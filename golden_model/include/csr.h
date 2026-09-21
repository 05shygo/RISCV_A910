#ifndef __CSR_H__
#define __CSR_H__
#include <stdint.h>
#include <stdbool.h>

// golden model 侧的 CSR 文件, 与 mySoC/CSR.v 严格镜像.
// 只保存已实现的位, 未实现位读回恒 0.

uint32_t csr_read(uint32_t addr);
void     csr_write(uint32_t addr, uint32_t data);

bool     csr_is_known(uint32_t addr);
bool     csr_is_readonly(uint32_t addr);

// 陷阱入口: mepc <- epc, mcause <- cause, mtval <- tval,
//            MPIE <- MIE, MIE <- 0
void     csr_trap_entry(uint32_t cause, uint32_t epc, uint32_t tval);
// 中断返回: MIE <- MPIE, MPIE <- 1
void     csr_mret(void);
// 按 mtvec 模式解算陷阱向量: 只有"向量模式且是中断"才加 4*cause
uint32_t csr_trap_vector(uint32_t cause);

#endif
