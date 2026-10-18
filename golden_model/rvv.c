// RVV 向量黄金模型: 状态 / vset / 解码 / 分派.
//
// 提交步进: 每次 cpu_run_once() 执行一条架构指令, vset* 与标量指令走原来的
// ID/EX/MEM/WB 通路, 真正的向量运算/访存在 EX 级调 rvv_execute().
//
// 语义以本仓 RTL 为准 (见 include/rvv.h 顶部注释).

#include <cpu.h>
#include <rvv.h>
#include <string.h>
#include <stdio.h>

extern riscv32_CPU_state cpu;

rvv_last_t rvv_last;
int cpu_last_executed = 0;

#define RVV_OP_LOAD   0x07u
#define RVV_OP_STORE  0x27u
#define RVV_OP_OPV    0x57u

// funct3 分类 (与 rvv_backend_opcode.svh 一致)
#define RVV_F3_OPIVV  0u
#define RVV_F3_OPFVV  1u
#define RVV_F3_OPMVV  2u
#define RVV_F3_OPIVI  3u
#define RVV_F3_OPIVX  4u
#define RVV_F3_OPFVF  5u
#define RVV_F3_OPMVX  6u
#define RVV_F3_OPCFG  7u

void rvv_reset(void) {
  memset(&cpu.vec, 0, sizeof(cpu.vec));
  // 与 RvvFrontEnd.sv 的复位一致: vill=1, SEW=e8, LMUL=m1
  cpu.vec.vtype = (1u << RVV_VTYPE_VILL_BIT)
                | ((uint32_t)RVV_SEW8 << RVV_VTYPE_SEW_SHIFT)
                | ((uint32_t)RVV_LMUL1 << RVV_VTYPE_LMUL_SHIFT);
  cpu.vec.vl = 0;
  cpu.vec.vstart = 0;
  cpu.vec.vxrm = 0;
  cpu.vec.vxsat = 0;
  memset(&rvv_last, 0, sizeof(rvv_last));
  cpu_last_executed = 0;
}

// ---------------------------------------------------------------------------
// vtype 解码
// ---------------------------------------------------------------------------
int rvv_sew_code(void) { return (int)((cpu.vec.vtype >> RVV_VTYPE_SEW_SHIFT) & 0x7u); }
int rvv_sew_bits(void) { return 8 << rvv_sew_code(); }
int rvv_lmul_code(void) { return (int)(cpu.vec.vtype & 0x7u); }

int rvv_lmul_num(void) {
  switch (rvv_lmul_code()) {
    case RVV_LMUL2: return 2;
    case RVV_LMUL4: return 4;
    case RVV_LMUL8: return 8;
    default:        return 1;
  }
}
int rvv_lmul_den(void) {
  switch (rvv_lmul_code()) {
    case RVV_LMUL1_8: return 8;
    case RVV_LMUL1_4: return 4;
    case RVV_LMUL1_2: return 2;
    default:          return 1;
  }
}

int rvv_group_regs(void) {
  int n = rvv_lmul_num() / rvv_lmul_den();
  return (n < 1) ? 1 : n;
}

// 目的组的寄存器数 = LMUL * mult (mult = 1/2/4)
int rvv_group_regs_mult(int mult) {
  int n = (rvv_lmul_num() * mult) / rvv_lmul_den();
  return (n < 1) ? 1 : n;
}

// ---------------------------------------------------------------------------
// 元素 / 字节访问
//   eew 单位是 bit; 元素不会跨 16B 寄存器边界 (8/16/32 都整除 16).
// ---------------------------------------------------------------------------
uint32_t rvv_elem_get(uint32_t base, uint32_t idx, uint32_t eew, int sign) {
  uint32_t nbytes = eew / 8;
  uint32_t byte_off = idx * nbytes;
  uint32_t reg = (base + byte_off / RVV_VLENB) & 31u;
  uint32_t off = byte_off % RVV_VLENB;
  uint32_t val = 0;
  uint32_t i;
  for (i = 0; i < nbytes; i++)
    val |= (uint32_t)cpu.vec.vreg[reg][off + i] << (8 * i);
  if (sign && eew < 32) {
    uint32_t sh = 32 - eew;
    return (uint32_t)(((int32_t)(val << sh)) >> sh);
  }
  return val;
}

void rvv_elem_put(uint32_t base, uint32_t idx, uint32_t eew, uint32_t val) {
  uint32_t nbytes = eew / 8;
  uint32_t byte_off = idx * nbytes;
  uint32_t reg = (base + byte_off / RVV_VLENB) & 31u;
  uint32_t off = byte_off % RVV_VLENB;
  uint32_t i;
  for (i = 0; i < nbytes; i++)
    rvv_put_byte(reg, off + i, (uint8_t)(val >> (8 * i)));
}

void rvv_put_byte(uint32_t reg, uint32_t byte, uint8_t val) {
  uint32_t rel;
  if (reg >= RVV_NUM_REGS || byte >= RVV_VLENB) return;
  cpu.vec.vreg[reg][byte] = val;
  rel = (reg - rvv_last.vd_base) & 31u;
  if (rel < rvv_last.nreg && rel < RVV_MAX_DEST_REGS)
    rvv_last.wmask[rel] |= (uint16_t)(1u << byte);
}

void rvv_set_dst(uint32_t base, uint32_t nreg) {
  uint32_t i;
  rvv_last.vd_base = base & 31u;
  rvv_last.nreg = nreg;
  for (i = 0; i < RVV_MAX_DEST_REGS; i++) rvv_last.wmask[i] = 0;
}

// ---------------------------------------------------------------------------
// 解码
// ---------------------------------------------------------------------------
int rvv_decode(uint32_t inst, rvv_dec_t *d) {
  memset(d, 0, sizeof(*d));
  d->inst   = inst;
  d->opcode = inst & 0x7fu;
  d->rd     = (inst >> 7) & 0x1fu;
  d->funct3 = (inst >> 12) & 0x7u;
  d->rs1    = (inst >> 15) & 0x1fu;
  d->rs2    = (inst >> 20) & 0x1fu;
  d->vm     = (inst >> 25) & 0x1u;
  d->funct6 = (inst >> 26) & 0x3fu;

  if (d->opcode == RVV_OP_OPV) {
    d->vd  = d->rd;
    d->vs2 = d->rs2;
    d->vs1 = d->rs1;
    if (d->funct3 == RVV_F3_OPCFG) {
      d->is_vset = 1;
    } else if (d->funct3 == RVV_F3_OPIVI) {
      // 5 位有符号立即数, 位于 inst[19:15]
      d->imm = ((int32_t)(inst << 12)) >> 27;
    }
    return 1;
  }

  if (d->opcode == RVV_OP_LOAD || d->opcode == RVV_OP_STORE) {
    d->is_load  = (d->opcode == RVV_OP_LOAD);
    d->is_store = (d->opcode == RVV_OP_STORE);
    d->vd       = d->rd;       // load: vd; store: vs3
    d->base_rs1 = d->rs1;      // inst[19:15]
    d->nf       = (inst >> 29) & 0x7u;
    d->mew      = (inst >> 28) & 0x1u;
    d->mop      = (inst >> 26) & 0x3u;
    d->lumop    = d->rs2;      // inst[24:20]: lumop/sumop / stride / index vector
    return 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// vset*
// ---------------------------------------------------------------------------
static int vtype_is_legal(uint32_t vt) {
  uint32_t sew  = (vt >> 3) & 0x7u;
  uint32_t lmul = vt & 0x7u;
  if (sew > 2) return 0;                       // 只支持 e8/e16/e32
  switch (lmul) {
    case RVV_LMULRESERVED:
    case RVV_LMUL1_8:
      return 0;
    case RVV_LMUL1_4:
      return (sew == RVV_SEW8);
    case RVV_LMUL1_2:
      return (sew <= RVV_SEW16);
    default:
      return 1;
  }
}

static uint32_t vtype_vlmax(uint32_t vt) {
  uint32_t sew  = (vt >> 3) & 0x7u;
  uint32_t lmul = vt & 0x7u;
  uint32_t bytes;
  switch (lmul) {
    case RVV_LMUL1_8: bytes = RVV_VLENB / 8; break;
    case RVV_LMUL1_4: bytes = RVV_VLENB / 4; break;
    case RVV_LMUL1_2: bytes = RVV_VLENB / 2; break;
    case RVV_LMUL1:   bytes = RVV_VLENB;     break;
    case RVV_LMUL2:   bytes = RVV_VLENB * 2; break;
    case RVV_LMUL4:   bytes = RVV_VLENB * 4; break;
    case RVV_LMUL8:   bytes = RVV_VLENB * 8; break;
    default:          bytes = 0;             break;
  }
  return bytes >> sew;
}

uint32_t rvv_vset_exec(const rvv_dec_t *d) {
  uint32_t avl = 0;
  uint32_t vt  = 0;
  uint32_t vlmax;

  if ((d->inst >> 30) == 0x3u) {
    // vsetivli: uimm[4:0] 在 inst[19:15], vtype 在 inst[27:20]
    avl = d->rs1;
    vt  = (d->inst >> 20) & 0xffu;
  } else if ((d->inst >> 25) == 0x40u) {
    // vsetvl: vtype 来自 x[rs2]
    avl = (d->rs1 == 0) ? ((d->rd != 0) ? 0xffffffffu : cpu.vec.vl)
                        : cpu.gpr[d->rs1];
    vt  = cpu.gpr[d->rs2] & 0xffu;
  } else if ((d->inst >> 31) == 0u) {
    // vsetvli: vtype 在 inst[30:20] (只用低 8 位)
    avl = (d->rs1 == 0) ? ((d->rd != 0) ? 0xffffffffu : cpu.vec.vl)
                        : cpu.gpr[d->rs1];
    vt  = (d->inst >> 20) & 0xffu;
  } else {
    // 非法编码: 按 vill 处理 (本 SoC 的 frontend 也不认)
    vt = 0xffu;
    avl = 0;
  }

  if (!vtype_is_legal(vt)) {
    cpu.vec.vtype = (1u << RVV_VTYPE_VILL_BIT)
                  | ((uint32_t)RVV_SEW8 << RVV_VTYPE_SEW_SHIFT)
                  | ((uint32_t)RVV_LMUL1 << RVV_VTYPE_LMUL_SHIFT);
    cpu.vec.vl = 0;
    cpu.vec.vstart = 0;
    return 0;
  }

  vlmax = vtype_vlmax(vt);
  cpu.vec.vtype = vt & 0xffu;
  cpu.vec.vl = (avl > vlmax) ? vlmax : avl;
  cpu.vec.vstart = 0;
  return cpu.vec.vl;
}

// ---------------------------------------------------------------------------
// ID 级分派: 0x57 / 0x07 / 0x27 不再走 illegal
// ---------------------------------------------------------------------------
ID2EX ID_VECTOR(IF2ID inst) {
  ID2EX ret = {0};
  rvv_dec_t d;

  ret.inst_raw_split.inst_raw = inst.inst;
  ret.next_pc = inst.pc + 4;
  ret.pc = inst.pc;
  ret.inst = inst.inst;
  ret.alu_op = OP_VECTOR;
  ret.is_vec = 1;

  rvv_decode(inst.inst, &d);

  // 供 DPI 查 "上一条向量指令"
  rvv_last.valid = 1;
  rvv_last.is_vec = 1;
  rvv_last.is_vset = d.is_vset;
  rvv_last.pc = inst.pc;
  rvv_last.inst = inst.inst;
  rvv_set_dst(d.vd, 0);

  if (d.is_vset) {
    // vset 的 rd 写回新 vl; 走原 WB 通路
    ret.dst = d.rd;
    ret.wb_sel = WB_ALU;
    ret.wb_en = (d.rd != 0);
  }
  return ret;
}

// ---------------------------------------------------------------------------
// EX 级执行
// ---------------------------------------------------------------------------
uint32_t rvv_execute(uint32_t inst, uint32_t pc, rvv_trap_t *trap) {
  rvv_dec_t d;

  trap->valid = 0;
  trap->cause = 0;
  trap->tval  = 0;

  rvv_decode(inst, &d);
  rvv_last.is_vec = 1;
  rvv_last.is_vset = d.is_vset;
  rvv_last.pc = pc;
  rvv_last.inst = inst;
  rvv_set_dst(d.vd, 0);

  if (d.is_vset)
    return rvv_vset_exec(&d);

  if (cpu.vec.vtype & (1u << RVV_VTYPE_VILL_BIT)) {
    trap->valid = 1;
    trap->cause = EXC_ILLEGAL_INST;
    trap->tval  = inst;
    return 0;
  }

  if (d.is_load || d.is_store)
    rvv_mem_exec(&d, trap);
  else
    rvv_alu_exec(&d, trap);

  if (trap->valid) {
    // 异常指令没有架构副作用; 已写的 vreg 字节不应参与比对 (预检查保证不会发生)
    rvv_set_dst(d.vd, 0);
  }
  return 0;
}

// ---------------------------------------------------------------------------
// DPI 查询
// ---------------------------------------------------------------------------
int rvv_last_executed(void) { return cpu_last_executed; }
int rvv_last_is_vec(void) { return rvv_last.valid && rvv_last.is_vec; }
int rvv_last_is_vset(void) { return rvv_last.is_vset; }
int rvv_last_vd_base(void) { return (int)rvv_last.vd_base; }
int rvv_last_vd_nreg(void) { return (int)rvv_last.nreg; }

uint32_t rvv_last_vd_word(int rel_reg, int word) {
  uint32_t reg = (rvv_last.vd_base + (uint32_t)rel_reg) & 31u;
  uint32_t off = (uint32_t)word * 4u;
  uint32_t val = 0;
  if (off + 4 > RVV_VLENB) return 0;
  val  = (uint32_t)cpu.vec.vreg[reg][off + 0];
  val |= (uint32_t)cpu.vec.vreg[reg][off + 1] << 8;
  val |= (uint32_t)cpu.vec.vreg[reg][off + 2] << 16;
  val |= (uint32_t)cpu.vec.vreg[reg][off + 3] << 24;
  return val;
}

int rvv_last_vd_wmask(int rel_reg) {
  if (rel_reg < 0 || rel_reg >= (int)rvv_last.nreg || rel_reg >= RVV_MAX_DEST_REGS)
    return 0;
  return (int)rvv_last.wmask[rel_reg];
}

uint32_t rvv_last_inst_word(void) { return rvv_last.inst; }
uint32_t rvv_last_pc(void) { return rvv_last.pc; }
