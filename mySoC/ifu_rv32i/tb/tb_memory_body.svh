integer cycles=0,checks=0,writes=0,installs=0,forwards=0,requests0=0,requests1=0,reuses=0;
integer i,j,guard,old_writes,old_installs,old_forwards;
reg [31:0] write_pc[0:255];
reg [127:0] write_data[0:255];
reg [31:0] forwarded_pc[0:63];
reg [127:0] forwarded_data[0:63];
reg forwarded_error[0:63];
reg [1:0] bus_live=0;
reg [31:0] bus_pc[0:1];
reg [2:0] bus_beat[0:1],bus_len[0:1];
reg beat_accepted;

task check;input ok;input [511:0] msg;
 begin checks=checks+1;if(ok!==1'b1)$fatal(1,"cycle=%0d %0s",cycles,msg);end
endtask

function [127:0] content;input [31:0] pc;
 begin content={pc+32'd12,pc+32'd8,pc+32'd4,pc};end
endfunction

task step;
 begin
 #2;cycles=cycles+1;
 if(ifu_biu_rd_req && biu_ifu_rd_grnt)begin
  check(!bus_live[ifu_biu_rd_id],"bus ID reused before last beat");
  bus_live[ifu_biu_rd_id]=1;bus_pc[ifu_biu_rd_id]=ifu_biu_rd_addr;
  bus_beat[ifu_biu_rd_id]=0;bus_len[ifu_biu_rd_id]=ifu_biu_rd_len+1;
  if(ifu_biu_rd_id)requests1=requests1+1;else requests0=requests0+1;
  check(ifu_biu_rd_addr[3:0]==0 && ifu_biu_rd_size==4,"bus alignment/size");
 end
 beat_accepted=biu_ifu_rd_data_vld && ifu_biu_r_ready;
 if(beat_accepted)begin
  check(bus_live[biu_ifu_rd_id],"response without live ID");
  check(biu_ifu_rd_last===(bus_beat[biu_ifu_rd_id]+1==bus_len[biu_ifu_rd_id]),"last beat accounting");
  bus_beat[biu_ifu_rd_id]=bus_beat[biu_ifu_rd_id]+1;
  if(biu_ifu_rd_last)bus_live[biu_ifu_rd_id]=0;
 end
 if(refill_array_req && ifctrl_refill_grant)begin
  write_pc[writes]=l1_refill_icache_if_index;write_data[writes]=l1_refill_icache_if_inst_data;
  check(l1_refill_icache_if_inst_data===content(l1_refill_icache_if_index),"WRAP/replay beat associated with wrong block");
  writes=writes+1;
  if(l1_refill_icache_if_install)begin
   check(l1_refill_icache_if_last,"partial line published");installs=installs+1;
  end
 end
 if(l1_refill_ifctrl_vld && ifctrl_l1_refill_ready)begin
  forwarded_pc[forwards]=l1_refill_ifctrl_pc;
  forwarded_data[forwards]=l1_refill_ifdp_inst_data;
  forwarded_error[forwards]=l1_refill_ifdp_acc_err;
  check(l1_refill_ifdp_inst_data===content({l1_refill_ifctrl_pc[31:4],4'b0}),"critical block data/PC mismatch");
  forwards=forwards+1;
 end
 if(demand_hit)reuses=reuses+1;
 forever_cpuclk=1;#2;forever_cpuclk=0;#1;
 end
endtask

task demand;input [31:0] pc;input allocate;
 begin
  guard=0;
  while(!demand_ready)begin step;guard=guard+1;check(guard<100,"demand deadlock");end
  demand_pc=pc;demand_allocate=allocate;demand_valid=1;step;demand_valid=0;
 end
endtask

task response;input id;input error;
 reg [31:0] pc;
 reg [1:0] offset;
 begin
  check(bus_live[id],"test response needs granted ID");
  offset=bus_pc[id][5:4]+bus_beat[id];pc={bus_pc[id][31:6],offset,4'b0};
  biu_ifu_rd_id=id;biu_ifu_rd_data=content(pc);biu_ifu_rd_resp=error ? 2 : 0;
  biu_ifu_rd_last=bus_beat[id]+1==bus_len[id];biu_ifu_rd_data_vld=1;
  guard=0;
  step;
  while(!beat_accepted)begin step;guard=guard+1;check(guard<100,"return drain deadlock");end
  biu_ifu_rd_data_vld=0;
 end
endtask

task wait_idle;
 begin guard=0;while(!refill_idle)begin step;guard=guard+1;check(guard<100,"refill did not finish");end end
endtask

initial begin
 defaults;cpurst_b=1;#1;cpurst_b=0;#1;forever_cpuclk=1;#1;forever_cpuclk=0;cpurst_b=1;
 demand_attr=5'b11101;region_attr=5'b11101;demand_priv=3;cp0_yy_priv_mode=3;cp0_ifu_insde=1;
 biu_ifu_rd_grnt=1;ifctrl_refill_grant=1;ifctrl_ipb_grant=1;
 $display("CASE critical-first WRAP, backpressured forwarding, interleaved demand/prefetch IDs");
 enable=1;demand(32'h1034,1);
 repeat(5)step;
 check(requests0==1 && requests1==1,"demand and next-line prefetch not both granted");
 response(0,0);response(1,0);
 response(0,0);response(1,0);
 response(0,0);response(1,0);response(0,0);
 repeat(5)step;
 check(installs==1 && forwards==0,"forward hold should not delay atomic line install");
 check(l1_refill_ifctrl_vld,"critical data lost under IF backpressure");
 ifctrl_l1_refill_ready=1;step;wait_idle;
 check(forwards==1 && forwarded_pc[0]==32'h1034,"critical block entry offset lost");
 $display("CASE matching in-flight IPB is reused, then replayed at demand offset");
 demand(32'h1058,1);repeat(5)step;
 check(requests0==1,"duplicate ID0 request for in-flight prefetched line");
 response(1,0);repeat(14)step;wait_idle;
 check(reuses==1 && installs==2 && forwards==2 && requests0==1,"IPB replay did not fulfill demand once");
 check(write_pc[4]==32'h1050 && write_pc[5]==32'h1060 && write_pc[6]==32'h1070 && write_pc[7]==32'h1040,"internal replay is not WRAP");
 $display("CASE pure prefetch error drains and matching demand retries on ID0");
 demand(32'h2000,1);repeat(5)step;
 response(1,1);response(0,0);response(1,0);response(0,0);response(1,0);response(0,0);response(1,0);response(0,0);
 wait_idle;enable=0;demand(32'h2044,1);repeat(3)step;
 check(requests0==3,"failed prefetch stranded demand");
 for(i=0;i<4;i=i+1)response(0,0);wait_idle;
 $display("CASE cancel revokes live data but drains granted line; later error blocks install");
 old_installs=installs;old_forwards=forwards;
 demand(32'h3008,1);repeat(2)step;
 cancel=1;response(0,1);cancel=0;
 for(i=0;i<3;i=i+1)response(0,0);wait_idle;
 check(installs==old_installs && forwards==old_forwards,"old response/error escaped cancel");
 $display("CASE maintenance cancels install without blocking bus drain");
 old_installs=installs;demand(32'h4000,1);repeat(2)step;
 response(0,0);invalidate=1;step;invalidate=0;
 for(i=0;i<3;i=i+1)response(0,0);wait_idle;
 check(installs==old_installs,"maintenance allowed old line resurrection");
 $display("CASE uncached one-beat response never writes array");
 old_writes=writes;demand(32'h500c,0);repeat(2)step;response(0,1);wait_idle;
 check(writes==old_writes && forwarded_error[forwards-1],"uncached fault allocation/forwarding");
 check(!protocol_error && bus_live==0,"unresolved transaction/protocol error");
 $display("PASS memory cycles=%0d checks=%0d writes=%0d installs=%0d forwards=%0d id0=%0d id1=%0d reuses=%0d",cycles,checks,writes,installs,forwards,requests0,requests1,reuses);
 $finish;
end
