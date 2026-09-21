`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/06/30 14:19:39
// Design Name: 
// Module Name: PC
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


module PC(
    input wire clk,
    input wire rst,
    input wire stall,
    // 陷阱/中断重定向. 优先级必须【高于 stall】: 陷阱是在 WB(提交点)发出的,
    // 而同一拍完全可能正赶上一个 load-use 停顿或 muldiv 停顿. 若让 stall 赢了,
    // PC 会被冻住, 陷阱向量被静默丢掉. 同时也压过 din(分支/JAL 目标),
    // 因为发出重定向时 EX 里那条分支是【更年轻、本来就要被冲刷掉】的指令.
    input wire trap,
    input wire [31:0] trap_pc,
    input wire [31:0] din,
    output reg [31:0] pc
    );


always @(posedge clk or posedge rst) begin
    if(rst==`RstEnable) begin
        pc <= 32'd0;
    end else if(trap) begin
        pc <= trap_pc;
    end else if(stall) begin
        pc <= pc;
    end else begin
        pc <= din;
    end
end
//reg flag;
//always @(posedge clk or posedge rst) begin
//    if(rst==`RstEnable) begin
//        pc <= 32'd0;
//        flag <= 1;
//    end else if(flag==1) begin
//        pc <= 0;
//        flag <= 0;
//    end else if(stall) begin
//        pc <= pc;
//        flag <= flag;
//    end else begin
//        pc <= din;
//        flag <= flag;
//    end
//end

endmodule

