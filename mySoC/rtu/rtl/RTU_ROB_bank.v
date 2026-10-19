`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_ROB_bank — ROB 的一个 bank (8 项), A76 MCQ 式组织。
//
// 逻辑下标映射: idx[2:0] = bank, idx[5:3] = row。连续 iid 落在不同 bank,
// 所以一拍 3 条派遣/退休最多各占 3 个 bank, 每个 bank 每拍最多 1 个写口/1 个 pop。
//
// 读口: 每 bank 一个 3-bit row_q 指向"本 bank 下一个将退休的行" (= A76 的
//   preread_muxsel_q), head_data 是 bank 内 8:1 局部 mux。row_q 的选择子来自
//   寄存器, 读路径里没有 rptr 加法; 8 个 bank head 再由顶层做 3 个旋转 8:1
//   mux 组成 commit 窗口的下一个队头。
//
// 写口: 顶层把 3 条派遣 lane 按 bank 选成单口数据 (wr_data); 每表项的命中
//   用**当拍**派遣 (disp_acc/cptr_idx) 算好并寄存为 e_dsp_q, 下一拍写阵列。
//   寄存的 1 位使能可按 max_fanout 复制贴着表项 FF 放; 组合使能实测会把
//   一根网拉过整个 die (R14a -3.07 / R14b -3.87)。完成/解析/重放同理:
//   顶层只把 iid 扇到 8 个 bank, bank 内再与固定 row + 表项 WRAP 比较。
//
// 不变量: row_q = row((rptr + (BANK - rptr[2:0]) mod 8) mod 64)。
//   flush 时从 cptr_idx 重装 (rptr 同沿追到 cptr); 正常退休时只有本 bank 的
//   队头被 pop, row_q 前进一行。窗口新尾部读的是 rptr+3..rptr+5 的 bank,
//   与本拍被 pop 的 bank (rptr..rptr+pop_n-1, pop_n<=3) 不相交, 所以 head
//   读不会撞上同拍的清零。
// ---------------------------------------------------------------------------
(* keep_hierarchy = "yes" *)
module RTU_ROB_bank #(
    parameter integer BANK = 0
) (
    input  wire                cpu_clk,
    input  wire                cpu_rst,

    // ---- 派遣写口 ----
    // 数据由顶层按 bank 选成单口 (dacc_q/didx_q/ddata_q 的 3:1)。
    // 命中不直接比 dacc_q/didx_q: 用**当拍派遣** (disp_acc/cptr_idx) 算好,
    // 打入每表项一位的 dsp_q, 下一拍与 wr_data 对齐写阵列。这样
    // didx_q→比较→125 位使能网 的组合路径被 dsp_q 切断。
    input  wire [2:0]          disp_acc,
    input  wire [1:0]          ndisp,
    input  wire [`RTU_E_W-1:0] wr_data,

    // ---- 完成 (7 路) ----
    input  wire [6:0]          cmplt_vld,
    input  wire [6:0]          cmplt_iid0,
    input  wire [6:0]          cmplt_iid1,
    input  wire [6:0]          cmplt_iid2,
    input  wire [6:0]          cmplt_iid3,
    input  wire [6:0]          cmplt_iid4,
    input  wire [6:0]          cmplt_iid5,
    input  wire [6:0]          cmplt_iid6,

    // ---- store 重放 / 解析 ----
    input  wire                lsu_replay_vld,
    input  wire [6:0]          lsu_replay_iid,
    input  wire                resolve_vld,
    input  wire [6:0]          resolve_iid,
    input  wire                resolve_taken,
    input  wire                resolve_mispred,
    input  wire [31:0]         resolve_target,

    // ---- 冲刷 / 退休 ----
    input  wire                freeze_nxt,     // [R23] FSM busy 的下一拍值
    input  wire [1:0]          pop_n,          // 本拍退休条数; bank 用本地 rptr 副本判 pop

    output wire [`RTU_E_W-1:0] head_data,
    // [R21] head 的动态位 (下一拍值): {replay, cmplt, target, taken, mispred}。
    // 判退直接读它, 窗口不再存/匹配完成/解析/重放。
    output wire [`RTU_DYN_W-1:0] head_dyn
);

    localparam [2:0] BID = BANK;               // 常量: 本 bank 编号

    // [R23] 与 FSM 状态同沿装载的本地 busy 副本: 值等于本拍 fsm_busy,
    // 但每 bank 一根本地寄存器, clear/reload 不再吃全局 489 负载网。
    reg freeze_b_q;
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) freeze_b_q <= 1'b0;
        else         freeze_b_q <= freeze_nxt;
    end

    // -----------------------------------------------------------------------
    // 本地创造指针副本 (A76 的 per-bank 写指针思路)
    //   cptr 只有 6 位, 但顶层到 8 个 bank 的扇出/走线在布局实验里是 -1.9ns
    //   的头部 (cptr→e_dsp_q/row_q)。每个 bank 自己维护一份同步副本:
    //   cptr 不随 flush 归零, 每拍 +ndisp; reset 归零。顶层仍保留主 cptr
    //   (disp_wrap / 派遣回执), 两边同沿同 ndisp, 逐位一致。
    // -----------------------------------------------------------------------
    reg  [5:0] cptr_b_q;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            cptr_b_q <= 6'd0;
        else
            cptr_b_q <= cptr_b_q + {4'b0, ndisp};
    end

    // -----------------------------------------------------------------------
    // 本地退休指针副本 (rptr 的低 3 位 = bank id)
    //   与本地 cptr 同构: rptr 也是每拍 +pop_n、flush 时追到 cptr。放到 bank
    //   里以后, pop 判定 (rptr→e_pop_q) 不再从 robmisc 跨 die 扇到 8 个 bank。
    // -----------------------------------------------------------------------
    reg  [2:0] rptr_b_q;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            rptr_b_q <= 3'd0;
        else if (freeze_b_q)
            rptr_b_q <= cptr_b_q[2:0];
        else
            rptr_b_q <= rptr_b_q + {1'b0, pop_n};
    end

    wire is_rb0 = (rptr_b_q == BID);
    wire is_rb1 = ((rptr_b_q + 3'd1) == BID);
    wire is_rb2 = ((rptr_b_q + 3'd2) == BID);
    wire bnk_pop = (is_rb0 & (pop_n != 2'd0))
                 | (is_rb1 & pop_n[1])
                 | (is_rb2 & (&pop_n));


    // -----------------------------------------------------------------------
    // commit 读指针
    // -----------------------------------------------------------------------
    reg  [2:0] row_q;

    wire [2:0] bnk_flush_row = cptr_b_q[5:3]
                             + ((BID < cptr_b_q[2:0]) ? 3'd1 : 3'd0);

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            row_q <= 3'd0;
        else if (freeze_b_q)
            row_q <= bnk_flush_row;
        else if (bnk_pop)
            row_q <= row_q + 3'd1;
    end

    // -----------------------------------------------------------------------
    // [R22] 退休事件 C1 本地化 (A76 `dealloc_sel_c1`)
    //
    // 问题: 判退结果 (pop_n) 组合扇到 64 项 × 8 份 e_pop D 端 —— 实测一根
    // 881 负载的全局网, 跨 120 列走 7.3ns。
    // 做法: 每个 bank 记录**上一拍**的 rptr/row/pop_n, 下一拍用这些本地寄存器
    // 算 e_pop。清零时刻不变 (T 拍判退 -> T+1 本地 e_pop 有效 -> T+2 沿清零),
    // 但组合判退只扇到 8 bank 的 7 个本地 FF, 不再扇到 512 份 D 逻辑。
    // row_q/rptr_b_q 仍用 live pop_n (下一拍读 bank head 前必须已推进)。
    // -----------------------------------------------------------------------
    reg  [2:0] rptr_b_old_q;
    reg  [2:0] row_q_old_q;
    reg  [1:0] pop_n_old_q;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst || freeze_b_q) begin
            rptr_b_old_q <= 3'd0;
            row_q_old_q  <= 3'd0;
            pop_n_old_q  <= 2'd0;
        end else begin
            rptr_b_old_q <= rptr_b_q;
            row_q_old_q  <= row_q;
            pop_n_old_q  <= pop_n;
        end
    end

    wire is_old0 = (rptr_b_old_q == BID);
    wire is_old1 = ((rptr_b_old_q + 3'd1) == BID);
    wire is_old2 = ((rptr_b_old_q + 3'd2) == BID);
    wire pop_old_b = (is_old0 & (pop_n_old_q != 2'd0))
                   | (is_old1 & pop_n_old_q[1])
                   | (is_old2 & (&pop_n_old_q));

    // -----------------------------------------------------------------------
    // 完成/解析/重放的 bank 预译码 (顶层 iid 扇出到此为止)
    // -----------------------------------------------------------------------
    wire [6:0] cmplt_b;
    assign cmplt_b[0] = cmplt_vld[0] & (cmplt_iid0[2:0] == BID);
    assign cmplt_b[1] = cmplt_vld[1] & (cmplt_iid1[2:0] == BID);
    assign cmplt_b[2] = cmplt_vld[2] & (cmplt_iid2[2:0] == BID);
    assign cmplt_b[3] = cmplt_vld[3] & (cmplt_iid3[2:0] == BID);
    assign cmplt_b[4] = cmplt_vld[4] & (cmplt_iid4[2:0] == BID);
    assign cmplt_b[5] = cmplt_vld[5] & (cmplt_iid5[2:0] == BID);
    assign cmplt_b[6] = cmplt_vld[6] & (cmplt_iid6[2:0] == BID);

    wire res_b = resolve_vld    & (resolve_iid[2:0]    == BID);
    wire rep_b = lsu_replay_vld & (lsu_replay_iid[2:0] == BID);

    // -----------------------------------------------------------------------
    // 8 个表项
    // -----------------------------------------------------------------------
    wire [`RTU_E_W-1:0] e_q [0:7];
    wire [`RTU_E_W-1:0] e_d [0:7];
    wire [`RTU_E_W-1:0] e_u [0:7];   // [R21] 自更新值 (不含 pop/disp 优先级)

    genvar gr;
    generate
    for (gr = 0; gr < 8; gr = gr + 1) begin : g_entry
        localparam [2:0] ROW = gr;
        localparam [5:0] IDX = {ROW, BID};

        // 派遣命中在**当拍**算 (disp_acc/cptr_idx), 打一拍后与 wr_data 对齐。
        // 寄存的 1 位使能可以按 max_fanout 复制, 贴着本项 125 个 D mux 放;
        // 组合使能 (R14a 的 bank 级行译码 / R14b 的每项比较) 实测会拉出
        // 6.2~9ns 的跨 die 走线。
        wire e_hit_d0 = disp_acc[0] & (cptr_b_q == IDX);
        wire e_hit_d1 = disp_acc[1] & ((cptr_b_q + 6'd1) == IDX);
        wire e_hit_d2 = disp_acc[2] & ((cptr_b_q + 6'd2) == IDX);

        // disp_freeze 已在顶层把 disp_acc 清 0 ⇒ e_hit 全 0, 不需要再门控。
        // (带上它会让 flush FSM 的高扇出网一路拉到每个 e_dsp_q: 实测 900 条。)
        (* max_fanout = 8 *) reg e_dsp_q;
        always @(posedge cpu_clk or posedge cpu_rst) begin
            if (cpu_rst)
                e_dsp_q <= 1'b0;
            else
                e_dsp_q <= e_hit_d0 | e_hit_d1 | e_hit_d2;
        end

        // [R22] pop 清零用上一拍记录的事件 (C1 本地化): 清零沿与原设计相同
        // (判退 T -> T+1 组合有效 -> T+2 沿清零), 但不再有全局高扇出 D 网。
        wire e_pop_now = pop_old_b & (row_q_old_q == ROW);

        wire e_cmplt =
              (cmplt_b[0] && (cmplt_iid0[5:3] == ROW) && (cmplt_iid0[6] == e_q[gr][`RTU_E_WRAP]))
           || (cmplt_b[1] && (cmplt_iid1[5:3] == ROW) && (cmplt_iid1[6] == e_q[gr][`RTU_E_WRAP]))
           || (cmplt_b[2] && (cmplt_iid2[5:3] == ROW) && (cmplt_iid2[6] == e_q[gr][`RTU_E_WRAP]))
           || (cmplt_b[3] && (cmplt_iid3[5:3] == ROW) && (cmplt_iid3[6] == e_q[gr][`RTU_E_WRAP]))
           || (cmplt_b[4] && (cmplt_iid4[5:3] == ROW) && (cmplt_iid4[6] == e_q[gr][`RTU_E_WRAP]))
           || (cmplt_b[5] && (cmplt_iid5[5:3] == ROW) && (cmplt_iid5[6] == e_q[gr][`RTU_E_WRAP]))
           || (cmplt_b[6] && (cmplt_iid6[5:3] == ROW) && (cmplt_iid6[6] == e_q[gr][`RTU_E_WRAP]));

        wire e_res = res_b && (resolve_iid[5:3] == ROW) && (resolve_iid[6] == e_q[gr][`RTU_E_WRAP]);
        wire e_rep = rep_b && (lsu_replay_iid[5:3] == ROW) && (lsu_replay_iid[6] == e_q[gr][`RTU_E_WRAP]);

        RTU_ROB_entry u_entry (
            .cpu_clk       (cpu_clk),
            .cpu_rst       (cpu_rst),
            .disp_en       (e_dsp_q),
            .disp_data     (wr_data),
            .pop_en        (e_pop_now),
            .reload_en     (1'b0),
            .reload_data   ({`RTU_E_W{1'b0}}),
            .cmplt_hit     (e_cmplt),
            .replay_set    (e_rep),
            .resolve_hit   (e_res),
            .resolve_taken (resolve_taken),
            .resolve_mispred(resolve_mispred),
            .resolve_target(resolve_target),
            .flush_clr     (freeze_b_q),
            .entry_q       (e_q[gr]),
            .entry_d       (e_d[gr]),
            .entry_upd     (e_u[gr])
        );
    end
    endgenerate

    // -----------------------------------------------------------------------
    // bank head: 8:1 局部 mux, 选择子 row_q 是寄存器
    // -----------------------------------------------------------------------
    assign head_data = e_q[row_q];

    // [R21] head 的动态位取**下一拍值**: 同拍完成/解析/重放 (e_cmplt/e_res/e_rep)
    // 已经叠在 e_u 上, 所以判退在"表项刚成为队头"的那一拍就能看到。
    // 不能用 e_d: pop 优先级会把本拍退休的队头清成 0。
    wire [`RTU_E_W-1:0] head_upd = e_u[row_q];
    assign head_dyn = { head_upd[`RTU_E_REPLAY],
                        head_upd[`RTU_E_CMPLT],
                        head_upd[`RTU_E_TARGET],
                        head_upd[`RTU_E_TAKEN],
                        head_upd[`RTU_E_MISPRED] };

endmodule
