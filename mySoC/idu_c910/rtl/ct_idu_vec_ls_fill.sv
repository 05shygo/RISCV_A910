`include "rvv_backend.svh"

// ===========================================================================
// ct_idu_vec_ls_fill —— 向量 load/store 的 fill 引擎 (2026-10-17 S8)
//
// 职责（与计划 §10 对应）:
//   1. 接受 RvvCore 的 core uop (UOP_RVV2LSU_t)，按 iid 匹配 IS 阶段建好的
//      LSIQ anchor，把 uop 拆成 A910 的 **单字节** beat:
//        {synthetic opcode(LBU/SB), 完整地址, sdiq_entry, uop_idx, last, sd_data}
//      写进 anchor（`lsiq_vec_upd_*`），再拉 `lsiq_vec_beat_rdy` 让 LSIQ 发射。
//   2. load: 收集 32 位写回（按 {iid,uop_idx} 查 request 表），逐字节拼进
//      128 位 `ld_asm`，一个 core uop 的字节全回来后回一个 UOP_LSU2RVV_t。
//   3. store: 提交前 staging（每 anchor 最多 4 个 core uop），数据齐后先回
//      `lsu_vstore_last` 让 core 完成/提交；**提交后**才把 beat 排空进 LSU。
//
// 简化（首版，S9 再按用例收紧）:
//   * 默认每个 A910 beat 是 **1 个字节**（LBU/SB），但同一切片内连续、
//     4B 对齐、4 字节全 active 的组会合并成一个 **32 位 LW/SW** beat。
//     这样对齐的 16B uop 从 16 个请求降到 4 个；不满足条件时回退到 1B。
//     （A910 LSU 的 load 写回口只有 32 位，所以不可能一次 beat 取 16B。）
//   * mop 支持 US / CS / IU / IO；segment 由 S6 的 store uop 数限制兜住。
//   * request index 在**写回**时释放（计划写"LQ pop 后"，但 LQ 的 pop 不回送
//     uop_idx；匹配靠 {iid,uop_idx}，iid 不同 ⇒ 提前释放不会串）。
//   * fault-only-first / page fault 不在本方案范围。
// ===========================================================================
module ct_idu_vec_ls_fill
(
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic         rtu_yy_xx_flush,

  // RTU commit 广播（store 提交后排空）
  input  logic         rtu_yy_xx_commit0,
  input  logic [6:0]   rtu_yy_xx_commit0_iid,
  input  logic         rtu_yy_xx_commit1,
  input  logic [6:0]   rtu_yy_xx_commit1_iid,
  input  logic         rtu_yy_xx_commit2,
  input  logic [6:0]   rtu_yy_xx_commit2_iid,

  // RvvCore → fill
  input  logic         rvv_lsu_uop_valid,
  input  UOP_RVV2LSU_t rvv_lsu_uop,
  output logic         rvv_lsu_uop_ready,
  output logic         rvv_lsu_resp_valid,
  output UOP_LSU2RVV_t rvv_lsu_resp,
  input  logic         rvv_lsu_resp_ready,

  // LSIQ anchor 接口
  input  logic [7:0]   lsiq_vec_create_entry,
  input  logic         lsiq_vec_create_vld,
  input  logic [6:0]   lsiq_vec_create_iid,
  input  logic         lsiq_vec_create_store,
  output logic [7:0]   lsiq_vec_upd_entry,
  output logic [105:0] lsiq_vec_upd_data,
  output logic [7:0]   lsiq_vec_beat_rdy,
  input  logic [7:0]   lsiq_vec_old,
  input  logic [7:0]   lsu_idu_beat_done,
  input  logic [7:0]   lsu_idu_pop_entry,

  // LSU → fill（load 写回）
  input  logic         lsu_idu_wb_pipe3_wb_preg_vec,
  input  logic [4:0]   lsu_idu_wb_pipe3_wb_uop_idx,
  input  logic [6:0]   lsu_idu_wb_pipe3_wb_preg_iid,
  input  logic [31:0]  lsu_idu_wb_pipe3_wb_preg_data,

  // SQ 表项弹出（store 的 request 释放）
  input  logic         lsu_idu_sq_pop_vld,
  input  logic [4:0]   lsu_idu_sq_pop_uop_idx,

  // SDIQ
  input          [3:0] sdiq_entry_vld,       // 现有 4 项占用情况
  output logic         vec_sdiq_create_vld,
  output logic [3:0]   vec_sdiq_create_entry,
  input  logic [3:0]   sdiq_dp_issue_entry,
  input  logic         sdiq_issue_en,
  output logic [31:0]  vec_sd_data,

  // 反压
  input  logic [7:0]   lsu_idu_lq_full,
  input  logic [7:0]   lsu_idu_rb_full,
  input  logic [7:0]   lsu_idu_sq_full,

  // LSIQ 标量 old 的跨类型修正
  output logic [6:0]   vec_old_iid,
  output logic         vec_old_vld,

  // 向量 store 提交电平（给 SQ）
  output logic         vec_st_cmit_vld,
  output logic [6:0]   vec_st_cmit_iid
);

parameter NUM_ANCHOR = 8;
parameter NUM_REQ    = 32;

localparam logic [$clog2(`VLENB):0] FF_TAIL_MAX = `VLENB;
localparam logic [31:0] SYNTH_LBU = 32'h0000_0003;   // opcode 0000011, funct3 000
localparam logic [31:0] SYNTH_SB  = 32'h0000_0023;   // opcode 0100011, funct3 000
localparam logic [31:0] SYNTH_LW  = 32'h0000_2003;   // opcode 0000011, funct3 010
localparam logic [31:0] SYNTH_SW  = 32'h0000_2023;   // opcode 0100011, funct3 010

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
function automatic logic iid_older7 (input logic [6:0] a, input logic [6:0] b);
  iid_older7 = (a[6] ^ b[6]) ? (a[5:0] > b[5:0]) : (a[5:0] < b[5:0]);
endfunction

// EEW_e: EEW_NONE=0, EEW1=1, EEW8=2, EEW16=3, EEW32=4, EEW64=5
function automatic logic [2:0] eew_shift (input logic [2:0] eew);
  case (eew)
    3'd3:    eew_shift = 3'd1;   // EEW16
    3'd4:    eew_shift = 3'd2;   // EEW32
    3'd5:    eew_shift = 3'd3;   // EEW64
    default: eew_shift = 3'd0;   // EEW8 / EEW1
  endcase
endfunction

function automatic logic [15:0] calc_mask (input logic [127:0] v0_data,
                                           input logic        v0_valid,
                                           input logic [7:0]  vl,
                                           input logic [4:0]  uop_index,
                                           input logic [2:0]  eew);
  logic [2:0] sh;
  logic [8:0] elem;
  sh = eew_shift(eew);
  calc_mask = 16'd0;
  for (int b=0;b<16;b++) begin
    elem = ({4'b0, uop_index} + {5'b0, b[3:0]}) >> sh;
    calc_mask[b] = (elem < {1'b0, vl}) && (!v0_valid || v0_data[b]);
  end
endfunction

// ---------------------------------------------------------------------------
// 计算 anchor 中第 byte_pos 个字节的完整地址
// ---------------------------------------------------------------------------
// 与原来的 beat_addr case 逐式一致; 抽成函数是为了同时检查"相邻 4 字节
// 地址是否连续" (4B 合并条件)。
function automatic logic [31:0] vec_byte_addr (
    input logic [2:0]   mop,
    input logic [31:0]  base,
    input logic [31:0]  stride,
    input logic [127:0] vidx,
    input logic [2:0]   vs2_eew,
    input logic [2:0]   vd_eew,
    input logic [4:0]   uop_idx,
    input logic [3:0]   byte_pos
);
  logic [2:0] sh;
  logic [2:0] sh2;
  logic [8:0] elem;

  sh   = eew_shift(vd_eew);
  elem = ({4'b0, uop_idx} + {5'b0, byte_pos}) >> sh;

  case (mop)
    3'd0: begin // US
      vec_byte_addr = base + {27'b0, uop_idx}*32'd16 + {28'b0, byte_pos};
    end
    3'd2: begin // CS
      vec_byte_addr = base
                    + $signed(stride) * $signed({23'b0, elem})
                    + {28'b0, (byte_pos & ((8'd1 << sh) - 8'd1))};
    end
    3'd1, 3'd3: begin // IU / IO
      sh2 = eew_shift(vs2_eew);
      vec_byte_addr = base
                    + $signed(vidx[((elem * (8'd1 << sh2)) & 5'h0F)*8 +: 32])
                      * $signed({29'b0, (8'd1 << sh)})
                    + {28'b0, (byte_pos & ((8'd1 << sh) - 8'd1))};
    end
    default: vec_byte_addr = base + {28'b0, byte_pos};
  endcase
endfunction

// ---------------------------------------------------------------------------
// anchor 上下文
// ---------------------------------------------------------------------------
logic [NUM_ANCHOR-1:0] ctx_active;
logic [NUM_ANCHOR-1:0] ctx_store;
logic [NUM_ANCHOR-1:0] ctx_busy;
logic [NUM_ANCHOR-1:0] ctx_committed;
logic [NUM_ANCHOR-1:0] ctx_drained;
logic [NUM_ANCHOR-1:0] ctx_beat_issue;
logic [NUM_ANCHOR-1:0] ctx_beat_staged;   // 已写 beat 字段, 等下一拍拉 ready
logic [NUM_ANCHOR-1:0] ctx_all_issued;
logic [6:0]  ctx_iid       [0:NUM_ANCHOR-1];
logic [4:0]  ctx_lsu_id    [0:NUM_ANCHOR-1];
logic [2:0]  ctx_vd_eew    [0:NUM_ANCHOR-1];
logic [2:0]  ctx_vs2_eew   [0:NUM_ANCHOR-1];
logic [2:0]  ctx_mop       [0:NUM_ANCHOR-1];
logic [7:0]  ctx_vl        [0:NUM_ANCHOR-1];
logic [31:0] ctx_base      [0:NUM_ANCHOR-1];
logic [31:0] ctx_stride    [0:NUM_ANCHOR-1];
logic [127:0] ctx_sdata    [0:NUM_ANCHOR-1];
logic [127:0] ctx_vidx     [0:NUM_ANCHOR-1];
logic [15:0] ctx_mask      [0:NUM_ANCHOR-1];
logic [15:0] ctx_ld_pend   [0:NUM_ANCHOR-1];
logic [127:0] ctx_ld_asm   [0:NUM_ANCHOR-1];
logic [4:0]  ctx_uop_idx   [0:NUM_ANCHOR-1];
logic        ctx_uop_last  [0:NUM_ANCHOR-1];
logic [3:0]  ctx_byte_ptr  [0:NUM_ANCHOR-1];

// store staging（每 anchor 4 个 core uop）
logic [3:0]  stg_vld     [0:NUM_ANCHOR-1];
logic [4:0]  stg_uop_idx [0:NUM_ANCHOR-1][0:3];
logic        stg_last    [0:NUM_ANCHOR-1][0:3];
logic [15:0] stg_mask    [0:NUM_ANCHOR-1][0:3];
logic [127:0] stg_sdata  [0:NUM_ANCHOR-1][0:3];
logic [4:0]  stg_lsu_id  [0:NUM_ANCHOR-1][0:3];
logic [2:0]  stg_drain_slot [0:NUM_ANCHOR-1];
logic        drain_owner_vld;
logic [2:0]  drain_owner;

// request 表（单独 always_ff，避免和上下文多驱动）
logic [NUM_REQ-1:0] req_valid;
logic [2:0]  req_anchor [0:NUM_REQ-1];
logic [4:0]  req_uop    [0:NUM_REQ-1];
logic [3:0]  req_lane   [0:NUM_REQ-1];
logic [2:0]  req_len    [0:NUM_REQ-1];   // 1 或 4
logic        req_store  [0:NUM_REQ-1];
logic [4:0]  req_alloc_ptr;
logic [31:0] sd_entry_data [0:3];

// uop → anchor 匹配 / store 响应保持寄存器
wire         uop_accept;
logic [2:0]  uop_anchor;
logic        uop_anchor_found;
logic [3:0] uop_free_slot;
logic       uop_free_slot_vld;
always_comb begin
  uop_free_slot     = 4'd0;
  uop_free_slot_vld = 1'b0;
  for (int s=3;s>=0;s--) begin
    if (!stg_vld[uop_anchor][s]) begin
      uop_free_slot     = s[3:0];
      uop_free_slot_vld = 1'b1;
    end
  end
end

logic        store_resp_vld;
logic [6:0]  store_resp_iid;
logic [4:0]  store_resp_uop;
logic [4:0]  store_resp_lsu_id;
logic        resp_is_store;
logic [2:0]  resp_anchor;
logic        resp_load_can;

// ---------------------------------------------------------------------------
// 选 anchor + 当前字节地址
// ---------------------------------------------------------------------------
logic [2:0] beat_sel;
logic [3:0] beat_byte;
logic       beat_active;
logic       beat_is_load;
logic [31:0] beat_addr;
logic       beat_go;           // 真正发射 (active + 允许)
logic       beat_skip;         // 非 active 字节, 直接跳过

// 4B 合并 (2026-10-17): 同一 uop 内连续、4B 对齐、4 字节全 active 的组
// 合成一个 LW/SW beat。其余情况保持 1 字节 LBU/SB。
logic       beat_merge4;
logic [2:0] beat_len;          // 1 或 4
logic [4:0] beat_end;          // 本 beat 覆盖的最后一个字节
logic       beat_is_last;
logic [31:0] beat_opcode;
logic [31:0] beat_sdata;
logic [3:0]  beat_word_base;   // 4B 窗口起点 (<=12)
logic [3:0]  beat_mask4;       // 从 beat_byte 开始的 4 位 mask
logic [31:0] beat_addr_p1;
logic [31:0] beat_addr_p2;
logic [31:0] beat_addr_p3;

// 2026-10-17 S9 修: 有一个 beat 在飞时必须**锁定它的 anchor** 去做 beat_done
// 的清除; 否则 beat_sel 会跳到别的 anchor, done 清错表项 ⇒ 永远只发第一个 beat。
logic [2:0] beat_pend_sel;
logic       beat_pend_valid;
always_comb begin
  beat_pend_valid = |(ctx_beat_issue | ctx_beat_staged);
  beat_pend_sel   = 3'd0;
  for (int k=NUM_ANCHOR-1;k>=0;k--)
    if (ctx_beat_issue[k] | ctx_beat_staged[k]) beat_pend_sel = k[2:0];

  if (beat_pend_valid) begin
    beat_sel = beat_pend_sel;
  end
  else begin
    beat_sel = drain_owner_vld ? drain_owner : 3'd0;
    if (!drain_owner_vld) begin
      for (int k=NUM_ANCHOR-1;k>=0;k--) begin
        if (ctx_active[k] && ctx_busy[k] && !ctx_store[k] &&
            !ctx_beat_issue[k] && !ctx_beat_staged[k] && !ctx_all_issued[k])
          beat_sel = k[2:0];
      end
    end
  end
end

always_comb begin
  beat_byte   = ctx_byte_ptr[beat_sel];
  beat_active = ctx_mask[beat_sel][beat_byte];
  beat_is_load= !ctx_store[beat_sel];
  beat_addr   = vec_byte_addr(ctx_mop[beat_sel], ctx_base[beat_sel],
                              ctx_stride[beat_sel], ctx_vidx[beat_sel],
                              ctx_vs2_eew[beat_sel], ctx_vd_eew[beat_sel],
                              ctx_uop_idx[beat_sel], beat_byte);

  // ---------------- 4B 合并判定 ----------------
  // 条件:
  //   1) 4 个字节都在这个 16B 切片内;
  //   2) 起始地址 4B 对齐;
  //   3) 4 个字节全部 active;
  //   4) 4 个字节的地址连续 (US 恒成立; CS/IU/IO 只有元素内/索引恰好连续才成立)。
  // 不满足时保持原来的 1 字节 LBU/SB。
  beat_word_base = (beat_byte <= 4'd12) ? beat_byte : 4'd12;
  beat_mask4     = ctx_mask[beat_sel][beat_word_base +: 4];
  beat_merge4    = 1'b0;
  beat_addr_p1   = 32'd0;
  beat_addr_p2   = 32'd0;
  beat_addr_p3   = 32'd0;
  if (beat_byte <= 4'd12) begin
    beat_addr_p1 = vec_byte_addr(ctx_mop[beat_sel], ctx_base[beat_sel],
                                 ctx_stride[beat_sel], ctx_vidx[beat_sel],
                                 ctx_vs2_eew[beat_sel], ctx_vd_eew[beat_sel],
                                 ctx_uop_idx[beat_sel], beat_byte + 4'd1);
    beat_addr_p2 = vec_byte_addr(ctx_mop[beat_sel], ctx_base[beat_sel],
                                 ctx_stride[beat_sel], ctx_vidx[beat_sel],
                                 ctx_vs2_eew[beat_sel], ctx_vd_eew[beat_sel],
                                 ctx_uop_idx[beat_sel], beat_byte + 4'd2);
    beat_addr_p3 = vec_byte_addr(ctx_mop[beat_sel], ctx_base[beat_sel],
                                 ctx_stride[beat_sel], ctx_vidx[beat_sel],
                                 ctx_vs2_eew[beat_sel], ctx_vd_eew[beat_sel],
                                 ctx_uop_idx[beat_sel], beat_byte + 4'd3);
    beat_merge4  = (beat_addr[1:0] == 2'b00) &&
                   (&beat_mask4) &&
                   (beat_addr_p1 == (beat_addr + 32'd1)) &&
                   (beat_addr_p2 == (beat_addr + 32'd2)) &&
                   (beat_addr_p3 == (beat_addr + 32'd3));
  end

  beat_len    = beat_merge4 ? 3'd4 : 3'd1;
  beat_end    = {1'b0, beat_byte} + {2'b0, beat_len} - 5'd1;
  beat_is_last= ctx_uop_last[beat_sel] && (beat_end[3:0] == 4'd15);
  beat_opcode = beat_merge4 ? (beat_is_load ? SYNTH_LW : SYNTH_SW)
                            : (beat_is_load ? SYNTH_LBU : SYNTH_SB);
  beat_sdata  = beat_is_load ? 32'd0 :
                (beat_merge4 ? ctx_sdata[beat_sel][beat_word_base*8 +: 32]
                             : ({{24{1'b0}}, ctx_sdata[beat_sel][beat_byte*8 +: 8]}
                                << (beat_addr[1:0]*8)));
end

wire beat_sel_valid = drain_owner_vld ||
                      (ctx_active[beat_sel] && ctx_busy[beat_sel] && !ctx_store[beat_sel]);
// ⚠️ update 与 ready **分两拍** (计划 §9.2.4): 同拍的话 LSIQ 会用上一拍的
// beat 字段发射。
wire beat_can_issue = beat_sel_valid && !ctx_beat_issue[beat_sel] &&
                      !ctx_beat_staged[beat_sel] &&
                      (beat_is_load ? lsiq_vec_old[beat_sel] : 1'b1);
assign beat_go   = beat_can_issue &&  beat_active;     // 写 beat 字段那一拍
assign beat_skip = beat_can_issue && !beat_active;     // 非 active 字节直接跳过
wire   beat_rdy  = ctx_beat_staged[beat_sel];          // 下一拍才拉 ready

// request index / SDIQ entry 分配
function automatic logic [4:0] pick_req (input logic [NUM_REQ-1:0] used,
                                         input logic [4:0]        start);
  logic [2*NUM_REQ-1:0] used2;
  used2 = {used, used};
  pick_req = start;
  for (int j=NUM_REQ-1; j>=0; j--) begin
    if (!used2[start + j[4:0]]) pick_req = start + j[4:0];
  end
endfunction

logic [4:0] beat_req;
logic [3:0] beat_sdiq;
always_comb begin
  beat_req  = pick_req(req_valid, req_alloc_ptr);
  beat_sdiq = 4'd0;
  for (int k=3;k>=0;k--)
    if (!sdiq_entry_vld[k]) beat_sdiq = k[3:0];
end

// ---------------------------------------------------------------------------
// anchor 侧输出
// ---------------------------------------------------------------------------
always_comb begin
  lsiq_vec_upd_entry = 8'd0;
  lsiq_vec_upd_data  = 106'd0;
  lsiq_vec_beat_rdy  = 8'd0;
  if (beat_go) begin
    lsiq_vec_upd_entry[beat_sel] = 1'b1;
    lsiq_vec_upd_data = { beat_opcode,
                          beat_addr[31:0],
                          beat_sdiq,
                          beat_req,
                          beat_is_last,
                          beat_sdata };
  end
  // ready 比 update 晚一拍; 持续保持到该 beat 完成 (frz 会挡住重复发射)
  if (beat_rdy) lsiq_vec_beat_rdy[beat_sel] = 1'b1;
end

assign vec_sdiq_create_vld   = beat_go && !beat_is_load;
assign vec_sdiq_create_entry = beat_sdiq;

always_comb begin
  vec_sd_data = 32'd0;
  for (int k=0;k<4;k++)
    if (sdiq_dp_issue_entry[k]) vec_sd_data = sd_entry_data[k];
end

// ---------------------------------------------------------------------------
// 上下文状态机（单 always_ff）
// ---------------------------------------------------------------------------
integer ci;
always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    ctx_active     <= '0;
    ctx_store      <= '0;
    ctx_busy       <= '0;
    ctx_committed  <= '0;
    ctx_drained    <= '0;
    ctx_beat_issue  <= '0;
    ctx_beat_staged <= '0;
    ctx_all_issued  <= '0;
    drain_owner_vld <= 1'b0;
    store_resp_vld  <= 1'b0;
    for (ci=0; ci<NUM_ANCHOR; ci=ci+1) begin
      ctx_byte_ptr[ci]   <= 4'd0;
      stg_vld[ci]        <= 4'b0;
      stg_drain_slot[ci] <= 3'd0;
      ctx_ld_asm[ci]     <= 128'd0;
      ctx_mask[ci]       <= 16'd0;
      ctx_ld_pend[ci]    <= 16'd0;
    end
  end
  else if (rtu_yy_xx_flush) begin
    ctx_active     <= '0;
    ctx_store      <= '0;
    ctx_busy       <= '0;
    ctx_committed  <= '0;
    ctx_drained    <= '0;
    ctx_beat_issue  <= '0;
    ctx_beat_staged <= '0;
    ctx_all_issued  <= '0;
    drain_owner_vld <= 1'b0;
    store_resp_vld  <= 1'b0;
    for (ci=0; ci<NUM_ANCHOR; ci=ci+1) begin
      stg_vld[ci]        <= 4'b0;
      stg_drain_slot[ci] <= 3'd0;
      ctx_ld_asm[ci]     <= 128'd0;
      ctx_ld_pend[ci]    <= 16'd0;
    end
  end
  else begin

    // ---------------- anchor 创建 / 释放 ----------------
    if (lsiq_vec_create_vld) begin
      for (int k=0;k<NUM_ANCHOR;k++) begin
        if (lsiq_vec_create_entry[k]) begin
          ctx_active[k]  <= 1'b1;
          ctx_store[k]   <= lsiq_vec_create_store;
          ctx_iid[k]     <= lsiq_vec_create_iid;
          ctx_busy[k]    <= 1'b0;
          ctx_committed[k] <= 1'b0;
          ctx_drained[k] <= 1'b0;
          stg_vld[k]     <= 4'b0;
          stg_drain_slot[k] <= 3'd0;
        end
      end
    end
    for (int k=0;k<NUM_ANCHOR;k++) begin
      if (lsu_idu_pop_entry[k] && !(lsiq_vec_create_vld && lsiq_vec_create_entry[k])) begin
        ctx_active[k]  <= 1'b0;
        ctx_busy[k]    <= 1'b0;
        stg_vld[k]     <= 4'b0;
      end
    end

    // ---------------- core uop 接受 ----------------
    if (uop_accept && uop_anchor_found) begin
      if (rvv_lsu_uop.lsu_is_store) begin
        if (uop_free_slot_vld) begin
          stg_vld[uop_anchor][uop_free_slot]      <= 1'b1;
          stg_uop_idx[uop_anchor][uop_free_slot]  <= rvv_lsu_uop.uop_index;
          stg_last[uop_anchor][uop_free_slot]     <= rvv_lsu_uop.last_uop_valid;
          stg_mask[uop_anchor][uop_free_slot]     <= calc_mask(rvv_lsu_uop.v0_data,
                                                   rvv_lsu_uop.v0_valid,
                                                   rvv_lsu_uop.vl[7:0],
                                                   rvv_lsu_uop.uop_index,
                                                   rvv_lsu_uop.vd_eew);
          stg_sdata[uop_anchor][uop_free_slot]    <= rvv_lsu_uop.vregfile_read_data;
          stg_lsu_id[uop_anchor][uop_free_slot]   <= rvv_lsu_uop.lsu_id;
          // 公共字段
          ctx_base[uop_anchor]    <= rvv_lsu_uop.rs1_data;
          ctx_stride[uop_anchor]  <= rvv_lsu_uop.rs2_data;
          ctx_vd_eew[uop_anchor]  <= {1'b0, rvv_lsu_uop.vd_eew};
          ctx_vs2_eew[uop_anchor] <= {1'b0, rvv_lsu_uop.vs2_eew};
          ctx_mop[uop_anchor]     <= {1'b0, rvv_lsu_uop.lsu_type.lsu_mop};
          ctx_vl[uop_anchor]      <= rvv_lsu_uop.vl[7:0];
        end
      end
      else begin
        // load: 启动逐字节发射
        ctx_busy[uop_anchor]       <= 1'b1;
        ctx_byte_ptr[uop_anchor]   <= 4'd0;
        ctx_beat_issue[uop_anchor] <= 1'b0;
        ctx_all_issued[uop_anchor] <= 1'b0;
        ctx_ld_asm[uop_anchor]     <= 128'd0;
        ctx_mask[uop_anchor]       <= calc_mask(rvv_lsu_uop.v0_data,
                                        rvv_lsu_uop.v0_valid,
                                        rvv_lsu_uop.vl[7:0],
                                        rvv_lsu_uop.uop_index,
                                        rvv_lsu_uop.vd_eew);
        ctx_ld_pend[uop_anchor]    <= calc_mask(rvv_lsu_uop.v0_data,
                                        rvv_lsu_uop.v0_valid,
                                        rvv_lsu_uop.vl[7:0],
                                        rvv_lsu_uop.uop_index,
                                        rvv_lsu_uop.vd_eew);
        ctx_vidx[uop_anchor]       <= rvv_lsu_uop.vidx_data;
        ctx_base[uop_anchor]       <= rvv_lsu_uop.rs1_data;
        ctx_stride[uop_anchor]     <= rvv_lsu_uop.rs2_data;
        ctx_vd_eew[uop_anchor]     <= {1'b0, rvv_lsu_uop.vd_eew};
        ctx_vs2_eew[uop_anchor]    <= {1'b0, rvv_lsu_uop.vs2_eew};
        ctx_mop[uop_anchor]        <= {1'b0, rvv_lsu_uop.lsu_type.lsu_mop};
        ctx_vl[uop_anchor]         <= rvv_lsu_uop.vl[7:0];
        ctx_uop_idx[uop_anchor]    <= rvv_lsu_uop.uop_index;
        ctx_uop_last[uop_anchor]   <= rvv_lsu_uop.last_uop_valid;
        ctx_lsu_id[uop_anchor]     <= rvv_lsu_uop.lsu_id;
      end
    end

    // ---------------- beat 推进 ----------------
    if (beat_skip) begin
      if (ctx_byte_ptr[beat_sel] == 4'd15) ctx_all_issued[beat_sel] <= 1'b1;
      else                                 ctx_byte_ptr[beat_sel]   <= ctx_byte_ptr[beat_sel] + 4'd1;
    end
    else if (beat_go) begin
      ctx_beat_staged[beat_sel] <= 1'b1;
      if (beat_end[3:0] == 4'd15) ctx_all_issued[beat_sel] <= 1'b1;
      else                        ctx_byte_ptr[beat_sel]   <= ctx_byte_ptr[beat_sel] + beat_len;
    end
    else if (ctx_beat_staged[beat_sel] && !ctx_beat_issue[beat_sel]) begin
      // update 后一拍: 标记 outstanding (ready 正在拉; frz 保证只发一次)
      ctx_beat_issue[beat_sel] <= 1'b1;
    end
    else if (ctx_beat_issue[beat_sel] && lsu_idu_beat_done[beat_sel]) begin
      ctx_beat_issue[beat_sel]  <= 1'b0;
      ctx_beat_staged[beat_sel] <= 1'b0;
    end

    // ---------------- load 写回 → 拼装 ----------------
    if (lsu_idu_wb_pipe3_wb_preg_vec) begin
      for (int r=0;r<NUM_REQ;r++) begin
        if (req_valid[r] && !req_store[r] &&
            (req_uop[r] == lsu_idu_wb_pipe3_wb_uop_idx) &&
            (ctx_iid[req_anchor[r]] == lsu_idu_wb_pipe3_wb_preg_iid)) begin
          if (req_len[r] == 3'd4) begin
            // 4B beat: LSU 回的是完整 32 位字, 按 little-endian 填进 4 个字节
            ctx_ld_asm[req_anchor[r]][req_lane[r]*8 +: 32] <=
                lsu_idu_wb_pipe3_wb_preg_data[31:0];
            ctx_ld_pend[req_anchor[r]][req_lane[r] +: 4] <= 4'b0;
          end
          else begin
            ctx_ld_asm[req_anchor[r]][req_lane[r]*8 +: 8] <=
                lsu_idu_wb_pipe3_wb_preg_data[7:0];
            ctx_ld_pend[req_anchor[r]][req_lane[r]] <= 1'b0;
          end
        end
      end
    end

    // ---------------- store 响应保持 / load 响应发送 ----------------
    if (uop_accept && uop_anchor_found && rvv_lsu_uop.lsu_is_store) begin
      store_resp_vld    <= 1'b1;
      store_resp_iid    <= rvv_lsu_uop.rob_tag;
      store_resp_uop    <= rvv_lsu_uop.uop_index;
      store_resp_lsu_id <= rvv_lsu_uop.lsu_id;
    end
    else if (store_resp_vld && rvv_lsu_resp_ready) begin
      store_resp_vld    <= 1'b0;
    end

    if (resp_load_can && rvv_lsu_resp_ready) begin
      ctx_busy[resp_anchor]   <= 1'b0;
      ctx_ld_asm[resp_anchor] <= 128'd0;
    end

    // ---------------- store 提交 ----------------
    if (rtu_yy_xx_commit0 || rtu_yy_xx_commit1 || rtu_yy_xx_commit2) begin
      for (int k=0;k<NUM_ANCHOR;k++) begin
        if (ctx_active[k] && ctx_store[k] &&
            ((rtu_yy_xx_commit0 && ctx_iid[k]==rtu_yy_xx_commit0_iid) ||
             (rtu_yy_xx_commit1 && ctx_iid[k]==rtu_yy_xx_commit1_iid) ||
             (rtu_yy_xx_commit2 && ctx_iid[k]==rtu_yy_xx_commit2_iid)))
          ctx_committed[k] <= 1'b1;
      end
    end

    // ---------------- store 排空（一次一个 anchor） ----------------
    if (!drain_owner_vld) begin
      for (int k=NUM_ANCHOR-1;k>=0;k--) begin
        if (ctx_active[k] && ctx_store[k] && ctx_committed[k] && !ctx_drained[k]) begin
          drain_owner_vld   <= 1'b1;
          drain_owner       <= k[2:0];
          stg_drain_slot[k] <= 3'd0;
          ctx_byte_ptr[k]   <= 4'd0;
          ctx_all_issued[k] <= 1'b0;
          ctx_beat_issue[k] <= 1'b0;
          // 载入 slot0
          ctx_mask[k]     <= stg_mask[k][0];
          ctx_sdata[k]    <= stg_sdata[k][0];
          ctx_uop_idx[k]  <= stg_uop_idx[k][0];
          ctx_uop_last[k] <= stg_last[k][0];
        end
      end
    end
    else if (drain_owner_vld && ctx_all_issued[drain_owner] &&
             !ctx_beat_issue[drain_owner]) begin
      if (stg_drain_slot[drain_owner] < 3'd3) begin
        stg_drain_slot[drain_owner] <= stg_drain_slot[drain_owner] + 3'd1;
        ctx_byte_ptr[drain_owner]   <= 4'd0;
        ctx_all_issued[drain_owner] <= 1'b0;
        ctx_mask[drain_owner]       <= stg_mask[drain_owner][stg_drain_slot[drain_owner]+3'd1];
        ctx_sdata[drain_owner]      <= stg_sdata[drain_owner][stg_drain_slot[drain_owner]+3'd1];
        ctx_uop_idx[drain_owner]    <= stg_uop_idx[drain_owner][stg_drain_slot[drain_owner]+3'd1];
        ctx_uop_last[drain_owner]   <= stg_last[drain_owner][stg_drain_slot[drain_owner]+3'd1];
      end
      else begin
        ctx_drained[drain_owner]    <= 1'b1;
        ctx_committed[drain_owner]  <= 1'b0;
        drain_owner_vld             <= 1'b0;
      end
    end
  end
end

// ---------------------------------------------------------------------------
// request 表（写回释放 / beat 分配）
// ---------------------------------------------------------------------------
integer ri;
always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    req_valid     <= '0;
    req_alloc_ptr <= 5'd0;
    for (ri=0; ri<NUM_REQ; ri=ri+1) req_len[ri] <= 3'd0;
    for (ri=0; ri<4; ri=ri+1) sd_entry_data[ri] <= 32'd0;
  end
  else if (rtu_yy_xx_flush) begin
    req_valid <= '0;
  end
  else begin
    // 分配
    if (beat_go) begin
      req_valid[beat_req]  <= 1'b1;
      req_anchor[beat_req] <= beat_sel;
      // LSU 流水里的 uop_idx 是 **request index** (beat 字段), 不是 core uop_index
      req_uop[beat_req]    <= beat_req;
      req_lane[beat_req]   <= beat_byte;
      req_len[beat_req]    <= beat_len;
      req_store[beat_req]  <= !beat_is_load;
      req_alloc_ptr        <= beat_req + 5'd1;
      // SDIQ 数据: 1B beat 是放在 addr[1:0] 字节道的单字节; 4B beat 是
      // 4B 对齐的完整字 (beat_addr[1:0]==0)。load 不占 SDIQ, 不能写。
      if (!beat_is_load)
        sd_entry_data[beat_sdiq] <= beat_sdata;
    end
    // load 写回: 释放
    if (lsu_idu_wb_pipe3_wb_preg_vec) begin
      for (int r=0;r<NUM_REQ;r++) begin
        if (req_valid[r] && !req_store[r] &&
            (req_uop[r] == lsu_idu_wb_pipe3_wb_uop_idx) &&
            (ctx_iid[req_anchor[r]] == lsu_idu_wb_pipe3_wb_preg_iid))
          req_valid[r] <= 1'b0;
      end
    end
    // store: SQ 表项弹出后释放
    if (lsu_idu_sq_pop_vld) begin
      for (int r=0;r<NUM_REQ;r++)
        if (req_valid[r] && req_store[r] && (req_uop[r] == lsu_idu_sq_pop_uop_idx))
          req_valid[r] <= 1'b0;
    end
  end
end


// ---------------------------------------------------------------------------
// 响应通道: store 用保持寄存器 (避免 uop_ready ↔ resp_valid 组合环)
// ---------------------------------------------------------------------------
always_comb begin
  resp_anchor   = 3'd0;
  resp_is_store = 1'b0;
  resp_load_can = 1'b0;
  if (store_resp_vld) begin
    resp_is_store = 1'b1;
  end
  else begin
    for (int k=NUM_ANCHOR-1;k>=0;k--) begin
      if (ctx_active[k] && ctx_busy[k] && !ctx_store[k] &&
          (ctx_ld_pend[k] == 16'd0) &&
          (ctx_all_issued[k] || (ctx_mask[k] == 16'd0))) begin
        resp_anchor   = k[2:0];
        resp_is_store = 1'b0;
        resp_load_can = 1'b1;
      end
    end
  end
end

// uop ↔ anchor 匹配 (accept 与 ready 都用)
always_comb begin
  uop_anchor = 3'd0;
  uop_anchor_found = 1'b0;
  for (int k=NUM_ANCHOR-1;k>=0;k--) begin
    if (ctx_active[k] && (ctx_iid[k] == rvv_lsu_uop.rob_tag)) begin
      uop_anchor = k[2:0];
      uop_anchor_found = 1'b1;
    end
  end
end

assign uop_accept = rvv_lsu_uop_valid && rvv_lsu_uop_ready;
assign rvv_lsu_resp_valid = !rtu_yy_xx_flush && (store_resp_vld || resp_load_can);

always_comb begin
  rvv_lsu_resp = '0;
  if (store_resp_vld) begin
    rvv_lsu_resp.rob_tag              = store_resp_iid;
    rvv_lsu_resp.lsu_id               = store_resp_lsu_id;
    rvv_lsu_resp.uop_index            = store_resp_uop;
    rvv_lsu_resp.vregfile_write_valid = 1'b0;
    rvv_lsu_resp.lsu_vstore_last      = 1'b1;
    rvv_lsu_resp.ff_tail_index        = FF_TAIL_MAX;
  end
  else begin
    rvv_lsu_resp.rob_tag              = ctx_iid[resp_anchor];
    rvv_lsu_resp.lsu_id               = ctx_lsu_id[resp_anchor];
    rvv_lsu_resp.uop_index            = ctx_uop_idx[resp_anchor];
    rvv_lsu_resp.vregfile_write_valid = 1'b1;
    rvv_lsu_resp.vregfile_write_addr  = ctx_uop_idx[resp_anchor];
    rvv_lsu_resp.vregfile_write_data  = ctx_ld_asm[resp_anchor];
    rvv_lsu_resp.lsu_vstore_last      = 1'b0;
    rvv_lsu_resp.ff_tail_index        = FF_TAIL_MAX;
  end
end

// ---------------------------------------------------------------------------
// uop ready / vec_old / store commit level
// ---------------------------------------------------------------------------
assign rvv_lsu_uop_ready = !rtu_yy_xx_flush &&
                           !store_resp_vld &&
                           uop_anchor_found &&
                           ((ctx_store[uop_anchor] == 1'b0) ?
                              !ctx_busy[uop_anchor] :
                              uop_free_slot_vld && !drain_owner_vld);

always_comb begin
  vec_old_vld = 1'b0;
  vec_old_iid = 7'd0;
  for (int k=NUM_ANCHOR-1;k>=0;k--) begin
    if (ctx_active[k]) begin
      if (!vec_old_vld || iid_older7(ctx_iid[k], vec_old_iid)) begin
        vec_old_iid = ctx_iid[k];
        vec_old_vld = 1'b1;
      end
    end
  end
end

assign vec_st_cmit_vld = drain_owner_vld && ctx_active[drain_owner];
assign vec_st_cmit_iid = ctx_iid[drain_owner];

endmodule
