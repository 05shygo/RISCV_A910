`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_spram — 可移植 1R1W (简单双口) 同步 RAM + **写穿透读口**
//
// 分成两层是有原因的, 不是洁癖:
//   外层 rv32ifu2_spram       —— 拥有**写穿透**语义的那一级 mux
//   内层 rv32ifu2_spram_prim  —— 真正要换掉的存储原语
// 写穿透是**跨口**的 (读口要看写口这一拍写了什么), 没有任何 FPGA RAM 原语
// 内置这个能力。所以 mux 必须留在厂商宏**外面**, "换 IP 核"才等于"只换 prim"。
//
// ---------------------------------------------------------------------------
// 为什么不能照抄 ifu_rv32i/rtl/rv32_ifu_spram.v (C910 那套)
//
// C910 那个是 **1RW**: 一个地址口, 读写二选一, 且"写时 Q 保持不变"。ifu2 两条
// 都用不了:
//   1. **必须 1R1W**。i-cache 的查找读**每拍都要发**, 而写只在 refill_en 那一拍。
//      更要命的是读地址与写地址是**互相独立**的两个来源: 读地址 = next_pc[8:4]
//      (顶层组合算出来的), 写地址 = refill_pc[8:4]。1RW 只能丢掉读, 而丢掉的那
//      拍 F1 就没有数据了 —— 正好是"重定向进 PC 零气泡"那条快路上的气泡。
//      C910 敢用 1RW, 是因为它用 trans_busy_q 给**整个**回填事务插了气泡
//      (rv32_ifu_icache_top.v 的 array_available); ifu2 没有气泡可花。
//   2. **读口必须写穿透**。见下。
//
// ---------------------------------------------------------------------------
// 读口语义契约 (换 FPGA IP 核时逐条保持, 少一条周期数就会变)
//
//   1. **Q 寄存输出**: 第 k 拍给 rd_addr, 第 k+1 拍 rd_data 有效。
//   2. **写穿透**: 同一拍 rd_addr == wr_addr 且 wr_en 时, 第 k+1 拍的 rd_data
//      等于第 k 拍写入的 wr_data, 而**不是**存储里的旧值。
//   3. 整字写 (没有 bit/byte enable)。
//   4. **无复位、无上电初值** (真实宏上电是 X), 由控制器扫描。
//   5. **没有 rd_en**: 每拍都读。
//
// 契约 2 不是性能优化, 是**语义等价的核心**, 而且契约 5 与它绑在一起:
// 只要加了 rd_en, "Q 保持"就成了可能, 契约 1 不再无条件成立, 下面的等价性就不成立。
//
// 契约 2 的等价性证明 (与裸 reg 阵列逐位等价, 对所有输入序列成立):
//   裸 reg 阵列在第 k+1 拍读到的值是"边沿 k→k+1 之后"的 mem[rd_addr(k)]。
//   * 若 rd_addr(k) != wr_addr(k): 写落在别处, mem[rd_addr(k)] 没变
//     ⇒ 与第 k 拍读到的旧值相同。
//   * 若 rd_addr(k) == wr_addr(k): 边沿后 mem[rd_addr(k)] 正是 wr_data(k)
//     ⇒ 就是 mux 给出的那个值。
//   两种情况都等于本模块的 rd_data, 且两侧的内容推进方式完全相同。证毕。
//
// ⚠️ 契约 2 丢掉时的**两类**后果 (都不是"慢一点"而已):
//   (a) 漏命中 —— 查询行就是刚写入的行, 旧 tag ⇒ 多一次 2 拍回填 + 多一次 BIU 事务;
//   (b) **陈旧假命中** —— 查询行是同 set 的**另一行**, 且该行原驻留在被牺牲那一路;
//       旧 tag 说它还在 ⇒ 报 hit 并交付刚被覆盖的数据 ⇒ **交付错指令**。
//   (b) 是功能错误, 不是性能问题, 且短用例不一定测得到 —— 见 tb/tb_ifu2_spram.sv。
//
// ⚠️ 另一个坑: 旁路判断必须比较**行地址**(本模块的地址就是 set), 不能用别的
// 近似量去"顺手"比较 —— 比较粒度一错就是假命中发生器。
//
// ---------------------------------------------------------------------------
// 上 FPGA 的换法:
//   1. 只替换 rv32ifu2_spram_prim 的**函数体**。
//   2. rv32ifu2_spram 的写穿透 mux **无条件保留** —— 这是唯一必须活下来的东西。
//   3. IP 设置: simple dual port (1 写口 + 1 读口), read latency = 1, 不要再加输出
//      寄存器, 不要初值, 不要复位。
//   4. 资源提示: tag 阵列 (32×23 = 736 bit/片) 放分布式 RAM 更合适; data 阵列
//      (32×128) 宽度上要占满一个 BRAM 的位宽, 深度只用了 32。
// ===========================================================================
module rv32ifu2_spram #(
    parameter ADDR_W = 5,
    parameter DATA_W = 128
)(
    input  wire              clk,

    // ---- 读口 (每拍都读, 无 enable) ----
    input  wire [ADDR_W-1:0] rd_addr,
    output wire [DATA_W-1:0] rd_data,

    // ---- 写口 ----
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data
);

// ---------------------------------------------------------------------------
// 原语 (换 IP 核只动这一个模块)
// ---------------------------------------------------------------------------
wire [DATA_W-1:0] mem_rd;

rv32ifu2_spram_prim #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W)
) u_prim (
    .clk     (clk),
    .rd_addr (rd_addr),
    .rd_data (mem_rd),
    .wr_addr (wr_addr),
    .wr_en   (wr_en),
    .wr_data (wr_data)
);

// ---------------------------------------------------------------------------
// 写穿透 (契约 2)。
//
// 只打一拍就够: 第 k 拍判断"这一拍读的地址是不是正好被写", 第 k+1 拍用它选数据 ——
// 和第 k+1 拍从原语出来的 Q 是同一拍, 所以只是组合 mux, **不加拍**。
//
// wt_dat_q 用 wr_en 门控再存: 不用的时候不让它跟着 wr_data 空翻 (省动态功耗),
// 门控是安全的 —— 它只在 wt_q 为 1 时被读, 而 wt_q 蕴含 wr_en。
// ---------------------------------------------------------------------------
reg               wt_q;
reg  [DATA_W-1:0] wt_dat_q;

always @(posedge clk) begin
    wt_q <= wr_en & (wr_addr == rd_addr);
    if (wr_en) wt_dat_q <= wr_data;
end

assign rd_data = wt_q ? wt_dat_q : mem_rd;

// synopsys translate_off
// 契约 5 的结构自检: 加 rd_en 会让"Q 保持"成为可能, 契约 1 就不再无条件成立。
// 这里没有端口可查, 只能靠注释拦住 —— 这个 initial 只是把约束**打出来**,
// 让人在改这个文件时先看见它。
initial begin
    $display("[IFU2-SPRAM] ADDR_W=%0d DATA_W=%0d (契约: 同步读 + 写穿透 + 无 rd_en + 无复位)",
             ADDR_W, DATA_W);
end
// synopsys translate_on

endmodule

// ===========================================================================
// rv32ifu2_spram_prim — 存储原语本体
//
// 就是"同步读 + 同步写"的教科书模板: 读地址本拍给、数据下拍出 (rd_q 寄存),
// 写在同一个边沿。**写和读同址时这里是 read-first** (非阻塞赋值读到的是旧值) ——
// 这正是原语的正确行为, 补写穿透是外层 shell 的责任, 不要在这里加。
//
// 没有复位、没有 initial、没有 $readmemh: 真实宏上电就是 X。数据阵列不清零是
// 安全的 —— i-cache 的行有效位在控制器侧的触发器里, valid=0 的行数据永不被用。
//
// 换成 FPGA IP 核 (XPM_MEMORY / blk_mem_gen / altsyncram) 时替换本模块的函数体,
// 保持端口名与语义不变即可。
// ===========================================================================
module rv32ifu2_spram_prim #(
    parameter ADDR_W = 5,
    parameter DATA_W = 128
)(
    input  wire              clk,
    input  wire [ADDR_W-1:0] rd_addr,
    output wire [DATA_W-1:0] rd_data,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data
);

reg [DATA_W-1:0] mem_q [0:(1<<ADDR_W)-1];
reg [DATA_W-1:0] rd_q;

always @(posedge clk) begin
    rd_q <= mem_q[rd_addr];
    if (wr_en) mem_q[wr_addr] <= wr_data;
end

assign rd_data = rd_q;

endmodule
