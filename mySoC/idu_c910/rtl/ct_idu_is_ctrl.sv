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

module ct_idu_is_ctrl (
  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         forever_clk,
  input  logic         cpurst_b,

  input  logic         aiq_ctrl_1_left_updt,
  input  logic         aiq_ctrl_full_updt,
  input  logic         biq_ctrl_1_left_updt,
  input  logic         biq_ctrl_full_updt,

  input  logic         ctrl_ir_pipedown_inst0_vld,
  input  logic         ctrl_ir_pipedown_inst1_vld,
  input  logic         ctrl_ir_pipedown_inst2_vld,

  input  logic         ctrl_ir_pre_dis_aiq_create0_en,
  input  logic [1:0]   ctrl_ir_pre_dis_aiq_create0_sel,
  input  logic         ctrl_ir_pre_dis_aiq_create1_en,
  input  logic [1:0]   ctrl_ir_pre_dis_aiq_create1_sel,

  input  logic         ctrl_ir_pre_dis_biq_create0_en,
  input  logic [1:0]   ctrl_ir_pre_dis_biq_create0_sel,
  input  logic         ctrl_ir_pre_dis_biq_create1_en,
  input  logic [1:0]   ctrl_ir_pre_dis_biq_create1_sel,

  input  logic         ctrl_ir_pre_dis_inst0_vld,
  input  logic         ctrl_ir_pre_dis_inst1_vld,
  input  logic         ctrl_ir_pre_dis_inst2_vld,
  input  logic         ctrl_ir_pre_dis_inst3_vld,

  input  logic         ctrl_ir_pre_dis_lsiq_create0_en,
  input  logic [1:0]   ctrl_ir_pre_dis_lsiq_create0_sel,
  input  logic         ctrl_ir_pre_dis_lsiq_create1_en,
  input  logic [1:0]   ctrl_ir_pre_dis_lsiq_create1_sel,

  input  logic         ctrl_ir_pre_dis_pipedown2,

  input  logic         ctrl_ir_pre_dis_sdiq_create0_en,
  input  logic [1:0]   ctrl_ir_pre_dis_sdiq_create0_sel,
  input  logic         ctrl_ir_pre_dis_sdiq_create1_en,
  input  logic [1:0]   ctrl_ir_pre_dis_sdiq_create1_sel,

  input  logic         ctrl_ir_pre_dis_mult_create0_en,
  input  logic [1:0]   ctrl_ir_pre_dis_mult_create0_sel,
  input  logic         ctrl_ir_pre_dis_mult_create1_en,
  input  logic [1:0]   ctrl_ir_pre_dis_mult_create1_sel,

  input  logic         ctrl_ir_pre_dis_div_create0_en,
  input  logic [1:0]   ctrl_ir_pre_dis_div_create0_sel,
  input  logic         ctrl_ir_pre_dis_div_create1_en,
  input  logic [1:0]   ctrl_ir_pre_dis_div_create1_sel,

  input  logic         dp_ctrl_is_inst0_dst_vld,
  input  logic         dp_ctrl_is_inst1_dst_vld,
  input  logic         dp_ctrl_is_inst2_dst_vld,
  input  logic         dp_ctrl_is_inst3_dst_vld,


  input  logic         lsiq_ctrl_1_left_updt,
  input  logic         lsiq_ctrl_full_updt,

  input  logic         mult_ctrl_1_left_updt,
  input  logic         mult_ctrl_full_updt,

  input  logic         div_ctrl_1_left_updt,
  input  logic         div_ctrl_full_updt,

  input  logic         rtu_idu_rob_full,
  input  logic         rtu_yy_xx_flush,

  input  logic         sdiq_ctrl_1_left_updt,
  input  logic         sdiq_ctrl_full_updt,

  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic         ctrl_aiq_create0_en,
  output logic         ctrl_aiq_create1_en,

  output logic         ctrl_biq_create0_en,
  output logic         ctrl_biq_create1_en,

  output logic         ctrl_lsiq_create0_en,
  output logic         ctrl_lsiq_create1_en,

  output logic         ctrl_sdiq_create0_en,
  output logic         ctrl_sdiq_create1_en,

  output logic         ctrl_mult_create0_en,
  output logic         ctrl_mult_create1_en,

  output logic         ctrl_div_create0_en,
  output logic         ctrl_div_create1_en,

  output logic         ctrl_dp_dis_inst0_preg_vld,
  output logic         ctrl_dp_dis_inst1_preg_vld,
  output logic         ctrl_dp_dis_inst2_preg_vld,
  output logic         ctrl_dp_dis_inst3_preg_vld,

  output logic [1:0]   ctrl_dp_is_dis_aiq_create0_sel,
  output logic [1:0]   ctrl_dp_is_dis_aiq_create1_sel,
  output logic [1:0]   ctrl_dp_is_dis_biq_create0_sel,
  output logic [1:0]   ctrl_dp_is_dis_biq_create1_sel,
  output logic [1:0]   ctrl_dp_is_dis_lsiq_create0_sel,
  output logic [1:0]   ctrl_dp_is_dis_lsiq_create1_sel,
  output logic [1:0]   ctrl_dp_is_dis_sdiq_create0_sel,
  output logic [1:0]   ctrl_dp_is_dis_sdiq_create1_sel,
  output logic [1:0]   ctrl_dp_is_dis_mult_create0_sel,
  output logic [1:0]   ctrl_dp_is_dis_mult_create1_sel,
  output logic [1:0]   ctrl_dp_is_dis_div_create0_sel,
  output logic [1:0]   ctrl_dp_is_dis_div_create1_sel,

  output logic         ctrl_dp_is_dis_stall,

  output logic         ctrl_dp_is_inst0_vld,
  output logic         ctrl_dp_is_inst1_vld,
  output logic         ctrl_dp_is_inst2_vld,

  output logic         ctrl_is_inst2_vld,
  output logic         ctrl_is_stall,

  output logic [1:0]   ctrl_xx_is_inst0_sel,

  // 【2026-10-08 新增】派遣记录用: 车道 k 本拍**真的派发**
  // ⚠️ 与上面那个 ctrl_dp_dis_inst{k}_preg_vld 不是一回事 —— 那个还串了
  //    `dp_ctrl_is_inst{k}_dst_vld` (只在该路**写寄存器**时有效)。RTU 的
  //    `disp{k}_vld` 要的是"这一路有一条真指令离开 ID", **不管它写不写寄存器**
  //    (store / 分支 / 跳转都不写 rd, 但都要建 ROB 表项)。
  output logic         ctrl_dp_dis_inst0_vld,
  output logic         ctrl_dp_dis_inst1_vld,
  output logic         ctrl_dp_dis_inst2_vld
);

//==========================================================
//                  Internal signals
//==========================================================
// IS pipeline registers
logic        is_inst0_vld;
logic        is_inst1_vld;
logic        is_inst2_vld;

// Dispatch control registers
logic        is_dis_inst0_vld;
logic        is_dis_inst1_vld;
logic        is_dis_inst2_vld;
logic        is_dis_inst3_vld;
logic        is_dis_pipedown2;

logic        is_dis_aiq_create0_en;
logic [1:0]  is_dis_aiq_create0_sel;
logic        is_dis_aiq_create1_en;
logic [1:0]  is_dis_aiq_create1_sel;

logic        is_dis_biq_create0_en;
logic [1:0]  is_dis_biq_create0_sel;
logic        is_dis_biq_create1_en;
logic [1:0]  is_dis_biq_create1_sel;

logic        is_dis_lsiq_create0_en;
logic [1:0]  is_dis_lsiq_create0_sel;
logic        is_dis_lsiq_create1_en;
logic [1:0]  is_dis_lsiq_create1_sel;

logic        is_dis_sdiq_create0_en;
logic [1:0]  is_dis_sdiq_create0_sel;
logic        is_dis_sdiq_create1_en;
logic [1:0]  is_dis_sdiq_create1_sel;

logic        is_dis_mult_create0_en;
logic [1:0]  is_dis_mult_create0_sel;
logic        is_dis_mult_create1_en;
logic [1:0]  is_dis_mult_create1_sel;

logic        is_dis_div_create0_en;
logic [1:0]  is_dis_div_create0_sel;
logic        is_dis_div_create1_en;
logic [1:0]  is_dis_div_create1_sel;

// Updated create enable（用于 IQ full 预判）
logic        is_dis_aiq_create0_en_updt;
logic        is_dis_aiq_create1_en_updt;
logic        is_dis_biq_create0_en_updt;
logic        is_dis_biq_create1_en_updt;
logic        is_dis_lsiq_create0_en_updt;
logic        is_dis_lsiq_create1_en_updt;
logic        is_dis_sdiq_create0_en_updt;
logic        is_dis_sdiq_create1_en_updt;
logic        is_dis_mult_create0_en_updt;
logic        is_dis_mult_create1_en_updt;
logic        is_dis_div_create0_en_updt;
logic        is_dis_div_create1_en_updt;

logic        ctrl_is_aiq_full_updt;
logic        ctrl_is_biq_full_updt;
logic        ctrl_is_lsiq_full_updt;
logic        ctrl_is_sdiq_full_updt;
logic        ctrl_is_mult_full_updt;
logic        ctrl_is_div_full_updt;
logic        ctrl_is_iq_full_updt;

logic        ctrl_is_iq_full;
logic        ctrl_is_rob_full;
logic        ctrl_is_dis_stall;

//==========================================================
//                IS pipeline registers
//==========================================================
always_ff @(posedge forever_clk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    is_inst0_vld <= 1'b0;
    is_inst1_vld <= 1'b0;
    is_inst2_vld <= 1'b0;
  end
  else if(rtu_yy_xx_flush) begin
    is_inst0_vld <= 1'b0;
    is_inst1_vld <= 1'b0;
    is_inst2_vld <= 1'b0;
  end
  else if(!ctrl_is_dis_stall) begin
    is_inst0_vld <= ctrl_ir_pipedown_inst0_vld;
    is_inst1_vld <= ctrl_ir_pipedown_inst1_vld;
    is_inst2_vld <= ctrl_ir_pipedown_inst2_vld;
  end
  else begin
    is_inst0_vld <= is_inst0_vld;
    is_inst1_vld <= is_inst1_vld;
    is_inst2_vld <= is_inst2_vld;
  end
end

assign ctrl_dp_is_inst0_vld = is_inst0_vld;
assign ctrl_dp_is_inst1_vld = is_inst1_vld;
assign ctrl_dp_is_inst2_vld = is_inst2_vld;

assign ctrl_is_inst2_vld = is_inst2_vld;

//==========================================================
//            Implement of dispatch control register
//==========================================================
always_ff @(posedge forever_clk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    is_dis_inst0_vld <= 1'b0;
    is_dis_inst1_vld <= 1'b0;
    is_dis_inst2_vld <= 1'b0;
    is_dis_pipedown2 <= 1'b0;
    is_dis_aiq_create0_en   <= 1'b0;
    is_dis_aiq_create0_sel  <= 2'b0;
    is_dis_aiq_create1_en   <= 1'b0;
    is_dis_aiq_create1_sel  <= 2'b0;

    is_dis_biq_create0_en   <= 1'b0;
    is_dis_biq_create0_sel  <= 2'b0;
    is_dis_biq_create1_en   <= 1'b0;
    is_dis_biq_create1_sel  <= 2'b0;

    is_dis_lsiq_create0_en  <= 1'b0;
    is_dis_lsiq_create0_sel <= 2'b0;
    is_dis_lsiq_create1_en  <= 1'b0;
    is_dis_lsiq_create1_sel <= 2'b0;

    is_dis_sdiq_create0_en  <= 1'b0;
    is_dis_sdiq_create0_sel <= 2'b0;
    is_dis_sdiq_create1_en  <= 1'b0;
    is_dis_sdiq_create1_sel <= 2'b0;

    is_dis_mult_create0_en  <= 1'b0;
    is_dis_mult_create0_sel <= 2'b0;
    is_dis_mult_create1_en  <= 1'b0;
    is_dis_mult_create1_sel <= 2'b0;

    is_dis_div_create0_en   <= 1'b0;
    is_dis_div_create0_sel  <= 2'b0;
    is_dis_div_create1_en   <= 1'b0;
    is_dis_div_create1_sel  <= 2'b0;
  end
  else if(rtu_yy_xx_flush) begin
    is_dis_inst0_vld <= 1'b0;
    is_dis_inst1_vld <= 1'b0;
    is_dis_inst2_vld <= 1'b0;
    is_dis_pipedown2 <= 1'b0;

    is_dis_aiq_create0_en   <= 1'b0;
    is_dis_aiq_create0_sel  <= 2'b0;
    is_dis_aiq_create1_en   <= 1'b0;
    is_dis_aiq_create1_sel  <= 2'b0;

    is_dis_biq_create0_en   <= 1'b0;
    is_dis_biq_create0_sel  <= 2'b0;
    is_dis_biq_create1_en   <= 1'b0;
    is_dis_biq_create1_sel  <= 2'b0;

    is_dis_lsiq_create0_en  <= 1'b0;
    is_dis_lsiq_create0_sel <= 2'b0;
    is_dis_lsiq_create1_en  <= 1'b0;
    is_dis_lsiq_create1_sel <= 2'b0;

    is_dis_sdiq_create0_en  <= 1'b0;
    is_dis_sdiq_create0_sel <= 2'b0;
    is_dis_sdiq_create1_en  <= 1'b0;
    is_dis_sdiq_create1_sel <= 2'b0;

    is_dis_mult_create0_en  <= 1'b0;
    is_dis_mult_create0_sel <= 2'b0;
    is_dis_mult_create1_en  <= 1'b0;
    is_dis_mult_create1_sel <= 2'b0;

    is_dis_div_create0_en   <= 1'b0;
    is_dis_div_create0_sel  <= 2'b0;
    is_dis_div_create1_en   <= 1'b0;
    is_dis_div_create1_sel  <= 2'b0;
  end
  else if(!ctrl_is_dis_stall) begin
    is_dis_inst0_vld <= ctrl_ir_pre_dis_inst0_vld;
    is_dis_inst1_vld <= ctrl_ir_pre_dis_inst1_vld;
    is_dis_inst2_vld <= ctrl_ir_pre_dis_inst2_vld;
    is_dis_pipedown2 <= ctrl_ir_pre_dis_pipedown2;

    is_dis_aiq_create0_en   <= ctrl_ir_pre_dis_aiq_create0_en;
    is_dis_aiq_create0_sel  <= ctrl_ir_pre_dis_aiq_create0_sel;
    is_dis_aiq_create1_en   <= ctrl_ir_pre_dis_aiq_create1_en;
    is_dis_aiq_create1_sel  <= ctrl_ir_pre_dis_aiq_create1_sel;

    is_dis_biq_create0_en   <= ctrl_ir_pre_dis_biq_create0_en;
    is_dis_biq_create0_sel  <= ctrl_ir_pre_dis_biq_create0_sel;
    is_dis_biq_create1_en   <= ctrl_ir_pre_dis_biq_create1_en;
    is_dis_biq_create1_sel  <= ctrl_ir_pre_dis_biq_create1_sel;

    is_dis_lsiq_create0_en  <= ctrl_ir_pre_dis_lsiq_create0_en;
    is_dis_lsiq_create0_sel <= ctrl_ir_pre_dis_lsiq_create0_sel;
    is_dis_lsiq_create1_en  <= ctrl_ir_pre_dis_lsiq_create1_en;
    is_dis_lsiq_create1_sel <= ctrl_ir_pre_dis_lsiq_create1_sel;

    is_dis_sdiq_create0_en  <= ctrl_ir_pre_dis_sdiq_create0_en;
    is_dis_sdiq_create0_sel <= ctrl_ir_pre_dis_sdiq_create0_sel;
    is_dis_sdiq_create1_en  <= ctrl_ir_pre_dis_sdiq_create1_en;
    is_dis_sdiq_create1_sel <= ctrl_ir_pre_dis_sdiq_create1_sel;

    is_dis_mult_create0_en  <= ctrl_ir_pre_dis_mult_create0_en;
    is_dis_mult_create0_sel <= ctrl_ir_pre_dis_mult_create0_sel;
    is_dis_mult_create1_en  <= ctrl_ir_pre_dis_mult_create1_en;
    is_dis_mult_create1_sel <= ctrl_ir_pre_dis_mult_create1_sel;

    is_dis_div_create0_en   <= ctrl_ir_pre_dis_div_create0_en;
    is_dis_div_create0_sel  <= ctrl_ir_pre_dis_div_create0_sel;
    is_dis_div_create1_en   <= ctrl_ir_pre_dis_div_create1_en;
    is_dis_div_create1_sel  <= ctrl_ir_pre_dis_div_create1_sel;
  end
  else begin
    is_dis_inst0_vld <= is_dis_inst0_vld;
    is_dis_inst1_vld <= is_dis_inst1_vld;
    is_dis_inst2_vld <= is_dis_inst2_vld;
    is_dis_pipedown2 <= is_dis_pipedown2;

    is_dis_aiq_create0_en   <= is_dis_aiq_create0_en;
    is_dis_aiq_create0_sel  <= is_dis_aiq_create0_sel;
    is_dis_aiq_create1_en   <= is_dis_aiq_create1_en;
    is_dis_aiq_create1_sel  <= is_dis_aiq_create1_sel;

    is_dis_biq_create0_en   <= is_dis_biq_create0_en;
    is_dis_biq_create0_sel  <= is_dis_biq_create0_sel;
    is_dis_biq_create1_en   <= is_dis_biq_create1_en;
    is_dis_biq_create1_sel  <= is_dis_biq_create1_sel;

    is_dis_lsiq_create0_en  <= is_dis_lsiq_create0_en;
    is_dis_lsiq_create0_sel <= is_dis_lsiq_create0_sel;
    is_dis_lsiq_create1_en  <= is_dis_lsiq_create1_en;
    is_dis_lsiq_create1_sel <= is_dis_lsiq_create1_sel;

    is_dis_sdiq_create0_en  <= is_dis_sdiq_create0_en;
    is_dis_sdiq_create0_sel <= is_dis_sdiq_create0_sel;
    is_dis_sdiq_create1_en  <= is_dis_sdiq_create1_en;
    is_dis_sdiq_create1_sel <= is_dis_sdiq_create1_sel;

    is_dis_mult_create0_en  <= is_dis_mult_create0_en;
    is_dis_mult_create0_sel <= is_dis_mult_create0_sel;
    is_dis_mult_create1_en  <= is_dis_mult_create1_en;
    is_dis_mult_create1_sel <= is_dis_mult_create1_sel;

    is_dis_div_create0_en   <= is_dis_div_create0_en;
    is_dis_div_create0_sel  <= is_dis_div_create0_sel;
    is_dis_div_create1_en   <= is_dis_div_create1_en;
    is_dis_div_create1_sel  <= is_dis_div_create1_sel;
  end
end

//==========================================================
//        Control signal for IS data path update
//==========================================================
assign ctrl_xx_is_inst0_sel[0] = is_dis_pipedown2;
assign ctrl_xx_is_inst0_sel[1] = !is_dis_pipedown2;

//==========================================================
//                Control signal for PST
//==========================================================
assign ctrl_dp_dis_inst0_preg_vld = is_dis_inst0_vld
                                  && !ctrl_is_dis_stall
                                  && dp_ctrl_is_inst0_dst_vld;

assign ctrl_dp_dis_inst1_preg_vld = is_dis_inst1_vld
                                  && !ctrl_is_dis_stall
                                  && dp_ctrl_is_inst1_dst_vld;

assign ctrl_dp_dis_inst2_preg_vld = is_dis_inst2_vld
                                  && !ctrl_is_dis_stall
                                  && dp_ctrl_is_inst2_dst_vld;

// ---- 派遣记录用: 裸的车道有效 (不串 dst_vld), 见端口表的说明 ----
assign ctrl_dp_dis_inst0_vld = is_dis_inst0_vld && !ctrl_is_dis_stall;
assign ctrl_dp_dis_inst1_vld = is_dis_inst1_vld && !ctrl_is_dis_stall;
assign ctrl_dp_dis_inst2_vld = is_dis_inst2_vld && !ctrl_is_dis_stall;


//==========================================================
//              Issue Queue Dispatch Control
//==========================================================
//------------------------- AIQ ----------------------------
assign ctrl_aiq_create0_en = is_dis_aiq_create0_en && !ctrl_is_dis_stall;
assign ctrl_aiq_create1_en = is_dis_aiq_create1_en && !ctrl_is_dis_stall;

assign ctrl_dp_is_dis_aiq_create0_sel = is_dis_aiq_create0_sel;
assign ctrl_dp_is_dis_aiq_create1_sel = is_dis_aiq_create1_sel;

//------------------------- BIQ ----------------------------
assign ctrl_biq_create0_en = is_dis_biq_create0_en && !ctrl_is_dis_stall;
assign ctrl_biq_create1_en = is_dis_biq_create1_en && !ctrl_is_dis_stall;

assign ctrl_dp_is_dis_biq_create0_sel = is_dis_biq_create0_sel;
assign ctrl_dp_is_dis_biq_create1_sel = is_dis_biq_create1_sel;

//------------------------ LSIQ ----------------------------
assign ctrl_lsiq_create0_en = is_dis_lsiq_create0_en && !ctrl_is_dis_stall;
assign ctrl_lsiq_create1_en = is_dis_lsiq_create1_en && !ctrl_is_dis_stall;

assign ctrl_dp_is_dis_lsiq_create0_sel = is_dis_lsiq_create0_sel;
assign ctrl_dp_is_dis_lsiq_create1_sel = is_dis_lsiq_create1_sel;

//------------------------ SDIQ ----------------------------
assign ctrl_sdiq_create0_en = is_dis_sdiq_create0_en && !ctrl_is_dis_stall;
assign ctrl_sdiq_create1_en = is_dis_sdiq_create1_en && !ctrl_is_dis_stall;

assign ctrl_dp_is_dis_sdiq_create0_sel = is_dis_sdiq_create0_sel;
assign ctrl_dp_is_dis_sdiq_create1_sel = is_dis_sdiq_create1_sel;

//------------------------ MULT ----------------------------
assign ctrl_mult_create0_en = is_dis_mult_create0_en && !ctrl_is_dis_stall;
assign ctrl_mult_create1_en = is_dis_mult_create1_en && !ctrl_is_dis_stall;

assign ctrl_dp_is_dis_mult_create0_sel = is_dis_mult_create0_sel;
assign ctrl_dp_is_dis_mult_create1_sel = is_dis_mult_create1_sel;

//------------------------- DIV ----------------------------
assign ctrl_div_create0_en = is_dis_div_create0_en && !ctrl_is_dis_stall;
assign ctrl_div_create1_en = is_dis_div_create1_en && !ctrl_is_dis_stall;

assign ctrl_dp_is_dis_div_create0_sel = is_dis_div_create0_sel;
assign ctrl_dp_is_dis_div_create1_sel = is_dis_div_create1_sel;

//==========================================================
//                Issue Queue Full Prepare
//==========================================================
always_comb
begin
  if(!ctrl_is_dis_stall) begin
    is_dis_aiq_create0_en_updt  = ctrl_ir_pre_dis_aiq_create0_en;
    is_dis_aiq_create1_en_updt  = ctrl_ir_pre_dis_aiq_create1_en;

    is_dis_biq_create0_en_updt  = ctrl_ir_pre_dis_biq_create0_en;
    is_dis_biq_create1_en_updt  = ctrl_ir_pre_dis_biq_create1_en;

    is_dis_lsiq_create0_en_updt = ctrl_ir_pre_dis_lsiq_create0_en;
    is_dis_lsiq_create1_en_updt = ctrl_ir_pre_dis_lsiq_create1_en;

    is_dis_sdiq_create0_en_updt = ctrl_ir_pre_dis_sdiq_create0_en;
    is_dis_sdiq_create1_en_updt = ctrl_ir_pre_dis_sdiq_create1_en;

    is_dis_mult_create0_en_updt = ctrl_ir_pre_dis_mult_create0_en;
    is_dis_mult_create1_en_updt = ctrl_ir_pre_dis_mult_create1_en;

    is_dis_div_create0_en_updt  = ctrl_ir_pre_dis_div_create0_en;
    is_dis_div_create1_en_updt  = ctrl_ir_pre_dis_div_create1_en;
  end
  else begin
    is_dis_aiq_create0_en_updt  = is_dis_aiq_create0_en;
    is_dis_aiq_create1_en_updt  = is_dis_aiq_create1_en;

    is_dis_biq_create0_en_updt  = is_dis_biq_create0_en;
    is_dis_biq_create1_en_updt  = is_dis_biq_create1_en;

    is_dis_lsiq_create0_en_updt = is_dis_lsiq_create0_en;
    is_dis_lsiq_create1_en_updt = is_dis_lsiq_create1_en;

    is_dis_sdiq_create0_en_updt = is_dis_sdiq_create0_en;
    is_dis_sdiq_create1_en_updt = is_dis_sdiq_create1_en;

    is_dis_mult_create0_en_updt = is_dis_mult_create0_en;
    is_dis_mult_create1_en_updt = is_dis_mult_create1_en;

    is_dis_div_create0_en_updt  = is_dis_div_create0_en;
    is_dis_div_create1_en_updt  = is_dis_div_create1_en;
  end
end

//==========================================================
//                Issue Queue Full Update
//==========================================================
assign ctrl_is_aiq_full_updt =
          (is_dis_aiq_create0_en_updt && aiq_ctrl_full_updt)
       || (is_dis_aiq_create1_en_updt && aiq_ctrl_1_left_updt);

assign ctrl_is_biq_full_updt =
          (is_dis_biq_create0_en_updt && biq_ctrl_full_updt)
       || (is_dis_biq_create1_en_updt && biq_ctrl_1_left_updt);

assign ctrl_is_lsiq_full_updt =
          (is_dis_lsiq_create0_en_updt && lsiq_ctrl_full_updt)
       || (is_dis_lsiq_create1_en_updt && lsiq_ctrl_1_left_updt);

assign ctrl_is_sdiq_full_updt =
          (is_dis_sdiq_create0_en_updt && sdiq_ctrl_full_updt)
       || (is_dis_sdiq_create1_en_updt && sdiq_ctrl_1_left_updt);

assign ctrl_is_mult_full_updt =
          (is_dis_mult_create0_en_updt && mult_ctrl_full_updt)
       || (is_dis_mult_create1_en_updt && mult_ctrl_1_left_updt);

assign ctrl_is_div_full_updt =
          (is_dis_div_create0_en_updt && div_ctrl_full_updt)
       || (is_dis_div_create1_en_updt && div_ctrl_1_left_updt);

assign ctrl_is_iq_full_updt = ctrl_is_aiq_full_updt
                            || ctrl_is_biq_full_updt
                            || ctrl_is_lsiq_full_updt
                            || ctrl_is_sdiq_full_updt
                            || ctrl_is_mult_full_updt
                            || ctrl_is_div_full_updt;

//==========================================================
//                      Queue Full
//==========================================================
always_ff @(posedge forever_clk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    ctrl_is_iq_full <= 1'b0;
  end
  else if(rtu_yy_xx_flush) begin
    ctrl_is_iq_full <= 1'b0;
  end
  else begin
    ctrl_is_iq_full <= ctrl_is_iq_full_updt;
  end
end

//==========================================================
//                  Dispatch Stall signal
//==========================================================
assign ctrl_is_rob_full = is_dis_inst0_vld && rtu_idu_rob_full;

assign ctrl_is_dis_stall = ctrl_is_rob_full || ctrl_is_iq_full;

assign ctrl_dp_is_dis_stall = ctrl_is_dis_stall;

assign ctrl_is_stall = ctrl_is_dis_stall;

endmodule