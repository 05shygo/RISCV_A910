#include <cpu.h>
#include <csr.h>

extern riscv32_CPU_state cpu;

// mstatus 读回: MPP[12:11] 恒 2'b11 (本核只有 M 模式), 其余未实现位为 0.
// 与 mySoC/CSR.v 里的 mstatus_rdata 拼接顺序必须完全一致.
uint32_t csr_mstatus_rdata(void) {
    return (3u << 11)
         | (cpu.mstatus_mpie << MSTATUS_MPIE_BIT)
         | (cpu.mstatus_mie  << MSTATUS_MIE_BIT);
}

bool csr_is_known(uint32_t a) {
    switch (a) {
        case CSR_MSTATUS: case CSR_MIE:     case CSR_MTVEC:     case CSR_MSCRATCH:
        case CSR_MEPC:    case CSR_MCAUSE:  case CSR_MTVAL:     case CSR_MIP:
        case CSR_MCYCLE:  case CSR_MCYCLEH: case CSR_MINSTRET:  case CSR_MINSTRETH:
        case CSR_CYCLE:   case CSR_CYCLEH:  case CSR_INSTRET:   case CSR_INSTRETH:
            return true;
        default:
            return false;
    }
}

// 只读: mip 的 MTIP 由硬件驱动, 所有计数器都由硬件驱动.
// 对它们"尝试写" -> 非法指令; 但 csrrs rd, csr, x0 (纯读) 仍然合法.
bool csr_is_readonly(uint32_t a) {
    switch (a) {
        case CSR_MIP:
        case CSR_MCYCLE:  case CSR_MCYCLEH: case CSR_MINSTRET:  case CSR_MINSTRETH:
        case CSR_CYCLE:   case CSR_CYCLEH:  case CSR_INSTRET:   case CSR_INSTRETH:
            return true;
        default:
            return false;
    }
}

uint32_t csr_read(uint32_t addr) {
    switch (addr) {
        case CSR_MSTATUS:   return csr_mstatus_rdata();
        case CSR_MIE:       return cpu.mie_mtie << MIE_MTIE_BIT;
        // bit1 恒 0, bit0 是模式位
        case CSR_MTVEC:     return (cpu.mtvec & ~0x3u) | (cpu.mtvec & 1u);
        case CSR_MSCRATCH:  return cpu.mscratch;
        case CSR_MEPC:      return cpu.mepc;
        case CSR_MCAUSE:    return cpu.mcause;
        case CSR_MTVAL:     return cpu.mtval;
        // mip[7] 直接跟随已寄存的定时器中断电平
        case CSR_MIP:       return cpu.irq_timer ? (1u << MIE_MTIE_BIT) : 0u;
        case CSR_MCYCLE:
        case CSR_CYCLE:     return (uint32_t)cpu.mcycle;
        case CSR_MCYCLEH:
        case CSR_CYCLEH:    return (uint32_t)(cpu.mcycle >> 32);
        case CSR_MINSTRET:
        case CSR_INSTRET:   return (uint32_t)cpu.minstret;
        case CSR_MINSTRETH:
        case CSR_INSTRETH:  return (uint32_t)(cpu.minstret >> 32);
        default:            return 0;
    }
}

void csr_write(uint32_t addr, uint32_t data) {
    switch (addr) {
        case CSR_MSTATUS:
            cpu.mstatus_mie  = (data >> MSTATUS_MIE_BIT)  & 1u;
            cpu.mstatus_mpie = (data >> MSTATUS_MPIE_BIT) & 1u;
            break;
        case CSR_MIE:      cpu.mie_mtie = (data >> MIE_MTIE_BIT) & 1u; break;
        case CSR_MTVEC:    cpu.mtvec    = (data & ~0x3u) | (data & 1u); break;
        case CSR_MSCRATCH: cpu.mscratch = data; break;
        case CSR_MEPC:     cpu.mepc     = data & ~0x3u; break;
        case CSR_MCAUSE:   cpu.mcause   = data; break;
        case CSR_MTVAL:    cpu.mtval    = data; break;
        default: break;   // 只读 / 未实现: Control 侧已判成非法指令, 这里不再写
    }
}

void csr_trap_entry(uint32_t cause, uint32_t epc, uint32_t tval) {
    // 注意: 陷阱入口【不】对 epc 做对齐掩码 (与 CSR.v 的 mepc <= trap_epc_i 一致)
    cpu.mepc         = epc;
    cpu.mcause       = cause;
    cpu.mtval        = tval;
    cpu.mstatus_mpie = cpu.mstatus_mie;   // MPIE <- 旧的 MIE
    cpu.mstatus_mie  = 0;                 // 关中断, 防止电平型 MTIP 反复触发
}

void csr_mret(void) {
    cpu.mstatus_mie  = cpu.mstatus_mpie;  // MIE <- MPIE
    cpu.mstatus_mpie = 1;
}

uint32_t csr_trap_vector(uint32_t cause) {
    uint32_t base = cpu.mtvec & ~0x3u;
    // 只有"向量模式 + 中断"才加偏移; 异常在向量模式下也走基址
    if ((cpu.mtvec & 1u) && (cause >> 31))
        return base + ((cause & 0xfu) << 2);
    return base;
}
