`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_ROB — A76 MCQ 式 banked 表项阵列 (64 = 8 bank × 8 entry) + commit 窗口。
//
// ============================ bank 组织 (R14) ==============================
// 逻辑下标 idx[5:0]: bank = idx[2:0], row = idx[5:3]。连续 iid 落在不同 bank,
// 所以一拍 3 条派遣/退休最多各占 3 个 bank, 每 bank 每拍最多 1 写口 + 1 pop。
//
// 每 bank 一个 **寄存的** 3-bit row_q 指向本 bank 下一个将退休的行 (A76
// `preread_muxsel_q` 的对应物)。head_data 是 bank 内 8:1 局部 mux; 顶层只用
// 3 个 8:1 旋转 mux 把 bank head 拼成 commit 窗口的新队头。原来 rptr 到 64 项
// 的减法/比较/广播、didx_q 到 64 项的写数据广播、以及 3 个 64:1 预读 mux 都消失。
//
// ============================ commit 窗口 ==================================
// win_q0/1/2 就是 A76 的 commit 组寄存器 (`_o0_q`): commit 每拍组合读它们。
// 重填来源:
//   * 新窗口里仍在旧窗口内的槽 -> 从 win_q 移位;
//   * 窗口新尾部 (rptr+3..rptr+5)  -> 对应 bank 的 head (row_q 已指向它);
//   * 覆盖: 当拍派遣 disp_data > 上一拍派遣 ddata_q > bank head/win_q。
// 上一拍派遣必须覆盖: R11 把阵列写推迟了一拍, 尾部槽在阵列 q 里还看不到它,
// 而窗口 (比阵列早一拍) 必须立刻看到。
//
// 下标不变量: row_q[b] = row((rptr + (b - rptr[2:0]) mod 8) mod 64)。
//   * flush (disp_freeze): row_q <= cptr 派生值, rptr 同沿追到 cptr;
//   * 正常退休: b ∈ {rb, rb+1, rb+2} 且被 pop_n 覆盖时 row_q++。
// pop_n<=3<8 ⇒ 每 bank 每拍最多推进一行; 窗口尾部的 bank 与本拍被 pop 的
// bank 不相交, 所以 bank head 读不会读到同拍清零的项。
//
// ============================ 指针 (§4.2 的原则 2) ========================
// 创造指针改为 6-bit 二进制 + 回绕位 (原 cptr_oh[64] + oh2idx), 派遣回执的
// 回绕位用 cptr_idx+j 的进位算。退休指针/占用计数器/rob_full 口径不变。
// ---------------------------------------------------------------------------
module RTU_ROB (
    input  wire                cpu_clk,
    input  wire                cpu_rst,

    // [R6] 派遣冻结: 纯寄存器级 (FSM busy), 不含 T 拍。
    input  wire                disp_freeze,
    // [R23] FSM busy 的下一拍值: 各 bank 用同沿本地副本, 不增加延迟。
    input  wire                freeze_nxt,

    // ---- 派遣 (数据已由 RTU.v 按车道拼好; 顶层按程序序前缀给出) ----
    input  wire [2:0]          disp_vld,
    input  wire [`RTU_E_W-1:0] disp_data0,
    input  wire [`RTU_E_W-1:0] disp_data1,
    input  wire [`RTU_E_W-1:0] disp_data2,

    // ---- 完成 (7 路, D1.3) ----
    input  wire [6:0]          cmplt_vld,
    input  wire [6:0] cmplt_iid0,
    input  wire [6:0] cmplt_iid1,
    input  wire [6:0] cmplt_iid2,
    input  wire [6:0] cmplt_iid3,
    input  wire [6:0] cmplt_iid4,
    input  wire [6:0] cmplt_iid5,
    input  wire [6:0] cmplt_iid6,

    // ---- 解析结果 (BEU) ----
    input  wire                lsu_replay_vld,
    input  wire [6:0] lsu_replay_iid,

    input  wire                resolve_vld,
    input  wire [6:0] resolve_iid,
    input  wire                resolve_taken,
    input  wire                resolve_mispred,
    input  wire [31:0]         resolve_target,

    // ---- 退休 (来自 RTU_commit) / 冲刷 ----
    input  wire [1:0]          pop_n,
    input  wire                flush_lvl,      // 保留端口 (内部行为用 disp_freeze)

    // ---- 输出 ----
    output wire [6:0] rtu_beu_retire_iid,   // = {rptr_msb, rptr}
    output wire [6:0] win_iid0,
    output wire [6:0] win_iid1,
    output wire [6:0] win_iid2,
    output wire [`RTU_E_W-1:0] win_q0,
    output wire [`RTU_E_W-1:0] win_q1,
    output wire [`RTU_E_W-1:0] win_q2,
    output wire [6:0]          occ,
    output wire                rob_full,
    output wire [2:0]          disp_wrap,       // 3 条派遣各自 iid 的回绕位
    output wire [5:0]          cptr_idx         // 创造指针的二进制下标 (派遣回执用)
);

    // -----------------------------------------------------------------------
    // 指针与派遣使能
    // -----------------------------------------------------------------------
    reg  [5:0]  cptr_idx_q;
    reg         cptr_msb;
    reg  [5:0]  rptr;
    reg         rptr_msb;
    reg  [6:0]  occ_q;
    reg         rob_full_q;

    // 派遣按程序序前缀收口 (允许少于 3 条, 不许跳号; §6 的硬约定 1)
    wire [2:0] disp_acc;
    assign disp_acc[0] = disp_vld[0] & ~disp_freeze;
    assign disp_acc[1] = disp_acc[0] & disp_vld[1];
    assign disp_acc[2] = disp_acc[1] & disp_vld[2];

    wire [1:0] ndisp = {1'b0, disp_acc[0]} + {1'b0, disp_acc[1]} + {1'b0, disp_acc[2]};

    wire [6:0] cptr_sum = {1'b0, cptr_idx_q} + {5'b0, ndisp};
    wire [5:0] nxt_rptr = rptr + pop_n;
    wire [6:0] occ_nxt  = occ_q + {5'b0, ndisp} - {5'b0, pop_n};
    wire [5:0] win_idx0 = rptr;
    wire [5:0] win_idx1 = rptr + 6'd1;
    wire [5:0] win_idx2 = rptr + 6'd2;

    // 窗口重填的目标下标 (追齐后/换头后)。
    // [R7] 用寄存器级 disp_freeze, 不用组合 flush_lvl (上游 LSU commit 闸门)。
    wire [5:0] rld_idx0 = disp_freeze ? cptr_idx_q        : nxt_rptr;
    wire [5:0] rld_idx1 = disp_freeze ? cptr_idx_q + 6'd1 : nxt_rptr + 6'd1;
    wire [5:0] rld_idx2 = disp_freeze ? cptr_idx_q + 6'd2 : nxt_rptr + 6'd2;

    // -----------------------------------------------------------------------
    // [R11] 派遣数据/目标先打一拍再进阵列 (A76 的 dispatch 级)。
    // 窗口仍在本拍用 disp_* 更新; 阵列晚一拍写, 晚一拍的写与 flush 同沿时
    // flush 优先 (entry 内)。
    // -----------------------------------------------------------------------
    reg  [2:0]          dacc_q;
    reg  [`RTU_E_W-1:0] ddata_q0, ddata_q1, ddata_q2;
    reg  [5:0]          didx_q0, didx_q1, didx_q2;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            dacc_q   <= 3'd0;
            ddata_q0 <= {`RTU_E_W{1'b0}};
            ddata_q1 <= {`RTU_E_W{1'b0}};
            ddata_q2 <= {`RTU_E_W{1'b0}};
            didx_q0  <= 6'd0; didx_q1 <= 6'd0; didx_q2 <= 6'd0;
        end else begin
            dacc_q   <= disp_acc;
            ddata_q0 <= disp_data0;
            ddata_q1 <= disp_data1;
            ddata_q2 <= disp_data2;
            didx_q0  <= cptr_idx_q;
            didx_q1  <= cptr_idx_q + 6'd1;
            didx_q2  <= cptr_idx_q + 6'd2;
        end
    end

    // -----------------------------------------------------------------------
    // 8 个 bank: 每 bank 单写口 + 局部完成/解析/重放匹配 + 寄存读指针
    // -----------------------------------------------------------------------
    wire [`RTU_E_W-1:0] bnk_head [0:7];

    genvar gb;
    generate
    for (gb = 0; gb < 8; gb = gb + 1) begin : g_bank
        localparam [2:0] BID = gb;

        // 本 bank 的派遣数据: 3 条 lane 中最多一条落在本 bank, 3:1 选出。
        // (命中/行译码不在顶层做: bank 内用当拍 disp_acc/cptr 算好并寄存。)
        wire w0 = dacc_q[0] & (didx_q0[2:0] == BID);
        wire w1 = dacc_q[1] & (didx_q1[2:0] == BID);
        wire w2 = dacc_q[2] & (didx_q2[2:0] == BID);
        wire [`RTU_E_W-1:0] bnk_wdata = w0 ? ddata_q0 :
                                        w1 ? ddata_q1 : ddata_q2;

        RTU_ROB_bank #(.BANK(gb)) u_bank (
            .cpu_clk       (cpu_clk),
            .cpu_rst       (cpu_rst),
            .disp_acc      (disp_acc),
            .ndisp         (ndisp),
            .wr_data       (bnk_wdata),
            .cmplt_vld     (cmplt_vld),
            .cmplt_iid0    (cmplt_iid0),
            .cmplt_iid1    (cmplt_iid1),
            .cmplt_iid2    (cmplt_iid2),
            .cmplt_iid3    (cmplt_iid3),
            .cmplt_iid4    (cmplt_iid4),
            .cmplt_iid5    (cmplt_iid5),
            .cmplt_iid6    (cmplt_iid6),
            .lsu_replay_vld(lsu_replay_vld),
            .lsu_replay_iid(lsu_replay_iid),
            .resolve_vld   (resolve_vld),
            .resolve_iid   (resolve_iid),
            .resolve_taken (resolve_taken),
            .resolve_mispred(resolve_mispred),
            .resolve_target(resolve_target),
            .freeze_nxt    (freeze_nxt),
            .pop_n         (pop_n),
            .head_data     (bnk_head[gb])
        );
    end
    endgenerate

    // -----------------------------------------------------------------------
    // commit 窗口 (3 深) + bank head 旋转 mux
    //
    // 新窗口的尾部 (rptr+3..rptr+5) 是当前 rptr 之后第 3..5 个 bank 的 head;
    // row_q 已指向它们, 所以读 mux 的选择子是寄存器。仍在旧窗口内的槽直接
    // 从 win_q 移位 (与原来的 win_src 同构)。
    // -----------------------------------------------------------------------
    wire [`RTU_E_W-1:0] bnk_rd0 = bnk_head[rld_idx0[2:0]];
    wire [`RTU_E_W-1:0] bnk_rd1 = bnk_head[rld_idx1[2:0]];
    wire [`RTU_E_W-1:0] bnk_rd2 = bnk_head[rld_idx2[2:0]];

    // ⚠️ 必须先声明 win_q —— 下面 win_src 要用
    wire [`RTU_E_W-1:0] win_q0, win_q1, win_q2;
    wire [`RTU_E_W-1:0] win_base0, win_base1, win_base2;

    wire [`RTU_E_W-1:0] win_src0 = (pop_n == 2'd0) ? win_q0 :
                                   (pop_n == 2'd1) ? win_q1 :
                                   (pop_n == 2'd2) ? win_q2 : bnk_rd0;
    wire [`RTU_E_W-1:0] win_src1 = (pop_n == 2'd0) ? win_q1 :
                                   (pop_n == 2'd1) ? win_q2 : bnk_rd1;
    wire [`RTU_E_W-1:0] win_src2 = (pop_n == 2'd0) ? win_q2 : bnk_rd2;

    // 尾部槽 (base 来自 bank head) 才需要上一拍派遣覆盖:
    //   slot0 尾部 ⟺ pop_n=3; slot1 ⟺ pop_n>=2; slot2 ⟺ pop_n>=1
    wire tail0 = (pop_n == 2'd3);
    wire tail1 = pop_n[1];
    wire tail2 = (pop_n != 2'd0);

    wire dd0_0 = dacc_q[0] & (didx_q0 == rld_idx0);
    wire dd0_1 = dacc_q[1] & (didx_q1 == rld_idx0);
    wire dd0_2 = dacc_q[2] & (didx_q2 == rld_idx0);
    wire dd1_0 = dacc_q[0] & (didx_q0 == rld_idx1);
    wire dd1_1 = dacc_q[1] & (didx_q1 == rld_idx1);
    wire dd1_2 = dacc_q[2] & (didx_q2 == rld_idx1);
    wire dd2_0 = dacc_q[0] & (didx_q0 == rld_idx2);
    wire dd2_1 = dacc_q[1] & (didx_q1 == rld_idx2);
    wire dd2_2 = dacc_q[2] & (didx_q2 == rld_idx2);
    wire win_dd0 = tail0 & (dd0_0 | dd0_1 | dd0_2);
    wire win_dd1 = tail1 & (dd1_0 | dd1_1 | dd1_2);
    wire win_dd2 = tail2 & (dd2_0 | dd2_1 | dd2_2);
    wire [`RTU_E_W-1:0] win_dd0_data = dd0_0 ? ddata_q0 :
                                         dd0_1 ? ddata_q1 : ddata_q2;
    wire [`RTU_E_W-1:0] win_dd1_data = dd1_0 ? ddata_q0 :
                                         dd1_1 ? ddata_q1 : ddata_q2;
    wire [`RTU_E_W-1:0] win_dd2_data = dd2_0 ? ddata_q0 :
                                         dd2_1 ? ddata_q1 : ddata_q2;

    // 当拍派遣覆盖 (窗口比阵列早一拍, 判退要立刻看到)
    wire dp0_0 = disp_acc[0] & (cptr_idx_q == rld_idx0);
    wire dp0_1 = disp_acc[1] & ((cptr_idx_q + 6'd1) == rld_idx0);
    wire dp0_2 = disp_acc[2] & ((cptr_idx_q + 6'd2) == rld_idx0);
    wire dp1_0 = disp_acc[0] & (cptr_idx_q == rld_idx1);
    wire dp1_1 = disp_acc[1] & ((cptr_idx_q + 6'd1) == rld_idx1);
    wire dp1_2 = disp_acc[2] & ((cptr_idx_q + 6'd2) == rld_idx1);
    wire dp2_0 = disp_acc[0] & (cptr_idx_q == rld_idx2);
    wire dp2_1 = disp_acc[1] & ((cptr_idx_q + 6'd1) == rld_idx2);
    wire dp2_2 = disp_acc[2] & ((cptr_idx_q + 6'd2) == rld_idx2);
    wire win_dp0 = dp0_0 | dp0_1 | dp0_2;
    wire win_dp1 = dp1_0 | dp1_1 | dp1_2;
    wire win_dp2 = dp2_0 | dp2_1 | dp2_2;
    wire [`RTU_E_W-1:0] win_dp0_data = dp0_0 ? disp_data0 :
                                         dp0_1 ? disp_data1 : disp_data2;
    wire [`RTU_E_W-1:0] win_dp1_data = dp1_0 ? disp_data0 :
                                         dp1_1 ? disp_data1 : disp_data2;
    wire [`RTU_E_W-1:0] win_dp2_data = dp2_0 ? disp_data0 :
                                         dp2_1 ? disp_data1 : disp_data2;

    wire [`RTU_E_W-1:0] win_pre0 = win_dd0 ? win_dd0_data : win_src0;
    wire [`RTU_E_W-1:0] win_pre1 = win_dd1 ? win_dd1_data : win_src1;
    wire [`RTU_E_W-1:0] win_pre2 = win_dd2 ? win_dd2_data : win_src2;

    assign win_base0 = disp_freeze ? {`RTU_E_W{1'b0}} :
                       win_dp0 ? win_dp0_data : win_pre0;
    assign win_base1 = disp_freeze ? {`RTU_E_W{1'b0}} :
                       win_dp1 ? win_dp1_data : win_pre1;
    assign win_base2 = disp_freeze ? {`RTU_E_W{1'b0}} :
                       win_dp2 ? win_dp2_data : win_pre2;

    // 窗口重填使能: 换头 / 冲刷 / 当拍有派遣落进该槽 (上一拍派遣只在换头时
    // 才可能落进尾部, 已由 pop_n != 0 覆盖)。
    wire win_rld0 = disp_freeze | (pop_n != 2'd0) | win_dp0;
    wire win_rld1 = disp_freeze | (pop_n != 2'd0) | win_dp1;
    wire win_rld2 = disp_freeze | (pop_n != 2'd0) | win_dp2;

    // 自更新比较用的"装载后那一项"的 iid: reload 时用 rld_idx/新 wrap,
    // 否则用窗口自己的 win_idx/win_q。被派遣覆盖的项不叠更新 (派遣优先)。
    wire [5:0] win_u_idx0 = win_rld0 ? rld_idx0 : win_idx0;
    wire [5:0] win_u_idx1 = win_rld1 ? rld_idx1 : win_idx1;
    wire [5:0] win_u_idx2 = win_rld2 ? rld_idx2 : win_idx2;
    wire win_u_wrp0 = win_rld0 ? win_base0[`RTU_E_WRAP] : win_q0[`RTU_E_WRAP];
    wire win_u_wrp1 = win_rld1 ? win_base1[`RTU_E_WRAP] : win_q1[`RTU_E_WRAP];
    wire win_u_wrp2 = win_rld2 ? win_base2[`RTU_E_WRAP] : win_q2[`RTU_E_WRAP];
    wire win_upd_ok0 = ~(win_rld0 & (win_dp0 | win_dd0));
    wire win_upd_ok1 = ~(win_rld1 & (win_dp1 | win_dd1));
    wire win_upd_ok2 = ~(win_rld2 & (win_dp2 | win_dd2));

    wire win_cmplt0 = win_upd_ok0 && ((cmplt_vld[0] && (cmplt_iid0[5:0]==win_u_idx0) && (cmplt_iid0[6]==win_u_wrp0))
                   || (cmplt_vld[1] && (cmplt_iid1[5:0]==win_u_idx0) && (cmplt_iid1[6]==win_u_wrp0))
                   || (cmplt_vld[2] && (cmplt_iid2[5:0]==win_u_idx0) && (cmplt_iid2[6]==win_u_wrp0))
                   || (cmplt_vld[3] && (cmplt_iid3[5:0]==win_u_idx0) && (cmplt_iid3[6]==win_u_wrp0))
                   || (cmplt_vld[4] && (cmplt_iid4[5:0]==win_u_idx0) && (cmplt_iid4[6]==win_u_wrp0))
                   || (cmplt_vld[5] && (cmplt_iid5[5:0]==win_u_idx0) && (cmplt_iid5[6]==win_u_wrp0))
                   || (cmplt_vld[6] && (cmplt_iid6[5:0]==win_u_idx0) && (cmplt_iid6[6]==win_u_wrp0)));
    wire win_cmplt1 = win_upd_ok1 && ((cmplt_vld[0] && (cmplt_iid0[5:0]==win_u_idx1) && (cmplt_iid0[6]==win_u_wrp1))
                   || (cmplt_vld[1] && (cmplt_iid1[5:0]==win_u_idx1) && (cmplt_iid1[6]==win_u_wrp1))
                   || (cmplt_vld[2] && (cmplt_iid2[5:0]==win_u_idx1) && (cmplt_iid2[6]==win_u_wrp1))
                   || (cmplt_vld[3] && (cmplt_iid3[5:0]==win_u_idx1) && (cmplt_iid3[6]==win_u_wrp1))
                   || (cmplt_vld[4] && (cmplt_iid4[5:0]==win_u_idx1) && (cmplt_iid4[6]==win_u_wrp1))
                   || (cmplt_vld[5] && (cmplt_iid5[5:0]==win_u_idx1) && (cmplt_iid5[6]==win_u_wrp1))
                   || (cmplt_vld[6] && (cmplt_iid6[5:0]==win_u_idx1) && (cmplt_iid6[6]==win_u_wrp1)));
    wire win_cmplt2 = win_upd_ok2 && ((cmplt_vld[0] && (cmplt_iid0[5:0]==win_u_idx2) && (cmplt_iid0[6]==win_u_wrp2))
                   || (cmplt_vld[1] && (cmplt_iid1[5:0]==win_u_idx2) && (cmplt_iid1[6]==win_u_wrp2))
                   || (cmplt_vld[2] && (cmplt_iid2[5:0]==win_u_idx2) && (cmplt_iid2[6]==win_u_wrp2))
                   || (cmplt_vld[3] && (cmplt_iid3[5:0]==win_u_idx2) && (cmplt_iid3[6]==win_u_wrp2))
                   || (cmplt_vld[4] && (cmplt_iid4[5:0]==win_u_idx2) && (cmplt_iid4[6]==win_u_wrp2))
                   || (cmplt_vld[5] && (cmplt_iid5[5:0]==win_u_idx2) && (cmplt_iid5[6]==win_u_wrp2))
                   || (cmplt_vld[6] && (cmplt_iid6[5:0]==win_u_idx2) && (cmplt_iid6[6]==win_u_wrp2)));

    wire win_res0 = win_upd_ok0 && resolve_vld && (resolve_iid[5:0]==win_u_idx0) && (resolve_iid[6]==win_u_wrp0);
    wire win_res1 = win_upd_ok1 && resolve_vld && (resolve_iid[5:0]==win_u_idx1) && (resolve_iid[6]==win_u_wrp1);
    wire win_res2 = win_upd_ok2 && resolve_vld && (resolve_iid[5:0]==win_u_idx2) && (resolve_iid[6]==win_u_wrp2);

    wire win_replay0 = win_upd_ok0 && lsu_replay_vld && (lsu_replay_iid == {win_u_wrp0, win_u_idx0});
    wire win_replay1 = win_upd_ok1 && lsu_replay_vld && (lsu_replay_iid == {win_u_wrp1, win_u_idx1});
    wire win_replay2 = win_upd_ok2 && lsu_replay_vld && (lsu_replay_iid == {win_u_wrp2, win_u_idx2});

    RTU_ROB_entry u_win0 (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .disp_en(1'b0), .disp_data({`RTU_E_W{1'b0}}), .pop_en(1'b0),
        .reload_en(win_rld0), .reload_data(win_base0),
        .cmplt_hit(win_cmplt0), .replay_set(win_replay0), .resolve_hit(win_res0),
        .resolve_taken(resolve_taken), .resolve_mispred(resolve_mispred),
        .resolve_target(resolve_target),
        .flush_clr(disp_freeze), .entry_q(win_q0), .entry_d(win_d0)
    );

    RTU_ROB_entry u_win1 (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .disp_en(1'b0), .disp_data({`RTU_E_W{1'b0}}), .pop_en(1'b0),
        .reload_en(win_rld1), .reload_data(win_base1),
        .cmplt_hit(win_cmplt1), .replay_set(win_replay1), .resolve_hit(win_res1),
        .resolve_taken(resolve_taken), .resolve_mispred(resolve_mispred),
        .resolve_target(resolve_target),
        .flush_clr(disp_freeze), .entry_q(win_q1), .entry_d(win_d1)
    );

    RTU_ROB_entry u_win2 (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .disp_en(1'b0), .disp_data({`RTU_E_W{1'b0}}), .pop_en(1'b0),
        .reload_en(win_rld2), .reload_data(win_base2),
        .cmplt_hit(win_cmplt2), .replay_set(win_replay2), .resolve_hit(win_res2),
        .resolve_taken(resolve_taken), .resolve_mispred(resolve_mispred),
        .resolve_target(resolve_target),
        .flush_clr(disp_freeze), .entry_q(win_q2), .entry_d(win_d2)
    );

    // -----------------------------------------------------------------------
    // [R16] A76 式 commit-group UID (对应 Enyo `uid_o*_q`)
    //
    // 原来 `win_iid{k} = {win_q{k}[WRAP], rptr+k}` 是组合的, 把 rptr 一路送进
    // RTU_commit 的 replay/mispredict/trap 比较 -> pop_n -> 8 个 bank 的
    // e_pop_q/row_q 和训练 FIFO 写口 (R14f2 top-15 全在这一族)。这里把窗口
    // 表项的 iid 与表项同沿寄存, 判退只读寄存器。
    //
    // 装载源就是 `win_base{k}` / `rld_idx{k}` —— 本次边沿实际装进槽 k 的数据
    // 与它的逻辑下标, 所以 shift / bank head / 两路派遣覆盖都天然正确。
    // disp_freeze 拍 win_base 被强制 0, 用 cptr 派生的 iid 兜底。
    // -----------------------------------------------------------------------
    reg  [6:0] win_iid_q0, win_iid_q1, win_iid_q2;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            win_iid_q0 <= 7'd0;
            win_iid_q1 <= 7'd0;
            win_iid_q2 <= 7'd0;
        end else if (disp_freeze) begin
            win_iid_q0 <= {disp_wrap[0], cptr_idx_q};
            win_iid_q1 <= {disp_wrap[1], cptr_idx_q + 6'd1};
            win_iid_q2 <= {disp_wrap[2], cptr_idx_q + 6'd2};
        end else begin
            if (win_rld0) win_iid_q0 <= {win_base0[`RTU_E_WRAP], rld_idx0};
            if (win_rld1) win_iid_q1 <= {win_base1[`RTU_E_WRAP], rld_idx1};
            if (win_rld2) win_iid_q2 <= {win_base2[`RTU_E_WRAP], rld_idx2};
        end
    end

    // -----------------------------------------------------------------------
    // 指针推进
    // -----------------------------------------------------------------------
    // 退休指针越过 63 的回绕
    wire rptr_cross = (pop_n == 2'd1) ? (rptr == 6'd63) :
                      (pop_n == 2'd2) ? (rptr >= 6'd62) :
                      (pop_n == 2'd3) ? (rptr >= 6'd61) : 1'b0;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            cptr_idx_q <= 6'd0;
            cptr_msb   <= 1'b0;
            rptr       <= 6'd0;
            rptr_msb   <= 1'b0;
            occ_q      <= 7'd0;
        end else if (disp_freeze) begin
            // [R12] 指针/occ 复位用寄存器级 disp_freeze。
            // 创造指针 cptr 不归零 —— iid 要重复得等 128 次派遣 (见 R12 注释)。
            rptr     <= cptr_idx_q;
            rptr_msb <= cptr_msb;
            occ_q    <= 7'd0;
        end else begin
            cptr_idx_q <= cptr_sum[5:0];
            cptr_msb   <= cptr_msb ^ cptr_sum[6];
            rptr       <= nxt_rptr;
            rptr_msb   <= rptr_msb ^ rptr_cross;
            occ_q      <= occ_nxt;
        end
    end

    // [R14e] rob_full 用 **occ 的下一拍值** 寄存, 与 occ_q 同沿:
    //   rob_full_q(T+1) == (occ_q(T+1) >= TH), 与原来组合比较器逐拍等价,
    //   但切断了 occ_q → rob_full → rtu_disp_stall → IDU → disp_vld →
    //   窗口派遣覆盖 的跨模块组合环 (R14c Pblock 实测 -2.908 的头顶)。
    //   disp_freeze 那拍 occ 清零, full 也强制 0。
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            rob_full_q <= 1'b0;
        else if (disp_freeze)
            rob_full_q <= 1'b0;
        else
            rob_full_q <= (occ_nxt >= `RTU_ROB_FULL_TH);
    end

    assign rtu_beu_retire_iid = {rptr_msb, rptr};
    assign win_iid0            = win_iid_q0;
    assign win_iid1            = win_iid_q1;
    assign win_iid2            = win_iid_q2;
    assign occ                 = occ_q;
    assign rob_full            = rob_full_q;

    assign disp_wrap[0] = cptr_msb;
    assign disp_wrap[1] = cptr_msb ^ (cptr_idx_q == 6'd63);
    assign disp_wrap[2] = cptr_msb ^ (cptr_idx_q >= 6'd62);

    assign cptr_idx     = cptr_idx_q;

endmodule
