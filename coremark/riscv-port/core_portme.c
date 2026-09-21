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

ee_u32 default_num_contexts = 1;

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
