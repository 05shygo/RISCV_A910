module ct_idu_is_dp (
  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         forever_clk,
  input  logic         cpurst_b,

  // IR data

  input  logic [78:0] dp_ir_inst0_data,

  input  logic [64:0] dp_ir_inst0_pc,
  input  logic [24:0] dp_ir_inst0_chk,
  input  logic [78:0] dp_ir_inst1_data,
  input  logic [64:0] dp_ir_inst1_pc,
  input  logic [24:0] dp_ir_inst1_chk,

  input  logic [78:0] dp_ir_inst2_data,

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
  input  logic [5:0]   iu_idu_ex2_pipe2_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe2_wb_preg_vld_dupx,

  // Writeback from LSU
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,

  // 第 5 路唤醒: RVV vset 写回 (S3)
  input  logic [5:0]   rvv_idu_vset_wb_preg_dupx,
  input  logic         rvv_idu_vset_wb_preg_vld_dupx,

  // Control signals
  input  logic         ctrl_ir_pipedown_inst0_vld,
  input  logic         ctrl_ir_pipedown_inst1_vld,
  input  logic         ctrl_ir_pipedown_inst2_vld,
  input  logic         ctrl_dp_is_dis_stall,
  input  logic         ctrl_ir_pipedown,
  input  logic [1:0]   ctrl_xx_is_inst0_sel,


  input  logic [3:0]   sdiq_create0_entry,
  input  logic [3:0]   sdiq_create1_entry,

  // 2026-10-18 直连向量 L/S: 本拍 LSIQ create0/1 实际落到的空闲槽 (one-hot)。
  // 与下面的 is_lsiq_create0/1_iid 配对, 把 lsid 打进 VIQ 表项。
  input  logic [7:0]   lsiq_create0_entry,
  input  logic [7:0]   lsiq_create1_entry,

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
  // VIQ create0/create1 的源车道选择 (S1 新增; S2 接到 ct_idu_vecq)
  input  logic [1:0]   ctrl_dp_is_dis_vec_create0_sel,
  input  logic [1:0]   ctrl_dp_is_dis_vec_create1_sel,

  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic [8:0]   dp_ctrl_is_dis_inst2_ctrl_info,
  output logic [94:0]  dp_aiq_create0_data,
  output logic [94:0]  dp_aiq_create1_data,
  output logic [151:0] dp_biq_create0_data,
  output logic [151:0] dp_biq_create1_data,
  output logic         dp_ctrl_is_inst0_dst_vld,
  output logic         dp_ctrl_is_inst1_dst_vld,
  output logic         dp_ctrl_is_inst2_dst_vld,
  output logic [60:0]  dp_lsiq_create0_data,
  output logic [60:0]  dp_lsiq_create1_data,
  // 2026-10-17 S8: fill 引擎要按 anchor 记 iid
  output logic [6:0]   dp_lsiq_create0_iid,
  output logic [6:0]   dp_lsiq_create1_iid,
  output logic [7:0]   dp_sdiq_create0_data,
  output logic [7:0]   dp_sdiq_create1_data,
  output logic [61:0]  dp_mult_create0_data,
  output logic [61:0]  dp_mult_create1_data,
  output logic [61:0]  dp_div_create0_data,
  output logic [61:0]  dp_div_create1_data,

  // 向量队列 (VIQ) 建表数据 (S1 新增; S2 接到 ct_idu_vecq)
  // 2026-10-18: 101→104, 新增 [103:101] = lsid
  output logic [103:0] dp_vec_create0_data,
  output logic [103:0] dp_vec_create1_data,
  output logic [6:0]   dp_vec_create0_iid,
  output logic [6:0]   dp_vec_create1_iid,
  output logic         dp_ctrl_is_inst0_vec,
  output logic         dp_ctrl_is_inst1_vec,
  output logic         dp_ctrl_is_inst2_vec,

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
  output logic [78:0]  dp_is_dis_inst0_data,
  output logic [78:0]  dp_is_dis_inst1_data,
  output logic [78:0]  dp_is_dis_inst2_data,
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

parameter IS_WIDTH             = 79;
parameter IS_VEC_TYPE          = 78;   // [78:77]
parameter IS_VEC               = 76;
parameter IS_ILLEGAL           = 75;
parameter IS_ALU_SHORT         = 74;
parameter IS_LSU               = 73;
parameter IS_DIV               = 72;
parameter IS_MULT              = 71;
parameter IS_BJU               = 70;
parameter IS_STADDR            = 69;
parameter IS_STORE             = 68;
parameter IS_LOAD              = 67;
parameter IS_ALU               = 66;
parameter IS_DST_REL_PREG      = 65;
parameter IS_DST_PREG          = 59;
parameter IS_DST_REG           = 53;

//parameter IS_SRC2_DATA         = 55;
parameter IS_SRC1_DATA         = 48;
parameter IS_SRC0_DATA         = 41;
parameter IS_DST_VLD           = 34;
parameter IS_SRC1_VLD          = 33;
parameter IS_SRC0_VLD          = 32;
parameter IS_OPCODE            = 31;

//----------------------------------------------------------
//                    AIQ Parameters
//----------------------------------------------------------
parameter AIQ_WIDTH             = 95;   // 2026-10-08: 64 → 96 (高 32 位给 PC)
parameter AIQ_PC                = 94;   // 2026-10-08 新增: AUIPC 的 PC (高 32 位, 其余字段不动)
parameter AIQ_ILLEGAL           = 62; // 修正：补上分号
parameter AIQ_IID               = 61;
parameter AIQ_PREG              = 54;
parameter AIQ_SRC1_DATA         = 48;
parameter AIQ_SRC0_DATA         = 41;
parameter AIQ_DST_VLD           = 34;
parameter AIQ_SRC1_VLD          = 33;
parameter AIQ_SRC0_VLD          = 32;
parameter AIQ_OPCODE            = 31;

parameter MD_WIDTH              = 62;
parameter MD_IID                = 61;
parameter MD_PREG               = 54;
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
parameter LSIQ_WIDTH             = 61;      // S7: 60→61
parameter LSIQ_VEC               = 60;      // S7: anchor 标记
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
/*
assign is_inst0_create_dp_en      = ctrl_dp_is_inst0_vld && !ctrl_dp_is_dis_stall;
assign is_inst1_create_dp_en      = ctrl_dp_is_inst1_vld && !ctrl_dp_is_dis_stall;
assign is_inst2_create_dp_en      = ctrl_dp_is_inst2_vld && !ctrl_dp_is_dis_stall;
assign is_inst_create_dp_en       = ctrl_ir_pipedown && !ctrl_dp_is_dis_stall;
*/
assign is_inst0_create_dp_en      = ctrl_ir_pipedown_inst0_vld && !ctrl_dp_is_dis_stall;
assign is_inst1_create_dp_en      = ctrl_ir_pipedown_inst1_vld && !ctrl_dp_is_dis_stall;
assign is_inst2_create_dp_en      = ctrl_ir_pipedown_inst2_vld && !ctrl_dp_is_dis_stall;
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

// 向量车道信息 (S1 新增) —— 从 pipe_entry 读口取 (已锁存)
logic                is_inst0_vec;
logic [1:0]          is_inst0_vec_type;
logic                is_inst1_vec;
logic [1:0]          is_inst1_vec_type;
logic                is_inst2_vec;
logic [1:0]          is_inst2_vec_type;

// VIQ create0/create1 三选一后的原始数据 (S1 新增)
logic [IS_WIDTH-1:0] is_vec_create0_data;
logic [64:0]         is_vec_create0_pc;
logic [6:0]          is_vec_create0_iid;
logic [IS_WIDTH-1:0] is_vec_create1_data;
logic [64:0]         is_vec_create1_pc;
logic [6:0]          is_vec_create1_iid;

// 【补齐】以下 6 个信号在原代码中使用但未声明
logic [64:0] is_inst0_create_pc;
logic [64:0] is_inst1_create_pc;
logic [64:0] is_inst2_create_pc;
logic [64:0] is_inst0_read_pc;
logic [64:0] is_inst1_read_pc;
logic [64:0] is_inst2_read_pc;

logic [24:0] is_inst0_create_chk;
logic [24:0] is_inst1_create_chk;
logic [24:0] is_inst2_create_chk;
logic [24:0] is_inst0_read_chk;
logic [24:0] is_inst1_read_chk;
logic [24:0] is_inst2_read_chk;
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
assign dp_is_dis_inst0_data[78:0] = is_inst0_read_data[78:0];
assign dp_is_dis_inst1_data[78:0] = is_inst1_read_data[78:0];
assign dp_is_dis_inst2_data[78:0] = is_inst2_read_data[78:0];
assign dp_is_dis_inst0_pc[31:0]   = is_inst0_read_pc[31:0];
assign dp_is_dis_inst1_pc[31:0]   = is_inst1_read_pc[31:0];
assign dp_is_dis_inst2_pc[31:0]   = is_inst2_read_pc[31:0];
// 向量指令没有分支预测快照: chk 必须清零 (否则 RTU 会拿垃圾预测去训练)
assign dp_is_dis_inst0_chk[24:0]  = is_inst0_vec ? 25'd0 : is_inst0_read_chk[24:0];
assign dp_is_dis_inst1_chk[24:0]  = is_inst1_vec ? 25'd0 : is_inst1_read_chk[24:0];
assign dp_is_dis_inst2_chk[24:0]  = is_inst2_vec ? 25'd0 : is_inst2_read_chk[24:0];

parameter IS_CTRL_WIDTH       = 9;
parameter IS_CTRL_VMEM        = 8;
parameter IS_CTRL_VEC         = 7;
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
// 向量控制位 (S1 新增)
assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_VEC]     = is_inst2_read_data[IS_VEC];
assign dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_VMEM]    =
       is_inst2_read_data[IS_VEC] &&
       (is_inst2_read_data[IS_VEC_TYPE:IS_VEC_TYPE-1] == 2'b01 ||
        is_inst2_read_data[IS_VEC_TYPE:IS_VEC_TYPE-1] == 2'b10);

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
  .iu_idu_ex2_pipe2_wb_preg_dupx     (iu_idu_ex2_pipe2_wb_preg_dupx),
  .iu_idu_ex2_pipe2_wb_preg_vld_dupx (iu_idu_ex2_pipe2_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rvv_idu_vset_wb_preg_dupx         (rvv_idu_vset_wb_preg_dupx         ),
  .rvv_idu_vset_wb_preg_vld_dupx     (rvv_idu_vset_wb_preg_vld_dupx     ),
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
  .iu_idu_ex2_pipe2_wb_preg_dupx     (iu_idu_ex2_pipe2_wb_preg_dupx),
  .iu_idu_ex2_pipe2_wb_preg_vld_dupx (iu_idu_ex2_pipe2_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rvv_idu_vset_wb_preg_dupx         (rvv_idu_vset_wb_preg_dupx         ),
  .rvv_idu_vset_wb_preg_vld_dupx     (rvv_idu_vset_wb_preg_vld_dupx     ),
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
  .iu_idu_ex2_pipe2_wb_preg_dupx     (iu_idu_ex2_pipe2_wb_preg_dupx),
  .iu_idu_ex2_pipe2_wb_preg_vld_dupx (iu_idu_ex2_pipe2_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rvv_idu_vset_wb_preg_dupx         (rvv_idu_vset_wb_preg_dupx         ),
  .rvv_idu_vset_wb_preg_vld_dupx     (rvv_idu_vset_wb_preg_vld_dupx     ),
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

//----------------------------------------------------------
//                       Assign VEC (S1 新增)
//----------------------------------------------------------
assign is_inst0_vec      = is_inst0_read_data[IS_VEC];
assign is_inst0_vec_type = is_inst0_read_data[IS_VEC_TYPE:IS_VEC_TYPE-1];
assign is_inst1_vec      = is_inst1_read_data[IS_VEC];
assign is_inst1_vec_type = is_inst1_read_data[IS_VEC_TYPE:IS_VEC_TYPE-1];
assign is_inst2_vec      = is_inst2_read_data[IS_VEC];
assign is_inst2_vec_type = is_inst2_read_data[IS_VEC_TYPE:IS_VEC_TYPE-1];

assign dp_ctrl_is_inst0_vec = is_inst0_vec;
assign dp_ctrl_is_inst1_vec = is_inst1_vec;
assign dp_ctrl_is_inst2_vec = is_inst2_vec;

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
logic [31:0]         is_aiq_create0_pc;    // 2026-10-08: AIQ 表项的 PC
logic [31:0]         is_aiq_create1_pc;
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
          is_aiq_create0_pc[31:0]           = is_inst0_read_pc[31:0];   // 2026-10-08
          is_aiq_create0_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_aiq_create0_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_aiq_create0_pc[31:0]           = is_inst1_read_pc[31:0];   // 2026-10-08
          is_aiq_create0_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_aiq_create0_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_aiq_create0_pc[31:0]           = is_inst2_read_pc[31:0];   // 2026-10-08
          is_aiq_create0_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_aiq_create0_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_aiq_create0_pc[31:0]           = {32{1'bx}};   // 2026-10-08
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
          is_aiq_create1_pc[31:0]           = is_inst0_read_pc[31:0];   // 2026-10-08
          is_aiq_create1_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_aiq_create1_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_aiq_create1_pc[31:0]           = is_inst1_read_pc[31:0];   // 2026-10-08
          is_aiq_create1_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_aiq_create1_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_aiq_create1_pc[31:0]           = is_inst2_read_pc[31:0];   // 2026-10-08
          is_aiq_create1_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_aiq_create1_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_aiq_create1_pc[31:0]           = {32{1'bx}};   // 2026-10-08
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

// 2026-10-08: PC 放在高 32 位 (AIQ_PC=95), 原有字段位置一位不动
assign aiq_create0_data[AIQ_PC:AIQ_PC-31]                     = is_aiq_create0_pc[31:0];
assign aiq_create1_data[AIQ_PC:AIQ_PC-31]                     = is_aiq_create1_pc[31:0];

assign dp_aiq_create0_data[AIQ_WIDTH-1:0] = aiq_create0_data[AIQ_WIDTH-1:0];
assign dp_aiq_create1_data[AIQ_WIDTH-1:0] = aiq_create1_data[AIQ_WIDTH-1:0];

assign aiq_create0_data[AIQ_ILLEGAL]                          = is_aiq_create0_data[IS_ILLEGAL];
assign aiq_create0_data[AIQ_PREG:AIQ_PREG-5]                  = is_aiq_create0_data[IS_DST_PREG:IS_DST_PREG-5];
assign aiq_create0_data[AIQ_SRC1_DATA:AIQ_SRC1_DATA-6]        = is_aiq_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign aiq_create0_data[AIQ_SRC0_DATA:AIQ_SRC0_DATA-6]        = is_aiq_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign aiq_create0_data[AIQ_DST_VLD]                          = is_aiq_create0_data[IS_DST_VLD];
assign aiq_create0_data[AIQ_SRC1_VLD]                         = is_aiq_create0_data[IS_SRC1_VLD];
assign aiq_create0_data[AIQ_SRC0_VLD]                         = is_aiq_create0_data[IS_SRC0_VLD];
assign aiq_create0_data[AIQ_IID:AIQ_IID-6]                    = is_aiq_create0_iid[6:0];
assign aiq_create0_data[AIQ_OPCODE:AIQ_OPCODE-31]             = is_aiq_create0_data[IS_OPCODE:IS_OPCODE-31];

assign aiq_create1_data[AIQ_ILLEGAL]                          = is_aiq_create1_data[IS_ILLEGAL]; // 修正：源信号由 create0 改为 create1
assign aiq_create1_data[AIQ_PREG:AIQ_PREG-5]                  = is_aiq_create1_data[IS_DST_PREG:IS_DST_PREG-5];
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
assign dp_lsiq_create0_iid[6:0]                             = is_lsiq_create0_iid[6:0];
assign dp_lsiq_create1_iid[6:0]                             = is_lsiq_create1_iid[6:0];

// ⚠️ 2026-10-14 修复 (coremark_i1 卡死的真凶): 原版 ct_idu_is_dp.v:5459-5473 这里是一次
//    **重映射** —— SDIQ 的 create0/create1 是按"这拍窗口里第几条 store"分配的, 而 LSIQ 的
//    create0/create1 是按"第几条 LSU 指令(load 或 store)"分配的, **两者不是一回事**。
//    原版口径:
//      slot0: 是 load ⇒ 用 VMB 表项(本仓 RV32I 无 vector ⇒ 0); 是 store ⇒ 用 SDIQ create0
//      slot1: 是 load ⇒ 0; 是 store ⇒ 看 **slot0 是不是 store**:
//                 是   ⇒ 用 SDIQ create1 (第 2 条 store)
//                 不是 ⇒ 用 SDIQ create0 (它其实是窗口里**第 1 条** store)
//    本仓原来硬绑成"slot0←create0, slot1←create1" ⇒ 窗口是 **[load, store]** 时,
//    slot1 那条 store 拿到的是 create1 = 0 ⇒ LSIQ 表项的 `sdiq_entry` 记成 0 ⇒ 传到
//    SQ 表项就是 `sq_entry_sdid=0` ⇒ 那笔 store 的 store data 永远认领不上
//    (`sq_entry_data_set` 要求 `sq_entry_sdid == 广播的 sdid`) ⇒ `data_vld` 永远 0
//    ⇒ `sq_entry_pop_req` 永远 0 ⇒ **SQ 排不空** ⇒ ROB 队头 store 永不退休 ⇒ 整个核死锁。
//    实测: coremark_i1 有 6 次这样的建表 (T404/T453/T572/T2262/T2450/T2558),
//    每次都是 `lsiq_c0=1 lsiq_c1=1 sdiq_c0=1 sdiq_c1=0` 且 c1 的 sdiq 字段 = 0。
// 2026-10-17 S7: 向量 LOAD/STORE 的 anchor. 合成 opcode/地址/preg/sdiq 都由
// S8 fill 引擎的 beat update 填, create 时只给占位值 + 固定源编码 7'b0000001。
wire        is_lsiq_create0_vec      = is_lsiq_create0_data[IS_VEC];
wire [1:0]  is_lsiq_create0_vec_type = is_lsiq_create0_data[IS_VEC_TYPE:IS_VEC_TYPE-1];

assign lsiq_create0_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3] =
       (is_lsiq_create0_vec || is_lsiq_create0_data[IS_LOAD]) ? 4'b0
                                                              : ctrl_is_sdiq_create0_entry[3:0];
assign lsiq_create0_data[LSIQ_VEC]                           = is_lsiq_create0_vec;
assign lsiq_create0_data[LSIQ_STORE]                         =
       is_lsiq_create0_data[IS_STORE] ||
       (is_lsiq_create0_vec && (is_lsiq_create0_vec_type == 2'b10));
assign lsiq_create0_data[LSIQ_LOAD]                          =
       is_lsiq_create0_data[IS_LOAD]  ||
       (is_lsiq_create0_vec && (is_lsiq_create0_vec_type == 2'b01));
assign lsiq_create0_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-6]    =
       is_lsiq_create0_vec ? 7'b0000001
                           : is_lsiq_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign lsiq_create0_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5]      =
       is_lsiq_create0_vec ? 6'b0 : is_lsiq_create0_data[IS_DST_PREG:IS_DST_PREG-5];
assign lsiq_create0_data[LSIQ_DST_VLD]                       =
       is_lsiq_create0_vec ? 1'b0 : is_lsiq_create0_data[IS_DST_VLD];
assign lsiq_create0_data[LSIQ_SRC0_VLD]                      =
       is_lsiq_create0_vec ? 1'b1 : is_lsiq_create0_data[IS_SRC0_VLD];
assign lsiq_create0_data[LSIQ_IID:LSIQ_IID-6]                = is_lsiq_create0_iid[6:0];
assign lsiq_create0_data[LSIQ_OPCODE:LSIQ_OPCODE-31]         =
       is_lsiq_create0_vec ? 32'b0 : is_lsiq_create0_data[IS_OPCODE:IS_OPCODE-31];

// ⚠️ 2026-10-14 修复 (同上): slot1 的 sdiq_entry 要按"窗口里第几条 store"选 SDIQ 的
//    create0/create1, 不能硬绑 create1。原版 ct_idu_is_dp.v:5470-5473。
//    ⚠️⚠️ 2026-10-14 二次修: 上面那段注释写对了口径, 但**这一行漏了 slot0 是不是 store 的
//    判断** (硬绑 create1) ⇒ 窗口是 [load, store] 时 slot1 那条 store 仍然拿 create1=0
//    ⇒ 1694 条卡死照旧。必须按原版补 `is_lsiq_create0_data[IS_STADDR]` 这个条件。
wire        is_lsiq_create1_vec      = is_lsiq_create1_data[IS_VEC];
wire [1:0]  is_lsiq_create1_vec_type = is_lsiq_create1_data[IS_VEC_TYPE:IS_VEC_TYPE-1];

assign lsiq_create1_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3] =
       (is_lsiq_create1_vec || is_lsiq_create1_data[IS_LOAD]) ? 4'b0
     : ( is_lsiq_create0_data[IS_STADDR] ? ctrl_is_sdiq_create1_entry[3:0]  // slot0 也是 store ⇒ 这是第 2 条
                                         : ctrl_is_sdiq_create0_entry[3:0] );// slot0 是 load ⇒ 这是第 1 条
assign lsiq_create1_data[LSIQ_VEC]                           = is_lsiq_create1_vec;
assign lsiq_create1_data[LSIQ_STORE]                         =
       is_lsiq_create1_data[IS_STORE] ||
       (is_lsiq_create1_vec && (is_lsiq_create1_vec_type == 2'b10));
assign lsiq_create1_data[LSIQ_LOAD]                          =
       is_lsiq_create1_data[IS_LOAD]  ||
       (is_lsiq_create1_vec && (is_lsiq_create1_vec_type == 2'b01));
assign lsiq_create1_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-6]    =
       is_lsiq_create1_vec ? 7'b0000001
                           : is_lsiq_create1_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign lsiq_create1_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5]      =
       is_lsiq_create1_vec ? 6'b0 : is_lsiq_create1_data[IS_DST_PREG:IS_DST_PREG-5];
assign lsiq_create1_data[LSIQ_DST_VLD]                       =
       is_lsiq_create1_vec ? 1'b0 : is_lsiq_create1_data[IS_DST_VLD];
assign lsiq_create1_data[LSIQ_SRC0_VLD]                      =
       is_lsiq_create1_vec ? 1'b1 : is_lsiq_create1_data[IS_SRC0_VLD];
assign lsiq_create1_data[LSIQ_IID:LSIQ_IID-6]                = is_lsiq_create1_iid[6:0];
assign lsiq_create1_data[LSIQ_OPCODE:LSIQ_OPCODE-31]         =
       is_lsiq_create1_vec ? 32'b0 : is_lsiq_create1_data[IS_OPCODE:IS_OPCODE-31];

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
//                  Create Data for VIQ (S1 新增)
//----------------------------------------------------------
// 三选一 mux 与 AIQ 完全同构: 按 ctrl_dp_is_dis_vec_create{0,1}_sel 取车道。
always @(*)
begin
  case(ctrl_dp_is_dis_vec_create0_sel[1:0])
    2'd0: begin
          is_vec_create0_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_vec_create0_pc[64:0]           = is_inst0_read_pc[64:0];
          is_vec_create0_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_vec_create0_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_vec_create0_pc[64:0]           = is_inst1_read_pc[64:0];
          is_vec_create0_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_vec_create0_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_vec_create0_pc[64:0]           = is_inst2_read_pc[64:0];
          is_vec_create0_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_vec_create0_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_vec_create0_pc[64:0]           = {65{1'bx}};
          is_vec_create0_iid[6:0]           = {7{1'bx}};
          end
  endcase
end

always @(*)
begin
  case(ctrl_dp_is_dis_vec_create1_sel[1:0])
    2'd0: begin
          is_vec_create1_data[IS_WIDTH-1:0] = is_inst0_read_data[IS_WIDTH-1:0];
          is_vec_create1_pc[64:0]           = is_inst0_read_pc[64:0];
          is_vec_create1_iid[6:0]           = is_inst0_iid[6:0];
          end
    2'd1: begin
          is_vec_create1_data[IS_WIDTH-1:0] = is_inst1_read_data[IS_WIDTH-1:0];
          is_vec_create1_pc[64:0]           = is_inst1_read_pc[64:0];
          is_vec_create1_iid[6:0]           = is_inst1_iid[6:0];
          end
    2'd2: begin
          is_vec_create1_data[IS_WIDTH-1:0] = is_inst2_read_data[IS_WIDTH-1:0];
          is_vec_create1_pc[64:0]           = is_inst2_read_pc[64:0];
          is_vec_create1_iid[6:0]           = is_inst2_iid[6:0];
          end
    default: begin
          is_vec_create1_data[IS_WIDTH-1:0] = {IS_WIDTH{1'bx}};
          is_vec_create1_pc[64:0]           = {65{1'bx}};
          is_vec_create1_iid[6:0]           = {7{1'bx}};
          end
  endcase
end

// 2026-10-18 直连向量 L/S: 把 LSIQ create0/1 槽号按 iid 配给对应的 VIQ lane。
// IS 窗口内 iid 唯一; 向量 L/S lane 一定同时占一个 LSIQ create 口。
// 只有 vec_type=01(LOAD)/10(STORE) 才取 lsid, OP-V 固定 0。
function automatic logic [2:0] onehot8_to_idx (input logic [7:0] oh);
  onehot8_to_idx = 3'd0;
  for (int b = 0; b < 8; b++)
    if (oh[b]) onehot8_to_idx = b[2:0];
endfunction

wire is_vec_create0_ls =
     is_vec_create0_data[IS_VEC]
  && ((is_vec_create0_data[IS_VEC_TYPE:IS_VEC_TYPE-1] == 2'b01)
   || (is_vec_create0_data[IS_VEC_TYPE:IS_VEC_TYPE-1] == 2'b10));
wire is_vec_create1_ls =
     is_vec_create1_data[IS_VEC]
  && ((is_vec_create1_data[IS_VEC_TYPE:IS_VEC_TYPE-1] == 2'b01)
   || (is_vec_create1_data[IS_VEC_TYPE:IS_VEC_TYPE-1] == 2'b10));

wire [2:0] is_vec_create0_lsid =
     (!is_vec_create0_ls) ? 3'd0 :
     ((|lsiq_create0_entry) && (is_lsiq_create0_iid[6:0] == is_vec_create0_iid[6:0]))
        ? onehot8_to_idx(lsiq_create0_entry) :
     ((|lsiq_create1_entry) && (is_lsiq_create1_iid[6:0] == is_vec_create0_iid[6:0]))
        ? onehot8_to_idx(lsiq_create1_entry) : 3'd0;

wire [2:0] is_vec_create1_lsid =
     (!is_vec_create1_ls) ? 3'd0 :
     ((|lsiq_create0_entry) && (is_lsiq_create0_iid[6:0] == is_vec_create1_iid[6:0]))
        ? onehot8_to_idx(lsiq_create0_entry) :
     ((|lsiq_create1_entry) && (is_lsiq_create1_iid[6:0] == is_vec_create1_iid[6:0]))
        ? onehot8_to_idx(lsiq_create1_entry) : 3'd0;

// 104 位打包 —— 顺序必须与 VIQ (S2 的 ct_idu_vecq) 的字段定义逐位一致:
//   [103:101] lsid, [100:69] pc, [68:37] opcode, [36:30] iid, [29:28] vec_type,
//   [27:22] dst_preg, [21:17] dst_reg, [16] dst_vld,
//   [15:9] src1_data, [8:2] src0_data, [1] src1_vld, [0] src0_vld
assign dp_vec_create0_data[103:101] = is_vec_create0_lsid[2:0];
assign dp_vec_create1_data[103:101] = is_vec_create1_lsid[2:0];
assign dp_vec_create0_data[100:69] = is_vec_create0_pc[31:0];
assign dp_vec_create0_data[68:37]  = is_vec_create0_data[IS_OPCODE:IS_OPCODE-31];
assign dp_vec_create0_data[36:30]  = is_vec_create0_iid[6:0];
assign dp_vec_create0_data[29:28]  = is_vec_create0_data[IS_VEC_TYPE:IS_VEC_TYPE-1];
assign dp_vec_create0_data[27:22]  = is_vec_create0_data[IS_DST_PREG:IS_DST_PREG-5];
assign dp_vec_create0_data[21:17]  = is_vec_create0_data[IS_DST_REG:IS_DST_REG-4];
assign dp_vec_create0_data[16]     = is_vec_create0_data[IS_DST_VLD];
assign dp_vec_create0_data[15:9]   = is_vec_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign dp_vec_create0_data[8:2]    = is_vec_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign dp_vec_create0_data[1]      = is_vec_create0_data[IS_SRC1_VLD];
assign dp_vec_create0_data[0]      = is_vec_create0_data[IS_SRC0_VLD];
assign dp_vec_create0_iid[6:0]     = is_vec_create0_iid[6:0];

assign dp_vec_create1_data[100:69] = is_vec_create1_pc[31:0];
assign dp_vec_create1_data[68:37]  = is_vec_create1_data[IS_OPCODE:IS_OPCODE-31];
assign dp_vec_create1_data[36:30]  = is_vec_create1_iid[6:0];
assign dp_vec_create1_data[29:28]  = is_vec_create1_data[IS_VEC_TYPE:IS_VEC_TYPE-1];
assign dp_vec_create1_data[27:22]  = is_vec_create1_data[IS_DST_PREG:IS_DST_PREG-5];
assign dp_vec_create1_data[21:17]  = is_vec_create1_data[IS_DST_REG:IS_DST_REG-4];
assign dp_vec_create1_data[16]     = is_vec_create1_data[IS_DST_VLD];
assign dp_vec_create1_data[15:9]   = is_vec_create1_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign dp_vec_create1_data[8:2]    = is_vec_create1_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign dp_vec_create1_data[1]      = is_vec_create1_data[IS_SRC1_VLD];
assign dp_vec_create1_data[0]      = is_vec_create1_data[IS_SRC0_VLD];
assign dp_vec_create1_iid[6:0]     = is_vec_create1_iid[6:0];

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

assign mult_create0_data[MD_PREG:MD_PREG-5]                  = is_mult_create0_data[IS_DST_PREG:IS_DST_PREG-5];
assign mult_create0_data[MD_SRC1_DATA:MD_SRC1_DATA-6]        = is_mult_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign mult_create0_data[MD_SRC0_DATA:MD_SRC0_DATA-6]        = is_mult_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign mult_create0_data[MD_DST_VLD]                         = is_mult_create0_data[IS_DST_VLD];
assign mult_create0_data[MD_SRC1_VLD]                        = is_mult_create0_data[IS_SRC1_VLD];
assign mult_create0_data[MD_SRC0_VLD]                        = is_mult_create0_data[IS_SRC0_VLD];
assign mult_create0_data[MD_IID:MD_IID-6]                    = is_mult_create0_iid[6:0];
assign mult_create0_data[MD_OPCODE:MD_OPCODE-31]             = is_mult_create0_data[IS_OPCODE:IS_OPCODE-31];

assign mult_create1_data[MD_PREG:MD_PREG-5]                  = is_mult_create1_data[IS_DST_PREG:IS_DST_PREG-5];
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
 
assign div_create0_data[MD_PREG:MD_PREG-5]                  = is_div_create0_data[IS_DST_PREG:IS_DST_PREG-5];
assign div_create0_data[MD_SRC1_DATA:MD_SRC1_DATA-6]        = is_div_create0_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign div_create0_data[MD_SRC0_DATA:MD_SRC0_DATA-6]        = is_div_create0_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign div_create0_data[MD_DST_VLD]                         = is_div_create0_data[IS_DST_VLD];
assign div_create0_data[MD_SRC1_VLD]                        = is_div_create0_data[IS_SRC1_VLD];
assign div_create0_data[MD_SRC0_VLD]                        = is_div_create0_data[IS_SRC0_VLD];
assign div_create0_data[MD_IID:MD_IID-6]                    = is_div_create0_iid[6:0];
assign div_create0_data[MD_OPCODE:MD_OPCODE-31]             = is_div_create0_data[IS_OPCODE:IS_OPCODE-31];

assign div_create1_data[MD_PREG:MD_PREG-5]                  = is_div_create1_data[IS_DST_PREG:IS_DST_PREG-5];
assign div_create1_data[MD_SRC1_DATA:MD_SRC1_DATA-6]        = is_div_create1_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign div_create1_data[MD_SRC0_DATA:MD_SRC0_DATA-6]        = is_div_create1_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign div_create1_data[MD_DST_VLD]                         = is_div_create1_data[IS_DST_VLD];
assign div_create1_data[MD_SRC1_VLD]                        = is_div_create1_data[IS_SRC1_VLD];
assign div_create1_data[MD_SRC0_VLD]                        = is_div_create1_data[IS_SRC0_VLD];
assign div_create1_data[MD_IID:MD_IID-6]                    = is_div_create1_iid[6:0];
assign div_create1_data[MD_OPCODE:MD_OPCODE-31]             = is_div_create1_data[IS_OPCODE:IS_OPCODE-31];

// &ModuleEnd; @4124
endmodule