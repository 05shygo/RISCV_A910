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
  output logic        id_ir_inst0_vld,
  output logic        id_ir_inst1_vld, 
  output logic        id_ir_inst2_vld,
  output logic        idu_ifu_inst0_ready,
  output logic        idu_ifu_inst1_ready,
  output logic        idu_ifu_inst2_ready,
  output logic        ctrl_dp_id_stall
);



//==========================================================
//                 ID pipeline registers
//==========================================================
assign ctrl_ib_pipedown_inst0_vld =
            ctrl_xx_is_inst0_sel[0] && id_inst2_vld
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
// ⚠️ 2026-10-11 修: 原来是 `!stall | !pipedown2`, 那个 `|` 让 inst2_ready 恒为 1
//    (只要不停顿), 而 `ct_idu_top.sv:332` 的编码是
//        accept_num = {inst2_ready | inst0_ready, inst2_ready}
//    它要给出 {0,2,3} 需要一条不变量: **inst2_ready ⇒ inst0_ready** (b 只有 a 为 1
//    时才许为 1)。`!stall | !pd2` **不小于** `!stall`, 正好把不变量顶穿:
//        stall=0 & pd2=1 : inst2_ready=1 ⇒ 报 3, 应为 2  ⇒ **IFU 多弹一条, 丢指令**
//        stall=1 & pd2=0 : inst2_ready=1 ⇒ 报 3, 应为 0
//    改成 `&` 后 inst2_ready = !stall & !pd2 ≤ !stall = inst0_ready, 不变量成立,
//    四象限恰好是 3 / 2 / 0 / 0。
//    这三根 ready 全设计**只被 `idu_accept_num` 一处消费**, 无其它影响面。
assign idu_ifu_inst2_ready = !ctrl_id_pipedown_stall & !ctrl_xx_is_inst0_sel[0];

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

assign id_ir_inst0_vld =   
          ctrl_xx_is_inst0_sel[0] && ctrl_ir_inst2_vld
         || ctrl_xx_is_inst0_sel[1] && id_inst0_vld;

assign id_ir_inst1_vld =   
          ctrl_xx_is_inst0_sel[0] && id_inst0_vld
         || ctrl_xx_is_inst0_sel[1] && id_inst1_vld;

assign id_ir_inst2_vld =   
          ctrl_xx_is_inst0_sel[0] && id_inst1_vld
         || ctrl_xx_is_inst0_sel[1] && id_inst2_vld;

assign ctrl_id_pipedown_stall = ctrl_ir_stall;
assign ctrl_dp_id_stall = ctrl_ir_stall;
endmodule


