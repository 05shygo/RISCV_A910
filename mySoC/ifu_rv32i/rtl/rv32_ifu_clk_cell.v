// SPDX-License-Identifier: Apache-2.0
// Same ungated functional model as this C910 repository's gated_clk_cell.v.
// Replace with a characterized ICG for ASIC use. Not a power implementation.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_clk_cell (

  // Predictor and pipeline interface
  input wire clk_in,
  input wire global_en,
  input wire module_en,
  input wire local_en,
  input wire external_en,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Predictor and pipeline interface
  output wire clk_out
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  assign clk_out = clk_in;
endmodule
