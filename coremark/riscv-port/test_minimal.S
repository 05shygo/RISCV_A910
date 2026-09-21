# Minimal test - just write to monitor and loop
.section .text
.globl _start

_start:
    # Load monitor address into a0
    li a0, 0x80000000
    
    # Write test values
    li a1, 0x11111111
    sw a1, 0(a0)
    
    li a1, 0x22222222
    sw a1, 0(a0)
    
    li a1, 0x33333333
    sw a1, 0(a0)
    
    li a1, 0x44444444
    sw a1, 0(a0)
    
    # Infinite loop
loop:
    li a1, 0xDEADBEEF
    sw a1, 0(a0)
    j loop
