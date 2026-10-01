#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
反向验证 (变异测试) 驱动 —— 证明 asm/ 用例真的能失败。

只看"改完还全绿"是没有说服力的: 一个"改坏了也不报错"的用例等于没测。
本脚本按 scripts/rev_mutations.txt 的清单逐条**故意注入一个错误**, 重新编译,
跑指定用例, 断言它**必须失败**; 跑完自动把文件还原。

三种"被抓到"的签名 (都由 -exitstatus 变成非 0 返回码):
  * Mismatch   逐拍 difftest 失配        (tb:612-617 的 $fatal)
  * TestPoint  用例自检失败 (a0/口 MONITOR) (tb:641-657)
  * Timeout    流水线卡死, 超过 MAX_CYCLES  (tb:667-682)

对 branch_bench / c3_only 这两条,**架构状态比对原理上看不出预测器好坏**
(预测错了会在 EX 纠正, 永远到不了 WB 提交点), 它们的判据是 `+BENCH` 的
逐类统计**有没有动** —— 见清单里的 metric 标记。

⚠️ 三条本工程的规矩 (与 scripts/ifu2_cm_sweep.sh 同源):
  1. 不给 SIM_ARGS: 命令行赋值会连 `+= -exitstatus` 一起吃掉, 卡死会报成 PASS。
     本脚本直接调 simv 并显式带 -exitstatus。
  2. env -u VERDI_HOME -u NOVAS_HOME: 否则加 +define+FSDB, 写共享 waveform/。
  3. meminit.{bin,hex,hex128} 是三个共享软链, 一次只能跑一个用例 (串行)。

用法:
  python3 scripts/rev_check.py              # 跑全部
  python3 scripts/rev_check.py M01 M05      # 只跑指定条目
  python3 scripts/rev_check.py --list       # 只列清单
"""

import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "scripts", "rev_mutations.txt")
BUILD_DIR = os.path.join(ROOT, "obj_rev")
LOG_DIR = "/tmp/rev_check"
IFU = "1"                 # 与 Makefile 默认一致; rv32_ifu_l0_btb 只在 IFU=1 下参与编译
DEF_CYCLES = 1000000
BENCH_TESTS = {"branch_bench", "c3_only"}   # 判据是指标变化, 不是返回码

# 判据用到的 +BENCH 输出行 (tb:454-465 / 2484+)
METRIC_RE = re.compile(r"^\s+(cls\d|total|jal/jalr|mispred)\b.*$")


# --------------------------------------------------------------------------
# 清单解析
# --------------------------------------------------------------------------
class Mut(object):
    def __init__(self, mid, name):
        self.mid, self.name = mid, name
        self.file = None
        self.build = "core"          # core = 整核; unit = 单元单测台 (obj_unit_rtu)
        self.tests = []
        self.note = ""
        self.before = None
        self.after = None

    def __repr__(self):
        return "%s %s (%s)" % (self.mid, self.name, self.file)


def _new_mut(s):
    head = s[4:].split(None, 1)
    return Mut(head[0], head[1] if len(head) > 1 else "")


def parse_manifest(path):
    """块内的一切都当正文 —— 否则 BEFORE 里一行以 `file:` 开头的 Verilog
    会被当成指令吃掉 (清单是给人看的, 不该有这种暗坑)"""
    muts, cur, mode, buf = [], None, None, []
    for line in open(path, encoding="utf-8").read().splitlines():
        s = line.strip()
        if mode == "before":
            if s == "BEFORE":                 # 收尾定界符
                _finish(cur, "before", buf)
                mode, buf = "await_after", []
            else:
                buf.append(line)
            continue
        if mode == "await_after":
            # 只认 `<<<AFTER` 开下一块; 中间的空行/注释一律忽略。
            # (少了这个状态, `<<<AFTER` 本身会被当成 after 块的正文写进 RTL —— 实测踩过,
            #  症状是 VCS 报 `div_pipe.v, 252: token is '<<<'`)
            if s == "<<<AFTER":
                mode, buf = "after", []
            continue
        if mode == "after":
            if s == "AFTER" or s.startswith("### "):
                _finish(cur, "after", buf)
                muts.append(cur)
                cur, mode, buf = None, None, []
                if s.startswith("### "):
                    cur = _new_mut(s)
            else:
                buf.append(line)
            continue
        if s.startswith("### "):
            cur = _new_mut(s)
        elif cur is None:
            continue                      # 文件头注释
        elif s.startswith("file:"):
            cur.file = s.split(":", 1)[1].strip()
        elif s.startswith("build:"):
            cur.build = s.split(":", 1)[1].strip()
        elif s.startswith("tests:"):
            cur.tests = s.split(":", 1)[1].split()
        elif s.startswith("note:"):
            cur.note = s.split(":", 1)[1].strip()
        elif s == "<<<BEFORE":
            mode, buf = "before", []
    if cur is not None:
        if mode:
            _finish(cur, mode, buf)
        muts.append(cur)
    return muts


def _finish(mut, mode, buf):
    """把收集到的行装回 mut; 去掉 AFTER 段尾部空行造成的多余换行差异"""
    if mode == "before":
        mut.before = "\n".join(buf).rstrip("\n") + "\n"
    elif mode == "after":
        mut.after = "\n".join(buf).rstrip("\n") + "\n"


# --------------------------------------------------------------------------
# 注入 / 还原
# --------------------------------------------------------------------------
def body(mut):
    """把清单里的 BEFORE/AFTER (永远是 LF) 折算成**该文件自己的行尾**。

    ⚠️ 必须按字节读写。ifu_rv32i/rtl 那棵树是**混**的: rv32_ifu_bht.v 是 CRLF
       (1714 行), rv32_ifu_l0_btb.v 却是 LF。用文本模式 open() 读写会静默把整个
       CRLF 文件翻成 LF —— `git status` 表现为"整个文件都改了", 实测踩过。"""
    raw = open(os.path.join(ROOT, mut.file), "rb").read()
    txt = raw.decode("utf-8")
    eol = "\r\n" if "\r\n" in txt else "\n"
    b = mut.before.replace("\n", eol) if eol != "\n" else mut.before
    a = mut.after.replace("\n", eol) if eol != "\n" else mut.after
    return raw, txt, b, a


def apply_mut(mut):
    """精确替换; 找不到或找到多处都直接报错 —— 清单会随 RTL 漂移, 必须响亮地失败"""
    raw, txt, b, a = body(mut)
    n = txt.count(b)
    if n != 1:
        raise SystemExit("[%s] 在 %s 里匹配到 %d 次 (要求恰好 1 次) —— 清单已过期, "
                         "请对照当前 RTL 更新 scripts/rev_mutations.txt" % (mut.mid, mut.file, n))
    open(os.path.join(ROOT, mut.file), "wb").write(
        txt.replace(b, a, 1).encode("utf-8"))
    return raw


def restore(mut, raw):
    open(os.path.join(ROOT, mut.file), "wb").write(raw)


# --- 崩溃安全: 本脚本会改工作树里的 RTL。进程被 kill -9 / 掉电时 finally 不执行,
#     所以除了内存里的 orig, 再往磁盘落一份快照, 并提供 --restore 手动还原。
BACKUP = os.path.join(LOG_DIR, "backup")


def snapshot(files):
    for f in sorted(set(files)):
        dst = os.path.join(BACKUP, f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(ROOT, f), dst)


def restore_all(files):
    n = 0
    for f in sorted(set(files)):
        src = os.path.join(BACKUP, f)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(ROOT, f))
            n += 1
    return n


# --------------------------------------------------------------------------
# 编译 / 运行
# --------------------------------------------------------------------------
def env_clean():
    e = dict(os.environ)
    e.pop("VERDI_HOME", None)
    e.pop("NOVAS_HOME", None)
    return e


UNIT_SIMV = os.path.join(ROOT, "obj_unit_rtu", "simv")


def build(tag, kind="core"):
    log = os.path.join(LOG_DIR, "build_%s.log" % tag)
    if kind == "unit":
        # 只编不跑: rtu-unit 那条规则会顺带跑仿真, 这里只要 simv。
        # ⚠️ 必须**先删掉 simv**: 本机的文件时间戳会漂到未来 (make 会警告
        #    "has modification time NNN s in the future"), 于是 `make` 认为
        #    simv 比刚改过的 RTL 还新, 直接 "Nothing to be done" —— 变异一条也
        #    没进仿真, 四条全部"幸存"(实测踩过)。
        #   还要清掉 VCS 自己的增量时间戳: 删了 simv 但 VCS 认为"设计没变"
        #   时会直接跳过链接 —— 于是既没有 simv 也不报错, 基线当场 FileNotFound。
        for f in (UNIT_SIMV, UNIT_SIMV + ".daidir/.vcs.timestamp"):
            if os.path.exists(f):
                os.unlink(f)
        # ⚠️ 目标名必须是**绝对路径**: Makefile 里是 `$(PWD)/obj_unit_rtu/simv`,
        #    写成相对名 make 会报 "No rule to make target"。
        cmd = ["make", UNIT_SIMV]
    else:
        cmd = ["make", "IFU=" + IFU, "BUILD_DIR=" + BUILD_DIR, "build"]
    with open(log, "w") as fh:
        rc = subprocess.call(cmd, cwd=ROOT, stdout=fh,
                             stderr=subprocess.STDOUT, env=env_clean())
    return rc


def run_unit(tag, seed=12345678, ninstr=200):
    """单元单测台。判据与整核同构: 不过 -> 非 0 退出 (TB 末尾 $fatal)。
    抓到的签名 = 任意一条 *** FAIL (逐拍比对/不变量/覆盖)。"""
    log = os.path.join(LOG_DIR, "%s_rtu_unit.log" % tag)
    args = [UNIT_SIMV, "+vcs+lic+wait", "+SEED=%d" % seed,
            "+NINSTR=%d" % ninstr, "-exitstatus", "-l", log]
    subprocess.call(args, cwd=ROOT,
                    stdout=open(os.devnull, "w"), stderr=subprocess.STDOUT,
                    env=env_clean())
    txt = open(log, encoding="utf-8", errors="replace").read() if os.path.exists(log) else ""
    return classify_unit(txt), txt, log


def classify_unit(txt):
    if "ALL PASS" in txt:
        return "PASS"
    if "*** FAIL" in txt or "ERRORS" in txt:
        return "TestPoint"
    return "UNKNOWN"


def link_images(test):
    """三个镜像必须一起链 —— 只链 bin 会让 DUT 跑上一个用例 (见 memory
    sim-image-three-symlinks)。

    ⚠️ 还要先确保 .hex/.hex128 是**从当前 .bin 现生成**的。改了 asm/*.S 之后
    只 `make asm`(重建 .bin) 而不重建 .hex 的话, DUT 跑的是旧程序、参考模型跑的
    是新程序 —— 症状是极早的 difftest 失配 (实测: 加了十几条指令后 .data 从
    0x1370 挪到 0x13b0, 在第 1068 拍报 `addi a4` 的结果不对), 看起来完全像
    RTL 坏了。这里的 make 在已是最新时是 no-op。"""
    b = os.path.join(ROOT, "bin", "%s.bin" % test)
    if not os.path.exists(b):
        return False
    subprocess.call(["make", "-s", b[:-4] + ".hex", b[:-4] + ".hex128"],
                    cwd=ROOT, env=env_clean(),
                    stdout=open(os.devnull, "w"), stderr=subprocess.STDOUT)
    for ext, link in (("bin", "meminit.bin"),
                      ("hex", "meminit.hex"),
                      ("hex128", "meminit128.hex")):
        src = os.path.join(ROOT, "bin", "%s.%s" % (test, ext))
        dst = os.path.join(ROOT, link)
        if not os.path.exists(src):
            return False
        if os.path.lexists(dst):
            os.unlink(dst)
        os.symlink(src, dst)
    return True


def run_test(test, tag, cycles=DEF_CYCLES):
    if not link_images(test):
        return None, None, "no image bin/%s.bin" % test
    log = os.path.join(LOG_DIR, "%s_%s.log" % (tag, test))
    args = [os.path.join(BUILD_DIR, "simv"), "+vcs+lic+wait",
            "+WAVE=%s_%s" % (tag, test), "+MAX_CYCLES=%d" % cycles,
            "-exitstatus", "-l", log]
    if test in BENCH_TESTS:
        args.insert(2, "+BENCH")
    subprocess.call(args, cwd=ROOT,
                    stdout=open(os.devnull, "w"), stderr=subprocess.STDOUT,
                    env=env_clean())
    txt = open(log, encoding="utf-8", errors="replace").read() if os.path.exists(log) else ""
    return classify(txt), txt, log


def classify(txt):
    """返回 'PASS' 或三种'被抓'签名之一"""
    if "Timed out" in txt or "exceeded MAX_CYCLES" in txt:
        return "Timeout"
    if "Mismatch detected" in txt or "Diffrence" in txt:
        return "Mismatch"
    if "Test Point Failed" in txt:
        return "TestPoint"
    if "Test Point Pass" in txt:
        return "PASS"
    return "UNKNOWN"


def metrics(txt):
    return sorted(l.strip() for l in txt.splitlines() if METRIC_RE.match(l))


def is_caught(res):
    """被抓 = 三种签名之一 (非 bench 用例), 或指标动了 (bench 用例)。
    PASS = 变异没被察觉; UNKNOWN = 仿真没跑起来/无 PASS 也无 fatal, 要人看。"""
    return res in ("Mismatch", "TestPoint", "Timeout") or res.startswith("CAUGHT")


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------
def main():
    argv = [a for a in sys.argv[1:]]
    all_muts = parse_manifest(MANIFEST)

    if "--list" in argv:
        for m in all_muts:
            print("%-5s %-38s %-42s %s" % (m.mid, m.name, m.file, " ".join(m.tests)))
        return 0

    if "--restore" in argv:
        n = restore_all([m.file for m in all_muts])
        print("已从快照还原 %d 个文件 (%s)" % (n, BACKUP))
        return 0

    if "--validate" in argv:
        # 不碰 RTL, 只核对每条 BEFORE 在该文件里**恰好出现一次** (按文件自己的行尾)。
        # 改了 RTL 之后先跑这个, 比跑完整矩阵快几个数量级。
        bad = 0
        for m in all_muts:
            if not (m.file and m.tests and m.before and m.after):
                print("!! %s 字段不全" % m.mid); bad += 1; continue
            if m.before == m.after:
                print("!! %s BEFORE == AFTER" % m.mid); bad += 1; continue
            _, txt, b, _ = body(m)
            n = txt.count(b)
            if n != 1:
                print("!! %-5s 在 %s 匹配 %d 次" % (m.mid, m.file, n)); bad += 1
        print("清单校验: %d 条, %s" %
              (len(all_muts), "全部通过" if bad == 0 else "%d 条有问题" % bad))
        return 0 if bad == 0 else 1

    muts = all_muts
    if argv:
        want = set(argv)
        muts = [m for m in muts if m.mid in want]
        if not muts:
            print("没有匹配的条目:", argv)
            return 2

    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(BUILD_DIR, exist_ok=True)
    snapshot([m.file for m in muts])

    print("=" * 78)
    print("反向验证: %d 条变异" % len(muts))
    print("=" * 78)

    # ---- 1) 未变异基线: 每个用到的用例都必须 PASS ----
    all_tests = sorted({t for m in muts for t in m.tests})
    kinds = sorted({m.build for m in muts})
    print("\n[基线] 未变异, 确认这些用例本身是过的: %s" % " ".join(all_tests))
    base = {}
    bad = []
    for k in kinds:
        if build("base_" + k, k) != 0:
            print("基线编译失败 (%s), 退出" % k); return 2
    for t in all_tests:
        if t == "rtu_unit":
            res, txt, _ = run_unit("base")
        else:
            res, txt, _ = run_test(t, "base")
        base[t] = (res, metrics(txt or ""))
        print("   %-14s %s" % (t, res))
        if res != "PASS":
            bad.append(t)
    if bad:
        print("\n!! 基线就有用例不过: %s —— 先修好再来做反向验证" % " ".join(bad))
        return 2

    # ---- 2) 逐条注入 ----
    rows = []
    try:
        rows = run_mutations(muts, base)
    except KeyboardInterrupt:
        print("\n!! 收到中断, 正在还原工作树 ...")
        restore_all([m.file for m in muts])
        print("   已还原。若仍有残留, 跑: python3 scripts/rev_check.py --restore")
        return 130
    # ------------------------------------------------------------------
    print("\n" + "=" * 78)
    print("汇总")
    print("=" * 78)
    print("%-5s %-30s %s" % ("ID", "变异", "结果"))
    print("-" * 78)
    survivors = []
    for m, res, _ in rows:
        summary = ", ".join("%s=%s" % (t, r) for t, r in res.items())
        # 判据是"**任意一条**指定用例抓到" —— 一条变异只需要有一个用例守得住。
        # 逐条的明细仍然全打出来, 因为"是**哪条**用例抓到的"本身就是要记的信息
        # (例如 M12 只有 trap 抓得到, M18 只有 muldiv_edge 抓得到)。
        ok = any(is_caught(r) for r in res.values())
        if not ok:
            survivors.append(m)
        print("%-5s %-30s %s%s" % (m.mid, m.name, summary, "" if ok else "   <== 幸存!"))
    print("-" * 78)
    print("共 %d 条, 全部被抓 %d 条, 幸存 %d 条" %
          (len(rows), len(rows) - len(survivors), len(survivors)))
    if survivors:
        print("\n幸存条目 (假覆盖或纵深防御, 需归因):")
        for m in survivors:
            print("   %s %s" % (m.mid, m.name))
    # 本机 python3 是 3.6.8: 没有 capture_output / text= (都是 3.7+)
    left = subprocess.run(["git", "status", "--porcelain", "--"] +
                          sorted(set(m.file for m in muts)),
                          cwd=ROOT, stdout=subprocess.PIPE,
                          universal_newlines=True).stdout.strip()
    print("\n工作树自检 (被变异过的文件相对 HEAD 的改动):")
    print("   " + (left.replace("\n", "\n   ") if left else "(无)"))
    return 0 if not survivors else 1


def run_mutations(muts, base):
    rows = []
    for m in muts:
        print("\n[%s] %s  (%s)" % (m.mid, m.name, m.file))
        print("      %s" % m.note)
        t0 = time.time()
        orig = apply_mut(m)
        try:
            if build(m.mid, m.build) != 0:
                rows.append((m, {t: "BUILD_FAIL" for t in m.tests}, 0))
                print("      编译失败 —— 变异本身不合法, 记 BUILD_FAIL")
                continue
            results = {}
            for t in m.tests:
                if t == "rtu_unit":
                    res, txt, _ = run_unit(m.mid)
                else:
                    res, txt, _ = run_test(t, m.mid)
                if t in BENCH_TESTS:
                    # 预测器类: 判据是指标有没有动
                    moved = metrics(txt or "") if txt else []
                    res = "CAUGHT(metric)" if moved != base[t][1] else "SURVIVED(metric)"
                results[t] = res
                print("      %-14s %s" % (t, res))
            rows.append((m, results, time.time() - t0))
        finally:
            restore(m, orig)
    return rows


if __name__ == "__main__":
    sys.exit(main())
