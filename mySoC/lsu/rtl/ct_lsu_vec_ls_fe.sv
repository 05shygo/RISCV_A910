// =============================================================================
// ct_lsu_vec_ls_fe.sv —— 向量 Load/Store 直连前端 (2026-10-18)
//
// 职责:
//   1. 接收 IDU fill 引擎发来的向量访存请求 (16B 对齐块), 进一个小 FIFO,
//      允许不同 uop 的 beat 同时在飞 (同一 uop 的串行由 fill 保证)。
//   2. 队头按 load/store 驱动 dcache_arb 的 VEC 源 (tag / data / dirty 查询),
//      并在下一拍把请求注入 ld_dc / st_dc (绕过 AG)。
//   3. dcache 仲裁未获授权、DC/DA restart 时原地保持并重发; 只有 load
//      走完 ld DA 或 store 走完 st DA 才弹出队头 (restart 时留在队头重试)。
//   4. 2026-10-18: 资源类 stall (LQ full / MSHR full / SQ full) 按队头
//      fill_id 进入休眠, 对应资源空出后唤醒; 冲突/discard 直接下一拍重试。
//
// 时序约定:
//   * 请求在周期 N 获得 vec_*_sel, 周期 N+1 dc_valid 单拍脉冲, DC 级锁存
//     字段, 周期 N+2 到 DA 完成/restart。
//   * outstanding 期间 (含请求在 DC/DA 中) 不再发下一笔, 避免重复建
//     LQ/MSHR/SQ; 也保证 DA restart 能按 fill_id 对回队头。
// =============================================================================

module ct_lsu_vec_ls_fe #(
  parameter int DEPTH            = 8,
  parameter int INDEX_WIDTH      = 5,
  parameter int DATA_INDEX_WIDTH = 6
)(
  input  logic         clk,
  input  logic         rst_b,
  input  logic         vec_ls_flush,

  //----------------------------------------------------------------------------
  // fill -> FE
  //----------------------------------------------------------------------------
  input  logic         req_valid,
  output logic         req_ready,
  input  logic         req_store,
  input  logic         req_nop,
  input  logic         req_last,        // 最后一笔 (驱动 LSIQ pop)
  input  logic [31:0]  req_addr,        // 16B 对齐块地址
  input  logic [15:0]  req_bytes_vld,   // 相对 16B 块的字节掩码
  input  logic [31:0]  req_wdata,       // store 数据, 已放在最终字节道
  input  logic [2:0]   req_lsid,
  input  logic [4:0]   req_fill_id,
  input  logic [4:0]   req_uop_idx,
  input  logic [4:0]   req_beat_idx,
  input  logic [6:0]   req_iid,

  //----------------------------------------------------------------------------
  // dcache_arb VEC 源
  //----------------------------------------------------------------------------
  output logic         vec_ld_req,
  output logic [INDEX_WIDTH-1:0]      vec_ld_tag_idx,
  output logic [7:0]                  vec_ld_data_req,
  output logic [DATA_INDEX_WIDTH-1:0] vec_ld_data_low_idx,
  output logic [DATA_INDEX_WIDTH-1:0] vec_ld_data_high_idx,
  output logic         vec_st_req,
  output logic [INDEX_WIDTH-1:0]      vec_st_tag_idx,
  output logic [INDEX_WIDTH-1:0]      vec_st_dirty_idx,
  input  logic         vec_ld_sel,
  input  logic         vec_st_sel,

  //----------------------------------------------------------------------------
  // DC 注入 (绕过 AG)
  //----------------------------------------------------------------------------
  output logic         dc_valid,
  output logic         dc_store,
  output logic         dc_nop,
  output logic         dc_last,
  output logic [31:0]  dc_addr,
  output logic [15:0]  dc_bytes_vld,
  output logic [31:0]  dc_wdata,
  output logic [2:0]   dc_lsid,
  output logic [4:0]   dc_fill_id,
  output logic [4:0]   dc_uop_idx,
  output logic [4:0]   dc_beat_idx,
  output logic [6:0]   dc_iid,

  //----------------------------------------------------------------------------
  // 完成 / 重试
  //----------------------------------------------------------------------------
  // 2026-10-18: load 在这里是"走完 ld DA"(不是 DC→DA)。DA 重放时请求仍留在
  // 队头, 因此 sleep 状态和 fill_id 都还能对得上。
  input  logic         ld_accept,             // ld_da_vec_done
  input  logic         ld_restart,
  input  logic [4:0]   ld_restart_fill_id,
  input  logic         ld_restart_lq_full,    // LQ 满 → 休眠
  input  logic         ld_restart_rb_full,    // MSHR 满 → 休眠
  input  logic         ld_restart_imme,       // 冲突 / discard → 立即重试
  input  logic         st_accept,             // st_da_vec_done
  input  logic         st_restart,
  input  logic [4:0]   st_restart_fill_id,
  input  logic         st_restart_sq_full,    // SQ 满 → 休眠
  input  logic         st_restart_imme,       // 其他 → 立即重试

  // 资源唤醒 (按队头 fill_id 对应)
  input  logic         ld_lq_not_full,
  input  logic         ld_mshr_not_full,
  input  logic         st_sq_not_full,

  // 请求被 LSU 接受 (load 进 DA / store 进 SQ) 的完成脉冲 —— fill 用它释放
  // nop / store 的 request (load 的数据仍走 rsp 通道)
  output logic         req_done_vld,
  output logic [4:0]   req_done_fill_id
);

localparam int PTR_W = $clog2(DEPTH);

typedef struct packed {
  logic        store;
  logic        nop;
  logic        last;
  logic [31:0] addr;
  logic [15:0] bytes_vld;
  logic [31:0] wdata;
  logic [2:0]  lsid;
  logic [4:0]  fill_id;
  logic [4:0]  uop_idx;
  logic [4:0]  beat_idx;
  logic [6:0]  iid;
} VEC_REQ_t;

VEC_REQ_t            q_mem [0:DEPTH-1];
logic [DEPTH-1:0]    q_vld;
logic [PTR_W-1:0]    q_wr;
logic [PTR_W-1:0]    q_rd;
logic [PTR_W:0]      q_cnt;
logic                outstanding;
// 获得 dcache_arb 授权后只注入 dc 一拍 (与 dcache 阵列读对齐); 之后请求
// 留在队头等 DC/DA 完成或 restart, 不能持续拉 dc_valid 重复注入。
logic                dc_pulse;
// 2026-10-18: 按 fill_id 的休眠/唤醒。队头同一时刻只有一笔在飞, 因此三组
// sleep 状态天然对应队头的 fill_id。
logic                sleep_lq;
logic                sleep_rb;
logic                sleep_sq;

VEC_REQ_t            head;
logic                head_vld;

wire                 push = req_valid && req_ready;
wire                 pop  = (head.store ? st_accept : ld_accept);

assign head      = q_mem[q_rd];
assign head_vld  = q_vld[q_rd];
assign req_ready = (q_cnt < DEPTH[PTR_W:0]) && !vec_ls_flush;

//----------------------------------------------------------------------------
// 休眠 / 唤醒: 只有队头一笔在飞, 用它的 fill_id 对齐 restart/wake。
//----------------------------------------------------------------------------
wire sleeping = sleep_lq | sleep_rb | sleep_sq;

wire ld_restart_this = outstanding && head_vld && ld_restart &&
                       (ld_restart_fill_id == head.fill_id);
wire st_restart_this = outstanding && head_vld && st_restart &&
                       (st_restart_fill_id == head.fill_id);

wire wake_lq = sleep_lq && ld_lq_not_full;
wire wake_rb = sleep_rb && ld_mshr_not_full;
wire wake_sq = sleep_sq && st_sq_not_full;
wire wake    = wake_lq | wake_rb | wake_sq;

//----------------------------------------------------------------------------
// 队头 -> dcache_arb
//----------------------------------------------------------------------------
wire [31:0] h_addr = head.addr;

assign vec_ld_req           = head_vld && !outstanding && !sleeping &&
                              !head.store && !vec_ls_flush;
assign vec_ld_tag_idx       = h_addr[9:5];
assign vec_ld_data_req      = {8{vec_ld_req}};
assign vec_ld_data_low_idx  = h_addr[9:4];
assign vec_ld_data_high_idx = {h_addr[9:5], ~h_addr[4]};

assign vec_st_req           = head_vld && !outstanding && !sleeping &&
                              head.store && !vec_ls_flush;
assign vec_st_tag_idx       = h_addr[9:5];
assign vec_st_dirty_idx     = h_addr[9:5];

wire grant = head_vld && !outstanding && !sleeping &&
             (head.store ? vec_st_sel : vec_ld_sel);

//----------------------------------------------------------------------------
// DC 注入: 获授权后的下一拍有效 (与 dcache 阵列同步读对齐)
//----------------------------------------------------------------------------
assign dc_valid     = dc_pulse && !vec_ls_flush;
assign dc_store     = head.store;
assign dc_nop       = head.nop;
assign dc_last      = head.last;
assign dc_addr      = head.addr;
assign dc_bytes_vld = head.bytes_vld;
assign dc_wdata     = head.wdata;
assign dc_lsid      = head.lsid;
assign dc_fill_id   = head.fill_id;
assign dc_uop_idx   = head.uop_idx;
assign dc_beat_idx  = head.beat_idx;
assign dc_iid       = head.iid;

// 只有当前 outstanding 对应的那一类完成才有意义
wire accept_now = (head.store ? st_accept : ld_accept);
wire restart_now = head.store ? st_restart_this : (ld_restart_this && !ld_accept);

assign req_done_vld     = accept_now;
assign req_done_fill_id = head.fill_id[4:0];

//----------------------------------------------------------------------------
// Queue
//----------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_b) begin
  if (!rst_b) begin
    q_vld       <= '0;
    q_wr        <= '0;
    q_rd        <= '0;
    q_cnt       <= '0;
    outstanding <= 1'b0;
    dc_pulse    <= 1'b0;
    sleep_lq    <= 1'b0;
    sleep_rb    <= 1'b0;
    sleep_sq    <= 1'b0;
  end
  else if (vec_ls_flush) begin
    q_vld       <= '0;
    q_wr        <= '0;
    q_rd        <= '0;
    q_cnt       <= '0;
    outstanding <= 1'b0;
    dc_pulse    <= 1'b0;
    sleep_lq    <= 1'b0;
    sleep_rb    <= 1'b0;
    sleep_sq    <= 1'b0;
  end
  else begin
    if (grant) begin
      outstanding <= 1'b1;
      dc_pulse    <= 1'b1;
    end
    else begin
      dc_pulse <= 1'b0;
      if (accept_now || (outstanding && restart_now))
        outstanding <= 1'b0;
    end

    // 资源空出 → 唤醒 (按队头 fill_id 隐含匹配, 同一时刻只有队头在飞)。
    if (wake) begin
      if (wake_lq) sleep_lq <= 1'b0;
      if (wake_rb) sleep_rb <= 1'b0;
      if (wake_sq) sleep_sq <= 1'b0;
    end

    // 休眠: 只有 LQ/MSHR/SQ 资源类 stall 才睡; 冲突/discard 走立即重试。
    if (restart_now) begin
      if (!head.store) begin
        if (ld_restart_lq_full) sleep_lq <= 1'b1;
        if (ld_restart_rb_full) sleep_rb <= 1'b1;
      end
      else begin
        if (st_restart_sq_full) sleep_sq <= 1'b1;
      end
    end

    // 请求被接收后队头前移, 清掉所有 sleep 状态 (最后写, 优先级最高)。
    if (pop) begin
      sleep_lq <= 1'b0;
      sleep_rb <= 1'b0;
      sleep_sq <= 1'b0;
    end

    if (push) begin
      q_mem[q_wr] <= VEC_REQ_t'{
        store     : req_store,
        nop       : req_nop,
        last      : req_last,
        addr      : req_addr,
        bytes_vld : req_bytes_vld,
        wdata     : req_wdata,
        lsid      : req_lsid,
        fill_id   : req_fill_id,
        uop_idx   : req_uop_idx,
        beat_idx  : req_beat_idx,
        iid       : req_iid
      };
      q_vld[q_wr] <= 1'b1;
      q_wr        <= q_wr + PTR_W'(1);
    end

    if (pop) begin
      q_vld[q_rd] <= 1'b0;
      q_rd        <= q_rd + PTR_W'(1);
    end

    unique case ({push, pop})
      2'b10: q_cnt <= q_cnt + 1'b1;
      2'b01: q_cnt <= q_cnt - 1'b1;
      default: q_cnt <= q_cnt;
    endcase
  end
end

endmodule
