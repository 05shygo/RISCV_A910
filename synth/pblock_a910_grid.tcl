# ===========================================================================
# A910 R14/R15 banked ROB 的 per-bank 布局 (官方 impl 的 OPT_DESIGN.TCL.PRE 钩子)
#
# 用法: build_fmax_a910.tcl 的第 4 个参数 = grid
#
# ⚠️ 器件 xc7k325tffg900-2 的 SLICEL 网格实际是 X0..153 / Y0..349
#    (2026-10-19 实测: 之前 X150..189 的窗口/preg 区域被裁到 X150..153 的窄条,
#     pblock 基本没生效)。本布局全部落在 X<=149。
#
#    bank 4x2 (每块 30x20) 在 Y100..139; 窗口/杂项/preg 在 bank 正下方
#    Y140..179 的中心带; commit/flush/expt/csr 再下一排 Y180..209。
#    这样 head 读、cptr/rptr->窗口/preg、csr->窗口都在一个紧凑簇内。
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

# --- 8 banks: 上排 Y100..119, 下排 Y120..139, 每块 30x20 ---
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

# --- commit 窗口 (30x30) ---
set wcells [get_cells -hier -quiet -filter "NAME =~ \"u_cpu/u_rtu/u_rob/u_win*\" && $notfixed"]
mkpb win_pb 80 140 109 169 $wcells

# --- ROB 杂项 (指针/窗口 mux/派遣寄存器等) ---
set mcells [get_cells -hier -quiet -filter "NAME =~ \"u_cpu/u_rtu/u_rob/*\" && NAME !~ \"*g_bank*\" && NAME !~ \"*u_win*\" && $notfixed"]
mkpb robmisc_pb 110 140 139 179 $mcells

# --- preg: 压紧在窗口左侧 ---
set pcells [get_cells -hier -quiet -filter "NAME =~ \"u_cpu/u_rtu/u_preg/*\" && $notfixed"]
mkpb preg_pb 40 140 79 179 $pcells

# --- commit/flush/expt/csr: 窗口/杂项正下方 ---
set ccells [get_cells -hier -quiet -filter "NAME =~ \"u_cpu/u_rtu/*\" && NAME !~ \"*u_rob*\" && NAME !~ \"*u_preg*\" && $notfixed"]
mkpb ctrl_pb 80 180 139 209 $ccells
