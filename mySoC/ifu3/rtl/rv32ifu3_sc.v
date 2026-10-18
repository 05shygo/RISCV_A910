`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_sc — 小型 path-SC (Statistical Corrector) 原型
//
// 定位: 不是替代 TAGE, 而是给 BP2 的 TAGE/base 结果做一次"强信心"纠正。
//   * 64 set × 4 way × {valid, tag[7:0], ctr[5:0]} = ~3.9 kbit
//   * set  = line_pc[9:4] ^ fold(PHR, SC_L, 6)
//   * tag  = {line_pc[15:10], slot} ^ fold(PHR, SC_L, 8)
//   * 每 slot 独立比较 4 way; hit 且 |ctr-32| >= THRESH 才 use
//   * 训练在退休点, 只收条件分支; hit 更新计数器, miss 用 RR 方式分配
//
// 与 TAGE 的差别:
//   * 计数器 6-bit (TAGE 3-bit), 更适合统计型难分支
//   * 4-way 有 tag, 冲突比 TAGE-lite 的 1-way 小
//   * 不引入 GHR/多表; 先用现有 16-bit PHR 的 path 相关做 A/B
//
// 读: BP0 给 rd_line_pc/rd_phr, 本模块寄存 set; BP1 用 tag_line_pc/tag_phr
//     算 tag/hit/ctr -> dir/use. 与 TAGE 的 BP0/BP1 时序一致.
// ===========================================================================
module rv32ifu3_sc #(
    parameter [4:0] SC_L   = 5'd12,
    parameter [5:0] THRESH = 6'd6
)(
    input  wire         clk,
    input  wire         rst,

    // ---- BP0: 索引 ----
    input  wire [31:0]  rd_line_pc,
    input  wire [15:0]  rd_phr,

    // ---- BP1: tag / 结果 ----
    input  wire [31:0]  tag_line_pc,
    input  wire [15:0]  tag_phr,
    input  wire [ 3:0]  slot_cond,
    output wire [ 3:0]  dir,       // 方向 (ctr MSB)
    output wire [ 3:0]  hit,
    output wire [ 3:0]  use,       // hit && 强信心

    // ---- 退休点训练 ----
    input  wire         upd_vld,
    input  wire [31:0]  upd_pc,
    input  wire         upd_taken,
    input  wire         upd_is_cond,
    input  wire [15:0]  upd_phr
);

// ---------------------------------------------------------------------------
// PHR folds (SC 自己的窗口)
// ---------------------------------------------------------------------------
wire [23:0] fold_idx_rd, fold_idx_upd;
wire [31:0] fold_tag_rd, fold_tag_upd;

rv32ifu3_phr #(.L0(SC_L)) u_phr_rd
    (.phr(rd_phr),  .fold_idx(fold_idx_rd),  .fold_tag(fold_tag_rd));
rv32ifu3_phr #(.L0(SC_L)) u_phr_upd
    (.phr(upd_phr), .fold_idx(fold_idx_upd), .fold_tag(fold_tag_upd));

// ---------------------------------------------------------------------------
// 64 set × 4 way; 每 way {valid, tag[7:0], ctr[5:0]}
// ---------------------------------------------------------------------------
reg [14:0] w0 [0:63];
reg [14:0] w1 [0:63];
reg [14:0] w2 [0:63];
reg [14:0] w3 [0:63];
reg [1:0]  rr_q [0:63];

// BP0 -> BP1 set
wire [5:0] rd_set = rd_line_pc[9:4] ^ fold_idx_rd[5:0];
reg  [5:0] q_set;
always @(posedge clk) begin
    if (rst) q_set <= 6'd0;
    else     q_set <= rd_set;
end

wire [14:0] q_w0 = w0[q_set];
wire [14:0] q_w1 = w1[q_set];
wire [14:0] q_w2 = w2[q_set];
wire [14:0] q_w3 = w3[q_set];

// ---------------------------------------------------------------------------
// BP1: 逐 slot tag/hit/ctr
// ---------------------------------------------------------------------------
genvar g;
generate
for (g = 0; g < 4; g = g + 1) begin : g_slot
    wire [7:0] tag_base = {tag_line_pc[15:10], g[1:0]};
    wire [7:0] tag      = tag_base ^ fold_tag_rd[7:0];

    wire m0 = q_w0[14] && (q_w0[13:6] == tag);
    wire m1 = q_w1[14] && (q_w1[13:6] == tag);
    wire m2 = q_w2[14] && (q_w2[13:6] == tag);
    wire m3 = q_w3[14] && (q_w3[13:6] == tag);

    wire       any = m0 | m1 | m2 | m3;
    wire [5:0] ctr = m0 ? q_w0[5:0] :
                     m1 ? q_w1[5:0] :
                     m2 ? q_w2[5:0] : q_w3[5:0];

    assign hit[g] = slot_cond[g] & any;
    assign dir[g] = slot_cond[g] & any & ctr[5];
    assign use[g] = slot_cond[g] & any &&
                    ((ctr >= (6'd32 + THRESH)) || (ctr <= (6'd32 - THRESH)));
end
endgenerate

// ---------------------------------------------------------------------------
// 训练: 退休点, 只收条件分支
// ---------------------------------------------------------------------------
wire [31:0] upd_line = {upd_pc[31:4], 4'b0};
wire [1:0]  upd_slot = upd_pc[3:2];

wire [5:0] upd_set = upd_line[9:4] ^ fold_idx_upd[5:0];
wire [7:0] upd_tag = {upd_line[15:10], upd_slot} ^ fold_tag_upd[7:0];

wire [14:0] u_w0 = w0[upd_set];
wire [14:0] u_w1 = w1[upd_set];
wire [14:0] u_w2 = w2[upd_set];
wire [14:0] u_w3 = w3[upd_set];

wire u_m0 = u_w0[14] && (u_w0[13:6] == upd_tag);
wire u_m1 = u_w1[14] && (u_w1[13:6] == upd_tag);
wire u_m2 = u_w2[14] && (u_w2[13:6] == upd_tag);
wire u_m3 = u_w3[14] && (u_w3[13:6] == upd_tag);
wire u_any = u_m0 | u_m1 | u_m2 | u_m3;
wire [1:0] u_hit_way = u_m0 ? 2'd0 : u_m1 ? 2'd1 : u_m2 ? 2'd2 : 2'd3;
wire [5:0] u_old_ctr = u_m0 ? u_w0[5:0] :
                       u_m1 ? u_w1[5:0] :
                       u_m2 ? u_w2[5:0] : u_w3[5:0];
wire [7:0] u_old_tag = u_m0 ? u_w0[13:6] :
                       u_m1 ? u_w1[13:6] :
                       u_m2 ? u_w2[13:6] : u_w3[13:6];

wire [5:0] u_inc = (u_old_ctr == 6'd63) ? 6'd63 : u_old_ctr + 6'd1;
wire [5:0] u_dec = (u_old_ctr == 6'd0)  ? 6'd0  : u_old_ctr - 6'd1;
wire [5:0] u_new_ctr = u_any ? (upd_taken ? u_inc : u_dec) :
                               (upd_taken ? 6'd33 : 6'd31);
wire [7:0] u_new_tag = u_any ? u_old_tag : upd_tag;
wire [1:0] u_wr_way = u_any ? u_hit_way : rr_q[upd_set];

wire u_upd_ok = (^upd_pc !== 1'bx) && (^upd_taken !== 1'bx) &&
                (^upd_is_cond !== 1'bx) && (^upd_phr !== 1'bx);
wire u_we = upd_vld && upd_is_cond && u_upd_ok;

integer i;
always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < 64; i = i + 1) begin
            w0[i] <= 15'd0;
            w1[i] <= 15'd0;
            w2[i] <= 15'd0;
            w3[i] <= 15'd0;
            rr_q[i] <= 2'd0;
        end
    end else if (u_we) begin
        case (u_wr_way)
            2'd0: w0[upd_set] <= {1'b1, u_new_tag, u_new_ctr};
            2'd1: w1[upd_set] <= {1'b1, u_new_tag, u_new_ctr};
            2'd2: w2[upd_set] <= {1'b1, u_new_tag, u_new_ctr};
            default: w3[upd_set] <= {1'b1, u_new_tag, u_new_ctr};
        endcase
        if (!u_any)
            rr_q[upd_set] <= rr_q[upd_set] + 2'd1;
    end
end

// synopsys translate_off
always @(posedge clk) begin
    if (!rst && (^use === 1'bx)) begin
        $display("[IFU3-SC] ERROR: use has X q_set=%0d", q_set);
        $fatal;
    end
end
// synopsys translate_on

endmodule
