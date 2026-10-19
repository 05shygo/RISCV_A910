`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu4_predcheck — S1 预测检查 (香山式: 只做本地可判定的修正)
//
// 时序口径对齐香山: IFU 的 PredChecker 不碰 RAS 栈顶。香山把 RAS/uRAS 放在
// BPU, IFU 只用预测里的 target/attribute; 这里同样把 ret 的 target 修正交给
// BPU 的 BTB/uBTB 和后端重定向, 不再把 `ras_top` 的 16:1 栈读 mux + 4-lane
// bypass 串进 PredChecker。
//
// 这样 S1 的输入只剩已寄存的 lane_is_cfi/lane_is_jal/lane_jal_tgt 和 FTQ
// 预测 (pred_taken/slot/target), 路径里没有 RAS 状态、没有 128-bit 指令译码。
//
// 保留的规则 (都是“本地确定错”, 不依赖推测栈):
//   1. 预测 taken 的 slot k 之前有真实 JAL f (f<k): JAL 恒 taken,
//      修到 f 的 target; deliver 到 f。
//   2. 预测 taken 的 slot k 是非 CFI: 假 taken; 修成整块 fall-through。
//   3. 预测 taken 的 slot k 就是第一条真实 CFI 且是 JAL: target 不对则修。
//   4. 未预测 taken, 第一条真实 CFI 是 JAL: 修到 JAL 目标。
//   5. 其余 (cond / 非 ret JALR / ret) 方向或目标不可知, 不修。
//
// RV32I 固定 4 B 指令, 16 B 行正好 4 条; 只考虑 slot >= pc_ofs。
// ===========================================================================
module rv32ifu4_predcheck (
    // ---- S0 预译码字段 (已打拍) ----
    input  wire [  3:0] lane_is_cfi,
    input  wire [  3:0] lane_is_jal,
    input  wire [127:0] lane_jal_tgt,   // 4 x 32: lane PC + JAL 立即数
    input  wire [ 31:0] line_pc,        // 16 B 对齐行基址

    // ---- 预测 ----
    input  wire [  1:0] pc_ofs,
    input  wire         pred_taken,
    input  wire [  1:0] pred_slot,
    input  wire [ 31:0] pred_target,

    // ---- 修正结果 ----
    output reg          corr_valid,
    output reg          corr_taken,
    output reg  [  1:0] corr_slot,
    output reg  [ 31:0] corr_target,
    output reg  [  1:0] corr_end_slot
);

// ---------------------------------------------------------------------------
// 第一条真实 CFI (f) / 预测 taken 的 slot (k)
// ---------------------------------------------------------------------------
integer f_i, k_i;
reg     f_vld, f_jal;
reg     k_vld, k_jal;
reg [1:0] f_sel, k_sel;
reg [31:0] f_target, k_target;

always @(*) begin
    // f = 最低的、>= pc_ofs 的真实 CFI (显式低到高优先级)
    f_i = 4;
    if      ((0 >= pc_ofs) && lane_is_cfi[0]) f_i = 0;
    else if ((1 >= pc_ofs) && lane_is_cfi[1]) f_i = 1;
    else if ((2 >= pc_ofs) && lane_is_cfi[2]) f_i = 2;
    else if ((3 >= pc_ofs) && lane_is_cfi[3]) f_i = 3;

    f_vld    = (f_i < 4);
    f_sel    = f_vld ? f_i[1:0] : 2'd0;
    f_jal    = f_vld && lane_is_jal[f_sel];
    f_target = f_jal ? lane_jal_tgt[f_sel*32 +: 32] : 32'd0;

    k_i   = pred_taken ? pred_slot : 4;
    k_vld = pred_taken;
    k_sel = (k_vld && (k_i < 4)) ? k_i[1:0] : 2'd0;
    k_jal = k_vld && (k_i < 4) && lane_is_jal[k_sel];
    k_target = k_jal ? lane_jal_tgt[k_sel*32 +: 32] : pred_target;

    // 默认保持原预测
    corr_valid    = 1'b0;
    corr_taken    = pred_taken;
    corr_slot     = pred_taken ? pred_slot : 2'd3;
    corr_target   = pred_target;
    corr_end_slot = pred_taken ? pred_slot : 2'd3;

    if (pred_taken) begin
        // 1) 更早的 JAL (always-taken)
        if ((f_i < k_i) && f_vld && f_jal) begin
            corr_valid    = 1'b1;
            corr_taken    = 1'b1;
            corr_slot     = f_sel;
            corr_target   = f_target;
            corr_end_slot = f_sel;
        end
        // 2) 预测 taken 落在非 CFI -> 整块 fall-through
        else if (k_vld && (k_i < 4) && !lane_is_cfi[k_sel]) begin
            corr_valid    = 1'b1;
            corr_taken    = 1'b0;
            corr_slot     = 2'd3;
            corr_target   = line_pc + 32'd16;
            corr_end_slot = 2'd3;
        end
        // 3) 预测 taken 就是第一条真实 CFI 的 JAL, target 不对
        else if (k_vld && (f_i == k_i) && k_jal) begin
            // 32 位 != 会被综合成借位链; 显式 XOR 归约
            if (|(pred_target ^ k_target)) begin
                corr_valid    = 1'b1;
                corr_taken    = 1'b1;
                corr_slot     = k_sel;
                corr_target   = k_target;
                corr_end_slot = k_sel;
            end
        end
    end else begin
        // 4) 未预测 taken, 第一条真实 CFI 是 JAL
        if (f_vld && f_jal) begin
            corr_valid    = 1'b1;
            corr_taken    = 1'b1;
            corr_slot     = f_sel;
            corr_target   = f_target;
            corr_end_slot = f_sel;
        end
    end
end

endmodule
