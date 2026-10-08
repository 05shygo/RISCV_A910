`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_ROB — 表项阵列 (64) + 独热创造指针 + 头部读影子窗口 (D5) + 完成/解析匹配。
//
// ============================ 头部读的影子窗口 (D5 / §4.2 的 P1) ============
// 组合读的代价不是孤立的一条 mux, 而是
//   `64:1 mux -> 判退级联 -> preg 释放/AMT 写` 整条链压在一拍里。
// 所以这里养一份 **3 深的影子窗口** `win_q0/1/2`, 它们始终等于阵列下标
// `rptr+0/1/2` 的表项 —— 判退逻辑面对的永远是 3 个寄存器值。
//
// 写入路径 (与蓝本 `read_entry0/1/2` 同构):
//   * 移位: 退休指针前进 pop_n 格时, 全部 3 槽重填;
//   * 补空: 槽还是空的而阵列里那一格已经有效时补进来 (ROB 快空时的场景);
//   * 冲刷: FLUSH_2 那拍强制重填 —— 那拍指针归零、阵列同时被清, 所以直接取 0/1/2;
//   * 完成/解析: 影子项自己按"我这一格的 iid"匹配 (C910 的 read_entry 也带
//     complete 口, 见 ct_rtu_rob.v 的 read_entry*_cmplt_vld)。
//
// 重填的数据取**阵列的下一拍值** `rob_d[]` —— 里面已经含了本拍的完成/解析更新,
// 所以影子项不需要再自己去补那一拍 (少一套比较器, 也少一个"晚一拍"的坑)。
//
// ⚠️ 这里唯一的大 mux (`rob_d[rld_idx]`) 的**选择子只来自寄存器** (rptr/pop_n),
//    而且 mux 后面紧跟的就是影子寄存器 —— 它不在"判退 → 输出"那条链上。
//    这正是 P1 的对策: 大 mux 留在原地, 但它到影子寄存器就截止了。
//
// ============================ 指针 (§4.2 的原则 2) ========================
// 创造指针用**独热** (`cptr_oh` 64 位旋转), 天然给出每项的派遣使能, 没有加法器、
// 没有译码器 (P7)。退休指针是 6 位二进制 + 现展开 —— 那里不敏感 (C910 同)。
// 满/停用**计数器 + 留空位**, 不用指针比较 (§4 不变量 1), 且只依赖寄存器 (P8)。
// ---------------------------------------------------------------------------
module RTU_ROB (
    input  wire                cpu_clk,
    input  wire                cpu_rst,

    input  wire                flushing,       // 冲刷窗口 (含 T 拍): 冻住派遣与指针

    // ---- 派遣 (数据已由 RTU.v 按车道拼好; 顶层按程序序前缀给出) ----
    input  wire [2:0]          disp_vld,
    input  wire [`RTU_E_W-1:0] disp_data0,
    input  wire [`RTU_E_W-1:0] disp_data1,
    input  wire [`RTU_E_W-1:0] disp_data2,

    // ---- 完成 (7 路, D1.3) ----
    input  wire [6:0]          cmplt_vld,
    input  wire [6:0]          cmplt_iid0,
    input  wire [6:0]          cmplt_iid1,
    input  wire [6:0]          cmplt_iid2,
    input  wire [6:0]          cmplt_iid3,
    input  wire [6:0]          cmplt_iid4,
    input  wire [6:0]          cmplt_iid5,
    input  wire [6:0]          cmplt_iid6,

    // ---- 解析结果 (BEU) ----
    // ⚠️ **1 路**: 解析吞吐 = 分支执行单元数 (本核 1 个 BEU, 单发射一拍最多一条
    //    进 EX ⇒ 一拍最多一条解析)。D1.4 一度做成 3 路"按发射宽度预留", 但那与
    //    完成口(按功能单元数配)口径不一致 —— 一个 BEU 时 2 路恒零, 白付 128 个
    //    比较器 (见 §4.2 的完成总线 Fmax 风险项)。2026-10-02 收回 1 路。
    // ---- store 重放请求 (LSU 的 `lsu_rtu_wb_pipe4_flush` / `_spec_fail`) ----
    // "这条 store 的投机写失败了 ⇒ 它要重放": 在它自己的表项上置 `RTU_E_REPLAY`,
    // 之后它不能退休, 等它走到退休窗口最前面时由 RTU_commit 触发一次重放冲刷。
    // 与完成口同构地**按 iid 寻址** (表项只存回绕位 ⇒ 必须比回绕位)。
    input  wire                lsu_replay_vld,
    input  wire [6:0]          lsu_replay_iid,

    input  wire                resolve_vld,
    input  wire [6:0]          resolve_iid,
    input  wire                resolve_taken,
    input  wire                resolve_mispred,
    input  wire [31:0]         resolve_target,

    // ---- 退休 (来自 RTU_commit) / 冲刷 ----
    input  wire [1:0]          pop_n,
    input  wire                flush_lvl,      // FLUSH_2: 全清 + 指针复位

    // ---- 输出 ----
    output wire [6:0]          rtu_beu_retire_iid,   // = {rptr_msb, rptr}
    output wire [6:0]          win_iid0,
    output wire [6:0]          win_iid1,
    output wire [6:0]          win_iid2,
    output wire [`RTU_E_W-1:0] win_q0,
    output wire [`RTU_E_W-1:0] win_q1,
    output wire [`RTU_E_W-1:0] win_q2,
    output wire [6:0]          occ,
    output wire                rob_full,
    output wire [2:0]          disp_wrap,       // 3 条派遣各自 iid 的回绕位
    output wire [5:0]          cptr_idx         // 创造指针的二进制下标 (派遣回执用)
);

    // -----------------------------------------------------------------------
    // 创造指针的二进制下标 —— 给 §6.2 的"派遣回执" (rtu_disp_iid*) 用。
    //
    // ⚠️ **由 cptr_oh 组合译出, 不另存一份二进制指针**: 两份状态一旦走岔,
    //    回执发出去的 iid 会指向别的表项 —— 完成信号就会标到错的表项上,
    //    症状是"退休顺序错乱"而不是报错。
    // -----------------------------------------------------------------------
    function [5:0] oh2idx;
        input [63:0] oh;
        integer      j;
        begin
            oh2idx = 6'd0;
            for (j = 0; j < 64; j = j + 1)
                if (oh[j]) oh2idx = j[5:0];
        end
    endfunction

    // -----------------------------------------------------------------------
    // 指针与派遣使能
    // -----------------------------------------------------------------------
    reg  [63:0] cptr_oh;
    reg         cptr_msb;
    reg  [5:0]  rptr;
    reg         rptr_msb;
    reg  [6:0]  occ_q;

    // 派遣按程序序前缀收口 (允许少于 3 条, 不许跳号; §6 的硬约定 1)
    wire [2:0] disp_acc;
    assign disp_acc[0] = disp_vld[0] & ~flushing;
    assign disp_acc[1] = disp_acc[0] & disp_vld[1];
    assign disp_acc[2] = disp_acc[1] & disp_vld[2];

    // 车道 1/2 写的分别是 cptr+1 / cptr+2 —— 要的是 oh_r1[i] = cptr_oh[i-1]。
    // ⚠️ 这里的旋转方向**必须与下面指针推进的方向一致**: 指针是按 +n 前进的,
    //    写使能却按 -n 算的话, 多车道派遣时后面那几条的表项根本建不出来, 而
    //    占用计数照加 (单测台就是这么把它抓出来的 —— 症状是"完成的 iid 在阵列里
    //    找不到表项", 根因却是派遣使能。第一版把 {a[0],a[63:1]} 当成了右旋)。
    wire [63:0] oh_r1 = {cptr_oh[62:0], cptr_oh[63]};
    wire [63:0] oh_r2 = {cptr_oh[61:0], cptr_oh[63:62]};

    wire [5:0]  nxt_rptr = rptr + pop_n;
    wire [5:0]  win_idx0 = rptr;
    wire [5:0]  win_idx1 = rptr + 6'd1;
    wire [5:0]  win_idx2 = rptr + 6'd2;

    // 影子窗口重填的下标。⚠️ 冲刷那拍指针要归零, 阵列同拍被清空 —— 所以直接取 0/1/2,
    // 否则会拿"旧 rptr"去读一个刚被清掉的阵列, 窗口里留下上一代的数据。
    wire [5:0]  rld_idx0 = flush_lvl ? 6'd0 : nxt_rptr;
    wire [5:0]  rld_idx1 = flush_lvl ? 6'd1 : nxt_rptr + 6'd1;
    wire [5:0]  rld_idx2 = flush_lvl ? 6'd2 : nxt_rptr + 6'd2;

    // -----------------------------------------------------------------------
    // 表项阵列
    // -----------------------------------------------------------------------
    wire [`RTU_E_W-1:0] rob_q [0:63];
    wire [`RTU_E_W-1:0] rob_d [0:63];

    genvar gi;
    generate
    for (gi = 0; gi < 64; gi = gi + 1) begin : g_rob
        localparam [5:0] IDX = gi;

        wire e_hit0 = (disp_acc[0] & cptr_oh[gi]) | (disp_acc[1] & oh_r1[gi]) | (disp_acc[2] & oh_r2[gi]);
        wire [`RTU_E_W-1:0] e_data = (disp_acc[0] & cptr_oh[gi]) ? disp_data0 :
                                     (disp_acc[1] & oh_r1[gi])    ? disp_data1 : disp_data2;

        // 完成: iid 低 6 位 == 本项固定索引, 回绕位 == 本项存的那一位
        wire e_cmplt = (cmplt_vld[0] && (cmplt_iid0[5:0] == IDX) && (cmplt_iid0[6] == rob_q[gi][`RTU_E_WRAP]))
                    || (cmplt_vld[1] && (cmplt_iid1[5:0] == IDX) && (cmplt_iid1[6] == rob_q[gi][`RTU_E_WRAP]))
                    || (cmplt_vld[2] && (cmplt_iid2[5:0] == IDX) && (cmplt_iid2[6] == rob_q[gi][`RTU_E_WRAP]))
                    || (cmplt_vld[3] && (cmplt_iid3[5:0] == IDX) && (cmplt_iid3[6] == rob_q[gi][`RTU_E_WRAP]))
                    || (cmplt_vld[4] && (cmplt_iid4[5:0] == IDX) && (cmplt_iid4[6] == rob_q[gi][`RTU_E_WRAP]))
                    || (cmplt_vld[5] && (cmplt_iid5[5:0] == IDX) && (cmplt_iid5[6] == rob_q[gi][`RTU_E_WRAP]))
                    || (cmplt_vld[6] && (cmplt_iid6[5:0] == IDX) && (cmplt_iid6[6] == rob_q[gi][`RTU_E_WRAP]));

        wire e_res = resolve_vld && (resolve_iid[5:0] == IDX) && (resolve_iid[6] == rob_q[gi][`RTU_E_WRAP]);

        // store 重放请求: 与完成匹配同一套 iid 比较 (含回绕位)
        wire e_replay = lsu_replay_vld && (lsu_replay_iid[5:0] == IDX)
                                      && (lsu_replay_iid[6] == rob_q[gi][`RTU_E_WRAP]);

        // 本项这一拍被退休弹出 (见 RTU_ROB_entry 的 pop_en 注释)。
        // 距离用模 64 减法算, 于是回绕天然正确; pop_n 在 0 时全部为 0。
        wire [5:0] e_dist = IDX - rptr;
        wire       e_pop  = (pop_n == 2'd1) ? (e_dist == 6'd0) :
                            (pop_n == 2'd2) ? (e_dist <= 6'd1) :
                            (pop_n == 2'd3) ? (e_dist <= 6'd2) : 1'b0;

        RTU_ROB_entry u_entry (
            .cpu_clk       (cpu_clk),
            .cpu_rst       (cpu_rst),
            .disp_en       (e_hit0),
            .disp_data     (e_data),
            .pop_en        (e_pop),
            .reload_en     (1'b0),
            .reload_data   ({`RTU_E_W{1'b0}}),
            .cmplt_hit     (e_cmplt),
            .replay_set    (e_replay),
            .resolve_hit   (e_res),
            .resolve_taken (resolve_taken),
            .resolve_mispred(resolve_mispred),
            .resolve_target(resolve_target),
            .flush_clr     (flush_lvl),
            .entry_q       (rob_q[gi]),
            .entry_d       (rob_d[gi])
        );
    end
    endgenerate

    // -----------------------------------------------------------------------
    // 影子窗口 (3 深): 始终等于阵列的 rptr+0/1/2
    // -----------------------------------------------------------------------
    wire win_rld0 = flushing | (pop_n != 2'd0)
                  | (rob_q[rld_idx0][`RTU_E_VLD] & ~win_q0[`RTU_E_VLD]);
    wire win_rld1 = flushing | (pop_n != 2'd0)
                  | (rob_q[rld_idx1][`RTU_E_VLD] & ~win_q1[`RTU_E_VLD]);
    wire win_rld2 = flushing | (pop_n != 2'd0)
                  | (rob_q[rld_idx2][`RTU_E_VLD] & ~win_q2[`RTU_E_VLD]);

    wire win_cmplt0 = (cmplt_vld[0] && (cmplt_iid0[5:0]==win_idx0) && (cmplt_iid0[6]==win_q0[`RTU_E_WRAP]))
                   || (cmplt_vld[1] && (cmplt_iid1[5:0]==win_idx0) && (cmplt_iid1[6]==win_q0[`RTU_E_WRAP]))
                   || (cmplt_vld[2] && (cmplt_iid2[5:0]==win_idx0) && (cmplt_iid2[6]==win_q0[`RTU_E_WRAP]))
                   || (cmplt_vld[3] && (cmplt_iid3[5:0]==win_idx0) && (cmplt_iid3[6]==win_q0[`RTU_E_WRAP]))
                   || (cmplt_vld[4] && (cmplt_iid4[5:0]==win_idx0) && (cmplt_iid4[6]==win_q0[`RTU_E_WRAP]))
                   || (cmplt_vld[5] && (cmplt_iid5[5:0]==win_idx0) && (cmplt_iid5[6]==win_q0[`RTU_E_WRAP]))
                   || (cmplt_vld[6] && (cmplt_iid6[5:0]==win_idx0) && (cmplt_iid6[6]==win_q0[`RTU_E_WRAP]));
    wire win_cmplt1 = (cmplt_vld[0] && (cmplt_iid0[5:0]==win_idx1) && (cmplt_iid0[6]==win_q1[`RTU_E_WRAP]))
                   || (cmplt_vld[1] && (cmplt_iid1[5:0]==win_idx1) && (cmplt_iid1[6]==win_q1[`RTU_E_WRAP]))
                   || (cmplt_vld[2] && (cmplt_iid2[5:0]==win_idx1) && (cmplt_iid2[6]==win_q1[`RTU_E_WRAP]))
                   || (cmplt_vld[3] && (cmplt_iid3[5:0]==win_idx1) && (cmplt_iid3[6]==win_q1[`RTU_E_WRAP]))
                   || (cmplt_vld[4] && (cmplt_iid4[5:0]==win_idx1) && (cmplt_iid4[6]==win_q1[`RTU_E_WRAP]))
                   || (cmplt_vld[5] && (cmplt_iid5[5:0]==win_idx1) && (cmplt_iid5[6]==win_q1[`RTU_E_WRAP]))
                   || (cmplt_vld[6] && (cmplt_iid6[5:0]==win_idx1) && (cmplt_iid6[6]==win_q1[`RTU_E_WRAP]));
    wire win_cmplt2 = (cmplt_vld[0] && (cmplt_iid0[5:0]==win_idx2) && (cmplt_iid0[6]==win_q2[`RTU_E_WRAP]))
                   || (cmplt_vld[1] && (cmplt_iid1[5:0]==win_idx2) && (cmplt_iid1[6]==win_q2[`RTU_E_WRAP]))
                   || (cmplt_vld[2] && (cmplt_iid2[5:0]==win_idx2) && (cmplt_iid2[6]==win_q2[`RTU_E_WRAP]))
                   || (cmplt_vld[3] && (cmplt_iid3[5:0]==win_idx2) && (cmplt_iid3[6]==win_q2[`RTU_E_WRAP]))
                   || (cmplt_vld[4] && (cmplt_iid4[5:0]==win_idx2) && (cmplt_iid4[6]==win_q2[`RTU_E_WRAP]))
                   || (cmplt_vld[5] && (cmplt_iid5[5:0]==win_idx2) && (cmplt_iid5[6]==win_q2[`RTU_E_WRAP]))
                   || (cmplt_vld[6] && (cmplt_iid6[5:0]==win_idx2) && (cmplt_iid6[6]==win_q2[`RTU_E_WRAP]));

    wire win_res0 = resolve_vld && (resolve_iid[5:0]==win_idx0) && (resolve_iid[6]==win_q0[`RTU_E_WRAP]);
    wire win_res1 = resolve_vld && (resolve_iid[5:0]==win_idx1) && (resolve_iid[6]==win_q1[`RTU_E_WRAP]);
    wire win_res2 = resolve_vld && (resolve_iid[5:0]==win_idx2) && (resolve_iid[6]==win_q2[`RTU_E_WRAP]);

    wire [`RTU_E_W-1:0] win_d0, win_d1, win_d2;

    // ⚠️ 影子窗口也必须能收到重放置位: 判退读的是**窗口**那一份 (不是阵列),
    //    而窗口只在"队头移动/冲刷/补空"时 reload —— 被重放的那条**故意不让它退**
    //    (它的 store 不许落内存), 队头于是不动、窗口不 reload ⇒ 只靠阵列置位的话
    //    窗口永远看不到这个标志, **卡死**。用窗口自己的 iid 判 (与 win_iid* 同式)。
    wire win_replay0 = lsu_replay_vld && (lsu_replay_iid == win_iid0);
    wire win_replay1 = lsu_replay_vld && (lsu_replay_iid == win_iid1);
    wire win_replay2 = lsu_replay_vld && (lsu_replay_iid == win_iid2);

    RTU_ROB_entry u_win0 (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .disp_en(1'b0), .disp_data({`RTU_E_W{1'b0}}), .pop_en(1'b0),
        .reload_en(win_rld0), .reload_data(rob_d[rld_idx0]),
        .cmplt_hit(win_cmplt0), .replay_set(win_replay0), .resolve_hit(win_res0),
        .resolve_taken(resolve_taken), .resolve_mispred(resolve_mispred),
        .resolve_target(resolve_target),
        .flush_clr(flush_lvl), .entry_q(win_q0), .entry_d(win_d0)
    );

    RTU_ROB_entry u_win1 (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .disp_en(1'b0), .disp_data({`RTU_E_W{1'b0}}), .pop_en(1'b0),
        .reload_en(win_rld1), .reload_data(rob_d[rld_idx1]),
        .cmplt_hit(win_cmplt1), .replay_set(win_replay1), .resolve_hit(win_res1),
        .resolve_taken(resolve_taken), .resolve_mispred(resolve_mispred),
        .resolve_target(resolve_target),
        .flush_clr(flush_lvl), .entry_q(win_q1), .entry_d(win_d1)
    );

    RTU_ROB_entry u_win2 (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .disp_en(1'b0), .disp_data({`RTU_E_W{1'b0}}), .pop_en(1'b0),
        .reload_en(win_rld2), .reload_data(rob_d[rld_idx2]),
        .cmplt_hit(win_cmplt2), .replay_set(win_replay2), .resolve_hit(win_res2),
        .resolve_taken(resolve_taken), .resolve_mispred(resolve_mispred),
        .resolve_target(resolve_target),
        .flush_clr(flush_lvl), .entry_q(win_q2), .entry_d(win_d2)
    );

    // -----------------------------------------------------------------------
    // 指针推进
    // -----------------------------------------------------------------------
    wire [1:0] ndisp = {1'b0, disp_acc[0]} + {1'b0, disp_acc[1]} + {1'b0, disp_acc[2]};

    // 本拍派出的车道里有没有落在下标 63 的 -> 创造指针越过回绕点
    wire wrap_cross = (disp_acc[0] & cptr_oh[63])
                    | (disp_acc[1] & cptr_oh[62])
                    | (disp_acc[2] & cptr_oh[61]);

    // 退休指针越过 63 的回绕
    wire rptr_cross = (pop_n == 2'd1) ? (rptr == 6'd63) :
                      (pop_n == 2'd2) ? (rptr >= 6'd62) :
                      (pop_n == 2'd3) ? (rptr >= 6'd61) : 1'b0;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            cptr_oh  <= 64'd1;
            cptr_msb <= 1'b0;
            rptr     <= 6'd0;
            rptr_msb <= 1'b0;
            occ_q    <= 7'd0;
        end else if (flush_lvl) begin
            cptr_oh  <= 64'd1;
            cptr_msb <= 1'b0;
            rptr     <= 6'd0;
            rptr_msb <= 1'b0;
            occ_q    <= 7'd0;
        end else begin
            cptr_oh  <= (ndisp == 2'd0) ? cptr_oh :
                        (ndisp == 2'd1) ? {cptr_oh[62:0], cptr_oh[63]}    :
                        (ndisp == 2'd2) ? {cptr_oh[61:0], cptr_oh[63:62]} :
                                          {cptr_oh[60:0], cptr_oh[63:61]};
            cptr_msb <= cptr_msb ^ wrap_cross;
            rptr     <= nxt_rptr;
            rptr_msb <= rptr_msb ^ rptr_cross;
            occ_q    <= occ_q + {5'b0, ndisp} - {5'b0, pop_n};
        end
    end

    assign rtu_beu_retire_iid = {rptr_msb, rptr};
    assign win_iid0            = {win_q0[`RTU_E_WRAP], win_idx0};
    assign win_iid1            = {win_q1[`RTU_E_WRAP], win_idx1};
    assign win_iid2            = {win_q2[`RTU_E_WRAP], win_idx2};
    assign occ                 = occ_q;
    assign rob_full            = (occ_q >= `RTU_ROB_FULL_TH);

    assign disp_wrap[0] = cptr_msb;
    assign disp_wrap[1] = cptr_msb ^ cptr_oh[63];
    assign disp_wrap[2] = cptr_msb ^ (cptr_oh[63] | cptr_oh[62]);

    assign cptr_idx     = oh2idx(cptr_oh);

endmodule
