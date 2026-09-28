# ===========================================================================
# xc7k325tffg900-2 上的 Fmax 测量 —— IFU=2 (自研 ifu2) 配置
#
# 用法:
#   vivado -mode batch -source synth/build_fmax.tcl -tclargs <period_ns> <synth|impl> [bin路径]
#
#   period_ns : create_clock 的目标周期 (ns)
#   synth|impl: 只到综合 / 跑到 route_design (Fmax 要 impl 才算数)
#   bin路径    : 可选, $readmemh 镜像的来源 (默认 bin/coremark.bin)。
#                ⚠️ 镜像内容不影响时序, 只影响 $readmemh 能不能读到数。
#
# 配置口径 = Makefile IFU=2 的默认值 (BP_PRED=1 TAGE / icache 1024B 16B 行 /
# GHR=16, TAGE 几何吃 RTL 默认), 即 `make run IFU=2` 那条线。
#
# 2026-09-28 更新: 存储器已换成 mySoC/sync_mem.v (同步 1R1W + 写穿透, 落块 RAM),
# 初值走 $readmemh + PATHHEX/PATH128 两个宏 —— 本脚本自己按 Makefile 的
# od/awk 规则生成那两份十六进制镜像, 不依赖外部工具链。
# 旧的"用 synth/*_synth.v 顶掉仿真模型"的做法随之作废, 已删除。
# ===========================================================================

set PERIOD 12.2
set MODE   "impl"
set BIN    ""

if {[llength $argv] >= 1} { set PERIOD [lindex $argv 0] }
if {[llength $argv] >= 2} { set MODE   [lindex $argv 1] }
if {[llength $argv] >= 3} { set BIN    [lindex $argv 2] }

set SP   [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $SP ..]]

if {$BIN eq ""} { set BIN [file join $ROOT bin coremark.bin] }
if {![file exists $BIN]} { error "镜像不存在: $BIN" }

puts "================================================================"
puts "FMAX RUN: period=$PERIOD ns  mode=$MODE"
puts "ROOT=$ROOT"
puts "BIN =$BIN"
puts "================================================================"

# 目录名带周期: 不同周期的 run 各自独立, 也避免"删旧工程"这种事
# (踩过: 删上一个 run 的工程目录时被占用文件卡住, 顺手把上次的结果删了一半)。
set PROJ_NAME "fmax_${MODE}_${PERIOD}ns"
set PROJ_DIR  [file join $SP "vivado" $PROJ_NAME]
if {[file exists $PROJ_DIR]} {
    if {[catch {file delete -force $PROJ_DIR} err]} {
        error "工程目录存在且删不掉 (多半有进程占着): $err"
    }
}
file mkdir $PROJ_DIR

# ---------------------------------------------------------------------------
# $readmemh 镜像生成 —— 规则与 Makefile 的 bin/%.hex / bin/%.hex128 逐条一致:
#   .hex     = od -An -tx4 -v       每行 1 个 32 位小端字, 补零到 HEX_ROWS 行
#   .hex128  = od -An -tx4 -v -w16  每行 4 个字按 **w3 w2 w1 w0** 降序, 补零到
#              HEX_ROWS/4 行 —— 行内的排列正好等于 ifu_biu_mem 要的 {w3,w2,w1,w0}
# 用 Tcl 自己算而不是调 od/awk: 不依赖机器上装了什么。
# ---------------------------------------------------------------------------
proc gen_hex_images {bin_path hex32_path hex128_path rows} {
    set fh [open $bin_path rb]
    set data [read $fh]
    close $fh

    set need [expr {$rows * 4}]
    if {[string length $data] < $need} {
        append data [string repeat "\x00" [expr {$need - [string length $data]}]]
    }

    binary scan $data c* bytes
    set nwords [expr {[string length $data] / 4}]

    set words [list]
    for {set i 0} {$i < $nwords} {incr i} {
        set b0 [lindex $bytes [expr {$i*4    }]]
        set b1 [lindex $bytes [expr {$i*4 + 1}]]
        set b2 [lindex $bytes [expr {$i*4 + 2}]]
        set b3 [lindex $bytes [expr {$i*4 + 3}]]
        lappend words [expr {(($b3 & 0xff) << 24) | (($b2 & 0xff) << 16) |
                             (($b1 & 0xff) <<  8) |  ($b0 & 0xff)}]
    }

    set f1 [open $hex32_path w]
    foreach w $words { puts $f1 [format %08x $w] }
    close $f1

    set f2 [open $hex128_path w]
    for {set i 0} {$i < $nwords} {incr i 4} {
        puts $f2 [format "%08x%08x%08x%08x" \
                  [lindex $words [expr {$i+3}]] [lindex $words [expr {$i+2}]] \
                  [lindex $words [expr {$i+1}]] [lindex $words [expr {$i  }]]]
    }
    close $f2

    puts "HEX: $hex32_path ([expr {$nwords}] 字) + $hex128_path ([expr {$nwords/4}] 块)"
}

set HEX_ROWS 16384
set hex32  [file join $PROJ_DIR meminit.hex]
set hex128 [file join $PROJ_DIR meminit128.hex]
gen_hex_images $BIN $hex32 $hex128 $HEX_ROWS

create_project -force $PROJ_NAME $PROJ_DIR -part xc7k325tffg900-2

# ---------------------------------------------------------------------------
# 文件列表 = Makefile IFU=2 的 VSRC, 只少两类:
#   mySoC/ifu_subsys.v —— 那是 rv32_ifu_top 的适配层, IFU=2 下不参与;
#   vsrc/ram*.v        —— 仿真模型 ($fread 装载), 综合侧用 mySoC/sync_mem.v。
#     (IFU=2 下没有任何模块例化 IROM/DRAM, 不带它们综合结果一样)
# ---------------------------------------------------------------------------
set src_files {}

foreach f [lsort [glob -nocomplain [file join $ROOT mySoC *.v]]] {
    if {[file tail $f] eq "ifu_subsys.v"} { continue }
    lappend src_files $f
}
foreach f [lsort [glob -nocomplain [file join $ROOT mySoC ifu2 rtl *.v]]] {
    lappend src_files $f
}
lappend src_files [file join $SP top_fmax.v]

add_files -norecurse $src_files

# 全部按 SystemVerilog 解析: VCS 那边是 -sverilog 一把过 (miniRV_SoC.v 用了
# `logic`, 还有别的 SV 语法), Vivado 默认按 Verilog-2001 读 .v 会直接报错。
set_property file_type SystemVerilog [get_files -of [get_filesets sources_1] *.v]

# IFU=2 的宏 (与 Makefile IFU=2 的 DEFINES/BP_DEFS 默认值逐条对应)
# + PATHHEX/PATH128: sync_mem.v 的 $readmemh 初值 (同一个变量在 Makefile 里
#   由 +define+ 传, 这里换成 Vivado 的 verilog_define, 语义相同)。
set DEFS [list \
    USE_IFU2 \
    USE_IFU_ANY \
    BP_PRED=1 \
    BP_GHR_W=16 \
    REDIRECT_PIPE \
    ICACHE_BYTES=1024 \
    ICACHE_LINE_BYTES=16 \
    ICACHE_LINE_16B \
    PATHHEX=$hex32 \
    PATH128=$hex128 \
]
set_property verilog_define $DEFS [get_filesets sources_1]
set_property include_dirs [list [file join $ROOT mySoC] [file join $ROOT vsrc]] [get_filesets sources_1]
set_property top top_fmax [get_filesets sources_1]

# ---------------------------------------------------------------------------
# 约束: 时钟 + I/O 延时。
#   rst 是同步复位 (miniRV_SoC 里过了一级同步器), 给足一个周期;
#   调试输出口 (RUN_TRACE 的 tap) 打 false_path —— 它们只是把流水线里已有的
#   寄存器引出来看, 不是设计的一部分 (defines.vh 也写着"综合前注释掉")。
#   不加这条, 报告里会混进 o_dbg_value 的 I/O 路径, 把真正的核内路径挤下去。
# ---------------------------------------------------------------------------
set xdc [file join $PROJ_DIR fmax_gen.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $PERIOD \[get_ports clk\]"
puts $fh "set_input_delay  -clock clk 2.0 \[get_ports rst\]"
puts $fh "set_false_path -to \[get_ports {o_dbg_pc o_dbg_value o_dbg_reg o_dbg_ena o_dbg_have}\]"
close $fh
add_files -fileset constrs_1 $xdc

# ---------------------------------------------------------------------------
# 跑流程
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# [第三轮实测 2026-09-29] 实现策略: Performance_NetDelay_high
#   本设计关键路径走线占 87~88% (逐跳 ~0.41ns, 与负载数/物理跨度都无关), 正是指南里
#   "Net Delay 主导"那一支。6.5ns 点实测 WNS -0.473 -> -0.191 (+0.282ns); 与 RTL
#   五刀叠加后 6.5ns 点直接收敛 (最紧通过点 ~6.35ns, 147.4 -> ~157MHz)。
#   同批对照: ExplorePostRoutePhysOpt +0.215 / Explore +0.126 / Retiming +0.056 /
#             Flow_PerfOptimized_high+Explore -0.037 / merge_equivalent_drivers -0.12。
# ---------------------------------------------------------------------------
set_property strategy Performance_NetDelay_high [get_runs impl_1]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synth_1 FAILED: [get_property STATUS [get_runs synth_1]]"
}

if {$MODE eq "impl"} {
    launch_runs impl_1 -to_step route_design -jobs 8
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        error "impl_1 FAILED: [get_property STATUS [get_runs impl_1]]"
    }
    open_run impl_1
} else {
    open_run synth_1
}

# ---------------------------------------------------------------------------
# 报告
# ---------------------------------------------------------------------------
report_timing_summary -delay_type max -max_paths 20 -file [file join $PROJ_DIR timing_summary.rpt]
report_utilization -file [file join $PROJ_DIR utilization.rpt]

# 每个终点取最差一条 (默认 -nworst 1): 500 条覆盖 500 个不同终点。
# 只看 summary 的前 10 条会被"同一个终点的多条路径"骗到 —— 实测 93% 的违例
# 终点都落在 TAGE 的 pv_q 写口上, 那份分布才是判断"该动哪"的依据。
report_timing -delay_type max -max_paths 500 -file [file join $PROJ_DIR timing_paths500.rpt]

# ---------------------------------------------------------------------------
# ⚠️ 上面那份 500 条有个**盲区**: `-nworst 1` 意味着每个终点只报它最差的那一条,
#    而实测 500 条全部从同一个寄存器位 (EX 级的 ex_csr_addr_reg) 出发 ——
#    **前端 F1 那一拍自己的路径一条都看不到**。
#
#    而 F1 那一拍 (icache tag 比较 + BTB 行匹配 + TAGE 读/优先/use_sel + taken
#    选择 + next_pc) 正是做完 EX→前端那几刀之后会顶上来的一段, 现在完全没有数据。
#
# 这份按 **-nworst 8** 报: 同一个终点最多列 8 条不同起点的路径。
# 于是对同一个前端终点, 既能看到 EX 起点那条, 也能看到 q_pc/q_data 起点那条 ——
# 不用猜"F1 到底多长", 也不依赖任何层次名 (综合后名字会变)。
# ---------------------------------------------------------------------------
report_timing -delay_type max -max_paths 200 -nworst 8 -file [file join $PROJ_DIR timing_paths_f1.rpt]

# 定向: 直接从 F1 的 PC 寄存器出发的最差路径。名字在综合后可能被优化掉,
# 所以包在 catch 里 —— 取不到就跳过, 不影响整个流程 (上面那份 nworst 8 仍在)。
if {[catch {
    set f1_src [get_pins -hier -filter {NAME =~ "*u_icache/q_pc_q_reg*/C"}]
    if {[llength $f1_src] > 0} {
        report_timing -delay_type max -from $f1_src -max_paths 20 -nworst 3 \
            -file [file join $PROJ_DIR timing_from_qpc.rpt]
        puts "F1 report: [llength $f1_src] 个 q_pc_q 起点"
    } else {
        puts "F1 report: 找不到 u_icache/q_pc_q_reg, 跳过"
    }
} err]} { puts "F1 report skipped: $err" }

set wns  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set fmax [expr {1000.0 / ($PERIOD - $wns)}]

puts "================================================================"
puts "TIMING PATHS (top 8):"
set i 0
foreach p [get_timing_paths -delay_type max -max_paths 8] {
    incr i
    puts [format "  %d) %8.3f ns  %s -> %s" \
        $i [get_property SLACK $p] \
        [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
set ncrit 0
foreach p [get_timing_paths -delay_type max -max_paths 200 -slack_lesser_than 0] { incr ncrit }
puts "VIOLATING PATHS (slack<0, up to 200): $ncrit"

# ---------------------------------------------------------------------------
# 关键判据: **非 EX 起点**的最差路径有多长。
#   EX↔前端那几刀砍完之后, 顶上来的一定是前端 F1 自己那一拍 (从 q_pc/q_row_idx/
#   ctr_q 这些寄存器出发)。这条数字直接告诉我们"F1 还有多少余量", 也是决定
#   要不要动 TAGE / gshare 的依据。一并打进 log 的 FMAX_SUMMARY 附近, 好抓。
# ---------------------------------------------------------------------------
set non_ex ""
foreach p [get_timing_paths -delay_type max -max_paths 300 -nworst 8] {
    if {[string match "*ex_csr_addr*" [get_property STARTPOINT_PIN $p]]} { continue }
    set non_ex $p
    break
}
if {$non_ex ne ""} {
    puts [format "WORST_NON_EX slack=%.3fns  %s -> %s" \
        [get_property SLACK $non_ex] \
        [get_property STARTPOINT_PIN $non_ex] [get_property ENDPOINT_PIN $non_ex]]
} else {
    puts "WORST_NON_EX 没有非 ex_csr_addr 起点的路径 (前 300 个终点全是它)"
}
puts [format "FMAX_SUMMARY period=%s mode=%s wns=%.4f fmax_mhz=%.2f" \
      $PERIOD $MODE $wns $fmax]
puts "================================================================"
