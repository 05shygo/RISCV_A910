`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu4_predecode — S0 的组合预译码 (RV32I, 4 B 固定对齐)
//
// 目的: 把"从 128-bit 指令行里认 is_cfi/is_jal/is_ret、算 JAL target"从 S1
// 移到 S0, 和 ICache 数据一起打拍。这样:
//   * s1_data 不再扇出到 PredChecker/RAS 的控制锥 (Vivado 里
//     s1_data_reg[5] → 446 条路径的根);
//   * S1 的 PredChecker 只做"优先级 + 目标 mux", RAS 的 dec_action/dec_link
//     也来自寄存器, 不再从 128-bit 原始指令起头。
//
// 输出按 lane 打包, 与 rv32ifu4_predcheck 的输入一一对应:
//   lane_link[i*32 +: 32]    = lane PC + 4 (顺序下一 PC; RV32I 无 RVC)
//   lane_jal_tgt[i*32 +: 32] = lane PC + JAL 立即数
//   lane_is_cfi/is_jal/is_ret: 4 lane 位图
//   lane_action[i*2 +: 2]    = 0 none / 1 push / 2 pop / 3 pop_push
//
// 本模块只做译码, 不引用任何流水状态; S0 的输入是 ICache/skid 的寄存器输出,
// 因此这一步在 S0 拍内完成即可。
// ===========================================================================
module rv32ifu4_predecode (
    input  wire [127:0] line,         // 16 B 行, lane i = line[i*32 +: 32]
    input  wire [ 31:0] start_pc,     // FTQ 块起始 PC (可非 16 B 对齐)

    output wire [127:0] lane_link,
    output wire [127:0] lane_jal_tgt,
    output wire [  3:0] lane_is_cfi,
    output wire [  3:0] lane_is_jal,
    output wire [  7:0] lane_action
);

// JAL 立即数: {imm[20], imm[10:1], imm[11], imm[19:12], 0}
function [31:0] jal_imm;
    input [31:0] inst;
    begin
        jal_imm = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
    end
endfunction

wire [31:0] line_pc = {start_pc[31:4], 4'b0};

genvar g;
generate
for (g = 0; g < 4; g = g + 1) begin : g_lane
    wire [31:0] inst = line[g*32 +: 32];
    wire [31:0] pc   = line_pc + (g * 4);

    wire is_branch = (inst[6:0] == 7'b1100011);
    wire is_jal    = (inst[6:0] == 7'b1101111);
    wire is_jalr   = (inst[6:0] == 7'b1100111);

    // x1/x5 作为 link 寄存器
    wire is_call = (is_jal &&
                    ((inst[11:7] == 5'd1) || (inst[11:7] == 5'd5))) ||
                   (is_jalr &&
                    ((inst[11:7] == 5'd1) || (inst[11:7] == 5'd5)) &&
                    (inst[19:15] != inst[11:7]));
    // ret: jalr rs1 in {x1,x5} 且 rd != rs1 (含 pop_push)
    wire is_ret  = is_jalr &&
                   ((inst[19:15] == 5'd1) || (inst[19:15] == 5'd5)) &&
                   (inst[11:7] != inst[19:15]);
    // pop_push: rd/rs1 都在 link 集合且不同
    wire is_pp   = is_jalr &&
                   ((inst[11:7] == 5'd1) || (inst[11:7] == 5'd5)) &&
                   ((inst[19:15] == 5'd1) || (inst[19:15] == 5'd5)) &&
                   (inst[11:7] != inst[19:15]);

    assign lane_is_cfi[g] = is_branch | is_jal | is_jalr;
    assign lane_is_jal[g] = is_jal;

    assign lane_link[g*32 +: 32]    = pc + 32'd4;
    assign lane_jal_tgt[g*32 +: 32] = pc + jal_imm(inst);

    assign lane_action[g*2 +: 2] = is_pp   ? 2'd3 :
                                   is_ret  ? 2'd2 :
                                   is_call ? 2'd1 : 2'd0;
end
endgenerate

endmodule
