// SPDX-License-Identifier: Apache-2.0
// RV32I subset of ct_ifu_decd_normal/ipdecode; one word, replicated by IP.
// Illegal encodings remain in the instruction stream for IDU to trap.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_bp_decode (

  // Predictor and pipeline interface
  input  wire [31:0] inst,
  input  wire [31:0] pc,
  output wire        condbr,
  output wire        jal,
  output wire        jalr,
  output wire        auipc,
  output wire        pc_oper,
  output wire        dst_vld,
  output wire [ 2:0] cf_type,
  output wire        ras_push,
  output wire        ras_pop,
  output wire        ras_target_usable,
  output wire [31:0] direct_target,
  output wire        direct_misaligned,
  output wire [31:0] link_pc
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire        rd_link;
  wire        rs_link;
  wire [31:0] imm_b;
  wire [31:0] imm_j;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------
  assign rd_link = (inst[11:7] == 5'd1) || (inst[11:7] == 5'd5);
  assign rs_link = (inst[19:15] == 5'd1) || (inst[19:15] == 5'd5);
  assign imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
  assign imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

  assign
    condbr = inst[6:0] == 7'h63 && (inst[14:12] == 3'b000 || inst[14:12] == 3'b001 || inst[14]);

  assign jal = inst[6:0] == 7'h6f;

  assign jalr = inst[6:0] == 7'h67 && inst[14:12] == 3'b000;

  assign auipc = inst[6:0] == 7'h17;

  assign pc_oper = condbr || jal || jalr || auipc;

  assign dst_vld = (jal || jalr || auipc) && inst[11:7] != 5'b0;

  assign cf_type = condbr ? 3'd1 : jal ? 3'd2 : jalr ? 3'd3 : auipc ? 3'd4 : 3'd0;

  assign ras_push = (jal || jalr) && rd_link;

  assign ras_pop = jalr && rs_link && (!rd_link || inst[11:7] != inst[19:15]);

  // Pop hint and eligibility to predict from old TOS are deliberately different.
  assign ras_target_usable = ras_pop && inst[31:20] == 12'b0;

  assign direct_target = pc + (condbr ? imm_b : jal ? imm_j : 32'd4);

  assign direct_misaligned = (condbr || jal) && (|direct_target[1:0]);

  assign link_pc = pc + 32'd4;
endmodule
