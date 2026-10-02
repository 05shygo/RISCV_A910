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
    input  wire [6:0]          win_iid0,
    input  wire [6:0]          win_iid1,
    input  wire [6:0]          win_iid2,

    input  wire                fsm_busy,        // 冲刷状态机非 IDLE

    // ---- 异常 / 中断 / 存储队列 ----
    input  wire                expt_vld,
    input  wire [6:0]          expt_iid,
    input  wire [4:0]          expt_cause,
    input  wire [31:0]         expt_tval,
    input  wire                sq_rdy0,
    input  wire                sq_rdy1,
    input  wire                sq_rdy2,
    input  wire                sq_stall,
    input  wire                int_pending,

    // ---- CSR ----
    input  wire [6:0]          slot_src1_preg,
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
    output wire [1:0]          flush_src,
    output wire [31:0]         flush_pc,
    output wire [31:0]         trap_epc,
    output wire [4:0]          trap_cause,
    output wire [31:0]         trap_tval,
    output wire                trap_or_int,     // 要给 CSR 写 mepc/mcause/mtval

    // ---- 物理寄存器状态 (给 RTU_preg) ----
    output wire [2:0]          ret_arch_vld,
    output wire [2:0]          ret_kill_vld,
    output wire [2:0]          ret_free_vld,
    output wire [6:0]          ret_dst_preg0,
    output wire [6:0]          ret_dst_preg1,
    output wire [6:0]          ret_dst_preg2,
    output wire [6:0]          ret_old_preg0,
    output wire [6:0]          ret_old_preg1,
    output wire [6:0]          ret_old_preg2,
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
    output wire [6:0]          csr_rd_addr,
    output wire [31:0]         csr_rd_wdata,
    output wire [2:0]          csr_slot_retire, // 给 RTU_csr_slot 清槽

    // ---- 物理寄存器堆读地址 (difftest / CSR 源) ----
    output wire [6:0]          preg_raddr0,
    output wire [6:0]          preg_raddr1,
    output wire [6:0]          preg_raddr2,
    output wire [6:0]          csr_src_raddr,

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

    // 中断在场时把宽度压到 1 (D10): 槽 0 先退掉, 下一拍再取中断
    wire rv0 = ok0;
    wire rv1 = ok1 & rv0 & ~int_pending;
    wire rv2 = ok2 & rv1 & ~int_pending;

    // -----------------------------------------------------------------------
    // 3) 异常 / 4) 中断 / 5) mret / 6) 误预测
    // -----------------------------------------------------------------------
    assign trap_hit = expt_vld & rv0 & (expt_iid == win_iid0);

    assign int_take = int_pending & rv0 & ~w0_store & ~w0_csr & ~w0_mret & ~trap_hit;

    assign mret_hit = rv0 & w0_mret & ~trap_hit & ~int_take;

    wire mis0 = rv0 & w0_br & w0_misp;
    wire mis1 = rv1 & w1_br & w1_misp;
    wire mis2 = rv2 & w2_br & w2_misp;
    assign mispred_hit = mis0 | mis1 | mis2;

    assign mispred_target = mis0 ? win0[`RTU_E_TARGET] :
                            mis1 ? win1[`RTU_E_TARGET] : win2[`RTU_E_TARGET];

    assign flush_trig = trap_hit | int_take | mret_hit | mispred_hit;
    assign flush_src  = trap_hit ? `RTU_FS_EXPT :
                        int_take ? `RTU_FS_INT  :
                        mret_hit ? `RTU_FS_MRET : `RTU_FS_MISPRED;

    // 重定向目标: 陷阱/中断 -> mtvec 解算值; mret -> mepc; 误预测 -> 分支的真实目标
    assign flush_pc = (trap_hit | int_take) ? csr_trap_vector :
                      mret_hit              ? csr_mepc        :
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

    // ⚠️ 最容易漏的一行: p0..p31 是 x0..x31 的初始映射, 永不回收 (D2)。
    //    这里判 `>= 32`, 且只在"这条真的分配过 preg"时才放 (wr_eff)。
    //    反例: 不判的话第一次写 x1 就把初始映射 p1 放回自由池。
    //    (中间网线必须先声明再用 —— 双重 part-select `win2[..][6:5]` 是非法语法,
    //     而漏声明会退化成 1 位隐式线网, 症状是静默错。)
    wire [6:0] old0 = win0[`RTU_E_OLD_PREG];
    wire [6:0] old1 = win1[`RTU_E_OLD_PREG];
    wire [6:0] old2 = win2[`RTU_E_OLD_PREG];

    assign ret_free_vld = wr_eff & { (old2[6:5] != 2'b00),
                                     (old1[6:5] != 2'b00),
                                     (old0[6:5] != 2'b00) };

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
    wire [6:0] csr_dp  = csr_in0 ? win0[`RTU_E_DST_PREG] :
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
    // 退休点重训练 (阶段 4b): 取窗口里**程序序最老**的那条控制转移
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
    // ⚠️⚠️ **只有一个训练口, 3 发射落地前必须处理**: 同一窗口里出现 2 条以上控制
    //     转移时, 这里只发出**最老**的那条, 其余的**静默丢掉**训练 (C910 是 3 个
    //     退休训练口). 1 发射的 5 级顺序核里窗口最多一条分支 ⇒ 恒等价、测不出来;
    //     3 发射下最多丢 2 条。IFU 那边 `u_bht/u_btb` 也只有单 `upd_vld` 口,
    //     所以这是个**两头都要改**的活 (RTU 加训练 FIFO 或按宽度节流 + IFU 加口),
    //     属"阶段 3 乱序落地"清单, 见 doc/rtu_plan_zh.md §7-4b 的注。
    // -----------------------------------------------------------------------
    wire tr0 = commit_vld[0] & w0_br;
    wire tr1 = commit_vld[1] & w1_br;
    wire tr2 = commit_vld[2] & w2_br;

    assign train_vld   = tr0 | tr1 | tr2;
    assign train_pc    = tr0 ? win0[`RTU_E_PC]   : tr1 ? win1[`RTU_E_PC]   : win2[`RTU_E_PC];
    // `TARGET` 是 BEU 在解析那拍写回表项的真实后继 PC (= EX 的 `actual_npc`),
    // 也就是原来 `iu_btb_target` 的驱动源。不跳的条件分支它就是 pc+4 ——
    // BTB 的"不跳"训练用不上目标, 由 upd_taken 决定写不写。
    assign train_target= tr0 ? win0[`RTU_E_TARGET]: tr1 ? win1[`RTU_E_TARGET]: win2[`RTU_E_TARGET];
    assign train_chk   = tr0 ? win0[`RTU_E_CHK]  : tr1 ? win1[`RTU_E_CHK]  : win2[`RTU_E_CHK];
    assign train_taken = tr0 ? win0[`RTU_E_TAKEN]: tr1 ? win1[`RTU_E_TAKEN]: win2[`RTU_E_TAKEN];
    // 三分类互斥 (条件分支 = is_branch & ~jal & ~jalr), 与 EX 的
    // `iu_btb_is_cond/is_jal/is_jalr` 同集合 —— BTB 靠它选"写哪一类"。
    assign train_is_jal  = tr0 ? w0_jal  : tr1 ? w1_jal  : w2_jal;
    assign train_is_jalr = tr0 ? w0_jalr : tr1 ? w1_jalr : w2_jalr;
    assign train_is_cond = (tr0 ? w0_br  : tr1 ? w1_br  : w2_br)
                         & ~train_is_jal & ~train_is_jalr;

endmodule
