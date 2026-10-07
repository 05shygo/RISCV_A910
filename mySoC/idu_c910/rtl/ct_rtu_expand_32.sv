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

//==========================================================
// 5 位编号展开成 32 位独热
//==========================================================
// 移植自 C910 `gen_rtl/rtu/rtl/ct_rtu_expand_32.v`（接口与时序逐位一致）。
// 同事的 RV32I-idu 里 ct_idu_ir_rt.sv 例化了 3 次这个模块（分别展开三路的
// dst_reg_lsb），但没有把文件带过来 —— 缺它整棵 IDU 都 elaborate 不过。
// 放在这里而不是 rtu 目录：它只被 IDU 用。
//==========================================================

module ct_rtu_expand_32 (
  input  wire [4:0]  x_num,
  output wire [31:0] x_num_expand
);

assign x_num_expand[0]  = (x_num[4:0] == 5'd0);
assign x_num_expand[1]  = (x_num[4:0] == 5'd1);
assign x_num_expand[2]  = (x_num[4:0] == 5'd2);
assign x_num_expand[3]  = (x_num[4:0] == 5'd3);
assign x_num_expand[4]  = (x_num[4:0] == 5'd4);
assign x_num_expand[5]  = (x_num[4:0] == 5'd5);
assign x_num_expand[6]  = (x_num[4:0] == 5'd6);
assign x_num_expand[7]  = (x_num[4:0] == 5'd7);
assign x_num_expand[8]  = (x_num[4:0] == 5'd8);
assign x_num_expand[9]  = (x_num[4:0] == 5'd9);
assign x_num_expand[10] = (x_num[4:0] == 5'd10);
assign x_num_expand[11] = (x_num[4:0] == 5'd11);
assign x_num_expand[12] = (x_num[4:0] == 5'd12);
assign x_num_expand[13] = (x_num[4:0] == 5'd13);
assign x_num_expand[14] = (x_num[4:0] == 5'd14);
assign x_num_expand[15] = (x_num[4:0] == 5'd15);
assign x_num_expand[16] = (x_num[4:0] == 5'd16);
assign x_num_expand[17] = (x_num[4:0] == 5'd17);
assign x_num_expand[18] = (x_num[4:0] == 5'd18);
assign x_num_expand[19] = (x_num[4:0] == 5'd19);
assign x_num_expand[20] = (x_num[4:0] == 5'd20);
assign x_num_expand[21] = (x_num[4:0] == 5'd21);
assign x_num_expand[22] = (x_num[4:0] == 5'd22);
assign x_num_expand[23] = (x_num[4:0] == 5'd23);
assign x_num_expand[24] = (x_num[4:0] == 5'd24);
assign x_num_expand[25] = (x_num[4:0] == 5'd25);
assign x_num_expand[26] = (x_num[4:0] == 5'd26);
assign x_num_expand[27] = (x_num[4:0] == 5'd27);
assign x_num_expand[28] = (x_num[4:0] == 5'd28);
assign x_num_expand[29] = (x_num[4:0] == 5'd29);
assign x_num_expand[30] = (x_num[4:0] == 5'd30);
assign x_num_expand[31] = (x_num[4:0] == 5'd31);

endmodule
