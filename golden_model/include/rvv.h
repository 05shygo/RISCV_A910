#ifndef __RVV_H__
#define __RVV_H__

#include <stdint.h>
#include "cpu.h"

// ---------------------------------------------------------------------------
// RVV 架构模型 (VLEN=128 / ELEN=32)
//
// 语义按【本仓 RTL】取齐, 不是纯 spec:
//   * ta/ma 不生效, 一律 tail/mask undisturbed;
//   * vstart 恒 0, vxrm 恒 RNU;
//   * 窄化指令的 vtype.SEW 是【目的】宽度, 源 EEW=2*SEW;
//   * 扩展指令的 vtype.SEW 是【源】宽度, 目的 EEW=2/4*SEW;
//   * 索引向量访存的索引是【字节偏移】, 不乘元素大小.
// ---------------------------------------------------------------------------

typedef struct {
  int valid;
  uint32_t cause;
  uint32_t tval;
} rvv_trap_t;

typedef struct {
  uint32_t inst;
  uint32_t pc;
  uint32_t opcode;
  uint32_t funct3;
  uint32_t funct6;
  uint32_t vm;
  uint32_t rd;
  uint32_t rs1;
  uint32_t rs2;
  uint32_t vd;
  uint32_t vs1;
  uint32_t vs2;
  int32_t  imm;
  int      is_load;
  int      is_store;
  int      is_vset;
  // 向量 load/store
  uint32_t mop;
  uint32_t nf;
  uint32_t mew;
  uint32_t lumop;      // [24:20]: lumop/sumop, stride 寄存器, 或索引向量
  uint32_t base_rs1;   // inst[19:15]
} rvv_dec_t;

// 供 DPI 查询的"上一条向量指令"结果. 数据直接从 cpu.vec.vreg 读,
// 这里只记下本次指令写了哪些字节, 供 TB 和 DUT 的退休记录逐字节比对.
typedef struct {
  int      valid;      // 本拍是否执行了一条向量指令
  int      is_vec;
  int      is_vset;
  uint32_t pc;
  uint32_t inst;
  uint32_t vd_base;
  uint32_t nreg;       // 目的组寄存器数 (store 时为 0)
  uint16_t wmask[RVV_MAX_DEST_REGS];
} rvv_last_t;

extern rvv_last_t rvv_last;
extern int cpu_last_executed;

// ---- 生命周期 / 执行 ----
void      rvv_reset(void);
ID2EX     ID_VECTOR(IF2ID inst);
uint32_t  rvv_execute(uint32_t inst, uint32_t pc, rvv_trap_t *trap);

// ---- 解码 / 共享工具 ----
int       rvv_decode(uint32_t inst, rvv_dec_t *d);
uint32_t  rvv_vset_exec(const rvv_dec_t *d);
void      rvv_alu_exec(const rvv_dec_t *d, rvv_trap_t *trap);
void      rvv_mem_exec(const rvv_dec_t *d, rvv_trap_t *trap);

int       rvv_sew_bits(void);
int       rvv_sew_code(void);
int       rvv_lmul_code(void);
int       rvv_lmul_num(void);
int       rvv_lmul_den(void);
int       rvv_group_regs(void);       // 架构目的组的寄存器数
int       rvv_group_regs_mult(int mult); // LMUL*mult (用于加宽/扩展目的组)

uint32_t  rvv_elem_get(uint32_t base, uint32_t idx, uint32_t eew, int sign);
void      rvv_elem_put(uint32_t base, uint32_t idx, uint32_t eew, uint32_t val);
void      rvv_put_byte(uint32_t reg, uint32_t byte, uint8_t val);
void      rvv_set_dst(uint32_t base, uint32_t nreg);

// ---- DPI 包装用的取值 (定义在 rvv.c) ----
int       rvv_last_executed(void);
int       rvv_last_is_vec(void);
int       rvv_last_is_vset(void);
int       rvv_last_vd_base(void);
int       rvv_last_vd_nreg(void);
uint32_t  rvv_last_vd_word(int rel_reg, int word);
int       rvv_last_vd_wmask(int rel_reg);
uint32_t  rvv_last_inst_word(void);
uint32_t  rvv_last_pc(void);

#endif // __RVV_H__
