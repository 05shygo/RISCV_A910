`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_predcheck — S1 预测检查 (输入已由 rv32ifu3_predecode 在 S0 译码)
//
// 为什么接口变了: 原版把 4 lane 指令译码 (is_cfi/is_jal/is_ret、JAL 立即数)
// 和检查逻辑放在同一拍, 而 s1_data 是 128-bit 寄存器。Vivado 里
// `s1_data_reg[5] → PredChecker/RAS → FTQ/RAS 写口` 成了 24~25 级、87% 走线
// 的头号违例族。现在译码在 S0 完成并打拍, 本模块只做:
//   * 找第一条真实 CFI f
//   * 预测 taken 的 slot k
//   * 按规则修正 taken/slot/target/end_slot
// 目标一律来自已寄存的 lane_jal_tgt / ras_top / line_pc+16, 不再有指令字段比较
// 和 JAL 立即数加法在关键路径上。
//
// 修正规则 (保守, 只改“确定错”的场景):
//   1. 预测 taken 的 slot k 之前有真实 JAL/ret f (f<k): f 是 always-taken,
//      修到 f 的 target; deliver 到 f。
//   2. 预测 taken 的 slot k 是非 CFI: 假 taken; 修成整块 fall-through
//      (taken=0, end=3, target=line+16)。
//   3. 预测 taken 的 slot k 就是第一条真实 CFI, 且是 JAL/ret: target 与
//      真实 JAL 目标/RAS top 不同则修 target。
//   4. 未预测 taken, 第一条真实 CFI 是 JAL: 修到 JAL 目标。
//   5. 未预测 taken, 第一条真实 CFI 是 ret 且 RAS top 有效: 修到 RAS top。
//   6. 第一条真实 CFI 是 cond / 非 ret JALR: 方向/目标不可知, 不修。
//
// RV32I 固定 4 B 指令, 16 B 行正好 4 条; 只考虑 slot >= pc_ofs。
// ===========================================================================
module rv32ifu3_predcheck (
    // ---- S0 预译码字段 (已打拍) ----
    input  wire [  3:0] lane_is_cfi,
    input  wire [  3:0] lane_is_jal,
    input  wire [  3:0] lane_is_ret,
    input  wire [127:0] lane_jal_tgt,   // 4 x 32: lane PC + JAL 立即数
    input  wire [ 31:0] line_pc,        // 16 B 对齐行基址

    // ---- 预测 ----
    input  wire [  1:0] pc_ofs,
    input  wire         pred_taken,
    input  wire [  1:0] pred_slot,
    input  wire [ 31:0] pred_target,

    // ---- RAS 每条 lane 动作前的栈顶 ----
    input  wire [  3:0] ras_top_vld,
    input  wire [127:0] ras_top,

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
reg     f_vld, f_jal, f_ret, f_ras_vld;
reg     k_vld, k_cfi, k_jal, k_ret, k_ras_vld;
reg [1:0] f_sel, k_sel;
reg [31:0] f_target, k_target;

always @(*) begin
    // f = 最低的、>= pc_ofs 的真实 CFI。
    // 显式从低到高的优先级, 等价于原来"从 3 往 0 扫、每次覆盖"的语义,
    // 但综合出来是一条 4 选 1 的短链, 不是一个 for 循环。
    f_i = 4;
    if      ((0 >= pc_ofs) && lane_is_cfi[0]) f_i = 0;
    else if ((1 >= pc_ofs) && lane_is_cfi[1]) f_i = 1;
    else if ((2 >= pc_ofs) && lane_is_cfi[2]) f_i = 2;
    else if ((3 >= pc_ofs) && lane_is_cfi[3]) f_i = 3;

    f_vld     = (f_i < 4);
    f_sel     = f_vld ? f_i[1:0] : 2'd0;
    f_jal     = f_vld && lane_is_jal[f_sel];
    f_ret     = f_vld && lane_is_ret[f_sel];
    f_ras_vld = f_vld && ras_top_vld[f_sel];
    f_target  = f_jal ? lane_jal_tgt[f_sel*32 +: 32] :
                (f_ret ? ras_top[f_sel*32 +: 32] : 32'd0);

    k_i   = pred_taken ? pred_slot : 4;
    k_vld = pred_taken;
    k_sel = (k_vld && (k_i < 4)) ? k_i[1:0] : 2'd0;
    k_cfi = k_vld && (k_i < 4) && lane_is_cfi[k_sel];
    k_jal = k_vld && (k_i < 4) && lane_is_jal[k_sel];
    k_ret = k_vld && (k_i < 4) && lane_is_ret[k_sel];
    k_ras_vld = k_vld && (k_i < 4) && ras_top_vld[k_sel];
    k_target = k_jal ? lane_jal_tgt[k_sel*32 +: 32] :
               (k_ret ? ras_top[k_sel*32 +: 32] : pred_target);

    // 默认保持原预测
    corr_valid    = 1'b0;
    corr_taken    = pred_taken;
    corr_slot     = pred_taken ? pred_slot : 2'd3;
    corr_target   = pred_target;
    corr_end_slot = pred_taken ? pred_slot : 2'd3;

    if (pred_taken) begin
        // 1) 更早的 always-taken JAL/ret
        if ((f_i < k_i) && f_vld && (f_jal || (f_ret && f_ras_vld))) begin
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
        // 3) 预测 taken 就是第一条真实 CFI 的 JAL/ret, target 不对
        else if (k_vld && (f_i == k_i) && k_jal) begin
            if (pred_target != k_target) begin
                corr_valid    = 1'b1;
                corr_taken    = 1'b1;
                corr_slot     = k_sel;
                corr_target   = k_target;
                corr_end_slot = k_sel;
            end
        end
        else if (k_vld && (f_i == k_i) && k_ret && k_ras_vld) begin
            if (pred_target != k_target) begin
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
        // 5) 未预测 taken, 第一条真实 CFI 是 ret 且 RAS 有效
        else if (f_vld && f_ret && f_ras_vld) begin
            corr_valid    = 1'b1;
            corr_taken    = 1'b1;
            corr_slot     = f_sel;
            corr_target   = f_target;
            corr_end_slot = f_sel;
        end
    end
end

endmodule
