`include "rvv_backend.svh"

// ===========================================================================
// ct_idu_vec_ls_fill —— 向量 load/store 直连 fill 引擎 (2026-10-18 重写)
//
// 新架构:
//   * fill 自己算地址 / 组包, 直接发 {store, nop, addr16, bytes_vld, wdata,
//     lsid, fill_id, iid} 给 LSU 的 ct_lsu_vec_ls_fe (再驱动 dcache_arb),
//     不再合成 LBU/SB/LW/SW 标量 beat, 也不再经过 LSIQ 发射。
//   * load: 按 16B 对齐块 gather; 一笔请求取 16B, 响应按 fill_id 拼回 uop。
//     该笔走完 ld DA 即可发下一 beat, 数据响应可以晚到/乱序。
//   * store: 每个 4B 对齐字内严格选 32/16/8 最大连续宽度; 提交前逐笔进 SQ。
//   * 同一 uop 的 beat 串行; 不同 uop 由 FE 队列排序。
//   * 每个 uop 只有在所有 beat 都走完 DA (ctx_outs==0) 且 load 数据全部
//     回来 (ctx_pending==0) 后才回完成给 RVV。store 数据在 SQ 里等提交。
//   * LSIQ anchor 仍由 IS 建立, 但永久冻结; anchor 的 pop 由 ld_da/st_da 产生,
//     本模块只跟踪 anchor 的存活/最老状态。
//   * uop_idx 用 RVV 后端的 uop 索引, beat_idx 是本模块的 uop 内 beat 标签,
//     fill_id 只用于本模块与 LSU 的请求配对。
// ===========================================================================

module ct_idu_vec_ls_fill
(
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic         rtu_yy_xx_flush,

  // RTU commit 广播 (store 提交)
  input  logic         rtu_yy_xx_commit0,
  input  logic [6:0]   rtu_yy_xx_commit0_iid,
  input  logic         rtu_yy_xx_commit1,
  input  logic [6:0]   rtu_yy_xx_commit1_iid,
  input  logic         rtu_yy_xx_commit2,
  input  logic [6:0]   rtu_yy_xx_commit2_iid,
  // 2026-10-18: RTU 头部 3 条提交窗口 (电平) —— 向量 store 提前标记提交
  input  logic [2:0]   rtu_yy_xx_win_valid,
  input  logic [6:0]   rtu_yy_xx_win_iid0,
  input  logic [6:0]   rtu_yy_xx_win_iid1,
  input  logic [6:0]   rtu_yy_xx_win_iid2,

  // RvvCore → fill
  input  logic         rvv_lsu_uop_valid,
  input  UOP_RVV2LSU_t rvv_lsu_uop,
  output logic         rvv_lsu_uop_ready,
  output logic         rvv_lsu_resp_valid,
  output UOP_LSU2RVV_t rvv_lsu_resp,
  input  logic         rvv_lsu_resp_ready,

  // LSIQ anchor 广播
  input  logic [7:0]   lsiq_vec_create_entry,
  input  logic         lsiq_vec_create_vld,
  // create0/1 各自的 iid/store (同拍可能有两条向量 L/S)
  input  logic [7:0]   lsiq_create0_entry,
  input  logic [6:0]   lsiq_vec_create0_iid,
  input  logic         lsiq_vec_create0_store,
  input  logic [6:0]   lsiq_vec_create1_iid,
  input  logic         lsiq_vec_create1_store,
  input  logic [7:0]   lsiq_vec_old,
  input  logic [7:0]   lsu_idu_pop_entry,
  output logic [6:0]   vec_old_iid,
  output logic         vec_old_vld,

  // 直连 LSU 请求
  output logic         vec_ls_req_valid,
  input  logic         vec_ls_req_ready,
  output logic         vec_ls_req_store,
  output logic         vec_ls_req_nop,
  output logic         vec_ls_req_last,
  output logic [31:0]  vec_ls_req_addr,
  output logic [15:0]  vec_ls_req_bytes_vld,
  output logic [31:0]  vec_ls_req_wdata,
  output logic [2:0]   vec_ls_req_lsid,
  output logic [4:0]   vec_ls_req_fill_id,
  // 2026-10-18: uop_idx 是 RVV 后端给这条向量指令拆出的 uop 索引;
  // beat_idx 是本模块为同一 uop 内不同 beat 打的标签。
  output logic [4:0]   vec_ls_req_uop_idx,
  output logic [4:0]   vec_ls_req_beat_idx,
  output logic [6:0]   vec_ls_req_iid,

  // 直连 LSU 响应
  input  logic         vec_ls_rsp_valid,
  input  logic [4:0]   vec_ls_rsp_fill_id,
  input  logic         vec_ls_rsp_load,
  input  logic [127:0] vec_ls_rsp_data,
  input  logic [15:0]  vec_ls_rsp_bytes_vld,
  input  logic         vec_ls_req_done_vld,
  input  logic [4:0]   vec_ls_req_done_fill_id,

  // 给 SQ 的向量 store 提交电平
  output logic         vec_st_cmit_vld,
  output logic [6:0]   vec_st_cmit_iid,

  // 已提交但还有 beat 没进 SQ —— 喂 RTU 冲刷闸
  output logic         idu_lsu_cmit_vec_st_pending
);

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------
localparam NUM_ANC = 8;
localparam NUM_CTX = 8;
localparam NUM_REQ = 32;

localparam logic [$clog2(`VLENB):0] FF_TAIL_MAX = `VLENB;

// ---------------------------------------------------------------------------
// 工具函数 (沿用旧 fill)
// ---------------------------------------------------------------------------
function automatic logic iid_older7 (input logic [6:0] a, input logic [6:0] b);
  iid_older7 = (a[6] ^ b[6]) ? (a[5:0] > b[5:0]) : (a[5:0] < b[5:0]);
endfunction

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
  for (int b=0; b<16; b++) begin
    elem = ({4'b0, uop_index} + {5'b0, b[3:0]}) >> sh;
    calc_mask[b] = (elem < {1'b0, vl}) && (!v0_valid || v0_data[b]);
  end
endfunction

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
    3'd0: // US
      vec_byte_addr = base + {27'b0, uop_idx}*32'd16 + {28'b0, byte_pos};
    3'd2: // CS
      vec_byte_addr = base
                    + $signed(stride) * $signed({23'b0, elem})
                    + {28'b0, (byte_pos & ((8'd1 << sh) - 8'd1))};
    3'd1, 3'd3: begin // IU / IO
      sh2 = eew_shift(vs2_eew);
      vec_byte_addr = base
                    + $signed(vidx[((elem * (8'd1 << sh2)) & 5'h0F)*8 +: 32])
                      * $signed({29'b0, (8'd1 << sh)})
                    + {28'b0, (byte_pos & ((8'd1 << sh) - 8'd1))};
    end
    default:
      vec_byte_addr = base + {28'b0, byte_pos};
  endcase
endfunction

// ---------------------------------------------------------------------------
// Anchor 表 (按 lsid)
// ---------------------------------------------------------------------------
logic [NUM_ANC-1:0] anc_vld;
logic [NUM_ANC-1:0] anc_store;
logic [NUM_ANC-1:0] anc_committed;
logic [6:0]         anc_iid [0:NUM_ANC-1];

// ---------------------------------------------------------------------------
// uop context
// ---------------------------------------------------------------------------
logic [NUM_CTX-1:0]  ctx_vld;
logic [2:0]          ctx_lsid       [0:NUM_CTX-1];
logic [6:0]          ctx_iid        [0:NUM_CTX-1];
logic [4:0]          ctx_uop_index  [0:NUM_CTX-1];
logic [4:0]          ctx_dst_index  [0:NUM_CTX-1];
logic [2:0]          ctx_lsu_id     [0:NUM_CTX-1];
logic [4:0]          ctx_seq        [0:NUM_CTX-1];
logic                ctx_load       [0:NUM_CTX-1];
logic                ctx_last_uop   [0:NUM_CTX-1];
logic [2:0]          ctx_mop        [0:NUM_CTX-1];
logic [2:0]          ctx_vd_eew     [0:NUM_CTX-1];
logic [2:0]          ctx_vs2_eew    [0:NUM_CTX-1];
logic [7:0]          ctx_vl         [0:NUM_CTX-1];
logic [31:0]         ctx_base       [0:NUM_CTX-1];
logic [31:0]         ctx_stride     [0:NUM_CTX-1];
logic [127:0]        ctx_vidx       [0:NUM_CTX-1];
logic [15:0]         ctx_mask       [0:NUM_CTX-1];
logic [15:0]         ctx_pending    [0:NUM_CTX-1];
// load 已发出但数据还没回来的字节 (pending 是它的超集)
logic [15:0]         ctx_inflight  [0:NUM_CTX-1];
logic [127:0]        ctx_asm        [0:NUM_CTX-1];
logic [127:0]        ctx_stg_data   [0:NUM_CTX-1];

logic                ctx_req_vld    [0:NUM_CTX-1];   // 已发请求、尚未被 LSU 接收
logic [4:0]          ctx_beat_idx   [0:NUM_CTX-1];
logic [5:0]          ctx_outs       [0:NUM_CTX-1];   // 已接收但未完成(响应/done)的请求数
logic                ctx_need_nop   [0:NUM_CTX-1];
logic                ctx_resp_ready [0:NUM_CTX-1];

// ---------------------------------------------------------------------------
// request 表 (按 fill_id)
// ---------------------------------------------------------------------------
logic [NUM_REQ-1:0]  req_vld;
logic [2:0]          req_ctx   [0:NUM_REQ-1];
logic [15:0]         req_mask  [0:NUM_REQ-1];
logic [27:0]         req_blk   [0:NUM_REQ-1];
logic                req_store [0:NUM_REQ-1];
logic                req_nop   [0:NUM_REQ-1];
logic [4:0]          req_alloc_ptr;

// ---------------------------------------------------------------------------
// 其余状态
// ---------------------------------------------------------------------------
logic [4:0]          seq_cnt;

// ---------------------------------------------------------------------------
// 每 context 的逐字节地址
// ---------------------------------------------------------------------------
logic [31:0] caddr [0:NUM_CTX-1][0:15];
always_comb begin : caddr_calc
  for (int ci=0; ci<NUM_CTX; ci++) begin
    for (int bi=0; bi<16; bi++) begin
      caddr[ci][bi] = vec_byte_addr(ctx_mop[ci], ctx_base[ci], ctx_stride[ci],
                                    ctx_vidx[ci], ctx_vs2_eew[ci], ctx_vd_eew[ci],
                                    ctx_uop_index[ci], bi[3:0]);
    end
  end
end

// 同一 iid 的活跃 context 数 (final beat 的 LSIQ pop 需要等其它 uop 完成)
logic [3:0] same_iid_cnt [0:NUM_CTX-1];
always_comb begin : same_iid_calc
  for (int ci=0; ci<NUM_CTX; ci++) begin
    same_iid_cnt[ci] = 4'd0;
    for (int cj=0; cj<NUM_CTX; cj++)
      if (ctx_vld[cj] && (ctx_iid[cj] == ctx_iid[ci]))
        same_iid_cnt[ci] = same_iid_cnt[ci] + 4'd1;
  end
end

// ---------------------------------------------------------------------------
// Load 请求候选: 按 16B 对齐块 gather
// ---------------------------------------------------------------------------
logic [15:0] ld_req_mask [0:NUM_CTX-1];
logic [31:0] ld_req_addr [0:NUM_CTX-1];
logic [15:0] ld_req_bv   [0:NUM_CTX-1];
logic        ld_req_can  [0:NUM_CTX-1];
logic        ld_req_last [0:NUM_CTX-1];

always_comb begin : ld_cand_calc
  logic        found;
  logic [3:0]  first_b;
  logic [27:0] blk;
  logic [15:0] unreq;
  logic [15:0] rmask;
  logic [15:0] remain;

  for (int ci=0; ci<NUM_CTX; ci++) begin
    ld_req_mask[ci] = 16'd0;
    ld_req_addr[ci] = 32'd0;
    ld_req_bv[ci]   = 16'd0;
    ld_req_can[ci]  = 1'b0;
    ld_req_last[ci] = 1'b0;

    // 已发出、尚未回来的字节不再重复请求
    unreq = ctx_pending[ci] & ~ctx_inflight[ci];
    if (ctx_vld[ci] && ctx_load[ci] && !ctx_req_vld[ci] && (unreq != 16'd0)) begin
      found   = 1'b0;
      first_b = 4'd0;
      for (int k=0; k<16; k++) begin
        if (!found && unreq[k]) begin
          first_b = k[3:0];
          found   = 1'b1;
        end
      end
      blk = caddr[ci][first_b][31:4];
      rmask = 16'd0;
      for (int k=0; k<16; k++) begin
        if (unreq[k] && (caddr[ci][k][31:4] == blk)) begin
          rmask[k] = 1'b1;
          ld_req_bv[ci][caddr[ci][k][3:0]] = 1'b1;
        end
      end
      remain = unreq & ~rmask;     // 还没请求过的剩余字节
      ld_req_mask[ci] = rmask;
      ld_req_addr[ci] = {blk, 4'b0};
      ld_req_last[ci] = ctx_last_uop[ci] && (remain == 16'd0) &&
                        (same_iid_cnt[ci] == 4'd1);
      // 最后一个 uop 的最后一笔要等其它 uop 都完成才能发 (避免 anchor 提前 pop 后 lsid 复用)
      ld_req_can[ci]  = lsiq_vec_old[ctx_lsid[ci]] &&
                        !(ctx_last_uop[ci] && (remain == 16'd0) &&
                          (same_iid_cnt[ci] > 4'd1));
    end
  end
end

// ---------------------------------------------------------------------------
// Store 请求候选: 4B 字内严格 32/16/8 最大连续宽度
// ---------------------------------------------------------------------------
logic [15:0] st_req_mask [0:NUM_CTX-1];
logic [31:0] st_req_addr [0:NUM_CTX-1];
logic [15:0] st_req_bv   [0:NUM_CTX-1];
logic [31:0] st_req_data [0:NUM_CTX-1];
logic        st_req_can  [0:NUM_CTX-1];
logic        st_req_last [0:NUM_CTX-1];

// store 必须严格按 uop 顺序进入 SQ: 先找出所有活跃 store context 里 seq 最小的
// (它没发完之前, 后面的 context 一律不许发)
logic        st_old_vld;
logic [3:0]  st_old_ctx;
logic [4:0]  st_old_seq;
always_comb begin : st_old_calc
  st_old_vld = 1'b0;
  st_old_ctx = 4'd0;
  st_old_seq = 5'h1F;
  for (int sc=0; sc<NUM_CTX; sc++) begin
    if (ctx_vld[sc] && !ctx_load[sc]) begin
      if (!st_old_vld || (ctx_seq[sc] < st_old_seq)) begin
        st_old_vld = 1'b1;
        st_old_ctx = sc[3:0];
        st_old_seq = ctx_seq[sc];
      end
    end
  end
end

always_comb begin : st_cand_calc
  logic        found;
  logic [3:0]  first_b;
  logic [29:0] word_base;
  logic [3:0]  word_mask;
  logic [1:0]  grp_off;
  logic [2:0]  grp_size;
  logic [15:0] srmask;
  logic [31:0] sdata;
  logic [3:0]  grp_lo;
  logic [3:0]  wb;
  logic [31:0] grp_addr;
  logic [15:0] remain;

  for (int ci=0; ci<NUM_CTX; ci++) begin
    st_req_mask[ci] = 16'd0;
    st_req_addr[ci] = 32'd0;
    st_req_bv[ci]   = 16'd0;
    st_req_data[ci] = 32'd0;
    st_req_can[ci]  = 1'b0;
    st_req_last[ci] = 1'b0;

    if (ctx_vld[ci] && !ctx_load[ci] && !ctx_req_vld[ci] && (ctx_pending[ci] != 16'd0)) begin
      found   = 1'b0;
      first_b = 4'd0;
      for (int k=0; k<16; k++) begin
        if (!found && ctx_pending[ci][k]) begin
          first_b = k[3:0];
          found   = 1'b1;
        end
      end
      word_base = caddr[ci][first_b][31:2];
      word_mask = 4'd0;
      for (int k=0; k<16; k++) begin
        if (ctx_pending[ci][k] && (caddr[ci][k][31:2] == word_base))
          word_mask[caddr[ci][k][1:0]] = 1'b1;
      end

      // 32/16/8 选择
      grp_off  = 2'd0;
      grp_size = 3'd1;
      if (word_mask == 4'b1111) begin
        grp_off  = 2'd0;
        grp_size = 3'd4;
      end
      else if (word_mask[1:0] == 2'b11) begin
        grp_off  = 2'd0;
        grp_size = 3'd2;
      end
      else if (word_mask[3:2] == 2'b11) begin
        grp_off  = 2'd2;
        grp_size = 3'd2;
      end
      else begin
        // 最低的有效字节
        grp_off = 2'd0;
        for (int k=0; k<4; k++)
          if (word_mask[k]) begin
            grp_off = k[1:0];
            break;
          end
        grp_size = 3'd1;
      end

      grp_addr = {word_base, grp_off};
      grp_lo   = grp_addr[3:0];

      // 收集本组的输出字节 (重复地址也一并清掉 pending)
      srmask = 16'd0;
      sdata  = 32'd0;
      for (int gi=0; gi<4; gi++) begin
        if (gi < grp_size) begin
          wb = grp_lo + gi[3:0];
          st_req_bv[ci][wb] = 1'b1;
          for (int k=0; k<16; k++) begin
            if (ctx_pending[ci][k] &&
                (caddr[ci][k][31:2] == word_base) &&
                (caddr[ci][k][1:0] == (grp_off + gi[1:0]))) begin
              srmask[k] = 1'b1;
              // SQ 的 32 位数据会按 4 个 lane 复制, bytes_vld 选 lane;
              // 数据本身按 4B 字内偏移摆放 (不是 16B 块内偏移)。
              sdata[(grp_off + gi[1:0])*8 +: 8] = ctx_stg_data[ci][k*8 +: 8];
            end
          end
        end
      end

      remain = ctx_pending[ci] & ~srmask;
      st_req_mask[ci] = srmask;
      st_req_addr[ci] = {grp_addr[31:4], 4'b0};
      st_req_data[ci] = sdata;
      st_req_last[ci] = ctx_last_uop[ci] && (remain == 16'd0) &&
                        (same_iid_cnt[ci] == 4'd1);
      st_req_can[ci]  = lsiq_vec_old[ctx_lsid[ci]] &&
                        st_old_vld && (ci[3:0] == st_old_ctx) &&
                        !(ctx_last_uop[ci] && (remain == 16'd0) &&
                          (same_iid_cnt[ci] > 4'd1));
    end
  end
end

// ---------------------------------------------------------------------------
// 请求仲裁: store 先 (按 seq 最老), 再 load (按 context 序)
// ---------------------------------------------------------------------------
logic        issue_vld;
logic        issue_store;
logic        issue_nop;
logic        issue_last;
logic [31:0] issue_addr;
logic [15:0] issue_bv;
logic [31:0] issue_data;
logic [2:0]  issue_ctx;
logic [15:0] issue_mask;

logic        st_any;
logic [3:0]  st_sel;
logic [4:0]  st_min_seq;
logic        ld_any;
logic [3:0]  ld_sel;

always_comb begin
  st_any     = 1'b0;
  st_sel     = 4'd0;
  st_min_seq = 5'h1F;
  for (int ci0=0; ci0<NUM_CTX; ci0++) begin
    if (st_req_can[ci0] && ctx_vld[ci0]) begin
      if (!st_any || (ctx_seq[ci0] < st_min_seq)) begin
        st_any     = 1'b1;
        st_sel     = ci0[3:0];
        st_min_seq = ctx_seq[ci0];
      end
    end
  end

  ld_any = 1'b0;
  ld_sel = 4'd0;
  for (int ci1=NUM_CTX-1; ci1>=0; ci1--) begin
    if (ld_req_can[ci1] && ctx_vld[ci1]) begin
      ld_any = 1'b1;
      ld_sel = ci1[3:0];
    end
  end

  // 零掩码的最后一个 uop: 需要一笔 nop 请求去触发 LSIQ pop
  issue_vld   = 1'b0;
  issue_store = 1'b0;
  issue_nop   = 1'b0;
  issue_last  = 1'b0;
  issue_addr  = 32'd0;
  issue_bv    = 16'd0;
  issue_data  = 32'd0;
  issue_ctx   = 3'd0;
  issue_mask  = 16'd0;

  for (int ci2=NUM_CTX-1; ci2>=0; ci2--) begin
    if (ctx_vld[ci2] && ctx_need_nop[ci2] && !ctx_req_vld[ci2] &&
        lsiq_vec_old[ctx_lsid[ci2]] && (same_iid_cnt[ci2] == 4'd1) &&
        (ctx_load[ci2] || (st_old_vld && (ci2[3:0] == st_old_ctx)))) begin
      issue_vld   = 1'b1;
      issue_store = !ctx_load[ci2];
      issue_nop   = 1'b1;
      issue_last  = 1'b1;
      issue_ctx   = ci2[2:0];
      issue_mask  = 16'd0;
    end
  end

  if (!issue_vld && st_any) begin
    issue_vld   = 1'b1;
    issue_store = 1'b1;
    issue_nop   = 1'b0;
    issue_addr  = st_req_addr[st_sel];
    issue_bv    = st_req_bv[st_sel];
    issue_data  = st_req_data[st_sel];
    issue_last  = st_req_last[st_sel];
    issue_ctx   = st_sel[2:0];
    issue_mask  = st_req_mask[st_sel];
  end
  else if (!issue_vld && ld_any) begin
    issue_vld   = 1'b1;
    issue_store = 1'b0;
    issue_nop   = 1'b0;
    issue_addr  = ld_req_addr[ld_sel];
    issue_bv    = ld_req_bv[ld_sel];
    issue_data  = 32'd0;
    issue_last  = ld_req_last[ld_sel];
    issue_ctx   = ld_sel[2:0];
    issue_mask  = ld_req_mask[ld_sel];
  end
end

// free fill_id
function automatic logic [4:0] pick_req (input logic [NUM_REQ-1:0] used,
                                         input logic [4:0]        start);
  logic [2*NUM_REQ-1:0] used2;
  used2 = {used, used};
  pick_req = start;
  for (int j=NUM_REQ-1; j>=0; j--) begin
    if (!used2[start + j[4:0]]) pick_req = start + j[4:0];
  end
endfunction

logic [4:0] issue_req;
logic       req_free;
assign issue_req = pick_req(req_vld, req_alloc_ptr);
assign req_free  = ~(&req_vld);   // 至少一个空槽

assign vec_ls_req_valid     = issue_vld && req_free && !rtu_yy_xx_flush;
assign vec_ls_req_store     = issue_store;
assign vec_ls_req_nop       = issue_nop;
assign vec_ls_req_last      = issue_last;
assign vec_ls_req_addr      = issue_addr;
assign vec_ls_req_bytes_vld = issue_bv;
assign vec_ls_req_wdata     = issue_data;
assign vec_ls_req_lsid      = ctx_lsid[issue_ctx];
assign vec_ls_req_fill_id   = issue_req;
assign vec_ls_req_uop_idx   = ctx_uop_index[issue_ctx];
assign vec_ls_req_beat_idx  = ctx_beat_idx[issue_ctx];
assign vec_ls_req_iid       = ctx_iid[issue_ctx];

wire issue_fire = vec_ls_req_valid && vec_ls_req_ready;

// ---------------------------------------------------------------------------
// RVV uop 接收
// ---------------------------------------------------------------------------
logic        free_ctx_vld;
logic [3:0]  free_ctx;
always_comb begin : free_ctx_calc
  free_ctx_vld = 1'b0;
  free_ctx     = 4'd0;
  for (int ci=0; ci<NUM_CTX; ci++) begin
    if (!ctx_vld[ci]) begin
      free_ctx_vld = 1'b1;
      free_ctx     = ci[3:0];
      break;
    end
  end
end

wire [2:0] uop_lsid = rvv_lsu_uop.lsid;
wire       uop_anc_ok = anc_vld[uop_lsid] &&
                        (anc_iid[uop_lsid] == rvv_lsu_uop.rob_tag) &&
                        (anc_store[uop_lsid] == rvv_lsu_uop.lsu_is_store);

assign rvv_lsu_uop_ready = !rtu_yy_xx_flush &&
                           free_ctx_vld &&
                           uop_anc_ok;

wire uop_accept = rvv_lsu_uop_valid && rvv_lsu_uop_ready;

wire [15:0] uop_mask = calc_mask(rvv_lsu_uop.v0_data,
                                 rvv_lsu_uop.v0_valid,
                                 rvv_lsu_uop.vl[7:0],
                                 rvv_lsu_uop.uop_index,
                                 rvv_lsu_uop.vd_eew);

// ---------------------------------------------------------------------------
// 响应
// ---------------------------------------------------------------------------
// 完成响应: 一个 context 只有在所有 beat 都被 LSU 接收/完成 (ctx_outs==0)
// 且所有字节都已回来 (ctx_pending==0) 后才能回给 RVV。
logic        store_resp_vld;
logic [3:0]  store_resp_ctx;
logic        load_resp_vld;
logic [3:0]  load_resp_ctx;

always_comb begin : resp_sel_calc
  logic [4:0] min_seq;
  store_resp_vld = 1'b0;
  store_resp_ctx = 4'd0;
  load_resp_vld  = 1'b0;
  load_resp_ctx  = 4'd0;

  min_seq = 5'h1F;
  for (int ci=0; ci<NUM_CTX; ci++) begin
    if (ctx_vld[ci] && !ctx_load[ci] && !ctx_need_nop[ci] &&
        (ctx_outs[ci] == 6'd0) && (ctx_pending[ci] == 16'd0) &&
        ctx_resp_ready[ci] && (!store_resp_vld || (ctx_seq[ci] < min_seq))) begin
      store_resp_vld = 1'b1;
      store_resp_ctx = ci[3:0];
      min_seq        = ctx_seq[ci];
    end
  end

  min_seq = 5'h1F;
  for (int ci=0; ci<NUM_CTX; ci++) begin
    if (ctx_vld[ci] && ctx_load[ci] && !ctx_need_nop[ci] &&
        (ctx_outs[ci] == 6'd0) && (ctx_pending[ci] == 16'd0) &&
        ctx_resp_ready[ci] && (!load_resp_vld || (ctx_seq[ci] < min_seq))) begin
      load_resp_vld = 1'b1;
      load_resp_ctx = ci[3:0];
      min_seq       = ctx_seq[ci];
    end
  end
end

assign rvv_lsu_resp_valid = !rtu_yy_xx_flush && (store_resp_vld || load_resp_vld);

always_comb begin
  rvv_lsu_resp = '0;
  if (store_resp_vld) begin
    rvv_lsu_resp.rob_tag              = ctx_iid[store_resp_ctx];
    rvv_lsu_resp.uop_index            = ctx_uop_index[store_resp_ctx];
    rvv_lsu_resp.lsu_id               = ctx_lsu_id[store_resp_ctx];
    rvv_lsu_resp.vregfile_write_valid = 1'b0;
    rvv_lsu_resp.lsu_vstore_last      = 1'b1;
    rvv_lsu_resp.ff_tail_index        = FF_TAIL_MAX;
  end
  else begin
    rvv_lsu_resp.rob_tag              = ctx_iid[load_resp_ctx];
    rvv_lsu_resp.uop_index            = ctx_uop_index[load_resp_ctx];
    rvv_lsu_resp.lsu_id               = ctx_lsu_id[load_resp_ctx];
    rvv_lsu_resp.vregfile_write_valid = 1'b1;
    rvv_lsu_resp.vregfile_write_addr  = ctx_dst_index[load_resp_ctx];
    rvv_lsu_resp.vregfile_write_data  = ctx_asm[load_resp_ctx];
    rvv_lsu_resp.lsu_vstore_last      = 1'b0;
    rvv_lsu_resp.ff_tail_index        = FF_TAIL_MAX;
  end
end

wire resp_fire = rvv_lsu_resp_valid && rvv_lsu_resp_ready;

// ---------------------------------------------------------------------------
// 响应/完成事件
// ---------------------------------------------------------------------------
wire ld_rsp_hit   = vec_ls_rsp_valid;
wire ld_rsp_is_data = ld_rsp_hit && !req_store[vec_ls_rsp_fill_id];
wire done_hit     = vec_ls_req_done_vld;

wire [4:0] rsp_id  = vec_ls_rsp_fill_id;
wire [4:0] done_id = vec_ls_req_done_fill_id;

// 该请求是否 store/nop (避免越界/无效)
wire rsp_req_vld  = req_vld[rsp_id];
wire done_req_vld = req_vld[done_id];

// ---------------------------------------------------------------------------
// 主状态机
// ---------------------------------------------------------------------------
integer x;
always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    anc_vld       <= '0;
    anc_store     <= '0;
    anc_committed <= '0;
    ctx_vld       <= '0;
    req_vld       <= '0;
    req_alloc_ptr <= 5'd0;
    seq_cnt       <= 5'd0;
    for (x=0; x<NUM_ANC; x++) anc_iid[x] <= 7'd0;
    for (x=0; x<NUM_CTX; x++) begin
      ctx_lsid[x]       <= 3'd0;
      ctx_iid[x]        <= 7'd0;
      ctx_uop_index[x]  <= 5'd0;
      ctx_dst_index[x]  <= 5'd0;
      ctx_lsu_id[x]     <= 3'd0;
      ctx_seq[x]        <= 5'd0;
      ctx_load[x]       <= 1'b0;
      ctx_last_uop[x]   <= 1'b0;
      ctx_mop[x]        <= 3'd0;
      ctx_vd_eew[x]     <= 3'd0;
      ctx_vs2_eew[x]    <= 3'd0;
      ctx_vl[x]         <= 8'd0;
      ctx_base[x]       <= 32'd0;
      ctx_stride[x]     <= 32'd0;
      ctx_vidx[x]       <= 128'd0;
      ctx_mask[x]       <= 16'd0;
      ctx_pending[x]    <= 16'd0;
      ctx_inflight[x]   <= 16'd0;
      ctx_asm[x]        <= 128'd0;
      ctx_stg_data[x]   <= 128'd0;
      ctx_req_vld[x]    <= 1'b0;
      ctx_beat_idx[x]   <= 5'd0;
      ctx_outs[x]       <= 6'd0;
      ctx_need_nop[x]   <= 1'b0;
      ctx_resp_ready[x] <= 1'b0;
    end
  end
  else if (rtu_yy_xx_flush) begin
    anc_vld       <= '0;
    anc_store     <= '0;
    anc_committed <= '0;
    ctx_vld       <= '0;
    req_vld       <= '0;
    for (x=0; x<NUM_CTX; x++) begin
      ctx_req_vld[x]    <= 1'b0;
      ctx_beat_idx[x]   <= 5'd0;
      ctx_outs[x]       <= 6'd0;
      ctx_need_nop[x]   <= 1'b0;
      ctx_resp_ready[x] <= 1'b0;
      ctx_pending[x]    <= 16'd0;
      ctx_inflight[x]   <= 16'd0;
    end
  end
  else begin
    // ---------------- anchor create / pop / commit ----------------
    if (lsiq_vec_create_vld) begin
      for (x=0; x<NUM_ANC; x++) begin
        if (lsiq_vec_create_entry[x]) begin
          anc_vld[x]       <= 1'b1;
          // lsiq_create0_entry 为 1 ⇒ 该表项来自 create0, 否则来自 create1
          anc_store[x]     <= lsiq_create0_entry[x] ? lsiq_vec_create0_store
                                                    : lsiq_vec_create1_store;
          anc_iid[x]       <= lsiq_create0_entry[x] ? lsiq_vec_create0_iid
                                                    : lsiq_vec_create1_iid;
          anc_committed[x] <= 1'b0;
        end
      end
    end
    for (x=0; x<NUM_ANC; x++) begin
      if (lsu_idu_pop_entry[x] && !(lsiq_vec_create_entry[x] && lsiq_vec_create_vld)) begin
        anc_vld[x]       <= 1'b0;
        anc_committed[x] <= 1'b0;
      end
    end
    // 2026-10-18: 除了真正的退休广播, 只要该向量 store 的 iid 进入 RTU 头部
    // 3 条提交窗口, 就持续(锁存)标记为 committed, 让 SQ 提前弹到 WMB, 断开
    // "SQ 满 -> beat 发不出 -> 指令完不成 -> 不提交" 的环。RTU 自身仍只在
    // 收到 cmplt 后退休, 不会被这个电平带早。
    for (x=0; x<NUM_ANC; x++) begin
      if (anc_vld[x] && anc_store[x] &&
          !(lsiq_vec_create_vld && lsiq_vec_create_entry[x]) &&
          ((rtu_yy_xx_commit0 && (anc_iid[x] == rtu_yy_xx_commit0_iid)) ||
           (rtu_yy_xx_commit1 && (anc_iid[x] == rtu_yy_xx_commit1_iid)) ||
           (rtu_yy_xx_commit2 && (anc_iid[x] == rtu_yy_xx_commit2_iid)) ||
           (rtu_yy_xx_win_valid[0] && (anc_iid[x] == rtu_yy_xx_win_iid0)) ||
           (rtu_yy_xx_win_valid[1] && (anc_iid[x] == rtu_yy_xx_win_iid1)) ||
           (rtu_yy_xx_win_valid[2] && (anc_iid[x] == rtu_yy_xx_win_iid2))))
        anc_committed[x] <= 1'b1;
    end

    // ---------------- uop accept ----------------
    if (uop_accept) begin
      ctx_vld[free_ctx]       <= 1'b1;
      ctx_lsid[free_ctx]      <= rvv_lsu_uop.lsid;
      ctx_iid[free_ctx]       <= rvv_lsu_uop.rob_tag;
      ctx_uop_index[free_ctx] <= rvv_lsu_uop.uop_index;
      ctx_dst_index[free_ctx] <= rvv_lsu_uop.dst_index;
      ctx_lsu_id[free_ctx]    <= rvv_lsu_uop.lsu_id;
      ctx_seq[free_ctx]       <= seq_cnt;
      ctx_load[free_ctx]      <= !rvv_lsu_uop.lsu_is_store;
      ctx_last_uop[free_ctx]  <= rvv_lsu_uop.last_uop_valid;
      ctx_mop[free_ctx]       <= rvv_lsu_uop.lsu_type.lsu_mop;
      ctx_vd_eew[free_ctx]    <= rvv_lsu_uop.vd_eew;
      ctx_vs2_eew[free_ctx]   <= rvv_lsu_uop.vs2_eew;
      ctx_vl[free_ctx]        <= rvv_lsu_uop.vl[7:0];
      ctx_base[free_ctx]      <= rvv_lsu_uop.rs1_data;
      ctx_stride[free_ctx]    <= rvv_lsu_uop.rs2_data;
      ctx_vidx[free_ctx]      <= rvv_lsu_uop.vidx_data;
      ctx_mask[free_ctx]      <= uop_mask;
      ctx_pending[free_ctx]   <= uop_mask;
      ctx_inflight[free_ctx]  <= 16'd0;
      ctx_asm[free_ctx]       <= 128'd0;
      ctx_stg_data[free_ctx]  <= rvv_lsu_uop.vregfile_read_data;
      ctx_req_vld[free_ctx]   <= 1'b0;
      ctx_beat_idx[free_ctx]  <= 5'd0;
      ctx_outs[free_ctx]      <= 6'd0;
      ctx_need_nop[free_ctx]  <= (uop_mask == 16'd0) && rvv_lsu_uop.last_uop_valid;
      ctx_resp_ready[free_ctx]<= (uop_mask == 16'd0) && !rvv_lsu_uop.last_uop_valid;
      seq_cnt                 <= seq_cnt + 5'd1;
    end

    // ---------------- 请求发射 ----------------
    if (issue_fire) begin
      req_vld[issue_req]  <= 1'b1;
      req_ctx[issue_req]  <= issue_ctx;
      req_mask[issue_req] <= issue_mask;
      req_blk[issue_req]  <= issue_addr[31:4];
      req_store[issue_req]<= issue_store;
      req_nop[issue_req]  <= issue_nop;
      req_alloc_ptr       <= issue_req + 5'd1;

      // 同一 uop 的 beat 串行: 等上一笔被 LSU 接收 (done) 后才允许下一笔。
      ctx_req_vld[issue_ctx]   <= 1'b1;
      ctx_beat_idx[issue_ctx]  <= ctx_beat_idx[issue_ctx] + 5'd1;
      if (!issue_store && !issue_nop)
        ctx_inflight[issue_ctx] <= ctx_inflight[issue_ctx] | issue_mask;
      if (issue_nop)
        ctx_need_nop[issue_ctx] <= 1'b0;
    end

    // ---------------- load 数据响应 ----------------
    if (ld_rsp_hit && rsp_req_vld && !req_store[rsp_id] && !req_nop[rsp_id]) begin
      for (x=0; x<16; x++) begin
        if (req_mask[rsp_id][x] && (caddr[req_ctx[rsp_id]][x][31:4] == req_blk[rsp_id])) begin
          ctx_asm[req_ctx[rsp_id]][x*8 +: 8] <=
              vec_ls_rsp_data[caddr[req_ctx[rsp_id]][x][3:0]*8 +: 8];
          ctx_pending[req_ctx[rsp_id]][x] <= 1'b0;
        end
      end
      req_vld[rsp_id] <= 1'b0;
      ctx_inflight[req_ctx[rsp_id]] <=
          ctx_inflight[req_ctx[rsp_id]] & ~req_mask[rsp_id];
    end

    // ---------------- done: LSU 接收/完成一笔请求 ----------------
    // load: DA 通过即 done (数据可能稍后由 MSHR 返回) —— 立即放行下一 beat。
    // store/nop: st DA 通过即 done, 同时清掉该笔的 pending。
    if (done_hit && done_req_vld) begin
      ctx_req_vld[req_ctx[done_id]] <= 1'b0;

      if (req_store[done_id]) begin
        for (x=0; x<16; x++)
          if (req_mask[done_id][x])
            ctx_pending[req_ctx[done_id]][x] <= 1'b0;
        req_vld[done_id] <= 1'b0;
      end
      else if (req_nop[done_id]) begin
        req_vld[done_id] <= 1'b0;
      end
      // load: req_vld 保留到数据响应, ctx_outs 在响应时减
    end

    // ---------------- ctx_outs 计数 (issue +, load rsp -, store/nop done -) ----------------
    // 同一拍可能"上一笔响应"与"下一笔发射"落在同一 context, 必须合并成一次更新。
    for (x=0; x<NUM_CTX; x++) begin
      logic inc_x, dec_x;
      inc_x = issue_fire && (issue_ctx == x[3:0]);
      dec_x = (ld_rsp_hit && rsp_req_vld && !req_store[rsp_id] && !req_nop[rsp_id] &&
               (req_ctx[rsp_id] == x[3:0])) ||
              (done_hit && done_req_vld && (req_store[done_id] || req_nop[done_id]) &&
               (req_ctx[done_id] == x[3:0]));
      if (inc_x && !dec_x)
        ctx_outs[x] <= ctx_outs[x] + 6'd1;
      else if (!inc_x && dec_x)
        ctx_outs[x] <= ctx_outs[x] - 6'd1;
    end

    // ---------------- 完成判定 ----------------
    for (x=0; x<NUM_CTX; x++) begin
      if (ctx_vld[x] && !ctx_need_nop[x] &&
          (ctx_outs[x] == 6'd0) && (ctx_pending[x] == 16'd0))
        ctx_resp_ready[x] <= 1'b1;
    end

    // ---------------- 完成响应被 RVV 接收 → 释放 context ----------------
    if (resp_fire) begin
      if (store_resp_vld)
        ctx_vld[store_resp_ctx] <= 1'b0;
      else
        ctx_vld[load_resp_ctx]  <= 1'b0;
    end
  end
end

// ---------------------------------------------------------------------------
// vec_old / store commit level
// ---------------------------------------------------------------------------
always_comb begin : vec_old_calc
  vec_old_vld = 1'b0;
  vec_old_iid = 7'd0;
  for (int xi=0; xi<NUM_ANC; xi++) begin
    if (anc_vld[xi]) begin
      if (!vec_old_vld || iid_older7(anc_iid[xi], vec_old_iid)) begin
        vec_old_iid = anc_iid[xi];
        vec_old_vld = 1'b1;
      end
    end
  end
end

always_comb begin : vec_st_cmit_calc
  vec_st_cmit_vld = 1'b0;
  vec_st_cmit_iid = 7'd0;
  for (int xi=0; xi<NUM_ANC; xi++) begin
    if (anc_vld[xi] && anc_store[xi] && anc_committed[xi]) begin
      if (!vec_st_cmit_vld || iid_older7(anc_iid[xi], vec_st_cmit_iid)) begin
        vec_st_cmit_iid = anc_iid[xi];
        vec_st_cmit_vld = 1'b1;
      end
    end
  end
end

// 已提交 store 还有 beat 没进 SQ: RTU 在这段时间内不许发后端 flush
always_comb begin : cmit_st_pending_calc
  idu_lsu_cmit_vec_st_pending = 1'b0;
  for (int xi=0; xi<NUM_CTX; xi++) begin
    if (ctx_vld[xi] && !ctx_load[xi] && anc_committed[ctx_lsid[xi]] &&
        ((ctx_pending[xi] != 16'd0) || ctx_req_vld[xi] || ctx_need_nop[xi]))
      idu_lsu_cmit_vec_st_pending = 1'b1;
  end
end

endmodule
