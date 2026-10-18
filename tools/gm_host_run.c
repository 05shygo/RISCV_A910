// 主机侧黄金模型自测入口.
//
// 直接跑 DUT 变体的 .bin (链接在 0, 末尾 a7=93; ecall, mtvec==0) 直到
// cpu_poll_halt() 停机, 用程序自己的 rvv_status/rvv_a0 判定每条向量用例.
// 这一步不需要 VCS/DUT, 用来先把 C 语义调对.
//
// 用法:
//   gm_host_run <bin> [max_inst] [progress_addr phase_addr status_addr a0_addr ncases]
//
// 返回 0 = 全部通过 (a0 == 0), 1 = 自检失败, 2 = 没跑到 ECALL.

#include <cpu.h>
#include <rvv.h>
#include <stdio.h>
#include <stdlib.h>

extern riscv32_CPU_state cpu;
extern uint32_t memory[];
extern void init_cpu(const char *fname);
extern WB_info cpu_run_once(void);
extern int cpu_is_halted(void);
extern int cpu_halt_code(void);

static uint32_t read_word(uint32_t addr) {
  if (addr + 4 > MEM_SZ) return 0;
  return memory[addr >> 2];
}

int main(int argc, char **argv) {
  const char *bin;
  long max_inst = 20000000;
  long n = 0;
  uint32_t progress_addr = 0, phase_addr = 0, status_addr = 0, a0_addr = 0;
  int have_manifest = 0, ncases = 0, i;

  if (argc < 2) {
    fprintf(stderr, "usage: %s <bin> [max_inst] [progress phase status a0 ncases]\n",
            argv[0]);
    return 2;
  }
  bin = argv[1];
  if (argc > 2) max_inst = atol(argv[2]);
  if (argc >= 8) {
    progress_addr = (uint32_t)strtoul(argv[3], NULL, 0);
    phase_addr    = (uint32_t)strtoul(argv[4], NULL, 0);
    status_addr   = (uint32_t)strtoul(argv[5], NULL, 0);
    a0_addr       = (uint32_t)strtoul(argv[6], NULL, 0);
    ncases        = atoi(argv[7]);
    have_manifest = 1;
  }

  init_cpu(bin);

  {
    const char *tr = getenv("GM_HOST_TRACE");
    while (!cpu_is_halted() && n < max_inst) {
      uint32_t epc = cpu.npc;
      uint32_t einst = (epc + 4 <= MEM_SZ) ? memory[epc >> 2] : 0;
      cpu_run_once();
      if (tr && n < 5000)
        fprintf(stdout, "[%4ld] pc=0x%08x inst=0x%08x -> npc=0x%08x\n",
                n, epc, einst, cpu.npc);
      n++;
    }
  }

  fprintf(stdout, "GM_HOST: halted=%d code=%d inst=%ld pc=0x%08x a0=0x%08x vl=%u vtype=0x%x\n",
          cpu_is_halted(), cpu_halt_code(), (long)cpu.minstret,
          cpu.pc, cpu.gpr[10], cpu.vec.vl, cpu.vec.vtype);

  if (have_manifest) {
    fprintf(stdout, "GM_HOST: progress=%u phase=%u\n",
            read_word(progress_addr), read_word(phase_addr));
    for (i = 0; i < ncases; i++) {
      uint32_t st = read_word(status_addr + (uint32_t)i * 4u);
      if (st != 0) fprintf(stdout, "GM_STATUS: %d %u\n", i, st);
    }
    fprintf(stdout, "GM_HOST: a0_slot=0x%08x\n", read_word(a0_addr));
  }

  {
    const char *dump = getenv("GM_DUMP");   // "addr:nwords[,addr:nwords...]"
    while (dump && *dump) {
      uint32_t addr = (uint32_t)strtoul(dump, (char **)&dump, 0);
      long nw = 0;
      int k;
      if (*dump == ':') { dump++; nw = atol(dump); }
      while (*dump && *dump != ',') dump++;
      if (*dump == ',') dump++;
      for (k = 0; k < nw; k++)
        fprintf(stdout, "GM_MEM[0x%08x] = 0x%08x\n",
                addr + (uint32_t)k * 4u, read_word(addr + (uint32_t)k * 4u));
    }
  }

  if (!cpu_is_halted()) {
    fprintf(stderr, "GM_HOST: TIMEOUT (no ECALL within %ld instructions)\n", max_inst);
    return 2;
  }
  return (cpu_halt_code() == 0) ? 0 : 1;
}
