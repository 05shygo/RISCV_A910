`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_bht — 早预测用的 gshare BHT (香山 S1 早方向的简化对应)
//
// 256 行 × 4 slot × 2-bit 饱和计数器; 行索引 = 块 PC[11:4] ^ fold(16-bit PHR, 8)。
// BP0 给地址, BP1 出 4 个 slot 的方向; 早预测用它的方向, BP2 的长历史 TAGE
// 只做 override —— 这样 S2 override 的频率比"BTB base vs TAGE"低得多。
//
// 训练: 退休点, 只用条件分支; PHR 快照来自 chk[15:0]。
// ===========================================================================
module rv32ifu3_bht #(
    // 只用到 L1 的折叠窗口 (索引取 fold_idx[11:6]); 默认与 IFU3 TAGE_L1 一致。
    parameter [4:0] L1 = 5'd10
)(
    input  wire         clk,
    input  wire         rst,

    // ---- BP0 ----
    input  wire [ 31:0] rd_line_pc,
    input  wire [ 15:0] rd_phr,

    // ---- BP1 ----
    output wire [  3:0] dir,
    output wire [  3:0] strong_v, // 2-bit ctr 饱和在 00/11; BPU 只在强信心时用 BHT

    // ---- 退休点训练 ----
    input  wire         upd_vld,
    input  wire [ 31:0] upd_pc,
    input  wire         upd_taken,
    input  wire         upd_is_cond,
    input  wire [ 15:0] upd_phr
);

wire [23:0] fold_idx_rd;
wire [31:0] fold_tag_rd;
wire [23:0] fold_idx_upd;
wire [31:0] fold_tag_upd;

rv32ifu3_phr #(.L1(L1)) u_phr_rd
    (.phr(rd_phr),  .fold_idx(fold_idx_rd),  .fold_tag(fold_tag_rd));
rv32ifu3_phr #(.L1(L1)) u_phr_upd
    (.phr(upd_phr), .fold_idx(fold_idx_upd), .fold_tag(fold_tag_upd));

wire [7:0] rd_idx = rd_line_pc[11:4] ^ {2'b0, fold_idx_rd[11:6]};
reg  [7:0] q_idx;
always @(posedge clk) begin
    if (rst) q_idx <= 8'd0;
    else     q_idx <= rd_idx;
end

reg [7:0] tab [0:255];

wire [7:0] q_row = tab[q_idx];

assign dir[0] = q_row[1];
assign dir[1] = q_row[3];
assign dir[2] = q_row[5];
assign dir[3] = q_row[7];

// 00/11 才是强信心; 01/10 视为弱, BPU 回退到 BTB base.
assign strong_v[0] = (q_row[1:0] == 2'b00) || (q_row[1:0] == 2'b11);
assign strong_v[1] = (q_row[3:2] == 2'b00) || (q_row[3:2] == 2'b11);
assign strong_v[2] = (q_row[5:4] == 2'b00) || (q_row[5:4] == 2'b11);
assign strong_v[3] = (q_row[7:6] == 2'b00) || (q_row[7:6] == 2'b11);

wire [31:0] upd_line = {upd_pc[31:4], 4'b0};
wire [7:0]  upd_idx  = upd_line[11:4] ^ {2'b0, fold_idx_upd[11:6]};
wire [1:0]  upd_slot = upd_pc[3:2];

wire [1:0] old_ctr = tab[upd_idx][upd_slot*2 +: 2];
wire [1:0] inc_ctr = (old_ctr == 2'd3) ? 2'd3 : old_ctr + 2'd1;
wire [1:0] dec_ctr = (old_ctr == 2'd0) ? 2'd0 : old_ctr - 2'd1;

wire upd_ok = (^upd_pc !== 1'bx) && (^upd_taken !== 1'bx) &&
              (^upd_is_cond !== 1'bx) && (^upd_phr !== 1'bx);
wire upd_en = upd_vld && upd_is_cond && upd_ok;

integer i;
always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < 256; i = i + 1) begin
            // 01 = 弱 not-taken. 初始不是 00, 否则会被当成"强 not-taken"
            // 覆盖 BTB base; 冷分支应回退到 BTB.
            tab[i] <= {2'b01, 2'b01, 2'b01, 2'b01};
        end
    end else if (upd_en) begin
        tab[upd_idx][upd_slot*2 +: 2] <= upd_taken ? inc_ctr : dec_ctr;
    end
end

endmodule
