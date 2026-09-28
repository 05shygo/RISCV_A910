# ===========================================================================
# P0a: 扇出复制实验 (网表侧, 零语义, 不动仓库 RTL)
#
#   用法: vivado -mode batch -source /tmp/p0a_flow.tcl -tclargs <period> <mode>
#     period : 6.5 / 6.9  —— 复用对应 run 已综合好的 synth DCP, 不重新综合
#     mode   : base = 基线复刻 (opt/place/phys_opt/route, 与工程流程一致)
#              pass = 基线 + 3 次空转 phys_opt (对照组: 抵消"多跑 3 轮"本身)
#              repl = 基线 + 3 轮 force_replication_on_nets (只差复制这一项)
#
#   判据: base 复现工程 run 的 WNS (±0.05ns) ⇒ 流程等价; repl 相对 pass 的
#         差值 = 纯扇出复制的收益。
# ===========================================================================
set PERIOD [lindex $argv 0]
set MODE   [lindex $argv 1]

set ROOT  /home/st-wangjun/project/RISCV_A910
set SYNTH [file join $ROOT synth vivado fmax_impl_${PERIOD}ns \
                fmax_impl_${PERIOD}ns.runs synth_1 top_fmax.dcp]
if {![file exists $SYNTH]} { error "缺 synth DCP: $SYNTH" }
set OUT [file join /tmp/p0a fmax_${MODE}_${PERIOD}ns]
file mkdir $OUT

open_checkpoint $SYNTH

# ⚠️ 工程模式下 xdc 挂在 impl 阶段, synth DCP 里**没有约束** —— 不补这一步
#    整个 impl 是无约束跑的 (place/route 不按时序优化, phys_opt 直接空转)。
if {[llength [get_clocks -quiet]] == 0} {
    set XDC [file join $ROOT synth vivado fmax_impl_${PERIOD}ns fmax_gen.xdc]
    if {![file exists $XDC]} { error "缺 xdc: $XDC" }
    read_xdc $XDC
    puts "P0A_XDC loaded $XDC"
}
set per [get_property -quiet PERIOD [get_clocks -quiet clk]]
puts "P0A_CLK dcp_period=$per  expect=$PERIOD"
if {$per eq "" || abs($per - $PERIOD) > 0.01} { error "时钟不对: per=$per expect=$PERIOD" }

proc loads {n} { llength [get_pins -quiet -of $n -filter {DIRECTION == IN}] }

opt_design
place_design
phys_opt_design

if {$MODE ne "base"} {
    set t0 [clock seconds]
    set cand {}
    foreach n [get_nets -hier -quiet] {
        if {[loads $n] < 60} { continue }
        set dp [get_pins -quiet -of $n -filter {DIRECTION == OUT}]
        if {[llength $dp] != 1} { continue }          ;# 多条驱动/总线 → 跳过
        set ref [get_property -quiet REF_NAME [get_cells -quiet -of $dp]]
        if {$ref eq ""} { continue }
        if {[regexp {^(GND|VCC|BUFG|BUFH|BUFR|BUFIO|IBUF|OBUF|BUFGCTRL)} $ref]} { continue }
        lappend cand $n
    }
    puts "P0A_CAND mode=$MODE n=[llength $cand] scan=[expr {[clock seconds]-$t0}]s"
    foreach n $cand { puts [format "P0A_PRE  fo=%-5d %s" [loads $n] $n] }

    for {set i 1} {$i <= 3} {incr i} {
        if {$MODE eq "repl"} {
            if {[catch {phys_opt_design -force_replication_on_nets $cand} err]} {
                puts "P0A_ERR round=$i: $err"
            }
        } else {
            phys_opt_design
        }
        puts "P0A_ROUND $i done t=[expr {[clock seconds]-$t0}]s"
    }
    foreach n $cand { puts [format "P0A_POST fo=%-5d %s" [loads $n] $n] }
}

route_design

set wns  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set fmax [expr {1000.0 / ($PERIOD - $wns)}]

report_timing_summary -delay_type max -max_paths 20 -file [file join $OUT timing_summary.rpt]
report_timing -delay_type max -max_paths 500 -file [file join $OUT timing_paths500.rpt]
report_timing -delay_type max -max_paths 200 -nworst 8 -file [file join $OUT timing_paths_f1.rpt]
report_utilization -file [file join $OUT utilization.rpt]
report_high_fanout_nets -max_nets 40 -timing -file [file join $OUT hf_post.rpt]
write_checkpoint -force [file join $OUT top_fmax_routed.dcp]

puts "TIMING PATHS (top 8):"
foreach p [get_timing_paths -delay_type max -max_paths 8] {
    puts [format "  %8.3f ns  %s -> %s" [get_property SLACK $p] \
        [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
set non_ex ""
foreach p [get_timing_paths -delay_type max -max_paths 300 -nworst 8] {
    if {[string match "*ex_csr_addr*" [get_property STARTPOINT_PIN $p]]} { continue }
    set non_ex $p
    break
}
if {$non_ex ne ""} {
    puts [format "WORST_NON_EX slack=%.3fns  %s -> %s" [get_property SLACK $non_ex] \
        [get_property STARTPOINT_PIN $non_ex] [get_property ENDPOINT_PIN $non_ex]]
}
puts [format "P0A_SUMMARY period=%s mode=%s wns=%.4f fmax_mhz=%.2f" $PERIOD $MODE $wns $fmax]
