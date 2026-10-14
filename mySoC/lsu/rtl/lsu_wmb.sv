// Simplified WMB for RV32I
// - 32-bit address, 32-byte cacheline (2x128bit)
// - Removed: NC/SO FIFO, page attributes, snoop, icc, fence, sync, clock gating, had debug, st_wb, read ptr, atomic, ecc
// - Keep: basic write merge, dependency check, forward logic, wakeup lsiq
// - All accesses cacheable, no special operations

module lsu_wmb #(
  parameter int PA_WIDTH  = 32,
  parameter int WMB_ENTRY = 4,
  parameter int SQ_ENTRY  = 6,
  parameter int LSIQ_ENTRY = 8,
  parameter int DCACHE_SIZE = 2048,  // 1024, 2048, or 4096 bytes
  parameter int CACHELINE_SIZE = 32,
  parameter int NUM_WAYS = 2,
  parameter int OFFSET_WIDTH = 5,
  parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
  parameter int INDEX_WIDTH = $clog2(NUM_SETS),
  parameter int INDEX_LSB = OFFSET_WIDTH,
  parameter int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1,
  parameter int DATA_INDEX_WIDTH = INDEX_WIDTH + 1
)(
  input  logic                 cpurst_b,
  input  logic                 forever_cpuclk,
  // SQ interface
  input  logic [PA_WIDTH-1:0]  sq_pop_addr,
  input  logic [127:0]         sq_pop_data,
  input  logic [15:0]          sq_pop_bytes_vld,
  input  logic [SQ_ENTRY-1:0]  sq_pop_ptr,
  input  logic                 sq_wmb_merge_req,
  input  logic                 sq_wmb_merge_stall_req,
  input  logic                 sq_wmb_pop_to_ce_req,

  // Dcache status
  input  logic                 st_da_dcache_hit,
  input  logic                 st_da_dcache_way,
  input  logic                 st_da_dcache_dirty,
  input  logic                 st_da_dcache_valid,

  // Dcache write port monitoring (for entry status update)
  input  logic [4:0]           dcache_dirty_din,
  input  logic                 dcache_dirty_gwen,
  input  logic [4:0]           dcache_dirty_wen,
  input  logic [4:0]           dcache_idx,
  input  logic [43:0]          dcache_tag_din,
  input  logic                 dcache_tag_gwen,
  input  logic [1:0]           dcache_tag_wen,

  // RB (MSHR) interface
  input  logic [PA_WIDTH-1:0]  rb_biu_req_addr,

  // BIU AW/W/B channels
  input  logic                 bus_arb_wmb_aw_grnt,
  input  logic                 bus_arb_wmb_w_grnt,
  input  logic [3:0]           biu_lsu_b_id,
  input  logic [1:0]           biu_lsu_b_resp,
  input  logic                 biu_lsu_b_vld,

  // Dcache arbiter
  input  logic                 dcache_arb_wmb_ld_grnt,

  // LD dependency check
  input  logic [PA_WIDTH-1:0]  ld_dc_addr0,
  input  logic [7:0]           ld_dc_addr1_11to4,
  input  logic [15:0]          ld_dc_bytes_vld,
  input  logic                 ld_dc_chk_ld_inst_vld,
  input  logic                 lfb_wmb_write_req_hit_idx,
  input  logic                 vb_wmb_hit_idx,
  // LFB/VB address for conflict check (at set granularity)
  /*
  input  logic [26:0]          lfb_vb_addr_tto5,
  input  logic                 lfb_vb_create_vld,
  input  logic [31:0]          vb_biu_aw_addr,
  input  logic                 vb_biu_aw_req,
*/
  // Flush
  input  logic                 rtu_yy_xx_flush,

  // Outputs to SQ
  output logic                 wmb_sq_pop_grnt,

  // CE interface - inputs from CE module
  input  logic [PA_WIDTH-1:0]  wmb_ce_addr,
  input  logic [127:0]         wmb_ce_data128,
  input  logic [15:0]          wmb_ce_bytes_vld,
  input  logic [3:0]           wmb_ce_data_vld,
  input  logic [SQ_ENTRY-1:0]  wmb_ce_sq_ptr,
  input  logic                 wmb_ce_merge,
  input  logic [WMB_ENTRY-1:0] wmb_ce_merge_ptr,
  input  logic [WMB_ENTRY-1:0] wmb_ce_same_dcache_line,
  input  logic                 wmb_ce_merge_en,
  input  logic                 wmb_ce_update_dcache_valid,
  input  logic                 wmb_ce_update_dcache_dirty,
  input  logic                 wmb_ce_update_dcache_way,
  input  logic                 wmb_ce_write_biu_req,
  input  logic                 wmb_ce_write_dcache_req,
  input  logic                 wmb_ce_merge_data_addr_hit,
  input  logic                 wmb_ce_merge_data_stall,
  input  logic                 wmb_ce_merge_wmb_req,
  input  logic                 wmb_ce_create_wmb_req,
  input  logic                 wmb_ce_create_wmb_data_req,
  input  logic                 wmb_ce_vld,

  // CE interface - outputs to CE module
  output logic                 wmb_ce_pop_vld,
  output logic                 wmb_ce_create_vld,
  output logic                 wmb_ce_create_merge,
  output logic [WMB_ENTRY-1:0] wmb_ce_create_merge_ptr,
  output logic                 wmb_ce_create_stall,
  output logic [WMB_ENTRY-1:0] wmb_entry_vld,

  // BIU AW channel
  output logic [PA_WIDTH-1:0]  wmb_biu_aw_addr,
 // output logic [1:0]           wmb_biu_aw_bar,
  output logic [1:0]           wmb_biu_aw_burst,
  output logic [3:0]           wmb_biu_aw_cache,
 // output logic [1:0]           wmb_biu_aw_domain,
  output logic [3:0]           wmb_biu_aw_id,
  output logic [1:0]           wmb_biu_aw_len,
 // output logic                 wmb_biu_aw_lock,
  output logic [2:0]           wmb_biu_aw_prot,
  output logic                 wmb_biu_aw_req,
  output logic [2:0]           wmb_biu_aw_size,
  output logic [2:0]           wmb_biu_aw_snoop,
 // output logic                 wmb_biu_aw_user,

  // BIU W channel
  output logic [127:0]         wmb_biu_w_data,
  output logic [3:0]           wmb_biu_w_id,
  output logic                 wmb_biu_w_last,
  output logic                 wmb_biu_w_req,
  output logic [15:0]          wmb_biu_w_strb,
  output logic                 wmb_biu_w_vld,

  // Dcache interface
  output logic                 wmb_dcache_arb_req,
  output logic [7:0]           wmb_dcache_arb_ld_data_gateclk_en,
  output logic [127:0]         wmb_dcache_arb_ld_data_high_din,
  output logic [127:0]         wmb_dcache_arb_ld_data_low_din,
  output logic [DATA_INDEX_WIDTH-1:0]  wmb_dcache_arb_ld_data_idx,
  output logic [7:0]           wmb_dcache_arb_ld_data_req,
  output logic [31:0]          wmb_dcache_arb_ld_data_wen,
  output logic [4:0]           wmb_dcache_arb_st_dirty_din,
  output logic [INDEX_WIDTH-1:0]       wmb_dcache_arb_st_dirty_idx,
  output logic                 wmb_dcache_arb_st_dirty_req,
  output logic                 wmb_dcache_arb_st_dirty_gateclk_en,
  output logic [4:0]           wmb_dcache_arb_st_dirty_wen,

  // LD forward
  output logic [127:0]         wmb_ld_da_fwd_data,
  output logic                 wmb_ld_dc_fwd_req,
  output logic [15:0]          wmb_fwd_bytes_vld,
  output logic                 wmb_ld_dc_discard_req,

  // Wakeup LSIQ
  output logic [LSIQ_ENTRY-1:0] wmb_depd_wakeup,
  output logic                  wmb_sq_pop_to_ce_grnt,
  output logic                  wmb_rb_biu_req_hit_idx
);

  // Internal wires and registers
  logic [WMB_ENTRY-1:0]  wmb_create_ptr;
  logic [WMB_ENTRY-1:0]  wmb_write_ptr;
  logic [WMB_ENTRY-1:0]  wmb_data_ptr;
  logic                  wmb_create_ptr_circular;
  logic                  wmb_write_ptr_circular;
  logic                  wmb_data_ptr_circular;

  logic [WMB_ENTRY-1:0]  wmb_create_ptr_next1;
  logic [WMB_ENTRY-1:0]  wmb_write_ptr_next1;
  logic [WMB_ENTRY-1:0]  wmb_data_ptr_next1;

  logic [WMB_ENTRY-1:0]  wmb_entry_create_vld;
  logic [WMB_ENTRY-1:0]  wmb_entry_create_data_vld;
  logic [WMB_ENTRY-1:0]  wmb_entry_pop_vld;
  logic [WMB_ENTRY-1:0]  wmb_entry_write_biu_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_write_dcache_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_write_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_data_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_data_biu_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_fwd_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_rb_biu_req_hit_idx;
  logic [WMB_ENTRY-1:0]  wmb_entry_discard_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_cancel_acc_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_merge_data_addr_hit;
  logic [WMB_ENTRY-1:0]  wmb_entry_merge_data_stall;
  logic [WMB_ENTRY-1:0]  wmb_entry_merge_data_vld;
  logic [WMB_ENTRY-1:0]  wmb_entry_hit_sq_pop_dcache_line;
  logic [WMB_ENTRY-1:0]  wmb_entry_dcache_way;
  logic [WMB_ENTRY-1:0]  wmb_entry_fwd_data_pe_req;
  logic [WMB_ENTRY-1:0]  wmb_entry_write_ptr_unconditional_shift_imme;
  logic [WMB_ENTRY-1:0]  wmb_entry_write_ptr_after_write_shift_imme;
  logic [WMB_ENTRY-1:0]  wmb_entry_data_ptr_after_write_shift_imme;
  logic [WMB_ENTRY-1:0]  wmb_entry_aw_pending;
  logic [WMB_ENTRY-1:0]  wmb_entry_w_pending;

  logic [PA_WIDTH-1:0]   wmb_entry_addr [WMB_ENTRY];
  logic [127:0]          wmb_entry_data [WMB_ENTRY];
  logic [15:0]           wmb_entry_bytes_vld [WMB_ENTRY];
  logic [15:0]           wmb_entry_fwd_bytes_vld [WMB_ENTRY];
  logic [3:0]            wmb_entry_biu_id [WMB_ENTRY];

  // wmb_ce signals are now ports, removed from internal signals

  logic                  wmb_create_vld;
  logic                  wmb_merge_vld;
  logic                  wmb_create_permit;
  logic [WMB_ENTRY-1:0]  wmb_create_not_vld;

  logic                  wmb_write_ptr_shift_vld;
  logic                  wmb_data_ptr_shift_vld;
  logic                  wmb_write_ptr_met_create;
  logic                  wmb_data_ptr_met_create;
  logic                  wmb_write_grnt;
  logic                  wmb_data_grnt;
  logic                  wmb_write_req;
  logic                  wmb_data_req;
  logic                  wmb_write_ptr_shift_imme_grnt;
  logic                  wmb_entry_write_ptr_shift_imme;
  logic                  wmb_entry_data_ptr_shift_imme;

  logic [PA_WIDTH-1:0]   wmb_write_req_addr;
  logic                  wmb_write_biu_req_unmask;
  logic [1:0]            wmb_write_ptr_encode;

  logic [127:0]          wmb_data_req_data;
  logic [3:0]            wmb_data_req_biu_id;
  logic [15:0]           wmb_data_req_bytes_vld;

  logic [WMB_ENTRY-1:0]  wmb_write_dcache_ptr;
  logic [WMB_ENTRY-1:0]  wmb_dcache_req_ptr;
  logic                  wmb_write_dcache_pop_req;
  logic                  wmb_write_dcache_success;
  logic [PA_WIDTH-1:0]   wmb_write_dcache_addr;
  logic [127:0]          wmb_write_dcache_data;
  logic [15:0]           wmb_write_dcache_bytes_vld;
  logic                  wmb_write_req_dcache_way;

  logic [127:0]          wmb_fwd_data;
  logic [127:0]          wmb_fwd_data_sel;
  logic                  wmb_fwd_data_pe_req;
  logic                  wmb_fwd_req;

  logic [LSIQ_ENTRY-1:0] wmb_wakeup_queue;
  logic [LSIQ_ENTRY-1:0] wmb_wakeup_queue_next;
  logic [LSIQ_ENTRY-1:0] wmb_wakeup_queue_grnt;
  logic                  wmb_pop_depd;
  logic                  wmb_pop_depd_ff;
  logic                  wmb_pop_discard_req;
  logic                  wmb_pop_fwd_req;
  logic                  wmb_merge_data_addr_hit;
  logic                  wmb_merge_data_stall;
  // wmb_ce_create_* signals are now ports
  logic                  wmb_pop_to_ce_permit;


  logic [1:0]            BIU_R_NORM_ID_T = 2'b01;

  //==========================================================
  //                      Empty signal
  //==========================================================

  // CE module is now instantiated in lsu_top
  // CE data comes from SQ
  // assign wmb_ce_data128 = sq_pop_data; // Now handled in lsu_top

  //==========================================================
  //          Instance of WMB Entries
  //==========================================================
  genvar i;
  generate
    for (i = 0; i < WMB_ENTRY; i++) begin : gen_wmb_entry
lsu_wmb_entry #(
        .PA_WIDTH(PA_WIDTH),
        .WMB_ENTRY(WMB_ENTRY),
        .DCACHE_SIZE(DCACHE_SIZE)
      ) x_lsu_wmb_entry (
        .cpurst_b(cpurst_b),
        .forever_cpuclk(forever_cpuclk),

        // BIU interface
        .biu_lsu_b_id(biu_lsu_b_id),
        .biu_lsu_b_vld(biu_lsu_b_vld),
        .bus_arb_wmb_aw_grnt(bus_arb_wmb_aw_grnt),
        .bus_arb_wmb_w_grnt(bus_arb_wmb_w_grnt),
        .wmb_biu_aw_id(wmb_biu_aw_id),

        // Dcache write port monitoring
        .dcache_dirty_din(dcache_dirty_din),
        .dcache_dirty_gwen(dcache_dirty_gwen),
        .dcache_dirty_wen(dcache_dirty_wen),
        .dcache_idx(dcache_idx),
        .dcache_tag_din(dcache_tag_din),
        .dcache_tag_gwen(dcache_tag_gwen),
        .dcache_tag_wen(dcache_tag_wen),

        // LD dependency check
        .ld_dc_addr0(ld_dc_addr0),
        .ld_dc_addr1_11to4(ld_dc_addr1_11to4),
        .ld_dc_bytes_vld(ld_dc_bytes_vld),
        .ld_dc_chk_ld_inst_vld(ld_dc_chk_ld_inst_vld),

        // RB interface
        .rb_biu_req_addr(rb_biu_req_addr),

        // SQ interface
        .sq_pop_addr(sq_pop_addr),

        // Create interface
        .wmb_ce_addr(wmb_ce_addr),
        .wmb_ce_bytes_vld(wmb_ce_bytes_vld),
        .wmb_ce_data128(wmb_ce_data128),
        .wmb_ce_data_vld(wmb_ce_data_vld),
        .wmb_ce_merge_en(wmb_ce_merge_en),
        .wmb_ce_update_dcache_valid(wmb_ce_update_dcache_valid),
        .wmb_ce_update_dcache_dirty(wmb_ce_update_dcache_dirty),
        .wmb_ce_update_dcache_way(wmb_ce_update_dcache_way),

        // Entry control
        .wmb_entry_create_vld_x(wmb_entry_create_vld[i]),
        .wmb_entry_create_data_vld_x(wmb_entry_create_data_vld[i]),
        .wmb_entry_merge_data_vld_x(wmb_entry_merge_data_vld[i]),

        // Pointer control
        .wmb_write_ptr_x(wmb_write_ptr[i]),
        .wmb_data_ptr_x(wmb_data_ptr[i]),
        .wmb_dcache_req_ptr_x(wmb_dcache_req_ptr[i]),
        .wmb_write_dcache_success(wmb_write_dcache_success),
        .wmb_write_ptr_shift_imme_grnt(wmb_write_ptr_shift_imme_grnt),

        // Outputs
        .wmb_entry_addr_v(wmb_entry_addr[i]),
        .wmb_entry_data_v(wmb_entry_data[i]),
        .wmb_entry_bytes_vld_v(wmb_entry_bytes_vld[i]),
        .wmb_entry_fwd_bytes_vld_v(wmb_entry_fwd_bytes_vld[i]),
        .wmb_entry_vld_x(wmb_entry_vld[i]),
        .wmb_entry_dcache_way_x(wmb_entry_dcache_way[i]),
        .wmb_entry_merge_data_addr_hit_x(wmb_entry_merge_data_addr_hit[i]),
        .wmb_entry_merge_data_stall_x(wmb_entry_merge_data_stall[i]),
        .wmb_entry_hit_sq_pop_dcache_line_x(wmb_entry_hit_sq_pop_dcache_line[i]),
        .wmb_entry_fwd_req_x(wmb_entry_fwd_req[i]),
        .wmb_entry_fwd_data_pe_req_x(wmb_entry_fwd_data_pe_req[i]),
        .wmb_entry_discard_req_x(wmb_entry_discard_req[i]),
        .wmb_entry_cancel_acc_req_x(wmb_entry_cancel_acc_req[i]),
        .wmb_entry_write_req_x(wmb_entry_write_req[i]),
        .wmb_entry_write_biu_req_x(wmb_entry_write_biu_req[i]),
        .wmb_entry_write_dcache_req_x(wmb_entry_write_dcache_req[i]),
        .wmb_entry_write_ptr_unconditional_shift_imme_x(wmb_entry_write_ptr_unconditional_shift_imme[i]),
        .wmb_entry_data_req_x(wmb_entry_data_req[i]),
        .wmb_entry_data_biu_req_x(wmb_entry_data_biu_req[i]),
        .wmb_entry_data_ptr_after_write_shift_imme_x(wmb_entry_data_ptr_after_write_shift_imme[i]),
        .wmb_entry_biu_id_v(wmb_entry_biu_id[i]),
        .wmb_entry_pop_vld_x(wmb_entry_pop_vld[i]),
        .wmb_entry_rb_biu_req_hit_idx(wmb_entry_rb_biu_req_hit_idx[i])
      );
    end
  endgenerate
assign wmb_rb_biu_req_hit_idx = |wmb_entry_rb_biu_req_hit_idx;
  //==========================================================
  //                  Pointer Management
  //==========================================================
  // Create pointer
  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_create_ptr <= {{WMB_ENTRY-1{1'b0}}, 1'b1};
    else if (wmb_create_vld)
      wmb_create_ptr <= wmb_create_ptr_next1;
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_create_ptr_circular <= 1'b0;
    else if (wmb_create_vld && wmb_create_ptr[WMB_ENTRY-1])
      wmb_create_ptr_circular <= !wmb_create_ptr_circular;
  end

  // Write pointer
  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_write_ptr <= {{WMB_ENTRY-1{1'b0}}, 1'b1};
    else if (wmb_write_ptr_shift_vld)
      wmb_write_ptr <= wmb_write_ptr_next1;
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_write_ptr_circular <= 1'b0;
    else if (wmb_write_ptr_shift_vld && wmb_write_ptr[WMB_ENTRY-1])
      wmb_write_ptr_circular <= !wmb_write_ptr_circular;
  end

  // Data pointer
  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_data_ptr <= {{WMB_ENTRY-1{1'b0}}, 1'b1};
    else if (wmb_data_ptr_shift_vld)
      wmb_data_ptr <= wmb_data_ptr_next1;
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_data_ptr_circular <= 1'b0;
    else if (wmb_data_ptr_shift_vld && wmb_data_ptr[WMB_ENTRY-1])
      wmb_data_ptr_circular <= !wmb_data_ptr_circular;
  end

  // Pointer rotation
  assign wmb_create_ptr_next1 = {wmb_create_ptr[WMB_ENTRY-2:0], wmb_create_ptr[WMB_ENTRY-1]};
  assign wmb_write_ptr_next1  = {wmb_write_ptr[WMB_ENTRY-2:0], wmb_write_ptr[WMB_ENTRY-1]};
  assign wmb_data_ptr_next1   = {wmb_data_ptr[WMB_ENTRY-2:0], wmb_data_ptr[WMB_ENTRY-1]};

  // Pointer encoding
  function automatic [2:0] encode_ptr;
    input [WMB_ENTRY-1:0] ptr;
    integer j;
    begin
      encode_ptr = 3'b0;
      for (j = 0; j < WMB_ENTRY; j = j + 1) begin
        if (ptr[j])
          encode_ptr = j[2:0];
      end
    end
  endfunction

  assign wmb_write_ptr_encode = encode_ptr(wmb_write_ptr);

  // Pointer comparison
  assign wmb_write_ptr_met_create = (wmb_write_ptr == wmb_create_ptr) && (wmb_write_ptr_circular == wmb_create_ptr_circular);
  assign wmb_data_ptr_met_create  = (wmb_data_ptr == wmb_create_ptr) && (wmb_data_ptr_circular == wmb_create_ptr_circular);

  // Pointer shift control
  assign wmb_write_grnt = bus_arb_wmb_aw_grnt;
  assign wmb_data_grnt = bus_arb_wmb_w_grnt;
  assign wmb_write_req = |wmb_entry_write_req;
  assign wmb_data_req = |wmb_entry_data_req;

  // ⚠️ 原来取的是 `wmb_entry_write_ptr_after_write_shift_imme` —— 那是根**谁都没驱动**
  //    的向量(表项只引出 `..._unconditional_shift_imme_x`) ⇒ shift_imme = X/Z ⇒
  //    `wmb_write_ptr_shift_vld` 变 X ⇒ 写指针不走 ⇒ `wmb_write_req_addr` 落到未建
  //    表项上(addr=X) ⇒ AW 地址 `xxxxxxx0`。
  //    我曾把它改成本仓那根真向量, 但**取法又抄错了**: `array[wmb_write_ptr]` 是拿
  //    4 位 one-hot 当下标 ⇒ 越界 ⇒ X。原版 (ct_lsu_wmb.v:3242/3247) 就是**对全部
  //    表项直接 OR**, 不套下标。这里照原版改回。
  assign wmb_entry_write_ptr_shift_imme = |wmb_entry_write_ptr_unconditional_shift_imme;
  assign wmb_entry_data_ptr_shift_imme  = |wmb_entry_data_ptr_after_write_shift_imme;

  // 移位条件也照原版 (ct_lsu_wmb.v:3270):
  //   shift_vld = wmb_write_grnt || (!met_create && shift_imme)
  // 原来是 `wmb_write_grnt && wmb_write_req || |(imme)` —— 多了个 `&& req`、少了
  // `!met_create` 门, 都会让写指针在需要"跳过无效/已完成表项"时不走。
  assign wmb_write_ptr_shift_vld = wmb_write_grnt
                                   || (!wmb_write_ptr_met_create && wmb_entry_write_ptr_shift_imme);
  assign wmb_data_ptr_shift_vld  = wmb_data_grnt
                                   || (!wmb_data_ptr_met_create && wmb_entry_data_ptr_shift_imme);

  //==========================================================
  //          SQ interface - create/merge logic
  //==========================================================
  assign wmb_merge_data_addr_hit = |wmb_entry_merge_data_addr_hit;
  assign wmb_merge_data_stall = |wmb_entry_merge_data_stall;

  assign wmb_ce_create_merge = sq_wmb_merge_req && (wmb_merge_data_addr_hit || wmb_ce_merge_data_addr_hit);
  assign wmb_ce_create_stall = wmb_merge_data_stall || wmb_ce_merge_data_stall
                               || (wmb_merge_data_addr_hit || wmb_ce_merge_data_addr_hit) && sq_wmb_merge_stall_req;
  assign wmb_ce_create_merge_ptr = wmb_ce_merge_data_addr_hit ? wmb_create_ptr : wmb_entry_merge_data_addr_hit;

  assign wmb_pop_to_ce_permit = wmb_sq_pop_grnt || !wmb_ce_vld;
  assign wmb_ce_create_vld = sq_wmb_pop_to_ce_req && wmb_pop_to_ce_permit;
  assign wmb_sq_pop_to_ce_grnt = sq_wmb_pop_to_ce_req && wmb_pop_to_ce_permit;

  //==========================================================
  //          CE to Entry allocation
  //==========================================================
  assign wmb_create_not_vld = wmb_create_ptr & (~wmb_entry_vld);
  assign wmb_create_permit = |wmb_create_not_vld;

  assign wmb_create_vld = wmb_create_permit && wmb_ce_create_wmb_req;
  assign wmb_merge_vld = wmb_ce_merge_wmb_req;

  assign wmb_entry_create_vld = wmb_create_not_vld & {WMB_ENTRY{wmb_ce_create_wmb_req}};
  // ⚠️ 漏掉的输出 (原版 ct_lsu_wmb.v:3410): 建表项时**装数据**的使能。
  //    没这根 ⇒ 表项里 `wmb_entry_data <= wmb_entry_data_next` 的条件是 X/Z ⇒ 永真
  //    不成立 ⇒ WMB 表项的数据恒为 0 ⇒ 写出去的 W.data 全是 0 ⇒ store 写进去的
  //    是 0 而不是要存的值(字节掩码 wstrb 却是对的)。
  assign wmb_entry_create_data_vld = wmb_create_not_vld & {WMB_ENTRY{wmb_ce_create_wmb_data_req}};
  assign wmb_entry_merge_data_vld = {WMB_ENTRY{wmb_merge_vld}} & wmb_ce_merge_ptr;

  assign wmb_sq_pop_grnt = wmb_create_vld || wmb_merge_vld;
  assign wmb_ce_pop_vld = wmb_sq_pop_grnt;

  //==========================================================
  //          BIU AW channel (simplified - no icc/fence/sync)
  //==========================================================
  // ⚠️ 原版这里是"建表项时装载 wmb_ce_addr" + "写指针移位时装载 next1 地址"两级;
  //    移植只留了后者, 且取的是 `wmb_write_ptr_next1`(移位后那位) —— 那位常常**还没建
  //    表项**(wmb_entry_addr = X) ⇒ 记下的 AW 地址是 X ⇒ store 写到空处, 后续 load
  //    读到的是没被更新的老内存。
  //    改为: 建表项时装载新表项地址; 移位时按**当前**写指针取地址。
  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_write_req_addr <= '0;
    else if (wmb_create_vld)
      wmb_write_req_addr <= wmb_ce_addr;
    else if (wmb_write_ptr_shift_vld)
      wmb_write_req_addr <= wmb_entry_addr[encode_ptr(wmb_write_ptr)];
  end

  assign wmb_write_biu_req_unmask = |wmb_entry_write_biu_req;

  // Conflict check: WMB can only issue BIU AW if no conflict with LFB/VB at set granularity
  /*
  logic wmb_lfb_conflict;
  logic wmb_vb_conflict;

  assign wmb_lfb_conflict = lfb_vb_create_vld
                          && (wmb_write_req_addr[INDEX_MSB:INDEX_LSB] == lfb_vb_addr_tto5[INDEX_WIDTH-1:0]);

  assign wmb_vb_conflict = vb_biu_aw_req
                         && (wmb_write_req_addr[INDEX_MSB:INDEX_LSB] == vb_biu_aw_addr[INDEX_MSB:INDEX_LSB]);
*/
  assign wmb_biu_aw_req = wmb_write_biu_req_unmask & !vb_wmb_hit_idx & !lfb_wmb_write_req_hit_idx; //&& !wmb_lfb_conflict && !wmb_vb_conflict;
  assign wmb_biu_aw_addr = {wmb_write_req_addr[PA_WIDTH-1:4], 4'b0};
  assign wmb_biu_aw_id = {BIU_R_NORM_ID_T, wmb_write_ptr_encode};
  assign wmb_biu_aw_len = 2'b00;  // Single beat
  assign wmb_biu_aw_size = 3'b100;  // 16 bytes
  assign wmb_biu_aw_burst = 2'b01;  // INCR
  //assign wmb_biu_aw_lock = 1'b0;
  assign wmb_biu_aw_cache = 4'b1111;  // All cacheable
  assign wmb_biu_aw_prot = 3'b000;
  assign wmb_biu_aw_snoop = 3'b000;  // No snoop
 // assign wmb_biu_aw_domain = 2'b00;
 // assign wmb_biu_aw_bar = 2'b00;
 // assign wmb_biu_aw_user = 1'b0;

  //==========================================================
  //          BIU W channel
  //==========================================================
  always_comb begin
    wmb_data_req_data = 128'b0;
    for (int j = 0; j < WMB_ENTRY; j++) begin
      if (wmb_data_ptr[j])
        wmb_data_req_data = wmb_entry_data[j];
    end
  end

  always_comb begin
    wmb_data_req_bytes_vld = 16'b0;
    for (int j = 0; j < WMB_ENTRY; j++) begin
      if (wmb_data_ptr[j])
        wmb_data_req_bytes_vld = wmb_entry_bytes_vld[j];
    end
  end

  always_comb begin
    wmb_data_req_biu_id = 5'b0;
    for (int j = 0; j < WMB_ENTRY; j++) begin
      if (wmb_data_ptr[j])
        wmb_data_req_biu_id = wmb_entry_biu_id[j];
    end
  end

  assign wmb_biu_w_req = wmb_data_req;
  assign wmb_biu_w_vld = wmb_data_req;
  assign wmb_biu_w_id = wmb_data_req_biu_id;
  assign wmb_biu_w_data = wmb_data_req_data;
  assign wmb_biu_w_strb = wmb_data_req_bytes_vld;
  // ⚠️ 漏掉的输出: 原 C910 `wmb_biu_w_last = wmb_data_req_w_last`。本移植**根本没引出
  //    这根** ⇒ lsu_top 里 wmb_biu_w_last 悬空 ⇒ bus_arb 的 lsu_biu_w_st_last = Z
  //    ⇒ BIU 写通道 `biu_pad_wlast` = X ⇒ ct_biu_write_channel 的 WR_ACTIVE 永远
  //    `aw_done=1, w_done=0` ⇒ store 永远写不出去 ⇒ WMB 堵死 ⇒ MSHR 读被
  //    `wmb_rb_biu_req_hit_idx` 顶住 ⇒ 后续 load 的 line fill 永远做不了。
  //    本仓 AW/W 都是单拍 (aw_len=0, 16B/拍), 所以"有数据就是最后一拍"。
  assign wmb_biu_w_last = wmb_data_req;

  //==========================================================
  //          Dcache write request
  //==========================================================
  logic [WMB_ENTRY-1:0] wmb_dcache_req_set;
  logic [WMB_ENTRY-1:0] wmb_write_dcache_ptr_set;
  logic                 wmb_dcache_req_next;
  logic                 wmb_write_dcache_pop_up;

  assign wmb_dcache_req_ptr[WMB_ENTRY-1:0] = {WMB_ENTRY{wmb_write_dcache_pop_req}} & wmb_write_dcache_ptr[WMB_ENTRY-1:0];
  // ⚠️ 原版 (ct_lsu_wmb.v:4091) 屏蔽的是 `~wmb_dcache_req_ptr` (= 仅"正在弹的那项"),
  //    本仓抄成了 `~wmb_write_dcache_ptr` ⇒ **指针指着的那项被恒屏蔽**。若指针恰好
  //    就停在那唯一请求写 dcache 的表项上, req_set 恒 0 ⇒ req_next 恒 0 ⇒ pop_req
  //    永不抬 ⇒ 指针也永不前进 ⇒ 死锁: store 的数据永远写不进 dcache。
  assign wmb_dcache_req_set = wmb_entry_write_dcache_req & ~wmb_dcache_req_ptr;
  assign wmb_dcache_req_next = |wmb_dcache_req_set;
  assign wmb_write_dcache_pop_up = wmb_write_dcache_success || (!wmb_write_dcache_pop_req && wmb_dcache_req_next);

  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_write_dcache_pop_req <= 1'b0;
    else if (wmb_write_dcache_pop_up)
      wmb_write_dcache_pop_req <= wmb_dcache_req_next;
  end

  // Select next dcache request (priority encoder from write_ptr)
  always_comb begin
    wmb_write_dcache_ptr_set = '0;
    for (int j = 0; j < WMB_ENTRY; j++) begin
      if (wmb_dcache_req_set[(encode_ptr(wmb_write_ptr) + j) % WMB_ENTRY]) begin
        wmb_write_dcache_ptr_set[(encode_ptr(wmb_write_ptr) + j) % WMB_ENTRY] = 1'b1;
        break;
      end
    end
  end

  always_ff @(posedge forever_cpuclk) begin
    if (wmb_write_dcache_pop_up) begin
      wmb_write_dcache_ptr <= wmb_write_dcache_ptr_set;
    end
  end

  always_comb begin
    wmb_write_dcache_addr = '0;
    wmb_write_dcache_data = '0;
    wmb_write_dcache_bytes_vld = '0;
    for (int j = 0; j < WMB_ENTRY; j++) begin
      if (wmb_write_dcache_ptr[j]) begin
        wmb_write_dcache_addr = wmb_entry_addr[j];
        wmb_write_dcache_data = wmb_entry_data[j];
        wmb_write_dcache_bytes_vld = wmb_entry_bytes_vld[j];
      end
    end
  end

  assign wmb_write_req_dcache_way = |(wmb_write_dcache_ptr & wmb_entry_dcache_way);

  assign wmb_dcache_arb_req = wmb_write_dcache_pop_req;
  assign wmb_write_dcache_success = wmb_dcache_arb_req && dcache_arb_wmb_ld_grnt;

  // Dcache data array - 128-bit granularity, split high/low by address bit [4]
  logic wmb_dcache_data_high_sel;
  logic [3:0] wmb_dcache_data_region;

  assign wmb_dcache_data_region[3] = |wmb_write_dcache_bytes_vld[15:12];
  assign wmb_dcache_data_region[2] = |wmb_write_dcache_bytes_vld[11:8];
  assign wmb_dcache_data_region[1] = |wmb_write_dcache_bytes_vld[7:4];
  assign wmb_dcache_data_region[0] = |wmb_write_dcache_bytes_vld[3:0];
  assign wmb_dcache_data_high_sel = wmb_write_req_dcache_way ^ wmb_write_dcache_addr[4];

  assign wmb_dcache_arb_ld_data_req = {wmb_dcache_data_region, wmb_dcache_data_region}
                                      & {{4{wmb_dcache_data_high_sel}}, {4{!wmb_dcache_data_high_sel}}}
                                      & {8{wmb_dcache_arb_req}};
  assign wmb_dcache_arb_ld_data_gateclk_en = wmb_dcache_arb_ld_data_req;

  assign wmb_dcache_arb_ld_data_idx = {wmb_write_dcache_addr[INDEX_MSB:INDEX_LSB], wmb_write_req_dcache_way};
  assign wmb_dcache_arb_ld_data_low_din = wmb_write_dcache_data;
  assign wmb_dcache_arb_ld_data_high_din = wmb_write_dcache_data;
  assign wmb_dcache_arb_ld_data_wen = {wmb_write_dcache_bytes_vld, wmb_write_dcache_bytes_vld}
                                      & {{16{wmb_dcache_data_high_sel}}, {16{!wmb_dcache_data_high_sel}}};

  // Dirty array
  assign wmb_dcache_arb_st_dirty_req = wmb_dcache_arb_req;
  assign wmb_dcache_arb_st_dirty_gateclk_en = wmb_dcache_arb_req;
  assign wmb_dcache_arb_st_dirty_idx = wmb_write_dcache_addr[INDEX_MSB:INDEX_LSB];
  assign wmb_dcache_arb_st_dirty_din = 5'b01111;  // Set dirty bit
  assign wmb_dcache_arb_st_dirty_wen = {1'b0, {2{wmb_write_req_dcache_way}}, {2{!wmb_write_req_dcache_way}}};


  //==========================================================
  //          LD forward data
  //==========================================================
  assign wmb_fwd_req = |wmb_entry_fwd_req;
  assign wmb_fwd_data_pe_req = (|wmb_entry_fwd_data_pe_req) && ld_dc_chk_ld_inst_vld;

  always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b)
      wmb_fwd_data <= 128'b0;
    else if (wmb_fwd_data_pe_req)
      wmb_fwd_data <= wmb_fwd_data_sel;
  end

  always_comb begin
    wmb_fwd_data_sel = 128'b0;
    wmb_fwd_bytes_vld = 16'b0;
    for (int j = 0; j < WMB_ENTRY; j++) begin
      if (wmb_entry_fwd_data_pe_req[j]) begin
        wmb_fwd_data_sel  = wmb_entry_data[j];
        // 原 C910 用 wmb_fwd_id 选出命中表项的字节掩码 (ct_lsu_wmb.v 的
        // wmb_fwd_bytes_vld 选择器)。本移植**漏了这个输出**, lsu_top 里
        // wmb_fwd_bytes_vld 悬空 ⇒ 只靠 WMB 旁路时 (ld_dc 的 2'b01 分支)
        // ld_dc_fwd_bytes_vld 变成 X/0 ⇒ 部分覆盖的 store→load 拿不到数据。
        wmb_fwd_bytes_vld = wmb_entry_fwd_bytes_vld[j];
      end
    end
  end

  assign wmb_ld_da_fwd_data = wmb_fwd_data;
  assign wmb_ld_dc_fwd_req = wmb_fwd_req;
  assign wmb_ld_dc_discard_req = |wmb_entry_discard_req;


endmodule
