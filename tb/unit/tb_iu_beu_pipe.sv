`timescale 1ns / 1ps

//==========================================================
// tb_iu_beu_pipe —— IU_beu_pipe (IDU 的 BIQ 口 ↔ 老 BEU 的适配级) 的单元台
//==========================================================
// 【守什么】
//   1. **操作数摆放**。BIQ 的 `src1` 是**裸 PRF 读**(不像 AIQ 会切立即数),
//      而老 BEU 里 `npc_jalr = A + B` ⇒ JALR 时 B 必须喂 `br_imme`。
//      喂错的话 JALR 会跳到 "rs2 的值 + 立即数" 那种毫无意义的地方。
//   2. **8 位独热 → is_branch/is_jal/is_jalr + alu_op 的编码转换**。
//      写错一位就是"某条分支判反"。
//   3. **JALR 目标必须 `& ~1`** (RISC-V)。这条是 2026-10-08 刚在 BEU.v 里修掉的 ——
//      老核原来算的是裸 `A+B`, `imm[0]=1` 时会跳错。这里专门造这个用例。
//   4. **重定向的三个门**: `~redirect_in_progress`(RTU 的 trap 优先)、
//      `~chgflw_mask`(慢路冲刷期间屏蔽)、以及"预测对就不发"。
//   5. **完成与解析两条都要报** —— RTU 的 `resolve_hit` 只写 TARGET/TAKEN/MISPRED,
//      **不置 CMPLT**, 少了 cmplt 那条分支永远退不了休。
//==========================================================
module tb_iu_beu_pipe;

  reg         clk = 0;
  reg         rst = 1;
  always #5 clk = ~clk;

  reg         flush = 0;
  reg         sel = 0;
  reg  [6:0]  iid = 0;
  reg  [31:0] src0 = 0, src1 = 0, pc = 0, npc = 0;
  reg         taken = 0;
  reg  [7:0]  rslt_sel = 8'd1;
  reg  [31:0] br_imme = 0;
  reg         dst_vld = 0;
  reg  [5:0]  dst_preg = 0;
  reg         redirect_ip = 0;
  reg         chgflw_mask = 0;

  wire        wb_vld;
  wire [31:0] wb_data;
  wire [63:0] wb_expand;
  wire [5:0]  wb_dupx;
  wire        wb_vld_dupx;
  wire        cmplt_vld;
  wire [6:0]  cmplt_iid;
  wire        res_vld;
  wire [6:0]  res_iid;
  wire        res_taken;
  wire        res_mispred;
  wire [31:0] res_target;
  wire        rd_vld;
  wire [31:0] rd_pc;
  wire        cfl_vld;
  wire [31:0] cfl_pc;
  wire        ex_vld;
  wire [6:0]  ex_iid;
  wire [4:0]  ex_cause;
  wire [31:0] ex_tval;
  wire [31:0] o_npc;
  wire        o_taken;

  // 位序照 ct_idu_rf_pipe6_decd.sv
  localparam [7:0] B_BEQ =8'd1<<0, B_BNE =8'd1<<1, B_BLT =8'd1<<2, B_BGE =8'd1<<3,
                   B_BLTU=8'd1<<4, B_BGEU=8'd1<<5, B_JAL =8'd1<<6, B_JALR=8'd1<<7;

  localparam [31:0] PC0 = 32'h0000_1000;

  IU_beu_pipe u_dut (
    .cpu_clk(clk), .cpu_rst(rst), .idu_flush(flush),
    .idu_sel(sel), .idu_iid(iid), .idu_src0(src0), .idu_src1(src1),
    .idu_pc(pc), .idu_npc(npc), .idu_taken(taken), .idu_rslt_sel(rslt_sel),
    .idu_br_imme(br_imme), .idu_dst_vld(dst_vld), .idu_dst_preg(dst_preg),
    .redirect_in_progress(redirect_ip), .chgflw_mask(chgflw_mask),
    .wb_preg_vld(wb_vld), .wb_preg_data(wb_data), .wb_preg_expand(wb_expand),
    .wb_preg_dupx(wb_dupx), .wb_preg_vld_dupx(wb_vld_dupx),
    .cmplt_vld(cmplt_vld), .cmplt_iid(cmplt_iid),
    .resolve_vld(res_vld), .resolve_iid(res_iid), .resolve_taken(res_taken),
    .resolve_mispred(res_mispred), .resolve_target(res_target),
    .beu_redirect_vld(rd_vld), .iu_chgflw_vld(cfl_vld), .iu_chgflw_pc(cfl_pc),
    .expt_vld(ex_vld), .expt_iid(ex_iid), .expt_cause(ex_cause), .expt_tval(ex_tval),
    .o_actual_npc(o_npc), .o_br_taken(o_taken)
  );

  integer errs = 0;
  integer nchk = 0;

  // 发一条: EX1 看重定向, EX2 看完成/解析/写回
  task automatic go(
      input [7:0] s, input [31:0] a, input [31:0] b, input [31:0] imm,
      input [31:0] pred, input [31:0] exp_npc,
      input exp_taken, input exp_mispred, input [31:0] exp_rd,
      input exp_wr, input [8*44-1:0] name
  );
    begin
      @(negedge clk);
      sel=1'b1; iid=7'h1C; src0=a; src1=b; pc=PC0; npc=pred; br_imme=imm;
      rslt_sel=s; dst_vld=exp_wr; dst_preg=6'd21;
      #1;   // 组合路径稳定
      nchk = nchk + 1;
      if (rd_vld !== exp_mispred) begin
        errs=errs+1;
        $display("  ❌ %0s: EX1 重定向 vld=%b 期望 %b (actual_npc=%h pred=%h)",
                 name, rd_vld, exp_mispred, o_npc, pred);
      end
      else if (exp_mispred && cfl_pc !== exp_npc) begin
        errs=errs+1;
        $display("  ❌ %0s: 重定向目标 %h 期望 %h", name, cfl_pc, exp_npc);
      end
      @(negedge clk);
      sel=1'b0;
      nchk = nchk + 1;
      if (cmplt_vld !== 1'b1 || cmplt_iid !== 7'h1C) begin
        errs=errs+1; $display("  ❌ %0s: 完成口没报 (vld=%b) —— 分支靠它才能退休", name, cmplt_vld);
      end
      else if (res_vld !== 1'b1) begin
        errs=errs+1; $display("  ❌ %0s: 解析口没报", name);
      end
      else if (res_taken !== exp_taken) begin
        errs=errs+1; $display("  ❌ %0s: resolve_taken=%b 期望 %b", name, res_taken, exp_taken);
      end
      else if (res_target !== exp_npc) begin
        errs=errs+1; $display("  ❌ %0s: resolve_target=%h 期望 %h", name, res_target, exp_npc);
      end
      else if (exp_wr && (wb_vld !== 1'b1 || wb_data !== exp_rd)) begin
        errs=errs+1; $display("  ❌ %0s: rd 写回 vld=%b data=%h 期望 %h", name, wb_vld, wb_data, exp_rd);
      end
      else if (!exp_wr && wb_vld !== 1'b0) begin
        errs=errs+1; $display("  ❌ %0s: 不该写 rd 却写了", name);
      end
      else
        $display("  ✅ %0s → npc=%h taken=%b mispred=%b", name, exp_npc, exp_taken, exp_mispred);
      @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    $display("---- 条件分支: 方向 + 目标 + 误预测 ----");
    // BEQ 相等 ⇒ 跳; 预测没跳 ⇒ 误预测, 目标 = pc+imm
    go(B_BEQ, 32'd5, 32'd5, 32'h20, PC0+32'd4, PC0+32'h20, 1'b1, 1'b1, 32'd0, 1'b0, "BEQ 相等→跳(预测错)");
    // BEQ 相等 + 预测也对 ⇒ 不重定向
    go(B_BEQ, 32'd5, 32'd5, 32'h20, PC0+32'h20, PC0+32'h20, 1'b1, 1'b0, 32'd0, 1'b0, "BEQ 相等→跳(预测对)");
    // BEQ 不相等 ⇒ 不跳, npc = pc+4
    go(B_BEQ, 32'd5, 32'd6, 32'h20, PC0+32'h20, PC0+32'd4, 1'b0, 1'b1, 32'd0, 1'b0, "BEQ 不等→不跳(预测错)");
    // BEQ 不相等 + 预测也不跳 ⇒ 不重定向
    go(B_BEQ, 32'd5, 32'd6, 32'h20, PC0+32'd4, PC0+32'd4, 1'b0, 1'b0, 32'd0, 1'b0, "BEQ 不等→不跳(预测对)");
    go(B_BNE, 32'd5, 32'd6, 32'h40, PC0+32'd4, PC0+32'h40, 1'b1, 1'b1, 32'd0, 1'b0, "BNE 不等→跳");
    go(B_BLT, 32'hFFFF_FFFF, 32'd1, 32'h08, PC0+32'd4, PC0+32'h08, 1'b1, 1'b1, 32'd0, 1'b0, "BLT -1<1→跳");
    go(B_BGE, 32'hFFFF_FFFF, 32'd1, 32'h08, PC0+32'd4, PC0+32'd4, 1'b0, 1'b0, 32'd0, 1'b0, "BGE -1>=1→不跳");
    go(B_BLTU,32'hFFFF_FFFF, 32'd1, 32'h0C, PC0+32'd4, PC0+32'd4, 1'b0, 1'b0, 32'd0, 1'b0, "BLTU 大<1→不跳");
    go(B_BGEU,32'hFFFF_FFFF, 32'd1, 32'h0C, PC0+32'd4, PC0+32'h0C, 1'b1, 1'b1, 32'd0, 1'b0, "BGEU 大>=1→跳");

    $display("---- JAL / JALR: 目标 + rd=pc+4 ----");
    go(B_JAL,  32'd0, 32'd0, 32'h100, PC0+32'd4, PC0+32'h100, 1'b1, 1'b1, PC0+32'd4, 1'b1, "JAL 目标 pc+imm, rd=pc+4");
    // JALR: 目标 = (rs1+imm)&~1, **src1(rs2) 必须完全不参与**
    go(B_JALR, 32'h2000, 32'hDEAD_BEEF, 32'h10, PC0+32'd4, 32'h2010, 1'b1, 1'b1, PC0+32'd4, 1'b1, "JALR 用 rs1+imm, 忽略 src1");
    // ★ 关键用例: imm[0]=1 ⇒ 目标必须 (rs1+imm)&~1 = 0x2002, 不是 0x2003
    go(B_JALR, 32'h2000, 32'd0, 32'h03, PC0+32'd4, 32'h2002, 1'b1, 1'b1, PC0+32'd4, 1'b1, "JALR imm[0]=1 ⇒ 清 bit0");
    // ★ 另一个: rs1 奇数 + imm 奇数 ⇒ (奇+奇)&~1 = 偶
    go(B_JALR, 32'h2001, 32'd0, 32'h01, PC0+32'd4, 32'h2002, 1'b1, 1'b1, PC0+32'd4, 1'b1, "JALR 奇+奇 ⇒ 清 bit0");

    $display("---- 重定向的两个门 ----");
    @(negedge clk);
    sel=1; iid=7'h2D; src0=5; src1=5; pc=PC0; npc=PC0+32'd4; br_imme=32'h20;
    rslt_sel=B_BEQ; dst_vld=0; redirect_ip=1'b1;      // RTU 本拍在发 trap
    #1; nchk=nchk+1;
    if (rd_vld !== 1'b0) begin
      errs=errs+1; $display("  ❌ redirect_in_progress=1 时不该发重定向 (会和 trap 打架)");
    end else $display("  ✅ RTU 在发 trap 时 BEU 让路");
    redirect_ip=0; chgflw_mask=1'b1;                  // 慢路冲刷期间
    #1; nchk=nchk+1;
    if (rd_vld !== 1'b0) begin
      errs=errs+1; $display("  ❌ chgflw_mask=1 时不该发重定向 (两次重定向会打架)");
    end else $display("  ✅ 慢路冲刷期间 BEU 被屏蔽");
    chgflw_mask=0; #1; sel=0; @(negedge clk); @(negedge clk);

    $display("---- 取指地址非对齐 → cause 0 ----");
    @(negedge clk);
    sel=1; iid=7'h3E; src0=32'd0; src1=32'd0; pc=PC0; npc=PC0+32'd4;
    br_imme=32'h02; rslt_sel=B_JAL; dst_vld=1; dst_preg=6'd3;   // pc+2 非 4 对齐
    @(negedge clk); sel=0;
    // ⚠️ 这里**不能再等一拍** —— 异常是 EX2 的组合输出, 在 EX1→EX2 那个边沿之后
    //    就已经有效了; 多等一拍 ex2_vld 已被 sel=0 清掉, 会假报"没报异常"。
    nchk=nchk+1;
    if (ex_vld !== 1'b1 || ex_cause !== 5'd0 || ex_tval !== (PC0+32'h02)) begin
      errs=errs+1;
      $display("  ❌ 非对齐目标没报异常 (vld=%b cause=%0d tval=%h)", ex_vld, ex_cause, ex_tval);
    end else $display("  ✅ 目标非对齐 → expt cause=0 tval=%h", ex_tval);
    @(negedge clk);

    if (errs == 0)
      $display("=== IU-BEU-PIPE UNIT: ALL PASS (%0d 项判据) ===", nchk);
    else begin
      $display("=== IU-BEU-PIPE UNIT: FAIL — %0d 条判据不过 / 共 %0d ===", errs, nchk);
      $fatal(1, "checks failed");
    end
    $finish;
  end

  initial begin
    repeat (800) @(posedge clk);
    $display("=== IU-BEU-PIPE UNIT: FAIL — 超时 ===");
    $fatal(1, "timeout");
  end

endmodule
