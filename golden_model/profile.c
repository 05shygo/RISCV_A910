#include "profile.h"
#include <string.h>

// 见 include/profile.h 的口径说明. 本文件只加计数器, 不改变任何执行语义 ——
// 被 CSRC_GM 的通配符收进 difftest 也完全无害 (计数是 O(1) 的几条自增).

unsigned long gm_prof_cat[CAT_NUM];
unsigned long gm_prof_aluop[AOP_NUM];
unsigned long gm_prof_total;
unsigned long gm_prof_wb;
unsigned long gm_prof_mult;
unsigned long gm_prof_div;

// pc>>2 索引, 覆盖整个 64KB 映像
#define PC_HIST_N (MEM_SZ / 4)
static unsigned long pc_hist[PC_HIST_N];

unsigned long *gm_prof_pc_hist(unsigned *n_entries) {
    if (n_entries) *n_entries = PC_HIST_N;
    return pc_hist;
}

static const char *cat_name[CAT_NUM] = {
    "ALU-R   (add/sub/and/or/xor/sll/srl/sra/slt/sltu)",
    "ALU-I   (addi/andi/ori/xori/slli/srli/srai/slti/sltiu)",
    "LUI",
    "AUIPC",
    "BRANCH  (beq/bne/blt/bge/bltu/bgeu)",
    "JAL",
    "JALR",
    "MUL     (mul/mulh/mulhsu/mulhu)",
    "DIV     (div/divu/rem/remu)",
    "LOAD    (lb/lh/lw/lbu/lhu)",
    "STORE   (sb/sh/sw)",
    "CSR",
    "SYS     (ecall/ebreak/mret)",
    "ILLEGAL"
};

static const char *aluop_name[AOP_NUM] = {
    "ADD", "SUB", "SLL", "SLT", "SLTU", "XOR", "SRL", "SRA", "OR", "AND", "LUI/AUIPC"
};

// ---------------------------------------------------------------------------
// 一条退休指令 → 分类. 口径:
//   1) 先看译码器判的非法 (ID.c 的 exc_cause) —— 它比 opcode 更权威;
//   2) 再按 opcode 落到各发射队列上 (与 ct_idu_is_ctrl.sv 的分派一致).
// ---------------------------------------------------------------------------
void gm_profile_count(const ID2EX *d) {
    uint32_t inst = d->inst;
    uint32_t opcode = inst & 0x7fu;

    gm_prof_total++;
    if (d->wb_en) gm_prof_wb++;
    if (d->pc < MEM_SZ) pc_hist[d->pc >> 2]++;

    if (d->exc_valid && d->exc_cause == EXC_ILLEGAL_INST) {
        gm_prof_cat[CAT_ILLEGAL]++;
        return;
    }

    int cat = -1;
    int aop = -1;

    switch (opcode) {
        case 0x33: {   // OP
            uint32_t funct7 = inst >> 25;
            uint32_t funct3 = (inst >> 12) & 0x7u;
            if (funct7 == 1) {
                cat = (funct3 < 4) ? CAT_MUL : CAT_DIV;
                if (cat == CAT_MUL) gm_prof_mult++; else gm_prof_div++;
                break;
            }
            cat = CAT_ALU_R;
            switch (d->alu_op) {
                case OP_ADD:  aop = AOP_ADD;  break;
                case OP_SUB:  aop = AOP_SUB;  break;
                case OP_SLL:  aop = AOP_SLL;  break;
                case OP_SLT:  aop = AOP_SLT;  break;
                case OP_SLTU: aop = AOP_SLTU; break;
                case OP_XOR:  aop = AOP_XOR;  break;
                case OP_SRL:  aop = AOP_SRL;  break;
                case OP_SRA:  aop = AOP_SRA;  break;
                case OP_OR:   aop = AOP_OR;   break;
                case OP_AND:  aop = AOP_AND;  break;
                default: break;
            }
            break;
        }
        case 0x13:     // OP-IMM
            cat = CAT_ALU_I;
            switch (d->alu_op) {
                case OP_ADD:  aop = AOP_ADD;  break;
                case OP_SLL:  aop = AOP_SLL;  break;
                case OP_SLT:  aop = AOP_SLT;  break;
                case OP_SLTU: aop = AOP_SLTU; break;
                case OP_XOR:  aop = AOP_XOR;  break;
                case OP_SRL:  aop = AOP_SRL;  break;
                case OP_SRA:  aop = AOP_SRA;  break;
                case OP_OR:   aop = AOP_OR;   break;
                case OP_AND:  aop = AOP_AND;  break;
                default: break;
            }
            break;
        case 0x37: cat = CAT_LUI;   aop = AOP_PASS; break;
        case 0x17: cat = CAT_AUIPC; aop = AOP_PASS; break;
        case 0x63: cat = CAT_BRANCH; break;
        case 0x6f: cat = CAT_JAL;    break;
        case 0x67: cat = CAT_JALR;   break;
        case 0x03: cat = CAT_LOAD;   break;
        case 0x23: cat = CAT_STORE;  break;
        case 0x73: {   // SYSTEM
            uint32_t funct3 = (inst >> 12) & 0x7u;
            // funct3==0 是 PRIV 组: ecall/ebreak/mret (其余如 wfi 会被判非法)
            cat = (funct3 == 0) ? CAT_SYS : CAT_CSR;
            break;
        }
        default:
            cat = CAT_ILLEGAL;
            break;
    }

    if (cat >= 0) gm_prof_cat[cat]++;
    if (aop >= 0) gm_prof_aluop[aop]++;
}

// ---------------------------------------------------------------------------
// 打印. 顺带把"1 个 ALU 能撑到多少 IPC"的**上界**算出来, 这是本次画像的结论口:
//   设 ALU 类指令占动态指令的 F, 单 ALU 每拍只能吞吐 1 条 ⇒ IPC ≤ 1/F.
// ---------------------------------------------------------------------------
void gm_profile_dump(FILE *fp) {
    // ⚠️ C89: 循环变量必须在块首声明 —— VCS 用的系统 gcc 4.8.5 默认就是 gnu90,
    //    写成 `for (int i = ...)` 会让**整个 difftest 链接失败**. 别改回去.
    int i;
    unsigned long tot = gm_prof_total ? gm_prof_total : 1;
    unsigned long alu_ops = gm_prof_cat[CAT_ALU_R] + gm_prof_cat[CAT_ALU_I]
                          + gm_prof_cat[CAT_LUI]   + gm_prof_cat[CAT_AUIPC];
    unsigned long biq_ops = gm_prof_cat[CAT_BRANCH] + gm_prof_cat[CAT_JAL]
                          + gm_prof_cat[CAT_JALR];
    unsigned long md_ops  = gm_prof_cat[CAT_MUL] + gm_prof_cat[CAT_DIV];
    unsigned long ls_ops  = gm_prof_cat[CAT_LOAD] + gm_prof_cat[CAT_STORE];

    fprintf(fp, "\n================ 黄金模型动态指令画像 ================\n");
    fprintf(fp, "退休指令总数 : %lu\n", gm_prof_total);
    fprintf(fp, "写回寄存器   : %lu (%.2f%%)   —— 其余是 store/分支/被丢弃的 x0\n",
            gm_prof_wb, 100.0 * gm_prof_wb / tot);

    fprintf(fp, "\n---- 按发射队列分 (决定执行单元压力) ----\n");
    for (i = 0; i < CAT_NUM; i++) {
        if (!gm_prof_cat[i]) continue;
        fprintf(fp, "  %-52s %10lu  %6.2f%%\n", cat_name[i], gm_prof_cat[i],
                100.0 * gm_prof_cat[i] / tot);
    }

    fprintf(fp, "\n---- 归并到执行单元 ----\n");
    fprintf(fp, "  %-14s %10lu  %6.2f%%\n", "ALU (AIQ)",      alu_ops, 100.0 * alu_ops / tot);
    fprintf(fp, "  %-14s %10lu  %6.2f%%\n", "分支+跳转(BIQ)", biq_ops, 100.0 * biq_ops / tot);
    fprintf(fp, "  %-14s %10lu  %6.2f%%\n", "乘除 (MIQ)",     md_ops,  100.0 * md_ops  / tot);
    fprintf(fp, "  %-14s %10lu  %6.2f%%\n", "访存 (LSU)",     ls_ops,  100.0 * ls_ops  / tot);
    fprintf(fp, "  %-14s %10lu  %6.2f%%\n", "CSR+SYS",
            gm_prof_cat[CAT_CSR] + gm_prof_cat[CAT_SYS],
            100.0 * (gm_prof_cat[CAT_CSR] + gm_prof_cat[CAT_SYS]) / tot);
    fprintf(fp, "  %-14s %10lu  %6.2f%%\n", "非法", gm_prof_cat[CAT_ILLEGAL],
            100.0 * gm_prof_cat[CAT_ILLEGAL] / tot);

    fprintf(fp, "\n---- ALU 类内部算子分布 ----\n");
    for (i = 0; i < AOP_NUM; i++) {
        if (!gm_prof_aluop[i]) continue;
        fprintf(fp, "  %-10s %10lu  %6.2f%% (占 ALU 类 %.1f%%)\n",
                aluop_name[i], gm_prof_aluop[i],
                100.0 * gm_prof_aluop[i] / tot,
                100.0 * gm_prof_aluop[i] / (alu_ops ? alu_ops : 1));
    }

    fprintf(fp, "\n---- 单 ALU 的 IPC 天花板 ----\n");
    if (alu_ops) {
        double F = (double)alu_ops / (double)tot;
        fprintf(fp, "  ALU 类占比 F = %.4f  ⇒  1 个 ALU 时 IPC ≤ 1/F = %.3f\n", F, 1.0 / F);
        fprintf(fp, "  2 个 ALU 时天花板升到 %.3f (近似, 假设可完美双发射)\n", 2.0 / F);
    }
    fprintf(fp, "  (注意: 这是**纯吞吐**上界, 没算依赖链/发射口数/前端供给)\n");
    fprintf(fp, "======================================================\n\n");
    fflush(fp);
}
