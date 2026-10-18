`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_ras — 推测返回地址栈 + per-FTQ-entry 快照
//
// 为什么不再用 undo log:
//   旧实现是 64×32 log + 每块最多 8 路动态索引写 (log_idx_t[0..7]) + 4 路
//   push。综合到 FPGA 上, 8 个 64 选 1 的 33-bit 写 mux 占了 ~22k LUT
//   (u_ras 比整个 IDU 还大), 而 RS 里真正有状态的栈只有 16×32。
//
//   新结构: 每个 FTQ entry 保存一份"该块动作之前"的完整推测栈快照
//     {stk[16][32], sp, eff_action[4], start_pc, pc_ofs}
//   = 559 bit × 16 项 ≈ 8.9 kbit, 用 1R1W 分布式 RAM (LUTRAM) 实现:
//     * 公共路径每块只写一个口 (s1_idx), 没有 8 路动态写;
//     * 恢复时读一个快照 (1 拍), 再按 lane 回放最多 4 条动作 (1 条/拍);
//     * 不需要 commit 指针 / live window / full 反压。
//
// chk 的 ckpt 字段 (6 bit) 现在是 {snap_id[3:0], lane[1:0]}, snap_id = FTQ idx。
//   * IU redirect: rec_replay=1 —— 恢复快照, 回放 pc_ofs..lane 的动作;
//   * BPU override: rec_replay=0 —— 只恢复快照, 不回放 (整块丢弃)。
//   * RTU redirect: clr_valid=1 —— 清空推测状态。
//
// 恢复是多拍 FSM; busy 期间 IFU 闸住 S1 fire, top_vld=0。
// 公共路径 (每块 0..4 条 push/pop) 仍在一拍内用并行前缀完成, 与旧版一致。
// ===========================================================================
module rv32ifu3_ras #(
    parameter DEPTH = 16
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- S1 译码/应用 ----
    input  wire         s1_valid,
    input  wire [  1:0] s1_pc_ofs,
    input  wire [  1:0] s1_end_slot,   // 修正后的交付终点 (含)
    input  wire         s1_fire,
    input  wire [  3:0] s1_idx,        // 本块的 FTQ entry index = 快照 id
    input  wire [ 31:0] s1_start_pc,   // 本块起始 PC (可非 16 B 对齐)
    input  wire [  7:0] dec_action,    // 2b/lane: 0=none 1=push 2=pop 3=pop_push
    input  wire [127:0] dec_link,      // 32b/lane: call 的 pc+4

    // ---- 组合读: 每条 lane 动作之前的状态 ----
    output wire [  3:0] top_vld,
    output wire [127:0] top,           // 32b/lane
    output wire [ 23:0] ckpt,          // 6b/lane: {snap_id, lane}
    output wire [  7:0] eff_action,    // 2b/lane: 实际生效的动作
    output wire         busy,
    output wire         full,          // 恒 0 (快照没有 live-window 上限)

    // ---- 恢复 ----
    input  wire         rec_valid,
    input  wire [  5:0] rec_ckpt,      // {snap_id[3:0], lane[1:0]}
    input  wire         rec_replay,    // 1 = IU redirect 回放; 0 = BPU override
    input  wire [  2:0] rec_action,    // 0..3, 回放该分支的实际动作
    input  wire [ 31:0] rec_link,      // 分支的 link (pc+4)
    input  wire         clr_valid      // RTU redirect: 清空
);

localparam SP_W   = 5;                 // DEPTH=16 -> 0..16
localparam SW_STK = 0;
localparam SW_SP  = DEPTH * 32;        // 512
localparam SW_EFF = SW_SP + SP_W;      // 517
localparam SW_PC  = SW_EFF + 8;        // 525
localparam SW_OFS = SW_PC + 32;        // 557
localparam SNAP_W = SW_OFS + 2;        // 559

localparam ST_IDLE    = 2'd0;
localparam ST_RESTORE = 2'd1;
localparam ST_REPLAY  = 2'd2;

// ---------------------------------------------------------------------------
// 推测栈 + 快照 RAM
// ---------------------------------------------------------------------------
reg [31:0] stk_q [0:DEPTH-1];
reg [SP_W-1:0] sp_q;

(* ram_style = "distributed" *)
reg [SNAP_W-1:0] snap_mem [0:DEPTH-1];
reg [DEPTH-1:0]  snap_valid_q;

reg [1:0]  state_q;
reg        busy_q;

reg [1:0]  rec_lane_q;
reg        rec_replay_q;
reg [2:0]  rec_action_q;
reg [31:0] rec_link_q;
reg [3:0]  rec_snap_q;
reg [1:0]  replay_lane_q;
reg [1:0]  replay_end_q;

// 分布式 RAM 的异步读口: 恢复时直接按 rec_snap_q 读快照 (不在公共路径上)。
wire [SNAP_W-1:0] snap_sel = snap_mem[rec_snap_q];

assign busy = busy_q;
assign full = 1'b0;

// ---------------------------------------------------------------------------
// 组合链: 4 lane 并行前缀 (公共路径, 每块 0..4 条动作)
// ---------------------------------------------------------------------------
reg [SP_W-1:0] sp_v          [0:4];
reg [SP_W-1:0] sp_after_pop  [0:3];
reg            do_push_t     [0:3];
reg            do_pop_t      [0:3];
reg [SP_W-1:0] push_idx_t    [0:3];
reg [1:0]      eff_i         [0:3];
reg [31:0]     top_val       [0:3];

reg            push_en_t     [0:3];
reg [31:0]     push_data_t   [0:3];

reg [3:0]      top_vld_c;
reg [127:0]    top_c;
reg [23:0]     ckpt_c;
reg [7:0]      eff_c;
reg [SP_W-1:0] sp_next;

// lane i 动作前的栈顶: 原栈 + 更早 lane 的 push 旁路 (高 lane 的 push 覆盖低的)
function [31:0] stack_peek;
    input [3:0]      lane;
    input [SP_W-1:0] idx;
    integer j;
    reg [31:0] v;
    begin
        v = stk_q[idx];
        for (j = 0; j < 4; j = j + 1)
            if ((j < lane) && do_push_t[j] && (push_idx_t[j] == idx))
                v = dec_link[j*32 +: 32];
        stack_peek = v;
    end
endfunction

integer i, k;
reg [1:0] act_i;
reg       en_i;
always @(*) begin
    for (i = 0; i < 4; i = i + 1) begin
        push_en_t[i]   = 1'b0;
        push_idx_t[i]  = {SP_W{1'b0}};
        push_data_t[i] = 32'd0;
        do_push_t[i]   = 1'b0;
        do_pop_t[i]    = 1'b0;
        eff_i[i]       = 2'd0;
        top_val[i]     = 32'd0;
    end
    top_vld_c = 4'd0;
    top_c     = 128'd0;
    ckpt_c    = 24'd0;
    eff_c     = 8'd0;

    sp_v[0] = sp_q;

    // ---- 第一遍: 栈指针 / 有效动作 ----
    for (i = 0; i < 4; i = i + 1) begin
        en_i  = s1_valid && (i >= s1_pc_ofs) && (i <= s1_end_slot);
        act_i = dec_action[i*2 +: 2];

        do_pop_t[i]     = en_i && ((act_i == 2'd2) || (act_i == 2'd3)) &&
                          (sp_v[i] != 0);
        sp_after_pop[i] = sp_v[i] - {4'd0, do_pop_t[i]};
        do_push_t[i]    = en_i && ((act_i == 2'd1) || (act_i == 2'd3)) &&
                          (sp_after_pop[i] < DEPTH);
        push_idx_t[i]   = sp_after_pop[i];
        push_en_t[i]    = do_push_t[i];
        push_data_t[i]  = dec_link[i*32 +: 32];
        sp_v[i+1]       = sp_after_pop[i] + {4'd0, do_push_t[i]};

        if (!en_i) eff_i[i] = 2'd0;
        else case (act_i)
            2'd1: eff_i[i] = do_push_t[i] ? 2'd1 : 2'd0;
            2'd2: eff_i[i] = do_pop_t[i]  ? 2'd2 : 2'd0;
            2'd3: eff_i[i] = do_pop_t[i] ? (do_push_t[i] ? 2'd3 : 2'd2) :
                                            (do_push_t[i] ? 2'd1 : 2'd0);
            default: eff_i[i] = 2'd0;
        endcase
    end

    // ---- 第二遍: top ----
    for (i = 0; i < 4; i = i + 1)
        top_val[i] = (sp_v[i] != 0) ?
                     stack_peek(i[3:0],
                                (sp_v[i] != 0) ? (sp_v[i] - 1'b1) : {SP_W{1'b0}}) :
                     32'd0;

    // ---- 输出 ----
    for (i = 0; i < 4; i = i + 1) begin
        top_vld_c[i]      = (sp_v[i] != 0);
        top_c[i*32 +: 32] = top_val[i];
        // 快照 id 就是 FTQ entry index; lane 用绝对 slot。
        ckpt_c[i*6 +: 6]  = {s1_idx, i[1:0]};
        eff_c[i*2 +: 2]   = eff_i[i];
    end

    sp_next = sp_v[4];
end

assign top_vld    = busy_q ? 4'b0 : top_vld_c;
assign top        = top_c;
assign ckpt       = ckpt_c;
assign eff_action = eff_c;

// ---------------------------------------------------------------------------
// 快照写数据 (动作之前的栈 + 本块动作/PC)
// ---------------------------------------------------------------------------
wire [DEPTH*32-1:0] stk_flat;
genvar g;
generate
for (g = 0; g < DEPTH; g = g + 1) begin : g_flat
    assign stk_flat[g*32 +: 32] = stk_q[g];
end
endgenerate

wire [SNAP_W-1:0] snap_wdata = {s1_pc_ofs, s1_start_pc, eff_c, sp_q, stk_flat};

// 快照写: 每块一个写口。与主状态机的 push 写同拍, 但地址/数据独立。
always @(posedge clk) begin
    if (s1_fire)
        snap_mem[s1_idx] <= snap_wdata;
end

// ---------------------------------------------------------------------------
// 恢复回放
// ---------------------------------------------------------------------------
wire [31:0] snap_start_pc = snap_sel[SW_PC +: 32];
wire [31:0] snap_line_pc  = {snap_start_pc[31:4], 4'b0};
// 分支 lane 用 redirect 送来的实际 link; 更早的 lane 用快照块 PC 重算 pc+4。
wire [31:0] replay_link   = (replay_lane_q == rec_lane_q) ? rec_link_q :
                            (snap_line_pc + {replay_lane_q, 2'b00} + 32'd4);
wire [2:0]  replay_act    = (replay_lane_q == rec_lane_q) ? rec_action_q :
                            {1'b0, snap_sel[SW_EFF + replay_lane_q*2 +: 2]};

// ---------------------------------------------------------------------------
// 顺序
// ---------------------------------------------------------------------------
integer j;
always @(posedge clk) begin
    if (rst) begin
        sp_q           <= {SP_W{1'b0}};
        snap_valid_q   <= {DEPTH{1'b0}};
        state_q        <= ST_IDLE;
        busy_q         <= 1'b0;
        rec_lane_q     <= 2'd0;
        rec_replay_q   <= 1'b0;
        rec_action_q   <= 3'd0;
        rec_link_q     <= 32'd0;
        rec_snap_q     <= 4'd0;
        replay_lane_q  <= 2'd0;
        replay_end_q   <= 2'd0;
        for (j = 0; j < DEPTH; j = j + 1)
            stk_q[j] <= 32'd0;
    end else if (clr_valid) begin
        sp_q           <= {SP_W{1'b0}};
        snap_valid_q   <= {DEPTH{1'b0}};
        state_q        <= ST_IDLE;
        busy_q         <= 1'b0;
    end else if (rec_valid) begin
        if (snap_valid_q[rec_ckpt[5:2]]) begin
            rec_lane_q    <= rec_ckpt[1:0];
            rec_replay_q  <= rec_replay;
            rec_action_q  <= rec_action;
            rec_link_q    <= rec_link;
            rec_snap_q    <= rec_ckpt[5:2];
            state_q       <= ST_RESTORE;
            busy_q        <= 1'b1;
        end else begin
            // 无效快照: 丢掉推测栈和全部快照 id, 保持正确性
            sp_q          <= {SP_W{1'b0}};
            snap_valid_q  <= {DEPTH{1'b0}};
            state_q       <= ST_IDLE;
            busy_q        <= 1'b0;
        end
    end else begin
        // ---- 公共路径: 应用本块动作 + 写快照 ----
        if (s1_fire) begin
            snap_valid_q[s1_idx] <= 1'b1;
            for (k = 0; k < 4; k = k + 1)
                if (push_en_t[k])
                    stk_q[push_idx_t[k]] <= push_data_t[k];
            sp_q <= sp_next;
        end

        // ---- 恢复 FSM ----
        case (state_q)
            ST_RESTORE: begin
                for (j = 0; j < DEPTH; j = j + 1)
                    stk_q[j] <= snap_sel[j*32 +: 32];
                sp_q <= snap_sel[SW_SP +: SP_W];
                if (rec_replay_q && (snap_sel[SW_OFS +: 2] <= rec_lane_q)) begin
                    replay_lane_q <= snap_sel[SW_OFS +: 2];
                    replay_end_q  <= rec_lane_q;
                    state_q       <= ST_REPLAY;
                end else begin
                    state_q <= ST_IDLE;
                    busy_q  <= 1'b0;
                end
            end
            ST_REPLAY: begin
                case (replay_act)
                    3'd1: begin // push
                        if (sp_q < DEPTH) begin
                            stk_q[sp_q] <= replay_link;
                            sp_q        <= sp_q + 1'b1;
                        end
                    end
                    3'd2: begin // pop
                        if (sp_q != 0)
                            sp_q <= sp_q - 1'b1;
                    end
                    3'd3: begin // pop_push
                        if (sp_q != 0)
                            stk_q[sp_q - 1'b1] <= replay_link;
                        else begin
                            stk_q[0] <= replay_link;
                            sp_q     <= 1'b1;
                        end
                    end
                    default: ;
                endcase

                if (replay_lane_q == replay_end_q) begin
                    state_q <= ST_IDLE;
                    busy_q  <= 1'b0;
                end else begin
                    replay_lane_q <= replay_lane_q + 1'b1;
                end
            end
            default: begin
                state_q <= ST_IDLE;
                busy_q  <= 1'b0;
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// 断言
// ---------------------------------------------------------------------------
// synopsys translate_off
always @(posedge clk) begin
    if (!rst && (state_q == ST_REPLAY) &&
        (replay_lane_q > replay_end_q) && (replay_lane_q != 2'd0)) begin
        $display("[IFU3-RAS] ERROR: replay lane %0d > end %0d",
                 replay_lane_q, replay_end_q);
        $fatal;
    end
    if (!rst && busy_q && (sp_q > DEPTH)) begin
        $display("[IFU3-RAS] ERROR: sp=%0d > DEPTH", sp_q);
        $fatal;
    end
end
// synopsys translate_on

endmodule
