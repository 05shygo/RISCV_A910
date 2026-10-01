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

    integer      n_plan = 0;           // 下一份计划 (gen_plan 写, 下一拍才搬进 plan_n)
    logic [4:0]  n_lreg [0:2];
    logic [31:0] n_pc   [0:2];
    logic [24:0] n_chk  [0:2];
    logic        n_rfwe [0:2];
    logic [4:0]  n_flg  [0:2];
    logic [6:0]  n_opreg[0:2];
    logic [6:0]  n_s1   [0:2];
    logic [11:0] n_ca   [0:2];
    logic [2:0]  n_cop  [0:2];
    logic [4:0]  n_cimm [0:2];
    logic [2:0]  n_sqi  [0:2];
    logic [31:0] n_val  [0:2];

    integer      plan_n = 0;           // 本拍请求、下一拍要落的派遣
    logic [4:0]  p_lreg [0:2];
    logic [31:0] p_pc   [0:2];
    logic [24:0] p_chk  [0:2];
    logic        p_rfwe [0:2];
    logic [4:0]  p_flg  [0:2];
    logic [6:0]  p_opreg[0:2];
    logic [6:0]  p_s1   [0:2];
    logic [11:0] p_ca   [0:2];
    logic [2:0]  p_cop  [0:2];
    logic [4:0]  p_cimm [0:2];
    logic [2:0]  p_sqi  [0:2];
    logic [31:0] p_val  [0:2];
    logic [6:0]  p_iid  [0:2];

    logic [6:0]  got0, got1, got2;     // 本拍拿到的编号 (下一拍派遣用)
    logic        got_v0, got_v1, got_v2;

    // 摆在派遣口上的那一份 (它是否真被接受, 只有下一拍才看得见 —— DUT 用的是
    // **当拍**的 disp_stall/flushing 门控, 而 TB 是在 negedge 把数据摆上去的)。
    integer      cp_n = 0;
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
    logic [6:0]  cp_dpreg[0:2];
    logic [2:0]  cp_gotv;             // 摆这份计划时, 各车道拿到的编号是否有效

    // 派遣使能: 需要 preg 的车道必须拿到编号, 且**当拍**不 stall。
    // disp_stall 里含 flushing, 所以这一条同时覆盖冲刷窗口 (与 DUT 的 disp_acc 等价)。
    wire [2:0] lane_ok;
    // ⚠️ 必须用**与计划一起锁存**的 cp_gotv, 不能读实时的 got_v* —— 后者在同一次
    //    迭代里稍后才被刷新, 于是"摆到口上的 vld"与"TB 记的账"会用不同的值
    //    (踩过: acc_l 与 DUT 的 disp_acc 就差这一拍)。
    assign lane_ok[0] = (cp_n > 0) && ((cp_lreg[0] != 5'd0) ? cp_gotv[0] : 1'b1);
    assign lane_ok[1] = lane_ok[0] && (cp_n > 1) && ((cp_lreg[1] != 5'd0) ? cp_gotv[1] : 1'b1);
    assign lane_ok[2] = lane_ok[1] && (cp_n > 2) && ((cp_lreg[2] != 5'd0) ? cp_gotv[2] : 1'b1);
    wire [2:0] lane_go = lane_ok & {3{~disp_stall}};

    // ⚠️ 派遣是否真被接受, 由 TB **自己按同一个表达式算**, 不去读连续赋值的 d*_vld:
    //    drive_disp() 刚改完 cp_*, 同一时间步里读 d*_vld 可能还是旧值 (delta 顺序),
    //    那样 DUT 派了、TB 没记账, 两边立刻发散 (踩过: 症状是"一条也派不出去")。
    bit [2:0] acc_l;
    task automatic calc_acc;
        begin
            acc_l[0] = (cp_n > 0) && ((cp_lreg[0] != 5'd0) ? cp_gotv[0] : 1'b1);
            acc_l[1] = acc_l[0] && (cp_n > 1) && ((cp_lreg[1] != 5'd0) ? cp_gotv[1] : 1'b1);
            acc_l[2] = acc_l[1] && (cp_n > 2) && ((cp_lreg[2] != 5'd0) ? cp_gotv[2] : 1'b1);
            acc_l = acc_l & {3{~disp_stall}};
        end
    endtask

    assign d0_vld = lane_go[0];
    assign d1_vld = lane_go[1];
    assign d2_vld = lane_go[2];

    integer      errors = 0;
    integer      n_done = 0, n_trap = 0, n_int = 0, n_flush = 0;
    integer      n_store = 0, n_csr = 0, n_mret = 0, n_misp = 0;
    integer      fl_state = 0;         // 1=T 2=F1 3=F2
    integer      head_wait = 0;
    bit          trace_on = 0;
    integer      seed = 32'h1234_5678;
    integer      n_target = 200;
    bit          allow_exc, allow_int, allow_csr, allow_store, allow_branch;

    logic [2:0]  vldv;
    logic        trap_this;

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
            if (ifu_chg_vld && !trap_vld) begin
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

            // ---------- 5b) iid 约定 ----------
            if (n_ret < n_inst) begin
                if (beu_retire_iid !== x_iid[n_ret])
                    err($sformatf("retire_iid 不符: exp=%0d got=%0d (n_ret=%0d)",
                                  x_iid[n_ret], beu_retire_iid, n_ret));
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
                        if (ren_recover_map[7*l +: 7] !== ref_amt[l])
                            err($sformatf("AMT[%0d] 广播不符: exp=%0d got=%0d",
                                          l, ref_amt[l], ren_recover_map[7*l +: 7]));
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
    task automatic ref_confirm;
        begin
            if (cp_gotv[0]) ref_pend[cp_dpreg[0]] = 1'b0;
            if (cp_gotv[1]) ref_pend[cp_dpreg[1]] = 1'b0;
            if (cp_gotv[2]) ref_pend[cp_dpreg[2]] = 1'b0;
            // 只有"真的拿了编号"的车道才转占用 (dst_lreg==0 的车道没有编号)
            // 只给"真派出去、且真的用了这个编号"的车道转占用
            if (acc_l[0] && cp_gotv[0]) ref_busy[cp_dpreg[0]] = 1'b1;
            if (acc_l[1] && cp_gotv[1]) ref_busy[cp_dpreg[1]] = 1'b1;
            if (acc_l[2] && cp_gotv[2]) ref_busy[cp_dpreg[2]] = 1'b1;
        end
    endtask

    task automatic ref_retire;
        integer i;
        begin
            if (trap_vld) begin
                if (trap_cause == `RTU_CAUSE_MTIP) begin
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
                        n_ret = n_ret + 1;
                        n_done = n_done + 1;
                    end
                end
            end

            if (csr_we)    csr_file[csr_addr] = csr_wdata;
            if (csr_rd_we) pf[csr_rd_addr]    = csr_rd_wdata;

            if (ren_flush) begin
                plan_n       = 0;          // 冲刷前做的计划必须作废 (指针已复位)
                ren_preg_req = 2'd0;
                n_ret    = n_inst;
                ref_busy = 96'd0;
                ref_pend = 96'd0;
                tb_cptr  = 6'd0;
                tb_cmsb  = 1'b0;
            end
        end
    endtask

    // =======================================================================
    // 激励
    // =======================================================================
    // 把当前计划摆到派遣口上 (vld 由 lane_go 连续给, 这里只摆数据)
    task automatic drive_disp;
        begin
            cp_n = plan_n;
            for (int k = 0; k < 3; k = k + 1) begin
                cp_lreg[k]=n_lreg[k]; cp_pc[k]=n_pc[k];   cp_chk[k]=n_chk[k];
                cp_rfwe[k]=n_rfwe[k]; cp_flg[k]=n_flg[k]; cp_opreg[k]=n_opreg[k];
                cp_s1[k]=n_s1[k];     cp_ca[k]=n_ca[k];   cp_cop[k]=n_cop[k];
                cp_cimm[k]=n_cimm[k]; cp_sqi[k]=n_sqi[k]; cp_val[k]=n_val[k];
            end
            // 编号此刻就定下来 (它只能在下一拍被确认, 所以必须存副本)
            cp_dpreg[0] = got_v0 ? got0 : 7'd0;
            cp_dpreg[1] = got_v1 ? got1 : 7'd0;
            cp_dpreg[2] = got_v2 ? got2 : 7'd0;
            cp_gotv[0]  = got_v0;
            cp_gotv[1]  = got_v1;
            cp_gotv[2]  = got_v2;
            d0_pc=cp_pc[0]; d0_chk=cp_chk[0]; d0_lreg=cp_lreg[0]; d0_rfwe=cp_rfwe[0];
            d0_opreg=cp_opreg[0]; d0_s1preg=cp_s1[0]; d0_ca=cp_ca[0]; d0_cop=cp_cop[0];
            d0_cimm=cp_cimm[0]; d0_flg=cp_flg[0]; d0_sqid=cp_sqi[0]; d0_dpreg=cp_dpreg[0];
            d1_pc=cp_pc[1]; d1_chk=cp_chk[1]; d1_lreg=cp_lreg[1]; d1_rfwe=cp_rfwe[1];
            d1_opreg=cp_opreg[1]; d1_s1preg=cp_s1[1]; d1_ca=cp_ca[1]; d1_cop=cp_cop[1];
            d1_cimm=cp_cimm[1]; d1_flg=cp_flg[1]; d1_sqid=cp_sqi[1]; d1_dpreg=cp_dpreg[1];
            d2_pc=cp_pc[2]; d2_chk=cp_chk[2]; d2_lreg=cp_lreg[2]; d2_rfwe=cp_rfwe[2];
            d2_opreg=cp_opreg[2]; d2_s1preg=cp_s1[2]; d2_ca=cp_ca[2]; d2_cop=cp_cop[2];
            d2_cimm=cp_cimm[2]; d2_flg=cp_flg[2]; d2_sqid=cp_sqi[2]; d2_dpreg=cp_dpreg[2];
        end
    endtask

    // 生成本拍要请求的派遣计划 (下一拍真派)。iid 由指针镜像按 RTL 同规则算。
    task automatic gen_plan;
        int n, r;
        logic [5:0] c [0:2];
        logic       w [0:2];
        begin
            plan_n = 0;
            n = {$urandom} % 4;
            c[0] = tb_cptr;
            c[1] = (tb_cptr + 6'd1) & 6'h3f;
            c[2] = (tb_cptr + 6'd2) & 6'h3f;
            w[0] = tb_cmsb;
            w[1] = tb_cmsb ^ (tb_cptr == 6'd63);
            w[2] = tb_cmsb ^ (tb_cptr >= 6'd62);
            for (int k = 0; k < n; k = k + 1) begin
                logic [4:0] f;
                f = 5'd0;
                r = {$urandom} % 100;
                if (allow_store && r < 20)                        f[`RTU_FLG_STORE]  = 1'b1;
                else if (allow_branch && r < 40)                  f[`RTU_FLG_BRANCH] = 1'b1;
                else if (allow_csr && r < 50)                     f[`RTU_FLG_CSR]    = 1'b1;
                else if (r < 55)                                  f[`RTU_FLG_MRET]   = 1'b1;
                n_flg[k]   = f | (({$urandom} % 100 < 8) ? (5'b1 << `RTU_FLG_INTMASK) : 5'd0);
                n_lreg[k]  = {$urandom} % 32;
                n_rfwe[k]  = !(f[`RTU_FLG_STORE] || f[`RTU_FLG_BRANCH] || f[`RTU_FLG_MRET]);
                // old_preg = 该逻辑寄存器**当前的架构映射** (照参考模型自己的 AMT 推)。
                // ⚠️ 不能随手编一个: 真实机器里 old_preg 一定是"以前分配出去、现在
                //    正被占用的"那个 preg。编一个没分配过的, 退休释放就会往自由池里
                //    灌一个莫须有的编号 (池子放水 → 之后又把它发给别人)。
                //    首次写某个 lreg 时它是 <32 的初始映射, 正好覆盖"永不回收"那条门控。
                n_opreg[k] = ref_amt[n_lreg[k]];
                n_pc[k]    = {$urandom};
                n_chk[k]   = {$urandom} % (1 << 25);
                n_val[k]   = {$urandom};
                n_s1[k]    = {$urandom} % 96;
                n_ca[k]    = {$urandom} % 4096;
                n_cop[k]   = 3'b001 + ({$urandom} % 3);
                n_cimm[k]  = {$urandom} % 32;
                n_sqi[k]   = {$urandom} % 8;
                p_iid[k]   = {w[k], c[k]};
            end
            n_plan = n;                       // ⚠️ 忘了这一步就永远派 0 条
            ren_preg_req = n[1:0];
            ren_lreg0 = p_lreg[0]; ren_lreg1 = p_lreg[1]; ren_lreg2 = p_lreg[2];
        end
    endtask

    // 派遣当拍的 iid: {回绕位, cptr+k} —— 必须用**此刻**的指针镜像算。
    // ⚠️ 不能在 gen_plan 里就把 iid 算好: 计划是上一拍做的, 而指针可能已被冲刷复位,
    //    那样派出去的指令会拿到上一代的 iid (踩过: 症状是"退了一条还没派遣的指令")。
    function automatic logic [6:0] iid_at(input int k);
        logic [5:0] cc;
        logic       ww;
        begin
            cc = (tb_cptr + k) & 6'h3f;
            ww = tb_cmsb ^ (((tb_cptr + k) > 63) ? 1'b1 : 1'b0);
            iid_at = {ww, cc};
        end
    endfunction

    task automatic commit_stream;
        integer i;
        begin
            for (int k = 0; k < cp_n; k = k + 1) begin
                if (acc_l[k]) begin
                    i = n_inst;
                    p_iid[k] = iid_at(k);
                    x_pc[i]=cp_pc[k];   x_val[i]=cp_val[k];   x_lreg[i]=cp_lreg[k];
                    x_rfwe[i]=cp_rfwe[k]; x_flg[i]=cp_flg[k]; x_sqi[i]=cp_sqi[k];
                    x_dpr[i]=cp_dpreg[k];
                    x_opr[i]=cp_opreg[k]; x_iid[i]=p_iid[k];
                    x_ca[i]=cp_ca[k];   x_cop[i]=cp_cop[k];   x_cim[i]=cp_cimm[k];
                    x_cmp[i]=1'b0; x_exc[i]=1'b0; x_ec[i]=5'd0; x_etv[i]=32'd0;
                    x_tgt[i]=32'd0; x_tkn[i]=1'b0; x_msp[i]=1'b0; x_rsv[i]=1'b0;
                    n_inst = n_inst + 1;
                end
            end
        end
    endtask

    task automatic step_cptr(input int nd);
        begin
            if (nd > 0) begin
                if ((tb_cptr + nd) > 63) tb_cmsb = ~tb_cmsb;
                tb_cptr = (tb_cptr + nd) & 6'h3f;
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

            calc_acc();         // 上一拍摆上去的那次派遣, 本拍才谈得上"成没成"
            if (acc_l !== dut.u_rob.disp_acc)
                err($sformatf("acc_l=%b 与 DUT 的 disp_acc=%b 不一致 (stall=%b cp_n=%0d)",
                              acc_l, dut.u_rob.disp_acc, disp_stall, cp_n));
            // ⚠️ 摆上去的计划**只摆一拍**: 没派成就作废。
            //    跨拍重试是错的 —— §6.0 的握手窗口只有一拍 (编号在下一拍是 WF_ALLOC,
            //    再下一拍就回 FREE 了), 拿过期编号去派 = 指令拿着一个已经回池的 preg,
            //    紧接着它就会被发给别人 (踩过: 单测台第一版就是这么把池子搅乱的)。
            ref_confirm();      // 结算它的编号
            commit_stream();    // 记进参考流 (必须在清 cp_n 之前)
            nd = {1'b0, acc_l[0]} + {1'b0, acc_l[1]} + {1'b0, acc_l[2]};
            step_cptr(nd);
            cp_n = 0;           // 这份计划用完即弃 (下一拍由 drive_disp 摆新的)

            ref_retire();       // 本拍的退休 / 提交 / 冲刷

            // 抓本拍 DUT 发出来的编号 —— 下一拍派遣要用 (§6.0 的两拍语义)
            got0 = alloc0; got1 = alloc1; got2 = alloc2;
            got_v0 = alloc_vld0; got_v1 = alloc_vld1; got_v2 = alloc_vld2;
            if (got_v0) ref_pend[got0] = 1'b1;
            if (got_v1) ref_pend[got1] = 1'b1;
            if (got_v2) ref_pend[got2] = 1'b1;

            // 本拍刚派出去的不能同拍给完成信号 (同一个边沿, 表项还没建出来)
            n_ready = n_inst;

            // ⚠️ 计划要**晚一代**才摆上口: 请求在 T 拍发出 (gen_plan), 编号在 T 拍
            //    拿到 (上面刚抓), 派遣必须在 T+1 拍才发生 (§6.0)。若把 gen_plan 与
            //    drive_disp 放在同一次迭代里, 摆上去的计划配的是**上一代**编号 ——
            //    编号早已回池, 于是指令拿着一个别人的 preg。
            plan_n = n_plan;
            for (int k = 0; k < 3; k = k + 1) begin
                p_lreg[k]=n_lreg[k]; p_pc[k]=n_pc[k];   p_chk[k]=n_chk[k];
                p_rfwe[k]=n_rfwe[k]; p_flg[k]=n_flg[k]; p_opreg[k]=n_opreg[k];
                p_s1[k]=n_s1[k];     p_ca[k]=n_ca[k];   p_cop[k]=n_cop[k];
                p_cimm[k]=n_cimm[k]; p_sqi[k]=n_sqi[k]; p_val[k]=n_val[k];
            end

            // 把本拍要派的计划摆到口上, 并**当拍**记账。
            // ⚠️ 记账必须与 DUT 采样的那一刻用同一个 disp_stall: d*_vld 是连续门控,
            //    DUT 在 posedge 采到的就是"那一刻的 disp_stall" (= 本拍的值, 寄存器
            //    要到边沿才变), TB 在 negedge 读到的也是本拍的值 —— 两边必然一致。
            //    (踩过: 挪到下一拍再记账, 就会在 disp_stall 恰好在边沿翻转时错记一条。)
            // 把下一拍要派的计划摆到口上 (成不成, 下一拍由 calc_acc 结算)
            drive_disp();

            // 下一拍的完成 / 解析 / 异常 / 存储队列 / 中断
            gen_complete();
            gen_resolve();
            gen_expt();
            int_pending = allow_int && (({$urandom} % 100) < 5);
            sq_rdy0 = (({$urandom} % 100) < 90);
            sq_rdy1 = (({$urandom} % 100) < 90);
            sq_rdy2 = (({$urandom} % 100) < 90);
            sq_stall = (({$urandom} % 100) < 5);

            // 下一拍的派遣计划 (顺带为它请求 preg)
            if ((fl_state == 0) && !disp_stall) gen_plan();
            else begin
                n_plan = 0;
                ren_preg_req = 2'd0;
                cp_n = 0;                 // 口上的那一份也作废, 别在冲刷后派出去
            end

            cyc = cyc + 1;
        end
    endtask

    initial begin
        ren_preg_req=0; ren_lreg0=0; ren_lreg1=0; ren_lreg2=0;
        d0_pc=0; d1_pc=0; d2_pc=0; d0_chk=0; d1_chk=0; d2_chk=0;
        d0_lreg=0; d1_lreg=0; d2_lreg=0; d0_rfwe=0; d1_rfwe=0; d2_rfwe=0;
        d0_dpreg=0; d1_dpreg=0; d2_dpreg=0; d0_opreg=0; d1_opreg=0; d2_opreg=0;
        d0_s1preg=0; d1_s1preg=0; d2_s1preg=0;
        d0_ca=0; d1_ca=0; d2_ca=0; d0_cop=1; d1_cop=1; d2_cop=1;
        d0_cimm=0; d1_cimm=0; d2_cimm=0; d0_flg=0; d1_flg=0; d2_flg=0;
        d0_sqid=0; d1_sqid=0; d2_sqid=0;
        cv0=0; cv1=0; cv2=0; cv3=0; cv4=0; ci0=0; ci1=0; ci2=0; ci3=0; ci4=0;
        rsv_vld=0; rsv_iid=0; rsv_taken=0; rsv_misp=0; rsv_tgt=0;
        ex_vld=0; ex_iid=0; ex_cause=0; ex_tval=0;
        sq_rdy0=1; sq_rdy1=1; sq_rdy2=1; sq_stall=0;
        int_pending=0;
        csr_tvec = 32'h0000_1000;
        csr_mepc_i = 32'h0000_2000;
        got0=0; got1=0; got2=0; got_v0=0; got_v1=0; got_v2=0;
        cp_n = 0; cp_gotv = 3'd0; n_plan = 0;
        for (int k = 0; k < 3; k = k + 1) begin
            n_lreg[k]=0; n_pc[k]=0; n_chk[k]=0; n_rfwe[k]=0; n_flg[k]=0;
            n_opreg[k]=0; n_s1[k]=0; n_ca[k]=0; n_cop[k]=1; n_cimm[k]=0;
            n_sqi[k]=0; n_val[k]=0;
        end
        for (int k = 0; k < 3; k = k + 1) begin
            cp_lreg[k]=0; cp_pc[k]=0; cp_chk[k]=0; cp_rfwe[k]=0; cp_flg[k]=0;
            cp_opreg[k]=0; cp_s1[k]=0; cp_ca[k]=0; cp_cop[k]=1; cp_cimm[k]=0;
            cp_sqi[k]=0; cp_val[k]=0; cp_dpreg[k]=0;
            n_lreg[k]=0; n_pc[k]=0; n_chk[k]=0; n_rfwe[k]=0; n_flg[k]=0;
            n_opreg[k]=0; n_s1[k]=0; n_ca[k]=0; n_cop[k]=1; n_cimm[k]=0;
            n_sqi[k]=0; n_val[k]=0; p_iid[k]=0;
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
