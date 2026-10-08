#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 mySoC/rtu/rtl/RTU_subsys.v —— **RTU 与它所有对端的连线**。

【范围】(用户 2026-10-09 定)
  属于本层: **RTU 的每一条边** —— RTU↔IDU、RTU↔LSU 全部接死;
            RTU↔IFU / CSR / PRF / 完成口 / difftest 引出成端口
            (那些模块不在本层里, 但**接口是我们的责任**)。
  不属于本层: 其余模块**彼此之间**的连线 —— IFU↔IDU 的取指握手、
            IDU↔执行单元的发射口、LSU↔总线 —— 原样引出去。

【为什么用脚本生成】
  三个模块加起来 270+ 个端口, 手抄必错。而本工程的端口命名约定是
  **同名即同线**, 所以"按名字接线 + 一张例外表"既可靠又好复查 ——
  所有不按名字接的地方都集中在 EXCEPTIONS 里, 一眼能看完。
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "mySoC/rtu/rtl/RTU_subsys.v")

SRC = {
    "u_rtu":     ("mySoC/rtu/rtl/RTU.v",                 "RTU"),
    "u_idu":     ("mySoC/idu_c910/rtl/ct_idu_top.sv",    "ct_idu_top"),
    "u_lsu":     ("mySoC/lsu/rtl/lsu_top.sv",            "lsu_top"),
    "u_adapter": ("mySoC/rtu/rtl/RTU_idu_lsu_adapter.v", "RTU_idu_lsu_adapter"),
}
# 例化时的参数覆盖 (LSU 的默认值就是这些, 显式写出来是为了"几何变了能看见")
PARAMS = {
    "u_lsu": "\n    #(.DCACHE_SIZE (2048),\n"
             "      .LSIQ_ENTRY  (8),\n"
             "      .SQ_ENTRY    (6),\n"
             "      .SDIQ_ENTRY  (4),\n"
             "      .WMB_ENTRY   (4),\n"
             "      .LFB_ADDR_ENTRY(3),\n"
             "      .LFB_DATA_ENTRY(1))",
}

EXCEPTIONS = {
    ("u_rtu", "cpu_clk"): ("cpu_clk", None),
    ("u_rtu", "cpu_rst"): ("cpu_rst", None),
    ("u_idu", "forever_cpuclk"): ("cpu_clk", None),
    ("u_lsu", "forever_cpuclk"): ("cpu_clk", None),
    ("u_idu", "cpurst_b"): ("cpurst_b", "适配层就地反相 (RTU 高有效 / IDU-LSU 低有效)"),
    ("u_lsu", "cpurst_b"): ("cpurst_b", None),
    ("u_adapter", "cpu_clk"): ("cpu_clk", None),
    ("u_adapter", "cpu_rst"): ("cpu_rst", None),
    ("u_idu", "lsu_idu_lsiq_pop_entry"): ("lsu_idu_pop_entry", "交付侧名字少个 lsiq_, 位宽/语义一致"),
    ("u_idu", "lsu_sdiq_has_in_sq_vld"): ("lsu_sdiq_has_in_sq_any", "IDU 要 {vld, 独热}, LSU 只给一个带门控的独热"),
    ("u_idu", "lsu_sdiq_has_in_sq_sdiq"): ("lsu_idu_has_in_sq", None),
    ("u_lsu", "idu_lsu_ld_src"): ("idu_lsu_ld_src0", "交付侧名字多个 0"),
    ("u_lsu", "rtu_yy_xx_flush"): ("rtu_yy_xx_flush", "用适配层合并后的那根, 与 IDU 同源"),
}
DANGLING = {
    ("u_idu", "idu_lsu_st_preg"): "store 不写回, LSU 侧没有对应口",
}
EXTRA_NETS = [
    ("lsu_sdiq_has_in_sq_any", 0, "|lsu_idu_has_in_sq"),
]
# 内部信号里, 只有驱动方在 internal 里的才算真内部
INTERNAL_FORCE = {"rtu_yy_xx_flush", "cpurst_b", "idu_lsu_ld_src0",
                  "lsu_idu_pop_entry", "lsu_idu_has_in_sq"}


GEO = {"DCACHE_SIZE": 2048, "LSIQ_ENTRY": 8, "SQ_ENTRY": 6, "SDIQ_ENTRY": 4,
       "WMB_ENTRY": 4, "LFB_ADDR_ENTRY": 3, "LFB_DATA_ENTRY": 1}


def resolve_width(w):
    """把 `LSIQ_ENTRY-1:0` 这类**参数化位宽**代换成数值 `7:0`。

    ⚠️ 不能把参数名原样留在顶层端口上: 那些参数是**子模块的** (LSU 的几何参数),
    而 Verilog 的端口位宽表达式**不能引用模块体后面才声明的 localparam** ——
    第一版就是这么错的 (报 `Identifier 'LSIQ_ENTRY' has not been declared`)。
    这里只做"已知名字 → 数值"的替换 + 四则运算求值, 不做任意表达式求值。
    """
    if not w:
        return w
    expr = w
    for k, v in GEO.items():
        expr = re.sub(r"\b%s\b" % k, str(v), expr)
    parts = []
    for seg in expr.split(":"):
        seg = seg.strip()
        if not re.fullmatch(r"[0-9+\-*/() ]+", seg):
            return w                      # 里有不认识的东西 ⇒ 原样留着, 让人看见
        parts.append(str(eval(seg)))      # 只含数字与运算符, 安全
    return ":".join(parts)


def width_num(w):
    """把端口位宽串 (如 `6:0` / `LSIQ_ENTRY-1:0`) 算成**位数**。

    ⚠️ `resolve_width` 返回的是 `hi:lo` 字符串, 不能直接 int() —— 第一版就栽在这
    (于是每根内部网都被当成 1 位)。这里负责 hi-lo+1。
    """
    r = resolve_width(w)
    if not r:
        return 1
    if ":" not in r:
        try:
            return int(r)
        except ValueError:
            return None
    try:
        hi, lo = [int(x) for x in r.split(":")]
        return abs(hi - lo) + 1
    except ValueError:
        return None


def parse_ports(path, mod):
    text = re.sub(r"//[^\n]*", "", open(path, encoding="utf-8").read())
    m = re.search(r"^module\s+%s\b.*?^\);" % mod, text, re.S | re.M)
    if not m:
        raise SystemExit("找不到 %s 的端口表" % mod)
    out = []
    for line in m.group(0).splitlines():
        s = line.strip().rstrip(",")
        mm = re.match(r"^(input|output)\s+(?:wire|logic)\s*(?:\[([^\]]*)\]\s*)?(\w+)$", s)
        if mm:
            out.append((mm.group(1), mm.group(2), mm.group(3)))
    return out


def main():
    P = {inst: parse_ports(*f) for inst, f in SRC.items()}

    driven, consumed = {}, {}
    for inst, plist in P.items():
        for d, w, n in plist:
            (driven if d == "output" else consumed).setdefault(n, []).append(inst)
    internal = {n for n in driven if n in consumed} | INTERNAL_FORCE
    internal -= {"cpu_clk", "cpu_rst"}

    topports = {}
    for inst, plist in P.items():
        for d, w, n in plist:
            if n in internal:
                continue
            if n in topports and topports[n][0] != d:
                raise SystemExit("顶层端口方向冲突: %s" % n)
            topports[n] = (d, w)

    if ("u_rtu", "cpu_rst") not in EXCEPTIONS:
        topports.setdefault("cpu_rst", ("input", None))

    L = []
    A = L.append
    A("`timescale 1ns / 1ps")
    A("")
    A("// ---------------------------------------------------------------------------")
    A("// RTU_subsys —— **RTU 与它所有对端的连线**")
    A("//")
    A("// ⚠️ 本文件由 `scripts/gen_rtu_top.py` **生成**, 不要手改 ——")
    A("//    改端口/改接法请改那个脚本再重跑 (`python3 scripts/gen_rtu_top.py`)。")
    A("//    生成的理由: 三个模块加起来 270+ 个端口, 手抄必错; 而本工程的端口命名")
    A("//    约定是**同名即同线**, 所以'按名字接 + 一张例外表'更可靠 ——")
    A("//    所有不按名字接的地方都集中在脚本的 EXCEPTIONS 里, 一眼能看完。")
    A("// ---------------------------------------------------------------------------")
    A("// 【范围】(用户 2026-10-09 定)")
    A("//   * 属于本层: **RTU 的每一条边**")
    A("//       - RTU↔IDU、RTU↔LSU: 全部接死 (经 `RTU_idu_lsu_adapter` + 几根直连)")
    A("//       - RTU↔IFU / CSR / PRF / 完成口 / difftest: 引出成端口 ——")
    A("//         那些模块不在本层里, 但**接口是我们的责任**")
    A("//   * 不属于本层: 其余模块**彼此之间**的连线")
    A("//       - IFU↔IDU 的取指握手 (`ifu_idu_*` / `idu_accept_num` / chk)")
    A("//       - IDU↔执行单元的发射口 (`idu_aiq_*` / `idu_biq_*` / `idu_mult_*` …)")
    A("//       - LSU↔总线 (`rb_biu_*` / `wmb_biu_*` / `vb_biu_*` / `biu_lsu_*` …)")
    A("//     这些原样引出去。")
    A("//")
    A("// 【配置】按 **PREG=64** 使用 (交付的 C910 IDU 的 PRF 是 64 项 / 6 位寻址)。")
    A("//   64 档下 RTU 的 7 位物理号**最高位恒 0** ⇒ 与 IDU 的 6 位口直接相接就对")
    A("//   (Verilog 在端口连接处隐式截掉的那一位正好是 0, 这是**有意的**)。")
    A("//   适配层里有 generate 守卫, 拿 96 档编会在 elaborate 期直接失败。")
    A("// ---------------------------------------------------------------------------")
    A("")
    # 端口位宽里出现过的参数名 (LSU 用的是 Geometry 参数, 顶层要自己声明一份)
    NEEDED_PARAMS = ["DCACHE_SIZE", "LSIQ_ENTRY", "SQ_ENTRY", "SDIQ_ENTRY",
                     "WMB_ENTRY", "LFB_ADDR_ENTRY", "LFB_DATA_ENTRY"]
    used_params = sorted({m for n in topports for m in
                          re.findall(r"[A-Za-z_]\w*", topports[n][1] or "")
                          if m in NEEDED_PARAMS})
    A("module RTU_subsys (")
    keys = sorted(topports.keys())
    for i, n in enumerate(keys):
        d, w = topports[n]
        A("  %-6s wire %s%-38s%s" % (d, ("[%s] " % resolve_width(w)) if w else "", n,
                                     "" if i == len(keys) - 1 else ","))
    A(");")
    A("")
    A("    // ============================================================")
    A("    //  内部连线 (两侧模块之间, 不出本层)")
    A("    // ============================================================")
    # ⚠️ **内部网必须显式写位宽** —— 漏了就是 1 位隐式线网, 连到多位端口时被静默截断。
    #    这正是本项目栽过四次的那类坑 (交付的 IDU 里有 38 根), 生成器也得守同一条规矩。
    #    宽度取"所有连到它的端口里最宽的那个" (通常驱动方就是最宽的; 取 max 是为了
    #    在"驱动 7 位 / 消费 6 位"这种有意为之的截断上也写对 —— 那时网是 7 位,
    #    截断发生在消费侧的端口连接处, 与手写代码的行为一致)。
    netw = {}
    for inst, plist in P.items():
        for d, w, n in plist:
            if n not in internal:
                continue
            if (inst, n) in EXCEPTIONS:
                n = EXCEPTIONS[(inst, n)][0]
            v = width_num(w)
            if v is not None:
                netw[n] = max(netw.get(n, 1), v)
    for n in sorted(internal):
        w = netw.get(n, 1)
        A("    wire %s%-38s;   // 内部" % (("[%d:0] " % (w - 1)) if w > 1 else "", n))
    for n, w, expr in EXTRA_NETS:
        A("    wire %-38s = %s;" % (n, expr))
    A("")
    for inst, (path, mod) in SRC.items():
        A("    // ============================================================")
        A("    //  %s : %s" % (inst, mod))
        A("    // ============================================================")
        A("    %s%s %s (" % (mod, PARAMS.get(inst, ""), inst))
        plist = P[inst]
        lines = []
        for d, w, n in plist:
            if (inst, n) in DANGLING:
                lines.append(("    //  .%-34s (  )" % n, "   // " + DANGLING[(inst, n)]))
                continue
            if (inst, n) in EXCEPTIONS:
                tgt, why = EXCEPTIONS[(inst, n)]
                cmt = ("   // " + why) if why else ""
                lines.append(("    .%-34s (%-34s)" % (n, tgt), cmt))
            else:
                lines.append(("    .%-34s (%-34s)" % (n, n), ""))
        for i, (ln, cmt) in enumerate(lines):
            last = (i == len(lines) - 1)
            # ⚠️ 逗号必须在注释**之前** —— 写成 `.p (s)   // 说明,` 的话逗号会被
            #    注释吃掉, 连接表就少了分隔符 (第一版就是这么错的)。
            A(ln + ("" if last else ",") + cmt)
        A("    );")
        A("")
    A("endmodule")
    open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("写了 %s" % os.path.relpath(OUT, ROOT))
    print("  顶层端口 %d 个 / 内部信号 %d 根 / 例化 %d 个模块"
          % (len(topports), len(internal) + len(EXTRA_NETS), len(SRC)))


if __name__ == "__main__":
    main()
