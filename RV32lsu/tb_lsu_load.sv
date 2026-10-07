`timescale 1ns/1ps

module tb_lsu_load;

// Parameters
parameter int DCACHE_SIZE = 2048;
parameter int LSIQ_ENTRY  = 12;
parameter int SQ_ENTRY    = 6;
parameter int WMB_ENTRY   = 4;
parameter int LFB_ADDR_ENTRY = 3;
parameter int LFB_DATA_ENTRY = 1;

// Clock and reset
logic clk;
logic rst_n;

// IDU to LSU - Load interface
logic                 idu_lsu_ld_sel;
logic [2:0]           idu_lsu_ld_inst_size;
logic                 idu_lsu_ld_unalign_2nd;
logic                 idu_lsu_ld_sign_extend;
logic [6:0]           idu_lsu_ld_iid;
logic [LSIQ_ENTRY-1:0] idu_lsu_ld_lch_entry;
logic                 idu_lsu_ld_oldest;
logic [4:0]           idu_lsu_ld_preg;
logic [11:0]          idu_lsu_ld_offset;
logic [11:0]          idu_lsu_ld_offset_plus;
logic [31:0]          idu_lsu_ld_src;

// RTU interface
logic                 rtu_yy_xx_flush;
logic                 rtu_yy_xx_commit0;
logic [6:0]           rtu_yy_xx_commit0_iid;
logic                 rtu_yy_xx_commit1;
logic [6:0]           rtu_yy_xx_commit1_iid;
logic                 rtu_yy_xx_commit2;
logic [6:0]           rtu_yy_xx_commit2_iid;

// BIU interface
logic                 bus_arb_rb_ar_grnt;

// LSU outputs
logic                 ld_dc_idu_lq_full;
logic                 ld_dc_imme_wakeup;
logic                 lsu_idu_lq_not_full;
logic                 lsu_rtu_wb_pipe4_cmplt;
logic                 lsu_rtu_wb_pipe4_flush;
logic [6:0]           lsu_rtu_wb_pipe4_iid;
logic                 lsu_rtu_wb_pipe4_spec_fail;
logic                 sq_data_depd_wakeup;
logic                 sq_global_depd_wakeup;

// Clock generation
initial begin
    clk = 0;
    forever #5 clk = ~clk;
end

// DUT instantiation
lsu_top #(
    .DCACHE_SIZE(DCACHE_SIZE),
    .LSIQ_ENTRY(LSIQ_ENTRY),
    .SQ_ENTRY(SQ_ENTRY),
    .WMB_ENTRY(WMB_ENTRY),
    .LFB_ADDR_ENTRY(LFB_ADDR_ENTRY),
    .LFB_DATA_ENTRY(LFB_DATA_ENTRY)
) dut (
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
    .bus_arb_rb_ar_grnt(bus_arb_rb_ar_grnt),
    .ld_dc_idu_lq_full(ld_dc_idu_lq_full),
    .ld_dc_imme_wakeup(ld_dc_imme_wakeup),
    .lsu_idu_lq_not_full(lsu_idu_lq_not_full),
    .lsu_rtu_wb_pipe4_cmplt(lsu_rtu_wb_pipe4_cmplt),
    .lsu_rtu_wb_pipe4_flush(lsu_rtu_wb_pipe4_flush),
    .lsu_rtu_wb_pipe4_iid(lsu_rtu_wb_pipe4_iid),
    .lsu_rtu_wb_pipe4_spec_fail(lsu_rtu_wb_pipe4_spec_fail),
    .sq_data_depd_wakeup(sq_data_depd_wakeup),
    .sq_global_depd_wakeup(sq_global_depd_wakeup)
);

// Initialize signals
initial begin
    // Initialize inputs
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
    bus_arb_rb_ar_grnt = 1;

    // Reset
    #20;
    rst_n = 1;
    #20;

    $display("=== Starting LSU Load Tests ===");

    // Test 1: Load MISS in dcache
    $display("\n--- Test 1: Load MISS ---");
    test_load_miss();

    #100;

    // Test 2: Load HIT in dcache
    $display("\n--- Test 2: Load HIT ---");
    test_load_hit();

    #200;
    $display("\n=== All Tests Completed ===");
    $finish;
end

// Test load miss scenario
task test_load_miss();
    begin
        @(posedge clk);

        // Issue load instruction to address that's not in dcache
        idu_lsu_ld_sel = 1;
        idu_lsu_ld_inst_size = 3'b010; // Word access
        idu_lsu_ld_unalign_2nd = 0;
        idu_lsu_ld_sign_extend = 0;
        idu_lsu_ld_iid = 7'h10;
        idu_lsu_ld_lch_entry = 12'h001;
        idu_lsu_ld_oldest = 0;
        idu_lsu_ld_preg = 5'd1;
        idu_lsu_ld_offset = 12'h000;
        idu_lsu_ld_offset_plus = 12'h004;
        idu_lsu_ld_src = 32'h0000_1000; // Base address

        @(posedge clk);
        idu_lsu_ld_sel = 0;

        $display("  Issued load to address 0x%h (expected MISS)", idu_lsu_ld_src);

        // Wait for response
        repeat(10) @(posedge clk);
    end
endtask

// Test load hit scenario
task test_load_hit();
    begin
        @(posedge clk);

        // Issue load instruction to same address (should hit after first access)
        idu_lsu_ld_sel = 1;
        idu_lsu_ld_inst_size = 3'b010; // Word access
        idu_lsu_ld_unalign_2nd = 0;
        idu_lsu_ld_sign_extend = 0;
        idu_lsu_ld_iid = 7'h20;
        idu_lsu_ld_lch_entry = 12'h002;
        idu_lsu_ld_oldest = 0;
        idu_lsu_ld_preg = 5'd2;
        idu_lsu_ld_offset = 12'h000;
        idu_lsu_ld_offset_plus = 12'h004;
        idu_lsu_ld_src = 32'h0000_1000; // Same address as before

        @(posedge clk);
        idu_lsu_ld_sel = 0;

        $display("  Issued load to address 0x%h (expected HIT)", idu_lsu_ld_src);

        // Wait for response
        repeat(10) @(posedge clk);
    end
endtask

// Waveform dumping
initial begin
    $dumpfile("tb_lsu_load.vcd");
    $dumpvars(0, tb_lsu_load);
end

endmodule
