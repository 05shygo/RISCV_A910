module ct_lsu_lfb #(
    parameter LSIQ_ENTRY     = 12,
    parameter LFB_ADDR_ENTRY = 3,
    parameter LFB_DATA_ENTRY = 1,
    parameter BIU_LFB_ID_T   = 2'b00,
    parameter OKAY           = 2'b00,
    parameter EXOKAY         = 2'b01,
    parameter SLVERR         = 2'b10,
    parameter DECERR         = 2'b11,
    parameter DCACHE_SIZE    = 2048,  // 1024, 2048, or 4096 bytes
    // Derived parameters for dcache indexing
    parameter int CACHELINE_SIZE = 32,
    parameter int NUM_WAYS = 2,
    parameter int OFFSET_WIDTH = 5,
    parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
    parameter int INDEX_WIDTH = $clog2(NUM_SETS),
    parameter int INDEX_LSB = OFFSET_WIDTH,
    parameter int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1,
    parameter int TAG_LSB = INDEX_MSB + 1,
    parameter int TAG_WIDTH = 32 - TAG_LSB,
    parameter int LD_TAG_WIDTH = TAG_WIDTH * 2 + 2
)(
    input  logic [127:0] biu_lsu_r_data,
    input  logic [3:0]   biu_lsu_r_id,
    input  logic         biu_lsu_r_last,
    input  logic [1:0]   biu_lsu_r_resp,
    input  logic         biu_lsu_r_vld,
    input  logic         bus_arb_rb_ar_sel,
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic         dcache_arb_lfb_ld_grnt,
    input  logic [INDEX_WIDTH-1:0]   ld_da_idx,
    input  logic         ld_da_lfb_discard_grnt,
    input  logic         ld_da_lfb_set_wakeup_queue,
    input  logic [LSIQ_ENTRY-1:0] ld_da_lfb_wakeup_queue_next,
    input  logic [31:0]  rb_biu_req_addr,
    input  logic [27:0]  rb_lfb_addr_tto4,
    input  logic         rb_lfb_boundary_depd_wakeup,
    input  logic         rb_lfb_create_req,
    input  logic         rb_lfb_create_vld,
    input  logic         rb_lfb_depd,
    input  logic         rtu_yy_xx_flush,
    input  logic [31:0]  st_da_addr,
    input  logic [2:0]   vb_lfb_addr_entry_rcl_done,
    input  logic         vb_lfb_create_grnt,
    input  logic [2:0]   vb_lfb_dcache_hit,
    input  logic [2:0]   vb_lfb_dcache_way,
    input  logic         vb_lfb_rcl_done,
    input  logic         vb_lfb_vb_req_hit_idx,
    input  logic [31:0]  wmb_write_req_addr,

    output logic [7:0]   lfb_dcache_arb_ld_data_gateclk_en,
    output logic [127:0] lfb_dcache_arb_ld_data_high_din,
    output logic [INDEX_WIDTH:0]   lfb_dcache_arb_ld_data_idx,
    output logic [127:0] lfb_dcache_arb_ld_data_low_din,
    output logic         lfb_dcache_arb_ld_req,
    output logic [LD_TAG_WIDTH-1:0]  lfb_dcache_arb_ld_tag_din,
    output logic         lfb_dcache_arb_ld_tag_gateclk_en,
    output logic [INDEX_WIDTH-1:0]   lfb_dcache_arb_ld_tag_idx,
    output logic         lfb_dcache_arb_ld_tag_req,
    output logic [1:0]   lfb_dcache_arb_ld_tag_wen,
    output logic         lfb_dcache_arb_st_tag_req,
    output logic         lfb_dcache_arb_st_tag_gateclk_en,
    output logic [INDEX_WIDTH-1:0]   lfb_dcache_arb_st_tag_idx,
    output logic [LD_TAG_WIDTH-3:0]  lfb_dcache_arb_st_tag_din,
    output logic [1:0]   lfb_dcache_arb_st_tag_wen,

//---------------dirty array------------
    output logic         lfb_dcache_arb_st_dirty_req,
    output logic         lfb_dcache_arb_st_dirty_gateclk_en,
    output logic [INDEX_WIDTH-1:0]   lfb_dcache_arb_st_dirty_idx,
    output logic [4:0]   lfb_dcache_arb_st_dirty_din,
    output logic [4:0]   lfb_dcache_arb_st_dirty_wen,
    output logic [LSIQ_ENTRY-1:0] lfb_depd_wakeup,
    output logic         lfb_ld_da_hit_idx,
    output logic         lfb_pop_depd_ff,
    output logic         lfb_rb_biu_req_hit_idx,
    output logic         lfb_rb_ca_rready_grnt,
    output logic [3:0]   lfb_rb_create_id,
    output logic         lfb_st_da_hit_idx,
    output logic [26:0]  lfb_vb_addr_tto5,
//    output logic         lfb_vb_create_req,
    output logic         lfb_vb_create_vld,
    output logic [1:0]   lfb_vb_id,
    output logic         lfb_wmb_read_req_hit_idx,
    output logic         lfb_wmb_write_req_hit_idx,
    output logic         lfb_addr_full
);

//==========================================================
//                 Internal registers
//==========================================================
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_create_ptr;
logic [1:0]                lfb_first_pass_ptr;
logic [LFB_ADDR_ENTRY-1:0] lfb_lf_sm_addr_id;
logic [26:0]               lfb_lf_sm_addr_tto5;
logic                      lfb_lf_sm_refill_way;
logic                      lfb_lf_sm_vld;
logic [3:0]                lfb_no_rcl_cnt;
logic [LFB_ADDR_ENTRY-1:0] lfb_r_id_hit_addr_ptr;
logic [LFB_ADDR_ENTRY-1:0] lfb_vb_addr_ptr;
logic [LFB_ADDR_ENTRY-1:0] lfb_vb_pe_req_ptr;
logic                      lfb_vb_req_unmask;
logic [LSIQ_ENTRY-1:0]     lfb_wakeup_queue;

//==========================================================
//                 Internal wires
//==========================================================
logic                      lfb_addr_create_vld;
logic [27:0]               lfb_addr_entry_addr_tto4_v [LFB_ADDR_ENTRY-1:0];
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_dcache_hit;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_depd;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_discard_vld;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_ld_da_hit_idx;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_linefill_permit;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_not_resp;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_pop_vld;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_rb_biu_req_hit_idx;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_rb_create_vld;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_rcl_done;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_refill_way;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_resp_set;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_st_da_hit_idx;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_vb_pe_req;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_vb_pe_req_grnt;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_vld;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_wmb_read_req_hit_idx;
logic [LFB_ADDR_ENTRY-1:0] lfb_addr_entry_wmb_write_req_hit_idx;
logic                      lfb_addr_pop_depd;
logic                      lfb_addr_pop_discard_vld;
logic                      lfb_addr_rb_create_vld;
logic [1:0]                lfb_biu_id_2to0;
logic                      lfb_biu_r_id_hit;
logic                      lfb_ca_rready_grnt;
logic [1:0]                lfb_create_id;
logic                      lfb_create_vb_cancel;
logic                      lfb_create_vb_success;
logic [LFB_ADDR_ENTRY-1:0] lfb_data_addr_pop_req;
logic                      lfb_data_create_vld;
logic [LFB_ADDR_ENTRY-1:0] lfb_data_entry_addr_id;
logic [LFB_ADDR_ENTRY-1:0] lfb_data_entry_addr_pop_req;
logic [255:0]              lfb_data_entry_data;
logic                      lfb_data_entry_last;
logic                      lfb_data_entry_lf_sm_req;
logic                      lfb_data_entry_vld;
logic                      lfb_data_not_full;
logic [LFB_ADDR_ENTRY-1:0] lfb_lf_sm_addr_pop_req;
logic                      lfb_lf_sm_create_vld;
logic [255:0]              lfb_lf_sm_data256;
logic                      lfb_lf_sm_data_grnt;
logic                      lfb_lf_sm_data_pop_req;
logic [255:0]              lfb_lf_sm_data_settle;
logic                      lfb_lf_sm_permit;
logic                      lfb_lf_sm_req;
logic [LFB_ADDR_ENTRY-1:0] lfb_lf_sm_req_addr_ptr;
logic [26:0]               lfb_lf_sm_req_addr_tto5;
logic                      lfb_lf_sm_req_depd;
logic                      lfb_lf_sm_req_refill_way;
logic [3:0]                lfb_no_rcl_cnt_create;
logic [3:0]                lfb_no_rcl_cnt_pop;
logic [3:0]                lfb_no_rcl_cnt_updt_val;
logic                      lfb_no_rcl_cnt_updt_vld;
logic                      lfb_r_resp_err;
logic                      lfb_vb_pe_all_req;
logic                      lfb_vb_pe_rb_req;
logic                      lfb_vb_pe_req;
logic [26:0]               lfb_vb_pe_req_addr_tto5;
logic                      lfb_vb_pe_req_permit;
logic                      lfb_vb_req_entry_vld;
logic                      lfb_vb_req_hit_idx;
logic [LSIQ_ENTRY-1:0]     lfb_wakeup_queue_after_pop;
logic [LSIQ_ENTRY-1:0]     lfb_wakeup_queue_next;

//==========================================================
//                 Instantiate addr entries
//==========================================================
genvar i;
generate
    for (i = 0; i < LFB_ADDR_ENTRY; i = i + 1) begin : gen_lfb_addr_entry
        ct_lsu_lfb_addr_entry u_lfb_addr_entry (
            .cpurst_b                               (cpurst_b),
            .forever_cpuclk                            (forever_cpuclk),
            .ld_da_idx                              (ld_da_idx),
            .ld_da_lfb_discard_grnt                 (ld_da_lfb_discard_grnt),
            .lfb_addr_entry_rb_create_vld_x         (lfb_addr_entry_rb_create_vld[i]),
            .lfb_addr_entry_resp_set_x              (lfb_addr_entry_resp_set[i]),
            .lfb_addr_entry_vb_pe_req_grnt_x        (lfb_addr_entry_vb_pe_req_grnt[i]),
            .lfb_data_addr_pop_req_x                (lfb_data_addr_pop_req[i]),
            .lfb_lf_sm_addr_pop_req_x               (lfb_lf_sm_addr_pop_req[i]),
            .lfb_vb_pe_req                          (lfb_vb_pe_req),
            .lfb_vb_pe_req_permit                   (lfb_vb_pe_req_permit),
            .rb_biu_req_addr                        (rb_biu_req_addr),
            .rb_lfb_addr_tto4                       (rb_lfb_addr_tto4),
            .rb_lfb_depd                            (rb_lfb_depd),
            .st_da_addr                             (st_da_addr),
            .vb_lfb_addr_entry_rcl_done_x           (vb_lfb_addr_entry_rcl_done[i]),
            .vb_lfb_dcache_hit                      (vb_lfb_dcache_hit[i]),
            .vb_lfb_dcache_way                      (vb_lfb_dcache_way[i]),
            .wmb_write_req_addr                     (wmb_write_req_addr),

            .lfb_addr_entry_addr_tto4_v             (lfb_addr_entry_addr_tto4_v[i]),
            .lfb_addr_entry_dcache_hit_x            (lfb_addr_entry_dcache_hit[i]),
            .lfb_addr_entry_depd_x                  (lfb_addr_entry_depd[i]),
            .lfb_addr_entry_discard_vld_x           (lfb_addr_entry_discard_vld[i]),
            .lfb_addr_entry_ld_da_hit_idx_x         (lfb_addr_entry_ld_da_hit_idx[i]),
            .lfb_addr_entry_linefill_permit_x       (lfb_addr_entry_linefill_permit[i]),
            .lfb_addr_entry_not_resp_x              (lfb_addr_entry_not_resp[i]),
            .lfb_addr_entry_pop_vld_x               (lfb_addr_entry_pop_vld[i]),
            .lfb_addr_entry_rb_biu_req_hit_idx_x    (lfb_addr_entry_rb_biu_req_hit_idx[i]),
            .lfb_addr_entry_rcl_done_x              (lfb_addr_entry_rcl_done[i]),
            .lfb_addr_entry_refill_way_x            (lfb_addr_entry_refill_way[i]),
            .lfb_addr_entry_st_da_hit_idx_x         (lfb_addr_entry_st_da_hit_idx[i]),
            .lfb_addr_entry_vb_pe_req_x             (lfb_addr_entry_vb_pe_req[i]),
            .lfb_addr_entry_vld_x                   (lfb_addr_entry_vld[i]),
            .lfb_addr_entry_wmb_read_req_hit_idx_x  (lfb_addr_entry_wmb_read_req_hit_idx[i]),
            .lfb_addr_entry_wmb_write_req_hit_idx_x (lfb_addr_entry_wmb_write_req_hit_idx[i])
        );
    end
endgenerate

//==========================================================
//                 Instantiate data entry
//==========================================================
ct_lsu_lfb_data_entry u_lfb_data_entry (
    .biu_lsu_r_data                 (biu_lsu_r_data),
    .biu_lsu_r_last                 (biu_lsu_r_last),
    .biu_lsu_r_vld                  (biu_lsu_r_vld),
    .cpurst_b                       (cpurst_b),
    .forever_cpuclk                    (forever_cpuclk),
    .lfb_addr_entry_linefill_permit (lfb_addr_entry_linefill_permit),
    .lfb_biu_id_2to0                (lfb_biu_id_2to0),
    .lfb_biu_r_id_hit               (lfb_biu_r_id_hit),
    .lfb_data_entry_create_vld_x    (lfb_data_create_vld),
    .lfb_first_pass_ptr             (lfb_first_pass_ptr),
    .lfb_lf_sm_data_grnt_x          (lfb_lf_sm_data_grnt),
    .lfb_lf_sm_data_pop_req_x       (lfb_lf_sm_data_pop_req),
    .lfb_r_resp_err                 (lfb_r_resp_err),

    .lfb_data_entry_addr_id_v       (lfb_data_entry_addr_id),
    .lfb_data_entry_addr_pop_req_v  (lfb_data_entry_addr_pop_req),
    .lfb_data_entry_data_v          (lfb_data_entry_data),
    .lfb_data_entry_last_x          (lfb_data_entry_last),
    .lfb_data_entry_lf_sm_req_x     (lfb_data_entry_lf_sm_req),
    .lfb_data_entry_vld_x           (lfb_data_entry_vld)
);

//==========================================================
//                 Generate addr create signal
//==========================================================
//------------------create ptr------------------------------
always @( lfb_addr_entry_vld[LFB_ADDR_ENTRY-1:0])
begin
  lfb_addr_create_ptr[LFB_ADDR_ENTRY-1:0] = {LFB_ADDR_ENTRY{1'b0}};
  casez(lfb_addr_entry_vld[LFB_ADDR_ENTRY-1:0])
    3'b??0: lfb_addr_create_ptr[0] = 1'b1;
    3'b?01: lfb_addr_create_ptr[1] = 1'b1;
    3'b011: lfb_addr_create_ptr[2] = 1'b1;
    default: lfb_addr_create_ptr[LFB_ADDR_ENTRY-1:0] = {LFB_ADDR_ENTRY{1'b0}};
  endcase
end
assign lfb_addr_full = &lfb_addr_entry_vld[LFB_ADDR_ENTRY-1:0];
//------------------create id encode------------------------
always @( lfb_addr_create_ptr[LFB_ADDR_ENTRY-1:0])
begin
  lfb_create_id[1:0] = 2'b0;
  case(lfb_addr_create_ptr[LFB_ADDR_ENTRY-1:0])
    3'b001: lfb_create_id[1:0] = 2'd0;
    3'b010: lfb_create_id[1:0] = 2'd1;
    3'b100: lfb_create_id[1:0] = 2'd2;
    default: lfb_create_id[1:0] = 2'd0;
  endcase
end

//------------------grnt signal to rb-----------------------
assign lfb_rb_create_id[3:0] = {BIU_LFB_ID_T,lfb_create_id[1:0]};

assign lfb_addr_rb_create_vld = bus_arb_rb_ar_sel && rb_lfb_create_req && rb_lfb_create_vld;

assign lfb_addr_entry_rb_create_vld[LFB_ADDR_ENTRY-1:0]
    = {LFB_ADDR_ENTRY{lfb_addr_rb_create_vld}} & lfb_addr_create_ptr[LFB_ADDR_ENTRY-1:0];

//==========================================================
//                 Request vb addr entry
//==========================================================
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_vb_req_unmask <= 1'b0;
  else if (lfb_vb_pe_all_req)
    lfb_vb_req_unmask <= 1'b1;
  else if (lfb_create_vb_success || lfb_create_vb_cancel)
    lfb_vb_req_unmask <= 1'b0;
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    lfb_vb_addr_ptr[LFB_ADDR_ENTRY-1:0] <= {LFB_ADDR_ENTRY{1'b0}};
    lfb_vb_addr_tto5[26:0]              <= 27'b0;
  end
  else if (lfb_vb_pe_req_permit && lfb_vb_pe_req)
  begin
    lfb_vb_addr_ptr[LFB_ADDR_ENTRY-1:0] <= lfb_vb_pe_req_ptr[LFB_ADDR_ENTRY-1:0];
    lfb_vb_addr_tto5[26:0]              <= lfb_vb_pe_req_addr_tto5[26:0];
  end
  else if (lfb_vb_pe_req_permit && lfb_vb_pe_rb_req)
  begin
    lfb_vb_addr_ptr[LFB_ADDR_ENTRY-1:0] <= lfb_addr_create_ptr[LFB_ADDR_ENTRY-1:0];
    lfb_vb_addr_tto5[26:0]              <= rb_lfb_addr_tto4[26:1];
  end
end

//-----------------pop req signal---------------------------
assign lfb_vb_pe_rb_req = lfb_addr_rb_create_vld;

assign lfb_vb_pe_req = |lfb_addr_entry_vb_pe_req[LFB_ADDR_ENTRY-1:0];

assign lfb_vb_pe_all_req = lfb_vb_pe_req || lfb_vb_pe_rb_req;

//------------------permit signal---------------------------
assign lfb_vb_pe_req_permit = !lfb_vb_req_unmask
                              || lfb_create_vb_cancel
                              || lfb_create_vb_success;

//------------------request ptr-----------------------------
always @( lfb_addr_entry_vb_pe_req[LFB_ADDR_ENTRY-1:0])
begin
  lfb_vb_pe_req_ptr[LFB_ADDR_ENTRY-1:0] = {LFB_ADDR_ENTRY{1'b0}};
  casez(lfb_addr_entry_vb_pe_req[LFB_ADDR_ENTRY-1:0])
    3'b??1: lfb_vb_pe_req_ptr[0] = 1'b1;
    3'b?10: lfb_vb_pe_req_ptr[1] = 1'b1;
    3'b100: lfb_vb_pe_req_ptr[2] = 1'b1;
    default: lfb_vb_pe_req_ptr[LFB_ADDR_ENTRY-1:0] = {LFB_ADDR_ENTRY{1'b0}};
  endcase
end

assign lfb_vb_pe_req_addr_tto5[26:0]
    = {27{lfb_vb_pe_req_ptr[0]}} & lfb_addr_entry_addr_tto4_v[0][26:1]
    | {27{lfb_vb_pe_req_ptr[1]}} & lfb_addr_entry_addr_tto4_v[1][26:1]
    | {27{lfb_vb_pe_req_ptr[2]}} & lfb_addr_entry_addr_tto4_v[2][26:1];

//-------------------pop grnt signal------------------------
assign lfb_addr_entry_vb_pe_req_grnt[LFB_ADDR_ENTRY-1:0]
    = {LFB_ADDR_ENTRY{lfb_vb_pe_req_permit}} & lfb_vb_pe_req_ptr[LFB_ADDR_ENTRY-1:0];

//-------------------request signal-------------------------
assign lfb_vb_req_hit_idx = vb_lfb_vb_req_hit_idx;

//assign lfb_vb_create_req = lfb_vb_req_unmask;

assign lfb_vb_create_vld = lfb_vb_req_unmask && !lfb_vb_req_hit_idx;

always @( lfb_vb_addr_ptr[LFB_ADDR_ENTRY-1:0])
begin
  lfb_vb_id[1:0] = 2'b0;
  case(lfb_vb_addr_ptr[LFB_ADDR_ENTRY-1:0])
    3'b001: lfb_vb_id[1:0] = 2'd0;
    3'b010: lfb_vb_id[1:0] = 2'd1;
    3'b100: lfb_vb_id[1:0] = 2'd2;
    default: lfb_vb_id[1:0] = 2'd0;
  endcase
end

assign lfb_create_vb_success = lfb_vb_create_vld && vb_lfb_create_grnt;

assign lfb_vb_req_entry_vld = |(lfb_vb_addr_ptr[LFB_ADDR_ENTRY-1:0] & lfb_addr_entry_vld[LFB_ADDR_ENTRY-1:0]);
assign lfb_create_vb_cancel = lfb_vb_req_unmask && !lfb_vb_req_entry_vld;

//==========================================================
//                 Pass data to data entry
//==========================================================
//----------r id------------------------
assign lfb_biu_r_id_hit = biu_lsu_r_vld
                          && (biu_lsu_r_id[3:2] == BIU_LFB_ID_T);
assign lfb_biu_id_2to0[1:0] = biu_lsu_r_id[1:0];

assign lfb_addr_entry_resp_set[LFB_ADDR_ENTRY-1:0]
    = {LFB_ADDR_ENTRY{lfb_biu_r_id_hit && lfb_data_not_full}}
      & lfb_r_id_hit_addr_ptr[LFB_ADDR_ENTRY-1:0];

//----------r resp----------------------
assign lfb_r_resp_err = (biu_lsu_r_resp[1:0] == DECERR)
                        || (biu_lsu_r_resp[1:0] == SLVERR);

//------------------data create signal----------------------
assign lfb_data_create_vld = lfb_biu_r_id_hit;

//------------------r id hit addr ptr------------------------
always @( lfb_biu_id_2to0[1:0])
begin
  lfb_r_id_hit_addr_ptr[LFB_ADDR_ENTRY-1:0] = {LFB_ADDR_ENTRY{1'b0}};
  case(lfb_biu_id_2to0[1:0])
    2'd0: lfb_r_id_hit_addr_ptr[0] = 1'b1;
    2'd1: lfb_r_id_hit_addr_ptr[1] = 1'b1;
    2'd2: lfb_r_id_hit_addr_ptr[2] = 1'b1;
    default: lfb_r_id_hit_addr_ptr[LFB_ADDR_ENTRY-1:0] = {LFB_ADDR_ENTRY{1'b0}};
  endcase
end

assign lfb_pass_addr_4  = {2{lfb_r_id_hit_addr_ptr[0]}} & lfb_addr_entry_addr_tto4_v[0][0]
                        | {2{lfb_r_id_hit_addr_ptr[1]}} & lfb_addr_entry_addr_tto4_v[1][0]
                        | {2{lfb_r_id_hit_addr_ptr[2]}} & lfb_addr_entry_addr_tto4_v[2][0];

//AXI returns the line in address order: first beat is always the low 128-bit half.
always @( lfb_pass_addr_4)
begin
lfb_first_pass_ptr[1:0]  = 2'b0;
case(lfb_pass_addr_4)
  1'd0:lfb_first_pass_ptr[0]  = 1'b1;
  1'd1:lfb_first_pass_ptr[1]  = 1'b1;
  default:lfb_first_pass_ptr[1:0]  = 2'b0;
endcase
// &CombEnd; @427
end

//==========================================================
//                 Linefill state machine
//==========================================================
//+-----+
//| vld |
//+-----+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_lf_sm_vld <= 1'b0;
  else if (lfb_lf_sm_create_vld)
    lfb_lf_sm_vld <= 1'b1;
  else if (dcache_arb_lfb_ld_grnt)
    lfb_lf_sm_vld <= 1'b0;
end

//+------------+---------+------+
//| refill way | addr_id | addr |
//+------------+---------+------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    lfb_lf_sm_refill_way                  <= 1'b0;
    lfb_lf_sm_addr_id[LFB_ADDR_ENTRY-1:0] <= {LFB_ADDR_ENTRY{1'b0}};
    lfb_lf_sm_addr_tto5[26:0]             <= 27'b0;
  end
  else if (lfb_lf_sm_create_vld)
  begin
    lfb_lf_sm_refill_way                  <= lfb_lf_sm_req_refill_way;
    lfb_lf_sm_addr_id[LFB_ADDR_ENTRY-1:0] <= lfb_lf_sm_req_addr_ptr[LFB_ADDR_ENTRY-1:0];
    lfb_lf_sm_addr_tto5[26:0]             <= lfb_lf_sm_req_addr_tto5[26:0];
  end
end

//------------------create signal---------------------------
assign lfb_lf_sm_permit = !lfb_lf_sm_vld;
assign lfb_lf_sm_req = lfb_data_entry_lf_sm_req;
assign lfb_lf_sm_create_vld = lfb_lf_sm_req && lfb_lf_sm_permit;

//------------------create info-----------------------------
assign lfb_lf_sm_req_addr_ptr[LFB_ADDR_ENTRY-1:0] = lfb_data_entry_addr_id[LFB_ADDR_ENTRY-1:0];

assign lfb_lf_sm_data_grnt = lfb_lf_sm_create_vld;

assign lfb_lf_sm_req_addr_tto5[26:0]
    = {27{lfb_lf_sm_req_addr_ptr[0]}} & lfb_addr_entry_addr_tto4_v[0][27:1]
    | {27{lfb_lf_sm_req_addr_ptr[1]}} & lfb_addr_entry_addr_tto4_v[1][27:1]
    | {27{lfb_lf_sm_req_addr_ptr[2]}} & lfb_addr_entry_addr_tto4_v[2][27:1];

assign lfb_lf_sm_req_depd = |(lfb_lf_sm_req_addr_ptr[LFB_ADDR_ENTRY-1:0] & lfb_addr_entry_depd[LFB_ADDR_ENTRY-1:0]);
assign lfb_lf_sm_req_refill_way = |(lfb_lf_sm_req_addr_ptr[LFB_ADDR_ENTRY-1:0] & lfb_addr_entry_refill_way[LFB_ADDR_ENTRY-1:0]);

//----------------------settle data-------------------------
assign lfb_lf_sm_data256[255:0] = lfb_data_entry_data[255:0];

assign lfb_lf_sm_data_settle[255:0] = lfb_lf_sm_refill_way
                                      ? {lfb_lf_sm_data256[127:0], lfb_lf_sm_data256[255:128]}
                                      : lfb_lf_sm_data256[255:0];

//----------------------cache interface---------------------
assign lfb_dcache_arb_ld_req = lfb_lf_sm_vld;

//---------------tag array--------------
assign lfb_dcache_arb_ld_tag_req        = lfb_lf_sm_vld;
assign lfb_dcache_arb_ld_tag_gateclk_en = lfb_dcache_arb_ld_tag_req;
assign lfb_dcache_arb_ld_tag_idx[INDEX_WIDTH-1:0]   = lfb_lf_sm_addr_tto5[INDEX_WIDTH-1:0];
// {way1_valid, way1_tag, way0_valid, way0_tag}, valid fixed to 1
assign lfb_dcache_arb_ld_tag_din[LD_TAG_WIDTH-1:0]  = {1'b1, lfb_lf_sm_addr_tto5[TAG_WIDTH+INDEX_WIDTH-1:INDEX_WIDTH],
                                           1'b1, lfb_lf_sm_addr_tto5[TAG_WIDTH+INDEX_WIDTH-1:INDEX_WIDTH]};
assign lfb_dcache_arb_ld_tag_wen[1:0]   = lfb_lf_sm_vld
                                          ? {lfb_lf_sm_refill_way, !lfb_lf_sm_refill_way}
                                          : 2'b0;

//---------------data array-------------
assign lfb_dcache_arb_ld_data_gateclk_en[7:0] = {8{lfb_lf_sm_vld}};
assign lfb_dcache_arb_ld_data_idx[INDEX_WIDTH:0] = {lfb_lf_sm_addr_tto5[INDEX_WIDTH-1:0], lfb_lf_sm_refill_way};
assign lfb_dcache_arb_ld_data_low_din[127:0]  = lfb_lf_sm_data_settle[127:0];
assign lfb_dcache_arb_ld_data_high_din[127:0] = lfb_lf_sm_data_settle[255:128];

assign lfb_dcache_arb_st_tag_req        = lfb_dcache_arb_ld_tag_req;
assign lfb_dcache_arb_st_tag_gateclk_en = lfb_dcache_arb_ld_tag_req;
assign lfb_dcache_arb_st_tag_idx[INDEX_WIDTH-1:0]   = lfb_dcache_arb_ld_tag_idx[INDEX_WIDTH-1:0];
assign lfb_dcache_arb_st_tag_din[LD_TAG_WIDTH-3:0]  = {lfb_lf_sm_addr_tto5[TAG_WIDTH+INDEX_WIDTH-1:INDEX_WIDTH],
                                                      lfb_lf_sm_addr_tto5[TAG_WIDTH+INDEX_WIDTH-1:INDEX_WIDTH]};
assign lfb_dcache_arb_st_tag_wen[1:0]   = lfb_dcache_arb_ld_tag_wen[1:0];

//---------------dirty array------------
assign lfb_dcache_arb_st_dirty_req      = lfb_dcache_arb_ld_tag_req;
assign lfb_dcache_arb_st_dirty_gateclk_en = lfb_dcache_arb_ld_tag_req;
assign lfb_dcache_arb_st_dirty_idx[INDEX_WIDTH-1:0] = lfb_dcache_arb_ld_tag_idx[INDEX_WIDTH-1:0];
//dirty=0，shared看rresp的isshared，fifo替换
assign lfb_dcache_arb_st_dirty_din[4:0] = {!lfb_lf_sm_refill_way,1'b0,1'b1,1'b0,1'b1};
assign lfb_dcache_arb_st_dirty_wen[4:0] = {1'b1,{2{lfb_lf_sm_refill_way}},{2{!lfb_lf_sm_refill_way}}};


//----------------------pop signal--------------------------
assign lfb_lf_sm_addr_pop_req[LFB_ADDR_ENTRY-1:0]
    = {LFB_ADDR_ENTRY{dcache_arb_lfb_ld_grnt}} & lfb_lf_sm_addr_id[LFB_ADDR_ENTRY-1:0];

assign lfb_lf_sm_data_pop_req = dcache_arb_lfb_ld_grnt;

assign lfb_data_addr_pop_req[LFB_ADDR_ENTRY-1:0] = lfb_data_entry_addr_pop_req[LFB_ADDR_ENTRY-1:0];

//==========================================================
//                 Maintain wakeup queue
//==========================================================
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_wakeup_queue[LSIQ_ENTRY-1:0] <= {LSIQ_ENTRY{1'b0}};
  else if (rtu_yy_xx_flush)
    lfb_wakeup_queue[LSIQ_ENTRY-1:0] <= {LSIQ_ENTRY{1'b0}};
  else if (ld_da_lfb_set_wakeup_queue || lfb_pop_depd_ff)
    lfb_wakeup_queue[LSIQ_ENTRY-1:0] <= lfb_wakeup_queue_next[LSIQ_ENTRY-1:0];
end

//+-------------+
//| depd_pop_ff |
//+-------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_pop_depd_ff <= 1'b0;
  else if (lfb_addr_pop_depd
      || lfb_addr_pop_discard_vld
      || rb_lfb_boundary_depd_wakeup
      || (lfb_lf_sm_req_depd && lfb_lf_sm_create_vld))
    lfb_pop_depd_ff <= 1'b1;
  else
    lfb_pop_depd_ff <= 1'b0;
end

//----------------forward to depd_pop_ff------------------
assign lfb_addr_pop_depd = |(lfb_addr_entry_pop_vld[LFB_ADDR_ENTRY-1:0]
                             & lfb_addr_entry_depd[LFB_ADDR_ENTRY-1:0]);
assign lfb_addr_pop_discard_vld = |(lfb_addr_entry_pop_vld[LFB_ADDR_ENTRY-1:0]
                                    & lfb_addr_entry_discard_vld[LFB_ADDR_ENTRY-1:0]);

//------------------update wakeup queue---------------------
assign lfb_wakeup_queue_after_pop[LSIQ_ENTRY-1:0] = lfb_pop_depd_ff
                                                  ? {LSIQ_ENTRY{1'b0}}
                                                  : lfb_wakeup_queue[LSIQ_ENTRY-1:0];

assign lfb_wakeup_queue_next[LSIQ_ENTRY-1:0]
    = lfb_wakeup_queue_after_pop[LSIQ_ENTRY-1:0]
      | {LSIQ_ENTRY{ld_da_lfb_set_wakeup_queue}} & ld_da_lfb_wakeup_queue_next[LSIQ_ENTRY-1:0];

//------------------------wakeup----------------------------
assign lfb_depd_wakeup[LSIQ_ENTRY-1:0] = lfb_pop_depd_ff
                                         ? lfb_wakeup_queue[LSIQ_ENTRY-1:0]
                                         : {LSIQ_ENTRY{1'b0}};

//==========================================================
//                 Avoid deadlock with no rcl
//==========================================================
assign lfb_addr_create_vld = lfb_addr_rb_create_vld;

assign lfb_no_rcl_cnt_create[3:0] = {3'b0, lfb_addr_create_vld};
assign lfb_no_rcl_cnt_pop[3:0] = {3'b0, vb_lfb_rcl_done};

assign lfb_no_rcl_cnt_updt_vld = lfb_addr_create_vld
                                 || vb_lfb_rcl_done;

assign lfb_no_rcl_cnt_updt_val[3:0] = lfb_no_rcl_cnt[3:0]
                                      + lfb_no_rcl_cnt_create[3:0]
                                      - lfb_no_rcl_cnt_pop[3:0];

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_no_rcl_cnt[3:0] <= 4'b0;
  else if (lfb_no_rcl_cnt_updt_vld)
    lfb_no_rcl_cnt[3:0] <= lfb_no_rcl_cnt_updt_val[3:0];
end

assign lfb_ca_rready_grnt = (lfb_no_rcl_cnt[3:0] < 4'd1);
assign lfb_rb_ca_rready_grnt = lfb_ca_rready_grnt;

//==========================================================
//                 Interface to other module
//==========================================================
assign lfb_ld_da_hit_idx = |lfb_addr_entry_ld_da_hit_idx[LFB_ADDR_ENTRY-1:0];
assign lfb_st_da_hit_idx = |lfb_addr_entry_st_da_hit_idx[LFB_ADDR_ENTRY-1:0];
assign lfb_rb_biu_req_hit_idx = |lfb_addr_entry_rb_biu_req_hit_idx[LFB_ADDR_ENTRY-1:0];
assign lfb_wmb_read_req_hit_idx = |lfb_addr_entry_wmb_read_req_hit_idx[LFB_ADDR_ENTRY-1:0];
assign lfb_wmb_write_req_hit_idx = |lfb_addr_entry_wmb_write_req_hit_idx[LFB_ADDR_ENTRY-1:0];

// &ModuleEnd; @836
endmodule