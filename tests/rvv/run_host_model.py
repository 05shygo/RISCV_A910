#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用主机侧黄金模型跑 RVV sweep 用例 (不需要 VCS/DUT).

每个 bin/rvv_sweep_*.bin 都已嵌入 Spike 生成的黄金值, 程序自己在 phase 4
逐字比较并把失败累加进 a0. 这里只负责:
  1. 从 tests/rvv/manifest_<name>.json 取 progress/phase/status/a0 地址;
  2. 调 obj_gm_host/gm_host_run, 按 rvv_status[] 报出失败用例名.

用法:
  make gm-host                                  # 全量
  python3 tests/rvv/run_host_model.py --only alu
  python3 tests/rvv/run_host_model.py --only ls --full
"""

import argparse
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def find_manifest(test):
    """rvv_sweep_alu_0 -> tests/rvv/manifest_alu_0.json"""
    name = test
    if name.startswith("rvv_sweep_"):
        name = name[len("rvv_sweep_"):]
    path = os.path.join(HERE, "manifest_%s.json" % name)
    return path if os.path.exists(path) else None


def run_one(runner, test, max_inst):
    bin_path = os.path.join(ROOT, "bin", test + ".bin")
    manifest = find_manifest(test)
    if not os.path.exists(bin_path):
        return ("MISSING", test, ["bin 不存在: %s" % bin_path])
    if manifest is None:
        return ("NOMANIFEST", test, ["缺 manifest (先 make rvv-sweep-gen)"])

    with open(manifest) as f:
        m = json.load(f)
    cmd = [runner, bin_path, str(max_inst),
           str(m["progress_addr"]), str(m["phase_addr"]),
           str(m["status_addr"]), str(m["a0_addr"]), str(m["n"])]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       universal_newlines=True)
    fails = []
    halted = False
    for line in p.stdout.splitlines():
        if line.startswith("GM_STATUS:"):
            _, idx, val = line.split()
            i = int(idx)
            name = m["cases"][i]["name"] if i < m["n"] else "?"
            fails.append("case %d (%s) status=%s" % (i, name, val))
        elif "GM_HOST: halted=1" in line:
            halted = True
    if not halted:
        return ("TIMEOUT", test, ["没跑到 ECALL"])
    if p.returncode == 0 and not fails:
        return ("PASS", test, [])
    if not fails:
        fails.append("a0 != 0 (rc=%d)" % p.returncode)
    return ("FAIL", test, fails)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runner", default=os.path.join(ROOT, "obj_gm_host", "gm_host_run"))
    ap.add_argument("--only", default="", help="只跑名字里含该子串的用例")
    ap.add_argument("--max-inst", type=int, default=20000000)
    args = ap.parse_args()

    if not os.path.exists(args.runner):
        sys.exit("缺 host runner: %s (先 make gm-host 或 gcc 编译)" % args.runner)

    tests = sorted(os.path.basename(p)[:-4]
                   for p in glob.glob(os.path.join(ROOT, "bin", "rvv_sweep_*.bin")))
    if args.only:
        tests = [t for t in tests if args.only in t]
    if not tests:
        sys.exit("没有匹配的用例")

    npass = nfail = 0
    bad = []
    for t in tests:
        st, name, fails = run_one(args.runner, t, args.max_inst)
        print("  %-22s %s" % (name, st))
        for f in fails:
            print("      " + f)
        if st == "PASS":
            npass += 1
        else:
            nfail += 1
            bad.append(name)

    print("\n==================== RVV host model ====================")
    print("PASS=%d FAIL=%d" % (npass, nfail))
    if bad:
        print("FAIL: " + ", ".join(bad))
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
