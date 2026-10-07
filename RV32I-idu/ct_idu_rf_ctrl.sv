module ct_idu_rf_ctrl (
  //==========================================================
  // 全局信号
  //==========================================================
  input  logic        cpurst_b,
  input  logic        forever_cpuclk,

  //==========================================================
  // Issue Enable（来自各 IQ）
  //==========================================================
  input  logic        aiq_xx_issue_en,
  input  logic        mult_xx_issue_en,
  input  logic        div_xx_issue_en,
  input  logic        lsiq_xx_pipe3_issue_en,
  input  logic        lsiq_xx_pipe4_issue_en,
  input  logic        sdiq_xx_issue_en,
  input  logic        biq_xx_issue_en,

  //==========================================================
  // Flush
  //==========================================================
  input  logic        rtu_yy_xx_flush,


  //==========================================================
  // RF Execution Unit Selection
  //==========================================================
  output logic        idu_aiq_sel,
  output logic        idu_mult_sel,
  output logic        idu_div_sel,
  output logic        idu_lsu_ld_sel,
  output logic        idu_lsu_st_sel,
  output logic        idu_lsu_sdiq_sel,
  output logic        idu_biq_sel
);

//==========================================================
//                 内部信号声明
//==========================================================
// Issue enable（原始 RTL 使用但未声明，保留以免未定义）

// RF inst valid 寄存器
logic rf_pipe0_inst_vld;
logic rf_pipe1_inst_vld;
logic rf_pipe2_inst_vld;
logic rf_pipe3_inst_vld;
logic rf_pipe4_inst_vld;
logic rf_pipe5_inst_vld;
logic rf_pipe6_inst_vld;

// ctrl 内部中间信号
logic ctrl_rf_pipe0_inst_vld;
logic ctrl_rf_pipe1_inst_vld;
logic ctrl_rf_pipe2_inst_vld;
logic ctrl_rf_pipe3_inst_vld;
logic ctrl_rf_pipe4_inst_vld;
logic ctrl_rf_pipe5_inst_vld;
logic ctrl_rf_pipe6_inst_vld;

logic ctrl_rf_pipe0_pipedown_vld;
logic ctrl_rf_pipe1_pipedown_vld;
logic ctrl_rf_pipe2_pipedown_vld;
logic ctrl_rf_pipe3_pipedown_vld;
logic ctrl_rf_pipe4_pipedown_vld;
logic ctrl_rf_pipe5_pipedown_vld;
logic ctrl_rf_pipe6_pipedown_vld;

//==========================================================
//                 RF Inst Valid registers
//==========================================================
//----------------------------------------------------------
//                Pipe0 Instruction Valid
//----------------------------------------------------------
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe0_inst_vld <= 1'b0;
  end
  else if(rtu_yy_xx_flush) begin
    rf_pipe0_inst_vld <= 1'b0;
  end
  else begin
    rf_pipe0_inst_vld <= aiq_xx_issue_en;
  end
end

assign ctrl_rf_pipe0_inst_vld = rf_pipe0_inst_vld;

//----------------------------------------------------------
//                Pipe1 Instruction Valid
//----------------------------------------------------------
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe1_inst_vld <= 1'b0;
  end
  else if(rtu_yy_xx_flush) begin
    rf_pipe1_inst_vld <= 1'b0;
  end
  else begin
    rf_pipe1_inst_vld <= mult_xx_issue_en;
  end
end

assign ctrl_rf_pipe1_inst_vld = rf_pipe1_inst_vld;

//----------------------------------------------------------
//                Pipe2 Instruction Valid
//----------------------------------------------------------
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe2_inst_vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    rf_pipe2_inst_vld <= 1'b0;
  else
    rf_pipe2_inst_vld <= div_xx_issue_en;
end

assign ctrl_rf_pipe2_inst_vld = rf_pipe2_inst_vld;

//----------------------------------------------------------
//                Pipe3 Instruction Valid
//----------------------------------------------------------
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe3_inst_vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    rf_pipe3_inst_vld <= 1'b0;
  else
    rf_pipe3_inst_vld <= lsiq_xx_pipe3_issue_en;
end

assign ctrl_rf_pipe3_inst_vld = rf_pipe3_inst_vld;

//----------------------------------------------------------
//                Pipe4 Instruction Valid
//----------------------------------------------------------
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe4_inst_vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    rf_pipe4_inst_vld <= 1'b0;
  else
    rf_pipe4_inst_vld <= lsiq_xx_pipe4_issue_en;
end

assign ctrl_rf_pipe4_inst_vld = rf_pipe4_inst_vld;

//----------------------------------------------------------
//                Pipe5 Instruction Valid
//----------------------------------------------------------
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe5_inst_vld <= 1'b0;
  // pipe5 rf stage is flush by flush_be
  else if(rtu_yy_xx_flush)
    rf_pipe5_inst_vld <= 1'b0;
  else
    rf_pipe5_inst_vld <= sdiq_xx_issue_en;
end

assign ctrl_rf_pipe5_inst_vld = rf_pipe5_inst_vld;

//----------------------------------------------------------
//                Pipe6 Instruction Valid
//----------------------------------------------------------
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe6_inst_vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    rf_pipe6_inst_vld <= 1'b0;
  else
    rf_pipe6_inst_vld <= biq_xx_issue_en;
end

assign ctrl_rf_pipe6_inst_vld = rf_pipe6_inst_vld;

//----------------------------------------------------------
//                    RF pipedown valid
//----------------------------------------------------------
assign ctrl_rf_pipe0_pipedown_vld = ctrl_rf_pipe0_inst_vld;
assign ctrl_rf_pipe1_pipedown_vld = ctrl_rf_pipe1_inst_vld;
assign ctrl_rf_pipe2_pipedown_vld = ctrl_rf_pipe2_inst_vld;
assign ctrl_rf_pipe3_pipedown_vld = ctrl_rf_pipe3_inst_vld;
assign ctrl_rf_pipe4_pipedown_vld = ctrl_rf_pipe4_inst_vld;
assign ctrl_rf_pipe5_pipedown_vld = ctrl_rf_pipe5_inst_vld;
assign ctrl_rf_pipe6_pipedown_vld = ctrl_rf_pipe6_inst_vld;


//==========================================================
//                RF Execution Unit Selection
//==========================================================
assign idu_aiq_sel      = ctrl_rf_pipe0_pipedown_vld;
assign idu_mult_sel     = ctrl_rf_pipe1_pipedown_vld;
assign idu_div_sel      = ctrl_rf_pipe2_pipedown_vld;
assign idu_lsu_ld_sel   = ctrl_rf_pipe3_pipedown_vld;
assign idu_lsu_st_sel   = ctrl_rf_pipe4_pipedown_vld;
assign idu_lsu_sdiq_sel = ctrl_rf_pipe5_pipedown_vld;
assign idu_biq_sel      = ctrl_rf_pipe6_pipedown_vld;

endmodule