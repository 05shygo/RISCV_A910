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
  input  logic        aiq1_xx_issue_en,
  input  logic        aiq1_issue_stall,   // EX2 占着且没拿到写回授权 ⇒ 保持 valid
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
  output logic        idu_aiq1_sel,
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
logic rf_aiq1_inst_vld;        // AIQ1 的独立流水 valid (不占用 pipe 编号)
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

logic ctrl_rf_aiq1_inst_vld;
logic ctrl_rf_aiq1_pipedown_vld;
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
//                AIQ1 Instruction Valid (2026-10-18 新增)
//----------------------------------------------------------
// ⚠️ `aiq1_issue_stall` (来自 IU_alu_pipe 的 issue_stall) 时必须**保持**,
//    不能像普通情况那样把 valid 清 0:
//      AIQ1 issue → rf_ctrl 打一拍 → ALU EX1 → EX2。
//    EX2 占着且没拿到写回授权时, AIQ 已经不再发新指令、rf_dp 的数据寄存器
//    也因 issue=0 而保持; 如果这里的 valid 被清掉, 已经进 RF 流水的那条
//    就丢了 valid ⇒ 指令凭空消失 (AIQ 里也已经 pop 了)。
//    下一拍授权后 EX2 捕获同一份数据、正常写回。
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_aiq1_inst_vld <= 1'b0;
  end
  else if(rtu_yy_xx_flush) begin
    rf_aiq1_inst_vld <= 1'b0;
  end
  else if(aiq1_issue_stall) begin
    rf_aiq1_inst_vld <= rf_aiq1_inst_vld;
  end
  else begin
    rf_aiq1_inst_vld <= aiq1_xx_issue_en;
  end
end

assign ctrl_rf_aiq1_inst_vld = rf_aiq1_inst_vld;

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
assign ctrl_rf_aiq1_pipedown_vld = ctrl_rf_aiq1_inst_vld;
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
assign idu_aiq1_sel     = ctrl_rf_aiq1_pipedown_vld;
assign idu_mult_sel     = ctrl_rf_pipe1_pipedown_vld;
assign idu_div_sel      = ctrl_rf_pipe2_pipedown_vld;
assign idu_lsu_ld_sel   = ctrl_rf_pipe3_pipedown_vld;
assign idu_lsu_st_sel   = ctrl_rf_pipe4_pipedown_vld;
assign idu_lsu_sdiq_sel = ctrl_rf_pipe5_pipedown_vld;
assign idu_biq_sel      = ctrl_rf_pipe6_pipedown_vld;

endmodule