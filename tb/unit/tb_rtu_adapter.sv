`timescale 1ns/1ps
//==========================================================
// tb_rtu_adapter —— RTU_idu_lsu_adapter 的单元台 (2026-10-08)
//==========================================================
// 【这个台子守什么】
// 适配层不是纯接线 —— 它有**四类有真逻辑的变换**, 每一类都能静默出错:
//   1. `ren_preg_req` 的"三路独立 vld → 程序序前缀计数";
//   2. **映射恢复表的逐槽重排** (32×7 → 32×6)。这是最容易写错的一处:
//      写成"切低位"会把 32 个槽整体错位, 而**功能测试几乎看不出来**
//      (恢复表只在冲刷时用, 而且要正好冲在改过映射的指令上才暴露);
//   3. **异常两源 → 单路, 先 cmplt 门控再比 iid 取最旧**。丢错一条的后果是
//      **年长那条的异常永久丢失** (它按正常流程退休走掉、不会被重取);
//   4. store 重放的两根来源 (`pipe4_flush` / `pipe4_spec_fail`) 都要能触发。
// 这几条在整核 difftest 里都只会表现成"某条指令结果不对", 定位不到适配层,
// 所以在这里用定向激励逐条钉死。
//
// ⚠️ 端口连接是**手写的** (不像 IDU 那个冒烟台是生成的) —— 这个模块的端口表
//    是自研的、不会天天变; 真变了 elaborate 会报, 不会静默漏。
//==========================================================
module tb_rtu_adapter;
  reg clk = 0;  always #5 clk = ~clk;
  reg rst = 1;
  wire cpurst_b;

  // IDU 侧
  reg  [0:0] a0v=0,a1v=0,a2v=0;
  wire [5:0] ap0,ap1,ap2;
  wire ap0v,ap1v,ap2v;
  wire [6:0] ri0,ri1,ri2;  wire rfull;
  wire rflush;  wire [191:0] rrec;
  reg  [63:0] dmask = 64'h0;
  reg  d0v=0; reg [31:0] d0pc=0; reg [24:0] d0chk=0; reg [4:0] d0lreg=0;
  reg  d0we=0; reg [6:0] d0dp=0,d0op=0,d0sp=0; reg [11:0] d0ca=0;
  reg  [2:0] d0co=0; reg [4:0] d0ci=0; reg [6:0] d0fl=0;
  reg  d1v=0; reg [31:0] d1pc=0; reg [24:0] d1chk=0; reg [4:0] d1lreg=0;
  reg  d1we=0; reg [6:0] d1dp=0,d1op=0,d1sp=0; reg [11:0] d1ca=0;
  reg  [2:0] d1co=0; reg [4:0] d1ci=0; reg [6:0] d1fl=0;
  reg  d2v=0; reg [31:0] d2pc=0; reg [24:0] d2chk=0; reg [4:0] d2lreg=0;
  reg  d2we=0; reg [6:0] d2dp=0,d2op=0,d2sp=0; reg [11:0] d2ca=0;
  reg  [2:0] d2co=0; reg [4:0] d2ci=0; reg [6:0] d2fl=0;
  // LSU 侧
  reg [0:0] p3c=0,p3e=0,p4c=0,p4e=0,p4f=0,p4s=0;
  reg [6:0] p3i=0,p4i=0;  reg [31:0] p3a=0,p4a=0;
  // 其它异常源
  reg oev=0; reg [6:0] oei=0; reg [4:0] oec=0; reg [31:0] oet=0;
  // RTU 侧
  wire [1:0] req; wire [4:0] rl0,rl1,rl2;
  reg  [6:0] pa0=0,pa1=0,pa2=0; reg pav0=0,pav1=0,pav2=0;
  wire dv0,dv1,dv2; wire [31:0] pc0,pc1,pc2; wire [24:0] ck0,ck1,ck2;
  wire [4:0] lr0,lr1,lr2; wire w0,w1,w2;
  wire [6:0] dp0,dp1,dp2,op0,op1,op2,sp0,sp1,sp2,fl0,fl1,fl2;
  wire [11:0] ca0,ca1,ca2; wire [2:0] co0,co1,co2; wire [4:0] ci0,ci1,ci2;
  wire [2:0] sq0,sq1,sq2;
  wire c5,i5,c6,i6, lrv; wire [6:0] lri;
  wire ev; wire [6:0] ei; wire [4:0] ec_; wire [31:0] et;
  wire s0,s1,s2,ss; wire [63:0] pdm;
  reg  dstop=0, rf=0, bf=0; reg [223:0] rmap=0; reg [6:0] ti0=0,ti1=0,ti2=0;
  reg  [1:0] fcnt=0;

  RTU_idu_lsu_adapter u (
    .cpu_clk(clk), .cpu_rst(rst), .cpurst_b(cpurst_b),
    .idu_rtu_ir_preg0_alloc_vld(a0v), .idu_rtu_ir_preg1_alloc_vld(a1v),
    .idu_rtu_ir_preg2_alloc_vld(a2v),
    .rtu_idu_alloc_preg0(ap0), .rtu_idu_alloc_preg1(ap1), .rtu_idu_alloc_preg2(ap2),
    .rtu_idu_alloc_preg0_vld(ap0v), .rtu_idu_alloc_preg1_vld(ap1v), .rtu_idu_alloc_preg2_vld(ap2v),
    .rtu_idu_rob_inst0_iid(ri0), .rtu_idu_rob_inst1_iid(ri1), .rtu_idu_rob_inst2_iid(ri2),
    .rtu_idu_rob_full(rfull), .rtu_yy_xx_flush(rflush),
    .rtu_idu_rt_recover_preg(rrec),
    .idu_rtu_pst_preg_dealloc_mask(dmask),
    .idu_rtu_disp0_vld(d0v), .idu_rtu_disp0_pc(d0pc), .idu_rtu_disp0_chk(d0chk),
    .idu_rtu_disp0_dst_lreg(d0lreg), .idu_rtu_disp0_rf_we(d0we),
    .idu_rtu_disp0_dst_preg(d0dp), .idu_rtu_disp0_old_preg(d0op),
    .idu_rtu_disp0_src1_preg(d0sp), .idu_rtu_disp0_csr_addr(d0ca),
    .idu_rtu_disp0_csr_op(d0co), .idu_rtu_disp0_csr_imm(d0ci), .idu_rtu_disp0_flags(d0fl),
    .idu_rtu_disp1_vld(d1v), .idu_rtu_disp1_pc(d1pc), .idu_rtu_disp1_chk(d1chk),
    .idu_rtu_disp1_dst_lreg(d1lreg), .idu_rtu_disp1_rf_we(d1we),
    .idu_rtu_disp1_dst_preg(d1dp), .idu_rtu_disp1_old_preg(d1op),
    .idu_rtu_disp1_src1_preg(d1sp), .idu_rtu_disp1_csr_addr(d1ca),
    .idu_rtu_disp1_csr_op(d1co), .idu_rtu_disp1_csr_imm(d1ci), .idu_rtu_disp1_flags(d1fl),
    .idu_rtu_disp2_vld(d2v), .idu_rtu_disp2_pc(d2pc), .idu_rtu_disp2_chk(d2chk),
    .idu_rtu_disp2_dst_lreg(d2lreg), .idu_rtu_disp2_rf_we(d2we),
    .idu_rtu_disp2_dst_preg(d2dp), .idu_rtu_disp2_old_preg(d2op),
    .idu_rtu_disp2_src1_preg(d2sp), .idu_rtu_disp2_csr_addr(d2ca),
    .idu_rtu_disp2_csr_op(d2co), .idu_rtu_disp2_csr_imm(d2ci), .idu_rtu_disp2_flags(d2fl),
    .lsu_rtu_wb_pipe3_cmplt(p3c), .lsu_rtu_wb_pipe3_iid(p3i),
    .lsu_rtu_wb_pipe3_expt_vld(p3e), .lsu_rtu_wb_pipe3_expt_addr(p3a),
    .lsu_rtu_wb_pipe4_cmplt(p4c), .lsu_rtu_wb_pipe4_iid(p4i),
    .lsu_rtu_wb_pipe4_expt_vld(p4e), .lsu_rtu_wb_pipe4_expt_addr(p4a),
    .lsu_rtu_wb_pipe4_flush(p4f), .lsu_rtu_wb_pipe4_spec_fail(p4s),
    .other_expt_vld(oev), .other_expt_iid(oei), .other_expt_cause(oec), .other_expt_tval(oet),
    .ren_preg_req(req), .ren_preg_req_lreg0(rl0), .ren_preg_req_lreg1(rl1), .ren_preg_req_lreg2(rl2),
    .rtu_preg_alloc0(pa0), .rtu_preg_alloc1(pa1), .rtu_preg_alloc2(pa2),
    .rtu_preg_alloc_vld0(pav0), .rtu_preg_alloc_vld1(pav1), .rtu_preg_alloc_vld2(pav2),
    .disp0_vld(dv0), .disp0_pc(pc0), .disp0_chk(ck0), .disp0_dst_lreg(lr0),
    .disp0_rf_we(w0), .disp0_dst_preg(dp0), .disp0_old_preg(op0), .disp0_src1_preg(sp0),
    .disp0_csr_addr(ca0), .disp0_csr_op(co0), .disp0_csr_imm(ci0), .disp0_flags(fl0), .disp0_sq_id(sq0),
    .disp1_vld(dv1), .disp1_pc(pc1), .disp1_chk(ck1), .disp1_dst_lreg(lr1),
    .disp1_rf_we(w1), .disp1_dst_preg(dp1), .disp1_old_preg(op1), .disp1_src1_preg(sp1),
    .disp1_csr_addr(ca1), .disp1_csr_op(co1), .disp1_csr_imm(ci1), .disp1_flags(fl1), .disp1_sq_id(sq1),
    .disp2_vld(dv2), .disp2_pc(pc2), .disp2_chk(ck2), .disp2_dst_lreg(lr2),
    .disp2_rf_we(w2), .disp2_dst_preg(dp2), .disp2_old_preg(op2), .disp2_src1_preg(sp2),
    .disp2_csr_addr(ca2), .disp2_csr_op(co2), .disp2_csr_imm(ci2), .disp2_flags(fl2), .disp2_sq_id(sq2),
    .cmplt_vld5(c5), .cmplt_iid5(i5), .cmplt_vld6(c6), .cmplt_iid6(i6),
    .lsu_replay_vld(lrv), .lsu_replay_iid(lri),
    .expt_vld(ev), .expt_iid(ei), .expt_cause(ec_), .expt_tval(et),
    .sq_rdy0(s0), .sq_rdy1(s1), .sq_rdy2(s2), .sq_stall(ss),
    .preg_dealloc_mask(pdm),
    .rtu_disp_stall(dstop), .rtu_ren_flush(rf), .rtu_backend_flush(bf),
    .rtu_ren_recover_map(rmap), .rtu_disp_iid0(ti0), .rtu_disp_iid1(ti1), .rtu_disp_iid2(ti2),
    .rtu_preg_free_cnt(fcnt)
  );

  integer errs = 0;
  initial begin
    rst = 1; repeat(4) @(posedge clk); rst = 0; @(posedge clk);
    if (cpurst_b !== 1'b1) begin errs=errs+1; $display("FAIL: cpurst_b 应为 1, 实为 %b", cpurst_b); end
    // 请求计数
    a0v=1; a1v=0; a2v=0; #1;
    if (req !== 2'd1) begin errs=errs+1; $display("FAIL: req=%0d 期望 1", req); end
    a1v=1; #1; if (req !== 2'd2) begin errs=errs+1; $display("FAIL: req=%0d 期望 2", req); end
    a2v=1; #1; if (req !== 2'd3) begin errs=errs+1; $display("FAIL: req=%0d 期望 3", req); end
    a0v=0;a1v=0;a2v=0; #1;
    // 恢复表重排: 槽 3 放 0x2A, 槽 0 放 0x15
    rmap = {224{1'b0}}; rmap[7*3 +: 7] = 7'h2A; rmap[7*0 +: 7] = 7'h15; #1;
    if (rrec[6*3 +: 6] !== 6'h2A) begin errs=errs+1; $display("FAIL: rrec[槽3]=%h 期望 2A", rrec[6*3 +: 6]); end
    if (rrec[6*0 +: 6] !== 6'h15) begin errs=errs+1; $display("FAIL: rrec[槽0]=%h 期望 15", rrec[6*0 +: 6]); end
    // LSU 异常: 只有 store
    p4c=1; p4e=1; p4i=7'h12; p4a=32'hdead; #1;
    if (ev!==1'b1 || ec_!==5'd6 || ei!==7'h12 || et!==32'hdead)
      begin errs=errs+1; $display("FAIL: store 异常 vld=%b cause=%0d iid=%h tval=%h", ev, ec_, ei, et); end
    // 两个源同拍: load iid=0x10(更老) store iid=0x20 ⇒ 应取 load (cause 4)
    p3c=1; p3e=1; p3i=7'h10; p3a=32'hbeef; #1;
    if (ev!==1'b1 || ec_!==5'd4 || ei!==7'h10 || et!==32'hbeef)
      begin errs=errs+1; $display("FAIL: 两源取最旧 vld=%b cause=%0d iid=%h tval=%h", ev, ec_, ei, et); end
    // 反过来: load iid=0x30 (更新) store iid=0x12 (更老) ⇒ 应取 store
    p3i=7'h30; #1;
    if (ev!==1'b1 || ec_!==5'd6 || ei!==7'h12)
      begin errs=errs+1; $display("FAIL: 两源取最旧(反) vld=%b cause=%0d iid=%h (期望 cause=6 iid=12)", ev, ec_, ei); end
    // expt 门控: load 的 cmplt 去掉, 只剩 store ⇒ 仍应报 store 那条
    p3c=0; #1;
    if (ev!==1'b1 || ec_!==5'd6 || ei!==7'h12)
      begin errs=errs+1; $display("FAIL: 只关 load cmplt 时应仍报 store, 实为 vld=%b cause=%0d", ev, ec_); end
    // 两条的 cmplt 都去掉 ⇒ 一条都不该报 (expt 相位门控)
    p4c=0; #1;
    if (ev!==1'b0) begin errs=errs+1; $display("FAIL: cmplt 全 0 时不该报异常, 实为 vld=%b", ev); end
    // 门控的正面用例: 只有 expt_vld 而没有 cmplt ⇒ 仍然不报 (这才是那条修复守的)
    p4e=1; p4c=0; p3e=0; #1;
    if (ev!==1'b0) begin errs=errs+1; $display("FAIL: 有 expt_vld 无 cmplt 时不该报, 实为 vld=%b", ev); end
    // store 重放: 两根都要能触发
    p4f=1; #1; if (lrv!==1'b1) begin errs=errs+1; $display("FAIL: pipe4_flush 没触发重放"); end
    p4f=0; p4s=1; #1; if (lrv!==1'b1) begin errs=errs+1; $display("FAIL: spec_fail 没触发重放"); end
    p4s=0; #1; if (lrv!==1'b0) begin errs=errs+1; $display("FAIL: 两根都 0 时不该重放"); end
    // 派遣记录透传
    d0v=1; d0pc=32'h100; d0dp=7'd33; d0op=7'd1; d0fl=7'b1010101; #1;
    if (dv0!==1'b1 || pc0!==32'h100 || dp0!==7'd33 || op0!==7'd1 || fl0!==7'b1010101 || sq0!==3'd0)
      begin errs=errs+1; $display("FAIL: 派遣记录透传不对"); end
    // preg 切位: RTU 给 7'b1110011 ⇒ IDU 侧应得 6'b110011
    pa0=7'b1110011; pav0=1; #1;
    if (ap0!==6'b110011) begin errs=errs+1; $display("FAIL: preg 切位 ap0=%b 期望 110011", ap0); end

    if (errs==0)
      $display("=== RTU-ADAPTER UNIT: ALL PASS (8 项判据) ===");
    else begin
      $display("=== RTU-ADAPTER UNIT: FAIL — %0d 条判据不过 ===", errs);
      $fatal(1, "checks failed");
    end
    $finish;
  end
endmodule
