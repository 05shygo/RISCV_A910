module ct_idu_ir_dp (
  input  logic            cpurst_b,
  input  logic            forever_clk,
  input  logic            ctrl_ir_stall,
  output logic [96:0]     crtl_ir_inst2_data,
  output logic [24:0]     crtl_ir_inst2_chk,

  input  logic [121:0]     dp_id_pipedown_inst0_data,
  input  logic [24:0]      dp_id_pipedown_inst0_chk,
  input  logic [121:0]     dp_id_pipedown_inst1_data,
  input  logic [24:0]      dp_id_pipedown_inst1_chk,
  input  logic [121:0]     dp_id_pipedown_inst2_data,
  input  logic [24:0]      dp_id_pipedown_inst2_chk,

  input  logic [5  :0]    rt_dp_inst0_rel_preg,
  input  logic [8  :0]    rt_dp_inst0_src0_data,
  input  logic [8  :0]    rt_dp_inst0_src1_data,
  input  logic [9  :0]    rt_dp_inst0_src2_data,

  input  logic [5  :0]    rt_dp_inst1_rel_preg,
  input  logic [8  :0]    rt_dp_inst1_src0_data,
  input  logic [8  :0]    rt_dp_inst1_src1_data,
  input  logic [9  :0]    rt_dp_inst1_src2_data,

  input  logic [5  :0]    rt_dp_inst2_rel_preg,
  input  logic [8  :0]    rt_dp_inst2_src0_data,
  input  logic [8  :0]    rt_dp_inst2_src1_data,
  input  logic [9  :0]    rt_dp_inst2_src2_data,

  input  logic [5  :0]    rtu_idu_alloc_preg0,
  input  logic [5  :0]    rtu_idu_alloc_preg1,
  input  logic [5  :0]    rtu_idu_alloc_preg2,

  output logic [6  :0]    dp_ctrl_ir_inst0_ctrl_info,
  output logic            dp_ctrl_ir_inst0_dst_vld,
  output logic            dp_ctrl_ir_inst0_dst_x0,
  output logic            dp_ctrl_ir_inst0_illegal,

  output logic [6  :0]    dp_ctrl_ir_inst1_ctrl_info,
  output logic            dp_ctrl_ir_inst1_dst_vld,
  output logic            dp_ctrl_ir_inst1_dst_x0,
  output logic            dp_ctrl_ir_inst1_illegal,

  output logic [6  :0]    dp_ctrl_ir_inst2_ctrl_info,
  output logic            dp_ctrl_ir_inst2_dst_vld,
  output logic            dp_ctrl_ir_inst2_dst_x0,
  output logic            dp_ctrl_ir_inst2_illegal,

  output logic [82 :0]    dp_ir_inst0_data,
  output logic [64:0]     dp_ir_inst0_pc,
  output logic [24:0]     dp_ir_inst0_chk,
  output logic [82 :0]    dp_ir_inst1_data,
  output logic [64:0]     dp_ir_inst1_pc,
  output logic [24:0]     dp_ir_inst1_chk,
  output logic [82 :0]    dp_ir_inst2_data,
  output logic [64:0]     dp_ir_inst2_pc,
  output logic [24:0]     dp_ir_inst2_chk,

  output logic [5  :0]    dp_rt_inst0_dst_preg,
  output logic [4  :0]    dp_rt_inst0_dst_reg,
  output logic            dp_rt_inst0_dst_vld,
  output logic [4  :0]    dp_rt_inst0_src0_reg,
  output logic            dp_rt_inst0_src0_vld,
  output logic [4  :0]    dp_rt_inst0_src1_reg,
  output logic            dp_rt_inst0_src1_vld,

  output logic [5  :0]    dp_rt_inst1_dst_preg,
  output logic [4  :0]    dp_rt_inst1_dst_reg,
  output logic            dp_rt_inst1_dst_vld,
  output logic [4  :0]    dp_rt_inst1_src0_reg,
  output logic            dp_rt_inst1_src0_vld,
  output logic [4  :0]    dp_rt_inst1_src1_reg,
  output logic            dp_rt_inst1_src1_vld,

  output logic [5  :0]    dp_rt_inst2_dst_preg,
  output logic [4  :0]    dp_rt_inst2_dst_reg,
  output logic            dp_rt_inst2_dst_vld,
  output logic [4  :0]    dp_rt_inst2_src0_reg,
  output logic            dp_rt_inst2_src0_vld,
  output logic [4  :0]    dp_rt_inst2_src1_reg,
  output logic            dp_rt_inst2_src1_vld
);

//==========================================================
//                       Parameters
//==========================================================
parameter IR_WIDTH            = 123;
parameter IR_TAKEN            = 122;
parameter IR_NPC              = 121;
parameter IR_PC               = 89;
parameter IR_ILLEGAL          = 57;
parameter IR_DST_X0           = 56;
parameter IR_INST_TYPE        = 55;
parameter IR_DST_REG          = 49;
parameter IR_DST_VLD          = 44;
parameter IR_SRC1_REG         = 43;
parameter IR_SRC1_VLD         = 38;
parameter IR_SRC0_REG         = 37;
parameter IR_SRC0_VLD         = 32;
parameter IR_OPCODE           = 31;

parameter IS_CTRL_WIDTH       = 7;
parameter IS_CTRL_ILLEGAL     = 6;
parameter IS_CTRL_ALU         = 5;
parameter IS_CTRL_STADDR      = 4;
parameter IS_CTRL_LSU         = 3;
parameter IS_CTRL_BJU         = 2;
parameter IS_CTRL_DIV         = 1;
parameter IS_CTRL_MULT        = 0;

parameter IS_ILLEGAL           = 82;
parameter IS_ALU_SHORT         = 81;
parameter IS_LSU               = 80;
parameter IS_DIV               = 79;
parameter IS_MULT              = 78;
parameter IS_BJU               = 77;
parameter IS_STADDR            = 76;
parameter IS_STORE             = 75;
parameter IS_LOAD              = 74;
parameter IS_ALU               = 73;
parameter IS_DST_REL_PREG      = 72;
parameter IS_DST_PREG          = 66;
parameter IS_DST_REG           = 60;
parameter IS_SRC2_DATA         = 55;
parameter IS_SRC1_DATA         = 48;
parameter IS_SRC0_DATA         = 41;
parameter IS_DST_VLD           = 34;
parameter IS_SRC1_VLD          = 33;
parameter IS_SRC0_VLD          = 32;
parameter IS_OPCODE            = 31;

//==========================================================
//                       Internal Signals
//==========================================================

// &Regs; @28
logic [IR_WIDTH-1:0]   ir_inst0_data;
logic [IR_WIDTH-1:0]   ir_inst1_data;
logic [IR_WIDTH-1:0]   ir_inst2_data;

// &Wires; @29
// 内部信号声明 - RV32I精简版

logic [5  :0]     ir_inst0_dst_preg;
logic             ir_inst0_load;
logic [31 :0]     ir_inst0_opcode;
logic             ir_inst0_store;
logic             ir_inst0_type_alu;
logic             ir_inst0_alu_short;

logic [5  :0]     ir_inst1_dst_preg;
logic             ir_inst1_load;
logic [31 :0]     ir_inst1_opcode;
logic             ir_inst1_store;
logic             ir_inst1_type_alu;
logic             ir_inst1_alu_short;

logic [5  :0]     ir_inst2_dst_preg;
logic             ir_inst2_load;
logic [31 :0]     ir_inst2_opcode;
logic             ir_inst2_store;
logic             ir_inst2_type_alu;
logic             ir_inst2_alu_short;

logic [5  :0]     ir_pipedown_inst0_dst_preg;
logic [5  :0]     ir_pipedown_inst1_dst_preg;
logic [5  :0]     ir_pipedown_inst2_dst_preg;

//==========================================================
//                IR/IS pipeline registers
//==========================================================
logic [24:0] ir_inst0_chk;
logic [24:0] ir_inst1_chk;
logic [24:0] ir_inst2_chk;

always @(posedge forever_clk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    ir_inst0_data[IR_WIDTH-1:0] <= {IR_WIDTH{1'b0}};
    ir_inst1_data[IR_WIDTH-1:0] <= {IR_WIDTH{1'b0}};
    ir_inst2_data[IR_WIDTH-1:0] <= {IR_WIDTH{1'b0}};
    ir_inst0_chk[24:0]          <= {25{1'b0}};
    ir_inst1_chk[24:0]          <= {25{1'b0}};
    ir_inst2_chk[24:0]          <= {25{1'b0}};
  end
  else if(!ctrl_ir_stall) begin
    ir_inst0_data[IR_WIDTH-1:0] <= dp_id_pipedown_inst0_data[IR_WIDTH-1:0];
    ir_inst1_data[IR_WIDTH-1:0] <= dp_id_pipedown_inst1_data[IR_WIDTH-1:0];
    ir_inst2_data[IR_WIDTH-1:0] <= dp_id_pipedown_inst2_data[IR_WIDTH-1:0];
    ir_inst0_chk[24:0]          <= dp_id_pipedown_inst0_chk[24:0];
    ir_inst1_chk[24:0]          <= dp_id_pipedown_inst1_chk[24:0];
    ir_inst2_chk[24:0]          <= dp_id_pipedown_inst2_chk[24:0];
  end
  else begin
    ir_inst0_data[IR_WIDTH-1:0] <= ir_inst0_data[IR_WIDTH-1:0];
    ir_inst1_data[IR_WIDTH-1:0] <= ir_inst1_data[IR_WIDTH-1:0];
    ir_inst2_data[IR_WIDTH-1:0] <= ir_inst2_data[IR_WIDTH-1:0];
    ir_inst0_chk[24:0]          <= ir_inst0_chk[24:0];
    ir_inst1_chk[24:0]          <= ir_inst1_chk[24:0];
    ir_inst2_chk[24:0]          <= ir_inst2_chk[24:0];
  end
end

assign dp_ir_inst0_chk[24:0] = ir_inst0_chk[24:0];
assign dp_ir_inst1_chk[24:0] = ir_inst1_chk[24:0];
assign dp_ir_inst2_chk[24:0] = ir_inst2_chk[24:0];
//==========================================================
//                Prepare IR control data
//==========================================================

assign dp_ctrl_ir_inst0_dst_x0 =
       ir_inst0_data[IR_DST_X0];

assign dp_ctrl_ir_inst1_dst_x0 =
       ir_inst1_data[IR_DST_X0];

assign dp_ctrl_ir_inst2_dst_x0 =
       ir_inst2_data[IR_DST_X0];

assign dp_ctrl_ir_inst0_dst_vld =
       ir_inst0_data[IR_DST_VLD];

assign dp_ctrl_ir_inst1_dst_vld =
       ir_inst1_data[IR_DST_VLD];

assign dp_ctrl_ir_inst2_dst_vld =
       ir_inst2_data[IR_DST_VLD];

assign dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_MULT] =
       ir_inst0_data[IR_INST_TYPE];

assign dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_MULT] =
       ir_inst1_data[IR_INST_TYPE];

assign dp_ctrl_ir_inst2_ctrl_info[IS_CTRL_MULT] =
       ir_inst2_data[IR_INST_TYPE];

assign dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_DIV] =
       ir_inst0_data[IR_INST_TYPE-1];

assign dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_DIV] =
       ir_inst1_data[IR_INST_TYPE-1];

assign dp_ctrl_ir_inst2_ctrl_info[IS_CTRL_DIV] =
       ir_inst2_data[IR_INST_TYPE-1];

assign dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_BJU] =
       ir_inst0_data[IR_INST_TYPE-2];

assign dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_BJU] =
       ir_inst1_data[IR_INST_TYPE-2];

assign dp_ctrl_ir_inst2_ctrl_info[IS_CTRL_BJU] =
       ir_inst2_data[IR_INST_TYPE-2];

assign dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_LSU] =
       ir_inst0_data[IR_INST_TYPE-3];

assign dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_LSU] =
       ir_inst1_data[IR_INST_TYPE-3];

assign dp_ctrl_ir_inst2_ctrl_info[IS_CTRL_LSU] =
       ir_inst2_data[IR_INST_TYPE-3];

assign dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_STADDR] =
       ir_inst0_data[IR_INST_TYPE-4];

assign dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_STADDR] =
       ir_inst1_data[IR_INST_TYPE-4];

assign dp_ctrl_ir_inst2_ctrl_info[IS_CTRL_STADDR] =
       ir_inst2_data[IR_INST_TYPE-4];

assign dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_ALU] =
       ir_inst0_data[IR_INST_TYPE-5];

assign dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_ALU] =
       ir_inst1_data[IR_INST_TYPE-5];

assign dp_ctrl_ir_inst2_ctrl_info[IS_CTRL_ALU] =
       ir_inst2_data[IR_INST_TYPE-5];

assign dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_ILLEGAL] = 
       dp_ctrl_ir_inst0_illegal;

assign dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_ILLEGAL] = 
       dp_ctrl_ir_inst1_illegal;

assign dp_ctrl_ir_inst2_ctrl_info[IS_CTRL_ILLEGAL] = 
       dp_ctrl_ir_inst2_illegal;       

assign ir_inst0_type_alu =
       ir_inst0_data[IR_INST_TYPE-5];

assign ir_inst1_type_alu =
       ir_inst1_data[IR_INST_TYPE-5];

assign ir_inst2_type_alu =
       ir_inst2_data[IR_INST_TYPE-5];

//==========================================================
//               Assign ptag, creg and lsu pc
//==========================================================

assign ir_inst0_dst_preg[5:0] =
       {6{!ir_inst0_data[IR_DST_X0]}} &
       rtu_idu_alloc_preg0[5:0];

assign ir_inst1_dst_preg[5:0] =
       {6{!ir_inst1_data[IR_DST_X0]}} &
       rtu_idu_alloc_preg1[5:0];

assign ir_inst2_dst_preg[5:0] =
       {6{!ir_inst2_data[IR_DST_X0]}} &
       rtu_idu_alloc_preg2[5:0];

//power optimization: mask pipedown index if dst not valid
assign ir_pipedown_inst0_dst_preg[5:0] =
       {6{ir_inst0_data[IR_DST_VLD]}} &
       ir_inst0_dst_preg[5:0];

assign ir_pipedown_inst1_dst_preg[5:0] =
       {6{ir_inst1_data[IR_DST_VLD]}} &
       ir_inst1_dst_preg[5:0];

assign ir_pipedown_inst2_dst_preg[5:0] =
       {6{ir_inst2_data[IR_DST_VLD]}} &
       ir_inst2_dst_preg[5:0];

//==========================================================
//                Prepare Rename Table data
//==========================================================

assign dp_rt_inst0_dst_vld =
       ir_inst0_data[IR_DST_VLD];

assign dp_rt_inst1_dst_vld =
       ir_inst1_data[IR_DST_VLD];

assign dp_rt_inst2_dst_vld =
       ir_inst2_data[IR_DST_VLD];

assign dp_rt_inst0_dst_reg[4:0] =
       ir_inst0_data[IR_DST_REG:IR_DST_REG-4];

assign dp_rt_inst1_dst_reg[4:0] =
       ir_inst1_data[IR_DST_REG:IR_DST_REG-4];

assign dp_rt_inst2_dst_reg[4:0] =
       ir_inst2_data[IR_DST_REG:IR_DST_REG-4];

assign dp_rt_inst0_dst_preg[5:0] =
       ir_inst0_dst_preg[5:0];

assign dp_rt_inst1_dst_preg[5:0] =
       ir_inst1_dst_preg[5:0];

assign dp_rt_inst2_dst_preg[5:0] =
       ir_inst2_dst_preg[5:0];

assign dp_rt_inst0_src0_vld =
       ir_inst0_data[IR_SRC0_VLD];

assign dp_rt_inst1_src0_vld =
       ir_inst1_data[IR_SRC0_VLD];

assign dp_rt_inst2_src0_vld =
       ir_inst2_data[IR_SRC0_VLD];

assign dp_rt_inst0_src0_reg[4:0] =
       ir_inst0_data[IR_SRC0_REG:IR_SRC0_REG-4];

assign dp_rt_inst1_src0_reg[4:0] =
       ir_inst1_data[IR_SRC0_REG:IR_SRC0_REG-4];

assign dp_rt_inst2_src0_reg[4:0] =
       ir_inst2_data[IR_SRC0_REG:IR_SRC0_REG-4];

assign dp_rt_inst0_src1_vld =
       ir_inst0_data[IR_SRC1_VLD];

assign dp_rt_inst1_src1_vld =
       ir_inst1_data[IR_SRC1_VLD];

assign dp_rt_inst2_src1_vld =
       ir_inst2_data[IR_SRC1_VLD];

assign dp_rt_inst0_src1_reg[4:0] =
       ir_inst0_data[IR_SRC1_REG:IR_SRC1_REG-4];

assign dp_rt_inst1_src1_reg[4:0] =
       ir_inst1_data[IR_SRC1_REG:IR_SRC1_REG-4];

assign dp_rt_inst2_src1_reg[4:0] =
       ir_inst2_data[IR_SRC1_REG:IR_SRC1_REG-4];


assign crtl_ir_inst2_data[96:0] = {ir_inst2_data[IR_TAKEN:IR_TAKEN-64],ir_inst2_data[IR_OPCODE:IR_OPCODE-31]};
assign ctrl_ir_inst2_chk[24:0]  = ir_inst2_chk[24:0];
//==========================================================
//                   Instance IR Decoder
//==========================================================

assign ir_inst0_opcode[31:0] =
       ir_inst0_data[IR_OPCODE:0];

assign ir_inst1_opcode[31:0] =
       ir_inst1_data[IR_OPCODE:0];

assign ir_inst2_opcode[31:0] =
       ir_inst2_data[IR_OPCODE:0];

assign dp_ctrl_ir_inst0_illegal = ir_inst0_data[IR_ILLEGAL];   
assign dp_ctrl_ir_inst1_illegal = ir_inst1_data[IR_ILLEGAL]; 
assign dp_ctrl_ir_inst2_illegal = ir_inst2_data[IR_ILLEGAL]; 
// &ConnRule(s/^x_/ir_inst0_/); @829
// &Instance("ct_idu_ir_decd", "x_ct_idu_ir_decd0"); @830
ct_idu_ir_decd x_ct_idu_ir_decd0 (
  .x_alu_short (ir_inst0_alu_short),
  .x_load      (ir_inst0_load),
  .x_opcode    (ir_inst0_opcode),
  .x_store     (ir_inst0_store),
  .x_type_alu  (ir_inst0_type_alu)
);

// &ConnRule(s/^x_/ir_inst1_/); @831
// &Instance("ct_idu_ir_decd", "x_ct_idu_ir_decd1"); @832
ct_idu_ir_decd x_ct_idu_ir_decd1 (
  .x_alu_short (ir_inst1_alu_short),
  .x_load      (ir_inst1_load),
  .x_opcode    (ir_inst1_opcode),
  .x_store     (ir_inst1_store),
  .x_type_alu  (ir_inst1_type_alu)
);

// &ConnRule(s/^x_/ir_inst2_/); @833
// &Instance("ct_idu_ir_decd", "x_ct_idu_ir_decd2"); @834
ct_idu_ir_decd x_ct_idu_ir_decd2 (
  .x_alu_short (ir_inst2_alu_short),
  .x_load      (ir_inst2_load),
  .x_opcode    (ir_inst2_opcode),
  .x_store     (ir_inst2_store),
  .x_type_alu  (ir_inst2_type_alu)
);

//==========================================================
//                 Rename for IS data path
//==========================================================
//load inst will create
//except lrw and split load (last split will create)
//pop inst do not create lsfifo

//==========================================================
//                 Rename for IS data path
//==========================================================
//----------------------------------------------------------
//                   Data path rename (RV32I Simplified)
//----------------------------------------------------------

// Instruction 0 - RV32I signal assignments to Issue Stage
// Launch and optimization signals

//是alu的快速指令，不是乘除法那些
assign dp_ir_inst0_pc[64:0] = ir_inst0_data[IR_TAKEN:IR_PC-31];

assign dp_ir_inst0_data[IS_ILLEGAL] =
       dp_ctrl_ir_inst0_illegal;

assign dp_ir_inst0_data[IS_ALU_SHORT] =
       ir_inst0_alu_short;

// Instruction type flags (decoded from IR_INST_TYPE field)
//load或store
assign dp_ir_inst0_data[IS_LSU] =
       ir_inst0_data[IR_INST_TYPE-3];

//除法指令
assign dp_ir_inst0_data[IS_DIV] =
       ir_inst0_data[IR_INST_TYPE-1];

//乘法指令
assign dp_ir_inst0_data[IS_MULT] =
       ir_inst0_data[IR_INST_TYPE];

//分支指令
assign dp_ir_inst0_data[IS_BJU] =
       ir_inst0_data[IR_INST_TYPE-2];

//store有写数据寄存器
assign dp_ir_inst0_data[IS_STADDR] =
       ir_inst0_data[IR_INST_TYPE-4];

//store
assign dp_ir_inst0_data[IS_STORE] =
       ir_inst0_store;

//load
assign dp_ir_inst0_data[IS_LOAD] =
       ir_inst0_load;

//alu
assign dp_ir_inst0_data[IS_ALU] =
       ir_inst0_data[IR_INST_TYPE-5];

assign dp_ir_inst0_data[IS_DST_REL_PREG:IS_DST_REL_PREG-5] =
       rt_dp_inst0_rel_preg[5:0];

//新分配的物理寄存器
assign dp_ir_inst0_data[IS_DST_PREG:IS_DST_PREG-5] =
       ir_pipedown_inst0_dst_preg[5:0];

//逻辑寄存器
assign dp_ir_inst0_data[IS_DST_REG:IS_DST_REG-4] =
       ir_inst0_data[IR_DST_REG:IR_DST_REG-4];

/*
  rt_dp_inst0_src2_data[9:0] = {?, preg[6:0], valid, wb_valid}
  - bit [8:2]: preg[6:0] - 源操作数2映射的物理寄存器编号
  - bit [1]: valid - 源操作数是否有效
  - bit [0]: wb_valid - 写回有效标志
*/

assign dp_ir_inst0_data[IS_SRC2_DATA:IS_SRC2_DATA-6] =
       rt_dp_inst0_src2_data[6:0];

//rt_dp_inst0_src1_data[8:0] = {ready, preg[6:0], wb_valid}
assign dp_ir_inst0_data[IS_SRC1_DATA:IS_SRC1_DATA-6] =
       rt_dp_inst0_src1_data[6:0];

assign dp_ir_inst0_data[IS_SRC0_DATA:IS_SRC0_DATA-6] =
       rt_dp_inst0_src0_data[6:0];

// Validity flags
assign dp_ir_inst0_data[IS_DST_VLD] =
       ir_inst0_data[IR_DST_VLD];

//assign dp_ir_inst0_data[IS_SRC2_VLD] =
//       ir_inst0_data[IR_SRC2_VLD];

assign dp_ir_inst0_data[IS_SRC1_VLD] =
       ir_inst0_data[IR_SRC1_VLD];

assign dp_ir_inst0_data[IS_SRC0_VLD] =
       ir_inst0_data[IR_SRC0_VLD];

// Instruction opcode (32-bit RV32I instruction encoding)
assign dp_ir_inst0_data[IS_OPCODE:IS_OPCODE-31] =
       ir_inst0_data[IR_OPCODE:0];


//==========================================================
// Instruction 1
//==========================================================

// Instruction 1 - RV32I signal assignments to Issue Stage
// Launch and optimization signals
assign dp_ir_inst1_pc[64:0] = ir_inst1_data[IR_TAKEN:IR_PC-31];

assign dp_ir_inst1_data[IS_ILLEGAL] =
       dp_ctrl_ir_inst1_illegal;

assign dp_ir_inst1_data[IS_ALU_SHORT] =
       ir_inst1_alu_short;

// Instruction type flags (decoded from IR_INST_TYPE field)
assign dp_ir_inst1_data[IS_LSU] =
       ir_inst1_data[IR_INST_TYPE-3];

assign dp_ir_inst1_data[IS_DIV] =
       ir_inst1_data[IR_INST_TYPE-1];

assign dp_ir_inst1_data[IS_MULT] =
       ir_inst1_data[IR_INST_TYPE];

assign dp_ir_inst1_data[IS_BJU] =
       ir_inst1_data[IR_INST_TYPE-2];

assign dp_ir_inst1_data[IS_STADDR] =
       ir_inst1_data[IR_INST_TYPE-4];

assign dp_ir_inst1_data[IS_STORE] =
       ir_inst1_store;

assign dp_ir_inst1_data[IS_LOAD] =
       ir_inst1_load;

assign dp_ir_inst1_data[IS_ALU] =
       ir_inst1_data[IR_INST_TYPE-5];

assign dp_ir_inst1_data[IS_DST_REL_PREG:IS_DST_REL_PREG-5] =
       rt_dp_inst1_rel_preg[5:0];

assign dp_ir_inst1_data[IS_DST_PREG:IS_DST_PREG-5] =
       ir_pipedown_inst1_dst_preg[5:0];

assign dp_ir_inst1_data[IS_DST_REG:IS_DST_REG-4] =
       ir_inst1_data[IR_DST_REG:IR_DST_REG-4];

// Source operand data
assign dp_ir_inst1_data[IS_SRC2_DATA:IS_SRC2_DATA-6] =
       rt_dp_inst1_src2_data[6:0];

assign dp_ir_inst1_data[IS_SRC1_DATA:IS_SRC1_DATA-6] =
       rt_dp_inst1_src1_data[6:0];

assign dp_ir_inst1_data[IS_SRC0_DATA:IS_SRC0_DATA-6] =
       rt_dp_inst1_src0_data[6:0];

// Validity flags
assign dp_ir_inst1_data[IS_DST_VLD] =
       ir_inst1_data[IR_DST_VLD];

assign dp_ir_inst1_data[IS_SRC1_VLD] =
       ir_inst1_data[IR_SRC1_VLD];

assign dp_ir_inst1_data[IS_SRC0_VLD] =
       ir_inst1_data[IR_SRC0_VLD];

// Instruction opcode (32-bit RV32I instruction encoding)
assign dp_ir_inst1_data[IS_OPCODE:IS_OPCODE-31] =
       ir_inst1_data[IR_OPCODE:0];

//==========================================================
// Instruction 2
//==========================================================

// Instruction 2 - RV32I signal assignments to Issue Stage
assign dp_ir_inst2_pc[64:0] = ir_inst2_data[IR_TAKEN:IR_PC-31];

assign dp_ir_inst2_data[IS_ILLEGAL] =
       dp_ctrl_ir_inst2_illegal;

assign dp_ir_inst2_data[IS_ALU_SHORT] =
       ir_inst2_alu_short;

// Instruction type flags (decoded from IR_INST_TYPE field)
assign dp_ir_inst2_data[IS_LSU] =
       ir_inst2_data[IR_INST_TYPE-3];

assign dp_ir_inst2_data[IS_DIV] =
       ir_inst2_data[IR_INST_TYPE-1];

assign dp_ir_inst2_data[IS_MULT] =
       ir_inst2_data[IR_INST_TYPE];

assign dp_ir_inst2_data[IS_BJU] =
       ir_inst2_data[IR_INST_TYPE-2];

assign dp_ir_inst2_data[IS_STADDR] =
       ir_inst2_data[IR_INST_TYPE-4];

assign dp_ir_inst2_data[IS_STORE] =
       ir_inst2_store;

assign dp_ir_inst2_data[IS_LOAD] =
       ir_inst2_load;

assign dp_ir_inst2_data[IS_ALU] =
       ir_inst2_data[IR_INST_TYPE-5];

assign dp_ir_inst2_data[IS_DST_REL_PREG:IS_DST_REL_PREG-5] =
       rt_dp_inst2_rel_preg[5:0];

assign dp_ir_inst2_data[IS_DST_PREG:IS_DST_PREG-5] =
       ir_pipedown_inst2_dst_preg[5:0];

assign dp_ir_inst2_data[IS_DST_REG:IS_DST_REG-4] =
       ir_inst2_data[IR_DST_REG:IR_DST_REG-4];

// Source operand data
assign dp_ir_inst2_data[IS_SRC2_DATA:IS_SRC2_DATA-6] =
       rt_dp_inst2_src2_data[6:0];

assign dp_ir_inst2_data[IS_SRC1_DATA:IS_SRC1_DATA-6] =
       rt_dp_inst2_src1_data[6:0];

assign dp_ir_inst2_data[IS_SRC0_DATA:IS_SRC0_DATA-6] =
       rt_dp_inst2_src0_data[6:0];

// Validity flags
assign dp_ir_inst2_data[IS_DST_VLD] =
       ir_inst2_data[IR_DST_VLD];

assign dp_ir_inst2_data[IS_SRC1_VLD] =
       ir_inst2_data[IR_SRC1_VLD];

assign dp_ir_inst2_data[IS_SRC0_VLD] =
       ir_inst2_data[IR_SRC0_VLD];

// Instruction opcode (32-bit RV32I instruction encoding)
assign dp_ir_inst2_data[IS_OPCODE:IS_OPCODE-31] =
       ir_inst2_data[IR_OPCODE:0];

// &ModuleEnd; @1241
endmodule

