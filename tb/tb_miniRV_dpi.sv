module tb_miniRV_dpi;
  import "DPI-C" context function void gm_init(input string path);
  import "DPI-C" context function int gm_check_step(input int dut_wb_have_inst,
                                             input int dut_wb_pc,
                                             input int dut_wb_ena,
                                             input int dut_wb_reg,
                                             input int dut_wb_value,
                                             input int dut_wb_irq_safe);
  import "DPI-C" context function int gm_halted();
  import "DPI-C" context function int gm_exit_code();
  import "DPI-C" context function void gm_set_cycle(input int c);
  import "DPI-C" context function void gm_set_timer(input int lo, input int hi);
  import "DPI-C" context function void gm_set_irq(input int pending);
  import "DPI-C" context function int gm_check_csr(input int dut_mstatus, input int dut_mie,
                                            input int dut_mtvec, input int dut_mscratch,
                                            input int dut_mepc, input int dut_mcause,
                                            input int dut_mtval, input int dut_mip);

  logic clk = 0;
  logic rst = 1;
  integer cycles = 0;
  integer max_cycles;
  string wave_name;
  // +BENCH 时才对定向基准 (asm/branch_bench.S) 做分场景计数与报告;
  // 整场基准 (CoreMark) 不加这个 plusarg ⇒ 计数逻辑完全不参与。
  logic bench_en = 0;
  initial if ($test$plusargs("BENCH")) bench_en = 1;

  always #5 clk = ~clk; // 100MHz

  initial begin
    // Hold reset asserted for several cycles to ensure DUT initializes
    repeat (20) @(posedge clk);
    rst = 0;
    $display("[mycpu] Reset done.");
    // No warm-up needed: the golden model is commit-driven, so it stays put
    // until the DUT retires its first instruction. Difftest is active from here.
    $display("[difftest] Test Start!");
  end

  miniRV_SoC dut (
    .fpga_rst(rst),
    .fpga_clk(clk),
    .debug_wb_have_inst(),
    .debug_wb_pc(),
    .debug_wb_ena(),
    .debug_wb_reg(),
    .debug_wb_value()
  );

  // Workaround: miniRV_SoC uses an internal clock variable (cpu_clk)
  // initialized from fpga_clk instead of a continuous assignment.
  // Force internal cpu_clk to follow the TB clock without modifying original RTL.
  initial begin
    force dut.cpu_clk = clk;
    force dut.fpga_clk = clk;
  end

`ifdef FSDB
  initial begin
    if (!$value$plusargs("WAVE=%s", wave_name)) wave_name = "waves";
    $fsdbDumpfile({"waveform/", wave_name, ".fsdb"});
    $fsdbDumpvars(0, tb_miniRV_dpi);
  end
`endif
  // Always dump VCD as a fallback so waves are available even if FSDB PLI isn't linked
  // DISABLED for CoreMark performance - VCD dump significantly slows simulation
  // initial begin
  //   if (!$value$plusargs("WAVE=%s", wave_name)) wave_name = "waves";
  //   $dumpfile({"waveform/", wave_name, ".vcd"});
  //   $dumpvars(0, tb_miniRV_dpi);
  // end

  initial begin
    string bin_path = "meminit.bin"; // Makefile links TEST.bin -> meminit.bin
    gm_init(bin_path);
  end

  // TIMER(mtime) 采样: 直接读 DUT 的真实寄存器, 保证按构造一致.
  //
  // 为什么要延迟: DUT 在 MEM 级读到 mtime, 而 TB 要到下一拍才在 WB 上看见这条
  // 指令(EX_MEM->MEM_WB 一拍), golden model 又是在"提交"那一刻才执行它. 所以
  // 它需要的正是 1 拍前的 mtime. 级数若不对, 第一次 timer 读就会 difftest 报错
  // (实测: 2 拍时参考值比 DUT 小 1).
  logic [63:0] mtime_d1;
  always @(posedge clk) begin
    mtime_d1 <= dut.u_bridge.mtime;
  end

  // Difftest: called every cycle, but the golden model only advances on cycles
  // where the DUT reports a valid writeback commit (see dpi/dpi_shim.c).
  // 定时器中断挂起位: 直接采 DUT 内部【它自己正在用的那一级寄存信号】,
  // 这样 golden model 拿到的与 DUT 判据用的逐位相同, 不需要事后校准延迟.
  // 绝不能改成让 golden model 自己用 mtime/mtimecmp 重算 —— DUT 的 mtimecmp
  // 是时序寄存器, 而 golden model 是提交步进的, 那样必然差拍.
  wire dut_timer_irq = dut.Core_cpu.timer_irq_d1;

  // 位号: 与 mySoC/defines.vh 一致 (MIE=3, MPIE=7, MTIE=MTIP=7)
  localparam int MSTATUS_MIE_BIT  = 3;
  localparam int MSTATUS_MPIE_BIT = 7;
  localparam int MIE_MTIE_BIT     = 7;

  // DUT 的 CSR 读回值 (与 CSR.v 的组合读逻辑一致)
  function automatic int dut_csr_mstatus();
    dut_csr_mstatus = int'(32'h0) | int'(32'd3 << 11)
                    | int'(dut.Core_cpu.U_CSR.mstatus_mpie << MSTATUS_MPIE_BIT)
                    | int'(dut.Core_cpu.U_CSR.mstatus_mie  << MSTATUS_MIE_BIT);
  endfunction
  function automatic int dut_csr_mie();
    dut_csr_mie = int'(dut.Core_cpu.U_CSR.mie_mtie) << MIE_MTIE_BIT;
  endfunction
  function automatic int dut_csr_mtvec();
    dut_csr_mtvec = int'((dut.Core_cpu.U_CSR.mtvec & ~32'h3) | (dut.Core_cpu.U_CSR.mtvec & 32'h1));
  endfunction
  function automatic int dut_csr_mip();
    dut_csr_mip = int'(dut_timer_irq) << MIE_MTIE_BIT;
  endfunction

`ifdef USE_IFU2
  // ---------------------------------------------------------------------------
  // ifu2 (自研 2 级前端) 观测
  //
  // 下面那一大段 `ifdef USE_IFU 的探针绑的是旧层次 (dut.Core_cpu.u_ifu_subsys.
  // u_ifu_top.u_bp_top...), IFU=2 时整个不编译 —— 这里只留对照实验真正需要的
  // 几个量: 周期数是所有 A/B 的主指标, 其余用来解释周期花在哪。
  // 完整探针 (L0/BHT/GHR) 在 Phase 4 补。
  // ---------------------------------------------------------------------------
  integer n2_retire   = 0;   // 退休指令数
  integer n2_bubble   = 0;   // 核心在等、IFU 没货的拍数
  integer n2_init     = 0;   // IFU 初始化完成前的拍数
  integer n2_biu_txn  = 0;   // BIU 读事务数 (i-cache 行填充)
  integer n2_cond     = 0;   // 条件分支 (EX 解析)
  integer n2_mis_cond = 0;   // 条件分支误预测
  integer n2_jmp      = 0;   // jal / jalr
  integer n2_mis_jmp  = 0;   // jal / jalr 误预测

  // branch_bench 的逐类统计。口径与 `ifdef USE_IFU 那一段完全一致 (同样的
  // ~stall & ~redirect 门控, 同样的 PC 区间), 这样两边的准确率可以直接对比。
  function automatic integer bench_class2(input [31:0] pc);
    if      (pc >= 32'h0000_0100 && pc < 32'h0000_0140) return 1;
    else if (pc >= 32'h0000_0140 && pc < 32'h0000_01c0) return 2;
    else if (pc >= 32'h0000_01c0 && pc < 32'h0000_0250) return 3;
    else if (pc >= 32'h0000_0250 && pc < 32'h0000_0290) return 4;
    else if (pc >= 32'h0000_0290 && pc < 32'h0000_0320) return 5;
    else                                                return 0;
  endfunction

  integer bc2_cond [0:5];    // 逐类条件分支数
  integer bc2_mis  [0:5];    // 逐类条件分支误预测
  integer bc2_jmp  [0:5];    // 逐类 jal/jalr
  integer bc2_misj [0:5];    // 逐类 jal/jalr 误预测

  // ⚠️ 必须显式清零: integer 数组上电是 X, 而 `X + 1` 还是 X, 计数会永远出不来。
  initial begin
    integer i2;
    for (i2 = 0; i2 <= 5; i2 = i2 + 1) begin
      bc2_cond[i2] = 0; bc2_mis[i2] = 0; bc2_jmp[i2] = 0; bc2_misj[i2] = 0;
    end
  end

  // NPC_SEL 编码 (mySoC/defines.vh): 0=NEXT 1=BRANCH 2=ALU(jalr) 3=JAL
  wire [1:0] n2_npc_op   = dut.Core_cpu.ex_npc_op;
  wire       n2_ex_vld   = dut.Core_cpu.have_inst_EX & ~dut.Core_cpu.stall
                          & ~dut.Core_cpu.redirect;
  wire       n2_is_cond  = n2_ex_vld & (dut.Core_cpu.ex_npc_op == 2'd1);
  wire       n2_is_jmp   = n2_ex_vld & ((dut.Core_cpu.ex_npc_op == 2'd2) ||
                                        (dut.Core_cpu.ex_npc_op == 2'd3));
  wire       n2_misp     = dut.Core_cpu.mispredict & n2_ex_vld;

  // ---------------------------------------------------------------------------
  // 气泡归因 (互斥分桶, 口径与 `ifdef USE_IFU 的 report_bubble_stats 完全一致,
  // 这样两个前端的账可以直接并排看)。
  //
  // ifu2 特有的子归因: "核在等、IFU 没货" 时 IFU 到底卡在哪 ——
  //   * cache 没有这一行 (q_hit=0): 回填通路
  //   * 有货但队列是空的 (q_hit=1 且 ib_cnt=0): 取指没跟上消费
  // ---------------------------------------------------------------------------
  integer b2_accept=0, b2_init=0, b2_flush=0, b2_stall=0, b2_nofetch=0;
  integer b2_nf_miss=0, b2_nf_qempty=0, b2_nf_other=0;
  integer b2_raw_stall=0, b2_raw_div=0, b2_raw_mul=0, b2_raw_loaduse=0;
  integer b2_trap=0, b2_misp=0;
  // 重定向后到下一次 if_accept 的等待拍数 (只归因, 不与上面互斥)
  integer b2_rf_redir=0, b2_rf_flush=0, b2_ev_redir=0, b2_ev_flush=0;
  reg     b2_rf_armed = 1'b0;
  reg     b2_rf_isflush = 1'b0;

`ifdef M2PROBE
  // ---------------------------------------------------------------------------
  // 误预测归因: "方向表猜错" 还是 "BTB 根本没这条分支"?
  //   chk[15] = 预测时该 slot 在 BTB 里有没有条目
  //   chk[16] = 预测时的方向
  // 两者的修法完全不同 —— 前者要加历史/换索引, 后者要加 CAM/容量。
  // ---------------------------------------------------------------------------
  integer m2_cond=0, m2_cond_mis=0, m2_cond_nobtb=0, m2_cond_dir=0;
  integer m2_jmp=0,  m2_jmp_mis=0,  m2_jmp_nobtb=0,  m2_jmp_tgt=0;
  integer m2_pt_nt=0, m2_pn_t=0;      // 过预测 taken / 漏预测 taken (条件分支)
  // 逐 PC 误预测直方图 (按 pc[9:2], 256 档), 用来找"责任最大的那几条静态分支"
  integer m2_hist_mis [0:255];
  integer m2_hist_ct  [0:255];

  initial begin
    integer z;
    for (z = 0; z < 256; z = z + 1) begin m2_hist_mis[z] = 0; m2_hist_ct[z] = 0; end
  end

  wire w2_ct_ok   = dut.Core_cpu.iu_btb_update_vld;      // 已含 have_inst_EX/~stall/~redirect
  wire w2_ct_cond = w2_ct_ok & dut.Core_cpu.iu_btb_is_cond;
  wire w2_ct_jmp  = w2_ct_ok & (dut.Core_cpu.iu_btb_is_jal | dut.Core_cpu.iu_btb_is_jalr);
  wire w2_ct_mis  = w2_ct_ok & dut.Core_cpu.mispredict;
  // ⚠️ 位号**跟着 RTL 的参数走**, 别再写死数字。
  // 这段探针已经静默失效过一次: GHR_W 从 12 改到 8 之后 CHK_BTBHIT/CHK_PREDTK
  // 从 17/18 挪到了 13/14, 而这里还读 17/18 —— 那两个位在空白区里恒 0, 于是
  // "方向错 vs BTB 没这条"的归因整个废掉 (每一条都算成 BTB 没这条)。
  // 直接层次化引用 rv32ifu2_top 的 localparam, 以后调参数不会再漂。
  wire w2_ct_hit  = dut.Core_cpu.iu_btb_chk[dut.Core_cpu.u_ifu_subsys.CHK_BTBHIT];
  wire w2_ct_tk   = dut.Core_cpu.iu_btb_chk[dut.Core_cpu.u_ifu_subsys.CHK_PREDTK];

  always @(posedge clk) if (!rst) begin
    if (w2_ct_cond) begin
      m2_cond <= m2_cond + 1;
      m2_hist_ct[dut.Core_cpu.iu_btb_cur_pc[9:2]] <= m2_hist_ct[dut.Core_cpu.iu_btb_cur_pc[9:2]] + 1;
      if (w2_ct_mis) begin
        m2_cond_mis <= m2_cond_mis + 1;
        m2_hist_mis[dut.Core_cpu.iu_btb_cur_pc[9:2]] <= m2_hist_mis[dut.Core_cpu.iu_btb_cur_pc[9:2]] + 1;
        if (!w2_ct_hit) m2_cond_nobtb <= m2_cond_nobtb + 1;
        else            m2_cond_dir   <= m2_cond_dir   + 1;
        if ( w2_ct_tk) m2_pt_nt <= m2_pt_nt + 1;   // 猜跳, 实际没跳
        else           m2_pn_t  <= m2_pn_t  + 1;   // 猜不跳, 实际跳了
      end
    end
    if (w2_ct_jmp) begin
      m2_jmp <= m2_jmp + 1;
      m2_hist_ct[dut.Core_cpu.iu_btb_cur_pc[9:2]] <= m2_hist_ct[dut.Core_cpu.iu_btb_cur_pc[9:2]] + 1;
      if (w2_ct_mis) begin
        m2_jmp_mis <= m2_jmp_mis + 1;
        m2_hist_mis[dut.Core_cpu.iu_btb_cur_pc[9:2]] <= m2_hist_mis[dut.Core_cpu.iu_btb_cur_pc[9:2]] + 1;
        if (!w2_ct_hit) m2_jmp_nobtb <= m2_jmp_nobtb + 1;
        else            m2_jmp_tgt   <= m2_jmp_tgt   + 1;
      end
    end
  end

`endif

`ifdef BTPROBE
  // ---------------------------------------------------------------------------
  // BTB 的"一行 4 slot"几何到底用掉多少?
  //
  // 要回答的是: 块索引 (一行 = 一个 16 B 块 + 一个共享标签) 配上 4 个 (offset,target)
  // slot, 在实际负载上是不是浪费面积 —— 如果占用行里平均只有 ~1 个 slot 有效,
  // 那 64/71 的位宽就基本白花, 换成更紧凑的编码同等面积能装下多得多的分支。
  //
  // 两个口径:
  //  静态 占用扫描 ($finish 时): 扫描整个阵列, 统计"占用行"的行数, 以及每行
  //        有效 slot 数的直方图。这是阵列的**稳定占用**。
  //  动态 取指块分支密度: 每来一个新的取指地址, 数一次 slot_vld 的 popcount。
  //        这是取指流的**分支密度**(含没命中的块 —— 那份是容量 miss 不是浪费)。
  // ---------------------------------------------------------------------------
  integer btp_occ   = 0;
  integer btp_slots = 0;
  integer btp_hist  [0:4];      // 占用行: 几个 slot 有效
  integer btp_dyn   [0:4];      // 取指地址: 几个 slot 命中
  integer btp_lk    = 0;
  integer btp_dynsum = 0;
  // ⚠️ slot i **就是**块内第 i 个字 (训练侧 `u_slot = upd_pc[3:2]`, 使用侧
  //    `sl_vld[pc_ofs]`)。所以"slot 数"和"块内位置"是绑死的 —— 想知道砍到
  //    2 个 slot 会丢什么, 必须知道**分支落在哪个位置**, 只看"几个分支"会得出
  //    完全错误的乐观结论。
  integer btp_pos   [0:3];      // 静态: 占用行里落在位置 i 的有效 slot 数
  integer btp_mask  [0:15];     // 静态: 4 位有效掩码的直方图
  integer btp_dpos  [0:3];      // 动态: 取指地址在位置 i 命中多少次
  // 交付侧: MAX_ISSUE=3 而一块 4 条 ⇒ 无分支的直线块会被拆成 3+1 两次查表。
  // `next_pc = q_pc + 4*ib_push_acc` (rv32ifu2_top.v), 所以"同一 16 B 块被连着
  // 取两次"就是拆分事件。这是乱序 3 发射下会**直接顶到吞吐**的那个数。
  integer btp_push  [0:4];      // ib_push_acc 直方图 (MAX_ISSUE=4 ⇒ 0..4)
  integer btp_ev    = 0;        // 取指事件数 (= 取指地址变化次数)
  integer btp_pushsum = 0;      // 推进 IBUF 的指令总数
  integer btp_split = 0;        // 同块被连续取两次的次数

  initial begin
    integer z;
    for (z = 0; z <= 4; z = z + 1) begin btp_hist[z] = 0; btp_dyn[z] = 0; end
    for (z = 0; z <= 3; z = z + 1) begin btp_pos[z] = 0; btp_dpos[z] = 0; end
    for (z = 0; z <= 4; z = z + 1) btp_push[z] = 0;
    for (z = 0; z <= 15; z = z + 1) btp_mask[z] = 0;
  end

  wire [31:0] btp_pc = dut.Core_cpu.u_ifu_subsys.next_pc;
  reg  [31:0] btp_pc_q = 32'hFFFF_FFFF;

  always @(posedge clk) if (!rst) begin
    btp_pc_q <= btp_pc;
    if (btp_pc != btp_pc_q) begin     // 只在"换了一个取指地址"时数, 避免停顿重复计数
      integer n;
      // 同一 16 B 块被连着取两次 (MAX_ISSUE=3 < 4 条/块 的直接后果)
      if (btp_pc[31:4] == btp_pc_q[31:4]) btp_split <= btp_split + 1;
      btp_ev <= btp_ev + 1;
      n = 0;
      if (dut.Core_cpu.u_ifu_subsys.btb_vld[0]) n = n + 1;
      if (dut.Core_cpu.u_ifu_subsys.btb_vld[1]) n = n + 1;
      if (dut.Core_cpu.u_ifu_subsys.btb_vld[2]) n = n + 1;
      if (dut.Core_cpu.u_ifu_subsys.btb_vld[3]) n = n + 1;
      btp_dyn[n] <= btp_dyn[n] + 1;
      btp_lk     <= btp_lk + 1;
      btp_dynsum <= btp_dynsum + n;
      if (dut.Core_cpu.u_ifu_subsys.btb_vld[0]) btp_dpos[0] <= btp_dpos[0] + 1;
      if (dut.Core_cpu.u_ifu_subsys.btb_vld[1]) btp_dpos[1] <= btp_dpos[1] + 1;
      if (dut.Core_cpu.u_ifu_subsys.btb_vld[2]) btp_dpos[2] <= btp_dpos[2] + 1;
      if (dut.Core_cpu.u_ifu_subsys.btb_vld[3]) btp_dpos[3] <= btp_dpos[3] + 1;
    end
    // 每拍记一次实际收下的条数 (含 0 = 没推)
    btp_push[dut.Core_cpu.u_ifu_subsys.ib_push_acc] <=
        btp_push[dut.Core_cpu.u_ifu_subsys.ib_push_acc] + 1;
    btp_pushsum <= btp_pushsum + dut.Core_cpu.u_ifu_subsys.ib_push_acc;
  end

  final begin : btp_report
    integer r, s, n, mk;
    integer nr;
    nr = dut.Core_cpu.u_ifu_subsys.u_btb.NR_ROWS;
    btp_occ = 0; btp_slots = 0;
    for (r = 0; r < nr; r = r + 1) begin
      // 行有效位 = tag_q 的最高位 (rv32ifu2_btb.v 的 {行有效, tag})
      if (dut.Core_cpu.u_ifu_subsys.u_btb.tag_q[r][dut.Core_cpu.u_ifu_subsys.u_btb.TAG_BITS]) begin
        n = 0; mk = 0;
        for (s = 0; s < 4; s = s + 1)
          if (dut.Core_cpu.u_ifu_subsys.u_btb.dat_q[r][s*16 + dut.Core_cpu.u_ifu_subsys.u_btb.SL_VLD]) begin
            n = n + 1;
            mk = mk | (1 << s);
            btp_pos[s] = btp_pos[s] + 1;
          end
        btp_occ   = btp_occ + 1;
        btp_slots = btp_slots + n;
        btp_hist[n] = btp_hist[n] + 1;
        btp_mask[mk] = btp_mask[mk] + 1;
      end
    end
    $display("-------- BTB 4-slot 几何占用 (BTPROBE) --------");
    $display("  阵列行数        = %0d (物理)", nr);
    $display("  占用行          = %0d (%.1f%% of 阵列)", btp_occ,
             (nr > 0) ? 100.0*btp_occ/nr : 0.0);
    $display("  占用行内有效slot = %0d (平均 %.3f 个/行)", btp_slots,
             (btp_occ > 0) ? 1.0*btp_slots/btp_occ : 0.0);
    for (r = 0; r <= 4; r = r + 1)
      if (btp_hist[r] > 0)
        $display("    占用行里 %0d 个 slot 有效 : %0d 行 (%.1f%%)", r, btp_hist[r],
                 (btp_occ > 0) ? 100.0*btp_hist[r]/btp_occ : 0.0);
    $display("  取指地址数      = %0d, 命中 slot 合计 = %0d (平均 %.3f 个/地址)", btp_lk,
             btp_dynsum, (btp_lk > 0) ? 1.0*btp_dynsum/btp_lk : 0.0);
    for (r = 0; r <= 4; r = r + 1)
      if (btp_dyn[r] > 0)
        $display("    取指地址命中 %0d 个 slot : %0d (%.1f%%)", r, btp_dyn[r],
                 (btp_lk > 0) ? 100.0*btp_dyn[r]/btp_lk : 0.0);

    // ---- 位置分布: 决定"能不能砍 slot" 的那个数 ----
    $display("  --- 块内位置分布 (slot i 就是块内第 i 个字) ---");
    for (r = 0; r <= 3; r = r + 1)
      $display("    位置 %0d : 静态占用 %0d 行 (%.1f%%), 动态命中 %0d 次 (%.1f%%)",
               r, btp_pos[r], (btp_occ > 0) ? 100.0*btp_pos[r]/btp_occ : 0.0,
               btp_dpos[r], (btp_lk > 0) ? 100.0*btp_dpos[r]/btp_lk : 0.0);
    $display("  --- 交付侧: 一块 4 条 vs MAX_ISSUE=3 ---");
    $display("    取指事件(地址变化) = %0d, 推出指令 = %0d, 平均 %.3f 条/事件",
             btp_ev, btp_pushsum, (btp_ev > 0) ? 1.0*btp_pushsum/btp_ev : 0.0);
    $display("    **同块被连续取两次** = %0d (%.1f%% 的取指事件)", btp_split,
             (btp_ev > 0) ? 100.0*btp_split/btp_ev : 0.0);
    for (r = 0; r <= 4; r = r + 1)
      $display("    ib_push_acc=%0d : %0d 拍 (%.1f%%)", r, btp_push[r],
               (cycles > 0) ? 100.0*btp_push[r]/cycles : 0.0);
    $display("  有效掩码直方图 (bit i = 位置 i 有分支):");
    for (r = 0; r <= 15; r = r + 1)
      if (btp_mask[r] > 0)
        $display("    %4b : %0d 行 (%.1f%%)", r, btp_mask[r],
                 (btp_occ > 0) ? 100.0*btp_mask[r]/btp_occ : 0.0);
  end
`endif
  wire w2_c_flush = dut.Core_cpu.flush_if_id | dut.Core_cpu.ifu_idu_flush;
  wire w2_c_stall = dut.Core_cpu.stall;
  wire w2_miss    = ~dut.Core_cpu.u_ifu_subsys.q_hit;
  wire w2_qempty  = dut.Core_cpu.u_ifu_subsys.ib_cnt == 4'd0;
  wire w2_redir   = dut.Core_cpu.u_ifu_subsys.redirect;
  wire w2_flush   = dut.Core_cpu.rtu_ifu_flush | dut.Core_cpu.rtu_ifu_chgflw_vld;

  always @(posedge clk) if (!rst) begin
    if (dut.Core_cpu.if_accept)                       b2_accept  <= b2_accept  + 1;
    else if (!dut.Core_cpu.ifu_init_done)             b2_init    <= b2_init    + 1;
    else if (w2_c_flush)                              b2_flush   <= b2_flush   + 1;
    else if (w2_c_stall)                              b2_stall   <= b2_stall   + 1;
    else begin
      b2_nofetch <= b2_nofetch + 1;
      if      (w2_miss)   b2_nf_miss   <= b2_nf_miss   + 1;
      else if (w2_qempty) b2_nf_qempty <= b2_nf_qempty + 1;
      else                b2_nf_other  <= b2_nf_other  + 1;
    end
    // 原始 (不互斥)
    if (w2_c_stall)                b2_raw_stall  <= b2_raw_stall  + 1;
    // 重构后"核内停顿"有三个来源, 分开记: 除法占住 EX / 乘法冒险停 ID /
    // load-use (三者本来就互斥)
    if (dut.Core_cpu.div_stall)    b2_raw_div    <= b2_raw_div    + 1;
    if (dut.Core_cpu.mul_stall)    b2_raw_mul    <= b2_raw_mul    + 1;
    if (w2_c_stall & ~dut.Core_cpu.div_stall & ~dut.Core_cpu.mul_stall)
                                   b2_raw_loaduse<= b2_raw_loaduse+ 1;
    if (dut.Core_cpu.mispredict)   b2_misp       <= b2_misp       + 1;
    if (dut.Core_cpu.redirect)     b2_trap       <= b2_trap       + 1;
    // 重定向/冲刷之后, 前端重新出指令要几拍
    if (w2_redir) begin
      b2_rf_armed <= 1'b1;
      b2_rf_isflush <= w2_flush;
      b2_ev_redir <= b2_ev_redir + 1;
      if (w2_flush) b2_ev_flush <= b2_ev_flush + 1;
    end else if (b2_rf_armed) begin
      if (dut.Core_cpu.if_accept) b2_rf_armed <= 1'b0;
      else if (b2_rf_isflush)     b2_rf_flush <= b2_rf_flush + 1;
      else                        b2_rf_redir <= b2_rf_redir + 1;
    end
  end

  always @(posedge clk) if (!rst) begin
    if (dut.Core_cpu.retire_now) n2_retire <= n2_retire + 1;
    if (dut.Core_cpu.if_bubble)  n2_bubble <= n2_bubble + 1;
    if (!dut.Core_cpu.ifu_init_done) n2_init <= n2_init + 1;
    if (dut.Core_cpu.ifu_biu_rd_req & dut.Core_cpu.ifu_biu_rd_grnt)
      n2_biu_txn <= n2_biu_txn + 1;

    if (n2_is_cond) begin
      n2_cond <= n2_cond + 1;
      bc2_cond[bench_class2(dut.Core_cpu.pc_EX)] <= bc2_cond[bench_class2(dut.Core_cpu.pc_EX)] + 1;
      if (n2_misp) begin
        n2_mis_cond <= n2_mis_cond + 1;
        bc2_mis[bench_class2(dut.Core_cpu.pc_EX)] <= bc2_mis[bench_class2(dut.Core_cpu.pc_EX)] + 1;
      end
    end
    if (n2_is_jmp) begin
      n2_jmp <= n2_jmp + 1;
      bc2_jmp[bench_class2(dut.Core_cpu.pc_EX)] <= bc2_jmp[bench_class2(dut.Core_cpu.pc_EX)] + 1;
      if (n2_misp) begin
        n2_mis_jmp <= n2_mis_jmp + 1;
        bc2_misj[bench_class2(dut.Core_cpu.pc_EX)] <= bc2_misj[bench_class2(dut.Core_cpu.pc_EX)] + 1;
      end
    end
  end

  task report_ifu2_stats();
    $display("-------- IFU2 (2-stage front-end) --------");
    $display("  cycles          = %0d", cycles);
    $display("  retired inst    = %0d", n2_retire);
    // 先除后乘: retire 超过 210 万时 retire*1000 会撑爆 32 位有符号并打印成负数
      $display("  IPC (x1000)     = %0d", (cycles == 0) ? 0 : (n2_retire / (cycles/1000 + 1)));
    $display("  fetch bubble    = %0d", n2_bubble);
    $display("  IFU init cycles = %0d", n2_init);
    $display("  BIU read txn    = %0d", n2_biu_txn);
    if ($test$plusargs("BENCH")) begin
      integer c, tot_c, tot_m;
      tot_c = 0; tot_m = 0;
      $display("  --- 逐类方向准确率 (口径同 USE_IFU 的 report_bench_stats) ---");
      for (c = 1; c <= 5; c = c + 1) begin
        tot_c = tot_c + bc2_cond[c];
        tot_m = tot_m + bc2_mis[c];
        if (bc2_cond[c] > 0)
          $display("    cls%0d cond=%0d mis=%0d acc=%0d.%02d%%",
                   c, bc2_cond[c], bc2_mis[c], ((bc2_cond[c]-bc2_mis[c])*100)/bc2_cond[c],
                   (((bc2_cond[c]-bc2_mis[c])*10000)/bc2_cond[c]) % 100);
      end
      if (tot_c > 0)
        $display("    total cond=%0d mis=%0d acc=%0d.%02d%%",
                 tot_c, tot_m, ((tot_c-tot_m)*100)/tot_c, (((tot_c-tot_m)*10000)/tot_c)%100);
      $display("    jal/jalr=%0d mis=%0d", n2_jmp, n2_mis_jmp);
      $display("    mispred=%0d ctrl_total=%0d", n2_mis_cond+n2_mis_jmp, n2_cond+n2_jmp);
`ifdef M2PROBE
      $display("  ================ 分支预测归因 ================");
      $display("  条件分支 : %0d 条, 误预测 %0d -> 准确率 %0d.%02d%%",
               m2_cond, m2_cond_mis, (m2_cond>0)?((m2_cond-m2_cond_mis)*100/m2_cond):0,
               (m2_cond>0)?(((m2_cond-m2_cond_mis)*10000/m2_cond)%100):0);
      $display("    其中 BTB 没这条分支 : %0d (%0.1f%% 的条件误预测)",
               m2_cond_nobtb, (m2_cond_mis>0)?100.0*m2_cond_nobtb/m2_cond_mis:0.0);
      $display("    其中 BTB 有、方向猜错 : %0d (%0.1f%%)",
               m2_cond_dir, (m2_cond_mis>0)?100.0*m2_cond_dir/m2_cond_mis:0.0);
      $display("      过预测(猜跳没跳) %0d / 漏预测(猜不跳跳了) %0d", m2_pt_nt, m2_pn_t);
      $display("  JAL/JALR : %0d 条, 误预测 %0d -> 准确率 %0d.%02d%%",
               m2_jmp, m2_jmp_mis, (m2_jmp>0)?((m2_jmp-m2_jmp_mis)*100/m2_jmp):0,
               (m2_jmp>0)?(((m2_jmp-m2_jmp_mis)*10000/m2_jmp)%100):0);
      $display("    其中 BTB 没这条 : %0d ; BTB 有、目标错 : %0d", m2_jmp_nobtb, m2_jmp_tgt);
      begin
        integer k, b1, b2, b3, b4, b5, b6, b7, b8;
        integer i1,i2,i3,i4,i5,i6,i7,i8, t;
        b1=0;b2=0;b3=0;b4=0;b5=0;b6=0;b7=0;b8=0;
        i1=0;i2=0;i3=0;i4=0;i5=0;i6=0;i7=0;i8=0;
        for (k = 0; k < 256; k = k + 1) begin
          t = m2_hist_mis[k];
          if (t > b1) begin b8=b7;i8=i7; b7=b6;i7=i6; b6=b5;i6=i5; b5=b4;i5=i4;
                            b4=b3;i4=i3; b3=b2;i3=i2; b2=b1;i2=i1; b1=t;i1=k; end
          else if (t > b2) begin b8=b7;i8=i7; b7=b6;i7=i6; b6=b5;i6=i5; b5=b4;i5=i4;
                               b4=b3;i4=i3; b3=b2;i3=i2; b2=t;i2=k; end
          else if (t > b3) begin b8=b7;i8=i7; b7=b6;i7=i6; b6=b5;i6=i5; b5=b4;i5=i4;
                               b4=b3;i4=i3; b3=t;i3=k; end
          else if (t > b4) begin b8=b7;i8=i7; b7=b6;i7=i6; b6=b5;i6=i5; b5=b4;i5=i4;
                               b4=t;i4=k; end
          else if (t > b5) begin b8=b7;i8=i7; b7=b6;i7=i6; b6=b5;i6=i5; b5=t;i5=k; end
          else if (t > b6) begin b8=b7;i8=i7; b7=b6;i7=i6; b6=t;i6=k; end
          else if (t > b7) begin b8=b7;i8=i7; b7=t;i7=k; end
          else if (t > b8) begin b8=t;i8=k; end
        end
        $display("  误预测最多的 8 个 16B 区间 (PC 基址 / 误预测 / 该区间控制转移数 / 准确率):");
        $display("     0x%04x  %6d / %6d  %s", i1*4, b1, m2_hist_ct[i1],
                 (m2_hist_ct[i1]>0)?"":"" );
        $display("     0x%04x  %6d / %6d", i2*4, b2, m2_hist_ct[i2]);
        $display("     0x%04x  %6d / %6d", i3*4, b3, m2_hist_ct[i3]);
        $display("     0x%04x  %6d / %6d", i4*4, b4, m2_hist_ct[i4]);
        $display("     0x%04x  %6d / %6d", i5*4, b5, m2_hist_ct[i5]);
        $display("     0x%04x  %6d / %6d", i6*4, b6, m2_hist_ct[i6]);
        $display("     0x%04x  %6d / %6d", i7*4, b7, m2_hist_ct[i7]);
        $display("     0x%04x  %6d / %6d", i8*4, b8, m2_hist_ct[i8]);
      end
`endif
      $display("  ================ 取指气泡拆解 (口径同 USE_IFU) ================");
      $display("  总拍数                      : %0d", cycles);
      $display("  核接受指令 (if_accept=1)    : %0d (%0.2f%%)", b2_accept, 100.0*b2_accept/cycles);
      $display("  不给指令 (if_accept=0)      : %0d (%0.2f%%)",
               cycles-b2_accept, 100.0*(cycles-b2_accept)/cycles);
      $display("    1. IFU 初始化未完成       : %0d", b2_init);
      $display("    2. 冲刷 (mispredict/陷阱) : %0d", b2_flush);
      $display("    3. 核内停顿               : %0d", b2_stall);
      $display("    4. 核在等, IFU 没货       : %0d (%0.2f%%)",
               b2_nofetch, 100.0*b2_nofetch/cycles);
      $display("       4a. cache 没有这一行   : %0d", b2_nf_miss);
      $display("       4b. 有行但队列空       : %0d", b2_nf_qempty);
      $display("       4c. 其它               : %0d", b2_nf_other);
      $display("  核内停顿原始(div/mul/load-use): %0d / %0d / %0d",
               b2_raw_div, b2_raw_mul, b2_raw_loaduse);
      $display("  误预测 %0d / 陷阱 %0d", b2_misp, b2_trap);
      $display("  冲刷后重填等待: 误预测路 %0d 拍 (%0d 次, 平均 %0d.%02d 拍), 陷阱路 %0d 拍",
               b2_rf_redir, b2_ev_redir,
               (b2_ev_redir>0)?b2_rf_redir/b2_ev_redir:0, (b2_ev_redir>0)?(b2_rf_redir*100/b2_ev_redir)%100:0,
               b2_rf_flush);
      $display("  ==============================================================");
      // 方向表的"有多少行真的被写过" —— 用来判断表是不是大得没用/小得不够。
      // gshare 数计数器行; TAGE 数行有效位为 1 的行 (清干净的行是全 0)。
      // ⚠️ BP_PRED=1 时没有 u_bht 这个实例, 不分支的话整个 tb 编不过。
`ifdef BP_PRED
      begin
        integer r, nz, tot;
        nz = 0;
        tot = $size(dut.Core_cpu.u_ifu_subsys.g_tage.u_tage.tag_q);
        for (r = 0; r < tot; r = r + 1)
          if (dut.Core_cpu.u_ifu_subsys.g_tage.u_tage.tag_q[r] !== 0) nz = nz + 1;
        $display("    TAGE rows valid = %0d / %0d", nz, tot);
      end
`else
      begin
        integer r, nz, tot;
        nz = 0; tot = 0;
        for (r = 0; r < 512; r = r + 1) begin
          if (dut.Core_cpu.u_ifu_subsys.g_gshare.u_bht.ctr_q[r] !== 8'h00) nz = nz + 1;
          tot = tot + 1;
        end
        $display("    BHT rows nonzero = %0d / %0d", nz, tot);
      end
`endif
    end
  endtask
`endif

  always @(posedge clk) begin
    cycles <= cycles + 1;
    gm_set_cycle(cycles + 1);
    gm_set_timer(mtime_d1[31:0], mtime_d1[63:32]);
    gm_set_irq(dut_timer_irq);
    if (!rst) begin
      int ret;
      ret = gm_check_step(dut.debug_wb_have_inst,
                          dut.debug_wb_pc,
                          dut.debug_wb_ena,
                          dut.debug_wb_reg,
                          dut.debug_wb_value,
                          dut.Core_cpu.wb_irq_safe);
      // CSR 比较: 只在【没有重定向】的提交沿做.
      // 陷阱/中断/mret 自己的 mepc/mcause/mstatus 写入发生在这一拍时钟边沿,
      // 而 golden model 是在 gm_check_step() 里应用的 —— 重定向当拍比较必然
      // 拿到"DUT 边沿前 vs 参考边沿后". 普通 csrr* 在 EX 级就写了(比提交早
      // ≥2 拍), 所以下一个提交沿比较时两边都已是新值, 覆盖不受影响.
      // 只在 CSR 文件"静止"时比较: 在途的 CSR 写会让 DUT(EX 级写)与
      // golden model(提交当拍写)在窗口内读到不同状态, 那不是真错.
      if (ret >= 0 && !gm_halted() && dut.Core_cpu.csr_quiescent) begin
        int csr_ret;
        csr_ret = gm_check_csr(dut_csr_mstatus(), dut_csr_mie(), dut_csr_mtvec(),
                               dut.Core_cpu.U_CSR.mscratch, dut.Core_cpu.U_CSR.mepc,
                               dut.Core_cpu.U_CSR.mcause, dut.Core_cpu.U_CSR.mtval,
                               dut_csr_mip());
        if (csr_ret < 0) begin
          $display("[difftest] CSR mismatch at cycle %0d", cycles);
          $fatal(1, "Difftest CSR failed - simulation stopped");
        end
      end
      if (ret < 0) begin
        $display("[difftest] ERROR: Mismatch detected at cycle %0d", cycles);
        $display("  DUT: PC=0x%08x, ena=%0d, reg=%0d, value=0x%08x",
                 dut.debug_wb_pc, dut.debug_wb_ena, dut.debug_wb_reg, dut.debug_wb_value);
        $fatal(1, "Difftest failed - simulation stopped");
      end
      // Test program finished: report pass/fail from a0 and end cleanly.
      else if (gm_halted()) begin
        $display("[difftest] Test finished at cycle %0d", cycles);
        // +NOVALID: 调试模式。CoreMark 退出码非 0 通常是"跑分不合法"(≥10 秒规则,
        //   ITERATIONS 少时必然触发), 而逐拍 difftest 已全程通过 ⇒ 功能无误。
        //   该开关只跳过有效性判定, 统计量照常打印; 真正的功能错误会在上面的
        //   difftest 分支就被 $fatal 拦住, 不会走到这里。
        if (gm_exit_code() == 0 || $test$plusargs("NOVALID")) begin
          if (gm_exit_code() == 0) $display("Test Point Pass!");
          else $display("Test Point Pass (NOVALID: 退出码 %0d — 跳过 CoreMark 有效性判定, 仅调试用)",
                        gm_exit_code());
`ifdef USE_IFU
          report_branch_stats();
          report_l0_stats();
          report_bubble_stats();
          if (bench_en) report_bench_stats();
    if (bench_en) report_coremark_selfdist();
          if (bench_en) report_coremark_selfdist();
`endif
`ifdef USE_IFU2
          report_ifu2_stats();
`endif
          $finish;
        end else begin
          $display("Test Point Failed");
`ifdef USE_IFU
          // 跑分不合法 (如 ITERATIONS=1 触发 CoreMark 的 10 秒下限) 时也要出数:
          // 那只是有效性规则, 统计量本身仍然有效.
          report_branch_stats();
          report_l0_stats();
          report_bubble_stats();
          if (bench_en) report_bench_stats();
    if (bench_en) report_coremark_selfdist();
          if (bench_en) report_coremark_selfdist();
`endif
`ifdef USE_IFU2
          report_ifu2_stats();
`endif
          $fatal(1, "Test Point Failed");
        end
      end
    end
  end

  // Timeout based on cycle count to mimic Verilator harness semantics
  //
  // 必须用 $fatal 而不是 $finish: $finish 的退出码是 0, run-all 按 make 退出码
  // 判定, 于是"跑飞/卡死到超时"会被计成 PASS. 这对 difftest 尤其危险 ——
  // 一旦节拍失步, 典型表现就是卡住直到超时, 正好伪装成通过.
  initial begin
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 1000000;
    wait (cycles >= max_cycles);
    $display("Timed out! Please check whether your CPU got stuck.");
`ifdef USE_IFU
    report_branch_stats();
    report_l0_stats();
    report_bubble_stats();
    if (bench_en) report_bench_stats();
    if (bench_en) report_coremark_selfdist();
`endif
`ifdef USE_IFU2
    report_ifu2_stats();
`endif
    $fatal(1, "Timed out - simulation exceeded MAX_CYCLES");
  end

  // ---------------------------------------------------------------------------
  // Cycle-by-cycle pipeline probe for DUT debugging. Enable with +TRACE.
  // Sampled on the negedge so the values shown are the settled post-edge state
  // of the cycle whose number is printed.
  // ---------------------------------------------------------------------------
  logic trace_en = 0;
  initial if ($test$plusargs("TRACE")) trace_en = 1;

  always @(negedge clk) if (trace_en && !rst) begin
    $display("[T%04d] PC  IF=%08x ID=%08x EX=%08x MEM=%08x WB=%08x",
             cycles, dut.Core_cpu.if_pc, dut.Core_cpu.id_pc, dut.Core_cpu.pc_EX,
             dut.Core_cpu.pc_MEM, dut.Core_cpu.pc_WB);
`ifdef USE_IFU
    $display("        IFU vld0=%b data0=%h init=%b idu_flush=%b accept=%b bubble=%b",
             dut.Core_cpu.ifu_inst0_vld, dut.Core_cpu.ifu_inst0_data,
             dut.Core_cpu.ifu_init_done, dut.Core_cpu.ifu_idu_flush,
             dut.Core_cpu.if_accept, dut.Core_cpu.if_bubble);
    $display("        MIS ifpn=%08x idpn=%08x expn=%08x actual=%08x mispredict=%b br_taken=%b is_jump=%b is_jalr=%b misaligned=%b",
             dut.Core_cpu.if_pred_npc, dut.Core_cpu.id_pred_npc, dut.Core_cpu.ex_pred_npc,
             dut.Core_cpu.actual_npc, dut.Core_cpu.mispredict,
             dut.Core_cpu.ex_br_taken, dut.Core_cpu.ex_is_jump, dut.Core_cpu.ex_is_jalr,
             dut.Core_cpu.ex_inst_misaligned);
`endif
    $display("        INST ID=%08x | have_inst ID/EX/MEM/WB=%b%b%b%b",
             dut.Core_cpu.id_inst, dut.Core_cpu.have_inst_ID, dut.Core_cpu.have_inst_EX,
             dut.Core_cpu.have_inst_MEM, dut.Core_cpu.have_inst_WB);
    $display("        CTRL stall=%b div_stall=%b mul_stall=%b flush_if=%b flush_ex=%b branched=%b",
             dut.Core_cpu.stall, dut.Core_cpu.div_stall, dut.Core_cpu.mul_stall,
             dut.Core_cpu.flush_if_id, dut.Core_cpu.flush_id_ex, dut.Core_cpu.branched);
    $display("        MULDIV ex_is_muldiv=%b(mul=%b div=%b) req_vld=%b resp_vld=%b(is_div=%b) rsp=%08x | m1_vld=%b m2_vld=%b r_vld=%b",
             dut.Core_cpu.ex_is_muldiv, dut.Core_cpu.ex_is_mul, dut.Core_cpu.ex_is_div,
             dut.Core_cpu.U_MUL_DIV.req_valid, dut.Core_cpu.md_resp_vld,
             dut.Core_cpu.md_resp_is_div, dut.Core_cpu.md_resp_data,
             dut.Core_cpu.U_MUL_DIV.U_MUL_PIPE.req_vld,
             dut.Core_cpu.U_MUL_DIV.U_MUL_PIPE.vld_m2,
             dut.Core_cpu.U_MUL_DIV.U_MUL_PIPE.resp_vld_r);
    $display("        TRAP redirect=%b exc=%b(%0d) irq=%b mret=%b | IDexc=%b(%0d) tval=%08x | EXloc=%b(%0d) tgt=%08x bad=%b is_load=%b is_st=%b",
             dut.Core_cpu.redirect, dut.Core_cpu.wb_exc_valid, dut.Core_cpu.wb_exc_cause,
             dut.Core_cpu.irq_taken, dut.Core_cpu.wb_is_mret,
             dut.Core_cpu.id_exc_valid, dut.Core_cpu.id_exc_cause, dut.Core_cpu.id_exc_tval,
             dut.Core_cpu.ex_local_exc_valid, dut.Core_cpu.ex_local_exc_cause,
             dut.Core_cpu.ex_target, dut.Core_cpu.ex_addr_bad,
             dut.Core_cpu.ex_is_load, dut.Core_cpu.ex_is_store);
    $display("        CSR ex_we=%b op=%0d addr=%03x imm=%b wdata=%08x rdata=%08x redirect=%b mtvec=%08x",
             dut.Core_cpu.ex_csr_we, dut.Core_cpu.ex_csr_op, dut.Core_cpu.ex_csr_addr,
             dut.Core_cpu.ex_csr_imm, dut.Core_cpu.ex_csr_wdata, dut.Core_cpu.csr_rdata,
             dut.Core_cpu.redirect, dut.Core_cpu.U_CSR.mtvec);
    $display("        CSR2 mepc=%08x mcause=%08x mtval=%08x mstatus=%08x",
             dut.Core_cpu.U_CSR.mepc, dut.Core_cpu.U_CSR.mcause,
             dut.Core_cpu.U_CSR.mtval, dut_csr_mstatus());
    $display("        EX  we=%b wR=%02d wD=%08x alu_c_final=%08x",
             dut.Core_cpu.ex_rf_we, dut.Core_cpu.ex_wR, dut.Core_cpu.ex_wD,
             dut.Core_cpu.ex_alu_c_final);
    $display("        MEM we=%b wR=%02d wD=%08x | WB we=%b wR=%02d wD=%08x",
             dut.Core_cpu.mem_rf_we, dut.Core_cpu.mem_wR, dut.Core_cpu.mem_wD,
             dut.Core_cpu.wb_rf_we, dut.Core_cpu.wb_wR, dut.Core_cpu.wb_wD);
  end
`ifdef USE_IFU
  // ---------------------------------------------------------------------------
  // 分支预测统计 (纯观测, 不影响 DUT 行为)
  //
  // 分子分母共用 mycpu.v 上报 IFU 的同一套门控 have_inst_EX & ~stall & ~redirect:
  //   - 被误预测冲掉的年轻指令从不在 EX 解析, 所以不会重复计数;
  //   - EX 因 load-use/muldiv 停顿时 pc_EX 保持, 不加 ~stall 会把同一条分支数成多拍;
  //   - 与 redirect 同拍的分支已被冲刷, 单独计数.
  // 解析口径 = "控制转移指令在 EX 真正结算掉的那一拍", 与 BHT 训练上报同源.
  // ---------------------------------------------------------------------------
  integer n_cond_strong = 0; // 条件分支: BHT 强 taken (counter=2'b11, 预测位+低位都对)
  integer n_cond_weak   = 0; // 条件分支: BHT 弱 taken (counter=2'b10)
  integer n_retire     = 0;  // 退休指令数 (排除被中断 squash 的)
  integer n_cond       = 0;  // 条件分支 (iu_bht_check_vld 同门控)
  integer n_jmp        = 0;  // jal / jalr
  integer n_mispred    = 0;  // 误预测总数 (控制转移)
  integer n_mis_cond   = 0;  // 条件分支误预测
  integer n_mis_jmp    = 0;  // jal/jalr 误预测
  integer n_cond_tpred = 0;  // 条件分支: BHT 预测 taken
  integer n_cond_taken = 0;  // 条件分支: 实际 taken
  integer n_pt_nt      = 0;  // 预测 taken 实际不跳 (BHT 过预测)
  integer n_pn_t       = 0;  // 预测 not-taken 实际跳 (BHT 漏预测)
  integer n_trap       = 0;  // 陷阱/中断/mret 重定向
  integer n_fill       = 0;  // IFU BIU 读事务 (i-cache 行填充)
  integer n_bubble     = 0;  // IFU 交不出指令的拍数 (取指气泡)
  integer n_init       = 0;  // IFU 初始化完成前的拍数
  integer n_misp_raw   = 0;  // 不做 ~stall/~redirect 门控的误预测拍数 (自检用)

  // ---------------------------------------------------------------------------
  // [2026-09-25 前端微架构矩阵] ICache / 前端交接点观测 (纯观测, 不改 DUT 行为)
  //
  // icache 的 access/miss 计数在 RTL 里本来就有 (rv32_ifu_icache_if.v:344-376),
  // 但被 hpcp_ifu_cnt_en 门控, 而 SoC 把它恒接 0 (ifu_subsys.v), 所以顶层
  // ifu_hpcp_icache_* 永远是 0。这里直接用 RTL 自己的事件源 (同一根线),
  // 绕开那道门控; 另外用 cp0_ifu_icache_en 门控, 保证 ICACHE=0 时不虚计。
  //   access 事件 = 该文件 event_source[0] = seq_data_req | chgflw
  //   miss   事件 = 该文件 event_source[1] = ifu_hpcp_icache_miss_pre (IP 级判 miss)
  // ---------------------------------------------------------------------------
  wire ic_en_w      = dut.Core_cpu.u_ifu_subsys.u_ifu_top.cp0_ifu_icache_en;
  wire ic_access_w  = ic_en_w &&
    (dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_if_array.u_icache_if.pcgen_icache_if_seq_data_req ||
     dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_if_array.u_icache_if.pcgen_icache_if_chgflw);
  wire ic_miss_w    = ic_en_w &&
    dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_if_array.u_icache_if.ifu_hpcp_icache_miss_pre;
  wire refill_run_w = dut.Core_cpu.u_ifu_subsys.u_ifu_top.refill_active_block;
  wire ib_accept_w  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.ib_accept;
  // IF 级真的发出了取指 (cache 读或 bypass 读) / IF 手里有块但 IP 不收 (后端反压, 不是 IF 延迟)
  wire if_issue_w   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.ifctrl_ifdp_issue;
  wire ip_hold_w    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.ifctrl_ifdp_hold;
  wire ip_redir_w   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.ip_redirect;
  wire l0_inval_w   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.l0_invalidate;
  integer n_ic_access = 0;   // I-Cache 读事件 (行填充/查询)
  integer n_ic_miss   = 0;   // I-Cache miss (IP 级判定)
  integer n_refill_cyc= 0;   // refill/miss 处理占用拍数
  integer n_ib_accept = 0;   // IF→IB 交接的 16B 块数 (ib_accept)
  integer n_if_issue  = 0;   // IF 级发出取指的拍数 (cache/bypass 都一样算)
  integer n_ip_hold   = 0;   // IF 有块但 IP 不收 (后端反压) 的拍数
  integer n_ip_redir  = 0;   // IP 级改向 (L1 BTB / 块内 L0) 次数
  integer n_l0_inval  = 0;   // L0 失效次数 (与 ip_redir 对账)

  wire st_ctrl_ok = dut.Core_cpu.have_inst_EX & ~dut.Core_cpu.stall
                  & ~dut.Core_cpu.redirect;
  wire st_cond    = dut.Core_cpu.iu_bht_check_vld;   // 已含 have_inst_EX&BRANCH&~stall&~redirect
  wire st_jmp     = st_ctrl_ok & (dut.Core_cpu.ex_is_jump | dut.Core_cpu.ex_is_jalr);
  wire st_mis     = st_ctrl_ok & dut.Core_cpu.mispredict;

  always @(posedge clk) if (!rst) begin
    if (dut.Core_cpu.retire_now)   n_retire  <= n_retire  + 1;
    if (dut.Core_cpu.mispredict)   n_misp_raw<= n_misp_raw+ 1;
    if (dut.Core_cpu.redirect)     n_trap    <= n_trap    + 1;
    if (~dut.Core_cpu.ifu_init_done) n_init  <= n_init    + 1;
    if (~dut.Core_cpu.if_accept)   n_bubble  <= n_bubble  + 1;
    if (dut.Core_cpu.ifu_biu_rd_req & dut.Core_cpu.ifu_biu_rd_grnt)
                                   n_fill    <= n_fill    + 1;
    if (ic_access_w)  n_ic_access  <= n_ic_access  + 1;
    if (ic_miss_w)    n_ic_miss    <= n_ic_miss    + 1;
    if (refill_run_w) n_refill_cyc <= n_refill_cyc + 1;
    if (ib_accept_w)  n_ib_accept  <= n_ib_accept  + 1;
    if (if_issue_w)   n_if_issue   <= n_if_issue   + 1;
    if (ip_hold_w)    n_ip_hold    <= n_ip_hold    + 1;
    if (ip_redir_w)   n_ip_redir   <= n_ip_redir   + 1;
    if (l0_inval_w)   n_l0_inval   <= n_l0_inval   + 1;
    if (st_cond) begin
      n_cond       <= n_cond       + 1;
      n_cond_tpred <= n_cond_tpred + dut.Core_cpu.ex_bht_pred;
      // chk_idx[24] 是预测当时的 BHT 计数器低位: 预测位==1 时, 低位 1 = 强 taken
      // (2'b11), 低位 0 = 弱 taken (2'b10).
      if (dut.Core_cpu.ex_bht_pred &  dut.Core_cpu.ex_bht_chk[24]) n_cond_strong <= n_cond_strong + 1;
      if (dut.Core_cpu.ex_bht_pred & ~dut.Core_cpu.ex_bht_chk[24]) n_cond_weak   <= n_cond_weak   + 1;
      n_cond_taken <= n_cond_taken + dut.Core_cpu.ex_alu_f;
      if ( dut.Core_cpu.ex_bht_pred & ~dut.Core_cpu.ex_alu_f) n_pt_nt <= n_pt_nt + 1;
      if (~dut.Core_cpu.ex_bht_pred &  dut.Core_cpu.ex_alu_f) n_pn_t  <= n_pn_t  + 1;
    end
    if (st_jmp)  n_jmp     <= n_jmp     + 1;
    if (st_mis) begin
      n_mispred <= n_mispred + 1;
      if (st_cond)     n_mis_cond <= n_mis_cond + 1;
      else if (st_jmp) n_mis_jmp  <= n_mis_jmp  + 1;
    end
  end

  task automatic report_branch_stats();
    integer n_cf;
    begin
      n_cf = n_cond + n_jmp;
      $display("");
      $display("================ 分支预测统计 ================");
      $display("周期数                        : %0d (其中 IFU 初始化 %0d)", cycles, n_init);
      $display("退休指令数                    : %0d", n_retire);
      $display("EX 解析的控制转移             : %0d", n_cf);
      $display("  条件分支 / jal,jalr         : %0d / %0d", n_cond, n_jmp);
      $display("误预测 (控制转移)             : %0d", n_mispred);
      $display("  条件分支误预测              : %0d", n_mis_cond);
      $display("  jal/jalr 误预测             : %0d", n_mis_jmp);
      if (n_cond  > 0)
        $display("条件分支准确率                : %0.2f%%  (%0d/%0d 正确)",
                 100.0*(n_cond-n_mis_cond)/n_cond, n_cond-n_mis_cond, n_cond);
      if (n_jmp   > 0)
        $display("jal/jalr 准确率               : %0.2f%%  (%0d/%0d 正确)",
                 100.0*(n_jmp-n_mis_jmp)/n_jmp, n_jmp-n_mis_jmp, n_jmp);
      if (n_cf    > 0)
        $display("总体控制转移准确率            : %0.2f%%  (%0d/%0d 正确)",
                 100.0*(n_cf-n_mispred)/n_cf, n_cf-n_mispred, n_cf);
      if (n_retire> 0)
        $display("每千条指令误预测 (MPKI)       : %0.2f", 1000.0*n_mispred/n_retire);
      $display("条件分支: BHT 预测 taken      : %0d (%0.2f%%), 实际 taken: %0d (%0.2f%%)",
               n_cond_tpred, n_cond ? 100.0*n_cond_tpred/n_cond : 0.0,
               n_cond_taken, n_cond ? 100.0*n_cond_taken/n_cond : 0.0);
      $display("  其中 强 taken(counter=11)   : %0d", n_cond_strong);
      $display("  其中 弱 taken(counter=10)   : %0d", n_cond_weak);
      $display("预测 taken 实际不跳           : %0d", n_pt_nt);
      $display("预测 not-taken 实际跳         : %0d  <- BHT 漏掉的 taken", n_pn_t);
      $display("陷阱/中断/mret 重定向         : %0d", n_trap);
      $display("IFU 取指气泡拍数              : %0d (%0.2f%%)",
               n_bubble, cycles ? 100.0*n_bubble/cycles : 0.0);
      $display("IFU BIU 读事务 (i-cache 填充) : %0d", n_fill);
      // [2026-09-25 前端微架构矩阵]
      $display("I-Cache 读事件 / miss         : %0d / %0d (miss 率 %0.2f%%)",
               n_ic_access, n_ic_miss,
               n_ic_access ? 100.0*n_ic_miss/n_ic_access : 0.0);
      $display("每 miss 的 BIU 读事务         : %0.2f",
               n_ic_miss ? 1.0*n_fill/n_ic_miss : 0.0);
      $display("refill/miss 处理占用拍数      : %0d (%0.2f%%)",
               n_refill_cyc, cycles ? 100.0*n_refill_cyc/cycles : 0.0);
      $display("IF→IP 交接 16B 块数           : %0d  (每块 %0.2f 拍, 每拍 %0.3f 块)",
               n_ib_accept, n_ib_accept ? 1.0*cycles/n_ib_accept : 0.0,
               cycles ? 1.0*n_ib_accept/cycles : 0.0);
      $display("IF 发出取指拍数 / 发而不交     : %0d / %0d  (每交付块发 %.3f 次)",
               n_if_issue, n_if_issue - n_ib_accept,
               n_ib_accept ? 1.0*n_if_issue/n_ib_accept : 0.0);
      $display("IF 有块但 IP 不收 (后端反压)   : %0d (%0.2f%%)",
               n_ip_hold, cycles ? 100.0*n_ip_hold/cycles : 0.0);
      $display("IP 级改向 / L0 失效           : %0d / %0d", n_ip_redir, n_l0_inval);
      $display("每拍交付指令数 (retire/cycle) : %0.3f", cycles ? 1.0*n_retire/cycles : 0.0);
      $display("未门控的 mispredict 拍数      : %0d (自检, 与上面 %0d 应接近)",
               n_misp_raw, n_mispred);
      $display("=============================================");
    end
  endtask

  // ---------------------------------------------------------------------------
  // L0 BTB 与前端供指统计 (纯观测)
  //
  // 分层引用: mycpu → u_ifu_subsys → u_ifu_top → u_bp_top → u_l0
  //   u_l0.*        : L0 BTB 内部信号 (命中/更新/条目状态)
  //   u_ifu_top.*   : IF/IP 级的 L0 交接点 (l0_hit / l0_invalidate / train_*)
  // ---------------------------------------------------------------------------
  wire        l0_lookup_en, l0_hit_w, l0_hit_type1, l0_hit_type2, l0_hit_type3;
  wire        l0_upd_en, l0_upd_match, l0_alloc, l0_kill, l0_hold, l0_fire;
  wire [15:0] l0_vld_v, l0_cnt_v;
  wire [ 2:0] l0_hit_type;
  wire        top_l0_hit, top_l0_inv, top_l0_redir, top_train_v, top_train_t;
  wire [ 2:0] top_train_type;
  wire [15:0] top_l0_invmask;

  // ---------------------------------------------------------------------------
  // [IC1] 定向实验: miniRV 的 GHR (vghr) 到底有没有在动?
  //
  // 起因: 与 C910 跑同一份 branch_bench, 类 3(交替) 只有 50.00%, 而 C910 是 86.72%。
  // 两边的 BHT 是同一结构 (rv32_ifu_bht.v:374-394 与 ct_ifu_bht.v 同源),
  // 预测索引都写着 `pc[6:3] ^ vghr[3:0]`。所以怀疑点很具体: vghr 是不是一直是 0。
  // 若 vghr 恒为 0, 索引退化成纯 PC -> BHT 等价于每-PC 计数器 -> 交替序列上上限就是 50%。
  // ---------------------------------------------------------------------------
  wire [21:0] dbg_vghr;
  wire [21:0] dbg_vghr_ip;
  wire [ 3:0] dbg_vghr_ofs;
  assign dbg_vghr      = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.vghr_q;
  assign dbg_vghr_ip   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_ipdp_vghr_q;
  assign dbg_vghr_ofs  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.pre_vghr_offset_0;

  wire [31:0] dbg_taken_v, dbg_ntake_v, dbg_sel_v;
  wire [ 1:0] dbg_selr;
  wire [ 1:0] dbg_cnt;
  assign dbg_taken_v = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.bht_ipdp_pre_array_data_taken;
  assign dbg_ntake_v = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.bht_ipdp_pre_array_data_ntake;
  assign dbg_sel_v   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.bht_selected;
  assign dbg_selr    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.bht_ipdp_sel_array_result;
  assign dbg_cnt     = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.bht_counter;

  // 每个 2 位计数器只看 MSB (奇数位): 有没有任何一个计数器 >= 2
  wire dbg_sel_has2 = |(dbg_sel_v & 32'hAAAA_AAAA);

  wire dbg_ghr_iu, dbg_ghr_lbuf, dbg_ghr_ip, dbg_lbuf_act, dbg_ip_conbr, dbg_bju_chk;
  assign dbg_ghr_iu    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.ghr_updt_vld;
  assign dbg_ghr_lbuf  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.vghr_lbuf_updt_vld;
  assign dbg_ghr_ip    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.vghr_ip_updt_vld;
  assign dbg_lbuf_act  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.lbuf_bht_active_state;
  assign dbg_ip_conbr  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.ipctrl_bht_con_br_vld;
  assign dbg_bju_chk   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.iu_ifu_bht_check_vld;

  wire dbg_ev, dbg_chk;
  assign dbg_ev  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.ipctrl_bht_con_br_vld;
  assign dbg_chk = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.iu_ifu_bht_check_vld;

  integer dbg_n_iu = 0, dbg_n_lbuf = 0, dbg_n_ip = 0, dbg_n_lact = 0, dbg_n_icb = 0, dbg_n_bchk = 0;
  // GHR 多移的嫌疑: 同一根分支连着两拍都发 bht_event
  integer dbg_ev2 = 0, dbg_ev_nochk = 0, dbg_chk_noev = 0;
  // vghr_q[3:0] 的 16 桶直方图 (自锁假设: 若被预测位填满, 会极端集中在 0 或 15)
  integer dbg_gh0 = 0, dbg_gh15 = 0, dbg_gh_mid = 0, dbg_offs_uniq_seen = 0;
  // 解锁通路: ghr_updt_vld && iu_ifu_bht_check_vld 时用真实结果 {bju_ghr[20:0], condbr_taken} 覆盖
  wire dbg_unlock = dbg_ghr_iu && dbg_chk;
  wire dbg_unl_t  = dbg_unlock && dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.iu_ifu_bht_condbr_taken;
  integer dbg_n_unlock = 0, dbg_n_unl_t = 0;
  reg [15:0] dbg_offs_acc = 16'h0;   // 必须显式初始化: 本机 VCS 不清零 reg
  reg [3:0]  dbg_gh_q;
  reg dbg_ev_q, dbg_chk_q;
  integer dbg_tkn_nz = 0, dbg_ntk_nz = 0, dbg_selr1 = 0, dbg_has2 = 0, dbg_cnt1 = 0;
  integer dbg_nz = 0, dbg_chg = 0, dbg_ipdiff = 0, dbg_ofsnz = 0;
  reg [21:0] dbg_prev = 0;
  reg        dbg_seen = 0;

  // ---------------------------------------------------------------------------
  // [IC1] 大 BTB (L1, rv32_ifu_btb) 的贡献
  //
  // 起因: 之前把"L0 命中率只有 30%"当成要提的指标, 但 C910 的 L0 只是快滤
  // (可用命中仅 4,301, 条件分支目标全靠大 BTB)。自研核也有大 BTB 且是活的,
  // 所以先量清楚"目标预测"到底由谁承担, 再谈该不该动 L0 的容量。
  // ---------------------------------------------------------------------------
  wire        bt_lookup_vld, bt_result_vld, bt_if_vld;
  wire [ 3:0] bt_hit, bt_if_hit;
  wire [31:0] bt_if_pc;
  assign bt_lookup_vld = dut.Core_cpu.u_ifu_subsys.u_ifu_top.ifctrl_btb_lookup_vld;
  assign bt_result_vld = dut.Core_cpu.u_ifu_subsys.u_ifu_top.btb_result_vld;
  assign bt_hit        = dut.Core_cpu.u_ifu_subsys.u_ifu_top.btb_hit;
  assign bt_if_vld     = dut.Core_cpu.u_ifu_subsys.u_ifu_top.btb_if_vld;
  assign bt_if_hit     = dut.Core_cpu.u_ifu_subsys.u_ifu_top.btb_if_hit;
  assign bt_if_pc      = dut.Core_cpu.u_ifu_subsys.u_ifu_top.btb_if_pc;

  integer bt_n_lookup = 0, bt_n_result = 0, bt_n_hit = 0, bt_n_ifvld = 0, bt_n_ifhit = 0;
  integer bt_cls_lk [0:5], bt_cls_ht [0:5];
  integer bti;
  initial begin
    bt_n_lookup = 0; bt_n_result = 0; bt_n_hit = 0; bt_n_ifvld = 0; bt_n_ifhit = 0;
    for (bti = 0; bti <= 5; bti = bti + 1) begin bt_cls_lk[bti] = 0; bt_cls_ht[bti] = 0; end
  end
  always @(posedge clk) if (!rst && bench_en) begin
    if (bt_lookup_vld) bt_n_lookup = bt_n_lookup + 1;
    if (bt_result_vld) bt_n_result = bt_n_result + 1;
    if (bt_result_vld && (|bt_hit)) bt_n_hit = bt_n_hit + 1;
    if (bt_if_vld) bt_n_ifvld = bt_n_ifvld + 1;
    if (bt_if_vld && (|bt_if_hit)) bt_n_ifhit = bt_n_ifhit + 1;
    if (bt_if_vld) begin
      bt_cls_lk[bench_class(bt_if_pc)] = bt_cls_lk[bench_class(bt_if_pc)] + 1;
      if (|bt_if_hit) bt_cls_ht[bench_class(bt_if_pc)] = bt_cls_ht[bench_class(bt_if_pc)] + 1;
    end
  end

  // ===========================================================================
  // [IC1] Q1: L1 大 BTB 逐 PC 普查 (窗口 [0x100,0x320), 4 字节粒度 -> 136 桶)
  //
  // 起因: 类 5 的 L1 查询命中率只有 48.97% (C910 99.32%), 而类 5 的 8 条分支
  //   各自独占一行 (PC[3:0]=0 -> 行地址 0x2a..0x31 互不别名), 目标恒为 +8,
  //   查表又只在 16 字节块的起点。所以"查不到"只可能是两种情况之一:
  //     (a) 大量查询的 PC 上根本没有分支 (取指包密度问题, 与表无关);
  //     (b) 分支 PC 上确实没写进条目 / 写了别名。
  //   逐 PC 普查把这两种一次分开 —— 只看类的合计命中率永远看不出来。
  //
  // 观测点: bt_if_vld / bt_if_pc (= u_btb.rd_pc_q, 与 if_hit 同拍同地址)。
  //   rv32_ifu_btb.v:185  slot_eligible[s] = enable && s >= rd_pc_q[3:2] && rd_pc_q[1:0]==0
  //   所以对"查询起点自己的槽位" s = pc[3:2] 而言, 可用性只取决于 pc[1:0]==0;
  //   但任意 >= 该位置的槽位命中都算命中, 因此这里按【可用槽位集合】再算一次:
  //     ev = 可用槽位里有有效项   (结构上还有戏)
  //     em = 可用槽位里有 tag 匹配 (理论上就该命中)
  //   ev/em 与 lk/ht 对不上时, 问题在 eligible 判定而不是表内容。
  // ===========================================================================
  localparam integer BTW_BASE = 32'h0000_0100;
  localparam integer BTW_N    = 136;   // (0x320-0x100)/4

  wire [79:0] btw_tag_all;
  wire        btw_upd_vld, btw_upd_rdy, btw_upd_fire, btw_rdy;
  wire [31:0] btw_upd_pc;
  assign btw_tag_all  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_btb.tag_q;
  assign btw_upd_vld  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_btb.update_vld;
  assign btw_upd_rdy  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_btb.update_ready;
  assign btw_upd_fire = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_btb.upd;
  assign btw_upd_pc   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_btb.update_pc;
  assign btw_rdy      = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_btb.lookup_ready;

  integer btw_lk  [0:135];   // 查询次数
  integer btw_ht  [0:135];   // 命中次数
  integer btw_ev  [0:135];   // 可用槽位里有有效项
  integer btw_em  [0:135];   // 可用槽位里有 tag 匹配
  integer btw_occ [0:135];   // 该 16 字节行 4 个槽位的有效位数之和 (按查询累加)
  integer btw_uf  [0:135];   // 更新真正写进 SRAM
  integer btw_idx, btw_s, btw_bin;
  reg [3:0] btw_v, btw_m, btw_emask;
  initial for (btw_idx = 0; btw_idx < BTW_N; btw_idx = btw_idx + 1) begin
    btw_lk[btw_idx]=0; btw_ht[btw_idx]=0; btw_ev[btw_idx]=0;
    btw_em[btw_idx]=0; btw_occ[btw_idx]=0; btw_uf[btw_idx]=0;
  end

  always @(posedge clk) if (!rst && bench_en) begin
    if (bt_if_vld) begin
      btw_bin = (bt_if_pc - BTW_BASE) >> 2;
      if (btw_bin >= 0 && btw_bin < BTW_N) begin
        btw_lk[btw_bin] = btw_lk[btw_bin] + 1;
        if (|bt_if_hit) btw_ht[btw_bin] = btw_ht[btw_bin] + 1;
        btw_v = 4'b0; btw_m = 4'b0;
        for (btw_s = 0; btw_s < 4; btw_s = btw_s + 1) begin
          if (btw_tag_all[btw_s*20+19]) begin
            btw_v[btw_s] = 1'b1;
            if (btw_tag_all[btw_s*20 +: 19] == bt_if_pc[31:13]) btw_m[btw_s] = 1'b1;
          end
        end
        btw_occ[btw_bin] = btw_occ[btw_bin] + $countones(btw_v);
        if (bt_if_pc[1:0] == 2'b00) begin
          btw_emask = 4'b1111 << bt_if_pc[3:2];
          if (|(btw_v & btw_emask)) btw_ev[btw_bin] = btw_ev[btw_bin] + 1;
          if (|(btw_m & btw_emask)) btw_em[btw_bin] = btw_em[btw_bin] + 1;
        end
      end
    end
    if (btw_upd_fire) begin
      btw_bin = (btw_upd_pc - BTW_BASE) >> 2;
      if (btw_bin >= 0 && btw_bin < BTW_N) btw_uf[btw_bin] = btw_uf[btw_bin] + 1;
    end
  end

  // ===========================================================================
  // [IC1] Q1 附带: L1 BTB 的【阻塞】与【更新落空】
  //
  // 目的: 分清"查得慢"和"查不准"。lookup_vld 拉高但 lookup_ready=0 的拍数就是
  //   IF 想查表却查不成 (写缓冲占着单口 / 初始化 / cancel), 这类拍会直接变成
  //   取指气泡, 是 Q4 要量化的东西。更新侧统计 train_valid 里有多少既没写进
  //   SRAM 也没留下缓冲 (pc/target 非 4 字节对齐被 upd 直接丢掉)。
  // ===========================================================================
  integer btw_blk = 0, btw_upd_acc = 0, btw_upd_drp = 0;
  always @(posedge clk) if (!rst && bench_en) begin
    if (bt_lookup_vld && !btw_rdy) btw_blk = btw_blk + 1;
    if (btw_upd_vld && btw_upd_rdy) begin
      btw_upd_acc = btw_upd_acc + 1;
      if (!btw_upd_fire) btw_upd_drp = btw_upd_drp + 1;
    end
  end



  // ---------------------------------------------------------------------------
  // [IC1] 定向实验 Step 1: BHT 预测时刻的"四元组"
  //
  // 问题: 类 3(交替) 只有 50.00%、且 4096 次里一次 taken 都没预测出来;
  //       类 5(T,T,T,N) 是 89.31%, 工作正常。两者都带跨分支相关性, 差在哪一步?
  //
  // 做法: 在 IP 级条件分支有效那一拍, 采
  //         ip_pc                        (IP 级 PC, 字节地址)
  //         bht_ipdp_pre_offset_onehot   (片内 16 选 1, = PC[7:4] ^ GHR[3:0])
  //         bht_ipdp_sel_array_result    (bit1 选 taken/ntake 平面)
  //         bht_counter                  (选中的 2 位计数器; 预测 = bit1)
  //       按【类内第几条分支】分桶, 累积"出现过的取值集合"(按位或) 与计数。
  //
  // 判定规则(计划里已先定好, 避免第二次猜错):
  //   mask_oh  只有 1 位               -> 片内偏移卡死 => GHR[3:0] 在预测时刻不变
  //   mask_oh  多位、mask_cnt bit1 恒 0 -> 计数器没分开 => 训练写错地方/没写
  //   mask_oh  变、mask_sel 恒一值      -> 平面选错
  // 类 5 是"工作正常"的对照; 两者的差异就是答案。
  // ---------------------------------------------------------------------------
  wire        st_ipvld;
  wire [31:0] st_pc;
  wire [15:0] st_oh;
  wire [ 1:0] st_sel;
  wire [ 1:0] st_cnt;
  assign st_ipvld = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.ipctrl_bht_con_br_vld;
  assign st_pc    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.ip_pc;
  assign st_oh    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.bht_ipdp_pre_offset_onehot;
  assign st_sel   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.bht_ipdp_sel_array_result;
  assign st_cnt   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.bht_counter;
  // pre-array 的【行地址】。它由 {vghr_q[11:8], vghr_q[7:2]^vghr_q[19:14]} 造出,
  // 用到 19 位历史 —— 是"深位历史有没有在动"的唯一观察窗。行一变就是完全不同的
  // 计数器组, 所以即使低 4 位还是预测位, 也有可能从行这一路把自锁解开。
  wire [9:0]  st_row;
  assign st_row   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_pred_array_rd_index;

  // 类 3 基准 0x1c0 (分支在 0x1d0+16k) / 类 5 基准 0x290 (分支在 0x2a0+16k)
  integer st_idx3, st_idx5;
  integer st_n3   [0:15], st_n5   [0:15];
  integer st_oh3  [0:15], st_oh5  [0:15];
  integer st_sel3 [0:15], st_sel5 [0:15];
  integer st_cnt3 [0:15], st_cnt5 [0:15];
  integer st_tk3  [0:15], st_tk5  [0:15];
  integer st_pc3  [0:15], st_pc5  [0:15];
  // cnt 的 4 桶直方图: 区分"被训得来回摆"(00/01 各半) 与"几乎没写过"(全 00)
  integer st_c3_00[0:15], st_c3_01[0:15], st_c3_10[0:15], st_c3_11[0:15];
  integer st_row3 [0:15], st_row5 [0:15];   // 行地址的按位或 => 取值集合

  integer si;
  initial for (si = 0; si < 16; si = si + 1) begin
    st_n3[si]=0; st_n5[si]=0; st_oh3[si]=0; st_oh5[si]=0;
    st_sel3[si]=0; st_sel5[si]=0; st_cnt3[si]=0; st_cnt5[si]=0;
    st_tk3[si]=0; st_tk5[si]=0; st_pc3[si]=0; st_pc5[si]=0;
    st_c3_00[si]=0; st_c3_01[si]=0; st_c3_10[si]=0; st_c3_11[si]=0;
    st_row3[si]=0; st_row5[si]=0;
  end

  always @(posedge clk) if (!rst && bench_en && st_ipvld) begin
    if (bench_class(st_pc) == 3) begin
      st_idx3 = ((st_pc - 32'h1c0) >> 4) & 15;
      st_n3  [st_idx3] = st_n3  [st_idx3] + 1;
      st_oh3 [st_idx3] = st_oh3 [st_idx3] | st_oh;
      st_sel3[st_idx3] = st_sel3[st_idx3] | st_sel;
      st_cnt3[st_idx3] = st_cnt3[st_idx3] | st_cnt;
      if (st_cnt[1]) st_tk3[st_idx3] = st_tk3[st_idx3] + 1;
      case (st_cnt)
        2'b00: st_c3_00[st_idx3] = st_c3_00[st_idx3] + 1;
        2'b01: st_c3_01[st_idx3] = st_c3_01[st_idx3] + 1;
        2'b10: st_c3_10[st_idx3] = st_c3_10[st_idx3] + 1;
        2'b11: st_c3_11[st_idx3] = st_c3_11[st_idx3] + 1;
      endcase
      st_row3[st_idx3] = st_row3[st_idx3] | st_row;
      st_pc3 [st_idx3] = st_pc;
    end
    if (bench_class(st_pc) == 5) begin
      st_idx5 = ((st_pc - 32'h290) >> 4) & 15;
      st_n5  [st_idx5] = st_n5  [st_idx5] + 1;
      st_oh5 [st_idx5] = st_oh5 [st_idx5] | st_oh;
      st_sel5[st_idx5] = st_sel5[st_idx5] | st_sel;
      st_cnt5[st_idx5] = st_cnt5[st_idx5] | st_cnt;
      if (st_cnt[1]) st_tk5[st_idx5] = st_tk5[st_idx5] + 1;
      st_row5[st_idx5] = st_row5[st_idx5] | st_row;
      st_pc5 [st_idx5] = st_pc;
    end
  end

  // ===========================================================================
  // [IC1] Q2: 类 3 / 类 5 的【逐条分支】方向准确率
  //
  // 口径与 §1.2 的"最终预测 vs 实际跳转"完全一致 (ex_bht_pred / ex_alu_f),
  //   只是把桶从"整类"细化到"类内第几条静态分支", 好和 C910 侧那张
  //   cls5 posN 表逐行对照 (pos = ((pc-基准)>>4), 类3 基准 0x1c0 / 类5 基准 0x290,
  //   实测分支落在 pos1..pos8, 与 C910 编号一致)。
  // ===========================================================================
  integer b3_cond [0:15], b3_mis [0:15], b3_tp [0:15], b3_tk [0:15], b3_pc [0:15];
  integer b5_cond [0:15], b5_mis [0:15], b5_tp [0:15], b5_tk [0:15], b5_pc [0:15];
  integer bpos, bclsx;
  initial for (bpos = 0; bpos < 16; bpos = bpos + 1) begin
    b3_cond[bpos]=0; b3_mis[bpos]=0; b3_tp[bpos]=0; b3_tk[bpos]=0; b3_pc[bpos]=0;
    b5_cond[bpos]=0; b5_mis[bpos]=0; b5_tp[bpos]=0; b5_tk[bpos]=0; b5_pc[bpos]=0;
  end

  always @(posedge clk) if (!rst && bench_en) begin
    if (st_cond || st_mis) begin
      bclsx = bench_class(dut.Core_cpu.pc_EX);
      if (bclsx == 3) begin
        bpos = ((dut.Core_cpu.pc_EX - 32'h0000_01c0) >> 4) & 15;
        if (st_cond) begin
          b3_cond[bpos] = b3_cond[bpos] + 1;
          b3_pc  [bpos] = dut.Core_cpu.pc_EX;
          b3_tp  [bpos] = b3_tp  [bpos] + dut.Core_cpu.ex_bht_pred;
          b3_tk  [bpos] = b3_tk  [bpos] + dut.Core_cpu.ex_alu_f;
        end
        if (st_mis && st_cond) b3_mis[bpos] = b3_mis[bpos] + 1;
      end else if (bclsx == 5) begin
        bpos = ((dut.Core_cpu.pc_EX - 32'h0000_0290) >> 4) & 15;
        if (st_cond) begin
          b5_cond[bpos] = b5_cond[bpos] + 1;
          b5_pc  [bpos] = dut.Core_cpu.pc_EX;
          b5_tp  [bpos] = b5_tp  [bpos] + dut.Core_cpu.ex_bht_pred;
          b5_tk  [bpos] = b5_tk  [bpos] + dut.Core_cpu.ex_alu_f;
        end
        if (st_mis && st_cond) b5_mis[bpos] = b5_mis[bpos] + 1;
      end
    end
  end

  // ===========================================================================
  // [IC1] Q3: 类 3 的 (行地址, 计数器, 相位) 联合分布
  //
  // 之前只有"行地址取值集合"和"计数器取值集合"两个【边缘分布】, 缺的是联合:
  //   行地址与相位到底相不相关? 这一步就是回答它。
  //
  // 相位怎么来: 类 3 的 8 条分支全是 `beq x9, x0`, 而 x9 每个外层轮次翻一次
  //   (0x1c0 的 xori), 所以同一轮内 8 条分支结局相同、轮次之间交替。
  //   第 k 轮 x9 = k&1, 分支 taken <=> x9==0 <=> k 为偶数。
  //
  //   关键是不能用"某条分支被预测了几次"来数轮次: 实测类 3 的位置 2..8 每轮
  //   会被【预测多次】(0x1f0 有 1024 次预测但只有 512 次到 EX), 多出来的是
  //   冲刷前被杀掉的投机预测 —— 用它们数轮次相位就全乱了 (第一版就栽在这)。
  //   改成数【进入类 3 区间的次数】: IP 级采样序列里 bench_class 由非 3 变成 3
  //   的那一拍就是新的一轮, 与重复预测无关, 也不受冲刷影响。
  //
  // 表按【类内位置 x 该位置出现过的行地址】组织 (每个位置最多 16 个不同行),
  //   每格再按相位与 2 位计数器分桶 —— 于是可以直接读出:
  //   同一个行地址下面, cnt 会不会因为相位不同而不同; 若每格都是 00/01 混在一起,
  //   说明这个索引根本没把相位分开, 问题在索引构造而不在计数器训练。
  // 类 5 同表但按 mod 4 相位 (x30&3, 分支 taken <=> 相位!=3), 作为"工作正常"的对照。
  // ===========================================================================
  integer j3_key [0:255], j3_n [0:255], j3_s0 [0:255], j3_s1 [0:255];
  integer j3_c0 [0:255], j3_c1 [0:255], j3_c2 [0:255], j3_c3 [0:255];
  integer j3_slotv[0:15];
  integer j5_key [0:255], j5_n [0:255];
  integer j5_p0 [0:255], j5_p1 [0:255], j5_p2 [0:255], j5_p3 [0:255];
  integer j5_c0 [0:255], j5_c1 [0:255], j5_c2 [0:255], j5_c3 [0:255];
  integer j5_slotv[0:15];
  integer jk, jpos, jslot, jidx;
  integer jround3 = 0, jround5 = 0;   // 进入类 3 / 类 5 区间的次数 = 外层轮次 k
  reg     jinc3 = 0, jinc5 = 0;       // 上一拍采样是否落在类 3 / 类 5 里
  integer j_phase_odd;

  // [Q3-3] 预测时刻的 GHR 与片内偏移, 按相位分开记 (or/and 夹逼取值集合)
  //   若 相位0 与 相位1 的集合完全相同, 说明相位信息根本没进到索引里;
  //   若不同, 那问题就在"计数器怎么用这个索引"而不是"索引没有相位信息"。
  reg [21:0] j3_gp0_or [0:15], j3_gp0_ad [0:15];
  reg [21:0] j3_gp1_or [0:15], j3_gp1_ad [0:15];
  reg [15:0] j3_oh0_or [0:15], j3_oh1_or [0:15];
  reg [9:0]  j3_rw0_or [0:15], j3_rw1_or [0:15];
  integer j3_ng0 [0:15], j3_ng1 [0:15];
  // 类 5 的对照: 按"是不是第 4 拍(N 相位)"分两堆
  reg [21:0] j5_gn_or [0:15], j5_gn_ad [0:15];   // N 相位 (ph3)
  reg [21:0] j5_gt_or [0:15], j5_gt_ad [0:15];   // T 相位 (ph0..2)
  integer j5_ngn [0:15], j5_ngt [0:15];
  wire [21:0] j3_h_now;
  assign j3_h_now = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.vghr_q;
  initial begin
    for (jk = 0; jk < 256; jk = jk + 1) begin
      j3_key[jk]=-1; j3_n[jk]=0; j3_s0[jk]=0; j3_s1[jk]=0;
      j3_c0[jk]=0; j3_c1[jk]=0; j3_c2[jk]=0; j3_c3[jk]=0;
      j5_key[jk]=-1; j5_n[jk]=0;
      j5_p0[jk]=0; j5_p1[jk]=0; j5_p2[jk]=0; j5_p3[jk]=0;
      j5_c0[jk]=0; j5_c1[jk]=0; j5_c2[jk]=0; j5_c3[jk]=0;
    end
    for (jk = 0; jk < 16; jk = jk + 1) begin
      j3_slotv[jk]=0; j5_slotv[jk]=0;
      j3_gp0_or[jk]=22'b0;  j3_gp0_ad[jk]=22'h3F_FFFF;
      j3_gp1_or[jk]=22'b0;  j3_gp1_ad[jk]=22'h3F_FFFF;
      j3_oh0_or[jk]=16'b0;  j3_oh1_or[jk]=16'b0;
      j3_rw0_or[jk]=10'b0;  j3_rw1_or[jk]=10'b0;
      j3_ng0[jk]=0;         j3_ng1[jk]=0;
      j5_gn_or[jk]=22'b0;   j5_gn_ad[jk]=22'h3F_FFFF;
      j5_gt_or[jk]=22'b0;   j5_gt_ad[jk]=22'h3F_FFFF;
      j5_ngn[jk]=0;         j5_ngt[jk]=0;
    end
  end

  always @(posedge clk) if (!rst && bench_en && st_ipvld) begin
    if (bench_class(st_pc) == 3 && !jinc3) jround3 = jround3 + 1;
    if (bench_class(st_pc) == 5 && !jinc5) jround5 = jround5 + 1;
    jinc3 = (bench_class(st_pc) == 3);
    jinc5 = (bench_class(st_pc) == 5);

    if (bench_class(st_pc) == 3) begin
      jpos = ((st_pc - 32'h0000_01c0) >> 4) & 15;
      // 第 k 轮 taken <=> k 为偶数; 相位1 记 "这一轮该跳"
      j_phase_odd = ((jround3 & 1) == 0);
      jslot = -1;
      for (jk = 0; jk < j3_slotv[jpos]; jk = jk + 1)
        if (j3_key[jpos*16+jk] == st_row) jslot = jk;
      if (jslot < 0 && j3_slotv[jpos] < 16) begin
        jslot = j3_slotv[jpos];
        j3_slotv[jpos] = j3_slotv[jpos] + 1;
        j3_key[jpos*16+jslot] = st_row;
      end
      if (j_phase_odd) begin
        j3_gp1_or[jpos] = j3_gp1_or[jpos] | j3_h_now;
        j3_gp1_ad[jpos] = j3_gp1_ad[jpos] & j3_h_now;
        j3_oh1_or[jpos] = j3_oh1_or[jpos] | st_oh;
        j3_rw1_or[jpos] = j3_rw1_or[jpos] | st_row;
        j3_ng1[jpos] = j3_ng1[jpos] + 1;
      end else begin
        j3_gp0_or[jpos] = j3_gp0_or[jpos] | j3_h_now;
        j3_gp0_ad[jpos] = j3_gp0_ad[jpos] & j3_h_now;
        j3_oh0_or[jpos] = j3_oh0_or[jpos] | st_oh;
        j3_rw0_or[jpos] = j3_rw0_or[jpos] | st_row;
        j3_ng0[jpos] = j3_ng0[jpos] + 1;
      end
      if (jslot >= 0) begin
        jidx = jpos*16 + jslot;
        j3_n[jidx] = j3_n[jidx] + 1;
        if (j_phase_odd) j3_s1[jidx] = j3_s1[jidx] + 1;
        else             j3_s0[jidx] = j3_s0[jidx] + 1;
        case (st_cnt)
          2'b00: j3_c0[jidx] = j3_c0[jidx] + 1;
          2'b01: j3_c1[jidx] = j3_c1[jidx] + 1;
          2'b10: j3_c2[jidx] = j3_c2[jidx] + 1;
          2'b11: j3_c3[jidx] = j3_c3[jidx] + 1;
        endcase
      end
    end
    if (bench_class(st_pc) == 5) begin
      jpos = ((st_pc - 32'h0000_0290) >> 4) & 15;
      if ((jround5 & 3) == 3) begin
        j5_gn_or[jpos] = j5_gn_or[jpos] | j3_h_now;
        j5_gn_ad[jpos] = j5_gn_ad[jpos] & j3_h_now;
        j5_ngn[jpos] = j5_ngn[jpos] + 1;
      end else begin
        j5_gt_or[jpos] = j5_gt_or[jpos] | j3_h_now;
        j5_gt_ad[jpos] = j5_gt_ad[jpos] & j3_h_now;
        j5_ngt[jpos] = j5_ngt[jpos] + 1;
      end
      jslot = -1;
      for (jk = 0; jk < j5_slotv[jpos]; jk = jk + 1)
        if (j5_key[jpos*16+jk] == st_row) jslot = jk;
      if (jslot < 0 && j5_slotv[jpos] < 16) begin
        jslot = j5_slotv[jpos];
        j5_slotv[jpos] = j5_slotv[jpos] + 1;
        j5_key[jpos*16+jslot] = st_row;
      end
      if (jslot >= 0) begin
        jidx = jpos*16 + jslot;
        j5_n[jidx] = j5_n[jidx] + 1;
        // 第 k 轮 x29 = k&3, 分支 taken <=> (k&3)!=3
        case (jround5 & 3)
          2'd0: j5_p0[jidx] = j5_p0[jidx] + 1;
          2'd1: j5_p1[jidx] = j5_p1[jidx] + 1;
          2'd2: j5_p2[jidx] = j5_p2[jidx] + 1;
          default: j5_p3[jidx] = j5_p3[jidx] + 1;
        endcase
        case (st_cnt)
          2'b00: j5_c0[jidx] = j5_c0[jidx] + 1;
          2'b01: j5_c1[jidx] = j5_c1[jidx] + 1;
          2'b10: j5_c2[jidx] = j5_c2[jidx] + 1;
          2'b11: j5_c3[jidx] = j5_c3[jidx] + 1;
        endcase
      end
    end
  end

  // ===========================================================================
  // [IC1] Q3-2: 读索引 vs 写索引 —— 被读的那一行到底有没有被写过
  //
  // Q3 的联合分布只能看出"读到的计数器卡在 00/01"; 还差一步: 是【没训练】还是
  //   【训练写到别处去了】。两者在同一张表里长得一样, 必须直接比对索引。
  //
  // rv32_ifu_bht.v 的两条索引表达式 (与 C910 ct_ifu_bht.v:477 / :1259 逐字符相同):
  //   读 (正常预测路径, :394)  = {vghr_q[11:8], vghr_q[7:2] ^ vghr_q[19:14]}
  //   写 (预测阵列写缓冲, :1055)= {cur_ghr[13:10], cur_ghr[9:4] ^ cur_ghr[21:16]}
  // 两个表达式的**位窗不同**(读用 11:8/19:14, 写用 13:10/21:16, 整体差 2 位)。
  //   在 C910 原设计里这个错位是靠"读在 IP 级用 vghr_q、写在提交级用随包带下来
  //   的 GHR"来抵消的 —— 一旦两边带的历史不对齐, 读的行就永远等不到写。
  //   这里不做任何推断, 只按位置分别累计读到的行集合与写入的行集合, 看重叠。
  //
  //   读集合为空 / 写集合为空 / 交集为空  —— 三种情况指向完全不同的修法。
  // ===========================================================================
  // 写侧不再用 cur_cur_pc 归属 (实测该分层引用读出来是常数 0x03f, 不可信),
  //   改成直接看预测阵列 SRAM 的**实际写地址** bht_pred_array_index +
  //   写使能 bht_pred_array_wen_b, 再用一个衰减窗口把写归到最近的类区间。
  //   窗口宽度 96 拍: 类 3 的 8 条分支预测跨度约 80~130 拍, 写滞后预测十几拍,
  //   所以窗口能覆盖住本类的写; 也必然会捎带一点下一类的写 —— 但这里要回答的是
  //   "类 3 读的那些行到底有没有被写过", 捎带只会让结论更保守。
  wire [9:0]  q3w_idx;
  wire        q3w_inv;
  wire [31:0] q3w_wen;
  wire        q3w_cen_b;
  // 直接取【写索引】而不是 mux 后的 SRAM 地址: bht_pred_array_index 在读/写同拍时
  // 优先给读索引(见 rv32_ifu_bht.v:364-372 的优先级), 用它会张冠李戴。
  assign q3w_idx = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_wr_buf_pred_updt_index;
  assign q3w_inv = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_inv_on_q;
  assign q3w_wen = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_pred_array_wen_b;
  // cen_b=0 才是 SRAM 真的使能; 只看 wen_b 会把被 cen_b 压掉的拍也算成写,
  // 而那些拍地址 mux 走的是【读】索引 —— 这正是之前"写地址全不对"的来源。
  assign q3w_cen_b = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_pred_array_cen_b;

  reg [1023:0] q3_rd3 [0:15];
  reg [1023:0] q3_wr3 [0:15];
  reg [1023:0] q3_rd5 [0:15];
  reg [1023:0] q3_wr5 [0:15];
  integer q3_k, q3_p, q3_nrd3 = 0, q3_nwr3 = 0, q3_nrd5 = 0, q3_nwr5 = 0;
  integer q3_wpc, q3_wposx;
  initial for (q3_k = 0; q3_k < 16; q3_k = q3_k + 1) begin
    q3_rd3[q3_k] = 1024'b0; q3_wr3[q3_k] = 1024'b0;
    q3_rd5[q3_k] = 1024'b0; q3_wr5[q3_k] = 1024'b0;
  end

  always @(posedge clk) if (!rst && bench_en && st_ipvld) begin
    if (bench_class(st_pc) == 3) begin
      q3_p = ((st_pc - 32'h0000_01c0) >> 4) & 15;
      q3_rd3[q3_p] = q3_rd3[q3_p] | (1024'b1 << st_row);
    end
    if (bench_class(st_pc) == 5) begin
      q3_p = ((st_pc - 32'h0000_0290) >> 4) & 15;
      q3_rd5[q3_p] = q3_rd5[q3_p] | (1024'b1 << st_row);
    end
  end

  reg [1023:0] q3_wr3all = 1024'b0, q3_wr5all = 1024'b0, q3_wrall = 1024'b0;
  integer q3_nall = 0, q3_c3all = 0, q3_c5all = 0;
  integer q3_c3win = 0, q3_c5win = 0;
  // 本地复算: 同一个 GHR 值 h 分别代进"读窗口"与"写窗口"两条表达式, 看会不会撞
  wire [21:0] q3_h;
  wire [9:0]  q3_rd_of_h, q3_wr_of_h;
  assign q3_h       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.vghr_q;
  assign q3_rd_of_h = {q3_h[11:8], q3_h[7:2] ^ q3_h[19:14]};
  assign q3_wr_of_h = {q3_h[13:10], q3_h[9:4] ^ q3_h[21:16]};
  // 随包带下去的那个 GHR (bht_ipdp_vghr_q) —— 写索引用的就是它 (经 iu_chk_idx 原样回来)
  wire [21:0] q3_hc;
  wire [9:0]  q3_wr_of_hc, q3_wr_of_hc2;
  assign q3_hc       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_ipdp_vghr_q;
  assign q3_wr_of_hc = {q3_hc[13:10], q3_hc[9:4] ^ q3_hc[21:16]};
  assign q3_wr_of_hc2 = {q3_hc[11:8], q3_hc[7:2] ^ q3_hc[19:14]};
  integer q3_same3 = 0, q3_same5 = 0, q3_tot3 = 0, q3_tot5 = 0;
  integer q3_csame3 = 0, q3_csame5 = 0, q3_hdiff = 0, q3_shift3 = 0, q3_shift5 = 0;
  integer q3_tot3x = 0, q3_tot5x = 0;

  always @(posedge clk) if (!rst && bench_en) begin
    if (st_ipvld) begin
      if (q3_hc !== q3_h) q3_hdiff = q3_hdiff + 1;
      if (bench_class(st_pc) == 3) begin
        q3_tot3 = q3_tot3 + 1;
        if (q3_wr_of_h == q3_rd_of_h) q3_same3 = q3_same3 + 1;
        // 真正会用的那一次: 写索引(用随包的 GHR) 是不是等于 读索引
        if (q3_wr_of_hc == q3_rd_of_h) q3_csame3 = q3_csame3 + 1;
        // 若随包 GHR 恰好比 vghr_q 少/多 2 位, 用同一窗口代进去会不会对上
        if (q3_wr_of_hc2 == q3_rd_of_h) q3_shift3 = q3_shift3 + 1;
        q3_tot3x = q3_tot3x + 1;
        q3_c3win = 96;
      end
      if (bench_class(st_pc) == 5) begin
        q3_tot5 = q3_tot5 + 1;
        if (q3_wr_of_h == q3_rd_of_h) q3_same5 = q3_same5 + 1;
        if (q3_wr_of_hc == q3_rd_of_h) q3_csame5 = q3_csame5 + 1;
        if (q3_wr_of_hc2 == q3_rd_of_h) q3_shift5 = q3_shift5 + 1;
        q3_tot5x = q3_tot5x + 1;
        q3_c5win = 96;
      end
    end
    if (q3_c3win > 0) q3_c3win = q3_c3win - 1;
    if (q3_c5win > 0) q3_c5win = q3_c5win - 1;
    if (!q3w_inv && (|(~q3w_wen)) && !q3w_cen_b) begin
      q3_nall = q3_nall + 1;
      q3_wrall = q3_wrall | (1024'b1 << q3w_idx);
      if (q3_c3win > 0) begin
        q3_wr3all = q3_wr3all | (1024'b1 << q3w_idx);
        q3_c3all = q3_c3all + 1;
      end
      if (q3_c5win > 0) begin
        q3_wr5all = q3_wr5all | (1024'b1 << q3w_idx);
        q3_c5all = q3_c5all + 1;
      end
    end
  end

  // [Q3-6] 写进去的【值】: 每个类3读地址上, 写 00/01/10/11 各多少次
  wire [63:0] j6_din;
  integer j6_aw [0:2047];      // 索引 = 地址项*4 + 写入的 2 位值
  integer j6_wv [0:3];         // 全局: 所有写(非 inv)的值分布
  integer j6_wall = 0;
  integer j6_wi, j6_wval, j6_wf, j6_init_i;
  assign j6_din = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_pred_array_din;
  initial begin
    for (j6_init_i = 0; j6_init_i < 2048; j6_init_i = j6_init_i + 1) j6_aw[j6_init_i]=0;
    for (j6_init_i = 0; j6_init_i < 4; j6_init_i = j6_init_i + 1) j6_wv[j6_init_i]=0;
  end

  integer j6_a [0:511], j6_at [0:511], j6_an [0:511], j6_acl [0:511];
  integer j6_ac = 0, j6_aovf = 0;
  integer j6_g [0:4095], j6_gt [0:4095], j6_gn [0:4095];
  integer j6_i2, j6_f, j6_pos2, j6_cls2, j6_a2, j6_ph2, j6_lo;
  integer j6_raddr, j6_roff, j6_rplane;
  reg     j6_same_addr;
  initial begin
    for (j6_i2 = 0; j6_i2 < 512; j6_i2 = j6_i2 + 1) begin
      j6_a[j6_i2]=0; j6_at[j6_i2]=0; j6_an[j6_i2]=0; j6_acl[j6_i2]=0;
    end
    for (j6_i2 = 0; j6_i2 < 4096; j6_i2 = j6_i2 + 1) begin
      j6_g[j6_i2]=0; j6_gt[j6_i2]=0; j6_gn[j6_i2]=0;
    end
  end

  // [Q3-7] 全局写地址表: 类3 的写究竟落到哪个 (word,plane,offset)
  integer j7_a [0:511], j7_n [0:511], j7_c = 0, j7_ovf = 0;
  integer j7_i, j7_f, j7_a2, j7_init;
  initial begin
    for (j7_init = 0; j7_init < 512; j7_init = j7_init + 1) begin j7_a[j7_init]=0; j7_n[j7_init]=0; end
  end

  // [Q3-10] 预测时刻读索引走的是 6 级 mux 里的哪一档
  wire q310_flush, q310_misp, q310_chk, q310_rec, q310_amq, q310_afq;
  assign q310_flush = dut.Core_cpu.u_ifu_subsys.u_ifu_top.rtu_ifu_flush;
  assign q310_misp  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bju_mispred;
  assign q310_chk   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.iu_ifu_bht_check_vld;
  assign q310_rec   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.local_recover_vld;
  assign q310_amq   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.after_bju_mispred_q;
  assign q310_afq   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.after_rtu_ifu_flush_q;
  // 读出的 st_row 到底等不等于"用 vghr_q 按第 6 档公式算出来的"
  // (bht_pred_array_rd_index 是 always@(*) 里的 reg, 分层引用可能不可靠 —— 之前 cur_cur_pc 就栽在这)
  wire [9:0] q310_exprd;
  assign q310_exprd = {j3_h_now[11:8], j3_h_now[7:2] ^ j3_h_now[19:14]};
  integer q310_rowok = 0, q310_rowne = 0;
  integer q310_n [0:6];
  integer q310_j;
  initial for (q310_j = 0; q310_j < 7; q310_j = q310_j + 1) q310_n[q310_j] = 0;

  // ===========================================================================
  // [IC1] Q3-8: 同一条分支 —— 预测级读的地址 vs 提交级写的地址, 配对比较
  //
  // §5.12 已经证明: 类 3 读的 21 个地址收到 0 次写, 且写落在了**同一个 word**
  //   而 plane/offset 不对。要判定这是"打包锁存时机"还是"PC 位约定"的问题,
  //   必须把同一个分支的两个时刻配起来看。
  //
  // 做法: 预测时刻把 (pc[12:0], 读地址) 推进一个 64 项环形表;
  //   写时刻用顶层 `iu_ifu_cur_pc`(它才是可靠的端口, 内部 cur_cur_pc 分层引用读出来是常数)
  //   去表里从最旧开始找同 PC 的项, 比读地址与写地址。
  //   - 命中率接近 0        -> iu_ifu_cur_pc 本身不可信, 本次测量作废
  //   - 命中但 word 不同    -> 索引(GHR)问题
  //   - 命中但 plane/offset 不同 -> 打包锁存时机 / PC 位约定问题
  // ===========================================================================
  localparam Q38_N = 64;
  reg [12:0] q38_pc  [0:Q38_N-1];
  reg [14:0] q38_rd  [0:Q38_N-1];
  reg        q38_vld [0:Q38_N-1];
  reg [21:0] q38_ghr [0:Q38_N-1];
  integer    q38_t   [0:Q38_N-1];
  integer    q38_clk = 0;
  integer    q38_age_hist [0:7];      // 配对年龄直方图
  integer    q38_age_max = 0, q38_skip = 0;
  integer    q38_geq = 0, q38_gne = 0, q38_gsh[0:4];
  integer    q38_gk;
  integer    q38_gx0 = 0, q38_gx1 = 0, q38_gx2 = 0;
  wire [21:0] q38_curghr;
  assign q38_curghr = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.cur_ghr;
  integer    q38_wp = 0;
  integer    q38_i, q38_f, q38_age, q38_best;
  integer    q38_ins = 0, q38_hit = 0, q38_miss = 0;
  integer    q38_eq = 0, q38_wne = 0, q38_pne = 0, q38_one = 0, q38_none = 0;
  integer    q38_i0;
  // 写地址的 PC: 顶层端口, 取 [12:0] 与环里的 pc 同宽比较
  wire [31:0] q38_curpc;
  // 写时刻"到底在写哪条分支"的 PC: 写缓冲非空时写的是【缓冲里那条】(cur_cur_pc=buf_cur_pc),
  // 否则写的是当前 BJU 那条。之前只用 iu_ifu_cur_pc, 于是拿 A 分支的读去比 B 分支的写 —— 这是
  // 配对率恒为 0 的真正原因。buf_cur_pc/not_empty 都是 wire, 分层引用可靠。
  wire [9:0]  q38_bufpc;
  wire        q38_bufne;
  assign q38_bufpc = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.buf_cur_pc;
  assign q38_bufne = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_bht.bht_wr_buf_not_empty;
  wire [12:0] q38_wpc;
  assign q38_wpc = q38_bufne ? {q38_bufpc, 3'b000} : q38_curpc[12:0];
  assign q38_curpc = dut.Core_cpu.u_ifu_subsys.u_ifu_top.iu_ifu_cur_pc;
  integer q38_pcuniq = 0;
  reg [12:0] q38_pcseen = 13'b0;
  integer q38_i1;
  initial begin
    for (q38_i0 = 0; q38_i0 < Q38_N; q38_i0 = q38_i0 + 1) begin
      q38_pc[q38_i0]=0; q38_rd[q38_i0]=0; q38_vld[q38_i0]=0; q38_t[q38_i0]=0; q38_ghr[q38_i0]=0;
    end
    for (q38_i1 = 0; q38_i1 < 8; q38_i1 = q38_i1 + 1) q38_age_hist[q38_i1]=0;
  for (q38_i1 = 0; q38_i1 < 5; q38_i1 = q38_i1 + 1) q38_gsh[q38_i1]=0;
  end

  always @(posedge clk) if (!rst) q38_clk = q38_clk + 1;

  // 预测侧: 把读地址记下来 (类 3 / 类 5 都记; 写侧按 PC 找)
  always @(posedge clk) if (!rst && bench_en && st_ipvld) begin
    if (bench_class(st_pc) == 3 || bench_class(st_pc) == 5) begin
      q38_i = 0;
      // 找一个空槽 (从写指针起找最旧的)
      q38_f = -1;
      for (q38_age = 0; q38_age < Q38_N; q38_age = q38_age + 1) begin
        q38_i = (q38_wp + q38_age) % Q38_N;
        if (!q38_vld[q38_i]) begin q38_f = q38_i; q38_age = Q38_N; end
      end
      if (q38_f < 0) begin q38_f = q38_wp; q38_wp = (q38_wp + 1) % Q38_N; end
      q38_pc [q38_f] = st_pc[12:0];
      q38_rd [q38_f] = st_row*32 + (~st_sel[1])*16 + ((st_oh == 16'h0001) ? 0 :
                       (st_oh == 16'h0002) ? 1 : (st_oh == 16'h0004) ? 2 :
                       (st_oh == 16'h0008) ? 3 : (st_oh == 16'h0010) ? 4 :
                       (st_oh == 16'h0020) ? 5 : (st_oh == 16'h0040) ? 6 :
                       (st_oh == 16'h0080) ? 7 : (st_oh == 16'h0100) ? 8 :
                       (st_oh == 16'h0200) ? 9 : (st_oh == 16'h0400) ? 10 :
                       (st_oh == 16'h0800) ? 11 : (st_oh == 16'h1000) ? 12 :
                       (st_oh == 16'h2000) ? 13 : (st_oh == 16'h4000) ? 14 : 15);
      // [Q3-10] 同时统计读索引 mux 走了哪一档 (与上面对齐, 同一拍)
      if (st_row === q310_exprd) q310_rowok = q310_rowok + 1; else q310_rowne = q310_rowne + 1;
      if      (q310_flush) q310_n[0] = q310_n[0] + 1;
      else if (q310_misp && !q310_chk) q310_n[1] = q310_n[1] + 1;
      else if (q310_misp &&  q310_chk) q310_n[2] = q310_n[2] + 1;
      else if (q310_rec)   q310_n[3] = q310_n[3] + 1;
      else if (q310_amq || q310_afq)  q310_n[4] = q310_n[4] + 1;
      else                            q310_n[5] = q310_n[5] + 1;
      q38_vld[q38_f] = 1'b1;
      q38_t  [q38_f] = q38_clk;
      q38_ghr[q38_f] = j3_h_now;
      q38_ins = q38_ins + 1;
    end
  end

  // ===========================================================================
  // [IC1] Q3-4: 完整计数器地址 (word, plane, offset) 的读/写对账
  //
  // 前面几步已经把范围缩到"读到的计数器卡在 00/01"; 剩下只有两种可能:
  //   (a) 那个地址压根没被写过;
  //   (b) 被写过, 但写进去的值一直是 00/01。
  //   这两者只能靠【完整地址】对账来分开, 只看 word 是分不开的。
  //
  // 地址构成 (rv32_ifu_bht.v, 预阵列是 1024 word x 64bit = 每 word 16 个计数器):
  //   读: word   = bht_pred_array_rd_index[9:0]
  //       offset = 1 在 bht_ipdp_pre_offset_onehot[15:0] 里的位置
  //       plane  = bht_ipdp_sel_array_result[1]
  //   写: word   = bht_pred_array_index[9:0]      (写优先, 非读拍)
  //       field  = bht_wr_buf_pred_updt_sel_b 里那个 0 的位置 (0..31)
  //       offset = field>>1, plane = field&1     (:660-695 的平面交织)
  // 读到的地址进表; 每次写查一次表, 命中就 +1。
  // ===========================================================================
  integer j4_addr [0:255];        // 类3: {word[9:0], plane, offset[3:0]} = 15 bit
  integer j4_nrd  [0:255];        // 该地址被读次数
  integer j4_nwr  [0:255];        // 该地址被写次数
  integer j4_naddr = 0;
  integer j5a_addr [0:255];       // 类5 同表 (对照: 它是能学的那个)
  integer j5a_nrd  [0:255];
  integer j5a_nwr  [0:255];
  integer j5a_naddr = 0;
  integer j4_i, j4_found, j4_a;
  integer j4_ovf = 0, j5a_ovf = 0;
  integer j4_rd_off, j4_rd_addr;
  reg [1:0] j4_rd_plane;
  integer j4_selb, j4_cls;

  initial for (j4_i = 0; j4_i < 256; j4_i = j4_i + 1) begin
    j4_addr[j4_i]=0; j4_nrd[j4_i]=0; j4_nwr[j4_i]=0;
    j5a_addr[j4_i]=0; j5a_nrd[j4_i]=0; j5a_nwr[j4_i]=0;
  end

  // 读地址: 类 3 与类 5 各记一张表
  always @(posedge clk) if (!rst && bench_en && st_ipvld) begin
    j4_cls = bench_class(st_pc);
    if (j4_cls == 3 || j4_cls == 5) begin
      // plane 的口径必须与写侧一致: 64 位 word 里第 f 个 2 位域, f 偶数 = taken 平面,
      // f 奇数 = ntaken 平面 (rv32_ifu_bht.v:659-695)。读侧
      //   bht_selected = sel_result[1] ? taken : ntaken
      // ⇒ f 的奇偶 = !sel_result[1]。
      j4_rd_plane = ~st_sel[1];
      j4_rd_off = 0;
      for (j4_i = 0; j4_i < 16; j4_i = j4_i + 1)
        if (st_oh[j4_i]) j4_rd_off = j4_i;
      j4_rd_addr = (st_row << 5) | (j4_rd_plane << 4) | j4_rd_off;
      if (j4_cls == 3) begin
        j4_found = -1;
        for (j4_i = 0; j4_i < j4_naddr; j4_i = j4_i + 1)
          if (j4_addr[j4_i] == j4_rd_addr) j4_found = j4_i;
        if (j4_found < 0) begin
          if (j4_naddr < 256) begin
            j4_found = j4_naddr; j4_naddr = j4_naddr + 1;
            j4_addr[j4_found] = j4_rd_addr;
          end else j4_ovf = j4_ovf + 1;
        end
        if (j4_found >= 0) j4_nrd[j4_found] = j4_nrd[j4_found] + 1;
      end else begin
        j4_found = -1;
        for (j4_i = 0; j4_i < j5a_naddr; j4_i = j4_i + 1)
          if (j5a_addr[j4_i] == j4_rd_addr) j4_found = j4_i;
        if (j4_found < 0) begin
          if (j5a_naddr < 256) begin
            j4_found = j5a_naddr; j5a_naddr = j5a_naddr + 1;
            j5a_addr[j4_found] = j4_rd_addr;
          end else j5a_ovf = j5a_ovf + 1;
        end
        if (j4_found >= 0) j5a_nrd[j4_found] = j5a_nrd[j4_found] + 1;
      end
    end
  end

  // 写地址: 预测阵列的真实写 (非 inv), 同时对两张表查
  always @(posedge clk) if (!rst && bench_en && !q3w_inv) begin
    // cen_b=0 才是 SRAM 真使能; 否则地址 mux 走的是读索引, 会把读地址当成写地址
    if ((|(~q3w_wen)) && !q3w_cen_b) begin
      j4_selb = -1;
      for (j4_i = 0; j4_i < 32; j4_i = j4_i + 1)
        if (!q3w_wen[j4_i]) j4_selb = j4_i;
      if (j4_selb >= 0) begin
        j4_a = q3w_idx*32 + (j4_selb & 1)*16 + (j4_selb >> 1);
        for (j4_i = 0; j4_i < j4_naddr; j4_i = j4_i + 1)
          if (j4_addr[j4_i] == j4_a) j4_nwr[j4_i] = j4_nwr[j4_i] + 1;
        for (j4_i = 0; j4_i < j5a_naddr; j4_i = j4_i + 1)
          if (j5a_addr[j4_i] == j4_a) j5a_nwr[j4_i] = j5a_nwr[j4_i] + 1;
        // [Q3-6] 这次写进去的值 (第 j4_selb 个 2 位域)
        // [Q3-8] 与预测级配对
        q38_best = -1;
        for (q38_i = 0; q38_i < Q38_N; q38_i = q38_i + 1)
          if (q38_vld[q38_i] && q38_pc[q38_i] == q38_wpc) begin
            if (q38_best >= 0) q38_skip = q38_skip + 1;
            if (q38_best < 0 || q38_t[q38_i] > q38_t[q38_best]) q38_best = q38_i;
          end
        if (q38_best < 0) q38_miss = q38_miss + 1;
        else begin
          q38_hit = q38_hit + 1;
          q38_age = q38_clk - q38_t[q38_best];
          if (q38_age > q38_age_max) q38_age_max = q38_age;
          if (q38_age < 8) q38_age_hist[q38_age] = q38_age_hist[q38_age] + 1;
          q38_vld[q38_best] = 1'b0;
          q38_pcseen = q38_pcseen | q38_pc[q38_best];
          if (q38_rd[q38_best] == j4_a) q38_eq = q38_eq + 1;
          else begin
            if ((q38_rd[q38_best]/32)   != (j4_a/32))   q38_wne = q38_wne + 1;
            if (((q38_rd[q38_best]/16)%2) != ((j4_a/16)%2)) q38_pne = q38_pne + 1;
            if ((q38_rd[q38_best]%16)   != (j4_a%16))   q38_one = q38_one + 1;
          end
          // [Q3-9] 随包 GHR 与预测时刻 GHR 比: 相等? 还是差若干次移位?
          if (q38_curghr === q38_ghr[q38_best]) q38_geq = q38_geq + 1;
          else begin
            q38_gne = q38_gne + 1;
            for (q38_gk = 1; q38_gk <= 4; q38_gk = q38_gk + 1)
              if ((q38_curghr >> q38_gk) == (q38_ghr[q38_best] >> q38_gk))
                q38_gsh[q38_gk] = q38_gsh[q38_gk] + 1;
            if (q38_ghr[q38_best][7:0] == q38_curghr[7:0]) q38_gx0 = q38_gx0 + 1;
            if (q38_ghr[q38_best][7:0] == q38_curghr[8:1]) q38_gx1 = q38_gx1 + 1;
            if (q38_ghr[q38_best][7:0] == q38_curghr[9:2]) q38_gx2 = q38_gx2 + 1;
          end
        end
        j7_a2 = j4_a;
        j7_f = -1;
        for (j7_i = 0; j7_i < j7_c; j7_i = j7_i + 1)
          if (j7_a[j7_i] == j7_a2) j7_f = j7_i;
        if (j7_f < 0) begin
          if (j7_c < 512) begin j7_f = j7_c; j7_c = j7_c + 1; j7_a[j7_f] = j7_a2; end
          else j7_ovf = j7_ovf + 1;
        end
        if (j7_f >= 0) j7_n[j7_f] = j7_n[j7_f] + 1;
        j6_wf   = j4_selb;
        j6_wval = (j6_din >> (2*j6_wf)) & 64'h3;
        j6_wall = j6_wall + 1;
        if (j6_wval < 4) j6_wv[j6_wval] = j6_wv[j6_wval] + 1;
        for (j6_wi = 0; j6_wi < j6_ac; j6_wi = j6_wi + 1)
          if (j6_acl[j6_wi] == 3 && j6_a[j6_wi] == j4_a)
            if (j6_wval < 4) j6_aw[j6_wi*4+j6_wval] = j6_aw[j6_wi*4+j6_wval] + 1;
      end
    end
  end

  // ===========================================================================
  // [IC1] Q3-5: 相位可分性 —— 把"按相位分堆"从【比凸包】升级成【比分布】
  //
  // §5.8/§5.9 用的是 or/and 夹逼, 那只比较取值范围(凸包), 不比较分布 ——
  //   两个相位的取值范围一样但分布完全不同时, 那个测法给不出结论
  //   (类 5 就是这样被判成"无相位信息"的, 结论不可信)。
  // 这里改成直方图, 并直接回答真正要问的那个问题:
  //   【预测器看到的那个"计数器地址"在相位之间分不分得开?】
  //     - 地址在相位间分得开 -> 两个相位用不同的计数器, 交替序列可学;
  //     - 地址混在一起     -> 同一个计数器看到 50/50, 上限就是 50%。
  // 地址编码: {cls(1), word(10), plane(1), offset(4)} 共 16 位, 两类共用一张表,
  //   用最高位分开, 这样"类 3 的地址"和"类 5 的地址"不会互相污染。
  // 同时按 GHR 低 8 位也建一张直方图, 作为"地址分不开是不是因为 GHR 就分不开"的对照。
  // ===========================================================================

  always @(posedge clk) if (!rst && bench_en && st_ipvld) begin
    j6_cls2 = bench_class(st_pc);
    if (j6_cls2 == 3 || j6_cls2 == 5) begin
      j6_pos2 = ((st_pc - ((j6_cls2 == 3) ? 32'h0000_01c0 : 32'h0000_0290)) >> 4) & 15;
      // 相位: 类3 = 进入类3区间的轮次奇偶; 类5 = 轮次 mod 4 是否为 3
      if (j6_cls2 == 3) j6_ph2 = ((jround3 & 1) == 0);
      else               j6_ph2 = ((jround5 & 3) != 3);
      // 地址 (与 Q3-4 同口径: plane = !sel_result[1])
      j6_roff = 0;
      for (j6_i2 = 0; j6_i2 < 16; j6_i2 = j6_i2 + 1)
        if (st_oh[j6_i2]) j6_roff = j6_i2;
      j6_rplane = ~st_sel[1];
      // 全用 integer 算术, 避免 16 bit 字面量/位宽截断导致的符号扩展
      j6_raddr = ((j6_cls2 == 5) ? 32768 : 0) + st_row*32 + j6_rplane*16 + j6_roff;
      j6_f = -1;
      for (j6_i2 = 0; j6_i2 < j6_ac; j6_i2 = j6_i2 + 1)
        if (j6_a[j6_i2] == j6_raddr) j6_f = j6_i2;
      if (j6_f < 0) begin
        if (j6_ac < 512) begin
          j6_f = j6_ac; j6_ac = j6_ac + 1; j6_a[j6_f] = j6_raddr;
          j6_acl[j6_f] = j6_cls2;
        end else j6_aovf = j6_aovf + 1;
      end
      if (j6_f >= 0) begin
        if (j6_ph2) j6_at[j6_f] = j6_at[j6_f] + 1;
        else        j6_an[j6_f] = j6_an[j6_f] + 1;
      end
      // GHR 低 8 位的直方图
      j6_lo = {18'b0, j3_h_now[7:0]};
      j6_i2 = ((j6_cls2 == 5) ? 2048 : 0) + (j6_pos2 - 1)*256 + j6_lo;
      j6_g[j6_i2] = j6_g[j6_i2] + 1;
      if (j6_ph2) j6_gt[j6_i2] = j6_gt[j6_i2] + 1;
      else        j6_gn[j6_i2] = j6_gn[j6_i2] + 1;
    end
  end

  // ===========================================================================
  // [IC1] Q5: L0 BTB 的【训练质量】—— entry_rd_hit 与 eligible 分开数
  //
  // bp_change_log §4.1 那个实验 (当时没做): 这两个 popcount 分开之后,
  //   "PC 压根不在表里" (rd_hit=0) 与 "在表里但没武装" (rd_hit>0 且 eligible 全 0)
  //   才能分开看。rv32_ifu_l0_btb.v:223-227:
  //     entry_rd_hit = entry_vld & (entry_src[31:4] == lookup_pc[31:4])
  //     eligible     = lookup_en & entry_rd_hit & !inv & (src[3:2]>=pc[3:2]) & entry_cnt & ...
  //   所以 eligible ⊆ rd_hit, 差额就是"槽位/武装"淘汰掉的部分。
  //   不要再用 entry_cnt 的 popcount 当依据 (删项时不清零, 见 §4.3)。
  // ===========================================================================
  wire [15:0] q5_rdhit, q5_elig;
  assign q5_rdhit = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.entry_rd_hit;
  assign q5_elig  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.eligible;
  integer q5_lookn = 0, q5_rd_sum = 0, q5_el_sum = 0;
  integer q5_rd0 = 0, q5_el0 = 0, q5_noarm = 0, q5_slotmiss = 0;
  always @(posedge clk) if (!rst && bench_en) begin
    if (l0_lookup_en) begin
      q5_lookn = q5_lookn + 1;
      q5_rd_sum = q5_rd_sum + $countones(q5_rdhit);
      q5_el_sum = q5_el_sum + $countones(q5_elig);
      if ($countones(q5_rdhit) == 0) q5_rd0 = q5_rd0 + 1;
      if ($countones(q5_elig)  == 0) q5_el0 = q5_el0 + 1;
      if ($countones(q5_rdhit) > 0 && $countones(q5_elig) == 0) q5_noarm  = q5_noarm  + 1;
    end
  end
  always @(posedge clk) if (!rst && bench_en) begin
    if (l0_lookup_en && $countones(q5_rdhit) > 0 && $countones(q5_elig) == 0)
      if (!(|(q5_rdhit & q5_elig))) q5_slotmiss = q5_slotmiss + 1;
  end

  // ===========================================================================
  // [IC1] Q4: L1 BTB miss 与取指气泡的关联
  //
  // 直接量"没有 LBUF 的代价"的第二步: 把 L1 BTB 关掉 (force cp0_ifu_btb_en=0),
  //   同样的 branch_bench 再跑一遍, 周期数差值就是大 BTB 的整体贡献;
  //   配合 +BENCH 的分类准确率, 还能看出它影响的是"方向"还是"目标"。
  //   force 的是 u_ifu_top 的输入端口 (ifu_subsys.v:103 处接常量 1'b1), 只观测。
  // ===========================================================================
  // 【2026-09-24 更正】下面这条"entry_update_en 把 L1 开关串进 L0 武装"的旧解释是错的:
  // rv32_ifu_l0_btb_entry.v:76 里那个叫 cp0_ifu_btb_en 的**端口**, 在唯一例化处
  // (rv32_ifu_l0_btb.v:249) 接的是 L0 自己的 enable(= cp0_ifu_l0btb_en),
  // L1 的开关到不了写使能。实测: +NOBTB 下 L0 分配 11,299 -> 22,189 (翻倍, 不是归零)。
  // 真机制是 rv32_ifu_top.v:597  training_ready = !cp0_ifu_btb_en || btb_update_ready
  //   —— **L1 的 ready 兼作训练总线的节流阀**: 抽掉它, 训练事件翻倍, BHT 被污染
  //   (class5 89.31% -> 74.32%, 约等于恒 taken 的 75% 偏置基线)。
  // ⇒ 这一行仍然是脏的, 不能用来判 L1 的价值; 但换 L1 尺寸请用 BP_BTB_ROW_W
  //   (纯表尺寸, 实测 16 行 +0.008%), 不要用 +NOBTB。
  // ⇒ 另外: **整删 L1 或抽掉它的 ready 会掉进这个区间**, 所以 L1 不能整删。
  //   (旧注释误以为"要单独看 L1 的效果就得加一个只关 L0 的开关" —— 不需要, 用 BP_BTB_ROW_W。)
  logic nobtb = 0;
  initial if ($test$plusargs("NOBTB")) nobtb = 1;
  initial if ($test$plusargs("NOBTB"))
    force dut.Core_cpu.u_ifu_subsys.u_ifu_top.cp0_ifu_btb_en = 1'b0;
  logic nol0 = 0;
  initial if ($test$plusargs("NOL0")) nol0 = 1;
  initial if ($test$plusargs("NOL0"))
    force dut.Core_cpu.u_ifu_subsys.u_ifu_top.cp0_ifu_l0btb_en = 1'b0;

  // 前端的 L1 BTB 相关阻塞拍: "核在等, IFU 没货" 且 L1 BTB 这一拍拒绝查询
  integer q4_nofetch = 0, q4_nf_btblk = 0;
  wire c_flush_x = dut.Core_cpu.flush_if_id | dut.Core_cpu.ifu_idu_flush;
  wire c_stall_x = dut.Core_cpu.stall;
  always @(posedge clk) if (!rst) begin
    if (!dut.Core_cpu.if_accept && dut.Core_cpu.ifu_init_done
        && !c_flush_x && !c_stall_x) begin
      q4_nofetch = q4_nofetch + 1;
      if (bt_lookup_vld && !btw_rdy) q4_nf_btblk = q4_nf_btblk + 1;
    end
  end

  always @(posedge clk) if (!rst && bench_en) begin
    if (dbg_vghr !== 22'b0)  dbg_nz    <= dbg_nz + 1;
    if (dbg_vghr !== dbg_prev) dbg_chg <= dbg_chg + 1;
    if (dbg_vghr_ip !== dbg_vghr) dbg_ipdiff <= dbg_ipdiff + 1;
    if (dbg_vghr_ofs !== 4'b0) dbg_ofsnz <= dbg_ofsnz + 1;
    if (dbg_taken_v !== 32'b0)  dbg_tkn_nz <= dbg_tkn_nz + 1;
    if (dbg_ntake_v !== 32'b0)  dbg_ntk_nz <= dbg_ntk_nz + 1;
    if (dbg_selr[1])            dbg_selr1  <= dbg_selr1  + 1;
    if (dbg_sel_has2)           dbg_has2   <= dbg_has2   + 1;
    if (dbg_cnt[1])             dbg_cnt1   <= dbg_cnt1   + 1;
    if (dbg_ghr_iu)   dbg_n_iu   <= dbg_n_iu   + 1;
    if (dbg_ghr_lbuf) dbg_n_lbuf <= dbg_n_lbuf + 1;
    if (dbg_ghr_ip)   dbg_n_ip   <= dbg_n_ip   + 1;
    if (dbg_lbuf_act) dbg_n_lact <= dbg_n_lact + 1;
    if (dbg_ip_conbr) dbg_n_icb  <= dbg_n_icb  + 1;
    if (dbg_bju_chk)  dbg_n_bchk <= dbg_n_bchk + 1;
    if (dbg_unlock) dbg_n_unlock <= dbg_n_unlock + 1;
    if (dbg_unl_t)  dbg_n_unl_t  <= dbg_n_unl_t  + 1;
    if (dbg_ev && dbg_ev_q)   dbg_ev2      <= dbg_ev2 + 1;
    if (dbg_ev && !dbg_ev_q)  dbg_ev_nochk <= dbg_ev_nochk + 1;
    if (dbg_chk && !dbg_ev)   dbg_chk_noev <= dbg_chk_noev + 1;
    dbg_ev_q  <= dbg_ev;
    dbg_chk_q <= dbg_chk;
    dbg_gh_q  <= dbg_vghr[3:0];
    if (dbg_vghr[3:0] == 4'h0)      dbg_gh0  <= dbg_gh0  + 1;
    else if (dbg_vghr[3:0] == 4'hF) dbg_gh15 <= dbg_gh15 + 1;
    else                            dbg_gh_mid <= dbg_gh_mid + 1;
    if (bench_class(dut.Core_cpu.pc_EX) == 3 && dbg_offs_acc != 16'hFFFF)
      dbg_offs_acc <= dbg_offs_acc | (16'h0001 << dbg_vghr[3:0]);
    dbg_prev <= dbg_vghr;
  end

  assign l0_lookup_en   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.lookup_en;
  assign l0_hit_w       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.hit;
  assign l0_hit_type    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.hit_type;
  assign l0_hit_type1   = (l0_hit_type == 3'd1);   // 条件分支
  assign l0_hit_type2   = (l0_hit_type == 3'd2);   // jal
  assign l0_hit_type3   = (l0_hit_type == 3'd3);   // jalr
  assign l0_upd_en      = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.update_en;
  assign l0_upd_match   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.update_match;
  assign l0_alloc       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.alloc_vld;
  assign l0_kill        = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.update_kill;
  assign l0_hold        = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.update_hold;
  assign l0_fire        = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.update_fire;
  assign l0_vld_v       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.entry_vld;
  assign l0_cnt_v       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.entry_cnt;
  assign top_l0_hit     = dut.Core_cpu.u_ifu_subsys.u_ifu_top.l0_hit;
  assign top_l0_inv     = dut.Core_cpu.u_ifu_subsys.u_ifu_top.l0_invalidate;
  assign top_l0_invmask = dut.Core_cpu.u_ifu_subsys.u_ifu_top.l0_invalidate_mask;
  // 注意: pcgen_l0_btb_chgflw_vld 是"通用的取指改向" (含 ipctrl/ibctrl 各路),
  // 不是 L0 专用 —— 实测 beq 上 L0 命中 0 次它却有 28 次. L0 真正改向要看
  // ifctrl 的 accept, 以及 IF→IP 传下去的 ifdp_ipdp_l0_hit.
  assign top_l0_redir   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.ifctrl_l0_btb_accept;
  assign top_train_v    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.train_valid;
  assign top_train_t    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.train_taken;
  assign top_train_type = dut.Core_cpu.u_ifu_subsys.u_ifu_top.train_type;

  integer l0_lk = 0, l0_hitn = 0, l0_hc = 0, l0_hj = 0, l0_hjr = 0;
  integer l0_redirn = 0, l0_invn = 0, l0_inv_entries = 0, l0_ipn = 0;
  integer tr_v = 0, tr_tk = 0, tr_nt = 0, tr_c = 0, tr_j = 0, tr_jr = 0;
  integer l0_updn = 0, l0_mtchn = 0, l0_allocn = 0, l0_killn = 0, l0_holdn = 0;
  integer l0_sum_vld = 0, l0_sum_cnt = 0, l0_firen = 0;
  integer l0_alloc_t = 0, l0_alloc_n = 0, b_armed0 = 0, b_partial = 0, b_consume = 0;

  // L0 判决点 (ipctrl): 把一个 L0 命中事件分成 方向错 / 目标存错 / 类型错 / 正确.
  // 这是"update 逻辑写错了目标" 与 "taken 位粘滞" 的分水岭 ——
  // l0_correct 要求 {slot, type, 包内预测位=1, 包内 npc == L0 target} 全中.
  wire        ipc_ev;             // L0 命中且该分支本拍派发 (事件脉冲)
  wire        ipc_dir, ipc_tgt, ipc_typ;
  wire [191:0] ipc_lastpkt;
  wire [ 3:0] ipc_lastidx;
  wire [ 1:0] ipc_l0slot;         // [2026-09-25] 原先漏声明 ⇒ 隐式 1 bit 网,
                                  // 复算里 slot 比较只用到 slot[0], 于是本项
                                  // "不符拍数" 恒为大数, 自检失效 (详见下方注释)
  wire [31:0] ipc_l0target;
  wire [ 2:0] ipc_l0type;

  assign ipc_lastpkt  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.last_packet;
  assign ipc_lastidx  = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.last_index;
  assign ipc_l0slot   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.pipe_ifdp_ipdp_l0_slot;
  assign ipc_l0type   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.pipe_ifdp_ipdp_l0_type;
  assign ipc_l0target = dut.Core_cpu.u_ifu_subsys.u_ifu_top.pipe_ifdp_ipdp_l0_target;
  assign ipc_ev       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.fragment_fire
                      & dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.reaches_l0
                      & dut.Core_cpu.u_ifu_subsys.u_ifu_top.pipe_ifdp_ipdp_l0_hit;
  // 按 RTL 逐项复算 l0_correct, 与内部结果逐拍比对 (分层引用可信度自检)
  wire ipc_hit_x = dut.Core_cpu.u_ifu_subsys.u_ifu_top.pipe_ifdp_ipdp_l0_hit;
  wire ipc_mine  = ipc_hit_x
                 & (dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.last_index == ipc_l0slot)
                 & (dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.last_packet[108:106] == ipc_l0type)
                 &  dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.last_packet[122]
                 & (dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.last_packet[95:64] == ipc_l0target);
  wire ipc_corr_x = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.l0_correct;
  assign ipc_dir = ipc_ev & ~ipc_lastpkt[122];                 // 包内方向预测说不跳
  // [2026-09-25 更正] 原注释说"刻意不做 slot 比较, 因为 ipctrl 的 slot 端口
  // 经分层引用读出来像只取低位"。查明真因是 TB 侧 `ipc_l0slot` 漏了声明:
  // 隐式网是 1 bit, `last_index == ipc_l0slot` 实际只比了 slot[0], 所以看起来
  // "恒差 2"。补上 `wire [1:0] ipc_l0slot` 后, 下面 ipc_mine 与 RTL 的 l0_correct
  // 是同一个表达式, "不符拍数" 应当精确为 0 —— 那才是这个自检该有的样子。
  // (三桶之和 = 有命中的 invalidate 数这一条本来就不依赖 slot, 不受影响。)
  assign ipc_typ = ipc_ev & ipc_lastpkt[122]
                 & (ipc_lastpkt[108:106] != ipc_l0type);       // 方向对, 类型不符
  assign ipc_tgt = ipc_ev & ipc_lastpkt[122] & (ipc_lastpkt[108:106] == ipc_l0type)
                 & (ipc_lastpkt[95:64] != ipc_l0target);       // 方向类型都对, 目标不符

  // ---------------------------------------------------------------------------
  // 更新/查找 的选择优先级一致性检查
  //
  // u_l0 里两者用的是不同规则:
  //   update_select[entry] = match && !(|(match & HIGHER_ENTRIES))  -> 同 PC 取【最高】编号
  //   hit_select[entry]    = cand  && !(|(cand  & LOWER_ENTRIES))   -> 命中取【最低】编号
  // C910 不存在这种不对称: 它把命中 one-hot 随包一路带到 addrgen, 再原样送回当更新目标
  // (ct_ifu_addrgen.v:302), L0 内部不做任何仲裁. 只要一个 PC 在表里唯一, 两条规则
  // 结果相同; 出现同 PC 重复项时才会分叉 —— 所以先量"同 PC 重复项到底会不会出现".
  // ---------------------------------------------------------------------------
  wire [15:0] l0_matchvec;
  wire [15:0] l0_updsel;
  wire [ 3:0] l0_hitidx;
  wire [31:0] l0_lookpc, l0_updpc;
  assign l0_matchvec = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.update_match_vec;
  assign l0_updsel   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.update_select;
  assign l0_hitidx   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top.u_l0.hit_payload[42:39];
  assign l0_lookpc   = dut.Core_cpu.u_ifu_subsys.u_ifu_top.ifdp_l0_btb_pc;  // 顶层网, 不用输入端口
  assign l0_updpc    = dut.Core_cpu.u_ifu_subsys.u_ifu_top.train_pc;

  reg [3:0]  lut_idx_q;
  reg [31:0] lut_pc_q;
  reg        lut_vld_q;
  integer b_mm = 0, b_mm_fire = 0, b_mm1 = 0, b_disagree = 0;

  integer ev_l0 = 0, ev_dir = 0, ev_tgt = 0, ev_typ = 0;
  integer ev_inv_echo = 0, b_corr_mismatch = 0;
  wire ipc_inv_echo = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.fragment_fire
                    & dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.reaches_l0
                    & ~dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ipctrl.l0_correct;

  // ibctrl 的 fragment 推进: consume_count 会不会小于 fragment 总拍数 (会的话
  // accepted[lane]=lane<consume_count 的静态 lane 语义就会重复/漏训)
  wire        ibc_consume;
  wire [ 2:0] ibc_consume_count, ibc_count_q;
  assign ibc_consume       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ibctrl.consume;
  assign ibc_consume_count = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ibctrl.consume_count;
  assign ibc_count_q       = dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_pipeline.u_ibctrl.count_q;

  // 气泡拆解: 优先级 [init > 冲刷 > 核内停顿 > IFU 没货]; 另存未加优先级的原始计
  // 数, 便于核对 (每拍可以有多个原因).
  integer b_accept = 0, b_init = 0, b_flush = 0, b_stall = 0, b_nofetch = 0;
  integer b_raw_init = 0, b_raw_stall = 0, b_raw_flush = 0, b_raw_iflush = 0,
          b_raw_novld = 0, b_raw_div = 0, b_raw_mul = 0, b_raw_loaduse = 0;
  integer b_nf_reissue = 0, b_nf_bpread = 0, b_nf_frontend = 0, b_nf_other = 0;


  wire c_flush = dut.Core_cpu.flush_if_id | dut.Core_cpu.ifu_idu_flush;
  wire c_stall = dut.Core_cpu.stall;

  // ---- 「其它」桶归因: 改向/失效/冲刷事件后, 等 IFU 重新吐出指令(out_count>0)的拍数 ----
  // 判据: rf_in_bucket 若 ≈ b_nf_other, 说明这 8.5% 主要来自"改向后重填",
  //       而不是前端稳态吞吐不够 (量级: L0 全程接受改向 ~1.0M 次 ⇒ 每 ~10 拍一次).
  integer rf_redir = 0, rf_inval = 0, rf_flush = 0, rf_ev = 0, rf_wait = 0, rf_in_bucket = 0;
  integer rf_ev_redir_c = 0, rf_ev_inval_c = 0, rf_ev_flush_c = 0;
  reg         rf_armed = 1'b0;
  reg  [1:0]  rf_src   = 2'd0;
  wire rf_ev_redir = dut.Core_cpu.u_ifu_subsys.u_ifu_top.ifctrl_l0_btb_accept;
  wire rf_ev_inval = dut.Core_cpu.u_ifu_subsys.u_ifu_top.l0_invalidate;
  wire rf_ev_flush = c_flush;
  wire rf_ev_any   = rf_ev_redir | rf_ev_inval | rf_ev_flush;
  wire rf_has_inst = dut.Core_cpu.u_ifu_subsys.u_ifu_top.out_count != 2'b0;
  wire rf_in_nf    = !dut.Core_cpu.if_accept && dut.Core_cpu.ifu_init_done && !c_flush && !c_stall;

  always @(posedge clk) if (!rst) begin
    // ---- 气泡, 按优先级划分 (互斥, 合计 = !if_accept 拍数) ----
    if (dut.Core_cpu.if_accept)                       b_accept  <= b_accept  + 1;
    else if (!dut.Core_cpu.ifu_init_done)             b_init    <= b_init    + 1;
    else if (c_flush)                                 b_flush   <= b_flush   + 1;
    else if (c_stall)                                 b_stall   <= b_stall   + 1;
    else                                              b_nofetch <= b_nofetch + 1;
    // ---- 原始计数 (不互斥), 自检用 ----
    if (!dut.Core_cpu.ifu_init_done)  b_raw_init   <= b_raw_init   + 1;
    if (dut.Core_cpu.stall)           b_raw_stall  <= b_raw_stall  + 1;
    if (dut.Core_cpu.div_stall)       b_raw_div    <= b_raw_div    + 1;
    if (dut.Core_cpu.mul_stall)       b_raw_mul    <= b_raw_mul    + 1;
    if (dut.Core_cpu.stall & ~dut.Core_cpu.div_stall & ~dut.Core_cpu.mul_stall)
                                      b_raw_loaduse<= b_raw_loaduse+ 1;
    if (dut.Core_cpu.flush_if_id)     b_raw_flush  <= b_raw_flush  + 1;
    if (dut.Core_cpu.ifu_idu_flush)   b_raw_iflush <= b_raw_iflush + 1;
    if (!dut.Core_cpu.ifu_inst0_vld)  b_raw_novld  <= b_raw_novld  + 1;
    // ---- 没货时 IFU 在干什么 ----
    if (!dut.Core_cpu.if_accept && dut.Core_cpu.ifu_init_done && !c_flush && !c_stall) begin
      if (dut.Core_cpu.u_ifu_subsys.u_ifu_top.reissue)                b_nf_reissue  <= b_nf_reissue  + 1;
      else if (dut.Core_cpu.u_ifu_subsys.u_ifu_top.bp_read_stall)     b_nf_bpread   <= b_nf_bpread   + 1;
      else if (dut.Core_cpu.u_ifu_subsys.u_ifu_top.if_frontend_stall) b_nf_frontend <= b_nf_frontend + 1;
      else                                                            b_nf_other    <= b_nf_other    + 1;
    end
    // ---- 改向后重填等待: 与上面的桶不互斥, 只做归因 ----
    if (rf_ev_any) begin
      rf_ev    <= rf_ev + 1;
      if (rf_ev_redir) rf_ev_redir_c <= rf_ev_redir_c + 1;
      if (rf_ev_inval) rf_ev_inval_c <= rf_ev_inval_c + 1;
      if (rf_ev_flush) rf_ev_flush_c <= rf_ev_flush_c + 1;
      rf_armed <= 1'b1;
      rf_src   <= rf_ev_redir ? 2'd1 : (rf_ev_inval ? 2'd2 : 2'd3);
    end else if (rf_armed && rf_has_inst) begin
      rf_armed <= 1'b0;
    end
    if (rf_armed && !rf_has_inst && !rf_ev_any) begin
      rf_wait <= rf_wait + 1;
      if      (rf_src == 2'd1) rf_redir <= rf_redir + 1;
      else if (rf_src == 2'd2) rf_inval <= rf_inval + 1;
      else                     rf_flush <= rf_flush + 1;
      if (rf_in_nf)            rf_in_bucket <= rf_in_bucket + 1;
    end
    // ---- L0 BTB ----
    if (l0_lookup_en) l0_lk <= l0_lk + 1;
    if (l0_hit_w) begin
      l0_hitn <= l0_hitn + 1;
      if (l0_hit_type1) l0_hc  <= l0_hc  + 1;
      if (l0_hit_type2) l0_hj  <= l0_hj  + 1;
      if (l0_hit_type3) l0_hjr <= l0_hjr + 1;
    end
    if (top_l0_redir) l0_redirn <= l0_redirn + 1;
    if (dut.Core_cpu.u_ifu_subsys.u_ifu_top.ifdp_ipdp_l0_hit) l0_ipn <= l0_ipn + 1;
    if (top_l0_inv) begin
      l0_invn         <= l0_invn + 1;
      l0_inv_entries  <= l0_inv_entries + $countones(top_l0_invmask);
    end
    if (top_train_v) begin
      tr_v <= tr_v + 1;
      if (top_train_t) tr_tk <= tr_tk + 1; else tr_nt <= tr_nt + 1;
      if (top_train_type == 3'd1) tr_c  <= tr_c  + 1;
      if (top_train_type == 3'd2) tr_j  <= tr_j  + 1;
      if (top_train_type == 3'd3) tr_jr <= tr_jr + 1;
    end
    if (l0_upd_en) begin
      l0_updn <= l0_updn + 1;
      if (l0_upd_match) l0_mtchn <= l0_mtchn + 1;
    end
    if (l0_alloc) begin
      l0_allocn <= l0_allocn + 1;
      if (top_train_t) l0_alloc_t <= l0_alloc_t + 1;   // 预测 taken 时的分配
      else             l0_alloc_n <= l0_alloc_n + 1;   // 预测 not-taken 时的分配
    end
    if (l0_cnt_v == 16'b0) b_armed0 <= b_armed0 + 1;
    // 同 PC 重复项: 更新时匹配到 >=2 条 (这正是"取最高/最低"会分叉的前提)
    // 自检: matchvec 读出来可信吗? ==1 的拍数应当约等于 "命中已有条目" 的次数
    if ($countones(l0_matchvec) == 1) b_mm1 <= b_mm1 + 1;
    if ($countones(l0_matchvec) >= 2) begin
      b_mm <= b_mm + 1;
      if (l0_fire) b_mm_fire <= b_mm_fire + 1;   // 真发生写入且选择有意义
    end
    if (l0_lookup_en & l0_hit_w) begin
      lut_idx_q <= l0_hitidx;
      lut_pc_q  <= l0_lookpc;
      lut_vld_q <= 1'b1;
    end
    // 更新的选中项 ≠ 最近一次同 PC 查找的命中项
    if (l0_upd_en & lut_vld_q & (l0_updpc == lut_pc_q) &
        (l0_updsel != (16'b1 << lut_idx_q))) b_disagree <= b_disagree + 1;
    if (ipc_inv_echo) ev_inv_echo <= ev_inv_echo + 1;
    if (ipc_mine !== ipc_corr_x) b_corr_mismatch <= b_corr_mismatch + 1;
    if (ipc_ev) begin
      ev_l0 <= ev_l0 + 1;
      if (ipc_dir) ev_dir <= ev_dir + 1;
      if (ipc_tgt) ev_tgt <= ev_tgt + 1;
      if (ipc_typ) ev_typ <= ev_typ + 1;
    end
    if (ibc_consume) begin
      b_consume <= b_consume + 1;
      if (ibc_consume_count != ibc_count_q) b_partial <= b_partial + 1;  // fragment 分拍推进
    end
    if (l0_kill)  l0_killn  <= l0_killn  + 1;
    if (l0_hold)  l0_holdn  <= l0_holdn  + 1;
    if (l0_fire)  l0_firen <= l0_firen  + 1;
    l0_sum_vld <= l0_sum_vld + $countones(l0_vld_v);
    l0_sum_cnt <= l0_sum_cnt + $countones(l0_cnt_v);
  end

  task automatic report_l0_stats();
    integer div_c;
    begin
      div_c = (cycles > 0) ? cycles : 1;
      $display("");
      $display("================ L0 BTB 统计 ================");
      $display("lookup (IF 级查询)            : %0d", l0_lk);
      $display("  命中 (CAM hit)              : %0d (%0.2f%% 查询命中率)",
               l0_hitn, l0_lk ? 100.0*l0_hitn/l0_lk : 0.0);
      $display("  命中类型 条件/jal/jalr      : %0d / %0d / %0d", l0_hc, l0_hj, l0_hjr);
      $display("IF 级接受并改向 (accept)      : %0d", l0_redirn);
      $display("IF→IP 传下去的 L0 命中        : %0d", l0_ipn);
      $display("IP 级判 L0 预测错 (invalidate): %0d   <-- 白取一整趟", l0_invn);
      $display("  L0 判决事件总数             : %0d", ev_l0);
      $display("    方向错 (包内预测位=不跳)  : %0d  <-- taken 位粘滞", ev_dir);
      $display("    目标存错 (方向/类型都对)  : %0d  <-- update 写错 target", ev_tgt);
      $display("    类型错                    : %0d", ev_typ);
      $display("    三桶合计 = %0d, 无命中的 invalidate = %0d (应当相等)",
               ev_dir+ev_tgt+ev_typ, l0_invn - (ev_dir+ev_tgt+ev_typ));
      $display("  对账: TB 复算 fragment_fire&reaches_l0&!l0_correct = %0d (顶层 l0_invalidate %0d)",
               ev_inv_echo, l0_invn);
      $display("  对账: TB 复算 l0_correct 与内部不符的拍数 = %0d", b_corr_mismatch);
      $display("  被删条目数 (mask popcount)  : %0d  (平均 %0.2f 条/次)",
               l0_inv_entries, l0_invn ? 1.0*l0_inv_entries/l0_invn : 0.0);
      $display("表内平均有效/武装条目         : %0.2f / %0.2f  (共 16)",
               1.0*l0_sum_vld/div_c, 1.0*l0_sum_cnt/div_c);
      $display("武装条目为 0 的拍数           : %0d (%0.2f%%)  <-- 此时 L0 必然不命中",
               b_armed0, 100.0*b_armed0/div_c);
      $display("fragment 分拍推进 (consume_count<count_q): %0d / %0d 次 consume",
               b_partial, b_consume);
      $display("--- 训练 (ibctrl → L0 update) ---");
      $display("train_valid                   : %0d", tr_v);
      $display("  条件/jal/jalr               : %0d / %0d / %0d", tr_c, tr_j, tr_jr);
      $display("  update_taken=1 (武装/填写)  : %0d", tr_tk);
      $display("  update_taken=0 (删项/保持)  : %0d", tr_nt);
      $display("update_en (过资格判定)        : %0d", l0_updn);
      $display("  命中已有条目                : %0d", l0_mtchn);
      $display("  未命中 → 分配新条目         : %0d  <-- 表搅动", l0_allocn);
      $display("    其中 预测 taken 时分配     : %0d", l0_alloc_t);
      $display("    其中 预测 not-taken 时分配 : %0d  <-- 天然不可能武装的废项", l0_alloc_n);
      $display("  update_fire / kill / hold   : %0d / %0d / %0d",
               l0_firen, l0_killn, l0_holdn);
      $display("--- 选择优先级一致性 (C910 无此问题, 它随包带命中 one-hot) ---");
      $display("同 PC 重复项导致多路匹配的拍数 : %0d  (0 = 取最高/最低永不冲突)", b_mm);
      $display("  其中真的发生写入的拍数       : %0d", b_mm_fire);
      $display("  自检 matchvec==1 的拍数      : %0d (应≈命中已有条目)", b_mm1);
      $display("更新选中项 != 最近同 PC 查找命中项: %0d", b_disagree);
      $display("  (后者含'查找命中的是同块里更晚的分支'这种正常情形, 不是判错依据)");
      $display("=============================================");
    end
  endtask

  // ===========================================================================
  // [IC1] Q6b: CoreMark —— 条件分支的"自距离"分布
  //
  // 想回答的问题: 类 3 那种"同一条静态分支的下一次实例要等很多条其它条件分支"
  //   在 CoreMark 里占多少? 它们贡献了多少误预测?
  //
  // 定义: 自距 = 两次相邻实例之间【执行过的条件分支条数】(全局序号差)。
  //   GHR 只有 22 位 => 自距 > 22 时, 这条分支【自己上一次的结局】已经不在 GHR 里了,
  //   它只能靠"最近 22 条其它分支的结局"来猜。
  //   分档: 0=首次, 1=<=4, 2=<=8, 3=<=16, 4=<=22, 5=<=32, 6=<=64, 7=<=128, 8=<=512, 9=>512
  //
  // 直映射表索引 pc[13:2] (4096 项); CoreMark 镜像 13.9KB < 16KB, 基本无冲突。
  // ===========================================================================
  localparam CBN = 4096;
  integer cbq_seq = 1;
  integer cbq_last [0:CBN-1];
  integer cbq_dn [0:9], cbq_dm [0:9], cbq_dt [0:9];
  integer cbq_idx, cbq_d, cbq_b, cbq_j;
  // 逐 PC 汇总 (用于看"误预测大户"是谁)
  integer cbp_n [0:CBN-1], cbp_m [0:CBN-1], cbp_t [0:CBN-1], cbp_d [0:CBN-1];
  integer cbp_pc[0:CBN-1];
  integer cbp_k, cbp_best, cbp_bi;

  function automatic integer cbq_bin(input integer d);
    begin
      if      (d <= 0)    cbq_bin = 0;
      else if (d <= 4)    cbq_bin = 1;
      else if (d <= 8)    cbq_bin = 2;
      else if (d <= 16)   cbq_bin = 3;
      else if (d <= 22)   cbq_bin = 4;
      else if (d <= 32)   cbq_bin = 5;
      else if (d <= 64)   cbq_bin = 6;
      else if (d <= 128)  cbq_bin = 7;
      else if (d <= 512)  cbq_bin = 8;
      else                cbq_bin = 9;
    end
  endfunction

  initial begin
    for (cbq_j = 0; cbq_j < CBN; cbq_j = cbq_j + 1) begin
      cbq_last[cbq_j] = 0;
      cbp_n[cbq_j] = 0; cbp_m[cbq_j] = 0; cbp_t[cbq_j] = 0; cbp_d[cbq_j] = 0;
      cbp_pc[cbq_j] = 0;
    end
    for (cbq_j = 0; cbq_j < 10; cbq_j = cbq_j + 1) begin
      cbq_dn[cbq_j] = 0; cbq_dm[cbq_j] = 0; cbq_dt[cbq_j] = 0;
    end
  end

  always @(posedge clk) if (!rst && bench_en && st_cond) begin
    cbq_idx = dut.Core_cpu.pc_EX[13:2];
    if (cbq_last[cbq_idx] == 0) cbq_d = 0;
    else                        cbq_d = cbq_seq - cbq_last[cbq_idx];
    cbq_b = cbq_bin(cbq_d);
    cbq_dn[cbq_b] = cbq_dn[cbq_b] + 1;
    if (st_mis) cbq_dm[cbq_b] = cbq_dm[cbq_b] + 1;
    if (dut.Core_cpu.ex_alu_f) cbq_dt[cbq_b] = cbq_dt[cbq_b] + 1;
    cbq_last[cbq_idx] = cbq_seq;
    cbq_seq = cbq_seq + 1;

    cbp_n[cbq_idx] = cbp_n[cbq_idx] + 1;
    if (st_mis) cbp_m[cbq_idx] = cbp_m[cbq_idx] + 1;
    if (dut.Core_cpu.ex_alu_f) cbp_t[cbq_idx] = cbp_t[cbq_idx] + 1;
    cbp_d[cbq_idx] = cbq_d;
    cbp_pc[cbq_idx] = dut.Core_cpu.pc_EX;
  end

  // ---------------------------------------------------------------------------
  // 定向基准 asm/branch_bench.S 的分场景统计 (+BENCH)
  //
  // CoreMark 只能看总量, 分不出"哪一类分支在变好/变差"; 小用例的统计量又被
  // IFU 初始化的 1027 拍淹没。branch_bench 把四类可判定场景放进四个互不重叠
  // 的 PC 区间, 这里按 PC 分桶, 用来定向验证 P0 的语义改动。
  //
  // 只在 +BENCH 时计数 ⇒ CoreMark 等整场基准不加这个 plusarg, 完全不受影响。
  //
  // 分桶用的 PC 必须与 branch_bench.S 头部的布局注释一致:
  //   1 [0x100,0x140) ① 稳定 taken 的循环回边
  //   2 [0x140,0x1c0) ② 几乎不跳的前向分支 (恒不跳)
  //   3 [0x1c0,0x250) ③ 交替 taken/not-taken
  //   4 [0x250,0x290) ④ 函数调用/返回
  //   0 其余 (外层循环/初始化/退出, 仅作对账)
  //
  // 各桶的采样点与所测 PC:
  //   分支准确率   pc_EX            (控制转移在 EX 结算的那一拍)
  //   L0 查找/命中 l0_lookpc        (IF 级查询 PC = ifdp_l0_btb_pc)
  //   L0 更新      l0_updpc         (训练 PC = train_pc, 即分支自己的 PC)
  //   L0 判错      ipc_lastpkt[63:32] (IP 级 packet 的 PC 字段)
  // ---------------------------------------------------------------------------
  function automatic integer bench_class(input [31:0] pc);
    if      (pc >= 32'h0000_0100 && pc < 32'h0000_0140) return 1;
    else if (pc >= 32'h0000_0140 && pc < 32'h0000_01c0) return 2;
    else if (pc >= 32'h0000_01c0 && pc < 32'h0000_0250) return 3;
    else if (pc >= 32'h0000_0250 && pc < 32'h0000_0290) return 4;
    else if (pc >= 32'h0000_0290 && pc < 32'h0000_0320) return 5;
    else                                                return 0;
  endfunction

  integer bcls;
  integer bc_cond    [0:5];   // 条件分支数
  integer bc_mis     [0:5];   // 条件分支误预测
  integer bc_tpred   [0:5];   // BHT 预测 taken
  integer bc_taken   [0:5];   // 实际 taken
  integer bc_strong  [0:5];   // 预测 taken 且 chk_idx[24]=1 (强 taken)
  integer bc_weak    [0:5];   // 预测 taken 且 chk_idx[24]=0 (弱 taken)
  integer bc_jmp     [0:5];   // jal / jalr
  integer bc_misj    [0:5];   // jal / jalr 误预测
  integer bc_lk      [0:5];   // L0 查询
  integer bc_hit     [0:5];   // L0 查询命中
  integer bc_inv     [0:5];   // L0 被判错 (白取)
  integer bc_redir   [0:5];   // L0 命中且该段确实是 IF 级改向源
  integer bc_trv     [0:5];   // 训练上报
  integer bc_trt     [0:5];   // 训练: update_taken=1
  integer bc_trn     [0:5];   // 训练: update_taken=0
  integer bc_upd     [0:5];   // 过资格判定
  integer bc_mtch    [0:5];   // 命中已有条目
  integer bc_alloc   [0:5];   // 分配新条目
  integer bc_alloct  [0:5];   // 分配且 update_taken=1
  integer bc_allcn   [0:5];   // 分配且 update_taken=0 (P0-3 的靶子)
  integer bc_kill    [0:5];
  integer bc_hold    [0:5];
  integer bc_arm     [0:5];   // 命中项里已武装的条数之和 (看武装状态)

  // ipctrl 的 packet PC 字段; 与 report_l0_stats 里的三桶判决同一来源
  // (不要写成 wire x = expr: 本机 VCS 上对实例驱动网的 net declaration
  //  assignment 会读到 Z, 见 ifu 集成时的踩坑记录)
  wire [31:0] ipc_pktpc;
  assign ipc_pktpc = ipc_lastpkt[63:32];

  // 本机 VCS 不会把未初始化的 integer 数组清成 0 (读出来是 x, 而 x+1 恒为 x),
  // 所以必须显式清零 —— 直接照抄上面的 `integer n_cond = 0;` 写法做不到数组,
  // 只能这样成批赋。
  integer bk;
  initial for (bk = 0; bk <= 5; bk = bk + 1) begin
    bc_cond[bk] = 0; bc_mis[bk]   = 0; bc_tpred[bk] = 0; bc_taken[bk]  = 0;
    bc_strong[bk] = 0; bc_weak[bk] = 0; bc_jmp[bk]  = 0; bc_misj[bk]   = 0;
    bc_lk[bk]   = 0; bc_hit[bk]   = 0; bc_inv[bk]   = 0; bc_redir[bk]  = 0;
    bc_trv[bk]  = 0; bc_trt[bk]   = 0; bc_trn[bk]   = 0; bc_upd[bk]    = 0;
    bc_mtch[bk] = 0; bc_alloc[bk] = 0; bc_alloct[bk] = 0; bc_allcn[bk] = 0;
    bc_kill[bk] = 0; bc_hold[bk]  = 0; bc_arm[bk]   = 0;
  end

  always @(posedge clk) if (!rst && bench_en) begin
    // ---- 分支准确率: 按 pc_EX 分桶 (与 st_cond/st_jmp/st_mis 同门控) ----
    if (st_cond) begin
      bcls = bench_class(dut.Core_cpu.pc_EX);
      bc_cond[bcls]  = bc_cond[bcls]  + 1;
      bc_tpred[bcls] = bc_tpred[bcls] + dut.Core_cpu.ex_bht_pred;
      bc_taken[bcls] = bc_taken[bcls] + dut.Core_cpu.ex_alu_f;
      if ( dut.Core_cpu.ex_bht_pred &  dut.Core_cpu.ex_bht_chk[24]) bc_strong[bcls] = bc_strong[bcls] + 1;
      if ( dut.Core_cpu.ex_bht_pred & ~dut.Core_cpu.ex_bht_chk[24]) bc_weak  [bcls] = bc_weak  [bcls] + 1;
    end
    if (st_jmp) begin
      bcls = bench_class(dut.Core_cpu.pc_EX);
      bc_jmp[bcls] = bc_jmp[bcls] + 1;
    end
    if (st_mis) begin
      bcls = bench_class(dut.Core_cpu.pc_EX);
      if (st_cond)     bc_mis [bcls] = bc_mis [bcls] + 1;
      else if (st_jmp) bc_misj[bcls] = bc_misj[bcls] + 1;
    end
    // ---- L0 查找/命中: 按 IF 级查询 PC 分桶 ----
    if (l0_lookup_en) begin
      bcls = bench_class(l0_lookpc);
      bc_lk[bcls] = bc_lk[bcls] + 1;
      if (l0_hit_w) bc_hit[bcls] = bc_hit[bcls] + 1;
    end
    // ---- L0 更新: 按训练 PC (分支自己的 PC) 分桶 ----
    if (top_train_v) begin
      bcls = bench_class(l0_updpc);
      bc_trv[bcls] = bc_trv[bcls] + 1;
      if (top_train_t) bc_trt[bcls] = bc_trt[bcls] + 1;
      else             bc_trn[bcls] = bc_trn[bcls] + 1;
    end
    if (l0_upd_en) begin
      bcls = bench_class(l0_updpc);
      bc_upd[bcls] = bc_upd[bcls] + 1;
      if (l0_upd_match) bc_mtch[bcls] = bc_mtch[bcls] + 1;
      if (l0_kill) bc_kill[bcls] = bc_kill[bcls] + 1;
      if (l0_hold) bc_hold[bcls] = bc_hold[bcls] + 1;
      if (l0_upd_match) bc_arm [bcls] = bc_arm[bcls] + $countones(l0_updsel & l0_cnt_v);
    end
    if (l0_alloc) begin
      bcls = bench_class(l0_updpc);
      bc_alloc[bcls] = bc_alloc[bcls] + 1;
      if (top_train_t) bc_alloct[bcls] = bc_alloct[bcls] + 1;
      else             bc_allcn [bcls] = bc_allcn [bcls] + 1;
    end
    // ---- L0 判错 (白取): 按 IP 级 packet PC 分桶 ----
    if (top_l0_inv) begin
      bcls = bench_class(ipc_pktpc);
      bc_inv[bcls] = bc_inv[bcls] + 1;
    end
    // ---- IF 级改向: accept 是 IF 级的脉冲, 用同一级的查询 PC 分桶
    //      (accept 的源头就是这一拍的查询命中, 这里不复算, 只作分桶标签) ----
    if (top_l0_redir) begin
      bcls = bench_class(l0_lookpc);
      bc_redir[bcls] = bc_redir[bcls] + 1;
    end
  end

  // [Q6b] CoreMark 自距离分布报告
  task automatic report_coremark_selfdist();
    integer k, tot, mis, dt, cum_n, cum_m;
    begin
      tot = 0; mis = 0; dt = 0;
      for (k = 0; k <= 9; k = k + 1) begin tot = tot + cbq_dn[k]; mis = mis + cbq_dm[k]; dt = dt + cbq_dt[k]; end
      if (tot == 0) begin
        $display("========== [Q6b] CoreMark 条件分支自距离分布 ==========");
        $display("  (本用例没有条件分支计数, 或未加 +BENCH)");
        $display("=====================================================");
      end else begin
        $display("========== [Q6b] CoreMark 条件分支自距离分布 ==========");
        $display("  自距 = 同类静态分支两次实例之间执行过的条件分支条数; GHR 只有 22 位");
        $display("  条件分支总数 %0d  (实际 taken %0.1f%%)", tot, 100.0*dt/tot);
        $display("  %-22s %10s %8s %10s %10s", "自距区间", "条数", "占比", "误预测", "该档准确率");
        for (k = 0; k <= 9; k = k + 1) begin
          if (cbq_dn[k] > 0)
            $display("  %-22s %10d %7.2f%% %10d %9.2f%%",
                     (k==0) ? "首次" :
                     (k==1) ? "1-4" :
                     (k==2) ? "5-8" :
                     (k==3) ? "9-16" :
                     (k==4) ? "17-22" :
                     (k==5) ? "23-32" :
                     (k==6) ? "33-64" :
                     (k==7) ? "65-128" :
                     (k==8) ? "129-512" : ">512",
                     cbq_dn[k], 100.0*cbq_dn[k]/tot, cbq_dm[k],
                     100.0*(cbq_dn[k]-cbq_dm[k])/cbq_dn[k]);
        end
        cum_n = 0; cum_m = 0;
        for (k = 5; k <= 9; k = k + 1) begin cum_n = cum_n + cbq_dn[k]; cum_m = cum_m + cbq_dm[k]; end
        $display("  ---- 自距 > 22 (GHR 罩不住) 合计: %0d 条 = %0.2f%% 的条数, 占误预测 %0.2f%%, 该组准确率 %0.2f%%",
                 cum_n, 100.0*cum_n/tot, (mis>0)?100.0*cum_m/mis:0.0,
                 (cum_n>0)?100.0*(cum_n-cum_m)/cum_n:0.0);
        begin : cbp_top
          integer bi, t2, done;
          $display("  ---- 误预测最多的 20 条静态分支 ----");
          $display("  %-12s %9s %9s %9s %9s", "PC", "执行", "误预测", "准确率", "自距");
          for (bi = 0; bi < 20; bi = bi + 1) begin
            cbp_best = -1;
            for (cbp_k = 0; cbp_k < CBN; cbp_k = cbp_k + 1)
              if (cbp_m[cbp_k] > 0 && (cbp_best < 0 || cbp_m[cbp_k] > cbp_m[cbp_best]))
                cbp_best = cbp_k;
            if (cbp_best >= 0) begin
              $display("  %-12h %9d %9d %8.2f%% %9d",
                       cbp_pc[cbp_best], cbp_n[cbp_best], cbp_m[cbp_best],
                       100.0*(cbp_n[cbp_best]-cbp_m[cbp_best])/cbp_n[cbp_best], cbp_d[cbp_best]);
              cbp_m[cbp_best] = 0;   // 打过的清掉, 下一轮选下一个
            end else bi = 20;
          end
        end
        $display("=====================================================");
      end
    end
  endtask

  task automatic report_bench_stats();
    integer k;
    begin
      $display("");
      $display("========== 定向基准分场景统计 (branch_bench) ==========");
      $display("PC 区间: 1[0x100,0x140) 2[0x140,0x1c0) 3[0x1c0,0x250) 4[0x250,0x290) 5[0x290,0x320) 0=其余");
      $display("1=稳定taken回边 2=恒不跳前向 3=交替 4=调用/返回 5=T,T,T,N(造弱taken)");
      $display("%-30s %8s %8s %8s %8s %8s %8s",
               "类别", "1回边", "2不跳", "3交替", "4调用", "5弱tk", "0其余");
      $display("%-30s %8d %8d %8d %8d %8d %8d", "条件分支数 (EX)",
               bc_cond[1], bc_cond[2], bc_cond[3], bc_cond[4], bc_cond[5], bc_cond[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  误预测",
               bc_mis[1], bc_mis[2], bc_mis[3], bc_mis[4], bc_mis[5], bc_mis[0]);
      for (k = 1; k <= 5; k = k + 1) begin
        if (bc_cond[k] > 0)
          $display("  类%0d 条件分支准确率             : %0.2f%%  (%0d/%0d)",
                   k, 100.0*(bc_cond[k]-bc_mis[k])/bc_cond[k], bc_cond[k]-bc_mis[k], bc_cond[k]);
      end
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  预测 taken (BHT)",
               bc_tpred[1], bc_tpred[2], bc_tpred[3], bc_tpred[4], bc_tpred[5], bc_tpred[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  实际 taken",
               bc_taken[1], bc_taken[2], bc_taken[3], bc_taken[4], bc_taken[5], bc_taken[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  其中强 taken(11)",
               bc_strong[1], bc_strong[2], bc_strong[3], bc_strong[4], bc_strong[5], bc_strong[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  其中弱 taken(10)  <-- P0-1/P0-2",
               bc_weak[1], bc_weak[2], bc_weak[3], bc_weak[4], bc_weak[5], bc_weak[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "jal/jalr 数",
               bc_jmp[1], bc_jmp[2], bc_jmp[3], bc_jmp[4], bc_jmp[5], bc_jmp[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  jal/jalr 误预测",
               bc_misj[1], bc_misj[2], bc_misj[3], bc_misj[4], bc_misj[5], bc_misj[0]);
      $display("--- L0 BTB ---");
      $display("%-30s %8d %8d %8d %8d %8d %8d", "L0 查询 (按 IF PC)",
               bc_lk[1], bc_lk[2], bc_lk[3], bc_lk[4], bc_lk[5], bc_lk[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  L0 命中",
               bc_hit[1], bc_hit[2], bc_hit[3], bc_hit[4], bc_hit[5], bc_hit[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "L0 训练上报 (按分支 PC)",
               bc_trv[1], bc_trv[2], bc_trv[3], bc_trv[4], bc_trv[5], bc_trv[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  训练 taken",
               bc_trt[1], bc_trt[2], bc_trt[3], bc_trt[4], bc_trt[5], bc_trt[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  训练 not-taken",
               bc_trn[1], bc_trn[2], bc_trn[3], bc_trn[4], bc_trn[5], bc_trn[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  命中已有条目",
               bc_mtch[1], bc_mtch[2], bc_mtch[3], bc_mtch[4], bc_mtch[5], bc_mtch[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  分配新条目",
               bc_alloc[1], bc_alloc[2], bc_alloc[3], bc_alloc[4], bc_alloc[5], bc_alloc[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "    其中 taken 时  <-- 有效",
               bc_alloct[1], bc_alloct[2], bc_alloct[3], bc_alloct[4], bc_alloct[5], bc_alloct[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "    其中 ntk 时    <-- 废项 P0-3",
               bc_allcn[1], bc_allcn[2], bc_allcn[3], bc_allcn[4], bc_allcn[5], bc_allcn[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  命中项的已武装条数",
               bc_arm[1], bc_arm[2], bc_arm[3], bc_arm[4], bc_arm[5], bc_arm[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  kill (降级删项) P0-2",
               bc_kill[1], bc_kill[2], bc_kill[3], bc_kill[4], bc_kill[5], bc_kill[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  hold",
               bc_hold[1], bc_hold[2], bc_hold[3], bc_hold[4], bc_hold[5], bc_hold[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "L0 判错/白取 (按 IP PC)",
               bc_inv[1], bc_inv[2], bc_inv[3], bc_inv[4], bc_inv[5], bc_inv[0]);
      $display("%-30s %8d %8d %8d %8d %8d %8d", "  同期 IF 级改向",
               bc_redir[1], bc_redir[2], bc_redir[3], bc_redir[4], bc_redir[5], bc_redir[0]);
      $display("对账: 各桶条件分支合计 %0d (全局 %0d)",
               bc_cond[0]+bc_cond[1]+bc_cond[2]+bc_cond[3]+bc_cond[4]+bc_cond[5], n_cond);
      $display("--- 定向实验: GHR (vghr) 活性 ---");
      $display("  vghr_q 非零拍数      : %0d", dbg_nz);
      $display("  vghr_q 发生变化的拍数: %0d", dbg_chg);
      $display("  bht_ipdp_vghr_q 与 vghr_q 不等的拍数: %0d", dbg_ipdiff);
      $display("  pre_vghr_offset_0 非零拍数: %0d", dbg_ofsnz);

      $display("--- 大 BTB (L1) 的贡献 ---");
      $display("  查找选通 %0d 拍 | 结果有效 %0d 拍 | 其中命中 %0d 拍 (命中率 %.2f%%)",
               bt_n_lookup, bt_n_result, bt_n_hit,
               (bt_n_result > 0) ? 100.0 * bt_n_hit / bt_n_result : 0.0);
      $display("  IF 级有效 %0d 拍 | 其中命中 %0d 拍 (%.2f%%)",
               bt_n_ifvld, bt_n_ifhit,
               (bt_n_ifvld > 0) ? 100.0 * bt_n_ifhit / bt_n_ifvld : 0.0);
      for (bti = 1; bti <= 5; bti = bti + 1) begin
        if (bt_cls_lk[bti] > 0)
          $display("  L1 cls%0d 查询 %6d  命中 %6d  (%.2f%%)", bti, bt_cls_lk[bti], bt_cls_ht[bti],
                   100.0 * bt_cls_ht[bti] / bt_cls_lk[bti]);
      end
      $display("--- 定向实验 Step 1: BHT 预测时刻四元组 ---");
      for (si = 0; si < 16; si = si + 1) begin
        if (st_n3[si] > 0)
          $display("  cls3 pos%0d pc=%h n=%5d row=%h oh=%h sel=%h cnt=%h taken=%5d | 00=%0d 01=%0d 10=%0d 11=%0d",
                   si, st_pc3[si], st_n3[si], st_row3[si], st_oh3[si], st_sel3[si], st_cnt3[si], st_tk3[si],
                   st_c3_00[si], st_c3_01[si], st_c3_10[si], st_c3_11[si]);
      end
      for (si = 0; si < 16; si = si + 1) begin
        if (st_n5[si] > 0)
          $display("  cls5 pos%0d pc=%h n=%5d row=%h oh=%h sel=%h cnt=%h taken=%5d",
                   si, st_pc5[si], st_n5[si], st_row5[si], st_oh5[si], st_sel5[si], st_cnt5[si], st_tk5[si]);
      end
      $display("--- pre-array / 选择阵列 状态 ---");
      $display("  pre_array_data_taken 非零拍数 : %0d", dbg_tkn_nz);
      $display("  pre_array_data_ntake 非零拍数 : %0d", dbg_ntk_nz);
      $display("  sel_array_result[1]=1 拍数    : %0d", dbg_selr1);
      $display("  bht_selected 里有计数器>=2 的拍数: %0d", dbg_has2);
      $display("  bht_counter[1]=1 (预测 taken) 拍数: %0d", dbg_cnt1);
      $display("--- vghr 移位来源 (三个门控各 fired 多少拍) ---");
      $display("  ghr_updt_vld (iu_ifu_chgflw_vld)  : %0d", dbg_n_iu);
      $display("  vghr_lbuf_updt_vld                : %0d", dbg_n_lbuf);
      $display("  vghr_ip_updt_vld (ipctrl 条件分支): %0d", dbg_n_ip);
      $display("  lbuf_bht_active_state             : %0d", dbg_n_lact);
      $display("  ipctrl_bht_con_br_vld             : %0d", dbg_n_icb);
      $display("  iu_ifu_bht_check_vld              : %0d", dbg_n_bchk);
      $display("  bht_event 连续两拍都拉高          : %0d", dbg_ev2);
      $display("  bht_event 上升沿 (独立事件数)     : %0d", dbg_ev_nochk);
      $display("  check_vld 拉高但 bht_event 没拉高 : %0d", dbg_chk_noev);
      $display("--- vghr_q[3:0] 分布 (自锁假设) ---");
      $display("  == 0  : %0d 拍", dbg_gh0);
      $display("  == 15 : %0d 拍", dbg_gh15);
      $display("  其它  : %0d 拍", dbg_gh_mid);
      $display("  类3 指令在 EX 时出现过的 vghr[3:0] 取值个数: 见下方 bits=%h", dbg_offs_acc);
      $display("--- mispredict 解锁通路 (注入真实结果) ---");
      $display("  ghr_updt_vld && check_vld 拍数 (真值注入) : %0d", dbg_n_unlock);
      $display("    其中 condbr_taken=1 (注入 1)            : %0d", dbg_n_unl_t);
      $display("    其中 condbr_taken=0 (注入 0)            : %0d", dbg_n_unlock - dbg_n_unl_t);

      // -----------------------------------------------------------------
      // [Q2] 类 3 / 类 5 逐条分支方向准确率 (与 §1.2 同口径, 细化到类内位置)
      // -----------------------------------------------------------------
      $display("--- [Q2] 逐条分支方向准确率 (pos = (pc-基准)>>4, 与 C910 编号一致) ---");
      for (si = 0; si < 16; si = si + 1) begin
        if (b3_cond[si] > 0)
          $display("  cls3 pos%0d pc=%h n=%5d 准=%6.2f%%  误=%5d  预测tk=%5d 实际tk=%5d",
                   si, b3_pc[si], b3_cond[si],
                   100.0*(b3_cond[si]-b3_mis[si])/b3_cond[si], b3_mis[si], b3_tp[si], b3_tk[si]);
      end
      for (si = 0; si < 16; si = si + 1) begin
        if (b5_cond[si] > 0)
          $display("  cls5 pos%0d pc=%h n=%5d 准=%6.2f%%  误=%5d  预测tk=%5d 实际tk=%5d",
                   si, b5_pc[si], b5_cond[si],
                   100.0*(b5_cond[si]-b5_mis[si])/b5_cond[si], b5_mis[si], b5_tp[si], b5_tk[si]);
      end

      // -----------------------------------------------------------------
      // [Q1] L1 大 BTB 逐 PC 普查: [0x100,0x320) 每 4 字节一行
      //      lk=查询 ht=命中 ev=可用槽位有有效项 em=可用槽位有 tag 匹配
      //      occ=该 16 字节行有效槽位数之和 (均值 = 行占用), uf=真正写进 SRAM 的更新
      // -----------------------------------------------------------------
      $display("--- [Q1] L1 大 BTB 逐 PC 普查 (窗口 [0x100,0x320), 4B 粒度) ---");
      $display("  L1 查询被阻塞 (lookup_vld & !ready) : %0d 拍", btw_blk);
      $display("  更新被接受 / 被丢 (非对齐等)        : %0d / %0d", btw_upd_acc, btw_upd_drp);
      $display("  %-10s %7s %7s %7s %7s %8s %7s", "PC", "lk", "ht", "ev", "em", "occ均", "uf");
      for (btw_idx = 0; btw_idx < BTW_N; btw_idx = btw_idx + 1) begin
        if (btw_lk[btw_idx] > 0 || btw_uf[btw_idx] > 0)
          $display("  0x%h  %7d %7d %7d %7d %8.2f %7d",
                   BTW_BASE + btw_idx*4, btw_lk[btw_idx], btw_ht[btw_idx],
                   btw_ev[btw_idx], btw_em[btw_idx],
                   (btw_lk[btw_idx] > 0) ? 1.0*btw_occ[btw_idx]/btw_lk[btw_idx] : 0.0,
                   btw_uf[btw_idx]);
      end
      for (bti = 1; bti <= 5; bti = bti + 1) begin
        if (bt_cls_lk[bti] > 0)
          $display("  [类合计复核] cls%0d 查询 %6d 命中 %6d (%.2f%%)",
                   bti, bt_cls_lk[bti], bt_cls_ht[bti], 100.0*bt_cls_ht[bti]/bt_cls_lk[bti]);
      end

      // -----------------------------------------------------------------
      // [Q3] 类 3 的 (行地址 x 相位 x 计数器) 联合分布
      //      每行: slot=第几个不同行地址 n=样本 s0/s1=两种相位的样本数
      //            c00/c01/c10/c11 = 读到的 2 位计数器分布
      //      判据: 若同一行地址下 s0/s1 还是 50/50 混, 说明行地址与相位无关;
      //            若 s0/s1 分得很开而 c00..c11 仍全是 00/01, 说明写进该行的
      //            计数器没被训练到 taken 侧。
      // -----------------------------------------------------------------
      $display("--- [Q3] cls3 (行地址 x 相位 x 计数器) 联合分布 ---");
      for (si = 0; si < 16; si = si + 1) begin
        if (j3_slotv[si] > 0) begin
          $display("  cls3 pos%0d pc=%h 不同行地址数=%0d", si, st_pc3[si], j3_slotv[si]);
          for (jk = 0; jk < j3_slotv[si]; jk = jk + 1) begin
            jidx = si*16 + jk;
            $display("    row=%h n=%5d  相位0=%5d 相位1=%5d   cnt: 00=%5d 01=%5d 10=%5d 11=%5d",
                     j3_key[jidx], j3_n[jidx], j3_s0[jidx], j3_s1[jidx],
                     j3_c0[jidx], j3_c1[jidx], j3_c2[jidx], j3_c3[jidx]);
          end
        end
      end
      $display("  [相位自检] 进入类3区间的次数 = %0d (应为 512, 即外层轮次)", jround3);
      // -----------------------------------------------------------------
      // [Q3-5] 相位可分性: 比分布而不是比凸包
      //   "混入比例" = 该相位的样本里, 落在【另一个相位也读过】的地址(或 GHR 值)上的比例。
      //   接近 0  -> 两个相位用的计数器分得很开, 交替序列可学;
      //   接近 100 -> 同一个计数器两种相位都在读, 上限就是 50%。
      // -----------------------------------------------------------------
      $display("--- [Q3-5] 相位可分性 (比分布) ---");
      begin : q35_block
        integer c, tt, tn, ts, ns, tdist, ndist, shdist, tsh, nsh;
        integer idx2;
        for (c = 3; c <= 5; c = c + 2) begin
          tdist = 0; ndist = 0; shdist = 0; tsh = 0; nsh = 0; tt = 0; tn = 0;
          for (idx2 = 0; idx2 < 512; idx2 = idx2 + 1) begin
            if (j6_acl[idx2] == c && (j6_at[idx2] > 0 || j6_an[idx2] > 0)) begin
              if (j6_at[idx2] > 0) tdist = tdist + 1;
              if (j6_an[idx2] > 0) ndist = ndist + 1;
              tt = tt + j6_at[idx2];
              tn = tn + j6_an[idx2];
              if (j6_at[idx2] > 0 && j6_an[idx2] > 0) begin
                shdist = shdist + 1;
                tsh = tsh + j6_at[idx2];
                nsh = nsh + j6_an[idx2];
              end
            end
          end
          $display("  类%0d 计数器地址: T相位 %0d 个(样%d) / N相位 %0d 个(样%d) / 两相位共有 %0d 个",
                   c, tdist, tt, ndist, tn, shdist);
          $display("       -> 「共有地址」覆盖 T 侧 %0.1f%%, N 侧 %0.1f%%",
                   (tt>0)?100.0*tsh/tt:0.0, (tn>0)?100.0*nsh/tn:0.0);
          begin : sep1
            integer i3, best, bt, bn;
            best = 0;
            for (i3 = 0; i3 < 512; i3 = i3 + 1)
              if (j6_acl[i3] == c) best = best + ((j6_at[i3] > j6_an[i3]) ? j6_at[i3] : j6_an[i3]);
            // 平衡版: 按 t/T vs n/N 判, 再看两类的召回率平均 —— 剔掉类间样本数不平衡(70/30)的干扰
            bt = 0; bn = 0;
            for (i3 = 0; i3 < 512; i3 = i3 + 1) begin
              if (j6_acl[i3] == c && (j6_at[i3] > 0 || j6_an[i3] > 0)) begin
                if (j6_at[i3]*tn >= j6_an[i3]*tt) bt = bt + j6_at[i3];
                else                               bn = bn + j6_an[i3];
              end
            end
            $display("       -> ★ 只看地址猜相位: 朴素 %0.1f%% (受样本数不平衡干扰) / 平衡 %0.1f%%  [50%%=分不开 100%%=完全分开]",
                     (tt+tn>0)?100.0*best/(tt+tn):0.0,
                     ((tt>0&&tn>0))?50.0*(1.0*bt/tt + 1.0*bn/tn):0.0);
          end
          tdist = 0; ndist = 0; shdist = 0; tsh = 0; nsh = 0; tt = 0; tn = 0;
          for (idx2 = ((c == 5) ? 2048 : 0); idx2 < ((c == 5) ? 4096 : 2048); idx2 = idx2 + 1) begin
            if (j6_g[idx2] > 0) begin
              if (j6_gt[idx2] > 0) tdist = tdist + 1;
              if (j6_gn[idx2] > 0) ndist = ndist + 1;
              tt = tt + j6_gt[idx2];
              tn = tn + j6_gn[idx2];
              if (j6_gt[idx2] > 0 && j6_gn[idx2] > 0) begin
                shdist = shdist + 1;
                tsh = tsh + j6_gt[idx2];
                nsh = nsh + j6_gn[idx2];
              end
            end
          end
          $display("  类%0d GHR低8位 : T相位 %0d 个取值(样%d) / N相位 %0d 个 / 共有 %0d 个",
                   c, tdist, tt, ndist, shdist);
          $display("       -> 「共有 GHR 值」覆盖 T 侧 %0.1f%%, N 侧 %0.1f%%",
                   (tt>0)?100.0*tsh/tt:0.0, (tn>0)?100.0*nsh/tn:0.0);
          begin : sep2
            integer i3, best, bt, bn;
            best = 0; bt = 0; bn = 0;
            for (i3 = ((c == 5) ? 2048 : 0); i3 < ((c == 5) ? 4096 : 2048); i3 = i3 + 1) begin
              best = best + ((j6_gt[i3] > j6_gn[i3]) ? j6_gt[i3] : j6_gn[i3]);
              if (j6_gt[i3]*tn >= j6_gn[i3]*tt) bt = bt + j6_gt[i3];
              else                              bn = bn + j6_gn[i3];
            end
            $display("       -> ★ 只看 GHR低8位猜相位: 朴素 %0.1f%% / 平衡 %0.1f%%",
                     (tt+tn>0)?100.0*best/(tt+tn):0.0,
                     ((tt>0&&tn>0))?50.0*(1.0*bt/tt + 1.0*bn/tn):0.0);
          end
        end
        $display("  (地址表 %0d 项, 溢出 %0d)", j6_ac, j6_aovf);
      end

      // -----------------------------------------------------------------
      // [Q3-6] 写进去的是什么值 —— 决定病因在"写哪儿"还是"写什么"
      // -----------------------------------------------------------------
      $display("--- [Q3-10] 预测时刻读索引 mux 走哪一档 (类3/5 的预测) ---");
      $display("  1 rtu_flush=%0d  2 bju_mispred&!chk=%0d  3 bju_mispred&chk=%0d  4 local_recover=%0d  5 after_misp/flush_q=%0d  6 正常=%0d  合计=%0d",
               q310_n[0],q310_n[1],q310_n[2],q310_n[3],q310_n[4],q310_n[5],
               q310_n[0]+q310_n[1]+q310_n[2]+q310_n[3]+q310_n[4]+q310_n[5]);

      $display("  [自检] st_row 与用 vghr_q 按第6档算出的值: 相等 %0d / 不等 %0d", q310_rowok, q310_rowne);
      $display("--- [Q3-8] 预测级读地址 vs 提交级写地址, 同一 PC 配对 ---");
      $display("  预测入表 %0d 次, 写侧配对命中 %0d / 未命中 %0d", q38_ins, q38_hit, q38_miss);
      $display("  命中里: 地址完全相同 %0d; 不同 %0d (word 不同 %0d / plane 不同 %0d / offset 不同 %0d)",
               q38_eq, q38_hit-q38_eq, q38_wne, q38_pne, q38_one);
      $display("  同 PC 有多项(取最新)次数 = %0d; 配对年龄最大 %0d 拍", q38_skip, q38_age_max);
      $display("  年龄直方图 0..7 拍: %0d %0d %0d %0d %0d %0d %0d %0d",
               q38_age_hist[0],q38_age_hist[1],q38_age_hist[2],q38_age_hist[3],
               q38_age_hist[4],q38_age_hist[5],q38_age_hist[6],q38_age_hist[7]);
      $display("  [Q3-9] 随包 GHR 与预测时刻 GHR: 完全相等 %0d / 不等 %0d", q38_geq, q38_gne);
      $display("         不等的那些里, 右移 k 位后高位一致(k=1..4): %0d %0d %0d %0d",
               q38_gsh[1],q38_gsh[2],q38_gsh[3],q38_gsh[4]);
      $display("         低 8 位对齐关系: 同相 %0d / 随包比预测新1位 %0d / 新2位 %0d",
               q38_gx0, q38_gx1, q38_gx2);
      $display("  (q38_pcseen=%h: 只作参考)", q38_pcseen);

      $display("--- [Q3-6] 写入的值分布 ---");
      $display("  全局: 写 %0d 次, 值 00=%0d 01=%0d 10=%0d 11=%0d",
               j6_wall, j6_wv[0], j6_wv[1], j6_wv[2], j6_wv[3]);
      $display("  类3 读到的地址上(这些地址的读次数一并列出):");
      for (si = 0; si < 512; si = si + 1) begin
        if (j6_acl[si] == 3 && (j6_at[si]+j6_an[si]) > 0)
          $display("    %h word=%h plane=%0d off=%0d  读%5d  写:%0d次(00=%0d 01=%0d 10=%0d 11=%0d)",
                   j6_a[si], j6_a[si][14:5], j6_a[si][4], j6_a[si][3:0], j6_at[si]+j6_an[si],
                   j6_aw[si*4]+j6_aw[si*4+1]+j6_aw[si*4+2]+j6_aw[si*4+3],
                   j6_aw[si*4], j6_aw[si*4+1], j6_aw[si*4+2], j6_aw[si*4+3]);
      end
      $display("--- [Q3-7] 全局写地址 (word,plane,offset), 共 %0d 个 / 写 %0d 次 (溢出 %0d) ---",
               j7_c, j6_wall, j7_ovf);
      $display("  %-8s %6s   %s", "addr", "写次数", "word plane offset");
      for (si = 0; si < 512; si = si + 1) begin
        if (j7_n[si] > 0)
          $display("  %h %6d   w=%h pl=%0d off=%0d",
                   j7_a[si], j7_n[si], j7_a[si]/32, (j7_a[si]/16)%2, j7_a[si]%16);
      end

      $display("--- [Q3-4] 类3 读到的完整计数器地址 (word,plane,offset) 的读/写次数 ---");
      $display("  不同地址数 = %0d (溢出 %0d)", j4_naddr, j4_ovf);
      $display("  %-8s %8s %8s   %s", "地址", "读次数", "写次数", "(word,plane,offset)");
      for (si = 0; si < 256; si = si + 1) begin
        if (j4_nrd[si] > 0)
          $display("  0x%h %8d %8d   word=%h plane=%0d offset=%0d",
                   j4_addr[si], j4_nrd[si], j4_nwr[si],
                   j4_addr[si][14:5], j4_addr[si][4], j4_addr[si][3:0]);
      end
      $display("--- [Q3-4 对照] 类5 读到的完整计数器地址的读/写次数 ---");
      $display("  不同地址数 = %0d (溢出 %0d)", j5a_naddr, j5a_ovf);
      for (si = 0; si < 256; si = si + 1) begin
        if (j5a_nrd[si] > 0)
          $display("  0x%h %8d %8d   word=%h plane=%0d offset=%0d",
                   j5a_addr[si], j5a_nrd[si], j5a_nwr[si],
                   j5a_addr[si][14:5], j5a_addr[si][4], j5a_addr[si][3:0]);
      end
      $display("--- [Q3-3] 预测时刻的 GHR / 偏移 / 行地址, 按相位分开 (or==and 表示该相位内恒定) ---");
      for (si = 0; si < 16; si = si + 1) begin
        if (j3_slotv[si] > 0) begin
          $display("  cls3 pos%0d pc=%h", si, st_pc3[si]);
          $display("     相位0(不跳) n=%4d  GHR or=%h and=%h  偏移or=%h  行or=%h",
                   j3_ng0[si], j3_gp0_or[si], j3_gp0_ad[si], j3_oh0_or[si], j3_rw0_or[si]);
          $display("     相位1(要跳) n=%4d  GHR or=%h and=%h  偏移or=%h  行or=%h",
                   j3_ng1[si], j3_gp1_or[si], j3_gp1_ad[si], j3_oh1_or[si], j3_rw1_or[si]);
          $display("     两相位 GHR 集合相同? %s   偏移集合相同? %s   行集合相同? %s",
                   (j3_gp0_or[si]==j3_gp1_or[si] && j3_gp0_ad[si]==j3_gp1_ad[si]) ? "是 <== 索引里没有相位信息" : "否",
                   (j3_oh0_or[si]==j3_oh1_or[si]) ? "是" : "否",
                   (j3_rw0_or[si]==j3_rw1_or[si]) ? "是" : "否");
        end
      end
      $display("--- [Q3-对照] cls5 (行地址 x mod4 相位 x 计数器) ---");
      for (si = 0; si < 16; si = si + 1) begin
        if (j5_slotv[si] > 0) begin
          $display("  cls5 pos%0d pc=%h 不同行地址数=%0d", si, st_pc5[si], j5_slotv[si]);
          for (jk = 0; jk < j5_slotv[si]; jk = jk + 1) begin
            jidx = si*16 + jk;
            $display("    row=%h n=%5d  ph0=%5d ph1=%5d ph2=%5d ph3=%5d   cnt: 00=%5d 01=%5d 10=%5d 11=%5d",
                     j5_key[jidx], j5_n[jidx], j5_p0[jidx], j5_p1[jidx],
                     j5_p2[jidx], j5_p3[jidx],
                     j5_c0[jidx], j5_c1[jidx], j5_c2[jidx], j5_c3[jidx]);
          end
        end
      end
      $display("  [相位自检] 进入类5区间的次数 = %0d (应为 512)", jround5);
      $display("--- [Q3-3 对照] 类5 预测时刻的 GHR, 按 T/N 相位分开 ---");
      for (si = 0; si < 16; si = si + 1) begin
        if (j5_slotv[si] > 0) begin
          $display("  cls5 pos%0d pc=%h  N相位 n=%4d GHR or=%h and=%h | T相位 n=%4d GHR or=%h and=%h | 相同? %s",
                   si, st_pc5[si], j5_ngn[si], j5_gn_or[si], j5_gn_ad[si],
                   j5_ngt[si], j5_gt_or[si], j5_gt_ad[si],
                   (j5_gn_or[si]==j5_gt_or[si] && j5_gn_ad[si]==j5_gt_ad[si]) ? "是 <== 也无相位信息" : "否");
        end
      end

      // -----------------------------------------------------------------
      // [Q3-2] 读到的行 vs 写到的行 —— 同一位置分开累计, 看有没有交集
      //   "写过" = 读到的行出现在该位置的写集合里 (写索引命中)
      // -----------------------------------------------------------------
      $display("--- [Q3-2] 读索引集合 vs 写索引集合 (按类内位置) ---");
      $display("  [自检] 预测阵列真实写次数 (非 inv) = %0d  (落在类3窗口 %0d / 类5窗口 %0d)",
               q3_nall, q3_c3all, q3_c5all);
      $display("  [自检] 全局写过的行数 = %0d, 类3窗口内 = %0d, 类5窗口内 = %0d",
               $countones(q3_wrall), $countones(q3_wr3all), $countones(q3_wr5all));
      $display("  [关键A] 同一个 GHR 值(vghr_q)代进两条表达式是否相等:");
      $display("     类3: %0d/%0d 次相等", q3_same3, q3_tot3);
      $display("     类5: %0d/%0d 次相等", q3_same5, q3_tot5);
      $display("  [关键B] 写索引用【随包带下去的 GHR】算, 是否等于本次的读索引:");
      $display("     类3: %0d/%0d 次相等   <-- 相等才会训练到刚读的那个计数器",
               q3_csame3, q3_tot3x);
      $display("     类5: %0d/%0d 次相等", q3_csame5, q3_tot5x);
      $display("  [关键C] 把随包 GHR 按【读窗口】而不是写窗口代进去, 与读索引相等:");
      $display("     类3: %0d/%0d   类5: %0d/%0d", q3_shift3, q3_tot3x, q3_shift5, q3_tot5x);
      $display("  [自检] bht_ipdp_vghr_q 与 vghr_q 不等的拍数 = %0d / %0d",
               q3_hdiff, q3_tot3x + q3_tot5x);
      for (si = 0; si < 16; si = si + 1) begin
        if (j3_slotv[si] > 0) begin
          $display("  cls3 pos%0d pc=%h  读集合=%0d 行  类3窗口写集合=%0d 行  全局写集合=%0d 行",
                   si, st_pc3[si], $countones(q3_rd3[si]),
                   $countones(q3_wr3all), $countones(q3_wrall));
          for (jk = 0; jk < j3_slotv[si]; jk = jk + 1) begin
            jidx = si*16 + jk;
            $display("      读到的 row=%h n=%5d  -> 类3窗口写过? %s   全局写过? %s",
                     j3_key[jidx], j3_n[jidx],
                     q3_wr3all[j3_key[jidx]] ? "是" : "**否**",
                     q3_wrall [j3_key[jidx]] ? "是" : "**否**");
          end
        end
      end
      for (si = 0; si < 16; si = si + 1) begin
        if (j5_slotv[si] > 0)
          $display("  cls5 pos%0d pc=%h  读集合=%0d 行  类5窗口写集合=%0d 行",
                   si, st_pc5[si], $countones(q3_rd5[si]), $countones(q3_wr5all));
      end

      // -----------------------------------------------------------------
      // [Q5] L0 BTB 训练质量: entry_rd_hit 与 eligible 分开
      // -----------------------------------------------------------------
      $display("--- [Q5] L0 BTB 训练质量 (rd_hit vs eligible) ---");
      $display("  查询次数                          : %0d", q5_lookn);
      $display("  平均 entry_rd_hit (PC 在表里)     : %0.3f 条/次", (q5_lookn>0)?1.0*q5_rd_sum/q5_lookn:0.0);
      $display("  平均 eligible (在表里且可命中)    : %0.3f 条/次", (q5_lookn>0)?1.0*q5_el_sum/q5_lookn:0.0);
      $display("  PC 完全不在表里的查询             : %0d (%0.2f%%)",
               q5_rd0, (q5_lookn>0)?100.0*q5_rd0/q5_lookn:0.0);
      $display("  在表里但 eligible=0 (没武装/槽位) : %0d (%0.2f%%)",
               q5_noarm, (q5_lookn>0)?100.0*q5_noarm/q5_lookn:0.0);
      $display("    其中确实一条都没武装的          : %0d", q5_slotmiss);
      $display("  eligible=0 的查询合计             : %0d (%0.2f%%)",
               q5_el0, (q5_lookn>0)?100.0*q5_el0/q5_lookn:0.0);

      // -----------------------------------------------------------------
      // [Q4] 前端阻塞归因 (与取指气泡拆解同一门控)
      // -----------------------------------------------------------------
      $display("--- [Q4] 前端阻塞归因 ---");
      $display("  '核在等, IFU 没货' 拍数                       : %0d", q4_nofetch);
      $display("    其中 L1 BTB 这一拍拒绝查询 (lookup&!ready) : %0d (%0.2f%%)",
               q4_nf_btblk, (q4_nofetch>0)?100.0*q4_nf_btblk/q4_nofetch:0.0);
      $display("======================================================");
    end
  endtask

  task automatic report_bubble_stats();
    integer not_accept, chk;
    begin
      not_accept = b_init + b_flush + b_stall + b_nofetch;
      chk        = b_raw_init + b_raw_stall + b_raw_flush + b_nofetch;
      $display("");
      $display("================ 取指气泡拆解 ================");
      $display("总拍数                        : %0d", cycles);
      $display("核接受指令 (if_accept=1)      : %0d (%0.2f%%)",
               b_accept, 100.0*b_accept/cycles);
      $display("不给指令 (if_accept=0)        : %0d (%0.2f%%) [互斥合计自检 %0d]",
               not_accept, 100.0*not_accept/cycles, chk);
      $display("  1. IFU 初始化未完成         : %0d", b_init);
      $display("  2. 冲刷 (mispredict/陷阱)   : %0d", b_flush);
      $display("  3. 核内停顿                 : %0d", b_stall);
      $display("  4. 核在等, IFU 没货         : %0d (%0.2f%%)",
               b_nofetch, 100.0*b_nofetch/cycles);
      $display("     其中 reissue(访存重发)   : %0d", b_nf_reissue);
      $display("     其中 bp_read_stall       : %0d", b_nf_bpread);
      $display("     其中 if_frontend_stall   : %0d", b_nf_frontend);
      $display("     其它                     : %0d", b_nf_other);
      $display("  --- 「其它」归因: 事件后等前端重新出指令 ---");
      $display("     事件数 (改向/失效/冲刷)  : %0d / %0d / %0d (合计 %0d)",
               rf_ev_redir_c, rf_ev_inval_c, rf_ev_flush_c, rf_ev);
      $display("     重填等待拍数 按来源      : %0d / %0d / %0d (合计 %0d)",
               rf_redir, rf_inval, rf_flush, rf_wait);
      $display("     其中落在「其它」桶内      : %0d  (占该桶 %0.2f%%)",
               rf_in_bucket, (b_nf_other>0)?100.0*rf_in_bucket/b_nf_other:0.0);
      $display("  原始计数(不互斥): init=%0d stall=%0d(load-use %0d / div %0d / mul %0d) flush_if_id=%0d ifu_idu_flush=%0d !inst0_vld=%0d",
               b_raw_init, b_raw_stall, b_raw_loaduse, b_raw_div, b_raw_mul,
               b_raw_flush, b_raw_iflush, b_raw_novld);
      $display("=============================================");
    end
  endtask
`endif
endmodule
