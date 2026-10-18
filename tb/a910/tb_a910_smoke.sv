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
    .bvalid  (pad_biu_bvalid),   .bready  (biu_pad_bready)
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
    .pad_biu_bvalid (pad_biu_bvalid), .biu_pad_bready (biu_pad_bready)
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
    // 2026-10-17 S9: 删掉 cmplt 的 force —— 否则 bridge 生成的完成脉冲
    // (cmplt_vld1 = core ROB 完成链 / cmplt_vld2 = vset) 永远传不到 RTU。
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
  // [RVV_DBG] 向量 L/S uop 为什么进不了 fill —— 只打前 40 次
  //   (2026-10-18: rvv_lsu/逐指令 sweep 都在第一条 vle 上卡死, 用这个定位)
  // -------------------------------------------------------------------------
  integer rvv_dbg_cnt = 0;
  integer d_vecq=0, d_acc=0, d_rs=0, d_lsu=0, d_core=0;
  always @(posedge clk) if (!rst && $test$plusargs("RVV_DBG")) begin
    if (dut.u_ct_idu_top.u_ct_idu_vecq.vecq_xx_issue_en && d_vecq<8) begin
      d_vecq = d_vecq + 1;
      $display("[RVVDBG] T%0t VIQ issue iid=%0d op=%0d bits=%h", $time,
               dut.idu_vec_inst_iid, dut.idu_vec_inst_opcode,
               dut.idu_vec_inst_bits);
    end
    if (dut.u_rvv_a910_bridge.accept && d_acc<8) begin
      d_acc = d_acc + 1;
      $display("[RVVDBG] T%0t bridge accept iid=%0d", $time,
               dut.idu_vec_inst_iid);
    end
    if (dut.u_rvv_a910_bridge.u_rvv_core.backend.rs_valid_dp2lsu[0] && d_rs<8) begin
      d_rs = d_rs + 1;
      $display("[RVVDBG] T%0t LSU RS push iid=%0d", $time,
               dut.u_rvv_a910_bridge.u_rvv_core.backend.rs_dp2lsu[0].rob_tag);
    end
    if (dut.u_rvv_a910_bridge.u_rvv_core.backend.uop_lsu_valid_rvv2lsu[0] && d_lsu<8) begin
      d_lsu = d_lsu + 1;
      $display("[RVVDBG] T%0t LSU RS out iid=%0d", $time,
               dut.u_rvv_a910_bridge.u_rvv_core.backend.uop_lsu_rvv2lsu[0].rob_tag);
    end
    if (dut.rvv_lsu_uop_valid && d_core<8) begin
      d_core = d_core + 1;
      $display("[RVVDBG] T%0t bridge LSU uop valid iid=%0d lsid=%0d ready=%b",
               $time, dut.rvv_lsu_uop.rob_tag, dut.rvv_lsu_uop.lsid,
               dut.rvv_lsu_uop_ready);
    end
    // 卡住之后的周期状态: fill ctx / LSU 请求-响应
    if (cycles > 3000 && cycles < 20000 && (cycles % 1000) == 0) begin
      $display("[RVVDBG] T%0t FILL vld=%b ld=%b pend=%h outs=%0d infl=%h respv=%b respR=%b | reqv=%b reqR=%b done=%b rspv=%b",
        $time,
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_vld,
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_load[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_pending[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_outs[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_inflight[0],
        dut.u_ct_idu_top.u_vec_ls_fill.rvv_lsu_resp_valid,
        dut.u_ct_idu_top.u_vec_ls_fill.rvv_lsu_resp_ready,
        dut.vec_ls_req_valid, dut.vec_ls_req_ready,
        dut.vec_ls_req_done_vld, dut.vec_ls_rsp_valid);
      $display("[RVVDBG]        ST old_vld=%b old_ctx=%0d lsiq_old=%b can=%b%b%b%b seq=%0d/%0d/%0d/%0d lsid=%0d/%0d/%0d/%0d samiid=%0d/%0d/%0d/%0d",
        dut.u_ct_idu_top.u_vec_ls_fill.st_old_vld,
        dut.u_ct_idu_top.u_vec_ls_fill.st_old_ctx,
        dut.u_ct_idu_top.lsiq_vec_old,
        dut.u_ct_idu_top.u_vec_ls_fill.st_req_can[0],
        dut.u_ct_idu_top.u_vec_ls_fill.st_req_can[1],
        dut.u_ct_idu_top.u_vec_ls_fill.st_req_can[2],
        dut.u_ct_idu_top.u_vec_ls_fill.st_req_can[3],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_seq[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_seq[1],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_seq[2],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_seq[3],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_lsid[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_lsid[1],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_lsid[2],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_lsid[3],
        dut.u_ct_idu_top.u_vec_ls_fill.same_iid_cnt[0],
        dut.u_ct_idu_top.u_vec_ls_fill.same_iid_cnt[1],
        dut.u_ct_idu_top.u_vec_ls_fill.same_iid_cnt[2],
        dut.u_ct_idu_top.u_vec_ls_fill.same_iid_cnt[3]);
      $display("[RVVDBG]        LSU ld_da_vec=%b rspv=%b fid=%0d bytes=%h done=%b miss=%b mshr=%b | lq_ok=%b rb_ok=%b",
        dut.u_lsu_top.ld_da_vec, dut.u_lsu_top.ld_da_vec_rsp_vld,
        dut.u_lsu_top.ld_da_fill_id, dut.u_lsu_top.ld_da_bytes_vld,
        dut.u_lsu_top.ld_da_vec_done, dut.u_lsu_top.ld_da_vec_miss,
        dut.u_lsu_top.ld_da_vec_mshr_created,
        dut.u_lsu_top.lsu_idu_lq_not_full, dut.u_lsu_top.lsu_idu_rb_not_full);
    end
  end
  always @(posedge clk) begin
    if (!rst && $test$plusargs("RVV_DBG") &&
        dut.rvv_lsu_uop_valid && !dut.rvv_lsu_uop_ready && rvv_dbg_cnt < 40) begin
      rvv_dbg_cnt = rvv_dbg_cnt + 1;
      $display("[RVVDBG] T%0t uop iid=%0d lsid=%0d st=%b | anc_vld=%b anc_iid=%0d anc_st=%b | anc_ok=%b ready=%b",
        $time, dut.rvv_lsu_uop.rob_tag, dut.rvv_lsu_uop.lsid,
        dut.rvv_lsu_uop.lsu_is_store,
        dut.u_ct_idu_top.u_vec_ls_fill.anc_vld[dut.rvv_lsu_uop.lsid],
        dut.u_ct_idu_top.u_vec_ls_fill.anc_iid[dut.rvv_lsu_uop.lsid],
        dut.u_ct_idu_top.u_vec_ls_fill.anc_store[dut.rvv_lsu_uop.lsid],
        dut.u_ct_idu_top.u_vec_ls_fill.uop_anc_ok,
        dut.rvv_lsu_uop_ready);
    end
  end

  // ---- RVV load DA event probe ----
  integer e_da=0,e_done=0,e_rsp=0,e_mshr=0,e_miss=0,e_rbrsp=0,e_rbcr=0,e_rbfull=0,e_dcv=0;
  always @(posedge clk) if (!rst && $test$plusargs("RVV_DBG")) begin
    if (dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld && e_da<20) begin
      e_da=e_da+1;
      $display("[RVVDBG] T%0t DA inst_vld vec=%b nop=%b hit=%b data=%b rbcr=%b rbfull=%b rbhit=%b fid=%0d",
        $time, dut.u_lsu_top.ld_da_vec, dut.u_lsu_top.u_lsu_ld_da.ld_da_vec_nop_q,
        dut.u_lsu_top.u_lsu_ld_da.ld_da_dcache_hit, dut.u_lsu_top.u_lsu_ld_da.ld_da_data_vld,
        dut.u_lsu_top.ld_da_rb_create_vld, dut.u_lsu_top.rb_ld_da_full,
        dut.u_lsu_top.rb_ld_da_hit_idx, dut.u_lsu_top.ld_da_fill_id);
    end
    if (dut.u_lsu_top.ld_da_vec && e_dcv<20) begin
      e_dcv=e_dcv+1;
      $display("[RVVDBG] T%0t DA vec_level inst_vld=%b restart=%b done=%b rsp=%b mshr=%b miss=%b",
        $time, dut.u_lsu_top.u_lsu_ld_da.ld_da_inst_vld, dut.u_lsu_top.u_lsu_ld_da.ld_da_restart_vld,
        dut.u_lsu_top.ld_da_vec_done, dut.u_lsu_top.ld_da_vec_rsp_vld,
        dut.u_lsu_top.ld_da_vec_mshr_created, dut.u_lsu_top.ld_da_vec_miss);
    end
    if (dut.u_lsu_top.ld_da_vec_done && e_done<20) begin
      e_done=e_done+1; $display("[RVVDBG] T%0t DA vec_done fid=%0d", $time, dut.u_lsu_top.ld_da_fill_id);
    end
    if (dut.u_lsu_top.ld_da_vec_rsp_vld && e_rsp<20) begin
      e_rsp=e_rsp+1; $display("[RVVDBG] T%0t DA vec_rsp fid=%0d bytes=%h", $time, dut.u_lsu_top.ld_da_fill_id, dut.u_lsu_top.ld_da_bytes_vld);
    end
    if (dut.u_lsu_top.ld_da_vec_mshr_created && e_mshr<20) begin
      e_mshr=e_mshr+1; $display("[RVVDBG] T%0t DA vec_mshr_created fid=%0d", $time, dut.u_lsu_top.ld_da_fill_id);
    end
    if (dut.u_lsu_top.ld_da_vec_miss && e_miss<20) begin
      e_miss=e_miss+1; $display("[RVVDBG] T%0t DA vec_miss fid=%0d", $time, dut.u_lsu_top.ld_da_fill_id);
    end
    if (dut.u_lsu_top.rb_vec_rsp_vld && e_rbrsp<20) begin
      e_rbrsp=e_rbrsp+1; $display("[RVVDBG] T%0t RB vec_rsp fid=%0d bytes=%h", $time, dut.u_lsu_top.rb_vec_rsp_fill_id, dut.u_lsu_top.rb_vec_rsp_bytes_vld);
    end
    if (dut.u_lsu_top.ld_da_rb_create_vld && e_rbcr<20) begin
      e_rbcr=e_rbcr+1; $display("[RVVDBG] T%0t rb_create fid=%0d", $time, dut.u_lsu_top.ld_da_fill_id);
    end
    if (dut.u_lsu_top.rb_ld_da_full && e_rbfull<5) begin
      e_rbfull=e_rbfull+1; $display("[RVVDBG] T%0t rb_full", $time);
    end
  end

  // ---- RVV store fill/anchor event probe ----
  logic [7:0]  prev_lsiq_vec_old = 8'h0;
  logic [7:0]  prev_anc_vld = 8'h0;
  always @(posedge clk) if (!rst && $test$plusargs("RVV_DBG")) begin
    if (dut.rvv_lsu_uop_valid && dut.rvv_lsu_uop_ready &&
        dut.rvv_lsu_uop.lsu_is_store) begin
      $display("[RVVDBG] T%0t ST accept iid=%0d lsid=%0d fill=%0d mask=%h last_uop=%b", $time,
        dut.rvv_lsu_uop.rob_tag, dut.rvv_lsu_uop.lsid,
        dut.u_ct_idu_top.u_vec_ls_fill.seq_cnt,
        dut.u_ct_idu_top.u_vec_ls_fill.uop_mask,
        dut.rvv_lsu_uop.last_uop_valid);
    end
    if (dut.u_ct_idu_top.u_vec_ls_fill.issue_fire &&
        dut.u_ct_idu_top.u_vec_ls_fill.issue_store) begin
      $display("[RVVDBG] T%0t ST issue ctx=%0d mask=%h last=%b addr=%h", $time,
        dut.u_ct_idu_top.u_vec_ls_fill.issue_ctx,
        dut.u_ct_idu_top.u_vec_ls_fill.issue_mask,
        dut.u_ct_idu_top.u_vec_ls_fill.issue_last,
        dut.u_ct_idu_top.u_vec_ls_fill.issue_addr);
    end
    if (dut.u_ct_idu_top.u_vec_ls_fill.done_hit &&
        dut.u_ct_idu_top.u_vec_ls_fill.done_req_vld) begin
      $display("[RVVDBG] T%0t ST done id=%0d reqstore=%b", $time,
        dut.u_ct_idu_top.u_vec_ls_fill.done_id,
        dut.u_ct_idu_top.u_vec_ls_fill.req_store[dut.u_ct_idu_top.u_vec_ls_fill.done_id]);
    end
    if (dut.u_lsu_top.u_lsu_st_da.st_da_vec_done)
      $display("[RVVDBG] T%0t ST VEC DA done last=%b lsid=%h fid=%0d",
        $time, dut.u_lsu_top.u_lsu_st_da.st_da_last,
        dut.u_lsu_top.u_lsu_st_da.st_da_lsid,
        dut.u_lsu_top.u_lsu_st_da.st_da_fill_id);
    if (dut.lsu_idu_lsiq_pop1_vld)
      $display("[RVVDBG] T%0t ST DA pop vld entry=%h last=%b lsid=%h", $time, dut.u_lsu_top.st_da_idu_pop_entry, dut.u_lsu_top.u_lsu_st_da.st_da_last, dut.u_lsu_top.u_lsu_st_da.st_da_lsid);
    if (dut.lsu_idu_lsiq_pop0_vld)
      $display("[RVVDBG] LD DA pop vld entry=%h", dut.u_lsu_top.ld_da_idu_pop_entry);
    if (dut.lsu_idu_lsiq_pop_entry != 8'h0)
      $display("[RVVDBG] LSIQ pop entry=%h", dut.lsu_idu_lsiq_pop_entry);
    if (cycles > 1000 && (cycles % 500) == 0)
      $display("[RVVDBG] T%0t E2 st=%b ld=%b frz=%b rdy=%b raw=%b old=%b | ready=%b p4rdy=%b p4iss=%b rf4=%b | op=%h",
        $time,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.store,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.load,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.frz,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.x_rdy,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.x_raw_rdy,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.old,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_ready[2],
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_pipe4_entry_ready[2],
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_dp_pipe4_issue_entry[2],
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_rf_pipe4_issue_en,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.opcode);
    if (dut.u_lsu_top.st_ag_dc_inst_vld)
      $display("[RVVDBG] T%0t ST AG iid=%0d old=%b addr=%h",
        $time, dut.u_lsu_top.st_ag_iid, dut.u_lsu_top.st_ag_old,
        dut.u_lsu_top.st_ag_dc_addr0);
    if (dut.u_lsu_top.st_dc_da_inst_vld)
      $display("[RVVDBG] T%0t ST DC iid=%0d vec=%b sqfull=%b",
        $time, dut.u_lsu_top.st_dc_iid, dut.u_lsu_top.st_dc_vec,
        !dut.lsu_idu_sq_not_full);
    if (dut.u_lsu_top.st_da_inst_vld)
      $display("[RVVDBG] T%0t ST DA iid=%0d vec=%b restart=%b sqfull=%b",
        $time, dut.u_lsu_top.st_da_iid, dut.u_lsu_top.st_da_vec,
        dut.u_lsu_top.u_lsu_st_da.st_da_restart_vld, !dut.lsu_idu_sq_not_full);
    if (dut.u_lsu_top.u_lsu_st_ag.st_ag_dcache_stall_req ||
        dut.u_lsu_top.u_lsu_st_ag.st_ag_stall_vld ||
        dut.u_lsu_top.u_lsu_st_ag.st_ag_stall_mask ||
        (dut.u_lsu_top.st_ag_stall_restart_entry != 8'h0))
      $display("[RVVDBG] T%0t STALL req=%b vld=%b mask=%b re=%h | ag_iid=%0d ag_lsid=%h inst=%b | rf_sel=%b rf_iid=%0d lch=%h | imme_wk=%h",
        $time,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_dcache_stall_req,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_stall_vld,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_stall_mask,
        dut.u_lsu_top.st_ag_stall_restart_entry,
        dut.u_lsu_top.st_ag_iid,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_lsid,
        dut.u_lsu_top.u_lsu_st_ag.st_ag_inst_vld,
        dut.u_lsu_top.idu_lsu_st_sel,
        dut.u_lsu_top.idu_lsu_st_iid,
        dut.u_lsu_top.idu_lsu_st_lch_entry,
        dut.u_lsu_top.lsu_idu_imme_wakeup);
    if (dut.u_lsu_top.u_lsu_st_dc.st_dc_inst_vld &&
        dut.u_lsu_top.u_lsu_st_dc.st_dc_iid == 7'd44)
      $display("[RVVDBG] T%0t DC44 inst=1 restart=%b sqfullvld=%b old=%b specfail=%b expt=%b vec=%b sqfull=%b",
        $time,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_restart_vld,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_sq_full_vld,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_old,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_spec_fail,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_expt,
        dut.u_lsu_top.u_lsu_st_dc.st_dc_vec,
        !dut.lsu_idu_sq_not_full);
    if (dut.u_ct_idu_top.u_vec_ls_fill.ld_rsp_hit)
      $display("[RVVDBG] T%0t FILL ld_rsp_hit rspid=%0d reqvld=%b reqctx=%0d rspv=%b",
        $time, dut.u_ct_idu_top.u_vec_ls_fill.rsp_id,
        dut.u_ct_idu_top.u_vec_ls_fill.req_vld[dut.u_ct_idu_top.u_vec_ls_fill.rsp_id],
        dut.u_ct_idu_top.u_vec_ls_fill.req_ctx[dut.u_ct_idu_top.u_vec_ls_fill.rsp_id],
        dut.vec_ls_rsp_valid);
    if (cycles > 1000 && (cycles % 500) == 0)
      $display("[RVVDBG] T%0t CTX vld=%b ld=%b pend=%h/%h/%h/%h outs=%0d/%0d/%0d/%0d rr=%b%b%b%b respv=%b",
        $time,
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_vld,
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_load[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_pending[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_pending[1],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_pending[2],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_pending[3],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_outs[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_outs[1],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_outs[2],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_outs[3],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_resp_ready[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_resp_ready[1],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_resp_ready[2],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_resp_ready[3],
        dut.u_ct_idu_top.u_vec_ls_fill.rvv_lsu_resp_valid);
    if (dut.u_lsu_top.rb_vec_rsp_vld)
      $display("[RVVDBG] T%0t RB rspvld=%b grnt=%b fid=%0d | vec=%b rsp=%b fd=%0d/%0d/%0d/%0d grntx=%b ptr=%b st0=%0d grnt0=%b",
        $time,
        dut.u_lsu_top.rb_vec_rsp_vld, dut.u_lsu_top.rb_vec_rsp_grnt,
        dut.u_lsu_top.rb_vec_rsp_fill_id,
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vec,
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vec_rsp,
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vec_fill_id[0],
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vec_fill_id[1],
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vec_fill_id[2],
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vec_fill_id[3],
        dut.u_lsu_top.u_lsu_mshr.rb_entry_vec_rsp_grnt,
        dut.u_lsu_top.u_lsu_mshr.rb_vec_rsp_ptr,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_state,
        dut.u_lsu_top.u_lsu_mshr.gen_mshr_entry[0].u_mshr_entry.rb_entry_vec_rsp_grnt_x);
    if (dut.rtu_yy_xx_flush)
      $display("[RVVDBG] T%0t RTU FLUSH", $time);
    if (cycles > 1000 && (cycles % 500) == 0)
      $display("[RVVDBG] T%0t LSIQ vld=%h vec=%h old=%h | e0 age=%b iid=%0d | e1 age=%b iid=%0d | e2 age=%b iid=%0d | e3 age=%b iid=%0d",
        $time,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_vld,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_vec,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_vec_old,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.agevec_all,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry0.iid,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.agevec_all,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry1.iid,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.agevec_all,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry2.iid,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.agevec_all,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.u_ct_idu_is_lsiq_entry3.iid);
    if (dut.u_ct_idu_top.lsiq_vec_old != prev_lsiq_vec_old) begin
      prev_lsiq_vec_old <= dut.u_ct_idu_top.lsiq_vec_old;
      $display("[RVVDBG] vec_old %b -> %b (entries vld=%h vec=%h)",
        prev_lsiq_vec_old, dut.u_ct_idu_top.lsiq_vec_old,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_vld,
        dut.u_ct_idu_top.x_ct_idu_is_lsiq.lsiq_entry_vec);
    end
    if (dut.u_ct_idu_top.u_vec_ls_fill.anc_vld != prev_anc_vld) begin
      prev_anc_vld <= dut.u_ct_idu_top.u_vec_ls_fill.anc_vld;
      $display("[RVVDBG] anc_vld %b -> %b", prev_anc_vld,
        dut.u_ct_idu_top.u_vec_ls_fill.anc_vld);
    end
  end

  // -------------------------------------------------------------------------
  // 退休监视 (全部走顶层已命名的观察口, 层次化引用, 零 RTL 改动)
  // -------------------------------------------------------------------------
  integer retired  = 0;              // 累计退休条数 (rtu_retire_cnt 是**当拍条数**, 要自己累)
  integer a0_val   = -1;             // 最后一次看到写 x10 的值 (-1 = 从没写过)
  integer a0_hits  = 0;
  integer exit_seen = 0;             // 见到 x17 = 93 (用例的退出序列标记)
  integer trap_seen = 0;
  integer trace_on  = 0;

  // -------------------------------------------------------------------------
  // 【RVV 逐指令 sweep 回读】+RVV_SWEEP 时启用, 平时完全不影响本台
  //
  //   用例把 “当前 case id” 写进 progress 字, 把每条指令的自检结果 (0=pass,
  //   1=fail, 0xffffffff=还没跑到) 写进 status 数组。本台在 PASS / 超时两条
  //   收尾路径上把它们从 AXI 从机内存里读出来打印, 运行器按 manifest 映射成
  //   逐指令表。超时能看到 progress ⇒ 直接定位“卡在哪条指令”。
  // -------------------------------------------------------------------------
  bit          rvv_sweep_en = 1'b0;
  integer      rvv_progress_addr = 0;
  integer      rvv_status_addr   = 0;
  integer      rvv_status_n      = 0;
  integer      rvv_phase_addr    = 0;

  // AXI 从机: reg [127:0] mem[0:4095], 索引 addr[15:4], 字在块内 [3:2]
  function automatic [31:0] rvv_mem_word(input integer a);
    rvv_mem_word = u_mem.mem[a[15:4]][a[3:2]*32 +: 32];
  endfunction

  task automatic rvv_dump;
    integer k;
    integer res_addr, exp_addr;
    begin
      if (!rvv_sweep_en) disable rvv_dump;
      $display("RVV_PROGRESS %08x", rvv_mem_word(rvv_progress_addr));
      $display("RVV_PHASE %08x", rvv_mem_word(rvv_phase_addr));
      for (k = 0; k < rvv_status_n; k = k + 1)
        $display("RVV_STATUS %0d %08x", k,
                 rvv_mem_word(rvv_status_addr + 4*k));
      $display("RVV_TRAPS %0d", trap_seen);
      $display("RVV_EXPT vld=%b iid=%0d",
               dut.rvv_expt_vld, dut.rvv_expt_iid);
      // 可选调试: +RVV_RES_ADDR/+RVV_EXP_ADDR 给出两个阵列的基址,
      // 每条用例打印前 4 个字 (FAIL 时对照用)。平时不传就不打。
      if ($value$plusargs("RVV_RES_ADDR=%d", res_addr) &&
          $value$plusargs("RVV_EXP_ADDR=%d", exp_addr)) begin
        for (k = 0; k < rvv_status_n; k = k + 1)
          $display("RVV_RES %0d %08x %08x %08x %08x", k,
                   rvv_mem_word(res_addr + 64*k + 0),
                   rvv_mem_word(res_addr + 64*k + 4),
                   rvv_mem_word(res_addr + 64*k + 8),
                   rvv_mem_word(res_addr + 64*k + 12));
        for (k = 0; k < rvv_status_n; k = k + 1)
          $display("RVV_EXP %0d %08x %08x %08x %08x", k,
                   rvv_mem_word(exp_addr + 64*k + 0),
                   rvv_mem_word(exp_addr + 64*k + 4),
                   rvv_mem_word(exp_addr + 64*k + 8),
                   rvv_mem_word(exp_addr + 64*k + 12));
      end
    end
  endtask

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
    if (!rst && trace_early && cycles >= 84 && cycles <= 140) begin
      $display("      T%0d | IFU inst=%b%b%b cnt=%0d av=%b | IDreg=%b%b%b | disp=%b%b%b",
               cycles, dut.idu_inst2_vld, dut.idu_inst1_vld, dut.idu_inst0_vld,
               dut.u_rv32ifu2_top.u_ibuf.cnt_q, dut.idu_accept_num,
               dut.u_ct_idu_top.u_ct_idu_id_ctrl.id_inst2_vld,   // ← 修: 穿到 id_ctrl 实例
               dut.u_ct_idu_top.u_ct_idu_id_ctrl.id_inst1_vld,   // ← 修
               dut.u_ct_idu_top.u_ct_idu_id_ctrl.id_inst0_vld,   // ← 修
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
      // ⚠️ pd2 已知 ⇒ case 正常匹配 ⇒ 数据 X 是**那一支的数据源** X, 不是 default 触发
      //    判据: 同一个 case 里 pc 也是同一支赋的, default 会让 pc 一起变 X
      $display("           派发记录: flags0=%b pc0=%08x rf_we0=%b | is_dis_data0=%08x",
               dut.idu_rtu_disp0_flags, dut.idu_rtu_disp0_pc, dut.idu_rtu_disp0_rf_we,
               dut.u_ct_idu_top.dp_is_dis_inst0_data[31:0]);
      // 目的/旧物理号: 派发记录里 dst_preg=[66:61] old_preg=[72:67] (ct_idu_top.sv:1405-1406)
      $display("                    dst_preg=%0d old_preg=%0d | 派发记录: dst=%0d old=%0d",
               dut.u_ct_idu_top.dp_is_dis_inst0_data[66:61],
               dut.u_ct_idu_top.dp_is_dis_inst0_data[72:67],
               dut.idu_rtu_disp0_dst_preg, dut.idu_rtu_disp0_old_preg);
      $display("                    pd2=%b sel=%b | IR级: ir0_data=%08x ir0_pc=%08x",
               dut.u_ct_idu_top.ctrl_xx_is_inst0_sel[0],
               dut.u_ct_idu_top.ctrl_xx_is_inst0_sel,
               dut.u_ct_idu_top.dp_ir_inst0_data[31:0],
               dut.u_ct_idu_top.dp_ir_inst0_pc[31:0]);
      // 源头: IFU 交给 IDU 的 97 位包 (A910 顶层拼的) —— 看它是不是"PC 好、指令字 X"
      $display("          IFU包: vld=%b inst=%08x pc=%08x | 97bit=%024x",
               dut.idu_inst0_vld, dut.ifu_idu_ib_inst0_data[31:0],
               dut.ifu_idu_ib_inst0_data[63:32], dut.ifu_idu_ib_inst0_data[95:0]);
      $display("          IDpipedown: data=%08x pc64=%08x vld0=%b",
               dut.u_ct_idu_top.dp_id_pipedown_inst0_data[31:0],
               dut.u_ct_idu_top.dp_id_pipedown_inst0_data[63:32],
               dut.u_ct_idu_top.u_ct_idu_id_ctrl.id_inst0_vld);   // ← 修: 穿到 id_ctrl 实例
      // 有效位那条链 (与数据不同源 —— 嫌疑点)
      $display("          VLD链: ir_inst0_vld=%b ir_pipe_stall=%b pipedown0_vld=%b pre_dis0_vld=%b disp0_vld=%b",
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_inst0_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pipedown_stall,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_pipedown_inst0_vld,
               dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ctrl_ir_pre_dis_inst0_vld,
               dut.u_ct_idu_top.ctrl_dp_dis_inst0_vld);
      // RTU 的预分配握手 (门房模型): IDU 报请求几条, RTU 给号
      $display("          RTU分配: req=%b | 给号=%0d(vld%b) %0d(vld%b) %0d(vld%b)",
               dut.ren_preg_req,
               dut.rtu_idu_alloc_preg0, dut.rtu_idu_alloc_preg0_vld,
               dut.rtu_idu_alloc_preg1, dut.rtu_idu_alloc_preg1_vld,
               dut.rtu_idu_alloc_preg2, dut.rtu_idu_alloc_preg2_vld);
      // ⚠️ 对照: RTU 那个**端口** vs 适配层的**输出** vs 顶层网 —— 三者该是同一个值
      $display("          [对照] u_rtu口=%0d/%0d/%0d | 适配层入=%0d/%0d/%0d | 顶层网=%0d/%0d/%0d",
               dut.u_rtu.rtu_preg_alloc0, dut.u_rtu.rtu_preg_alloc1,
               dut.u_rtu.rtu_preg_alloc2,
               dut.u_rtu_adapter.rtu_preg_alloc0, dut.u_rtu_adapter.rtu_preg_alloc1,
               dut.u_rtu_adapter.rtu_preg_alloc2,
               dut.rtu_idu_alloc_preg0, dut.rtu_idu_alloc_preg1,
               dut.rtu_idu_alloc_preg2);
      // 发射 + 写回的物理号 (同事线索: 写回时标记全是 0 → div 拿不到依赖释放)
      $display("          发射: aiq_sel=%b aiq_dst_preg=%0d | mult_sel=%b mult_preg=%0d div_sel=%b div_preg=%0d",
               dut.idu_aiq_sel, dut.idu_aiq_dst_preg,
               dut.idu_mult_sel, dut.idu_mult_dst_preg,
               dut.idu_div_sel, dut.idu_div_dst_preg);
      $display("          写回: p0_vld=%b p0_dupx=%0d | p1_vld=%b p1_dupx=%0d | p2_vld=%b p2_dupx=%0d",
               dut.iu_idu_ex2_pipe0_wb_preg_vld_dupx, dut.iu_idu_ex2_pipe0_wb_preg_dupx,
               dut.iu_idu_ex2_pipe1_wb_preg_vld_dupx, dut.iu_idu_ex2_pipe1_wb_preg_dupx,
               dut.iu_idu_ex2_pipe2_wb_preg_vld_dupx, dut.iu_idu_ex2_pipe2_wb_preg_dupx);
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

    // RVV sweep 回读参数 (地址用十进制传, 避免 VCS 对 %h 的实现差异)
    rvv_sweep_en = $test$plusargs("RVV_SWEEP");
    if (rvv_sweep_en) begin
      if (!$value$plusargs("RVV_PROGRESS_ADDR=%d", rvv_progress_addr))
        rvv_progress_addr = 0;
      if (!$value$plusargs("RVV_STATUS_ADDR=%d", rvv_status_addr))
        rvv_status_addr = 0;
      if (!$value$plusargs("RVV_STATUS_N=%d", rvv_status_n))
        rvv_status_n = 0;
      if (!$value$plusargs("RVV_PHASE_ADDR=%d", rvv_phase_addr))
        rvv_phase_addr = 0;
      $display("  [RVV_SWEEP] progress@0x%08x status@0x%08x n=%0d",
               rvv_progress_addr, rvv_status_addr, rvv_status_n);
    end

    $display("");
    $display("==================================================");
    $display("  A910_cpu 最小冒烟台  (MAX_CYCLES=%0d)", max_cycles);
    $display("==================================================");
    // 位宽自检: 有人报"波形里 rtu_preg_alloc0 是 2 位" —— 这里印出实际位宽
    $display("  [位宽] rtu_idu_alloc_preg0=%0d tap_num0=%0d ren_preg_req=%0d RTU_PREG_W=%0d",
             $bits(dut.rtu_idu_alloc_preg0), $bits(dut.u_rtu.u_preg.tap_num0),
             $bits(dut.ren_preg_req), `RTU_PREG_W);
    // 同事报"在 RTU 顶层拉的波形里 rtu_preg_alloc0 是 2 位" —— 逐层量一遍
    $display("  [位宽] u_rtu.rtu_preg_alloc0=%0d  u_rtu.u_preg.rtu_preg_alloc0=%0d  u_rtu.u_preg.tap_num0=%0d",
             $bits(dut.u_rtu.rtu_preg_alloc0), $bits(dut.u_rtu.u_preg.rtu_preg_alloc0),
             $bits(dut.u_rtu.u_preg.tap_num0));

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
      // RVV sweep 的 status/progress 是标量 store, 可能还压在 WMB 里 —— 多等一会儿
      if (rvv_sweep_en) repeat (5000) @(posedge clk);
      $display("");
      $display("==================================================");
      if (a0_val == 0) begin
        $display("  === A910 SMOKE: PASS ===");
        $display("  a0(x10) = 0 (写了 %0d 次), 累计退休 %0d 条, 用了 %0d 拍",
                 a0_hits, retired, cycles);
        $display("==================================================");
        rvv_dump();
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
        rvv_dump();
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
      rvv_dump();
    end

    // ⚠️ 必须 $fatal 不能 $finish: $finish 的退出码是 0, make 会把失败当通过。
    //    能走到这里一定是超时 —— PASS 分支已经在上面 $finish 返回了。
    $fatal(1, "a910 smoke timeout");
  end

  // =====================================================================
  //  【临时诊断】派遣记录 vs 分配握手 —— `A910_SIM_ARGS=+PROBE_DISP`
  //
  //  追 IDU 尾巴用: create→read 改完之后 X 没了, 但
  //    * 首条退休 dbg_commit_value0 = X   (x5 本该 <= 100)
  //    * 第三条 dbg_commit_pc  = 0x04      (mul 本该在 0x08)
  //  两个都是"表项内部不自洽"的样子 —— pc 与 dst/lreg 描述的不是同一条指令。
  //  RTU 侧 pc 和 dst_preg 走的是同一条路进 ROB (RTU_subsys.v:458-469), 所以
  //  嫌疑落在**派遣当拍记录本身**、或**记录与分配号不同拍**上。这里把两者
  //  同拍拍下来对齐着看。
  // =====================================================================
  integer disp_probe_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_DISP") && disp_probe_lines < 200) begin
      if (dut.idu_rtu_disp0_vld === 1'b1 || dut.idu_rtu_disp1_vld === 1'b1
          || dut.idu_rtu_disp2_vld === 1'b1 || dut.ren_preg_req !== 3'b000) begin
        disp_probe_lines = disp_probe_lines + 1;
        $display("  [DISP] T%0d vld=%b%b%b | pc0=%08x pc1=%08x pc2=%08x",
                 cycles, dut.idu_rtu_disp2_vld, dut.idu_rtu_disp1_vld, dut.idu_rtu_disp0_vld,
                 dut.idu_rtu_disp0_pc, dut.idu_rtu_disp1_pc, dut.idu_rtu_disp2_pc);
        $display("         dst_preg=%0d,%0d,%0d lreg=%0d,%0d,%0d flags=%b,%b,%b",
                 dut.idu_rtu_disp0_dst_preg, dut.idu_rtu_disp1_dst_preg,
                 dut.idu_rtu_disp2_dst_preg,
                 dut.idu_rtu_disp0_dst_lreg, dut.idu_rtu_disp1_dst_lreg,
                 dut.idu_rtu_disp2_dst_lreg,
                 dut.idu_rtu_disp0_flags, dut.idu_rtu_disp1_flags, dut.idu_rtu_disp2_flags);
        $display("         req=%b alloc_vld(IDU)=%b%b%b | 给号=%0d(%b),%0d(%b),%0d(%b)",
                 dut.ren_preg_req,
                 dut.idu_rtu_ir_preg2_alloc_vld, dut.idu_rtu_ir_preg1_alloc_vld,
                 dut.idu_rtu_ir_preg0_alloc_vld,
                 dut.rtu_idu_alloc_preg0, dut.rtu_idu_alloc_preg0_vld,
                 dut.rtu_idu_alloc_preg1, dut.rtu_idu_alloc_preg1_vld,
                 dut.rtu_idu_alloc_preg2, dut.rtu_idu_alloc_preg2_vld);
        // ★ 二分点: 写入口(create) vs 读出口(read) 的 pc 各是多少 + IR 级车位有效位
        $display("         [二分] create_pc=%08x,%08x,%08x  read_pc=%08x,%08x,%08x",
                 dut.u_ct_idu_top.x_ct_idu_is_dp.is_inst0_create_pc[31:0],
                 dut.u_ct_idu_top.x_ct_idu_is_dp.is_inst1_create_pc[31:0],
                 dut.u_ct_idu_top.x_ct_idu_is_dp.is_inst2_create_pc[31:0],
                 dut.u_ct_idu_top.x_ct_idu_is_dp.is_inst0_read_pc[31:0],
                 dut.u_ct_idu_top.x_ct_idu_is_dp.is_inst1_read_pc[31:0],
                 dut.u_ct_idu_top.x_ct_idu_is_dp.is_inst2_read_pc[31:0]);
        $display("                dp_ir_pc=%08x,%08x,%08x  ir_vld=%b%b%b  ir_pipped_vld=%b%b%b",
                 dut.u_ct_idu_top.x_ct_idu_is_dp.dp_ir_inst0_pc[31:0],
                 dut.u_ct_idu_top.x_ct_idu_is_dp.dp_ir_inst1_pc[31:0],
                 dut.u_ct_idu_top.x_ct_idu_is_dp.dp_ir_inst2_pc[31:0],
                 dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_inst2_vld,
                 dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_inst1_vld,
                 dut.u_ct_idu_top.x_ct_idu_ir_ctrl.ir_inst0_vld,
                 dut.u_ct_idu_top.ctrl_ir_pipedown_inst2_vld,
                 dut.u_ct_idu_top.ctrl_ir_pipedown_inst1_vld,
                 dut.u_ct_idu_top.ctrl_ir_pipedown_inst0_vld);
      end
    end
  end

  // =====================================================================
  //  【临时诊断】ifu_biu_axi 的 busy_q 死锁现场 —— `A910_SIM_ARGS=+PROBE_AXI`
  //
  //  假设 (读码推出, 待实测): 单拍事务下
  //     `busy_q` 的清除条件是 `beat_taken & (beat_left_q == 3'd1)`,
  //     但 `beat_left_q` 在 `r_fire` 那拍就从 1 减到 0, 而 `beat_taken`
  //     (= data_vld_q) 要**再晚一拍**才成立 ⇒ 两个条件永远不同拍 ⇒ busy_q 永不落
  //     ⇒ `arvalid = biu_rd_req & ~busy_q` 恒 0 ⇒ refill FSM 卡在 S_REQ ⇒ 取指死。
  //
  //  触发即打印 (不用写死窗口, 免得又得为一轮调试改一次 TB), 上限 300 行。
  // =====================================================================
  integer axi_probe_lines = 0;
  always @(posedge clk) begin
    if (!rst && $test$plusargs("PROBE_AXI") && axi_probe_lines < 300) begin
      if (dut.u_ifu_biu_axi.busy_q === 1'b1 || dut.u_rv32ifu2_top.refill_req === 1'b1
          || dut.u_ifu_biu_axi.ar_fire === 1'b1 || dut.u_ifu_biu_axi.r_fire === 1'b1) begin
        axi_probe_lines = axi_probe_lines + 1;
        $display("  [AXI] T%0d ar_fire=%b r_fire=%b beat_taken=%b | busy_q=%b beat_left=%0d data_vld=%b grnt=%b",
                 cycles,
                 dut.u_ifu_biu_axi.ar_fire, dut.u_ifu_biu_axi.r_fire,
                 dut.u_ifu_biu_axi.beat_taken,
                 dut.u_ifu_biu_axi.busy_q, dut.u_ifu_biu_axi.beat_left_q,
                 dut.u_ifu_biu_axi.data_vld_q, dut.u_ifu_biu_axi.grnt_q);
        $display("         refill: state=%0d req=%b busy=%b | req_len=%b arvalid=%b arready=%b rvalid=%b rready=%b | 已退休=%0d",
                 dut.u_rv32ifu2_top.u_refill.state_q,
                 dut.u_rv32ifu2_top.refill_req, dut.u_rv32ifu2_top.refill_busy,
                 dut.u_ifu_biu_axi.biu_rd_len,
                 dut.u_ifu_biu_axi.ifu_biu_arvalid, dut.u_ifu_biu_axi.ifu_biu_arready,
                 dut.u_ifu_biu_axi.biu_ifu_rvalid, dut.u_ifu_biu_axi.ifu_biu_rready,
                 retired);
      end
    end
  end

  // =========================================================================
  // 2026-10-17 S9: 向量通路一次性探针 (只打前 8 次, 用完可删)
  //
  // 2026-10-18: ct_idu_vec_ls_fill.sv 重写后 ctx_*/beat_* 这些内部名改了,
  //   下面这段会和新的 RTL 对不上 (VCS 的 XMRE 是编译期解析, 不是运行期)。
  //   默认不编译; 需要时用 +define+RVV_OLD_FILL_VDBG 打开并同步信号名。
  // =========================================================================
`ifdef RVV_OLD_FILL_VDBG
  integer v_issue=0, v_accept=0, v_lsuvalid=0, v_fillacc=0, v_beat=0, v_lsiqcrt=0, v_vqcreate=0, v_lsuok=0, v_acc2=0, v_lsu2=0, v_resp=0, v_ctx=0, v_wb=0;
  always @(posedge clk) begin
    if (dut.u_ct_idu_top.u_ct_idu_vecq.vecq_xx_issue_en && v_issue<8) begin
      v_issue = v_issue + 1;
      $display("[VDBG] T%0t VIQ issue iid=%0d op=%0d bits=%h", $time,
               dut.idu_vec_inst_iid, dut.idu_vec_inst_opcode, dut.idu_vec_inst_bits);
    end
    if (dut.u_rvv_a910_bridge.accept && v_accept<8) begin
      v_accept = v_accept + 1;
      $display("[VDBG] T%0t bridge accept iid=%0d", $time, dut.idu_vec_inst_iid);
    end
    if (dut.u_rvv_a910_bridge.core_lsu_valid[0] && v_lsuvalid<8) begin
      v_lsuvalid = v_lsuvalid + 1;
      $display("[VDBG] T%0t core LSU uop iid=%0d store=%0d", $time,
               dut.rvv_lsu_uop.rob_tag, dut.rvv_lsu_uop.lsu_is_store);
    end
    if (dut.u_ct_idu_top.u_vec_ls_fill.uop_accept && v_fillacc<8) begin
      v_fillacc = v_fillacc + 1;
      $display("[VDBG] T%0t fill accept found=%0d", $time,
               dut.u_ct_idu_top.u_vec_ls_fill.uop_anchor_found);
    end
    if (dut.u_ct_idu_top.u_vec_ls_fill.beat_go && v_beat<80) begin
      v_beat = v_beat + 1;
      $display("[VDBG] T%0t fill beat anchor=%0d", $time,
               dut.u_ct_idu_top.u_vec_ls_fill.beat_sel);
    end
    if (dut.u_ct_idu_top.lsiq_vec_create_vld && v_lsiqcrt<8) begin
      v_lsiqcrt = v_lsiqcrt + 1;
      $display("[VDBG] T%0t LSIQ vec create entry=%b iid=%0d", $time,
               dut.u_ct_idu_top.lsiq_vec_create_entry, dut.u_ct_idu_top.lsiq_vec_create_iid);
    end
    if (dut.u_rvv_a910_bridge.accept) begin
      $display("[VDBG] T%0t inst_data.rob_tag=%0d", $time, dut.u_rvv_a910_bridge.core_inst_data[0].rob_tag);
    end
    if (dut.u_rvv_a910_bridge.u_rvv_core.frontend.cmd_valid_o[0]) begin
      $display("[VDBG] T%0t frontend cmd rob_tag=%0d", $time,
               dut.u_rvv_a910_bridge.u_rvv_core.frontend_cmd_data[0].rob_tag);
    end
    if (dut.u_rvv_a910_bridge.u_rvv_core.backend.rs_valid_dp2lsu[0]) begin
      $display("[VDBG] T%0t LSU RS push rob_tag=%0d", $time,
               dut.u_rvv_a910_bridge.u_rvv_core.backend.rs_dp2lsu[0].rob_tag);
    end
    if (dut.u_rvv_a910_bridge.u_rvv_core.backend.uop_lsu_valid_rvv2lsu[0]) begin
      $display("[VDBG] T%0t LSU RS out rob_tag=%0d idx=%h", $time,
               dut.u_rvv_a910_bridge.u_rvv_core.backend.uop_lsu_rvv2lsu[0].rob_tag,
               dut.u_rvv_a910_bridge.u_rvv_core.backend.uop_lsu_rvv2lsu[0].uop_index);
    end
    if ($time > 1090000 && $time < 1260000 && ($time % 100000) == 0) begin
      $display("[VDBG] T%0t ctx0 act=%b busy=%b mask=%h ptr=%0d all=%b bit=%b old=%b mop=%0d vl=%0d",
        $time,
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_active[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_busy[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_mask[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_byte_ptr[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_all_issued[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_beat_issue[0],
        dut.u_ct_idu_top.lsiq_vec_old[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_mop[0],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_vl[0]);
    end
    if (dut.u_ct_idu_top.u_vec_ls_fill.uop_accept && v_acc2<4) begin
      v_acc2 = v_acc2 + 1;
      $display("[VDBG] T%0t accept vl=%0d v0v=%b v0d=%h eew=%0d idx=%0d mop=%0d anchor=%0d",
        $time, dut.rvv_lsu_uop.vl, dut.rvv_lsu_uop.v0_valid, dut.rvv_lsu_uop.v0_data,
        dut.rvv_lsu_uop.vd_eew, dut.rvv_lsu_uop.uop_index,
        dut.rvv_lsu_uop.lsu_type.lsu_mop, dut.u_ct_idu_top.u_vec_ls_fill.uop_anchor);
    end
    if ($time > 1070 && $time < 1400 && v_lsu2 < 24) begin
      v_lsu2 = v_lsu2 + 1;
      $display("[VDBG] T%0t LSU agdc=%b dcda=%b wbcmp=%b beatdn=%h pop=%h vec=%b last=%b wbvec=%b daid=%0d",
        $time,
        dut.u_lsu_top.ld_ag_dc_inst_vld,
        dut.u_lsu_top.ld_dc_da_inst_vld,
        dut.u_lsu_top.ld_da_wb_cmplt_req,
        dut.u_lsu_top.ld_da_idu_beat_done,
        dut.u_lsu_top.ld_da_idu_pop_entry,
        dut.u_lsu_top.ld_da_vec,
        dut.u_lsu_top.ld_da_last,
        dut.lsu_idu_wb_pipe3_wb_preg_vec,
        dut.u_lsu_top.ld_da_iid);
    end
    if (dut.lsu_idu_wb_pipe3_wb_preg_vec && v_wb<24) begin
      v_wb = v_wb + 1;
      $display("[VDBG] T%0t WB iid=%0d uop=%0d data=%h", $time,
        dut.lsu_idu_wb_pipe3_wb_preg_iid, dut.lsu_idu_wb_pipe3_wb_uop_idx,
        dut.lsu_idu_wb_pipe3_wb_preg_data);
    end
    if (dut.rvv_lsu_resp_valid && v_resp<8) begin
      v_resp = v_resp + 1;
      $display("[VDBG] T%0t RESP iid=%0d uop=%0d last=%b wv=%b data=%h",
        $time, dut.rvv_lsu_resp.rob_tag, dut.rvv_lsu_resp.uop_index,
        dut.rvv_lsu_resp.lsu_vstore_last, dut.rvv_lsu_resp.vregfile_write_valid,
        dut.rvv_lsu_resp.vregfile_write_data[31:0]);
    end
    if ($time > 2000 && $time < 2600 && v_ctx<40) begin
      v_ctx = v_ctx + 1;
      $display("[VDBG] T%0t FILL act=%b pend=%h all=%b stg=%b comm=%b drain=%b dr=%0d",
        $time,
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_active,
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_ld_pend[2],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_all_issued[2],
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_beat_staged,
        dut.u_ct_idu_top.u_vec_ls_fill.ctx_committed,
        dut.u_ct_idu_top.u_vec_ls_fill.drain_owner_vld,
        dut.u_ct_idu_top.u_vec_ls_fill.drain_owner);
    end
    if (dut.u_rvv_a910_bridge.u_rvv_core.backend.uop_lsu_valid_rvv2lsu[0] && v_lsuok<6) begin
      v_lsuok = v_lsuok + 1;
      $display("[VDBG] T%0t flat tag=%h uop.tag=%h rsout.tag=%h", $time,
               dut.u_rvv_a910_bridge.u_rvv_core.uop_lsu_rob_tag_rvv2lsu[0],
               dut.u_rvv_a910_bridge.core_lsu_uop.rob_tag,
               dut.u_rvv_a910_bridge.u_rvv_core.backend.uop_lsu_rvv2lsu[0].rob_tag);
    end
    if (dut.u_ct_idu_top.u_ct_idu_vecq.ctrl_vec_create0_en && v_vqcreate<8) begin
      v_vqcreate = v_vqcreate + 1;
      $display("[VDBG] T%0t vecq create0", $time);
    end
  end
`endif  // RVV_OLD_FILL_VDBG

endmodule
