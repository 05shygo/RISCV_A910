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
//   5. **反压闭环: `md_unit_stall` 必须覆盖除法在飞的全过程, 一拍都不能漏**
//      (2026-10-11 立)。IDU 只看这一个信号, 且**当拍就 pop 表项** ⇒ 它认为能发
//      而 wrapper 没收下 = 那条指令蒸发、RTU 表项永不完成 = 死等。
//      ⚠️ 光接 `div_busy` 不够: 保持了请求、但 div_pipe 还在 ST_IDLE 的那一拍
//      `div_busy` 仍是 0。这就是下面"反压闭环"一段专治的洞 —— 上面那个
//      `issue_wait` 抓不到它, 因为它每次都等单元空了才发、发一条等一条,
//      **永远构不成背靠背**。改这一段的驱动方式前请先读那段长注。
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
  wire        md_unit_stall;

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
    .mul_ready(mul_ready), .div_busy(div_busy), .resp_is_div(resp_is_div),
    .md_unit_stall(md_unit_stall)
  );

  integer errs = 0, nchk = 0;

  // ---------------------------------------------------------------------
  // 写回计数器 —— 给下面"反压闭环"那一段用
  //   wb_vld 每条结果只脉冲一拍 (乘: resp_vld_r 寄存器; 除: state==ST_RESP 单拍),
  //   所以按拍数就是按条数。乘 II=1 连发时它会连续拉高, 那也是对的 —— 每拍一条。
  // ---------------------------------------------------------------------
  integer n_issue = 0, n_wb = 0;
  always @(posedge clk) begin
    if (!rst && wb_vld === 1'b1) n_wb = n_wb + 1;
  end

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

  // ---------------------------------------------------------------------
  // 【反压闭环】按**真实 IDU 的语义**驱动, 不再"等单元空了才发"
  // ---------------------------------------------------------------------
  // 为什么必须单开一段: 上面的 `issue_wait` 每次都等 `!div_busy` 才发、且发一条
  // 等一条, 于是**永远构不成背靠背** —— 而恰恰是背靠背那一拍有洞。
  //
  // 真实 IDU (`ct_idu_is_md`) 只看 `md_unit_stall`: 它低就发, 并且**当拍就把表项
  // pop 掉** (`md_xx_issue_en` 是单拍脉冲, ct_idu_is_md.sv:143)。所以
  //     "IDU 认为能发" 与 "wrapper 真的收下" 必须**逐拍一致**;
  // 差一拍, 那条指令就凭空蒸发, RTU 的表项永远不完成 ⇒ 死等。
  //
  // 判据: **发出去的条数 == 写回来的条数**。本段没有冲刷, 单元里也不该有
  //       被丢弃的在飞项, 所以这个等式必须严格成立。
  //
  // ⚠️ 除法要发的条数按"队列里总有货"算 —— 模拟 `md_xx_issue_en` 每拍都可能拉高。
  //
  // ⚠️⚠️ 2026-10-15 修 (coremark_i1 卡在 `divu` 上, 就是这段 TB 漏掉的那一拍):
  //   **`idu_div_sel` 不是 `md_xx_issue_en`, 而是它打了一拍的结果。**
  //   `ct_idu_rf_ctrl.sv:117` 写着 `rf_pipe2_inst_vld <= div_xx_issue_en`
  //   (乘法是 `rf_pipe1_inst_vld`, 同理), 也就是 IDU 的 RF 流水线里有一级寄存器。
  //   所以"队列发出决策"与"单元看到请求"**天然差一拍**:
  //
  //     拍     | 队列决策 (issue_en)   | 单元看到的 sel | 单元收不收
  //     -------+-----------------------+----------------+-----------
  //      A     | 发第 1 条             | (上一条 或 0)  | —
  //      A+1   | 发第 2 条 ← **要挡这** | 第 1 条        | 收 (hold←1)
  //      A+2   | (该被挡住)            | 第 2 条        | 收不收?
  //
  //   老驱动把 `d_sel` 当成"当拍决策"直接摆出去 (same-cycle 语义), 于是**永远
  //   构不成"单元看着上一条、队列发下一条"的那个窗口** —— 单元 TB 因此一路绿灯,
  //   而整机在 `core_print_int` 的 `remu`/`divu` 背靠背上死锁。
  //   这里补上一级流水线寄存器 (`d_pd_*`/`m_pd_*`), 让驱动**逐位对上真实 IDU**。
  //
  //   ⇒ 所以 `md_unit_stall` 必须连"这一拍正在被收下"(`div_accept`) 一起盖住;
  //     不盖的话第 A+1 拍队列以为端口空闲、照发第 2 条, 而那一条到 A+2 拍
  //     `div_accept = sel & ~hold & ~busy = 0`、`mul_req_vld = 0` ⇒ **静默蒸发**,
  //     且队列那一拍已经把表项 pop 掉了, 补救不回来。
  task automatic idu_style_issue(
      input integer n_div,
      input integer n_mul,
      input integer max_cyc
  );
    integer cyc, di, mi;
    // 发射流水线寄存器 (= 真实 IDU 的 rf_pipe{1,2}_inst_vld 那一级 + RF 读出口)
    reg          d_pd_vld, m_pd_vld;
    reg          ie_d, ie_m;
    reg [6:0]    d_pd_iid,  m_pd_iid;
    reg [5:0]    d_pd_preg, m_pd_preg;
    reg [31:0]   d_pd_s0, d_pd_s1, m_pd_s0, m_pd_s1;
    reg [3:0]    d_pd_rs, m_pd_rs;
    begin
      di = 0; mi = 0; cyc = 0;
      d_pd_vld = 1'b0; m_pd_vld = 1'b0;
      d_sel = 1'b0; m_sel = 1'b0;
      // 循环条件带上流水线寄存器: 最后一条也要**真摆到端口上**才算发完
      while (((di < n_div) || (mi < n_mul) || d_pd_vld || m_pd_vld)
             && (cyc < max_cyc)) begin
        // ---- 本拍: 把流水线寄存器摆到端口 (= 单元的 idu_div_sel / idu_mult_sel) ----
        d_sel  = d_pd_vld;   m_sel  = m_pd_vld;
        d_iid  = d_pd_iid;   m_iid  = m_pd_iid;
        d_preg = d_pd_preg;  m_preg = m_pd_preg;
        d_s0   = d_pd_s0;    m_s0   = m_pd_s0;
        d_s1   = d_pd_s1;    m_s1   = m_pd_s1;
        d_rs   = d_pd_rs;    m_rs   = m_pd_rs;
        d_dvld = d_pd_vld;
        // ⚠️ 必须让组合逻辑**落定**再读 `md_unit_stall`。它是这些端口的组合函数
        //    (含 `div_accept = idu_div_sel & ~hold & ~busy`) —— 而连续赋值要等下一个
        //    delta 才更新, 同一拍紧接着直接读会拿到**上一拍的旧值**。
        //    实测症状 (2026-10-15, 就是这段): cyc=1 那拍 `dsel=1` 而 `acc`/`stall`
        //    读出来还是 0 ⇒ 第二条除被误判成"端口空"发出 ⇒ 到下一拍被单元丢掉。
        //    真实 IDU 里 `sel` 是寄存器输出, 组合逻辑有整拍时间落定, 不存在这个问题。
        //    `#1` = 1ns; 时钟 `always #5` ⇒ 距下一个 posedge 还有 4ns, 不会踩到。
        #1;
        // 摆完之后 `md_unit_stall` 才是本拍的真值。
        // ---- 决策: 只看 md_unit_stall —— IDU 的全部视角 (它没有别的反压输入) ----
        // 乘、除是两条独立队列, **可以同拍都发**
        ie_d = (di < n_div) && (md_unit_stall === 1'b0);
        ie_m = (mi < n_mul) && (md_unit_stall === 1'b0);
        if ($test$plusargs("MDDBG"))
          $display("  [TB] cyc=%0d dsel=%b dpd=%b msel=%b mpd=%b | stall=%b hold=%b busy=%b acc=%b state=%0d req=%b resp=%b wb=%b | ie_d=%b ie_m=%b di=%0d mi=%0d",
            cyc, d_sel, d_pd_vld, m_sel, m_pd_vld,
            md_unit_stall, u_dut.div_hold_vld, u_dut.div_busy, u_dut.div_accept,
            u_dut.u_muldiv.U_DIV_PIPE.state, u_dut.req_vld_mux, u_dut.resp_valid, wb_vld,
            ie_d, ie_m, di, mi);
        if (ie_d) begin
          d_pd_iid  = 7'h30 + di[6:0];
          d_pd_preg = 6'd10 + di[5:0];
          d_pd_s0   = 32'd1000 + di;  d_pd_s1 = 32'd7;
          d_pd_rs   = D_DIV;
          di = di + 1;  n_issue = n_issue + 1;
        end
        if (ie_m) begin
          m_pd_iid  = 7'h30 + mi[6:0];
          m_pd_preg = 6'd40 + mi[5:0];
          m_pd_s0   = 32'd3 + mi;     m_pd_s1 = 32'd5;
          m_pd_rs   = M_MUL;
          mi = mi + 1;  n_issue = n_issue + 1;
        end
        @(negedge clk);
        // 时钟沿: 流水线寄存器更新 (上一拍决策的内容本拍已经摆出去/被收下了)
        d_pd_vld = ie_d;  m_pd_vld = ie_m;
        cyc = cyc + 1;
      end
      d_sel = 1'b0; m_sel = 1'b0; d_pd_vld = 1'b0; m_pd_vld = 1'b0;
      if ((di < n_div) || (mi < n_mul))
        $display("  ⚠️ 驱动超时: 只发出 %0d/%0d 除 + %0d/%0d 乘", di, n_div, mi, n_mul);
    end
  endtask

  // 等管道排空: 连续 `quiet` 拍没有写回就算空了 (最后一条除法最多 ~35 拍)
  task automatic drain(input integer quiet);
    integer q, g;
    begin
      q = 0; g = 0;
      while ((q < quiet) && (g < 600)) begin
        @(negedge clk);
        if (wb_vld === 1'b1) q = 0; else q = q + 1;
        g = g + 1;
      end
    end
  endtask

  // 一段"按 IDU 语义发 + 排空 + 对数"的完整检查
  task automatic check_backpressure(
      input integer n_div, input integer n_mul, input [8*48-1:0] name
  );
    integer iss, got;
    begin
      drain(8);                      // 先把上一段的残留排干净, 再清计数
      n_issue = 0; n_wb = 0;
      idu_style_issue(n_div, n_mul, 400);
      drain(8);
      iss = n_issue; got = n_wb;
      nchk = nchk + 1;
      if (got !== iss) begin
        errs = errs + 1;
        $display("  ❌ %0s: IDU 发出 %0d 条, 单元只写回 %0d 条 —— **%0d 条被静默丢弃** (那条永远不会完成)",
                 name, iss, got, iss - got);
      end
      else $display("  ✅ %0s: 发 %0d 回 %0d (逐拍对齐)", name, iss, got);
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

    $display("---- 反压闭环: 按 IDU 语义驱动, 发出条数必须等于写回条数 ----");
    // 这三种是同一个洞的三个入口: div_hold_vld 已置起、而 div_pipe 还在 ST_IDLE
    // 的那一拍 (`md_unit_stall` 若只接 div_busy, 这拍是 0)。IDU 会照发并 pop 表项,
    // 而 wrapper 两个口都不收 ⇒ 指令蒸发。
    check_backpressure(2, 0, "背靠背两条除");
    check_backpressure(1, 2, "同拍发一除一乘 + 次拍再来一条乘");
    check_backpressure(3, 4, "除乘混发若干条");

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
