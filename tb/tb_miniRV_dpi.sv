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
        if (gm_exit_code() == 0) begin
          $display("Test Point Pass!");
`ifdef USE_IFU
          report_branch_stats();
          report_l0_stats();
          report_bubble_stats();
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
    $display("        CTRL stall=%b muldiv_stall=%b flush_if=%b flush_ex=%b branched=%b",
             dut.Core_cpu.stall, dut.Core_cpu.muldiv_stall, dut.Core_cpu.flush_if_id,
             dut.Core_cpu.flush_id_ex, dut.Core_cpu.branched);
    $display("        MULDIV ex_is_muldiv=%b valid_i=%b ready=%b busy=%b | v1/2/3=%b%b%b p1=%08x p2=%08x p3=%08x",
             dut.Core_cpu.ex_is_muldiv, dut.Core_cpu.U_MUL_DIV.valid_i,
             dut.Core_cpu.muldiv_ready, dut.Core_cpu.muldiv_busy,
             dut.Core_cpu.U_MUL_DIV.mul_valid_stage1, dut.Core_cpu.U_MUL_DIV.mul_valid_stage2,
             dut.Core_cpu.U_MUL_DIV.mul_valid_stage3,
             dut.Core_cpu.U_MUL_DIV.mul_result_stage1[31:0],
             dut.Core_cpu.U_MUL_DIV.mul_result_stage2[31:0],
             dut.Core_cpu.U_MUL_DIV.mul_result_stage3[31:0]);
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
  // 刻意不做 slot 比较: ipctrl 的 slot 输入端口经分层引用读出来像"只取低位"
  // (lastidx 与它恒差 2), 不可信. 而 dir/tgt/typ 三桶之和应当精确等于
  // "有命中的 invalidate 数" —— 这本身就是对"编译进 simv 的 l0_correct 究竟
  // 有没有 slot 项"的检验.
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
          b_raw_novld = 0, b_raw_muldiv = 0, b_raw_loaduse = 0;
  integer b_nf_reissue = 0, b_nf_bpread = 0, b_nf_frontend = 0, b_nf_other = 0;

  wire c_flush = dut.Core_cpu.flush_if_id | dut.Core_cpu.ifu_idu_flush;
  wire c_stall = dut.Core_cpu.stall;

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
    if (dut.Core_cpu.muldiv_stall)    b_raw_muldiv <= b_raw_muldiv + 1;
    if (dut.Core_cpu.stall & ~dut.Core_cpu.muldiv_stall)
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
      $display("  原始计数(不互斥): init=%0d stall=%0d(load-use %0d / muldiv %0d) flush_if_id=%0d ifu_idu_flush=%0d !inst0_vld=%0d",
               b_raw_init, b_raw_stall, b_raw_loaduse, b_raw_muldiv,
               b_raw_flush, b_raw_iflush, b_raw_novld);
      $display("=============================================");
    end
  endtask
`endif
endmodule
