#!/bin/bash
# 误预测归因 (M2PROBE) 的 CoreMark 并行跑.
#
# 目的: 回答"BTB 扩容那 0.9% 到底是**少误预测**还是**少气泡**".
#   这条决定 BTB 的收益在**乱序化之后**是否还成立 ——
#   乱序会把误预测代价放大 (1.07 -> ~10 拍, 见 ooo-score-5-projection),
#   却会把 fetch bubble 吸收掉。两者在乱序下的命运相反。
#
# M2PROBE 把条件/JAL 的误预测拆成:
#   条件分支: "BTB 没这条" (要容量/CAM) vs "BTB 有、方向错" (要历史/索引)
#   JAL/JALR : "BTB 没这条" vs "BTB 有、目标错"
# ⚠️ 该探针的位号跟着 RTL 参数走 (层次化引用 CHK_BTBHIT/CHK_PREDTK), 曾经因为写死
#    位号而静默失效过一次 —— 换 GHR_W 后务必先看这两行数是否非零。
#
# 用法: bash scripts/ifu2_cm_attrib.sh <配置文件> [输出文件]
#   配置行: <名字>  <make 变量...>

set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
CFG=${1:?用法: $0 <配置文件> [输出文件]}
OUT=${2:-/tmp/cm_attrib.tsv}
MAXCYC=15000000
LOGDIR=/tmp/cm_attrib
mkdir -p "$LOGDIR"

ln -sf "$ROOT/bin/coremark.bin" "$ROOT/meminit.bin"

: > "$OUT"
echo -e "cfg\tcm_cycles\tbubble\tcond\tcond_mis\tcond_nobtb\tcond_dir\tjmp\tjmp_mis\tjmp_nobtb\tjmp_tgt" >> "$OUT"

run_one () {
    local name="$1"; shift
    local bd="$ROOT/obj_at_$name"
    local log="$LOGDIR/$name.log"

    if ! env -u VERDI_HOME -u NOVAS_HOME make -C "$ROOT" IFU=2 TOP=tb_miniRV_dpi \
            BUILD_DIR="$bd" VCS_FLAGS_EXTRA=+define+M2PROBE "$@" build \
            > "$LOGDIR/$name.build.log" 2>&1; then
        echo -e "$name\tBUILD_FAIL" >> "$OUT"; return
    fi

    ( cd "$ROOT" && "./obj_at_$name/simv" +vcs+lic+wait +WAVE=at_$name +BENCH \
        +MAX_CYCLES=$MAXCYC -exitstatus -l "$log" > /dev/null 2>&1 )

    local f
    f() { grep -oE "$1" "$log" | head -1 | grep -oE '[0-9]+'; }
    local cyc bub cond cmis cnob cdir jmp jmis jnob jtgt
    cyc=$(f 'cycles *= *[0-9]+')
    bub=$(f 'fetch bubble *= *[0-9]+')
    cond=$(  awk '/条件分支 :/{print $4}' "$log" | tr -d ',')
    cmis=$(  awk '/条件分支 :/{print $7}' "$log" | tr -d ',')
    cnob=$(  awk '/BTB 没这条分支/{print $6}' "$log" | tr -d ',')
    cdir=$(  awk '/BTB 有、方向猜错/{print $6}' "$log" | tr -d ',')
    jmp=$(   awk '/JAL\/JALR :/{print $4}' "$log" | tr -d ',')
    jmis=$(  awk '/JAL\/JALR :/{print $7}' "$log" | tr -d ',')
    jnob=$(  awk '/JAL\/JALR/{getline; print $6}' "$log" | tr -d ',')
    jtgt=$(  awk '/JAL\/JALR/{getline; print $10}' "$log" | tr -d ',')

    echo -e "$name\t${cyc:-0}\t${bub:-0}\t${cond:-0}\t${cmis:-0}\t${cnob:-0}\t${cdir:-0}\t${jmp:-0}\t${jmis:-0}\t${jnob:-0}\t${jtgt:-0}" >> "$OUT"
}

pids=()
while read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    # shellcheck disable=SC2086
    set -- $line
    name=$1; shift
    echo "=== launch $name ===" >&2
    run_one "$name" "$@" &
    pids+=($!)
done < "$CFG"
for p in "${pids[@]}"; do wait "$p"; done

echo "=== 结果: $OUT ===" >&2
column -t -s"$(printf '\t')" "$OUT" >&2
