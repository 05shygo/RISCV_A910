// Simplified WMB Entry for RV32I
// - 32-bit address, 32-byte cacheline (2x128bit)
// - Removed: page attributes, shared, snoop, icc, fence, sync, ecc
// - Keep: valid, dirty, fifo, basic store operations
// - Support configurable entry count

module lsu_wmb_entry #(
  parameter int PA_WIDTH  = 32,
  parameter int WMB_ENTRY = 4,
  parameter int DCACHE_SIZE = 2048  // 1024, 2048, or 4096 bytes
)(
  // Clock and reset
  input  logic          cpurst_b,
  input  logic          forever_cpuclk,

  // BIU interface
  input  logic [3:0]    biu_lsu_b_id,
  input  logic          biu_lsu_b_vld,
  input  logic          bus_arb_wmb_aw_grnt,
  input  logic          bus_arb_wmb_w_grnt,
  input  logic [3:0]    wmb_biu_aw_id,

  // Dcache write port monitoring (for real-time status update)
  input  logic [4:0]    dcache_dirty_din,
  input  logic          dcache_dirty_gwen,
  input  logic [4:0]    dcache_dirty_wen,
  input  logic [4:0]    dcache_idx,
  input  logic [43:0]   dcache_tag_din,
  input  logic          dcache_tag_gwen,
  input  logic [1:0]    dcache_tag_wen,

  // Load pipe dependency check
  input  logic [PA_WIDTH-1:0] ld_dc_addr0,
  input  logic [7:0]    ld_dc_addr1_11to4,
  input  logic [15:0]   ld_dc_bytes_vld,
  input  logic          ld_dc_chk_ld_inst_vld,

  // RB (MSHR) interface
  input  logic [PA_WIDTH-1:0] rb_biu_req_addr,

  // SQ interface
  input  logic [PA_WIDTH-1:0] sq_pop_addr,

  // WMB CE interface
  input  logic [PA_WIDTH-1:0] wmb_ce_addr,
  input  logic [15:0]   wmb_ce_bytes_vld,
  input  logic [127:0]  wmb_ce_data128,
  input  logic [3:0]    wmb_ce_data_vld,
  input  logic          wmb_ce_merge_en,
  input  logic          wmb_ce_update_dcache_valid,
  input  logic          wmb_ce_update_dcache_dirty,
  input  logic          wmb_ce_update_dcache_way,

  // WMB control signals (from top)
  input  logic          wmb_data_ptr_x,
  input  logic          wmb_dcache_req_ptr_x,
  input  logic          wmb_write_ptr_x,
  input  logic          wmb_write_dcache_success,
  input  logic          wmb_write_ptr_shift_imme_grnt,

  // Entry control (internal feedback)
  input  logic          wmb_entry_create_vld_x,
  input  logic          wmb_entry_create_data_vld_x,
  input  logic          wmb_entry_merge_data_vld_x,

  // Output: entry data
  output logic [PA_WIDTH-1:0] wmb_entry_addr_v,
  output logic [127:0]  wmb_entry_data_v,
  output logic [15:0]   wmb_entry_bytes_vld_v,
  output logic [15:0]   wmb_entry_fwd_bytes_vld_v,

  // Output: entry status
  output logic          wmb_entry_vld_x,
  output logic          wmb_entry_dcache_way_x,

  // Output: merge control
  output logic          wmb_entry_merge_data_addr_hit_x,
  output logic          wmb_entry_merge_data_stall_x,
  output logic          wmb_entry_hit_sq_pop_dcache_line_x,

  // Output: forward control
  output logic          wmb_entry_fwd_req_x,
  output logic          wmb_entry_fwd_data_pe_req_x,
  output logic          wmb_entry_discard_req_x,
  output logic          wmb_entry_cancel_acc_req_x,

  // Output: write request
  output logic          wmb_entry_write_req_x,
  output logic          wmb_entry_write_biu_req_x,
  output logic          wmb_entry_write_dcache_req_x,

  // Output: data request
  output logic          wmb_entry_data_req_x,
  output logic          wmb_entry_data_biu_req_x,
  output logic [3:0]    wmb_entry_biu_id_v,

  // Output: pop control
  output logic          wmb_entry_pop_vld_x,
  output logic          wmb_entry_rb_biu_req_hit_idx,

  output logic          wmb_entry_data_ptr_after_write_shift_imme_x,
  output logic          wmb_entry_write_ptr_unconditional_shift_imme_x
);

  //==========================================================
  //                 Derived Parameters
  //==========================================================
  localparam int CACHELINE_SIZE = 32;
  localparam int NUM_WAYS = 2;
  localparam int OFFSET_WIDTH = 5;
  localparam int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS;
  localparam int INDEX_WIDTH = $clog2(NUM_SETS);
  localparam int INDEX_LSB = OFFSET_WIDTH;
  localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;

  //==========================================================
  //                 Internal Registers
  //==========================================================
  logic                   wmb_entry_vld;
  logic [PA_WIDTH-1:0]    wmb_entry_addr;
  logic [127:0]           wmb_entry_data;
  logic [15:0]            wmb_entry_bytes_vld;
  logic                   wmb_entry_dcache_valid;
  logic                   wmb_entry_dcache_dirty;
  logic                   wmb_entry_dcache_way;
  logic                   wmb_entry_merge_en;
  logic                   wmb_entry_write_req_success;
  logic                   wmb_entry_write_resp;
  logic                   wmb_entry_data_req_success;
  logic [3:0]             wmb_entry_biu_id;
  logic                   wmb_entry_biu_b_id_vld;

  //==========================================================
  //                 Internal Wires
  //==========================================================

  logic                   wmb_entry_create_vld;
  logic                   wmb_entry_create_data_vld;
  logic                   wmb_entry_merge_data_vld;
  logic [3:0]             wmb_entry_create_data;
  logic [3:0]             wmb_entry_merge_data;
  logic [127:0]           wmb_entry_data_next;
  logic [15:0]            wmb_entry_bytes_vld_and;

  logic                   wmb_entry_hit_sq_pop_addr_tto6;
  logic                   wmb_entry_hit_sq_pop_addr_5to4;
  logic                   wmb_entry_hit_sq_pop_addr_tto4;
  logic                   wmb_entry_hit_sq_pop_dcache_line;
  logic                   wmb_entry_merge_data_addr_hit;
  logic                   wmb_entry_merge_data_permit;
  logic                   wmb_entry_merge_data_stall;

  logic                   wmb_entry_depd_addr_tto12_hit;
  logic                   wmb_entry_depd_addr_11to4_hit;
  logic                   wmb_entry_depd_addr1_11to4_hit;
  logic                   wmb_entry_depd_addr_tto4_hit;
  logic                   wmb_entry_depd_addr1_tto4_hit;
  logic [15:0]            wmb_entry_and_ld_dc_bytes_vld;
  logic                   wmb_entry_and_ld_dc_bytes_vld_hit;
  logic                   wmb_entry_depd_do_hit;
  logic [15:0]            wmb_entry_fwd_bytes_vld;
  logic                   wmb_entry_fwd_data_pre;
  logic                   wmb_entry_fwd_data_pe_req;
  logic                   wmb_entry_fwd_req;
  logic                   wmb_entry_discard_req;
  logic                   wmb_entry_cancel_acc_req;

  logic                   wmb_entry_write_req;
  logic                   wmb_entry_write_biu_req;
  logic                   wmb_entry_write_dcache_req;
  logic                   wmb_entry_write_ptr_shift_imme;
  logic                   wmb_entry_write_ptr_unconditional_shift_imme;
  logic                   wmb_entry_write_req_success_set;
  logic                   wmb_entry_write_resp_set;

  logic                   wmb_entry_data_req;
  logic                   wmb_entry_data_biu_req;
  logic                   wmb_entry_data_ptr_after_write_shift_imme;
  logic                   wmb_entry_data_req_success_set;

  logic                   wmb_entry_b_id_hit;
  logic                   wmb_entry_b_resp_vld;
  logic                   wmb_entry_biu_b_id_vld_set;

  logic                   wmb_entry_pop_vld;

  // Dcache status update signals
  logic                   wmb_entry_update_dcache_valid;
  logic                   wmb_entry_update_dcache_dirty;
  logic                   wmb_entry_update_dcache_way;
  logic                   wmb_entry_dcache_update_vld;
  logic                   wmb_entry_dcache_update_vld_unmask;

  logic                   wmb_write_ptr;
  logic                   wmb_data_ptr;
  logic                   wmb_dcache_req_ptr;

  // Assign pointer signals
  assign wmb_write_ptr = wmb_write_ptr_x;
  assign wmb_data_ptr = wmb_data_ptr_x;
  assign wmb_dcache_req_ptr = wmb_dcache_req_ptr_x;
  assign wmb_entry_create_vld = wmb_entry_create_vld_x;
  assign wmb_entry_create_data_vld = wmb_entry_create_data_vld_x;
  assign wmb_entry_merge_data_vld = wmb_entry_merge_data_vld_x;

  //==========================================================
  //                 Registers
  //==========================================================
  // Entry valid
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_vld <= 1'b0;
    else if (wmb_entry_pop_vld)
      wmb_entry_vld <= 1'b0;
    else if (wmb_entry_create_vld)
      wmb_entry_vld <= 1'b1;
  end

  // Entry info
  always_ff @(posedge forever_cpuclk)
  begin
    if (wmb_entry_create_vld)
    begin
      wmb_entry_addr[PA_WIDTH-1:0] <= wmb_ce_addr[PA_WIDTH-1:0];
      wmb_entry_merge_en <= wmb_ce_merge_en;
    end
  end

  // Dcache info
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
    begin
      wmb_entry_dcache_valid <= 1'b0;
      wmb_entry_dcache_dirty <= 1'b0;
      wmb_entry_dcache_way   <= 1'b0;
    end
    else if (wmb_entry_create_vld)
    begin
      wmb_entry_dcache_valid <= wmb_ce_update_dcache_valid;
      wmb_entry_dcache_dirty <= wmb_ce_update_dcache_dirty;
      wmb_entry_dcache_way   <= wmb_ce_update_dcache_way;
    end
    else if (wmb_entry_dcache_update_vld)
    begin
      wmb_entry_dcache_valid <= wmb_entry_update_dcache_valid;
      wmb_entry_dcache_dirty <= wmb_entry_update_dcache_dirty;
      wmb_entry_dcache_way   <= wmb_entry_update_dcache_way;
    end
  end

  // Data and bytes_vld
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
    begin
      wmb_entry_bytes_vld[15:0] <= 16'b0;
    end
    else if (wmb_entry_create_vld)
    begin
      wmb_entry_bytes_vld[15:0] <= wmb_ce_bytes_vld[15:0];
    end
    else if (wmb_entry_merge_data_vld)
    begin
      wmb_entry_bytes_vld[15:0] <= wmb_entry_bytes_vld_and[15:0];
    end
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_data[31:0] <= 32'b0;
    else if (wmb_entry_create_data[0] || wmb_entry_merge_data[0])
      wmb_entry_data[31:0] <= wmb_entry_data_next[31:0];
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_data[63:32] <= 32'b0;
    else if (wmb_entry_create_data[1] || wmb_entry_merge_data[1])
      wmb_entry_data[63:32] <= wmb_entry_data_next[63:32];
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_data[95:64] <= 32'b0;
    else if (wmb_entry_create_data[2] || wmb_entry_merge_data[2])
      wmb_entry_data[95:64] <= wmb_entry_data_next[95:64];
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_data[127:96] <= 32'b0;
    else if (wmb_entry_create_data[3] || wmb_entry_merge_data[3])
      wmb_entry_data[127:96] <= wmb_entry_data_next[127:96];
  end

  // Write success/resp
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_write_req_success <= 1'b0;
    else if (wmb_entry_create_vld)
      wmb_entry_write_req_success <= 1'b0;
    else if (wmb_entry_write_req_success_set)
      wmb_entry_write_req_success <= 1'b1;
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_write_resp <= 1'b0;
    else if (wmb_entry_create_vld)
      wmb_entry_write_resp <= 1'b0;
    else if (wmb_entry_write_resp_set)
      wmb_entry_write_resp <= 1'b1;
  end

  // Data req success
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_data_req_success <= 1'b0;
    else if (wmb_entry_create_vld)
      wmb_entry_data_req_success <= 1'b0;
    else if (wmb_entry_data_req_success_set)
      wmb_entry_data_req_success <= 1'b1;
  end

  // BIU ID
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_biu_id[3:0] <= 4'b0;
    else if (wmb_entry_write_biu_req)
      wmb_entry_biu_id[3:0] <= wmb_biu_aw_id[3:0];
  end

  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_entry_biu_b_id_vld <= 1'b0;
    else if (wmb_entry_create_vld)
      wmb_entry_biu_b_id_vld <= 1'b0;
    else if (wmb_entry_biu_b_id_vld_set)
      wmb_entry_biu_b_id_vld <= 1'b1;
    else if (wmb_entry_b_resp_vld)
      wmb_entry_biu_b_id_vld <= 1'b0;
  end

  //==========================================================
  //                 Create/Merge Logic
  //==========================================================
  // Match at dcache set granularity (INDEX_MSB:INDEX_LSB)
  assign wmb_entry_hit_sq_pop_addr_tto6 = (wmb_entry_addr[PA_WIDTH-1:INDEX_MSB+1] == sq_pop_addr[PA_WIDTH-1:INDEX_MSB+1]);
  assign wmb_entry_hit_sq_pop_addr_5to4 = (wmb_entry_addr[INDEX_LSB-1:4] == sq_pop_addr[INDEX_LSB-1:4]);
  assign wmb_entry_hit_sq_pop_addr_tto4 = wmb_entry_hit_sq_pop_addr_tto6 && wmb_entry_hit_sq_pop_addr_5to4;

  // Dcache line match at set granularity
  assign wmb_entry_hit_sq_pop_dcache_line = (wmb_entry_addr[INDEX_MSB:INDEX_LSB] == sq_pop_addr[INDEX_MSB:INDEX_LSB]) && wmb_entry_vld;

  assign wmb_entry_merge_data_addr_hit = wmb_entry_hit_sq_pop_addr_tto4
                                         && wmb_entry_merge_en
                                         && wmb_entry_vld;

  assign wmb_entry_merge_data_permit = !wmb_entry_write_req_success
                                       && !wmb_entry_data_req_success
                                       && !(wmb_entry_data_req || wmb_dcache_req_ptr);

  assign wmb_entry_merge_data_stall = wmb_entry_merge_data_addr_hit
                                      && !wmb_entry_merge_data_permit;

  assign wmb_entry_merge_data[3:0] = {4{wmb_entry_merge_data_vld}} & wmb_ce_data_vld[3:0];
  assign wmb_entry_create_data[3:0] = {4{wmb_entry_create_data_vld}} & wmb_ce_data_vld[3:0];

  // Merge data byte-by-byte
  assign wmb_entry_data_next[7:0]     = wmb_ce_bytes_vld[0]  ? wmb_ce_data128[7:0]     : wmb_entry_data[7:0];
  assign wmb_entry_data_next[15:8]    = wmb_ce_bytes_vld[1]  ? wmb_ce_data128[15:8]    : wmb_entry_data[15:8];
  assign wmb_entry_data_next[23:16]   = wmb_ce_bytes_vld[2]  ? wmb_ce_data128[23:16]   : wmb_entry_data[23:16];
  assign wmb_entry_data_next[31:24]   = wmb_ce_bytes_vld[3]  ? wmb_ce_data128[31:24]   : wmb_entry_data[31:24];
  assign wmb_entry_data_next[39:32]   = wmb_ce_bytes_vld[4]  ? wmb_ce_data128[39:32]   : wmb_entry_data[39:32];
  assign wmb_entry_data_next[47:40]   = wmb_ce_bytes_vld[5]  ? wmb_ce_data128[47:40]   : wmb_entry_data[47:40];
  assign wmb_entry_data_next[55:48]   = wmb_ce_bytes_vld[6]  ? wmb_ce_data128[55:48]   : wmb_entry_data[55:48];
  assign wmb_entry_data_next[63:56]   = wmb_ce_bytes_vld[7]  ? wmb_ce_data128[63:56]   : wmb_entry_data[63:56];
  assign wmb_entry_data_next[71:64]   = wmb_ce_bytes_vld[8]  ? wmb_ce_data128[71:64]   : wmb_entry_data[71:64];
  assign wmb_entry_data_next[79:72]   = wmb_ce_bytes_vld[9]  ? wmb_ce_data128[79:72]   : wmb_entry_data[79:72];
  assign wmb_entry_data_next[87:80]   = wmb_ce_bytes_vld[10] ? wmb_ce_data128[87:80]   : wmb_entry_data[87:80];
  assign wmb_entry_data_next[95:88]   = wmb_ce_bytes_vld[11] ? wmb_ce_data128[95:88]   : wmb_entry_data[95:88];
  assign wmb_entry_data_next[103:96]  = wmb_ce_bytes_vld[12] ? wmb_ce_data128[103:96]  : wmb_entry_data[103:96];
  assign wmb_entry_data_next[111:104] = wmb_ce_bytes_vld[13] ? wmb_ce_data128[111:104] : wmb_entry_data[111:104];
  assign wmb_entry_data_next[119:112] = wmb_ce_bytes_vld[14] ? wmb_ce_data128[119:112] : wmb_entry_data[119:112];
  assign wmb_entry_data_next[127:120] = wmb_ce_bytes_vld[15] ? wmb_ce_data128[127:120] : wmb_entry_data[127:120];

  assign wmb_entry_bytes_vld_and[15:0] = wmb_entry_bytes_vld[15:0] | wmb_ce_bytes_vld[15:0];

  //==========================================================
  //                 Dependency Check
  //==========================================================
  // Use set granularity for address comparison
  assign wmb_entry_depd_addr_tto12_hit = (wmb_entry_addr[PA_WIDTH-1:INDEX_MSB+1] == ld_dc_addr0[PA_WIDTH-1:INDEX_MSB+1]);
  assign wmb_entry_depd_addr_11to4_hit = (wmb_entry_addr[INDEX_MSB:4] == ld_dc_addr0[INDEX_MSB:4]);
  assign wmb_entry_depd_addr1_11to4_hit = (wmb_entry_addr[INDEX_MSB:4] == ld_dc_addr1_11to4[INDEX_MSB-4:0]);

  assign wmb_entry_depd_addr_tto4_hit = wmb_entry_depd_addr_tto12_hit && wmb_entry_depd_addr_11to4_hit;
  assign wmb_entry_depd_addr1_tto4_hit = wmb_entry_depd_addr_tto12_hit && wmb_entry_depd_addr1_11to4_hit;

  assign wmb_entry_and_ld_dc_bytes_vld[15:0] = wmb_entry_bytes_vld[15:0] & ld_dc_bytes_vld[15:0];
  assign wmb_entry_and_ld_dc_bytes_vld_hit = |wmb_entry_and_ld_dc_bytes_vld[15:0];
  assign wmb_entry_depd_do_hit = wmb_entry_and_ld_dc_bytes_vld_hit;

  assign wmb_entry_fwd_data_pe_req = wmb_entry_vld && wmb_entry_depd_addr_tto4_hit;
  assign wmb_entry_fwd_data_pre = wmb_entry_fwd_data_pe_req && ld_dc_chk_ld_inst_vld;
  assign wmb_entry_fwd_req = wmb_entry_fwd_data_pre && wmb_entry_depd_do_hit;
  assign wmb_entry_fwd_bytes_vld[15:0] = {16{wmb_entry_fwd_data_pre}}
                                         & wmb_entry_and_ld_dc_bytes_vld[15:0];

  assign wmb_entry_discard_req = 1'b0;  // Simplified: no atomic
  assign wmb_entry_cancel_acc_req = wmb_entry_vld && wmb_entry_depd_addr1_tto4_hit;

  //==========================================================
  //                 Write Request Logic
  //==========================================================

  assign wmb_entry_write_req = wmb_entry_vld
                               && wmb_write_ptr
                               && !wmb_entry_write_req_success;

  // Write to BIU if dcache not valid
  assign wmb_entry_write_biu_req = wmb_entry_vld
                                   && wmb_write_ptr
                                   && !wmb_entry_write_req_success
                                   && !wmb_entry_dcache_valid;

  // Write to dcache if valid (regardless of dirty status)
  assign wmb_entry_write_dcache_req = wmb_entry_vld
                                      && !wmb_entry_write_resp
                                      && wmb_entry_dcache_valid
                                      && !wmb_entry_write_req_success;

  assign wmb_entry_write_ptr_unconditional_shift_imme =
      wmb_write_ptr &&
       (!wmb_entry_vld
          || wmb_dcache_req_ptr && wmb_write_dcache_success
          || wmb_entry_write_resp
          || wmb_entry_write_req_success);

  assign wmb_entry_write_req_success_set = !wmb_entry_write_req_success
                                           && (wmb_entry_write_biu_req && bus_arb_wmb_aw_grnt
                                               || wmb_dcache_req_ptr && wmb_write_dcache_success
                                               || wmb_entry_write_ptr_unconditional_shift_imme);

  assign wmb_entry_write_resp_set = !wmb_entry_write_resp
                                    && (wmb_dcache_req_ptr && wmb_write_dcache_success
                                        || wmb_entry_b_resp_vld
                                        || wmb_entry_write_ptr_unconditional_shift_imme & !wmb_entry_write_req_success);

  //==========================================================
  //                 Data Request Logic
  //==========================================================
  assign wmb_entry_data_req = wmb_entry_vld
                              && wmb_data_ptr
                              && !wmb_entry_data_req_success
                              && wmb_entry_write_req_success;

  assign wmb_entry_data_biu_req = wmb_data_ptr
                                  && wmb_entry_write_req_success
                                  && !wmb_entry_data_req_success
                                  && !wmb_entry_write_resp;

  assign wmb_entry_data_ptr_after_write_shift_imme =
      wmb_data_ptr &&
         (!wmb_entry_vld
          || wmb_dcache_req_ptr && wmb_write_dcache_success
          || wmb_entry_write_resp);

  assign wmb_entry_data_req_success_set = wmb_entry_data_biu_req && bus_arb_wmb_w_grnt
                                          || wmb_dcache_req_ptr && wmb_write_dcache_success
                                          || wmb_entry_data_ptr_after_write_shift_imme;

  //==========================================================
  //                 BIU Response
  //==========================================================
  assign wmb_entry_biu_b_id_vld_set = wmb_entry_write_biu_req;

  assign wmb_entry_b_id_hit = biu_lsu_b_vld
                              && wmb_entry_biu_b_id_vld
                              && (wmb_entry_biu_id[3:0] == biu_lsu_b_id[3:0]);

  assign wmb_entry_b_resp_vld = wmb_entry_b_id_hit;

  //==========================================================
  //                 Pop Control
  //==========================================================
  assign wmb_entry_pop_vld = wmb_entry_vld
                             && wmb_entry_write_resp
                             && wmb_entry_data_req_success;

  //==========================================================
  //                 Dcache Info Update Module
  //==========================================================
  // Instantiate module to monitor dcache write port and update status
  lsu_dcache_info_update #(
    .DCACHE_SIZE(DCACHE_SIZE),
    .INDEX_WIDTH(INDEX_WIDTH)
  ) x_lsu_wmb_entry_dcache_info_update (
    .compare_dcwp_addr       (wmb_entry_addr[PA_WIDTH-1:0]        ),
    .dcache_dirty_din        (dcache_dirty_din                    ),
    .dcache_dirty_gwen       (dcache_dirty_gwen                   ),
    .dcache_dirty_wen        (dcache_dirty_wen                    ),
    .dcache_idx              (dcache_idx                          ),
    .dcache_tag_din          (dcache_tag_din                      ),
    .dcache_tag_gwen         (dcache_tag_gwen                     ),
    .dcache_tag_wen          (dcache_tag_wen                      ),
    .origin_dcache_dirty     (wmb_entry_dcache_dirty              ),
    .origin_dcache_valid     (wmb_entry_dcache_valid              ),
    .origin_dcache_way       (wmb_entry_dcache_way                ),
    .compare_dcwp_hit_idx    (                                    ),
    .compare_dcwp_update_vld (wmb_entry_dcache_update_vld_unmask  ),
    .update_dcache_dirty     (wmb_entry_update_dcache_dirty       ),
    .update_dcache_valid     (wmb_entry_update_dcache_valid       ),
    .update_dcache_way       (wmb_entry_update_dcache_way         )
  );

  assign wmb_entry_dcache_update_vld = wmb_entry_vld & wmb_entry_dcache_update_vld_unmask;

  assign wmb_entry_rb_biu_req_hit_idx = wmb_entry_vld & (wmb_entry_addr[INDEX_MSB:5] ==  rb_biu_req_addr[INDEX_MSB:5]);
  //==========================================================
  //                 Output Assignment
  //==========================================================
  assign wmb_entry_addr_v = wmb_entry_addr;
  assign wmb_entry_data_v = wmb_entry_data;
  assign wmb_entry_bytes_vld_v = wmb_entry_bytes_vld;
  assign wmb_entry_fwd_bytes_vld_v = wmb_entry_fwd_bytes_vld;
  assign wmb_entry_biu_id_v = wmb_entry_biu_id;

  assign wmb_entry_vld_x = wmb_entry_vld;
  assign wmb_entry_dcache_way_x = wmb_entry_dcache_way;
  assign wmb_entry_merge_data_addr_hit_x = wmb_entry_merge_data_addr_hit;
  assign wmb_entry_merge_data_stall_x = wmb_entry_merge_data_stall;
  assign wmb_entry_hit_sq_pop_dcache_line_x = wmb_entry_hit_sq_pop_dcache_line;
  assign wmb_entry_fwd_req_x = wmb_entry_fwd_req;
  assign wmb_entry_fwd_data_pe_req_x = wmb_entry_fwd_data_pe_req;
  assign wmb_entry_discard_req_x = wmb_entry_discard_req;
  assign wmb_entry_cancel_acc_req_x = wmb_entry_cancel_acc_req;
  assign wmb_entry_write_req_x = wmb_entry_write_req;
  assign wmb_entry_write_biu_req_x = wmb_entry_write_biu_req;
  assign wmb_entry_write_dcache_req_x = wmb_entry_write_dcache_req;
  assign wmb_entry_data_req_x = wmb_entry_data_req;
  assign wmb_entry_data_biu_req_x = wmb_entry_data_biu_req;
  assign wmb_entry_pop_vld_x = wmb_entry_pop_vld;

 
  assign wmb_entry_write_ptr_unconditional_shift_imme_x = wmb_entry_write_ptr_unconditional_shift_imme;
  assign wmb_entry_data_ptr_after_write_shift_imme_x = wmb_entry_data_ptr_after_write_shift_imme;

endmodule