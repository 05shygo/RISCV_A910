#ifndef TIMER_H
#define TIMER_H

#include "../include/cpu.h"

// 镜像 mySoC/perip_bridge.v 里的 TIMER 外设:
//   +0x00 mtime[31:0]     只读
//   +0x04 mtime[63:32]    只读
//   +0x08 mtimecmp[31:0]  读写
//   +0x0C mtimecmp[63:32] 读写
uint32_t read_timer(uint32_t rel_addr, AccessMode mode);
void write_timer(uint32_t rel_addr, AccessMode mode, uint32_t data);

// mtime 由 testbench 每个周期从 DUT 的真实寄存器采样后喂进来.
// golden model 是按提交步进的, 自己数不出周期数; 用 DUT 的值可以保证
// 两边按构造一致, 不会因为流水线相位差而误报.
void timer_set_mtime(uint32_t lo, uint32_t hi);

#endif
