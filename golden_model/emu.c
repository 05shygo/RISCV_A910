#include <cpu.h>
#include <csr.h>
#include <debug.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include "peripheral/result_monitor.h"
#include "peripheral/onboard.h"
#include "peripheral/timer.h"

static const char *reg_name[33] = {
  "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
  "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
  "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
  "this_pc"
};

riscv32_CPU_state cpu;
peripheral_descr peripherals[MAX_PERIPHERAL];
uint32_t num_peripherals = 0;
uint32_t memory[MEM_SZ / sizeof(uint32_t)];

extern IF2ID IF(uint32_t);
extern ID2EX ID(IF2ID);
extern EX2MEM EX(ID2EX);
extern MEM2WB MEM(EX2MEM);
extern WB_info WB(MEM2WB);

// ---------------------------------------------------------------------------
// Termination
//
// Test programs end with ECALL and report pass/fail through a0. The DUT's
// Control.v whitelists opcodes for its have_inst signal and does NOT include
// 0x73, so the DUT never presents the ECALL as a commit. A commit-driven
// difftest would therefore never reach it, so we detect it here by peeking at
// the instruction the model is about to execute.
//
// This is sound: the model only advances on a DUT commit, so once cpu.npc
// points at the ECALL the DUT has already retired everything before it.
// ---------------------------------------------------------------------------
static int halted = 0;
static int halt_code = 0;   // 0 = pass (a0 == 0), 1 = fail

static bool is_ecall(uint32_t inst) {
    // SYSTEM opcode with funct3 == PRIV(0) and imm == 0.
    return (inst & 0x7fu) == 0x73u
        && ((inst >> 12) & 0x7u)  == 0u
        && ((inst >> 20) & 0xfffu) == 0u;
}

int cpu_is_halted(void) { return halted; }
int cpu_halt_code(void) { return halt_code; }

// 由外设触发终止: CoreMark 用 sim_end() 死循环写 MONITOR 的 pass/fail 标志来
// 结束(它没有 ECALL), MONITOR 的写回调检测到标志后就调这里.
void cpu_request_halt(int code) {
    halted = 1;
    halt_code = code;
}

// Simulation cycle count, pushed in every cycle by the testbench. The model
// itself is commit-stepped and has no notion of cycles, but the monitor
// peripheral can stamp its output with this for performance measurement.
static unsigned long cur_cycle = 0;
void cpu_set_cycle(unsigned long c) { cur_cycle = c; }
unsigned long cpu_get_cycle(void) { return cur_cycle; }

// Must be polled EVERY cycle, not only on commits. In dpi/dpi_shim.c this call
// must stay AHEAD of the commit gate: the ordering is load-bearing for the
// legacy tests (see the comment there).
//
// mtvec == 0 是"没有装 handler"的哨兵值:
//   陷阱机制实现之后, ecall 在本模型里是一条真正的异常指令(记 mcause/mepc
//   并跳 mtvec). 但现有几十个测试都是以裸 ecall 收尾的, 它们从不写 mtvec,
//   于是这里仍然把这种 ecall 当成"测试结束", 行为与实现陷阱之前完全一致.
//   要测试真正的 ecall 异常, 测试自己先写 mtvec 装 handler 即可 —— 那时
//   mtvec != 0, 这个兼容分支就不会生效, ecall 走正常陷阱路径.
//
// 边界检查是必需的: 有了陷阱之后 cpu.npc 可以是 mtvec/mepc 里的任意值,
// 超出映像范围时 memory[npc>>2] 会越界读.
int cpu_poll_halt(void) {
    if (!halted && cpu.mtvec == 0 && cpu.npc < MEM_SZ
        && is_ecall(memory[cpu.npc >> 2])) {
        halted = 1;
        halt_code = (cpu.gpr[10] == 0) ? 0 : 1;
        color_print("ECALL at PC = 0x%8.8x, Stop now.\n", cpu.npc);
    }
    return halted;
}

// ---------------------------------------------------------------------------
// 定时器中断 (MTIP)
//
// cpu.irq_timer 由 TB 经 gm_set_irq() 每拍推入, 是 DUT 内部那级寄存后的
// timer_int_flag 的【同一个信号】. 这里【不】自己用 mtime/mtimecmp 重算:
// DUT 的 mtimecmp 是时序寄存器而本模型是提交步进的, 自己算必然差拍.
// ---------------------------------------------------------------------------
int cpu_irq_enabled(void) {
    return cpu.irq_timer && cpu.mie_mtie && cpu.mstatus_mie;
}

// 在"无副作用"的提交边界上取中断: 不执行任何指令, 只做陷阱入口.
// mepc 取 CPU 即将执行的那条指令的地址 —— 它正是 DUT 此刻压在 WB 级、
// 还没提交的那条(被 squash 掉, 等 mret 之后重执行).
// 返回 1 表示这一拍的提交被中断吃掉了(调用方不要再去执行指令).
int cpu_take_irq(void) {
    if (halted || !cpu_irq_enabled()) return 0;
    csr_trap_entry(INTR_MTIP_CAUSE, cpu.npc, 0);
    cpu.npc = csr_trap_vector(INTR_MTIP_CAUSE);
    return 1;
}

void cpu_set_irq(int pending) { cpu.irq_timer = pending ? 1u : 0u; }
uint32_t cpu_get_irq(void) { return cpu.irq_timer; }

// Runs exactly one architectural instruction. The caller decides when that
// happens (see dpi/dpi_shim.c: one call per DUT writeback commit), so this
// model stays purely architectural and never models pipeline timing.
WB_info cpu_run_once() {
    WB_info empty = {0};

    if (cpu_poll_halt()) return empty;

    IF2ID inst = IF(cpu.npc);
    ID2EX decode_info = ID(inst);
    EX2MEM ex_info = EX(decode_info);
    MEM2WB mem_info = MEM(ex_info);
    return WB(mem_info);
}

void print_reg_state(){
    color_print("======= REG VALUE =======\n");
    color_print("x[ 0] = 0x00000000\t");
    int i;
    for(i = 1; i < 32; i++) {
        if( (i % 4) == 0 ) printf("\n");
        color_print("x[%2d] = 0x%8.8x\t", i, cpu.gpr[i]);
    }
    printf("\n");
}

void register_peripheral(const char *name, uint32_t base_addr, uint32_t len, PeripheralRCallback callback_r, PeripheralWCallback callback_w){
    color_print("Peripheral name: %s\tbase: 0x%8.8x\taddr len: 0x%8.8x\t\n", name, base_addr, len);
    peripheral_descr new_peripheral;
    new_peripheral.name = name;
    new_peripheral.base_addr = base_addr;
    new_peripheral.len = len;
    new_peripheral.callback_r = callback_r;
    new_peripheral.callback_w = callback_w;
    Assert(num_peripherals < MAX_PERIPHERAL, "Too many peripherals.\n");
    peripherals[num_peripherals++] = new_peripheral;
}

bool is_peripheral(uint32_t addr, size_t* id){
    // Check if the address is in range of peripherals
    // If yes, return id
    // Otherwise return -1
    int i;
    for(i = 0; i < num_peripherals; i++) {
        // 左闭右开, 与 mySoC/perip_bridge.v 的解码范围严格一致
        if(addr >= peripherals[i].base_addr && addr < peripherals[i].base_addr + peripherals[i].len) {
            *id = i;
            return true;
        }
    }
    return false;
}

void init_memory(const char *fname) {
    assert(fname != NULL);
    FILE *fp = fopen(fname, "rb");
    Assert(fp != NULL, "Cannot open file \"%s\"!\n", fname);
    Log("Using file \"%s\" as memory image.\n", fname);
    fseek(fp, 0, SEEK_END);
    long img_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    Assert(img_size > 0, "Memory image \"%s\" is empty.\n", fname);
    Assert(img_size <= MEM_SZ, "Memory image \"%s\" is %ld bytes, exceeds MEM_SZ (%d).\n",
           fname, img_size, MEM_SZ);
    size_t ret = fread(memory, (size_t)img_size, 1, fp);
    assert(ret == 1);
    fclose(fp);
}

void init_cpu(const char *fname) {
    halted = 0;
    halt_code = 0;
    cpu.npc = 0;
    cpu.pc = 0;
    // CSR 复位: 与 CSR.v 的复位值逐位一致 (全 0).
    // 注意 mtvec 必须复位成 0 —— cpu_poll_halt 把 mtvec==0 当作"没装 handler"
    // 的哨兵, 现有测试全靠它保持旧的 ecall 收尾行为.
    cpu.mstatus_mie  = 0;
    cpu.mstatus_mpie = 0;
    cpu.mie_mtie     = 0;
    cpu.mtvec        = 0;
    cpu.mscratch     = 0;
    cpu.mepc         = 0;
    cpu.mcause       = 0;
    cpu.mtval        = 0;
    cpu.mcycle       = 0;
    cpu.minstret     = 0;
    cpu.irq_timer    = 0;
    register_peripheral("MONITOR", 0x80000000, 0x8,   read_monitor,    write_monitor);
    register_peripheral("Digit",   0xFFFFF000, 0x4,   read_seven_seg,  write_seven_seg);
    register_peripheral("TIMER",   0xFFFFF040, 0x10,  read_timer,      write_timer);
    init_memory(fname);
}
