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

// &Depend("ct_spsram_256x52.vp"); @26
// &Depend("ct_spsram_512x52.vp"); @27

module ct_lsu_dcache_tag_array #(
  parameter int INDEX_WIDTH = 5,   // 4 for 1KB, 5 for 2KB, 6 for 4KB
  parameter int TAG_WIDTH = 23     // Derived from 32 - INDEX_WIDTH - 5
)(
  forever_cpuclk,
  pad_yy_icg_scan_en,
  tag_din,
  tag_dout,
  tag_gateclk_en,
  tag_gwen_b,
  tag_idx,
  tag_sel_b,
  tag_wen_b,
  cp0_lsu_icg_en
);

localparam int TAG_ARRAY_WIDTH = TAG_WIDTH * 2;  // 2 ways, no valid bits for store tag

input           forever_cpuclk;
input           pad_yy_icg_scan_en;
input   [TAG_ARRAY_WIDTH-1:0]  tag_din;
input           tag_gateclk_en;
input           tag_gwen_b;
input   [INDEX_WIDTH-1:0]  tag_idx;
input           tag_sel_b;
input   [1 :0]  tag_wen_b;
input           cp0_lsu_icg_en;
output  [TAG_ARRAY_WIDTH-1:0]  tag_dout;

wire            forever_cpuclk;
wire            pad_yy_icg_scan_en;
wire    [TAG_ARRAY_WIDTH-1:0]  tag_din;
wire    [TAG_ARRAY_WIDTH-1:0]  tag_dout;
wire            tag_gateclk_en;
wire            tag_gwen_b;
wire    [INDEX_WIDTH-1:0]  tag_idx;
wire            tag_sel_b;
wire    [1 :0]  tag_wen_b;
wire    [TAG_ARRAY_WIDTH-1:0]  tag_wen_b_all;
wire            cp0_lsu_icg_en;

//==========================================================
//              Instance dcache array
//==========================================================

// &Force("bus","tag_idx","8","0"); @91
assign tag_wen_b_all[TAG_ARRAY_WIDTH-1:0]  = {{TAG_WIDTH{tag_wen_b[1]}},
                                               {TAG_WIDTH{tag_wen_b[0]}}};


//csky vperl_off
`ifdef DCACHE_1KB
ct_spsram_16x54  x_ct_spsram_16x54 (
  `ifdef MEM_CFG_IN
  .mem_cfg_in     (mem_cfg_in  ),
  `endif
  .A             (tag_idx[3:0] ),
  .CEN           (tag_sel_b    ),
  .CLK           (forever_cpuclk),
  .D             (tag_din      ),
  .GWEN          (tag_gwen_b   ),
  .Q             (tag_dout     ),
  .WEN           (tag_wen_b_all)
);
`endif//DCACHE_1KB

`ifdef DCACHE_2KB
ct_spsram_32x44  x_ct_spsram_32x44 (
  `ifdef MEM_CFG_IN
  .mem_cfg_in     (mem_cfg_in  ),
  `endif
  .A             (tag_idx[4:0] ),
  .CEN           (tag_sel_b    ),
  .CLK           (forever_cpuclk),
  .D             (tag_din      ),
  .GWEN          (tag_gwen_b   ),
  .Q             (tag_dout     ),
  .WEN           (tag_wen_b_all)
);
`endif//DCACHE_2KB

`ifdef DCACHE_4KB
ct_spsram_64x50  x_ct_spsram_64x50 (
  `ifdef MEM_CFG_IN
  .mem_cfg_in     (mem_cfg_in  ),
  `endif
  .A             (tag_idx[5:0] ),
  .CEN           (tag_sel_b    ),
  .CLK           (forever_cpuclk),
  .D             (tag_din      ),
  .GWEN          (tag_gwen_b   ),
  .Q             (tag_dout     ),
  .WEN           (tag_wen_b_all)
);
`endif//DCACHE_4KB
//csky vperl_on

// &ModuleEnd; @128
endmodule


