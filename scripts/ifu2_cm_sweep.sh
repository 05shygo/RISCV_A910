#!/bin/bash
# ifu2 TAGE 几何的 **CoreMark 专用** 并行扫点.
#
# 为什么不用 scripts/ifu2_tage_sweep.sh: 那个是串行的、而且每次跑 branch_bench
# 再跑 CoreMark. 本项目 branch_bench 只当参考, 判据是 CoreMark 的"每单位面积收益",
# 所以这里只跑 CoreMark, 并且**并行**(32 核, 每点独立 BUILD_DIR).
#
# 用法: bash scripts/ifu2_cm_sweep.sh <配置文件> [输出文件]
#   配置行: <名字>  <make 变量...>        '#' 开头与空行跳过.
#
# ⚠️ 三条本工程用血换来的规矩, 都在这里落实:
#   1. **不能给 SIM_ARGS** —— Makefile 里是 `SIM_ARGS ?= ...` 之后 `SIM_ARGS +=
#      -exitstatus`, 命令行赋值会连 `+=` 一起吃掉, 于是 $fatal 也返回 0, 卡死报成
#      PASS. 这里绕过 make run, 直接调 simv 并显式带 -exitstatus.
#   2. **`env -u VERDI_HOME -u NOVAS_HOME`** —— 否则 FSDB_HOME 非空 ⇒ +define+FSDB
#      ⇒ simv 会写 waveform/*.fsdb (共享目录, 会拖慢且可能踩到别人的 Verdi).
#   3. **meminit.* 只链一次, 而且三个都要链** —— `make run` 的 `ln -sf` 是
#      unlink+link, 并发会以 "ln: File exists" 随机失败; 所以这里在**派发之前**
#      一次性把三个 (bin/hex/hex128) 都指到 coremark, 各并行的点不再碰它们.
#      以前只链 bin, 漏掉的两个会让 DUT 跑上一个用例 (见下面的详细说明).
#
# ⚠️ 名字是人写的, 会写错 (第一轮就发生过: 名字叫 L2.5.12 实际没传 L3). 输出里
#    保存 RTL **自己打印**的那行 `[IFU2-TAGE]`, 拿它对名字.

set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
CFG=${1:?用法: $0 <配置文件> [输出文件]}
OUT=${2:-/tmp/cm_sweep.tsv}
MAXCYC=15000000
LOGDIR=/tmp/cm_sweep
mkdir -p "$LOGDIR"

# 三个镜像软链**必须一起**指向 coremark (2026-09-30 修, 见 memory
# sim-image-three-symlinks)。三个宏都在编译期烧进 simv, 各喂一个消费者:
#   meminit.bin    → golden model 的 PATH
#   meminit.hex    → DUT 数据 RAM   (PATHHEX, sync_mem.v:142 的 $readmemh)
#   meminit128.hex → DUT 取指 ROM   (PATH128, sync_mem.v:196 的 $readmemh)
# 以前只链 meminit.bin, 于是本轮扫描跑的是**上一个人留下的 .hex**:
# 上一次跑的是 xori, DUT 就在跑 xori 而参考模型在跑 coremark ⇒ 第 274 拍一个
# difftest 失配, 看起来完全像 RTL 坏了 (实测踩过)。换 cwd 解决不了 —— 宏是
# 绝对路径。hex 由 bin/coremark.bin 现生成, 先确保它存在且比 .bin 新。
env -u VERDI_HOME -u NOVAS_HOME make -C "$ROOT" -s \
    "$ROOT/bin/coremark.hex" "$ROOT/bin/coremark.hex128" >/dev/null 2>&1

for pair in bin/coremark.bin:meminit.bin \
            bin/coremark.hex:meminit.hex \
            bin/coremark.hex128:meminit128.hex; do
    src="$ROOT/${pair%%:*}"; dst="$ROOT/${pair##*:}"
    ln -sf "$src" "$dst"
    if [ "$(readlink -f "$dst")" != "$src" ]; then
        echo "${pair##*:} 软链不对 ($(readlink -f "$dst")), 退出" >&2; exit 1
    fi
done

: > "$OUT"
echo -e "cfg\tarea_bit\tcm_cycles\tretired\tpass\tactual" >> "$OUT"

run_one () {
    local name="$1"; shift
    local bd="$ROOT/obj_cm_$name"
    local log="$LOGDIR/$name.log"

    if ! env -u VERDI_HOME -u NOVAS_HOME make -C "$ROOT" IFU=2 TOP=tb_miniRV_dpi \
            BUILD_DIR="$bd" "$@" build > "$LOGDIR/$name.build.log" 2>&1; then
        echo -e "$name\tBUILD_FAIL\t\t\t\t" >> "$OUT"; return
    fi

    ( cd "$ROOT" && "./obj_cm_$name/simv" +vcs+lic+wait +WAVE=cm_$name \
        +MAX_CYCLES=$MAXCYC -exitstatus -l "$log" > /dev/null 2>&1 )
    local rc=$?

    # 面积/RTL 实际参数从那行 `[IFU2-TAGE] ...` 取 —— 拿不到就是配置没落地.
    local area actual cyc ret pass
    actual=$(grep -o '\[IFU2-TAGE\].*' "$log" | head -1 | sed 's/.*TAB/TAB/')
    area=$(grep -o 'AREA=[0-9]*' "$log" | head -1 | cut -d= -f2)
    [ -z "$area" ] && area="(gshare)"
    cyc=$(grep -oE 'cycles *= *[0-9]+' "$log" | head -1 | grep -oE '[0-9]+')
    ret=$(grep -oE 'retired inst *= *[0-9]+' "$log" | head -1 | grep -oE '[0-9]+')
    pass=$(grep -c 'Test Point Pass' "$log")
    echo -e "$name\t$area\t${cyc:-0}\t${ret:-0}\t$pass\trc=$rc ${actual:-NO_TAGE_LINE}" >> "$OUT"
}

pids=()
while read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    # shellcheck disable=SC2086
    set -- $line
    name=$1; shift
    echo "=== launch $name : $* ===" >&2
    run_one "$name" "$@" &
    pids+=($!)
done < "$CFG"

fail=0
# `${pids[@]+"${pids[@]}"}` 而不是 "${pids[@]}": 脚本是 set -u, 而空配置下
# pids 是空数组 —— bash 4.2 之前 (本机 4.2) 对空数组的 "${pids[@]}" 会报
# "unbound variable" 并跳过整个循环 (不致命, 但输出里多一行莫名其妙的错).
for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || fail=1; done

echo "=== 结果: $OUT (fail=$fail) ===" >&2
sort -t"$(printf '\t')" -k3,3n "$OUT" | column -t -s"$(printf '\t')" >&2
