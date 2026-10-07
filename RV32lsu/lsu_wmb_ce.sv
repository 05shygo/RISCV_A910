// Simplified WMB Create Entry for RV32I
// - 32-bit address, 32-byte cacheline (2x128bit)
// - Removed: page attributes, shared, normal access, icc, fence, sync
// - Keep: basic merge logic, address comparison

module lsu_wmb_ce #(
  parameter int PA_WIDTH  = 32,
  parameter int SQ_ENTRY  = 6,
  parameter int WMB_ENTRY = 4
)(
  input  logic                 cpurst_b,
  input  logic                 forever_cpuclk,
  input  logic                 rtu_lsu_async_flush,
  input  logic                 sq_wmb_merge_stall_req,
  input  logic [PA_WIDTH-1:0]  sq_pop_addr,
  input  logic [15:0]          sq_pop_bytes_vld,
  input  logic [SQ_ENTRY-1:0]  sq_pop_ptr,
  input  logic                 wmb_ce_create_vld,
  input  logic                 wmb_ce_create_merge,
  input  logic [WMB_ENTRY-1:0] wmb_ce_create_merge_ptr,
  input  logic                 wmb_ce_create_stall,
  input  logic                 wmb_ce_dcache_dirty,
  input  logic                 wmb_ce_dcache_valid,
  input  logic                 wmb_ce_pop_vld,
  input  logic [WMB_ENTRY-1:0] wmb_entry_vld,
  input  logic                 rb_wmb_ce_hit_idx,

  output logic [PA_WIDTH-1:0]  wmb_ce_addr,
  output logic [15:0]          wmb_ce_bytes_vld,
  output logic                 wmb_ce_create_wmb_data_req,
  output logic                 wmb_ce_create_wmb_req,
  output logic [3:0]           wmb_ce_data_vld,
  output logic                 wmb_ce_merge_data_addr_hit,
  output logic                 wmb_ce_merge_data_stall,
  output logic                 wmb_ce_merge_en,
  output logic [WMB_ENTRY-1:0] wmb_ce_merge_ptr,
  output logic                 wmb_ce_merge_wmb_req,
  output logic                 wmb_ce_merge_wmb_wait_not_vld_req,
  output logic [WMB_ENTRY-1:0] wmb_ce_same_dcache_line,
  output logic [SQ_ENTRY-1:0]  wmb_ce_sq_ptr,
  output logic                 wmb_ce_vld,
  output logic                 wmb_ce_write_biu_req,
  output logic                 wmb_ce_write_dcache_req
);

  logic                 wmb_ce_merge;
  logic                 wmb_ce_merge_not_vld;
  logic [WMB_ENTRY-1:0] wmb_ce_merge_ptr_and_not_vld;
  logic                 wmb_ce_stall;
  logic                 wmb_ce_hit_sq_pop_addr_5to4;
  logic                 wmb_ce_hit_sq_pop_addr_tto4;
  logic                 wmb_ce_hit_sq_pop_addr_tto6;
  logic                 wmb_ce_hit_rb_idx;
  logic                 wmb_ce_hit_rb_idx_ff;
  logic                 wmb_ce_hit_rb_idx_set;

  // Valid register
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
      wmb_ce_vld <= 1'b0;
    else if (rtu_lsu_async_flush)
      wmb_ce_vld <= 1'b0;
    else if (wmb_ce_create_vld)
      wmb_ce_vld <= 1'b1;
    else if (wmb_ce_pop_vld)
      wmb_ce_vld <= 1'b0;
  end

  // Address, bytes_vld, inst_size, sq_ptr registers
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
    begin
      wmb_ce_addr      <= '0;
      wmb_ce_bytes_vld <= '0;
      wmb_ce_sq_ptr    <= '0;
    end
    else if (wmb_ce_create_vld)
    begin
      wmb_ce_addr      <= sq_pop_addr;
      wmb_ce_bytes_vld <= sq_pop_bytes_vld;
      wmb_ce_sq_ptr    <= sq_pop_ptr;
    end
  end

  // Merge and stall info
  always_ff @(posedge forever_cpuclk or negedge cpurst_b)
  begin
    if (!cpurst_b)
    begin
      wmb_ce_merge     <= 1'b0;
      wmb_ce_stall     <= 1'b0;
      wmb_ce_merge_ptr <= '0;
    end
    else if (wmb_ce_create_vld)
    begin
      wmb_ce_merge     <= wmb_ce_create_merge;
      wmb_ce_stall     <= wmb_ce_create_stall;
      wmb_ce_merge_ptr <= wmb_ce_create_merge_ptr;
    end
  end
//+------------+
//| hit rb idx |
//+------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    wmb_ce_hit_rb_idx       <=  1'b0;
  else if(wmb_ce_create_vld)
    wmb_ce_hit_rb_idx       <= sq_wmb_merge_stall_req;
  else if(wmb_ce_vld)
    wmb_ce_hit_rb_idx       <=  wmb_ce_hit_rb_idx_set;
end

//+---------------+
//| hit rb idx ff |
//+---------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    wmb_ce_hit_rb_idx_ff    <=  1'b0;
  else if(wmb_ce_create_vld)
    wmb_ce_hit_rb_idx_ff    <=  sq_wmb_merge_stall_req;
  else if(wmb_ce_vld)
    wmb_ce_hit_rb_idx_ff    <=  wmb_ce_hit_rb_idx;
end

assign wmb_ce_hit_rb_idx_set  = wmb_ce_hit_rb_idx
                                &&  rb_wmb_ce_hit_idx;

  // Merge logic
  assign wmb_ce_merge_ptr_and_not_vld = wmb_ce_merge_ptr & ~wmb_entry_vld;
  assign wmb_ce_merge_not_vld = |wmb_ce_merge_ptr_and_not_vld;

  assign wmb_ce_merge_wmb_req = wmb_ce_vld
                                && wmb_ce_merge
                                && !wmb_ce_stall;

  assign wmb_ce_merge_wmb_wait_not_vld_req = wmb_ce_vld
                                             && wmb_ce_merge
                                             && wmb_ce_stall;

  assign wmb_ce_create_wmb_req = wmb_ce_vld
                                 &&  !wmb_ce_hit_rb_idx_ff
                                 && (!wmb_ce_merge || wmb_ce_merge_not_vld);

  assign wmb_ce_create_wmb_data_req = wmb_ce_vld
                                      && (!wmb_ce_merge || wmb_ce_stall);

  // Data valid per 32-bit word
  assign wmb_ce_data_vld[0] = |wmb_ce_bytes_vld[3:0];
  assign wmb_ce_data_vld[1] = |wmb_ce_bytes_vld[7:4];
  assign wmb_ce_data_vld[2] = |wmb_ce_bytes_vld[11:8];
  assign wmb_ce_data_vld[3] = |wmb_ce_bytes_vld[15:12];

  // Write destination: dcache if valid, otherwise BIU
  assign wmb_ce_write_dcache_req = wmb_ce_dcache_valid && !wmb_ce_dcache_dirty;
  assign wmb_ce_write_biu_req = !wmb_ce_dcache_valid || wmb_ce_dcache_dirty;

  assign wmb_ce_merge_en = 1'b1;

  // Address comparison for cacheline (bit [31:5] for 32-byte line)
  assign wmb_ce_hit_sq_pop_addr_tto6 = (wmb_ce_addr[PA_WIDTH-1:6] == sq_pop_addr[PA_WIDTH-1:6]);
  assign wmb_ce_hit_sq_pop_addr_5to4 = (wmb_ce_addr[5:4] == sq_pop_addr[5:4]);
  assign wmb_ce_hit_sq_pop_addr_tto4 = wmb_ce_hit_sq_pop_addr_tto6 && wmb_ce_hit_sq_pop_addr_5to4;

  assign wmb_ce_merge_data_addr_hit = wmb_ce_hit_sq_pop_addr_tto4 && wmb_ce_vld;
  assign wmb_ce_merge_data_stall = 1'b0;

endmodule
