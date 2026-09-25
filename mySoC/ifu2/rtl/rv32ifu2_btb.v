`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_btb — 按取指块索引的分支目标缓冲 (块 BTB)
//
// 一行 = 一个 16 B 取指块 = 4 个 slot。**一次查表覆盖整块**, F1 按 slot 取用,
// 不需要二次查表 —— 这是 2 级流水能成立的关键: 预测必须在**指令译码之前**就绪,
// 否则 PC 回不到 F0。
//
// 每个 slot 存 {valid, 类型, 2 位方向计数器, 目标}:
//   * 一个 slot 同时管目标与方向 ⇒ 最简的"块内双模态(bimodal)"预测器。
//     索引里天然带 PC 位 (块地址), 正好补上原 BHT "行索引一位 PC 都没有" 的
//     结构性短板 (见 memory bp-class3-root-cause / bp-area-frontier)。
//   * 类型区分 条件分支 / JAL / JALR: 后两者恒 taken, 目标来自表而非立即数。
//
// 索引与标签 (思路同 ifu_rv32i 的 L1 BTB, 但表小得多、做成同步读以配合顶层
// "F0 给地址、F1 用结果" 的时序):
//   row = pc[ROW_AW+3 : 4],  tag = pc[31 : ROW_AW+4]
//
// ⚠️ **标签必须随行数一起加宽**。只截索引不拓宽标签的话, 被丢掉的高位不进标签,
// 不同 PC 会**假命中**并拿到别人的目标 —— 那是"取错指令", 比真实的冲突 miss 糟得多。
// (原面积实验专门记过这条: memory bp-area-vs-accuracy.md "缩放模型的关键点"。)
//
// 训练 (EX 级回送):
//   * 行标签不匹配 / slot 无效 ⇒ 整行换标签 + 分配该 slot, 计数器按本次结果播种;
//   * slot 有效 ⇒ 计数器饱和 ±1, 且本次 taken 时刷新目标 (JALR 的目标会变)。
// ===========================================================================
module rv32ifu2_btb #(
    parameter ROW_AW = 6,              // 行数 = 2^ROW_AW (默认 64 行 × 4 slot = 256 项)
    parameter SLOTS  = 4
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- F0: 用"下一个取指地址"索引 (与 i-cache 同一拍、同一地址) ----
    input  wire [ 31:0] rd_pc,

    // ---- F1: 结果 (与 q_pc 同属一次取指) ----
    output wire [SLOTS-1:0]       slot_vld,     // 该 slot 有效 (已含行命中)
    output wire [SLOTS-1:0]       slot_cond,    // 该 slot 是条件分支 (方向问 BHT)
    output wire [SLOTS-1:0]       slot_jmp,     // 该 slot 是 JAL/JALR (恒 taken)
    output wire [SLOTS*32-1:0]    slot_target,  // slot i 在 [i*32 +: 32]
    output wire                   init_done,

    // ---- 训练 (EX 级, 1 拍脉冲) ----
    input  wire         upd_vld,
    input  wire [ 31:0] upd_pc,        // 解析掉的那条控制转移指令的 PC
    input  wire         upd_taken,     // 实际跳了没有 (JAL/JALR 恒 1)
    input  wire [ 31:0] upd_target,    // 实际目标 (upd_taken=0 时无意义)
    input  wire         upd_cond,
    input  wire         upd_jal,
    input  wire         upd_jalr
);

localparam NR_ROWS  = 1 << ROW_AW;
localparam TAG_LSB  = ROW_AW + 4;
localparam TAG_BITS = 32 - TAG_LSB;

// slot 字段布局。
// ⚠️ **这里不存方向计数器** —— 方向统一由 rv32ifu2_bht (gshare) 给。早先版本每
// slot 带一个 2 位计数器当"块内双模态", 但它在严格交替的模式上恒错 0.19%,
// 而方向本来就是 gshare 的活; 两处各存一份只会让训练走两条路, 必然后悔。
localparam SL_VLD      = 0;
localparam SL_COND     = 1;
localparam SL_JAL      = 2;
localparam SL_JALR     = 3;
localparam SL_TGT_BASE = 4;                 // 30 位: target[31:2]
localparam SLOT_W      = 34;
localparam ROW_W       = SLOTS * SLOT_W;

// ---------------------------------------------------------------------------
// 表: 数据行 + 行标签 (行标签 bit[TAG_BITS] = 行有效)
// ---------------------------------------------------------------------------
reg [ROW_W-1:0]    dat_q [0:NR_ROWS-1];
reg [TAG_BITS:0]   tag_q [0:NR_ROWS-1];

wire [ROW_AW-1:0]   rd_row = rd_pc[TAG_LSB-1:4];
wire [TAG_BITS-1:0] rd_tag = rd_pc[31:TAG_LSB];

reg [ROW_AW-1:0]   q_row_q;
reg [TAG_BITS-1:0] q_tag_q;

always @(posedge clk) begin
    q_row_q <= rd_row;
    q_tag_q <= rd_tag;
end

wire [TAG_BITS:0] q_rtag   = tag_q[q_row_q];
wire              q_row_hit = q_rtag[TAG_BITS] & (q_rtag[TAG_BITS-1:0] == q_tag_q);
wire [ROW_W-1:0]  q_dat     = dat_q[q_row_q];

// ---------------------------------------------------------------------------
// 逐 slot 展开 (generate: 四个槽的电路完全相同, 手写四遍容易漏改)
// ---------------------------------------------------------------------------
genvar g;
generate
for (g = 0; g < SLOTS; g = g + 1) begin : g_slot
    wire [SLOT_W-1:0] s = q_dat[g*SLOT_W +: SLOT_W];
    wire        vld   = s[SL_VLD];
    wire        jal   = s[SL_JAL];
    wire        jalr  = s[SL_JALR];
    wire [31:0] tgt   = {s[SL_TGT_BASE +: 30], 2'b00};

    assign slot_vld[g]    = q_row_hit & vld;
    assign slot_cond[g]   = s[SL_COND];
    assign slot_jmp[g]    = jal | jalr;
    assign slot_target[g*32 +: 32] = tgt;
end
endgenerate

// ---------------------------------------------------------------------------
// 训练
// ---------------------------------------------------------------------------
wire [ROW_AW-1:0]   u_row  = upd_pc[TAG_LSB-1:4];
wire [TAG_BITS-1:0] u_tag  = upd_pc[31:TAG_LSB];
wire [1:0]          u_slot = upd_pc[3:2];

wire [TAG_BITS:0]   u_rtag  = tag_q[u_row];
wire                u_rowok = u_rtag[TAG_BITS] & (u_rtag[TAG_BITS-1:0] == u_tag);
wire [ROW_W-1:0]    u_dat   = dat_q[u_row];
wire [SLOT_W-1:0]   u_s     = u_dat[u_slot*SLOT_W +: SLOT_W];

// 目标只在"本次真的跳了"时刷新。不跳时核心给的是 pc+4, 那是顺序地址不是跳转目标。
//
// ⚠️ 不跳且**这一行还没写过**时, 旧目标字段是 X (寄存器阵列上电为 X, 初始化扫描
// 只清 tag 的 valid 位, 不清数据行)。早期版本这里直接拷旧字段, 于是"一条从没跳过
// 的条件分支"会以 valid=1 + **X 的目标**进表; 之后只要 BHT 把它预测成 taken,
// next_pc 就变成 X, 整条前端从头烂掉 —— 表现为 CoreMark 跑到 5 万多拍突然
// PC 全 X, 而所有短用例都测不出来(短用例里没有"先分配后翻向"的足够长历史)。
// 所以: 旧字段不可信时一律填 0。
wire slot_old_ok = u_rowok & u_s[SL_VLD];
wire [31:0] new_target = upd_taken        ? upd_target
                       : slot_old_ok      ? {u_s[SL_TGT_BASE +: 30], 2'b00}
                       :                    32'b0;

wire [SLOT_W-1:0] new_s = {
    new_target[31:2],       // [33:4] 30 位
    upd_jalr,               // [3]
    upd_jal,                // [2]
    upd_cond,               // [1]
    1'b1                    // [0] valid
};

// 把新 slot 写回行。行标签不匹配 ⇒ 整行作废 (行粒度替换), 其余 slot 填 0。
// 用 generate 逐 slot 拼, 比"移位+掩码"那种写法可读得多, 也不容易在 SLOTS 变化时静默出错。
wire [ROW_W-1:0] upd_row_next;
generate
for (g = 0; g < SLOTS; g = g + 1) begin : g_upd
    assign upd_row_next[g*SLOT_W +: SLOT_W] =
        (g == u_slot) ? new_s
                      : (u_rowok ? u_dat[g*SLOT_W +: SLOT_W] : {SLOT_W{1'b0}});
end
endgenerate

// ---------------------------------------------------------------------------
// 初始化扫描
//
// 必须把行标签的 valid 位清掉: 寄存器阵列上电是 X, 而
// `q_row_hit = tag_vld & (tag == ...)` 在有 X 时是 **X 而不是 0**, 会一路传到
// slot_vld → 截断位置 → next_pc。所以不能靠"valid 位自己会拦"。
// 与 i-cache 用同一套做法 (扫描而非复位 for 循环), 将来换 SRAM 宏不用改控制。
// ---------------------------------------------------------------------------
reg              init_done_q;
reg [ROW_AW:0]   init_cnt_q;

assign init_done = init_done_q;

always @(posedge clk) begin
    if (rst) begin
        init_done_q <= 1'b0;
        init_cnt_q  <= {(ROW_AW+1){1'b0}};
    end else if (!init_done_q) begin
        tag_q[init_cnt_q[ROW_AW-1:0]] <= {(TAG_BITS+1){1'b0}};
        if (init_cnt_q == (NR_ROWS-1)) init_done_q <= 1'b1;
        init_cnt_q <= init_cnt_q + 1'b1;
    end else if (upd_vld) begin
        dat_q[u_row] <= upd_row_next;
        tag_q[u_row] <= {1'b1, u_tag};
    end
end

endmodule
