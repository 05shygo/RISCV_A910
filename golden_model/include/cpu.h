#ifndef __CPU__
#define __CPU__
#include <stdint.h>
#include <stdbool.h>
#include "debug.h"
#define MEM_PADDR_BITS 16
#define MEM_SZ (1 << MEM_PADDR_BITS)
#define MAX_PERIPHERAL 16

typedef enum{
    ACCESS_WORD,
    ACCESS_HWORD,
    ACCESS_BYTE
} AccessMode;

typedef uint32_t(*PeripheralRCallback)(uint32_t rel_addr, AccessMode mode);
typedef void(*PeripheralWCallback)(uint32_t rel_addr, AccessMode mode, uint32_t data);

typedef struct {
    const char* name;
    uint32_t base_addr;
    uint32_t len;
    PeripheralRCallback callback_r;
    PeripheralWCallback callback_w;
} peripheral_descr;

// ---- CSR 地址 (与 mySoC/defines.vh 一一对应) ----
#define CSR_MSTATUS   0x300
#define CSR_MIE       0x304
#define CSR_MTVEC     0x305
#define CSR_MSCRATCH  0x340
#define CSR_MEPC      0x341
#define CSR_MCAUSE    0x342
#define CSR_MTVAL     0x343
#define CSR_MIP       0x344
#define CSR_MCYCLE    0xB00
#define CSR_MINSTRET  0xB02
#define CSR_MCYCLEH   0xB80
#define CSR_MINSTRETH 0xB82
#define CSR_CYCLE     0xC00
#define CSR_INSTRET   0xC02
#define CSR_CYCLEH    0xC80
#define CSR_INSTRETH  0xC82

#define MSTATUS_MIE_BIT  3
#define MSTATUS_MPIE_BIT 7
#define MIE_MTIE_BIT     7

// ---- 异常 cause (与 mySoC/defines.vh 一致) ----
#define EXC_INST_MISALIGNED  0
#define EXC_INST_ACCESS      1
#define EXC_ILLEGAL_INST     2
#define EXC_BREAKPOINT       3
#define EXC_LOAD_MISALIGNED  4
#define EXC_LOAD_ACCESS      5
#define EXC_STORE_MISALIGNED 6
#define EXC_STORE_ACCESS     7
#define EXC_ECALL_M          11
#define INTR_MTIP_CAUSE      0x80000007u

typedef struct {
  uint32_t gpr[32];
  uint32_t pc;
  uint32_t npc;
  // ---- 机器模式 CSR ----
  // 只保存【已实现】的位, 未实现位读回恒 0 (WARL); 与 CSR.v 严格一一对应.
  uint32_t mstatus_mie;
  uint32_t mstatus_mpie;
  uint32_t mie_mtie;
  uint32_t mtvec;        // [31:2] 基址, [0] 模式, [1] 恒 0
  uint32_t mscratch;
  uint32_t mepc;
  uint32_t mcause;
  uint32_t mtval;
  uint64_t mcycle;       // 自由计数 (difftest 不比较)
  uint64_t minstret;     // 退休指令数 (difftest 不比较)
  // 已寄存的定时器中断电平, 由 TB 经 gm_set_irq() 推入;
  // golden model 自己【不重算】它 —— 自己算必然和 DUT 差拍.
  uint32_t irq_timer;
} riscv32_CPU_state;

typedef struct {
    uint32_t inst;
    uint32_t pc;
} IF2ID;

typedef enum { OP_TYPE_REG, OP_TYPE_MEM, OP_TYPE_IMM } op_type;
typedef enum { R, I, S, B, U, J } inst_format;
typedef enum { IMM_I, IMM_S, IMM_B, IMM_U, IMM_J } imm_format;
typedef enum { MEM_BYTE, MEM_HALF, MEM_WORD } mem_width;

typedef struct {
    op_type type;
    uint32_t value;
} Operand;

typedef struct {
    __uint32_t wb_have_inst;
    __uint32_t wb_pc;
    __uint32_t wb_reg;
    __uint32_t wb_value;
    __uint32_t wb_ena;
} WB_info;

typedef enum { OP_ADD, OP_SLT, OP_SLTU, OP_AND, OP_OR, OP_XOR, OP_SLL, OP_SRL, OP_SUB, OP_SRA, OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU, OP_DIV, OP_DIVU, OP_REM, OP_REMU, OP_INVALID, OP_ECALL, OP_EBREAK, OP_MRET, OP_CSR } alu_op_t;
// CSR 子操作
typedef enum { CSR_OP_NONE, CSR_OP_RW, CSR_OP_RS, CSR_OP_RC } csr_op_t;
typedef enum { MEM_LB, MEM_LBU, MEM_LH, MEM_LHU, MEM_LW, MEM_SB, MEM_SH, MEM_SW } mem_op_t;
typedef enum { BR_EQ, BR_NEQ, BR_GE, BR_GEU, BR_LT, BR_LTU, BR_JUMP, BR_JUMPREG } br_op_t;
typedef enum { WB_ALU, WB_PC, WB_LOAD } wb_sel_t;

#include "riscv32_instdef.h"
typedef struct {
    Decodeinfo_raw inst_raw_split;
    alu_op_t alu_op;
    mem_op_t mem_op;
    br_op_t  br_op;
    wb_sel_t wb_sel;   // TODO
    uint32_t next_pc;
    uint32_t is_jmp;
    uint32_t is_branch;
    uint32_t is_mem;
    Operand src1, src2;
    uint32_t store_val;
    uint32_t dst;
    uint32_t wb_en;
    uint32_t inst;
    uint32_t pc;
    // ---- CSR / 陷阱 ----
    csr_op_t csr_op;       // CSR_OP_NONE 表示不是 CSR 指令
    uint32_t csr_addr;
    uint32_t csr_we;       // 是否真的写 (csrrw 总是写; csrrs/csrrc 需 rs1!=x0)
    uint32_t is_mret;
    uint32_t exc_valid;    // 该指令产生同步异常
    uint32_t exc_cause;
    uint32_t exc_tval;
} ID2EX;

typedef struct {
    uint32_t alu_out;
    uint32_t store_val;
    uint32_t is_mem;
    mem_op_t mem_op;
    wb_sel_t wb_sel;
    uint32_t wb_en;
    uint32_t dst;
    uint32_t branch_taken;
    uint32_t target_pc;
    uint32_t inst;
    uint32_t pc;
    uint32_t exc_valid;
    uint32_t exc_cause;
    uint32_t exc_tval;
    uint32_t is_mret;
} EX2MEM;

typedef struct {
    uint32_t alu_out;
    uint32_t load_out;
    wb_sel_t wb_sel;
    uint32_t wb_en;
    uint32_t dst;
    uint32_t branch_taken;
    uint32_t target_pc;
    uint32_t inst;
    uint32_t pc;
    uint32_t exc_valid;
    uint32_t exc_cause;
    uint32_t exc_tval;
    uint32_t is_mret;
} MEM2WB;

#endif
