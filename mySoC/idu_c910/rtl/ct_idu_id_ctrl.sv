module ct_idu_id_ctrl (
  input  logic        forever_cpuclk,
  input  logic        cpurst_b,
  input  logic        ifu_idu_ib_inst0_vld,
  input  logic        ifu_idu_ib_inst1_vld,
  input  logic        ifu_idu_ib_inst2_vld,
  input  logic [1:0]  ctrl_xx_is_inst0_sel,
  input  logic        ctrl_ir_stall,
  input  logic        ctrl_ir_inst2_vld,
  input  logic        rtu_yy_xx_flush,
  output logic        id_inst0_vld,
  output logic        id_inst1_vld, 
  output logic        id_inst2_vld,
  output logic        idu_ifu_inst0_ready,
  output logic        idu_ifu_inst1_ready,
  output logic        idu_ifu_inst2_ready,
  output logic        ctrl_dp_id_stall
);



//==========================================================
//                 ID pipeline registers
//==========================================================
assign ctrl_ib_pipedown_inst0_vld =
            ctrl_xx_is_inst0_sel[0] && ctrl_ir_inst2_vld
         || ctrl_xx_is_inst0_sel[1] && ifu_idu_ib_inst0_vld;

assign ctrl_ib_pipedown_inst1_vld =
            ctrl_xx_is_inst0_sel[0] && ifu_idu_ib_inst0_vld
         || ctrl_xx_is_inst0_sel[1] && ifu_idu_ib_inst1_vld;
assign ctrl_ib_pipedown_inst2_vld =
            ctrl_xx_is_inst0_sel[0] && ifu_idu_ib_inst1_vld
         || ctrl_xx_is_inst0_sel[1] && ifu_idu_ib_inst2_vld;
logic ctrl_id_pipedown_stall;
assign idu_ifu_inst0_ready = !ctrl_id_pipedown_stall;
assign idu_ifu_inst1_ready = !ctrl_id_pipedown_stall;
assign idu_ifu_inst2_ready = !ctrl_id_pipedown_stall | !ctrl_xx_is_inst0_sel[0];

//----------------------------------------------------------
//               Pipeline register implement
//----------------------------------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    id_inst0_vld <= 1'b0;
    id_inst1_vld <= 1'b0;
    id_inst2_vld <= 1'b0;
  end
  else if(rtu_yy_xx_flush) begin
    id_inst0_vld <= 1'b0;
    id_inst1_vld <= 1'b0;
    id_inst2_vld <= 1'b0;
  end
  else if(!ctrl_id_pipedown_stall) begin
    id_inst0_vld <= ctrl_ib_pipedown_inst0_vld;
    id_inst1_vld <= ctrl_ib_pipedown_inst1_vld;
    id_inst2_vld <= ctrl_ib_pipedown_inst2_vld;
  end
  else begin
    id_inst0_vld <= id_inst0_vld;
    id_inst1_vld <= id_inst1_vld;
    id_inst2_vld <= id_inst2_vld;
  end
end

assign ctrl_id_pipedown_stall = ctrl_ir_stall;
assign ctrl_dp_id_stall = ctrl_ir_stall;
endmodule


