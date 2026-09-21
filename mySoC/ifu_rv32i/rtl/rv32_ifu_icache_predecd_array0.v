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

// RV32I/no-MMU derivative: 64 KiB, two ways, 64 B lines, 512 sets.
// All address inputs use byte addressing: set PA[14:6], block PA[5:4].
// Tag row = {FIFO, valid1, tag1[16:0], valid0, tag0[16:0]}.
// Core request strobes MUST be mutually exclusive; use rv32_ifu_icache_top.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_icache_predecd_array0 (

  // Clock, reset and configuration
  input wire cp0_ifu_icg_en,
  input wire cp0_yy_clk_en,
  input wire forever_cpuclk,

  // Cache array and pipeline interface
  input wire [14:0] ifu_icache_index,
  input wire        ifu_icache_predecd_array0_cen_b,
  input wire        ifu_icache_predecd_array0_clk_en,
  input wire [31:0] ifu_icache_predecd_array0_din,
  input wire        ifu_icache_predecd_array0_wen_b,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Cache array and pipeline interface
  output wire [31:0] icache_ifu_predecd_array0_dout
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire [31:0] ifu_icache_predecd_array0_bwen;
  wire        predecd_clk;
  wire        predecd_local_en;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  rv32_ifu_clk_cell u_predecd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (predecd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (predecd_local_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign predecd_local_en                     = ifu_icache_predecd_array0_clk_en;

  //Support Bit Write
  assign ifu_icache_predecd_array0_bwen[31:0] = {32{ifu_icache_predecd_array0_wen_b}};

  rv32_ifu_spram #(
    .ADDR_WIDTH(11),
    .DATA_WIDTH(32)
  ) u_ct_spsram_2048x32_split (
    .A   (ifu_icache_index[14:4]),
    .CEN (ifu_icache_predecd_array0_cen_b),
    .CLK (predecd_clk),
    .D   (ifu_icache_predecd_array0_din),
    .GWEN(ifu_icache_predecd_array0_wen_b),
    .Q   (icache_ifu_predecd_array0_dout),
    .WEN (ifu_icache_predecd_array0_bwen)
  );
endmodule
