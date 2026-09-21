#ifndef CORE_PORTME_H
#define CORE_PORTME_H

// Configuration for bare-metal RISC-V
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0

#define COMPILER_VERSION "RISCV-GCC"
#define COMPILER_FLAGS "-O2 -march=rv32i -mabi=ilp32"
#define MEM_LOCATION "STACK"

// Data types
typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;
typedef unsigned int   ee_size_t;

#define NULL ((void *)0)
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

// Timer configuration
#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

// Cycle counter: mySoC/perip_bridge.v 里的 TIMER 外设 (mtime, 每拍 +1).
// 之前 timer_counter 是个从没被赋值过的变量, 导致所有计时恒为 0.
// 改成直接读 MMIO 后, get_vtimer()/start_time()/stop_time()/get_time()
// 整条链都拿到真实周期数.
#define CM_TIMER_ADDR  0xFFFFF040u
#define timer_counter  (*(volatile ee_u32 *)CM_TIMER_ADDR)

// Seed and memory method
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STACK

// Single thread
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0

#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

// Use smaller data size for bare-metal
#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#define VALIDATION_RUN 1
#endif

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */
