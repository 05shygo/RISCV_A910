#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tests/rvv/catalog.py —— RVV 逐指令用例目录

范围严格按 doc/v-instruction.md:
  * MULMAC 15 条
  * ALU    35 条
  * PMTRDT  6 条
  * LSU    18 条 (文档标题写 12, 实际列了 18)
  * mask    8 条 (文档标题写 3, 实际列了 8)
另外 vsetvli/vsetivli 只作为每条用例的前缀和基础设施自检, 不作为被测指令。

用例约定 (与 gen_sweep.py 配合):
  * 标量寄存器: a0 = 失败计数 (TB 的 PASS 判据), a1 = .vx 的标量源,
    t0..t6 = 临时; 不要用其它标量寄存器。
  * 向量寄存器: v1 = vs2, v2 = vs1, v3/v4 = 宽 vs1, v5 = vd,
    v6..v8 = 宽目的组的后续寄存器, v0 = mask/carry。
  * 每条用例在执行前把 "全 16B" 的 vd 组预置成 0x05 (tu/mu, 见 gen_sweep.py),
    保证 tail / 被屏蔽元素是确定的、能逐字节和 Spike 对拍。
  * 结果观察: vreg 类把 vd 组用 vse32 落到 rvv_res; store 类直接检查 rvv_mem。
"""

SEW_VL = {8: 16, 16: 8, 32: 4}


class Case:
    """一条被测指令的完整描述。

    setup       : 列表, 进入被测指令前的汇编 (必须含本用例的 vsetvli + 源装载)
    inst        : 被测指令
    dests       : 需要 dump 的目的寄存器 (宽目的组可能有多个)
    res_bytes   : vreg 类检查多少字节 (4 的倍数)
    mem_bytes   : >0 表示 store 类, 检查 rvv_mem 里的目标区
    mask        : 需要先把 rvv_mask 装进 v0 (vm=0 / vmerge / vadc)
    pre_init    : 需要预置的寄存器 (默认 = dests; store 类填 [5])
    """

    __slots__ = ("group", "name", "setup", "inst", "dests", "res_bytes",
                 "mem_bytes", "mask", "pre_init", "manual")

    def __init__(self, group, name, setup, inst, dests=(5,), res_bytes=16,
                 mem_bytes=0, mask=False, pre_init=None, manual=None):
        self.group = group
        self.name = name
        self.setup = list(setup)
        self.inst = inst
        self.dests = tuple(dests)
        self.res_bytes = res_bytes
        self.mem_bytes = mem_bytes
        self.mask = mask
        self.pre_init = tuple(pre_init) if pre_init is not None else (
            tuple(dests) if not mem_bytes else (5,))
        self.manual = manual


# ---------------------------------------------------------------------------
# 汇编小工具
# ---------------------------------------------------------------------------
def vs(sew, lmul="m1", vl=None):
    if vl is None:
        vl = SEW_VL[sew]
    return "vsetivli x0, %d, e%d, %s, tu, mu" % (vl, sew, lmul)


def ldv(sew, reg, label):
    return ["la t1, %s" % label, "vle%d.v %s, (t1)" % (sew, reg)]


def src_setup(sew, a="v1", b="v2", vl=None):
    """载入 vs2 / vs1。vle 的 SEW = 用例 SEW。"""
    out = [vs(sew, "m1", vl)]
    out += ldv(sew, a, "rvv_in_a%d" % sew)
    out += ldv(sew, b, "rvv_in_b%d" % sew)
    return out


def inst_of(mnem, form, vd=5):
    """生成常见 .vv/.vx/.vi 形态的指令文本。"""
    if form == "vv":
        return "%s.vv v%d, v1, v2" % (mnem, vd)
    if form == "vx":
        return "%s.vx v%d, v1, a1" % (mnem, vd)
    if form == "vi":
        return "%s.vi v%d, v1, 3" % (mnem, vd)
    raise ValueError(form)


# ---------------------------------------------------------------------------
# ALU (doc §3.2, 35 条)
# ---------------------------------------------------------------------------
ALU_FORMS = {
    "vadd":  ["vv", "vx", "vi"],
    "vsub":  ["vv", "vx"],
    "vrsub": ["vx", "vi"],
    "vadc":  ["vvm", "vxm", "vim"],
    "vmax":  ["vv", "vx"],
    "vmaxu": ["vv", "vx"],
    "vmin":  ["vv", "vx"],
    "vminu": ["vv", "vx"],
    "vmseq": ["vv", "vx", "vi"],
    "vmsne": ["vv", "vx", "vi"],
    "vmslt": ["vv", "vx"],
    "vmsltu": ["vv", "vx"],
    "vmsle": ["vv", "vx", "vi"],
    "vmsleu": ["vv", "vx", "vi"],
    "vand":  ["vv", "vx", "vi"],
    "vor":   ["vv", "vx", "vi"],
    "vxor":  ["vv", "vx", "vi"],
    "vsll":  ["vv", "vx", "vi"],
    "vsrl":  ["vv", "vx", "vi"],
    "vsra":  ["vv", "vx", "vi"],
    "vssrl": ["vv", "vx", "vi"],
    "vssra": ["vv", "vx", "vi"],
    "vsaddu": ["vv", "vx", "vi"],
    "vsadd":  ["vv", "vx", "vi"],
    "vssubu": ["vv", "vx"],
    "vssub":  ["vv", "vx"],
}


def alu_cases():
    out = []
    g = "alu"
    # ---- 普通 vv/vx/vi ----
    for m, forms in ALU_FORMS.items():
        for f in forms:
            if m == "vadc":
                # vadc 没有 vm 字段, v0 是进位输入
                inst = {"vvm": "vadc.vvm v5, v1, v2, v0",
                        "vxm": "vadc.vxm v5, v1, a1, v0",
                        "vim": "vadc.vim v5, v1, 3, v0"}[f]
                out.append(Case(g, "%s.%s e32" % (m, f), src_setup(32),
                                inst, mask=True))
            elif m in ("vssubu", "vssub") or (m in ("vssrl", "vssra") and f == "vv"):
                out.append(Case(g, "%s.%s e32" % (m, f),
                                src_setup(32) + (["li a1, 3"] if f == "vx" else []),
                                inst_of(m, f)))
            else:
                out.append(Case(g, "%s.%s e32" % (m, f),
                                src_setup(32) + (["li a1, 3"] if f == "vx" else []),
                                inst_of(m, f)))

    # ---- 饱和/移位补 e8/e16 变体 ----
    for m in ("vsadd", "vssub", "vsll", "vsra", "vssrl", "vssra"):
        for sew in (8, 16):
            out.append(Case(g, "%s.vv e%d" % (m, sew), src_setup(sew),
                            "%s.vv v5, v1, v2" % m))

    # ---- vmv (3 形态) ----
    out.append(Case(g, "vmv.v.v e32", src_setup(32), "vmv.v.v v5, v1"))
    out.append(Case(g, "vmv.v.x e32", [vs(32), "li a1, 3"], "vmv.v.x v5, a1"))
    out.append(Case(g, "vmv.v.i e32", [vs(32)], "vmv.v.i v5, 3"))

    # ---- vmerge (3 形态, vm=0 用 v0) ----
    out.append(Case(g, "vmerge.vvm e32", src_setup(32),
                    "vmerge.vvm v5, v1, v2, v0", mask=True))
    out.append(Case(g, "vmerge.vxm e32", src_setup(32) + ["li a1, 3"],
                    "vmerge.vxm v5, v1, a1, v0", mask=True))
    out.append(Case(g, "vmerge.vim e32", src_setup(32),
                    "vmerge.vim v5, v1, 3, v0", mask=True))

    # ---- 类型转换 (vf2: e8->e16, vf4: e8->e32) ----
    for m in ("vsext", "vzext"):
        for vf in (2, 4):
            # 宽目的组必须按 EMUL 对齐: vf2 -> v6/v7, vf4 -> v4..v7
            if vf == 2:
                nb, dests, vd = 32, (6, 7), 6
            else:
                nb, dests, vd = 64, (4, 5, 6, 7), 4
            out.append(Case(g, "%s.vf%d e8" % (m, vf),
                            [vs(8)] + ldv(8, "v1", "rvv_in_a8"),
                            "%s.vf%d v%d, v1" % (m, vf, vd),
                            dests=dests, res_bytes=nb,
                            # Spike 这个 build 对 SEW=8 的 v*ext 一律报 illegal
                            # (e16/e32 正常) ⇒ 这 4 条的黄金值用 Python 直接算
                            manual=("sext" if m == "vsext" else "zext", vf)))

    # ---- 窄化移位/饱和 (源 e16 -> 目 e8; 另补 e32->e16) ----
    # ⚠️ 窄化指令的源 EMUL = 2*LMUL ⇒ vs2/vs1 必须是 **偶数寄存器**。
    #    用 vs2=v2, vs1=v4, vd=v6 (v1/v5 会 illegal, Spike/ISA 都会拒)。
    def narrow_setup(sew, vl):
        s = [vs(sew, vl=vl)]
        s += ldv(sew, "v2", "rvv_in_a%d" % sew)
        s += ldv(sew, "v4", "rvv_in_b%d" % sew)
        return s

    for m in ("vnclip", "vnclipu"):
        for f in ("vv", "vx", "vi"):
            inst = {"vv": "%s.wv v6, v2, v4" % m,
                    "vx": "%s.wx v6, v2, a1" % m,
                    "vi": "%s.wi v6, v2, 3" % m}[f]
            out.append(Case(g, "%s.%s e16" % (m, f),
                            narrow_setup(16, 8) +
                            (["li a1, 3"] if f == "vx" else []),
                            inst, dests=(6,)))
    for f in ("vv", "vx", "vi"):
        inst = {"vv": "vnsrl.wv v6, v2, v4",
                "vx": "vnsrl.wx v6, v2, a1",
                "vi": "vnsrl.wi v6, v2, 3"}[f]
        out.append(Case(g, "vnsrl.%s e16" % f,
                        narrow_setup(16, 8) +
                        (["li a1, 3"] if f == "vx" else []),
                        inst, dests=(6,)))
    # ⚠️ 2026-10-18 修: 窄化指令的 vtype.SEW 是**目的**位宽, 原用例写
    #    narrow_setup(32,4) 实际是 "源 e64 → 目的 e32", 需要 EEW64 (后端不支持),
    #    Spike 能跑但 DUT 判 illegal ⇒ trap。e32→e16 的正确写法是 vtype e16
    #    (上面 vnclip.{vv,vx,vi} e16 已经覆盖)。这里补 e8→e16 的变体。
    out.append(Case(g, "vnclip.vv e8",
                    narrow_setup(8, 16), "vnclip.wv v6, v2, v4",
                    dests=(6,)))
    return out


# ---------------------------------------------------------------------------
# MULMAC (doc §3.1, 15 条)
# ---------------------------------------------------------------------------
def mulmac_cases():
    out = []
    g = "mulmac"

    def acc_setup(sew, vl):
        # vd (v5) 参与运算, 用真实数据预置
        s = [vs(sew)]
        s += ldv(sew, "v1", "rvv_in_a%d" % sew)
        s += ldv(sew, "v2", "rvv_in_b%d" % sew)
        s += ldv(sew, "v5", "rvv_in_c%d" % sew)
        return s

    # ---- 基础乘 / 高位乘 ----
    for m in ("vmul", "vmulhu", "vmulh", "vmulhsu"):
        for f in ("vv", "vx"):
            out.append(Case(g, "%s.%s e32" % (m, f),
                            src_setup(32) + (["li a1, 3"] if f == "vx" else []),
                            inst_of(m, f)))
    for sew in (8, 16):
        out.append(Case(g, "vmul.vv e%d" % sew, src_setup(sew),
                        "vmul.vv v5, v1, v2"))

    # ---- 乘累加 ----
    # ⚠️ MAC 的 .vx 汇编语法是 `vd, rs1, vs2` (标量在前), 与 vadd.vx 相反
    for m in ("vmacc", "vmadd", "vnmsac", "vnmsub"):
        for f in ("vv", "vx"):
            inst = ("%s.vv v5, v1, v2" % m) if f == "vv" else \
                   ("%s.vx v5, a1, v1" % m)
            out.append(Case(g, "%s.%s e32" % (m, f),
                            acc_setup(32, 4) +
                            (["li a1, 3"] if f == "vx" else []),
                            inst))

    # ---- 宽位乘 (e8 -> e16, 目的 2 个寄存器) ----
    for m in ("vwmulu", "vwmul", "vwmulsu"):
        for f in ("vv", "vx"):
            out.append(Case(g, "%s.%s e8" % (m, f),
                            src_setup(8) + (["li a1, 3"] if f == "vx" else []),
                            inst_of(m, f, vd=6), dests=(6, 7), res_bytes=32))
    # 补一条 e16 -> e32
    out.append(Case(g, "vwmul.vv e16", src_setup(16),
                    "vwmul.vv v6, v1, v2", dests=(6, 7), res_bytes=32))

    # ---- 宽位乘累加 (e8 -> e16; vd 是宽组 v6/v7, vs1/vs2 都是窄向量) ----
    #   ⚠️ vwmaccus.vv 在这个 binutils (2.43) 里没有助记符 (vwmaccus.vx 有),
    #      所以只测 .vx; 其余三种测 .vv/.vx。
    for m in ("vwmaccu", "vwmacc", "vwmaccsu", "vwmaccus"):
        forms = ("vv", "vx") if m != "vwmaccus" else ("vx",)
        for f in forms:
            s = [vs(8)]
            s += ldv(8, "v1", "rvv_in_a8")
            s += ldv(8, "v2", "rvv_in_b8")
            # 宽累加器 vd = v6/v7 (偶数对齐)
            s += ["vsetivli x0, 8, e16, m1, tu, mu"]
            s += ldv(16, "v6", "rvv_in_c16")
            s += ["la t1, rvv_in_c16+16", "vle16.v v7, (t1)"]
            s += [vs(8)]
            if f == "vx":
                s += ["li a1, 3"]
            # MAC 的 .vx: 标量在前 (vs1=rs1, vs2=向量)
            inst = ("%s.vv v6, v1, v2" % m) if f == "vv" else \
                   ("%s.vx v6, a1, v1" % m)
            out.append(Case(g, "%s.%s e8" % (m, f), s, inst,
                            dests=(6, 7), res_bytes=32))
    return out


# ---------------------------------------------------------------------------
# PMTRDT (doc §3.3, 6 条)
# ---------------------------------------------------------------------------
def red_cases():
    out = []
    g = "red"
    for m in ("vredsum", "vredmax", "vredmaxu", "vredmin", "vredminu"):
        out.append(Case(g, "%s.vs e32" % m, src_setup(32),
                        "%s.vs v5, v1, v2" % m))
    # vwredsum: 源 e8 -> 种子/目的 e16
    s = [vs(16)]
    s += ldv(16, "v2", "rvv_in_b16")     # 宽种子 vs1
    s += [vs(8)]
    s += ldv(8, "v1", "rvv_in_a8")
    out.append(Case(g, "vwredsum.vs e8", s, "vwredsum.vs v5, v1, v2"))
    return out


# ---------------------------------------------------------------------------
# mask 逻辑 (doc §3.5, 8 条)
# ---------------------------------------------------------------------------
def mask_cases():
    out = []
    g = "mask"
    for m, asm in (("vmandn", "vmandn"), ("vmand", "vmand"),
                   ("vmor", "vmor"), ("vmxor", "vmxor"),
                   ("vmorn", "vmorn"), ("vmnand", "vmnand"),
                   ("vmnor", "vmnor"), ("vmxnor", "vmxnor")):
        s = [vs(8)]
        s += ldv(8, "v1", "rvv_mask_a")
        s += ldv(8, "v2", "rvv_mask_b")
        out.append(Case(g, "%s.mm" % m, s, "%s.mm v5, v1, v2" % asm))
    return out


# ---------------------------------------------------------------------------
# LSU (doc §3.4, 18 条)
# ---------------------------------------------------------------------------
def ls_cases():
    out = []
    g = "ls"

    # ---- unit-stride load ----
    # dcache HIT 路径: 先标量 store 把行写进 dcache, 隔几条再 vle32 (命中)
    hit = ["li t0, 0x12345678", "la t2, rvv_hitbuf", "sw t0, 0(t2)"]
    hit += ["addi x0, x0, 0"] * 8
    hit += [vs(32), "la t1, rvv_hitbuf"]
    out.append(Case(g, "vle32.v dcache-hit", hit, "vle32.v v5, (t1)"))
    # SQ data-discard: 标量 load 未回 → sw 数据还不到 → vle 撞上这条 SQ 表项
    # (DA 不再立刻 restart, 由 SQ 表项 data_set 时用 fill_id 唤醒)
    s = ["la t2, rvv_ls_src", "lw t4, 0(t2)",
         "la t3, rvv_hitbuf", "sw t4, 0(t3)",
         vs(32), "la t1, rvv_hitbuf"]
    out.append(Case(g, "vle32.v sq-data-discard", s, "vle32.v v5, (t1)"))
    # LFB conflict: 标量 load miss 建 LFB → vle 同一行撞 LFB
    # (记录 fill_id, linefill 数据回来后再唤醒)
    s = ["la t2, rvv_ls_src", "lw t4, 0(t2)", vs(32)]
    out.append(Case(g, "vle32.v lfb-conflict", s, "vle32.v v5, (t2)"))
    for sew in (8, 16, 32):
        out.append(Case(g, "vle%d.v unit" % sew,
                        [vs(sew)] + ldv(sew, "v5", "rvv_ls_src"),
                        "vle%d.v v5, (t1)" % sew))
    # 未对齐基址 / 跨 16B 边界
    s = [vs(32), "la t1, rvv_ls_src+4"]
    out.append(Case(g, "vle32.v unaligned+4", s, "vle32.v v5, (t1)"))
    s = [vs(16), "la t1, rvv_ls_src+12"]
    out.append(Case(g, "vle16.v cross16B", s, "vle16.v v5, (t1)"))
    # VL=1
    s = [vs(32, vl=1)] + ldv(32, "v5", "rvv_ls_src")
    out.append(Case(g, "vle32.v VL=1", s, "vle32.v v5, (t1)"))

    # ---- unit-stride store ----
    for sew in (8, 16, 32):
        s = [vs(sew)] + ldv(sew, "v5", "rvv_ls_src")
        s += ["la t1, RVVMEM"]
        out.append(Case(g, "vse%d.v unit" % sew, s,
                        "vse%d.v v5, (t1)" % sew,
                        dests=(), mem_bytes=64))
    # 未对齐 store 基址
    s = [vs(16)] + ldv(16, "v5", "rvv_ls_src")
    s += ["la t1, RVVMEM+2"]
    out.append(Case(g, "vse16.v unaligned+2", s, "vse16.v v5, (t1)",
                    dests=(), mem_bytes=64))

    # ---- strided ----
    for sew in (8, 16, 32):
        # 正步长 4
        s = [vs(sew)]
        s += ldv(sew, "v5", "rvv_ls_src")     # 先占位 (load 会覆盖)
        s += ["la t1, rvv_ls_src", "li a1, 4"]
        out.append(Case(g, "vlse%d.v +4" % sew, s,
                        "vlse%d.v v5, (t1), a1" % sew))
        # 负步长: 基址挪到最后一个元素
        last = (SEW_VL[sew] - 1) * 4
        s = [vs(sew), "la t1, rvv_ls_src+%d" % last, "li a1, -4"]
        out.append(Case(g, "vlse%d.v -4" % sew, s,
                        "vlse%d.v v5, (t1), a1" % sew))
        # store +4
        s = [vs(sew)] + ldv(sew, "v5", "rvv_ls_src")
        s += ["la t1, RVVMEM", "li a1, 4"]
        out.append(Case(g, "vsse%d.v +4" % sew, s,
                        "vsse%d.v v5, (t1), a1" % sew,
                        dests=(), mem_bytes=64))
        # store 0 步长
        s = [vs(sew)] + ldv(sew, "v5", "rvv_ls_src")
        s += ["la t1, RVVMEM", "li a1, 0"]
        out.append(Case(g, "vsse%d.v 0" % sew, s,
                        "vsse%d.v v5, (t1), a1" % sew,
                        dests=(), mem_bytes=64))

    # ---- indexed (unordered) ----
    for sew in (8, 16, 32):
        # 索引向量的 EEW = sew
        idx = "rvv_idx%d" % sew
        s = [vs(sew)] + ldv(sew, "v1", idx)   # 索引
        s += ["la t1, rvv_ls_src"]
        out.append(Case(g, "vluxei%d.v" % sew, s,
                        "vluxei%d.v v5, (t1), v1" % sew))
        # store
        s = [vs(sew)] + ldv(sew, "v1", idx)
        s += [vs(sew)] + ldv(sew, "v5", "rvv_ls_src")
        s += ["la t1, RVVMEM"]
        out.append(Case(g, "vsuxei%d.v" % sew, s,
                        "vsuxei%d.v v5, (t1), v1" % sew,
                        dests=(), mem_bytes=64))

    # ---- masked load/store (v0.t) ----
    # mask 由 Case.mask 在 setup 前装进 v0; setup 自己切到 e32
    s = [vs(32), "la t1, rvv_ls_src"]
    out.append(Case(g, "vle32.v masked", s, "vle32.v v5, (t1), v0.t",
                    mask=True))
    s = [vs(32)] + ldv(32, "v5", "rvv_ls_src")
    s += ["la t1, RVVMEM"]
    out.append(Case(g, "vse32.v masked", s, "vse32.v v5, (t1), v0.t",
                    mask=True, dests=(), mem_bytes=64))

    # ---- LMUL=2 unit-stride (多 uop/多 beat) ----
    s = ["vsetivli x0, 8, e32, m2, tu, mu"]
    s += ["la t1, rvv_ls_src", "vle32.v v6, (t1)"]
    out.append(Case(g, "vle32.v m2 lmul2", s, "vle32.v v6, (t1)",
                    dests=(6, 7), res_bytes=32))
    s = ["vsetivli x0, 8, e32, m2, tu, mu"]
    s += ["la t1, rvv_ls_src", "vle32.v v6, (t1)"]
    s += ["la t1, RVVMEM"]
    out.append(Case(g, "vse32.v m2 lmul2", s, "vse32.v v6, (t1)",
                    dests=(), mem_bytes=64, pre_init=(6, 7)))
    return out


# ---------------------------------------------------------------------------
def build_cases():
    return {
        "alu": alu_cases(),
        "mulmac": mulmac_cases(),
        "red": red_cases(),
        "mask": mask_cases(),
        "ls": ls_cases(),
    }


GROUPS = ("alu", "mulmac", "red", "mask", "ls")


if __name__ == "__main__":
    cc = build_cases()
    total = 0
    for g in GROUPS:
        print("%-8s %3d cases" % (g, len(cc[g])))
        total += len(cc[g])
    print("total %d" % total)
