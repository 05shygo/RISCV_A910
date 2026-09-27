`timescale 1ns / 1ps
`include "defines.vh"

// ===========================================================================
// tb_muldiv_unit — 乘除法单元的单元级自检 TB (doc 附录 B 的口径)
//
// 直接驱动 MUL_DIV, 不经整核。为什么要有这一层:
//   * 整核 difftest 只能告诉你"某条指令结果不对", 定位不到是 Booth 阵列、压缩树
//     还是除法迭代数算错;
//   * 队列/冲刷这类时序性质 (II=1、被冲刷的乘法绝不写回) 在整核里很难构造,
//     在这里一个 task 就能直接断言。
//
// 激励协议与核内一致 (mycpu.v 的接法):
//   * 乘法: req_valid 拉 1 拍 (mul_ready 恒 1), 结果 2 拍后出来;
//   * 除法: req_valid **保持**到 resp_valid, 核用 div_stall 顶住 EX 来做到这一点。
// ===========================================================================
module tb_muldiv_unit;

localparam TAG_W = 7;

logic clk = 0;
logic rst = 1;
always #5 clk = ~clk;

// ---- 请求口 ----
logic          req_valid;
logic [3:0]    req_op;
logic [31:0]   src0, src1;
logic [TAG_W-1:0] req_tag;
logic [63:0]   req_src2;
logic [1:0]    acc_mode;

// ---- 状态 / 响应 ----
logic          mul_ready, div_busy;
logic          resp_valid, resp_is_div;
logic [31:0]   resp_data;
logic [TAG_W-1:0] resp_tag;

// ---- 控制 ----
logic          wb_grant, flush_valid;
logic [TAG_W-1:0] flush_tag;

MUL_DIV #(.DATA_W(32), .TAG_W(TAG_W)) dut (
    .clk          (clk),
    .rst          (rst),
    .req_valid    (req_valid),
    .req_op       (req_op),
    .req_src0     (src0),
    .req_src1     (src1),
    .req_tag      (req_tag),
    .req_src2     (req_src2),
    .req_acc_mode (acc_mode),
    .mul_ready    (mul_ready),
    .div_busy     (div_busy),
    .resp_valid   (resp_valid),
    .resp_data    (resp_data),
    .resp_tag     (resp_tag),
    .resp_is_div  (resp_is_div),
    .wb_grant     (wb_grant),
    .flush_valid  (flush_valid),
    .flush_tag    (flush_tag)
);

integer errors = 0;
integer n_req = 0, n_resp = 0;
integer n_killed = 0;   // 被 flush 掉、因此**本就不该**有响应的请求数

// ===========================================================================
// 黄金模型
// ===========================================================================
function automatic logic [31:0] ref_mul(input logic [3:0] op,
                                        input logic [31:0] a,
                                        input logic [31:0] b);
    logic signed [63:0] sa, sb, sp;
    logic        [63:0] ua, ub, up;
    begin
        sa = $signed(a);
        sb = $signed(b);
        ua = {32'b0, a};
        ub = {32'b0, b};
        case (op)
            `MD_OP_MUL:    begin sp = sa * sb;                  ref_mul = sp[31:0]; end
            `MD_OP_MULH:   begin sp = sa * sb;                  ref_mul = sp[63:32]; end
            `MD_OP_MULHSU: begin sp = sa * $signed({1'b0, b});  ref_mul = sp[63:32]; end
            `MD_OP_MULHU:  begin up = ua * ub;                  ref_mul = up[63:32]; end
            default:       ref_mul = 32'hDEAD_BEEF;
        endcase
    end
endfunction

function automatic logic [31:0] ref_div(input logic [3:0] op,
                                        input logic [31:0] a,
                                        input logic [31:0] b);
    logic signed [31:0] sa, sb, q, r;
    logic        [31:0] ua, ub, uq, ur;
    begin
        sa = $signed(a);
        sb = $signed(b);
        ua = a;
        ub = b;
        // ⚠️ 除法/取余必须先算进 signed 的临时量: 直接写 `case ... : (sa / sb)`
        // 时, 整个表达式的上下文由左值 (ref_div 是无符号 32 位) 决定, 会把 / 的
        // 两个操作数也**当成无符号** —— 于是 -5/-2 会算成 4294967291/4294967294。
        if (b != 32'b0) begin
            // 无符号永远安全
            uq = ua / ub;
            ur = ua % ub;
            // ⚠️ **有符号**的 INT_MIN/-1 必须单独挡掉: 这是唯一会让 / 和 % 在
            // 仿真器里直接 SIGFPE 的组合 (x86 的 idiv 溢出), 而它的架构结果由
            // 规范另行规定。⚠️ 这个特判只对 DIV/REM 成立 —— REMU 里
            // 0x8000_0000 / 0xFFFF_FFFF 只是两个普通无符号数 (商 0 余 8e8),
            // 一起挡掉的话反而会把 REMU 判错。
            if (!((a == 32'h8000_0000) && (b == 32'hFFFF_FFFF))) begin
                q = sa / sb;
                r = sa % sb;
            end else begin
                q = 32'sh8000_0000;   // 回绕商 (规范要求 DIV 返回 INT_MIN)
                r = 32'sd0;           // 规范要求 REM 返回 0
            end
        end else begin
            q = 32'sd0; r = 32'sd0; uq = 32'd0; ur = 32'd0;
        end
        case (op)
            `MD_OP_DIV:  ref_div = (b == 32'b0) ? 32'hFFFF_FFFF
                               : ((a == 32'h8000_0000) && (b == 32'hFFFF_FFFF)) ? 32'h8000_0000
                               : q;
            `MD_OP_DIVU: ref_div = (b == 32'b0) ? 32'hFFFF_FFFF : uq;
            // 除零时 REM/REMU 返回**原始被除数** (不是绝对值)
            `MD_OP_REM:  ref_div = (b == 32'b0) ? a
                               : ((a == 32'h8000_0000) && (b == 32'hFFFF_FFFF)) ? 32'h0
                               : r;
            `MD_OP_REMU: ref_div = (b == 32'b0) ? a : ur;
            default:     ref_div = 32'hDEAD_BEEF;
        endcase
    end
endfunction

function automatic string op_name(input logic [3:0] op);
    case (op)
        `MD_OP_MUL:    op_name = "MUL";    `MD_OP_MULH:   op_name = "MULH";
        `MD_OP_MULHSU: op_name = "MULHSU"; `MD_OP_MULHU:  op_name = "MULHU";
        `MD_OP_DIV:    op_name = "DIV";    `MD_OP_DIVU:   op_name = "DIVU";
        `MD_OP_REM:    op_name = "REM";    default:       op_name = "REMU";
    endcase
endfunction

// ===========================================================================
// 激励
// ===========================================================================
task automatic idle_req;
    begin
        req_valid = 1'b0;
        req_op    = `MD_OP_MUL;
        src0      = 32'b0;
        src1      = 32'b0;
        req_tag   = {TAG_W{1'b0}};
        acc_mode  = `MD_ACC_NONE;
        req_src2  = 64'b0;
    end
endtask

// 发一条乘法: req_valid 拉 1 拍, 等 2 拍后的响应
task automatic do_mul(input logic [3:0] op, input logic [31:0] a, input logic [31:0] b,
                      output logic [31:0] data, output logic [TAG_W-1:0] tag);
    integer guard;
    begin
        @(negedge clk);
        req_valid = 1'b1; req_op = op; src0 = a; src1 = b; req_tag = TAG_W'(n_req);
        n_req = n_req + 1;
        @(negedge clk);
        req_valid = 1'b0;
        guard = 0;
        while (!resp_valid && guard < 20) begin @(negedge clk); guard = guard + 1; end
        data = resp_data; tag = resp_tag;
        if (resp_valid) n_resp = n_resp + 1;
        else begin errors = errors + 1; $display("[FATAL] 乘法 %s 等不到响应", op_name(op)); end
    end
endtask

// 发一条除法: req_valid 保持到响应 (与核内 div_stall 的语义一致)
task automatic do_div(input logic [3:0] op, input logic [31:0] a, input logic [31:0] b,
                      output logic [31:0] data, output integer lat);
    integer guard;
    begin
        @(negedge clk);
        req_valid = 1'b1; req_op = op; src0 = a; src1 = b; req_tag = TAG_W'(n_req);
        n_req = n_req + 1;
        lat = 0; guard = 0;
        // lat = 从"请求那一拍"到"看到响应"经过的拍数。
        // 状态机是 IDLE(请求拍) → PREP → ITER×n → FIXUP → RESP ⇒ lat = n + 3。
        // (PREP 拆成两拍是综合实测逼出来的, 见 div_pipe.v 文件头)
        @(negedge clk); lat = 1;
        while (!(resp_valid && resp_is_div) && guard < 200) begin
            @(negedge clk); lat = lat + 1; guard = guard + 1;
        end
        data = resp_data;
        if (resp_valid && resp_is_div) n_resp = n_resp + 1;
        else begin errors = errors + 1; $display("[FATAL] 除法 %s 等不到响应", op_name(op)); end
        @(negedge clk);
        req_valid = 1'b0;
    end
endtask

task automatic check_mul(input logic [3:0] op, input logic [31:0] a, input logic [31:0] b);
    logic [31:0] got; logic [TAG_W-1:0] tag; logic [31:0] exp;
    begin
        do_mul(op, a, b, got, tag);
        exp = ref_mul(op, a, b);
        if (got !== exp) begin
            errors = errors + 1;
            $display("[MUL MISMATCH] %-6s a=%08x b=%08x exp=%08x got=%08x",
                     op_name(op), a, b, exp, got);
        end
    end
endtask

task automatic check_div(input logic [3:0] op, input logic [31:0] a, input logic [31:0] b);
    logic [31:0] got; integer lat; logic [31:0] exp;
    begin
        do_div(op, a, b, got, lat);
        exp = ref_div(op, a, b);
        if (got !== exp) begin
            errors = errors + 1;
            $display("[DIV MISMATCH] %-6s a=%08x b=%08x exp=%08x got=%08x (lat=%0d)",
                     op_name(op), a, b, exp, got, lat);
        end
    end
endtask

// ===========================================================================
// 用例
// ===========================================================================
// doc §8.1 的定向表
task automatic directed;
    logic [31:0] v [0:15];
    integer i, j;
    begin
        v[0]  = 32'h0000_0000;  v[1]  = 32'h0000_0001;  v[2]  = 32'hFFFF_FFFF;
        v[3]  = 32'h8000_0000;  v[4]  = 32'h7FFF_FFFF;  v[5]  = 32'h8000_0001;
        v[6]  = 32'h0000_0002;  v[7]  = 32'h0000_0007;  v[8]  = 32'h0000_0064;
        v[9]  = 32'h1234_5678;  v[10] = 32'hDEAD_BEEF;  v[11] = 32'hAAAA_AAAA;
        v[12] = 32'h5555_5555;  v[13] = 32'h0000_FFFF;  v[14] = 32'h0001_0000;
        v[15] = 32'hFFFF_0000;

        $display("---- 定向: 乘法 16x16 边界组合 x 4 种 op ----");
        for (i = 0; i < 16; i = i + 1)
            for (j = 0; j < 16; j = j + 1) begin
                check_mul(`MD_OP_MUL,    v[i], v[j]);
                check_mul(`MD_OP_MULH,   v[i], v[j]);
                check_mul(`MD_OP_MULHSU, v[i], v[j]);
                check_mul(`MD_OP_MULHU,  v[i], v[j]);
            end

        $display("---- 定向: 除法 16x16 边界组合 x 4 种 op ----");
        for (i = 0; i < 16; i = i + 1)
            for (j = 0; j < 16; j = j + 1) begin
                check_div(`MD_OP_DIV,  v[i], v[j]);
                check_div(`MD_OP_DIVU, v[i], v[j]);
                check_div(`MD_OP_REM,  v[i], v[j]);
                check_div(`MD_OP_REMU, v[i], v[j]);
            end
    end
endtask

// 提前结束: 对每一个可能的迭代数 n=0..16 都至少构造一组 (|a|/|d| 前导位扫描)
task automatic early_exit_sweep;
    integer pa, pd, s, expn, lat;
    logic [31:0] a, d, got, exp;
    begin
        $display("---- 提前结束: 扫 (pos_a, pos_d) 组合, 并核对延迟 = n+2 ----");
        for (pa = 0; pa <= 31; pa = pa + 1) begin
            for (pd = 0; pd <= 31; pd = pd + 1) begin
                // 最高位分别落在 pa / pd, 低位再掺一点 (不能碰到最高位)
                a = (32'd1 << pa) | ((pa >= 3) ? 32'h5 : 32'd0);
                d = (32'd1 << pd) | ((pd >= 2) ? 32'd3 : 32'd0);
                s = pa - pd;
                expn = (s < 0) ? 0 : (s >> 1) + 1;
                do_div(`MD_OP_DIVU, a, d, got, lat);
                exp = ref_div(`MD_OP_DIVU, a, d);
                if (got !== exp) begin
                    errors = errors + 1;
                    $display("[DIV MISMATCH] DIVU a=%08x b=%08x exp=%08x got=%08x", a, d, exp, got);
                end
                if (lat !== expn + 3) begin
                    errors = errors + 1;
                    $display("[LAT MISMATCH] a=%08x b=%08x (pos %0d/%0d) 期望 %0d 拍, 实测 %0d 拍",
                             a, d, pa, pd, expn + 3, lat);
                end
            end
        end
    end
endtask

// 随机
task automatic random_sweep(input integer iters);
    logic [31:0] a, b;
    integer i;
    begin
        $display("---- 随机 %0d 组 (4 乘 + 4 除) ----", iters);
        for (i = 0; i < iters; i = i + 1) begin
            a = $random();
            b = $random();
            check_mul(`MD_OP_MUL,    a, b);
            check_mul(`MD_OP_MULH,   a, b);
            check_mul(`MD_OP_MULHSU, a, b);
            check_mul(`MD_OP_MULHU,  a, b);
            check_div(`MD_OP_DIV,    a, b);
            check_div(`MD_OP_DIVU,   a, b);
            check_div(`MD_OP_REM,    a, b);
            check_div(`MD_OP_REMU,   a, b);
        end
    end
endtask

// 背靠背: II=1 —— 连发 8 条乘法, 响应必须每拍一个、按序、带对的 tag
task automatic back_to_back;
    integer i, seen, guard;
    logic [31:0] exp [0:7];
    logic [31:0] a [0:7];
    logic [31:0] b [0:7];
    integer      gap [0:7];
    integer      prev;
    begin
        $display("---- 背靠背乘法 (II=1) ----");
        for (i = 0; i < 8; i = i + 1) begin
            a[i] = $random();
            b[i] = $random();
            exp[i] = ref_mul(`MD_OP_MUL, a[i], b[i]);
        end
        // 必须**边发边收**: 响应的延迟只有 2 拍, 发完 8 条再收的话前 6 条早就过去了。
        // 第 i 拍(negedge i)发出的请求, 其响应正好在 negedge i+2 出现 —— 这一条
        // 也正是"II=1 + 固定 2 拍"的定义, 所以下面的逐拍断言同时验证了两件事。
        @(negedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            req_valid = 1'b1;
            req_op = `MD_OP_MUL; src0 = a[i]; src1 = b[i]; req_tag = TAG_W'(i);
            if (!mul_ready) begin
                errors = errors + 1;
                $display("[FATAL] 背靠背第 %0d 条: mul_ready=0 (II 不是 1)", i);
            end
            n_req = n_req + 1;
            @(negedge clk);
            // 请求 i 在 N_i 发出、P_{i+1} 被采样 ⇒ 响应在 N_{i+2} 可见,
            // 也就是本拍 (N_{i+1}) 看到的应该是第 i-1 条的响应。
            if (i >= 1) begin
                if (!resp_valid) begin
                    errors = errors + 1;
                    $display("[FATAL] 背靠背第 %0d 条响应没来 (不是每拍一个)", i-1);
                end else begin
                    n_resp = n_resp + 1;
                    if (resp_tag !== TAG_W'(i-1)) begin
                        errors = errors + 1;
                        $display("[TAG MISMATCH] 第 %0d 条响应 tag=%0d", i-1, resp_tag);
                    end
                    if (resp_data !== exp[i-1]) begin
                        errors = errors + 1;
                        $display("[MUL MISMATCH] 背靠背第 %0d 条 exp=%08x got=%08x",
                                 i-1, exp[i-1], resp_data);
                    end
                end
            end else if (resp_valid) begin
                errors = errors + 1;
                $display("[FATAL] 第 %0d 拍就出现了响应 (延迟不足 2 拍)", i);
            end
        end
        req_valid = 1'b0;
        // 收最后一条 (第 7 条的响应在 N_9)
        @(negedge clk);
        if (!resp_valid) begin
            errors = errors + 1; $display("[FATAL] 背靠背第 7 条没有响应");
        end else begin
            n_resp = n_resp + 1;
            if (resp_tag !== TAG_W'(7)) begin
                errors = errors + 1;
                $display("[TAG MISMATCH] 第 7 条响应 tag=%0d", resp_tag);
            end
            if (resp_data !== exp[7]) begin
                errors = errors + 1;
                $display("[MUL MISMATCH] 背靠背第 7 条 exp=%08x got=%08x", exp[7], resp_data);
            end
        end
        // 再等一拍确认没有多出来的第 9 个脉冲
        @(negedge clk);
        if (resp_valid) begin
            errors = errors + 1;
            $display("[FATAL] 背靠背 8 条之后多出一个响应脉冲");
        end
    end
endtask

// 冲刷: 被 flush 掉的乘法绝不能产生响应 (doc §8.3)
task automatic flush_check;
    logic [31:0] got; logic [TAG_W-1:0] tag; integer guard;
    begin
        $display("---- 冲刷: 在飞的乘法不得写回 ----");
        // (1) 发射当拍就冲刷
        @(negedge clk);
        req_valid = 1'b1; req_op = `MD_OP_MUL; src0 = $random(); src1 = $random();
        req_tag = 7'd42; n_req = n_req + 1; n_killed = n_killed + 1;
        flush_valid = 1'b1;
        @(negedge clk);
        req_valid = 1'b0; flush_valid = 1'b0;
        for (guard = 0; guard < 8; guard = guard + 1) begin
            if (resp_valid) begin
                errors = errors + 1;
                $display("[FATAL] 发射当拍被冲刷的乘法仍然产生了响应 (data=%08x)", resp_data);
            end
            @(negedge clk);
        end

        // (2) 发射后 1 拍冲刷 (此时在 M2 级)
        @(negedge clk);
        req_valid = 1'b1; req_op = `MD_OP_MUL; src0 = $random(); src1 = $random();
        req_tag = 7'd43; n_req = n_req + 1; n_killed = n_killed + 1;
        @(negedge clk);
        req_valid = 1'b0;
        flush_valid = 1'b1;
        @(negedge clk);
        flush_valid = 1'b0;
        for (guard = 0; guard < 8; guard = guard + 1) begin
            if (resp_valid) begin
                errors = errors + 1;
                $display("[FATAL] 在 M2 被冲刷的乘法仍然产生了响应 (data=%08x)", resp_data);
            end
            @(negedge clk);
        end

        // (3) 冲刷之后流水必须还能正常干活
        do_mul(`MD_OP_MUL, 32'd10, 32'd7, got, tag);
        if (got !== 32'd70) begin
            errors = errors + 1;
            $display("[FATAL] 冲刷后乘法失效: 10*7=%0d", got);
        end else begin
            n_resp = n_resp + 1;
            $display("     冲刷后 10*7 = %0d (OK)", got);
        end
        n_req = n_req + 1;
    end
endtask

// 除法忙的时候乘法照常 (两条流水互不阻塞) —— 这是"乘除分家"的核心理由
task automatic div_mul_overlap;
    logic [31:0] got; integer lat, guard, mul_got_early;
    logic [31:0] dv; logic [31:0] mv; logic [TAG_W-1:0] tag;
    begin
        $display("---- 除法迭代期间乘法不受影响 ----");
        @(negedge clk);
        req_valid = 1'b1; req_op = `MD_OP_DIVU;
        src0 = 32'hFFFF_FFFF; src1 = 32'h0000_0003;   // 满量程 → 16 次迭代
        req_tag = 7'd1; n_req = n_req + 1;
        @(negedge clk);
        // 除法还在跑的时候塞一条乘法进去 (核里不可能, 这里验证单元本身)
        if (!div_busy) begin errors = errors + 1; $display("[FATAL] 除法应该 busy"); end
        req_op = `MD_OP_MUL; src0 = 32'd6; src1 = 32'd9; req_tag = 7'd2; n_req = n_req + 1;
        @(negedge clk);
        req_op = `MD_OP_DIVU; src0 = 32'hFFFF_FFFF; src1 = 32'h0000_0003;
        mul_got_early = 0;
        guard = 0;
        while (guard < 40) begin
            if (resp_valid && !resp_is_div && !mul_got_early) begin
                mul_got_early = 1;
                if (resp_data !== 32'd54) begin
                    errors = errors + 1;
                    $display("[FATAL] 除法迭代中的乘法结果错: %0d", resp_data);
                end else begin
                    n_resp = n_resp + 1;
                end
            end
            if (resp_valid && resp_is_div) begin
                n_resp = n_resp + 1;
                mv = resp_data;
                if (mv !== 32'h5555_5555) begin
                    errors = errors + 1;
                    $display("[FATAL] 除法结果错: exp=55555555 got=%08x", mv);
                end
                guard = 99;
            end
            @(negedge clk); guard = guard + 1;
        end
        if (!mul_got_early) begin
            errors = errors + 1;
            $display("[FATAL] 除法占着单元时乘法被卡住了 (乘除没有真正分家)");
        end
        req_valid = 1'b0;
        @(negedge clk);
    end
endtask

// 延迟与周期数报表
task automatic latency_report;
    logic [31:0] got; integer lat;
    begin
        // 状态机 IDLE(请求拍) → PREP → ITER×n → FIXUP → RESP
        // ⇒ 从请求拍到看到响应 n+3 拍 (带 PREP 两拍), 现状是恒 34 拍。
        $display("---- 除法延迟 (n+3 拍) ----");
        do_div(`MD_OP_DIVU, 32'd100, 32'd7, got, lat);
        $display("     100/7     : %0d 拍 (s=4, n=3 ⇒ 期望 6)", lat);
        do_div(`MD_OP_DIVU, 32'hFFFF_FFFF, 32'h2, got, lat);
        $display("     2^32-1/2  : %0d 拍 (s=30, n=16 ⇒ 期望 19)", lat);
        do_div(`MD_OP_DIVU, 32'd7, 32'd100, got, lat);
        $display("     7/100     : %0d 拍 (n=0 ⇒ 期望 3)", lat);
        do_div(`MD_OP_DIV, 32'h8000_0000, 32'hFFFF_FFFF, got, lat);
        $display("     INT_MIN/-1: %0d 拍, 结果 %08x (期望 80000000)", lat, got);
        do_div(`MD_OP_REM, 32'h8000_0000, 32'hFFFF_FFFF, got, lat);
        $display("     INT_MIN%%-1: %0d 拍, 结果 %08x (期望 00000000)", lat, got);
    end
endtask

// ===========================================================================
initial begin
    idle_req();
    wb_grant    = 1'b1;
    flush_valid = 1'b0;
    flush_tag   = {TAG_W{1'b0}};
    req_src2    = 64'b0;
    acc_mode    = `MD_ACC_NONE;

    repeat (5) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    directed();
    early_exit_sweep();
    random_sweep(300);
    back_to_back();
    flush_check();
    div_mul_overlap();
    latency_report();

    $display("");
    $display("==================================================");
    // doc §8.3: resp_valid 的条数 == 被接受的请求数 − 被冲刷掉的条数
    $display("  请求 %0d 条 / 冲刷 %0d 条 / 响应 %0d 条", n_req, n_killed, n_resp);
    if (n_resp !== (n_req - n_killed)) begin
        errors = errors + 1;
        $display("  [FATAL] 响应条数与 (请求-冲刷) 不符 (丢/重)");
    end
    if (errors == 0) $display("  MULDIV UNIT: ALL PASS");
    else             $display("  MULDIV UNIT: %0d ERRORS", errors);
    $display("==================================================");
    if (errors == 0) $finish;
    else             $fatal(1, "muldiv unit test failed");
end

endmodule
