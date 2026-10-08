module lsu_ld_da #(
    parameter int IID_WIDTH     = 6,
    parameter int LSIQ_ENTRY = 8,
    parameter int DC_IDX        = 8,
    parameter int SQ_ENTRY      = 6
)(
    input  logic                          forever_cpuclk,
    input  logic                          cpurst_b,

    input  logic                          ld_dc_da_inst_vld,
    input  logic                          ld_dc_borrow_vld,
    input  logic [1:0]                    ld_dc_inst_size,
    input  logic                          ld_dc_boundary,
    input  logic                          ld_dc_secd,
    input  logic                          ld_dc_sign_extend,
    input  logic [6:0]                    ld_dc_iid,
    input  logic [LSIQ_ENTRY-1:0]         ld_dc_lsid,
    input  logic                          ld_dc_old,
    input  logic [5:0]                    ld_dc_preg,
    input  logic [15:0]                   ld_dc_bytes_vld,
    input  logic [15:0]                   ld_dc_bytes_vld1,
    input  logic                          ld_dc_acclr_en,
    input  logic                          ld_dc_da_cb_merge_en,
    input  logic                          ld_dc_raw_new,
    input  logic [31:0]                   ld_dc_addr0,
    input  logic                          ld_dc_cb_addr_create_vld,

    input  logic                          rtu_yy_xx_flush,
    input  logic [31:0]                   dcache_lsu_ld_data_bank0_dout,
    input  logic [31:0]                   dcache_lsu_ld_data_bank1_dout,
    input  logic [31:0]                   dcache_lsu_ld_data_bank2_dout,
    input  logic [31:0]                   dcache_lsu_ld_data_bank3_dout,
    input  logic [31:0]                   dcache_lsu_ld_data_bank4_dout,
    input  logic [31:0]                   dcache_lsu_ld_data_bank5_dout,
    input  logic [31:0]                   dcache_lsu_ld_data_bank6_dout,
    input  logic [31:0]                   dcache_lsu_ld_data_bank7_dout,
    input  logic                          ld_dc_hit_low_region,
    input  logic                          ld_dc_hit_high_region,
    input  logic                          ld_dc_dcache_hit,
    input  logic [7:0]                    ld_dc_da_data_rot_sel,
    input  logic [3:0]                    ld_dc_preg_sign_sel,
    input  logic [15:0]                   ld_dc_fwd_bytes_vld,
    input  logic                          ld_dc_fwd_sq_vld,
    input  logic                          ld_dc_fwd_wmb_vld,
    input  logic [SQ_ENTRY-1:0]           sq_ld_dc_fwd_id,
    output logic [SQ_ENTRY-1:0]           ld_da_sq_fwd_id,
    output logic                          ld_da_sq_data_discard_vld,
    output logic                          ld_da_sq_fwd_multi_vld,
    output logic                          ld_da_sq_global_discard_vld,
    input  logic                          cb_ld_da_data_vld,
    input  logic [127:0]                  cb_ld_da_data,

    input  logic                          sq_ld_dc_other_discard_req,
    input  logic                          sq_ld_dc_data_discard_req,
    input  logic                          sq_ld_dc_fwd_multi,
    input  logic                          sq_ld_dc_fwd_multi_mask,
    input  logic [31:0]                   sq_ld_da_fwd_data,
    input  logic [127:0]                  wmb_ld_da_fwd_data,
    input  logic                          sd_ex1_inst_vld,
    input  logic                          rb_ld_da_hit_idx,
    input  logic                          rb_ld_da_merge_fail,
    input  logic                          lfb_ld_da_hit_idx,
    input  logic                          rb_ld_da_full,
    input  logic                          rtu_yy_xx_commit0,
    input  logic [6:0]                    rtu_yy_xx_commit0_iid,
    input  logic                          rtu_yy_xx_commit1,
    input  logic [6:0]                    rtu_yy_xx_commit1_iid,
    input  logic                          rtu_yy_xx_commit2,
    input  logic [6:0]                    rtu_yy_xx_commit2_iid,
    input  logic                          ld_da_discard_wmb,

    output logic [1:0]                    ld_da_inst_size,
    output logic                          ld_da_boundary,
    output logic                          ld_da_secd,
    output logic                          ld_da_sign_extend,
    output logic [6:0]                    ld_da_iid,
    output logic [LSIQ_ENTRY-1:0]         ld_da_lsid,
    output logic                          ld_da_old,
    output logic [5:0]                    ld_da_preg,
    output logic [15:0]                   ld_da_bytes_vld,
    output logic [15:0]                   ld_da_bytes_vld1,
    output logic                          ld_da_acclr_en,
    output logic                          ld_da_raw_new,
    output logic [31:0]                   ld_da_addr0,
    output logic                          ld_da_cb_addr_create_vld,

    output logic                          ld_da_rb_data_vld,
    output logic                          ld_da_rb_discard_grnt,
    output logic                          ld_da_lfb_discard_grnt,
    output logic                          ld_da_rb_cmit,
    output logic [31:0]                   ld_da_addr,
    output logic                          ld_da_boundary_after_mask,
    output logic [4:0]                    ld_da_idx,

    output logic                          ld_da_wb_cmplt_req,
    output logic                          ld_da_wb_data_req,
    output logic [31:0]                   ld_da_wb_data,
    output logic [3:0]                    ld_da_preg_sign_sel,

    output logic                          ld_da_rb_merge_vld,
    output logic                          ld_da_rb_create_vld,
    output logic [7:0]                    ld_da_data_rot_sel,

    output logic                          ld_da_cb_ld_inst_vld,
    output logic                          ld_da_cb_data_vld,
    output logic [127:0]                  ld_da_cb_data,

    output logic [LSIQ_ENTRY-1:0]         ld_da_idu_rb_full,
    output logic [LSIQ_ENTRY-1:0]         ld_da_idu_pop_entry,
    output logic [LSIQ_ENTRY-1:0]         ld_da_idu_secd,
    output logic                          ld_da_vb_borrow_vb,
    output logic [255:0]                  ld_da_data256,
    input  logic                          ld_dc_settle_way
);

logic                          ld_da_cb_merge_en;
logic                          ld_da_fwd_sq_vld;
logic                          ld_da_fwd_wmb_vld;
logic [15:0]                   ld_da_fwd_bytes_vld;



logic                          ld_da_other_discard_sq;
logic                          ld_da_data_discard_sq;
logic                          ld_da_fwd_sq_bypass;
logic                          ld_da_fwd_sq_multi;
logic                          ld_da_fwd_sq_multi_mask;
logic                          ld_da_fwd_bypass_sq_multi;

logic                          ld_da_dcache_hit;
logic                          ld_da_hit_low_region;
logic                          ld_da_hit_high_region;

logic [127:0]                  ld_da_dcache_pass_data128_am;
logic [127:0]                  ld_da_cb_bypass_data_am;
logic [127:0]                  ld_da_cb_bypass_data_for_merge;
logic [127:0]                  ld_da_dcache_data_after_merge;
logic [127:0]                  ld_da_data_unrot;
logic [127:0]                  ld_da_data_settle;
logic [127:0]                  ld_da_data128;

logic [63:0]                   ld_da_ahead_preg_data_sign0;
logic [63:0]                   ld_da_ahead_preg_data_sign1;
logic [63:0]                   ld_da_ahead_preg_data_sign2;
logic [63:0]                   ld_da_ahead_preg_data_sign3;
logic [63:0]                   ld_da_preg_data_sign_extend;

logic                          ld_da_rb_create_vld_unmask;
logic                          ld_da_discard_from_rb_req;
logic                          ld_da_rb_merge_vld_unmask;
logic                          ld_da_discard_from_lfb_req;
logic                          ld_da_hit_idx_discard_req;

logic                          ld_da_inst_vld;
logic                          ld_da_borrow_vld;

logic                          ld_da_cmit_hit0;
logic                          ld_da_cmit_hit1;
logic                          ld_da_cmit_hit2;

logic                          ld_da_data_discard_sq_final;
logic                          ld_da_fwd_sq_multi_final;
logic                          ld_da_discard_wmb_final;
logic                          ld_da_discard_dc_req;

logic [LSIQ_ENTRY-1:0]         ld_da_mask_lsid;

logic                          ld_da_boundary_first;

logic                          ld_da_restart_vld;
logic                          ld_da_rb_full_req;
logic                          ld_da_other_discard_sq_req;
logic                          ld_da_data_discard_sq_req;
logic                          ld_da_rb_full_vld;
logic                          ld_da_idu_pop_vld;
logic                          ld_da_idu_secd_vld;

logic [127:0]                  sq_ld_da_fwd_data_128;
logic [127:0]                  wmb_ld_da_fwd_data_128;
logic [127:0]                  ld_da_fwd_wmb_data_am;
logic [127:0]                  ld_da_fwd_sq_data_am;
logic [127:0]                  ld_da_fwd_data_am;
logic [127:0]                  ld_da_fwd_data_bypass;
logic                          ld_da_fwd_sq_bypass_vld;
logic                          ld_da_fwd_vld;
logic                          ld_da_merge_from_cb;
logic [127:0]                  ld_da_high_region_data128_am;
logic [127:0]                  ld_da_low_region_data128_am;
logic                          ld_da_data_vld;

logic [31:0]                   ld_da_dcache_data_bank0;
logic [31:0]                   ld_da_dcache_data_bank1;
logic [31:0]                   ld_da_dcache_data_bank2;
logic [31:0]                   ld_da_dcache_data_bank3;
logic [31:0]                   ld_da_dcache_data_bank4;
logic [31:0]                   ld_da_dcache_data_bank5;
logic [31:0]                   ld_da_dcache_data_bank6;
logic [31:0]                   ld_da_dcache_data_bank7;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_da_inst_vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    ld_da_inst_vld <= 1'b0;
  else if(ld_dc_da_inst_vld)
    ld_da_inst_vld <= 1'b1;
  else
    ld_da_inst_vld <= 1'b0;
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_da_borrow_vld <= 1'b0;
  else if(ld_dc_borrow_vld)
    ld_da_borrow_vld <= 1'b1;
  else
    ld_da_borrow_vld <= 1'b0;
end

logic                          ld_da_settle_way;
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    ld_da_settle_way                    <=  1'b0;
  end
  else if(ld_dc_borrow_vld)
  begin
    ld_da_settle_way                    <=  ld_dc_settle_way;
  end
end

assign ld_da_vb_borrow_vb = ld_da_borrow_vld;

always @(posedge forever_cpuclk)
begin
  ld_da_dcache_data_bank0[31:0] <= dcache_lsu_ld_data_bank0_dout[31:0];
  ld_da_dcache_data_bank4[31:0] <= dcache_lsu_ld_data_bank4_dout[31:0];
end

always @(posedge forever_cpuclk)
begin
  ld_da_dcache_data_bank1[31:0] <= dcache_lsu_ld_data_bank1_dout[31:0];
  ld_da_dcache_data_bank5[31:0] <= dcache_lsu_ld_data_bank5_dout[31:0];
end

always @(posedge forever_cpuclk)
begin
  ld_da_dcache_data_bank2[31:0] <= dcache_lsu_ld_data_bank2_dout[31:0];
  ld_da_dcache_data_bank6[31:0] <= dcache_lsu_ld_data_bank6_dout[31:0];
end

always @(posedge forever_cpuclk)
begin
  ld_da_dcache_data_bank3[31:0] <= dcache_lsu_ld_data_bank3_dout[31:0];
  ld_da_dcache_data_bank7[31:0] <= dcache_lsu_ld_data_bank7_dout[31:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    ld_da_inst_size         <= 2'b0;
    ld_da_boundary          <= 1'b0;
    ld_da_secd              <= 1'b0;
    ld_da_sign_extend       <= 1'b0;
    ld_da_iid               <= {IID_WIDTH+1{1'b0}};
    ld_da_lsid              <= {LSIQ_ENTRY{1'b0}};
    ld_da_old               <= 1'b0;
    ld_da_preg              <= 7'b0;
    ld_da_bytes_vld         <= 16'b0;
    ld_da_bytes_vld1        <= 16'b0;
    ld_da_acclr_en          <= 1'b0;
    ld_da_cb_merge_en       <= 1'b0;
    ld_da_raw_new           <= 1'b0;
    ld_da_addr0             <= 32'b0;
    ld_da_cb_addr_create_vld<= 1'b0;
    ld_da_fwd_sq_vld        <= 1'b0;
    ld_da_fwd_wmb_vld       <= 1'b0;
    ld_da_fwd_bytes_vld     <= 16'b0;
    ld_da_data_rot_sel      <= 8'b0;
    ld_da_preg_sign_sel     <= 4'b0;
  end
  else if(ld_dc_da_inst_vld) begin
    ld_da_inst_size         <= ld_dc_inst_size;
    ld_da_boundary          <= ld_dc_boundary;
    ld_da_secd              <= ld_dc_secd;
    ld_da_sign_extend       <= ld_dc_sign_extend;
    ld_da_iid               <= ld_dc_iid;
    ld_da_lsid              <= ld_dc_lsid;
    ld_da_old               <= ld_dc_old;
    ld_da_preg              <= ld_dc_preg;
    ld_da_bytes_vld         <= ld_dc_bytes_vld;
    ld_da_bytes_vld1        <= ld_dc_bytes_vld1;
    ld_da_acclr_en          <= ld_dc_acclr_en;
    ld_da_cb_merge_en       <= ld_dc_da_cb_merge_en;
    ld_da_raw_new           <= ld_dc_raw_new;
    ld_da_addr0             <= ld_dc_addr0;
    ld_da_cb_addr_create_vld<= ld_dc_cb_addr_create_vld;

    ld_da_fwd_sq_vld        <= ld_dc_fwd_sq_vld;
    ld_da_fwd_wmb_vld       <= ld_dc_fwd_wmb_vld;
    ld_da_fwd_bytes_vld     <= ld_dc_fwd_bytes_vld;
    ld_da_sq_fwd_id         <= sq_ld_dc_fwd_id;
    ld_da_data_rot_sel      <= ld_dc_da_data_rot_sel;
    ld_da_preg_sign_sel     <= ld_dc_preg_sign_sel;

    ld_da_other_discard_sq          <= sq_ld_dc_other_discard_req;
    ld_da_data_discard_sq           <= sq_ld_dc_data_discard_req;
    ld_da_fwd_sq_multi              <= sq_ld_dc_fwd_multi;
    ld_da_fwd_sq_multi_mask         <= sq_ld_dc_fwd_multi_mask;
  end
end

assign ld_da_addr[31:0] = ld_da_addr0[31:0];
assign ld_da_idx[4:0]   = ld_da_addr0[9:5];

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    ld_da_dcache_hit              <= 1'b0;
    ld_da_hit_low_region          <= 1'b0;
    ld_da_hit_high_region         <= 1'b0;
  end
  else if(ld_dc_da_inst_vld)
  begin
    ld_da_dcache_hit              <= ld_dc_dcache_hit;
    ld_da_hit_low_region          <= ld_dc_hit_low_region;
    ld_da_hit_high_region         <= ld_dc_hit_high_region;
  end
end

assign sq_ld_da_fwd_data_128[127:0] = {sq_ld_da_fwd_data[31:0],sq_ld_da_fwd_data[31:0],
                                        sq_ld_da_fwd_data[31:0],sq_ld_da_fwd_data[31:0]};
assign wmb_ld_da_fwd_data_128[127:0] = wmb_ld_da_fwd_data[127:0];

assign ld_da_fwd_wmb_data_am[127:0] =
      {{{8{ld_da_bytes_vld[15]}}  & wmb_ld_da_fwd_data_128[127:120]}
      ,{{8{ld_da_bytes_vld[14]}}  & wmb_ld_da_fwd_data_128[119:112]}
      ,{{8{ld_da_bytes_vld[13]}}  & wmb_ld_da_fwd_data_128[111:104]}
      ,{{8{ld_da_bytes_vld[12]}}  & wmb_ld_da_fwd_data_128[103:96]}
      ,{{8{ld_da_bytes_vld[11]}}  & wmb_ld_da_fwd_data_128[95:88]}
      ,{{8{ld_da_bytes_vld[10]}}  & wmb_ld_da_fwd_data_128[87:80]}
      ,{{8{ld_da_bytes_vld[9]}}   & wmb_ld_da_fwd_data_128[79:72]}
      ,{{8{ld_da_bytes_vld[8]}}   & wmb_ld_da_fwd_data_128[71:64]}
      ,{{8{ld_da_bytes_vld[7]}}   & wmb_ld_da_fwd_data_128[63:56]}
      ,{{8{ld_da_bytes_vld[6]}}   & wmb_ld_da_fwd_data_128[55:48]}
      ,{{8{ld_da_bytes_vld[5]}}   & wmb_ld_da_fwd_data_128[47:40]}
      ,{{8{ld_da_bytes_vld[4]}}   & wmb_ld_da_fwd_data_128[39:32]}
      ,{{8{ld_da_bytes_vld[3]}}   & wmb_ld_da_fwd_data_128[31:24]}
      ,{{8{ld_da_bytes_vld[2]}}   & wmb_ld_da_fwd_data_128[23:16]}
      ,{{8{ld_da_bytes_vld[1]}}   & wmb_ld_da_fwd_data_128[15:8]}
      ,{{8{ld_da_bytes_vld[0]}}   & wmb_ld_da_fwd_data_128[7:0]}};

assign ld_da_fwd_sq_data_am[127:0] =
      {{{8{ld_da_bytes_vld[15]}}  & sq_ld_da_fwd_data_128[127:120]}
      ,{{8{ld_da_bytes_vld[14]}}  & sq_ld_da_fwd_data_128[119:112]}
      ,{{8{ld_da_bytes_vld[13]}}  & sq_ld_da_fwd_data_128[111:104]}
      ,{{8{ld_da_bytes_vld[12]}}  & sq_ld_da_fwd_data_128[103:96]}
      ,{{8{ld_da_bytes_vld[11]}}  & sq_ld_da_fwd_data_128[95:88]}
      ,{{8{ld_da_bytes_vld[10]}}  & sq_ld_da_fwd_data_128[87:80]}
      ,{{8{ld_da_bytes_vld[9]}}   & sq_ld_da_fwd_data_128[79:72]}
      ,{{8{ld_da_bytes_vld[8]}}   & sq_ld_da_fwd_data_128[71:64]}
      ,{{8{ld_da_bytes_vld[7]}}   & sq_ld_da_fwd_data_128[63:56]}
      ,{{8{ld_da_bytes_vld[6]}}   & sq_ld_da_fwd_data_128[55:48]}
      ,{{8{ld_da_bytes_vld[5]}}   & sq_ld_da_fwd_data_128[47:40]}
      ,{{8{ld_da_bytes_vld[4]}}   & sq_ld_da_fwd_data_128[39:32]}
      ,{{8{ld_da_bytes_vld[3]}}   & sq_ld_da_fwd_data_128[31:24]}
      ,{{8{ld_da_bytes_vld[2]}}   & sq_ld_da_fwd_data_128[23:16]}
      ,{{8{ld_da_bytes_vld[1]}}   & sq_ld_da_fwd_data_128[15:8]}
      ,{{8{ld_da_bytes_vld[0]}}   & sq_ld_da_fwd_data_128[7:0]}};

assign ld_da_fwd_data_am[127:0] = ld_da_fwd_sq_vld
                                  ? ld_da_fwd_sq_data_am[127:0]
                                  : ld_da_fwd_wmb_data_am[127:0];


assign ld_da_fwd_vld = ld_da_fwd_sq_vld
                       || ld_da_fwd_wmb_vld && ld_da_dcache_hit;

assign ld_da_merge_from_cb = ld_da_cb_merge_en && cb_ld_da_data_vld;

assign ld_da_high_region_data128_am[127:0] =
      {{{8{ld_da_bytes_vld[15]}}  & ld_da_dcache_data_bank7[31:24]}
      ,{{8{ld_da_bytes_vld[14]}}  & ld_da_dcache_data_bank7[23:16]}
      ,{{8{ld_da_bytes_vld[13]}}  & ld_da_dcache_data_bank7[15:8]}
      ,{{8{ld_da_bytes_vld[12]}}  & ld_da_dcache_data_bank7[7:0]}
      ,{{8{ld_da_bytes_vld[11]}}  & ld_da_dcache_data_bank6[31:24]}
      ,{{8{ld_da_bytes_vld[10]}}  & ld_da_dcache_data_bank6[23:16]}
      ,{{8{ld_da_bytes_vld[9]}}   & ld_da_dcache_data_bank6[15:8]}
      ,{{8{ld_da_bytes_vld[8]}}   & ld_da_dcache_data_bank6[7:0]}
      ,{{8{ld_da_bytes_vld[7]}}   & ld_da_dcache_data_bank5[31:24]}
      ,{{8{ld_da_bytes_vld[6]}}   & ld_da_dcache_data_bank5[23:16]}
      ,{{8{ld_da_bytes_vld[5]}}   & ld_da_dcache_data_bank5[15:8]}
      ,{{8{ld_da_bytes_vld[4]}}   & ld_da_dcache_data_bank5[7:0]}
      ,{{8{ld_da_bytes_vld[3]}}   & ld_da_dcache_data_bank4[31:24]}
      ,{{8{ld_da_bytes_vld[2]}}   & ld_da_dcache_data_bank4[23:16]}
      ,{{8{ld_da_bytes_vld[1]}}   & ld_da_dcache_data_bank4[15:8]}
      ,{{8{ld_da_bytes_vld[0]}}   & ld_da_dcache_data_bank4[7:0]}};

assign ld_da_low_region_data128_am[127:0] =
      {{{8{ld_da_bytes_vld[15]}}  & ld_da_dcache_data_bank3[31:24]}
      ,{{8{ld_da_bytes_vld[14]}}  & ld_da_dcache_data_bank3[23:16]}
      ,{{8{ld_da_bytes_vld[13]}}  & ld_da_dcache_data_bank3[15:8]}
      ,{{8{ld_da_bytes_vld[12]}}  & ld_da_dcache_data_bank3[7:0]}
      ,{{8{ld_da_bytes_vld[11]}}  & ld_da_dcache_data_bank2[31:24]}
      ,{{8{ld_da_bytes_vld[10]}}  & ld_da_dcache_data_bank2[23:16]}
      ,{{8{ld_da_bytes_vld[9]}}   & ld_da_dcache_data_bank2[15:8]}
      ,{{8{ld_da_bytes_vld[8]}}   & ld_da_dcache_data_bank2[7:0]}
      ,{{8{ld_da_bytes_vld[7]}}   & ld_da_dcache_data_bank1[31:24]}
      ,{{8{ld_da_bytes_vld[6]}}   & ld_da_dcache_data_bank1[23:16]}
      ,{{8{ld_da_bytes_vld[5]}}   & ld_da_dcache_data_bank1[15:8]}
      ,{{8{ld_da_bytes_vld[4]}}   & ld_da_dcache_data_bank1[7:0]}
      ,{{8{ld_da_bytes_vld[3]}}   & ld_da_dcache_data_bank0[31:24]}
      ,{{8{ld_da_bytes_vld[2]}}   & ld_da_dcache_data_bank0[23:16]}
      ,{{8{ld_da_bytes_vld[1]}}   & ld_da_dcache_data_bank0[15:8]}
      ,{{8{ld_da_bytes_vld[0]}}   & ld_da_dcache_data_bank0[7:0]}};

assign ld_da_dcache_pass_data128_am[127:0] =
      {128{ld_da_hit_low_region}}  & ld_da_low_region_data128_am[127:0]
    | {128{ld_da_hit_high_region}} & ld_da_high_region_data128_am[127:0];

assign ld_da_cb_bypass_data_am[127:0] =
      {{{8{ld_da_bytes_vld1[15]}}  & cb_ld_da_data[127:120]}
      ,{{8{ld_da_bytes_vld1[14]}}  & cb_ld_da_data[119:112]}
      ,{{8{ld_da_bytes_vld1[13]}}  & cb_ld_da_data[111:104]}
      ,{{8{ld_da_bytes_vld1[12]}}  & cb_ld_da_data[103:96]}
      ,{{8{ld_da_bytes_vld1[11]}}  & cb_ld_da_data[95:88]}
      ,{{8{ld_da_bytes_vld1[10]}}  & cb_ld_da_data[87:80]}
      ,{{8{ld_da_bytes_vld1[9]}}   & cb_ld_da_data[79:72]}
      ,{{8{ld_da_bytes_vld1[8]}}   & cb_ld_da_data[71:64]}
      ,{{8{ld_da_bytes_vld1[7]}}   & cb_ld_da_data[63:56]}
      ,{{8{ld_da_bytes_vld1[6]}}   & cb_ld_da_data[55:48]}
      ,{{8{ld_da_bytes_vld1[5]}}   & cb_ld_da_data[47:40]}
      ,{{8{ld_da_bytes_vld1[4]}}   & cb_ld_da_data[39:32]}
      ,{{8{ld_da_bytes_vld1[3]}}   & cb_ld_da_data[31:24]}
      ,{{8{ld_da_bytes_vld1[2]}}   & cb_ld_da_data[23:16]}
      ,{{8{ld_da_bytes_vld1[1]}}   & cb_ld_da_data[15:8]}
      ,{{8{ld_da_bytes_vld1[0]}}   & cb_ld_da_data[7:0]}};

assign ld_da_cb_bypass_data_for_merge[127:0] = ld_da_merge_from_cb
                                               ? ld_da_cb_bypass_data_am[127:0]
                                               : 128'b0;

assign ld_da_dcache_data_after_merge[127:0] = ld_da_cb_bypass_data_for_merge[127:0]
                                              | ld_da_dcache_pass_data128_am[127:0];

assign ld_da_data_unrot[127:120] = ld_da_fwd_bytes_vld[15] ? ld_da_fwd_data_am[127:120] : ld_da_dcache_data_after_merge[127:120];
assign ld_da_data_unrot[119:112] = ld_da_fwd_bytes_vld[14] ? ld_da_fwd_data_am[119:112] : ld_da_dcache_data_after_merge[119:112];
assign ld_da_data_unrot[111:104] = ld_da_fwd_bytes_vld[13] ? ld_da_fwd_data_am[111:104] : ld_da_dcache_data_after_merge[111:104];
assign ld_da_data_unrot[103:96]  = ld_da_fwd_bytes_vld[12] ? ld_da_fwd_data_am[103:96]  : ld_da_dcache_data_after_merge[103:96];
assign ld_da_data_unrot[95:88]   = ld_da_fwd_bytes_vld[11] ? ld_da_fwd_data_am[95:88]   : ld_da_dcache_data_after_merge[95:88];
assign ld_da_data_unrot[87:80]   = ld_da_fwd_bytes_vld[10] ? ld_da_fwd_data_am[87:80]   : ld_da_dcache_data_after_merge[87:80];
assign ld_da_data_unrot[79:72]   = ld_da_fwd_bytes_vld[9]  ? ld_da_fwd_data_am[79:72]   : ld_da_dcache_data_after_merge[79:72];
assign ld_da_data_unrot[71:64]   = ld_da_fwd_bytes_vld[8]  ? ld_da_fwd_data_am[71:64]   : ld_da_dcache_data_after_merge[71:64];
assign ld_da_data_unrot[63:56]   = ld_da_fwd_bytes_vld[7]  ? ld_da_fwd_data_am[63:56]   : ld_da_dcache_data_after_merge[63:56];
assign ld_da_data_unrot[55:48]   = ld_da_fwd_bytes_vld[6]  ? ld_da_fwd_data_am[55:48]   : ld_da_dcache_data_after_merge[55:48];
assign ld_da_data_unrot[47:40]   = ld_da_fwd_bytes_vld[5]  ? ld_da_fwd_data_am[47:40]   : ld_da_dcache_data_after_merge[47:40];
assign ld_da_data_unrot[39:32]   = ld_da_fwd_bytes_vld[4]  ? ld_da_fwd_data_am[39:32]   : ld_da_dcache_data_after_merge[39:32];
assign ld_da_data_unrot[31:24]   = ld_da_fwd_bytes_vld[3]  ? ld_da_fwd_data_am[31:24]   : ld_da_dcache_data_after_merge[31:24];
assign ld_da_data_unrot[23:16]   = ld_da_fwd_bytes_vld[2]  ? ld_da_fwd_data_am[23:16]   : ld_da_dcache_data_after_merge[23:16];
assign ld_da_data_unrot[15:8]    = ld_da_fwd_bytes_vld[1]  ? ld_da_fwd_data_am[15:8]    : ld_da_dcache_data_after_merge[15:8];
assign ld_da_data_unrot[7:0]     = ld_da_fwd_bytes_vld[0]  ? ld_da_fwd_data_am[7:0]     : ld_da_dcache_data_after_merge[7:0];

ct_lsu_rot_data x_lsu_ld_da_data_rot (
  .data_in            (ld_da_data_unrot  ),
  .data_settle_out    (ld_da_data_settle ),
  .rot_sel            (ld_da_data_rot_sel)
);

logic [255:0] ld_da_data256_way0;
logic [255:0] ld_da_data256_way1;
assign ld_da_data256_way0[255:0]  = {ld_da_dcache_data_bank7[31:0],
                                    ld_da_dcache_data_bank6[31:0],
                                    ld_da_dcache_data_bank5[31:0],
                                    ld_da_dcache_data_bank4[31:0],
                                    ld_da_dcache_data_bank3[31:0],
                                    ld_da_dcache_data_bank2[31:0],
                                    ld_da_dcache_data_bank1[31:0],
                                    ld_da_dcache_data_bank0[31:0]};
assign ld_da_data256_way1[255:0]  = {ld_da_dcache_data_bank3[31:0],
                                    ld_da_dcache_data_bank2[31:0],
                                    ld_da_dcache_data_bank1[31:0],
                                    ld_da_dcache_data_bank0[31:0],
                                    ld_da_dcache_data_bank7[31:0],
                                    ld_da_dcache_data_bank6[31:0],
                                    ld_da_dcache_data_bank5[31:0],
                                    ld_da_dcache_data_bank4[31:0]};
assign ld_da_data256[255:0]       = ld_da_settle_way
                                    ? ld_da_data256_way1[255:0]
                                    : ld_da_data256_way0[255:0];

assign ld_da_data128[127:0] = ld_da_data_settle[127:0];

assign ld_da_cb_ld_inst_vld = ld_da_inst_vld
                              &&  ld_da_cb_addr_create_vld;
assign ld_da_cb_data_vld    = ld_da_inst_vld
                              &&  ld_da_cb_addr_create_vld 
                              &&  ld_da_dcache_hit
                              &&  !ld_da_fwd_vld; 
assign ld_da_cb_data[127:0]  = ld_da_dcache_pass_data128_am;

assign ld_da_wb_cmplt_req = ld_da_inst_vld && !ld_da_secd;
assign ld_da_wb_data_req  = ld_da_wb_cmplt_req & ld_da_data_vld;
assign ld_da_wb_data[31:0] = ld_da_data128[31:0];

assign ld_da_data_vld = ld_da_inst_vld && (ld_da_fwd_vld || ld_da_dcache_hit);
assign ld_da_rb_data_vld = ld_da_data_vld;

assign ld_da_rb_create_vld_unmask = ld_da_inst_vld
                                    & !ld_da_discard_dc_req
                                    & !ld_da_secd
                                    & (!ld_da_rb_data_vld | ld_da_boundary_after_mask);

assign ld_da_boundary_after_mask = ld_da_inst_vld & ld_da_boundary & !ld_da_merge_from_cb;

assign ld_da_discard_from_rb_req = ld_da_rb_create_vld_unmask && rb_ld_da_hit_idx
                                   || ld_da_rb_merge_vld_unmask && rb_ld_da_merge_fail;

assign ld_da_discard_from_lfb_req = (ld_da_rb_create_vld_unmask
                                     || ld_da_rb_merge_vld_unmask && !ld_da_rb_data_vld)
                                    && lfb_ld_da_hit_idx;

assign ld_da_hit_idx_discard_req = ld_da_discard_from_rb_req
                                   || ld_da_discard_from_lfb_req;

assign ld_da_rb_full_req          = ld_da_rb_create_vld
                                    &&  rb_ld_da_full;

assign ld_da_rb_discard_grnt = ld_da_discard_from_rb_req;
assign ld_da_lfb_discard_grnt = ld_da_discard_from_lfb_req;

assign ld_da_rb_merge_vld_unmask = ld_da_inst_vld
                                   && !ld_da_discard_dc_req
                                   && ld_da_secd
                                   && ld_da_boundary;

assign ld_da_rb_merge_vld = ld_da_rb_merge_vld_unmask
                            && !ld_da_hit_idx_discard_req;

assign ld_da_rb_create_vld = ld_da_rb_create_vld_unmask
                             && !ld_da_hit_idx_discard_req;

assign ld_da_cmit_hit0 = {rtu_yy_xx_commit0, rtu_yy_xx_commit0_iid[6:0]}
                         == {1'b1, ld_da_iid[6:0]};
assign ld_da_cmit_hit1 = {rtu_yy_xx_commit1, rtu_yy_xx_commit1_iid[6:0]}
                         == {1'b1, ld_da_iid[6:0]};
assign ld_da_cmit_hit2 = {rtu_yy_xx_commit2, rtu_yy_xx_commit2_iid[6:0]}
                         == {1'b1, ld_da_iid[6:0]};

assign ld_da_other_discard_sq_req = ld_da_inst_vld
                                    &&  ld_da_other_discard_sq;
assign ld_da_data_discard_sq_req  = ld_da_inst_vld
                                    &&  ld_da_data_discard_sq_final;
assign ld_da_fwd_sq_multi_req     = ld_da_inst_vld
                                    &&  ld_da_fwd_sq_multi_final;                                    

assign ld_da_sq_data_discard_vld  = !ld_da_other_discard_sq_req
                                    &&  ld_da_data_discard_sq_req;
assign ld_da_sq_fwd_multi_vld     = !ld_da_other_discard_sq_req
                                    &&  !ld_da_data_discard_sq_req
                                    &&  ld_da_fwd_sq_multi_req;   

assign ld_da_other_discard_sq_vld = ld_da_other_discard_sq_req;

assign ld_da_sq_global_discard_vld= ld_da_other_discard_sq_vld
                                    ||  ld_da_sq_fwd_multi_vld;

assign ld_da_rb_cmit = ld_da_cmit_hit0 || ld_da_cmit_hit1 || ld_da_cmit_hit2;

assign ld_da_data_discard_sq_final = ld_da_data_discard_sq;

assign ld_da_fwd_sq_multi_final = ld_da_fwd_sq_multi && !ld_da_fwd_sq_multi_mask;

assign ld_da_discard_wmb_final = ld_da_discard_wmb;

assign ld_da_discard_dc_req = ld_da_other_discard_sq
                              || ld_da_data_discard_sq_final
                              || ld_da_fwd_sq_multi_final
                              || ld_da_discard_wmb_final;

assign ld_da_restart_vld          = ld_da_other_discard_sq_req
                                    ||  ld_da_fwd_sq_multi_final
                                    ||  ld_da_data_discard_sq_req
                                    ||  ld_da_discard_wmb_final
                                    ||  ld_da_hit_idx_discard_req
                                    ||  ld_da_rb_full_req;

assign ld_da_rb_full_vld          = !ld_da_other_discard_sq_req
                                    &&  !ld_da_fwd_sq_multi_final
                                    &&  !ld_da_data_discard_sq_req
                                    &&  !ld_da_discard_wmb_final
                                    &&  !ld_da_hit_idx_discard_req
                                    &&  ld_da_rb_full_req;

assign ld_da_mask_lsid[LSIQ_ENTRY-1:0]      = {LSIQ_ENTRY{ld_da_inst_vld}}
                                              & ld_da_lsid[LSIQ_ENTRY-1:0];
assign ld_da_idu_rb_full[LSIQ_ENTRY-1:0]    = {LSIQ_ENTRY{ld_da_rb_full_vld}}
                                              & ld_da_mask_lsid[LSIQ_ENTRY-1:0];

assign ld_da_idu_pop_vld                    = ld_da_inst_vld
                                              &&  !ld_da_boundary_first
                                              &&  !ld_da_restart_vld;
assign ld_da_idu_pop_entry[LSIQ_ENTRY-1:0]  = {LSIQ_ENTRY{ld_da_idu_pop_vld}}
                                              & ld_da_mask_lsid[LSIQ_ENTRY-1:0];

assign ld_da_idu_secd_vld                   = ld_da_inst_vld
                                              &&  ld_da_boundary_first    
                                              &&  !ld_da_restart_vld;

assign ld_da_idu_secd[LSIQ_ENTRY-1:0]       = {LSIQ_ENTRY{ld_da_idu_secd_vld}}
                                              & ld_da_mask_lsid[LSIQ_ENTRY-1:0];                                              
endmodule