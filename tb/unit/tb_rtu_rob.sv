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
    logic [6:0]  x_s1  [0:MAXI-1];      // CSR 的 rs1_preg (判"写不写 CSR"用)
    logic [2:0]  x_sqi [0:MAXI-1];
    logic [31:0] x_tgt [0:MAXI-1];
    logic        x_tkn [0:MAXI-1];
    logic        x_msp [0:MAXI-1];
    logic        x_rsv [0:MAXI-1];
    logic [1:0]  x_src [0:MAXI-1];      // [诊断] old_preg 的来源
    integer      x_srcidx [0:MAXI-1];

    // ⚠️ 这里**故意不维护**"哪些 preg 被占用"的位图。
    //    它是从 参考流 + AMT + 派发中的编号 派生出来的量, 维护第二份必然与它们打架
    //    (单测台为此debug 了很多轮)。占用与否一律**直接问 DUT 自己的状态表**,
    //    或者从参考流现场算 —— 两者都与相位无关。
    logic [6:0]  ref_amt [0:31];       // 参考模型自己维护的 AMT
    // 重命名级的**投机映射表 RAT** (§6: "谁负责什么" 里写死是重命名级的职责)。
    // 派遣时写、冲刷时用 `rtu_ren_recover_map` (= ref_amt) 整表覆盖 —— 契约怎么
    // 描述对面那一侧, 参考模型就怎么维护, 不再去"重建"它。
    logic [6:0]  ref_rat [0:31];

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
    logic [1:0]  pl_src  [0:2];
    integer      pl_srcidx[0:2];

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
    logic [1:0]  cp_src  [0:2];
    integer      cp_srcidx[0:2];
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

    logic [31:0] ret_epc_q = 32'd0, ret_tval_q = 32'd0;
    logic        ret_mret_q = 1'b0, ret_iflush_q = 1'b0, ret_bflush_q = 1'b0;
    logic [31:0] ret_ipc_q = 32'd0;
    logic [2:0]  ret_sw_q = 3'd0;
    logic [8:0]  ret_sqid_q = 9'd0;
    logic        ret_csrwe_q = 1'b0, ret_csrrd_q = 1'b0;
    logic [11:0] ret_csra_q = 12'd0;
    logic [31:0] ret_csrw_q = 32'd0, ret_csrrw_q = 32'd0;
    logic [6:0]  ret_csrra_q = 7'd0;
    logic [2:0]  x_retarch_q = 3'd0, x_retkill_q = 3'd0, x_retfree_q = 3'd0;
    logic [6:0]  x_dstp_q [0:2];
    logic        x_flvl_q = 1'b0;
    logic [6:0]  x_oldp_q [0:2];
    logic [2:0]  ret_fv_q = 3'd0;
    logic [20:0] ret_fp_q = 21'd0;
    // ⚠️⚠️ 这里必须**整套**锁: 脉冲 + 载荷 + 检查要用到的输入 (sq_rdy/int_pending/CSR 读数据)。
    //    只锁脉冲、载荷读实时值 = 两帧混用 —— 而且混出来的那一帧**根本不存在**:
    //    在 negedge N 直接读的组合值 = f(边沿后的状态, 边沿前的输入), 而 DUT 在
    //    posedge N+5 用的是**同一状态 + 本拍刚摆上去的输入**。两者只在"TB 这一拍
    //    没有改动任何输入"时才相等。踩到的实例: 610000 拍读到 vld=011/pop=2, 但同一拍
    //    TB 把 sq_rdy0 摇成 0 (槽 0 是 store) ⇒ DUT 真正提交 0 条, 参考流于是永远
    //    慢一条, 之后成片失败。
    //    唯一的自洽帧是"刚过去的那个 posedge 做了什么" —— 也就是这一整套 ret_*_q。
    logic [31:0] ret_pc_q  [0:2];
    logic [4:0]  ret_reg_q [0:2];
    logic [31:0] ret_val_q [0:2];
    logic [2:0]  ret_ena_q = 3'd0;
    logic [2:0]  ret_rdy_q = 3'd0;
    logic        ret_ipend_q = 1'b0;
    logic [31:0] ret_csrrdata_q = 32'd0, ret_csrsrc_q = 32'd0;
    always @(posedge clk) begin
        ret_vld_q    <= {cmv2, cmv1, cmv0};
        ret_cnt_q    <= retire_cnt;
        ret_trap_q   <= trap_vld;
        ret_tcause_q <= trap_cause;
        ret_flush_q  <= ren_flush;
        ret_epc_q    <= trap_epc;    ret_tval_q <= trap_tval;
        ret_mret_q   <= mret_vld;
        ret_iflush_q <= ifu_chg_vld; ret_ipc_q  <= ifu_chg_pc;
        ret_bflush_q <= backend_flush;
        ret_sw_q     <= {store_vld2, store_vld1, store_vld0};
        ret_sqid_q   <= {store_sqid2, store_sqid1, store_sqid0};
        ret_csrwe_q  <= csr_we;      ret_csrrd_q <= csr_rd_we;
        ret_csra_q   <= csr_addr;    ret_csrw_q  <= csr_wdata;
        ret_csrrw_q  <= csr_rd_wdata; ret_csrra_q <= csr_rd_addr;
        ret_fv_q     <= {ren_free_vld2, ren_free_vld1, ren_free_vld0};
        ret_fp_q     <= {ren_free_preg2, ren_free_preg1, ren_free_preg0};
        ret_pc_q[0]  <= cmpc0;  ret_pc_q[1]  <= cmpc1;  ret_pc_q[2]  <= cmpc2;
        ret_reg_q[0] <= cmreg0; ret_reg_q[1] <= cmreg1; ret_reg_q[2] <= cmreg2;
        ret_val_q[0] <= cmval0; ret_val_q[1] <= cmval1; ret_val_q[2] <= cmval2;
        ret_ena_q    <= {cmena2, cmena1, cmena0};
        ret_rdy_q    <= {sq_rdy2, sq_rdy1, sq_rdy0};
        ret_ipend_q  <= int_pending;
        ret_csrrdata_q <= csr_rdata;
        ret_csrsrc_q   <= csrsrc_rdata;
        // [诊断] preg 表的边沿前输入, 用于给空闲计数的差账定位
        x_retarch_q <= dut.u_preg.ret_arch_vld;
        x_retkill_q <= dut.u_preg.ret_kill_vld;
        x_dstp_q[0] <= dut.u_preg.ret_dst_preg0;
        x_dstp_q[1] <= dut.u_preg.ret_dst_preg1;
        x_dstp_q[2] <= dut.u_preg.ret_dst_preg2;
        x_flvl_q    <= dut.u_preg.flush_lvl;
    end
    // 四态表在**冲沿前**的快照。"释放的编号不该是 FREE 态"这条不变量问的是
    // "释放发生在哪个状态上", 而释放本身就在同一个 posedge 把那个编号写成 FREE ——
    // 在负沿直接读 st[] 必然读到 FREE (等于拿结果去问原因, 恒假)。所以留一份边沿前的副本。
    logic [191:0] st_snap_q = 192'd0;
    logic [223:0] amt_snap_q = 224'd0;
    always @(posedge clk) begin
        for (int si = 0; si < 96; si = si + 1)
            st_snap_q[2*si +: 2] <= dut.u_preg.st[si];
        for (int ai = 0; ai < 32; ai = ai + 1)
            amt_snap_q[7*ai +: 7] <= dut.u_preg.amt[ai];
    end

    // 采样时机: 进入 D_DISP 时"上膛", 紧随其后的那个 posedge 采一次然后卸膛。
    // 那个 posedge 正是 DUT 采样的那一个 (TB 在 negedge 摆状态, DUT 在下一个
    // posedge 采), 两边看到的是同一个 lane_go —— 这样"记的账"必然等于"真派出去的"。
    // ⚠️ 不能无条件每拍锁存: 下一个 posedge 时状态已经切走了, 会把 0 覆盖上去。
    logic       d_arm = 1'b0;
    always @(posedge clk) if (d_arm) begin acc_q <= lane_go; d_arm <= 1'b0; end

    // ---- 分配编号的采样时机: **请求那一拍结束的那个 posedge** ----
    // ⚠️⚠️ 这是本 TB 最大的一处踩坑。`rtu_preg_alloc*` 是优先编码器的**组合输出**,
    //    只在"请求还挂在口上"的那一拍有效 (§6.0: "T 拍…**同拍**把编号放到
    //    rtu_preg_alloc")。而选中的编号在那个 posedge 就进 WF_ALLOC、退出 free_vec,
    //    编码器随即指向**下一批**空闲编号。
    //    早先这里是在 D_REQ 那一拍 (也就是 T+1) 直接读实时值 —— 读到的永远是"下一批",
    //    指令于是拿着一个**从没分配过、仍处于 FREE** 的编号当 dst_preg: 它既不进
    //    ALLOC 也不会被认领, 很快被编码器发给别人 (双份发出 / `释放了 FREE 态的 pN` /
    //    以 FREE 态退休成 ARCH, 各种下游症状都从这里长出来)。
    //    修法与"接受位"同构: 进 D_REQ 时上膛, 请求周期结尾的那个 posedge 采一次 ——
    //    取样点正是 DUT 采样 ren_preg_req 的同一刻, 两边看到的是同一批编号。
    logic        al_arm = 1'b0;
    logic [6:0]  s_got [0:2];
    logic [2:0]  s_gotv = 3'd0;
    always @(posedge clk) if (al_arm) begin
        s_got[0] <= alloc0; s_got[1] <= alloc1; s_got[2] <= alloc2;
        s_gotv   <= {alloc_vld2, alloc_vld1, alloc_vld0};
        al_arm   <= 1'b0;
    end

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
    // ⚠️ `dst_lreg == 0` 的车道**不申请也不使用**编号 (§6.1 约定 5: "RTU 侧按 0 处理")。
    //    但 `rtu_preg_alloc*` 那根线上永远**有值** —— 那是别的车道要拿的编号。照抄
    //    上口就等于告诉 RTU "这条指令要写 pXX", 参考流也跟着记错 (窗口逐字段比对会
    //    对不上, "分配器不得再发在途 dst_preg" 也会拿它误报)。
    assign d0_dpreg = (pl_lreg[0] != 5'd0) ? h_got[0] : 7'd0;
    assign d1_dpreg = (pl_lreg[1] != 5'd0) ? h_got[1] : 7'd0;
    assign d2_dpreg = (pl_lreg[2] != 5'd0) ? h_got[2] : 7'd0;

    integer      errors = 0;
    integer      n_done = 0, n_trap = 0, n_int = 0, n_flush = 0;
    integer      n_store = 0, n_csr = 0, n_mret = 0, n_misp = 0;
    integer      fl_state = 0;         // 1=T 2=F1 3=F2
    integer      beu_orphan = 0;       // 见 beu_mask 那条检查 (连续多少拍"无解释")
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
    bit          log_dumped3 = 0;
    bit          trace_on = 0;
    integer      seed = 32'h1234_5678;
    integer      n_target = 200;
    bit          allow_exc, allow_int, allow_csr, allow_store, allow_branch;

    logic [2:0]  vldv;
    logic        trap_this;
    logic        int_seen = 1'b0;      // 本拍刚取走了一次中断

    task automatic log_evt(input string e);
        begin
            evt[evt_i % LOGN] = e;
            evt_i = evt_i + 1;
        end
    endtask

    task automatic dump_log;
        begin
            $display("  ---- 最近 %0d 条事件 (旧 -> 新) [evt_i=%0d] ----", LOGN, evt_i);
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
            // ⚠️ 整套用 posedge 锁存的那一份 (= "刚过去的那个 posedge DUT 做了什么")。
            //    读实时组合值会拿到"还没发生的那个事件 + 上一拍的输入" —— 一个不存在的帧。
            vldv      = ret_vld_q;
            trap_this = 1'b0;
            csr_slot  = -1;
            for (int k = 0; k < 3; k = k + 1)
                if (vldv[k] && ((n_ret + k) < n_inst) && flg_of(n_ret+k)[`RTU_FLG_CSR])
                    csr_slot = k;

            // ---------- 0) 提交脉冲必须是前缀, 且与 retire_cnt 一致 ----------
            if (vldv[1] && !vldv[0]) err("退休脉冲跳号: 有槽1无槽0");
            if (vldv[2] && !vldv[1]) err("退休脉冲跳号: 有槽2无槽1");
            if (ret_cnt_q !== ({1'b0,vldv[2]} + {1'b0,vldv[1]} + {1'b0,vldv[0]}))
                err($sformatf("retire_cnt=%0d 与提交脉冲 %b 不符", ret_cnt_q, vldv));

            // ---------- 1) 陷阱 / 中断 ----------
            if (ret_trap_q) begin
                if (n_ret >= n_inst) err("trap_vld 但参考队列为空");
                else begin
                    i = n_ret;
                    trap_this = 1'b1;
                    if (ret_tcause_q == `RTU_CAUSE_MTIP) begin
                        n_int = n_int + 1;
                        if (ret_ipend_q !== 1'b1) err("取了中断但 int_pending=0");
                        if (ret_cnt_q !== 2'd0) err("取中断那一拍不该有退休计数");
                        if (vldv !== 3'b000)      err("取中断那一拍不该有提交脉冲");
                        if (flg_of(i)[`RTU_FLG_STORE] || flg_of(i)[`RTU_FLG_CSR] ||
                            flg_of(i)[`RTU_FLG_MRET])
                            err("中断落在了有副作用的提交点上");
                    end else begin
                        n_trap = n_trap + 1;
                        if (!x_exc[i]) err($sformatf("凭空陷入: 指令 %0d 没注入异常", i));
                        else if (ret_tcause_q !== x_ec[i])
                            err($sformatf("陷阱 cause 不符: exp=%0d got=%0d", x_ec[i], ret_tcause_q));
                        else if (ret_tval_q !== x_etv[i]) err("陷阱 tval 不符");
                        if (ret_epc_q !== x_pc[i]) err("陷阱 mepc 不是队头那条的 pc");
                        if (!(vldv[0] && !vldv[1] && !vldv[2])) err("陷阱那拍应只退到它为止");
                        if (ret_ena_q[0] !== 1'b0) err("陷阱指令不该写 rd (ena 必须为 0)");
                        if (ret_sw_q[0] || ret_csrwe_q || ret_csrrd_q)
                            err("陷阱指令不该产生任何副作用");
                    end
                    if (ret_iflush_q !== 1'b1) err("陷阱/中断那拍必须发前端重定向");
                    if (ret_ipc_q !== csr_tvec) err("陷阱/中断的重定向目标应为陷阱向量");
                end
            end

            // ---------- 2) 逐槽核对 ----------
            for (int k = 0; k < 3; k = k + 1) begin
                logic        ena, sw;
                logic [31:0] pc, val;
                logic [4:0]  rreg;
                if (vldv[k]) begin
                    ena = ret_ena_q[k];  pc = ret_pc_q[k];
                    rreg = ret_reg_q[k]; val = ret_val_q[k];  sw = ret_sw_q[k];

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
                                if (val !== ret_csrrdata_q) err("CSR 指令写 rd 的值必须等于 CSR 旧值");
                            end else if (val !== pf[x_dpr[i]])
                                err($sformatf("指令 %0d 提交值不符: exp=%08x got=%08x",
                                              i, pf[x_dpr[i]], val));
                        end
                        if (sw !== (flg_of(i)[`RTU_FLG_STORE] && !trap_this))
                            err($sformatf("指令 %0d store 脉冲不符", i));
                        if (sw) begin
                            if (!ret_rdy_q[k]) err("store 数据没就绪却退休了");
                            if (ret_sqid_q[3*k +: 3] !== x_sqi[i]) err("store sq_id 不符");
                            n_store = n_store + 1;
                        end
                        // 释放 old_preg: 脉冲与编号都必须逐位一致
                        exp_free_k = (x_rfwe[i] && (x_lreg[i] != 5'd0) &&
                                      (x_opr[i] >= 7'd32) && !trap_this);
                        begin
                            logic       fv_k;
                            logic [6:0] fp_k;
                            fv_k = ret_fv_q[k];
                            fp_k = ret_fp_q[7*k +: 7];
                            if (fv_k !== exp_free_k)
                                err($sformatf("指令 %0d 释放脉冲不符: exp=%b got=%b (old=%0d)",
                                              i, exp_free_k, fv_k, x_opr[i]));
                            if (fv_k && (fp_k !== x_opr[i]))
                                err($sformatf("指令 %0d 释放的编号不符: exp=%0d got=%0d",
                                              i, x_opr[i], fp_k));
                            if (fv_k && (fp_k < 7'd32)) err("释放了架构寄存器 p0..p31");
                            // 纯 DUT 侧: 释放的编号在 DUT 的池子里绝不该是 FREE 态
                            // (它是"被替换掉的架构映射", 一定处于 ARCH/ALLOC)。
                            if (fv_k && (st_snap_q[2*fp_k +: 2] === 2'd0)) begin
                                err($sformatf("释放了 FREE 态的 p%0d (指令 %0d, trap=%b) dpr=%0d old=%0d lreg=%0d amt=%0d oldsrc=%0d idx=%0d",
                                              fp_k, i, trap_this, x_dpr[i], x_opr[i],
                                              x_lreg[i], ref_amt[x_lreg[i]], x_src[i], x_srcidx[i]));
                                if (!log_dumped3) begin dump_log(); log_dumped3 = 1'b1; end
                            end
                        end
                    end
                end
            end

            // ---------- 3) CSR 写口 ----------
            // ⚠️ 陷阱那拍要整个跳过: 异常正好注在这条 CSR 上时 `write_vld = 0`
            //    (§4.5: 陷阱那条不发副作用), 于是 csr_we/csr_rd_we 本来就该是 0 ——
            //    而下面这套检查是"RW 类必须写", 不跳过就是自己跟自己打架。
            if ((csr_slot >= 0) && !trap_this) begin
                integer ii;
                logic [31:0] exp_w, src_v;
                logic        exp_csr_we;
                ii = n_ret + csr_slot;
                if (ret_csra_q !== x_ca[ii]) err("CSR 写地址不符");
                src_v = x_cop[ii][2] ? {27'b0, x_cim[ii]} : ret_csrsrc_q;
                exp_w = (x_cop[ii][1:0] == 2'b01) ? src_v :
                        (x_cop[ii][1:0] == 2'b10) ? (ret_csrrdata_q |  src_v) :
                                                    (ret_csrrdata_q & ~src_v);
                // 写不写 CSR 的口径 (§6.3 ⑤ / A6c): RW 恒写; RS/RC 看**源非零**
                // (立即数型看 uimm, 寄存器型看 rs1_preg —— x0 恒映射到 p0, 而 p0 永不
                //  进自由池, 所以 "src1_preg == 0" 就等价于 "rs1 是 x0")。
                // ⚠️ 早先这里写死"必须写", 把 RS/RC 且源为 0 的正常情形也报成错。
                exp_csr_we = (x_cop[ii][1:0] == 2'b01) ||
                             (x_cop[ii][2] ? (|x_cim[ii]) : (|x_s1[ii]));
                if (ret_csrwe_q !== exp_csr_we)
                    err($sformatf("CSR 写使能不符: op=%b imm=%0d s1p=%0d exp=%b got=%b",
                                  x_cop[ii], x_cim[ii], x_s1[ii], exp_csr_we, ret_csrwe_q));
                if (ret_csrw_q !== exp_w) err($sformatf("CSR 写值不符: exp=%08x got=%08x", exp_w, ret_csrw_q));
                if (ret_csrrd_q !== (x_rfwe[ii] && (x_lreg[ii] != 5'd0)))
                    err("CSR 指令的 rd 写使能不符");
                if (ret_csrrd_q) begin
                    if (ret_csrra_q !== x_dpr[ii]) err("CSR rd 写地址不符");
                    if (ret_csrrw_q !== ret_csrrdata_q) err("CSR rd 写值必须等于旧值");
                end
                n_csr = n_csr + 1;
            end else if (!trap_this && (ret_csrwe_q || ret_csrrd_q)) begin
                err("没有 CSR 指令退休却出现 CSR 写");
            end

            // ---------- 4) 误预测退休的重定向目标 ----------
            // (mret 也会发前端重定向, 但那条走 §5 的检查)
            if (ret_iflush_q && !ret_trap_q && !ret_mret_q) begin
                integer mi;
                mi = -1;
                for (int k = 0; k < 3; k = k + 1)
                    if (vldv[k] && ((n_ret+k) < n_inst) &&
                        flg_of(n_ret+k)[`RTU_FLG_BRANCH] && x_msp[n_ret+k] && (mi < 0))
                        mi = n_ret + k;
                if (mi < 0) err("发了前端重定向, 但没有任何退休分支是误预测的");
                else if (ret_ipc_q !== x_tgt[mi]) begin
                    err($sformatf("误预测重定向目标不符: exp=%08x got=%08x | mi=%0d iid=%0d n_ret=%0d",
                                  x_tgt[mi], ret_ipc_q, mi, x_iid[mi], n_ret));
                    if (!log_dumped3) begin dump_log(); log_dumped3 = 1'b1; end
                end
                n_misp = n_misp + 1;
            end

            // ---------- 5) mret ----------
            if (ret_mret_q) begin
                if ((n_ret >= n_inst) || !flg_of(n_ret)[`RTU_FLG_MRET]) err("mret_vld 但队头不是 mret");
                else if (ret_ipc_q !== csr_mepc_i) err("mret 的重定向目标应为 mepc");
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

            // ---------- 5b) 阵列 vld == "这一格装着在途指令" ----------
            // 纯 DUT 侧不变量 (与参考流无关): 在途区间就是 [rptr, rptr+occ), 所以
            // 阵列里**恰好**这一段 vld=1、其余全 0。冲出这一条, 说明"退休弹出一项"
            // 没有把那一格清掉 —— 而阵列不随指针绕圈自动失效, 于是那一格会一直挂着
            // 上一代 (甚至上上代) 的 vld=1/cmplt=1, 等 ROB 快排空、窗口的"补空"
            // 路径去看 rptr+k 时, 就把旧表项当成在途项补进来 ⇒ 判退级联按它再发一次
            // 交付脉冲, **同一条指令被退休两次**。
            // ⚠️ 这条是 2026-10-01 在整核里撞出来之后补的 (阶段 1 接进 mycpu 时
            //    trap.S 的 wait_loop 上重复提交): 原来的 TB 只在"窗口有效"时比
            //    窗口与阵列, 两份都错就看不出来; 而它的激励又总让 ROB 保持半满
            //    (rptr+k 永远落在在途区间内), 于是从没走到这个角落。**别删。**
            if (!ren_flush) begin
                for (int k = 0; k < 64; k = k + 1) begin
                    logic occ_k;
                    occ_k = (((k - dut.u_rob.rptr) & 6'h3f) < dut.u_rob.occ_q);
                    if (occ_k !== (dut.u_rob.rob_q[k][`RTU_E_VLD] === 1'b1))
                        err($sformatf("阵列[%0d] vld=%b 与在途区间不符 (rptr=%0d occ=%0d)",
                                      k, dut.u_rob.rob_q[k][`RTU_E_VLD],
                                      dut.u_rob.rptr, dut.u_rob.occ_q));
                end
            end

            // ---------- 6) 分配器 ----------
            // 纯 DUT 侧的不变量: 给出的编号自身必须是 FREE 态 (与模型无关)
            if (alloc_vld0 && (dut.u_preg.st[alloc0] !== 2'd0))
                err($sformatf("分配器给出非 FREE 的 p%0d (st=%0d)", alloc0, dut.u_preg.st[alloc0]));
            if (alloc_vld1 && (dut.u_preg.st[alloc1] !== 2'd0))
                err($sformatf("分配器给出非 FREE 的 p%0d (st=%0d)", alloc1, dut.u_preg.st[alloc1]));
            if (alloc_vld2 && (dut.u_preg.st[alloc2] !== 2'd0))
                err($sformatf("分配器给出非 FREE 的 p%0d (st=%0d)", alloc2, dut.u_preg.st[alloc2]));
            if (alloc_vld0 && (alloc0 < 7'd32)) err("分配器给出架构寄存器");
            if (alloc_vld1 && (alloc1 < 7'd32)) err("分配器给出架构寄存器");
            if (alloc_vld2 && (alloc2 < 7'd32)) err("分配器给出架构寄存器");
            if (alloc_vld0 && alloc_vld1 && (alloc0 == alloc1)) err("两路分配撞车");
            if (alloc_vld0 && alloc_vld2 && (alloc0 == alloc2)) err("两路分配撞车");
            if (alloc_vld1 && alloc_vld2 && (alloc1 == alloc2)) err("两路分配撞车");
            // 不得把**任何在途指令的 dst_preg** 再发一遍 —— 这条才是"自由池没漏干"
            // 的本质, 而且与 TB 对两拍握手的相位建模无关 (比"不得是上一拍刚发出去的
            // 那个"稳健得多: 后者要求 TB 把 T/T+1 的相位对得分毫不差, 很容易假报)。
            // ⚠️ 冲刷那一拍要跳过: 参考流的窗口要到 disp_step 里才清零, 此刻它还是
            //    "冲掉之前"的旧窗口, 里面那些编号 DUT 已经放回自由池了 —— 比必然误报。
            // ⚠️ **本拍正在退休的那几条要排除**: 它们此刻既还在参考流窗口里
            //    (ref_retire 要等这一拍才把它记掉), 又已经把自己的编号交了出去 ——
            //    ① 陷阱那条: `ret_kill_vld` 把它的 dst_preg 放回 FREE;
            //    ② 同组里后一条写同一条 lreg 时, 它的 old_preg 正好是前一条的 dst_preg,
            //       于是前一条刚转 ARCH 的编号在**同一拍**又被放回 FREE
            //       (这正是"年轻者胜"该有的样子)。
            //    这两种情形下那个编号本来就可以再发出去, 不排除就是纯假报。
            for (int ii = n_ret; ii < n_inst && !ret_flush_q; ii = ii + 1) begin
                // 陷阱那拍**整个窗口**的 dst_preg 都可能被 `ret_kill_vld` 放回 (三路
                // 都带 rf_we&lreg!=0 就是三条全杀, 不只是槽 0) —— 那几条本来就随冲刷
                // 一起作废, 编号可以再发出去, 所以整段跳过。
                if (ret_trap_q) continue;
                if (ii < (n_ret + ret_cnt_q)) continue;
                if ((alloc_vld0 && (alloc0 == x_dpr[ii])) ||
                    (alloc_vld1 && (alloc1 == x_dpr[ii])) ||
                    (alloc_vld2 && (alloc2 == x_dpr[ii])))
                    begin
                        err($sformatf("分配器把在途指令 %0d 的 dst_preg (p%0d) 又发了一遍 | st=%0d rfwe=%b lreg=%0d | 本拍 alloc=%b/%0d,%b/%0d,%b/%0d req=%0d",
                                      ii, x_dpr[ii], dut.u_preg.st[x_dpr[ii]], x_rfwe[ii], x_lreg[ii],
                                      alloc_vld0, alloc0, alloc_vld1, alloc1, alloc_vld2, alloc2,
                                      ren_preg_req));
                        if (!log_dumped3) begin dump_log(); log_dumped3 = 1'b1; end
                    end
            end


            // ---------- 6b) 空闲计数 == 池子里真 FREE 的个数 ----------
            // 纯 DUT 侧自洽: 编号总数 96, p0..p31 恒为初始映射且永不回收, 所以
            // "还剩几个可用" 就是高段里 FREE 的个数。这条是 §6.0 对重命名级的承诺
            // (剩余可用数), 高报会让对面按高报的数发请求却拿不满编号。
            begin
                integer fcnt, fpre;
                fcnt = 0; fpre = 0;
                for (int q = 32; q < 96; q = q + 1) begin
                    if (dut.u_preg.st[q] === `RTU_P_FREE) fcnt = fcnt + 1;
                    if (st_snap_q[2*q +: 2] === `RTU_P_FREE) fpre = fpre + 1;
                end
                if (dut.u_preg.free_cnt !== fcnt[6:0]) begin
                    string chg;
                    chg = "";
                    for (int q = 32; q < 96; q = q + 1)
                        if (st_snap_q[2*q +: 2] !== dut.u_preg.st[q])
                            chg = {chg, $sformatf(" p%0d:%0d>%0d", q,
                                                  st_snap_q[2*q +: 2], dut.u_preg.st[q])};
                    err($sformatf("空闲计数不符: 计数器=%0d, 实际 FREE=%0d | 本边沿变化:%s | E前 kill=%b flvl=%b fvl=%b old=%0d,%0d,%0d",
                                  dut.u_preg.free_cnt, fcnt, chg,
                                  x_retkill_q, x_flvl_q, ret_fv_q,
                                  ret_fp_q[6:0], ret_fp_q[13:7], ret_fp_q[20:14]));
                end
            end

            // ---------- 7) AMT 逐拍等于参考模型 ----------
            // 边沿前的快照 vs 参考模型 (ref_amt 此刻正好是"上一个事件之后"的值),
            // 两边同帧。比"只在冲刷那拍比"强得多: 映射一旦发散, 当场就能指出来,
            // 而不是等到某次冲刷时看到一堆 exp/got 对不上。
            for (int l = 0; l < 32; l = l + 1)
                if (amt_snap_q[7*l +: 7] !== ref_amt[l]) begin
                    err($sformatf("AMT[%0d] 与参考模型不符 (边沿前): exp=%0d got=%0d",
                                  l, ref_amt[l], amt_snap_q[7*l +: 7]));
                    if (!log_dumped) dump_log();
                end

            // ---------- 8) 冲刷时间线 (§6.3 ①) ----------
            // 对齐口径: 触发那个 posedge 叫 P。`backend_flush`/`ren_flush` 是 **st_q 的组合
            // 输出**, 所以在 negedge 读实时值是对的 (边沿后的状态) —— 三段分别在
            // P+5 / P+15 / P+25 的负沿上可见。而"有没有触发"必须用锁存的 ret_iflush_q
            // (触发本身就是组合量, 读实时值会读到下一个事件)。
            //
            // 于是状态号的含义: 1 = P+5 那拍 (T, 后端冲刷), 2 = P+15 那拍 (T+1, 重命名冲刷)。
            // 触发分支放在最前 (不看 fl_state): DUT 的冲刷状态机是 IDLE→F1→F2→IDLE
            // 三拍, 但一次冲刷走完的**下一个 posedge** 就允许再触发一次 —— 靠 fl_state
            // 去括号会把这种背靠背的第二次漏掉, 窗口从此错位 (踩过: 72 条
            // "beu_flush_chgflw_mask 与冲刷窗口不符")。
            if (ret_iflush_q) begin
                n_flush   = n_flush + 1;
                head_wait = 0;
                fl_state  = 1;
                if (!backend_flush) err("冲刷 T 拍应有 rtu_backend_flush");
            end else case (fl_state)
                0: begin
                    if (backend_flush || ren_flush)
                        err("没有触发却出现冲刷信号");
                end
                1: begin
                    if (!ren_flush) err("冲刷 T+1 拍应有 rtu_ren_flush");
                    if (!ren_recover_vld) err("ren_flush 那拍必须同时给 recover_vld");
                    for (int l = 0; l < 32; l = l + 1)
                        if (ren_recover_map[7*l +: 7] !== ref_amt[l]) begin
                            err($sformatf("AMT[%0d] 广播不符: exp=%0d got=%0d",
                                          l, ref_amt[l], ren_recover_map[7*l +: 7]));
                            if (!log_dumped) dump_log();
                        end
                    fl_state = 2;
                end
                default: begin
                    if (backend_flush || ren_flush) err("冲刷 T+2 拍应该已经结束了");
                    fl_state = 0;
                end
            endcase
            if ((fl_state != 0) && !disp_stall) err("冲刷窗口内 disp_stall 必须保持");
            // ⚠️ 不能拿 beu_mask 与 fl_state 逐拍相等: `beu_mask = flushing = flush_trig | ~idle`,
            //    而 `flush_trig` 是**组合**的提交级信号 —— 它在负沿上可能刚好为 1, 但 DUT
            //    在那个 posedge 用的输入已经被 TB 换掉, 状态机并不真的进 F1。逐拍相等会
            //    报一堆假失败 (踩过: 66 条)。
            //    有牙齿的两条: ① 窗口内必须保持; ② 窗口外只允许"这一拍确实在发起冲刷"
            //    时拉高 —— 那种情形下一拍一定能从锁存的触发脉冲或 DUT 的 FSM 上看出来。
            if (((fl_state != 0) || ret_iflush_q) && !beu_mask)
                err("冲刷窗口内 beu_mask 必须保持");
            // ⚠️ 只在一两拍上为 1 不算事: TB 在**负沿**换输入, 于是 `flush_trig` 这个
            //    组合量可能"前半拍为 1、后半拍(被 DUT 采样的那一刻)又变 0" —— 真核里
            //    输入是同步换的, 不会有这种半拍毛刺。有牙齿的是"一直挂着不放"。
            if (!ret_iflush_q && !beu_mask && (fl_state == 0) && (dut.u_flush.st_q == `RTU_FSM_IDLE))
                beu_orphan = 0;
            else if (beu_mask && !ret_iflush_q && (fl_state == 0) &&
                     (dut.u_flush.st_q == `RTU_FSM_IDLE)) begin
                beu_orphan = beu_orphan + 1;
                if (beu_orphan > 3)
                    err("beu_flush_chgflw_mask 连续多拍拉高却没有对应的冲刷");
            end else
                beu_orphan = 0;

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
            // ⚠️ 这里连"陷阱是哪一类"都必须用锁存的那一份: `trap_cause` 是**组合**输出,
            //    没有 trap_hit 时它恒等于 `RTU_CAUSE_MTIP`(默认值)。早先这里读实时值,
            //    于是每一次**同步**异常都被当成中断处理 —— `n_ret = n_inst` 把整条流
            //    抹掉 (踩过: 症状是一堆 "退休位置不符 / 释放了 FREE 态")。
            if (ret_trap_q) begin
                log_evt($sformatf("TRAP n_ret=%0d n_inst=%0d cause=%0d", n_ret, n_inst, ret_tcause_q));
                if (ret_tcause_q == `RTU_CAUSE_MTIP) begin
                    // ⚠️ 这里**不动 n_ret**: 取中断那拍 `pop_n = 0`, DUT 的 rptr 纹丝不动
                    //    (ROB 要到 FLUSH_2 才清)。早先在这里 `n_ret = n_inst` 把整条流
                    //    抹掉, 于是"本圈已退条数"与 DUT 的 rptr 立刻差开, 后面连着几拍
                    //    的 `退休位置不符` 全是这么来的。被 squash 的那些由 FLUSH 那一刻
                    //    的整表归零统一处理 (那条路径本来就对)。
                    int_seen = 1'b1;
                end else if (vldv[0]) begin
                    // 陷阱那条: 分配过但没写 -> 回 FREE (DUT 侧由 ret_kill_vld 完成)
                    n_ret = n_ret + 1;
                end
            end else begin
                for (int k = 0; k < 3; k = k + 1) begin
                    if (vldv[k]) begin
                        i = n_ret;
                        if (x_rfwe[i] && (x_lreg[i] != 5'd0))
                            ref_amt[x_lreg[i]] = x_dpr[i];   // 模型只需要维护 AMT
                        log_evt($sformatf("RET  inst=%0d iid=%0d rptr=%0d lreg=%0d dpr=%0d rfwe=%b",
                                          i, x_iid[i], dut.u_rob.rptr, x_lreg[i], x_dpr[i], x_rfwe[i]));
                        n_ret = n_ret + 1;
                        n_done = n_done + 1;
                    end
                end
            end

            // 提交点副作用也要用锁存的那一份 (实时值描述的是**下一个**事件, 会写错地址)
            if (ret_csrwe_q) csr_file[ret_csra_q] = ret_csrw_q;
            if (ret_csrrd_q) pf[ret_csrra_q]      = ret_csrrw_q;
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
                    // old_preg **不在这里算** —— 见 old_preg_of(): 它要等 D_REQ 那拍
                    // 拿到 dst_preg 之后才算得出来 (同拍/同计划里的依存要用到它)。
                    pl_opreg[k] = 7'd0;
                    pl_pc[k]    = {$urandom};
                    pl_chk[k]   = {$urandom} % (1 << 25);
                    pl_val[k]   = {$urandom};
                    pl_s1[k]    = {$urandom} % 96;
                    pl_ca[k]    = {$urandom} % 4096;
                    // ⚠️ csr_op 按 §6.1 A6c 是 **funct3 原样**, 而合法取值有六个:
                    //    001/010/011 (寄存器型) 与 101/110/111 (立即数型)。
                    //    这里原来只生成前三个 ⇒ **立即数形式从没被激励过**,
                    //    于是"喂两位 CSR_OP_* 码而不是 funct3"那种接线错
                    //    (`csr_is_imm` 恒 0 ⇒ csrrwi 拿 rs1 垃圾当源) 在单测台
                    //    里静默通过, 一直到整核接上 CSR 写口才炸。别改回去。
                    case ({$urandom} % 4)
                        0: pl_cop[k] = 3'b001;
                        1: pl_cop[k] = 3'b010;
                        2: pl_cop[k] = 3'b011;
                        default: pl_cop[k] = 3'b101 + ({$urandom} % 3);
                    endcase
                    // uimm5 要走满 0 与非 0 两类: 0 决定 RS/RC 不写 (exp_csr_we 那一支)
                    pl_cimm[k]  = ({$urandom} % 4 == 0) ? 5'd0 : {$urandom} % 32;
                    pl_sqi[k]   = {$urandom} % 8;
                end else begin
                    pl_flg[k]=0; pl_lreg[k]=0; pl_rfwe[k]=0; pl_opreg[k]=0;
                    pl_pc[k]=0;  pl_chk[k]=0;  pl_val[k]=0;  pl_s1[k]=0;
                    pl_ca[k]=0;  pl_cop[k]=1;  pl_cimm[k]=0; pl_sqi[k]=0;
                end
            end
            // §6.1 A7: **一拍最多一条 CSR**。CSR 单槽 (RTU_csr_slot) 只装得下一条,
            // 组里出现第二条时它既写不进槽、退休时又读到别人的字段 —— 契约只能
            // 把这条约束放在重命名级 (它看得见整组), 所以这里按契约把年轻的那条降级。
            begin
                bit seen_csr = 1'b0;
                for (int k = 0; k < 3; k = k + 1) begin
                    if ((k < pl_n) && pl_flg[k][`RTU_FLG_CSR]) begin
                        if (seen_csr) pl_flg[k][`RTU_FLG_CSR] = 1'b0;
                        else          seen_csr = 1'b1;
                    end
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

    logic [1:0] g_op_src = 2'd0;    // [诊断] old 是从哪一路来的: 0=RAT 1=同计划更老的车道
    integer     g_op_idx = -1;

    // -----------------------------------------------------------------------
    // old_preg = **重命名级的 RAT** 在该 lreg 上的当前值 (§6.1: "被替换的 (来自你自己的 RAT)")。
    //
    // ⚠️ 早先这里给的是 `ref_amt[lreg]`, 即**架构映射** —— 那是错的, 只在"同一 lreg 不会
    //    有两条在途"时才碰巧等价。反例: inst A 写 x8 得 dpr=p50, inst B 再写 x8 时 A 还没
    //    退休, B 拿到的 old 仍是 p36=A 的 old ⇒ A、B 退休时**都释放 p36**; 第一次是真释放,
    //    第二次释放的是已经变 FREE 的 p36 —— 症状是 `释放了 FREE 态的 pNN`。
    //
    // 也**不要**去"从在途窗口重建" RAT (现场扫一遍 [n_ret, n_inst) 取最年轻的写者):
    //    那是在替 RTL 复刻语义, 窗口边界慢一拍/陷阱杀编号/冲刷回收各撞过一次。
    //    老老实实维护一份 ref_rat —— 这正是 §6 点名由重命名级持有的那一份状态。
    //
    // 同一份计划里的依存要按程序序串起来: 更老的车道 j<k 若写同一个 lreg, 它的
    // dst_preg 就是刚锁存的 h_got[j] (那一刻 RAT 还没写进去, 查表查不到)。
    //
    // 必须在 D_REQ 那拍调用: 那时 (i) 上一份计划的账已经结完 (disp_step 开头),
    // RAT 是新的; (ii) h_got 刚锁存好。
    // -----------------------------------------------------------------------
    function automatic logic [6:0] old_preg_of(input integer k);
        begin
            old_preg_of = 7'd0;
            g_op_src = 2'd0;  g_op_idx = -1;
            if (pl_rfwe[k] && (pl_lreg[k] != 5'd0)) begin
                old_preg_of = ref_rat[pl_lreg[k]];
                for (int j = 0; j < k; j = j + 1)
                    if ((j < pl_n) && pl_rfwe[j] &&
                        (pl_lreg[j] == pl_lreg[k]) && (pl_lreg[j] != 5'd0)) begin
                        old_preg_of = h_got[j];
                        g_op_src    = 2'd1;  g_op_idx = j;
                    end
            end
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
                // 不写寄存器的车道按契约摆 0 (§6.1 约定 5), 参考流也记 0 —— 这样
                // "窗口逐字段等于参考流" 比的就是同一条线上的值。
                x_dpr[i] = (cp_lreg[k] != 5'd0) ? cp_got[k] : 7'd0;
                x_opr[i]=cp_opreg[k]; x_iid[i]=iid_at(k);
                x_src[i]=cp_src[k];   x_srcidx[i]=cp_srcidx[k];
                x_ca[i]=cp_ca[k];     x_cop[i]=cp_cop[k];   x_cim[i]=cp_cimm[k];
                x_s1[i]=cp_s1[k];
                x_cmp[i]=1'b0; x_exc[i]=1'b0; x_ec[i]=5'd0; x_etv[i]=32'd0;
                x_tgt[i]=32'd0; x_tkn[i]=1'b0; x_msp[i]=1'b0; x_rsv[i]=1'b0;
                n_inst = n_inst + 1;
            end
            // RAT 更新与"记进参考流"同一个动作、同一个顺序 (老 -> 新), 年轻的覆盖年老的
            for (int k = 0; k < nd; k = k + 1)
                if (cp_rfwe[k] && (cp_lreg[k] != 5'd0))
                    ref_rat[cp_lreg[k]] = cp_got[k];
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
            // ---- 冲刷记账 (必须排在**最前**, 早于下面任何一次用 n_ret/n_inst 的判断) ----
            // ⚠️ 这一条踩过: DUT 在 FLUSH_2 那个 posedge 就把 ROB 清了 (非 ARCH 全回 FREE),
            //    而 TB 要等 ret_flush_q 锁存出来才看得到 —— 中间那一拍 FSM 已经在 D_IDLE
            //    重新起了一份计划, 于是 old_preg_of() 会把**已经被冲掉**的指令当成在途,
            //    拿它那个已经变 FREE 的 dst_preg 去释放 (症状: 释放了 FREE 态的 pN)。
            //    放在这里 = 保证"记的账"永远不晚于"用它的人"。
            if (ret_flush_q) begin
                log_evt($sformatf("FLUSH n_ret=%0d n_inst=%0d (都归零重来)", n_ret, n_inst));
                lap_base = n_inst;
                n_ret    = n_inst;
                tb_cptr  = 6'd0;
                tb_cmsb  = 1'b0;
                // AMT 不因冲刷而变 (它只反映已退休的映射) —— 这正是"恢复靠整表覆盖"的底气。
                // RAT 则**必须**整表覆盖回架构映射: 被冲掉的那些写者没了 (§6 的约定 4)。
                for (int l = 0; l < 32; l = l + 1) ref_rat[l] = ref_amt[l];
            end

            // ---- 结算上一拍摆上口的派遣 (与状态机走到哪个分支无关!) ----
            // ⚠️ 这一步**必须**独立于状态路径: 有一次派遣自己引出的 csr_inflight 会把
            //    状态机顶回 IDLE, 结算若只写在 D_REQ 分支里, 那次派遣就永远记不上账
            //    —— 参考流是空的, 于是没有完成信号, CSR 槽再也放不掉 (踩过的死锁)。
            if (commit_pending && !ren_flush) begin
                nd = 0;
                for (int k = 0; k < 3; k = k + 1) begin
                    if (acc_q[k]) nd = nd + 1;
                    // (编号的占用/归还由 DUT 自己的状态表负责, 这里不做镜像)
                end
                dispatch_record(nd);
                commit_pending = 1'b0;
            end

            if (ren_flush) begin
                // 冲刷: 挂着的编号由 DUT 在 FLUSH_2 放回, 模型里一并清掉
                h_gotv = 3'd0; pl_n = 0; cp_n = 0; commit_pending = 1'b0;
                d_arm = 1'b0; al_arm = 1'b0;
                dstate = D_IDLE;
            end else begin
                case (dstate)
                    D_IDLE: begin
                        if (!disp_stall) begin
                            gen_plan();                 // 第一份计划
                            al_arm = 1'b1;              // 请求这拍结束的 posedge 采编号
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
                        // (b) 取**上一拍 posedge 采下来的那份**编号 (见 al_arm)
                        h_got[0] = s_got[0];
                        h_got[1] = s_got[1];
                        h_got[2] = s_got[2];
                        h_gotv   = s_gotv;
                        // (c) **现在**才算 old_preg: 要 (i) 上一份计划的账已经结完
                        //     (②在 disp_step 开头, 本分支之前), (ii) 本份计划的 dst_preg
                        //     刚锁存好 —— 两者只有在这一拍同时成立。放在 gen_plan 里算
                        //     会看到一份还没入账的在途流 (单测台的 old_preg 就是这么错的)。
                        for (int k = 0; k < 3; k = k + 1) begin
                            pl_opreg[k] = old_preg_of(k);
                            pl_src[k]   = g_op_src;
                            pl_srcidx[k]= g_op_idx;
                        end
                        d_arm  = 1'b1;
                        dstate = D_DISP;
                        end
                    end
                    default: begin                     // D_DISP: 本拍把派遣摆在口上
                        // [不变量] 确认过的车道, 编号必须正好走到 ALLOC ——
                        // 停在 WF_ALLOC 说明派遣没被认领, 已经是 ARCH/FREE 说明握手错位。
                        for (int k = 0; k < 3; k = k + 1)
                            if (acc_q[k] && (pl_lreg[k] != 5'd0) &&
                                (dut.u_preg.st[h_got[k]] !== `RTU_P_ALLOC))
                                err($sformatf("派出的车道编号不在 ALLOC 态: 车道 %0d p%0d st=%0d",
                                              k, h_got[k], dut.u_preg.st[h_got[k]]));
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
                            cp_src[k]=pl_src[k];   cp_srcidx[k]=pl_srcidx[k];
                        end
                        commit_pending = 1'b1;
                        if (disp_stall) begin
                            pl_n = 0; dstate = D_IDLE; // stall 时不再往下发
                        end else begin
                            gen_plan();                // 下一份 (下一拍在 D_REQ 里请求)
                            al_arm = 1'b1;             // ⚠️ 这里**也要**上膛!
                            dstate = D_REQ;            //    流水式推进 (D_DISP→D_REQ) 时不经过
                        end                            //    D_IDLE, 漏了这一行就会一直用**上一份**
                                                       //    计划的编号 (踩过: 症状是反复拿同一个
                                                       //    早已变 ARCH 的编号, 一路顶到双份发出)
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
        // ---------- 0) 影子窗口的每个字段都必须等于参考流里对应的那条指令 ----------
        // 这是"流有没有错位"最直接的判据: 位置对得上 (4b 已查), 字段也必须对得上。
        for (int k = 0; k < 3; k = k + 1) begin
            logic [`RTU_E_W-1:0] w;
            integer ii;
            if (k == 0) w = dut.u_rob.win_q0;
            else if (k == 1) w = dut.u_rob.win_q1;
            else w = dut.u_rob.win_q2;
            ii = n_ret + k;
            if (w[`RTU_E_VLD] && (ii < n_inst) && (fl_state == 0)) begin
                if ((w[`RTU_E_DST_LREG] !== x_lreg[ii]) ||
                    (w[`RTU_E_DST_PREG] !== x_dpr[ii]) ||
                    (w[`RTU_E_OLD_PREG] !== x_opr[ii]) ||
                    (w[`RTU_E_RF_WE]    !== x_rfwe[ii]) ||
                    (w[`RTU_E_PC]       !== x_pc[ii]))
                    err($sformatf("窗口[%0d] 与参考流 inst=%0d 不符: lreg %0d/%0d dpr %0d/%0d opr %0d/%0d rfwe %b/%b pc %08x/%08x",
                                  k, ii,
                                  w[`RTU_E_DST_LREG], x_lreg[ii], w[`RTU_E_DST_PREG], x_dpr[ii],
                                  w[`RTU_E_OLD_PREG], x_opr[ii], w[`RTU_E_RF_WE], x_rfwe[ii],
                                  w[`RTU_E_PC], x_pc[ii]));
            end
        end
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

        // ---------- 4a2) ROB 占用数 == 参考流在途条数 ----------
        // 派遣记账与退休记账的**总账**: 只要有一笔记错 (多记/漏记), 这里当场发散。
        // ⚠️ DUT 在派遣那个 posedge 就建表项, 参考流要下一拍才记账 —— 中间那一拍
        //    要把 `commit_pending` 挂着的条数算进来, 否则从第一拍起就误报。
        begin
            integer pend;
            pend = 0;
            if (commit_pending)
                pend = {2'b0, acc_q[0]} + {2'b0, acc_q[1]} + {2'b0, acc_q[2]};
            if (dut.u_rob.occ_q !== (n_inst - n_ret + pend))
                err($sformatf("ROB 占用数不符: DUT=%0d, 参考流在途=%0d (n_inst=%0d n_ret=%0d pend=%0d)",
                              dut.u_rob.occ_q, n_inst - n_ret, n_inst, n_ret, pend));
        end

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

        // ---------- 活性: 队头完成了却迟迟不退 ----------
        // ⚠️ 必须排在**记账之后**: 这里问的是"现在的那个队头"。放在 check_cycle 里
        //    量的是上一拍的头 —— 某一拍正好把在途的都退完时, n_ret 还落在后面, 于是
        //    把"已经退干净了"误判成"卡住" (踩过)。冲刷窗口用 DUT 自己的口径
        //    (beu_mask == flushing, 含"这一拍正在发起冲刷"), 而不是 TB 的 fl_state
        //    —— 后者少盖一拍, 会把正当的冲刷窗口算成卡住。
        if (!beu_mask && !ret_iflush_q && (n_ret < n_inst)) begin
            if (x_cmp[n_ret] && !flg_of(n_ret)[`RTU_FLG_STORE] && !int_pending)
                head_wait = head_wait + 1;
            else head_wait = 0;
            if (head_wait > 8) begin
                err($sformatf("指令 %0d 早就完成却不退休", n_ret));
                head_wait = 0;
            end
        end else head_wait = 0;

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
                // ⚠️ **分支必须先把解析结果写回表项, 才能报完成** (§6.1 的 resolve/cmplt 次序)。
                //    否则会出现"完成信号先到、resolve 后到, 而这条正好在这拍退休" ——
                //    ROB 判退用的是**边沿前**的表项, 于是它按"没误预测"退掉, 重定向就丢了。
                //    真机里 BEU 也是同拍出结果+完成, 不存在"完成了还没解析"的分支。
                if (x_flg[pick][`RTU_FLG_BRANCH] && !x_rsv[pick]) continue;
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
                log_evt($sformatf("RESV inst=%0d iid=%0d misp=%b tgt=%08x", pick, x_iid[pick], rsv_misp, rsv_tgt));
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
            // ⚠️ 同步异常的 cause 不能撞上 `RTU_CAUSE_MTIP` (=7): DUT 的 trap_cause 是
            //    二选一 (trap_hit ? expt_cause : MTIP), 参考模型只能靠这个值区分
            //    "同步异常"和"取中断"。撞上就会把一次同步异常当成中断 (n_ret = n_inst,
            //    整条流抹掉)。换一个等价的非 7 值, 覆盖度不变。
            if (ex_cause == `RTU_CAUSE_MTIP) ex_cause = 5'd12;
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
            int_seen = 1'b0;

            check_cycle();      // 用"上一拍驱动的输入 + 本拍输出"检查

            // 状态机推进 + 流水账。必须排在 check_cycle 之后: check_cycle 要在
            // dstate==D_DISP 那拍核对"摆上口的 vld"与 DUT 内部接受的 disp_acc 是否一致。
            disp_step();

            ref_retire();       // 本拍的退休 / 提交 / 冲刷

            if (trace_on && ($time > 550) && ($time < 660))
                $display("    DBG@%0t live_vld=%b retq=%b n_ret=%0d n_inst=%0d rptr=%0d pop=%0d w0v=%b w0c=%b w1v=%b w1c=%b st=%0d trig=%b trap=%b int=%b ok=%b%b%b ip=%b rdy0=%b sqst=%b exv=%b exiid=%0d w0iid=%0d",
                         $time, {cmv2,cmv1,cmv0}, ret_vld_q, n_ret, n_inst,
                         dut.u_rob.rptr, dut.u_rob.pop_n,
                         dut.u_rob.win_q0[`RTU_E_VLD], dut.u_rob.win_q0[`RTU_E_CMPLT],
                         dut.u_rob.win_q1[`RTU_E_VLD], dut.u_rob.win_q1[`RTU_E_CMPLT],
                         dut.u_flush.st_q, dut.u_commit.flush_trig, dut.u_commit.trap_hit,
                         dut.u_commit.int_take, dut.u_commit.ok0, dut.u_commit.ok1, dut.u_commit.ok2,
                         int_pending, sq_rdy0, sq_stall, ex_vld, ex_iid, dut.u_rob.win_iid0);

            check_after_retire();   // 指针位置 / iid 约定 (必须在记账之后比)

            // 本拍刚派出去的不能同拍给完成信号 (同一个边沿, 表项还没建出来)
            n_ready = n_inst;

            // 下一拍的完成 / 解析 / 异常 / 存储队列 / 中断
            gen_complete();
            gen_resolve();
            gen_expt();
            // 中断请求按**电平**建模: 置起来之后一直保持到被取走 —— 真机的 mip.MTIP
            // 就是这样, 不会自己消失 (早先按 5% 随机脉冲建模, 跑到最后经常一次都
            // 没被取到, 验收里的"中断覆盖"随机地过不了)。
            if (!allow_int)        int_pending = 1'b0;
            else if (int_seen)     int_pending = 1'b0;
            else if (!int_pending) int_pending = (({$urandom} % 100) < 20);
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
        for (int l = 0; l < 32;   l = l + 1) begin
            ref_amt[l] = l[6:0];
            ref_rat[l] = l[6:0];       // RAT 初值 = 架构映射
        end

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
