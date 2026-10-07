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

module ct_lsu_dcache_dirty_array #(
  parameter int INDEX_WIDTH = 5   // 4 for 1KB, 5 for 2KB, 6 for 4KB
)(
  dirty_din,
  dirty_dout,
  dirty_gateclk_en,
  dirty_gwen_b,
  dirty_idx,
  dirty_sel_b,
  dirty_wen_b,
  forever_cpuclk,
  pad_yy_icg_scan_en,
  cp0_lsu_icg_en
);
input   [4:0]  dirty_din;
input          dirty_gateclk_en;
input          dirty_gwen_b;
input   [INDEX_WIDTH-1:0]  dirty_idx;
input          dirty_sel_b;
input   [4:0]  dirty_wen_b;
input          forever_cpuclk;
input          pad_yy_icg_scan_en;
input          cp0_lsu_icg_en;
output  [4:0]  dirty_dout;

wire    [4:0]  dirty_din;
wire    [4:0]  dirty_dout;
wire           dirty_gateclk_en;
wire           dirty_gwen_b;
wire    [INDEX_WIDTH-1:0]  dirty_idx;
wire           dirty_sel_b;
wire    [4:0]  dirty_wen_b;
wire           forever_cpuclk;
wire           pad_yy_icg_scan_en;
wire           cp0_lsu_icg_en;

//==========================================================
//              Instance dcache array
//==========================================================

// &Force("bus","dirty_idx","8","0"); @115

//csky vperl_off
`ifdef DCACHE_1KB
ct_spsram_16x5  x_ct_spsram_16x5 (
  `ifdef MEM_CFG_IN
  .mem_cfg_in     (mem_cfg_in    ),
  `endif
  .A              (dirty_idx[3:0]),
  .CEN            (dirty_sel_b   ),
  .CLK            (forever_cpuclk),
  .D              (dirty_din     ),
  .GWEN           (dirty_gwen_b  ),
  .Q              (dirty_dout    ),
  .WEN            (dirty_wen_b   )
);
`endif//DCACHE_1KB

`ifdef DCACHE_2KB
ct_spsram_32x5  x_ct_spsram_32x5 (
  `ifdef MEM_CFG_IN
  .mem_cfg_in     (mem_cfg_in    ),
  `endif
  .A              (dirty_idx[4:0]),
  .CEN            (dirty_sel_b   ),
  .CLK            (forever_cpuclk),
  .D              (dirty_din     ),
  .GWEN           (dirty_gwen_b  ),
  .Q              (dirty_dout    ),
  .WEN            (dirty_wen_b   )
);
`endif//DCACHE_2KB

`ifdef DCACHE_4KB
ct_spsram_64x5  x_ct_spsram_64x5 (
  `ifdef MEM_CFG_IN
  .mem_cfg_in     (mem_cfg_in    ),
  `endif
  .A              (dirty_idx[5:0]),
  .CEN            (dirty_sel_b   ),
  .CLK            (forever_cpuclk),
  .D              (dirty_din     ),
  .GWEN           (dirty_gwen_b  ),
  .Q              (dirty_dout    ),
  .WEN            (dirty_wen_b   )
);
`endif//DCACHE_4KB
//csky vperl_on

// &ModuleEnd; @183
endmodule


