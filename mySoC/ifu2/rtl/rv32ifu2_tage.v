`timescale 1ns / 1ps

//----------------------------------------------------------------------------
// rv32ifu2 — 自研两级取指前端 (mySoC/ifu2)
//
//---------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
//---------------------------------------------------------------------------
//
// Purpose : TAGE 方向预测器 (按 TAGE_branch_predi.md)
//
//   与 rv32ifu2_bht.v (gshare) 同一组端口的替代品: F0 给"下一个取指地址" + GHR,
//   F1 出整块 4 个 slot 的方向。顶层由 BP_PRED 选。
//
//   为什么必须按**块**索引而不是按分支 PC: 2 级流水要求预测在译码之前就绪,
//   一次查表要覆盖整个 16 B 块的 4 个位置。所以一行 = 一个块 = 4 个 slot,
//   与 rv32ifu2_btb.v 同行几何。代价是 slot 维度的利用率不高 —— 核心每拍只吃
//   一条 (mycpu.v 的 idu_accept_num 恒 0/1), 稳态是每拍推一条 lane, 一行 4 个
//   slot 多数时候只用得上 1 个。doc §4 有实测数字。
//
// Usage :
//   rv32ifu2_top.v 的 g_tage 分支例化本模块 (BP_PRED=1 时; 回 gshare 基线用
//   `make ... BP_PRED=0`)。几何由 Makefile 的 BP_TAGE_* 传进来, 约束见文件末尾
//   的 initial 自检块。
//
// Table structure :
//   T0            块 PC 直接索引, 4 slot × 2 位饱和计数器, **必定命中**
//   T1..TN        每行 = {行有效, tag[TAG_W-1:0]} + 4 × {slot有效, pred[2:0], u[1:0]}
//     index_i = pc[ROW_AW+3:4] ^ fold(ghr, L_i, ROW_AW)
//     tag_i   = pc[TAG_HI:ROW_AW+4] ^ rotl(fold(ghr, L_i, TAG_W), i mod TAG_W)
//     hit_i(s)= 行有效 & (tag_i == 存的 tag) & slot有效
//   provider = 命中的表里 L 最大的 (都不命中 = T0)
//   altpred  = 次长命中的表 (都不命中 = T0)
//   USE_SEL  = **有符号** 4 位饱和计数器组, 按分支 PC 直接索引 (不吃历史, 无 tag)
//   fpred    = (provider 强信心 || USE_SEL < 0) ? provider 的 pred : altpred
//
// fpred 生成策略 (规格 §fpred 生成策略):
//   静态: fpred = provider 强信心 ? provider : altpred
//   动态: 用 USE_SEL 决定"provider 信心不足时"怎么选 ——
//           fpred = (!weak || USE_SEL < 0) ? provider : altpred
//           altpred 与真实结果相同 ⇒ USE_SEL 递增, 否则递减 (两边都饱和)
//
//   ⚠️ **规格那条规则与它自己的前文打架, 本实现按前文 + 参考实现取"或"。**
//      前文说 USE_SEL 决定"pcpn **信心不足**时"的选择方式 —— 只有"或"能兑现这句。
//      规则原文写的是"不为弱**且** USE_SEL 为负"; 而规格链的 TAGE-SC-L 原文是
//      "if (the confidence counter is not weak **or** USE ALT ON NA is negative)"。
//      两种读法在**正好相反的两格**上不同:
//          弱 & SEL<0 : "或"→provider   "且"→altpred
//          强 & SEL>=0: "或"→provider   "且"→altpred
//      "或"让强信心恒赢, 是经典 TAGE 的形式, 反馈稳定。要回"且"只改 fpred 那一行。
//
//   USE_SEL 清成 0 ⇒ 弱信心时选 altpred ⇒ **上电行为与静态策略逐位相同**, 之后才收敛。
//   后果: 弱信心那一档的取舍从此是学出来的, 不再是设计时写死的 3'b011/3'b100。
//
//   ⚠️ **USE_SEL 不需要额外的 chk 位。** 本文件与 doc §4 都记过一条待办
//      ("上动态 USE_SEL 必须把 provider_pred 也带到 EX") —— 那条**不成立**:
//      训练侧要的两个量都能现算, 见下面 u 更新处的证明。
//
//   ⚠️ **slot 有效位是必需的**。没有它, slot 0 分配出来的行会替 slot 2 的另一个
//      分支冒充 provider —— 那一条的表项从没学过, 却会把它的 pred 当真。
//
//   ⚠️ **tag 宽度受 64 KB 地址空间限制**: tag 用的是 pc[TAG_HI:ROW_AW+4],
//      TAG_HI=15 (与 rv32ifu2_btb.v 同一个理由, 见那里的注释), 所以
//      TAG_W <= 12 - ROW_AW。方向表假命中的代价只是一次误预测(不像 BTB 会取错
//      指令), 但仍然不该超出这个上限。文件末尾的 initial 块里有自检。
//
// Folded history :
//   用**组合折叠**, 不维护增量寄存器
//     fold(ghr,L,W)[j] = ^_{k: j+kW < L} ghr[j+kW]     —— 只吃 h[0:L-1]
//   GHR 只有 GHR_W 位, 一棵 XOR 树而已。增量方案要每张表两个 folded 寄存器,
//   **外加"移出窗口的位"的修正项** (L 不是 W 整数倍时要在位置 L mod W 上再 XOR
//   掉 h[L-1]), 漏掉就静默算错; 组合版结构上不可能出这类错。
//   每张表必须只吃 h[0:L_i-1] —— 吃满 GHR 的话"几何历史长度"就失去意义。
//
// Training :
//   训练在 EX **重算**, 只从 chk 带 1 位过来。
//   一开始的设计是"预测时把 provider 编号 + altpred 存进 chk 带到 EX"。评审推翻:
//     1. F1→EX 有 4 拍以上 (IBUF 8 深 + 核心停顿), 期间表还在被别的分支写。
//        拿携带的编号直接当写地址, 中途发生行替换就会去改**别的块**的表项。
//     2. 那些字段在初始化扫描期间会是 X, X 当 mux 选择会**写进表状态**。
//   ⇒ 现在只带 `upd_fpred` 一位 (预测当时真正给出的方向; EX 侧无法重算 —— 表项
//      可能已经变了), 其余全部用 (upd_pc, upd_ghr) 按**同一批函数**重算。
//
//   ⚠️ 顶层**不能**拿 iu_bht_pred 顶替 upd_fpred: 那个是
//      `sl_taken = btb_cond & bht_taken & init_done`, 被 btb_vld 门控过。
//      BTB 里没有这一行时它是 0, 而 TAGE 可能给了 1 —— u 更新会被整段跳过,
//      分配还会在"纯 BTB miss"上误触发。
//
//   ⚠️ 训练只由条件分支驱动 (iu_bht_check_vld), **绝不能**用 iu_btb_update_vld
//      (那个还含 JAL/JALR, 会给没有方向的分支教"taken")。
//----------------------------------------------------------------------------

module rv32ifu2_tage
  //---------------------------------------------------------------------------
  // Parameters (for ports or related)
  //---------------------------------------------------------------------------
  #(parameter
    T0_AW    = 6,             // T0 行数 log2
    ROW_AW   = 6,             // 每张 tagged 表行数 log2
    // ---- 逐表**逻辑**行数 ----
    // 回答"每一级的表 entry 数不同会怎样"。默认 = ROW_AW ⇒ 四张表同尺寸,
    // 与加这几个参数之前**逐位相同** (已用 base/aw7/r5_only 三个已知点验证)。
    //
    // 实现方式: 物理阵列仍按 ROW_AW 分配, 但第 i 张表的**行索引用且仅用**
    // pc[RAi+3:4] 这 RAi 位 (高位恒 0) ⇒ 行号只落在 [0, 2^RAi) —— 冲突行为与
    // 一张独立的 2^RAi 行表**逐位相同**; 被索引让出来的 (12-RAi) 位**全部进标签**,
    // 所以"索引+标签"恒等于 pc[15:4] 这 12 位, 块身份的口径没变。
    // 代价是浪费了 (2^ROW_AW - 2^RAi) 行物理阵列 —— 测性能曲线时这是**故意的**:
    // 要的是"如果这张表只有 2^RAi 行会怎样", 不是省 RAM。
    // ⚠️ 约束: TAG_W >= 12 - RAi (标签要装下让出来的那几位), 末尾自检。
    ROW_AW_T1 = ROW_AW,
    ROW_AW_T2 = ROW_AW,
    ROW_AW_T3 = ROW_AW,
    ROW_AW_T4 = ROW_AW,
    NTAB     = 4,             // tagged 表数 (1..NTABMAX)
    TAG_W    = 6,             // 行标签位宽 (<= 12-ROW_AW, 见头注释)
    GHR_W    = 16,            // 全局历史位宽
    T0_HIST  = 0,             // T0 索引里掺几位历史 (0 = 按规格的纯双模态)
    SLOTS    = 4,             // 每行 slot 数 = 16 B 块的 4 个位置
    TAG_HI   = 15,            // 地址空间上界 (64 KB)
    L1       = 2,             // 表 1 的历史长度
    L2       = 5,             // 表 2
    L3       = 9,             // 表 3
    L4       = 14,            // 表 4
    USEL_AW  = 6,             // USE_SEL 计数器组的项数 log2 (= ROW_AW: 与表同深)
    USEL_W   = 4,             // USE_SEL 位宽 (**有符号**, 4 位 ⇒ 范围 -8..+7)
    USEL_EN  = 1,             // 1 = 动态策略 (规格), 0 = 回静态策略做 A/B
    USEL_GATE= 1,             // 1 = 只在"弱信心且 altpred != pcpn"时训练 USE_SEL,
                              // 0 = 规格字面的无条件训练 (实测差 0.65pp, 见 doc §4)
    USEL_IDX = 0,             // 索引口径: 0 = 纯 PC (规格字面), 1 = PC ^ fold(GHR)
                              // ⚠️ 实测 1 **更差**: CoreMark 11,285,707 (比 0 差 4,695 拍,
                              //    只比静态好 262 拍), 且掺的历史越长越差。别默认打开。
    USEL_L   = 9              // USEL_IDX=1 时掺多少位历史
  )

  //---------------------------------------------------------------------------
  // Ports
  //---------------------------------------------------------------------------
  (
    // Global signals
    input  wire             clk,
    input  wire             rst,           // 高有效

    // F0: 用"下一个取指地址" + 该次取指生效的 GHR 索引
    input  wire [ 31:0]     rd_pc,
    input  wire [GHR_W-1:0] rd_ghr,

    // F1: 逐 slot 的方向
    output wire [SLOTS-1:0] slot_pred,
    output wire             init_done,

    // 训练 (EX 级, 1 拍脉冲; 由 iu_bht_check_vld 驱动, 仅条件分支)
    input  wire             upd_vld,
    input  wire [ 31:0]     upd_pc,
    input  wire [GHR_W-1:0] upd_ghr,       // 该分支取指时的 GHR 快照 (chk)
    input  wire             upd_taken,     // 该条件分支实际方向
    input  wire             upd_fpred      // 预测当时给出的方向 (chk 的 CHK_FPRED)
  );

  // ---------------------------------------------------------------------------
  //  Local parameters
  // ---------------------------------------------------------------------------
  localparam NR_ROWS   = 1 << ROW_AW;
  localparam T0_ROWS   = 1 << T0_AW;

  // 逐表逻辑行数, 夹到 [1, ROW_AW]。(常量表达式, 不用函数 —— 避免不同工具对
  // "常量函数"的支持差异。)
  localparam RA1 = (ROW_AW_T1 < 1) ? 1 : (ROW_AW_T1 > ROW_AW) ? ROW_AW : ROW_AW_T1;
  localparam RA2 = (ROW_AW_T2 < 1) ? 1 : (ROW_AW_T2 > ROW_AW) ? ROW_AW : ROW_AW_T2;
  localparam RA3 = (ROW_AW_T3 < 1) ? 1 : (ROW_AW_T3 > ROW_AW) ? ROW_AW : ROW_AW_T3;
  localparam RA4 = (ROW_AW_T4 < 1) ? 1 : (ROW_AW_T4 > ROW_AW) ? ROW_AW : ROW_AW_T4;

  // 第 i 张表的标签宽度 = 12 - RAi (被行索引让出来的那几位)。
  localparam TW1 = TAG_HI - 3 - RA1;   // = 12 - RA1
  localparam TW2 = TAG_HI - 3 - RA2;
  localparam TW3 = TAG_HI - 3 - RA3;
  localparam TW4 = TAG_HI - 3 - RA4;

  // 四张表里最小的逻辑行数 —— 上界检查 (TAG_W <= 12-MIN_RA) 用
  localparam MIN_RA = (RA1 < RA2) ? ((RA1 < RA3) ? ((RA1 < RA4) ? RA1 : RA4) : ((RA3 < RA4) ? RA3 : RA4))
                                  : ((RA2 < RA3) ? ((RA2 < RA4) ? RA2 : RA4) : ((RA3 < RA4) ? RA3 : RA4));

  // 逻辑容量 (面积报表用)。物理阵列是 NTAB*NR_ROWS, 但**设计点**是逻辑的这个。
  localparam LG_ROWS = ((NTAB > 0) ? (1 << RA1) : 0) + ((NTAB > 1) ? (1 << RA2) : 0)
                     + ((NTAB > 2) ? (1 << RA3) : 0) + ((NTAB > 3) ? (1 << RA4) : 0);
  localparam NTABMAX   = 4;                        // 表数上限 = 读侧展开宽度
  localparam PV_DEPTH  = NTAB * NR_ROWS * SLOTS;
  localparam TAG_DEPTH = NTAB * NR_ROWS;

  // pv 的字段布局: {slot_vld, pred[SLOT_PRED_W-1:0], u[SLOT_U_W-1:0]}
  localparam SLOT_U_W     = 2;                     // u: 有用位计数器
  localparam SLOT_PRED_W  = 3;                     // pred: 3 位饱和计数器
  localparam SLOT_W       = 1 + SLOT_PRED_W + SLOT_U_W;
  localparam SLOT_U_POS      = 0;                  // pv[SLOT_U_POS    +: SLOT_U_W]
  localparam SLOT_PRED_POS   = SLOT_U_POS + SLOT_U_W;
  localparam SLOT_PRED_TAKEN = SLOT_PRED_POS + SLOT_PRED_W - 1;  // pred 符号位 = 方向
  localparam SLOT_VLD_POS    = SLOT_PRED_POS + SLOT_PRED_W;      // slot 有效位

  localparam T0_TAKEN_POS = 1;                     // T0 是 2 位计数器, 高位 = 方向

  // USE_SEL 计数器组
  localparam USEL_ROWS = 1 << USEL_AW;
  // 有符号饱和的两端。用裸位型而不是 signed 变量: 判负只取最高位,
  // 加减只在两端的字面量上比较 —— 全程不碰 signed/unsigned 的隐式规则。
  localparam [USEL_W-1:0] USEL_MAX = {1'b0, {(USEL_W-1){1'b1}}};   // +7 (USEL_W=4)
  localparam [USEL_W-1:0] USEL_MIN = {1'b1, {(USEL_W-1){1'b0}}};   // -8 (USEL_W=4)

  // 初始化扫描的行数 = 三张阵列里行数最多的那个。各自的索引按自己的位宽绕行
  // (照 rv32ifu2_btb.v 的做法), 绕行只会多清几遍, 不会漏。
  // USEL_AW 默认 = ROW_AW ⇒ 默认配置下 INIT_ROWS 仍是 64, init 仍是 64 拍。
  // ⚠️ 把 USEL_AW 抬过 ROW_AW 会**直接加长 init**, 所有用例的周期数都会变。
  localparam INIT_ROWS = (T0_AW > ROW_AW) ? ((T0_AW > USEL_AW) ? T0_ROWS  : USEL_ROWS)
                                          : ((ROW_AW > USEL_AW) ? NR_ROWS  : USEL_ROWS);
  localparam INIT_AW   = (T0_AW > ROW_AW) ? ((T0_AW > USEL_AW) ? T0_AW    : USEL_AW)
                                          : ((ROW_AW > USEL_AW) ? ROW_AW   : USEL_AW);

  // ---------------------------------------------------------------------------
  //  Signal declarations
  // ---------------------------------------------------------------------------
  genvar  gi, gs;
  integer wi, wj;
  integer pi, ci;

  // 表阵列
  //   tag_q: 第 i 张表 (i=1..NTAB) 在 [ (i-1)*NR_ROWS +: NR_ROWS ]
  //   pv_q : 第 i 张表第 r 行第 s 个 slot 在 [ ((i-1)*NR_ROWS + r)*SLOTS + s ]
  reg [TAG_W:0]    tag_q [0:TAG_DEPTH-1];          // {行有效, tag}
  reg [SLOT_W-1:0] pv_q  [0:PV_DEPTH-1];
  reg [1:0]        t0_q  [0:T0_ROWS*SLOTS-1];

  // USE_SEL 计数器组。**每拍只有一个写口** (init 扫描 或 训练, 互斥),
  // 读口是组合读 —— 与 btb/bht 同一种"组合读 + 同步写", 与三张表**不同**:
  // 表的写口每拍有多个, 这个没有。将来要换 RAM, 这一张是最容易的一张。
  reg [USEL_W-1:0] use_sel_q [0:USEL_ROWS-1];

  // 初始化扫描
  reg             init_done_q;
  reg [INIT_AW:0] init_cnt_q;

  // F0: 索引与标签
  wire [ROW_AW-1:0] rd_row_idx [0:NTAB-1];
  wire [TAG_W-1:0]  rd_row_tag [0:NTAB-1];
  wire [T0_AW-1:0]  rd_t0_idx;
  wire [USEL_AW-1:0] rd_usel_idx;

  // F0 → F1 流水寄存器 (只寄存索引与标签, 与 rv32ifu2_bht.v / rv32ifu2_btb.v 同拍型)
  reg [ROW_AW-1:0] q_row_idx [0:NTAB-1];
  reg [TAG_W-1:0]  q_row_tag [0:NTAB-1];
  reg [T0_AW-1:0]  q_t0_idx;
  reg [USEL_AW-1:0] q_usel_idx;

  // F1: USE_SEL 的符号位。
  // 取最高位判负而不是把数组声明成 signed —— 省掉 Verilog 的 signed/unsigned
  // 隐式转换规则, 也省掉"数组元素能不能是 signed"这种可移植性问题。
  wire use_sel_neg = use_sel_q[q_usel_idx][USEL_W-1];

  // F1: 逐表读行, 摊平成 NTABMAX 宽的总线 (未用的表恒 0)
  wire [NTABMAX*SLOTS-1:0]   tb_hit;
  wire [NTABMAX*SLOTS-1:0]   tb_pred;
  wire [NTABMAX*SLOTS-1:0]   tb_weak;
  wire [NTABMAX*SLOTS*2-1:0] tb_u;

  // F1: provider / alternate (逐 slot, 0 = T0, 1..NTAB = 表编号)
  wire [2:0] prov_sel [0:SLOTS-1];
  wire [2:0] alt_sel  [0:SLOTS-1];
  wire [SLOTS-1:0] t0_pred;
  wire [SLOTS-1:0] prov_pred, prov_weak, alt_pred, fpred_raw;

  // 训练路径: 用 (upd_pc, upd_ghr) 重算出来的一切
  wire [ROW_AW-1:0] u_row_idx [0:NTAB-1];
  wire [TAG_W-1:0]  u_row_tag [0:NTAB-1];
  wire [TAG_W:0]    u_tag_row [0:NTAB-1];
  wire [SLOT_W-1:0] u_ent     [0:NTAB-1];
  wire              u_hit     [0:NTAB-1];
  wire [1:0]        u_eff     [0:NTAB-1];
  wire [1:0]        u_age     [0:NTAB-1];

  wire [1:0]       u_slot;
  wire [T0_AW-1:0] u_t0_idx;
  wire [2:0]       u_t0_pred;
  reg  [2:0]       u_prov, u_alt;
  wire [2:0]       u_prov_s, u_alt_s;              // 防越界的"安全编号", 见下
  wire [2:0]       u_ppred, u_apred;
  wire             u_misp;
  wire [1:0]       u_prov_u_nxt;
  wire [2:0]       u_prov_pred_nxt;
  wire [1:0]       u_t0_nxt;
  wire [USEL_AW-1:0] u_usel_idx;
  wire               u_usel_en;
  wire               u_usel_up;
  wire [USEL_W-1:0]  u_usel_nxt;
  reg  [2:0]       u_k;                            // 0 = 不分配
  reg              u_k_tag_same;
  wire [2:0]       u_alloc_pred;

  // ---------------------------------------------------------------------------
  //  Functions
  //
  // ⚠️ 这组函数是**唯一**的公式来源, 读侧 (rd_pc/rd_ghr) 与写侧 (upd_pc/upd_ghr)
  //    都调它们。本工程用血换来的规矩: 读索引与写索引必须是同一个公式
  //    (memory bp-class3-root-cause —— 读写 GHR 位窗不一致, 让一整类分支在整个
  //    仿真里收到 0 次写)。谁要加一条"另一条路"的索引, 先把这条想清楚。
  // ---------------------------------------------------------------------------

  // fold(ghr,L,W)[j] = ^_{k: j+kW < L} ghr[j+kW]
  function automatic [31:0] fold_history ( input [GHR_W-1:0] h,
                                           input integer     len,
                                           input integer     wid);
    integer    j, k;
    reg [31:0] o;
    begin : fn_fold_history
      o = 32'b0;
      for (j = 0; j < wid; j = j + 1)
        for (k = j; k < len; k = k + wid)
          o[j] = o[j] ^ h[k];
      fold_history = o;
    end
  endfunction

  // 定宽循环左移, 让各张表的 tag 折叠错开
  function automatic [TAG_W-1:0] rotl_tag ( input [TAG_W-1:0] x,
                                            input integer     rot);
    integer         b;
    reg [TAG_W-1:0] y;
    begin : fn_rotl_tag
      y = {TAG_W{1'b0}};
      for (b = 0; b < TAG_W; b = b + 1)
        y[(b + rot) % TAG_W] = x[b];
      rotl_tag = y;
    end
  endfunction

  // 低 aw 位的掩码 (aw <= 12)。用循环而不是 (1<<aw)-1: 后者在 aw=12 时要靠
  // 32 位宽度兜住, 循环版没有这个边界问题。
  function automatic [31:0] mask_lo ( input integer aw);
    integer b;
    begin : fn_mask_lo
      mask_lo = 32'b0;
      for (b = 0; b < aw; b = b + 1) mask_lo[b] = 1'b1;
    end
  endfunction

  // 变宽循环左移 (与 rotl_tag 同义, 只是宽度可传参 —— 逐表标签宽度不同了)
  function automatic [31:0] rotl_w ( input [31:0]  x,
                                     input integer rot,
                                     input integer w);
    integer b;
    begin : fn_rotl_w
      rotl_w = 32'b0;
      if (w > 0)
        for (b = 0; b < w; b = b + 1) rotl_w[(b + rot) % w] = x[b];
    end
  endfunction

  // tagged 表的行索引 (逻辑 aw 行)。
  // 只取 pc[aw+3:4] 这 aw 位, 高位置 0 ⇒ 行号落在 [0, 2^aw) ⇒ 物理阵列里
  // 只有前 2^aw 行会被用到, 冲突行为与独立的 2^aw 行表相同。
  function automatic [ROW_AW-1:0] row_index_w ( input [31:0]      pc,
                                                input [GHR_W-1:0] h,
                                                input integer     len,
                                                input integer     aw);
    reg [31:0] v;
    begin : fn_row_index_w
      v = (pc[TAG_HI:4] ^ fold_history(h, len, aw)) & mask_lo(aw);
      row_index_w = v[ROW_AW-1:0];
    end
  endfunction

  // tagged 表的行标签, 宽度 tw = 12 - aw。
  // pc[TAG_HI:4] >> aw 就是 pc[TAG_HI : aw+4] 低位对齐 —— 索引让出来的
  // 那 (12-aw) 位**全部**进标签, 于是索引+标签仍恒等于 pc[15:4] 的 12 位,
  // "块身份"的口径与改尺寸之前完全一致。零扩展到 TAG_W 存进阵列。
  function automatic [TAG_W-1:0] row_tag_w ( input [31:0]      pc,
                                             input [GHR_W-1:0] h,
                                             input integer     len,
                                             input integer     rot,
                                             input integer     aw,
                                             input integer     tw);
    reg [31:0] v;
    begin : fn_row_tag_w
      v = (pc[TAG_HI:4] >> aw) ^ rotl_w(fold_history(h, len, tw), rot, tw);
      row_tag_w = v & mask_lo(tw);
    end
  endfunction

  // USE_SEL 的索引。**读侧与写侧必须调同一个** (本工程那条硬规矩, 见上面的函数段开头)。
  //   USEL_IDX=0: 纯 PC —— 规格字面("使用分支指令的 pc 直接索引")。
  //   USEL_IDX=1: PC ^ fold(GHR, USEL_L, USEL_AW) —— 把"到达这条分支的路径"也掺进来,
  //               与三张 tagged 表同一个折叠函数。表项身份 = pc ⊕ fold(ghr) + tag,
  //               所以这个口径是在向"每个 entry 一个 USE_SEL"靠, 但计数器仍然是
  //               跨分配持久的 (不像表项会在分配时被重置)。
  function automatic [USEL_AW-1:0] usel_index ( input [31:0]      pc,
                                                input [GHR_W-1:0] h);
    begin : fn_usel_index
      if (USEL_IDX == 0) usel_index = pc[USEL_AW+3:4];
      else               usel_index = pc[USEL_AW+3:4] ^ fold_history(h, USEL_L, USEL_AW);
    end
  endfunction

  // T0 的行索引 (T0_HIST=0 时就是纯 PC 的双模态)
  function automatic [T0_AW-1:0] t0_index ( input [31:0]      pc,
                                            input [GHR_W-1:0] h);
    reg [T0_AW-1:0] x;
    begin : fn_t0_index
      x = pc[T0_AW+3:4];
      if (T0_HIST > 0) x = x ^ fold_history(h, T0_HIST, T0_AW);
      t0_index = x;
    end
  endfunction

  // 3 位饱和计数器
  function automatic [2:0] ctr3_next ( input [2:0] c,
                                       input       up);
    begin : fn_ctr3_next
      if (up) ctr3_next = (c == 3'b111) ? 3'b111 : (c + 3'd1);
      else    ctr3_next = (c == 3'b000) ? 3'b000 : (c - 3'd1);
    end
  endfunction

  // 2 位饱和计数器
  function automatic [1:0] ctr2_next ( input [1:0] c,
                                       input       up);
    begin : fn_ctr2_next
      if (up) ctr2_next = (c == 2'b11) ? 2'b11 : (c + 2'd1);
      else    ctr2_next = (c == 2'b00) ? 2'b00 : (c - 2'd1);
    end
  endfunction

  // USE_SEL: **有符号**饱和计数器。范围 [USEL_MIN, USEL_MAX] = [-2^(USEL_W-1), 2^(USEL_W-1)-1]
  // 两端的比较用字面量而不是算术判断 (c[MSB] 之类): 中间值怎么走都行, 溢出不行。
  function automatic [USEL_W-1:0] usel_ctr_next ( input [USEL_W-1:0] c,
                                                  input             up);
    begin : fn_usel_ctr_next
      if (up) usel_ctr_next = (c == USEL_MAX) ? USEL_MAX : (c + 1'b1);
      else    usel_ctr_next = (c == USEL_MIN) ? USEL_MIN : (c - 1'b1);
    end
  endfunction

  // 弱信心 = 3'b011 / 3'b100 (规格 §fpred 生成策略)
  function automatic is_weak ( input [2:0] c);
    begin : fn_is_weak
      is_weak = (c == 3'b011) || (c == 3'b100);
    end
  endfunction

  // ---------------------------------------------------------------------------
  //  初始化扫描
  //
  // 与 BTB / i-cache 同一套做法: 阵列上电是 X, 而 X 会一路传到 next_pc。
  // 扫描期间**丢掉训练** —— 此时行有效位还是 X, `X & (tag == )` 是 X 不是 0,
  // 会让 provider 选择变成 X 并写进表里 (永久污染, 症状见 doc §5 第 3 条)。
  // ---------------------------------------------------------------------------
  assign init_done = init_done_q;

  always @(posedge clk)
  begin : p_init_scan
    if (rst)
    begin
      init_done_q <= 1'b0;
      init_cnt_q  <= {(INIT_AW+1){1'b0}};
    end
    else if (!init_done_q)
    begin
      if (init_cnt_q == (INIT_ROWS-1)) init_done_q <= 1'b1;
      init_cnt_q <= init_cnt_q + 1'b1;
    end
  end // p_init_scan

  // ---------------------------------------------------------------------------
  //  F0: 索引与标签 (组合) + 打一拍进 F1
  // ---------------------------------------------------------------------------
  generate
    for (gi = 0; gi < NTAB; gi = gi + 1)
      begin : g_f0_index
        localparam LI  = (gi == 0) ? L1 : (gi == 1) ? L2 : (gi == 2) ? L3 : L4;
        localparam RA  = (gi == 0) ? RA1 : (gi == 1) ? RA2 : (gi == 2) ? RA3 : RA4;
        localparam TW  = (gi == 0) ? TW1 : (gi == 1) ? TW2 : (gi == 2) ? TW3 : TW4;
        localparam ROT = (TW > 0) ? (gi % TW) : 0;

        assign rd_row_idx[gi] = row_index_w(rd_pc, rd_ghr, LI, RA);
        assign rd_row_tag[gi] = row_tag_w  (rd_pc, rd_ghr, LI, ROT, RA, TW);
      end
  endgenerate

  assign rd_t0_idx = t0_index(rd_pc, rd_ghr);

  // USE_SEL 的读索引。用块粒度 pc[USEL_AW+3:4] 打底, 这样一条分支的归属稳定,
  // 不会因为块内偏移变化而换格子; USEL_IDX=1 时再掺进历史 (公式见 usel_index)。
  assign rd_usel_idx = usel_index(rd_pc, rd_ghr);

  always @(posedge clk)
  begin : p_f0_f1
    if (rst)
    begin
      for (wj = 0; wj < NTAB; wj = wj + 1)
      begin
        q_row_idx[wj] <= {ROW_AW{1'b0}};
        q_row_tag[wj] <= {TAG_W{1'b0}};
      end
      q_t0_idx   <= {T0_AW{1'b0}};
      q_usel_idx <= {USEL_AW{1'b0}};
    end
    else
    begin
      for (wj = 0; wj < NTAB; wj = wj + 1)
      begin
        q_row_idx[wj] <= rd_row_idx[wj];
        q_row_tag[wj] <= rd_row_tag[wj];
      end
      q_t0_idx   <= rd_t0_idx;
      q_usel_idx <= rd_usel_idx;
    end
  end // p_f0_f1

  // ---------------------------------------------------------------------------
  //  F1: 逐表读行
  //
  //  行标签是**整行共享**的 (一个块一个 tag), slot 靠自己的有效位区分,
  //  所以 hit 是 (表, slot) 二维的。
  // ---------------------------------------------------------------------------
  generate
    for (gi = 0; gi < NTABMAX; gi = gi + 1)
      begin : g_f1_read
        if (gi < NTAB)
          begin : g_used
            wire [TAG_W:0] tag_row;
            wire           tag_match;

            assign tag_row   = tag_q[gi*NR_ROWS + q_row_idx[gi]];
            assign tag_match = (tag_row[TAG_W-1:0] == q_row_tag[gi]);

            for (gs = 0; gs < SLOTS; gs = gs + 1)
              begin : g_slot
                wire [SLOT_W-1:0] pv;

                assign pv = pv_q[(gi*NR_ROWS + q_row_idx[gi])*SLOTS + gs];

                // slot 有效位是必需的, 见头注释
                assign tb_hit [gi*SLOTS + gs] = tag_row[TAG_W] & tag_match
                                              & pv[SLOT_VLD_POS];
                assign tb_pred[gi*SLOTS + gs] = pv[SLOT_PRED_TAKEN];
                assign tb_weak[gi*SLOTS + gs] = is_weak(pv[SLOT_PRED_POS +: SLOT_PRED_W]);
                assign tb_u[(gi*SLOTS + gs)*2 +: 2] = pv[SLOT_U_POS +: SLOT_U_W];
              end
          end
        else
          begin : g_unused
            for (gs = 0; gs < SLOTS; gs = gs + 1)
              begin : g_slot
                assign tb_hit [gi*SLOTS + gs] = 1'b0;
                assign tb_pred[gi*SLOTS + gs] = 1'b0;
                assign tb_weak[gi*SLOTS + gs] = 1'b0;
                assign tb_u[(gi*SLOTS + gs)*2 +: 2] = 2'b00;
              end
          end
      end
  endgenerate

  // ---------------------------------------------------------------------------
  //  F1: provider / alternate 选择 (逐 slot)
  //  高位 = 历史更长的表。
  // ---------------------------------------------------------------------------
  generate
    for (gs = 0; gs < SLOTS; gs = gs + 1)
      begin : g_sel
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

  assign t0_pred = { t0_q[q_t0_idx*SLOTS+3][T0_TAKEN_POS],
                     t0_q[q_t0_idx*SLOTS+2][T0_TAKEN_POS],
                     t0_q[q_t0_idx*SLOTS+1][T0_TAKEN_POS],
                     t0_q[q_t0_idx*SLOTS+0][T0_TAKEN_POS] };

  generate
    for (gs = 0; gs < SLOTS; gs = gs + 1)
      begin : g_fpred
        wire [2:0] ps = prov_sel[gs];
        wire [2:0] as = alt_sel[gs];

        assign prov_pred[gs] = (ps == 3'd0) ? t0_pred[gs] : tb_pred[(ps-1)*SLOTS + gs];
        assign prov_weak[gs] = (ps == 3'd0) ? 1'b0        : tb_weak[(ps-1)*SLOTS + gs];
        assign alt_pred [gs] = (as == 3'd0) ? t0_pred[gs] : tb_pred[(as-1)*SLOTS + gs];

        // 只有 T0 命中时 ps==0 ⇒ 直接用 T0, 且此时 as 也必为 0 ⇒ altpred == fpred
        // ⇒ u 的更新条件恒不成立 (与规格"若仅命中 T0, 则 T0 也是 altpred"一致)
        //
        // 动态策略: USE_SEL 只在 provider 弱信心那一档起作用 ——
        //   !weak || use_sel_neg ⇒ provider, 否则 altpred。
        // 强信心恒赢, 所以 USE_SEL 不会推翻一个饱和的 provider。
        // USEL_EN=0 时退回静态 (与加 USE_SEL 之前逐位相同)。
        if (USEL_EN)
          assign fpred_raw[gs] = (ps == 3'd0) ? t0_pred[gs]
                               : ((!prov_weak[gs] || use_sel_neg) ? prov_pred[gs]
                                                                  : alt_pred[gs]);
        else
          assign fpred_raw[gs] = (ps == 3'd0) ? t0_pred[gs]
                               : (prov_weak[gs] ? alt_pred[gs] : prov_pred[gs]);
      end
  endgenerate

  // ⚠️ 初始化扫描期间阵列还是 X, 而 `valid & (tag == …)` 在 valid 为 X 时是
  //    **X 不是 0**, 会一路传到 next_pc。用 AND 门控, **不能**用三元
  //    (X ? a : b 是逐位合并, 不是干净的 0)。
  assign slot_pred = fpred_raw & {SLOTS{init_done}};

  // ---------------------------------------------------------------------------
  //  训练路径: 用 (upd_pc, upd_ghr) 重算一切
  // ---------------------------------------------------------------------------
  generate
    for (gi = 0; gi < NTAB; gi = gi + 1)
      begin : g_u0_index
        localparam LI  = (gi == 0) ? L1 : (gi == 1) ? L2 : (gi == 2) ? L3 : L4;
        localparam RA  = (gi == 0) ? RA1 : (gi == 1) ? RA2 : (gi == 2) ? RA3 : RA4;
        localparam TW  = (gi == 0) ? TW1 : (gi == 1) ? TW2 : (gi == 2) ? TW3 : TW4;
        localparam ROT = (TW > 0) ? (gi % TW) : 0;

        assign u_row_idx[gi] = row_index_w(upd_pc, upd_ghr, LI, RA);
        assign u_row_tag[gi] = row_tag_w  (upd_pc, upd_ghr, LI, ROT, RA, TW);
      end
  endgenerate

  assign u_slot = upd_pc[3:2];

  assign u_t0_idx = t0_index(upd_pc, upd_ghr);
  // T0 是 2 位计数器, 借高两位拼成"3 位口径"以便和 tagged 表统一比较 ——
  // 只有 bit[2] (方向) 会被用到。
  assign u_t0_pred = {t0_q[u_t0_idx*SLOTS + u_slot][T0_TAKEN_POS], 2'b00};

  assign u_t0_nxt = ctr2_next(t0_q[u_t0_idx*SLOTS + u_slot], upd_taken);

  generate
    for (gi = 0; gi < NTAB; gi = gi + 1)
      begin : g_u_read
        assign u_tag_row[gi] = tag_q[gi*NR_ROWS + u_row_idx[gi]];
        assign u_ent    [gi] = pv_q[(gi*NR_ROWS + u_row_idx[gi])*SLOTS + u_slot];
        assign u_hit    [gi] = u_tag_row[gi][TAG_W] & (u_tag_row[gi][TAG_W-1:0] == u_row_tag[gi])
                             & u_ent[gi][SLOT_VLD_POS];
      end
  endgenerate

  // provider / alternate (训练侧)。用 done 标志退出循环,
  // 不用"把循环变量设成 -1"那种写法。
  always @*
  begin : p_u_prov
    u_prov = 3'd0;
    u_alt  = 3'd0;
    for (pi = NTAB - 1; pi >= 0; pi = pi - 1)
      if (u_hit[pi] && (u_prov == 3'd0)) u_prov = pi + 1;
    if (u_prov != 3'd0)
      for (pi = u_prov - 2; pi >= 0; pi = pi - 1)
        if (u_hit[pi] && (u_alt == 3'd0)) u_alt = pi + 1;
  end // p_u_prov

  // ⚠️ u_prov / u_alt 为 0 时下面的 u_ent[..-1] 会越界读。用一个"安全编号"顶住 ——
  //    那两个分支的结果在 u_prov==0 时本来就不使用。
  //    注意连续赋值里的三元是**两边都求值**的, 不能靠条件短路来防越界。
  assign u_prov_s = (u_prov == 3'd0) ? 3'd1 : u_prov;
  assign u_alt_s  = (u_alt  == 3'd0) ? 3'd1 : u_alt;

  assign u_ppred = (u_prov == 3'd0) ? u_t0_pred
                                    : u_ent[u_prov_s-1][SLOT_PRED_POS +: SLOT_PRED_W];
  assign u_apred = (u_alt  == 3'd0) ? u_t0_pred
                                    : u_ent[u_alt_s -1][SLOT_PRED_POS +: SLOT_PRED_W];
  assign u_misp  = (upd_fpred != upd_taken);

  // ---------------------------------------------------------------------------
  // USE_SEL 的更新 (规格: "当 altpred 与最终的分支结果相同时递增, 反之递减")
  //
  // altpred 用 EX 侧重算出来的 u_apred —— 与本文件其它训练量同一套口径 (不携带预测
  // 当时的编号, 见头注释 §Training)。
  //
  // ⚠️ **没有加"只在弱信心时才更新"这种门控。** 规格那句是无条件的, 就按无条件做。
  //    门控版 (经典 TAGE 是"provider 弱且 altpred != pcpn 时才训练") 可以 A/B,
  //    但那是规格之外的改动。
  // ---------------------------------------------------------------------------
  // 写索引: **同一个 usel_index**, 只是换成 (upd_pc, upd_ghr)。
  // ⚠️ upd_ghr 是随指令走完全程的那份 GHR 快照, 与表索引用的是同一对 (pc, ghr),
  //    所以读写必然同址 (memory bp-class3-root-cause 那条纪律)。
  assign u_usel_idx = usel_index(upd_pc, upd_ghr);
  assign u_usel_up  = (u_apred[2] == upd_taken);
  assign u_usel_nxt = usel_ctr_next(use_sel_q[u_usel_idx], u_usel_up);

  // 门控 (USEL_GATE=1, 默认): 只在"**决定权真的交给了 USE_SEL**"的那些分支上训练 ——
  // 即 provider 弱信心 **且** altpred 与 pcpn 不一致。
  //
  // 为什么必须有这道门 (实测): 无门控时每个条件分支都训练, 其中一大类是
  // "只剩 T0 命中" (ps==0) —— 那时 altpred 与 pcpn **是同一个表项**, 于是
  // `u_apred==taken` 量的根本不是"altpred 比 pcpn 好在哪", 而是"T0 准不准"。
  // 双模态的 T0 在 branch_bench 的类 3/类 5 上本来就弱, 一路把 USE_SEL 拽成负,
  // 弱信心那一档就被翻成 pcpn, 正好和静态策略相反 ⇒ 类 3 93.38%→87.20%、
  // 类 5 96.28%→93.45%、总周期 +736。
  //
  // ⚠️ ps==0 时 is_weak(u_ppred) 是**没意义**的: u_t0_pred 是 {方向, 2'b00} 拼出来的
  //    "3 位口径", 恒不落在 3'b011/3'b100 的弱区间里。这里不出错是因为同一拍
  //    `u_apred[2] != u_ppred[2]` 必为假, 与门把这一项吃掉了 —— 别把这两个条件拆开用。
  assign u_usel_en  = USEL_GATE ? (is_weak(u_ppred) && (u_apred[2] != u_ppred[2]))
                                : 1'b1;

  // ---------------------------------------------------------------------------
  // u 的更新方向用 `upd_fpred == upd_taken` 当"pcpn 猜没猜对"的代理。
  //
  // ⚠️ 本文件头与 doc §4 都记过一条待办: "上动态 USE_SEL 后这个等价不成立, 必须把
  //    provider_pred 也带到 EX"。**那条待办是错的, 不需要多带任何位**, 证明:
  //      fpred 按构造**只可能**是 pcpn 或 altpred 二者之一 (ps==0 时两者都等于
  //      t0_pred, 更是同一个值)。于是
  //          altpred != fpred  ⇒  fpred != altpred  ⇒  fpred == pcpn
  //      也就是说: **u 更新的条件一成立, fpred 就已经是 pcpn 了**, 与静态还是动态
  //      无关。规格要求的条件 "按生成策略选择了 pcpn 且 altpred != pcpn" 也就等价于
  //      `altpred != fpred` (因为 fpred==pcpn 时后一条就是 `altpred != fpred`)。
  //    ⇒ 带过来的这一位 fpred 同时充当了条件与方向, chk 宽度不用动。
  // ---------------------------------------------------------------------------
  assign u_prov_u_nxt    = ctr2_next(u_ent[u_prov_s-1][SLOT_U_POS +: SLOT_U_W],
                                     upd_fpred == upd_taken);
  assign u_prov_pred_nxt = ctr3_next(u_ppred, upd_taken);

  // ---------------------------------------------------------------------------
  //  分配 (规格 §6 策略 A/B/C)
  //
  //    A 优先级: 在**比 provider 更长**的表里挑 u==0 的**最短**那张
  //    B 避免乒乓: 有多张 u==0 时取历史长度短的 (上面的"最短"扫描就是它)
  //    C 初始化: 写 tag, pred = 本次结果的**弱**方向, u = 0
  //
  //  三处对规格的偏离, 都在 doc §4 记了:
  //    * 范围含**最长表** (原文 i<k<M 把最长表排除 ⇒ 它永远分配不到 ⇒ 死表)
  //    * pred 初始化成弱方向 (011/100) 而不是强极值 —— 刚分配就不可替换是坏事
  //    * 只有**行标签真的被替换**时才清同行其它 slot。无条件清会让同块两条分支
  //      轮流擦掉对方的项, 每一轮都重来一次, 永不收敛。
  //
  //  ⚠️ u 的候选判据是 `u_eff = u & 行有效 & slot有效`: 没分配过的项 u 是陈旧值,
  //     不门控就会把本该分配的那张表跳过去, 转去做老化递减。
  //
  //  一个能用的副产品: `u_k == 0` ⇒ 所有更长的表都满足"行有效 & slot有效 & u≠0"
  //  ⇒ 它们**都写过**, 于是老化递减那一支读到的 u/pred 一定是干净的 (不是 X),
  //  不需要再单独防护。
  // ---------------------------------------------------------------------------
  generate
    for (gi = 0; gi < NTAB; gi = gi + 1)
      begin : g_u_eff
        // ⚠️ 门控信号**必须来自扫描清过的位** (row_valid), 光用 slot_valid 不够:
        //    从未写过的项 slot_valid 也是 X, `X & X = X`, 于是下面的 `u_eff==0`
        //    比较恒为假 ⇒ **一行都分配不出去**。实测症状就是
        //    `TAGE rows valid = 0 / 256` + 类 3 恰好回到 50.00% + 类 5 掉到 74.41%
        //    (= 只剩 T0 双模态在干活), 而所有其它数都正常。
        //    另外**不能**写成 `slot_valid ? u : 2'b00` 那种三元 —— `X ? a : b` 是
        //    逐位合并而不是干净的 0。`X & 0 = 0` 才是本工程反复记过的那条规矩。
        assign u_eff[gi] = u_ent[gi][SLOT_U_POS +: SLOT_U_W]
                         & {SLOT_U_W{u_tag_row[gi][TAG_W] & u_ent[gi][SLOT_VLD_POS]}};
      end
  endgenerate

  always @*
  begin : p_u_alloc
    u_k = 3'd0;
    for (ci = ((u_prov == 3'd0) ? 0 : u_prov); ci < NTAB; ci = ci + 1)
      if ((u_eff[ci] == 2'b00) && (u_k == 3'd0)) u_k = ci + 1;

    u_k_tag_same = 1'b0;
    if (u_k != 3'd0)
      u_k_tag_same = u_tag_row[u_k-1][TAG_W]
                   & (u_tag_row[u_k-1][TAG_W-1:0] == u_row_tag[u_k-1]);
  end // p_u_alloc

  // 新分配的表项: pred = 本次结果的弱方向 (011/100), u = 0
  assign u_alloc_pred = upd_taken ? 3'b100 : 3'b011;

  // 老化递减: 比 provider 更长的表的 u 各减 1 (规格 §6 (A)-2, 类 LSU 效果)
  generate
    for (gi = 0; gi < NTAB; gi = gi + 1)
      begin : g_u_age
        assign u_age[gi] = (u_ent[gi][SLOT_U_POS +: SLOT_U_W] == 2'b00)
                         ? 2'b00
                         : (u_ent[gi][SLOT_U_POS +: SLOT_U_W] - 2'd1);
      end
  endgenerate

  // ---------------------------------------------------------------------------
  //  写口
  //
  //  所有写入落在**互不重叠**的 word 上: provider 的表 vs 分配/老化落到的更长的
  //  表, 按构造是不同表。
  // ---------------------------------------------------------------------------
  always @(posedge clk)
  begin : p_write
    if (rst)
    begin
      // 复位时不写阵列 —— 清零交给下面的初始化扫描 (与 btb/bht/icache 同一套做法)。
      // 这一支**必须留着**: 中途复位时 init_done_q 还是 1, 少了它训练会直接写进
      // 还没清干净的阵列。
    end
    else if (!init_done_q)
    begin
      // 初始化扫描: 各表并行, 行索引各按自己的位宽绕行。
      for (wi = 0; wi < NTAB; wi = wi + 1)
        tag_q[wi*NR_ROWS + init_cnt_q[ROW_AW-1:0]] <= {(TAG_W+1){1'b0}};

      for (wi = 0; wi < SLOTS; wi = wi + 1)
        t0_q[init_cnt_q[T0_AW-1:0]*SLOTS + wi] <= 2'b00;

      // pv_q **也要清**。只清 tag 那一行的话, 行有效位虽然是干净的 0, 但
      // u/pred/slot_valid 全是 X, 而分配逻辑必须去读"没分配过"的项的 u
      // (规格 §6: 读比 provider 更长的表的 u) —— 读到 X 就整条分配路径失效。
      // 代价是这一支里 NTAB × SLOTS = 16 个写口, 但只在复位后那几十拍上电,
      // 折成多路选择器而不是真的 16 口 RAM (这些阵列本来就落成寄存器)。
      // 换掉的写法 (只靠 row_valid 门控) 依赖一条归纳出来的不变量"有效行里
      // 所有 slot 位都是已知的", 那种东西迟早会被下一次改动悄悄破坏。
      for (wi = 0; wi < NTAB; wi = wi + 1)
        for (wj = 0; wj < SLOTS; wj = wj + 1)
          pv_q[(wi*NR_ROWS + init_cnt_q[ROW_AW-1:0])*SLOTS + wj] <= {SLOT_W{1'b0}};

      // USE_SEL 也清。清成 0 而不是 -1 ⇒ 弱信心那一档退回 altpred ⇒ 上电行为与
      // 静态策略逐位相同, 之后才按实测收敛。USEL_ROWS 默认 = INIT_ROWS, 刚好扫一遍。
      use_sel_q[init_cnt_q[USEL_AW-1:0]] <= {USEL_W{1'b0}};
    end
    else if (upd_vld)
    begin
      // 0) USE_SEL (门控见 u_usel_en 处的注释)。这一支与 init 扫描、与下面的表写入
      //    都落在**不同阵列**上, 不冲突; use_sel_q 每拍至多一个写口。
      if (u_usel_en) use_sel_q[u_usel_idx] <= u_usel_nxt;

      // 1) provider 的 pred **无条件**更新 (规格 §5/§6);
      //    u 只在 `altpred != fpred` 时更新。
      //    静态策略下该条件成立时必有 fpred == provider_pred, 所以 u 的增减方向
      //    就是"fpred 猜没猜对"。⚠️ 将来若上动态 USE_SEL, 这个等价不成立,
      //    那时必须把 provider_pred 也一起带出到 EX。
      if (u_prov == 3'd0)
        t0_q[u_t0_idx*SLOTS + u_slot] <= u_t0_nxt;
      else if (u_apred[2] != upd_fpred)
        pv_q[(u_prov-1)*NR_ROWS*SLOTS + u_row_idx[u_prov-1]*SLOTS + u_slot]
          <= {1'b1, u_prov_pred_nxt, u_prov_u_nxt};
      else
        pv_q[(u_prov-1)*NR_ROWS*SLOTS + u_row_idx[u_prov-1]*SLOTS + u_slot]
          <= {1'b1, u_prov_pred_nxt, u_ent[u_prov-1][SLOT_U_POS +: SLOT_U_W]};

      // 2) 误预测 ⇒ 分配 / 老化
      if (u_misp)
      begin
        if (u_k != 3'd0)
        begin
          pv_q[(u_k-1)*NR_ROWS*SLOTS + u_row_idx[u_k-1]*SLOTS + u_slot]
            <= {1'b1, u_alloc_pred, 2'b00};
          tag_q[(u_k-1)*NR_ROWS + u_row_idx[u_k-1]] <= {1'b1, u_row_tag[u_k-1]};

          // 只有行标签真的被替换时才清同行其它 slot (见上面"三处偏离"第 3 条)
          for (wi = 0; wi < SLOTS; wi = wi + 1)
            if ((wi != u_slot) && !u_k_tag_same)
              pv_q[(u_k-1)*NR_ROWS*SLOTS + u_row_idx[u_k-1]*SLOTS + wi]
                <= {SLOT_W{1'b0}};
        end
        else
        begin
          for (wi = ((u_prov == 3'd0) ? 0 : u_prov); wi < NTAB; wi = wi + 1)
            pv_q[wi*NR_ROWS*SLOTS + u_row_idx[wi]*SLOTS + u_slot]
              <= {u_ent[wi][SLOT_VLD_POS],
                  u_ent[wi][SLOT_PRED_POS +: SLOT_PRED_W],
                  u_age[wi]};
        end
      end
    end
  end // p_write

  // ---------------------------------------------------------------------------
  //  配置自检 + 打印 (照 rv32ifu2_icache.v 的做法)
  //
  //  ⚠️ 扫点前**先看这一行**: 原树 icache 参数化就踩过"改的 define 没进到 RTL,
  //     于是所有'不同配置'其实是同一个配置, 整张表作废"
  //     (memory icache-geometry-bugs.md)。
  // ---------------------------------------------------------------------------
  // synopsys translate_off
  // synopsys translate_off
  initial
  begin : p_config_check
    if ((NTAB < 1) || (NTAB > NTABMAX))
    begin
      $display("[IFU2-TAGE] NTAB=%0d 未实现 (只支持 1..%0d)", NTAB, NTABMAX);
      $fatal;
    end

    if (SLOTS != 4)
    begin
      $display("[IFU2-TAGE] SLOTS=%0d 未实现 (只支持 4: 与 16 B 取指块对应)", SLOTS);
      $fatal;
    end

    // ⚠️ 这条检查的口径**反了, 已降级为告警**。原来是 `TAG_W <= 12-ROW_AW` 的
    //    $fatal: 均匀几何下索引+标签恒占 12 位, 标签比让出来的宽没意义。上了
    //    逐表行数之后, 让出索引的是**逻辑行数** RAi, 真正要守的是**下界**
    //    TAG_W >= 12-RAi (见下一条 $fatal)。TAG_W 偏大只是每个表项多存几位
    //    恒 0 —— `tag_row == q_row_tag` 两边高位都是 0, **行为逐位不变**,
    //    所以它不该拦住扫点 (第一版写成 $fatal, 直接把整轮实验毙了)。
    if (TAG_W > (TAG_HI - (MIN_RA + 4) + 1))
      $display("[IFU2-TAGE] ⚠️ TAG_W=%0d 比 min(RA)=%0d 需要的 %0d 位宽 —— 每项多存 %0d 位恒 0 (行为不变, 只浪费面积)",
               TAG_W, MIN_RA, TAG_HI - (MIN_RA + 4) + 1,
               TAG_W - (TAG_HI - (MIN_RA + 4) + 1));

    // 逐表: 标签要装得下被行索引让出来的 (12-RAi) 位。装不下就是"两个不同的
    // 块共用同一个 (索引,标签)" ⇒ 静默假命中, 所以这里是 $fatal 而不是告警。
    if ((TW1 > TAG_W) || (TW2 > TAG_W) || (TW3 > TAG_W) || (TW4 > TAG_W))
    begin
      $display("[IFU2-TAGE] 逐表标签不够宽: TAG_W=%0d, 需要 max(12-RAi)=%0d (RA=%0d/%0d/%0d/%0d)",
               TAG_W, (TW1 > TW2) ? ((TW1 > TW3) ? ((TW1 > TW4) ? TW1 : TW4) : ((TW3 > TW4) ? TW3 : TW4))
                                  : ((TW2 > TW3) ? ((TW2 > TW4) ? TW2 : TW4) : ((TW3 > TW4) ? TW3 : TW4)),
               RA1, RA2, RA3, RA4);
      $fatal;
    end

    if ((RA1 < 1) || (RA2 < 1) || (RA3 < 1) || (RA4 < 1))
    begin
      $display("[IFU2-TAGE] 逐表行数必须 >= 1 (RA=%0d/%0d/%0d/%0d)", RA1, RA2, RA3, RA4);
      $fatal;
    end

    // 逐表行数**不能超过物理深度** ROW_AW (阵列就 2^ROW_AW 行)。超了会被夹到
    // ROW_AW —— 这是静默降级, 扫点时名字会跟实际对不上, 所以必须吼一声。
    // 想要某张表**更大**, 得抬 BP_TAGE_AW 再把别的表缩下来 (物理阵列一起变大)。
    if ((ROW_AW_T1 > ROW_AW) || (ROW_AW_T2 > ROW_AW)
     || (ROW_AW_T3 > ROW_AW) || (ROW_AW_T4 > ROW_AW))
      $display("[IFU2-TAGE] ⚠️ 逐表行数被夹到物理深度 ROW_AW=%0d (请求 %0d/%0d/%0d/%0d) —— 实际生效见上面 RA=",
               ROW_AW, ROW_AW_T1, ROW_AW_T2, ROW_AW_T3, ROW_AW_T4);

    if ((L1 > GHR_W) || (L2 > GHR_W) || (L3 > GHR_W) || (L4 > GHR_W))
    begin
      $display("[IFU2-TAGE] 历史长度超过 GHR_W=%0d, 折叠会退化", GHR_W);
      $fatal;
    end

    if (USEL_W < 2)
    begin
      // 有符号计数器至少要留 1 位符号 + 1 位数值, 否则永远判不出"负"
      $display("[IFU2-TAGE] USEL_W=%0d 太小 (有符号计数器至少 2 位)", USEL_W);
      $fatal;
    end

    if (INIT_ROWS > NR_ROWS)
    begin
      // 不是错, 但会**加长初始化**, 所有用例的周期数都会跟着变 —— 先让人看见
      $display("[IFU2-TAGE] ⚠️ 初始化扫描 %0d 拍 (表只有 %0d 行): USEL_AW/T0_AW 抬高了 INIT_ROWS",
               INIT_ROWS, NR_ROWS);
    end

    // ⚠️ ROWS 打的是**逐表逻辑行数** RA1../RA4, 不是物理阵列深度 NR_ROWS ——
    //    缩过的表在物理阵列里仍占 2^ROW_AW 行 (故意的, 见参数段注释)。
    //    面积也按逻辑行数算, 那才是被评估的设计点。核对配置请看 RA= 这一段。
    $display("[IFU2-TAGE] T0=%0d(H=%0d) TAB=%0d PHYS=%0d RA=%0d/%0d/%0d/%0d TAG_W=%0d GHR=%0d L=%0d/%0d/%0d/%0d SEL=%0d/%0d(en%0d gate%0d idx%0d L%0d) AREA=%0d bit",
             T0_ROWS, T0_HIST, NTAB, NR_ROWS, RA1, RA2, RA3, RA4, TAG_W, GHR_W,
             L1, L2, L3, L4,
             USEL_ROWS, USEL_W, USEL_EN, USEL_GATE, USEL_IDX, USEL_L,
             T0_ROWS*SLOTS*2 + LG_ROWS*(1+TAG_W) + LG_ROWS*SLOTS*SLOT_W
             + USEL_ROWS*USEL_W + GHR_W);
  end // p_config_check
  // synopsys translate_on

endmodule
