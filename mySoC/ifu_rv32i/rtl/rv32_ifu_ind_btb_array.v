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
module rv32_ifu_ind_btb_array #(
  // [BP_SHRINK] 间接 BTB 行数, 默认 = 原样 256 行 (ADDR_WIDTH=8)。
  // `+define+BP_IND_AW=n` 覆盖成 2^n 行, 只留索引低位。
  // 该表按路径寄存器索引、不带标签, 所以截位就是纯粹的"表变小、别名变多"。
`ifdef BP_IND_AW
  parameter IND_AW = `BP_IND_AW
`else
  parameter IND_AW = 8
`endif
) (

  // Clock, reset and configuration
  input wire cp0_ifu_icg_en,
  input wire cp0_yy_clk_en,
  input wire forever_cpuclk,

  // Predictor and pipeline interface
  input wire        ind_btb_cen_b,
  input wire        ind_btb_clk_en,
  input wire [34:0] ind_btb_data_in,
  input wire [IND_AW-1:0] ind_btb_index,
  input wire        ind_btb_wen_b,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Predictor and pipeline interface
  output wire [34:0] ind_btb_dout
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire [34:0] ind_btb_bwen;
  wire        ind_btb_clk;
  wire        ind_btb_local_en;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  //Gate Clk
  rv32_ifu_clk_cell u_ind_btb_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ind_btb_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ind_btb_local_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ind_btb_local_en   = ind_btb_clk_en;

  assign ind_btb_bwen[34:0] = {35{ind_btb_wen_b}};

  //Instance Logic
  rv32_ifu_spram #(
    .ADDR_WIDTH(IND_AW),
    .DATA_WIDTH(35)
  ) u_ct_spsram_256x23 (
    .A   (ind_btb_index),
    .CEN (ind_btb_cen_b),
    .CLK (ind_btb_clk),
    .D   (ind_btb_data_in),
    .GWEN(ind_btb_wen_b),
    .Q   (ind_btb_dout),
    .WEN (ind_btb_bwen)
  );
endmodule
