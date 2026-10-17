# ===========================================================================
# asm/rvv_lsu.S —— 向量 unit-stride load/store 的最小端到端自检 (S9)
# ===========================================================================
# 为什么"必须用向量 store 才能自检": vmv.x.s / vcpop / vfirst 是**标量目的**
#   指令, S5 的设计是在入口拦下并报 illegal trap —— 所以向量结果只能先 vse32.v
#   落内存, 再用标量 lw 读回来比较。
#
# 形态约束 (与 asm/a910_smoke.S 相同): **纯直线, 无跳转、无 call** ——
#   A910 顶层的 `idu_accept_num` 在取指流被打断时有已知丢指令的窗口。
#   自检结果累加进 x11, 最后 a0 = x11; a0 == 0 表示全对。
#
# 覆盖:
#   * vsetvli (rs1=x0, rd=x0) → VL = VLMAX = 4 (VLEN=128, e32)
#   * vle32.v  unit-stride load
#   * vadd.vx  (顺带确认向量计算通路 + 标量源)
#   * vse32.v  unit-stride store (提交后排空)
#   * 标量 sw/lw 与向量访存同地址空间的顺序
# ===========================================================================

.section .text.init
.globl _start

_start:
    # ---- 数据区: 0x1000 放 4 个初值 1,2,3,4 ----
    lui   x5, 0x1              # x5 = 0x1000
    addi  x6, x0, 1
    sw    x6, 0(x5)
    addi  x6, x0, 2
    sw    x6, 4(x5)
    addi  x6, x0, 3
    sw    x6, 8(x5)
    addi  x6, x0, 4
    sw    x6, 12(x5)

    # ---- 向量: v1 = [1,2,3,4]; v2 = v1 + 10; 存到 0x1100 ----
    addi  x6, x0, 4            # AVL=4 (rd=x0,rs1=x0 会取旧 vl=0, 不能用)
    vsetvli x0, x6, e32, m1, ta, ma
    vle32.v v1, (x5)
    addi  x7, x0, 10
    vadd.vx v2, v1, x7
    lui   x8, 0x1
    addi  x8, x8, 0x100        # x8 = 0x1100
    vse32.v v2, (x8)

    # ---- 读回比较 (期望 11,12,13,14), 差值累加进 x11 ----
    addi  x11, x0, 0

    lw    x9, 0(x8)
    addi  x10, x0, 11
    sub   x9, x9, x10
    add   x11, x11, x9

    lw    x9, 4(x8)
    addi  x10, x0, 12
    sub   x9, x9, x10
    add   x11, x11, x9

    lw    x9, 8(x8)
    addi  x10, x0, 13
    sub   x9, x9, x10
    add   x11, x11, x9

    lw    x9, 12(x8)
    addi  x10, x0, 14
    sub   x9, x9, x10
    add   x11, x11, x9

    add   x10, x0, x11         # a0 = 累加差 (0 = 全对)

    # ---- 退出序列 ----
    addi x17, x0, 93
    ecall
    unimp
