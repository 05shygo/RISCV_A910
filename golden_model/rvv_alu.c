// RVV 计算类指令: ALU / MULMAC / 归约 / mask 逻辑 / 扩展 / 窄化
//
// 全部按"每元素循环 + 只写 active 元素"实现, 尾部与被屏蔽元素保持原值
// (本仓 RTL 忽略 ta/ma, 恒为 undisturbed).

#include <cpu.h>
#include <rvv.h>
#include <string.h>

extern riscv32_CPU_state cpu;

// funct6 (与 mySoC/design/inc/rvv_backend_opcode.svh 一致)
#define VADD          0
#define VSUB          2
#define VRSUB         3
#define VMINU         4
#define VMIN          5
#define VMAXU         6
#define VMAX          7
#define VAND          9
#define VOR           10
#define VXOR          11
#define VADC          16
#define VMERGE_VMV    23
#define VMSEQ         24
#define VMSNE         25
#define VMSLTU        26
#define VMSLT         27
#define VMSLEU        28
#define VMSLE         29
#define VMSGTU        30
#define VMSGT         31
#define VSADDU        32
#define VSADD         33
#define VSSUBU        34
#define VSSUB         35
#define VSLL          37
#define VSRL          40
#define VSRA          41
#define VSSRL         42
#define VSSRA         43
#define VNSRL         44
#define VNSRA         45
#define VNCLIPU       46
#define VNCLIP        47

#define VREDSUM       0
#define VREDAND       1
#define VREDOR        2
#define VREDXOR       3
#define VREDMINU      4
#define VREDMIN       5
#define VREDMAXU      6
#define VREDMAX       7

#define VXUNARY0      18
#define VZEXT_VF4_SEL 4
#define VSEXT_VF4_SEL 5
#define VZEXT_VF2_SEL 6
#define VSEXT_VF2_SEL 7

#define VMANDN        24
#define VMAND         25
#define VMOR          26
#define VMXOR         27
#define VMORN         28
#define VMNAND        29
#define VMNOR         30
#define VMXNOR        31

#define VMULHU        36
#define VMUL          37
#define VMULHSU       38
#define VMULH         39
#define VMADD         41
#define VNMSUB        43
#define VMACC         45
#define VNMSAC        47
#define VWREDSUMU     48
#define VWREDSUM      49
#define VWMULU        56
#define VWMULSU       58
#define VWMUL         59
#define VWMACCU       60
#define VWMACC        61
#define VWMACCUS      62
#define VWMACCSU      63

#define RVV_F3_OPIVV  0u
#define RVV_F3_OPMVV  2u
#define RVV_F3_OPIVI  3u
#define RVV_F3_OPIVX  4u
#define RVV_F3_OPMVX  6u

static int32_t sx(uint32_t v, int bits) {
  if (bits >= 32) return (int32_t)v;
  return ((int32_t)(v << (32 - bits))) >> (32 - bits);
}

static uint32_t sew_mask(int sew) {
  return (sew >= 32) ? 0xffffffffu : ((1u << sew) - 1u);
}

static int mask_bit(uint32_t i) {
  return (cpu.vec.vreg[0][i >> 3] >> (i & 7u)) & 1;
}

static int op_active(const rvv_dec_t *d, uint32_t i) {
  if (i >= cpu.vec.vl) return 0;
  if (d->vm) return 1;
  return mask_bit(i);
}

static uint32_t scalar_word(const rvv_dec_t *d) {
  if (d->funct3 == RVV_F3_OPIVX || d->funct3 == RVV_F3_OPMVX)
    return cpu.gpr[d->rs1];
  if (d->funct3 == RVV_F3_OPIVI)
    return (uint32_t)d->imm;
  return 0;
}

// .vv 读 vs1 元素; .vx/.vi 读标量 (不截断, 调用方按需 mask/符号扩展)
static uint32_t src1_word(const rvv_dec_t *d, uint32_t i, int sew, int sign) {
  if (d->funct3 == RVV_F3_OPIVV || d->funct3 == RVV_F3_OPMVV)
    return rvv_elem_get(d->vs1, i, (uint32_t)sew, sign);
  return scalar_word(d);
}

static void illegal(rvv_trap_t *trap, const rvv_dec_t *d) {
  trap->valid = 1;
  trap->cause = EXC_ILLEGAL_INST;
  trap->tval  = d->inst;
}

// ---------------------------------------------------------------------------
// 普通 ALU (逐元素, 目的宽度 = SEW)
// ---------------------------------------------------------------------------
static void alu_element_ops(const rvv_dec_t *d, int sew, uint32_t m,
                            uint32_t (*calc)(const rvv_dec_t *, uint32_t, int,
                                             uint32_t, uint32_t)) {
  uint32_t i;
  rvv_set_dst(d->vd, (uint32_t)rvv_group_regs());
  for (i = 0; i < cpu.vec.vl; i++) {
    uint32_t a, b, val;
    if (!op_active(d, i)) continue;
    a = rvv_elem_get(d->vs2, i, (uint32_t)sew, 0);
    b = src1_word(d, i, sew, 0);
    val = calc(d, i, sew, a, b) & m;
    rvv_elem_put(d->vd, i, (uint32_t)sew, val);
  }
}

static uint32_t calc_add(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i; (void)sew;
  return a + b;
}
static uint32_t calc_sub(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i; (void)sew;
  return a - b;
}
static uint32_t calc_rsub(const rvv_dec_t *d, uint32_t i, int sew,
                          uint32_t a, uint32_t b) {
  (void)d; (void)i; (void)sew;
  return b - a;
}
static uint32_t calc_minu(const rvv_dec_t *d, uint32_t i, int sew,
                          uint32_t a, uint32_t b) {
  uint32_t mm = sew_mask(sew);
  (void)d; (void)i;
  return ((a & mm) < (b & mm)) ? (a & mm) : (b & mm);
}
static uint32_t calc_min(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i;
  return (sx(a, sew) < sx(b, sew)) ? a : b;
}
static uint32_t calc_maxu(const rvv_dec_t *d, uint32_t i, int sew,
                          uint32_t a, uint32_t b) {
  uint32_t mm = sew_mask(sew);
  (void)d; (void)i;
  return ((a & mm) > (b & mm)) ? (a & mm) : (b & mm);
}
static uint32_t calc_max(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i;
  return (sx(a, sew) > sx(b, sew)) ? a : b;
}
static uint32_t calc_and(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i; (void)sew;
  return a & b;
}
static uint32_t calc_or(const rvv_dec_t *d, uint32_t i, int sew,
                        uint32_t a, uint32_t b) {
  (void)d; (void)i; (void)sew;
  return a | b;
}
static uint32_t calc_xor(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i; (void)sew;
  return a ^ b;
}

static uint32_t calc_sll(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i;
  return a << (b & (uint32_t)(sew - 1));
}
static uint32_t calc_srl(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i;
  return (a & sew_mask(sew)) >> (b & (uint32_t)(sew - 1));
}
static uint32_t calc_sra(const rvv_dec_t *d, uint32_t i, int sew,
                         uint32_t a, uint32_t b) {
  (void)d; (void)i;
  return (uint32_t)(sx(a, sew) >> (b & (uint32_t)(sew - 1)));
}
static uint32_t calc_ssrl(const rvv_dec_t *d, uint32_t i, int sew,
                          uint32_t a, uint32_t b) {
  uint32_t sh = b & (uint32_t)(sew - 1);
  uint32_t q;
  (void)d; (void)i;
  a &= sew_mask(sew);
  q = a >> sh;
  if (sh) q += (a >> (sh - 1)) & 1u;         // RNU
  return q;
}
static uint32_t calc_ssra(const rvv_dec_t *d, uint32_t i, int sew,
                          uint32_t a, uint32_t b) {
  uint32_t sh = b & (uint32_t)(sew - 1);
  int32_t s = sx(a, sew);
  int32_t q;
  (void)d; (void)i;
  q = s >> sh;
  if (sh) q += (s >> (sh - 1)) & 1;          // RNU
  return (uint32_t)q;
}

static uint32_t calc_saddu(const rvv_dec_t *d, uint32_t i, int sew,
                           uint32_t a, uint32_t b) {
  uint32_t mm = sew_mask(sew);
  uint64_t r = (uint64_t)(a & mm) + (uint64_t)(b & mm);
  (void)d; (void)i;
  if (r > mm) { r = mm; cpu.vec.vxsat = 1; }
  return (uint32_t)r;
}
static uint32_t calc_sadd(const rvv_dec_t *d, uint32_t i, int sew,
                          uint32_t a, uint32_t b) {
  int64_t r = (int64_t)sx(a, sew) + (int64_t)sx(b, sew);
  int64_t hi = (int64_t)((1ll << (sew - 1)) - 1);
  int64_t lo = -(1ll << (sew - 1));
  (void)d; (void)i;
  if (r > hi) { r = hi; cpu.vec.vxsat = 1; }
  else if (r < lo) { r = lo; cpu.vec.vxsat = 1; }
  return (uint32_t)r & sew_mask(sew);
}
static uint32_t calc_ssubu(const rvv_dec_t *d, uint32_t i, int sew,
                           uint32_t a, uint32_t b) {
  uint32_t mm = sew_mask(sew);
  uint32_t ua = a & mm, ub = b & mm;
  (void)d; (void)i;
  if (ua < ub) { cpu.vec.vxsat = 1; return 0; }
  return ua - ub;
}
static uint32_t calc_ssub(const rvv_dec_t *d, uint32_t i, int sew,
                          uint32_t a, uint32_t b) {
  int64_t r = (int64_t)sx(a, sew) - (int64_t)sx(b, sew);
  int64_t hi = (int64_t)((1ll << (sew - 1)) - 1);
  int64_t lo = -(1ll << (sew - 1));
  (void)d; (void)i;
  if (r > hi) { r = hi; cpu.vec.vxsat = 1; }
  else if (r < lo) { r = lo; cpu.vec.vxsat = 1; }
  return (uint32_t)r & sew_mask(sew);
}

static void alu_simple(const rvv_dec_t *d, int sew, uint32_t m) {
  switch (d->funct6) {
    case VADD:   alu_element_ops(d, sew, m, calc_add);   break;
    case VSUB:   alu_element_ops(d, sew, m, calc_sub);   break;
    case VRSUB:  alu_element_ops(d, sew, m, calc_rsub);  break;
    case VMINU:  alu_element_ops(d, sew, m, calc_minu);  break;
    case VMIN:   alu_element_ops(d, sew, m, calc_min);   break;
    case VMAXU:  alu_element_ops(d, sew, m, calc_maxu);  break;
    case VMAX:   alu_element_ops(d, sew, m, calc_max);   break;
    case VAND:   alu_element_ops(d, sew, m, calc_and);   break;
    case VOR:    alu_element_ops(d, sew, m, calc_or);    break;
    case VXOR:   alu_element_ops(d, sew, m, calc_xor);   break;
    case VSLL:   alu_element_ops(d, sew, m, calc_sll);   break;
    case VSRL:   alu_element_ops(d, sew, m, calc_srl);   break;
    case VSRA:   alu_element_ops(d, sew, m, calc_sra);   break;
    case VSSRL:  alu_element_ops(d, sew, m, calc_ssrl);  break;
    case VSSRA:  alu_element_ops(d, sew, m, calc_ssra);  break;
    case VSADDU: alu_element_ops(d, sew, m, calc_saddu); break;
    case VSADD:  alu_element_ops(d, sew, m, calc_sadd);  break;
    case VSSUBU: alu_element_ops(d, sew, m, calc_ssubu); break;
    case VSSUB:  alu_element_ops(d, sew, m, calc_ssub);  break;
    default: break;
  }
}

// ---------------------------------------------------------------------------
// 比较类: 目的 = mask 寄存器 (每个元素 1 bit)
// ---------------------------------------------------------------------------
static void alu_compare(const rvv_dec_t *d, int sew) {
  uint32_t i, b;
  uint32_t nbytes = (cpu.vec.vl + 7u) / 8u;
  if (nbytes > (uint32_t)RVV_VLENB) nbytes = RVV_VLENB;

  rvv_set_dst(d->vd, 1);
  for (b = 0; b < nbytes; b++) {
    uint32_t byte = 0, bit;
    for (bit = 0; bit < 8; bit++) {
      i = b * 8u + bit;
      if (i < cpu.vec.vl) {
        uint32_t a = rvv_elem_get(d->vs2, i, (uint32_t)sew, 0);
        uint32_t bb = src1_word(d, i, sew, 0);
        int v = 0;
        if (op_active(d, i)) {
          switch (d->funct6) {
            case VMSEQ:  v = (a == (bb & sew_mask(sew))); break;
            case VMSNE:  v = (a != (bb & sew_mask(sew))); break;
            case VMSLTU: v = ((a & sew_mask(sew)) < (bb & sew_mask(sew))); break;
            case VMSLT:  v = (sx(a, sew) < sx(bb, sew)); break;
            case VMSLEU: v = ((a & sew_mask(sew)) <= (bb & sew_mask(sew))); break;
            case VMSLE:  v = (sx(a, sew) <= sx(bb, sew)); break;
            case VMSGTU: v = ((a & sew_mask(sew)) > (bb & sew_mask(sew))); break;
            case VMSGT:  v = (sx(a, sew) > sx(bb, sew)); break;
            default: v = 0; break;
          }
        }
        if (v) byte |= (1u << bit);
      }
    }
    rvv_put_byte(d->vd, b, (uint8_t)byte);
  }
}

// ---------------------------------------------------------------------------
// mask 逻辑 .mm
// ---------------------------------------------------------------------------
static void alu_mask_logic(const rvv_dec_t *d) {
  uint32_t i, b;
  uint32_t nbytes = (cpu.vec.vl + 7u) / 8u;
  if (nbytes > (uint32_t)RVV_VLENB) nbytes = RVV_VLENB;

  rvv_set_dst(d->vd, 1);
  for (b = 0; b < nbytes; b++) {
    uint32_t byte = 0, bit;
    for (bit = 0; bit < 8; bit++) {
      i = b * 8u + bit;
      if (i < cpu.vec.vl) {
        uint32_t a = (cpu.vec.vreg[d->vs2][i >> 3] >> (i & 7u)) & 1u;
        uint32_t c = (cpu.vec.vreg[d->vs1][i >> 3] >> (i & 7u)) & 1u;
        uint32_t v = 0;
        switch (d->funct6) {
          case VMANDN: v = a & ~c; break;
          case VMAND:  v = a & c;  break;
          case VMOR:   v = a | c;  break;
          case VMXOR:  v = a ^ c;  break;
          case VMORN:  v = a | ~c; break;
          case VMNAND: v = ~(a & c); break;
          case VMNOR:  v = ~(a | c); break;
          case VMXNOR: v = ~(a ^ c); break;
          default:     v = 0; break;
        }
        if (v & 1u) byte |= (1u << bit);
      }
    }
    rvv_put_byte(d->vd, b, (uint8_t)byte);
  }
}

// ---------------------------------------------------------------------------
// vmv / vmerge
// ---------------------------------------------------------------------------
static void alu_vmv_merge(const rvv_dec_t *d, int sew, uint32_t m) {
  uint32_t i;
  rvv_set_dst(d->vd, (uint32_t)rvv_group_regs());
  if (d->vm) {
    // vmv.v.v / vmv.v.x / vmv.v.i
    for (i = 0; i < cpu.vec.vl; i++) {
      uint32_t val = src1_word(d, i, sew, 0) & m;
      rvv_elem_put(d->vd, i, (uint32_t)sew, val);
    }
  } else {
    // vmerge: mask=1 -> vs1(scalar/imm), mask=0 -> vs2
    // (按黄金值确认: `vmerge.vvm vd, vs2, vs1, v0` 的 mask=1 选第三操作数)
    for (i = 0; i < cpu.vec.vl; i++) {
      uint32_t val = mask_bit(i) ? src1_word(d, i, sew, 0)
                                 : rvv_elem_get(d->vs2, i, (uint32_t)sew, 0);
      rvv_elem_put(d->vd, i, (uint32_t)sew, val & m);
    }
  }
}

// ---------------------------------------------------------------------------
// vadc: v0 提供进位, 写所有 i<vl
// ---------------------------------------------------------------------------
static void alu_vadc(const rvv_dec_t *d, int sew, uint32_t m) {
  uint32_t i;
  rvv_set_dst(d->vd, (uint32_t)rvv_group_regs());
  for (i = 0; i < cpu.vec.vl; i++) {
    uint32_t a = rvv_elem_get(d->vs2, i, (uint32_t)sew, 0);
    uint32_t b = src1_word(d, i, sew, 0);
    uint32_t c = (uint32_t)mask_bit(i);
    rvv_elem_put(d->vd, i, (uint32_t)sew, (a + b + c) & m);
  }
}

// ---------------------------------------------------------------------------
// 扩展 vzext/vsext .vf2/.vf4
// ---------------------------------------------------------------------------
static void alu_extend(const rvv_dec_t *d, int sew, rvv_trap_t *trap) {
  int mult, sign, dest_eew;
  uint32_t i;

  switch (d->rs1) {
    case VZEXT_VF2_SEL: mult = 2; sign = 0; break;
    case VSEXT_VF2_SEL: mult = 2; sign = 1; break;
    case VZEXT_VF4_SEL: mult = 4; sign = 0; break;
    case VSEXT_VF4_SEL: mult = 4; sign = 1; break;
    default: illegal(trap, d); return;
  }
  dest_eew = mult * sew;
  if (dest_eew > 32) { illegal(trap, d); return; }

  rvv_set_dst(d->vd, (uint32_t)rvv_group_regs_mult(mult));
  for (i = 0; i < cpu.vec.vl; i++) {
    uint32_t val;
    if (!op_active(d, i)) continue;
    val = rvv_elem_get(d->vs2, i, (uint32_t)sew, sign);
    rvv_elem_put(d->vd, i, (uint32_t)dest_eew, val);
  }
}

// ---------------------------------------------------------------------------
// 窄化 vnsrl/vnsra/vnclip/vnclipu
// ---------------------------------------------------------------------------
static void alu_narrow(const rvv_dec_t *d, int sew, rvv_trap_t *trap) {
  int src_eew = 2 * sew;
  uint32_t m = sew_mask(sew);
  uint32_t srcm;
  uint32_t i;

  if (src_eew > 32) { illegal(trap, d); return; }
  srcm = sew_mask(src_eew);

  rvv_set_dst(d->vd, (uint32_t)rvv_group_regs());
  for (i = 0; i < cpu.vec.vl; i++) {
    uint32_t sh, src, val;
    if (!op_active(d, i)) continue;
    src = rvv_elem_get(d->vs2, i, (uint32_t)src_eew, 0);
    if (d->funct3 == RVV_F3_OPIVV)
      sh = rvv_elem_get(d->vs1, i, (uint32_t)sew, 0) & (uint32_t)(src_eew - 1);
    else
      sh = src1_word(d, i, sew, 0) & (uint32_t)(src_eew - 1);

    switch (d->funct6) {
      case VNSRL:
        val = (src & srcm) >> sh;
        break;
      case VNSRA:
        val = (uint32_t)(sx(src, src_eew) >> sh);
        break;
      case VNCLIPU: {
        uint32_t q = (src & srcm) >> sh;
        if (sh) q += ((src & srcm) >> (sh - 1)) & 1u;
        if (q > m) { q = m; cpu.vec.vxsat = 1; }
        val = q;
        break;
      }
      case VNCLIP: {
        int64_t q = (int64_t)(sx(src, src_eew) >> sh);
        int64_t hi = (int64_t)((1ll << (sew - 1)) - 1);
        int64_t lo = -(1ll << (sew - 1));
        if (sh) q += (sx(src, src_eew) >> (sh - 1)) & 1;
        if (q > hi) { q = hi; cpu.vec.vxsat = 1; }
        else if (q < lo) { q = lo; cpu.vec.vxsat = 1; }
        val = (uint32_t)q & m;
        break;
      }
      default:
        val = 0;
        break;
    }
    rvv_elem_put(d->vd, i, (uint32_t)sew, val);
  }
}

// ---------------------------------------------------------------------------
// MUL / MAC (含加宽)
// ---------------------------------------------------------------------------
static void alu_mulmac(const rvv_dec_t *d, int sew, rvv_trap_t *trap) {
  uint32_t i;
  int widen = 0;

  switch (d->funct6) {
    case VWMULU: case VWMULSU: case VWMUL:
    case VWMACCU: case VWMACC: case VWMACCUS: case VWMACCSU:
      widen = 1;
      break;
    default:
      break;
  }

  if (widen) {
    int dest_eew = 2 * sew;
    uint64_t dm;
    if (dest_eew > 32) { illegal(trap, d); return; }
    dm = (dest_eew >= 32) ? 0xffffffffull : ((1ull << dest_eew) - 1ull);
    rvv_set_dst(d->vd, (uint32_t)rvv_group_regs_mult(2));
    for (i = 0; i < cpu.vec.vl; i++) {
      uint32_t a, b, prod, acc;
      uint64_t v64;
      if (!op_active(d, i)) continue;
      a = rvv_elem_get(d->vs2, i, (uint32_t)sew, 0);
      b = src1_word(d, i, sew, 0);
      switch (d->funct6) {
        case VWMULU:
          v64 = (uint64_t)(a & sew_mask(sew)) * (uint64_t)(b & sew_mask(sew));
          prod = (uint32_t)(v64 & dm);
          rvv_elem_put(d->vd, i, (uint32_t)dest_eew, prod);
          break;
        case VWMUL:
          v64 = (uint64_t)((int64_t)sx(a, sew) * (int64_t)sx(b, sew));
          prod = (uint32_t)(v64 & dm);
          rvv_elem_put(d->vd, i, (uint32_t)dest_eew, prod);
          break;
        case VWMULSU:
          v64 = (uint64_t)((int64_t)sx(a, sew) * (uint64_t)(b & sew_mask(sew)));
          prod = (uint32_t)(v64 & dm);
          rvv_elem_put(d->vd, i, (uint32_t)dest_eew, prod);
          break;
        case VWMACCU:
          v64 = (uint64_t)(a & sew_mask(sew)) * (uint64_t)(b & sew_mask(sew));
          acc = rvv_elem_get(d->vd, i, (uint32_t)dest_eew, 0);
          rvv_elem_put(d->vd, i, (uint32_t)dest_eew,
                       (uint32_t)(((uint64_t)acc + v64) & dm));
          break;
        case VWMACC:
          v64 = (uint64_t)((int64_t)sx(a, sew) * (int64_t)sx(b, sew));
          acc = rvv_elem_get(d->vd, i, (uint32_t)dest_eew, 0);
          rvv_elem_put(d->vd, i, (uint32_t)dest_eew,
                       (uint32_t)(((uint64_t)acc + v64) & dm));
          break;
        case VWMACCSU:
          // RTL: vs2 unsigned, vs1 signed
          v64 = (uint64_t)((int64_t)sx(b, sew) * (uint64_t)(a & sew_mask(sew)));
          acc = rvv_elem_get(d->vd, i, (uint32_t)dest_eew, 0);
          rvv_elem_put(d->vd, i, (uint32_t)dest_eew,
                       (uint32_t)(((uint64_t)acc + v64) & dm));
          break;
        case VWMACCUS:
          // RTL: vs2 signed, vs1 unsigned
          v64 = (uint64_t)((int64_t)sx(a, sew) * (uint64_t)(b & sew_mask(sew)));
          acc = rvv_elem_get(d->vd, i, (uint32_t)dest_eew, 0);
          rvv_elem_put(d->vd, i, (uint32_t)dest_eew,
                       (uint32_t)(((uint64_t)acc + v64) & dm));
          break;
        default:
          break;
      }
    }
    return;
  }

  rvv_set_dst(d->vd, (uint32_t)rvv_group_regs());
  for (i = 0; i < cpu.vec.vl; i++) {
    uint32_t a, b, val;
    if (!op_active(d, i)) continue;
    a = rvv_elem_get(d->vs2, i, (uint32_t)sew, 0);
    b = src1_word(d, i, sew, 0);
    switch (d->funct6) {
      case VMUL:
        val = (uint32_t)((uint64_t)a * (uint64_t)(b & sew_mask(sew)));
        break;
      case VMULHU:
        val = (uint32_t)(((uint64_t)(a & sew_mask(sew)) *
                          (uint64_t)(b & sew_mask(sew))) >> sew);
        break;
      case VMULH:
        val = (uint32_t)((uint64_t)((int64_t)sx(a, sew) *
                                    (int64_t)sx(b, sew)) >> sew);
        break;
      case VMULHSU:
        val = (uint32_t)((uint64_t)((int64_t)sx(a, sew) *
                                    (uint64_t)(b & sew_mask(sew))) >> sew);
        break;
      case VMACC:
        val = rvv_elem_get(d->vd, i, (uint32_t)sew, 0)
            + (uint32_t)((uint64_t)a * (uint64_t)(b & sew_mask(sew)));
        break;
      case VNMSAC:
        val = rvv_elem_get(d->vd, i, (uint32_t)sew, 0)
            - (uint32_t)((uint64_t)a * (uint64_t)(b & sew_mask(sew)));
        break;
      case VMADD:
        val = (uint32_t)((uint64_t)rvv_elem_get(d->vd, i, (uint32_t)sew, 0)
                         * (uint64_t)(b & sew_mask(sew))) + a;
        break;
      case VNMSUB:
        val = a - (uint32_t)((uint64_t)rvv_elem_get(d->vd, i, (uint32_t)sew, 0)
                             * (uint64_t)(b & sew_mask(sew)));
        break;
      default:
        val = 0;
        break;
    }
    rvv_elem_put(d->vd, i, (uint32_t)sew, val & sew_mask(sew));
  }
}

// ---------------------------------------------------------------------------
// 归约
// ---------------------------------------------------------------------------
static void alu_reduce(const rvv_dec_t *d, int sew, rvv_trap_t *trap) {
  uint32_t i;

  if (d->funct6 == VWREDSUMU || d->funct6 == VWREDSUM) {
    int dest_eew = 2 * sew;
    int sign = (d->funct6 == VWREDSUM);
    uint64_t acc;
    uint64_t dm;
    if (dest_eew > 32) { illegal(trap, d); return; }
    dm = (dest_eew >= 32) ? 0xffffffffull : ((1ull << dest_eew) - 1ull);
    acc = (uint64_t)rvv_elem_get(d->vs1, 0, (uint32_t)dest_eew, sign) & dm;
    for (i = 0; i < cpu.vec.vl; i++) {
      uint32_t v;
      if (!op_active(d, i)) continue;
      v = rvv_elem_get(d->vs2, i, (uint32_t)sew, sign);
      acc = (acc + (uint64_t)v) & dm;
    }
    rvv_set_dst(d->vd, (uint32_t)rvv_group_regs_mult(2));
    rvv_elem_put(d->vd, 0, (uint32_t)dest_eew, (uint32_t)acc);
    return;
  }

  {
    int sign = (d->funct6 == VREDMIN || d->funct6 == VREDMAX ||
                d->funct6 == VREDSUM);
    int32_t sacc = sx(rvv_elem_get(d->vs1, 0, (uint32_t)sew, 1), sew);
    uint32_t uacc = rvv_elem_get(d->vs1, 0, (uint32_t)sew, 0) & sew_mask(sew);
    for (i = 0; i < cpu.vec.vl; i++) {
      uint32_t v;
      if (!op_active(d, i)) continue;
      v = rvv_elem_get(d->vs2, i, (uint32_t)sew, sign);
      switch (d->funct6) {
        case VREDSUM:  sacc = (int32_t)((uint32_t)sacc + (uint32_t)v); break;
        case VREDAND:  uacc &= v & sew_mask(sew); break;
        case VREDOR:   uacc |= v & sew_mask(sew); break;
        case VREDXOR:  uacc ^= v & sew_mask(sew); break;
        case VREDMINU: if ((v & sew_mask(sew)) < uacc) uacc = v & sew_mask(sew); break;
        case VREDMAXU: if ((v & sew_mask(sew)) > uacc) uacc = v & sew_mask(sew); break;
        case VREDMIN:  if (sx(v, sew) < sacc) sacc = sx(v, sew); break;
        case VREDMAX:  if (sx(v, sew) > sacc) sacc = sx(v, sew); break;
        default: break;
      }
    }
    rvv_set_dst(d->vd, (uint32_t)rvv_group_regs());
    rvv_elem_put(d->vd, 0, (uint32_t)sew,
                 (sign ? (uint32_t)sacc : uacc) & sew_mask(sew));
  }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
void rvv_alu_exec(const rvv_dec_t *d, rvv_trap_t *trap) {
  int sew = rvv_sew_bits();
  uint32_t m = sew_mask(sew);
  uint32_t f3 = d->funct3;
  uint32_t f6 = d->funct6;

  if (f3 == RVV_F3_OPIVV || f3 == RVV_F3_OPIVI || f3 == RVV_F3_OPIVX) {
    switch (f6) {
      case VADD: case VSUB: case VRSUB:
      case VMINU: case VMIN: case VMAXU: case VMAX:
      case VAND: case VOR: case VXOR:
      case VSLL: case VSRL: case VSRA: case VSSRL: case VSSRA:
      case VSADDU: case VSADD: case VSSUBU: case VSSUB:
        alu_simple(d, sew, m);
        return;
      case VADC:
        alu_vadc(d, sew, m);
        return;
      case VMERGE_VMV:
        alu_vmv_merge(d, sew, m);
        return;
      case VMSEQ: case VMSNE:
      case VMSLTU: case VMSLT: case VMSLEU: case VMSLE:
      case VMSGTU: case VMSGT:
        alu_compare(d, sew);
        return;
      case VNSRL: case VNSRA: case VNCLIPU: case VNCLIP:
        alu_narrow(d, sew, trap);
        return;
      case VWREDSUMU: case VWREDSUM:      // 这两条是 OPIVV 编码, 不是 OPMVV
        alu_reduce(d, sew, trap);
        return;
      default:
        illegal(trap, d);
        return;
    }
  }

  if (f3 == RVV_F3_OPMVV || f3 == RVV_F3_OPMVX) {
    switch (f6) {
      case VREDSUM: case VREDAND: case VREDOR: case VREDXOR:
      case VREDMINU: case VREDMIN: case VREDMAXU: case VREDMAX:
      case VWREDSUMU: case VWREDSUM:
        if (f3 != RVV_F3_OPMVV) { illegal(trap, d); return; }
        alu_reduce(d, sew, trap);
        return;
      case VXUNARY0:
        if (f3 != RVV_F3_OPMVV) { illegal(trap, d); return; }
        alu_extend(d, sew, trap);
        return;
      case VMANDN: case VMAND: case VMOR: case VMXOR:
      case VMORN: case VMNAND: case VMNOR: case VMXNOR:
        alu_mask_logic(d);
        return;
      case VMULHU: case VMUL: case VMULHSU: case VMULH:
      case VMADD: case VNMSUB: case VMACC: case VNMSAC:
      case VWMULU: case VWMULSU: case VWMUL:
      case VWMACCU: case VWMACC: case VWMACCUS: case VWMACCSU:
        alu_mulmac(d, sew, trap);
        return;
      default:
        illegal(trap, d);
        return;
    }
  }

  // OPF* / 其它: 本仓没有浮点向量
  illegal(trap, d);
}
