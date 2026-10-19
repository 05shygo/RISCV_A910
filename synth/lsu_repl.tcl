# ---------------------------------------------------------------------------
# LSU internal timing: location-aware fanout replication at post-place stage.
# Pass 1: the dominant spread-out drivers (dcache SRAM address / data / wen).
# The dcache SRAM macros are spread over all RAMB columns; a single bit drives
# loads in every column, making register->SRAM routes 8-9 ns (96-97% route
# delay) with only 1-4 logic levels.  Replicating drivers after placement lets
# the tool place one copy next to each group of loads.
# No RTL logic is changed.
# ---------------------------------------------------------------------------
set pats {
 *u_lsu_vb/vb_addr_tto5_reg*/Q
 *u_lsu_lfb/lfb_lf_sm_addr_tto5_reg*/Q
 *u_lsu_lfb/lfb_lf_sm_vld_reg*/Q
 *u_lsu_ld_da/ld_da_dcache_hit_reg/Q
 *u_lsu_ld_ag/ld_ag_base_reg*/Q
 *u_lsu_st_ag/st_ag_base_reg*/Q
 *u_lsu_ld_dc/ld_dc_addr0_reg*/Q
 *u_lsu_wmb/wmb_write_dcache_ptr_reg*/Q
}
set pins {}
foreach pat $pats {
  set p [get_pins -hier -quiet -filter "NAME =~ \"$pat\""]
  puts "LSU_REPL PAT $pat pins=[llength $p]"
  set pins [concat $pins $p]
}
set names {}
foreach pin $pins {
  foreach n [get_nets -quiet -of_objects $pin] {
    set nm [get_property NAME $n]
    if {![regexp -nocase {clk|rst|cpurst} $nm]} { lappend names $nm }
  }
}
set names [lsort -unique $names]
set nets [get_nets -quiet $names]
puts "LSU_REPL NETS=[llength $nets]"
phys_opt_design -force_replication_on_nets $nets
route_design -directive NoTimingRelaxation
puts "LSU_REPL DONE"
