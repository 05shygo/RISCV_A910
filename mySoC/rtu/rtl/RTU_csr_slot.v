`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_csr_slot — CSR 单槽 + 在途门控 (§4.3 的省资源项, 表项外的 27 bit)。
//
// 取舍: csr_addr(12)+csr_op(3)+csr_imm(5)+src1_preg(7) = 27 bit。
//   放进表项要 27 × 64 = 1.7 Kb; 而它们**只在 CSR 指令退休那一拍**被消费
//   (不参与判退、不在 P1 链上), 抽成单槽只要 27 bit, 还让退休级少读 4 个
//   64 选 1 的字段 —— 时序是正向的。
//   代价: 同一时刻只允许一条 CSR 在途, 第二条到了停派遣 (csr_inflight → disp_stall)。
//   CSR 在 CoreMark 里几乎不出现, 实测代价 ≈ 0。
//
// 谁写: 派遣那拍挑**第一条 is_csr 的车道**写进来 (在途唯一, 不会有第二条)。
// 谁清: 该条退休那一拍 / 冲刷。
// ---------------------------------------------------------------------------
module RTU_csr_slot (
    input  wire        cpu_clk,
    input  wire        cpu_rst,

    // 派遣 (已按车道拆好; 父模块保证 lane_vld 只对"要写槽"的那条有效)
    input  wire [2:0]  disp_csr_vld,       // 三条里 is_csr 的那条
    input  wire [6:0]  disp_src1_preg0, disp_src1_preg1, disp_src1_preg2,
    input  wire [11:0] disp_csr_addr0,  disp_csr_addr1,  disp_csr_addr2,
    input  wire [2:0]  disp_csr_op0,    disp_csr_op1,    disp_csr_op2,
    input  wire [4:0]  disp_csr_imm0,   disp_csr_imm1,   disp_csr_imm2,

    input  wire        retire_clr,         // 该条退休 (retire_vld & is_csr)
    input  wire        flush_clr,          // FLUSH_2

    output wire        csr_inflight,
    output wire [6:0]  slot_src1_preg,
    output wire [11:0] slot_csr_addr,
    output wire [2:0]  slot_csr_op,
    output wire [4:0]  slot_csr_imm
);

    reg        vld_q;
    reg [6:0]  src1_q;
    reg [11:0] addr_q;
    reg [2:0]  op_q;
    reg [4:0]  imm_q;

    wire [2:0]  d_vld   = disp_csr_vld;
    wire [6:0]  d_src1  = d_vld[0] ? disp_src1_preg0 : d_vld[1] ? disp_src1_preg1 : disp_src1_preg2;
    wire [11:0] d_addr  = d_vld[0] ? disp_csr_addr0  : d_vld[1] ? disp_csr_addr1  : disp_csr_addr2;
    wire [2:0]  d_op    = d_vld[0] ? disp_csr_op0    : d_vld[1] ? disp_csr_op1    : disp_csr_op2;
    wire [4:0]  d_imm   = d_vld[0] ? disp_csr_imm0   : d_vld[1] ? disp_csr_imm1   : disp_csr_imm2;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            vld_q  <= 1'b0;  src1_q <= 7'd0; addr_q <= 12'd0;
            op_q   <= 3'd0;  imm_q  <= 5'd0;
        end else if (flush_clr) begin
            vld_q  <= 1'b0;  src1_q <= 7'd0; addr_q <= 12'd0;
            op_q   <= 3'd0;  imm_q  <= 5'd0;
        end else if (retire_clr) begin
            vld_q  <= 1'b0;                 // 退休即释放 (地址等字段不再被读)
        end else if (|d_vld) begin
            vld_q  <= 1'b1;
            src1_q <= d_src1;
            addr_q <= d_addr;
            op_q   <= d_op;
            imm_q  <= d_imm;
        end
    end

    assign csr_inflight  = vld_q;
    assign slot_src1_preg= src1_q;
    assign slot_csr_addr = addr_q;
    assign slot_csr_op   = op_q;
    assign slot_csr_imm  = imm_q;

endmodule
