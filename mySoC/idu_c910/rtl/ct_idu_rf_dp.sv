module ct_idu_rf_dp (
  //==========================================================
  // 全局信号
  //==========================================================
  input  logic           cpurst_b,
  input  logic           forever_cpuclk,

  //==========================================================
  // Pipe0: AIQ
  //==========================================================
  input  logic [95:0]    aiq_dp_issue_read_data,   // 64 → 96 (2026-10-08 加 PC)
  input  logic           aiq_xx_issue_en,
  input  logic [31:0]    prf_dp_rf_pipe0_src0_data,
  input  logic [31:0]    prf_dp_rf_pipe0_src1_data,
  output logic [5:0]     dp_prf_rf_pipe0_src0_preg,
  output logic [5:0]     dp_prf_rf_pipe0_src1_preg,
  output logic [6:0]     idu_aiq_iid,
  output logic [5:0]     idu_aiq_dst_preg,
  output logic [31:0]    idu_aiq_pc,          // 2026-10-08 新增: AUIPC 要用
  output logic [31:0]    idu_aiq_src0,
  output logic [31:0]    idu_aiq_src1,
  output logic [12:0]    idu_aiq_rslt_sel,
  output logic           idu_aiq_illegal,

  //==========================================================
  // Pipe1: AIQ1 / MULT
  //==========================================================
  input  logic [62:0]    mult_dp_issue_read_data,
  input  logic           mult_xx_issue_en,
  input  logic [31:0]    prf_dp_rf_pipe1_src0_data,
  input  logic [31:0]    prf_dp_rf_pipe1_src1_data,
  output logic [5:0]     dp_prf_rf_pipe1_src0_preg,
  output logic [5:0]     dp_prf_rf_pipe1_src1_preg,
  output logic [6:0]     idu_mult_iid,
  output logic [5:0]     idu_mult_dst_preg,
  output logic [31:0]    idu_mult_src0,
  output logic [31:0]    idu_mult_src1,
  output logic [3:0]     idu_mult_rslt_sel,

  //==========================================================
  // Pipe2: DIV
  //==========================================================
  input  logic [62:0]    div_dp_issue_read_data,
  input  logic           div_xx_issue_en,
  input  logic [31:0]    prf_dp_rf_pipe2_src0_data,
  input  logic [31:0]    prf_dp_rf_pipe2_src1_data,
  output logic [5:0]     dp_prf_rf_pipe2_src0_preg,
  output logic [5:0]     dp_prf_rf_pipe2_src1_preg,
  output logic [6:0]     idu_div_iid,
  // 补: 顶层一直在连 .idu_div_dst_vld, 但本模块原来没有这个端口 (同事的分析工具
  // 也把它标成 bogus)。内部其实早就算好了 (见 dp_ctrl_is_div_issue_dst_vld),
  // 只是那根线当时没有任何消费者 —— 声明了端口接出去即可, 逻辑一行没动。
  output logic           idu_div_dst_vld,
  output logic [5:0]     idu_div_dst_preg,
  output logic [31:0]    idu_div_src0,
  output logic [31:0]    idu_div_src1,
  output logic [3:0]     idu_div_rslt_sel,

  //==========================================================
  // Pipe3: LSIQ Load
  //==========================================================
  input  logic [7:0]     lsiq_dp_pipe3_issue_entry,
  input  logic [59:0]    lsiq_dp_pipe3_issue_read_data,
  input  logic           lsiq_xx_pipe3_issue_en,
  input  logic           lsiq_pipe3_entry_unalign_2nd,
  input  logic           lsiq_pipe3_entry_old,
  input  logic [31:0]    prf_dp_rf_pipe3_src0_data,
  output logic [5:0]     dp_prf_rf_pipe3_src0_preg,
  output logic [6:0]     idu_lsu_ld_iid,
  output logic [5:0]     idu_lsu_ld_preg,
  output logic [31:0]    idu_lsu_ld_src0,
  output logic [11:0]    idu_lsu_ld_offset,
  output logic [12:0]    idu_lsu_ld_offset_plus,
  output logic           idu_lsu_ld_sign_extend,
  output logic [1:0]     idu_lsu_ld_inst_size,
  output logic           idu_lsu_ld_unalign_2nd,
  output logic [7:0]     idu_lsu_ld_lch_entry,
  output logic           idu_lsu_ld_oldest,

  //==========================================================
  // Pipe4: LSIQ Store
  //==========================================================
  input  logic [7:0]     lsiq_dp_pipe4_issue_entry,
  input  logic [59:0]    lsiq_dp_pipe4_issue_read_data,
  input  logic           lsiq_xx_pipe4_issue_en,
  input  logic           lsiq_pipe4_entry_unalign_2nd,
  input  logic           lsiq_pipe4_entry_old,
  input  logic [31:0]    prf_dp_rf_pipe4_src0_data,
  output logic [5:0]     dp_prf_rf_pipe4_src0_preg,
  output logic [6:0]     idu_lsu_st_iid,
  //output logic [5:0]     idu_lsu_st_preg,
  output logic [31:0]    idu_lsu_st_src0,
  output logic [11:0]    idu_lsu_st_offset,
  output logic [12:0]    idu_lsu_st_offset_plus,
  output logic [1:0]     idu_lsu_st_inst_size,
  output logic           idu_lsu_st_unalign_2nd,
  output logic [7:0]     idu_lsu_st_lch_entry,
  output logic           idu_lsu_st_oldest,
  output logic [3:0]     idu_lsu_st_sdiq_entry,

  //==========================================================
  // Pipe5: SDIQ
  //==========================================================
  input  logic [3:0]     sdiq_dp_issue_entry,
  input  logic [7:0]     sdiq_dp_issue_read_data,
  input  logic           sdiq_xx_issue_en,
  input  logic [31:0]    prf_dp_rf_pipe5_src0_data,
  output logic [5:0]     dp_prf_rf_pipe5_src0_preg,
  output logic [3:0]     idu_lsu_rf_pipe5_sdiq_entry,
  output logic [31:0]    idu_lsu_rf_pipe5_src0,

  //==========================================================
  // Pipe6: BIQ
  //==========================================================
  input  logic [151:0]   biq_dp_issue_read_data,
  input  logic           biq_xx_issue_en,
  input  logic [31:0]    prf_dp_rf_pipe6_src0_data,
  input  logic [31:0]    prf_dp_rf_pipe6_src1_data,
  output logic [5:0]     dp_prf_rf_pipe6_src0_preg,
  output logic [5:0]     dp_prf_rf_pipe6_src1_preg,
  output logic [6:0]     idu_biq_iid,
  output logic [31:0]    idu_biq_src0,
  output logic [31:0]    idu_biq_src1,
  output logic [7:0]     idu_biq_rslt_sel,
  output logic [31:0]    idu_biq_br_imme,
  output logic           idu_biq_dst_vld,
  output logic [5:0]     idu_biq_dst_preg,   // [BIQ_DST_PREG : -5] 共 6 bit
  output logic           idu_biq_taken,      // [BIQ_PC] 单 bit
  output logic [31:0]    idu_biq_npc,        // [BIQ_PC-1  : BIQ_PC-32]
  output logic [31:0]    idu_biq_pc,          // [BIQ_PC-33 : BIQ_PC-64]
  output logic [24:0]    idu_biq_chk
);

//==========================================================
//                       Parameters
//==========================================================
//----------------------------------------------------------
//                    AIQ Parameters
//----------------------------------------------------------
parameter AIQ_WIDTH             = 96;   // 2026-10-08: 64 → 96 (高 32 位给 PC)
parameter AIQ_PC                = 95;   // 2026-10-08 新增
parameter AIQ_ILLEGAL           = 63;
parameter AIQ_IID               = 62;
parameter AIQ_SRC2_DATA         = 55;
parameter AIQ_SRC1_DATA         = 48;
parameter AIQ_SRC0_DATA         = 41;
parameter AIQ_DST_VLD           = 34;
parameter AIQ_SRC1_VLD          = 33;
parameter AIQ_SRC0_VLD          = 32;
parameter AIQ_OPCODE            = 31;

parameter MD_WIDTH              = 63;   // 2026-10-08: 64 → 96 (高 32 位给 PC)
parameter MD_IID               = 62;
parameter MD_SRC2_DATA         = 55;
parameter MD_SRC1_DATA         = 48;
parameter MD_SRC0_DATA         = 41;
parameter MD_DST_VLD           = 34;
parameter MD_SRC1_VLD          = 33;
parameter MD_SRC0_VLD          = 32;
parameter MD_OPCODE            = 31;
//----------------------------------------------------------
//                    BIQ Parameters
//----------------------------------------------------------
parameter BIQ_WIDTH             = 152;
parameter BIQ_CHK               = 151;
parameter BIQ_PC                = 126;
parameter BIQ_IID               = 61;
parameter BIQ_DST_PREG          = 54;
parameter BIQ_SRC1_DATA         = 48;
parameter BIQ_SRC0_DATA         = 41;
parameter BIQ_DST_VLD           = 34;
parameter BIQ_SRC1_VLD          = 33;
parameter BIQ_SRC0_VLD          = 32;
parameter BIQ_OPCODE            = 31;

//----------------------------------------------------------
//                    LSIQ Parameters
//----------------------------------------------------------
parameter LSIQ_WIDTH             = 60;
parameter LSIQ_IID               = 59;
parameter LSIQ_SDIQ_ENTRY        = 52;
parameter LSIQ_STORE             = 48;
parameter LSIQ_LOAD              = 47;
parameter LSIQ_SRC0_DATA         = 46;
parameter LSIQ_DST_PREG          = 39;
parameter LSIQ_DST_VLD           = 33;
parameter LSIQ_SRC0_VLD          = 32;
parameter LSIQ_OPCODE            = 31;

//----------------------------------------------------------
//                    SDIQ Parameters
//----------------------------------------------------------
parameter SDIQ_WIDTH             = 8;
parameter SDIQ_SRC1_DATA         = 7;
// 与 ct_idu_is_sdiq_entry 的 SDIQ_SRC0_PREG 保持同一个值 —— 那个 entry 的
// read_data 布局是 [5:0]=src0_preg, [6]=src0_vld。原来这里用 SDIQ_SRC1_DATA
// 读 [7:2], 会把 vld 位当 preg 的最高位, 与生产者对不上。
parameter SDIQ_SRC0_PREG         = 5;
parameter SDIQ_SRC1_VLD          = 0;

//----------------------------------------------------------
//                    ALU Parameters
//----------------------------------------------------------
parameter ALU_SEL                = 13;

//==========================================================
//                    Internal Signals
//==========================================================

//----------------------------------------------------------
// Pipe0
//----------------------------------------------------------
logic [AIQ_WIDTH-1:0]  rf_pipe0_data;
logic                  rf_pipe0_prf_src0_preg_updt_vld;
logic                  rf_pipe0_prf_src1_preg_updt_vld;
logic [5:0]            rf_pipe0_prf_src0_preg;
logic [5:0]            rf_pipe0_prf_src1_preg;
logic [31:0]           pipe0_decd_opcode;
logic [ALU_SEL-1:0]    pipe0_decd_sel;
logic [31:0]           pipe0_decd_imm;
logic [31:0]           pipe0_decd_src1_imm;
logic [31:0]           rf_pipe0_src0_data;
logic [31:0]           rf_pipe0_src1_data;

//----------------------------------------------------------
// Pipe1
//----------------------------------------------------------
logic [3:0]            rf_pipe1_iq_entry;
logic [MD_WIDTH-1:0]  rf_pipe1_data;
logic                  rf_pipe1_prf_src0_preg_updt_vld;
logic                  rf_pipe1_prf_src1_preg_updt_vld;
logic [5:0]            rf_pipe1_prf_src0_preg;
logic [5:0]            rf_pipe1_prf_src1_preg;
logic [31:0]           pipe1_decd_opcode;
logic [3:0]            pipe1_decd_sel;
logic [31:0]           rf_pipe1_src0_data;
logic [31:0]           rf_pipe1_src1_data;


//----------------------------------------------------------
// Pipe2
//----------------------------------------------------------
logic [MD_WIDTH-1:0]  rf_pipe2_data;
logic                  rf_pipe2_prf_src0_preg_updt_vld;
logic                  rf_pipe2_prf_src1_preg_updt_vld;
logic [5:0]            rf_pipe2_prf_src0_preg;
logic [5:0]            rf_pipe2_prf_src1_preg;
logic [31:0]           pipe2_decd_opcode;
logic [3:0]            pipe2_decd_sel;
logic [31:0]           rf_pipe2_src0_data;
logic [31:0]           rf_pipe2_src1_data;

//----------------------------------------------------------
// Pipe3
//----------------------------------------------------------
logic [7:0]            rf_pipe3_iq_entry;
logic                  rf_pipe3_2nd;
logic                  rf_pipe3_old;
logic [LSIQ_WIDTH-1:0] rf_pipe3_data;
logic                  rf_pipe3_prf_src0_preg_updt_vld;
logic [5:0]            rf_pipe3_prf_src0_preg;
logic [1:0]            pipe3_decd_inst_size;
logic [11:0]           pipe3_decd_offset;
logic [12:0]           pipe3_decd_offset_plus;
logic [31:0]           pipe3_decd_opcode;
logic                  pipe3_decd_sign_extend;
logic [31:0]           rf_pipe3_src0_data;

//----------------------------------------------------------
// Pipe4
//----------------------------------------------------------
logic [7:0]            rf_pipe4_iq_entry;
logic                  rf_pipe4_2nd;
logic                  rf_pipe4_old;
logic [LSIQ_WIDTH-1:0] rf_pipe4_data;
logic                  rf_pipe4_prf_src0_preg_updt_vld;
logic [5:0]            rf_pipe4_prf_src0_preg;
logic [1:0]            pipe4_decd_inst_size;
logic [11:0]           pipe4_decd_offset;
logic [12:0]           pipe4_decd_offset_plus;
logic [31:0]           pipe4_decd_opcode;
logic [31:0]           rf_pipe4_src0_data;

//----------------------------------------------------------
// Pipe5
//----------------------------------------------------------
logic [3:0]            rf_pipe5_iq_entry;
logic                  rf_pipe5_prf_src0_preg_updt_vld;
logic [5:0]            rf_pipe5_prf_src0_preg;
logic [31:0]           rf_pipe5_src0_data;

//----------------------------------------------------------
// Pipe6
//----------------------------------------------------------
logic [BIQ_WIDTH-1:0]  rf_pipe6_data;
logic                  rf_pipe6_prf_src0_preg_updt_vld;
logic                  rf_pipe6_prf_src1_preg_updt_vld;
logic [5:0]            rf_pipe6_prf_src0_preg;
logic [5:0]            rf_pipe6_prf_src1_preg;
logic [31:0]           pipe6_decd_opcode;
logic [7:0]            pipe6_decd_sel;
logic [31:0]           pipe6_decd_br_imm;
logic [31:0]           rf_pipe6_src0_data;
logic [31:0]           rf_pipe6_src1_data;

//==========================================================
//                    Pipe0 Data Path
//==========================================================
//----------------------------------------------------------
//                  Rename Pipedown Data
//----------------------------------------------------------
assign dp_ctrl_is_aiq_issue_dst_vld = aiq_dp_issue_read_data[AIQ_DST_VLD];

//----------------------------------------------------------
//                   Pipeline Registers
//----------------------------------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe0_data[AIQ_WIDTH-1:0] <= {AIQ_WIDTH{1'b0}};
  end
  else if(aiq_xx_issue_en) begin
    rf_pipe0_data[AIQ_WIDTH-1:0] <= aiq_dp_issue_read_data[AIQ_WIDTH-1:0];
  end
  else begin
    rf_pipe0_data[AIQ_WIDTH-1:0] <= rf_pipe0_data[AIQ_WIDTH-1:0];
  end
end

//----------------------------------------------------------
//                Source Pipeline Registers
//----------------------------------------------------------
assign rf_pipe0_prf_src0_preg_updt_vld = aiq_xx_issue_en;
assign rf_pipe0_prf_src1_preg_updt_vld = aiq_xx_issue_en;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe0_prf_src0_preg[5:0] <= 6'b0;
  else if(rf_pipe0_prf_src0_preg_updt_vld)
    rf_pipe0_prf_src0_preg[5:0] <= aiq_dp_issue_read_data[AIQ_SRC0_DATA:AIQ_SRC0_DATA-5];
  else
    rf_pipe0_prf_src0_preg[5:0] <= rf_pipe0_prf_src0_preg[5:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe0_prf_src1_preg[5:0] <= 6'b0;
  else if(rf_pipe0_prf_src1_preg_updt_vld)
    rf_pipe0_prf_src1_preg[5:0] <= aiq_dp_issue_read_data[AIQ_SRC1_DATA:AIQ_SRC1_DATA-5];
  else
    rf_pipe0_prf_src1_preg[5:0] <= rf_pipe0_prf_src1_preg[5:0];
end

//output
assign dp_prf_rf_pipe0_src0_preg[5:0] = rf_pipe0_prf_src0_preg[5:0];
assign dp_prf_rf_pipe0_src1_preg[5:0] = rf_pipe0_prf_src1_preg[5:0];

//----------------------------------------------------------
//                    RF stage Decoder
//----------------------------------------------------------
ct_idu_rf_pipe0_decd  x_ct_idu_rf_pipe0_decd (
  .pipe0_decd_opcode   (pipe0_decd_opcode  ),
  .pipe0_decd_sel      (pipe0_decd_sel     ),
  .pipe0_decd_imm      (pipe0_decd_imm     )
);

assign pipe0_decd_opcode[31:0] = rf_pipe0_data[AIQ_OPCODE:AIQ_OPCODE-31];

//----------------------------------------------------------
//                    Source Operand 0
//----------------------------------------------------------
assign rf_pipe0_src0_data[31:0] = prf_dp_rf_pipe0_src0_data[31:0];

//----------------------------------------------------------
//                    Source Operand 1
//----------------------------------------------------------
always @(*)
begin
  if(!rf_pipe0_data[AIQ_SRC1_VLD])
    rf_pipe0_src1_data[31:0] = pipe0_decd_imm[31:0];
  else 
    rf_pipe0_src1_data[31:0] = prf_dp_rf_pipe0_src1_data[31:0];
end

//----------------------------------------------------------
//                Output to Execution Units
//----------------------------------------------------------
assign idu_aiq_iid[6:0]              = rf_pipe0_data[AIQ_IID:AIQ_IID-6];
assign idu_aiq_dst_preg[5:0]         = rf_pipe0_data[AIQ_SRC2_DATA:AIQ_SRC2_DATA-5];
// 2026-10-08 新增: 把表项里存的 PC 引出来。C910 里 AUIPC 的 PC 来自 BJU 的
// PC FIFO, 交付的 IDU 没有那一路 ⇒ 这里照 chk 的做法随指令带进 AIQ 表项。
assign idu_aiq_pc[31:0]              = rf_pipe0_data[AIQ_PC:AIQ_PC-31];
assign idu_aiq_src0[31:0]            = rf_pipe0_src0_data[31:0];
assign idu_aiq_src1[31:0]            = rf_pipe0_src1_data[31:0];
assign idu_aiq_rslt_sel[ALU_SEL-1:0] = pipe0_decd_sel[ALU_SEL-1:0];
assign idu_aiq_illegal               = rf_pipe0_data[AIQ_ILLEGAL];

//==========================================================
//                    Pipe1 Data Path
//==========================================================
//----------------------------------------------------------
//                  Rename Pipedown Data
//----------------------------------------------------------
assign dp_ctrl_is_mult_issue_dst_vld = mult_dp_issue_read_data[MD_DST_VLD];

//----------------------------------------------------------
//                   Pipeline Registers
//----------------------------------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe1_data[MD_WIDTH-1:0] <= {MD_WIDTH{1'b0}};
  end
  else if(aiq_xx_issue_en) begin
    rf_pipe1_data[MD_WIDTH-1:0] <= mult_dp_issue_read_data[MD_WIDTH-1:0];
  end
  else begin
    rf_pipe1_data[MD_WIDTH-1:0] <= rf_pipe1_data[MD_WIDTH-1:0];
  end
end

//----------------------------------------------------------
//                Source Pipeline Registers
//----------------------------------------------------------
assign rf_pipe1_prf_src0_preg_updt_vld = mult_xx_issue_en;
assign rf_pipe1_prf_src1_preg_updt_vld = mult_xx_issue_en;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe1_prf_src0_preg[5:0] <= 6'b0;
  else if(rf_pipe1_prf_src0_preg_updt_vld)
    rf_pipe1_prf_src0_preg[5:0] <= mult_dp_issue_read_data[MD_SRC0_DATA:MD_SRC0_DATA-5];
  else
    rf_pipe1_prf_src0_preg[5:0] <= rf_pipe1_prf_src0_preg[5:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe1_prf_src1_preg[5:0] <= 6'b0;
  else if(rf_pipe1_prf_src1_preg_updt_vld)
    rf_pipe1_prf_src1_preg[5:0] <= mult_dp_issue_read_data[MD_SRC1_DATA:MD_SRC1_DATA-5];
  else
    rf_pipe1_prf_src1_preg[5:0] <= rf_pipe1_prf_src1_preg[5:0];
end

//output
assign dp_prf_rf_pipe1_src0_preg[5:0] = rf_pipe1_prf_src0_preg[5:0];
assign dp_prf_rf_pipe1_src1_preg[5:0] = rf_pipe1_prf_src1_preg[5:0];

//----------------------------------------------------------
//                    RF stage Decoder
//----------------------------------------------------------
ct_idu_rf_pipe1_decd  x_ct_idu_rf_pipe1_decd (
  .pipe1_decd_opcode   (pipe1_decd_opcode  ),
  .pipe1_decd_mul_sel      (pipe1_decd_sel     )
);

assign pipe1_decd_opcode[31:0] = rf_pipe1_data[MD_OPCODE:MD_OPCODE-31];

//----------------------------------------------------------
//                    Source Operand 0/1
//----------------------------------------------------------
assign rf_pipe1_src0_data[31:0] = prf_dp_rf_pipe1_src0_data[31:0];
assign rf_pipe1_src1_data[31:0] = prf_dp_rf_pipe1_src1_data[31:0];

//----------------------------------------------------------
//                Output to Execution Units
//----------------------------------------------------------
assign idu_mult_iid[6:0]      = rf_pipe1_data[MD_IID:MD_IID-6];
assign idu_mult_dst_preg[5:0] = rf_pipe1_data[MD_SRC2_DATA:MD_SRC2_DATA-5];
assign idu_mult_src0[31:0]    = rf_pipe1_src0_data[31:0];
assign idu_mult_src1[31:0]    = rf_pipe1_src1_data[31:0];
assign idu_mult_rslt_sel[3:0] = pipe1_decd_sel[3:0];

//==========================================================
//                    Pipe2 Data Path
//==========================================================
//----------------------------------------------------------
//                  Rename Pipedown Data
//----------------------------------------------------------
assign dp_ctrl_is_div_issue_dst_vld = div_dp_issue_read_data[MD_DST_VLD];
// 补: 把这个值接到新加的输出端口上 (原来这根线没有任何消费者)
assign idu_div_dst_vld              = dp_ctrl_is_div_issue_dst_vld;

//----------------------------------------------------------
//                   Pipeline Registers
//----------------------------------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe2_data[MD_WIDTH-1:0] <= {MD_WIDTH{1'b0}};
  end
  else if(div_xx_issue_en) begin
    rf_pipe2_data[MD_WIDTH-1:0] <= div_dp_issue_read_data[MD_WIDTH-1:0];
  end
  else begin
    rf_pipe2_data[MD_WIDTH-1:0] <= rf_pipe2_data[MD_WIDTH-1:0];
  end
end

//----------------------------------------------------------
//                Source Pipeline Registers
//----------------------------------------------------------
assign rf_pipe2_prf_src0_preg_updt_vld = div_xx_issue_en;
assign rf_pipe2_prf_src1_preg_updt_vld = div_xx_issue_en;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe2_prf_src0_preg[5:0] <= 6'b0;
  else if(rf_pipe2_prf_src0_preg_updt_vld)
    rf_pipe2_prf_src0_preg[5:0] <= div_dp_issue_read_data[MD_SRC0_DATA:MD_SRC0_DATA-5];
  else
    rf_pipe2_prf_src0_preg[5:0] <= rf_pipe2_prf_src0_preg[5:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe2_prf_src1_preg[5:0] <= 6'b0;
  else if(rf_pipe2_prf_src1_preg_updt_vld)
    rf_pipe2_prf_src1_preg[5:0] <= div_dp_issue_read_data[MD_SRC1_DATA:MD_SRC1_DATA-5];
  else
    rf_pipe2_prf_src1_preg[5:0] <= rf_pipe2_prf_src1_preg[5:0];
end

//output
assign dp_prf_rf_pipe2_src0_preg[5:0] = rf_pipe2_prf_src0_preg[5:0];
assign dp_prf_rf_pipe2_src1_preg[5:0] = rf_pipe2_prf_src1_preg[5:0];

//----------------------------------------------------------
//                    RF stage Decoder
//----------------------------------------------------------
ct_idu_rf_pipe2_decd  x_ct_idu_rf_pipe2_decd (
  .pipe2_decd_opcode   (pipe2_decd_opcode  ),
  .pipe2_decd_div_sel      (pipe2_decd_sel     )
);

assign pipe2_decd_opcode[31:0] = rf_pipe2_data[MD_OPCODE:MD_OPCODE-31];

//----------------------------------------------------------
//                    Source Operand 0/1
//----------------------------------------------------------
assign rf_pipe2_src0_data[31:0] = prf_dp_rf_pipe2_src0_data[31:0];
assign rf_pipe2_src1_data[31:0] = prf_dp_rf_pipe2_src1_data[31:0];

//----------------------------------------------------------
//                Output to Execution Units
//----------------------------------------------------------
assign idu_div_iid[6:0]      = rf_pipe2_data[MD_IID:MD_IID-6];
assign idu_div_dst_preg[5:0] = rf_pipe2_data[MD_SRC2_DATA:MD_SRC2_DATA-5];
assign idu_div_src0[31:0]    = rf_pipe2_src0_data[31:0];
assign idu_div_src1[31:0]    = rf_pipe2_src1_data[31:0];
assign idu_div_rslt_sel[3:0] = pipe2_decd_sel[3:0];

//==========================================================
//                    Pipe3 Data Path
//==========================================================
//----------------------------------------------------------
//                   Pipeline Registers
//----------------------------------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe3_iq_entry[7:0]        <= 8'b0;
    rf_pipe3_2nd                  <= 1'b0;   
    rf_pipe3_old                  <= 1'b0;
    rf_pipe3_data[LSIQ_WIDTH-1:0] <= {LSIQ_WIDTH{1'b0}};
  end
  else if(lsiq_xx_pipe3_issue_en) begin
    rf_pipe3_iq_entry[7:0]        <= lsiq_dp_pipe3_issue_entry[7:0];
    rf_pipe3_2nd                  <= lsiq_pipe3_entry_unalign_2nd;
    rf_pipe3_old                  <= lsiq_pipe3_entry_old;
    rf_pipe3_data[LSIQ_WIDTH-1:0] <= lsiq_dp_pipe3_issue_read_data[LSIQ_WIDTH-1:0];
  end
  else begin
    rf_pipe3_iq_entry[7:0]        <= rf_pipe3_iq_entry[7:0];
    rf_pipe3_2nd                  <= rf_pipe3_2nd;
    rf_pipe3_old                  <= rf_pipe3_old;
    rf_pipe3_data[LSIQ_WIDTH-1:0] <= rf_pipe3_data[LSIQ_WIDTH-1:0];
  end
end

//----------------------------------------------------------
//                Source Pipeline Registers
//----------------------------------------------------------
assign rf_pipe3_prf_src0_preg_updt_vld = lsiq_xx_pipe3_issue_en;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe3_prf_src0_preg[5:0] <= 6'b0;
  else if(rf_pipe3_prf_src0_preg_updt_vld)
    rf_pipe3_prf_src0_preg[5:0] <= lsiq_dp_pipe3_issue_read_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-5];
  else
    rf_pipe3_prf_src0_preg[5:0] <= rf_pipe3_prf_src0_preg[5:0];
end

//output
assign dp_prf_rf_pipe3_src0_preg[5:0] = rf_pipe3_prf_src0_preg[5:0];

//----------------------------------------------------------
//                    RF stage Decoder
//----------------------------------------------------------
ct_idu_rf_pipe3_decd  x_ct_idu_rf_pipe3_decd (
  .pipe3_decd_inst_size    (pipe3_decd_inst_size   ),
  .pipe3_decd_offset       (pipe3_decd_offset      ),
  .pipe3_decd_offset_plus  (pipe3_decd_offset_plus ),
  .pipe3_decd_opcode       (pipe3_decd_opcode      ),
  .pipe3_decd_sign_extend  (pipe3_decd_sign_extend )
);

assign pipe3_decd_opcode[31:0] = rf_pipe3_data[LSIQ_OPCODE:LSIQ_OPCODE-31];

//----------------------------------------------------------
//                    Source Operand
//----------------------------------------------------------
assign rf_pipe3_src0_data[31:0] = prf_dp_rf_pipe3_src0_data[31:0];

//----------------------------------------------------------
//                Output to Execution Units
//----------------------------------------------------------
assign idu_lsu_ld_iid[6:0]          = rf_pipe3_data[LSIQ_IID:LSIQ_IID-6];
assign idu_lsu_ld_preg[5:0]         = rf_pipe3_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5];
assign idu_lsu_ld_src0[31:0]        = rf_pipe3_src0_data[31:0];
assign idu_lsu_ld_offset[11:0]      = pipe3_decd_offset[11:0];
assign idu_lsu_ld_offset_plus[12:0] = pipe3_decd_offset_plus[12:0];
assign idu_lsu_ld_sign_extend       = pipe3_decd_sign_extend;
assign idu_lsu_ld_inst_size[1:0]    = pipe3_decd_inst_size[1:0];
assign idu_lsu_ld_unalign_2nd       = rf_pipe3_2nd;
assign idu_lsu_ld_lch_entry[7:0]    = rf_pipe3_iq_entry[7:0];
assign idu_lsu_ld_oldest            = rf_pipe3_old;

//==========================================================
//                    Pipe4 Data Path
//==========================================================
//----------------------------------------------------------
//                   Pipeline Registers
//----------------------------------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe4_iq_entry[7:0]        <= 8'b0;
    rf_pipe4_2nd                  <= 1'b0;   
    rf_pipe4_old                  <= 1'b0;
    rf_pipe4_data[LSIQ_WIDTH-1:0] <= {LSIQ_WIDTH{1'b0}};
  end
  else if(lsiq_xx_pipe4_issue_en) begin
    rf_pipe4_iq_entry[7:0]        <= lsiq_dp_pipe4_issue_entry[7:0];
    rf_pipe4_2nd                  <= lsiq_pipe4_entry_unalign_2nd;
    rf_pipe4_old                  <= lsiq_pipe4_entry_old;
    rf_pipe4_data[LSIQ_WIDTH-1:0] <= lsiq_dp_pipe4_issue_read_data[LSIQ_WIDTH-1:0];
  end
  else begin
    rf_pipe4_iq_entry[7:0]        <= rf_pipe4_iq_entry[7:0];
    rf_pipe4_2nd                  <= rf_pipe4_2nd;
    rf_pipe4_old                  <= rf_pipe4_old;
    rf_pipe4_data[LSIQ_WIDTH-1:0] <= rf_pipe4_data[LSIQ_WIDTH-1:0];
  end
end

//----------------------------------------------------------
//                Source Pipeline Registers
//----------------------------------------------------------
assign rf_pipe4_prf_src0_preg_updt_vld = lsiq_xx_pipe4_issue_en;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe4_prf_src0_preg[5:0] <= 6'b0;
  else if(rf_pipe4_prf_src0_preg_updt_vld)
    rf_pipe4_prf_src0_preg[5:0] <= lsiq_dp_pipe4_issue_read_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-5];
  else
    rf_pipe4_prf_src0_preg[5:0] <= rf_pipe4_prf_src0_preg[5:0];
end

//output
assign dp_prf_rf_pipe4_src0_preg[5:0] = rf_pipe4_prf_src0_preg[5:0];

//----------------------------------------------------------
//                    RF stage Decoder
//----------------------------------------------------------
ct_idu_rf_pipe4_decd  x_ct_idu_rf_pipe4_decd (
  .pipe4_decd_inst_size    (pipe4_decd_inst_size   ),
  .pipe4_decd_offset       (pipe4_decd_offset      ),
  .pipe4_decd_offset_plus  (pipe4_decd_offset_plus ),
  .pipe4_decd_opcode       (pipe4_decd_opcode      )
);

assign pipe4_decd_opcode[31:0] = rf_pipe4_data[LSIQ_OPCODE:LSIQ_OPCODE-31];

//----------------------------------------------------------
//                    Source Operand
//----------------------------------------------------------
assign rf_pipe4_src0_data[31:0] = prf_dp_rf_pipe4_src0_data[31:0];

//----------------------------------------------------------
//                Output to Execution Units
//----------------------------------------------------------
assign idu_lsu_st_iid[6:0]          = rf_pipe4_data[LSIQ_IID:LSIQ_IID-6];
//assign idu_lsu_st_preg[5:0]         = rf_pipe4_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5];
assign idu_lsu_st_src0[31:0]        = rf_pipe4_src0_data[31:0];
assign idu_lsu_st_offset[11:0]      = pipe4_decd_offset[11:0];
assign idu_lsu_st_offset_plus[12:0] = pipe4_decd_offset_plus[12:0];
assign idu_lsu_st_inst_size[1:0]    = pipe4_decd_inst_size[1:0];
assign idu_lsu_st_unalign_2nd       = rf_pipe4_2nd;
assign idu_lsu_st_lch_entry[7:0]    = rf_pipe4_iq_entry[7:0];
assign idu_lsu_st_oldest            = rf_pipe4_old;
assign idu_lsu_st_sdiq_entry[3:0]   = rf_pipe4_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3];

//==========================================================
//                    Pipe5 Data Path
//==========================================================
//----------------------------------------------------------
//                   Pipeline Registers
//----------------------------------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe5_iq_entry[3:0] <= 4'b0;
  end
  else if(sdiq_xx_issue_en) begin
    rf_pipe5_iq_entry[3:0] <= sdiq_dp_issue_entry[3:0];
  end
  else begin
    rf_pipe5_iq_entry[3:0] <= rf_pipe5_iq_entry[3:0];
  end
end

//----------------------------------------------------------
//                Source Pipeline Registers
//----------------------------------------------------------
assign rf_pipe5_prf_src0_preg_updt_vld = sdiq_xx_issue_en;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe5_prf_src0_preg[5:0] <= 6'b0;
  else if(rf_pipe5_prf_src0_preg_updt_vld)
    rf_pipe5_prf_src0_preg[5:0] <= sdiq_dp_issue_read_data[SDIQ_SRC0_PREG:SDIQ_SRC0_PREG-5];
  else
    rf_pipe5_prf_src0_preg[5:0] <= rf_pipe5_prf_src0_preg[5:0];
end

//output
assign dp_prf_rf_pipe5_src0_preg[5:0] = rf_pipe5_prf_src0_preg[5:0];

//----------------------------------------------------------
//                    Source Operand 0
//----------------------------------------------------------
assign rf_pipe5_src0_data[31:0] = prf_dp_rf_pipe5_src0_data[31:0];

//----------------------------------------------------------
//                Output to Execution Units
//----------------------------------------------------------
assign idu_lsu_rf_pipe5_sdiq_entry[3:0] = rf_pipe5_iq_entry[3:0];
assign idu_lsu_rf_pipe5_src0[31:0]      = rf_pipe5_src0_data[31:0];

//==========================================================
//                    Pipe6 Data Path
//==========================================================
//----------------------------------------------------------
//                  Rename Pipedown Data
//----------------------------------------------------------

//----------------------------------------------------------
//                   Pipeline Registers
//----------------------------------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    rf_pipe6_data[BIQ_WIDTH-1:0] <= {BIQ_WIDTH{1'b0}};
  end
  else if(biq_xx_issue_en) begin
    rf_pipe6_data[BIQ_WIDTH-1:0] <= biq_dp_issue_read_data[BIQ_WIDTH-1:0];
  end
  else begin
    rf_pipe6_data[BIQ_WIDTH-1:0] <= rf_pipe6_data[BIQ_WIDTH-1:0];
  end
end

//----------------------------------------------------------
//                Source Pipeline Registers
//----------------------------------------------------------
assign rf_pipe6_prf_src0_preg_updt_vld = biq_xx_issue_en;
assign rf_pipe6_prf_src1_preg_updt_vld = biq_xx_issue_en;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe6_prf_src0_preg[5:0] <= 6'b0;
  else if(rf_pipe6_prf_src0_preg_updt_vld)
    rf_pipe6_prf_src0_preg[5:0] <= biq_dp_issue_read_data[BIQ_SRC0_DATA:BIQ_SRC0_DATA-5];
  else
    rf_pipe6_prf_src0_preg[5:0] <= rf_pipe6_prf_src0_preg[5:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rf_pipe6_prf_src1_preg[5:0] <= 6'b0;
  else if(rf_pipe6_prf_src1_preg_updt_vld)
    rf_pipe6_prf_src1_preg[5:0] <= biq_dp_issue_read_data[BIQ_SRC1_DATA:BIQ_SRC1_DATA-5];
  else
    rf_pipe6_prf_src1_preg[5:0] <= rf_pipe6_prf_src1_preg[5:0];
end

//output
assign dp_prf_rf_pipe6_src0_preg[5:0] = rf_pipe6_prf_src0_preg[5:0];
assign dp_prf_rf_pipe6_src1_preg[5:0] = rf_pipe6_prf_src1_preg[5:0];

//----------------------------------------------------------
//                    RF stage Decoder
//----------------------------------------------------------
ct_idu_rf_pipe6_decd  x_ct_idu_rf_pipe6_decd (
  .pipe6_decd_opcode   (pipe6_decd_opcode  ),
  .pipe6_decd_br_sel      (pipe6_decd_sel     ),
  .pipe6_decd_br_imm   (pipe6_decd_br_imm  )
);

assign pipe6_decd_opcode[31:0] = rf_pipe6_data[BIQ_OPCODE:BIQ_OPCODE-31];

//----------------------------------------------------------
//                    Source Operand 0
//----------------------------------------------------------
assign rf_pipe6_src0_data[31:0] = prf_dp_rf_pipe6_src0_data[31:0];
assign rf_pipe6_src1_data[31:0] = prf_dp_rf_pipe6_src1_data[31:0];

//----------------------------------------------------------
//                Output to Execution Units
//----------------------------------------------------------
assign idu_biq_chk[24:0]     = rf_pipe6_data[BIQ_CHK:BIQ_CHK-24];
assign idu_biq_iid[6:0]      = rf_pipe6_data[BIQ_IID:BIQ_IID-6];
assign idu_biq_src0[31:0]    = rf_pipe6_src0_data[31:0];
assign idu_biq_src1[31:0]    = rf_pipe6_src1_data[31:0];
assign idu_biq_rslt_sel[7:0] = pipe6_decd_sel[7:0];
assign idu_biq_br_imme[31:0] = pipe6_decd_br_imm[31:0];
assign idu_biq_dst_vld       = rf_pipe6_data[BIQ_DST_VLD];
assign idu_biq_dst_preg      = rf_pipe6_data[BIQ_DST_PREG:BIQ_DST_PREG-5];
assign idu_biq_taken         = rf_pipe6_data[BIQ_PC];
assign idu_biq_npc[31:0]     = rf_pipe6_data[BIQ_PC-1:BIQ_PC-32];
assign idu_biq_pc[31:0]      = rf_pipe6_data[BIQ_PC-33:BIQ_PC-64];

endmodule