`include "ct_idu_vecq_defs.svh"

// =============================================================================
// ct_idu_vecq_entry.sv —— 向量队列 (VIQ) 表项 (S2)
//
// 一个表项 = 101 位指令数据 + 两个标量源依赖表项 (ct_idu_dep_reg_entry)。
//   * 本表项就是 A910 侧给 RVV core 的唯一指令缓冲；RvvFrontEnd 内部不再排队。
//   * srcX_vld=0 时把依赖表项的源编码强制成 {preg0, wb=1} ⇒ 立即 ready。
//   * 第 5 路唤醒 (rvv_idu_vset_wb_*) 的端口在本阶段先留好, S3 接进 dep entry。
// =============================================================================
module ct_idu_vecq_entry (
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic         rtu_yy_xx_flush,

  // 标量写回 snoop (IU pipe0/1/2 + LSU pipe3)
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe2_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe2_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,

  // 第 5 路唤醒 (vset 写回): S2 顶层钉 0, S3 接进 dep entry
  input  logic [5:0]   rvv_idu_vset_wb_preg_dupx,
  input  logic         rvv_idu_vset_wb_preg_vld_dupx,

  // 建表 / 弹出
  input  logic [`VIQ_WIDTH-1:0] x_create_data,
  input  logic         x_create_en,
  input  logic         x_pop,

  // 读出
  output logic [`VIQ_WIDTH-1:0] x_read_data,
  output logic         x_rdy,
  output logic         x_vld,
  // issue 时的**当前** wb (dep entry 实时跟踪), 不是 data_q 里的建表快照
  output logic         x_src0_wb,
  output logic         x_src1_wb
);

//==========================================================
//                    Internal Signals
//==========================================================
logic               vld;
logic [`VIQ_WIDTH-1:0] data_q;

logic               create_src0_vld;
logic               create_src1_vld;
logic [6:0]         create_src0_data;
logic [6:0]         create_src1_data;
logic [6:0]         read_src0_data;
logic [6:0]         read_src1_data;

//==========================================================
//                       Entry Valid
//==========================================================
assign x_vld = vld;

always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b)
    vld <= 1'b0;
  else if (rtu_yy_xx_flush)
    vld <= 1'b0;
  else if (x_create_en)
    vld <= 1'b1;            // 同拍"弹出+重建"时 create 优先
  else if (x_pop)
    vld <= 1'b0;
  else
    vld <= vld;
end

//==========================================================
//                    Instruction Data
//==========================================================
always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b)
    data_q <= {`VIQ_WIDTH{1'b0}};
  else if (rtu_yy_xx_flush)
    data_q <= {`VIQ_WIDTH{1'b0}};   // 防 flush 后残留数据被当成新表项读出
  else if (x_create_en)
    data_q <= x_create_data;
  else
    data_q <= data_q;
end

assign x_read_data = data_q;

//==========================================================
//              Source Dependency Information
//==========================================================
assign create_src0_vld = x_create_data[`VIQ_SRC0_VLD];
assign create_src1_vld = x_create_data[`VIQ_SRC1_VLD];

// srcX_vld=0 ⇒ 源编码强制为 preg0 + wb=1 (立即 ready)
assign create_src0_data = create_src0_vld
                        ? x_create_data[`VIQ_SRC0_DATA:`VIQ_SRC0_DATA-6]
                        : 7'b0000001;
assign create_src1_data = create_src1_vld
                        ? x_create_data[`VIQ_SRC1_DATA:`VIQ_SRC1_DATA-6]
                        : 7'b0000001;

//------------------------source 0--------------------------
ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src0 (
  .cpurst_b                          (cpurst_b                          ),
  .forever_cpuclk                    (forever_cpuclk                    ),
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx     ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx ),
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx     ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx ),
  .iu_idu_ex2_pipe2_wb_preg_dupx     (iu_idu_ex2_pipe2_wb_preg_dupx     ),
  .iu_idu_ex2_pipe2_wb_preg_vld_dupx (iu_idu_ex2_pipe2_wb_preg_vld_dupx ),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx     ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx ),
  .rvv_idu_vset_wb_preg_dupx         (rvv_idu_vset_wb_preg_dupx         ),
  .rvv_idu_vset_wb_preg_vld_dupx     (rvv_idu_vset_wb_preg_vld_dupx     ),
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush                   ),
  .x_create_data                     (create_src0_data[6:0]             ),
  .x_write_en                        (x_create_en                       ),
  .x_read_data                       (read_src0_data[6:0]               )
);

//------------------------source 1--------------------------
ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src1 (
  .cpurst_b                          (cpurst_b                          ),
  .forever_cpuclk                    (forever_cpuclk                    ),
  .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx     ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx ),
  .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx     ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx ),
  .iu_idu_ex2_pipe2_wb_preg_dupx     (iu_idu_ex2_pipe2_wb_preg_dupx     ),
  .iu_idu_ex2_pipe2_wb_preg_vld_dupx (iu_idu_ex2_pipe2_wb_preg_vld_dupx ),
  .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx     ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx ),
  .rvv_idu_vset_wb_preg_dupx         (rvv_idu_vset_wb_preg_dupx         ),
  .rvv_idu_vset_wb_preg_vld_dupx     (rvv_idu_vset_wb_preg_vld_dupx     ),
  .rtu_yy_xx_flush                   (rtu_yy_xx_flush                   ),
  .x_create_data                     (create_src1_data[6:0]             ),
  .x_write_en                        (x_create_en                       ),
  .x_read_data                       (read_src1_data[6:0]               )
);

//==========================================================
//                     Entry Ready
//==========================================================
// dep entry 的 x_read_data[0] = wb (结果已经写进 PRF)
assign x_rdy = vld
               && read_src0_data[0]
               && read_src1_data[0];

// 发射给 core 的 wb 必须是 dep entry 的**当前**值:
// data_q 里的 [srcX_data] 是建表时的快照, 指令在 VIQ 里等过写回后它会过期。
assign x_src0_wb = read_src0_data[0];
assign x_src1_wb = read_src1_data[0];

// S2: 第 5 路唤醒端口 (rvv_idu_vset_wb_*) 先留好; S3 接进 dep entry。

endmodule
