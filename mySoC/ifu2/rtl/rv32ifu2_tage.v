`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_tage — TAGE 方向预测器 (按 TAGE_branch_predi.md)
//
// 与 rv32ifu2_bht.v (gshare) 同一组端口的替代品: F0 给"下一个取指地址"+GHR,
// F1 出整块 4 个 slot 的方向。顶层由 BP_PRED 选。
//
// 为什么必须按**块**索引而不是按分支 PC: 2 级流水要求预测在译码之前就绪,
// 一次查表要覆盖整个 16 B 块的 4 个位置。所以一行 = 一个块 = 4 个 slot,
// 与 rv32ifu2_btb.v 同行几何。代价是 slot 维度的利用率不高 —— 核心每拍只吃
// 一条 (mycpu.v 的 idu_accept_num 恒 0/1), 稳态是每拍推一条 lane, 一行 4 个
// slot 多数时候只用得上 1 个。doc §4 有实测数字。
//
// ---------------------------------------------------------------------------
// 结构
// ---------------------------------------------------------------------------
//   T0            块 PC 直接索引, 4 slot × 2 位饱和计数器, **必定命中**
//   T1..TN        每行 = {行有效, tag[TAG_W-1:0]} + 4 × {slot有效, pred[2:0], u[1:0]}
//     index_i = pc[ROW_AW+3:4] ^ fold(ghr, L_i, ROW_AW)
//     tag_i   = pc[TAG_HI:ROW_AW+4] ^ rotl(fold(ghr, L_i, TAG_W), i mod TAG_W)
//     hit_i(s)= 行有效 & (tag_i == 存的 tag) & slot有效
//   provider = 命中的表里 L 最大的 (都不命中 = T0); altpred = 次长命中的表 (都不命中 = T0)
//   fpred    = provider 强信心 ? provider 的 pred : altpred      (静态策略)
//
// ⚠️ **slot 有效位是必需的**。没有它, slot 0 分配出来的行会替 slot 2 的另一个
//    分支冒充 provider —— 那一条的表项从没学过, 却会把它的 pred 当真。
//
// ⚠️ **tag 宽度受 64 KB 地址空间限制**: tag 用的是 pc[TAG_HI:ROW_AW+4],
//    TAG_HI=15 (与 rv32ifu2_btb.v 同一个理由, 见那里的注释), 所以
//    TAG_W <= 12 - ROW_AW。方向表假命中的代价只是一次误预测(不像 BTB 会取错
//    指令), 但仍然不该超出这个上限。initial 块里有自检。
//
// ---------------------------------------------------------------------------
// folded history 用**组合折叠**, 不维护增量寄存器
// ---------------------------------------------------------------------------
//   fold(ghr,L,W)[j] = ^_{k: j+kW < L} ghr[j+kW]     —— 只吃 h[0:L-1]
// GHR 只有 GHR_W 位, 一棵 XOR 树而已。增量方案要每张表两个 folded 寄存器,
// **外加"移出窗口的位"的修正项** (L 不是 W 整数倍时要在位置 L mod W 上再 XOR
// 掉 h[L-1]), 漏掉就静默算错; 组合版结构上不可能出这类错。
// 每张表必须只吃 h[0:L_i-1] —— 吃满 GHR 的话"几何历史长度"就失去意义。
//
// ---------------------------------------------------------------------------
// 训练: 在 EX **重算**, 只从 chk 带 1 位过来
// ---------------------------------------------------------------------------
// 一开始的设计是"预测时把 provider 编号 + altpred 存进 chk 带到 EX"。评审推翻:
//   1. F1→EX 有 4 拍以上 (IBUF 8 深 + 核心停顿), 期间表还在被别的分支写。
//      拿携带的编号直接当写地址, 中途发生行替换就会去改**别的块**的表项。
//   2. 那些字段在初始化扫描期间会是 X, X 当 mux 选择会**写进表状态**。
// ⇒ 现在只带 `upd_fpred` 一位 (预测当时真正给出的方向; EX 侧无法重算 —— 表项
//    可能已经变了), 其余全部用 (upd_pc, upd_ghr) 按**同一批函数**重算。
//
// ⚠️ 顶层**不能**拿 iu_bht_pred 顶替 upd_fpred: 那个是
//    `sl_taken = btb_cond & bht_taken & init_done`, 被 btb_vld 门控过。
//    BTB 里没有这一行时它是 0, 而 TAGE 可能给了 1 —— u 更新会被整段跳过,
//    分配还会在"纯 BTB miss"上误触发。
//
// ⚠️ 训练只由条件分支驱动 (iu_bht_check_vld), **绝不能**用 iu_btb_update_vld
//    (那个还含 JAL/JALR, 会给没有方向的分支教"taken")。
// ===========================================================================
module rv32ifu2_tage #(
    parameter T0_AW    = 6,            // T0 行数 log2
    parameter ROW_AW   = 6,            // 每张 tagged 表行数 log2
    parameter NTAB     = 4,            // tagged 表数 (1..4)
    parameter TAG_W    = 6,            // 行标签位宽 (<= 12-ROW_AW, 见头注释)
    parameter GHR_W    = 16,
    parameter T0_HIST  = 0,            // T0 索引里掺几位历史 (0 = 按规格的纯双模态)
    parameter SLOTS    = 4,
    parameter TAG_HI   = 15,           // 地址空间上界 (64 KB)
    parameter L1       = 2,
    parameter L2       = 5,
    parameter L3       = 9,
    parameter L4       = 14
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- F0: 用"下一个取指地址" + 该次取指生效的 GHR 索引 ----
    input  wire [ 31:0]     rd_pc,
    input  wire [GHR_W-1:0] rd_ghr,

    // ---- F1: 逐 slot 的方向 ----
    output wire [SLOTS-1:0] slot_pred,
    output wire             init_done,

    // ---- 训练 (EX 级, 1 拍脉冲; 由 iu_bht_check_vld 驱动, 仅条件分支) ----
    input  wire             upd_vld,
    input  wire [ 31:0]     upd_pc,
    input  wire [GHR_W-1:0] upd_ghr,   // 该分支取指时的 GHR 快照 (chk)
    input  wire             upd_taken,
    input  wire             upd_fpred    // 预测当时给出的方向 (chk 的 CHK_FPRED)
);

localparam NR_ROWS   = 1 << ROW_AW;
localparam T0_ROWS   = 1 << T0_AW;
localparam SLOT_W    = 6;                        // {valid, pred[2:0], u[1:0]}
localparam NTABMAX   = 4;
localparam PV_DEPTH  = NTAB * NR_ROWS * SLOTS;
localparam TAG_DEPTH = NTAB * NR_ROWS;

// 初始化扫描的行数 = 两张表里行数多的那个。两边的行索引各自按自己的位宽绕行
// (照 rv32ifu2_btb.v 的做法), 绕行只会多清几遍, 不会漏。
localparam INIT_ROWS = (T0_AW > ROW_AW) ? T0_ROWS : NR_ROWS;
localparam INIT_AW   = (T0_AW > ROW_AW) ? T0_AW   : ROW_AW;

// ---------------------------------------------------------------------------
// fold / rotl / 索引 / 标签 / 计数器
//
// ⚠️ 这组函数是**唯一**的公式来源, 读侧 (rd_pc/rd_ghr) 与写侧 (upd_pc/upd_ghr)
//    都调它们。本工程用血换来的规矩: 读索引与写索引必须是同一个公式
//    (memory bp-class3-root-cause —— 读写 GHR 位窗不一致, 让一整类分支在整个
//    仿真里收到 0 次写)。谁要加一条"另一条路"的索引, 先把这条想清楚。
// ---------------------------------------------------------------------------
function [31:0] foldh;
    input [GHR_W-1:0] h;
    input integer     L;
    input integer     W;
    integer j, k;
    reg [31:0] o;
    begin
        o = 32'b0;
        for (j = 0; j < W; j = j + 1)
            for (k = j; k < L; k = k + W)
                o[j] = o[j] ^ h[k];
        foldh = o;
    end
endfunction

function [TAG_W-1:0] rotl_tag;
    input [TAG_W-1:0] x;
    input integer     r;
    integer b;
    reg [TAG_W-1:0] y;
    begin
        y = {TAG_W{1'b0}};
        for (b = 0; b < TAG_W; b = b + 1)
            y[(b + r) % TAG_W] = x[b];
        rotl_tag = y;
    end
endfunction

function [ROW_AW-1:0] tage_idx;
    input [31:0]      pc;
    input [GHR_W-1:0] h;
    input integer     L;
    begin
        tage_idx = pc[ROW_AW+3:4] ^ foldh(h, L, ROW_AW);
    end
endfunction

function [TAG_W-1:0] tage_tag;
    input [31:0]      pc;
    input [GHR_W-1:0] h;
    input integer     L;
    input integer     r;
    begin
        tage_tag = pc[TAG_HI:ROW_AW+4] ^ rotl_tag(foldh(h, L, TAG_W), r);
    end
endfunction

function [T0_AW-1:0] t0_index;
    input [31:0]      pc;
    input [GHR_W-1:0] h;
    reg [T0_AW-1:0] x;
    begin
        x = pc[T0_AW+3:4];
        if (T0_HIST > 0) x = x ^ foldh(h, T0_HIST, T0_AW);
        t0_index = x;
    end
endfunction

function [2:0] ctr3_next;                  // 3 位饱和计数器
    input [2:0] c;
    input       up;
    begin
        if (up) ctr3_next = (c == 3'b111) ? 3'b111 : (c + 3'd1);
        else    ctr3_next = (c == 3'b000) ? 3'b000 : (c - 3'd1);
    end
endfunction

function [1:0] ctr2_next;                  // 2 位饱和计数器
    input [1:0] c;
    input       up;
    begin
        if (up) ctr2_next = (c == 2'b11) ? 2'b11 : (c + 2'd1);
        else    ctr2_next = (c == 2'b00) ? 2'b00 : (c - 2'd1);
    end
endfunction

// 弱信心 = 3'b011 / 3'b100 (规格 §fpred 生成策略)
function is_weak;
    input [2:0] c;
    begin is_weak = (c == 3'b011) || (c == 3'b100); end
endfunction

// ---------------------------------------------------------------------------
// 表
//   tag_q: 第 i 张表 (i=1..NTAB) 在 [ (i-1)*NR_ROWS +: NR_ROWS ]
//   pv_q : 第 i 张表第 r 行第 s 个 slot 在 [ ((i-1)*NR_ROWS + r)*SLOTS + s ]
// ---------------------------------------------------------------------------
reg [TAG_W:0]    tag_q [0:TAG_DEPTH-1];    // {行有效, tag}
reg [SLOT_W-1:0] pv_q  [0:PV_DEPTH-1];
reg [1:0]        t0_q  [0:T0_ROWS*SLOTS-1];

// ---------------------------------------------------------------------------
// 初始化扫描计数器 (声明放前面: 写口那个 always 要用)
// ---------------------------------------------------------------------------
reg             init_done_q;
reg [INIT_AW:0] init_cnt;

assign init_done = init_done_q;

always @(posedge clk) begin
    if (rst) begin
        init_done_q <= 1'b0;
        init_cnt    <= {(INIT_AW+1){1'b0}};
    end else if (!init_done_q) begin
        if (init_cnt == (INIT_ROWS-1)) init_done_q <= 1'b1;
        init_cnt <= init_cnt + 1'b1;
    end
end

// ===========================================================================
// F0 → F1: 只寄存索引与标签 (与 rv32ifu2_bht.v / rv32ifu2_btb.v 同一拍型)
// ===========================================================================
wire [ROW_AW-1:0] rd_idx [0:NTAB-1];
wire [TAG_W-1:0]  rd_tag [0:NTAB-1];
wire [T0_AW-1:0]  rd_t0;

genvar gi, gs;
generate
for (gi = 0; gi < NTAB; gi = gi + 1) begin : g_f0
    localparam LI  = (gi == 0) ? L1 : (gi == 1) ? L2 : (gi == 2) ? L3 : L4;
    localparam ROT = gi % TAG_W;
    assign rd_idx[gi] = tage_idx (rd_pc, rd_ghr, LI);
    assign rd_tag[gi] = tage_tag (rd_pc, rd_ghr, LI, ROT);
end
endgenerate
assign rd_t0 = t0_index (rd_pc, rd_ghr);

reg [ROW_AW-1:0] q_idx [0:NTAB-1];
reg [TAG_W-1:0]  q_tag [0:NTAB-1];
reg [T0_AW-1:0]  q_t0;

integer rj;
always @(posedge clk) begin
    if (rst) begin
        for (rj = 0; rj < NTAB; rj = rj + 1) begin
            q_idx[rj] <= {ROW_AW{1'b0}};
            q_tag[rj] <= {TAG_W{1'b0}};
        end
        q_t0 <= {T0_AW{1'b0}};
    end else begin
        for (rj = 0; rj < NTAB; rj = rj + 1) begin
            q_idx[rj] <= rd_idx[rj];
            q_tag[rj] <= rd_tag[rj];
        end
        q_t0 <= rd_t0;
    end
end

// ---------------------------------------------------------------------------
// F1: 逐表读行 → 摊平成 4×SLOTS 的总线 (NTABMAX 宽, 未用的表恒 0)
//   行标签是**整行共享**的 (一个块一个 tag), slot 靠自己的有效位区分。
//   所以 hit 是 (表, slot) 二维的。
// ---------------------------------------------------------------------------
wire [NTABMAX*SLOTS-1:0]   tb_hit;
wire [NTABMAX*SLOTS-1:0]   tb_pred;
wire [NTABMAX*SLOTS-1:0]   tb_weak;
wire [NTABMAX*SLOTS*2-1:0] tb_u;

generate
for (gi = 0; gi < NTABMAX; gi = gi + 1) begin : g_f1
    if (gi < NTAB) begin : g_used
        wire [TAG_W:0] rt = tag_q[gi*NR_ROWS + q_idx[gi]];
        wire           tm = (rt[TAG_W-1:0] == q_tag[gi]);
        for (gs = 0; gs < SLOTS; gs = gs + 1) begin : g_s
            wire [SLOT_W-1:0] pv = pv_q[(gi*NR_ROWS + q_idx[gi])*SLOTS + gs];
            // slot 有效位是必需的, 见头注释
            assign tb_hit [gi*SLOTS + gs] = rt[TAG_W] & tm & pv[5];
            assign tb_pred[gi*SLOTS + gs] = pv[4];
            assign tb_weak[gi*SLOTS + gs] = is_weak (pv[4:2]);
            assign tb_u   [(gi*SLOTS + gs)*2 +: 2] = pv[1:0];
        end
    end else begin : g_unused
        for (gs = 0; gs < SLOTS; gs = gs + 1) begin : g_s
            assign tb_hit [gi*SLOTS + gs] = 1'b0;
            assign tb_pred[gi*SLOTS + gs] = 1'b0;
            assign tb_weak[gi*SLOTS + gs] = 1'b0;
            assign tb_u   [(gi*SLOTS + gs)*2 +: 2] = 2'b00;
        end
    end
end
endgenerate

// ---------------------------------------------------------------------------
// provider / alternate 选择 (逐 slot)。高位 = 历史更长的表。
// ---------------------------------------------------------------------------
wire [2:0] prov_sel [0:SLOTS-1];           // 0 = T0, 1..NTAB = 表编号
wire [2:0] alt_sel  [0:SLOTS-1];

generate
for (gs = 0; gs < SLOTS; gs = gs + 1) begin : g_sel
    wire h4 = (NTAB >= 4) ? tb_hit[3*SLOTS + gs] : 1'b0;
    wire h3 = (NTAB >= 3) ? tb_hit[2*SLOTS + gs] : 1'b0;
    wire h2 = (NTAB >= 2) ? tb_hit[1*SLOTS + gs] : 1'b0;
    wire h1 = (NTAB >= 1) ? tb_hit[0*SLOTS + gs] : 1'b0;

    assign prov_sel[gs] = h4 ? 3'd4 : h3 ? 3'd3 : h2 ? 3'd2 : h1 ? 3'd1 : 3'd0;
    assign alt_sel [gs] = h4 ? (h3 ? 3'd3 : h2 ? 3'd2 : h1 ? 3'd1 : 3'd0)
                        : h3 ? (h2 ? 3'd2 : h1 ? 3'd1 : 3'd0)
                        : h2 ? (h1 ? 3'd1 : 3'd0)
                        : 3'd0;
end
endgenerate

wire [SLOTS-1:0] t0_pred = { t0_q[q_t0*SLOTS+3][1], t0_q[q_t0*SLOTS+2][1],
                             t0_q[q_t0*SLOTS+1][1], t0_q[q_t0*SLOTS+0][1] };

wire [SLOTS-1:0] prov_pred, prov_weak, alt_pred, fpred_raw;
generate
for (gs = 0; gs < SLOTS; gs = gs + 1) begin : g_fp
    wire [2:0] ps = prov_sel[gs];
    wire [2:0] as = alt_sel[gs];
    assign prov_pred[gs] = (ps == 3'd0) ? t0_pred[gs] : tb_pred[(ps-1)*SLOTS + gs];
    assign prov_weak[gs] = (ps == 3'd0) ? 1'b0        : tb_weak[(ps-1)*SLOTS + gs];
    assign alt_pred [gs] = (as == 3'd0) ? t0_pred[gs] : tb_pred[(as-1)*SLOTS + gs];
    // 只有 T0 命中时 ps==0 ⇒ 直接用 T0, 且此时 as 也必为 0 ⇒ altpred == fpred
    // ⇒ u 的更新条件恒不成立 (与规格"若仅命中 T0, 则 T0 也是 altpred"一致)
    assign fpred_raw[gs] = (ps == 3'd0) ? t0_pred[gs]
                         : (prov_weak[gs] ? alt_pred[gs] : prov_pred[gs]);
end
endgenerate

// ⚠️ 初始化扫描期间阵列还是 X, 而 `valid & (tag == …)` 在 valid 为 X 时是 **X 不是 0**,
//    会一路传到 next_pc。用 AND 门控, **不能**用三元 (X ? a : b 是逐位合并, 不是干净的 0)。
assign slot_pred = fpred_raw & {SLOTS{init_done}};

// ===========================================================================
// 训练路径: 用 (upd_pc, upd_ghr) 重算一切
// ===========================================================================
wire [ROW_AW-1:0] u_idx [0:NTAB-1];
wire [TAG_W-1:0]  u_tag [0:NTAB-1];
generate
for (gi = 0; gi < NTAB; gi = gi + 1) begin : g_u0
    localparam LI  = (gi == 0) ? L1 : (gi == 1) ? L2 : (gi == 2) ? L3 : L4;
    localparam ROT = gi % TAG_W;
    assign u_idx[gi] = tage_idx (upd_pc, upd_ghr, LI);
    assign u_tag[gi] = tage_tag (upd_pc, upd_ghr, LI, ROT);
end
endgenerate

wire [1:0]        u_s    = upd_pc[3:2];
wire [T0_AW-1:0]  u_t0i  = t0_index (upd_pc, upd_ghr);
// T0 是 2 位计数器, 借高两位拼成"3 位口径"以便和 tagged 表统一比较 ——
// 只有 bit[2] (方向) 会被用到。
wire [2:0]        t0_pred_u = {t0_q[u_t0i*SLOTS + u_s][1], 2'b00};

wire [SLOT_W-1:0] u_ent [0:NTAB-1];
wire              u_hit [0:NTAB-1];
wire [TAG_W:0]    u_rt  [0:NTAB-1];
generate
for (gi = 0; gi < NTAB; gi = gi + 1) begin : g_ur
    assign u_rt [gi] = tag_q[gi*NR_ROWS + u_idx[gi]];
    assign u_ent[gi] = pv_q[(gi*NR_ROWS + u_idx[gi])*SLOTS + u_s];
    assign u_hit[gi] = u_rt[gi][TAG_W] & (u_rt[gi][TAG_W-1:0] == u_tag[gi]) & u_ent[gi][5];
end
endgenerate

// provider / alternate (训练侧)。用 done 标志退出循环, 不用"把循环变量设成 -1"那种写法。
integer pi;
reg [2:0] u_prov, u_alt;
always @* begin
    u_prov = 3'd0;
    u_alt  = 3'd0;
    for (pi = NTAB - 1; pi >= 0; pi = pi - 1)
        if (u_hit[pi] && (u_prov == 3'd0)) u_prov = pi + 1;
    if (u_prov != 3'd0)
        for (pi = u_prov - 2; pi >= 0; pi = pi - 1)
            if (u_hit[pi] && (u_alt == 3'd0)) u_alt = pi + 1;
end

// ⚠️ u_prov / u_alt 为 0 时下面的 u_ent[..-1] 会越界读。用一个"安全编号"顶住 ——
//    那两个分支的结果在 u_prov==0 时本来就不使用。
wire [2:0] u_prov_s = (u_prov == 3'd0) ? 3'd1 : u_prov;
wire [2:0] u_alt_s  = (u_alt  == 3'd0) ? 3'd1 : u_alt;

wire [2:0] u_ppred = (u_prov == 3'd0) ? t0_pred_u : u_ent[u_prov_s-1][4:2];
wire [2:0] u_apred = (u_alt  == 3'd0) ? t0_pred_u : u_ent[u_alt_s -1][4:2];
wire       u_misp  = (upd_fpred != upd_taken);

wire [1:0] u_prov_new_u = ctr2_next (u_ent[u_prov_s-1][1:0], upd_fpred == upd_taken);
wire [2:0] u_prov_new_p = ctr3_next (u_ppred, upd_taken);
wire [1:0] u_t0_new     = ctr2_next (t0_q[u_t0i*SLOTS + u_s], upd_taken);

// ---------------------------------------------------------------------------
// 分配 (规格 §6 策略 A/B/C)
//
//   A 优先级: 在**比 provider 更长**的表里挑 u==0 的**最短**那张
//   B 避免乒乓: 有多张 u==0 时取历史长度短的 (上面的"最短"扫描就是它)
//   C 初始化: 写 tag, pred = 本次结果的**弱**方向, u = 0
//
// 三处对规格的偏离, 都在 doc §4 记了:
//   * 范围含**最长表** (原文 i<k<M 把最长表排除 ⇒ 它永远分配不到 ⇒ 死表)
//   * pred 初始化成弱方向 (011/100) 而不是强极值 —— 刚分配就不可替换是坏事
//   * 只有**行标签真的被替换**时才清同行其它 slot。无条件清会让同块两条分支
//     轮流擦掉对方的项, 每一轮都重来一次, 永不收敛。
//
// ⚠️ u 的候选判据是 `u_eff = u & 行有效 & slot有效`: 没分配过的项 u 是陈旧值,
//    不门控就会把本该分配的那张表跳过去, 转去做老化递减。
//
// 一个能用的副产品: `u_k == 0` ⇒ 所有更长的表都满足"行有效 & slot有效 & u≠0"
// ⇒ 它们**都写过**, 于是老化递减那一支读到的 u/pred 一定是干净的 (不是 X),
// 不需要再单独防护。
// ---------------------------------------------------------------------------
wire [1:0] u_eff [0:NTAB-1];
generate
for (gi = 0; gi < NTAB; gi = gi + 1)
    // ⚠️ 门控信号**必须来自扫描清过的位** (row_valid), 光用 slot_valid 不够:
    //    从未写过的项 slot_valid 也是 X, `X & X = X`, 于是下面的 `u_eff==0`
    //    比较恒为假 ⇒ **一行都分配不出去**。实测症状就是
    //    `TAGE rows valid = 0 / 256` + 类 3 恰好回到 50.00% + 类 5 掉到 74.41%
    //    (= 只剩 T0 双模态在干活), 而所有其它数都正常。
    //    另外**不能**写成 `slot_valid ? u : 2'b00` 那种三元 —— `X ? a : b` 是
    //    逐位合并而不是干净的 0。`X & 0 = 0` 才是本工程反复记过的那条规矩。
    assign u_eff[gi] = u_ent[gi][1:0] & {2{u_rt[gi][TAG_W] & u_ent[gi][5]}};
endgenerate

integer ci;
reg [2:0] u_k;                             // 0 = 不分配
reg       u_k_tag_same;
always @* begin
    u_k = 3'd0;
    for (ci = ((u_prov == 3'd0) ? 0 : u_prov); ci < NTAB; ci = ci + 1)
        if ((u_eff[ci] == 2'b00) && (u_k == 3'd0)) u_k = ci + 1;
    u_k_tag_same = 1'b0;
    if (u_k != 3'd0)
        u_k_tag_same = u_rt[u_k-1][TAG_W] & (u_rt[u_k-1][TAG_W-1:0] == u_tag[u_k-1]);
end

wire [2:0] u_k_pred = upd_taken ? 3'b100 : 3'b011;

// 老化递减: 比 provider 更长的表的 u 各减 1 (规格 §6 (A)-2, 类 LSU 效果)
wire [1:0] u_age [0:NTAB-1];
generate
for (gi = 0; gi < NTAB; gi = gi + 1)
    assign u_age[gi] = (u_ent[gi][1:0] == 2'b00) ? 2'b00 : (u_ent[gi][1:0] - 2'd1);
endgenerate

// ---------------------------------------------------------------------------
// 写口。所有写入落在**互不重叠**的 word 上: provider 的表 vs 分配/老化落到的
// 更长的表, 按构造是不同表。
// ---------------------------------------------------------------------------
integer wi, wj;
always @(posedge clk) begin
    if (rst) begin
        // 什么都不做: 复位后的清零交给下面的初始化扫描 (与 btb/bht/icache 同一套做法)
    end else if (!init_done_q) begin
        // 初始化扫描: 各表并行, 行索引各按自己的位宽绕行。
        // 扫描期间**丢掉训练**: 此时行有效位还是 X, `X & (tag==)` 是 X 不是 0,
        // 会让 provider 选择变成 X 并写进表里 (永久污染, 症状见 doc §5 第 3 条)。
        for (wi = 0; wi < NTAB; wi = wi + 1)
            tag_q[wi*NR_ROWS + init_cnt[ROW_AW-1:0]] <= {(TAG_W+1){1'b0}};
        for (wi = 0; wi < SLOTS; wi = wi + 1)
            t0_q[init_cnt[T0_AW-1:0]*SLOTS + wi] <= 2'b00;
        // pv_q **也要清**。只清 tag 那一行的话, 行有效位虽然是干净的 0, 但
        // u/pred/slot_valid 全是 X, 而分配逻辑必须去读"没分配过"的项的 u
        // (规格 §6: 读比 provider 更长的表的 u) —— 读到 X 就整条分配路径失效。
        // 代价是这一支里 4 表 × 4 slot = 16 个写口, 但只在复位后那几十拍上电,
        // 折成多路选择器而不是真的 16 口 RAM (这些阵列本来就落成寄存器)。
        // 换掉的写法 (只靠 row_valid 门控) 依赖一条归纳出来的不变量"有效行里
        // 所有 slot 位都是已知的", 那种东西迟早会被下一次改动悄悄破坏。
        for (wi = 0; wi < NTAB; wi = wi + 1)
            for (wj = 0; wj < SLOTS; wj = wj + 1)
                pv_q[(wi*NR_ROWS + init_cnt[ROW_AW-1:0])*SLOTS + wj] <= {SLOT_W{1'b0}};
    end else if (upd_vld) begin
        // 1) provider 的 pred **无条件**更新 (规格 §5/§6);
        //    u 只在 `altpred != fpred` 时更新。
        //    静态策略下该条件成立时必有 fpred == provider_pred, 所以 u 的增减方向
        //    就是"fpred 猜没猜对"。⚠️ 将来若上动态 USE_SEL, 这个等价不成立,
        //    那时必须把 provider_pred 也一起带出到 EX。
        if (u_prov == 3'd0) begin
            t0_q[u_t0i*SLOTS + u_s] <= u_t0_new;
        end else if (u_apred[2] != upd_fpred) begin
            pv_q[(u_prov-1)*NR_ROWS*SLOTS + u_idx[u_prov-1]*SLOTS + u_s]
                <= {1'b1, u_prov_new_p, u_prov_new_u};
        end else begin
            pv_q[(u_prov-1)*NR_ROWS*SLOTS + u_idx[u_prov-1]*SLOTS + u_s]
                <= {1'b1, u_prov_new_p, u_ent[u_prov-1][1:0]};
        end

        // 2) 误预测 ⇒ 分配 / 老化
        if (u_misp) begin
            if (u_k != 3'd0) begin
                pv_q[(u_k-1)*NR_ROWS*SLOTS + u_idx[u_k-1]*SLOTS + u_s]
                    <= {1'b1, u_k_pred, 2'b00};
                tag_q[(u_k-1)*NR_ROWS + u_idx[u_k-1]] <= {1'b1, u_tag[u_k-1]};
                for (wi = 0; wi < SLOTS; wi = wi + 1)
                    if ((wi != u_s) && !u_k_tag_same)
                        pv_q[(u_k-1)*NR_ROWS*SLOTS + u_idx[u_k-1]*SLOTS + wi]
                            <= {SLOT_W{1'b0}};
            end else begin
                for (wi = ((u_prov == 3'd0) ? 0 : u_prov); wi < NTAB; wi = wi + 1)
                    pv_q[wi*NR_ROWS*SLOTS + u_idx[wi]*SLOTS + u_s]
                        <= {u_ent[wi][5], u_ent[wi][4:2], u_age[wi]};
            end
        end
    end
end

// ---------------------------------------------------------------------------
// 自检 + 配置打印 (照 rv32ifu2_icache.v 的做法)
//
// 扫点前**先看这一行**: 原树 icache 参数化就踩过"改的 define 没进到 RTL,
// 于是所有'不同配置'其实是同一个配置, 整张表作废" (memory icache-geometry-bugs.md)。
// ---------------------------------------------------------------------------
// synopsys translate_off
initial begin
    if ((NTAB < 1) || (NTAB > NTABMAX)) begin
        $display("[IFU2-TAGE] NTAB=%0d 未实现 (只支持 1..%0d)", NTAB, NTABMAX);
        $fatal;
    end
    if (SLOTS != 4) begin
        $display("[IFU2-TAGE] SLOTS=%0d 未实现 (只支持 4: 与 16 B 取指块对应)", SLOTS);
        $fatal;
    end
    if (TAG_W > (TAG_HI - (ROW_AW + 4) + 1)) begin
        $display("[IFU2-TAGE] TAG_W=%0d 超出 64 KB 地址空间能给的位置 (%0d)",
                 TAG_W, TAG_HI - (ROW_AW + 4) + 1);
        $fatal;
    end
    if ((L1 > GHR_W) || (L2 > GHR_W) || (L3 > GHR_W) || (L4 > GHR_W)) begin
        $display("[IFU2-TAGE] 历史长度超过 GHR_W=%0d, 折叠会退化", GHR_W);
        $fatal;
    end
    $display("[IFU2-TAGE] T0=%0d(H=%0d) TAB=%0d ROWS=%0d TAG_W=%0d GHR=%0d L=%0d/%0d/%0d/%0d AREA=%0d bit",
             T0_ROWS, T0_HIST, NTAB, NR_ROWS, TAG_W, GHR_W, L1, L2, L3, L4,
             T0_ROWS*SLOTS*2 + NTAB*NR_ROWS*(1+TAG_W) + NTAB*NR_ROWS*SLOTS*SLOT_W + GHR_W);
end
// synopsys translate_on

endmodule
