`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu4_btb — 块 BTB (Phase 2: 64 行 × 4 slot, 阵列落 LUTRAM/BRAM)
//
// 结构:
//   * 16 B 行索引: 64 行, row = pc[9:4], tag = pc[15:10]
//   * 每行 4 个 slot (16 B 块内的 4 条 4 B 指令)
//   * 每 slot: {valid, type[1:0], target[15:0], ctr[1:0]}
//       type: 0=none, 1=条件分支, 2=JAL/JALR
//     目标只存低 16 位 (SoC 代码在 64 KB 内); 高位由取指 PC 的 [31:16] 还原。
//
// 存储:
//   * 行 = 91 bit {tag[5:0], row_vld, slot_vld[3:0], type[3:0][1:0],
//                  ctr[3:0][1:0], target[3:0][15:0]}
//   * 预测口: 1R1W 同步 RAM (BP0 给地址, BP1 出整行)
//   * 训练口: 异步读 LUTRAM + 同步写 (与改前的寄存器阵列同拍:
//     第 N 拍读旧行/算新行/写回都在同一拍完成, 不增加训练延迟)
//   * 上电由 init FSM 写零; init 完成前预测输出强制无效。
//
// 训练 (退休点):
//   * 新分配 slot 只在 taken / JAL / JALR 时做 (那时 target 才是真目标);
//   * 已存在 slot 的 cond 只在 taken 时刷新 target, not-taken 只更新计数器。
// ===========================================================================
module rv32ifu4_btb #(
    parameter ROW_AW = 6,
    parameter SLOTS  = 4
)(
    input  wire         clk,
    input  wire         rst,             // 高有效

    // ---- BP0: 行读地址 (精确 start PC; 内部会按 16 B 对齐) ----
    input  wire [ 31:0] rd_pc,

    // ---- BP1: 行命中 + 4 个 slot ----
    output wire [SLOTS-1:0]     slot_vld,
    output wire [SLOTS-1:0]     slot_cond,
    output wire [SLOTS-1:0]     slot_jump,
    output wire [SLOTS*2-1:0]   slot_ctr,     // slot i 在 [i*2 +: 2]
    output wire [SLOTS*16-1:0]  slot_target,  // slot i 在 [i*16 +: 16]

    // ---- 退休点训练 ----
    input  wire         upd_vld,
    input  wire [ 31:0] upd_pc,
    input  wire [ 31:0] upd_target,
    input  wire         upd_taken,
    input  wire         upd_is_cond,
    input  wire         upd_is_jal,
    input  wire         upd_is_jalr
);

localparam NR       = 1 << ROW_AW;
localparam TAG_BITS = 6;                 // pc[15:10], 64 KB 地址空间
localparam TAG_LSB  = ROW_AW + 4;        // 10
localparam ROW_MSB  = ROW_AW + 3;        // 9

localparam R_TAG  = 0;
localparam R_VLD  = R_TAG + TAG_BITS;
localparam R_SVLD = R_VLD + 1;
localparam R_TYPE = R_SVLD + SLOTS;
localparam R_CTR  = R_TYPE + SLOTS*2;
localparam R_TGT  = R_CTR + SLOTS*2;
localparam ROW_W  = R_TGT + SLOTS*16;

localparam [1:0] T_COND = 2'd1;
localparam [1:0] T_JUMP = 2'd2;

// ---------------------------------------------------------------------------
// 预测读流水: BP0 给行地址, BP1 出整行 (RAM 同步读)
// ---------------------------------------------------------------------------
wire [ROW_AW-1:0] rd_row = rd_pc[ROW_MSB:4];
wire [TAG_BITS-1:0] rd_tag = rd_pc[TAG_LSB+TAG_BITS-1:TAG_LSB];

reg [ROW_AW-1:0]   q_row_q;
reg [TAG_BITS-1:0] q_tag_q;

always @(posedge clk) begin
    if (rst) begin
        q_row_q <= {ROW_AW{1'b0}};
        q_tag_q <= {TAG_BITS{1'b0}};
    end else begin
        q_row_q <= rd_row;
        q_tag_q <= rd_tag;
    end
end

// ---------------------------------------------------------------------------
// 训练两级 (2026-10-19): A 拍寄存 row/tag/slot/控制/目标; B 拍异步读旧行 ->
// 组合更新 -> 写回. 相邻两笔更新同一 row 时, B 拍读到的旧行已含上一笔
// (写在同一沿), 无 RAW 丢失.
// ---------------------------------------------------------------------------
wire [ROW_AW-1:0]   u_row  = upd_pc[ROW_MSB:4];
wire [TAG_BITS-1:0] u_tag  = upd_pc[TAG_LSB+TAG_BITS-1:TAG_LSB];
wire [1:0]          u_slot = upd_pc[3:2];

wire        u_is_jump  = upd_is_jal | upd_is_jalr;
wire        u_allocate = upd_taken | u_is_jump;
wire [1:0]  u_new_type = upd_is_cond ? T_COND : T_JUMP;

// 训练口在复位后可能短暂给 X; 不能用 X 的 pc/target 写进表
wire u_upd_ok = (^upd_pc !== 1'bx) && (^upd_target !== 1'bx) &&
                (^upd_taken !== 1'bx) && (^upd_is_cond !== 1'bx) &&
                (^upd_is_jal !== 1'bx) && (^upd_is_jalr !== 1'bx);
wire u_we_comb = upd_vld && u_upd_ok;

reg [ROW_AW-1:0]   u_row_q;
reg [TAG_BITS-1:0] u_tag_q;
reg [1:0]          u_slot_q;
reg                u_allocate_q;
reg [1:0]          u_new_type_q;
reg                u_taken_q;
reg [15:0]         u_target_q;
reg                u_we_q;

always @(posedge clk) begin
    if (rst) begin
        u_row_q      <= {ROW_AW{1'b0}};
        u_tag_q      <= {TAG_BITS{1'b0}};
        u_slot_q     <= 2'd0;
        u_allocate_q <= 1'b0;
        u_new_type_q <= T_COND;
        u_taken_q    <= 1'b0;
        u_target_q   <= 16'd0;
        u_we_q       <= 1'b0;
    end else begin
        u_row_q      <= u_row;
        u_tag_q      <= u_tag;
        u_slot_q     <= u_slot;
        u_allocate_q <= u_allocate;
        u_new_type_q <= u_new_type;
        u_taken_q    <= upd_taken;
        u_target_q   <= upd_target[15:0];
        u_we_q       <= u_we_comb;
    end
end

wire [ROW_W-1:0] u_row_data;
wire [ROW_W-1:0] u_new_row;

wire [SLOTS-1:0]    old_svld = u_row_data[R_SVLD +: SLOTS];
wire [SLOTS*2-1:0]  old_type = u_row_data[R_TYPE +: SLOTS*2];
wire [SLOTS*2-1:0]  old_ctr  = u_row_data[R_CTR  +: SLOTS*2];
wire                old_hit  = u_row_data[R_VLD] &&
                               (u_row_data[R_TAG +: TAG_BITS] == u_tag_q);

wire [SLOTS*2-1:0] old_slot_type = old_type[u_slot_q*2 +: 2];
wire [1:0]         old_slot_ctr  = old_ctr [u_slot_q*2 +: 2];
wire [1:0]         inc_ctr = (old_slot_ctr == 2'd3) ? 2'd3 : old_slot_ctr + 2'd1;
wire [1:0]         dec_ctr = (old_slot_ctr == 2'd0) ? 2'd0 : old_slot_ctr - 2'd1;

// 组合更新: 与改前的寄存器阵列逐位同义
reg [ROW_W-1:0] u_new_row_c;
reg             u_we_c;
always @(*) begin
    u_new_row_c = u_row_data;
    u_we_c      = 1'b0;
    if (u_we_q) begin
        if (!old_hit) begin
            if (u_allocate_q) begin
                u_new_row_c = {ROW_W{1'b0}};
                u_new_row_c[R_TAG +: TAG_BITS] = u_tag_q;
                u_new_row_c[R_VLD] = 1'b1;
                u_new_row_c[R_SVLD + u_slot_q] = 1'b1;
                u_new_row_c[R_TYPE + u_slot_q*2 +: 2] = u_new_type_q;
                u_new_row_c[R_CTR  + u_slot_q*2 +: 2] =
                    u_taken_q ? 2'd3 : 2'd1;
                u_new_row_c[R_TGT  + u_slot_q*16 +: 16] = u_target_q;
                u_we_c = 1'b1;
            end
        end else if (old_svld[u_slot_q]) begin
            if (old_slot_type == T_COND) begin
                u_new_row_c[R_CTR + u_slot_q*2 +: 2] =
                    u_taken_q ? inc_ctr : dec_ctr;
                if (u_taken_q)
                    u_new_row_c[R_TGT + u_slot_q*16 +: 16] = u_target_q;
            end else begin
                u_new_row_c[R_CTR + u_slot_q*2 +: 2] = 2'd3;
                u_new_row_c[R_TGT + u_slot_q*16 +: 16] = u_target_q;
            end
            u_we_c = 1'b1;
        end else if (u_allocate_q) begin
            u_new_row_c[R_SVLD + u_slot_q] = 1'b1;
            u_new_row_c[R_TYPE + u_slot_q*2 +: 2] = u_new_type_q;
            u_new_row_c[R_CTR  + u_slot_q*2 +: 2] =
                u_taken_q ? 2'd3 : 2'd1;
            u_new_row_c[R_TGT  + u_slot_q*16 +: 16] = u_target_q;
            u_we_c = 1'b1;
        end
    end
end
assign u_new_row = u_new_row_c;

// ---------------------------------------------------------------------------
// init FSM: 64 拍写零; 完成前预测无效、训练不收
// ---------------------------------------------------------------------------
reg [ROW_AW-1:0] init_cnt;
reg              init_done;

always @(posedge clk) begin
    if (rst) begin
        init_cnt  <= {ROW_AW{1'b0}};
        init_done <= 1'b0;
    end else if (!init_done) begin
        if (init_cnt == NR-1)
            init_done <= 1'b1;
        init_cnt <= init_cnt + 1'b1;
    end
end

wire init_active = ~init_done;

wire                 wr_en   = init_active ? 1'b1 : (u_we_c & init_done);
wire [ROW_AW-1:0]    wr_addr = init_active ? init_cnt : u_row_q;
wire [ROW_W-1:0]     wr_data = init_active ? {ROW_W{1'b0}} : u_new_row;

// ---------------------------------------------------------------------------
// 预测口: LUTRAM 异步读 + 输出打拍 (2026-10-19)
//
// 原来用 SPRAM (BRAM), 其时钟→输出 1.8ns 直接挂在 BPU 的单拍预测环上
// (BTB 行输出 -> next PC -> BTB 地址)。换成 LUTRAM + 显式输出寄存器:
//   BP0: rd_row -> mem_pred[rd_row] (异步) -> row0_q
//   BP1: row0_q 参与预测 (与原来 SPRAM 寄存输出同拍)
// 环里只剩 FF clk-to-q (~0.2ns) + LUTRAM 读 (~0.4ns)，砍掉 BRAM 的 1.8ns。
// 面积: 多一份 64×91 LUTRAM，省掉一个 RAMB36。
// ---------------------------------------------------------------------------
(* ram_style = "distributed" *) reg [ROW_W-1:0] mem_pred [0:NR-1];
reg [ROW_W-1:0] row0_q;

always @(posedge clk) begin
    if (rst) row0_q <= {ROW_W{1'b0}};
    else     row0_q <= mem_pred[rd_row];
end

wire [ROW_W-1:0] row0_data = row0_q;

// ---------------------------------------------------------------------------
// 训练口: 异步读 LUTRAM (64 × 91), 同步写；预测阵列同写
// ---------------------------------------------------------------------------
(* ram_style = "distributed" *) reg [ROW_W-1:0] mem1 [0:NR-1];

integer i;
always @(posedge clk) begin
    if (wr_en) begin
        mem1[wr_addr]     <= wr_data;
        mem_pred[wr_addr] <= wr_data;
    end
end

assign u_row_data = mem1[u_row_q];

// ---------------------------------------------------------------------------
// 预测输出
// ---------------------------------------------------------------------------
wire [TAG_BITS-1:0] row_tag = row0_data[R_TAG +: TAG_BITS];
wire                row_vld = row0_data[R_VLD];
wire                row_hit = init_done && row_vld && (row_tag == q_tag_q);

wire [SLOTS-1:0]    row_svld = row0_data[R_SVLD +: SLOTS];
wire [SLOTS*2-1:0]  row_type = row0_data[R_TYPE +: SLOTS*2];

assign slot_vld    = row_svld & {SLOTS{row_hit}};
assign slot_ctr    = row0_data[R_CTR +: SLOTS*2];
assign slot_target = row0_data[R_TGT +: SLOTS*16];

genvar g;
generate
for (g = 0; g < SLOTS; g = g + 1) begin : g_slot
    assign slot_cond[g] = slot_vld[g] && (row_type[g*2 +: 2] == T_COND);
    assign slot_jump[g] = slot_vld[g] && (row_type[g*2 +: 2] == T_JUMP);
end
endgenerate

// synopsys translate_off
integer k;
initial begin
    for (k = 0; k < NR; k = k + 1) begin
        mem1[k]     = {ROW_W{1'b0}};
        mem_pred[k] = {ROW_W{1'b0}};
    end
end
// synopsys translate_on

endmodule
