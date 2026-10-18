`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu3_sc — 定向: tag 命中 / 6-bit 计数器 / 强信心 use / RR 分配 / 非条件不训练
//
// 时序按 BPU 的实际用法:
//   BP0 给 rd_line_pc/rd_phr -> q_set 打一拍
//   BP1 再给 tag_line_pc/tag_phr (与 q_set 同一个块) -> dir/hit/use
// ===========================================================================
module tb_ifu3_sc;

reg clk = 0; always #5 clk = ~clk;
reg rst;

reg  [31:0] rd_line_pc;
reg  [15:0] rd_phr;
reg  [31:0] tag_line_pc;
reg  [15:0] tag_phr;
reg  [ 3:0] slot_cond;
wire [ 3:0] dir;
wire [ 3:0] hit;
wire [ 3:0] use;

reg         upd_vld;
reg  [31:0] upd_pc;
reg         upd_taken;
reg         upd_is_cond;
reg  [15:0] upd_phr;

rv32ifu3_sc #(.SC_L(5'd12), .THRESH(6'd6)) dut (
    .clk         (clk),
    .rst         (rst),
    .rd_line_pc  (rd_line_pc),
    .rd_phr      (rd_phr),
    .tag_line_pc (tag_line_pc),
    .tag_phr     (tag_phr),
    .slot_cond   (slot_cond),
    .dir         (dir),
    .hit         (hit),
    .use         (use),
    .upd_vld     (upd_vld),
    .upd_pc      (upd_pc),
    .upd_taken   (upd_taken),
    .upd_is_cond (upd_is_cond),
    .upd_phr     (upd_phr)
);

integer errs = 0;

task automatic fail(input string msg);
    begin
        errs = errs + 1;
        if (errs <= 20) $display("[SC-TB] FAIL @%0t: %s", $time, msg);
    end
endtask

task automatic train(input [31:0] pc, input [15:0] phr,
                     input taken, input is_cond);
    begin
        @(negedge clk);
        upd_vld = 1'b1; upd_pc = pc; upd_phr = phr;
        upd_taken = taken; upd_is_cond = is_cond;
        @(negedge clk);
        upd_vld = 1'b0;
        @(posedge clk); #1;
    end
endtask

reg [3:0] r_dir, r_hit, r_use;

task automatic read_sc(input [31:0] line_pc, input [15:0] phr);
    begin
        @(negedge clk);
        rd_line_pc = line_pc;
        rd_phr     = phr;
        slot_cond  = 4'b1111;
        @(negedge clk);
        tag_line_pc = line_pc;
        tag_phr     = phr;
        #1;
        r_dir = dir; r_hit = hit; r_use = use;
    end
endtask

initial begin
    rst = 1'b1;
    rd_line_pc = 32'd0; rd_phr = 16'd0;
    tag_line_pc = 32'd0; tag_phr = 16'd0;
    slot_cond = 4'd0;
    upd_vld = 0; upd_pc = 0; upd_taken = 0; upd_is_cond = 0; upd_phr = 0;

    repeat (4) @(posedge clk);
    #1 rst = 1'b0;
    repeat (2) @(posedge clk);

    // ---- 1) 冷表: 无命中 ----
    read_sc(32'h0200, 16'h0000);
    if (r_hit !== 4'b0000)
        fail($sformatf("冷表 hit=%b exp=0000", r_hit));

    // ---- 2) 同一 slot1 训 6 次 taken: 首次 miss seed=33, 之后 5 次递增到 38 -> use=1 ----
    train(32'h0204, 16'h0000, 1'b1, 1'b1);
    train(32'h0204, 16'h0000, 1'b1, 1'b1);
    train(32'h0204, 16'h0000, 1'b1, 1'b1);
    train(32'h0204, 16'h0000, 1'b1, 1'b1);
    train(32'h0204, 16'h0000, 1'b1, 1'b1);
    train(32'h0204, 16'h0000, 1'b1, 1'b1);
    read_sc(32'h0200, 16'h0000);
    if (r_hit[1] !== 1'b1) fail($sformatf("slot1 hit=%b exp=1", r_hit[1]));
    if (r_use[1] !== 1'b1) fail($sformatf("slot1 use=%b exp=1 (ctr>=38)", r_use[1]));
    if (r_dir[1] !== 1'b1) fail($sformatf("slot1 dir=%b exp=1", r_dir[1]));

    // ---- 3) 同一 slot1 训 12 次 not-taken: 38 -> 26 -> use=1, dir=0 ----
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 37
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 36
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 35
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 34
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 33
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 32
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 31
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 30
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 29
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 28
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 27
    train(32'h0204, 16'h0000, 1'b0, 1'b1); // 26
    read_sc(32'h0200, 16'h0000);
    if (r_hit[1] !== 1'b1) fail($sformatf("not-taken slot1 hit=%b exp=1", r_hit[1]));
    if (r_use[1] !== 1'b1) fail($sformatf("not-taken slot1 use=%b exp=1 (ctr<=26)", r_use[1]));
    if (r_dir[1] !== 1'b0) fail($sformatf("not-taken slot1 dir=%b exp=0", r_dir[1]));

    // ---- 4) 同 pc 不同 PHR: 不同 set/tag, 不应命中 ----
    read_sc(32'h0200, 16'h0001);
    if (r_hit[1] !== 1'b0)
        fail($sformatf("PHR=1 不应命中 slot1: hit=%b", r_hit[1]));

    // ---- 5) 非条件训练不改变表 ----
    train(32'h0208, 16'h0000, 1'b1, 1'b0);
    train(32'h0208, 16'h0000, 1'b1, 1'b0);
    train(32'h0208, 16'h0000, 1'b1, 1'b0);
    read_sc(32'h0200, 16'h0000);
    if (r_hit[2] !== 1'b0)
        fail($sformatf("非条件分支训了 slot2: hit=%b", r_hit[2]));

    // ---- 6) 4 way 分配 + RR: slot0/1/2/3 各占一 way, 第 5 个替换 way0 ----
    // 0x200/0x204/0x208/0x20C 同 set (line_pc[9:4]=0x20), tag 含 slot.
    // 先让 slot0/2/3 各训 2 次 (slot1 已有), 共 4 way.
    train(32'h0200, 16'h0000, 1'b1, 1'b1);
    train(32'h0200, 16'h0000, 1'b1, 1'b1);
    train(32'h0208, 16'h0000, 1'b1, 1'b1);
    train(32'h0208, 16'h0000, 1'b1, 1'b1);
    train(32'h020C, 16'h0000, 1'b1, 1'b1);
    train(32'h020C, 16'h0000, 1'b1, 1'b1);
    read_sc(32'h0200, 16'h0000);
    if (r_hit !== 4'b1111)
        fail($sformatf("4 个 slot 应有 4 个 hit: %b", r_hit));

    // 第 5 个 branch: 同 set (0x600[9:4]=0x20), 不同 tag (slot0).
    // 训 5 次 taken, 应分配到 way0 (RR), 挤掉最早分配在 way0 的 0x204 slot1.
    train(32'h0600, 16'h0000, 1'b1, 1'b1);
    train(32'h0600, 16'h0000, 1'b1, 1'b1);
    train(32'h0600, 16'h0000, 1'b1, 1'b1);
    train(32'h0600, 16'h0000, 1'b1, 1'b1);
    train(32'h0600, 16'h0000, 1'b1, 1'b1);
    read_sc(32'h0600, 16'h0000);
    if (r_hit[0] !== 1'b1)
        fail($sformatf("0x600 slot0 应命中 (RR way0): hit=%b", r_hit[0]));
    read_sc(32'h0200, 16'h0000);
    if (r_hit[1] !== 1'b0)
        fail($sformatf("0x204 slot1 应被 RR 挤掉: hit=%b", r_hit[1]));
    if (r_hit[0] !== 1'b1)
        fail($sformatf("0x200 slot0 不应被挤掉: hit=%b", r_hit[0]));

    $display("");
    if (errs == 0) begin
        $display("[tb_ifu3_sc] PASS");
    end else begin
        $display("[tb_ifu3_sc] FAIL %0d errors", errs);
        $fatal(1);
    end
    $finish;
end

initial begin
    #500_000;
    $display("[tb_ifu3_sc] 致命: 超时");
    $fatal(1);
end

endmodule
