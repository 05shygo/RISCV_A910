`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_preg — 物理寄存器四态表 + 两拍分配 + 架构映射表 AMT (D2 / D3)。
//
// 四态 (每 preg 2 bit, 共 192 bit):
//   FREE --(优先编码选中, T)--> WF_ALLOC --(派遣确认, T+1)--> ALLOC
//                                    \--(没派成/被冲刷)--------> FREE
//   ALLOC --(退休且写回)--> ARCH        ALLOC --(陷阱那条)--> FREE
//   ARCH  --(退休释放 old_preg && >=32)--> FREE
//   冲刷: 非 ARCH 全部回 FREE (一拍并行, 每个 preg 各看各的, 不用扫描)
//
// ⚠️ `WF_ALLOC` 不是多余的簿记: 96 位三端口优先编码器是 7 级左右的组合深度,
//    直接串在"派遣 → 分配 → 更新状态"这条链上会把派遣拍压垮 (§4.2 的 P3)。
//    C910 也是切成两拍 (`ct_rtu_pst_preg_entry.v:288-295`)。
// ⚠️ `p0..p31` 永不进自由池 —— 退休释放 old_preg 时必须判 `>= 32`,
//    否则第一次写 x1 就把初始映射 p1 放回池子 (D2 里标"最容易漏的一行",
//    本核把它放在**调用方** RTU.v 一处判, 免得观察口与池子两处判得不一致)。
//
// 空闲计数用**加减计数器**而不是 popcount: disp_stall 要喂给前端的捕获使能,
// 而 IF_ID 捕获本来就在 500 条最差路径里 (§4.2 的 P8)。计数器只被寄存器事件驱动。
// ---------------------------------------------------------------------------
module RTU_preg (
    input  wire        cpu_clk,
    input  wire        cpu_rst,

    // ---- §6.0 分配请求 (T 拍) ----
    input  wire [1:0]  ren_preg_req,
    input  wire [4:0]  ren_preg_req_lreg0,
    input  wire [4:0]  ren_preg_req_lreg1,
    input  wire [4:0]  ren_preg_req_lreg2,

    // ---- 派遣确认 (T+1 拍) ----
    input  wire [2:0]  disp_vld,
    input  wire [6:0]  disp_dst_preg0,
    input  wire [6:0]  disp_dst_preg1,
    input  wire [6:0]  disp_dst_preg2,

    // ---- 退休 ----
    input  wire [2:0]  ret_arch_vld,     // dst_preg -> ARCH (+ AMT 写)
    input  wire [2:0]  ret_kill_vld,     // 陷阱那条: 分配过但没写的 dst_preg -> FREE
    input  wire [2:0]  ret_free_vld,     // old_preg (已判 >=32) -> FREE
    input  wire [6:0]  ret_dst_preg0, ret_dst_preg1, ret_dst_preg2,
    input  wire [6:0]  ret_old_preg0, ret_old_preg1, ret_old_preg2,
    input  wire [4:0]  ret_dst_lreg0, ret_dst_lreg1, ret_dst_lreg2,

    // ---- 冲刷 (FLUSH_2) ----
    input  wire        flush_lvl,

    // ---- 输出 ----
    output wire [6:0]  rtu_preg_alloc0,
    output wire [6:0]  rtu_preg_alloc1,
    output wire [6:0]  rtu_preg_alloc2,
    output wire        rtu_preg_alloc_vld0,
    output wire        rtu_preg_alloc_vld1,
    output wire        rtu_preg_alloc_vld2,
    output wire [6:0]  free_cnt,               // 7 位真值 (给自检/TB)
    output wire [1:0]  rtu_preg_free_cnt,      // §6.0 的口径: 饱和到 3
    output wire [223:0] amt_flat               // 32 × 7bit, amt_flat[7*l +: 7] = AMT[l]
);

    reg  [1:0]  st [0:95];
    reg  [1:0]  nst[0:95];
    // WF_ALLOC 的"年龄": 刚发出去那一拍是 0, 再等一拍变 1。
    // ⚠️ 放回自由池**要等两拍**, 不能刚发出去没派成下一拍就收 —— §6.0 的握手本来
    //    只留了一拍窗口, 但那样对"发出者晚半拍/晚一拍"零容忍: 编号一旦被放回,
    //    优先编码器立刻可能把它发给别人, 而前一条指令还拿着它 (单测台就是这么撞上的)。
    //    多等一拍只让自由池少一个编号一拍, 没有任何正确性代价。
    reg  [95:0] wf_age;
    reg  [6:0]  amt[0:31];
    reg  [6:0]  free_cnt_q;

    integer     i;
    integer     k;

    // -----------------------------------------------------------------------
    // 三路选择: 独热域 + **平衡树**, 二进制化只在最后出一趟
    //
    //   池子 ──> 高树 (最高空闲) ────────────────────────┐
    //        ├─> 低树 (最低空闲) ──> [末端掩 sel0] ───────┤
    //        └─> 去掉 sel0 ──> 高树 ──> [末端掩 sel1] ────┴─> 三路独热
    //
    // ⚠️ 2026-10-02 第二次重构 (第一版对齐 C910, 这一版对齐 ARM Enyo
    //    `enyo_is_vxq_free_list.sv`)。三件事是分开的:
    //
    //    ① **第 0/1 路并行** —— ARM 把掩码放在**扫描之后** (该文件 `:349`):
    //          iq_second_free = iq_second_free_pre & ~iq_first_free
    //       两路扫描方向相反时, 只有在"恰好剩 1 个空闲"那一拍它们才会撞上, 末端
    //       一个与就修好了 ⇒ 第二路**根本不依赖第一路**, 两条链并行。
    //       我们第 0 路取最高、第 1 路取最低, 正好是同构, 可以直接搬。第 2 路
    //       (次高) 天生要级联, 但它只挂在第 0 路后面 —— 第 1 路的掩码同样挪到末端。
    //       关键链: 3 条扫描串行 → **2 条**。
    //
    //    ② **扫描用平衡树** (fu*/fd*/vu*, 见下), 不用逐位累加链。
    //
    //    ③ **全扁平线网, 不用 function** —— 一棵树就是 7 根名字明确的线, 综合与
    //       调试时一眼能看出它是几级; 函数体反而把深度藏在"调用"后面。
    //
    // ⚠️ 选中的顺序 (高 / 低 / 高) 与历次实现**逐位一致**, 别改: 改顺序不破坏
    //    任何不变量, 但会让回归波形与历史记录对不上。重构的验收判据永远是
    //    "一位不变"。同理, 车道 0 不申请时它的候选位**仍然**被 `~sel0_oh` 排除在
    //    外 (不把后面的请求往前挪) —— 这是 §6.0 的车道语义, 与 req_lane 无关。
    //    ✅ 已机器核对 (一次性 TB, 未进仓库): 随机 / 小池 / 单点 / 边界定向 +
    //       req_lane 全扫下, 三路编号 / alloc_vld / 候选池 / sel_oh 与**原始版**
    //       (enc_lo/enc_hi 优先链 + 二进制往返) 逐位相同。
    //    ⚠️ 该等价性的前提是 `free_vec[31:0] ≡ 0`。现在这条不再靠"p0..p31 恒 ARCH"
    //       那条不变量兜着 —— 池子经 `PREG_HI_MSK` 掩过, 低段**结构上**进不来。
    // -----------------------------------------------------------------------

    // p32..p95 的窗口。p0..p31 是 x0..x31 的初始映射, 永不进自由池 (D2)。
    // ⚠️ 这里**显式**掩出来, 而不是靠"它们恒为 ARCH"这条不变量兜着: 池子向量从
    //    源头就不含低段, 于是 cand0 / 三路扫描 / 计数器三处天然同式, 不用再逐处
    //    论证"那个状态不可达"。合法域里 `|cand0` 与不掩时逐位相同。
    localparam [95:0] PREG_HI_MSK = {64'hFFFF_FFFF_FFFF_FFFF, 32'd0};

    // 独热 → 7 位编号的**位掩码**: BM{k} 里为 1 的那些位 = "编号的第 k 位是 1" 的
    // preg。于是 `|(sel_oh & BM{k})` 就是答案的第 k 位 —— 7 个 AND-OR, 既没有优先
    // 逻辑, 也不用把编号切来切去。
    // 窗口是 p32..p95, 所以高 64 位是"以 p32 为最低位"的周期图案:
    //   位0 周期2 / 位1 周期4 / 位2 周期8 / 位3 周期16 / 位4 周期32 /
    //   位5 = 窗口低半 (p32..p63) / 位6 = 窗口高半 (p64..p95)。
    localparam [95:0] PREG_BM0 = {64'hAAAA_AAAA_AAAA_AAAA, 32'd0};
    localparam [95:0] PREG_BM1 = {64'hCCCC_CCCC_CCCC_CCCC, 32'd0};
    localparam [95:0] PREG_BM2 = {64'hF0F0_F0F0_F0F0_F0F0, 32'd0};
    localparam [95:0] PREG_BM3 = {64'hFF00_FF00_FF00_FF00, 32'd0};
    localparam [95:0] PREG_BM4 = {64'hFFFF_0000_FFFF_0000, 32'd0};
    localparam [95:0] PREG_BM5 = {64'h0000_0000_FFFF_FFFF, 32'd0};
    localparam [95:0] PREG_BM6 = {64'hFFFF_FFFF_0000_0000, 32'd0};

    wire [95:0] free_vec;
    genvar      gv;
    generate
        for (gv = 0; gv < 96; gv = gv + 1) begin : g_free
            assign free_vec[gv] = (st[gv] == `RTU_P_FREE);
        end
    endgenerate

    // 车道是否要分配: 有请求 且 dst 不是 x0 (x0 不分配、不映射)
    wire [2:0] req_lane;
    assign req_lane[0] = (ren_preg_req > 2'd0) && (ren_preg_req_lreg0 != 5'd0);
    assign req_lane[1] = (ren_preg_req > 2'd1) && (ren_preg_req_lreg1 != 5'd0);
    assign req_lane[2] = (ren_preg_req > 2'd2) && (ren_preg_req_lreg2 != 5'd0);

    // 可分配池 (p32..p95 之外恒 0)
    wire [95:0] free_hi = free_vec & PREG_HI_MSK;

    // -----------------------------------------------------------------------
    // "某一位的上方/下方有没有空闲" —— 显式的 Kogge-Stone 平衡树, 6 级翻满 64 位
    //     fu{d}[i] = |free[i+1 : i+d]        fd{d}[i] = |free[i-d : i-1]
    // 每一级就是"自己 或 自己移位"—— 移位是纯布线 ⇒ 一级只花一级 LUT, 6 级 ⇒
    // 深度 6。
    //
    // ⚠️ 为什么显式写树, 而不是让工具去化简逐位累加式 (`found` 链 / C910 的
    //    `x[i] & ~|x[95:i+1]`): 那是**前缀**计算 —— 每个中间量都带着自己的扇出,
    //    综合器默认按链子搭 (最深 64 级), 不保证重平衡成对数深度。显式写出树才是
    //    "深度可控"的那条路。ARM Enyo 的 DetectedOne/DetectedMulti
    //    (`enyo_is_vxq_free_list.sv:771-794`) 就是这个思想; 这里用移位写法表达同一
    //    棵树 (更短, 也不用给本仓引入没先例的二维线网数组)。
    // ⚠️ 低树会往下卷, 输入必须是**已经掩过窗口**的 `free_hi` (p32 以下恒 0);
    //    高树往上卷, 天然碰不到低段。
    // -----------------------------------------------------------------------
    wire [95:0] fu1  = free_hi >> 1;
    wire [95:0] fu2  = fu1  | (fu1  >> 1);
    wire [95:0] fu4  = fu2  | (fu2  >> 2);
    wire [95:0] fu8  = fu4  | (fu4  >> 4);
    wire [95:0] fu16 = fu8  | (fu8  >> 8);
    wire [95:0] fu32 = fu16 | (fu16 >> 16);
    wire [95:0] fu64 = fu32 | (fu32 >> 32);

    wire [95:0] fd1  = free_hi << 1;
    wire [95:0] fd2  = fd1  | (fd1  << 1);
    wire [95:0] fd4  = fd2  | (fd2  << 2);
    wire [95:0] fd8  = fd4  | (fd4  << 4);
    wire [95:0] fd16 = fd8  | (fd8  << 8);
    wire [95:0] fd32 = fd16 | (fd16 << 16);
    wire [95:0] fd64 = fd32 | (fd32 << 32);

    // ⚠️ 第 0/1 路的掩码在**末端**, 不在第 1 路的扫描输入上 —— 两条扫描并行
    //    (ARM `enyo_is_vxq_free_list.sv:349` 的写法)。见上面 ① 的长注。
    //    一位独热 = 自己 & ~(自己上方/下方有别人)。
    wire [95:0] sel0_oh = free_hi & ~fu64;                // 最高
    wire [95:0] sel1_oh = (free_hi & ~fd64) & ~sel0_oh;   // 最低 —— 与 sel0 并行
    wire [95:0] v1      = free_hi & ~sel0_oh;

    // 第 2 路 (次高) 挂在第 0 路后面: 先去最高再找最高; 第 1 路的掩码仍在末端
    wire [95:0] vu1  = v1 >> 1;
    wire [95:0] vu2  = vu1  | (vu1  >> 1);
    wire [95:0] vu4  = vu2  | (vu2  >> 2);
    wire [95:0] vu8  = vu4  | (vu4  >> 4);
    wire [95:0] vu16 = vu8  | (vu8  >> 8);
    wire [95:0] vu32 = vu16 | (vu16 >> 16);
    wire [95:0] vu64 = vu32 | (vu32 >> 32);
    wire [95:0] sel2_oh = (v1 & ~vu64) & ~sel1_oh;

    // ⚠️ 先把每个候选池声明出来再用 —— 本仓有"先用后声明造 1 位隐式线网"的前科
    //    (cpu/sim/rtl_patch/README.md 与 §9 的 R7), 症状是**语义静默错**而不是报错。
    wire [95:0] v2    = v1 & ~sel1_oh;   // = 池子去掉前两路已选中的 (第 2 路的候选域)
    wire [95:0] cand0 = free_hi;
    wire [95:0] cand1 = v1;
    wire [95:0] cand2 = v2;

    // ⚠️ 每一路都必须**同时**用 `|candK` 门控, 三处 (sel_oh / alloc_vld* / 计数器的
    //    n_alloc) 逐位同式 —— 少一处就是"看着发出去了、账上没记"那类慢慢偏的 bug。
    //    旧实现里这条门控还兼着挡一个坑: `1<<sel` 在"没找到"时是 bit 0, 于是池子
    //    不够三路时第 2/3 路会把 **p0 置成 WF_ALLOC**, x0 的映射就没了。
    //    改成独热后 `sel*_oh` 找不到就是 0, 那个坑**结构上消失**了 —— 但门控本身
    //    仍要留: 它守的是"发出去了"这个定义本身, 与编码形式无关。
    wire [95:0] sel_oh = (sel0_oh & {96{req_lane[0] & (|cand0)}})
                       | (sel1_oh & {96{req_lane[1] & (|cand1)}})
                       | (sel2_oh & {96{req_lane[2] & (|cand2)}});

    // 独热 -> 7 位编号: 第 k 位 = "选中的那一位, 它的编号第 k 位是 1" (见 PREG_BM*)。
    // 一个都没选中时 7 位全 0, 与历次实现一致。
    assign rtu_preg_alloc0 = { |(sel0_oh & PREG_BM6), |(sel0_oh & PREG_BM5),
                               |(sel0_oh & PREG_BM4), |(sel0_oh & PREG_BM3),
                               |(sel0_oh & PREG_BM2), |(sel0_oh & PREG_BM1),
                               |(sel0_oh & PREG_BM0) };
    assign rtu_preg_alloc1 = { |(sel1_oh & PREG_BM6), |(sel1_oh & PREG_BM5),
                               |(sel1_oh & PREG_BM4), |(sel1_oh & PREG_BM3),
                               |(sel1_oh & PREG_BM2), |(sel1_oh & PREG_BM1),
                               |(sel1_oh & PREG_BM0) };
    assign rtu_preg_alloc2 = { |(sel2_oh & PREG_BM6), |(sel2_oh & PREG_BM5),
                               |(sel2_oh & PREG_BM4), |(sel2_oh & PREG_BM3),
                               |(sel2_oh & PREG_BM2), |(sel2_oh & PREG_BM1),
                               |(sel2_oh & PREG_BM0) };
    assign rtu_preg_alloc_vld0 = req_lane[0] & (|cand0);
    assign rtu_preg_alloc_vld1 = req_lane[1] & (|cand1);
    assign rtu_preg_alloc_vld2 = req_lane[2] & (|cand2);

    // -----------------------------------------------------------------------
    // 派遣确认 (T+1 拍)
    //
    // 口径: **按"这个编号当前是不是 WF_ALLOC 态"判**, 而不是去比"上一拍发出去的
    // 那个值"。两者在合法协议下等价 (WF_ALLOC 恰好就是上一拍发出去、还没落定的
    // 那一批), 但按状态判**与相位无关** —— 派遣晚半拍/晚一拍都不会把编号误放回
    // 自由池。踩过的坑: 早先按 pend 值比较, TB 侧相位对不齐时 DUT 会静默地把
    // 编号放回 FREE, 而指令还拿着它 —— 自由池立刻放水。
    // -----------------------------------------------------------------------
    wire [95:0] hit_disp;      // 本拍派遣真正用到的编号 (独热)
    genvar      gd;
    generate
        for (gd = 0; gd < 96; gd = gd + 1) begin : g_disp
            assign hit_disp[gd] = (disp_vld[0] && (disp_dst_preg0 == gd))
                               || (disp_vld[1] && (disp_dst_preg1 == gd))
                               || (disp_vld[2] && (disp_dst_preg2 == gd));
        end
    endgenerate

    wire [95:0] is_wf;
    genvar      gw;
    generate
        for (gw = 0; gw < 96; gw = gw + 1) begin : g_wf
            assign is_wf[gw] = (st[gw] == `RTU_P_WFALLOC);
        end
    endgenerate

    wire conf_alloc_any = |(is_wf &  hit_disp);
    wire conf_free_any  = |(is_wf & ~hit_disp);

    // -----------------------------------------------------------------------
    // 陷阱那条的 kill —— **必须门掉 ARCH 态**
    //
    // kill 的语义是"把**分配出去**的编号还回池子" (它没写 rd), 架构态永远不该被
    // kill。不门的话, 阶段 1 的恒等映射 (§7 读法 A: dst_preg == p_<lreg> == ARCH)
    // 会当场踩中: 一条写寄存器的指令陷进去 ⇒ `ret_arch_vld = wr_eff` 是 ~trap 门过的
    // 而 `ret_kill_vld` 是 trap 门过的 ⇒ 下面的转移把 `p_<lreg>` 标成 FREE,
    // 而 AMT 仍指着它。阶段 1 没有消费者 (ren_preg_req 恒 0 ⇒ preg_short 恒假),
    // **功能上看不出来**; 但它永久破坏"ARCH 项数 == 32", 而空闲计数每次冲刷都按
    // `64 − arch_hi_cnt` 重算、状态表却不复原 —— 阶段 2 一开真重命名就两边对不上。
    //
    // ⚠️ 计数器必须用**同一个条件**: `n_freed` 原来无条件把 `ret_kill_vld` 加进去,
    //    门了状态却不门计数, 就是"账目慢慢偏"那类 bug。
    // 真重命名下被 kill 的 dst_preg 必然是 ALLOC/WF_ALLOC ⇒ 这条门控在阶段 2+ 惰性,
    // 单元单测台的行为一位不变。
    // -----------------------------------------------------------------------
    wire [95:0] not_arch_vec;
    genvar      gk;
    generate
        for (gk = 0; gk < 96; gk = gk + 1) begin : g_notarch
            assign not_arch_vec[gk] = (st[gk] != `RTU_P_ARCH);
        end
    endgenerate

    wire [2:0] kill_hit = { ret_kill_vld[2] & not_arch_vec[ret_dst_preg2],
                            ret_kill_vld[1] & not_arch_vec[ret_dst_preg1],
                            ret_kill_vld[0] & not_arch_vec[ret_dst_preg0] };

    // -----------------------------------------------------------------------
    // 四态表更新 (优先级: 冲刷 > 退休 > 派遣确认 > 本拍选中 > 保持)
    // -----------------------------------------------------------------------
    always @(*) begin
        for (i = 0; i < 96; i = i + 1) begin
            // ⚠️ 三个车道之间必须按**程序序从年轻到老**判 (先车道 2, 再 1, 再 0)。
            //    同一条 lreg 在一组里被写两次时, 年轻那条的 `old_preg` 正好是年长那条的
            //    `dst_preg`: 年长那条把它转 ARCH, 年轻那条又要把它放回 FREE —— 架构上
            //    最终是 FREE (年轻的那条才是这条 lreg 的新映射)。按"字段分组"判
            //    (先全判 arch 再全判 free) 会留下 ARCH ⇒ **白漏一个编号**, 而且
            //    空闲计数与真实状态当场对不上 (单测台的账就是在这儿差的)。
            //    比较器个数没变, 只是换了枚举顺序。
            if (flush_lvl) begin
                // 冲刷: 没退休的一律回 FREE, 架构态不动
                nst[i] = (st[i] == `RTU_P_ARCH) ? `RTU_P_ARCH : `RTU_P_FREE;
            end else if ((ret_arch_vld[2] && (ret_dst_preg2 == i))) begin
                nst[i] = `RTU_P_ARCH;
            end else if ((kill_hit[2] && (ret_dst_preg2 == i)) ||
                         (ret_free_vld[2] && (ret_old_preg2 == i))) begin
                nst[i] = `RTU_P_FREE;
            end else if ((ret_arch_vld[1] && (ret_dst_preg1 == i))) begin
                nst[i] = `RTU_P_ARCH;
            end else if ((kill_hit[1] && (ret_dst_preg1 == i)) ||
                         (ret_free_vld[1] && (ret_old_preg1 == i))) begin
                nst[i] = `RTU_P_FREE;
            end else if ((ret_arch_vld[0] && (ret_dst_preg0 == i))) begin
                nst[i] = `RTU_P_ARCH;
            end else if ((kill_hit[0] && (ret_dst_preg0 == i)) ||
                         (ret_free_vld[0] && (ret_old_preg0 == i))) begin
                nst[i] = `RTU_P_FREE;
            end else if (is_wf[i] &&  hit_disp[i]) begin
                nst[i] = `RTU_P_ALLOC;          // 本拍被派出去了
            end else if (is_wf[i] && !hit_disp[i] && wf_age[i]) begin
                nst[i] = `RTU_P_FREE;           // 等满两拍都没派成 -> 回自由池
            end else if (sel_oh[i]) begin
                nst[i] = `RTU_P_WFALLOC;
            end else begin
                nst[i] = st[i];
            end
        end
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            // p0..p31 = x0..x31 的初始映射; p32..p95 = FREE
            for (i = 0; i < 32; i = i + 1) st[i] <= `RTU_P_ARCH;
            for (i = 32; i < 96; i = i + 1) st[i] <= `RTU_P_FREE;
        end else begin
            for (i = 0; i < 96; i = i + 1) st[i] <= nst[i];
        end
    end

    // -----------------------------------------------------------------------
    // WF_ALLOC 的年龄 (1 bit 够: 只区分"刚发出去那一拍"和"已经等了一拍")
    //
    // ⚠️ 这个寄存器**曾经只有声明和读取、没有任何赋值** —— 于是 `nst` 里那条
    //    "等满两拍没人认领就回 FREE" 永远不成立, 编号一旦被分配而没派成
    //    (TB/重命名级在 T+1 那拍 stall), 就一直卡在 WF_ALLOC **直到下一次冲刷**。
    //    单测台里冲刷频繁所以看不出来; 真核冲刷间隔上千拍, 自由池会被抽干
    //    (free_cnt 掉到 0 → preg_short → 派遣永久停摆)。
    //    时间线 (与 §6.0 的两拍握手对齐): 选中的那个 posedge 起 WF_ALLOC,
    //    派遣确认在紧随的那个 posedge 采样; 再往后一拍还没人认领就回收。
    // -----------------------------------------------------------------------
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) wf_age <= 96'd0;
        else
            for (i = 0; i < 96; i = i + 1)
                wf_age[i] <= sel_oh[i]                     ? 1'b0 :   // 本拍刚发出去
                             (is_wf[i] && !hit_disp[i])    ? 1'b1 :   // 等了一拍还没派成
                                                             1'b0;
    end

    // -----------------------------------------------------------------------
    // 空闲计数 (加减计数器, 不让 popcount 上路径)
    // -----------------------------------------------------------------------
    wire [95:0] do_free_wf = is_wf & ~hit_disp & wf_age;
    wire [1:0] n_cf = $countones(do_free_wf);             // 本拍放回自由池的个数 (0..3)
    // ⚠️ `kill_hit` **也要算进去**: 陷阱那条自己的 dst_preg 是 ALLOC -> FREE
    //    (它没写 rd), 漏了它每次陷阱都会让计数器少 1 —— 单测台里表现为
    //    "计数器恒低 1, 一直不回来" (踩过)。陷阱那拍 write_vld=0, 所以 kill 与
    //    arch/free 不会互相覆盖, 直接相加即可。 (最多 3+3+3 = 9, 用 4 位)
    // ⚠️ 这里用的是 `kill_hit` 而**不是** `ret_kill_vld` —— 状态转移上面门掉了
    //    ARCH, 计数必须同门 (见那段注释), 否则池子的账与状态表当场对不上。
    wire [3:0] n_freed = {3'b0, ret_free_vld[0]} + {3'b0, ret_free_vld[1]}
                       + {3'b0, ret_free_vld[2]} + {3'b0, n_cf}
                       + {3'b0, kill_hit[0]} + {3'b0, kill_hit[1]}
                       + {3'b0, kill_hit[2]};
    wire [3:0] n_alloc = {3'b0, rtu_preg_alloc_vld0} + {3'b0, rtu_preg_alloc_vld1}
                       + {3'b0, rtu_preg_alloc_vld2};

    // 冲刷后还在池子外的只有 ARCH: p0..p31 恒 ARCH (32 个), 高段里 retired 过的映射
    // 仍是 ARCH —— `st[i] == ARCH ? ARCH : FREE` 那一条把它们留下了。所以自由数
    // **不是** 64 而是 64 − (p32..p95 里 ARCH 的个数)。写死 64 会永久高报, 于是
    // `preg_short` 迟一拍才拦, 重命名级按高报的数发请求却拿不满编号 (§6.0 的承诺
    // "编号在 T+1 拍仍然有效"就破了)。
    wire [95:0] arch_vec;
    generate
        for (gv = 0; gv < 96; gv = gv + 1) begin : g_arch
            assign arch_vec[gv] = (st[gv] == `RTU_P_ARCH);
        end
    endgenerate
    // ⚠️ 只数 p32..p95。用位选而不是掩码常量: 掩码写反 (拼接是高位在前) 会去数
    //    p0..p31 —— 那 32 个恒为 ARCH, 症状是自由数恒低 30 上下, 看着像固定偏移。
    wire [6:0] arch_hi_cnt = $countones(arch_vec[95:32]);

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)          free_cnt_q <= 7'd64;
        else if (flush_lvl)   free_cnt_q <= 7'd64 - arch_hi_cnt;
        else                  free_cnt_q <= free_cnt_q + {3'b0, n_freed} - {3'b0, n_alloc};
    end

    assign free_cnt          = free_cnt_q;
    assign rtu_preg_free_cnt = (free_cnt_q >= 7'd3) ? 2'd3 : free_cnt_q[1:0];

    // -----------------------------------------------------------------------
    // AMT: 架构映射表 (32 × 7)。退休那拍的 3 个写口; 冲刷**不**动它 ——
    // 它只反映已退休的映射, 这正是"恢复靠整表覆盖"的底气 (D1/D2)。
    // -----------------------------------------------------------------------
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            for (i = 0; i < 32; i = i + 1) amt[i] <= i[6:0];
        end else begin
            // ⚠️ 优先级必须**倒过来**: 同一拍退掉的多条指令可能写同一个 lreg
            //    (`addi x8..; addi x8..` 相邻两条), 架构上最后留下的是**程序序最年轻**
            //    的那条的 dst_preg, 也就是车道 2。按 0>1>2 判会把最老的写口留下 ——
            //    单测台抓到的症状正是 `AMT[8] exp=72 got=46` (车道 1 写 46、车道 2 写 72)。
            for (i = 0; i < 32; i = i + 1) begin
                if      (ret_arch_vld[2] && (ret_dst_lreg2 == i)) amt[i] <= ret_dst_preg2;
                else if (ret_arch_vld[1] && (ret_dst_lreg1 == i)) amt[i] <= ret_dst_preg1;
                else if (ret_arch_vld[0] && (ret_dst_lreg0 == i)) amt[i] <= ret_dst_preg0;
            end
        end
    end

    generate
        for (gv = 0; gv < 32; gv = gv + 1) begin : g_amt
            assign amt_flat[7*gv +: 7] = amt[gv];
        end
    endgenerate

endmodule
