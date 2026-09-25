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
// [ICACHE 参数化] 默认值 = 原 64 KiB/64 B 几何, 不传参时逐位不变。
module rv32_ifu_icache_tag_array #(
  parameter INDEX_MSB  = 14,   // 索引最高位 (= INDEX_WIDTH-1)
  parameter SET_LSB    = 6,    // set 在索引里的最低位 (= LINE_BITS)
  parameter ADDR_WIDTH = 9,    // = SET_BITS
  parameter DATA_WIDTH = 37    // = 2*TAG_WIDTH+1
) (

  // Clock, reset and configuration
  input wire forever_cpuclk,
  input wire cp0_ifu_icg_en,

  // Cache array and pipeline interface
  input wire [INDEX_MSB:0] ifu_icache_index,
  input wire        ifu_icache_tag_cen_b,
  input wire        ifu_icache_tag_clk_en,
  input wire [DATA_WIDTH-1:0] ifu_icache_tag_din,
  input wire [ 2:0] ifu_icache_tag_wen,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Cache array and pipeline interface
  output wire [36:0] icache_ifu_tag_dout
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  // [ICACHE 参数化] tag 行布局 = {FIFO, way1(TAG_WIDTH), way0(TAG_WIDTH)},
  // DATA_WIDTH = 2*TAG_WIDTH+1 ⇒ 每组的位宽必须是 (DATA_WIDTH-1)/2, 不能写死 18
  // (写死时 TAG_WIDTH!=18 的几何会把 FIFO 位写错位置, 且高位永远被写)。
  localparam TAG_HALF = (DATA_WIDTH-1)/2;
  wire [DATA_WIDTH-1:0] ifu_icache_tag_bwen;
  wire        ifu_icache_tag_gwen;
  wire        tag_clk;
  wire        tag_local_en;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  //Gate Clk
  rv32_ifu_clk_cell u_tag_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (tag_clk),
    .external_en       (1'b0),
    .global_en         (1'b1),
    .local_en          (tag_local_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign tag_local_en = ifu_icache_tag_clk_en;

  //Instance Logic
  //Support Bit Write
  assign ifu_icache_tag_gwen = &ifu_icache_tag_wen[2:0];

  assign ifu_icache_tag_bwen[DATA_WIDTH-1:0] = {
    ifu_icache_tag_wen[2], {TAG_HALF{ifu_icache_tag_wen[1]}}, {TAG_HALF{ifu_icache_tag_wen[0]}}
  };

  //Icache Size define
  rv32_ifu_spram #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_ct_spsram_512x59 (
    .A   (ifu_icache_index[INDEX_MSB:SET_LSB]),
    .CEN (ifu_icache_tag_cen_b),
    .CLK (tag_clk),
    .D   (ifu_icache_tag_din),
    .GWEN(ifu_icache_tag_gwen),
    .Q   (icache_ifu_tag_dout),
    .WEN (ifu_icache_tag_bwen)
  );
endmodule
