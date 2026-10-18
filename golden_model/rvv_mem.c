// RVV 向量访存: 字节粒度 load/store
//   * unit-stride (mop=00, lumop/sumop=0)
//   * constant-stride (mop=10, 步长在 rs2 字段)
//   * indexed unordered/ordered (mop=01/11, 索引向量在 vs2 字段)
//
// 索引是【字节偏移】, 不乘元素大小, 按索引 EEW 符号扩展.
// 先对所有 active 元素做地址预检查, 任一越界则整条指令不产生副作用.

#include <cpu.h>
#include <rvv.h>

extern riscv32_CPU_state cpu;
extern uint32_t memory[];
#ifdef GM_TRACE_COREMARK
extern rvv_last_t rvv_last;
extern void gm_trace_store(uint32_t, uint32_t, uint32_t);
#endif

#define RVV_OP_LOAD   0x07u
#define RVV_OP_STORE  0x27u

#define MOP_UNIT      0u
#define MOP_INDEXED   1u
#define MOP_STRIDED   2u
#define MOP_ORDERED   3u

static int mask_bit(uint32_t i) {
  return (cpu.vec.vreg[0][i >> 3] >> (i & 7u)) & 1;
}

static int elem_active(const rvv_dec_t *d, uint32_t i) {
  if (i >= cpu.vec.vl) return 0;
  if (d->vm) return 1;
  return mask_bit(i);
}

static uint8_t rd8(uint32_t a) {
  return (uint8_t)(memory[a >> 2] >> ((a & 3u) * 8u));
}

static void wr8(uint32_t a, uint8_t v) {
  uint32_t idx = a >> 2;
  uint32_t sh  = (a & 3u) * 8u;
  memory[idx] = (memory[idx] & ~(0xffu << sh)) | ((uint32_t)v << sh);
#ifdef GM_TRACE_COREMARK
  gm_trace_store(a, rvv_last.pc, rvv_last.inst);
#endif
}

static uint32_t rd_elem(uint32_t a, uint32_t nbytes) {
  uint32_t v = 0, i;
  for (i = 0; i < nbytes; i++)
    v |= (uint32_t)rd8(a + i) << (8 * i);
  return v;
}

static void wr_elem(uint32_t a, uint32_t nbytes, uint32_t v) {
  uint32_t i;
  for (i = 0; i < nbytes; i++)
    wr8(a + i, (uint8_t)(v >> (8 * i)));
}

static int range_ok(uint32_t a, uint32_t n) {
  // 向量访存只建模低 64KB DRAM; MMIO 不在向量用例范围内.
  if (a >= MEM_SZ) return 0;
  if (n > MEM_SZ - a) return 0;
  return 1;
}

static void illegal(rvv_trap_t *trap, const rvv_dec_t *d) {
  trap->valid = 1;
  trap->cause = EXC_ILLEGAL_INST;
  trap->tval  = d->inst;
}

// 把 funct3 的 width 字段翻译成字节数 (e8=0, e16=5, e32=6)
static int width_bytes(uint32_t funct3) {
  switch (funct3) {
    case 0: return 1;
    case 5: return 2;
    case 6: return 4;
    default: return 0;
  }
}

// 计算第 i 个元素的地址
static uint32_t elem_addr(const rvv_dec_t *d, uint32_t i,
                          uint32_t ebytes, int idx_bytes) {
  uint32_t base = cpu.gpr[d->base_rs1];
  switch (d->mop) {
    case MOP_UNIT:
      return base + i * ebytes;
    case MOP_STRIDED: {
      int32_t stride = (int32_t)cpu.gpr[d->lumop];
      return base + (uint32_t)((int32_t)(i * (uint32_t)stride));
    }
    case MOP_INDEXED:
    case MOP_ORDERED: {
      int32_t off = (int32_t)rvv_elem_get(d->lumop, i,
                                          (uint32_t)idx_bytes * 8u, 1);
      return base + (uint32_t)off;
    }
    default:
      return base;
  }
}

void rvv_mem_exec(const rvv_dec_t *d, rvv_trap_t *trap) {
  int sew = rvv_sew_bits();
  int ebytes = sew / 8;
  int idx_bytes = 0;
  uint32_t i;
  uint32_t nreg;

  if (d->nf != 0 || d->mew != 0) {   // 段/宽索引不在本模型范围
    illegal(trap, d);
    return;
  }

  switch (d->mop) {
    case MOP_UNIT:
      if (d->lumop != 0) {           // whole-register / mask / fault-first
        illegal(trap, d);
        return;
      }
      if (width_bytes(d->funct3) == 0) { illegal(trap, d); return; }
      if (width_bytes(d->funct3) != ebytes) { illegal(trap, d); return; }
      break;
    case MOP_STRIDED:
      if (width_bytes(d->funct3) == 0) { illegal(trap, d); return; }
      if (width_bytes(d->funct3) != ebytes) { illegal(trap, d); return; }
      break;
    case MOP_INDEXED:
    case MOP_ORDERED:
      idx_bytes = width_bytes(d->funct3);
      if (idx_bytes == 0) { illegal(trap, d); return; }
      break;
    default:
      illegal(trap, d);
      return;
  }

  // 地址预检查: 所有 active 元素都要在 DRAM 内, 否则整条指令不落地
  for (i = 0; i < cpu.vec.vl; i++) {
    uint32_t a;
    if (!elem_active(d, i)) continue;
    a = elem_addr(d, i, (uint32_t)ebytes, idx_bytes);
    if (!range_ok(a, (uint32_t)ebytes)) {
      trap->valid = 1;
      trap->cause = d->is_load ? EXC_LOAD_ACCESS : EXC_STORE_ACCESS;
      trap->tval  = a;
      return;
    }
  }

  if (d->is_load) {
    nreg = (uint32_t)rvv_group_regs();
    rvv_set_dst(d->vd, nreg);
    for (i = 0; i < cpu.vec.vl; i++) {
      uint32_t a, v;
      if (!elem_active(d, i)) continue;
      a = elem_addr(d, i, (uint32_t)ebytes, idx_bytes);
      v = rd_elem(a, (uint32_t)ebytes);
      rvv_elem_put(d->vd, i, (uint32_t)sew, v);
    }
  } else {
    // store: vd 字段是 vs3, 不写 VRF
    rvv_set_dst(d->vd, 0);
    for (i = 0; i < cpu.vec.vl; i++) {
      uint32_t a, v;
      if (!elem_active(d, i)) continue;
      a = elem_addr(d, i, (uint32_t)ebytes, idx_bytes);
      v = rvv_elem_get(d->vd, i, (uint32_t)sew, 0);
      wr_elem(a, (uint32_t)ebytes, v);
    }
  }
}
