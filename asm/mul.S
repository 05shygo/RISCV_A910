.section .text.init
.globl _start
_start:
    jal x0, reset_vector

reset_vector:
    # Test MUL: 10 * 7 = 70
    addi x5, x0, 10      # x5 = 10
    addi x6, x0, 7       # x6 = 7
    mul x7, x5, x6       # x7 = 10 * 7 = 70 (0x46)
    
    # Check result
    addi x8, x0, 70      # x8 = 70
    beq x7, x8, test_pass
    
    # Test failed
    addi x10, x0, 1      # a0 = 1 (error code)
    jal x0, end
    
test_pass:
    addi x10, x0, 0      # a0 = 0 (success)
    
end:
    addi x17, x0, 93     # a7 = 93 (exit syscall)
    ecall
    unimp
