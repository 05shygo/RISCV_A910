`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu4_phr — 25-bit 路径历史 (PHR) 的折叠视图
//
// 香山的 TAGE 用 PHR（所有 taken CFI 的路径历史），每张表吃自己的历史窗口。
// 这里用 25 bit PHR + 4 张表 (默认窗口 5/10/15/25)，折叠到 6 bit set / 8 bit tag。
// 更新逻辑在 BPU（taken 时移入 1 bit hash），本模块只做组合折叠。
// ===========================================================================
module rv32ifu4_phr #(
    parameter [4:0] L0 = 5'd5,
    parameter [4:0] L1 = 5'd10,
    parameter [4:0] L2 = 5'd15,
    parameter [4:0] L3 = 5'd16
)(
    input  wire [24:0] phr,
    output wire [23:0] fold_idx,   // 4 × 6 bit
    output wire [31:0] fold_tag    // 4 × 8 bit
);

function [5:0] fold6;
    input [24:0] h;
    input [4:0]  len;
    integer i;
    begin
        fold6 = 6'd0;
        for (i = 0; i < 25; i = i + 1) begin
            if (i < len) begin
                fold6[i % 6] = fold6[i % 6] ^ h[i];
            end
        end
    end
endfunction

function [7:0] fold8;
    input [24:0] h;
    input [4:0]  len;
    integer i;
    begin
        fold8 = 8'd0;
        for (i = 0; i < 25; i = i + 1) begin
            if (i < len) begin
                fold8[i % 8] = fold8[i % 8] ^ h[i];
            end
        end
    end
endfunction

assign fold_idx[5:0]   = fold6(phr, L0);
assign fold_idx[11:6]  = fold6(phr, L1);
assign fold_idx[17:12] = fold6(phr, L2);
assign fold_idx[23:18] = fold6(phr, L3);

assign fold_tag[7:0]   = fold8(phr, L0);
assign fold_tag[15:8]  = fold8(phr, L1);
assign fold_tag[23:16] = fold8(phr, L2);
assign fold_tag[31:24] = fold8(phr, L3);

endmodule
