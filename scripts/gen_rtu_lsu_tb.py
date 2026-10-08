#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 RTU + LSU 联合仿真台的**端口骨架** (tb/unit/tb_rtu_lsu.sv)。

为什么要生成: lsu_top 有 200 多个端口, 手抄必错 —— 而端口连错在 VCS 里是
"elaborate 报 port not found" 或者更糟的**静默接错**(位宽对得上、语义错了)。
本脚本从 lsu_top.sv 的端口表直接生成 `logic` 声明 + `.port(sig)` 连接。

⚠️ 生成的只是**骨架**: 所有输入一律初始化成 0 (除了总线仲裁 grant 那几根给 1,
   否则 LSU 永远拿不到总线), 刺激由人手写在 `// ==== 刺激 ====` 之后。
⚠️ RTU 那侧的端口**不生成** —— 它的契约在 doc/rtu_plan_zh.md §6, 手写更清楚,
   而且 RTU↔LSU 那 16 根线正是这个台子要验的东西, 必须显式连。

用法: python3 scripts/gen_rtu_lsu_tb.py    (输出到 stdout, 重定向到 tb/unit/)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LSU_TOP = os.path.join(ROOT, "mySoC/lsu/rtl/lsu_top.sv")
RTU_TOP = os.path.join(ROOT, "mySoC/rtu/rtl/RTU.v")
RTU_PARAMS = {"RTU_ROB_DEPTH": 64, "RTU_NUM_PREG": 96}

# 顶层参数: 生成里直接写死调用方给的档 (与 Makefile 的 DCACHE_SIZE 同口径)
PARAMS = {"SQ_ENTRY": 6, "LSIQ_ENTRY": 12, "SDIQ_ENTRY": 4,
          "WMB_ENTRY": 4, "LFB_ADDR_ENTRY": 3, "LFB_DATA_ENTRY": 1,
          "DCACHE_SIZE": 2048, "IID_WIDTH": 7}

re_port = re.compile(
    r"^\s*(input|output)\s+(?:logic|wire)\s*(\[[^\]]*\])?\s*([A-Za-z_]\w*)\s*,?\s*(?://.*)?$")


def parse_ports(path, modname):
    ports, in_list = [], False
    for line in open(path, encoding="utf-8", errors="ignore"):
        if not in_list:
            if re.match(r"^\s*module\s+%s\b" % modname, line):
                in_list = True
            continue
        if re.match(r"^\s*\)\s*;", line):
            break
        m = re_port.match(line)
        if m:
            direction, width, name = m.group(1), m.group(2), m.group(3)
            ports.append((direction, width, name))
    return ports


def width_of(w):
    """[7:0] -> 8;  None -> 1;  [SQ_ENTRY-1:0] -> 参数代入"""
    if not w:
        return 1
    inner = w.strip("[]")
    if ":" not in inner:
        return 1
    msb, lsb = inner.split(":", 1)
    for k, v in PARAMS.items():
        msb = msb.replace(k, str(v))
        lsb = lsb.replace(k, str(v))
    try:
        return int(eval(msb.strip())) - int(eval(lsb.strip())) + 1
    except Exception:
        return None        # 交给调用方手填


# 这些信号**由本台的接线块驱动** (复位桥接 / 总线 grant / 重放或门), 生成块只声明不初始化
NO_INIT = {
    "cpu_rst", "cpurst_b", "lsu_replay_vld",
    # ⚠️ **两个时钟必须在这里** (2026-10-08 修的): 生成块对每个非 NO_INIT 输入都发
    # `initial x = 0;`, 而接线块原来只桥了复位 —— 于是 RTU 的 `cpu_clk` 与 LSU 的
    # `forever_cpuclk` **全程恒 0**, 两个 DUT 一个寄存器都不翻。症状是 `rtu-lsu-unit`
    # 在第 3 步 `fork ... join_any` 上**永久挂死** (LSU 不动 ⇒ 既没有 AR 也没有完成),
    # 而且因为本台原来没有自检, "挂死"与"跑完没事"在日志上长得一样 —— 更要命的是
    # RTU 也没动: `occ_q` 全程 0、`retire_cnt` 全程 0, 即本台号称要验的那条链
    # (完成 → 退休 → 提交广播 → LSU 表项 cmit) **一次都没发生过**。
    "cpu_clk", "forever_cpuclk",
    "bus_arb_rb_ar_grnt", "bus_arb_rb_ar_sel",
    "bus_arb_wmb_aw_grnt", "bus_arb_wmb_w_grnt",
    "bus_arb_vb_aw_grnt", "bus_arb_vb_w_grnt",
    "biu_lsu_r_data", "biu_lsu_r_id", "biu_lsu_r_last", "biu_lsu_r_resp", "biu_lsu_r_vld",
}
# RTU 例化里这几个口要接 LSU 的信号 (默认是自环, 这里覆盖掉)
# ⚠️ 完成口接的是**本台过闸后**的线 (`rt_cmplt_*`), 不是 LSU 的裸输出 —— 为什么:
#    LSU 的 load AG 在"IDU 什么都没给"的时候会自由跑一个 restart 环
#    (`lsu_ld_ag.sv:191-198`: `inst_vld <= (stall_ori && !ld_sel) || ld_sel`, 而
#    `stall_ori = !dcache_arb_ag_ld_sel` ⇒ 空闲时每 2 拍翻一次), 于是
#    `ld_da_wb_cmplt_req → pipe3_cmplt` 上**从复位起就周期性出现 iid 为垃圾的完成**。
#    真机里 IDU 一直有真指令、且完成只属于真指令, 本台没有 IDU 就得自己过这道闸,
#    否则 RTU 会被垃圾完成标错表项 (iid 撞上在途表项 ⇒ 假退休)。
#    闸门见接线块里的 `rt_cmplt_vld5/6`。
RTU_CONN_OVERRIDE = {
    "cmplt_vld5": "rt_cmplt_vld5",
    "cmplt_iid5": "lsu_rtu_wb_pipe3_iid",
    "cmplt_vld6": "rt_cmplt_vld6",
    "cmplt_iid6": "lsu_rtu_wb_pipe4_iid",
    "lsu_replay_iid": "lsu_rtu_wb_pipe4_iid",
}

# LSU 的这几个输入**由 RTU 的输出驱动** (同名), LSU 那半不声明、只连接
WIRED_FROM_RTU = {
    "rtu_yy_xx_commit0", "rtu_yy_xx_commit1", "rtu_yy_xx_commit2",
    "rtu_yy_xx_commit0_iid", "rtu_yy_xx_commit1_iid", "rtu_yy_xx_commit2_iid",
    "rtu_yy_xx_flush", "rtu_lsu_async_flush",
}


def emit(modname, path, inst, params=None, skip=()):
    """发一个模块的声明 + 例化 (输入 logic 且置 0, 输出 wire)"""
    ports = parse_ports(path, modname)
    if not ports:
        sys.exit("解析 %s 失败: 没抓到端口" % modname)
    L = ["    // ============ %s 端口 (生成, 勿手改) ============" % modname]
    for d, w, n in ports:
        if n in skip:
            continue
        wd = width_of(w)
        if wd is None:
            sys.exit("宽度解析不出: %s (%s)" % (w, n))
        rng = "" if wd == 1 else "[%d:0] " % (wd - 1)
        kind = "logic" if d == "input" else "wire "
        L.append("    %s %-16s %s;" % (kind, rng, n))
    # 输入统一置 0 (LSU 的总线 grant 那几根由调用方事后改 1)
    for d, w, n in ports:
        if d == "input" and n not in NO_INIT and n not in skip:
            L.append("    initial %s = %s;" % (n, "0" if width_of(w) == 1
                                               else "'0"))
    L.append("")
    conn = RTU_CONN_OVERRIDE if modname == "RTU" else {}
    pstr = ""
    if params:
        pstr = " #(" + ", ".join(".%s(%s)" % (k, v) for k, v in params.items()) + ")"
    L.append("    %s%s %s (" % (modname, pstr, inst))
    for d, w, n in ports:
        L.append("        .%-28s (%s)," % (n, conn.get(n, n)))
    L[-1] = L[-1][:-1]
    L.append("    );")
    print("// %s: %d 个端口" % (modname, len(ports)), file=sys.stderr)
    return "\n".join(L)


def main():
    print(emit("lsu_top", LSU_TOP, "u_lsu", PARAMS, skip=WIRED_FROM_RTU))
    print()
    print(emit("RTU", RTU_TOP, "u_rtu", skip=WIRED_FROM_RTU))
    print()
    print("""    // ============ 本台接线 (时钟 / 复位桥接 / 总线 grant / 重放或门) ============
    // ⚠️ 本台的 TB 内部信号**先声明** (VCS 对"先用后声明"直接报
    //    `Identifier has not been declared yet`, 不是退化成隐式线网 —— 但两种都别踩)
    logic        ld_inflight = 1'b0;   // 我们那条 load 在途 (激励置, 完成回报后清)
    logic [6:0]  ld_iid      = 7'd0;   // 它的 iid (派遣那拍从 rtu_disp_iid0 采回)

    // ⚠️ **时钟必须先接上** (2026-10-08 修): RTU 的时钟口叫 `cpu_clk`、LSU 的叫
    // `forever_cpuclk` (= lsu_top.sv:50 唯一的时钟输入), 两边都接本台的 `clk`。
    // 不接的后果见 NO_INIT 上面那段注释 (挂死 + 整条链根本没跑)。
    assign cpu_clk        = clk;
    assign forever_cpuclk = clk;
    // 复位: RTU 高有效、LSU 低有效 => 取反 (照 mySoC/ifu_subsys.v:111 的先例)
    assign cpu_rst  = rst;
    assign cpurst_b = ~rst;

    // ---- 完成口过闸 (只放行"我们自己派出去的那条"的完成) ----
    // 为什么需要: 见 RTU_CONN_OVERRIDE 上面的长注 (LSU 空闲时 pipe3_cmplt 上会有
    // iid 为垃圾的完成)。三个条件缺一不可:
    //   ① `ld_inflight` 我们这条在途 (激励置/清, 保证完成不会在窗口外漏进来);
    //   ② iid 相等 —— 尾段把 `lch_entry` 一直举着, AG 的 restart 环带的就是**我们**
    //      这条 (数据寄存器里锁的就是它), 所以"我们 iid 的完成"不会是别人的。
    assign rt_cmplt_vld5 = lsu_rtu_wb_pipe3_cmplt & ld_inflight
                                                & (lsu_rtu_wb_pipe3_iid == ld_iid);
    // 本台不造 store ⇒ store 完成口恒 0 (别让 st_wb 的相位信号假报完成)
    assign rt_cmplt_vld6 = 1'b0;
    // 总线仲裁: **与对应 req 同拍给 grant/sel** (不是"永远预授权") ——
    // 侦察结论: `sel` 与 `grnt` 必须同拍为高, LFB 地址表项才会建 (lsu_lfb.sv:277);
    // 而 grnt 还兼作 rb 表项的推进 (lsu_mshr_entry.sv:443)。本台不建模仲裁器,
    // 直接"有请求就授权"。
    assign bus_arb_rb_ar_grnt  = rb_biu_ar_req;
    assign bus_arb_rb_ar_sel   = rb_biu_ar_req;
    assign bus_arb_wmb_aw_grnt = wmb_biu_aw_req;
    assign bus_arb_wmb_w_grnt  = wmb_biu_w_req;
    assign bus_arb_vb_aw_grnt  = 1'b0;      // 本台不测 VB (victim buffer)
    assign bus_arb_vb_w_grnt   = 1'b0;
    // store 重放: LSU 的两根**或**起来送进 RTU (语义见 RTU 的端口注释)
    assign lsu_replay_vld = lsu_rtu_wb_pipe4_flush | lsu_rtu_wb_pipe4_spec_fail;
    // LSU 的冲刷口名字与 RTU 的不同名, 需要显式接 (其余 7 根同名, 靠连线自动对上)
    assign rtu_yy_xx_flush = rtu_backend_flush;
    // 释放否决掩码 (2026-10-08, 第 5 态): 本台**不建模** IDU 的 SDIQ, 由生成器
    // 统一给 `initial preg_dealloc_mask = '0` (即"没有任何号被 store 引用"), 所以
    // 这个台上的释放都是"挂一拍 RELEASE 就回池"。要测押住请用 rtu-unit 的
    // `+MASKDIR` / `+MASKPCT=n` —— 那里才有参考模型与判据。""")
    print()   # 与手写的尾段 (假 BIU / 激励) 之间留一个空行


if __name__ == "__main__":
    main()
