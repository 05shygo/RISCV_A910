# ===========================================================================
# A910 + ifu3 的 Fmax 测量 —— xc7k325tffg900-2
#
# 用法:
#   vivado -mode batch -source synth/build_fmax_a910.tcl -tclargs <period_ns> <synth|impl> [ifu2|ifu3]
#
#   period_ns : create_clock 的目标周期 (ns)。190MHz -> 5.263; 150MHz -> 6.667
#   synth|impl: 只到综合 / 跑到 route_design (Fmax 要 impl 才算数)
#   ifu2|ifu3 : 前端配置, 默认 ifu3
#
# 配置口径 = Makefile 的 `A910_IFU=<n>` 那条线 (见 Makefile:958-989):
#   A910_cpu 顶层, RTU_PREG64, DCACHE_2KB (DCACHE_SIZE 默认 2048)
#
#   ifu3 (= A910_IFU=3): USE_IFU3;
#     ifu2 的 icache/refill/spram/ibuf/ifu_biu_axi + ifu3/rtl 全套;
#     ifu2 的 top/btb/bht/tage/ras 不参与编译。
#
#   ifu2 (= A910_IFU=2): USE_IFU2 + **TAGE 那套** (BP_PRED=1, BP_GHR_W=16);
#     A910 的 Makefile 规则本身不挂 BP_DEFS (默认是 gshare), 这里显式按
#     `make ... BP_PRED=1` 的派生规则补上, 用于和 ifu3 对比。
#     icache 1024B/16B 行取 RTL 默认。
#
# 与 build_fmax.tcl 的差异:
#   * 顶层是 top_a910_fmax (A910_cpu + 显式 BUFG), 不是 miniRV_SoC;
#   * 片内没有存储器 (BIU 是 AXI 主端), 不需要 $readmemh 镜像生成;
#   * AXI 边界按 0ns 输入/输出延迟约束 —— 输入路径拿到整拍预算, 输出路径
#     也被正常分析 (不再像调试 tap 那样 false_path)。
# ===========================================================================

set PERIOD 5.263
set MODE   "impl"
set IFU    "ifu3"

if {[llength $argv] >= 1} { set PERIOD [lindex $argv 0] }
if {[llength $argv] >= 2} { set MODE   [lindex $argv 1] }
if {[llength $argv] >= 3} { set IFU    [lindex $argv 2] }
if {$MODE ne "synth" && $MODE ne "impl"} {
    error "MODE 只能是 synth 或 impl, 当前是 '$MODE'"
}
if {$IFU ne "ifu2" && $IFU ne "ifu3"} {
    error "IFU 只能是 ifu2 或 ifu3, 当前是 '$IFU'"
}

set SP   [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $SP ..]]

puts "================================================================"
puts "A910+[string toupper $IFU] FMAX RUN: period=$PERIOD ns  mode=$MODE"
puts "ROOT=$ROOT"
puts "================================================================"

# 工程目录带 a910_<ifu> 前缀: 与 miniRV 的 fmax_<mode>_<period>ns 分开,
# 同名周期的不同配置也不会互相删目录。
set PROJ_NAME "fmax_a910_${IFU}_${MODE}_${PERIOD}ns_r9br10tmp"
set PROJ_DIR  [file join $SP "vivado" $PROJ_NAME]
if {[file exists $PROJ_DIR]} {
    if {[catch {file delete -force $PROJ_DIR} err]} {
        error "工程目录存在且删不掉 (多半有进程占着): $err"
    }
}
file mkdir $PROJ_DIR

create_project -force $PROJ_NAME $PROJ_DIR -part xc7k325tffg900-2

# ---------------------------------------------------------------------------
# 文件列表 = Makefile 的 A910_SRC (A910_IFU=3)
# ---------------------------------------------------------------------------
set src_files [list [file join $ROOT mySoC A910_cpu.sv]]

if {$IFU eq "ifu3"} {
    # ifu3 复用 ifu2 的 icache/refill/spram/ibuf/biu, 去掉 ifu2 自己那套预测器/顶层。
    set IFU2_SKIP {rv32ifu2_top.v rv32ifu2_btb.v rv32ifu2_bht.v rv32ifu2_tage.v rv32ifu2_ras.v}
    foreach f [lsort [glob -nocomplain [file join $ROOT mySoC ifu2 rtl *.v]]] {
        if {[lsearch -exact $IFU2_SKIP [file tail $f]] >= 0} { continue }
        lappend src_files $f
    }
    foreach f [lsort [glob -nocomplain [file join $ROOT mySoC ifu3 rtl *.v]]] {
        lappend src_files $f
    }
} else {
    foreach f [lsort [glob -nocomplain [file join $ROOT mySoC ifu2 rtl *.v]]] {
        lappend src_files $f
    }
}
foreach d {rtu/rtl iu/rtl} {
    foreach f [lsort [glob -nocomplain [file join $ROOT mySoC {*}[split $d /] *.v]]] {
        lappend src_files $f
    }
}
# C910 移植的 IDU/LSU/BIU 是 SystemVerilog, 单独的 *.sv 通配。
foreach d {idu_c910/rtl lsu/rtl biu/rtl} {
    foreach f [lsort [glob -nocomplain [file join $ROOT mySoC {*}[split $d /] *.sv]]] {
        lappend src_files $f
    }
}
lappend src_files [file join $SP top_a910_fmax.v]

add_files -norecurse $src_files

# VCS 那侧是 -sverilog 一把过; Vivado 默认把 .v 按 Verilog-2001 解析会报错。
set_property file_type SystemVerilog [get_files -of [get_filesets sources_1] *.v]

# 宏 = Makefile A910 规则 + 前端选择。
# ifu2 的 TAGE 档 = `BP_PRED=1` 的派生默认 (BP_GHR_W=16), 与 Makefile:541 一致。
if {$IFU eq "ifu3"} {
    set DEFS [list USE_IFU3 RTU_PREG64 DCACHE_2KB]
} else {
    set DEFS [list USE_IFU2 BP_PRED=1 BP_GHR_W=16 RTU_PREG64 DCACHE_2KB]
}
set_property verilog_define $DEFS [get_filesets sources_1]
set_property include_dirs [list [file join $ROOT mySoC] [file join $ROOT vsrc] \
                               [file join $ROOT mySoC rtu rtl]] [get_filesets sources_1]
set_property top top_a910_fmax [get_filesets sources_1]

# ---------------------------------------------------------------------------
# 约束:
#   clk   : 目标周期;
#   rst   : 与 build_fmax.tcl 同口径, 2ns 输入延迟 (同步复位, 不是关键路径);
#   AXI   : 0ns 输入/输出延迟 —— 没有真实板级信息, 就按"边界整拍可用"分析,
#           这样 pad→寄存器 与 寄存器→pad 都不会被漏掉。
# ---------------------------------------------------------------------------
set xdc [file join $PROJ_DIR fmax_gen.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $PERIOD \[get_ports clk\]"
puts $fh "set_input_delay  -clock clk 2.0 \[get_ports rst\]"
puts $fh "set_input_delay  -clock clk 0.0 \[get_ports {pad_biu_*}\]"
puts $fh "set_output_delay -clock clk 0.0 \[get_ports {biu_pad_*}\]"
close $fh
add_files -fileset constrs_1 $xdc

# ---------------------------------------------------------------------------
# 综合/实现策略: 这一轮按"综合 + 布局布线都开优化"口径。
#   synth: Flow_PerfOptimized_high (性能优先综合; 默认是 Vivado Synthesis Defaults)
#   impl : Performance_NetDelay_high — 与 miniRV 那套 Fmax 流程一致
#          (本设计同样以 net delay 为主)。
# ---------------------------------------------------------------------------
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
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
report_timing -delay_type max -max_paths 500 -file [file join $PROJ_DIR timing_paths500.rpt]

# 每个终点最多列 8 个不同起点: 前端和核内同时起跳时不会互相遮住。
report_timing -delay_type max -max_paths 200 -nworst 8 -file [file join $PROJ_DIR timing_paths_nw8.rpt]

# 定向: ifu3 S0 的 PC 寄存器出发的路径 (综合后层次名可能被优化, 取不到就跳过)。
if {[catch {
    set s0_src [get_pins -hier -quiet -filter {NAME =~ "*u_ifu/s0_*start_pc_reg*/C"}]
    if {[llength $s0_src] > 0} {
        report_timing -delay_type max -from $s0_src -max_paths 20 -nworst 3 \
            -file [file join $PROJ_DIR timing_from_s0pc.rpt]
        puts "S0 report: [llength $s0_src] 个 s0_*start_pc 起点"
    } else {
        puts "S0 report: 找不到 s0_*start_pc_reg, 跳过"
    }
} err]} { puts "S0 report skipped: $err" }

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
foreach p [get_timing_paths -delay_type max -max_paths 500 -slack_lesser_than 0] { incr ncrit }
puts "VIOLATING ENDPOINTS (slack<0, up to 500): $ncrit"

puts [format "FMAX_SUMMARY period=%s mode=%s wns=%.4f fmax_mhz=%.2f" \
      $PERIOD $MODE $wns $fmax]
puts "================================================================"
