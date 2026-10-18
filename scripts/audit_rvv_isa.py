#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""audit_rvv_isa.py —— 检查 RVV CoreMark 的二进制是否只用 A910 支持的向量指令

背景（2026-10-18）：
  GCC 14 自动向量化 CoreMark 时会生成一些 A910 向量融合层不支持、或者
  黄金模型没实现的指令（vmv.x.s、vid.v、vrgather、整寄存器 spill、
  e16,mf4 等）。CoreMark RVV 构建走“编译器规避”路线：在源码里按函数
  关掉向量化，而不是改 RTL。本脚本就是那条路线的**唯一判据**：
  出现清单外的向量指令 / 向量 CSR 就让构建失败。

用法：
  python3 scripts/audit_rvv_isa.py --elf coremark/build_rvv/coremark_rvv.elf \
      --objdump riscv32-unknown-elf-objdump --summary

退出码：0 = PASS；1 = 有违规；2 = objdump/ELF 读取失败。

⚠️ 只反汇编代码段（objdump -d，不要 -D）—— .debug_* 的字节会被
   误判成看似合理的向量指令，制造假阳性/假阴性。
"""

import argparse
import re
import subprocess
import sys
from collections import Counter, defaultdict

# ---------------------------------------------------------------------------
# 允许集：全部来自 doc/v-instruction.md，且 A910 RTL + 现有黄金模型已支持
# ---------------------------------------------------------------------------
# 普通访存：vle8.v / vse16.v / vlse8.v / vsse32.v / vluxei16.v / vsuxei8.v ...
LS_RE = re.compile(r"^v([ls])(e|se|luxei|suxei)(8|16|32)\.v$")

# OPIVV/OPIVX/OPIVI/OPMVV/OPMVX 的助记符基名（点号前）
ALU_BASES = {
    # 算术 / 比较 / 逻辑 / 移位 / 饱和
    "vadd", "vsub", "vrsub", "vadc",
    "vmax", "vmaxu", "vmin", "vminu",
    "vmseq", "vmsne", "vmslt", "vmsltu", "vmsle", "vmsleu",
    "vand", "vor", "vxor",
    "vsll", "vsrl", "vsra", "vssrl", "vssra", "vnsrl",
    "vsaddu", "vsadd", "vssubu", "vssub",
    # 搬移 / 选择 / 扩展 / 窄化 / 归约
    "vmerge", "vsext", "vzext", "vnclip", "vnclipu",
    "vredsum", "vwredsum", "vredmax", "vredmaxu", "vredmin", "vredminu",
    # mask 逻辑（.mm）
    "vmandn", "vmand", "vmor", "vmxor", "vmorn", "vmnand", "vmnor", "vmxnor",
    # MULMAC
    "vmul", "vmulhu", "vmulh", "vmulhsu",
    "vmacc", "vmadd", "vnmsac", "vnmsub",
    "vwmulu", "vwmul", "vwmulsu",
    "vwmaccu", "vwmacc", "vwmaccsu", "vwmaccus",
}

# 只允许这三种 vmv（向量目的）。vmv.x.s / vmv.s.x 不在其中。
VMV_ALLOWED = {"vmv.v.v", "vmv.v.x", "vmv.v.i"}

# vset 的合法 SEW/LMUL 组合（RvvFrontEnd 的 legality 子集；
# e16,mf4 / e8,mf8 / e32,mf2 / m2+ 都会被判 vill）
VSET_ALLOWED = {
    ("e8", "m1"), ("e16", "m1"), ("e32", "m1"),
    ("e8", "mf2"), ("e16", "mf2"),
}

CSR_MNEMONICS = {
    "csrr", "csrw", "csrs", "csrc",
    "csrrw", "csrrs", "csrrc",
    "csrrwi", "csrrsi", "csrrci",
}

# 期望仍然向量化的函数（信息性，不参与 PASS/FAIL）
KEEP_LIST = [
    "matrix_mul_const", "matrix_add_const", "core_init_state",
    "iterate", "ee_printf",
]


def doc_name(mnem):
    """把 objdump 助记符映射回 doc/v-instruction.md 里的名字。"""
    m = LS_RE.match(mnem)
    if m:
        kind, form, sew = m.groups()
        return ("VLE" if kind == "l" else "VSE") + sew if form == "e" else \
               ("VLSE" if kind == "l" else "VSSE") + sew if form == "se" else \
               ("VLXEI" if kind == "l" else "VSXEI") + sew
    if mnem.startswith("vmv.v."):
        return "VMV"
    base = mnem.split(".", 1)[0]
    if base in ("vsext", "vzext"):
        suffix = mnem.split(".", 1)[1] if "." in mnem else ""
        return base.upper() + "_" + suffix.replace(".", "_").upper()
    return base.upper()


def vset_combo(operands):
    """从 vset 操作数里抠出 (sew, lmul)。返回 None 表示解析失败。"""
    m = re.search(r"\b(e8|e16|e32|e64)\b", operands)
    if not m:
        return None
    sew = m.group(1)
    m2 = re.search(r"\b(mf8|mf4|mf2|m1|m2|m4|m8)\b", operands)
    if not m2:
        return None
    return (sew, m2.group(1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elf", required=True)
    ap.add_argument("--objdump", default="riscv32-unknown-elf-objdump")
    ap.add_argument("--summary", action="store_true",
                    help="打印覆盖统计（助记符/函数/keep-list）")
    args = ap.parse_args()

    try:
        out = subprocess.run(
            [args.objdump, "-d", "--no-show-raw-insn", args.elf],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        sys.stderr.write("audit: objdump failed: %s\n" % e)
        return 2

    func = "<unknown>"
    func_hdr = re.compile(r"^([0-9a-fA-F]+) <([^>]+)>:$")
    insn_re = re.compile(r"^\s*([0-9a-fA-F]+):\s+([A-Za-z0-9_.]+)\s*(.*)$")

    total_vec = 0
    masked = 0
    by_mnem = Counter()
    by_func = Counter()
    by_doc = Counter()
    violations = []   # (func, addr, mnem, reason)

    for line in out.splitlines():
        m = func_hdr.match(line.strip())
        if m:
            func = m.group(2)
            continue

        m = insn_re.match(line)
        if not m:
            continue
        addr, mnem, operands = m.group(1), m.group(2), m.group(3).strip()

        # ---- 非向量 CSR：本核没有 CSR 文件，一律不允许 ----
        if mnem in CSR_MNEMONICS:
            violations.append((func, addr, mnem,
                               "CSR instruction (A910 CSR file not connected)"))
            continue

        # 只看向量指令（CSR 上面已处理）
        if not mnem.startswith("v"):
            continue

        # ---- vset* ----
        if mnem in ("vsetvli", "vsetivli"):
            total_vec += 1
            by_mnem[mnem] += 1
            by_func[func] += 1
            combo = vset_combo(operands)
            if combo is None:
                violations.append((func, addr, mnem,
                                   "unparseable vtype operand: %r" % operands))
            elif combo not in VSET_ALLOWED:
                violations.append((func, addr, mnem,
                                   "unsupported SEW/LMUL %s,%s" % combo))
            continue
        if mnem == "vsetvl":
            total_vec += 1
            by_mnem[mnem] += 1
            by_func[func] += 1
            violations.append((func, addr, mnem,
                               "vsetvl (runtime vtype) not allowed"))
            continue

        if not mnem.startswith("v"):
            continue

        # ---- 普通向量指令 ----
        total_vec += 1
        by_mnem[mnem] += 1
        by_func[func] += 1
        by_doc[doc_name(mnem)] += 1
        if ",v0.t" in operands.replace(" ", ""):
            masked += 1

        ok = False
        if LS_RE.match(mnem):
            ok = True
        elif mnem in VMV_ALLOWED:
            ok = True
        else:
            base = mnem.split(".", 1)[0]
            if base in ALU_BASES:
                # vsext/vzext 只支持 vf2/vf4
                if base in ("vsext", "vzext"):
                    ok = mnem in (base + ".vf2", base + ".vf4")
                else:
                    ok = True
        if not ok:
            violations.append((func, addr, mnem,
                               "not in A910 supported RVV set"))

    # ------------------------------------------------------------------
    # 报告
    # ------------------------------------------------------------------
    print("=" * 68)
    print("  RVV instruction audit: %s" % args.elf)
    print("=" * 68)
    print("  vector instructions : %d  (masked v0.t: %d)" % (total_vec, masked))

    if args.summary:
        print("\n  -- by mnemonic --")
        for k, v in by_mnem.most_common():
            print("    %-18s %4d" % (k, v))
        print("\n  -- by doc/v-instruction.md name --")
        for k, v in by_doc.most_common():
            print("    %-18s %4d" % (k, v))
        print("\n  -- by function (vector insns) --")
        for k, v in by_func.most_common():
            print("    %-30s %4d" % (k, v))
        print("\n  -- keep-list check --")
        for name in KEEP_LIST:
            n = sum(c for f, c in by_func.items()
                    if f == name or f.startswith(name + "."))
            print("    %-24s %s (%d)" % (name,
                  "vectorized" if n else "NOT vectorized", n))

    if violations:
        print("\n  VIOLATIONS (%d):" % len(violations))
        for func, addr, mnem, why in violations:
            print("    0x%-6s %-24s %-14s  %s" % (addr, func, mnem, why))
        print("\n  AUDIT: FAIL")
        return 1

    print("\n  AUDIT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
