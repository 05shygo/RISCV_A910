//=============================================================================
// tb_lsiq_equiv —— 参数化 LSIQ (ct_idu_is_lsiq @ LSIQ_ENTRY=8) 与参数化之前的
//                 原版 (HEAD 里那份, 改名为 _ref) 的**逐拍等价**自检台。
//
// 【为什么要有它】把写死的 8 项 LSIQ 改成 generate 通用版, 正确性不能靠"跑一遍
//   difftest 没红"。这个台子把两份 RTL 并排喂**同一串激励** (开环: 两边输入完全
//   一样, 不看各自输出), 逐拍比所有输出 + 所有内部状态。第一处分歧就停, 并把当时
//   的输入和两边的状态全打出来 —— 修的时候不用猜。
//
// 比什么:
//   输出   : lsiq_ctrl_full_updt / lsiq_ctrl_1_left_updt / lsiq_rf_pipe3_issue_en /
//            lsiq_rf_pipe4_issue_en / lsiq_dp_pipe3/4_issue_entry /
//            lsiq_dp_pipe3/4_entry_read_data / *_entry_unalign_2nd / *_entry_old
//   内部   : lsiq_entry_cnt / lsiq_entry_vld / lsiq_entry_ready / lsiq_entry_issue_en
//            / 每个表项存着的 agevec 与 agevec_all
//
// ⚠️ agevec 两种约定不同 (新版 N 位自屏蔽 vs 原版 N-1 位紧凑), 不能直接比位;
//   这里按"第 i 项看第 j 项"的语义映射后再比 (见 old_idx)。
//
// ⚠️ 激励必须遵守两条**硬件契约**, 否则会假红 (原版自己在那两支上不自洽):
//   1) create1_en ⟹ create0_en —— ct_idu_ir_ctrl.sv:644 结构性成立。
//      原版的 full/1_left 用的是独热 create 编码 (create_2 = create1_en), 而它
//      自己的计数器用的是二进制和; 两者只在契约下一致。
//   2) lsu_idu_lsiq_pop_vld == pop0_vld | pop1_vld —— lsu_top.sv:307。
//=============================================================================
`timescale 1ns/1ps
module tb_lsiq_equiv;

  localparam int N = 8;

  logic        clk = 0;
  logic        cpurst_b = 0;
  logic        c0, c1;
  logic [59:0] d0, d1;
  logic [5:0]  wbp0, wbp1, wbp2, wbp3;
  logic        wbv0, wbv1, wbv2, wbv3;
  logic        flush;

  logic [N-1:0] lq_full, rb_full, sq_full, secd, imme_wakeup, pop_entry;
  logic         lq_nf, rb_nf, sq_nf;
  logic         pop0_vld, pop1_vld, pop_vld;

  logic         new_left, new_full, new_p3en, new_p4en;
  logic         ref_left, ref_full, ref_p3en, ref_p4en;
  logic [59:0]  new_p3rd, new_p4rd, ref_p3rd, ref_p4rd;
  // 2026-10-19 停用: new 侧非对齐第二半标记已摘除
  logic         new_p3old, new_p4old;
  logic         ref_p3un, ref_p3old, ref_p4un, ref_p4old;
  logic [N-1:0] new_p3iss, new_p4iss, ref_p3iss, ref_p4iss;

  assign pop_vld = pop0_vld | pop1_vld;   // 契约 2

  //--------------------------------------------------------------- 新版 DUT
  ct_idu_is_lsiq #(.LSIQ_ENTRY(N)) u_new (
    .cpurst_b                          (cpurst_b  ),
    .ctrl_lsiq_create0_en              (c0        ),
    .ctrl_lsiq_create1_en              (c1        ),
    .dp_lsiq_create0_data              (d0        ),
    .dp_lsiq_create1_data              (d1        ),
    .forever_cpuclk                    (clk       ),
    .iu_idu_ex2_pipe0_wb_preg_dupx     (wbp0      ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx (wbv0      ),
    .iu_idu_ex2_pipe1_wb_preg_dupx     (wbp1      ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx (wbv1      ),
    .iu_idu_ex2_pipe2_wb_preg_dupx     (wbp2      ),
    .iu_idu_ex2_pipe2_wb_preg_vld_dupx (wbv2      ),
    .lsu_idu_lq_full                   (lq_full   ),
    .lsu_idu_lq_not_full               (lq_nf     ),
    .lsu_idu_lsiq_pop0_vld             (pop0_vld  ),
    .lsu_idu_lsiq_pop1_vld             (pop1_vld  ),
    .lsu_idu_lsiq_pop_entry            (pop_entry ),
    .lsu_idu_lsiq_pop_vld              (pop_vld   ),
    .lsu_idu_rb_full                   (rb_full   ),
    .lsu_idu_rb_not_full               (rb_nf     ),
    // 2026-10-19 停用: .lsu_idu_secd    (secd      ),
    .lsu_idu_sq_full                   (sq_full   ),
    .lsu_idu_sq_not_full               (sq_nf     ),
    .lsu_idu_imme_wakeup               (imme_wakeup),
    .lsu_idu_wb_pipe3_wb_preg_dupx     (wbp3      ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx (wbv3      ),
    .rtu_yy_xx_flush                   (flush     ),
    .lsiq_ctrl_1_left_updt             (new_left  ),
    .lsiq_ctrl_full_updt               (new_full  ),
    .lsiq_rf_pipe3_issue_en            (new_p3en  ),
    .lsiq_rf_pipe4_issue_en            (new_p4en  ),
    .lsiq_dp_pipe3_entry_read_data     (new_p3rd  ),
    // 2026-10-19 停用: .lsiq_pipe3_entry_unalign_2nd (new_p3un),
    .lsiq_pipe3_entry_old              (new_p3old ),
    .lsiq_dp_pipe3_issue_entry         (new_p3iss ),
    .lsiq_dp_pipe4_entry_read_data     (new_p4rd  ),
    // 2026-10-19 停用: .lsiq_pipe4_entry_unalign_2nd (new_p4un),
    .lsiq_pipe4_entry_old              (new_p4old ),
    .lsiq_dp_pipe4_issue_entry         (new_p4iss )
  );

  //--------------------------------------------------------------- 原版 DUT
  ct_idu_is_lsiq_ref u_ref (
    .cpurst_b                          (cpurst_b  ),
    .ctrl_lsiq_create0_en              (c0        ),
    .ctrl_lsiq_create1_en              (c1        ),
    .dp_lsiq_create0_data              (d0        ),
    .dp_lsiq_create1_data              (d1        ),
    .forever_cpuclk                    (clk       ),
    .iu_idu_ex2_pipe0_wb_preg_dupx     (wbp0      ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx (wbv0      ),
    .iu_idu_ex2_pipe1_wb_preg_dupx     (wbp1      ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx (wbv1      ),
    .iu_idu_ex2_pipe2_wb_preg_dupx     (wbp2      ),
    .iu_idu_ex2_pipe2_wb_preg_vld_dupx (wbv2      ),
    .lsu_idu_lq_full                   (lq_full   ),
    .lsu_idu_lq_not_full               (lq_nf     ),
    .lsu_idu_lsiq_pop0_vld             (pop0_vld  ),
    .lsu_idu_lsiq_pop1_vld             (pop1_vld  ),
    .lsu_idu_lsiq_pop_entry            (pop_entry ),
    .lsu_idu_lsiq_pop_vld              (pop_vld   ),
    .lsu_idu_rb_full                   (rb_full   ),
    .lsu_idu_rb_not_full               (rb_nf     ),
    .lsu_idu_secd                      (secd      ),
    .lsu_idu_sq_full                   (sq_full   ),
    .lsu_idu_sq_not_full               (sq_nf     ),
    .lsu_idu_imme_wakeup               (imme_wakeup),
    .lsu_idu_wb_pipe3_wb_preg_dupx     (wbp3      ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx (wbv3      ),
    .rtu_yy_xx_flush                   (flush     ),
    .lsiq_ctrl_1_left_updt             (ref_left  ),
    .lsiq_ctrl_full_updt               (ref_full  ),
    .lsiq_rf_pipe3_issue_en            (ref_p3en  ),
    .lsiq_rf_pipe4_issue_en            (ref_p4en  ),
    .lsiq_dp_pipe3_entry_read_data     (ref_p3rd  ),
    .lsiq_pipe3_entry_unalign_2nd      (ref_p3un  ),
    .lsiq_pipe3_entry_old              (ref_p3old ),
    .lsiq_dp_pipe3_issue_entry         (ref_p3iss ),
    .lsiq_dp_pipe4_entry_read_data     (ref_p4rd  ),
    .lsiq_pipe4_entry_unalign_2nd      (ref_p4un  ),
    .lsiq_pipe4_entry_old              (ref_p4old ),
    .lsiq_dp_pipe4_issue_entry         (ref_p4iss )
  );

  //-------------------------------------------------- 每项存着的 agevec (取出来比)
  logic [N-1:0] new_av  [N];
  logic [N-1:0] new_ava [N];
  logic [N-2:0] ref_av  [N];
  logic [N-2:0] ref_ava [N];
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_av
      assign new_av[gi]  = u_new.g_lsiq_entry[gi].u_ct_idu_is_lsiq_entry.agevec;
      assign new_ava[gi] = u_new.g_lsiq_entry[gi].u_ct_idu_is_lsiq_entry.agevec_all;
    end
  endgenerate

  // 原版是 8 份写死的实例名, 只能一条条列。
  always_comb begin
    ref_av[0]  = u_ref.u_ct_idu_is_lsiq_entry0.agevec;
    ref_av[1]  = u_ref.u_ct_idu_is_lsiq_entry1.agevec;
    ref_av[2]  = u_ref.u_ct_idu_is_lsiq_entry2.agevec;
    ref_av[3]  = u_ref.u_ct_idu_is_lsiq_entry3.agevec;
    ref_av[4]  = u_ref.u_ct_idu_is_lsiq_entry4.agevec;
    ref_av[5]  = u_ref.u_ct_idu_is_lsiq_entry5.agevec;
    ref_av[6]  = u_ref.u_ct_idu_is_lsiq_entry6.agevec;
    ref_av[7]  = u_ref.u_ct_idu_is_lsiq_entry7.agevec;
    ref_ava[0] = u_ref.u_ct_idu_is_lsiq_entry0.agevec_all;
    ref_ava[1] = u_ref.u_ct_idu_is_lsiq_entry1.agevec_all;
    ref_ava[2] = u_ref.u_ct_idu_is_lsiq_entry2.agevec_all;
    ref_ava[3] = u_ref.u_ct_idu_is_lsiq_entry3.agevec_all;
    ref_ava[4] = u_ref.u_ct_idu_is_lsiq_entry4.agevec_all;
    ref_ava[5] = u_ref.u_ct_idu_is_lsiq_entry5.agevec_all;
    ref_ava[6] = u_ref.u_ct_idu_is_lsiq_entry6.agevec_all;
    ref_ava[7] = u_ref.u_ct_idu_is_lsiq_entry7.agevec_all;
  end

  // 原版 agevec 的第 j 位 (j = 在"除 i 外按序号升序"里的位置)
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

  function automatic logic new_bit_a(input int i, input int j);
    return new_ava[i][j];
  endfunction

  function automatic logic ref_bit_a(input int i, input int j);
    return ref_ava[i][old_idx(i,j)];
  endfunction

  //--------------------------------------------------------------- 比对 + 激励
  int cyc = 0, errs = 0;
  int cov_issue = 0, cov_full = 0, cov_left = 0, cov_cre = 0, cov_flush = 0;
  int cov_pop = 0, cov_pop2 = 0;
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

  task automatic chkv(input string nm, input logic [N-1:0] a, input logic [N-1:0] b);
    if (a !== b) begin
      $display("  [MISMATCH] cyc=%0d  %0s: new=%b ref=%b", cyc, nm, a, b);
      errs = errs + 1;
    end
  endtask

  task automatic dump_inputs;
    $display("    in : c0=%b c1=%b flush=%b pop0=%b pop1=%b pop_e=%b lq_f=%b sq_f=%b rb_f=%b secd=%b",
             c0, c1, flush, pop0_vld, pop1_vld, pop_entry, lq_full, sq_full, rb_full, secd);
    $display("    new: cnt=%0d vld=%b rdy=%b iss=%b p3iss=%b p4iss=%b full=%b left=%b",
             u_new.lsiq_entry_cnt, u_new.lsiq_entry_vld, u_new.lsiq_entry_ready,
             u_new.lsiq_entry_issue_en, new_p3iss, new_p4iss, new_full, new_left);
    $display("    ref: cnt=%0d vld=%b rdy=%b iss=%b p3iss=%b p4iss=%b full=%b left=%b",
             u_ref.lsiq_entry_cnt, u_ref.lsiq_entry_vld, u_ref.lsiq_entry_ready,
             u_ref.lsiq_entry_issue_en, ref_p3iss, ref_p4iss, ref_full, ref_left);
  endtask

  always #5 clk = ~clk;

  // 激励: 分段 (灌满 / 单建表 / 排空 / 随机), 每个 negedge 先比后驱
  always @(negedge clk) begin
    int e0;
    if (cpurst_b) begin
      // ---- 比对 (状态已在上一个 posedge 之后稳定) ----
      e0 = errs;
      chk("full_updt", new_full, ref_full);
      chk("1_left_updt", new_left, ref_left);
      chk("rf_pipe3_issue_en", new_p3en, ref_p3en);
      chk("rf_pipe4_issue_en", new_p4en, ref_p4en);
      chkv("dp_pipe3_issue_entry", new_p3iss, ref_p3iss);
      chkv("dp_pipe4_issue_entry", new_p4iss, ref_p4iss);
      if (new_p3rd !== ref_p3rd) begin
        $display("  [MISMATCH] cyc=%0d  p3_read_data: new=%h ref=%h", cyc, new_p3rd, ref_p3rd);
        errs = errs + 1;
      end
      if (new_p4rd !== ref_p4rd) begin
        $display("  [MISMATCH] cyc=%0d  p4_read_data: new=%h ref=%h", cyc, new_p4rd, ref_p4rd);
        errs = errs + 1;
      end
      // 2026-10-19 停用: new 侧不再有非对齐第二半标记, ref 侧该输出 (恒 0 或 x) 不再参与比对
      chk("p3_old",         new_p3old, ref_p3old);
      chk("p4_old",         new_p4old, ref_p4old);
      if (u_new.lsiq_entry_cnt !== u_ref.lsiq_entry_cnt) begin
        $display("  [MISMATCH] cyc=%0d  cnt: new=%0d ref=%0d", cyc,
                 u_new.lsiq_entry_cnt, u_ref.lsiq_entry_cnt);
        errs = errs + 1;
      end
      chkv("entry_vld",      u_new.lsiq_entry_vld,      u_ref.lsiq_entry_vld);
      chkv("entry_ready",    u_new.lsiq_entry_ready,    u_ref.lsiq_entry_ready);
      chkv("entry_issue_en", u_new.lsiq_entry_issue_en, u_ref.lsiq_entry_issue_en);
      for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
          if (i != j) begin
            if (new_bit(i,j) !== ref_bit(i,j)) begin
              $display("  [MISMATCH] cyc=%0d  agevec[%0d][%0d]: new=%b ref=%b", cyc,
                       i, j, new_bit(i,j), ref_bit(i,j));
              errs = errs + 1;
            end
            if (new_bit_a(i,j) !== ref_bit_a(i,j)) begin
              $display("  [MISMATCH] cyc=%0d  agevec_all[%0d][%0d]: new=%b ref=%b", cyc,
                       i, j, new_bit_a(i,j), ref_bit_a(i,j));
              errs = errs + 1;
            end
          end
      if (errs != e0) begin
        dump_inputs;
        // $fatal: 退出码非 0 ⇒ `make lsiq-equiv` 直接红, 能被门禁脚本判
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
      lq_full = '0; sq_full = '0; rb_full = '0; secd = '0; imme_wakeup = '0;
      pop_entry = '0; pop0_vld = 0; pop1_vld = 0;
      lq_nf = 0; sq_nf = 0; rb_nf = 0;
    end
    else begin
      cpurst_b = 1'b1;
      flush    = (($urandom() % 150) == 0);          // 偶发冲刷
      // 60 位随机指令数据 —— 但 LOAD/STORE 两位要有偏向, 否则两种类型都出不来。
      d0 = {$urandom(), $urandom()};
      d1 = {$urandom(), $urandom()};
      d0[48] = (($urandom() % 100) < 45);   // LSIQ_STORE
      d0[47] = (($urandom() % 100) < 45);   // LSIQ_LOAD
      d1[48] = (($urandom() % 100) < 45);
      d1[47] = (($urandom() % 100) < 45);
      // 写回激励: 让表项真的能"等来操作数"
      wbv0 = (($urandom() % 100) < 25);  wbp0 = $urandom() % 64;
      wbv1 = (($urandom() % 100) < 25);  wbp1 = $urandom() % 64;
      wbv2 = (($urandom() % 100) < 25);  wbp2 = $urandom() % 64;
      wbv3 = (($urandom() % 100) < 25);  wbp3 = $urandom() % 64;
      // LSU 侧"队列满"掩码与 not_full 都是随机的 (真核里由 LSU 给)
      lq_full     = $urandom();
      sq_full     = $urandom();
      rb_full     = $urandom();
      secd        = '0;   // 2026-10-19: new 侧不再接收 secd, 令 ref 侧也恒 0 以保持等价
      imme_wakeup = $urandom();
      lq_nf = (($urandom() % 100) < 60);
      sq_nf = (($urandom() % 100) < 60);
      rb_nf = (($urandom() % 100) < 60);
      pop0_vld = (($urandom() % 100) < 35);
      pop1_vld = (($urandom() % 100) < 35);
      // pop_entry: 一半随机 (含无效位), 一半只点有效项 (让队列真能排空)
      pop_entry = (($urandom() % 2) == 0) ? $urandom()
                                          : ($urandom() & u_new.lsiq_entry_vld);
      case (cyc % 280)
        default: begin
          if      ((cyc % 280) <  70) begin c0 = 1'b1; c1 = 1'b1; end  // 灌满
          else if ((cyc % 280) < 100) begin c0 = 1'b1; c1 = 1'b0; end  // 单建表
          else if ((cyc % 280) < 190) begin c0 = 1'b0; c1 = 1'b0; end  // 排空
          else begin                                                   // 随机
            c0 = (($urandom() % 100) < 60);
            c1 = c0 && (($urandom() % 100) < 50);   // create1 ⟹ create0 (硬件契约)
          end
        end
      endcase
    end

    // ---- 覆盖统计 ----
    if (cpurst_b) begin
      if (new_p3en || new_p4en) cov_issue = cov_issue + 1;
      if (new_full)  cov_full  = cov_full  + 1;
      if (new_left)  cov_left  = cov_left  + 1;
      if (c0 || c1)  cov_cre   = cov_cre   + 1;
      if (flush)     cov_flush = cov_flush + 1;
      if (pop0_vld || pop1_vld) cov_pop = cov_pop + 1;
      if (pop0_vld && pop1_vld) cov_pop2 = cov_pop2 + 1;
      if (u_new.lsiq_entry_cnt <= N)
        cov_cnt[u_new.lsiq_entry_cnt] = cov_cnt[u_new.lsiq_entry_cnt] + 1;
      else
        cov_cnt_over = cov_cnt_over + 1;
    end

    if (cyc >= 200000) begin
      $display("");
      $display("================ tb_lsiq_equiv 结果 ================");
      $display("  跑 %0d 拍, 不一致 %0d 处", cyc, errs);
      $display("  覆盖: 发射 %0d 拍 | full %0d 拍 | 1_left %0d 拍 | 建表 %0d 拍 | 冲刷 %0d 次 | pop %0d 拍 (双 pop %0d)",
               cov_issue, cov_full, cov_left, cov_cre, cov_flush, cov_pop, cov_pop2);
      $display("  LSIQ 占用分布 (cnt=0..%0d): %0d %0d %0d %0d %0d %0d %0d %0d %0d   [cnt>N: %0d 拍]",
               N, cov_cnt[0], cov_cnt[1], cov_cnt[2], cov_cnt[3], cov_cnt[4],
               cov_cnt[5], cov_cnt[6], cov_cnt[7], cov_cnt[8], cov_cnt_over);
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
