`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_predcheck — RV32I 预译码 + S1 PredChecker
//
// 输入一个 16 B 行、行基址、pc_ofs、FTQ 的预测 taken/slot/target、RAS 的
// 每 slot top/top_vld；输出:
//   * dec_action/dec_link: 给 RAS 的 call/ret/pop_push 动作
//   * 修正后的 {taken, slot, target, end_slot}，或 corr_valid=0 保持原预测
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
    input  wire [127:0] line,
    input  wire [ 31:0] line_pc,       // 16 B 对齐的行基址
    input  wire [  1:0] pc_ofs,

    input  wire         pred_taken,    // 已按 pc_ofs 生效后的 taken
    input  wire [  1:0] pred_slot,
    input  wire [ 31:0] pred_target,

    input  wire [  3:0] ras_top_vld,
    input  wire [127:0] ras_top,

    output reg  [  7:0] dec_action,    // 2b/lane
    output reg  [127:0] dec_link,      // 32b/lane = pc+4

    output reg          corr_valid,
    output reg          corr_taken,
    output reg  [  1:0] corr_slot,
    output reg  [ 31:0] corr_target,
    output reg  [  1:0] corr_end_slot
);

// ---------------------------------------------------------------------------
// 逐 lane 译码
// ---------------------------------------------------------------------------
reg [31:0] inst_t [0:3];
reg [31:0] pc_t   [0:3];
reg        is_cfi_t   [0:3];
reg        is_branch_t[0:3];
reg        is_jal_t   [0:3];
reg        is_jalr_t  [0:3];
reg        is_call_t  [0:3];
reg        is_ret_t   [0:3];
reg        is_pp_t    [0:3];
reg [31:0] jal_tgt_t  [0:3];
reg [1:0]  action_t   [0:3];

// JAL 立即数: {imm[20], imm[10:1], imm[11], imm[19:12], 0}
function [31:0] jal_imm;
    input [31:0] inst;
    begin
        jal_imm = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
    end
endfunction

integer i;
always @(*) begin
    for (i = 0; i < 4; i = i + 1) begin
        inst_t[i]  = line[i*32 +: 32];
        pc_t[i]    = line_pc + (i * 4);
        dec_link[i*32 +: 32] = pc_t[i] + 32'd4;

        is_branch_t[i] = (inst_t[i][6:0] == 7'b1100011);
        is_jal_t[i]    = (inst_t[i][6:0] == 7'b1101111);
        is_jalr_t[i]   = (inst_t[i][6:0] == 7'b1100111);
        is_cfi_t[i]    = is_branch_t[i] | is_jal_t[i] | is_jalr_t[i];

        // x1/x5 作为 link 寄存器
        is_call_t[i] = (is_jal_t[i] &&
                        ((inst_t[i][11:7] == 5'd1) || (inst_t[i][11:7] == 5'd5))) ||
                       (is_jalr_t[i] &&
                        ((inst_t[i][11:7] == 5'd1) || (inst_t[i][11:7] == 5'd5)) &&
                        (inst_t[i][19:15] != inst_t[i][11:7]));
        // ret: jalr rs1 in {x1,x5} 且 rd != rs1 (含 pop_push)
        is_ret_t[i]  = is_jalr_t[i] &&
                       ((inst_t[i][19:15] == 5'd1) || (inst_t[i][19:15] == 5'd5)) &&
                       (inst_t[i][11:7] != inst_t[i][19:15]);
        // pop_push: rd/rs1 都在 link 集合且不同
        is_pp_t[i]   = is_jalr_t[i] &&
                       ((inst_t[i][11:7] == 5'd1) || (inst_t[i][11:7] == 5'd5)) &&
                       ((inst_t[i][19:15] == 5'd1) || (inst_t[i][19:15] == 5'd5)) &&
                       (inst_t[i][11:7] != inst_t[i][19:15]);

        jal_tgt_t[i] = pc_t[i] + jal_imm(inst_t[i]);

        if (is_pp_t[i])       action_t[i] = 2'd3;
        else if (is_ret_t[i]) action_t[i] = 2'd2;
        else if (is_call_t[i])action_t[i] = 2'd1;
        else                  action_t[i] = 2'd0;

        dec_action[i*2 +: 2] = action_t[i];
    end
end

// ---------------------------------------------------------------------------
// 第一条真实 CFI (f) / 预测 taken 的 slot (k)
// ---------------------------------------------------------------------------
integer f_i, k_i;
reg     f_vld, f_jal, f_ret, f_ras_vld;
reg     k_vld, k_cfi, k_jal, k_ret, k_ras_vld;
reg [31:0] f_target, k_target;

always @(*) begin
    // f = 最低的、>= pc_ofs 的真实 CFI
    f_i = 4;
    for (i = 3; i >= 0; i = i - 1) begin
        if ((i >= pc_ofs) && is_cfi_t[i])
            f_i = i;
    end
    f_vld     = (f_i < 4);
    f_jal     = f_vld && is_jal_t[f_i];
    f_ret     = f_vld && is_ret_t[f_i];
    f_ras_vld = f_vld && ras_top_vld[f_i];
    f_target  = f_jal ? jal_tgt_t[f_i] :
                (f_ret ? ras_top[f_i*32 +: 32] : 32'd0);

    k_i = pred_taken ? pred_slot : 4;
    k_vld = pred_taken;
    k_cfi = k_vld && (k_i < 4) && is_cfi_t[k_i];
    k_jal = k_vld && (k_i < 4) && is_jal_t[k_i];
    k_ret = k_vld && (k_i < 4) && is_ret_t[k_i];
    k_ras_vld = k_vld && (k_i < 4) && ras_top_vld[k_i];
    k_target = k_jal ? jal_tgt_t[k_i] :
               (k_ret ? ras_top[k_i*32 +: 32] : pred_target);

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
            corr_slot     = f_i[1:0];
            corr_target   = f_target;
            corr_end_slot = f_i[1:0];
        end
        // 2) 预测 taken 落在非 CFI -> 整块 fall-through
        else if (k_vld && (k_i < 4) && !is_cfi_t[k_i]) begin
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
                corr_slot     = k_i[1:0];
                corr_target   = k_target;
                corr_end_slot = k_i[1:0];
            end
        end
        else if (k_vld && (f_i == k_i) && k_ret && k_ras_vld) begin
            if (pred_target != k_target) begin
                corr_valid    = 1'b1;
                corr_taken    = 1'b1;
                corr_slot     = k_i[1:0];
                corr_target   = k_target;
                corr_end_slot = k_i[1:0];
            end
        end
    end else begin
        // 4) 未预测 taken, 第一条真实 CFI 是 JAL
        if (f_vld && f_jal) begin
            corr_valid    = 1'b1;
            corr_taken    = 1'b1;
            corr_slot     = f_i[1:0];
            corr_target   = f_target;
            corr_end_slot = f_i[1:0];
        end
        // 5) 未预测 taken, 第一条真实 CFI 是 ret 且 RAS 有效
        else if (f_vld && f_ret && f_ras_vld) begin
            corr_valid    = 1'b1;
            corr_taken    = 1'b1;
            corr_slot     = f_i[1:0];
            corr_target   = f_target;
            corr_end_slot = f_i[1:0];
        end
    end
end

endmodule
