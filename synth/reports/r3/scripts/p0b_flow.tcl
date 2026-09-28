# ===========================================================================
# P0b: 布局约束实验 —— 把整个 IFU 簇圈进一个 pblock (压紧物理跨度)
#
#   用法: vivado -mode batch -source /tmp/p0b_flow.tcl -tclargs <period> <tag> <pblock|none> <place_dir> <contain 0|1>
#     例: ... -tclargs 6.9 pb24def {SLICE_X65Y75:SLICE_X88Y274} Default 0
#     例: ... -tclargs 6.9 expnone none Default Explore 0
#
#   基线: /tmp/p0a/fmax_base_6.9ns = 工程 run 的逐位复刻 (+0.114 @6.9 / -0.473 @6.5)
#   只差 place 阶段的 pblock/directive; opt/phys_opt/route 与基线完全一致。
# ===========================================================================
set PERIOD [lindex $argv 0]
set TAG    [lindex $argv 1]
set PBSPEC [lindex $argv 2]
set PBDIR  [lindex $argv 3]
set CR     [lindex $argv 4]

set ROOT  /home/st-wangjun/project/RISCV_A910
set SYNTH [file join $ROOT synth vivado fmax_impl_${PERIOD}ns \
                fmax_impl_${PERIOD}ns.runs synth_1 top_fmax.dcp]
set OUT [file join /tmp/p0b fmax_${TAG}_${PERIOD}ns]
file mkdir $OUT

open_checkpoint $SYNTH
if {[llength [get_clocks -quiet]] == 0} {
    read_xdc [file join $ROOT synth vivado fmax_impl_${PERIOD}ns fmax_gen.xdc]
}
set per [get_property -quiet PERIOD [get_clocks -quiet clk]]
puts "P0B_CLK period=$per expect=$PERIOD"
if {$per eq "" || abs($per - $PERIOD) > 0.01} { error "时钟不对: per=$per" }

proc span {label pat} {
    set xs {}; set ys {}; set n 0
    foreach c [get_cells -quiet -hier -filter "NAME =~ \"$pat\" && IS_PRIMITIVE"] {
        if {[regexp {X(\d+)Y(\d+)} [get_property -quiet LOC $c] m x y]} {
            lappend xs $x; lappend ys $y; incr n
        }
    }
    if {$n == 0} { puts "SPAN $label: 无落位单元"; return }
    set xs [lsort -integer $xs]; set ys [lsort -integer $ys]
    puts [format "SPAN %-14s n=%-6d X=%s..%s Y=%s..%s" $label $n [lindex $xs 0] [lindex $xs end] [lindex $ys 0] [lindex $ys end]]
}

opt_design

if {$PBSPEC ne "none"} {
    create_pblock pb_ifu
    resize_pblock pb_ifu -add $PBSPEC
    set keep {}
    set nramb 0
    foreach c [get_cells -quiet -hier -filter {NAME =~ "*u_ifu_subsys*" && IS_PRIMITIVE}] {
        if {[string match "RAMB*" [get_property -quiet REF_NAME $c]]} { incr nramb; continue }
        lappend keep $c
    }
    puts "P0B_PB range=$PBSPEC cells=[llength $keep] 剔出RAMB=$nramb"
    add_cells_to_pblock pb_ifu -clear_locs $keep
    if {$CR} { set_property CONTAIN_ROUTING 1 [get_pblocks pb_ifu] }
}

place_design -directive $PBDIR
span "*u_ifu_subsys*"      "IFU(全部)"
span "*u_ifu_subsys/u_ibuf*"  "ibuf"
span "*u_ifu_subsys/g_tage.u_tage*" "tage"
span "*Core_cpu/U_IF_ID*"  "IF_ID"
span "*Core_cpu/U_ID_EX*"  "ID_EX"
span "*Core_cpu/u_ifu_subsys/u_icache*" "icache"

phys_opt_design
route_design

set wns  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set fmax [expr {1000.0 / ($PERIOD - $wns)}]
report_timing_summary -delay_type max -max_paths 20 -file [file join $OUT timing_summary.rpt]
report_timing -delay_type max -max_paths 500 -file [file join $OUT timing_paths500.rpt]
report_timing -delay_type max -max_paths 200 -nworst 8 -file [file join $OUT timing_paths_f1.rpt]
report_utilization -file [file join $OUT utilization.rpt]
foreach p [get_timing_paths -delay_type max -max_paths 4] {
    puts [format "  %8.3f ns  %s -> %s" [get_property SLACK $p] \
        [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
puts [format "P0B_SUMMARY period=%s tag=%s pblock=%s place=%s cr=%s wns=%.4f fmax_mhz=%.2f" \
      $PERIOD $TAG $PBSPEC $PBDIR $CR $wns $fmax]
