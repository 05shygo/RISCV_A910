`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu3_bpu — 白盒定向: BTB 训练/预测 + PHR 精确恢复/重启气泡/IFU override
//
// 关键断言:
//   * 0x104 的非对齐 JAL 预测 target 正确, early hash 用 line_pc+slot*4
//   * PHR 推进基底是 phr_q (连续两个 taken 都推进, 不是隔块)
//   * IU redirect 用 chk[15:0]+branch PC+实际 target 重算 hash
//   * redirect/ifu_override 后的重启气泡不覆盖恢复值
//   * IFU override 从 target 重启
// ===========================================================================
module tb_ifu3_bpu;

reg clk = 0; always #5 clk = ~clk;
reg rst;

reg         redirect;
reg         redirect_rtu;
reg  [31:0] redirect_pc;
reg  [24:0] iu_btb_chk;
reg  [31:0] iu_btb_pc;
reg         iu_btb_taken;
reg         iu_btb_is_cond;
reg         ifu_ovr_valid;
reg  [31:0] ifu_ovr_target;
reg  [15:0] ifu_ovr_phr;

reg         upd_vld;
reg  [31:0] upd_pc;
reg  [31:0] upd_target;
reg         upd_taken;
reg         upd_is_cond;
reg         upd_is_jal;
reg         upd_is_jalr;
reg  [24:0] upd_chk;

wire        alloc_valid;
reg         alloc_ready;
wire [31:0] alloc_start_pc;
wire        alloc_taken;
wire [ 1:0] alloc_taken_slot;
wire [31:0] alloc_target;
wire [ 3:0] alloc_btb_cond;
wire [15:0] alloc_phr;
wire [ 5:0] alloc_meta_id;
wire [63:0] alloc_meta_data;
reg  [ 3:0] ftq_alloc_idx;

wire        ovr_valid;
wire [ 3:0] ovr_idx;
wire        ovr_taken;
wire [ 1:0] ovr_taken_slot;
wire [31:0] ovr_target;
wire [ 3:0] ovr_btb_cond;
wire [15:0] ovr_phr;

rv32ifu3_bpu #(.BP_EN(1)) dut (
    .clk(clk), .rst(rst),
    .redirect(redirect), .redirect_rtu(redirect_rtu), .redirect_pc(redirect_pc),
    .iu_btb_chk(iu_btb_chk), .iu_btb_pc(iu_btb_pc),
    .iu_btb_taken(iu_btb_taken), .iu_btb_is_cond(iu_btb_is_cond),
    .ifu_ovr_valid(ifu_ovr_valid), .ifu_ovr_target(ifu_ovr_target), .ifu_ovr_phr(ifu_ovr_phr),
    .upd_vld(upd_vld), .upd_pc(upd_pc), .upd_target(upd_target),
    .upd_taken(upd_taken), .upd_is_cond(upd_is_cond),
    .upd_is_jal(upd_is_jal), .upd_is_jalr(upd_is_jalr), .upd_chk(upd_chk),
    .alloc_valid(alloc_valid), .alloc_ready(alloc_ready),
    .alloc_start_pc(alloc_start_pc), .alloc_taken(alloc_taken),
    .alloc_taken_slot(alloc_taken_slot), .alloc_target(alloc_target),
    .alloc_btb_cond(alloc_btb_cond), .alloc_phr(alloc_phr),
    .alloc_meta_id(alloc_meta_id), .alloc_meta_data(alloc_meta_data),
    .ftq_alloc_idx(ftq_alloc_idx),
    .ovr_valid(ovr_valid), .ovr_idx(ovr_idx), .ovr_taken(ovr_taken),
    .ovr_taken_slot(ovr_taken_slot), .ovr_target(ovr_target),
    .ovr_btb_cond(ovr_btb_cond), .ovr_phr(ovr_phr)
);

integer errs = 0;
integer ncyc;
reg got;
reg [31:0] g_target;
reg        g_taken;
reg [ 1:0] g_slot;
reg [15:0] g_phr;

task automatic fail(input string msg);
    begin
        errs = errs + 1;
        if (errs <= 30) $display("[BPU-TB] FAIL @%0t: %s", $time, msg);
    end
endtask

task automatic train(input [31:0] pc, input [31:0] tgt,
                     input is_jal, input is_cond);
    begin
        @(negedge clk);
        upd_vld = 1; upd_pc = pc; upd_target = tgt; upd_taken = 1;
        upd_is_cond = is_cond; upd_is_jal = is_jal; upd_is_jalr = 0;
        upd_chk = 25'd0;
        @(negedge clk);
        upd_vld = 0;
        repeat (2) @(negedge clk);
    end
endtask

task automatic do_redirect(input [31:0] pc, input rtu,
                           input [24:0] chk, input [31:0] bpc,
                           input taken, input is_cond);
    begin
        @(negedge clk);
        redirect = 1; redirect_rtu = rtu; redirect_pc = pc;
        iu_btb_chk = chk; iu_btb_pc = bpc;
        iu_btb_taken = taken; iu_btb_is_cond = is_cond;
        @(negedge clk);
        redirect = 0; iu_btb_chk = 0; iu_btb_taken = 0; iu_btb_is_cond = 0;
    end
endtask

task automatic wait_alloc(input [31:0] want, input integer maxc);
    integer n;
    begin
        got = 0;
        for (n = 0; n < maxc; n = n + 1) begin
            @(negedge clk);
            if (alloc_valid && alloc_ready && (alloc_start_pc == want)) begin
                g_target = alloc_target;
                g_taken  = alloc_taken;
                g_slot   = alloc_taken_slot;
                g_phr    = alloc_phr;
                got      = 1;
                @(posedge clk); #1;   // 吃掉这次 alloc, 并让 phr_q 更新落定
                n = maxc;
            end
        end
        if (!got) begin
            fail($sformatf("等不到 alloc pc=%h", want));
        end
    end
endtask

integer i;
initial begin
    rst = 1; redirect=0; redirect_rtu=0; redirect_pc=0;
    iu_btb_chk=0; iu_btb_pc=0; iu_btb_taken=0; iu_btb_is_cond=0;
    ifu_ovr_valid=0; ifu_ovr_target=0; ifu_ovr_phr=0;
    upd_vld=0; upd_pc=0; upd_target=0; upd_taken=0; upd_is_cond=0;
    upd_is_jal=0; upd_is_jalr=0; upd_chk=0;
    alloc_ready=1; ftq_alloc_idx=0;

    repeat (4) @(posedge clk);
    #1 rst = 0;
    repeat (2) @(posedge clk);

    // ---- 1) 未训练块: fall-through ----
    do_redirect(32'h1000, 1'b1, 25'd0, 32'h0, 1'b0, 1'b0);
    wait_alloc(32'h1000, 20);
    if (!got || g_taken || (g_target != 32'h1010))
        fail($sformatf("fall-through pc=%h taken=%b tgt=%h", 32'h1000, g_taken, g_target));

    // ---- 2) 两个连续 taken: PHR 必须两次都推进 (基底用 phr_q) ----
    train(32'h104, 32'h20E, 1'b1, 1'b0);   // 非对齐块 start=0x104
    train(32'h20E, 32'h30A, 1'b1, 1'b0);
    do_redirect(32'h104, 1'b1, 25'd0, 32'h0, 1'b0, 1'b0);
    wait_alloc(32'h104, 20);
    if (!got || !g_taken || (g_target != 32'h20E))
        fail($sformatf("jal1 pc=%h taken=%b tgt=%h", 32'h104, g_taken, g_target));
    if (g_phr !== 16'h0000)
        fail($sformatf("jal1 alloc_phr=%h exp=0000 (块首快照)", g_phr));
    if (dut.phr_q !== 16'h0002)
        fail($sformatf("jal1 phr_q=%h exp=0002 (非对齐 hash)", dut.phr_q));

    wait_alloc(32'h20E, 20);
    if (!got || !g_taken || (g_target != 32'h30A))
        fail($sformatf("jal2 pc=%h taken=%b tgt=%h", 32'h20E, g_taken, g_target));
    // 一拍滞后口径: 0x20E 的 TAGE 读发生在 0x104 推进之前, 所以它的
    // alloc_phr 仍是 0; 0x30A 才看到 2。
    if (g_phr !== 16'h0000)
        fail($sformatf("jal2 alloc_phr=%h exp=0000 (lag)", g_phr));
    if (dut.phr_q !== 16'h0009)
        fail($sformatf("jal2 phr_q=%h exp=0009 (两次推进)", dut.phr_q));

    wait_alloc(32'h30A, 20);
    if (!got || g_taken || (g_target != 32'h310))
        fail($sformatf("jal3 pc=%h taken=%b tgt=%h (非对齐 fall-through=line+16)", 32'h30A, g_taken, g_target));
    if (g_phr !== 16'h0002)
        fail($sformatf("jal3 alloc_phr=%h exp=0002 (lag)", g_phr));

    // ---- 3) IU redirect 精确 PHR: 条件 taken ----
    // chk=0xA55A, branch pc=0x1004 ([3:2]=1,[7:6]=0), target=0x300([3:2]=0)
    // -> hash=1, phr={0x255A,1}=0x9569
    do_redirect(32'h300, 1'b0, 25'h00A55A, 32'h1004, 1'b1, 1'b1);
    if (dut.phr_q !== 16'h9569)
        fail($sformatf("IU redirect phr=%h exp=9569", dut.phr_q));
    repeat (3) @(posedge clk);
    if (dut.phr_q !== 16'h9569)
        fail($sformatf("IU redirect 气泡后 phr=%h exp=9569", dut.phr_q));

    // ---- 4) IU redirect 条件 not-taken: 不推进 ----
    do_redirect(32'h600, 1'b0, 25'h001234, 32'h1010, 1'b0, 1'b1);
    if (dut.phr_q !== 16'h1234)
        fail($sformatf("not-taken phr=%h exp=1234", dut.phr_q));

    // ---- 5) IFU override: 从 target 重启 + PHR 保持 ----
    @(negedge clk);
    ifu_ovr_valid = 1; ifu_ovr_target = 32'h400; ifu_ovr_phr = 16'h1234;
    @(negedge clk);
    ifu_ovr_valid = 0;
    if (dut.phr_q !== 16'h1234)
        fail($sformatf("ifu_ovr phr=%h exp=1234", dut.phr_q));
    if (dut.bp_hold_pc !== 32'h400)
        fail($sformatf("ifu_ovr hold_pc=%h exp=400", dut.bp_hold_pc));
    repeat (2) @(posedge clk);
    if (dut.phr_q !== 16'h1234)
        fail($sformatf("ifu_ovr 气泡后 phr=%h exp=1234", dut.phr_q));
    if (dut.bp_rd_pc_q !== 32'h400)
        fail($sformatf("ifu_ovr 后重启 PC=%h exp=400", dut.bp_rd_pc_q));

    // ---- 6) RTU redirect 清 PHR ----
    do_redirect(32'h500, 1'b1, 25'd0, 32'h0, 1'b0, 1'b0);
    if (dut.phr_q !== 16'h0000)
        fail($sformatf("RTU redirect phr=%h exp=0", dut.phr_q));

    $display("");
    if (errs == 0) begin
        $display("[tb_ifu3_bpu] PASS");
    end else begin
        $display("[tb_ifu3_bpu] FAIL %0d errors", errs);
        $fatal(1);
    end
    $finish;
end

// 每拍推进 ftq_alloc_idx / 观察 alloc (不参与判据)
always @(posedge clk) begin
    if (alloc_valid && alloc_ready)
        ftq_alloc_idx <= ftq_alloc_idx + 4'd1;
end

initial begin
    #1_000_000;
    $display("[tb_ifu3_bpu] 致命: 超时");
    $fatal(1);
end

endmodule
