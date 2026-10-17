`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_ras — IFU3 的推测返回地址栈 + 精确 undo log
//
// 与 ifu2 的 pointer-only RAS 不同: 这里把每次 push/pop 都记进 undo log,
// 误预测恢复时按 log 逆序撤销, 连**被覆盖的栈内容**一起恢复, 不是只拨指针。
//
// 数据流:
//   * S1 组合译码 4 条指令 -> dec_action/dec_link
//   * 本模块组合算出每条 lane 的 top/top_vld/ckpt/eff_action
//   * S1 fire 时一次性应用 0..4 条动作 (最多 8 条 log)
//   * chk 携带 {ckpt[5:0], eff_action[2:0]} 随指令走
//   * IU 重定向: 按 chk 的 ckpt 回滚, 再重放该分支的实际动作
//   * BPU override: 按 S2 块的 start_ckpt 回滚 (不重放)
//   * RTU 重定向: 无 chk, 清空 (与 PHR 清 0 同口径)
//   * 退休: 用 chk 的 eff_action 推进 log 的 commit 指针
//
// log 满 (占用 >= 63) 时 full=1, IFU 闸住 S1 fire; 退休独立前进, 不会死锁。
// rollback 是多拍 FSM; busy 期间 IFU 闸住 S1 fire, PredChecker 视为 RAS 无效。
// ===========================================================================
module rv32ifu3_ras #(
    parameter DEPTH     = 16,
    parameter LOG_DEPTH = 64
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- S1 译码/应用 ----
    input  wire         s1_valid,
    input  wire [  1:0] s1_pc_ofs,
    input  wire [  1:0] s1_end_slot,   // 修正后的交付终点 (含)
    input  wire         s1_fire,
    input  wire [  7:0] dec_action,    // 2b/lane: 0=none 1=push 2=pop 3=pop_push
    input  wire [127:0] dec_link,      // 32b/lane: call 的 pc+4

    // ---- 组合读: 每条 lane 动作之前的状态 ----
    output wire [  3:0] top_vld,
    output wire [127:0] top,           // 32b/lane
    output wire [ 23:0] ckpt,          // 6b/lane: 该 lane 动作前的 log 写指针
    output wire [  7:0] eff_action,    // 2b/lane: 实际生效的动作 (栈空/满会退化)
    output wire         busy,
    output wire         full,

    // ---- 恢复 ----
    input  wire         rec_valid,     // IU redirect 或 BPU override
    input  wire [  5:0] rec_ckpt,
    input  wire [  2:0] rec_action,    // 0..3, 回滚后重放该动作
    input  wire [ 31:0] rec_link,
    input  wire         clr_valid,     // RTU redirect: 清空

    // ---- 退休 ----
    input  wire         cmt_valid,
    input  wire [  2:0] cmt_action,  // chk[18:16], 当前编码 0..3
    input  wire [  5:0] cmt_ckpt     // chk[24:19], 必须等于 log 里最老未提交动作的指针
);

localparam SP_W = $clog2(DEPTH + 1);   // 16 -> 5
localparam CW   = $clog2(LOG_DEPTH);   // 64 -> 6

reg [31:0] stk_q [0:DEPTH-1];
reg [SP_W-1:0] sp_q;                    // 0..DEPTH

reg [LOG_DEPTH-1:0] log_op_q;           // 1=push, 0=pop
reg [31:0]          log_data_q [0:LOG_DEPTH-1];
reg [CW-1:0]        wr_q;
reg [CW-1:0]        cmt_q;

reg                 busy_q;
reg [CW-1:0]        rec_target_q;
reg [2:0]           rec_action_q;
reg [31:0]          rec_link_q;

assign busy = busy_q;

// ---------------------------------------------------------------------------
// 组合链: 逐 slot 推演 0..4 条动作
// ---------------------------------------------------------------------------
reg [SP_W-1:0] sp_t;
reg [CW-1:0]   wr_t;
reg [31:0]     stk_t [0:DEPTH-1];

reg [31:0]     log_data_t [0:7];
reg [CW-1:0]   log_idx_t  [0:7];
reg            log_op_t   [0:7];
reg            log_en_t   [0:7];
reg [3:0]      nlog_t;

reg            push_en_t   [0:3];
reg [SP_W-1:0] push_idx_t  [0:3];
reg [31:0]     push_data_t [0:3];

reg [3:0]      top_vld_c;
reg [127:0]    top_c;
reg [23:0]     ckpt_c;
reg [7:0]      eff_c;
reg [SP_W-1:0] sp_next;
reg [CW-1:0]   wr_next;

integer i, k;
always @(*) begin
    sp_t = sp_q;
    wr_t = wr_q;
    for (i = 0; i < DEPTH; i = i + 1)
        stk_t[i] = stk_q[i];

    nlog_t = 4'd0;
    for (k = 0; k < 8; k = k + 1) begin
        log_en_t[k]   = 1'b0;
        log_op_t[k]   = 1'b0;
        log_data_t[k] = 32'd0;
        log_idx_t[k]  = {CW{1'b0}};
    end
    for (i = 0; i < 4; i = i + 1) begin
        push_en_t[i]   = 1'b0;
        push_idx_t[i]  = {SP_W{1'b0}};
        push_data_t[i] = 32'd0;
    end

    top_vld_c = 4'd0;
    top_c     = 128'd0;
    ckpt_c    = 24'd0;
    eff_c     = 8'd0;

    for (i = 0; i < 4; i = i + 1) begin
        ckpt_c[i*6 +: 6] = wr_t;
        top_vld_c[i]     = (sp_t != 0);
        top_c[i*32 +: 32] = (sp_t != 0) ? stk_t[sp_t - 1'b1] : 32'd0;

        // 只有 [pc_ofs, end_slot] 内的 lane 才真正推进 RAS
        if (s1_valid && (i >= s1_pc_ofs) && (i <= s1_end_slot)) begin
            case (dec_action[i*2 +: 2])
                2'd1: begin // push
                    if (sp_t < DEPTH) begin
                        push_en_t[i]   = 1'b1;
                        push_idx_t[i]  = sp_t;
                        push_data_t[i] = dec_link[i*32 +: 32];
                        stk_t[sp_t]    = dec_link[i*32 +: 32];

                        log_en_t[nlog_t]   = 1'b1;
                        log_op_t[nlog_t]   = 1'b1;
                        log_data_t[nlog_t] = dec_link[i*32 +: 32];
                        log_idx_t[nlog_t]  = wr_t;
                        nlog_t = nlog_t + 4'd1;
                        wr_t   = wr_t + 1'b1;
                        sp_t   = sp_t + 1'b1;
                        eff_c[i*2 +: 2] = 2'd1;
                    end
                end
                2'd2: begin // pop
                    if (sp_t != 0) begin
                        log_en_t[nlog_t]   = 1'b1;
                        log_op_t[nlog_t]   = 1'b0;
                        log_data_t[nlog_t] = stk_t[sp_t - 1'b1];
                        log_idx_t[nlog_t]  = wr_t;
                        nlog_t = nlog_t + 4'd1;
                        wr_t   = wr_t + 1'b1;
                        sp_t   = sp_t - 1'b1;
                        eff_c[i*2 +: 2] = 2'd2;
                    end
                end
                2'd3: begin // pop_push: 先 pop 再 push
                    if (sp_t != 0) begin
                        log_en_t[nlog_t]   = 1'b1;
                        log_op_t[nlog_t]   = 1'b0;
                        log_data_t[nlog_t] = stk_t[sp_t - 1'b1];
                        log_idx_t[nlog_t]  = wr_t;
                        nlog_t = nlog_t + 4'd1;
                        wr_t   = wr_t + 1'b1;
                        sp_t   = sp_t - 1'b1;
                        eff_c[i*2 +: 2] = 2'd2;
                    end
                    if (sp_t < DEPTH) begin
                        push_en_t[i]   = 1'b1;
                        push_idx_t[i]  = sp_t;
                        push_data_t[i] = dec_link[i*32 +: 32];
                        stk_t[sp_t]    = dec_link[i*32 +: 32];

                        log_en_t[nlog_t]   = 1'b1;
                        log_op_t[nlog_t]   = 1'b1;
                        log_data_t[nlog_t] = dec_link[i*32 +: 32];
                        log_idx_t[nlog_t]  = wr_t;
                        nlog_t = nlog_t + 4'd1;
                        wr_t   = wr_t + 1'b1;
                        sp_t   = sp_t + 1'b1;
                        eff_c[i*2 +: 2] = (eff_c[i*2 +: 2] == 2'd2) ? 2'd3 : 2'd1;
                    end
                end
                default: ;
            endcase
        end
    end

    sp_next = sp_t;
    wr_next = wr_t;
end

// 本块最多还要 8 条 log; 必须把当前块的 nlog 也算进去, 否则可能在
// “占用 60、块要 8 条”时覆盖最老的未提交项。
wire [6:0] occ_need = {1'b0, wr_q - cmt_q} + {3'b0, nlog_t};
assign full = s1_valid ? (occ_need > (LOG_DEPTH - 1)) :
                         ((wr_q - cmt_q) == (LOG_DEPTH - 1));

assign top_vld    = busy_q ? 4'b0 : top_vld_c;
assign top        = top_c;
assign ckpt       = ckpt_c;
assign eff_action = eff_c;

// ---------------------------------------------------------------------------
// 顺序: S1 应用 / rollback / 清空
// ---------------------------------------------------------------------------
wire [5:0] occ_q      = wr_q - cmt_q;
wire [5:0] rec_dist_q = wr_q - rec_ckpt;
wire       rec_ok     = (rec_dist_q <= occ_q);
// checkpoint 无效 (log 回绕/快照过期) 时整颗 RAS 清掉, 保持指针一致。
wire       invalid_rec = rec_valid && !rec_ok;

integer j;
always @(posedge clk) begin
    if (rst) begin
        sp_q          <= {SP_W{1'b0}};
        wr_q          <= {CW{1'b0}};
        busy_q        <= 1'b0;
        rec_target_q  <= {CW{1'b0}};
        rec_action_q  <= 3'd0;
        rec_link_q    <= 32'd0;
        for (j = 0; j < DEPTH; j = j + 1)
            stk_q[j] <= 32'd0;
        log_op_q <= {LOG_DEPTH{1'b0}};
        for (j = 0; j < LOG_DEPTH; j = j + 1)
            log_data_q[j] <= 32'd0;
    end else if (clr_valid) begin
        // RTU 重定向: 没有 chk, 丢掉全部推测状态 (栈内容不清理, 指针归零即可)
        sp_q     <= {SP_W{1'b0}};
        wr_q     <= {CW{1'b0}};
        busy_q   <= 1'b0;
    end else if (rec_valid) begin
        if (rec_ok) begin
            rec_target_q <= rec_ckpt;
            rec_action_q <= rec_action;
            rec_link_q   <= rec_link;
            busy_q       <= 1'b1;
        end else begin
            // checkpoint 不在 live window (log 回绕/无效快照): 丢掉 RAS, 保正确性
            sp_q     <= {SP_W{1'b0}};
            wr_q     <= {CW{1'b0}};
            busy_q   <= 1'b0;
            // cmt_q 由下面的独立 always 用 invalid_rec 清 0
        end
    end else if (busy_q) begin
        if (wr_q != rec_target_q) begin
            // 逆序撤销一条
            wr_q <= wr_q - 1'b1;
            if (log_op_q[wr_q - 1'b1]) begin
                if (sp_q != 0)
                    sp_q <= sp_q - 1'b1;                // undo push
            end else begin
                if (sp_q < DEPTH) begin
                    stk_q[sp_q] <= log_data_q[wr_q - 1'b1]; // undo pop
                    sp_q        <= sp_q + 1'b1;
                end
            end
        end else begin
            // 回到了块首/分支前, 重放该分支的实际动作
            case (rec_action_q)
                3'd1: begin // push
                    if (sp_q < DEPTH) begin
                        stk_q[sp_q]        <= rec_link_q;
                        log_op_q[wr_q]     <= 1'b1;
                        log_data_q[wr_q]   <= rec_link_q;
                        sp_q               <= sp_q + 1'b1;
                        wr_q               <= wr_q + 1'b1;
                    end
                end
                3'd2: begin // pop
                    if (sp_q != 0) begin
                        log_op_q[wr_q]   <= 1'b0;
                        log_data_q[wr_q] <= stk_q[sp_q - 1'b1];
                        sp_q             <= sp_q - 1'b1;
                        wr_q             <= wr_q + 1'b1;
                    end
                end
                3'd3: begin // pop_push
                    if (sp_q != 0) begin
                        log_op_q[wr_q]     <= 1'b0;
                        log_data_q[wr_q]   <= stk_q[sp_q - 1'b1];
                        log_op_q[wr_q+1'b1]   <= 1'b1;
                        log_data_q[wr_q+1'b1] <= rec_link_q;
                        stk_q[sp_q - 1'b1] <= rec_link_q;
                        wr_q               <= wr_q + 2'd2;
                    end else begin
                        log_op_q[wr_q]   <= 1'b1;
                        log_data_q[wr_q] <= rec_link_q;
                        stk_q[0]         <= rec_link_q;
                        sp_q             <= 1'b1;
                        wr_q             <= wr_q + 1'b1;
                    end
                end
                default: ;
            endcase
            busy_q <= 1'b0;
        end
    end else if (s1_fire) begin
        for (k = 0; k < 8; k = k + 1) begin
            if (log_en_t[k]) begin
                log_op_q[log_idx_t[k]]   <= log_op_t[k];
                log_data_q[log_idx_t[k]] <= log_data_t[k];
            end
        end
        for (k = 0; k < 4; k = k + 1) begin
            if (push_en_t[k])
                stk_q[push_idx_t[k]] <= push_data_t[k];
        end
        sp_q <= sp_next;
        wr_q <= wr_next;
    end
end

// 退休: 只推进 commit 指针, 不改栈。cmt_action: 0=0 条, 1/2=1 条, 3=2 条。
wire [2:0]    cmt_inc3 = (cmt_action == 3'd3) ? 3'd2 :
                         (cmt_action != 3'd0) ? 3'd1 : 3'd0;
wire [CW-1:0] cmt_inc  = {{(CW-3){1'b0}}, cmt_inc3};

// RTU 重定向会清空 RAS, 但 RTU 的训练 FIFO 不会清; 已经退休的 call/ret
// 训练事件可能在 clear 之后才到。此时 log 是空的, 没有可提交的动作, 忽略。
// ckpt 用来诊断: 正常情况下应等于 log 里最老未提交动作的指针。训练 FIFO 的
// 延迟/clear 可能让它对不上; 对不上只告警一次, 不能因此停止推进 commit
// (否则 log 会满, S1 永久停顿)。
wire cmt_do = cmt_valid && (cmt_inc != {CW{1'b0}}) && (wr_q != cmt_q);

always @(posedge clk) begin
    if (rst || clr_valid || invalid_rec)
        cmt_q <= {CW{1'b0}};
    else if (cmt_do)
        cmt_q <= cmt_q + cmt_inc;
end

// ---------------------------------------------------------------------------
// 断言
// ---------------------------------------------------------------------------
// synopsys translate_off
reg late_warned;
initial late_warned = 1'b0;
reg mismatch_warned;
initial mismatch_warned = 1'b0;
integer dj;
integer dbg_cmt_n;
initial dbg_cmt_n = 0;
always @(posedge clk) begin
    if ($test$plusargs("IFU3_DBG") && !rst && cmt_valid &&
        (cmt_inc != {CW{1'b0}}) && (dbg_cmt_n < 300)) begin
        $display("[RAS-CMT] t=%0t cmt=%0d ckpt=%0d act=%0d wr=%0d sp=%0d",
                 $time, cmt_q, cmt_ckpt, cmt_action, wr_q, sp_q);
        dbg_cmt_n <= dbg_cmt_n + 1;
    end
end
always @(posedge clk) begin
    if (!rst && !clr_valid && cmt_valid && (cmt_inc != {CW{1'b0}})) begin
        if (wr_q == cmt_q) begin
            if (!late_warned) begin
                late_warned <= 1'b1;
                $display("[IFU3-RAS] WARN: clear 之后的迟到训练事件 (action=%0d), 后续静默", cmt_action);
            end
        end else if ((wr_q - cmt_q) < cmt_inc) begin
            $display("[IFU3-RAS] ERROR: commit 越过未提交 log (cmt=%0d inc=%0d wr=%0d)",
                     cmt_q, cmt_inc, wr_q);
            $fatal;
        end
        if ((cmt_ckpt != cmt_q) && !mismatch_warned) begin
            mismatch_warned <= 1'b1;
            $display("[IFU3-RAS] DBG ckpt=%0d cmt=%0d wr=%0d action=%0d sp=%0d",
                     cmt_ckpt, cmt_q, wr_q, cmt_action, sp_q);
            for (dj = 0; dj < 8; dj = dj + 1)
                $display("[IFU3-RAS]   log[%0d] op=%b data=%h",
                         (cmt_q + dj[5:0]) & 6'h3F,
                         log_op_q[(cmt_q + dj[5:0]) & 6'h3F],
                         log_data_q[(cmt_q + dj[5:0]) & 6'h3F]);
        end
    end
    if (!rst && rec_valid && !rec_ok) begin
        $display("[IFU3-RAS] WARN: 无效 checkpoint (wr=%0d ckpt=%0d cmt=%0d), 丢 RAS",
                 wr_q, rec_ckpt, cmt_q);
    end
    if (!rst && busy_q && (sp_q > DEPTH)) begin
        $display("[IFU3-RAS] ERROR: sp=%0d > DEPTH", sp_q);
        $fatal;
    end
    if (!rst && busy_q && (wr_q != rec_target_q)) begin
        if ( log_op_q[wr_q - 1'b1] && (sp_q == 0)) begin
            $display("[IFU3-RAS] ERROR: undo push at sp=0 (wr=%0d)", wr_q);
            $fatal;
        end
        if (!log_op_q[wr_q - 1'b1] && (sp_q >= DEPTH)) begin
            $display("[IFU3-RAS] ERROR: undo pop at sp=%0d (wr=%0d)", sp_q, wr_q);
            $fatal;
        end
    end
end
// synopsys translate_on

endmodule
