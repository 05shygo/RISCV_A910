// =============================================================================
// ct_idu_vecq.sv —— 向量队列 (VIQ, S2)
//
// 规格（2026-10-17 用户方案确认）:
//   * 4 深、严格按序 FIFO;
//   * **2 写 / 1 读**: create0/create1 两个写口, head 一个读口;
//   * 真正的 pop = vecq_xx_issue_en && rvv_vec_inst_ready, 由顶层相与后
//     经 vecq_dp_issue_pop 送回 (本阶段 ready 钉 0 ⇒ 不会 pop);
//   * **vecq 就是 RVV 通路的唯一指令缓冲**: RvvFrontEnd 不再排队,
//     RvvCore 的解码流水线固定 N=1 (见 RvvCore.sv / rvv_backend_define.svh)。
//
// 水位信号 vecq_ctrl_full_updt / vecq_ctrl_1_left_updt 的口径与 AIQ 完全相同:
//   full_updt     = 本拍更新后队列会满 (cnt' == 4)
//   1_left_updt   = 本拍更新后只剩 1 个空位 (cnt' == 3)
// is_ctrl 用它们做下一拍 create 的预判 (create0 对 full, create1 对 1_left)。
//
// 字段定义见 ct_idu_vecq_defs.svh (与 is_dp 的 101 位打包一一对应)。
// =============================================================================
`include "ct_idu_vecq_defs.svh"

module ct_idu_vecq (
  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic         vecq_ctrl_1_left_updt,
  output logic         vecq_ctrl_full_updt,
  output logic         vecq_xx_issue_en,
  output logic [`VIQ_WIDTH-1:0] vecq_dp_issue_data,
  // issue 时的当前源 wb (来自 dep entry, 不是建表快照)
  output logic         vecq_dp_issue_src0_wb,
  output logic         vecq_dp_issue_src1_wb,

  // PRF 读口: head 的 src0/src1 preg
  output logic [5:0]   vecq_prf_rd_addr0,
  output logic [5:0]   vecq_prf_rd_addr1,
  input  logic [31:0]  vecq_prf_rd_data0,
  input  logic [31:0]  vecq_prf_rd_data1,

  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,

  input  logic         ctrl_vec_create0_en,
  input  logic         ctrl_vec_create1_en,
  input  logic [`VIQ_WIDTH-1:0] dp_vec_create0_data,
  input  logic [`VIQ_WIDTH-1:0] dp_vec_create1_data,
  input  logic [6:0]   dp_vec_create0_iid,
  input  logic [6:0]   dp_vec_create1_iid,

  input  logic         rtu_yy_xx_flush,

  // 唯一读口的真正 pop 使能 (= issue_en && rvv_vec_inst_ready)
  input  logic         vecq_dp_issue_pop,

  // 标量写回 snoop (IU pipe0/1/2 + LSU pipe3)
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe2_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe2_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,

  // 第 5 路唤醒 (vset): S2 顶层钉 0, S3 接进 entry 的 dep entry
  input  logic [5:0]   rvv_idu_vset_wb_preg_dupx,
  input  logic         rvv_idu_vset_wb_preg_vld_dupx
);

localparam VECQ_ENTRY = 4;

//==========================================================
//                    Internal Signals
//==========================================================
logic [1:0]  wr_ptr;
logic [1:0]  rd_ptr;
logic [2:0]  vecq_entry_cnt;

logic [VECQ_ENTRY-1:0] entry_create_en;
logic [VECQ_ENTRY-1:0] entry_pop;
logic [VECQ_ENTRY-1:0] entry_rdy;
logic [VECQ_ENTRY-1:0] entry_vld;
logic [VECQ_ENTRY-1:0] entry_src0_wb;
logic [VECQ_ENTRY-1:0] entry_src1_wb;

logic [`VIQ_WIDTH-1:0] entry_create_data [0:VECQ_ENTRY-1];
logic [`VIQ_WIDTH-1:0] entry_read_data   [0:VECQ_ENTRY-1];

logic [1:0]  create1_slot;
logic [2:0]  create_num;
logic [2:0]  cnt_updt;
logic [`VIQ_WIDTH-1:0] head_data;

// 水位预判
logic        create_2;
logic        create_1;
logic        create_0;
logic        pop_0;

//==========================================================
//                Create / Pop Slot Mapping
//==========================================================
// create0 落在 wr_ptr; create1 落在它后一格。create1 一定伴随 create0
// (is_ctrl 的 create1_en 是“至少两条向量”), 但这里仍按 create0_en 计算,
// 万一上游行为变化也不会在两格之间留洞。
assign create1_slot = wr_ptr + {1'b0, ctrl_vec_create0_en};
assign create_num   = {2'b0, ctrl_vec_create0_en}
                    + {2'b0, ctrl_vec_create1_en};

always_comb begin
  entry_create_en = 4'b0;
  entry_create_en[wr_ptr]       = ctrl_vec_create0_en;
  entry_create_en[create1_slot] = ctrl_vec_create1_en;
end

always_comb begin
  for (int k = 0; k < VECQ_ENTRY; k++)
    entry_create_data[k] = {`VIQ_WIDTH{1'bx}};

  // 101 位打包与 is_dp 完全一致; 末尾用单独送来的 iid 覆盖同名字段,
  // 保证“数据包里的 iid”和“create 口的 iid”永远一致。
  entry_create_data[wr_ptr] =
      {dp_vec_create0_data[`VIQ_PC:`VIQ_IID+1],
       dp_vec_create0_iid[6:0],
       dp_vec_create0_data[`VIQ_VEC_TYPE:0]};

  entry_create_data[create1_slot] =
      {dp_vec_create1_data[`VIQ_PC:`VIQ_IID+1],
       dp_vec_create1_iid[6:0],
       dp_vec_create1_data[`VIQ_VEC_TYPE:0]};
end

always_comb begin
  entry_pop = 4'b0;
  entry_pop[rd_ptr] = vecq_dp_issue_pop;
end

//==========================================================
//                     Head 数据选择
//==========================================================
always_comb begin
  case (rd_ptr)
    2'd0:    head_data = entry_read_data[0];
    2'd1:    head_data = entry_read_data[1];
    2'd2:    head_data = entry_read_data[2];
    2'd3:    head_data = entry_read_data[3];
    default: head_data = {`VIQ_WIDTH{1'bx}};
  endcase
end

assign vecq_dp_issue_data = head_data;

// head 的当前源 wb (四选一, 与 head_data 同拍)
always_comb begin
  case (rd_ptr)
    2'd0: begin vecq_dp_issue_src0_wb = entry_src0_wb[0];
                vecq_dp_issue_src1_wb = entry_src1_wb[0]; end
    2'd1: begin vecq_dp_issue_src0_wb = entry_src0_wb[1];
                vecq_dp_issue_src1_wb = entry_src1_wb[1]; end
    2'd2: begin vecq_dp_issue_src0_wb = entry_src0_wb[2];
                vecq_dp_issue_src1_wb = entry_src1_wb[2]; end
    2'd3: begin vecq_dp_issue_src0_wb = entry_src0_wb[3];
                vecq_dp_issue_src1_wb = entry_src1_wb[3]; end
    default: begin vecq_dp_issue_src0_wb = 1'bx;
                   vecq_dp_issue_src1_wb = 1'bx; end
  endcase
end

// 2026-10-17 S3b: 只有 vset* 在 vecq 里等源 ready (它不进入 RVV 后端);
// 其余向量计算指令立即发射, 迟到写回在 RVV 的 ALU/MUL/DIV/PMT RS 里等;
// 向量 L/S 的基址等待在 A910 LSIQ (S7)。
// head 的 101 位表项 [68:37] 是完整指令字: opcode=[43:37], funct3=[51:49]。
wire [6:0] head_opcode = head_data[`VIQ_OPCODE-25:`VIQ_OPCODE-31];
wire [2:0] head_funct3 = head_data[`VIQ_OPCODE-17:`VIQ_OPCODE-19];
wire       head_is_vset = (head_opcode == 7'b1010111) && (head_funct3 == 3'b111);

assign vecq_xx_issue_en = entry_vld[rd_ptr] &&
                          (!head_is_vset || entry_rdy[rd_ptr]);

//==========================================================
//                    PRF 读地址
//==========================================================
// srcX_data[6:1] 是 preg[5:0], bit0 是 wb; srcX_vld=0 时读 preg0 (恒 0)。
assign vecq_prf_rd_addr0 =
    head_data[`VIQ_SRC0_VLD]
      ? head_data[`VIQ_SRC0_DATA:`VIQ_SRC0_DATA-5] : 6'd0;
assign vecq_prf_rd_addr1 =
    head_data[`VIQ_SRC1_VLD]
      ? head_data[`VIQ_SRC1_DATA:`VIQ_SRC1_DATA-5] : 6'd0;

//==========================================================
//               Entry Counter / Pointers
//==========================================================
assign cnt_updt = vecq_entry_cnt + create_num - {2'b0, vecq_dp_issue_pop};

always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    wr_ptr         <= 2'd0;
    rd_ptr         <= 2'd0;
    vecq_entry_cnt <= 3'd0;
  end
  else if (rtu_yy_xx_flush) begin
    wr_ptr         <= 2'd0;
    rd_ptr         <= 2'd0;
    vecq_entry_cnt <= 3'd0;
  end
  else begin
    wr_ptr         <= wr_ptr + create_num[1:0];
    rd_ptr         <= rd_ptr + {1'b0, vecq_dp_issue_pop};
    vecq_entry_cnt <= cnt_updt;
  end
end

//==========================================================
//                 Water-level prediction
//==========================================================
// 口径与 ct_idu_is_aiq.sv:131-165 完全相同。
assign create_2 = ctrl_vec_create1_en;                          // 两条都建
assign create_1 = ctrl_vec_create0_en && !ctrl_vec_create1_en;  // 恰好建一条
assign create_0 = !ctrl_vec_create0_en;                         // 不建
assign pop_0    = !vecq_dp_issue_pop;

assign vecq_ctrl_full_updt =
       (vecq_entry_cnt == 3'd2) && create_2 && pop_0
    || (vecq_entry_cnt == 3'd3) && create_1 && pop_0
    || (vecq_entry_cnt == 3'd4) && create_0 && pop_0;

assign vecq_ctrl_1_left_updt =
       (vecq_entry_cnt == 3'd1) && create_2 && pop_0
    || (vecq_entry_cnt == 3'd2) && create_1 && pop_0
    || (vecq_entry_cnt == 3'd2) && create_2 && !pop_0
    || (vecq_entry_cnt == 3'd3) && create_0 && pop_0
    || (vecq_entry_cnt == 3'd3) && create_1 && !pop_0
    || (vecq_entry_cnt == 3'd4) && create_0 && !pop_0;

//==========================================================
//                   Entry Instances
//==========================================================
genvar gi;
generate
  for (gi = 0; gi < VECQ_ENTRY; gi++) begin : gen_vecq_entry
    ct_idu_vecq_entry u_ct_idu_vecq_entry (
      .cpurst_b                          (cpurst_b                          ),
      .forever_cpuclk                    (forever_cpuclk                    ),
      .rtu_yy_xx_flush                   (rtu_yy_xx_flush                   ),
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
      .x_create_data                     (entry_create_data[gi]             ),
      .x_create_en                       (entry_create_en[gi]               ),
      .x_pop                             (entry_pop[gi]                     ),
      .x_read_data                       (entry_read_data[gi]               ),
      .x_rdy                             (entry_rdy[gi]                     ),
      .x_vld                             (entry_vld[gi]                     ),
      .x_src0_wb                         (entry_src0_wb[gi]                 ),
      .x_src1_wb                         (entry_src1_wb[gi]                 )
    );
  end
endgenerate

endmodule
