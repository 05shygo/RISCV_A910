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

// Simplified dcache arbiter for RV32I
// - Only AG/WMB/LFB/VB request sources (removed SNQ/ICC/MCIC)
// - No serial request (removed consecutive two-cycle request feature)
// - Configurable dcache capacity support

module ct_lsu_dcache_arb #(
  parameter int DCACHE_SIZE = 2048,  // 1024, 2048, or 4096 bytes
  // Derived parameters for dcache indexing
  parameter int CACHELINE_SIZE = 32,
  parameter int NUM_WAYS = 2,
  parameter int OFFSET_WIDTH = 5,
  parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
  parameter int INDEX_WIDTH = $clog2(NUM_SETS),
  parameter int INDEX_LSB = OFFSET_WIDTH,
  parameter int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1,
  parameter int DATA_INDEX_WIDTH = INDEX_WIDTH + 1,
  parameter int TAG_LSB = INDEX_MSB + 1,
  parameter int TAG_WIDTH = 32 - TAG_LSB,
  parameter int LD_TAG_WIDTH = TAG_WIDTH * 2 + 2,
  parameter int ST_TAG_WIDTH = TAG_WIDTH * 2
)(
  // Clock and reset
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,

  //==========================================================
  // AG stage requests
  //==========================================================
  input  logic         ag_dcache_arb_ld_tag_req,
  input  logic         ag_dcache_arb_ld_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  ag_dcache_arb_ld_tag_idx,
  input  logic [7:0]        ag_dcache_arb_ld_data_req,
  input  logic [7:0]   ag_dcache_arb_ld_data_gateclk_en,
  input  logic [DATA_INDEX_WIDTH-1:0]  ag_dcache_arb_ld_data_low_idx,
  input  logic [DATA_INDEX_WIDTH-1:0]  ag_dcache_arb_ld_data_high_idx,

  input  logic         ag_dcache_arb_st_tag_req,
  input  logic         ag_dcache_arb_st_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  ag_dcache_arb_st_tag_idx,
  input  logic         ag_dcache_arb_st_dirty_req,
  input  logic         ag_dcache_arb_st_dirty_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  ag_dcache_arb_st_dirty_idx,

  output logic         dcache_arb_ag_ld_sel,
  output logic         dcache_arb_ag_st_sel,
  output logic [31:0]  dcache_arb_ld_ag_addr,
  output logic         dcache_arb_ld_ag_borrow_addr_vld,
  output logic [31:0]  dcache_arb_st_ag_addr,
  output logic         dcache_arb_st_ag_borrow_addr_vld,

  //==========================================================
  // WMB requests
  //==========================================================
  input  logic         wmb_dcache_arb_ld_req,
  input  logic [7:0]   wmb_dcache_arb_ld_data_gateclk_en,
  input  logic [DATA_INDEX_WIDTH-1:0]  wmb_dcache_arb_ld_data_low_idx,
  input  logic [DATA_INDEX_WIDTH-1:0]  wmb_dcache_arb_ld_data_high_idx,
  input  logic [127:0] wmb_dcache_arb_ld_data_low_din,
  input  logic [127:0] wmb_dcache_arb_ld_data_high_din,
  input  logic [31:0]  wmb_dcache_arb_ld_data_wen,

  input  logic         wmb_dcache_arb_st_req,
  input  logic [4:0]   wmb_dcache_arb_st_dirty_din,
  input  logic         wmb_dcache_arb_st_dirty_req,
  input  logic         wmb_dcache_arb_st_dirty_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  wmb_dcache_arb_st_dirty_idx,
  input  logic [4:0]   wmb_dcache_arb_st_dirty_wen,

  output logic         dcache_arb_wmb_ld_grnt,

  //==========================================================
  // LFB requests
  //==========================================================
  input  logic         lfb_dcache_arb_ld_req,
  input  logic [7:0]   lfb_dcache_arb_ld_data_gateclk_en,
  input  logic [DATA_INDEX_WIDTH-1:0]  lfb_dcache_arb_ld_data_idx,
  input  logic [127:0] lfb_dcache_arb_ld_data_low_din,
  input  logic [127:0] lfb_dcache_arb_ld_data_high_din,
  input  logic [LD_TAG_WIDTH-1:0]  lfb_dcache_arb_ld_tag_din,
  input  logic         lfb_dcache_arb_ld_tag_req,
  input  logic         lfb_dcache_arb_ld_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  lfb_dcache_arb_ld_tag_idx,
  input  logic [1:0]   lfb_dcache_arb_ld_tag_wen,

  input  logic         lfb_dcache_arb_st_req,
  input  logic [ST_TAG_WIDTH-1:0]  lfb_dcache_arb_st_tag_din,
  input  logic         lfb_dcache_arb_st_tag_req,
  input  logic         lfb_dcache_arb_st_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  lfb_dcache_arb_st_tag_idx,
  input  logic [1:0]   lfb_dcache_arb_st_tag_wen,
  input  logic [4:0]   lfb_dcache_arb_st_dirty_din,
  input  logic         lfb_dcache_arb_st_dirty_req,
  input  logic         lfb_dcache_arb_st_dirty_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  lfb_dcache_arb_st_dirty_idx,
  input  logic [4:0]   lfb_dcache_arb_st_dirty_wen,

  output logic         dcache_arb_lfb_ld_grnt,

  //==========================================================
  // VB requests
  //==========================================================
  input  logic         vb_dcache_arb_ld_req,
  input  logic         vb_dcache_arb_ld_borrow_req,
  input  logic         vb_dcache_arb_data_way,
  input  logic [7:0]   vb_dcache_arb_ld_data_gateclk_en,
  input  logic [INDEX_WIDTH:0]  vb_dcache_arb_ld_data_idx,
  input  logic [LD_TAG_WIDTH-1:0]  vb_dcache_arb_ld_tag_din,
  input  logic         vb_dcache_arb_ld_tag_req,
  input  logic         vb_dcache_arb_ld_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  vb_dcache_arb_ld_tag_idx,
  input  logic [1:0]   vb_dcache_arb_ld_tag_wen,

  input  logic         vb_dcache_arb_st_req,
  input  logic         vb_dcache_arb_st_borrow_req,
  input  logic         vb_dcache_arb_st_tag_req,
  input  logic         vb_dcache_arb_st_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  vb_dcache_arb_st_tag_idx,
  input  logic [4:0]   vb_dcache_arb_st_dirty_din,
  input  logic         vb_dcache_arb_st_dirty_req,
  input  logic         vb_dcache_arb_st_dirty_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  vb_dcache_arb_st_dirty_idx,
  input  logic         vb_dcache_arb_st_dirty_gwen,
  input  logic [4:0]   vb_dcache_arb_st_dirty_wen,
  input  logic [31:0]  vb_dcache_arb_borrow_addr,

  output logic         dcache_arb_vb_ld_grnt,
  output logic         dcache_arb_vb_st_grnt,
  output logic         dcache_arb_ld_dc_borrow_vld,
  output logic         dcache_arb_ld_dc_settle_way,
  output logic         dcache_arb_st_dc_borrow_vld,

  //==========================================================
  // Dcache array interfaces
  //==========================================================
  output logic         lsu_dcache_ld_tag_sel_b,
  output logic         lsu_dcache_ld_tag_gwen_b,
  output logic [1:0]   lsu_dcache_ld_tag_wen_b,
  output logic         lsu_dcache_ld_tag_gateclk_en,
  output logic [INDEX_WIDTH-1:0]  lsu_dcache_ld_tag_idx,
  output logic [LD_TAG_WIDTH-1:0]  lsu_dcache_ld_tag_din,

  output logic         lsu_dcache_st_tag_sel_b,
  output logic         lsu_dcache_st_tag_gwen_b,
  output logic [1:0]   lsu_dcache_st_tag_wen_b,
  output logic         lsu_dcache_st_tag_gateclk_en,
  output logic [INDEX_WIDTH-1:0]  lsu_dcache_st_tag_idx,
  output logic [ST_TAG_WIDTH-1:0]  lsu_dcache_st_tag_din,

  output logic         lsu_dcache_st_dirty_sel_b,
  output logic         lsu_dcache_st_dirty_gwen_b,
  output logic [4:0]   lsu_dcache_st_dirty_wen_b,
  output logic         lsu_dcache_st_dirty_gateclk_en,
  output logic [INDEX_WIDTH-1:0]  lsu_dcache_st_dirty_idx,
  output logic [4:0]   lsu_dcache_st_dirty_din,

  output logic [7:0]   lsu_dcache_ld_data_sel_b,
  output logic [7:0]   lsu_dcache_ld_data_gwen_b,
  output logic [31:0]  lsu_dcache_ld_data_wen_b,
  output logic [7:0]   lsu_dcache_ld_data_gateclk_en,
  output logic [DATA_INDEX_WIDTH-1:0]  lsu_dcache_ld_data_low_idx,
  output logic [DATA_INDEX_WIDTH-1:0]  lsu_dcache_ld_data_high_idx,
  output logic [127:0] lsu_dcache_ld_data_low_din,
  output logic [127:0] lsu_dcache_ld_data_high_din,

  output logic [INDEX_WIDTH-1:0]  dcache_idx,
  output logic         lsu_dcache_ld_xx_gwen,
  output logic [ST_TAG_WIDTH-1:0]  dcache_tag_din,
  output logic         dcache_tag_gwen,
  output logic [1:0]   dcache_tag_wen,
  output logic [4:0]   dcache_dirty_din,
  output logic         dcache_dirty_gwen,
  output logic [4:0]   dcache_dirty_wen
);

//==========================================================
//            Load pipeline arbitration
//==========================================================
// Priority (high to low): LFB > VB > WMB > AG

logic [3:0] dcache_arb_ld_req;
logic [3:0] dcache_arb_ld_sel;
logic dcache_arb_lfb_ld_sel, dcache_arb_vb_ld_sel, dcache_arb_wmb_ld_sel;
logic dcache_arb_lfb_ld_sel_unmask, dcache_arb_vb_ld_sel_unmask;
logic dcache_arb_wmb_ld_sel_unmask, dcache_arb_ag_ld_sel_unmask;

// Store pipeline signals (declared here because used in load masking)
logic [2:0] dcache_arb_st_req;
logic [2:0] dcache_arb_st_sel;
logic dcache_arb_lfb_st_sel, dcache_arb_vb_st_sel;
logic dcache_arb_lfb_st_sel_unmask, dcache_arb_vb_st_sel_unmask, dcache_arb_ag_st_sel_unmask;

assign dcache_arb_ld_req[3:0] = {lfb_dcache_arb_ld_req,
                                 vb_dcache_arb_ld_req,
                                 wmb_dcache_arb_ld_req,
                                 ag_dcache_arb_ld_tag_req};

always_comb begin
  dcache_arb_ld_sel[3:0] = 4'b0;
  casez(dcache_arb_ld_req[3:0])
    4'b1???:  dcache_arb_ld_sel[3] = 1'b1;  // LFB
    4'b01??:  dcache_arb_ld_sel[2] = 1'b1;  // VB
    4'b001?:  dcache_arb_ld_sel[1] = 1'b1;  // WMB
    4'b0001:  dcache_arb_ld_sel[0] = 1'b1;  // AG
    default:  dcache_arb_ld_sel[3:0] = 4'b0;
  endcase
end

assign dcache_arb_lfb_ld_sel_unmask = dcache_arb_ld_sel[3];
assign dcache_arb_vb_ld_sel_unmask  = dcache_arb_ld_sel[2];
assign dcache_arb_wmb_ld_sel_unmask = dcache_arb_ld_sel[1];
assign dcache_arb_ag_ld_sel_unmask  = dcache_arb_ld_sel[0];

// Mask if requesting both ld and st but only got one
assign dcache_arb_lfb_ld_sel = dcache_arb_lfb_ld_sel_unmask
                               && (!lfb_dcache_arb_st_req || dcache_arb_lfb_st_sel_unmask);
assign dcache_arb_vb_ld_sel  = dcache_arb_vb_ld_sel_unmask
                               && (!vb_dcache_arb_st_req || dcache_arb_vb_st_sel_unmask);
assign dcache_arb_wmb_ld_sel = dcache_arb_wmb_ld_sel_unmask;  // WMB doesn't request both
assign dcache_arb_ag_ld_sel  = dcache_arb_ag_ld_sel_unmask;

assign dcache_arb_lfb_ld_grnt = dcache_arb_lfb_ld_sel;
assign dcache_arb_vb_ld_grnt  = dcache_arb_vb_ld_sel;
assign dcache_arb_wmb_ld_grnt = dcache_arb_wmb_ld_sel;

//==========================================================
//            Store pipeline arbitration
//==========================================================
// Priority (high to low): LFB > VB > AG (WMB doesn't use store pipeline)

assign dcache_arb_st_req[2:0] = {lfb_dcache_arb_st_req,
                                 vb_dcache_arb_st_req,
                                 ag_dcache_arb_st_tag_req};

always_comb begin
  dcache_arb_st_sel[2:0] = 3'b0;
  casez(dcache_arb_st_req[2:0])
    3'b1??:  dcache_arb_st_sel[2] = 1'b1;  // LFB
    3'b01?:  dcache_arb_st_sel[1] = 1'b1;  // VB
    3'b001:  dcache_arb_st_sel[0] = 1'b1;  // AG
    default: dcache_arb_st_sel[2:0] = 3'b0;
  endcase
end

assign dcache_arb_lfb_st_sel_unmask = dcache_arb_st_sel[2];
assign dcache_arb_vb_st_sel_unmask  = dcache_arb_st_sel[1];
assign dcache_arb_ag_st_sel_unmask  = dcache_arb_st_sel[0];

// Mask if requesting both ld and st but only got one
assign dcache_arb_lfb_st_sel = dcache_arb_lfb_st_sel_unmask
                               && (!lfb_dcache_arb_ld_req || dcache_arb_lfb_ld_sel_unmask);
assign dcache_arb_vb_st_sel  = dcache_arb_vb_st_sel_unmask
                               && (!vb_dcache_arb_ld_req || dcache_arb_vb_ld_sel_unmask);
assign dcache_arb_ag_st_sel  = dcache_arb_ag_st_sel_unmask;

assign dcache_arb_vb_st_grnt = dcache_arb_vb_st_sel;

//==========================================================
//            Borrow signals for DC stage
//==========================================================
// VB borrows ld/st pipeline when reading victim data
assign dcache_arb_ld_dc_borrow_vld      = vb_dcache_arb_ld_borrow_req && dcache_arb_vb_ld_sel;

assign dcache_arb_st_dc_borrow_vld      = vb_dcache_arb_st_borrow_req && dcache_arb_vb_st_sel;

assign dcache_arb_ld_ag_addr[31:0]      = vb_dcache_arb_borrow_addr[31:0];
assign dcache_arb_ld_ag_borrow_addr_vld = dcache_arb_ld_dc_borrow_vld;
assign dcache_arb_ld_dc_settle_way      = vb_dcache_arb_data_way;
assign dcache_arb_st_ag_addr[31:0]      = vb_dcache_arb_borrow_addr[31:0];
assign dcache_arb_st_ag_borrow_addr_vld = dcache_arb_st_dc_borrow_vld;

//==========================================================
//            Load tag array mux
//==========================================================
assign lsu_dcache_ld_tag_sel_b = !(dcache_arb_lfb_ld_sel || dcache_arb_vb_ld_sel
                                    || dcache_arb_wmb_ld_sel || dcache_arb_ag_ld_sel);

assign lsu_dcache_ld_tag_gwen_b = !(dcache_arb_lfb_ld_sel || dcache_arb_vb_ld_sel
                                     || dcache_arb_wmb_ld_sel);

assign lsu_dcache_ld_tag_gateclk_en = lfb_dcache_arb_ld_tag_gateclk_en
                                       || vb_dcache_arb_ld_tag_gateclk_en
                                       || ag_dcache_arb_ld_tag_gateclk_en;

assign lsu_dcache_ld_tag_idx = ({INDEX_WIDTH{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_vb_ld_sel}} & vb_dcache_arb_ld_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_ag_ld_sel}} & ag_dcache_arb_ld_tag_idx);

assign lsu_dcache_ld_tag_din = ({LD_TAG_WIDTH{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_tag_din)
                                | ({LD_TAG_WIDTH{dcache_arb_vb_ld_sel}} & vb_dcache_arb_ld_tag_din);

assign lsu_dcache_ld_tag_wen_b = ({2{dcache_arb_lfb_ld_sel}} & ~lfb_dcache_arb_ld_tag_wen)
                                  | ({2{dcache_arb_vb_ld_sel}} & ~vb_dcache_arb_ld_tag_wen)
                                  | 2'b11;

//==========================================================
//            Store tag array mux
//==========================================================
assign lsu_dcache_st_tag_sel_b = !(dcache_arb_lfb_st_sel || dcache_arb_vb_st_sel
                                    || dcache_arb_ag_st_sel);

assign lsu_dcache_st_tag_gwen_b = !(dcache_arb_lfb_st_sel);

assign lsu_dcache_st_tag_gateclk_en = lfb_dcache_arb_st_tag_gateclk_en
                                       || vb_dcache_arb_st_tag_gateclk_en
                                       || ag_dcache_arb_st_tag_gateclk_en;

assign lsu_dcache_st_tag_idx = ({INDEX_WIDTH{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_vb_st_sel}} & vb_dcache_arb_st_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_ag_st_sel}} & ag_dcache_arb_st_tag_idx);

assign lsu_dcache_st_tag_din = ({ST_TAG_WIDTH{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_tag_din);

assign lsu_dcache_st_tag_wen_b = ({2{dcache_arb_lfb_st_sel}} & ~lfb_dcache_arb_st_tag_wen) | 2'b11;

assign dcache_tag_din  = lsu_dcache_st_tag_din;
assign dcache_tag_gwen = ~lsu_dcache_st_tag_gwen_b;
assign dcache_tag_wen  = ~lsu_dcache_st_tag_wen_b;

//==========================================================
//            Dirty array mux
//==========================================================
logic vb_dirty_gwen;
assign vb_dirty_gwen = vb_dcache_arb_st_dirty_gwen && dcache_arb_vb_st_sel;

assign lsu_dcache_st_dirty_sel_b = !(dcache_arb_lfb_st_sel || dcache_arb_vb_st_sel
                                      || dcache_arb_ag_st_sel || wmb_dcache_arb_st_req);

assign lsu_dcache_st_dirty_gwen_b = !(dcache_arb_lfb_st_sel || vb_dirty_gwen
                                       || wmb_dcache_arb_st_req);

assign lsu_dcache_st_dirty_gateclk_en = lfb_dcache_arb_st_dirty_gateclk_en
                                         || vb_dcache_arb_st_dirty_gateclk_en
                                         || ag_dcache_arb_st_dirty_gateclk_en
                                         || wmb_dcache_arb_st_dirty_gateclk_en;

assign lsu_dcache_st_dirty_idx = ({INDEX_WIDTH{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_dirty_idx)
                                  | ({INDEX_WIDTH{dcache_arb_vb_st_sel}} & vb_dcache_arb_st_dirty_idx)
                                  | ({INDEX_WIDTH{dcache_arb_ag_st_sel}} & ag_dcache_arb_st_dirty_idx)
                                  | ({INDEX_WIDTH{wmb_dcache_arb_st_req}} & wmb_dcache_arb_st_dirty_idx);


assign lsu_dcache_st_dirty_din = ({5{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_dirty_din)
                                  | ({5{dcache_arb_vb_st_sel}} & vb_dcache_arb_st_dirty_din)
                                  | ({5{wmb_dcache_arb_st_req}} & wmb_dcache_arb_st_dirty_din);


assign lsu_dcache_st_dirty_wen_b = ({5{dcache_arb_lfb_st_sel}} & ~lfb_dcache_arb_st_dirty_wen)
                                    | ({5{dcache_arb_vb_st_sel}} & ~vb_dcache_arb_st_dirty_wen)
                                    | ({5{wmb_dcache_arb_st_req}} & ~wmb_dcache_arb_st_dirty_wen)
                                    | 5'h1F;

assign dcache_dirty_din  = lsu_dcache_st_dirty_din;
assign dcache_dirty_gwen = ~lsu_dcache_st_dirty_gwen_b;
assign dcache_dirty_wen  = ~lsu_dcache_st_dirty_wen_b;

//==========================================================
//            Data array mux
//==========================================================
assign lsu_dcache_ld_data_sel_b = {8{!(dcache_arb_lfb_ld_sel || dcache_arb_vb_ld_sel
                                        || dcache_arb_wmb_ld_sel)}} || ag_dcache_arb_ld_data_req;

assign lsu_dcache_ld_data_gwen_b = {8{!(dcache_arb_lfb_ld_sel || dcache_arb_wmb_ld_sel)}};

assign lsu_dcache_ld_data_gateclk_en = lfb_dcache_arb_ld_data_gateclk_en
                                        | vb_dcache_arb_ld_data_gateclk_en
                                        | wmb_dcache_arb_ld_data_gateclk_en
                                        | ag_dcache_arb_ld_data_gateclk_en;

// LFB and VB use single index for all banks
assign lsu_dcache_ld_data_low_idx = ({DATA_INDEX_WIDTH{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_data_idx)
                                     | ({DATA_INDEX_WIDTH{dcache_arb_vb_ld_sel}} & vb_dcache_arb_ld_data_idx)
                                     | ({DATA_INDEX_WIDTH{dcache_arb_wmb_ld_sel}} & wmb_dcache_arb_ld_data_low_idx)
                                     | ({DATA_INDEX_WIDTH{dcache_arb_ag_ld_sel}} & ag_dcache_arb_ld_data_low_idx);

assign lsu_dcache_ld_data_high_idx = ({DATA_INDEX_WIDTH{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_data_idx)
                                      | ({DATA_INDEX_WIDTH{dcache_arb_vb_ld_sel}} & vb_dcache_arb_ld_data_idx)
                                      | ({DATA_INDEX_WIDTH{dcache_arb_wmb_ld_sel}} & wmb_dcache_arb_ld_data_high_idx)
                                      | ({DATA_INDEX_WIDTH{dcache_arb_ag_ld_sel}} & ag_dcache_arb_ld_data_high_idx);

assign lsu_dcache_ld_data_low_din = ({128{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_data_low_din)
                                     | ({128{dcache_arb_wmb_ld_sel}} & wmb_dcache_arb_ld_data_low_din);

assign lsu_dcache_ld_data_high_din = ({128{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_data_high_din)
                                      | ({128{dcache_arb_wmb_ld_sel}} & wmb_dcache_arb_ld_data_high_din);

assign lsu_dcache_ld_data_wen_b = ({32{dcache_arb_lfb_ld_sel}} & 32'h0)
                                   | ({32{dcache_arb_wmb_ld_sel}} & ~wmb_dcache_arb_ld_data_wen)
                                   | 32'hFFFF_FFFF;

assign lsu_dcache_ld_xx_gwen = ~lsu_dcache_ld_data_gwen_b[0];

// Index for compatibility
assign dcache_idx = lsu_dcache_st_dirty_idx;

endmodule