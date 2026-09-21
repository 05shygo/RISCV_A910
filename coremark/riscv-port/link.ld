OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* Use only 16KB to stay well within CPU memory limits */
    /* This ensures stack + program fit in available memory */
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
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
