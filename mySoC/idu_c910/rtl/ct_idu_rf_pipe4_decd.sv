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

module ct_idu_rf_pipe4_decd (
  input  logic [31:0]  pipe4_decd_opcode,
  output logic [11:0]  pipe4_decd_offset,
  output logic [12:0]  pipe4_decd_offset_plus,
  output logic [1:0]   pipe4_decd_inst_size
);

//==========================================================
//                      字段提取
//==========================================================
logic [6:0] opcode;
logic [2:0] funct3;

assign opcode = pipe4_decd_opcode[6:0];
assign funct3 = pipe4_decd_opcode[14:12];

//==========================================================
//                       Decode
//==========================================================
always_comb begin
  // 默认值初始化，非 Store 指令输出全 0，防止生成 Latch
  pipe4_decd_offset    = 12'b0;
  pipe4_decd_inst_size = 2'b00;

  // 判断 Opcode 是否为 STORE (0100011)
  if (opcode == 7'b0100011) begin
    // S-type 12 位立即数拼接：{imm[11:5], imm[4:0]}
    pipe4_decd_offset = {pipe4_decd_opcode[31:25], pipe4_decd_opcode[11:7]};

    // Store 指令不需要将数据符号扩展至 32 位，因此 sign_extend 固定为 0

    case (funct3)
      3'b000: pipe4_decd_inst_size = 2'b00; // SB
      3'b001: pipe4_decd_inst_size = 2'b01; // SH
      3'b010: pipe4_decd_inst_size = 2'b10; // SW
      default: pipe4_decd_inst_size = 2'b00; // 非法 Store 指令
    endcase
  end
end

//==========================================================
//              Offset Plus 计算
//==========================================================
// 保留原逻辑：符号扩展后加 16
assign pipe4_decd_offset_plus[12:0] = {pipe4_decd_offset[11], pipe4_decd_offset[11:0]} + 13'h10;

endmodule