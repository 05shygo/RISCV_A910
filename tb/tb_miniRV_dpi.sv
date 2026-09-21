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
          $finish;
        end else begin
          $display("Test Point Failed");
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
endmodule
