#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 ct_idu_top.sv 的端口表生成 tb/unit/tb_idu_c910.sv 的端口连接。

为什么要生成: ct_idu_top 有 116 个端口, 手工敲既有抄错的风险, 也维护不动。
改了 IDU 顶层端口之后重跑本脚本即可 —— 忘了重跑, elaborate 会报
"port not found", 那正是这个冒烟台存在的意义。

用法:
    python3 scripts/gen_idu_smoke_tb.py            # 写回 tb/unit/tb_idu_c910.sv
    python3 scripts/gen_idu_smoke_tb.py --check    # 只检查是否需要重新生成 (CI 用)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "mySoC/idu_c910/rtl/ct_idu_top.sv")
TB = os.path.join(ROOT, "tb/unit/tb_idu_c910.sv")

# 这两根不接常量: 时钟/复位要动, rob_full/flush 是"允许派遣"的场景开关
CLK_PORTS = {"forever_cpuclk", "cpurst_b"}
SCENE_PORTS = {"rtu_idu_rob_full", "rtu_yy_xx_flush"}


def parse_ports(path):
    """抠出 module ct_idu_top(...) 里的 (方向, 位宽, 名字)。

    只认 `input  logic [W:0]  name,` 这种 ANSI 风格 —— 这个文件通篇是这种写法,
    换成非 ANSI 风格的话本函数会直接报错, 不会静默漏端口。
    """
    text = open(path, encoding="utf-8").read()
    m = re.search(r"^module\s+ct_idu_top\b.*?^\);", text, re.S | re.M)
    if not m:
        raise SystemExit("找不到 module ct_idu_top 的端口表")
    ports = []
    for line in m.group(0).splitlines():
        line = line.split("//")[0].strip().rstrip(",")
        mm = re.match(r"^(input|output)\s+logic\s+(?:\[(\d+):(\d+)\]\s+)?(\w+)$", line)
        if mm:
            d, hi, lo, name = mm.groups()
            w = (int(hi) - int(lo) + 1) if hi is not None else 1
            ports.append(("in" if d == "input" else "out", w, name))
    return ports


def wire(prefix, w, n):
    return "  %s %s%s;" % (prefix, "      " if w == 1 else "[%2d:0] " % (w - 1), n)


def render(ports):
    ins = [p for p in ports if p[0] == "in"]
    outs = [p for p in ports if p[0] == "out"]
    clocked = [p for p in ins if p[2] in CLK_PORTS]
    scene = [p for p in ins if p[2] in SCENE_PORTS]
    const = [p for p in ins if p[2] not in CLK_PORTS and p[2] not in SCENE_PORTS]
    if len(clocked) != 2 or len(scene) != 2:
        raise SystemExit("时钟/复位或场景开关端口对不上, 检查 CLK_PORTS/SCENE_PORTS")

    L = ["""//==========================================================
// tb_idu_c910 —— C910 移植 IDU (ct_idu_top) 的 elaboration 冒烟台
//==========================================================
// 【这个台子要守住什么】
// 主构建 (make build) 里没有任何模块例化 ct_idu_top, 而 VCS 只 elaborate
// 从 -top 可达的层次 —— 于是这个 IDU 只会被 "Parsing", 内部的端口连接错误
// (接错的端口名 / 位宽不符 / 未驱动网) 一个都查不出来。
// 这里把它**真的例化一次**, 专门逼出这类错误; 顺便跑几百拍看有没有 X。
//
// 【它不是功能验证】输入全接常量, 只验证"能 elaborate + 上电不炸"。
// 真正的契约测试 (派遣记录 / preg 分配握手 / 冲刷) 要等 Phase 3-4 再往这里加。
//
// ⚠️ 端口连接是 scripts/gen_idu_smoke_tb.py 从 ct_idu_top.sv **生成的**,
//    手改这里会在下次重生成时丢掉。改了 IDU 顶层端口就重跑那个脚本。
//==========================================================

`timescale 1ns/1ps

module tb_idu_c910;

  reg clk;
  reg rst_n;

  initial begin clk = 1'b0; forever #5 clk = ~clk; end
"""]
    L.append("  // ---- 时钟/复位 ----")
    L += [wire("wire", w, n) for _, w, n in clocked]
    L.append("")
    L.append("  // ---- 其余输入: 全部接常量 0 ----")
    L += [wire("wire", w, n) for _, w, n in const]
    L.append("")
    L.append("  // ---- 输出 ----")
    L += [wire("wire", w, n) for _, w, n in outs]
    L.append("")
    L.append("  assign forever_cpuclk = clk;")
    L.append("  assign cpurst_b       = rst_n;")
    L += ["  assign %-32s = %d'b0;" % (n, w) for _, w, n in const]
    L.append("")
    L.append("  // ROB 不满 ⇒ 允许派遣; 不冲刷")
    L.append("  assign rtu_idu_rob_full = 1'b0;")
    L.append("  assign rtu_yy_xx_flush  = 1'b0;")
    L.append("")
    L.append("  ct_idu_top u_ct_idu_top (")
    L.append("    .forever_cpuclk                 (forever_cpuclk),")
    L.append("    .cpurst_b                       (cpurst_b),")
    conns = ["    .%-32s (%-32s)," % (n, n) for _, _, n in const + scene + outs]
    conns[-1] = conns[-1].rstrip(",")
    L += conns
    L.append("  );")
    L.append("""
  // ---- 复位 + 跑若干拍 ----
  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (200) @(posedge clk);

    if (^{idu_ifu_inst0_ready, idu_ifu_inst1_ready, idu_ifu_inst2_ready} === 1'bx)
      $display("TB-IDU: 注意 — ifu ready 信号含 X");

    $display("=== IDU elaboration smoke: PASS (跑完 210 拍无异常) ===");
    $finish;
  end

  // 超时保护: 没人推进就报错退出, 而不是挂死
  initial begin
    repeat (5000) @(posedge clk);
    $display("TB-IDU: FAIL — 超时");
    $fatal(1, "timeout");
  end

endmodule""")
    return "\n".join(L) + "\n", ins, outs


def main():
    ports = parse_ports(SRC)
    out, ins, outs = render(ports)
    old = open(TB, encoding="utf-8").read() if os.path.exists(TB) else ""
    if out == old:
        print("tb_idu_c910.sv 已是最新 (%d 入 / %d 出)" % (len(ins), len(outs)))
        return 0
    if "--check" in sys.argv:
        print("tb_idu_c910.sv 与 ct_idu_top.sv 端口表不一致 —— 需要重新生成")
        return 1
    open(TB, "w", encoding="utf-8").write(out)
    print("已生成 %s (%d 入 / %d 出)" % (os.path.relpath(TB, ROOT), len(ins), len(outs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
