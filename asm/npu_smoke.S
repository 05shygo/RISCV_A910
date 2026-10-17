# ===========================================================================
# asm/npu_smoke.S —— 里程碑 1 的 difftest 变体 (Gate 3)
# ===========================================================================
# 跑法:  make NPU=1 TEST=npu_smoke run
#
# 【与 npu_loop.S 的唯一区别】这里**不轮询 BUSY**, 改用固定延时循环.
#
# 为什么必须这样:
#   difftest 逐条比较"提交了什么指令、写了哪个寄存器、值是多少". 而 BUSY 是
#   桥的 FSM 的真实电平 —— 一个单拍 AXI 往返要 3~5 个周期. 黄金模型是
#   **提交步进**的, 没有周期概念, 只能恒答 BUSY=0. 于是同一个轮询循环:
#     模型: 第 1 圈就退出
#     DUT : 要转 3~5 圈
#   ⇒ pc 序列立刻发散, difftest 报一堆无意义的失配.
#
#   换成固定延时之后, 两边执行的**指令序列逐位相同**, difftest 才真正在比
#   "CPU 程序写得对不对" —— 而模型的应答是按"NPU 正确执行后会是什么"给的,
#   于是模型变成了独立检查器: DUT 若返回别的值, 立刻被抓住.
#
#   ⚠️ 延时要足够长. 太短的话 DUT 里上一笔还没做完就发下一笔, 桥会置
#      OVERFLOW 并**丢弃**请求, 而模型照单全收 ⇒ 后续读的值两边不一致.
#      这里给 ~300 周期, 远超单拍往返所需的几个周期.
#
# 【它验证什么 / 不验证什么】
#   验证: CPU 侧程序的每一条访存指令、每一次地址计算、每一个比较分支都对
#         (difftest 全绿 ⇒ 程序本身无 bug, 排除了"测试写错了"这种可能).
#   不验证: NPU 算得对不对 —— 模型不跑 NPU 的程序, DTCM 的内容是写死的期望值.
#          NPU 本身由 tb/npu/tb_npu_loop.sv 直接看信号验证 (Gate 2).
# ===========================================================================

# ---- NPU 程序长度 (由 Makefile 生成) ----
.include "npu/build/npu_prog_defs.inc"

# ---- NPU 控制窗口 (mySoC/npu_bridge.v) ----
.equ NPU_BASE,   0x40000000
.equ NPU_CTL,    0x00
.equ NPU_WADDR,  0x04
.equ NPU_WDATA,  0x08
.equ NPU_STATUS, 0x0C
.equ NPU_RADDR,  0x10
.equ NPU_RCMD,   0x14
.equ NPU_RDATA,  0x18
.equ NPU_ERRCLR, 0x20

.equ NPU_ITCM,   0x00000000
.equ NPU_DTCM,   0x00010000
.equ NPU_CSR,    0x00030000

# 期望值 —— 与 npu/npu_prog.S 里写的两个魔数一致
.equ EXP_W0,     0xCAFEBABE
.equ EXP_W1,     0x12345678

# MONITOR
.equ MON_PASS,   0x80000000
.equ MON_FAIL,   0x80000004

.equ DELAY_ITERS, 100          # 100 圈 × (addi + bnez) ≈ 200+ 周期

# 固定延时. 用 s4 做计数器; 不做任何访存 (循环里没有 MMIO ⇒ 两边指令流相同).
.macro DELAY
    li   s4, DELAY_ITERS
8888:
    addi s4, s4, -1
    bnez s4, 8888b
.endm

# 单拍 AXI 写: \a = 本地地址寄存器, \d = 数据寄存器
# 每笔之间用固定延时代替 BUSY 轮询 —— 见文件开头的说明.
.macro AXIW areg, dreg
    sw   \areg, NPU_WADDR(t0)
    DELAY
    sw   \dreg, NPU_WDATA(t0)
    DELAY
.endm

# 单拍 AXI 读: \a = 本地地址寄存器, 结果留在 s3
.macro AXIR areg
    sw   \areg, NPU_RADDR(t0)
    DELAY
    li   s2, 1
    sw   s2, NPU_RCMD(t0)
    DELAY
    lw   s3, NPU_RDATA(t0)
.endm

.section .text
.globl _start
_start:
    li   t0, NPU_BASE
    li   t1, 0
    sw   t1, NPU_ERRCLR(t0)         # 清粘滞错误 (同时清 RVALID)
    DELAY

    # 1. 放 NPU 的 aresetn (桥内 16 拍保持计数)
    li   t1, 1
    sw   t1, NPU_CTL(t0)
    DELAY

    # 2. 把 npu_prog 写进 ITCM (WADDR 自增)
    li   t1, NPU_ITCM
    sw   t1, NPU_WADDR(t0)
    DELAY

    la   t2, npu_prog
    li   t3, NPU_PROG_WORDS
7771:
    lw   t4, 0(t2)
    sw   t4, NPU_WDATA(t0)
    DELAY
    addi t2, t2, 4
    addi t3, t3, -1
    bnez t3, 7771b

    # 3. 自检写通路: 读回 ITCM[0]
    li   t1, NPU_ITCM
    AXIR t1
    la   t2, npu_prog
    lw   t2, 0(t2)
    bne  s3, t2, fail

    # 4. pcStart = 0 (WADDR 走完上面已是 36, 必须显式重设)
    li   t1, NPU_CSR + 4
    li   t2, 0
    AXIW t1, t2

    # 5. 放时钟门控, 再放复位
    li   t1, NPU_CSR + 0
    li   t2, 1
    AXIW t1, t2
    li   t2, 0
    AXIW t1, t2

    # 6. 给 NPU 足够时间跑完 (纯延时, 不轮询 —— 见文件开头)
    DELAY
    DELAY
    DELAY
    DELAY

    # 7. 读一次 STATUS. 期望 HALT=1 且 RVALID=0 (上一笔是写).
    #    模型给的也是这个值 ⇒ 两边逐位相同.
    lw   s2, NPU_STATUS(t0)
    andi t4, s2, 0x08               # ST_HALT
    beqz t4, fail

    # 8. 经 AXI 读 CSR status, 交叉验证 halted 位
    li   t1, NPU_CSR + 8
    AXIR t1
    andi t2, s3, 1
    beqz t2, fail

    # 9. 读回 DTCM 两个魔数
    li   t1, NPU_DTCM + 0
    AXIR t1
    li   t2, EXP_W0
    bne  s3, t2, fail

    li   t1, NPU_DTCM + 4
    AXIR t1
    li   t2, EXP_W1
    bne  s3, t2, fail

    # 10. 通过
    li   t1, 0x0000BEEF
    li   t2, MON_PASS
    sw   t1, 0(t2)
    li   a0, 0
    ecall
1:  j    1b

fail:
    li   t1, 0x0000DEAD
    li   t2, MON_FAIL
    sw   t1, 0(t2)
    li   a0, 1
    ecall
1:  j    1b

# ---------------------------------------------------------------------------
# 要灌进 NPU ITCM 的机器码. 必须放在最后 —— 放开头会占据地址 0, 而 CPU 复位
# 后从 PC=0 取指, 会把数据表当指令执行.
# ---------------------------------------------------------------------------
.include "npu/build/npu_prog.inc"
