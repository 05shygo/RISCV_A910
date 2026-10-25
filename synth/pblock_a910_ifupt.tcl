# IFU+BPU+ICache+IBUF 收紧版 Pblock (2026-10-19)
# 第一版 X0..60/Y39..200 的实测 IFU bbox = X1..64/Y21..121;
# 收紧到 X0..64/Y20..121, 释放 Y122.. 给其他模块, 并把 ICache 的 4 个
# RAMB36 (器件 X1 列只有 Y39..42 这四个站点) 一起框进来。
set notfixed {PRIMITIVE_TYPE !~ "BUFG*"}
create_pblock ifu_pb
resize_pblock ifu_pb -add SLICE_X0Y20:SLICE_X64Y121
resize_pblock ifu_pb -add RAMB36_X1Y39:RAMB36_X1Y42
set cells [get_cells -hier -quiet -filter "NAME =~ \"u_cpu/u_rv32ifu2_top/*\" && $notfixed"]
add_cells_to_pblock [get_pblocks ifu_pb] $cells
puts "IFU PB cells=[llength $cells] region=X0..64 Y20..121 (tight)"
