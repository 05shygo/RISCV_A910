# ===========================================================================
# P0c: 布局形状/密度扫描 + 多子块 (P0b 的下一轮迭代)
#
#   用法: vivado -mode batch -source /tmp/p0c_flow.tcl -tclargs <period> <tag> <spec> <place_dir>
#     spec : "name|cells_pattern|SLICE_X..Y..:SLICE_X..Y..[;name2|pat2|range2]"
#            传 none 则不加 pblock
#   例:  "pb_ifu|*u_ifu_subsys*|SLICE_X64Y125:SLICE_X87Y224"
#        "pb_tage|*g_tage.u_tage*|SLICE_X64Y125:SLICE_X73Y224;pb_ibuf|*u_ibuf*|SLICE_X74Y125:SLICE_X93Y224;pb_btb|*u_btb*|SLICE_X94Y125:SLICE_X97Y174"
#
#   判据: 与 /tmp/p0a/fmax_base_6.9ns (工程基线逐位复刻, +0.114 @6.9) 比。
# ===========================================================================
set PERIOD [lindex $argv 0]
set TAG    [lindex $argv 1]
set SPEC   [lindex $argv 2]
set PBDIR  [lindex $argv 3]

set ROOT  /home/st-wangjun/project/RISCV_A910
set SYNTH [file join $ROOT synth vivado fmax_impl_${PERIOD}ns \
                fmax_impl_${PERIOD}ns.runs synth_1 top_fmax.dcp]
set OUT [file join /tmp/p0c fmax_${TAG}_${PERIOD}ns]
file mkdir $OUT

open_checkpoint $SYNTH
if {[llength [get_clocks -quiet]] == 0} {
    read_xdc [file join $ROOT synth vivado fmax_impl_${PERIOD}ns fmax_gen.xdc]
}
set per [get_property -quiet PERIOD [get_clocks -quiet clk]]
if {$per eq "" || abs($per - $PERIOD) > 0.01} { error "时钟不对: per=$per" }
puts "P0C_CLK period=$per tag=$TAG place=$PBDIR"

# 模块落位统计 (用 LOC 的 min/max, 论证压紧程度)
proc span {label pat} {
    set xs {}; set ys {}; set n 0
    foreach c [get_cells -quiet -hier -filter "NAME =~ \"$pat\" && IS_PRIMITIVE"] {
        if {[regexp {X(\d+)Y(\d+)} [get_property -quiet LOC $c] m x y]} { lappend xs $x; lappend ys $y; incr n }
    }
    if {$n == 0} { puts "SPAN $label: 无落位单元"; return }
    set xs [lsort -integer $xs]; set ys [lsort -integer $ys]
    puts [format "SPAN %-12s n=%-6d X=%s..%s Y=%s..%s" $label $n [lindex $xs 0] [lindex $xs end] [lindex $ys 0] [lindex $ys end]]
}

opt_design

if {$SPEC ne "none"} {
    foreach spec [split $SPEC ";"] {
        set f [split $spec "|"]
        set name [lindex $f 0]; set pat [lindex $f 1]; set rng [lindex $f 2]
        create_pblock $name
        resize_pblock $name -add $rng
        set keep {}
        foreach c [get_cells -quiet -hier -filter "NAME =~ \"$pat\" && IS_PRIMITIVE"] {
            if {[string match "RAMB*" [get_property -quiet REF_NAME $c]]} { continue }
            lappend keep $c
        }
        add_cells_to_pblock $name -clear_locs $keep
        puts "P0C_PB $name range=$rng cells=[llength $keep]"
    }
}

place_design -directive $PBDIR
span "*u_ifu_subsys*"        "*u_ifu_subsys*"
span "ibuf"                  "*u_ibuf*"
span "tage"                  "*g_tage.u_tage*"
span "icache"                "*u_icache*"
span "IF_ID"                 "*Core_cpu/U_IF_ID/*"

phys_opt_design
route_design

set wns  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
report_timing_summary -delay_type max -max_paths 20 -file [file join $OUT timing_summary.rpt]
report_timing -delay_type max -max_paths 500 -file [file join $OUT timing_paths500.rpt]
report_utilization -file [file join $OUT utilization.rpt]
foreach p [get_timing_paths -delay_type max -max_paths 3] {
    puts [format "  %8.3f ns  %s -> %s" [get_property SLACK $p] \
        [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
set dd [get_property DATAPATH_DELAY [get_timing_paths -delay_type max -max_paths 1]]
puts [format "P0C_SUMMARY period=%s tag=%s place=%s spec=%s wns=%.4f rt=%.3f fmax_mhz=%.2f" \
      $PERIOD $TAG $PBDIR $SPEC $wns $dd [expr {1000.0/($PERIOD-$wns)}]]
