`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_preg — 物理寄存器四态表 + 分配握手 + 架构映射表 AMT (D2 / D3)。
//
// 四态 (每 preg 2 bit, 共 192 bit):
//   FREE --(被 tap 选中补进"门房")--> WF_ALLOC --(派遣认领)--> ALLOC
//   ALLOC --(退休且写回)--> ARCH        ALLOC --(陷阱那条)--> FREE
//   ARCH  --(退休且 old_preg != dst_preg)--> FREE
//   冲刷: 非 ARCH 全部回 FREE (一拍并行, 每个 preg 各看各的, 不用扫描)
//
// ⚠️ **2026-10-07: 分配握手改成 C910 的"门房保持寄存器"(tap), 年龄回收删除。**
//    完整理由与验收口径见 doc/rtu_preg_alloc_plan_zh.md, 摘要在文件末尾。
//    一句话: 号与许可都进寄存器(每路一份 tap), 消费者**当拍取走**, 取走即补下一个;
//    池子在"补进 tap"那一刻就把号标成 WF_ALLOC, 之后只等派遣来认领。
//
// ⚠️ `WF_ALLOC` 不是多余的簿记: 96 位三端口优先编码器是 7 级左右的组合深度,
//    直接串在"派遣 → 分配 → 更新状态"这条链上会把派遣拍压垮 (§4.2 的 P3)。
//    C910 也是切成两拍 (`ct_rtu_pst_preg_entry.v:288-295`)。
//
// ⚠️ **2026-10-02 (D1.2): 自由池是全部 96 项, 不再钉在 p32..p95。**
//    改之前: reset 把 p0..p31 置 ARCH 且**永不回收** ⇒ 每个"搬过家"的 lreg 都
//    额外占着一个回不来的格子, 池子收敛到 33 (= 64 − ≤31 个被顶掉的初始映射)。
//    顺序核无所谓, 乱序要的就是深窗口 —— 参考核 free_list 只有 32 项却挂在 64 项
//    ROB 后面, §4 不变量 2 批评的正是这件事。
//    现在照 C910: 初始映射的那一项起在 RETIRE 态, 被顶掉就 RETIRE → RELEASE →
//    DEALLOC 回池子 (那边 `ct_rtu_pst_preg_entry.v:236` 的
//    `reset_mapped ? RETIRE : DEALLOC`)。⇒ 池子恒 64、架构项恒 32,
//    §4 不变量 4 的口径**原样成立** (探针不用改)。
//    ⚠️ 释放**判在调用方** (RTU_commit 的 `old_preg != dst_preg`), 免得观察口与
//       池子两处判得不一致 —— 就是 D2 里那条"最容易漏的一行"。
//
// 空闲计数用**加减计数器**而不是 popcount: disp_stall 要喂给前端的捕获使能,
// 而 IF_ID 捕获本来就在 500 条最差路径里 (§4.2 的 P8)。计数器只被寄存器事件驱动。
// ---------------------------------------------------------------------------
module RTU_preg (
    input  wire        cpu_clk,
    input  wire        cpu_rst,

    // ---- §6.0 分配请求 (当拍取走) ----
    input  wire [1:0]  ren_preg_req,
    input  wire [4:0]  ren_preg_req_lreg0,
    input  wire [4:0]  ren_preg_req_lreg1,
    input  wire [4:0]  ren_preg_req_lreg2,

    // ---- 派遣认领 (号走到 ROB 那一拍, 与取走相隔任意拍) ----
    input  wire [2:0]  disp_vld,
    input  wire [6:0]  disp_dst_preg0,
    input  wire [6:0]  disp_dst_preg1,
    input  wire [6:0]  disp_dst_preg2,

    // ---- 退休 ----
    input  wire [2:0]  ret_arch_vld,     // dst_preg -> ARCH (+ AMT 写)
    input  wire [2:0]  ret_kill_vld,     // 陷阱那条: 分配过但没写的 dst_preg -> FREE
    input  wire [2:0]  ret_free_vld,     // old_preg (调用方已判 != dst_preg) -> FREE
    input  wire [6:0]  ret_dst_preg0, ret_dst_preg1, ret_dst_preg2,
    input  wire [6:0]  ret_old_preg0, ret_old_preg1, ret_old_preg2,
    input  wire [4:0]  ret_dst_lreg0, ret_dst_lreg1, ret_dst_lreg2,

    // ---- 冲刷 (FLUSH_2) ----
    input  wire        flush_lvl,

    // ---- 输出 (2026-10-07 起都是**寄存值** = 门房 tap 里备着的号) ----
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
    // ---- 每路一份"门房"寄存器 (C910 `ct_rtu_pst_preg.v:7376-7393` 的 alloc_preg*) ----
    // 它备着一个已经出池(WF_ALLOC)、等着被取走的号。消费者**当拍取走**;
    // 取走(或空着)的那一拍边沿才补下一个。于是许可与编号都不依赖本拍请求
    // ⇒ 与 IDU 停顿链之间的组合环断开 (那是本次改造的首要目的)。
    reg  [6:0]  tap_num0, tap_num1, tap_num2;
    reg         tap_vld0, tap_vld1, tap_vld2;
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
    //    "一位不变"。同理, 车道 0 不补号时它的候选位**仍然**被 `~sel0_oh` 排除在
    //    外 (不把后面的选择往前挪) —— 这是 §6.0 的车道语义。改这些线的时候记住
    //    门控源是 `pop_lane` (补号) 而不是"请求": 号是**提前备好的**,
    //    与请求的相位已经解耦 (2026-10-07)。
    //    ✅ 已机器核对 (一次性 TB, 未进仓库): 随机 / 小池 / 单点 / 边界定向 +
    //       请求全扫下, 三路编号 / alloc_vld / 候选池 / sel_oh 与**原始版**
    //       (enc_lo/enc_hi 优先链 + 二进制往返) 逐位相同。
    //    ⚠️ 该等价性的前提是 `free_vec[31:0] ≡ 0` (低段全是初始映射、没被顶掉过)。
    //       改前的版本靠 `PREG_HI_MSK` 把低段**结构上**挡在窗口外; D1.2 之后窗口是
    //       整个 [0,95], 前提回到"阶段 1 的低段恒 ARCH"这条不变量上 —— 由整核探针
    //       (`tb/tb_miniRV_dpi.sv` 的 "ARCH 项数 == 32") 与逐位等价 TB 守着。
    // -----------------------------------------------------------------------

    // 独热 → 7 位编号的**位掩码**: BM{k} 里为 1 的那些位 = "编号的第 k 位是 1" 的
    // preg。于是 `|(sel_oh & BM{k})` 就是答案的第 k 位 —— 7 个 AND-OR, 既没有优先
    // 逻辑, 也不用把编号切来切去。
    // ⚠️ 2026-10-02 (D1.2): 窗口从 p32..p95 扩到**全 96 项**, 于是图案从"以 p32 为
    //    最低位的 64 位周期"变回"以 p0 为最低位的 96 位周期": 低 32 位不再是 0。
    //    高 64 位与改前**逐位相同** (32 是 2/4/8/16/32 的公倍数, 周期图案在窗口里
    //    对齐) —— 这正是"阶段 1 一位不变"的一半理由; 另一半是低段恒 ARCH ⇒
    //    `sel_oh` 落不进低段。
    //      位0 周期2 / 位1 周期4 / 位2 周期8 / 位3 周期16 / 位4 周期32 /
    //      位5 = p32..p63 (全表里唯一一段 bit5=1 的) / 位6 = p64..p95。
    localparam [95:0] PREG_BM0 = 96'hAAAA_AAAA_AAAA_AAAA_AAAA_AAAA;
    localparam [95:0] PREG_BM1 = 96'hCCCC_CCCC_CCCC_CCCC_CCCC_CCCC;
    localparam [95:0] PREG_BM2 = 96'hF0F0_F0F0_F0F0_F0F0_F0F0_F0F0;
    localparam [95:0] PREG_BM3 = 96'hFF00_FF00_FF00_FF00_FF00_FF00;
    localparam [95:0] PREG_BM4 = 96'hFFFF_0000_FFFF_0000_FFFF_0000;
    localparam [95:0] PREG_BM5 = 96'h0000_0000_FFFF_FFFF_0000_0000;
    localparam [95:0] PREG_BM6 = 96'hFFFF_FFFF_0000_0000_0000_0000;

    wire [95:0] free_vec;
    genvar      gv;
    generate
        for (gv = 0; gv < 96; gv = gv + 1) begin : g_free
            assign free_vec[gv] = (st[gv] == `RTU_P_FREE);
        end
    endgenerate

    // 本路本拍被**取走**: 消费者请求了这一路, 且 dst 不是 x0 (x0 不分配、不映射)。
    // "请求即取走" 是 C910 的语义 —— 它那边 alloc_vld、RAT 写、进 IS 由同一个
    // `!ctrl_ir_stall` 门控, 三者同拍 (`ct_idu_ir_ctrl.sv:259` / `ct_idu_ir_dp.sv:283`)。
    wire [2:0] take_lane;
    assign take_lane[0] = (ren_preg_req > 2'd0) && (ren_preg_req_lreg0 != 5'd0);
    assign take_lane[1] = (ren_preg_req > 2'd1) && (ren_preg_req_lreg1 != 5'd0);
    assign take_lane[2] = (ren_preg_req > 2'd2) && (ren_preg_req_lreg2 != 5'd0);

    // 本路备着的那个号**本拍被派遣认领** —— 兜"没请求却把它派出去了"那种误用。
    // 有它, 误用只会让本路提前补号, 不会把同一个号发两次 (静默撞号是大忌)。
    // ⚠️ 必须门 `tap_vld`: 空 tap 的残值 0 会被 dst_preg=0 的 x0 车道蹭中。
    wire tap_hit0 = tap_vld0 && ((disp_vld[0] && (disp_dst_preg0 == tap_num0))
                              || (disp_vld[1] && (disp_dst_preg1 == tap_num0))
                              || (disp_vld[2] && (disp_dst_preg2 == tap_num0)));
    wire tap_hit1 = tap_vld1 && ((disp_vld[0] && (disp_dst_preg0 == tap_num1))
                              || (disp_vld[1] && (disp_dst_preg1 == tap_num1))
                              || (disp_vld[2] && (disp_dst_preg2 == tap_num1)));
    wire tap_hit2 = tap_vld2 && ((disp_vld[0] && (disp_dst_preg0 == tap_num2))
                              || (disp_vld[1] && (disp_dst_preg1 == tap_num2))
                              || (disp_vld[2] && (disp_dst_preg2 == tap_num2)));

    // 本拍要给哪几路**补号** (= 从这个边沿起, 把选中的 FREE 装进门房)。
    // 池子的 WF_ALLOC 标记跟着它走, 不再跟着"本拍请求"走 —— 号一进 tap 就出池了。
    wire [2:0] pop_lane;
    assign pop_lane[0] = !tap_vld0 | take_lane[0] | tap_hit0;
    assign pop_lane[1] = !tap_vld1 | take_lane[1] | tap_hit1;
    assign pop_lane[2] = !tap_vld2 | take_lane[2] | tap_hit2;

    // 可分配池 = 全表里处于 FREE 的那些。
    // ⚠️ 2026-10-02 (D1.2): 窗口是**全部 96 项**, 不再是 p32..p95 —— 初始映射被顶掉
    //    之后也回池子、位置随改名漂移, 低段不是"只属于 x0..x31"的保留区了。
    //    (改前这里是 `free_vec & PREG_HI_MSK`, 靠掩码把低段**结构上**挡在窗口外;
    //     现在那条保证改由"阶段 1 低段恒 ARCH"这条不变量提供: free_vec[31:0] ≡ 0
    //     ⇒ 本式与掩过时逐位相同。)
    wire [95:0] free_pool = free_vec;

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
    // ⚠️ 两棵树都在**全 96 位**上翻 (D1.2 之后窗口就是全表): 低树左移会从右端
    //    移入 0、高树右移会从左端移入 0, 于是"边界之外没有空闲"这件事由移位自带,
    //    不需要掩码。改前低段是保留区、必须靠 `PREG_HI_MSK` 兜; 现在不用了。
    // -----------------------------------------------------------------------
    wire [95:0] fu1  = free_pool >> 1;
    wire [95:0] fu2  = fu1  | (fu1  >> 1);
    wire [95:0] fu4  = fu2  | (fu2  >> 2);
    wire [95:0] fu8  = fu4  | (fu4  >> 4);
    wire [95:0] fu16 = fu8  | (fu8  >> 8);
    wire [95:0] fu32 = fu16 | (fu16 >> 16);
    wire [95:0] fu64 = fu32 | (fu32 >> 32);

    wire [95:0] fd1  = free_pool << 1;
    wire [95:0] fd2  = fd1  | (fd1  << 1);
    wire [95:0] fd4  = fd2  | (fd2  << 2);
    wire [95:0] fd8  = fd4  | (fd4  << 4);
    wire [95:0] fd16 = fd8  | (fd8  << 8);
    wire [95:0] fd32 = fd16 | (fd16 << 16);
    wire [95:0] fd64 = fd32 | (fd32 << 32);

    // ⚠️ 第 0/1 路的掩码在**末端**, 不在第 1 路的扫描输入上 —— 两条扫描并行
    //    (ARM `enyo_is_vxq_free_list.sv:349` 的写法)。见上面 ① 的长注。
    //    一位独热 = 自己 & ~(自己上方/下方有别人)。
    wire [95:0] sel0_oh = free_pool & ~fu64;                // 最高
    wire [95:0] sel1_oh = (free_pool & ~fd64) & ~sel0_oh;   // 最低 —— 与 sel0 并行
    wire [95:0] v1      = free_pool & ~sel0_oh;

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
    wire [95:0] cand0 = free_pool;
    wire [95:0] cand1 = v1;
    wire [95:0] cand2 = v2;

    // ⚠️ 每一路都必须**同时**用 `|candK` 门控, 三处 (g_selK / 装进门房 / 计数器的
    //    n_alloc) 逐位同式 —— 少一处就是"看着发出去了、账上没记"那类慢慢偏的 bug。
    //    旧实现里这条门控还兼着挡一个坑: `1<<sel` 在"没找到"时是 bit 0, 于是池子
    //    不够三路时第 2/3 路会把 **p0 置成 WF_ALLOC**, x0 的映射就没了。
    //    改成独热后 `sel*_oh` 找不到就是 0, 那个坑**结构上消失**了 —— 但门控本身
    //    仍要留: 它守的是"这一路真拿到了号"这个定义本身, 与编码形式无关。
    //    ⚠️ 2026-10-07: 门控源从 `req_lane` 换成 `pop_lane` —— 号**装进门房那一刻**
    //       就出池 (标 WF_ALLOC), 而不是"被请求那一刻"。
    wire [95:0] g_sel0 = sel0_oh & {96{pop_lane[0] & (|cand0)}};
    wire [95:0] g_sel1 = sel1_oh & {96{pop_lane[1] & (|cand1)}};
    wire [95:0] g_sel2 = sel2_oh & {96{pop_lane[2] & (|cand2)}};
    wire [95:0] sel_oh = g_sel0 | g_sel1 | g_sel2;

    // 独热 -> 7 位编号: 第 k 位 = "选中的那一位, 它的编号第 k 位是 1" (见 PREG_BM*)。
    // 一个都没选中时 7 位全 0, 与历次实现一致。这是"这一拍要装进门房的号"。
    wire [6:0] pop_num0 = { |(g_sel0 & PREG_BM6), |(g_sel0 & PREG_BM5),
                            |(g_sel0 & PREG_BM4), |(g_sel0 & PREG_BM3),
                            |(g_sel0 & PREG_BM2), |(g_sel0 & PREG_BM1),
                            |(g_sel0 & PREG_BM0) };
    wire [6:0] pop_num1 = { |(g_sel1 & PREG_BM6), |(g_sel1 & PREG_BM5),
                            |(g_sel1 & PREG_BM4), |(g_sel1 & PREG_BM3),
                            |(g_sel1 & PREG_BM2), |(g_sel1 & PREG_BM1),
                            |(g_sel1 & PREG_BM0) };
    wire [6:0] pop_num2 = { |(g_sel2 & PREG_BM6), |(g_sel2 & PREG_BM5),
                            |(g_sel2 & PREG_BM4), |(g_sel2 & PREG_BM3),
                            |(g_sel2 & PREG_BM2), |(g_sel2 & PREG_BM1),
                            |(g_sel2 & PREG_BM0) };

    // 出端口的是**门房寄存器的内容**, 不是本拍选出来的那个 —— 这一行就是"断环"本身:
    // `rtu_preg_alloc*` / `_vld*` 与 `ren_preg_req` 之间不再有组合路径。
    assign rtu_preg_alloc0     = tap_num0;
    assign rtu_preg_alloc1     = tap_num1;
    assign rtu_preg_alloc2     = tap_num2;
    assign rtu_preg_alloc_vld0 = tap_vld0;
    assign rtu_preg_alloc_vld1 = tap_vld1;
    assign rtu_preg_alloc_vld2 = tap_vld2;

    // -----------------------------------------------------------------------
    // 派遣认领 (号走到 ROB 那一拍 —— 与"取走"相隔几拍**不定**, 见文件末尾长注)
    //
    // 口径: **按"这个编号当前是不是 WF_ALLOC 态"判**, 而不是去比"某一拍发出去的
    // 那个值"。两者在合法协议下等价 (WF_ALLOC 恰好就是已经备出去、还没落定的
    // 那一批), 但按状态判**与相位无关** —— 派遣早半拍/晚几拍都能认领上。
    // 这正是 2026-10-07 删掉年龄回收的前提: 认领不依赖"多久之前发的"。
    // 踩过的坑: 早先按 pend 值比较, TB 侧相位对不齐时 DUT 会静默地把
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

    // ⚠️ 2026-10-07: 这两根是**观察口**, 没有任何消费者 —— 别把它当"回收路径"。
    //    年龄回收已删 (§文件末尾), 号只由派遣认领或被冲刷清掉两条路。
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
    // `96 − 全表 ARCH` 重算、状态表却不复原 —— 阶段 2 一开真重命名就两边对不上。
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
                nst[i] = `RTU_P_ALLOC;          // 本拍被派出去了 (承下门房备着的号)
            end else if (sel_oh[i]) begin
                nst[i] = `RTU_P_WFALLOC;
            end else begin
                nst[i] = st[i];
            end
        end
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            // p0..p31 = x0..x31 的初始映射 (D1.2 之后它们**可被回收**: 谁被顶掉谁
            // 回池子, 位置随改名漂移); p32..p95 = FREE。
            // 对照 C910 `ct_rtu_pst_preg_entry.v:236`: `reset_mapped ? RETIRE : DEALLOC`。
            for (i = 0; i < 32; i = i + 1) st[i] <= `RTU_P_ARCH;
            for (i = 32; i < 96; i = i + 1) st[i] <= `RTU_P_FREE;
        end else begin
            for (i = 0; i < 96; i = i + 1) st[i] <= nst[i];
        end
    end

    // -----------------------------------------------------------------------
    // 门房 (tap) 更新 —— 本次改造的核心 (C910 `ct_rtu_pst_preg.v:7376-7393`)
    //
    //   * 只在 `pop_lane[k]` 时从池子选一个新号装进来; 选不到 (池子空) 就 vld=0;
    //   * 不 pop 就**保持** —— 号一直备在门口, 谁要谁拿, 拿的早晚都不影响;
    //   * 冲刷清空。必须清: 冲刷把池子里非 ARCH 的全部置 FREE, 门房里那个号
    //     已经不在池子里了, 留着就是"备着一个池子认为空闲的号" (会被再选一次)。
    //   * `pop_lane` 里为什么要有 `!tap_vld`: 空门房必须立刻补上, 否则消费者
    //     要等下一拍才看得到 vld=1, 白白多停一拍。
    //   * 为什么要有 `take_lane`: 号被取走了就得给下一个备一个新的 —— 否则门房
    //     一直举着旧号, 下一个消费者拿到的还是它 (同一个号发两次)。
    // -----------------------------------------------------------------------
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            tap_vld0 <= 1'b0; tap_num0 <= 7'd0;
            tap_vld1 <= 1'b0; tap_num1 <= 7'd0;
            tap_vld2 <= 1'b0; tap_num2 <= 7'd0;
        end else if (flush_lvl) begin
            tap_vld0 <= 1'b0; tap_num0 <= 7'd0;
            tap_vld1 <= 1'b0; tap_num1 <= 7'd0;
            tap_vld2 <= 1'b0; tap_num2 <= 7'd0;
        end else begin
            if (pop_lane[0]) begin tap_vld0 <= (|g_sel0); tap_num0 <= pop_num0; end
            if (pop_lane[1]) begin tap_vld1 <= (|g_sel1); tap_num1 <= pop_num1; end
            if (pop_lane[2]) begin tap_vld2 <= (|g_sel2); tap_num2 <= pop_num2; end
        end
    end

    // -----------------------------------------------------------------------
    // 空闲计数 (加减计数器, 不让 popcount 上路径)
    // -----------------------------------------------------------------------
    // ⚠️ `kill_hit` **也要算进去**: 陷阱那条自己的 dst_preg 是 ALLOC -> FREE
    //    (它没写 rd), 漏了它每次陷阱都会让计数器少 1 —— 单测台里表现为
    //    "计数器恒低 1, 一直不回来" (踩过)。陷阱那拍 write_vld=0, 所以 kill 与
    //    arch/free 不会互相覆盖, 直接相加即可。 (最多 3+3+3 = 9, 用 4 位)
    // ⚠️ 这里用的是 `kill_hit` 而**不是** `ret_kill_vld` —— 状态转移上面门掉了
    //    ARCH, 计数必须同门 (见那段注释), 否则池子的账与状态表当场对不上。
    // ⚠️ 2026-10-07: 去掉了"年龄回收"那一项 (n_cf) —— 号不再按年龄回收。
    wire [3:0] n_freed = {3'b0, ret_free_vld[0]} + {3'b0, ret_free_vld[1]}
                       + {3'b0, ret_free_vld[2]}
                       + {3'b0, kill_hit[0]} + {3'b0, kill_hit[1]}
                       + {3'b0, kill_hit[2]};
    // ⚠️ 数的必须是**出池的次数** (= 装进门房的次数), 不是"本拍请求了几路" ——
    //    号在装进 tap 那一刻就出池, 与请求的相位解耦。少记一次计数器就永久高报。
    wire [3:0] n_alloc = {3'b0, (|g_sel0)} + {3'b0, (|g_sel1)} + {3'b0, (|g_sel2)};

    // 冲刷后还在池子外的只有 ARCH: 初始映射那 32 项、以及任何 retired 过的映射 ——
    // `st[i] == ARCH ? ARCH : FREE` 那一条把它们留下了。所以自由数**不是** 96 而是
    // `96 − 全表 ARCH 数`。写死 96 会永久高报, 于是消费者按高报的数发请求却拿不满编号。
    // ⚠️ 2026-10-07: 除 ARCH 外, 门房备着的那 ≤3 个号也不在 FREE 里 ⇒ free_cnt 比
    //    "还能发出去多少"少 ≤3。这是"提前备号"的固有代价 (C910 同样), 不是漏记。
    wire [95:0] arch_vec;
    generate
        for (gv = 0; gv < 96; gv = gv + 1) begin : g_arch
            assign arch_vec[gv] = (st[gv] == `RTU_P_ARCH);
        end
    endgenerate
    // ⚠️ 数**全表** 96 项 (D1.2)。改前这里是 `arch_vec[95:32]` 配常量 64 —— 那套写法
    //    把"p0..p31 恒 ARCH"当成了结构事实; 现在初始映射会被顶掉, 不成立了。
    //    阶段 1 里两者逐位同值: 低 32 项恒 ARCH ⇒ `96 − (32 + 高段)` == `64 − 高段`。
    wire [6:0] arch_cnt = $countones(arch_vec);

    always @(posedge cpu_clk or posedge cpu_rst) begin
        // ⚠️ 复位值必须是**常数** 64 (= 96 − 32 项初始映射): 那一拍 st[] 在真实
        //    上电时是 X, `96 − arch_cnt` 会算出 X 并永久留在计数器里。
        if (cpu_rst)          free_cnt_q <= 7'd64;
        else if (flush_lvl)   free_cnt_q <= 7'd96 - arch_cnt;
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

    // =======================================================================
    // 分配握手 —— 为什么是"门房保持寄存器" (2026-10-07 改造, 完整版见
    // doc/rtu_preg_alloc_plan_zh.md)
    //
    // 【改之前是什么】`rtu_preg_alloc*` / `_vld*` 是**本拍请求的组合函数**
    //   (`alloc_vld = req_lane & |cand`)。配 §6.0 那句"T 拍你要、T+1 拍你用"时
    //   自洽 —— 但我们自己的重命名级**根本还不存在**, 真正的消费者是 C910 IDU,
    //   而它把 `rtu_idu_alloc_preg*_vld` 当**同拍许可**用, 并且反馈进它自己的
    //   停顿链 (`ct_idu_ir_ctrl.sv:246-259`) ⇒
    //        请求 → 我们的组合 vld → IDU 停顿 → 请求        **组合环**
    //   C910 那侧没有这个环, 因为它的 alloc 寄存器**是寄存器**
    //   (`ct_rtu_pst_preg.v:7376-7393`), vld 只依赖上一拍的池子状态。
    //
    // 【改之后是什么】每路一个 tap (号 + vld 都是寄存器):
    //        池子 --(pop_lane)--> tap --> 消费者**当拍取走** --> 取走即补下一个
    //   * 取走 = `take_lane` (消费者请求了这一路), 与 C910 的"请求即取走"同义;
    //   * 池子在**装进 tap 那一刻**把号标 WF_ALLOC, 之后只等派遣认领;
    //   * 许可与编号都不再依赖本拍请求 ⇒ 环断开 (这也让 96 位优先编码器
    //     从"跨模块回到 IDU 的 RAT 写口"变成"到本模块的 tap 寄存器")。
    //
    // 【为什么把"年龄回收"删了】原来有一条 `WF_ALLOC 等满两拍没人认领 → FREE`。
    //   它的存在前提是"给了号就一定会在一两拍内被派遣" —— C910 模型下不成立:
    //   号在 IDU 的 IR 级被吃进 RAT 之后, 要经 IR → IS → IS 派发 才到 ROB,
    //   中间被 IQ 满 / ROB 满卡住是**任意多拍**。按年龄回收就会在指令还攥着它的
    //   时候把号放回池子 → 再发给别人 → 两条指令共用一个 preg, **静默错**, 不报错。
    //   删掉之后号的出路只有两条: 派遣认领 (WF_ALLOC→ALLOC) 与冲刷 (→FREE)。
    //   ⚠️ 代价: "消费者请求了却不派遣、也不冲刷"会**永久漏**一个号, 本模块
    //      没有任何办法发现 (C910 靠"请求、RAT 写、进 IS 同一个 !ctrl_ir_stall
    //      门控"从契约上排除这种情形)。这条是契约, 不是机制 —— 见 §6.0。
    //   ⚠️ R02 那条变异 (冲刷不许把分配过的号留着) 现在是**唯一**的兜底出口,
    //      比以前更承重。
    //
    // 【没验证到的】环的消失本身测不出来 (单元台与整核都看不见"组合环");
    //   能测的只有"池子非空 ⇒ 三路 vld 全 1"这条**行为**不变量 (单测台里叫
    //   "备号"检查, 变异 R08 拿它当锚)。tap_hit 那条兜底没有激励。
    // =======================================================================

endmodule
