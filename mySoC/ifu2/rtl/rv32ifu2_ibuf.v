`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_ibuf — 指令队列 (3 入 / 3 出 / 环形)
//
// 它在整个 2 级设计里承担一个关键职责: **把取指侧的"参差不齐"吸收掉**。
//
// F1 每拍能交付几条, 取决于 PC 落在 16 B 块内的偏移: 偏移 0 时有 4 条可选,
// 偏移 1 时只剩 3 条, 偏移 3 时只剩 1 条; 再叠加"队列只剩 1 个空位"这类反压,
// 交付条数会抖动。C910 的解法是让 IP 反复重处理同一个块、把片段凑成对齐前缀
// (fragment / prefix / PCFIFO 拆分), 状态机很大。本设计的解法是**取消"包"**:
// 逐 lane 独立有效, 队列吸收抖动, 消费侧只看队列深度。于是那套机制整体消失。
//
// 空队列旁路: 队列空时本拍推进来的条目直接出现在输出口 —— 否则每次误预测后
// 头一条指令都要白等一拍, 正好吃掉 2 级流水省下来的那一拍。
// 旁路代价是 acc_push 不能再依赖 pop_num (会形成组合环), 见下。
// ===========================================================================
module rv32ifu2_ibuf #(
    parameter DEPTH = 8,               // 必须是 2 的幂
    parameter W     = 153              // {chk[24:0], idu_packet[127:0]}
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- 冲刷: 重定向当拍清空。取指侧已经切到新路径, 队列里剩下的全是
    //      错误路径的指令; 当拍正在交付的那条也一样会被核心丢弃(if_accept=0)。
    input  wire         flush,

    // ---- 入队 (来自 F1), 逐 lane 有效 ----
    // ⚠️ 入队侧 4 宽、出队侧仍是 3 宽 (核心是 3 发射)。两侧不等宽是**有意的**:
    //    一个 16 B 块正好 4 条指令, 只有把宽度做到 4 才能"一块一拍推完"。
    //    否则 fetch 侧被 3 卡住: 4 条要推两拍 (3+1), 直线代码封顶 2 IPC ——
    //    这条顶压在目标 3 发射之下。出队侧保持 3 是核心自己的消费上限。
    // [W2.3] 推进掩码: 取指侧已经把"本块剩余 / taken 截断 / 队列空位"三条
    // 前缀条件交好了 (见 rv32ifu2_top.v 的同名注释), 这里不再做 min/mux ——
    // 掩码天然是前缀, 直接当写使能用, popcount 就是 acc_push。
    input  wire [  3:0] push_mask,
    input  wire [W-1:0] push_data0,
    input  wire [W-1:0] push_data1,
    input  wire [W-1:0] push_data2,
    input  wire [W-1:0] push_data3,

    // 实际收下了几条 = 掩码的 popcount。取指侧必须**按它**推进 PC —— 按想推的
    // 条数推进会跳过队列没装下的那几条, 那是静默丢指令, difftest 会抓但很难查。
    output wire [  2:0] push_accept,

    // ---- 出队 (到 IDU), 逐 lane 有效 ----
    output wire [W-1:0] out_data0,
    output wire [W-1:0] out_data1,
    output wire [W-1:0] out_data2,
    output wire [  2:0] out_vld,
    // ⚠️ 2026-10-11 **语义变更**: `pop_num` 从"必须正好是 out_vld 的连续前缀"
    //    (义务在消费端) 改成**上限 (cap)** —— 本模块按有效前缀截断, 见 `pop_eff`。
    input  wire [  1:0] pop_num,       // 最多弹几条; 实际按 out_vld 的有效前缀截断

    // ---- 状态 ----
    // 端口表里不能用 localparam (声明顺序在它之前), 直接写 $clog2
    output wire [$clog2(DEPTH):0] count,
    output wire         full
);

localparam AW = $clog2(DEPTH);

reg [W-1:0]  ent_q [0:DEPTH-1];
reg [AW-1:0] head_q;
reg [AW+1:0] cnt_q;                    // 0..DEPTH, 要比索引宽

// ---------------------------------------------------------------------------
// 空位
//
// ⚠️ 这里刻意**不**把本拍的 pop_num 算进空位: 算了的话 acc_push 会依赖
// pop_num, 而 pop_num 来自核心的 if_accept, if_accept 又依赖 out_vld,
// out_vld 在空队列时依赖 acc_push —— 一条完整的组合环。少算这一格只是让
// 队列实际可用深度少 1, DEPTH=8 且一拍最多推 3 条, 完全不心疼。
// (空位截断现在由取指侧的 push_mask 做, 这里只把它读出来给 full/掩码用。)
// ---------------------------------------------------------------------------
wire [AW+1:0] space = DEPTH[AW+1:0] - cnt_q;

wire [2:0] acc_push = {1'b0, push_mask[0]} + {1'b0, push_mask[1]}
                    + {1'b0, push_mask[2]} + {1'b0, push_mask[3]};

assign push_accept = acc_push;

wire empty = (cnt_q == 0);

// ---------------------------------------------------------------------------
// 输出: 空队列走上限旁路, 否则读环形缓冲
// ---------------------------------------------------------------------------
wire [AW-1:0] idx0 = head_q;
wire [AW-1:0] idx1 = head_q + {{(AW-1){1'b0}}, 1'b1};
wire [AW-1:0] idx2 = head_q + 2'd2;

assign out_data0 = empty ? push_data0 : ent_q[idx0];
assign out_data1 = empty ? push_data1 : ent_q[idx1];
assign out_data2 = empty ? push_data2 : ent_q[idx2];

assign out_vld[0] = empty ? push_mask[0] : 1'b1;
assign out_vld[1] = empty ? push_mask[1] : (cnt_q >= 2);
assign out_vld[2] = empty ? push_mask[2] : (cnt_q >= 3);

// ---------------------------------------------------------------------------
// 实际弹出条数 = min(pop_num, 有效前缀数)      [2026-10-11 新增]
// ---------------------------------------------------------------------------
// `pop_num` 是**上限**而不是确数, 这里做截断。为什么必须自己截 (整核冒烟台实测):
//
//   消费端 (C910 IDU) 的 `idu_accept_num` 是**纯组合**地从它自己的停顿/模式算出来的,
//   **完全不看 IFU 手上到底有几条有效**。复位后本队列是空的 (`out_vld=000`)、
//   IDU 又没停顿 ⇒ 它报"收 3 条"。而下面的
//       cnt_q <= cnt_q + acc_push - pop_num
//   **没有下溢保护**: 0 - 3 在 5 位无符号里回卷成 **29** ⇒ `empty` 永远为假 ⇒
//   `out_vld[0]` **无条件**拉 1 ⇒ 读出从没写过的 `ent_q[head_q]` = **X**, 整核死。
//   而且**回不去**: cnt_q 每拍 -3 却永远踩不到 0, 只有 rst/flush 能清。
//
// 消费端那边也在修 cap (`ct_idu_id_ctrl.sv` 的 `idu_ifu_inst2_ready`, `|`→`&`) ——
// 但那修的是"IDU 最多能吃几条", 治不了"队列里根本不够"。**队列计数器不许减到负
// 是队列自己的常识**, 所以在这里兜。
//
// ⚠️ 这改变了本模块的接口语义 (端口表那条注释同步改了): 原来是"pop_num 必须是
//    out_vld 的连续前缀", 现在是"pop_num 是上限, 本模块按有效前缀截断"。
//    等价性的依据: IDU 消费的**恰好是** IFU 的有效前缀 (见 `ct_idu_id_ctrl.sv:25-34`
//    的 pipedown 三式), 所以 `min(cap, 前缀数)` 正是它实际吃掉的条数。
//    在这边算而不是在 IDU 里算, 是因为那样会造出 `IFU out_vld →(跨模块)→ accept_num
//    →(跨回来)→ cnt_q` 的往返组合路径; 留在本模块则 `pop_num` 只单向跨一次。
wire [1:0] pop_avail = ~out_vld[0] ? 2'd0 :
                       ~out_vld[1] ? 2'd1 :
                       ~out_vld[2] ? 2'd2 : 2'd3;
wire [1:0] pop_eff   = (pop_num < pop_avail) ? pop_num : pop_avail;

assign count = cnt_q;                  // 直接给全宽: 截位会让"满队列=8"读成 0
assign full  = (space == 0);

// ---------------------------------------------------------------------------
// 写入端口: 寄存器化 one-hot 写指针 (2026-10-19)
//
// 原来队尾 = head_q + cnt_q, 再用动态下标写 ent_q[w*]。综合/布局后这是一张
// 8→(W×8) 的写译码: head/cnt 的地址位扇出到所有表项位 (routed: fo=332/466,
// 9.4ns 纯 route), 是 IFU 内部最差路径。
//
// 改成 one-hot 写指针:
//   * wptr_q 是寄存器, 指向下一个空位;
//   * 4 条写 lane 的使能 = wptr_q 的常量左旋 0/1/2/3 (纯连线, 无译码);
//   * push 时 wptr_q 左旋 acc_push 位 (0..4); pop 不改变队尾;
//   * 不变式: wptr_q = 1 << ((head_q + cnt_q) mod DEPTH), 与旧 w0 逐位等价。
//
// 使能源从"组合译码网"变成"寄存器位": 可按 max_fanout 复制, 贴着表项摆放,
// 高扇出长走线从写地址路径里消失。
// ---------------------------------------------------------------------------
(* max_fanout = 16 *) reg [DEPTH-1:0] wptr_q;

wire [DEPTH-1:0] wl0 = wptr_q;                                  // tail + 0
wire [DEPTH-1:0] wl1 = {wptr_q[DEPTH-2:0], wptr_q[DEPTH-1]};    // tail + 1
wire [DEPTH-1:0] wl2 = {wl1[DEPTH-2:0], wl1[DEPTH-1]};          // tail + 2
wire [DEPTH-1:0] wl3 = {wl2[DEPTH-2:0], wl2[DEPTH-1]};          // tail + 3
wire [DEPTH-1:0] wptr4 = {wl3[DEPTH-2:0], wl3[DEPTH-1]};        // tail + 4

wire [DEPTH-1:0] wptr_nxt = (acc_push == 3'd0) ? wptr_q :
                            (acc_push == 3'd1) ? wl1    :
                            (acc_push == 3'd2) ? wl2    :
                            (acc_push == 3'd3) ? wl3    : wptr4;

genvar e;
generate
for (e = 0; e < DEPTH; e = e + 1) begin : g_ent
    // 同一表项最多被一条 lane 命中 (w0..w3 是 4 个连续且互异的 one-hot 位)
    wire we0 = push_mask[0] & wl0[e];
    wire we1 = push_mask[1] & wl1[e];
    wire we2 = push_mask[2] & wl2[e];
    wire we3 = push_mask[3] & wl3[e];
    always @(posedge clk) begin
        if (!(rst | flush)) begin
            if (we0) ent_q[e] <= push_data0;
            if (we1) ent_q[e] <= push_data1;
            if (we2) ent_q[e] <= push_data2;
            if (we3) ent_q[e] <= push_data3;
        end
    end
end
endgenerate

always @(posedge clk) begin
    if (rst | flush) begin
        head_q <= {AW{1'b0}};
        cnt_q  <= {(AW+2){1'b0}};
        wptr_q <= {{(DEPTH-1){1'b0}}, 1'b1};              // 空队列: 队尾 = 0
    end else begin
        head_q <= head_q + pop_eff;                       // ← 截断后的实际条数
        cnt_q  <= cnt_q + acc_push - pop_eff;
        wptr_q <= wptr_nxt;
    end
end

endmodule
