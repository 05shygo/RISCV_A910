`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

// ---------------------------------------------------------------------------
// rvv_backend_lsu_remap — LSU uop ⇄ LSU 响应的配对 (2026-10-17 S6 重写)
//
// **旧实现**：mapinfo FIFO 与 lsu_res FIFO 按**同一下标**配对，隐含"LSU 按序
//   返回"。A910 侧是多 beat、可以乱序/交错返回的，必须改成按 key 查表。
//
// **新实现**：8 项 scoreboard。
//   * uop 被 LSU 接收那一拍 (valid & ready)，从与 LSU RS **逐项对齐**的
//     mapinfo 旁路队列取表头，分配一个槽，把 {rob_entry, rob_tag, is_store,
//     write_addr, writes_rob} 记进去；同拍把槽号作为 `lsu_id` 送给 LSU。
//   * 响应带回 `lsu_id`，按它查槽 ⇒ 不再要求按序返回。
//   * 槽满时把 LSU 视野里的 `valid` 拉低 (反压)，uop 留在 RS 里 —— 绝不能
//     覆盖已有槽。
//   * 每个 core uop (包括不写 ROB 的中间 uop) 都会收到一个响应，都要靠槽号
//     消费；`writes_rob=0` 的槽只消费、不产生 ROB 写回。
// ---------------------------------------------------------------------------
module rvv_backend_lsu_remap
(
  clk,
  rst_n,
  flush,                  // 全局冲刷: 在飞的 LSU uop/响应全丢 ⇒ 槽必须一起清

  // ---- uop 出发侧 (S6 新增) ----
  lsu_req_valid,          // LSU RS 输出有效 (门控前)
  lsu_req_ready,          // LSU 的 ready
  mapinfo_valid,          // mapinfo 旁路队列表头有效
  mapinfo,                // mapinfo 旁路队列表头 (与 RS 逐项对齐)
  lsu_valid_o,            // 门控后的 valid → LSU
  lsu_id_o,               // 本拍这条 uop 分配的槽号
  pop_mapinfo,            // 本拍消费 mapinfo 表头

  // ---- 响应侧 ----
  lsu_res_valid,
  lsu_res,
  pop_lsu_res,

  // submit LSU result to ROB
  result_valid,
  result,
  ff_tail_index,
  result_ready,

  // submit trap to ROB
  trap_valid_rmp2rob,
  trap_rob_entry_rmp2rob,
  trap_ready_rob2rmp
);

//
// interface signals
//
  input   logic                           clk;
  input   logic                           rst_n;
  input   logic                           flush;
  input   logic           [`NUM_LSU-1:0]  lsu_req_valid;
  input   logic           [`NUM_LSU-1:0]  lsu_req_ready;
  input   logic           [`NUM_LSU-1:0]  mapinfo_valid;
  input   LSU_MAP_INFO_t  [`NUM_LSU-1:0]  mapinfo;
  output  logic           [`NUM_LSU-1:0]  lsu_valid_o;
  output  logic           [`NUM_LSU-1:0][2:0] lsu_id_o;
  output  logic           [`NUM_LSU-1:0]  pop_mapinfo;

  input   logic           [`NUM_LSU-1:0]  lsu_res_valid;
  input   UOP_LSU_t       [`NUM_LSU-1:0]  lsu_res;
  output  logic           [`NUM_LSU-1:0]  pop_lsu_res;

  // submit LSU result to ROB
  output  logic           [`NUM_LSU-1:0]                    result_valid;
  output  PU2ROB_t        [`NUM_LSU-1:0]                    result;
  output  logic           [`NUM_LSU-1:0][$clog2(`VLENB):0]  ff_tail_index;
  input   logic           [`NUM_LSU-1:0]                    result_ready;

  // submit trap to ROB
  output  logic                           trap_valid_rmp2rob;
  output  logic   [`ROB_DEPTH_WIDTH-1:0]  trap_rob_entry_rmp2rob;
  input   logic                           trap_ready_rob2rmp;

//
// internal signals
//
  localparam NUM_SS = 8;

  logic                         ss_valid      [0:NUM_SS-1];
  logic                         ss_writes_rob [0:NUM_SS-1];
  logic   [`ROB_DEPTH_WIDTH-1:0] ss_rob_entry [0:NUM_SS-1];
  logic   [`ROB_TAG_WIDTH-1:0]   ss_rob_tag   [0:NUM_SS-1];
  logic                         ss_is_store   [0:NUM_SS-1];
  logic   [`REGIDX_WIDTH-1:0]    ss_waddr      [0:NUM_SS-1];
  logic   [2:0]                  ss_lsu_id     [0:NUM_SS-1];
  logic   [2:0]                  lsu_slot_ptr;

  logic   [NUM_SS-1:0]           ss_used;
  logic   [`NUM_LSU-1:0]         lane_walk;     // 门控前的 lane 链
  logic   [`NUM_LSU-1:0]         aop_pre;       // 门控前"这一拍会被接收"
  logic   [2:0]                  slot_pick [0:`NUM_LSU-1];
  logic                          slot_found[0:`NUM_LSU-1];
  logic   [NUM_SS-1:0]           used_stage [0:`NUM_LSU-1];

// ---------------------------------------------------------------------------
// 槽搜索: 从 start 起绕一圈找第一个空闲; found=0 表示全忙
// ---------------------------------------------------------------------------
  function automatic logic [2:0] pick_free (input logic [NUM_SS-1:0] used,
                                            input logic [2:0]        start,
                                            output logic             found);
    logic [2*NUM_SS-1:0] used2;
    used2 = {used, used};
    found = 1'b0;
    pick_free = start;
    // 从大到小覆盖 ⇒ 最后写进的是 k 最小的那个 = 离 start 最近的空闲
    for (int j = NUM_SS-1; j >= 0; j--) begin
      if (!used2[start + j[2:0]]) begin
        pick_free = start + j[2:0];      // 3 位截断 = 自动回绕
        found     = 1'b1;
      end
    end
  endfunction

  always_comb begin
    for (int i=0; i<NUM_SS; i++)
      ss_used[i] = ss_valid[i];
  end

// ---------------------------------------------------------------------------
// 分配 / 反压
// ---------------------------------------------------------------------------
  genvar g;
  generate
  for (g=0; g<`NUM_LSU; g++) begin : gen_alloc
    if (g==0) begin : gen_l0
      // 与 backend 的 lane 链一致: lane0 只看自己
      assign lane_walk[0] = lsu_req_valid[0];
      assign aop_pre[0]   = lane_walk[0] & lsu_req_ready[0];
      assign used_stage[0]= ss_used;
    end else begin : gen_li
      assign lane_walk[g] = lane_walk[g-1] & lsu_req_ready[g-1] & lsu_req_valid[g];
      assign aop_pre[g]   = lane_walk[g] & lsu_req_ready[g];
      assign used_stage[g]= used_stage[g-1] |
                            ((slot_found[g-1] & lsu_valid_o[g-1])
                              ? (8'd1 << slot_pick[g-1]) : 8'd0);
    end
  end
  endgenerate

  always_comb begin
    for (int i=0; i<`NUM_LSU; i++) begin
      // 有 uop 要走却拿不到 mapinfo / 拿不到槽 ⇒ 拉低 valid (反压)
      // 注意: mapinfo 与 RS 逐项对齐, 正常情况下不会出现 !mapinfo_valid。
      slot_pick[i]  = pick_free(used_stage[i],
                                (i==0) ? lsu_slot_ptr : (slot_pick[i-1] + 3'd1),
                                slot_found[i]);
      lsu_valid_o[i] = lane_walk[i] &
                       (i==0 ? 1'b1 : lsu_valid_o[i-1]) &
                       (aop_pre[i] ? (mapinfo_valid[i] & slot_found[i]) : 1'b1);
      // 槽号: 这一拍真的被接收才是有效的
      lsu_id_o[i]    = slot_pick[i];
      pop_mapinfo[i] = lsu_valid_o[i] & lsu_req_ready[i];
    end
  end

// ---------------------------------------------------------------------------
// 槽表: 分配 (uop 被接收) / 释放 (响应回来)
// ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i=0; i<NUM_SS; i++) begin
        ss_valid[i]      <= 1'b0;
        ss_writes_rob[i] <= 1'b0;
        ss_rob_entry[i]  <= '0;
        ss_rob_tag[i]    <= '0;
        ss_is_store[i]   <= 1'b0;
        ss_waddr[i]      <= '0;
        ss_lsu_id[i]     <= '0;
      end
      lsu_slot_ptr <= 3'd0;
    end else if (flush) begin
      // 冲刷时 LSU uop / 响应一起被清 (RS/res FIFO 的 clear 是同一根),
      // 在飞的响应永远不会回来 ⇒ 槽必须全部释放, 否则会永久占死。
      for (int i=0; i<NUM_SS; i++)
        ss_valid[i] <= 1'b0;
      lsu_slot_ptr <= 3'd0;
    end else begin
      // ---- 释放: 响应被消费的那一拍 ----
      // (同拍分配不会选中一个 valid=1 的槽, 所以分配/释放不会撞同一个槽)
      for (int i=0; i<`NUM_LSU; i++) begin
        if (pop_lsu_res[i])
          ss_valid[lsu_res[i].uop_lsu2rvv.lsu_id] <= 1'b0;
      end
      // ---- 分配 ----
      for (int i=0; i<`NUM_LSU; i++) begin
        if (pop_mapinfo[i]) begin
          ss_valid[slot_pick[i]]      <= 1'b1;
          ss_writes_rob[slot_pick[i]] <= mapinfo[i].valid;
          ss_rob_entry[slot_pick[i]]  <= mapinfo[i].rob_entry;
          ss_rob_tag[slot_pick[i]]    <= mapinfo[i].rob_tag;
          ss_is_store[slot_pick[i]]   <= mapinfo[i].lsu_is_store;
          ss_waddr[slot_pick[i]]      <= mapinfo[i].vregfile_write_addr;
          ss_lsu_id[slot_pick[i]]     <= slot_pick[i];
        end
      end
      // ---- 分配指针 ----
      if (pop_mapinfo[`NUM_LSU-1])
        lsu_slot_ptr <= slot_pick[`NUM_LSU-1] + 3'd1;
      else if (pop_mapinfo[0])
        lsu_slot_ptr <= slot_pick[0] + 3'd1;
    end
  end

// ---------------------------------------------------------------------------
// 响应 → ROB
// ---------------------------------------------------------------------------
  logic [`NUM_LSU-1:0][2:0] res_id;
  logic [`NUM_LSU-1:0]      res_hit;

  always_comb begin
    for (int i=0; i<`NUM_LSU; i++) begin
      res_id[i]  = lsu_res[i].uop_lsu2rvv.lsu_id;
      // 自校验: 槽里的 lsu_id 必须与自己一致 (防槽被错误覆盖导致串数据)
      res_hit[i] = lsu_res_valid[i] & ss_valid[res_id[i]] &
                   (ss_lsu_id[res_id[i]] == res_id[i]);
    end
  end

  generate
    for(g=0;g<`NUM_LSU;g++) begin: GET_RESULT
      assign result_valid[g] = res_hit[g] & !lsu_res[g].trap_valid &
                               ss_writes_rob[res_id[g]] &
                               ( (!ss_is_store[res_id[g]]) & lsu_res[g].uop_lsu2rvv.vregfile_write_valid ||
                                  ss_is_store[res_id[g]] & lsu_res[g].uop_lsu2rvv.lsu_vstore_last );
    `ifdef TB_SUPPORT
      assign result[g].uop_pc    = lsu_res[g].uop_lsu2rvv.uop_pc;
    `endif
      assign result[g].rob_entry = ss_rob_entry[res_id[g]];
      assign result[g].w_data    = lsu_res[g].uop_lsu2rvv.vregfile_write_data;
      assign result[g].w_valid   = res_hit[g] & !lsu_res[g].trap_valid &
                                   !ss_is_store[res_id[g]] &
                                   lsu_res[g].uop_lsu2rvv.vregfile_write_valid &
                                   (lsu_res[g].uop_lsu2rvv.vregfile_write_addr == ss_waddr[res_id[g]]);
      assign result[g].vsaturate = 'b0;
    `ifdef ZVE32F_ON
      assign result[g].fpexp     = 'b0;
    `endif
      assign ff_tail_index[g]    = lsu_res[g].uop_lsu2rvv.ff_tail_index;
    end
  endgenerate

  always_comb begin
    trap_valid_rmp2rob    = 'b0;
    trap_rob_entry_rmp2rob = 'b0;
    for (int j=0;j<`NUM_LSU;j++) begin
      // 只有写 ROB 的 uop 才能把 trap 挂到某个表项上; 中间 uop 的 trap 没有
      // 可挂的 rob_entry (mapinfo.valid=0), 丢弃。
      if (res_hit[j] & lsu_res[j].trap_valid & ss_writes_rob[res_id[j]]) begin
        trap_valid_rmp2rob     = 'b1;
        trap_rob_entry_rmp2rob = ss_rob_entry[res_id[j]];
      end
    end
  end

// ---------------------------------------------------------------------------
// 响应消费 (pop) —— 每个响应都必须被消费, 否则 res FIFO 会堵住
// ---------------------------------------------------------------------------
  generate
    for(g=0;g<`NUM_LSU;g++) begin: GET_POP
      assign pop_lsu_res[g] = !lsu_res_valid[g] ? 1'b0 :
                              !res_hit[g] ? 1'b1 :   // 键对不上: 丢弃并消费 (防死锁, ASSERT_ON 会报)
                              lsu_res[g].trap_valid ? trap_ready_rob2rmp :
                              ss_writes_rob[res_id[g]]
                                ? (result_valid[g] & result_ready[g])
                                : 1'b1;      // 不写 ROB 的 uop: 收到即消费
    end
  endgenerate

`ifdef ASSERT_ON
  // 一旦 mapinfo 与 RS 对齐关系被破坏, 这里会立刻报
  for (genvar a=0; a<`NUM_LSU; a++) begin : gen_asrt
    `rvv_forbid(lsu_req_valid[a] && !mapinfo_valid[a])
    else $error("LSU remap: mapinfo lane %0d missing - RS/mapinfo FIFOs are misaligned", a);
  end
`endif

endmodule
