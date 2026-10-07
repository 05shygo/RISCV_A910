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

module ct_idu_rf_pipe3_decd (
  input  logic [31:0]  pipe3_decd_opcode,
  output logic [11:0]  pipe3_decd_offset,
  output logic [12:0]  pipe3_decd_offset_plus,
  output logic         pipe3_decd_sign_extend,
  output logic [1:0]   pipe3_decd_inst_size
);

//==========================================================
//                      字段提取
//==========================================================
logic [6:0] opcode;
logic [2:0] funct3;

assign opcode = pipe3_decd_opcode[6:0];
assign funct3 = pipe3_decd_opcode[14:12];

//==========================================================
//                       Decode
//==========================================================
always_comb begin
  // 默认值初始化，防止生成 Latch
  pipe3_decd_offset      = 12'b0;
  pipe3_decd_sign_extend = 1'b0;
  pipe3_decd_inst_size   = 2'b00;

  case (opcode)
    // ================== LOAD (I-type) ==================
    7'b0000011: begin
      pipe3_decd_offset      = pipe3_decd_opcode[31:20]; // I-type 12 位立即数
      pipe3_decd_sign_extend = 1'b1;                     // 默认为有符号扩展
      case (funct3)
        3'b000: pipe3_decd_inst_size = 2'b00; // LB
        3'b001: pipe3_decd_inst_size = 2'b01; // LH
        3'b010: pipe3_decd_inst_size = 2'b10; // LW
        3'b100: begin                         // LBU
          pipe3_decd_inst_size   = 2'b00;
          pipe3_decd_sign_extend = 1'b0;
        end
        3'b101: begin                         // LHU
          pipe3_decd_inst_size   = 2'b01;
          pipe3_decd_sign_extend = 1'b0;
        end
        default: begin
          pipe3_decd_inst_size   = 2'b00;
          pipe3_decd_sign_extend = 1'b0;
        end
      endcase
    end

    // ================== STORE (S-type) ==================
    7'b0100011: begin
      // S-type 立即数拼接：{imm[11:5], imm[4:0]}
      pipe3_decd_offset      = {pipe3_decd_opcode[31:25], pipe3_decd_opcode[11:7]};
      pipe3_decd_sign_extend = 1'b0; // Store 不需要符号扩展
      case (funct3)
        3'b000: pipe3_decd_inst_size = 2'b00; // SB
        3'b001: pipe3_decd_inst_size = 2'b01; // SH
        3'b010: pipe3_decd_inst_size = 2'b10; // SW
        default: pipe3_decd_inst_size = 2'b00;
      endcase
    end

    // ================== 其它 RV32I 指令 ==================
    default: begin
      pipe3_decd_offset      = 12'b0;
      pipe3_decd_sign_extend = 1'b0;
      pipe3_decd_inst_size   = 2'b00;
    end
  endcase
end

//==========================================================
//              Offset Plus 计算
//==========================================================
// 保留原逻辑：符号扩展后加 16（用于某些微架构的非对齐访存或 Cache line 边界处理）
assign pipe3_decd_offset_plus[12:0] = {pipe3_decd_offset[11], pipe3_decd_offset[11:0]} + 13'h10;

endmodule