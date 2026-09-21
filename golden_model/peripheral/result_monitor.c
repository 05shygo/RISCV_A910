#include "result_monitor.h"
#include <stdio.h>
#include <stdlib.h>

extern unsigned long cpu_get_cycle(void);   // from emu.c
extern void cpu_request_halt(int code);     // from emu.c

// 各测试程序用不同的 pass/fail 标志值:
//   coremark/core_portme.c  0xDEADBEEF(pass) / 0xBADC0DE0(fail)
//   coremark/riscv-port/test_end.h, core_main.c 的 sim_end()  0x0000BEEF / 0x0000DEAD
// ee_printf 逐字符写到同一个地址, 字符值都 < 0x100, 不会冲突.
#define IS_PASS_FLAG(v)  ((v) == 0x0000BEEFu || (v) == 0xDEADBEEFu)
#define IS_FAIL_FLAG(v)  ((v) == 0x0000DEADu || (v) == 0xBADC0DE0u)

uint32_t monitor_value_passed;
uint32_t monitor_value_failed;

uint32_t read_monitor(uint32_t rel_addr, AccessMode mode){
    Assert(mode == ACCESS_WORD && !(rel_addr & 0b11), "Access unaligned");
    switch (rel_addr)
    {
    case 0:
        return monitor_value_passed;
    case 4:
        return monitor_value_failed;
    default:
        panic("Access out of bound.");
    }
}

void write_monitor(uint32_t rel_addr, AccessMode mode, uint32_t data) {
    Assert(mode == ACCESS_WORD && !(rel_addr & 0b11), "Access unaligned");

    // 写 pass/fail 标志 = 程序宣告结束. 用这个和 ECALL 并列作为终止条件,
    // 让没有 ECALL 的 CoreMark 也能正常收尾而不是跑到周期上限.
    if (IS_PASS_FLAG(data))      cpu_request_halt(0);
    else if (IS_FAIL_FLAG(data)) cpu_request_halt(1);

    switch (rel_addr)
    {
    case 0:
        monitor_value_passed = data;
        // GM_MONITOR=1 echoes character-at-a-time writes (ee_printf in the
        // CoreMark port writes each char here). The pass/fail flags are all
        // >= 0x100, so anything below that is printable output.
        if (data < 0x100u && getenv("GM_MONITOR") != NULL) {
            fputc((int)data, stdout);
            // Stamp every line with the simulation cycle it was printed on, so
            // a benchmark's own (possibly broken) timing can be cross-checked.
            if (data == '\n') printf("[c=%lu]\n", cpu_get_cycle());
            fflush(stdout);
        }
        break;
    case 4:
        monitor_value_failed = data;
        break;
    default:
        panic("Access out of bound.");
    }
}