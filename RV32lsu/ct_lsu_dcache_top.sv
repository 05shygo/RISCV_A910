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

// &ModuleBeg; @26
module ct_lsu_dcache_top #(
  parameter int DCACHE_SIZE = 2048  // 1024, 2048, or 4096 bytes
)(
  cp0_lsu_icg_en,
  dcache_lsu_ld_data_bank0_dout,
  dcache_lsu_ld_data_bank1_dout,
  dcache_lsu_ld_data_bank2_dout,
  dcache_lsu_ld_data_bank3_dout,
  dcache_lsu_ld_data_bank4_dout,
  dcache_lsu_ld_data_bank5_dout,
  dcache_lsu_ld_data_bank6_dout,
  dcache_lsu_ld_data_bank7_dout,
  dcache_lsu_ld_tag_dout,
  dcache_lsu_st_dirty_dout,
  dcache_lsu_st_tag_dout,
  forever_cpuclk,
  lsu_dcache_ld_data_gateclk_en,
  lsu_dcache_ld_data_gwen_b,
  lsu_dcache_ld_data_high_din,
  lsu_dcache_ld_data_high_idx,
  lsu_dcache_ld_data_low_din,
  lsu_dcache_ld_data_low_idx,
  lsu_dcache_ld_data_sel_b,
  lsu_dcache_ld_data_wen_b,
  lsu_dcache_ld_tag_din,
  lsu_dcache_ld_tag_gateclk_en,
  lsu_dcache_ld_tag_gwen_b,
  lsu_dcache_ld_tag_idx,
  lsu_dcache_ld_tag_sel_b,
  lsu_dcache_ld_tag_wen_b,
  lsu_dcache_st_dirty_din,
  lsu_dcache_st_dirty_gateclk_en,
  lsu_dcache_st_dirty_gwen_b,
  lsu_dcache_st_dirty_idx,
  lsu_dcache_st_dirty_sel_b,
  lsu_dcache_st_dirty_wen_b,
  lsu_dcache_st_tag_din,
  lsu_dcache_st_tag_gateclk_en,
  lsu_dcache_st_tag_gwen_b,
  lsu_dcache_st_tag_idx,
  lsu_dcache_st_tag_sel_b,
  lsu_dcache_st_tag_wen_b,
  pad_yy_icg_scan_en
);

// Derived parameters for configurable dcache
localparam int CACHELINE_SIZE = 32;                        // Fixed 32-byte cacheline
localparam int NUM_WAYS = 2;                               // Fixed 2-way
localparam int OFFSET_WIDTH = 5;                           // log2(32) = 5
localparam int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS;
localparam int INDEX_WIDTH = $clog2(NUM_SETS);            // 4 for 1KB, 5 for 2KB, 6 for 4KB
localparam int INDEX_LSB = OFFSET_WIDTH;                   // = 5
localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;    // 8 for 1KB, 9 for 2KB, 10 for 4KB
localparam int DATA_INDEX_WIDTH = INDEX_WIDTH + 1;         // Include way bit
localparam int TAG_LSB = INDEX_MSB + 1;                    // 9 for 1KB, 10 for 2KB, 11 for 4KB
localparam int TAG_WIDTH = 32 - TAG_LSB;                   // Tag width
localparam int LD_TAG_WIDTH = TAG_WIDTH * 2 + 2;           // Load tag: 2 ways + 2 valid bits
localparam int ST_TAG_WIDTH = TAG_WIDTH * 2;               // Store tag: 2 ways only

// &Ports; @27
input            cp0_lsu_icg_en;
input            forever_cpuclk;
input   [7  :0]  lsu_dcache_ld_data_gateclk_en;
input   [7  :0]  lsu_dcache_ld_data_gwen_b;
input   [127:0]  lsu_dcache_ld_data_high_din;
input   [DATA_INDEX_WIDTH-1:0]  lsu_dcache_ld_data_high_idx;
input   [127:0]  lsu_dcache_ld_data_low_din;
input   [DATA_INDEX_WIDTH-1:0]  lsu_dcache_ld_data_low_idx;
input   [7  :0]  lsu_dcache_ld_data_sel_b;
input   [31 :0]  lsu_dcache_ld_data_wen_b;
input   [LD_TAG_WIDTH-1:0]  lsu_dcache_ld_tag_din;
input            lsu_dcache_ld_tag_gateclk_en;
input            lsu_dcache_ld_tag_gwen_b;
input   [INDEX_WIDTH-1:0]  lsu_dcache_ld_tag_idx;
input            lsu_dcache_ld_tag_sel_b;
input   [1  :0]  lsu_dcache_ld_tag_wen_b;
input   [4  :0]  lsu_dcache_st_dirty_din;
input            lsu_dcache_st_dirty_gateclk_en;
input            lsu_dcache_st_dirty_gwen_b;
input   [INDEX_WIDTH-1:0]  lsu_dcache_st_dirty_idx;
input            lsu_dcache_st_dirty_sel_b;
input   [4  :0]  lsu_dcache_st_dirty_wen_b;
input   [ST_TAG_WIDTH-1:0]  lsu_dcache_st_tag_din;
input            lsu_dcache_st_tag_gateclk_en;
input            lsu_dcache_st_tag_gwen_b;
input   [INDEX_WIDTH-1:0]  lsu_dcache_st_tag_idx;
input            lsu_dcache_st_tag_sel_b;
input   [1  :0]  lsu_dcache_st_tag_wen_b;
input            pad_yy_icg_scan_en;
output  [31 :0]  dcache_lsu_ld_data_bank0_dout;
output  [31 :0]  dcache_lsu_ld_data_bank1_dout;
output  [31 :0]  dcache_lsu_ld_data_bank2_dout;
output  [31 :0]  dcache_lsu_ld_data_bank3_dout;
output  [31 :0]  dcache_lsu_ld_data_bank4_dout;
output  [31 :0]  dcache_lsu_ld_data_bank5_dout;
output  [31 :0]  dcache_lsu_ld_data_bank6_dout;
output  [31 :0]  dcache_lsu_ld_data_bank7_dout;
output  [LD_TAG_WIDTH-1:0]  dcache_lsu_ld_tag_dout;
output  [4  :0]  dcache_lsu_st_dirty_dout;
output  [ST_TAG_WIDTH-1:0]  dcache_lsu_st_tag_dout;        

// &Regs; @28

// &Wires; @29
wire             cp0_lsu_icg_en;
wire    [31 :0]  dcache_lsu_ld_data_bank0_dout;
wire    [31 :0]  dcache_lsu_ld_data_bank1_dout;
wire    [31 :0]  dcache_lsu_ld_data_bank2_dout;
wire    [31 :0]  dcache_lsu_ld_data_bank3_dout;
wire    [31 :0]  dcache_lsu_ld_data_bank4_dout;
wire    [31 :0]  dcache_lsu_ld_data_bank5_dout;
wire    [31 :0]  dcache_lsu_ld_data_bank6_dout;
wire    [31 :0]  dcache_lsu_ld_data_bank7_dout;
wire    [LD_TAG_WIDTH-1:0]  dcache_lsu_ld_tag_dout;
wire    [4  :0]  dcache_lsu_st_dirty_dout;
wire    [ST_TAG_WIDTH-1:0]  dcache_lsu_st_tag_dout;
wire             forever_cpuclk;
wire    [7  :0]  lsu_dcache_ld_data_gateclk_en;
wire    [7  :0]  lsu_dcache_ld_data_gwen_b;
wire    [127:0]  lsu_dcache_ld_data_high_din;
wire    [DATA_INDEX_WIDTH-1:0]  lsu_dcache_ld_data_high_idx;
wire    [127:0]  lsu_dcache_ld_data_low_din;
wire    [DATA_INDEX_WIDTH-1:0]  lsu_dcache_ld_data_low_idx;
wire    [7  :0]  lsu_dcache_ld_data_sel_b;
wire    [31 :0]  lsu_dcache_ld_data_wen_b;
wire    [LD_TAG_WIDTH-1:0]  lsu_dcache_ld_tag_din;
wire             lsu_dcache_ld_tag_gateclk_en;
wire             lsu_dcache_ld_tag_gwen_b;
wire    [INDEX_WIDTH-1:0]  lsu_dcache_ld_tag_idx;
wire             lsu_dcache_ld_tag_sel_b;
wire    [1  :0]  lsu_dcache_ld_tag_wen_b;
wire    [4  :0]  lsu_dcache_st_dirty_din;
wire             lsu_dcache_st_dirty_gateclk_en;
wire             lsu_dcache_st_dirty_gwen_b;
wire    [INDEX_WIDTH-1:0]  lsu_dcache_st_dirty_idx;
wire             lsu_dcache_st_dirty_sel_b;
wire    [4  :0]  lsu_dcache_st_dirty_wen_b;
wire    [ST_TAG_WIDTH-1:0]  lsu_dcache_st_tag_din;
wire             lsu_dcache_st_tag_gateclk_en;
wire             lsu_dcache_st_tag_gwen_b;
wire    [INDEX_WIDTH-1:0]  lsu_dcache_st_tag_idx;
wire             lsu_dcache_st_tag_sel_b;
wire    [1  :0]  lsu_dcache_st_tag_wen_b;
wire             pad_yy_icg_scan_en;            


//==========================================================
//                Instance dcache array
//==========================================================
//---------------------tag and dirty------------------------
// &Instance("ct_lsu_dcache_ld_tag_array", "x_ct_lsu_dcache_ld_tag_array"); @35
ct_lsu_dcache_ld_tag_array #(
  .INDEX_WIDTH(INDEX_WIDTH),
  .TAG_WIDTH(TAG_WIDTH)
) x_ct_lsu_dcache_ld_tag_array (
  .cp0_lsu_icg_en               (cp0_lsu_icg_en              ),
  .forever_cpuclk               (forever_cpuclk              ),
  .pad_yy_icg_scan_en           (pad_yy_icg_scan_en          ),
  .tag_din                      (lsu_dcache_ld_tag_din       ),
  .tag_dout                     (dcache_lsu_ld_tag_dout      ),
  .tag_gateclk_en               (lsu_dcache_ld_tag_gateclk_en),
  .tag_gwen_b                   (lsu_dcache_ld_tag_gwen_b    ),
  .tag_idx                      (lsu_dcache_ld_tag_idx       ),
  .tag_sel_b                    (lsu_dcache_ld_tag_sel_b     ),
  .tag_wen_b                    (lsu_dcache_ld_tag_wen_b     )
);



// &Instance("ct_lsu_dcache_tag_array", "x_ct_lsu_dcache_st_tag_array"); @45
ct_lsu_dcache_tag_array #(
  .INDEX_WIDTH(INDEX_WIDTH),
  .TAG_WIDTH(TAG_WIDTH)
) x_ct_lsu_dcache_st_tag_array (
  .cp0_lsu_icg_en               (cp0_lsu_icg_en              ),
  .forever_cpuclk               (forever_cpuclk              ),
  .pad_yy_icg_scan_en           (pad_yy_icg_scan_en          ),
  .tag_din                      (lsu_dcache_st_tag_din       ),
  .tag_dout                     (dcache_lsu_st_tag_dout      ),
  .tag_gateclk_en               (lsu_dcache_st_tag_gateclk_en),
  .tag_gwen_b                   (lsu_dcache_st_tag_gwen_b    ),
  .tag_idx                      (lsu_dcache_st_tag_idx       ),
  .tag_sel_b                    (lsu_dcache_st_tag_sel_b     ),
  .tag_wen_b                    (lsu_dcache_st_tag_wen_b     )
);


ct_lsu_dcache_dirty_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_st_dirty_array (
  .cp0_lsu_icg_en                 (cp0_lsu_icg_en                ),
  .dirty_din                      (lsu_dcache_st_dirty_din       ),
  .dirty_dout                     (dcache_lsu_st_dirty_dout      ),
  .dirty_gateclk_en               (lsu_dcache_st_dirty_gateclk_en),
  .dirty_gwen_b                   (lsu_dcache_st_dirty_gwen_b    ),
  .dirty_idx                      (lsu_dcache_st_dirty_idx       ),
  .dirty_sel_b                    (lsu_dcache_st_dirty_sel_b     ),
  .dirty_wen_b                    (lsu_dcache_st_dirty_wen_b     ),
  .forever_cpuclk                 (forever_cpuclk                ),
  .pad_yy_icg_scan_en             (pad_yy_icg_scan_en            )
);


ct_lsu_dcache_data_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_ld_data_bank0_array (
  .cp0_lsu_icg_en                   (cp0_lsu_icg_en                  ),
  .data_din                         (lsu_dcache_ld_data_low_din[31:0]),
  .data_dout                        (dcache_lsu_ld_data_bank0_dout   ),
  .data_gateclk_en                  (lsu_dcache_ld_data_gateclk_en[0]),
  .data_gwen_b                      (lsu_dcache_ld_data_gwen_b[0]    ),
  .data_idx                         (lsu_dcache_ld_data_low_idx      ),
  .data_sel_b                       (lsu_dcache_ld_data_sel_b[0]     ),
  .data_wen_b                       (lsu_dcache_ld_data_wen_b[3:0]   ),
  .forever_cpuclk                   (forever_cpuclk                  ),
  .pad_yy_icg_scan_en               (pad_yy_icg_scan_en              )
);


ct_lsu_dcache_data_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_ld_data_bank1_array (
  .cp0_lsu_icg_en                    (cp0_lsu_icg_en                   ),
  .data_din                          (lsu_dcache_ld_data_low_din[63:32]),
  .data_dout                         (dcache_lsu_ld_data_bank1_dout    ),
  .data_gateclk_en                   (lsu_dcache_ld_data_gateclk_en[1] ),
  .data_gwen_b                       (lsu_dcache_ld_data_gwen_b[1]     ),
  .data_idx                          (lsu_dcache_ld_data_low_idx       ),
  .data_sel_b                        (lsu_dcache_ld_data_sel_b[1]      ),
  .data_wen_b                        (lsu_dcache_ld_data_wen_b[7:4]    ),
  .forever_cpuclk                    (forever_cpuclk                   ),
  .pad_yy_icg_scan_en                (pad_yy_icg_scan_en               )
);


ct_lsu_dcache_data_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_ld_data_bank2_array (
  .cp0_lsu_icg_en                    (cp0_lsu_icg_en                   ),
  .data_din                          (lsu_dcache_ld_data_low_din[95:64]),
  .data_dout                         (dcache_lsu_ld_data_bank2_dout    ),
  .data_gateclk_en                   (lsu_dcache_ld_data_gateclk_en[2] ),
  .data_gwen_b                       (lsu_dcache_ld_data_gwen_b[2]     ),
  .data_idx                          (lsu_dcache_ld_data_low_idx       ),
  .data_sel_b                        (lsu_dcache_ld_data_sel_b[2]      ),
  .data_wen_b                        (lsu_dcache_ld_data_wen_b[11:8]   ),
  .forever_cpuclk                    (forever_cpuclk                   ),
  .pad_yy_icg_scan_en                (pad_yy_icg_scan_en               )
);


ct_lsu_dcache_data_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_ld_data_bank3_array (
  .cp0_lsu_icg_en                     (cp0_lsu_icg_en                    ),
  .data_din                           (lsu_dcache_ld_data_low_din[127:96]),
  .data_dout                          (dcache_lsu_ld_data_bank3_dout     ),
  .data_gateclk_en                    (lsu_dcache_ld_data_gateclk_en[3]  ),
  .data_gwen_b                        (lsu_dcache_ld_data_gwen_b[3]      ),
  .data_idx                           (lsu_dcache_ld_data_low_idx        ),
  .data_sel_b                         (lsu_dcache_ld_data_sel_b[3]       ),
  .data_wen_b                         (lsu_dcache_ld_data_wen_b[15:12]   ),
  .forever_cpuclk                     (forever_cpuclk                    ),
  .pad_yy_icg_scan_en                 (pad_yy_icg_scan_en                )
);


ct_lsu_dcache_data_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_ld_data_bank4_array (
  .cp0_lsu_icg_en                    (cp0_lsu_icg_en                   ),
  .data_din                          (lsu_dcache_ld_data_high_din[31:0]),
  .data_dout                         (dcache_lsu_ld_data_bank4_dout    ),
  .data_gateclk_en                   (lsu_dcache_ld_data_gateclk_en[4] ),
  .data_gwen_b                       (lsu_dcache_ld_data_gwen_b[4]     ),
  .data_idx                          (lsu_dcache_ld_data_high_idx      ),
  .data_sel_b                        (lsu_dcache_ld_data_sel_b[4]      ),
  .data_wen_b                        (lsu_dcache_ld_data_wen_b[19:16]  ),
  .forever_cpuclk                    (forever_cpuclk                   ),
  .pad_yy_icg_scan_en                (pad_yy_icg_scan_en               )
);


ct_lsu_dcache_data_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_ld_data_bank5_array (
  .cp0_lsu_icg_en                     (cp0_lsu_icg_en                    ),
  .data_din                           (lsu_dcache_ld_data_high_din[63:32]),
  .data_dout                          (dcache_lsu_ld_data_bank5_dout     ),
  .data_gateclk_en                    (lsu_dcache_ld_data_gateclk_en[5]  ),
  .data_gwen_b                        (lsu_dcache_ld_data_gwen_b[5]      ),
  .data_idx                           (lsu_dcache_ld_data_high_idx       ),
  .data_sel_b                         (lsu_dcache_ld_data_sel_b[5]       ),
  .data_wen_b                         (lsu_dcache_ld_data_wen_b[23:20]   ),
  .forever_cpuclk                     (forever_cpuclk                    ),
  .pad_yy_icg_scan_en                 (pad_yy_icg_scan_en                )
);


ct_lsu_dcache_data_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_ld_data_bank6_array (
  .cp0_lsu_icg_en                     (cp0_lsu_icg_en                    ),
  .data_din                           (lsu_dcache_ld_data_high_din[95:64]),
  .data_dout                          (dcache_lsu_ld_data_bank6_dout     ),
  .data_gateclk_en                    (lsu_dcache_ld_data_gateclk_en[6]  ),
  .data_gwen_b                        (lsu_dcache_ld_data_gwen_b[6]      ),
  .data_idx                           (lsu_dcache_ld_data_high_idx       ),
  .data_sel_b                         (lsu_dcache_ld_data_sel_b[6]       ),
  .data_wen_b                         (lsu_dcache_ld_data_wen_b[27:24]   ),
  .forever_cpuclk                     (forever_cpuclk                    ),
  .pad_yy_icg_scan_en                 (pad_yy_icg_scan_en                )
);


ct_lsu_dcache_data_array #(
  .INDEX_WIDTH(INDEX_WIDTH)
) x_ct_lsu_dcache_ld_data_bank7_array (
  .cp0_lsu_icg_en                      (cp0_lsu_icg_en                     ),
  .data_din                            (lsu_dcache_ld_data_high_din[127:96]),
  .data_dout                           (dcache_lsu_ld_data_bank7_dout      ),
  .data_gateclk_en                     (lsu_dcache_ld_data_gateclk_en[7]   ),
  .data_gwen_b                         (lsu_dcache_ld_data_gwen_b[7]       ),
  .data_idx                            (lsu_dcache_ld_data_high_idx        ),
  .data_sel_b                          (lsu_dcache_ld_data_sel_b[7]        ),
  .data_wen_b                          (lsu_dcache_ld_data_wen_b[31:28]    ),
  .forever_cpuclk                      (forever_cpuclk                     ),
  .pad_yy_icg_scan_en                  (pad_yy_icg_scan_en                 )
);



// &ModuleEnd; @228
endmodule


