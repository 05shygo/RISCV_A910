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
//
//---------------------------------------------------------------------------
// 存储形态 (2026-09-28 重排, 为 FPGA 综合)
//
// 原来是三个**平铺**的寄存器阵列 (tag_q 256×7 / pv_q 1024×6 / t0_q 256×2) + use_sel。
// 平铺带来两个 FPGA 上致命的问题:
//   1. **写口多**。同一个 always 块里 provider 更新、误预测分配、同行其它 slot 清零、
//      老化递减、init 扫描各写一遍, pv_q 一拍最多 16 个写地址。合成器对"多写口
//      同工艺"的阵列只能 `RAM dissolved into registers` —— 8.7 K 个 FF, 占全设计
//      13.2 K FF 的三分之二 (实测报告)。
//   2. **读写构成一条组合环, 规模是阵列的全展开**。训练要在同一拍里
//      `读 1024 项里的一项 → 算新的计数器 → 写回`。平铺阵列下读是 1024:1 的 mux 树,
//      写要广播到全部 6144 个 FF 的 D 端, 实测那条路 12.6 ns 里只有 2.0 ns 是逻辑,
//      10.6 ns 是布线 —— 阵列摊开之后的物理距离本身就是延迟。
//
// 重排后的形态:
//   * **逐表**: 每张 tagged 表一个独立阵列, 于是"这批写落在哪张表"不再需要
//     在同一个阵列内部区分 —— 每个阵列每拍**只有一个写口**。
//   * **行打包**: 一行 4 个 slot 的 {vld,pred,u} 打包成一个 ROW_W=24 位的字。
//     于是"清同行其它 slot"从 4 个写口变成 1 个整行写, init 扫描同理。
//   * **双副本**: 预测读 (F1, 地址 q_row_idx) 与训练读 (地址 u_row_idx) 是两个
//     互不相关的地址, 所以每张表存两份 —— `_p` 副本喂 F1, `_u` 副本喂训练。
//     两份都写, 内容恒等。64 深 × 24 位的分布式 RAM 一份只要 24 个 LUT6,
//     整个 TAGE 的阵列因此从 8.7 K FF 降到约 250 个 LUT6。
//   * 每个阵列都是教科书模板 (`if (we) mem[a] <= d;` + `assign q = mem[ra];`),
//     带 `ram_style = "distributed"` ⇒ 落 RAM64X1D 而不是 FF。
//
//   * **训练打两拍** (2026-09-28 第二步): 训练原本是**一整条组合链**跑在一拍里
//     (ID_EX.ex_bht_chk → 折历史 → 行索引 → 读阵列 → 命中/优先级 → 计数器递推 →
//     写数据 → 阵列的 D 端), 综合报告里那是全设计最差的一条 (23 级逻辑、12.6 ns,
//     其中 10.6 ns 是布线)。现在切成 E / U1 / U2 三段, 每段起点都是一级寄存器,
//     见下面 §训练打两拍。**这一步会改变训练可见性的延迟** (写落盘晚两拍),
//     所以它的判据是实测周期数与准确率, 不是"逐位不变"。
//
//   ⚠️ use_sel_q 保持寄存器阵列 (64×4 = 256 FF, 可忽略), 但**另加一份只存符号位
//      的分布式 RAM 副本** `usel_sgn_p` 给 F1 —— 预测路径只要最高位, 而 FF 阵列的
//      64:1 读是一棵三级的 mux 树, 换成一个 LUT 的 LUTRAM 读。
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

  // pv 的字段布局: {slot_vld, pred[SLOT_PRED_W-1:0], u[SLOT_U_W-1:0]}
  localparam SLOT_U_W     = 2;                     // u: 有用位计数器
  localparam SLOT_PRED_W  = 3;                     // pred: 3 位饱和计数器
  localparam SLOT_W       = 1 + SLOT_PRED_W + SLOT_U_W;
  localparam SLOT_U_POS      = 0;                  // pv[SLOT_U_POS    +: SLOT_U_W]
  localparam SLOT_PRED_POS   = SLOT_U_POS + SLOT_U_W;
  localparam SLOT_PRED_TAKEN = SLOT_PRED_POS + SLOT_PRED_W - 1;  // pred 符号位 = 方向
  localparam SLOT_VLD_POS    = SLOT_PRED_POS + SLOT_PRED_W;      // slot 有效位

  // 一行打包后的宽度 (= 4 slot × 6 位 = 24)。整个文件里"一行"都指这个宽度的字。
  localparam ROW_W = SLOTS * SLOT_W;

  localparam T0_TAKEN_POS = 1;                     // T0 是 2 位计数器, 高位 = 方向
  localparam T0_ROW_W     = SLOTS * 2;             // T0 一行 = 4 slot × 2 位

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

  // ---- 逐表阵列的两份副本, 以及它们各自的读口 ----
  //   `_p` 副本: F1 预测读, 读地址 q_row_idx[gi]      (与顶层同拍)
  //   `_u` 副本: 训练读,   读地址 u1_row_idx[gi]     (U1 那一级)
  // 两份内容恒等 —— 写口同时写两边。分两份是因为两个读地址互不相关, 分布式 RAM
  // 只能靠复制来加读口 (与其让工具隐式复制, 不如显式写出来, 端口数一眼可数)。
  wire [ROW_W-1:0] tb_row_rd [0:NTABMAX-1];        // 预测读: 整行 {4 × {vld,pred,u}}
  wire [TAG_W:0]   tb_tag_rd [0:NTABMAX-1];        // 预测读: {行有效, tag}
  wire [ROW_W-1:0] tb_row_up [0:NTABMAX-1];        // 训练读: 整行
  wire [TAG_W:0]   tb_tag_up [0:NTABMAX-1];        // 训练读: {行有效, tag}

  // ---- 训练的两级流水 (2026-09-28 加, 见下面 §训练打两拍) ----
  //
  //   U1: 索引/控制打一拍 (源是 upd_pc/upd_ghr 现算出来的组合量)
  //   U2: 写命令打一拍 —— 写口真正用的是这一级
  reg              u1_vld;
  reg [ROW_AW-1:0] u1_row_idx [0:NTAB-1];
  reg [TAG_W-1:0]  u1_row_tag [0:NTAB-1];
  reg [T0_AW-1:0]  u1_t0_idx;
  reg [USEL_AW-1:0] u1_usel_idx;
  reg [1:0]        u1_slot;
  reg              u1_taken;
  reg              u1_fpred;

  // ---- 每表一个写口 (训练/扫描共用) ----
  // 原本 pv_q 一拍最多 16 个写地址, 现在按表拆开后**每张表每拍至多一个**:
  // provider 与分配/老化按构造落在不同的表上 (老化从 provider 的下一张开始扫),
  // 而"清同行其它 slot"与 init 都并进了整行写。加了流水之后这条不变量仍然成立 ——
  // U2 只有一份寄存器, 每拍至多一笔写命令在落盘。
  reg              u2_pv_we   [0:NTABMAX-1];
  reg [ROW_AW-1:0] u2_pv_addr [0:NTABMAX-1];
  reg [ROW_W-1:0]  u2_pv_data [0:NTABMAX-1];
  reg              u2_tg_we   [0:NTABMAX-1];
  reg [TAG_W:0]    u2_tg_data [0:NTABMAX-1];

  // ---- T0: 同样行打包 + 双副本 ----
  (* ram_style = "distributed" *) reg [T0_ROW_W-1:0] t0_p [0:T0_ROWS-1];
  (* ram_style = "distributed" *) reg [T0_ROW_W-1:0] t0_u [0:T0_ROWS-1];
  wire [T0_ROW_W-1:0] t0_row_rd;
  wire [T0_ROW_W-1:0] t0_row_up;
  reg  [T0_AW-1:0]    t0_waddr;                    // U2 写地址
  reg  [T0_ROW_W-1:0] t0_wdata;
  reg                 t0_we;
  wire [1:0]          t0_s [0:SLOTS-1];            // 预测读按 slot 拆开给 t0_pred

  // ---- USE_SEL: 主体仍是寄存器阵列, 另加一份只存符号位的 LUTRAM 给 F1 ----
  reg [USEL_W-1:0] use_sel_q [0:USEL_ROWS-1];
  reg              usel_sgn_p [0:USEL_ROWS-1];     // 只存最高位 (= 符号)
  reg              usel_we;
  reg [USEL_AW-1:0] usel_waddr;                    // U2 写地址
  reg [USEL_W-1:0] usel_wdata;

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
  // ⚠️ 读的是 usel_sgn_p (只存符号位的 LUTRAM 副本), 不是 use_sel_q —— 见头注释。
  wire use_sel_neg = usel_sgn_p[q_usel_idx];

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
  wire [1:0]       u_prov_u_keep;
  wire [2:0]       u_prov_pred_nxt;
  wire [1:0]       u_t0_nxt;
  wire [USEL_AW-1:0] u_usel_idx_c;   // 组合算出来的 (U1 的输入)
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

  // 整行里替换掉第 s 个 slot, 其余原样保留。
  // 行打包把"写一个 slot"变成"写一整行", 于是同行其它 slot 的清零/保留都落在这
  // 一个函数里, 不再各开一个写口。SLOTS 变化时这里不会静默出错 (循环按参数走)。
  function automatic [ROW_W-1:0] slot_put ( input [ROW_W-1:0]  row,
                                            input [1:0]        s,
                                            input [SLOT_W-1:0] v);
    integer k;
    begin : fn_slot_put
      for (k = 0; k < SLOTS; k = k + 1)
        slot_put[k*SLOT_W +: SLOT_W] = (k == s) ? v : row[k*SLOT_W +: SLOT_W];
    end
  endfunction

  // T0 的同义函数 (一行 4 个 2 位计数器)
  function automatic [T0_ROW_W-1:0] t0_put ( input [T0_ROW_W-1:0] row,
                                             input [1:0]          s,
                                             input [1:0]          v);
    integer k;
    begin : fn_t0_put
      for (k = 0; k < SLOTS; k = k + 1)
        t0_put[k*2 +: 2] = (k == s) ? v : row[k*2 +: 2];
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
  //  逐表阵列 + 两个读口 + 一个写口
  //
  //  这是本次重排的核心: 每张表 = 4 个 64 深的小阵列 (pv 的预测/训练副本 +
  //  tag 的预测/训练副本), 每个阵列 1 写口 1 组合读口, 教科书模板 ⇒ 分布式 RAM。
  //
  //  ⚠️ 两份副本必须**同时写**、内容恒等 —— 训练读看到的旧值正是"训练自己的读"
  //     该看到的 (写在同一拍边沿落下), 与平铺阵列的语义逐位相同。
  //  ⚠️ 扫描那支的 rst 优先级与原来一致: 复位时**不写阵列** (中途复位时
  //     init_done_q 还是 1, 少了这条训练会写进还没清干净的阵列)。
  // ---------------------------------------------------------------------------
  generate
    for (gi = 0; gi < NTABMAX; gi = gi + 1)
      begin : g_tab
        // ⚠️ 存储对 NTABMAX 张表**无条件**例化, 只有读口分 g_used / g_unused。
        //    为什么不为未用的表省掉: tb 的 +BENCH 探针要逐表扫"有多少行真的被写过",
        //    而层次名不能用变量下标, 只能按常量展开 g_tab[0..3] —— 未用表不例化的话
        //    NTAB<4 的扫点配置会让 tb 直接编不过。未用表的写使能恒 0、读口恒 0,
        //    是纯死逻辑, 综合时会被清掉 (默认 NTAB=4 全部在用, 一点不浪费)。
        (* ram_style = "distributed" *) reg [ROW_W-1:0] pv_p [0:NR_ROWS-1];
        (* ram_style = "distributed" *) reg [ROW_W-1:0] pv_u [0:NR_ROWS-1];
        (* ram_style = "distributed" *) reg [TAG_W:0]   tg_p [0:NR_ROWS-1];
        (* ram_style = "distributed" *) reg [TAG_W:0]   tg_u [0:NR_ROWS-1];

        always @(posedge clk)
        begin : p_tab
          if (rst)
          begin
            // 复位不写阵列 —— 清零交给初始化扫描 (与 btb/bht/icache 同一套做法)
          end
          else if (!init_done_q)
          begin
            // 扫描: 一行写一次 (原来是 4 个 slot 各写一次, 覆盖范围相同)
            pv_p[init_cnt_q[ROW_AW-1:0]] <= {ROW_W{1'b0}};
            pv_u[init_cnt_q[ROW_AW-1:0]] <= {ROW_W{1'b0}};
            tg_p[init_cnt_q[ROW_AW-1:0]] <= {(TAG_W+1){1'b0}};
            tg_u[init_cnt_q[ROW_AW-1:0]] <= {(TAG_W+1){1'b0}};
          end
          else
          begin
            if (u2_pv_we[gi])
            begin
              pv_p[u2_pv_addr[gi]] <= u2_pv_data[gi];
              pv_u[u2_pv_addr[gi]] <= u2_pv_data[gi];
            end
            if (u2_tg_we[gi])
            begin
              tg_p[u2_pv_addr[gi]] <= u2_tg_data[gi];
              tg_u[u2_pv_addr[gi]] <= u2_tg_data[gi];
            end
          end
        end // p_tab

        if (gi < NTAB)
          begin : g_used
            // 预测读 (F1) —— 地址是 F0 打过来的寄存器
            assign tb_row_rd[gi] = pv_p[q_row_idx[gi]];
            assign tb_tag_rd[gi] = tg_p[q_row_idx[gi]];

            // 训练读 —— 地址是 U1 打过来的寄存器。
            //
            // ⚠️ **旁路是必需的**: U1 这一拍读表时, U2 那笔写正在**同一个边沿**落盘,
            //    所以组合读到的还是旧值。不补这一路, 连着两拍训到同一行时会丢掉前一笔
            //    (紧循环里的分支真的会这样)。旁路之后读侧看到的就等价于"所有更早的
            //    训练都已落盘", 与不流水的版本逐位相同 —— 见头注释 §训练打两拍。
            //    比较口径必须是**表号 + 行号**, 不能用近似量。
            wire pv_byp = u2_pv_we[gi] & (u2_pv_addr[gi] == u1_row_idx[gi]);
            wire tg_byp = u2_tg_we[gi] & (u2_pv_addr[gi] == u1_row_idx[gi]);
            assign tb_row_up[gi] = pv_byp ? u2_pv_data[gi] : pv_u[u1_row_idx[gi]];
            assign tb_tag_up[gi] = tg_byp ? u2_tg_data[gi] : tg_u[u1_row_idx[gi]];
          end
        else
          begin : g_unused
            assign tb_row_rd[gi] = {ROW_W{1'b0}};
            assign tb_tag_rd[gi] = {(TAG_W+1){1'b0}};
            assign tb_row_up[gi] = {ROW_W{1'b0}};
            assign tb_tag_up[gi] = {(TAG_W+1){1'b0}};
          end
      end
  endgenerate

  // ---------------------------------------------------------------------------
  //  T0 阵列 (行打包 + 双副本) 与 USE_SEL
  // ---------------------------------------------------------------------------
  always @(posedge clk)
  begin : p_t0
    if (rst)
    begin
    end
    else if (!init_done_q)
    begin
      t0_p[init_cnt_q[T0_AW-1:0]] <= {T0_ROW_W{1'b0}};
      t0_u[init_cnt_q[T0_AW-1:0]] <= {T0_ROW_W{1'b0}};
    end
    else if (t0_we)
    begin
      t0_p[t0_waddr] <= t0_wdata;
      t0_u[t0_waddr] <= t0_wdata;
    end
  end // p_t0

  assign t0_row_rd = t0_p[q_t0_idx];
  // 训练读 + 旁路 (同 pv/tg, 理由见 g_used 那段注释)
  assign t0_row_up = (t0_we & (t0_waddr == u1_t0_idx)) ? t0_wdata : t0_u[u1_t0_idx];

  always @(posedge clk)
  begin : p_usel
    if (rst)
    begin
    end
    else if (!init_done_q)
    begin
      use_sel_q [init_cnt_q[USEL_AW-1:0]] <= {USEL_W{1'b0}};
      usel_sgn_p[init_cnt_q[USEL_AW-1:0]] <= 1'b0;
    end
    else if (usel_we)
    begin
      use_sel_q [usel_waddr] <= usel_wdata;
      usel_sgn_p[usel_waddr] <= usel_wdata[USEL_W-1];
    end
  end // p_usel

  // 训练读 + 旁路 (同 pv/tg)
  wire [USEL_W-1:0] usel_rd = (usel_we & (usel_waddr == u1_usel_idx))
                            ? usel_wdata : use_sel_q[u1_usel_idx];

  // ---------------------------------------------------------------------------
  //  F1: 逐表读行 (行打包后每张表只有一个读口)
  //
  //  行标签是**整行共享**的 (一个块一个 tag), slot 靠自己的有效位区分,
  //  所以 hit 是 (表, slot) 二维的。
  // ---------------------------------------------------------------------------
  generate
    for (gi = 0; gi < NTABMAX; gi = gi + 1)
      begin : g_f1_read
        if (gi < NTAB)
          begin : g_used
            wire [TAG_W:0] tag_row   = tb_tag_rd[gi];
            wire           tag_match = (tag_row[TAG_W-1:0] == q_row_tag[gi]);

            for (gs = 0; gs < SLOTS; gs = gs + 1)
              begin : g_slot
                wire [SLOT_W-1:0] pv = tb_row_rd[gi][gs*SLOT_W +: SLOT_W];

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

  // T0 的逐 slot 方向 (行打包后从一行里取 4 个 2 位字段)
  generate
    for (gs = 0; gs < SLOTS; gs = gs + 1)
      begin : g_t0_s
        assign t0_s[gs] = t0_row_rd[gs*2 +: 2];
      end
  endgenerate

  assign t0_pred = { t0_s[3][T0_TAKEN_POS], t0_s[2][T0_TAKEN_POS],
                     t0_s[1][T0_TAKEN_POS], t0_s[0][T0_TAKEN_POS] };

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
  //
  //  §训练打两拍 (2026-09-28)
  //
  //  加流水之前, 训练是**一整条组合链**跑在一拍里的:
  //      ID_EX.ex_bht_chk → fold_history → 行索引 → 读阵列 → 命中/优先级 →
  //      3 位计数器递推 → 写数据 → 阵列的 D 端
  //  综合报告里这是全设计最差的一条, 而路径上 23 级逻辑里大部分是**读阵列的 mux**
  //  (4×MUXF7 + 4×MUXF8), 12.6 ns 里 10.6 ns 是布线 —— 逻辑级的账其实不难看,
  //  难看的是一整块阵列摊开之后的物理距离。上一版把阵列改成逐表 LUTRAM 之后读侧
  //  从 1024:1 缩到 64:1, 但那仍是同一拍里的组合链。
  //
  //  这里把它切成三段, 每段的起点都是一级寄存器:
  //      E    (upd_vld 那一拍) 组合算索引                     → U1 寄存器
  //      U1   读表 + 命中判定 + provider/分配/老化 + 计数器递推 → U2 寄存器
  //      U2   写口 (地址/数据/使能)
  //
  //  ⚠️ **唯一一处会改变行为的地方**: 写落盘从"E 边沿"推迟到"E+2 边沿"。
  //     U1 那一段的读用旁路补齐 (见 g_used / t0 / usel_rd 三处的注释), 所以**训练
  //     自己看到的表状态与不流水时逐位相同**; 变的是"预测读"能看到这次训练结果的
  //     时刻晚了两拍。紧循环 (体长 1~2 拍) 里可能因此少学到一次, 长程稳态不受影响。
  //     这一步的判据是**实测周期数与准确率**, 不是"逐位不变"。
  //
  //  ⚠️ 索引仍然在 E 那一拍从 (upd_pc, upd_ghr) **重算**, 没有改成随 chk 携带。
  //     理由见头注释 §Training: 携带的编号会在 F1→EX 的几拍里过期 (表还在被别的
  //     分支写), 拿它当写地址会改到别的块的表项上。重算是读写索引一致性的保证。
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

  assign u_usel_idx_c = usel_index(upd_pc, upd_ghr);

  // ---- U1: 索引与控制打一拍 ----
  // 只打"索引/控制"这一层, 不打折出来的历史树 —— 折历史 (fold_history) 本身是
  // XOR 树, 放在 U1 的起点这一段里, 后面整段就与它无关了。
  always @(posedge clk)
  begin : p_u1
    if (rst)
    begin
      u1_vld    <= 1'b0;
      u1_t0_idx <= {T0_AW{1'b0}};
      u1_usel_idx <= {USEL_AW{1'b0}};
      u1_slot   <= 2'b00;
      u1_taken  <= 1'b0;
      u1_fpred  <= 1'b0;
      for (wj = 0; wj < NTAB; wj = wj + 1)
      begin
        u1_row_idx[wj] <= {ROW_AW{1'b0}};
        u1_row_tag[wj] <= {TAG_W{1'b0}};
      end
    end
    else
    begin
      // 扫描期间不训练 (与原来一致): init_done_q 为 0 时 u1_vld 恒 0,
      // 于是 U2 那级只会锁进全 0 的写命令。
      u1_vld    <= upd_vld & init_done_q;
      u1_t0_idx <= u_t0_idx;
      u1_usel_idx <= u_usel_idx_c;
      u1_slot   <= u_slot;
      u1_taken  <= upd_taken;
      u1_fpred  <= upd_fpred;
      for (wj = 0; wj < NTAB; wj = wj + 1)
      begin
        u1_row_idx[wj] <= u_row_idx[wj];
        u1_row_tag[wj] <= u_row_tag[wj];
      end
    end
  end // p_u1

  // T0 是 2 位计数器, 借高两位拼成"3 位口径"以便和 tagged 表统一比较 ——
  // 只有 bit[2] (方向) 会被用到。
  assign u_t0_pred = {t0_row_up[u1_slot*2 + T0_TAKEN_POS], 2'b00};

  assign u_t0_nxt = ctr2_next(t0_row_up[u1_slot*2 +: 2], u1_taken);

  generate
    for (gi = 0; gi < NTAB; gi = gi + 1)
      begin : g_u_read
        assign u_tag_row[gi] = tb_tag_up[gi];
        assign u_ent    [gi] = tb_row_up[gi][u1_slot*SLOT_W +: SLOT_W];
        assign u_hit    [gi] = u_tag_row[gi][TAG_W] & (u_tag_row[gi][TAG_W-1:0] == u1_row_tag[gi])
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
  assign u_misp  = (u1_fpred != u1_taken);

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
  // 写索引: **同一个 usel_index**, 只是换成 (upd_pc, upd_ghr) —— 它在 E 那一拍算好
  // 后打进了 u1_usel_idx, 这里读的是 U1 的副本。读地址与写地址是同一个寄存器,
  // 所以读写必然同址 (memory bp-class3-root-cause 那条纪律)。
  // ⚠️ upd_ghr 是随指令走完全程的那份 GHR 快照, 与表索引用的是同一对 (pc, ghr)。
  assign u_usel_up  = (u_apred[2] == u1_taken);
  assign u_usel_nxt = usel_ctr_next(usel_rd, u_usel_up);

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
                                     u1_fpred == u1_taken);
  // u 保持不变那一支: `altpred == fpred` 时 u 不动, 只更新 pred
  assign u_prov_u_keep   = u_ent[u_prov_s-1][SLOT_U_POS +: SLOT_U_W];
  assign u_prov_pred_nxt = ctr3_next(u_ppred, u1_taken);

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
                   & (u_tag_row[u_k-1][TAG_W-1:0] == u1_row_tag[u_k-1]);
  end // p_u_alloc

  // 新分配的表项: pred = 本次结果的弱方向 (011/100), u = 0
  assign u_alloc_pred = u1_taken ? 3'b100 : 3'b011;

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
  //  U2: 写命令打一拍
  //
  //  所有写入落在**互不重叠**的表上: provider 的表 vs 分配/老化落到的更长的
  //  表, 按构造是不同表 —— 于是"每张表每拍一个写口"这条不变量成立, 也是这次
  //  重排能落 LUTRAM 的全部理由。下面仍然用 if/else 给出优先级, 万一将来加一条
  //  新的写源, 行为是确定的而不是"两个 always 分支各写各的"。
  //
  //  与平铺版的逐位对应关系:
  //    * provider 写 = 整行里替换掉第 u1_slot 个 slot 的 {vld, pred, u}
  //    * 分配写     = 整行 (行标签被替换时其余 slot 清零, 否则保留 —— 见 §6 偏离 3)
  //    * 老化写     = 整行里只替换第 u1_slot 个 slot 的 u
  //    * tag 写     = 只有分配那一路才有
  //
  //  U2 是**打拍**的 (非阻塞写 u2_* 寄存器) —— 这正是切断那条组合环的那一下:
  //  上面那一大段判定全部落在 U1 这一拍里, 结果只走寄存器到写口, 写口后面
  //  只剩"地址 + 数据 + 使能"三组寄存器到阵列的 D 端。
  //
  //  ⚠️ 每个分支都必须显式把**所有** u2_* 写一遍 (没有"保持"语义): 它们是流水
  //     寄存器, 靠"本拍没有训练就写 0"来表达"本拍没有训练"。漏清一路就是一笔幽灵写。
  // ---------------------------------------------------------------------------
  always @(posedge clk)
  begin : p_u2
    integer li;
    for (li = 0; li < NTABMAX; li = li + 1)
    begin
      u2_pv_we[li]   <= 1'b0;
      u2_pv_addr[li] <= {ROW_AW{1'b0}};
      u2_pv_data[li] <= {ROW_W{1'b0}};
      u2_tg_we[li]   <= 1'b0;
      u2_tg_data[li] <= {(TAG_W+1){1'b0}};
    end
    t0_we      <= 1'b0;
    t0_waddr   <= {T0_AW{1'b0}};
    t0_wdata   <= {T0_ROW_W{1'b0}};
    usel_we    <= 1'b0;
    usel_waddr <= {USEL_AW{1'b0}};
    usel_wdata <= {USEL_W{1'b0}};

    // rst / 扫描期间: 上面那组默认值已经把在途命令清成 0, 不需要再写一遍
    if (!rst && init_done_q && u1_vld)
    begin
      // 0) USE_SEL (门控见 u_usel_en 处的注释)。它自成一张小表, 与其它写入不冲突。
      usel_we    <= u_usel_en;
      usel_waddr <= u1_usel_idx;
      usel_wdata <= u_usel_nxt;

      // 1) provider 的 pred **无条件**更新 (规格 §5/§6);
      //    u 只在 `altpred != fpred` 时更新 (否则保持原值)。
      if (u_prov == 3'd0)
      begin
        t0_we    <= 1'b1;
        t0_waddr <= u1_t0_idx;
        t0_wdata <= t0_put(t0_row_up, u1_slot, u_t0_nxt);
      end
      else
      begin
        u2_pv_we  [u_prov-1] <= 1'b1;
        u2_pv_addr[u_prov-1] <= u1_row_idx[u_prov-1];
        u2_pv_data[u_prov-1] <= slot_put(tb_row_up[u_prov-1], u1_slot,
                                         {1'b1, u_prov_pred_nxt,
                                          (u_apred[2] != u1_fpred) ? u_prov_u_nxt
                                                                   : u_prov_u_keep});
      end

      // 2) 误预测 ⇒ 分配 / 老化
      if (u_misp)
      begin
        if (u_k != 3'd0)
        begin
          u2_pv_we  [u_k-1] <= 1'b1;
          u2_pv_addr[u_k-1] <= u1_row_idx[u_k-1];
          // 只有行标签真的被替换时才清同行其它 slot (见上面"三处偏离"第 3 条)
          u2_pv_data[u_k-1] <= slot_put(u_k_tag_same ? tb_row_up[u_k-1] : {ROW_W{1'b0}},
                                        u1_slot, {1'b1, u_alloc_pred, 2'b00});
          u2_tg_we  [u_k-1] <= 1'b1;
          u2_tg_data[u_k-1] <= {1'b1, u1_row_tag[u_k-1]};
        end
        else
        begin
          for (wi = ((u_prov == 3'd0) ? 0 : u_prov); wi < NTAB; wi = wi + 1)
          begin
            u2_pv_we  [wi] <= 1'b1;
            u2_pv_addr[wi] <= u1_row_idx[wi];
            u2_pv_data[wi] <= slot_put(tb_row_up[wi], u1_slot,
                                       {u_ent[wi][SLOT_VLD_POS],
                                        u_ent[wi][SLOT_PRED_POS +: SLOT_PRED_W],
                                        u_age[wi]});
          end
        end
      end
    end
  end // p_u2

  // ---------------------------------------------------------------------------
  //  配置自检 + 打印 (照 rv32ifu2_icache.v 的做法)
  //
  //  ⚠️ 扫点前**先看这一行**: 原树 icache 参数化就踩过"改的 define 没进到 RTL,
  //     于是所有'不同配置'其实是同一个配置, 整张表作废"
  //     (memory icache-geometry-bugs.md)。
  // ---------------------------------------------------------------------------
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
