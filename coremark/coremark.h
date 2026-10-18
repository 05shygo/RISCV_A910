/*
Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Original Author: Shay Gal-on
*/

/* Topic: Description
        This file contains  declarations of the various benchmark functions.
*/

/* Configuration: TOTAL_DATA_SIZE
        Define total size for data algorithms will operate on
*/
#ifndef TOTAL_DATA_SIZE
#define TOTAL_DATA_SIZE 2 * 1000
#endif

#define SEED_ARG      0
#define SEED_FUNC     1
#define SEED_VOLATILE 2

#define MEM_STATIC 0
#define MEM_MALLOC 1
#define MEM_STACK  2

#include "core_portme.h"

/* ---------------------------------------------------------------------------
 * CoreMark RVV bring-up（编译器规避路线, 2026-10-18）
 *
 * GCC 14 自动向量化会把少数函数编成 A910 向量融合层不支持的形态:
 *   vmv.x.s / vmv.s.x（归约回标量）、vid.v、vrgather、整寄存器 spill
 *   (vs1r/vl1r/vl1re*) 以及被 RvvFrontEnd 判 vill 的 e16,mf4 / e8,mf8 vset。
 * 相应函数在这里逐个关掉向量化, 其余函数保留自动向量化。
 *
 * ⚠️ 只有 RVV 构建定义 COREMARK_RVV。标量构建下宏展开为空, 源码语义与
 *    代码生成都不变 —— bin/coremark.bin 必须逐位一致（用 cmp 验证）。
 * ------------------------------------------------------------------------- */
#if defined(COREMARK_RVV) && COREMARK_RVV
/* ⚠️ optimize 属性会把该函数的编译选项切到"命令行基线 + 这里列出的项",
 *    且**不接受 -fno-builtin**。对 number()（ee_printf.c）这种含清零循环的
 *    函数, 这会把它改写成 memset 而本 port 是 -nostdlib ⇒ 该文件改用整文件
 *    -fno-tree-vectorize（见 Makefile.coremark_rvv）, 不用这个属性。 */
#define CM_NO_VECTORIZE __attribute__((optimize("no-tree-vectorize")))
#else
#define CM_NO_VECTORIZE
#endif

#if HAS_STDIO
#include <stdio.h>
#endif
#if HAS_PRINTF
#define ee_printf printf
#endif

/* Actual benchmark execution in iterate */
void *iterate(void *pres);

/* Typedef: secs_ret
        For machines that have floating point support, get number of seconds as
   a double. Otherwise an unsigned int.
*/
#if HAS_FLOAT
typedef double secs_ret;
#else
typedef ee_u32 secs_ret;
#endif

#if MAIN_HAS_NORETURN
#define MAIN_RETURN_VAL
#define MAIN_RETURN_TYPE void
#else
#define MAIN_RETURN_VAL  0
#define MAIN_RETURN_TYPE int
#endif

void       start_time(void);
void       stop_time(void);
CORE_TICKS get_time(void);
secs_ret   time_in_secs(CORE_TICKS ticks);

/* Misc useful functions */
ee_u16 crcu8(ee_u8 data, ee_u16 crc);
ee_u16 crc16(ee_s16 newval, ee_u16 crc);
ee_u16 crcu16(ee_u16 newval, ee_u16 crc);
ee_u16 crcu32(ee_u32 newval, ee_u16 crc);
ee_u8  check_data_types(void);
void * portable_malloc(ee_size_t size);
void   portable_free(void *p);
ee_s32 parseval(char *valstring);

/* Algorithm IDS */
#define ID_LIST             (1 << 0)
#define ID_MATRIX           (1 << 1)
#define ID_STATE            (1 << 2)
#define ALL_ALGORITHMS_MASK (ID_LIST | ID_MATRIX | ID_STATE)
#define NUM_ALGORITHMS      3

/* list data structures */
typedef struct list_data_s
{
    ee_s16 data16;
    ee_s16 idx;
} list_data;

typedef struct list_head_s
{
    struct list_head_s *next;
    struct list_data_s *info;
} list_head;

/*matrix benchmark related stuff */
#define MATDAT_INT 1
#if MATDAT_INT
typedef ee_s16 MATDAT;
typedef ee_s32 MATRES;
#else
typedef ee_f16 MATDAT;
typedef ee_f32 MATRES;
#endif

typedef struct MAT_PARAMS_S
{
    int     N;
    MATDAT *A;
    MATDAT *B;
    MATRES *C;
} mat_params;

/* state machine related stuff */
/* List of all the possible states for the FSM */
typedef enum CORE_STATE
{
    CORE_START = 0,
    CORE_INVALID,
    CORE_S1,
    CORE_S2,
    CORE_INT,
    CORE_FLOAT,
    CORE_EXPONENT,
    CORE_SCIENTIFIC,
    NUM_CORE_STATES
} core_state_e;

/* Helper structure to hold results */
typedef struct RESULTS_S
{
    /* inputs */
    ee_s16              seed1;       /* Initializing seed */
    ee_s16              seed2;       /* Initializing seed */
    ee_s16              seed3;       /* Initializing seed */
    void *              memblock[4]; /* Pointer to safe memory location */
    ee_u32              size;        /* Size of the data */
    ee_u32              iterations;  /* Number of iterations to execute */
    ee_u32              execs;       /* Bitmask of operations to execute */
    struct list_head_s *list;
    mat_params          mat;
    /* outputs */
    ee_u16 crc;
    ee_u16 crclist;
    ee_u16 crcmatrix;
    ee_u16 crcstate;
    ee_s16 err;
    /* ultithread specific */
    core_portable port;
} core_results;

/* Multicore execution handling */
#if (MULTITHREAD > 1)
ee_u8 core_start_parallel(core_results *res);
ee_u8 core_stop_parallel(core_results *res);
#endif

/* list benchmark functions */
list_head *core_list_init(ee_u32 blksize, list_head *memblock, ee_s16 seed);
ee_u16     core_bench_list(core_results *res, ee_s16 finder_idx);

/* state benchmark functions */
void   core_init_state(ee_u32 size, ee_s16 seed, ee_u8 *p);
ee_u16 core_bench_state(ee_u32 blksize,
                        ee_u8 *memblock,
                        ee_s16 seed1,
                        ee_s16 seed2,
                        ee_s16 step,
                        ee_u16 crc);

/* matrix benchmark functions */
ee_u32 core_init_matrix(ee_u32      blksize,
                        void *      memblk,
                        ee_s32      seed,
                        mat_params *p);
ee_u16 core_bench_matrix(mat_params *p, ee_s16 seed, ee_u16 crc);
