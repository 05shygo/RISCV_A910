`timescale 1ns / 1ps
`include "defines.vh"

// ===========================================================================
// rv32ifu4_bvu — 前端分支重定向单元 (A76 BX 的 redirect 半边)
//
// 只做: IDU BIQ 发射口寄存一拍 -> BEU 比较 -> 本地重定向 + BPU PHR 修复。
// 完成/解析/写回/异常**不在这里** —— 仍由 IU 的 IU_beu_pipe 在 RTU 旁边完成,
// 避免把 completion/resolve 从 IFU 跨芯片送到 ROB (impl 实测该路径 97% 布线、
// 5.2ns)。两边吃同一个 BIQ 发射口, 比较逻辑重复但只有 ~30 LUT。
//
// 优先级 (由 top 统一合并): RTU trap/mret > BVU > IFU PredChecker > BPU S2。
// ===========================================================================
module rv32ifu4_bvu (
    input  wire        clk,
    input  wire        rst,                // 高有效
    input  wire        idu_flush,          // = rtu_yy_xx_flush

    // ---------------- IDU BIQ 发射口 ----------------
    input  wire        biq_sel,
    input  wire [ 6:0] biq_iid,
    input  wire [31:0] biq_src0,
    input  wire [31:0] biq_src1,
    input  wire [31:0] biq_pc,
    input  wire [31:0] biq_npc,
    input  wire        biq_taken,
    input  wire [  7:0] biq_rslt_sel,
    input  wire [31:0] biq_br_imme,
    input  wire [ 24:0] biq_chk,

    // ---------------- 重定向握手 ----------------
    input  wire        redirect_in_progress, // RTU 本拍在发 trap/mret
    input  wire        chgflw_mask,          // RTU 慢路冲刷期间屏蔽

    // ---------------- 本地重定向 (给 IFU top) ----------------
    output wire        bvu_redirect_vld,
    output wire [31:0] bvu_redirect_pc,
    output wire [ 24:0] bvu_btb_chk,
    output wire [ 31:0] bvu_btb_pc,
    output wire        bvu_btb_taken,
    output wire        bvu_btb_is_cond,

    // ---------------- BPiQ 写入 (解析点; 退休训练时按 iid 读) ----------------
    output wire        bvu_bpiq_wr,
    output wire [  6:0] bvu_bpiq_iid,
    output wire [ 31:0] bvu_bpiq_pc,
    output wire [ 15:0] bvu_bpiq_target,
    output wire        bvu_bpiq_taken,
    output wire        bvu_bpiq_is_cond,
    output wire        bvu_bpiq_is_jal,
    output wire        bvu_bpiq_is_jalr,
    output wire [ 24:0] bvu_bpiq_chk
);

// ---------------------------------------------------------------------------
// 边界寄存: IDU BIQ 发射口 → BVU
// ---------------------------------------------------------------------------
reg        s0_sel;
reg [ 6:0] s0_iid;
reg [31:0] s0_src0;
reg [31:0] s0_src1;
reg [31:0] s0_pc;
reg [31:0] s0_npc;
reg        s0_taken;
reg [ 7:0] s0_rslt_sel;
reg [31:0] s0_br_imme;
reg [24:0] s0_chk;

always @(posedge clk) begin
    if (rst || idu_flush) begin
        s0_sel      <= 1'b0;
        s0_iid      <= 7'd0;
        s0_src0     <= 32'd0;
        s0_src1     <= 32'd0;
        s0_pc       <= 32'd0;
        s0_npc      <= 32'd0;
        s0_taken    <= 1'b0;
        s0_rslt_sel <= 8'd0;
        s0_br_imme  <= 32'd0;
        s0_chk      <= 25'd0;
    end else begin
        s0_sel      <= biq_sel;
        s0_iid      <= biq_iid;
        s0_src0     <= biq_src0;
        s0_src1     <= biq_src1;
        s0_pc       <= biq_pc;
        s0_npc      <= biq_npc;
        s0_taken    <= biq_taken;
        s0_rslt_sel <= biq_rslt_sel;
        s0_br_imme  <= biq_br_imme;
        s0_chk      <= biq_chk;
    end
end

// ---------------------------------------------------------------------------
// 位序照 ct_idu_rf_pipe6_decd.sv:
//   [0]BEQ [1]BNE [2]BLT [3]BGE [4]BLTU [5]BGEU [6]JAL [7]JALR
// ---------------------------------------------------------------------------
wire sel_beq  = s0_rslt_sel[0];
wire sel_bne  = s0_rslt_sel[1];
wire sel_blt  = s0_rslt_sel[2];
wire sel_bge  = s0_rslt_sel[3];
wire sel_bltu = s0_rslt_sel[4];
wire sel_bgeu = s0_rslt_sel[5];
wire sel_jal  = s0_rslt_sel[6];
wire sel_jalr = s0_rslt_sel[7];

wire is_branch = sel_beq | sel_bne | sel_blt | sel_bge | sel_bltu | sel_bgeu;
wire is_jal    = sel_jal;
wire is_jalr   = sel_jalr;

reg [4:0] alu_op;
always @(*) begin
    if      (sel_bne)  alu_op = `ALU_BNE;
    else if (sel_blt)  alu_op = `ALU_BLT;
    else if (sel_bge)  alu_op = `ALU_BGE;
    else if (sel_bltu) alu_op = `ALU_BLTU;
    else if (sel_bgeu) alu_op = `ALU_BGEU;
    else               alu_op = `ALU_BEQ;
end

// JALR 的 B 口必须喂立即数 (BEU 里 npc_jalr = A + B)
wire [31:0] beu_b = is_jalr ? s0_br_imme : s0_src1;

wire        br_taken;
wire [31:0] actual_npc;
wire [31:0] target;
wire        mis_align;
wire        npc_mismatch;

BEU u_beu (
    .A            (s0_src0),
    .B            (beu_b),
    .pc           (s0_pc),
    .sext         (s0_br_imme),
    .pc4          (s0_pc + 32'd4),
    .pred_npc     (s0_npc),
    .alu_op       (alu_op),
    .is_branch    (is_branch),
    .is_jal       (is_jal),
    .is_jalr      (is_jalr),
    .br_taken     (br_taken),
    .actual_npc   (actual_npc),
    .target       (target),
    .mis_align    (mis_align),
    .npc_mismatch (npc_mismatch)
);

// ---------------------------------------------------------------------------
// EX1: 本地重定向 + 在途误预测的年龄门控
// ---------------------------------------------------------------------------
wire mispredict = s0_sel & npc_mismatch;
wire red_req    = mispredict & ~redirect_in_progress & ~chgflw_mask;

reg        mis_inflight_q;
reg [ 6:0] mis_iid_q;

wire [6:0] iid_gap = mis_iid_q - s0_iid;
wire       older   = ~iid_gap[6];

always @(posedge clk) begin
    if (rst) begin
        mis_inflight_q <= 1'b0;
        mis_iid_q      <= 7'd0;
    end else if (idu_flush) begin
        mis_inflight_q <= 1'b0;
        mis_iid_q      <= 7'd0;
    end else if (red_req & (~mis_inflight_q | older)) begin
        mis_inflight_q <= 1'b1;
        mis_iid_q      <= s0_iid;
    end
end

assign bvu_redirect_vld = red_req & (~mis_inflight_q | older);
assign bvu_redirect_pc  = actual_npc;

assign bvu_btb_chk     = s0_chk;
assign bvu_btb_pc      = s0_pc;
assign bvu_btb_taken   = br_taken | is_jal | is_jalr;
assign bvu_btb_is_cond = is_branch;

assign bvu_bpiq_wr      = s0_sel;
assign bvu_bpiq_iid     = s0_iid;
assign bvu_bpiq_pc      = s0_pc;
assign bvu_bpiq_target  = actual_npc[15:0];
assign bvu_bpiq_taken   = br_taken | is_jal | is_jalr;
assign bvu_bpiq_is_cond = is_branch;
assign bvu_bpiq_is_jal  = is_jal;
assign bvu_bpiq_is_jalr = is_jalr;
assign bvu_bpiq_chk     = s0_chk;

// 占位: biq_taken 不参与重定向判断 (BEU 用 npc_mismatch)
wire unused_taken = biq_taken ^ s0_taken ^ target[0] ^ mis_align;

// synopsys translate_off
always @(posedge clk) begin
    if (!rst && $test$plusargs("BVU_DBG") && (biq_sel || s0_sel))
        $display("[BVU] T=%0t biq_sel=%b biq_pc=%h biq_iid=%h biq_rslt=%b flush=%b | s0_sel=%b s0_pc=%h s0_iid=%h s0_rslt=%b",
                 $time, biq_sel, biq_pc, biq_iid, biq_rslt_sel, idu_flush,
                 s0_sel, s0_pc, s0_iid, s0_rslt_sel);
end
// synopsys translate_on

endmodule
