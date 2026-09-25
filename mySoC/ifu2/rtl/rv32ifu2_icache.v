`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_icache — 2 路组相联 i-cache (数据阵列 + 标签比较 + 替换)
//
// 为什么是这样, 而不是照搬 ifu_rv32i 那套:
//
//   * 两路并行读 + 标签比较后 mux。**没有 way 预测状态, 没有错 way 重发**,
//     也没有配套的"首次受阻保存"(ifdp 的 packet_q[0])。原设计的 way 预测是
//     为 64 KB 大缓存省读功耗用的, 在 2 KB 这个尺度上纯属负担, 删掉它的代价
//     只是多读一路数据。
//   * 阵列按"同步读"建模 (地址本拍给, 数据下拍用), 与真实 SRAM 语义一致。
//     ⚠️ 不要改成组合读: 那会拿到上一拍地址的旧数据, 与本拍 pc 的 tag 一比
//     反而"假命中" —— cpu 工程正是踩了这个坑 (cpu/sim/README.md:32-45)。
//     那边几个小表**应该**异步, 这里**应该**同步, 方向相反, 别照搬。
//   * 回填写**旁路转发**: 装行那一拍就能直接交付, 省掉"装完再重读"的一拍。
//
// 几何: 2 KB / 2 路 / 16 B 行 / 64 set。set = pc[9:4], tag = pc[31:10]。
// 16 B 行 = 单拍 128-bit 回填, 正是 ifu_biu_mem 从端原生支持的 rd_len=2'b00。
// ===========================================================================
module rv32ifu2_icache #(
    parameter IC_BYTES  = 2048,
    parameter IC_LINE   = 16,
    parameter IC_WAYS   = 2,         // 只实现了 2 路, 见下方断言
    parameter ICACHE_EN = 1          // 0 = 每次访问都算 miss (等价"关缓存", 不复用)
)(
    input  wire         clk,
    input  wire         rst,          // 高有效

    // ---- F0: 下一个要取的地址, 直接进阵列地址口 ----
    //
    // ⚠️ 这里是**下一个**地址, 不是"当前正在消费的地址"。阵列是同步读, 本拍给的
    // 地址要到下拍才有数据; 而 q_pc 恰好就是它下拍的值, 于是"q_pc 的数据"与
    // "q_pc" 天然对齐, 不需要第二份延迟寄存器。
    // 早先的写法是"给当前地址、再寄存一份 q_pc 做比较", 那样一旦取指停顿
    // (地址寄存器保持), q_pc 会把同一个地址连看两拍, 同一条指令被推进 IBUF 两次
    // —— 就是 difftest 报的重复提交。别再改回去。
    input  wire [ 31:0] rd_addr,

    // ---- F1: 上一拍那个地址的读结果 ----
    output wire [ 31:0] q_pc,         // = 上一拍的 rd_addr; F1 一切判断的基准
    output wire [127:0] q_data,       // 该 PC 所在的 16 B 整行
    output wire         q_hit,        // 该行在缓存里 (或本拍正被回填进来)

    // ---- 回填写口 (来自 rv32ifu2_refill, 与 q_* 同拍比较 => 少等一拍) ----
    input  wire         refill_en,
    input  wire [ 31:0] refill_pc,
    input  wire [127:0] refill_data,

    // ---- 状态 ----
    output wire         init_done
);

// ---------------------------------------------------------------------------
// 几何推导
// ---------------------------------------------------------------------------
localparam SET_BITS = $clog2(IC_BYTES / (IC_WAYS * IC_LINE));  // 2048/(2*16) => 64 => 6
localparam LINE_BITS = $clog2(IC_LINE);                        // 16 B => 4
localparam SETS      = 1 << SET_BITS;                          // 64
localparam TAG_BITS  = 32 - SET_BITS - LINE_BITS;              // 22
localparam LINE_W    = IC_LINE * 8;                            // 128

// pc[SET_MSB:SET_LSB] = set, pc[31:TAG_LSB] = tag
localparam SET_LSB = LINE_BITS;
localparam SET_MSB = SET_BITS + LINE_BITS - 1;
localparam TAG_LSB = SET_BITS + LINE_BITS;

wire [SET_BITS-1:0] rd_set = rd_addr[SET_MSB:SET_LSB];

// ---------------------------------------------------------------------------
// 阵列。tag_q 每位 = {valid, tag}。用寄存器阵列 + 同步读建模:
// 地址本拍给 (q_set_q 在边沿锁存), 数据下拍用。真实设计里这是 SRAM 宏。
// ---------------------------------------------------------------------------
reg [TAG_BITS:0] tag_q [0:IC_WAYS*SETS-1];
reg [LINE_W-1:0] dat_q [0:IC_WAYS*SETS-1];
reg              lru_q [0:SETS-1];     // 1 = way1 是牺牲者, 0 = way0 是牺牲者

reg [SET_BITS-1:0] q_set_q;
reg [31:0]         q_pc_q;

always @(posedge clk) begin
    q_set_q <= rd_set;
    q_pc_q  <= rd_addr;
end

assign q_pc = q_pc_q;

// ---------------------------------------------------------------------------
// F1 的组合比较 (声明放在用到它们的时序块之前 —— 本工程踩过
// "先用后声明被 VCS 造成 1 位隐式线网" 的坑, 不要依赖工具的宽松处理)
// ---------------------------------------------------------------------------
wire [TAG_BITS-1:0] q_tag = q_pc_q[31:TAG_LSB];

wire [TAG_BITS:0] t0 = tag_q[0*SETS + q_set_q];
wire [TAG_BITS:0] t1 = tag_q[1*SETS + q_set_q];

wire q_hit0 = t0[TAG_BITS] & (t0[TAG_BITS-1:0] == q_tag);
wire q_hit1 = t1[TAG_BITS] & (t1[TAG_BITS-1:0] == q_tag);

// 回填旁路: 本拍正要装的整行就是 q_pc 要的那行 ⇒ 直接用回填数据交付。
// 省掉的一次往返 = 每次 miss 少 1 拍。
wire rf_match = refill_en & (refill_pc[31:LINE_BITS] == q_pc_q[31:LINE_BITS]);

// ---------------------------------------------------------------------------
// 初始化扫描的完成标志。
//
// 为什么是扫描而不是"复位分支里 for 一遍": 阵列在真实设计里是 SRAM, 上电是
// X 而不是 0, 只能由控制器走一遍。保持同样的语义, 将来换 SRAM 宏不用改控制。
// 数据阵列不清 —— valid=0 的行数据永远不会被用。
// (声明必须在下面的 rf_wr* 之前 —— 本工程踩过"先用后声明被造成隐式线网"的坑)
// ---------------------------------------------------------------------------
reg        init_done_q;
reg [31:0] init_cnt_q;

assign init_done = init_done_q;

// ---------------------------------------------------------------------------
// 回填写: 牺牲者选择 —— 无效路优先, 否则 LRU 路
// ---------------------------------------------------------------------------
wire [SET_BITS-1:0] rf_set = refill_pc[SET_MSB:SET_LSB];
wire [TAG_BITS-1:0] rf_tag = refill_pc[31:TAG_LSB];
wire rf_v0  = tag_q[0*SETS + rf_set][TAG_BITS];
wire rf_v1  = tag_q[1*SETS + rf_set][TAG_BITS];
wire rf_way = (~rf_v0) ? 1'b0 : (~rf_v1) ? 1'b1 : lru_q[rf_set];

wire rf_wr0 = refill_en & init_done_q & (rf_way == 1'b0);
wire rf_wr1 = refill_en & init_done_q & (rf_way == 1'b1);

always @(posedge clk) begin
    if (rst) begin
        init_done_q <= 1'b0;
        init_cnt_q  <= 32'd0;
    end else if (!init_done_q) begin
        // 扫描期间把两路的 valid 清掉; 阵列索引就是计数器本身
        tag_q[0*SETS + init_cnt_q[SET_BITS-1:0]] <= {(TAG_BITS+1){1'b0}};
        tag_q[1*SETS + init_cnt_q[SET_BITS-1:0]] <= {(TAG_BITS+1){1'b0}};
        if (init_cnt_q == (SETS-1)) init_done_q <= 1'b1;
        init_cnt_q <= init_cnt_q + 32'd1;
    end else begin
        if (rf_wr0) begin
            tag_q[0*SETS + rf_set] <= {1'b1, rf_tag};
            dat_q[0*SETS + rf_set] <= refill_data;
        end
        if (rf_wr1) begin
            tag_q[1*SETS + rf_set] <= {1'b1, rf_tag};
            dat_q[1*SETS + rf_set] <= refill_data;
        end
        // 命中更新 LRU; 回填写把 LRU 指向另一路
        if (q_hit0)      lru_q[q_set_q] <= 1'b1;
        else if (q_hit1) lru_q[q_set_q] <= 1'b0;
        if (refill_en)   lru_q[rf_set]  <= ~rf_way;
    end
end

// ---------------------------------------------------------------------------
// 数据选择
// ---------------------------------------------------------------------------
wire [LINE_W-1:0] q_data_arr = q_hit0 ? dat_q[0*SETS + q_set_q]
                                      : dat_q[1*SETS + q_set_q];

assign q_data = rf_match ? refill_data : q_data_arr;
assign q_hit  = ICACHE_EN ? (rf_match | q_hit0 | q_hit1) : 1'b0;

// 只做了 2 路。真要 3 路以上得把上面的比较/选择展开成 generate —— 这里直接
// 挡住, 免得改了参数却悄悄只比较前两路, 那会变成"偶发取错指令"的疑难杂症。
// synopsys translate_off
initial begin
    if (IC_WAYS != 2) begin
        $display("[IFU2-ICACHE] IC_WAYS=%0d 未实现 (只支持 2)", IC_WAYS);
        $fatal;
    end
    // 打印落地参数。**扫点前先看这一行** —— 原树 icache 参数化就踩过
    // "改的 define 没进到 RTL, 于是所有'不同配置'其实是同一个配置, 整张容量表作废"
    // (memory icache-geometry-bugs.md 缺陷 B)。这一行就是防那个的。
    $display("[IFU2-ICACHE] BYTES=%0d LINE=%0d WAYS=%0d SETS=%0d SET_BITS=%0d TAG_BITS=%0d",
             IC_BYTES, IC_LINE, IC_WAYS, SETS, SET_BITS, TAG_BITS);
end
// synopsys translate_on

endmodule
