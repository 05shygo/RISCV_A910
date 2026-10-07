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

// &ModuleBeg; @25
module ct_lsu_lq (
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [31:0]  ld_dc_addr0,
    input  logic [15:0]  ld_dc_bytes_vld,
    input  logic [15:0]  ld_dc_bytes_vld1,
    input  logic [6:0]   ld_dc_iid,
    input  logic         ld_dc_lq_create1_vld,
    input  logic         ld_dc_lq_create_vld,
    input  logic         ld_dc_secd,
    input  logic         rtu_yy_xx_commit0,
    input  logic [6:0]   rtu_yy_xx_commit0_iid,
    input  logic         rtu_yy_xx_commit1,
    input  logic [6:0]   rtu_yy_xx_commit1_iid,
    input  logic         rtu_yy_xx_commit2,
    input  logic [6:0]   rtu_yy_xx_commit2_iid,
    input  logic         rtu_yy_xx_flush,
    input  logic [31:0]  st_dc_addr0,
    input  logic [15:0]  st_dc_bytes_vld,
    input  logic         st_dc_chk_st_inst_vld,
    input  logic [6:0]   st_dc_iid,
    output logic         lq_ld_dc_full,
    output logic         lq_ld_dc_inst_hit,
    output logic         lq_ld_dc_less2,
    output logic         lq_st_dc_spec_fail,
    output logic         lsu_idu_lq_not_full
);

parameter LQ_ENTRY = 8;
genvar i;

// 内部信号
logic [7:0]  lq_create_ptr0;
logic [7:0]  lq_create_ptr1;
logic        lq_create_success;
logic        lq_create1_success;
logic [7:0]  lq_entry_create0_vld;
logic [7:0]  lq_entry_create1_vld;
logic [7:0]  lq_entry_inst_hit;
logic [7:0]  lq_entry_raw_spec_fail;
logic [7:0]  lq_entry_vld;
logic        lq_full;

//==========================================================
//                 Instance load queue entry
//==========================================================
generate
  for (i = 0; i < LQ_ENTRY; i = i + 1) begin : gen_lq_entry
    ct_lsu_lq_entry u_lq_entry (
      .cpurst_b                 (cpurst_b),
      .forever_cpuclk           (forever_cpuclk),
      .ld_dc_addr0              (ld_dc_addr0),
      .ld_dc_bytes_vld          (ld_dc_bytes_vld),
      .ld_dc_bytes_vld1         (ld_dc_bytes_vld1),
      .ld_dc_iid                (ld_dc_iid),
      .ld_dc_secd               (ld_dc_secd),
      .lq_entry_create0_vld_x   (lq_entry_create0_vld[i]),
      .lq_entry_create1_vld_x   (lq_entry_create1_vld[i]),
      .rtu_yy_xx_commit0        (rtu_yy_xx_commit0),
      .rtu_yy_xx_commit0_iid    (rtu_yy_xx_commit0_iid),
      .rtu_yy_xx_commit1        (rtu_yy_xx_commit1),
      .rtu_yy_xx_commit1_iid    (rtu_yy_xx_commit1_iid),
      .rtu_yy_xx_commit2        (rtu_yy_xx_commit2),
      .rtu_yy_xx_commit2_iid    (rtu_yy_xx_commit2_iid),
      .rtu_yy_xx_flush          (rtu_yy_xx_flush),
      .st_dc_addr0              (st_dc_addr0),
      .st_dc_bytes_vld          (st_dc_bytes_vld),
      .st_dc_chk_st_inst_vld    (st_dc_chk_st_inst_vld),
      .st_dc_iid                (st_dc_iid),
      .lq_entry_inst_hit_x      (lq_entry_inst_hit[i]),
      .lq_entry_raw_spec_fail_x (lq_entry_raw_spec_fail[i]),
      .lq_entry_vld_x           (lq_entry_vld[i])
    );
  end
endgenerate

//==========================================================
//                 Generate create pointer
//==========================================================
// &CombBeg; @101
always @( lq_entry_vld[7:0])
begin
  lq_create_ptr0[7:0] = 8'b0;
  casez(lq_entry_vld[7:0])
    8'b????_???0: lq_create_ptr0[0] = 1'b1;
    8'b????_??01: lq_create_ptr0[1] = 1'b1;
    8'b????_?011: lq_create_ptr0[2] = 1'b1;
    8'b????_0111: lq_create_ptr0[3] = 1'b1;
    8'b???0_1111: lq_create_ptr0[4] = 1'b1;
    8'b??01_1111: lq_create_ptr0[5] = 1'b1;
    8'b?011_1111: lq_create_ptr0[6] = 1'b1;
    8'b0111_1111: lq_create_ptr0[7] = 1'b1;
    default:      lq_create_ptr0[7:0] = 8'b0;
  endcase
// &CombEnd; @122
end

// &CombBeg; @124
always @( lq_entry_vld[7:0])
begin
  lq_create_ptr1[7:0] = 8'b0;
  casez(lq_entry_vld[7:0])
    8'b0???_????: lq_create_ptr1[7] = 1'b1;
    8'b10??_????: lq_create_ptr1[6] = 1'b1;
    8'b110?_????: lq_create_ptr1[5] = 1'b1;
    8'b1110_????: lq_create_ptr1[4] = 1'b1;
    8'b1111_0???: lq_create_ptr1[3] = 1'b1;
    8'b1111_10??: lq_create_ptr1[2] = 1'b1;
    8'b1111_110?: lq_create_ptr1[1] = 1'b1;
    8'b1111_1110: lq_create_ptr1[0] = 1'b1;
    default:      lq_create_ptr1[7:0] = 8'b0;
  endcase
// &CombEnd; @145
end

assign lq_full = &lq_entry_vld[7:0];

//==========================================================
//                 Generate create pointer
//==========================================================
assign lq_create_success  = ld_dc_lq_create_vld
                            &&  !rtu_yy_xx_flush
                            &&  (!lq_ld_dc_less2 
                                 || !lq_ld_dc_full && !ld_dc_lq_create1_vld);

assign lq_create1_success = lq_create_success
                            && ld_dc_lq_create1_vld;

assign lq_entry_create0_vld[7:0] = {8{lq_create_success}}
                                   & lq_create_ptr0[7:0];

assign lq_entry_create1_vld[7:0] = {8{lq_create1_success}}
                                   & lq_create_ptr1[7:0];

//==========================================================
//                 Generate interface
//==========================================================
// &Force("output", "lq_ld_dc_full"); @181
// &Force("output", "lq_ld_dc_less2"); @182
assign lq_ld_dc_full        = lq_full;
assign lq_ld_dc_less2       = &(lq_create_ptr0[7:0] | lq_entry_vld[7:0]);
assign lq_ld_dc_inst_hit    = |lq_entry_inst_hit[7:0];
assign lq_st_dc_spec_fail   = |lq_entry_raw_spec_fail[7:0];

assign lsu_idu_lq_not_full  = !lq_full;

// &ModuleEnd; @191
endmodule