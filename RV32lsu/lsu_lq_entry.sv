module ct_lsu_lq_entry (
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [31:0]  ld_dc_addr0,
    input  logic [15:0]  ld_dc_bytes_vld,
    input  logic [15:0]  ld_dc_bytes_vld1,
    input  logic [6:0]   ld_dc_iid,
    input  logic         ld_dc_secd,
    input  logic         lq_entry_create0_vld_x,
    input  logic         lq_entry_create1_vld_x,
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
    output logic         lq_entry_inst_hit_x,
    output logic         lq_entry_raw_spec_fail_x,
    output logic         lq_entry_vld_x
);

// 内部寄存器
logic [27:0] lq_entry_addr0_tto4;
logic [15:0] lq_entry_bytes_vld;
logic [6:0]  lq_entry_iid;
logic        lq_entry_secd;
logic        lq_entry_vld;

// 内部组合信号
logic        lq_entry_cmit_hit0;
logic        lq_entry_cmit_hit1;
logic        lq_entry_cmit_hit2;
logic        lq_entry_cmit_vld;
logic        lq_entry_create0_dp_vld;
logic        lq_entry_create0_vld;
logic        lq_entry_create1_dp_vld;
logic        lq_entry_create1_vld;
logic [39:0] lq_entry_from_ld_dc_addr0;
logic [39:0] lq_entry_from_ld_dc_addr1;
logic [39:0] lq_entry_from_st_dc_addr0;
logic        lq_entry_iid_newer_than_st_dc;
logic        lq_entry_inst_hit;
logic        lq_entry_newer_than_st_dc;
logic        lq_entry_pop_vld;
logic        lq_entry_raw_addr_tto4_hit;
logic        lq_entry_raw_do_hit;
logic        lq_entry_raw_spec_fail;
logic        lq_entry_raw_spec_fail1;

//==========================================================
//                 Register
//==========================================================
//+-----------+
//| entry_vld |
//+-----------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lq_entry_vld  <=  1'b0;
  else if(lq_entry_pop_vld  ||  rtu_yy_xx_flush)
    lq_entry_vld  <=  1'b0;
  else if(lq_entry_create0_vld || lq_entry_create1_vld)
    lq_entry_vld  <=  1'b1;
end

//+-----------+------------+-----+--------+------+
//| addr_tto2 | bytes_vld0 | iid | deform | secd |
//+-----------+------------+-----+--------+------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    lq_entry_addr0_tto4[27:0]  <=  {28{1'b0}};
    lq_entry_bytes_vld[15:0]  <=  16'b0;
    lq_entry_iid[6:0]         <=  7'b0;
    lq_entry_secd             <=  1'b0;
  end
  else if(lq_entry_create0_vld)
  begin
    lq_entry_addr0_tto4[27:0] <=  lq_entry_from_ld_dc_addr0[31:4];
    lq_entry_bytes_vld[15:0]  <=  ld_dc_bytes_vld[15:0];
    lq_entry_iid[6:0]         <=  ld_dc_iid[6:0];
    lq_entry_secd             <=  ld_dc_secd;
  end
  else if(lq_entry_create1_vld)
  begin
    lq_entry_addr0_tto4[27:0] <=  lq_entry_from_ld_dc_addr1[31:4];
    lq_entry_bytes_vld[15:0]  <=  ld_dc_bytes_vld1[15:0];
    lq_entry_iid[6:0]         <=  ld_dc_iid[6:0];
    lq_entry_secd             <=  1'b1;
  end
end

//==========================================================
//                 Generate pop signal
//==========================================================
assign lq_entry_cmit_hit0 = rtu_yy_xx_commit0
                            &&  lq_entry_vld
                            &&  (rtu_yy_xx_commit0_iid[6:0]  ==  lq_entry_iid[6:0]);
assign lq_entry_cmit_hit1 = rtu_yy_xx_commit1
                            &&  lq_entry_vld
                            &&  (rtu_yy_xx_commit1_iid[6:0]  ==  lq_entry_iid[6:0]);
assign lq_entry_cmit_hit2 = rtu_yy_xx_commit2
                            &&  lq_entry_vld
                            &&  (rtu_yy_xx_commit2_iid[6:0]  ==  lq_entry_iid[6:0]);

assign lq_entry_cmit_vld  = (lq_entry_cmit_hit0
                                ||  lq_entry_cmit_hit1
                                ||  lq_entry_cmit_hit2)
                            &&  lq_entry_vld;

assign lq_entry_pop_vld   = lq_entry_cmit_vld;

//==========================================================
//                 lq iid check
//==========================================================
//check iid to judge whether to create lq
assign lq_entry_inst_hit  = lq_entry_vld
                            &&  (lq_entry_secd  ==  ld_dc_secd)
                            &&  (lq_entry_iid[6:0] ==  ld_dc_iid[6:0]);

//==========================================================
//                 RAR speculation check
//==========================================================


//==========================================================
//                 RAW speculation check
//==========================================================
// situat st pipe             lq        addr      bytes_vld
// 1      st/stex             ld        31:4      x

//------------------compare signal--------------------------
//compare the instruction in the entry is newer or older
// &Instance("ct_rtu_compare_iid","x_lsu_lq_entry_compare_st_dc_iid"); @169
ct_rtu_compare_iid  x_lsu_lq_entry_compare_st_dc_iid (
  .x_iid0                        (st_dc_iid[6:0]               ),
  .x_iid0_older                  (lq_entry_iid_newer_than_st_dc),
  .x_iid1                        (lq_entry_iid[6:0]            )
);

// &Connect( .x_iid0         (st_dc_iid[6:0]       ), @170
//           .x_iid1         (lq_entry_iid[6:0]    ), @171
//           .x_iid0_older   (lq_entry_iid_newer_than_st_dc)); @172

assign lq_entry_newer_than_st_dc  = lq_entry_vld
                                    &&  lq_entry_iid_newer_than_st_dc;
//addr0 compare
assign lq_entry_from_st_dc_addr0[31:0] = st_dc_addr0[31:0];
assign lq_entry_raw_addr_tto4_hit   = lq_entry_addr0_tto4[27:0]
                                      ==  lq_entry_from_st_dc_addr0[31:4];

//bytes_vld compare
assign lq_entry_raw_do_hit       = |(lq_entry_bytes_vld[15:0]  & st_dc_bytes_vld[15:0]);

//------------------situation 1-----------------------------
assign lq_entry_raw_spec_fail1    = lq_entry_newer_than_st_dc
                                    &&  st_dc_chk_st_inst_vld
                                    &&  lq_entry_raw_addr_tto4_hit
                                    &&  lq_entry_raw_do_hit;

//------------------combine---------------------------------
assign lq_entry_raw_spec_fail     = lq_entry_raw_spec_fail1;

//==========================================================
//                 Generate interface
//==========================================================
//------------------input-----------------------------------
assign lq_entry_create0_vld         = lq_entry_create0_vld_x;
assign lq_entry_create1_vld         = lq_entry_create1_vld_x;
//------------------output----------------------------------
assign lq_entry_vld_x               = lq_entry_vld;
assign lq_entry_inst_hit_x          = lq_entry_inst_hit;
assign lq_entry_raw_spec_fail_x     = lq_entry_raw_spec_fail;

// &ModuleEnd; @209
endmodule