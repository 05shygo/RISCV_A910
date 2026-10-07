/*Copyright 2019-2021 T-Head Semiconductor Co., Ltd.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

module ct_idu_rf_pipe0_decd (
  input  logic [31:0]  pipe0_decd_opcode,
  output logic [12:0]  pipe0_decd_sel,   // 13 位独热码 ALU 运算类型
  output logic [31:0]  pipe0_decd_imm    // 立即数输出
);

//==========================================================
//              独热码 ALU 运算类型编码
//==========================================================
// 每一位代表一种操作，只有 1 位为 1
localparam logic [12:0] ALU_ADD     = 13'd1 << 0;   // ADD / ADDI
localparam logic [12:0] ALU_SUB     = 13'd1 << 1;   // SUB
localparam logic [12:0] ALU_SLL     = 13'd1 << 2;   // SLL / SLLI
localparam logic [12:0] ALU_SLT     = 13'd1 << 3;   // SLT / SLTI
localparam logic [12:0] ALU_SLTU    = 13'd1 << 4;   // SLTU / SLTIU
localparam logic [12:0] ALU_XOR     = 13'd1 << 5;   // XOR / XORI
localparam logic [12:0] ALU_SRL     = 13'd1 << 6;   // SRL / SRLI
localparam logic [12:0] ALU_SRA     = 13'd1 << 7;   // SRA / SRAI
localparam logic [12:0] ALU_OR      = 13'd1 << 8;   // OR / ORI
localparam logic [12:0] ALU_AND     = 13'd1 << 9;   // AND / ANDI
localparam logic [12:0] ALU_LUI     = 13'd1 << 10;  // LUI
localparam logic [12:0] ALU_AUIPC   = 13'd1 << 11;  // AUIPC
localparam logic [12:0] ALU_ILLEGAL = 13'd1 << 12;  // 非本模块支持指令

//==========================================================
//                      字段提取
//==========================================================
logic [6:0] opcode;
logic [2:0] funct3;
logic [6:0] funct7;

assign opcode = pipe0_decd_opcode[6:0];
assign funct3 = pipe0_decd_opcode[14:12];
assign funct7 = pipe0_decd_opcode[31:25];

// 提取 I-type 立即数 (12 位符号扩展至 32 位)
logic [31:0] imm_i;
assign imm_i = {{20{pipe0_decd_opcode[31]}}, pipe0_decd_opcode[31:20]};

//==========================================================
//                      译码逻辑
//==========================================================
always_comb begin
  // 默认值初始化，防止生成 Latch
  pipe0_decd_sel = ALU_ILLEGAL;
  pipe0_decd_imm = 32'd0;

  case (opcode)

    // ================= R-type: OP =================
    7'b0110011: begin
      case (funct3)
        3'b000: begin
          if      (funct7 == 7'b0000000) pipe0_decd_sel = ALU_ADD;
          else if (funct7 == 7'b0100000) pipe0_decd_sel = ALU_SUB;
          else                           pipe0_decd_sel = ALU_ILLEGAL;
        end

        3'b001: pipe0_decd_sel = (funct7 == 7'b0000000) ? ALU_SLL  : ALU_ILLEGAL;
        3'b010: pipe0_decd_sel = (funct7 == 7'b0000000) ? ALU_SLT  : ALU_ILLEGAL;
        3'b011: pipe0_decd_sel = (funct7 == 7'b0000000) ? ALU_SLTU : ALU_ILLEGAL;
        3'b100: pipe0_decd_sel = (funct7 == 7'b0000000) ? ALU_XOR  : ALU_ILLEGAL;

        3'b101: begin
          if      (funct7 == 7'b0000000) pipe0_decd_sel = ALU_SRL;
          else if (funct7 == 7'b0100000) pipe0_decd_sel = ALU_SRA;
          else                           pipe0_decd_sel = ALU_ILLEGAL;
        end

        3'b110: pipe0_decd_sel = (funct7 == 7'b0000000) ? ALU_OR   : ALU_ILLEGAL;
        3'b111: pipe0_decd_sel = (funct7 == 7'b0000000) ? ALU_AND  : ALU_ILLEGAL;

        default: pipe0_decd_sel = ALU_ILLEGAL;
      endcase
    end

    // ================= I-type: OP-IMM =================
    7'b0010011: begin
      // I-type 算术指令，输出立即数
      pipe0_decd_imm = imm_i;

      case (funct3)
        3'b000: pipe0_decd_sel = ALU_ADD;    // ADDI
        3'b010: pipe0_decd_sel = ALU_SLT;    // SLTI
        3'b011: pipe0_decd_sel = ALU_SLTU;   // SLTIU
        3'b100: pipe0_decd_sel = ALU_XOR;    // XORI
        3'b110: pipe0_decd_sel = ALU_OR;     // ORI
        3'b111: pipe0_decd_sel = ALU_AND;    // ANDI

        3'b001: begin                        // SLLI
          if (funct7 == 7'b0000000) pipe0_decd_sel = ALU_SLL;
          else                      pipe0_decd_sel = ALU_ILLEGAL;
        end

        3'b101: begin                        // SRLI / SRAI
          if      (funct7 == 7'b0000000) pipe0_decd_sel = ALU_SRL;
          else if (funct7 == 7'b0100000) pipe0_decd_sel = ALU_SRA;
          else                           pipe0_decd_sel = ALU_ILLEGAL;
        end

        default: pipe0_decd_sel = ALU_ILLEGAL;
      endcase
    end

    // ================= U-type: LUI / AUIPC =================
    7'b0110111: pipe0_decd_sel = ALU_LUI;
    7'b0010111: pipe0_decd_sel = ALU_AUIPC;

    default: begin
      pipe0_decd_sel = ALU_ILLEGAL;
      pipe0_decd_imm = 32'd0;
    end
  endcase
end

endmodule