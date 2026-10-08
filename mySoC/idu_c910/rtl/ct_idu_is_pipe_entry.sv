module ct_idu_is_pipe_entry (
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic [6:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [6:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [6:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  // ⚠️ 原为 rtu_idu_flush_fe / rtu_idu_flush_is 两个口, 归一成 rtu_yy_xx_flush。
  //    理由: 本设计**只有一个**冲刷信号 (rtu_yy_xx_flush, 顶层端口表里没有 fe/is),
  //    而两处例化点 (ct_idu_is_dp -> is_pipe_entry, ct_idu_is_sdiq -> is_sdiq_entry)
  //    传的本来就是 rtu_yy_xx_flush —— 名字对不上, 整个 IDU elaborate 不过。
  //    子模块 ct_idu_dep_reg_entry 也只有 rtu_yy_xx_flush 一个口。
  //    前端/发射级分开冲刷 (C910 有) 是 Phase 3/4 的事, 届时再拆。
  input  logic         rtu_yy_xx_flush,
  input  logic [82:0]  x_create_data,
  input  logic [64:0]  x_create_pc,
  input  logic [24:0]  x_create_chk,
  input  logic         x_create_dp_en,
  output logic [82:0]  x_read_data,
  output logic [64:0]  x_read_pc,
  output logic [24:0]  x_read_chk
);

//==========================================================
//                 IR/IS pipeline select
//==========================================================
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

//==========================================================
//                   Internal Signals
//==========================================================
logic [4:0]   entry_dst_reg;
logic [6:0]   entry_dst_preg;
logic [6:0]   entry_dst_rel_preg;
logic [31:0]  entry_opcode;
logic [64:0]  entry_pc;
logic         entry_src0_vld;
logic         entry_src1_vld;
logic         entry_dst_vld;
logic         entry_alu;
logic         entry_load;
logic         entry_store;
logic         entry_staddr;
logic         entry_bju;
logic         entry_mult;
logic         entry_div;
logic         entry_lsu;
logic         entry_alu_short;

logic [6:0]   x_create_src0_data;
logic [6:0]   x_create_src1_data;
logic [6:0]   x_create_src2_data;
logic [6:0]   x_read_src0_data;
logic [6:0]   x_read_src1_data;
logic [6:0]   x_read_src2_data;
logic entry_illegal;

//==========================================================
//                 Instruction Information
//==========================================================
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    entry_dst_reg[4:0]       <= 5'b0;
    entry_dst_preg[6:0]      <= 7'b0;
    entry_dst_rel_preg[6:0]  <= 7'b0;
  end
  else if(x_create_dp_en) begin
    entry_dst_reg[4:0]       <= x_create_data[IS_DST_REG:IS_DST_REG-4];
    // ⚠️ 2026-10-09 修: 原来写的是 -6 (7 位), 而**打包侧** (ct_idu_ir_dp.sv:507-516)
    //    与**消费侧** (ct_idu_is_dp.sv:601/686) 用的都是 **-5 (6 位)** ⇒
    //    这里多读的那一位 `x_create_data[60]` 其实是**邻居 dst_reg 的 MSB**,
    //    落进 `entry_dst_preg[6]`。当前没有消费者读那一位, 所以不发病 ——
    //    但它是个「看着是 7 位、其实第 7 位是别人的」的陷阱, 一并改对。
    entry_dst_preg[5:0]      <= x_create_data[IS_DST_PREG:IS_DST_PREG-5];
    entry_dst_rel_preg[5:0]  <= x_create_data[IS_DST_REL_PREG:IS_DST_REL_PREG-5];  // 同上: -6 → -5
  end
  else begin
    entry_dst_reg[4:0]       <= entry_dst_reg[4:0];
    entry_dst_preg[6:0]      <= entry_dst_preg[6:0];
    entry_dst_rel_preg[6:0]  <= entry_dst_rel_preg[6:0];
  end
end
logic [24:0] entry_chk;
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    entry_pc[64:0]       <= 65'b0;
    entry_chk[24:0]      <= 25'b0;
  end
  else if(x_create_dp_en) begin
    entry_pc[64:0]       <= x_create_pc[64:0];
    entry_chk[24:0]      <= x_create_chk[24:0];
  end
  else begin
    entry_pc[64:0]       <= entry_pc[64:0];
    entry_chk[24:0]      <= entry_chk[24:0];
  end
end
assign x_read_pc[64:0] = entry_pc[64:0];
assign x_read_chk[24:0]=entry_chk[24:0];
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    entry_opcode[31:0]       <= 32'b0;
    entry_src0_vld           <= 1'b0;
    entry_src1_vld           <= 1'b0;
    entry_dst_vld            <= 1'b0;
    entry_alu                <= 1'b0;
    entry_load               <= 1'b0;
    entry_store              <= 1'b0;
    entry_staddr             <= 1'b0;
    entry_bju                <= 1'b0;
    entry_mult               <= 1'b0;
    entry_div                <= 1'b0;
    entry_lsu                <= 1'b0;
    entry_alu_short          <= 1'b0;
    entry_illegal            <= 1'b0;
  end
  else if(x_create_dp_en) begin
    entry_opcode[31:0]       <= x_create_data[IS_OPCODE:IS_OPCODE-31];
    entry_src0_vld           <= x_create_data[IS_SRC0_VLD];
    entry_src1_vld           <= x_create_data[IS_SRC1_VLD];
    entry_dst_vld            <= x_create_data[IS_DST_VLD];
    entry_alu                <= x_create_data[IS_ALU];
    entry_load               <= x_create_data[IS_LOAD];
    entry_store              <= x_create_data[IS_STORE];
    entry_staddr             <= x_create_data[IS_STADDR];
    entry_bju                <= x_create_data[IS_BJU];
    entry_mult               <= x_create_data[IS_MULT];
    entry_div                <= x_create_data[IS_DIV];
    entry_lsu                <= x_create_data[IS_LSU];
    entry_alu_short          <= x_create_data[IS_ALU_SHORT];
    entry_illegal            <= x_create_data[IS_ILLEGAL];
  end
  else begin
    entry_opcode[31:0]       <= entry_opcode[31:0];
    entry_src0_vld           <= entry_src0_vld;
    entry_src1_vld           <= entry_src1_vld;
    entry_dst_vld            <= entry_dst_vld;
    entry_alu                <= entry_alu;
    entry_load               <= entry_load;
    entry_store              <= entry_store;
    entry_staddr             <= entry_staddr;
    entry_bju                <= entry_bju;
    entry_mult               <= entry_mult;
    entry_div                <= entry_div;
    entry_lsu                <= entry_lsu;
    entry_alu_short          <= entry_alu_short;
    entry_illegal            <= entry_illegal;
  end
end

//rename for read output
assign x_read_data[IS_OPCODE:IS_OPCODE-31] = entry_opcode[31:0];
assign x_read_data[IS_SRC0_VLD]            = entry_src0_vld;
assign x_read_data[IS_SRC1_VLD]            = entry_src1_vld;
assign x_read_data[IS_DST_VLD]             = entry_dst_vld;
assign x_read_data[IS_ALU]                 = entry_alu;
assign x_read_data[IS_LOAD]                = entry_load;
assign x_read_data[IS_STORE]               = entry_store;
assign x_read_data[IS_STADDR]              = entry_staddr;
assign x_read_data[IS_BJU]                 = entry_bju;
assign x_read_data[IS_MULT]                = entry_mult;
assign x_read_data[IS_DIV]                 = entry_div;
assign x_read_data[IS_LSU]                 = entry_lsu;
assign x_read_data[IS_ALU_SHORT]           = entry_alu_short;
assign x_read_data[IS_ILLEGAL]             = entry_illegal;
//==========================================================
//              Source Dependency Information
//==========================================================
assign x_create_src0_data[6:0] = x_create_data[IS_SRC0_DATA:IS_SRC0_DATA-6];
assign x_create_src1_data[6:0] = x_create_data[IS_SRC1_DATA:IS_SRC1_DATA-6];
assign x_create_src2_data[6:0] = x_create_data[IS_SRC2_DATA:IS_SRC2_DATA-6];

assign x_read_data[IS_SRC2_DATA:IS_SRC2_DATA-6] = x_read_src2_data[6:0];
assign x_read_data[IS_SRC1_DATA:IS_SRC1_DATA-6] = x_read_src1_data[6:0];
assign x_read_data[IS_SRC0_DATA:IS_SRC0_DATA-6] = x_read_src0_data[6:0];
// ⚠️ 2026-10-09 补: 上面那批读出口 assign **漏了三个字段** ——
//    `entry_dst_rel_preg` / `entry_dst_preg` / `entry_dst_reg` 都在 :88-98 被锁存了,
//    却**没有一个接进 x_read_data** ⇒ 这三段是真·无驱动 ⇒ 读出恒 X。
//    后果不是「少个观察量」: `is_aiq/biq/lsiq/sdiq_create*_data` **全部**等于
//    `is_inst{k}_read_data` (见 ct_idu_is_dp.sv:429/457/532/601/686 …), 而
//      * `biq_create*_data[BIQ_DST_PREG]  ← IS_DST_PREG` ⇒ **JAL/JALR 的 rd 是 X**;
//      * `lsiq_create*_data[LSIQ_DST_PREG] ← IS_DST_PREG` ⇒ **load 的目标 preg 是 X**
//        (它一路传到 `idu_lsu_ld_preg`, LSU 按它写回 PRF);
//      * `IS_DST_REL_PREG` = 旧映射, RTU 退休释放编号要用。
//    本仓第五次栽「漏接 = 静默 X」这一类。
assign x_read_data[IS_DST_REG:IS_DST_REG-4]           = entry_dst_reg[4:0];   // [60:56] 5 位
assign x_read_data[IS_DST_PREG:IS_DST_PREG-5]         = entry_dst_preg[5:0];   // [66:61] **6 位**
assign x_read_data[IS_DST_REL_PREG:IS_DST_REL_PREG-5] = entry_dst_rel_preg[5:0]; // [72:67] **6 位**

//------------------------source 0--------------------------
ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src0 (
  .cpurst_b                          (cpurst_b),
  .forever_cpuclk                    (forever_cpuclk),
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush                   ),
  .x_create_data                     (x_create_src0_data[6:0]),
  .x_write_en                        (x_create_dp_en),
  .x_read_data                       (x_read_src0_data[6:0])
);

//------------------------source 1--------------------------
ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src1 (
  .cpurst_b                          (cpurst_b),
  .forever_cpuclk                    (forever_cpuclk),
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush                   ),
  .x_create_data                     (x_create_src1_data[6:0]),
  .x_write_en                        (x_create_dp_en),
  .x_read_data                       (x_read_src1_data[6:0])
);

//------------------------source 2--------------------------
ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src2 (
  .cpurst_b                          (cpurst_b),
  .forever_cpuclk                    (forever_cpuclk),
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush                   ),
  .x_create_data                     (x_create_src2_data[6:0]),
  .x_write_en                        (x_create_dp_en),
  .x_read_data                       (x_read_src2_data[6:0])
);

endmodule