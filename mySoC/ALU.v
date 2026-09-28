`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/06/30 15:15:20
// Design Name: 
// Module Name: ALU
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

module ALU(
    input [31:0] A,
    input [31:0] B,
    input [`ALU_OP_WIDTH-1:0] alu_op,
    //????
    output reg [31:0] alu_c,
    //?????
    output reg alu_f
    );


always @(*) begin
    // 六条比较指令 (BEQ/BNE/BLT/BGE/BLTU/BGEU) 只给 alu_f 赋值, 不给 alu_c ——
    // 缺这一行 Vivado 就把 alu_c 推断成 32 位 latch, 而那正是关键路径上的一段:
    // latch 迫使加法的进位链和"保持旧值"的反馈 mux 合进同一个锥, 于是比较结果
    // 也被拖到进位链后面 (实测报告里 u1_taken 前挂着 4 级 CARRY4)。
    // 比较指令不写寄存器 (rf_we=0), alu_c 唯一的去处是 Bus_raddr 那个无副作用的
    // 同步 RAM 读地址, 所以清 0 不影响任何合法指令。 (2026-09-28)
    alu_c = 32'b0;
    case (alu_op)
        `ALU_ADD: begin alu_c = A + B; alu_f = 0; end
        `ALU_SUB: begin alu_c = A + (~B + 1); alu_f = 0; end
        `ALU_AND: begin alu_c = A & B; alu_f = 0; end
        `ALU_OR: begin alu_c = A | B; alu_f = 0; end
        `ALU_XOR: begin alu_c = A ^ B; alu_f = 0; end
        `ALU_SLL: begin alu_c = A << B[4:0]; alu_f = 0; end
        `ALU_SRL: begin alu_c = A >> B[4:0]; alu_f = 0; end
        `ALU_SRA: begin alu_c = ($signed(A)) >>> B[4:0]; alu_f = 0; end
        `ALU_SLT: begin alu_c = (($signed(A)) < ($signed(B))) ? 1:0; alu_f = 0; end
        `ALU_SLTU: begin alu_c = (A<B) ? 1:0; alu_f = 0; end
        `ALU_BEQ: begin 
            if(A == B) begin
                alu_f = 1;
            end else begin
                alu_f = 0;
            end
        end
        `ALU_BNE: begin
            if(A == B) begin
                alu_f = 0;
            end else begin
                alu_f = 1;
            end
        end
        `ALU_BLT: begin
            if($signed(A)<$signed(B)) begin
                alu_f = 1;
            end else begin
                alu_f = 0;
            end
        end
        `ALU_BLTU: begin
            if(A < B) begin
                alu_f = 1;
            end else begin
                alu_f = 0;
            end
        end
        `ALU_BGE: begin
            if($signed(A) >= $signed(B)) begin
                alu_f = 1;
            end else begin
                alu_f = 0;
            end
        end
        `ALU_BGEU: begin
            if(A >= B) begin
                alu_f = 1;
            end else begin
                alu_f = 0;
            end
        end
        default: begin alu_c = 0; alu_f = 0; end
    endcase
end

endmodule

