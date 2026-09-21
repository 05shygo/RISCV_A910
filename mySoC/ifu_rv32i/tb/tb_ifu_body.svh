integer cycles=0,checks=0,delivered=0,allocations=0,misses=0,accesses=0,prefetches=0,reuses=0;
integer seed=32'h09102117;
integer i,j,guard,before_count,token_next=0;
integer lbuf_cycles=0;
reg short_loop,forward_loop,branch_mode,predictors_off;
reg [21:0] history_model=0;
integer branch_events=0;
reg [31:0] rnd,expected_pc=32'h1000;
reg [1:0] bus_live=0;
reg [31:0] bus_pc[0:1];
reg [2:0] bus_count[0:1],bus_len[0:1];
reg [31:0] token_pc[0:8191],token_npc[0:8191];
reg [24:0] token_chk[0:8191];
reg [12:0] token;
reg [127:0] packet;
reg [383:0] packets;
reg [1:0] candidate_count;
reg [31:0] return_pc;
reg [1:0] offset;
reg [31:0] expected_inst;
reg request_fire,response_fire;
reg [31:0] version=0;
reg accept_enable=1;
reg request_id;
reg fault_mode=0;
reg [3:0] expected_cause=0;
reg [31:0] request_pc;
reg [2:0] request_len;
reg [127:0] software_response;

task check;input ok;input [511:0] msg;
 begin checks=checks+1;if(ok!==1'b1)begin
 $display("IF vld=%b IP=%b pc=%h stall=%b IB=%d IBUF=%d lbuf_state=%d lbuf_count=%d active=%b wait=%b memidle=%b faultstop=%b mask=%h",u_ifu.ifctrl_debug_if_vld,u_ifu.pipe_ip_valid,u_ifu.ifdp_ipdp_vpc,u_ifu.ipctrl_ifctrl_stall,u_ifu.u_pipeline.u_ibctrl.count_q,u_ifu.occupancy,u_ifu.u_lbuf.state_q,u_ifu.u_lbuf.count_q,u_ifu.lbuf_active,u_ifu.lbuf_waiting,u_ifu.memory_idle,u_ifu.fault_stop_q,u_ifu.ifdp_ipdp_word_mask);
 $fatal(1,"cycle=%0d expected_pc=%h %0s",cycles,expected_pc,msg);end end
endtask
function [31:0] program_word;input [31:0] pc;
 begin
  // 64-instruction loop. AUIPC records stress independent allocation bandwidth.
  if(short_loop && pc==32'h103c)program_word=32'hfc5ff06f; // jal x0,-60
  else if(forward_loop && pc==32'h1008)program_word=32'h00c0006f;
  else if(!short_loop && pc==32'h10fc)program_word=32'hf05ff06f; // jal x0,-252
  else if(branch_mode)program_word=32'h00001263; // bne x0,x0,+4
  else if(pc[3:2]==0)program_word=32'h00000097;
  else program_word=32'h00100113 | (version<<20);
 end
endfunction

task step;
 begin
  rnd=$random(seed);biu_ifu_rd_grnt=rnd[0] || rnd[1];
  iu_ifu_pcfifo_credit=(rnd>>2)%3;
  iu_ifu_pcfifo_alloc0_token=token_next;iu_ifu_pcfifo_alloc1_token=token_next+1;
  idu_ifu_accept_num=0;
  if(!biu_ifu_rd_data_vld && bus_live!=0 && rnd[5])begin
   biu_ifu_rd_id=bus_live==3 ? rnd[6] : bus_live[1];
   offset=bus_pc[biu_ifu_rd_id][5:4]+bus_count[biu_ifu_rd_id];
   return_pc={bus_pc[biu_ifu_rd_id][31:6],offset,4'b0};
   for(j=0;j<4;j=j+1)biu_ifu_rd_data[j*32+:32]=program_word(return_pc+j*4);
   biu_ifu_rd_data_vld=1;biu_ifu_rd_last=bus_count[biu_ifu_rd_id]+1==bus_len[biu_ifu_rd_id];
  end
  #2;
  candidate_count=ifu_idu_ib_inst0_vld+{1'b0,ifu_idu_ib_inst1_vld}+{1'b0,ifu_idu_ib_inst2_vld};
  if(accept_enable && !ifu_idu_flush)begin rnd=$random(seed);idu_ifu_accept_num=rnd%(candidate_count+1);end
  #1;cycles=cycles+1;
  check((^u_ifu.u_lbuf.state_q)!==1'bx,"unknown LBUF state");
  if(u_ifu.bht_event && cp0_ifu_bht_en)begin
    check(u_ifu.bht_chk_idx[21:0]===history_model,"BHT snapshot does not precede its accepted branch");
    branch_events=branch_events+1;
  end
  if(!u_ifu.bp_init_done || u_ifu.predictor_commit_restore || (u_ifu.bp_maint_vld && u_ifu.bp_maint_ready))history_model=0;
  else if(iu_ifu_chgflw_vld && cp0_ifu_bht_en)history_model=iu_ifu_bht_check_vld ?
      {iu_ifu_chk_idx[20:0],iu_ifu_bht_condbr_taken} : iu_ifu_chk_idx[21:0];
  else if(u_ifu.ib_redirect_all)history_model=u_ifu.combined_recover_ghr;
  else if(u_ifu.bht_event && cp0_ifu_bht_en)history_model={history_model[20:0],u_ifu.bht_taken};
  request_fire=ifu_biu_rd_req && biu_ifu_rd_grnt;
  request_id=ifu_biu_rd_id;request_pc=ifu_biu_rd_addr;request_len={1'b0,ifu_biu_rd_len}+1;
  response_fire=biu_ifu_rd_data_vld && ifu_biu_r_ready;
  if(request_fire)begin
   check(!bus_live[request_id],"read ID reused");
   check(request_pc>=32'h1000 && request_pc<32'h3000,"unsafe physical bus request");
  end
  if(ifu_iu_pcfifo_create0_en)begin
   token_pc[token_next]=ifu_iu_pcfifo_create0_cur_pc;
   token_npc[token_next]=ifu_iu_pcfifo_create0_pred_npc;
   token_chk[token_next]=ifu_iu_pcfifo_create0_chk_idx;
   allocations=allocations+1;
  end
  if(ifu_iu_pcfifo_create1_en)begin
   check(ifu_iu_pcfifo_create0_en,"non-prefix PCFIFO creates");
   token_pc[token_next+1]=ifu_iu_pcfifo_create1_cur_pc;
   token_npc[token_next+1]=ifu_iu_pcfifo_create1_pred_npc;
   token_chk[token_next+1]=ifu_iu_pcfifo_create1_chk_idx;
   allocations=allocations+1;
  end
  token_next=token_next+ifu_iu_pcfifo_create0_en+ifu_iu_pcfifo_create1_en;
  packets={ifu_idu_ib_inst2_data,ifu_idu_ib_inst1_data,ifu_idu_ib_inst0_data};
  for(i=0;i<idu_ifu_accept_num;i=i+1)begin
   packet=packets[i*128+:128];expected_inst=program_word(expected_pc);
   if(packet[63:32]!==expected_pc)$display("actual pc=%h inst=%h npc=%h IP=%h",packet[63:32],packet[31:0],packet[95:64],u_ifu.ifdp_ipdp_vpc);
   check(packet[63:32]===expected_pc,"instruction lost, duplicated or wrong path");
   if(fault_mode)begin
    check(packet[96] && packet[100:97]===expected_cause,"fetch fault cause missing");
    check(!packet[105] && packet[121:109]==0,"fetch fault allocated PCFIFO token");
   end else begin
    check(packet[31:0]===expected_inst,"memory/Cache/maintenance opcode mismatch");
    check(!packet[96],"unexpected fetch fault");
   end
   if(packet[105])begin
    token=packet[121:109];
    check(token_pc[token]===packet[63:32] && token_npc[token]===packet[95:64],"dynamic token association");
   end
   if(!fault_mode)begin
   expected_pc=expected_pc==(short_loop ? 32'h103c : 32'h10fc) ? 32'h1000 :
     (forward_loop && expected_pc==32'h1008) ? 32'h1014 : expected_pc+4;
   check(packet[95:64]===expected_pc,"source target not corrected before delivery");
   end
   delivered=delivered+1;
  end
  if(ifu_hpcp_icache_miss)misses=misses+1;
  if(ifu_hpcp_icache_access)accesses=accesses+1;
  if(ifu_hpcp_ipb_launch)prefetches=prefetches+1;
  if(ifu_hpcp_ipb_demand_hit)reuses=reuses+1;
  if(ifu_hpcp_lbuf_active)lbuf_cycles=lbuf_cycles+1;
  forever_cpuclk=1;#2;forever_cpuclk=0;#1;
  check(u_ifu.u_bp_top.u_bht.vghr_q===history_model,"VGHR differs from accepted-event reference");
  if(response_fire)begin
   bus_count[biu_ifu_rd_id]=bus_count[biu_ifu_rd_id]+1;
   if(biu_ifu_rd_last)bus_live[biu_ifu_rd_id]=0;
   biu_ifu_rd_data_vld=0;
  end
  if(request_fire)begin bus_live[request_id]=1;bus_pc[request_id]=request_pc;bus_count[request_id]=0;bus_len[request_id]=request_len;end
 end
endtask

initial begin
 defaults;cp0_yy_clk_en=1;cp0_ifu_icg_en=1;cp0_ifu_rvbr=32'h1000;cp0_yy_priv_mode=3;
 short_loop=$test$plusargs("SHORT_LOOP");forward_loop=$test$plusargs("FORWARD_LOOP");
 branch_mode=$test$plusargs("BRANCHES");
 predictors_off=$test$plusargs("PRED_OFF");
 cp0_ifu_lbuf_en=short_loop;
 cp0_ifu_icache_en=1;cp0_ifu_icache_pref_en=1;cp0_ifu_iwpe=1;cp0_ifu_insde=1;
 cp0_ifu_btb_en=1;cp0_ifu_l0btb_en=1;cp0_ifu_bht_en=1;cp0_ifu_ras_en=1;cp0_ifu_ind_btb_en=1;
 if(predictors_off)begin
  cp0_ifu_btb_en=0;cp0_ifu_l0btb_en=0;cp0_ifu_bht_en=0;cp0_ifu_ras_en=0;cp0_ifu_ind_btb_en=0;
 end
 hpcp_ifu_cnt_en=1;
 cpurst_b=1;#1;cpurst_b=0;#1;forever_cpuclk=1;#1;forever_cpuclk=0;cpurst_b=1;
 if(branch_mode)begin
   guard=0;while(!ifu_cp0_init_done)begin step;guard=guard+1;check(guard<1500,"initialization timeout");end
   iu_ifu_chgflw_vld=1;iu_ifu_chgflw_pc=32'h1000;iu_ifu_chk_idx=25'h2a55aa;step;iu_ifu_chgflw_vld=0;
 end
 $display("CASE real initialization, critical refill, prefetch, PCGEN/IF/IP/IB/IBUF loop stream");
 guard=0;while(delivered<500)begin step;guard=guard+1;check(guard<5000,"initialization or full pipeline deadlock");end
 $display("CASE precise recovery clears young queue and resumes matching PC");
 rtu_ifu_flush=1;rtu_ifu_chgflw_vld=1;rtu_ifu_chgflw_pc=short_loop ? 32'h1020 : 32'h1040;expected_pc=rtu_ifu_chgflw_pc;step;
 rtu_ifu_flush=0;rtu_ifu_chgflw_vld=0;
 before_count=delivered;guard=0;
 while(delivered<before_count+200)begin step;guard=guard+1;check(guard<2000,"recovery deadlock");end
 $display("CASE full maintenance drains both IDs, invalidates old code, resumes new image");
 cp0_ifu_maint_vld=1;cp0_ifu_maint_op=0;cp0_ifu_maint_resume_pc=32'h1000;
 #1;while(!ifu_cp0_maint_ready)step;
 expected_pc=32'h1000;step;cp0_ifu_maint_vld=0;version=2;
 guard=0;while(!ifu_cp0_maint_done)begin step;guard=guard+1;check(guard<2500,"maintenance deadlock");end
 step;before_count=delivered;guard=0;
 while(delivered<before_count+200)begin step;guard=guard+1;check(guard<2000,"maintenance resume deadlock");end
 $display("CASE software Tag read response held under backpressure");
 cp0_ifu_icache_read_req=1;cp0_ifu_icache_read_index=11'h100;
 cp0_ifu_icache_read_way=0;cp0_ifu_icache_read_kind=1;
 #1;guard=0;while(!ifu_cp0_icache_read_ready)begin step;guard=guard+1;check(guard<100,"software read admission");end
 step;cp0_ifu_icache_read_req=0;
 guard=0;while(!ifu_cp0_icache_read_data_vld)begin step;guard=guard+1;check(guard<100,"software read response");end
 software_response=ifu_cp0_icache_read_data;
 check(software_response[17:0]===18'h20000 && software_response[127:19]===0,"PIPT software Tag layout");
 repeat(5)begin step;check(ifu_cp0_icache_read_data_vld && ifu_cp0_icache_read_data===software_response,"software response overwritten");end
 cp0_ifu_icache_read_data_ready=1;step;cp0_ifu_icache_read_data_ready=0;
 $display("CASE LSU physical-line invalidation owns its completion and resumes");
 lsu_ifu_icache_inv_vld=1;lsu_ifu_icache_inv_all=0;lsu_ifu_icache_inv_pa=32'h1000;lsu_ifu_icache_inv_resume_pc=32'h1000;
 #1;while(!ifu_lsu_icache_inv_ready)step;
 expected_pc=32'h1000;step;lsu_ifu_icache_inv_vld=0;
 guard=0;while(!ifu_lsu_icache_inv_done)begin step;guard=guard+1;check(!ifu_cp0_maint_done,"LSU completion sent to CP0");check(guard<1500,"LSU line invalidate deadlock");end
 step;before_count=delivered;guard=0;
 while(delivered<before_count+50)begin step;guard=guard+1;check(guard<1000,"line invalidate restart");end
 $display("CASE no-op drains, debug entry flushes and exactly one injected word is delivered");
 cp0_ifu_no_op_req=1;guard=0;
 while(!ifu_yy_xx_no_op)begin step;guard=guard+1;check(guard<200,"no-op transaction drain");end
 // Enter debug with deliberately nonzero speculative history. No retirement
 // has occurred, so the committed history to restore is zero.
 iu_ifu_chgflw_vld=1;iu_ifu_chgflw_pc=32'h1000;iu_ifu_chk_idx=25'h355aa5;
 expected_pc=32'h1000;step;iu_ifu_chgflw_vld=0;
 if(!predictors_off)check(history_model==22'h355aa5,"debug history seed missing");
 rtu_ifu_dbgon=1;step;
 check(history_model==0,"debug entry did not restore committed history");
 guard=0;while(!ifu_had_cmd_ready)begin step;guard=guard+1;check(guard<200,"debug entry not quiescent");end
 had_ifu_pc=32'h1000;had_ifu_ir=program_word(32'h1000);had_ifu_ir_vld=1;
 expected_pc=32'h1000;before_count=delivered;step;had_ifu_ir_vld=0;
 guard=0;while(delivered==before_count)begin step;guard=guard+1;check(guard<100,"debug instruction not delivered");end
 repeat(5)step;check(delivered==before_count+1,"debug instruction duplicated");
 rtu_ifu_dbgon=0;cp0_ifu_no_op_req=0;rtu_ifu_flush=1;rtu_ifu_chgflw_vld=1;rtu_ifu_chgflw_pc=32'h1000;expected_pc=32'h1000;
 step;rtu_ifu_flush=0;rtu_ifu_chgflw_vld=0;before_count=delivered;guard=0;
 while(delivered<before_count+50)begin step;guard=guard+1;check(guard<1000,"debug exit restart");end
 if(short_loop)check(lbuf_cycles>100,"short loop never entered replay");
 if(branch_mode && !predictors_off)check(branch_events>500,"conditional branch test had no coverage");
 $display("CASE denied region and exact misaligned PC deliver one fault then stop");
 fault_mode=1;expected_pc=32'h4000;expected_cause=1;before_count=delivered;
 rtu_ifu_flush=1;rtu_ifu_chgflw_vld=1;rtu_ifu_chgflw_pc=expected_pc;step;
 rtu_ifu_flush=0;rtu_ifu_chgflw_vld=0;guard=0;
 while(delivered==before_count)begin step;guard=guard+1;check(guard<100,"region fault stalled");end
 repeat(10)step;check(delivered==before_count+1,"region fault repeated");
 expected_pc=32'h1002;expected_cause=0;before_count=delivered;
 rtu_ifu_flush=1;rtu_ifu_chgflw_vld=1;rtu_ifu_chgflw_pc=expected_pc;step;
 rtu_ifu_flush=0;rtu_ifu_chgflw_vld=0;guard=0;
 while(delivered==before_count)begin step;guard=guard+1;check(guard<100,"misaligned fault stalled");end
 repeat(10)step;check(delivered==before_count+1,"misaligned fault repeated");
 fault_mode=0;expected_pc=32'h1000;before_count=delivered;
 rtu_ifu_flush=1;rtu_ifu_chgflw_vld=1;rtu_ifu_chgflw_pc=expected_pc;step;
 rtu_ifu_flush=0;rtu_ifu_chgflw_vld=0;guard=0;
 while(delivered<before_count+20)begin step;guard=guard+1;check(guard<500,"fault recovery did not restart");end
 $display("PASS IFU cycles=%0d checks=%0d delivered=%0d allocations=%0d accesses=%0d misses=%0d prefetches=%0d reuses=%0d lbuf_cycles=%0d",cycles,checks,delivered,allocations,accesses,misses,prefetches,reuses,lbuf_cycles);
 $finish;
end
