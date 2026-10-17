# ---------------------------------------------------------------------------
# 把 VCS 编译日志里的警告按"归属"分类（供 make a910-elab 的门禁计数用）。
#
# 用法:
#   awk -f scripts/elab_warn_count.awk <vcs.log>
# 输出一行五个整数:
#   <A910 IWNF> <A910 DCTTSW> <A910_cpu.sv 的 PCWM-W> <RVV 警告总数>
#   <其余 A910 文件的 PCWM-W>
#
# 归属判据: 一个 Warning 块里第一个带引号的源文件路径。
#   * mySoC/design/ 下（含 design/inc 的头文件） = RVV 上游代码, 不参与门禁;
#   * 其余（mySoC/ 自己的 RTL 等）              = A910 侧。
#
# 门禁口径与改动前保持一致: PCWM-W 只门禁 A910_cpu.sv 里的（位宽差应全部显式
# 落在适配层）。其余 A910 文件已有的 PCWM-W（当前是 ct_biu_top.sv 的
# ifu_biu_rid 4→1）是 S0 之前的基线, 只打印、不门禁; 新增的仍会被打印出来。
#
# 为什么要这样分: S0 把 coralnpu RVV 的 49 个设计文件并进了同一个 VCS 文件表。
# 上游既有的警告不能把 A910 的门禁染红, 否则每个阶段都会"红", 门禁就失效了。
# ---------------------------------------------------------------------------
function flush() {
    if (wtype != "" && wpath != "") {
        if (wpath ~ /(^|\/)mySoC\/design\//) {
            rvv++
        } else if (wtype == "IWNF") {
            a_iwnf++
        } else if (wtype == "DCTTSW") {
            a_dcttsw++
        } else if (wtype == "PCWM-W") {
            if (wpath ~ /(^|\/)A910_cpu\.sv$/) {
                a_pcwm_cpu++
            } else {
                a_pcwm_other++
            }
        }
    }
    wtype = ""
    wpath = ""
}

/^Warning-\[/ {
    flush()
    wtype = $0
    sub(/^Warning-\[/, "", wtype)
    sub(/\].*/, "", wtype)
    next
}

{
    if (wtype != "" && wpath == "") {
        line = $0
        while (match(line, /"[^"]+"/)) {
            p = substr(line, RSTART + 1, RLENGTH - 2)
            if (p ~ /\.(sv|svh|v|vh)$/) {
                wpath = p
                break
            }
            line = substr(line, RSTART + RLENGTH)
        }
    }
}

END {
    flush()
    printf "%d %d %d %d %d\n", a_iwnf, a_dcttsw, a_pcwm_cpu, rvv, a_pcwm_other
}
