# ===========================================================================
# muldiv_edge.S — RV32M 乘除法重构后的定向用例 (doc §8.1 那张表)
#
# 走两条判据:
#   1. difftest: 每条退休指令的 rd/数据都与黄金模型逐条比对 —— 只要有一条
#      乘除法算错、或者在飞的乘法被冲刷后仍写回, 立刻在这里炸;
#   2. 显式自检: 每条结果与期望值比, 不等就把编号写进 a0 退出。
#
# a0 = 0 退出 = 通过; 非 0 = 失败点的编号 (见下面 li x30, <编号>)。
#
# 覆盖:
#   A 乘法边界 (0 / 1 / -1 / INT_MIN / 全 1)
#   B MULH / MULHSU / MULHU 的高 32 位与符号 (含最容易错的 0x80000000 组)
#   C 除法特殊值 (四种除零行为不同 / INT_MIN÷-1 / x÷1 / 0÷x)
#   D 余数与商的符号
#   E 依赖距离 0/1/2/3 (乘法结果被紧跟的指令用)
#   F 写同一个 rd (WAW)
#   G 在飞冲刷: 乘法在 MEM 时正好分支误预测; 以及错误路径上的乘法不得写回
#   H 除法与紧随消费者的配合 (除法占住 EX, 结果靠转发)
# ===========================================================================
.section .text.init
.globl _start

_start:
    jal x0, reset_vector

# reg != imm 时: x30 = 编号, 跳到 fail
.macro CHECK reg, imm, id
    li   x31, \imm
    beq  \reg, x31, 9f
    li   x30, \id
    j    fail
9:
.endm

reset_vector:
    # ---------------- A. 乘法边界 ----------------
    li   x1, 0
    li   x2, 0x12345678
    mul  x3, x1, x2          # 0 * x = 0
    CHECK x3, 0, 1

    li   x1, 1
    mul  x3, x1, x2          # 1 * x = x
    CHECK x3, 0x12345678, 2

    li   x1, -1
    mul  x3, x1, x2          # -1 * x = -x
    CHECK x3, 0xEDCBA988, 3

    li   x1, 0x80000000
    li   x2, -1
    mul  x3, x1, x2          # INT_MIN * -1: 低 32 位回绕仍是 0x80000000
    CHECK x3, 0x80000000, 4

    li   x1, 0xFFFFFFFF
    li   x2, 0xFFFFFFFF
    mul  x3, x1, x2          # (-1)*(-1) 的低 32 位 = 1
    CHECK x3, 1, 5

    # ---------------- B. 高位与 MULHSU 符号 ----------------
    li   x1, 0xFFFFFFFF
    li   x2, 0xFFFFFFFF
    mulh x3, x1, x2          # (-1)*(-1) = 1 ⇒ 高 32 位 = 0
    CHECK x3, 0, 6

    li   x1, 0x80000000
    li   x2, 0xFFFFFFFF
    mulh x3, x1, x2          # INT_MIN * -1 = 2^31 ⇒ 高 32 位 = 0
    CHECK x3, 0, 7

    # MULHSU (0x80000000, 0xFFFFFFFF): -2^31 * (2^32-1) = -0x7FFFFFFF80000000
    # ⇒ 高 32 位 = 0x80000000。这一组是"符号处理写错"最典型的指纹。
    li   x1, 0x80000000
    li   x2, 0xFFFFFFFF
    mulhsu x3, x1, x2
    CHECK x3, 0x80000000, 8

    # MULHSU (0x7FFFFFFF, 0x80000000) = 0x3FFFFFFF80000000
    li   x1, 0x7FFFFFFF
    li   x2, 0x80000000
    mulhsu x3, x1, x2
    CHECK x3, 0x3FFFFFFF, 9

    li   x1, 0xFFFFFFFF
    li   x2, 0xFFFFFFFF
    mulhu x3, x1, x2         # (2^32-1)^2 = 0xFFFFFFFE00000001
    CHECK x3, 0xFFFFFFFE, 10

    li   x1, 0x80000000
    li   x2, 0x80000000
    mulhu x3, x1, x2         # 2^62
    CHECK x3, 0x40000000, 11

    # ---------------- C. 除法特殊值 ----------------
    li   x1, 5
    li   x2, 0
    div  x3, x1, x2          # 除零 ⇒ -1
    CHECK x3, 0xFFFFFFFF, 12
    divu x3, x1, x2
    CHECK x3, 0xFFFFFFFF, 13
    rem  x3, x1, x2          # 除零 ⇒ 被除数本身
    CHECK x3, 5, 14
    remu x3, x1, x2
    CHECK x3, 5, 15

    li   x1, -5
    rem  x3, x1, x2          # 除零 ⇒ **原始**被除数 (不是绝对值)
    CHECK x3, 0xFFFFFFFB, 16

    li   x1, 0x80000000
    li   x2, -1
    div  x3, x1, x2          # INT_MIN / -1 ⇒ INT_MIN (溢出不回绕)
    CHECK x3, 0x80000000, 17
    rem  x3, x1, x2          # INT_MIN % -1 ⇒ 0
    CHECK x3, 0, 18

    li   x2, 1
    li   x1, 0xDEADBEEF
    div  x3, x1, x2          # x / 1 = x
    CHECK x3, 0xDEADBEEF, 19
    rem  x3, x1, x2          # x % 1 = 0
    CHECK x3, 0, 20

    li   x1, 0
    li   x2, 7
    div  x3, x1, x2          # 0 / x = 0
    CHECK x3, 0, 21
    rem  x3, x1, x2
    CHECK x3, 0, 22

    # ---------------- D. 商与余数的符号 ----------------
    li   x1, -7
    li   x2, 3
    div  x3, x1, x2          # -7 / 3 = -2 (向零截断)
    CHECK x3, -2, 23
    rem  x3, x1, x2          # -7 % 3 = -1 (余数跟被除数)
    CHECK x3, -1, 24

    li   x1, 7
    li   x2, -3
    div  x3, x1, x2
    CHECK x3, -2, 25
    rem  x3, x1, x2
    CHECK x3, 1, 26

    li   x1, -7
    li   x2, -3
    div  x3, x1, x2
    CHECK x3, 2, 27
    rem  x3, x1, x2
    CHECK x3, -1, 28

    li   x1, 100
    li   x2, 7
    div  x3, x1, x2
    CHECK x3, 14, 29
    rem  x3, x1, x2
    CHECK x3, 2, 30
    divu x3, x1, x2
    CHECK x3, 14, 31
    remu x3, x1, x2
    CHECK x3, 2, 32

    # ---------------- E. 依赖距离 ----------------
    li   x4, 9
    li   x5, 11
    li   x6, 0

    mul  x7, x4, x5          # 距离 0: 紧跟一条就用
    add  x8, x7, x7
    CHECK x8, 198, 33

    mul  x7, x4, x5          # 距离 1
    addi x6, x6, 0
    add  x8, x7, x6
    CHECK x8, 99, 34

    mul  x7, x4, x5          # 距离 2
    addi x6, x6, 0
    addi x6, x6, 0
    add  x8, x7, x6
    CHECK x8, 99, 35

    mul  x7, x4, x5          # 距离 3
    addi x6, x6, 0
    addi x6, x6, 0
    addi x6, x6, 0
    add  x8, x7, x6
    CHECK x8, 99, 36

    # 消费者是分支条件 / 访存数据 (前递要覆盖这两条路)
    li   x9, 0x3000          # DRAM 里的一块空闲区 (避开镜像占用的低地址)
    mul  x7, x4, x5
    beq  x7, x7, 1f          # 用乘法结果当分支条件, 恒成立
    li   x30, 37
    j    fail
1:
    mul  x7, x4, x5
    sw   x7, 0(x9)           # 用乘法结果当 store 数据
    addi x6, x6, 0           # 给 store→load 留两拍, 免得测到访存通路的时序细节
    addi x6, x6, 0
    lw   x8, 0(x9)
    CHECK x8, 99, 38

    # 连续两条乘法背靠背 (II=1)
    li   x10, 3
    li   x11, 4
    mul  x12, x10, x11       # 12
    mul  x13, x12, x11       # 48 (前一条的结果当操作数)
    mul  x14, x13, x10       # 144
    add  x8, x12, x13
    add  x8, x8, x14
    CHECK x8, 204, 39

    # ---------------- F. 写同一个 rd ----------------
    li   x15, 0x1111
    mul  x15, x10, x11       # 12
    addi x15, x0, 1          # 年轻指令覆盖 ⇒ 1 (乘法的写必须发生在它之前)
    CHECK x15, 1, 40

    addi x15, x0, 7
    mul  x15, x10, x11       # 年轻乘法覆盖老 addi ⇒ 12
    CHECK x15, 12, 41

    # ---------------- G. 在飞冲刷 ----------------
    # (1) 乘法在 MEM 时分支误预测: 乘法**比分支老**, 结果必须照常写回。
    li   x20, 0
    li   x16, 0
    li   x4, 9
    li   x5, 11
    mul  x17, x4, x5         # 99, 在飞
    beq  x20, x0, 2f         # 恒跳; 冷预测器上很可能误预测
    li   x16, 0xBAD          # 错误路径
2:
    CHECK x17, 99, 42
    CHECK x16, 0, 43

    # (2) 错误路径上的乘法绝不能写回。x18 先清 0, 若错路乘法漏写就说谎了。
    li   x18, 0
    li   x20, 0
    li   x4, 0x1234
    li   x5, 0x5678
    beq  x20, x0, 3f         # 恒跳
    mul  x18, x4, x5         # 错误路径上的乘法
    mul  x18, x18, x4
3:
    CHECK x18, 0, 44

    # (3) 循环里连做乘法, 出口那次分支"由跳变不跳" ⇒ 制造一次真误预测。
    # 乘法与被冲掉的年轻指令同时在飞, 结果必须照常写回。
    li   x4, 9
    li   x5, 11
    li   x16, 0
    li   x20, 0
    li   x21, 6
4:
    mul  x17, x4, x5         # 99
    add  x16, x16, x17
    addi x20, x20, 1
    blt  x20, x21, 4b        # 前 5 次跳, 第 6 次不跳 ⇒ 预测器学习后误预测一次
5:
    # 循环体跑了 6 次 (x20 = 0..5)
    CHECK x16, 594, 45

    # ---------------- H. 除法与紧随消费者 ----------------
    li   x1, 100
    li   x2, 7
    div  x7, x1, x2          # 距离 0
    add  x8, x7, x7
    CHECK x8, 28, 46

    div  x7, x1, x2          # 距离 1
    addi x6, x6, 0
    add  x8, x7, x6
    CHECK x8, 14, 47

    addi x6, x0, 0
    div  x7, x1, x2          # 距离 2
    addi x6, x6, 1
    add  x8, x7, x6
    CHECK x8, 15, 48

    # 除法 + 背靠背 (第二条除法要等第一条出结果)
    li   x1, 0x7FFFFFFF
    li   x2, 3
    div  x7, x1, x2
    div  x8, x7, x2
    CHECK x7, 715827882, 49
    CHECK x8, 238609294, 50

    # 乘法在飞 + 除法占住 EX + 消费者要用乘法的 rd。这一组专打"除法在 EX 迭代
    # 期间, 后面的乘法冒险信号误清 ID_EX"那条路 —— 一旦踩中, 除法会凭空消失。
    li   x1, 100
    li   x2, 7
    li   x4, 13
    li   x5, 17
    mul  x7, x4, x5          # 221
    div  x8, x1, x2          # 14 (与乘法无依赖, 所以能走到 EX)
    add  x9, x7, x8          # 同时要乘法和除法的结果
    CHECK x9, 235, 51
    CHECK x7, 221, 52
    CHECK x8, 14, 53

    # 全量程除法 (16 次迭代那个档位)
    li   x1, 0xFFFFFFFF
    li   x2, 3
    divu x7, x1, x2
    CHECK x7, 0x55555555, 54
    remu x8, x1, x2
    CHECK x8, 0, 55

    li   x30, 0
    j    pass

fail:
    mv   x10, x30            # a0 = 失败编号
    li   x17, 93
    ecall
    unimp

pass:
    li   x10, 0
    li   x17, 93
    ecall
    unimp
