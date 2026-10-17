`timescale 1ns / 1ps

//==========================================================
// tb_iu_wb_arb —— 两个执行单元抢同一写回口的严格 round-robin 仲裁
//==========================================================
// 【守什么】
//   1. **绝不双授权** —— 双授权会让两个结果同拍写同一个 PRF 口;
//   2. **授权必须对应请求** —— 没请求也拉 grant 会让上游误以为结果被取走;
//   3. **单请求每拍都能拿口** —— 不能因为"上一拍是它"而空转;
//   4. **双请求严格交替** —— MD 至少每两拍拿到一次口, 这是 MD skid 深度 2
//      不溢出、ALU1 不被饿死的前提;
//   5. **请求保持到授权** —— 这是两个调用方的共同协议 (EX2 保持 / FIFO 队头保持)。
//
// 判定方式: 台子里放一个与 DUT 同构的期望模型 (last 位 + 同样的 grant 方程),
// 每拍逐位比对; 另加定向段和一段确定性 LFSR 随机段。
//==========================================================
module tb_iu_wb_arb;

  reg         clk = 0;
  reg         rst = 1;
  always #5 clk = ~clk;

  reg         flush = 0;
  reg         req_a = 0;
  reg         req_b = 0;
  wire        gnt_a, gnt_b, last_b;

  integer errs = 0, nchk = 0;

  IU_wb_arb u_dut (
    .cpu_clk (clk),
    .cpu_rst (rst),
    .flush   (flush),
    .req_a   (req_a),
    .req_b   (req_b),
    .gnt_a   (gnt_a),
    .gnt_b   (gnt_b),
    .last_b  (last_b)
  );

  // ---------------------------------------------------------------------
  // 期望模型: 与 DUT 的 RR 状态同构
  //   exp_last 在 posedge 更新; exp_a/exp_b 用当前 req + 寄存状态组合算出。
  //   由于 TB 在 negedge 比, 这时 posedge 已过、req 也刚摆好 ⇒ 三者可直接比。
  // ---------------------------------------------------------------------
  reg  exp_last = 0;
  wire exp_a = req_a & (~req_b | exp_last);
  wire exp_b = req_b & (~req_a | ~exp_last);

  always @(posedge clk) begin
    if (rst)            exp_last <= 1'b0;
    else if (flush)     exp_last <= 1'b0;
    else if (exp_b)     exp_last <= 1'b1;
    else if (exp_a)     exp_last <= 1'b0;
  end

  // 每拍比对 + 两条硬不变量
  // ⚠️ #1: 驱动段在同一个 negedge 才摆 req, 而连续赋值要等 delta 才更新。
  //    不加这 1ns 会读到上一拍的 grant (本仓其它台踩过同款, 见 iu-md-unit)。
  always @(negedge clk) begin
    #1;
    if (!rst) begin
      nchk = nchk + 1;
      if (gnt_a !== exp_a || gnt_b !== exp_b) begin
        errs = errs + 1;
        $display("  ❌ RR 不符 @%0t: req=(%b,%b) gnt=(%b,%b) exp=(%b,%b) last=%b",
                 $time, req_a, req_b, gnt_a, gnt_b, exp_a, exp_b, exp_last);
      end
      if (gnt_a === 1'b1 && gnt_b === 1'b1) begin
        errs = errs + 1;
        $display("  ❌ 双授权 @%0t —— 两次写回会同拍撞同一个 PRF 口", $time);
      end
      if ((gnt_a === 1'b1 && req_a !== 1'b1) ||
          (gnt_b === 1'b1 && req_b !== 1'b1)) begin
        errs = errs + 1;
        $display("  ❌ 无请求却授权 @%0t (req=%b%b gnt=%b%b)",
                 $time, req_a, req_b, gnt_a, gnt_b);
      end
    end
  end

  // 确定性 LFSR (不依赖 $urandom 的全局种子)
  reg  [31:0] lfsr = 32'h1ace_b00c;
  function automatic lfsr_next(input [31:0] s);
    lfsr_next = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
  endfunction

  integer i;
  integer g_a_cnt, g_b_cnt;
  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    $display("---- 单请求 ----");
    // A only: 连续 5 拍都必须拿到
    for (i = 0; i < 5; i = i + 1) begin
      req_a = 1'b1; req_b = 1'b0;
      @(negedge clk);
      nchk = nchk + 1;
      if (gnt_a !== 1'b1 || gnt_b !== 1'b0) begin
        errs = errs + 1;
        $display("  ❌ A 单请求没拿到口 (gnt_a=%b)", gnt_a);
      end
    end
    req_a = 1'b0;
    @(negedge clk);
    // B only: 连续 5 拍都必须拿到
    for (i = 0; i < 5; i = i + 1) begin
      req_a = 1'b0; req_b = 1'b1;
      @(negedge clk);
      nchk = nchk + 1;
      if (gnt_b !== 1'b1 || gnt_a !== 1'b0) begin
        errs = errs + 1;
        $display("  ❌ B 单请求没拿到口 (gnt_b=%b)", gnt_b);
      end
    end
    req_b = 1'b0;
    @(negedge clk);
    $display("  ✅ 单请求每拍都拿到口");

    $display("---- 双请求: 严格交替 ----");
    g_a_cnt = 0; g_b_cnt = 0;
    for (i = 0; i < 16; i = i + 1) begin
      req_a = 1'b1; req_b = 1'b1;
      @(negedge clk);
      if (gnt_a === 1'b1) g_a_cnt = g_a_cnt + 1;
      if (gnt_b === 1'b1) g_b_cnt = g_b_cnt + 1;
    end
    nchk = nchk + 1;
    if (g_a_cnt + g_b_cnt !== 16 || (g_a_cnt - g_b_cnt > 1) || (g_b_cnt - g_a_cnt > 1)) begin
      errs = errs + 1;
      $display("  ❌ 16 拍双请求授权不均衡: A=%0d B=%0d", g_a_cnt, g_b_cnt);
    end
    else
      $display("  ✅ 16 拍双请求: A=%0d B=%0d (交替, 差 ≤1)", g_a_cnt, g_b_cnt);
    req_a = 1'b0; req_b = 1'b0;
    @(negedge clk);

    $display("---- 随机请求 (确定性 LFSR) ----");
    for (i = 0; i < 20000; i = i + 1) begin
      lfsr = lfsr_next(lfsr);
      req_a = lfsr[0];
      req_b = lfsr[1];
      @(negedge clk);
    end
    req_a = 1'b0; req_b = 1'b0;
    @(negedge clk);

    $display("---- flush / 复位状态 ----");
    req_a = 1'b1; req_b = 1'b1;
    @(negedge clk);
    @(negedge clk);
    flush = 1'b1;
    @(negedge clk);
    flush = 1'b0;
    req_a = 1'b0; req_b = 1'b0;
    @(negedge clk);
    // 下一拍双请求应轮到 A (flush 把 last 清 0)
    req_a = 1'b1; req_b = 1'b1;
    @(negedge clk);
    nchk = nchk + 1;
    if (gnt_a !== 1'b1) begin
      errs = errs + 1;
      $display("  ❌ flush 后双请求应先给 A (gnt_a=%b)", gnt_a);
    end
    else
      $display("  ✅ flush 后 RR 状态清回 A");

    if (errs == 0)
      $display("=== IU-WB-ARB UNIT: ALL PASS (%0d 项判据) ===", nchk);
    else begin
      $display("=== IU-WB-ARB UNIT: FAIL — %0d 条判据不过 / 共 %0d ===", errs, nchk);
      $fatal(1, "checks failed");
    end
    $finish;
  end

  initial begin
    repeat (60000) @(posedge clk);
    $display("=== IU-WB-ARB UNIT: FAIL — 超时 ===");
    $fatal(1, "timeout");
  end

endmodule
