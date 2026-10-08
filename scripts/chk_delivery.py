#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
对同事交付的 RTL 做**静态接口体检** —— 查的是 VCS 不会报错、但功能静默失效的那几类。

【为什么要它】接 C910 IDU/LSU 的过程中, 同一个坑反复出现, 而且每一条都是
"能 elaborate、能跑、冒烟台还绿, 但功能是错的":

  A. **漏声明 → 隐式 1 位线网**。`default_nettype wire` 下, 未声明的标识符是 1 位线网,
     连到多位端口时**静默截断**。交付的 IDU 里踩了 38 根, 其中
     `aiq_dp_issue_read_data` 应 96 位、`biq_dp_issue_read_data` 应 152 位 ——
     **整条发射通路只剩 bit0**。本仓历史上共踩过四次。
  B. **子模块端口宽 ≠ 顶层端口宽**。`idu_biq_rslt_sel` 顶层声明 6 位、内部驱动 8 位,
     而 BR_JAL=bit6 / BR_JALR=bit7 ⇒ **JAL/JALR 被整个丢掉**。
  C. **被当时钟用、却全仓无驱动的信号**。C910 工厂版的门控时钟单元被整体剥掉,
     交付里 8 个文件 17 处本地时钟没有驱动 (含 LSU 的存储队列 `sq_clk`)。
  D. **空连接的输入端口** (`.port()`), 拿到的是 Z。
  E. **parameter 漏分号 / 先用后声明** 这类语法级问题。

用法:
    python3 scripts/chk_delivery.py                  # 查 IDU + LSU
    python3 scripts/chk_delivery.py mySoC/xxx/rtl    # 查指定目录

判据口径 (写下来免得以后误判):
  * A 只报"既未声明、又连到**宽 >1** 的端口" —— 1 位信号用隐式线网**无害**。
  * B 只报"该信号**同时是顶层端口**"的 —— 内部信号之间有宽差是正常的截断。
  * C 只报"被 posedge/negedge 用、且既不是 input 端口、也没有任何赋值"的。
退出码: 0 = 干净, 1 = 有发现。
"""
import os
import re
import sys
import glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIRS = ["mySoC/idu_c910/rtl", "mySoC/lsu/rtl", "mySoC/rtu/rtl"]

# 时钟扫描时认识的"本来就是时钟"的名字
KNOWN_CLK = {"forever_cpuclk", "forever_clk", "cpu_clk", "clk"}


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def width_of(rng):
    """从 `[hi:lo]` 算宽度。参数化/未知返回 None (那类不参与比较, 免得误报)。"""
    if not rng:
        return 1
    if ":" not in rng:
        return None
    try:
        hi, lo = [int(x.strip()) for x in rng.split(":", 1)]
        return abs(hi - lo) + 1
    except ValueError:
        return None


PORT_RE = re.compile(
    r"^(input|output|inout)\s+(?:wire|logic|reg)?\s*(?:signed\s*)?"
    r"(?:\[([^\]]*)\]\s*)?(\w+)$")


def parse_ports(text):
    """module 端口表 → {名字: 宽度}"""
    m = re.search(r"^\s*module\s+(\w+)\s*(#\s*\(.*?\)\s*)?\((.*?)\)\s*;",
                  text, re.S | re.M)
    if not m:
        return None, {}
    d = {}
    for line in m.group(3).splitlines():
        mm = PORT_RE.match(line.strip().rstrip(","))
        if mm:
            d[mm.group(3)] = width_of(mm.group(2))
            # 方向另存一个键 (前缀避开正常名字), 给"空连接"那条判据查方向用
            d["__dir__" + mm.group(3)] = mm.group(1)
    return m.group(1), d


def declared_names(text):
    """本文件里所有被声明过的标识符 (含端口表)。"""
    names = set()
    for m in re.finditer(r"\b(?:input|output|inout|logic|wire|reg)\b([^;]*);", text):
        for nm in re.findall(r"([A-Za-z_]\w*)", re.sub(r"\[[^\]]*\]", "", m.group(1))):
            names.add(nm)
    _, ports = parse_ports(text)
    names |= {k for k in ports if not k.startswith("__dir__")}
    return names


def instantiations(text):
    """(模块名, 实例名, 连接串)"""
    for m in re.finditer(r"^\s*(\w+)\s+(?:#\s*\(.*?\)\s*)?(\w+)\s*\((.*?)\)\s*;",
                         text, re.S | re.M):
        yield m.group(1), m.group(2), m.group(3)


def main():
    dirs = sys.argv[1:] or DEFAULT_DIRS
    files = []
    for d in dirs:
        files += sorted(glob.glob(os.path.join(ROOT, d, "*.sv")) +
                        glob.glob(os.path.join(ROOT, d, "*.v")))
    if not files:
        print("没找到源文件 (目录: %s)" % dirs)
        return 1

    texts = {f: open(f, encoding="utf-8", errors="replace").read() for f in files}
    modports = {}
    for f, t in texts.items():
        name, ports = parse_ports(strip_comments(t))
        if name:
            modports.setdefault(name, ports)

    findings = 0

    # ---- A / B / D: 逐文件的顶层例化对账 ----
    for f, raw in texts.items():
        text = strip_comments(raw)
        decl = declared_names(text)
        _, topports = parse_ports(text)

        undeclared = {}   # 信号 -> (最宽, 例子)
        mismatch = {}     # 信号 -> (顶层宽, 子模块, 口, 子宽)
        empty_in = []     # (行号, 口名)

        for mod, inst, conns in instantiations(text):
            if mod not in modports:
                continue
            for pm in re.finditer(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)", conns):
                port, sig = pm.group(1), pm.group(2)
                if sig == "":       # D: 空连接
                    # ⚠️ 只有**输入**口悬空才是问题 (拿到 Z); 输出口不接是"不要这个观察量",
                    #    无害。所以这里要查方向 —— 早期版本没查, 把两个输出口误报成问题。
                    if modports[mod].get("__dir__" + port) in ("input", "inout"):
                        empty_in.append((port, mod))
                    continue
                if not re.fullmatch(r"[A-Za-z_]\w*", sig):
                    continue
                wsub = modports[mod].get(port)
                if sig not in decl and wsub and wsub > 1:
                    if sig not in undeclared or wsub > undeclared[sig][0]:
                        undeclared[sig] = (wsub, "%s.%s" % (mod, port))
                if sig in topports and wsub and topports[sig] and wsub != topports[sig]:
                    mismatch[sig] = (topports[sig], mod, port, wsub)

        if undeclared:
            findings += len(undeclared)
            print("❌ %s: %d 根信号**未声明**且连到多位端口 ⇒ 隐式 1 位线网会截断它"
                  % (os.path.relpath(f, ROOT), len(undeclared)))
            for s, (w, ex) in sorted(undeclared.items(), key=lambda x: -x[1][0]):
                print("      %-38s 本该 %-4s 位 (例: %s)" % (s, w, ex))
        if mismatch:
            findings += len(mismatch)
            print("❌ %s: 顶层端口与子模块端口**位宽不一致**"
                  % os.path.relpath(f, ROOT))
            print("   (⚠️ 需人工判断: 两侧都合理时也可能无害 —— 已知 `*_dupx` 的 6 vs 7"
                  " 就是如此, PREG=64 档下第 7 位恒 0。真错的是那种\"丢掉了有意义的高位\","
                  " 如 `idu_biq_rslt_sel` 的 6 vs 8 —— BR_JAL/BR_JALR 恰好在 bit6/7)")
            for s, (wt, mo, po, ws) in sorted(mismatch.items()):
                print("      %-38s 顶层 %-3s ← %s.%s 宽 %s"
                      % (s, wt, mo, po, ws))
        if empty_in:
            findings += len(empty_in)
            print("❌ %s: %d 个端口是**空连接** `.port()` (输入会拿到 Z)"
                  % (os.path.relpath(f, ROOT), len(empty_in)))
            for po, mo in empty_in[:20]:
                print("      .%s()  (例化 %s)" % (po, mo))

    # ---- C: 无驱动的时钟 ----
    for f, raw in texts.items():
        text = strip_comments(raw)
        clks = set(re.findall(r"(?:posedge|negedge)\s+([A-Za-z_]\w*)", text))
        clks = {c for c in clks if "rst" not in c.lower() and "reset" not in c.lower()}
        _, ports = parse_ports(text)
        bad = []
        for c in sorted(clks):
            if c in KNOWN_CLK:
                continue
            if c in ports:          # 是 input 端口 ⇒ 由外面驱动
                continue
            if re.search(r"assign\s+%s\s*=" % re.escape(c), text) or \
               re.search(r"\b%s\s*<=" % re.escape(c), text):
                continue
            bad.append(c)
        if bad:
            findings += len(bad)
            print("❌ %s: 被当时钟用、却无驱动 ⇒ 那块寄存器永不翻转: %s"
                  % (os.path.relpath(f, ROOT), bad))

    # ---- E: parameter 漏分隔符 ----
    for f, raw in texts.items():
        lines = [l.split("//")[0].rstrip()
                 for l in raw.splitlines()]
        for i, s in enumerate(lines):
            if not re.match(r"\s*parameter\s+", s) or s.rstrip().endswith((";", ",")):
                continue
            j = i + 1
            while j < len(lines) and lines[j].strip() == "":
                j += 1
            if j < len(lines) and re.match(r"\s*parameter\s+", lines[j]):
                findings += 1
                print("❌ %s:%d parameter 后跟 parameter 却没有分隔符: %s"
                      % (os.path.relpath(f, ROOT), i + 1, s.strip()))

    if findings == 0:
        print("✅ 交付体检干净 (%d 个文件)" % len(files))
        return 0
    print("\n共 %d 处 —— 逐条核对; 上面每类都在文档里记了为什么 VCS 不报错。" % findings)
    return 1


if __name__ == "__main__":
    sys.exit(main())
