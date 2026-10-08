// Simple one-hot decoder for register number
// Converts 6-bit register number to 64-bit one-hot encoding
//
// ⚠️ 2026-10-08: 由 `ct_rtu_expand_96` 改来 —— 物理寄存器改成 64 个 (6 位) 之后,
//    这个一热展开也跟着缩。改法照仓库约定"文件名 == 模块名", 例化点同步改
//    (lsu_ld_wb.sv 两处)。对照 C910 原版就是 `ct_rtu_expand_64.v`。

module ct_rtu_expand_64 (
    input  logic [5:0]  x_num,
    output logic [63:0] x_num_expand
);

always_comb begin
    x_num_expand = 64'b0;
    if (x_num < 64) begin
        x_num_expand[x_num] = 1'b1;
    end
end

endmodule
