`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_tage — 香山式 TAGE-lite (Phase 1b)
//
// 结构:
//   * 4 张 tagged 表, 每表 64 set × 1 way; 默认历史窗口 5/10/15/16 (16-bit PHR, 参数化)
//   * 每项 {tag[7:0], ctr[2:0]} + valid (valid 单独一个 64-bit 向量)
//   * set_i  = line_pc[9:4] ^ fold(phr, L_i, 6)
//   * tag_i  = {line_pc[15:10], slot[1:0]} ^ fold(phr, L_i, 8)
//   * provider = 命中的表里历史最长者; alt = 次长命中
//   * dir = provider 强信心 ? provider : (alt 命中 ? alt : base)
//     base 来自 BTB 的每 slot 2-bit 计数器
//
// 时序:
//   * BP0 给 rd_line_pc/rd_phr, 本模块寄存 set 地址
//   * BP1 用 q_set + tag_line_pc/tag_phr 算 tag/hit/provider/alt
//   * 读写都用寄存器阵列; 训练读与预测读是两套独立地址
//
// 训练 (退休点, 只对条件分支):
//   * 重算 set/tag; 有 provider 就更新它的 ctr; provider 弱/错时向更长历史的
//     下一张表分配; 没有 provider 就分配到 T0(最短表)。
//   * 1-way, 分配即覆盖; useful 计数先不做。
// ===========================================================================
module rv32ifu3_tage #(
    parameter [4:0] L0 = 5'd5,
    parameter [4:0] L1 = 5'd10,
    parameter [4:0] L2 = 5'd15,
    parameter [4:0] L3 = 5'd16
)(
    input  wire         clk,
    input  wire         rst,

    // ---- BP0: 读 ----
    input  wire [ 31:0] rd_line_pc,
    input  wire [ 15:0] rd_phr,

    // ---- BP1: tag/选择 ----
    input  wire [ 31:0] tag_line_pc,
    input  wire [ 15:0] tag_phr,
    input  wire [  3:0] slot_cond,
    input  wire [  3:0] base_dir,
    output wire [  3:0] dir,
    output wire [  3:0] hit_any,

    // ---- 退休点训练 ----
    input  wire         upd_vld,
    input  wire [ 31:0] upd_pc,
    input  wire         upd_taken,
    input  wire         upd_is_cond,
    input  wire [ 15:0] upd_phr
);

// ---------------------------------------------------------------------------
// PHR folds
// ---------------------------------------------------------------------------
wire [23:0] fold_idx_rd, fold_idx_tag, fold_idx_upd;
wire [31:0] fold_tag_rd, fold_tag_tag, fold_tag_upd;

rv32ifu3_phr #(.L0(L0), .L1(L1), .L2(L2), .L3(L3))
u_phr_rd  (.phr(rd_phr),  .fold_idx(fold_idx_rd),  .fold_tag(fold_tag_rd));
rv32ifu3_phr #(.L0(L0), .L1(L1), .L2(L2), .L3(L3))
u_phr_tag (.phr(tag_phr), .fold_idx(fold_idx_tag), .fold_tag(fold_tag_tag));
rv32ifu3_phr #(.L0(L0), .L1(L1), .L2(L2), .L3(L3))
u_phr_upd (.phr(upd_phr), .fold_idx(fold_idx_upd), .fold_tag(fold_tag_upd));

// ---------------------------------------------------------------------------
// 表存储
// ---------------------------------------------------------------------------
reg [10:0] tab0 [0:63];
reg [10:0] tab1 [0:63];
reg [10:0] tab2 [0:63];
reg [10:0] tab3 [0:63];
reg [63:0] vld0, vld1, vld2, vld3;

// ---------------------------------------------------------------------------
// BP0 -> BP1 读地址寄存
// ---------------------------------------------------------------------------
wire [5:0] rd_set0 = rd_line_pc[9:4] ^ fold_idx_rd[5:0];
wire [5:0] rd_set1 = rd_line_pc[9:4] ^ fold_idx_rd[11:6];
wire [5:0] rd_set2 = rd_line_pc[9:4] ^ fold_idx_rd[17:12];
wire [5:0] rd_set3 = rd_line_pc[9:4] ^ fold_idx_rd[23:18];

reg [5:0] q_set0, q_set1, q_set2, q_set3;
always @(posedge clk) begin
    if (rst) begin
        q_set0 <= 6'd0;
        q_set1 <= 6'd0;
        q_set2 <= 6'd0;
        q_set3 <= 6'd0;
    end else begin
        q_set0 <= rd_set0;
        q_set1 <= rd_set1;
        q_set2 <= rd_set2;
        q_set3 <= rd_set3;
    end
end

wire [10:0] q_tab0 = tab0[q_set0];
wire [10:0] q_tab1 = tab1[q_set1];
wire [10:0] q_tab2 = tab2[q_set2];
wire [10:0] q_tab3 = tab3[q_set3];

// ---------------------------------------------------------------------------
// BP1: 逐 slot tag/hit/provider
// ---------------------------------------------------------------------------
function [1:0] pick_prov_idx;
    input h3, h2, h1, h0;
    begin
        pick_prov_idx = h3 ? 2'd3 : h2 ? 2'd2 : h1 ? 2'd1 : 2'd0;
    end
endfunction

function pick_prov_hit;
    input h3, h2, h1, h0;
    begin
        pick_prov_hit = h3 | h2 | h1 | h0;
    end
endfunction

function [2:0] pick_prov_ctr;
    input h3, h2, h1, h0;
    input [2:0] c3, c2, c1, c0;
    begin
        pick_prov_ctr = h3 ? c3 : h2 ? c2 : h1 ? c1 : h0 ? c0 : 3'd0;
    end
endfunction

function pick_alt_hit;
    input h3, h2, h1, h0;
    begin
        pick_alt_hit = (h3 & (h2 | h1 | h0)) |
                       (h2 & (h1 | h0)) |
                       (h1 & h0);
    end
endfunction

function [2:0] pick_alt_ctr;
    input h3, h2, h1, h0;
    input [2:0] c3, c2, c1, c0;
    begin
        pick_alt_ctr = h3 ? (h2 ? c2 : h1 ? c1 : h0 ? c0 : 3'd0) :
                       h2 ? (h1 ? c1 : h0 ? c0 : 3'd0) :
                       h1 ? (h0 ? c0 : 3'd0) : 3'd0;
    end
endfunction

function tage_dir;
    input h3, h2, h1, h0;
    input [2:0] c3, c2, c1, c0;
    input       base;
    reg         has, alt_hit, is_weak;
    reg [2:0]   pctr, actr;
    begin
        has     = h3 | h2 | h1 | h0;
        pctr    = pick_prov_ctr(h3, h2, h1, h0, c3, c2, c1, c0);
        alt_hit = pick_alt_hit(h3, h2, h1, h0);
        actr    = pick_alt_ctr(h3, h2, h1, h0, c3, c2, c1, c0);
        is_weak = (pctr == 3'd3) || (pctr == 3'd4);
        if (!has)                     tage_dir = base;
        else if (is_weak && alt_hit)  tage_dir = actr[2];
        else                          tage_dir = pctr[2];
    end
endfunction

genvar g;
generate
for (g = 0; g < 4; g = g + 1) begin : g_slot
    wire [7:0] tag_base = {tag_line_pc[15:10], g[1:0]};
    wire [7:0] tag0 = tag_base ^ fold_tag_tag[7:0];
    wire [7:0] tag1 = tag_base ^ fold_tag_tag[15:8];
    wire [7:0] tag2 = tag_base ^ fold_tag_tag[23:16];
    wire [7:0] tag3 = tag_base ^ fold_tag_tag[31:24];

    wire h0 = vld0[q_set0] && (q_tab0[10:3] == tag0);
    wire h1 = vld1[q_set1] && (q_tab1[10:3] == tag1);
    wire h2 = vld2[q_set2] && (q_tab2[10:3] == tag2);
    wire h3 = vld3[q_set3] && (q_tab3[10:3] == tag3);

    wire [2:0] c0 = q_tab0[2:0];
    wire [2:0] c1 = q_tab1[2:0];
    wire [2:0] c2 = q_tab2[2:0];
    wire [2:0] c3 = q_tab3[2:0];

    assign dir[g]     = slot_cond[g] & tage_dir(h3, h2, h1, h0, c3, c2, c1, c0, base_dir[g]);
    assign hit_any[g] = slot_cond[g] & pick_prov_hit(h3, h2, h1, h0);
end
endgenerate

// ---------------------------------------------------------------------------
// 训练
// ---------------------------------------------------------------------------
wire [31:0] upd_line = {upd_pc[31:4], 4'b0};
wire [1:0]  upd_slot = upd_pc[3:2];

wire [5:0] upd_set0 = upd_line[9:4] ^ fold_idx_upd[5:0];
wire [5:0] upd_set1 = upd_line[9:4] ^ fold_idx_upd[11:6];
wire [5:0] upd_set2 = upd_line[9:4] ^ fold_idx_upd[17:12];
wire [5:0] upd_set3 = upd_line[9:4] ^ fold_idx_upd[23:18];

wire [7:0] upd_tag_base = {upd_line[15:10], upd_slot};
wire [7:0] upd_tag0 = upd_tag_base ^ fold_tag_upd[7:0];
wire [7:0] upd_tag1 = upd_tag_base ^ fold_tag_upd[15:8];
wire [7:0] upd_tag2 = upd_tag_base ^ fold_tag_upd[23:16];
wire [7:0] upd_tag3 = upd_tag_base ^ fold_tag_upd[31:24];

wire [10:0] u_tab0 = tab0[upd_set0];
wire [10:0] u_tab1 = tab1[upd_set1];
wire [10:0] u_tab2 = tab2[upd_set2];
wire [10:0] u_tab3 = tab3[upd_set3];

wire uh0 = vld0[upd_set0] && (u_tab0[10:3] == upd_tag0);
wire uh1 = vld1[upd_set1] && (u_tab1[10:3] == upd_tag1);
wire uh2 = vld2[upd_set2] && (u_tab2[10:3] == upd_tag2);
wire uh3 = vld3[upd_set3] && (u_tab3[10:3] == upd_tag3);

wire [2:0] uc0 = u_tab0[2:0];
wire [2:0] uc1 = u_tab1[2:0];
wire [2:0] uc2 = u_tab2[2:0];
wire [2:0] uc3 = u_tab3[2:0];

wire       u_prov_hit = pick_prov_hit(uh3, uh2, uh1, uh0);
wire [1:0] u_prov_idx = pick_prov_idx(uh3, uh2, uh1, uh0);
wire [2:0] u_prov_ctr = pick_prov_ctr(uh3, uh2, uh1, uh0, uc3, uc2, uc1, uc0);

// 选写哪张表: 无 provider -> T0; provider 错且不是最长表 -> 下一张更长的表;
// 否则写 provider。
wire u_prov_wrong = u_prov_hit && (u_prov_ctr[2] != upd_taken);
wire [1:0] u_sel = !u_prov_hit ? 2'd0 :
                   (u_prov_wrong && (u_prov_idx != 2'd3)) ? (u_prov_idx + 2'd1) :
                   u_prov_idx;

wire [5:0] u_set_sel = (u_sel == 2'd0) ? upd_set0 :
                       (u_sel == 2'd1) ? upd_set1 :
                       (u_sel == 2'd2) ? upd_set2 : upd_set3;
wire [7:0] u_tag_sel = (u_sel == 2'd0) ? upd_tag0 :
                       (u_sel == 2'd1) ? upd_tag1 :
                       (u_sel == 2'd2) ? upd_tag2 : upd_tag3;
wire [10:0] u_entry_sel = (u_sel == 2'd0) ? u_tab0 :
                          (u_sel == 2'd1) ? u_tab1 :
                          (u_sel == 2'd2) ? u_tab2 : u_tab3;
wire u_vld_sel = (u_sel == 2'd0) ? vld0[upd_set0] :
                 (u_sel == 2'd1) ? vld1[upd_set1] :
                 (u_sel == 2'd2) ? vld2[upd_set2] : vld3[upd_set3];

wire u_same = u_vld_sel && (u_entry_sel[10:3] == u_tag_sel);
wire [2:0] u_old_ctr = u_same ? u_entry_sel[2:0] : 3'd0;
wire [2:0] u_inc_ctr = (u_old_ctr == 3'd7) ? 3'd7 : u_old_ctr + 3'd1;
wire [2:0] u_dec_ctr = (u_old_ctr == 3'd0) ? 3'd0 : u_old_ctr - 3'd1;
wire [2:0] u_new_ctr = u_same ? (upd_taken ? u_inc_ctr : u_dec_ctr) :
                                 (upd_taken ? 3'd4 : 3'd3);

// 训练口在复位后可能短暂给 X; 不能用 X 的 pc/phr 写表
wire u_upd_ok = (^upd_pc !== 1'bx) && (^upd_taken !== 1'bx) &&
                (^upd_is_cond !== 1'bx) && (^upd_phr !== 1'bx);
wire u_we = upd_vld && upd_is_cond && u_upd_ok;

integer i;
always @(posedge clk) begin
    if (rst) begin
        vld0 <= 64'd0;
        vld1 <= 64'd0;
        vld2 <= 64'd0;
        vld3 <= 64'd0;
    end else if (u_we) begin
        case (u_sel)
            2'd0: begin tab0[u_set_sel] <= {u_tag_sel, u_new_ctr}; vld0[u_set_sel] <= 1'b1; end
            2'd1: begin tab1[u_set_sel] <= {u_tag_sel, u_new_ctr}; vld1[u_set_sel] <= 1'b1; end
            2'd2: begin tab2[u_set_sel] <= {u_tag_sel, u_new_ctr}; vld2[u_set_sel] <= 1'b1; end
            default: begin tab3[u_set_sel] <= {u_tag_sel, u_new_ctr}; vld3[u_set_sel] <= 1'b1; end
        endcase
    end
end

endmodule
