`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_top — 自研 2 级 3 发射前端
//
// 动机见 doc/ifu2_zh.md。一句话: 原 ifu_rv32i 是 C910 派生前端 (41 文件 /
// 14,967 行 / 3 级流水), 但实测性能并不优于别处 1,354 行的前端。本模块用
// 2 级流水重新表达同样的能力, 并保留 3 发射 —— 本核未来要做乱序多发射。
//
// 流水划分 (每级一个寄存器边界):
//
//   F0  pc_q ─┬─→ i-cache 阵列寻址 (set = pc[9:4], sync read)
//             └─→ BPU 异步查表 (Phase 2)
//                 ⇒ 下一 PC = 重定向 > 预测 > 顺序
//
//   F1  q_pc / q_data / q_hit ─→ 按偏移对齐 ≤3 条 ─→ IBUF ─→ IDU
//
// 与 C910 版的关键差异 —— 这些是"少掉的复杂度", 不是"少掉的功能":
//   * 取消"取指包": F1 逐 lane 交付 1~3 条, 由 IBUF 吸收抖动。于是 IP fragment /
//     prefix 切分 / PCFIFO credit-token 拆分整体消失。
//   * 两路并行读 + tag 比较后 mux: 没有 way 预测状态, 没有错 way 重发, 也没有
//     配套的"IFDP 首次受阻保存"。
//   * 无 LBUF / SFP / 间接 BTB / 调试 / 向量 / 多区域 / 断点 / precode 阵列。
//   * 误预测恢复不再走"多拍重填": pc 一拍内重定向, 新指令 2 拍后交付。
//
// Phase 1 (当前): i-cache + 回填 + IBUF + ragged 交付 ≤3 条。**尚无预测** ——
//   pred_npc 恒为 pc+4, 所以每条 taken 分支都靠 EX 重定向兜底。功能是对的,
//   只是慢; Phase 2 接 BPU 后才有预测。
// ===========================================================================
module rv32ifu2_top #(
    // ICACHE_EN=0 时缓存退化成"每次都 miss"(不复用), 用来量"缓存值多少分"
    parameter ICACHE_EN = 1,
    parameter BP_EN     = 1,
    // ---- 几何与表尺寸 ----
    //
    // 全部可由 Makefile 的 +define+ 覆盖, 这样扫点不用改 RTL (原 ifu_rv32i 的
    // ICACHE_BYTES / BP_* 是同一套做法)。⚠️ 用 define 驱动 parameter 而不是
    // 反过来: parameter 有默认值, 忘了接 define 的话扫出来的"不同配置"其实是
    // 同一个配置 —— 这正是原树 icache 参数化踩过的坑 (首版容量表全废)。
`ifdef ICACHE_BYTES
    parameter IC_BYTES  = `ICACHE_BYTES,
`else
    parameter IC_BYTES  = 1024,      // 与 Makefile 默认一致, 便于和 IFU=1 对照
`endif
`ifdef ICACHE_LINE_BYTES
    parameter IC_LINE   = `ICACHE_LINE_BYTES,
`else
    parameter IC_LINE   = 16,
`endif
    parameter IC_WAYS   = 2,
`ifdef BP_BTB_ROW_AW
    parameter BTB_ROW_AW = `BP_BTB_ROW_AW,
`else
    parameter BTB_ROW_AW = 6,        // 64 行 × 4 slot = 256 项
`endif
`ifdef BP_BHT_ROW_AW
    parameter BHT_ROW_AW = `BP_BHT_ROW_AW,
`else
    parameter BHT_ROW_AW = 9,        // 512 行 × 4 slot × 2bit = 4 Kbit
`endif
`ifdef BP_GHR_W
    parameter GHR_W      = `BP_GHR_W,// 全局历史宽度
`else
    parameter GHR_W      = 12,
`endif
    // RAS 深度 log2 (8 项) 与它在 chk 快照里占的位段
`ifdef BP_RAS
    parameter RAS_EN     = `BP_RAS,
`else
    parameter RAS_EN     = 0,        // 默认关: CoreMark 上它是 +0.25%, 见 doc §4
`endif
    parameter RAS_AW     = 3,
    parameter RAS_CHK_LSB = GHR_W,
    parameter RAS_CHK_MSB = GHR_W + RAS_AW,
    parameter CHK_BTBHIT  = GHR_W + RAS_AW + 1,   // chk 里"BTB 命中"标志位
    parameter CHK_PREDTK  = GHR_W + RAS_AW + 2,   // chk 里"预测方向"位
    // 哨兵参数: 上面每个 `ifdef 分支里的 parameter 都带逗号, 需要有一个
    // 无条件跟在最后的参数, 否则 `endif 之后直接是 `)(` 时列表尾会多一个逗号。
    // 以后往上面加参数也不会踩到这个。
    parameter _param_list_sentinel = 1'b0
)(
    input  wire         clk,
    input  wire         rst,              // 高有效

    // ---- IDU 交付 ----
    output wire         idu_inst0_vld,
    output wire [127:0] idu_inst0_data,
    output wire [ 24:0] idu_inst0_chk,
    output wire         idu_inst1_vld,
    output wire [127:0] idu_inst1_data,
    output wire [ 24:0] idu_inst1_chk,
    output wire         idu_inst2_vld,
    output wire [127:0] idu_inst2_data,
    output wire [ 24:0] idu_inst2_chk,
    output wire         idu_flush,        // 本模块内部冲刷, 当拍三槽 vld 全 0
    input  wire [  1:0] idu_accept_num,   // 同拍消费的前缀条数

    // ---- 后端重定向 (1 拍脉冲) ----
    input  wire         iu_chgflw_vld,    // EX 级分支/JAL/JALR 误预测
    input  wire [ 31:0] iu_chgflw_pc,
    input  wire         rtu_flush,        // WB 提交点陷阱/中断/mret
    input  wire         rtu_chgflw_vld,
    input  wire [ 31:0] rtu_chgflw_pc,

    // ---- 分支预测器训练 (EX 级解析出控制转移时回送, 1 拍脉冲) ----
    //
    // 不用 C910 那套 iu_bht_check_vld/chk_idx 回送: 那套只覆盖**条件分支**
    // (jal/jalr 的目标学习完全缺失, 原设计里 jalr 从不写 BTB)。这里直接给
    // "解析掉的指令是谁、什么类型、实际去了哪", BTB 自己就能分配/更新。
    input  wire         iu_bht_check_vld,   // 保留给 Phase 2c 的 GHR 通路
    input  wire [ 31:0] iu_cur_pc,
    input  wire         iu_bht_condbr_taken,
    input  wire         iu_bht_pred,
    input  wire [ 24:0] iu_chk_idx,
    input  wire         iu_btb_update_vld,
    input  wire [ 31:0] iu_btb_cur_pc,
    input  wire         iu_btb_taken,
    input  wire [ 31:0] iu_btb_target,
    input  wire         iu_btb_is_cond,
    input  wire         iu_btb_is_jal,
    input  wire         iu_btb_is_jalr,
    // 该指令取指时的 GHR 快照 (随指令走, 就是 chk 里那份)。
    // 重定向时用它把 GHR 拨回"这条指令之前"再补上真实方向 —— 错误路径上那些
    // 块的 GHR 更新必须撤销, 否则一次误预测会污染很长一段的预测索引。
    input  wire [ 24:0] iu_btb_chk,

    // ---- 状态 ----
    output wire         init_done,

    // ---- BIU 主端 (req/grant 协议, 对手方见 mySoC/ifu_biu_mem.v) ----
    output wire         biu_rd_req,
    output wire [ 31:0] biu_rd_addr,
    output wire         biu_rd_id,
    output wire [  1:0] biu_rd_len,
    input  wire         biu_rd_grnt,
    input  wire         biu_rd_data_vld,
    input  wire [127:0] biu_rd_data,
    input  wire         biu_rd_rid,
    input  wire         biu_rd_last,
    input  wire [  1:0] biu_rd_resp,
    output wire         biu_r_ready
);

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------
localparam [31:0] RESET_PC    = 32'h0000_0000;
localparam        LINE_BITS   = $clog2(IC_LINE);
localparam [1:0]  MAX_ISSUE   = 2'd3;          // 3 发射

// ---------------------------------------------------------------------------
// 重定向
//
// RTU (WB 提交点) 优先于 IU (EX 推测点): 后者可能本身就来自错误路径。
// 两者都是 1 拍脉冲且当拍组合有效, 直接用来选 pc_q 的下一值
// ⇒ 重定向进 PC 是 0 拍代价 (与 C910 版"IU redirect 走 pc_bus 快速路径"等价)。
// ---------------------------------------------------------------------------
wire        redirect;
wire [31:0] redirect_pc;

assign redirect    = rtu_chgflw_vld | rtu_flush | iu_chgflw_vld;
assign redirect_pc = (rtu_chgflw_vld | rtu_flush) ? rtu_chgflw_pc : iu_chgflw_pc;

assign idu_flush   = redirect;

// ---------------------------------------------------------------------------
// PC 与 i-cache
//
// 全设计只有**一份** PC 寄存器, 就在 u_icache 里 (它内部的 q_pc_q)。这里只组合
// 地算出"下一个要取的地址"喂给阵列, 下一拍它就变成 q_pc。
//
// 为什么不是"顶层持有一个 pc_q 再寄存一份给 F1 用": 那样一旦取指停顿 (地址保持),
// 延迟的那份会把同一个地址连看两拍, 同一条指令被推进 IBUF 两次 —— difftest 报的
// 重复提交。让阵列地址 = 下一个地址、q_pc = 它的寄存值, 数据与 PC 天然对齐,
// 停顿也只是原地重看同一拍数据, 不会重复。改动前先读 rv32ifu2_icache.v 的端口注释。
// ---------------------------------------------------------------------------
wire [ 31:0] q_pc;                             // F1: 当前消费的 PC
wire [ 1:0]  pc_ofs = q_pc[LINE_BITS-1:2];     // 16 B 块内的字偏移 (0..3)

wire [127:0] q_data;                           // 一整行 16 B, 不是一条指令
wire         q_hit;
wire         ic_init_done;
wire         refill_en;
wire [ 31:0] refill_pc;
wire [127:0] refill_data;
wire         refill_busy;
wire         refill_req;

// 下一个取指地址。Phase 2 起这里还要掺 BPU 的预测目标。
wire [ 31:0] next_pc;

rv32ifu2_icache #(
    .IC_BYTES  (IC_BYTES),
    .IC_LINE   (IC_LINE),
    .IC_WAYS   (IC_WAYS),
    .ICACHE_EN (ICACHE_EN)
) u_icache (
    .clk         (clk),
    .rst         (rst),
    .rd_addr     (next_pc),
    .q_pc        (q_pc),
    .q_data      (q_data),
    .q_hit       (q_hit),
    .refill_en   (refill_en),
    .refill_pc   (refill_pc),
    .refill_data (refill_data),
    .init_done   (ic_init_done)
);

rv32ifu2_refill #(
    .IC_LINE (IC_LINE)
) u_refill (
    .clk             (clk),
    .rst             (rst),
    .req             (refill_req),
    .req_pc          (q_pc),
    .busy            (refill_busy),
    .refill_en       (refill_en),
    .refill_pc       (refill_pc),
    .refill_data     (refill_data),
    .biu_rd_req      (biu_rd_req),
    .biu_rd_addr     (biu_rd_addr),
    .biu_rd_id       (biu_rd_id),
    .biu_rd_len      (biu_rd_len),
    .biu_rd_grnt     (biu_rd_grnt),
    .biu_rd_data_vld (biu_rd_data_vld),
    .biu_rd_data     (biu_rd_data),
    .biu_rd_rid      (biu_rd_rid),
    .biu_rd_last     (biu_rd_last),
    .biu_rd_resp     (biu_rd_resp),
    .biu_r_ready     (biu_r_ready)
);

// ---------------------------------------------------------------------------
// 块 BTB (预测在 F0 查、F1 用, 与 i-cache 同一拍同一地址)
// ---------------------------------------------------------------------------
wire [ 3:0]  btb_vld;
wire [ 3:0]  btb_cond;
wire [ 3:0]  btb_jmp;
wire [127:0] btb_target;
wire         btb_init_done;
wire [ 7:0]  bht_ctr;          // 4 slot × 2 bit 计数器
wire         bht_init_done;

// RAS 的输出要先于"交付/截断"那段声明 —— 截断时要用栈顶覆盖 ret 的目标。
// (声明与例化分开只是 Verilog 的顺序要求, 不是逻辑上的先后。)
wire [31:0] ras_top;
wire        ras_top_vld_raw;
wire [RAS_AW:0] ras_ptr;

// RAS_EN=0 时把"栈顶有效"钉死为 0: ret 一律回落到 BTB 目标, 也不做压/弹。
// 用挂在输出上而不是 `ifdef 掉整个例化 —— 两种配置走的是同一份 RTL,
// 不会出现"关了之后某条路径没编进去"这种只在一种配置下暴露的差异。
wire ras_top_vld = ras_top_vld_raw & RAS_EN;

rv32ifu2_btb #(
    .ROW_AW (BTB_ROW_AW),
    .SLOTS  (4)
) u_btb (
    .clk           (clk),
    .rst           (rst),
    .rd_pc         (next_pc),
    .slot_vld      (btb_vld),
    .slot_cond     (btb_cond),
    .slot_jmp      (btb_jmp),
    .slot_target   (btb_target),
    .init_done     (btb_init_done),
    .upd_vld       (iu_btb_update_vld),
    .upd_pc        (iu_btb_cur_pc),
    .upd_taken     (iu_btb_taken),
    .upd_target    (iu_btb_target),
    .upd_cond      (iu_btb_is_cond),
    .upd_jal       (iu_btb_is_jal),
    .upd_jalr      (iu_btb_is_jalr)
);

// 方向: 条件分支问 gshare(BHT), JAL/JALR 恒 taken。
// 原设计的教训是"方向表的索引里一位 PC 都没有", 所以这里方向只由 BHT 给,
// BTB 只管"有哪些控制转移、目标在哪"。
// ⚠️ 拼接是**高位在前**: {a,b,c,d} 里 a 落在 bit3。slot i 的计数器在
// bht_ctr[2i+1:2i], 所以 slot0 的 MSB 必须放到 bit0 —— 写成
// {bht_ctr[1], bht_ctr[3], ...} 就把四个 slot 的方向整体倒过来了: 谁读谁的邻居,
// 表现是"方向几乎全错"(branch_bench 类 1 从 96% 掉到 4.5%), 而表里看得见非零行,
// 很容易误判成"写没落对地方"。
wire [ 3:0] bht_taken = {bht_ctr[7], bht_ctr[5], bht_ctr[3], bht_ctr[1]};

// 初始化扫描期间两张表的 X 都会经 slot_vld / 方向流进截断位置 → next_pc。
// 显式清掉, 不赌"valid 位会拦住"。
wire [ 3:0] sl_vld   = btb_vld & {4{btb_init_done}};
// BHT 扫描期间计数器是 X, 会经 next_pc 传出去 ⇒ 那段时间方向一律按"不跳"。
// 注意是**只挡方向**, 不用把它并进 init_all: BHT 有 512 行, 并进去会让每条用例
// 开头白等 512 拍, 而这几百拍里"猜不跳"本来也只影响预测率。
wire [ 3:0] sl_taken = (btb_cond & bht_taken & {4{bht_init_done}}) | (~btb_cond & btb_jmp);
wire        init_all = ic_init_done & btb_init_done;

// ---------------------------------------------------------------------------
// 交付: 从 pc_ofs 起, 把本块里剩下的字拼成至多 3 条
//
// 交付条数由**本块剩余**、**第一个预测 taken 的分支**、**队列空位**三者共同限制。
// init_done 门控是必需的: 初始化扫描期间阵列还是 X, q_hit / slot_vld 都是 X,
// 不挡住的话 X 会顺着 q_data 或截断位置流出去。
// ---------------------------------------------------------------------------
// 本 16 B 块里还剩几条 (1..4)。⚠️ 必须用 3 位: "剩 4 条"装不进 2 位,
// `2'd4 - 0` 在 2 位里是 0, want_push 会恒等于 0 —— 整个前端一条都发不出去。
wire [ 2:0] blk_left = 3'd4 - {1'b0, pc_ofs};

// 在 [pc_ofs, 3] 里找第一个"有效且预测 taken"的 slot。
// 排在 pc_ofs 之前的 slot 是上一拍已经交付过的, 不能再参与截断 (它们的预测
// 早已生效, 生效方式就是上一拍把 next_pc 改成了它们的目标)。
wire btb_t0 = (pc_ofs == 2'd0) & sl_vld[0] & sl_taken[0];
wire btb_t1 = (pc_ofs <= 2'd1) & sl_vld[1] & sl_taken[1];
wire btb_t2 = (pc_ofs <= 2'd2) & sl_vld[2] & sl_taken[2];
wire btb_t3 =                    sl_vld[3] & sl_taken[3];

wire        any_taken   = btb_t0 | btb_t1 | btb_t2 | btb_t3;
wire [ 1:0] taken_slot  = btb_t0 ? 2'd0 : btb_t1 ? 2'd1 : btb_t2 ? 2'd2 : 2'd3;
wire [31:0] btb_tgt_raw = btb_t0 ? btb_target[0*32 +: 32]
                        : btb_t1 ? btb_target[1*32 +: 32]
                        : btb_t2 ? btb_target[2*32 +: 32]
                        :          btb_target[3*32 +: 32];


// 想推几条: 到 taken 那条为止(含); 没有 taken 就推满本块剩余; 再受 3 发射限制。
wire [ 2:0] want_to_taken = {1'b0, taken_slot} - {1'b0, pc_ofs} + 3'd1;
wire [ 2:0] want_cnt_raw  = any_taken ? want_to_taken : blk_left;
wire [ 1:0] want_push     = (want_cnt_raw >= 3'd3) ? MAX_ISSUE : want_cnt_raw[1:0];

wire        can_push  = q_hit & init_all;

// 回填请求: 需要一条指令但缓存里没有, 且当前没有事务在途。
// init_done 显式挡住扫描期, 不依赖 X 的取值 (X 在 Verilog 里 `& 0` 是 0, 但别赌)。
assign refill_req = ~q_hit & ~refill_busy & init_all & ~redirect;

// 重定向当拍不推进: 此时 q_pc 还是旧路径的 PC, 推下去就是错误路径的指令。
wire [ 1:0] push_num = (can_push & ~redirect) ? want_push : 2'd0;

// ---------------------------------------------------------------------------
// IDU 包拼装
//
// 字段布局对外**一字不改**(与 C910 版 ifu_rv32i 相同), 因为核心 mycpu.v 与
// tb 探针都按固定位切片读它 —— 改宽会静默移动所有下游切片。
//   [31:0] inst   [63:32] PC   [95:64] pred_npc   [96] fault
//   [100:97] cause   [104:101] attr   [105] pc_oper   [108:106] cf_type
//   [121:109] token   [122] pred_taken   [127:123] 保留
//
// Phase 1 无预测: cf_type / pred_taken / 空 = 0, pred_npc = pc+4。分支由 EX
// 判误预测并重定向兜底。
// ---------------------------------------------------------------------------
function [127:0] make_packet;
    input [31:0] pc;
    input [31:0] inst;
    input [31:0] pred_npc;
    input        pred_taken;
    begin
        make_packet = {
            5'b0,               // [127:123] 保留
            pred_taken,         // [122]     方向预测 (核心当 if_bht_pred 用)
            13'b0,              // [121:109] token
            3'b0,               // [108:106] cf_type
            1'b0,               // [105]     pc_oper
            4'b0,               // [104:101] 属性
            4'b0,               // [100:97]  cause
            1'b0,               // [96]      fault
            pred_npc,           // [95:64]
            pc,                 // [63:32]   PC
            inst                // [31:0]
        };
    end
endfunction

// 每条 lane 落在块内的哪个 slot, 以及它是不是被预测 taken 的那一条。
// ⚠️ 不能加 reached_taken 门控: 没被推进 IBUF 的 lane 的 pred_npc 本来就没人看,
// 而"被推进了"的 lane 里除了 taken 那条, 其余都该是 pc+4。加了门控反而会在
// "IBUF 空间不够、只推进了一半"时把 taken 那条的 pred_npc 写成 pc+4。

// ⚠️ pc_ofs>0 时 inst1/inst2 的位选会越过 q_data 的末尾(返回 X) —— 这是**有意**
// 的: 那几条指令本来就不在这一行里, 没有数据可给。want_push 由 blk_left 限制,
// 越界的 lane 永远不会被 IBUF 收下, 所以 X 不会流进指令流。
wire [31:0] inst0 = q_data[{(pc_ofs + 2'd0), 5'b0} +: 32];
wire [31:0] inst1 = q_data[{(pc_ofs + 2'd1), 5'b0} +: 32];
wire [31:0] inst2 = q_data[{(pc_ofs + 2'd2), 5'b0} +: 32];

// ⚠️ lane 的 PC 是 q_pc + 4*i, **不能**再加 pc_ofs: q_pc 本身就是"本拍第一条
// 要交付的指令的 PC", 偏移已经含在里面了(它只在重定向落到块中间时才非 0)。
// 加了就是重复计偏移 —— 数据用 ofs 索引(对), 标签再加一次 ofs(错), 于是一条
// 指令带着往下数第 ofs 条的 PC 进 IBUF, 看着像"跳过若干条指令"。
wire [31:0] pc0 = q_pc;
wire [31:0] pc1 = q_pc + 32'd4;
wire [31:0] pc2 = q_pc + 32'd8;

// 被预测 taken 的那条指令 (用来判它是不是 ret; 越界 lane 的值不关心 ——
// 那种情况下 reached_taken 必为 0, 目标根本不会被采用)
wire [1:0]  taken_lane = taken_slot - pc_ofs;
wire [31:0] taken_inst = (taken_lane == 2'd0) ? inst0
                       : (taken_lane == 2'd1) ? inst1 : inst2;
wire        t_is_jalr  = (taken_inst[6:0] == 7'b1100_111);       // JALR
wire [4:0]  t_rd       = taken_inst[11:7];
wire [4:0]  t_rs1      = taken_inst[19:15];
wire        t_is_ret   = t_is_jalr & ((t_rs1 == 5'd1) | (t_rs1 == 5'd5))
                                  & (t_rd  == 5'd0);

// ret 的目标问 RAS, 不问 BTB: BTB 只记得住最近一次的目标, 而 ret 的目标随调用
// 深度变化 —— 这是 jal/jalr 误预测的主要来源。
wire [31:0] taken_tgt = (t_is_ret & ras_top_vld) ? ras_top : btb_tgt_raw;

wire [2:0] slot_l0 = {1'b0, pc_ofs};
wire [2:0] slot_l1 = slot_l0 + 3'd1;
wire [2:0] slot_l2 = slot_l0 + 3'd2;

wire lane0_taken = any_taken & (slot_l0 == {1'b0, taken_slot});
wire lane1_taken = any_taken & (slot_l1 == {1'b0, taken_slot});
wire lane2_taken = any_taken & (slot_l2 == {1'b0, taken_slot});

wire [31:0] npc0 = lane0_taken ? taken_tgt : (pc0 + 32'd4);
wire [31:0] npc1 = lane1_taken ? taken_tgt : (pc1 + 32'd4);
wire [31:0] npc2 = lane2_taken ? taken_tgt : (pc2 + 32'd4);

// ---------------------------------------------------------------------------
// IBUF
// ---------------------------------------------------------------------------
// push 数据里要带**本 lane 自己的** GHR 快照 (chk), 而快照要用 ib_push_acc 算,
// 所以这里只声明, 赋值放到 GHR 块之后 —— 顺序只是 Verilog 的声明顺序要求,
// 不是逻辑上的先后。
wire [152:0] ib_push0, ib_push1, ib_push2;
wire [ 24:0] chk0, chk1, chk2;

wire [152:0] ib_out0, ib_out1, ib_out2;
wire [  2:0] ib_vld;
wire [  1:0] ib_push_acc;
wire [  3:0] ib_cnt;
wire         ib_full;

rv32ifu2_ibuf #(
    .DEPTH (8),
    .W     (153)
) u_ibuf (
    .clk       (clk),
    .rst       (rst),
    .flush     (redirect),
    .push_num  (push_num),
    .push_data0(ib_push0),
    .push_data1(ib_push1),
    .push_data2(ib_push2),
    .push_accept(ib_push_acc),
    .out_data0 (ib_out0),
    .out_data1 (ib_out1),
    .out_data2 (ib_out2),
    .out_vld   (ib_vld),
    .pop_num   (idu_accept_num),
    .count     (ib_cnt),
    .full      (ib_full)
);

// ---------------------------------------------------------------------------
// GHR (推测全局历史) 与 gshare 方向表
//
// GHR 在 F1 按"本拍真正推进 IBUF 的那些 lane"里的条件分支顺序推进。
// 用**推进**而不是**交付**做门控: 没进 IBUF 的 lane 下一拍还会再看一遍, 那时
// 才该推进; 用交付门控会把同一批分支的历史重复追加两次。
//
// 误预测时用随指令回来的 chk 快照把 GHR 拨回"这条指令之前"再补真实方向 ——
// 错误路径上那些块的 GHR 更新必须撤销。快照是**逐 lane 算**的: 同一个取指包内
// 第二条条件分支的历史已经含了第一条的结果, 两 lane 用同一份快照就会把它们
// 训到同一行去 (原设计"读索引与写索引 GHR 位窗不一致"就是这类病)。
// ---------------------------------------------------------------------------
reg [GHR_W-1:0] ghr_q;

// 把物理 slot 编号旋转成 lane 编号 (lane i 对应 slot pc_ofs+i)
wire [3:0] vld_rot  = sl_vld   >> pc_ofs;
wire [3:0] tk_rot   = sl_taken >> pc_ofs;
wire [3:0] cond_rot = (btb_cond & sl_vld) >> pc_ofs;

// 只有进 IBUF 的 lane 参与历史推进
wire [2:0] pushed_m = { (ib_push_acc == 2'd3), (ib_push_acc >= 2'd2), (ib_push_acc >= 2'd1) };
wire [2:0] lane_cond = { cond_rot[2], cond_rot[1], cond_rot[0] } & pushed_m;
wire [2:0] lane_tk   = { tk_rot[2],   tk_rot[1],   tk_rot[0]   };

function [2:0] ghr_pack;               // 按 lane 顺序压成低位连续的位串
    input [2:0] c;
    input [2:0] t;
    integer i;
    reg [2:0] b;
    begin
        b = 3'b000;
        for (i = 0; i < 3; i = i + 1)
            if (c[i]) b = {b[1:0], t[i]};
        ghr_pack = b;
    end
endfunction

function [1:0] ghr_cnt;
    input [2:0] c;
    begin
        ghr_cnt = {1'b0, c[0]} + {1'b0, c[1]} + {1'b0, c[2]};
    end
endfunction

wire [2:0]       ghr_bits = ghr_pack(lane_cond, lane_tk);   // 仅用于推进 GHR
wire [1:0]       ghr_n    = ghr_cnt(lane_cond);
wire [GHR_W-1:0] ghr_next = (ghr_q << ghr_n) | {{(GHR_W-3){1'b0}}, ghr_bits};

// 重定向时的 GHR 恢复
// 条件分支误预测 ⇒ 拨回块首再补一位真实方向。块内第 2/3 条分支时这是**近似**
// (丢掉了同块里更靠前那几条的结局), 但 GHR 只影响预测质量、不影响正确性,
// 而这个近似只在误预测那一拍出现一次。
wire [GHR_W-1:0] ghr_restore = iu_btb_is_cond
                             ? {iu_btb_chk[GHR_W-2:0], iu_btb_taken}
                             :  iu_btb_chk[GHR_W-1:0];

// 本拍结束时 GHR 的值。它同时就是"下一个取指地址"查表该用的历史 ——
// 阵列地址与 GHR 索引在同一拍形成, 结果同一拍到达 F1, 正好对齐。
wire [GHR_W-1:0] ghr_after = (rtu_chgflw_vld | rtu_flush) ? {GHR_W{1'b0}}
                           : iu_chgflw_vld                ? ghr_restore
                           :                                ghr_next;

always @(posedge clk) begin
    if (rst) ghr_q <= {GHR_W{1'b0}};
    else     ghr_q <= ghr_after;
end

// ---------------------------------------------------------------------------
// GHR 快照 = **本块的块首 GHR**, 三条 lane 完全相同。
//
// ⚠️ 这里**必须**是块首的 GHR, 不能是"这条指令自己之前"的 GHR。
// 表是**按块**索引的 (一行 4 个 slot), 预测时的索引用的是块首 GHR; 写入如果改用
// "该分支之前"的 GHR, 同一个 slot 的读写就会落到不同的行 —— 那正是原设计类 3
// 卡在 50% 的病 (类 3 读到的 21 个地址整个仿真收到 0 次写)。
// 块内第 2、3 条分支靠**不同的 slot 位**区分, 不靠不同的 GHR。
//
// ghr_q 就是块首 GHR: 本块的分支要到本拍末尾才推进它, 而块是本拍才被交付的。
// ---------------------------------------------------------------------------
// chk = {RAS 指针, GHR}。两者都是**块首**的值 —— 同一节拍本块的三条 lane 相同,
// 与"表按块索引"的口径一致 (见上面 GHR 那段的长注释)。
wire [24:0] chk_snap = {{(25-RAS_CHK_MSB-1){1'b0}}, ras_ptr, ghr_q[GHR_W-1:0]};

// 再带上两个**逐 lane** 的预测元信息, 供归因用 (只读, 不参与任何逻辑):
//   bit CHK_BTBHIT: 预测时这一 slot 在 BTB 里有没有条目 (没有 ⇒ 只能猜"不跳")
//   bit CHK_PREDTK: 预测时的方向
// 没有这两位就无法区分"方向表猜错了"和"BTB 根本没这条分支" —— 这两种瓶颈
// 的修法完全不同 (前者加历史/表, 后者加 CAM/容量)。
wire chk0_f = chk_snap;
wire chk1_f = chk_snap;
wire chk2_f = chk_snap;

assign chk0 = chk0_f;
assign chk1 = chk1_f;
assign chk2 = chk2_f;

assign ib_push0 = {chk0, make_packet(pc0, inst0, npc0, lane0_taken)};
assign ib_push1 = {chk1, make_packet(pc1, inst1, npc1, lane1_taken)};
assign ib_push2 = {chk2, make_packet(pc2, inst2, npc2, lane2_taken)};

// ---------------------------------------------------------------------------
// RAS
//
// 一拍最多压一条 / 弹一条: 一个取指包里出现两条 call (或两条 ret) 极少,
// 而真出现时只记第一条 —— 只影响预测质量, 不影响正确性 (误预测会兜底)。
// ---------------------------------------------------------------------------
wire [2:0] c_lane = { (inst2[6:0] == 7'b1100_111) & ((inst2[11:7]==5'd1)|(inst2[11:7]==5'd5)) & pushed_m[2],
                      (inst1[6:0] == 7'b1100_111) & ((inst1[11:7]==5'd1)|(inst1[11:7]==5'd5)) & pushed_m[1],
                      (inst0[6:0] == 7'b1100_111) & ((inst0[11:7]==5'd1)|(inst0[11:7]==5'd5)) & pushed_m[0] };
wire [2:0] r_lane = { (inst2[6:0] == 7'b1100_111) & ((inst2[19:15]==5'd1)|(inst2[19:15]==5'd5)) & (inst2[11:7]==5'd0) & pushed_m[2],
                      (inst1[6:0] == 7'b1100_111) & ((inst1[19:15]==5'd1)|(inst1[19:15]==5'd5)) & (inst1[11:7]==5'd0) & pushed_m[1],
                      (inst0[6:0] == 7'b1100_111) & ((inst0[19:15]==5'd1)|(inst0[19:15]==5'd5)) & (inst0[11:7]==5'd0) & pushed_m[0] };
// jal rd,x1|5 也算 call
wire [2:0] j_lane = { (inst2[6:0] == 7'b1101_111) & ((inst2[11:7]==5'd1)|(inst2[11:7]==5'd5)) & pushed_m[2],
                      (inst1[6:0] == 7'b1101_111) & ((inst1[11:7]==5'd1)|(inst1[11:7]==5'd5)) & pushed_m[1],
                      (inst0[6:0] == 7'b1101_111) & ((inst0[11:7]==5'd1)|(inst0[11:7]==5'd5)) & pushed_m[0] };

wire [2:0] push_lane = (c_lane | j_lane) & {3{RAS_EN}};
wire [2:0] ras_push_num = {2'b00, push_lane[0]} | {2'b00, push_lane[1]} | {2'b00, push_lane[2]};
wire [2:0] ras_pop_num  = ({2'b00, r_lane[0]} | {2'b00, r_lane[1]} | {2'b00, r_lane[2]}) & {3{RAS_EN}};

wire [31:0] push_ret_pc = push_lane[0] ? (pc0 + 32'd4)
                        : push_lane[1] ? (pc1 + 32'd4)
                        :                (pc2 + 32'd4);

rv32ifu2_ras #(
    .DEPTH (1 << RAS_AW),
    .AW    (RAS_AW)
) u_ras (
    .clk         (clk),
    .rst         (rst),
    .push_num    (ras_push_num),
    .push_pc0    (push_ret_pc),
    .push_pc1    (push_ret_pc),
    .push_pc2    (push_ret_pc),
    .pop_num     (ras_pop_num),
    .top         (ras_top),
    .top_vld     (ras_top_vld_raw),
    .ptr_out     (ras_ptr),
    .restore_vld (redirect),
    .restore_ptr (iu_btb_chk[RAS_CHK_MSB:RAS_CHK_LSB])
);

rv32ifu2_bht #(
    .ROW_AW (BHT_ROW_AW),
    .GHR_W  (GHR_W),
    .SLOTS  (4)
) u_bht (
    .clk       (clk),
    .rst       (rst),
    .rd_pc     (next_pc),
    .rd_ghr    (ghr_after),
    .slot_ctr  (bht_ctr),
    .init_done (bht_init_done),
    .upd_vld   (iu_bht_check_vld),
    .upd_pc    (iu_cur_pc),
    .upd_ghr   (iu_chk_idx[GHR_W-1:0]),
    .upd_slot  (iu_cur_pc[3:2]),
    .upd_taken (iu_bht_condbr_taken)
);


assign idu_inst0_vld  = ib_vld[0] & ~idu_flush;
assign idu_inst0_data = ib_out0[127:0];
assign idu_inst0_chk  = ib_out0[152:128];
assign idu_inst1_vld  = ib_vld[1] & ~idu_flush;
assign idu_inst1_data = ib_out1[127:0];
assign idu_inst1_chk  = ib_out1[152:128];
assign idu_inst2_vld  = ib_vld[2] & ~idu_flush;
assign idu_inst2_data = ib_out2[127:0];
assign idu_inst2_chk  = ib_out2[152:128];

// ---------------------------------------------------------------------------
// 下一个取指地址
//
// 前进量 = **IBUF 实际收下的条数**, 不是 F1 想推的条数: 队列快满时 acc_push 会
// 小于 push_num, 剩下的那几条下拍从新偏移重新提供, 既不丢也不重取。
//
// 复位那条分支在这里出现是必需的 —— 阵列地址寄存器在 u_icache 里, 复位后它自己
// 回到 0, 顶层只要保证复位期间 next_pc 也是 0 (下面 rst 分支)。
// 重定向优先: 目标地址当拍就进阵列, 下一拍 q_pc 即是目标, 所以重定向进 PC
// 是**零气泡**(只要命中), 与 C910 版"IU redirect 走 pc_bus 快速路径"等价。
// ---------------------------------------------------------------------------
wire [31:0] pc_adv = {28'd0, ib_push_acc, 2'b00};

// 只有"想推的条数全部推进去了"才算真的走到了那条 taken 分支, 这时 PC 才去目标。
// 队列空间不够时只推进了一部分, 分支还没进去, PC 必须按顺序继续 —— 否则会跳过
// 分支之前那些还没交付的指令。
wire reached_taken = any_taken & ({1'b0, ib_push_acc} == want_cnt_raw);

assign next_pc = rst            ? RESET_PC
               : redirect       ? redirect_pc
               : reached_taken  ? taken_tgt
               :                  (q_pc + pc_adv);

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
assign init_done = init_all;



/* verilator lint_off UNUSED */
// 这一组是 Phase 2c (gshare) 才用的 C910 风格回送; 现在留着接线位置但没接。
// 别误当成漏接 —— 当前训练走的是 iu_btb_* 那一组。
wire        unused_bht_check = iu_bht_check_vld ^ iu_bht_condbr_taken ^ iu_bht_pred ^ BP_EN;
wire [31:0] unused_bht_pc    = iu_cur_pc;
wire [24:0] unused_chk_idx   = iu_chk_idx;
/* verilator lint_on UNUSED */

endmodule
