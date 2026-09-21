#include <cpu.h>
#include <csr.h>
extern riscv32_CPU_state cpu;
WB_info WB(MEM2WB mem_info) {
    WB_info ret;
    ret.wb_have_inst = 1;
    if(mem_info.branch_taken) {
        cpu.npc = mem_info.target_pc;
    }
    uint32_t wb_val = 0;
    int trapped = mem_info.exc_valid;
    // 同步异常: 该指令【不写 rd】, 而是记 CSR 并跳到陷阱向量.
    // 与 DUT 一致 —— DUT 那边陷阱指令照样发一个提交脉冲(所以 golden model
    // 也要"执行"它), 但 wb_ena 被强制为 0.
    if(!trapped && mem_info.wb_en) {
        switch(mem_info.wb_sel) {
            case WB_ALU: wb_val = mem_info.alu_out; break;
            case WB_PC: wb_val = mem_info.pc + 4; break;
            case WB_LOAD: wb_val = mem_info.load_out; break;
            default: wb_val = 0; break;
        }
        cpu.gpr[mem_info.dst] = wb_val;
    }
    if(trapped) {
        // mepc = 陷阱指令自己的地址 (与 DUT 的 mepc = pc_WB 一致)
        csr_trap_entry(mem_info.exc_cause, mem_info.pc, mem_info.exc_tval);
        cpu.npc = csr_trap_vector(mem_info.exc_cause);
    } else if(mem_info.is_mret) {
        cpu.npc = cpu.mepc;
        csr_mret();
    }
    ret.wb_value = wb_val;
    ret.wb_ena = mem_info.wb_en && !trapped;
    ret.wb_pc = mem_info.pc;
    ret.wb_reg = mem_info.dst;
    cpu.gpr[0] = 0;
    // 计数器只保证单调 (difftest 不比较它们: 周期数是环境状态,
    // 提交步进的 golden model 算不出 DUT 的真实周期数)
    cpu.mcycle++;
    cpu.minstret++;
    Log("WB Stage:");
    Log("PC = %8.8x", mem_info.pc);
    if(mem_info.wb_en) {
        Log("WB value = %8.8x, WReg = %d, npc = 0x%8.8x", wb_val, mem_info.dst, cpu.npc);
    }
    if(mem_info.branch_taken) {
        Log("Branch Taken, target is %8.8x", mem_info.target_pc);
    }
    return ret;
}
