`timescale 1ns / 1ps
`define STRINGIFY(x) `"x`"

// ===========================================================================
// mySoC/sync_mem.v — 可综合的同步存储器原语 (1R1W RAM / ROM)
//
// 为什么要有这个文件
// ---------------------------------------------------------------------------
// 原来的两个存储器是**仿真模型**, 直接拿去综合会退化:
//   * vsrc/ram.v 的 DRAM 是 `assign spo = mem[a]` —— **异步读**。异步读的阵列在
//     FPGA 上只能落分布式 LUTRAM (实测 RAMS64E × 8160)。16K×32 摊在八千多个
//     LUT 站点上, 地址线从 CPU 走到每一个站点, 那条路 **0 级逻辑、98% 布线** ——
//     延迟就是物理距离, 跟逻辑深度无关。
//   * mySoC/ifu_biu_mem.v 的指令阵列只读+有初值, 被例化成分布式 ROM
//     (约 7K 个 LUT 当逻辑用), 同理。
// 要用块 RAM (BRAM), 存储阵列必须是**同步读** (地址当拍给、数据下拍出), 而
// 比赛模板那条 `.xci` 路线就是这个语义。所以这里给出一个语义明确的接缝。
//
// 换 FPGA IP 核时**只有 prim 那一层要换**
// ---------------------------------------------------------------------------
// 结构照 rv32ifu2_spram.v 的分层 (那套已经用在 i-cache 上, 且踩过坑):
//   外层  sync_ram_1r1w      —— 拥有**写穿透**语义的那一级 mux
//   内层  sync_ram_1r1w_prim —— 真正要换掉的存储原语 (XPM_MEMORY / blk_mem_gen)
// 写穿透是**跨口**的 (读口要看写口这一拍写了什么), 没有任何 FPGA RAM 原语内置
// 这个能力 (Xilinx 的 WRITE_FIRST 只作用于写口自己的 DO)。所以 mux 必须留在
// 厂商宏**外面**, "换 IP 核"才等于"只换 prim"。
//
// 读口语义契约 (换 IP 时逐条保持, 少一条周期数/功能就会变)
// ---------------------------------------------------------------------------
//   1. **Q 寄存输出**: 第 k 拍给 rd_addr, 第 k+1 拍 rd_data 有效。
//   2. **写穿透**: 同一拍 rd_addr == wr_addr 且 wr_en 时, 第 k+1 拍的 rd_data
//      等于第 k 拍写入的 wr_data, 而**不是**存储里的旧值。
//   3. 整字写 (没有 bit/byte enable)。
//   4. **无复位** (真实宏上电是 X / 由初值决定)。
//   5. **没有 rd_en**: 每拍都读。
//
// ⚠️ **契约 2 在本工程里不是优化, 是正确性。** 数据侧靠它同时兑现两件事:
//   * store→load 同址: 写口在 MEM 级、读口在 EX 级, 两者**同一拍**比较 ——
//     紧接着 store 的那条 load 必须看到新值 (异步阵列时代这是白送的);
//   * store→store 同址: 后一条 store 的 sb/sh 读-改-写必须基于前一条 store
//     已经合并好的字, 否则会把前一条写进去的字节整个盖掉。
//   丢掉契约 2 的症状是"隔一条的错误", 短用例不一定覆盖得到。
//
// ⚠️ 另一条纪律: 旁路判断比较的必须是**存储地址本身** (这里是字地址), 不能用
//    "反正差不多"的近似量 —— 比较粒度一错就是静默的错误数据。
//
// 上 FPGA 的换法
// ---------------------------------------------------------------------------
//   1. 只替换 sync_ram_1r1w_prim / sync_rom_1r1w_prim 的**函数体**。
//   2. 外层那一级写穿透 mux **无条件保留**。
//   3. IP 设置: simple dual port (1 写口 + 1 读口), read latency = 1,
//      不要再加输出寄存器, 上电初值就用 `PATH 指向的镜像 (见下)。
//
// 镜像文件
// ---------------------------------------------------------------------------
// 初值走 `$readmemh` + Makefile 生成的十六进制镜像 (PATH 宏), 仿真与综合**同一份**。
// 原来的 $fread + 手工字节交换是仿真专用的, 综合器不认。
// ===========================================================================

// ---------------------------------------------------------------------------
// sync_ram_1r1w —— 通用 1R1W 同步 RAM (数据存储用)
// ---------------------------------------------------------------------------
`include "defines.vh"

module sync_ram_1r1w #(
    parameter ADDR_W = 14,        // 14 ⇒ 16K 字 (= 比赛模板的 64 KB 数据区)
    parameter DATA_W = 32
)(
    input  wire              clk,

    // ---- 读口 (每拍都读, 无 enable) ----
    input  wire [ADDR_W-1:0] rd_addr,
    output wire [DATA_W-1:0] rd_data,

    // ---- 写口 ----
    input  wire              wr_en,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire [DATA_W-1:0] wr_data
);

wire [DATA_W-1:0] mem_rd;

sync_ram_1r1w_prim #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W)
) u_prim (
    .clk     (clk),
    .rd_addr (rd_addr),
    .rd_data (mem_rd),
    .wr_en   (wr_en),
    .wr_addr (wr_addr),
    .wr_data (wr_data)
);

// ---------------------------------------------------------------------------
// 写穿透 (契约 2)。只打一拍就够: 第 k 拍判断"这一拍读的地址是不是正好被写",
// 第 k+1 拍用它选数据 —— 和第 k+1 拍从原语出来的 Q 是同一拍, 所以只是组合 mux,
// **不加拍**。
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

endmodule

// ---------------------------------------------------------------------------
// sync_ram_1r1w_prim —— 存储原语本体 (换 IP 只动这里)
//
// 就是"同步读 + 同步写"的教科书模板: 读地址本拍给、数据下拍出, 写在同一个边沿。
// **写和读同址时这里是 read-first** (非阻塞赋值读到的是旧值) —— 这正是原语的
// 正确行为, 补写穿透是外层 shell 的责任, 不要在这里加。
//
// 没有复位、没有 initial 清零: 真实宏上电由初值 (或 X) 决定, 数据阵列不清零是
// 安全的 —— 有效位都在控制器侧的触发器里。
//
// `PATHHEX 是 Makefile 从 bin/%.bin 生成的十六进制镜像 (每行一个 32 位字)。
// Vivado 用 initial 里的 $readmemh 给 BRAM 上电初值, 这是官方支持的写法。
// ---------------------------------------------------------------------------
module sync_ram_1r1w_prim #(
    parameter ADDR_W = 14,
    parameter DATA_W = 32
)(
    input  wire              clk,
    input  wire [ADDR_W-1:0] rd_addr,
    output wire [DATA_W-1:0] rd_data,
    input  wire              wr_en,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire [DATA_W-1:0] wr_data
);

reg [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];
reg [DATA_W-1:0] rd_q;

initial begin
    $readmemh(`STRINGIFY(`PATHHEX), mem);
end

always @(posedge clk) begin
    rd_q <= mem[rd_addr];
    if (wr_en) mem[wr_addr] <= wr_data;
end

assign rd_data = rd_q;

endmodule

// ---------------------------------------------------------------------------
// sync_rom_1r1w —— 1R1W 同步 ROM (取指存储用)
//
// 与 RAM 同契约, 只是没有写口、没有写穿透 (没有写就没有撞地址的问题)。
// 宽口 (BEAT_W) 是为了取指: BIU 一次要 16 B (128 位), 拆成 4 个 32 位阵列去读
// 要么开 4 个读口、要么存 4 份 —— 直接把字宽做成 128 位更省 BRAM。
// 初值文件是 **128 位/行** 的镜像 (Makefile 生成, 行内 w3..w0 降序,
// 正好等于顶层要的 {w3,w2,w1,w0})。
// ---------------------------------------------------------------------------
module sync_rom_1r1w #(
    parameter ADDR_W = 12,        // 12 ⇒ 4096 个 16 B 块 = 64 KB
    parameter DATA_W = 128
)(
    input  wire              clk,
    input  wire [ADDR_W-1:0] rd_addr,
    output wire [DATA_W-1:0] rd_data
);

sync_rom_1r1w_prim #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W)
) u_prim (
    .clk     (clk),
    .rd_addr (rd_addr),
    .rd_data (rd_data)
);

endmodule

module sync_rom_1r1w_prim #(
    parameter ADDR_W = 12,
    parameter DATA_W = 128
)(
    input  wire              clk,
    input  wire [ADDR_W-1:0] rd_addr,
    output wire [DATA_W-1:0] rd_data
);

reg [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];
reg [DATA_W-1:0] rd_q;

initial begin
    $readmemh(`STRINGIFY(`PATH128), mem);
end

always @(posedge clk) begin
    rd_q <= mem[rd_addr];
end

assign rd_data = rd_q;

endmodule
