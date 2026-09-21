.section .text.init
.globl _start
_start:
    jal x0, reset_vector

reset_vector:
    # 先记下 DRAM 第 0 个字(镜像首字)的原值, 最后验证 MMIO 写没有把它踩坏.
    # 加外设桥之前, 写 0x80000000 会被截断成 DRAM[0], 这个检查就是针对那个 bug.
    lw   x18, 0(x0)

    # ---- 1. MONITOR 写后回读 ----
    lui  x5, 0x80000            # x5 = 0x80000000
    lui  x6, 0x12345
    addi x6, x6, 0x678          # x6 = 0x12345678 (非 pass/fail 标志, 不会触发 halt)
    sw   x6, 0(x5)
    lw   x7, 0(x5)
    bne  x7, x6, fail

    # ---- 2. TIMER: mtime 递增 ----
    lui  x8, 0xFFFFF
    addi x8, x8, 0x040          # x8 = 0xFFFFF040
    lw   x9, 0(x8)              # mtime[31:0]
    lw   x19, 0(x8)             # 再读一次
    sub  x20, x19, x9
    bge  x0, x20, fail          # 差值必须 > 0

    # ---- 3. TIMER: 高位在短仿真内应为 0 ----
    lw   x21, 4(x8)
    bne  x21, x0, fail

    # ---- 4. TIMER: mtimecmp 读写 ----
    lui  x22, 0x0000A
    addi x22, x22, 0x5A5        # x22 = 0x0000A5A5
    sw   x22, 8(x8)
    lw   x23, 8(x8)
    bne  x23, x22, fail

    # ---- 5. DIG 写后回读 ----
    lui  x15, 0xFFFFF           # x15 = 0xFFFFF000
    lui  x16, 0x0000B
    addi x16, x16, 0xCD         # x16 = 0x0000ABCD
    sw   x16, 0(x15)
    lw   x24, 0(x15)
    bne  x24, x16, fail

    # ---- 6. MMIO 写没有污染 DRAM[0] ----
    lw   x25, 0(x0)
    bne  x25, x18, fail

    # ---- 全部通过 ----
    addi x10, x0, 0             # a0 = 0
    jal  x0, end

fail:
    addi x10, x0, 1             # a0 = 1

end:
    addi x17, x0, 93            # a7 = 93 (exit syscall)
    ecall
    unimp
