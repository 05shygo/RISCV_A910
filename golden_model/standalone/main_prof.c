// ---------------------------------------------------------------------------
// 独立跑黄金模型的**指令画像**驱动 —— 不开 RTL 仿真, 纯 C 解释器跑完整程序.
//
// 为什么可行: 黄金模型本来就是"每个提交执行一条指令"的架构级模型, DPI 只是它的
// 一个驱动方式 (dpi/dpi_shim.c). 外设 (MONITOR/TIMER/NPU) 都注册在模型内部,
// CoreMark 靠写 MONITOR 收尾, 完全不依赖 TB.
//
// 代价: 没有周期概念 —— TIMER 的 mtime 恒 0, 所以 CoreMark 自己打的
// "Average cycles/iteration" 会是 0, **跑分没有意义**. 但指令条数与类型分布
// 与 DUT 退休流逐条一致 (difftest PASS 的前提下), 这正是本工具要的东西.
//
// 编译运行 (见 golden_model/standalone/build_prof.sh):
//     ./gmprof bin/coremark.bin
// ---------------------------------------------------------------------------
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cpu.h"
#include "profile.h"

extern void init_cpu(const char *fname);
extern WB_info cpu_run_once(void);
extern int  cpu_is_halted(void);
extern int  cpu_halt_code(void);
extern void timer_set_mtime(uint32_t lo, uint32_t hi);

int main(int argc, char **argv) {
    // C89: 见 profile.c 顶部那条警告 (VCS 的系统 gcc 4.8.5 默认 gnu90)
    unsigned long n = 1;
    unsigned npc = 0;
    unsigned long *hist;
    unsigned long best;
    unsigned i;
    int bi, k;
    FILE *fp;

    if (argc < 2) {
        fprintf(stderr, "usage: %s <meminit.bin> [dumpfile]\n", argv[0]);
        return 2;
    }

    init_cpu(argv[1]);

    // GM_PROF_TICKS=1: 让 mtime 每退休一条 ++ (纯"假时钟", 只为对齐控制流).
    //
    // 【为什么需要】CoreMark 的收尾报告里有 `if (time_in_secs(total_time) > 0)`
    // 两条分支: 计时器不动时走 `%d` 那条, 动了才走 `%f` 那条 —— 而 DUT 里计时器
    // 是动的. 不补这个假时钟, 独立跑的指令流会比 DUT 少约 1370 条(全是报告代码),
    // 于是"独立跑 = DUT 退休流"这个前提就没法逐条核对.
    //
    // 注意: 这里绝不能触发中断 —— 黄金模型的中断(MTIP)只在 dpi_shim 里由 TB
    // 经 cpu_take_irq() 投递, 本驱动不调它, 所以推 mtime 是"只读值"的纯副作用.
    int fake_ticks = getenv("GM_PROF_TICKS") != NULL;

    while (!cpu_is_halted()) {
        cpu_run_once();
        if (fake_ticks) timer_set_mtime((uint32_t)n, 0);
        if ((++n & 0xFFFFFFul) == 0) {
            fprintf(stderr, "  ... %luM retired\n", n / 1000000ul);
        }
    }

    printf("\n[gmprof] halted, code = %d (0=PASS), retired = %lu\n",
           cpu_halt_code(), gm_prof_total);

    fp = stdout;
    if (argc >= 3) {
        fp = fopen(argv[2], "w");
        if (!fp) { perror("fopen"); return 2; }
    }
    gm_profile_dump(fp);

    // ---- 热点 PC (退休次数最多的地方 = 真正的循环体) ----
    hist = gm_prof_pc_hist(&npc);
    fprintf(fp, "---- 退休次数 Top 20 的 PC ----\n");
    for (k = 0; k < 20; k++) {
        best = 0; bi = -1;
        for (i = 0; i < npc; i++) {
            if (hist[i] > best) { best = hist[i]; bi = (int)i; }
        }
        if (bi < 0 || best == 0) break;
        fprintf(fp, "  pc=0x%05x  %10lu  (%5.2f%%)\n", (unsigned)bi << 2, best,
                100.0 * best / (gm_prof_total ? gm_prof_total : 1));
        hist[bi] = 0;   // 挖掉再找下一个
    }
    if (fp != stdout) fclose(fp);

    return cpu_halt_code();
}
