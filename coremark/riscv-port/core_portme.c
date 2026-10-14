#include "coremark.h"
#include "core_portme.h"

// MONITOR peripheral for output and test control
#define MONITOR_ADDR    ((volatile ee_u32*)0x80000000)
#define TEST_PASS_FLAG  0xDEADBEEF
#define TEST_FAIL_FLAG  0xBADC0DE0

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

// timer_counter 现在是 core_portme.h 里读 TIMER 外设的宏, 见那里说明
static CORETIMETYPE start_time_val, stop_time_val;

void start_time(void) {
    start_time_val = timer_counter;
    // Don't reset counter - we want continuous counting for accurate measurement
}

void stop_time(void) {
    stop_time_val = timer_counter;
}

CORE_TICKS get_time(void) {
    CORE_TICKS elapsed = (CORE_TICKS)(stop_time_val - start_time_val);
    return elapsed;
}

secs_ret time_in_secs(CORE_TICKS ticks) {
    // 1 tick = 1 个周期. 按 1MHz 归一到"秒", 这样
    // Iterations/Sec 与 CoreMark/MHz 数值一致(CoreMark/MHz 本身与频率无关).
    return ticks / 1000000u;
}

ee_u32 default_num_contexts = COREMARK_CONTEXTS;

// ---------------------------------------------------------------------------
// 多 context 的入口 (2026-10-14) —— CoreMark 在 `MULTITHREAD > 1` 时走这对钩子
// (core_main.c:317-321), "怎么并行"由平台层回答。本 port 没有 pthread/fork/socket
// (裸核上没必要), 所以这里就是**顺序**跑: 每个 context 依次调同一个 `iterate()`。
//
//   ⇒ 分数口径要看清: CoreMark 报的是 `default_num_contexts * iterations / 时间`,
//     而时间是 N 个 context **串行**的总时间。所以本 port 的"N 路"提供的是
//     **多 context 的功能/压力覆盖** (N 份独立数据块 + N 份 CRC 都要对, 窗口更宽、
//     重命名/preg 回收的压力更大), **不是**真并行加速比 —— 报告的
//     `Parallel Sequential : N` 那行就是照着这个口径写的。
// ⚠️ 这两个函数在 coremark.h 里只于 `#if (MULTITHREAD > 1)` 下声明 ⇒ 定义也必须挂
//    在同一个条件里。无条件定义会让 MULTITHREAD=1 时多出没人用的函数, 基线二进制的
//    md5 就变了 (顺序核那条 11,438,398 拍的基线要求逐位可复现)。
// ---------------------------------------------------------------------------
#if (MULTITHREAD > 1)
ee_u8 core_start_parallel(core_results *res) {
    iterate(res);
    return 0;
}
ee_u8 core_stop_parallel(core_results *res) {
    (void)res;
    return 0;
}
#endif

void portable_init(core_portable *p, int *argc, char *argv[]) {
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) {
        ee_printf("ERROR: ee_ptr_int size mismatch!\n");
    }
    if (sizeof(ee_u32) != 4) {
        ee_printf("ERROR: ee_u32 must be 32-bit!\n");
    }
    p->portable_id = 1;
}

void portable_fini(core_portable *p) {
    p->portable_id = 0;
}
