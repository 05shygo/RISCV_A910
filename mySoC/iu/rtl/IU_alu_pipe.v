`timescale 1ns / 1ps
`include "defines.vh"

// ---------------------------------------------------------------------------
// IU_alu_pipe —— **IDU 的一个 ALU 发射口 ↔ 老 ALU 之间的适配流水级**。
//
// 【为什么需要它】
// 同事交付的 C910 IDU 的发射队列 (AIQ) 给的是 C910 那套接口:
//     {sel, iid, dst_preg, src0, src1, rslt_sel[12:0]}
// 而本仓 `mySoC/iu/rtl/ALU.v` 是老顺序核的接口:
//     {A, B, alu_op[4:0]} → {alu_c, alu_f}
// **两套算子编码完全不同**: IDU 的 `rslt_sel` 是 13 位**独热**
// (语义见 `ct_idu_rf_pipe0_decd.sv` 的 localparam), 老 ALU 吃的是 `defines.vh` 里
// 那套 5 位 `ALU_*` 编码。
//
// 这里选**写编码转换**而不是重写 ALU: 老 ALU 是为 Fmax 优化过的 (见它文件头 [C5]
// 那段 —— 32 位比较拆成 4 个 8 位并行, 避开一条 32 位进位链), 重写等于把那笔收益
// 扔掉。代价只是多一级 13→5 的 LUT。
//
// 【本模块做四件事】
//   1. `rslt_sel[12:0]` 独热 → `alu_op[4:0]` 编码;
//   2. **LUI / AUIPC** —— 老 ALU 里没有这两条 (老核是在 EX 级用 mux 现拼的),
//      这里补上: LUI = src1 (立即数), AUIPC = pc + src1;
//   3. **EX1 → EX2 打一拍**, 结果在 EX2 写回 (命名与 IDU 的
//      `iu_idu_ex2_pipe*_wb_preg_*` 对齐);
//   4. 生成 RTU 的完成回报 (`cmplt_vld/iid`) —— C910 里这是 IU 的活
//      (`iu_rtu_ex2_pipe*_complete`), 交付的 IDU 没有这个口。
//
// 【操作数约定 (对着 ct_idu_rf_dp.sv 核过)】
//   `idu_src0` = PRF 读出的 rs1
//   `idu_src1` = **当 `AIQ_SRC1_VLD` 为 0 时切成立即数** (`:368-373` 那个 mux)
//   ⇒ I 型指令的立即数就在 src1 上, 所以 LUI 直接取 src1。
//   `idu_pc` 是 2026-10-08 新加进 AIQ 表项的 (见 doc/DELIVERY_FIXES 的说明:
//   C910 的 AUIPC 走独立 ct_iu_special、PC 来自 BJU 的 PC FIFO, 交付版没有那一路)。
//
// 【与 RTU 完成口的关系】
//   `cmplt_vld/iid` 报的是"这条在 EX2 完成了"。RTU 按 iid 找表项标完成。
//   ⚠️ 非法指令**也报完成** —— 它占着 ROB 表项, 要能退休才能陷入; 但不写 PRF。
// ---------------------------------------------------------------------------
module IU_alu_pipe (
    input  wire        cpu_clk,
    input  wire        cpu_rst,          // 高有效 (与 RTU 同口径; IDU 侧低有效由适配层反相)
    input  wire        idu_flush,        // = rtu_yy_xx_flush, 冲掉 EX2 里的在途结果

    // ---------------- 来自 IDU 的 AIQ 发射口 ----------------
    input  wire        idu_sel,          // 本拍这个发射口出一条 (idu_aiq_sel)
    input  wire [6:0]  idu_iid,          // 它的 iid (idu_aiq_iid)
    input  wire [5:0]  idu_dst_preg,     // 目标物理号 (idu_aiq_dst_preg)
    input  wire [31:0] idu_src0,         // = PRF[rs1]
    input  wire [31:0] idu_src1,         // = PRF[rs2] 或 **立即数** (SRC1_VLD=0 时)
    input  wire [31:0] idu_pc,           // 表项里的 PC (只有 AUIPC 用)
    input  wire [12:0] idu_rslt_sel,     // 13 位独热算子
    input  wire        idu_illegal,      // 非法指令

    // ---------------- 写回 IDU (EX2) ----------------
    output wire        wb_preg_vld,      // → iu_idu_ex2_pipe*_wb_preg_vld
    output wire [31:0] wb_preg_data,     // → _wb_preg_data
    output wire [63:0] wb_preg_expand,   // → _wb_preg_expand (独热写使能)
    output wire [5:0]  wb_preg_dupx,     // → _wb_preg_dupx     (依赖唤醒的号)
    output wire        wb_preg_vld_dupx, // → _wb_preg_vld_dupx (依赖唤醒的有效)

    // ---------------- 完成回报给 RTU ----------------
    output wire        cmplt_vld,
    output wire [6:0]  cmplt_iid,

    // ---------------- 观察口 ----------------
    output wire [31:0] o_alu_result      // 未打拍的结果 (调试用)
);

    // ==========================================================
    //  1) 13 位独热 → alu_op 编码
    // ==========================================================
    // 位序照 ct_idu_rf_pipe0_decd.sv 的 localparam:
    //   [0]ADD [1]SUB [2]SLL [3]SLT [4]SLTU [5]XOR [6]SRL [7]SRA
    //   [8]OR  [9]AND [10]LUI [11]AUIPC [12]ILLEGAL
    wire sel_add   = idu_rslt_sel[0];
    wire sel_sub   = idu_rslt_sel[1];
    wire sel_sll   = idu_rslt_sel[2];
    wire sel_slt   = idu_rslt_sel[3];
    wire sel_sltu  = idu_rslt_sel[4];
    wire sel_xor   = idu_rslt_sel[5];
    wire sel_srl   = idu_rslt_sel[6];
    wire sel_sra   = idu_rslt_sel[7];
    wire sel_or    = idu_rslt_sel[8];
    wire sel_and   = idu_rslt_sel[9];
    wire sel_lui   = idu_rslt_sel[10];
    wire sel_auipc = idu_rslt_sel[11];
    wire sel_ill   = idu_rslt_sel[12];

    // ⚠️ 用 if/else 链而不是 case(1'b1): 后者在 VCS 里对独热输入会被当成
    //    "多分支可能同时命中", 综合出来的优先级链反而更长。这里写成并列的
    //    互斥条件, 综合器能直接铺成一层 LUT。
    reg [4:0] alu_op;
    always @(*) begin
        if      (sel_sub)  alu_op = `ALU_SUB;
        else if (sel_sll)  alu_op = `ALU_SLL;
        else if (sel_slt)  alu_op = `ALU_SLT;
        else if (sel_sltu) alu_op = `ALU_SLTU;
        else if (sel_xor)  alu_op = `ALU_XOR;
        else if (sel_srl)  alu_op = `ALU_SRL;
        else if (sel_sra)  alu_op = `ALU_SRA;
        else if (sel_or)   alu_op = `ALU_OR;
        else if (sel_and)  alu_op = `ALU_AND;
        // LUI/AUIPC/ILLEGAL 走 ADD (无害: 下面 result 的 mux 会把它们盖掉),
        // 不想让 default 落进 X (那会在波形上掩盖真问题)。
        else               alu_op = `ALU_ADD;
    end

    wire [31:0] alu_c;
    wire        alu_f;              // 分支判决位 —— ALU0/1 用不到 (分支在 BIQ 那条)
    ALU u_alu (
        .A      (idu_src0),
        .B      (idu_src1),
        .alu_op (alu_op),
        .alu_c  (alu_c),
        .alu_f  (alu_f)
    );

    // ==========================================================
    //  2) LUI / AUIPC —— 老 ALU 没有这两条
    // ==========================================================
    //   LUI   rd, imm      ⇒ rd = imm          (src1 在 SRC1_VLD=0 时就是立即数)
    //   AUIPC rd, imm      ⇒ rd = pc + imm
    // ⚠️ AUIPC 的 src0 是 PRF[x0] (rs1 恒为 0), **不要**拿 src0 当加数。
    wire [31:0] result = sel_lui   ? idu_src1
                       : sel_auipc ? (idu_pc + idu_src1)
                       :             alu_c;

    assign o_alu_result = result;

    // ==========================================================
    //  3) EX1 → EX2 打一拍
    // ==========================================================
    reg        ex2_vld;
    reg [6:0]  ex2_iid;
    reg [5:0]  ex2_preg;
    reg [31:0] ex2_data;
    reg        ex2_wr;       // 这条要写寄存器 (非非法指令)

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            ex2_vld  <= 1'b0;
            ex2_iid  <= 7'd0;
            ex2_preg <= 6'd0;
            ex2_data <= 32'd0;
            ex2_wr   <= 1'b0;
        end
        else if (idu_flush) begin
            // 冲刷那拍清掉在途结果 —— 与 IDU 自己的流水寄存器同口径。
            // ⚠️ 漏了这一段的话, 错误路径上那条的完成会在冲刷后照报,
            //    RTU 按 iid 命中一条**新派进来的**同下标表项 ⇒ 把还没写回的
            //    指令标成完成 (就是 §10 D2.1 那条契约的翻版)。
            ex2_vld  <= 1'b0;
            ex2_wr   <= 1'b0;
        end
        else begin
            ex2_vld  <= idu_sel;
            ex2_iid  <= idu_iid;
            ex2_preg <= idu_dst_preg;
            ex2_data <= result;
            ex2_wr   <= idu_sel & ~idu_illegal;
        end
    end

    // ==========================================================
    //  4) 写回 IDU + 完成回报
    // ==========================================================
    // PRF 写口: vld 与独热 expand 成对 (PRF 用 expand 当写使能)。
    // ⚠️ 非法指令**不写 PRF** (没有结果可言), 但完成照样报 —— 它要能退休才能陷入。
    assign wb_preg_vld      = ex2_wr;
    assign wb_preg_data     = ex2_data;
    assign wb_preg_expand   = 64'd1 << ex2_preg;
    // 依赖唤醒: 与写回同拍同条件 (发射队列拿它置对应 preg 的 rdy 位)。
    assign wb_preg_dupx     = ex2_preg;
    assign wb_preg_vld_dupx = ex2_wr;

    // 完成回报: **非法指令也报** (见上)。
    assign cmplt_vld = ex2_vld;
    assign cmplt_iid = ex2_iid;

endmodule
