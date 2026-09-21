`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/07/11 08:55:07
// Design Name: 
// Module Name: IF_ID
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module IF_ID(
    input               clk,
    input               rst,
    input               stall,
    input               flush,
    input [31:0]        if_pc,
    input [31:0]        if_pc4,
    input [31:0]        if_inst,
    output reg [31:0]   id_pc,
    output reg [31:0]   id_pc4,
    output reg [31:0]   id_inst,
    output reg          id_have_inst
    );

// id_have_inst: 这个槽位里到底有没有一条真实取到的指令.
//
// 以前这个信息由 Control.v 的 opcode 白名单"猜"出来, 但那个办法有两个洞:
//   1. 白名单不含 0x73, 于是 ecall/ebreak/csr/mret 永远不提交;
//   2. 未知 opcode 一律记 0, 于是【非法指令也不会提交】, trap 根本发不出去,
//      golden model 等不到提交脉冲会一直卡住.
// 而靠 "id_inst != 0" 来判也不行: 气泡正好就是全零, 而 .word 0x00000000
// 恰恰是一条合法的"非法指令"用例, 两者必须区分开.
// 所以只能真的带一位: 正常捕获置 1, flush/rst 清 0, 停顿保持.
always @(posedge clk or posedge rst) begin
    if(rst == `RstEnable || flush) begin
        id_pc <= 0;
        id_pc4 <= 0;
        id_inst <= 0;
        id_have_inst <= 1'b0;
    end else if(stall) begin
        id_pc <= id_pc;
        id_pc4 <= id_pc4;
        id_inst <= id_inst;
        id_have_inst <= id_have_inst;
    end else begin
        id_pc <= if_pc;
        id_pc4 <= if_pc4;
        id_inst <= if_inst;
        id_have_inst <= 1'b1;
    end
end


endmodule

