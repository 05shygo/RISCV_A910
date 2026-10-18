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
    // 2026-10-15 停用: 非对齐"第二半"表项 (addr1/bytes_vld1/create1/secd) 整条摘掉
    //input  logic [27:0]  ld_dc_addr1_to4,
    input  logic [15:0]  ld_dc_bytes_vld,
    //input  logic [15:0]  ld_dc_bytes_vld1,
    input  logic [6:0]   ld_dc_iid,
    // 2026-10-17 S7
    input  logic         ld_dc_vec,
    input  logic         ld_dc_old,
    input  logic [4:0]   ld_dc_uop_idx,
    input  logic [4:0]   ld_dc_beat_idx,
    //input  logic         ld_dc_lq_create1_vld,
    input  logic         ld_dc_lq_create_vld,
    //input  logic         ld_dc_secd,
    input  logic         rtu_yy_xx_commit0,
    input  logic [6:0]   rtu_yy_xx_commit0_iid,
    input  logic         rtu_yy_xx_commit1,
    input  logic [6:0]   rtu_yy_xx_commit1_iid,
    input  logic         rtu_yy_xx_commit2,
    input  logic [6:0]   rtu_yy_xx_commit2_iid,
    // 2026-10-18: 向量 beat 提前提交窗口 (电平)
    input  logic [2:0]   rtu_yy_xx_win_valid,
    input  logic [6:0]   rtu_yy_xx_win_iid0,
    input  logic [6:0]   rtu_yy_xx_win_iid1,
    input  logic [6:0]   rtu_yy_xx_win_iid2,
    input  logic         rtu_yy_xx_flush,
    input  logic [31:0]  st_dc_addr0,
    input  logic [15:0]  st_dc_bytes_vld,
    input  logic         st_dc_chk_st_inst_vld,
    input  logic [6:0]   st_dc_iid,
    input  logic         st_dc_vec,
    input  logic [4:0]   st_dc_uop_idx,
    output logic         lq_ld_dc_full,
    output logic         lq_ld_dc_inst_hit,
    output logic         lq_ld_dc_less2,
    output logic         lq_st_dc_spec_fail,
    output logic         lsu_idu_lq_not_full
);

parameter LQ_ENTRY = 16;
genvar i;

// 内部信号
logic [LQ_ENTRY-1:0] lq_create_ptr0;
logic        lq_create_success;
logic [LQ_ENTRY-1:0] lq_entry_create0_vld;
logic [LQ_ENTRY-1:0] lq_entry_inst_hit;
logic [LQ_ENTRY-1:0] lq_entry_raw_spec_fail;
logic [LQ_ENTRY-1:0] lq_entry_vld;
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
      //.ld_dc_addr1_to4          (ld_dc_addr1_to4),
      .ld_dc_bytes_vld          (ld_dc_bytes_vld),
      //.ld_dc_bytes_vld1         (ld_dc_bytes_vld1),
      .ld_dc_iid                (ld_dc_iid),
      .ld_dc_vec                (ld_dc_vec),
      .ld_dc_old                (ld_dc_old),
      .ld_dc_uop_idx            (ld_dc_uop_idx),
      .ld_dc_beat_idx           (ld_dc_beat_idx),
      //.ld_dc_secd               (ld_dc_secd),
      .lq_entry_create0_vld_x   (lq_entry_create0_vld[i]),
      //.lq_entry_create1_vld_x   (lq_entry_create1_vld[i]),
      .rtu_yy_xx_commit0        (rtu_yy_xx_commit0),
      .rtu_yy_xx_commit0_iid    (rtu_yy_xx_commit0_iid),
      .rtu_yy_xx_commit1        (rtu_yy_xx_commit1),
      .rtu_yy_xx_commit1_iid    (rtu_yy_xx_commit1_iid),
      .rtu_yy_xx_commit2        (rtu_yy_xx_commit2),
      .rtu_yy_xx_commit2_iid    (rtu_yy_xx_commit2_iid),
      .rtu_yy_xx_win_valid      (rtu_yy_xx_win_valid),
      .rtu_yy_xx_win_iid0       (rtu_yy_xx_win_iid0),
      .rtu_yy_xx_win_iid1       (rtu_yy_xx_win_iid1),
      .rtu_yy_xx_win_iid2       (rtu_yy_xx_win_iid2),
      .rtu_yy_xx_flush          (rtu_yy_xx_flush),
      .st_dc_addr0              (st_dc_addr0),
      .st_dc_bytes_vld          (st_dc_bytes_vld),
      .st_dc_chk_st_inst_vld    (st_dc_chk_st_inst_vld),
      .st_dc_iid                (st_dc_iid),
      .st_dc_vec                (st_dc_vec),
      .st_dc_uop_idx            (st_dc_uop_idx),
      .lq_entry_inst_hit_x      (lq_entry_inst_hit[i]),
      .lq_entry_raw_spec_fail_x (lq_entry_raw_spec_fail[i]),
      .lq_entry_vld_x           (lq_entry_vld[i])
    );
  end
endgenerate

//==========================================================
//                 Generate create pointer
//==========================================================
// 最低空闲项优先 (LQ_ENTRY 可配置)
always @(*)
begin
  lq_create_ptr0 = {LQ_ENTRY{1'b0}};
  for (int k=0; k<LQ_ENTRY; k++) begin
    if (!lq_entry_vld[k]) begin
      lq_create_ptr0[k] = 1'b1;
      break;
    end
  end
end

assign lq_full = &lq_entry_vld[LQ_ENTRY-1:0];

//==========================================================
//                 Generate create pointer
//==========================================================
// 2026-10-15 停用: 末项 `&& !ld_dc_lq_create1_vld` 恒为真 (create1 已摘)
assign lq_create_success  = ld_dc_lq_create_vld
                            &&  !rtu_yy_xx_flush
                            &&  ( !lq_ld_dc_less2
                                  || !lq_ld_dc_full );//&& !ld_dc_lq_create1_vld);

// 2026-10-15 停用: create1 (非对齐第二半) 的表项创建
//assign lq_create1_success = lq_create_success
//                            && ld_dc_lq_create1_vld;

assign lq_entry_create0_vld[LQ_ENTRY-1:0] = {LQ_ENTRY{lq_create_success}}
                                            & lq_create_ptr0[LQ_ENTRY-1:0];

//==========================================================
//                 Generate interface
//==========================================================
// &Force("output", "lq_ld_dc_full"); @181
// &Force("output", "lq_ld_dc_less2"); @182
assign lq_ld_dc_full        = lq_full;
assign lq_ld_dc_less2       = &(lq_create_ptr0[LQ_ENTRY-1:0] | lq_entry_vld[LQ_ENTRY-1:0]);
assign lq_ld_dc_inst_hit    = |lq_entry_inst_hit[LQ_ENTRY-1:0];
assign lq_st_dc_spec_fail   = |lq_entry_raw_spec_fail[LQ_ENTRY-1:0];

assign lsu_idu_lq_not_full  = !lq_full;

// &ModuleEnd; @191
endmodule