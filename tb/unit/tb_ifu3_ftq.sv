`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu3_ftq — FTQ 指针/队列参考模型对拍
//
// 覆盖: 随机 alloc/finish/同一拍 alloc+finish、override 重写+丢年轻项、
//       flush、inflight 读偏移、rd_valid/读数据、meta_id。
// override 当拍不驱动 alloc/finish (IFU/BPU 的外部口径)。
// ===========================================================================
module tb_ifu3_ftq;

localparam DEPTH = 16;

reg clk = 0; always #5 clk = ~clk;
reg rst;

reg         alloc_valid;
wire        alloc_ready;
reg  [31:0] alloc_start_pc;
reg         alloc_taken;
reg  [ 1:0] alloc_taken_slot;
reg  [31:0] alloc_target;
reg  [ 3:0] alloc_btb_cond;
reg  [15:0] alloc_phr;
reg  [ 5:0] alloc_meta_id;
reg  [63:0] alloc_meta_data;

reg  [ 2:0] inflight;
wire        rd_valid;
wire [31:0] rd_start_pc;
wire        rd_taken;
wire [ 1:0] rd_taken_slot;
wire [31:0] rd_target;
wire [ 3:0] rd_btb_cond;
wire [15:0] rd_phr;
wire [ 5:0] rd_meta_id;

reg         finish;
reg         flush;
reg         ovr_valid;
reg  [ 3:0] ovr_idx;
reg         ovr_taken;
reg  [ 1:0] ovr_taken_slot;
reg  [31:0] ovr_target;
reg  [ 3:0] ovr_btb_cond;
reg  [15:0] ovr_phr;

wire [ 3:0] alloc_idx;
wire [ 3:0] rd_ptr;
wire [ 3:0] head_idx;

rv32ifu3_ftq #(.DEPTH(DEPTH), .META_DEPTH(64), .META_W(64)) dut (
    .clk(clk), .rst(rst),
    .alloc_valid(alloc_valid), .alloc_ready(alloc_ready),
    .alloc_start_pc(alloc_start_pc), .alloc_taken(alloc_taken),
    .alloc_taken_slot(alloc_taken_slot), .alloc_target(alloc_target),
    .alloc_btb_cond(alloc_btb_cond), .alloc_phr(alloc_phr),
    .alloc_meta_id(alloc_meta_id), .alloc_meta_data(alloc_meta_data),
    .inflight(inflight),
    .rd_valid(rd_valid), .rd_start_pc(rd_start_pc), .rd_taken(rd_taken),
    .rd_taken_slot(rd_taken_slot), .rd_target(rd_target),
    .rd_btb_cond(rd_btb_cond), .rd_phr(rd_phr), .rd_meta_id(rd_meta_id),
    .finish(finish), .flush(flush),
    .ovr_valid(ovr_valid), .ovr_idx(ovr_idx), .ovr_taken(ovr_taken),
    .ovr_taken_slot(ovr_taken_slot), .ovr_target(ovr_target),
    .ovr_btb_cond(ovr_btb_cond), .ovr_phr(ovr_phr),
    .alloc_idx(alloc_idx), .rd_ptr(rd_ptr), .head_idx(head_idx)
);

// ---------------------------------------------------------------------------
// 参考模型
// ---------------------------------------------------------------------------
reg [31:0] r_start [0:DEPTH-1];
reg        r_taken [0:DEPTH-1];
reg [ 1:0] r_slot  [0:DEPTH-1];
reg [31:0] r_target[0:DEPTH-1];
reg [ 3:0] r_cond  [0:DEPTH-1];
reg [15:0] r_phr   [0:DEPTH-1];
reg [ 5:0] r_meta  [0:DEPTH-1];
integer r_head, r_count;
integer errs = 0;
integer seed;
integer k;

task automatic fail(input string msg);
    begin
        errs = errs + 1;
        if (errs <= 30) $display("[FTQ-TB] FAIL @%0t: %s", $time, msg);
    end
endtask

function automatic integer rand_mod(input integer n);
    integer v;
    begin
        v = $random(seed);
        if (v < 0) v = -v;
        rand_mod = v % n;
    end
endfunction

integer inf, rd_i, d_i, ai, alloc_i;
reg alloc_fire;
integer i;

initial begin
    seed = 32'hF7A0_1234;
    rst = 1; alloc_valid=0; alloc_start_pc=0; alloc_taken=0;
    alloc_taken_slot=0; alloc_target=0; alloc_btb_cond=0; alloc_phr=0;
    alloc_meta_id=0; alloc_meta_data=0; inflight=0; finish=0; flush=0;
    ovr_valid=0; ovr_idx=0; ovr_taken=0; ovr_taken_slot=0; ovr_target=0;
    ovr_btb_cond=0; ovr_phr=0;
    r_head = 0; r_count = 0;
    for (i=0;i<DEPTH;i=i+1) begin
        r_start[i]=0; r_taken[i]=0; r_slot[i]=0; r_target[i]=0;
        r_cond[i]=0; r_phr[i]=0; r_meta[i]=0;
    end

    repeat (3) @(posedge clk);
    #1 rst = 0;

    for (k = 0; k < 8000; k = k + 1) begin
        // 默认
        alloc_valid = 1'b0; finish = 1'b0; flush = 1'b0; ovr_valid = 1'b0;
        alloc_start_pc = $random(seed);
        alloc_taken = $random(seed);
        alloc_taken_slot = rand_mod(4);
        alloc_target = $random(seed);
        alloc_btb_cond = $random(seed);
        alloc_phr = $random(seed);
        alloc_meta_id = rand_mod(64);
        alloc_meta_data = {$random(seed), $random(seed)};

        if (rand_mod(100) < 2) begin
            flush = 1'b1;
        end else if ((r_count > 0) && (rand_mod(100) < 12)) begin
            // override 在队列内随机一项
            d_i = rand_mod(r_count);
            ovr_valid = 1'b1;
            ovr_idx = (r_head + d_i) & 4'hF;
            ovr_taken = $random(seed);
            ovr_taken_slot = rand_mod(4);
            ovr_target = $random(seed);
            ovr_btb_cond = $random(seed);
            ovr_phr = $random(seed);
        end else begin
            alloc_valid = (rand_mod(100) < 60);
            finish = (r_count > 0) && (rand_mod(100) < 35);
        end

        // inflight <= count
        if (r_count == 0) inf = 0;
        else inf = rand_mod(((r_count > 7) ? 7 : r_count) + 1);
        inflight = inf[2:0];

        #1;
        // ---- 组合输出/指针比对 ----
        alloc_fire = alloc_valid && alloc_ready;
        ai = (r_head + r_count) % DEPTH;
        if (alloc_idx !== ai[3:0])
            fail($sformatf("alloc_idx=%0d exp=%0d", alloc_idx, ai));
        if (head_idx !== (r_head[3:0]))
            fail($sformatf("head_idx=%0d exp=%0d", head_idx, r_head));
        rd_i = (r_head + inf) % DEPTH;
        if (rd_ptr !== (rd_i[3:0]))
            fail($sformatf("rd_ptr=%0d exp=%0d (head=%0d inf=%0d)", rd_ptr, rd_i, r_head, inf));
        if (rd_valid !== (r_count > inf))
            fail($sformatf("rd_valid=%b exp=%b (cnt=%0d inf=%0d)", rd_valid, r_count > inf, r_count, inf));
        if (r_count > inf) begin
            if (rd_start_pc !== r_start[rd_i]) fail($sformatf("rd_start_pc=%h exp=%h", rd_start_pc, r_start[rd_i]));
            if (rd_taken !== r_taken[rd_i]) fail($sformatf("rd_taken=%b exp=%b", rd_taken, r_taken[rd_i]));
            if (rd_taken_slot !== r_slot[rd_i]) fail($sformatf("rd_slot=%0d exp=%0d", rd_taken_slot, r_slot[rd_i]));
            if (rd_target !== r_target[rd_i]) fail($sformatf("rd_target=%h exp=%h", rd_target, r_target[rd_i]));
            if (rd_btb_cond !== r_cond[rd_i]) fail($sformatf("rd_cond=%b exp=%b", rd_btb_cond, r_cond[rd_i]));
            if (rd_phr !== r_phr[rd_i]) fail($sformatf("rd_phr=%h exp=%h", rd_phr, r_phr[rd_i]));
            if (rd_meta_id !== r_meta[rd_i]) fail($sformatf("rd_meta=%0d exp=%0d", rd_meta_id, r_meta[rd_i]));
        end

        @(posedge clk);
        #1;

        // ---- 参考状态更新 (与 FTQ 的 always 分支同口径) ----
        if (flush) begin
            r_head = 0;
            r_count = 0;
        end else if (ovr_valid) begin
            r_taken[ovr_idx]  = ovr_taken;
            r_slot[ovr_idx]   = ovr_taken_slot;
            r_target[ovr_idx] = ovr_target;
            r_cond[ovr_idx]   = ovr_btb_cond;
            r_phr[ovr_idx]    = ovr_phr;
            r_count = d_i + 1;
        end else begin
            if (alloc_fire) begin
                r_start[ai]  = alloc_start_pc;
                r_taken[ai]  = alloc_taken;
                r_slot[ai]   = alloc_taken_slot;
                r_target[ai] = alloc_target;
                r_cond[ai]   = alloc_btb_cond;
                r_phr[ai]    = alloc_phr;
                r_meta[ai]   = alloc_meta_id;
            end
            if (finish) begin
                r_head = (r_head + 1) % DEPTH;
            end
            // 同拍 alloc+finish: head+1, count 不变
            if (alloc_fire && !finish)      r_count = r_count + 1;
            else if (!alloc_fire && finish) r_count = r_count - 1;
        end

        // 后状态指针
        if (head_idx !== (r_head[3:0]))
            fail($sformatf("post head=%0d exp=%0d", head_idx, r_head));
        ai = (r_head + r_count) % DEPTH;
        if (alloc_idx !== (ai[3:0]))
            fail($sformatf("post alloc_idx=%0d exp=%0d", alloc_idx, ai));
    end

    $display("");
    if (errs == 0) begin
        $display("[tb_ifu3_ftq] PASS");
    end else begin
        $display("[tb_ifu3_ftq] FAIL %0d errors", errs);
        $fatal(1);
    end
    $finish;
end

initial begin
    #2_000_000;
    $display("[tb_ifu3_ftq] 致命: 超时");
    $fatal(1);
end

endmodule
