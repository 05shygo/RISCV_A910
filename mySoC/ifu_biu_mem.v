`timescale 1ns / 1ps
`define STRINGIFY(x) `"x`"

// ===========================================================================
// IFU BIU 从端 + 指令 ROM (ifu_biu_mem)
//
// 给 rv32_ifu_top 的 BIU 主端口提供存储。协议要点 (与 doc/icache_zh.md、
// RV32I_C910_IFU_interface_v1.1_noMMU.xlsx P05/P06/P07 一致):
//   - req && grnt 在时钟边沿接受一笔事务; 本从端 grnt 恒 1。
//   - rd_id: 0 = demand, 1 = prefetch。两路各最多一笔在途, 路内保序,
//     两路可交错返回。返回必须回显 rd_id —— IFU 用它选内部 ready。
//   - rd_len: 2'b11 = 4 拍 (64B 行), 2'b00 = 单拍。last 必须打在
//     第 3 拍 / 第 0 拍, 打错会被 IFU 判为协议错, 每次取指都变故障。
//   - 拍序是 64B 行内以请求的 16B 块为首的 WRAP: 块号 = addr[5:4] + beat (模 4)。
//   - data_vld && ifu_biu_r_ready 才算一拍被消费; 不 ready 时全部返回信号保持。
//   - grant 当拍 IFU 内部的 outstanding 寄存器还没置位, 那拍不能驱动 data_vld。
//   - resp: 2'b00 = 成功 (IFU 只看 bit1)。
// ===========================================================================
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
// 指令镜像: 与 vsrc/ram.v 的 IROM 相同方式加载 `PATH (meminit.bin)。
// mem[j] 即字节偏移 4*j 处的 RV32 小端字。16K 字 = 64KB = 区域大小。
// ---------------------------------------------------------------------------
reg [31:0] mem    [0:16383];
reg [31:0] mem_rd [0:16383];
integer    i, j, mem_file;

initial begin
    for (i = 0; i < 16384; i = i + 128) begin
        for (j = i; j < i + 128; j = j + 1) mem[j] = 0;
    end
    mem_file = $fopen(`STRINGIFY(`PATH), "r");
    if (mem_file == 0) begin
        $display("[ERROR] Open file %s failed, please check whether file exists!\n", `STRINGIFY(`PATH));
        $fatal;
    end
    $display("[INFO] IFU instruction ROM initialized with %s", `STRINGIFY(`PATH));
    // 必须先清零: $fread 只填镜像覆盖到的部分, 其余保持 X, 而 X 会经返回
    // 拍流进 IFU 的指令字 (同 vsrc/ram.v 的坑)。
    for (i = 0; i < 16384; i = i + 128) begin
        for (j = i; j < i + 128; j = j + 1) mem_rd[j] = 0;
    end
    $fread(mem_rd, mem_file);
    for (i = 0; i < 16384; i = i + 128) begin
        for (j = i; j < i + 128; j = j + 1) begin
            mem[j] = {{mem_rd[j][07:00]}, {mem_rd[j][15:08]}, {mem_rd[j][23:16]}, {mem_rd[j][31:24]}};
        end
    end
end

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

// WRAP 拍地址: 行内块号 = 请求块 + beat (模 4)。
wire [2:0] blk      = {1'b0, ctx_base[sel][5:4]} + {1'b0, ctx_beat[sel]};
wire [31:0] beat_addr = {ctx_base[sel][31:6], blk[1:0], 4'b0};

// 区域只有 64KB, 越界一律返回 0, 绝不让 X 进指令字。
wire        in_region = (beat_addr[31:16] == 16'h0);
wire [13:0] waddr     = beat_addr[15:2];
wire [31:0] w0 = in_region ? mem[waddr + 14'd0] : 32'b0;
wire [31:0] w1 = in_region ? mem[waddr + 14'd1] : 32'b0;
wire [31:0] w2 = in_region ? mem[waddr + 14'd2] : 32'b0;
wire [31:0] w3 = in_region ? mem[waddr + 14'd3] : 32'b0;

assign biu_ifu_rd_data_vld = ctx_valid[sel];
assign biu_ifu_rd_data     = {w3, w2, w1, w0};
assign biu_ifu_rd_id       = sel;
assign biu_ifu_rd_last     = (ctx_len[sel] == 2'b11) ? (ctx_beat[sel] == 2'd3)
                                                      : (ctx_beat[sel] == 2'd0);
assign biu_ifu_rd_resp     = 2'b00;

wire fire = biu_ifu_rd_data_vld & ifu_biu_r_ready;

always @(posedge clk) begin
    if (rst) begin
        ctx_valid[0] <= 1'b0;
        ctx_valid[1] <= 1'b0;
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
