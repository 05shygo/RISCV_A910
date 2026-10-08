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

    assign iu_chgflw_vld    = mispredict & ~redirect_in_progress & ~chgflw_mask;
    assign iu_chgflw_pc     = actual_npc;
    assign beu_redirect_vld = iu_chgflw_vld;

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
