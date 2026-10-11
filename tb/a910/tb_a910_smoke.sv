`timescale 1ns / 1ps

// ===========================================================================
// tb/a910/tb_a910_smoke.sv —— A910_cpu (乱序多发射整核) 的最小冒烟台
// ===========================================================================
// 【为什么要有这个文件】
//   `mySoC/A910_cpu.sv` 是新顶层, 但仓库里只有 `make a910-elab`(只 elaborate 不仿真),
//   没有任何 TB 例化它 ⇒ 这个核**一次都没跑过**。本台补上"能跑起来 + 能自动判对错"。
//
// 【范围】最小可跑: 时钟/复位 + AXI 从机内存 + 退休监视。**不接 CSR、不接 difftest**。
//
// 【怎么判 PASS/FAIL (没有 difftest 也能判)】
//   顶层 `A910_cpu.sv:580-594` 有 15 根退休观察口 `dbg_commit_*`, 是**架构寄存器视角**
//   (vld / pc / ena / 逻辑寄存器号 / 值), 而且真的接上了 (`:1630-1644`)。`RTU.v:383-392`
//   的注释印证它本来就是给逐条比对用的 ("逐条比对, 错一位就炸")。
//   ⇒ 用例把"对不对"压进 `a0`(x10), TB 盯 `dbg_commit_reg==5'd10` 抓值即可。
//
// 【⚠️ ecall 在这个顶层里不会停机 —— 推翻了我最初的判断】
//   `ct_idu_id_decd.sv:54,139`:
//       wire op_system = (opcode == 7'b1110011);          // ECALL/EBREAK/CSR* 全部
//       assign illegal = !valid_inst || op_fence || op_system;
//   C910 的 IDU 把**整个 SYSTEM 主 opcode 判成非法指令**, 而 `ct_idu_top` **没有异常
//   输出口** (RTU 的 `expt_iu_*` 唯一来源是 BEU, 只报"取指地址非对齐")。`illegal` 只压
//   写回 (`IU_alu_pipe.v:161`), **不影响完成与退休** ⇒ `ecall` 等价于一条"不写 rd 的
//   普通指令", 静默滑过去, PC 会继续走进 bin 的补零区。
//   ⇒ **终止条件必须由本 TB 给**, 不能指望程序自己停。
//
// 【⚠️ 六根未驱动的线必须在 TB 里 force 掉, 否则第一条指令退休那拍整个 RTU 变 X】
//   未驱动的 `logic` 在 VCS 里是 **Z**, 而它们都进了组合逻辑 (见下面的 force 段)。
//   用 force 而不是改 RTL: 和 `a910-elab` 那套"不接常量桩, 免得分不清'没接'和
//   '真不会发生'"的原则一致 —— 脏东西留在顶层, 谁填谁负责。
// ===========================================================================
module tb_a910_smoke;

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
  // A910_cpu ↔ AXI 从机内存
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

  wire [127:0] pad_biu_rdata;
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
  wire         pad_biu_bready;

  axi_slave_128 #(.MEM_BLOCKS(4096)) u_mem (
    .clk     (clk),
    .rst     (rst),

    .araddr  (biu_pad_araddr),   .arid    (biu_pad_arid),
    .arlen   (biu_pad_arlen),    .arsize  (biu_pad_arsize),
    .arburst (biu_pad_arburst),  .arvalid (biu_pad_arvalid),
    .arready (pad_biu_arready),

    .rdata   (pad_biu_rdata),    .rid     (pad_biu_rid),
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
    .bvalid  (pad_biu_bvalid),   .bready  (pad_biu_bready)
  );

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
    .pad_biu_bvalid (pad_biu_bvalid), .biu_pad_bready (pad_biu_bready)
  );

  // -------------------------------------------------------------------------
  // 【雷】force 掉六根未驱动的线 —— 不拆的话第一条指令退休那拍整个 RTU 变 X
  // -------------------------------------------------------------------------
  //  `int_pending` 进的是 `RTU_commit.v:197-227` 的**组合前缀链**
  //  (`okp1 = ok1 & okp0 & ~int_pending;` / `rv1 = ... & ~int_pending` / `int_take = ...`),
  //  它是 Z ⇒ `rtu_retire_cnt` / `dbg_commit_vld1,2` 从第一条退休起恒 X ⇒ 本台报废。
  //  `iu_btb_*` 进 GHR 恢复 (`rv32ifu2_top.v:740-742`), 第一次 EX 重定向就把 X 灌进
  //  GHR ⇒ 预测 PC 变 X。
  //  `csr_*` 是 trap/mret 的目标; `cmplt_vld1/2` 只脏波形。
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

  // 【临时诊断】把 RTU 的 flush_trig 钉成 0 —— 用来判定"X 是不是只在冲刷链上"
  initial if ($test$plusargs("KILL_FLUSH")) force dut.u_rtu.flush_trig = 1'b0;

  // 【根因验证】把 `idu_accept_num` 夹成"IFU 本拍**真的**交了几条"(= `ib_vld` 的连续前缀)。
  //   IDU 那根是已知未修的契约违例 (`ct_idu_top.sv:332` 只有 00/11 且不看 vld)，
  //   而 `rv32ifu2_ibuf.v:120` 的 `cnt_q <= cnt_q + acc_push - pop_num` 没有下溢保护
  //   ⇒ IBUF 空队列时被减 3, 5 位计数器回卷成 29 ⇒ `empty` 变假 ⇒ `out_vld[0]` 无条件
  //   拉 1 ⇒ 读出从没写过的 `ent_q` = **X**。
  //   加 `+FIX_ACCEPT` 若整核能跑通, 这条因果链就闭合了。
  // ⚠️ 用 `===` 而不是 `!`: 复位期 `ib_vld` 是 X, 若让它传下去会把 IBUF 的
  //    `cnt_q` 也带成 X (force 的回灌) —— 那就不是"验证", 是"另一个 X 源"。
  //    X 一律当 0 (= 本拍没交指令), 正合契约。
  wire [1:0] accept_clamped = (dut.u_rv32ifu2_top.ib_vld[0] !== 1'b1) ? 2'd0 :
                              (dut.u_rv32ifu2_top.ib_vld[1] !== 1'b1) ? 2'd1 :
                              (dut.u_rv32ifu2_top.ib_vld[2] !== 1'b1) ? 2'd2 : 2'd3;
  // ⚠️ 不能用 `initial force` —— 那样 RHS 在 time 0 就被求值锁死 (当时是 X)。
  //    要放 `always @(*)` 里, 每次 RHS 变都重下一次过程连续赋值才会跟着动。
  wire fix_accept = $test$plusargs("FIX_ACCEPT");
  always @(*) if (fix_accept) force dut.idu_accept_num = accept_clamped;

  // 【根因验证 2】按**同事口述的语义** {0,2,3} 造一份 accept_num:
  //     !stall ⇒ 3;  !stall && pipedown2 ⇒ 2;  stall ⇒ 0
  //   等价于把 `ct_idu_id_ctrl.sv:38` 的 `|` 改成 `&`:
  //     inst2_ready = !stall & !sel[0]  ⇒  bit0 = 它, bit1 = inst2_ready|inst0_ready = !stall
  //   ⚠️ 这一份**仍然不看** `ifu_idu_ib_inst*_vld` —— 用它就是为了验证:
  //      "光把编码改对, 能不能让整核跑起来"。
  // X 当 0 处理 (= "没停"), 否则 force 的 RHS 会把 X 灌回 IBUF —— 那就不是验证了
  wire       stall_id = (dut.u_ct_idu_top.ctrl_ir_stall           === 1'b1);
  wire       pd2_id   = (dut.u_ct_idu_top.ctrl_xx_is_inst0_sel[0] === 1'b1);
  wire [1:0] accept_intended = {~stall_id, ~stall_id & ~pd2_id};
  wire fix_accept2 = $test$plusargs("FIX_ACCEPT2");
  always @(*) if (fix_accept2) force dut.idu_accept_num = accept_intended;

  // -------------------------------------------------------------------------
  // 退休监视 (全部走顶层已命名的观察口, 层次化引用, 零 RTL 改动)
  // -------------------------------------------------------------------------
  integer retired  = 0;              // 累计退休条数 (rtu_retire_cnt 是**当拍条数**, 要自己累)
  integer a0_val   = -1;             // 最后一次看到写 x10 的值 (-1 = 从没写过)
  integer a0_hits  = 0;
  integer exit_seen = 0;             // 见到 x17 = 93 (用例的退出序列标记)
  integer trap_seen = 0;
  integer trace_on  = 0;

  always @(posedge clk) begin
    if (!rst) begin
      retired = retired + dut.rtu_retire_cnt;

      if (trace_on && dut.rtu_retire_cnt != 2'b00) begin
        $display("      --- T%0d retire_cnt=%b (vld=%b%b%b) ---", cycles,
                 dut.rtu_retire_cnt, dut.dbg_commit_vld2, dut.dbg_commit_vld1,
                 dut.dbg_commit_vld0);
        if (dut.dbg_commit_vld0)
          $display("      ret pc=%08x ena=%b x%0d<=%08x",
                   dut.dbg_commit_pc0, dut.dbg_commit_ena0,
                   dut.dbg_commit_reg0, dut.dbg_commit_value0);
        if (dut.dbg_commit_vld1)
          $display("      ret pc=%08x ena=%b x%0d<=%08x",
                   dut.dbg_commit_pc1, dut.dbg_commit_ena1,
                   dut.dbg_commit_reg1, dut.dbg_commit_value1);
        if (dut.dbg_commit_vld2)
          $display("      ret pc=%08x ena=%b x%0d<=%08x",
                   dut.dbg_commit_pc2, dut.dbg_commit_ena2,
                   dut.dbg_commit_reg2, dut.dbg_commit_value2);
      end

      // ---- a0 (x10): 用例把自检结果压在这里 ----
      if (dut.dbg_commit_vld0 && dut.dbg_commit_ena0 && dut.dbg_commit_reg0 == 5'd10) begin
        a0_val = dut.dbg_commit_value0; a0_hits = a0_hits + 1;
      end
      if (dut.dbg_commit_vld1 && dut.dbg_commit_ena1 && dut.dbg_commit_reg1 == 5'd10) begin
        a0_val = dut.dbg_commit_value1; a0_hits = a0_hits + 1;
      end
      if (dut.dbg_commit_vld2 && dut.dbg_commit_ena2 && dut.dbg_commit_reg2 == 5'd10) begin
        a0_val = dut.dbg_commit_value2; a0_hits = a0_hits + 1;
      end

      // ---- x17 = 93: 用例走到退出序列了 ----
      if (dut.dbg_commit_vld0 && dut.dbg_commit_ena0 && dut.dbg_commit_reg0 == 5'd17
          && dut.dbg_commit_value0 == 32'd93) exit_seen = 1;
      if (dut.dbg_commit_vld1 && dut.dbg_commit_ena1 && dut.dbg_commit_reg1 == 5'd17
          && dut.dbg_commit_value1 == 32'd93) exit_seen = 1;
      if (dut.dbg_commit_vld2 && dut.dbg_commit_ena2 && dut.dbg_commit_reg2 == 5'd17
          && dut.dbg_commit_value2 == 32'd93) exit_seen = 1;

      if (dut.rtu_trap_vld) trap_seen = trap_seen + 1;
    end
  end

  // 失速诊断: 一直不退休时打印"卡在哪一级"
  integer last_retired = 0;
  integer ar_hs = 0;                     // AXI 读地址握手次数 (和 R 拍数分开数)
  always @(posedge clk) if (!rst && biu_pad_arvalid && pad_biu_arready) ar_hs = ar_hs + 1;

  // 逐拍追踪复位刚放开那一段 —— 找 X 是哪一拍、从哪冒出来的。
  // 默认关 (输出太吵), 加 `A910_SIM_ARGS=+TRACE_EARLY` 打开。第一次给这个核找
  // X 就是靠它: 一眼看到 T24 那拍 `disp=x11` —— 槽 2 的发射有效位是 X。
  wire trace_early = $test$plusargs("TRACE_EARLY");
  always @(posedge clk) begin
    if (!rst && trace_early && cycles >= 20 && cycles <= 40) begin
      $display("      T%0d init=%b | IFU inst=%b%b%b | disp=%b%b%b | occ=%0d st_q=%b ret=%b",
               cycles, dut.ifu_init_done,
               dut.idu_inst2_vld, dut.idu_inst1_vld, dut.idu_inst0_vld,
               dut.idu_rtu_disp2_vld, dut.idu_rtu_disp1_vld, dut.idu_rtu_disp0_vld,
               dut.u_rtu.u_rob.occ, dut.u_rtu.u_flush.st_q, dut.rtu_retire_cnt);
      $display("           alloc_vld(IDU)=%b%b%b | req=%b | tap_vld=%b%b%b",
               dut.idu_rtu_ir_preg2_alloc_vld, dut.idu_rtu_ir_preg1_alloc_vld,
               dut.idu_rtu_ir_preg0_alloc_vld, dut.ren_preg_req,
               dut.rtu_idu_alloc_preg2_vld, dut.rtu_idu_alloc_preg1_vld,
               dut.rtu_idu_alloc_preg0_vld);
      $display("           IDU: is_stall=%b ir_stall=%b dis_stall=%b | rob_full=%b",
               dut.u_ct_idu_top.ctrl_is_stall, dut.u_ct_idu_top.ctrl_ir_stall,
               dut.u_ct_idu_top.ctrl_dp_is_dis_stall, dut.u_ct_idu_top.rtu_idu_rob_full);
      $display("           IBUF cnt=%0d empty=%b push_mask=%b can_push=%b init_all=%b accept_num=%b",
               dut.u_rv32ifu2_top.u_ibuf.cnt_q, dut.u_rv32ifu2_top.u_ibuf.empty,
               dut.u_rv32ifu2_top.push_mask, dut.u_rv32ifu2_top.can_push,
               dut.u_rv32ifu2_top.init_all, dut.idu_accept_num);
      $display("           IBUF out_vld=%b out_data0[31:0]=%08x",
               dut.u_rv32ifu2_top.ib_vld, dut.u_rv32ifu2_top.ib_out0[31:0]);
    end
  end

  // init 之后那一段也要逐拍看: 第一次真正派遣是第二个可能的污染点
  always @(posedge clk) begin
    if (!rst && trace_early && cycles >= 84 && cycles <= 100) begin
      $display("      T%0d | IFU inst=%b%b%b cnt=%0d av=%b | IDreg=%b%b%b | disp=%b%b%b",
               cycles, dut.idu_inst2_vld, dut.idu_inst1_vld, dut.idu_inst0_vld,
               dut.u_rv32ifu2_top.u_ibuf.cnt_q, dut.idu_accept_num,
               dut.u_ct_idu_top.id_inst2_vld, dut.u_ct_idu_top.id_inst1_vld,
               dut.u_ct_idu_top.id_inst0_vld,
               dut.idu_rtu_disp2_vld, dut.idu_rtu_disp1_vld, dut.idu_rtu_disp0_vld);
      // ⚠️ 原来这里是 `ctrl_ir_inst2_vld` —— 那根在 IDU 侧是悬空的, 同事 7c54bec
      //    已把它换成 `ctrl_rt_inst2_vld` (ir_ctrl 里 `ir_inst2_vld` 的导出)。
      $display("           ctrl_rt_inst2_vld=%b (内部ir_inst2_vld=%b) pd2=%b pre_pipedown2=%b ir_stall=%b ir_pipedown=%b",
               dut.u_ct_idu_top.ctrl_rt_inst2_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_inst2_vld,
               dut.u_ct_idu_top.ctrl_xx_is_inst0_sel[0],
               dut.u_ct_idu_top.ctrl_ir_pre_dis_pipedown2,
               dut.u_ct_idu_top.ctrl_ir_stall,
               dut.u_ct_idu_top.ctrl_ir_pipedown);
      $display("           五项: biq=%b aiq=%b lsiq=%b mult=%b div=%b ⇒ type_stall=%b",
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_3_biq_inst,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_3_aiq_inst,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_3_lsiq_inst,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_3_mult_inst,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_3_div_inst,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_type_stall_pipedown2);
      // IFU 取指请求链: refill_req = ~q_hit & ~refill_busy & init_all & ~redirect
      //                 redirect    = rtu_chgflw_vld | rtu_flush | iu_red_vld
      $display("           IFU取指: refill_req=%b q_hit=%b refill_busy=%b init_all=%b redirect=%b",
               dut.u_rv32ifu2_top.refill_req, dut.u_rv32ifu2_top.q_hit,
               dut.u_rv32ifu2_top.refill_busy, dut.u_rv32ifu2_top.init_all,
               dut.u_rv32ifu2_top.redirect);
      $display("                    redirect三源: rtu_chgflw=%b rtu_flush=%b iu_red_vld=%b",
               dut.u_rv32ifu2_top.rtu_chgflw_vld, dut.u_rv32ifu2_top.rtu_flush,
               dut.u_rv32ifu2_top.iu_red_vld);
      // 派发记录 (IDU → RTU): flags 是从 dp_is_dis_inst*_data 的指令字译出来的
      $display("           派发记录: flags0=%b pc0=%08x rf_we0=%b | is_dis_data0[31:0]=%08x",
               dut.idu_rtu_disp0_flags, dut.idu_rtu_disp0_pc, dut.idu_rtu_disp0_rf_we,
               dut.u_ct_idu_top.dp_is_dis_inst0_data[31:0]);
      $display("           IFUdata0=%08x IDdata0=%08x type_stall_pd2=%b",
               dut.idu_inst0_data[31:0],
               dut.u_ct_idu_top.dp_id_pipedown_inst0_data[31:0],
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_type_stall_pipedown2);
    end
  end

  // 早期也要打: 只打 2000 的倍数的话, 分不清 X 是"复位就没干净"还是"跑起来才脏的"
  wire early = 1'b0;
  always @(posedge clk) begin
    if (!rst && trace_on && (early || (cycles % 500 == 0)) && (cycles > 0)) begin
      $display("      ... cycles=%0d retired=%0d (新增 %0d) rst_b=%b", cycles, retired,
               retired - last_retired, dut.rst_b);
      $display("          IFU: init=%b pc_q=%08x  -> IDU: inst_vld=%b%b%b accept_num=%b",
               dut.ifu_init_done, dut.u_rv32ifu2_top.u_icache.q_pc_q,
               dut.idu_inst2_vld, dut.idu_inst1_vld, dut.idu_inst0_vld, dut.idu_accept_num);
      $display("          RTU: occ=%0d retire_cnt=%b  flush: yy_xx=%b ifu=%b chgflw=%b",
               dut.u_rtu.u_rob.occ, dut.rtu_retire_cnt,
               dut.rtu_yy_xx_flush, dut.rtu_ifu_flush, dut.rtu_ifu_chgflw_vld);
      $display("          AXI: ar_hs=%0d r_hs=%0d | arvalid=%b arready=%b rvalid=%b rready=%b",
               ar_hs, u_mem.rd_hs_cnt, biu_pad_arvalid, pad_biu_arready,
               pad_biu_rvalid, biu_pad_rready);
      $display("          EXPT: iu=%b ld=%b st=%b | RTU: trap_hit=%b flush_trig=%b src=%b st_q=%b",
               dut.expt_iu_vld, dut.expt_ld_vld, dut.expt_st_vld,
               dut.u_rtu.u_commit.trap_hit, dut.u_rtu.flush_trig,
               dut.u_rtu.flush_src, dut.u_rtu.u_flush.st_q);
      $display("          DISP: disp0=%b disp1=%b disp2=%b | cmplt4=%b cmplt3=%b commit0=%b",
               dut.idu_rtu_disp0_vld, dut.idu_rtu_disp1_vld, dut.idu_rtu_disp2_vld,
               dut.cmplt_vld4, dut.cmplt_vld3, dut.rtu_yy_xx_commit0);
      $display("          flush_trig 的三个可疑源: mret_hit=%b replay_hit=%b mispred_hit=%b",
               dut.u_rtu.u_commit.mret_hit, dut.u_rtu.u_commit.replay_hit,
               dut.u_rtu.u_commit.mispred_hit);
      $display("          源: lsu_replay_vld=%b resolve_vld=%b resolve_mispred=%b w0_mret=%b",
               dut.lsu_replay_vld, dut.resolve_vld, dut.resolve_mispred,
               dut.u_rtu.u_commit.w0_mret);
      last_retired = retired;
    end
  end

  // -------------------------------------------------------------------------
  // 【不变量】`idu_accept_num` 只能取 0 / 2 / 3
  // -------------------------------------------------------------------------
  // 为什么: `ct_idu_top.sv:332` 的编码 `{inst2_ready|inst0_ready, inst2_ready}`
  // 要给出 {0,2,3}, 依赖一条不变量 `inst2_ready ⇒ inst0_ready`; 2026-10-11 之前
  // `ct_idu_id_ctrl.sv` 里写成 `!stall | !pd2` 把它顶穿 ⇒ 冒出了 1 之外的错误组合。
  // (那次实测的症状是 pipedown2 模式报 3 而实际只吃 2 ⇒ IFU 多弹一条 = 丢指令。)
  reg seen0 = 0, seen2 = 0, seen3 = 0;
  always @(posedge clk) if (!rst) begin
    if (dut.idu_accept_num === 2'd0) seen0 = 1;
    if (dut.idu_accept_num === 2'd2) seen2 = 1;
    if (dut.idu_accept_num === 2'd3) seen3 = 1;
    // 当场炸, 不等终局 —— 这样 PASS 分支也拦得住
    if (dut.idu_accept_num === 2'd1) begin
      $display("  ❌ [INVARIANT] idu_accept_num = 1 —— `inst2_ready ⇒ inst0_ready` 不成立");
      $display("     见 ct_idu_id_ctrl.sv 里 `idu_ifu_inst2_ready` 的注释");
      $fatal(1, "accept_num invariant violated");
    end
  end

  // -------------------------------------------------------------------------
  // 主流程
  // -------------------------------------------------------------------------
  integer i;

`ifdef FSDB
  // FSDB 波形 dump
  reg [8*100:1] wave_file;
  initial begin
    if ($value$plusargs("WAVE=%s", wave_file)) begin
      $sformat(wave_file, "waveform/%0s.fsdb", wave_file);
    end else begin
      wave_file = "waveform/a910_smoke.fsdb";
    end
    $fsdbDumpfile(wave_file);
    $fsdbDumpvars(0, tb_a910_smoke);
    $display("  📊 FSDB 波形已启用: %0s", wave_file);
  end
`endif

  initial begin
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 200000;

    $display("");
    $display("==================================================");
    $display("  A910_cpu 最小冒烟台  (MAX_CYCLES=%0d)", max_cycles);
    $display("==================================================");

    rst = 1;
    repeat (20) @(posedge clk);
    rst = 0;
    $display("  复位释放 (20 拍)");

    // 等 IFU 把 icache 灌好 —— 复位后约 32 拍
    i = 0;
    while (dut.ifu_init_done !== 1'b1 && i < 500) begin
      @(posedge clk); i = i + 1;
    end
    if (dut.ifu_init_done !== 1'b1) begin
      $display("  ❌ 500 拍内 ifu_init_done 没拉起来 —— IFU 取指初始化就没过, 后面不用看了");
      $fatal(1, "ifu init timeout");
    end
    $display("  ✅ IFU 初始化完成 (cycles=%0d)", cycles);
    trace_on = 1;

    // 跑到退出序列, 或超时
    while (!exit_seen && cycles < max_cycles) @(posedge clk);

    if (exit_seen) begin
      // 退出序列已看到, 再放几拍让后面的退休排空
      repeat (20) @(posedge clk);
      $display("");
      $display("==================================================");
      if (a0_val == 0) begin
        $display("  === A910 SMOKE: PASS ===");
        $display("  a0(x10) = 0 (写了 %0d 次), 累计退休 %0d 条, 用了 %0d 拍",
                 a0_hits, retired, cycles);
        $display("==================================================");
        $finish;
      end
      else begin
        $display("  === A910 SMOKE: FAIL ===");
        $display("  a0(x10) = %0d (0x%08x), 写了 %0d 次, 累计退休 %0d 条",
                 a0_val, a0_val, a0_hits, retired);
        if (a0_val < 0)
          $display("  ⚠️ a0 从来没被写过 —— 用例没跑到那条 sub, 或 IDU 把它丢了");
        else
          $display("  ⚠️ a0 != 0 —— 用例自检没过, 乘法/除法结果不对");
        $display("==================================================");
        $fatal(1, "a910 smoke failed");
      end
    end
    else begin
      $display("");
      $display("==================================================");
      $display("  === A910 SMOKE: FAIL (超时) ===");
      $display("  %0d 拍内没看到退出序列 (x17=93)", max_cycles);
      $display("  累计退休 %0d 条, IFU 初始化=%b, ROB 占用=%0d, ICache PC=%08x, AXI 读握手=%0d 次",
               retired, dut.ifu_init_done, dut.u_rtu.u_rob.occ,
               dut.u_rv32ifu2_top.u_icache.q_pc_q, u_mem.rd_hs_cnt);
      if (retired == 0)
        $display("  ⚠️ 一条都没退休 —— 卡在取指/派遣, 不是执行的问题");
      else
        $display("  ⚠️ 退休了 %0d 条但不往下走 —— 看上面最后几条的 PC", retired);
      $display("==================================================");
      $display("  idu_accept_num 取值集合: 0=%b 2=%b 3=%b (1 应当从不出现)",
               seen0, seen2, seen3);
    end

    // ⚠️ 必须 $fatal 不能 $finish: $finish 的退出码是 0, make 会把失败当通过。
    //    能走到这里一定是超时 —— PASS 分支已经在上面 $finish 返回了。
    $fatal(1, "a910 smoke timeout");
  end

endmodule
