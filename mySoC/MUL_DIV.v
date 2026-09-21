`timescale 1ns / 1ps
`include "defines.vh"

// RV32M 乘除法单元
module MUL_DIV(
    input wire clk,
    input wire rst,
    input wire [31:0] A,
    input wire [31:0] B,
    input wire [`ALU_OP_WIDTH-1:0] alu_op,
    input wire valid_i,              // 输入有效信号
    
    output reg [31:0] result,
    output reg ready_o,              // 结果准备好信号
    output reg busy_o                // 忙碌信号
);

// 乘法器 - 使用3级流水线
reg [63:0] mul_result_stage1;
reg [63:0] mul_result_stage2;
reg [63:0] mul_result_stage3;
// 必须与 ALU_OP_WIDTH 同宽: ALU_MUL=16 需要 5 位, 用 4 位会被截断成
// ALU_ADD(0), 导致下面的输出 case 永远匹配不到 ALU_MUL 而返回 0.
reg [`ALU_OP_WIDTH-1:0] mul_op_stage1, mul_op_stage2, mul_op_stage3;
reg mul_valid_stage1, mul_valid_stage2, mul_valid_stage3;

// 除法器状态机
localparam DIV_IDLE = 2'b00;
localparam DIV_CALC = 2'b01;
localparam DIV_DONE = 2'b10;

reg [1:0] div_state;
// 需要能表示到 32, 否则 `div_cnt < 32` 恒为真, DIV_DONE 永不可达.
reg [5:0] div_cnt;
reg [31:0] dividend_abs, divisor_abs;
reg [31:0] dividend_orig;     // 原始被除数, 供除零时的 REM/REMU 使用
reg [63:0] remainder;
reg [63:0] remainder_shift;   // DIV_CALC 的组合临时值（阻塞赋值）
reg [31:0] quotient;
reg div_sign_q, div_sign_r;
reg div_by_zero;
reg [`ALU_OP_WIDTH-1:0] div_op_save;  // 同上: ALU_DIV=20 也需要 5 位

// 辅助信号
wire is_mul = (alu_op == `ALU_MUL || alu_op == `ALU_MULH ||
               alu_op == `ALU_MULHSU || alu_op == `ALU_MULHU);
wire is_div = (alu_op == `ALU_DIV || alu_op == `ALU_DIVU ||
               alu_op == `ALU_REM || alu_op == `ALU_REMU);

// 乘法流水线是否空闲.
// 关键: CPU 在等待 ready_o 期间会一直保持 valid_i 为高 (因为它把这条
// MUL 保持在 EX 级). 若不加这个条件, 3 级流水线会被同一条指令反复灌入,
// 于是 mul_valid_stage3 不止一拍为高 —— 下一条紧邻的 MUL 进入 EX 时会看到
// 残留的 ready_o=1, 既不产生停顿, 又取走一个陈旧的 stage3 值 (写回 0).
wire mul_pipe_empty = ~(mul_valid_stage1 | mul_valid_stage2 | mul_valid_stage3);

// 乘法器逻辑（3级流水线，兼容）
always @(posedge clk or posedge rst) begin
    if (rst) begin
        mul_result_stage1 <= 64'b0;
        mul_result_stage2 <= 64'b0;
        mul_result_stage3 <= 64'b0;
        mul_op_stage1 <= 4'b0;
        mul_op_stage2 <= 4'b0;
        mul_op_stage3 <= 4'b0;
        mul_valid_stage1 <= 1'b0;
        mul_valid_stage2 <= 1'b0;
        mul_valid_stage3 <= 1'b0;
    end else begin
        // Stage 1: 计算乘法 (仅在流水线排空时接受新操作)
        if (valid_i && is_mul && mul_pipe_empty) begin
            case (alu_op)
                `ALU_MUL, `ALU_MULH: begin
                    // 有符号乘法
                    mul_result_stage1 <= $signed(A) * $signed(B);
                end
                `ALU_MULHSU: begin
                    // A有符号，B无符号
                    mul_result_stage1 <= $signed(A) * $signed({1'b0, B});
                end
                `ALU_MULHU: begin
                    // 无符号乘法
                    mul_result_stage1 <= A * B;
                end
                default: mul_result_stage1 <= 64'b0;
            endcase
            mul_op_stage1 <= alu_op;
            mul_valid_stage1 <= 1'b1;
        end else begin
            mul_valid_stage1 <= 1'b0;
        end
        
        // Stage 2: 流水线
        mul_result_stage2 <= mul_result_stage1;
        mul_op_stage2 <= mul_op_stage1;
        mul_valid_stage2 <= mul_valid_stage1;
        
        // Stage 3: 流水线
        mul_result_stage3 <= mul_result_stage2;
        mul_op_stage3 <= mul_op_stage2;
        mul_valid_stage3 <= mul_valid_stage2;
    end
end

// 除法器逻辑（恢复余数算法，32周期）
always @(posedge clk or posedge rst) begin
    if (rst) begin
        div_state <= DIV_IDLE;
        div_cnt <= 6'b0;
        dividend_abs <= 32'b0;
        divisor_abs <= 32'b0;
        dividend_orig <= 32'b0;
        remainder <= 64'b0;
        quotient <= 32'b0;
        div_sign_q <= 1'b0;
        div_sign_r <= 1'b0;
        div_by_zero <= 1'b0;
        div_op_save <= 4'b0;
    end else begin
        case (div_state)
            DIV_IDLE: begin
                if (valid_i && is_div) begin
                    // 保存操作码
                    div_op_save <= alu_op;

                    // 检查除零
                    div_by_zero <= (B == 32'b0);
                    dividend_orig <= A;

                    // 计算符号
                    case (alu_op)
                        `ALU_DIV: begin
                            div_sign_q <= A[31] ^ B[31];
                            div_sign_r <= A[31];
                            dividend_abs <= A[31] ? (~A + 1) : A;
                            divisor_abs <= B[31] ? (~B + 1) : B;
                        end
                        `ALU_REM: begin
                            div_sign_q <= A[31] ^ B[31];
                            div_sign_r <= A[31];
                            dividend_abs <= A[31] ? (~A + 1) : A;
                            divisor_abs <= B[31] ? (~B + 1) : B;
                        end
                        default: begin // DIVU, REMU
                            div_sign_q <= 1'b0;
                            div_sign_r <= 1'b0;
                            dividend_abs <= A;
                            divisor_abs <= B;
                        end
                    endcase

                    remainder <= {32'b0, A};
                    quotient <= 32'b0;
                    div_cnt <= 6'b0;
                    div_state <= DIV_CALC;
                end
            end

            DIV_CALC: begin
                if (div_cnt < 32) begin
                    // 恢复余数除法算法.
                    // 必须先用阻塞赋值把移位结果算到临时变量, 再拿它做比较和
                    // 相减: 直接对 remainder 用非阻塞赋值时, if 里读到的是移位
                    // 前的旧值; 而且 "整体左移" 与 "只减高 32 位" 两条赋值混用
                    // 会让高位那次赋值覆盖掉移位进来的进位 (丢掉 remainder[31]),
                    // 结果会算错 (100/7 得到 5 而不是 14).
                    remainder_shift = {remainder[62:0], 1'b0};

                    if (remainder_shift[63:32] >= divisor_abs) begin
                        remainder <= {remainder_shift[63:32] - divisor_abs,
                                      remainder_shift[31:0]};
                        quotient <= {quotient[30:0], 1'b1};
                    end else begin
                        remainder <= remainder_shift;
                        quotient <= {quotient[30:0], 1'b0};
                    end

                    div_cnt <= div_cnt + 1;
                end else begin
                    div_state <= DIV_DONE;
                end
            end

            DIV_DONE: begin
                div_state <= DIV_IDLE;
            end

            default: div_state <= DIV_IDLE;
        endcase
    end
end

// 输出逻辑
always @(*) begin
    result = 32'b0;
    ready_o = 1'b0;
    busy_o = 1'b0;
    
    // 乘法结果（3周期延迟）
    if (mul_valid_stage3) begin
        case (mul_op_stage3)
            `ALU_MUL: result = mul_result_stage3[31:0];
            `ALU_MULH, `ALU_MULHSU, `ALU_MULHU: result = mul_result_stage3[63:32];
            default: result = 32'b0;
        endcase
        ready_o = 1'b1;
    end
    
    // 除法结果
    if (div_state == DIV_DONE) begin
        if (div_by_zero) begin
            // 除零处理
            case (div_op_save)
                `ALU_DIV, `ALU_DIVU: result = 32'hFFFFFFFF;
                // 除零时 REM/REMU 返回原始被除数 rs1 (不是它的绝对值).
                `ALU_REM, `ALU_REMU: result = dividend_orig;
                default: result = 32'b0;
            endcase
        end else begin
            case (div_op_save)
                `ALU_DIV: result = div_sign_q ? (~quotient + 1) : quotient;
                `ALU_DIVU: result = quotient;
                // 恢复余数算法跑完后, 最终余数留在 remainder 的【高 32 位】,
                // 低 32 位是移位过程中被除数移出的比特, 不是余数.
                `ALU_REM: result = div_sign_r ? (~remainder[63:32] + 1) : remainder[63:32];
                `ALU_REMU: result = remainder[63:32];
                default: result = 32'b0;
            endcase
        end
        ready_o = 1'b1;
    end
    
    // 忙碌信号
    busy_o = (div_state == DIV_CALC) || 
             mul_valid_stage1 || mul_valid_stage2;
end

endmodule
