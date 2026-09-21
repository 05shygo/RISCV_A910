#include <stdio.h>
#include <cpu.h>
extern riscv32_CPU_state cpu;
extern uint32_t memory[];

IF2ID IF(uint32_t npc) {
    IF2ID ret;
    // 越界取指【不能】用 Assert 崩掉仿真进程: 宿主崩溃不是任何合法的架构
    // 行为, 而且 memory[] 只有 16K 个字, npc>>2 越界会直接段错误.
    // 这里给 0 占位, 真正的处理是 ID 级把它判成 instruction access fault
    // (cause 1) —— 与 DUT 的 id_inst_oob 对应.
    ret.inst = (npc < MEM_SZ) ? memory[npc >> 2] : 0u;
    ret.pc = npc;
    cpu.pc = npc;
    Log("\n=====");
    Log("Fetched instruction 0x%8.8x at PC=0x%8.8x", ret.inst, ret.pc);
    cpu.npc = cpu.pc + 4;
    return ret;
}
