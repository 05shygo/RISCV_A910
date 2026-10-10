`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_flush — 冲刷状态机 + 重定向分发 (D11 / §6.3 ① / **D13**)。
//
//   IDLE --(退休窗口出现 flush 源)--> F1 --(无条件)--> IDLE
//
//   T   : IDLE & flush_trig —— 退休窗口照常出信号; **本拍就** 拉高 disp_stall 与
//         beu_mask, 并拉 `core_redirect` (核内冲刷)。
//   T+1 : F1 —— backend_flush (冲发射队列/执行级/存储队列) + 清 expt_entry
//         **与** ren_flush + AMT 整表覆盖 + ALLOC/WF_ALLOC -> FREE + ROB 指针复位。
//   T+2 : IDLE —— disp_stall 放开, 派遣恢复。
//
// ⚠️ **2026-10-02: F1/F2 已合成一拍, 冻结从 3 拍压到 2 拍**(见下面 FSM 处的长注)。
//    旧文档里的 "T+2 = F2 / T+3 = 放开" 已经作废。
//
// ⚠️ `disp_stall` 从 **T 拍** 就要起来 (不是 T+1): 从这一刻到 RAT 恢复之间派出去的
//    指令, 都是拿"还没恢复的 RAT"改名出来的, 只能在 T+1 被冲掉 (D3.1 的前提③)。
//    这条漏了, 症状是"偶发算错、极难复现"。
// ⚠️ `beu_mask` (rtu_beu_flush_chgflw_mask) 同样从 T 拍起 —— 漏了会让两次重定向打架。
//
// ---------------------------------------------------------------------------
// **D13 (2026-10-02)：误预测的慢路不再重启前端，冻结窗口从"执行级重定向那拍"起。**
//
// 这是 C910 的形态 (ct_rtu_retire.v 的 FLUSH_IS 不碰 IFU)。两条改动是一套：
//
//   ① **冻结提前**：BEU 在 EX 发出误预测重定向的那一拍拉 `beu_redirect_vld`，
//      本模块置一个**锁存**位 `mispred_pend`，与 `flushing` 一起进 rtu_disp_stall，
//      到 F2 清。⇒ 从重定向到冲刷完成之间**派遣一直冻着**，前端不可能派出
//      "拿着未恢复 RAT 改名"的指令。窗口里前端刚重填、RAT 未恢复 ⇒ **本来就没有
//      能正确改名的指令可派**，所以这个冻结近乎免费 (真正的收益是 ②)。
//   ② **不重启前端**：误预测时 `ifu_flush` / `ifu_chgflw_vld` 不再拉高 —— 前端在
//      EX 那拍就已经被 BEU 送到真实目标、之后一路在取指，再重启一次就是"重取两次"
//      (阶段 1 实测代价 +4.66% 周期)。陷阱/中断/mret **照旧**。
//
// ⚠️ 三条不能顺手删的：
//   * `core_redirect` (核内) **对误预测仍然要拉高** —— 它驱动 mycpu.v 的 `redirect`：
//     冲 IF_ID/ID_EX/EX_MEM、按掉 store 写使能、CSR 静默、训练门控。断了它，
//     错误路径的 store 会写进内存。
//   * `backend_flush` (F1) 同理 —— 后端与 IDU 里更年轻的指令仍然必须冲掉。
//   * F2 的 AMT 整表覆盖仍然必须做：冻结有个"边界拍"(见下)，残迹靠它收。
//
// ⚠️ **"边界拍"**：`mispred_pend` 是寄存器 (P8 要求 disp_stall 只依赖寄存器)，
//    所以它从 T_ex+1 才起。T_ex 那拍靠 `branched`(mycpu.v 的 Hazard_Detection)
//    冲掉 IF_ID/ID_EX 顺手挡住 —— 这一条**依赖 mycpu.v 的 `branched = mispredict`**，
//    改动那边时别把这条覆盖丢掉。
// ---------------------------------------------------------------------------
module RTU_flush (
    input  wire         cpu_clk,
    input  wire         cpu_rst,

    input  wire         flush_trig,
    input  wire [2:0]   flush_src,
    input  wire [31:0]  flush_pc,
    input  wire [32*`RTU_PREG_W-1:0] amt_flat,   // 架构映射表 (RTU_preg 出), 宽度随档
    input  wire         beu_redirect_vld,// D13: EX 级真的发出误预测重定向的那一拍

    output wire         fsm_busy,        // 非 IDLE: 判退要停
    output wire         flushing,        // 含 T 拍: 冻派遣 + 屏蔽 BEU
    output wire         mispred_pend,    // D13: 有未决快路重定向 (T_ex+1 .. F2)
    output wire         core_redirect,   // T 拍: 核内重定向事件 (= flush_trig, 含误预测)
    output wire         backend_flush,   // T+1
    output wire         expt_clr,        // T+1
    output wire         flush_lvl,       // T+2: ALLOC->FREE / RAT 覆盖 / 指针复位
    output wire         ren_flush,
    output wire         ren_recover_vld,
    output wire [32*`RTU_PREG_W-1:0] ren_recover_map,   // 宽度随档 (32 × `RTU_PREG_W)
    output wire         beu_mask,
    output wire         ifu_flush,       // 陷阱/中断/mret 才拉 (D13)
    output wire         ifu_chgflw_vld,  // 同上
    output wire [31:0]  ifu_chgflw_pc
);

    reg [1:0] st_q;
    reg [31:0] pc_q;

    wire idle = (st_q == `RTU_FSM_IDLE);
    wire f1   = (st_q == `RTU_FSM_F1);

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            st_q <= `RTU_FSM_IDLE;
            pc_q <= 32'd0;
        end else begin
            // -----------------------------------------------------------------
            // 2026-10-02 (D11 的"合成一拍"): 原先是 IDLE->F1->F2->IDLE 三拍,
            // 现在合成 IDLE->F1->IDLE 两拍。**冻结窗口从 3 拍压到 2 拍。**
            //
            // 为什么能合: 原 F1(后端冲刷) 与 F2(ALLOC->FREE + RAT 覆盖 + 指针复位)
            // 之间没有真依赖 —— AMT 在触发拍(T, 退休边沿)就写好了, 所以"恢复用的
            // 那张表"在 T+1 这一拍已经有效; 两者都是**同一批寄存器的写**, 放同一个
            // 边沿上不冲突。C910 的 `FLUSH_IS_BE`(管线已空就把两级并成拍) 就是这
            // 个意思, 我们这里比它更简单: 顺序核里不需要等排水。
            //
            // ⚠️ **收益是实测逼出来的**: 这 3 拍冻结是阶段 1 那 +4.66% 的主因
            //    (3 拍 × ~13 万次冲刷事件 ≈ 周期 3.5%); D13(误预测不重启前端)
            //    只值 0.44%, 因为"重取"那个窗口在这个 5 级顺序核里本来就是空的。
            //    详见 doc/rtu_plan_zh.md 的 D13 末尾"实测结果"。
            //
            // 时序: T = flush_trig 那一拍(退休拍), 冻结覆盖 T 与 T+1, T+2 放开 ——
            //   因为 T+1 边沿 ROB 指针已复位, T+2 的 flush_trig 自然为 0。
            // -----------------------------------------------------------------
            case (st_q)
                `RTU_FSM_IDLE: st_q <= flush_trig ? `RTU_FSM_F1 : `RTU_FSM_IDLE;
                default      : st_q <= `RTU_FSM_IDLE;
            endcase
            if (flush_trig) pc_q <= flush_pc;   // 目标留下来 (F1 期间读)
        end
    end

    assign fsm_busy = ~idle;
    assign flushing = flush_trig | ~idle;

    // T+1 这一拍: 后端冲刷 + 重命名恢复 **同时** 发生 (原来是 F1/F2 两拍)。
    assign backend_flush = f1;
    assign expt_clr      = f1;

    assign flush_lvl       = f1;
    assign ren_flush       = f1;
    assign ren_recover_vld = f1;
    assign ren_recover_map = amt_flat;

    assign beu_mask = flushing;

    // -----------------------------------------------------------------------
    // D13: 未决快路重定向 (锁存, F2 清) —— 把冻结窗口从"执行级重定向那拍"拉起来
    // -----------------------------------------------------------------------
    // 置: EX 级发出误预测重定向那拍 (beu_redirect_vld)。
    // 清: 冲刷跑到 F2 (那一拍 RAT 刚恢复, 派遣可以放了)。
    // ⚠️ **清优先**: 保证一定能解锁 —— 挂死的代价远大于少冻一拍。
    //    不会丢"置"(即锁不住): F2 那拍 `beu_mask = flushing = 1`, EX 级重定向本来
    //    就被屏蔽, 所以 `beu_redirect_vld` 在 F2 恒为 0。
    // 活性: `beu_redirect_vld` 只由"确实误预测"的分支产生 ⇒ 它退休那拍必然
    //    `mispred_hit` ⇒ 必然有一次冲刷跑到 F2 来清; 若它先被更老的陷阱冲掉,
    //    陷阱那次冲刷也会清。⇒ 不存在"置上之后永远没人清"。
    reg mispred_pend_q;
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)               mispred_pend_q <= 1'b0;
        else if (flush_lvl)        mispred_pend_q <= 1'b0;
        else if (beu_redirect_vld) mispred_pend_q <= 1'b1;
    end
    assign mispred_pend = mispred_pend_q;

    // 核内重定向事件: 四类源**都算** (含误预测)。mycpu.v 用它驱动 `redirect`。
    assign core_redirect = flush_trig;

    // 前端重定向: **误预测不发** (D13 / C910 的 FLUSH_IS 不碰 IFU)。
    // `flush_src` 的优先级是 trap > int > mret > **replay** > mispred (RTU_commit),
    // 所以
    // "== MISPRED" 等价于"这一拍只有误预测这一个源"。
    // ⚠️ 只有**误预测**不重启前端 (D13: 前端在 EX 那拍已经被送到真实目标)。
    //    2026-10-08 加的 `FS_REPLAY` (store 重放) 走的是"要重启"这一支 —— 它必须
    //    从被标记那条自己的 PC 重取, 前端并没有替它做过任何重定向。
    wire is_mispred_flush = (flush_src == `RTU_FS_MISPRED);
    assign ifu_flush       = flush_trig & ~is_mispred_flush;
    assign ifu_chgflw_vld  = flush_trig & ~is_mispred_flush;
    // 采样它的永远是 vld=1 那拍, 而那拍 flush_trig 恒真 ⇒ 实际恒取 flush_pc。
    // (pc_q 因此是死逻辑; 留着是因为"不采样时换成实时值"有引入假动作的风险,
    //  收益为零。要清就在阶段 5 的清面积里一起清。)
    assign ifu_chgflw_pc   = flush_trig ? flush_pc : pc_q;

endmodule
