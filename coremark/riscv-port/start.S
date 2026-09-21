# RISC-V startup code for CoreMark
.section .text.init
.globl _start
.type _start, @function

_start:
    # Initialize stack pointer
    la sp, _stack_top
    
    # Clear BSS section
    la a0, _bss_start
    la a1, _bss_end
    beq a0, a1, bss_done
bss_loop:
    sw zero, 0(a0)
    addi a0, a0, 4
    blt a0, a1, bss_loop
bss_done:

    # Call main
    call main
    
    # If main returns, loop forever
_exit:
    j _exit

.size _start, .-_start
