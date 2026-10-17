/*
 * CoralNPU 侧的最小测试程序 —— 里程碑 1 的被测对象.
 *
 * 目的: 证明"CPU 把程序写进 ITCM → 配 pcStart → 放时钟门控与复位 → NPU 真的
 *       跑起来 → 写出的数据能被 CPU 读回"这条链路是通的.
 *
 * 所以它刻意做得极简, 且不依赖任何 CoralNPU 的运行库:
 *   * 不用 toolchain/crt/coralnpu_start.S (那份会设栈、清 bss、跑 init_array)
 *   * 不设栈指针 (本程序没有调用、没有局部变量, 用不着栈)
 *   * 不用 gp 相对寻址 (纯 lui/addi 造地址)
 *   * 纯 RV32IM, 不碰向量 —— 本里程碑不测向量, 先证明通路
 *
 * 两个魔数是给 CPU 侧比的:
 *   0xCAFEBABE @ DTCM+0x00
 *   0x12345678 @ DTCM+0x04
 * 选互不相同、且都不是 0 或全 1 的值 —— 未初始化/未写成功时读回来是 SRAM 的
 * 随机初值, 不会跟这两个数撞上 (`Sram_2048x128.v` 的 initial 用 $random 填).
 *
 * ⚠️ 链接方式: 不用 toolchain/coralnpu_tcm.ld.tpl. 那份链接脚本的 .data 段
 *    无条件分配 `_ret` 槽位到 DTCM, objcopy -O binary 之后会产出一个 ~64KB 的
 *    稀疏镜像 (CPU 的 DRAM 才 64KB, 放不下). 这里改用 -Wl,-Ttext=0 且保持
 *    程序为纯 .text, 得到的镜像就是每 4 字节一条指令的扁平数组, 与 ITCM
 *    本地 0 一一对应.
 *
 * 收尾用 mpause (编码 0x08000073) —— CoralNPU 的自定义指令, 会把粘滞的
 * halted 标志置起. CPU 侧就是靠轮询这个标志判断"跑完了".
 */

    .section .text
    .globl _start
    .align 2

_start:
    /* DTCM 本地基址 = 0x0001_0000 */
    li      t0, 0x00010000

    li      t1, 0xCAFEBABE
    sw      t1, 0(t0)

    li      t2, 0x12345678
    sw      t2, 4(t0)

    /* mpause: 置 halted, 核停下来 */
    .word   0x08000073

    /* mpause 之后的兜底自旋. 正常情况下不会执行到 —— 留着是为了万一
       mpause 没生效, 核也不会跑飞出去访问未映射地址 (那会触发 SLVERR →
       fault, 反而看不清是哪个环节的问题). */
1:  j       1b
