integer checks=0;
integer cycles=0;
integer issues=0;
integer transfers=0;
integer l0_accepts=0;
integer i,j,k;
integer before_count;
integer seed=32'h09103217;
reg [31:0] random_word;
reg [127:0] memory_data[0:1][0:2047];
reg [31:0] memory_precode[0:1][0:2047];
reg [17:0] memory_tag[0:1][0:511];
reg model_if_valid=0;
reg model_ip_valid=0;
reg model_held=0;
reg [31:0] model_pc;
reg [1:0] model_kind,model_way;
reg [4:0] model_attr;
reg model_fault;
reg [3:0] model_mask,model_bkpta,model_bkptb;
reg [127:0] model_data[0:1];
reg [31:0] model_precode[0:1];
reg [17:0] model_tag[0:1];
reg model_l0_hit;
reg [3:0] model_l0_index;
reg [1:0] model_l0_slot,model_l0_way;
reg [2:0] model_l0_type;
reg [31:0] model_l0_target;
reg model_btb_vld;
reg [3:0] model_btb_hit;
reg [127:0] model_btb_target;
reg [7:0] model_btb_way;
reg [3:0] model_no_spec;
reg do_transfer,do_issue,kill_if,next_ip_valid,next_ip_pcload;
reg [2047:0] old_ip_packet;
reg [31:0] expect_pc;
reg [1:0] expect_way,expect_kind;
reg expect_fault,expect_l0_hit,expect_btb_vld;
reg [3:0] expect_mask,expect_bkpta,expect_bkptb,expect_l0_index,expect_btb_hit,expect_no_spec;
reg [1:0] expect_l0_slot,expect_l0_way;
reg [2:0] expect_l0_type;
reg [31:0] expect_l0_target;
reg [127:0] expect_data[0:1];
reg [31:0] expect_precode[0:1];
reg [2:0] expect_tag_match[0:1];
reg [127:0] expect_btb_target;
reg [7:0] expect_btb_way;
reg [4:0] expect_attr;
reg expected_l0_accept;
reg early_btb_vld;
reg [3:0] early_btb_hit;
reg [127:0] early_btb_target;
reg [7:0] early_btb_way;
reg bht_query;
reg [9:0] bht_query_index;
reg [1:0] old_bht_selector;
integer w,s;

task check;
  input condition;
  input [511:0] message;
  begin
    checks=checks+1;
    if(condition !== 1'b1) $fatal(1,"cycle=%0d %0s",cycles,message);
  end
endtask

function [4:0] attributes;
  input [31:0] pc;
  begin
    if(pc<32'h100000) attributes=5'b11101;
    else if(pc>=32'h10000000 && pc<32'h10010000) attributes=5'b10101;
    else attributes=0;
  end
endfunction

task step;
  begin
    #2;
    cycles=cycles+1;
    check((ifctrl_array_grant & (ifctrl_array_grant-1))==0,"array ownership is not one-hot-or-zero");
    check(ifctrl_debug_if_vld===model_if_valid,"IF valid differs from transaction scoreboard");
    check(ifctrl_ifdp_held===model_held,"IF saved-response lifecycle");
    check(!ifctrl_btb_lookup_vld || ifctrl_ifdp_issue,"BTB lookup without a granted fetch");
    check(ifctrl_bht_pipedown===ifctrl_ifdp_pipedown,"BHT and IF/IP must advance atomically");
    check(!ifctrl_l0_btb_accept || ifctrl_ifdp_pipedown,"L0 consumed without source transfer");
    if(maintenance_array_req) check(ifctrl_array_grant[0],"maintenance lost priority");
    else if(refill_array_req) check(ifctrl_array_grant[1],"refill lost priority");
    else if(ipb_array_req) check(ifctrl_array_grant[2],"IPB lost priority");

    do_transfer=ifctrl_ifdp_pipedown;
    early_btb_vld=btb_ifdp_vld; early_btb_hit=btb_ifdp_hit;
    early_btb_target=btb_ifdp_target; early_btb_way=btb_ifdp_way;
    do_issue=ifctrl_ifdp_issue;
    bht_query=ifctrl_bht_read;
    bht_query_index=ifctrl_bht_pcindex;
    old_bht_selector=tb_bht_bht_ipdp_sel_array_result;
    kill_if=frontend_redirect || pcgen_ifctrl_pipe_cancel || control_ifctrl_reissue;
    old_ip_packet=ip_packet_observed;
    next_ip_valid=pcgen_ifctrl_pipe_cancel ? 0 :
      (!ipctrl_ifctrl_stall && !ipctrl_ifctrl_bht_stall) ? do_transfer : model_ip_valid;
    next_ip_pcload=ifctrl_pcgen_chgflw_vld;
    // Lookup information is owned by this IF block at its first sampling edge.
    // A later predictor update must not alter a saved response.
    if(model_if_valid && !model_held) begin
      model_l0_hit=l0_btb_ifdp_hit && !model_fault && model_kind!=2 &&
        l0_btb_ifdp_slot>=model_pc[3:2] && l0_btb_ifdp_target[1:0]==0;
      model_l0_index=l0_btb_ifdp_index;
      model_l0_slot=l0_btb_ifdp_slot;
      model_l0_type=l0_btb_ifdp_type;
      model_l0_target=l0_btb_ifdp_target;
      model_l0_way=l0_btb_ifdp_way;
      model_btb_vld=btb_ifdp_vld && btb_ifdp_pc==model_pc && !model_fault && model_kind!=2;
      model_btb_hit=model_btb_vld ? btb_ifdp_hit : 0;
      model_btb_target=model_btb_vld ? btb_ifdp_target : 0;
      model_btb_way=model_btb_vld ? btb_ifdp_way : 0;
      model_no_spec=(sfp_ifdp_vld && sfp_ifdp_pc==model_pc && !model_fault) ?
                    sfp_ifdp_no_spec & model_mask : 0;
    end
    expected_l0_accept=do_transfer && model_l0_hit && !(model_l0_type==3 && bp_recovery_stall);
    if(model_if_valid) begin
      check(ifdp_ifctrl_fault===model_fault,"IF exception source");
      check(ifdp_l0_btb_pc===model_pc,"L0 queried with unrelated PC");
      check(ifctrl_l0_btb_accept===expected_l0_accept,"L0 accept/hold/recovery qualification");
    end
    if(do_transfer) begin
      transfers=transfers+1;
      expect_pc=model_pc; expect_way=model_way; expect_kind=model_kind;
      expect_fault=model_fault; expect_mask=model_mask; expect_attr=model_attr;
      expect_bkpta=model_bkpta & model_mask; expect_bkptb=model_bkptb & model_mask;
      expect_l0_hit=model_l0_hit; expect_l0_index=model_l0_index;
      expect_l0_slot=model_l0_slot; expect_l0_type=model_l0_type;
      expect_l0_target=model_l0_target; expect_l0_way=model_l0_way;
      expect_btb_vld=model_btb_vld; expect_btb_hit=model_btb_hit;
      expect_btb_target=model_btb_target; expect_btb_way=model_btb_way; expect_no_spec=model_no_spec;
      for(w=0;w<2;w=w+1) begin
        expect_data[w]=model_data[w]; expect_precode[w]=model_precode[w];
        if(model_fault || model_kind==2) expect_tag_match[w]=0;
        else if(model_kind==3) expect_tag_match[w]=(w==0)?3'b111:0;
        else expect_tag_match[w]={model_tag[w][17:16]=={1'b1,model_pc[31]},
          model_tag[w][15:8]==model_pc[30:23],model_tag[w][7:0]==model_pc[22:15]};
      end
    end
    if(ifctrl_l0_btb_accept) l0_accepts=l0_accepts+1;
    if(ifctrl_ifdp_hold) model_held=1;
    if(kill_if || do_transfer) begin model_if_valid=0; model_held=0; end
    if(do_issue) begin
      issues=issues+1; model_if_valid=1; model_held=0;
      model_pc=ifctrl_ifdp_issue_pc; model_way=ifctrl_ifdp_issue_way;
      model_kind=ifctrl_ifdp_issue_kind; model_attr=attributes(model_pc);
      model_fault=(model_kind==1) || (model_kind==3 && l1_refill_ifdp_acc_err);
      if(model_kind!=3) begin
        if(model_pc[1:0]!=0 || !model_attr[4] || !model_attr[0])
          check(model_kind==1,"denied/misaligned fetch did not create fault token");
        else if(!model_attr[3] || !cp0_ifu_icache_en)
          check(model_kind==2,"uncached access was not delegated to IP/refill");
        else check(model_kind==0 && ifctrl_array_fetch,"normal cache request did not own SRAM");
      end
      model_mask=0; model_bkpta=0; model_bkptb=0;
      for(s=0;s<4;s=s+1) begin
        model_mask[s]=model_fault ? (s==model_pc[3:2]) : (s>=model_pc[3:2]);
        model_bkpta[s]=had_ifu_bkpta_en &&
          (((model_pc & 32'hfffffff0)+4*s & ~had_yy_xx_bkpta_mask)==
           (had_yy_xx_bkpta_base & ~had_yy_xx_bkpta_mask));
        model_bkptb[s]=had_ifu_bkptb_en &&
          (((model_pc & 32'hfffffff0)+4*s & ~had_yy_xx_bkptb_mask)==
           (had_yy_xx_bkptb_base & ~had_yy_xx_bkptb_mask));
      end
      for(w=0;w<2;w=w+1) begin
        model_tag[w]=memory_tag[w][model_pc[14:6]];
        model_data[w]=0; model_precode[w]=0;
        if(!model_fault && model_kind==0 && model_way[w]) begin
          model_data[w]=memory_data[w][model_pc[14:4]];
          model_precode[w]=memory_precode[w][model_pc[14:4]];
        end
        if(!model_fault && model_kind==3 && w==0) begin
          model_data[w]=l1_refill_ifdp_inst_data;
          model_precode[w]=l1_refill_ifdp_precode;
        end
      end
    end
    // Independent memory contents follow only accepted physical writes.
    if(ifctrl_refill_grant && l1_refill_icache_if_wr) begin
      memory_data[l1_refill_icache_if_fifo][l1_refill_icache_if_index[14:4]]=l1_refill_icache_if_inst_data;
      memory_precode[l1_refill_icache_if_fifo][l1_refill_icache_if_index[14:4]]=l1_refill_icache_if_pre_code;
      if(l1_refill_icache_if_first || l1_refill_icache_if_last)
        memory_tag[l1_refill_icache_if_fifo][l1_refill_icache_if_index[14:6]]=
          {l1_refill_icache_if_last && l1_refill_icache_if_install,l1_refill_icache_if_ptag};
    end
    if(ifctrl_maintenance_grant && ifctrl_icache_if_reset_req) begin
      for(w=0;w<2;w=w+1) begin
        memory_data[w][ifctrl_icache_if_index[14:4]]=0;
        memory_precode[w][ifctrl_icache_if_index[14:4]]=0;
        memory_tag[w][ifctrl_icache_if_index[14:6]]=0;
      end
    end
    forever_cpuclk=1; #2;
    if(bht_query) begin
      check(u_bht.sel_rd_q===1'b1,"BHT first/new query response was incorrectly stalled");
      check(u_bht.bht_sel_array_index_q===bht_query_index,"BHT query index differs from accepted PC");
    end
    if(do_transfer && (expect_kind==0 || expect_kind==3))
      check(tb_bht_bht_ipdp_sel_array_result===((expect_pc[13:7]+expect_pc[6:4]) & 2'b11),
            "BHT selector not associated with transferred PC after hold/redirect");
    if(!do_transfer)
      check(tb_bht_bht_ipdp_sel_array_result===old_bht_selector,"BHT IP result changed without transfer");
    check(u_bht.vghr_q===22'b0,"IF lookup/transfer changed speculative history without IP event");
    check(tb_btb_result_vld===early_btb_vld,"BTB early/legacy result latency");
    if(early_btb_vld)
      check(tb_btb_hit===early_btb_hit && tb_btb_target===early_btb_target &&
            tb_btb_way_hint===early_btb_way,"BTB early data differs from legacy registered result");
    check(ifctrl_ipctrl_vld===next_ip_valid,"IP valid: cancel/load/hold priority");
    model_ip_valid=next_ip_valid;
    if(!do_transfer) check(ip_packet_observed===old_ip_packet,"IP payload changed without transfer");
    else begin
      check(ifdp_ipdp_vpc===expect_pc,"IP PC mismatch");
      check(ifdp_ipdp_attr===expect_attr,"region attributes from wrong request");
      check(ifdp_ipdp_way_pred===expect_way,"read Way association");
      check(ifdp_ipdp_fault===expect_fault,"IP fault mismatch");
      check(ifdp_ipdp_word_mask===expect_mask,"word entry/fault mask");
      check(ifdp_ipdp_bkpta===expect_bkpta && ifdp_ipdp_bkptb===expect_bkptb,"breakpoint masks");
      check(ifdp_ipdp_inst_data0===expect_data[0] && ifdp_ipdp_inst_data1===expect_data[1],"SRAM/forward/stalled payload mismatch");
      check(ifdp_ipdp_precode0===expect_precode[0] && ifdp_ipdp_precode1===expect_precode[1],"precode association");
      if(ifdp_ipdp_tag_match0!==expect_tag_match[0] || ifdp_ipdp_tag_match1!==expect_tag_match[1])
        $display("TAG pc=%h actual=%b/%b expected=%b/%b kind=%d",expect_pc,
          ifdp_ipdp_tag_match0,ifdp_ipdp_tag_match1,expect_tag_match[0],expect_tag_match[1],expect_kind);
      check(ifdp_ipdp_tag_match0===expect_tag_match[0] && ifdp_ipdp_tag_match1===expect_tag_match[1],"Tag slices to IP");
      check(ifdp_ipdp_refill_on===(expect_kind==3) && ifdp_ipdp_cache_bypass===(expect_kind==2),"source type");
      check(ifdp_ipdp_l0_hit===expect_l0_hit && ifdp_ipdp_l0_index===expect_l0_index &&
        ifdp_ipdp_l0_slot===expect_l0_slot && ifdp_ipdp_l0_type===expect_l0_type &&
        ifdp_ipdp_l0_target===expect_l0_target && ifdp_ipdp_l0_way===expect_l0_way,"L0 snapshot changed under stall");
      check(ifdp_ipdp_btb_vld===expect_btb_vld && ifdp_ipdp_btb_hit===expect_btb_hit &&
        ifdp_ipdp_btb_target===expect_btb_target && ifdp_ipdp_btb_way===expect_btb_way,"BTB snapshot changed under stall");
      check(ifdp_ipdp_no_spec===expect_no_spec,"SFP association");
      check(ifctrl_ipctrl_if_pcload===next_ip_pcload,"L0 accepted flag did not follow source packet");
    end
    forever_cpuclk=0; #2;
  end
endtask

task fill_line;
  input integer which_way;
  input [31:0] pc;
  integer block_index;
  integer word_index;
  begin
    refill_array_req=1; l1_refill_icache_if_wr=1;
    l1_refill_icache_if_fifo=which_way;
    l1_refill_icache_if_ptag=pc[31:15];
    for(block_index=0;block_index<4;block_index=block_index+1) begin
      l1_refill_icache_if_index=pc+16*block_index;
      l1_refill_icache_if_first=(block_index==0);
      l1_refill_icache_if_last=(block_index==3);
      l1_refill_icache_if_install=(block_index==3);
      l1_refill_icache_if_pre_code=32'h12345678+block_index;
      for(word_index=0;word_index<4;word_index=word_index+1)
        l1_refill_icache_if_inst_data[word_index*32+:32]=32'ha0000000+pc+16*block_index+4*word_index;
      step;
    end
    refill_array_req=0; l1_refill_icache_if_wr=0;
    l1_refill_icache_if_first=0; l1_refill_icache_if_last=0; l1_refill_icache_if_install=0;
  end
endtask

task redirect;
  input [31:0] target_pc;
  begin
    iu_ifu_chgflw_vld=1; iu_ifu_chgflw_pc=target_pc; step;
    iu_ifu_chgflw_vld=0;
  end
endtask

initial begin
  defaults;
  forever_cpuclk=0; cpurst_b=1; #1; cpurst_b=0;
  #1; forever_cpuclk=1; #1; forever_cpuclk=0; #1; cpurst_b=1;
  // Seed distinct selector counters by row and slot. Expectations use only PC,
  // so a stale SRAM result or query index cannot pass by following DUT signals.
  for(i=0;i<128;i=i+1)
    for(j=0;j<8;j=j+1)
      u_bht.u_bht_sel_array.u_ct_spsram_128x16.mem_q[i][2*j+:2]=(i+j)%4;
  for(i=0;i<2;i=i+1) begin
    for(j=0;j<2048;j=j+1) begin memory_data[i][j]=0; memory_precode[i][j]=0; end
    for(j=0;j<512;j=j+1) memory_tag[i][j]=0;
  end
  $display("CASE initialize arrays, independent IF arbitration, real BTB SRAM");
  maintenance_array_req=1; ifctrl_icache_if_reset_req=1;
  ifctrl_icache_if_inv_on=1; ifctrl_icache_if_tag_req=1;
  for(i=0;i<2048;i=i+1) begin ifctrl_icache_if_index=i*16; step; end
  maintenance_array_req=0; ifctrl_icache_if_reset_req=0;
  ifctrl_icache_if_inv_on=0; ifctrl_icache_if_tag_req=0;
  check(tb_btb_init_done,"BTB initialization");
  for(i=0;i<16;i=i+1) begin fill_line(0,32'h1000+64*i); fill_line(1,32'h9000+64*i); end
  // Train one main BTB slot. Legacy and early outputs share the same table.
  tb_btb_update_vld=1; tb_btb_update_pc=32'h1018;
  tb_btb_update_target=32'h1234; tb_btb_update_way=2;
  step; tb_btb_update_vld=0; step;
  frontend_init_done=1;
  vector_pcgen_pcload=1; vector_pcgen_pc=32'h1004; step; vector_pcgen_pcload=0;
  step;
  check(ifdp_l0_btb_pc==32'h1004,"initial high-priority target replay");
  $display("CASE continuous hits: one IF/IP block per cycle");
  before_count=transfers;
  for(i=0;i<16;i=i+1) begin
    step;
    check(ifdp_ipdp_vpc==(i==0 ? 32'h1004 : 32'h1000+16*i),"continuous stream duplicated/skipped a PC");
    if(ifdp_ipdp_vpc==32'h1010) begin
      check(ifdp_ipdp_btb_vld && ifdp_ipdp_btb_hit[2],"BTB early result missed IF capture edge");
      check(ifdp_ipdp_btb_target[64+:32]==32'h1234,"BTB early target");
    end
  end
  check(transfers-before_count==16,"continuous hit throughput fell below one block per cycle");

  $display("CASE stalled IF and IP, other owners overwrite array outputs");
  ipctrl_ifctrl_stall=1;
  l0_btb_ifdp_hit=1; l0_btb_ifdp_slot=3; l0_btb_ifdp_index=5;
  l0_btb_ifdp_type=1; l0_btb_ifdp_target=32'h1100; l0_btb_ifdp_way=1;
  step;
  maintenance_array_req=1; ifctrl_icache_if_read_req_data0=1;
  ifctrl_icache_if_read_req_index=32'h9000;
  before_count=l0_accepts;
  for(i=0;i<6;i=i+1) begin
    l0_btb_ifdp_target=32'h9000+16*i; l0_btb_ifdp_index=i;
    had_yy_xx_bkpta_base=32'h1234+i; step;
  end
  check(l0_accepts==before_count,"stall repeatedly consumed L0 prediction");
  check(ifctrl_pcgen_chgflw_no_stall_mask && !ifctrl_pcgen_chgflw_vld,
        "C910 short hint was incorrectly tied to accepted redirect");
  maintenance_array_req=0; ifctrl_icache_if_read_req_data0=0;
  ipctrl_ifctrl_stall=0; l0_btb_ifdp_hit=0; step;
  check(ifctrl_ipctrl_if_pcload && ifdp_ipdp_l0_target==32'h1100,"held L0 target was not preserved");
  check(l0_accepts==before_count+1,"L0 source was not consumed exactly once");
  step;

  $display("CASE IP owns wrong-Way and true miss decisions");
  cp0_ifu_btb_en=0;
  ipctrl_pcgen_reissue_pcload=1; ipctrl_pcgen_reissue_pc=32'h9008;
  ipctrl_pcgen_reissue_way_pred=1; step; ipctrl_pcgen_reissue_pcload=0; step;
  check(ifdp_ipdp_vpc==32'h9008 && ifdp_ipdp_tag_match1==7 && ifdp_ipdp_way_pred==1,
        "wrong-Way indication must reach IP without an IF-owned replay");
  ipctrl_pcgen_reissue_pcload=1; ipctrl_pcgen_reissue_way_pred=2;
  step; ipctrl_pcgen_reissue_pcload=0; step;
  check(ifdp_ipdp_inst_data1[64+:32]==32'ha0009008,"IP-directed correct-Way replay");
  redirect(32'h7000); step;
  check(ifdp_ipdp_tag_match0!=7 && ifdp_ipdp_tag_match1!=7 && !ifdp_ipdp_fault,"true miss belongs to IP");

  $display("CASE fault tokens, byte-mask breakpoints, uncached bypass");
  had_ifu_bkpta_en=1; had_yy_xx_bkpta_base=32'h1018; had_yy_xx_bkpta_mask=0;
  had_ifu_bkptb_en=1; had_yy_xx_bkptb_base=32'h1010; had_yy_xx_bkptb_mask=15;
  redirect(32'h1014); step;
  check(ifdp_ipdp_bkpta==4'b0100 && ifdp_ipdp_bkptb==4'b1110,"Excel breakpoint mask bit meaning");
  redirect(32'h8000000c); step;
  check(ifdp_ipdp_fault && ifdp_ipdp_word_mask==8 && ifdp_ipdp_cause==1,"denied address deadlocked or wrong token");
  redirect(32'h1006); step;
  check(ifdp_ipdp_fault && ifdp_ipdp_cause==0 && ifdp_ipdp_vpc==32'h1006,"unaligned PC silently rounded");
  redirect(32'h10000004); step;
  check(ifdp_ipdp_cache_bypass && !ifdp_ipdp_fault,"noncacheable demand delegation");

  $display("CASE live refill forwarding, matching address, no-op drain, no duplicate");
  l1_refill_ifctrl_active=1;
  ipctrl_pcgen_reissue_pcload=1; ipctrl_pcgen_reissue_pc=32'h10000004;
  ipctrl_pcgen_reissue_way_pred=3; step; ipctrl_pcgen_reissue_pcload=0;
  l1_refill_ifctrl_vld=1; l1_refill_ifctrl_live=0; l1_refill_ifctrl_pc=32'h10000000;
  step; check(!ifctrl_l1_refill_ready,"stale same-PC refill accepted");
  l1_refill_ifctrl_live=1; l1_refill_ifctrl_pc=32'h10000010;
  step; check(!ifctrl_l1_refill_ready,"unrelated refill block accepted");
  l1_refill_ifctrl_pc=32'h10000000;
  l1_refill_ifdp_inst_data=128'h44444444_33333333_22222222_11111111;
  l1_refill_ifdp_precode=32'h13579bdf;
  cp0_ifu_no_op_req=1;
  step; step;
  check(ifdp_ipdp_refill_on && ifdp_ipdp_vpc==32'h10000004 && ifdp_ipdp_word_mask==14,
        "critical block forwarding lost pending word offset");
  before_count=issues;
  for(i=0;i<4;i=i+1) step;
  check(issues==before_count,"held refill valid was delivered more than once");
  l1_refill_ifctrl_vld=0; l1_refill_ifctrl_active=0; cp0_ifu_no_op_req=0;
  redirect(32'h1010); step;

  $display("CASE deferred indirect recovery, cancel beats stalls, identical-PC redirect");
  ipctrl_ifctrl_stall=1;
  l0_btb_ifdp_hit=1; l0_btb_ifdp_type=3; l0_btb_ifdp_slot=3;
  l0_btb_ifdp_target=32'h1200; step;
  bp_recovery_stall=1; ipctrl_ifctrl_stall=0;
  before_count=l0_accepts; step;
  check(l0_accepts==before_count,"unsafe indirect L0 prediction used during deferred recovery");
  bp_recovery_stall=0; l0_btb_ifdp_hit=0;
  ipctrl_ifctrl_stall=1;
  rtu_ifu_chgflw_vld=1; rtu_ifu_flush=1; rtu_ifu_chgflw_pc=32'h1010;
  step; check(!ifctrl_ipctrl_vld,"RTU cancellation did not override stall");
  rtu_ifu_chgflw_vld=0; rtu_ifu_flush=0; step;
  ipctrl_ifctrl_stall=0; step;
  check(ifdp_ipdp_vpc==32'h1010,"same-address redirect delivered an old transaction");

  $display("CASE sticky replay across array conflicts; IP local redirect preserves older domains");
  ipctrl_ifctrl_stall=1;
  maintenance_array_req=1; ifctrl_icache_if_read_req_data0=1;
  rtu_ifu_chgflw_vld=1; rtu_ifu_flush=1; rtu_ifu_chgflw_pc=32'h112c;
  step; rtu_ifu_chgflw_vld=0; rtu_ifu_flush=0;
  before_count=issues;
  for(i=0;i<7;i=i+1) step;
  check(issues==before_count && pcgen_ifctrl_pc==32'h112c,"blocked high-priority target lost");
  maintenance_array_req=0; ifctrl_icache_if_read_req_data0=0;
  step; step; ipctrl_ifctrl_stall=0; step;
  check(ifdp_ipdp_vpc==32'h112c,"sticky reissue did not revisit registered target");
  ipctrl_ifctrl_stall=1; ipctrl_pcgen_if_stall=1;
  ipctrl_pcgen_chgflw_pcload=1; ipctrl_pcgen_chgflw_pc=32'h1200;
  ipctrl_pcgen_chgflw_way_pred=1;
  #1;
  check(!pcgen_ibctrl_cancel && !pcgen_ibctrl_ibuf_flush,"local IP correction flushed older IB/IBUF");
  step;
  check(ifctrl_ipctrl_vld && ifdp_ipdp_vpc==32'h112c,"local correction lost preserved IP prefix");
  ipctrl_pcgen_chgflw_pcload=0; step;
  ipctrl_ifctrl_stall=0; ipctrl_pcgen_if_stall=0; step;

  $display("CASE refill error token and cancellation simultaneous with old same-PC return");
  l1_refill_ifctrl_active=1;
  ipctrl_pcgen_reissue_pcload=1; ipctrl_pcgen_reissue_pc=32'h1000000c;
  step; ipctrl_pcgen_reissue_pcload=0;
  l1_refill_ifctrl_pc=32'h10000000; l1_refill_ifctrl_live=1;
  l1_refill_ifctrl_vld=1; l1_refill_ifdp_acc_err=1;
  step; step;
  check(ifdp_ipdp_refill_on && ifdp_ipdp_fault && ifdp_ipdp_word_mask==8 &&
        ifdp_ipdp_inst_data0==0,"refill error token/entry position");
  l1_refill_ifctrl_vld=0;
  ipctrl_pcgen_reissue_pcload=1; ipctrl_pcgen_reissue_pc=32'h1000000c;
  step; ipctrl_pcgen_reissue_pcload=0;
  l1_refill_ifctrl_vld=1;
  rtu_ifu_chgflw_vld=1; rtu_ifu_flush=1; rtu_ifu_chgflw_pc=32'h1000000c;
  before_count=issues; step;
  check(issues==before_count,"cancel accepted a same-PC old error response");
  rtu_ifu_chgflw_vld=0; rtu_ifu_flush=0; l1_refill_ifctrl_live=0;
  step; check(issues==before_count,"old refill reused after recovery");
  l1_refill_ifctrl_vld=0; l1_refill_ifctrl_active=0; l1_refill_ifdp_acc_err=0;
  redirect(32'h1000); step;

  $display("CASE explicit array re-read cancels the old IF sample and retains the PC");
  ipctrl_ifctrl_stall=1; control_ifctrl_reissue=1;
  before_count=issues; step;
  check(issues==before_count && !ifctrl_debug_if_vld,"control replay failed to cancel old IF sample");
  control_ifctrl_reissue=0; step;
  ipctrl_ifctrl_stall=0; step;

  $display("CASE random stalls, local/global redirects, all owner conflicts, predictor hints");
  cp0_ifu_btb_en=1;
  had_ifu_bkpta_en=0; had_ifu_bkptb_en=0;
  for(i=0;i<4000;i=i+1) begin
    random_word=$urandom(seed);
    ipctrl_ifctrl_stall=random_word[0];
    ipctrl_ifctrl_bht_stall=random_word[1] && random_word[2];
    cp0_ifu_no_op_req=random_word[3] && random_word[4];
    maintenance_array_req=random_word[5] && random_word[6];
    ifctrl_icache_if_read_req_data0=maintenance_array_req;
    ifctrl_icache_if_read_req_index=32'h1000+16*random_word[11:7];
    refill_array_req=random_word[12] && random_word[13];
    l1_refill_icache_if_wr=refill_array_req;
    l1_refill_icache_if_fifo=random_word[14];
    l1_refill_icache_if_index=32'h1040+16*random_word[18:15];
    l1_refill_icache_if_inst_data={4{random_word}};
    l1_refill_icache_if_pre_code=random_word;
    ipb_array_req=random_word[19]; ipb_icache_if_req=ipb_array_req;
    ipb_icache_if_req_for_gateclk=ipb_array_req; ipb_icache_if_index=32'h1080;
    iu_ifu_chgflw_vld=random_word[20:18]==0;
    iu_ifu_chgflw_pc=32'h1000+4*random_word[26:21];
    l0_btb_ifdp_hit=random_word[28]; l0_btb_ifdp_type=random_word[29]?3:1;
    l0_btb_ifdp_target=32'h1000+16*random_word[25:22];
    l0_btb_ifdp_slot=random_word[31:30]; l0_btb_ifdp_index=random_word[25:22];
    l0_btb_ifdp_way=random_word[17:16]; bp_recovery_stall=random_word[27];
    step;
  end
  $display("PASS IF stage cycles=%0d checks=%0d issues=%0d transfers=%0d l0_accepts=%0d",
            cycles,checks,issues,transfers,l0_accepts);
  $finish;
end
