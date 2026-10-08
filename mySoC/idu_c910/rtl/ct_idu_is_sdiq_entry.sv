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

module ct_idu_is_sdiq_entry (
  //==========================================================
  // 全局信号
  //==========================================================
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic         rtu_yy_xx_flush,

  //==========================================================
  // Flush（ct_idu_dep_reg_entry 需要）
  //==========================================================
  // ⚠️ 这里原来还有 rtu_idu_flush_fe / rtu_idu_flush_is 两个口, 已改成用上面
  //    "全局信号" 区那根 rtu_yy_xx_flush。理由: 本设计只有一个冲刷信号 (顶层
  //    端口表里没有 fe/is), 而两处例化点传的本来就是 rtu_yy_xx_flush ——
  //    名字对不上, 整个 IDU elaborate 不过。子模块 ct_idu_dep_reg_entry 也
  //    只有 rtu_yy_xx_flush 一个口。
  //    前端/发射级分开冲刷 (C910 有) 是 Phase 3/4 的事, 届时要连同顶层端口一起加。

  //==========================================================
  // Store Queue 状态
  //==========================================================
  input  logic         lsu_sdiq_has_in_sq,
 // input  logic         lsu_sq_sdiq_unalign,

  //==========================================================
  // 写端口（来自 IU/LSU 的物理寄存器回写）
  //==========================================================
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,

  //==========================================================
  // SDIQ 控制
  //==========================================================
  input  logic         lsu_idu_ex1_sdiq_pop_vld,
  input  logic [2:0]   x_create_agevec,
  input  logic [7:0]   x_create_data,
  input  logic         x_create_en,
  input  logic         x_issue_en,
  input  logic         x_pop_cur_entry,
  input  logic [2:0]   x_pop_other_entry,

  //==========================================================
  // 输出
  //==========================================================
  output logic [2:0]   x_agevec,
  output logic         x_rdy,
  output logic [7:0]   x_read_data,
  output logic [63:0]  x_src0_preg_expand,
  output logic         x_vld
);

//==========================================================
//                       Parameters
//==========================================================
//----------------------------------------------------------
//                    SDIQ Parameters
//----------------------------------------------------------
parameter int SDIQ_WIDTH     = 8;
parameter int SDIQ_SRC1_DATA = 7;
parameter int SDIQ_SRC1_VLD  = 0;

// 以下三个参数原代码使用但未定义，此处补充（具体值需与实现对齐）
parameter int SDIQ_SRC0_PREG = 5;
parameter int SDIQ_SRC0_VLD  = 6;
parameter int AIQ_SRC1_DATA  = 7;

//==========================================================
//                      内部信号声明
//==========================================================
// Entry 状态寄存器
logic         vld;
logic         has_in_sq;
logic [2:0]   agevec;
logic         src0_vld;

// 读写端口数据
logic [6:0]   create_src1_data;
logic [6:0]   read_src1_data;

// src0_preg 展开
logic [5:0]   read_data_src0_preg;
logic [63:0]  read_data_src0_preg_expand;

// 就绪
logic         src0_rdy_for_issue;

//==========================================================
//                      Entry Valid
//==========================================================
assign x_vld = vld;

always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    vld <= 1'b0;
  else if(x_create_en)
    vld <= 1'b1;
  else if(lsu_idu_ex1_sdiq_pop_vld && x_pop_cur_entry)
    vld <= 1'b0;
  else
    vld <= vld;
end

//==========================================================
//                        Freeze
//==========================================================
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    has_in_sq <= 1'b0;
  else if(x_create_en)
    has_in_sq <= 1'b0;
  else if(x_issue_en)
    has_in_sq <= 1'b0;
  else if(lsu_sdiq_has_in_sq)
    has_in_sq <= 1'b1;
//  else if(lsu_sq_sdiq_unalign)
//    has_in_sq <= 1'b0;
  else
    has_in_sq <= has_in_sq;
end

//==========================================================
//                       Age Vector
//==========================================================
assign x_agevec[2:0] = agevec[2:0];

always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    agevec[2:0] <= 3'b0;
  else if(x_create_en)
    agevec[2:0] <= x_create_agevec[2:0];
  else if(lsu_idu_ex1_sdiq_pop_vld)
    agevec[2:0] <= agevec[2:0] & ~x_pop_other_entry[2:0];
  else
    agevec[2:0] <= agevec[2:0];
end

//==========================================================
//                 Instruction Information
//==========================================================
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    src0_vld <= 1'b0;
  else if(x_create_en)
    src0_vld <= x_create_data[SDIQ_SRC0_VLD];
  else
    src0_vld <= src0_vld;
end

// rename for read output
assign x_read_data[SDIQ_SRC0_VLD] = src0_vld;

//==========================================================
//             Store Address Instruction Ready
//==========================================================
//----------------------------------------------------------
//                 Staddr 0 in Store Queue
//----------------------------------------------------------

//==========================================================
//              Source Dependency Information
//==========================================================
//------------------------ source 1 -------------------------
assign create_src1_data[6:0] = x_create_data[AIQ_SRC1_DATA:AIQ_SRC1_DATA-6];

//----------------------------------------------------------------------
// Instance : ct_idu_dep_reg_entry
// Desc     : 依赖寄存器 entry（写端口来自 ex2/wb pipe0/1/pipe3，读端口给 x）
//----------------------------------------------------------------------
ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src1 (
  .cpurst_b                          (cpurst_b                          ),
  .forever_cpuclk                    (forever_cpuclk                    ),

  // 写端口：IU pipe0 ex2 wb
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx     ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx ),

  // 写端口：IU pipe1 ex2 wb
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx     ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx ),

  // 写端口：LSU pipe3 wb
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx     ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx ),

  // flush
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush                   ),

  // 写数据 / 写使能
  .x_create_data                     (create_src1_data[6:0]             ),
  .x_write_en                        (x_create_en                       ),

  // 读数据
  .x_read_data                       (read_src1_data[6:0]               )
);

// ⚠️ 原为 x_read_data[AIQ_SRC1_DATA:AIQ_SRC1_DATA-6] (= 位 [7:1]), 与上面
//    x_read_data[SDIQ_SRC0_VLD](位 6) 重叠 —— elaborate 报 ICSD (多驱动器)。
//    偏移是从 AIQ entry 抄过来的: AIQ 的 read_data 有 64 位, 同样的写成对;
//    SDIQ 只有 8 位, 按本文件自己的参数 (SDIQ_SRC0_PREG=5) 应该是位 [5:0],
//    这也与下面读 read_data_src0_preg 的写法一致。
assign x_read_data[SDIQ_SRC0_PREG:SDIQ_SRC0_PREG-5] = read_src1_data[5:0];

//==========================================================
//             Dealloc mask signal for src0/srcv0
//==========================================================
assign read_data_src0_preg[5:0] = x_read_data[SDIQ_SRC0_PREG:SDIQ_SRC0_PREG-5];

// &ConnRule(s/^x_num/read_data_src0_preg/); @335
// &Instance("ct_rtu_expand_96","x_ct_rtu_expand_96_read_data_src0_preg"); @336
ct_idu_expand_64 x_ct_ct_idu_expand_64 (
  .x_num        (read_data_src0_preg       ),
  .x_num_expand (read_data_src0_preg_expand)
);

assign x_src0_preg_expand[63:0] = {64{vld && src0_vld}}
                                  & read_data_src0_preg_expand[63:0];

//==========================================================
//                  Entry Ready Signal
//==========================================================
assign src0_rdy_for_issue = read_src1_data[0];

assign x_rdy = vld
            && has_in_sq
            && src0_rdy_for_issue;

// &ModuleEnd; @358
endmodule