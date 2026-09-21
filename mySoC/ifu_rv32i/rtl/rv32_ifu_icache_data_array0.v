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
module rv32_ifu_icache_data_array0 (

  // Clock, reset and configuration
  input wire cp0_yy_clk_en,
  input wire cp0_ifu_icg_en,
  input wire forever_cpuclk,

  // Cache array and pipeline interface
  input wire         ifu_icache_data_array0_bank0_cen_b,
  input wire         ifu_icache_data_array0_bank0_clk_en,
  input wire         ifu_icache_data_array0_bank1_cen_b,
  input wire         ifu_icache_data_array0_bank1_clk_en,
  input wire         ifu_icache_data_array0_bank2_cen_b,
  input wire         ifu_icache_data_array0_bank2_clk_en,
  input wire         ifu_icache_data_array0_bank3_cen_b,
  input wire         ifu_icache_data_array0_bank3_clk_en,
  input wire [127:0] ifu_icache_data_array0_din,
  input wire         ifu_icache_data_array0_wen_b,
  input wire [ 14:0] ifu_icache_index,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Cache array and pipeline interface
  output wire [127:0] icache_ifu_data_array0_dout
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire        data_clk_bank0;
  wire        data_clk_bank1;
  wire        data_clk_bank2;
  wire        data_clk_bank3;
  wire        data_local_en_bank0;
  wire        data_local_en_bank1;
  wire        data_local_en_bank2;
  wire        data_local_en_bank3;
  wire [31:0] icache_ifu_data_array0_bank0_dout;
  wire [31:0] icache_ifu_data_array0_bank1_dout;
  wire [31:0] icache_ifu_data_array0_bank2_dout;
  wire [31:0] icache_ifu_data_array0_bank3_dout;
  wire [31:0] ifu_icache_data_array0_bank0_bwen;
  wire [31:0] ifu_icache_data_array0_bank0_din;
  wire [31:0] ifu_icache_data_array0_bank1_bwen;
  wire [31:0] ifu_icache_data_array0_bank1_din;
  wire [31:0] ifu_icache_data_array0_bank2_bwen;
  wire [31:0] ifu_icache_data_array0_bank2_din;
  wire [31:0] ifu_icache_data_array0_bank3_bwen;
  wire [31:0] ifu_icache_data_array0_bank3_din;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  //Gate Clk
  rv32_ifu_clk_cell u_data_bank0_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (data_clk_bank0),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (data_local_en_bank0),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign data_local_en_bank0 = ifu_icache_data_array0_bank0_clk_en;

  rv32_ifu_clk_cell u_data_bank1_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (data_clk_bank1),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (data_local_en_bank1),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign data_local_en_bank1 = ifu_icache_data_array0_bank1_clk_en;

  rv32_ifu_clk_cell u_data_bank2_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (data_clk_bank2),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (data_local_en_bank2),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign data_local_en_bank2 = ifu_icache_data_array0_bank2_clk_en;

  rv32_ifu_clk_cell u_data_bank3_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (data_clk_bank3),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (data_local_en_bank3),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign data_local_en_bank3 = ifu_icache_data_array0_bank3_clk_en;

  //Instance Logic
  //Support Bit Write
  assign ifu_icache_data_array0_bank0_bwen[31:0] = {32{ifu_icache_data_array0_wen_b}};

  assign ifu_icache_data_array0_bank1_bwen[31:0] = {32{ifu_icache_data_array0_wen_b}};

  assign ifu_icache_data_array0_bank2_bwen[31:0] = {32{ifu_icache_data_array0_wen_b}};

  assign ifu_icache_data_array0_bank3_bwen[31:0] = {32{ifu_icache_data_array0_wen_b}};

  assign icache_ifu_data_array0_dout[127:0] = {
    icache_ifu_data_array0_bank0_dout[31:0],
    icache_ifu_data_array0_bank1_dout[31:0],
    icache_ifu_data_array0_bank2_dout[31:0],
    icache_ifu_data_array0_bank3_dout[31:0]
  };

  assign ifu_icache_data_array0_bank0_din[31:0] = ifu_icache_data_array0_din[127:96];

  assign ifu_icache_data_array0_bank1_din[31:0] = ifu_icache_data_array0_din[95:64];

  assign ifu_icache_data_array0_bank2_din[31:0] = ifu_icache_data_array0_din[63:32];

  assign ifu_icache_data_array0_bank3_din[31:0] = ifu_icache_data_array0_din[31:0];

  //Icache Size define
  rv32_ifu_spram #(
    .ADDR_WIDTH(11),
    .DATA_WIDTH(32)
  ) u_ct_spsram_2048x32_bank0 (
    .A   (ifu_icache_index[14:4]),
    .CEN (ifu_icache_data_array0_bank0_cen_b),
    .CLK (data_clk_bank0),
    .D   (ifu_icache_data_array0_bank0_din),
    .GWEN(ifu_icache_data_array0_wen_b),
    .Q   (icache_ifu_data_array0_bank0_dout),
    .WEN (ifu_icache_data_array0_bank0_bwen)
  );

  rv32_ifu_spram #(
    .ADDR_WIDTH(11),
    .DATA_WIDTH(32)
  ) u_ct_spsram_2048x32_bank1 (
    .A   (ifu_icache_index[14:4]),
    .CEN (ifu_icache_data_array0_bank1_cen_b),
    .CLK (data_clk_bank1),
    .D   (ifu_icache_data_array0_bank1_din),
    .GWEN(ifu_icache_data_array0_wen_b),
    .Q   (icache_ifu_data_array0_bank1_dout),
    .WEN (ifu_icache_data_array0_bank1_bwen)
  );

  rv32_ifu_spram #(
    .ADDR_WIDTH(11),
    .DATA_WIDTH(32)
  ) u_ct_spsram_2048x32_bank2 (
    .A   (ifu_icache_index[14:4]),
    .CEN (ifu_icache_data_array0_bank2_cen_b),
    .CLK (data_clk_bank2),
    .D   (ifu_icache_data_array0_bank2_din),
    .GWEN(ifu_icache_data_array0_wen_b),
    .Q   (icache_ifu_data_array0_bank2_dout),
    .WEN (ifu_icache_data_array0_bank2_bwen)
  );

  rv32_ifu_spram #(
    .ADDR_WIDTH(11),
    .DATA_WIDTH(32)
  ) u_ct_spsram_2048x32_bank3 (
    .A   (ifu_icache_index[14:4]),
    .CEN (ifu_icache_data_array0_bank3_cen_b),
    .CLK (data_clk_bank3),
    .D   (ifu_icache_data_array0_bank3_din),
    .GWEN(ifu_icache_data_array0_wen_b),
    .Q   (icache_ifu_data_array0_bank3_dout),
    .WEN (ifu_icache_data_array0_bank3_bwen)
  );
endmodule
