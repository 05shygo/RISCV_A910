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

module ct_idu_rf_pipe2_div_decd (
  input  logic [31:0]  pipe2_decd_opcode,
  output logic [3:0]   pipe2_decd_div_sel   // 4 位独热码判断除法/取余类型
);

//==========================================================
//              独热码 除法/取余 运算类型编码
//==========================================================
// 每一位代表一种操作，只有 1 位为 1
localparam logic [3:0] DIV_DIV  = 4'd1 << 0;   // DIV   (有符号除法)
localparam logic [3:0] DIV_DIVU = 4'd1 << 1;   // DIVU  (无符号除法)
localparam logic [3:0] DIV_REM  = 4'd1 << 2;   // REM   (有符号取余)
localparam logic [3:0] DIV_REMU = 4'd1 << 3;   // REMU  (无符号取余)

//==========================================================
//                      字段提取
//==========================================================
logic [6:0] opcode;
logic [2:0] funct3;
logic [6:0] funct7;

assign opcode = pipe2_decd_opcode[6:0];
assign funct3 = pipe2_decd_opcode[14:12];
assign funct7 = pipe2_decd_opcode[31:25];

//==========================================================
//                      译码逻辑
//==========================================================
always_comb begin
  // 默认值初始化，非除法指令时输出全 0
  pipe2_decd_div_sel = 4'b0000;

  // 判断是否为 OP 指令，且 funct7 为 M 扩展标志 (0000001)
  if (opcode == 7'b0110011 && funct7 == 7'b0000001) begin
    case (funct3)
      3'b100: pipe2_decd_div_sel = DIV_DIV;     // DIV
      3'b101: pipe2_decd_div_sel = DIV_DIVU;    // DIVU
      3'b110: pipe2_decd_div_sel = DIV_REM;     // REM
      3'b111: pipe2_decd_div_sel = DIV_REMU;    // REMU
      default: pipe2_decd_div_sel = 4'b0000;    // 乘法指令 (000~011) 或其他非法情况
    endcase
  end
end

endmodule