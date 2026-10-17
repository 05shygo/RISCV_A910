`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_bpu — 香山式: BP1 早预测 (uBTB / BTB+base) + BP2 TAGE override
//
//   BP0: 用 btb_rd_pc 读 BTB; 用 (line_pc, phr_q) 读 TAGE
//   BP1: uBTB 命中 => always-taken early target; 否则 BTB+base first-taken;
//        写 FTQ (早预测); next_pc 组合反馈到 BP0 读地址 (1 块/拍)
//   BP2: 用 latched BTB slots + TAGE dir 重算 first-taken;
//        与早预测不同 => S2 override: 重写同一 FTQ 项、丢弃年轻项,
//        BPU 从修正后的 next_pc/PHR 重启 (BP0/BP1 的年轻预测作废)
//
// 注意: 3 级 BPU 的最终 TAGE 不能串进 next-PC, 否则每块 3 拍; 所以 next-PC
// 只由 BP1 早预测驱动, TAGE 只走 BP2 override 这条旁路 —— 与香山 S1/S2 一致。
// ===========================================================================
module rv32ifu3_bpu #(
    parameter BP_EN  = 1,
    parameter BTB_AW = 6,
    parameter [4:0] TAGE_L0 = 5'd5,
    parameter [4:0] TAGE_L1 = 5'd10,
    parameter [4:0] TAGE_L2 = 5'd15,
    parameter [4:0] TAGE_L3 = 5'd16
)(
    input  wire         clk,
    input  wire         rst,             // 高有效

    input  wire         redirect,
    input  wire         redirect_rtu,
    input  wire [ 31:0] redirect_pc,
    input  wire [ 24:0] iu_btb_chk,
    input  wire [ 31:0] iu_btb_pc,
    input  wire         iu_btb_taken,
    input  wire         iu_btb_is_cond,

    // ---- IFU PredChecker override: 从修正 target/PHR 重启 ----
    input  wire         ifu_ovr_valid,
    input  wire [ 31:0] ifu_ovr_target,
    input  wire [ 15:0] ifu_ovr_phr,

    // ---- 退休点训练 ----
    input  wire         upd_vld,
    input  wire [ 31:0] upd_pc,
    input  wire [ 31:0] upd_target,
    input  wire         upd_taken,
    input  wire         upd_is_cond,
    input  wire         upd_is_jal,
    input  wire         upd_is_jalr,
    input  wire [ 24:0] upd_chk,

    // ---- FTQ 分配 ----
    output wire         alloc_valid,
    input  wire         alloc_ready,
    output wire [ 31:0] alloc_start_pc,
    output wire         alloc_taken,
    output wire [  1:0] alloc_taken_slot,
    output wire [ 31:0] alloc_target,
    output wire [  3:0] alloc_btb_cond,
    output wire [ 15:0] alloc_phr,
    output wire [  5:0] alloc_meta_id,
    output wire [ 63:0] alloc_meta_data,

    // ---- FTQ 索引 / S2 override ----
    input  wire [  3:0] ftq_alloc_idx,
    output wire         ovr_valid,
    output wire [  3:0] ovr_idx,
    output wire         ovr_taken,
    output wire [  1:0] ovr_taken_slot,
    output wire [ 31:0] ovr_target,
    output wire [  3:0] ovr_btb_cond,
    output wire [ 15:0] ovr_phr
);

// ---------------------------------------------------------------------------
// 预测环寄存器 (必须先声明: 下面的 BTB/TAGE/uBTB 例化会用到)
// ---------------------------------------------------------------------------
reg [31:0] bp_rd_pc_q;
reg [15:0] bp_rd_phr_q;
reg        bp_q_valid;
reg [31:0] bp_hold_pc;
reg [15:0] phr_q;

wire [1:0]  pc_ofs  = bp_rd_pc_q[3:2];
wire [31:0] line_pc = {bp_rd_pc_q[31:4], 4'b0};

// ---------------------------------------------------------------------------
// BTB / TAGE / uBTB
// ---------------------------------------------------------------------------
wire [ 3:0]  btb_slot_vld;
wire [ 3:0]  btb_slot_cond;
wire [ 3:0]  btb_slot_jump;
wire [ 7:0]  btb_slot_ctr;
wire [127:0] btb_slot_target;
wire [31:0]  btb_rd_pc;

rv32ifu3_btb #(
    .ROW_AW (BTB_AW),
    .SLOTS  (4)
) u_btb (
    .clk         (clk),
    .rst         (rst),
    .rd_pc       (btb_rd_pc),
    .slot_vld    (btb_slot_vld),
    .slot_cond   (btb_slot_cond),
    .slot_jump   (btb_slot_jump),
    .slot_ctr    (btb_slot_ctr),
    .slot_target (btb_slot_target),
    .upd_vld     (upd_vld),
    .upd_pc      (upd_pc),
    .upd_target  (upd_target),
    .upd_taken   (upd_taken),
    .upd_is_cond (upd_is_cond),
    .upd_is_jal  (upd_is_jal),
    .upd_is_jalr (upd_is_jalr)
);

wire [3:0] tage_dir;
wire [3:0] tage_hit;

rv32ifu3_tage #(
    .L0 (TAGE_L0),
    .L1 (TAGE_L1),
    .L2 (TAGE_L2),
    .L3 (TAGE_L3)
) u_tage (
    .clk         (clk),
    .rst         (rst),
    .rd_line_pc  ({btb_rd_pc[31:4], 4'b0}),
    .rd_phr      (phr_q),
    .tag_line_pc (line_pc),
    .tag_phr     (bp_rd_phr_q),
    .slot_cond   (btb_slot_cond),
    .base_dir    ({btb_slot_ctr[7], btb_slot_ctr[5], btb_slot_ctr[3], btb_slot_ctr[1]}),
    .dir         (tage_dir),
    .hit_any     (tage_hit),
    .upd_vld     (upd_vld),
    .upd_pc      (upd_pc),
    .upd_taken   (upd_taken),
    .upd_is_cond (upd_is_cond),
    .upd_phr     (upd_chk[15:0])
);

wire        ubtb_hit;
wire [1:0]  ubtb_pos;
wire        ubtb_cond;
wire [31:0] ubtb_target;

rv32ifu3_ubtb #(
    .ENTRIES (32),
    .TAG_W   (12),
    .IDX_W   (5)
) u_ubtb (
    .clk         (clk),
    .rst         (rst),
    .rd_pc       (bp_rd_pc_q),
    .hit         (ubtb_hit),
    .pos         (ubtb_pos),
    .is_cond     (ubtb_cond),
    .target      (ubtb_target),
    .upd_vld     (upd_vld),
    .upd_pc      (upd_pc),
    .upd_target  (upd_target),
    .upd_taken   (upd_taken),
    .upd_is_cond (upd_is_cond),
    .upd_is_jal  (upd_is_jal),
    .upd_is_jalr (upd_is_jalr)
);

// ---------------------------------------------------------------------------
// BP1 早预测: BTB+base; uBTB 给 target/position 做兜底
// ---------------------------------------------------------------------------
wire [3:0] base_cand = {
    btb_slot_vld[3] && (btb_slot_jump[3] || (btb_slot_cond[3] && btb_slot_ctr[7])) && (2'd3 >= pc_ofs),
    btb_slot_vld[2] && (btb_slot_jump[2] || (btb_slot_cond[2] && btb_slot_ctr[5])) && (2'd2 >= pc_ofs),
    btb_slot_vld[1] && (btb_slot_jump[1] || (btb_slot_cond[1] && btb_slot_ctr[3])) && (2'd1 >= pc_ofs),
    btb_slot_vld[0] && (btb_slot_jump[0] || (btb_slot_cond[0] && btb_slot_ctr[1])) && (2'd0 >= pc_ofs)
};

wire       base_taken = |base_cand;
wire [1:0] base_slot =
    base_cand[0] ? 2'd0 :
    base_cand[1] ? 2'd1 :
    base_cand[2] ? 2'd2 : 2'd3;
wire [31:0] base_target =
    base_cand[0] ? btb_slot_target[ 31:  0] :
    base_cand[1] ? btb_slot_target[ 63: 32] :
    base_cand[2] ? btb_slot_target[ 95: 64] :
                   btb_slot_target[127: 96];

wire ubtb_use = ubtb_hit && (ubtb_pos >= pc_ofs);
wire ubtb_base_dir =
    (ubtb_pos == 2'd0) ? (btb_slot_cond[0] && btb_slot_ctr[1]) :
    (ubtb_pos == 2'd1) ? (btb_slot_cond[1] && btb_slot_ctr[3]) :
    (ubtb_pos == 2'd2) ? (btb_slot_cond[2] && btb_slot_ctr[5]) :
                         (btb_slot_cond[3] && btb_slot_ctr[7]);
wire ubtb_taken = ubtb_use && (ubtb_cond ? ubtb_base_dir : 1'b1);
wire early_taken = (BP_EN != 0) && (ubtb_taken | base_taken);
wire [1:0] early_slot = ubtb_taken ? ubtb_pos : base_slot;
wire [31:0] fall_pc = line_pc + 32'd16;
// 未 taken 时 target 是 don't-care; 用 fall_pc 填, 避免 X 流进 FTQ/override 比较
wire [31:0] early_target_raw = ubtb_taken ? ubtb_target : base_target;
wire [31:0] early_target = early_taken ? early_target_raw : fall_pc;

wire [31:0] next_pc = early_target;

// 早预测的 PHR (给下一块读 TAGE 用)
// ⚠️ early_slot 是 16 B 行内的绝对 slot, CFI PC 必须从行基址算; 从 start_pc
//    算会在 start_pc[3:2]!=0 时多算 pc_ofs*4。
wire [31:0] early_cfi_pc = line_pc + {early_slot, 2'b00};
wire [1:0]  early_hash = early_cfi_pc[3:2] ^ early_cfi_pc[7:6] ^ early_target[3:2];
// PHR 的推进基底是全局索引寄存器 phr_q (与 ifu2 ghr_next 同口径);
// bp_rd_phr_q 是给查表/tag/FTQ snapshot 用的延迟副本, 不能拿来推进。
wire [15:0] phr_next = early_taken ? {phr_q[13:0], early_hash} : phr_q;

// ---------------------------------------------------------------------------
// BP2 regs: 早预测 + BTB slots + TAGE dir, 下一拍做 override
// ---------------------------------------------------------------------------
reg        bp2_valid;
reg [3:0]  bp2_idx;
reg [31:0] bp2_start_pc;
reg [31:0] bp2_line_pc;
reg [15:0] bp2_phr;
reg        bp2_early_taken;
reg [1:0]  bp2_early_slot;
reg [31:0] bp2_early_target;
reg [3:0]  bp2_btb_vld;
reg [3:0]  bp2_btb_cond;
reg [3:0]  bp2_btb_jump;
reg [127:0] bp2_btb_target;
reg [3:0]  bp2_tage_dir;

// ---------------------------------------------------------------------------
// BP2: 用 BTB slots + TAGE dir 重算
// ---------------------------------------------------------------------------
wire [1:0] bp2_pc_ofs = bp2_start_pc[3:2];
wire [3:0] corr_cand = {
    bp2_btb_vld[3] && (bp2_btb_jump[3] || (bp2_btb_cond[3] && bp2_tage_dir[3])) && (2'd3 >= bp2_pc_ofs),
    bp2_btb_vld[2] && (bp2_btb_jump[2] || (bp2_btb_cond[2] && bp2_tage_dir[2])) && (2'd2 >= bp2_pc_ofs),
    bp2_btb_vld[1] && (bp2_btb_jump[1] || (bp2_btb_cond[1] && bp2_tage_dir[1])) && (2'd1 >= bp2_pc_ofs),
    bp2_btb_vld[0] && (bp2_btb_jump[0] || (bp2_btb_cond[0] && bp2_tage_dir[0])) && (2'd0 >= bp2_pc_ofs)
};
wire       corr_avail = |bp2_btb_vld;
wire       corr_taken = |corr_cand;
wire [1:0] corr_slot =
    corr_cand[0] ? 2'd0 :
    corr_cand[1] ? 2'd1 :
    corr_cand[2] ? 2'd2 : 2'd3;
wire [31:0] corr_target_raw =
    corr_cand[0] ? bp2_btb_target[ 31:  0] :
    corr_cand[1] ? bp2_btb_target[ 63: 32] :
    corr_cand[2] ? bp2_btb_target[ 95: 64] :
                   bp2_btb_target[127: 96];
wire [31:0] corr_target = corr_taken ? corr_target_raw : (bp2_line_pc + 32'd16);

// taken/未 taken 不一致本身就是 override; slot/target 只在两边都 taken 时才有意义
wire corr_diff = corr_avail &&
                 ((corr_taken != bp2_early_taken) ||
                  (corr_taken && bp2_early_taken &&
                   ((corr_slot != bp2_early_slot) ||
                    (corr_target != bp2_early_target))));
assign ovr_valid = bp2_valid && corr_diff && !redirect && (BP_EN != 0);
assign ovr_idx = bp2_idx;
assign ovr_taken = corr_taken;
assign ovr_taken_slot = corr_taken ? corr_slot : 2'd3;
assign ovr_target = corr_target;
// FTQ 的 ent_phr/ent_btb_cond 是**本块**的块首快照, 不是 corr_phr
// (corr_phr 是修完之后下一块的 PHR, 只能喂 BPU 重启)。
assign ovr_btb_cond = bp2_btb_cond;
assign ovr_phr      = bp2_phr;

wire [31:0] corr_cfi_pc = bp2_line_pc + {corr_slot, 2'b00};
wire [1:0]  corr_hash = corr_cfi_pc[3:2] ^ corr_cfi_pc[7:6] ^ corr_target[3:2];
wire [15:0] corr_phr = corr_taken ? {bp2_phr[13:0], corr_hash} : bp2_phr;
wire [31:0] corr_next_pc = corr_target;

// ---------------------------------------------------------------------------
// 分配 / 环控制
// ---------------------------------------------------------------------------
wire stall = bp_q_valid && !alloc_ready && !ovr_valid && !ifu_ovr_valid;
wire alloc_fire = bp_q_valid && !redirect && !ovr_valid && !ifu_ovr_valid && alloc_ready;

assign btb_rd_pc = ifu_ovr_valid ? ifu_ovr_target :
                   ovr_valid ? corr_next_pc :
                   (stall ? bp_rd_pc_q :
                    (bp_q_valid ? next_pc : bp_hold_pc));

assign alloc_valid      = bp_q_valid && !redirect && !ovr_valid && !ifu_ovr_valid;
assign alloc_start_pc   = bp_rd_pc_q;
assign alloc_taken      = early_taken;
assign alloc_taken_slot = early_taken ? early_slot : 2'd3;
assign alloc_target     = next_pc;
assign alloc_btb_cond   = btb_slot_cond;
assign alloc_phr        = bp_rd_phr_q;
assign alloc_meta_id    = 6'd0;
assign alloc_meta_data  = 64'd0;

always @(posedge clk) begin
    if (rst) begin
        bp_rd_pc_q  <= 32'd0;
        bp_rd_phr_q <= 16'd0;
        bp_q_valid  <= 1'b0;
        bp_hold_pc  <= 32'd0;
        phr_q       <= 16'd0;
        bp2_valid   <= 1'b0;
        bp2_idx     <= 4'd0;
        bp2_start_pc <= 32'd0;
        bp2_line_pc  <= 32'd0;
        bp2_phr      <= 16'd0;
        bp2_early_taken  <= 1'b0;
        bp2_early_slot   <= 2'd0;
        bp2_early_target <= 32'd0;
        bp2_btb_vld      <= 4'd0;
        bp2_btb_cond     <= 4'd0;
        bp2_btb_jump     <= 4'd0;
        bp2_btb_target   <= 128'd0;
        bp2_tage_dir     <= 4'd0;
    end else if (redirect) begin
        bp_rd_pc_q  <= 32'd0;
        bp_rd_phr_q <= 16'd0;
        bp_q_valid  <= 1'b0;
        bp_hold_pc  <= redirect_pc;
        bp2_valid   <= 1'b0;
        if (redirect_rtu || (^iu_btb_chk === 1'bx) ||
            (^iu_btb_pc === 1'bx) || (^redirect_pc === 1'bx) ||
            (^iu_btb_taken === 1'bx) || (^iu_btb_is_cond === 1'bx)) begin
            phr_q <= 16'd0;
        end else if (iu_btb_taken && iu_btb_is_cond) begin
            // chk[15:0] 是块首快照; 条件分支实际 taken 时补上真实 hash。
            // 非条件 (JAL/JALR) / not-taken 不推进 PHR, 直接回到块首。
            phr_q <= {iu_btb_chk[13:0],
                      iu_btb_pc[3:2] ^ iu_btb_pc[7:6] ^ redirect_pc[3:2]};
        end else begin
            phr_q <= iu_btb_chk[15:0];
        end
    end else if (ifu_ovr_valid) begin
        // IFU PredChecker override 优先于 BPU 自己的 S2 override:
        // 从真实译码修正后的 target 重启, PHR 用该块的块首快照 (JAL/ret/
        // fall-through 都不推进条件历史)。
        bp_rd_pc_q  <= 32'd0;
        bp_rd_phr_q <= 16'd0;
        bp_q_valid  <= 1'b0;
        bp_hold_pc  <= ifu_ovr_target;
        phr_q       <= ifu_ovr_phr;
        bp2_valid   <= 1'b0;
    end else if (ovr_valid) begin
        // S2 override: 从修正后的 next_pc/PHR 重启, 丢掉 BP0/BP1 的年轻预测
        bp_rd_pc_q  <= 32'd0;
        bp_rd_phr_q <= 16'd0;
        bp_q_valid  <= 1'b0;
        bp_hold_pc  <= corr_next_pc;
        phr_q       <= corr_phr;
        bp2_valid   <= 1'b0;
    end else if (!stall) begin
        bp_rd_pc_q  <= btb_rd_pc;
        bp_rd_phr_q <= phr_q;
        bp_q_valid  <= 1'b1;
        // 重定向/override 后的重启气泡里 bp_rd_pc_q/bp_rd_phr_q 还是 0,
        // 这一拍算出的 phr_next 是垃圾; 不能用它覆盖刚恢复的 phr_q。
        if (bp_q_valid)
            phr_q <= phr_next;

        // BP2 只跟踪"已经写进 FTQ"的早预测
        bp2_valid <= alloc_fire;
        if (alloc_fire) begin
            bp2_idx           <= ftq_alloc_idx;
            bp2_start_pc      <= bp_rd_pc_q;
            bp2_line_pc       <= line_pc;
            bp2_phr           <= bp_rd_phr_q;
            bp2_early_taken   <= early_taken;
            bp2_early_slot    <= early_slot;
            bp2_early_target  <= early_target;
            bp2_btb_vld       <= btb_slot_vld;
            bp2_btb_cond      <= btb_slot_cond;
            bp2_btb_jump      <= btb_slot_jump;
            bp2_btb_target    <= btb_slot_target;
            bp2_tage_dir      <= tage_dir;
        end
    end else begin
        // stall: 保持 PC/valid; BP2 已在上一拍评估完
        bp2_valid <= 1'b0;
    end
end

// synopsys translate_off
reg dbg_x_done;
initial dbg_x_done = 1'b0;
always @(posedge clk) begin
    if (!rst && !dbg_x_done && ((^btb_rd_pc === 1'bx) || (^bp_rd_pc_q === 1'bx))) begin
        dbg_x_done <= 1'b1;
        $display("[BPU-XDBG] t=%0t rdpc=%h btb_rd=%h vld=%b stall=%b ovr=%b next=%h early_tk=%b ubtb=%b/%h btb=%b/%h fall=%h hold=%h corr=%h",
                 $time, bp_rd_pc_q, btb_rd_pc, bp_q_valid, stall, ovr_valid, next_pc,
                 early_taken, ubtb_use, ubtb_target, base_taken, base_target,
                 fall_pc, bp_hold_pc, corr_next_pc);
        $display("[BPU-XDBG] btb vld=%b cond=%b jump=%b ctr=%b tgt=%h",
                 btb_slot_vld, btb_slot_cond, btb_slot_jump, btb_slot_ctr, btb_slot_target);
        $display("[BPU-XDBG] bp2 vld=%b line=%h early=%b/%0d/%h corr=%b/%0d/%h",
                 bp2_valid, bp2_line_pc, bp2_early_taken, bp2_early_slot, bp2_early_target,
                 corr_taken, corr_slot, corr_target);
        $display("[BPU-XDBG] bp2 btbvld=%b cond=%b jump=%b tgt=%h tagedir=%b corravail=%b corrdiff=%b",
                 bp2_btb_vld, bp2_btb_cond, bp2_btb_jump, bp2_btb_target,
                 bp2_tage_dir, corr_avail, corr_diff);
    end
end
// synopsys translate_on

endmodule
