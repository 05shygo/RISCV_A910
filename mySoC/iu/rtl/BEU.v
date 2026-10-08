`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: BEU (Branch Execution Unit, 分支执行单元)
//
// 为什么单独拉一个模块 (参考 C910 的 ct_iu_bju / 参考核的 Branch.v + br_ex.v):
//   改动前分支判决走**共享 ALU**: ALU 的 A 口是 `ex_csr_op ? ex_csr_rdata : ex_A`,
//   于是"条件分支成不成立"被迫串在 "CSR 读 mux → 32 位比较进位链" 之后。
//   FPGA 报告里 EX 族 132/500 条路径的起点就是 ex_csr_op_reg —— 与前端 F1 自环
//   并列的两大绑定族之一。
//
// 三样东西在这里一次做完, 全部从 ID_EX 的寄存器直起算:
//   * 条件: 6 条分支各自从 A/B 直接判, 用 4 个 8 位比较并行 + 组间优先的浅结构
//     (与 ALU.v 的 [C5] 同构; 该结构已用 Verilator 做过 16 op × 12 组边界向量
//      + 20 万随机向量的逐位等价验证)。
//   * 目标: 三个候选 (pc4 / pc+sext / A+B) 并行算。
//   * 误预测: 每个候选的 {与 pred_npc 是否相等, 目标是否非对齐} **提前并行算好**,
//     最后只按一个浅 select 选出结果 —— 于是 32 位比较不再串在 mux 后面。
//     (综合器原先把 `actual_npc != ex_pred_npc` 实现成 32 位减法的借用链,
//      实测报告里 3 级 CARRY4 就串在路径尾部。这里写成 `|(a ^ b)`, 是纯 OR 树。)
//
// 等价性 (逐位): 非分支 op 的条件恒 0 (与 ALU 的 default 一致);
//   非控制转移时 actual_npc = pc4; target = is_jalr ? A+B : pc+sext 与原式相同。
//   pc4 用的是 ID_EX 锁存的 ex_pc4 (= 包内 PC + 4, 与 pc_EX + 4 恒等)。
//////////////////////////////////////////////////////////////////////////////////

`include "defines.vh"

module BEU(
    input  [`RegBus]           A,             // ex_A  (已转发)
    input  [`RegBus]           B,             // ex_B  (已转发)
    input  [`RegBus]           pc,            // pc_EX
    input  [`RegBus]           sext,          // ex_sext
    input  [`RegBus]           pc4,           // ex_pc4
    input  [`RegBus]           pred_npc,      // ex_pred_npc
    input  [`ALU_OP_WIDTH-1:0] alu_op,        // ex_alu_op
    input                      is_branch,     // ex_npc_op == NPC_SEL_BRANCH
    input                      is_jal,        // ex_npc_op == NPC_SEL_JAL
    input                      is_jalr,       // ex_npc_op == NPC_SEL_ALU
    output                     br_taken,
    output [`RegBus]           actual_npc,
    output [`RegBus]           target,
    output                     mis_align,
    output                     npc_mismatch
    );

// ---------------------------------------------------------------------------
// 1. 条件判决: 4 个 8 位比较并行 + 组间优先 (同 ALU.v [C5])
//    无符号 A<B  ⟺  最高"不等字节"处 A<B ⟺ l3|(e3&(l2|(e2&(l1|(e1&l0)))))
//    有符号 A<B  ⟺  符号不同看 A[31]; 相同则同无符号 (标准恒等)
// ---------------------------------------------------------------------------
wire [7:0] bx0 = A[7:0]   ^ B[7:0];
wire [7:0] bx1 = A[15:8]  ^ B[15:8];
wire [7:0] bx2 = A[23:16] ^ B[23:16];
wire [7:0] bx3 = A[31:24] ^ B[31:24];
wire e0 = ~|bx0, e1 = ~|bx1, e2 = ~|bx2, e3 = ~|bx3;

wire l0 = (A[7:0]   < B[7:0]);
wire l1 = (A[15:8]  < B[15:8]);
wire l2 = (A[23:16] < B[23:16]);
wire l3 = (A[31:24] < B[31:24]);

wire ltu = l3 | (e3 & (l2 | (e2 & (l1 | (e1 & l0)))));
wire eqv = e3 & e2 & e1 & e0;
wire sgn = A[31] ^ B[31];
wire lts = sgn ? A[31] : ltu;

reg cond;
always @(*) begin
    case (alu_op)
        `ALU_BEQ : cond =  eqv;
        `ALU_BNE : cond = ~eqv;
        `ALU_BLT : cond =  lts;
        `ALU_BGE : cond = ~lts;
        `ALU_BLTU: cond =  ltu;
        `ALU_BGEU: cond = ~ltu;
        default  : cond = 1'b0;      // 与 ALU 的 default 一致
    endcase
end

assign br_taken = is_branch & cond;

// ---------------------------------------------------------------------------
// 2. 三个候选目标, 以及每个候选自己的 (失配 / 非对齐)
//    比较一律写成 `|(a ^ b)`: 显式 OR 树, 不给综合器"用减法借位链"的机会。
// ---------------------------------------------------------------------------
wire [31:0] npc_imm  = pc + sext;

// ---------------------------------------------------------------------------
// JALR 的目标: RISC-V 规定是 `(rs1 + sext(imm)) & ~1` —— **bit0 必须清掉**。
//
// ⚠️ 2026-10-08 修: 原来这里是裸的 `A + B`, 没有清 bit0。
//    老核那条路也一样 (Control.v 给 JALR 用 `Sext_I` + `NPC_SEL_ALU`, 目标就是
//    共享 ALU 的 A+B) ⇒ `imm[0] = 1` 时目标会跳错。RV32I 下编译器生成的 jalr
//    偏移基本都是偶数, 所以一路没暴露; 但 ISA 测试里有 `jalr x1, x2, 1` 这类
//    用例 (它必须跳到 `(rs1+1) & ~1`)。
//    ⚠️ 清的位置很关键: **必须在加法之后**。把立即数的 bit0 先清掉再相加不等价
//       (rs1=1, imm=1: 正确是 (1+1)&~1 = 2; 先清 imm 得 1+0 = 1)。
// ---------------------------------------------------------------------------
wire [31:0] npc_jalr_raw = A + B;
wire [31:0] npc_jalr     = {npc_jalr_raw[31:1], 1'b0};

wire m_pc4  = |(pc4      ^ pred_npc);
wire m_imm  = |(npc_imm  ^ pred_npc);
wire m_jalr = |(npc_jalr ^ pred_npc);

wire a_imm  = |npc_imm[1:0];
wire a_jalr = npc_jalr[1];   // 2026-10-08: bit0 已被上面清掉, 只看 bit1

// 同一组 select (is_jalr / br_taken|is_jal) 选出三样结果
wire sel_jalr = is_jalr;
wire sel_tgt  = br_taken | is_jal;

assign actual_npc   = sel_jalr ? npc_jalr : sel_tgt ? npc_imm : pc4;
assign target       = sel_jalr ? npc_jalr : npc_imm;
assign mis_align    = sel_jalr ? a_jalr   : a_imm;
assign npc_mismatch = sel_jalr ? m_jalr   : sel_tgt ? m_imm : m_pc4;

endmodule
