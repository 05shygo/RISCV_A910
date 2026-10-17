# ===========================================================================
# asm/npu_loop.S —— 里程碑 1 主判据: CPU 启动 CoralNPU 并读回结果
# ===========================================================================
# 跑法:  make npu-run TEST=npu_loop MAX_CYCLES=200000
#
# 它做的事 (对应 doc/npu_m1_zh.md 的验收序列):
#   1. 放 NPU 的 aresetn               (CTL = 1, 等 16 拍保持计数走完)
#   2. 把 npu_prog 的机器码逐字写进 ITCM (WADDR 自增)
#   3. 读回 ITCM[0] 自检写通路          —— 这一步失败说明桥的写侧有问题,
#                                          不必等 NPU 跑起来就能定位
#   4. 配 pcStart = 0
#   5. 放时钟门控 (CTL = 1) 再放复位 (CTL = 0)
#   6. 轮询 STATUS.HALT 直到 NPU 跑完 (mpause)
#   7. 经 AXI 读 CSR status 交叉验证 halted 位
#   8. 读回 DTCM 的两个魔数, 与 npu_prog.S 里写的比对
#   9. 写 0xBEEF 到 MONITOR+0 表示通过, 或 0xDEAD 到 MONITOR+4 表示失败
#
# ⚠️ 全程只用 sw/lw —— 见 mySoC/npu_bridge.v 开头. perip_bridge.v:18 写明
#    "总线上看不出 sb/sh, 外设只能按整字 sw 写": 半字写会走读-改-写, 把高 lane
#    的垃圾一起写进去.
#
# ⚠️ 寄存器约定: a0(x10) 留给退出码 (difftest 的 npu_smoke 变体要用), 不能
#    当临时寄存器. 这里用 t0-t4 / s2.
# ===========================================================================

# ---- NPU 程序长度 (由 Makefile 生成) ----
# ⚠️ 为什么常数和机器码数组要分成两个 .include:
#    机器码是一串 .word, 必须放在**文件末尾** —— 放开头就占据地址 0, 而 CPU
#    复位后从 PC=0 取指, 会把数据表当指令执行. 但 GAS 的 `li` 是宏, 展开时
#    要立刻知道立即数的值, **不支持前向引用** ⇒ 常数只能单独放开头.
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
.equ NPU_ERRADDR,0x1C
.equ NPU_ERRCLR, 0x20

# STATUS 位
.equ ST_BUSY,    0x01
.equ ST_ERR,     0x02
.equ ST_OVF,     0x04
.equ ST_HALT,    0x08
.equ ST_FAULT,   0x10

# NPU 本地地址
.equ NPU_ITCM,   0x00000000
.equ NPU_DTCM,   0x00010000
.equ NPU_CSR,    0x00030000

# 期望值 —— 必须与 npu/npu_prog.S 里写的两个魔数一致
.equ EXP_W0,     0xCAFEBABE
.equ EXP_W1,     0x12345678

# MONITOR / DIG
.equ MON_PASS,   0x80000000
.equ MON_FAIL,   0x80000004
.equ DIG_REG,    0xFFFFF000

# 轮询上限 —— 纯兜底, 防止桥或 NPU 出问题时仿真挂到周期上限而没有诊断
.equ SPIN_MAX,   200000

.macro NPU_INIT
    li   t0, NPU_BASE
    li   t1, 0
    sw   t1, NPU_ERRCLR(t0)         # 清粘滞错误
.endm

# 等访问引擎空闲. 用 s2 做临时 (宏里不改别的寄存器).
.macro NPU_IDLE
9990:
    lw   s2, NPU_STATUS(t0)
    andi s2, s2, ST_BUSY
    bnez s2, 9990b
.endm

# 单拍 AXI 写: \a = NPU 本地地址寄存器, \d = 数据寄存器
.macro NPU_AXIW areg, dreg
    sw   \areg, NPU_WADDR(t0)
    NPU_IDLE
    sw   \dreg, NPU_WDATA(t0)
    NPU_IDLE
.endm

# 单拍 AXI 读: \a = NPU 本地地址寄存器, 结果留在 s3
.macro NPU_AXIR areg
    sw   \areg, NPU_RADDR(t0)
    NPU_IDLE
    li   s2, 1
    sw   s2, NPU_RCMD(t0)
    NPU_IDLE
    lw   s3, NPU_RDATA(t0)
.endm

.section .text
.globl _start
_start:
    NPU_INIT

    # -----------------------------------------------------------------------
    # 1. 放 NPU 的 aresetn.
    #    桥内会加载 16 拍保持计数, 期间 BUSY=1, 覆盖 NPU 内部 RstSync (2 拍)
    #    + axiEnable (1 拍). 这一步之后 AXI 才接受事务.
    # -----------------------------------------------------------------------
    li   t1, 1
    sw   t1, NPU_CTL(t0)
    NPU_IDLE

    # -----------------------------------------------------------------------
    # 2. 把 npu_prog 写进 ITCM.
    #    WADDR 每次被接收后自动 +4, 所以循环里只写 WDATA.
    # -----------------------------------------------------------------------
    li   t1, NPU_ITCM
    sw   t1, NPU_WADDR(t0)
    NPU_IDLE

    la   t2, npu_prog               # .inc 里的机器码数组
    li   t3, NPU_PROG_WORDS
7771:
    lw   t4, 0(t2)
    NPU_IDLE                        # 上一笔写完才写下一笔, 否则桥会置 OVERFLOW
    sw   t4, NPU_WDATA(t0)
    addi t2, t2, 4
    addi t3, t3, -1
    bnez t3, 7771b
    NPU_IDLE

    # -----------------------------------------------------------------------
    # 3. 自检写通路: 读回 ITCM[0], 应当等于程序第一条指令.
    # -----------------------------------------------------------------------
    li   t1, NPU_ITCM
    NPU_AXIR t1
    la   t2, npu_prog
    lw   t2, 0(t2)
    bne  s3, t2, fail

    # -----------------------------------------------------------------------
    # 4. pcStart = 0 (与 npu_core_wrap 里 io_boot_addr=0 一致, 两条路同值)
    # -----------------------------------------------------------------------
    li   t1, NPU_CSR + 4
    li   t2, 0
    NPU_AXIW t1, t2

    # -----------------------------------------------------------------------
    # 5. 放时钟门控再放复位.
    #    CSR+0x00 的 bit1 = 时钟门控(高有效), bit0 = 复位(高有效).
    #    写 1 ⇒ 门控放开、复位仍有效; 写 0 ⇒ 复位也放.
    #    顺序不能反 —— 复位释放沿必须在时钟跑起来之后才被 NPU 内部采到.
    # -----------------------------------------------------------------------
    li   t1, NPU_CSR + 0
    li   t2, 1
    NPU_AXIW t1, t2
    li   t2, 0
    NPU_AXIW t1, t2

    # -----------------------------------------------------------------------
    # 6. 轮询 halted
    # -----------------------------------------------------------------------
    li   t3, SPIN_MAX
7772:
    lw   s2, NPU_STATUS(t0)
    andi t4, s2, ST_HALT
    bnez t4, 7773f                 # halted ⇒ 跑完了
    andi t4, s2, ST_FAULT
    bnez t4, fail                  # NPU 报 fault ⇒ 直接判失败
    andi t4, s2, ST_ERR
    bnez t4, fail                  # 访问出错 (超时/非 OKAY 响应)
    addi t3, t3, -1
    bnez t3, 7772b
    j    fail                      # 轮询超限

7773:
    # -----------------------------------------------------------------------
    # 7. 经 AXI 读 CSR status, 交叉验证 halted 位 (bit0).
    #    这条路和上面读直连引脚不同 —— 它证明 AXI 读通路也是通的.
    # -----------------------------------------------------------------------
    li   t1, NPU_CSR + 8
    NPU_AXIR t1
    andi t2, s3, 1
    beqz t2, fail

    # -----------------------------------------------------------------------
    # 8. 读回 DTCM 的两个魔数
    # -----------------------------------------------------------------------
    li   t1, NPU_DTCM + 0
    NPU_AXIR t1
    li   t2, EXP_W0
    bne  s3, t2, fail

    li   t1, NPU_DTCM + 4
    NPU_AXIR t1
    li   t2, EXP_W1
    bne  s3, t2, fail

    # -----------------------------------------------------------------------
    # 9. 通过. 顺手把读回的第一个字写到数码管, 让 TB 能独立观测到
    #    "这个值确实来自 NPU" (CPU 自己从没往 DIG 写过 0xCAFEBABE).
    # -----------------------------------------------------------------------
    li   t1, EXP_W0
    li   t2, DIG_REG
    sw   t1, 0(t2)

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
# 要灌进 NPU ITCM 的机器码 (由 Makefile 从 npu/npu_prog.S 生成).
# 必须放在最后 —— 见文件开头的说明.
# ---------------------------------------------------------------------------
.include "npu/build/npu_prog.inc"
