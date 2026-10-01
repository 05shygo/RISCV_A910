`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// Design Name: 
// Module Name: MEM_WB
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


`include "defines.vh"

module MEM_WB(
    input                       clk       ,
    input                       rst       ,
    // 陷阱重定向时必须能清空这一级:
    // 发出重定向的那条指令此刻正在 WB 提交, 而【比它年轻、已经走到 MEM】的
    // 那条必须被丢掉. 本模块原本既没有 stall 也没有 flush 端口, 会照常锁存,
    // 于是被冲刷的年轻指令下一拍照样提交 —— 所以这个端口是必需的.
    input                       flush     ,
    input                       mem_irq_safe ,
    input                       mem_exc_valid,
    input [3:0]                 mem_exc_cause,
    input [31:0]                mem_exc_tval ,
    input                       mem_is_mret  ,
    input                       mem_csr_we   ,
    input                       mem_rf_we ,
    // 这条指令是乘法: 它的结果不在 mem_wD 里, 由 mycpu.v 在 WB 级换进 wb_wD
    // (必须和其余 payload 走**同一条条件链**, 否则会出现"is_mul 还挂着、
    //  payload 已被冲掉"的幽灵指令).
    input                       mem_is_mul ,
    input [4:0]                mem_wR    ,
    input [31:0]                mem_wD    ,
    output reg                  wb_irq_safe  ,
    output reg                  wb_exc_valid ,
    output reg [3:0]            wb_exc_cause ,
    output reg [31:0]           wb_exc_tval  ,
    output reg                  wb_is_mret   ,
    output reg                  wb_csr_we    ,
    output reg                  wb_rf_we  ,
    output reg                  wb_is_mul ,
    output reg [4:0]           wb_wR     ,
    output reg [31:0]           wb_wD	,

    //trace
    input  wire [31:0] pc_i       ,
    output reg  [31:0] pc_o       ,
    input  wire        have_inst_i,
    output reg         have_inst_o
    );

// 三个 always 块的条件链必须一致 (rst/flush -> 清成气泡; 否则捕获),
// 不一致就会注入"have_inst=1 但 payload 已清零"的幽灵指令.
always @(posedge clk or posedge rst) begin
    if(rst || flush) begin
        wb_rf_we     <= 0;
        wb_is_mul    <= 1'b0;
        wb_wR        <= 0;
        wb_wD        <= 0;
        wb_irq_safe  <= 1'b1;
        wb_exc_valid <= 1'b0;
        wb_exc_cause <= 0;
        wb_exc_tval  <= 0;
        wb_is_mret   <= 1'b0;
        wb_csr_we    <= 1'b0;
    end else begin
        wb_rf_we     <= mem_rf_we ;
        wb_is_mul    <= mem_is_mul;
        wb_wR        <= mem_wR    ;
        wb_wD        <= mem_wD    ;
        wb_irq_safe  <= mem_irq_safe ;
        wb_exc_valid <= mem_exc_valid;
        wb_exc_cause <= mem_exc_cause;
        wb_exc_tval  <= mem_exc_tval ;
        wb_is_mret   <= mem_is_mret  ;
        wb_csr_we    <= mem_csr_we   ;
    end
end


//trace
always @ (posedge clk or posedge rst) begin
    if (rst || flush) pc_o <= 32'b0;
    else              pc_o <= pc_i;
end
always @ (posedge clk or posedge rst) begin
    if (rst || flush) have_inst_o <= 1'b0;
    else              have_inst_o <= have_inst_i;
end
endmodule

