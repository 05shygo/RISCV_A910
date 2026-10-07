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

module ct_idu_rf_pipe1_decd (
  input  logic [31:0]  pipe1_decd_opcode,
  output logic [3:0]   pipe1_decd_mul_sel   // 4 位独热码判断乘法类型
);

//==========================================================
//              独热码 乘法 运算类型编码
//==========================================================
// 每一位代表一种操作，只有 1 位为 1
localparam logic [3:0] MUL_MUL    = 4'd1 << 0;   // MUL     (有符号×有符号，取低 32 位)
localparam logic [3:0] MUL_MULH   = 4'd1 << 1;   // MULH    (有符号×有符号，取高 32 位)
localparam logic [3:0] MUL_MULHSU = 4'd1 << 2;   // MULHSU  (有符号×无符号，取高 32 位)
localparam logic [3:0] MUL_MULHU  = 4'd1 << 3;   // MULHU   (无符号×无符号，取高 32 位)

//==========================================================
//                      字段提取
//==========================================================
logic [6:0] opcode;
logic [2:0] funct3;
logic [6:0] funct7;

assign opcode = pipe1_decd_opcode[6:0];
assign funct3 = pipe1_decd_opcode[14:12];
assign funct7 = pipe1_decd_opcode[31:25];

//==========================================================
//                      译码逻辑
//==========================================================
always_comb begin
  // 默认值初始化，非乘法指令时输出全 0
  pipe1_decd_mul_sel = 4'b0000;

  // 判断是否为 OP 指令，且 funct7 为 M 扩展标志 (0000001)
  if (opcode == 7'b0110011 && funct7 == 7'b0000001) begin
    case (funct3)
      3'b000: pipe1_decd_mul_sel = MUL_MUL;     // MUL
      3'b001: pipe1_decd_mul_sel = MUL_MULH;    // MULH
      3'b010: pipe1_decd_mul_sel = MUL_MULHSU;  // MULHSU
      3'b011: pipe1_decd_mul_sel = MUL_MULHU;   // MULHU
      default: pipe1_decd_mul_sel = 4'b0000;    // 除法/取余 (100~111) 或其他非法情况
    endcase
  end
end

endmodule