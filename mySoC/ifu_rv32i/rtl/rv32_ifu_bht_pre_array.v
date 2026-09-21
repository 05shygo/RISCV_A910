/*Copyright 2019-2021 T-Head Semiconductor Co., Ltd.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// RV32I port, 2026-09-20: portable synchronous SRAM; original control polarity/read latency retained.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_bht_pre_array (

  // Predictor and pipeline interface
  input wire        bht_pre_array_clk_en,
  input wire        bht_pred_array_cen_b,
  input wire [63:0] bht_pred_array_din,
  input wire        bht_pred_array_gwen,
  input wire [ 9:0] bht_pred_array_index,
  input wire [63:0] bht_pred_bwen,

  // Clock, reset and configuration
  input wire cp0_ifu_icg_en,
  input wire cp0_yy_clk_en,
  input wire forever_cpuclk,
  input wire pad_yy_icg_scan_en,

  // Predictor and pipeline interface
  output wire [63:0] bht_pre_data_out
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire bht_pre_clk;
  wire bht_pre_en;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  //Gate Clk
  rv32_ifu_clk_cell u_bht_pre_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (bht_pre_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (bht_pre_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign bht_pre_en = bht_pre_array_clk_en;

  //Instance Logic
  rv32_ifu_spram #(
    .ADDR_WIDTH(10),
    .DATA_WIDTH(64)
  ) u_ct_spsram_1024x64 (
    .A   (bht_pred_array_index),
    .CEN (bht_pred_array_cen_b),
    .CLK (bht_pre_clk),
    .D   (bht_pred_array_din),
    .GWEN(bht_pred_array_gwen),
    .Q   (bht_pre_data_out),
    .WEN (bht_pred_bwen)
  );
endmodule
