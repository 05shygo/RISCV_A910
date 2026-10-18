# ===========================================================================
# asm/rvv_partial_st.S —— 定向自检: **部分 VL / 分数 LMUL 的向量 store 不得越界**
#
# 背景 (2026-10-18, CoreMark RVV bring-up):
#   GCC 自动向量化后的 CoreMark 里有 `vsetivli 4,e16,mf2` + `vse16.v`
#   （iterate 清 CRC 字段）和 `vsetvli a5,a3,e16,m1`（矩阵循环尾块，VL<8）
#   这类**不满一个向量寄存器**的 store。rvv-sweep 的用例全是"写满 16B"，
#   没覆盖它们。全核跑 CoreMark 时第一次失配前，栈上的指针被写成了 X，
#   怀疑就是部分 VL 的 store 把寄存器未初始化的尾巴也写下去了。
#
# 本用例:
#   * canary 直接放在 .data（镜像里），避免标量 store 在 WMB 里和处理同一条
#     线 —— 第一版用 4 个 sw 预热，结果卡在 WMB merge（那是另一个问题）；
#   * 先用 4 个标量 lw 把 line 填进 dcache；
#   * v1 整个 16B 写成 0xFFFF（e16,m1, VL=8）；
#   * 再 `vsetivli 4,e16,mf2` + `vse16.v` —— 只应写 8B；
#   * 后 8B 是 canary 0xA5A5A5A5，逐字回读，差值累加进 a0。
#
#   ⇒ 若硬件把整条 16B 写下去，后两个字会变成 0xFFFFFFFF，a0 != 0。
#
# 形态约束与 a910_smoke.S 相同: 纯直线、无跳转、无 call。
# ===========================================================================

.section .data
.align 4
buf:
    .word 0xA5A5A5A5
    .word 0xA5A5A5A5
    .word 0xA5A5A5A5
    .word 0xA5A5A5A5

.section .text.init
.globl _start

_start:
    la    x5, buf                 # x5 = &buf

    # 先把 line 弄成 dcache 里的脏行，并建立"load → 地址"的数据依赖，
    # 保证向量 store 发射时 line 已经稳定在 dcache 里（否则会撞 LFB 冲突）
    li    x6, -1
    sw    x6, 0(x5)
    lw    x7, 0(x5)
    lw    x7, 4(x5)
    lw    x7, 8(x5)
    lw    x7, 12(x5)
    andi  x7, x7, 0
    add   x5, x5, x7

    # 整个 v1 = 0xFFFF (16B)
    vsetivli x0, 8, e16, m1, ta, ma
    vmv.v.i v1, -1

    # 满 VL（m1）: 写满 8 个 e16 = 16B（对照组）
    vsetivli x0, 8, e16, m1, ta, ma
    # 与 CoreMark 的 iterate 保持同样的间距：vset 之后隔若干标量指令再 store
    # （紧挨着发 store 会卡在向量配置/发射通路上，那是另一个时序问题）
    addi  x12, x0, 1
    addi  x12, x12, 1
    addi  x12, x12, 1
    addi  x12, x12, 1
    addi  x12, x12, 1
    addi  x12, x12, 1
    addi  x12, x12, 1
    addi  x12, x12, 1
    vse16.v v1, (x5)

    # ---- 回读并累加差值 ----
    lw    x6, 0(x5)
    lw    x7, 4(x5)
    lw    x8, 8(x5)
    lw    x9, 12(x5)

    li    x10, 0
    li    x11, 0xFFFFFFFF
    xor   x6, x6, x11
    add   x10, x10, x6            # 前 8B 期望全 0xFFFF
    xor   x7, x7, x11
    add   x10, x10, x7

    xor   x8, x8, x11
    add   x10, x10, x8            # 满 VL: 四个字都应是 0xFFFFFFFF
    xor   x9, x9, x11
    add   x10, x10, x9

    # ---- 退出序列 ----
    addi  x17, x0, 93
    ecall
    unimp
