// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for rv32_ifu_l0_btb.
//
// The SoC regression cannot reach the L0 BTB update corner cases: with the BHT
// untrained, update_taken is 1 only for JAL/JALR, so a conditional branch never
// arms an entry and the kill path never fires. This bench drives the module
// directly and asserts on the entry state, so the C910 three-state write
// semantics (allocate / raise / kill / hold) are actually covered.
//
// Run:
//   vcs -full64 -sverilog -timescale=1ns/1ps +v2k -f rtl/files.f \
//       tb/tb_l0_btb.sv -o /tmp/tb_l0 -Mdir=/tmp/tb_l0_csrc && /tmp/tb_l0

`timescale 1ns/1ps

module tb_l0_btb;

  reg         forever_cpuclk;
  reg         cpurst_b;
  reg         enable;
  reg         invalidate;
  reg         lookup_vld;
  reg  [31:0] lookup_pc;
  reg         cancel;
  reg         ras_valid;
  reg  [31:0] ras_target;
  wire        hit;
  wire [ 3:0] hit_index;
  wire [ 1:0] hit_slot;
  wire [ 2:0] hit_type;
  wire [31:0] target;
  wire [ 1:0] way_hint;

  reg         update_vld;
  reg  [31:0] update_pc;
  reg  [31:0] update_target;
  reg  [ 2:0] update_type;
  reg         update_taken;
  reg         update_ras;
  reg  [ 1:0] update_way;
  reg         directed_inv_vld;
  reg  [15:0] directed_inv_mask;

  integer errors = 0;
  integer entry;
  integer found;

  rv32_ifu_l0_btb dut (
    .forever_cpuclk   (forever_cpuclk  ),
    .cpurst_b         (cpurst_b        ),
    .enable           (enable          ),
    .invalidate       (invalidate      ),
    .lookup_vld       (lookup_vld      ),
    .lookup_pc        (lookup_pc       ),
    .cancel           (cancel          ),
    .ras_valid        (ras_valid       ),
    .ras_target       (ras_target      ),
    .hit              (hit             ),
    .hit_index        (hit_index       ),
    .hit_slot         (hit_slot        ),
    .hit_type         (hit_type        ),
    .target           (target          ),
    .way_hint         (way_hint        ),
    .update_vld       (update_vld      ),
    .update_pc        (update_pc       ),
    .update_target    (update_target   ),
    .update_type      (update_type     ),
    .update_taken     (update_taken    ),
    // P0-1: update_cnt_lo = 预测当时 BHT 计数器低位。本自检台只造"强 taken"
    // 场景 (update_taken=1 即视为 2'b11), 所以恒接 update_taken。
    .update_cnt_lo    (update_taken    ),
    .update_ras      (update_ras      ),
    .update_way       (update_way      ),
    .directed_inv_vld (directed_inv_vld),
    .directed_inv_mask(directed_inv_mask)
  );

  initial forever_cpuclk = 0;
  always #5 forever_cpuclk = ~forever_cpuclk;

  task check(input cond, input [255:0] what);
    begin
      if (cond !== 1'b1) begin
        errors = errors + 1;
        $display("FAIL: %0s  (pc=%h hit=%b target=%h cnt=%b fifo=%h)",
                 what, update_pc, hit, target, dut.entry_cnt, dut.entry_fifo_q);
      end
    end
  endtask

  task tick;
    begin
      @(posedge forever_cpuclk); #1;
    end
  endtask

  // Drive one training event for exactly one clock.
  task train(input [31:0] pc, input [31:0] dst, input [2:0] kind, input taken, input ras);
    begin
      update_pc = pc; update_target = dst; update_type = kind;
      update_taken = taken; update_ras = ras; update_way = 2'b01;
      update_vld = 1;
      tick;
      update_vld = 0;
      update_taken = 1;
    end
  endtask

  // Index of the entry holding src == pc, or -1.
  function integer find_entry(input [31:0] pc);
    integer i;
    begin
      find_entry = -1;
      for (i = 0; i < 16; i = i + 1)
        if (dut.entry_vld[i] && dut.entry_src[i] == pc) find_entry = i;
    end
  endfunction

  // Combinational hit for pc, sampled before a clock edge.
  task expect_hit(input [31:0] pc, input exp_hit, input [31:0] exp_target, input [255:0] what);
    begin
      lookup_vld = 1; lookup_pc = pc; #1;
      check(hit === exp_hit, what);
      if (exp_hit) check(target === exp_target, what);
      lookup_vld = 0; #1;
    end
  endtask

  initial begin
    cpurst_b = 0; enable = 1; invalidate = 0; lookup_vld = 0; lookup_pc = 0;
    cancel = 0; ras_valid = 0; ras_target = 0;
    update_vld = 0; update_pc = 0; update_target = 0; update_type = 0;
    update_taken = 1; update_ras = 0; update_way = 0;
    directed_inv_vld = 0; directed_inv_mask = 0;
    tick; tick;
    cpurst_b = 1;
    tick;

    // ---------------------------------------------------------------
    // 1. Allocate a taken entry: valid, counter armed, lookup hits.
    // ---------------------------------------------------------------
    train(32'h80000000, 32'h90000000, 3'd2, 1'b1, 1'b0);
    entry = find_entry(32'h80000000);
    check(entry >= 0, "alloc: entry present");
    entry = (entry < 0) ? 0 : entry;
    check(dut.entry_cnt[entry] === 1'b1, "alloc taken: counter armed");
    check(dut.entry_vld[entry] === 1'b1, "alloc taken: valid");
    expect_hit(32'h80000000, 1'b1, 32'h90000000, "alloc taken: lookup hits");

    // The allocation FIFO advanced exactly once.
    check(dut.entry_fifo_q === 16'h0002, "alloc: fifo advanced once");

    // ---------------------------------------------------------------
    // 2. Hit with !taken on an armed entry -> KILL (C910 not_saturate).
    //    The entry must disappear, not merely be disarmed.
    // ---------------------------------------------------------------
    train(32'h80000000, 32'h90000000, 3'd2, 1'b0, 1'b0);
    check(dut.entry_vld[entry] === 1'b0, "kill: entry deleted");
    expect_hit(32'h80000000, 1'b0, 32'h0, "kill: lookup misses");
    // A kill is not an allocation, so the FIFO must not move.
    check(dut.entry_fifo_q === 16'h0002, "kill: fifo held");

    // ---------------------------------------------------------------
    // 3. Fresh entry trained !taken -> allocated but disarmed (counter 0),
    //    so it is present yet cannot redirect.
    // ---------------------------------------------------------------
    train(32'h80000010, 32'h90000010, 3'd1, 1'b0, 1'b0);
    entry = find_entry(32'h80000010);
    check(entry >= 0, "alloc ntaken: entry present");
    entry = (entry < 0) ? 0 : entry;
    check(dut.entry_vld[entry] === 1'b1, "alloc ntaken: valid");
    check(dut.entry_cnt[entry] === 1'b0, "alloc ntaken: counter clear");
    expect_hit(32'h80000010, 1'b0, 32'h0, "alloc ntaken: disarmed entry does not hit");
    check(dut.entry_fifo_q === 16'h0004, "alloc ntaken: fifo advanced");

    // ---------------------------------------------------------------
    // 4. Hit with !taken on a DISARMED entry -> HOLD: no write at all.
    //    The counter must not be written, the FIFO must not move.
    // ---------------------------------------------------------------
    train(32'h80000010, 32'h90000010, 3'd1, 1'b0, 1'b0);
    check(dut.entry_vld[entry] === 1'b1, "hold: entry still valid");
    check(dut.entry_cnt[entry] === 1'b0, "hold: counter untouched");
    check(dut.entry_fifo_q === 16'h0004, "hold: fifo held");

    // ---------------------------------------------------------------
    // 5. Hit with taken -> RAISE the counter and refresh the payload.
    // ---------------------------------------------------------------
    train(32'h80000010, 32'h90000020, 3'd1, 1'b1, 1'b0);
    check(dut.entry_cnt[entry] === 1'b1, "raise: counter set");
    check(dut.entry_dst[entry] === 32'h90000020, "raise: payload refreshed");
    expect_hit(32'h80000010, 1'b1, 32'h90000020, "raise: lookup hits with new target");
    check(dut.entry_fifo_q === 16'h0004, "raise: fifo held");

    // A subsequent !taken on the now-armed entry kills it (counter only rises
    // until the entry is deleted).
    train(32'h80000010, 32'h90000020, 3'd1, 1'b0, 1'b0);
    check(dut.entry_vld[entry] === 1'b0, "raise then ntaken: killed");

    // ---------------------------------------------------------------
    // 6. Directed invalidation beats a same-cycle update to the same entry.
    // ---------------------------------------------------------------
    train(32'h80000030, 32'h90000030, 3'd3, 1'b1, 1'b0);
    entry = find_entry(32'h80000030);
    check(entry >= 0, "dirinv: entry present");
    entry = (entry < 0) ? 0 : entry;
    update_pc = 32'h80000030; update_target = 32'h90000040; update_type = 3'd3;
    update_taken = 1'b1; update_ras = 1'b0; update_way = 2'b01; update_vld = 1'b1;
    directed_inv_vld = 1'b1; directed_inv_mask = (16'h0001 << entry);
    tick;
    update_vld = 0; directed_inv_vld = 0;
    check(dut.entry_vld[entry] === 1'b0, "dirinv: invalidation wins over update");
    expect_hit(32'h80000030, 1'b0, 32'h0, "dirinv: lookup misses");

    // ---------------------------------------------------------------
    // 7. Return entries take the RAS top as target, and need it to be usable.
    // ---------------------------------------------------------------
    train(32'h80000050, 32'h0, 3'd3, 1'b1, 1'b1);
    entry = find_entry(32'h80000050);
    entry = (entry < 0) ? 0 : entry;
    check(dut.entry_ras[entry] === 1'b1, "ras: entry flagged");
    ras_valid = 1; ras_target = 32'habcde000;
    expect_hit(32'h80000050, 1'b1, 32'habcde000, "ras: target from ras top");
    ras_valid = 0;
    expect_hit(32'h80000050, 1'b0, 32'h0, "ras: unusable stack top blocks return");
    ras_valid = 1; ras_target = 32'habcde002;
    expect_hit(32'h80000050, 1'b0, 32'h0, "ras: misaligned target blocks return");
    ras_valid = 0;

    // ---------------------------------------------------------------
    // 8. Global invalidation clears the whole table and restarts the FIFO.
    // ---------------------------------------------------------------
    invalidate = 1; tick; invalidate = 0;
    check(dut.entry_vld === 16'h0000, "invalidate: table empty");
    check(dut.entry_fifo_q === 16'h0001, "invalidate: fifo restarted");

    if (errors == 0) $display("PASS tb_l0_btb: C910 three-state write semantics");
    else             $display("FAIL tb_l0_btb: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL tb_l0_btb: timeout");
    $finish;
  end

endmodule
