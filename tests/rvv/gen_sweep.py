#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tests/rvv/gen_sweep.py —— 生成 RVV 逐指令自检汇编 (+ Spike 黄金)

流程 (--oracle):
  1. 生成 asm/rvv_sweep_<group>.S, 期望值数组先填 0
  2. 汇编到 0x80000000 (oracle 变体, 开头置 mstatus.VS), 用 Spike 跑
     rs N -> pc 0 -> 逐字 mem 读回 rvv_res / rvv_mem / rvv_progress
  3. 把真实值写进最终 .S 的 rvv_exp
  4. 再汇编一次 (DUT 变体, -Ttext=0), 用 nm 取 progress/status 地址写 manifest
  5. 可选: 再跑一遍带自检的 oracle, 确认 rvv_a0 == 0 (校验生成器自己的比较代码)

日常回归不需要 Spike: 生成的 .S 已带黄金值, `make rvv-sweep` 只跑 DUT。

用法:
  python3 tests/rvv/gen_sweep.py --oracle          # 全量重新生成
  python3 tests/rvv/gen_sweep.py --oracle --only alu
  python3 tests/rvv/gen_sweep.py                    # 只生成 .S (期望值为 0, 需已有黄金)
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ASM_DIR = os.path.join(ROOT, "asm")

DEFAULT_CROSS = "/x2025/GPrj1/IC1/riscv/RISCV_CPU/tools/riscv/bin/riscv32-unknown-elf-"
CROSS = os.environ.get("RVV_CROSS", DEFAULT_CROSS)
SPIKE = os.environ.get("RVV_SPIKE", "/bin/spike")
SPIKE_LIB = os.environ.get("RVV_SPIKE_LIB", "/usr/local/lib")

sys.path.insert(0, HERE)
from catalog import build_cases, GROUPS  # noqa: E402

SLOT = 64          # 每个用例在 res/exp/mem 区里占 64B
ORACLE_BASE = 0x80000000
RUN_STEPS = 4000000


# ---------------------------------------------------------------------------
# 数据区
# ---------------------------------------------------------------------------
def data_section(ncases, exp_words=None):
    ls_src = ", ".join(str((i * 17 + 5) & 0xFF) for i in range(256))
    status = "\n".join(
        "rvv_status: .word " + ", ".join(["0xa5a5a5a5"] * min(8, ncases))
        if i == 0 else
        "    .word " + ", ".join(["0xa5a5a5a5"] * min(8, ncases - i))
        for i in range(0, ncases, 8))
    if exp_words is None:
        exp = "rvv_exp:      .space %d" % (SLOT * ncases)
    else:
        rows = []
        for cid in range(ncases):
            ws = exp_words.get(cid, [])
            n = len(ws)
            ws = list(ws) + [0] * ((SLOT // 4) - n)
            rows.append("    .word " + ", ".join("0x%08x" % (w & 0xFFFFFFFF)
                                                for w in ws))
        exp = "rvv_exp:\n" + "\n".join(rows)
    return """
.section .data
.align 4
rvv_progress: .word 0
rvv_phase:    .word 0
rvv_a0:       .word 0
%s
rvv_trapmask: .space %d
.align 4
rvv_res:      .space %d
.align 4
%s
.align 4
rvv_mem:      .space %d

.align 4
rvv_in_a8:  .byte 1,127,128,255,0,85,170,16,240,15,126,129,2,254,64,192
rvv_in_b8:  .byte 2,1,1,1,1,2,3,4,8,8,1,1,254,2,3,5
rvv_in_a16: .half 1,0x7fff,0x8000,0xffff,0,0x5555,0xaaaa,0x1234
rvv_in_b16: .half 2,1,1,1,1,2,3,0x0101
rvv_in_a32: .word 1,0x7fffffff,0x80000000,0xffffffff
rvv_in_b32: .word 2,1,1,1
rvv_in_c32: .word 3,5,7,9
rvv_in_c16: .half 3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33
rvv_in_w16: .half 1,0x7fff,0x8000,0xffff,2,3,4,5,6,7,8,9,10,11,12,13
rvv_mask_a: .byte 0x55,0xaa,0x0f,0xf0,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0xff,0x00,0x5a,0xa5
rvv_mask_b: .byte 0x0f,0xf0,0x33,0xcc,0x80,0x40,0x20,0x10,0x08,0x04,0x02,0x01,0x0f,0xf0,0xa5,0x5a
rvv_idx8:   .byte 0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60
rvv_idx16:  .half 0,2,4,6,8,10,12,14
rvv_idx32:  .word 0,4,8,12
rvv_hitbuf: .space 64
rvv_ls_src: .byte %s
.align 5
rvv_sweep_area: .space 4096
""" % (status, ncases, SLOT * ncases, exp, SLOT * ncases, ls_src)


# ---------------------------------------------------------------------------
# 单条用例代码
# ---------------------------------------------------------------------------
def check_words(case):
    if case.mem_bytes:
        return case.mem_bytes // 4
    return case.res_bytes // 4


def gen_case(cid, case, oracle=False, unif=False):
    """生成一条用例的 phase 0-2 (预置/源装载 -> 被测指令 -> 结果落内存)。

    结果比对**不在**这里做: 所有 store 都排在全部用例之后统一比对, 避开
    "标量 load 紧跟向量 store 读到旧值" 的排序/转发窗口 (实测 2026-10-18:
    vse32 后立刻 lw 读到 0, 隔 ~30 条指令才读到正确值)。

    oracle=True 且 case.manual 时整条跳过 —— Spike 对这个编码不支持的用例,
    黄金值由 manual_expected() 直接算, 不参与 Spike 自检。
    """
    if oracle and case.manual:
        return "    # ---- case %d: %s (oracle 跳过, 黄金用本地模型) ----\n" % (
            cid, case.name)
    L = []
    off = cid * SLOT

    # 1) 进度标记 + phase 0 (预置 + 源装载; 卡在 vle 会直接指到 setup)
    L.append("    # ---- case %d: %s ----" % (cid, case.name))
    L.append("    li   t0, %d" % cid)
    L.append("    sw   t0, 0(s0)")
    L.append("    li   t0, 0")
    L.append("    sw   t0, 0(s1)")

    # 2) 全 16B 预置目的寄存器组 (tu/mu 下的 tail / 被屏蔽元素)
    L.append("    vsetivli x0, 16, e8, m1, tu, mu")
    for r in case.pre_init:
        L.append("    vmv.v.i v%d, 5" % r)

    # 3) v0 (mask / carry)
    if case.mask:
        L.append("    vsetivli x0, 16, e8, m1, tu, mu")
        if unif:
            L.append("    vmv.v.i v0, 5")
        else:
            L.append("    la   t1, rvv_mask_a")
            L.append("    vle8.v v0, (t1)")

    # 4) 用例自己的 setup (vset + 源装载 + 标量)
    for s in case.setup:
        # 每个 store 用例的目标区在自己的 64B 槽里
        s = s.replace("RVVMEM", "rvv_mem+%d" % off)
        if unif:
            # 2026-10-18 现状: 向量 load 在 DA 里卡死 (见 rvv_lsu 同样挂)。
            # unif 变体把所有源装载换成统一常量, 让计算类指令先能跑通。
            mm = re.match(r"\s*vle\d+\.v\s+(v\d+),.*", s)
            if mm:
                s = "vmv.v.i %s, 5" % mm.group(1)
        L.append("    " + s if not s.startswith("    ") else s)

    # 5) 被测指令 (phase 1)
    L.append("    li   t0, 1")
    L.append("    sw   t0, 0(s1)")
    L.append("    " + case.inst)

    # 6) 结果落内存 (phase 2; store 类直接写在目标区)
    L.append("    li   t0, 2")
    L.append("    sw   t0, 0(s1)")
    if not case.mem_bytes:
        L.append("    vsetivli x0, 4, e32, m1, tu, mu")
        for k, r in enumerate(case.dests):
            L.append("    la   t1, rvv_res+%d" % (off + 16 * k))
            L.append("    vse32.v v%d, (t1)" % r)
    return "\n".join(L) + "\n"


def gen_check(cid, case, phase=4, oracle=False):
    """全部用例跑完后统一做的标量比对 (phase 4)。"""
    if oracle and case.manual:
        return "    # ---- check %d: %s (oracle 跳过) ----\n" % (cid, case.name)
    L = []
    nwords = check_words(case)
    off = cid * SLOT
    target = "rvv_mem" if case.mem_bytes else "rvv_res"
    L.append("    # ---- check %d: %s ----" % (cid, case.name))
    L.append("    li   t0, %d" % cid)
    L.append("    sw   t0, 0(s0)")
    L.append("    li   t0, %d" % phase)
    L.append("    sw   t0, 0(s1)")
    L.append("    la   t1, %s+%d" % (target, off))
    L.append("    la   t2, rvv_exp+%d" % off)
    for w in range(nwords):
        L.append("    lw   t3, %d(t1)" % (4 * w))
        L.append("    lw   t4, %d(t2)" % (4 * w))
        L.append("    xor  t3, t3, t4")
        if w == 0:
            L.append("    mv   t5, t3")
        else:
            L.append("    or   t5, t5, t3")
    L.append("    sltu t5, x0, t5")              # 1 = fail
    L.append("    la   t1, rvv_status+%d" % (4 * cid))
    L.append("    sw   t5, 0(t1)")
    L.append("    add  a0, a0, t5")
    return "\n".join(L) + "\n"


def gen_asm(group, cases, exp_map, oracle, unif=False):
    L = []
    L.append("    # 自动生成 by tests/rvv/gen_sweep.py —— 不要手改")
    L.append(".section .text.init")
    L.append(".globl _start")
    L.append("_start:")
    if oracle:
        L.append("    # Spike: 打开 mstatus.VS, 否则所有向量指令 illegal")
        L.append("    li   t0, 0x600")
        L.append("    csrs mstatus, t0")
        # Spike 对本 build 不支持的指令会报 illegal; 装一个 handler 跳过它并
        # 在 trapmask 里标记, 让整份 oracle 能跑完, 一次性列出所有不支持的用例。
        L.append("    la   t0, rvv_trap_handler")
        L.append("    csrw mtvec, t0")
    L.append("    add  a0, x0, x0")
    # s0/s1 固定指向 progress/phase, 每用例的标量代码不许碰 s0/s1
    L.append("    la   s0, rvv_progress")
    L.append("    la   s1, rvv_phase")
    for cid, c in enumerate(cases):
        L.append(gen_case(cid, c, oracle, unif))
    # ---- 全部 store 之后再统一比对 (phase 4) ----
    for cid, c in enumerate(cases):
        L.append(gen_check(cid, c, oracle=oracle))
    # ---- 把 dcache 脏行冲回内存 ----
    # ⚠️ 冒烟台直接读 AXI 从机内存 (u_mem), 而 dcache 是 write-back (2KB/32B/2-way)。
    #    status/progress 的标量 store 若正好落在一条已被访存带进来的行上 (实测
    #    red 组的 status[5]@0x1520 被 rvv_res 的 fill 带进 dcache), 就只更新 dcache,
    #    内存里仍是镜像初值 ⇒ TB 误判成 HANG。这里顺序读 4KB 无关地址 (每个 set
    #    至少经过 2 路), 强制把脏行写回。不改变任何被比对的数据。
    #    扫的是镜像里的 rvv_sweep_area (DUT/Spike 都合法), 不能用固定物理地址。
    # 2026-10-18: 从 `lw` 改成 `sw`。difftest 逐条比对退休值, 而这个扫描的读数
    #   本来就被丢弃; 实测 DUT 的 LSU 在向量 store 之后对扫描区做 load 时,
    #   会错误地命中尚未排空的 store 数据 (AXI 内存里明明是 0, 读回 0x05050505)。
    #   改成 store 一样能强制分配/驱逐 dcache 行, 且不产生被比对的架构值;
    #   store 数据用 t3 里残留的值即可 —— 这块区域的内容没有任何人读。
    L.append("    # ---- dcache write-back sweep (写地址, 值会被丢弃) ----")
    L.append("    la   t1, rvv_sweep_area")
    for k in range(128):
        if k == 64:
            # lw/addi 的立即数只有 12 位 (有符号, ≤2047), 4KB 分两段
            L.append("    addi t1, t1, 2016")
        L.append("    sw   t3, %d(t1)" % (32 * (k % 64)))
    L.append("    la   t0, rvv_a0")
    L.append("    sw   a0, 0(t0)")
    if oracle:
        L.append("rvv_oracle_loop:")
        L.append("    j    rvv_oracle_loop")
        L.append(".align 2")
        L.append("rvv_trap_handler:")
        L.append("    csrr t0, mepc")
        L.append("    addi t0, t0, 4")
        L.append("    csrw mepc, t0")
        L.append("    la   t1, rvv_progress")
        L.append("    lw   t2, 0(t1)")
        L.append("    la   t1, rvv_trapmask")
        L.append("    add  t1, t1, t2")
        L.append("    li   t3, 1")
        L.append("    sb   t3, 0(t1)")
        L.append("    mret")
    else:
        L.append("    addi x17, x0, 93")
        L.append("    ecall")
        L.append("    unimp")
    L.append(data_section(len(cases), exp_map if exp_map else None))
    return "\n".join(L)


def gen_asm_with_exp(group, cases, exp_map, oracle, unif=False):
    return gen_asm(group, cases, exp_map, oracle, unif)


# ---------------------------------------------------------------------------
# 汇编 / Spike
# ---------------------------------------------------------------------------
def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True, **kw)


def assemble(src_path, out_elf, base, oracle):
    # ⚠️ -mno-relax 必须: 裸机程序没有 crt0 设 gp, 而链接器缺省会把
    #    `la symbol` 松弛成 gp-relative ⇒ 在 A910/Spike 里 gp=0, 地址全错。
    cmd = [CROSS + "gcc", "-march=rv32imv_zicsr", "-mabi=ilp32", "-mno-relax",
           "-nostdlib", "-nostartfiles", "-Wl,-Ttext=0x%x" % base]
    if oracle:
        cmd += ["-DSPIKE_ORACLE"]
    cmd += [src_path, "-o", out_elf]
    r = subprocess.run(cmd, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, universal_newlines=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise RuntimeError("assemble failed: %s" % src_path)
    return out_elf


def nm_symbols(elf):
    out = sh([CROSS + "nm", elf]).stdout
    syms = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3:
            try:
                syms[p[2]] = int(p[0], 16)
            except ValueError:
                pass
    return syms


def run_spike(elf, cmds):
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = SPIKE_LIB + ":" + env.get("LD_LIBRARY_PATH", "")
    with tempfile.NamedTemporaryFile("w", suffix=".cmd", delete=False) as f:
        f.write("\n".join(cmds) + "\nquit\n")
        cmd_path = f.name
    try:
        r = subprocess.run(
            [SPIKE, "--isa=rv32gcv", "--misaligned", "-d",
             "--debug-cmd=" + cmd_path, elf],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, env=env, timeout=600)
    finally:
        os.unlink(cmd_path)
    # ⚠️ Spike 的 debug 回显 (pc/mem/reg) 走 **stderr**, 不是 stdout
    txt = r.stdout + "\n" + r.stderr
    vals = []
    for line in txt.splitlines():
        s = line.strip()
        if re.fullmatch(r"0x[0-9a-fA-F]+", s):
            vals.append(int(s, 16))
    return vals, txt


def oracle_group(group, cases, unif=False):
    """返回 (exp_map, mem_map, info)。exp_map[cid] = [words]"""
    tmpdir = tempfile.mkdtemp(prefix="rvv_oracle_")
    try:
        src = os.path.join(tmpdir, "oracle.S")
        with open(src, "w") as f:
            f.write(gen_asm(group, cases, {}, oracle=True, unif=unif))
        elf = os.path.join(tmpdir, "oracle.elf")
        assemble(src, elf, ORACLE_BASE, True)
        syms = nm_symbols(elf)

        # 结果区地址
        cmds = ["rs %d" % RUN_STEPS, "pc 0", "mem 0x%08x" % syms["rvv_progress"]]
        layout = []   # ('res'/'mem', cid, words)
        for cid, c in enumerate(cases):
            if c.manual:
                continue
            if c.mem_bytes:
                base = syms["rvv_mem"] + cid * SLOT
                layout.append(("mem", cid, c.mem_bytes // 4))
                for w in range(c.mem_bytes // 4):
                    cmds.append("mem 0x%08x" % (base + 4 * w))
            else:
                base = syms["rvv_res"] + cid * SLOT
                layout.append(("res", cid, c.res_bytes // 4))
                for w in range(c.res_bytes // 4):
                    cmds.append("mem 0x%08x" % (base + 4 * w))
        cmds.append("mem 0x%08x" % syms["rvv_a0"])
        tm_words = (len(cases) + 3) // 4
        for w in range(tm_words):
            cmds.append("mem 0x%08x" % (syms["rvv_trapmask"] + 4 * w))

        vals, raw = run_spike(elf, cmds)
        if not vals:
            raise RuntimeError("spike produced no output for %s" % group)
        pc = vals[0]
        progress = vals[1]
        data = vals[2:]
        # 跑完的判据: PC 回到 oracle 的收尾循环 (>= 0x80000000)。若在 0 附近,
        # 说明发生了未经 trap handler 处理的异常 (或 handler 自己出错)。
        if pc < ORACLE_BASE:
            cid = progress if 0 <= progress < len(cases) else -1
            name = cases[cid].name if cid >= 0 else "?"
            sys.stderr.write(
                "\n[oracle] %s: Spike PC=0x%x (预期 0x%x), progress=%d "
                "-> 该用例在 Spike 上 trap/未完成: %s\n" % (group, pc, loop,
                                                         progress, name))
            return None, None, {"error": "trap", "cid": cid,
                                "name": name, "pc": pc}

        # 解析
        exp_map, mem_map = {}, {}
        pos = 0
        for kind, cid, n in layout:
            ws = data[pos:pos + n]
            pos += n
            if len(ws) != n:
                raise RuntimeError("short spike dump for %s case %d" % (group, cid))
            (exp_map if kind == "res" else mem_map)[cid] = ws
        # Spike 不支持的编码: 用本地模型算
        for cid, c in enumerate(cases):
            if c.manual:
                exp_map[cid] = manual_expected(c, unif)
        a0 = data[pos] if pos < len(data) else None
        pos += 1
        tm_words = data[pos:pos + (len(cases) + 3) // 4]
        trapped = []
        for i in range(len(cases)):
            b = (tm_words[i // 4] >> (8 * (i % 4))) & 0xFF
            if b:
                trapped.append(i)
        return exp_map, mem_map, {"a0": a0, "trapped": trapped}
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# 本地模型: Spike 对这个 build 的 SEW=8 vsext/vzext 一律 illegal
# ---------------------------------------------------------------------------
IN_A8 = [1, 127, 128, 255, 0, 85, 170, 16, 240, 15, 126, 129, 2, 254, 64, 192]


def manual_expected(case, unif=False):
    kind, vf = case.manual
    src = [5] * 16 if unif else IN_A8
    words = []
    if vf == 2:
        raw = []
        for b in src:
            v = (b - 256 if (kind == "sext" and b >= 128) else b) & 0xFFFF
            raw += [v & 0xFF, (v >> 8) & 0xFF]
    else:
        raw = []
        for b in src:
            v = (b - 256 if (kind == "sext" and b >= 128) else b) & 0xFFFFFFFF
            raw += [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
    for i in range(0, len(raw), 4):
        words.append(raw[i] | (raw[i+1] << 8) | (raw[i+2] << 16) | (raw[i+3] << 24))
    return words


# ---------------------------------------------------------------------------
def gen_one(base, gname, cases, suffix, unif, oracle, no_verify):
    """生成一个批次 (base = 文件名后缀, gname = 所属组名)。返回 0 成功。"""
    exp_map, mem_map, info = {}, {}, {}
    print("[%s] %d cases -> %s" % (base, len(cases),
                                   "Spike oracle ..." if oracle else "generate"))

    if oracle:
        exp_map, mem_map, info = oracle_group(base, cases, unif)
        if exp_map is None:
            print("  ❌ oracle 失败: %s" % info)
            src = gen_asm_with_exp(gname, cases, {}, False, unif)
            with open(os.path.join(ASM_DIR, "rvv_sweep_%s%s.S" % (base, suffix)), "w") as f:
                f.write(src)
            return 2
        for cid, ws in mem_map.items():
            exp_map[cid] = ws
        tr = info.get("trapped", [])
        print("  ✅ oracle ok" + ("" if info.get("a0") is None
                                 else ", a0=%s" % info["a0"]))
        if tr:
            print("  ⚠️ Spike 对本 build 不支持的编码 %d 条:" % len(tr))
            for cid in tr:
                print("     [%3d] %s" % (cid, cases[cid].name))

    src = gen_asm_with_exp(gname, cases, exp_map, False, unif)
    asm_path = os.path.join(ASM_DIR, "rvv_sweep_%s%s.S" % (base, suffix))
    with open(asm_path, "w") as f:
        f.write(src)

    tmpd = tempfile.mkdtemp(prefix="rvv_dut_%s_" % base)
    try:
        elf = os.path.join(tmpd, "dut.elf")
        assemble(asm_path, elf, 0, False)
        syms = nm_symbols(elf)
        manifest = {
            "group": gname,
            "test": base,
            "n": len(cases),
            "progress_addr": syms["rvv_progress"],
            "phase_addr": syms["rvv_phase"],
            "status_addr": syms["rvv_status"],
            "a0_addr": syms["rvv_a0"],
            "cases": [{"id": i, "name": c.name,
                       "kind": "mem" if c.mem_bytes else "vreg",
                       "bytes": c.mem_bytes or c.res_bytes}
                      for i, c in enumerate(cases)],
        }
        with open(os.path.join(HERE, "manifest_%s%s.json" % (base, suffix)), "w") as f:
            json.dump(manifest, f, indent=1)
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)

    if oracle and not no_verify:
        tmpd = tempfile.mkdtemp(prefix="rvv_verify_%s_" % base)
        try:
            vsrc = os.path.join(tmpd, "verify.S")
            with open(vsrc, "w") as f:
                f.write(gen_asm_with_exp(gname, cases, exp_map, True, unif))
            velf = os.path.join(tmpd, "verify.elf")
            assemble(vsrc, velf, ORACLE_BASE, True)
            vsyms = nm_symbols(velf)
            vals, raw = run_spike(
                velf, ["rs %d" % RUN_STEPS, "pc 0",
                       "mem 0x%08x" % vsyms["rvv_a0"]])
            if len(vals) < 2 or vals[0] < ORACLE_BASE:
                print("  ❌ oracle 自检: PC/trap 异常 (%s)" % vals[:3])
                return 3
            if vals[1] != 0:
                print("  ❌ oracle 自检: a0=%d (期望 0) —— 比较代码/黄金不一致"
                      % vals[1])
                return 3
            print("  ✅ oracle 自检通过 (a0=0)")
        finally:
            shutil.rmtree(tmpd, ignore_errors=True)

    print("  -> %s  (%d cases, manifest 已写)" % (asm_path, len(cases)))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--oracle", action="store_true",
                    help="用 Spike 重新生成黄金值")
    ap.add_argument("--only", default=None, help="只处理一个 group")
    ap.add_argument("--no-verify", action="store_true",
                    help="不跑 oracle 自检 (a0==0)")
    ap.add_argument("--setup", choices=("full", "unif"), default="full",
                    help="full=真实 vle 源数据; unif=统一常量 (向量 load 未通时用)")
    ap.add_argument("--batch", type=int, default=20,
                    help="每个 .S 最多几条用例 (避开已知的 idu_accept_num/IBUF 长程序 bug)")
    args = ap.parse_args()

    all_cases = build_cases()
    unif = (args.setup == "unif")
    variant = "unif" if unif else "full"
    unif_groups = ("alu", "mulmac", "red", "mask")
    if args.only:
        groups = [args.only]
    else:
        groups = list(unif_groups) if unif else list(GROUPS)
    suffix = "_unif" if unif else ""

    os.makedirs(ASM_DIR, exist_ok=True)
    os.makedirs(HERE, exist_ok=True)

    batch_file = os.path.join(HERE, "batches.json")
    batches = {}
    if os.path.exists(batch_file):
        try:
            batches = json.load(open(batch_file))
        except Exception:
            batches = {}
    names = [] if not args.only else list(batches.get(variant, []))
    names = [n for n in names if n.split("_")[0] not in groups]

    for g in groups:
        cases_all = all_cases[g]
        n = max(1, args.batch)
        chunks = [cases_all[i:i+n] for i in range(0, len(cases_all), n)]
        for ci, cases in enumerate(chunks):
            base = g if len(chunks) == 1 else "%s_%d" % (g, ci)
            rc = gen_one(base, g, cases, suffix, unif, args.oracle,
                         args.no_verify)
            if rc != 0:
                return rc
            names.append(base)
    batches[variant] = names
    with open(batch_file, "w") as f:
        json.dump(batches, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
