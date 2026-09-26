#!/bin/bash
# ifu2 TAGE 几何扫点 (RTL 侧, 真实负载)
#
# 为什么 C++ 那边扫过了还要在 RTL 再扫一遍: C++ 用的是 SPEC trace, 而本项目
# 的落地基准是 branch_bench 与 CoreMark —— 两者对"表容量"的敏感度完全不同
# (branch_bench 只用到 54/256 行, 加容量等于白加; SPEC 上 4 张表明显赢 3 张表,
# 在 CoreMark 上只差 0.05%)。**默认点以这里的数为准。**
#
# 用法: bash scripts/ifu2_tage_sweep.sh <配置文件> [输出文件]
#   配置文件每行:  <名字>  <make 变量...>
#     gshare                     BP_PRED=0
#     T_r6n4t6g16_L2.5.9.14      BP_PRED=1
#     T_r7n3t5g18_L2.5.10.16     BP_PRED=1 BP_TAGE_AW=7 BP_TAGE_TAG_W=5 BP_GHR_W=18 ...
#   '#' 开头与空行跳过。
#
# ⚠️ 必须**串行**跑: tb 的参考模型按相对路径读 meminit.bin, 而 DUT 走编译期
#    +define+PATH。并发跑不同用例会让两者指到不同镜像, 表现为"第 57 拍就
#    difftest 失配", 看起来像 RTL 坏了 (工程里踩过两次)。
#
# ⚠️ GHR_W <= 18 (25 位 chk 的预算)。越界时 RTL 会在 time 0 打一行
#    `[IFU2-TOP] chk 只有 25 位...` 然后 $fatal —— 别把它当成噪音忽略。

set -u
cd "$(dirname "$0")/.."
CFG=${1:?用法: $0 <配置文件> [输出文件]}
OUT=${2:-/tmp/tage_sweep.tsv}
BUILD=obj_sweep

run_cfg () {
    local name="$1"; shift
    echo "=== $name : $* ===" >&2
    if ! env -u VERDI_HOME -u NOVAS_HOME make IFU=2 TOP=tb_miniRV_dpi \
            BUILD_DIR="$PWD/$BUILD" "$@" build > /tmp/sw_build.log 2>&1; then
        echo -e "$name\tBUILD_FAIL\t\t\t\t\t\t" >> "$OUT"; return
    fi

    # ---- branch_bench ----
    ln -sf "$PWD/bin/branch_bench.bin" meminit.bin
    ./$BUILD/simv +vcs+lic+wait +BENCH +WAVE=sw_bb +MAX_CYCLES=1000000 \
        -exitstatus -l /tmp/sw_bb.log > /dev/null 2>&1
    # 面积从那行 `[IFU2-TAGE] ... AREA=` 取 (运行时打印, 不在编译日志里)。
    # 拿不到就说明配置没落地 —— 那行存在的意义就是这个。
    local area bbcyc bbacc bb3 bb5
    # ⚠️ 名字是**人写的**, 会写错 —— 第一轮就发生过: 某行名字叫 L2.5.12, 实际只
    #    传了 BP_TAGE_L4, L3 悄悄留在默认值 9, 于是那一行和别的配置根本没有可比性。
    #    ⇒ 保存 RTL 自己打印的那行参数, 名字对不上时一眼能看见。
    local tline
    tline=$(grep -o '\[IFU2-TAGE\].*' /tmp/sw_bb.log | head -1 | sed 's/.*TAB/TAB/')
    area=$(grep -o 'AREA=[0-9]*' /tmp/sw_bb.log | head -1 | cut -d= -f2)
    [ -z "$area" ] && area="(gshare)"
    bbcyc=$(grep -oE 'cycles *= *[0-9]+' /tmp/sw_bb.log | head -1 | grep -oE '[0-9]+')
    bbacc=$(grep -oE 'total cond=[0-9]+ mis=[0-9]+ acc=[0-9.]+%' /tmp/sw_bb.log | grep -oE '[0-9.]+%')
    bb3=$(grep -oE 'cls3 cond=[0-9]+ mis=[0-9]+ acc=[0-9.]+%' /tmp/sw_bb.log | grep -oE '[0-9.]+%')
    bb5=$(grep -oE 'cls5 cond=[0-9]+ mis=[0-9]+ acc=[0-9.]+%' /tmp/sw_bb.log | grep -oE '[0-9.]+%')

    # ---- CoreMark ----
    ln -sf "$PWD/bin/coremark.bin" meminit.bin
    ./$BUILD/simv +vcs+lic+wait +WAVE=sw_cm +MAX_CYCLES=15000000 \
        -exitstatus -l /tmp/sw_cm.log > /dev/null 2>&1
    local cmcyc cmret cmok
    cmcyc=$(grep -oE 'cycles *= *[0-9]+' /tmp/sw_cm.log | head -1 | grep -oE '[0-9]+')
    cmret=$(grep -oE 'retired inst *= *[0-9]+' /tmp/sw_cm.log | head -1 | grep -oE '[0-9]+')
    cmok=$(grep -c 'Test Point Pass' /tmp/sw_cm.log)

    echo -e "$name\t$area\t$bbcyc\t$bbacc\t$bb3\t$bb5\t$cmcyc\t$tline" >> "$OUT"
    tail -1 "$OUT" >&2
}

: > "$OUT"
echo -e "cfg\tarea_bit\tbb_cycles\tbb_total\tbb_cls3\tbb_cls5\tcm_cycles\trtl_actual" >> "$OUT"

while read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    # shellcheck disable=SC2086
    set -- $line
    name=$1; shift
    run_cfg "$name" "$@"
done < "$CFG"

echo "=== 结果: $OUT ===" >&2
cat "$OUT" >&2
