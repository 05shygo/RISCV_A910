`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_bht — gshare 方向预测表 (PC ⊕ 全局历史)
//
// 这是对原 BHT 那条"没有走完的路"的正面回应。实测结论是:
//   * 原设计方向表的**行索引一位 PC 都没有**, 只吃历史 ⇒ 掺 PC 是唯一能在小表上
//     继续回收准确率的手段 (memory bp-area-frontier-2026-09-24 §"每比特收益表" 之后)。
//   * 类 3(交替) 卡在 50% 的病因最终定到**读索引与写索引的 GHR 位窗不一致**:
//     读侧 plane 来自重读选择阵列、offset 用实时 vghr_q; 写侧 plane 来自随包锁存的
//     cur_sel_rst、offset 用随包锁存的 cur_ghr ⇒ 类 3 读到的 21 个地址**整个仿真里
//     收到 0 次写** (memory bp-class3-root-cause 第五轮)。
// 本模块从结构上排除这一类错误: **索引只有一个公式, 读和写都调它**,
// 且写入用的 GHR 是随指令走完全程的那份快照 (chk), 不是"写的时候再读一次"。
//
// 行 = 一个 16 B 取指块 = 4 个 slot × 2 位饱和计数器, 与 rv32ifu2_btb 同索引,
// 这样一次查表就能给出整块每个 slot 的方向 —— 预测必须在译码之前就绪。
//
// 索引: idx = pc[ROW_AW+3:4] ^ fold(ghr)
//   fold 把 GHR 折到 ROW_AW 位: 低位直接异或, 高位折回来。原设计用"截位"当
//   折叠, 实测折叠比截位在 branch_bench 上省 3.2% 周期 (BP_PRE_FOLD 那组对比),
//   所以这里默认就是折叠。
// ===========================================================================
module rv32ifu2_bht #(
    parameter ROW_AW = 9,              // 512 行 × 8 bit = 4 Kbit
    parameter GHR_W  = 12,
    parameter SLOTS  = 4
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- F0: 用"下一个取指地址" + 该块生效时的 GHR 索引 ----
    input  wire [ 31:0]     rd_pc,
    input  wire [GHR_W-1:0] rd_ghr,

    // ---- F1: 逐 slot 的方向 (2 位计数器的**高位**就是预测 taken) ----
    output wire [SLOTS*2-1:0] slot_ctr,
    output wire               init_done,

    // ---- 训练 (EX 级, 1 拍脉冲) ----
    input  wire             upd_vld,
    input  wire [ 31:0]     upd_pc,
    input  wire [GHR_W-1:0] upd_ghr,   // 该分支**之前**的 GHR (随指令带的快照)
    input  wire [  1:0]     upd_slot,  // = upd_pc[3:2]
    input  wire             upd_taken
);

localparam NR_ROWS  = 1 << ROW_AW;
localparam SLOT_BITS = 2;
localparam ROW_W    = SLOTS * SLOT_BITS;

// ---------------------------------------------------------------------------
// 唯一的索引公式: 读、写、恢复三处共用。
// 任何"读走一个窗口、写走另一个窗口"的改动都会重现类 3 那个病, 别改。
// ---------------------------------------------------------------------------
function [ROW_AW-1:0] gshare_index;
    input [31:0]     pc;
    input [GHR_W-1:0] ghr;
    integer i;
    reg [ROW_AW-1:0] f;
    begin
        f = {ROW_AW{1'b0}};
        for (i = 0; i < GHR_W; i = i + 1)
            f[i % ROW_AW] = f[i % ROW_AW] ^ ghr[i];
        gshare_index = pc[ROW_AW+3:4] ^ f;
    end
endfunction

// ---------------------------------------------------------------------------
// 表 + 同步读 (与 i-cache / BTB 同一拍: 地址在 F0, 结果在 F1)
// ---------------------------------------------------------------------------
reg [ROW_W-1:0] ctr_q [0:NR_ROWS-1];

wire [ROW_AW-1:0] rd_idx = gshare_index(rd_pc, rd_ghr);

reg [ROW_AW-1:0] q_idx_q;

always @(posedge clk) q_idx_q <= rd_idx;

assign slot_ctr = ctr_q[q_idx_q];

// ---------------------------------------------------------------------------
// 训练: 同一个索引公式 + 随指令带过来的 GHR 快照
// ---------------------------------------------------------------------------
wire [ROW_AW-1:0] u_idx = gshare_index(upd_pc, upd_ghr);

wire [ROW_W-1:0] u_row;
assign u_row = ctr_q[u_idx];
wire [ROW_W-1:0] u_row_next;
wire [1:0]       u_ctr = u_row[upd_slot*SLOT_BITS +: SLOT_BITS];

function [1:0] ctr_next;
    input [1:0] c;
    input       taken;
    begin
        if (taken) ctr_next = (c == 2'b11) ? 2'b11 : (c + 2'd1);
        else       ctr_next = (c == 2'b00) ? 2'b00 : (c - 2'd1);
    end
endfunction

wire [1:0] u_new = ctr_next(u_ctr, upd_taken);

// 逐 slot 拼回去, 比"移位+掩码"可读, 也不会在 SLOTS 变化时静默出错
genvar gu;
generate
for (gu = 0; gu < SLOTS; gu = gu + 1) begin : g_upd
    assign u_row_next[gu*SLOT_BITS +: SLOT_BITS] =
        (gu == upd_slot) ? u_new : u_row[gu*SLOT_BITS +: SLOT_BITS];
end
endgenerate

// ---------------------------------------------------------------------------
// 初始化扫描
//
// 与 BTB / i-cache 同样的理由: 寄存器阵列上电是 X, 而计数器的 X 会让
// "预测 taken" 变成 X 一路传到 next_pc。清 NR_ROWS 个 8 位行很便宜。
// ---------------------------------------------------------------------------
reg            init_done_q;
reg [ROW_AW:0] init_cnt_q;

assign init_done = init_done_q;

always @(posedge clk) begin
    if (rst) begin
        init_done_q <= 1'b0;
        init_cnt_q  <= {(ROW_AW+1){1'b0}};
    end else if (!init_done_q) begin
        ctr_q[init_cnt_q[ROW_AW-1:0]] <= {ROW_W{1'b0}};
        if (init_cnt_q == (NR_ROWS-1)) init_done_q <= 1'b1;
        init_cnt_q <= init_cnt_q + 1'b1;
    end else if (upd_vld) begin
        ctr_q[u_idx] <= u_row_next;
    end
end

endmodule
