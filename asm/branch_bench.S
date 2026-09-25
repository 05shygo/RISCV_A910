# =============================================================================
# asm/branch_bench.S —— 分支预测 / L0 BTB 定向基准
#
# 为什么需要它: 现有小用例的统计量被 IFU 初始化 (约 1027 拍) 淹没
# (beq 全程仅 1509 拍, 其中 1027 拍是初始化), 无法用来评估预测质量;
# CoreMark 只能看总量, 分不出"哪一类分支"在变好/变差.
#
# 本基准把四类可判定场景放进四个互不重叠的 PC 区间, TB 按 pc_EX 分桶统计,
# 就能定向验证 P0 的语义改动 (弱→强才武装 / 弱 taken 降级 / not-taken 不再分配).
#
# ---- PC 布局 (TB 侧 tb_miniRV_dpi.sv 的 bench_class() 必须与此一致) ----
#   class 0  [0x000,0x100) + [0x290,...)  外层循环/初始化/退出 —— 不参与分类
#   class 1  [0x100,0x140)  ① 稳定 taken 的循环回边 (3 条, 16 字节间隔)
#   class 2  [0x140,0x1C0)  ② 几乎不跳的前向分支 (8 条, 16 字节间隔, 恒不跳)
#   class 3  [0x1C0,0x250)  ③ 交替 taken/not-taken (8 条, 16 字节间隔)
#   class 4  [0x250,0x290)  ④ 函数调用/返回 (4 个调用点 + 2 个被调函数)
#   class 5  [0x290,0x320)  ⑤ 偏 taken 的 T,T,T,N 节奏 (8 条) —— 专门产出
#                              "BHT 用弱计数器(10)预测 taken" 的事件, 也就是
#                              P0-1 (只有强 taken 才武装) 与 P0-2 (弱 taken 降级)
#                              唯一会改行为的那个事件类。纯交替(类3)落在哪个
#                              双稳盆地取决于冷启动, 实测落在"恒预测不跳"，
#                              产不出弱 taken, 所以单列一类。
#
# ---- 为什么 16 字节间隔 ----
# BHT 的预测阵列由 GHR 哈希索引, 选择阵列索引取 PC[9:3] (rv32_ifu_bht.v:456
# `bht_sel_array_index[6:0] = pcgen_bht_pcindex[9:3]`, 而 pcgen_bht_pcindex =
# pc_bus[13:4])。16 字节间隔让每条静态分支的 PC[13:4] 与 PC[9:3] 都不同,
# 避免两条分支互相踩同一个 BHT 表项 —— 否则"类内 8 条分支共用 1 个 2 位计数器",
# 测到的就不是单条分支的历史了。
#
# ---- 运行长度 ----
# 外层 512 轮; 每轮约 200~300 拍 (含分支惩罚与填充 nop), 合计约 10~15 万拍,
# IFU 初始化的 1027 拍占比 < 1% (要求 < 2%, 总长 ≥ 5 万拍)。
#
# 退出约定沿用其它 asm 用例: a0 = 0 成功 / 1 失败, a7 = 93, ecall。
# =============================================================================

    .section .text.init
    .globl _start

# -----------------------------------------------------------------------------
# class 0: 初始化 + 外层循环
# -----------------------------------------------------------------------------
_start:
    jal  x0, reset_vector           # 0x000

    .org 0x008
reset_vector:
    addi x31, x0, 512               # 外层迭代次数
    addi x6,  x0, 1                 # class2 的比较操作数 (恒 > 0 ⇒ 分支恒不跳)
    addi x8,  x0, 1                 # class2 第二个比较操作数
    addi x9,  x0, 0                 # class3 的交替位 (每轮翻转一次)
    addi x10, x0, 0                 # class3 taken 路径的累加器
    addi x20, x0, 0                 # f4a 被调用次数
    addi x21, x0, 0                 # f4b 被调用次数
    addi x27, x0, 3                 # class5 的"不跳"阈值
    addi x29, x0, 0                 # class5 的相位寄存器
    addi x30, x0, 0                 # class5 的轮次计数
    jal  x0, class1                 # 0x02C → 进入被测区

    # 0x028..0x0FF 不会被取到 (上面这条 jal 直接跳过), 留空即可。

# -----------------------------------------------------------------------------
# class 1 [0x100,0x140): 稳定 taken 的循环回边
#   三个内层循环, 回边分别 taken 48/16/24 次后才不跳 ⇒ 单条静态分支的 taken
#   比例 98%/94%/96%, BHT 计数器会饱和到强 taken, L0 项应当被武装并保持。
# -----------------------------------------------------------------------------
    .org 0x100
class1:
    addi x5,  x0, 48                # 0x100
c1a:
    addi x5,  x5, -1                # 0x104
    bne  x5,  x0, c1a               # 0x108   回边 #1
    nop                             # 0x10C
    addi x28, x0, 16                # 0x110
c1c:
    addi x28, x28, -1               # 0x114
    bne  x28, x0, c1c               # 0x118   回边 #2
    nop                             # 0x11C
    addi x7,  x0, 24                # 0x120
c1b:
    addi x7,  x7, -1                # 0x124
    bne  x7,  x0, c1b               # 0x128   回边 #3
    nop                             # 0x12C
    nop                             # 0x130
    nop                             # 0x134
    nop                             # 0x138
    nop                             # 0x13C

# -----------------------------------------------------------------------------
# class 2 [0x140,0x1C0): 几乎不跳的前向分支
#   8 条条件分支, 条件恒为假 (x6 = x8 = 1, 所有比较都取反), 全部前向指向
#   c2_land。这是 P0-3 (alloc_vld &= update_taken) 的直接靶子: 改动前它们会
#   以 cnt=0 进表 (永远不可能命中, 只挤掉有用项), 改动后不应再分配。
#   取极限"恒不跳"而不是"少跳", 是因为 P0-3 的资格位正好就是 update_taken。
# -----------------------------------------------------------------------------
    .org 0x140
class2:
    blt  x6,  x0, c2_land           # 0x140  1 < 0   假
    nop
    nop
    nop
    bge  x0,  x6, c2_land           # 0x150  0 >= 1  假
    nop
    nop
    nop
    bgeu x0,  x6, c2_land           # 0x160  0 >=u 1 假
    nop
    nop
    nop
    bltu x6,  x0, c2_land           # 0x170  1 <u 0  假
    nop
    nop
    nop
    beq  x8,  x0, c2_land           # 0x180  1 == 0  假
    nop
    nop
    nop
    blt  x8,  x0, c2_land           # 0x190  1 < 0   假
    nop
    nop
    nop
    bltu x8,  x0, c2_land           # 0x1A0  1 <u 0  假
    nop
    nop
    nop
    bne  x6,  x6, c2_land           # 0x1B0  恒假
    nop
    nop
c2_land:                            # 0x1BC
    nop

# -----------------------------------------------------------------------------
# class 3 [0x1C0,0x250): 交替 taken/not-taken (2 位计数器的最坏情况)
#   x9 每轮翻转一次, 8 条分支全部测 `beq x9, x0` ⇒ 每条静态分支的序列都是
#   taken, not-taken, taken, ... 交替。这正是 P0-1 (只有强 taken 才武装) 与
#   P0-2 (弱 taken 就降级) 的靶子: 交替会把 2 位计数器困在弱 taken 附近。
# -----------------------------------------------------------------------------
    .org 0x1C0
class3:
    xori x9,  x9, 1                 # 0x1C0  每轮翻转一次 (各条分支同相位)
    nop                             # 0x1C4
    nop                             # 0x1C8
    nop                             # 0x1CC
    beq  x9,  x0, c3a0              # 0x1D0
    addi x10, x10, 1                # 0x1D4
c3a0:
    nop                             # 0x1D8
    nop                             # 0x1DC
    beq  x9,  x0, c3a1              # 0x1E0
    addi x10, x10, 1                # 0x1E4
c3a1:
    nop                             # 0x1E8
    nop                             # 0x1EC
    beq  x9,  x0, c3a2              # 0x1F0
    addi x10, x10, 1                # 0x1F4
c3a2:
    nop                             # 0x1F8
    nop                             # 0x1FC
    beq  x9,  x0, c3a3              # 0x200
    addi x10, x10, 1                # 0x204
c3a3:
    nop                             # 0x208
    nop                             # 0x20C
    beq  x9,  x0, c3a4              # 0x210
    addi x10, x10, 1                # 0x214
c3a4:
    nop                             # 0x218
    nop                             # 0x21C
    beq  x9,  x0, c3a5              # 0x220
    addi x10, x10, 1                # 0x224
c3a5:
    nop                             # 0x228
    nop                             # 0x22C
    beq  x9,  x0, c3a6              # 0x230
    addi x10, x10, 1                # 0x234
c3a6:
    nop                             # 0x238
    nop                             # 0x23C
    beq  x9,  x0, c3a7              # 0x240
    addi x10, x10, 1                # 0x244
c3a7:
    nop                             # 0x248
    nop                             # 0x24C

# -----------------------------------------------------------------------------
# class 4 [0x250,0x290): 函数调用/返回 (考 RAS + L0 target)
#   4 个互不相同的调用点调用 2 个函数, 因此同一函数的 4 次调用会返回 4 个
#   不同地址 —— 只有 RAS 正确才活得下来; L0/BTB 也要为每条 jal/jalr 存对目标。
# -----------------------------------------------------------------------------
    .org 0x250
class4:
    jal  x1, f4a                    # 0x250  调用点 A1
    jal  x1, f4b                    # 0x254  调用点 B1
    jal  x1, f4a                    # 0x258  调用点 A2
    jal  x1, f4b                    # 0x25C  调用点 B2
    jal  x0, c4_done                # 0x260  跳过被调函数体
    nop                             # 0x264
    nop                             # 0x268
    nop                             # 0x26C
f4a:                                # 0x270
    addi x20, x20, 1                # 0x270
    ret                             # 0x274
    nop                             # 0x278
    nop                             # 0x27C
f4b:                                # 0x280
    addi x21, x21, 1                # 0x280
    ret                             # 0x284
    nop                             # 0x288
c4_done:                            # 0x28C
    nop                             # 0x28C

# -----------------------------------------------------------------------------
# class 5 [0x290,0x320): 偏 taken 的 T,T,T,N 节奏 —— 专门造"弱 taken 预测"
#   x30 每轮 +1, x29 = x30 & 3; 每条分支 x29 != 3 时前向跳 (跳 1 条指令)。
#   稳态下每条静态分支的结局序列是 T,T,T,N —— 2 位饱和计数器会停在 11,
#   每次 N 把它压到 10 (弱 taken), 下一个 T 就是"用弱计数器预测 taken"。
#   这正是 C910 `l0_btb_counter_zero` (只有强 taken 2'b11 才武装) 与
#   `l0_btb_not_saturate` (弱 taken 2'b10 就降级删项) 唯一有分歧的事件类,
#   所以是 P0-1 / P0-2 的靶子。稳态准确率 75% (每 4 次错 1 次)。
# -----------------------------------------------------------------------------
    .org 0x290
class5:
    addi x30, x30, 1                # 0x290
    andi x29, x30, 3                # 0x294
    nop                             # 0x298
    nop                             # 0x29C
    bne  x29, x27, c5a0             # 0x2A0  taken 3/4
    addi x10, x10, 1                # 0x2A4
c5a0:
    nop                             # 0x2A8
    nop                             # 0x2AC
    bne  x29, x27, c5a1             # 0x2B0
    addi x10, x10, 1                # 0x2B4
c5a1:
    nop                             # 0x2B8
    nop                             # 0x2BC
    bne  x29, x27, c5a2             # 0x2C0
    addi x10, x10, 1                # 0x2C4
c5a2:
    nop                             # 0x2C8
    nop                             # 0x2CC
    bne  x29, x27, c5a3             # 0x2D0
    addi x10, x10, 1                # 0x2D4
c5a3:
    nop                             # 0x2D8
    nop                             # 0x2DC
    bne  x29, x27, c5a4             # 0x2E0
    addi x10, x10, 1                # 0x2E4
c5a4:
    nop                             # 0x2E8
    nop                             # 0x2EC
    bne  x29, x27, c5a5             # 0x2F0
    addi x10, x10, 1                # 0x2F4
c5a5:
    nop                             # 0x2F8
    nop                             # 0x2FC
    bne  x29, x27, c5a6             # 0x300
    addi x10, x10, 1                # 0x304
c5a6:
    nop                             # 0x308
    nop                             # 0x30C
    bne  x29, x27, c5a7             # 0x310
    addi x10, x10, 1                # 0x314
c5a7:
    nop                             # 0x318
    nop                             # 0x31C

# -----------------------------------------------------------------------------
# class 0: 外层循环控制 + 自检 + 退出
# -----------------------------------------------------------------------------
    .org 0x320
loop_ctrl:
    addi x31, x31, -1               # 0x320
    bne  x31, x0, class1            # 0x324  外层回边 (不计入任何类)

    # 自检: class4 里每个被调函数每轮各被调用 2 次
    addi x22, x0, 1024              # 512 轮 × 2 次
    bne  x20, x22, bench_fail
    bne  x21, x22, bench_fail
    addi x10, x0, 0                 # a0 = 0 (成功)
    jal  x0, bench_end

bench_fail:
    addi x10, x0, 1                 # a0 = 1 (失败)

bench_end:
    addi x17, x0, 93                # a7 = 93 (exit syscall)
    ecall
    unimp
