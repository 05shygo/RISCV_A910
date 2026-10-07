`timescale 1ns/1ps

// Complete Load Pipeline Test with BIU simulation
// Tests load instruction flow through AG -> DC -> DA with BIU response

module tb_load_pipeline;

parameter LSIQ_ENTRY = 12;
parameter DCACHE_SIZE = 2048;
parameter CACHELINE_SIZE = 32;
parameter NUM_WAYS = 2;
parameter OFFSET_WIDTH = 5;
parameter NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS;
parameter INDEX_WIDTH = $clog2(NUM_SETS);

// Clock and reset
logic clk;
logic rst_n;

// IDU to AG inputs
logic idu_lsu_ld_sel;
logic [2:0] idu_lsu_ld_inst_size;
logic idu_lsu_ld_unalign_2nd;
logic idu_lsu_ld_sign_extend;
logic [6:0] idu_lsu_ld_iid;
logic [LSIQ_ENTRY-1:0] idu_lsu_ld_lch_entry;
logic idu_lsu_ld_oldest;
logic [4:0] idu_lsu_ld_preg;
logic [11:0] idu_lsu_ld_offset;
logic [11:0] idu_lsu_ld_offset_plus;
logic [31:0] idu_lsu_ld_src;

// RTU inputs
logic rtu_yy_xx_flush;
logic rtu_yy_xx_commit0;
logic [6:0] rtu_yy_xx_commit0_iid;
logic rtu_yy_xx_commit1;
logic [6:0] rtu_yy_xx_commit1_iid;
logic rtu_yy_xx_commit2;
logic [6:0] rtu_yy_xx_commit2_iid;

// Simulated BIU interface
logic biu_req_valid;
logic [31:0] biu_req_addr;
logic biu_resp_valid;
logic [127:0] biu_resp_data;

// AG to DC signals
logic ld_ag_dc_inst_vld;
logic [1:0] ld_ag_inst_size;
logic ld_ag_secd;
logic ld_ag_sign_extend;
logic [6:0] ld_ag_iid;
logic [LSIQ_ENTRY-1:0] ld_ag_lsid;
logic ld_ag_old;
logic [6:0] ld_ag_preg;
logic ld_ag_boundary;
logic ld_ag_acclr_en;
logic ld_ag_dc_fwd_bypass_en;
logic [15:0] ld_ag_bytes_vld1;
logic [15:0] ld_ag_bytes_vld;
logic ld_ag_raw_new;
logic [27:0] ld_ag_addr1_to4;
logic [31:0] ld_ag_dc_addr0;

// DC outputs
logic ld_dc_da_inst_vld;
logic ld_dc_dcache_hit;
logic [31:0] ld_dc_addr0;
logic [6:0] ld_dc_iid;
logic ld_dc_lq_create_vld;

// Dummy inputs for modules
logic st_ag_iid = 0;
logic dcache_arb_ag_ld_sel = 1;
logic dcache_arb_ld_ag_borrow_addr_vld = 0;
logic [31:0] dcache_arb_ld_ag_addr = 0;
logic [41:0] dcache_lsu_ld_tag_dout = 42'h0;

// Instantiate LD_AG
lsu_ld_ag #(
  .IID_WIDTH(6),
  .LSIQ_ENTRY(LSIQ_ENTRY),
  .DCACHE_SIZE(DCACHE_SIZE)
) u_ld_ag (
  .forever_clk(clk),
  .cpurst_b(rst_n),
  .idu_lsu_ld_sel(idu_lsu_ld_sel),
  .idu_lsu_ld_inst_size(idu_lsu_ld_inst_size),
  .idu_lsu_ld_unalign_2nd(idu_lsu_ld_unalign_2nd),
  .idu_lsu_ld_sign_extend(idu_lsu_ld_sign_extend),
  .idu_lsu_ld_iid(idu_lsu_ld_iid),
  .idu_lsu_ld_lch_entry(idu_lsu_ld_lch_entry),
  .idu_lsu_ld_oldest(idu_lsu_ld_oldest),
  .idu_lsu_ld_preg(idu_lsu_ld_preg),
  .idu_lsu_ld_offset(idu_lsu_ld_offset),
  .idu_lsu_ld_offset_plus(idu_lsu_ld_offset_plus),
  .idu_lsu_ld_src(idu_lsu_ld_src),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .rtu_yy_xx_commit0(rtu_yy_xx_commit0),
  .rtu_yy_xx_commit0_iid(rtu_yy_xx_commit0_iid),
  .rtu_yy_xx_commit1(rtu_yy_xx_commit1),
  .rtu_yy_xx_commit1_iid(rtu_yy_xx_commit1_iid),
  .rtu_yy_xx_commit2(rtu_yy_xx_commit2),
  .rtu_yy_xx_commit2_iid(rtu_yy_xx_commit2_iid),
  .st_ag_iid(st_ag_iid),
  .dcache_arb_ag_ld_sel(dcache_arb_ag_ld_sel),
  .dcache_arb_ld_ag_borrow_addr_vld(dcache_arb_ld_ag_borrow_addr_vld),
  .dcache_arb_ld_ag_addr(dcache_arb_ld_ag_addr),
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
  .ld_ag_bytes_vld1(ld_ag_bytes_vld1),
  .ld_ag_bytes_vld(ld_ag_bytes_vld),
  .ld_ag_raw_new(ld_ag_raw_new),
  .ld_ag_addr1_to4(ld_ag_addr1_to4),
  .ld_ag_dc_addr0(ld_ag_dc_addr0),
  .ag_dcache_arb_ld_data_high_idx(),
  .ag_dcache_arb_ld_data_low_idx(),
  .ag_dcache_arb_ld_data_req(),
  .ag_dcache_arb_ld_data_gateclk_en(),
  .ag_dcache_arb_ld_tag_idx(),
  .ag_dcache_arb_ld_tag_req(),
  .ag_dcache_arb_ld_tag_gateclk_en(),
  .ag_dcache_arb_ld_gateclk_en()
);

// Instantiate LD_DC (simplified connections)
lsu_ld_dc #(
  .IID_WIDTH(6),
  .LSIQ_ENTRY(LSIQ_ENTRY),
  .DCACHE_SIZE(DCACHE_SIZE)
) u_ld_dc (
  .forever_clk(clk),
  .cpurst_b(rst_n),
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
  .ld_ag_bytes_vld1(ld_ag_bytes_vld1),
  .ld_ag_bytes_vld(ld_ag_bytes_vld),
  .ld_ag_raw_new(ld_ag_raw_new),
  .ld_ag_addr1_to4(ld_ag_addr1_to4),
  .ld_ag_dc_addr0(ld_ag_dc_addr0),
  .st_dc_chk_st_inst_vld(1'b0),
  .st_dc_bytes_vld(16'b0),
  .st_dc_addr0(32'b0),
  .lq_ld_dc_inst_hit(1'b0),
  .lq_ld_dc_full(1'b0),
  .lq_ld_dc_less2(1'b0),
  .dcache_idx({INDEX_WIDTH{1'b0}}),
  .dcache_arb_ld_dc_borrow_vld(1'b0),
  .dcache_lsu_ld_tag_dout(dcache_lsu_ld_tag_dout),
  .cb_ld_dc_addr_hit(1'b0),
  .sq_ld_dc_cancel_acc_req(1'b0),
  .sq_ld_dc_fwd_req(1'b0),
  .wmb_ld_dc_cancel_acc_req(1'b0),
  .wmb_ld_dc_fwd_req(1'b0),
  .wmb_fwd_bytes_vld(16'b0),
  .rtu_yy_xx_flush(rtu_yy_xx_flush),
  .sq_ld_dc_addr1_dep_discard(1'b0),
  .ld_dc_da_inst_vld(ld_dc_da_inst_vld),
  .ld_dc_iid(ld_dc_iid),
  .ld_dc_addr0(ld_dc_addr0),
  .ld_dc_dcache_hit(ld_dc_dcache_hit),
  .ld_dc_lq_create_vld(ld_dc_lq_create_vld),
  .ld_dc_borrow_vld(),
  .ld_dc_inst_size(),
  .ld_dc_addr1_to4(),
  .ld_dc_boundary(),
  .ld_dc_secd(),
  .ld_dc_sign_extend(),
  .ld_dc_lsid(),
  .ld_dc_old(),
  .ld_dc_preg(),
  .ld_dc_bytes_vld(),
  .ld_dc_bytes_vld1(),
  .ld_dc_acclr_en(),
  .ld_dc_da_cb_merge_en(),
  .ld_dc_raw_new(),
  .ld_dc_cb_addr_create_vld(),
  .ld_dc_cb_addr_tto4(),
  .ld_dc_chk_ld_inst_vld(),
  .ld_dc_chk_ld_addr1_vld(),
  .ld_dc_chk_ld_bypass_vld(),
  .ld_dc_idu_lq_full(),
  .ld_dc_imme_wakeup(),
  .ld_dc_hit_low_region(),
  .ld_dc_hit_high_region(),
  .ld_dc_da_data_rot_sel(),
  .ld_dc_preg_sign_sel(),
  .ld_dc_fwd_bytes_vld(),
  .ld_dc_fwd_sq_vld(),
  .ld_dc_fwd_wmb_vld(),
  .ld_dc_lq_create1_vld()
);

// BIU request monitor
always_ff @(posedge clk) begin
  if (ld_dc_da_inst_vld && !ld_dc_dcache_hit) begin
    biu_req_valid <= 1'b1;
    biu_req_addr <= ld_dc_addr0;
  end else begin
    biu_req_valid <= 1'b0;
  end
end

// BIU response simulation
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    biu_resp_valid <= 1'b0;
    biu_resp_data <= 128'h0;
  end else if (biu_req_valid) begin
    // Simulate BIU delay - respond after 10 cycles
    repeat(10) @(posedge clk);
    biu_resp_valid <= 1'b1;
    biu_resp_data <= 128'hDEADBEEF_CAFEBABE_12345678_ABCD1000;
    @(posedge clk);
    biu_resp_valid <= 1'b0;
  end
end

// Clock generation
initial begin
  clk = 0;
  forever #5 clk = ~clk;
end

// Test stimulus
initial begin
  // Initialize
  rst_n = 0;
  idu_lsu_ld_sel = 0;
  idu_lsu_ld_inst_size = 0;
  idu_lsu_ld_unalign_2nd = 0;
  idu_lsu_ld_sign_extend = 0;
  idu_lsu_ld_iid = 0;
  idu_lsu_ld_lch_entry = 0;
  idu_lsu_ld_oldest = 0;
  idu_lsu_ld_preg = 0;
  idu_lsu_ld_offset = 0;
  idu_lsu_ld_offset_plus = 0;
  idu_lsu_ld_src = 0;
  rtu_yy_xx_flush = 0;
  rtu_yy_xx_commit0 = 0;
  rtu_yy_xx_commit0_iid = 0;
  rtu_yy_xx_commit1 = 0;
  rtu_yy_xx_commit1_iid = 0;
  rtu_yy_xx_commit2 = 0;
  rtu_yy_xx_commit2_iid = 0;

  // Reset
  repeat(10) @(posedge clk);
  rst_n = 1;
  repeat(5) @(posedge clk);

  $display("=== Test 1: Load MISS - Address 0x1000 ==>");
  @(posedge clk);
  idu_lsu_ld_sel = 1;
  idu_lsu_ld_inst_size = 3'b010;  // Word
  idu_lsu_ld_sign_extend = 0;
  idu_lsu_ld_iid = 7'h01;
  idu_lsu_ld_lch_entry = 12'h001;
  idu_lsu_ld_oldest = 1;
  idu_lsu_ld_preg = 5'd1;
  idu_lsu_ld_offset = 12'h000;
  idu_lsu_ld_src = 32'h0000_1000;

  @(posedge clk);
  idu_lsu_ld_sel = 0;

  repeat(5) @(posedge clk);
  if (!ld_dc_dcache_hit)
    $display("[%0t] MISS detected: addr=0x%h", $time, ld_dc_addr0);

  // Wait for BIU response
  wait(biu_resp_valid);
  $display("[%0t] BIU response: data=0x%h", $time, biu_resp_data);

  repeat(10) @(posedge clk);

  // Issue commit
  $display("=== Issuing RTU commit for IID=0x01 ===");
  @(posedge clk);
  rtu_yy_xx_commit0 = 1;
  rtu_yy_xx_commit0_iid = 7'h01;

  @(posedge clk);
  rtu_yy_xx_commit0 = 0;

  repeat(10) @(posedge clk);

  $display("=== Test 2: Load HIT - Address 0x1004 (same cacheline) ===");
  // Set valid tag for hit
  dcache_lsu_ld_tag_dout = {1'b0, 20'h00000, 1'b1, 20'h00008};

  @(posedge clk);
  idu_lsu_ld_sel = 1;
  idu_lsu_ld_inst_size = 3'b010;
  idu_lsu_ld_sign_extend = 0;
  idu_lsu_ld_iid = 7'h02;
  idu_lsu_ld_lch_entry = 12'h002;
  idu_lsu_ld_oldest = 1;
  idu_lsu_ld_preg = 5'd2;
  idu_lsu_ld_offset = 12'h000;
  idu_lsu_ld_src = 32'h0000_1004;

  @(posedge clk);
  idu_lsu_ld_sel = 0;

  repeat(5) @(posedge clk);
  if (ld_dc_dcache_hit)
    $display("[%0t] HIT detected: addr=0x%h", $time, ld_dc_addr0);

  // Issue commit
  $display("=== Issuing RTU commit for IID=0x02 ===");
  @(posedge clk);
  rtu_yy_xx_commit0 = 1;
  rtu_yy_xx_commit0_iid = 7'h02;

  @(posedge clk);
  rtu_yy_xx_commit0 = 0;

  repeat(20) @(posedge clk);

  $display("=== Simulation Complete ===");
  $finish;
end

endmodule
