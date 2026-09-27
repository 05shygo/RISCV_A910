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
    // 全部可由 Makefile 的 +define+ 覆盖, 扫点不用改 RTL。
`ifdef ICACHE_BYTES
    parameter IC_BYTES  = `ICACHE_BYTES,
`else
    parameter IC_BYTES  = 1024,
`endif
`ifdef ICACHE_LINE_BYTES
    parameter IC_LINE   = `ICACHE_LINE_BYTES,
`else
    parameter IC_LINE   = 16,
`endif
    parameter IC_WAYS   = 2,
    // ---- 方向预测器二选一 (Makefile 的 BP_PRED) ----
    //   1 = TAGE   (rv32ifu2_tage, 按 TAGE_branch_predi.md, **默认**)
    //   0 = gshare (rv32ifu2_bht, 旧默认, 留做 A/B 与回归基线)
    // Makefile 只在非 0 时才 +define+BP_PRED, 所以 tb 里的 `ifdef BP_PRED`
    // 与这里的取值天然一致。
`ifdef BP_PRED
    parameter BP_PRED_MODE = `BP_PRED,
`else
    parameter BP_PRED_MODE = 0,
`endif
    // TAGE 几何。⚠️ TAG_W <= 12 - TAGE_ROW_AW (64 KB 地址空间, 见 tage.v 头注释),
    // 越界会在 elaborate 时报 $fatal 而不是静默跑一个残废配置。
`ifdef BP_T0_AW
    parameter TAGE_T0_AW   = `BP_T0_AW,
`else
    parameter TAGE_T0_AW   = 6,
`endif
`ifdef BP_TAGE_AW
    parameter TAGE_ROW_AW  = `BP_TAGE_AW,
`else
    parameter TAGE_ROW_AW  = 6,
`endif
`ifdef BP_TAGE_N
    parameter TAGE_NTAB    = `BP_TAGE_N,
`else
    parameter TAGE_NTAB    = 4,
`endif
`ifdef BP_TAGE_TAG_W
    parameter TAGE_TAG_W   = `BP_TAGE_TAG_W,
`else
    parameter TAGE_TAG_W   = 6,
`endif
    // 逐表**逻辑**行数 (回答"每一级的表 entry 数不同会怎样")。缺省 = 跟随
    // TAGE_ROW_AW ⇒ 四张表同尺寸, 与加这几个参数之前逐位相同。
    // ⚠️ 约束 TAGE_TAG_W >= 12 - TAGE_RAi, tage.v 末尾自检会 $fatal。
`ifdef BP_TAGE_RA1
    parameter TAGE_RA1     = `BP_TAGE_RA1,
`else
    parameter TAGE_RA1     = TAGE_ROW_AW,
`endif
`ifdef BP_TAGE_RA2
    parameter TAGE_RA2     = `BP_TAGE_RA2,
`else
    parameter TAGE_RA2     = TAGE_ROW_AW,
`endif
`ifdef BP_TAGE_RA3
    parameter TAGE_RA3     = `BP_TAGE_RA3,
`else
    parameter TAGE_RA3     = TAGE_ROW_AW,
`endif
`ifdef BP_TAGE_RA4
    parameter TAGE_RA4     = `BP_TAGE_RA4,
`else
    parameter TAGE_RA4     = TAGE_ROW_AW,
`endif
`ifdef BP_TAGE_T0H
    parameter TAGE_T0_HIST = `BP_TAGE_T0H,
`else
    parameter TAGE_T0_HIST = 0,
`endif
`ifdef BP_TAGE_L1
    parameter TAGE_L1      = `BP_TAGE_L1,
`else
    parameter TAGE_L1      = 2,
`endif
`ifdef BP_TAGE_L2
    parameter TAGE_L2      = `BP_TAGE_L2,
`else
    parameter TAGE_L2      = 5,
`endif
`ifdef BP_TAGE_L3
    parameter TAGE_L3      = `BP_TAGE_L3,
`else
    parameter TAGE_L3      = 9,
`endif
`ifdef BP_TAGE_L4
    parameter TAGE_L4      = `BP_TAGE_L4,
`else
    parameter TAGE_L4      = 14,
`endif
    // USE_SEL 的几何。它**按构造与 T0 解耦**: ps==0 (只剩 T0 命中) 时 fpred 直接取
    // t0_pred, USE_SEL 根本不被查询 (rv32ifu2_tage.v 的 fpred 那一行), 训练侧也被
    // u_usel_en 挡掉 —— 所以它的适用域是"命中 tagged 表的分支", 与 T0 有多少项无关。
    // ⚠️ USEL_AW 一旦超过 ROW_AW 会抬高 INIT_ROWS, 初始化扫描变长.
`ifdef BP_TAGE_USEL_AW
    parameter TAGE_USEL_AW   = `BP_TAGE_USEL_AW,
`else
    parameter TAGE_USEL_AW   = 6,
`endif
`ifdef BP_TAGE_USEL_W
    parameter TAGE_USEL_W    = `BP_TAGE_USEL_W,
`else
    parameter TAGE_USEL_W    = 4,
`endif
`ifdef BP_TAGE_USEL_GATE
    parameter TAGE_USEL_GATE = `BP_TAGE_USEL_GATE,
`else
    parameter TAGE_USEL_GATE = 1,
`endif
`ifdef BP_BTB_ROW_AW
    parameter BTB_ROW_AW = `BP_BTB_ROW_AW,
`else
    parameter BTB_ROW_AW = 6,
`endif
`ifdef BP_BHT_ROW_AW
    parameter BHT_ROW_AW = `BP_BHT_ROW_AW,
`else
    parameter BHT_ROW_AW = 9,
`endif
`ifdef BP_GHR_W
    parameter GHR_W      = `BP_GHR_W,
`else
    // gshare 默认 8: 见 doc §4 的 "GHR 宽度扫点" —— 它的索引只有 9 位,
    // 更长的历史会被 `f[i % ROW_AW]` 折到低位上互相抵消, 实测越长越差。
    // TAGE 每张表有**自己的**宽度, 不存在那个自抵消, 长历史才有用, 所以默认给 16。
    // 两者共用一个参数: TAGE 那套由 Makefile 传 BP_GHR_W, 或吃这个条件默认。
    parameter GHR_W      = (BP_PRED_MODE != 0) ? 16 : 8,
`endif
`ifdef BP_RAS
    parameter RAS_EN     = `BP_RAS,
`else
    parameter RAS_EN     = 0,
`endif
    parameter RAS_AW      = 3,
    parameter RAS_CHK_LSB = GHR_W,
    parameter RAS_CHK_MSB = GHR_W + RAS_AW,
    // chk 的字段布局。⚠️ **改这里必须同时改 tb 里跟着参数走的切片**
    // (tb_miniRV_dpi.sv 的 M2PROBE 那一段), 否则探针会静默读到别的位。
    // 这份位账已经漂过一次: GHR_W 从 12 改到 8 之后 CHK_BTBHIT/CHK_PREDTK
    // 从 17/18 挪到了 13/14, 而 tb 还在读 17/18 —— 那两个位在空白区里恒 0,
    // 于是 M2PROBE 的"方向错 vs BTB 没这条"归因整个失效。
    //
    //   [GHR_W-1:0]        GHR 快照
    //   [RAS_CHK_MSB:LSB]  ras_ptr (RAS_AW+1 位)
    //   [CHK_BTBHIT]       TB 归因: 预测时这个 slot 在 BTB 里有没有条目
    //   [CHK_PREDTK]       TB 归因: 预测时的方向 (含 BTB 门控)
    //   [CHK_FPRED]        TAGE 训练用: 方向表**原始**给出的方向 (无 BTB 门控)
    //   ⚠️ 整份 chk 只有 25 位, 所以 **GHR_W <= 18** (RAS_AW=3 时)。
    //   越界的后果是**静默**的: `25'd1 << 26` 在 25 位里就是 0, 那一位永远置不上,
    //   TAGE 的 upd_fpred 恒读到 0 ⇒ 分配逻辑整条失效, 而所有别的数看起来都正常
    //   (实测症状: 类 3 恰好 50.00%、类 5 掉回 74.41%、TAGE rows valid = 0)。
    //   GHR_W=24 更狠 —— 复制次数变负数, 直接 elaborate 失败。
    //   下面的 initial 块会显式报这个错。
    parameter CHK_W       = 25,
    parameter CHK_BTBHIT  = GHR_W + RAS_AW + 1,
    parameter CHK_PREDTK  = GHR_W + RAS_AW + 2,
    parameter CHK_FPRED   = GHR_W + RAS_AW + 3,
    // 哨兵: 每个 `ifdef 分支里的 parameter 都带逗号, 需要有个无条件跟在最后的
    // 参数, 否则 `endif 之后直接是 `)(` 时列表尾会多一个逗号。
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
// ⚠️ 4, 不是 3。交付宽度必须 >= 16 B 块里的指令数 (4), 否则一个无分支的直线块
// 要推两拍 (3+1), **直线代码封顶 2 IPC** —— 顶压在 3 发射的目标之下。
// 这是"块 = 4 条"与"推入宽度 = 3"之间的硬冲突, 不是调优问题。
localparam [2:0]  MAX_ISSUE   = 3'd4;          // 一拍最多交付 4 条 = 整个 16 B 块

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
wire [31:0] ras_top;
wire        ras_top_vld_raw;
wire [RAS_AW:0] ras_ptr;
wire ras_top_vld = ras_top_vld_raw & RAS_EN;
wire [ 3:0]  dir_pred;         // 方向表给出的逐 slot 原始方向 (未过 BTB 门控)
wire         dir_init_done;    // 方向表初始化完成 (gshare 或 TAGE, 二选一)

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

// 方向: 条件分支问方向表 (gshare 或 TAGE, 见下面的 generate), JAL/JALR 恒 taken。
// 原设计的教训是"方向表的索引里一位 PC 都没有", 所以这里方向只由方向表给,
// BTB 只管"有哪些控制转移、目标在哪"。

// 初始化扫描期间两张表的 X 都会经 slot_vld / 方向流进截断位置 → next_pc。
// 显式清掉, 不赌"valid 位会拦住"。
wire [ 3:0] sl_vld   = btb_vld & {4{btb_init_done}};
// 方向表扫描期间计数器是 X, 会经 next_pc 传出去 ⇒ 那段时间方向一律按"不跳"。
// 注意是**只挡方向**, 不用把它并进 init_all: gshare 有 512 行 / TAGE 最多 512 拍,
// 并进去会让每条用例开头白等几百拍, 而这几百拍里"猜不跳"本来也只影响预测率。
// BP_EN=0 同样把方向按住 —— BP_EN 此前是**死参数**(只在 lint 抑制式里出现过),
// 顺手接上, 让"预测器全关"能当一个干净基线。
wire [ 3:0] sl_taken = (btb_cond & dir_pred & {4{dir_init_done & BP_EN}})
                     | (~btb_cond & btb_jmp);
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
// want_cnt_raw 天然落在 [1,4] (blk_left = 4-pc_ofs, want_to_taken = taken_slot-pc_ofs+1),
// 所以这里只是"再受发射宽度限制", MAX_ISSUE=4 时恒等。
wire [ 2:0] want_push     = (want_cnt_raw > MAX_ISSUE) ? MAX_ISSUE : want_cnt_raw;

wire        can_push  = q_hit & init_all;

// 回填请求: 需要一条指令但缓存里没有, 且当前没有事务在途。
// init_done 显式挡住扫描期, 不依赖 X 的取值 (X 在 Verilog 里 `& 0` 是 0, 但别赌)。
assign refill_req = ~q_hit & ~refill_busy & init_all & ~redirect;

// 重定向当拍不推进: 此时 q_pc 还是旧路径的 PC, 推下去就是错误路径的指令。
// ⚠️ 位宽必须 >= want_push 的位宽。这里曾经还是 [1:0], 而 want_push 已经是 [2:0]:
//    want_push=4 (3'b100) 截成 2'b00 = 0 ⇒ **一条都推不进去**, next_pc 原地不动,
//    BIU 只发 1 次事务然后整条流水线空转 (实测 retired=0, fetch bubble≈满拍)。
//    正是本工程反复踩的"隐式截断"那一族 —— 改宽度时把**所有**同族声明一起改。
wire [ 2:0] push_num = (can_push & ~redirect) ? want_push : 3'd0;

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
// lane3 只在 pc_ofs==0 时有意义 (blk_left=4 才推得到第 4 条), 那时索引是 3, 不会越界。
wire [31:0] inst3 = q_data[{(pc_ofs + 2'd3), 5'b0} +: 32];

// ⚠️ lane 的 PC 是 q_pc + 4*i, **不能**再加 pc_ofs: q_pc 本身就是"本拍第一条
// 要交付的指令的 PC", 偏移已经含在里面了(它只在重定向落到块中间时才非 0)。
// 加了就是重复计偏移 —— 数据用 ofs 索引(对), 标签再加一次 ofs(错), 于是一条
// 指令带着往下数第 ofs 条的 PC 进 IBUF, 看着像"跳过若干条指令"。
wire [31:0] pc0 = q_pc;
wire [31:0] pc1 = q_pc + 32'd4;
wire [31:0] pc2 = q_pc + 32'd8;
wire [31:0] pc3 = q_pc + 32'd12;

// taken_lane = taken_slot - pc_ofs, 落在 [0,3] (两者都在 0..3 且 taken_slot >= pc_ofs)
wire [1:0]  taken_lane = taken_slot - pc_ofs;
wire [31:0] taken_inst = (taken_lane == 2'd0) ? inst0
                       : (taken_lane == 2'd1) ? inst1
                       : (taken_lane == 2'd2) ? inst2 : inst3;
wire        t_is_jalr  = (taken_inst[6:0] == 7'b1100_111);
wire        t_is_ret   = t_is_jalr & ((taken_inst[19:15] == 5'd1) | (taken_inst[19:15] == 5'd5))
                                  & (taken_inst[11:7]  == 5'd0);
wire [31:0] taken_tgt = (t_is_ret & ras_top_vld) ? ras_top : btb_tgt_raw;

wire [2:0] slot_l0 = {1'b0, pc_ofs};
wire [2:0] slot_l1 = slot_l0 + 3'd1;
wire [2:0] slot_l2 = slot_l0 + 3'd2;
wire [2:0] slot_l3 = slot_l0 + 3'd3;

wire lane0_taken = any_taken & (slot_l0 == {1'b0, taken_slot});
wire lane1_taken = any_taken & (slot_l1 == {1'b0, taken_slot});
wire lane2_taken = any_taken & (slot_l2 == {1'b0, taken_slot});
wire lane3_taken = any_taken & (slot_l3 == {1'b0, taken_slot});

wire [31:0] npc0 = lane0_taken ? taken_tgt : (pc0 + 32'd4);
wire [31:0] npc1 = lane1_taken ? taken_tgt : (pc1 + 32'd4);
wire [31:0] npc2 = lane2_taken ? taken_tgt : (pc2 + 32'd4);
wire [31:0] npc3 = lane3_taken ? taken_tgt : (pc3 + 32'd4);

// ---------------------------------------------------------------------------
// IBUF
// ---------------------------------------------------------------------------
// push 数据里要带**本 lane 自己的** GHR 快照 (chk), 而快照要用 ib_push_acc 算,
// 所以这里只声明, 赋值放到 GHR 块之后 —— 顺序只是 Verilog 的声明顺序要求,
// 不是逻辑上的先后。
wire [152:0] ib_push0, ib_push1, ib_push2, ib_push3;
wire [ 24:0] chk0, chk1, chk2, chk3;

wire [152:0] ib_out0, ib_out1, ib_out2;      // 出队侧仍是 3 (核心是 3 发射)
wire [  2:0] ib_vld;
wire [  2:0] ib_push_acc;
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
    .push_data3(ib_push3),
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
// 方向表的**原始**方向 (未过 BTB 门控), 同样旋转成 lane 编号。
// TAGE 的 u 更新与分配都要求"方向表自己当时的判断", 而不是"最终发给核心的方向"
// —— BTB 没有这一行时两者不同, 混用会让 u 整段不更新、还会在纯 BTB miss 上误分配。
wire [3:0] fp_rot   = dir_pred >> pc_ofs;

// 只有进 IBUF 的 lane 参与历史推进
wire [3:0] pushed_m = { (ib_push_acc == 3'd4), (ib_push_acc >= 3'd3),
                        (ib_push_acc >= 3'd2), (ib_push_acc >= 3'd1) };
wire [3:0] lane_cond = { cond_rot[3], cond_rot[2], cond_rot[1], cond_rot[0] } & pushed_m;
wire [3:0] lane_tk   = { tk_rot[3],   tk_rot[2],   tk_rot[1],   tk_rot[0]   };

function [3:0] ghr_pack;               // 按 lane 顺序压成低位连续的位串
    input [3:0] c;
    input [3:0] t;
    integer i;
    reg [3:0] b;
    begin
        b = 4'b0000;
        for (i = 0; i < 4; i = i + 1)
            if (c[i]) b = {b[2:0], t[i]};
        ghr_pack = b;
    end
endfunction

function [2:0] ghr_cnt;
    input [3:0] c;
    begin
        ghr_cnt = {2'b0, c[0]} + {2'b0, c[1]} + {2'b0, c[2]} + {2'b0, c[3]};
    end
endfunction

wire [3:0]       ghr_bits = ghr_pack(lane_cond, lane_tk);   // 仅用于推进 GHR
wire [2:0]       ghr_n    = ghr_cnt(lane_cond);
wire [GHR_W-1:0] ghr_next = (ghr_q << ghr_n) | {{(GHR_W-4){1'b0}}, ghr_bits};

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
// ⚠️ 这份 GHR 快照与上面 `rd_ghr(ghr_after)` 的索引是**一对**: 读索引用的是
// "下一拍的 ghr_q", 而这里存的就是下一拍的 ghr_q。谁要单独改一边 —— 比如照
// 文档 §4 规则 2 把它换成"块首 GHR"却不改 F0 的 rd_ghr —— 立刻重现原设计那个
// "读写索引不一致 ⇒ 一整类分支收到 0 次写"的病 (memory bp-class3-root-cause)。
// (顺带更正: 文档说必须是"块首 GHR、三条 lane 相同", 实际做到的是"每条 lane
//  推进时自己的 GHR"。SPEC 上实测后者**更好** 0.58pp, 所以别去"修"它。)
// 高位补零的个数**钳到 0**: 不让 GHR_W 过大时变成负复制数而在 elaborate 期
// 报一个看不懂的错 —— 那种配置由下面的 initial 显式 $fatal 拦。
localparam CHK_PAD = (CHK_W > RAS_CHK_MSB + 1) ? (CHK_W - RAS_CHK_MSB - 1) : 0;
wire [CHK_W-1:0] chk_snap = {{CHK_PAD{1'b0}}, ras_ptr, ghr_q[GHR_W-1:0]};

// 再带两个**逐 lane** 的预测元信息, 只供 TB 归因用, 不参与任何逻辑:
//   CHK_BTBHIT: 预测时这一 slot 在 BTB 里有没有条目 (没有 ⇒ 只能猜"不跳")
//   CHK_PREDTK: 预测时的方向
// 没有这两位就无法区分"方向表猜错了"和"BTB 根本没这条分支" —— 两者的修法完全不同
// (前者换索引/加历史, 后者加 CAM/容量), 而 TAGE 只解决前者, 所以这个拆分决定了
// TAGE 到底有没有用武之地。
//
// ⚠️ 位段选在 RAS_CHK_MSB+2 起: ras_ptr 占 [RAS_CHK_MSB:RAS_CHK_LSB]=[15:12],
// bit 15 **不是空闲位** —— 早先版本把 BTBHIT 放在 bit15, 直接和 ras_ptr[3] 撞了。
// bit 16 留空, 用 17/18。
// ⚠️⚠️ **位宽必须显式写**。`wire x = expr;` 在 Verilog 里**不推断宽度, 一律 1 位** ——
// 写成 `wire chk0_f = chk_snap | ...;` 会把 25 位的 chk 截成只剩 bit0 (即 ghr_q[0]),
// 整个 GHR 快照被毁, BHT 训练索引随之崩掉。
// 症状: branch_bench 从 161,528 涨到 208,964、方向准确率 95.00% → 54.30%、
// 类 3 恰好回到 50.00% —— 看起来完全像"预测表被改坏了", 而真凶只是少写了 [24:0]。
// 本工程此前已踩过同类坑 (隐式 1 位线网把 ex_pred_npc 变成恒 0), 别再踩第三次。
wire [24:0] chk0_f = chk_snap | (vld_rot[0] ? (25'd1 << CHK_BTBHIT) : 25'd0)
                             | (tk_rot[0]  ? (25'd1 << CHK_PREDTK) : 25'd0)
                             | (fp_rot[0]  ? (25'd1 << CHK_FPRED)  : 25'd0);
wire [24:0] chk1_f = chk_snap | (vld_rot[1] ? (25'd1 << CHK_BTBHIT) : 25'd0)
                             | (tk_rot[1]  ? (25'd1 << CHK_PREDTK) : 25'd0)
                             | (fp_rot[1]  ? (25'd1 << CHK_FPRED)  : 25'd0);
wire [24:0] chk2_f = chk_snap | (vld_rot[2] ? (25'd1 << CHK_BTBHIT) : 25'd0)
                             | (tk_rot[2]  ? (25'd1 << CHK_PREDTK) : 25'd0)
                             | (fp_rot[2]  ? (25'd1 << CHK_FPRED)  : 25'd0);
wire [24:0] chk3_f = chk_snap | (vld_rot[3] ? (25'd1 << CHK_BTBHIT) : 25'd0)
                             | (tk_rot[3]  ? (25'd1 << CHK_PREDTK) : 25'd0)
                             | (fp_rot[3]  ? (25'd1 << CHK_FPRED)  : 25'd0);

assign chk0 = chk0_f;
assign chk1 = chk1_f;
assign chk2 = chk2_f;
assign chk3 = chk3_f;

assign ib_push0 = {chk0, make_packet(pc0, inst0, npc0, lane0_taken)};
assign ib_push1 = {chk1, make_packet(pc1, inst1, npc1, lane1_taken)};
assign ib_push2 = {chk2, make_packet(pc2, inst2, npc2, lane2_taken)};
assign ib_push3 = {chk3, make_packet(pc3, inst3, npc3, lane3_taken)};

wire [3:0] c_lane = { (inst3[6:0]==7'b1100_111)&((inst3[11:7]==5'd1)|(inst3[11:7]==5'd5))&pushed_m[3],
                      (inst2[6:0]==7'b1100_111)&((inst2[11:7]==5'd1)|(inst2[11:7]==5'd5))&pushed_m[2],
                      (inst1[6:0]==7'b1100_111)&((inst1[11:7]==5'd1)|(inst1[11:7]==5'd5))&pushed_m[1],
                      (inst0[6:0]==7'b1100_111)&((inst0[11:7]==5'd1)|(inst0[11:7]==5'd5))&pushed_m[0] };
wire [3:0] r_lane = { (inst3[6:0]==7'b1100_111)&((inst3[19:15]==5'd1)|(inst3[19:15]==5'd5))&(inst3[11:7]==5'd0)&pushed_m[3],
                      (inst2[6:0]==7'b1100_111)&((inst2[19:15]==5'd1)|(inst2[19:15]==5'd5))&(inst2[11:7]==5'd0)&pushed_m[2],
                      (inst1[6:0]==7'b1100_111)&((inst1[19:15]==5'd1)|(inst1[19:15]==5'd5))&(inst1[11:7]==5'd0)&pushed_m[1],
                      (inst0[6:0]==7'b1100_111)&((inst0[19:15]==5'd1)|(inst0[19:15]==5'd5))&(inst0[11:7]==5'd0)&pushed_m[0] };
wire [3:0] j_lane = { (inst3[6:0]==7'b1101_111)&((inst3[11:7]==5'd1)|(inst3[11:7]==5'd5))&pushed_m[3],
                      (inst2[6:0]==7'b1101_111)&((inst2[11:7]==5'd1)|(inst2[11:7]==5'd5))&pushed_m[2],
                      (inst1[6:0]==7'b1101_111)&((inst1[11:7]==5'd1)|(inst1[11:7]==5'd5))&pushed_m[1],
                      (inst0[6:0]==7'b1101_111)&((inst0[11:7]==5'd1)|(inst0[11:7]==5'd5))&pushed_m[0] };
wire [3:0] push_lane = (c_lane | j_lane) & {4{RAS_EN}};
wire [3:0] ras_push_num = {3'b000, push_lane[0]} | {3'b000, push_lane[1]}
                        | {3'b000, push_lane[2]} | {3'b000, push_lane[3]};
wire [3:0] ras_pop_num  = ({3'b000, r_lane[0]} | {3'b000, r_lane[1]}
                        |  {3'b000, r_lane[2]} | {3'b000, r_lane[3]}) & {4{RAS_EN}};
// ⚠️ 四个 lane 的返回地址**都取同一个** push_ret_pc —— 与 RAS 一直以来的做法一致
//    (多 call 同块时本来就只能记一个)。这里只是把选择器补到 4 路, 不改语义。
wire [31:0] push_ret_pc = push_lane[0] ? (pc0+32'd4) : push_lane[1] ? (pc1+32'd4)
                        : push_lane[2] ? (pc2+32'd4) : (pc3+32'd4);

rv32ifu2_ras #(
    .DEPTH (1 << RAS_AW), .AW (RAS_AW)
) u_ras (
    .clk(clk), .rst(rst),
    .push_num(ras_push_num),
    .push_pc0(push_ret_pc), .push_pc1(push_ret_pc),
    .push_pc2(push_ret_pc), .push_pc3(push_ret_pc),
    .pop_num(ras_pop_num),
    .top(ras_top), .top_vld(ras_top_vld_raw), .ptr_out(ras_ptr),
    .restore_vld(redirect),
    .restore_ptr(iu_btb_chk[RAS_CHK_MSB:RAS_CHK_LSB])
);

// 方向表二选一。两者端口一一对应 (rd_pc/rd_ghr → 逐 slot 方向 + init_done,
// 以及同一组训练脉冲), 所以这里只是一个 generate 开关。
//
// ⚠️ 两者都**只**由 iu_bht_check_vld 训练 (条件分支)。绝不能用 iu_btb_update_vld,
//    那个还含 JAL/JALR —— 会给没有方向的分支教 "taken"。
// ⚠️ TAGE 还要一位 upd_fpred: 预测当时方向表**原始**给出的方向。顶层**不能**拿
//    iu_bht_pred 顶替 (那是 sl_taken, 被 btb_vld 门控过), 见 rv32ifu2_tage.v 头注释。
generate
if (BP_PRED_MODE == 0) begin : g_gshare
    wire [ 7:0] bht_ctr;       // 4 slot × 2 bit 计数器
    wire        bht_init_done;
    // ⚠️ {a,b,c,d} 是高位在前: 这样拼 bit0 才是 slot0 (原设计在这里整体倒过一次)
    wire [ 3:0] bht_taken = {bht_ctr[7], bht_ctr[5], bht_ctr[3], bht_ctr[1]};

    assign dir_pred      = bht_taken;
    assign dir_init_done = bht_init_done;

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
end else begin : g_tage
    wire [ 3:0] tage_pred;
    wire        tage_init_done;

    assign dir_pred      = tage_pred;
    assign dir_init_done = tage_init_done;

    rv32ifu2_tage #(
        .T0_AW   (TAGE_T0_AW),
        .ROW_AW  (TAGE_ROW_AW),
        .ROW_AW_T1 (TAGE_RA1),
        .ROW_AW_T2 (TAGE_RA2),
        .ROW_AW_T3 (TAGE_RA3),
        .ROW_AW_T4 (TAGE_RA4),
        .NTAB    (TAGE_NTAB),
        .TAG_W   (TAGE_TAG_W),
        .GHR_W   (GHR_W),
        .T0_HIST (TAGE_T0_HIST),
        .SLOTS   (4),
        .TAG_HI  (15),
        .L1      (TAGE_L1),
        .L2      (TAGE_L2),
        .L3      (TAGE_L3),
        .L4      (TAGE_L4),
        .USEL_AW (TAGE_USEL_AW),
        .USEL_W  (TAGE_USEL_W),
        .USEL_GATE (TAGE_USEL_GATE)
    ) u_tage (
        .clk       (clk),
        .rst       (rst),
        .rd_pc     (next_pc),
        .rd_ghr    (ghr_after),
        .slot_pred (tage_pred),
        .init_done (tage_init_done),
        .upd_vld   (iu_bht_check_vld),
        .upd_pc    (iu_cur_pc),
        .upd_ghr   (iu_chk_idx[GHR_W-1:0]),
        .upd_taken (iu_bht_condbr_taken),
        .upd_fpred (iu_btb_chk[CHK_FPRED])
    );
end
endgenerate


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
// 推进量 = 实际收下的条数 × 4 (最大 4 条 = 16 B, 正好一个块)
wire [31:0] pc_adv = {27'd0, ib_push_acc, 2'b00};

// 只有"想推的条数全部推进去了"才算真的走到了那条 taken 分支, 这时 PC 才去目标。
// 队列空间不够时只推进了一部分, 分支还没进去, PC 必须按顺序继续 —— 否则会跳过
// 分支之前那些还没交付的指令。
wire reached_taken = any_taken & (ib_push_acc == want_cnt_raw);

assign next_pc = rst            ? RESET_PC
               : redirect       ? redirect_pc
               : reached_taken  ? taken_tgt
               :                  (q_pc + pc_adv);

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
assign init_done = init_all;

// ---------------------------------------------------------------------------
// chk 位预算自检 (照 rv32ifu2_icache.v 对 IC_WAYS 的做法)
// 见 CHK_* 那段注释: 越界是**静默**失效, 必须显式拦。
// ---------------------------------------------------------------------------
// synopsys translate_off
initial begin
    if (CHK_FPRED >= CHK_W) begin
        $display("[IFU2-TOP] chk 只有 %0d 位, 但 GHR_W=%0d 把 CHK_FPRED 顶到 %0d —— 放不下。",
                 CHK_W, GHR_W, CHK_FPRED);
        $display("           把 GHR_W 压到 <= %0d, 或者把 chk 整体加宽 (IBUF 宽度 /",
                 CHK_W - RAS_AW - 4);
        $display("           idu_inst*_chk / IF_ID / ID_EX / tb 的切片都要跟着改)。");
        $fatal;
    end
    $display("[IFU2-TOP] GHR_W=%0d chk: GHR[%0d:0] ras[%0d:%0d] BTBHIT=%0d PREDTK=%0d FPRED=%0d",
             GHR_W, GHR_W-1, RAS_CHK_MSB, RAS_CHK_LSB, CHK_BTBHIT, CHK_PREDTK, CHK_FPRED);
end
// synopsys translate_on


endmodule
