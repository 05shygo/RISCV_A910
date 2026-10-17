#ifndef __PROFILE_H__
#define __PROFILE_H__

// ---------------------------------------------------------------------------
// 黄金模型的**动态指令画像** —— 统计每条退休指令落在哪条发射队列/执行单元上.
//
// 之所以可信: 黄金模型是提交步进的, 每个提交恰好调一次 ID(), 所以这里的计数
// 就是 DUT 的**退休指令流**; difftest PASS 时两者逐条一致.
//
// 之所以便宜: 整个模型是纯 C 解释器, 9.4M 条指令一两秒跑完, 不需要开 RTL 仿真.
// 用法见 golden_model/standalone/main_prof.c.
//
// 分类口径照着 A910 的发射队列切 (mySoC/idu_c910/rtl/ct_idu_is_*.sv):
//   ALU   → AIQ  → IU_alu_pipe   (目前只例化了 1 个)
//   BR/JMP→ BIQ  → IU_beu_pipe
//   MD    → MIQ  → IU_md_pipe
//   LOAD  → LSIQ → LSU
//   STORE → SDIQ → LSU
//   CSR / SYS → 见 profile.c 里的说明
// ---------------------------------------------------------------------------

#include <stdio.h>
#include "cpu.h"

typedef enum {
    CAT_ALU_R = 0,   // OP(opcode 0x33) 非 M 扩展: ADD/SUB/AND/OR/XOR/SLL/SRL/SRA/SLT/SLTU
    CAT_ALU_I,       // OP-IMM(0x13): ADDI/ANDI/.../SLLI/SRLI/SRAI
    CAT_LUI,         // LUI
    CAT_AUIPC,       // AUIPC
    CAT_BRANCH,      // BEQ/BNE/BLT/BGE/BLTU/BGEU
    CAT_JAL,         // JAL
    CAT_JALR,        // JALR
    CAT_MUL,         // MUL/MULH/MULHSU/MULHU
    CAT_DIV,         // DIV/DIVU/REM/REMU
    CAT_LOAD,        // LB/LH/LW/LBU/LHU
    CAT_STORE,       // SB/SH/SW
    CAT_CSR,         // CSRRW/S/C + 立即数形式
    CAT_SYS,         // ECALL/EBREAK/MRET
    CAT_ILLEGAL,     // 非法指令 (含 OOB 取指)
    CAT_NUM
} gm_cat_t;

// 更细的 ALU 算子分布 (只对 CAT_ALU_R / CAT_ALU_I / CAT_LUI / CAT_AUIPC 有意义)
typedef enum {
    AOP_ADD = 0, AOP_SUB, AOP_SLL, AOP_SLT, AOP_SLTU, AOP_XOR,
    AOP_SRL, AOP_SRA, AOP_OR, AOP_AND, AOP_PASS,   // PASS = LUI/AUIPC 的拼装
    AOP_NUM
} gm_aluop_t;

extern unsigned long gm_prof_cat[CAT_NUM];
extern unsigned long gm_prof_aluop[AOP_NUM];
extern unsigned long gm_prof_total;      // 退休指令总数
extern unsigned long gm_prof_wb;         // 其中真的写回寄存器的条数
extern unsigned long gm_prof_mult;       // 乘除内部再细分
extern unsigned long gm_prof_div;

// 每条 PC 的退休次数 (发现热点循环用). 下标 = pc>>2, 越界返回 NULL.
extern unsigned long *gm_prof_pc_hist(unsigned *n_entries);

void gm_profile_count(const ID2EX *d);
void gm_profile_dump(FILE *fp);

#endif
