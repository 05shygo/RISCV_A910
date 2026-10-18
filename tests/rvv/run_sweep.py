#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tests/rvv/run_sweep.py —— 跑 RVV 逐指令 sweep 并出 PASS/FAIL/HANG 表

依赖:
  * asm/rvv_sweep_<group>.S 与 tests/rvv/manifest_<group>.json
    (由 gen_sweep.py --oracle 生成; 黄金值已嵌入 .S, 运行期不需要 Spike)
  * make a910-run (tb/a910/tb_a910_smoke.sv + axi_slave_128.v)

用法:
  python3 tests/rvv/run_sweep.py                  # 全量
  python3 tests/rvv/run_sweep.py --only ls        # 只跑一组
  python3 tests/rvv/run_sweep.py --verbose        # 每条用例一行
  python3 tests/rvv/run_sweep.py --rebuild        # 先删 obj_a910_sim 强制重编
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SIM_BUILD = os.path.join(ROOT, "obj_a910_sim")
SIM_LOG = os.path.join(SIM_BUILD, "sim.log")
GROUPS = ("alu", "mulmac", "red", "mask", "ls")

NOT_RUN = 0xA5A5A5A5


def run(cmd, env=None, capture=True):
    sys.stdout.write("  $ %s\n" % " ".join(cmd))
    sys.stdout.flush()
    if capture:
        return subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT,
                              universal_newlines=True, env=env)
    return subprocess.run(cmd, cwd=ROOT, env=env)


def parse_log(path):
    progress = None
    phase = None
    status = {}
    traps = None
    expt = ""
    passed = failed = None
    if not os.path.exists(path):
        return None
    for line in open(path, errors="replace"):
        m = re.match(r"\s*RVV_PROGRESS\s+([0-9a-fA-F]+)", line)
        if m:
            progress = int(m.group(1), 16)
        m = re.match(r"\s*RVV_PHASE\s+([0-9a-fA-F]+)", line)
        if m:
            phase = int(m.group(1), 16)
        m = re.match(r"\s*RVV_STATUS\s+(\d+)\s+([0-9a-fA-F]+)", line)
        if m:
            status[int(m.group(1))] = int(m.group(2), 16)
        m = re.match(r"\s*RVV_TRAPS\s+(\d+)", line)
        if m:
            traps = int(m.group(1))
        m = re.match(r"\s*RVV_EXPT\s+(.*)", line)
        if m:
            expt = m.group(1).strip()
        if "A910 SMOKE: PASS" in line:
            passed = True
        if "A910 SMOKE: FAIL" in line:
            failed = True
    return {"progress": progress, "phase": phase, "status": status, "traps": traps,
            "expt": expt, "pass": passed, "fail": failed}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--max-cycles", type=int, default=500000)
    ap.add_argument("--skip-elab", action="store_true")
    ap.add_argument("--variant", choices=("full", "unif"), default="full",
                    help="full=真实 vle 源数据; unif=统一常量 (向量 load 未通时用)")
    args = ap.parse_args()

    unif = (args.variant == "unif")
    suffix = "_unif" if unif else ""
    # 批次列表由 gen_sweep.py 写进 batches.json (每批 <=20 条, 避开已知的
    # idu_accept_num/IBUF 长直线程序 bug)。缺文件时退回按组合名跑老的单文件。
    bfile = os.path.join(HERE, "batches.json")
    groups = []
    if os.path.exists(bfile):
        try:
            groups = json.load(open(bfile)).get(args.variant, [])
        except Exception:
            groups = []
    if not groups:
        if args.only:
            groups = [args.only]
        elif unif:
            groups = ["alu", "mulmac", "red", "mask"]
        else:
            groups = list(GROUPS)
    elif args.only:
        groups = [g for g in groups if g == args.only or g.startswith(args.only + "_")]
    env = dict(os.environ)

    if not shutil.which("vcs"):
        vcs_home = "/mnt/tools/synopsys/vcs/V-2023.12-SP2"
        verdi_home = "/mnt/tools/synopsys/verdi/V-2023.12-SP2"
        env["VCS_HOME"] = vcs_home
        env["VERDI_HOME"] = verdi_home
        env.setdefault("SNPSLMD_LICENSE_FILE", "27000@192.168.50.152")
        env["PATH"] = env.get("PATH", "") + ":" + vcs_home + "/bin:" + verdi_home + "/bin"
        if not shutil.which("vcs", path=env["PATH"]):
            sys.stderr.write(
                "❌ 找不到 vcs。请先 export:\n"
                "  VCS_HOME=/mnt/tools/synopsys/vcs/V-2023.12-SP2\n"
                "  VERDI_HOME=/mnt/tools/synopsys/verdi/V-2023.12-SP2\n"
                "  SNPSLMD_LICENSE_FILE=27000@192.168.50.152\n"
                "  PATH=$PATH:$VCS_HOME/bin:$VERDI_HOME/bin\n")
            return 2

    # 1) 结构检查 + 组装测试镜像
    if not args.skip_elab:
        r = run(["make", "--no-print-directory", "a910-elab"], env=env)
        if r.returncode != 0:
            sys.stdout.write(r.stdout)
            sys.stderr.write("❌ a910-elab 失败\n")
            return 2
        sys.stdout.write(r.stdout)

    # 不跑全局 `make -B asm` —— 那会把仓库里入库的其它用例 .elf/.dump 全重刷。
    # 每个 group 在跑之前单独 -B 重编自己的 .bin/.hex/.hex128。

    # 2) 确保 simv 是当前源码编的 (本机时间戳会乱跳)
    if args.rebuild or not os.path.exists(os.path.join(SIM_BUILD, "simv")):
        if os.path.isdir(SIM_BUILD):
            shutil.rmtree(SIM_BUILD)

    # 3) 逐组跑
    total = {"PASS": 0, "FAIL": 0, "HANG": 0, "NOTRUN": 0, "ENTERED": 0}
    failed_cases = []
    for g in groups:
        mpath = os.path.join(HERE, "manifest_%s%s.json" % (g, suffix))
        if not os.path.exists(mpath):
            sys.stderr.write("❌ 缺 %s —— 先跑 make rvv-sweep-gen\n" % mpath)
            return 2
        man = json.load(open(mpath))
        n = man["n"]

        sim_args = ("+RVV_SWEEP +RVV_PROGRESS_ADDR=%d +RVV_PHASE_ADDR=%d "
                    "+RVV_STATUS_ADDR=%d +RVV_STATUS_N=%d"
                    % (man["progress_addr"], man["phase_addr"],
                       man["status_addr"], n))
        # 只强制重编本 group 的三个镜像文件 (本机时间戳会乱跳)
        tbase = "rvv_sweep_%s%s" % (g, suffix)
        bdir = os.path.join(ROOT, "bin")
        r = run(["make", "--no-print-directory", "-B",
                 os.path.join(bdir, "%s.bin" % tbase),
                 os.path.join(bdir, "%s.hex" % tbase),
                 os.path.join(bdir, "%s.hex128" % tbase)], env=env)
        if r.returncode != 0:
            sys.stdout.write(r.stdout)
            sys.stderr.write("❌ 构建 %s 失败 —— 先生成用例: make rvv-sweep-gen\n"
                             % tbase)
            return 2
        r = run(["make", "--no-print-directory", "a910-run",
                 "TEST=%s" % tbase,
                 "MAX_CYCLES=%d" % args.max_cycles,
                 "A910_SIM_ARGS=%s" % sim_args], env=env)
        # 仿真失败 (超时/自检失败) 也要解析日志
        parsed = parse_log(SIM_LOG)
        if parsed is None:
            sys.stderr.write("❌ %s: 没找到 %s\n" % (g, SIM_LOG))
            return 2

        pg = parsed["progress"]
        res = []
        for c in man["cases"]:
            cid = c["id"]
            st = parsed["status"].get(cid, NOT_RUN)
            if st == 0:
                res.append(("PASS", c))
            elif st == 1:
                res.append(("FAIL", c))
            else:
                if pg == cid:
                    res.append(("HANG", c))
                elif pg is not None and cid < pg:
                    # 超时前已经进过这条用例 (其比对在全局 check pass 里, 没跑到)
                    res.append(("ENTERED", c))
                else:
                    res.append(("NOTRUN", c))
        cnt = {"PASS": 0, "FAIL": 0, "HANG": 0, "NOTRUN": 0, "ENTERED": 0}
        for s, c in res:
            cnt[s] += 1
            if s in ("FAIL", "HANG"):
                failed_cases.append((g, s, c))
        for k in total:
            total[k] += cnt[k]

        # NOTRUN>0 说明超时/提前退出, 不能因为 a0==0 就当 PASS
        verdict = ("PASS" if cnt["FAIL"] == 0 and cnt["HANG"] == 0
                   and cnt["NOTRUN"] == 0 else "FAIL")
        sys.stdout.write("\n[%s] %d cases -> %s  (PASS=%d FAIL=%d HANG=%d "
                         "ENTERED=%d NOTRUN=%d)\n"
                         % (g, n, verdict, cnt["PASS"], cnt["FAIL"],
                            cnt["HANG"], cnt["ENTERED"], cnt["NOTRUN"]))
        if parsed["traps"]:
            sys.stdout.write("  RTU trap 次数=%d, 最近异常: %s\n"
                             % (parsed["traps"], parsed["expt"]))
        if args.verbose or cnt["FAIL"] or cnt["HANG"]:
            for s, c in res:
                if args.verbose or s in ("FAIL", "HANG"):
                    sys.stdout.write("    %-7s [%3d] %s\n" % (s, c["id"],
                                                             c["name"]))
        if cnt["NOTRUN"] and pg is not None:
            phase_txt = {0: "setup/源装载", 1: "被测指令", 2: "结果落内存",
                         3: "标量比对"}.get(parsed["phase"], "?")
            sys.stdout.write("  ⚠️ progress 停在第 %d 条, phase=%s; "
                             "之后 %d 条没跑到\n"
                             % (pg, phase_txt, cnt["NOTRUN"]))
        if r.returncode != 0 and verdict == "PASS":
            sys.stdout.write("  ⚠️ simv 返回 %d 但自检 PASS —— 见 %s\n"
                             % (r.returncode, SIM_LOG))

    sys.stdout.write("\n================ RVV SWEEP SUMMARY ================\n")
    sys.stdout.write("PASS=%d FAIL=%d HANG=%d ENTERED=%d NOTRUN=%d\n"
                     % (total["PASS"], total["FAIL"], total["HANG"],
                        total["ENTERED"], total["NOTRUN"]))
    if failed_cases:
        sys.stdout.write("失败项:\n")
        for g, s, c in failed_cases:
            sys.stdout.write("  %-6s %-8s [%3d] %s\n" % (s, g, c["id"],
                                                        c["name"]))
    sys.stdout.write("===================================================\n")
    return 0 if (total["FAIL"] == 0 and total["HANG"] == 0
                 and total["NOTRUN"] == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
