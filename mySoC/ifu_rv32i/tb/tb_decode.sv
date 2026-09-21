`timescale 1ns/1ps
module tb_decode;
  reg [31:0] inst=0, pc=0;
  wire cb,jal,jalr,auipc,pcop,dst,push,pop,usable,bad;
  wire [2:0] kind;
  wire [31:0] direct,link;
  rv32_ifu_bp_decode d(.inst(inst),.pc(pc),.condbr(cb),.jal(jal),.jalr(jalr),.auipc(auipc),
    .pc_oper(pcop),.dst_vld(dst),.cf_type(kind),.ras_push(push),.ras_pop(pop),
    .ras_target_usable(usable),.direct_target(direct),.direct_misaligned(bad),.link_pc(link));
  reg direction=0,rv=0,iv=0,bv=0;
  reg [31:0] rt=32'hf1000000,it=32'he1000000,bt=32'hd1000000;
  wire [31:0] npc,recorded;
  wire predicted,unknown,bad_pred;
  rv32_ifu_bp_target t(.pc(pc),.cf_type(kind),.direct_target(direct),.bht_pred(direction),
    .ras_usable(usable),.ras_valid(rv),.ras_target(rt),.ind_valid(iv),.ind_target(it),
    .btb_valid(bv),.btb_target(bt),.pred_npc(npc),.recorded_target(recorded),
    .pred_taken(predicted),.target_unknown(unknown),.bad_target(bad_pred));
  integer checks=0,rd,rs,f,off;
  reg epush,epop;
  reg [31:0] expected;
  reg [12:0] bimm;
  reg [20:0] jimm;
  task check(input bit ok,input string message);
    begin checks=checks+1; if(!ok) $fatal(1,"%s: inst=%h pc=%h",message,inst,pc); end
  endtask
  initial begin
    pc=32'h80000000;
    for(rd=0;rd<32;rd=rd+1) for(rs=0;rs<32;rs=rs+1) begin
      inst=(rs<<15)|(rd<<7)|32'h67;
      epush=(rd==1 || rd==5);
      if(rs!=1 && rs!=5) epop=0;
      else if(rd==rs) epop=0;
      else epop=1;
      #1;
      check(jalr && kind==3 && push==epush && pop==epop && usable==epop,"JALR x1/x5 hint table");
      check(dst==(rd!=0),"JALR destination");
      inst=inst|32'h00400000; #1;
      check(push==epush && pop==epop && !usable,"nonzero immediate preserves hint but disables direct TOS");
    end
    for(f=0;f<8;f=f+1) begin
      inst=(f<<12)|32'h63; #1; check(cb==(f!=2 && f!=3),"six legal conditional branches");
      inst=(f<<12)|32'h67; #1; check(jalr==(f==0),"JALR funct3 legality");
    end
    for(off=-4096;off<=4094;off=off+2) begin
      bimm=off[12:0];
      inst={bimm[12],bimm[10:5],5'd2,5'd1,3'b000,bimm[4:1],bimm[11],7'h63};
      expected=pc+off; direction=1; #1;
      check(direct==expected && bad==(expected[1:0]!=0),"B immediate exhaustive signed decode");
      check(recorded==expected && npc==(bad ? pc+4 : expected),"B target alignment never silently rounds bit1");
      direction=0; #1; check(npc==pc+4 && !predicted,"not-taken keeps sequential path");
    end
    for(off=-1048576;off<=1048574;off=off+8190) begin
      jimm=off[20:0]; inst={jimm[20],jimm[10:1],jimm[11],jimm[19:12],5'd5,7'h6f};
      expected=pc+off; #1; check(jal && push && direct==expected,"JAL signed offsets/link x5");
    end
    pc=32'hfffffffc; inst=32'h008000ef; #1;
    check(link==0 && direct==4 && npc==4,"RV32 wraparound plus four/eight");
    pc=32'h1000; inst=32'h000280e7; rv=1;iv=1;bv=1; #1;
    check(push && pop && npc==rt,"coroutine old RAS target priority");
    rv=0; #1; check(npc==it,"IND fallback");
    iv=0; #1; check(npc==bt,"main BTB fallback");
    bv=0; #1; check(npc==pc+4 && unknown,"unknown JALR continues sequential and requires backend check");
    bv=1; bt=32'hd0000002; #1;
    check(npc==pc+4 && unknown && bad_pred,"unaligned predicted indirect target not rounded");
    inst=32'h00000297; #1; check(auipc && pcop && !push && !pop && npc==pc+4,"AUIPC metadata without control transfer");
    inst=32'h00000001; #1; check(!pcop,"RVC word not predecoded as control flow");
    $display("PASS RV32 decode and target arbitration: %0d checks",checks);
    $finish;
  end
endmodule
