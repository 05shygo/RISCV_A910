# 异常 / 中断 / CSR 定向测试.
#
# 覆盖: CSR 五条指令的旧值语义, ecall(11), ebreak(3), 非法指令(2)+mtval,
#       load 非对齐(4), store 非对齐(6), jalr 目标非对齐(0), 定时器中断(MTIP).
#
# 注意本用例【写 mtvec】装 handler, 所以 golden model 侧的
# "裸 ecall = 测试结束" 兼容分支 (mtvec==0) 不会生效 —— 必须用写
# MONITOR(0x8000_0000) 的 0x0000BEEF / 0x0000DEAD 收尾.

.section .text.init
.globl _start
_start:
    jal x0, reset_vector

# ---------------------------------------------------------------------------
# 统一陷阱入口.
# 只破坏 x5 / x6 / x7 / x28 / x29 —— 测试主体不要在这些寄存器里跨陷入存东西.
# 出口时:
#   x5 = mcause, x6 = 出错指令的地址(mepc 原值), x7 = mtval
#
# 同步异常: mepc+4 后 mret, 于是从出错指令的下一条继续执行.
# 定时器中断: 抬高 mtimecmp 把中断源拉低(pending 需要软件清源才会掉),
#             并且【不】改 mepc —— mret 后重执行被打断的那条指令.
# ---------------------------------------------------------------------------
trap_handler:
    csrr x5, mcause
    csrr x6, mepc
    csrr x7, mtval

    li   x28, 0x80000007
    bne  x5, x28, th_sync

    # ---- 定时器中断 ----
    li   x28, 0xFFFFF040
    li   x29, -1
    sw   x29, 8(x28)            # mtimecmp_lo = 0xFFFFFFFF
    sw   x29, 12(x28)           # mtimecmp_hi = 0xFFFFFFFF  -> 源变低
    mret

th_sync:
    # 取指越界(cause 1)不能靠 mepc+4 恢复 —— 下一格地址依然取不到, 会无限陷入.
    # 恢复地址由测试预先放进 mscratch.
    li   x28, 1
    beq  x5, x28, th_inst_fault

    addi x28, x6, 4             # 其余同步异常: 跳过出错指令
    csrw mepc, x28
    mret

th_inst_fault:
    csrr x28, mscratch
    csrw mepc, x28
    mret

reset_vector:
    # ---- 0. 装陷阱入口 (从这一刻起 ecall 不再是"测试结束") ----
    la   x30, trap_handler
    csrw mtvec, x30

    # ===================== 1. CSR 指令的旧值语义 =====================
    li   x10, 0x12345678
    csrw mscratch, x10
    csrr x11, mscratch
    bne  x11, x10, fail

    # csrrw: rd 拿【旧值】, csr 写新值
    li   x12, 0xAABBCCDD
    csrrw x13, mscratch, x12
    bne  x13, x10, fail
    csrr x14, mscratch
    bne  x14, x12, fail

    # csrrs: 新值 = 旧值 | rs1, rd 拿旧值
    li   x15, 0x0F0F0F0F
    csrrs x16, mscratch, x15
    bne  x16, x12, fail
    li   x17, 0xAFBFCFDF        # 0xAABBCCDD | 0x0F0F0F0F
    csrr x18, mscratch
    bne  x18, x17, fail

    # csrrc: 新值 = 旧值 & ~rs1
    csrrc x19, mscratch, x15
    bne  x19, x17, fail
    li   x20, 0xA0B0C0D0        # 0xAFBFCFDF & ~0x0F0F0F0F
    csrr x21, mscratch
    bne  x21, x20, fail

    # csrrwi: 源是 rs1 域里的 5 位零扩展立即数
    csrrwi x22, mscratch, 31
    li   x23, 31
    csrr x24, mscratch
    bne  x24, x23, fail

    # csrrs rd, csr, x0 是纯读 (rs1=x0 不触发写)
    csrrs x25, mscratch, x0
    bne  x25, x23, fail

    # ---- 反向验证补丁 1: CSR 读的 B 口必须是 0 ----------------------------
    # 守 ALU_input_MUX 的 `ALUB_SEL_ZERO: B = 32'b0`。改成 B=rD2 时,
    # CSR 读回的就是 "旧值 + 某个寄存器", 下面这条会立刻不等。
    #
    # 选 CSR 有一条**不显然**的准则: 它的**低 5 位** (inst[24:20], 也就是
    # ALU_input_MUX.rD2 取到的寄存器号) 索引到的那个寄存器**必须非 0**。
    # 上面全部 CSR 用例只用了 mscratch(0x340) 和 mstatus(0x300) —— 两者低 5 位
    # 都是 0, 索引到 x0, 而 x0 恒为 0, 于是 "B 口给 0" 和 "B 口给 rD2"
    # **完全分不出来** (第一版反向验证就是在这里漏掉的)。
    # mtvec = 0x305 -> 低 5 位 = 5 -> x5, 所以先把 x5 设成非 0 再读。
    la   x28, trap_handler
    csrw mtvec, x28
    li   x5, 0xDEADBEEF          # 让 rD2 指向的 x5 非 0
    csrr x29, mtvec
    bne  x29, x28, fail          # 正确结果 = mtvec 本身, 不是 mtvec + x5
    li   x5, 0

    # ---- 反向验证补丁 2: 对**只读** CSR 的纯读必须合法 --------------------
    # 守 Control.v 的 `csr_we = (csr_op == CSR_OP_RW) || (rs1_addr != 5'b0)`。
    # 若 csr_we 被写成恒 1, `csrrs rd, <只读 CSR>, x0` 会撞上
    # `is_illegal = csr_we && csr_addr_ro` 而被判非法 —— 但上面那条
    # `csrrs x25, mscratch, x0` 的 mscratch **可写**, 恒写也只是把旧值写回去,
    # 语义上没有差别, 所以它抓不到。
    # 这里用 mcycle (只读): 拿 x5 当哨兵, 没陷入它就该保持 -1。
    #
    # ⚠️ rd **必须写 x0** (读出来丢掉)。写成 `csrrs x29, mcycle, x0` 会让
    #    difftest 直接失配: DUT 的 mcycle 数真实周期, 参考模型是提交步进的、
    #    只能按"每条指令 +1"计数 (DUT_BUG_REPORT 16.3), 两者本来就对不上 ——
    #    计数器的值一旦落进 rd 就会被提交点比较。实测踩过 (第 1146 拍失配)。
    #    这里只需要"有没有陷入"这一个信息, 值本身不要。
    li   x5, -1
    csrrs x0, mcycle, x0
    li   x28, -1
    bne  x5, x28, fail

    # ===================== 2. ecall -> mcause 11 =====================
    li   x10, 0
test_ecall:
    ecall
    la   x11, test_ecall
    bne  x6, x11, fail          # mepc = ecall 自己的地址
    li   x12, 11
    bne  x5, x12, fail
    bne  x7, x0, fail           # ecall 的 mtval = 0

    # ===================== 3. ebreak -> mcause 3 =====================
test_ebreak:
    ebreak
    la   x11, test_ebreak
    bne  x6, x11, fail
    li   x12, 3
    bne  x5, x12, fail

    # ===================== 4. 非法指令 -> mcause 2, mtval = 指令字 ==========
    # 不能用 unimp: unimp = 0xC0001073 = csrrw x0, cycle, x0,
    # 实现了 CSR 之后它是一条【合法】指令, 不会陷入.
test_illegal:
    .word 0xffffffff
    la   x11, test_illegal
    bne  x6, x11, fail
    li   x12, 2
    bne  x5, x12, fail
    li   x13, -1
    bne  x7, x13, fail          # mtval = 指令本身

    # ===================== 5. load 非对齐 -> mcause 4 =====================
    la   x14, scratch
    li   x20, 0x0BADF00D
    sw   x20, 0(x14)            # 先在对齐地址写个已知值
    addi x14, x14, 1            # 奇地址
    li   x15, 0x5A5A5A5A
test_lh:
    lh   x15, 0(x14)
    la   x11, test_lh
    bne  x6, x11, fail
    li   x12, 4
    bne  x5, x12, fail
    bne  x7, x14, fail          # mtval = 访存地址
    li   x13, 0x5A5A5A5A
    bne  x15, x13, fail         # 被陷阱的 load 绝不能写 rd

    # ===================== 6. store 非对齐 -> mcause 6 =====================
    li   x16, 0x11223344
test_sw:
    sw   x16, 0(x14)            # x14 是奇地址 -> 非 4 对齐
    la   x11, test_sw
    bne  x6, x11, fail
    li   x12, 6
    bne  x5, x12, fail
    bne  x7, x14, fail
    # 被陷阱的 store 绝不能真的写进内存
    la   x18, scratch
    lw   x19, 0(x18)
    bne  x19, x20, fail

    # ===================== 7. jalr 目标非对齐 -> mcause 0 ==================
    la   x20, jalr_target
test_jalr:
    jalr x0, x20, 2             # 目标 = jalr_target + 2
    la   x11, test_jalr
    bne  x6, x11, fail
    bne  x5, x0, fail           # mcause = 0
    addi x21, x20, 2
    bne  x7, x21, fail          # mtval = 非对齐的目标地址

    # ===================== 8. 地址越界 -> 访问异常 =====================
    # 这一组专治"越界地址被静默别名进 DRAM[0]".
    # 关键: 老的 bug 是把地址截断成 Bus_addr[15:2], 所以 0x00010000 会落到
    # 【字节地址 0】(镜像的第一个字, 也就是 _start 那条 j 指令)。
    # 因此要盯着地址 0 检查, 而不是随便找个数据区 —— 我第一版就是盯错了地方,
    # 反向验证时才暴露出来.
    lw   x17, 0(x0)             # 记下字节地址 0 的原值 (0x0040006f)

    lui  x22, 0x00010           # x22 = 0x00010000, 刚好越过 64KB
    li   x23, 0x11223344
test_st_oob:
    sw   x23, 0(x22)
    la   x11, test_st_oob
    bne  x6, x11, fail          # mepc = 出错指令
    li   x12, 7
    bne  x5, x12, fail          # store access fault
    bne  x7, x22, fail          # mtval = 越界地址
    lw   x24, 0(x0)
    bne  x24, x17, fail         # ★ 越界写没有被截断落到地址 0

    lui  x25, 0x00020           # 0x00020000, 另一个会回绕到 0 的地址
    li   x26, 0x5A5A5A5A
test_ld_oob:
    lw   x26, 0(x25)
    la   x11, test_ld_oob
    bne  x6, x11, fail
    li   x12, 5
    bne  x5, x12, fail          # load access fault
    bne  x7, x25, fail
    li   x12, 0x5A5A5A5A
    bne  x26, x12, fail         # ★ 越界 load 不能写 rd
    lw   x24, 0(x0)
    bne  x24, x17, fail

    # 外设页里【未实现】的偏移也要报异常, 而不是静默丢弃
    # (以前整页放行, 往未实现的外设写会被无声吃掉)
    lui  x27, 0xFFFFF
    addi x27, x27, 0x004        # 0xFFFFF004, DIG 之后的空隙
test_peri_gap:
    lw   x26, 0(x27)
    la   x11, test_peri_gap
    bne  x6, x11, fail
    li   x12, 5
    bne  x5, x12, fail

    # ===================== 9. 取指越界 -> mcause 1 =====================
    # 恢复地址放 mscratch, 由 handler 的 cause-1 分支取用
    la   x22, after_inst_fault
    csrw mscratch, x22
    li   x23, 0x20000           # 64KB 之外
test_inst_fault:
    jalr x0, x23, 0
after_inst_fault:
    li   x12, 1
    bne  x5, x12, fail          # instruction access fault
    li   x13, 0x20000
    bne  x6, x13, fail          # mepc = 取不到的那个地址
    bne  x7, x13, fail          # mtval 同上

    # ===================== 10. 定时器中断 (MTIP) =====================
    # 先彻底关中断, 免得配置期间就被打断
    csrw mie, x0
    csrw mstatus, x0

    # 抬高 mtimecmp 把中断源拉低.
    # 复位后 mtime = mtimecmp = 0, 而判据是 mtime >= mtimecmp, 所以
    # mip[7] 复位后【就是 1】; 只有让源变低才会清掉.
    li   x22, 0xFFFFF040
    li   x23, -1
    sw   x23, 8(x22)
    sw   x23, 12(x22)

    # mtimecmp = mtime + 300
    lw   x24, 0(x22)
    addi x24, x24, 300
    sw   x24, 8(x22)
    sw   x0,  12(x22)

    # 开中断: mie.MTIE = 1, mstatus.MIE = 1
    li   x25, 0x80
    csrw mie, x25
    li   x26, 0x8
    csrw mstatus, x26

    # 自旋等中断 (handler 会把 x5 置成 0x80000007).
    #
    # 循环体里【故意】放一条 store 和一条 CSR 写: 中断只能落在"没有已发生
    # 副作用"的提交点上(被 squash 的指令若已经写过内存或 CSR, DUT 与参考模型
    # 会永久不一致). 这个循环每次都经过这两类指令, 正好压住 irq_safe 那条路径
    # —— 少了它, 去掉门控的改动也能"通过", 等于没测.
    la   x21, scratch
    li   x5, 0
wait_loop:
    sw   x0, 0(x21)             # 有副作用的 store
    csrw mscratch, x0           # 有副作用的 CSR 写
    li   x27, 0x80000007
    beq  x5, x27, wait_done
    j    wait_loop
wait_done:
    li   x27, 0x80000007
    bne  x5, x27, fail          # 必须真的收到定时器中断

    # mret 应把 MIE 恢复成陷入前的值(1)
    csrr x10, mstatus
    andi x11, x10, 8
    beq  x11, x0, fail

    # 收尾前关中断, 免得后面又被中断打断
    csrw mie, x0
    csrw mstatus, x0

    # ============ 11. 非法 S 型 funct3 -> 纯 no-op ============
    # 编码: S 型, funct3 = 011 (RISC-V 保留编码), rs1=x30, rs2=x29, imm=0
    #   -> .word 0x01DF3023
    # 约定 (2026-10-01, 对齐参考核 RISCV_CPU/cpu): **不判非法指令** —— 不写内存、
    # 不写寄存器、不报异常, 整条退化成 no-op。cpu 对同一情形是
    # `default: inst_subtype_o = 4'b0` (= 它的 MEM_LB) 且 reg_wflag=0, 继续走。
    #
    # 这条盯的是 Control.v 的 OPCODE_S 兜底臂: 把 ram_we 改回 1 就会**真的写一个
    # 整字** (dram_sel=LB 让 MEM.v 的 wdata_out 保持默认的 wdin, 而本核没有字节
    # 使能), 哨兵会被改掉。更早的写法还会把上一笔 store 的残留数据写进来。
    la   x30, s_f3_target
    li   x29, 0x11112222
    sw   x29, 0(x30)            # 哨兵
    li   x29, 0x5555AAAA
    .word 0x01DF3023            # 非法 funct3 的 S 型 (本该是 sw x29,0(x30))
    lw   x31, 0(x30)
    li   x28, 0x11112222
    bne  x31, x28, fail         # 哨兵必须原封不动

    # 奇数地址再来一次: 旧写法 (兜底 dram_sel=SW) 会让 ex_wsize_word=1 而报
    # cause 6 (store 非对齐)。给一条非法指令报"非对齐"没有意义 —— 现在
    # ram_we=0 让 ex_is_store=0, cause 6/7 都产生不了。
    addi x30, x30, 1
    li   x5, -1                 # 哨兵: 没陷入就保持 -1
    .word 0x01FF3023            # 同一编码, rs2=x31
    li   x28, -1
    bne  x5, x28, fail

    # ===================== 全部通过 =====================
    li   x10, 0x80000000
    li   x11, 0x0000BEEF
    sw   x11, 0(x10)            # 通知 MONITOR / TB: 通过
    j    .                      # 停在这里等 TB 结束仿真

fail:
    li   x10, 0x80000000
    li   x11, 0x0000DEAD
    sw   x11, 0(x10)            # 通知 MONITOR / TB: 失败
    j    .

.section .data
.align 4
scratch:
    .word 0x0BADF00D
jalr_target:
    .word 0x00000000
s_f3_target:                        # 第 11 节"非法 S 型 funct3"的哨兵
    .word 0x00000000
