`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu3_ras — 快照式 RAS 的参考模型对拍
//
// 覆盖:
//   * 每块 0..4 条 push/pop/pop_push 的任意组合 (含同块 call+ret)
//   * 栈空/栈满时的动作退化 (eff_action)
//   * 每块快照: 随机的 IU redirect (恢复 + 回放 pc_ofs..lane) 和
//     BPU override (只恢复、不回放)
//   * 无效快照 / RTU clear
//   * 每个 lane 的 top/top_vld/ckpt/eff_action 组合输出
//
// 运行: ./simv +vcs+lic+wait -exitstatus
// ===========================================================================
module tb_ifu3_ras;

localparam DEPTH = 16;

reg clk = 1'b0;
always #5 clk = ~clk;

reg         rst;
reg         s1_valid;
reg  [ 1:0] s1_pc_ofs;
reg  [ 1:0] s1_end_slot;
reg         s1_fire;
reg  [ 3:0] s1_idx;
reg  [31:0] s1_start_pc;
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
reg         rec_replay;
reg  [ 2:0] rec_action;
reg  [31:0] rec_link;
reg         clr_valid;

rv32ifu3_ras #(
    .DEPTH (DEPTH)
) dut (
    .clk         (clk),
    .rst         (rst),
    .s1_valid    (s1_valid),
    .s1_pc_ofs   (s1_pc_ofs),
    .s1_end_slot (s1_end_slot),
    .s1_fire     (s1_fire),
    .s1_idx      (s1_idx),
    .s1_start_pc (s1_start_pc),
    .dec_action  (dec_action),
    .dec_link    (dec_link),
    .top_vld     (top_vld),
    .top         (top),
    .ckpt        (ckpt),
    .eff_action  (eff_action),
    .busy        (busy),
    .full        (full),
    .rec_valid   (rec_valid),
    .rec_ckpt    (rec_ckpt),
    .rec_replay  (rec_replay),
    .rec_action  (rec_action),
    .rec_link    (rec_link),
    .clr_valid   (clr_valid)
);

// ---------------------------------------------------------------------------
// 参考模型
// ---------------------------------------------------------------------------
reg [31:0] m_stk [0:DEPTH-1];
reg [4:0]  m_sp;

reg [DEPTH*32-1:0] s_stk [0:DEPTH-1];
reg [4:0]  s_sp   [0:DEPTH-1];
reg [7:0]  s_eff  [0:DEPTH-1];
reg [1:0]  s_ofs  [0:DEPTH-1];
reg [31:0] s_pc   [0:DEPTH-1];
reg        s_valid[0:DEPTH-1];

reg [3:0]  e_top_vld;
reg [127:0] e_top;
reg [23:0] e_ckpt;
reg [7:0]  e_eff;

reg [31:0] n_stk [0:DEPTH-1];
reg [4:0]  n_sp;

integer errs = 0;
integer nblocks = 0;
integer nrec = 0;
integer nclr = 0;
integer cur_idx = 0;

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

// 组合推演: 与 RTL 的并行前缀同语义
task automatic m_compute(input [7:0] acts, input [127:0] links,
                         input [1:0] pofs, input [1:0] endslot);
    reg [31:0] t_stk [0:DEPTH-1];
    reg [4:0]  t_sp;
    integer i;
    reg [1:0]  act;
    begin
        t_sp = m_sp;
        for (i = 0; i < DEPTH; i = i + 1)
            t_stk[i] = m_stk[i];

        e_top_vld = 4'd0;
        e_top     = 128'd0;
        e_ckpt    = 24'd0;
        e_eff     = 8'd0;

        for (i = 0; i < 4; i = i + 1) begin
            e_ckpt[i*6 +: 6] = {cur_idx[3:0], i[1:0]};
            e_top_vld[i]     = (t_sp != 0);
            e_top[i*32 +: 32] = (t_sp != 0) ? t_stk[t_sp - 1'b1] : 32'd0;

            act = acts[i*2 +: 2];
            if ((i >= pofs) && (i <= endslot)) begin
                case (act)
                    2'd1: begin
                        if (t_sp < DEPTH) begin
                            t_stk[t_sp] = links[i*32 +: 32];
                            t_sp = t_sp + 1'b1;
                            e_eff[i*2 +: 2] = 2'd1;
                        end
                    end
                    2'd2: begin
                        if (t_sp != 0) begin
                            t_sp = t_sp - 1'b1;
                            e_eff[i*2 +: 2] = 2'd2;
                        end
                    end
                    2'd3: begin
                        if (t_sp != 0) begin
                            t_sp = t_sp - 1'b1;
                            e_eff[i*2 +: 2] = 2'd2;
                        end
                        if (t_sp < DEPTH) begin
                            t_stk[t_sp] = links[i*32 +: 32];
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
    end
endtask

task automatic save_snap(input integer id, input [7:0] eff,
                         input [1:0] ofs, input [31:0] pc);
    integer i;
    begin
        for (i = 0; i < DEPTH; i = i + 1)
            s_stk[id][i*32 +: 32] = m_stk[i];
        s_sp[id]    = m_sp;
        s_eff[id]   = eff;
        s_ofs[id]   = ofs;
        s_pc[id]    = pc;
        s_valid[id] = 1'b1;
    end
endtask

task automatic restore_snap(input integer id);
    integer i;
    begin
        for (i = 0; i < DEPTH; i = i + 1)
            m_stk[i] = s_stk[id][i*32 +: 32];
        m_sp = s_sp[id];
    end
endtask

task automatic apply_action(input [2:0] act, input [31:0] link);
    begin
        case (act)
            3'd1: begin
                if (m_sp < DEPTH) begin
                    m_stk[m_sp] = link;
                    m_sp = m_sp + 1'b1;
                end
            end
            3'd2: begin
                if (m_sp != 0)
                    m_sp = m_sp - 1'b1;
            end
            3'd3: begin
                if (m_sp != 0)
                    m_stk[m_sp - 1'b1] = link;
                else begin
                    m_stk[0] = link;
                    m_sp = 5'd1;
                end
            end
            default: ;
        endcase
    end
endtask

task automatic compare_comb;
    integer i;
    begin
        if (busy) begin
            fail("busy 时仍在检查组合输出");
        end
        if (top_vld !== e_top_vld)
            fail($sformatf("top_vld=%b exp=%b", top_vld, e_top_vld));
        for (i = 0; i < 4; i = i + 1) begin
            if (top[i*32 +: 32] !== e_top[i*32 +: 32])
                fail($sformatf("top[%0d]=%h exp=%h", i, top[i*32 +: 32], e_top[i*32 +: 32]));
            if (ckpt[i*6 +: 6] !== e_ckpt[i*6 +: 6])
                fail($sformatf("ckpt[%0d]=%h exp=%h", i, ckpt[i*6 +: 6], e_ckpt[i*6 +: 6]));
            if (eff_action[i*2 +: 2] !== e_eff[i*2 +: 2])
                fail($sformatf("eff[%0d]=%0d exp=%0d", i, eff_action[i*2 +: 2], e_eff[i*2 +: 2]));
        end
    end
endtask

task automatic compare_state(input string tag);
    integer i;
    begin
        if (dut.sp_q !== m_sp)
            fail($sformatf("%s sp=%0d exp=%0d", tag, dut.sp_q, m_sp));
        for (i = 0; i < DEPTH; i = i + 1)
            if (dut.stk_q[i] !== m_stk[i])
                fail($sformatf("%s stk[%0d]=%h exp=%h", tag, i, dut.stk_q[i], m_stk[i]));
        for (i = 0; i < DEPTH; i = i + 1)
            if (dut.snap_valid_q[i] !== s_valid[i])
                fail($sformatf("%s snap_valid[%0d]=%b exp=%b", tag, i,
                               dut.snap_valid_q[i], s_valid[i]));
        if (full !== 1'b0)
            fail($sformatf("%s full=%b exp=0", tag, full));
    end
endtask

task automatic wait_idle;
    integer guard;
    begin
        guard = 0;
        while (busy && guard < 100) begin
            @(posedge clk); #1;
            guard = guard + 1;
        end
        if (busy) begin
            fail("busy 超时");
            $fatal;
        end
    end
endtask

task automatic do_block(input [7:0] acts, input [127:0] links,
                        input [1:0] pofs, input [1:0] endslot,
                        input [31:0] start_pc);
    integer i;
    begin
        wait_idle();
        dec_action  = acts;
        dec_link    = links;
        s1_pc_ofs   = pofs;
        s1_end_slot = endslot;
        s1_idx      = cur_idx[3:0];
        s1_start_pc = start_pc;
        s1_valid    = 1'b1;
        s1_fire     = 1'b1;

        m_compute(acts, links, pofs, endslot);
        #1;
        compare_comb();

        save_snap(cur_idx, e_eff, pofs, start_pc);

        @(posedge clk);
        #1;
        m_sp = n_sp;
        for (i = 0; i < DEPTH; i = i + 1)
            m_stk[i] = n_stk[i];
        s1_fire  = 1'b0;
        s1_valid = 1'b0;
        dec_action = 8'd0;
        nblocks = nblocks + 1;
        compare_state("block");
        cur_idx = (cur_idx + 1) % DEPTH;
    end
endtask

task automatic do_recover(input integer id, input [1:0] lane,
                          input replay, input [2:0] act, input [31:0] link);
    integer l;
    integer ofs;
    reg [31:0] lpc;
    begin
        wait_idle();
        restore_snap(id);
        if (replay) begin
            ofs = s_ofs[id];
            lpc = {s_pc[id][31:4], 4'b0};
            for (l = ofs; l < lane; l = l + 1)
                apply_action({1'b0, s_eff[id][l*2 +: 2]},
                             lpc + (l * 4) + 32'd4);
            apply_action(act, link);
        end

        rec_valid  = 1'b1;
        rec_ckpt   = {id[3:0], lane};
        rec_replay = replay;
        rec_action = act;
        rec_link   = link;
        @(posedge clk);
        #1;
        rec_valid = 1'b0;
        wait_idle();
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
integer pick, nvalid;
integer id;
integer lane;
integer ofs;
reg [31:0] start_pc;

initial begin
    seed = 32'h5EED_2026;
    void'($random(seed));

    rst = 1'b1;
    s1_valid = 0; s1_pc_ofs = 0; s1_end_slot = 0; s1_fire = 0;
    s1_idx = 0; s1_start_pc = 0;
    dec_action = 0; dec_link = 0;
    rec_valid = 0; rec_ckpt = 0; rec_replay = 0; rec_action = 0; rec_link = 0;
    clr_valid = 0;

    m_sp = 0;
    for (k = 0; k < DEPTH; k = k + 1) begin
        m_stk[k] = 32'd0;
        s_valid[k] = 1'b0;
        s_sp[k] = 0; s_eff[k] = 0; s_ofs[k] = 0; s_pc[k] = 0;
    end

    repeat (4) @(posedge clk);
    #1 rst = 1'b0;
    repeat (2) @(posedge clk);

    // ---- 定向 1: 同块 call + ret + pop_push + none ----
    acts = 8'b00_11_10_01;
    links = {32'h4444_4440, 32'h3333_3330, 32'h2222_2220, 32'h1111_1110};
    do_block(acts, links, 2'd0, 2'd3, 32'h1000);

    // ---- 定向 2: IU replay 到 slot2 ----
    do_recover(0, 2'd2, 1'b1, 3'd2, 32'hDEAD_0000);

    // ---- 定向 3: 空栈 pop / pop_push 退化 ----
    do_block(8'b00_00_00_10, 128'd0, 2'd0, 2'd3, 32'h1010);

    // ---- 定向 4: BPU override (只恢复, 不回放) ----
    do_recover(0, 2'd0, 1'b0, 3'd0, 32'd0);

    // ---- 定向 5: RTU clear ----
    clr_valid = 1'b1;
    @(posedge clk); #1;
    clr_valid = 1'b0;
    m_sp = 0;
    for (k = 0; k < DEPTH; k = k + 1)
        s_valid[k] = 1'b0;
    nclr = nclr + 1;
    compare_state("clr");

    // ---- 随机 ----
    for (k = 0; k < 3000; k = k + 1) begin
        // 随机 clear
        if (rand_mod(200) == 0) begin
            wait_idle();
            clr_valid = 1'b1;
            @(posedge clk); #1;
            clr_valid = 1'b0;
            m_sp = 0;
            for (r = 0; r < DEPTH; r = r + 1)
                s_valid[r] = 1'b0;
            nclr = nclr + 1;
            compare_state("rand-clr");
        end

        // 随机恢复 (有有效快照时)
        nvalid = 0;
        for (r = 0; r < DEPTH; r = r + 1)
            if (s_valid[r]) nvalid = nvalid + 1;

        if ((nvalid > 0) && (rand_mod(6) == 0)) begin
            id = rand_mod(DEPTH);
            while (!s_valid[id]) id = (id + 1) % DEPTH;

            ofs = s_ofs[id];
            lane = ofs + rand_mod(4 - ofs);
            if (lane > 3) lane = 3;

            if (rand_mod(2) == 0) begin
                // IU redirect: 回放 + 分支实际动作
                do_recover(id, lane[1:0], 1'b1, rand_mod(4), $random());
            end else begin
                // BPU override: 只恢复快照
                do_recover(id, lane[1:0], 1'b0, 3'd0, 32'd0);
            end
        end

        // 随机 block
        pofs = rand_mod(4);
        ends = pofs + rand_mod(4 - pofs);
        if (ends > 3) ends = 3;
        acts = 8'd0;
        for (r = 0; r < 4; r = r + 1) begin
            pick = rand_mod(10);
            if (pick < 4)       acts[r*2 +: 2] = 2'd0;
            else if (pick < 7)  acts[r*2 +: 2] = 2'd1;
            else if (pick < 9)  acts[r*2 +: 2] = 2'd2;
            else                acts[r*2 +: 2] = 2'd3;
        end
        for (r = 0; r < 4; r = r + 1)
            links[r*32 +: 32] = $random();
        start_pc = 32'h2000 + (cur_idx * 16);
        do_block(acts, links, pofs[1:0], ends[1:0], start_pc);
    end

    // ---- 无效快照恢复: 应清空推测栈 ----
    // 先用 clr 把 DUT 的 snap_valid 清掉, 再对一个不存在的快照发恢复。
    wait_idle();
    clr_valid = 1'b1;
    @(posedge clk); #1;
    clr_valid = 1'b0;
    for (r = 0; r < DEPTH; r = r + 1)
        s_valid[r] = 1'b0;
    m_sp = 0;
    rec_valid  = 1'b1;
    rec_ckpt   = 6'd0;
    rec_replay = 1'b1;
    rec_action = 3'd1;
    rec_link   = 32'h1234_5678;
    @(posedge clk); #1;
    rec_valid = 1'b0;
    wait_idle();
    compare_state("invalid-snap");

    // ---- 收尾 ----
    $display("");
    if (errs == 0) begin
        $display("[tb_ifu3_ras] PASS  blocks=%0d recover=%0d clr=%0d snap_valid=%b",
                 nblocks, nrec, nclr, dut.snap_valid_q);
    end else begin
        $display("[tb_ifu3_ras] FAIL  %0d errors (blocks=%0d recover=%0d clr=%0d)",
                 errs, nblocks, nrec, nclr);
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
