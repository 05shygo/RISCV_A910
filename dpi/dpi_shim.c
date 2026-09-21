// DPI shim exposing the golden model to the SystemVerilog testbench.
//
// Pacing: the golden model is COMMIT-DRIVEN. The testbench calls
// gm_check_step() every clock, but the reference advances exactly one
// architectural instruction only on the cycles where the DUT reports a valid
// writeback (dut_wb_have_inst). Gating the advance -- not just the comparison
// -- is what keeps the two in sync: the 5-stage DUT retires an instruction
// every varying number of cycles (pipeline fill, load-use stalls, multi-cycle
// MUL/DIV, branch flushes), so stepping the reference per-cycle would drift by
// however many cycles the DUT failed to retire on.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cpu.h"
#include "csr.h"

/* Ensure C linkage even if compiled by a C++ compiler */
#ifdef __cplusplus
extern "C" {
#endif

extern void init_cpu(const char*);   // from golden model
extern WB_info cpu_run_once(void);
extern int cpu_is_halted(void);
extern int cpu_halt_code(void);
extern int cpu_poll_halt(void);
extern void cpu_set_cycle(unsigned long);
extern void timer_set_mtime(uint32_t lo, uint32_t hi);
extern int  cpu_take_irq(void);
extern void cpu_set_irq(int pending);
extern uint32_t memory[];            // meminit.bin image, indexed by word

static int initialized = 0;

// SV side calls gm_init; we forward to existing model init
void gm_init(const char* path_sv) {
  if (!initialized) {
    if (path_sv == NULL) path_sv = "meminit.bin";
    init_cpu(path_sv);
    initialized = 1;
  }
}

// Push the current simulation cycle into the model, for monitor output
// timestamping. Called every cycle -- the model is commit-stepped, so it has
// no other way to know the cycle number.
void gm_set_cycle(int c) {
  cpu_set_cycle((unsigned long)c);
}

// Push the TIMER's mtime. The testbench samples the DUT's real mtime register
// and delays it to match the pipeline phase at which the reference executes the
// instruction that read it (see tb_miniRV_dpi.sv).
void gm_set_timer(int lo, int hi) {
  timer_set_mtime((uint32_t)lo, (uint32_t)hi);
}

// Push the timer interrupt pending level. The testbench samples the DUT's own
// registered copy of timer_int_flag, so both sides act on the bit-identical
// signal -- the model must NOT recompute it from mtime/mtimecmp (the DUT's
// mtimecmp is a timing register, and this model is commit-stepped).
void gm_set_irq(int pending) {
  cpu_set_irq(pending);
}

// Compare the DUT's CSR file against the model's. Called once per commit, but
// ONLY on cycles where the DUT reports no redirect: a trap's own mepc/mcause/
// mstatus writes land on that same clock edge, while the model applies them
// inside gm_check_step(), so comparing on a redirect cycle would always differ.
// For ordinary csrr* the DUT writes in EX (>=2 cycles before the commit) while
// the model writes at the commit itself, so at a commit boundary both already
// hold the new value.
int gm_check_csr(int dut_mstatus, int dut_mie, int dut_mtvec, int dut_mscratch,
                 int dut_mepc, int dut_mcause, int dut_mtval, int dut_mip) {
  if (!initialized) return 0;
  struct { const char *name; uint32_t dut; uint32_t ref; } t[] = {
    { "mstatus",  (uint32_t)dut_mstatus,  csr_read(CSR_MSTATUS)  },
    { "mie",      (uint32_t)dut_mie,      csr_read(CSR_MIE)      },
    { "mtvec",    (uint32_t)dut_mtvec,    csr_read(CSR_MTVEC)    },
    { "mscratch", (uint32_t)dut_mscratch, csr_read(CSR_MSCRATCH) },
    { "mepc",     (uint32_t)dut_mepc,     csr_read(CSR_MEPC)     },
    { "mcause",   (uint32_t)dut_mcause,   csr_read(CSR_MCAUSE)   },
    { "mtval",    (uint32_t)dut_mtval,    csr_read(CSR_MTVAL)    },
    { "mip",      (uint32_t)dut_mip,      csr_read(CSR_MIP)      },
  };
  unsigned i;
  int fail = 0;
  for (i = 0; i < sizeof(t) / sizeof(t[0]); i++)
    if (t[i].dut != t[i].ref) fail = 1;
  if (!fail) return 0;

  fprintf(stderr, "=========== CSR Difference ===========\n");
  fprintf(stderr, "%-10s\t%-12s\t%-12s\n", "CSR", "REFERENCE", "MYCPU");
  for (i = 0; i < sizeof(t) / sizeof(t[0]); i++)
    if (t[i].dut != t[i].ref)
      fprintf(stderr, "%-10s\t0x%08x\t0x%08x\n", t[i].name, t[i].ref, t[i].dut);
  return -1;
}

// Termination: the model halts when it reaches the ECALL that ends the test.
int gm_halted(void) {
  return initialized ? cpu_is_halted() : 0;
}

// 0 = pass (a0 == 0), 1 = fail.
int gm_exit_code(void) {
  return initialized ? cpu_halt_code() : 0;
}

// Print the raw instruction word at a PC, so a mismatch report shows what the
// DUT was actually retiring. Guards the image bounds -- the DUT can report a
// PC past the end of meminit.bin.
static void print_inst_at(const char *who, uint32_t pc) {
  if (pc + 4 > MEM_SZ) {
    fprintf(stderr, "  %-9s PC=0x%08x  <outside image>\n", who, pc);
    return;
  }
  fprintf(stderr, "  %-9s PC=0x%08x  inst=0x%08x\n", who, pc, memory[pc >> 2]);
}

int gm_check_step(int dut_wb_have_inst, int dut_wb_pc, int dut_wb_ena, int dut_wb_reg,
                  int dut_wb_value, int dut_wb_irq_safe) {
  if (!initialized) return 0;

  // Poll termination every cycle. This must sit OUTSIDE (and AHEAD of) the
  // commit gate below: the legacy tests end with a bare ECALL whose terminating
  // effect is reported by this poll, so reordering these two statements silently
  // breaks every one of them.
  if (cpu_poll_halt()) return 0;

  // DUT is not retiring an instruction this cycle: hold the reference still.
  if (!dut_wb_have_inst) return 0;

  // Timer interrupt. The check sits INSIDE the commit gate on purpose: the DUT
  // only takes MTIP at a commit point (its WB stage carries an instruction), so
  // during a load-use / muldiv stall its WB holds a bubble and no interrupt is
  // taken. Polling every cycle like cpu_poll_halt() would make the model take
  // the interrupt a few cycles early and desync.
  //
  // dut_wb_irq_safe is the DUT's own "this retiring instruction has no
  // side effect that already happened" bit (not a store, not a CSR write).
  // Squashing an instruction that already stored or wrote a CSR would make the
  // two sides diverge permanently, so both refuse to take MTIP there.
  if (dut_wb_irq_safe && cpu_take_irq()) return 0;

  // Advance the reference by exactly one architectural instruction.
  WB_info ref = cpu_run_once();

  // GM_TRACE=1 dumps every commit side by side, for diagnosing DUT bugs.
  if (getenv("GM_TRACE")) {
    static long n = 0;
    fprintf(stderr, "[c%03ld] DUT pc=0x%08x ena=%d reg=%2d val=0x%08x | REF pc=0x%08x ena=%d reg=%2d val=0x%08x\n",
            ++n, (unsigned)dut_wb_pc, dut_wb_ena, dut_wb_reg, (unsigned)dut_wb_value,
            ref.wb_pc, ref.wb_ena, ref.wb_reg, ref.wb_value);
  }

  // cpu_run_once() may have just halted (ECALL is never executed); nothing to
  // compare against in that case.
  if (cpu_is_halted()) return 0;

  int fail = 0;
  if ((int)ref.wb_pc != dut_wb_pc) fail = 1;
  if ((int)ref.wb_ena != dut_wb_ena) fail = 1;
  if (dut_wb_ena) {
    if ((int)ref.wb_reg != dut_wb_reg || (int)ref.wb_value != dut_wb_value) fail = 1;
  }
  if (fail) {
    fprintf(stderr, "=========== Diffrence ===========\n");
    fprintf(stderr, "SIGNAL NAME\tREFERENCE\tMYCPU\n");
    fprintf(stderr, "debug_wb_pc\t0x%08x\t0x%08x\n", ref.wb_pc, (unsigned)dut_wb_pc);
    fprintf(stderr, "debug_wb_ena\t%10d\t%10d\n", ref.wb_ena, dut_wb_ena);
    fprintf(stderr, "debug_wb_reg\t%10d\t%10d\n", ref.wb_reg, dut_wb_reg);
    fprintf(stderr, "debug_wb_value\t0x%08x\t0x%08x\n", ref.wb_value, (unsigned)dut_wb_value);
    fprintf(stderr, "--- instruction at each reported PC ---\n");
    print_inst_at("reference", ref.wb_pc);
    print_inst_at("mycpu", (uint32_t)dut_wb_pc);
    return -1;
  }
  return 0;
}

#ifdef __cplusplus
} // extern "C"
#endif
