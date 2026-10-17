`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu3_ifu — IFU S0/S1/S2 定向台
//
// 覆盖:
//   * S0 back-to-back: ICache 连续 hit 时约 1 块/拍 (原计划的吞吐规则)
//   * 响应旁路 + skid: IBUF 反压 (ib_count=7) 时仍按 4B 连续 PC 交付, 不丢块
//   * 非对齐 start_pc=0x1004: 只交付 slot>=1, 下一块从 line+16 继续
//   * NOP 流下 PredChecker 不发 override
//
// 说明: FTQ/ICache/IBUF 都是行为模型; IBUF 的 push_accept 严格等于
//       push_mask 的 popcount (与 rv32ifu2_ibuf 的契约一致)。
// ===========================================================================
module tb_ifu3_ifu;

reg clk = 0; always #5 clk = ~clk;
reg rst = 1;

// FTQ 伪模型
reg  [ 31:0] cur_start;
reg          ftq_rd_valid;
wire [  2:0] ftq_inflight;
wire         ftq_finish;
reg  [ 31:0] ftq_rd_start_pc;
wire         ftq_rd_taken;
wire [  1:0] ftq_rd_taken_slot;
wire [ 31:0] ftq_rd_target;
wire [  3:0] ftq_rd_btb_cond;
wire [ 15:0] ftq_rd_phr;
wire [  5:0] ftq_rd_meta_id;
wire [  3:0] ftq_rd_ptr;
reg  [  3:0] ftq_head_idx;

// ICache 行为模型
reg  [ 31:0] ic_q_pc;
reg  [127:0] ic_q_data;
reg          ic_q_hit;
wire [ 31:0] ic_rd_addr;
wire         ic_req_active;

// IBUF 行为模型
wire [  3:0] ib_push_mask;
wire [152:0] ib_push_data0;
wire [152:0] ib_push_data1;
wire [152:0] ib_push_data2;
wire [152:0] ib_push_data3;
reg  [  2:0] ib_push_accept;
reg  [  3:0] ib_count;

wire         idu_flush;
reg          init_done;

wire         ifu_ovr_valid;
wire [  3:0] ifu_ovr_idx;
wire         ifu_ovr_taken;
wire [  1:0] ifu_ovr_taken_slot;
wire [ 31:0] ifu_ovr_target;
wire [  3:0] ifu_ovr_btb_cond;
wire [ 15:0] ifu_ovr_phr;

wire [2:0] acc_push = {1'b0,ib_push_mask[0]} + {1'b0,ib_push_mask[1]} +
                      {1'b0,ib_push_mask[2]} + {1'b0,ib_push_mask[3]};

rv32ifu3_ifu dut (
    .clk(clk), .rst(rst),
    .ftq_rd_valid(ftq_rd_valid), .ftq_rd_start_pc(ftq_rd_start_pc),
    .ftq_rd_taken(ftq_rd_taken), .ftq_rd_taken_slot(ftq_rd_taken_slot),
    .ftq_rd_target(ftq_rd_target), .ftq_rd_btb_cond(ftq_rd_btb_cond),
    .ftq_rd_phr(ftq_rd_phr), .ftq_rd_meta_id(ftq_rd_meta_id),
    .ftq_rd_ptr(ftq_rd_ptr), .ftq_head_idx(ftq_head_idx),
    .ftq_inflight(ftq_inflight), .ftq_finish(ftq_finish),
    .ovr_valid(1'b0), .ovr_idx(4'd0),
    .iu_btb_chk(25'd0), .iu_btb_pc(32'd0), .iu_btb_taken(1'b0),
    .redirect_rtu(1'b0), .rtu_train_vld(1'b0), .rtu_train_chk(25'd0),
    .ifu_ovr_valid(ifu_ovr_valid), .ifu_ovr_idx(ifu_ovr_idx),
    .ifu_ovr_taken(ifu_ovr_taken), .ifu_ovr_taken_slot(ifu_ovr_taken_slot),
    .ifu_ovr_target(ifu_ovr_target), .ifu_ovr_btb_cond(ifu_ovr_btb_cond),
    .ifu_ovr_phr(ifu_ovr_phr),
    .ic_rd_addr(ic_rd_addr), .ic_q_pc(ic_q_pc), .ic_q_data(ic_q_data),
    .ic_q_hit(ic_q_hit), .ic_req_active(ic_req_active),
    .ib_push_mask(ib_push_mask), .ib_push_data0(ib_push_data0),
    .ib_push_data1(ib_push_data1), .ib_push_data2(ib_push_data2),
    .ib_push_data3(ib_push_data3), .ib_push_accept(ib_push_accept),
    .ib_count(ib_count),
    .redirect(1'b0), .redirect_pc(32'd0), .init_done(init_done)
);

assign ftq_rd_start_pc  = cur_start;
assign ftq_rd_taken     = 1'b0;
assign ftq_rd_taken_slot= 2'd3;
assign ftq_rd_target    = 32'd0;
assign ftq_rd_btb_cond  = 4'd0;
assign ftq_rd_phr       = 16'd0;
assign ftq_rd_meta_id   = 6'd0;
assign ftq_rd_ptr       = 4'd0;

// ICache: 1 拍同步读, 永远 hit, 全 NOP
always @(posedge clk) begin
    if (rst) begin
        ic_q_pc   <= 32'd0;
        ic_q_data <= 128'd0;
        ic_q_hit  <= 1'b0;
    end else begin
        ic_q_pc   <= ic_rd_addr;
        ic_q_data <= {32'h00000013, 32'h00000013, 32'h00000013, 32'h00000013};
        ic_q_hit  <= 1'b1;
    end
end

// IBUF 契约: accept = popcount(push_mask)
always @(*) begin
    ib_push_accept = acc_push;
end

integer errs = 0;
integer pushed = 0;
integer pc_err = 0;
reg [31:0] expected_pc;
integer s0_issues = 0;
integer s0_measured = 0;
integer measure = 0;
integer ncycle = 0;

task automatic fail(input string msg);
    begin
        errs = errs + 1;
        if (errs <= 30) $display("[IFU-TB] FAIL @%0t: %s", $time, msg);
    end
endtask

// 每个被接受 lane 的 PC 必须连续 4B
always @(negedge clk) begin
    if (!rst && init_done) begin
        if (ib_push_mask[0]) begin
            if (ib_push_data0[63:32] !== expected_pc) begin
                pc_err = pc_err + 1;
                if (pc_err <= 10)
                    $display("[IFU-TB] PC gap lane0 got=%h exp=%h", ib_push_data0[63:32], expected_pc);
            end
            expected_pc = expected_pc + 4;
            pushed = pushed + 1;
        end
        if (ib_push_mask[1]) begin
            if (ib_push_data1[63:32] !== expected_pc) begin
                pc_err = pc_err + 1;
                if (pc_err <= 10)
                    $display("[IFU-TB] PC gap lane1 got=%h exp=%h", ib_push_data1[63:32], expected_pc);
            end
            expected_pc = expected_pc + 4;
            pushed = pushed + 1;
        end
        if (ib_push_mask[2]) begin
            if (ib_push_data2[63:32] !== expected_pc) begin
                pc_err = pc_err + 1;
                if (pc_err <= 10)
                    $display("[IFU-TB] PC gap lane2 got=%h exp=%h", ib_push_data2[63:32], expected_pc);
            end
            expected_pc = expected_pc + 4;
            pushed = pushed + 1;
        end
        if (ib_push_mask[3]) begin
            if (ib_push_data3[63:32] !== expected_pc) begin
                pc_err = pc_err + 1;
                if (pc_err <= 10)
                    $display("[IFU-TB] PC gap lane3 got=%h exp=%h", ib_push_data3[63:32], expected_pc);
            end
            expected_pc = expected_pc + 4;
            pushed = pushed + 1;
        end
    end
end

// S0 issue 计数 + 下一块 start PC 推进 (对齐口径)
always @(posedge clk) begin
    if (!rst) begin
        ncycle <= ncycle + 1;
        if (measure && dut.s0_issue) s0_issues <= s0_issues + 1;
        if (dut.s0_issue) begin
            // 非对齐块也按 line+16 推进 (IFU 的 fall-through 口径)
            cur_start <= {cur_start[31:4], 4'b0} + 32'd16;
        end
        // PredChecker 修正时, 下一块从修正 target 开始
        if (ifu_ovr_valid) begin
            cur_start <= ifu_ovr_target;
        end
    end
end

task automatic reset_dut;
    begin
        rst = 1; init_done = 0; ftq_rd_valid = 0;
        ib_count = 0;
        expected_pc = 0; pushed = 0; pc_err = 0; s0_issues = 0; measure = 0;
        repeat (3) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);
        init_done = 1;
    end
endtask

integer i;
initial begin
    // ---- 1) 连续对齐块: 吞吐 + PC 连续性 ----
    cur_start = 32'h1000;
    expected_pc = 32'h1000;
    ftq_rd_valid = 1;
    reset_dut();
    cur_start = 32'h1000;   // reset_dut 期间被推进过
    expected_pc = 32'h1000;
    ftq_rd_valid = 1;

    repeat (20) @(posedge clk);
    measure = 1;
    repeat (50) @(posedge clk);
    measure = 0;
    s0_measured = s0_issues;
    $display("[IFU-TB] back-to-back S0 issues in 50 cycles = %0d", s0_measured);
    if (s0_measured < 40) begin
        fail($sformatf("S0 吞吐不足: %0d/50 (期望 >=40)", s0_measured));
    end
    repeat (20) @(posedge clk);
    if (pc_err != 0) fail($sformatf("连续块 PC gap %0d 次", pc_err));
    if (pushed < 200) fail($sformatf("交付 lane 太少: %0d", pushed));

    // ---- 2) IBUF 反压: 只放 1 格, 仍不能丢块/跳 PC ----
    ib_count = 4'd7;
    repeat (30) @(posedge clk);
    ib_count = 4'd0;
    repeat (20) @(posedge clk);
    if (pc_err != 0) fail($sformatf("反压 PC gap %0d 次", pc_err));
    if (ifu_ovr_valid) fail("NOP 流不该有 PredChecker override");

    // ---- 3) 非对齐 start_pc=0x1004: 只放一块 ----
    reset_dut();
    cur_start = 32'h1004;
    expected_pc = 32'h1004;
    ftq_rd_valid = 0;
    @(negedge clk); ftq_rd_valid = 1;
    @(negedge clk); ftq_rd_valid = 0;
    repeat (20) @(posedge clk);
    if (pc_err != 0) fail($sformatf("非对齐块 PC gap %0d 次", pc_err));
    // 0x1004 块只应交付 3 lane (slot 1..3)
    if (pushed != 3) fail($sformatf("非对齐块交付 lane=%0d exp=3", pushed));

    $display("");
    if (errs == 0) begin
        $display("[tb_ifu3_ifu] PASS  pushed=%0d back-to-back=%0d", pushed, s0_measured);
    end else begin
        $display("[tb_ifu3_ifu] FAIL %0d errors (pushed=%0d pc_gap=%0d)", errs, pushed, pc_err);
        $fatal(1);
    end
    $finish;
end

initial begin
    #2_000_000;
    $display("[tb_ifu3_ifu] 致命: 超时");
    $fatal(1);
end

endmodule
