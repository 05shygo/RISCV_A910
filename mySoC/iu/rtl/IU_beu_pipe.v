`timescale 1ns / 1ps
`include "defines.vh"

// ---------------------------------------------------------------------------
// IU_beu_pipe —— **IDU 的 BIQ 发射口 ↔ 老 BEU 之间的适配级** (分支/跳转)。
//
// 【两套接口的差异】
//   BIQ 给: {sel, iid, src0, src1, pc, npc, taken, rslt_sel[7:0](独热), br_imme,
//            dst_vld, dst_preg, chk}
//   老 BEU: {A, B, pc, sext, pc4, pred_npc, alu_op[4:0], is_branch, is_jal, is_jalr}
//        → {br_taken, actual_npc, target, mis_align, npc_mismatch}
//
// ⚠️ **操作数摆放与 AIQ 那条不一样**: `idu_biq_src1` 是**裸的 PRF 读**
//    (AIQ 那边 `SRC1_VLD=0` 时会把立即数切进 src1, BIQ 这边没有那个 mux ——
//     见 ct_idu_rf_dp.sv:822 与 :819-821 的对比)。
//    而老 BEU 里 `npc_jalr = A + B`, 所以 **JALR 时 B 必须喂 `br_imme`**。
//    ⇒ B = is_jalr ? br_imme : src1。
//    JAL / 条件分支的目标都用 `pc + sext`, `sext` 统一给 `br_imme`。
//
// 【时序: 两拍分工, 这是刻意的】
//   * **重定向走 EX1 (组合)**。—— D13 的"早重定向"就是靠这一拍: 前端在分支**解析
//     的那一拍**就被送到真实目标, 不等退休。打一拍就等于把 D13 的收益扔掉
//     (`iu_chgflw_vld` 直接进 IFU 的重定向口, 与 RTU 的 trap 口并列)。
//   * **完成 / 解析 / PRF 写回走 EX2 (寄存)**。—— 为什么不跟重定向一起放 EX1:
//     RTU 的 `resolve_hit` **只写 TARGET/TAKEN/MISPRED, 不置 CMPLT**
//     (见 RTU_ROB_entry.v:57-67) ⇒ 分支要**另外**报 `cmplt` 才能退休。
//     若 `cmplt` 在 EX1 而 PRF 写回 (JAL/JALR 的 rd=pc+4) 在 EX2, 那条可能在写回
//     落地前就走到队头退休 ⇒ difftest 读到**旧值**。两者同拍 (EX2) 才安全;
//     A8 要求的"完成不早于解析"在同拍下天然成立。
//
// 【与 RTU / IFU 的握手 (照 mycpu.v:925-934 的口径)】
//   iu_chgflw_vld = mispredict & ~redirect_in_progress & ~chgflw_mask
//     * `redirect_in_progress` = RTU 本拍正在发 trap/mret 重定向 (它优先);
//     * `chgflw_mask` = `rtu_beu_flush_chgflw_mask` —— 慢路冲刷期间屏蔽 BEU 再发,
//       漏了会让两次重定向打架。
//   beu_redirect_vld = iu_chgflw_vld —— 告诉 RTU "EX 级真的发出了重定向",
//     RTU 据此把派遣冻结窗口从执行级那拍拉起来 (D13)。
// ---------------------------------------------------------------------------
module IU_beu_pipe (
    input  wire        cpu_clk,
    input  wire        cpu_rst,          // 高有效
    input  wire        idu_flush,        // = rtu_yy_xx_flush

    // ---------------- 来自 IDU 的 BIQ 发射口 ----------------
    input  wire        idu_sel,
    input  wire [6:0]  idu_iid,
    input  wire [31:0] idu_src0,         // = PRF[rs1]
    input  wire [31:0] idu_src1,         // = PRF[rs2]  (**裸读**, 不像 AIQ 会切立即数)
    input  wire [31:0] idu_pc,
    input  wire [31:0] idu_npc,          // 预测的后继 PC
    input  wire        idu_taken,        // 预测的方向
    input  wire [7:0]  idu_rslt_sel,     // 独热, 见 ct_idu_rf_pipe6_decd
    input  wire [31:0] idu_br_imme,      // 分支/跳转立即数 (B/J/I 型由译码选好)
    input  wire        idu_dst_vld,      // JAL/JALR 写 rd
    input  wire [5:0]  idu_dst_preg,
    input  wire [24:0] idu_chk,          // 取指时随指令带来的 chk (含 PHR 快照)

    // ---------------- 与 RTU / IFU 的重定向握手 ----------------
    input  wire        redirect_in_progress, // RTU 本拍在发 trap/mret (优先级更高)
    input  wire        chgflw_mask,          // = rtu_beu_flush_chgflw_mask

    // ---------------- 写回 IDU (EX2) ----------------
    output wire        wb_preg_vld,
    output wire [31:0] wb_preg_data,
    output wire [63:0] wb_preg_expand,
    output wire [5:0]  wb_preg_dupx,
    output wire        wb_preg_vld_dupx,

    // ---------------- 完成 / 解析 给 RTU (EX2) ----------------
    output wire        cmplt_vld,
    output wire [6:0]  cmplt_iid,
    output wire        resolve_vld,
    output wire [6:0]  resolve_iid,
    output wire        resolve_taken,
    output wire        resolve_mispred,
    output wire [31:0] resolve_target,

    // ---------------- 重定向 (EX1, 组合) ----------------
    output wire        beu_redirect_vld, // → RTU: 本拍真的发出了误预测重定向
    output wire        iu_chgflw_vld,    // → IFU: EX 级重定向 (与 RTU 的 trap 口并列)
    output wire [31:0] iu_chgflw_pc,     // → IFU: 真实目标
    // → IFU: 重定向当拍的 chk/实际方向/类型 (PHR/RAS 修复用; 不是训练口)
    output wire [24:0] iu_btb_chk,
    output wire [31:0] iu_btb_pc,      // 分支自己的 PC (PHR hash 精确重算用)
    output wire        iu_btb_taken,
    output wire        iu_btb_is_cond,

    // ---------------- 异常源: 取指地址非对齐 (cause 0) ----------------
    output wire        expt_vld,
    output wire [6:0]  expt_iid,
    output wire [4:0]  expt_cause,
    output wire [31:0] expt_tval,

    // ---------------- 观察口 ----------------
    output wire [31:0] o_actual_npc,
    output wire        o_br_taken
);

    // ==========================================================
    //  1) 8 位独热 → 老 BEU 需要的三种信息
    // ==========================================================
    // 位序照 ct_idu_rf_pipe6_decd.sv 的 localparam:
    //   [0]BEQ [1]BNE [2]BLT [3]BGE [4]BLTU [5]BGEU [6]JAL [7]JALR
    wire sel_beq  = idu_rslt_sel[0];
    wire sel_bne  = idu_rslt_sel[1];
    wire sel_blt  = idu_rslt_sel[2];
    wire sel_bge  = idu_rslt_sel[3];
    wire sel_bltu = idu_rslt_sel[4];
    wire sel_bgeu = idu_rslt_sel[5];
    wire sel_jal  = idu_rslt_sel[6];
    wire sel_jalr = idu_rslt_sel[7];

    wire is_branch = sel_beq | sel_bne | sel_blt | sel_bge | sel_bltu | sel_bgeu;
    wire is_jal    = sel_jal;
    wire is_jalr   = sel_jalr;

    // 条件编码: 老 BEU 吃 ALU_BEQ..ALU_BGEU 那套 (defines.vh)
    reg [4:0] alu_op;
    always @(*) begin
        if      (sel_bne)  alu_op = `ALU_BNE;
        else if (sel_blt)  alu_op = `ALU_BLT;
        else if (sel_bge)  alu_op = `ALU_BGE;
        else if (sel_bltu) alu_op = `ALU_BLTU;
        else if (sel_bgeu) alu_op = `ALU_BGEU;
        else               alu_op = `ALU_BEQ;   // BEQ 与"非法/空"共用, 下面 is_branch 会挡住
    end

    // ==========================================================
    //  2) 操作数摆放 (见模块头 ⚠️)
    // ==========================================================
    wire [31:0] beu_b = is_jalr ? idu_br_imme : idu_src1;

    wire        br_taken;
    wire [31:0] actual_npc;
    wire [31:0] target;
    wire        mis_align;
    wire        npc_mismatch;

    BEU u_beu (
        .A            (idu_src0),
        .B            (beu_b),
        .pc           (idu_pc),
        .sext         (idu_br_imme),
        .pc4          (idu_pc + 32'd4),
        .pred_npc     (idu_npc),
        .alu_op       (alu_op),
        .is_branch    (is_branch),
        .is_jal       (is_jal),
        .is_jalr      (is_jalr),
        .br_taken     (br_taken),
        .actual_npc   (actual_npc),
        .target       (target),
        .mis_align    (mis_align),
        .npc_mismatch (npc_mismatch)
    );

    assign o_actual_npc = actual_npc;
    assign o_br_taken   = br_taken;

    // ==========================================================
    //  3) EX1: 重定向 (组合, 早发)
    // ==========================================================
    // 预测错 ⟺ 真实后继 != 预测后继。老 BEU 的 `npc_mismatch` 已经把三种情形
    // (不跳→pc4 / 条件跳→pc+imm / JAL·JALR→目标) 都归一成"与 pred_npc 比",
    // 所以这里不用再单独看 `taken`。
    wire mispredict = idu_sel & npc_mismatch;
    wire red_req    = mispredict & ~redirect_in_progress & ~chgflw_mask;

    // -----------------------------------------------------------------------
    //  ⚠️ 在途误预测重定向期间, **只准更老的分支**再发 (2026-10-12, 对应 C910
    //     `ct_iu_bju.v:506` 的 `!idu_mispred_stall || bju_rf_older_mispred`)
    //
    //  【症状】执行级重定向早发, 而错路上的那些分支这时还堵在 BIQ 里没发射完 ——
    //    它们随后各自再报一次"我也误预测了", 把刚建好的正确重定向**顶掉**。
    //    实测 (`beq`, `+PROBE_BEU`):
    //        T96  0x10 beq → actual=0x1c chgflw_vld=1   ← 正确的那次
    //        T97  0x14 bne → actual=0x2c4 chgflw_vld=1  ← 错路上的, 把 PC 拽到 fail
    //    那几个地址 (0x14/0x18/0x1c) 都是"前端按错方向取回来的", 它们**比 0x10 年轻**。
    //
    //  【为什么不能只做"发过就不许再发"】试过: `beq` 6→7 条, 但 `mul` 从 PASS 退回
    //    FAIL。原因是**发射是乱序的** —— `mul` 里错路那条 `jal x0,0x24` 比正确的
    //    `beq x7,x8,0x20` **先发射**, 于是"先到先得"挡住的反而是正确那次, PC 跑到
    //    0x24。⇒ 判据必须是**年龄**, 不是到达顺序。
    //
    //  【年龄从哪来】iid。BIQ 发射口上现成有 (`idu_iid`)。它按 {wrap, idx} 自增,
    //    取值序列正好是 7 位计数器 0..127 循环 ⇒ "a 比 b 老" ⟺ 从 a 往前走到 b
    //    不足半圈 ⟺ `(b - a)` 的第 6 位为 0。不需要额外端口, 也不需要 IDU 配合。
    //
    //  【为什么这样就够了】错路上那条一定是**更年轻**的 (它是顺着错方向在正确
    //    那条后面取回来的) ⇒ 一律被挡; 而乱序先发射的那条更年轻的也一样被挡。
    //    反过来, 万一有**更老**的分支这时才发射, 它说了算 (并刷新基准)。
    //
    //  ⚠️ 清条件用 `idu_flush` (= rtu_yy_xx_flush): 与 IDU 看到的是同一根。
    //     闸门是 `mis_inflight_q`, `mis_iid_q` 残留无所谓 —— 标志为 0 时不比较。
    // -----------------------------------------------------------------------
    reg        mis_inflight_q;
    reg [6:0]  mis_iid_q;

    wire [6:0] iid_gap = mis_iid_q - idu_iid;      // 从本拍这条走到在途那条
    wire       older   = ~iid_gap[6];              // 不足半圈 ⇒ 本拍这条更老

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            mis_inflight_q <= 1'b0;
            mis_iid_q      <= 7'd0;
        end
        else if (idu_flush) begin
            mis_inflight_q <= 1'b0;                // 冲刷到 ⇒ 窗口结束
            mis_iid_q      <= 7'd0;
        end
        else if (red_req & (~mis_inflight_q | older)) begin
            mis_inflight_q <= 1'b1;                // 本拍这条发了, 基准换成它
            mis_iid_q      <= idu_iid;
        end
    end

    assign iu_chgflw_vld    = red_req & (~mis_inflight_q | older);
    assign iu_chgflw_pc     = actual_npc;
    assign beu_redirect_vld = iu_chgflw_vld;

    // 给 IFU 的 PHR/RAS 修复信息: 必须是**当拍 EX** 的值, 不能换成退休点那份
    assign iu_btb_chk     = idu_chk;
    assign iu_btb_pc      = idu_pc;
    assign iu_btb_taken   = br_taken | is_jal | is_jalr;
    assign iu_btb_is_cond = is_branch;

    // ==========================================================
    //  4) EX2: 完成 / 解析 / 写回
    // ==========================================================
    reg        ex2_vld;
    reg [6:0]  ex2_iid;
    reg        ex2_taken;
    reg        ex2_mispred;
    reg [31:0] ex2_target;
    reg [5:0]  ex2_preg;
    reg [31:0] ex2_pc4;
    reg        ex2_wr;        // JAL/JALR 才写 rd
    reg        ex2_misalign;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            ex2_vld      <= 1'b0;
            ex2_iid      <= 7'd0;
            ex2_taken    <= 1'b0;
            ex2_mispred  <= 1'b0;
            ex2_target   <= 32'd0;
            ex2_preg     <= 6'd0;
            ex2_pc4      <= 32'd0;
            ex2_wr       <= 1'b0;
            ex2_misalign <= 1'b0;
        end
        else if (idu_flush) begin
            // 与 IU_alu_pipe 同一个理由: 冲刷那拍必须清掉在途的完成/解析,
            // 否则它会按 iid 命中一条**新派进来的**同下标表项 (D2.1 的翻版)。
            ex2_vld      <= 1'b0;
            ex2_wr       <= 1'b0;
            ex2_misalign <= 1'b0;
        end
        else begin
            ex2_vld      <= idu_sel;
            ex2_iid      <= idu_iid;
            ex2_taken    <= br_taken | is_jal | is_jalr;   // JAL/JALR 恒"跳"
            ex2_mispred  <= npc_mismatch;
            ex2_target   <= actual_npc;
            ex2_preg     <= idu_dst_preg;
            ex2_pc4      <= idu_pc + 32'd4;                // JAL/JALR 的 rd 值
            ex2_wr       <= idu_sel & idu_dst_vld;
            ex2_misalign <= mis_align;
        end
    end

    // 写回 IDU: JAL/JALR 的 rd = pc + 4
    assign wb_preg_vld      = ex2_wr;
    assign wb_preg_data     = ex2_pc4;
    assign wb_preg_expand   = 64'd1 << ex2_preg;
    assign wb_preg_dupx     = ex2_preg;
    assign wb_preg_vld_dupx = ex2_wr;

    // 完成 + 解析: **两条都要报** —— resolve 只写 TARGET/TAKEN/MISPRED,
    // 不置 CMPLT (RTU_ROB_entry.v:57-67), 少了 cmplt 那条永远退不了休。
    assign cmplt_vld       = ex2_vld;
    assign cmplt_iid       = ex2_iid;
    assign resolve_vld     = ex2_vld;
    assign resolve_iid     = ex2_iid;
    assign resolve_taken   = ex2_taken;
    assign resolve_mispred = ex2_mispred;
    assign resolve_target  = ex2_target;

    // 取指地址非对齐 → cause 0 (EXC_INST_MISALIGNED, defines.vh:297)
    // 只在**真的跳**且目标没对齐时报 (老 BEU 的 mis_align 已经按三条目标路径选好了)。
    assign expt_vld   = ex2_vld & ex2_misalign;
    assign expt_iid   = ex2_iid;
    assign expt_cause = 5'd0;
    assign expt_tval  = ex2_target;

endmodule
