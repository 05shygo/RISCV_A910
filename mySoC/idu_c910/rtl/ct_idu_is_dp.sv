module ct_idu_is_dp (
  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         forever_clk,
  input  logic         cpurst_b,

  // IR data
  input  logic [82:0] dp_ir_inst0_data,
  input  logic [64:0] dp_ir_inst0_pc,
  input  logic [24:0] dp_ir_inst0_chk,
  input  logic [82:0] dp_ir_inst1_data,
  input  logic [64:0] dp_ir_inst1_pc,
  input  logic [24:0] dp_ir_inst1_chk,
  input  logic [82:0] dp_ir_inst2_data,
  input  logic [64:0] dp_ir_inst2_pc,
  input  logic [24:0] dp_ir_inst2_chk,

  // IID from RTU
  input  logic [6:0]   rtu_idu_rob_inst0_iid,
  input  logic [6:0]   rtu_idu_rob_inst1_iid,
  input  logic [6:0]   rtu_idu_rob_inst2_iid,

  // Flush
  input  logic         rtu_yy_xx_flush,

  // Writeback from IU
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,

  // Writeback from LSU
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,

  // Control signals
  input  logic         ctrl_dp_is_inst0_vld,
  input  logic         ctrl_dp_is_inst1_vld,
  input  logic         ctrl_dp_is_inst2_vld,
  input  logic         ctrl_dp_is_dis_stall,
  input  logic         ctrl_ir_pipedown,
  input  logic [1:0]   ctrl_xx_is_inst0_sel,


  input  logic [3:0]   sdiq_create0_entry,
  input  logic [3:0]   sdiq_create1_entry,

  // Queue enable inputs

  input  logic         ctrl_sdiq_create0_en,
  input  logic         ctrl_sdiq_create1_en,

  // Queue create select signals
  input  logic [1:0]   ctrl_dp_is_dis_aiq_create0_sel,
  input  logic [1:0]   ctrl_dp_is_dis_aiq_create1_sel,
  input  logic [1:0]   ctrl_dp_is_dis_biq_create0_sel,
  input  logic [1:0]   ctrl_dp_is_dis_biq_create1_sel,
  input  logic [1:0]   ctrl_dp_is_dis_lsiq_create0_sel,
  input  logic [1:0]   ctrl_dp_is_dis_lsiq_create1_sel,
  input  logic [1:0]   ctrl_dp_is_dis_sdiq_create0_sel,
  input  logic [1:0]   ctrl_dp_is_dis_sdiq_create1_sel,
  input  logic [1:0]   ctrl_dp_is_dis_mult_create0_sel,
  input  logic [1:0]   ctrl_dp_is_dis_mult_create1_sel,
  input  logic [1:0]   ctrl_dp_is_dis_div_create0_sel,
  input  logic [1:0]   ctrl_dp_is_dis_div_create1_sel,

  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic [6:0]   dp_ctrl_is_dis_inst2_ctrl_info,
  output logic [63:0]  dp_aiq_create0_data,
  output logic [63:0]  dp_aiq_create1_data,
  output logic [151:0] dp_biq_create0_data,
  output logic [151:0] dp_biq_create1_data,
  output logic         dp_ctrl_is_inst0_dst_vld,
  output logic         dp_ctrl_is_inst1_dst_vld,
  output logic         dp_ctrl_is_inst2_dst_vld,
  output logic [67:0]  dp_lsiq_create0_data,
  output logic [67:0]  dp_lsiq_create1_data,
  output logic [7:0]   dp_sdiq_create0_data,
  output logic [7:0]   dp_sdiq_create1_data,
  output logic [62:0]  dp_mult_create0_data,
  output logic [62:0]  dp_mult_create1_data,
  output logic [62:0]  dp_div_create0_data,
  output logic [62:0]  dp_div_create1_data,

  //----------------------------------------------------------------------------
  // 【2026-10-08 新增】派遣记录 —— 给 RTU（退休单元）用的逐路录出
  //
  // 为什么加在这里: 下面那批 `*_create{0,1}_data` 是**按发射队列**组织的, 每个队列
  // 只有 2 个 create 口, 且靠 `ctrl_dp_is_dis_*_create{0,1}_sel` 指明"这口装的是
  // 三路里的哪一路" —— 从那些 create 口**反推不出**完整的三路记录 (没有进任何队列的
  // 那一路就丢了)。而 `is_inst{0,1,2}_create_{data,pc,chk}` 本来就是**按车道**排好的
  // 派遣当拍最终值 (已含 pipedown2 的 mux, 见 :218-256), 所以直接按车道录出。
  //
  // 字段含义 (data[82:0] 的位域见文件里的 IS_* parameter):
  //   pc   —— **只取 [31:0]**: 内部是 65 位 {taken[64], npc[63:32], pc[31:0]}
  //   chk  —— 前端取指时打包的预测快照, 退休点训练要用
  //   data —— 指令 + 分类 + 逻辑/物理寄存器号, 由顶层 ct_idu_top 拆给 RTU
  //
  // ⚠️ 按车道录出, 但**是否真的派发**由 ct_idu_is_ctrl 的 ctrl_dp_dis_inst{k}_vld 决定 —
  //    这两者必须成对使用 (data 是组合值, 车道没派发时它没有意义)。
  //----------------------------------------------------------------------------
  output logic [82:0]  dp_is_dis_inst0_data,
  output logic [82:0]  dp_is_dis_inst1_data,
  output logic [82:0]  dp_is_dis_inst2_data,
  output logic [31:0]  dp_is_dis_inst0_pc,
  output logic [31:0]  dp_is_dis_inst1_pc,
  output logic [31:0]  dp_is_dis_inst2_pc,
  output logic [24:0]  dp_is_dis_inst0_chk,
  output logic [24:0]  dp_is_dis_inst1_chk,
  output logic [24:0]  dp_is_dis_inst2_chk
);

//==========================================================
//                       Parameters
//==========================================================
//----------------------------------------------------------
//                 IS ctrl path parameters
//----------------------------------------------------------
parameter IS_WIDTH             = 83;
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

//----------------------------------------------------------
//                    AIQ Parameters
//----------------------------------------------------------
parameter AIQ_WIDTH             = 64;
parameter AIQ_ILLEGAL           = 63; // 修正：补上分号
parameter AIQ_IID               = 62;
parameter AIQ_SRC2_DATA         = 55;
parameter AIQ_SRC1_DATA         = 48;
parameter AIQ_SRC0_DATA         = 41;
parameter AIQ_DST_VLD           = 34;
parameter AIQ_SRC1_VLD          = 33;
parameter AIQ_SRC0_VLD          = 32;
parameter AIQ_OPCODE            = 31;

parameter MD_WIDTH              = 63;
parameter MD_IID                = 62;
parameter MD_SRC2_DATA          = 55;
parameter MD_SRC1_DATA          = 48;
parameter MD_SRC0_DATA          = 41;
parameter MD_DST_VLD            = 34;
parameter MD_SRC1_VLD           = 33;
parameter MD_SRC0_VLD           = 32;
parameter MD_OPCODE             = 31;

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
parameter SDIQ_SRC1_VLD          = 0;

//==========================================================
//                IR/IS pipeline registers
//==========================================================
//----------------------------------------------------------
//           control signals for pipeline entry
//----------------------------------------------------------
logic is_inst0_create_dp_en;
logic is_inst1_create_dp_en;
logic is_inst2_create_dp_en;
logic is_inst_create_dp_en;

assign is_inst0_create_dp_en      = ctrl_dp_is_inst0_vld && !ctrl_dp_is_dis_stall;
assign is_inst1_create_dp_en      = ctrl_dp_is_inst1_vld && !ctrl_dp_is_dis_stall;
assign is_inst2_create_dp_en      = ctrl_dp_is_inst2_vld && !ctrl_dp_is_dis_stall;
assign is_inst_create_dp_en       = ctrl_ir_pipedown && !ctrl_dp_is_dis_stall;

//----------------------------------------------------------
//             IS pipeline registers shift MUX
//----------------------------------------------------------
logic [IS_WIDTH-1:0] is_inst0_read_data;
logic [IS_WIDTH-1:0] is_inst1_read_data;
logic [IS_WIDTH-1:0] is_inst2_read_data;

logic [IS_WIDTH-1:0] is_inst0_create_data;
logic [IS_WIDTH-1:0] is_inst1_create_data;
logic [IS_WIDTH-1:0] is_inst2_create_data;

// 【补齐】以下 6 个信号在原代码中使用但未声明
logic [64:0] is_inst0_create_pc;
logic [64:0] is_inst1_create_pc;
logic [64:0] is_inst2_create_pc;
logic [64:0] is_inst0_read_pc;
logic [64:0] is_inst1_read_pc;
logic [64:0] is_inst2_read_pc;

logic [64:0] is_inst0_create_chk;
logic [64:0] is_inst1_create_chk;
logic [64:0] is_inst2_create_chk;
logic [64:0] is_inst0_read_chk;
logic [64:0] is_inst1_read_chk;
logic [64:0] is_inst2_read_chk;
// &CombBeg; @545
always @(*)
begin
  case(ctrl_xx_is_inst0_sel[1:0])
    2'b01 : begin
              is_inst0_create_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
              is_inst0_create_pc[64:0]           = is_inst2_read_pc[64:0];
              is_inst0_create_chk[24:0]          = is_inst2_read_chk[24:0];
              is_inst1_create_data[IS_WIDTH-1:0] = dp_ir_inst0_data[IS_WIDTH-1:0];
              is_inst1_create_pc[64:0]           = dp_ir_inst0_pc[64:0];
              is_inst1_create_chk[24:0]          = dp_ir_inst0_chk[24:0];
              is_inst2_create_data[IS_WIDTH-1:0] = dp_ir_inst1_data[IS_WIDTH-1:0];
              is_inst2_create_pc[64:0]           = dp_ir_inst1_pc[64:0];
              is_inst2_create_chk[24:0]          = dp_ir_inst1_chk[24:0];
            end
    2'b10 : begin
              is_inst0_create_data[IS_WIDTH-1:0] = dp_ir_inst0_data[IS_WIDTH-1:0];
              is_inst0_create_pc[64:0]           = dp_ir_inst0_pc[64:0];
              is_inst0_create_chk[24:0]          = dp_ir_inst0_chk[24:0];
              is_inst1_create_data[IS_WIDTH-1:0] = dp_ir_inst1_data[IS_WIDTH-1:0];
              is_inst1_create_pc[64:0]           = dp_ir_inst1_pc[64:0];
              is_inst1_create_chk[24:0]          = dp_ir_inst1_chk[24:0];
              is_inst2_create_data[IS_WIDTH-1:0] = dp_ir_inst2_data[IS_WIDTH-1:0];
              is_inst2_create_pc[64:0]           = dp_ir_inst2_pc[64:0];
              is_inst2_create_chk[24:0]          = dp_ir_inst2_chk[24:0];
            end
    default: begin
              is_inst0_create_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
              is_inst0_create_pc[64:0]           = {65{1'bx}};
              is_inst0_create_chk[24:0]          = {25{1'bx}};
              is_inst1_create_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
              is_inst1_create_pc[64:0]           = {65{1'bx}};
              is_inst1_create_chk[24:0]          = {25{1'bx}};
              is_inst2_create_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
              is_inst2_create_pc[64:0]           = {65{1'bx}};
              is_inst2_create_chk[24:0]          = {25{1'bx}};
            end
  endcase
end

//==========================================================
//   派遣记录录出 (2026-10-08 新增, 给 RTU)
//==========================================================
// 就是把上面那个 mux 的三路结果按车道引出去。注意:
//   * data 是 83 位原样, 由 ct_idu_top 拆字段 (IDU 这边不解释 RTU 的 flags 编码);
//   * pc 只录 [31:0] —— 内部 65 位 = {taken, npc[31:0], pc[31:0]};
//   * chk 内部声明成了 [64:0] 但只用 [24:0] (见上面声明处的注释), 这里按 25 位录。
assign dp_is_dis_inst0_data[82:0] = is_inst0_create_data[82:0];
assign dp_is_dis_inst1_data[82:0] = is_inst1_create_data[82:0];
assign dp_is_dis_inst2_data[82:0] = is_inst2_create_data[82:0];
assign dp_is_dis_inst0_pc[31:0]   = is_inst0_create_pc[31:0];
assign dp_is_dis_inst1_pc[31:0]   = is_inst1_create_pc[31:0];
assign dp_is_dis_inst2_pc[31:0]   = is_inst2_create_pc[31:0];
assign dp_is_dis_inst0_chk[24:0]  = is_inst0_create_chk[24:0];
assign dp_is_dis_inst1_chk[24:0]  = is_inst1_create_chk[24:0];
assign dp_is_dis_inst2_chk[24:0]  = is_inst2_create_chk[24:0];

parameter IS_CTRL_WIDTH       = 7;
parameter IS_CTRL_ILLEGAL     = 6;
parameter IS_CTRL_ALU         = 5;
parameter IS_CTRL_STADDR      = 4;
parameter IS_CTRL_LSU         = 3;
parameter IS_CTRL_BJU         = 2;
parameter IS_CTRL_DIV         = 1;
parameter IS_CTRL_MULT        = 0;

assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_ILLEGAL] = is_inst2_read_data[IS_ILLEGAL];
assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_STADDR]  = is_inst2_read_data[IS_STADDR];
assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_LSU]     = is_inst2_read_data[IS_LSU];
assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_BJU]     = is_inst2_read_data[IS_BJU];
assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_DIV]     = is_inst2_read_data[IS_DIV];
assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_MULT]    = is_inst2_read_data[IS_MULT];
assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_ALU]     = is_inst2_read_data[IS_ALU];

//----------------------------------------------------------
//            pipeline entry registers instance
//----------------------------------------------------------
ct_idu_is_pipe_entry u_ct_idu_is_pipe_entry_0 (
  .cpurst_b                          (cpurst_b),
  .forever_cpuclk                    (forever_clk),   // 子模块端口名是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush),
  .x_create_data                     (is_inst0_create_data),
  .x_create_pc                       (is_inst0_create_pc),
  .x_create_chk                      (is_inst0_create_chk),
  .x_create_dp_en                    (is_inst0_create_dp_en),
  .x_read_data                       (is_inst0_read_data),
  .x_read_pc                         (is_inst0_read_pc),
  .x_read_chk                        (is_inst0_read_chk)
);

ct_idu_is_pipe_entry u_ct_idu_is_pipe_entry_1 (
  .cpurst_b                          (cpurst_b),
  .forever_cpuclk                    (forever_clk),   // 子模块端口名是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush),
  .x_create_data                     (is_inst1_create_data),
  .x_create_pc                       (is_inst1_create_pc),
  .x_create_chk                      (is_inst1_create_chk),
  .x_create_dp_en                    (is_inst1_create_dp_en),
  .x_read_data                       (is_inst1_read_data),
  .x_read_pc                         (is_inst1_read_pc),
  .x_read_chk                        (is_inst1_read_chk)
);

ct_idu_is_pipe_entry u_ct_idu_is_pipe_entry_2 (
  .cpurst_b                          (cpurst_b),
  .forever_cpuclk                    (forever_clk),   // 子模块端口名是 forever_cpuclk
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush),
  .x_create_data                     (is_inst2_create_data),
  .x_create_pc                       (is_inst2_create_pc),
  .x_create_chk                      (is_inst2_create_chk),
  .x_create_dp_en                    (is_inst2_create_dp_en),
  .x_read_data                       (is_inst2_read_data),
  .x_read_pc                         (is_inst2_read_pc),
  .x_read_chk                        (is_inst2_read_chk)
);

//----------------------------------------------------------
//                       Assign IID
//----------------------------------------------------------
logic [6:0] is_inst0_iid;
logic [6:0] is_inst1_iid;
logic [6:0] is_inst2_iid;

assign is_inst0_iid[6:0] = rtu_idu_rob_inst0_iid[6:0];
assign is_inst1_iid[6:0] = rtu_idu_rob_inst1_iid[6:0];
assign is_inst2_iid[6:0] = rtu_idu_rob_inst2_iid[6:0];

//==========================================================
//                 Create Data for PST
//==========================================================
assign dp_ctrl_is_inst0_dst_vld  = is_inst0_read_data[IS_DST_VLD];
assign dp_ctrl_is_inst1_dst_vld  = is_inst1_read_data[IS_DST_VLD];
assign dp_ctrl_is_inst2_dst_vld  = is_inst2_read_data[IS_DST_VLD];

//==========================================================
//               Create Launch Ready for AIQ
//==========================================================
//----------------------------------------------------------
//               Issue Queue Create entry
//----------------------------------------------------------
logic [3:0] ctrl_is_sdiq_create0_entry;
logic [3:0] ctrl_is_sdiq_create1_entry;

assign ctrl_is_sdiq_create0_entry[3:0] = {4{ctrl_sdiq_create0_en}} & sdiq_create0_entry[3:0];
assign ctrl_is_sdiq_create1_entry[3:0] = {4{ctrl_sdiq_create1_en}} & sdiq_create1_entry[3:0];


//==========================================================
//               Create Data for Issue Queue
//==========================================================
//----------------------------------------------------------
//                  Create Data for AIQ
//----------------------------------------------------------
logic [IS_WIDTH-1:0] is_aiq_create0_data;
logic [6:0]          is_aiq_create0_iid;
logic [IS_WIDTH-1:0] is_aiq_create1_data;
logic [6:0]          is_aiq_create1_iid;

// &CombBeg; @2720
always @(*)
begin
  case(ctrl_dp_is_dis_aiq_create0_sel[1:0])
    2'd0: begin
          is_aiq_create0_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_aiq_create0_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_aiq_create0_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_aiq_create0_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_aiq_create0_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_aiq_create0_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_aiq_create0_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_aiq_create0_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @2773
end

// &CombBeg; @2775
always @(*)
begin
  case(ctrl_dp_is_dis_aiq_create1_sel[1:0])
    2'd0: begin
          is_aiq_create1_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_aiq_create1_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_aiq_create1_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_aiq_create1_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_aiq_create1_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_aiq_create1_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_aiq_create1_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_aiq_create1_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @2828
end

//----------------------------------------------------------
//                Reorganize for AIQ create
//----------------------------------------------------------
logic [AIQ_WIDTH-1:0] aiq_create0_data;
logic [AIQ_WIDTH-1:0] aiq_create1_data;

assign dp_aiq_create0_data[AIQ_WIDTH-1:0] = aiq_create0_data[AIQ_WIDTH-1:0];
assign dp_aiq_create1_data[AIQ_WIDTH-1:0] = aiq_create1_data[AIQ_WIDTH-1:0];

assign aiq_create0_data[AIQ_ILLEGAL]                          = is_aiq_create0_data[IS_ILLEGAL];
assign aiq_create0_data[AIQ_SRC2_DATA:AIQ_SRC2_DATA-6]        = is_aiq_create0_data[IS_SRC2_DATA:IS_SRC2_DATA-6];
assign aiq_create0_data[AIQ_SRC1_DATA:AIQ_SRC1_DATA-6]        = is_aiq_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign aiq_create0_data[AIQ_SRC0_DATA:AIQ_SRC0_DATA-6]        = is_aiq_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign aiq_create0_data[AIQ_DST_VLD]                          = is_aiq_create0_data[IS_DST_VLD];
assign aiq_create0_data[AIQ_SRC1_VLD]                         = is_aiq_create0_data[IS_SRC1_VLD];
assign aiq_create0_data[AIQ_SRC0_VLD]                         = is_aiq_create0_data[IS_SRC0_VLD];
assign aiq_create0_data[AIQ_IID:AIQ_IID-6]                    = is_aiq_create0_iid[6:0];
assign aiq_create0_data[AIQ_OPCODE:AIQ_OPCODE-31]             = is_aiq_create0_data[IS_OPCODE:IS_OPCODE-31];

assign aiq_create1_data[AIQ_ILLEGAL]                          = is_aiq_create1_data[IS_ILLEGAL]; // 修正：源信号由 create0 改为 create1
assign aiq_create1_data[AIQ_SRC2_DATA:AIQ_SRC2_DATA-6]        = is_aiq_create1_data[IS_SRC2_DATA:IS_SRC2_DATA-6];
assign aiq_create1_data[AIQ_SRC1_DATA:AIQ_SRC1_DATA-6]        = is_aiq_create1_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign aiq_create1_data[AIQ_SRC0_DATA:AIQ_SRC0_DATA-6]        = is_aiq_create1_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign aiq_create1_data[AIQ_DST_VLD]                          = is_aiq_create1_data[IS_DST_VLD];
assign aiq_create1_data[AIQ_SRC1_VLD]                         = is_aiq_create1_data[IS_SRC1_VLD];
assign aiq_create1_data[AIQ_SRC0_VLD]                         = is_aiq_create1_data[IS_SRC0_VLD];
assign aiq_create1_data[AIQ_IID:AIQ_IID-6]                    = is_aiq_create1_iid[6:0];
assign aiq_create1_data[AIQ_OPCODE:AIQ_OPCODE-31]             = is_aiq_create1_data[IS_OPCODE:IS_OPCODE-31];

//----------------------------------------------------------
//                  Create Data for BIQ
//----------------------------------------------------------
logic [IS_WIDTH-1:0] is_biq_create0_data;
logic [6:0]          is_biq_create0_iid;
logic [IS_WIDTH-1:0] is_biq_create1_data;
logic [6:0]          is_biq_create1_iid;

// 【补齐】以下信号在原代码中使用但未声明
logic [64:0]         is_biq_create0_pc;
logic [64:0]         is_biq_create1_pc;
logic [24:0]         is_biq_create0_chk;
logic [24:0]         is_biq_create1_chk;

// &CombBeg; @3167
always @(*)
begin
  case(ctrl_dp_is_dis_biq_create0_sel[1:0])
    2'd0: begin
          is_biq_create0_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_biq_create0_pc[64:0]           = is_inst0_read_pc[64:0];
          is_biq_create0_chk[24:0]          = is_inst0_read_chk[24:0];
          is_biq_create0_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_biq_create0_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_biq_create0_pc[64:0]           = is_inst1_read_pc[64:0];
          is_biq_create0_chk[24:0]          = is_inst1_read_chk[24:0];
          is_biq_create0_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_biq_create0_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_biq_create0_pc[64:0]           = is_inst2_read_pc[64:0];
          is_biq_create0_chk[24:0]          = is_inst2_read_chk[24:0];
          is_biq_create0_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_biq_create0_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_biq_create0_pc[64:0]           = {65{1'bx}};
          is_biq_create0_chk[24:0]          = {25{1'bx}};
          is_biq_create0_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @3195
end

always @(*)
begin
  case(ctrl_dp_is_dis_biq_create1_sel[1:0])
    2'd0: begin
          is_biq_create1_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_biq_create1_pc[64:0]           = is_inst0_read_pc[64:0];
          is_biq_create1_chk[24:0]          = is_inst0_read_chk[24:0];
          is_biq_create1_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_biq_create1_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_biq_create1_pc[64:0]           = is_inst1_read_pc[64:0];
          is_biq_create1_chk[24:0]          = is_inst1_read_chk[24:0];
          is_biq_create1_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_biq_create1_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_biq_create1_pc[64:0]           = is_inst2_read_pc[64:0];
          is_biq_create1_chk[24:0]          = is_inst2_read_chk[24:0];
          is_biq_create1_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_biq_create1_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_biq_create1_pc[64:0]           = {65{1'bx}};
          is_biq_create1_chk[24:0]          = {25{1'bx}};
          is_biq_create1_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @3225
end

//----------------------------------------------------------
//                Reorganize for BIQ create
//----------------------------------------------------------
logic [BIQ_WIDTH-1:0] biq_create0_data;
logic [BIQ_WIDTH-1:0] biq_create1_data;

assign dp_biq_create0_data[BIQ_WIDTH-1:0] = biq_create0_data[BIQ_WIDTH-1:0];
assign dp_biq_create1_data[BIQ_WIDTH-1:0] = biq_create1_data[BIQ_WIDTH-1:0];

assign biq_create0_data[BIQ_CHK:BIQ_CHK-24]            = is_biq_create0_chk[24:0];
assign biq_create0_data[BIQ_PC:BIQ_PC-64]              = is_biq_create0_pc[64:0];
assign biq_create0_data[BIQ_DST_PREG:BIQ_DST_PREG-5]   = is_biq_create0_data[IS_DST_PREG:IS_DST_PREG-5];
assign biq_create0_data[BIQ_SRC1_DATA:BIQ_SRC1_DATA-6] = is_biq_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign biq_create0_data[BIQ_SRC0_DATA:BIQ_SRC0_DATA-6] = is_biq_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign biq_create0_data[BIQ_DST_VLD]                   = is_biq_create0_data[IS_DST_VLD];
assign biq_create0_data[BIQ_SRC1_VLD]                  = is_biq_create0_data[IS_SRC1_VLD];
assign biq_create0_data[BIQ_SRC0_VLD]                  = is_biq_create0_data[IS_SRC0_VLD];
assign biq_create0_data[BIQ_IID:BIQ_IID-6]             = is_biq_create0_iid[6:0];
assign biq_create0_data[BIQ_OPCODE:BIQ_OPCODE-31]      = is_biq_create0_data[IS_OPCODE:IS_OPCODE-31];

assign biq_create1_data[BIQ_CHK:BIQ_CHK-24]            = is_biq_create1_chk[24:0];
assign biq_create1_data[BIQ_PC:BIQ_PC-64]              = is_biq_create1_pc[64:0];
assign biq_create1_data[BIQ_DST_PREG:BIQ_DST_PREG-5]   = is_biq_create1_data[IS_DST_PREG:IS_DST_PREG-5];
assign biq_create1_data[BIQ_SRC1_DATA:BIQ_SRC1_DATA-6] = is_biq_create1_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign biq_create1_data[BIQ_SRC0_DATA:BIQ_SRC0_DATA-6] = is_biq_create1_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign biq_create1_data[BIQ_DST_VLD]                   = is_biq_create1_data[IS_DST_VLD];
assign biq_create1_data[BIQ_SRC1_VLD]                  = is_biq_create1_data[IS_SRC1_VLD];
assign biq_create1_data[BIQ_SRC0_VLD]                  = is_biq_create1_data[IS_SRC0_VLD];
assign biq_create1_data[BIQ_IID:BIQ_IID-6]             = is_biq_create1_iid[6:0];
assign biq_create1_data[BIQ_OPCODE:BIQ_OPCODE-31]      = is_biq_create1_data[IS_OPCODE:IS_OPCODE-31];

//----------------------------------------------------------
//                  Create Data for LSIQ
//----------------------------------------------------------
logic [IS_WIDTH-1:0] is_lsiq_create0_data;
logic [6:0]          is_lsiq_create0_iid;
logic [IS_WIDTH-1:0] is_lsiq_create1_data;
logic [6:0]          is_lsiq_create1_iid;

// &CombBeg; @3296
always @(*)
begin
  case(ctrl_dp_is_dis_lsiq_create0_sel[1:0])
    2'd0: begin
          is_lsiq_create0_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_lsiq_create0_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_lsiq_create0_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_lsiq_create0_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_lsiq_create0_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_lsiq_create0_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_lsiq_create0_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_lsiq_create0_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @3319
end

// &CombBeg; @3321
always @(*)
begin
  case(ctrl_dp_is_dis_lsiq_create1_sel[1:0])
    2'd1: begin
          is_lsiq_create1_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_lsiq_create1_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_lsiq_create1_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_lsiq_create1_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_lsiq_create1_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_lsiq_create1_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @3340
end

//----------------------------------------------------------
//                Reorganize for LSIQ create
//----------------------------------------------------------
logic [LSIQ_WIDTH-1:0] lsiq_create0_data;
logic [LSIQ_WIDTH-1:0] lsiq_create1_data;

assign dp_lsiq_create0_data[LSIQ_WIDTH-1:0]                  = lsiq_create0_data[LSIQ_WIDTH-1:0];
assign dp_lsiq_create1_data[LSIQ_WIDTH-1:0]                  = lsiq_create1_data[LSIQ_WIDTH-1:0];

assign lsiq_create0_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3] = ctrl_is_sdiq_create0_entry[3:0];
assign lsiq_create0_data[LSIQ_STORE]                         = is_lsiq_create0_data[IS_STORE];
assign lsiq_create0_data[LSIQ_LOAD]                          = is_lsiq_create0_data[IS_LOAD];
assign lsiq_create0_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-6]    = is_lsiq_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign lsiq_create0_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5]      = is_lsiq_create0_data[IS_DST_PREG:IS_DST_PREG-5];
assign lsiq_create0_data[LSIQ_DST_VLD]                       = is_lsiq_create0_data[IS_DST_VLD];
assign lsiq_create0_data[LSIQ_SRC0_VLD]                      = is_lsiq_create0_data[IS_SRC0_VLD];
assign lsiq_create0_data[LSIQ_IID:LSIQ_IID-6]                = is_lsiq_create0_iid[6:0];
assign lsiq_create0_data[LSIQ_OPCODE:LSIQ_OPCODE-31]         = is_lsiq_create0_data[IS_OPCODE:IS_OPCODE-31];

assign lsiq_create1_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3] = ctrl_is_sdiq_create1_entry[3:0];
assign lsiq_create1_data[LSIQ_STORE]                         = is_lsiq_create1_data[IS_STORE];
assign lsiq_create1_data[LSIQ_LOAD]                          = is_lsiq_create1_data[IS_LOAD];
assign lsiq_create1_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-6]    = is_lsiq_create1_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign lsiq_create1_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5]      = is_lsiq_create1_data[IS_DST_PREG:IS_DST_PREG-5];
assign lsiq_create1_data[LSIQ_DST_VLD]                       = is_lsiq_create1_data[IS_DST_VLD];
assign lsiq_create1_data[LSIQ_SRC0_VLD]                      = is_lsiq_create1_data[IS_SRC0_VLD];
assign lsiq_create1_data[LSIQ_IID:LSIQ_IID-6]                = is_lsiq_create1_iid[6:0];
assign lsiq_create1_data[LSIQ_OPCODE:LSIQ_OPCODE-31]         = is_lsiq_create1_data[IS_OPCODE:IS_OPCODE-31];

//----------------------------------------------------------
//                  Create Data for SDIQ
//----------------------------------------------------------
logic [IS_WIDTH-1:0] is_sdiq_create0_data;
logic [IS_WIDTH-1:0] is_sdiq_create1_data;

// &CombBeg; @3549
always @(*)
begin
  case(ctrl_dp_is_dis_sdiq_create0_sel[1:0])
    2'd0: is_sdiq_create0_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
    2'd1: is_sdiq_create0_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
    2'd2: is_sdiq_create0_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
    default: is_sdiq_create0_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
  endcase
// &CombEnd; @3557
end

// &CombBeg; @3559
always @(*)
begin
  case(ctrl_dp_is_dis_sdiq_create1_sel[1:0])
    2'd1: is_sdiq_create1_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
    2'd2: is_sdiq_create1_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
    default: is_sdiq_create1_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
  endcase
// &CombEnd; @3566
end

//----------------------------------------------------------
//                Reorganize for SDIQ create
//----------------------------------------------------------
logic [SDIQ_WIDTH-1:0] sdiq_create0_data;
logic [SDIQ_WIDTH-1:0] sdiq_create1_data;

assign dp_sdiq_create0_data[SDIQ_WIDTH-1:0] = sdiq_create0_data[SDIQ_WIDTH-1:0];
assign dp_sdiq_create1_data[SDIQ_WIDTH-1:0] = sdiq_create1_data[SDIQ_WIDTH-1:0];

assign sdiq_create0_data[SDIQ_SRC1_DATA:SDIQ_SRC1_DATA-6]   = is_sdiq_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign sdiq_create0_data[SDIQ_SRC1_VLD]                     = is_sdiq_create0_data[IS_SRC1_VLD];

assign sdiq_create1_data[SDIQ_SRC1_DATA:SDIQ_SRC1_DATA-6]   = is_sdiq_create1_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign sdiq_create1_data[SDIQ_SRC1_VLD]                     = is_sdiq_create1_data[IS_SRC1_VLD];

//----------------------------------------------------------
//                  Create Data for MULT
//----------------------------------------------------------
logic [IS_WIDTH-1:0] is_mult_create0_data;
logic [6:0]          is_mult_create0_iid;
logic [IS_WIDTH-1:0] is_mult_create1_data;
logic [6:0]          is_mult_create1_iid;

// &CombBeg; @2720
always @(*)
begin
  case(ctrl_dp_is_dis_mult_create0_sel[1:0])
    2'd0: begin
          is_mult_create0_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_mult_create0_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_mult_create0_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_mult_create0_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_mult_create0_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_mult_create0_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_mult_create0_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_mult_create0_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @2773
end

// &CombBeg; @2775
always @(*)
begin
  case(ctrl_dp_is_dis_mult_create1_sel[1:0])
    2'd0: begin
          is_mult_create1_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_mult_create1_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_mult_create1_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_mult_create1_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_mult_create1_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_mult_create1_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_mult_create1_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_mult_create1_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @2828
end

//----------------------------------------------------------
//                Reorganize for MULT create
//----------------------------------------------------------
logic [MD_WIDTH-1:0] mult_create0_data;
logic [MD_WIDTH-1:0] mult_create1_data;

assign dp_mult_create0_data[MD_WIDTH-1:0] = mult_create0_data[MD_WIDTH-1:0];
assign dp_mult_create1_data[MD_WIDTH-1:0] = mult_create1_data[MD_WIDTH-1:0];

assign mult_create0_data[MD_SRC2_DATA:MD_SRC2_DATA-6]        = is_mult_create0_data[IS_SRC2_DATA:IS_SRC2_DATA-6];
assign mult_create0_data[MD_SRC1_DATA:MD_SRC1_DATA-6]        = is_mult_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign mult_create0_data[MD_SRC0_DATA:MD_SRC0_DATA-6]        = is_mult_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign mult_create0_data[MD_DST_VLD]                         = is_mult_create0_data[IS_DST_VLD];
assign mult_create0_data[MD_SRC1_VLD]                        = is_mult_create0_data[IS_SRC1_VLD];
assign mult_create0_data[MD_SRC0_VLD]                        = is_mult_create0_data[IS_SRC0_VLD];
assign mult_create0_data[MD_IID:MD_IID-6]                    = is_mult_create0_iid[6:0];
assign mult_create0_data[MD_OPCODE:MD_OPCODE-31]             = is_mult_create0_data[IS_OPCODE:IS_OPCODE-31];

assign mult_create1_data[MD_SRC2_DATA:MD_SRC2_DATA-6]        = is_mult_create1_data[IS_SRC2_DATA:IS_SRC2_DATA-6];
assign mult_create1_data[MD_SRC1_DATA:MD_SRC1_DATA-6]        = is_mult_create1_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign mult_create1_data[MD_SRC0_DATA:MD_SRC0_DATA-6]        = is_mult_create1_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign mult_create1_data[MD_DST_VLD]                         = is_mult_create1_data[IS_DST_VLD];
assign mult_create1_data[MD_SRC1_VLD]                        = is_mult_create1_data[IS_SRC1_VLD];
assign mult_create1_data[MD_SRC0_VLD]                        = is_mult_create1_data[IS_SRC0_VLD];
assign mult_create1_data[MD_IID:MD_IID-6]                    = is_mult_create1_iid[6:0];
assign mult_create1_data[MD_OPCODE:MD_OPCODE-31]             = is_mult_create1_data[IS_OPCODE:IS_OPCODE-31];

//----------------------------------------------------------
//                  Create Data for DIV
//----------------------------------------------------------
logic [IS_WIDTH-1:0] is_div_create0_data;
logic [6:0]          is_div_create0_iid;
logic [IS_WIDTH-1:0] is_div_create1_data;
logic [6:0]          is_div_create1_iid;

// &CombBeg; @2720
always @(*)
begin
  case(ctrl_dp_is_dis_div_create0_sel[1:0])
    2'd0: begin
          is_div_create0_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_div_create0_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_div_create0_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_div_create0_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_div_create0_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_div_create0_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_div_create0_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_div_create0_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @2773
end

// &CombBeg; @2775
always @(*)
begin
  case(ctrl_dp_is_dis_div_create1_sel[1:0])
    2'd0: begin
          is_div_create1_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_div_create1_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_div_create1_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_div_create1_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_div_create1_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_div_create1_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_div_create1_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_div_create1_iid[6:0]           = {7{1'bx}};
          end
  endcase
// &CombEnd; @2828
end

//----------------------------------------------------------
//                Reorganize for DIV create
//----------------------------------------------------------
logic [MD_WIDTH-1:0] div_create0_data;
logic [MD_WIDTH-1:0] div_create1_data;

assign dp_div_create0_data[MD_WIDTH-1:0] = div_create0_data[MD_WIDTH-1:0];
assign dp_div_create1_data[MD_WIDTH-1:0] = div_create1_data[MD_WIDTH-1:0];

assign div_create0_data[MD_SRC2_DATA:MD_SRC2_DATA-6]        = is_div_create0_data[IS_SRC2_DATA:IS_SRC2_DATA-6];
assign div_create0_data[MD_SRC1_DATA:MD_SRC1_DATA-6]        = is_div_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign div_create0_data[MD_SRC0_DATA:MD_SRC0_DATA-6]        = is_div_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign div_create0_data[MD_DST_VLD]                         = is_div_create0_data[IS_DST_VLD];
assign div_create0_data[MD_SRC1_VLD]                        = is_div_create0_data[IS_SRC1_VLD];
assign div_create0_data[MD_SRC0_VLD]                        = is_div_create0_data[IS_SRC0_VLD];
assign div_create0_data[MD_IID:MD_IID-6]                    = is_div_create0_iid[6:0];
assign div_create0_data[MD_OPCODE:MD_OPCODE-31]             = is_div_create0_data[IS_OPCODE:IS_OPCODE-31];

assign div_create1_data[MD_SRC2_DATA:MD_SRC2_DATA-6]        = is_div_create1_data[IS_SRC2_DATA:IS_SRC2_DATA-6];
assign div_create1_data[MD_SRC1_DATA:MD_SRC1_DATA-6]        = is_div_create1_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign div_create1_data[MD_SRC0_DATA:MD_SRC0_DATA-6]        = is_div_create1_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign div_create1_data[MD_DST_VLD]                         = is_div_create1_data[IS_DST_VLD];
assign div_create1_data[MD_SRC1_VLD]                        = is_div_create1_data[IS_SRC1_VLD];
assign div_create1_data[MD_SRC0_VLD]                        = is_div_create1_data[IS_SRC0_VLD];
assign div_create1_data[MD_IID:MD_IID-6]                    = is_div_create1_iid[6:0];
assign div_create1_data[MD_OPCODE:MD_OPCODE-31]             = is_div_create1_data[IS_OPCODE:IS_OPCODE-31];

// &ModuleEnd; @4124
endmodule