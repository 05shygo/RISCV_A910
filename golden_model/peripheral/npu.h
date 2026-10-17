#include <../include/cpu.h>

// CoralNPU 控制窗口 (0x4000_0000-0x4000_0FFF) 的黄金模型.
//
// 它建模两件事:
//   1. **mySoC/npu_bridge.v 的寄存器堆** —— 忠实地跟 WADDR/WDATA/RADDR/RCMD
//      的语义走, 所以 CPU 程序里把数据写错地方、算错地址这类 bug 会被 difftest
//      抓到 (RTL 和模型对同一次读给出不同的 RDATA).
//   2. **NPU 侧的内容** —— ITCM 用一个影子数组记下 CPU 写进去的东西 (可回读,
//      因此写通路的 bug 也能被抓); DTCM 与 CSR 用固定期望值应答 (模型不跑
//      NPU 的程序, 无从得知真实结果, 只能按"NPU 正确执行后会是什么"来答).
//
// ⚠️ 因此它**不是** NPU 的功能模型 —— 它验证的是 **CPU 侧程序**有没有写对,
//    而不是 NPU 算得对不对. NPU 本身由 tb/npu/tb_npu_loop.sv 直接看信号验证.

uint32_t read_npu(uint32_t rel_addr, AccessMode mode);
void     write_npu(uint32_t rel_addr, AccessMode mode, uint32_t data);
