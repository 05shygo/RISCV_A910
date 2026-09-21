  integer checks=0;
  integer i, j, n;
  reg [21:0] committed_model, speculative_model;
  reg [31:0] rng=32'h59a38e17;
  reg [31:0] snapshot;
  reg [3:0] saved_hit;
  reg [127:0] saved_target;
  reg [31:0] spec_stack[0:11], commit_stack[0:5];
  integer spec_count, commit_count, spop, cpop;
  reg spush, cpush, recover;
  always #5 forever_cpuclk=~forever_cpuclk;
  initial begin #2000000; $fatal(1,"watchdog"); end
  task tick; begin @(posedge forever_cpuclk); #1; end endtask
  task check(input bit condition, input string why);
    begin checks=checks+1; if(!condition) $fatal(1,"%s (check %0d, time %0t)",why,checks,$time); end
  endtask
  task maintain(input [4:0] mask);
    begin
      #1;
      check(bp_maint_ready,"maintenance ready");
      bp_maint_mask=mask; bp_maint_vld=1; tick(); bp_maint_vld=0;
      check(!bp_init_done,"maintenance blocks prediction");
      n=0;
      while(!bp_maint_done && n<1100) begin tick(); n=n+1; end
      check(bp_maint_done && bp_init_done,"maintenance completes");
      tick(); check(!bp_maint_done,"done is a pulse");
    end
  endtask
  task btb_write(input [31:0] pc, input [31:0] dst, input [1:0] way);
    begin
      check(btb_update_ready,"BTB update ready");
      btb_update_pc=pc; btb_update_target=dst; btb_update_way=way;
      btb_update_vld=1; tick(); btb_update_vld=0; tick();
    end
  endtask
  task btb_read(input [31:0] pc);
    begin
      btb_lookup_pc=pc; btb_lookup_vld=1;
      #1; check(btb_lookup_ready,"BTB read ready"); tick();
      btb_lookup_vld=0; check(!btb_result_vld,"BTB has registered SRAM latency");
      tick(); check(btb_result_vld,"BTB result after SRAM and output latch");
    end
  endtask
  task l0_write(input [31:0] pc, input [31:0] dst, input [2:0] kind);
    begin
      l0_update_pc=pc; l0_update_target=dst; l0_update_type=kind;
      l0_update_taken=1; l0_update_way=2; l0_update_vld=1;
      tick(); l0_update_vld=0;
    end
  endtask
  task push(input [31:0] pc);
    begin
      ibdp_ras_push_pc=pc; ibctrl_ras_pcall_vld=1;
      ibctrl_ras_pcall_vld_for_gateclk=1; tick();
      ibctrl_ras_pcall_vld=0; ibctrl_ras_pcall_vld_for_gateclk=0; #1;
    end
  endtask
  task pop;
    begin
      ibctrl_ras_preturn_vld=1; ibctrl_ras_preturn_vld_for_gateclk=1; tick();
      ibctrl_ras_preturn_vld=0; ibctrl_ras_preturn_vld_for_gateclk=0; #1;
    end
  endtask
  initial begin
    forever_cpuclk=0; cpurst_b=0; defaults(); tick(); tick(); cpurst_b=1;
    n=0;
    while(!bp_init_done && n<1100) begin
      tick(); n=n+1;
      if(!bp_init_done) check(!l0_hit && !ras_top_valid && !ind_result_vld,"no prediction during reset sweep");
    end
    check(bp_init_done && n>=1024,"full BHT reset sweep, no premature init_done");
    check(dut.u_bht.u_bht_pre_array.u_ct_spsram_1024x64.mem_q[0]===64'h3333333333333333,"BHT row zero reset");
    check(dut.u_bht.u_bht_pre_array.u_ct_spsram_1024x64.mem_q[1023]===64'h3333333333333333,"BHT final row reset");
    check(!ras_top_valid,"empty RAS");
    $display("PASS initialization");

    for(i=0;i<4;i=i+1) btb_write(32'h81234000+i*4,32'hf1000000+i*256,i[1:0]);
    for(i=0;i<4;i=i+1) begin
      btb_read(32'h81234000+i*4);
      check(btb_hit==((4'b1111<<i)&4'b1111),"BTB word-entry mask");
      for(j=i;j<4;j=j+1) begin
        check(btb_target[j*32+:32]==32'hf1000000+j*256,"BTB complete high target");
        check(btb_way_hint[j*2+:2]==j[1:0],"BTB way hint");
      end
      tick();
    end
    btb_read(32'h91234000); check(btb_hit==0,"BTB full source tag"); tick();
    btb_read(32'h81234002); check(btb_hit==0,"BTB rejects unaligned source"); tick();
    btb_lookup_pc=32'h81234000; btb_lookup_vld=1; tick(); btb_lookup_vld=0;
    btb_update_pc=32'h81234008; btb_update_target=32'hffff0000; btb_update_way=3; btb_update_vld=1;
    tick(); btb_update_vld=0;
    check(btb_result_vld && btb_target[95:64]==32'hffff0000,"BTB concurrent update bypass");
    tick(); btb_read(32'h81234008); check(btb_target[95:64]==32'hffff0000,"BTB buffer drained to SRAM"); tick();
    btb_lookup_vld=1; tick(); btb_lookup_vld=0; frontend_cancel=1; tick();
    check(!btb_result_vld,"BTB cancels pending read"); frontend_cancel=0; tick();
    check(!btb_result_vld,"BTB killed result does not resurrect");
    $display("PASS BTB slots, tags, targets, bypass, cancellation");

    l0_write(32'h8000100c,32'hf1234000,3'd2);
    l0_write(32'h80001004,32'hc1234000,3'd1);
    l0_lookup_pc=32'h80001000; l0_lookup_vld=1; #1;
    check(l0_hit && l0_hit_slot==1 && l0_target==32'hc1234000,"L0 earliest eligible branch");
    l0_lookup_pc=32'h80001008; #1;
    check(l0_hit && l0_hit_slot==3,"L0 skips before entry");
    l0_directed_inv_mask=16'b1<<l0_hit_index; l0_directed_inv_vld=1; #1;
    check(!l0_hit,"L0 directed invalidation bypass"); tick(); l0_directed_inv_vld=0; #1;
    check(!l0_hit,"L0 directed invalidation stored");
    l0_lookup_pc=32'h90001000; #1; check(!l0_hit,"L0 full source tag");
    l0_lookup_pc=32'h80001000; frontend_cancel=1; #1; check(!l0_hit,"L0 recovery wins");
    frontend_cancel=0; l0_lookup_vld=0;
    $display("PASS L0 earliest slot, directed invalidate, full tag");

    push(32'hfffffffC); check(ras_top_valid && ras_l0_btb_pc==32'hfffffffc,"RAS full byte PC");
    push(32'h12345678); check(ras_l0_btb_pc==32'h12345678,"RAS second push");
    ibctrl_ras_preturn_vld=1; ibctrl_ras_pcall_vld=1; ibdp_ras_push_pc=32'h87654320;
    #1; check(ras_l0_btb_pc==32'h12345678,"coroutine sees old top"); tick();
    ibctrl_ras_preturn_vld=0; ibctrl_ras_pcall_vld=0; #1;
    check(ras_top_valid && ras_l0_btb_pc==32'h87654320,"coroutine replaces old top");
    pop(); check(ras_top_valid && ras_l0_btb_pc==32'hfffffffc,"coroutine keeps depth");
    pop(); check(!ras_top_valid,"RAS empty after matching pops");
    ibctrl_ras_pcall_vld=1; ibctrl_ras_preturn_vld=1; ibdp_ras_push_pc=32'h80000004; tick();
    ibctrl_ras_pcall_vld=0; ibctrl_ras_preturn_vld=0; #1;
    check(ras_top_valid && ras_l0_btb_pc==32'h80000004,"empty coroutine still pushes"); pop();
    maintain(5'b10000);
    for(i=0;i<13;i=i+1) push(32'ha0000000+i*4);
    for(i=12;i>=1;i=i-1) begin
      check(ras_top_valid && ras_l0_btb_pc==32'ha0000000+i*4,"RAS overflow keeps latest twelve"); pop();
    end
    check(!ras_top_valid,"RAS overflow drops oldest");
    maintain(5'b10000);
    rtu_ifu_retire0_vld=1; rtu_ifu_retire0_pcall=1; rtu_ifu_retire0_inc_pc=32'hd0000010;
    rtu_ifu_flush=1; tick(); rtu_ifu_flush=0; rtu_ifu_retire0_pcall=0; rtu_ifu_retire0_vld=0; #1;
    check(ras_top_valid && ras_l0_btb_pc==32'hd0000010,"same-cycle retired call and flush restores content/valid");
    iu_ifu_mispred_stall=1; snapshot=dut.u_ras.top_ptr_q; push(32'h80000000);
    check(dut.u_ras.top_ptr_q==snapshot && !ras_top_valid,"mispred_stall blocks speculative RAS");
    iu_ifu_mispred_stall=0;
    $display("PASS RAS push/pop/coroutine/overflow/retirement recovery");

    maintain(5'b10000); spec_count=0; commit_count=0;
    for(i=0;i<1000;i=i+1) begin
      rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
      spush=rng[0]; spop=rng[1]; cpush=rng[2]; cpop=rng[3]; recover=rng[4];
      rtu_ifu_retire0_vld=1; rtu_ifu_retire0_pcall=cpush; rtu_ifu_retire0_preturn=cpop;
      rtu_ifu_retire0_inc_pc=32'hd0000000+i*4; rtu_ifu_flush=recover;
      ibctrl_ras_pcall_vld=spush; ibctrl_ras_preturn_vld=spop; ibdp_ras_push_pc=32'he0000000+i*4;
      if(cpop && commit_count>0) commit_count=commit_count-1;
      if(cpush) begin
        if(commit_count==6) begin
          for(j=0;j<5;j=j+1) commit_stack[j]=commit_stack[j+1]; commit_count=5;
        end
        commit_stack[commit_count]=rtu_ifu_retire0_inc_pc; commit_count=commit_count+1;
      end
      if(recover) begin
        spec_count=commit_count;
        for(j=0;j<commit_count;j=j+1) spec_stack[j]=commit_stack[j];
      end else begin
        if(spop && spec_count>0) spec_count=spec_count-1;
        if(spush) begin
          if(spec_count==12) begin
            for(j=0;j<11;j=j+1) spec_stack[j]=spec_stack[j+1]; spec_count=11;
          end
          spec_stack[spec_count]=ibdp_ras_push_pc; spec_count=spec_count+1;
        end
      end
      tick(); rtu_ifu_flush=0; ibctrl_ras_pcall_vld=0; ibctrl_ras_preturn_vld=0; #1;
      check(ras_top_valid== (spec_count>0),"random RAS validity matches bounded committed/speculative stacks");
      if(spec_count>0) check(ras_l0_btb_pc===spec_stack[spec_count-1],"random RAS content after simultaneous retirement/speculation/recovery");
    end
    defaults();
    $display("PASS 1000 randomized RAS retirement/speculation/recovery cycles");

    maintain(5'b11111);
    rtu_ifu_retire0_vld=1; rtu_ifu_retire0_jmp=1; rtu_ifu_retire0_mispred=1;
    rtu_ifu_retire0_jmp_mispred=1; rtu_ifu_retire0_next_pc=32'he1234000; rtu_ifu_retire0_chk_idx=0;
    tick(); rtu_ifu_retire0_vld=0; rtu_ifu_retire0_jmp=0; rtu_ifu_retire0_mispred=0; rtu_ifu_retire0_jmp_mispred=0;
    ipdp_ind_btb_jmp_detect=1; tick(); check(!ind_result_vld,"IND requires output latch");
    ipdp_ind_btb_jmp_detect=0; tick();
    check(ind_target_valid && ind_target==32'he1234000,"IND preserves complete high address");
    tick(); check(!ind_result_vld,"IND response pulse");
    ipdp_ind_btb_jmp_detect=1; tick(); ipdp_ind_btb_jmp_detect=0; frontend_cancel=1; tick();
    frontend_cancel=0; tick(); check(!ind_result_vld,"IND read canceled across output stage");
    rtu_ifu_retire0_vld=1; rtu_ifu_retire1_vld=1; rtu_ifu_retire2_vld=1;
    rtu_ifu_retire0_jmp=1; rtu_ifu_retire1_jmp=1; rtu_ifu_retire2_jmp=1;
    rtu_ifu_retire0_chk_idx=8'h11; rtu_ifu_retire1_chk_idx=8'h22; rtu_ifu_retire2_chk_idx=8'h33;
    rtu_ifu_flush=1; tick();
    check(dut.u_ind_btb.path_reg_0_q==8'h33 && dut.u_ind_btb.path_reg_1_q==8'h22 && dut.u_ind_btb.path_reg_2_q==8'h11,"IND same-cycle ordered retirement recovery");
    defaults();
    $display("PASS IND synchronous timing/full targets/path recovery/cancel");

    maintain(5'b00100);
    committed_model=0; speculative_model=0;
    for(i=0;i<2000;i=i+1) begin
      rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
      rtu_ifu_retire0_vld=1; rtu_ifu_retire1_vld=1; rtu_ifu_retire2_vld=1;
      rtu_ifu_retire0_condbr=rng[0]; rtu_ifu_retire1_condbr=rng[1]; rtu_ifu_retire2_condbr=rng[2];
      rtu_ifu_retire0_condbr_taken=rng[3]; rtu_ifu_retire1_condbr_taken=rng[4]; rtu_ifu_retire2_condbr_taken=rng[5];
      ipctrl_bht_con_br_vld=rng[6]; ipctrl_bht_con_br_taken=rng[7];
      lbuf_bht_active_state=rng[8]; lbuf_bht_con_br_vld=rng[8] && rng[9]; lbuf_bht_con_br_taken=rng[10];
      rtu_ifu_flush=(rng[14:11]==0); iu_ifu_chgflw_vld=(rng[18:15]==0);
      iu_ifu_bht_check_vld=iu_ifu_chgflw_vld && rng[19]; iu_ifu_bht_condbr_taken=rng[20];
      iu_ifu_chk_idx={3'b000,rng[21:0]}; local_recover_vld=(rng[25:22]==0);
      local_recover_ghr=rng[31:10]; frontend_cancel=rng[26]; cp0_ifu_bht_en=!rng[27];
      if(cp0_ifu_bht_en) begin
        if(rng[0]) committed_model={committed_model[20:0],rng[3]};
        if(rng[1]) committed_model={committed_model[20:0],rng[4]};
        if(rng[2]) committed_model={committed_model[20:0],rng[5]};
      end
      if(rtu_ifu_flush && cp0_ifu_bht_en) speculative_model=committed_model;
      else if(iu_ifu_chgflw_vld && cp0_ifu_bht_en)
        speculative_model=iu_ifu_bht_check_vld ? {iu_ifu_chk_idx[20:0],iu_ifu_bht_condbr_taken} : iu_ifu_chk_idx[21:0];
      else if(local_recover_vld) speculative_model=local_recover_ghr;
      else if(!rtu_ifu_flush && !iu_ifu_chgflw_vld && !frontend_cancel && cp0_ifu_bht_en) begin
        if(lbuf_bht_con_br_vld) speculative_model={speculative_model[20:0],lbuf_bht_con_br_taken};
        else if(ipctrl_bht_con_br_vld && !lbuf_bht_active_state) speculative_model={speculative_model[20:0],ipctrl_bht_con_br_taken};
      end
      tick();
      check(dut.u_bht.rtughr_q===committed_model,"random committed GHR ordered append");
      check(dut.u_bht.vghr_q===speculative_model,"random speculative GHR recovery priority");
    end
    defaults();
    $display("PASS 2000 randomized history/flush/cancel/enable/LBUF cycles");

    maintain(5'b00100);
    // Fill the four-entry queue by giving reads priority. Drop fifth and count it.
    pcgen_bht_seq_read=1; iu_ifu_bht_check_vld=1; iu_ifu_bht_pred=0;
    iu_ifu_bht_condbr_taken=1; iu_ifu_chk_idx=0;
    for(i=0;i<4;i=i+1) begin tick(); check(!bht_train_drop_count,"first four updates retained"); end
    #1; check(bht_train_drop,"fifth blocked update advertises performance drop");
    tick(); check(bht_train_drop_count==1,"training drop counted");
    iu_ifu_bht_check_vld=0; pcgen_bht_seq_read=0;
    repeat(8) tick();
    check(!dut.u_bht.entry0_vld_q && !dut.u_bht.entry1_vld_q && !dut.u_bht.entry2_vld_q && !dut.u_bht.entry3_vld_q,"queue drains");
    check(dut.u_bht.u_bht_pre_array.u_ct_spsram_1024x64.mem_q[0][3:2]==2'b01,"training reaches selected not-taken bank");
    $display("PASS BHT queue/drop/drain/SRAM training");

    maintain(5'b11111);
    btb_read(32'h81234000); check(btb_hit==0,"maintenance invalidates BTB");
    l0_lookup_pc=32'h80001000; l0_lookup_vld=1; #1; check(!l0_hit,"maintenance invalidates L0");
    check(!ras_top_valid,"maintenance clears RAS");
    $display("PASS predictor cluster: %0d checks",checks);
    $finish;
  end
