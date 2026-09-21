integer cycles=0,checks=0,produced=0,delivered=0,allocated=0,branches=0,expected_branches=0;
integer seed=32'h09105107;
integer i,j,k,guard;
integer token_next=0;
reg random_mode=1;
reg [31:0] exp_pc[0:4095],exp_inst[0:4095],exp_npc[0:4095];
reg [2:0] exp_kind[0:4095];
reg exp_fault[0:4095];
reg [31:0] token_pc[0:8191],token_npc[0:8191];
reg token_valid[0:8191];
reg [127:0] packet,prior_packet[0:2];
reg [1:0] old_count,old_accept;
reg prior_valid=0;
reg clear_ip;
reg [31:0] rnd;
reg [2:0] kind;
reg [12:0] token;
integer ip_redirects=0,ib_redirects=0,ras_pushes=0,ras_pops=0,queries=0;

task check;
 input ok;
 input [511:0] msg;
 begin checks=checks+1; if(ok!==1'b1) $fatal(1,"cycle=%0d %0s",cycles,msg); end
endtask

function [2:0] decode_kind;
 input [31:0] inst;
 begin
  case(inst[6:0])
    7'h17:decode_kind=4;
    7'h63:decode_kind=(inst[14:12]<2 || inst[14]) ? 1 : 0;
    7'h6f:decode_kind=2;
    7'h67:decode_kind=inst[14:12]==0 ? 3 : 0;
    default:decode_kind=0;
  endcase
 end
endfunction

task step;
 begin
  if(random_mode) begin
    rnd=$random(seed); iu_ifu_pcfifo_credit=rnd%3;
    idu_ifu_accept_num=0;
  end
  iu_ifu_pcfifo_alloc0_token=token_next;
  iu_ifu_pcfifo_alloc1_token=token_next+1;
  #2;
  if(random_mode) begin rnd=$random(seed); idu_ifu_accept_num=rnd%(out_count+1); end
  #1;
  cycles=cycles+1;
  check(idu_ifu_accept_num<=out_count,"invalid acceptance");
  check(occupancy<=32,"IBUF overflow");
  check(!create_en[1] || create_en[0],"PCFIFO creates not a prefix");
  check(({1'b0,create_en[0]}+{1'b0,create_en[1]})<=iu_ifu_pcfifo_credit,"credit overspent");
  if(prior_valid && !flush) begin
    for(k=0;k<old_count-old_accept;k=k+1)
      check(out_packet[k*128+:128]===prior_packet[k+old_accept],"unaccepted candidate changed");
  end
  for(k=0;k<2;k=k+1) if(create_en[k]) begin
    token=token_next+k;
    check(!token_valid[token],"dynamic token allocated twice");
    token_valid[token]=1;
    token_pc[token]=create_pc[k*32+:32]; token_npc[token]=create_npc[k*32+:32];
    allocated=allocated+1;
    check(create_type[k*3+:3]!=0,"ordinary instruction allocated PCFIFO");
  end
  token_next=token_next+create_en[0]+create_en[1];
  for(k=0;k<idu_ifu_accept_num;k=k+1) begin
    packet=out_packet[k*128+:128];
    check(delivered<produced,"extra instruction delivered");
    check(packet[63:32]===exp_pc[delivered],"PC order/entry/prefix mismatch");
    check(packet[31:0]===exp_inst[delivered],"instruction duplication or wrong Way");
    check(packet[95:64]===exp_npc[delivered],"prediction not corrected at source");
    check(packet[108:106]===exp_kind[delivered],"control-flow type mismatch");
    check(packet[96]===exp_fault[delivered],"fault flag mismatch");
    check(packet[127:123]===0,"reserved bits not zero");
    if(packet[105]) begin
      token=packet[121:109];
      check(token_valid[token],"instruction delivered without PCFIFO allocation");
      check(token_pc[token]===packet[63:32] && token_npc[token]===packet[95:64],"token paired with wrong dynamic instruction");
      token_valid[token]=0;
    end else check(packet[121:109]===0,"non-PC operation carries token");
    delivered=delivered+1;
  end
  if(bht_event) branches=branches+1;
  if(ip_redirect) ip_redirects=ip_redirects+1;
  if(ib_redirect) ib_redirects=ib_redirects+1;
  if(ras_push) ras_pushes=ras_pushes+1;
  if(ras_pop) ras_pops=ras_pops+1;
  if(ind_query) queries=queries+1;
  for(k=0;k<3;k=k+1) prior_packet[k]=out_packet[k*128+:128];
  old_count=out_count;old_accept=idu_ifu_accept_num;prior_valid=!flush;
  clear_ip=ifctrl_ipctrl_vld && !ipctrl_ifctrl_stall;
  forever_cpuclk=1;#2;forever_cpuclk=0;#1;
  if(clear_ip) ifctrl_ipctrl_vld=0;
 end
endtask

task expect_word;
 input [31:0] pc,inst,npc;
 input fault;
 begin
  exp_pc[produced]=pc;exp_inst[produced]=inst;exp_npc[produced]=npc;
  exp_kind[produced]=fault ? 0 : decode_kind(inst); exp_fault[produced]=fault;
  if(!fault && decode_kind(inst)==1) expected_branches=expected_branches+1;
  produced=produced+1;
 end
endtask

task start_block;
 input [31:0] pc;
 input [127:0] data;
 input [3:0] mask;
 begin
  guard=0;
  while(ifctrl_ipctrl_vld) begin step;guard=guard+1;check(guard<500,"IP failed to make progress");end
  ifctrl_ifdp_pipedown=1;step;ifctrl_ifdp_pipedown=0;
  ifdp_ipdp_vpc=pc;ifdp_ipdp_inst_data0=data;ifdp_ipdp_inst_data1=~data;
  ifdp_ipdp_word_mask=mask;ifctrl_ipctrl_vld=1;
 end
endtask

task drain;
 begin
  guard=0;
  while(ifctrl_ipctrl_vld || !ib_empty || !ibuf_empty) begin
    step;guard=guard+1;check(guard<1000,"pipeline deadlock");
  end
  check(delivered==produced,"lost instruction");
 end
endtask

reg [127:0] words;
reg [31:0] ins,base;
initial begin
 defaults;
 for(i=0;i<8192;i=i+1)token_valid[i]=0;
 cpurst_b=1;#1;cpurst_b=0;#1;forever_cpuclk=1;#1;forever_cpuclk=0;cpurst_b=1;
 ifdp_ipdp_tag_match0=7;ifdp_ipdp_way_pred=1;demand_ready=1;btb_update_ready=1;
 $display("CASE random four-word blocks, multiple conditional branches, AUIPC segmentation, ring wrap");
 for(i=0;i<250;i=i+1)begin
  base=32'h1000+i*16;words=0;
  for(j=0;j<4;j=j+1)begin
   rnd=$random(seed);
   case(rnd%4)
    0:ins=32'h00000017|(j<<7);
    1:ins=32'h00000063;
    2:ins=32'h00100093;
    3:ins=32'h00001067; // Illegal JALR funct3 must remain ordinary raw data.
   endcase
   words[j*32+:32]=ins;
   expect_word(base+j*4,ins,base+j*4+4,0);
  end
  start_block(base,words,15);
 end
 drain;
 check(branches==expected_branches,"conditional history duplicated or omitted under stall");
 $display("CASE three AUIPC, no credit, no IDU acceptance: all records and packets retained");
 random_mode=0;iu_ifu_pcfifo_credit=0;idu_ifu_accept_num=0;
 for(j=0;j<4;j=j+1) expect_word(32'h8000+j*4,32'h00000017,32'h8004+j*4,0);
 start_block(32'h8000,{4{32'h00000017}},15);
 repeat(8)step;
 check(create_en==0 && out_count==0,"PCFIFO credit zero leaked candidate");
 random_mode=1;drain;
 $display("CASE registered ADDRGEN correction retains older IBUF and corrects token NPC");
 ifdp_ipdp_btb_hit=1;ifdp_ipdp_btb_target=32'hdead0000;
 expect_word(32'h9000,32'h008000ef,32'h9008,0);
 start_block(32'h9000,{96'b0,32'h008000ef},15);drain;
 check(ib_redirects==1 && ras_pushes==1,"JAL target correction/accepted call event");
 ifdp_ipdp_btb_hit=0;
 $display("CASE recovery interlock and RAS-before-IND return arbitration");
 recovery_stall=1;ind_enable=1;ras_valid=1;ras_target=32'habc0;
 ind_result_vld=1;ind_target_valid=1;ind_target=32'hbbc0;
 expect_word(32'h9100,32'h00008067,32'habc0,0);
 start_block(32'h9100,{96'b0,32'h00008067},15);
 repeat(10)step;
 check(recovery_wait && ras_pops==0,"return escaped deferred recovery window");
 recovery_stall=0;drain;
 check(ras_pops==1 && queries>=3,"return update or synchronous IND wait missing");
 $display("CASE wrong Way retries without allocating demand or consuming data");
 ifdp_ipdp_tag_match0=0;ifdp_ipdp_tag_match1=7;
 start_block(32'ha000,0,15);#1;
 check(reissue && way_event && !demand_valid && reissue_way==2,"wrong Way classified as miss");
 step;
 ifdp_ipdp_tag_match0=7;ifdp_ipdp_tag_match1=0;
 $display("CASE exact unaligned fault PC with no PCFIFO record");
 ifdp_ipdp_fault=1;ifdp_ipdp_cause=0;
 expect_word(32'ha006,32'h00000013,32'ha00a,1);
 start_block(32'ha006,0,2);drain;ifdp_ipdp_fault=0;
 check(delivered==produced,"final delivery count");
 $display("PASS pipeline cycles=%0d checks=%0d instructions=%0d allocations=%0d branches=%0d",cycles,checks,delivered,allocated,branches);
 $finish;
end
