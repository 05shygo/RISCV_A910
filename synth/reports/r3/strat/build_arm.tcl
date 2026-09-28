# 用法: -tclargs <period> <arm>   arm = merge | ffo | incr
set PERIOD [lindex $argv 0]
set ARM    [lindex $argv 1]
set ROOT   /home/st-wangjun/project/RISCV_A910
set SYNTH  [file join $ROOT synth vivado fmax_impl_${PERIOD}ns fmax_impl_${PERIOD}ns.runs synth_1 top_fmax.dcp]
set REF    /tmp/p0a/fmax_base_6.9ns/top_fmax_routed.dcp
set OUT    [file join /tmp/strat2 fmax_${ARM}_${PERIOD}ns]
file mkdir $OUT
open_checkpoint $SYNTH
if {[llength [get_clocks -quiet]] == 0} {
    read_xdc [file join $ROOT synth vivado fmax_impl_${PERIOD}ns fmax_gen.xdc]
}
puts "ARM_CLK [get_property -quiet PERIOD [get_clocks -quiet clk]] expect=$PERIOD arm=$ARM"

if {$ARM eq "incr"} {
    # 指南第五步: 增量 —— 拿 6.9ns 已布线的结果当 reference, 只按新约束局部重优化
    if {[catch {read_checkpoint -incremental $REF} e]} { puts "INCR_READ_FAIL $e" } else { puts "INCR_READ_OK" }
    if {[catch {opt_design} e]} { puts "INCR_OPT $e" }
    place_design
} else {
    if {$ARM eq "merge"} {
        if {[catch {opt_design -merge_equivalent_drivers -hier_fanout_limit 512} e]} { puts "MERGE_FAIL $e"; opt_design }
    } else {
        # 指南里的 FORCE_MAX_FANOUT 在 2023.2 不存在 (design 无此属性), 这里退而用
        # net 级 MAX_FANOUT (真实可用的那个), 看它值不值
        set nets [get_nets -hier -quiet -filter {NAME =~ "*u_ifu_subsys*"}]
        set n0 0
        foreach n $nets { if {[llength [get_pins -quiet -of $n -filter {DIRECTION == IN}]] >= 60} { incr n0; catch {set_property MAX_FANOUT 32 $n} } }
        puts "FFO_SET nets=$n0"
        opt_design
    }
    place_design
}
phys_opt_design
route_design
set wns  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
report_timing -delay_type max -max_paths 500 -file [file join $OUT timing_paths500.rpt]
report_utilization -file [file join $OUT utilization.rpt]
report_high_fanout_nets -max_nets 30 -timing -file [file join $OUT hf_post.rpt]
foreach p [get_timing_paths -delay_type max -max_paths 3] {
    puts [format "  %8.3f ns  %s -> %s" [get_property SLACK $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
puts [format "ARM_SUMMARY period=%s arm=%s wns=%.4f fmax_mhz=%.2f" $PERIOD $ARM $wns [expr {1000.0/($PERIOD-$wns)}]]
