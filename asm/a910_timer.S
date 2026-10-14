# ---------------------------------------------------------------------------
# a910_timer.S —— A910 上"读 TIMER 外设"的最小用例   (2026-10-14)
#
# 【为什么要它】CoreMark 搬到 A910 上跑, 唯一的新依赖就是**读 TIMER**
#   (`*(volatile ee_u32 *)0xFFFFF040`, 见 coremark/riscv-port/core_portme.h 的
#   CM_TIMER_ADDR)。而 A910_cpu 顶层**没有外设** —— 这个 TIMER 是 difftest 台
#   在 AXI 从机上现造的 (返回 TB 的周期计数器, 见 tb/a910/tb_a910_difftest.sv
#   顶部 "TIMER 外设" 那段)。
#   先用这条用例把它单独钉住: 免得 CoreMark 跑几十分钟才发现"读数恒等"或
#   "设备读把核挂住"。
#
# 【判据】(difftest 逐条比对 + 人眼看下面三项)
#   1) 两次读数**不等** —— 计数器真的在走 (恒等 ⇒ vcycles 恒 0, CoreMark 不出分);
#   2) 差值是**小正数** (设备读的往返延迟, 几拍~几十拍), 不是几十万 (那是没读到);
#   3) 最后给 MONITOR 写 0xBEEF ⇒ 黄金模型停机判 PASS。
# ---------------------------------------------------------------------------
    .section .text.init
    .globl _start
_start:
    li   t0, 0xFFFFF040         # TIMER.mtime[31:0] (只读)
    lw   t1, 0(t0)              # 第一次读
    lw   t2, 0(t0)              # 紧挨着再读一次 (同一拍附近)

    # 空转 ~200 拍: **关键判据** —— 隔这么多拍再读, 差值若仍为 0, 说明这个地址
    # 被当普通内存缓存了 (设备读必须每次真的过总线); 差值 ~200 才是对的。
    li   t5, 50
1:  addi t5, t5, -1
    bne  t5, x0, 1b

    lw   t3, 0(t0)              # 隔 ~200 拍后的第三次读
    sub  t4, t2, t1             # 间隔 1 (紧邻)
    sub  t6, t3, t2             # 间隔 2 (隔了 ~200 拍) ← 看这个

    # 顺手把现场存到内存 (difftest 只看寄存器, 这里是给人看的)
    li   t5, 0x2000
    sw   t1, 0(t5)
    sw   t4, 4(t5)
    sw   t6, 8(t5)

    # 停机: MONITOR <- 0xBEEF (黄金模型的 pass 标志, 见 golden_model/peripheral/result_monitor.c)
    li   t0, 0x80000000
    li   t1, 0x0000BEEF
    sw   t1, 0(t0)
1:  j    1b
