`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU — 退休单元顶层 (doc/rtu_plan_zh.md §5 / §6)
//
// 对外端口 = §6 契约的**逐字实现**, 一条不多一条不少。任何改动都要先改 §6。
//   §6.0 物理寄存器分配握手 (两拍语义)   §6.1 输入   §6.2 输出
//   §6.3 时序与边角约定 (冲刷时间线 / disp_stall 只依赖寄存器 / CSR 完成时机)
//
// 端口风格: 扁平编号 (xxx0/xxx1/xxx2 = 程序序, 0 最老), 与前端 idu_inst0/1/2_*
// 同风格 —— 本仓与蓝本 C910 都没有 SV unpacked array 端口的先例, 而 Fmax 验收
// 要在 Vivado 上过, 不该拿新语法当第一次综合实验 (§6 的 A4)。
//
// 内部结构:
//   RTU_ROB       表项阵列 + 独热创造指针 + read_entry 影子窗口 (D5) + 完成/解析匹配
//   RTU_commit    判退级联 + 中断掩码 + 提交点副作用 (P1 链的后半段)
//   RTU_preg      四态表 + WF_ALLOC 打拍 + 96 位三端口优先编码 + AMT
//   RTU_csr_slot  CSR 单槽 + 在途门控 (§4.3 的省资源项)
//   RTU_expt      异常收集, 最旧者胜 (D9)
//   RTU_flush     冲刷状态机 + 重定向分发 (D11)
//   RTU_iid_cmp   iid 年龄比较 (**只给异常收集用**, 不许接进重定向链, D12)
// ---------------------------------------------------------------------------
module RTU (
    input  wire        cpu_clk,
    input  wire        cpu_rst,

    // ===================== §6.0 物理寄存器分配握手 =====================
    input  wire [1:0]  ren_preg_req,        // 0..3, 车道 0..n-1 是本次的请求者
    input  wire [4:0]  ren_preg_req_lreg0,  // 判 x0 用: lreg==0 的那一路不给编号
    input  wire [4:0]  ren_preg_req_lreg1,
    input  wire [4:0]  ren_preg_req_lreg2,
    output wire [6:0]  rtu_preg_alloc0,     // 给下一拍用的编号 (T 拍给, T+1 拍仍有效)
    output wire [6:0]  rtu_preg_alloc1,
    output wire [6:0]  rtu_preg_alloc2,
    output wire        rtu_preg_alloc_vld0,
    output wire        rtu_preg_alloc_vld1,
    output wire        rtu_preg_alloc_vld2,
    output wire [1:0]  rtu_preg_free_cnt,   // 剩余可用数 (饱和: 3 == ">=3")

    // ===================== §6.1 派遣 (k = 0/1/2 = 程序序) =====================
    input  wire        disp0_vld,
    input  wire [31:0] disp0_pc,
    input  wire [24:0] disp0_chk,
    input  wire [4:0]  disp0_dst_lreg,
    input  wire        disp0_rf_we,
    input  wire [6:0]  disp0_dst_preg,
    input  wire [6:0]  disp0_old_preg,
    input  wire [6:0]  disp0_src1_preg,
    input  wire [11:0] disp0_csr_addr,
    input  wire [2:0]  disp0_csr_op,
    input  wire [4:0]  disp0_csr_imm,
    input  wire [4:0]  disp0_flags,         // {is_mret, is_csr, intmask, is_store, is_branch}
    input  wire [2:0]  disp0_sq_id,

    input  wire        disp1_vld,
    input  wire [31:0] disp1_pc,
    input  wire [24:0] disp1_chk,
    input  wire [4:0]  disp1_dst_lreg,
    input  wire        disp1_rf_we,
    input  wire [6:0]  disp1_dst_preg,
    input  wire [6:0]  disp1_old_preg,
    input  wire [6:0]  disp1_src1_preg,
    input  wire [11:0] disp1_csr_addr,
    input  wire [2:0]  disp1_csr_op,
    input  wire [4:0]  disp1_csr_imm,
    input  wire [4:0]  disp1_flags,
    input  wire [2:0]  disp1_sq_id,

    input  wire        disp2_vld,
    input  wire [31:0] disp2_pc,
    input  wire [24:0] disp2_chk,
    input  wire [4:0]  disp2_dst_lreg,
    input  wire        disp2_rf_we,
    input  wire [6:0]  disp2_dst_preg,
    input  wire [6:0]  disp2_old_preg,
    input  wire [6:0]  disp2_src1_preg,
    input  wire [11:0] disp2_csr_addr,
    input  wire [2:0]  disp2_csr_op,
    input  wire [4:0]  disp2_csr_imm,
    input  wire [4:0]  disp2_flags,
    input  wire [2:0]  disp2_sq_id,

    // ===================== §6.1 完成 (p = 0..4) =====================
    input  wire        cmplt_vld0, input wire [6:0] cmplt_iid0,
    input  wire        cmplt_vld1, input wire [6:0] cmplt_iid1,
    input  wire        cmplt_vld2, input wire [6:0] cmplt_iid2,
    input  wire        cmplt_vld3, input wire [6:0] cmplt_iid3,
    input  wire        cmplt_vld4, input wire [6:0] cmplt_iid4,

    // ===================== §6.1 解析结果 (BEU) =====================
    input  wire        resolve_vld,
    input  wire [6:0]  resolve_iid,
    input  wire        resolve_taken,
    input  wire        resolve_mispred,
    input  wire [31:0] resolve_target,

    // ===================== §6.1 异常 (ID/EX/MEM 的检出点, 老级优先) =====================
    input  wire        expt_vld,
    input  wire [6:0]  expt_iid,
    input  wire [4:0]  expt_cause,
    input  wire [31:0] expt_tval,

    // ===================== §6.1 存储队列 / CSR / 中断 =====================
    input  wire        sq_rdy0,             // 退休窗口第 k 槽的 store 数据就绪
    input  wire        sq_rdy1,
    input  wire        sq_rdy2,
    input  wire        sq_stall,            // 存储队列满/下游忙 -> 压退休宽度
    input  wire [31:0] csr_rdata,           // 组合读: 地址见 rtu_csr_addr
    input  wire        int_pending,         // 已按 mstatus/mie/mip 屏蔽过

    // ===================== BEU -> RTU (D13) =====================
    // EX 级**真的发出**误预测重定向的那一拍 (mycpu.v 里就是 iu_ifu_chgflw_vld)。
    // 只用于置"未决快路重定向"锁存位 —— 把派遣冻结的窗口从"执行级重定向那拍"
    // 拉起来, 直到 F2; 并且它是"误预测不再重启前端"(D13 ②)的依据。
    input  wire        beu_redirect_vld,

    // ===================== §6.1 物理寄存器堆读口 (A1) =====================
    input  wire [31:0] preg_rdata0,         // <- PRF[rtu_preg_raddr0]
    input  wire [31:0] preg_rdata1,
    input  wire [31:0] preg_rdata2,
    input  wire [31:0] rtu_csr_src_rdata,   // <- PRF[rtu_csr_src_raddr]

    // ===================== §6.1 重定向目标的来源 (A6) =====================
    input  wire [31:0] csr_trap_vector,
    input  wire [31:0] csr_mepc,

    // ===================== §6.2 前端: 陷阱/中断/mret/误预测的重定向 =====================
    output wire        rtu_ifu_flush,
    output wire        rtu_ifu_chgflw_vld,
    output wire [31:0] rtu_ifu_chgflw_pc,
    output wire        rtu_ifu_train_vld,   // 退休点重训练 (阶段 4b 接上)
    output wire [31:0] rtu_ifu_train_pc,
    output wire [24:0] rtu_ifu_train_chk,
    output wire        rtu_ifu_train_taken,

    // ===================== §6.2 后端冲刷 (D11 的 FLUSH_1) =====================
    output wire        rtu_backend_flush,

    // ===================== §6.2 核内重定向事件 (D13 新增) =====================
    // "本拍 RTU 在重定向", 四类源**都算**(含误预测)。mycpu.v 用它驱动 `redirect`
    // (冲 IF_ID/ID_EX/EX_MEM、按掉 store 写使能、CSR 静默、训练门控)。
    // ⚠️ 与 rtu_ifu_flush **必须在顶层分开接**: D13 之后两者对误预测取值不同。
    output wire        rtu_core_redirect,

    // ===================== §6.2 BEU: D1 的最旧门控 + 冲刷屏蔽 =====================
    output wire [6:0]  rtu_beu_retire_iid,
    output wire        rtu_beu_flush_chgflw_mask,

    // ===================== §6.2 重命名级 =====================
    output wire        rtu_disp_stall,
    output wire        rtu_ren_recover_vld,
    output wire [223:0] rtu_ren_recover_map, // 32 x 7bit AMT
    output wire        rtu_ren_flush,
    output wire [6:0]  rtu_ren_free_preg0,   // 观察口 (自由池在 RTU 侧)
    output wire [6:0]  rtu_ren_free_preg1,
    output wire [6:0]  rtu_ren_free_preg2,
    output wire        rtu_ren_free_vld0,
    output wire        rtu_ren_free_vld1,
    output wire        rtu_ren_free_vld2,
    // 派遣回执 (§6.2, 2026-10-01 新增): 本拍真进了 ROB 的车道拿到的 iid。
    // 重命名级必须把它随指令带进流水线 —— cmplt_iid / resolve_iid 是按 iid 寻址的,
    // 而 RTU 表项里只存回绕位, 编号只有分配者知道 (§6.3 ⑪)。
    output wire        rtu_disp_vld0,
    output wire        rtu_disp_vld1,
    output wire        rtu_disp_vld2,
    output wire [6:0]  rtu_disp_iid0,
    output wire [6:0]  rtu_disp_iid1,
    output wire [6:0]  rtu_disp_iid2,

    // ===================== §6.2 物理寄存器堆访问 (A1) =====================
    output wire [6:0]  rtu_preg_raddr0,      // = 退休槽 k 的 dst_preg
    output wire [6:0]  rtu_preg_raddr1,
    output wire [6:0]  rtu_preg_raddr2,
    output wire [6:0]  rtu_csr_src_raddr,    // = 在途 CSR 指令的 src1_preg
    output wire        rtu_csr_rd_we,        // CSR 的 rd 结果在退休当拍写回
    output wire [6:0]  rtu_csr_rd_addr,
    output wire [31:0] rtu_csr_rd_wdata,     // = CSR 旧值

    // ===================== §6.2 提交点副作用 =====================
    output wire        rtu_store_vld0,
    output wire        rtu_store_vld1,
    output wire        rtu_store_vld2,
    output wire [2:0]  rtu_store_sq_id0,
    output wire [2:0]  rtu_store_sq_id1,
    output wire [2:0]  rtu_store_sq_id2,
    output wire        rtu_csr_we,
    output wire [11:0] rtu_csr_addr,         // 一个口两种用: 组合读地址 + 写地址
    output wire [31:0] rtu_csr_wdata,
    output wire        rtu_trap_vld,         // 同步异常或中断 (两者都写 mepc/mcause/mtval)
    output wire        rtu_mret_vld,
    output wire [31:0] rtu_trap_epc,
    output wire [31:0] rtu_trap_tval,
    output wire [4:0]  rtu_trap_cause,
    output wire [1:0]  rtu_retire_cnt,       // 0..3 (被中断 squash 的那条不计)

    // ===================== §6.2 difftest / debug =====================
    output wire        dbg_commit_vld0,
    output wire        dbg_commit_vld1,
    output wire        dbg_commit_vld2,
    output wire [31:0] dbg_commit_pc0,
    output wire [31:0] dbg_commit_pc1,
    output wire [31:0] dbg_commit_pc2,
    output wire        dbg_commit_ena0,      // 陷阱那条: vld=1 但 ena=0 (§4.5)
    output wire        dbg_commit_ena1,
    output wire        dbg_commit_ena2,
    output wire [4:0]  dbg_commit_reg0,
    output wire [4:0]  dbg_commit_reg1,
    output wire [4:0]  dbg_commit_reg2,
    output wire [31:0] dbg_commit_value0,    // 摘自 preg_rdata*, CSR 那条换成 CSR 旧值
    output wire [31:0] dbg_commit_value1,
    output wire [31:0] dbg_commit_value2
);

    // =======================================================================
    // 内部连线 —— **全部前置声明**。
    // ⚠️ 本仓有"先用后声明造 1 位隐式线网"的前科 (cpu/sim/rtl_patch/README.md,
    //    以及 §9 的 R7): 症状是语义静默错、只报 PCWM-W 警告, 不报错。
    //    所以这里一次性把跨模块的网线全列出来, 后面只赋值/连接, 不再插声明。
    // =======================================================================
    wire        flushing;                    // 冲刷窗口 (含 T 拍)
    wire        mispred_pend;                // D13: 有未决快路重定向 (T_ex+1 .. F2)
    wire        fsm_busy;
    wire        flush_lvl;                   // FLUSH_2 脉冲
    wire        expt_clr;                    // FLUSH_1: 清 expt_entry
    wire        flush_trig;
    wire [1:0]  flush_src;
    wire [31:0] flush_pc;
    wire        backend_flush;
    wire        ren_flush;
    wire        ren_recover_vld;
    wire [223:0] ren_recover_map;
    wire        beu_mask;
    wire [1:0]  pop_n;
    wire [2:0]  disp_acc;
    wire [2:0]  disp_wrap;
    wire [5:0]  cptr_idx;                    // 创造指针的二进制下标 (派遣回执)
    wire [2:0]  disp_vld_raw;
    wire [`RTU_E_W-1:0] disp_data0;
    wire [`RTU_E_W-1:0] disp_data1;
    wire [`RTU_E_W-1:0] disp_data2;
    wire [`RTU_E_W-1:0] win0, win1, win2;
    wire [6:0]  win_iid0, win_iid1, win_iid2;
    wire [6:0]  rob_occ;
    wire        rob_full;
    wire        expt_entry_vld;
    wire [6:0]  expt_entry_iid;
    wire [4:0]  expt_entry_cause;
    wire [31:0] expt_entry_tval;
    wire        csr_inflight;
    wire [6:0]  slot_src1_preg;
    wire [11:0] slot_csr_addr;
    wire [2:0]  slot_csr_op;
    wire [4:0]  slot_csr_imm;
    wire [2:0]  csr_slot_retire;
    wire [2:0]  commit_vld, write_vld;
    wire        trap_hit, int_take, mret_hit, mispred_hit, trap_or_int;
    wire [31:0] mispred_target;
    wire [31:0] trap_epc_d, trap_tval_d;
    wire [4:0]  trap_cause_d;
    wire [2:0]  ret_arch_vld, ret_kill_vld, ret_free_vld;
    wire [6:0]  ret_dst_preg0, ret_dst_preg1, ret_dst_preg2;
    wire [6:0]  ret_old_preg0, ret_old_preg1, ret_old_preg2;
    wire [4:0]  ret_dst_lreg0, ret_dst_lreg1, ret_dst_lreg2;
    wire [6:0]  free_cnt;
    wire [223:0] amt_flat;
    wire        preg_short;

    // =======================================================================
    // 派遣车道: 收口成程序序前缀 (§6 的硬约定 1; 允许少于 3 条, 不许跳号)
    // =======================================================================
    assign disp_acc[0] = disp0_vld & ~flushing;
    assign disp_acc[1] = disp_acc[0] & disp1_vld;
    assign disp_acc[2] = disp_acc[1] & disp2_vld;

    assign disp_vld_raw = {disp2_vld, disp1_vld, disp0_vld};

    // 表项拼装 (位序 = RTU_define.vh 里那张图, 一个字都不能错)
    assign disp_data0 = { 1'b1,             // vld
                          1'b0,             // cmplt
                          disp_wrap[0],     // wrap
                          disp0_pc,
                          32'd0,            // target (BEU 解析时写回)
                          disp0_chk,
                          disp0_dst_lreg,
                          disp0_dst_preg,
                          disp0_old_preg,
                          disp0_flags,
                          disp0_rf_we,
                          1'b0,             // actual_taken
                          1'b0,             // mispred
                          disp0_sq_id };
    assign disp_data1 = { 1'b1, 1'b0, disp_wrap[1], disp1_pc, 32'd0, disp1_chk,
                          disp1_dst_lreg, disp1_dst_preg, disp1_old_preg, disp1_flags,
                          disp1_rf_we, 1'b0, 1'b0, disp1_sq_id };
    assign disp_data2 = { 1'b1, 1'b0, disp_wrap[2], disp2_pc, 32'd0, disp2_chk,
                          disp2_dst_lreg, disp2_dst_preg, disp2_old_preg, disp2_flags,
                          disp2_rf_we, 1'b0, 1'b0, disp2_sq_id };

    // =======================================================================
    // ROB
    // =======================================================================
    RTU_ROB u_rob (
        .cpu_clk            (cpu_clk),
        .cpu_rst            (cpu_rst),
        .flushing           (flushing),
        .disp_vld           (disp_vld_raw),
        .disp_data0         (disp_data0),
        .disp_data1         (disp_data1),
        .disp_data2         (disp_data2),
        .cmplt_vld          ({cmplt_vld4, cmplt_vld3, cmplt_vld2, cmplt_vld1, cmplt_vld0}),
        .cmplt_iid0         (cmplt_iid0),
        .cmplt_iid1         (cmplt_iid1),
        .cmplt_iid2         (cmplt_iid2),
        .cmplt_iid3         (cmplt_iid3),
        .cmplt_iid4         (cmplt_iid4),
        .resolve_vld        (resolve_vld),
        .resolve_iid        (resolve_iid),
        .resolve_taken      (resolve_taken),
        .resolve_mispred    (resolve_mispred),
        .resolve_target     (resolve_target),
        .pop_n              (pop_n),
        .flush_lvl          (flush_lvl),
        .rtu_beu_retire_iid (rtu_beu_retire_iid),
        .win_iid0           (win_iid0),
        .win_iid1           (win_iid1),
        .win_iid2           (win_iid2),
        .win_q0             (win0),
        .win_q1             (win1),
        .win_q2             (win2),
        .occ                (rob_occ),
        .rob_full           (rob_full),
        .disp_wrap          (disp_wrap),
        .cptr_idx           (cptr_idx)
    );

    // =======================================================================
    // 派遣回执: 本拍被接受的车道在 ROB 里的 iid (§6.2 / §6.3 ⑪)
    //   车道 k 的 iid = {wrap_k, cptr_idx + k} —— 与表项里存的 (wrap, 固定下标)
    //   是同一套算法 (disp_wrap 就是表项 WRAP 位的来源, 见上面的 disp_data*)。
    //   ⚠️ 编号是给**下一拍**随指令走的, 与 §6.0 的两拍语义无关 (那条是 preg)。
    // =======================================================================
    assign rtu_disp_vld0 = disp_acc[0];
    assign rtu_disp_vld1 = disp_acc[1];
    assign rtu_disp_vld2 = disp_acc[2];
    assign rtu_disp_iid0 = {disp_wrap[0], cptr_idx};
    assign rtu_disp_iid1 = {disp_wrap[1], cptr_idx + 6'd1};
    assign rtu_disp_iid2 = {disp_wrap[2], cptr_idx + 6'd2};

    // =======================================================================
    // 异常收集 (最旧者胜)
    // =======================================================================
    RTU_expt u_expt (
        .cpu_clk   (cpu_clk),
        .cpu_rst   (cpu_rst),
        .expt_vld  (expt_vld),
        .expt_iid  (expt_iid),
        .expt_cause(expt_cause),
        .expt_tval (expt_tval),
        .flush_clr (expt_clr),
        .entry_vld (expt_entry_vld),
        .entry_iid (expt_entry_iid),
        .entry_cause(expt_entry_cause),
        .entry_tval(expt_entry_tval)
    );

    // =======================================================================
    // CSR 单槽
    // =======================================================================
    RTU_csr_slot u_csr_slot (
        .cpu_clk        (cpu_clk),
        .cpu_rst        (cpu_rst),
        .disp_csr_vld   ({ disp_acc[2] & disp2_flags[`RTU_FLG_CSR],
                           disp_acc[1] & disp1_flags[`RTU_FLG_CSR],
                           disp_acc[0] & disp0_flags[`RTU_FLG_CSR] }),
        .disp_src1_preg0(disp0_src1_preg),
        .disp_src1_preg1(disp1_src1_preg),
        .disp_src1_preg2(disp2_src1_preg),
        .disp_csr_addr0 (disp0_csr_addr),
        .disp_csr_addr1 (disp1_csr_addr),
        .disp_csr_addr2 (disp2_csr_addr),
        .disp_csr_op0   (disp0_csr_op),
        .disp_csr_op1   (disp1_csr_op),
        .disp_csr_op2   (disp2_csr_op),
        .disp_csr_imm0  (disp0_csr_imm),
        .disp_csr_imm1  (disp1_csr_imm),
        .disp_csr_imm2  (disp2_csr_imm),
        .retire_clr     (|csr_slot_retire),
        .flush_clr      (flush_lvl),
        .csr_inflight   (csr_inflight),
        .slot_src1_preg (slot_src1_preg),
        .slot_csr_addr  (slot_csr_addr),
        .slot_csr_op    (slot_csr_op),
        .slot_csr_imm   (slot_csr_imm)
    );

    // =======================================================================
    // 判退 + 提交点副作用
    // =======================================================================
    RTU_commit u_commit (
        .cpu_clk        (cpu_clk),
        .cpu_rst        (cpu_rst),
        .win0           (win0),
        .win1           (win1),
        .win2           (win2),
        .win_iid0       (win_iid0),
        .win_iid1       (win_iid1),
        .win_iid2       (win_iid2),
        .fsm_busy       (fsm_busy),
        .expt_vld       (expt_entry_vld),
        .expt_iid       (expt_entry_iid),
        .expt_cause     (expt_entry_cause),
        .expt_tval      (expt_entry_tval),
        .sq_rdy0        (sq_rdy0),
        .sq_rdy1        (sq_rdy1),
        .sq_rdy2        (sq_rdy2),
        .sq_stall       (sq_stall),
        .int_pending    (int_pending),
        .slot_src1_preg (slot_src1_preg),
        .slot_csr_addr  (slot_csr_addr),
        .slot_csr_op    (slot_csr_op),
        .slot_csr_imm   (slot_csr_imm),
        .csr_rdata      (csr_rdata),
        .csr_src_rdata  (rtu_csr_src_rdata),
        .csr_trap_vector(csr_trap_vector),
        .csr_mepc       (csr_mepc),
        .preg_rdata0    (preg_rdata0),
        .preg_rdata1    (preg_rdata1),
        .preg_rdata2    (preg_rdata2),
        .pop_n          (pop_n),
        .commit_vld     (commit_vld),
        .write_vld      (write_vld),
        .trap_hit       (trap_hit),
        .int_take       (int_take),
        .mret_hit       (mret_hit),
        .mispred_hit    (mispred_hit),
        .mispred_target (mispred_target),
        .flush_trig     (flush_trig),
        .flush_src      (flush_src),
        .flush_pc       (flush_pc),
        .trap_epc       (trap_epc_d),
        .trap_cause     (trap_cause_d),
        .trap_tval      (trap_tval_d),
        .trap_or_int    (trap_or_int),
        .ret_arch_vld   (ret_arch_vld),
        .ret_kill_vld   (ret_kill_vld),
        .ret_free_vld   (ret_free_vld),
        .ret_dst_preg0  (ret_dst_preg0),
        .ret_dst_preg1  (ret_dst_preg1),
        .ret_dst_preg2  (ret_dst_preg2),
        .ret_old_preg0  (ret_old_preg0),
        .ret_old_preg1  (ret_old_preg1),
        .ret_old_preg2  (ret_old_preg2),
        .ret_dst_lreg0  (ret_dst_lreg0),
        .ret_dst_lreg1  (ret_dst_lreg1),
        .ret_dst_lreg2  (ret_dst_lreg2),
        .store_vld      ({rtu_store_vld2, rtu_store_vld1, rtu_store_vld0}),
        .store_sq_id0   (rtu_store_sq_id0),
        .store_sq_id1   (rtu_store_sq_id1),
        .store_sq_id2   (rtu_store_sq_id2),
        .csr_we         (rtu_csr_we),
        .csr_addr       (rtu_csr_addr),
        .csr_wdata      (rtu_csr_wdata),
        .csr_rd_we      (rtu_csr_rd_we),
        .csr_rd_addr    (rtu_csr_rd_addr),
        .csr_rd_wdata   (rtu_csr_rd_wdata),
        .csr_slot_retire(csr_slot_retire),
        .preg_raddr0    (rtu_preg_raddr0),
        .preg_raddr1    (rtu_preg_raddr1),
        .preg_raddr2    (rtu_preg_raddr2),
        .csr_src_raddr  (rtu_csr_src_raddr),
        .commit_ena     ({dbg_commit_ena2, dbg_commit_ena1, dbg_commit_ena0}),
        .commit_pc0     (dbg_commit_pc0),
        .commit_pc1     (dbg_commit_pc1),
        .commit_pc2     (dbg_commit_pc2),
        .commit_reg0    (dbg_commit_reg0),
        .commit_reg1    (dbg_commit_reg1),
        .commit_reg2    (dbg_commit_reg2),
        .commit_value0  (dbg_commit_value0),
        .commit_value1  (dbg_commit_value1),
        .commit_value2  (dbg_commit_value2),
        .train_vld      (rtu_ifu_train_vld),
        .train_pc       (rtu_ifu_train_pc),
        .train_chk      (rtu_ifu_train_chk),
        .train_taken    (rtu_ifu_train_taken)
    );

    assign dbg_commit_vld0 = commit_vld[0];
    assign dbg_commit_vld1 = commit_vld[1];
    assign dbg_commit_vld2 = commit_vld[2];

    // =======================================================================
    // 物理寄存器状态 (四态表 + AMT)
    // =======================================================================
    RTU_preg u_preg (
        .cpu_clk            (cpu_clk),
        .cpu_rst            (cpu_rst),
        .ren_preg_req       (ren_preg_req),
        .ren_preg_req_lreg0 (ren_preg_req_lreg0),
        .ren_preg_req_lreg1 (ren_preg_req_lreg1),
        .ren_preg_req_lreg2 (ren_preg_req_lreg2),
        .disp_vld           (disp_acc),
        .disp_dst_preg0     (disp0_dst_preg),
        .disp_dst_preg1     (disp1_dst_preg),
        .disp_dst_preg2     (disp2_dst_preg),
        .ret_arch_vld       (ret_arch_vld),
        .ret_kill_vld       (ret_kill_vld),
        .ret_free_vld       (ret_free_vld),
        .ret_dst_preg0      (ret_dst_preg0),
        .ret_dst_preg1      (ret_dst_preg1),
        .ret_dst_preg2      (ret_dst_preg2),
        .ret_old_preg0      (ret_old_preg0),
        .ret_old_preg1      (ret_old_preg1),
        .ret_old_preg2      (ret_old_preg2),
        .ret_dst_lreg0      (ret_dst_lreg0),
        .ret_dst_lreg1      (ret_dst_lreg1),
        .ret_dst_lreg2      (ret_dst_lreg2),
        .flush_lvl          (flush_lvl),
        .rtu_preg_alloc0    (rtu_preg_alloc0),
        .rtu_preg_alloc1    (rtu_preg_alloc1),
        .rtu_preg_alloc2    (rtu_preg_alloc2),
        .rtu_preg_alloc_vld0(rtu_preg_alloc_vld0),
        .rtu_preg_alloc_vld1(rtu_preg_alloc_vld1),
        .rtu_preg_alloc_vld2(rtu_preg_alloc_vld2),
        .free_cnt           (free_cnt),
        .rtu_preg_free_cnt  (rtu_preg_free_cnt),
        .amt_flat           (amt_flat)
    );

    // 释放的观察口 (§6.2): 自由池在 RTU 侧, 这三个口是给 debug/difftest 看的
    assign rtu_ren_free_vld0 = ret_free_vld[0];
    assign rtu_ren_free_vld1 = ret_free_vld[1];
    assign rtu_ren_free_vld2 = ret_free_vld[2];
    assign rtu_ren_free_preg0 = ret_old_preg0;
    assign rtu_ren_free_preg1 = ret_old_preg1;
    assign rtu_ren_free_preg2 = ret_old_preg2;

    // =======================================================================
    // 冲刷状态机
    // =======================================================================
    RTU_flush u_flush (
        .cpu_clk        (cpu_clk),
        .cpu_rst        (cpu_rst),
        .flush_trig     (flush_trig),
        .flush_src      (flush_src),
        .flush_pc       (flush_pc),
        .amt_flat       (amt_flat),
        .beu_redirect_vld(beu_redirect_vld),
        .fsm_busy       (fsm_busy),
        .flushing       (flushing),
        .mispred_pend   (mispred_pend),
        .core_redirect  (rtu_core_redirect),
        .backend_flush  (backend_flush),
        .expt_clr       (expt_clr),
        .flush_lvl      (flush_lvl),
        .ren_flush      (ren_flush),
        .ren_recover_vld(ren_recover_vld),
        .ren_recover_map(ren_recover_map),
        .beu_mask       (beu_mask),
        .ifu_flush      (rtu_ifu_flush),
        .ifu_chgflw_vld (rtu_ifu_chgflw_vld),
        .ifu_chgflw_pc  (rtu_ifu_chgflw_pc)
    );

    assign rtu_backend_flush         = backend_flush;
    assign rtu_beu_flush_chgflw_mask = beu_mask;
    assign rtu_ren_flush             = ren_flush;
    assign rtu_ren_recover_vld       = ren_recover_vld;
    assign rtu_ren_recover_map       = ren_recover_map;

    // =======================================================================
    // 派遣停顿 —— 只依赖寄存器 (P8): ROB 占用计数、preg 空闲计数、CSR 在途、
    // 冲刷窗口、未决快路重定向 (D13)
    // =======================================================================
    assign preg_short = (free_cnt < {5'b0, ren_preg_req});

    // ⚠️ mispred_pend 是**寄存器** (见 RTU_flush) —— P8 要求这一项不许把
    //    beu_redirect_vld 组合进来 (那会造出"EX 控制锥 -> 前端捕获使能"的新长链,
    //    而 r3 的绑定路径正是 ex_csr_op -> U_ID_EX/*_reg/CE 那一族)。
    assign rtu_disp_stall = rob_full | preg_short | csr_inflight | flushing | mispred_pend;

    // =======================================================================
    // 其余提交点副作用与 retire 计数
    // =======================================================================
    assign rtu_trap_vld   = trap_or_int;
    assign rtu_mret_vld   = mret_hit;
    assign rtu_trap_epc   = trap_epc_d;
    assign rtu_trap_tval  = trap_tval_d;
    assign rtu_trap_cause = trap_cause_d;
    assign rtu_retire_cnt = pop_n;

endmodule
