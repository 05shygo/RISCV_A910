`timescale 1ns / 1ps

// ===========================================================================
// tb/a910/tb_a910_difftest.sv —— A910_cpu (乱序多发射整核) 的 **difftest 台**
// ===========================================================================
// 【为什么要有它】冒烟台 (`tb_a910_smoke.sv`) 的判据是"看见 x17=93 且 a0==0",
//   而 riscv-tests 的用例把 `fail` 块紧挨着排在 `pass` 块前面 —— `ecall` 在
//   A910 顶层**不停机**(见下), 于是"撞 fail → 落穿进 pass"会静默变成 PASS。
//   实测: `beq` 用例的分支根本没生效(0x10 的 beq 没跳, PC 直接跑到 fail),
//   冒烟台照样报 `=== A910 SMOKE: PASS ===`。**顺序核的用例不能用冒烟台判**。
//
// 【判据从哪来】复用仓库现成的黄金模型 (`golden_model/` + `dpi/dpi_shim.c`)。
//   它是**提交步进**的: 每调用一次 `gm_check_step()` 才执行一条架构指令, 并把它
//   (pc/ena/reg/value) 与 DUT 报的这条逐位比对; `have_inst=0` 时原地不动。
//   A910 顶层那 15 根 `dbg_commit_*` 正是为此准备的接入点 (`RTU.v:383-392`)。
//   ⇒ 这里把三个退休槽**按 0→1→2(程序序)**逐拍喂进去, 一条一条比。
//
// 【收尾】黄金模型自己判: `cpu_poll_halt()` 在 `cpu.npc` 指到一条 ecall 且
//   `mtvec==0` 时停机, 用当时的 a0 定 pass/fail (`emu.c: cpu_poll_halt`)。
//   这正好是 riscv-tests 的约定, 而且**不受"落穿"影响** —— 它停在第一个 ecall。
//
// 【为什么不能只看 a0】见上: 分支错了、指令丢了, a0 一样可能是 0。
//   逐条比对的意义就在于**报出第一个失配点**, 而不是只给一个终局结论。
//
// 【运行】
//   make a910-difftest TEST=addi
//   make a910-difftest TEST=addi A910_DT_ARGS=+TRACE     # 打全部退休流
// ===========================================================================
module tb_a910_difftest;

  // -------------------------------------------------------------------------
  // 黄金模型 (DPI-C): 与 tb_miniRV_dpi.sv 用的是同一份，参数也一样
  // -------------------------------------------------------------------------
  import "DPI-C" context function void gm_init(input string path);
  import "DPI-C" context function int  gm_check_step(input int dut_wb_have_inst,
                                                     input int dut_wb_pc,
                                                     input int dut_wb_ena,
                                                     input int dut_wb_reg,
                                                     input int dut_wb_value,
                                                     input int dut_wb_irq_safe);
  import "DPI-C" context function int  gm_halted();
  import "DPI-C" context function int  gm_exit_code();
  import "DPI-C" context function void gm_set_timer(input int lo, input int hi);

  // -------------------------------------------------------------------------
  // 时钟 / 复位
  // -------------------------------------------------------------------------
  reg clk = 0;
  reg rst = 1;                       // 高有效, 与 A910_cpu 同极性
  always #5 clk = ~clk;              // 100 MHz (配 -timescale=1ns/1ps)

  integer cycles = 0;
  always @(posedge clk) cycles = cycles + 1;

  integer max_cycles = 200000;

  // -------------------------------------------------------------------------
  // A910_cpu ↔ AXI 从机内存 (与冒烟台同一块板子)
  // -------------------------------------------------------------------------
  wire [31:0]  biu_pad_araddr;
  wire [3:0]   biu_pad_arid;
  wire [1:0]   biu_pad_arlen;
  wire [2:0]   biu_pad_arsize;
  wire [1:0]   biu_pad_arburst;
  wire [3:0]   biu_pad_arcache;
  wire [2:0]   biu_pad_arprot;
  wire         biu_pad_arvalid;
  wire         pad_biu_arready;

  wire [127:0] pad_biu_rdata;       // ← 由 TB 驱动 (TIMER 那一路就地替换, 见下)
  wire [127:0] pad_biu_rdata_mem;   // AXI 从机 (内存) 的原始读数据
  wire [3:0]   pad_biu_rid;
  wire         pad_biu_rlast;
  wire [1:0]   pad_biu_rresp;
  wire         pad_biu_rvalid;
  wire         biu_pad_rready;

  wire [31:0]  biu_pad_awaddr;
  wire [3:0]   biu_pad_awid;
  wire [1:0]   biu_pad_awlen;
  wire [2:0]   biu_pad_awsize;
  wire [1:0]   biu_pad_awburst;
  wire [3:0]   biu_pad_awcache;
  wire [2:0]   biu_pad_awprot;
  wire         biu_pad_awvalid;
  wire         pad_biu_awready;

  wire [127:0] biu_pad_wdata;
  wire [15:0]  biu_pad_wstrb;
  wire         biu_pad_wlast;
  wire         biu_pad_wvalid;
  wire         pad_biu_wready;

  wire [3:0]   pad_biu_bid;
  wire [1:0]   pad_biu_bresp;
  wire         pad_biu_bvalid;
  wire         biu_pad_bready;

  axi_slave_128 #(.MEM_BLOCKS(4096)) u_mem (
    .clk     (clk),
    .rst     (rst),

    .araddr  (biu_pad_araddr),   .arid    (biu_pad_arid),
    .arlen   (biu_pad_arlen),    .arsize  (biu_pad_arsize),
    .arburst (biu_pad_arburst),  .arvalid (biu_pad_arvalid),
    .arready (pad_biu_arready),

    .rdata   (pad_biu_rdata_mem), .rid    (pad_biu_rid),
    .rlast   (pad_biu_rlast),    .rresp   (pad_biu_rresp),
    .rvalid  (pad_biu_rvalid),   .rready  (biu_pad_rready),

    .awaddr  (biu_pad_awaddr),   .awid    (biu_pad_awid),
    .awlen   (biu_pad_awlen),    .awsize  (biu_pad_awsize),
    .awburst (biu_pad_awburst),  .awvalid (biu_pad_awvalid),
    .awready (pad_biu_awready),

    .wdata   (biu_pad_wdata),    .wstrb   (biu_pad_wstrb),
    .wlast   (biu_pad_wlast),    .wvalid  (biu_pad_wvalid),
    .wready  (pad_biu_wready),

    .bid     (pad_biu_bid),      .bresp   (pad_biu_bresp),
    .bvalid  (pad_biu_bvalid),   .bready  (biu_pad_bready)
  );

  // -------------------------------------------------------------------------
  // TIMER 外设 (0xFFFFF040) —— A910_cpu 顶层**没有外设**, 总线上的 TIMER 由本 TB 现造
  //
  // 【为什么必须有】CoreMark 的计时走 `*(volatile ee_u32 *)0xFFFFF040`
  //   (coremark/riscv-port/core_portme.h 的 CM_TIMER_ADDR)。而 AXI 从机只按地址低位
  //   索引内存 (0xFFFFF040 → 块 0xF04) ⇒ 两次读数恒等 ⇒ `vcycles = end - start = 0`
  //   ⇒ CoreMark 只报 "Average cycles/iteration: 0 (timer did not advance)", 拿不到
  //   分数。这里就地把该地址的读**换成 TB 的周期计数器** —— 与顺序核那条路
  //   (`mySoC/perip_bridge.v` 的 mtime 每拍 +1) 同义: **1 tick = 1 周期**。
  //
  // ⚠️ 只认 +0x00 (mtime[31:0]): +0x04/+0x08/+0x0C 别一起顶掉 —— 模型的
  //    `timer_read` 对那三档返回的是它自己的寄存器, 顶多了反而对不上。
  // ⚠️ 模型那一侧靠下面 difftest 主体里的 `gm_set_timer(退休包的值)` 对齐, 两边
  //    读到的必须是同一个数, 否则第一条 tick 读就报失配。
  // ⚠️ 用 `u_mem.rd_addr` 而不是 `biu_pad_araddr`: 后者只在 AR 握手那拍有效, 而
  //    rdata 是后面几拍才采的 (从机内部的 rd_addr 才是"这一拍"的地址)。
  // -------------------------------------------------------------------------
  wire rd_is_timer = (u_mem.rd_addr[31:4] == 28'hFFFFF04) && (u_mem.rd_addr[3:0] == 4'h0);
  assign pad_biu_rdata = rd_is_timer ? {96'b0, cycles[31:0]} : pad_biu_rdata_mem;

  A910_cpu dut (
    .clk (clk),
    .rst (rst),

    .biu_pad_araddr (biu_pad_araddr), .biu_pad_arid   (biu_pad_arid),
    .biu_pad_arlen  (biu_pad_arlen),  .biu_pad_arsize (biu_pad_arsize),
    .biu_pad_arburst(biu_pad_arburst),.biu_pad_arcache(biu_pad_arcache),
    .biu_pad_arprot (biu_pad_arprot), .biu_pad_arvalid(biu_pad_arvalid),
    .pad_biu_arready(pad_biu_arready),

    .pad_biu_rdata  (pad_biu_rdata),  .pad_biu_rid    (pad_biu_rid),
    .pad_biu_rlast  (pad_biu_rlast),  .pad_biu_rresp  (pad_biu_rresp),
    .pad_biu_rvalid (pad_biu_rvalid), .biu_pad_rready (biu_pad_rready),

    .biu_pad_awaddr (biu_pad_awaddr), .biu_pad_awid   (biu_pad_awid),
    .biu_pad_awlen  (biu_pad_awlen),  .biu_pad_awsize (biu_pad_awsize),
    .biu_pad_awburst(biu_pad_awburst),.biu_pad_awcache(biu_pad_awcache),
    .biu_pad_awprot (biu_pad_awprot), .biu_pad_awvalid(biu_pad_awvalid),
    .pad_biu_awready(pad_biu_awready),

    .biu_pad_wdata  (biu_pad_wdata),  .biu_pad_wstrb  (biu_pad_wstrb),
    .biu_pad_wlast  (biu_pad_wlast),  .biu_pad_wvalid (biu_pad_wvalid),
    .pad_biu_wready (pad_biu_wready),

    .pad_biu_bid    (pad_biu_bid),    .pad_biu_bresp  (pad_biu_bresp),
    .pad_biu_bvalid (pad_biu_bvalid), .biu_pad_bready (biu_pad_bready)
  );

  // -------------------------------------------------------------------------
  // 【雷】force 掉未驱动的线 —— 与冒烟台同一套, 理由见 tb_a910_smoke.sv 那段长注
  //   (CSR 没接 ⇒ trap/mret 相关全 0; `iu_btb_*` 进 IFU 的 GHR 恢复。
  //    `int_pending` 进 RTU_commit 的**组合前缀链**, 不钉死则第一条退休那拍整个
  //    RTU 变 X。)
  // -------------------------------------------------------------------------
  initial begin
    force dut.int_pending     = 1'b0;
    force dut.csr_trap_vector = 32'b0;
    force dut.csr_mepc        = 32'b0;
    force dut.csr_rdata       = 32'b0;
    force dut.iu_btb_chk      = 25'b0;
    force dut.iu_btb_taken    = 1'b0;
    force dut.iu_btb_is_cond  = 1'b0;
    force dut.cmplt_vld1      = 1'b0;
    force dut.cmplt_iid1      = 7'b0;
    force dut.cmplt_vld2      = 1'b0;
    force dut.cmplt_iid2      = 7'b0;
  end

  // -------------------------------------------------------------------------
  // 【difftest 主体】逐拍把退休包按 0→1→2 喂给黄金模型
  // -------------------------------------------------------------------------
  integer retired   = 0;      // 累计退休条数 (自数, `rtu_retire_cnt` 只是当拍条数)
  integer halted    = 0;
  integer exit_code = 0;
  integer bad       = 0;
  reg     trace_on  = 0;

  wire trace_en = $test$plusargs("TRACE");

  // 一颗 3 发射核的退休包最多 3 条, 槽 0 最旧 —— 必须按程序序喂, 否则参考模型
  // 会拿着后一条的 pc 去比对前一条的值, 报出来的失配点全错位。
  always @(posedge clk) begin
    if (!rst && !halted) begin
      // ⚠️ 2026-10-13: `rtu_retire_cnt` 是核内**当拍**的退休条数, 而下面三个槽
      //    来自 `dbg_commit_*` —— 顶层现在给这三根加了"等 LSU 写回落地"的延迟线
      //    (见 A910_cpu.sv), 两者**不再同拍**。探针的"几条/哪些槽"必须统一取自
      //    延迟后的 `dbg_commit_vld*`, 否则打出来的 pc 与条数对不上。
      if (trace_on && |{dut.dbg_commit_vld2, dut.dbg_commit_vld1, dut.dbg_commit_vld0}) begin
        $display("      T%0d 退休 %b%b%b 条", cycles,
                 dut.dbg_commit_vld2, dut.dbg_commit_vld1, dut.dbg_commit_vld0);
        if (dut.dbg_commit_vld0)
          $display("        slot0 pc=%08x ena=%b x%0d<=%08x", dut.dbg_commit_pc0,
                   dut.dbg_commit_ena0, dut.dbg_commit_reg0, dut.dbg_commit_value0);
        if (dut.dbg_commit_vld1)
          $display("        slot1 pc=%08x ena=%b x%0d<=%08x", dut.dbg_commit_pc1,
                   dut.dbg_commit_ena1, dut.dbg_commit_reg1, dut.dbg_commit_value1);
        if (dut.dbg_commit_vld2)
          $display("        slot2 pc=%08x ena=%b x%0d<=%08x", dut.dbg_commit_pc2,
                   dut.dbg_commit_ena2, dut.dbg_commit_reg2, dut.dbg_commit_value2);
      end

      // ---------------------------------------------------------------------
      // ⚠️ 计时器对齐 (2026-10-14, 为了 CoreMark 能跑在 A910 上):
      //    模型是**提交步进**的, 它自己的 mtime 不会走 —— 之前它恒为 0, 于是任何
      //    "读 TIMER" 的 load 在模型里都读回 0。顺序核那条路是靠 TB 每拍
      //    `gm_set_timer(mtime_d1)` 推的 (延迟一拍匹配 MEM 级读点), 而 **A910 是
      //    乱序核**: 一条 load 从读到提交隔着几拍到几十拍不等 (设备读还要过 BIU),
      //    固定延迟必然对不上。
      //    改法: 喂每条指令**之前**, 把模型计时器设成**这条指令自己带回来的值**
      //    (`dbg_commit_value`) —— 于是 "读 TIMER 的 load" 在模型里读到的正是 DUT
      //    读到的那个数。对非 load 指令设它无害: 模型只在执行 TIMER load 时读
      //    mtime, 而那一定是由那条 load 自己的值刚设好的 (三个槽各自设、各自喂)。
      // ---------------------------------------------------------------------
      if (dut.dbg_commit_vld0) begin
        retired = retired + 1;
        // `irq_safe` 恒 1: 本台不接 CSR/中断 (csr_* 全 force 0), 中断门永远关着,
        // 这一位在模型里只用于 `cpu_take_irq()` 的门控。
        gm_set_timer(dut.dbg_commit_value0, 32'd0);
        if (gm_check_step(1, dut.dbg_commit_pc0, dut.dbg_commit_ena0,
                          dut.dbg_commit_reg0, dut.dbg_commit_value0, 1) != 0) begin
          bad = 1;
          $display("  ❌ 第 %0d 条退休 (slot0, T%0d) 起与黄金模型不一致", retired, cycles);
        end
      end
      if (dut.dbg_commit_vld1 && !bad) begin
        retired = retired + 1;
        gm_set_timer(dut.dbg_commit_value1, 32'd0);
        if (gm_check_step(1, dut.dbg_commit_pc1, dut.dbg_commit_ena1,
                          dut.dbg_commit_reg1, dut.dbg_commit_value1, 1) != 0) begin
          bad = 1;
          $display("  ❌ 第 %0d 条退休 (slot1, T%0d) 起与黄金模型不一致", retired, cycles);
        end
      end
      if (dut.dbg_commit_vld2 && !bad) begin
        retired = retired + 1;
        gm_set_timer(dut.dbg_commit_value2, 32'd0);
        if (gm_check_step(1, dut.dbg_commit_pc2, dut.dbg_commit_ena2,
                          dut.dbg_commit_reg2, dut.dbg_commit_value2, 1) != 0) begin
          bad = 1;
          $display("  ❌ 第 %0d 条退休 (slot2, T%0d) 起与黄金模型不一致", retired, cycles);
        end
      end

      // 模型在"下一条是 ecall"时自己停下 —— 用当时的 a0 定 pass/fail。
      if (gm_halted()) begin
        halted    = 1;
        exit_code = gm_exit_code();
      end
    end
  end

  // 失配即停: 再跑下去只会刷屏, 而且 PC 早就跑飞了。
  // `$fatal(1,..)` 的退出码靠 `-exitstatus` 才传得出去 (见 Makefile 注释)。
  always @(posedge clk) if (bad) begin
    $display("");
    $display("  ⚠️ 失配前的累计退休 = %0d 条, 本拍 = T%0d", retired - 1, cycles);
    $display("     上面的 REFERENCE/MYCPU 对照就是第一个不一致点 (dpi_shim.c 打的)");
    // 带诊断探针时多等一拍: 探针是另一个 always 块, 同一拍谁先跑没有保证,
    // 先 $fatal 会把失配那一拍的现场吞掉。
    if ($test$plusargs("PROBE_WB") || trace_en) @(posedge clk);
    // 【临时诊断】+NOSTOP: 失配不停, 继续跑到 MAX_CYCLES —— 看后面到底能不能自愈
    if (!$test$plusargs("NOSTOP")) $fatal(1, "a910 difftest mismatch");
  end

  // -------------------------------------------------------------------------
  // 主流程
  // -------------------------------------------------------------------------
  integer i;
  reg [8*256:1] test_name;

  // -------------------------------------------------------------------------
  // 【临时诊断】递交代 vs 写回口 vs PRF 读口 —— `A910_DT_ARGS=+PROBE_WB`
  //
  //  冒烟台报的失配是"值不对"(pc/ena/reg 都对), 有两条嫌疑:
  //    (1) 执行单元算错 (写回口的数据本身就是错的);
  //    (2) 提交读路取错 (写回对, 但 `dbg_commit_value` 没取到它) —— 包括
  //        本顶层新加的旁路挑错了写口。
  //  这里把三样同拍拍下来: 写口 (vld/号/数据) / 旁路命中 / RTU 的读地址 +
  //  **旁路前的原始读值**。一眼能分开 (1) 和 (2)。
  // -------------------------------------------------------------------------
  integer wb_probe_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_WB") && wb_probe_lines < 400
        && (dut.dbg_commit_vld0 || dut.dbg_commit_vld1 || dut.dbg_commit_vld2
            || dut.iu_idu_ex2_pipe0_wb_preg_vld || dut.iu_idu_ex2_pipe1_wb_preg_vld
            || dut.iu_idu_ex2_pipe2_wb_preg_vld || dut.lsu_idu_wb_pipe3_wb_preg_vld)) begin
      wb_probe_lines = wb_probe_lines + 1;
      $display("  [WB] T%0d 退休: s0=%b pc=%08x r%0d<=%08x | s1=%b pc=%08x r%0d<=%08x | s2=%b pc=%08x r%0d<=%08x",
               cycles,
               dut.dbg_commit_vld0, dut.dbg_commit_pc0, dut.dbg_commit_reg0, dut.dbg_commit_value0,
               dut.dbg_commit_vld1, dut.dbg_commit_pc1, dut.dbg_commit_reg1, dut.dbg_commit_value1,
               dut.dbg_commit_vld2, dut.dbg_commit_pc2, dut.dbg_commit_reg2, dut.dbg_commit_value2);
      $display("       写口: p0=%b#%0d=%08x | p1=%b#%0d=%08x | p2=%b#%0d=%08x | p3=%b#%0d=%08x",
               dut.iu_idu_ex2_pipe0_wb_preg_vld, dut.iu_idu_ex2_pipe0_wb_preg_dupx,
               dut.iu_idu_ex2_pipe0_wb_preg_data,
               dut.iu_idu_ex2_pipe1_wb_preg_vld, dut.iu_idu_ex2_pipe1_wb_preg_dupx,
               dut.iu_idu_ex2_pipe1_wb_preg_data,
               dut.iu_idu_ex2_pipe2_wb_preg_vld, dut.iu_idu_ex2_pipe2_wb_preg_dupx,
               dut.iu_idu_ex2_pipe2_wb_preg_data,
               dut.lsu_idu_wb_pipe3_wb_preg_vld, dut.lsu_idu_wb_pipe3_wb_preg,
               dut.lsu_idu_wb_pipe3_wb_preg_data);
      // expand 独热与命中位: 旁路就是按它选的, 挑错写口会直接看在这上面
      $display("       expand命中: wb0=%b wb1=%b wb2=%b wb3=%b (低 20 位) | %020x %020x %020x %020x",
               dut.prf_wb0_hot[0], dut.prf_wb1_hot[0], dut.prf_wb2_hot[0], dut.prf_wb3_hot[0],
               dut.iu_idu_ex2_pipe0_wb_preg_expand[19:0],
               dut.iu_idu_ex2_pipe1_wb_preg_expand[19:0],
               dut.iu_idu_ex2_pipe2_wb_preg_expand[19:0],
               dut.lsu_idu_wb_pipe3_wb_preg_expand[19:0]);
      $display("       读口: raddr=%0d,%0d,%0d | raw=%08x,%08x,%08x | 旁路后=%08x,%08x,%08x",
               dut.rtu_preg_raddr0, dut.rtu_preg_raddr1, dut.rtu_preg_raddr2,
               dut.idu_rtu_preg_rdata_raw0, dut.idu_rtu_preg_rdata_raw1,
               dut.idu_rtu_preg_rdata_raw2,
               dut.rtu_preg_rdata0, dut.rtu_preg_rdata1, dut.rtu_preg_rdata2);
    end
  end

  // -------------------------------------------------------------------------
  // 【临时诊断】重定向前后 IFU↔IDU 手上各有什么 —— `A910_DT_ARGS=+PROBE_IFU`
  //   追"跳转目标那条指令不见了": 重定向那拍起 12 拍逐拍打 IFU 交的指令、
  //   IBUF 的计数/头部、IDU 报收几条、以及三条 vld。
  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // 【临时诊断】分支那条路 (BIQ → BEU) —— `A910_DT_ARGS=+PROBE_BEU`
  //   追"分支跳了却没改 PC": 看分支到底有没有从 BIQ 发射、BEU 算出的
  //   真实后继/预测后继/误预测位各是什么。
  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // 【临时诊断】派遣流 (IDU → RTU) —— `A910_DT_ARGS=+PROBE_DISP`
  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // 【临时诊断】preg 分配握手逐拍 —— `A910_DT_ARGS=+PROBE_PREG`
  //   RTU 侧给出号 (tap), IDU 侧 IR/IS 两级各拿到什么号。
  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // 【临时诊断】p0 (常量 0 号) 什么时候进了自由池 —— `A910_DT_ARGS=+PROBE_P0`
  //   一旦 `u_rtu.u_preg.free_vec[0]` 变 1, 就把这一拍所有相关信号打出来:
  //   谁在退休、退的是哪个号、free/release/arch 三根各是什么。
  // -------------------------------------------------------------------------
  integer p0_lines = 0;
  reg     p0_seen  = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_P0") && p0_lines < 60) begin
      if (dut.u_rtu.u_preg.free_vec[0] === 1'b1 && !p0_seen) begin
        p0_seen = 1;
        $display("  ❌ [P0] T%0d ** preg0 (常量 0 号) 进入了自由池 **", cycles);
      end
      if (cycles >= 96) begin
        p0_lines = p0_lines + 1;
        $display("  [P0] T%0d st0=%0d flush=%b | dst=%0d,%0d,%0d old=%0d,%0d,%0d | free_vld=%b kill_vld=%b arch_vld=%b",
                 cycles, dut.u_rtu.u_preg.st[0], dut.u_rtu.u_preg.flush_lvl,
                 dut.u_rtu.u_commit.ret_dst_preg0, dut.u_rtu.u_commit.ret_dst_preg1,
                 dut.u_rtu.u_commit.ret_dst_preg2,
                 dut.u_rtu.u_commit.ret_old_preg0, dut.u_rtu.u_commit.ret_old_preg1,
                 dut.u_rtu.u_commit.ret_old_preg2,
                 dut.u_rtu.u_commit.ret_free_vld, dut.u_rtu.u_commit.ret_kill_vld,
                 dut.u_rtu.u_commit.ret_arch_vld);
      end
    end
  end

  // -------------------------------------------------------------------------
  // 【临时诊断】x4 (lreg 4) 的映射链 vs 冲刷恢复 —— `A910_DT_ARGS=+PROBE_X4`
  //
  //   beq 台 T318: 第二圈 `0x134 addi x4,x4,1` 读出 0 (应为 1)。
  //   冲刷时 IDU 的整张改名表被灌成 RTU 的 AMT (`ct_idu_ir_rt.sv:203`),
  //   所以嫌疑是: **0x13c 回跳那次误预测冲刷来的那拍, AMT[4] 还没更新到
  //   第一圈 0x134 写进去的新号** ⇒ 恢复回旧号 ⇒ 第二圈读回 0x11c 写的 0。
  //   这里把两边的映射 + 判退级的三个槽逐拍并排打出来。
  // -------------------------------------------------------------------------
  integer x4_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_X4") && cycles >= 288 && cycles <= 322
        && x4_lines < 300) begin
      // ---- 改名表的**写口**逐拍: 谁把号写进表里 (含冲刷恢复) ----
      $display("  [RTW] T%0d 写en=%b%b%b lreg=%0d,%0d,%0d dst=%0d,%0d,%0d vld=%b,%b,%b | recov=%b reset=%b stall=%b",
               cycles,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.inst0_write_en,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.inst1_write_en,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.inst2_write_en,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst0_dst_reg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst1_dst_reg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst2_dst_reg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst0_dst_preg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst1_dst_preg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst2_dst_preg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.ctrl_rt_inst0_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.ctrl_rt_inst1_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.ctrl_rt_inst2_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.rt_recover_updt_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.rt_reset_updt_vld,
               dut.u_ct_idu_top.ctrl_ir_stall);
      // ---- ID 级 (交给 IR 的窗口) vs IR 级三条道各是哪条指令 ----
      $display("       ID: pc=%08x,%08x,%08x vld=%b%b%b  →  IR: pc=%08x,%08x,%08x",
               dut.u_ct_idu_top.u_ct_idu_id_dp.id_inst0_pc,
               dut.u_ct_idu_top.u_ct_idu_id_dp.id_inst1_pc,
               dut.u_ct_idu_top.u_ct_idu_id_dp.id_inst2_pc,
               dut.u_ct_idu_top.id_ir_inst0_vld, dut.u_ct_idu_top.id_ir_inst1_vld,
               dut.u_ct_idu_top.id_ir_inst2_vld,
               dut.u_ct_idu_top.dp_ir_inst0_pc[31:0], dut.u_ct_idu_top.dp_ir_inst1_pc[31:0],
               dut.u_ct_idu_top.dp_ir_inst2_pc[31:0]);
      // ---- IFU → IDU 这一拍交了什么 ----
      $display("       IFU: ib_vld=%b pc=%08x,%08x,%08x cnt=%0d head=%0d | IDU acc=%b vld=%b%b%b",
               dut.u_rv32ifu2_top.ib_vld,
               dut.u_rv32ifu2_top.ib_out0[63:32], dut.u_rv32ifu2_top.ib_out1[63:32],
               dut.u_rv32ifu2_top.ib_out2[63:32],
               dut.u_rv32ifu2_top.u_ibuf.cnt_q, dut.u_rv32ifu2_top.u_ibuf.head_q,
               dut.idu_accept_num, dut.idu_inst0_vld, dut.idu_inst1_vld, dut.idu_inst2_vld);
      $display("       IRlreg: lreg=%0d,%0d,%0d dst_vld=%b,%b,%b",
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst0_dst_reg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst1_dst_reg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst2_dst_reg,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst0_dst_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst1_dst_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_rt.dp_rt_inst2_dst_vld);
      // ---- 分配握手: IDU 三路请求 vs RTU 收到的 ren_preg_req ----
      //   2026-10-12 起两边是**同一个逐路向量**（原来是"求和当前缀长度"，会判错，
      //   见 `doc/a910_difftest_zh.md` §6.5）：这两个 `%b` 应当逐位相同。
      $display("       ALLOC: IDU 请求=%b%b%b → ren_preg_req=%b | tap vld=%b%b%b num=%0d,%0d,%0d | free_cnt=%0d",
               dut.idu_rtu_ir_preg2_alloc_vld, dut.idu_rtu_ir_preg1_alloc_vld,
               dut.idu_rtu_ir_preg0_alloc_vld,
               dut.ren_preg_req,
               dut.u_rtu.u_preg.tap_vld0, dut.u_rtu.u_preg.tap_vld1,
               dut.u_rtu.u_preg.tap_vld2,
               dut.u_rtu.u_preg.tap_num0, dut.u_rtu.u_preg.tap_num1,
               dut.u_rtu.u_preg.tap_num2,
               dut.u_rtu.u_preg.free_cnt_q);
      // ---- 派遣流三条道全打 ----
      $display("       派: %b %08x l%0d d%0d o%0d | %b %08x l%0d d%0d o%0d | %b %08x l%0d d%0d o%0d",
               dut.idu_rtu_disp0_vld, dut.idu_rtu_disp0_pc, dut.idu_rtu_disp0_dst_lreg,
               dut.idu_rtu_disp0_dst_preg, dut.idu_rtu_disp0_old_preg,
               dut.idu_rtu_disp1_vld, dut.idu_rtu_disp1_pc, dut.idu_rtu_disp1_dst_lreg,
               dut.idu_rtu_disp1_dst_preg, dut.idu_rtu_disp1_old_preg,
               dut.idu_rtu_disp2_vld, dut.idu_rtu_disp2_pc, dut.idu_rtu_disp2_dst_lreg,
               dut.idu_rtu_disp2_dst_preg, dut.idu_rtu_disp2_old_preg);
      // ---- 发射 (AIQ) 逐拍: 谁在发射、目标号是谁 ----
      if (dut.idu_aiq_sel)
        $display("       AIQ: %08x iid=%0d d%0d src0=%08x src1=%08x",
                 dut.idu_aiq_pc, dut.idu_aiq_iid, dut.idu_aiq_dst_preg,
                 dut.idu_aiq_src0, dut.idu_aiq_src1);
      x4_lines = x4_lines + 1;
      $display("  [X4] T%0d AMT[4]=%0d | RAT[4]=%0d wb=%b | arch=%b lreg=%0d,%0d,%0d dst=%0d,%0d,%0d old=%0d,%0d,%0d free=%b",
               cycles, dut.u_rtu.u_preg.amt[4],
               dut.u_ct_idu_top.x_ct_idu_ir_rt.reg_read_data_raw[4][6:1],
               dut.u_ct_idu_top.x_ct_idu_ir_rt.reg_read_data_raw[4][0],
               dut.u_rtu.u_commit.ret_arch_vld,
               dut.u_rtu.u_commit.ret_dst_lreg0, dut.u_rtu.u_commit.ret_dst_lreg1,
               dut.u_rtu.u_commit.ret_dst_lreg2,
               dut.u_rtu.u_commit.ret_dst_preg0, dut.u_rtu.u_commit.ret_dst_preg1,
               dut.u_rtu.u_commit.ret_dst_preg2,
               dut.u_rtu.u_commit.ret_old_preg0, dut.u_rtu.u_commit.ret_old_preg1,
               dut.u_rtu.u_commit.ret_old_preg2,
               dut.u_rtu.u_commit.ret_free_vld);
      $display("        flush_lvl=%b yy_flush=%b ret_cnt=%b | AMT_flat[4]=%0d",
               dut.u_rtu.u_preg.flush_lvl, dut.rtu_yy_xx_flush,
               dut.rtu_retire_cnt,
               dut.u_rtu.u_preg.amt_flat[6*4 +: 6]);

      // 派遣流里凡是 x4 的 (lreg==4) 全打出来 —— 看两圈分别拿的哪个号
      if (dut.idu_rtu_disp0_vld && dut.idu_rtu_disp0_dst_lreg == 5'd4)
        $display("        [派0] pc=%08x dst_preg=%0d old_preg=%0d",
                 dut.idu_rtu_disp0_pc, dut.idu_rtu_disp0_dst_preg, dut.idu_rtu_disp0_old_preg);
      if (dut.idu_rtu_disp1_vld && dut.idu_rtu_disp1_dst_lreg == 5'd4)
        $display("        [派1] pc=%08x dst_preg=%0d old_preg=%0d",
                 dut.idu_rtu_disp1_pc, dut.idu_rtu_disp1_dst_preg, dut.idu_rtu_disp1_old_preg);
      if (dut.idu_rtu_disp2_vld && dut.idu_rtu_disp2_dst_lreg == 5'd4)
        $display("        [派2] pc=%08x dst_preg=%0d old_preg=%0d",
                 dut.idu_rtu_disp2_pc, dut.idu_rtu_disp2_dst_preg, dut.idu_rtu_disp2_old_preg);
      // ALU 写回: 两条 0x134 分别写到哪个号
      if (dut.u_iu_alu_pipe.wb_preg_vld)
        $display("        [WB ] ALU 写 preg=%0d data=%08x",
                 dut.u_iu_alu_pipe.wb_preg_dupx, dut.u_iu_alu_pipe.wb_preg_data);
    end
  end

  // 【临时诊断】卡死现场逐拍: ROB 队头 + 判退门控 —— `+PROBE_STALL` (窗由 STL_LO/STL_HI 给)
  integer stl_lo = 270, stl_hi = 330;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_STALL") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [STL] T%0d occ=%0d | 队头 pc=%08x,%08x,%08x iid=%0d,%0d,%0d",
               cycles, dut.u_rtu.u_rob.occ,
               dut.u_rtu.u_rob.win_q0[120:89], dut.u_rtu.u_rob.win_q1[120:89],
               dut.u_rtu.u_rob.win_q2[120:89],
               dut.u_rtu.u_rob.win_iid0, dut.u_rtu.u_rob.win_iid1, dut.u_rtu.u_rob.win_iid2);
      $display("        vld=%b,%b,%b cmplt=%b,%b,%b br=%b,%b,%b mispred_flag=%b,%b,%b store=%b,%b,%b",
               dut.u_rtu.u_commit.w0_vld, dut.u_rtu.u_commit.w1_vld, dut.u_rtu.u_commit.w2_vld,
               dut.u_rtu.u_commit.w0_cmplt, dut.u_rtu.u_commit.w1_cmplt, dut.u_rtu.u_commit.w2_cmplt,
               dut.u_rtu.u_commit.w0_br, dut.u_rtu.u_commit.w1_br, dut.u_rtu.u_commit.w2_br,
               dut.u_rtu.u_commit.w0_misp, dut.u_rtu.u_commit.w1_misp, dut.u_rtu.u_commit.w2_misp,
               dut.u_rtu.u_commit.w0_store, dut.u_rtu.u_commit.w1_store, dut.u_rtu.u_commit.w2_store);
      $display("        commit: ok=%b,%b,%b okp=%b,%b,%b ret_cnt=%b | fsm_busy=%b flushing=%b st_q=%b | flush_trig=%b mispred_hit=%b mret=%b trap=%b replay=%b",
               dut.u_rtu.u_commit.ok0, dut.u_rtu.u_commit.ok1, dut.u_rtu.u_commit.ok2,
               dut.u_rtu.u_commit.okp0, dut.u_rtu.u_commit.okp1, dut.u_rtu.u_commit.okp2,
               dut.rtu_retire_cnt,
               dut.u_rtu.fsm_busy, dut.u_rtu.flushing, dut.u_rtu.u_flush.st_q,
               dut.u_rtu.u_commit.flush_trig, dut.u_rtu.u_commit.mispred_hit,
               dut.u_rtu.u_commit.mret_hit, dut.u_rtu.u_commit.trap_hit,
               dut.u_rtu.u_commit.replay_hit);
      $display("        resolve: vld=%b iid=%0d mispred=%b | gate_hold=%b yy_flush=%b | sq: stall=%b rdy=%b,%b,%b | int_pending=%b",
               dut.resolve_vld, dut.resolve_iid, dut.resolve_mispred,
               dut.mispred_hold_q, dut.rtu_yy_xx_flush,
               dut.u_rtu.u_commit.sq_stall, dut.u_rtu.u_commit.sq_rdy0,
               dut.u_rtu.u_commit.sq_rdy1, dut.u_rtu.u_commit.sq_rdy2,
               dut.u_rtu.u_commit.int_pending);
      $display("        LSU: ld_da_vld=%b lsid=%0d secd=%b wb_cmplt_req=%b | ld_wb_inst_vld=%b pipe3_wb_preg_vld=%b | LFB: r_vld=%b r_id=%b id_hit=%b data_vld=%b create_vld=%b entry_id=%0d r_last=%b arready=%b",
               dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld, dut.u_lsu_top.u_lsu_ld_da.ld_da_lsid,
               dut.u_lsu_top.u_lsu_ld_da.ld_da_secd,
               dut.u_lsu_top.ld_da_wb_cmplt_req, dut.u_lsu_top.ld_wb_inst_vld,
               dut.lsu_rtu_wb_pipe3_wb_preg_vld,
               dut.u_lsu_top.u_lsu_lfb.biu_lsu_r_vld, dut.u_lsu_top.u_lsu_lfb.biu_lsu_r_id,
               dut.u_lsu_top.u_lsu_lfb.lfb_biu_r_id_hit,
               dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_vld,
               dut.u_lsu_top.u_lsu_lfb.lfb_data_create_vld,
               dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_id,
               dut.u_lsu_top.u_lsu_lfb.biu_lsu_r_last,
               dut.u_lsu_top.u_lsu_lfb.lfb_biu_arready);
    end
  end

  // 【临时诊断】发射/完成总线 —— `+PROBE_ISS` (窗由 STL_LO/STL_HI 给)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_ISS") && cycles >= stl_lo && cycles <= stl_hi) begin
      if (dut.idu_aiq_sel)
        $display("  [ISS] T%0d ALU: pc=%08x iid=%0d dst=%0d src0=%08x src1=%08x",
                 cycles, dut.idu_aiq_pc, dut.idu_aiq_iid, dut.idu_aiq_dst_preg,
                 dut.idu_aiq_src0, dut.idu_aiq_src1);
      $display("  [LWB] T%0d inst_vld=%b inst_iid=%0d | data_vld=%b data_preg=%0d data_iid=%0d data=%08x | da:req=%b preg=%0d | rb:req=%b preg=%0d | dbg: pc=%08x,%08x,%08x val=%08x,%08x,%08x",
               cycles,
               dut.u_lsu_top.u_lsu_ld_wb.ld_wb_inst_vld, dut.u_lsu_top.u_lsu_ld_wb.ld_wb_iid,
               dut.u_lsu_top.u_lsu_ld_wb.ld_wb_data_vld, dut.u_lsu_top.u_lsu_ld_wb.ld_wb_data_preg,
               dut.u_lsu_top.u_lsu_ld_wb.ld_wb_data_iid,
               dut.lsu_idu_wb_pipe3_wb_preg_data,
               dut.u_lsu_top.u_lsu_ld_wb.ld_da_wb_data_req, dut.u_lsu_top.u_lsu_ld_wb.ld_da_preg,
               dut.u_lsu_top.u_lsu_ld_wb.rb_ld_wb_data_req, dut.u_lsu_top.u_lsu_ld_wb.rb_ld_wb_preg,
               dut.dbg_commit_pc0, dut.dbg_commit_pc1, dut.dbg_commit_pc2,
               dut.dbg_commit_value0, dut.dbg_commit_value1, dut.dbg_commit_value2);
      if (|{dut.cmplt_vld6, dut.cmplt_vld5, dut.cmplt_vld4, dut.cmplt_vld3,
            dut.cmplt_vld2, dut.cmplt_vld1, dut.cmplt_vld0})
        $display("  [CMP] T%0d cmplt=%b%b%b%b%b%b%b iid=%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                 cycles, dut.cmplt_vld6, dut.cmplt_vld5, dut.cmplt_vld4, dut.cmplt_vld3,
                 dut.cmplt_vld2, dut.cmplt_vld1, dut.cmplt_vld0,
                 dut.cmplt_iid0, dut.cmplt_iid1, dut.cmplt_iid2, dut.cmplt_iid3,
                 dut.cmplt_iid4, dut.cmplt_iid5, dut.cmplt_iid6);
      if (dut.lsu_idu_wb_pipe3_wb_preg_vld_dupx || dut.iu_idu_ex2_pipe0_wb_preg_vld_dupx
          || dut.iu_idu_ex2_pipe1_wb_preg_vld_dupx || dut.iu_idu_ex2_pipe2_wb_preg_vld_dupx)
        $display("  [WB ] T%0d 写回: LSU_p3=%b#%0d | IU_p0=%b#%0d p1=%b#%0d p2=%b#%0d",
                 cycles, dut.lsu_idu_wb_pipe3_wb_preg_vld_dupx,
                 dut.lsu_idu_wb_pipe3_wb_preg,
                 dut.iu_idu_ex2_pipe0_wb_preg_vld_dupx, dut.iu_idu_ex2_pipe0_wb_preg_dupx,
                 dut.iu_idu_ex2_pipe1_wb_preg_vld_dupx, dut.iu_idu_ex2_pipe1_wb_preg_dupx,
                 dut.iu_idu_ex2_pipe2_wb_preg_vld_dupx, dut.iu_idu_ex2_pipe2_wb_preg_dupx);
    end
  end

  // 【临时诊断】load 地址/数据流水 —— `+PROBE_LD` (窗用 STL_LO/STL_HI)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LD") && cycles >= stl_lo && cycles <= stl_hi) begin
      if (dut.idu_rtu_disp0_vld && dut.idu_rtu_disp0_pc == 32'h218)
        $display("  [LDI] T%0d 派发 pc=0x218 → iid=%0d", cycles, dut.rtu_disp_iid0);
      if (dut.idu_rtu_disp1_vld && dut.idu_rtu_disp1_pc == 32'h218)
        $display("  [LDI] T%0d 派发 pc=0x218 → iid=%0d", cycles, dut.rtu_disp_iid1);
      if (dut.idu_rtu_disp2_vld && dut.idu_rtu_disp2_pc == 32'h218)
        $display("  [LDI] T%0d 派发 pc=0x218 → iid=%0d", cycles, dut.rtu_disp_iid2);
      $display("  [LFB] T%0d hit_idx=%b set_wkq=%b lsid=%b | wkq=%b pop=%b wakeup=%b | lf_create=%b lf_vld=%b refill_way=%b | dc_wr: tag_req=%b tag_wen=%b data_req=%b idx=%0d",
               cycles,
               dut.u_lsu_top.u_lsu_lfb.lfb_ld_da_hit_idx,
               dut.u_lsu_top.u_lsu_lfb.ld_da_lfb_set_wakeup_queue,
               dut.u_lsu_top.ld_da_lsid,
               dut.u_lsu_top.u_lsu_lfb.lfb_wakeup_queue,
               dut.u_lsu_top.u_lsu_lfb.lfb_pop_depd_ff,
               dut.u_lsu_top.lfb_depd_wakeup,
               dut.u_lsu_top.u_lsu_lfb.lfb_lf_sm_create_vld,
               dut.u_lsu_top.u_lsu_lfb.lfb_lf_sm_vld,
               dut.u_lsu_top.u_lsu_lfb.lfb_lf_sm_refill_way,
               dut.u_lsu_top.u_lsu_lfb.lfb_dcache_arb_ld_tag_req,
               dut.u_lsu_top.u_lsu_lfb.lfb_dcache_arb_ld_tag_wen,
               dut.u_lsu_top.u_lsu_lfb.lfb_dcache_arb_ld_req,
               dut.u_lsu_top.u_lsu_lfb.lfb_dcache_arb_ld_tag_idx);
      $display("  [CMD] T%0d 延迟线输入: v=%b%b%b pc=%08x,%08x,%08x iid=%0d,%0d,%0d | rtu_yy_xx_commit=%b%b%b iid=%0d,%0d,%0d",
               cycles,
               dut.rtu_cmt_vld[0], dut.rtu_cmt_vld[1], dut.rtu_cmt_vld[2],
               dut.rtu_cmt_pc[0], dut.rtu_cmt_pc[1], dut.rtu_cmt_pc[2],
               dut.rtu_cmt_iid[0], dut.rtu_cmt_iid[1], dut.rtu_cmt_iid[2],
               dut.rtu_yy_xx_commit0, dut.rtu_yy_xx_commit1, dut.rtu_yy_xx_commit2,
               dut.rtu_yy_xx_commit0_iid, dut.rtu_yy_xx_commit1_iid, dut.rtu_yy_xx_commit2_iid);
      $display("  [DCW] T%0d lfb_sel=%b lfb_grnt=%b | tag_gwen_b=%b tag_sel_b=%b tag_wen_b=%b | data_gwen_b=%b data_sel_b=%b",
               cycles,
               dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_sel,
               dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_grnt,
               dut.u_lsu_top.lsu_dcache_ld_tag_gwen_b,
               dut.u_lsu_top.lsu_dcache_ld_tag_sel_b,
               dut.u_lsu_top.lsu_dcache_ld_tag_wen_b,
               dut.u_lsu_top.lsu_dcache_ld_data_gwen_b,
               dut.u_lsu_top.lsu_dcache_ld_data_sel_b);
      if (dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld)
        $display("  [LDC] T%0d iid=%0d addr=%08x secd=%b hit=%b way=%b fwd=%b expt=%b | data_vld=%b cmplt_req=%b data_req=%b | disc_lfb=%b rb_create=%b",                 cycles, dut.u_lsu_top.u_lsu_ld_da.ld_da_iid,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_addr,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_secd,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_hit,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_settle_way,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_fwd_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_expt,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_data_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_wb_cmplt_req,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_wb_data_req,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_discard_from_lfb_req,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_rb_create_vld);
      if (dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld)
        $display("  [LDA] T%0d iid=%0d preg=%0d addr=%08x | cb_vld=%b cb_data=%08x | rb_vld=%b | rot=%0d | d256lo=%032x d256hi=%032x | wb_req=%b wb_data=%08x",
                 cycles, dut.u_lsu_top.u_lsu_ld_da.ld_da_iid,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_preg,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_addr,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_cb_data_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_cb_data,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_rb_data_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_data_rot_sel,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_data256[127:0],
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_data256[255:128],
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_wb_data_req,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_wb_data);
    end
  end

  // 【临时诊断】store 数据进 SQ → 旋转 → 旁路给 load 整条数据链 —— `+PROBE_SQ`
  //   [SQD] IDU pipe5 送来的 store 数据 / SDIQ 选中
  //   [SQR] SQ 顶层的 settle 旋转:rot_sel 是不是 one-hot(非 one-hot ⇒ rot_data default 全 X)
  //   [SQE] 各 SQ 表项里存的数据 + 该表项的 rot_sel
  //   [SQL] load 拿到的那一拍:SQ 给的数据 / 字节掩码 / 旋转量 / 最终写回值
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SQ") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [SQD] T%0d sdiq_sel=%b sdiq_id=%b pipe5_src0=%08x | settle_hit=%b rot_sel=%b settle_data=%08x",
               cycles, dut.idu_lsu_sdiq_sel, dut.idu_lsu_rf_pipe5_sdiq_entry,
               dut.idu_lsu_rf_pipe5_src0,
               dut.u_lsu_top.u_lsu_sq.sq_entry_settle_data_hit,
               dut.u_lsu_top.u_lsu_sq.sq_settle_rot_sel,
               dut.u_lsu_top.u_lsu_sq.sq_data_settle);
      $display("  [SQE] T%0d data=%08x %08x %08x | rot=%02x %02x %02x | addr=%08x %08x %08x | vld=%b iid=%0d %0d %0d",
               cycles,
               dut.u_lsu_top.u_lsu_sq.sq_entry_data[0], dut.u_lsu_top.u_lsu_sq.sq_entry_data[1],
               dut.u_lsu_top.u_lsu_sq.sq_entry_data[2],
               dut.u_lsu_top.u_lsu_sq.sq_entry_rot_sel[0], dut.u_lsu_top.u_lsu_sq.sq_entry_rot_sel[1],
               dut.u_lsu_top.u_lsu_sq.sq_entry_rot_sel[2],
               dut.u_lsu_top.u_lsu_sq.sq_entry_addr0[0], dut.u_lsu_top.u_lsu_sq.sq_entry_addr0[1],
               dut.u_lsu_top.u_lsu_sq.sq_entry_addr0[2],
               dut.u_lsu_top.u_lsu_sq.sq_entry_vld,
               dut.u_lsu_top.u_lsu_sq.sq_entry_iid[0], dut.u_lsu_top.u_lsu_sq.sq_entry_iid[1],
               dut.u_lsu_top.u_lsu_sq.sq_entry_iid[2]);
      if (dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld)
        $display("  [SQL] T%0d iid=%0d addr=%08x fwd_vld=%b fwd_sq=%b fwd_bytes=%04x ld_rot=%0d | sq_fwd_id=%b sq_fwd_data=%08x | d128=%032x wb=%08x",
                 cycles, dut.u_lsu_top.u_lsu_ld_da.ld_da_iid,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_addr,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_fwd_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_fwd_sq_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_fwd_bytes_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_data_rot_sel,
                 dut.u_lsu_top.sq_ld_dc_fwd_id, dut.u_lsu_top.sq_ld_da_fwd_data,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_data128,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_wb_data);
    end
  end

  // 【临时诊断】IDU 侧 SDIQ / pipe5 相位 —— `+PROBE_SDIQ` (窗由 STL_LO/STL_HI 给)
  //   看 issue_en → (reg) → rf_pipe5_inst_vld / rf_pipe5_prf_src0_preg 是否同拍,
  //   以及送到 LSU 的 sdiq_sel / sdiq_id / src0 三根是不是同拍有效。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SDIQ") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [IDU] T%0d issue_en=%b p5_vld=%b | dp_issue_entry=%b dp_read_data=%02x | p5_iq_entry=%b p5_src0_preg=%0d | prf_rd_preg=%0d prf_rd_data=%08x | sdiq_sel=%b sdiq_id=%b src0=%08x | st_sdiq_entry=%b",
               cycles,
               dut.u_ct_idu_top.x_ct_idu_rf_dp.sdiq_xx_issue_en,
               dut.u_ct_idu_top.x_ct_idu_rf_ctrl.rf_pipe5_inst_vld,
               dut.u_ct_idu_top.x_ct_idu_rf_dp.sdiq_dp_issue_entry,
               dut.u_ct_idu_top.x_ct_idu_rf_dp.sdiq_dp_issue_read_data,
               dut.u_ct_idu_top.x_ct_idu_rf_dp.rf_pipe5_iq_entry,
               dut.u_ct_idu_top.x_ct_idu_rf_dp.rf_pipe5_prf_src0_preg,
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.dp_prf_rf_pipe5_src0_preg,
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.prf_dp_rf_pipe5_src0_data,
               dut.idu_lsu_sdiq_sel,
               dut.idu_lsu_rf_pipe5_sdiq_entry,
               dut.idu_lsu_rf_pipe5_src0,
               dut.idu_lsu_st_sdiq_entry);
    end
  end

  // 【临时诊断】SDIQ 表项内部: 存的 rs2(store data) preg / ready 位 / 读出的 8 位 —— `+PROBE_SD2`
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SD2") && cycles >= stl_lo && cycles <= stl_hi) begin
      if (dut.idu_lsu_sdiq_sel || dut.u_ct_idu_top.sdiq_xx_issue_en
          || dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.x_create_en)
        $display("  [SD2] T%0d issue_en=%b sel=%b | e0:vld=%b rdy=%b cread=%02x rd=%02x preg=%0d s0vld=%b | dp:%02x",
                 cycles,
                 dut.u_ct_idu_top.sdiq_xx_issue_en, dut.idu_lsu_sdiq_sel,
                 dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.vld,
                 dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.x_rdy,
                 dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.x_create_data,
                 dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.x_read_data,
                 dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.u_ct_idu_dep_reg_entry_src1.preg,
                 dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.src0_vld,
                 dut.u_ct_idu_top.sdiq_dp_issue_read_data);
    end
  end

  // 【临时诊断】AXI 总线 + MSHR 表项/写回请求 —— `+PROBE_AXI`
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_AXI") && cycles >= stl_lo && cycles <= stl_hi) begin
      if (biu_pad_arvalid & pad_biu_arready)
        $display("  [AX] T%0d AR addr=%08x len=%0d", cycles, biu_pad_araddr, biu_pad_arlen);
      if (pad_biu_rvalid)
        $display("  [AX] T%0d R last=%b data=%032x", cycles, pad_biu_rlast, pad_biu_rdata);
      if (biu_pad_awvalid)
        $display("  [AX] T%0d AW v=%b r=%b addr=%08x", cycles, biu_pad_awvalid, pad_biu_awready, biu_pad_awaddr);
      if (biu_pad_wvalid)
        $display("  [AX] T%0d  W v=%b r=%b last=%b strb=%16x data=%032x", cycles, biu_pad_wvalid, pad_biu_wready, biu_pad_wlast, biu_pad_wstrb, biu_pad_wdata);
      $display("  [LQ] T%0d evld=%b eiid=%0d | ld:dc_vld=%b iid=%0d addr=%08x | st:chk=%b iid=%0d addr=%08x | specfail=%b specfail1=%b",
               cycles,
               dut.u_lsu_top.u_lsu_lq.lq_entry_vld,
               dut.u_lsu_top.u_lsu_lq.gen_lq_entry[0].u_lq_entry.lq_entry_iid,
               dut.u_lsu_top.ld_dc_lq_create_vld,
               dut.u_lsu_top.u_lsu_ld_dc.ld_dc_iid,
               dut.u_lsu_top.u_lsu_ld_dc.ld_dc_addr0,
               dut.u_lsu_top.st_dc_chk_st_inst_vld,
               dut.u_lsu_top.u_lsu_st_dc.st_dc_iid,
               dut.u_lsu_top.u_lsu_st_dc.st_dc_addr0,
               dut.u_lsu_top.lq_st_dc_spec_fail,
               dut.u_lsu_top.u_lsu_lq.gen_lq_entry[0].u_lq_entry.lq_entry_raw_spec_fail1);
      $display("  [WM] T%0d sqe_data= %08x %08x %08x %08x %08x %08x | ce_sqptr=%b popd=%08x | wen_data: %08x %08x %08x",
               cycles,
               dut.u_lsu_top.u_lsu_sq.sq_entry_data[0], dut.u_lsu_top.u_lsu_sq.sq_entry_data[1],
               dut.u_lsu_top.u_lsu_sq.sq_entry_data[2], dut.u_lsu_top.u_lsu_sq.sq_entry_data[3],
               dut.u_lsu_top.u_lsu_sq.sq_entry_data[4], dut.u_lsu_top.u_lsu_sq.sq_entry_data[5],
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_sq_ptr, dut.u_lsu_top.sq_pop_data,
               dut.u_lsu_top.u_lsu_wmb.wmb_entry_data[0], dut.u_lsu_top.u_lsu_wmb.wmb_entry_data[1],
               dut.u_lsu_top.u_lsu_wmb.wmb_entry_data[2]);
    end
  end

  integer preg_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_PREG") && preg_lines < 120 && cycles >= 96) begin
      preg_lines = preg_lines + 1;
      $display("  [PREG] T%0d tap: vld=%b%b%b num=%0d,%0d,%0d | IR alloc=%b%b%b preg=%0d,%0d,%0d | 派遣 vld=%b%b%b 号=%0d,%0d,%0d",
               cycles,
               dut.rtu_idu_alloc_preg2_vld, dut.rtu_idu_alloc_preg1_vld, dut.rtu_idu_alloc_preg0_vld,
               dut.rtu_idu_alloc_preg0, dut.rtu_idu_alloc_preg1, dut.rtu_idu_alloc_preg2,
               dut.idu_rtu_ir_preg2_alloc_vld, dut.idu_rtu_ir_preg1_alloc_vld,
               dut.idu_rtu_ir_preg0_alloc_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_dp.ir_inst0_dst_preg,
               dut.u_ct_idu_top.x_ct_idu_ir_dp.ir_inst1_dst_preg,
               dut.u_ct_idu_top.x_ct_idu_ir_dp.ir_inst2_dst_preg,
               dut.idu_rtu_disp2_vld, dut.idu_rtu_disp1_vld, dut.idu_rtu_disp0_vld,
               dut.idu_rtu_disp0_dst_preg, dut.idu_rtu_disp1_dst_preg,
               dut.idu_rtu_disp2_dst_preg);
    end
  end

  integer disp_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_DISP") && disp_lines < 120
        && (dut.idu_rtu_disp0_vld || dut.idu_rtu_disp1_vld || dut.idu_rtu_disp2_vld)) begin
      disp_lines = disp_lines + 1;
      $display("  [DISP] T%0d vld=%b%b%b pc=%08x,%08x,%08x dst_preg=%0d,%0d,%0d lreg=%0d,%0d,%0d old=%0d,%0d,%0d iid=%0d,%0d,%0d",
               cycles, dut.idu_rtu_disp2_vld, dut.idu_rtu_disp1_vld, dut.idu_rtu_disp0_vld,
               dut.idu_rtu_disp0_pc, dut.idu_rtu_disp1_pc, dut.idu_rtu_disp2_pc,
               dut.idu_rtu_disp0_dst_preg, dut.idu_rtu_disp1_dst_preg, dut.idu_rtu_disp2_dst_preg,
               dut.idu_rtu_disp0_dst_lreg, dut.idu_rtu_disp1_dst_lreg, dut.idu_rtu_disp2_dst_lreg,
               dut.idu_rtu_disp0_old_preg, dut.idu_rtu_disp1_old_preg, dut.idu_rtu_disp2_old_preg,
               dut.rtu_disp_iid0, dut.rtu_disp_iid1, dut.rtu_disp_iid2);
      $display("        分配: req=%b | 给号 vld=%b%b%b 号=%0d,%0d,%0d | IDU 侧 alloc_vld=%b%b%b",
               dut.ren_preg_req,
               dut.rtu_idu_alloc_preg2_vld, dut.rtu_idu_alloc_preg1_vld, dut.rtu_idu_alloc_preg0_vld,
               dut.rtu_idu_alloc_preg0, dut.rtu_idu_alloc_preg1, dut.rtu_idu_alloc_preg2,
               dut.idu_rtu_ir_preg2_alloc_vld, dut.idu_rtu_ir_preg1_alloc_vld,
               dut.idu_rtu_ir_preg0_alloc_vld);
    end
  end

  // 【临时诊断】ID 窗口 vs IR 窗口逐拍并排 —— `+PROBE_IDIR`
  //   追"某条指令在 ID 级被收下了, 却没有出现在 IR/派遣里"。
  integer IDIR_LO = 0;
  integer IDIR_HI = 0;
  initial begin
    void'($value$plusargs("IDIR_LO=%d", IDIR_LO));
    void'($value$plusargs("IDIR_HI=%d", IDIR_HI));
    void'($value$plusargs("STL_LO=%d", stl_lo));
    void'($value$plusargs("STL_HI=%d", stl_hi));
  end
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_IDIR") && cycles >= IDIR_LO && cycles <= IDIR_HI) begin
      $display("  [IDIR] T%0d IDreg: vld=%b%b%b pc=%08x,%08x,%08x | IRreg: vld=%b%b%b pc=%08x,%08x,%08x",
               cycles,
               dut.u_ct_idu_top.u_ct_idu_id_ctrl.id_inst2_vld,
               dut.u_ct_idu_top.u_ct_idu_id_ctrl.id_inst1_vld,
               dut.u_ct_idu_top.u_ct_idu_id_ctrl.id_inst0_vld,
               dut.u_ct_idu_top.u_ct_idu_id_dp.id_inst2_pc,
               dut.u_ct_idu_top.u_ct_idu_id_dp.id_inst1_pc,
               dut.u_ct_idu_top.u_ct_idu_id_dp.id_inst0_pc,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_inst2_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_inst1_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_inst0_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_dp.ir_inst2_data[89:58],
               dut.u_ct_idu_top.x_ct_idu_ir_dp.ir_inst1_data[89:58],
               dut.u_ct_idu_top.x_ct_idu_ir_dp.ir_inst0_data[89:58]);
      $display("         ID→IR: vld=%b%b%b pc=%08x,%08x,%08x | 派遣: vld=%b%b%b pc=%08x,%08x,%08x iid=%0d,%0d,%0d",
               dut.u_ct_idu_top.id_ir_inst2_vld, dut.u_ct_idu_top.id_ir_inst1_vld,
               dut.u_ct_idu_top.id_ir_inst0_vld,
               dut.u_ct_idu_top.u_ct_idu_id_dp.dp_id_pipedown_inst2_data[89:58],
               dut.u_ct_idu_top.u_ct_idu_id_dp.dp_id_pipedown_inst1_data[89:58],
               dut.u_ct_idu_top.u_ct_idu_id_dp.dp_id_pipedown_inst0_data[89:58],
               dut.idu_rtu_disp2_vld, dut.idu_rtu_disp1_vld, dut.idu_rtu_disp0_vld,
               dut.idu_rtu_disp2_pc, dut.idu_rtu_disp1_pc, dut.idu_rtu_disp0_pc,
               dut.rtu_disp_iid2, dut.rtu_disp_iid1, dut.rtu_disp_iid0);
      $display("         acc=%b ifu_acc=%b ib_vld=%b pc=%08x,%08x,%08x cnt=%0d head=%0d | is_pipedown2=%b id_sel=%b id_stall=%b ir_stall=%b",
               dut.idu_accept_num, dut.ifu_accept_num, dut.u_rv32ifu2_top.ib_vld,
               dut.u_rv32ifu2_top.ib_out0[63:32], dut.u_rv32ifu2_top.ib_out1[63:32],
               dut.u_rv32ifu2_top.ib_out2[63:32],
               dut.u_rv32ifu2_top.u_ibuf.cnt_q, dut.u_rv32ifu2_top.u_ibuf.head_q,
               dut.u_ct_idu_top.ctrl_xx_is_inst0_sel[0], dut.u_ct_idu_top.ctrl_xx_is_inst0_sel[1],
               dut.u_ct_idu_top.u_ct_idu_id_ctrl.ctrl_id_pipedown_stall,
               dut.u_ct_idu_top.ctrl_ir_stall);
    end
  end

  integer beu_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_BEU") && beu_lines < 200
        && (dut.idu_biq_sel || dut.iu_chgflw_vld)) begin
      beu_lines = beu_lines + 1;
      $display("  [BEU] T%0d sel=%b pc=%08x npc=%08x taken=%b sel=%b | src0=%08x src1/imm=%08x",
               cycles, dut.idu_biq_sel, dut.idu_biq_pc, dut.idu_biq_npc, dut.idu_biq_taken,
               dut.idu_biq_rslt_sel, dut.idu_biq_src0, dut.idu_biq_src1);
      $display("        实际: actual_npc=%08x mismatch=%b mispred=%b | chgflw_vld=%b chgflw_pc=%08x",
               dut.u_iu_beu_pipe.o_actual_npc,
               dut.u_iu_beu_pipe.u_beu.npc_mismatch,
               dut.u_iu_beu_pipe.mispredict,
               dut.iu_chgflw_vld, dut.iu_chgflw_pc);
    end
  end

  // 【临时诊断】判退级逐拍: 退休窗口的 iid/mispred 位 vs 冲刷触发 —— `+PROBE_RET`
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RET") && cycles >= 94 && cycles <= 114) begin
      $display("  [RET] T%0d ret=%b win_iid=%0d,%0d w0_misp=%b | mispred_hit=%b trig=%b busy=%b st=%0d gate=%b rtu_yy_xx=%b",
               cycles, dut.rtu_retire_cnt, dut.u_rtu.u_rob.win_iid0, dut.u_rtu.u_rob.win_iid1,
               dut.u_rtu.u_commit.w0_misp, dut.u_rtu.u_commit.mispred_hit,
               dut.u_rtu.u_commit.flush_trig, dut.u_rtu.fsm_busy, dut.u_rtu.u_flush.st_q,
               dut.mispred_hold_q, dut.rtu_yy_xx_flush);
      $display("        resolve: vld=%b iid=%0d mispred=%b tgt=%08x | win_res=%b,%b win_iid=%0d,%0d | beu cmplt=%b#%0d",
               dut.resolve_vld, dut.resolve_iid, dut.resolve_mispred, dut.resolve_target,
               dut.u_rtu.u_rob.win_res0, dut.u_rtu.u_rob.win_res1,
               dut.u_rtu.u_rob.win_iid0, dut.u_rtu.u_rob.win_iid1,
               dut.cmplt_vld3, dut.cmplt_iid3);
    end
  end

  // 【临时诊断】x4 的改名链: 每次派发看 lreg/dst_preg/old_preg —— `+PROBE_RAT`
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RAT") && cycles >= 300 && cycles <= 320
        && (dut.idu_rtu_disp0_vld || dut.idu_rtu_disp1_vld || dut.idu_rtu_disp2_vld)) begin
      $display("  [RAT] T%0d 派: lreg=%0d,%0d,%0d dst_preg=%0d,%0d,%0d old_preg=%0d,%0d,%0d | pc=%08x,%08x,%08x",
               cycles,
               dut.idu_rtu_disp0_dst_lreg, dut.idu_rtu_disp1_dst_lreg, dut.idu_rtu_disp2_dst_lreg,
               dut.idu_rtu_disp0_dst_preg, dut.idu_rtu_disp1_dst_preg, dut.idu_rtu_disp2_dst_preg,
               dut.idu_rtu_disp0_old_preg, dut.idu_rtu_disp1_old_preg, dut.idu_rtu_disp2_old_preg,
               dut.idu_rtu_disp0_pc, dut.idu_rtu_disp1_pc, dut.idu_rtu_disp2_pc);
    end
  end

  // -------------------------------------------------------------------------
  // 【临时诊断】RTU 重定向 → T+1 撞车探针 —— `A910_DT_ARGS=+PROBE_RACE`
  //
  //  追的是这条时序癌: RTU 在 T 拍发**前端**重定向 (`rtu_ifu_chgflw_vld`, 与
  //  `rtu_ifu_flush` 同拍同值, 见 RTU_flush.v:156-161), 但它给 IDU 的**大扫帚**
  //  `rtu_yy_xx_flush` 是 **T+1** 才到 (RTU_flush.v 的 F1)。而 IFU2 命中 I-Cache
  //  时 T+1 就能把目标那条交出来 (零气泡重定向 + 空队列旁路, ibuf:93-99)
  //  ⇒ "交货"和"被清"撞在同一拍:
  //    * ID 级寄存器 `else if(rtu_yy_xx_flush)` 的优先级高于 pipedown
  //      (ct_idu_id_ctrl.sv:77 / ct_idu_id_dp.sv:178) ⇒ 当拍交来那条被丢;
  //    * 而 IDU 报给 IFU 的 `idu_accept_num` **不看 vld** (ct_idu_id_ctrl.sv:53-65)
  //      ⇒ IBUF 把它当"已收下"弹掉 ⇒ **永久丢** (不是晚一拍)。
  //
  //  ⚠️ 只看**生效值** —— 闸门之后的 `idu_inst*_vld` / `ifu_accept_num`:
  //     改了闸门 (hold 里并进 `rtu_yy_xx_flush` 或 `rtu_ifu_chgflw_vld`) 之后,
  //     撞车那拍这两组应当全 0 ⇒ 指令留在 IBUF 里等下一拍, 不丢。
  //     所以判据是**末尾那行的 `真丢` 必须为 0**, 而不是"撞车次数"。
  // -------------------------------------------------------------------------
  integer race_reds  = 0;     // RTU 非误预测前端重定向 (T 拍) 次数
  integer race_hit   = 0;     // 其中 T+1 撞上大扫帚、且 IFU 真的交货了的次数
  integer race_lost  = 0;     // 其中 IBUF 还把它弹走了 (accept != 0) ⇒ 真丢
  integer race_lines = 0;
  reg     race_pend  = 1'b0;
  reg [2:0]  race_src;
  reg [31:0] race_pc;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RACE")) begin
      if (race_pend) begin
        race_pend = 1'b0;
        if (dut.rtu_yy_xx_flush) begin
          if (dut.idu_inst0_vld || dut.idu_inst1_vld || dut.idu_inst2_vld) race_hit = race_hit + 1;
          if (dut.idu_inst0_vld && (dut.ifu_accept_num != 2'b0)) race_lost = race_lost + 1;
          if (race_lines < 200) begin
            race_lines = race_lines + 1;
            $display("  [RACE] T%0d src=%0d tgt=%08x | T+1: 大扫帚=1 闸门=%b | IFU 备货=%b%b%b 交出=%b%b%b accept=%b ⇒ %s",
                     cycles, race_src, race_pc, dut.mispred_hold_q,
                     dut.ifu_inst2_vld, dut.ifu_inst1_vld, dut.ifu_inst0_vld,
                     dut.idu_inst2_vld, dut.idu_inst1_vld, dut.idu_inst0_vld,
                     dut.ifu_accept_num,
                     (dut.idu_inst0_vld && (dut.ifu_accept_num != 2'b0)) ? "★真丢" : "留着");
          end
        end
      end
      if (dut.rtu_ifu_chgflw_vld) begin
        race_reds = race_reds + 1;
        race_pend = 1'b1;
        race_src  = dut.u_rtu.flush_src;
        race_pc   = dut.rtu_ifu_chgflw_pc;
      end
    end
  end

  integer ifu_win = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_IFU")) begin
      if (dut.u_rv32ifu2_top.redirect) ifu_win = 20;
      if (ifu_win > 0) begin
        ifu_win = ifu_win - 1;
        $display("  [RTU→IFU] T%0d rtu_flush=%b rtu_chgflw_vld=%b rtu_chgflw_pc=%08x | IFU 取指 PC=%08x | gate(hold)=%b",
                 cycles, dut.rtu_ifu_flush, dut.rtu_ifu_chgflw_vld, dut.rtu_ifu_chgflw_pc,
                 dut.u_rv32ifu2_top.u_icache.q_pc_q, dut.mispred_hold_q);
        // 派遣(iid/目标号) vs 完成(iid) vs 退休(iid) —— 追"这条是谁登记的完成"
        $display("  [IID] T%0d 派:%b#%0d(p%0d) %b#%0d(p%0d) %b#%0d(p%0d) | 完成:%b#%0d %b#%0d %b#%0d %b#%0d %b#%0d",
                 cycles,
                 dut.idu_rtu_disp0_vld, dut.rtu_disp_iid0, dut.idu_rtu_disp0_dst_preg,
                 dut.idu_rtu_disp1_vld, dut.rtu_disp_iid1, dut.idu_rtu_disp1_dst_preg,
                 dut.idu_rtu_disp2_vld, dut.rtu_disp_iid2, dut.idu_rtu_disp2_dst_preg,
                 dut.cmplt_vld0, dut.cmplt_iid0, dut.cmplt_vld1, dut.cmplt_iid1,
                 dut.cmplt_vld2, dut.cmplt_iid2, dut.cmplt_vld3, dut.cmplt_iid3,
                 dut.cmplt_vld4, dut.cmplt_iid4);
        $display("  [RET] T%0d 退休:%b iid=%0d/%0d | 完成5/6(LSU):%b#%0d %b#%0d | LSU 写口:%b",
                 cycles, dut.rtu_retire_cnt, dut.u_rtu.u_rob.win_iid0, dut.u_rtu.u_rob.win_iid1,
                 dut.cmplt_vld5, dut.cmplt_iid5, dut.cmplt_vld6, dut.cmplt_iid6,
                 dut.lsu_rtu_wb_pipe3_wb_preg_vld);
        $display("  [AG] T%0d ld_sel=%b ld_iid=%0d | ag_vld=%b stall_vld=%b stall_ori=%b ag2dc=%b",
                 cycles, dut.idu_lsu_ld_sel, dut.idu_lsu_ld_iid,
                 dut.u_lsu_top.u_lsu_ld_ag.ld_ag_inst_vld,
                 dut.u_lsu_top.u_lsu_ld_ag.ld_ag_stall_vld,
                 dut.u_lsu_top.u_lsu_ld_ag.ld_ag_stall_ori,
                 dut.u_lsu_top.u_lsu_ld_ag.ld_ag_dc_inst_vld);
        $display("  [LSU] T%0d ld_sel=%b ld_iid=%0d | dc2da=%b da_vld=%b secd=%b da_wb_req=%b | wb_pre=%b wb_vld=%b wb_iid=%0d",
                 cycles, dut.idu_lsu_ld_sel, dut.idu_lsu_ld_iid,
                 dut.u_lsu_top.u_lsu_ld_da.ld_dc_da_inst_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_secd,
                 dut.u_lsu_top.ld_da_wb_cmplt_req,
                 dut.u_lsu_top.u_lsu_ld_wb.ld_wb_pre_inst_vld,
                 dut.u_lsu_top.ld_wb_inst_vld, dut.u_lsu_top.rb_ld_wb_iid);
        $display("  [IFU] T%0d flush: iu_chgflw=%b rtu_chgflw=%b idu_flush(rtu_yy_xx)=%b | IDU is_stall=%b ir_stall=%b",
                 cycles, dut.iu_chgflw_vld, dut.rtu_ifu_chgflw_vld, dut.rtu_yy_xx_flush,
                 dut.u_ct_idu_top.ctrl_is_stall, dut.u_ct_idu_top.ctrl_ir_stall);
        $display("  [FLS] T%0d rtu: trig=%b src=%b st_q=%b | resolve vld=%b iid=%0d taken=%b mispred=%b tgt=%08x | beu_red=%b",
                 cycles, dut.u_rtu.flush_trig, dut.u_rtu.flush_src, dut.u_rtu.u_flush.st_q,
                 dut.resolve_vld, dut.resolve_iid, dut.resolve_taken, dut.resolve_mispred,
                 dut.resolve_target, dut.beu_redirect_vld);
        $display("  [IFU] T%0d red=%b red_pc=%08x | ib_vld=%b pc=%08x,%08x,%08x | cnt=%0d head=%0d | acc=%b | idu_vld=%b%b%b",
                 cycles, dut.u_rv32ifu2_top.redirect, dut.u_rv32ifu2_top.redirect_pc,
                 dut.u_rv32ifu2_top.ib_vld,
                 dut.u_rv32ifu2_top.ib_out0[63:32], dut.u_rv32ifu2_top.ib_out1[63:32],
                 dut.u_rv32ifu2_top.ib_out2[63:32],
                 dut.u_rv32ifu2_top.u_ibuf.cnt_q, dut.u_rv32ifu2_top.u_ibuf.head_q,
                 dut.idu_accept_num,
                 dut.idu_inst2_vld, dut.idu_inst1_vld, dut.idu_inst0_vld);
      end
    end
  end

  // -------------------------------------------------------------------------
  // FSDB 波形生成 (仿照 tb_a910_smoke.sv)
  // -------------------------------------------------------------------------
`ifdef FSDB
  reg [8*100:1] wave_file;
  initial begin
    if ($value$plusargs("WAVE=%s", wave_file)) begin
      $sformat(wave_file, "waveform/%0s.fsdb", wave_file);
    end else begin
      wave_file = "waveform/a910_difftest.fsdb";
    end
    $fsdbDumpfile(wave_file);
    $fsdbDumpvars(0, tb_a910_difftest);
    $display("  📊 FSDB 波形已启用: %0s", wave_file);
  end
`endif

  initial begin
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 200000;
    if (!$value$plusargs("TEST=%s", test_name)) test_name = "(+TEST 未给)";

    // 黄金模型自己读 **meminit.bin** (Makefile 每用例把它链到 bin/$(TEST).bin),
    // 与 DUT 侧 AXI 从机读 meminit128.hex 是同一个镜像的两种宽度视图。
    gm_init("meminit.bin");

    $display("");
    $display("==================================================");
    $display("  A910_cpu difftest 台   TEST=%0s  (MAX_CYCLES=%0d)", test_name, max_cycles);
    $display("==================================================");

    rst = 1;
    repeat (20) @(posedge clk);
    rst = 0;
    trace_on = 1;

    while (!halted && !bad && cycles < max_cycles) @(posedge clk);
    repeat (2) @(posedge clk);        // 让 halt/bad 那两个 always 块先跑完

    // [RACE] 汇总: 重定向次数 / 撞车次数 / **真丢条数** (判据是最后一列 = 0)
    if ($test$plusargs("PROBE_RACE")) begin
      $display("  [RACE] TEST=%0s | RTU 前端重定向 %0d 次 | T+1 撞车 %0d 次 | 真丢 %0d 条",
               test_name, race_reds, race_hit, race_lost);
    end

    $display("");
    $display("==================================================");
    if (halted && !bad) begin
      if (exit_code == 0) begin
        $display("  === A910 DIFFTEST: PASS ===");
        $display("  TEST=%0s  逐条比对通过, 退休 %0d 条, 用了 %0d 拍",
                 test_name, retired, cycles);
        $display("==================================================");
        $finish;
      end
      else begin
        // ------------ +NOVALID: 只跳过"跑分有效性"判定 ----------------
        // 照 tb_miniRV_dpi.sv 的同名开关 (那边是 CoreMark 的"≥10 秒"规则)。
        // 本台现在的头号用例是 **CoreMark 上 A910**, 而它的计时依赖读 TIMER 外设,
        // 而 A910 的 LSU/dcache 目前**没有 device/uncached 旁路** (实测: 同一地址
        // 读三次, AXI 上只有一次 AR —— 后两次被 cache 吃掉) ⇒ 程序里
        // `total_time = 0` ⇒ 触发 "ERROR! Must execute for at least 10 secs",
        // `total_errors++` ⇒ 退出码 1。而**逐拍 difftest 是全程通过的**:
        // 指令流、寄存器值、CRC 都对, 只是内核自己的计时器不走了。
        // ⇒ 这个开关不掩盖任何功能错误 (真错会在上面的 `bad` 分支 $fatal),
        //   它只把"分数不合法"从 FAIL 降级成 PASS, 并把**真正要看的两个数**
        //   (退休条数 / 用了多少拍) 打出来。
        // 判据提醒: 用它跑出来的分数**不能引用**, 只能当周期/退休数看。
        if ($test$plusargs("NOVALID")) begin
          $display("  === A910 DIFFTEST: PASS (NOVALID: 退出码 %0d, 分数不合法) ===",
                   exit_code);
          $display("  TEST=%0s  逐条比对通过, 退休 %0d 条, 用了 %0d 拍",
                   test_name, retired, cycles);
          $display("  ⚠️ 退出码非 0 = 用例自检没过 (多半是跑分有效性: 计时器读到常量)。");
          $display("     指令流与寄存器已逐条比对通过 ⇒ 周期/退休数可用, 分数不可引用。");
          $display("==================================================");
          $finish;
        end
        $display("  === A910 DIFFTEST: FAIL (用例自检没过) ===");
        $display("  TEST=%0s  黄金模型停在 ecall 时 a0 != 0", test_name);
        $display("  ⚠️ 这条路径说明**指令流本身是对的**(否则会先在 difftest 上报失配),");
        $display("     是用例的 fail 分支被执行了 —— 去看它跳去了哪个 fail。");
        $display("     (CoreMark 那种『分数不合法』的退出码 1, 用 +NOVALID 放开。)");
        $display("==================================================");
        $fatal(1, "a910 difftest: test self-check failed");
      end
    end
    else if (bad) begin
      // 详细对照已由 dpi_shim.c 打在上面
      $display("  === A910 DIFFTEST: FAIL (与黄金模型不一致) ===");
      $display("  TEST=%0s  退休 %0d 条, 用了 %0d 拍", test_name, retired, cycles);
      $display("==================================================");
      $fatal(1, "a910 difftest: mismatch");
    end
    else begin
      $display("  === A910 DIFFTEST: FAIL (超时) ===");
      $display("  TEST=%0s  %0d 拍内没跑到收尾的 ecall", test_name, max_cycles);
      $display("  累计退休 %0d 条, IFU 初始化=%b, ROB 占用=%0d, ICache PC=%08x",
               retired, dut.ifu_init_done, dut.u_rtu.u_rob.occ,
               dut.u_rv32ifu2_top.u_icache.q_pc_q);
      if (retired == 0)
        $display("  ⚠️ 一条都没退休 —— 卡在取指/派遣, 不是执行的问题");
      $display("==================================================");
      $fatal(1, "a910 difftest: timeout");
    end
  end

endmodule
