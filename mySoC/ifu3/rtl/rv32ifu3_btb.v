`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_btb — 香山式块 BTB (Phase 1a: 直接映射 + 每 slot 2-bit 方向)
//
// 结构:
//   * 16 B 行索引: 64 行, row = pc[9:4], tag = pc[15:10]
//   * 每行 4 个 slot (16 B 块内的 4 条 4 B 指令)
//   * 每 slot: {valid, type[1:0], target[31:0], ctr[1:0]}
//       type: 0=none, 1=条件分支, 2=JAL/JALR
//   * 条件分支的方向 base 就用 slot 的 2-bit 饱和计数器;
//     Phase 1b 的 TAGE 只做 "覆盖 base" 的 provider/alt, 不再单独维护 BHT。
//   * 读: BP0 给行地址, BP1 出行命中/slot 数据 (同步读)
//   * 训练: 退休点 (rtu_train_*), 同拍读写不同端口; 训练写对同拍预测只见旧值,
//     可接受 (下一拍就更新)。
//
// ⚠️ 条件分支 "没 taken" 时退休口给的是 pc+4, 不是分支目标; 所以:
//   * 新分配 slot 只在 taken / JAL / JALR 时做 (那时 target 才是真目标);
//   * 已存在 slot 的 cond 只在 taken 时刷新 target, not-taken 只更新计数器。
//   否则会把 pc+4 当成 taken 目标, 预测 taken 时跳错。
// ===========================================================================
module rv32ifu3_btb #(
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
    output wire [SLOTS*32-1:0]  slot_target,  // slot i 在 [i*32 +: 32]

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

localparam [1:0] T_NONE = 2'd0;
localparam [1:0] T_COND = 2'd1;
localparam [1:0] T_JUMP = 2'd2;

reg [SLOTS-1:0]    slot_vld_q  [0:NR-1];
reg [SLOTS*2-1:0]  slot_type_q [0:NR-1];
reg [SLOTS*2-1:0]  slot_ctr_q  [0:NR-1];
reg [SLOTS*32-1:0] slot_tgt_q  [0:NR-1];
reg                row_vld_q   [0:NR-1];
reg [TAG_BITS-1:0] row_tag_q   [0:NR-1];

// ---------------------------------------------------------------------------
// BP0 -> BP1 读流水
// ---------------------------------------------------------------------------
wire [ROW_AW-1:0]   rd_row = rd_pc[ROW_MSB:4];
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

wire q_row_hit = row_vld_q[q_row_q] && (row_tag_q[q_row_q] == q_tag_q);

assign slot_vld    = slot_vld_q[q_row_q] & {SLOTS{q_row_hit}};
assign slot_ctr    = slot_ctr_q[q_row_q];
assign slot_target = slot_tgt_q[q_row_q];

genvar g;
generate
for (g = 0; g < SLOTS; g = g + 1) begin : g_slot
    assign slot_cond[g] = slot_vld[g] && (slot_type_q[q_row_q][g*2 +: 2] == T_COND);
    assign slot_jump[g] = slot_vld[g] && (slot_type_q[q_row_q][g*2 +: 2] == T_JUMP);
end
endgenerate

// ---------------------------------------------------------------------------
// 训练 (退休点)
// ---------------------------------------------------------------------------
wire [ROW_AW-1:0]   u_row  = upd_pc[ROW_MSB:4];
wire [TAG_BITS-1:0] u_tag  = upd_pc[TAG_LSB+TAG_BITS-1:TAG_LSB];
wire [1:0]          u_slot = upd_pc[3:2];

wire        u_row_hit  = row_vld_q[u_row] && (row_tag_q[u_row] == u_tag);
wire        u_slot_vld = slot_vld_q[u_row][u_slot];
wire [1:0]  u_slot_typ = slot_type_q[u_row][u_slot*2 +: 2];
wire [1:0]  u_slot_ctr = slot_ctr_q[u_row][u_slot*2 +: 2];

wire [1:0] u_inc_ctr = (u_slot_ctr == 2'd3) ? 2'd3 : u_slot_ctr + 2'd1;
wire [1:0] u_dec_ctr = (u_slot_ctr == 2'd0) ? 2'd0 : u_slot_ctr - 2'd1;

wire u_is_jump  = upd_is_jal | upd_is_jalr;
wire u_allocate = upd_taken | u_is_jump;
wire [1:0] u_new_type = upd_is_cond ? T_COND : T_JUMP;
wire [1:0] u_new_ctr  = upd_taken ? 2'd3 : 2'd1;

// 训练口在复位后可能短暂给 X; 不能用 X 的 pc/target 写进表 (否则 hit/tag 变 X)
wire u_upd_ok = (^upd_pc !== 1'bx) && (^upd_target !== 1'bx) &&
                (^upd_taken !== 1'bx) && (^upd_is_cond !== 1'bx) &&
                (^upd_is_jal !== 1'bx) && (^upd_is_jalr !== 1'bx);

integer i;
always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < NR; i = i + 1) begin
            row_vld_q[i] <= 1'b0;
        end
    end else if (upd_vld && u_upd_ok) begin
        if (!u_row_hit) begin
            if (u_allocate) begin
                row_vld_q[u_row]  <= 1'b1;
                row_tag_q[u_row]  <= u_tag;
                slot_vld_q[u_row] <= {SLOTS{1'b0}};
                slot_type_q[u_row]<= {SLOTS*2{1'b0}};
                slot_ctr_q[u_row] <= {SLOTS*2{1'b0}};
                slot_vld_q[u_row][u_slot]             <= 1'b1;
                slot_type_q[u_row][u_slot*2 +: 2]     <= u_new_type;
                slot_tgt_q[u_row][u_slot*32 +: 32]    <= upd_target;
                slot_ctr_q[u_row][u_slot*2 +: 2]      <= u_new_ctr;
            end
        end else if (u_slot_vld) begin
            if (u_slot_typ == T_COND) begin
                slot_ctr_q[u_row][u_slot*2 +: 2] <= upd_taken ? u_inc_ctr : u_dec_ctr;
                if (upd_taken) begin
                    slot_tgt_q[u_row][u_slot*32 +: 32] <= upd_target;
                end
            end else if (u_slot_typ == T_JUMP) begin
                slot_ctr_q[u_row][u_slot*2 +: 2] <= 2'd3;
                slot_tgt_q[u_row][u_slot*32 +: 32] <= upd_target;
            end
        end else begin
            if (u_allocate) begin
                slot_vld_q[u_row][u_slot]             <= 1'b1;
                slot_type_q[u_row][u_slot*2 +: 2]     <= u_new_type;
                slot_tgt_q[u_row][u_slot*32 +: 32]    <= upd_target;
                slot_ctr_q[u_row][u_slot*2 +: 2]      <= u_new_ctr;
            end
        end
    end
end

// synopsys translate_off
always @(posedge clk) begin
    if (!rst && (^slot_vld === 1'bx)) begin
        $display("[IFU3-BTB] ERROR: slot_vld X qrow=%0d qtag=%h rowvld=%b rowtag=%h slvld=%b hit=%b rd_pc=%h",
                 q_row_q, q_tag_q, row_vld_q[q_row_q], row_tag_q[q_row_q],
                 slot_vld_q[q_row_q], q_row_hit, rd_pc);
        $fatal;
    end
end
// synopsys translate_on

endmodule
