`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu3_ras — rv32ifu3_ras 的参考模型对拍
//
// 覆盖:
//   * 每块 0..4 条 push/pop/pop_push 的任意组合 (含同块 call+ret)
//   * 栈空/栈满时的动作退化 (eff_action)
//   * 随机 checkpoint 的 undo log 回滚 + 重放实际动作
//   * 退休 commit 指针推进、live window/full
//   * 每个 lane 的 top/top_vld/ckpt/eff_action 组合输出
//
// 运行: ./simv +vcs+lic+wait -exitstatus
// ===========================================================================
module tb_ifu3_ras;

localparam DEPTH = 16;
localparam LOG_DEPTH = 64;
localparam CW = 6;

reg clk = 1'b0;
always #5 clk = ~clk;

reg         rst;
reg         s1_valid;
reg  [ 1:0] s1_pc_ofs;
reg  [ 1:0] s1_end_slot;
reg         s1_fire;
reg  [ 7:0] dec_action;
reg  [127:0] dec_link;

wire [  3:0] top_vld;
wire [127:0] top;
wire [ 23:0] ckpt;
wire [  7:0] eff_action;
wire         busy;
wire         full;

reg         rec_valid;
reg  [ 5:0] rec_ckpt;
reg  [ 2:0] rec_action;
reg  [31:0] rec_link;
reg         clr_valid;
reg         cmt_valid;
reg  [ 2:0] cmt_action;
reg  [ 5:0] cmt_ckpt;

rv32ifu3_ras #(
    .DEPTH     (DEPTH),
    .LOG_DEPTH (LOG_DEPTH)
) dut (
    .clk        (clk),
    .rst        (rst),
    .s1_valid   (s1_valid),
    .s1_pc_ofs  (s1_pc_ofs),
    .s1_end_slot(s1_end_slot),
    .s1_fire    (s1_fire),
    .dec_action (dec_action),
    .dec_link   (dec_link),
    .top_vld    (top_vld),
    .top        (top),
    .ckpt       (ckpt),
    .eff_action (eff_action),
    .busy       (busy),
    .full       (full),
    .rec_valid  (rec_valid),
    .rec_ckpt   (rec_ckpt),
    .rec_action (rec_action),
    .rec_link   (rec_link),
    .clr_valid  (clr_valid),
    .cmt_valid  (cmt_valid),
    .cmt_action (cmt_action),
    .cmt_ckpt   (cmt_ckpt)
);

// ---------------------------------------------------------------------------
// 参考模型
// ---------------------------------------------------------------------------
reg [31:0] m_stk [0:DEPTH-1];
reg [4:0]  m_sp;
reg [5:0]  m_wr, m_cmt;
reg        m_op   [0:LOG_DEPTH-1];
reg [31:0] m_data [0:LOG_DEPTH-1];

reg [3:0]  e_top_vld;
reg [127:0] e_top;
reg [23:0] e_ckpt;
reg [7:0]  e_eff;

reg [31:0] n_stk [0:DEPTH-1];
reg [4:0]  n_sp;
reg [5:0]  n_wr;

integer errs = 0;
integer nblocks = 0;
integer nrec = 0;
integer ncmt = 0;

task automatic fail(input string msg);
    begin
        errs = errs + 1;
        if (errs <= 40)
            $display("[RAS-TB] FAIL @%0t: %s", $time, msg);
    end
endtask

function automatic integer rand_mod(input integer n);
    integer v;
    begin
        v = $random();
        if (v < 0) v = -v;
        rand_mod = v % n;
    end
endfunction

// 组合推演: 与 RTL 的 always @* 同口径
task automatic m_compute(input [7:0] acts, input [127:0] links,
                         input [1:0] pofs, input [1:0] endslot);
    reg [31:0] t_stk [0:DEPTH-1];
    reg [4:0]  t_sp;
    reg [5:0]  t_wr;
    reg [3:0]  nlog;
    integer i;
    reg [2:0] act;
    begin
        t_sp = m_sp;
        t_wr = m_wr;
        for (i = 0; i < DEPTH; i = i + 1)
            t_stk[i] = m_stk[i];
        nlog = 0;

        e_top_vld = 4'd0;
        e_top     = 128'd0;
        e_ckpt    = 24'd0;
        e_eff     = 8'd0;

        for (i = 0; i < 4; i = i + 1) begin
            e_ckpt[i*6 +: 6] = t_wr;
            e_top_vld[i]     = (t_sp != 0);
            e_top[i*32 +: 32] = (t_sp != 0) ? t_stk[t_sp - 1] : 32'd0;
            act = acts[i*2 +: 2];
            if ((i >= pofs) && (i <= endslot)) begin
                case (act)
                    2'd1: begin
                        if (t_sp < DEPTH) begin
                            t_stk[t_sp] = links[i*32 +: 32];
                            m_op[t_wr]   = 1'b1;
                            m_data[t_wr] = links[i*32 +: 32];
                            t_wr = t_wr + 1'b1;
                            t_sp = t_sp + 1'b1;
                            e_eff[i*2 +: 2] = 2'd1;
                        end
                    end
                    2'd2: begin
                        if (t_sp != 0) begin
                            m_op[t_wr]   = 1'b0;
                            m_data[t_wr] = t_stk[t_sp - 1];
                            t_wr = t_wr + 1'b1;
                            t_sp = t_sp - 1'b1;
                            e_eff[i*2 +: 2] = 2'd2;
                        end
                    end
                    2'd3: begin
                        if (t_sp != 0) begin
                            m_op[t_wr]   = 1'b0;
                            m_data[t_wr] = t_stk[t_sp - 1];
                            t_wr = t_wr + 1'b1;
                            t_sp = t_sp - 1'b1;
                            e_eff[i*2 +: 2] = 2'd2;
                        end
                        if (t_sp < DEPTH) begin
                            t_stk[t_sp] = links[i*32 +: 32];
                            m_op[t_wr]   = 1'b1;
                            m_data[t_wr] = links[i*32 +: 32];
                            t_wr = t_wr + 1'b1;
                            t_sp = t_sp + 1'b1;
                            e_eff[i*2 +: 2] = (e_eff[i*2 +: 2] == 2'd2) ? 2'd3 : 2'd1;
                        end
                    end
                    default: ;
                endcase
            end
        end

        for (i = 0; i < DEPTH; i = i + 1)
            n_stk[i] = t_stk[i];
        n_sp = t_sp;
        n_wr = t_wr;
    end
endtask

task automatic m_apply;
    integer i;
    begin
        m_sp = n_sp;
        m_wr = n_wr;
        for (i = 0; i < DEPTH; i = i + 1)
            m_stk[i] = n_stk[i];
    end
endtask

// 参考模型: 应用一条恢复动作
task automatic m_replay(input [2:0] act, input [31:0] link);
    begin
        case (act)
            3'd1: begin
                if (m_sp < DEPTH) begin
                    m_stk[m_sp] = link;
                    m_op[m_wr]  = 1'b1;
                    m_data[m_wr]= link;
                    m_sp = m_sp + 1'b1;
                    m_wr = m_wr + 1'b1;
                end
            end
            3'd2: begin
                if (m_sp != 0) begin
                    m_op[m_wr]   = 1'b0;
                    m_data[m_wr] = m_stk[m_sp - 1'b1];
                    m_sp = m_sp - 1'b1;
                    m_wr = m_wr + 1'b1;
                end
            end
            3'd3: begin
                if (m_sp != 0) begin
                    m_op[m_wr]   = 1'b0;
                    m_data[m_wr] = m_stk[m_sp - 1'b1];
                    m_op[m_wr+1]   = 1'b1;
                    m_data[m_wr+1] = link;
                    m_stk[m_sp - 1'b1] = link;
                    m_wr = m_wr + 2'd2;
                end else begin
                    m_op[m_wr]   = 1'b1;
                    m_data[m_wr] = link;
                    m_stk[0]     = link;
                    m_sp = 5'd1;
                    m_wr = m_wr + 1'b1;
                end
            end
            default: ;
        endcase
    end
endtask

task automatic compare_comb;
    reg [3:0]   x_vld;
    reg [127:0] x_top;
    reg [23:0]  x_ckpt;
    reg [7:0]   x_eff;
    integer i;
    begin
        x_vld  = top_vld;
        x_top  = top;
        x_ckpt = ckpt;
        x_eff  = eff_action;
        if (x_vld !== e_top_vld) begin
            fail($sformatf("top_vld=%b exp=%b", x_vld, e_top_vld));
        end
        for (i = 0; i < 4; i = i + 1) begin
            if (x_top[i*32 +: 32] !== e_top[i*32 +: 32])
                fail($sformatf("top[%0d]=%h exp=%h", i, x_top[i*32 +: 32], e_top[i*32 +: 32]));
            if (x_ckpt[i*6 +: 6] !== e_ckpt[i*6 +: 6])
                fail($sformatf("ckpt[%0d]=%0d exp=%0d", i, x_ckpt[i*6 +: 6], e_ckpt[i*6 +: 6]));
            if (x_eff[i*2 +: 2] !== e_eff[i*2 +: 2])
                fail($sformatf("eff[%0d]=%0d exp=%0d", i, x_eff[i*2 +: 2], e_eff[i*2 +: 2]));
        end
    end
endtask

task automatic compare_state(input string tag);
    integer i;
    begin
        if (dut.sp_q !== m_sp)
            fail($sformatf("%s sp=%0d exp=%0d", tag, dut.sp_q, m_sp));
        if (dut.wr_q !== m_wr)
            fail($sformatf("%s wr=%0d exp=%0d", tag, dut.wr_q, m_wr));
        if (dut.cmt_q !== m_cmt)
            fail($sformatf("%s cmt=%0d exp=%0d", tag, dut.cmt_q, m_cmt));
        for (i = 0; i < DEPTH; i = i + 1) begin
            if (dut.stk_q[i] !== m_stk[i])
                fail($sformatf("%s stk[%0d]=%h exp=%h", tag, i, dut.stk_q[i], m_stk[i]));
        end
    end
endtask

// 记录一个 block 内每条 lane 的 checkpoint/action (用于随机恢复)
reg [5:0]  hist_ckpt [0:8191];
reg [2:0]  hist_act  [0:8191];
integer    hist_n = 0;

task automatic do_block(input [7:0] acts, input [127:0] links,
                        input [1:0] pofs, input [1:0] endslot);
    integer i;
    integer inc;
    integer occ;
    begin
        // 等 RAS 不忙
        while (busy) @(posedge clk);
        // log 满时先退休一些动作腾空间
        while (full) begin
            occ = (m_wr - m_cmt + 64) % 64;
            if (occ == 0) begin
                fail("full 但 occupancy=0");
                $fatal;
            end
            inc = (occ >= 2) ? 2 : 1;
            cmt_valid  = 1'b1;
            cmt_action = (inc == 2) ? 3'd3 : 3'd1;
            cmt_ckpt   = m_cmt;
            m_cmt = m_cmt + inc;
            @(posedge clk);
            #1;
            cmt_valid = 1'b0;
            if (dut.cmt_q !== m_cmt)
                fail($sformatf("full-drain cmt=%0d exp=%0d", dut.cmt_q, m_cmt));
            ncmt = ncmt + 1;
        end

        dec_action  = acts;
        dec_link    = links;
        s1_pc_ofs   = pofs;
        s1_end_slot = endslot;
        s1_valid    = 1'b1;
        s1_fire     = 1'b1;

        m_compute(acts, links, pofs, endslot);
        #1;
        compare_comb();

        // 记录本块真正生效的 lane checkpoint/action
        for (i = 0; i < 4; i = i + 1) begin
            if ((i >= pofs) && (i <= endslot)) begin
                hist_ckpt[hist_n % 8192] = e_ckpt[i*6 +: 6];
                hist_act [hist_n % 8192] = e_eff[i*2 +: 2];
                hist_n = hist_n + 1;
            end
        end

        @(posedge clk);
        #1;
        m_apply();
        s1_fire  = 1'b0;
        s1_valid = 1'b0;
        dec_action = 8'd0;
        nblocks = nblocks + 1;
        compare_state("block");
    end
endtask

task automatic do_commit(input integer inc);
    integer occ;
    begin
        occ = (m_wr - m_cmt + 64) % 64;
        if (occ < inc) begin
            fail($sformatf("commit inc=%0d occ=%0d", inc, occ));
            return;
        end
        cmt_valid  = 1'b1;
        cmt_action = (inc == 0) ? 3'd0 : (inc == 1) ? 3'd1 : 3'd3;
        cmt_ckpt   = m_cmt;
        m_cmt = m_cmt + inc;
        @(posedge clk);
        #1;
        cmt_valid = 1'b0;
        compare_state("commit");
        ncmt = ncmt + 1;
    end
endtask

task automatic do_recover(input [5:0] target, input [2:0] act, input [31:0] link);
    integer i;
    integer guard;
    begin
        // 参考模型: 逆序撤销到 target, 再重放
        while (m_wr != target) begin
            m_wr = m_wr - 1'b1;
            if (m_op[m_wr]) begin
                m_sp = m_sp - 1'b1;
            end else begin
                m_stk[m_sp] = m_data[m_wr];
                m_sp = m_sp + 1'b1;
            end
        end
        m_replay(act, link);

        rec_valid  = 1'b1;
        rec_ckpt   = target;
        rec_action = act;
        rec_link   = link;
        @(posedge clk);
        #1;
        rec_valid = 1'b0;
        guard = 0;
        while (busy && guard < 200) begin
            @(posedge clk);
            #1;
            guard = guard + 1;
        end
        if (busy) begin
            fail("rollback busy 超时");
            $fatal;
        end
        compare_state("recover");
        nrec = nrec + 1;
    end
endtask

// ---------------------------------------------------------------------------
// 主程序
// ---------------------------------------------------------------------------
integer seed;
integer k, r;
integer pofs, ends;
reg [7:0]   acts;
reg [127:0] links;
integer pick, ddist, occ;
integer inc;
integer hist_pick;

initial begin
    seed = 32'h5EED_1234;
    void'($random(seed));

    rst = 1'b1;
    s1_valid = 0; s1_pc_ofs = 0; s1_end_slot = 0; s1_fire = 0;
    dec_action = 0; dec_link = 0;
    rec_valid = 0; rec_ckpt = 0; rec_action = 0; rec_link = 0;
    clr_valid = 0; cmt_valid = 0; cmt_action = 0; cmt_ckpt = 0;

    m_sp = 0; m_wr = 0; m_cmt = 0;
    for (k = 0; k < DEPTH; k = k + 1) m_stk[k] = 32'd0;
    for (k = 0; k < LOG_DEPTH; k = k + 1) begin
        m_op[k] = 1'b0; m_data[k] = 32'd0;
    end

    repeat (4) @(posedge clk);
    #1 rst = 1'b0;
    repeat (2) @(posedge clk);

    // ---- 定向 1: 同块 call + ret + pop_push + none ----
    acts = 8'b00_11_10_01;   // slot0=push, slot1=pop, slot2=pop_push, slot3=none
    links = {32'h4444_4440, 32'h3333_3330, 32'h2222_2220, 32'h1111_1110};
    do_block(acts, links, 2'd0, 2'd3);

    // ---- 定向 2: 回滚到 slot2 的 checkpoint 并重放 pop ----
    // hist[2] 是 slot2 动作前的 checkpoint
    do_recover(hist_ckpt[2], 3'd2, 32'hDEAD_0000);

    // ---- 定向 3: 空栈 pop / pop_push 退化 ----
    do_block(8'b00_00_00_10, 128'd0, 2'd0, 2'd3);

    // ---- 定向 4: commit 推进 ----
    do_commit(1);

    // ---- 定向 5: RTU 式 clear ----
    clr_valid = 1'b1;
    @(posedge clk); #1;
    clr_valid = 1'b0;
    m_sp = 0; m_wr = 0; m_cmt = 0;
    hist_n = 0;
    if (busy) fail("clr 后 busy 仍为 1");
    compare_state("clr");

    // ---- 随机 ----
    for (k = 0; k < 3000; k = k + 1) begin
        // 随机 commit
        if (rand_mod(5) == 0) begin
            occ = (m_wr - m_cmt + 64) % 64;
            inc = rand_mod(3);
            if (inc > occ) inc = occ;
            do_commit(inc);
        end

        // 随机恢复
        if ((hist_n > 8) && (rand_mod(7) == 0)) begin
            // 选一个在 live window 内的 checkpoint
            pick = -1;
            for (r = 0; r < 32; r = r + 1) begin
                hist_pick = rand_mod(hist_n);
                hist_pick = hist_pick % 8192;
                ddist = (m_wr - hist_ckpt[hist_pick] + 64) % 64;
                occ   = (m_wr - m_cmt + 64) % 64;
                if ((ddist <= occ) && (hist_act[hist_pick] != 2'd0)) begin
                    pick = hist_pick;
                    r = 32;
                end
            end
            if (pick >= 0) begin
                r = rand_mod(4);
                do_recover(hist_ckpt[pick], r[2:0], $random());
            end
        end

        // 随机 block
        pofs = rand_mod(4);
        ends = pofs + rand_mod(4 - pofs);
        if (ends > 3) ends = 3;
        acts = 8'd0;
        for (r = 0; r < 4; r = r + 1) begin
            pick = rand_mod(10);
            // 40% none, 30% push, 25% pop, 5% pop_push
            if (pick < 4)       acts[r*2 +: 2] = 2'd0;
            else if (pick < 7)  acts[r*2 +: 2] = 2'd1;
            else if (pick < 9)  acts[r*2 +: 2] = 2'd2;
            else                acts[r*2 +: 2] = 2'd3;
        end
        for (r = 0; r < 4; r = r + 1)
            links[r*32 +: 32] = $random();
        do_block(acts, links, pofs[1:0], ends[1:0]);
    end

    // ---- 收尾 ----
    $display("");
    if (errs == 0) begin
        $display("[tb_ifu3_ras] PASS  blocks=%0d recover=%0d commit=%0d hist=%0d",
                 nblocks, nrec, ncmt, hist_n);
    end else begin
        $display("[tb_ifu3_ras] FAIL  %0d errors (blocks=%0d recover=%0d commit=%0d)",
                 errs, nblocks, nrec, ncmt);
        $fatal(1);
    end
    $finish;
end

// 看门狗
initial begin
    #20_000_000;
    $display("[tb_ifu3_ras] 致命: 超时");
    $fatal(1);
end

endmodule
