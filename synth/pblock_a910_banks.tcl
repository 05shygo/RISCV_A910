# ===========================================================================
# A910 R14 banked ROB: **只约束 8 个 bank** 的布局 (官方 impl 的 PRE 钩子)
#
# window/misc/preg/ctrl 不做 Pblock, 交给 place_design 按连接性摆。
# 用于 A/B: bank pblock 是 head mux 收益的来源; 控制逻辑自由摆放有时更好。
# 器件网格 X0..153 / Y0..349。
# ===========================================================================
set notfixed {PRIMITIVE_TYPE !~ "BUFG*" && PRIMITIVE_TYPE !~ "RAMB*" && PRIMITIVE_TYPE !~ "DSP*"}

proc mkpb {name x0 y0 x1 y1 cells} {
    create_pblock $name
    resize_pblock $name -add "SLICE_X${x0}Y${y0}:SLICE_X${x1}Y${y1}"
    if {[llength $cells] > 0} {
        add_cells_to_pblock [get_pblocks $name] $cells
    }
    puts "PB $name cells=[llength $cells] region=$x0,$y0:$x1,$y1"
}

set bregs {
    {30 100 59 119}   {60 100 89 119}   {90 100 119 119}   {120 100 149 119}
    {30 120 59 139}   {60 120 89 139}   {90 120 119 139}   {120 120 149 139}
}
set i 0
foreach r $bregs {
    lassign $r x0 y0 x1 y1
    set pat [format "u_cpu/u_rtu/u_rob/g_bank\[%d\].u_bank/*" $i]
    set cells [get_cells -hier -quiet -filter "NAME =~ \"$pat\" && $notfixed"]
    mkpb "bank${i}_pb" $x0 $y0 $x1 $y1 $cells
    incr i
}
