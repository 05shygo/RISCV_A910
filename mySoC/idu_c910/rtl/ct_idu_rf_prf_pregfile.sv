module ct_idu_rf_prf_pregfile (
  //==========================================================
  // 全局信号
  //==========================================================
  input  logic         forever_cpuclk,

  //==========================================================
  // 来自 DP 的源寄存器索引（第一个模块的 output）
  //==========================================================
  input  logic [5:0]   dp_prf_rf_pipe0_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe0_src1_preg,
  input  logic [5:0]   dp_prf_rf_pipe1_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe1_src1_preg,
  input  logic [5:0]   dp_prf_rf_pipe2_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe2_src1_preg,
  input  logic [5:0]   dp_prf_rf_pipe3_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe4_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe5_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe6_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe6_src1_preg,

  //==========================================================
  // 写端口（来自 IU/LSU，位宽适配 32bit 寄存器）
  //==========================================================
  input  logic [31:0]  iu_idu_ex2_pipe0_wb_preg_data,
  input  logic [63:0]  iu_idu_ex2_pipe0_wb_preg_expand,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld,
  input  logic [31:0]  iu_idu_ex2_pipe1_wb_preg_data,
  input  logic [63:0]  iu_idu_ex2_pipe1_wb_preg_expand,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld,
  input  logic [31:0]  lsu_idu_wb_pipe3_wb_preg_data,
  input  logic [63:0]  lsu_idu_wb_pipe3_wb_preg_expand,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld,

  //==========================================================
  // 输出到 DP 的源数据（第一个模块的 input）
  //==========================================================
  output logic [31:0]  prf_dp_rf_pipe0_src0_data,
  output logic [31:0]  prf_dp_rf_pipe0_src1_data,
  output logic [31:0]  prf_dp_rf_pipe1_src0_data,
  output logic [31:0]  prf_dp_rf_pipe1_src1_data,
  output logic [31:0]  prf_dp_rf_pipe2_src0_data,
  output logic [31:0]  prf_dp_rf_pipe2_src1_data,
  output logic [31:0]  prf_dp_rf_pipe3_src0_data,
  output logic [31:0]  prf_dp_rf_pipe4_src0_data,
  output logic [31:0]  prf_dp_rf_pipe5_src0_data,
  output logic [31:0]  prf_dp_rf_pipe6_src0_data,
  output logic [31:0]  prf_dp_rf_pipe6_src1_data
);

//==========================================================
//              Instance GPR Physical Registers
//==========================================================
//----------------------------------------------------------
//                       Preg data / vld 数组
//----------------------------------------------------------
logic [31:0] preg_reg_dout [0:63];
logic [2:0]  preg_wb_vld   [0:63];

//----------------------------------------------------------
//                         Preg 0
//----------------------------------------------------------
// treat preg0 as constant 0
assign preg_reg_dout[0] = 32'b0;

//----------------------------------------------------------
//                       实例化 preg1 ~ preg63
//----------------------------------------------------------
genvar i;
generate
  for (i = 1; i < 64; i = i + 1) begin : gen_preg
    ct_idu_rf_prf_gated_preg u_ct_idu_rf_prf_preg (
      .forever_cpuclk                (forever_cpuclk               ),
      .iu_idu_ex2_pipe0_wb_preg_data (iu_idu_ex2_pipe0_wb_preg_data),
      .iu_idu_ex2_pipe1_wb_preg_data (iu_idu_ex2_pipe1_wb_preg_data),
      .lsu_idu_wb_pipe3_wb_preg_data (lsu_idu_wb_pipe3_wb_preg_data),
      .x_reg_dout                    (preg_reg_dout[i]             ),
      .x_wb_vld                      (preg_wb_vld[i]               )
    );
  end
endgenerate

//==========================================================
//                       Write Port 
//==========================================================
// 3 write ports
logic [63:0] pipe0_wb_vld;
logic [63:0] pipe1_wb_vld;
logic [63:0] pipe3_wb_vld;

assign pipe0_wb_vld = {64{iu_idu_ex2_pipe0_wb_preg_vld}}
                      & iu_idu_ex2_pipe0_wb_preg_expand;
assign pipe1_wb_vld = {64{iu_idu_ex2_pipe1_wb_preg_vld}}
                      & iu_idu_ex2_pipe1_wb_preg_expand;
assign pipe3_wb_vld = {64{lsu_idu_wb_pipe3_wb_preg_vld}}
                      & lsu_idu_wb_pipe3_wb_preg_expand;

// preg0 恒为常量 0，不写入
assign preg_wb_vld[0] = 3'b000;

genvar j;
generate
  for (j = 1; j < 64; j = j + 1) begin : gen_wb_vld
    assign preg_wb_vld[j] = {pipe3_wb_vld[j], pipe1_wb_vld[j], pipe0_wb_vld[j]};
  end
endgenerate

//==========================================================
//                       Read Port 
//==========================================================
// 说明：
//   - 物理寄存器共有 64 个（preg0 ~ preg63），索引 [5:0]
//   - preg_reg_dout[0] 恒为 32'b0（preg0 作为常量 0）
//   - 数据位宽统一为 32bit
//   - 用数组索引替代 case，等价于 64 选 1 mux
//   - 仅保留 DP 实际用到的端口：pipe0/1/2/6 双 src，pipe3/4/5 单 src
//==========================================================

//----------------------------------------------------------
//                 Read Port 1: pipe0 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe0_src0_data = preg_reg_dout[dp_prf_rf_pipe0_src0_preg];

//----------------------------------------------------------
//                 Read Port 2: pipe0 src1
//----------------------------------------------------------
assign prf_dp_rf_pipe0_src1_data = preg_reg_dout[dp_prf_rf_pipe0_src1_preg];

//----------------------------------------------------------
//                 Read Port 3: pipe1 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe1_src0_data = preg_reg_dout[dp_prf_rf_pipe1_src0_preg];

//----------------------------------------------------------
//                 Read Port 4: pipe1 src1
//----------------------------------------------------------
assign prf_dp_rf_pipe1_src1_data = preg_reg_dout[dp_prf_rf_pipe1_src1_preg];

//----------------------------------------------------------
//                 Read Port 5: pipe2 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe2_src0_data = preg_reg_dout[dp_prf_rf_pipe2_src0_preg];

//----------------------------------------------------------
//                 Read Port 6: pipe2 src1
//----------------------------------------------------------
assign prf_dp_rf_pipe2_src1_data = preg_reg_dout[dp_prf_rf_pipe2_src1_preg];

//----------------------------------------------------------
//                 Read Port 7: pipe3 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe3_src0_data = preg_reg_dout[dp_prf_rf_pipe3_src0_preg];

//----------------------------------------------------------
//                 Read Port 8: pipe4 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe4_src0_data = preg_reg_dout[dp_prf_rf_pipe4_src0_preg];

//----------------------------------------------------------
//                 Read Port 9: pipe5 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe5_src0_data = preg_reg_dout[dp_prf_rf_pipe5_src0_preg];

//----------------------------------------------------------
//                 Read Port 10: pipe6 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe6_src0_data = preg_reg_dout[dp_prf_rf_pipe6_src0_preg];

//----------------------------------------------------------
//                 Read Port 11: pipe6 src1
//----------------------------------------------------------
assign prf_dp_rf_pipe6_src1_data = preg_reg_dout[dp_prf_rf_pipe6_src1_preg];

// &ModuleEnd; @1536
endmodule