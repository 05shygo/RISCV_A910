// ===========================================================================
// tb/npu/tb_npu_loop.sv —— 里程碑 1 主判据的专用测试台
// ===========================================================================
// 跑法:  make npu-run TEST=npu_loop MAX_CYCLES=200000
//
// 【为什么不用主 difftest 流程】
//   黄金模型不知道 NPU 的存在, 而 NPU 的完成时刻不可能被"逐条指令比对"的
//   模型跟踪 —— 轮询循环在模型里第 1 圈就退出、在 DUT 里要转 N 圈, pc 序列
//   必然发散. 所以主判据走这条**直接看信号**的路; difftest 那条路留给
//   npu_smoke (它把轮询换成固定延时, 模型按预期值应答).
//
// 【判据】四条, 缺一不可:
//   1. u_bridge.monitor_passed == 0xBEEF   —— CPU 自己的全部检查都过了
//   2. u_bridge.dig_reg      == 0xCAFEBABE —— 这个值只可能来自 NPU
//        (CPU 程序从没往 DIG 写过这个数; 它出现在这里, 只能是 CPU 从 NPU 的
//         DTCM 读回来再转手写进去的)
//   3. io_halted == 1 且 io_fault == 0     —— NPU 确实跑完且没报错
//   4. 周期数 < MAX_CYCLES                  —— 没有挂死
//
// 判据 2 是这套检查的关键: 判据 1 只证明"CPU 认为自己对了", 判据 2 才是
// **独立于 CPU 自述**的证据 —— DIG 寄存器的值由 TB 直接观测, CPU 无法伪造.
//
// ⚠️ 本 TB 不定义 FSDB 也能跑. 要看波形加 +define+FSDB, 但注意 RvvCoreMiniAxi
//    内联了整个 RVV 后端 (近十万行), 全量 dump 会非常大 —— 所以只 dump
//    tb + 两个实例的 scope.
// ===========================================================================

`timescale 1ns / 1ps

module tb_npu_loop;

  logic clk = 0;
  logic rst = 1;
  integer cycles = 0;
  integer max_cycles = 200000;

  always #5 clk = ~clk;   // 100 MHz

  miniRV_SoC dut (
      .fpga_rst (rst),
      .fpga_clk (clk),
      .debug_wb_have_inst (),
      .debug_wb_pc        (),
      .debug_wb_ena       (),
      .debug_wb_reg       (),
      .debug_wb_value     ()
  );

  // miniRV_SoC 内部的 cpu_clk 是从 fpga_clk 初值赋过去的普通变量, 不是
  // 连续赋值 —— 和主 TB 一样用 force 让它跟着 TB 时钟走.
  initial begin
    force dut.cpu_clk  = clk;
    force dut.fpga_clk = clk;
  end

`ifdef FSDB
  string wave_name;
  initial begin
    if (!$value$plusargs("WAVE=%s", wave_name)) wave_name = "npu_loop";
    $fsdbDumpfile({"waveform/", wave_name, ".fsdb"});
    // 只 dump 必要的 scope —— RvvCoreMiniAxi 内联了整个 RVV 后端,
    // 全量 dump (0, tb) 会产出几十 GB 的波形.
    $fsdbDumpvars(0, tb_npu_loop.dut.u_bridge);
    $fsdbDumpvars(0, tb_npu_loop.dut.u_npu_bridge);
    $fsdbDumpvars(0, tb_npu_loop.dut.u_npu_core);
  end
`endif

  initial begin
    if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) ;
  end

  always @(posedge clk) cycles <= cycles + 1;

  initial begin
    repeat (20) @(posedge clk);
    rst = 0;
    $display("[npu] 复位释放, 开始执行");
  end

  // -------------------------------------------------------------------------
  // 完成判定
  // -------------------------------------------------------------------------
  logic done = 0;

  always @(posedge clk) begin
    if (!done && dut.u_bridge.monitor_passed == 32'h0000_BEEF) begin
      done = 1;
      check_and_finish();
    end
    else if (!done && dut.u_bridge.monitor_failed == 32'h0000_DEAD) begin
      done = 1;
      // CPU 自己判定失败. 把可观测的状态全打出来, 便于定位是哪一步断的.
      $display("========================================================");
      $display("NPU M1 FAIL: CPU 程序报失败 (MONITOR+4 = 0xDEAD)");
      $display("  周期数            = %0d", cycles);
      $display("  NPU io_halted     = %0b", dut.u_npu_core.u_core.io_halted);
      $display("  NPU io_fault      = %0b", dut.u_npu_core.u_core.io_fault);
      $display("  NPU io_wfi        = %0b", dut.u_npu_core.u_core.io_wfi);
      $display("  STATUS 寄存器     = 0x%08x", dut.u_npu_bridge.rdata_reg);
      $display("  桥 waddr/raddr    = 0x%05x / 0x%05x", dut.u_npu_bridge.waddr, dut.u_npu_bridge.raddr);
      $display("  桥 err/ovf        = %0b / %0b", dut.u_npu_bridge.err, dut.u_npu_bridge.ovf);
      $display("  桥 erraddr        = 0x%08x", dut.u_npu_bridge.erraddr);
      $display("  桥写 FSM / 读 FSM = %0d / %0d", dut.u_npu_bridge.wstate, dut.u_npu_bridge.rstate);
      $display("  DIG 寄存器        = 0x%08x", dut.u_bridge.dig_reg);
      $display("  aresetn (CTL[0])  = %0b", dut.u_npu_bridge.ctl[0]);
      $display("========================================================");
      $fatal(1, "NPU M1 FAIL");
    end
    else if (!done && cycles > max_cycles) begin
      done = 1;
      $display("========================================================");
      $display("NPU M1 FAIL: 超时 (%0d 周期)", max_cycles);
      $display("  程序是否跑起来了? CPU 停在 PC 附近的迹象:");
      $display("  NPU io_halted     = %0b", dut.u_npu_core.u_core.io_halted);
      $display("  NPU io_fault      = %0b", dut.u_npu_core.u_core.io_fault);
      $display("  桥 waddr/raddr    = 0x%05x / 0x%05x", dut.u_npu_bridge.waddr, dut.u_npu_bridge.raddr);
      $display("  桥 err/ovf        = %0b / %0b", dut.u_npu_bridge.err, dut.u_npu_bridge.ovf);
      $display("  桥写 FSM / 读 FSM = %0d / %0d", dut.u_npu_bridge.wstate, dut.u_npu_bridge.rstate);
      $display("  aresetn (CTL[0])  = %0b", dut.u_npu_bridge.ctl[0]);
      $display("========================================================");
      $fatal(1, "NPU M1 FAIL: timeout");
    end
  end

  task automatic check_and_finish();
    int errs = 0;

    $display("========================================================");
    $display("NPU M1 判据检查 (周期 %0d)", cycles);

    // 判据 1: CPU 自检通过
    if (dut.u_bridge.monitor_passed == 32'h0000_BEEF)
      $display("  [1/4] PASS  CPU 自检通过 (MONITOR = 0xBEEF)");
    else begin
      $display("  [1/4] FAIL  CPU 自检未通过 (MONITOR = 0x%08x)", dut.u_bridge.monitor_passed);
      errs++;
    end

    // 判据 2: 独立证据 —— DIG 里的值只能来自 NPU
    if (dut.u_bridge.dig_reg == 32'hCAFE_BABE)
      $display("  [2/4] PASS  DIG = 0xCAFEBABE (值来自 NPU 的 DTCM)");
    else begin
      $display("  [2/4] FAIL  DIG = 0x%08x, 期望 0xCAFEBABE", dut.u_bridge.dig_reg);
      errs++;
    end

    // 判据 3: NPU 确实跑完且无错
    if (dut.u_npu_core.u_core.io_halted === 1'b1 && dut.u_npu_core.u_core.io_fault === 1'b0)
      $display("  [3/4] PASS  NPU io_halted=1, io_fault=0");
    else begin
      $display("  [3/4] FAIL  NPU io_halted=%0b, io_fault=%0b",
               dut.u_npu_core.u_core.io_halted, dut.u_npu_core.u_core.io_fault);
      errs++;
    end

    // 判据 4: 周期数在预算内
    if (cycles < max_cycles)
      $display("  [4/4] PASS  周期数 %0d < %0d", cycles, max_cycles);
    else begin
      $display("  [4/4] FAIL  周期数 %0d >= %0d", cycles, max_cycles);
      errs++;
    end

    $display("--------------------------------------------------------");
    if (errs == 0) begin
      $display("NPU M1 PASS");
      $display("========================================================");
      $finish;
    end else begin
      $display("NPU M1 FAIL: %0d 项判据未过", errs);
      $display("========================================================");
      $fatal(1, "NPU M1 FAIL");
    end
  endtask

endmodule
