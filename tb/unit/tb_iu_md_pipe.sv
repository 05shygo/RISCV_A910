`timescale 1ns / 1ps

//==========================================================
// tb_iu_md_pipe —— IU_md_pipe (IDU 的 MUL/DIV 发射口 ↔ MUL_DIV 单元) 的单元台
//==========================================================
// 【守什么】
//   1. **两个 rslt_sel[3:0] 的独热位序不同** —— mult 的 bit0..3 是 MUL/MULH/
//      MULHSU/MULHU, div 的 bit0..3 是 DIV/DIVU/REM/REMU。同样的 bit 位置含义不同,
//      解码时先看是哪条口。写错一位 = 某条 M 扩展指令算错。
//   2. **tag = {iid, preg} 的打包与拆包** —— 写回时要一次拿回 dst_preg (PRF 写地址)
//      和 iid (RTU 完成口)。拆错位就会"结果写进别人的格子"或"完成报给了别的表项"。
//   3. **写回与完成必须同拍** —— 若 cmplt 比 PRF 写早, RTU 可能先让那条退休 ⇒
//      difftest 读到旧值。
//   4. **div_busy 的可见性** —— 交付的 MD 队列没有反压口, 除法口只在 IDLE 那拍
//      收请求; 这里至少要把 div_busy 引出来, 接线时能拿它设闸。
//==========================================================
module tb_iu_md_pipe;

  reg         clk = 0;
  reg         rst = 1;
  always #5 clk = ~clk;

  reg         flush = 0;
  reg         m_sel = 0;
  reg  [6:0]  m_iid = 0;
  reg  [5:0]  m_preg = 0;
  reg  [31:0] m_s0 = 0, m_s1 = 0;
  reg  [3:0]  m_rs = 4'd1;
  reg         d_sel = 0;
  reg  [6:0]  d_iid = 0;
  reg         d_dvld = 1;
  reg  [5:0]  d_preg = 0;
  reg  [31:0] d_s0 = 0, d_s1 = 0;
  reg  [3:0]  d_rs = 4'd1;

  wire        wb_vld;
  wire [5:0]  wb_dupx;
  wire        wb_vld_dupx;
  wire [31:0] wb_data;
  wire [63:0] wb_expand;
  wire        cm_vld;
  wire [6:0]  cm_iid;
  wire        mul_ready, div_busy, resp_is_div;

  // 位序照 ct_idu_rf_pipe1_decd (乘) / pipe2_decd (除)
  localparam [3:0] M_MUL=4'd1<<0, M_MULH=4'd1<<1, M_MULHSU=4'd1<<2, M_MULHU=4'd1<<3;
  localparam [3:0] D_DIV=4'd1<<0, D_DIVU=4'd1<<1, D_REM =4'd1<<2, D_REMU =4'd1<<3;

  IU_md_pipe u_dut (
    .cpu_clk(clk), .cpu_rst(rst), .idu_flush(flush),
    .idu_mult_sel(m_sel), .idu_mult_iid(m_iid), .idu_mult_dst_preg(m_preg),
    .idu_mult_src0(m_s0), .idu_mult_src1(m_s1), .idu_mult_rslt_sel(m_rs),
    .idu_div_sel(d_sel), .idu_div_iid(d_iid), .idu_div_dst_vld(d_dvld),
    .idu_div_dst_preg(d_preg), .idu_div_src0(d_s0), .idu_div_src1(d_s1),
    .idu_div_rslt_sel(d_rs),
    .wb_preg_vld(wb_vld), .wb_preg_dupx(wb_dupx), .wb_preg_vld_dupx(wb_vld_dupx),
    .wb_preg_data(wb_data), .wb_preg_expand(wb_expand),
    .cmplt_vld(cm_vld), .cmplt_iid(cm_iid),
    .mul_ready(mul_ready), .div_busy(div_busy), .resp_is_div(resp_is_div)
  );

  integer errs = 0, nchk = 0;

  // 发一条乘/除, 等写回, 查结果 + tag 拆包 + 完成口
  task automatic issue_wait(
      input is_div_op,          // 1 = 走除法口
      input [3:0] rs, input [31:0] a, input [31:0] b,
      input [31:0] exp_val, input [8*40-1:0] name
  );
    integer guard;
    begin
      // 等单元能收: 乘看 mul_ready, 除看 !div_busy
      guard = 0;
      while ((is_div_op ? div_busy : ~mul_ready) && guard < 200) begin
        @(negedge clk); guard = guard + 1;
      end
      @(negedge clk);
      m_iid = 7'h55; m_preg = 6'd27; m_s0 = a; m_s1 = b; m_rs = rs;
      d_iid = 7'h55; d_preg = 6'd27; d_s0 = a; d_s1 = b; d_rs = rs; d_dvld = 1'b1;
      if (is_div_op) d_sel = 1'b1; else m_sel = 1'b1;
      @(negedge clk);
      m_sel = 1'b0; d_sel = 1'b0;
      // 等写回
      guard = 0;
      while (wb_vld !== 1'b1 && guard < 200) begin
        @(negedge clk); guard = guard + 1;
      end
      nchk = nchk + 1;
      if (wb_vld !== 1'b1) begin
        errs = errs + 1; $display("  ❌ %0s: 200 拍内没写回", name);
      end
      else if (wb_data !== exp_val) begin
        errs = errs + 1;
        $display("  ❌ %0s: 结果 %h 期望 %h (a=%h b=%h)", name, wb_data, exp_val, a, b);
      end
      else if (wb_dupx !== 6'd27 || wb_expand !== (64'd1 << 6'd27)) begin
        errs = errs + 1;
        $display("  ❌ %0s: tag 的 preg 拆错 (dupx=%0d expand=%h)", name, wb_dupx, wb_expand);
      end
      else if (cm_vld !== 1'b1 || cm_iid !== 7'h55) begin
        errs = errs + 1;
        $display("  ❌ %0s: 完成口不对 (vld=%b iid=%h 期望 55)", name, cm_vld, cm_iid);
      end
      else
        $display("  ✅ %0s → %h (且完成与写回同拍)", name, wb_data);
      @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    $display("---- 乘法四条 ----");
    issue_wait(1'b0, M_MUL,    32'd7,   32'd5,   32'd35,           "MUL     7*5");
    issue_wait(1'b0, M_MUL,    32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'd1, "MUL     (-1)*(-1) 低 32 位");
    issue_wait(1'b0, M_MULH,   32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0000, "MULH    (-1)*(-1) 高 32 位");
    issue_wait(1'b0, M_MULHU,  32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFE, "MULHU   无符号高 32 位");
    issue_wait(1'b0, M_MULHSU, 32'hFFFF_FFFF, 32'd2, 32'hFFFF_FFFF, "MULHSU  -1 * 2 高 32 位");

    $display("---- 除法四条 ----");
    issue_wait(1'b1, D_DIV,  32'd7,  32'd2,  32'd3,          "DIV     7/2");
    // ⚠️ RISC-V 的 DIV 是**向零截断**: -7/2 = -3 (不是 -4 —— 那是向下取整)。
    //    第一版我按 -4 写的, 是**测试写错了**, DUT 给的 -3 是对的。
    issue_wait(1'b1, D_DIV,  32'hFFFF_FFF9, 32'd2, 32'hFFFF_FFFD, "DIV     -7/2 (向零截断 = -3)");
    issue_wait(1'b1, D_DIVU, 32'hFFFF_FFFF, 32'd2, 32'h7FFF_FFFF, "DIVU    无符号");
    issue_wait(1'b1, D_REM,  32'hFFFF_FFF9, 32'd2, 32'hFFFF_FFFF, "REM     -7%2 (符号跟被除数)");
    issue_wait(1'b1, D_REMU, 32'hFFFF_FFFF, 32'd2, 32'd1,    "REMU    无符号取余");

    $display("---- div_busy 可见性 (交付的 MD 队列没有反压口, 靠它设闸) ----");
    @(negedge clk);
    d_iid=7'h11; d_preg=6'd3; d_s0=32'd100; d_s1=32'd7; d_rs=D_DIV; d_dvld=1'b1;
    d_sel = 1'b1;
    @(negedge clk);
    d_sel = 1'b0;
    @(negedge clk);
    @(negedge clk);
    nchk = nchk + 1;
    if (div_busy !== 1'b1) begin
      errs = errs + 1; $display("  ❌ 除法在飞时 div_busy 没拉起来 —— 上层没法设闸");
    end else $display("  ✅ 除法在飞时 div_busy=1 (上层可据此设发射闸)");
    // 等它写完
    begin : wait_done
      integer g; g = 0;
      while (wb_vld !== 1'b1 && g < 200) begin @(negedge clk); g = g + 1; end
    end
    @(negedge clk);

    $display("---- 冲刷: 在飞的乘法不该再报写回 ----");
    @(negedge clk);
    m_iid=7'h22; m_preg=6'd5; m_s0=32'd3; m_s1=32'd3; m_rs=M_MUL;
    m_sel = 1'b1;
    @(negedge clk);
    m_sel = 1'b0;
    @(negedge clk);           // 乘法在飞 (3 级)
    flush = 1'b1;
    @(negedge clk);
    flush = 1'b0;
    begin : chk_flush
      integer g; integer seen; seen = 0;
      for (g = 0; g < 12; g = g + 1) begin
        @(negedge clk);
        if (wb_vld === 1'b1) seen = seen + 1;
      end
      nchk = nchk + 1;
      if (seen != 0) begin
        errs = errs + 1;
        $display("  ❌ 被冲刷的乘法还报了 %0d 次写回 —— RTU 会收到一条不该有的完成", seen);
      end else $display("  ✅ 被冲刷的乘法没有写回");
    end

    if (errs == 0)
      $display("=== IU-MD-PIPE UNIT: ALL PASS (%0d 项判据) ===", nchk);
    else begin
      $display("=== IU-MD-PIPE UNIT: FAIL — %0d 条判据不过 / 共 %0d ===", errs, nchk);
      $fatal(1, "checks failed");
    end
    $finish;
  end

  initial begin
    repeat (4000) @(posedge clk);
    $display("=== IU-MD-PIPE UNIT: FAIL — 超时 ===");
    $fatal(1, "timeout");
  end

endmodule
