integer n;
integer a;
integer b;
integer seed = 32'h27182818;
integer random_value;
integer covers_lookup = 0;
integer covers_update = 0;
integer covers_overlap = 0;

initial forever_cpuclk = 0;
always #5 forever_cpuclk = ~forever_cpuclk;
initial begin #3000000; $fatal(1,"L0 test timeout"); end

task tick;
  begin
    #1; compare;
    @(posedge forever_cpuclk); #1; compare;
    @(negedge forever_cpuclk); #1; compare;
  end
endtask

task check(input condition, input [511:0] text);
  begin
    if(condition !== 1'b1) $fatal(1,"%0s",text);
  end
endtask

task write_entry(input [31:0] pc, input [31:0] dst, input [2:0] kind);
  begin
    update_pc=pc; update_target=dst; update_type=kind;
    update_vld=1; update_taken=1; update_ras=0; update_way=2'b10;
    tick;
    update_vld=0;
  end
endtask

initial begin
  defaults;
  cpurst_b=0;
  tick;
  cpurst_b=1;
  tick;
  // Fill/wrap all 16 entries and test every source/starting word combination.
  for(n=0;n<40;n=n+1) write_entry(32'h80001000+n*4,32'h90000000+n*16,3'd2);
  for(n=24;n<40;n=n+1) begin
    lookup_vld=1; lookup_pc=32'h80001000+n*4;
    #1; compare; check(hit,"populated source should hit");
    tick;
  end
  // Put different slots in reverse index order to exercise earliest-word choice.
  invalidate=1; tick; invalidate=0;
  write_entry(32'h8000200c,32'h90001000,3'd2);
  write_entry(32'h80002008,32'h90001010,3'd1);
  write_entry(32'h80002004,32'h90001020,3'd3);
  write_entry(32'h80002000,32'h90001030,3'd2);
  for(n=0;n<4;n=n+1) begin
    lookup_pc=32'h80002000+n*4; #1; compare;
    check(hit && hit_slot==n,"earliest eligible slot");
  end
  // The four combinational probes may end on a rising edge; move stimulus back
  // to a falling edge before changing sequential controls in either model.
  @(negedge forever_cpuclk); #1;
  // Updating a matching entry must not advance replacement, even when invalidated.
  update_pc=32'h80002004; update_target=32'ha0000040; update_type=3;
  update_taken=1; update_ras=1; update_vld=1;
  directed_inv_vld=1; directed_inv_mask=16'h0004;
  tick;
  check(dut.replace_ptr_q==4 && !dut.valid_q[2],"directed invalidate priority and old match");
  update_vld=0; directed_inv_vld=0;
  write_entry(32'h80002004,32'ha0000040,3'd3);
  // RAS target and alignment controls, then enable/cancel/full invalidation.
  update_pc=32'h80002004; update_target=32'ha0000040; update_type=3;
  update_ras=1; update_vld=1; tick; update_vld=0;
  lookup_pc=32'h80002004; ras_valid=1; ras_target=32'hfffffffC; tick;
  check(target===32'hfffffffc,"RAS full target");
  ras_target=32'hfffffffe; tick; check(hit_slot==2,"misaligned RAS skips return");
  ras_valid=0; tick;
  cancel=1; directed_inv_vld=1; directed_inv_mask=16'h0002; tick;
  check(!hit && !dut.valid_q[1],"cancel does not suppress directed invalidation");
  cancel=0; directed_inv_vld=0; enable=0; tick; check(!hit,"enable gates lookup");
  enable=1;
  for(n=0;n<8;n=n+1) begin
    update_vld=1; update_type=n[2:0]; update_pc=32'h70000000;
    update_target=32'h60000000; tick;
  end
  update_type=2;
  for(n=1;n<4;n=n+1) begin
    update_pc=32'h70000000+n; tick;
    update_pc=32'h70000000; update_target=32'h60000000+n; tick;
  end
  update_vld=0;

  // Seed duplicate valid PCs in BOTH models to test the original explicit tie
  // rules (normal updates deduplicate, so this state is not naturally reachable).
  invalidate=1; tick; invalidate=0;
  dut.valid_q=16'h0084; ref_dut.valid_q=16'h0084;
  dut.taken_q=16'h0084; ref_dut.taken_q=16'h0084;
  dut.src_q[2]=32'h81000004; ref_dut.src_q[2]=32'h81000004;
  dut.src_q[7]=32'h81000004; ref_dut.src_q[7]=32'h81000004;
  dut.dst_q[2]=32'h82000000; ref_dut.dst_q[2]=32'h82000000;
  dut.dst_q[7]=32'h83000000; ref_dut.dst_q[7]=32'h83000000;
  dut.kind_q[2]=2; ref_dut.kind_q[2]=2; dut.kind_q[7]=2; ref_dut.kind_q[7]=2;
  dut.ways_q[2]=1; ref_dut.ways_q[2]=1; dut.ways_q[7]=2; ref_dut.ways_q[7]=2;
  lookup_pc=32'h81000000; #1; compare;
  check(hit_index==2 && target==32'h82000000,"equal-slot lookup takes lowest entry");
  write_entry(32'h81000004,32'h84000000,3'd2);
  check(dut.dst_q[7]==32'h84000000 && dut.dst_q[2]==32'h82000000,
        "duplicate update takes highest entry");
  invalidate=1; tick; invalidate=0;

  // Reproducible initialized-state random differential testing. Match PCs are
  // deliberately selected frequently; purely uniform addresses almost never hit.
  for(n=0;n<5000;n=n+1) begin
    random_value=$random(seed);
    a=(random_value & 15);
    b=((random_value >> 4) & 15);
    enable=(random_value & 16'h300)!=0;
    invalidate=(random_value & 16'h7f00)==0;
    cancel=(random_value & 16'h3800)==0;
    lookup_vld=(random_value & 16'h4000)!=0;
    update_vld=(random_value & 16'h8000)!=0;
    directed_inv_vld=(random_value & 32'h00060000)==0;
    directed_inv_mask=16'b1<<a;
    update_pc=(dut.valid_q[a] && random_value[20]) ? dut.src_q[a] :
               (32'h80000000 + (b*16) + ((a%4)*4));
    if(random_value[21:20]==0) update_pc[1:0]=random_value[23:22];
    update_target=32'h90000000 | (random_value & 32'hfffffc);
    if(random_value[25:24]==0) update_target[1:0]=random_value[27:26];
    update_type=random_value[30:28];
    update_taken=random_value[31];
    update_ras=random_value[19];
    update_way=random_value[18:17];
    lookup_pc=(dut.valid_q[b] && random_value[16]) ?
               {dut.src_q[b][31:4],random_value[5:4],2'b00} : update_pc;
    ras_valid=random_value[6];
    ras_target=32'ha0000000 | (random_value & 32'hffff);
    if(random_value[7]) ras_target[1:0]=0;
    if(lookup_vld) covers_lookup=covers_lookup+1;
    if(update_vld) covers_update=covers_update+1;
    if(update_vld && directed_inv_vld) covers_overlap=covers_overlap+1;
    if(n%997==0) begin
      // Assert reset between edges, including while update inputs are active.
      #1; cpurst_b=0; #1; compare;
      tick; cpurst_b=1;
    end
    tick;
  end
  check(covers_overlap>100,"random update/invalidation overlap exercised");
  $display("PASS L0 generate: %0d four-state output/state comparisons; 5000 random cycles; lookup=%0d update=%0d overlap=%0d",
           comparisons,covers_lookup,covers_update,covers_overlap);
  $finish;
end
