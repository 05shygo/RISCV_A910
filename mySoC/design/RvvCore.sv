// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// ⚠️ 2026-10-17 (S2 用户方案): N 固定为 1。
//    指令缓冲由 A910 IDU 侧的 ct_idu_vecq (4 深, 2 写/1 读) 承担;
//    RvvFrontEnd 的 N 槽只作为"accept 后一拍 reg_read_data 对齐"的单级流水寄存器,
//    不再需要 4 条并行的指令槽/解码通道。
module RvvCore #(parameter N = 1,
                 parameter CMD_BUFFER_MAX_CAPACITY = 16,
                 type RegDataT=logic [31:0],
                 type VRegDataT=logic [127:0],
                 type RegAddrT=logic [4:0],
                 type MaskT=logic [15:0]
                 )
(
  input clk,
  input rstn,

  input logic [`VSTART_WIDTH-1:0] vstart,
  input logic vstart_valid,
  input logic [1:0] vxrm,
  input logic vxsat,
  input logic [2:0] frm,
  input logic flush,

  // Instruction input.
  input logic [N-1:0] inst_valid,
  input RVVInstruction [N-1:0] inst_data,
  output logic [N-1:0] inst_ready,

  // Register file input
  input logic [(2*N)-1:0] reg_read_valid,
  input RegDataT [(2*N)-1:0] reg_read_data,

  // Floating point register file input
  input RegDataT [N-1:0] freg_read_data,

  // Scalar Regfile writeback for configuration functions.
  output logic [N-1:0] reg_write_valid,
  output RegAddrT [N-1:0] reg_write_addr,
  output RegDataT [N-1:0] reg_write_data,

  // Scalar Regfile writeback for non-configuration functions.
  output logic async_rd_valid,
  output RegAddrT async_rd_addr,
  output RegDataT async_rd_data,
  input logic async_rd_ready,

  // Floating Point Regfile writeback.
  output logic async_frd_valid,
  output RegAddrT async_frd_addr,
  output RegDataT async_frd_data,
  input logic async_frd_ready,

  // RVV to LSU
  output  logic     [`NUM_LSU-1:0] uop_lsu_valid_rvv2lsu,
  output  logic     [`NUM_LSU-1:0] uop_lsu_idx_valid_rvv2lsu,
  output  RegAddrT  [`NUM_LSU-1:0] uop_lsu_idx_addr_rvv2lsu,
  output  VRegDataT [`NUM_LSU-1:0] uop_lsu_idx_data_rvv2lsu,
  output  logic     [`NUM_LSU-1:0] uop_lsu_vregfile_valid_rvv2lsu,
  output  RegAddrT  [`NUM_LSU-1:0] uop_lsu_vregfile_addr_rvv2lsu,
  output  VRegDataT [`NUM_LSU-1:0] uop_lsu_vregfile_data_rvv2lsu,
  output  logic     [`NUM_LSU-1:0] uop_lsu_v0_valid_rvv2lsu,
  output  MaskT     [`NUM_LSU-1:0] uop_lsu_v0_data_rvv2lsu,
  // 2026-10-17 S6: 送 A910 LSU 的完整字段 (扁平口, 不改结构端口)
  output  logic     [`NUM_LSU-1:0][`ROB_TAG_WIDTH-1:0]                    uop_lsu_rob_tag_rvv2lsu,
  output  logic     [`NUM_LSU-1:0][`UOP_INDEX_WIDTH_LSU-1:0]              uop_lsu_uop_index_rvv2lsu,
  output  logic     [`NUM_LSU-1:0][2:0]                                   uop_lsu_lsu_id_rvv2lsu,
  output  logic     [`NUM_LSU-1:0]                                        uop_lsu_first_rvv2lsu,
  output  logic     [`NUM_LSU-1:0]                                        uop_lsu_last_rvv2lsu,
  output  logic     [`NUM_LSU-1:0]                                        uop_lsu_is_store_rvv2lsu,
  output  LSU_TYPE_t [`NUM_LSU-1:0]                                       uop_lsu_type_rvv2lsu,
  output  EEW_e      [`NUM_LSU-1:0]                                       uop_lsu_vd_eew_rvv2lsu,
  output  EEW_e      [`NUM_LSU-1:0]                                       uop_lsu_vs2_eew_rvv2lsu,
  output  logic     [`NUM_LSU-1:0][`VL_WIDTH-1:0]                         uop_lsu_vl_rvv2lsu,
  output  logic     [`NUM_LSU-1:0][`VSTART_WIDTH-1:0]                     uop_lsu_vstart_rvv2lsu,
  output  logic     [`NUM_LSU-1:0][`REGIDX_WIDTH-1:0]                     uop_lsu_dst_index_rvv2lsu,
  output  logic     [`NUM_LSU-1:0][31:0]                                  uop_lsu_rs1_data_rvv2lsu,
  output  logic     [`NUM_LSU-1:0]                                        uop_lsu_rs1_vld_rvv2lsu,
  output  logic     [`NUM_LSU-1:0][31:0]                                  uop_lsu_rs2_data_rvv2lsu,
  output  logic     [`NUM_LSU-1:0]                                        uop_lsu_rs2_vld_rvv2lsu,
  output  logic     [`NUM_LSU-1:0][$clog2(`EMUL_MAX)-1:0]                 uop_lsu_seg_index_rvv2lsu,
  input   logic     [`NUM_LSU-1:0] uop_lsu_ready_lsu2rvv,

  // LSU to RVV
  input  logic     [`NUM_LSU-1:0] uop_lsu_valid_lsu2rvv,
  input  RegAddrT  [`NUM_LSU-1:0] uop_lsu_addr_lsu2rvv,
  input  VRegDataT [`NUM_LSU-1:0] uop_lsu_wdata_lsu2rvv,
  input  logic     [`NUM_LSU-1:0] uop_lsu_last_lsu2rvv,
  input  logic     [`NUM_LSU-1:0][$clog2(`VLENB):0] uop_lsu_ff_tail_index_lsu2rvv,
  // 2026-10-17 S6: 乱序响应的配对键 (bridge 原样带回)
  input  logic     [`NUM_LSU-1:0][`ROB_TAG_WIDTH-1:0]        uop_lsu_rob_tag_lsu2rvv,
  input  logic     [`NUM_LSU-1:0][`UOP_INDEX_WIDTH_LSU-1:0]  uop_lsu_uop_index_lsu2rvv,
  input  logic     [`NUM_LSU-1:0][2:0]                       uop_lsu_lsu_id_lsu2rvv,
  output logic     [`NUM_LSU-1:0] uop_lsu_ready_rvv2lsu,

  // Vector CSR writeback
  output vcsr_valid,
  output RVVConfigState vector_csr,
  input vcsr_ready,

  // Config state
  output config_state_valid,
  output RVVConfigState config_state,
  output logic [31:0] next_config_mtype_o,

  // Idle
  output logic rvv_idle,
  output logic [$clog2(2*N + 1)-1:0] queue_capacity,

  // Writeback from reorder buffer and decode stage
  output ROB2RT_t [`NUM_RT_UOP+`NUM_DE_INST-1:0] rd_rob2rt_o,
  output logic    [`NUM_RT_UOP+`NUM_DE_INST-1:0] rd_valid_rob2rt_o,

  // Trap output
  output logic trap_valid_o,
  output RVVInstruction trap_data_o,

  // VXSAT update from backend (fixes C3 bug: previously dead-end wires)
  output logic                            wr_vxsat_valid_o,
  output logic    [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat_o,

  // Floating point fflags update from backend
  output logic                            wr_fflags_valid_o,
  output logic    [4:0]                   wr_fflags_o,

  //==========================================================
  // A910 bridge 接口 (2026-10-17 S3 新增)
  //==========================================================
  // 每条被接受的指令对应的架构配置状态 (N=1)。
  output RVVConfigState [N-1:0] cmd_config_state_o,
  // 配置恢复: S3 钉 0, S4 由 bridge 驱动。
  input  logic                  config_load_valid_i,
  input  RVVConfigState         config_load_data_i,

  //==========================================================
  // 标量源等待 (2026-10-17 S3b)
  //==========================================================
  // 每条指令的标量源: 物理号 / 是否使用 / issue 时是否已写回。
  input  logic [N-1:0]              src0_vld_i,
  input  logic [N-1:0][5:0]         src0_preg_i,
  input  logic [N-1:0]              src0_wb_i,
  input  logic [N-1:0][31:0]        src0_data_i,
  input  logic [N-1:0]              src1_vld_i,
  input  logic [N-1:0][5:0]         src1_preg_i,
  input  logic [N-1:0]              src1_wb_i,
  input  logic [N-1:0][31:0]        src1_data_i,
  // A910 标量写回: IU pipe0/1/2、LSU pipe3、vset
  input  logic [4:0]                scalar_wb_vld,
  input  logic [4:0][5:0]           scalar_wb_preg,
  input  logic [4:0][31:0]          scalar_wb_data,
  // 提交水位 / 完成 (S4 接 backend; S3 本模块内钉 0)。
  input  logic                  cmt_wmk_valid_i,
  input  logic [`ROB_TAG_WIDTH-1:0] cmt_wmk_iid_i,
  output logic                  inst_cmplt_valid_o,
  output logic [`ROB_TAG_WIDTH-1:0] inst_cmplt_iid_o,
  output logic [`ROB_TAG_WIDTH-1:0] rob_head_rob_tag_o,
  output logic                  rob_head_valid_o
`ifdef ZVT_ON
  ,
  // VME to LSU (store data)
  output logic uop_vme2lsu_valid,
  output VRegDataT uop_vme2lsu_data,
  input logic uop_vme2lsu_ready,

  // LSU to VME (load data)
  input logic uop_lsu2vme_valid,
  input VRegDataT uop_lsu2vme_data,
  output logic uop_lsu2vme_ready,

  // VME retirement
  output logic vmeRtVld_o,
  output VMERT_t vmeRt_o,
  input  logic vmeRtRdy_i
`endif
);
  logic [N-1:0] frontend_cmd_valid;
  RVVCmd [N-1:0] frontend_cmd_data;
  // frontend → backend 的按-iid 源等待表写口 (S3b)
  logic [N-1:0]       src0_wt_vld;
  logic [N-1:0][6:0]  src0_wt_iid;
  logic [N-1:0][5:0]  src0_wt_preg;
  logic [N-1:0]       src0_wt_wb;
  logic [N-1:0][31:0] src0_wt_data;
  logic [N-1:0]       src1_wt_vld;
  logic [N-1:0][6:0]  src1_wt_iid;
  logic [N-1:0][5:0]  src1_wt_preg;
  logic [N-1:0]       src1_wt_wb;
  logic [N-1:0][31:0] src1_wt_data;
  logic [$clog2(2*N + 1)-1:0] queue_capacity_internal;
  RvvFrontEnd#(.N(N), .RegDataT(RegDataT), .RegAddrT(RegAddrT)) frontend(
      .clk(clk),
      .rstn(rstn),
      .vstart_i(vstart),
      .vstart_valid_i(vstart_valid),
      .vxrm_i(vxrm),
      .vxsat_i(vxsat),
      .frm_i(frm),
      .flush_i(flush),
      .inst_valid_i(inst_valid),
      .inst_data_i(inst_data),
      .inst_ready_o(inst_ready),
      .reg_read_valid_i(reg_read_valid),
      .reg_read_data_i(reg_read_data),
      .freg_read_data_i(freg_read_data),
      .reg_write_valid_o(reg_write_valid),
      .reg_write_addr_o(reg_write_addr),
      .reg_write_data_o(reg_write_data),
      .cmd_valid_o(frontend_cmd_valid),
      .cmd_data_o(frontend_cmd_data),
      .queue_capacity_i(queue_capacity_internal),
      .queue_capacity_o(queue_capacity),
      .trap_valid_o(trap_valid_o),
      .trap_data_o(trap_data_o),
      .config_state_valid(config_state_valid),
      .config_state(config_state),
      .next_config_mtype_o(next_config_mtype_o),
      // S3: A910 bridge 接口
      .cmd_config_state_o(cmd_config_state_o),
      .config_load_valid_i(config_load_valid_i),
      .config_load_data_i(config_load_data_i),
      // S3b: 源等待 + re-arm
      .src0_vld_i(src0_vld_i),
      .src0_preg_i(src0_preg_i),
      .src0_wb_i(src0_wb_i),
      .src0_data_i(src0_data_i),
      .src1_vld_i(src1_vld_i),
      .src1_preg_i(src1_preg_i),
      .src1_wb_i(src1_wb_i),
      .src1_data_i(src1_data_i),
      .src0_wt_vld(src0_wt_vld),
      .src0_wt_iid(src0_wt_iid),
      .src0_wt_preg(src0_wt_preg),
      .src0_wt_wb(src0_wt_wb),
      .src0_wt_data(src0_wt_data),
      .src1_wt_vld(src1_wt_vld),
      .src1_wt_iid(src1_wt_iid),
      .src1_wt_preg(src1_wt_preg),
      .src1_wt_wb(src1_wt_wb),
      .src1_wt_data(src1_wt_data)
  );

  // frontend → backend 的 re-arm 脉冲 (S3b)


  //==========================================================
  //  S4: 完成/提交水位由 backend 的 ROB 驱动 (见下方 rvv_backend 例化)
  //==========================================================

  // Backpressure from backend fifo
  logic   [$clog2(`CQ_DEPTH):0] remaining_count_cq2rvs;
  // Back-pressure frontend
  always_comb begin
    if (remaining_count_cq2rvs > 2*N) begin
      queue_capacity_internal = 2*N;
    end else begin
      queue_capacity_internal = remaining_count_cq2rvs;
    end
  end

  // Back-end ============================================================

  // LSU Tie-offs
  // RVV send LSU uop to RVS
    UOP_RVV2LSU_t     [`NUM_LSU-1:0]          uop_lsu_rvv2lsu;
    // S6: scoreboard 槽号由 backend 的 remap 在 LSU 接收那一拍分配
    logic [`NUM_LSU-1:0][2:0]                 backend_lsu_id;
    always_comb begin
      for (int i = 0; i < `NUM_LSU; i++) begin
        uop_lsu_idx_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_valid;
        uop_lsu_idx_addr_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_addr;
        uop_lsu_idx_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_data;
        uop_lsu_vregfile_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_valid;
        uop_lsu_vregfile_addr_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_addr;
        uop_lsu_vregfile_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_data;
        uop_lsu_v0_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].v0_valid;
        uop_lsu_v0_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].v0_data;
        // S6: A910 LSU 需要的完整字段
        uop_lsu_rob_tag_rvv2lsu[i]  = uop_lsu_rvv2lsu[i].rob_tag;
        uop_lsu_uop_index_rvv2lsu[i]= uop_lsu_rvv2lsu[i].uop_index;
        uop_lsu_first_rvv2lsu[i]    = uop_lsu_rvv2lsu[i].first_uop_valid;
        uop_lsu_last_rvv2lsu[i]     = uop_lsu_rvv2lsu[i].last_uop_valid;
        uop_lsu_is_store_rvv2lsu[i] = uop_lsu_rvv2lsu[i].lsu_is_store;
        uop_lsu_type_rvv2lsu[i]     = uop_lsu_rvv2lsu[i].lsu_type;
        uop_lsu_vd_eew_rvv2lsu[i]   = uop_lsu_rvv2lsu[i].vd_eew;
        uop_lsu_vs2_eew_rvv2lsu[i]  = uop_lsu_rvv2lsu[i].vs2_eew;
        uop_lsu_vl_rvv2lsu[i]       = uop_lsu_rvv2lsu[i].vl;
        uop_lsu_vstart_rvv2lsu[i]   = uop_lsu_rvv2lsu[i].vstart;
        uop_lsu_dst_index_rvv2lsu[i]= uop_lsu_rvv2lsu[i].dst_index;
        uop_lsu_rs1_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].rs1_data;
        uop_lsu_rs1_vld_rvv2lsu[i]  = uop_lsu_rvv2lsu[i].rs1_data_valid;
        uop_lsu_rs2_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].rs2_data;
        uop_lsu_rs2_vld_rvv2lsu[i]  = uop_lsu_rvv2lsu[i].rs2_data_valid;
        uop_lsu_seg_index_rvv2lsu[i]= uop_lsu_rvv2lsu[i].seg_field_index;
      end
    end
    // 槽号不来自 RS 表项 (它在 LSU 接收那一拍才分配), 由 backend 直接给出
    assign uop_lsu_lsu_id_rvv2lsu = backend_lsu_id;

  // LSU feedback to RVV
    UOP_LSU2RVV_t     [`NUM_LSU-1:0]          uop_lsu_lsu2rvv;
    always_comb begin
      for (int i = 0; i < `NUM_LSU; i++) begin
        uop_lsu_lsu2rvv[i].vregfile_write_valid = (
            uop_lsu_valid_lsu2rvv[i] && !uop_lsu_last_lsu2rvv[i]);
        uop_lsu_lsu2rvv[i].vregfile_write_addr = uop_lsu_addr_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].vregfile_write_data = uop_lsu_wdata_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].ff_tail_index = uop_lsu_ff_tail_index_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].lsu_vstore_last = (
            uop_lsu_valid_lsu2rvv[i] && uop_lsu_last_lsu2rvv[i]);
        // S6: 乱序返回的配对键 —— bridge 原样带回
        uop_lsu_lsu2rvv[i].rob_tag   = uop_lsu_rob_tag_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].uop_index = uop_lsu_uop_index_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].lsu_id    = uop_lsu_lsu_id_lsu2rvv[i];
        `ifdef TB_SUPPORT
              uop_lsu_lsu2rvv[i].uop_pc = 0;
        `endif
      end
    end

  // Scalar regfile write-back tie-offs
  // TODO(derekjchow): Properly arbitrate write-back tie-offs by extending
  // interface. For time being, only accept from slot 0.
  logic    [`NUM_RT_UOP-1:0] rt_xrf_valid_rvv2rvs;
  RT2RVS_t [`NUM_RT_UOP-1:0] rt_rvs_rvv2rvs;
  logic    [`NUM_RT_UOP-1:0] rt_rvs_ready_rvs2rvv;

  always_comb begin
    rt_rvs_ready_rvs2rvv[0] = async_rd_ready;
    async_rd_valid = rt_xrf_valid_rvv2rvs[0];
    async_rd_addr = rt_rvs_rvv2rvs[0].rt_index;
    async_rd_data = rt_rvs_rvv2rvs[0].rt_data;
    for (int i = 1; i < `NUM_RT_UOP; i++) begin
      rt_rvs_ready_rvs2rvv[i] = 0;
    end
  end

  // Floating point regfile write-back
  // TODO(derekjchow): Properly arbitrate write-back tie-offs by extending
  // interface. For time being, only accept from slot 0.
  logic [`NUM_RT_UOP-1:0]                           rvv2rvs_frd_valid;
`ifdef TB_SUPPORT
  logic [`NUM_RT_UOP-1:0][`PC_WIDTH-1:0]            rvv2rvs_frd_pc;
`endif
  logic [`NUM_RT_UOP-1:0][`ROB_TAG_WIDTH-1:0]       rvv2rvs_frd_rob_tag;
  logic [`NUM_RT_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] rvv2rvs_frd_addr;
  logic [`NUM_RT_UOP-1:0][`XLEN-1:0]                rvv2rvs_frd_data;
  logic [`NUM_RT_UOP-1:0]                           rvv2rvs_frd_ready;
  always_comb begin
    rvv2rvs_frd_ready[0] = async_frd_ready;
    for (int i = 1; i < `NUM_RT_UOP; i++) begin
      rvv2rvs_frd_ready[i] = 0;
    end
  end
  assign async_frd_valid = rvv2rvs_frd_valid[0];
  assign async_frd_addr = rvv2rvs_frd_addr[0];
  assign async_frd_data = rvv2rvs_frd_data[0];

  // Backpressure
  logic wr_vxsat_ready;
  always_comb begin
    // TODO(derekjchow): Actually accept
    wr_vxsat_ready = 1;
  end

  // CSR Update, unused for now
  logic                            wr_vxsat_valid;
  logic    [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat;

  // Floating point CSR Update, unused for now
  logic    rt2fcsr_write_valid;
  RVFEXP_t rt2fcsr_write_data;
  logic    fcsr2rt_write_ready;
  always_comb begin
    // TODO(derekjchow): Actually accept and use
    fcsr2rt_write_ready = 1;
  end

  // Trap handling
  logic  trap_valid_rvs2rvv;
  logic  trap_ready_rvv2rvs;
  assign trap_valid_rvs2rvv = flush;

  // Tie-off unused VME interfaces
`ifdef ZVT_ON
  logic                 uop_vme2lsu_vld;
  UOP_VME2LSU_t         uop_vme2lsu;
  logic                 uop_vme2lsu_rdy;
  logic                 uop_lsu2vme_vld;
  UOP_LSU2VME_t         uop_lsu2vme;
  logic                 uop_lsu2vme_rdy;

  assign uop_vme2lsu_valid = uop_vme2lsu_vld;
  assign uop_vme2lsu_data  = uop_vme2lsu.r_data;
  assign uop_vme2lsu_rdy   = uop_vme2lsu_ready;

  assign uop_lsu2vme_vld    = uop_lsu2vme_valid;
  assign uop_lsu2vme.w_data = uop_lsu2vme_data;
`ifdef TB_SUPPORT
  assign uop_lsu2vme.uop_pc    = 0;
  assign uop_lsu2vme.uop_index = 0;
`endif
  assign uop_lsu2vme_ready = uop_lsu2vme_rdy;
`endif

  logic   [`ISSUE_LANE-1:0] insts_ready_cq2rvs;
  logic rvv_backend_idle;
  assign rvv_idle = rvv_backend_idle && (frontend_cmd_valid == 0);
  rvv_backend backend(
      .clk(clk),
      .rst_n(rstn),
      // S3b: 标量写回 + re-arm
      .scalar_wb_vld(scalar_wb_vld),
      .scalar_wb_preg(scalar_wb_preg),
      .scalar_wb_data(scalar_wb_data),
      .src0_wt_vld(src0_wt_vld[0]),
      .src0_wt_iid(src0_wt_iid[0]),
      .src0_wt_preg(src0_wt_preg[0]),
      .src0_wt_wb(src0_wt_wb[0]),
      .src0_wt_data(src0_wt_data[0]),
      .src1_wt_vld(src1_wt_vld[0]),
      .src1_wt_iid(src1_wt_iid[0]),
      .src1_wt_preg(src1_wt_preg[0]),
      .src1_wt_wb(src1_wt_wb[0]),
      .src1_wt_data(src1_wt_data[0]),
      // S4: A910 完成 / 提交
      .cmt_wmk_valid(cmt_wmk_valid_i),
      .cmt_wmk_iid(cmt_wmk_iid_i),
      .inst_cmplt_valid(inst_cmplt_valid_o),
      .inst_cmplt_rob_tag(inst_cmplt_iid_o),
      .rob_head_rob_tag(rob_head_rob_tag_o),
      .rob_head_valid(rob_head_valid_o),
      .insts_valid_rvs2cq(frontend_cmd_valid),
      .insts_rvs2cq(frontend_cmd_data),
      .insts_ready_cq2rvs(insts_ready_cq2rvs),
      .remaining_count_cq2rvs(remaining_count_cq2rvs),

      .uop_lsu_valid_rvv2lsu(uop_lsu_valid_rvv2lsu),
      .uop_lsu_rvv2lsu(uop_lsu_rvv2lsu),
      .uop_lsu_lsu_id_rvv2lsu(backend_lsu_id),
      .uop_lsu_ready_lsu2rvv(uop_lsu_ready_lsu2rvv),

      .uop_lsu_valid_lsu2rvv(uop_lsu_valid_lsu2rvv),
      .uop_lsu_lsu2rvv(uop_lsu_lsu2rvv),
      .uop_lsu_ready_rvv2lsu(uop_lsu_ready_rvv2lsu),

      .rt_rvs_rvv2rvs(rt_rvs_rvv2rvs),
      .rt_xrf_valid_rvv2rvs(rt_xrf_valid_rvv2rvs),
      .rt_rvs_ready_rvs2rvv(rt_rvs_ready_rvs2rvv),

`ifdef ZVE32F_ON
      .async_frd_valid(rvv2rvs_frd_valid),
`ifdef TB_SUPPORT
      .async_frd_pc(rvv2rvs_frd_pc),
`endif
      .async_frd_rob_tag(rvv2rvs_frd_rob_tag),
      .async_frd_addr(rvv2rvs_frd_addr),
      .async_frd_data(rvv2rvs_frd_data),
      .async_frd_ready(rvv2rvs_frd_ready),
`endif

      .wr_vxsat_valid(wr_vxsat_valid),
      .wr_vxsat(wr_vxsat),
      .wr_vxsat_ready(wr_vxsat_ready),

`ifdef ZVE32F_ON
      .rt2fcsr_write_valid(rt2fcsr_write_valid),
      .rt2fcsr_write_data(rt2fcsr_write_data),
      .fcsr2rt_write_ready(fcsr2rt_write_ready),
`endif
      .trap_valid_rvs2rvv(trap_valid_rvs2rvv),
      .trap_ready_rvv2rvs(trap_ready_rvv2rvs),
      .vcsr_valid(vcsr_valid),
      .vector_csr(vector_csr),
      .vcsr_ready(vcsr_ready),
      .rd_valid_rob2rt_o(rd_valid_rob2rt_o),
      .rvv_idle(rvv_backend_idle),
      .rd_rob2rt_o(rd_rob2rt_o)
`ifdef ZVT_ON
      ,.uop_vme2lsu_vld(uop_vme2lsu_vld),
      .uop_vme2lsu(uop_vme2lsu),
      .uop_vme2lsu_rdy(uop_vme2lsu_rdy),
      .uop_lsu2vme_vld(uop_lsu2vme_vld),
      .uop_lsu2vme(uop_lsu2vme),
      .uop_lsu2vme_rdy(uop_lsu2vme_rdy),
      .vme_lsuflush_vld(1'b0),
      .vme_lsuflush_rdy(),
      .vmeRtVld(vmeRtVld_o),
      .vmeRt(vmeRt_o),
      .vmeRtRdy(vmeRtRdy_i)
`endif
  );

  // Connect vxsat signals to outputs (fixes C3 bug)
  assign wr_vxsat_valid_o = wr_vxsat_valid;
  assign wr_vxsat_o = wr_vxsat;

  // Connect fflags signals to outputs
`ifdef ZVE32F_ON
  assign wr_fflags_valid_o = rt2fcsr_write_valid;
  assign wr_fflags_o = rt2fcsr_write_data;
`else
  assign wr_fflags_valid_o = 1'b0;
  assign wr_fflags_o = 5'b0;
`endif

endmodule
