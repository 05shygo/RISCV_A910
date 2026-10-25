# IFU+BPU+ICache+IBUF Pblock (2026-10-19)
# 当前无约束时 IFU top 摆在 X0..39 / Y41..338 (竖长条), 内部 q_pc->tag 走 9.1ns。
# 收进 X0..60 / Y100..200, 并允许 ICache 的 RAMB36 (当前 X1Y41..44) 在 X1 列同 Y 段。
set notfixed {PRIMITIVE_TYPE !~ "BUFG*"}
create_pblock ifu_pb
# 两条分开加: 花括号列表里带两个 range 时 RAMB 段会被吞掉 (实测 pblock 无 RAMB 站点).
# ⚠️ 器件 X1 列的 RAMB36E1 只有 Y39..42 这 4 个站点 (2026-10-19 实测);
#    ICache 的 4 个 BRAM 就在那里。Pblock 的 Y 必须覆盖到 39, 否则
#    "no compatible site is available in Pblock"。
resize_pblock ifu_pb -add SLICE_X0Y39:SLICE_X60Y200
resize_pblock ifu_pb -add RAMB36_X1Y39:RAMB36_X1Y42
set cells [get_cells -hier -quiet -filter "NAME =~ \"u_cpu/u_rv32ifu2_top/*\" && $notfixed"]
add_cells_to_pblock [get_pblocks ifu_pb] $cells
puts "IFU PB cells=[llength $cells] region=X0..60 Y100..200"
