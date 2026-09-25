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
module rv32_ifu_bht_sel_array #(
  // [BP_SHRINK] 选择阵列行数, 默认 = 原样 128 行 (ADDR_WIDTH=7)。
  // `+define+BP_SEL_AW=n` 覆盖成 2^n 行, 同样只留索引低位。
`ifdef BP_SEL_AW
  parameter SEL_AW = `BP_SEL_AW
`else
  parameter SEL_AW = 7
`endif
) (

  // Predictor and pipeline interface
  input wire        bht_sel_array_cen_b,
  input wire        bht_sel_array_clk_en,
  input wire [15:0] bht_sel_array_din,
  input wire        bht_sel_array_gwen,
  input wire [SEL_AW-1:0] bht_sel_array_index,
  input wire [15:0] bht_sel_bwen,

  // Clock, reset and configuration
  input wire cp0_ifu_icg_en,
  input wire cp0_yy_clk_en,
  input wire forever_cpuclk,
  input wire pad_yy_icg_scan_en,

  // Predictor and pipeline interface
  output wire [15:0] bht_sel_data_out
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire bht_sel_clk;
  wire bht_sel_en;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  //Gate Clk
  rv32_ifu_clk_cell u_bht_sel_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (bht_sel_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (bht_sel_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign bht_sel_en = bht_sel_array_clk_en;

  //Instance Logic
  rv32_ifu_spram #(
    .ADDR_WIDTH(SEL_AW),
    .DATA_WIDTH(16)
  ) u_ct_spsram_sel (
    .A   (bht_sel_array_index),
    .CEN (bht_sel_array_cen_b),
    .CLK (bht_sel_clk),
    .D   (bht_sel_array_din),
    .GWEN(bht_sel_array_gwen),
    .Q   (bht_sel_data_out),
    .WEN (bht_sel_bwen)
  );
endmodule
