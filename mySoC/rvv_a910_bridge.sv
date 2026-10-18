// =============================================================================
// rvv_a910_bridge.sv —— A910 IDU 与 coralnpu RvvCore 之间的桥 (S3)
//
// 2026-10-17 方案:
//   * 指令缓冲唯一来源 = A910 IDU 的 ct_idu_vecq (4 深, 2 写/1 读)。
//     bridge **不再加指令 FIFO**; RvvCore 前端固定 N=1, 每拍只解一条。
//   * 每拍最多一条指令进入 core:
//       idu_vec_* (VIQ head)  →  RvvCore.inst_*
//     core 接受后一拍, 用影子寄存器把同一组的 src0/src1 值送回
//     `reg_read_data_i` (RvvFrontEnd 注释: 标量操作数晚一拍到)。
//   * vset* 的标量 rd 写回 (新 vl) 用按 accept 顺序的 4 深 FIFO 配平:
//       accept && is_vset          → push {iid, dst_preg, dst_vld}
//       core.reg_write_valid[0]    → pop  →  rvv_idu_vset_wb_* + cmplt_vld2
//     dst_vld=0 (rd=x0) 也发 cmplt, 但不写 PRF。
//   * S3 只做这些; trap (S5)、LSU (S8)、完成链/提交门控/flush 收敛 (S4)
//     在本文件里先钉 0 / 留端口。
//
// 2026-10-17 S4 已接:
//   * cmplt_vld1  = core ROB 的完成链 (一条指令的全部 uop 都 done);
//   * 提交水位 cmt_wmk_* 由 rtu_yy_xx_commit* 寄存成**电平**送 core;
//     core 的 ROB 只让水位覆盖的表项 pop / 写 VRF;
//   * rtu_flush 后先等已提交前缀 drain，再发 core_flush 全局清 core；
//     同拍 config_load_valid=1，把 vtype/vl 恢复到**已提交**的 vset 状态；
//   * vxsat 从 core 的 wr_vxsat_valid_o 回存到 vxsat_q 再送回 core。
// =============================================================================
`include "rvv_backend.svh"

module rvv_a910_bridge (
  //----------------------------------------------------------------------------
  // 时钟 / 复位
  //----------------------------------------------------------------------------
  input  wire        clk,
  input  wire        rst,                  // 高有效; 内部取反送 core.rstn

  //----------------------------------------------------------------------------
  // 指令入口 (IDU VIQ head, 1 条/拍)
  //----------------------------------------------------------------------------
  input  wire        idu_vec_inst_valid,
  input  wire [6:0]  idu_vec_inst_iid,
  input  wire [31:0] idu_vec_inst_pc,
  input  wire [1:0]  idu_vec_inst_opcode,  // 0=LOAD 1=STORE 2=RVV
  input  wire [24:0] idu_vec_inst_bits,
  // 2026-10-18 直连向量 L/S: IS 建好的 LSIQ anchor 槽号
  input  wire [2:0]  idu_vec_lsid,
  input  wire        idu_vec_src0_vld,
  input  wire [31:0] idu_vec_src0_data,
  input  wire        idu_vec_src1_vld,
  input  wire [31:0] idu_vec_src1_data,
  input  wire [5:0]  idu_vec_dst_preg,
  input  wire        idu_vec_dst_vld,
  input  wire [4:0]  idu_vec_dst_reg,
  output wire        rvv_vec_inst_ready,

  //----------------------------------------------------------------------------
  // vset 写回 (标量 rd = 新 vl)
  //----------------------------------------------------------------------------
  output wire        rvv_idu_vset_wb_vld,
  output wire [5:0]  rvv_idu_vset_wb_preg,
  output wire [31:0] rvv_idu_vset_wb_data,
  output wire [6:0]  rvv_idu_vset_wb_iid,

  //----------------------------------------------------------------------------
  // RTU
  //----------------------------------------------------------------------------
  output wire        cmplt_vld1,
  output wire [6:0]  cmplt_iid1,
  output wire        cmplt_vld2,
  output wire [6:0]  cmplt_iid2,
  input  wire        rtu_commit0,
  input  wire        rtu_commit1,
  input  wire        rtu_commit2,
  input  wire [6:0]  rtu_commit_iid0,
  input  wire [6:0]  rtu_commit_iid1,
  input  wire [6:0]  rtu_commit_iid2,
  input  wire        rtu_flush,

  //----------------------------------------------------------------------------
  // 异常 (S5 实现)
  //----------------------------------------------------------------------------
  output wire        rvv_expt_vld,
  output wire [6:0]  rvv_expt_iid,
  output wire [4:0]  rvv_expt_cause,       // 恒 5'd2
  output wire [31:0] rvv_expt_tval,

  //----------------------------------------------------------------------------
  // 状态 / 调试
  //----------------------------------------------------------------------------
  output wire        rvv_idle,
  output wire        rvv_trap_valid,
  output wire [31:0] rvv_trap_inst,

  //----------------------------------------------------------------------------
  // 向量 LSU (S8 接)
  //----------------------------------------------------------------------------
  output wire        rvv_lsu_uop_valid,
  output wire UOP_RVV2LSU_t rvv_lsu_uop,
  input  wire        rvv_lsu_uop_ready,
  input  wire        rvv_lsu_resp_valid,
  input  wire UOP_LSU2RVV_t rvv_lsu_resp,
  output wire        rvv_lsu_resp_ready
);

  wire rstn = ~rst;

  //==========================================================
  //             Core <-> Bridge 内部信号
  //==========================================================
  // ⚠️ RvvCore 的 N 维端口是**packed 数组**:
  //      inst_data[N-1:0] / reg_read_data[2N-1:0] / ...
  //    必须用同样形状的 packed 数组声明 (unpacked 数组 VCS 会报 PCTM)。
  logic                core_inst_valid;        // logic [0:0]
  RVVInstruction [0:0] core_inst_data;
  logic                core_inst_ready;
  logic [1:0]          core_reg_read_valid;    // {src1, src0}
  logic [1:0][31:0]    core_reg_read_data;
  logic [0:0][31:0]    core_freg_read_data;
  logic                core_reg_write_valid;   // [0:0]
  logic [0:0][4:0]     core_reg_write_addr;
  logic [0:0][31:0]    core_reg_write_data;
  logic                core_trap_valid;
  RVVInstruction       core_trap_data;
  logic                core_rvv_idle;
  RVVConfigState [0:0] core_cmd_config_state;

  // ---- S4: core 的完成 / 提交 / flush 接口 ----
  logic        core_cmplt_valid;
  logic [6:0]  core_cmplt_iid;
  logic [6:0]  core_rob_head_tag;
  logic        core_rob_head_valid;
  logic        core_wr_vxsat_valid;
  logic        core_wr_vxsat;

  // ---- S4: 提交水位 (bridge 寄存成电平) ----
  logic        wmk_valid_q;
  logic [6:0]  wmk_iid_q;
  // ---- S4: flush 收敛 ----
  logic        flush_wmk_valid_q;   // 冲刷开始时冻结的水位
  logic [6:0]  flush_wmk_iid_q;
  logic        flush_pending;
  logic [2:0]  flush_drain_cnt;
  logic        core_flush;          // 收敛后给 core 的单拍全局清空 (同时恢复配置)
  // ---- S4: vxsat 回存 ----
  logic        vxsat_q;

  // ---- S4: vset 配置快照 FIFO (声明提前: ready 里要用 cfg_cnt) ----
  // 深度 16: 已完成但未提交的 vset 个数上限不确定 (A910 的 ROB/队列深度)，
  // 所以再加**满反压** (见 rvv_vec_inst_ready)，保证永不丢表项。
  localparam CFG_FIFO_DEPTH = 16;
  logic [3:0]      cfg_wr_ptr;
  logic [3:0]      cfg_rd_ptr;
  logic [4:0]      cfg_cnt;
  logic [6:0]      cfg_iid_mem   [0:CFG_FIFO_DEPTH-1];
  RVVConfigState   cfg_state_mem [0:CFG_FIFO_DEPTH-1];
  RVVConfigState   committed_cfg;
  wire cfg_fifo_near_full = (cfg_cnt >= 5'(CFG_FIFO_DEPTH-1));

  // 冲刷收敛期间关闭指令入口 (valid 与 ready 必须一起夹)
  wire         inst_entry_en = !flush_pending && !rtu_flush;

  // ---- S8: 向量 LSU 通路 (只接 lane0) ----
  logic          [1:0]        core_lsu_valid;
  logic          [1:0]        core_lsu_idx_valid;
  logic          [1:0][4:0]   core_lsu_idx_addr;
  logic          [1:0][127:0] core_lsu_idx_data;
  logic          [1:0]        core_lsu_vreg_valid;
  logic          [1:0][4:0]   core_lsu_vreg_addr;
  logic          [1:0][127:0] core_lsu_vreg_data;
  logic          [1:0]        core_lsu_v0_valid;
  logic          [1:0][15:0]  core_lsu_v0_data;
  logic          [1:0][6:0]   core_lsu_rob_tag;
  logic          [1:0][4:0]   core_lsu_uop_index;
  logic          [1:0][2:0]   core_lsu_lsu_id;
  logic          [1:0][2:0]   core_lsu_lsid;
  logic          [1:0]        core_lsu_first;
  logic          [1:0]        core_lsu_last;
  logic          [1:0]        core_lsu_is_store;
  LSU_TYPE_t     [1:0]        core_lsu_type;
  EEW_e          [1:0]        core_lsu_vd_eew;
  EEW_e          [1:0]        core_lsu_vs2_eew;
  logic          [1:0][`VL_WIDTH-1:0]     core_lsu_vl;
  logic          [1:0][`VSTART_WIDTH-1:0] core_lsu_vstart;
  logic          [1:0][4:0]   core_lsu_dst_idx;
  logic          [1:0][31:0]  core_lsu_rs1_data;
  logic          [1:0]        core_lsu_rs1_vld;
  logic          [1:0][31:0]  core_lsu_rs2_data;
  logic          [1:0]        core_lsu_rs2_vld;
  logic          [1:0][2:0]   core_lsu_seg_idx;
  logic          [1:0]        core_lsu_resp_ready;
  UOP_RVV2LSU_t               core_lsu_uop;
  UOP_LSU2RVV_t               core_lsu_resp;

  // ---- S5: 非法指令异常出口 ----
  // core 的两条"退休信息"通路:
  //   [NUM_RT_UOP-1:0]                  内部 ROB 的退休 (F2 用槽 0)
  //   [NUM_RT_UOP +: NUM_DE_INST]       后端解不出的指令 (de2rt, F1)
  logic [`NUM_RT_UOP+`NUM_DE_INST-1:0]     core_rd_valid_rob2rt;
  ROB2RT_t [`NUM_RT_UOP+`NUM_DE_INST-1:0]  core_rd_rob2rt;
  logic                                    core_async_rd_valid;

  // 按 iid 记录"这条指令的原始指令字", 供 F1/F2/F3 查 tval。
  // ⚠️ bridge 只收到 inst[31:7], 低 7 位 opcode 必须自己补回。
  typedef struct packed {
    logic        vld;
    logic [31:0] inst;
  } accepted_inst_t;
  accepted_inst_t accepted_inst_tbl [0:127];
  // 每个 iid 只报一次异常 (de2rt 的 valid 可能连续多拍不撤)。
  // accept 一条新指令 (iid 复用) 时清; 冲刷时**不清** —— 见 S5 注释。
  logic [127:0] expt_done;

  // inst[6:0] opcode ← bridge 的 2 位类别
  function automatic logic [6:0] opcode7_of (input logic [1:0] op);
    opcode7_of = (op == 2'd0) ? 7'b0000111 :   // LOAD  (vle*)
                 (op == 2'd1) ? 7'b0100111 :   // STORE (vse*)
                                 7'b1010111;    // OP-V
  endfunction

  // 标量目的向量指令: vmv.x.s / vcpop.m / vfirst.m
  //   funct3=OPMVV(010), funct6=VWRXUNARY0(010000), vs1 = 0 / 16 / 17。
  // ⚠️ 不看 vm (inst[25]): 非法组合也必须拦, 否则会落进 core 的奇怪分支。
  function automatic logic is_scalar_dest_inst (input logic [31:0] inst);
    logic [4:0] vs1;
    vs1 = inst[19:15];
    is_scalar_dest_inst = (inst[6:0]   == 7'b1010111) &&   // OP-V
                          (inst[14:12] == 3'b010)    &&   // OPMVV
                          (inst[31:26] == 6'b010000) &&   // VWRXUNARY0
                          ((vs1 == 5'd0) || (vs1 == 5'd16) || (vs1 == 5'd17));
  endfunction

  //==========================================================
  //                  Instruction Entry
  //==========================================================
  // vset*: funct3 == 111 (bits[7:5] = inst[14:12])，且必须是三种合法编码之一
  // —— 与 RvvFrontEnd 里 is_setvl 的判据逐位一致 (vsetvli / vsetivli / vsetvl)。
  // 放宽会往 vset FIFO 里塞一条**永远不会完成**的表项 (frontend 不发
  // reg_write_valid)，卡死后面所有 vset 的写回。
  wire is_vset = (idu_vec_inst_opcode == 2'd2) &&
                 (idu_vec_inst_bits[7:5] == 3'b111) &&
                 ( (idu_vec_inst_bits[24]    == 1'b0)  ||   // vsetvli
                   (idu_vec_inst_bits[24:23] == 2'b11) ||   // vsetivli
                   (idu_vec_inst_bits[24:18] == 7'b1000000) // vsetvl
                 );

  // 完整指令字 (inst[31:7] + 补回的低 7 位 opcode)
  wire [31:0] accept_inst_word = {idu_vec_inst_bits, opcode7_of(idu_vec_inst_opcode)};

  // S5 F0: 标量目的向量指令**入口拦下**, 不进 core。
  // 若放进去, 它们会正常完成并触发 cmplt_vld1 ⇒ A910 可能先提交、后收到异常,
  // 异常就丢了。
  wire is_scalar_dest = is_scalar_dest_inst(accept_inst_word);

  // S4: 冲刷收敛期间不再向 core 送新指令。
  // 同拍也把 rtu_flush 本身夹进去 —— 冲刷那拍 core 可能还能收一条，
  // 收进来也只是等 core_flush 清掉，不如从一开始就挡住。
  assign core_inst_valid          = idu_vec_inst_valid && inst_entry_en && !is_scalar_dest;
  assign core_inst_data[0].rob_tag = idu_vec_inst_iid;
  assign core_inst_data[0].lsid    = idu_vec_lsid;
  assign core_inst_data[0].pc      = idu_vec_inst_pc;
  assign core_inst_data[0].opcode  = RVVOpCode'(idu_vec_inst_opcode);
  assign core_inst_data[0].bits    = idu_vec_inst_bits;

  // ⚠️ ready 必须一起夹 (inst_entry_en, 声明见上): IDU 的 VIQ 真正的 pop =
  //    issue_en && rvv_vec_inst_ready (ct_idu_vecq.sv:179/:196)。只挡 valid
  //    不挡 ready ⇒ VIQ 以为被收下了，照常 pop ⇒ 指令静默丢失。
  // ⚠️ vset 还要额外做"配置 FIFO 将满"反压: cfg 表项在 vset **完成**时才 push，
  //    满了会静默丢状态 ⇒ 冲刷后的配置恢复错。压住 vset 的 ready 即可 ——
  //    已完成的那批 vset 还能照常提交 (cmplt_vld2 已发) ⇒ 一定能腾出空间。
  // ⚠️ 标量目的指令绕开 core_inst_ready (不进 core), 但**必须**仍受
  //    inst_entry_en 夹: 冲刷收敛期间不能报异常 (目标指令本来就要被冲掉)。
  assign rvv_vec_inst_ready = inst_entry_en &&
                              (is_scalar_dest
                                 ? 1'b1
                                 : (core_inst_ready && !(is_vset && cfg_fifo_near_full)));
  wire   accept                 = idu_vec_inst_valid && rvv_vec_inst_ready;

  //==========================================================
  //        reg_read_data 影子 (accept 后一拍对齐)
  //==========================================================
  // RvvFrontEnd 在 accept 后一拍才译码 inst_q, 并在这拍用 reg_read_data_i。
  // 所以这里必须把 accept 那拍的源数据寄存一拍。
  logic        acc_src0_vld_q;
  logic [31:0] acc_src0_data_q;
  logic        acc_src1_vld_q;
  logic [31:0] acc_src1_data_q;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      acc_src0_vld_q  <= 1'b0;
      acc_src0_data_q <= 32'd0;
      acc_src1_vld_q  <= 1'b0;
      acc_src1_data_q <= 32'd0;
    end
    else if (accept) begin
      acc_src0_vld_q  <= idu_vec_src0_vld;
      acc_src0_data_q <= idu_vec_src0_data;
      acc_src1_vld_q  <= idu_vec_src1_vld;
      acc_src1_data_q <= idu_vec_src1_data;
    end
  end

  assign core_reg_read_valid    = {acc_src1_vld_q, acc_src0_vld_q};
  assign core_reg_read_data[0]  = acc_src0_data_q;
  assign core_reg_read_data[1]  = acc_src1_data_q;
  assign core_freg_read_data[0] = 32'd0;

  //==========================================================
  //        vset 完成 FIFO (按 accept 顺序配 iid)
  //==========================================================
  // 深度 4: vset 在 accept 后一拍就完成 (frontend 的 reg_write_valid_o),
  // 与 VIQ 同深足够。rd=x0 的 vset 也入 FIFO —— 要发 cmplt, 只是不写 PRF。
  localparam VSET_FIFO_DEPTH = 4;

  logic [1:0] vset_wr_ptr;
  logic [1:0] vset_rd_ptr;
  logic [2:0] vset_cnt;
  logic [6:0] vset_iid_mem  [0:VSET_FIFO_DEPTH-1];
  logic [5:0] vset_preg_mem [0:VSET_FIFO_DEPTH-1];
  logic       vset_dstv_mem [0:VSET_FIFO_DEPTH-1];

  wire vset_push = accept && is_vset;
  wire vset_pop  = core_reg_write_valid && (vset_cnt != 3'd0);

  assign rvv_idu_vset_wb_vld  = vset_pop && vset_dstv_mem[vset_rd_ptr];
  assign rvv_idu_vset_wb_preg = vset_preg_mem[vset_rd_ptr];
  assign rvv_idu_vset_wb_data = core_reg_write_data[0];
  assign rvv_idu_vset_wb_iid  = vset_iid_mem[vset_rd_ptr];

  // vset 完成脉冲: 不管 dst_vld, 都要让 A910 的 ROB 表项完成。
  // S5 起完成脉冲统一走下方的汇总 FIFO (vset_pop 作为 push 源), 这里不再直接assign
  // cmplt_vld2 —— 否则会和 FIFO 输出打架 (双驱动)。

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      vset_wr_ptr <= 2'd0;
      vset_rd_ptr <= 2'd0;
      vset_cnt    <= 3'd0;
    end
    else if (rtu_flush) begin
      vset_wr_ptr <= 2'd0;
      vset_rd_ptr <= 2'd0;
      vset_cnt    <= 3'd0;
    end
    else begin
      if (vset_push) begin
        vset_iid_mem[vset_wr_ptr]  <= idu_vec_inst_iid;
        vset_preg_mem[vset_wr_ptr] <= idu_vec_dst_preg;
        vset_dstv_mem[vset_wr_ptr] <= idu_vec_dst_vld;
        vset_wr_ptr <= vset_wr_ptr + 2'd1;
      end
      if (vset_pop) begin
        vset_rd_ptr <= vset_rd_ptr + 2'd1;
      end
      vset_cnt <= vset_cnt + {2'b0, vset_push} - {2'b0, vset_pop};
    end
  end

  //==========================================================
  //        S4: 提交水位 + 完成脉冲 + flush 收敛 + 配置恢复
  //==========================================================
  // 年龄比较: 与 mySoC/rtu/rtl/RTU_iid_cmp.v 同规则 (只用于退休门控慢路径)。
  function automatic logic iid_older7 (input logic [6:0] a, input logic [6:0] b);
    iid_older7 = (a[6] ^ b[6]) ? (a[5:0] > b[5:0]) : (a[5:0] < b[5:0]);
  endfunction

  // 提交广播: 三路里取**最年轻**的 (commit2 > commit1 > commit0)。
  // ⚠️ rtu_yy_xx_commit*_iid 是无条件寄存的"当拍窗口 iid"，必须和同拍的
  //    commit* 标志成对使用 (见 RTU.v:900-935 的注释) —— 这里正是成对采样。
  wire       commit_any      = rtu_commit0 | rtu_commit1 | rtu_commit2;
  wire [6:0] commit_youngest = rtu_commit2 ? rtu_commit_iid2 :
                               rtu_commit1 ? rtu_commit_iid1 :
                                             rtu_commit_iid0;

  // "含本拍提交"的水位: rtu_flush 那拍最后一次退休窗口的提交广播正好落地，
  // 冻结水位与 vset 配置扫描都必须用它 (用上一拍的值会漏掉最后一个窗口)。
  wire [6:0] flush_wmk_next_iid = commit_any ? commit_youngest : wmk_iid_q;
  wire       flush_wmk_next_vld = wmk_valid_q | commit_any;

  // 水位寄存成**电平**: 没有提交脉冲的拍水位仍然有效，否则已提交但还没 pop
  // 的表项会被误判成"未提交"而停住。
  // ⚠️ 冲刷时**不清水位**: A910 的 iid 单调前进，清除只会让门控短暂失效。
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      wmk_valid_q <= 1'b0;
      wmk_iid_q   <= 7'd0;
    end else if (commit_any) begin
      wmk_valid_q <= 1'b1;
      wmk_iid_q   <= commit_youngest;
    end
  end

  //==========================================================
  //        S5: 非法指令异常出口
  //        (入口过滤 F0 + 退休监视 F1/F2/F3 + 最旧者胜锦标赛)
  //==========================================================
  // 事实:
  //   * RvvCore.trap_valid_o 只覆盖 frontend 的 vill (F3);
  //   * 后端解不出的指令走 de2rt (F1) —— 不进 core ROB、**没有 cmplt**,
  //     不报异常就会把 A910 那一条永远卡住;
  //   * 标量目的指令 (vmv.x.s / vcpop.m / vfirst.m) 必须在入口拦下 (F0),
  //     否则它们会正常完成并先于异常提交到 A910。
  // 四个候选做"最旧者胜"锦标赛, 每拍最多报一条给 A910。更年轻的输家直接丢弃
  // 是安全的: 更老的异常触发 trap 后会把它们整批冲掉。

  // 异常不可在冲刷收敛期产生: 目标指令马上要被冲掉。
  wire expt_emit_en = !flush_pending && !rtu_flush;

  // ---- F0: 入口扫描 (主通路) ----
  wire        f0_vld  = accept && is_scalar_dest && expt_emit_en;
  wire [6:0]  f0_iid  = idu_vec_inst_iid;
  wire [31:0] f0_tval = accept_inst_word;

  // ---- F1: 后端解不出 (de2rt 的假退休记录, 在 rd_rob2rt_o 高位) ----
  // ⚠️ de2rt_valid 可能连续多拍为 1 ⇒ 必须按 iid 去重, 否则同一条反复 trap。
  // ⚠️ 两条 lane 取"新的里面更老的" (lane 0 程序序在前)。
  wire        de2rt0_vld = core_rd_valid_rob2rt[`NUM_RT_UOP];
  wire        de2rt1_vld = core_rd_valid_rob2rt[`NUM_RT_UOP+1];
  wire [6:0]  de2rt0_iid = core_rd_rob2rt[`NUM_RT_UOP].rob_tag;
  wire [6:0]  de2rt1_iid = core_rd_rob2rt[`NUM_RT_UOP+1].rob_tag;
  wire        f1_l0_new  = de2rt0_vld && !expt_done[de2rt0_iid];
  wire        f1_l1_new  = de2rt1_vld && !expt_done[de2rt1_iid];
  wire        f1_vld     = (f1_l0_new | f1_l1_new) && expt_emit_en;
  wire [6:0]  f1_iid     = f1_l0_new ? de2rt0_iid : de2rt1_iid;
  wire [31:0] f1_tval    = accepted_inst_tbl[f1_iid].inst;

  // ---- F2: 标量写回漏网 (兜底) ----
  // ⚠️ 与计划书原文的差异 (必读): 原文在 core 的 retire 级看
  //    `rd_valid_rob2rt_o[0] && async_rd_valid`。S4 已把 rd_valid_rob2rt
  //    提交门控 ⇒ 该写回只会在 A910 **提交之后**发生, 那时再报异常救不回来,
  //    而且 RTU_expt 会攥着一条永远对不上的 iid 压住后面的真异常。
  // ⇒ 把检查前移到**完成脉冲**处: 要发 cmplt 的这条指令若被认成标量目的,
  //   当场补一条异常即可 (完成脉冲照发 —— RTU 的 trap 需要完成位, 见下方 FIFO 注释)。
  //   它被 F0 误放进来时本来会正常完成; 现在异常比完成早一拍落地 ⇒ 不会先提交。
  //   (async_rd_valid 仍然接出来做不变量监视, 见下方 ASSERT_ON。)
  wire        cmplt_inst_vld       = accepted_inst_tbl[core_cmplt_iid].vld;
  wire [31:0] cmplt_inst           = accepted_inst_tbl[core_cmplt_iid].inst;
  wire        cmplt_is_scalar_dest = cmplt_inst_vld && is_scalar_dest_inst(cmplt_inst);
  wire        f2_vld  = core_cmplt_valid && cmplt_is_scalar_dest && expt_emit_en;
  wire [6:0]  f2_iid  = core_cmplt_iid;
  wire [31:0] f2_tval = cmplt_inst;

  // ---- F3: frontend vill ----
  // vset/vill 不进后端, 天然没有 cmplt; trap_valid 是 accept 后一拍的脉冲。
  wire        f3_new  = core_trap_valid && !expt_done[core_trap_data.rob_tag];
  wire        f3_vld  = f3_new && expt_emit_en;
  wire [6:0]  f3_iid  = core_trap_data.rob_tag;
  wire [31:0] f3_tval = {core_trap_data.bits, opcode7_of(core_trap_data.opcode)};

  // ---- 完成脉冲的"补发"请求 (每条非法指令必须补一个 cmplt, 见下方 FIFO 注释) ----
  wire        f0_push    = accept && is_scalar_dest;
  wire        f1_l0_push = f1_l0_new && expt_emit_en;
  wire        f1_l1_push = f1_l1_new && expt_emit_en;
  wire        f3_push    = f3_vld;

  // ---- 锦标赛: 最旧者胜 ----
  wire        pick_f0 = f0_vld & (~f1_vld | iid_older7(f0_iid, f1_iid));
  wire        pick_f1 = f1_vld & ~pick_f0;
  wire        w1_vld  = pick_f0 | pick_f1;
  wire [6:0]  w1_iid  = pick_f1 ? f1_iid  : f0_iid;
  wire [31:0] w1_tval = pick_f1 ? f1_tval : f0_tval;

  wire        pick_w1 = w1_vld & (~f2_vld | iid_older7(w1_iid, f2_iid));
  wire        pick_f2 = f2_vld & ~pick_w1;
  wire        w2_vld  = pick_w1 | pick_f2;
  wire [6:0]  w2_iid  = pick_f2 ? f2_iid  : w1_iid;
  wire [31:0] w2_tval = pick_f2 ? f2_tval : w1_tval;

  wire        pick_w2 = w2_vld & (~f3_vld | iid_older7(w2_iid, f3_iid));
  wire        pick_f3 = f3_vld & ~pick_w2;
  wire        expt_vld_in  = pick_w2 | pick_f3;
  wire [6:0]  expt_iid_in  = pick_f3 ? f3_iid  : w2_iid;
  wire [31:0] expt_tval_in = pick_f3 ? f3_tval : w2_tval;

  assign rvv_expt_vld   = expt_vld_in;
  assign rvv_expt_iid   = expt_iid_in;
  assign rvv_expt_cause = 5'd2;              // illegal instruction
  assign rvv_expt_tval  = expt_tval_in;

  //---- accepted_inst 表 (查 tval) + 去重位 ----
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      for (int i=0; i<128; i++)
        accepted_inst_tbl[i].vld <= 1'b0;
      expt_done <= '0;
    end else begin
      if (accept) begin
        accepted_inst_tbl[idu_vec_inst_iid].vld  <= 1'b1;
        accepted_inst_tbl[idu_vec_inst_iid].inst <= accept_inst_word;
        // iid 复用 ⇒ 清去重位
        expt_done[idu_vec_inst_iid] <= 1'b0;
      end
      if (core_flush) begin
        for (int i=0; i<128; i++)
          accepted_inst_tbl[i].vld <= 1'b0;
        // ⚠️ 冲刷时**不清** expt_done: de2rt 的脉冲可能跨冲刷继续为 1,
        //    清掉会让同一条已被冲掉的指令再报一次 (RTU_expt 攥着对不上的 iid)。
      end
      // 去重位在**补完成脉冲那一拍**就置上 (不是等异常真的发出): 每条指令的
      // 异常与完成都是一次性的; 若本拍输了锦标赛, 赢家 (更老) 的 trap 会把它
      // 整条冲掉, 不需要再报。
      if (f0_push)   expt_done[f0_iid]    <= 1'b1;
      if (f1_l0_push) expt_done[de2rt0_iid] <= 1'b1;
      if (f1_l1_push) expt_done[de2rt1_iid] <= 1'b1;
      if (f3_push)   expt_done[f3_iid]    <= 1'b1;
      // F2 (完成时才发现是标量目的): 完成脉冲由 core 源负责, 这里只记去重位
      if (expt_vld_in)
        expt_done[expt_iid_in] <= 1'b1;
    end
  end

  // 不变量监视: 标量目的指令绝不该走到 core 的退休级 (F0 已拦)。
  // S4 的提交门控下这条写回发生在提交之后, 所以它只能当监视用, 不能当异常源。
`ifdef ASSERT_ON
  always_ff @(posedge clk) begin
    if (!rst && core_async_rd_valid)
      $error("RVV bridge: scalar XRF write reached core retire (iid=%0d) - F0 filter failed",
             core_cmplt_iid);
  end
`endif

  //----------------------------------------------------------------------------
  // 完成脉冲汇总 FIFO —— 从 A910 完成口 1/2 每拍吐 2 条
  //----------------------------------------------------------------------------
  // ⚠️⚠️ 与计划书的关键差异 (必须理解):
  //    计划书说"非法指令的表项由 RTU 异常机制冲刷, 不需要 cmplt"。
  //    本仓的 RTU **不是这样**: `RTU_commit.v:194` 的 `ok0 = w0_vld & w0_cmplt & ...`,
  //    而 `trap_hit = expt_vld & okp0 & (iid==win_iid)` ⇒ **没有完成位就永远 trap
  //    不了**。BEU 的取指非对齐异常也是 expt 与 cmplt 同拍发的 (IU_beu_pipe.v:269)。
  //    ⇒ 每条非法指令都**必须补一个 cmplt**, 否则它会永远卡在 ROB 队头。
  //
  // 时序是安全的: 异常在 T 拍进 RTU_expt (寄存), 完成经本 FIFO 至少 T+1 才到
  // ROB (再寄存一拍) ⇒ trap 一定看得到异常, 不存在"先 cmplt 后异常"。
  //
  // 汇聚源:
  //   core : 内部 ROB 的完成链 (合法计算指令; 也兜住 F2 的"标量目的漏网")
  //   vset : vset 完成 (PRF 写回仍在 vset_pop 当拍, 这里只延迟 cmplt)
  //   f0   : 入口拦下的标量目的指令 (没进 core, 自己造完成)
  //   f1   : 后端解不出 (de2rt, 两条 lane)
  //   f3   : frontend vill
  // 每条指令最多贡献一次: core/vset 本来就是单脉冲, f0/f1/f3 用 expt_done 去重。
  // 容量 128 > A910 ROB(64) + 前/后端在飞窗口 ⇒ 不可能溢出, 不需要反压。
  localparam CMPLT_FIFO_DEPTH = 128;

  logic [5:0][6:0] cmplt_push_iid;
  logic [1:0][6:0] cmplt_pop_iid;
  logic [7:0]      cmplt_q_cnt;
  logic            cmplt_pop0, cmplt_pop1;

  assign cmplt_push_iid[0] = core_cmplt_iid;
  assign cmplt_push_iid[1] = vset_iid_mem[vset_rd_ptr];
  assign cmplt_push_iid[2] = idu_vec_inst_iid;
  assign cmplt_push_iid[3] = de2rt0_iid;
  assign cmplt_push_iid[4] = de2rt1_iid;
  assign cmplt_push_iid[5] = core_trap_data.rob_tag;

  multi_fifo #(
    .T            (logic [6:0]),
    .M            (6),
    .N            (2),
    .DEPTH        (CMPLT_FIFO_DEPTH),
    .ASYNC_RSTN   (1'b1),
    .CHAOS_PUSH   (1'b1),
    .FULL_PUSH    (1'b1)
  ) u_cmplt_fifo (
    .clk          (clk),
    .rst_n        (rstn),
    .push         ({f3_push, f1_l1_push, f1_l0_push, f0_push,
                    vset_pop, core_cmplt_valid}),
    .pushRdy      (),
    .datain       (cmplt_push_iid),
    .full         (),
    .almost_full  (),
    .pop          ({cmplt_pop1, cmplt_pop0}),
    .dataout      (cmplt_pop_iid),
    .empty        (),
    .almost_empty (),
    .clear        (1'b0),
    .fifo_data    (),
    .wptr         (),
    .rptr         (),
    .entry_count  (cmplt_q_cnt)
  );

  assign cmplt_pop0 = (cmplt_q_cnt != 8'd0);
  assign cmplt_pop1 = (cmplt_q_cnt >= 8'd2);

  // 完成口 1/2 (vset 与非法指令共用, 顺序无关 —— 只是置 done 位)
  assign cmplt_vld1 = cmplt_pop0;
  assign cmplt_iid1 = cmplt_pop_iid[0];
  assign cmplt_vld2 = cmplt_pop1;
  assign cmplt_iid2 = cmplt_pop_iid[1];

  //----------------------------------------------------------------------------
  // vset 的配置快照 FIFO: {iid, 完成后的架构状态}
  // (状态声明在文件头部 —— ready 里的满反压要用 cfg_cnt)
  //----------------------------------------------------------------------------
  // 深度 16 + 满反压: 已完成但未提交的 vset 个数上限取决于 A910 的 ROB/队列
  // 深度，不能只靠"core ROB 16 深"推 (vset 不进 core ROB)。满反压保证不丢。

  // push: vset 完成那一拍 (此时 core_cmd_config_state 就是这条 vset 之后的
  // 架构状态 —— fontend 的 inst_config_state[1] 含本拍指令的效果)。
  wire cfg_push = vset_pop;

  // pop: 队头那条 vset 已被 A910 提交 (水位覆盖它)。一拍一个足够 ——
  // 提交广播每拍最多覆盖 3 条，而本 FIFO 只是把延迟从 1 拍摊到几拍。
  wire cfg_head_committed = (cfg_cnt != 5'd0) && wmk_valid_q &&
                            (cfg_iid_mem[cfg_rd_ptr] == wmk_iid_q ||
                             iid_older7(cfg_iid_mem[cfg_rd_ptr], wmk_iid_q));
  wire cfg_pop = cfg_head_committed && !flush_pending && !rtu_flush;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      cfg_wr_ptr    <= 4'd0;
      cfg_rd_ptr    <= 4'd0;
      cfg_cnt       <= 5'd0;
      // 复位值 = frontend 的复位状态 (vill=1, 其余 0; RNU/SEW8/LMUL1 都是 0)。
      committed_cfg      <= '0;
      committed_cfg.vill <= 1'b1;
    end
    else if (rtu_flush) begin
      // 冲刷时: 先把 FIFO 里**已提交**的 vset 收进 committed_cfg，再把整条
      // FIFO 丢掉 —— 未提交的是被冲掉的推测性 vset。
      // (必须保留"已提交但还没 pop"的那一条: 完成→提交→pop 有 1 拍窗口。)
      // 比较用**含本拍提交**的水位 (flush_wmk_next_*): 最后一次退休窗口的
      // 提交广播就在 rtu_flush 这一拍落地，用上一拍的水位会漏掉它。
      for (int k=0; k<CFG_FIFO_DEPTH; k++) begin
        if (k < cfg_cnt) begin
          if (flush_wmk_next_vld &&
              (cfg_iid_mem[cfg_rd_ptr + 4'(k)] == flush_wmk_next_iid ||
               iid_older7(cfg_iid_mem[cfg_rd_ptr + 4'(k)], flush_wmk_next_iid))) begin
            committed_cfg <= cfg_state_mem[cfg_rd_ptr + 4'(k)];
          end
        end
      end
      cfg_wr_ptr <= 4'd0;
      cfg_rd_ptr <= 4'd0;
      cfg_cnt    <= 5'd0;
    end
    else begin
      if (cfg_push && (cfg_cnt != 5'(CFG_FIFO_DEPTH))) begin
        cfg_iid_mem[cfg_wr_ptr]   <= vset_iid_mem[vset_rd_ptr];
        cfg_state_mem[cfg_wr_ptr] <= core_cmd_config_state[0];
        cfg_wr_ptr <= cfg_wr_ptr + 4'd1;
      end
      if (cfg_pop) begin
        committed_cfg <= cfg_state_mem[cfg_rd_ptr];
        cfg_rd_ptr    <= cfg_rd_ptr + 4'd1;
      end
      cfg_cnt <= cfg_cnt + {4'd0, (cfg_push && (cfg_cnt != 5'(CFG_FIFO_DEPTH)))}
                         - {4'd0, cfg_pop};
    end
  end

  //----------------------------------------------------------------------------
  // flush 收敛状态机
  //----------------------------------------------------------------------------
  // rtu_flush 是 A910 的冲刷起点 (F1 拍, 单拍脉冲); core_flush 是收敛之后
  // 给 core 的全局清空。两者不是同一根。
  //
  // 顺序写死:
  //   1. rtu_flush: 挡住新指令, 冻结"已提交前缀"的水位;
  //   2. 等 core 的 ROB 头变成未提交 (已提交的表项都已 pop、VRF 已写完);
  //   3. 再等 3 拍让 retire→VRF 最后一级流完;
  //   4. 拉一拍 core_flush, 同拍 config_load_valid=1 恢复配置;
  //   5. 清 flush_pending。
  //
  // ⚠️ 冻结水位必须**含本拍提交**: rtu_yy_xx_commit* 是寄存输出，F1 这拍
  //    恰好落地"触发冲刷的那次退休窗口" (含误预测分支之前的所有指令)。
  //    少覆盖这一拍 ⇒ 那些指令在 core 里被当成未提交冲掉 ⇒ VRF 写丢失。
  // core ROB 头是否已经"全是未提交项"。
  // 注意用**冻结**水位比较: 冲刷后 A910 会继续提交新指令，它的 iid 会跳过
  // 被冲掉的区间；若用实时水位，被冲掉的 core 表项会被误判成已提交。
  wire core_head_committed =
      flush_wmk_valid_q && core_rob_head_valid &&
      (core_rob_head_tag == flush_wmk_iid_q ||
       iid_older7(core_rob_head_tag, flush_wmk_iid_q));
  wire core_drained = !core_head_committed;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      flush_pending     <= 1'b0;
      flush_drain_cnt   <= 3'd0;
      core_flush        <= 1'b0;
      flush_wmk_valid_q <= 1'b0;
      flush_wmk_iid_q   <= 7'd0;
    end else begin
      core_flush <= 1'b0;   // 单拍脉冲
      if (rtu_flush) begin
        flush_pending   <= 1'b1;
        flush_drain_cnt <= 3'd0;
        // ⚠️ 只在**第一次**冲刷时冻结水位: 收敛期间 A910 会继续提交新指令，
        // 它们的 iid 会跳过被冲掉的区间；若这时重新冻结，被冲掉的 core 表项
        // 会被误判成"已提交"而写进架构 VRF (coralnpu 的 VRF 没有重命名)。
        if (!flush_pending) begin
          flush_wmk_valid_q <= flush_wmk_next_vld;
          flush_wmk_iid_q   <= flush_wmk_next_iid;
        end
      end
      else if (flush_pending) begin
        if (!core_drained) begin
          flush_drain_cnt <= 3'd0;
        end
        else if (flush_drain_cnt != 3'd3) begin
          flush_drain_cnt <= flush_drain_cnt + 3'd1;
        end
        else begin
          core_flush    <= 1'b1;
          flush_pending <= 1'b0;
        end
      end
    end
  end

  // 收敛期间 core 看到的是冻结水位 (理由见 core_head_committed 的注释)。
  wire        core_wmk_valid = flush_pending ? flush_wmk_valid_q : wmk_valid_q;
  wire [6:0]  core_wmk_iid   = flush_pending ? flush_wmk_iid_q   : wmk_iid_q;

  // vxsat 回存: vxsat 的写回发生在**提交后**的 retire 级 (rd_valid_rob2rt
  // 已被提交门控)，所以这里直接采信。reset 值 = 架构 vxsat 的复位值 0。
  always_ff @(posedge clk or posedge rst) begin
    if (rst)
      vxsat_q <= 1'b0;
    else if (core_wr_vxsat_valid)
      vxsat_q <= core_wr_vxsat;
  end

  //==========================================================
  //                        RvvCore
  //==========================================================
  RvvCore #(.N(1)) u_rvv_core (
    .clk                              (clk),
    .rstn                             (rstn),

    .vstart                           ({`VSTART_WIDTH{1'b0}}),
    .vstart_valid                     (1'b0),
    .vxrm                             (2'b0),
    .vxsat                            (vxsat_q),
    .frm                              (3'b0),
    .flush                            (core_flush),

    .inst_valid                       (core_inst_valid),
    .inst_data                        (core_inst_data),
    .inst_ready                       (core_inst_ready),

    .reg_read_valid                   (core_reg_read_valid),
    .reg_read_data                    (core_reg_read_data),
    .freg_read_data                   (core_freg_read_data),

    .reg_write_valid                  (core_reg_write_valid),
    .reg_write_addr                   (core_reg_write_addr),
    .reg_write_data                   (core_reg_write_data),

    // S5: 标量写回只做不变量监视 (F0 已把这些指令拦在入口)
    .async_rd_valid                   (core_async_rd_valid),
    .async_rd_addr                    (),
    .async_rd_data                    (),
    .async_rd_ready                   (1'b1),

    .async_frd_valid                  (),
    .async_frd_addr                   (),
    .async_frd_data                   (),
    .async_frd_ready                  (1'b1),

    // LSU: S6 只在 core 内部把接口做完; 到 A910 LSU 还要 S8 的 fill 引擎。
    // 现在把 LSU 的 ready/响应钉住 ⇒ 向量 L/S uop 会停在 core 的 LSU RS 里
    // (只影响仿真, 不影响 elaborate)。
    // 2026-10-17 S8: 只接 lane0 (计划 §10.9)
    .uop_lsu_valid_rvv2lsu            (core_lsu_valid),
    .uop_lsu_idx_valid_rvv2lsu        (core_lsu_idx_valid),
    .uop_lsu_idx_addr_rvv2lsu         (core_lsu_idx_addr),
    .uop_lsu_idx_data_rvv2lsu         (core_lsu_idx_data),
    .uop_lsu_vregfile_valid_rvv2lsu   (core_lsu_vreg_valid),
    .uop_lsu_vregfile_addr_rvv2lsu    (core_lsu_vreg_addr),
    .uop_lsu_vregfile_data_rvv2lsu    (core_lsu_vreg_data),
    .uop_lsu_v0_valid_rvv2lsu         (core_lsu_v0_valid),
    .uop_lsu_v0_data_rvv2lsu          (core_lsu_v0_data),
    .uop_lsu_rob_tag_rvv2lsu          (core_lsu_rob_tag),
    .uop_lsu_uop_index_rvv2lsu        (core_lsu_uop_index),
    .uop_lsu_lsu_id_rvv2lsu           (core_lsu_lsu_id),
    .uop_lsu_lsid_rvv2lsu             (core_lsu_lsid),
    .uop_lsu_first_rvv2lsu            (core_lsu_first),
    .uop_lsu_last_rvv2lsu             (core_lsu_last),
    .uop_lsu_is_store_rvv2lsu         (core_lsu_is_store),
    .uop_lsu_type_rvv2lsu             (core_lsu_type),
    .uop_lsu_vd_eew_rvv2lsu           (core_lsu_vd_eew),
    .uop_lsu_vs2_eew_rvv2lsu          (core_lsu_vs2_eew),
    .uop_lsu_vl_rvv2lsu               (core_lsu_vl),
    .uop_lsu_vstart_rvv2lsu           (core_lsu_vstart),
    .uop_lsu_dst_index_rvv2lsu        (core_lsu_dst_idx),
    .uop_lsu_rs1_data_rvv2lsu         (core_lsu_rs1_data),
    .uop_lsu_rs1_vld_rvv2lsu          (core_lsu_rs1_vld),
    .uop_lsu_rs2_data_rvv2lsu         (core_lsu_rs2_data),
    .uop_lsu_rs2_vld_rvv2lsu          (core_lsu_rs2_vld),
    .uop_lsu_seg_index_rvv2lsu        (core_lsu_seg_idx),
    .uop_lsu_ready_lsu2rvv            ({1'b0, rvv_lsu_uop_ready}),

    .uop_lsu_valid_lsu2rvv            ({1'b0, rvv_lsu_resp_valid}),
    .uop_lsu_addr_lsu2rvv             ({5'd0, rvv_lsu_resp.vregfile_write_addr}),
    .uop_lsu_wdata_lsu2rvv            ({128'd0, rvv_lsu_resp.vregfile_write_data}),
    .uop_lsu_last_lsu2rvv             ({1'b0, rvv_lsu_resp.lsu_vstore_last}),
    .uop_lsu_ff_tail_index_lsu2rvv    ({5'd0, rvv_lsu_resp.ff_tail_index}),
    .uop_lsu_rob_tag_lsu2rvv          ({7'd0, rvv_lsu_resp.rob_tag}),
    .uop_lsu_uop_index_lsu2rvv        ({5'd0, rvv_lsu_resp.uop_index}),
    .uop_lsu_lsu_id_lsu2rvv           ({3'd0, rvv_lsu_resp.lsu_id}),
    .uop_lsu_ready_rvv2lsu            (core_lsu_resp_ready),

    .vcsr_valid                       (),
    .vector_csr                       (),
    .vcsr_ready                       (1'b1),

    .config_state_valid               (),
    .config_state                     (),
    .next_config_mtype_o              (),

    .rvv_idle                         (core_rvv_idle),
    .queue_capacity                   (),

    // S5: F1 看高位 (de2rt), 低位是内部 ROB 的退休信息
    .rd_rob2rt_o                      (core_rd_rob2rt),
    .rd_valid_rob2rt_o                (core_rd_valid_rob2rt),

    .trap_valid_o                     (core_trap_valid),
    .trap_data_o                      (core_trap_data),

    .wr_vxsat_valid_o                 (core_wr_vxsat_valid),
    .wr_vxsat_o                       (core_wr_vxsat),
    .wr_fflags_valid_o                (),
    .wr_fflags_o                      (),

    // S3 预留 / S4 接通的 A910 接口
    .cmd_config_state_o               (core_cmd_config_state),
    .config_load_valid_i              (core_flush),      // 与 core_flush 同拍
    .config_load_data_i               (committed_cfg),
    .cmt_wmk_valid_i                  (core_wmk_valid),
    .cmt_wmk_iid_i                    (core_wmk_iid),
    .inst_cmplt_valid_o               (core_cmplt_valid),
    .inst_cmplt_iid_o                 (core_cmplt_iid),
    .rob_head_rob_tag_o               (core_rob_head_tag),
    .rob_head_valid_o                 (core_rob_head_valid)
  );

  //==========================================================
  //                   状态 / 调试输出
  //==========================================================
  assign rvv_idle        = core_rvv_idle;
  assign rvv_trap_valid  = core_trap_valid;
  assign rvv_trap_inst   = {core_trap_data.bits, 7'b1010111};

  // 异常出口在文件上半部 "S5: 非法指令异常出口" 一节驱动 (rvv_expt_*)。

  //==========================================================
  // S8: 向量 LSU uop 装配 / 响应拆解 (只接 lane0)
  //==========================================================
  assign rvv_lsu_uop_valid  = core_lsu_valid[0];
  assign rvv_lsu_resp_ready = core_lsu_resp_ready[0];

  always_comb begin
    core_lsu_uop = '0;
    core_lsu_uop.rob_tag           = core_lsu_rob_tag[0];
    core_lsu_uop.uop_index         = core_lsu_uop_index[0];
    core_lsu_uop.first_uop_valid   = core_lsu_first[0];
    core_lsu_uop.last_uop_valid    = core_lsu_last[0];
    core_lsu_uop.lsu_is_store      = core_lsu_is_store[0];
    core_lsu_uop.lsu_type          = core_lsu_type[0];
    core_lsu_uop.vd_eew            = core_lsu_vd_eew[0];
    core_lsu_uop.vs2_eew           = core_lsu_vs2_eew[0];
    core_lsu_uop.vl                = core_lsu_vl[0];
    core_lsu_uop.vstart            = core_lsu_vstart[0];
    core_lsu_uop.dst_index         = core_lsu_dst_idx[0];
    core_lsu_uop.rs1_data          = core_lsu_rs1_data[0];
    core_lsu_uop.rs1_data_valid    = core_lsu_rs1_vld[0];
    core_lsu_uop.rs2_data          = core_lsu_rs2_data[0];
    core_lsu_uop.rs2_data_valid    = core_lsu_rs2_vld[0];
    core_lsu_uop.seg_field_index   = core_lsu_seg_idx[0];
    core_lsu_uop.lsu_id            = core_lsu_lsu_id[0];
    core_lsu_uop.lsid              = core_lsu_lsid[0];
    core_lsu_uop.vidx_valid        = core_lsu_idx_valid[0];
    core_lsu_uop.vidx_addr         = core_lsu_idx_addr[0];
    core_lsu_uop.vidx_data         = core_lsu_idx_data[0];
    core_lsu_uop.vregfile_read_valid = core_lsu_vreg_valid[0];
    core_lsu_uop.vregfile_read_addr  = core_lsu_vreg_addr[0];
    core_lsu_uop.vregfile_read_data  = core_lsu_vreg_data[0];
    core_lsu_uop.v0_valid          = core_lsu_v0_valid[0];
    core_lsu_uop.v0_data           = core_lsu_v0_data[0];
  end
  assign rvv_lsu_uop = core_lsu_uop;

endmodule
