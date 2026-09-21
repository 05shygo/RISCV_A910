// Minimal DPI shim to reuse existing golden model like Verilator harness
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "cpu.h"
/* Ensure C linkage even if compiled by a C++ compiler */
#ifdef __cplusplus
extern "C" {
#endif

extern void init_cpu(const char*); // from golden model
extern WB_info cpu_run_once();

static int initialized = 0;

// SV side calls gm_init; we forward to existing model init
void gm_init(const char* path_sv) {
  if (!initialized) {
    if (path_sv == NULL) path_sv = "meminit.bin";
    init_cpu(path_sv);
    initialized = 1;
  }
}

// One step per SV clock edge if desired
void cpu_step(int* wb_have_inst, int* wb_pc, int* wb_ena, int* wb_reg, int* wb_value) {
  if (!initialized) return;
  WB_info w = cpu_run_once();
  if (wb_have_inst) *wb_have_inst = w.wb_have_inst;
  if (wb_pc)        *wb_pc        = (int)w.wb_pc;
  if (wb_ena)       *wb_ena       = (int)w.wb_ena;
  if (wb_reg)       *wb_reg       = (int)w.wb_reg;
  if (wb_value)     *wb_value     = (int)w.wb_value;
}

// Optional difftest-style check called from SV with DUT's writeback when valid
int gm_check_step(int dut_wb_have_inst, int dut_wb_pc, int dut_wb_ena, int dut_wb_reg, int dut_wb_value) {
  if (!initialized) return 0;
  if (!dut_wb_have_inst) return 0;
  WB_info ref = cpu_run_once();
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
    return -1;
  }
  return 0;
}

#ifdef __cplusplus
} // extern "C"
#endif

