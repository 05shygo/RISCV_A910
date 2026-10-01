`timescale 1ns / 1ps
`include "RTU_define.vh"

// ===========================================================================
// tb_rtu_rob — 退休单元的独立单测台 (doc/rtu_plan_zh.md 阶段 0 的验收件)
//
// 不经整核: 直接用激励驱动 §6.1 的输入端口, 逐拍核对 §6.2 的输出。
// 为什么要这一层: 退休单元 90% 的 bug (退休窗口 / 异常最旧者胜 / 冲刷 /
// preg 释放与恢复 / ROB 满停顿 / 两拍分配) 在整核 difftest 里只表现成
// "某条指令结果不对", 定位不到是 ROB 指针、影子窗口还是 preg 状态机算错。
//
// ------------------------- 检查口径 (写清楚, 免得被误解) ---------------------
// 参考模型**不预测 DUT 的内部流水延迟**, 而是逐拍核对"你报出来的退休事件"是否合法:
//   * 第 k 个退休槽必须正好是参考队列里"第 k 条还没退休的指令" (程序序、不跳号),
//     且它必须已经收到过完成信号;
//   * pc / reg / ena / value / 释放的 preg / store 脉冲 / CSR 写值 必须与参考模型一致;
//   * 陷阱必须落在队头, cause/tval/mepc 必须等于参考模型注入的那一组,
//     且那条 ena=0、不写任何东西;
//   * 误预测退休那拍的前端重定向目标必须等于该分支的真实 target;
//   * `rtu_beu_retire_iid` 必须等于"下一条该退休指令"的 iid (iid 约定的直接核对)。
// 这样既做到逐拍比对, 又不把 DUT 的内部延迟抄进参考模型 —— 照抄 RTL 的 TB 只能
// 证明"RTL 等于它自己"。参考模型是纯行为描述, 与 RTL 结构无关。
//
// 另有几条硬不变量 (每拍):
//   * 分配器给出的编号两两不同、都 >= 32、且不在占用态;
//   * 释放脉冲必须逐位等于"该指令真写了 rd 且 old_preg >= 32"; 释放的编号必须等于 old_preg;
//   * 空闲计数 == 64 - 占用数 (饱和到 3);
//   * 冲刷时间线严格 T(重定向+冻结) / T+1(backend_flush) / T+2(ren_flush+AMT) / T+3 放开;
//   * AMT 广播逐位等于参考模型自己维护的架构映射表。
//
// 时钟约定 (与 §6.0 的两拍分配对齐):
//   在 negedge N 驱动的输入, 被 DUT 在下一个 posedge 采样 (即"周期 N+1"生效);
//   在 negedge N 读到的 alloc* 是"周期 N"发出的编号 -> 用于周期 N+1 的派遣。
//   激励只许打 n_ready 之前的指令 —— 本拍刚派出去的还没进表项, 不能同拍完成。
//
// 用法:
//   make rtu-unit                       # 默认种子 + 200 条随机指令
//   ./obj_unit_rtu/simv +SEED=12345 +NINSTR=400 [+TRACE]
// ===========================================================================
module tb_rtu_rob;

    localparam integer MAXI = 65536;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    // ===================== DUT 端口 =====================
    logic [1:0]  ren_preg_req;
    logic [4:0]  ren_lreg0, ren_lreg1, ren_lreg2;
    wire  [6:0]  alloc0, alloc1, alloc2;
    wire         alloc_vld0, alloc_vld1, alloc_vld2;
    wire  [1:0]  free_cnt_o;

    wire         d0_vld, d1_vld, d2_vld;
    logic [31:0] d0_pc, d1_pc, d2_pc;
    logic [24:0] d0_chk, d1_chk, d2_chk;
    logic [4:0]  d0_lreg, d1_lreg, d2_lreg;
    logic        d0_rfwe, d1_rfwe, d2_rfwe;
    logic [6:0]  d0_dpreg, d1_dpreg, d2_dpreg;
    logic [6:0]  d0_opreg, d1_opreg, d2_opreg;
    logic [6:0]  d0_s1preg, d1_s1preg, d2_s1preg;
    logic [11:0] d0_ca, d1_ca, d2_ca;
    logic [2:0]  d0_cop, d1_cop, d2_cop;
    logic [4:0]  d0_cimm, d1_cimm, d2_cimm;
    logic [4:0]  d0_flg, d1_flg, d2_flg;
    logic [2:0]  d0_sqid, d1_sqid, d2_sqid;

    logic        cv0, cv1, cv2, cv3, cv4;
    logic [6:0]  ci0, ci1, ci2, ci3, ci4;

    logic        rsv_vld;
    logic [6:0]  rsv_iid;
    logic        rsv_taken, rsv_misp;
    logic [31:0] rsv_tgt;

    logic        ex_vld;
    logic [6:0]  ex_iid;
    logic [4:0]  ex_cause;
    logic [31:0] ex_tval;

    logic        sq_rdy0, sq_rdy1, sq_rdy2, sq_stall;
    logic        int_pending;
    logic [31:0] csr_tvec, csr_mepc_i;

    wire         ifu_flush, ifu_chg_vld;
    wire [31:0]  ifu_chg_pc;
    wire         ifu_trn_vld, ifu_trn_taken;
    wire [31:0]  ifu_trn_pc;
    wire [24:0]  ifu_trn_chk;
    wire         backend_flush;
    wire [6:0]   beu_retire_iid;
    wire         beu_mask;
    wire         disp_stall;
    wire         ren_recover_vld, ren_flush;
    wire [223:0] ren_recover_map;
    wire [6:0]   ren_free_preg0, ren_free_preg1, ren_free_preg2;
    wire         ren_free_vld0, ren_free_vld1, ren_free_vld2;
    wire [6:0]   praddr0, praddr1, praddr2, csr_src_raddr;
    wire         csr_rd_we;
    wire [6:0]   csr_rd_addr;
    wire [31:0]  csr_rd_wdata;
    wire         store_vld0, store_vld1, store_vld2;
    wire [2:0]   store_sqid0, store_sqid1, store_sqid2;
    wire         csr_we;
    wire [11:0]  csr_addr;
    wire [31:0]  csr_wdata;
    wire         trap_vld, mret_vld;
    wire [31:0]  trap_epc, trap_tval;
    wire [4:0]   trap_cause;
    wire [1:0]   retire_cnt;
    wire         cmv0, cmv1, cmv2, cmena0, cmena1, cmena2;
    wire [31:0]  cmpc0, cmpc1, cmpc2, cmval0, cmval1, cmval2;
    wire [4:0]   cmreg0, cmreg1, cmreg2;

    // ---- 存储器模型: CSR 文件与物理寄存器堆 (都是组合读, 与真核同构) ----
    logic [31:0] csr_file [0:4095];
    logic [31:0] pf [0:95];
    logic [31:0] csr_rdata;
    logic [31:0] prdata0, prdata1, prdata2, csrsrc_rdata;

    assign csr_rdata    = csr_file[csr_addr];      // 地址由 DUT 给 (组合读)
    assign prdata0      = pf[praddr0];
    assign prdata1      = pf[praddr1];
    assign prdata2      = pf[praddr2];
    assign csrsrc_rdata = pf[csr_src_raddr];

    RTU dut (
        .cpu_clk(clk), .cpu_rst(rst),
        .ren_preg_req(ren_preg_req),
        .ren_preg_req_lreg0(ren_lreg0), .ren_preg_req_lreg1(ren_lreg1),
        .ren_preg_req_lreg2(ren_lreg2),
        .rtu_preg_alloc0(alloc0), .rtu_preg_alloc1(alloc1), .rtu_preg_alloc2(alloc2),
        .rtu_preg_alloc_vld0(alloc_vld0), .rtu_preg_alloc_vld1(alloc_vld1),
        .rtu_preg_alloc_vld2(alloc_vld2),
        .rtu_preg_free_cnt(free_cnt_o),
        .disp0_vld(d0_vld), .disp0_pc(d0_pc), .disp0_chk(d0_chk),
        .disp0_dst_lreg(d0_lreg), .disp0_rf_we(d0_rfwe), .disp0_dst_preg(d0_dpreg),
        .disp0_old_preg(d0_opreg), .disp0_src1_preg(d0_s1preg),
        .disp0_csr_addr(d0_ca), .disp0_csr_op(d0_cop), .disp0_csr_imm(d0_cimm),
        .disp0_flags(d0_flg), .disp0_sq_id(d0_sqid),
        .disp1_vld(d1_vld), .disp1_pc(d1_pc), .disp1_chk(d1_chk),
        .disp1_dst_lreg(d1_lreg), .disp1_rf_we(d1_rfwe), .disp1_dst_preg(d1_dpreg),
        .disp1_old_preg(d1_opreg), .disp1_src1_preg(d1_s1preg),
        .disp1_csr_addr(d1_ca), .disp1_csr_op(d1_cop), .disp1_csr_imm(d1_cimm),
        .disp1_flags(d1_flg), .disp1_sq_id(d1_sqid),
        .disp2_vld(d2_vld), .disp2_pc(d2_pc), .disp2_chk(d2_chk),
        .disp2_dst_lreg(d2_lreg), .disp2_rf_we(d2_rfwe), .disp2_dst_preg(d2_dpreg),
        .disp2_old_preg(d2_opreg), .disp2_src1_preg(d2_s1preg),
        .disp2_csr_addr(d2_ca), .disp2_csr_op(d2_cop), .disp2_csr_imm(d2_cimm),
        .disp2_flags(d2_flg), .disp2_sq_id(d2_sqid),
        .cmplt_vld0(cv0), .cmplt_iid0(ci0), .cmplt_vld1(cv1), .cmplt_iid1(ci1),
        .cmplt_vld2(cv2), .cmplt_iid2(ci2), .cmplt_vld3(cv3), .cmplt_iid3(ci3),
        .cmplt_vld4(cv4), .cmplt_iid4(ci4),
        .resolve_vld(rsv_vld), .resolve_iid(rsv_iid), .resolve_taken(rsv_taken),
        .resolve_mispred(rsv_misp), .resolve_target(rsv_tgt),
        .expt_vld(ex_vld), .expt_iid(ex_iid), .expt_cause(ex_cause), .expt_tval(ex_tval),
        .sq_rdy0(sq_rdy0), .sq_rdy1(sq_rdy1), .sq_rdy2(sq_rdy2), .sq_stall(sq_stall),
        .csr_rdata(csr_rdata), .int_pending(int_pending),
        .preg_rdata0(prdata0), .preg_rdata1(prdata1), .preg_rdata2(prdata2),
        .rtu_csr_src_rdata(csrsrc_rdata),
        .csr_trap_vector(csr_tvec), .csr_mepc(csr_mepc_i),
        .rtu_ifu_flush(ifu_flush), .rtu_ifu_chgflw_vld(ifu_chg_vld),
        .rtu_ifu_chgflw_pc(ifu_chg_pc),
        .rtu_ifu_train_vld(ifu_trn_vld), .rtu_ifu_train_pc(ifu_trn_pc),
        .rtu_ifu_train_chk(ifu_trn_chk), .rtu_ifu_train_taken(ifu_trn_taken),
        .rtu_backend_flush(backend_flush),
        .rtu_beu_retire_iid(beu_retire_iid), .rtu_beu_flush_chgflw_mask(beu_mask),
        .rtu_disp_stall(disp_stall),
        .rtu_ren_recover_vld(ren_recover_vld), .rtu_ren_recover_map(ren_recover_map),
        .rtu_ren_flush(ren_flush),
        .rtu_ren_free_preg0(ren_free_preg0), .rtu_ren_free_preg1(ren_free_preg1),
        .rtu_ren_free_preg2(ren_free_preg2),
        .rtu_ren_free_vld0(ren_free_vld0), .rtu_ren_free_vld1(ren_free_vld1),
        .rtu_ren_free_vld2(ren_free_vld2),
        .rtu_preg_raddr0(praddr0), .rtu_preg_raddr1(praddr1), .rtu_preg_raddr2(praddr2),
        .rtu_csr_src_raddr(csr_src_raddr),
        .rtu_csr_rd_we(csr_rd_we), .rtu_csr_rd_addr(csr_rd_addr),
        .rtu_csr_rd_wdata(csr_rd_wdata),
        .rtu_store_vld0(store_vld0), .rtu_store_vld1(store_vld1),
        .rtu_store_vld2(store_vld2),
        .rtu_store_sq_id0(store_sqid0), .rtu_store_sq_id1(store_sqid1),
        .rtu_store_sq_id2(store_sqid2),
        .rtu_csr_we(csr_we), .rtu_csr_addr(csr_addr), .rtu_csr_wdata(csr_wdata),
        .rtu_trap_vld(trap_vld), .rtu_mret_vld(mret_vld),
        .rtu_trap_epc(trap_epc), .rtu_trap_tval(trap_tval), .rtu_trap_cause(trap_cause),
        .rtu_retire_cnt(retire_cnt),
        .dbg_commit_vld0(cmv0), .dbg_commit_vld1(cmv1), .dbg_commit_vld2(cmv2),
        .dbg_commit_pc0(cmpc0), .dbg_commit_pc1(cmpc1), .dbg_commit_pc2(cmpc2),
        .dbg_commit_ena0(cmena0), .dbg_commit_ena1(cmena1), .dbg_commit_ena2(cmena2),
        .dbg_commit_reg0(cmreg0), .dbg_commit_reg1(cmreg1), .dbg_commit_reg2(cmreg2),
        .dbg_commit_value0(cmval0), .dbg_commit_value1(cmval1), .dbg_commit_value2(cmval2)
    );

    // =======================================================================
    // 参考模型
    // =======================================================================
    integer cycle = 0;
    integer n_inst = 0;            // 已派遣条数; 指令号全局递增
    integer n_ret  = 0;            // 下一条该退休的指令号; 在途 = [n_ret, n_inst)
    integer n_ready = 0;           // 本拍之前就已派遣的条数 (激励只许打这个范围)

    logic [31:0] x_pc  [0:MAXI-1];
    logic [31:0] x_val [0:MAXI-1];
    logic [4:0]  x_lreg[0:MAXI-1];
    logic        x_rfwe[0:MAXI-1];
    logic [4:0]  x_flg [0:MAXI-1];
    logic [6:0]  x_dpr [0:MAXI-1];
    logic [6:0]  x_opr [0:MAXI-1];
    logic [6:0]  x_iid [0:MAXI-1];
    logic        x_cmp [0:MAXI-1];
    logic        x_exc [0:MAXI-1];
    logic [4:0]  x_ec  [0:MAXI-1];
    logic [31:0] x_etv [0:MAXI-1];
    logic [11:0] x_ca  [0:MAXI-1];
    logic [2:0]  x_cop [0:MAXI-1];
    logic [4:0]  x_cim [0:MAXI-1];
    logic [2:0]  x_sqi [0:MAXI-1];
    logic [31:0] x_tgt [0:MAXI-1];
    logic        x_tkn [0:MAXI-1];
    logic        x_msp [0:MAXI-1];
    logic        x_rsv [0:MAXI-1];

    logic [95:0] ref_busy = 96'd0;     // 占用 (派遣确认过)
    logic [95:0] ref_pend = 96'd0;     // 已发出编号、还没确认 (WF_ALLOC)
    logic [6:0]  ref_amt [0:31];       // 参考模型自己维护的 AMT

    logic [5:0]  tb_cptr = 6'd0;       // 派遣指针镜像 (iid = {回绕位, 槽号})
    logic        tb_cmsb = 1'b0;

    // =======================================================================
    // 派遣驱动: 一台**显式握手状态机**
    //
    // §6.0 的握手是两拍: T 拍给编号, T+1 拍才派遣。TB 在 negedge 采样、DUT 在
    // posedge 采样, 所以计划必须**晚一代**才摆上口, 否则配到的是上一代编号 ——
    // 编号早已回池, 指令却拿着它, 紧接着它会被发给别人 (本 TB 栽过的坑)。
    //
    //   D_IDLE --(有活 && 不 stall)--> D_REQ --(无条件)--> D_DISP --(无条件)--> D_IDLE
    //        生成计划 pl_*            摆 ren_preg_req      摆 disp_* + 记流水账
    //
    // 三条纪律, 缺一条就会再栽:
    //   ① **所有派遣端口都是连续赋值** (由 dstate + pl_* + h_got* 驱动), 不做过程式
    //      驱动 —— 这样"摆上口的值"与"TB 记的账"在构造上就是同一个表达式, 不会
    //      在同一个时间步里读到旧值;
    //   ② 派遣 vld 由**当拍** disp_stall 连续门控, 与 DUT 的接受条件同式 ——
    //      "成没成"是当拍的函数, 不需要预测下一拍;
    //   ③ 记账只在 D_DISP→D_IDLE 那一步做一次。
    // =======================================================================
    localparam [1:0] D_IDLE = 2'd0, D_REQ = 2'd1, D_DISP = 2'd2;
    logic [1:0] dstate = D_IDLE;

    integer      pl_n = 0;             // 本份计划要派几条
    logic [4:0]  pl_lreg [0:2];
    logic [31:0] pl_pc   [0:2];
    logic [24:0] pl_chk  [0:2];
    logic        pl_rfwe [0:2];
    logic [4:0]  pl_flg  [0:2];
    logic [6:0]  pl_opreg[0:2];
    logic [6:0]  pl_s1   [0:2];
    logic [11:0] pl_ca   [0:2];
    logic [2:0]  pl_cop  [0:2];
    logic [4:0]  pl_cimm [0:2];
    logic [2:0]  pl_sqi  [0:2];
    logic [31:0] pl_val  [0:2];

    logic [6:0]  h_got  [0:2];         // D_REQ 那拍锁存下来的编号
    logic [2:0]  h_gotv = 3'd0;

    // 已经摆上口的那份计划的快照 + "它还欠一次结算"。
    // 为什么要留一份: 接受位是 posedge 锁存的 (acc_q), 要等到**下一拍**才读得到,
    // 而那时 pl_* 已经被下一份计划覆盖了。
    integer      cp_n = 0;             // 快照的条数 (即"上一条被派遣的"条数)
    logic [4:0]  cp_lreg [0:2];
    logic [31:0] cp_pc   [0:2];
    logic [24:0] cp_chk  [0:2];
    logic        cp_rfwe [0:2];
    logic [4:0]  cp_flg  [0:2];
    logic [6:0]  cp_opreg[0:2];
    logic [6:0]  cp_s1   [0:2];
    logic [11:0] cp_ca   [0:2];
    logic [2:0]  cp_cop  [0:2];
    logic [4:0]  cp_cimm [0:2];
    logic [2:0]  cp_sqi  [0:2];
    logic [31:0] cp_val  [0:2];
    logic [6:0]  cp_got  [0:2];
    logic [2:0]  cp_gotv = 3'd0;
    logic        commit_pending = 1'b0;

    // ---- 连续驱动: 编号请求 (只在 D_REQ 那拍有效) ----
    assign ren_preg_req = (dstate == D_REQ) ? pl_n[1:0] : 2'd0;
    assign ren_lreg0    = pl_lreg[0];
    assign ren_lreg1    = pl_lreg[1];
    assign ren_lreg2    = pl_lreg[2];

    // ---- 连续驱动: 派遣 ----
    // 需要 preg 的车道必须拿到编号; dst_lreg==0 的车道不需要 (编号按 §6.0 是 don't-care)
    wire [2:0] lane_ok;
    assign lane_ok[0] = (dstate == D_DISP) && (pl_n > 0) && ((pl_lreg[0] != 5'd0) ? h_gotv[0] : 1'b1);
    assign lane_ok[1] = lane_ok[0] && (pl_n > 1) && ((pl_lreg[1] != 5'd0) ? h_gotv[1] : 1'b1);
    assign lane_ok[2] = lane_ok[1] && (pl_n > 2) && ((pl_lreg[2] != 5'd0) ? h_gotv[2] : 1'b1);
    wire [2:0] lane_go = lane_ok & {3{~disp_stall}};   // disp_stall 里含 flushing

    // ⚠️ 接受与否必须在 **posedge** 那一刻锁存 —— DUT 就是在那时采样的。
    //    用 negedge 再读 lane_go 已经晚了: 同一个 posedge 上 DUT 的寄存器已经翻过,
    //    disp_stall 可能已经变成 1 (比如这一次派遣自己引入的 csr_inflight),
    //    于是明明派出去了却记成"没派成" (踩过: 状态机永远停不下来)。
    logic [2:0] acc_q = 3'd0;
    // 同理: 退休观察也要**在 posedge 锁存** —— DUT 是在那一刻采样的。
    // 在 negedge 直接读 vldv/retire_cnt 会与"那一拍 DUT 真正做了什么"错开
    // (TB 在这一拍还会改自己的激励), 记账就会与 rptr 差一条 (踩过)。
    logic [2:0] ret_vld_q = 3'd0;
    logic [1:0] ret_cnt_q = 2'd0;
    logic       ret_trap_q = 1'b0;
    logic [4:0] ret_tcause_q = 5'd0;
    logic       ret_flush_q = 1'b0;
    always @(posedge clk) begin
        ret_vld_q    <= {cmv2, cmv1, cmv0};
        ret_cnt_q    <= retire_cnt;
        ret_trap_q   <= trap_vld;
        ret_tcause_q <= trap_cause;
        ret_flush_q  <= ren_flush;
    end
    // 采样时机: 进入 D_DISP 时"上膛", 紧随其后的那个 posedge 采一次然后卸膛。
    // 那个 posedge 正是 DUT 采样的那一个 (TB 在 negedge 摆状态, DUT 在下一个
    // posedge 采), 两边看到的是同一个 lane_go —— 这样"记的账"必然等于"真派出去的"。
    // ⚠️ 不能无条件每拍锁存: 下一个 posedge 时状态已经切走了, 会把 0 覆盖上去。
    logic       d_arm = 1'b0;
    always @(posedge clk) if (d_arm) begin acc_q <= lane_go; d_arm <= 1'b0; end

    assign d0_vld = lane_go[0];    assign d1_vld = lane_go[1];    assign d2_vld = lane_go[2];
    assign d0_pc  = pl_pc[0];      assign d1_pc  = pl_pc[1];      assign d2_pc  = pl_pc[2];
    assign d0_chk = pl_chk[0];     assign d1_chk = pl_chk[1];     assign d2_chk = pl_chk[2];
    assign d0_lreg= pl_lreg[0];    assign d1_lreg= pl_lreg[1];    assign d2_lreg= pl_lreg[2];
    assign d0_rfwe= pl_rfwe[0];    assign d1_rfwe= pl_rfwe[1];    assign d2_rfwe= pl_rfwe[2];
    assign d0_opreg=pl_opreg[0];   assign d1_opreg=pl_opreg[1];   assign d2_opreg=pl_opreg[2];
    assign d0_s1preg=pl_s1[0];     assign d1_s1preg=pl_s1[1];     assign d2_s1preg=pl_s1[2];
    assign d0_ca  = pl_ca[0];      assign d1_ca  = pl_ca[1];      assign d2_ca  = pl_ca[2];
    assign d0_cop = pl_cop[0];     assign d1_cop = pl_cop[1];     assign d2_cop = pl_cop[2];
    assign d0_cimm= pl_cimm[0];    assign d1_cimm= pl_cimm[1];    assign d2_cimm= pl_cimm[2];
    assign d0_flg = pl_flg[0];     assign d1_flg = pl_flg[1];     assign d2_flg = pl_flg[2];
    assign d0_sqid= pl_sqi[0];     assign d1_sqid= pl_sqi[1];     assign d2_sqid= pl_sqi[2];
    assign d0_dpreg = h_got[0];    assign d1_dpreg = h_got[1];    assign d2_dpreg = h_got[2];

    integer      errors = 0;
    integer      n_done = 0, n_trap = 0, n_int = 0, n_flush = 0;
    integer      n_store = 0, n_csr = 0, n_mret = 0, n_misp = 0;
    integer      fl_state = 0;         // 1=T 2=F1 3=F2
    integer      head_wait = 0;
    integer      hcnt = 0;
    integer      lap_base = 0;      // 本圈起点 (上次冲刷时的 n_inst)
    logic [5:0]  rptr_prev = 6'd0;  // [核对] DUT 上一拍的 rptr
    logic        rptr_msb_prev = 1'b0;
    logic [1:0]  pop_prev = 2'd0;   // [核对] DUT 上一拍的 pop_n
    integer      dcnt = 0;

    // [诊断] 最近 64 条事件 (派遣/退休/冲刷), 第一次 retire_iid 错位时整段倒出来
    localparam integer LOGN = 64;
    string       evt [0:LOGN-1];
    integer      evt_i = 0;
    bit          log_dumped = 0;
    bit          log_dumped2 = 0;
    bit          trace_on = 0;
    integer      seed = 32'h1234_5678;
    integer      n_target = 200;
    bit          allow_exc, allow_int, allow_csr, allow_store, allow_branch;

    logic [2:0]  vldv;
    logic        trap_this;

    task automatic log_evt(input string e);
        begin
            evt[evt_i % LOGN] = e;
            evt_i = evt_i + 1;
        end
    endtask

    task automatic dump_log;
        begin
            $display("  ---- 最近 %0d 条事件 (旧 -> 新) ----", LOGN);
            for (int j = 0; j < LOGN; j = j + 1)
                if (evt_i > j) begin
                    int idx;
                    idx = (evt_i - LOGN + j) % LOGN;             // 环回取模 (Verilog 的 % 对负数结果不保证)
                    if (idx < 0) idx = idx + LOGN;
                    if (evt[idx] != "") $display("    %s", evt[idx]);
                end
            log_dumped = 1'b1;
        end
    endtask

    task automatic err(input string msg);
        begin
            errors = errors + 1;
            $display("[%0t] *** FAIL: %s", $time, msg);
        end
    endtask

    function automatic logic [4:0] flg_of(input integer i);
        begin flg_of = x_flg[i]; end
    endfunction

    // =======================================================================
    // 逐拍检查 (在 negedge; 用上一拍驱动的输入 + DUT 本拍输出)
    // =======================================================================
    task automatic check_cycle;
        integer i;
        integer csr_slot;
        logic   exp_free_k;
        begin
            vldv      = {cmv2, cmv1, cmv0};
            trap_this = 1'b0;
            csr_slot  = -1;
            for (int k = 0; k < 3; k = k + 1)
                if (vldv[k] && ((n_ret + k) < n_inst) && flg_of(n_ret+k)[`RTU_FLG_CSR])
                    csr_slot = k;

            // ---------- 0) 提交脉冲必须是前缀, 且与 retire_cnt 一致 ----------
            if (vldv[1] && !vldv[0]) err("退休脉冲跳号: 有槽1无槽0");
            if (vldv[2] && !vldv[1]) err("退休脉冲跳号: 有槽2无槽1");
            if (retire_cnt !== ({1'b0,vldv[2]} + {1'b0,vldv[1]} + {1'b0,vldv[0]}))
                err($sformatf("retire_cnt=%0d 与提交脉冲 %b 不符", retire_cnt, vldv));

            // ---------- 1) 陷阱 / 中断 ----------
            if (trap_vld) begin
                if (n_ret >= n_inst) err("trap_vld 但参考队列为空");
                else begin
                    i = n_ret;
                    trap_this = 1'b1;
                    if (trap_cause == `RTU_CAUSE_MTIP) begin
                        n_int = n_int + 1;
                        if (int_pending !== 1'b1) err("取了中断但 int_pending=0");
                        if (retire_cnt !== 2'd0)  err("取中断那一拍不该有退休计数");
                        if (vldv !== 3'b000)      err("取中断那一拍不该有提交脉冲");
                        if (flg_of(i)[`RTU_FLG_STORE] || flg_of(i)[`RTU_FLG_CSR] ||
                            flg_of(i)[`RTU_FLG_MRET])
                            err("中断落在了有副作用的提交点上");
                    end else begin
                        n_trap = n_trap + 1;
                        if (!x_exc[i]) err($sformatf("凭空陷入: 指令 %0d 没注入异常", i));
                        else if (trap_cause !== x_ec[i])
                            err($sformatf("陷阱 cause 不符: exp=%0d got=%0d", x_ec[i], trap_cause));
                        else if (trap_tval !== x_etv[i]) err("陷阱 tval 不符");
                        if (trap_epc !== x_pc[i]) err("陷阱 mepc 不是队头那条的 pc");
                        if (!(vldv[0] && !cmv1 && !cmv2)) err("陷阱那拍应只退到它为止");
                        if (cmena0 !== 1'b0) err("陷阱指令不该写 rd (ena 必须为 0)");
                        if (store_vld0 || csr_we || csr_rd_we)
                            err("陷阱指令不该产生任何副作用");
                    end
                    if (ifu_chg_vld !== 1'b1) err("陷阱/中断那拍必须发前端重定向");
                    if (ifu_chg_pc !== csr_tvec) err("陷阱/中断的重定向目标应为陷阱向量");
                end
            end

            // ---------- 2) 逐槽核对 ----------
            for (int k = 0; k < 3; k = k + 1) begin
                logic        ena, sw;
                logic [31:0] pc, val;
                logic [4:0]  rreg;
                if (vldv[k]) begin
                    if (k == 0) begin ena=cmena0; pc=cmpc0; rreg=cmreg0; val=cmval0; sw=store_vld0; end
                    else if (k == 1) begin ena=cmena1; pc=cmpc1; rreg=cmreg1; val=cmval1; sw=store_vld1; end
                    else begin ena=cmena2; pc=cmpc2; rreg=cmreg2; val=cmval2; sw=store_vld2; end

                    if ((n_ret + k) >= n_inst) err($sformatf("槽 %0d 报了退休但队列里没有这条", k));
                    else begin
                        i = n_ret + k;
                        if (!x_cmp[i]) err($sformatf("指令 %0d 没完成就退休了", i));
                        if (pc !== x_pc[i]) err($sformatf("指令 %0d pc 不符", i));
                        if (rreg !== x_lreg[i])
                            err($sformatf("指令 %0d reg 不符: exp=%0d got=%0d", i, x_lreg[i], rreg));
                        if (ena !== (x_rfwe[i] & ~trap_this))
                            err($sformatf("指令 %0d ena 不符: exp=%b got=%b",
                                          i, x_rfwe[i] & ~trap_this, ena));
                        if (ena) begin
                            if (flg_of(i)[`RTU_FLG_CSR]) begin
                                if (val !== csr_rdata) err("CSR 指令写 rd 的值必须等于 CSR 旧值");
                            end else if (val !== pf[x_dpr[i]])
                                err($sformatf("指令 %0d 提交值不符: exp=%08x got=%08x",
                                              i, pf[x_dpr[i]], val));
                        end
                        if (sw !== (flg_of(i)[`RTU_FLG_STORE] && !trap_this))
                            err($sformatf("指令 %0d store 脉冲不符", i));
                        if (sw) begin
                            if (!((k==0)?sq_rdy0:(k==1)?sq_rdy1:sq_rdy2))
                                err("store 数据没就绪却退休了");
                            if ((k==0?store_sqid0:(k==1?store_sqid1:store_sqid2)) !== x_sqi[i])
                                err("store sq_id 不符");
                            n_store = n_store + 1;
                        end
                        // 释放 old_preg: 脉冲与编号都必须逐位一致
                        exp_free_k = (x_rfwe[i] && (x_lreg[i] != 5'd0) &&
                                      (x_opr[i] >= 7'd32) && !trap_this);
                        begin
                            logic       fv_k;
                            logic [6:0] fp_k;
                            if (k==0) begin fv_k=ren_free_vld0; fp_k=ren_free_preg0; end
                            else if (k==1) begin fv_k=ren_free_vld1; fp_k=ren_free_preg1; end
                            else begin fv_k=ren_free_vld2; fp_k=ren_free_preg2; end
                            if (fv_k !== exp_free_k)
                                err($sformatf("指令 %0d 释放脉冲不符: exp=%b got=%b (old=%0d)",
                                              i, exp_free_k, fv_k, x_opr[i]));
                            if (fv_k && (fp_k !== x_opr[i]))
                                err($sformatf("指令 %0d 释放的编号不符: exp=%0d got=%0d",
                                              i, x_opr[i], fp_k));
                            if (fv_k && (fp_k < 7'd32)) err("释放了架构寄存器 p0..p31");
                            if (fv_k)
                                err($sformatf("释放了不在占用态的 p%0d (指令 %0d, trap=%b)",
                                              fp_k, i, trap_this));
                        end
                    end
                end
            end

            // ---------- 3) CSR 写口 ----------
            if (csr_slot >= 0) begin
                integer ii;
                logic [31:0] exp_w, src_v;
                ii = n_ret + csr_slot;
                if (csr_addr !== x_ca[ii]) err("CSR 写地址不符");
                src_v = x_cop[ii][2] ? {27'b0, x_cim[ii]} : csrsrc_rdata;
                exp_w = (x_cop[ii][1:0] == 2'b01) ? src_v :
                        (x_cop[ii][1:0] == 2'b10) ? (csr_rdata |  src_v) :
                                                    (csr_rdata & ~src_v);
                if (csr_we !== 1'b1) err("RW 类 CSR 指令必须写 CSR");
                if (csr_wdata !== exp_w) err($sformatf("CSR 写值不符: exp=%08x got=%08x", exp_w, csr_wdata));
                if (csr_rd_we !== (x_rfwe[ii] && (x_lreg[ii] != 5'd0)))
                    err("CSR 指令的 rd 写使能不符");
                if (csr_rd_we) begin
                    if (csr_rd_addr !== x_dpr[ii]) err("CSR rd 写地址不符");
                    if (csr_rd_wdata !== csr_rdata) err("CSR rd 写值必须等于旧值");
                end
                n_csr = n_csr + 1;
            end else if (csr_we || csr_rd_we) begin
                err("没有 CSR 指令退休却出现 CSR 写");
            end

            // ---------- 4) 误预测退休的重定向目标 ----------
            // (mret 也会发前端重定向, 但那条走 §5 的检查)
            if (ifu_chg_vld && !trap_vld && !mret_vld) begin
                integer mi;
                mi = -1;
                for (int k = 0; k < 3; k = k + 1)
                    if (vldv[k] && ((n_ret+k) < n_inst) &&
                        flg_of(n_ret+k)[`RTU_FLG_BRANCH] && x_msp[n_ret+k] && (mi < 0))
                        mi = n_ret + k;
                if (mi < 0) err("发了前端重定向, 但没有任何退休分支是误预测的");
                else if (ifu_chg_pc !== x_tgt[mi]) err("误预测重定向目标应为该分支的真实目标");
                n_misp = n_misp + 1;
            end

            // ---------- 5) mret ----------
            if (mret_vld) begin
                if ((n_ret >= n_inst) || !flg_of(n_ret)[`RTU_FLG_MRET]) err("mret_vld 但队头不是 mret");
                else if (ifu_chg_pc !== csr_mepc_i) err("mret 的重定向目标应为 mepc");
                n_mret = n_mret + 1;
            end

            // ---------- 5a) 影子窗口必须等于阵列的 rptr+0/1/2 (D5 的机制本身) ----------
            // 判退逻辑面对的是影子窗口; 它一旦落后于阵列, 症状就是"指令明明完成了
            // 却不退休" —— 而那是最难从外部现象反推的一类。
            if (!ren_flush) begin
                for (int k = 0; k < 3; k = k + 1) begin
                    logic        wv, wc;
                    logic [31:0] wp;
                    integer      ix;
                    ix = (dut.u_rob.rptr + k) & 6'h3f;
                    if (k == 0) begin wv = dut.u_rob.win_q0[`RTU_E_VLD]; wc = dut.u_rob.win_q0[`RTU_E_CMPLT]; wp = dut.u_rob.win_q0[`RTU_E_PC]; end
                    else if (k == 1) begin wv = dut.u_rob.win_q1[`RTU_E_VLD]; wc = dut.u_rob.win_q1[`RTU_E_CMPLT]; wp = dut.u_rob.win_q1[`RTU_E_PC]; end
                    else begin wv = dut.u_rob.win_q2[`RTU_E_VLD]; wc = dut.u_rob.win_q2[`RTU_E_CMPLT]; wp = dut.u_rob.win_q2[`RTU_E_PC]; end
                    // ⚠️ 只在窗口**已经有这一项**时比: 阵列新建的那一项要等"补空"路径
                    //    下一拍才进窗口 (D5 的设计如此), 空窗 vs 有效阵列是正常的中间态。
                    if (wv && ((wc !== dut.u_rob.rob_q[ix][`RTU_E_CMPLT]) ||
                               (wp !== dut.u_rob.rob_q[ix][`RTU_E_PC])))
                        err($sformatf("影子窗口[%0d] 与阵列[%0d] 不符: win(vld=%b cmpl=%b pc=%08x) vs arr(vld=%b cmpl=%b pc=%08x)",
                                      k, ix, wv, wc, wp,
                                      dut.u_rob.rob_q[ix][`RTU_E_VLD],
                                      dut.u_rob.rob_q[ix][`RTU_E_CMPLT],
                                      dut.u_rob.rob_q[ix][`RTU_E_PC]));
                end
            end

            // ---------- 6) 分配器 ----------
            if (alloc_vld0 && (alloc0 < 7'd32)) err("分配器给出架构寄存器");
            if (alloc_vld1 && (alloc1 < 7'd32)) err("分配器给出架构寄存器");
            if (alloc_vld2 && (alloc2 < 7'd32)) err("分配器给出架构寄存器");
            if (alloc_vld0 && alloc_vld1 && (alloc0 == alloc1)) err("两路分配撞车");
            if (alloc_vld0 && alloc_vld2 && (alloc0 == alloc2)) err("两路分配撞车");
            if (alloc_vld1 && alloc_vld2 && (alloc1 == alloc2)) err("两路分配撞车");
            // 不得把**任何在途指令的 dst_preg** 再发一遍 —— 这条才是"自由池没漏干"
            // 的本质, 而且与 TB 对两拍握手的相位建模无关 (比"不得是上一拍刚发出去的
            // 那个"稳健得多: 后者要求 TB 把 T/T+1 的相位对得分毫不差, 很容易假报)。
            for (int ii = n_ret; ii < n_inst; ii = ii + 1) begin
                if ((alloc_vld0 && (alloc0 == x_dpr[ii])) ||
                    (alloc_vld1 && (alloc1 == x_dpr[ii])) ||
                    (alloc_vld2 && (alloc2 == x_dpr[ii])))
                    err($sformatf("分配器把在途指令 %0d 的 dst_preg (p%0d) 又发了一遍",
                                  ii, x_dpr[ii]));
            end


            // ---------- 8) 冲刷时间线 (§6.3 ①) ----------
            case (fl_state)
                0: begin
                    if (ifu_chg_vld) begin
                        fl_state  = 1;
                        head_wait = 0;
                        n_flush   = n_flush + 1;
                    end else if (backend_flush || ren_flush)
                        err("没有触发却出现冲刷信号");
                end
                1: begin
                    if (!backend_flush) err("冲刷 T+1 拍应有 rtu_backend_flush");
                    fl_state = 2;
                end
                2: begin
                    if (!ren_flush) err("冲刷 T+2 拍应有 rtu_ren_flush");
                    if (!ren_recover_vld) err("ren_flush 那拍必须同时给 recover_vld");
                    for (int l = 0; l < 32; l = l + 1)
                        if (ren_recover_map[7*l +: 7] !== ref_amt[l]) begin
                            err($sformatf("AMT[%0d] 广播不符: exp=%0d got=%0d",
                                          l, ref_amt[l], ren_recover_map[7*l +: 7]));
                            if (!log_dumped) dump_log();
                        end
                    fl_state = 3;
                end
                default: begin
                    if (backend_flush || ren_flush) err("冲刷 T+3 拍应该已经结束了");
                    fl_state = 0;
                end
            endcase
            if ((fl_state != 0) && !disp_stall) err("冲刷窗口内 disp_stall 必须保持");
            if (beu_mask !== (fl_state != 0)) err("beu_flush_chgflw_mask 与冲刷窗口不符");

            // ---------- 9) 活性 ----------
            if ((fl_state == 0) && !trap_vld && (n_ret < n_inst)) begin
                if (x_cmp[n_ret] && !flg_of(n_ret)[`RTU_FLG_STORE] && !int_pending)
                    head_wait = head_wait + 1;
                else head_wait = 0;
                if (head_wait > 8) err($sformatf("指令 %0d 早就完成却不退休", n_ret));
            end else head_wait = 0;

            if (trace_on && (n_inst > 17) && (n_inst < 26))
                $display("        ARR occ=%0d rptr=%0d cptr=%b iid0..7=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d vld=%b%b%b%b%b%b%b%b | TB n_inst=%0d n_ret=%0d",
                         dut.u_rob.occ_q, dut.u_rob.rptr, dut.u_rob.cptr_oh[7:0],
                         {dut.u_rob.rob_q[0][`RTU_E_WRAP],6'd0}, {dut.u_rob.rob_q[1][`RTU_E_WRAP],6'd1},
                         {dut.u_rob.rob_q[2][`RTU_E_WRAP],6'd2}, {dut.u_rob.rob_q[3][`RTU_E_WRAP],6'd3},
                         {dut.u_rob.rob_q[4][`RTU_E_WRAP],6'd4}, {dut.u_rob.rob_q[5][`RTU_E_WRAP],6'd5},
                         {dut.u_rob.rob_q[6][`RTU_E_WRAP],6'd6}, {dut.u_rob.rob_q[7][`RTU_E_WRAP],6'd7},
                         dut.u_rob.rob_q[0][`RTU_E_VLD], dut.u_rob.rob_q[1][`RTU_E_VLD],
                         dut.u_rob.rob_q[2][`RTU_E_VLD], dut.u_rob.rob_q[3][`RTU_E_VLD],
                         dut.u_rob.rob_q[4][`RTU_E_VLD], dut.u_rob.rob_q[5][`RTU_E_VLD],
                         dut.u_rob.rob_q[6][`RTU_E_VLD], dut.u_rob.rob_q[7][`RTU_E_VLD],
                         n_inst, n_ret);

            if (trace_on && (n_inst > 17) && (n_inst < 26))
                $display("        TRK n_inst=%0d n_ret=%0d occ=%0d flst=%0d stall=%b disp=%b%b%b ifuchg=%b",
                         n_inst, n_ret, dut.u_rob.occ_q, fl_state, disp_stall,
                         d0_vld, d1_vld, d2_vld, ifu_chg_vld);

            if (trace_on)
                $display("[%0t] fl=%0d ret=%0d/%0d vld=%b cnt=%0d trap=%b stall=%b free=%0d",
                         $time, fl_state, n_ret, n_inst, vldv, retire_cnt, trap_vld,
                         disp_stall, free_cnt_o);
        end
    endtask

    // =======================================================================
    // 参考模型推进 (等价于 DUT 在一个时钟边沿做的事)
    // =======================================================================
    task automatic ref_retire;
        integer i;
        begin
            vldv = ret_vld_q;                    // 用 posedge 锁存的那一份 (与 DUT 同刻)
            if (ret_trap_q) begin
                log_evt($sformatf("TRAP n_ret=%0d n_inst=%0d cause=%0d", n_ret, n_inst, ret_tcause_q));
                if (ret_tcause_q == `RTU_CAUSE_MTIP) begin
                    n_ret = n_inst;                       // 队头被 squash, 后面全丢
                end else if (vldv[0]) begin
                    if (x_rfwe[n_ret] && (x_lreg[n_ret] != 5'd0))
                        ref_busy[x_dpr[n_ret]] = 1'b0;    // 分配过但没写 -> 回 FREE
                    n_ret = n_ret + 1;
                end
            end else begin
                for (int k = 0; k < 3; k = k + 1) begin
                    if (vldv[k]) begin
                        i = n_ret;
                        if (x_rfwe[i] && (x_lreg[i] != 5'd0)) begin
                            if (x_opr[i] >= 7'd32) ref_busy[x_opr[i]] = 1'b0;
                            ref_busy[x_dpr[i]] = 1'b1;
                            ref_amt[x_lreg[i]] = x_dpr[i];
                        end
                        log_evt($sformatf("RET  inst=%0d iid=%0d rptr=%0d lreg=%0d dpr=%0d rfwe=%b",
                                          i, x_iid[i], dut.u_rob.rptr, x_lreg[i], x_dpr[i], x_rfwe[i]));
                        n_ret = n_ret + 1;
                        n_done = n_done + 1;
                    end
                end
            end

            if (csr_we)    csr_file[csr_addr] = csr_wdata;
            if (csr_rd_we) pf[csr_rd_addr]    = csr_rd_wdata;

            if (ret_flush_q) begin
                log_evt($sformatf("FLUSH n_ret=%0d n_inst=%0d (都归零重来)", n_ret, n_inst));
                lap_base = n_inst;
                n_ret    = n_inst;
                ref_pend = 96'd0;
                tb_cptr  = 6'd0;
                tb_cmsb  = 1'b0;
                // ⚠️ 冲刷只把**在途的**(ALLOC/WF_ALLOC)放回自由池; **架构映射表里的
                //    那批 preg 依然被占用** (AMT 只反映已退休的映射, 冲刷不动它)。
                //    模型若在这里一律清零, 之后某条指令释放它的 old_preg (正是某个
                //    架构映射) 就会被误报成"释放了不在占用态的 preg"。
                ref_busy = 96'd0;
                for (int l = 0; l < 32; l = l + 1) ref_busy[ref_amt[l]] = 1'b1;
            end
        end
    endtask

    // =======================================================================
    // 激励
    // =======================================================================
    // 生成一份新计划 (D_IDLE→D_REQ 那一步调用)
    task automatic gen_plan;
        int n, r;
        begin
            n = {$urandom} % 4;
            pl_n = n;
            for (int k = 0; k < 3; k = k + 1) begin
                logic [4:0] f;
                f = 5'd0;
                if (k < n) begin
                    r = {$urandom} % 100;
                    if (allow_store && r < 20)        f[`RTU_FLG_STORE]  = 1'b1;
                    else if (allow_branch && r < 40)  f[`RTU_FLG_BRANCH] = 1'b1;
                    else if (allow_csr && r < 50)     f[`RTU_FLG_CSR]    = 1'b1;
                    else if (r < 55)                  f[`RTU_FLG_MRET]   = 1'b1;
                    pl_flg[k] = f | ((({$urandom} % 100) < 8) ? (5'b1 << `RTU_FLG_INTMASK) : 5'd0);
                    pl_rfwe[k]  = !(f[`RTU_FLG_STORE] || f[`RTU_FLG_BRANCH] || f[`RTU_FLG_MRET]);
                    // ⚠️ 不写寄存器的指令必须把 dst_lreg 给 **0** (§6.1)。
                    //    给它一个非 0 的垃圾值, RTU 就会按"这条要写 rd"去申请/分配 preg;
                    //    而退休时 `wr_eff = rf_we & lreg!=0` 又不成立, 那个 preg 既不转
                    //    ARCH 也不释放 —— **漏掉**, 之后被当空闲再发出去 (踩过: 单测台
                    //    第一版就是这么把自由池搅乱的, 表象是 AMT/iid 到处对不上)。
                    pl_lreg[k]  = pl_rfwe[k] ? ({$urandom} % 32) : 5'd0;
                    // old_preg == 该 lreg **当前的架构映射**: 真机里它一定是"以前发出去、
                    // 现在正被占用的"那个 preg。随手编一个没分配过的, 退休释放就会往
                    // 自由池里灌一个莫须有的编号 (池子放水 → 之后又把它发给别人)。
                    // 首次写某个 lreg 时它是 <32 的初始映射, 正好覆盖"永不回收"那条门控。
                    pl_opreg[k] = ref_amt[pl_lreg[k]];
                    pl_pc[k]    = {$urandom};
                    pl_chk[k]   = {$urandom} % (1 << 25);
                    pl_val[k]   = {$urandom};
                    pl_s1[k]    = {$urandom} % 96;
                    pl_ca[k]    = {$urandom} % 4096;
                    pl_cop[k]   = 3'b001 + ({$urandom} % 3);
                    pl_cimm[k]  = {$urandom} % 32;
                    pl_sqi[k]   = {$urandom} % 8;
                end else begin
                    pl_flg[k]=0; pl_lreg[k]=0; pl_rfwe[k]=0; pl_opreg[k]=0;
                    pl_pc[k]=0;  pl_chk[k]=0;  pl_val[k]=0;  pl_s1[k]=0;
                    pl_ca[k]=0;  pl_cop[k]=1;  pl_cimm[k]=0; pl_sqi[k]=0;
                end
            end
        end
    endtask

    function automatic logic [6:0] iid_at(input int k);
        logic [5:0] cc;
        logic       ww;
        begin
            cc = (tb_cptr + k) & 6'h3f;
            ww = tb_cmsb ^ (((tb_cptr + k) > 63) ? 1'b1 : 1'b0);
            iid_at = {ww, cc};
        end
    endfunction

    task automatic step_cptr(input int nd);
        begin
            if (nd > 0) begin
                if ((tb_cptr + nd) > 63) tb_cmsb = ~tb_cmsb;
                tb_cptr = (tb_cptr + nd) & 6'h3f;
            end
        end
    endtask

    // 把"被接受的车道"记进参考流 + 推进指针镜像
    task automatic dispatch_record(input int nd);
        integer i;
        begin
            for (int k = 0; k < nd; k = k + 1) begin
                i = n_inst;
                x_pc[i]=cp_pc[k];     x_val[i]=cp_val[k];   x_lreg[i]=cp_lreg[k];
                x_rfwe[i]=cp_rfwe[k]; x_flg[i]=cp_flg[k];   x_sqi[i]=cp_sqi[k];
                x_dpr[i]=cp_got[k];
                x_opr[i]=cp_opreg[k]; x_iid[i]=iid_at(k);
                x_ca[i]=cp_ca[k];     x_cop[i]=cp_cop[k];   x_cim[i]=cp_cimm[k];
                x_cmp[i]=1'b0; x_exc[i]=1'b0; x_ec[i]=5'd0; x_etv[i]=32'd0;
                x_tgt[i]=32'd0; x_tkn[i]=1'b0; x_msp[i]=1'b0; x_rsv[i]=1'b0;
                n_inst = n_inst + 1;
            end
            if (nd > 0)
                log_evt($sformatf("DISP n_inst=%0d nd=%0d iid0=%0d got0=%0d lreg0=%0d",
                                  n_inst, nd, iid_at(0), cp_got[0], cp_lreg[0]));
            step_cptr(nd);
            // 记账后立刻核对指针镜像与 DUT 的创造指针 —— 两者必须一致,
            // 不一致就说明"这一拍记的条数"与实际派出去的条数对不上。
            if (!dut.u_rob.cptr_oh[tb_cptr])
                err($sformatf("指针镜像与 DUT 不符: 记了 %0d 条后 TBmir=%0d, 但 DUT 的创造指针不在那儿 (cptr_oh=%b)",
                              nd, tb_cptr, dut.u_rob.cptr_oh[15:0]));
        end
    endtask

    // 状态机推进 + 流水账 (每拍一次, 必须排在 check_cycle 之后 —— 它要先看到本拍的值)
    task automatic disp_step;
        int nd;
        begin
            // ---- 结算上一拍摆上口的派遣 (与状态机走到哪个分支无关!) ----
            // ⚠️ 这一步**必须**独立于状态路径: 有一次派遣自己引出的 csr_inflight 会把
            //    状态机顶回 IDLE, 结算若只写在 D_REQ 分支里, 那次派遣就永远记不上账
            //    —— 参考流是空的, 于是没有完成信号, CSR 槽再也放不掉 (踩过的死锁)。
            if (commit_pending && !ren_flush) begin
                nd = 0;
                for (int k = 0; k < 3; k = k + 1) begin
                    if (acc_q[k]) nd = nd + 1;
                    if (cp_gotv[k] && acc_q[k]) ref_busy[cp_got[k]] = 1'b1;
                    if (cp_gotv[k]) ref_pend[cp_got[k]] = 1'b0;   // 没派成的还回池子
                end
                dispatch_record(nd);
                commit_pending = 1'b0;
            end

            if (ren_flush) begin
                // 冲刷: 挂着的编号由 DUT 在 FLUSH_2 放回, 模型里一并清掉
                for (int k = 0; k < 3; k = k + 1)
                    if (h_gotv[k]) ref_pend[h_got[k]] = 1'b0;
                h_gotv = 3'd0; pl_n = 0; cp_n = 0; commit_pending = 1'b0;
                d_arm = 1'b0;
                dstate = D_IDLE;
            end else begin
                case (dstate)
                    D_IDLE: begin
                        if (!disp_stall) begin
                            gen_plan();                 // 第一份计划
                            dstate = D_REQ;
                        end
                    end
                    D_REQ: begin
                        // (a2) 请求是上一拍发出去的, 本拍得重新看一次 stall:
                        //      比如 CSR 单槽被占 (csr_inflight) 时**不许**再派新指令 ——
                        //      否则第二条 CSR 会覆盖单槽, 第一条退休时读到别人的字段。
                        //      此时这份计划连同刚发出去的编号一起作废 (编号由 DUT 放回)。
                        if (disp_stall) begin
                            pl_n = 0; h_gotv = 3'd0;
                            dstate = D_IDLE;
                        end else begin
                        // (b) 再锁存**本份**计划拿到的编号
                        h_got[0] = alloc_vld0 ? alloc0 : 7'd0;
                        h_got[1] = alloc_vld1 ? alloc1 : 7'd0;
                        h_got[2] = alloc_vld2 ? alloc2 : 7'd0;
                        h_gotv   = {alloc_vld2, alloc_vld1, alloc_vld0};
                        for (int k = 0; k < 3; k = k + 1)
                            if (h_gotv[k]) ref_pend[h_got[k]] = 1'b1;
                        d_arm  = 1'b1;
                        dstate = D_DISP;
                        end
                    end
                    default: begin                     // D_DISP: 本拍把派遣摆在口上
                        cp_n       = pl_n;             // 留给下一拍结算
                        cp_got[0]  = h_got[0];
                        cp_got[1]  = h_got[1];
                        cp_got[2]  = h_got[2];
                        cp_gotv    = h_gotv;
                        for (int k = 0; k < 3; k = k + 1) begin
                            cp_lreg[k]=pl_lreg[k]; cp_pc[k]=pl_pc[k];   cp_chk[k]=pl_chk[k];
                            cp_rfwe[k]=pl_rfwe[k]; cp_flg[k]=pl_flg[k]; cp_opreg[k]=pl_opreg[k];
                            cp_s1[k]=pl_s1[k];     cp_ca[k]=pl_ca[k];   cp_cop[k]=pl_cop[k];
                            cp_cimm[k]=pl_cimm[k]; cp_sqi[k]=pl_sqi[k]; cp_val[k]=pl_val[k];
                        end
                        commit_pending = 1'b1;
                        if (disp_stall) begin
                            pl_n = 0; dstate = D_IDLE; // stall 时不再往下发
                        end else begin
                            gen_plan();                // 下一份 (下一拍在 D_REQ 里请求)
                            dstate = D_REQ;
                        end
                    end
                endcase
            end
        end
    endtask

    // 记账**之后**才能比的检查 (指针位置 / iid 约定):
    // ⚠️ 它们必须跑在 ref_retire 之后 —— 退休脉冲是 posedge 锁存的, 而 DUT 的 rptr
    //    在同一个边沿就前进了; 若在记账前比, 参考流永远"慢一拍", 于是每一拍都误报。
    task automatic check_after_retire;
        integer i;
        begin
        // ---------- 4a) DUT 的 rptr 每拍只能前进 pop_n (除冲刷复位之外不许跳) ----------
        // ⚠️ 用**锁存**的冲刷标志: 冲刷脉冲在 FLUSH_2 那拍, 指针复位就在同一个边沿 ——
        //    到了下一拍 negedge, 实时的 ren_flush 已经回 0, 但指针确实"跳"过,
        //    用实时信号做守卫会漏掉那一拍 (踩过)。
        if (!ret_flush_q) begin
            logic [6:0] exp_rp;
            // 上拍读到的 rptr + **本拍锁存的** pop (即结束上一拍那个边沿上用的值)
            exp_rp = {rptr_msb_prev, rptr_prev} + {5'b0, ret_cnt_q};
            if ({dut.u_rob.rptr_msb, dut.u_rob.rptr} !== exp_rp[6:0])
                err($sformatf("rptr 推进异常: 上拍=%0d.%0d pop=%0d, 本拍 DUT=%0d.%0d (应为 %0d) | 本拍内部: pop_n=%0d nxt=%0d flushlvl=%b flushing=%b",
                              rptr_msb_prev, rptr_prev, ret_cnt_q,
                              dut.u_rob.rptr_msb, dut.u_rob.rptr, exp_rp[6:0],
                              dut.u_rob.pop_n, dut.u_rob.nxt_rptr,
                              dut.u_rob.flush_lvl, dut.u_rob.flushing));
        end
        rptr_prev     = dut.u_rob.rptr;
        rptr_msb_prev = dut.u_rob.rptr_msb;
        pop_prev      = ret_cnt_q;   // 用 posedge 锁存的那份 (DUT 边沿上用的就是它)

        // ---------- 4b) 退休指针: DUT 的 {msb,rptr} 必须等于"本圈已退休条数" ----------
        // 这是把参考流与 DUT 的退休位置直接钉在一起的不变量 (带本圈基准, 免得把
        // 全局指令号与圈内位置混在一起)。它一旦不发散, 后面那些 iid/完成信号
        // 的对齐问题就不可能存在。
        begin
            integer since;
            since = n_ret - lap_base;
            if ({dut.u_rob.rptr_msb, dut.u_rob.rptr} !== since[6:0]) begin
                err($sformatf("退休位置不符: DUT=%0d.%0d, 本圈已退 %0d 条 (n_ret=%0d lap_base=%0d, flst=%0d)",
                              dut.u_rob.rptr_msb, dut.u_rob.rptr, since,
                              n_ret, lap_base, fl_state));
                if (!log_dumped2) begin dump_log(); log_dumped2 = 1'b1; end
            end
        end

        // ---------- 5b) iid 约定 ----------
        // ⚠️ 冲刷当拍 (ren_flush) 不比: DUT 在那一拍把 rptr 归零重新开始, 而参考流
        //    要到同一拍稍后才重新对齐 —— 在这一拍比必然误报 (踩过: 这一条曾独占
        //    失败总数的绝大部分)。
        if ((n_ret < n_inst) && !ren_flush && (fl_state == 0)) begin
            if (beu_retire_iid !== x_iid[n_ret]) begin
                err($sformatf("retire_iid 不符: exp=%0d got=%0d (n_ret=%0d, dutrptr=%0d, flst=%0d)",
                              x_iid[n_ret], beu_retire_iid, n_ret, dut.u_rob.rptr, fl_state));
                if (!log_dumped2) begin dump_log(); log_dumped2 = 1'b1; end
            end
        end
        end
    endtask

    task automatic gen_complete;
        integer done_cnt;
        int     pick;
        int unsigned span;
        begin
            cv0=0; cv1=0; cv2=0; cv3=0; cv4=0;
            done_cnt = 0;
            for (int tries = 0; tries < 12; tries = tries + 1) begin
                if (n_ready <= n_ret) break;
                span = n_ready - n_ret;
                pick = n_ret + ({$urandom} % span);
                if (x_cmp[pick]) continue;
                case (done_cnt)
                    0: begin cv0=1; ci0=x_iid[pick]; end
                    1: begin cv1=1; ci1=x_iid[pick]; end
                    2: begin cv2=1; ci2=x_iid[pick]; end
                    3: begin cv3=1; ci3=x_iid[pick]; end
                    default: begin cv4=1; ci4=x_iid[pick]; end
                endcase
                x_cmp[pick] = 1'b1;
                // 完成的同时把结果写进物理寄存器堆 (模拟执行单元写 PRF)
                if (x_rfwe[pick] && (x_lreg[pick] != 5'd0) && !x_flg[pick][`RTU_FLG_CSR])
                    pf[x_dpr[pick]] = x_val[pick];
                done_cnt = done_cnt + 1;
                if (done_cnt == 5) break;
            end
        end
    endtask

    task automatic gen_resolve;
        int unsigned span;
        int pick;
        begin
            rsv_vld = 0;
            if (n_ready <= n_ret) return;
            span = n_ready - n_ret;
            pick = n_ret + ({$urandom} % span);
            if (x_flg[pick][`RTU_FLG_BRANCH] && !x_rsv[pick]) begin
                rsv_vld = 1'b1;
                rsv_iid = x_iid[pick];
                rsv_taken = {$urandom} % 2;
                rsv_misp  = (({$urandom} % 100) < 60);
                rsv_tgt   = {$urandom};
                x_rsv[pick] = 1'b1;
                x_tkn[pick] = rsv_taken;
                x_msp[pick] = rsv_misp;
                x_tgt[pick] = rsv_tgt;
            end
        end
    endtask

    task automatic gen_expt;
        int unsigned span;
        int pick;
        begin
            ex_vld = 0;
            if (!allow_exc || (n_ready <= n_ret) || (fl_state != 0)) return;
            if (({$urandom} % 100) >= 30) return;
            span = n_ready - n_ret;
            pick = n_ret + ({$urandom} % span);
            if (x_exc[pick]) return;
            ex_vld   = 1'b1;
            ex_iid   = x_iid[pick];
            ex_cause = 5'd2 + ({$urandom} % 10);
            ex_tval  = {$urandom};
            x_exc[pick] = 1'b1;
            x_ec[pick]  = ex_cause;
            x_etv[pick] = ex_tval;
        end
    endtask

    // =======================================================================
    // 主流程
    // =======================================================================

    task automatic run_cycle(inout integer cyc);
        int nd;
        begin
            @(negedge clk);

            check_cycle();      // 用"上一拍驱动的输入 + 本拍输出"检查

            // 状态机推进 + 流水账。必须排在 check_cycle 之后: check_cycle 要在
            // dstate==D_DISP 那拍核对"摆上口的 vld"与 DUT 内部接受的 disp_acc 是否一致。
            disp_step();

            ref_retire();       // 本拍的退休 / 提交 / 冲刷

            check_after_retire();   // 指针位置 / iid 约定 (必须在记账之后比)

            // 本拍刚派出去的不能同拍给完成信号 (同一个边沿, 表项还没建出来)
            n_ready = n_inst;

            // 下一拍的完成 / 解析 / 异常 / 存储队列 / 中断
            gen_complete();
            gen_resolve();
            gen_expt();
            int_pending = allow_int && (({$urandom} % 100) < 5);
            sq_rdy0 = (({$urandom} % 100) < 90);
            sq_rdy1 = (({$urandom} % 100) < 90);
            sq_rdy2 = (({$urandom} % 100) < 90);
            sq_stall = (({$urandom} % 100) < 5);

            cyc = cyc + 1;
        end
    endtask

    initial begin
        cv0=0; cv1=0; cv2=0; cv3=0; cv4=0; ci0=0; ci1=0; ci2=0; ci3=0; ci4=0;
        rsv_vld=0; rsv_iid=0; rsv_taken=0; rsv_misp=0; rsv_tgt=0;
        ex_vld=0; ex_iid=0; ex_cause=0; ex_tval=0;
        sq_rdy0=1; sq_rdy1=1; sq_rdy2=1; sq_stall=0;
        int_pending=0;
        csr_tvec = 32'h0000_1000;
        csr_mepc_i = 32'h0000_2000;
        dstate = D_IDLE; pl_n = 0; h_gotv = 3'd0; cp_n = 0; commit_pending = 1'b0;
        for (int k = 0; k < 3; k = k + 1) begin
            h_got[k]=0;
            pl_lreg[k]=0; pl_pc[k]=0; pl_chk[k]=0; pl_rfwe[k]=0; pl_flg[k]=0;
            pl_opreg[k]=0; pl_s1[k]=0; pl_ca[k]=0; pl_cop[k]=1; pl_cimm[k]=0;
            pl_sqi[k]=0; pl_val[k]=0;
        end
        cycle = 0;

        if ($test$plusargs("TRACE")) trace_on = 1;
        void'($value$plusargs("SEED=%d", seed));
        void'($value$plusargs("NINSTR=%d", n_target));
        void'($urandom(seed));

        for (int a = 0; a < 4096; a = a + 1) csr_file[a] = {$urandom};
        for (int p = 0; p < 96;   p = p + 1) pf[p] = {$urandom};
        for (int l = 0; l < 32;   l = l + 1) ref_amt[l] = l[6:0];

        $display("==================================================");
        $display("  RTU 单元 TB: seed=%0d 目标指令数=%0d", seed, n_target);

        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // 阶段 A: 安静 (无异常/中断), 压实基本退休通路
        allow_exc=0; allow_int=0; allow_csr=1; allow_store=1; allow_branch=1;
        while ((n_inst < n_target/3) && (cycle < 20000)) run_cycle(cycle);

        // 阶段 B: 打开异常
        allow_exc=1; allow_int=0;
        while ((n_inst < (2*n_target)/3) && (cycle < 40000)) run_cycle(cycle);

        // 阶段 C: 全开
        allow_exc=1; allow_int=1;
        while ((n_inst < n_target) && (cycle < 80000)) run_cycle(cycle);

        // 收尾: 关掉激励, 把在途的排干
        allow_exc=0; allow_int=0; allow_csr=0; allow_store=0; allow_branch=0;
        for (int t = 0; t < 400; t = t + 1) run_cycle(cycle);

        $display("--------------------------------------------------");
        $display("  派遣 %0d 条 / 退休 %0d 条 / 冲刷 %0d 次 / 周期 %0d",
                 n_inst, n_done, n_flush, cycle);
        $display("  陷阱 %0d / 中断 %0d / mret %0d / 误预测 %0d / store %0d / CSR %0d",
                 n_trap, n_int, n_mret, n_misp, n_store, n_csr);
        if (n_inst < n_target) err($sformatf("活性不足: 只派了 %0d 条 (目标 %0d)", n_inst, n_target));
        if (n_trap  == 0) err("一次同步异常都没覆盖到");
        if (n_int   == 0) err("一次中断都没覆盖到");
        if (n_flush == 0) err("一次冲刷都没覆盖到");
        if (n_store == 0) err("一次 store 退休都没覆盖到");
        if (n_csr   == 0) err("一次 CSR 退休都没覆盖到");
        if (n_mret  == 0) err("一次 mret 都没覆盖到");

        if (errors == 0) begin
            $display("  RTU UNIT: ALL PASS");
            $display("==================================================");
            $finish;
        end else begin
            $display("  RTU UNIT: %0d ERRORS", errors);
            $display("==================================================");
            $fatal(1, "rtu unit test failed");
        end
    end

endmodule
