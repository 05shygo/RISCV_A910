module lsu_top #(
  parameter int DCACHE_SIZE = 2048,  // 1024, 2048, or 4096 bytes
  parameter int LSIQ_ENTRY = 8,
  parameter int SQ_ENTRY    = 6,
  parameter int SDIQ_ENTRY  = 4,
  parameter int WMB_ENTRY   = 4,
  parameter int LFB_ADDR_ENTRY = 3,
  parameter int LFB_DATA_ENTRY = 1
)(
  // IDU to LSU - Load interface
  input  logic                 idu_lsu_ld_sel,
  input  logic [1:0]           idu_lsu_ld_inst_size,
  input  logic                 idu_lsu_ld_unalign_2nd,
  input  logic                 idu_lsu_ld_sign_extend,
  input  logic [6:0]           idu_lsu_ld_iid,
  input  logic [LSIQ_ENTRY-1:0] idu_lsu_ld_lch_entry,
  input  logic                 idu_lsu_ld_oldest,
  input  logic [5:0]           idu_lsu_ld_preg,
  input  logic [11:0]          idu_lsu_ld_offset,
  input  logic [12:0]          idu_lsu_ld_offset_plus,
  input  logic [31:0]          idu_lsu_ld_src,

  // IDU to LSU - Store interface
  input  logic                 idu_lsu_st_sel,
  input  logic [1:0]           idu_lsu_st_inst_size,
  input  logic                 idu_lsu_st_unalign_2nd,
  input  logic [6:0]           idu_lsu_st_iid,
  input  logic [LSIQ_ENTRY-1:0] idu_lsu_st_lch_entry,
  input  logic [SDIQ_ENTRY-1:0] idu_lsu_st_sdiq_entry,
  input  logic                 idu_lsu_st_oldest,
  input  logic [11:0]          idu_lsu_st_offset,
  input  logic [12:0]          idu_lsu_st_offset_plus,
  input  logic [31:0]          idu_lsu_st_src0,

  input  logic [31:0]          idu_lsu_rf_pipe5_src0,  // in
  input  logic                 idu_lsu_sdiq_sel,  // in
  input  logic [3:0]           idu_lsu_rf_pipe5_sdiq_entry,  //in

  // RTU interface
  input  logic                 rtu_yy_xx_flush,
  input  logic                 rtu_yy_xx_commit0,
  input  logic [6:0]           rtu_yy_xx_commit0_iid,
  input  logic                 rtu_yy_xx_commit1,
  input  logic [6:0]           rtu_yy_xx_commit1_iid,
  input  logic                 rtu_yy_xx_commit2,
  input  logic [6:0]           rtu_yy_xx_commit2_iid,
  input  logic                 rtu_lsu_async_flush,

  // Clock and reset
  input  logic                 forever_cpuclk,
  input  logic                 cpurst_b,

  // BIU read interface (from bus to LSU)
 // input  logic                 bus_arb_rb_ar_grnt,
 // input  logic                 bus_arb_rb_ar_sel,
  input  logic [127:0]         biu_lsu_r_data,
  input  logic [3:0]           biu_lsu_r_id,
  input  logic                 biu_lsu_r_last,
  input  logic [1:0]           biu_lsu_r_resp,
  input  logic                 biu_lsu_r_vld,

  // BIU write response interface (from bus to LSU)
  input  logic [3:0]           biu_lsu_b_id,
  input  logic [1:0]           biu_lsu_b_resp,
  input  logic                 biu_lsu_b_vld,

  input  logic                 biu_lsu_ar_ready,
  input  logic                 biu_lsu_aw_vb_grnt,
  input  logic                 biu_lsu_aw_wmb_grnt,
  input  logic                 biu_lsu_w_vb_grnt,
  input  logic                 biu_lsu_w_wmb_grnt,

    // BIU AR 输出
  output logic [31:0]  lsu_biu_ar_addr,
  output logic [1:0]   lsu_biu_ar_bar,
  output logic [1:0]   lsu_biu_ar_burst,
  output logic [3:0]   lsu_biu_ar_cache,
  output logic [1:0]   lsu_biu_ar_domain,
  output logic [3:0]   lsu_biu_ar_id,
  output logic [1:0]   lsu_biu_ar_len,
  output logic         lsu_biu_ar_lock,
  output logic [2:0]   lsu_biu_ar_prot,
  output logic         lsu_biu_ar_req,
  output logic [2:0]   lsu_biu_ar_size,
  output logic [2:0]   lsu_biu_ar_user,
  output logic         lsu_biu_r_ready,

  // BIU AW store 输出
  output logic [31:0]  lsu_biu_aw_st_addr,
  output logic [1:0]   lsu_biu_aw_st_bar,
  output logic [1:0]   lsu_biu_aw_st_burst,
  output logic [3:0]   lsu_biu_aw_st_cache,
  output logic [1:0]   lsu_biu_aw_st_domain,
  output logic [3:0]   lsu_biu_aw_st_id,
  output logic [1:0]   lsu_biu_aw_st_len,
  output logic         lsu_biu_aw_st_lock,
  output logic [2:0]   lsu_biu_aw_st_prot,
  output logic         lsu_biu_aw_st_req,
  output logic [2:0]   lsu_biu_aw_st_size,
  output logic         lsu_biu_aw_st_user,

  // BIU AW victim 输出
  output logic [31:0]  lsu_biu_aw_vict_addr,
  output logic [1:0]   lsu_biu_aw_vict_bar,
  output logic [1:0]   lsu_biu_aw_vict_burst,
  output logic [3:0]   lsu_biu_aw_vict_cache,
  output logic [1:0]   lsu_biu_aw_vict_domain,
  output logic [3:0]   lsu_biu_aw_vict_id,
  output logic [1:0]   lsu_biu_aw_vict_len,
  output logic         lsu_biu_aw_vict_lock,
  output logic [2:0]   lsu_biu_aw_vict_prot,
  output logic         lsu_biu_aw_vict_req,
  output logic [2:0]   lsu_biu_aw_vict_size,
  output logic         lsu_biu_aw_vict_user,

  // BIU W store 输出
  output logic [127:0] lsu_biu_w_st_data,
  output logic         lsu_biu_w_st_last,
  output logic [15:0]  lsu_biu_w_st_strb,
  output logic         lsu_biu_w_st_vld,

  // BIU W victim 输出
  output logic [127:0] lsu_biu_w_vict_data,
  output logic         lsu_biu_w_vict_last,
  output logic [15:0]  lsu_biu_w_vict_strb,
  output logic         lsu_biu_w_vict_vld,
/*
  // BIU write address grant (from bus to LSU)
  input  logic                 bus_arb_wmb_aw_grnt,
  input  logic                 bus_arb_wmb_w_grnt,
  input  logic                 bus_arb_vb_aw_grnt,
  input  logic                 bus_arb_vb_w_grnt,

  // LSU to BIU - Read address request (RB)
  output logic [31:0]          rb_biu_ar_addr,
  output logic [1:0]           rb_biu_ar_bar,
  output logic [1:0]           rb_biu_ar_burst,
  output logic [3:0]           rb_biu_ar_cache,
  output logic [1:0]           rb_biu_ar_domain,
  output logic [3:0]           rb_biu_ar_id,
  output logic [1:0]           rb_biu_ar_len,
  output logic                 rb_biu_ar_lock,
  output logic [2:0]           rb_biu_ar_prot,
  output logic                 rb_biu_ar_req,
  output logic [2:0]           rb_biu_ar_size,
  output logic [3:0]           rb_biu_ar_snoop,
  output logic                 rb_biu_ar_user,

  // LSU to BIU - Write address/data request (WMB)
  output logic [31:0]          wmb_biu_aw_addr,
  output logic [1:0]           wmb_biu_aw_bar,
  output logic [1:0]           wmb_biu_aw_burst,
  output logic [3:0]           wmb_biu_aw_cache,
  output logic [1:0]           wmb_biu_aw_domain,
  output logic [3:0]           wmb_biu_aw_id,
  output logic [1:0]           wmb_biu_aw_len,
  output logic                 wmb_biu_aw_lock,
  output logic [2:0]           wmb_biu_aw_prot,
  output logic                 wmb_biu_aw_req,
  output logic [2:0]           wmb_biu_aw_size,
  output logic [2:0]           wmb_biu_aw_snoop,
  output logic                 wmb_biu_aw_user,
  output logic [127:0]         wmb_biu_w_data,
  output logic [3:0]           wmb_biu_w_id,
  output logic                 wmb_biu_w_req,
  output logic [15:0]          wmb_biu_w_strb,
  output logic                 wmb_biu_w_vld,

  // LSU to BIU - Write address/data request (VB)
  output logic [31:0]          vb_biu_aw_addr,
  output logic [1:0]           vb_biu_aw_burst,
  output logic [3:0]           vb_biu_aw_cache,
  output logic [3:0]           vb_biu_aw_id,
  output logic [1:0]           vb_biu_aw_len,
  output logic                 vb_biu_aw_lock,
  output logic [2:0]           vb_biu_aw_prot,
  output logic [2:0]           vb_biu_aw_size,
  output logic                 vb_biu_aw_req,
  output logic [127:0]         vb_biu_w_data,
  output logic [3:0]           vb_biu_w_id,
  output logic                 vb_biu_w_last,
  output logic                 vb_biu_w_req,
  output logic [15:0]          vb_biu_w_strb,
  output logic                 vb_biu_w_vld,
*/
  // LSU to IDU - Load queue status
  output logic [LSIQ_ENTRY-1:0]lsu_idu_imme_wakeup,
  output logic                 lsu_idu_lsiq_pop_vld,
  output logic                 lsu_idu_lsiq_pop0_vld,
  output logic                 lsu_idu_lsiq_pop1_vld,
  output logic [LSIQ_ENTRY-1:0]lsu_idu_pop_entry,
  output logic [LSIQ_ENTRY-1:0]lsu_idu_secd,

  output logic [LSIQ_ENTRY-1:0]lsu_idu_lq_full,
  output logic                 lsu_idu_lq_not_full,

  output logic [LSIQ_ENTRY-1:0]lsu_idu_rb_full,
  output logic                 lsu_idu_rb_not_full,

  output logic [LSIQ_ENTRY-1:0]lsu_idu_sq_full,
  output logic                 lsu_idu_sq_not_full,

  output logic [SDIQ_ENTRY-1:0]lsu_idu_has_in_sq,



  // LSU to RTU - Writeback pipe3
  output logic                 lsu_rtu_wb_pipe3_cmplt,
  output logic [6:0]           lsu_rtu_wb_pipe3_iid,
  output logic                 lsu_rtu_wb_pipe3_expt_vld,
  output logic [31:0]          lsu_rtu_wb_pipe3_expt_addr,
  output logic [63:0]          lsu_rtu_wb_pipe3_wb_preg_expand,
  output logic                 lsu_rtu_wb_pipe3_wb_preg_vld,

  // LSU to IDU - Writeback pipe3
  output logic [5:0]           lsu_idu_wb_pipe3_wb_preg,
  output logic [31:0]          lsu_idu_wb_pipe3_wb_preg_data,
  output logic [63:0]          lsu_idu_wb_pipe3_wb_preg_expand,
  output logic                 lsu_idu_wb_pipe3_wb_preg_vld,

  // LSU to RTU - Writeback pipe4
  output logic                 lsu_rtu_wb_pipe4_cmplt,
  output logic                 lsu_rtu_wb_pipe4_expt_vld,
  output logic [31:0]          lsu_rtu_wb_pipe4_expt_addr,
  output logic                 lsu_rtu_wb_pipe4_flush,
  output logic [6:0]           lsu_rtu_wb_pipe4_iid,
  output logic                 lsu_rtu_wb_pipe4_spec_fail,

  // Store queue wakeup
  output logic [LSIQ_ENTRY-1:0]sq_data_depd_wakeup,
  output logic [LSIQ_ENTRY-1:0]sq_global_depd_wakeup,


  // LFB dependency wakeup
  output logic [LSIQ_ENTRY-1:0] lfb_depd_wakeup
);

// Derived parameters
localparam int CACHELINE_SIZE = 32;
localparam int NUM_WAYS = 2;
localparam int OFFSET_WIDTH = 5;
localparam int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS;
localparam int INDEX_WIDTH = $clog2(NUM_SETS);
localparam int INDEX_LSB = OFFSET_WIDTH;
localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;
localparam int DATA_INDEX_WIDTH = INDEX_WIDTH + 1;
localparam int TAG_LSB = INDEX_MSB + 1;
localparam int TAG_WIDTH = 32 - TAG_LSB;
localparam int LD_TAG_WIDTH = TAG_WIDTH * 2 + 2;
localparam int ST_TAG_WIDTH = TAG_WIDTH * 2;

//==========================================================
// Internal Signal Declarations
//==========================================================

logic [LSIQ_ENTRY-1:0]st_ag_stall_restart_entry;
logic [LSIQ_ENTRY-1:0]ld_ag_stall_restart_entry;
logic [LSIQ_ENTRY-1:0]ld_dc_imme_wakeup;
assign lsu_idu_imme_wakeup[LSIQ_ENTRY-1:0] = ld_dc_imme_wakeup[LSIQ_ENTRY-1:0] |
                                            st_ag_stall_restart_entry[LSIQ_ENTRY-1:0] |
                                            ld_ag_stall_restart_entry[LSIQ_ENTRY-1:0];

logic [LSIQ_ENTRY-1:0]ld_da_idu_pop_entry;
logic [LSIQ_ENTRY-1:0]st_da_idu_pop_entry;
assign lsu_idu_pop_entry[LSIQ_ENTRY-1:0] = ld_da_idu_pop_entry[LSIQ_ENTRY-1:0] |
                              st_da_idu_pop_entry[LSIQ_ENTRY-1:0];  


logic [LSIQ_ENTRY-1:0]st_da_idu_secd;
logic [LSIQ_ENTRY-1:0]ld_da_idu_secd;
assign lsu_idu_secd[LSIQ_ENTRY-1:0] = st_da_idu_secd[LSIQ_ENTRY-1:0] |
                              ld_da_idu_secd[LSIQ_ENTRY-1:0];

logic [LSIQ_ENTRY-1:0]ld_dc_idu_lq_full;
assign lsu_idu_lq_full = ld_dc_idu_lq_full[LSIQ_ENTRY-1:0];

logic [LSIQ_ENTRY-1:0]ld_da_idu_rb_full;
logic [LSIQ_ENTRY-1:0]st_da_idu_rb_full;
assign lsu_idu_rb_full = ld_da_idu_rb_full[LSIQ_ENTRY-1:0] |
                        st_da_idu_rb_full[LSIQ_ENTRY-1:0];
 
logic [LSIQ_ENTRY-1:0]st_dc_idu_sq_full;
assign lsu_idu_sq_full = st_dc_idu_sq_full[LSIQ_ENTRY-1:0];


logic ld_da_idu_pop_vld;
assign lsu_idu_lsiq_pop0_vld = ld_da_idu_pop_vld;
logic st_da_idu_pop_vld;
assign lsu_idu_lsiq_pop1_vld =st_da_idu_pop_vld;
assign lsu_idu_lsiq_pop_vld = lsu_idu_lsiq_pop0_vld | lsu_idu_lsiq_pop1_vld;

//==========================================================
// BIU interface internal signals
//==========================================================
// RB -> BIU AR request
logic [31:0]  rb_biu_ar_addr;
logic [1:0]   rb_biu_ar_bar;
logic [1:0]   rb_biu_ar_burst;
logic [3:0]   rb_biu_ar_cache;
logic [1:0]   rb_biu_ar_domain;
logic [3:0]   rb_biu_ar_id;
logic [1:0]   rb_biu_ar_len;
logic         rb_biu_ar_lock;
logic [2:0]   rb_biu_ar_prot;
logic         rb_biu_ar_req;
logic [2:0]   rb_biu_ar_size;
logic [2:0]   rb_biu_ar_user;

// VB -> BIU AW/W request
logic [31:0]  vb_biu_aw_addr;
logic [1:0]   vb_biu_aw_bar;
logic [1:0]   vb_biu_aw_burst;
logic [3:0]   vb_biu_aw_cache;
logic [1:0]   vb_biu_aw_domain;
logic [3:0]   vb_biu_aw_id;
logic [1:0]   vb_biu_aw_len;
logic         vb_biu_aw_lock;
logic [2:0]   vb_biu_aw_prot;
logic         vb_biu_aw_req;
logic [2:0]   vb_biu_aw_size;
logic         vb_biu_aw_user;
logic [127:0] vb_biu_w_data;
logic [3:0]   vb_biu_w_id;
logic         vb_biu_w_last;
logic         vb_biu_w_req;
logic [15:0]  vb_biu_w_strb;
logic         vb_biu_w_vld;

// WMB -> BIU AW/W request
logic [31:0]  wmb_biu_aw_addr;
logic [1:0]   wmb_biu_aw_bar;
logic [1:0]   wmb_biu_aw_burst;
logic [3:0]   wmb_biu_aw_cache;
logic [1:0]   wmb_biu_aw_domain;
logic [3:0]   wmb_biu_aw_id;
logic [1:0]   wmb_biu_aw_len;
logic         wmb_biu_aw_lock;
logic [2:0]   wmb_biu_aw_prot;
logic         wmb_biu_aw_req;
logic [2:0]   wmb_biu_aw_size;
logic [2:0]   wmb_biu_aw_snoop;
logic         wmb_biu_aw_user;
logic [127:0] wmb_biu_w_data;
logic [3:0]   wmb_biu_w_id;
logic         wmb_biu_w_last;
logic         wmb_biu_w_req;
logic [15:0]  wmb_biu_w_strb;
logic         wmb_biu_w_vld;

// BIU arbiter grants
logic         bus_arb_rb_ar_grnt;
logic         bus_arb_vb_aw_grnt;
logic         bus_arb_wmb_aw_grnt;
logic         bus_arb_vb_w_grnt;
logic         bus_arb_wmb_w_grnt;
logic         bus_arb_rb_ar_sel;

// VB W ID (used only by lsu_vb output)
// (already covered above as vb_biu_w_id)
// Previously-implicit inter-module wires (declared at correct widths)
logic                        dcache_arb_ld_ag_borrow_addr_vld;
logic [31:0]                 dcache_arb_ld_ag_addr;
logic                        ld_dc_lq_create_vld;
logic                        ld_dc_lq_create1_vld;
logic [SQ_ENTRY-1:0]         sq_ld_dc_fwd_id;
logic                        ld_da_cb_ld_inst_vld;
logic                        ld_da_cb_data_vld;
logic [127:0]                ld_da_cb_data;
logic                        lq_st_dc_spec_fail;
logic                        st_da_sq_no_restart;
logic                        wmb_sq_pop_to_ce_grnt;
logic                        wmb_ce_update_dcache_dirty;
logic                        wmb_ce_update_dcache_valid;
logic                        wmb_ce_update_dcache_way;
logic                        st_da_dcache_valid;
logic                        rb_wmb_ce_hit_idx;
logic                        dcache_arb_lfb_ld_grnt;
logic                        ld_da_lfb_set_wakeup_queue;
logic [LSIQ_ENTRY-1:0]       ld_da_lfb_wakeup_queue_next;
logic [31:0]                 wmb_write_req_addr;
logic [7:0]                  lfb_dcache_arb_ld_data_gateclk_en;
logic [127:0]                lfb_dcache_arb_ld_data_high_din;
logic [INDEX_WIDTH:0]        lfb_dcache_arb_ld_data_idx;
logic [127:0]                lfb_dcache_arb_ld_data_low_din;
logic                        lfb_dcache_arb_ld_req;
logic [LD_TAG_WIDTH-1:0]     lfb_dcache_arb_ld_tag_din;
logic                        lfb_dcache_arb_ld_tag_gateclk_en;
logic [INDEX_WIDTH-1:0]      lfb_dcache_arb_ld_tag_idx;
logic                        lfb_dcache_arb_ld_tag_req;
logic [1:0]                  lfb_dcache_arb_ld_tag_wen;
logic                        lfb_dcache_arb_st_tag_req;
logic                        lfb_dcache_arb_st_tag_gateclk_en;
logic [INDEX_WIDTH-1:0]      lfb_dcache_arb_st_tag_idx;
logic [LD_TAG_WIDTH-3:0]     lfb_dcache_arb_st_tag_din;
logic [1:0]                  lfb_dcache_arb_st_tag_wen;
logic                        lfb_dcache_arb_st_dirty_req;
logic                        lfb_dcache_arb_st_dirty_gateclk_en;
logic [INDEX_WIDTH-1:0]      lfb_dcache_arb_st_dirty_idx;
logic [4:0]                  lfb_dcache_arb_st_dirty_din;
logic [4:0]                  lfb_dcache_arb_st_dirty_wen;
logic                        lfb_pop_depd_ff;
logic                        lfb_wmb_read_req_hit_idx;
logic                        lfb_wmb_write_req_hit_idx;
logic [255:0]                ld_da_data256;
logic [19:0]                 st_da_vb_feedback_addr_tto12;
logic                        dcache_arb_ag_st_sel;
logic [31:0]                 dcache_arb_st_ag_addr;
logic                        dcache_arb_st_ag_borrow_addr_vld;

// Load AG to DC
logic ld_ag_dc_inst_vld;
logic [1:0] ld_ag_inst_size;
logic ld_ag_secd;
logic ld_ag_sign_extend;
logic [6:0] ld_ag_iid;
logic [LSIQ_ENTRY-1:0] ld_ag_lsid;
logic ld_ag_old;
logic [5:0] ld_ag_preg;
logic ld_ag_boundary;
logic ld_ag_acclr_en;
logic ld_ag_dc_fwd_bypass_en;
logic [15:0] ld_ag_bytes_vld1;
logic [15:0] ld_ag_bytes_vld;
logic [27:0] ld_ag_addr1_to4;
logic [31:0] ld_ag_dc_addr0;
logic ld_ag_raw_new;

// Load AG to DCache arbiter
logic ag_dcache_arb_ld_tag_gateclk_en;
logic ag_dcache_arb_ld_tag_req;
logic [INDEX_WIDTH-1:0] ag_dcache_arb_ld_tag_idx;
logic [7:0]ag_dcache_arb_ld_data_gateclk_en;
logic [7:0]ag_dcache_arb_ld_data_req;
logic [DATA_INDEX_WIDTH-1:0] ag_dcache_arb_ld_data_low_idx;
logic [DATA_INDEX_WIDTH-1:0] ag_dcache_arb_ld_data_high_idx;

// DCache arbiter to Load
logic dcache_arb_ag_ld_sel;
logic dcache_arb_ld_dc_borrow_vld;
logic dcache_arb_ld_dc_settle_way;
logic [1:0] dcache_arb_ld_dc_borrow_db;

// Store AG outputs
logic st_ag_boundary;
logic [31:0] st_ag_dc_addr0;
logic [15:0] st_ag_dc_bytes_vld;
logic st_ag_dc_inst_vld;
logic [3:0] st_ag_dc_rot_sel;
logic [6:0] st_ag_iid;
logic st_ag_inst_vld;
logic [LSIQ_ENTRY-1:0] st_ag_lsid;
logic st_ag_old;
logic [SDIQ_ENTRY-1:0] st_ag_sdid_oh;
logic st_ag_secd;


// Store AG to DCache arbiter
logic ag_dcache_arb_st_dirty_gateclk_en;
logic [INDEX_WIDTH-1:0] ag_dcache_arb_st_dirty_idx;
logic ag_dcache_arb_st_dirty_req;
logic ag_dcache_arb_st_tag_gateclk_en;
logic [INDEX_WIDTH-1:0] ag_dcache_arb_st_tag_idx;
logic ag_dcache_arb_st_tag_req;

// DCache arbiter to Store
logic dcache_arb_st_dc_borrow_vld;

// Store DC outputs
logic st_dc_inst_vld;
logic st_dc_borrow_vld;
logic st_dc_secd;
logic [6:0] st_dc_iid;
logic [LSIQ_ENTRY-1:0] st_dc_lsid;
logic [SDIQ_ENTRY-1:0] st_dc_sdid_oh;
logic st_dc_old;
logic st_dc_expt;
logic [15:0] st_dc_bytes_vld;
logic [3:0] st_dc_rot_sel;
logic st_dc_boundary;
logic [31:0] st_dc_addr0;
logic st_dc_sq_create_vld;
logic st_dc_sq_create_dp_vld;
logic st_dc_sq_create_gateclk_en;
logic st_dc_sq_data_vld;
logic st_dc_boundary_first;
logic st_dc_chk_st_inst_vld;
logic [7:0] st_dc_rot_sel_rev;
logic st_dc_da_inst_vld;
logic [43:0] st_dc_da_dcache_tag_array;
logic [4:0] st_dc_da_dcache_dirty_array;
logic st_dc_da_tag0_hit;
logic st_dc_da_tag1_hit;

logic st_dc_dcwp_hit_idx;
logic st_dc_spec_fail;
logic st_dc_get_dcache_tag_dirty;

// Store DA outputs
logic st_da_borrow_vld;
logic st_da_dcache_dirty;
logic st_da_dcache_hit;
logic st_da_dcache_miss;
logic st_da_dcache_replace_dirty;
logic st_da_dcache_replace_valid;
logic st_da_dcache_replace_way;
logic st_da_dcache_way;


logic [6:0] st_da_iid;
logic st_da_inst_vld;
logic st_da_old;
logic st_da_rb_cmit;
logic st_da_rb_create_dp_vld;
logic st_da_rb_create_gateclk_en;
logic st_da_rb_create_vld;
logic st_da_secd;
logic st_da_sq_dcache_dirty;
logic st_da_sq_dcache_valid;
logic st_da_sq_dcache_way;
logic [TAG_WIDTH+INDEX_WIDTH-1:0] st_da_vb_feedback_addr_tto_offset;
logic st_da_wb_cmplt_req;
logic st_da_wb_spec_fail;
logic st_da_wb_expt_vld;
logic [31:0] st_da_wb_expt_addr;
logic [31:0] st_da_addr;
logic st_da_boundary;
logic [15:0] st_da_bytes_vld;

// Store WB output
logic st_wb_inst_vld;

// DCache write ports
logic dcache_dirty_gwen;
logic [4:0] dcache_dirty_din;
logic [4:0] dcache_dirty_wen;
logic dcache_tag_gwen;
logic [43:0] dcache_tag_din;
logic [1:0] dcache_tag_wen;
logic [INDEX_WIDTH-1:0] dcache_idx;

// DCache read outputs
logic [LD_TAG_WIDTH-1:0] dcache_lsu_ld_tag_dout;
logic [4:0] dcache_lsu_st_dirty_dout;
logic [43:0] dcache_lsu_st_tag_dout;

// DCache arbiter to dcache top signals
logic [7:0] lsu_dcache_ld_data_gateclk_en;
logic [7:0] lsu_dcache_ld_data_gwen_b;
logic [31:0] lsu_dcache_ld_data_wen_b;
logic [7:0] lsu_dcache_ld_data_sel_b;
logic [DATA_INDEX_WIDTH-1:0] lsu_dcache_ld_data_low_idx;
logic [DATA_INDEX_WIDTH-1:0] lsu_dcache_ld_data_high_idx;
logic [127:0] lsu_dcache_ld_data_low_din;
logic [127:0] lsu_dcache_ld_data_high_din;
logic lsu_dcache_ld_tag_gateclk_en;
logic lsu_dcache_ld_tag_gwen_b;
logic lsu_dcache_ld_tag_sel_b;
logic [1:0] lsu_dcache_ld_tag_wen_b;
logic [INDEX_WIDTH-1:0] lsu_dcache_ld_tag_idx;
logic [LD_TAG_WIDTH-1:0] lsu_dcache_ld_tag_din;
logic lsu_dcache_st_tag_gateclk_en;
logic lsu_dcache_st_tag_gwen_b;
logic lsu_dcache_st_tag_sel_b;
logic [1:0] lsu_dcache_st_tag_wen_b;
logic [INDEX_WIDTH-1:0] lsu_dcache_st_tag_idx;
logic [ST_TAG_WIDTH-1:0] lsu_dcache_st_tag_din;
logic lsu_dcache_st_dirty_gateclk_en;
logic lsu_dcache_st_dirty_gwen_b;
logic lsu_dcache_st_dirty_sel_b;
logic [4:0] lsu_dcache_st_dirty_wen_b;
logic [INDEX_WIDTH-1:0] lsu_dcache_st_dirty_idx;
logic [4:0] lsu_dcache_st_dirty_din;

// Load DC outputs
logic ld_dc_stall_vld;
logic ld_dc_lq_full_vld;
logic ld_dc_lq_full_req;
logic ld_dc_da_inst_vld;
logic ld_dc_borrow_vld;
logic [1:0] ld_dc_borrow_db;
logic [1:0] ld_dc_inst_size;
logic [27:0] ld_dc_addr1_to4;
logic ld_dc_boundary;
logic ld_dc_secd;
logic ld_dc_sign_extend;
logic [6:0] ld_dc_iid;
logic [LSIQ_ENTRY-1:0] ld_dc_lsid;
logic ld_dc_old;
logic [5:0] ld_dc_preg;
logic ld_dc_expt;
logic [15:0] ld_dc_bytes_vld;
logic [15:0] ld_dc_bytes_vld1;
logic ld_dc_acclr_en;
logic ld_dc_da_cb_merge_en;
logic ld_dc_raw_new;
logic [31:0] ld_dc_addr0;
logic ld_dc_cb_addr_create_vld;
logic ld_dc_chk_ld_inst_vld;
logic ld_dc_chk_ld_addr1_vld;
logic ld_dc_chk_ld_bypass_vld;
logic ld_dc_hit_low_region;
logic ld_dc_hit_high_region;
logic ld_dc_dcache_hit;
logic [7:0] ld_dc_da_data_rot_sel;
logic [3:0] ld_dc_preg_sign_sel;
logic [15:0] ld_dc_fwd_bytes_vld;
logic ld_dc_fwd_sq_vld;
logic ld_dc_fwd_wmb_vld;
logic [27:0] ld_dc_cb_addr_tto4;
logic lsu_dcache_ld_xx_gwen;

// Placeholder signals for modules not yet implemented (to be connected by user)
logic lq_ld_dc_inst_hit;
logic lq_ld_dc_full;
logic lq_ld_dc_less2;
logic cb_ld_dc_addr_hit;
logic sq_ld_dc_cancel_acc_req;
logic sq_ld_dc_fwd_req;
logic wmb_ld_dc_cancel_acc_req;
logic wmb_ld_dc_fwd_req;
logic [15:0] wmb_fwd_bytes_vld;
logic sq_ld_dc_addr1_dep_discard;
logic sq_st_dc_full;
logic sq_st_dc_inst_hit;

// SQ to WMB signals
logic [31:0] sq_pop_addr;
logic [127:0] sq_pop_data;
logic [15:0] sq_pop_bytes_vld;
logic [SQ_ENTRY-1:0] sq_pop_ptr;
logic sq_wmb_merge_req;
logic sq_wmb_merge_stall_req;
logic sq_wmb_pop_to_ce_req;
logic wmb_sq_pop_grnt;

// WMB signals
logic wmb_ld_dc_discard_req;
logic [LSIQ_ENTRY-1:0] wmb_depd_wakeup;
logic [7:0] ld_dc_addr1_11to4;

// Extract address bits [11:4] for WMB
assign ld_dc_addr1_11to4 = ld_dc_addr0[11:4];

// WMB to DCache arbiter
logic wmb_dcache_arb_req;
logic [127:0] wmb_dcache_arb_ld_data_high_din;
logic [127:0] wmb_dcache_arb_ld_data_low_din;
logic [DATA_INDEX_WIDTH-1:0] wmb_dcache_arb_ld_data_idx;
logic [7:0] wmb_dcache_arb_ld_data_req;
logic [31:0] wmb_dcache_arb_ld_data_wen;
logic [4:0] wmb_dcache_arb_st_dirty_din;
logic [INDEX_WIDTH-1:0] wmb_dcache_arb_st_dirty_idx;
logic wmb_dcache_arb_st_dirty_req;
logic [4:0] wmb_dcache_arb_st_dirty_wen;
logic dcache_arb_wmb_ld_grnt;

// LFB/VB signals for WMB
logic [26:0] lfb_vb_addr_tto5;
logic lfb_vb_create_vld;
logic [1:0] lfb_vb_id;

// VB to dcache arbiter signals
logic vb_dcache_arb_ld_borrow_req;
logic vb_dcache_arb_st_borrow_req;
logic [31:0] vb_dcache_arb_borrow_addr;
logic [LD_TAG_WIDTH-1:0] vb_dcache_arb_ld_tag_din;
logic [INDEX_WIDTH-1:0] vb_dcache_arb_ld_tag_idx;
logic vb_dcache_arb_ld_tag_req;
logic vb_dcache_arb_ld_tag_gateclk_en;
logic [1:0] vb_dcache_arb_ld_tag_wen;
logic [INDEX_WIDTH-1:0] vb_dcache_arb_st_tag_idx;
logic vb_dcache_arb_st_tag_req;
logic vb_dcache_arb_st_tag_gateclk_en;
logic vb_dcache_arb_st_dirty_req;
logic vb_dcache_arb_st_dirty_gateclk_en;
logic [INDEX_WIDTH-1:0] vb_dcache_arb_st_dirty_idx;
logic [4:0] vb_dcache_arb_st_dirty_din;
logic vb_dcache_arb_st_dirty_gwen;
logic [4:0] vb_dcache_arb_st_dirty_wen;
logic [DATA_INDEX_WIDTH-1:0] vb_dcache_arb_ld_data_idx;
logic [7:0] vb_dcache_arb_ld_data_gateclk_en;
logic dcache_arb_vb_ld_grnt;
logic dcache_arb_vb_st_grnt;

// VB to LFB signals
logic vb_lfb_create_grnt;
logic vb_lfb_vb_req_hit_idx;
logic [2:0]vb_lfb_addr_entry_rcl_done;
logic [2:0]vb_lfb_dcache_hit;
logic [2:0]vb_lfb_dcache_way;
logic vb_lfb_rcl_done;
logic vb_rb_biu_req_hit_idx;
logic vb_dcache_arb_data_way;

// Load DA signals (placeholder, to be connected)
logic ld_da_vb_borrow_vb;
logic [31:0] ld_da_addr;
logic [6:0] ld_da_iid;
logic [5:0] ld_da_preg;
logic [3:0] ld_da_preg_sign_sel;
logic ld_da_wb_cmplt_req;
logic [31:0] ld_da_wb_data;
logic ld_da_wb_data_req;
logic ld_da_wb_spec_fail;
logic ld_da_st_da_hit_idx;
logic ld_da_inst_vld;
logic [1:0] ld_da_borrow_vld;
logic [7:0] ld_da_borrow_db;
logic [1:0] ld_da_inst_size;
logic ld_da_boundary;
logic ld_da_secd;
logic ld_da_sign_extend;
logic [LSIQ_ENTRY-1:0] ld_da_lsid;
logic ld_da_old;
logic [15:0] ld_da_bytes_vld;
logic [15:0] ld_da_bytes_vld1;
logic ld_da_acclr_en;
logic ld_da_raw_new;
logic [31:0] ld_da_addr0;
logic ld_da_cb_addr_create_vld;
logic ld_da_rb_data_vld;
logic ld_da_rb_discard_grnt;
logic ld_da_lfb_discard_grnt;
logic ld_da_rb_cmit;
logic ld_da_boundary_after_mask;
logic [4:0] ld_da_idx;
logic ld_da_discard_wmb;

// CB (Combine Buffer) signals
logic cb_ld_da_data_vld;
logic [127:0] cb_ld_da_data;

// SQ to LD_DA signals
logic sq_ld_dc_other_discard_req;
logic sq_ld_dc_data_discard_req;
logic sq_ld_dc_fwd_bypass_req;
logic sq_ld_dc_fwd_multi;
logic sq_ld_dc_fwd_multi_mask;
logic sq_ld_dc_fwd_bypass_multi;
logic [31:0] sq_ld_da_fwd_data;

// Additional SQ signals
logic rb_sq_pop_hit_idx;
logic [SQ_ENTRY-1:0] ld_da_sq_fwd_id;
logic ld_da_sq_data_discard_vld;
logic ld_da_sq_fwd_multi_vld;
logic ld_da_sq_global_discard_vld;

// WMB to LD_DA signals
logic [127:0] wmb_ld_da_fwd_data;

// SD (Store Data) signals
logic sd_ex1_inst_vld;

// MSHR/RB to LD_DA signals
logic rb_ld_da_hit_idx;
logic rb_ld_da_merge_fail;
logic rb_ld_da_full;

// LFB to LD_DA signals
logic lfb_ld_da_hit_idx;

// DCache data bank outputs
logic [31:0] dcache_lsu_ld_data_bank0_dout;
logic [31:0] dcache_lsu_ld_data_bank1_dout;
logic [31:0] dcache_lsu_ld_data_bank2_dout;
logic [31:0] dcache_lsu_ld_data_bank3_dout;
logic [31:0] dcache_lsu_ld_data_bank4_dout;
logic [31:0] dcache_lsu_ld_data_bank5_dout;
logic [31:0] dcache_lsu_ld_data_bank6_dout;
logic [31:0] dcache_lsu_ld_data_bank7_dout;

// Read buffer signals (placeholder)
logic rb_ld_wb_bus_err;
logic [31:0] rb_ld_wb_bus_err_addr;
logic rb_ld_wb_cmplt_req;
logic [31:0] rb_ld_wb_data;
logic [6:0] rb_ld_wb_data_iid;
logic rb_ld_wb_data_req;
logic [6:0] rb_ld_wb_iid;
logic [5:0] rb_ld_wb_preg;
logic [3:0] rb_ld_wb_preg_sign_sel;
logic ld_wb_rb_cmplt_grnt;
logic ld_wb_rb_data_grnt;
logic rb_st_da_full;
logic rb_st_da_hit_idx;
logic lfb_st_da_hit_idx;

// RB to LFB signals
logic [27:0] rb_lfb_addr_tto4;
logic rb_lfb_boundary_depd_wakeup;
logic rb_lfb_create_req;
logic rb_lfb_create_vld;
logic rb_lfb_depd;
logic [31:0] rb_biu_req_addr;

// LFB to RB signals
logic [3:0] lfb_rb_create_id;
logic lfb_rb_ca_rready_grnt;
logic lfb_rb_biu_req_hit_idx;
logic lfb_addr_full;

// WMB to RB signal
logic wmb_rb_biu_req_hit_idx;

// LD_DA to RB signals
logic ld_da_rb_create_vld;
logic ld_da_rb_merge_vld;
logic [7:0] ld_da_data_rot_sel;

// Load WB outputs (placeholder)
logic ld_wb_data_vld;
logic ld_wb_inst_vld;
logic [31:0] lsu_rtu_async_expt_addr;
logic lsu_rtu_async_expt_vld;
logic ld_da_wb_expt_vld;
logic [31:0] ld_da_wb_expt_addr;
assign lsu_biu_r_ready = 1'b1;
// Control signals (placeholder)
assign bus_arb_rb_ar_sel = bus_arb_rb_ar_grnt;
//==========================================================
// Module Instantiations
//==========================================================
ct_lsu_bus_arb u_ct_lsu_bus_arb (
  // 输入：BIU 握手/授权
  .biu_lsu_ar_ready          (biu_lsu_ar_ready         ),
  .biu_lsu_aw_vb_grnt        (biu_lsu_aw_vb_grnt       ),
  .biu_lsu_aw_wmb_grnt       (biu_lsu_aw_wmb_grnt      ),
  .biu_lsu_w_vb_grnt         (biu_lsu_w_vb_grnt        ),
  .biu_lsu_w_wmb_grnt        (biu_lsu_w_wmb_grnt       ),

  // RB AR 请求
  .rb_biu_ar_addr            (rb_biu_ar_addr           ),
  .rb_biu_ar_bar             (rb_biu_ar_bar            ),
  .rb_biu_ar_burst           (rb_biu_ar_burst          ),
  .rb_biu_ar_cache           (rb_biu_ar_cache          ),
  .rb_biu_ar_domain          (rb_biu_ar_domain         ),
  .rb_biu_ar_id              (rb_biu_ar_id             ),
  .rb_biu_ar_len             (rb_biu_ar_len            ),
  .rb_biu_ar_lock            (rb_biu_ar_lock           ),
  .rb_biu_ar_prot            (rb_biu_ar_prot           ),
  .rb_biu_ar_req             (rb_biu_ar_req            ),
  .rb_biu_ar_size            (rb_biu_ar_size           ),
  .rb_biu_ar_user            (rb_biu_ar_user           ),

  // VB AW 请求
  .vb_biu_aw_addr            (vb_biu_aw_addr           ),
  .vb_biu_aw_bar             (vb_biu_aw_bar            ),
  .vb_biu_aw_burst           (vb_biu_aw_burst          ),
  .vb_biu_aw_cache           (vb_biu_aw_cache          ),
  .vb_biu_aw_domain          (vb_biu_aw_domain         ),
  .vb_biu_aw_id              (vb_biu_aw_id             ),
  .vb_biu_aw_len             (vb_biu_aw_len            ),
  .vb_biu_aw_lock            (vb_biu_aw_lock           ),
  .vb_biu_aw_prot            (vb_biu_aw_prot           ),
  .vb_biu_aw_req             (vb_biu_aw_req            ),
  .vb_biu_aw_size            (vb_biu_aw_size           ),
  .vb_biu_aw_user            (vb_biu_aw_user           ),

  // VB W 请求
  .vb_biu_w_data             (vb_biu_w_data            ),
  .vb_biu_w_last             (vb_biu_w_last            ),
  .vb_biu_w_req              (vb_biu_w_req             ),
  .vb_biu_w_strb             (vb_biu_w_strb            ),
  .vb_biu_w_vld              (vb_biu_w_vld             ),

  // WMB AW 请求
  .wmb_biu_aw_addr           (wmb_biu_aw_addr          ),
  .wmb_biu_aw_bar            (wmb_biu_aw_bar           ),
  .wmb_biu_aw_burst          (wmb_biu_aw_burst         ),
  .wmb_biu_aw_cache          (wmb_biu_aw_cache         ),
  .wmb_biu_aw_domain         (wmb_biu_aw_domain        ),
  .wmb_biu_aw_id             (wmb_biu_aw_id            ),
  .wmb_biu_aw_len            (wmb_biu_aw_len           ),
  .wmb_biu_aw_lock           (wmb_biu_aw_lock          ),
  .wmb_biu_aw_prot           (wmb_biu_aw_prot          ),
  .wmb_biu_aw_req            (wmb_biu_aw_req           ),
  .wmb_biu_aw_size           (wmb_biu_aw_size          ),
  .wmb_biu_aw_user           (wmb_biu_aw_user          ),

  // WMB W 请求
  .wmb_biu_w_data            (wmb_biu_w_data           ),
  .wmb_biu_w_last            (wmb_biu_w_last           ),
  .wmb_biu_w_req             (wmb_biu_w_req            ),
  .wmb_biu_w_strb            (wmb_biu_w_strb           ),
  .wmb_biu_w_vld             (wmb_biu_w_vld            ),

  // AR 授权
  .bus_arb_rb_ar_grnt        (bus_arb_rb_ar_grnt       ),

  // AW 授权
  .bus_arb_vb_aw_grnt        (bus_arb_vb_aw_grnt       ),
  .bus_arb_wmb_aw_grnt       (bus_arb_wmb_aw_grnt      ),

  // W 授权
  .bus_arb_vb_w_grnt         (bus_arb_vb_w_grnt        ),
  .bus_arb_wmb_w_grnt        (bus_arb_wmb_w_grnt       ),

  // BIU AR 输出
  .lsu_biu_ar_addr           (lsu_biu_ar_addr          ),
  .lsu_biu_ar_bar            (lsu_biu_ar_bar           ),
  .lsu_biu_ar_burst          (lsu_biu_ar_burst         ),
  .lsu_biu_ar_cache          (lsu_biu_ar_cache         ),
  .lsu_biu_ar_domain         (lsu_biu_ar_domain        ),
  .lsu_biu_ar_id             (lsu_biu_ar_id            ),
  .lsu_biu_ar_len            (lsu_biu_ar_len           ),
  .lsu_biu_ar_lock           (lsu_biu_ar_lock          ),
  .lsu_biu_ar_prot           (lsu_biu_ar_prot          ),
  .lsu_biu_ar_req            (lsu_biu_ar_req           ),
  .lsu_biu_ar_size           (lsu_biu_ar_size          ),
  .lsu_biu_ar_user           (lsu_biu_ar_user          ),

  // BIU AW store 输出
  .lsu_biu_aw_st_addr        (lsu_biu_aw_st_addr       ),
  .lsu_biu_aw_st_bar         (lsu_biu_aw_st_bar        ),
  .lsu_biu_aw_st_burst       (lsu_biu_aw_st_burst      ),
  .lsu_biu_aw_st_cache       (lsu_biu_aw_st_cache      ),
  .lsu_biu_aw_st_domain      (lsu_biu_aw_st_domain     ),
  .lsu_biu_aw_st_id          (lsu_biu_aw_st_id         ),
  .lsu_biu_aw_st_len         (lsu_biu_aw_st_len        ),
  .lsu_biu_aw_st_lock        (lsu_biu_aw_st_lock       ),
  .lsu_biu_aw_st_prot        (lsu_biu_aw_st_prot       ),
  .lsu_biu_aw_st_req         (lsu_biu_aw_st_req        ),
  .lsu_biu_aw_st_size        (lsu_biu_aw_st_size       ),
  .lsu_biu_aw_st_user        (lsu_biu_aw_st_user       ),

  // BIU AW victim 输出
  .lsu_biu_aw_vict_addr      (lsu_biu_aw_vict_addr     ),
  .lsu_biu_aw_vict_bar       (lsu_biu_aw_vict_bar      ),
  .lsu_biu_aw_vict_burst     (lsu_biu_aw_vict_burst    ),
  .lsu_biu_aw_vict_cache     (lsu_biu_aw_vict_cache    ),
  .lsu_biu_aw_vict_domain    (lsu_biu_aw_vict_domain   ),
  .lsu_biu_aw_vict_id        (lsu_biu_aw_vict_id       ),
  .lsu_biu_aw_vict_len       (lsu_biu_aw_vict_len      ),
  .lsu_biu_aw_vict_lock      (lsu_biu_aw_vict_lock     ),
  .lsu_biu_aw_vict_prot      (lsu_biu_aw_vict_prot     ),
  .lsu_biu_aw_vict_req       (lsu_biu_aw_vict_req      ),
  .lsu_biu_aw_vict_size      (lsu_biu_aw_vict_size     ),
  .lsu_biu_aw_vict_user      (lsu_biu_aw_vict_user     ),

  // BIU W store 输出
  .lsu_biu_w_st_data         (lsu_biu_w_st_data        ),
  .lsu_biu_w_st_last         (lsu_biu_w_st_last        ),
  .lsu_biu_w_st_strb         (lsu_biu_w_st_strb        ),
  .lsu_biu_w_st_vld          (lsu_biu_w_st_vld         ),

  // BIU W victim 输出
  .lsu_biu_w_vict_data       (lsu_biu_w_vict_data      ),
  .lsu_biu_w_vict_last       (lsu_biu_w_vict_last      ),
  .lsu_biu_w_vict_strb       (lsu_biu_w_vict_strb      ),
  .lsu_biu_w_vict_vld        (lsu_biu_w_vict_vld       )
);
//----------------------------------------------------------
// Load Address Generation
//----------------------------------------------------------
lsu_ld_ag #(
  .IID_WIDTH(6),
  .LSIQ_ENTRY(LSIQ_ENTRY),
  .DCACHE_SIZE(DCACHE_SIZE)
) u_lsu_ld_ag (
  .forever_cpuclk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .idu_lsu_ld_sel(idu_lsu_ld_sel),//in
  .idu_lsu_ld_inst_size(idu_lsu_ld_inst_size),//in
  .idu_lsu_ld_unalign_2nd(idu_lsu_ld_unalign_2nd),//in
  .idu_lsu_ld_sign_extend(idu_lsu_ld_sign_extend),//in
  .idu_lsu_ld_iid(idu_lsu_ld_iid),//in
  .idu_lsu_ld_lch_entry(idu_lsu_ld_lch_entry),//in
  .idu_lsu_ld_oldest(idu_lsu_ld_oldest),//in
  .idu_lsu_ld_preg(idu_lsu_ld_preg),//in
  .idu_lsu_ld_offset(idu_lsu_ld_offset),//in
  .idu_lsu_ld_offset_plus(idu_lsu_ld_offset_plus),//in
  .idu_lsu_ld_src(idu_lsu_ld_src),//in
  .rtu_yy_xx_flush(rtu_yy_xx_flush),//in
  .rtu_yy_xx_commit0(rtu_yy_xx_commit0),//in
  .rtu_yy_xx_commit0_iid(rtu_yy_xx_commit0_iid),//in
  .rtu_yy_xx_commit1(rtu_yy_xx_commit1),//in
  .rtu_yy_xx_commit1_iid(rtu_yy_xx_commit1_iid),//in
  .rtu_yy_xx_commit2(rtu_yy_xx_commit2),//in
  .rtu_yy_xx_commit2_iid(rtu_yy_xx_commit2_iid),//in
  .st_ag_iid(st_ag_iid),
  .dcache_arb_ld_ag_borrow_addr_vld(dcache_arb_ld_ag_borrow_addr_vld),
  .dcache_arb_ld_ag_addr(dcache_arb_ld_ag_addr),
  .dcache_arb_ag_ld_sel(dcache_arb_ag_ld_sel),
  .ld_ag_dc_inst_vld(ld_ag_dc_inst_vld),
  .ld_ag_inst_size(ld_ag_inst_size),
  .ld_ag_secd(ld_ag_secd),
  .ld_ag_sign_extend(ld_ag_sign_extend),
  .ld_ag_iid(ld_ag_iid),
  .ld_ag_lsid(ld_ag_lsid),
  .ld_ag_old(ld_ag_old),
  .ld_ag_preg(ld_ag_preg),
  .ld_ag_boundary(ld_ag_boundary),
  .ld_ag_acclr_en(ld_ag_acclr_en),
  .ld_ag_dc_fwd_bypass_en(ld_ag_dc_fwd_bypass_en),
  .ld_ag_expt(ld_ag_expt),
  .ag_dcache_arb_ld_tag_gateclk_en(ag_dcache_arb_ld_tag_gateclk_en),
  .ag_dcache_arb_ld_tag_req(ag_dcache_arb_ld_tag_req),
  .ag_dcache_arb_ld_tag_idx(ag_dcache_arb_ld_tag_idx),
  .ag_dcache_arb_ld_data_gateclk_en(ag_dcache_arb_ld_data_gateclk_en),
  .ag_dcache_arb_ld_data_req(ag_dcache_arb_ld_data_req),
  .ag_dcache_arb_ld_data_low_idx(ag_dcache_arb_ld_data_low_idx),
  .ag_dcache_arb_ld_data_high_idx(ag_dcache_arb_ld_data_high_idx),
  .ld_ag_bytes_vld1(ld_ag_bytes_vld1),
  .ld_ag_bytes_vld(ld_ag_bytes_vld),
  .ld_ag_addr1_to4(ld_ag_addr1_to4),
  .ld_ag_dc_addr0(ld_ag_dc_addr0),
  .ld_ag_raw_new(ld_ag_raw_new),
  .ld_ag_stall_restart_entry(ld_ag_stall_restart_entry)
);

//----------------------------------------------------------
// Load Data Cache
//----------------------------------------------------------
logic ld_dc_settle_way;
lsu_ld_dc #(
  .IID_WIDTH(6),
  .LSIQ_ENTRY(LSIQ_ENTRY),
  .DCACHE_SIZE(DCACHE_SIZE)
) u_lsu_ld_dc (
  .forever_cpuclk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .ld_ag_dc_inst_vld(ld_ag_dc_inst_vld),
  .ld_ag_inst_size(ld_ag_inst_size),
  .ld_ag_secd(ld_ag_secd),
  .ld_ag_sign_extend(ld_ag_sign_extend),
  .ld_ag_iid(ld_ag_iid),
  .ld_ag_lsid(ld_ag_lsid),
  .ld_ag_old(ld_ag_old),
  .ld_ag_preg(ld_ag_preg),
  .ld_ag_boundary(ld_ag_boundary),
  .ld_ag_acclr_en(ld_ag_acclr_en),
  .ld_ag_dc_fwd_bypass_en(ld_ag_dc_fwd_bypass_en),
  .ld_ag_expt(ld_ag_expt),
  .ld_ag_bytes_vld1(ld_ag_bytes_vld1),
  .ld_ag_bytes_vld(ld_ag_bytes_vld),
  .ld_ag_raw_new(ld_ag_raw_new),
  .ld_ag_addr1_to4(ld_ag_addr1_to4),
  .ld_ag_dc_addr0(ld_ag_dc_addr0),
  .st_dc_chk_st_inst_vld(st_dc_chk_st_inst_vld),
  .st_dc_bytes_vld(st_dc_bytes_vld),
  .st_dc_addr0(st_dc_addr0),
  .lq_ld_dc_inst_hit(lq_ld_dc_inst_hit),
  .lq_ld_dc_full(lq_ld_dc_full),
  .lq_ld_dc_less2(lq_ld_dc_less2),
  .dcache_idx(dcache_idx),
  .dcache_arb_ld_dc_borrow_vld(dcache_arb_ld_dc_borrow_vld),
  .dcache_arb_ld_dc_settle_way(dcache_arb_ld_dc_settle_way),
  .dcache_lsu_ld_tag_dout(dcache_lsu_ld_tag_dout),
  .cb_ld_dc_addr_hit(cb_ld_dc_addr_hit),
  .sq_ld_dc_cancel_acc_req(sq_ld_dc_cancel_acc_req),
  .sq_ld_dc_fwd_req(sq_ld_dc_fwd_req),
  .wmb_ld_dc_cancel_acc_req(wmb_ld_dc_cancel_acc_req),
  .wmb_ld_dc_fwd_req(wmb_ld_dc_fwd_req),
  .wmb_fwd_bytes_vld(wmb_fwd_bytes_vld),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .sq_ld_dc_addr1_dep_discard(sq_ld_dc_addr1_dep_discard),
  .ld_dc_da_inst_vld(ld_dc_da_inst_vld),
  .ld_dc_borrow_vld(ld_dc_borrow_vld),
  .ld_dc_settle_way(ld_dc_settle_way),
  .ld_dc_inst_size(ld_dc_inst_size),
  .ld_dc_addr1_to4(ld_dc_addr1_to4),
  .ld_dc_boundary(ld_dc_boundary),
  .ld_dc_secd(ld_dc_secd),
  .ld_dc_sign_extend(ld_dc_sign_extend),
  .ld_dc_iid(ld_dc_iid),
  .ld_dc_lsid(ld_dc_lsid),
  .ld_dc_old(ld_dc_old),
  .ld_dc_preg(ld_dc_preg),
  .ld_dc_expt(ld_dc_expt),
  .ld_dc_bytes_vld(ld_dc_bytes_vld),
  .ld_dc_bytes_vld1(ld_dc_bytes_vld1),
  .ld_dc_acclr_en(ld_dc_acclr_en),
  .ld_dc_da_cb_merge_en(ld_dc_da_cb_merge_en),
  .ld_dc_raw_new(ld_dc_raw_new),
  .ld_dc_addr0(ld_dc_addr0),
  .ld_dc_cb_addr_create_vld(ld_dc_cb_addr_create_vld),
  .ld_dc_cb_addr_tto4(ld_dc_cb_addr_tto4),
  .ld_dc_chk_ld_inst_vld(ld_dc_chk_ld_inst_vld),
  .ld_dc_chk_ld_addr1_vld(ld_dc_chk_ld_addr1_vld),
  .ld_dc_chk_ld_bypass_vld(ld_dc_chk_ld_bypass_vld),
  .ld_dc_idu_lq_full(ld_dc_idu_lq_full),//out
  .ld_dc_imme_wakeup(ld_dc_imme_wakeup),//out
  .ld_dc_hit_low_region(ld_dc_hit_low_region),
  .ld_dc_hit_high_region(ld_dc_hit_high_region),
  .ld_dc_dcache_hit(ld_dc_dcache_hit),
  .ld_dc_da_data_rot_sel(ld_dc_da_data_rot_sel),
  .ld_dc_preg_sign_sel(ld_dc_preg_sign_sel),
  .ld_dc_fwd_bytes_vld(ld_dc_fwd_bytes_vld),
  .ld_dc_fwd_sq_vld(ld_dc_fwd_sq_vld),
  .ld_dc_fwd_wmb_vld(ld_dc_fwd_wmb_vld),

  .ld_dc_lq_create_vld(ld_dc_lq_create_vld),
  .ld_dc_lq_create1_vld(ld_dc_lq_create1_vld)

);

//----------------------------------------------------------
// Load Data Access
//----------------------------------------------------------
lsu_ld_da #(
  .IID_WIDTH(6),
  .LSIQ_ENTRY(LSIQ_ENTRY),
  .DC_IDX(8)
) u_lsu_ld_da (
  .forever_cpuclk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .ld_dc_da_inst_vld(ld_dc_da_inst_vld),
  .ld_dc_borrow_vld(ld_dc_borrow_vld),
  .ld_dc_inst_size(ld_dc_inst_size),
  .ld_dc_boundary(ld_dc_boundary),
  .ld_dc_secd(ld_dc_secd),
  .ld_dc_sign_extend(ld_dc_sign_extend),
  .ld_dc_iid(ld_dc_iid),
  .ld_dc_lsid(ld_dc_lsid),
  .ld_dc_old(ld_dc_old),
  .ld_dc_preg(ld_dc_preg),
  .ld_dc_expt(ld_dc_expt),
 // .ld_dc_addr1_to4(ld_dc_addr1_to4),
  .ld_dc_bytes_vld(ld_dc_bytes_vld),
  .ld_dc_bytes_vld1(ld_dc_bytes_vld1),
  .ld_dc_acclr_en(ld_dc_acclr_en),
  .ld_dc_da_cb_merge_en(ld_dc_da_cb_merge_en),
  .ld_dc_raw_new(ld_dc_raw_new),
  .ld_dc_addr0(ld_dc_addr0),
  .ld_dc_cb_addr_create_vld(ld_dc_cb_addr_create_vld),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .dcache_lsu_ld_data_bank0_dout(dcache_lsu_ld_data_bank0_dout),
  .dcache_lsu_ld_data_bank1_dout(dcache_lsu_ld_data_bank1_dout),
  .dcache_lsu_ld_data_bank2_dout(dcache_lsu_ld_data_bank2_dout),
  .dcache_lsu_ld_data_bank3_dout(dcache_lsu_ld_data_bank3_dout),
  .dcache_lsu_ld_data_bank4_dout(dcache_lsu_ld_data_bank4_dout),
  .dcache_lsu_ld_data_bank5_dout(dcache_lsu_ld_data_bank5_dout),
  .dcache_lsu_ld_data_bank6_dout(dcache_lsu_ld_data_bank6_dout),
  .dcache_lsu_ld_data_bank7_dout(dcache_lsu_ld_data_bank7_dout),
  .ld_dc_hit_low_region(ld_dc_hit_low_region),
  .ld_dc_hit_high_region(ld_dc_hit_high_region),
  .ld_dc_dcache_hit(ld_dc_dcache_hit),
  .ld_dc_da_data_rot_sel(ld_dc_da_data_rot_sel),
  .ld_dc_preg_sign_sel(ld_dc_preg_sign_sel),
  .ld_dc_fwd_bytes_vld(ld_dc_fwd_bytes_vld),
  .ld_dc_fwd_sq_vld(ld_dc_fwd_sq_vld),
  .ld_dc_fwd_wmb_vld(ld_dc_fwd_wmb_vld),
  .sq_ld_dc_fwd_id(sq_ld_dc_fwd_id),
  .ld_da_sq_fwd_id(ld_da_sq_fwd_id),
  .ld_da_sq_data_discard_vld(ld_da_sq_data_discard_vld),
  .ld_da_sq_fwd_multi_vld(ld_da_sq_fwd_multi_vld),
  .ld_da_sq_global_discard_vld(ld_da_sq_global_discard_vld),
  .cb_ld_da_data_vld(cb_ld_da_data_vld),
  .cb_ld_da_data(cb_ld_da_data),
  .sq_ld_dc_other_discard_req(sq_ld_dc_other_discard_req),
  .sq_ld_dc_data_discard_req(sq_ld_dc_data_discard_req),
  .sq_ld_dc_fwd_multi(sq_ld_dc_fwd_multi),
  .sq_ld_dc_fwd_multi_mask(sq_ld_dc_fwd_multi_mask),
  .sq_ld_da_fwd_data(sq_ld_da_fwd_data),
  .wmb_ld_da_fwd_data(wmb_ld_da_fwd_data),
  .sd_ex1_inst_vld(sd_ex1_inst_vld),
  .rb_ld_da_hit_idx(rb_ld_da_hit_idx),
  .rb_ld_da_merge_fail(rb_ld_da_merge_fail),
  .lfb_ld_da_hit_idx(lfb_ld_da_hit_idx),
  .rb_ld_da_full(rb_ld_da_full),
  .rtu_yy_xx_commit0(rtu_yy_xx_commit0),
  .rtu_yy_xx_commit0_iid(rtu_yy_xx_commit0_iid),
  .rtu_yy_xx_commit1(rtu_yy_xx_commit1),
  .rtu_yy_xx_commit1_iid(rtu_yy_xx_commit1_iid),
  .rtu_yy_xx_commit2(rtu_yy_xx_commit2),
  .rtu_yy_xx_commit2_iid(rtu_yy_xx_commit2_iid),
  .ld_da_discard_wmb(ld_da_discard_wmb),
  .ld_da_inst_size(ld_da_inst_size),
  .ld_da_boundary(ld_da_boundary),
  .ld_da_secd(ld_da_secd),
  .ld_da_sign_extend(ld_da_sign_extend),
  .ld_da_iid(ld_da_iid),
  .ld_da_lsid(ld_da_lsid),
  .ld_da_old(ld_da_old),
  .ld_da_preg(ld_da_preg),
  .ld_da_bytes_vld(ld_da_bytes_vld),
  .ld_da_bytes_vld1(ld_da_bytes_vld1),
  .ld_da_acclr_en(ld_da_acclr_en),
  .ld_da_raw_new(ld_da_raw_new),
  .ld_da_addr0(ld_da_addr0),
  .ld_da_cb_addr_create_vld(ld_da_cb_addr_create_vld),
  .ld_da_rb_data_vld(ld_da_rb_data_vld),
  .ld_da_rb_discard_grnt(ld_da_rb_discard_grnt),
  .ld_da_lfb_discard_grnt(ld_da_lfb_discard_grnt),
  .ld_da_rb_cmit(ld_da_rb_cmit),
  .ld_da_addr(ld_da_addr),
  .ld_da_boundary_after_mask(ld_da_boundary_after_mask),
  .ld_da_idx(ld_da_idx),
  .ld_da_rb_merge_vld(ld_da_rb_merge_vld),
  .ld_da_rb_create_vld(ld_da_rb_create_vld),
  .ld_da_data_rot_sel(ld_da_data_rot_sel),
  .ld_da_cb_ld_inst_vld(ld_da_cb_ld_inst_vld),
  .ld_da_cb_data_vld(ld_da_cb_data_vld),
  .ld_da_cb_data(ld_da_cb_data),
  .ld_da_idu_rb_full(ld_da_idu_rb_full),
  .ld_da_idu_pop_vld(ld_da_idu_pop_vld),
  .ld_da_idu_pop_entry(ld_da_idu_pop_entry),
  .ld_da_idu_secd(ld_da_idu_secd),
  .ld_da_vb_borrow_vb(ld_da_vb_borrow_vb),
  .ld_da_data256(ld_da_data256),
  .ld_dc_settle_way(ld_dc_settle_way),
  .ld_da_wb_cmplt_req(ld_da_wb_cmplt_req),
  .ld_da_wb_expt_vld(ld_da_wb_expt_vld),
  .ld_da_wb_expt_addr(ld_da_wb_expt_addr),
  .ld_da_wb_data_req(ld_da_wb_data_req),
  .ld_da_wb_data(ld_da_wb_data),
  .ld_da_preg_sign_sel(ld_da_preg_sign_sel)
);

//----------------------------------------------------------
// Load Writeback
//----------------------------------------------------------
ct_lsu_ld_wb #(
  .BYTE(2'b00),
  .HALF(2'b01),
  .WORD(2'b10),
  .DWORD(2'b11),
  .VMB_ENTRY(8)
) u_lsu_ld_wb (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .ld_da_addr(ld_da_addr),
  .ld_da_iid(ld_da_iid),
  .ld_da_preg(ld_da_preg),
  .ld_da_preg_sign_sel(ld_da_preg_sign_sel),
  .ld_da_wb_cmplt_req(ld_da_wb_cmplt_req),
  .ld_da_wb_expt_vld(ld_da_wb_expt_vld),
  .ld_da_wb_expt_addr(ld_da_wb_expt_addr),
  .ld_da_wb_data(ld_da_wb_data),
  .ld_da_wb_data_req(ld_da_wb_data_req),
  .rb_ld_wb_bus_err(rb_ld_wb_bus_err),
  .rb_ld_wb_bus_err_addr(rb_ld_wb_bus_err_addr),
  .rb_ld_wb_cmplt_req(rb_ld_wb_cmplt_req),
  .rb_ld_wb_data(rb_ld_wb_data),
  .rb_ld_wb_data_iid(rb_ld_wb_data_iid),
  .rb_ld_wb_data_req(rb_ld_wb_data_req),
  .rb_ld_wb_iid(rb_ld_wb_iid),
  .rb_ld_wb_preg(rb_ld_wb_preg),
  .rb_ld_wb_preg_sign_sel(rb_ld_wb_preg_sign_sel),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .ld_wb_data_vld(ld_wb_data_vld),
  .ld_wb_inst_vld(ld_wb_inst_vld),
  .ld_wb_rb_cmplt_grnt(ld_wb_rb_cmplt_grnt),
  .ld_wb_rb_data_grnt(ld_wb_rb_data_grnt),
  .lsu_rtu_async_expt_addr(lsu_rtu_async_expt_addr),
  .lsu_rtu_async_expt_vld(lsu_rtu_async_expt_vld),
  .lsu_rtu_wb_pipe3_cmplt(lsu_rtu_wb_pipe3_cmplt),
  .lsu_rtu_wb_pipe3_iid(lsu_rtu_wb_pipe3_iid),
  .lsu_rtu_wb_pipe3_expt_vld(lsu_rtu_wb_pipe3_expt_vld),
  .lsu_rtu_wb_pipe3_expt_addr(lsu_rtu_wb_pipe3_expt_addr),
  .lsu_rtu_wb_pipe3_wb_preg_expand(lsu_rtu_wb_pipe3_wb_preg_expand),
  .lsu_rtu_wb_pipe3_wb_preg_vld(lsu_rtu_wb_pipe3_wb_preg_vld),
  .lsu_idu_wb_pipe3_wb_preg(lsu_idu_wb_pipe3_wb_preg),
  .lsu_idu_wb_pipe3_wb_preg_data(lsu_idu_wb_pipe3_wb_preg_data),
  .lsu_idu_wb_pipe3_wb_preg_expand(lsu_idu_wb_pipe3_wb_preg_expand),
  .lsu_idu_wb_pipe3_wb_preg_vld(lsu_idu_wb_pipe3_wb_preg_vld)
);

ct_lsu_cache_buffer u_ct_lsu_cache_buffer (
    .cpurst_b                  (cpurst_b),
    .dcache_idx                (dcache_idx),
    .forever_cpuclk            (forever_cpuclk),
    .ld_da_cb_data             (ld_da_cb_data),
    .ld_da_cb_data_vld         (ld_da_cb_data_vld),
    .ld_da_cb_ld_inst_vld      (ld_da_cb_ld_inst_vld),
    .ld_dc_addr1_to4           (ld_dc_addr1_to4),
    .ld_dc_cb_addr_create_vld  (ld_dc_cb_addr_create_vld),
    .ld_dc_cb_addr_tto4        (ld_dc_cb_addr_tto4),
    .lsu_dcache_ld_xx_gwen     (lsu_dcache_ld_xx_gwen),
    .cb_ld_da_data             (cb_ld_da_data),
    .cb_ld_da_data_vld         (cb_ld_da_data_vld),
    .cb_ld_dc_addr_hit         (cb_ld_dc_addr_hit)
);

//----------------------------------------------------------
// Store Address Generation
//----------------------------------------------------------
ct_lsu_st_ag #(
  .DCACHE_SIZE(DCACHE_SIZE)
) u_lsu_st_ag (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .idu_lsu_st_sel(idu_lsu_st_sel),
  .idu_lsu_st_inst_size(idu_lsu_st_inst_size),
  .idu_lsu_st_unalign_2nd(idu_lsu_st_unalign_2nd),
  .idu_lsu_st_iid(idu_lsu_st_iid),
  .idu_lsu_st_lch_entry(idu_lsu_st_lch_entry),
  .idu_lsu_st_sdiq_entry(idu_lsu_st_sdiq_entry),
  .idu_lsu_st_oldest(idu_lsu_st_oldest),
  .idu_lsu_st_offset(idu_lsu_st_offset),
  .idu_lsu_st_offset_plus(idu_lsu_st_offset_plus),
  .idu_lsu_st_src0(idu_lsu_st_src0),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .dcache_arb_ag_st_sel(dcache_arb_ag_st_sel),
  .dcache_arb_st_ag_borrow_addr_vld(dcache_arb_st_ag_borrow_addr_vld),
  .dcache_arb_st_ag_addr(dcache_arb_st_ag_addr),
  .ag_dcache_arb_st_dirty_gateclk_en(ag_dcache_arb_st_dirty_gateclk_en),
  .ag_dcache_arb_st_dirty_idx(ag_dcache_arb_st_dirty_idx),
  .ag_dcache_arb_st_dirty_req(ag_dcache_arb_st_dirty_req),
  .ag_dcache_arb_st_tag_gateclk_en(ag_dcache_arb_st_tag_gateclk_en),
  .ag_dcache_arb_st_tag_idx(ag_dcache_arb_st_tag_idx),
  .ag_dcache_arb_st_tag_req(ag_dcache_arb_st_tag_req),
  .st_ag_boundary(st_ag_boundary),
  .st_ag_dc_addr0(st_ag_dc_addr0),
  .st_ag_dc_bytes_vld(st_ag_dc_bytes_vld),
  .st_ag_dc_inst_vld(st_ag_dc_inst_vld),
  .st_ag_dc_rot_sel(st_ag_dc_rot_sel),
  .st_ag_iid(st_ag_iid),
  .st_ag_inst_vld(st_ag_inst_vld),
  .st_ag_lsid(st_ag_lsid),
  .st_ag_old(st_ag_old),
  .st_ag_expt(st_ag_expt),
  .st_ag_sdid_oh(st_ag_sdid_oh),
  .st_ag_secd(st_ag_secd),
  .st_ag_stall_restart_entry(st_ag_stall_restart_entry)
);

//----------------------------------------------------------
// Store Data Cache
//----------------------------------------------------------
ct_lsu_st_dc u_lsu_st_dc (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .dcache_arb_st_dc_borrow_vld(dcache_arb_st_dc_borrow_vld),
  .dcache_lsu_st_dirty_dout(dcache_lsu_st_dirty_dout),
  .dcache_lsu_st_tag_dout(dcache_lsu_st_tag_dout),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .dcache_dirty_gwen(dcache_dirty_gwen),
  .dcache_idx(dcache_idx),
  .lq_st_dc_spec_fail(lq_st_dc_spec_fail),
  .sq_st_dc_full(sq_st_dc_full),
  .sq_st_dc_inst_hit(sq_st_dc_inst_hit),
  .st_ag_boundary(st_ag_boundary),
  .st_ag_dc_addr0(st_ag_dc_addr0),
  .st_ag_dc_bytes_vld(st_ag_dc_bytes_vld),
  .st_ag_dc_inst_vld(st_ag_dc_inst_vld),
  .st_ag_dc_rot_sel(st_ag_dc_rot_sel),
  .st_ag_iid(st_ag_iid),
  .st_ag_inst_vld(st_ag_inst_vld),
  .st_ag_lsid(st_ag_lsid),
  .st_ag_old(st_ag_old),
  .st_ag_expt(st_ag_expt),
  .st_ag_sdid_oh(st_ag_sdid_oh),
  .st_ag_secd(st_ag_secd),
  .st_dc_inst_vld(st_dc_inst_vld),
  .st_dc_borrow_vld(st_dc_borrow_vld),
  .st_dc_secd(st_dc_secd),
  .st_dc_iid(st_dc_iid),
  .st_dc_lsid(st_dc_lsid),
  .st_dc_sdid_oh(st_dc_sdid_oh),
  .st_dc_old(st_dc_old),
  .st_dc_expt(st_dc_expt),
  .st_dc_bytes_vld(st_dc_bytes_vld),
  .st_dc_rot_sel(st_dc_rot_sel),
  .st_dc_boundary(st_dc_boundary),
  .st_dc_addr0(st_dc_addr0),
  //.st_dc_sdid(st_dc_sdid),
  .st_dc_sq_create_vld(st_dc_sq_create_vld),
  .st_dc_sq_create_dp_vld(st_dc_sq_create_dp_vld),
  .st_dc_sq_create_gateclk_en(st_dc_sq_create_gateclk_en),
  .st_dc_sq_data_vld(st_dc_sq_data_vld),
  .st_dc_boundary_first(st_dc_boundary_first),
  .st_dc_chk_st_inst_vld(st_dc_chk_st_inst_vld),
  .st_dc_rot_sel_rev(st_dc_rot_sel_rev),
  .st_dc_da_inst_vld(st_dc_da_inst_vld),
  .st_dc_da_dcache_tag_array(st_dc_da_dcache_tag_array),
  .st_dc_da_dcache_dirty_array(st_dc_da_dcache_dirty_array),
  .st_dc_da_tag0_hit(st_dc_da_tag0_hit),
  .st_dc_da_tag1_hit(st_dc_da_tag1_hit),
  .st_dc_idu_sq_full(st_dc_idu_sq_full),
  .st_dc_dcwp_hit_idx(st_dc_dcwp_hit_idx),
  .st_dc_spec_fail(st_dc_spec_fail),
  .lsu_idu_has_in_sq(lsu_idu_has_in_sq)
);


//----------------------------------------------------------
// Store Data Access
//----------------------------------------------------------
logic [21:0] st_da_vb_feedback_addr_tto10;
ct_lsu_st_da #(
  .DCACHE_SIZE(DCACHE_SIZE),
  .LSIQ_ENTRY(LSIQ_ENTRY)
) u_lsu_st_da (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .dcache_dirty_din(dcache_dirty_din),
  .dcache_dirty_gwen(dcache_dirty_gwen),
  .dcache_dirty_wen(dcache_dirty_wen),
  .dcache_idx(dcache_idx),
  .dcache_tag_din(dcache_tag_din),
  .dcache_tag_gwen(dcache_tag_gwen),
  .dcache_tag_wen(dcache_tag_wen),
  .ld_da_st_da_hit_idx(ld_da_st_da_hit_idx),
  .lfb_st_da_hit_idx(lfb_st_da_hit_idx),
  .rb_st_da_full(rb_st_da_full),
  .rb_st_da_hit_idx(rb_st_da_hit_idx),
  .rtu_yy_xx_commit0(rtu_yy_xx_commit0),
  .rtu_yy_xx_commit0_iid(rtu_yy_xx_commit0_iid),
  .rtu_yy_xx_commit1(rtu_yy_xx_commit1),
  .rtu_yy_xx_commit1_iid(rtu_yy_xx_commit1_iid),
  .rtu_yy_xx_commit2(rtu_yy_xx_commit2),
  .rtu_yy_xx_commit2_iid(rtu_yy_xx_commit2_iid),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .st_dc_addr0(st_dc_addr0),
  .st_dc_borrow_vld(st_dc_borrow_vld),
  .st_dc_boundary(st_dc_boundary),
  .st_dc_bytes_vld(st_dc_bytes_vld),
  .st_dc_da_dcache_dirty_array(st_dc_da_dcache_dirty_array),
  .st_dc_da_dcache_tag_array(st_dc_da_dcache_tag_array),
  .st_dc_da_inst_vld(st_dc_da_inst_vld),
  .st_dc_da_tag0_hit(st_dc_da_tag0_hit),
  .st_dc_da_tag1_hit(st_dc_da_tag1_hit),
  .st_dc_dcwp_hit_idx(st_dc_dcwp_hit_idx),
  .st_dc_get_dcache_tag_dirty(st_dc_get_dcache_tag_dirty),
  .st_dc_iid(st_dc_iid),
  .st_dc_inst_vld(st_dc_inst_vld),
  .st_dc_lsid(st_dc_lsid),
  .st_dc_old(st_dc_old),
  .st_dc_expt(st_dc_expt),
  .st_dc_secd(st_dc_secd),
  .st_dc_spec_fail(st_dc_spec_fail),
  .st_da_borrow_vld(st_da_borrow_vld),
  .st_da_dcache_dirty(st_da_dcache_dirty),
  .st_da_dcache_hit(st_da_dcache_hit),
  .st_da_dcache_miss(st_da_dcache_miss),
  .st_da_dcache_replace_dirty(st_da_dcache_replace_dirty),
  .st_da_dcache_replace_valid(st_da_dcache_replace_valid),
  .st_da_dcache_replace_way(st_da_dcache_replace_way),
  .st_da_dcache_way(st_da_dcache_way),
  .st_da_idu_pop_vld(st_da_idu_pop_vld),
  .st_da_idu_pop_entry(st_da_idu_pop_entry),
  .st_da_idu_rb_full(st_da_idu_rb_full),
  .st_da_idu_secd(st_da_idu_secd),
  .st_da_iid(st_da_iid),
  .st_da_inst_vld(st_da_inst_vld),
  .st_da_old(st_da_old),
  .st_da_rb_cmit(st_da_rb_cmit),
  .st_da_rb_create_dp_vld(st_da_rb_create_dp_vld),
  .st_da_rb_create_gateclk_en(st_da_rb_create_gateclk_en),
  .st_da_rb_create_vld(st_da_rb_create_vld),
  .st_da_secd(st_da_secd),
  .st_da_sq_dcache_dirty(st_da_sq_dcache_dirty),
  .st_da_sq_dcache_valid(st_da_sq_dcache_valid),
  .st_da_sq_dcache_way(st_da_sq_dcache_way),
  .st_da_vb_feedback_addr_tto10(st_da_vb_feedback_addr_tto10),
  .st_da_wb_cmplt_req(st_da_wb_cmplt_req),
  .st_da_wb_expt_vld(st_da_wb_expt_vld),
  .st_da_wb_expt_addr(st_da_wb_expt_addr),
  .st_da_wb_spec_fail(st_da_wb_spec_fail),
  .st_da_addr(st_da_addr),
  .st_da_boundary(st_da_boundary),
  .st_da_bytes_vld(st_da_bytes_vld),
  .st_da_sq_no_restart(st_da_sq_no_restart)
);

//----------------------------------------------------------
// Store Writeback
//----------------------------------------------------------
ct_lsu_st_wb u_lsu_st_wb (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .st_da_iid(st_da_iid),
  .st_da_wb_cmplt_req(st_da_wb_cmplt_req),
  .st_da_wb_expt_vld(st_da_wb_expt_vld),
  .st_da_wb_expt_addr(st_da_wb_expt_addr),
  .st_da_wb_spec_fail(st_da_wb_spec_fail),
  .lsu_rtu_wb_pipe4_cmplt(lsu_rtu_wb_pipe4_cmplt),//out
  .lsu_rtu_wb_pipe4_expt_vld(lsu_rtu_wb_pipe4_expt_vld),
  .lsu_rtu_wb_pipe4_expt_addr(lsu_rtu_wb_pipe4_expt_addr),
  .lsu_rtu_wb_pipe4_flush(lsu_rtu_wb_pipe4_flush),//out
  .lsu_rtu_wb_pipe4_iid(lsu_rtu_wb_pipe4_iid),//out
  .lsu_rtu_wb_pipe4_spec_fail(lsu_rtu_wb_pipe4_spec_fail)//out
);

//----------------------------------------------------------
// Store Queue
//----------------------------------------------------------
// WMB CE signals used by SQ
logic [31:0]        wmb_ce_addr;
logic [127:0]       wmb_ce_data128;
logic [15:0]        wmb_ce_bytes_vld;
logic [3:0]         wmb_ce_data_vld;
logic [SQ_ENTRY-1:0] wmb_ce_sq_ptr;
logic               wmb_ce_merge;
logic [WMB_ENTRY-1:0] wmb_ce_merge_ptr;
logic [WMB_ENTRY-1:0] wmb_ce_same_dcache_line;
logic               wmb_ce_merge_en;
logic               wmb_ce_write_biu_req;
logic               wmb_ce_write_dcache_req;
logic               wmb_ce_merge_data_addr_hit;
logic               wmb_ce_merge_data_stall;
logic               wmb_ce_merge_wmb_req;
logic               wmb_ce_create_wmb_req;
logic               wmb_ce_create_wmb_data_req;
logic               wmb_ce_vld;
logic               wmb_ce_pop_vld;
logic               wmb_ce_create_vld;
logic               wmb_ce_create_merge;
logic [WMB_ENTRY-1:0] wmb_ce_create_merge_ptr;
logic               wmb_ce_create_stall;
logic               wmb_ce_bytes_vld_full;
logic               wmb_ce_dcache_dirty;
logic               wmb_ce_dcache_valid;
logic               wmb_ce_merge_wmb_wait_not_vld_req;

ct_lsu_sq #(
  .SQ_ENTRY(SQ_ENTRY),
  .LSIQ_ENTRY(LSIQ_ENTRY),
  .IID_WIDTH(7)
) u_lsu_sq (
  .cpurst_b(cpurst_b),
  .dcache_dirty_din(dcache_dirty_din),
  .dcache_dirty_gwen(dcache_dirty_gwen),
  .dcache_dirty_wen(dcache_dirty_wen),
  .dcache_idx(dcache_idx),
  .dcache_tag_din(dcache_tag_din),
  .dcache_tag_gwen(dcache_tag_gwen),
  .dcache_tag_wen(dcache_tag_wen),
  .forever_cpuclk(forever_cpuclk),
  .ld_da_lsid(ld_da_lsid),
  .ld_da_sq_data_discard_vld(ld_da_sq_data_discard_vld),
  .ld_da_sq_fwd_id(ld_da_sq_fwd_id),
  .ld_da_sq_fwd_multi_vld(ld_da_sq_fwd_multi_vld),
  .ld_da_sq_global_discard_vld(ld_da_sq_global_discard_vld),
  .ld_dc_addr0(ld_dc_addr0),
  .ld_dc_addr1_11to4(ld_dc_addr1_11to4),
  .ld_dc_bytes_vld(ld_dc_bytes_vld),
  .ld_dc_bytes_vld1(ld_dc_bytes_vld1),
  .ld_dc_chk_ld_addr1_vld(ld_dc_chk_ld_addr1_vld),
  .ld_dc_chk_ld_bypass_vld(ld_dc_chk_ld_bypass_vld),
  .ld_dc_chk_ld_inst_vld(ld_dc_chk_ld_inst_vld),
  .ld_dc_iid(ld_dc_iid),
  .rb_sq_pop_hit_idx(rb_sq_pop_hit_idx),
  .rtu_lsu_async_flush(rtu_lsu_async_flush),
  .rtu_yy_xx_commit0(rtu_yy_xx_commit0),
  .rtu_yy_xx_commit0_iid(rtu_yy_xx_commit0_iid),
  .rtu_yy_xx_commit1(rtu_yy_xx_commit1),
  .rtu_yy_xx_commit1_iid(rtu_yy_xx_commit1_iid),
  .rtu_yy_xx_commit2(rtu_yy_xx_commit2),
  .rtu_yy_xx_commit2_iid(rtu_yy_xx_commit2_iid),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .idu_lsu_rf_pipe5_src0(idu_lsu_rf_pipe5_src0),  // in
  .idu_lsu_sdiq_sel(idu_lsu_sdiq_sel),  // in
  .idu_lsu_rf_pipe5_sdiq_entry(idu_lsu_rf_pipe5_sdiq_entry),  //in
  .st_da_iid(st_da_iid),
  .st_da_inst_vld(st_da_inst_vld),
  .st_da_secd(st_da_secd),
  .st_da_sq_dcache_dirty(st_da_sq_dcache_dirty),
  .st_da_sq_dcache_valid(st_da_sq_dcache_valid),
  .st_da_sq_dcache_way(st_da_sq_dcache_way),
  .st_da_sq_no_restart(st_da_sq_no_restart),
  .st_dc_addr0(st_dc_addr0),
  .st_dc_boundary(st_dc_boundary),
  .st_dc_boundary_first(st_dc_boundary_first),
  .st_dc_bytes_vld(st_dc_bytes_vld),
  .st_dc_iid(st_dc_iid),
  .st_dc_old(st_dc_old),
  .st_dc_rot_sel_rev(st_dc_rot_sel_rev),
  .st_dc_sdid(st_dc_sdid_oh),
  .st_dc_secd(st_dc_secd),
  .st_dc_sq_create_vld(st_dc_sq_create_vld),
  .st_dc_sq_data_vld(st_dc_sq_data_vld),
  .wmb_ce_addr(wmb_ce_addr),
  .wmb_ce_sq_ptr(wmb_ce_sq_ptr),
  .wmb_sq_pop_grnt(wmb_sq_pop_grnt),
  .wmb_sq_pop_to_ce_grnt(wmb_sq_pop_to_ce_grnt),  
  .sq_data_depd_wakeup(sq_data_depd_wakeup),  // out
  .sq_global_depd_wakeup(sq_global_depd_wakeup),  // out
  .sq_ld_da_fwd_data(sq_ld_da_fwd_data),
  .sq_ld_dc_addr1_dep_discard(sq_ld_dc_addr1_dep_discard),
  .sq_ld_dc_cancel_acc_req(sq_ld_dc_cancel_acc_req),
  .sq_ld_dc_data_discard_req(sq_ld_dc_data_discard_req),
  .sq_ld_dc_fwd_id(sq_ld_dc_fwd_id),  
  .sq_ld_dc_fwd_multi(sq_ld_dc_fwd_multi),
  .sq_ld_dc_fwd_multi_mask(sq_ld_dc_fwd_multi_mask),
  .sq_ld_dc_fwd_req(sq_ld_dc_fwd_req),
  .sq_ld_dc_other_discard_req(sq_ld_dc_other_discard_req),
  .sq_pop_addr(sq_pop_addr),
  .sq_pop_bytes_vld(sq_pop_bytes_vld),
  .sq_pop_ptr(sq_pop_ptr),
  .sq_st_dc_full(sq_st_dc_full),
  .sq_st_dc_inst_hit(sq_st_dc_inst_hit),
  .sq_wmb_merge_stall_req(sq_wmb_merge_stall_req),
  .sq_wmb_pop_to_ce_req(sq_wmb_pop_to_ce_req),
  .wmb_ce_data128(sq_pop_data),
  .wmb_ce_update_dcache_dirty(wmb_ce_update_dcache_dirty),  
  .wmb_ce_update_dcache_valid(wmb_ce_update_dcache_valid),  
  .wmb_ce_update_dcache_way(wmb_ce_update_dcache_way),
  .lsu_idu_sq_not_full(lsu_idu_sq_not_full)  
);

//----------------------------------------------------------
// Load Queue
//----------------------------------------------------------
ct_lsu_lq u_lsu_lq (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .ld_dc_addr0(ld_dc_addr0),
  .ld_dc_bytes_vld(ld_dc_bytes_vld),
  .ld_dc_bytes_vld1(ld_dc_bytes_vld1),
  .ld_dc_iid(ld_dc_iid),
  .ld_dc_lq_create1_vld(ld_dc_lq_create1_vld),
  .ld_dc_lq_create_vld(ld_dc_lq_create_vld),
  .ld_dc_secd(ld_dc_secd),
  .rtu_yy_xx_commit0(rtu_yy_xx_commit0),
  .rtu_yy_xx_commit0_iid(rtu_yy_xx_commit0_iid),
  .rtu_yy_xx_commit1(rtu_yy_xx_commit1),
  .rtu_yy_xx_commit1_iid(rtu_yy_xx_commit1_iid),
  .rtu_yy_xx_commit2(rtu_yy_xx_commit2),
  .rtu_yy_xx_commit2_iid(rtu_yy_xx_commit2_iid),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .st_dc_addr0(st_dc_addr0),
  .st_dc_bytes_vld(st_dc_bytes_vld),
  .st_dc_chk_st_inst_vld(st_dc_chk_st_inst_vld),
  .st_dc_iid(st_dc_iid),
  .lq_ld_dc_full(lq_ld_dc_full),
  .lq_ld_dc_inst_hit(lq_ld_dc_inst_hit),
  .lq_ld_dc_less2(lq_ld_dc_less2),
  .lq_st_dc_spec_fail(lq_st_dc_spec_fail),
  .lsu_idu_lq_not_full(lsu_idu_lq_not_full)  // out
);

//----------------------------------------------------------
// WMB Create Entry (CE)
//----------------------------------------------------------
logic [WMB_ENTRY-1:0] wmb_entry_vld;

lsu_wmb_ce #(
  .PA_WIDTH(32),
  .SQ_ENTRY(SQ_ENTRY),
  .WMB_ENTRY(WMB_ENTRY)
) u_lsu_wmb_ce (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .rtu_lsu_async_flush(rtu_lsu_async_flush),
  .sq_wmb_merge_stall_req(sq_wmb_merge_stall_req),
  .sq_pop_addr(sq_pop_addr),
  .sq_pop_bytes_vld(sq_pop_bytes_vld),
  .sq_pop_ptr(sq_pop_ptr),
  .wmb_ce_create_vld(wmb_ce_create_vld),
  .wmb_ce_create_merge(wmb_ce_create_merge),
  .wmb_ce_create_merge_ptr(wmb_ce_create_merge_ptr),
  .wmb_ce_create_stall(wmb_ce_create_stall),
  .wmb_ce_dcache_dirty(st_da_dcache_dirty),
  .wmb_ce_dcache_valid(st_da_dcache_valid),
  .wmb_ce_pop_vld(wmb_ce_pop_vld),
  .wmb_entry_vld(wmb_entry_vld),
  .rb_wmb_ce_hit_idx(rb_wmb_ce_hit_idx),
  .wmb_ce_addr(wmb_ce_addr),
  .wmb_ce_bytes_vld(wmb_ce_bytes_vld),
  .wmb_ce_create_wmb_data_req(wmb_ce_create_wmb_data_req),
  .wmb_ce_create_wmb_req(wmb_ce_create_wmb_req),
  .wmb_ce_data_vld(wmb_ce_data_vld),
  .wmb_ce_merge_data_addr_hit(wmb_ce_merge_data_addr_hit),
  .wmb_ce_merge_data_stall(wmb_ce_merge_data_stall),
  .wmb_ce_merge_en(wmb_ce_merge_en),
  .wmb_ce_merge_ptr(wmb_ce_merge_ptr),
  .wmb_ce_merge_wmb_req(wmb_ce_merge_wmb_req),
  .wmb_ce_merge_wmb_wait_not_vld_req(),
  .wmb_ce_same_dcache_line(wmb_ce_same_dcache_line),
  .wmb_ce_sq_ptr(wmb_ce_sq_ptr),
  .wmb_ce_vld(wmb_ce_vld),
  .wmb_ce_write_biu_req(wmb_ce_write_biu_req),
  .wmb_ce_write_dcache_req(wmb_ce_write_dcache_req)
);

// CE data comes from SQ
assign wmb_ce_data128 = sq_pop_data;

//----------------------------------------------------------
// Write Merge Buffer
//----------------------------------------------------------
logic wmb_dcache_arb_st_dirty_gateclk_en;
logic [7:0] wmb_dcache_arb_ld_data_gateclk_en;
lsu_wmb #(
  .PA_WIDTH(32),
  .WMB_ENTRY(WMB_ENTRY),
  .SQ_ENTRY(SQ_ENTRY),
  .LSIQ_ENTRY(LSIQ_ENTRY),
  .DCACHE_SIZE(DCACHE_SIZE)
) u_lsu_wmb (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .sq_pop_addr(sq_pop_addr),
  .sq_pop_data(sq_pop_data),
  .sq_pop_bytes_vld(sq_pop_bytes_vld),
  .sq_pop_ptr(sq_pop_ptr),
  .sq_wmb_merge_req(sq_wmb_merge_req),
  .sq_wmb_merge_stall_req(sq_wmb_merge_stall_req),
  .sq_wmb_pop_to_ce_req(sq_wmb_pop_to_ce_req),
  .st_da_dcache_hit(st_da_dcache_hit),
  .st_da_dcache_way(st_da_dcache_way),
  .st_da_dcache_dirty(st_da_dcache_dirty),
  .st_da_dcache_valid(st_da_dcache_valid),

  // ---- 补：Dcache 写端口监测 ----
  .dcache_dirty_din(dcache_dirty_din),
  .dcache_dirty_gwen(dcache_dirty_gwen),
  .dcache_dirty_wen(dcache_dirty_wen),
  .dcache_idx(dcache_idx),
  .dcache_tag_din(dcache_tag_din),
  .dcache_tag_gwen(dcache_tag_gwen),
  .dcache_tag_wen(dcache_tag_wen),

  // ---- 补：RB(MSHR) 请求地址 ----
  .rb_biu_req_addr(rb_biu_req_addr),

  .bus_arb_wmb_aw_grnt(bus_arb_wmb_aw_grnt),
  .bus_arb_wmb_w_grnt(bus_arb_wmb_w_grnt),
  .biu_lsu_b_id(biu_lsu_b_id),
  .biu_lsu_b_resp(biu_lsu_b_resp),
  .biu_lsu_b_vld(biu_lsu_b_vld),
  .dcache_arb_wmb_ld_grnt(dcache_arb_wmb_ld_grnt),
  .ld_dc_addr0(ld_dc_addr0),
  .ld_dc_addr1_11to4(ld_dc_addr1_11to4),
  .ld_dc_bytes_vld(ld_dc_bytes_vld),
  .ld_dc_chk_ld_inst_vld(ld_dc_chk_ld_inst_vld),
  .lfb_vb_addr_tto5(lfb_vb_addr_tto5),
  .lfb_vb_create_vld(lfb_vb_create_vld),
  .vb_biu_aw_addr(vb_biu_aw_addr),
  .vb_biu_aw_req(vb_biu_aw_req),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .wmb_sq_pop_grnt(wmb_sq_pop_grnt),

  // CE interface - 输入
  .wmb_ce_addr(wmb_ce_addr),
  .wmb_ce_data128(wmb_ce_data128),
  .wmb_ce_bytes_vld(wmb_ce_bytes_vld),
  .wmb_ce_data_vld(wmb_ce_data_vld),
  .wmb_ce_sq_ptr(wmb_ce_sq_ptr),
  .wmb_ce_merge(wmb_ce_merge),
  .wmb_ce_merge_ptr(wmb_ce_merge_ptr),
  .wmb_ce_same_dcache_line(wmb_ce_same_dcache_line),
  .wmb_ce_merge_en(wmb_ce_merge_en),

  // ---- 补：CE 更新 dcache 状态 ----
  .wmb_ce_update_dcache_valid(wmb_ce_update_dcache_valid),
  .wmb_ce_update_dcache_dirty(wmb_ce_update_dcache_dirty),
  .wmb_ce_update_dcache_way(wmb_ce_update_dcache_way),

  .wmb_ce_write_biu_req(wmb_ce_write_biu_req),
  .wmb_ce_write_dcache_req(wmb_ce_write_dcache_req),
  .wmb_ce_merge_data_addr_hit(wmb_ce_merge_data_addr_hit),
  .wmb_ce_merge_data_stall(wmb_ce_merge_data_stall),
  .wmb_ce_merge_wmb_req(wmb_ce_merge_wmb_req),
  .wmb_ce_create_wmb_req(wmb_ce_create_wmb_req),
  .wmb_ce_create_wmb_data_req(wmb_ce_create_wmb_data_req),
  .wmb_ce_vld(wmb_ce_vld),

  // CE interface - 输出
  .wmb_ce_pop_vld(wmb_ce_pop_vld),
  .wmb_ce_create_vld(wmb_ce_create_vld),
  .wmb_ce_create_merge(wmb_ce_create_merge),
  .wmb_ce_create_merge_ptr(wmb_ce_create_merge_ptr),

  // ---- 补：CE 输出 ----
  // ⚠️ 这里原来还有一行 .wmb_ce_create_same_dcache_line(...) —— 删掉了:
  //    lsu_wmb 没有这个端口(它的口叫 wmb_ce_same_dcache_line, 且是**输入**,
  //    不是 CE 输出), 而那个 net 全文件只出现在这一行、从未声明。
  //    同名概念的正确连接在上面 .wmb_ce_same_dcache_line(wmb_ce_same_dcache_line)。
  .wmb_ce_create_stall(wmb_ce_create_stall),
  .wmb_entry_vld(wmb_entry_vld),

  // BIU interface
  .wmb_biu_aw_addr(wmb_biu_aw_addr),
  .wmb_biu_aw_bar(wmb_biu_aw_bar),
  .wmb_biu_aw_burst(wmb_biu_aw_burst),
  .wmb_biu_aw_cache(wmb_biu_aw_cache),
  .wmb_biu_aw_domain(wmb_biu_aw_domain),
  .wmb_biu_aw_id(wmb_biu_aw_id),
  .wmb_biu_aw_len(wmb_biu_aw_len),
  .wmb_biu_aw_lock(wmb_biu_aw_lock),
  .wmb_biu_aw_prot(wmb_biu_aw_prot),
  .wmb_biu_aw_req(wmb_biu_aw_req),
  .wmb_biu_aw_size(wmb_biu_aw_size),
  .wmb_biu_aw_snoop(wmb_biu_aw_snoop),
  .wmb_biu_aw_user(wmb_biu_aw_user),
  .wmb_biu_w_data(wmb_biu_w_data),
  .wmb_biu_w_id(wmb_biu_w_id),
  .wmb_biu_w_req(wmb_biu_w_req),
  .wmb_biu_w_strb(wmb_biu_w_strb),
  .wmb_biu_w_vld(wmb_biu_w_vld),

  // Dcache interface
  .wmb_dcache_arb_req(wmb_dcache_arb_req),
  .wmb_dcache_arb_ld_data_high_din(wmb_dcache_arb_ld_data_high_din),
  .wmb_dcache_arb_ld_data_low_din(wmb_dcache_arb_ld_data_low_din),
  .wmb_dcache_arb_ld_data_idx(wmb_dcache_arb_ld_data_idx),
  .wmb_dcache_arb_ld_data_req(wmb_dcache_arb_ld_data_req),
  .wmb_dcache_arb_ld_data_wen(wmb_dcache_arb_ld_data_wen),
  .wmb_dcache_arb_ld_data_gateclk_en(wmb_dcache_arb_ld_data_gateclk_en),
  .wmb_dcache_arb_st_dirty_din(wmb_dcache_arb_st_dirty_din),
  .wmb_dcache_arb_st_dirty_idx(wmb_dcache_arb_st_dirty_idx),
  .wmb_dcache_arb_st_dirty_req(wmb_dcache_arb_st_dirty_req),
  .wmb_dcache_arb_st_dirty_gateclk_en(wmb_dcache_arb_st_dirty_gateclk_en),
  .wmb_dcache_arb_st_dirty_wen(wmb_dcache_arb_st_dirty_wen),

  // LD interface
  .wmb_ld_da_fwd_data(wmb_ld_da_fwd_data),
  .wmb_ld_dc_fwd_req(wmb_ld_dc_fwd_req),
  .wmb_ld_dc_discard_req(wmb_ld_dc_discard_req),
  .wmb_depd_wakeup(wmb_depd_wakeup),
  .wmb_sq_pop_to_ce_grnt(wmb_sq_pop_to_ce_grnt),
  .wmb_rb_biu_req_hit_idx(wmb_rb_biu_req_hit_idx)
);

//----------------------------------------------------------
// Line Fill Buffer
//----------------------------------------------------------
ct_lsu_lfb #(
  .LSIQ_ENTRY(LSIQ_ENTRY),
  .LFB_ADDR_ENTRY(LFB_ADDR_ENTRY),
  .LFB_DATA_ENTRY(LFB_DATA_ENTRY),
  .BIU_LFB_ID_T(2'b00),
  .OKAY(2'b00),
  .EXOKAY(2'b01),
  .SLVERR(2'b10),
  .DECERR(2'b11),
  .DCACHE_SIZE(DCACHE_SIZE)
) u_lsu_lfb (
  .biu_lsu_r_data(biu_lsu_r_data),
  .biu_lsu_r_id(biu_lsu_r_id),
  .biu_lsu_r_last(biu_lsu_r_last),
  .biu_lsu_r_resp(biu_lsu_r_resp),
  .biu_lsu_r_vld(biu_lsu_r_vld),
  .bus_arb_rb_ar_sel(bus_arb_rb_ar_sel),
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .dcache_arb_lfb_ld_grnt(dcache_arb_lfb_ld_grnt),
  .ld_da_idx(ld_da_idx),
  .ld_da_lfb_discard_grnt(ld_da_lfb_discard_grnt),
  .ld_da_lfb_set_wakeup_queue(ld_da_lfb_set_wakeup_queue),
  .ld_da_lfb_wakeup_queue_next(ld_da_lfb_wakeup_queue_next),
  .rb_biu_req_addr(rb_biu_req_addr),
  .rb_lfb_addr_tto4(rb_lfb_addr_tto4),
  .rb_lfb_boundary_depd_wakeup(rb_lfb_boundary_depd_wakeup),
  .rb_lfb_create_req(rb_lfb_create_req),
  .rb_lfb_create_vld(rb_lfb_create_vld),
  .rb_lfb_depd(rb_lfb_depd),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .st_da_addr(st_da_addr),
  .vb_lfb_addr_entry_rcl_done(vb_lfb_addr_entry_rcl_done),
  .vb_lfb_create_grnt(vb_lfb_create_grnt),
  .vb_lfb_dcache_hit(vb_lfb_dcache_hit),
  .vb_lfb_dcache_way(vb_lfb_dcache_way),
  .vb_lfb_rcl_done(vb_lfb_rcl_done),
  .vb_lfb_vb_req_hit_idx(vb_lfb_vb_req_hit_idx),
  .wmb_write_req_addr(wmb_write_req_addr),
  .lfb_dcache_arb_ld_data_gateclk_en(lfb_dcache_arb_ld_data_gateclk_en),
  .lfb_dcache_arb_ld_data_high_din(lfb_dcache_arb_ld_data_high_din),
  .lfb_dcache_arb_ld_data_idx(lfb_dcache_arb_ld_data_idx),
  .lfb_dcache_arb_ld_data_low_din(lfb_dcache_arb_ld_data_low_din),
  .lfb_dcache_arb_ld_req(lfb_dcache_arb_ld_req),
  .lfb_dcache_arb_ld_tag_din(lfb_dcache_arb_ld_tag_din),
  .lfb_dcache_arb_ld_tag_gateclk_en(lfb_dcache_arb_ld_tag_gateclk_en),
  .lfb_dcache_arb_ld_tag_idx(lfb_dcache_arb_ld_tag_idx),
  .lfb_dcache_arb_ld_tag_req(lfb_dcache_arb_ld_tag_req),
  .lfb_dcache_arb_ld_tag_wen(lfb_dcache_arb_ld_tag_wen),
  .lfb_dcache_arb_st_tag_req(lfb_dcache_arb_st_tag_req),
  .lfb_dcache_arb_st_tag_gateclk_en(lfb_dcache_arb_st_tag_gateclk_en),
  .lfb_dcache_arb_st_tag_idx(lfb_dcache_arb_st_tag_idx),
  .lfb_dcache_arb_st_tag_din(lfb_dcache_arb_st_tag_din),
  .lfb_dcache_arb_st_tag_wen(lfb_dcache_arb_st_tag_wen),
  .lfb_dcache_arb_st_dirty_req(lfb_dcache_arb_st_dirty_req),
  .lfb_dcache_arb_st_dirty_gateclk_en(lfb_dcache_arb_st_dirty_gateclk_en),
  .lfb_dcache_arb_st_dirty_idx(lfb_dcache_arb_st_dirty_idx),
  .lfb_dcache_arb_st_dirty_din(lfb_dcache_arb_st_dirty_din),
  .lfb_dcache_arb_st_dirty_wen(lfb_dcache_arb_st_dirty_wen),
  .lfb_depd_wakeup(lfb_depd_wakeup),
  .lfb_ld_da_hit_idx(lfb_ld_da_hit_idx),
  .lfb_pop_depd_ff(lfb_pop_depd_ff),
  .lfb_rb_biu_req_hit_idx(lfb_rb_biu_req_hit_idx),
  .lfb_rb_ca_rready_grnt(lfb_rb_ca_rready_grnt),
  .lfb_rb_create_id(lfb_rb_create_id),
  .lfb_st_da_hit_idx(lfb_st_da_hit_idx),
  .lfb_vb_addr_tto5(lfb_vb_addr_tto5),
  .lfb_vb_create_vld(lfb_vb_create_vld),
  .lfb_vb_id(lfb_vb_id),
  .lfb_wmb_read_req_hit_idx(lfb_wmb_read_req_hit_idx),
  .lfb_wmb_write_req_hit_idx(lfb_wmb_write_req_hit_idx),
  .lfb_addr_full(lfb_addr_full)
);

//----------------------------------------------------------
// Victim Buffer
//----------------------------------------------------------
ct_lsu_vb #(
  .BIU_VB_ID_T(2'b00),
  .DCACHE_SIZE(DCACHE_SIZE)
) u_lsu_vb (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .lfb_vb_addr_tto5(lfb_vb_addr_tto5),
  .lfb_vb_create_vld(lfb_vb_create_vld),
  .lfb_vb_id(lfb_vb_id),
  .rb_biu_req_addr(rb_biu_req_addr),
  .vb_rb_biu_req_hit_idx(vb_rb_biu_req_hit_idx),
  .bus_arb_vb_aw_grnt(bus_arb_vb_aw_grnt),
  .bus_arb_vb_w_grnt(bus_arb_vb_w_grnt),
  .biu_lsu_b_id(biu_lsu_b_id),
  .biu_lsu_b_vld(biu_lsu_b_vld),
  .dcache_arb_vb_ld_grnt(dcache_arb_vb_ld_grnt),
  .dcache_arb_vb_st_grnt(dcache_arb_vb_st_grnt),
  .ld_da_data256(ld_da_data256),
  .ld_da_vb_borrow_vb(ld_da_vb_borrow_vb),
  .st_da_dcache_hit(st_da_dcache_hit),
  .st_da_dcache_way(st_da_dcache_way),
  .st_da_dcache_replace_valid(st_da_dcache_replace_valid),
  .st_da_dcache_replace_dirty(st_da_dcache_replace_dirty),
  .st_da_vb_feedback_addr_tto10(st_da_vb_feedback_addr_tto10),
  .vb_lfb_create_grnt(vb_lfb_create_grnt),
  .vb_lfb_vb_req_hit_idx(vb_lfb_vb_req_hit_idx),
  .vb_lfb_addr_entry_rcl_done(vb_lfb_addr_entry_rcl_done),
  .vb_lfb_dcache_hit(vb_lfb_dcache_hit),
  .vb_lfb_dcache_way(vb_lfb_dcache_way),
  .vb_lfb_rcl_done(vb_lfb_rcl_done),
  .vb_biu_aw_addr(vb_biu_aw_addr),
  .vb_biu_aw_burst(vb_biu_aw_burst),
  .vb_biu_aw_cache(vb_biu_aw_cache),
  .vb_biu_aw_id(vb_biu_aw_id),
  .vb_biu_aw_len(vb_biu_aw_len),
  .vb_biu_aw_lock(vb_biu_aw_lock),
  .vb_biu_aw_prot(vb_biu_aw_prot),
  .vb_biu_aw_req(vb_biu_aw_req),
  .vb_biu_aw_size(vb_biu_aw_size),
  .vb_biu_w_data(vb_biu_w_data),
  .vb_biu_w_id(vb_biu_w_id),
  .vb_biu_w_last(vb_biu_w_last),
  .vb_biu_w_req(vb_biu_w_req),
  .vb_biu_w_strb(vb_biu_w_strb),
  .vb_biu_w_vld(vb_biu_w_vld),
  .vb_dcache_arb_ld_borrow_req(vb_dcache_arb_ld_borrow_req),
  .vb_dcache_arb_data_way(vb_dcache_arb_data_way),
  .vb_dcache_arb_st_borrow_req(vb_dcache_arb_st_borrow_req),
  .vb_dcache_arb_borrow_addr(vb_dcache_arb_borrow_addr),
  .vb_dcache_arb_ld_tag_din(vb_dcache_arb_ld_tag_din),
  .vb_dcache_arb_ld_tag_idx(vb_dcache_arb_ld_tag_idx),
  .vb_dcache_arb_ld_tag_req(vb_dcache_arb_ld_tag_req),
  .vb_dcache_arb_ld_tag_gateclk_en(vb_dcache_arb_ld_tag_gateclk_en),
  .vb_dcache_arb_ld_tag_wen(vb_dcache_arb_ld_tag_wen),
  .vb_dcache_arb_st_tag_idx(vb_dcache_arb_st_tag_idx),
  .vb_dcache_arb_st_tag_req(vb_dcache_arb_st_tag_req),
  .vb_dcache_arb_st_tag_gateclk_en(vb_dcache_arb_st_tag_gateclk_en),
  .vb_dcache_arb_st_dirty_req(vb_dcache_arb_st_dirty_req),
  .vb_dcache_arb_st_dirty_gateclk_en(vb_dcache_arb_st_dirty_gateclk_en),
  .vb_dcache_arb_st_dirty_idx(vb_dcache_arb_st_dirty_idx),
  .vb_dcache_arb_st_dirty_din(vb_dcache_arb_st_dirty_din),
  .vb_dcache_arb_st_dirty_gwen(vb_dcache_arb_st_dirty_gwen),
  .vb_dcache_arb_st_dirty_wen(vb_dcache_arb_st_dirty_wen),
  .vb_dcache_arb_ld_data_gateclk_en(vb_dcache_arb_ld_data_gateclk_en),
  .vb_dcache_arb_ld_data_idx(vb_dcache_arb_ld_data_idx)
);

//----------------------------------------------------------
// DCache Arbiter
//----------------------------------------------------------
ct_lsu_dcache_arb #(
  .DCACHE_SIZE(DCACHE_SIZE)
) u_dcache_arb (
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .ag_dcache_arb_ld_tag_req(ag_dcache_arb_ld_tag_req),
  .ag_dcache_arb_ld_tag_gateclk_en(ag_dcache_arb_ld_tag_gateclk_en),
  .ag_dcache_arb_ld_tag_idx(ag_dcache_arb_ld_tag_idx),
  .ag_dcache_arb_ld_data_req(ag_dcache_arb_ld_data_req),
  .ag_dcache_arb_ld_data_gateclk_en(ag_dcache_arb_ld_data_gateclk_en),
  .ag_dcache_arb_ld_data_low_idx(ag_dcache_arb_ld_data_low_idx),
  .ag_dcache_arb_ld_data_high_idx(ag_dcache_arb_ld_data_high_idx),
  .ag_dcache_arb_st_tag_req(ag_dcache_arb_st_tag_req),
  .ag_dcache_arb_st_tag_gateclk_en(ag_dcache_arb_st_tag_gateclk_en),
  .ag_dcache_arb_st_tag_idx(ag_dcache_arb_st_tag_idx),
  .ag_dcache_arb_st_dirty_req(ag_dcache_arb_st_dirty_req),
  .ag_dcache_arb_st_dirty_gateclk_en(ag_dcache_arb_st_dirty_gateclk_en),
  .ag_dcache_arb_st_dirty_idx(ag_dcache_arb_st_dirty_idx),
  .dcache_arb_ag_ld_sel(dcache_arb_ag_ld_sel),
  .dcache_arb_ag_st_sel(dcache_arb_ag_st_sel),
  .dcache_arb_ld_ag_addr(dcache_arb_ld_ag_addr),
  .dcache_arb_ld_ag_borrow_addr_vld(dcache_arb_ld_ag_borrow_addr_vld),
  .dcache_arb_st_ag_addr(dcache_arb_st_ag_addr),
  .dcache_arb_st_ag_borrow_addr_vld(dcache_arb_st_ag_borrow_addr_vld),
  .wmb_dcache_arb_ld_req(wmb_dcache_arb_req),
  .wmb_dcache_arb_ld_data_gateclk_en(wmb_dcache_arb_ld_data_gateclk_en),  // WMB uses combined idx, needs conversion
  .wmb_dcache_arb_ld_data_low_idx(wmb_dcache_arb_ld_data_idx),
  .wmb_dcache_arb_ld_data_high_idx(wmb_dcache_arb_ld_data_idx),
  .wmb_dcache_arb_ld_data_low_din(wmb_dcache_arb_ld_data_low_din),
  .wmb_dcache_arb_ld_data_high_din(wmb_dcache_arb_ld_data_high_din),
  .wmb_dcache_arb_ld_data_wen(wmb_dcache_arb_ld_data_wen),
  .wmb_dcache_arb_st_req(wmb_dcache_arb_req),
  .wmb_dcache_arb_st_dirty_din(wmb_dcache_arb_st_dirty_din),
  .wmb_dcache_arb_st_dirty_req(wmb_dcache_arb_st_dirty_req),
  .wmb_dcache_arb_st_dirty_gateclk_en(wmb_dcache_arb_st_dirty_gateclk_en),
  .wmb_dcache_arb_st_dirty_idx(wmb_dcache_arb_st_dirty_idx),
  .wmb_dcache_arb_st_dirty_wen(wmb_dcache_arb_st_dirty_wen),
  .dcache_arb_wmb_ld_grnt(dcache_arb_wmb_ld_grnt),
  .lfb_dcache_arb_ld_req(lfb_dcache_arb_ld_req),
  .lfb_dcache_arb_ld_data_gateclk_en(lfb_dcache_arb_ld_data_gateclk_en),
  .lfb_dcache_arb_ld_data_idx(lfb_dcache_arb_ld_data_idx),
  .lfb_dcache_arb_ld_data_low_din(lfb_dcache_arb_ld_data_low_din),
  .lfb_dcache_arb_ld_data_high_din(lfb_dcache_arb_ld_data_high_din),
  .lfb_dcache_arb_ld_tag_din(lfb_dcache_arb_ld_tag_din),
  .lfb_dcache_arb_ld_tag_req(lfb_dcache_arb_ld_tag_req),
  .lfb_dcache_arb_ld_tag_gateclk_en(lfb_dcache_arb_ld_tag_gateclk_en),
  .lfb_dcache_arb_ld_tag_idx(lfb_dcache_arb_ld_tag_idx),
  .lfb_dcache_arb_ld_tag_wen(lfb_dcache_arb_ld_tag_wen),
  .lfb_dcache_arb_st_req(lfb_dcache_arb_st_tag_req),
  .lfb_dcache_arb_st_tag_din(lfb_dcache_arb_st_tag_din),
  .lfb_dcache_arb_st_tag_req(lfb_dcache_arb_st_tag_req),
  .lfb_dcache_arb_st_tag_gateclk_en(lfb_dcache_arb_st_tag_gateclk_en),
  .lfb_dcache_arb_st_tag_idx(lfb_dcache_arb_st_tag_idx),
  .lfb_dcache_arb_st_tag_wen(lfb_dcache_arb_st_tag_wen),
  .lfb_dcache_arb_st_dirty_din(lfb_dcache_arb_st_dirty_din),
  .lfb_dcache_arb_st_dirty_req(lfb_dcache_arb_st_dirty_req),
  .lfb_dcache_arb_st_dirty_gateclk_en(lfb_dcache_arb_st_dirty_gateclk_en),
  .lfb_dcache_arb_st_dirty_idx(lfb_dcache_arb_st_dirty_idx),
  .lfb_dcache_arb_st_dirty_wen( lfb_dcache_arb_st_dirty_wen),
  .dcache_arb_lfb_ld_grnt(dcache_arb_lfb_ld_grnt),
  .vb_dcache_arb_ld_req(vb_dcache_arb_ld_borrow_req),
  .vb_dcache_arb_ld_borrow_req(vb_dcache_arb_ld_borrow_req),
  .vb_dcache_arb_data_way(vb_dcache_arb_data_way),
  .vb_dcache_arb_ld_data_gateclk_en(vb_dcache_arb_ld_data_gateclk_en),
  .vb_dcache_arb_ld_data_idx(vb_dcache_arb_ld_data_idx),
  .vb_dcache_arb_ld_tag_din(vb_dcache_arb_ld_tag_din),
  .vb_dcache_arb_ld_tag_req(vb_dcache_arb_ld_tag_req),
  .vb_dcache_arb_ld_tag_gateclk_en(vb_dcache_arb_ld_tag_gateclk_en),
  .vb_dcache_arb_ld_tag_idx(vb_dcache_arb_ld_tag_idx),
  .vb_dcache_arb_ld_tag_wen(vb_dcache_arb_ld_tag_wen),
  .vb_dcache_arb_st_req(vb_dcache_arb_st_borrow_req),
  .vb_dcache_arb_st_borrow_req(vb_dcache_arb_st_borrow_req),
  .vb_dcache_arb_st_tag_req(vb_dcache_arb_st_tag_req),
  .vb_dcache_arb_st_tag_gateclk_en(vb_dcache_arb_st_tag_gateclk_en),
  .vb_dcache_arb_st_tag_idx(vb_dcache_arb_st_tag_idx),
  .vb_dcache_arb_st_dirty_din(vb_dcache_arb_st_dirty_din),
  .vb_dcache_arb_st_dirty_req(vb_dcache_arb_st_dirty_req),
  .vb_dcache_arb_st_dirty_gateclk_en(vb_dcache_arb_st_dirty_gateclk_en),
  .vb_dcache_arb_st_dirty_idx(vb_dcache_arb_st_dirty_idx),
  .vb_dcache_arb_st_dirty_gwen(vb_dcache_arb_st_dirty_gwen),
  .vb_dcache_arb_st_dirty_wen(vb_dcache_arb_st_dirty_wen),
  .vb_dcache_arb_borrow_addr(vb_dcache_arb_borrow_addr),
  .dcache_arb_vb_ld_grnt(dcache_arb_vb_ld_grnt),
  .dcache_arb_vb_st_grnt(dcache_arb_vb_st_grnt),
  .dcache_arb_ld_dc_borrow_vld(dcache_arb_ld_dc_borrow_vld),
  .dcache_arb_ld_dc_settle_way(dcache_arb_ld_dc_settle_way),
  .dcache_arb_st_dc_borrow_vld(dcache_arb_st_dc_borrow_vld),
  .lsu_dcache_ld_tag_sel_b(lsu_dcache_ld_tag_sel_b),
  .lsu_dcache_ld_tag_gwen_b(lsu_dcache_ld_tag_gwen_b),
  .lsu_dcache_ld_tag_wen_b(lsu_dcache_ld_tag_wen_b),
  .lsu_dcache_ld_tag_gateclk_en(lsu_dcache_ld_tag_gateclk_en),
  .lsu_dcache_ld_tag_idx(lsu_dcache_ld_tag_idx),
  .lsu_dcache_ld_tag_din(lsu_dcache_ld_tag_din),
  .lsu_dcache_st_tag_sel_b(lsu_dcache_st_tag_sel_b),
  .lsu_dcache_st_tag_gwen_b(lsu_dcache_st_tag_gwen_b),
  .lsu_dcache_st_tag_wen_b(lsu_dcache_st_tag_wen_b),
  .lsu_dcache_st_tag_gateclk_en(lsu_dcache_st_tag_gateclk_en),
  .lsu_dcache_st_tag_idx(lsu_dcache_st_tag_idx),
  .lsu_dcache_st_tag_din(lsu_dcache_st_tag_din),
  .lsu_dcache_st_dirty_sel_b(lsu_dcache_st_dirty_sel_b),
  .lsu_dcache_st_dirty_gwen_b(lsu_dcache_st_dirty_gwen_b),
  .lsu_dcache_st_dirty_wen_b(lsu_dcache_st_dirty_wen_b),
  .lsu_dcache_st_dirty_gateclk_en(lsu_dcache_st_dirty_gateclk_en),
  .lsu_dcache_st_dirty_idx(lsu_dcache_st_dirty_idx),
  .lsu_dcache_st_dirty_din(lsu_dcache_st_dirty_din),
  .lsu_dcache_ld_data_sel_b(lsu_dcache_ld_data_sel_b),
  .lsu_dcache_ld_data_gwen_b(lsu_dcache_ld_data_gwen_b),
  .lsu_dcache_ld_data_wen_b(lsu_dcache_ld_data_wen_b),
  .lsu_dcache_ld_data_gateclk_en(lsu_dcache_ld_data_gateclk_en),
  .lsu_dcache_ld_data_low_idx(lsu_dcache_ld_data_low_idx),
  .lsu_dcache_ld_data_high_idx(lsu_dcache_ld_data_high_idx),
  .lsu_dcache_ld_data_low_din(lsu_dcache_ld_data_low_din),
  .lsu_dcache_ld_data_high_din(lsu_dcache_ld_data_high_din),
  .dcache_idx(dcache_idx),
  .lsu_dcache_ld_xx_gwen(lsu_dcache_ld_xx_gwen),
  .dcache_tag_din(dcache_tag_din),
  .dcache_tag_gwen(dcache_tag_gwen),
  .dcache_tag_wen(dcache_tag_wen),
  .dcache_dirty_din(dcache_dirty_din),
  .dcache_dirty_gwen(dcache_dirty_gwen),
  .dcache_dirty_wen(dcache_dirty_wen)
);

//----------------------------------------------------------
// DCache Top (tag/dirty/data arrays)
//----------------------------------------------------------
ct_lsu_dcache_top #(
  .DCACHE_SIZE(DCACHE_SIZE)
) u_dcache_top (
  .cp0_lsu_icg_en(1'b1),
  .dcache_lsu_ld_data_bank0_dout(dcache_lsu_ld_data_bank0_dout),
  .dcache_lsu_ld_data_bank1_dout(dcache_lsu_ld_data_bank1_dout),
  .dcache_lsu_ld_data_bank2_dout(dcache_lsu_ld_data_bank2_dout),
  .dcache_lsu_ld_data_bank3_dout(dcache_lsu_ld_data_bank3_dout),
  .dcache_lsu_ld_data_bank4_dout(dcache_lsu_ld_data_bank4_dout),
  .dcache_lsu_ld_data_bank5_dout(dcache_lsu_ld_data_bank5_dout),
  .dcache_lsu_ld_data_bank6_dout(dcache_lsu_ld_data_bank6_dout),
  .dcache_lsu_ld_data_bank7_dout(dcache_lsu_ld_data_bank7_dout),
  .dcache_lsu_ld_tag_dout(dcache_lsu_ld_tag_dout),
  .dcache_lsu_st_dirty_dout(dcache_lsu_st_dirty_dout),
  .dcache_lsu_st_tag_dout(dcache_lsu_st_tag_dout),
  .forever_cpuclk(forever_cpuclk),
  .lsu_dcache_ld_data_gateclk_en(lsu_dcache_ld_data_gateclk_en),
  .lsu_dcache_ld_data_gwen_b(lsu_dcache_ld_data_gwen_b),
  .lsu_dcache_ld_data_high_din(lsu_dcache_ld_data_high_din),
  .lsu_dcache_ld_data_high_idx(lsu_dcache_ld_data_high_idx),
  .lsu_dcache_ld_data_low_din(lsu_dcache_ld_data_low_din),
  .lsu_dcache_ld_data_low_idx(lsu_dcache_ld_data_low_idx),
  .lsu_dcache_ld_data_sel_b(lsu_dcache_ld_data_sel_b),
  .lsu_dcache_ld_data_wen_b(lsu_dcache_ld_data_wen_b),
  .lsu_dcache_ld_tag_din(lsu_dcache_ld_tag_din),
  .lsu_dcache_ld_tag_gateclk_en(lsu_dcache_ld_tag_gateclk_en),
  .lsu_dcache_ld_tag_gwen_b(lsu_dcache_ld_tag_gwen_b),
  .lsu_dcache_ld_tag_idx(lsu_dcache_ld_tag_idx),
  .lsu_dcache_ld_tag_sel_b(lsu_dcache_ld_tag_sel_b),
  .lsu_dcache_ld_tag_wen_b(lsu_dcache_ld_tag_wen_b),
  .lsu_dcache_st_dirty_din(lsu_dcache_st_dirty_din),
  .lsu_dcache_st_dirty_gateclk_en(lsu_dcache_st_dirty_gateclk_en),
  .lsu_dcache_st_dirty_gwen_b(lsu_dcache_st_dirty_gwen_b),
  .lsu_dcache_st_dirty_idx(lsu_dcache_st_dirty_idx),
  .lsu_dcache_st_dirty_sel_b(lsu_dcache_st_dirty_sel_b),
  .lsu_dcache_st_dirty_wen_b(lsu_dcache_st_dirty_wen_b),
  .lsu_dcache_st_tag_din(lsu_dcache_st_tag_din),
  .lsu_dcache_st_tag_gateclk_en(lsu_dcache_st_tag_gateclk_en),
  .lsu_dcache_st_tag_gwen_b(lsu_dcache_st_tag_gwen_b),
  .lsu_dcache_st_tag_idx(lsu_dcache_st_tag_idx),
  .lsu_dcache_st_tag_sel_b(lsu_dcache_st_tag_sel_b),
  .lsu_dcache_st_tag_wen_b(lsu_dcache_st_tag_wen_b),
  .pad_yy_icg_scan_en(1'b0)
);

//----------------------------------------------------------
// MSHR (Read Buffer)
//----------------------------------------------------------
lsu_mshr #(
  .RB_ENTRY(4)
) u_lsu_mshr (
  .biu_lsu_r_data(biu_lsu_r_data),
  .biu_lsu_r_id(biu_lsu_r_id),
  .biu_lsu_r_resp(biu_lsu_r_resp),
  .biu_lsu_r_vld(biu_lsu_r_vld),
  .cpurst_b(cpurst_b),
  .forever_cpuclk(forever_cpuclk),
  .wmb_ce_addr(wmb_ce_addr),
  .bus_arb_rb_ar_grnt(bus_arb_rb_ar_grnt),  // in
  .ld_da_addr(ld_da_addr),
  .ld_da_boundary_after_mask(ld_da_boundary_after_mask),
  .ld_da_bytes_vld(ld_da_bytes_vld),
  .ld_da_data_ori(ld_da_wb_data),  
  .ld_da_data_rot_sel(ld_da_data_rot_sel),  
  .ld_da_idx(ld_da_idx),
  .ld_da_iid(ld_da_iid),
  .ld_da_inst_size(ld_da_inst_size),
  .ld_da_old(ld_da_old),
  .ld_da_preg(ld_da_preg),
  .ld_da_rb_cmit(ld_da_rb_cmit),
  .ld_da_rb_create_vld(ld_da_rb_create_vld),  
  .ld_da_rb_data_vld(ld_da_rb_data_vld),
  .ld_da_rb_discard_grnt(ld_da_rb_discard_grnt),
  .ld_da_rb_merge_vld(ld_da_rb_merge_vld),
  .ld_da_sign_extend(ld_da_sign_extend),
  .ld_wb_rb_cmplt_grnt(ld_wb_rb_cmplt_grnt),
  .ld_wb_rb_data_grnt(ld_wb_rb_data_grnt),
  .lfb_addr_full(lfb_addr_full), 
  .lfb_rb_biu_req_hit_idx(lfb_rb_biu_req_hit_idx), 
  .lfb_rb_ca_rready_grnt(lfb_rb_ca_rready_grnt),
  .lfb_rb_create_id(lfb_rb_create_id),  
  .rtu_yy_xx_commit0(rtu_yy_xx_commit0),
  .rtu_yy_xx_commit0_iid(rtu_yy_xx_commit0_iid),
  .rtu_yy_xx_commit1(rtu_yy_xx_commit1),
  .rtu_yy_xx_commit1_iid(rtu_yy_xx_commit1_iid),
  .rtu_yy_xx_commit2(rtu_yy_xx_commit2),
  .rtu_yy_xx_commit2_iid(rtu_yy_xx_commit2_iid),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .sq_pop_addr(sq_pop_addr), 
  .st_da_addr(st_da_addr),
  .st_da_bytes_vld(st_da_bytes_vld),
  .st_da_dcache_hit(st_da_dcache_hit),
  .st_da_iid(st_da_iid),
  .st_da_old(st_da_old),
  .st_da_rb_cmit(st_da_rb_cmit),
  .st_da_rb_create_vld(st_da_rb_create_vld),
  .vb_rb_biu_req_hit_idx(vb_rb_biu_req_hit_idx),  
  .wmb_rb_biu_req_hit_idx(wmb_rb_biu_req_hit_idx),  
  .rb_biu_ar_addr(rb_biu_ar_addr),
  .rb_biu_ar_id(rb_biu_ar_id),
  .rb_biu_ar_len(rb_biu_ar_len),
  .rb_biu_ar_size(rb_biu_ar_size),
  .rb_biu_ar_burst(rb_biu_ar_burst),
  .rb_biu_ar_lock(rb_biu_ar_lock),
  .rb_biu_ar_cache(rb_biu_ar_cache),
  .rb_biu_ar_prot(rb_biu_ar_prot),
  .rb_biu_ar_req(rb_biu_ar_req),
  .rb_ld_da_full(rb_ld_da_full),
  .rb_ld_da_hit_idx(rb_ld_da_hit_idx),
  .rb_ld_da_merge_fail(rb_ld_da_merge_fail),
  .rb_st_da_full(rb_st_da_full),
  .rb_st_da_hit_idx(rb_st_da_hit_idx),
  .rb_ld_wb_bus_err(rb_ld_wb_bus_err),
  .rb_ld_wb_bus_err_addr(rb_ld_wb_bus_err_addr),
  .rb_ld_wb_cmplt_req(rb_ld_wb_cmplt_req),
  .rb_ld_wb_data(rb_ld_wb_data),
  .rb_ld_wb_data_iid(rb_ld_wb_data_iid),
  .rb_ld_wb_data_req(rb_ld_wb_data_req),
  .rb_ld_wb_iid(rb_ld_wb_iid),
  .rb_ld_wb_preg(rb_ld_wb_preg),
  .rb_ld_wb_preg_sign_sel(rb_ld_wb_preg_sign_sel),
  .rb_lfb_addr_tto4(rb_lfb_addr_tto4),
  .rb_lfb_boundary_depd_wakeup(rb_lfb_boundary_depd_wakeup),
  .rb_lfb_create_req(rb_lfb_create_req),
  .rb_lfb_create_vld(rb_lfb_create_vld),
  .rb_lfb_depd(rb_lfb_depd),
  .rb_biu_req_addr(rb_biu_req_addr),
  .rb_sq_pop_hit_idx(rb_sq_pop_hit_idx),
  .lsu_idu_rb_not_full(lsu_idu_rb_not_full)
);



endmodule
