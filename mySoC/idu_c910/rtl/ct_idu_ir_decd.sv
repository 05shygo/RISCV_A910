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

// &ModuleBeg; @26
// RV32I Simplified Version - Only essential outputs
module ct_idu_ir_decd (
  input  logic [31:0]  x_opcode,
  input  logic         x_type_alu,
  output logic         x_alu_short,
  output logic         x_load,
  output logic         x_store
);

//==========================================================
//                     Internal Signals
//==========================================================
logic decd_alu_short;
logic decd_load;
logic decd_store;

//==========================================================
//                     Output Decode
//==========================================================
assign x_load      = decd_load;
assign x_store     = decd_store;
assign x_alu_short = decd_alu_short;

//==========================================================
//                      Short ALU
//==========================================================
// Long ALU do not forward data in EX1
assign decd_alu_short = x_type_alu;

//==========================================================
//                   Load and Store
//==========================================================
//----------------------------------------------------------
//                   Load Instruction
//----------------------------------------------------------
assign decd_load =
     ({x_opcode[14:12], x_opcode[6:0]} == 10'b000_0000011) // lb
  || ({x_opcode[14:12], x_opcode[6:0]} == 10'b001_0000011) // lh
  || ({x_opcode[14:12], x_opcode[6:0]} == 10'b010_0000011) // lw
  || ({x_opcode[14:12], x_opcode[6:0]} == 10'b100_0000011) // lbu
  || ({x_opcode[14:12], x_opcode[6:0]} == 10'b101_0000011); // lhu

//----------------------------------------------------------
//                   Store Instruction
//----------------------------------------------------------
// RV32I: sb, sh, sw
assign decd_store =
     ({x_opcode[14:12], x_opcode[6:0]} == 10'b000_0100011) // sb
  || ({x_opcode[14:12], x_opcode[6:0]} == 10'b001_0100011) // sh
  || ({x_opcode[14:12], x_opcode[6:0]} == 10'b010_0100011); // sw

// &ModuleEnd; @511
endmodule