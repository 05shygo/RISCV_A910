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
  import "DPI-C" context function void gm_dump_mem(input int addr, input int nwords);
  import "DPI-C" context function int unsigned gm_read_mem(input int addr);
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

  // 探针窗口 (可用 +STL_LO/+STL_HI 覆盖; 默认 270/330 是早期用例的现场)
  integer stl_lo = 270, stl_hi = 330;
  initial begin
    void'($value$plusargs("STL_LO=%d", stl_lo));
    void'($value$plusargs("STL_HI=%d", stl_hi));
  end

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
  // 【临时诊断】写通道落盘现场 + AXI 从机内存看门狗 (2026-10-14, coremark_i1 #1689)
  //
  // 【为什么加它】失灵点 pc=0x44 `lh a5,0(a0)` (a0=0xf940) 上, 黄金模型读回 0x2424,
  //   DUT 读回 0 —— 而 AXI 上同地址回填的是 0x6464。即 **DUT 内存本身被写成了错值**,
  //   不是 load 通路的问题。
  //   光看 `+PROBE_AXI` 的 AW/W 打印对不上: 按"第 i 个 AW 配第 i 个 W"重建出来的
  //   写序列给出的是正确值 0x2424, 与从机实际内存 0x6464 矛盾 ⇒ 总线上 AW/W 两条
  //   通道的**真实配对**不是打印顺序。必须让从机在**真正落盘那一拍**自己报出来。
  //
  //   [SLVW] 从机在 wvalid&wready 那拍实际写的那笔: 用的 wr_addr + strb + data。
  //   [MEMW] 从机内存 mem[f93..f96] 的每次变化 (带当拍总线状态), 定位是哪一笔写坏的。
  // -------------------------------------------------------------------------
  // ⚠️ 2026-10-15: 原来**没有 plusarg 门** ⇒ 每笔 AXI 写都打, 千万拍级用例
  //    (CoreMark 30 迭代) 光这一条就能刷出百万行、明显拖慢仿真。按本文件惯例补门,
  //    要回看时加 `A910_DT_ARGS=+PROBE_SLVW`。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SLVW") && biu_pad_wvalid && pad_biu_wready)
      $display("  [SLVW] T%0d wr_addr=%08x strb=%04x data=%032x",
               cycles, u_mem.wr_addr, biu_pad_wstrb, biu_pad_wdata);
  end

  // [WDC] WMB → dcache 数据阵列写口: 逐笔 store 的 way / high_sel / data / bytes_vld。
  //   用来查 "store 数据到底写进了高半还是低半、字节掩码对不对"。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_WDC") && dut.u_lsu_top.u_lsu_wmb.wmb_dcache_arb_req)
      $display("  [WDC] T%0d addr=%08x way=%b a4=%b hin=%b data=%032x bv=%04x region=%b grnt=%b",
               cycles, dut.u_lsu_top.u_lsu_wmb.wmb_write_dcache_addr,
               dut.u_lsu_top.u_lsu_wmb.wmb_write_req_dcache_way,
               dut.u_lsu_top.u_lsu_wmb.wmb_write_dcache_addr[4],
               dut.u_lsu_top.u_lsu_wmb.wmb_dcache_data_high_sel,
               dut.u_lsu_top.u_lsu_wmb.wmb_write_dcache_data,
               dut.u_lsu_top.u_lsu_wmb.wmb_write_dcache_bytes_vld,
               dut.u_lsu_top.u_lsu_wmb.wmb_dcache_data_region,
               dut.u_lsu_top.u_lsu_wmb.wmb_write_dcache_success);
  end

  // [LFBW] LFB → dcache 数据阵列写口 (miss 回填): 低/高半 din 与写使能。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LFBW") && dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_sel)
      $display("  [LFBW] T%0d low_idx=%0d low_din=%032x high_din=%032x wen_b=%08x sel_b=%02x",
               cycles, dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_low_idx,
               dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_low_din,
               dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_high_din,
               dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_wen_b,
               dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_sel_b);
  end

  // [HOLD] 误预测冻结窗 (A910_cpu.sv 的本地补丁) 的闸门状态
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_HOLD") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [HOLD] T%0d mispred_hold=%b pulse_seen=%b | iu_chgflw_vld=%b rtu_flush_busy=%b rtu_yy_xx_flush=%b | flush_trig=%b mispred_hit=%b",
               cycles, dut.mispred_hold_q, dut.hold_pulse_seen_q,
               dut.iu_chgflw_vld, dut.rtu_flush_busy, dut.rtu_yy_xx_flush,
               dut.u_rtu.u_commit.flush_trig, dut.u_rtu.u_commit.mispred_hit);
  end

  // [ST] store 流水三级 (AG/DC/DA/WB) + SQ 接收口 —— 看队头那条 store 卡在哪一级
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_ST") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [ST] T%0d st_ag v=%b iid=%0d addr=%08x old=%b | st_dc v=%b iid=%0d | st_da v=%b iid=%0d | st_wb v=%b iid=%0d | sq_full=%b inst_hit=%b",
               cycles,
               dut.u_lsu_top.st_ag_inst_vld, dut.u_lsu_top.st_ag_iid,
               dut.u_lsu_top.st_ag_dc_addr0, dut.u_lsu_top.st_ag_old,
               dut.u_lsu_top.st_dc_inst_vld, dut.u_lsu_top.st_dc_iid,
               dut.u_lsu_top.st_da_inst_vld, dut.u_lsu_top.st_da_iid,
               dut.u_lsu_top.st_wb_inst_vld, 0,
               dut.u_lsu_top.sq_st_dc_full, dut.u_lsu_top.sq_st_dc_inst_hit);
  end

  // [DCL] 盯一段地址区间 (字节地址 DCL_LO..DCL_HI, 默认 0xf700..0xf71f):
  //   store DA 级的 dcache 判据 + WMB CE 的落盘决策。
  //   2026-10-15 加的临时探针, 追 coremark_i1 #46462 (lw ra,28(sp) 读回上一笔的 ra)。
  integer dcl_lo = 32'h0000_f700, dcl_hi = 32'h0000_f71f;
  wire dcl_st_hit = $test$plusargs("PROBE_DCL")
                    && dut.u_lsu_top.u_lsu_st_da.st_da_addr0 >= dcl_lo
                    && dut.u_lsu_top.u_lsu_st_da.st_da_addr0 <= dcl_hi;
  wire dcl_ce_hit = $test$plusargs("PROBE_DCL")
                    && dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_addr >= dcl_lo
                    && dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_addr <= dcl_hi;
  wire dcl_ld_hit = $test$plusargs("PROBE_DCL")
                    && dut.u_lsu_top.u_lsu_ld_da.ld_da_addr >= dcl_lo
                    && dut.u_lsu_top.u_lsu_ld_da.ld_da_addr <= dcl_hi;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_DCL")) begin
      if (dut.u_lsu_top.u_lsu_st_da.st_da_inst_vld && dcl_st_hit)
        $display("  [SDA] T%0d iid=%0d addr=%08x hit=%b way=%b v0=%b v1=%b t0=%b t1=%b da=%b | rpl_way=%b rpl_vld=%b rpl_dirty=%b old=%b",
                 cycles, dut.u_lsu_top.u_lsu_st_da.st_da_iid,
                 dut.u_lsu_top.u_lsu_st_da.st_da_addr0,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_hit,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_way,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_valid0,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_valid1,
                 dut.u_lsu_top.u_lsu_st_da.st_da_tag0_hit,
                 dut.u_lsu_top.u_lsu_st_da.st_da_tag1_hit,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_dirty_array,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_way,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_valid,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_dirty,
                 dut.u_lsu_top.u_lsu_st_da.st_da_old);
      if (dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_vld && dcl_ce_hit)
        $display("  [CEC] T%0d create=%b addr=%08x bv=%04x | dc_valid=%b dc_dirty=%b wdc=%b wbiu=%b | pop=%b mwreq=%b stall=%b mnotvld=%b",
                 cycles,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_create_vld,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_addr,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_bytes_vld,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_dcache_valid,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_dcache_dirty,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_write_dcache_req,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_write_biu_req,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_pop_vld,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_wmb_req,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_stall,
                 dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_not_vld);
      // 回填那一拍: 谁在抢 dcache 的 tag/dirty 写口, 以及最终落到阵列上的 idx/wen/din
      // (单独开关 +PROBE_ARB, 它跟地址无关, 常开太吵)
      if ($test$plusargs("PROBE_ARB")
          && (dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_st_sel
              || dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_st_sel
              || dut.u_lsu_top.u_dcache_arb.wmb_dcache_arb_st_req))
        $display("  [ARB] T%0d lfb_st=%b lfb_ld=%b vb_st=%b wmb_req=%b ag_st=%b | tag: idx=%0d wen_b=%b din=%011x | dirty: idx=%0d gwen_b=%b wen_b=%b din=%b | lfb_idx=%0d wmb_idx=%0d",
                 cycles,
                 dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_st_sel,
                 dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_sel,
                 dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_st_sel,
                 dut.u_lsu_top.u_dcache_arb.wmb_dcache_arb_st_req,
                 dut.u_lsu_top.u_dcache_arb.dcache_arb_ag_st_sel,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_idx,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_wen_b,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_din[21:0],
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_idx,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_gwen_b,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_wen_b,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_din,
                 dut.u_lsu_top.u_dcache_arb.lfb_dcache_arb_st_dirty_idx,
                 dut.u_lsu_top.u_dcache_arb.wmb_dcache_arb_st_dirty_idx);
      if (dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld && dcl_ld_hit)
        $display("  [LDL] T%0d iid=%0d addr=%08x hit=%b way=%b fwd=%b | data_vld=%b wb=%08x",
                 cycles, dut.u_lsu_top.u_lsu_ld_da.ld_da_iid,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_addr,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_hit,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_settle_way,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_fwd_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_data_vld,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_wb_data);
    end
  end

  // [SQD2] SQ 排空路径: 有没有 pop 请求 / CE 有没有收 / 谁挡着
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SQ2") && cycles >= 2680 && cycles <= 2720)
      $display("  [SQD2] T%0d pop_unmask=%b pop_to_ce=%b merge_req=%b | ce_vld=%b ce_create=%b pop_vld=%b sqptr=%b | vld=%b cmit=%b create_ptr=%b pop_ptr=%b | grnt=%b",
               cycles,
               dut.u_lsu_top.u_lsu_sq.sq_pop_req_unmask,
               dut.u_lsu_top.u_lsu_sq.sq_pop_to_ce_req,
               dut.u_lsu_top.sq_wmb_merge_req,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_vld,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_create_vld,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_pop_vld,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_sq_ptr,
               dut.u_lsu_top.u_lsu_sq.sq_entry_vld,
               dut.u_lsu_top.u_lsu_sq.sq_entry_cmit,
               dut.u_lsu_top.u_lsu_sq.sq_create_ptr,
               dut.u_lsu_top.u_lsu_sq.sq_pop_ptr,
               dut.u_lsu_top.wmb_sq_pop_grnt);
  end

  // 【临时诊断 2026-10-14】SQ 队头 ↔ SDIQ 绑定: 队头表项绑的是哪个 SDIQ 号、
  //   那个 SDIQ 表项还在不在(vld/has_in_sq/rdy)、LSU 回的 has_in_sq 是什么。
  //   `+PROBE_SQSD` (窗固定 2686..2700, 悬挂期)
  always @(posedge clk) begin
    // 2026-10-16: 窗口改成走 STL_LO/STL_HI, 并把 6 个 SQ 表项全打出来
    //   (这次卡的是表项 2, 老探针只打表项 0 ⇒ 看不到)。
    if (!rst && $test$plusargs("PROBE_SQSD")
        && cycles >= stl_lo && cycles <= stl_hi && (cycles % 10) == 0) begin
      $display("  [SQSD] T%0d | sq: vld=%b cmit=%b not_dvld=%b",
        cycles,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_cmit,
        dut.u_lsu_top.u_lsu_sq.sq_entry_cmit_data_not_vld);
      $display("         e0 sdid=%b dvld=%b vld=%b cmit=%b | e1 sdid=%b dvld=%b vld=%b cmit=%b | e2 sdid=%b dvld=%b vld=%b cmit=%b",
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_sdid,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_data_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld[0], dut.u_lsu_top.u_lsu_sq.sq_entry_cmit[0],
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_sdid,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_data_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld[1], dut.u_lsu_top.u_lsu_sq.sq_entry_cmit[1],
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[2].x_ct_lsu_sq_entry.sq_entry_sdid,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[2].x_ct_lsu_sq_entry.sq_entry_data_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld[2], dut.u_lsu_top.u_lsu_sq.sq_entry_cmit[2]);
      $display("         e3 sdid=%b dvld=%b vld=%b cmit=%b | e4 sdid=%b dvld=%b vld=%b cmit=%b | e5 sdid=%b dvld=%b vld=%b cmit=%b",
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[3].x_ct_lsu_sq_entry.sq_entry_sdid,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[3].x_ct_lsu_sq_entry.sq_entry_data_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld[3], dut.u_lsu_top.u_lsu_sq.sq_entry_cmit[3],
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[4].x_ct_lsu_sq_entry.sq_entry_sdid,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[4].x_ct_lsu_sq_entry.sq_entry_data_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld[4], dut.u_lsu_top.u_lsu_sq.sq_entry_cmit[4],
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[5].x_ct_lsu_sq_entry.sq_entry_sdid,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[5].x_ct_lsu_sq_entry.sq_entry_data_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld[5], dut.u_lsu_top.u_lsu_sq.sq_entry_cmit[5]);
      $display("         lsu_has_in_sq=%b bcast: sel=%b st_sdiq=%b p5_sdiq=%b p5_vld=%b issue_en=%b | sd0 v=%b has=%b rdy=%b | sd1 v=%b has=%b rdy=%b | sd2 v=%b has=%b rdy=%b | sd3 v=%b has=%b rdy=%b",
        dut.u_lsu_top.lsu_idu_has_in_sq,
        dut.u_lsu_top.idu_lsu_sdiq_sel,
        dut.u_lsu_top.idu_lsu_st_sdiq_entry,
        dut.u_lsu_top.idu_lsu_rf_pipe5_sdiq_entry,
        dut.u_ct_idu_top.x_ct_idu_rf_ctrl.rf_pipe5_inst_vld,
        dut.u_ct_idu_top.sdiq_xx_issue_en,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.vld,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.has_in_sq,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.x_rdy,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_1.vld,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_1.has_in_sq,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_1.x_rdy,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_2.vld,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_2.has_in_sq,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_2.x_rdy,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_3.vld,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_3.has_in_sq,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_3.x_rdy);
    end
  end

  // 【临时诊断 2026-10-16】sdid 流水 + 冲刷: 看建表那一刻绑的 SDIQ 号是哪来的
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SDP") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [SDP] T%0d flush=%b | idu: sel=%b iid=%0d sdiq=%b | ag: vld=%b iid=%0d sdid=%b | dc: vld=%b iid=%0d sdid=%b | sd vld=%b has=%b",
        cycles, dut.rtu_yy_xx_flush,
        dut.idu_lsu_st_sel, dut.idu_lsu_st_iid, dut.idu_lsu_st_sdiq_entry,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_inst_vld, dut.u_lsu_top.u_lsu_st_ag.st_ag_iid,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_sdid_oh,
        dut.u_lsu_top.st_dc_inst_vld, dut.u_lsu_top.st_dc_iid, dut.u_lsu_top.st_dc_sdid_oh,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry_vld,
        {dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_3.has_in_sq,
         dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_2.has_in_sq,
         dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_1.has_in_sq,
         dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.has_in_sq});
  end

  // 【临时诊断 2026-10-16】边界(跨界)store 的 SQ 建表握手逐拍 —— `+PROBE_BD`
  //   盯: st_dc 的 boundary/secd/create/sdid + LSU 回给 IDU 的 has_in_sq 脉冲 + SDIQ 状态。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_BD") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [BD] T%0d | st_dc vld=%b iid=%0d addr=%08x bnd=%b secd=%b first=%b create=%b sdio=%b sqdvld=%b full=%b | pulse=%b | sdiq v=%b has=%b issue=%b | sq vld=%b cmit=%b notdvld=%b",
        cycles,
        dut.u_lsu_top.st_dc_inst_vld, dut.u_lsu_top.st_dc_iid, dut.u_lsu_top.st_dc_addr0,
        dut.u_lsu_top.st_dc_boundary, dut.u_lsu_top.st_dc_secd,
        dut.u_lsu_top.st_dc_boundary_first, dut.u_lsu_top.st_dc_sq_create_vld,
        dut.u_lsu_top.st_dc_sdid_oh, dut.u_lsu_top.st_dc_sq_data_vld,
        dut.u_lsu_top.sq_st_dc_full,
        dut.u_lsu_top.lsu_idu_has_in_sq,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry_vld,
        {dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_3.has_in_sq,
         dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_2.has_in_sq,
         dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_1.has_in_sq,
         dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.has_in_sq},
        dut.u_ct_idu_top.sdiq_xx_issue_en,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_cmit,
        dut.u_lsu_top.u_lsu_sq.sq_entry_cmit_data_not_vld);
  end

  // 【临时诊断 2026-10-16】挂死**起点**的时间线: SDIQ 表项(vld/has_in_sq)/SQ 表项
  //   (vld/cmit/data_vld/sdid)/LSU 回给 IDU 的 has_in_sq 脉冲/冲刷, 任何一项变化就打一行。
  //   `+PROBE_ONSET` (窗走 STL_LO/STL_HI)
  reg [3:0] on_sdv_q = 4'hx, on_sdh_q = 4'hx, on_sqv_q = 6'hx, on_sqc_q = 6'hx, on_sqd_q = 6'hx;
  reg       on_pls_q = 1'bx, on_fls_q = 1'bx, on_init = 0;
  wire [3:0] on_sdv = dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry_vld;
  wire [3:0] on_sdh = {dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_3.has_in_sq,
                       dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_2.has_in_sq,
                       dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_1.has_in_sq,
                       dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.has_in_sq};
  wire [3:0] on_pls = dut.u_lsu_top.lsu_idu_has_in_sq;
  wire [5:0] on_sqv = dut.u_lsu_top.u_lsu_sq.sq_entry_vld;
  wire [5:0] on_sqc = dut.u_lsu_top.u_lsu_sq.sq_entry_cmit;
  wire [5:0] on_sqd = ~dut.u_lsu_top.u_lsu_sq.sq_entry_cmit_data_not_vld | ~on_sqc;  // dvld 的近似: 未提交的当作有
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_ONSET") && cycles >= stl_lo && cycles <= stl_hi) begin
      if (!on_init || on_sdv !== on_sdv_q || on_sdh !== on_sdh_q || on_pls !== on_pls_q
          || on_sqv !== on_sqv_q || on_sqc !== on_sqc_q || on_fls_q !== dut.rtu_yy_xx_flush) begin
        $display("  [ONSET] T%0d flush=%b fsm=%b | sdiq v=%b has=%b | pulse=%b | sq vld=%b cmit=%b notdvld=%b | e0 sdid=%b dvld=%b iid=%0d | e1 sdid=%b dvld=%b iid=%0d | e2 sdid=%b dvld=%b iid=%0d",
          cycles, dut.rtu_yy_xx_flush, dut.u_rtu.u_flush.st_q,
          on_sdv, on_sdh, on_pls, on_sqv, on_sqc,
          dut.u_lsu_top.u_lsu_sq.sq_entry_cmit_data_not_vld,
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_sdid,
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_data_vld,
          dut.u_lsu_top.u_lsu_sq.sq_entry_iid[0],
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_sdid,
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_data_vld,
          dut.u_lsu_top.u_lsu_sq.sq_entry_iid[1],
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[2].x_ct_lsu_sq_entry.sq_entry_sdid,
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[2].x_ct_lsu_sq_entry.sq_entry_data_vld,
          dut.u_lsu_top.u_lsu_sq.sq_entry_iid[2]);
        $display("          e3 sdid=%b dvld=%b iid=%0d | e4 sdid=%b dvld=%b iid=%0d | e5 sdid=%b dvld=%b iid=%0d | st_dc: vld=%b sdio=%b create=%b sqfull=%b",
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[3].x_ct_lsu_sq_entry.sq_entry_sdid,
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[3].x_ct_lsu_sq_entry.sq_entry_data_vld,
          dut.u_lsu_top.u_lsu_sq.sq_entry_iid[3],
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[4].x_ct_lsu_sq_entry.sq_entry_sdid,
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[4].x_ct_lsu_sq_entry.sq_entry_data_vld,
          dut.u_lsu_top.u_lsu_sq.sq_entry_iid[4],
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[5].x_ct_lsu_sq_entry.sq_entry_sdid,
          dut.u_lsu_top.u_lsu_sq.gen_sq_entry[5].x_ct_lsu_sq_entry.sq_entry_data_vld,
          dut.u_lsu_top.u_lsu_sq.sq_entry_iid[5],
          dut.u_lsu_top.st_dc_inst_vld, dut.idu_lsu_st_sdiq_entry,
          dut.u_lsu_top.st_dc_sq_create_vld, dut.u_lsu_top.sq_st_dc_full);
        on_sdv_q <= on_sdv; on_sdh_q <= on_sdh; on_pls_q <= on_pls;
        on_sqv_q <= on_sqv; on_sqc_q <= on_sqc; on_fls_q <= dut.rtu_yy_xx_flush;
        on_init <= 1'b1;
      end
    end
  end

  // 【临时诊断 2026-10-16】LSIQ 二发(双派发)现场 —— `+PROBE_LSIQ` (窗走 STL_LO/STL_HI)
  //   目标: 同一笔 store 为什么被 pipe4 派发两次。盯 LSIQ 的 issued-entry / ready / vld /
  //   unalign_2nd / 每个表项的 frz(发过一次就置 1, 只能被 lsu_frz_clr / unalign_2nd_set /
  //   imme_wakeup 清) + LSU 回的 secd/pop/imme_wakeup + st_da 的 secd 生成条件。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LSIQ") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [LSIQ] T%0d | p4_is=%b p4en=%b iid=%0d | rdy=%b vld=%b sto=%b un2=%b | frz=%b(0..7) | secd=%b popvld=%b popent=%b immwk=%b | stda secd_vld=%b bnd_first=%b rst=%b",
        cycles,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_dp_pipe4_issue_entry,
        dut.u_ct_idu_top.lsiq_xx_pipe4_issue_en,
        dut.idu_lsu_st_iid,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_ready,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_vld,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_store,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.unalign_2nd,
        {dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.frz,
         dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry6.frz,
         dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry5.frz,
         dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry4.frz,
         dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.frz,
         dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.frz,
         dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.frz,
         dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.frz},
        dut.lsu_idu_secd, dut.u_ct_idu_top.lsu_idu_lsiq_pop_vld,
        dut.u_ct_idu_top.lsu_idu_lsiq_pop_entry,
        dut.u_ct_idu_top.lsu_idu_imme_wakeup,
        dut.u_lsu_top.u_lsu_st_da.st_da_idu_secd_vld,
        dut.u_lsu_top.u_lsu_st_da.st_da_boundary_first,
        dut.u_lsu_top.u_lsu_st_da.st_da_restart_vld);
  end

  // 【临时诊断 2026-10-14】SQ 表项 0 **建表那一拍**抓到了什么 —— 定位
  //   `data_vld=0 & sdid=0000` 这个非法孤儿态是哪来的。`+PROBE_SQCR` (只打前 40 次)
  integer sqcr_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SQCR") && sqcr_lines < 40
        && dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_create_vld
        && dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.st_dc_sdid == 4'b0000) begin
      sqcr_lines = sqcr_lines + 1;
      $display("  [SQCR] T%0d e0 create: st_dc_sdid_lat=%b st_dc_sq_data_vld=%b st_dc_iid=%0d | idu_st_sdiq=%b idu_st_iid=%0d st_sel=%b | st_dc_inst_vld=%b st_dc_iid=%0d | full=%b has_in_sq=%b",
        cycles,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.st_dc_sdid,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.st_dc_sq_data_vld,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.st_dc_iid,
        dut.idu_lsu_st_sdiq_entry, dut.idu_lsu_st_iid, dut.idu_lsu_st_sel,
        dut.u_lsu_top.st_dc_inst_vld, dut.u_lsu_top.st_dc_iid,
        dut.u_lsu_top.sq_st_dc_full, dut.u_lsu_top.lsu_idu_has_in_sq);
    end
  end

  // 【临时诊断 2026-10-14】IDU 派了一条 **sdiq_entry=0** 的 store(=AG 会把它存成
  //   `st_ag_sdid_oh=0000` ⇒ DC 建表 ⇒ 孤儿表项, 数据永远补不回来)。`+PROBE_ZSD`
  integer zsd_lines = 0;
  integer zsd_since_flush = 0;      // 距上次 rtu_yy_xx_flush 多少拍
  always @(posedge clk) begin
    if (rst) zsd_since_flush <= 0;
    else if (dut.rtu_yy_xx_flush) zsd_since_flush <= 0;
    else if (zsd_since_flush < 100000) zsd_since_flush <= zsd_since_flush + 1;
  end
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_ZSD") && zsd_lines < 30
        && dut.idu_lsu_st_sel && dut.idu_lsu_st_sdiq_entry == 4'b0000) begin
      zsd_lines = zsd_lines + 1;
      $display("  [ZSD] T%0d IDU 派了 sdiq_entry=0 的 store! iid=%0d | ag_stall=%b ag_inst_vld=%b ag_sdid=%b ag_iid=%0d | dc_inst_vld=%b dc_iid=%0d dc_sdid=%b | has_in_sq=%b | 距上次flush=%0d 拍 flush_now=%b chgflw=%b | sdiq_vld=%b%b%b%b sqfull=%b",
        cycles, dut.idu_lsu_st_iid,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_stall_vld, dut.u_lsu_top.u_lsu_st_ag.st_ag_inst_vld,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_sdid_oh, dut.u_lsu_top.u_lsu_st_ag.st_ag_iid,
        dut.u_lsu_top.st_dc_inst_vld, dut.u_lsu_top.st_dc_iid, dut.u_lsu_top.st_dc_sdid_oh,
        dut.u_lsu_top.lsu_idu_has_in_sq,
        zsd_since_flush, dut.rtu_yy_xx_flush, dut.iu_chgflw_vld,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_3.vld,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_2.vld,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_1.vld,
        dut.u_ct_idu_top.x_ct_idu_is_sdiq.u_ct_idu_is_sdiq_entry_0.vld,
        dut.u_lsu_top.sq_st_dc_full);
    end
  end

  // 【临时诊断 2026-10-14】判决性实验: **从 T2700 起强行打开**误预测冻结闸门
  //   (最后一次退休在 T2695), 看机器能否自愈。
  //   若照样卡死 ⇒ 闸门不是这个 hang 的成因(只是旁观者)。`+FORCE_OPEN`
  //   ⚠️ 不能从 0 拍就强开: 闸门早期本来在干活, 那样第 14 条退休就崩(实测)。
  always @(posedge clk) begin
    if (!rst && cycles >= 2700 && $test$plusargs("FORCE_OPEN")) force dut.idu_hold = 1'b0;
  end

  // 【临时诊断 2026-10-14】孤儿产生的**那一拍**: `ctrl_sdiq_create0_en=1` 但分配器
  //   返回 `0000`(满 或 vld 向量带 X)。同时看守卫 `ctrl_is_dis_stall` 为什么没拦住。
  //   `+PROBE_ALLOC`
  integer al_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_ALLOC") && al_lines < 30
        && dut.u_ct_idu_top.ctrl_lsiq_create0_en
        && dut.u_ct_idu_top.x_ct_idu_is_dp.ctrl_is_sdiq_create0_entry == 4'b0000) begin
      al_lines = al_lines + 1;
      $display("  [ALLOC] T%0d ** 建 LSIQ 表项但 SDIQ 字段=0 ** | lsiq0_en=%b sdiq0_en=%b | pre_lsiq0_en=%b pre_sdiq0_en=%b | is_dis_lsiq0=%b is_dis_sdiq0=%b | dis_stall=%b iq_full=%b | 距上次flush=%0d",
        cycles,
        dut.u_ct_idu_top.ctrl_lsiq_create0_en, dut.u_ct_idu_top.ctrl_sdiq_create0_en,
        dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_ir_pre_dis_lsiq_create0_en,
        dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_ir_pre_dis_sdiq_create0_en,
        dut.u_ct_idu_top.x_ct_idu_is_ctrl.is_dis_lsiq_create0_en,
        dut.u_ct_idu_top.x_ct_idu_is_ctrl.is_dis_sdiq_create0_en,
        dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_dis_stall,
        dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_iq_full,
        zsd_since_flush);
    end
  end

  // [SQD3] 逐表项: pop_req 为什么是 0 (data_vld / no_restart / in_wmb_ce)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SQ3") && cycles >= 2690 && cycles <= 2692) begin
      $display("  [SQD3] T%0d e0 vld=%b cmit=%b data_vld=%b no_restart=%b in_ce=%b pop_req=%b | e1 vld=%b cmit=%b data_vld=%b no_restart=%b in_ce=%b pop_req=%b | e2 in_ce=%b pop_req=%b",
        cycles,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld[0], dut.u_lsu_top.u_lsu_sq.sq_entry_cmit[0],
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_data_vld,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_no_restart,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_in_wmb_ce,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_pop_req,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld[1], dut.u_lsu_top.u_lsu_sq.sq_entry_cmit[1],
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_data_vld,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_no_restart,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_in_wmb_ce,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_pop_req,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[2].x_ct_lsu_sq_entry.sq_entry_in_wmb_ce,
        dut.u_lsu_top.u_lsu_sq.gen_sq_entry[2].x_ct_lsu_sq_entry.sq_entry_pop_req);
    end
  end

  // [HIS] "store 已进 SQ" 脉冲 (LSU ST_DC → IDU SDIQ 表项的 has_in_sq 置位源)
  //   整跑打印: 建表事件 + 脉冲非零事件
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_HIS")
        && (dut.u_lsu_top.st_dc_sq_create_vld || (dut.lsu_idu_has_in_sq != 4'b0)))
      $display("  [HIS] T%0d his=%b sdid_oh=%b sq_create=%b sq_full=%b sdid=%b | SQe0.sdid=%0d SQe0.data_vld=%b",
               cycles, dut.lsu_idu_has_in_sq, dut.u_lsu_top.st_dc_sdid_oh,
               dut.u_lsu_top.st_dc_sq_create_vld, dut.u_lsu_top.sq_st_dc_full,
               4'b0,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_sdid,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_data_vld);
  end

  // [STSEL] IDU 交给 LSU 的 store: 带的 sdid 是不是 0
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_STSEL") && dut.u_lsu_top.idu_lsu_st_sel)
      $display("  [STSEL] T%0d sel=1 iid=%0d sdiq_entry=%b st_inst_vld=%b lch_entry=%b",
               cycles, dut.u_lsu_top.idu_lsu_st_iid,
               dut.u_lsu_top.idu_lsu_st_sdiq_entry,
               1'b0,
               dut.u_lsu_top.idu_lsu_st_lch_entry);
  end

  // [WIN] IR 窗口每拍的 store 标志: vld / lsiq / sdiq 三组 + 两个 create1 条件
  integer win_c;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_WIN")) begin
      for (win_c = 0; win_c < 3; win_c = win_c + 1) begin
        if ((cycles >= 400 && cycles <= 408) || (cycles >= 2448 && cycles <= 2456) || (cycles >= 570 && cycles <= 576)) begin
          if (win_c == 0)
            $display("  [WIN] T%0d vld=%b%b%b lsiq=%b%b%b sdiq=%b%b%b | create0=%b create1=%b sel1i1=%b",
                     cycles,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst0_vld,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst1_vld,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst2_vld,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst0_lsiq,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst1_lsiq,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst2_lsiq,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst0_sdiq,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst1_sdiq,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst2_sdiq,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_sdiq_create0_en,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_sdiq_create1_en,
                     dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_sdiq_create1_sel_inst1);
        end
      end
    end
  end

  // [LSQ] LSIQ 建表: sdiq_entry 字段是不是 0 (0 = 这条 store 没有 SDIQ 表项)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LSQ")
        && ( (dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_lsiq_create0_en
              && dut.u_ct_idu_top.x_ct_idu_is_dp.dp_lsiq_create0_data[48]      // store
              && dut.u_ct_idu_top.x_ct_idu_is_dp.dp_lsiq_create0_data[52:49] == 4'b0)
          || (dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_lsiq_create1_en
              && dut.u_ct_idu_top.x_ct_idu_is_dp.dp_lsiq_create1_data[48]      // store
              && dut.u_ct_idu_top.x_ct_idu_is_dp.dp_lsiq_create1_data[52:49] == 4'b0) ))
      $display("  [LSQ] T%0d c0_data.sdiq=%b c1_data.sdiq=%b | lsiq_c0=%b lsiq_c1=%b sdiq_c0=%b sdiq_c1=%b | dis_stall=%b iq_full=%b rob_full=%b | c0_iid=%0d c1_iid=%0d",
               cycles,
               dut.u_ct_idu_top.x_ct_idu_is_dp.dp_lsiq_create0_data[52:49],
               dut.u_ct_idu_top.x_ct_idu_is_dp.dp_lsiq_create1_data[52:49],
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_lsiq_create0_en,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_lsiq_create1_en,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_sdiq_create0_en,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_sdiq_create1_en,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_dis_stall,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_iq_full,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_rob_full,
               dut.u_ct_idu_top.x_ct_idu_is_dp.lsiq_create0_data[59:53],
               dut.u_ct_idu_top.x_ct_idu_is_dp.lsiq_create1_data[59:53]);
  end

  // [STSEL] IDU 交给 LSU 的 store: 带的 sdid 是不是 0
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_STSEL") && dut.u_lsu_top.idu_lsu_st_sel)
      $display("  [STSEL] T%0d sel=1 iid=%0d sdiq_entry=%b st_inst_vld=%b lch_entry=%b",
               cycles, dut.u_lsu_top.idu_lsu_st_iid,
               dut.u_lsu_top.idu_lsu_st_sdiq_entry,
               1'b0,
               dut.u_lsu_top.idu_lsu_st_lch_entry);
  end

  // [CRE] 派发窗口里有几条 store / SDIQ 创建有没有发够
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_CRE")
        && (dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst0_sdiq
         || dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst1_sdiq
         || dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst2_sdiq))
      $display("  [CRE] T%0d win_sdiq=%b%b%b | sdiq_c0_en=%b sdiq_c1_en=%b | lsiq_c0_en=%b | dis_stall=%b rob_full=%b iq_full=%b | sdiq_cnt=%0d | e0=%b e1=%b",
               cycles,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst0_sdiq,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst1_sdiq,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst2_sdiq,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_sdiq_create0_en,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_sdiq_create1_en,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_lsiq_create0_en,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_dis_stall,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_rob_full,
               dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_iq_full,
               dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry_cnt,
               dut.u_ct_idu_top.x_ct_idu_is_dp.ctrl_is_sdiq_create0_entry,
               dut.u_ct_idu_top.x_ct_idu_is_dp.ctrl_is_sdiq_create1_entry);
  end

  // [SDQ] IDU 的 SDIQ (store data 发射队列): 有没有 entry 可以发 / 为什么发不出去
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SDQ") && cycles >= 2680 && cycles <= 2700)
      $display("  [SDQ] T%0d vld=%b rdy=%b ready=%b older=%b issue_en=%b | sel=%b id=%b src0=%08x | SQe0.sdid=%0d hit=%b",
               cycles,
               dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry_vld,
               {dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry3_rdy,
                dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry2_rdy,
                dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry1_rdy,
                dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry0_rdy},
               dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry_ready,
               dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_older_entry_ready,
               dut.u_ct_idu_top.x_ct_idu_is_sdiq.sdiq_entry_issue_en,
               dut.idu_lsu_sdiq_sel, dut.idu_lsu_rf_pipe5_sdiq_entry,
               dut.idu_lsu_rf_pipe5_src0,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_sdid,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_st_data_sdid_hit);
  end



  // 【临时诊断】LFB 逐拍 (T150530..T150590): fill 为什么完不成
  always @(posedge clk) begin
    if (!rst && cycles >= 150530 && cycles <= 150590) begin
      $display("  [LFPE] T%0d rcl_done=%b dcache_hit=%b refill_way=%b | de_id=%0d r_id=%0d | vb_vld=%b vb_rcl_done=%b vb_sm=%0d vb_aw=%b",
        cycles,
        dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_rcl_done,
        dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_dcache_hit,
        dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_refill_way,
        dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_id,
        dut.u_lsu_top.biu_lsu_r_id,
        dut.u_lsu_top.u_lsu_vb.vb_vld,
        dut.u_lsu_top.u_lsu_vb.vb_lfb_rcl_done,
        dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_state,
        dut.u_lsu_top.u_lsu_vb.vb_biu_aw_req);
      $display("  [LFPD] T%0d de_vld=%b success=%b linefill_permit=%b lfsm_req=%b | addr_permit=%b addr_vld=%b addr_depd=%b | de_id=%0d r_id=%0d r_ready=%b",
        cycles,
        dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_vld,
        dut.u_lsu_top.u_lsu_lfb.u_lfb_data_entry.lfb_data_entry_lf_sm_req_success,
        dut.u_lsu_top.u_lsu_lfb.u_lfb_data_entry.lfb_data_entry_linefill_permit,
        dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_lf_sm_req,
        dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_linefill_permit,
        dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_vld,
        dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_depd,
        dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_id,
        dut.u_lsu_top.biu_lsu_r_id,
        dut.u_lsu_top.lsu_biu_r_ready);
    end
    if (!rst && cycles >= 150530 && cycles <= 150590)
      $display("  [LFBP] T%0d lfsm_vld=%b lfsm_create=%b ld_grnt=%b | de_vld=%b de_create=%b tag_req=%b arready=%b | r_id_hit=%b r_vld=%b | aflush=%b yyflush=%b | aevld=%b",
        cycles,
        dut.u_lsu_top.u_lsu_lfb.lfb_lf_sm_vld,
        dut.u_lsu_top.u_lsu_lfb.lfb_lf_sm_create_vld,
        dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_grnt,
        dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_vld,
        dut.u_lsu_top.u_lsu_lfb.lfb_data_create_vld,
        dut.u_lsu_top.u_lsu_lfb.lfb_dcache_arb_ld_tag_req,
        dut.u_lsu_top.u_lsu_lfb.lfb_biu_arready,
        dut.u_lsu_top.u_lsu_lfb.lfb_biu_r_id_hit,
        dut.u_lsu_top.biu_lsu_r_vld,
        dut.rtu_lsu_async_flush,
        dut.rtu_yy_xx_flush,
        dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_vld);
  end

  // 【临时诊断】MD (乘除) 通路逐拍 —— `+PROBE_MD` (窗由 STL_LO/STL_HI 给)
  //   2026-10-15 新卡点 T393173: 反汇编 bin/coremark_i1.hex 得
  //     0x1e48 = `divu a1,a1,a2`, 0x1e2c = `remu a5,a1,a2`, 0x1e50 = `bgeu a7,a2,0x1e2c`
  //   —— 队头**不是 load, 而是一条 DIVU**(整数转十进制字符串那个循环)。
  //   看: IDU 的 div 队列发没发、适配级收没收、div_pipe 在哪个状态、响应回没回。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_MD") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [MD] T%0d idu: div_sel=%b iid=%0d rsel=%b | mult_sel=%b iid=%0d | divque_ie=%b vld=%b | multque_ie=%b | stall=%b",
        cycles,
        dut.idu_div_sel, dut.idu_div_iid, dut.idu_div_rslt_sel,
        dut.idu_mult_sel, dut.idu_mult_iid,
        dut.u_ct_idu_top.x_ct_idu_is_div.md_xx_issue_en,
        dut.u_ct_idu_top.x_ct_idu_is_div.md_entry_vld,
        dut.u_ct_idu_top.x_ct_idu_is_mult.md_xx_issue_en,
        dut.u_iu_md_pipe.md_unit_stall);
      $display("  [MD2] T%0d hold=%b idx=%0d iid=%0d | accept=%b busy=%b | req_vld=%b op=%0d tag_iid=%0d | divstate=%0d resp_vld=%b is_div=%b div_resp_vld=%b | mul_ready=%b cmplt=%b,%0d | fl=%b",
        cycles,
        dut.u_iu_md_pipe.div_hold_vld, dut.u_iu_md_pipe.div_hold_idx,
        dut.u_iu_md_pipe.div_hold_iid,
        dut.u_iu_md_pipe.div_accept, dut.u_iu_md_pipe.div_busy,
        dut.u_iu_md_pipe.req_vld_mux, dut.u_iu_md_pipe.req_op_mux,
        dut.u_iu_md_pipe.div_req_tag[12:6],
        dut.u_iu_md_pipe.u_muldiv.U_DIV_PIPE.state,
        dut.u_iu_md_pipe.resp_valid, dut.u_iu_md_pipe.resp_is_div,
        dut.u_iu_md_pipe.div_resp_vld,
        dut.u_iu_md_pipe.mul_ready,
        dut.u_iu_md_pipe.cmplt_vld, dut.u_iu_md_pipe.cmplt_iid,
        dut.rtu_yy_xx_flush);
    end
  end

  // 【临时诊断】LFB addr entry 逐拍 (2026-10-15, 卡点 T150548):
  //   entry0 的 dcache_hit 到底是"真命中"还是 VB rcl 比错了 tag。
  //   +PROBE_LF2, 窗 LF2_LO/LF2_HI (默认 150400..150600)
  integer lf2_lo = 140000, lf2_hi = 150600;
  integer tag_lo = 150515, tag_hi = 150540;
  initial begin
    void'($value$plusargs("LF2_LO=%d", lf2_lo));
    void'($value$plusargs("LF2_HI=%d", lf2_hi));
    void'($value$plusargs("TAG_LO=%d", tag_lo));
    void'($value$plusargs("TAG_HI=%d", tag_hi));
  end
  reg [4:0]  tag_idx_p = 5'b0;
  reg [43:0] tag_dout_p = 44'b0;
  reg [4:0]  tag_dirty_p = 5'b0;
  reg [2:0] lfa_vld_p = 3'b0;
  reg [2:0] lfa_rcl_p = 3'b0;
  reg [2:0] lfa_hit_p = 3'b0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LF2") && cycles >= lf2_lo && cycles <= lf2_hi) begin
      // 表项变化 (建/清/rcl/命中)
      if (dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_vld    !== lfa_vld_p ||
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_rcl_done !== lfa_rcl_p ||
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_dcache_hit !== lfa_hit_p) begin
        $display("  [LFA] T%0d vld %b->%b rcl=%b hit=%b way=%b permit=%b depd=%b disc=%b create=%b cptr=%b | a0=%07x a1=%07x a2=%07x",
          cycles, lfa_vld_p, dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_vld,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_rcl_done,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_dcache_hit,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_refill_way,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_linefill_permit,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_depd,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_discard_vld,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_rb_create_vld,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_create_ptr,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_addr_tto4_v[0],
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_addr_tto4_v[1],
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_addr_tto4_v[2]);
        lfa_vld_p <= dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_vld;
        lfa_rcl_p <= dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_rcl_done;
        lfa_hit_p <= dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_dcache_hit;
      end
      // 逐拍: st 流水线的 tag 抢用 + 寄存器对齐 (dout 对应**上一拍**presented 的 idx)
      if ((cycles < 150515 && 0) || 1) begin
        tag_idx_p  <= dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_idx;
        tag_dout_p <= dut.u_lsu_top.dcache_lsu_st_tag_dout;
        tag_dirty_p<= dut.u_lsu_top.dcache_lsu_st_dirty_dout;
      end
      if (dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_state != 3'b000
          || dut.u_lsu_top.dcache_arb_st_dc_borrow_vld
          || dut.u_lsu_top.u_lsu_st_dc.st_dc_borrow_vld
          || dut.u_lsu_top.u_lsu_st_da.st_da_borrow_vld)
      $display("  [TAG] T%0d st_req=%b st_sel=%b(idx=%02x) | LFB=%b VB=%b AG=%b WMB=%b | borr_vld_dc=%b agb=%b | sdc addr=%08x idx=%02x t0=%b t1=%b ivld=%b bvld=%b v=%05x | sda ivld=%b bvld=%b addr=%08x t0=%b t1=%b hit=%b v=%05x | pidx=%02x pdout=%011x pdirty=%05x | vb_sm=%0d vb_rcl_done=%b",
        cycles,
        dut.u_lsu_top.u_dcache_arb.dcache_arb_st_req,
        dut.u_lsu_top.u_dcache_arb.dcache_arb_st_sel,
        dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_idx,
        dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_st_sel,
        dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_st_sel,
        dut.u_lsu_top.u_dcache_arb.dcache_arb_ag_st_sel,
        dut.u_lsu_top.u_dcache_arb.dcache_arb_wmb_st_sel,
        dut.u_lsu_top.dcache_arb_st_dc_borrow_vld,
        dut.u_lsu_top.dcache_arb_st_ag_borrow_addr_vld,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_addr0,
        dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_idx,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_da_tag0_hit,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_da_tag1_hit,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_inst_vld,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_borrow_vld,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_da_dcache_dirty_array,
        dut.u_lsu_top.u_lsu_st_da.st_da_inst_vld,
        dut.u_lsu_top.u_lsu_st_da.st_da_borrow_vld,
        dut.u_lsu_top.u_lsu_st_da.st_da_addr0,
        dut.u_lsu_top.u_lsu_st_da.st_da_tag0_hit,
        dut.u_lsu_top.u_lsu_st_da.st_da_tag1_hit,
        dut.u_lsu_top.u_lsu_st_da.st_da_dcache_hit,
        dut.u_lsu_top.u_lsu_st_da.st_da_dcache_dirty_array,
        tag_idx_p,
        tag_dout_p,
        tag_dirty_p,
        dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_state,
        dut.u_lsu_top.u_lsu_vb.vb_rcl_done);
      tag_idx_p  <= dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_idx;
      tag_dout_p <= dut.u_lsu_top.dcache_lsu_st_tag_dout;
      tag_dirty_p<= dut.u_lsu_top.dcache_lsu_st_dirty_dout;
      // VB 在 CMP_TAG 那一拍: 比的是哪条地址、tag 阵列里有什么
      if (dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_state == 3'b011)
        $display("  [VBC] T%0d vb_vld=%b vb_tto5=%07x src=%0d | st_dc_addr0=%08x idx=%02x | dc_tag_dout=%011x dc_dirty=%05x | sdc t0=%b t1=%b inst=%b borr=%b | sda borr=%b hit=%b t0=%b t1=%b | rplway=%b rplvld=%b | vb_hit=%b rcl_done=%b | agb=%b dcarb_borr=%b ag_addr=%08x",
          cycles,
          dut.u_lsu_top.u_lsu_vb.vb_vld,
          dut.u_lsu_top.u_lsu_vb.vb_addr_tto5,
          dut.u_lsu_top.u_lsu_vb.vb_source_id,
          dut.u_lsu_top.u_lsu_st_dc.st_dc_addr0,
          dut.u_lsu_top.dcache_idx,
          dut.u_lsu_top.dcache_lsu_st_tag_dout,
          dut.u_lsu_top.dcache_lsu_st_dirty_dout,
          dut.u_lsu_top.u_lsu_st_dc.st_dc_da_tag0_hit,
          dut.u_lsu_top.u_lsu_st_dc.st_dc_da_tag1_hit,
          dut.u_lsu_top.u_lsu_st_dc.st_dc_inst_vld,
          dut.u_lsu_top.u_lsu_st_dc.st_dc_borrow_vld,
          dut.u_lsu_top.u_lsu_st_da.st_da_borrow_vld,
          dut.u_lsu_top.u_lsu_st_da.st_da_dcache_hit,
          dut.u_lsu_top.u_lsu_st_da.st_da_tag0_hit,
          dut.u_lsu_top.u_lsu_st_da.st_da_tag1_hit,
          dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_way,
          dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_valid,
          dut.u_lsu_top.vb_lfb_dcache_hit,
          dut.u_lsu_top.vb_lfb_addr_entry_rcl_done,
          dut.u_lsu_top.dcache_arb_st_ag_borrow_addr_vld,
          dut.u_lsu_top.dcache_arb_st_dc_borrow_vld,
          dut.u_lsu_top.u_lsu_st_ag.st_ag_dc_addr0);
      // load 在 DA 级: 是命中 dcache 还是 discard 到 LFB
      if (cycles >= 150500 && dut.u_lsu_top.ld_da_inst_vld)
        $display("  [LDL] T%0d ld_da addr=%08x idx=%02x hit=%b | disc_req=%b disc_grnt=%b lsid=%b | lfb_idxmask=%b aevld=%b",
          cycles,
          dut.u_lsu_top.u_lsu_ld_da.ld_da_addr,
          dut.u_lsu_top.ld_da_idx,
          dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_hit,
          dut.u_lsu_top.ld_da_hit_idx_discard_req,
          dut.u_lsu_top.ld_da_lfb_discard_grnt,
          dut.u_lsu_top.ld_da_lsid,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_ld_da_hit_idx,
          dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_vld);
    end
  end

  // 【临时诊断】dcache 三个阵列的写口逐拍 (2026-10-15, 卡点 T150548):
  //   查 "LFB 回填写进了 st tag/dirty, 但 ld tag 没写" 这类分裂。
  //   +PROBE_ARR, 窗 ARR_LO/ARR_HI (默认 149870..149910)
  integer arr_lo = 149870, arr_hi = 149910;
  initial begin
    void'($value$plusargs("ARR_LO=%d", arr_lo));
    void'($value$plusargs("ARR_HI=%d", arr_hi));
  end
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_ARR") && cycles >= arr_lo && cycles <= arr_hi) begin
      // 任一写口开着就打印
      if (!dut.u_lsu_top.lsu_dcache_ld_tag_gwen_b
          || !dut.u_lsu_top.lsu_dcache_st_tag_gwen_b
          || !dut.u_lsu_top.lsu_dcache_st_dirty_gwen_b) begin
        $display("  [ARR] T%0d LDtag gwen_b=%b idx=%02x din=%012x wen_b=%02b sel_b=%b || STtag gwen_b=%b idx=%02x din=%011x wen_b=%02b || DIRTY gwen_b=%b idx=%02x din=%05x wen_b=%05b",
          cycles,
          dut.u_lsu_top.lsu_dcache_ld_tag_gwen_b, dut.u_lsu_top.lsu_dcache_ld_tag_idx,
          dut.u_lsu_top.lsu_dcache_ld_tag_din, dut.u_lsu_top.lsu_dcache_ld_tag_wen_b,
          dut.u_lsu_top.lsu_dcache_ld_tag_sel_b,
          dut.u_lsu_top.lsu_dcache_st_tag_gwen_b, dut.u_lsu_top.lsu_dcache_st_tag_idx,
          dut.u_lsu_top.lsu_dcache_st_tag_din, dut.u_lsu_top.lsu_dcache_st_tag_wen_b,
          dut.u_lsu_top.lsu_dcache_st_dirty_gwen_b, dut.u_lsu_top.lsu_dcache_st_dirty_idx,
          dut.u_lsu_top.lsu_dcache_st_dirty_din, dut.u_lsu_top.lsu_dcache_st_dirty_wen_b);
        $display("       LFB lf_vld=%b create=%b ld_sel=%b st_sel=%b grnt=%b | VB ld_sel=%b st_sel=%b sm=%0d | AG st_sel=%b | WMB ld_sel=%b st_sel=%b",
          dut.u_lsu_top.u_lsu_lfb.lfb_lf_sm_vld,
          dut.u_lsu_top.u_lsu_lfb.lfb_lf_sm_create_vld,
          dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_sel,
          dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_st_sel,
          dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_grnt,
          dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_ld_sel,
          dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_st_sel,
          dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_state,
          dut.u_lsu_top.u_dcache_arb.dcache_arb_ag_st_sel,
          dut.u_lsu_top.u_dcache_arb.dcache_arb_wmb_ld_sel,
          dut.u_lsu_top.u_dcache_arb.dcache_arb_wmb_st_sel);
      end
    end
    // 死锁现场: 直接把阵列内容抠出来 (idx 0x1a..0x1c)
    if (!rst && $test$plusargs("PROBE_ARR") && cycles == 150560)
      $display("  [MEM] T%0d ldtag[1a]=%012x ldtag[1b]=%012x ldtag[1c]=%012x | sttag[1a]=%011x sttag[1b]=%011x sttag[1c]=%011x | dirty[1a]=%05x dirty[1b]=%05x dirty[1c]=%05x",
        cycles,
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_tag_array.x_ct_spsram_32x46.mem_q[5'h1a],
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_tag_array.x_ct_spsram_32x46.mem_q[5'h1b],
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_tag_array.x_ct_spsram_32x46.mem_q[5'h1c],
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_tag_array.x_ct_spsram_32x44.mem_q[5'h1a],
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_tag_array.x_ct_spsram_32x44.mem_q[5'h1b],
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_tag_array.x_ct_spsram_32x44.mem_q[5'h1c],
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_dirty_array.x_ct_spsram_32x5.mem_q[5'h1a],
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_dirty_array.x_ct_spsram_32x5.mem_q[5'h1b],
        dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_dirty_array.x_ct_spsram_32x5.mem_q[5'h1c]);
  end

  // 【临时诊断】load 三级流水 + ld tag 阵列读口 (2026-10-15):
  //   load 到底"该命中却报 miss" 还是"检查时确实还没有".  +PROBE_LDP, 窗 LDP_LO/LDP_HI
  integer ldp_lo = 149880, ldp_hi = 149905;
  initial begin
    void'($value$plusargs("LDP_LO=%d", ldp_lo));
    void'($value$plusargs("LDP_HI=%d", ldp_hi));
  end
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LDP") && cycles >= ldp_lo && cycles <= ldp_hi)
      $display("  [LDP] T%0d ldag v=%b a=%08x | ldc v=%b a=%08x hit=%b v0=%b v1=%b t0=%b t1=%b | lda v=%b a=%08x hit=%b cre=%b unmask=%b disc=%b | ldidx=%02x ldout=%012x | lfbc=%b rbbc=%b lfbidx=%b",
        cycles,
        dut.u_lsu_top.u_lsu_ld_ag.ld_ag_inst_vld, dut.u_lsu_top.dcache_arb_ld_ag_addr,
        dut.u_lsu_top.u_lsu_ld_dc.ld_dc_inst_vld, dut.u_lsu_top.u_lsu_ld_dc.ld_dc_addr0,
        dut.u_lsu_top.u_lsu_ld_dc.ld_dc_dcache_hit,
        dut.u_lsu_top.u_lsu_ld_dc.ld_dc_dcache_valid0, dut.u_lsu_top.u_lsu_ld_dc.ld_dc_dcache_valid1,
        dut.u_lsu_top.u_lsu_ld_dc.ld_dc_way0_tag_hit, dut.u_lsu_top.u_lsu_ld_dc.ld_dc_way1_tag_hit,
        dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld, dut.u_lsu_top.u_lsu_ld_da.ld_da_addr,
        dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_hit,
        dut.u_lsu_top.u_lsu_ld_da.ld_da_rb_create_vld,
        dut.u_lsu_top.u_lsu_ld_da.ld_da_rb_create_vld_unmask,
        dut.u_lsu_top.u_lsu_ld_da.ld_da_hit_idx_discard_req,
        dut.u_lsu_top.lsu_dcache_ld_tag_idx, dut.u_lsu_top.dcache_lsu_ld_tag_dout,
        dut.u_lsu_top.rb_lfb_create_vld,
        dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_rb_create_vld,
        dut.u_lsu_top.u_lsu_lfb.lfb_rb_biu_req_hit_idx);
  end

  // 【临时诊断】read buffer (MSHR) 4 个表项 + load 归档口 (2026-10-15 修完 T150548 后
  //   的新卡点 T393173: ROB 队头 pc=0x1e48 的 load 永不完成) +PROBE_RB, 窗由 STL_LO/STL_HI 给
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RB") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [RB] T%0d vld=%b iid=%0d,%0d,%0d,%0d st=%b,%b,%b,%b dest=%b,%b,%b,%b | data_req=%b cplt_req=%b data_iid=%0d data=%08x |  ld_da v=%b iid=%0d a=%08x rb_cr=%b rb_dis=%b rbdat=%b",
        cycles,
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vld,
        dut.u_lsu_top.u_lsu_mshr.rb_entry_iid[0], dut.u_lsu_top.u_lsu_mshr.rb_entry_iid[1],
        dut.u_lsu_top.u_lsu_mshr.rb_entry_iid[2], dut.u_lsu_top.u_lsu_mshr.rb_entry_iid[3],
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_state,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[1].u_mshr_entry.rb_entry_state,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[2].u_mshr_entry.rb_entry_state,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[3].u_mshr_entry.rb_entry_state,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_dest_vld,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[1].u_mshr_entry.rb_entry_dest_vld,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[2].u_mshr_entry.rb_entry_dest_vld,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[3].u_mshr_entry.rb_entry_dest_vld,
        dut.u_lsu_top.rb_ld_wb_data_req, dut.u_lsu_top.rb_ld_wb_cmplt_req,
        dut.u_lsu_top.rb_ld_wb_data_iid, dut.u_lsu_top.rb_ld_wb_data,
        dut.u_lsu_top.ld_da_inst_vld, dut.u_lsu_top.ld_da_iid,
        dut.u_lsu_top.u_lsu_ld_da.ld_da_addr,
        dut.u_lsu_top.ld_da_rb_create_vld, dut.u_lsu_top.ld_da_hit_idx_discard_req,
        dut.u_lsu_top.u_lsu_ld_da.ld_da_rb_data_vld);
  end

  // 【临时诊断】LFB wakeup queue 变化追踪 (2026-10-15, 修完 #75039 后的新卡点 T150548)
  //   [LFB] 探针显示: wkq=00001100 两条 load 挂在 LFB 上, 但 lf_vld=0 (没有在途 fill)
  //   ⇒ 队列里的等待位永远不会被清 ⇒ 这两条 load 永不出结果 ⇒ LQ 满、ROB 队头不完。
  reg [7:0] wkq_prev = 8'hff;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_WKQ")
        && dut.u_lsu_top.u_lsu_lfb.lfb_wakeup_queue !== wkq_prev) begin
      $display("  [WKQ] T%0d wkq %b -> %b | pop_ff=%b set=%b setvec=%b wakeup=%b | lfb_vld=%b",
        cycles, wkq_prev, dut.u_lsu_top.u_lsu_lfb.lfb_wakeup_queue,
        dut.u_lsu_top.u_lsu_lfb.lfb_pop_depd_ff,
        dut.u_lsu_top.ld_da_hit_idx_discard_req,
        dut.u_lsu_top.ld_da_lsid,
        dut.u_lsu_top.u_lsu_lfb.lfb_depd_wakeup,
        dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_vld);
      wkq_prev <= dut.u_lsu_top.u_lsu_lfb.lfb_wakeup_queue;
    end
  end

  // 【临时诊断】WMB 表项 + CE merge 目标快照 (2026-10-15, coremark_i1 #75039)
  //   症状: 约 T94128 那笔写 0xfc1c 的 `sw` 既没进 dcache([WDC] 无)也没进内存([SLVW] 无),
  //         数据凭空消失; 之后 dcache 里 0xfc1c 一直是上一代的 0x13a3, 直到 #75039 失配。
  // 【2026-10-16 快复现现场】SQ 的提交/数据判据 (三选一: 闸门洞 / 清除判据错 / 未退休)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_SQC") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [SQC] T%0d vld=%b cmit=%b cmit_not_dvld=%b has_cmit=%b flush=%b",
               cycles,
               dut.u_lsu_top.u_lsu_sq.sq_entry_vld,
               dut.u_lsu_top.u_lsu_sq.sq_entry_cmit,
               dut.u_lsu_top.u_lsu_sq.sq_entry_cmit_data_not_vld,
               dut.u_lsu_top.u_lsu_sq.sq_has_cmit,
               dut.rtu_yy_xx_flush);
  end

  integer wmbe_lo = 7370, wmbe_hi = 7520;   // 2026-10-16 改到 -O3 快复现的现场
  always @(posedge clk) begin
    if (!rst && cycles >= wmbe_lo && cycles <= wmbe_hi) begin
      $display("  [CEM] T%0d vld=%b addr=%08x merge=%b mptr=%b stall=%b mnotvld=%b mreq=%b mstall=%b ahit=%b | sqpop=%08x bv=%04x",
        cycles,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_vld,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_addr,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_ptr,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_stall,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_not_vld,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_wmb_req,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_data_stall,
        dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_data_addr_hit,
        dut.u_lsu_top.sq_pop_addr,
        dut.u_lsu_top.sq_pop_bytes_vld);
      $display("     E: vld=%b wp=%b dp=%b dvld=%b | e0 v=%b a=%08x ws=%b wreq=%b dptr=%b ahit=%b | e1 v=%b a=%08x ws=%b wreq=%b dptr=%b ahit=%b",
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld,
        dut.u_lsu_top.u_lsu_wmb.wmb_write_ptr,
        dut.u_lsu_top.u_lsu_wmb.wmb_data_ptr,
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_merge_data_vld,
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[0],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[0],
        dut.u_lsu_top.u_lsu_wmb.gen_wmb_entry[0].x_lsu_wmb_entry.wmb_entry_write_req_success,
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_req[0],
        dut.u_lsu_top.u_lsu_wmb.wmb_dcache_req_ptr[0],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_merge_data_addr_hit[0],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[1],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[1],
        dut.u_lsu_top.u_lsu_wmb.gen_wmb_entry[1].x_lsu_wmb_entry.wmb_entry_write_req_success,
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_req[1],
        dut.u_lsu_top.u_lsu_wmb.wmb_dcache_req_ptr[1],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_merge_data_addr_hit[1]);
      $display("     E2: e2 v=%b a=%08x ws=%b wreq=%b dptr=%b ahit=%b | e3 v=%b a=%08x ws=%b wreq=%b dptr=%b ahit=%b",
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[2],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[2],
        dut.u_lsu_top.u_lsu_wmb.gen_wmb_entry[2].x_lsu_wmb_entry.wmb_entry_write_req_success,
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_req[2],
        dut.u_lsu_top.u_lsu_wmb.wmb_dcache_req_ptr[2],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_merge_data_addr_hit[2],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[3],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[3],
        dut.u_lsu_top.u_lsu_wmb.gen_wmb_entry[3].x_lsu_wmb_entry.wmb_entry_write_req_success,
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_req[3],
        dut.u_lsu_top.u_lsu_wmb.wmb_dcache_req_ptr[3],
        dut.u_lsu_top.u_lsu_wmb.wmb_entry_merge_data_addr_hit[3]);
    end
  end

  // ===========================================================================
  // 【临时诊断 2026-10-16】区域探针 —— `+PROBE_RGN`
  //   盯 dcache **set 20** = 地址 [0xfa80, 0xfaa0) 这一整条 32B 线 (2KB/32set ⇒
  //   index = addr[9:5]), 把这行"从进 dcache 到离场"的全链路逐笔打出来:
  //     1) 三个阵列 (st_dirty / ld_tag / st_tag) 在 set 20 的**内容变化** + 写口来源
  //     2) 三阵列/数据阵列**落在 set 20 的每一笔写** (带 lfb/vb/ag/wmb 谁选中)
  //     3) WMB 表项里地址落在该区的建表/merge/写出
  //     4) AXI 上落在该区的 AW/W (= 真正上内存的那几笔)
  //   为什么不按拍窗: 探针打的是"当拍内容", 固定拍窗会把常态读成异常 (踩过)。
  //   这里全部按**地址/set** 触发, 全跑程不设窗。
  //   阵列布局 (2KB, 2-way, 32B 线, INDEX_WIDTH=5):
  //     dirty[4:0] = {replace_way, way1{dirty,vld}, way0{dirty,vld}}  ← store 命中判据看这个
  //     ld_tag[45:0]= {way1{tag[21:0],vld}, way0{tag[21:0],vld}}      ← load  命中判据看这个
  //     st_tag[43:0]= {way1 tag[21:0], way0 tag[21:0]}
  //   0xfa80 ⇒ set 20, tag = addr[31:10] = 0x3e
  // ===========================================================================
  localparam [4:0]  RGN_SET = 5'd20;

  wire [4:0]  rgn_dirty = dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_dirty_array
                            .x_ct_spsram_32x5.mem_q[RGN_SET];
  wire [45:0] rgn_ldtag = dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_tag_array
                            .x_ct_spsram_32x46.mem_q[RGN_SET];
  wire [43:0] rgn_sttag = dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_tag_array
                            .x_ct_spsram_32x44.mem_q[RGN_SET];

  reg [4:0]  rgn_dirty_q = 5'h1f;
  reg [45:0] rgn_ldtag_q = 46'h0;
  reg [43:0] rgn_sttag_q = 44'h0;
  reg        rgn_init = 0;

  // ---- 1) 三个阵列在 set 20 的内容变化 ----
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")) begin
      if (rgn_init) begin
        if (rgn_dirty !== rgn_dirty_q)
          $display("  [R20-DIR] T%0d %b -> %b  (way0{%b,%b} way1{%b,%b} rway=%b)",
                   cycles, rgn_dirty_q, rgn_dirty,
                   rgn_dirty[1], rgn_dirty[0], rgn_dirty[3], rgn_dirty[2], rgn_dirty[4]);
        if (rgn_ldtag !== rgn_ldtag_q)
          $display("  [R20-LDT] T%0d -> %b  (way0{tag=%06x,v=%b} way1{tag=%06x,v=%b})",
                   cycles, rgn_ldtag,
                   rgn_ldtag[21:0], rgn_ldtag[22], rgn_ldtag[44:23], rgn_ldtag[45]);
        if (rgn_sttag !== rgn_sttag_q)
          $display("  [R20-STT] T%0d -> %b  (way0 tag=%06x way1 tag=%06x)",
                   cycles, rgn_sttag, rgn_sttag[21:0], rgn_sttag[43:22]);
      end
      rgn_dirty_q <= rgn_dirty;
      rgn_ldtag_q <= rgn_ldtag;
      rgn_sttag_q <= rgn_sttag;
      rgn_init    <= 1'b1;
    end
  end

  // ---- 1b) 同样盯 set 21 (= 地址 [0xfaa0, 0xfac0) 那条线) ----
  wire [4:0]  rgn21_dirty = dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_st_dirty_array
                              .x_ct_spsram_32x5.mem_q[21];
  wire [45:0] rgn21_ldtag = dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_tag_array
                              .x_ct_spsram_32x46.mem_q[21];
  reg [4:0]  rgn21_dirty_q = 5'h1f;
  reg [45:0] rgn21_ldtag_q = 46'h0;
  reg        rgn21_init = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")) begin
      if (rgn21_init && rgn21_dirty !== rgn21_dirty_q)
        $display("  [R21-DIR] T%0d %b -> %b  (way0{%b,%b} way1{%b,%b} rway=%b)",
                 cycles, rgn21_dirty_q, rgn21_dirty,
                 rgn21_dirty[1], rgn21_dirty[0], rgn21_dirty[3], rgn21_dirty[2], rgn21_dirty[4]);
      if (rgn21_init && rgn21_ldtag !== rgn21_ldtag_q)
        $display("  [R21-LDT] T%0d -> %b  (way0{tag=%06x,v=%b} way1{tag=%06x,v=%b})",
                 cycles, rgn21_ldtag,
                 rgn21_ldtag[21:0], rgn21_ldtag[22], rgn21_ldtag[44:23], rgn21_ldtag[45]);
      rgn21_dirty_q <= rgn21_dirty;
      rgn21_ldtag_q <= rgn21_ldtag;
      rgn21_init    <= 1'b1;
    end
  end

  // ---- 1c) load 通路: 落在 [0xfa80,0xfac0) 的每一笔 load 在 ld_dc 的判定 + ld_da 的数据 ----
  //   ld_dc: 命中与否 / 走 SQ 旁路还是 WMB 旁路 / 选哪一路 (rot_sel)
  //   ld_da: 最终交给流水线的 32 位数据 (ld_da_wb_data)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")
        && dut.u_lsu_top.ld_dc_da_inst_vld
        && dut.u_lsu_top.ld_dc_addr0 >= 32'h0000_fa80
        && dut.u_lsu_top.ld_dc_addr0 <  32'h0000_fac0)
      $display("  [R20-LDC] T%0d iid=%0d addr=%08x dc_hit=%b lo=%b hi=%b | fwd_sq=%b fwd_wmb=%b | rot=%02x tagdout=%b",
               cycles, dut.u_lsu_top.ld_dc_iid, dut.u_lsu_top.ld_dc_addr0,
               dut.u_lsu_top.ld_dc_dcache_hit,
               dut.u_lsu_top.ld_dc_hit_low_region, dut.u_lsu_top.ld_dc_hit_high_region,
               dut.u_lsu_top.ld_dc_fwd_sq_vld, dut.u_lsu_top.ld_dc_fwd_wmb_vld,
               dut.u_lsu_top.ld_dc_da_data_rot_sel, dut.u_lsu_top.dcache_lsu_ld_tag_dout);
    if (!rst && $test$plusargs("PROBE_RGN")
        && dut.u_lsu_top.ld_da_inst_vld
        && dut.u_lsu_top.ld_da_addr0 >= 32'h0000_fa80
        && dut.u_lsu_top.ld_da_addr0 <  32'h0000_fac0)
      $display("  [R20-LDA] T%0d iid=%0d addr=%08x wb_data=%08x wb_req=%b banks=%08x%08x%08x%08x%08x%08x%08x%08x",
               cycles, dut.u_lsu_top.ld_da_iid, dut.u_lsu_top.ld_da_addr0,
               dut.u_lsu_top.ld_da_wb_data, dut.u_lsu_top.ld_da_wb_data_req,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank7_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank6_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank5_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank4_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank3_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank2_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank1_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank0_dout);
  end

  // ---- 1d) 数据阵列里这两条线的**实际内容** (way0; 变了才打) ----
  //   低位 128b = line 的 byte[15:0], 高位 128b = byte[31:16]; 打印顺序 = byte31..byte0。
  //   用来看 "那半个字到底有没有被写进 dcache、写成了什么"。
  // dcache 数据阵列里 set20/set21 的 way0 整线 (idx = {set,way} = 40 / 42)
  reg  [255:0] rgn20_dc;  reg [255:0] rgn21_dc;  reg [255:0] rgn20_dc1;
  reg  [255:0] rgn20_dm;  reg [255:0] rgn21_dm;
  reg  [255:0] rgn20_gm;  reg [255:0] rgn21_gm;
  task automatic rgn_sample;
    rgn20_dc = {
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank7_array.x_ct_spsram_64x32.mem_q[40],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank6_array.x_ct_spsram_64x32.mem_q[40],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank5_array.x_ct_spsram_64x32.mem_q[40],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank4_array.x_ct_spsram_64x32.mem_q[40],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank3_array.x_ct_spsram_64x32.mem_q[40],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank2_array.x_ct_spsram_64x32.mem_q[40],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank1_array.x_ct_spsram_64x32.mem_q[40],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank0_array.x_ct_spsram_64x32.mem_q[40]};
    rgn21_dc = {
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank7_array.x_ct_spsram_64x32.mem_q[42],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank6_array.x_ct_spsram_64x32.mem_q[42],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank5_array.x_ct_spsram_64x32.mem_q[42],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank4_array.x_ct_spsram_64x32.mem_q[42],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank3_array.x_ct_spsram_64x32.mem_q[42],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank2_array.x_ct_spsram_64x32.mem_q[42],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank1_array.x_ct_spsram_64x32.mem_q[42],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank0_array.x_ct_spsram_64x32.mem_q[42]};
  // DUT 从机内存 / 黄金模型内存里的同两条线 (byte31..byte0)
  // way1 也读出来 (索引 41 / 43) —— 用来判 "是不是读错了路"
    rgn20_dc1 = {
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank7_array.x_ct_spsram_64x32.mem_q[41],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank6_array.x_ct_spsram_64x32.mem_q[41],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank5_array.x_ct_spsram_64x32.mem_q[41],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank4_array.x_ct_spsram_64x32.mem_q[41],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank3_array.x_ct_spsram_64x32.mem_q[41],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank2_array.x_ct_spsram_64x32.mem_q[41],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank1_array.x_ct_spsram_64x32.mem_q[41],
      dut.u_lsu_top.u_dcache_top.x_ct_lsu_dcache_ld_data_bank0_array.x_ct_spsram_64x32.mem_q[41]};
    rgn20_dm = {u_mem.mem[12'hfa9], u_mem.mem[12'hfa8]};
    rgn21_dm = {u_mem.mem[12'hfab], u_mem.mem[12'hfaa]};
    rgn20_gm = {gm_read_mem(32'h0000_fa9c), gm_read_mem(32'h0000_fa98),
                           gm_read_mem(32'h0000_fa94), gm_read_mem(32'h0000_fa90),
                           gm_read_mem(32'h0000_fa8c), gm_read_mem(32'h0000_fa88),
                           gm_read_mem(32'h0000_fa84), gm_read_mem(32'h0000_fa80)};
    rgn21_gm = {gm_read_mem(32'h0000_fabc), gm_read_mem(32'h0000_fab8),
                           gm_read_mem(32'h0000_fab4), gm_read_mem(32'h0000_fab0),
                           gm_read_mem(32'h0000_faac), gm_read_mem(32'h0000_faa8),
                           gm_read_mem(32'h0000_faa4), gm_read_mem(32'h0000_faa0)};
  endtask
  reg [255:0] rgn20_dc_q = '0,  rgn21_dc_q = '0;
  reg [255:0] rgn20_dc1_q = '0;
  reg [255:0] rgn20_dm_q = '0,  rgn21_dm_q = '0;
  reg        rgn_line_init = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")) begin
      rgn_sample;
      if (rgn_line_init) begin
        if (rgn20_dc !== rgn20_dc_q)
          $display("  [R20-DC]  T%0d dcache = %064x  (GM=%064x)", cycles, rgn20_dc, rgn20_gm);
        if (rgn21_dc !== rgn21_dc_q)
          $display("  [R21-DC]  T%0d dcache = %064x  (GM=%064x)", cycles, rgn21_dc, rgn21_gm);
        if (rgn20_dc1 !== rgn20_dc1_q)
          $display("  [R20-DC1] T%0d dcache set20 WAY1 = %064x", cycles, rgn20_dc1);
        if (rgn20_dm !== rgn20_dm_q)
          $display("  [R20-DRAM] T%0d DUTmem = %064x  (GM=%064x)  %s", cycles, rgn20_dm, rgn20_gm,
                   (rgn20_dm === rgn20_gm) ? "" : "<<< DUT/GM 内存分家");
        if (rgn21_dm !== rgn21_dm_q)
          $display("  [R21-DRAM] T%0d DUTmem = %064x  (GM=%064x)  %s", cycles, rgn21_dm, rgn21_gm,
                   (rgn21_dm === rgn21_gm) ? "" : "<<< DUT/GM 内存分家");
      end
      rgn20_dc_q <= rgn20_dc;  rgn21_dc_q <= rgn21_dc;  rgn20_dc1_q <= rgn20_dc1;
      rgn20_dm_q <= rgn20_dm;  rgn21_dm_q <= rgn21_dm;
      rgn_line_init <= 1'b1;
    end
  end

  // ---- 2) 落在 set 20 的每一笔阵列写 (带来源) ----
  wire [3:0] rgn_src_st = {dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_st_sel,
                           dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_st_sel,
                           dut.u_lsu_top.u_dcache_arb.dcache_arb_ag_st_sel,
                           dut.u_lsu_top.u_dcache_arb.dcache_arb_wmb_st_sel};
  wire [3:0] rgn_src_ld = {dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_sel,
                           dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_ld_sel,
                           dut.u_lsu_top.u_dcache_arb.dcache_arb_wmb_ld_sel,
                           dut.u_lsu_top.u_dcache_arb.dcache_arb_ag_ld_sel};
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")) begin
      // dirty 阵列 (set 20 = line 0xfa80, set 21 = line 0xfaa0)
      if (!dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_gwen_b
          && !dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_sel_b
          && (dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_idx == 5'd20
              || dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_idx == 5'd21))
        $display("  [R20-WD] T%0d set=%0d dirty-wr din=%b wen_b=%b src[L,V,A,W]=%b  vb_gwen=%b",
                 cycles, dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_idx,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_din,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_wen_b, rgn_src_st,
                 dut.u_lsu_top.u_dcache_arb.vb_dirty_gwen);
      // ld tag 阵列
      if (!dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_tag_gwen_b
          && !dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_tag_sel_b
          && (dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_tag_idx == 5'd20
              || dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_tag_idx == 5'd21))
        $display("  [R20-WLT] T%0d set=%0d ldtag-wr din=%b wen_b=%b src[L,V,W,A]=%b",
                 cycles, dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_tag_idx,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_tag_din,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_tag_wen_b, rgn_src_ld);
      // st tag 阵列
      if (!dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_gwen_b
          && !dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_sel_b
          && (dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_idx == 5'd20
              || dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_idx == 5'd21))
        $display("  [R20-WST] T%0d set=%0d sttag-wr din=%b wen_b=%b src[L,V,A]=%b",
                 cycles, dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_idx,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_din,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_tag_wen_b, rgn_src_st[3:1]);
      // 数据阵列 (low/high 的 idx = {set[4:0], way})
      if ((dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_low_idx[5:1]  == 5'd20
           || dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_low_idx[5:1]  == 5'd21
           || dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_high_idx[5:1] == 5'd20
           || dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_high_idx[5:1] == 5'd21)
          && !dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_gwen_b[0]
          && !dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_sel_b[0])
        $display("  [R20-DAT] T%0d low<-%032x high<-%032x lowidx=%0d highidx=%0d wen_b=%08x sel_b=%02x src[L,V,W,A]=%b",
                 cycles,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_low_din,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_high_din,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_low_idx,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_high_idx,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_wen_b,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_sel_b, rgn_src_ld);
      // WMB 表项: 地址落在该区、且正在要求写出 —— dc_req/biu_req 谁抬 = 它打算写哪儿
      //   (write_dcache_req 抬 ⇒ 表项记着"行在 dcache"; write_biu_req 抬 ⇒ 直写内存)
      //   ⚠️ 逐项手写: generate 实例 (gen_wmb_entry[j].x_lsu_wmb_entry.*) 不能用变量索引。
      if (dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[0]
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[0] >= 32'h0000_fa80
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[0] <  32'h0000_fac0
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_req[0])
        $display("  [R20-WMB] T%0d e0 addr=%08x data=%032x bv=%04x way=%b dc_req=%b biu_req=%b dcp=%b",
                 cycles, dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[0],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_data[0],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_bytes_vld[0],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_dcache_way[0],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_dcache_req[0],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_biu_req[0],
                 dut.u_lsu_top.u_lsu_wmb.wmb_dcache_req_ptr[0]);
      if (dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[1]
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[1] >= 32'h0000_fa80
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[1] <  32'h0000_fac0
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_req[1])
        $display("  [R20-WMB] T%0d e1 addr=%08x data=%032x bv=%04x way=%b dc_req=%b biu_req=%b dcp=%b",
                 cycles, dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[1],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_data[1],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_bytes_vld[1],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_dcache_way[1],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_dcache_req[1],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_biu_req[1],
                 dut.u_lsu_top.u_lsu_wmb.wmb_dcache_req_ptr[1]);
      if (dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[2]
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[2] >= 32'h0000_fa80
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[2] <  32'h0000_fac0
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_req[2])
        $display("  [R20-WMB] T%0d e2 addr=%08x data=%032x bv=%04x way=%b dc_req=%b biu_req=%b dcp=%b",
                 cycles, dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[2],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_data[2],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_bytes_vld[2],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_dcache_way[2],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_dcache_req[2],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_biu_req[2],
                 dut.u_lsu_top.u_lsu_wmb.wmb_dcache_req_ptr[2]);
      if (dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[3]
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[3] >= 32'h0000_fa80
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[3] <  32'h0000_fac0
          && dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_req[3])
        $display("  [R20-WMB] T%0d e3 addr=%08x data=%032x bv=%04x way=%b dc_req=%b biu_req=%b dcp=%b",
                 cycles, dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[3],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_data[3],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_bytes_vld[3],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_dcache_way[3],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_dcache_req[3],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_write_biu_req[3],
                 dut.u_lsu_top.u_lsu_wmb.wmb_dcache_req_ptr[3]);
    end
  end

  // ---- 2b) store 流水过 st_da 时对这条线的判定 (命中/未命中、选中哪一路) ----
  //   store 的命中判据看的是 **dirty 阵列** 的 valid 位 (valid0=dirty[0], valid1=dirty[2]);
  //   load 看的是 ld_tag 阵列。两者不一致就会 "store 判 miss 直写内存 / load 命中读旧值"。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")
        && dut.u_lsu_top.u_lsu_st_da.st_da_inst_vld
        && dut.u_lsu_top.u_lsu_st_da.st_da_addr0 >= 32'h0000_fa80
        && dut.u_lsu_top.u_lsu_st_da.st_da_addr0 <  32'h0000_fac0)
      $display("  [R20-ST]  T%0d iid=%0d addr=%08x hit=%b v0=%b v1=%b t0=%b t1=%b way=%b darr=%b rway=%b rvld=%b rdtry=%b | rec_vld=%b rec_dtry=%b rec_way=%b lfbhit=%b",
               cycles, dut.u_lsu_top.st_da_iid,
               dut.u_lsu_top.u_lsu_st_da.st_da_addr0,
               dut.u_lsu_top.u_lsu_st_da.st_da_dcache_hit,
               dut.u_lsu_top.u_lsu_st_da.st_da_dcache_valid0,
               dut.u_lsu_top.u_lsu_st_da.st_da_dcache_valid1,
               dut.u_lsu_top.u_lsu_st_da.st_da_tag0_hit,
               dut.u_lsu_top.u_lsu_st_da.st_da_tag1_hit,
               dut.u_lsu_top.u_lsu_st_da.st_da_dcache_way,
               dut.u_lsu_top.u_lsu_st_da.st_da_dcache_dirty_array,
               dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_way,
               dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_valid,
               dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_dirty,
               dut.u_lsu_top.u_lsu_st_da.st_da_sq_dcache_valid,
               dut.u_lsu_top.u_lsu_st_da.st_da_sq_dcache_dirty,
               dut.u_lsu_top.u_lsu_st_da.st_da_sq_dcache_way,
               dut.u_lsu_top.lfb_st_da_hit_idx);
  end

  // ---- 1e) 该区里每一笔 load 最终交付的数据 (ld_da 的写回口) ----
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")
        && dut.u_lsu_top.ld_da_wb_data_req
        && dut.u_lsu_top.ld_da_addr0 >= 32'h0000_fa80
        && dut.u_lsu_top.ld_da_addr0 <  32'h0000_fac0)
      $display("  [R20-LDB] T%0d iid=%0d addr=%08x wb_data=%08x (半字=%04x) cb_merge=%b fwd_sq=%b fwd_wmb=%b hit=%b",
               cycles, dut.u_lsu_top.ld_da_iid, dut.u_lsu_top.ld_da_addr0,
               dut.u_lsu_top.ld_da_wb_data, dut.u_lsu_top.ld_da_wb_data[15:0],
               dut.u_lsu_top.u_lsu_ld_da.ld_da_merge_from_cb,
               dut.u_lsu_top.ld_dc_fwd_sq_vld, dut.u_lsu_top.ld_dc_fwd_wmb_vld,
               dut.u_lsu_top.ld_dc_dcache_hit);
  end

  // ---- 1g) ld_da 这一拍的阵列回读口 (哪个 way 的 idx + 八个 bank 的原值) ----
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN") && dut.u_lsu_top.ld_da_wb_data_req
        && dut.u_lsu_top.ld_da_addr0 >= 32'h0000_fa80
        && dut.u_lsu_top.ld_da_addr0 <  32'h0000_fac0)
      $display("  [R20-RAW] T%0d lowidx=%0d highidx=%0d banks=%08x%08x%08x%08x%08x%08x%08x%08x",
               cycles,
               dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_low_idx,
               dut.u_lsu_top.u_dcache_arb.lsu_dcache_ld_data_high_idx,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank7_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank6_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank5_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank4_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank3_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank2_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank1_dout,
               dut.u_lsu_top.u_dcache_top.dcache_lsu_ld_data_bank0_dout);
  end

  // ---- 1f) 缓存缓冲 (ct_lsu_cache_buffer): ld_da 可能拿它里面的**上一次**数据 ----
  reg cb_vld_q = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")) begin
      if (dut.u_lsu_top.u_ct_lsu_cache_buffer.cb_vld !== cb_vld_q)
        $display("  [R20-CB]  T%0d cb_vld %b -> %b | addr_tto4=%07x data=%032x",
                 cycles, cb_vld_q, dut.u_lsu_top.u_ct_lsu_cache_buffer.cb_vld,
                 dut.u_lsu_top.u_ct_lsu_cache_buffer.cb_addr_tto4,
                 dut.u_lsu_top.u_ct_lsu_cache_buffer.cb_data);
      cb_vld_q <= dut.u_lsu_top.u_ct_lsu_cache_buffer.cb_vld;
    end
  end

  // ---- 2c) SQ 表项的 dcache 记录位 + info_vld (整区, 变化即打) ----
  //   info_vld=0 时 `sq_entry_dcache_update_vld` 被闸掉 ⇒ 建表那一拍正好来一次回填的话,
  //   这一拍的信息更新会被吞掉, 表项永远停在 "miss"。这里就是要看这个窗口。
  reg [7:0] sq_watch_q [0:5];
  reg       sq_watch_init = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")) begin
      for (int i = 0; i < 6; i++) begin
        if (dut.u_lsu_top.u_lsu_sq.sq_entry_addr0[i] >= 32'h0000_fa80
            && dut.u_lsu_top.u_lsu_sq.sq_entry_addr0[i] <  32'h0000_fac0) begin
          if (sq_watch_init
              && {dut.u_lsu_top.u_lsu_sq.sq_entry_vld[i],
                  dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_info_vld[i],
                  dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_valid[i],
                  dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_dirty[i],
                  dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_way[i], 3'b0} !== sq_watch_q[i])
            $display("  [R20-SQE] T%0d e%0d iid=%0d addr=%08x vld=%b info_vld=%b dc_vld=%b dc_dirty=%b dc_way=%b",
                     cycles, i, dut.u_lsu_top.u_lsu_sq.sq_entry_iid[i],
                     dut.u_lsu_top.u_lsu_sq.sq_entry_addr0[i],
                     dut.u_lsu_top.u_lsu_sq.sq_entry_vld[i],
                     dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_info_vld[i],
                     dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_valid[i],
                     dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_dirty[i],
                     dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_way[i]);
          sq_watch_q[i] = {dut.u_lsu_top.u_lsu_sq.sq_entry_vld[i],
                           dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_info_vld[i],
                           dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_valid[i],
                           dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_dirty[i],
                           dut.u_lsu_top.u_lsu_sq.sq_entry_dcache_way[i], 3'b0};
        end
      end
      sq_watch_init <= 1'b1;
    end
  end

  // ---- 3) AXI 上落在该区的 AW / W (全跑程) ----
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_RGN")) begin
      if (biu_pad_awvalid && pad_biu_awready
          && biu_pad_awaddr >= 32'h0000_fa80 && biu_pad_awaddr < 32'h0000_fac0)
        $display("  [R20-AW]  T%0d addr=%08x len=%0d size=%0d", cycles,
                 biu_pad_awaddr, biu_pad_awlen, biu_pad_awsize);
      if (biu_pad_wvalid && pad_biu_wready
          && u_mem.wr_addr >= 32'h0000_fa80 && u_mem.wr_addr < 32'h0000_fac0)
        $display("  [R20-W]   T%0d wr_addr=%08x strb=%04x data=%032x", cycles,
                 u_mem.wr_addr, biu_pad_wstrb, biu_pad_wdata);
    end
  end

  // 【临时诊断】DRAM 逐字看门狗 (2026-10-15, coremark_i1 #75039)
  //   盯字节区间 DWLO..DWHI (4 字节步进), DUT 从机内存 =/= 黄金模型内存 的**每一拍**
  //   都打一行。用来定位 "DUT 的 DRAM 到底从哪一拍、哪个地址开始跟模型分家"。
  //   （#75039 的表现: pc=0xfa0 的 `lw a3,0(a4)` 读回 0x13a3, 模型读回 0x7359;
  //     而失配现场 DUT 内存 0xfa8c..0xfa9f 恰好比模型**每个半字都少 0x99**。）
  integer dw_lo = 32'h0, dw_hi = 32'h0, dw_a;
  reg [31:0] dwd_prev [0:511];
  reg [31:0] dwg_prev [0:511];
  reg        dw_init = 0;
  always @(posedge clk) begin
    if (!rst && dw_hi > dw_lo) begin
      for (dw_a = dw_lo; dw_a < dw_hi; dw_a = dw_a + 4) begin
        if (!dw_init
            || u_mem.mem[dw_a>>4][((dw_a&15)>>2)*32 +: 32] !== dwd_prev[(dw_a-dw_lo)>>2]
            || gm_read_mem(dw_a) !== dwg_prev[(dw_a-dw_lo)>>2]) begin
          if (dw_init)
            $display("  [DRAMD] T%0d [%05x] DUT=%08x GM=%08x %s",
                     cycles, dw_a,
                     u_mem.mem[dw_a>>4][((dw_a&15)>>2)*32 +: 32],
                     gm_read_mem(dw_a),
                     (u_mem.mem[dw_a>>4][((dw_a&15)>>2)*32 +: 32] === gm_read_mem(dw_a))
                       ? "" : "<<< DIFF");
          dwd_prev[(dw_a-dw_lo)>>2] = u_mem.mem[dw_a>>4][((dw_a&15)>>2)*32 +: 32];
          dwg_prev[(dw_a-dw_lo)>>2] = gm_read_mem(dw_a);
        end
      end
      dw_init = 1;
    end
  end

  reg [127:0] memw_prev [0:3];
  reg         memw_init = 0;
  integer     memw_i;
  always @(posedge clk) begin
    // ⚠️ 2026-10-16: 这块每拍扫 4 个 128b 块 + 16 次 gm_read_mem DPI ⇒ 整场跑分的
    //   主要开销 (实测把 11M 拍的用例拖到小时级)。默认关, 回看时加 +PROBE_MEMW。
    if (!rst && $test$plusargs("PROBE_MEMW")) begin
      for (memw_i = 0; memw_i < 4; memw_i = memw_i + 1) begin
        if (!memw_init || u_mem.mem[12'hf7f + memw_i] !== memw_prev[memw_i]) begin
          if (memw_init)
            $display("  [MEMW] T%0d mem[%05x]=%032x  GM=%08x %08x %08x %08x",
                     cycles, 16 * (12'hf7f + memw_i), u_mem.mem[12'hf7f + memw_i],
                     gm_read_mem(16 * (12'hf7f + memw_i)),
                     gm_read_mem(16 * (12'hf7f + memw_i) + 4),
                     gm_read_mem(16 * (12'hf7f + memw_i) + 8),
                     gm_read_mem(16 * (12'hf7f + memw_i) + 12));
          memw_prev[memw_i] = u_mem.mem[12'hf7f + memw_i];
        end
      end
      memw_init = 1;
    end
  end

  // 【临时诊断】黄金模型 0xf840..0xf85f 的变化时刻 —— 与 DUT DRAM 的 [MEMW] 对照,
  //   用来找 "DUT 的 DRAM 到底哪一拍开始跟黄金模型不一致"。
  reg [31:0] gmw_prev [0:7];
  reg        gmw_init = 0;
  integer    gmw_i;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_GMMW")) begin   // 同上: 每拍 8 次 DPI, 默认关
      for (gmw_i = 0; gmw_i < 8; gmw_i = gmw_i + 1) begin
        if (gmw_init && gm_read_mem(32'h0000_f840 + 4 * gmw_i) !== gmw_prev[gmw_i])
          $display("  [GMMW] T%0d GM[%05x]=%08x", cycles, 32'h0000_f840 + 4 * gmw_i,
                   gm_read_mem(32'h0000_f840 + 4 * gmw_i));
        gmw_prev[gmw_i] = gm_read_mem(32'h0000_f840 + 4 * gmw_i);
      end
      gmw_init = 1;
    end
  end

  // 【临时诊断】dcache dirty 数组写口 (只看 set 2 = 0xf840 那一行) + VB (victim/writeback) 活动。
  //   set 2 的行 = 0xf840..0xf85f —— 正是失配的那一行。
  integer vbd_lo, vbd_hi;
  initial begin
    void'($value$plusargs("VBD_LO=%d", vbd_lo));
    void'($value$plusargs("VBD_HI=%d", vbd_hi));
  end
  reg vb_vld_prev = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LEGACY")) begin   // DTW/VBP/VBW: 旧现场诊断, 默认关
      if (!dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_gwen_b
          && !dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_sel_b
          && dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_idx == 5'd2)
        $display("  [DTW] T%0d set2 dirty-wr din=%b wen_b=%b",
                 cycles,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_din,
                 dut.u_lsu_top.u_dcache_arb.lsu_dcache_st_dirty_wen_b);
      if (dut.u_lsu_top.u_lsu_vb.vb_vld && !vb_vld_prev)
        $display("  [VBP] T%0d VB create: vld=1 aw_req=%b w_req=%b borrow_ld=%b borrow_st=%b",
                 cycles, dut.u_lsu_top.u_lsu_vb.vb_biu_aw_req,
                 dut.u_lsu_top.u_lsu_vb.vb_biu_w_req,
                 dut.u_lsu_top.u_lsu_vb.vb_dcache_arb_ld_borrow_req,
                 dut.u_lsu_top.u_lsu_vb.vb_dcache_arb_st_borrow_req);
      if (dut.u_lsu_top.u_lsu_vb.vb_biu_aw_req && !dut.u_lsu_top.u_lsu_vb.vb_biu_w_req)
        $display("  [VBW] T%0d VB writeback AW: addr=%08x", cycles,
                 dut.u_lsu_top.u_lsu_vb.vb_biu_aw_addr);
      vb_vld_prev <= dut.u_lsu_top.u_lsu_vb.vb_vld;
      if ($test$plusargs("PROBE_VBD")
          && dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_state == 3'd3)
        $display("  [VBD] T%0d CMP_TAG set=%0d | hit=%b rway=%b rvld=%b rdtry=%b darr=%b | vbway=%b lfbrway=%b | ldgrnt=%b stgrnt=%b aw_req=%b",
                 cycles,
                 dut.u_lsu_top.u_lsu_vb.vb_addr_tto5[4:0],
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_hit,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_way,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_valid,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_replace_dirty,
                 dut.u_lsu_top.u_lsu_st_da.st_da_dcache_dirty_array,
                 dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_dcache_way,
                 dut.u_lsu_top.u_lsu_vb.vb_lfb_dcache_way,
                 dut.u_lsu_top.u_lsu_vb.dcache_arb_vb_ld_grnt,
                 dut.u_lsu_top.u_lsu_vb.dcache_arb_vb_st_grnt,
                 dut.u_lsu_top.u_lsu_vb.vb_biu_aw_req);
      if ($test$plusargs("PROBE_VBD") && vbd_hi > 0
          && cycles >= vbd_lo && cycles <= vbd_hi)
        $display("  [VBS] T%0d st=%0d vld=%b dnreg=%b stgrnt=%b ldgrnt=%b dst=%0d aw=%b vtto5=%05x",
                 cycles, dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_state,
                 dut.u_lsu_top.u_lsu_vb.vb_vld, dut.u_lsu_top.u_lsu_vb.vb_rcl_done_reg,
                 dut.u_lsu_top.u_lsu_vb.dcache_arb_vb_st_grnt,
                 dut.u_lsu_top.u_lsu_vb.dcache_arb_vb_ld_grnt,
                 dut.u_lsu_top.u_lsu_vb.vb_data_state,
                 dut.u_lsu_top.u_lsu_vb.vb_biu_aw_req,
                 dut.u_lsu_top.u_lsu_vb.vb_addr_tto5);
    end
  end

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
    // 【临时诊断】DUT 的 AXI 从机内存 vs 黄金模型内存 (栈上 0xf930..0xf96f)
    begin : mem_dump
      integer di;
      $display("  ---- DUT 内存 (u_mem.mem) 0xf7f0..0xf83f ----");
      for (di = 0; di < 5; di = di + 1)
        $display("    DUT_MEM[0x%08x] = %032x", 16 * (12'hf7f + di), u_mem.mem[12'hf7f + di]);
      $display("  ---- 黄金模型内存 0xf7f0..0xf83f ----");
      gm_dump_mem(32'h0000_f7f0, 80);
    end
    // 【临时诊断】逐字对齐 DUT vs GM 0xfa80..0xfa9f (第 49312 条那个 0xfa8c 循环的数组)
    begin : mem_dump_fa8
      integer aj;
      $display("  ---- DUT vs GM 0xfa80..0xfa9f (逐字) ----");
      for (aj = 0; aj < 8; aj = aj + 1) begin
        $display("    [0x%08x] DUT=%08x GM=%08x %s",
                 32'h0000_fa80 + 4 * aj,
                 u_mem.mem[12'hfa8 + (aj >> 2)][((aj & 3) * 32) +: 32],
                 gm_read_mem(32'h0000_fa80 + 4 * aj),
                 (u_mem.mem[12'hfa8 + (aj >> 2)][((aj & 3) * 32) +: 32]
                  !== gm_read_mem(32'h0000_fa80 + 4 * aj)) ? "  <<< DIFF" : "");
      end
    end
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
  // 【临时诊断】给 PROBE_WB 加个窗口, 否则 400 行预算在前 400 拍就烧光了 —— WB_LO/WB_HI
  integer wb_lo = 0, wb_hi = 1000000000;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_WB") && wb_probe_lines < 400000
        && cycles >= wb_lo && cycles <= wb_hi
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

  // 【临时诊断】LSIQ 表项/发射使能 + LSU 侧 load 管道 —— `+PROBE_LQ` (窗由 STL_LO/STL_HI 给)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LQ") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [LQ] T%0d cnt=%0d vld=%b e0=%b | p3iss=%b e3=%b p4iss=%b e4=%b | lq_full=%b rb_full=%b sq_full=%b",
               cycles, dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_cnt,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_vld,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_issue_en,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_rf_pipe3_issue_en,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_dp_pipe3_issue_entry,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_rf_pipe4_issue_en,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_dp_pipe4_issue_entry,
               dut.lsu_idu_lq_full, dut.lsu_idu_rb_full, dut.lsu_idu_sq_full);
      $display("       IDU→LSU: ld_sel=%b ld_iid=%0d st_sel=%b st_iid=%0d sdiq_sel=%b | pop=%b pop0=%b pop1=%b pop_entry=%b | ld_lch=%b st_lch=%b",
               dut.idu_lsu_ld_sel, dut.idu_lsu_ld_iid,
               dut.idu_lsu_st_sel, dut.idu_lsu_st_iid, dut.idu_lsu_sdiq_sel,
               dut.lsu_idu_lsiq_pop_vld, dut.lsu_idu_lsiq_pop0_vld, dut.lsu_idu_lsiq_pop1_vld,
               dut.lsu_idu_lsiq_pop_entry,
               dut.idu_lsu_ld_lch_entry, dut.idu_lsu_st_lch_entry);
      $display("       LSU ld: ag_vld=%b ag_iid=%0d ag_lsid=%b | da_vld=%b da_iid=%0d | lfb_wkq=%b lfb_hit_idx=%b create=%b vld=%b",
               dut.u_lsu_top.u_lsu_ld_ag.ld_ag_inst_vld, dut.u_lsu_top.ld_ag_iid, dut.u_lsu_top.ld_ag_lsid,
               dut.u_lsu_top.ld_da_inst_vld, dut.u_lsu_top.ld_da_iid,
               dut.u_lsu_top.u_lsu_lfb.lfb_wakeup_queue, dut.u_lsu_top.u_lsu_lfb.lfb_ld_da_hit_idx,
               dut.u_lsu_top.u_lsu_lfb.lfb_data_create_vld, dut.u_lsu_top.u_lsu_lfb.lfb_data_entry_vld);
    end
  end

  // 【临时诊断】LSIQ entry0 内部状态 (vld/frz/src0_rdy/raw_rdy) —— `+PROBE_FRZ`
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_FRZ") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [FRZ] T%0d e7: vld=%b frz=%b src0_rdy=%b raw_rdy=%b rdy=%b iss_en=%b create_en=%b iid=%0d | src0=%07b agevec=%07b | pop_vld=%b pop_entry=%b imme_wk=%b | ld_sel=%b ld_iid=%0d | LSU ag_vld=%b ag_iid=%0d ag_lsid=%b da_vld=%b da_iid=%0d",
               cycles,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.vld,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.frz,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.read_src0_data[0],
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.x_raw_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.x_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_issue_en[7],
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry7_create_en,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.iid,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.read_src0_data[6:0],
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry7.agevec[6:0],
               dut.lsu_idu_lsiq_pop_vld, dut.lsu_idu_lsiq_pop_entry,
               dut.lsu_idu_imme_wakeup[0],
               dut.idu_lsu_ld_sel, dut.idu_lsu_ld_iid,
               dut.u_lsu_top.u_lsu_ld_ag.ld_ag_inst_vld, dut.u_lsu_top.ld_ag_iid,
               dut.u_lsu_top.ld_ag_lsid,
               dut.u_lsu_top.ld_da_inst_vld, dut.u_lsu_top.ld_da_iid);
  end

  // 【临时诊断】LSIQ 全部 8 个表项逐拍 dump —— `+PROBE_LSIQ8`
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_LSIQ8") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [L8] T%0d cnt=%0d vld=%b iss_en=%b create0=%b pop_vld=%b pop_entry=%b wakeup=%b lsiq_ld_sel=%b ld_iid=%0d",
               cycles,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_cnt,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_vld,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_issue_en,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.ctrl_lsiq_create0_en,
               dut.lsu_idu_lsiq_pop_vld, dut.lsu_idu_lsiq_pop_entry,
               dut.lsu_idu_imme_wakeup,
               dut.idu_lsu_ld_sel, dut.idu_lsu_ld_iid);
      $display("       e0 v=%b f=%b iid=%0d rdy=%b raw=%b av=%07b | e1 v=%b f=%b iid=%0d rdy=%b raw=%b av=%07b",
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.vld,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.frz,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.iid,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.x_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.x_raw_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.agevec,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.vld,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.frz,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.iid,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.x_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.x_raw_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.agevec);
      $display("       e2 v=%b f=%b iid=%0d rdy=%b raw=%b av=%07b | e3 v=%b f=%b iid=%0d rdy=%b raw=%b av=%07b",
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.vld,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.frz,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.iid,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.x_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.x_raw_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.agevec,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.vld,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.frz,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.iid,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.x_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.x_raw_rdy,
               dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.agevec);
      $display("       WK: ld_dc=%b st_ag_re=%b ld_ag_re=%b sq_data=%b sq_glob=%b lfb=%b | fren=%b",
               dut.u_lsu_top.ld_dc_imme_wakeup,
               dut.u_lsu_top.st_ag_stall_restart_entry,
               dut.u_lsu_top.ld_ag_stall_restart_entry,
               dut.u_lsu_top.sq_data_depd_wakeup,
               dut.u_lsu_top.sq_global_depd_wakeup,
               dut.u_lsu_top.lfb_depd_wakeup,
               dut.u_lsu_top.u_lsu_ld_ag.ld_ag_stall_restart_entry);
      $display("       LSU: ld_ag v=%b iid=%0d lsid=%b | ld_da v=%b iid=%0d lsid=%b | lq_vld=%b rb_vld=%b | ld_lch=%b st_lch=%b | st_ag v=%b iid=%0d",
               dut.u_lsu_top.u_lsu_ld_ag.ld_ag_inst_vld, dut.u_lsu_top.ld_ag_iid, dut.u_lsu_top.ld_ag_lsid,
               dut.u_lsu_top.ld_da_inst_vld, dut.u_lsu_top.ld_da_iid, dut.u_lsu_top.ld_da_lsid,
               dut.u_lsu_top.u_lsu_lq.lq_entry_vld, dut.u_lsu_top.u_lsu_lfb.lfb_addr_entry_vld,
               dut.idu_lsu_ld_lch_entry, dut.idu_lsu_st_lch_entry,
               dut.u_lsu_top.st_ag_inst_vld, dut.u_lsu_top.st_ag_iid);
    end
  end

  // 【临时诊断】LSIQ 8 个表项 `frz` 的每次跳变 + 当时的 wakeup 向量 —— `+PROBE_FZ`
  // 盯 entry2: 每次 "被冻住" 的上升沿后连打 12 拍, 看有没有 wakeup 来解
  wire e2_vf = dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.vld
             & dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.frz;
  reg  e2_vf_q;
  integer e2_dump, fz_lines;
  integer e2_stuck, e2_reported;
  always @(posedge clk) begin
    if (rst) begin
      e2_vf_q <= 1'b0; e2_dump = 0; fz_lines = 0;
      e2_stuck = 0; e2_reported = 0;
    end else begin
      e2_vf_q <= e2_vf;
      if (e2_vf) e2_stuck = e2_stuck + 1; else begin e2_stuck = 0; e2_reported = 0; end
      // 只在 "连续冻住 >200 拍" 时报一次 (真正卡死的表项), 否则每笔发射都报太吵
      if ($test$plusargs("PROBE_FZ") && e2_stuck > 40 && e2_reported == 0) begin
        e2_reported = 1;
        fz_lines = fz_lines + 1;
        $display("  [FZ] T%0d e2 连续冻住 %0d 拍 vld=%b iid=%0d rawrdy=%b ldAgRdy=%b | ld_sel=%b lch=%b agstallvld=%b aginstvld=%b ldAGre=%b | st_sel=%b slch=%b stAGre=%b | ldDCwk=%b immeWK=%b issEN=%b | src0=%07b av2=%07b lq=%b rb=%b sq=%b",
                 cycles, e2_stuck,
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.vld,
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.iid,
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.x_raw_rdy,
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.read_src0_data[0],
                 dut.idu_lsu_ld_sel, dut.idu_lsu_ld_lch_entry,
                 dut.u_lsu_top.u_lsu_ld_ag.ld_ag_stall_vld,
                 dut.u_lsu_top.u_lsu_ld_ag.ld_ag_inst_vld,
                 dut.u_lsu_top.ld_ag_stall_restart_entry,
                 dut.idu_lsu_st_sel, dut.idu_lsu_st_lch_entry,
                 dut.u_lsu_top.st_ag_stall_restart_entry,
                 dut.u_lsu_top.ld_dc_imme_wakeup,
                 dut.lsu_idu_imme_wakeup,
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_issue_en,
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.read_src0_data[6:0],
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.agevec[6:0],
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.lq_full,
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.rb_full,
                 dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.sq_full);
      end
    end
  end

  // -------------------------------------------------------------------------
  // 【诊断 2026-10-15】CoreMark 30 迭代死锁取证 —— 两个探针
  //
  // 背景: `coremark`(30 迭代) 在 **T10,979,529 / 退休 9,429,555 条** 处**确定性死锁**:
  //   两棵不同的树 (38c56e3 / 98f5502)、15M 与 25M 两种预算下签名**逐位相同**
  //   (ROB 占 11, ICache PC=0x1cd4, 最后探针同为 T10979529), 多给的 10M 拍里
  //   退休数**一个都没涨** ⇒ 硬死锁, 不是"跑得慢"。
  //   而 `coremark_i1`(1 迭代, 31 万条) 的**同一段报告代码**跑得好好的 ⇒ **是累积效应**。
  //
  //   这两个探针专答两个问题:
  //     [POOL] 什么在随运行时间**单调缩水**? → preg 池余量 / ROB 占用 的稀疏趋势
  //            (记忆里记着"自由池单调缩水, 长用例迟早耗尽", 这是冲着它去的)
  //     [HEAD] 死锁那一刻, ROB **队头是哪条**、它在等什么?
  //
  //   用法: +PROBE_POOL +PROBE_HEAD +PROBE_FLG +PROBE_LSQ \
  //         +STL_LO=10975000 +STL_HI=10985000
  //
  // ⚠️ [POOL] 是稀疏的(每 10 万拍一行, 全跑程 ~250 行), 本来就该整程开着 ——
  //    趋势比卡点那一刻的瞬态更能说明问题。
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // [PERF] 周期去哪了 —— `+PROBE_PERF`
  //
  // 【为什么加】A910 跑 CoreMark 只有 IPC 0.859 (`9,440,680 条 / 10,992,343 拍`),
  //   对比 5 级顺序核 0.825 —— **只快 3.9%**。而 ROB 占用采样显示均值只有 **9.6/64**
  //   (从没超过 22) ⇒ 乱序窗口实际只有 ~10 条, 后端一直饿着。
  //   所以问题不是"乱序没用", 是**前端供不上**。这组计数器就是拆"供不上"的账。
  //
  // 口径:
  //   mispred  —— `mispred_hit` 脉冲数 (退休拍真的误预测了一次)
  //   flush    —— `flush_trig` 脉冲数 (四类源合计)
  //   rob_sum/max/zero —— ROB 占用逐拍累加 (采样法会混叠, 这里是真值)
  //   fe_idle  —— IDU 三条交付车道**全空**的拍数 (前端没货)
  //   fe_idle_nf —— 其中"不在冲刷冻结窗里"的拍数 ⇒ **真正的供给饥饿**
  // -------------------------------------------------------------------------
  integer perf_mispred = 0, perf_flush = 0, perf_rob_sum = 0, perf_rob_max = 0;
  integer perf_rob_zero = 0, perf_fe_idle = 0, perf_fe_idle_nf = 0, perf_cyc = 0;
  // 派遣/退休的宽度直方图 —— 3 发射到底发几条? `disp_vld` 是**前缀有效**
  // (`RTU.v:525` `disp_acc[1] = disp_acc[0] & disp1_vld`), 所以按位求和 = 条数。
  integer perf_disp_sum = 0, perf_disp1 = 0, perf_disp2 = 0, perf_disp3 = 0;
  integer perf_ret1 = 0, perf_ret2 = 0, perf_ret3 = 0;
  integer perf_n_disp = 0, perf_n_ret = 0;
  // ---- 派遣被谁挡 ----
  // `ct_idu_is_ctrl.sv:576` `ctrl_is_dis_stall = ctrl_is_rob_full || ctrl_is_iq_full`
  // `:548`  `ctrl_is_iq_full_updt = aiq|biq|lsiq|sdiq|mult|div`
  // ⇒ **任意一个队列满就堵死整个派遣口**。只在"确有指令等着派"时计数。
  integer perf_blk_wait = 0, perf_blk_rob = 0, perf_blk_aiq = 0, perf_blk_biq = 0;
  integer perf_blk_lsiq = 0, perf_blk_sdiq = 0, perf_blk_mult = 0, perf_blk_div = 0;
  // ---- ⚠️ `dut.rtu_idu_rob_full` 不是"ROB 满" ----
  //   `RTU.v:891` `rtu_disp_stall = rob_full | csr_inflight | flushing | mispred_pend`,
  //   而 `rtu_idu_rob_full = rtu_disp_stall`（adapter:284）。四个条件混在一起会把
  //   **冲刷/重定向的恢复窗**记成"ROB 容量不够"。这里拆开单独记。
  //   顺带: `rob_full = (occ_q >= RTU_ROB_FULL_TH)`,`TH = DEPTH - RSV = 60`
  //   （RTU_define.vh:97）—— 于是"真满"和"占用均值"不是一回事, 得分开看。
  integer perf_blk_stall = 0, perf_blk_csr = 0, perf_blk_flushw = 0, perf_blk_mppend = 0;
  // ---- 前端无货的分解: 是不是在等 i-cache 回填 ----
  //   `rv32ifu2_top.v:518` `refill_req = ~q_hit & ~refill_busy & init_all & ~redirect`
  //     ⇒ 每次 miss 恰好拉高**一拍**, 计数即 miss 次数。
  //   `:508` `can_push = q_hit & init_all` ⇒ 行不在缓存里就推不进 IBUF (真挡)。
  //   于是把"非冻结窗的无货"劈成两半:
  //     取指地址 miss  ⇒ 缓存问题
  //     取指地址命中  ⇒ 不是缓存问题 (IBUF/重定向/其它)
  integer perf_ic_miss = 0, perf_ic_busy = 0, perf_ic_idle_miss = 0, perf_ic_idle_hit = 0;
  // 再往下一层: "命中却没货" 的那些拍, 是不是正卡在重定向/重建 IBUF 的窗口里?
  //   `rv32ifu2_top.v:321` `idu_flush = redirect`, `:318`
  //   `redirect = rtu_chgflw_vld | rtu_flush | iu_red_vld`
  //   —— 每次重定向都把 IBUF 清空 (ibuf.v 的 flush 分支), 要重新填才有货。
  //   注意 `mispred_pend` 是多拍锁存 (RTU_flush.v:222), 而 `redirect` 是脉冲,
  //   两者覆盖的窗口不同, 分开记。
  integer perf_idle_red = 0, perf_idle_mpp = 0, perf_idle_oth = 0;
  // ---- 误预测冻结窗拆解: 4.87 拍到底花在哪一段 ----
  //   闸门就是 `A910_cpu.sv:968` 的 `mispred_hold_q` (它和 rtu_yy_xx_flush 一起
  //   进 idu_hold, 决定 IDU 看不看得到 IFU 交来的指令)。窗口分四段:
  //     ① 等冲刷脉冲   iu_chgflw_vld → rtu_yy_xx_flush
  //     ② 冲刷机器跑完 + 开闸   → mispred_hold_q 落
  //     ③ 重新取指     → 第一次 |push_mask (IBUF 被写)
  //     ④ 进 IBUF 到交货 → 第一次 idu_inst0_vld
  //   另外记一件最关键的事: **开闸那一拍 IBUF 里到底有没有货** ——
  //     有 ⇒ 窗口完全由冲刷机器决定 (要减只能减冲刷)
  //     没有 ⇒ 还要再加重新取指的时间
  integer fz_n = 0, fz_s1 = 0, fz_s2 = 0, fz_s3 = 0, fz_s4 = 0, fz_tot = 0;
  integer fz_gate_vs_ife = 0;      // 开闸时 IBUF 还没货的次数
  integer fz_hist [17];
  integer fz_st = 0, fz_cnt = 0, fz_ev = 0;
  integer fz_in_f1 = 0, fz_blocked = 0;   // ① 里: 处于 F1 的拍数 / blocked 拍数
  initial for (int k = 0; k <= 16; k++) fz_hist[k] = 0;
  // ---- AIQ 深挖: "满" 是深度不够还是排空到顶? ----
  //   满(cnt>=N-1, N = AIQ_ENTRY)的那些拍里:
  //     有就绪项 ⇒ 后面的项本该能发, 是**深度**卡住 ⇒ 加宽有用
  //     无就绪项 ⇒ 队头等操作数, 排空已到顶 ⇒ 加宽没用
  //
  // ⚠️ AIQ 深度从 RTL **实际信号**里量 ($bits 指到 aiq_entry_vld), 不走
  //   `+define` —— 免得 TB 和 RTL 各拿一个数, 悄悄对不上还算出一张假表。
  localparam int PERF_AIQ_N = $bits(dut.u_ct_idu_top.x_ct_idu_is_aiq.aiq_entry_vld);
  integer perf_aiq_occ_sum = 0, perf_aiq_issue = 0, perf_aiq_full = 0;
  integer perf_aiq_full_ready = 0, perf_aiq_full_noready = 0, perf_aiq_issue_full = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_PERF")) begin
      perf_cyc = perf_cyc + 1;
      if (dut.u_rtu.u_commit.mispred_hit) perf_mispred = perf_mispred + 1;
      if (dut.u_rtu.u_commit.flush_trig)  perf_flush    = perf_flush + 1;
      perf_rob_sum = perf_rob_sum + dut.u_rtu.u_rob.occ;
      if (dut.u_rtu.u_rob.occ > perf_rob_max) perf_rob_max = dut.u_rtu.u_rob.occ;
      if (dut.u_rtu.u_rob.occ == 0) perf_rob_zero = perf_rob_zero + 1;
      // ---- 冻结窗拆解的状态机 (与上面同拍, 在 perf 块里) ----
      case (fz_st)
        0: if (dut.iu_chgflw_vld) begin
             fz_st = 1; fz_cnt = 0; fz_n = fz_n + 1;
           end
        1: begin fz_cnt = fz_cnt + 1; fz_ev = fz_ev + 1;
             // ① 里有多少拍是在等 LSU 的"退休 store 数据到齐"(blocked)?
             if (dut.u_rtu.u_flush.f1)       fz_in_f1  = fz_in_f1  + 1;
             if (dut.u_rtu.u_flush.blocked)  fz_blocked = fz_blocked + 1;
             if (dut.rtu_yy_xx_flush) begin fz_s1 = fz_s1 + fz_cnt; fz_st = 2; fz_cnt = 0; end
           end
        2: begin fz_cnt = fz_cnt + 1; fz_ev = fz_ev + 1;
             if (!dut.mispred_hold_q) begin
               fz_s2 = fz_s2 + fz_cnt;
               if (!dut.idu_inst0_vld) fz_gate_vs_ife = fz_gate_vs_ife + 1;
               fz_st = 3; fz_cnt = 0;
             end
           end
        3: begin fz_cnt = fz_cnt + 1; fz_ev = fz_ev + 1;
             if (|dut.u_rv32ifu2_top.push_mask) begin fz_s3 = fz_s3 + fz_cnt; fz_st = 4; fz_cnt = 0; end
           end
        4: begin fz_cnt = fz_cnt + 1; fz_ev = fz_ev + 1;
             if (dut.idu_inst0_vld) begin
               fz_s4 = fz_s4 + fz_cnt;
               // fz_ev 在每段都累加了 ⇒ 这里就是四段之和 (本事件总窗口)
               fz_tot = fz_tot + fz_ev;
               if (fz_ev > 16) fz_hist[16] = fz_hist[16] + 1;
               else            fz_hist[fz_ev] = fz_hist[fz_ev] + 1;
               fz_ev = 0;
               fz_st = 0;
             end
           end
      endcase
      if (dut.u_rv32ifu2_top.refill_req)  perf_ic_miss = perf_ic_miss + 1;
      if (dut.u_rv32ifu2_top.refill_busy) perf_ic_busy = perf_ic_busy + 1;
      if (!(dut.idu_inst0_vld | dut.idu_inst1_vld | dut.idu_inst2_vld)) begin
        perf_fe_idle = perf_fe_idle + 1;
        if (!dut.u_rtu.u_flush.fsm_busy) begin
          perf_fe_idle_nf = perf_fe_idle_nf + 1;
          // 这一拍取指地址在不在缓存里 (init_all 门控: 初始化扫描期间不算)
          if (dut.u_rv32ifu2_top.init_all & ~dut.u_rv32ifu2_top.q_hit)
            perf_ic_idle_miss = perf_ic_idle_miss + 1;
          else begin
            perf_ic_idle_hit  = perf_ic_idle_hit  + 1;
            if (dut.u_rv32ifu2_top.redirect)      perf_idle_red = perf_idle_red + 1;
            else if (dut.u_rtu.mispred_pend)      perf_idle_mpp = perf_idle_mpp + 1;
            else                                  perf_idle_oth = perf_idle_oth + 1;
          end
        end
      end
      perf_n_disp = dut.u_rtu.u_preg.disp_vld[0] + dut.u_rtu.u_preg.disp_vld[1]
                  + dut.u_rtu.u_preg.disp_vld[2];
      perf_disp_sum = perf_disp_sum + perf_n_disp;
      if      (perf_n_disp == 1) perf_disp1 = perf_disp1 + 1;
      else if (perf_n_disp == 2) perf_disp2 = perf_disp2 + 1;
      else if (perf_n_disp == 3) perf_disp3 = perf_disp3 + 1;
      perf_n_ret = dut.dbg_commit_vld0 + dut.dbg_commit_vld1 + dut.dbg_commit_vld2;
      if      (perf_n_ret == 1) perf_ret1 = perf_ret1 + 1;
      else if (perf_n_ret == 2) perf_ret2 = perf_ret2 + 1;
      else if (perf_n_ret == 3) perf_ret3 = perf_ret3 + 1;
      // 有指令等着派的那一拍, 看看是谁挡的
      if (dut.u_ct_idu_top.x_ct_idu_is_ctrl.is_dis_inst0_vld) begin
        perf_blk_wait = perf_blk_wait + 1;
        if (dut.rtu_idu_rob_full) perf_blk_stall = perf_blk_stall + 1;   // 四项相或
        if (dut.u_rtu.rob_full)     perf_blk_rob    = perf_blk_rob    + 1;
        if (dut.u_rtu.csr_inflight) perf_blk_csr    = perf_blk_csr    + 1;
        if (dut.u_rtu.flushing)     perf_blk_flushw = perf_blk_flushw + 1;
        if (dut.u_rtu.mispred_pend) perf_blk_mppend = perf_blk_mppend + 1;
        if (dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_aiq_full_updt)  perf_blk_aiq  = perf_blk_aiq  + 1;
        if (dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_biq_full_updt)  perf_blk_biq  = perf_blk_biq  + 1;
        if (dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_lsiq_full_updt) perf_blk_lsiq = perf_blk_lsiq + 1;
        if (dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_sdiq_full_updt) perf_blk_sdiq = perf_blk_sdiq + 1;
        if (dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_mult_full_updt) perf_blk_mult = perf_blk_mult + 1;
        if (dut.u_ct_idu_top.x_ct_idu_is_ctrl.ctrl_is_div_full_updt)  perf_blk_div  = perf_blk_div  + 1;
      end
      // ---- AIQ 深挖 ----
      perf_aiq_occ_sum = perf_aiq_occ_sum + dut.u_ct_idu_top.x_ct_idu_is_aiq.aiq_entry_cnt;
      if (dut.u_ct_idu_top.x_ct_idu_is_aiq.aiq_xx_issue_en) perf_aiq_issue = perf_aiq_issue + 1;
      if (dut.u_ct_idu_top.x_ct_idu_is_aiq.aiq_entry_cnt >= (PERF_AIQ_N-1)) begin
        perf_aiq_full = perf_aiq_full + 1;
        if (|dut.u_ct_idu_top.x_ct_idu_is_aiq.aiq_entry_ready) perf_aiq_full_ready   = perf_aiq_full_ready   + 1;
        else                                                    perf_aiq_full_noready = perf_aiq_full_noready + 1;
        if (dut.u_ct_idu_top.x_ct_idu_is_aiq.aiq_xx_issue_en)   perf_aiq_issue_full  = perf_aiq_issue_full  + 1;
      end
    end
  end
  final begin
    if ($test$plusargs("PROBE_PERF")) begin
      $display("");
      $display("==================== [PERF] 周期分解 ====================");
      $display("  统计拍数          : %0d", perf_cyc);
      $display("  退休              : %0d  (IPC = %0.3f)",
               retired, perf_cyc ? retired * 1.0 / perf_cyc : 0.0);
      $display("  误预测 (mispred)  : %0d 次  ⇒ 每 %0.1f 拍一次",
               perf_mispred, perf_mispred ? perf_cyc * 1.0 / perf_mispred : 0.0);
      $display("  冲刷 (flush_trig) : %0d 次", perf_flush);
      $display("  ROB 占用          : 均值 %0.1f / 64, 峰值 %0d, 空 %0d 拍 (%.1f%%)",
               perf_cyc ? perf_rob_sum * 1.0 / perf_cyc : 0.0, perf_rob_max,
               perf_rob_zero, perf_cyc ? perf_rob_zero * 100.0 / perf_cyc : 0.0);
      $display("  前端无货          : %0d 拍 (%.1f%%)  其中非冲刷冻结窗 %0d 拍 (%.1f%%)",
               perf_fe_idle, perf_cyc ? perf_fe_idle * 100.0 / perf_cyc : 0.0,
               perf_fe_idle_nf, perf_fe_idle_nf && perf_cyc ? perf_fe_idle_nf * 100.0 / perf_cyc : 0.0);
      $display("  ---- 前端无货(非冻结窗)的成因 ----");
      $display("    取指地址 miss  : %0d 拍 (%.1f%% of 非冻结窗)  ⇒ i-cache 问题",
               perf_ic_idle_miss,
               perf_fe_idle_nf ? perf_ic_idle_miss * 100.0 / perf_fe_idle_nf : 0.0);
      $display("    取指地址命中   : %0d 拍 (%.1f%% of 非冻结窗)  ⇒ 不是缓存问题",
               perf_ic_idle_hit,
               perf_fe_idle_nf ? perf_ic_idle_hit * 100.0 / perf_fe_idle_nf : 0.0);
      $display("      ├ 重定向当拍(IBUF 刚被清): %0d 拍", perf_idle_red);
      $display("      ├ 未决重定向窗口        : %0d 拍", perf_idle_mpp);
      $display("      └ 其它(真·供给不上)     : %0d 拍 (%.1f%% of 非冻结窗)",
               perf_idle_oth,
               perf_fe_idle_nf ? perf_idle_oth * 100.0 / perf_fe_idle_nf : 0.0);
      $display("  ---- 误预测冻结窗拆解 (%0d 次) ----", fz_n);
      if (fz_n > 0) begin
        $display("    ① EX重定向→冲刷脉冲 : %0.2f 拍", fz_s1 * 1.0 / fz_n);
        $display("       ├ 其中在 F1 等闸门   : %0.2f 拍/次", fz_in_f1 * 1.0 / fz_n);
        $display("       └ 其中 blocked=1(LSU): %0.2f 拍/次", fz_blocked * 1.0 / fz_n);
        $display("    ② 脉冲→开闸(冲刷跑完): %0.2f 拍", fz_s2 * 1.0 / fz_n);
        $display("    ③ 开闸→IBUF 被写     : %0.2f 拍", fz_s3 * 1.0 / fz_n);
        $display("    ④ 写入→交货          : %0.2f 拍", fz_s4 * 1.0 / fz_n);
        $display("    合计                 : %0.2f 拍/次", fz_tot * 1.0 / fz_n);
        $display("    ⚠️ 开闸时 IBUF 还没货 : %0d 次 (%.1f%%) ⇒ 这部分是重取慢, 其余是冲刷慢",
                 fz_gate_vs_ife, fz_gate_vs_ife * 100.0 / fz_n);
        $display("    窗口直方图 (拍:次数) :");
        for (int k = 0; k <= 16; k = k + 1)
          if (fz_hist[k] != 0)
            $display("      %2d 拍 : %0d%s", k, fz_hist[k], (k == 16) ? "  (16+)" : "");
      end
      $display("  ---- i-cache 全局 ----");
      $display("    miss 次数      : %0d 次  ⇒ 每 %0.1f 拍一次",
               perf_ic_miss, perf_ic_miss ? perf_cyc * 1.0 / perf_ic_miss : 0.0);
      $display("    回填在途       : %0d 拍 (%.1f%% of 全拍)  平均每次 miss %0.1f 拍",
               perf_ic_busy, perf_cyc ? perf_ic_busy * 100.0 / perf_cyc : 0.0,
               perf_ic_miss ? perf_ic_busy * 1.0 / perf_ic_miss : 0.0);
      $display("  派遣总数          : %0d  (%.3f 条/拍)", perf_disp_sum,
               perf_cyc ? perf_disp_sum * 1.0 / perf_cyc : 0.0);
      $display("    每拍派遣条数分布 : 1 条 %0d 拍 (%.1f%%) | 2 条 %0d 拍 (%.1f%%) | 3 条 %0d 拍 (%.1f%%)",
               perf_disp1, perf_cyc ? perf_disp1 * 100.0 / perf_cyc : 0.0,
               perf_disp2, perf_cyc ? perf_disp2 * 100.0 / perf_cyc : 0.0,
               perf_disp3, perf_cyc ? perf_disp3 * 100.0 / perf_cyc : 0.0);
      $display("    每拍退休条数分布 : 1 条 %0d 拍 (%.1f%%) | 2 条 %0d 拍 (%.1f%%) | 3 条 %0d 拍 (%.1f%%)",
               perf_ret1, perf_cyc ? perf_ret1 * 100.0 / perf_cyc : 0.0,
               perf_ret2, perf_cyc ? perf_ret2 * 100.0 / perf_cyc : 0.0,
               perf_ret3, perf_cyc ? perf_ret3 * 100.0 / perf_cyc : 0.0);
      $display("  ---- 有指令等着派时, 谁在挡 (共 %0d 拍) ----", perf_blk_wait);
      $display("    RTU 停   : %8d 拍 (%5.1f%%)   = rob_full|csr|冲刷窗|未决重定向",
               perf_blk_stall,
               perf_blk_wait ? perf_blk_stall * 100.0 / perf_blk_wait : 0.0);
      $display("      ├ ROB 真满 (occ>=60): %8d 拍 (%5.1f%%)", perf_blk_rob,
               perf_blk_wait ? perf_blk_rob    * 100.0 / perf_blk_wait : 0.0);
      $display("      ├ CSR 在途          : %8d 拍 (%5.1f%%)", perf_blk_csr,
               perf_blk_wait ? perf_blk_csr    * 100.0 / perf_blk_wait : 0.0);
      $display("      ├ 冲刷恢复窗        : %8d 拍 (%5.1f%%)", perf_blk_flushw,
               perf_blk_wait ? perf_blk_flushw * 100.0 / perf_blk_wait : 0.0);
      $display("      └ 未决重定向        : %8d 拍 (%5.1f%%)", perf_blk_mppend,
               perf_blk_wait ? perf_blk_mppend * 100.0 / perf_blk_wait : 0.0);
      $display("    AIQ 满   : %8d 拍 (%5.1f%%)", perf_blk_aiq,
               perf_blk_wait ? perf_blk_aiq  * 100.0 / perf_blk_wait : 0.0);
      $display("    BIQ 满   : %8d 拍 (%5.1f%%)", perf_blk_biq,
               perf_blk_wait ? perf_blk_biq  * 100.0 / perf_blk_wait : 0.0);
      $display("    LSIQ 满  : %8d 拍 (%5.1f%%)", perf_blk_lsiq,
               perf_blk_wait ? perf_blk_lsiq * 100.0 / perf_blk_wait : 0.0);
      $display("    SDIQ 满  : %8d 拍 (%5.1f%%)", perf_blk_sdiq,
               perf_blk_wait ? perf_blk_sdiq * 100.0 / perf_blk_wait : 0.0);
      $display("    MUL 满   : %8d 拍 (%5.1f%%)", perf_blk_mult,
               perf_blk_wait ? perf_blk_mult * 100.0 / perf_blk_wait : 0.0);
      $display("    DIV 满   : %8d 拍 (%5.1f%%)", perf_blk_div,
               perf_blk_wait ? perf_blk_div  * 100.0 / perf_blk_wait : 0.0);
      $display("  ---- AIQ 深挖 (%0d 项): 满 = 深度不够 还是 排空到顶? ----", PERF_AIQ_N);
      $display("    AIQ 占用均值   : %0.2f / %0d",
               perf_cyc ? perf_aiq_occ_sum * 1.0 / perf_cyc : 0.0, PERF_AIQ_N);
      $display("    AIQ 发射率     : %0d 次 (%.3f 次/拍)", perf_aiq_issue,
               perf_cyc ? perf_aiq_issue * 1.0 / perf_cyc : 0.0);
      $display("    AIQ 满(cnt>=N-1): %0d 拍 (%.1f%%)", perf_aiq_full,
               perf_cyc ? perf_aiq_full * 100.0 / perf_cyc : 0.0);
      $display("      其中有就绪项 : %0d 拍 (%.1f%% of 满)  ⇒ 加宽有用",
               perf_aiq_full_ready, perf_aiq_full ? perf_aiq_full_ready * 100.0 / perf_aiq_full : 0.0);
      $display("      其中无就绪项 : %0d 拍 (%.1f%% of 满)  ⇒ 排空到顶, 加宽没用",
               perf_aiq_full_noready, perf_aiq_full ? perf_aiq_full_noready * 100.0 / perf_aiq_full : 0.0);
      $display("      满着仍在发射 : %0d 拍 (%.1f%% of 满)",
               perf_aiq_issue_full, perf_aiq_full ? perf_aiq_issue_full * 100.0 / perf_aiq_full : 0.0);
      $display("========================================================");
    end
  end

  // [POOL] preg 池余量 / ROB 占用 / 退休数 的趋势
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_POOL") && (cycles % 100000) == 0)
      $display("  [POOL] T%0d free_cnt=%0d rob_occ=%0d retired=%0d",
               cycles, dut.u_rtu.u_preg.free_cnt, dut.u_rtu.u_rob.occ, retired);
  end

  // [HEAD] ROB 队头表项 (位域同 RTU_define.vh: RTU_E_PC 120:89 / VLD 123 /
  //        CMPLT 122 / FLAGS 12:6 / DST_PREG 26:20 / OLD_PREG 19:13)
  integer hd_lo = 10900000, hd_hi = 11100000;
  initial begin
    void'($value$plusargs("HD_LO=%d", hd_lo));
    void'($value$plusargs("HD_HI=%d", hd_hi));
  end
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_HEAD") && cycles >= hd_lo && cycles <= hd_hi
        && (cycles % 200) == 0)
      $display("  [HEAD] T%0d rptr=%0d iid=%0d pc=%08x vld=%b cmplt=%b flags=%b dst_preg=%0d old_preg=%0d occ=%0d free=%0d",
               cycles,
               dut.u_rtu.u_rob.rptr,
               {dut.u_rtu.u_rob.rptr_msb, dut.u_rtu.u_rob.rptr},
               dut.u_rtu.u_rob.rob_q[dut.u_rtu.u_rob.rptr][120:89],
               dut.u_rtu.u_rob.rob_q[dut.u_rtu.u_rob.rptr][123],
               dut.u_rtu.u_rob.rob_q[dut.u_rtu.u_rob.rptr][122],
               dut.u_rtu.u_rob.rob_q[dut.u_rtu.u_rob.rptr][12:6],
               dut.u_rtu.u_rob.rob_q[dut.u_rtu.u_rob.rptr][26:20],
               dut.u_rtu.u_rob.rob_q[dut.u_rtu.u_rob.rptr][19:13],
               dut.u_rtu.u_rob.occ, dut.u_rtu.u_preg.free_cnt);
  end

  // [FSRC] **这次 flush 是哪来的** —— 回答"为什么会来这次冲刷"
  //   `RTU_commit.v:302`  `flush_trig = trap_hit|int_take|mret_hit|replay_hit|mispred_hit`
  //   `RTU_commit.v:306`  `flush_src  = replay_hit ? RTU_FS_REPLAY : RTU_FS_MISPRED`
  //   src 编码 (RTU_define.vh:157-161): 0=EXPT 1=INT 2=MRET 3=MISPRED 4=REPLAY
  //   ⚠️ 4=REPLAY 的注释是 "store 投机失败 ⇒ 冲掉它和更年轻的, 从它的 PC 重取"
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_FSRC") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [FSRC] T%0d trig=%b src=%0d pc=%08x | lsu_replay vld=%b iid=%0d | beu_redir=%b | fsm=%0d busy=%b",
               cycles, dut.u_rtu.u_flush.flush_trig, dut.u_rtu.u_flush.flush_src,
               dut.u_rtu.u_flush.flush_pc,
               dut.u_rtu.u_commit.lsu_replay_vld, dut.u_rtu.u_commit.lsu_replay_iid,
               dut.u_rtu.u_flush.beu_redirect_vld,
               dut.u_rtu.u_flush.st_q, dut.u_rtu.u_flush.fsm_busy);
  end

  // 【临时诊断】RTU 冲刷闸 `lsu_rtu_all_commit_data_vld` 的"谁在挡"逐拍表 —— `+PROBE_FLG`
  //   2026-10-15 加, 追"补了冲刷闸之后新出现的卡死": 闸门是 0 时, 是哪个 SQ 表项
  //   已 cmit 却没有 store data (还在等 SDIQ); 顺带把 RTU 冲刷 FSM 停在
  //   IDLE/WAIT/F1 哪一态一起打出来。
  //
  //   ⚠️ 这里**不再打 ld 侧** —— 原来的 `lsu_rtu_all_commit_ld_data_vld` /
  //      `u_lsu_mshr.rb_entry_cmit_data_vld` 两根在本仓**根本没有**:
  //      * ld 侧的冲刷闸整个没移植 (见 lsu_top.sv:1510、lsu_mshr.sv:158 的注释);
  //      * MSHR 表项内部今天虽有 `rb_entry_cmit_data_not_vld`
  //        (lsu_mshr_entry.sv:693), 但 lsu_mshr 既没引出、也没聚合。
  //      所以 `dut.lsu_rtu_all_commit_data_vld` 现在**恒等于** st 侧那一根。
  //
  //   ⚠️ 口径: sq 侧的口是本仓重写的 `sq_entry_cmit_data_not_vld`
  //      (lsu_sq.sv:218 声明 / :295 连表项 / :354 用), 语义与名字相反 ——
  //      **1 = 这个已退休表项还缺数据**, 即"就是它在挡闸门"。C910 原版的
  //      `sq_entry_cmit_data_vld` 在移植时没留。
  //      另注: 该线现在是**标量**且被 SQ_ENTRY 个表项并联驱动, 探针读到的值
  //      未必可信, 见 lsu_sq.sv:218 处的隐患。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_FLG") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [FLG] T%0d all=%b st=%b | fsm_st=%0d busy=%b flushing=%b flush_trig=%b | sq_vld=%b sq_cmit=%b sq_cmitnodvld=%b | rb_vld=%b",
        cycles,
        dut.lsu_rtu_all_commit_data_vld,
        dut.u_lsu_top.lsu_rtu_all_commit_st_data_vld,
        dut.u_rtu.u_flush.st_q,
        dut.u_rtu.u_flush.fsm_busy,
        dut.u_rtu.u_flush.flushing,
        dut.u_rtu.u_flush.flush_trig,
        dut.u_lsu_top.u_lsu_sq.sq_entry_vld,
        dut.u_lsu_top.u_lsu_sq.sq_entry_cmit,
        dut.u_lsu_top.u_lsu_sq.sq_entry_cmit_data_not_vld,
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vld);
    end
  end

  // 【临时诊断】总线 AW/W 两侧 + BIU 写通道 FSM —— `+PROBE_BUS` (窗由 STL_LO/STL_HI 给)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_BUS") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [BUS] T%0d aw_req st=%b vict=%b | w_req st=%b vict=%b | wmb_aw=%b wmb_w=%b | vb_hit=%b lfb_hit=%b wbiu_unmask=%b wdata_req=%b | FSM st=%0d sel=%b aw_done=%b w_done=%b | pad awv=%b awr=%b wv=%b wr=%b wl=%b",
               cycles,
               dut.u_lsu_top.u_ct_lsu_bus_arb.lsu_biu_aw_st_req,
               dut.u_lsu_top.u_ct_lsu_bus_arb.lsu_biu_aw_vict_req,
               dut.u_lsu_top.u_ct_lsu_bus_arb.lsu_biu_w_st_vld,
               dut.u_lsu_top.u_ct_lsu_bus_arb.lsu_biu_w_vict_vld,
               dut.u_lsu_top.u_lsu_wmb.wmb_biu_aw_req,
               dut.u_lsu_top.u_lsu_wmb.wmb_biu_w_req,
               dut.u_lsu_top.u_lsu_wmb.vb_wmb_hit_idx,
               dut.u_lsu_top.u_lsu_wmb.lfb_wmb_write_req_hit_idx,
               dut.u_lsu_top.u_lsu_wmb.wmb_write_biu_req_unmask,
               dut.u_lsu_top.u_lsu_wmb.wmb_data_req,
               dut.u_ct_biu_top.u_ct_biu_write_channel.wr_state,
               dut.u_ct_biu_top.u_ct_biu_write_channel.wr_sel_st,
               dut.u_ct_biu_top.u_ct_biu_write_channel.aw_done,
               dut.u_ct_biu_top.u_ct_biu_write_channel.w_done,
               dut.biu_pad_awvalid, dut.pad_biu_awready,
               dut.biu_pad_wvalid, dut.pad_biu_wready, dut.biu_pad_wlast);
    if (!rst && $test$plusargs("PROBE_BUS") && cycles >= stl_lo && cycles <= stl_hi)
      $display("        [SLV] aw_done=%b bvalid_r=%b bready=%b wr_cnt=%0d wr_len=%0d wr_addr=%08x | VB wsm vld=%b data_bias=%b strb=%04x data=%032x",
               u_mem.aw_done, u_mem.bvalid_r, dut.biu_pad_bready,
               u_mem.wr_cnt, u_mem.wr_len, u_mem.wr_addr,
               dut.u_lsu_top.u_lsu_vb.vb_wd_sm_vld,
               dut.u_lsu_top.u_lsu_vb.vb_wd_sm_data_bias,
               dut.u_lsu_top.u_lsu_vb.vb_biu_w_strb,
               dut.u_lsu_top.u_lsu_vb.vb_biu_w_data);
  end

  // 【临时诊断】dcache_arb 全部请求/授权向量 —— `+PROBE_ARB2` (窗由 STL_LO/STL_HI 给)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_ARB2") && cycles >= stl_lo && cycles <= stl_hi)
      $display("  [AR2] T%0d LDreq=%b LDsel=%b | STreq=%b STsel=%b | grnt lfbL=%b vbL=%b wmbL=%b | lfbS=%b vbS=%b agS=%b wmbS=%b | vb rcl_st=%0d vb_st_req=%b vb_ld_req=%b vb_borrow_ld=%b vb_borrow_st=%b",
               cycles,
               dut.u_lsu_top.u_dcache_arb.dcache_arb_ld_req, dut.u_lsu_top.u_dcache_arb.dcache_arb_ld_sel,
               dut.u_lsu_top.u_dcache_arb.dcache_arb_st_req, dut.u_lsu_top.u_dcache_arb.dcache_arb_st_sel,
               dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_ld_grnt, dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_ld_grnt,
               dut.u_lsu_top.u_dcache_arb.dcache_arb_wmb_ld_grnt,
               dut.u_lsu_top.u_dcache_arb.dcache_arb_lfb_st_sel, dut.u_lsu_top.u_dcache_arb.dcache_arb_vb_st_sel,
               dut.u_lsu_top.u_dcache_arb.dcache_arb_ag_st_sel, dut.u_lsu_top.u_dcache_arb.dcache_arb_wmb_st_sel,
               dut.u_lsu_top.u_lsu_vb.vb_rcl_sm_state,
               dut.u_lsu_top.vb_dcache_arb_st_req, dut.u_lsu_top.vb_dcache_arb_ld_borrow_req,
               dut.u_lsu_top.u_lsu_vb.vb_dcache_arb_ld_borrow_req,
               dut.u_lsu_top.u_lsu_vb.vb_dcache_arb_st_borrow_req);
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
      if (dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld)
        $display("  [LDB] T%0d addr=%08x ldw0=%b ldw1=%b | b0=%08x b1=%08x b2=%08x b3=%08x b4=%08x b5=%08x b6=%08x b7=%08x",
                 cycles, dut.u_lsu_top.u_lsu_ld_da.ld_da_addr,
                 dut.u_lsu_top.u_lsu_ld_dc.ld_dc_hit_way0,
                 dut.u_lsu_top.u_lsu_ld_dc.ld_dc_hit_way1,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_data_bank0,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_data_bank1,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_data_bank2,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_data_bank3,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_data_bank4,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_data_bank5,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_data_bank6,
                 dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_data_bank7);
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
      $display("  [SDS] T%0d bcast: sdiq_sel=%b sdiq_id=%b pipe5_src0=%08x | sd_ex1_vld=%b sd_rf_ex1_sdid=%b | e_sdid=%b %b %b",
               cycles, dut.idu_lsu_sdiq_sel, dut.idu_lsu_rf_pipe5_sdiq_entry,
               dut.idu_lsu_rf_pipe5_src0,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sd_ex1_inst_vld,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sd_rf_ex1_sdid,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[0].x_ct_lsu_sq_entry.sq_entry_sdid,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[1].x_ct_lsu_sq_entry.sq_entry_sdid,
               dut.u_lsu_top.u_lsu_sq.gen_sq_entry[2].x_ct_lsu_sq_entry.sq_entry_sdid);
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

  // 【临时诊断】WMB (写合并缓冲) 的合并通路 —— `+PROBE_WMB` (窗由 STL_LO/STL_HI 给)
  //
  // 【为什么加它】coremark_i1 第 939 条 (`lw a1,4(t3)` @ pc=0x938, addr=0xf8dc) 失配:
  //   提供数据的那笔 store (`sw a7,4(a3)` @ pc=0x8d8, iid=105) 在 SQ 里是对的
  //   (entry2: addr=0xf8dc data=0x0000f95c), 也带着 0xf95c pop 给了 CE, 但这条 128 位
  //   线的最终 AXI 写 (T1356 AW=0xf8d0 / T1357 W strb=0xf000) 里 data[127:96] 却是
  //   **旧行内容 0x7fff5b5b** —— strb 更新了、data 没换成新值。
  //   所以要逐拍看: sq_pop → CE → WMB 表项 这一路, 新数据在哪一拍哪一根上丢的。
  //
  // 排障顺序: 先看 mstall (merge 被 stall 而没重试 ⇒ 丢数据), 再看 CE 给的
  //   bytes_vld/data_vld 是否覆盖了目标 word3(bit3)/字节 12-15, 最后看表项
  //   E? 的 data 有没有真的被新值覆盖。
  integer wmb_k;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_WMB") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [WCE] T%0d pop: ptr=%b addr=%08x bv=%04x data=%032x | mreq=%b mstall_req=%b pce=%b",
               cycles, dut.u_lsu_top.sq_pop_ptr, dut.u_lsu_top.sq_pop_addr,
               dut.u_lsu_top.sq_pop_bytes_vld, dut.u_lsu_top.sq_pop_data,
               dut.u_lsu_top.sq_wmb_merge_req, dut.u_lsu_top.sq_wmb_merge_stall_req,
               dut.u_lsu_top.sq_wmb_pop_to_ce_req);
      $display("        CE锁存: vld=%b merge=%b stall=%b mptr=%b sqptr=%b | 建表 vld=%b merge=%b stall=%b mptr=%b wreq=%b wdreq=%b | pop_vld=%b",
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_vld,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_stall,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_ptr,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_sq_ptr,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_create_vld,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_create_merge,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_create_stall,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_create_merge_ptr,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_create_wmb_req,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_create_wmb_data_req,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_pop_vld);
      $display("        CE活: mwreq=%b ahit=%b mstall=%b mnotvld=%b | data_vld=%b bytes_vld=%04x data128=%032x",
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_wmb_req,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_data_addr_hit,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_data_stall,
               dut.u_lsu_top.u_lsu_wmb_ce.wmb_ce_merge_not_vld,
               dut.u_lsu_top.wmb_ce_data_vld, dut.u_lsu_top.wmb_ce_bytes_vld,
               dut.u_lsu_top.wmb_ce_data128);
      $display("        WMB: mrgvld=%b ahit=%b mstall=%b", dut.u_lsu_top.u_lsu_wmb.wmb_merge_vld,
               dut.u_lsu_top.u_lsu_wmb.wmb_merge_data_addr_hit,
               dut.u_lsu_top.u_lsu_wmb.wmb_merge_data_stall);
      for (wmb_k = 0; wmb_k < 4; wmb_k = wmb_k + 1)
        $display("        E%0d v=%b cv=%b mv=%b ah=%b st=%b addr=%08x bv=%04x data=%032x",
                 wmb_k,
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_vld[wmb_k],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_create_vld[wmb_k],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_merge_data_vld[wmb_k],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_merge_data_addr_hit[wmb_k],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_merge_data_stall[wmb_k],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_addr[wmb_k],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_bytes_vld[wmb_k],
                 dut.u_lsu_top.u_lsu_wmb.wmb_entry_data[wmb_k]);
    end
  end

  // 【临时诊断】WMB 两根独立指针 (write_ptr 管 AW 地址 / data_ptr 管 W 数据) —— `+PROBE_PTR`
  //   若二者错位, 就会出现 "AW 地址来自表项 X、W 数据来自表项 Y" 的交叉写。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_PTR") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [PTR] T%0d wptr=%b dptr=%b cptr=%b | aw_addr=%08x w_data=%032x w_strb=%04x",
               cycles,
               dut.u_lsu_top.u_lsu_wmb.wmb_write_ptr,
               dut.u_lsu_top.u_lsu_wmb.wmb_data_ptr,
               dut.u_lsu_top.u_lsu_wmb.wmb_create_ptr,
               {dut.u_lsu_top.u_lsu_wmb.wmb_write_req_addr[31:4], 4'b0},
               dut.u_lsu_top.u_lsu_wmb.wmb_data_req_data,
               dut.u_lsu_top.u_lsu_wmb.wmb_data_req_bytes_vld);
      $display("        ptrbit: w0=%b w1=%b w2=%b w3=%b | d0=%b d1=%b d2=%b d3=%b | aw_req=%b w_req=%b | shift: wsh=%b dsh=%b",
               dut.u_lsu_top.u_lsu_wmb.wmb_write_ptr[0], dut.u_lsu_top.u_lsu_wmb.wmb_write_ptr[1],
               dut.u_lsu_top.u_lsu_wmb.wmb_write_ptr[2], dut.u_lsu_top.u_lsu_wmb.wmb_write_ptr[3],
               dut.u_lsu_top.u_lsu_wmb.wmb_data_ptr[0], dut.u_lsu_top.u_lsu_wmb.wmb_data_ptr[1],
               dut.u_lsu_top.u_lsu_wmb.wmb_data_ptr[2], dut.u_lsu_top.u_lsu_wmb.wmb_data_ptr[3],
               dut.u_lsu_top.u_lsu_wmb.wmb_biu_aw_req, dut.u_lsu_top.u_lsu_wmb.wmb_data_req,
               dut.u_lsu_top.u_lsu_wmb.wmb_write_ptr_shift_vld, dut.u_lsu_top.u_lsu_wmb.wmb_data_ptr_shift_vld);
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

  // 【临时诊断】PRF 实况: 几个 preg 的值 + 写使能, 每拍 —— `+PROBE_PRF` (窗由 STL_LO/STL_HI 给)
  //   用来一锤定音: "值是没写进 PRF" 还是 "写进去了但退休读路取错"。
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_PRF") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [PRF] T%0d p59=%08x wv59=%b | p51=%08x wv51=%b | p6=%08x wv6=%b | p46=%08x wv46=%b | LSU_wb: vld=%b#%0d=%08x",
               cycles,
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.preg_reg_dout[59],
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.preg_wb_vld[59],
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.preg_reg_dout[51],
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.preg_wb_vld[51],
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.preg_reg_dout[6],
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.preg_wb_vld[6],
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.preg_reg_dout[46],
               dut.u_ct_idu_top.x_ct_idu_rf_prf_pregfile.preg_wb_vld[46],
               dut.lsu_idu_wb_pipe3_wb_preg_vld, dut.lsu_idu_wb_pipe3_wb_preg,
               dut.lsu_idu_wb_pipe3_wb_preg_data);
    end
  end

  // 【临时诊断】MSHR/refill-buffer 表项逐拍: vld/cmit/wb_data_req/flush_clear —— `+PROBE_MSHR`
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_MSHR") && cycles >= stl_lo && cycles <= stl_hi) begin
      $display("  [MSHR] T%0d yy_flush=%b | e0: vld=%b cmit=%b wbreq=%b fclr=%b iid=%0d addr=%08x",
               cycles, dut.rtu_yy_xx_flush,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_vld,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_cmit,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_wb_data_req,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_flush_clear,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_iid,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_addr);
      $display("        e1: vld=%b cmit=%b wbreq=%b fclr=%b iid=%0d addr=%08x | e2: vld=%b cmit=%b wbreq=%b iid=%0d addr=%08x",
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[1].u_mshr_entry.rb_entry_vld,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[1].u_mshr_entry.rb_entry_cmit,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[1].u_mshr_entry.rb_entry_wb_data_req,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[1].u_mshr_entry.rb_entry_flush_clear,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[1].u_mshr_entry.rb_entry_iid,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[1].u_mshr_entry.rb_entry_addr,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[2].u_mshr_entry.rb_entry_vld,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[2].u_mshr_entry.rb_entry_cmit,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[2].u_mshr_entry.rb_entry_wb_data_req,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[2].u_mshr_entry.rb_entry_iid,
               dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[2].u_mshr_entry.rb_entry_addr);
    end
  end

  // 【临时诊断】窗口内派遣映射 (pc↔iid↔dst_preg) —— `+PROBE_MAP` (窗由 STL_LO/STL_HI 给)
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_MAP") && cycles >= stl_lo && cycles <= stl_hi
        && (dut.idu_rtu_disp0_vld || dut.idu_rtu_disp1_vld || dut.idu_rtu_disp2_vld)) begin
      $display("  [MAP] T%0d 派 vld=%b%b%b pc=%08x,%08x,%08x dst_preg=%0d,%0d,%0d lreg=%0d,%0d,%0d iid=%0d,%0d,%0d",
               cycles, dut.idu_rtu_disp2_vld, dut.idu_rtu_disp1_vld, dut.idu_rtu_disp0_vld,
               dut.idu_rtu_disp0_pc, dut.idu_rtu_disp1_pc, dut.idu_rtu_disp2_pc,
               dut.idu_rtu_disp0_dst_preg, dut.idu_rtu_disp1_dst_preg, dut.idu_rtu_disp2_dst_preg,
               dut.idu_rtu_disp0_dst_lreg, dut.idu_rtu_disp1_dst_lreg, dut.idu_rtu_disp2_dst_lreg,
               dut.rtu_disp_iid0, dut.rtu_disp_iid1, dut.rtu_disp_iid2);
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
    void'($value$plusargs("WB_LO=%d", wb_lo));
    void'($value$plusargs("WB_HI=%d", wb_hi));
    void'($value$plusargs("DCL_LO=%h", dcl_lo));
    void'($value$plusargs("DCL_HI=%h", dcl_hi));
    void'($value$plusargs("DWLO=%d", dw_lo));
    void'($value$plusargs("DWHI=%d", dw_hi));
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
    // 临时: 让 +STL_LO/+STL_HI 能改探针窗口 (默认 270/330 是早期用例的现场)
    void'($value$plusargs("STL_LO=%d", stl_lo));
    void'($value$plusargs("STL_HI=%d", stl_hi));

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
    // ⚠️ 2026-10-15: 原来是无条件 `trace_on = 1`, 而文件头注释写的是
    //    "A910_DT_ARGS=+TRACE 打全部退休流" ⇒ `trace_en` 成了死代码, 退休流**一直**在打
    //    (实测 405K 拍刷了 547K 行)。千万拍级的 CoreMark 跑分必须先关掉它。
    trace_on = trace_en;

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
