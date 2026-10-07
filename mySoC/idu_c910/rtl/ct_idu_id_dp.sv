module ct_idu_id_dp(
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic         ctrl_dp_id_stall,
  input  logic [1:0]   ctrl_xx_is_inst0_sel,  // 新增：原代码中使用但端口列表缺失
  input  logic [96:0]  ifu_idu_ib_inst0_data,
  input  logic [96:0]  ifu_idu_ib_inst1_data,
  input  logic [96:0]  ifu_idu_ib_inst2_data,
  input  logic         rtu_yy_xx_flush,
  input  logic [96:0]  crtl_ir_inst2_data,
  output logic [121:0] dp_id_pipedown_inst0_data,
  output logic [121:0] dp_id_pipedown_inst1_data,
  output logic [121:0] dp_id_pipedown_inst2_data
);

//==========================================================
//                       Parameters
//==========================================================
//----------------------------------------------------------
//                 ID data path parameters
//----------------------------------------------------------
parameter ID_WIDTH            = 97;
parameter ID_TAKEN            = 96;
parameter ID_NPC              = 95;
parameter ID_PC               = 63;
parameter ID_OPCODE           = 31;

//----------------------------------------------------------
//                 IR data path parameters
//----------------------------------------------------------
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

//==========================================================
//                 Internal Signal Declarations
//==========================================================
// ID/IR pipeline register data
logic [ID_WIDTH-1:0] dp_ib_inst0_data;
logic [ID_WIDTH-1:0] dp_ib_inst1_data;
logic [ID_WIDTH-1:0] dp_ib_inst2_data;

logic [ID_WIDTH-1:0] id_inst0_data;
logic [ID_WIDTH-1:0] id_inst1_data;
logic [ID_WIDTH-1:0] id_inst2_data;  // 补齐：原代码遗漏了 inst2 的声明

// 提取的指令
logic [31:0]         id_inst0_inst;
logic [31:0]         id_inst1_inst;
logic [31:0]         id_inst2_inst;

// 解码器输出：源寄存器 0
logic                id_inst0_src0_vld;
logic [4:0]          id_inst0_src0_reg;
logic                id_inst1_src0_vld;
logic [4:0]          id_inst1_src0_reg;
logic                id_inst2_src0_vld;  // 补齐
logic [4:0]          id_inst2_src0_reg;  // 补齐

// 解码器输出：源寄存器 1
logic                id_inst0_src1_vld;
logic [4:0]          id_inst0_src1_reg;
logic                id_inst1_src1_vld;
logic [4:0]          id_inst1_src1_reg;
logic                id_inst2_src1_vld;  // 补齐
logic [4:0]          id_inst2_src1_reg;  // 补齐

// 解码器输出：目的寄存器
logic                id_inst0_dst_vld;
logic [4:0]          id_inst0_dst_reg;
logic                id_inst0_dst_x0;
logic                id_inst1_dst_vld;
logic [4:0]          id_inst1_dst_reg;
logic                id_inst1_dst_x0;
logic                id_inst2_dst_vld;   // 补齐
logic [4:0]          id_inst2_dst_reg;   // 补齐
logic                id_inst2_dst_x0;    // 补齐

// 解码器输出：指令类型
logic [5:0]          id_inst0_inst_type;
logic [5:0]          id_inst1_inst_type;
logic [5:0]          id_inst2_inst_type;  // 补齐

// 解码器输出：非法指令与分支预测
logic                id_inst0_illegal;    // 补齐
logic                id_inst1_illegal;    // 补齐
logic                id_inst2_illegal;    // 补齐

logic                id_inst0_taken;      // 补齐
logic                id_inst1_taken;      // 补齐
logic                id_inst2_taken;      // 补齐

// NPC 与 PC
logic [31:0]         id_inst0_npc;
logic [31:0]         id_inst0_pc;
logic [31:0]         id_inst1_npc;
logic [31:0]         id_inst1_pc;
logic [31:0]         id_inst2_npc;
logic [31:0]         id_inst2_pc;

//==========================================================
//                ID/IR pipeline registers
//==========================================================
//----------------------------------------------------------
//            ID Pipedown Instruction Selection
//----------------------------------------------------------
always @(*)
begin
  case(ctrl_xx_is_inst0_sel[1:0])
    2'b01  : begin
               dp_ib_inst0_data[ID_WIDTH-1:0] = crtl_ir_inst2_data[ID_WIDTH-1:0];
             end
    2'b10  : begin
               dp_ib_inst0_data[ID_WIDTH-1:0] = ifu_idu_ib_inst0_data[ID_WIDTH-1:0];
             end
    default: dp_ib_inst0_data[ID_WIDTH-1:0] = {ID_WIDTH{1'bx}};
  endcase
// &CombEnd; @545
end

// &CombBeg; @547
always @(*)
begin
  case(ctrl_xx_is_inst0_sel[1:0])
    2'b01 : begin
              dp_ib_inst1_data[ID_WIDTH-1:0] = ifu_idu_ib_inst0_data[ID_WIDTH-1:0];
            end
    2'b10 : begin
              dp_ib_inst1_data[ID_WIDTH-1:0] = ifu_idu_ib_inst1_data[ID_WIDTH-1:0];
            end
    default: dp_ib_inst1_data[ID_WIDTH-1:0] = {ID_WIDTH{1'bx}};
  endcase
// &CombEnd; @554
end

// &CombBeg; @556
always @(*)
begin
  case(ctrl_xx_is_inst0_sel[1:0])
    2'b01 : begin
              dp_ib_inst2_data[ID_WIDTH-1:0] = ifu_idu_ib_inst1_data[ID_WIDTH-1:0];
            end
    2'b10 : begin
              dp_ib_inst2_data[ID_WIDTH-1:0] = ifu_idu_ib_inst2_data[ID_WIDTH-1:0];
            end
    default: dp_ib_inst2_data[ID_WIDTH-1:0] = {ID_WIDTH{1'bx}};
  endcase
// &CombEnd; @563
end

//----------------------------------------------------------
//                ID/IR pipeline registers
//----------------------------------------------------------
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b | rtu_yy_xx_flush) begin
    id_inst0_data[ID_WIDTH-1:0] <= {ID_WIDTH{1'b0}};
    id_inst1_data[ID_WIDTH-1:0] <= {ID_WIDTH{1'b0}};
    id_inst2_data[ID_WIDTH-1:0] <= {ID_WIDTH{1'b0}};
  end
  else if(!ctrl_dp_id_stall) begin
    id_inst0_data[ID_WIDTH-1:0] <= dp_ib_inst0_data[ID_WIDTH-1:0];
    id_inst1_data[ID_WIDTH-1:0] <= dp_ib_inst1_data[ID_WIDTH-1:0];
    id_inst2_data[ID_WIDTH-1:0] <= dp_ib_inst2_data[ID_WIDTH-1:0];
  end
  else begin
    id_inst0_data[ID_WIDTH-1:0] <= id_inst0_data[ID_WIDTH-1:0];
    id_inst1_data[ID_WIDTH-1:0] <= id_inst1_data[ID_WIDTH-1:0];
    id_inst2_data[ID_WIDTH-1:0] <= id_inst2_data[ID_WIDTH-1:0];
  end
end

//==========================================================
//                    Normal Data Path
//==========================================================
//----------------------------------------------------------
//                 Instance of ID Decoder
//----------------------------------------------------------
assign id_inst0_inst[31:0] = id_inst0_data[ID_OPCODE:ID_OPCODE-31];
assign id_inst1_inst[31:0] = id_inst1_data[ID_OPCODE:ID_OPCODE-31];
assign id_inst2_inst[31:0] = id_inst2_data[ID_OPCODE:ID_OPCODE-31];

ct_idu_id_decd u_ct_idu_id_decd_0 (
    .inst      (id_inst0_inst),
    .src0_vld  (id_inst0_src0_vld),
    .src0_reg  (id_inst0_src0_reg),
    .src1_vld  (id_inst0_src1_vld),
    .src1_reg  (id_inst0_src1_reg),
    .dst_vld   (id_inst0_dst_vld),
    .dst_reg   (id_inst0_dst_reg),
    .dst_x0    (id_inst0_dst_x0),
    .inst_type (id_inst0_inst_type),
    .illegal   (id_inst0_illegal)
);

ct_idu_id_decd u_ct_idu_id_decd_1 (
    .inst      (id_inst1_inst),
    .src0_vld  (id_inst1_src0_vld),
    .src0_reg  (id_inst1_src0_reg),
    .src1_vld  (id_inst1_src1_vld),
    .src1_reg  (id_inst1_src1_reg),
    .dst_vld   (id_inst1_dst_vld),
    .dst_reg   (id_inst1_dst_reg),
    .dst_x0    (id_inst1_dst_x0),
    .inst_type (id_inst1_inst_type),
    .illegal   (id_inst1_illegal)
);

ct_idu_id_decd u_ct_idu_id_decd_2 (
    .inst      (id_inst2_inst),
    .src0_vld  (id_inst2_src0_vld),
    .src0_reg  (id_inst2_src0_reg),
    .src1_vld  (id_inst2_src1_vld),
    .src1_reg  (id_inst2_src1_reg),
    .dst_vld   (id_inst2_dst_vld),
    .dst_reg   (id_inst2_dst_reg),
    .dst_x0    (id_inst2_dst_x0),
    .inst_type (id_inst2_inst_type),
    .illegal   (id_inst2_illegal)
);

//----------------------------------------------------------
//            Rename ID stage normal inst data
//----------------------------------------------------------
assign id_inst0_taken = id_inst0_data[ID_TAKEN];
assign id_inst0_npc = id_inst0_data[ID_NPC:ID_NPC-31];
assign id_inst0_pc  = id_inst0_data[ID_PC:ID_PC-31];
assign dp_id_pipedown_inst0_data[IR_WIDTH-1:0] = {
    id_inst0_taken,
    id_inst0_npc,
    id_inst0_pc,
    id_inst0_illegal,
    id_inst0_dst_x0,
    id_inst0_inst_type,
    id_inst0_dst_reg,
    id_inst0_dst_vld,
    id_inst0_src1_reg,
    id_inst0_src1_vld,
    id_inst0_src0_reg,
    id_inst0_src0_vld,
    id_inst0_inst
};

assign id_inst1_taken = id_inst1_data[ID_TAKEN];
assign id_inst1_npc = id_inst1_data[ID_NPC:ID_NPC-31];
assign id_inst1_pc  = id_inst1_data[ID_PC:ID_PC-31];
assign dp_id_pipedown_inst1_data[IR_WIDTH-1:0] = {
    id_inst1_taken,
    id_inst1_npc,
    id_inst1_pc,
    id_inst1_illegal,
    id_inst1_dst_x0,
    id_inst1_inst_type,
    id_inst1_dst_reg,
    id_inst1_dst_vld,
    id_inst1_src1_reg,
    id_inst1_src1_vld,
    id_inst1_src0_reg,
    id_inst1_src0_vld,
    id_inst1_inst
};

assign id_inst2_taken = id_inst2_data[ID_TAKEN];
assign id_inst2_npc = id_inst2_data[ID_NPC:ID_NPC-31];
assign id_inst2_pc  = id_inst2_data[ID_PC:ID_PC-31];
assign dp_id_pipedown_inst2_data[IR_WIDTH-1:0] = {
    id_inst2_taken,
    id_inst2_npc,
    id_inst2_pc,
    id_inst2_illegal,
    id_inst2_dst_x0,
    id_inst2_inst_type,
    id_inst2_dst_reg,
    id_inst2_dst_vld,
    id_inst2_src1_reg,
    id_inst2_src1_vld,
    id_inst2_src0_reg,
    id_inst2_src0_vld,
    id_inst2_inst
};

endmodule