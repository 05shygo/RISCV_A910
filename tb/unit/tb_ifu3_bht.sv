`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu3_bht — 定向: BHT 读写索引一致 / 2-bit 饱和 / strong / slot 独立
//
// 关注点不是"gshare 准不准", 而是 BPU 里最容易错的三件事:
//   * 读和写用同一个 pc+fold(PHR) 公式 (写错窗口会让训练永远打不中)
//   * 2-bit 计数器复位为 01 (弱 not-taken), 00/11 才是 strong
//   * upd_is_cond=0 / upd_vld=0 不能改表
// ===========================================================================
module tb_ifu3_bht;

reg clk = 0; always #5 clk = ~clk;
reg rst;

reg  [31:0] rd_line_pc;
reg  [15:0] rd_phr;
wire [ 3:0] dir;
wire [ 3:0] strong_v;

reg         upd_vld;
reg  [31:0] upd_pc;
reg         upd_taken;
reg         upd_is_cond;
reg  [15:0] upd_phr;

rv32ifu3_bht #(.L1(5'd10)) dut (
    .clk         (clk),
    .rst         (rst),
    .rd_line_pc  (rd_line_pc),
    .rd_phr      (rd_phr),
    .dir         (dir),
    .strong_v    (strong_v),
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
        if (errs <= 20) $display("[BHT-TB] FAIL @%0t: %s", $time, msg);
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
        // 让写口在中间那个 posedge 落盘, 再读
        @(posedge clk); #1;
    end
endtask

reg [3:0] d, s;

task automatic read_bht(input [31:0] line_pc, input [15:0] phr);
    begin
        @(negedge clk);
        rd_line_pc = line_pc;
        rd_phr     = phr;
        @(posedge clk); #1;
        d = dir;
        s = strong_v;
    end
endtask

initial begin
    rst = 1'b1;
    rd_line_pc = 32'd0;
    rd_phr     = 16'd0;
    upd_vld    = 1'b0;
    upd_pc     = 32'd0;
    upd_taken  = 1'b0;
    upd_is_cond= 1'b0;
    upd_phr    = 16'd0;

    repeat (4) @(posedge clk);
    #1 rst = 1'b0;
    repeat (2) @(posedge clk);

    // ---- 1) 初始 2-bit 计数器 = 01: not taken, 但弱 ----
    read_bht(32'h0200, 16'h0000);
    if (d !== 4'b0000) fail($sformatf("初始 dir=%b exp=0000", d));
    if (s !== 4'b0000) fail($sformatf("初始 strong=%b exp=0000", s));

    // ---- 2) 一次 taken -> 10: dir=1, strong=0 ----
    train(32'h0204, 16'h0000, 1'b1, 1'b1);
    read_bht(32'h0200, 16'h0000);
    if (d[1] !== 1'b1) fail($sformatf("一次 taken 后 dir[1]=%b exp=1", d[1]));
    if (s[1] !== 1'b0) fail($sformatf("一次 taken 后 strong[1]=%b exp=0", s[1]));

    // ---- 3) 二次 taken -> 11: dir=1, strong=1 ----
    train(32'h0204, 16'h0000, 1'b1, 1'b1);
    read_bht(32'h0200, 16'h0000);
    if (d[1] !== 1'b1) fail($sformatf("二次 taken 后 dir[1]=%b exp=1", d[1]));
    if (s[1] !== 1'b1) fail($sformatf("二次 taken 后 strong[1]=%b exp=1", s[1]));

    // ---- 4) 同一 pc / 不同 PHR 读不同行 (读写索引一致性) ----
    read_bht(32'h0200, 16'h0001);
    if (d[1] !== 1'b0) fail($sformatf("PHR=1 读到 dir[1]=%b exp=0", d[1]));
    if (s[1] !== 1'b0) fail($sformatf("PHR=1 读到 strong[1]=%b exp=0", s[1]));

    // ---- 5) not-taken 递减 11 -> 10 -> 01 -> 00 ----
    train(32'h0204, 16'h0000, 1'b0, 1'b1);   // 10
    read_bht(32'h0200, 16'h0000);
    if (d[1] !== 1'b1) fail($sformatf("not-taken#1 dir[1]=%b exp=1", d[1]));
    if (s[1] !== 1'b0) fail($sformatf("not-taken#1 strong[1]=%b exp=0", s[1]));
    train(32'h0204, 16'h0000, 1'b0, 1'b1);   // 01
    read_bht(32'h0200, 16'h0000);
    if (d[1] !== 1'b0) fail($sformatf("not-taken#2 dir[1]=%b exp=0", d[1]));
    if (s[1] !== 1'b0) fail($sformatf("not-taken#2 strong[1]=%b exp=0", s[1]));
    train(32'h0204, 16'h0000, 1'b0, 1'b1);   // 00
    read_bht(32'h0200, 16'h0000);
    if (d[1] !== 1'b0) fail($sformatf("not-taken#3 dir[1]=%b exp=0", d[1]));
    if (s[1] !== 1'b1) fail($sformatf("not-taken#3 strong[1]=%b exp=1", s[1]));

    // ---- 6) slot 独立: slot2 训练不影响 slot1 ----
    train(32'h0208, 16'h0000, 1'b1, 1'b1);
    train(32'h0208, 16'h0000, 1'b1, 1'b1);
    read_bht(32'h0200, 16'h0000);
    if (d[1] !== 1'b0) fail($sformatf("slot2 污染 slot1: dir[1]=%b exp=0", d[1]));
    if (s[1] !== 1'b1) fail($sformatf("slot1 strong=%b exp=1", s[1]));
    if (d[2] !== 1'b1) fail($sformatf("slot2 dir[2]=%b exp=1", d[2]));
    if (s[2] !== 1'b1) fail($sformatf("slot2 strong[2]=%b exp=1", s[2]));

    // ---- 7) 非条件分支不训练: slot3 保持初始 01 ----
    train(32'h020C, 16'h0000, 1'b1, 1'b0);
    train(32'h020C, 16'h0000, 1'b1, 1'b0);
    read_bht(32'h0200, 16'h0000);
    if (d[3] !== 1'b0) fail($sformatf("非条件训练了 slot3: dir[3]=%b exp=0", d[3]));
    if (s[3] !== 1'b0) fail($sformatf("非条件训练了 slot3: strong[3]=%b exp=0", s[3]));

    // ---- 8) upd_vld=0 不训练 ----
    train(32'h0200, 16'h0000, 1'b1, 1'b1);
    train(32'h0200, 16'h0000, 1'b1, 1'b1);
    read_bht(32'h0200, 16'h0000);
    if (d[0] !== 1'b1) fail($sformatf("slot0 预训练 dir[0]=%b exp=1", d[0]));
    if (s[0] !== 1'b1) fail($sformatf("slot0 预训练 strong[0]=%b exp=1", s[0]));
    @(negedge clk);
    upd_vld = 1'b0; upd_pc = 32'h0200; upd_phr = 16'h0000;
    upd_taken = 1'b0; upd_is_cond = 1'b1;
    @(negedge clk);
    read_bht(32'h0200, 16'h0000);
    if (d[0] !== 1'b1) fail($sformatf("upd_vld=0 改了 slot0: dir[0]=%b exp=1", d[0]));
    if (s[0] !== 1'b1) fail($sformatf("upd_vld=0 改了 slot0: strong[0]=%b exp=1", s[0]));

    $display("");
    if (errs == 0) begin
        $display("[tb_ifu3_bht] PASS");
    end else begin
        $display("[tb_ifu3_bht] FAIL %0d errors", errs);
        $fatal(1);
    end
    $finish;
end

initial begin
    #200_000;
    $display("[tb_ifu3_bht] 致命: 超时");
    $fatal(1);
end

endmodule
