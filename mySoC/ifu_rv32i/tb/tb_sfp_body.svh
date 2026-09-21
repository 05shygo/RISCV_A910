integer checks=0,cycles=0,i;
task check;input ok;input [511:0] msg;
begin checks=checks+1;if(ok!==1'b1)$fatal(1,"SFP cycle=%0d %0s",cycles,msg);end endtask
task step;begin #2;forever_cpuclk=1;#2;forever_cpuclk=0;#1;cycles=cycles+1;end endtask
task feedback;input [31:0] pc;input store;input [2:0] status;
begin
 retire_valid=1;retire_store=store;retire_load=!store;retire_pc={64'b0,pc};
 retire_miss={2'b0,status[0]};retire_hit={2'b0,status[1]};retire_mispred={2'b0,status[2]};
 step;retire_valid=0;
end endtask
initial begin
 defaults;cpurst_b=1;#1;cpurst_b=0;step;cpurst_b=1;enable=1;lookup_mask=15;
 $display("CASE store SF allocation, BAR association and cross-block lookup state");
 feedback(32'h1000,1,1);feedback(32'h1014,0,1);
 lookup_pc=32'h1000;#1;check(no_spec===4'b0001,"SF not learned");
 lookup_accept=1;step;lookup_accept=0;
 lookup_pc=32'h1010;#1;check(no_spec===4'b0010,"BAR not paired with earlier SF");
 lookup_accept=1;step;lookup_accept=0;
 #1;check(no_spec==0,"BAR state did not clear on acceptance");
 $display("CASE saturating hit/mispred and disabled feedback");
 feedback(32'h1014,0,2);feedback(32'h1014,0,2);feedback(32'h1014,0,2);
 check(dut.entry_q[0][65:64]==3,"counter did not saturate");
 feedback(32'h1014,0,4);feedback(32'h1014,0,4);
 lookup_pc=32'h1000;#1;check(no_spec[0],"decrement removed nonzero entry");
 feedback(32'h1014,0,4);feedback(32'h1014,0,4);
 #1;check(no_spec==0 && dut.entry_q[0][65:64]==0,"counter underflow");
 feedback(32'h1000,1,1);
 enable=0;feedback(32'h1000,1,4);#1;check(no_spec==0,"disabled prediction visible");
 enable=1;#1;check(no_spec[0],"disabled feedback changed table");
 feedback(32'h1000,1,4);#1;check(no_spec==0,"store mispred did not clear counter");
 $display("CASE full-PC distinction, retirement priority, masked slots and cancel");
 feedback(32'h1000,1,1);feedback(32'h1014,0,1);
 lookup_pc=32'h11000;#1;check(no_spec==0,"truncated-PC false hit");
 lookup_pc=32'h1000;lookup_mask=14;#1;check(no_spec==0,"masked entry visible");
 lookup_mask=15;lookup_accept=1;step;lookup_accept=0;cancel=1;step;cancel=0;
 lookup_pc=32'h1010;#1;check(no_spec==0,"cancel retained speculative BAR mode");
 retire_valid=3;retire_load=0;retire_store=3;retire_miss=3;retire_hit=0;retire_mispred=0;
 retire_pc={32'b0,32'h3000,32'h2000};step;retire_valid=0;
 lookup_pc=32'h2000;#1;check(no_spec[0],"oldest feedback not selected");
 lookup_pc=32'h3000;#1;check(no_spec==0,"single update port trained second feedback");
 $display("CASE twelve-entry replacement wrap, invalidate priority");
 invalidate=1;step;invalidate=0;
 for(i=0;i<13;i=i+1)feedback(32'h4000+i*16,1,1);
 check(dut.pointer_q==1,"replacement pointer did not wrap at twelve");
 lookup_pc=32'h4000;#1;check(no_spec==0,"oldest entry not replaced");
 lookup_pc=32'h40c0;#1;check(no_spec[0],"wrapped replacement missing");
 invalidate=1;feedback(32'h5000,1,1);invalidate=0;
 for(i=0;i<12;i=i+1)check(dut.entry_q[i]==0,"invalidate did not dominate update");
 check(dut.pointer_q==0 && !dut.mode_q,"invalidate state not reset");
 $display("PASS SFP cycles=%0d checks=%0d",cycles,checks);$finish;
end
