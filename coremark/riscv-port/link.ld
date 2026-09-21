OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* CPU 的数据窗口就是 64KB (mycpu.v 用 Bus_addr[15:2] 选字, 14 位 -> 64KB),
       golden model 的 MEM_SZ 也是 64KB, 所以这里可以放宽到 64K.
       原来写 16K 时, 映像结束在 0x36e8 而栈顶只有 0x4000, 只剩 2328 字节;
       光 main() 里的 stack_memblock[2000] 一项就把栈压穿了, 会踩掉 .data/.bss
       里的 default_num_contexts 等全局量(表现为 CoreMark 报出 Iterations=234、
       loop 越界读 results[1..]) —— 而且 DUT 与 golden model 踩法一样,
       difftest 发现不了. */
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    . = 0x00000000;

    .text : {
        *(.text.init)
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
    } > RAM

    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > RAM

    .bss : {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    . = ALIGN(16);
    /* Stack top at 16KB = 0x4000, well under 64KB limit */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
