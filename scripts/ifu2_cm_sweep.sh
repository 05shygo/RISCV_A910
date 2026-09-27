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
#   3. **meminit.bin 只链一次** —— `make run` 的 `ln -sf` 是 unlink+link, 并发会
#      以 "ln: File exists" 随机失败. 所有点都用 coremark, 镜像本来就同一个.
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

ln -sf "$ROOT/bin/coremark.bin" "$ROOT/meminit.bin"
if [ "$(readlink -f "$ROOT/meminit.bin")" != "$ROOT/bin/coremark.bin" ]; then
    echo "meminit.bin 软链不对, 退出" >&2; exit 1
fi

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
for p in "${pids[@]}"; do wait "$p" || fail=1; done

echo "=== 结果: $OUT (fail=$fail) ===" >&2
sort -t"$(printf '\t')" -k3,3n "$OUT" | column -t -s"$(printf '\t')" >&2
