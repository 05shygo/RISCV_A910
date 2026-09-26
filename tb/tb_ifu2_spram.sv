`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu2_spram — rv32ifu2_spram 的等价性自检
//
// 比对对象是**参照模型**, 它逐字复刻 rv32ifu2_icache.v 换 RAM 之前的那套做法:
//
//     always @(posedge clk) begin
//         ref_ra_q <= rd_addr;              // 地址寄存 (无条件)
//         if (wr_en) ref_mem[wr_addr] <= wr_data;
//     end
//     assign ref_q = ref_mem[ref_ra_q];     // 组合读 —— 含本边沿刚写进去的值
//
// 两个阵列读出来必须**逐位相同**。
//
// 为什么值得单独写一个 tb: rv32ifu2_spram.v 的写穿透等价性是归纳法证明出来的,
// 但证明写在注释里没人会去重推。这里把它变成实测 —— 尤其是下面三类**光跑 CPU
// 用例测不到**的地址序列:
//
//   1. 同址同拍读写 (碰撞)。这是 i-cache 回填那一拍的真实形态。
//   2. 碰撞之后**立刻**再读同址 (写穿透是否真的落到了下一拍)。
//   3. 同址读 + 写别的地址 (写不能污染读口)。
//
// ⚠️ 第 2 类正是 read-first 语义会错的地方, 而且错法有两种: 漏命中, 或者
// (更坏) 交付陈旧数据。把 _prim 改成 read-first 再跑本 tb, 应当立刻报错 ——
// 这是本 tb 的**有效性**证明 (见 Makefile 无关, 直接用 vcs 编译本文件即可)。
//
// 编译 (不需要 golden model / DPI):
//   vcs -full64 -sverilog -timescale=1ns/1ps +v2k -top tb_ifu2_spram \
//       -o obj_spram/simv mySoC/ifu2/rtl/rv32ifu2_spram.v tb/tb_ifu2_spram.sv
//   ./obj_spram/simv -exitstatus
// ===========================================================================
module tb_ifu2_spram;

localparam int AW = 4;              // 16 项: 小到碰撞随手可得
localparam int DW = 8;
localparam int N  = 1 << AW;

reg              clk = 1'b0;
always #5 clk = ~clk;

reg  [AW-1:0] rd_addr;
reg  [AW-1:0] wr_addr;
reg           wr_en;
reg  [DW-1:0] wr_data;
wire [DW-1:0] rd_data;

rv32ifu2_spram #(.ADDR_W(AW), .DATA_W(DW)) dut (
    .clk     (clk),
    .rd_addr (rd_addr),
    .rd_data (rd_data),
    .wr_addr (wr_addr),
    .wr_en   (wr_en),
    .wr_data (wr_data)
);

// ---------------------------------------------------------------------------
// 参照模型 —— 换 RAM 之前 rv32ifu2_icache.v 的做法
// ---------------------------------------------------------------------------
reg  [DW-1:0] ref_mem [0:N-1];
reg  [AW-1:0] ref_ra_q;

always @(posedge clk) begin
    ref_ra_q <= rd_addr;
    if (wr_en) ref_mem[wr_addr] <= wr_data;
end

wire [DW-1:0] ref_q = ref_mem[ref_ra_q];

// ---------------------------------------------------------------------------
// 驱动 + 逐拍比对
//
// drive(): 本拍给地址与写控制 → 等一个边沿 → 比对**上一拍那个读地址**的结果。
// 这正是 icache 的用法: 地址第 k 拍给, 数据第 k+1 拍用。
// ---------------------------------------------------------------------------
int nchk = 0;
int nerr = 0;
int ncol = 0;               // 实际发生的同址同拍读写次数 (碰撞覆盖率)

task automatic drive(input [AW-1:0] ra, input [AW-1:0] wa,
                     input we, input [DW-1:0] wd, input string tag);
    rd_addr = ra; wr_addr = wa; wr_en = we; wr_data = wd;
    @(posedge clk);
    #1;                                  // 等非阻塞赋值落定
    nchk++;
    if (we && (ra == wa)) ncol++;
    if (rd_data !== ref_q) begin
        nerr++;
        if (nerr <= 20)
            $display("  [FAIL %s] t=%0t rd_addr=%0d -> rd_data=%h, 参照=%h   (wr_en=%b wr_addr=%0d wr_data=%h)",
                     tag, $time, ra, rd_data, ref_q, we, wa, wd);
    end
endtask

// ---------------------------------------------------------------------------
// 选一个"坏"读数: 让写数据的高位全 1, 这样一旦交付了陈旧值必然看得见
// ---------------------------------------------------------------------------
function automatic [DW-1:0] pat(input int i);
    pat = DW'(8'hA5 ^ (i * 8'h37));
endfunction

int i, k;
int seed;
int ra_r, wa_r;

initial begin
    // 不给随机种子的话 $random 每次跑一样 —— 这里反而要固定, 结果可复现
    seed = 32'hC0FFEE;
    void'($random(seed));

    rd_addr = '0; wr_addr = '0; wr_en = 1'b0; wr_data = '0;

    $display("[tb_ifu2_spram] AW=%0d DW=%0d N=%0d", AW, DW, N);

    // ---- 阶段 0: 复位/上电后阵列是 X。先全写一遍, 让两侧都有确定内容 ----
    // (真实宏上电就是 X, 靠控制器扫描; 这里用写满代替扫描, 比对才有意义)
    for (i = 0; i < N; i = i + 1)
        drive(AW'(i), AW'(i), 1'b1, pat(i), "fill");

    // ---- 阶段 1: 同址同拍读写 (碰撞), 连续做, 覆盖"刚写完立刻再读同址" ----
    for (i = 0; i < N; i = i + 1) begin
        drive(AW'(i), AW'(i), 1'b1, pat(i + 100), "collide-wr");
        drive(AW'(i), AW'(i), 1'b1, pat(i + 200), "collide-wr2");
        drive(AW'(i), AW'(i), 1'b0, '0,          "collide-rd");   // 只读同址
    end

    // ---- 阶段 2: 随机序列, 其中约 1/3 强制成碰撞 ----
    for (k = 0; k < 4000; k = k + 1) begin
        ra_r = $random();
        wa_r = $random();
        rd_addr = AW'(ra_r);
        if (($random() % 3) == 0) wa_r = ra_r;          // 强制碰撞
        drive(AW'(ra_r), AW'(wa_r), ($random() % 4) != 0, DW'($random()), "rand");
    end

    // ---- 阶段 3: 写口常关一段时间, 确认读口不会自己变 ----
    wr_en = 1'b0; wr_addr = '0; wr_data = '0;
    for (k = 0; k < 32; k = k + 1)
        drive(AW'($random()), AW'($random()), 1'b0, '0, "no-wr");

    // ---- 结论 ----
    $display("");
    if (nerr == 0) begin
        $display("[tb_ifu2_spram] PASS  比对 %0d 拍, 同址同拍读写碰撞 %0d 次", nchk, ncol);
        if (ncol == 0) begin
            $display("[tb_ifu2_spram] 致命: 一次碰撞都没发生, 本 tb 没验到写穿透那条路径!");
            $fatal(1);
        end
    end else begin
        $display("[tb_ifu2_spram] FAIL  %0d/%0d 拍不一致 (碰撞 %0d 次)", nerr, nchk, ncol);
        $fatal(1);
    end
    $finish;
end

// 看门狗
initial begin
    #2_000_000;
    $display("[tb_ifu2_spram] 致命: 超时");
    $fatal(1);
end

endmodule
