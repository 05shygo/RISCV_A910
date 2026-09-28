open_checkpoint /home/st-wangjun/project/RISCV_A910/synth/vivado/fmax_impl_7.0ns/fmax_impl_7.0ns.runs/impl_1/top_fmax_placed.dcp

proc span {pat label} {
  set cells [get_cells -quiet -hier -filter "NAME =~ \"$pat\" && IS_PRIMITIVE"]
  set xs {}; set ys {}
  foreach c $cells {
    set loc [get_property LOC $c]
    if {[regexp {X(\d+)Y(\d+)} $loc m x y]} { lappend xs $x; lappend ys $y }
  }
  if {[llength $xs]} {
    set xs [lsort -integer $xs]; set ys [lsort -integer $ys]
    puts [format "SPAN %-16s n=%-6d X=%s..%s  Y=%s..%s" $label [llength $xs] [lindex $xs 0] [lindex $xs end] [lindex $ys 0] [lindex $ys end]]
  } else { puts "SPAN $label: 无" }
  flush stdout
}

puts "=== 模块落位 ==="
span "*u_ifu_subsys/u_ibuf/*" "ibuf(全部)"
span "*u_ifu_subsys/u_ibuf/ent_q_reg*" "ibuf ent_q 寄存器"
span "*u_ifu_subsys/u_ibuf/ent_q\[*\]\[*\]_i_*" "ibuf 写锥 LUT"
span "*u_ifu_subsys/g_tage.u_tage/*" "tage(全部)"
span "*u_ifu_subsys/g_tage.u_tage/g_tab*" "tage 表(LUTRAM)"
span "*u_ifu_subsys/g_tage.u_tage/q_row_idx_reg*" "tage q_row_idx"
span "*u_ifu_subsys/g_tage.u_tage/q_row_tag_reg*" "tage q_row_tag"
span "*u_ifu_subsys/u_btb/*" "btb"
span "*u_ifu_subsys/u_icache/*" "icache"
span "*Core_cpu/U_IF_ID/*" "IF_ID"
span "*Core_cpu/U_ID_EX/*" "ID_EX"
span "*Core_cpu/U_EX_MEM/*" "EX_MEM"
span "*Core_cpu/U_MEM_WB/*" "MEM_WB"
span "*Core_cpu/U_CSR/*" "CSR"
span "*u_soc/U_REG/*" "REG(regfile)"

puts "=== o_dbg 端口驱动单元落位 ==="
foreach p [list o_dbg_value[0] o_dbg_pc[0] o_dbg_ena o_dbg_have] {
  set pp [get_ports -quiet $p]
  if {[llength $pp] == 0} { puts "PORT $p 无"; continue }
  set drv [get_pins -quiet -of [get_nets -quiet -of $pp] -filter {DIRECTION == OUT}]
  if {[llength $drv]} {
    set cell [get_cells -quiet -of [lindex $drv 0]]
    puts "PORT $p  drivers: [llength $drv]  首个=[lindex $drv 0] @ [get_property LOC [lindex $cell 0]]"
  } else { puts "PORT $p 无驱动 pin" }
}
