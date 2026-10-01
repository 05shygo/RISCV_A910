`timescale 1ns / 1ps

// ===========================================================================
// IFU BIU 从端 + 指令 ROM (ifu_biu_mem)
//
// 给 rv32_ifu_top / rv32ifu2_refill 的 BIU 主端口提供存储。协议要点 (与
// doc/icache_zh.md、RV32I_C910_IFU_interface_v1.1_noMMU.xlsx P05/P06/P07 一致):
//   - req && grnt 在时钟边沿接受一笔事务; 本从端 grnt 恒 1。
//   - rd_id: 0 = demand, 1 = prefetch。两路各最多一笔在途, 路内保序,
//     两路可交错返回。返回必须回显 rd_id —— IFU 用它选内部 ready。
//   - rd_len: 2'b11 = 4 拍 (64B 行), 2'b00 = 单拍。last 必须打在
//     第 3 拍 / 第 0 拍, 打错会被 IFU 判为协议错, 每次取指都变故障。
//   - 拍序是 64B 行内以请求的 16B 块为首的 WRAP: 块号 = addr[5:4] + beat (模 4)。
//   - data_vld && ifu_biu_r_ready 才算一拍被消费; 不 ready 时全部返回信号保持。
//   - grant 当拍 IFU 内部的 outstanding 寄存器还没置位, 那拍不能驱动 data_vld。
//   - resp: 2'b00 = 成功 (IFU 只看 bit1)。
//
//---------------------------------------------------------------------------
// 存储形态 (2026-09-28 换掉仿真模型)
//
// 原来是 `reg [31:0] mem [0:16383]` + `$fread` + 四个组合读口:
//   * `$fread` 综合器不认;
//   * 四个组合读口 (一拍凑 128 位) 在 FPGA 上只能落**分布式 ROM** —— 实测约 7K
//     个 LUT 当逻辑用, 而且读地址要铺到所有站点上, 布线长度就是延迟本身。
// 现在只有**一个**同步读口, 字宽直接做成 128 位 (一个 16 B 取指块一行):
//   4096 × 128 = 512 Kbit ⇒ 约 15 个 BRAM36, 而不是 4 份 16K×32 的 64 个。
//   初值走 `$readmemh(`PATH128)` —— Makefile 从 bin/%.bin 现生成 (每行一个块,
//   行内 w3..w0 降序, 正好等于顶层要的 {w3,w2,w1,w0})。
//
// ⚠️ **读地址必须提前一拍给**: 同步 ROM 的数据下一拍才出来, 而 ctx_valid 是
//    launch 的下一拍才拉高 —— 所以地址要在"数据被用掉的那一拍的前一拍"就已经
//    在 ROM 的地址口上。下面的 addr_nxt 就是"下一拍会被服务的那个 (ctx, beat)"。
//    拍序与原来的组合读**逐位相同** (T 拍 launch → T+1 出数据), 所以 i-cache 的
//    缺行代价仍然是 2 拍, rv32ifu2_refill 的 FSM 与 icache 的 rf_match 旁路一行都不用改。
//
// ⚠️ 当前 rv32ifu2_refill 只用 **demand 一路 (rd_id=0) 且 rd_len=2'b00 (单拍)**,
//    prefetch 那一路从未发起过。下面仍然把两路 + 多拍写全 —— 但要知道那段逻辑
//    在现有 FSM 下**跑不到**, 仿真测不出来; 将来真要上预取时先给它补用例。
// ===========================================================================
`include "defines.vh"

module ifu_biu_mem(
    input  wire         clk,
    input  wire         rst,              // 高有效

    // ---- IFU BIU 主端 (rv32_ifu_top 的 ifu_biu_* 一侧) ----
    input  wire         ifu_biu_rd_req,
    input  wire [ 31:0] ifu_biu_rd_addr,  // 字节地址, [3:0]==0
    input  wire         ifu_biu_rd_id,    // 0=demand 1=prefetch
    input  wire [  1:0] ifu_biu_rd_len,   // 2'b11=4拍 2'b00=1拍
    output wire         biu_ifu_rd_grnt,
    output wire         biu_ifu_rd_data_vld,
    output wire [127:0] biu_ifu_rd_data,
    output wire         biu_ifu_rd_id,
    output wire         biu_ifu_rd_last,
    output wire [  1:0] biu_ifu_rd_resp,
    input  wire         ifu_biu_r_ready
);

// ---------------------------------------------------------------------------
// 两个独立在途上下文
// ---------------------------------------------------------------------------
reg        ctx_valid [0:1];
reg [31:0] ctx_base  [0:1];
reg [ 1:0] ctx_len   [0:1];
reg [ 1:0] ctx_beat  [0:1];

assign biu_ifu_rd_grnt = 1'b1;

wire launch = ifu_biu_rd_req & biu_ifu_rd_grnt;

// 仲裁: demand (ID0) 优先于 prefetch (ID1)。
wire       sel    = ctx_valid[0] ? 1'b0 : 1'b1;
wire [ 1:0] sel_id = sel ? 2'd1 : 2'd0;

// ---------------------------------------------------------------------------
// 指令 ROM: 4096 个 16 B 块 × 128 位 (mySoC/sync_mem.v)
//
// 区域只有 64 KB, 越界一律返回 0, 绝不让 X 进指令字 —— 越界的判断与数据一起
// 打拍 (rom_region_q), 保证它与 rom_a_q 指的是同一个块。
// ---------------------------------------------------------------------------
reg          rom_region_q;
wire [127:0] rom_q;

// fire 先于 launch 判 (见下面的 always): 极端情况下同拍对同一 ID 既有最后一拍
// 消费又有新请求时, 新事务覆盖旧事务, 不丢请求。
wire fire = biu_ifu_rd_data_vld & ifu_biu_r_ready;

// ---- 下一拍的 (ctx, beat) 预测 ----
// 下一拍被服务的是谁 = 下一个 ctx_valid[0] (仲裁是"demand 优先")
wire        ctx0_nxt = (launch & (ifu_biu_rd_id == 1'b0))            ? 1'b1
                     : (fire & (sel == 1'b0) & biu_ifu_rd_last)      ? 1'b0
                     :                                                 ctx_valid[0];
wire        sel_nxt  = ctx0_nxt ? 1'b0 : 1'b1;

// 下一拍 ctx[sel_nxt] 的 base 与 beat
wire [31:0] base_nxt = (launch & (ifu_biu_rd_id == sel_nxt)) ? ifu_biu_rd_addr
                                                             : ctx_base[sel_nxt];
wire [ 1:0] beat_nxt = (launch & (ifu_biu_rd_id == sel_nxt)) ? 2'd0
                     : (fire & (sel == sel_nxt) & ~biu_ifu_rd_last)
                       ? (ctx_beat[sel_nxt] + 2'd1)
                     : ctx_beat[sel_nxt];

// 行内块号 = 请求块 + beat (模 4) —— 即 64 B 行内的 WRAP
wire [ 2:0] blk_nxt  = {1'b0, base_nxt[5:4]} + {1'b0, beat_nxt};
wire [31:0] addr_nxt = {base_nxt[31:6], blk_nxt[1:0], 4'b0};

// ⚠️ **地址口是组合送的, 不能打拍**。ROM 自己的输出寄存器在边沿上采 `mem[rd_addr]`,
//    也就是说第 X 拍出来的数据对应的是**第 X-1 拍**地址口上的值。要让数据在第 X 拍
//    可用, 地址就必须在 X-1 拍已经在口上 —— 而 X-1 拍正是 launch 那一拍, 那时
//    ctx_base 还在被写, 只有 ifu_biu_rd_addr 是有效的。所以 addr_nxt 既要预测
//    "下一拍轮到谁", 也必须**直接驱动地址口** (第一版把它打了一拍, 数据整体晚一拍,
//    取指全 0 —— 症状是 difftest 在第 95 拍第一次提交就对不上)。
sync_rom_1r1w #(
    .ADDR_W (12),                 // 4096 块 = 64 KB
    .DATA_W (128)
) u_rom (
    .clk     (clk),
    .rd_addr (addr_nxt[15:4]),
    .rd_data (rom_q)
);

// 越界标志与 rd_q 同拍对齐 (它也反映"上一拍地址口上的那个块")
always @(posedge clk) begin
    if (rst) rom_region_q <= 1'b0;
    else     rom_region_q <= (addr_nxt[31:16] == 16'h0);
end

assign biu_ifu_rd_data_vld = ctx_valid[sel];
assign biu_ifu_rd_data     = rom_region_q ? rom_q : 128'b0;
assign biu_ifu_rd_id       = sel;
assign biu_ifu_rd_last     = (ctx_len[sel] == 2'b11) ? (ctx_beat[sel] == 2'd3)
                                                      : (ctx_beat[sel] == 2'd0);
assign biu_ifu_rd_resp     = 2'b00;

always @(posedge clk) begin
    if (rst) begin
        // ctx_* 全部清掉。原来不打拍时它们只被 ctx_valid 门控, 是 X 也无所谓;
        // 现在 addr_nxt 是**组合**喂给 ROM 地址口的, 不清就会把 X 送到地址口上。
        ctx_valid[0] <= 1'b0;
        ctx_valid[1] <= 1'b0;
        ctx_base [0] <= 32'b0;
        ctx_base [1] <= 32'b0;
        ctx_len  [0] <= 2'b00;
        ctx_len  [1] <= 2'b00;
        ctx_beat [0] <= 2'b00;
        ctx_beat [1] <= 2'b00;
    end else begin
        // fire 先判, launch 后判: 若极端情况下同拍对同一 ID 既有最后一拍
        // 消费又有新请求 (IFU 的 outstanding_q 在 last 拍边沿清掉, 正常不会
        // 同拍), 新事务覆盖旧事务, 不丢请求。
        if (fire) begin
            if (biu_ifu_rd_last) ctx_valid[sel] <= 1'b0;
            else                 ctx_beat[sel]  <= ctx_beat[sel] + 2'd1;
        end
        if (launch) begin
            ctx_valid[ifu_biu_rd_id] <= 1'b1;
            ctx_base [ifu_biu_rd_id] <= ifu_biu_rd_addr;
            ctx_len  [ifu_biu_rd_id] <= ifu_biu_rd_len;
            ctx_beat [ifu_biu_rd_id] <= 2'd0;
        end
    end
end

endmodule
