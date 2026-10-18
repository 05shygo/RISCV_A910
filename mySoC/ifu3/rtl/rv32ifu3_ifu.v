`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_ifu — 3 级取指流水 (S0/S1/S2)
//
// 与香山 IFU 的对应关系 (RV32I 无 RVC, 16 B 块 = 4 条 4 B 指令, 所以边界
// 识别/压缩/RVC 展开全部不需要):
//   S0: 从 FTQ 取一个预测块, 发 ICache 行地址; 命中后把 {line, 元信息} 存下
//   S1: 4 条固定 PC, 生成/寄存; (Phase 2 在这里做 RV32I 预译码和预测检查)
//   S2: 组 128-bit packet + 25-bit chk, 按 IBUF 空位推前缀; 整块推完才 pop FTQ
//
// 关键不变量:
//   * S0/S1/S2 各自持有自己的 line 寄存器; S2 被 IBUF 反压时从自己的寄存器
//     重试剩余 lane, 不重读 ICache。
//   * FTQ 只在 S2 把本块最后一条 lane 推进 IBUF 后才 pop; 3 lane 交付 4 条
//     指令时不会丢第四 lane。
//   * startPc 可以不是 16 B 对齐: pc_ofs = startPc[3:2], 只交付 slot >= pc_ofs;
//     无 taken 时下一块由 BPU 给 align16(startPc)+16。
// ===========================================================================
module rv32ifu3_ifu (
    input  wire         clk,
    input  wire         rst,              // 高有效

    // ---- FTQ 读口 ----
    input  wire         ftq_rd_valid,
    input  wire [ 31:0] ftq_rd_start_pc,
    input  wire         ftq_rd_taken,
    input  wire [  1:0] ftq_rd_taken_slot,
    input  wire [ 31:0] ftq_rd_target,
    input  wire [  3:0] ftq_rd_btb_cond,
    input  wire [ 15:0] ftq_rd_phr,
    input  wire [  5:0] ftq_rd_meta_id,
    input  wire [  3:0] ftq_rd_ptr,
    input  wire [  3:0] ftq_head_idx,
    output wire [  2:0] ftq_inflight,
    output wire         ftq_finish,

    // ---- BPU S2 override: 丢弃 idx >= ovr_idx 的年轻项 ----
    input  wire         ovr_valid,
    input  wire [  3:0] ovr_idx,

    // ---- EX 重定向当拍的 chk/分支 PC (RAS 回滚用) ----
    input  wire [ 24:0] iu_btb_chk,
    input  wire [ 31:0] iu_btb_pc,
    input  wire         iu_btb_taken,
    input  wire         redirect_rtu,

    // ---- 退休训练 (只给 RAS 推进 commit 指针用) ----
    input  wire         rtu_train_vld,
    input  wire [ 24:0] rtu_train_chk,

    // ---- IFU 自己发起的 override (PredChecker) ----
    output wire         ifu_ovr_valid,
    output wire [  3:0] ifu_ovr_idx,
    output wire         ifu_ovr_taken,
    output wire [  1:0] ifu_ovr_taken_slot,
    output wire [ 31:0] ifu_ovr_target,
    output wire [  3:0] ifu_ovr_btb_cond,
    output wire [ 15:0] ifu_ovr_phr,

    // ---- ICache 读口 ----
    output wire [ 31:0] ic_rd_addr,
    input  wire [ 31:0] ic_q_pc,
    input  wire [127:0] ic_q_data,
    input  wire         ic_q_hit,
    output wire         ic_req_active,   // S0 正等这一行的结果 (给 refill 门控)

    // ---- IBUF 入队口 (复用 rv32ifu2_ibuf) ----
    output wire [  3:0] ib_push_mask,
    output wire [152:0] ib_push_data0,
    output wire [152:0] ib_push_data1,
    output wire [152:0] ib_push_data2,
    output wire [152:0] ib_push_data3,
    input  wire [  2:0] ib_push_accept,
    input  wire [  3:0] ib_count,

    // ---- 控制 ----
    input  wire         redirect,
    input  wire [ 31:0] redirect_pc,
    input  wire         init_done
);

// override 年龄比较 (先声明, 后面的 assign 使用)
wire [3:0] ovr_dist;

// ---------------------------------------------------------------------------
// 包格式 (与 rv32ifu2_top.v 完全一致, 不能改)
//   [31:0] inst  [63:32] PC  [95:64] pred_npc  [96] fault
//   [100:97] cause  [104:101] attr  [105] pc_oper  [108:106] cf_type
//   [121:109] token  [122] pred_taken  [127:123] 保留
// ---------------------------------------------------------------------------
function [127:0] make_packet;
    input [31:0] pc;
    input [31:0] inst;
    input [31:0] pred_npc;
    input        pred_taken;
    begin
        make_packet = {
            5'b0,               // [127:123]
            pred_taken,         // [122]
            13'b0,              // [121:109]
            3'b0,               // [108:106]
            1'b0,               // [105]
            4'b0,               // [104:101]
            4'b0,               // [100:97]
            1'b0,               // [96]
            pred_npc,           // [95:64]
            pc,                 // [63:32]
            inst                // [31:0]
        };
    end
endfunction

function [31:0] pick_word;
    input [127:0] line;
    input [  1:0] idx;
    begin
        case (idx)
            2'd0: pick_word = line[ 31:  0];
            2'd1: pick_word = line[ 63: 32];
            2'd2: pick_word = line[ 95: 64];
            default: pick_word = line[127: 96];
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// S0: 发 ICache 行读, 等 q_hit, 把整行 + FTQ 元信息存进 s0_resp
// ---------------------------------------------------------------------------
reg         s0_busy;
reg [ 31:0] s0_req_start_pc;
reg         s0_req_taken;
reg [  1:0] s0_req_taken_slot;
reg [ 31:0] s0_req_target;
reg [  3:0] s0_req_btb_cond;
reg [ 15:0] s0_req_phr;
reg [  5:0] s0_req_meta_id;
reg [ 31:0] s0_req_addr;
reg [  3:0] s0_req_idx;

reg         s0_resp_valid;
reg [ 31:0] s0_resp_start_pc;
reg         s0_resp_taken;
reg [  1:0] s0_resp_taken_slot;
reg [ 31:0] s0_resp_target;
reg [  3:0] s0_resp_btb_cond;
reg [ 15:0] s0_resp_phr;
reg [  5:0] s0_resp_meta_id;
reg [127:0] s0_resp_data;
reg [  3:0] s0_resp_idx;

wire [31:0] ftq_rd_line_pc = {ftq_rd_start_pc[31:4], 4'b0};
wire        s0_hit   = s0_busy && ic_q_hit;   // 本拍 ICache 返回当前请求
wire        s1_ready;                         // = !s1_valid || s1_fire (下面赋值)
// 1 块/拍: 响应可以直接旁路进 S1, 同拍再发下一块; S1 接不走时落 skid。
// IFU override 对外打了一拍 (top 里的 ifu_ovr_*_q)。FTQ 的 count 截断/BPU 重启
// 因此晚一拍, S0 也必须晚一拍再发新块, 否则会在 N+1 把将要被 override 丢弃的
// 年轻块先读进来, 而 IFU 自己不会丢弃它。hold 只闸 s0_issue; S1 仍用当拍
// ifu_ovr_valid 闸 fire, 保证 RAS 动作按修正后的 end_slot 应用。
reg ifu_ovr_hold_q;
always @(posedge clk) begin
    if (rst || redirect) ifu_ovr_hold_q <= 1'b0;
    else if (ifu_ovr_valid) ifu_ovr_hold_q <= 1'b1;
    else ifu_ovr_hold_q <= 1'b0;
end

wire        s0_issue = !s0_resp_valid &&
                       (!s0_busy || (s0_hit && s1_ready)) &&
                       ftq_rd_valid && init_done && !redirect &&
                       !ovr_valid && !ifu_ovr_valid && !ifu_ovr_hold_q;

assign ic_rd_addr     = s0_issue ? ftq_rd_line_pc :
                        (s0_busy ? s0_req_addr : 32'd0);
assign ic_req_active  = s0_busy;

// ---------------------------------------------------------------------------
// S1: 寄存本块; 计算 pc_ofs / 有效 taken / end_slot
// ---------------------------------------------------------------------------
reg         s1_valid;
reg [ 31:0] s1_start_pc;
reg         s1_taken;
reg [  1:0] s1_taken_slot;
reg [ 31:0] s1_target;
reg [  3:0] s1_btb_cond;
reg [ 15:0] s1_phr;
reg [  5:0] s1_meta_id;
reg [127:0] s1_data;
reg [  3:0] s1_idx;
reg         s1_corr_done;

// S0 预译码结果 (与 s1_data 同拍打进来)
reg [127:0] s1_pd_link;
reg [127:0] s1_pd_jal_tgt;
reg [  3:0] s1_pd_is_cfi;
reg [  3:0] s1_pd_is_jal;
reg [  3:0] s1_pd_is_ret;
reg [  7:0] s1_pd_action;

wire [1:0] s1_pc_ofs    = s1_start_pc[3:2];
wire       s1_eff_taken = s1_taken && (s1_taken_slot >= s1_pc_ofs);
wire [1:0] s1_end_slot  = s1_eff_taken ? s1_taken_slot : 2'd3;
wire [31:0] s1_line_pc  = {s1_start_pc[31:4], 4'b0};

// ---------------------------------------------------------------------------
// S0 -> S1 预译码
// 数据源必须与 s1_data 的选择一致: skid 优先, 否则用本拍 ICache 旁路。
// 这一步和 s1_data 的寄存同拍完成, 但结果单独打拍; S1 的控制锥 (PredChecker/
// RAS) 只看到已译码字段, 不再从 128-bit s1_data 起头。
// ---------------------------------------------------------------------------
wire [127:0] s1_data_next     = s0_resp_valid ? s0_resp_data : ic_q_data;
wire [ 31:0] s1_start_pc_next = s0_resp_valid ? s0_resp_start_pc : s0_req_start_pc;

wire [127:0] pd_lane_link;
wire [127:0] pd_lane_jal_tgt;
wire [  3:0] pd_lane_is_cfi;
wire [  3:0] pd_lane_is_jal;
wire [  3:0] pd_lane_is_ret;
wire [  7:0] pd_lane_action;

rv32ifu3_predecode u_predecode (
    .line         (s1_data_next),
    .start_pc     (s1_start_pc_next),
    .lane_link    (pd_lane_link),
    .lane_jal_tgt (pd_lane_jal_tgt),
    .lane_is_cfi  (pd_lane_is_cfi),
    .lane_is_jal  (pd_lane_is_jal),
    .lane_is_ret  (pd_lane_is_ret),
    .lane_action  (pd_lane_action)
);

// ---------------------------------------------------------------------------
// S2: 组包/推 IBUF
// ---------------------------------------------------------------------------
reg         s2_valid;
reg [ 31:0] s2_start_pc;
reg         s2_taken;
reg [  1:0] s2_taken_slot;
reg [ 31:0] s2_target;
reg [  3:0] s2_btb_cond;
reg [ 15:0] s2_phr;
reg [  5:0] s2_meta_id;
reg [127:0] s2_data;
reg [  1:0] s2_end_slot;
reg [  2:0] s2_cur_slot;
reg [  3:0] s2_idx;
reg [ 23:0] s2_ras_ckpt;      // 6b/lane, {快照 id, lane}
reg [  7:0] s2_ras_eff;       // 2b/lane, 实际生效的 RAS 动作
reg [  5:0] s2_start_ras_ckpt; // 本块快照 id (BPU override 恢复用)

// ---------------------------------------------------------------------------
// PredChecker / RAS 连线
// ---------------------------------------------------------------------------
wire         pc_corr_valid;
wire         pc_corr_taken;
wire [  1:0] pc_corr_slot;
wire [ 31:0] pc_corr_target;
wire [  1:0] pc_corr_end_slot;

wire [  3:0] ras_top_vld;
wire [127:0] ras_top;
wire [ 23:0] ras_ckpt;
wire [  7:0] ras_eff;
wire         ras_busy;
wire         ras_full;

wire         ras_rec_valid;
wire [  5:0] ras_rec_ckpt;
wire [  2:0] ras_rec_action;
wire [ 31:0] ras_rec_link;
wire         ras_clr_valid;

wire         s2_ready;
wire         s1_fire;

// EX 重定向的 chk 可能在上电/异常期为 X; 此时按 RTU 口径丢掉 RAS。
wire         iu_red_x     = (^iu_btb_chk === 1'bx) || (^iu_btb_pc === 1'bx);
wire         ras_rec_iu   = redirect && !redirect_rtu && !iu_red_x;
wire         ras_clr     = redirect && (redirect_rtu || iu_red_x);
wire         ras_rec_bpu;   // 在 override 年龄比较之后赋值

assign ras_clr_valid = ras_clr;
assign ras_rec_valid = (ras_rec_iu || ras_rec_bpu) && !ras_clr;
assign ras_rec_ckpt  = ras_rec_iu ? iu_btb_chk[24:19] : s2_start_ras_ckpt;
assign ras_rec_action= ras_rec_iu ? (iu_btb_taken ? iu_btb_chk[18:16] : 3'd0) : 3'd0;
assign ras_rec_link  = iu_btb_pc + 32'd4;

// IFU 自己的 override 脉冲: PredChecker 有修正且 RAS 可用、当前块还没修过。
wire ifu_need_corr = s1_valid && !s1_corr_done && pc_corr_valid &&
                     !redirect && !ras_busy && !ras_full;
assign ifu_ovr_valid      = ifu_need_corr;
assign ifu_ovr_idx        = s1_idx;
assign ifu_ovr_taken      = pc_corr_taken;
assign ifu_ovr_taken_slot = pc_corr_slot;
assign ifu_ovr_target     = pc_corr_target;
assign ifu_ovr_btb_cond   = s1_btb_cond;
assign ifu_ovr_phr        = s1_phr;

rv32ifu3_predcheck u_predcheck (
    .lane_is_cfi   (s1_pd_is_cfi),
    .lane_is_jal   (s1_pd_is_jal),
    .lane_is_ret   (s1_pd_is_ret),
    .lane_jal_tgt  (s1_pd_jal_tgt),
    .line_pc       (s1_line_pc),
    .pc_ofs        (s1_pc_ofs),
    .pred_taken    (s1_eff_taken),
    .pred_slot     (s1_taken_slot),
    .pred_target   (s1_target),
    .ras_top_vld   (ras_top_vld),
    .ras_top       (ras_top),
    .corr_valid    (pc_corr_valid),
    .corr_taken    (pc_corr_taken),
    .corr_slot     (pc_corr_slot),
    .corr_target   (pc_corr_target),
    .corr_end_slot (pc_corr_end_slot)
);

rv32ifu3_ras #(
    .DEPTH (16)
) u_ras (
    .clk         (clk),
    .rst         (rst),
    .s1_valid    (s1_valid),
    .s1_pc_ofs   (s1_pc_ofs),
    .s1_end_slot (s1_end_slot),
    .s1_fire     (s1_fire),
    .s1_idx      (s1_idx),
    .s1_start_pc (s1_start_pc),
    .dec_action  (s1_pd_action),
    .dec_link    (s1_pd_link),
    .top_vld     (ras_top_vld),
    .top         (ras_top),
    .ckpt        (ras_ckpt),
    .eff_action  (ras_eff),
    .busy        (ras_busy),
    .full        (ras_full),
    .rec_valid   (ras_rec_valid),
    .rec_ckpt    (ras_rec_ckpt),
    .rec_replay  (ras_rec_iu),
    .rec_action  (ras_rec_action),
    .rec_link    (ras_rec_link),
    .clr_valid   (ras_clr_valid)
);

reg [  2:0] inflight_q;

wire [2:0] s2_remain = {1'b0, s2_end_slot} - s2_cur_slot + 3'd1;
wire [3:0] s2_space  = 4'd8 - ib_count;

wire [2:0] s2_push_n =
    (s2_space >= 4'd4) ? s2_remain :
    (s2_space == 4'd0) ? 3'd0 :
    (s2_remain < s2_space[2:0]) ? s2_remain : s2_space[2:0];

wire s2_finish = s2_valid && (s2_push_n == s2_remain);

wire [3:0] s2_push_mask = (4'd1 << s2_push_n) - 4'd1;

// override 当拍 IFU 整体停一拍: FTQ 的 override 分支会忽略同拍 finish/alloc,
// 如果这里让 S2 继续 finish/pop, IFU 的 inflight 会和 FTQ 的 head/count 失步。
// (要省这一拍, 必须让 FTQ override 同时处理 finish 并调整 count, 见 Phase 3。)
assign ovr_dist     = ovr_idx - ftq_head_idx;

assign ib_push_mask = (s2_valid && !ovr_valid && !ifu_ovr_valid &&
                       !ifu_ovr_hold_q) ? s2_push_mask : 4'h0;
assign ftq_finish   = s2_finish && !redirect && !ovr_valid && !ifu_ovr_valid &&
                      !ifu_ovr_hold_q;
assign ftq_inflight = inflight_q;

// 四个 push lane 的打包
wire [2:0] s2_slot0 = s2_cur_slot + 3'd0;
wire [2:0] s2_slot1 = s2_cur_slot + 3'd1;
wire [2:0] s2_slot2 = s2_cur_slot + 3'd2;
wire [2:0] s2_slot3 = s2_cur_slot + 3'd3;

wire [31:0] s2_word0 = pick_word(s2_data, s2_slot0[1:0]);
wire [31:0] s2_word1 = pick_word(s2_data, s2_slot1[1:0]);
wire [31:0] s2_word2 = pick_word(s2_data, s2_slot2[1:0]);
wire [31:0] s2_word3 = pick_word(s2_data, s2_slot3[1:0]);

// start_pc 是 FTQ 给的"本块第一条指令 PC", 可以不是 16 B 对齐;
// 行内 slot 是绝对位置 (0..3), 所以 PC 必须从 **行基址** 加 slot*4,
// 不能从 start_pc 加 slot*4 (那会在 pc_ofs!=0 时多算 pc_ofs*4)。
wire [31:0] s2_line_pc = {s2_start_pc[31:4], 4'b0};
wire [31:0] s2_pc0 = s2_line_pc + {s2_slot0, 2'b00};
wire [31:0] s2_pc1 = s2_line_pc + {s2_slot1, 2'b00};
wire [31:0] s2_pc2 = s2_line_pc + {s2_slot2, 2'b00};
wire [31:0] s2_pc3 = s2_line_pc + {s2_slot3, 2'b00};

wire s2_tk0 = s2_taken && (s2_slot0 == {1'b0, s2_taken_slot});
wire s2_tk1 = s2_taken && (s2_slot1 == {1'b0, s2_taken_slot});
wire s2_tk2 = s2_taken && (s2_slot2 == {1'b0, s2_taken_slot});
wire s2_tk3 = s2_taken && (s2_slot3 == {1'b0, s2_taken_slot});

wire [31:0] s2_npc0 = s2_tk0 ? s2_target : (s2_pc0 + 32'd4);
wire [31:0] s2_npc1 = s2_tk1 ? s2_target : (s2_pc1 + 32'd4);
wire [31:0] s2_npc2 = s2_tk2 ? s2_target : (s2_pc2 + 32'd4);
wire [31:0] s2_npc3 = s2_tk3 ? s2_target : (s2_pc3 + 32'd4);

wire [127:0] s2_pkt0 = make_packet(s2_pc0, s2_word0, s2_npc0, s2_tk0);
wire [127:0] s2_pkt1 = make_packet(s2_pc1, s2_word1, s2_npc1, s2_tk1);
wire [127:0] s2_pkt2 = make_packet(s2_pc2, s2_word2, s2_npc2, s2_tk2);
wire [127:0] s2_pkt3 = make_packet(s2_pc3, s2_word3, s2_npc3, s2_tk3);

// chk = {ras_ckpt[5:0], ras_eff[2:0], phr[15:0]} (每 lane 独立)
//   [24:19] 该指令动作前的 RAS undo-log 指针
//   [18:16] 实际生效的 RAS 动作 (0 none / 1 push / 2 pop / 3 pop_push)
//   [15:0]  块首 PHR 快照 (TAGE 训练 + PHR 精确恢复)
// 总宽 25: 6(ckpt) + 1(保留, action[2]) + 2(eff) + 16(phr)
// action 字段仍是 3 bit [18:16], 当前编码只用 0..3, 所以 bit18=0。
//
// ⚠️ push lane 是相对 `s2_cur_slot` 的; chk 必须按**绝对 slot** 取 RAS 快照。
// 非对齐 start_pc / 部分 push 时, data0 可能对应 slot1/2/3, 不能固定用 slot0。
wire [1:0] ss0 = s2_slot0[1:0];
wire [1:0] ss1 = s2_slot1[1:0];
wire [1:0] ss2 = s2_slot2[1:0];
wire [1:0] ss3 = s2_slot3[1:0];

wire [5:0] ck_r0 = (ss0 == 2'd0) ? s2_ras_ckpt[ 5: 0] :
                   (ss0 == 2'd1) ? s2_ras_ckpt[11: 6] :
                   (ss0 == 2'd2) ? s2_ras_ckpt[17:12] :
                                   s2_ras_ckpt[23:18];
wire [5:0] ck_r1 = (ss1 == 2'd0) ? s2_ras_ckpt[ 5: 0] :
                   (ss1 == 2'd1) ? s2_ras_ckpt[11: 6] :
                   (ss1 == 2'd2) ? s2_ras_ckpt[17:12] :
                                   s2_ras_ckpt[23:18];
wire [5:0] ck_r2 = (ss2 == 2'd0) ? s2_ras_ckpt[ 5: 0] :
                   (ss2 == 2'd1) ? s2_ras_ckpt[11: 6] :
                   (ss2 == 2'd2) ? s2_ras_ckpt[17:12] :
                                   s2_ras_ckpt[23:18];
wire [5:0] ck_r3 = (ss3 == 2'd0) ? s2_ras_ckpt[ 5: 0] :
                   (ss3 == 2'd1) ? s2_ras_ckpt[11: 6] :
                   (ss3 == 2'd2) ? s2_ras_ckpt[17:12] :
                                   s2_ras_ckpt[23:18];

wire [1:0] ef_r0 = (ss0 == 2'd0) ? s2_ras_eff[1:0] :
                   (ss0 == 2'd1) ? s2_ras_eff[3:2] :
                   (ss0 == 2'd2) ? s2_ras_eff[5:4] :
                                   s2_ras_eff[7:6];
wire [1:0] ef_r1 = (ss1 == 2'd0) ? s2_ras_eff[1:0] :
                   (ss1 == 2'd1) ? s2_ras_eff[3:2] :
                   (ss1 == 2'd2) ? s2_ras_eff[5:4] :
                                   s2_ras_eff[7:6];
wire [1:0] ef_r2 = (ss2 == 2'd0) ? s2_ras_eff[1:0] :
                   (ss2 == 2'd1) ? s2_ras_eff[3:2] :
                   (ss2 == 2'd2) ? s2_ras_eff[5:4] :
                                   s2_ras_eff[7:6];
wire [1:0] ef_r3 = (ss3 == 2'd0) ? s2_ras_eff[1:0] :
                   (ss3 == 2'd1) ? s2_ras_eff[3:2] :
                   (ss3 == 2'd2) ? s2_ras_eff[5:4] :
                                   s2_ras_eff[7:6];

wire [24:0] s2_chk0 = {ck_r0, 1'b0, ef_r0, s2_phr};
wire [24:0] s2_chk1 = {ck_r1, 1'b0, ef_r1, s2_phr};
wire [24:0] s2_chk2 = {ck_r2, 1'b0, ef_r2, s2_phr};
wire [24:0] s2_chk3 = {ck_r3, 1'b0, ef_r3, s2_phr};
assign ib_push_data0 = {s2_chk0, s2_pkt0};
assign ib_push_data1 = {s2_chk1, s2_pkt1};
assign ib_push_data2 = {s2_chk2, s2_pkt2};
assign ib_push_data3 = {s2_chk3, s2_pkt3};

// ---------------------------------------------------------------------------
// inflight / 各级 handoff
// ---------------------------------------------------------------------------
assign s2_ready = !s2_valid || s2_finish;
assign s1_fire  = s1_valid && s2_ready && !redirect && !ifu_ovr_valid &&
                  !ifu_ovr_hold_q && !ovr_valid && !ras_busy && !ras_full;
assign s1_ready      = !s1_valid || s1_fire;
assign s1_load_skid  = s0_resp_valid && s1_ready;
assign s1_load_direct= s0_hit && s1_ready && !s0_resp_valid;
wire   s1_load       = s1_load_skid || s1_load_direct;

// override 的年龄比较一律用"相对 head 的距离", 避免环形索引回绕
wire [3:0] s2_dist    = s2_idx - ftq_head_idx;
wire [3:0] s1_dist    = s1_idx - ftq_head_idx;
wire [3:0] s0_req_dist = s0_req_idx - ftq_head_idx;
wire [3:0] s0_resp_dist= s0_resp_idx - ftq_head_idx;

// BPU override 命中已取块 (S2) 时, 该块在 S1 fire 时应用过的 RAS 动作要回滚。
assign ras_rec_bpu = ovr_valid && !redirect && !ifu_ovr_valid &&
                     s2_valid && (s2_dist >= ovr_dist);

always @(posedge clk) begin
    if (rst) begin
        s0_busy        <= 1'b0;
        s0_resp_valid  <= 1'b0;
        s1_valid       <= 1'b0;
        s2_valid       <= 1'b0;
        s2_cur_slot    <= 2'd0;
        inflight_q     <= 3'd0;
        s1_corr_done   <= 1'b0;
        s2_ras_ckpt    <= 24'd0;
        s2_ras_eff     <= 8'd0;
        s2_start_ras_ckpt <= 6'd0;
    end else if (redirect) begin
        s0_busy        <= 1'b0;
        s0_resp_valid  <= 1'b0;
        s1_valid       <= 1'b0;
        s2_valid       <= 1'b0;
        s2_cur_slot    <= 2'd0;
        inflight_q     <= 3'd0;
        s1_corr_done   <= 1'b0;
        s2_ras_ckpt    <= 24'd0;
        s2_ras_eff     <= 8'd0;
        s2_start_ras_ckpt <= 6'd0;
    end else if (ifu_ovr_valid) begin
        // PredChecker 修正当前 S1 块: 保留 S1/S2, 只丢弃年轻 S0, 闸一拍。
        // FTQ 重写同一项、BPU 从修正 target 重启由 top 完成 (下一拍)。
        s0_busy        <= 1'b0;
        s0_resp_valid  <= 1'b0;
        inflight_q     <= (s1_dist >= 4'd7) ? 3'd7 : (s1_dist[2:0] + 3'd1);
        s1_taken       <= pc_corr_taken;
        s1_taken_slot  <= pc_corr_slot;
        s1_target      <= pc_corr_target;
        s1_corr_done   <= 1'b1;
    end else if (ifu_ovr_hold_q) begin
        // top 的 registered IFU override 在本拍进 FTQ/BPU。FTQ 的 override
        // 分支会忽略同拍 finish/alloc, 所以这里也必须把 S0/S1/S2 整条停住:
        // 不 fire、不 push、不 finish、不推进 cur_slot、不改 inflight。
        // (否则 S2 finish 被 FTQ 忽略, 而 IFU 的 inflight 照减, 指针立刻错位,
        //  表现为同一个 FTQ entry 被取两次。)
        s0_busy       <= 1'b0;
        s0_resp_valid <= 1'b0;
    end else if (ovr_valid) begin
        // S2 override: 本拍 IFU 不推进 (推入/finish 已在外面门控);
        // 若 override 项已经被 IFU 取走, 丢弃它和它的年轻项; 更老的项保留。
        if ({1'b0, inflight_q} > {1'b0, ovr_dist}) begin
            if (s2_valid && (s2_dist >= ovr_dist))       s2_valid      <= 1'b0;
            if (s1_valid && (s1_dist >= ovr_dist)) begin
                s1_valid      <= 1'b0;
                s1_corr_done  <= 1'b0;
            end
            if (s0_busy && (s0_req_dist >= ovr_dist))    s0_busy       <= 1'b0;
            if (s0_resp_valid && (s0_resp_dist >= ovr_dist)) s0_resp_valid <= 1'b0;
            inflight_q <= ovr_dist[2:0];
        end
    end else begin
        // ---------------- S0 ----------------
        // 响应到达: 能直接进 S1 就旁路 (不写 skid), 否则存 skid。
        if (s0_hit) begin
            if (!s1_load_direct) begin
                s0_resp_valid    <= 1'b1;
                s0_resp_start_pc <= s0_req_start_pc;
                s0_resp_taken    <= s0_req_taken;
                s0_resp_taken_slot <= s0_req_taken_slot;
                s0_resp_target   <= s0_req_target;
                s0_resp_btb_cond <= s0_req_btb_cond;
                s0_resp_phr      <= s0_req_phr;
                s0_resp_meta_id  <= s0_req_meta_id;
                s0_resp_data     <= ic_q_data;
                s0_resp_idx      <= s0_req_idx;
            end
            s0_busy <= 1'b0;
        end
        // 同拍发下一块 (响应被旁路且 S1 接得走时)。后写的 nonblocking 覆盖
        // 上面 hit 分支的 s0_busy<=0。
        if (s0_issue) begin
            s0_busy          <= 1'b1;
            s0_req_start_pc  <= ftq_rd_start_pc;
            s0_req_taken     <= ftq_rd_taken;
            s0_req_taken_slot<= ftq_rd_taken_slot;
            s0_req_target    <= ftq_rd_target;
            s0_req_btb_cond  <= ftq_rd_btb_cond;
            s0_req_phr       <= ftq_rd_phr;
            s0_req_meta_id   <= ftq_rd_meta_id;
            s0_req_addr      <= ftq_rd_line_pc;
            s0_req_idx       <= ftq_rd_ptr;
        end
        if (s1_load_skid) begin
            s0_resp_valid    <= 1'b0;
        end

        // ---------------- S1 ----------------
        if (s1_fire) begin
            s1_valid         <= 1'b0;
            s1_corr_done     <= 1'b0;
        end
        if (s1_load) begin
            s1_valid         <= 1'b1;
            // skid 优先; 否则用本拍 ICache 响应旁路
            s1_start_pc      <= s0_resp_valid ? s0_resp_start_pc : s0_req_start_pc;
            s1_taken         <= s0_resp_valid ? s0_resp_taken    : s0_req_taken;
            s1_taken_slot    <= s0_resp_valid ? s0_resp_taken_slot : s0_req_taken_slot;
            s1_target        <= s0_resp_valid ? s0_resp_target   : s0_req_target;
            s1_btb_cond      <= s0_resp_valid ? s0_resp_btb_cond : s0_req_btb_cond;
            s1_phr           <= s0_resp_valid ? s0_resp_phr      : s0_req_phr;
            s1_meta_id       <= s0_resp_valid ? s0_resp_meta_id  : s0_req_meta_id;
            s1_data          <= s0_resp_valid ? s0_resp_data     : ic_q_data;
            s1_idx           <= s0_resp_valid ? s0_resp_idx      : s0_req_idx;
            s1_pd_link       <= pd_lane_link;
            s1_pd_jal_tgt    <= pd_lane_jal_tgt;
            s1_pd_is_cfi     <= pd_lane_is_cfi;
            s1_pd_is_jal     <= pd_lane_is_jal;
            s1_pd_is_ret     <= pd_lane_is_ret;
            s1_pd_action     <= pd_lane_action;
            s1_corr_done     <= 1'b0;
        end

        // ---------------- S2 ----------------
        if (s2_valid) begin
            if (s2_push_n != 3'd0) begin
                s2_cur_slot <= s2_cur_slot + s2_push_n;
            end
        end
        if (s1_fire) begin
            s2_valid         <= 1'b1;
            s2_start_pc      <= s1_start_pc;
            s2_taken         <= s1_eff_taken;
            s2_taken_slot    <= s1_taken_slot;
            s2_target        <= s1_target;
            s2_btb_cond      <= s1_btb_cond;
            s2_phr           <= s1_phr;
            s2_meta_id       <= s1_meta_id;
            s2_data          <= s1_data;
            s2_end_slot      <= s1_end_slot;
            s2_cur_slot      <= {1'b0, s1_pc_ofs};
            s2_idx           <= s1_idx;
            // RAS 的组合输出是“动作之前”的值, 与本拍应用动作同拍捕获
            s2_ras_ckpt      <= ras_ckpt;
            s2_ras_eff       <= ras_eff;
            s2_start_ras_ckpt<= ras_ckpt[5:0];
        end else if (s2_finish) begin
            s2_valid         <= 1'b0;
        end

        // ---------------- inflight ----------------
        case ({s0_issue, s2_finish})
            2'b10:   inflight_q <= inflight_q + 3'd1;
            2'b01:   inflight_q <= inflight_q - 3'd1;
            default: inflight_q <= inflight_q;
        endcase
    end
end

// synopsys translate_off
always @(posedge clk) begin
    if (!rst && !redirect) begin
        if (s2_valid && (s2_end_slot < s2_cur_slot)) begin
            $display("[IFU3-IFU] ERROR: end_slot=%0d < cur_slot=%0d", s2_end_slot, s2_cur_slot);
            $fatal;
        end
        if (s2_valid && (s2_push_n > s2_remain)) begin
            $display("[IFU3-IFU] ERROR: push_n=%0d > remain=%0d", s2_push_n, s2_remain);
            $fatal;
        end
        if (!ovr_valid && !ifu_ovr_valid && !ifu_ovr_hold_q && s2_valid &&
            (s2_push_n > ib_push_accept) && (s2_push_n != 0)) begin
            $display("[IFU3-IFU] ERROR: push_n=%0d > ib_push_accept=%0d", s2_push_n, ib_push_accept);
            $fatal;
        end
        if (s0_busy && (ic_q_pc != s0_req_addr)) begin
            // q_pc 应等于上一拍 rd_addr; 若不等说明有人改了 rd_addr 或时序错位
            $display("[IFU3-IFU] ERROR: q_pc=%h != req_addr=%h", ic_q_pc, s0_req_addr);
            $fatal;
        end
    end
end

// 调试: +IFU3_DBG 时打印前 300 次 push 的 PC/chk 动作/ckpt
integer dbg_push_n;
initial dbg_push_n = 0;
always @(posedge clk) begin
    if ($test$plusargs("IFU3_DBG") && !rst && (dbg_push_n < 300)) begin
        if (s1_fire)
            $display("[IFU3-FIRE] t=%0t pc=%h ofs=%0d end=%0d act=%b eff=%b ckpt=%b",
                     $time, s1_start_pc, s1_pc_ofs, s1_end_slot,
                     s1_pd_action, ras_eff, ras_ckpt);
        if (ib_push_mask[0])
            $display("[IFU3-CHK] t=%0t blk=%h cur=%0d slot=%0d pc=%h act=%0d ckpt=%0d effreg=%b ckreg=%b",
                     $time, s2_start_pc, s2_cur_slot, s2_slot0, s2_pc0,
                     s2_chk0[18:16], s2_chk0[24:19], s2_ras_eff, s2_ras_ckpt);
        if (ib_push_mask[1])
            $display("[IFU3-CHK] t=%0t blk=%h cur=%0d slot=%0d pc=%h act=%0d ckpt=%0d",
                     $time, s2_start_pc, s2_cur_slot, s2_slot1, s2_pc1,
                     s2_chk1[18:16], s2_chk1[24:19]);
        if (ib_push_mask[2])
            $display("[IFU3-CHK] t=%0t blk=%h cur=%0d slot=%0d pc=%h act=%0d ckpt=%0d",
                     $time, s2_start_pc, s2_cur_slot, s2_slot2, s2_pc2,
                     s2_chk2[18:16], s2_chk2[24:19]);
        if (ib_push_mask[3])
            $display("[IFU3-CHK] t=%0t blk=%h cur=%0d slot=%0d pc=%h act=%0d ckpt=%0d",
                     $time, s2_start_pc, s2_cur_slot, s2_slot3, s2_pc3,
                     s2_chk3[18:16], s2_chk3[24:19]);
        if (|ib_push_mask)
            dbg_push_n <= dbg_push_n + 1;
    end
end
// synopsys translate_on

endmodule
