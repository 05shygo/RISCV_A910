`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
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


// ---------------------------------------------------------------------------
// [C5] 比较/分支判决改浅结构: 32 位 `<` 挤在一条进位链里 -> 关键路径上占 4 级 CARRY4。
//      这里拆成 4 个 8 位比较 (各自 2 级 CARRY4, 并行) + 组间优先 (2~3 级 LUT)。
//      逻辑等价 (逐位推导):
//        无符号 A<B  ⟺  最高"不等字节"处 A<B  ⟺  l3 | (e3 & (l2 | (e2 & (l1 | (e1 & l0)))))
//        有符号 A<B  ⟺  符号不同时看 A[31]; 相同时与无符号比较相同 (标准恒等)
//        相等        ⟺  逐字节等
//      alu_f/alu_c 的取值与原 case 逐位一致, 只是不再走整条 32 位链。
// ---------------------------------------------------------------------------
wire [7:0] bx0 = A[7:0]   ^ B[7:0];
wire [7:0] bx1 = A[15:8]  ^ B[15:8];
wire [7:0] bx2 = A[23:16] ^ B[23:16];
wire [7:0] bx3 = A[31:24] ^ B[31:24];
wire e0 = ~|bx0, e1 = ~|bx1, e2 = ~|bx2, e3 = ~|bx3;
wire l0 = (A[7:0]   < B[7:0]);
wire l1 = (A[15:8]  < B[15:8]);
wire l2 = (A[23:16] < B[23:16]);
wire l3 = (A[31:24] < B[31:24]);
wire ltu = l3 | (e3 & (l2 | (e2 & (l1 | (e1 & l0)))));
wire eqv = e3 & e2 & e1 & e0;
wire sgn = A[31] ^ B[31];
wire lts = sgn ? A[31] : ltu;

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
        `ALU_SLT: begin alu_c = {31'b0, lts}; alu_f = 0; end
        `ALU_SLTU: begin alu_c = {31'b0, ltu}; alu_f = 0; end
        `ALU_BEQ: begin alu_c = 32'b0; alu_f = eqv; end
        `ALU_BNE: begin alu_c = 32'b0; alu_f = ~eqv; end
        `ALU_BLT: begin alu_c = 32'b0; alu_f = lts; end
        `ALU_BLTU: begin alu_c = 32'b0; alu_f = ltu; end
        `ALU_BGE: begin alu_c = 32'b0; alu_f = ~lts; end
        `ALU_BGEU: begin alu_c = 32'b0; alu_f = ~ltu; end
        default: begin alu_c = 0; alu_f = 0; end
    endcase
end

endmodule

