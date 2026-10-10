`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_commit — 判退级联 (窗口 3 个寄存器值 -> 退休宽度 / 中断掩码 / 提交点副作用)。
//
// 这是 §4.2 里 P1 那条链的"后半段": 前半段 (64:1 mux) 已经被 RTU_ROB 的影子窗口
// 移走了, 这里面对的永远是 3 个寄存器值。
//
// 判退规则 (逐条对着 D6/D9/D10):
//   1. 候选 = vld & cmplt & (非 store 或 sq 就绪) & 不在冲刷窗口;
//   2. 必须是程序序前缀 (ret_vld[k] 依赖 ret_vld[k-1]);
//   3. 异常: expt_entry 恒为最旧, 只在槽 0 命中时生效 —— **只退到它为止**,
//      它自己写 write_vld=0 (不写 rd/不写内存/不写 CSR), 但要发交付脉冲 (ena=0),
//      并且触发一次冲刷 (§4.5 的口径);
//   4. 中断: 只在"无副作用"的槽 0 上取; 取到时槽 0 被 squash (**不发脉冲**),
//      退休宽度为 0; 取不到 (槽 0 是 store/CSR/mret) 就把宽度压到 1, 让它先退掉;
//   5. mret: 正常退休 + 冲刷 + 重定向到 mepc;
//   6. 误预测: 该分支正常退休 + 冲刷 + 重定向到表项里的 target (A6/§6.3 ⑨)。
//
// 提交点副作用也在这里出 (与计划 §5 的表格相比, 把"提交点副作用"从 RTU_flush
// 挪到了本模块 —— 需要的数据全在这边, 挪过去会多出几十根跨模块线, 是笔亏本账)。
// ---------------------------------------------------------------------------
module RTU_commit (
    input  wire                cpu_clk,
    input  wire                cpu_rst,

    // ---- 头部三窗口 (来自 RTU_ROB 的影子窗口) ----
    input  wire [`RTU_E_W-1:0] win0,
    input  wire [`RTU_E_W-1:0] win1,
    input  wire [`RTU_E_W-1:0] win2,
    // store 重放请求 (LSU 跟完成**同拍**报) —— 见下面 rp_now 的注释
    input  wire                lsu_replay_vld,
    input  wire [6:0] lsu_replay_iid,
    input  wire [6:0] win_iid0,
    input  wire [6:0] win_iid1,
    input  wire [6:0] win_iid2,

    input  wire                fsm_busy,        // 冲刷状态机非 IDLE

    // ---- 异常 / 中断 / 存储队列 ----
    input  wire                expt_vld,
    input  wire [6:0] expt_iid,
    input  wire [4:0]          expt_cause,
    input  wire [31:0]         expt_tval,
    input  wire                sq_rdy0,
    input  wire                sq_rdy1,
    input  wire                sq_rdy2,
    input  wire                sq_stall,
    input  wire                int_pending,

    // ---- CSR ----
    input  wire [`RTU_PREG_W-1:0] slot_src1_preg,
    input  wire [11:0]         slot_csr_addr,
    input  wire [2:0]          slot_csr_op,
    input  wire [4:0]          slot_csr_imm,
    input  wire [31:0]         csr_rdata,
    input  wire [31:0]         csr_src_rdata,
    input  wire [31:0]         csr_trap_vector,
    input  wire [31:0]         csr_mepc,

    // ---- 物理寄存器堆读数据 (difftest) ----
    input  wire [31:0]         preg_rdata0,
    input  wire [31:0]         preg_rdata1,
    input  wire [31:0]         preg_rdata2,

    // ---- 判退 ----
    output wire [1:0]          pop_n,
    output wire [2:0]          commit_vld,      // 交付脉冲 (陷阱那条也发)
    output wire [2:0]          write_vld,       // 真有副作用 (陷阱那条不写)
    output wire                trap_hit,
    output wire                int_take,
    output wire                mret_hit,
    output wire                mispred_hit,
    output wire [31:0]         mispred_target,
    output wire                flush_trig,
    output wire [2:0]          flush_src,
    output wire [31:0]         flush_pc,
    output wire [31:0]         trap_epc,
    output wire [4:0]          trap_cause,
    output wire [31:0]         trap_tval,
    output wire                trap_or_int,     // 要给 CSR 写 mepc/mcause/mtval

    // ---- 物理寄存器状态 (给 RTU_preg) ----
    output wire [2:0]          ret_arch_vld,
    output wire [2:0]          ret_kill_vld,
    output wire [2:0]          ret_free_vld,
    output wire [`RTU_PREG_W-1:0] ret_dst_preg0,
    output wire [`RTU_PREG_W-1:0] ret_dst_preg1,
    output wire [`RTU_PREG_W-1:0] ret_dst_preg2,
    output wire [`RTU_PREG_W-1:0] ret_old_preg0,
    output wire [`RTU_PREG_W-1:0] ret_old_preg1,
    output wire [`RTU_PREG_W-1:0] ret_old_preg2,
    output wire [4:0]          ret_dst_lreg0,
    output wire [4:0]          ret_dst_lreg1,
    output wire [4:0]          ret_dst_lreg2,

    // ---- 提交点副作用 ----
    output wire [2:0]          store_vld,
    output wire [2:0]          store_sq_id0,
    output wire [2:0]          store_sq_id1,
    output wire [2:0]          store_sq_id2,
    output wire                csr_we,
    output wire [11:0]         csr_addr,
    output wire [31:0]         csr_wdata,
    output wire                csr_rd_we,
    output wire [`RTU_PREG_W-1:0] csr_rd_addr,
    output wire [31:0]         csr_rd_wdata,
    output wire [2:0]          csr_slot_retire, // 给 RTU_csr_slot 清槽

    // ---- 物理寄存器堆读地址 (difftest / CSR 源) ----
    output wire [`RTU_PREG_W-1:0] preg_raddr0,
    output wire [`RTU_PREG_W-1:0] preg_raddr1,
    output wire [`RTU_PREG_W-1:0] preg_raddr2,
    output wire [`RTU_PREG_W-1:0] csr_src_raddr,

    // ---- difftest ----
    output wire [2:0]          commit_ena,
    output wire [31:0]         commit_pc0,
    output wire [31:0]         commit_pc1,
    output wire [31:0]         commit_pc2,
    output wire [4:0]          commit_reg0,
    output wire [4:0]          commit_reg1,
    output wire [4:0]          commit_reg2,
    output wire [31:0]         commit_value0,
    output wire [31:0]         commit_value1,
    output wire [31:0]         commit_value2,

    // ---- 退休点重训练 (阶段 4b, 2026-10-02 接上) ----
    output wire                train_vld,
    output wire [31:0]         train_pc,
    output wire [31:0]         train_target,   // = 表项的 TARGET (真实后继 PC, BTB 用)
    output wire [24:0]         train_chk,
    output wire                train_taken,
    output wire                train_is_cond,
    output wire                train_is_jal,
    output wire                train_is_jalr
);

    // -----------------------------------------------------------------------
    // 字段展开
    // -----------------------------------------------------------------------
    wire [6:0]  f0 = win0[`RTU_E_FLAGS];
    wire [6:0]  f1 = win1[`RTU_E_FLAGS];
    wire [6:0]  f2 = win2[`RTU_E_FLAGS];

    wire        w0_vld   = win0[`RTU_E_VLD];
    wire        w1_vld   = win1[`RTU_E_VLD];
    wire        w2_vld   = win2[`RTU_E_VLD];
    wire        w0_cmplt = win0[`RTU_E_CMPLT];
    wire        w1_cmplt = win1[`RTU_E_CMPLT];
    wire        w2_cmplt = win2[`RTU_E_CMPLT];

    wire        w0_store = f0[`RTU_FLG_STORE];
    wire        w1_store = f1[`RTU_FLG_STORE];
    wire        w2_store = f2[`RTU_FLG_STORE];
    wire        w0_csr   = f0[`RTU_FLG_CSR];
    wire        w1_csr   = f1[`RTU_FLG_CSR];
    wire        w2_csr   = f2[`RTU_FLG_CSR];
    wire        w0_mret  = f0[`RTU_FLG_MRET];
    wire        w1_mret  = f1[`RTU_FLG_MRET];
    wire        w2_mret  = f2[`RTU_FLG_MRET];
    wire        w0_br    = f0[`RTU_FLG_BRANCH];
    wire        w1_br    = f1[`RTU_FLG_BRANCH];
    wire        w2_br    = f2[`RTU_FLG_BRANCH];
    // 控制转移的三分类 (阶段 4b): 条件分支 = BRANCH & ~JAL & ~JALR
    wire        w0_jal   = f0[`RTU_FLG_JAL];
    wire        w1_jal   = f1[`RTU_FLG_JAL];
    wire        w2_jal   = f2[`RTU_FLG_JAL];
    wire        w0_jalr  = f0[`RTU_FLG_JALR];
    wire        w1_jalr  = f1[`RTU_FLG_JALR];
    wire        w2_jalr  = f2[`RTU_FLG_JALR];

    wire        w0_misp  = win0[`RTU_E_MISPRED];
    wire        w1_misp  = win1[`RTU_E_MISPRED];
    wire        w2_misp  = win2[`RTU_E_MISPRED];

    wire [4:0]  lreg0 = win0[`RTU_E_DST_LREG];
    wire [4:0]  lreg1 = win1[`RTU_E_DST_LREG];
    wire [4:0]  lreg2 = win2[`RTU_E_DST_LREG];

    // -----------------------------------------------------------------------
    // 1) 候选 / 2) 前缀
    // -----------------------------------------------------------------------
    wire ok0 = w0_vld & w0_cmplt & ~(w0_store & (sq_stall | ~sq_rdy0)) & ~fsm_busy;
    wire ok1 = w1_vld & w1_cmplt & ~(w1_store & (sq_stall | ~sq_rdy1)) & ~fsm_busy;
    wire ok2 = w2_vld & w2_cmplt & ~(w2_store & (sq_stall | ~sq_rdy2)) & ~fsm_busy;

    // -----------------------------------------------------------------------
    // 两个前缀, 别混 (2026-10-08, store 重放):
    //   `okp*` = **只看完成**的前缀 (改动前就是 `rv*`) —— 用来判"谁是最老的重定向"
    //            (异常/中断/mret/误预测/重放都按它数年龄);
    //   `rv*`  = 再排掉"要重放"的那条 —— **判退/提交/弹出**用它: 被标记的那条
    //            必须原地不动 (它的 store 不许落内存), 它后面的也别越过去退。
    // 中断在场时把宽度压到 1 (D10): 槽 0 先退掉, 下一拍再取中断。
    // -----------------------------------------------------------------------
    wire okp0 = ok0;
    wire okp1 = ok1 & okp0 & ~int_pending;
    wire okp2 = ok2 & okp1 & ~int_pending;

    wire rpv0 = win0[`RTU_E_REPLAY];
    wire rpv1 = win1[`RTU_E_REPLAY];
    wire rpv2 = win2[`RTU_E_REPLAY];

    // ⚠️ **同拍命中**: LSU 的这两根是跟完成一起报的 (`ct_lsu_st_wb.v:334-335`), 而
    //    完成正是让那条 store "可以退休"的东西 ⇒ 它完全可能**这一拍就在队头、这一拍
    //    就要退**。只靠寄存器标志 (rpv0) 抓不到这一拍: 标志要下一个边沿才立起来, 而
    //    那个边沿上它已经退了 (内存写也提交了) —— 单测台换种子抓到的就是这一条。
    //    ⇒ 队头那条的"这一拍报告"必须像 `trap_hit` 一样**同拍**参与判退。
    wire rp_now = lsu_replay_vld && (lsu_replay_iid == win_iid0);

    // ⚠️ 队头那条**同时陷入**时, 陷阱赢、重放标志作废 (它本来就要被冲掉、也不会
    //    提交内存写) —— 不这么做的话陷阱那条的 `pop_n = 1` 会与 `commit_vld = 000`
    //    打架 (判退级联按 `rv0` 门控而陷阱的 pop_n 不看标志), 单测台的账当场对不上。
    //    陷阱要照常发交付脉冲 (ena=0), 所以 `rv0` 在那一拍必须是 1。
    wire rp_head = (rpv0 | rp_now) & ~trap_hit;

    wire rv0 = ok0  & ~rp_head;
    wire rv1 = ok1  & rv0 & ~int_pending & ~rpv1;
    wire rv2 = ok2  & rv1 & ~int_pending & ~rpv2;

    // -----------------------------------------------------------------------
    // 3) 异常 / 4) 中断 / 5) mret / 6) 误预测
    // -----------------------------------------------------------------------
    assign trap_hit = expt_vld & okp0 & (expt_iid == win_iid0);

    assign int_take = int_pending & okp0 & ~w0_store & ~w0_csr & ~w0_mret & ~trap_hit;

    assign mret_hit = okp0 & w0_mret & ~trap_hit & ~int_take;

    wire mis0 = okp0 & w0_br & w0_misp;
    wire mis1 = okp1 & w1_br & w1_misp;
    wire mis2 = okp2 & w2_br & w2_misp;

    // ---- store 重放 (第 5 类冲刷, 2026-10-08) ----
    // 谁赢 = **位置最靠前(最老)的那个重定向** —— 与误预测同一套年龄口径 (okp*),
    // 因为 `rp*` 与 `mis*` 各占一个槽、不会同槽 (store 不是分支)。
    // ⚠️ 为什么必须按年龄仲裁: 重放要求"从它的 PC 重取", 而更年轻的误预测冲刷会
    //    重取到**分支的目标**(比重放那条还靠后) ⇒ 把要重放的 store 永久跳过、
    //    它的内存写丢掉。反过来, 更老的误预测赢是对的 (那条 store 在错误路径上,
    //    本来就不该执行)。
    wire rp0 = okp0 & rp_head;
    wire rp1 = okp1 & rpv1;
    wire rp2 = okp2 & rpv2;
    wire replay_hit = rp0 | rp1 | rp2;

    // ⚠️ 必须用 `assign` —— `mispred_hit` 在端口表里已经是 `output wire`,
    //    模块内再写一次 `wire mispred_hit = ...` 不会成为驱动源, 端口网悬空 (Z),
    //    于是 `flush_trig = ... | Z` 变成 X, 冲刷 FSM 一上电就进 X 态 (踩过)。
    // ⚠️ 抑制**必须用原始标志位 `rpv*`, 不能用 `rp*`** —— `rp*` 还额外要求那一槽
    //    "这一拍可退" (ok*: 完成 + sq 就绪 + FSM 空闲)。队头那条 store 卡在 `sq_rdy`
    //    上时 `rp0 = 0`, 于是**更年轻的**误预测就压过重放、重定向到分支目标, 把这条
    //    要重放的 store 永久跳过 —— 正是要防的那件事 (单测台换种子抓到的)。
    //    "在途且被标记"本身就是 `rpv*` (它随 pop/flush 清), 不需要 ok 参与。
    assign mispred_hit = (mis0 & ~(rpv0 | rp_now)) | (mis1 & ~rpv0 & ~rpv1 & ~rp_now)
                       | (mis2 & ~rpv0 & ~rpv1 & ~rpv2 & ~rp_now);

    assign mispred_target = (mis0 & ~(rpv0 | rp_now))        ? win0[`RTU_E_TARGET] :
                            (mis1 & ~rpv0 & ~rpv1 & ~rp_now) ? win1[`RTU_E_TARGET] :
                                                               win2[`RTU_E_TARGET];

    assign flush_trig = trap_hit | int_take | mret_hit | replay_hit | mispred_hit;
    assign flush_src  = trap_hit    ? `RTU_FS_EXPT   :
                        int_take    ? `RTU_FS_INT    :
                        mret_hit    ? `RTU_FS_MRET   :
                        replay_hit  ? `RTU_FS_REPLAY : `RTU_FS_MISPRED;

    // 重定向目标: 陷阱/中断 -> mtvec 解算值; mret -> mepc; 误预测 -> 分支的真实目标
    assign flush_pc = (trap_hit | int_take) ? csr_trap_vector :
                      mret_hit              ? csr_mepc        :
                      replay_hit            ? (rp0 ? win0[`RTU_E_PC] :
                                               rp1 ? win1[`RTU_E_PC] : win2[`RTU_E_PC]) :
                                              mispred_target;

    assign trap_epc   = win0[`RTU_E_PC];                      // 陷阱/中断都落在槽 0
    assign trap_cause = trap_hit ? expt_cause : `RTU_CAUSE_MTIP;
    assign trap_tval  = trap_hit ? expt_tval  : 32'd0;
    assign trap_or_int = trap_hit | int_take;

    // -----------------------------------------------------------------------
    // 退休宽度与逐槽交付
    // -----------------------------------------------------------------------
    wire [1:0] pop_pre = rv2 ? 2'd3 : rv1 ? 2'd2 : rv0 ? 2'd1 : 2'd0;

    assign pop_n      = int_take ? 2'd0 : trap_hit ? 2'd1 : pop_pre;

    // commit_vld: 发交付脉冲的槽 (陷阱那条发, 靠 ena=0)
    // write_vld : 真有副作用的槽 (陷阱那条没有)
    // ⚠️ 槽 1/2 必须**同时也被 trap_hit 门控**: 陷阱只退到它自己为止 (pop_n = 1),
    //    若这两路还挂着, 交付脉冲就会报出 011 而 `rtu_retire_cnt` 报 1 —— 两者对不上,
    //    单测台按交付脉冲逐槽核对时会去核一条**根本没退休**的指令 (踩过:
    //    `retire_cnt=1 与提交脉冲 011 不符`, 连带一串 CSR 假失败)。
    //    `ena` 那边本来就被 ~trap_hit 清零, 所以这条只影响"报了哪几槽"。
    assign commit_vld = { rv2 & ~int_take & ~trap_hit,
                          rv1 & ~int_take & ~trap_hit,
                          rv0 & ~int_take };
    assign write_vld  = { rv2 & ~int_take & ~trap_hit,
                          rv1 & ~int_take & ~trap_hit,
                          rv0 & ~int_take & ~trap_hit };

    // -----------------------------------------------------------------------
    // 物理寄存器状态转移
    // -----------------------------------------------------------------------
    wire [2:0] rf_we   = { win2[`RTU_E_RF_WE], win1[`RTU_E_RF_WE], win0[`RTU_E_RF_WE] };
    wire [2:0] lreg_nz = { |lreg2, |lreg1, |lreg0 };
    wire [2:0] wr_eff  = write_vld & rf_we & lreg_nz;

    assign ret_arch_vld = wr_eff;                       // dst_preg -> ARCH (+ AMT)
    assign ret_kill_vld = { (trap_hit & rf_we[2] & (|lreg2)),
                            (trap_hit & rf_we[1] & (|lreg1)),
                            (trap_hit & rf_we[0] & (|lreg0)) };  // 陷阱那条: 分配过但没写

    assign ret_dst_preg0 = win0[`RTU_E_DST_PREG];
    assign ret_dst_preg1 = win1[`RTU_E_DST_PREG];
    assign ret_dst_preg2 = win2[`RTU_E_DST_PREG];
    assign ret_old_preg0 = win0[`RTU_E_OLD_PREG];
    assign ret_old_preg1 = win1[`RTU_E_OLD_PREG];
    assign ret_old_preg2 = win2[`RTU_E_OLD_PREG];
    assign ret_dst_lreg0 = lreg0;
    assign ret_dst_lreg1 = lreg1;
    assign ret_dst_lreg2 = lreg2;

    // ⚠️ 最容易漏的一行 (D2 / D1.2): "被顶掉的映射"什么时候回自由池。
    //    判据是 `old_preg != dst_preg`, **不是** `old_preg >= 32`。两件事分开看:
    //
    //    * **阶段 1** (恒等映射 `dst = old = p_<lreg>`): 恒假 ⇒ 一位不动。
    //      老判据 `>= 32` 在恒等映射下同样恒假 —— 这正是它当年被写成 `>= 32` 的
    //      真实意图: "别把刚转成 ARCH 的那个编号又放回池子"。
    //    * **阶段 2** (真重命名): `old` 来自 RAT 的活编号 (ARCH 或 ALLOC 态),
    //      `dst` 来自 FREE 池 (分配那一刻必是 FREE) ⇒ 必然不等 ⇒ 恒真。
    //      于是**初始映射 p0..p31 被顶掉时也会回收** (照 C910: 初始映射的 entry
    //      起在 RETIRE 态, 被顶掉走 RETIRE -> RELEASE -> DEALLOC 回池子),
    //      自由池恒 64, 而不是收敛到 33。
    //
    // ⚠️ 为什么非要留一条判据 (而不是干脆 `ret_free_vld = wr_eff`):
    //    若 `old == dst`, 同一个编号会**同拍**被写两次 —— `ret_arch_vld` 把它转
    //    ARCH、`ret_free_vld` 又把它放回 FREE。状态表的优先级让 ARCH 赢, 但
    //    `n_freed` 计数器照样 +1 ⇒ **账目与状态表当场对不上** (正是 §7 读法 A
    //    那条"必须配套的微调"的同一个坑, 只是换了个方向)。
    //
    //    (中间网线必须先声明再用 —— 双重 part-select `win2[..][6:5]` 是非法语法,
    //     而漏声明会退化成 1 位隐式线网, 症状是静默错。)
    wire [`RTU_PREG_W-1:0] old0 = win0[`RTU_E_OLD_PREG];
    wire [`RTU_PREG_W-1:0] old1 = win1[`RTU_E_OLD_PREG];
    wire [`RTU_PREG_W-1:0] old2 = win2[`RTU_E_OLD_PREG];

    assign ret_free_vld = wr_eff & { (old2 != ret_dst_preg2),
                                     (old1 != ret_dst_preg1),
                                     (old0 != ret_dst_preg0) };

    // -----------------------------------------------------------------------
    // 提交点副作用
    // -----------------------------------------------------------------------
    assign store_vld   = write_vld & { w2_store, w1_store, w0_store };
    assign store_sq_id0 = win0[`RTU_E_SQ_ID];
    assign store_sq_id1 = win1[`RTU_E_SQ_ID];
    assign store_sq_id2 = win2[`RTU_E_SQ_ID];

    wire csr_in0 = write_vld[0] & w0_csr;
    wire csr_in1 = write_vld[1] & w1_csr;
    wire csr_in2 = write_vld[2] & w2_csr;

    assign csr_slot_retire = {csr_in2, csr_in1, csr_in0};
    assign csr_addr        = slot_csr_addr;      // 组合读地址与写地址同值 (§6.3 ⑤)

    wire        csr_is_imm = slot_csr_op[2];
    wire [31:0] csr_src    = csr_is_imm ? {27'b0, slot_csr_imm} : csr_src_rdata;
    wire [31:0] csr_wdata_i= (slot_csr_op[1:0] == 2'b01) ? csr_src :
                             (slot_csr_op[1:0] == 2'b10) ? (csr_rdata |  csr_src) :
                                                           (csr_rdata & ~csr_src);
    assign csr_wdata = csr_wdata_i;

    // 写不写 CSR 与 Control.v 同口径: RW 恒写; RS/RC 看源非零。
    // (src1_preg == 0 等价于 rs1 域是 x0 —— 因为 x0 恒映射到 p0, 且 p0 永不进自由池)
    wire csr_src_nz = csr_is_imm ? (|slot_csr_imm) : (|slot_src1_preg);
    assign csr_we   = (csr_in0 | csr_in1 | csr_in2)
                    & ((slot_csr_op[1:0] == 2'b01) | csr_src_nz);

    // CSR 的 rd 值 = **旧值**, 三种 op 一样; 它到退休这拍才算得出来, 所以走独立写口
    wire csr_hit      = csr_in0 | csr_in1 | csr_in2;
    wire [`RTU_PREG_W-1:0] csr_dp  = csr_in0 ? win0[`RTU_E_DST_PREG] :
                         csr_in1 ? win1[`RTU_E_DST_PREG] : win2[`RTU_E_DST_PREG];
    wire [4:0] csr_dl  = csr_in0 ? lreg0 : csr_in1 ? lreg1 : lreg2;
    wire       csr_rfw = csr_in0 ? win0[`RTU_E_RF_WE] :
                         csr_in1 ? win1[`RTU_E_RF_WE] : win2[`RTU_E_RF_WE];

    assign csr_rd_we    = csr_hit & csr_rfw & (|csr_dl);
    assign csr_rd_addr  = csr_dp;
    assign csr_rd_wdata = csr_rdata;

    // -----------------------------------------------------------------------
    // 物理寄存器堆读地址
    // -----------------------------------------------------------------------
    assign preg_raddr0 = win0[`RTU_E_DST_PREG];
    assign preg_raddr1 = win1[`RTU_E_DST_PREG];
    assign preg_raddr2 = win2[`RTU_E_DST_PREG];
    assign csr_src_raddr = slot_src1_preg;

    // -----------------------------------------------------------------------
    // difftest
    // -----------------------------------------------------------------------
    assign commit_ena    = commit_vld & rf_we & ~{3{trap_hit}};
    assign commit_pc0    = win0[`RTU_E_PC];
    assign commit_pc1    = win1[`RTU_E_PC];
    assign commit_pc2    = win2[`RTU_E_PC];
    assign commit_reg0   = lreg0;
    assign commit_reg1   = lreg1;
    assign commit_reg2   = lreg2;
    // CSR 指令的 rd 值就是 CSR 旧值 (它不走普通写回), 所以这里要二选一
    assign commit_value0 = w0_csr ? csr_rdata : preg_rdata0;
    assign commit_value1 = w1_csr ? csr_rdata : preg_rdata1;
    assign commit_value2 = w2_csr ? csr_rdata : preg_rdata2;

    // -----------------------------------------------------------------------
    // 退休点重训练 (阶段 4b) + 训练 FIFO (D1.1 ①, 2026-10-02)
    //
    // 训练源 = 退休窗口里的控制转移, **按程序序逐条发出** (窗口里有多条时由下面的
    // FIFO 排队, 不再丢)。
    //
    // 为什么搬到这里 (计划 §7-4b): 乱序下分支是**乱序完成/解析**的, 留在 EX 级训练
    // 会把 GHR 按乱序顺序推、方向表被静默带偏。这与"重定向必须最旧"是同一个约束
    // 的两面。顺带修掉错误路径训练 (EX 那份只有 `~stall & ~redirect` 两道门)。
    //
    // 口径对齐 (与搬走之前的 EX 级逐条对照过, 为的是 §7-4c 的等价性证据。
    // 实测: branch_bench 57344 条条件分支里误预测 2988 → 2990 (差 2 条),
    // 指令数逐位一致 —— 差的那些是"训练晚 2~3 拍"期间被再次取到的极少数分支,
    // 属训练时机的固有代价, 不是数据错):
    //   * 用 `commit_vld` 而**不是** `write_vld` —— 陷阱那条 (`ena=0`, 只报不写)
    //     原来在 EX 就已经训练过一次, 这里保持同口径。**有意**不"顺手改对"。
    //   * `train_taken` 直接用表项的 `TAKEN`: `rtu_resolve_taken` 对条件分支是
    //     实际方向、对 JAL/JALR 恒 1 (mycpu.v), 与 EX 的
    //     `(npc_op==BRANCH) ? ex_br_taken : 1'b1` 同值。
    //   * `train_chk` 用表项里那份 (取指时打包、随指令走完整条流水),
    //     而不是 EX 当拍现读的 chk —— 后者在乱序下可能属于**另一条**指令。
    //
    // =======================================================================
    // 退休窗口三槽各自的"控制转移现场"
    // =======================================================================
    // ⚠️ 先声明再用 (本仓有"先用后声明造 1 位隐式线网"的前科, §9 R7):
    wire tr0 = commit_vld[0] & w0_br;
    wire tr1 = commit_vld[1] & w1_br;
    wire tr2 = commit_vld[2] & w2_br;
    wire [2:0]  tr    = { tr2, tr1, tr0 };          // 哪几槽是控制转移 (程序序)
    wire        any_tr= |tr;
    wire [2:0]  tr_jal  = { w2_jal,  w1_jal,  w0_jal  };
    wire [2:0]  tr_jalr = { w2_jalr, w1_jalr, w0_jalr };
    // 三分类互斥 (条件分支 = is_branch & ~jal & ~jalr), 与 EX 的
    // `iu_btb_is_cond/is_jal/is_jalr` 同集合 —— BTB 靠它选"写哪一类"。
    wire [2:0]  tr_cnd  = tr & ~tr_jal & ~tr_jalr;

    // =======================================================================
    // 训练 FIFO (D1.1 ①, 2026-10-02)
    //
    // **为什么加它**: 退休窗口有 3 槽, 里面**可能同时有 2~3 条控制转移**
    //   (`beq; jal; beq` 相邻三条, 前面被 sq_stall/冲刷之类卡一下, 解卡后一起退)。
    //   训练口只有一路, 原来只发最老那条、其余**静默丢掉** ⇒ 方向表学不到它们。
    //   ⚠️ 这在**单发射核里就会发生** —— 同拍退休是 ROB 窗口宽度决定的, 与分支
    //      执行单元有几个无关 ⇒ 不等乱序也该修。
    //
    // **为什么"排队晚几拍再训练"是对的** (整套做法的前提): 训练写的是**表项里那份
    //   `chk` 快照**索引到的位置 (BHT: pc + ghr 快照; TAGE: 再加 fpred; BTB: pc),
    //   与**当前**的 GHR/预测器状态无关 ⇒ 晚几拍写进去命中的还是同一格, 逐位相同。
    //   所以 FIFO 只改"何时写", 不改"写什么"。
    //
    // **时序**: 队列空时"最老那条直通"(零延迟) —— 保证"一窗一条"这个常见情形的
    //   行为与加 FIFO 之前**逐位相同** (CoreMark 的账不受影响)。
    // **顺序**: FIFO 序 = 程序序。**溢出**: 丢最年轻的并内部计数 (`tr_ovf_cnt`,
    //   不上端口; TB 用层次引用看)。
    // ⚠️ 冲刷**不清**队列: 里面装的是**已退休**分支的架构事实, 更年轻的指令被冲掉
    //    不影响它们。
    // ⚠️ 深度 4 的依据: 每拍最多进 3 条、出 1 条 ⇒ 最坏净增 2/拍, 要连续两拍
    //    "一窗三条控制转移"才溢出 (即 6 条相邻的控制转移)。改深度要同步改
    //    `q_*`/`nq_*` 的数组下标范围与 `TR_D`。
    // =======================================================================
    localparam TR_D = 4;

    reg  [2:0]  q_cnt;
    reg  [31:0] q_pc  [0:TR_D-1];
    reg  [31:0] q_tgt [0:TR_D-1];
    reg  [24:0] q_chk [0:TR_D-1];
    reg         q_tkn [0:TR_D-1];
    reg         q_cnd [0:TR_D-1];
    reg         q_jal [0:TR_D-1];
    reg         q_jlr [0:TR_D-1];

    reg  [2:0]  nq_cnt;
    reg  [31:0] nq_pc  [0:TR_D-1];
    reg  [31:0] nq_tgt [0:TR_D-1];
    reg  [24:0] nq_chk [0:TR_D-1];
    reg         nq_tkn [0:TR_D-1];
    reg         nq_cnd [0:TR_D-1];
    reg         nq_jal [0:TR_D-1];
    reg         nq_jlr [0:TR_D-1];

    // 直通: 队列空 + 本拍有控制转移 ⇒ 最老那条当拍就走 (不占队列, 零延迟)
    wire [1:0]  tr_old = tr[0] ? 2'd0 : tr[1] ? 2'd1 : 2'd2;
    wire        bp     = (q_cnt == 3'd0) & any_tr;
    wire        pop    = (q_cnt != 3'd0);                 // 队非空 ⇒ 每拍吐一条

    // 进队列的: 除"直通那条"之外的其余控制转移
    wire [2:0]  push_en = tr & ~(bp ? (3'b001 << tr_old) : 3'b000);

    // 输出 (直通取窗口里最老的; 否则取队头 q_*[0])
    wire [1:0]  osel = bp ? tr_old : 2'd0;
    assign train_vld    = bp | pop;
    assign train_pc     = bp ? ((osel == 2'd0) ? win0[`RTU_E_PC]     :
                                (osel == 2'd1) ? win1[`RTU_E_PC]     : win2[`RTU_E_PC])     : q_pc[0];
    // `TARGET` 是 BEU 在解析那拍写回表项的真实后继 PC (= EX 的 `actual_npc`),
    // 也就是原来 `iu_btb_target` 的驱动源。不跳的条件分支它就是 pc+4 ——
    // BTB 的"不跳"训练用不上目标, 由 upd_taken 决定写不写。
    assign train_target = bp ? ((osel == 2'd0) ? win0[`RTU_E_TARGET] :
                                (osel == 2'd1) ? win1[`RTU_E_TARGET] : win2[`RTU_E_TARGET]) : q_tgt[0];
    assign train_chk    = bp ? ((osel == 2'd0) ? win0[`RTU_E_CHK]    :
                                (osel == 2'd1) ? win1[`RTU_E_CHK]    : win2[`RTU_E_CHK])    : q_chk[0];
    assign train_taken  = bp ? ((osel == 2'd0) ? win0[`RTU_E_TAKEN]  :
                                (osel == 2'd1) ? win1[`RTU_E_TAKEN]  : win2[`RTU_E_TAKEN])  : q_tkn[0];
    assign train_is_jal = bp ? tr_jal[osel]  : q_jal[0];
    assign train_is_jalr= bp ? tr_jalr[osel] : q_jlr[0];
    assign train_is_cond= bp ? tr_cnd[osel]  : q_cnd[0];

    // ---------------- 队列的下一拍 ----------------
    reg  [2:0]  n_acc;            // 本拍要进队列的条数 (0..3)
    reg  [5:0]  acc_sel;          // 紧凑化之后, 第 j 条对应哪条车道 (3 × 2bit)
    reg  [31:0] a_pc  [0:2];      // 按紧凑序排好的待入队数据
    reg  [31:0] a_tgt [0:2];
    reg  [24:0] a_chk [0:2];
    reg         a_tkn [0:2];
    reg         a_cnd [0:2];
    reg         a_jal [0:2];
    reg         a_jlr [0:2];

    integer k, j;

    always @(*) begin
        // ① 紧凑化: 把"要进队列的车道"按程序序压成 0,1,2 号
        // ⚠️ `acc_sel` 必须**无条件先清 0**: 它在 n_acc==0 那几档不被赋值, 不初始化
        //    综合会推出一排锁存器 (仿真看不出来 —— n_push==0 时它根本不被使用)。
        n_acc   = 3'd0;
        acc_sel = 6'd0;
        if (push_en[0]) begin acc_sel[2*n_acc +: 2] = 2'd0; n_acc = n_acc + 3'd1; end
        if (push_en[1]) begin acc_sel[2*n_acc +: 2] = 2'd1; n_acc = n_acc + 3'd1; end
        if (push_en[2]) begin acc_sel[2*n_acc +: 2] = 2'd2; n_acc = n_acc + 3'd1; end
        for (j = 0; j < 3; j = j + 1) begin
            a_pc [j] = (acc_sel[2*j +: 2] == 2'd0) ? win0[`RTU_E_PC]     :
                       (acc_sel[2*j +: 2] == 2'd1) ? win1[`RTU_E_PC]     : win2[`RTU_E_PC];
            a_tgt[j] = (acc_sel[2*j +: 2] == 2'd0) ? win0[`RTU_E_TARGET] :
                       (acc_sel[2*j +: 2] == 2'd1) ? win1[`RTU_E_TARGET] : win2[`RTU_E_TARGET];
            a_chk[j] = (acc_sel[2*j +: 2] == 2'd0) ? win0[`RTU_E_CHK]    :
                       (acc_sel[2*j +: 2] == 2'd1) ? win1[`RTU_E_CHK]    : win2[`RTU_E_CHK];
            a_tkn[j] = (acc_sel[2*j +: 2] == 2'd0) ? win0[`RTU_E_TAKEN]  :
                       (acc_sel[2*j +: 2] == 2'd1) ? win1[`RTU_E_TAKEN]  : win2[`RTU_E_TAKEN];
            a_cnd[j] = tr_cnd [acc_sel[2*j +: 2]];
            a_jal[j] = tr_jal [acc_sel[2*j +: 2]];
            a_jlr[j] = tr_jalr[acc_sel[2*j +: 2]];
        end
    end

    // 队列腾出的位置 (pop 之后) 与放得下的条数
    wire [2:0] n_cnp = pop ? (q_cnt - 3'd1) : q_cnt;
    wire [2:0] space = 3'd4 - n_cnp;
    wire [2:0] n_push= (n_acc <= space) ? n_acc : space;
    wire [2:0] n_drop= n_acc - n_push;

    always @(*) begin
        // ② 下一拍: 前 n_cnp 项来自"pop 之后的残余", 接着放本拍接受的, 剩下清 0
        //    (pop 是 0/1, 残余的源下标就是 k + pop)
        for (k = 0; k < TR_D; k = k + 1) begin
            if (k < n_cnp) begin
                nq_pc [k] = q_pc [k + pop];  nq_tgt[k] = q_tgt[k + pop];
                nq_chk[k] = q_chk[k + pop];  nq_tkn[k] = q_tkn[k + pop];
                nq_cnd[k] = q_cnd[k + pop];  nq_jal[k] = q_jal[k + pop];
                nq_jlr[k] = q_jlr[k + pop];
            end else if (k < (n_cnp + n_push)) begin
                nq_pc [k] = a_pc [k - n_cnp]; nq_tgt[k] = a_tgt[k - n_cnp];
                nq_chk[k] = a_chk[k - n_cnp]; nq_tkn[k] = a_tkn[k - n_cnp];
                nq_cnd[k] = a_cnd[k - n_cnp]; nq_jal[k] = a_jal[k - n_cnp];
                nq_jlr[k] = a_jlr[k - n_cnp];
            end else begin
                nq_pc [k] = 32'd0; nq_tgt[k] = 32'd0; nq_chk[k] = 25'd0;
                nq_tkn[k] = 1'b0;  nq_cnd[k] = 1'b0;  nq_jal[k] = 1'b0; nq_jlr[k] = 1'b0;
            end
        end
        nq_cnt = n_cnp + n_push;
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            q_cnt <= 3'd0;
            for (k = 0; k < TR_D; k = k + 1) begin
                q_pc[k] <= 32'd0; q_tgt[k] <= 32'd0; q_chk[k] <= 25'd0;
                q_tkn[k] <= 1'b0; q_cnd[k] <= 1'b0; q_jal[k] <= 1'b0; q_jlr[k] <= 1'b0;
            end
        end else begin
            q_cnt <= nq_cnt;
            for (k = 0; k < TR_D; k = k + 1) begin
                q_pc[k] <= nq_pc[k]; q_tgt[k] <= nq_tgt[k]; q_chk[k] <= nq_chk[k];
                q_tkn[k] <= nq_tkn[k]; q_cnd[k] <= nq_cnd[k];
                q_jal[k] <= nq_jal[k]; q_jlr[k] <= nq_jlr[k];
            end
        end
    end

    // 溢出计数: 只给 TB/调试看 (层次引用), **不上端口** (§6 契约不动)
    reg [7:0] tr_ovf_cnt;
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)     tr_ovf_cnt <= 8'd0;
        else if (|n_drop) tr_ovf_cnt <= tr_ovf_cnt + {5'b0, n_drop};
    end

endmodule
