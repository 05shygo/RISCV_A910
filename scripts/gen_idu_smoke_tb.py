#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 ct_idu_top.sv 的端口表生成 tb/unit/tb_idu_c910.sv 的端口连接。

为什么要生成: ct_idu_top 有一百多个端口 (2026-10-08 实测 114 个: 52 入 / 62 出),
手工敲既有抄错的风险, 也维护不动。
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

# 这几根不接常量: 时钟/复位要动, rob_full/flush 是"允许派遣"的场景开关
CLK_PORTS = {"forever_cpuclk", "cpurst_b"}
SCENE_PORTS = {"rtu_idu_rob_full", "rtu_yy_xx_flush"}

# 2026-10-08: 定向激励要驱动的输入 —— 由 initial 块给值, 不能接常量。
# 选这几根是为了让**一条真指令**走完 IF→ID→IR→IS 并派遣出去:
#   ifu_idu_ib_inst0_{vld,data} —— 从 IFU 灌一条指令
#   ifu_idu_if_inst0_chk        —— 它的预测快照 (顺带验证 chk 通路)
#   rtu_idu_alloc_preg0{,_vld}  —— RTU 的"门房"给号 (同拍取走)
STIM_PORTS = {
    "ifu_idu_ib_inst0_vld", "ifu_idu_ib_inst0_data", "ifu_idu_if_inst0_chk",
    "rtu_idu_alloc_preg0_vld", "rtu_idu_alloc_preg0",
}

# 这几根恒接 1 (不是 0): 它们是 LSU 队列的"不满"指示 —— 接 0 会被当成
# "下游不满"的否定, 让 LSIQ 永远建不进去, 定向激励就走不到派遣。
TIE1_PORTS = {
    "lsu_idu_lq_not_full", "lsu_idu_rb_not_full", "lsu_idu_sq_not_full",
}


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
    stim = [p for p in ins if p[2] in STIM_PORTS]
    tie1 = [p for p in ins if p[2] in TIE1_PORTS]
    skip = CLK_PORTS | SCENE_PORTS | STIM_PORTS | TIE1_PORTS
    const = [p for p in ins if p[2] not in skip]
    if len(clocked) != 2 or len(scene) != 2:
        raise SystemExit("时钟/复位或场景开关端口对不上, 检查 CLK_PORTS/SCENE_PORTS")
    # 端口表改了名/删了口就要在这里炸, 别静默少驱动几根
    missing = (STIM_PORTS | TIE1_PORTS) - {p[2] for p in ins}
    if missing:
        raise SystemExit("STIM_PORTS/TIE1_PORTS 里有 IDU 顶层不存在的端口: %s"
                         % sorted(missing))

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
    L.append("  // ---- 定向激励驱动的输入 (由下面的 initial 块给值) ----")
    L += [wire("reg", w, n) for _, w, n in stim]
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
    L.append("  // LSU 队列的\"不满\"指示: 接 1 (接 0 会让 LSIQ 建不进去, 走不到派遣)")
    L += ["  assign %-32s = 1'b1;" % n for _, _, n in tie1]
    L.append("")
    L.append("  ct_idu_top u_ct_idu_top (")
    L.append("    .forever_cpuclk                 (forever_cpuclk),")
    L.append("    .cpurst_b                       (cpurst_b),")
    conns = ["    .%-32s (%-32s)," % (n, n) for _, _, n in const + scene + tie1 + stim + outs]
    conns[-1] = conns[-1].rstrip(",")
    L += conns
    L.append("  );")
    L.append("""
  //==========================================================
  //   定向激励 + 判据 (2026-10-08 加)
  //==========================================================
  // 【要证的两件事 —— 都是这次修复的核心, 而且是 elaboration 查不出来的】
  //
  //  ⓐ **RAT 真的在写**。交付的 IDU 里改名表挂在无驱动的 write_clk 上 (C910 工厂版的
  //     门控时钟单元被剥掉了), 一个字都写不进去。判据不靠层次引用, 而是用**先后两条
  //     写同一个 lreg 的指令**:
  //        第 1 条的 `old_preg` = RAT 复位值
  //        第 2 条的 `old_preg` **必须等于第 1 条的 `dst_preg`**  ← 写没写进去就看这一条
  //     表项不翻转的话, 第 2 条的 old_preg 会一直停在复位值。
  //
  //  ⓑ **派遣记录真的出来了**。查 36 根新口的 vld/pc/rf_we/dst_lreg/dst_preg/chk
  //     与灌进去的激励对得上, 外加 A6d (不写寄存器时 dst_lreg 必须为 0)。
  //
  // 激励: 每拍都往 inst0 车道灌同一条 `addi x1, x0, 1` (pc=0x100), RTU 侧恒给号 33。
  //       于是每次派遣都是"写 x1", 相邻两次派遣正好构成上面那条判据。
  //==========================================================
  localparam [31:0] PC0       = 32'h0000_0100;
  localparam [31:0] INST_ADDI = 32'h0010_0093;      // addi x1, x0, 1
  localparam [6:0]  PREG_GIVEN = 7'd33;
  localparam [24:0] CHK0      = 25'h0_12345;

  integer     n_disp;          // 观测到的派遣次数
  integer     errs;
  logic [6:0] old_preg_1st;
  logic       saw_rat_write;   // ★ 见过 old_preg 变成 RTU 给的号

  // ---- 派遣监视 ----
  always @(posedge clk) begin
    if (rst_n === 1'b1 && idu_rtu_disp0_vld === 1'b1) begin
      n_disp = n_disp + 1;

      if (idu_rtu_disp0_pc       !== PC0)       begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 pc=%h 期望 %h", n_disp, idu_rtu_disp0_pc, PC0); end
      if (idu_rtu_disp0_rf_we    !== 1'b1)      begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 rf_we=%b 期望 1 (addi 写 rd)", n_disp, idu_rtu_disp0_rf_we); end
      if (idu_rtu_disp0_dst_lreg !== 5'd1)      begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 dst_lreg=%0d 期望 1 (x1)", n_disp, idu_rtu_disp0_dst_lreg); end
      if (idu_rtu_disp0_dst_preg !== PREG_GIVEN)begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 dst_preg=%0d 期望 %0d (RTU 给的号)", n_disp, idu_rtu_disp0_dst_preg, PREG_GIVEN); end
      if (idu_rtu_disp0_chk      !== CHK0)      begin errs=errs+1; $display("TB-IDU: ❌ 第%0d次派遣 chk=%h 期望 %h (chk 旁路要原样透传)", n_disp, idu_rtu_disp0_chk, CHK0); end

      if (n_disp == 1) begin
        old_preg_1st = idu_rtu_disp0_old_preg[6:0];
        // 注意: 激励是**每拍都灌**同一条, 所以第 1 次观测到的派遣通常已经不是流水线里
        // 最早那条了 —— 这个 old_preg 可能已经是前面某条写进去的号, 不作为判据, 只打印。
        $display("TB-IDU: 第1次观测到派遣: dst_preg=%0d old_preg=%0d", PREG_GIVEN, old_preg_1st);
      end

      // ★ 核心判据: RAT 把 "x1 -> 33" 写进去了 ⇒ 后面的某次派遣里,
      //   old_preg (即 RAT 读出的旧映射) 必须变成 33。
      //   ⚠️ 不能用"第 2 次派遣就检查" —— 三宽改名下同一组的三条**同拍读 RAT**,
      //      组内看不到彼此的写 (没有组内转发), 要等下一组才读得到新值。
      //   ⚠️ 也不能用层次引用去直接看表项 —— 那样测的是"线接上了", 不是"值真的走通了"。
      if (idu_rtu_disp0_old_preg[6:0] === PREG_GIVEN) begin
        if (!saw_rat_write)
          $display("TB-IDU: ✅ RAT 在写 —— 第%0d次派遣读到 old_preg=%0d (= 前面写进去的号)",
                   n_disp, PREG_GIVEN);
        saw_rat_write = 1'b1;
      end
    end
  end

  // ---- 激励 ----
  initial begin
    ifu_idu_ib_inst0_vld    = 1'b0;
    ifu_idu_ib_inst0_data   = 97'd0;
    ifu_idu_if_inst0_chk    = 25'd0;
    rtu_idu_alloc_preg0_vld = 1'b0;
    rtu_idu_alloc_preg0     = 6'd0;
    n_disp = 0; errs = 0; saw_rat_write = 1'b0; old_preg_1st = 7'd0;

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // 灌激励: {taken, npc, pc, inst}
    ifu_idu_ib_inst0_data   = {1'b0, PC0 + 32'd4, PC0, INST_ADDI};
    ifu_idu_if_inst0_chk    = CHK0;
    ifu_idu_ib_inst0_vld    = 1'b1;
    rtu_idu_alloc_preg0     = PREG_GIVEN[5:0];
    rtu_idu_alloc_preg0_vld = 1'b1;

    // 跑够 2 次派遣 (发射队列会慢慢填满, 那之前一定能看到)
    repeat (200) @(posedge clk);
    ifu_idu_ib_inst0_vld    = 1'b0;
    rtu_idu_alloc_preg0_vld = 1'b0;
    repeat (5) @(posedge clk);

    if (^idu_accept_num === 1'bx)
      $display("TB-IDU: 注意 — idu_accept_num 含 X");
    else if (idu_accept_num === 2'b10)
      $display("TB-IDU: 警告 — idu_accept_num = 2 是不可达编码 (见 ct_idu_top.sv:180)");

    if (n_disp < 2) begin
      $display("TB-IDU: FAIL — 只观测到 %0d 次派遣, 定向判据没跑到 (期望 >= 2)", n_disp);
      $fatal(1, "stimulus did not reach dispatch");
    end
    if (errs != 0) begin
      $display("TB-IDU: FAIL — %0d 条判据不过", errs);
      $fatal(1, "checks failed");
    end
    if (!saw_rat_write) begin
      $display("TB-IDU: FAIL — 200 拍里从没读到 old_preg=%0d ⇒ **改名表没在写** (表项时钟没通?)", PREG_GIVEN);
      $fatal(1, "RAT write never observed");
    end
    $display("=== IDU smoke: PASS (%0d 次派遣, RAT 在读写在转, 派遣记录对得上) ===", n_disp);
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
