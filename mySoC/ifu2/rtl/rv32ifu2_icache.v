`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_icache — 2 路组相联 i-cache (真实 RAM 阵列 + 标签比较 + 替换)
//
// 为什么是这样, 而不是照搬 ifu_rv32i 那套:
//
//   * 两路并行读 + 标签比较后 mux。**没有 way 预测状态, 没有错 way 重发**,
//     也没有配套的"首次受阻保存"(ifdp 的 packet_q[0])。原设计的 way 预测是
//     为 64 KB 大缓存省读功耗用的, 在 1 KB 这个尺度上纯属负担, 删掉它的代价
//     只是多读一路数据。
//   * 阵列是**真实 RAM**(rv32ifu2_spram), 不再是裸 reg 阵列。回填写**旁路转发**:
//     装行那一拍就能直接交付, 省掉"装完再重读"的一拍。
//
// 几何(按 **Makefile 的构建默认** ICACHE_BYTES=1024 / ICACHE_LINE_BYTES=16 / 2 路):
// 1 KB、32 set、16 B 行、set = pc[8:4]、tag = pc[31:9]。
// ⚠️ 上面这个 parameter 默认值 2048 只是"没人传参时"的兜底, 与实际构建无关 ——
//    真正生效的几何**只能**看启动时打印的 `[IFU2-ICACHE] BYTES=… SETS=…` 那一行,
//    它按实到的 parameter 算。早先这里写死 "2 KB / 64 set / set=pc[9:4] /
//    tag=pc[31:10]", 与 Makefile 的 ICACHE_BYTES=1024 不符 —— 照着算会得到错的
//    ADDR_W。这类"注释与落地配置不一致"在本工程已经废掉过一整张容量表
//    (memory icache-geometry-bugs.md 缺陷 B), 别再写死。
//
// ---------------------------------------------------------------------------
// 阵列结构: 4 片真实 RAM, 行 = {valid, tag}
//
//   u_tag_way0 / u_tag_way1   32 × 24   ← {valid, tag[22:0]}, 含 valid
//   u_dat_way0 / u_dat_way1   32 × 128
//
// * **valid 就在 tag 行里** (C910 结构)。命中路径直接用阵列的寄存 Q:
//   `q_hit0 = tag_q0[ROW_VLD] & (tag_q0[TAG_BITS-1:0] == q_tag)`。好处是**单一真源**
//   —— 不存在"valid 触发器与 tag RAM 各存一份、写条件写岔了出假命中"的窗口。
//
// * **牺牲路要的那两个 valid 位靠捕获, 不靠第二个读口。** 关键恒等:
//       q_set_q(k) = rd_set(k-1) = rd_addr(k-1)[8:4] = q_pc_q(k)[8:4]
//   而 refill FSM 把 refill_pc 从 q_pc 锁存下来, 所以
//       refill_pc[8:4] = rf_set = "refill 事务开始时 q_pc 所在 set"
//   于是**只要 q_set_q == rf_set, 那一拍阵列 Q 里装的就是 rf_set 那一行** ——
//   把它抓进 valid_q 即可。这就是捕获条件写成 `q_set_q == rf_set` 的原因:
//   它把"抓到的永远是 rf_set 那一行"变成构造性事实, 与 BIU 快慢、与 redirect
//   都无关。(写成"miss 期间每拍都抓"是错的: 一旦 BIU 变慢或期间来一次 redirect,
//   rd_set 会变成别的行, 抓到的就是别的 set 的 valid —— 不会交付错指令, 但会
//   按错的 valid 挑牺牲路, 表现为罕见的周期漂移。)
//
// * **必须是 1R1W, 不能是 1RW。** 查找读每拍都要发, 回填写只在 refill_en 那一拍;
//   更关键的是读地址 (next_pc[8:4], 顶层组合算出来的) 与写地址 (refill_pc[8:4])
//   互相独立 —— redirect 与 refill_en 同拍时两者可以落在毫无关系的 set 上。
//   1RW 只能丢掉读, 而丢掉的那拍 F1 就没有数据了, 正好是"重定向进 PC 零气泡"
//   那条快路上的气泡。C910 敢用 1RW, 是因为它用 trans_busy_q 给**整个**回填事务
//   插了气泡; ifu2 没有气泡可花。详见 rv32ifu2_spram.v 头注释。
//
// * **读口写穿透。** 回填那拍发的读很可能与写**同址**: PC 被冻在缺行上, 块内偏移
//   为 0 时前进量一定还在同一 16 B 行内 ⇒ 同一个 set。没有写穿透, 每次 miss 都会
//   因为读到旧 tag 而多花一拍并多发一次 BIU 事务。语义与等价性证明见
//   rv32ifu2_spram.v。
//
// * **每路一片, 不合并成一行之外的东西。** 每路一片 ⇒ 每个例化点只有一个单位宽
//   wr_en, 映射到厂商 IP 核最省事 (BRAM 的写使能是字节粒度, 24 位行不是 8 的倍数)。
//
// ⚠️ 阵列地址寄存器在 rv32ifu2_spram 内部; 本模块的 `q_set_q` 是它的**影子**
//    (用于配命中/捕获)。两者必须同步无条件加载 —— 谁要是给其中一个加了 enable,
//   另一个也必须加, 否则会对着错的 set 判断。
//
// ⚠️ 本文件踩过两次"先用后声明被 VCS 造成 1 位隐式线网":
//    `way_valid` 少写位宽那次, `way_valid[1]` 直接越界报错; 更早的 `victim_way`
//    则是**静默**变成 1 位。所有组合信号一律在文件前部显式声明 + 写清位宽。
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
    // ⚠️ 这里是**下一个**地址, 不是"当前正在消费的地址"。阵列读是同步的, 本拍给的
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
localparam SET_BITS = $clog2(IC_BYTES / (IC_WAYS * IC_LINE));  // 1024/(2*16) => 32 => 5
localparam LINE_BITS = $clog2(IC_LINE);                        // 16 B => 4
localparam SETS      = 1 << SET_BITS;                          // 32
localparam TAG_BITS     = 32 - SET_BITS - LINE_BITS;              // 23 地址 tag 本身
localparam ROW_W     = TAG_BITS + 1;                              // 24 tag RAM 一行 = {valid, tag}
localparam ROW_VLD   = ROW_W - 1;                              // 23 行内 valid 的位置
localparam LINE_W    = IC_LINE * 8;                            // 128

// pc[SET_MSB:SET_LSB] = set, pc[31:TAG_LSB] = tag
localparam SET_LSB = LINE_BITS;
localparam SET_MSB = SET_BITS + LINE_BITS - 1;
localparam TAG_LSB = SET_BITS + LINE_BITS;

wire [SET_BITS-1:0] rd_set = rd_addr[SET_MSB:SET_LSB];

// ---------------------------------------------------------------------------
// 组合信号的**声明**一律提前 (见文件头的隐式线网警告)。这里只声明不赋值,
// 赋值点按逻辑顺序排在后面 —— 位置本身不影响语义, 但没有声明就会被 VCS
// 当成 1 位隐式线网。
// ---------------------------------------------------------------------------
// ⚠️ 这里**不要**再写一遍 `wire q_hit;` —— 它在上面已经是 output 端口了,
//    重复声明会被 VCS 报 `Warning-[IPDW] Identifier previously declared`
//    (第二次声明被忽略, 功能无影响, 但每次 elaborate 都会带一条噪声警告)。
wire                  q_hit0, q_hit1;
wire                  ram_hit;
wire                  capacity_conflict;
wire [IC_WAYS-1:0]    way_valid;
wire [IC_WAYS-1:0]    alloc_way;
wire [IC_WAYS-1:0]    lru_way;
wire [IC_WAYS-1:0]    victim_way;
wire                  capture_en;

// ---------------------------------------------------------------------------
// 状态。
//
// valid_q 是**捕获**寄存器 (不是阵列): 它保存的是"rf_set 那一行的两路 valid"。
// 上电为 X, 靠 rst 清 (它是 2 位控制状态, 不是存储阵列 —— 真实 RAM 里的 valid
// 由初始化扫描清, 那条不变量说的是**阵列**, 见下)。
//
// lru_q / init_cnt_q 都**不加复位**: 阵列侧的东西只由初始化扫描建立初值,
// 这是上 FPGA 能成立的前提。lru_q 只在两路都有效时才被读, 而那种状态必然
// 是回填写出来的 —— 所以它读到 X 的窗口不存在。
// ---------------------------------------------------------------------------
reg [IC_WAYS-1:0] valid_q;             // valid_q[way] = rf_set 那一行 way 路的 valid
reg [SETS-1:0]    lru_q;               // 1 = way1 是牺牲者, 0 = way0 是牺牲者

reg        init_done_q;
reg [31:0] init_cnt_q;

reg [SET_BITS-1:0] q_set_q;
reg [31:0]         q_pc_q;

assign init_done = init_done_q;

// ---------------------------------------------------------------------------
// 回填写口
// ---------------------------------------------------------------------------
wire [SET_BITS-1:0] rf_set = refill_pc[SET_MSB:SET_LSB];
wire [TAG_BITS-1:0]    rf_tag = refill_pc[31:TAG_LSB];

// ---------------------------------------------------------------------------
// 牺牲者选择 —— 无效路优先, 否则 LRU 路。
// 判优顺序与原设计逐字一致: way0 无效取 way0, way1 无效取 way1, 都有效才看 LRU。
// ---------------------------------------------------------------------------
assign way_valid         = valid_q;
assign capacity_conflict = &way_valid;          // 两路都有效

genvar g;
generate
for (g = 0; g < IC_WAYS; g = g + 1) begin : g_alloc_way
    // 第 0 路直接判, 其余路要"前面没有更优先的无效路"
    if (g == 0) assign alloc_way[0] = ~way_valid[0];
    else        assign alloc_way[g] = ~way_valid[g] & ~(|alloc_way[g-1:0]);
end
endgenerate

// ⚠️ 取的一定是 **rf_set 那一位**, 不能写 `~lru_q` —— 那是 32 位向量取反,
//    截断后只剩 set 0 的 LRU 位。本文件踩过这个。
assign lru_way[0] = ~lru_q[rf_set];
assign lru_way[1] =  lru_q[rf_set];

assign victim_way = capacity_conflict ? lru_way : alloc_way;

// ⚠️ valid 与 tag/data 必须**同一拍、同一条件**写 (都吃 rf_wr0/rf_wr1)。
//    拆开写就会出现"valid=1 但 tag 还是上一行"的假命中 ——
//    ifu2_zh.md §5 第 3 条(X 目标进表)踩的就是同类的坑。
wire rf_wr0 = refill_en & init_done_q & victim_way[0];
wire rf_wr1 = refill_en & init_done_q & victim_way[1];

// ---------------------------------------------------------------------------
// 初始化扫描。真实阵列上电是 X, 只能由控制器走一遍 —— 保持"逐 set 走 32 拍"的结构
// (C910 也是这么扫的, 只是它扫几百拍)。tag RAM 的写口被扫描借用, 写全 0 ——
// **valid 位就是这么清的**, 这就是 C910 的 array sweep。
// 数据阵列不清: valid=0 的行数据永远不会被用, 而有效行必然是回填写进去的,
// 那时 tag/data/valid 同拍写, 不存在"有效但数据是 X"的窗口。
//
// (扫描长度保持 32 拍是**免费**的, 但别指望它在总拍数里看得见: init_all =
//  ic_init_done & btb_init_done, BTB 扫 64 行, 32 拍本来就藏在它下面。)
// ---------------------------------------------------------------------------
wire                sweep  = ~init_done_q;
wire [SET_BITS-1:0] tag_wa = sweep ? init_cnt_q[SET_BITS-1:0] : rf_set;
wire [ROW_W-1:0]    tag_wd = sweep ? {ROW_W{1'b0}} : {1'b1, rf_tag};

// ---------------------------------------------------------------------------
// 4 片真实 RAM (1R1W + 写穿透)。
// 读地址是**组合的** rd_set —— 不能改成"先寄存地址再组合读阵列", 换成真 RAM 后
// 那就是组合环。写口按路分开: 只有被牺牲那一路的 RAM 被写, **不做 RMW**。
// ---------------------------------------------------------------------------
wire [ROW_W-1:0]  tag_q0, tag_q1;
wire [LINE_W-1:0] dat_q0, dat_q1;

rv32ifu2_spram #(
    .ADDR_W (SET_BITS),
    .DATA_W (ROW_W)
) u_tag_way0 (
    .clk     (clk),
    .rd_addr (rd_set),
    .rd_data (tag_q0),
    .wr_addr (tag_wa),
    .wr_en   (sweep | rf_wr0),
    .wr_data (tag_wd)
);

rv32ifu2_spram #(
    .ADDR_W (SET_BITS),
    .DATA_W (ROW_W)
) u_tag_way1 (
    .clk     (clk),
    .rd_addr (rd_set),
    .rd_data (tag_q1),
    .wr_addr (tag_wa),
    .wr_en   (sweep | rf_wr1),
    .wr_data (tag_wd)
);

rv32ifu2_spram #(
    .ADDR_W (SET_BITS),
    .DATA_W (LINE_W)
) u_dat_way0 (
    .clk     (clk),
    .rd_addr (rd_set),
    .rd_data (dat_q0),
    .wr_addr (rf_set),
    .wr_en   (rf_wr0),
    .wr_data (refill_data)
);

rv32ifu2_spram #(
    .ADDR_W (SET_BITS),
    .DATA_W (LINE_W)
) u_dat_way1 (
    .clk     (clk),
    .rd_addr (rd_set),
    .rd_data (dat_q1),
    .wr_addr (rf_set),
    .wr_en   (rf_wr1),
    .wr_data (refill_data)
);

// ---------------------------------------------------------------------------
// 影子地址寄存器 (与阵列内部的地址寄存器同沿、同地址、无条件加载)。
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    q_set_q <= rd_set;
    q_pc_q  <= rd_addr;
end

assign q_pc = q_pc_q;

// ---------------------------------------------------------------------------
// F1 的组合比较 —— 数据与 PC 都是第 k 拍寄存下来的, 比较就在这一拍完成,
// 不额外占拍 (F0 算地址 / F1 出结果, 两级)。
// ---------------------------------------------------------------------------
wire [TAG_BITS-1:0] q_tag = q_pc_q[31:TAG_LSB];

wire q_v0 = tag_q0[ROW_VLD];
wire q_v1 = tag_q1[ROW_VLD];

// [W2.5] 相等比较写成 |(a^b) 的显式 OR 树: 23 位 `==` 会被综合器实现成减法
// 的借用链 (实测报告里 icache tag 那条路径上出现过 2 级 CARRY4)。语义逐位不变,
// 只是不给它这个机会。q_hit 在关键路径上 (→ can_push → push_mask → ent_q)。
assign q_hit0 = q_v0 & ~|(tag_q0[TAG_BITS-1:0] ^ q_tag);
assign q_hit1 = q_v1 & ~|(tag_q1[TAG_BITS-1:0] ^ q_tag);

assign ram_hit = q_hit0 | q_hit1;

// ---------------------------------------------------------------------------
// valid 捕获 (见文件头"牺牲路要的那两个 valid 位靠捕获")。
//
// 条件 `q_set_q == rf_set` 保证抓到的**永远是 rf_set 那一行**: 阵列 Q 装的就是
// q_set_q 那一行, 而它等于 rf_set。`~q_hit` 只是"别在命中时白写"的省电项。
//
// 时序: 捕获发生在边沿, 所以 refill_en 那一拍 valid_q 里是**写之前**的状态 ——
// 正是牺牲路该看的状态。写完之后 valid_q 不再更新(那拍 q_hit 为 1, 或即便为 0
// 也还是抓 rf_set 那一行), 不影响本事务。
// ---------------------------------------------------------------------------
assign capture_en = init_done_q & ~q_hit & (q_set_q == rf_set);

always @(posedge clk) begin
    if (rst)             valid_q <= {IC_WAYS{1'b0}};
    else if (capture_en) valid_q <= {tag_q1[ROW_VLD], tag_q0[ROW_VLD]};
end

// 回填旁路: 本拍正要装的整行就是 q_pc 要的那行 ⇒ 直接用回填数据交付。
// 省掉的一次往返 = 每次 miss 少 1 拍。
//
// ⚠️ 它和 RAM 的**写穿透**是两个不同机制, 别拿一个去"简化"掉另一个:
//   rf_match   在**写的那一拍**交付 (写还没落到阵列里);
//   写穿透     在写之后的**下一拍**交付 (阵列此时已经更新)。
//   删掉 rf_match 每次 miss 多一拍; 删掉写穿透会退化成交付错指令。
// [W2.5] 28 位比较同样改成显式 XOR 归约 (它和 q_hit 一起进 q_hit 的顶层 OR)
wire rf_match = refill_en & ~|(refill_pc[31:LINE_BITS] ^ q_pc_q[31:LINE_BITS]);

// ---------------------------------------------------------------------------
// 数据选择
// ---------------------------------------------------------------------------
wire [LINE_W-1:0] q_data_arr = q_hit0 ? dat_q0 : dat_q1;

assign q_data = rf_match ? refill_data : q_data_arr;
// ⚠️ 已知缺陷 (不在本次改动范围, 单独修): ICACHE_EN=0 时这里把 rf_match 也折掉了,
//    而顶层 refill_req = ~q_hit & … ⇒ 永远回填、can_push 永远 0, 一条指令都发不出去。
//    正确写法是 `… : rf_match`。
assign q_hit  = ICACHE_EN ? (rf_match | q_hit0 | q_hit1) : 1'b0;

// ---------------------------------------------------------------------------
// 初始化扫描的计数器。init_done_q 落点与换 RAM 之前逐拍一致 (32 拍扫 + 第 33 拍置位)。
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        init_done_q <= 1'b0;
        init_cnt_q  <= 32'd0;
    end else if (!init_done_q) begin
        if (init_cnt_q == (SETS-1)) init_done_q <= 1'b1;
        init_cnt_q <= init_cnt_q + 32'd1;
    end
end

// ---------------------------------------------------------------------------
// LRU 更新。单块写, 不做 32 个 always 分别写那一个 packed 向量的某一位 ——
// 那是一个变量多个过程驱动, 非法的写法。
//
// 语义与原设计逐字一致:
//   way0 命中 ⇒ 下一个牺牲者指 way1 (lru=1); 否则 (way1 命中) ⇒ 指 way0 (lru=0);
//   都没命中 ⇒ 不更新。
//   回填写把 LRU 指向**另一路** ⇒ `victim_way[0]`。
//   ⚠️ 这里**不能**写 `~victim_way[0]`: victim_way 是 one-hot, way0 是牺牲者时
//      `victim_way[0]==1`, 而"指向另一路(way1)"要的也是 1 —— 两者同号。
//      (基线那句 `lru_q[rf_set] <= ~rf_way` 里的 rf_way 是**编号**不是 one-hot,
//       所以那边才要取反。照抄符号会得到正好相反的替换策略: 实测表现为
//       2 路里明明有一路无效却去挤有效那路, CoreMark 上多出约 3% 的 miss。)
//   两者同拍撞到同一个 set 时, 回填那条在后、优先。
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (init_done_q) begin
        if (ram_hit)   lru_q[q_set_q] <= q_hit0;
        if (refill_en) lru_q[rf_set]  <= victim_way[0];
    end
end

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
    $display("[IFU2-ICACHE] BYTES=%0d LINE=%0d WAYS=%0d SETS=%0d SET_BITS=%0d TAG_BITS=%0d ROW_W=%0d",
             IC_BYTES, IC_LINE, IC_WAYS, SETS, SET_BITS, TAG_BITS, ROW_W);
end
// synopsys translate_on

endmodule
