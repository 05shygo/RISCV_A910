//=============================================================================
// tb_biq_equiv —— 参数化 BIQ (ct_idu_is_biq @ BIQ_ENTRY=4) 与参数化之前的原版
//                 (HEAD 里那份, 改名为 _ref) 的**逐拍等价**自检台。
//
// 【为什么要有它】把写死的 4 项 AIQ 改成 generate 通用版, 正确性不能靠"跑一遍
//   difftest 没红"。这个台子把两份 RTL 并排喂**同一串激励** (开环: 两边输入
//   完全一样, 不看各自输出), 逐拍比所有输出 + 所有内部状态。第一处分歧就停,
//   并把当时的输入和两边的状态全打出来 —— 修的时候不用猜。
//
// 比什么:
//   输出   : biq_xx_issue_en / biq_dp_issue_read_data / biq_ctrl_full_updt /
//            biq_ctrl_1_left_updt
//   内部   : biq_entry_cnt / biq_entry_vld / biq_entry_ready / biq_entry_issue_en
//            / 每个表项存着的 agevec
//
// ⚠️ agevec 两种约定不同 (新版 N 位自屏蔽 vs 原版 N-1 位紧凑), 不能直接比位;
//   这里按"第 i 项看第 j 项"的语义映射后再比 (见 old_idx)。
//=============================================================================
`timescale 1ns/1ps
module tb_biq_equiv;

  localparam int N = 4;

  logic        clk = 0;
  logic        cpurst_b = 0;
  logic        c0, c1;
  logic [151:0] d0, d1;
  logic [5:0]  wbp0, wbp1, wbp2, wbp3;
  logic        wbv0, wbv1, wbv2, wbv3;
  logic        flush;

  logic        new_left, new_full, new_issue, ref_left, ref_full, ref_issue;
  logic [151:0] new_rdata, ref_rdata;

  //--------------------------------------------------------------- 新版 DUT
  ct_idu_is_biq #(.BIQ_ENTRY(N)) u_new (
    .biq_ctrl_1_left_updt              (new_left ),
    .biq_ctrl_full_updt                (new_full ),
    .biq_xx_issue_en                   (new_issue),
    .biq_dp_issue_read_data            (new_rdata),
    .cpurst_b                          (cpurst_b ),
    .ctrl_biq_create0_en               (c0       ),
    .ctrl_biq_create1_en               (c1       ),
    .dp_biq_create0_data               (d0       ),
    .dp_biq_create1_data               (d1       ),
    .forever_cpuclk                    (clk      ),
    .iu_idu_ex2_pipe0_wb_preg_dupx     (wbp0     ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx (wbv0     ),
    .iu_idu_ex2_pipe1_wb_preg_dupx     (wbp1     ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx (wbv1     ),
    .iu_idu_ex2_pipe2_wb_preg_dupx     (wbp2     ),
    .iu_idu_ex2_pipe2_wb_preg_vld_dupx (wbv2     ),
    .lsu_idu_wb_pipe3_wb_preg_dupx     (wbp3     ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx (wbv3     ),
    .rtu_yy_xx_flush                   (flush    )
  );

  //--------------------------------------------------------------- 原版 DUT
  ct_idu_is_biq_ref u_ref (
    .biq_ctrl_1_left_updt              (ref_left ),
    .biq_ctrl_full_updt                (ref_full ),
    .biq_xx_issue_en                   (ref_issue),
    .biq_dp_issue_read_data            (ref_rdata),
    .cpurst_b                          (cpurst_b ),
    .ctrl_biq_create0_en               (c0       ),
    .ctrl_biq_create1_en               (c1       ),
    .dp_biq_create0_data               (d0       ),
    .dp_biq_create1_data               (d1       ),
    .forever_cpuclk                    (clk      ),
    .iu_idu_ex2_pipe0_wb_preg_dupx     (wbp0     ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx (wbv0     ),
    .iu_idu_ex2_pipe1_wb_preg_dupx     (wbp1     ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx (wbv1     ),
    .iu_idu_ex2_pipe2_wb_preg_dupx     (wbp2     ),
    .iu_idu_ex2_pipe2_wb_preg_vld_dupx (wbv2     ),
    .lsu_idu_wb_pipe3_wb_preg_dupx     (wbp3     ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx (wbv3     ),
    .rtu_yy_xx_flush                   (flush    )
  );

  //-------------------------------------------------- 每项存着的 agevec (取出来比)
  logic [N-1:0] new_av [N];
  logic [N-2:0] ref_av [N];
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_av
      assign new_av[gi] = u_new.g_biq_entry[gi].entry_agevec;
      assign ref_av[gi] = (gi == 0) ? u_ref.biq_entry0_agevec :
                          (gi == 1) ? u_ref.biq_entry1_agevec :
                          (gi == 2) ? u_ref.biq_entry2_agevec :
                                      u_ref.biq_entry3_agevec;
    end
  endgenerate

  // 原版 agevec 的第 j 位 (j = 在"除 i 外按序号降序"里的位置)
  function automatic int old_idx(input int i, input int j);
    int c;
    c = 0;
    for (int k = 0; k < N; k++)
      if (k != i && k < j) c = c + 1;
    return c;
  endfunction

  // 新版第 i 项的 agevec 第 j 位 (自屏蔽约定: 位 j ↔ 表项 j)
  function automatic logic new_bit(input int i, input int j);
    return new_av[i][j];
  endfunction

  function automatic logic ref_bit(input int i, input int j);
    return ref_av[i][old_idx(i,j)];
  endfunction

  //--------------------------------------------------------------- 比对 + 激励
  int cyc = 0, errs = 0;
  int cov_issue = 0, cov_full = 0, cov_left = 0, cov_cre = 0, cov_flush = 0;
  int cov_cnt [N+1];
  // 开环激励会走到"队列已满还硬建表"这一支 (真核里被 ctrl_is_dis_stall 闸住,
  // 这里故意喂进去)。那一支下 cnt 会跑到 N 以上 (建表请求被记账, 但优先级编码
  // 已经没有空项可给), 所以单独计数 —— 不能让它悄悄丢出直方图外。
  int cov_cnt_over = 0;
  initial for (int k = 0; k <= N; k++) cov_cnt[k] = 0;

  task automatic chk(input string nm, input logic a, input logic b);
    if (a !== b) begin
      $display("  [MISMATCH] cyc=%0d  %0s: new=%b ref=%b", cyc, nm, a, b);
      errs = errs + 1;
    end
  endtask

  task automatic dump_inputs;
    $display("    in : c0=%b c1=%b flush=%b wb(v=%b%b%b%b p=%0d,%0d,%0d,%0d)",
             c0, c1, flush, wbv0, wbv1, wbv2, wbv3, wbp0, wbp1, wbp2, wbp3);
    $display("    new: cnt=%0d vld=%b rdy=%b iss=%b full=%b left=%b | av=%b %b %b %b",
             u_new.biq_entry_cnt, u_new.biq_entry_vld, u_new.biq_entry_ready,
             u_new.biq_entry_issue_en, new_full, new_left,
             new_av[0], new_av[1], new_av[2], new_av[3]);
    $display("    ref: cnt=%0d vld=%b rdy=%b iss=%b full=%b left=%b | av=%b %b %b %b",
             u_ref.biq_entry_cnt, u_ref.biq_entry_vld, u_ref.biq_entry_ready,
             u_ref.biq_entry_issue_en, ref_full, ref_left,
             ref_av[0], ref_av[1], ref_av[2], ref_av[3]);
  endtask

  always #5 clk = ~clk;

  // 激励: 分段 (灌满 / 单建表 / 排空 / 随机), 每个 negedge 先比后驱
  always @(negedge clk) begin
    int e0;
    if (cpurst_b) begin
      // ---- 比对 (状态已在上一个 posedge 之后稳定) ----
      e0 = errs;
      chk("issue_en", new_issue, ref_issue);
      if (new_rdata !== ref_rdata) begin
        $display("  [MISMATCH] cyc=%0d  read_data: new=%h ref=%h", cyc, new_rdata, ref_rdata);
        errs = errs + 1;
      end
      chk("full_updt", new_full, ref_full);
      chk("1_left_updt", new_left, ref_left);
      if (u_new.biq_entry_cnt !== u_ref.biq_entry_cnt) begin
        $display("  [MISMATCH] cyc=%0d  cnt: new=%0d ref=%0d", cyc,
                 u_new.biq_entry_cnt, u_ref.biq_entry_cnt);
        errs = errs + 1;
      end
      if (u_new.biq_entry_vld !== u_ref.biq_entry_vld) begin
        $display("  [MISMATCH] cyc=%0d  vld: new=%b ref=%b", cyc,
                 u_new.biq_entry_vld, u_ref.biq_entry_vld);
        errs = errs + 1;
      end
      if (u_new.biq_entry_ready !== u_ref.biq_entry_ready) begin
        $display("  [MISMATCH] cyc=%0d  ready: new=%b ref=%b", cyc,
                 u_new.biq_entry_ready, u_ref.biq_entry_ready);
        errs = errs + 1;
      end
      if (u_new.biq_entry_issue_en !== u_ref.biq_entry_issue_en) begin
        $display("  [MISMATCH] cyc=%0d  issue_en: new=%b ref=%b", cyc,
                 u_new.biq_entry_issue_en, u_ref.biq_entry_issue_en);
        errs = errs + 1;
      end
      for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
          if (i != j && new_bit(i,j) !== ref_bit(i,j)) begin
            $display("  [MISMATCH] cyc=%0d  agevec[%0d][%0d]: new=%b ref=%b", cyc,
                     i, j, new_bit(i,j), ref_bit(i,j));
            errs = errs + 1;
          end
      if (errs != e0) begin
        dump_inputs;
        // $fatal: 退出码非 0 ⇒ `make biq-equiv` 直接红, 能被门禁脚本判
        $fatal(1, "  ==> 第一处分歧, 停在 cyc=%0d", cyc);
      end
    end

    // ---- 驱动下一拍 ----
    cyc = cyc + 1;
    if (cyc < 4) begin
      cpurst_b = 1'b0;
      c0 = 0; c1 = 0; flush = 0;
      d0 = '0; d1 = '0;
      wbv0 = 0; wbv1 = 0; wbv2 = 0; wbv3 = 0;
      wbp0 = 0; wbp1 = 0; wbp2 = 0; wbp3 = 0;
    end
    else begin
      cpurst_b = 1'b1;
      flush    = (($urandom() % 150) == 0);          // 偶发冲刷
      d0       = {$urandom(), $urandom(), $urandom()};   // 95 位随机 (含 src preg/wb)
      d1       = {$urandom(), $urandom(), $urandom()};
      // 写回激励: 让表项真的能"等来操作数"
      wbv0 = (($urandom() % 100) < 25);  wbp0 = $urandom() % 64;
      wbv1 = (($urandom() % 100) < 25);  wbp1 = $urandom() % 64;
      wbv2 = (($urandom() % 100) < 25);  wbp2 = $urandom() % 64;
      wbv3 = (($urandom() % 100) < 25);  wbp3 = $urandom() % 64;
      case (cyc % 240)
        0  : begin end
        default: begin
          if      ((cyc % 240) <  60) begin c0 = 1'b1; c1 = 1'b1; end  // 灌满
          else if ((cyc % 240) <  90) begin c0 = 1'b1; c1 = 1'b0; end  // 单建表
          else if ((cyc % 240) < 180) begin c0 = 1'b0; c1 = 1'b0; end  // 排空
          else begin                                                   // 随机
            c0 = (($urandom() % 100) < 60);
            c1 = c0 && (($urandom() % 100) < 50);   // create1 ⟹ create0 (硬件契约)
          end
        end
      endcase
    end

    // ---- 覆盖统计 ----
    if (cpurst_b) begin
      if (new_issue) cov_issue = cov_issue + 1;
      if (new_full)  cov_full  = cov_full  + 1;
      if (new_left)  cov_left  = cov_left  + 1;
      if (c0 || c1)  cov_cre   = cov_cre   + 1;
      if (flush)     cov_flush = cov_flush + 1;
      if (u_new.biq_entry_cnt <= N)
        cov_cnt[u_new.biq_entry_cnt] = cov_cnt[u_new.biq_entry_cnt] + 1;
      else
        cov_cnt_over = cov_cnt_over + 1;
    end

    if (cyc >= 200000) begin
      $display("");
      $display("================ tb_biq_equiv 结果 ================");
      $display("  跑 %0d 拍, 不一致 %0d 处", cyc, errs);
      $display("  覆盖: 发射 %0d 拍 | full %0d 拍 | 1_left %0d 拍 | 建表 %0d 拍 | 冲刷 %0d 次",
               cov_issue, cov_full, cov_left, cov_cre, cov_flush);
      $display("  AIQ 占用分布 (cnt=0..%0d): %0d %0d %0d %0d %0d   [cnt>N: %0d 拍]",
               N, cov_cnt[0], cov_cnt[1], cov_cnt[2], cov_cnt[3], cov_cnt[4], cov_cnt_over);
      if (cov_cnt_over > 0) begin
        $display("    ⚠️ cnt>N 那 %0d 拍是开环激励『满着还硬建表』走出来的", cov_cnt_over);
        $display("       (真核里被 ctrl_is_dis_stall 闸住, 不可达) —— 两份 RTL 在这一支上");
        $display("       同样逐拍一致, 属额外覆盖。");
      end
      if (errs == 0) $display("  ===> PASS: 参数化版本 (N=%0d) 与原版逐拍一致", N);
      else           $display("  ===> FAIL: 见上面的 MISMATCH");
      $display("==================================================");
      $finish;
    end
  end

endmodule
