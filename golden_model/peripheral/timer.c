#include "timer.h"

static uint32_t mtime_lo = 0;
static uint32_t mtime_hi = 0;
static uint32_t mtimecmp_lo = 0;
static uint32_t mtimecmp_hi = 0;

void timer_set_mtime(uint32_t lo, uint32_t hi) {
    mtime_lo = lo;
    mtime_hi = hi;
}

uint32_t read_timer(uint32_t rel_addr, AccessMode mode) {
    Assert(mode == ACCESS_WORD, "Timer access must be a word access");
    switch (rel_addr) {
        case 0:  return mtime_lo;
        case 4:  return mtime_hi;
        case 8:  return mtimecmp_lo;
        case 12: return mtimecmp_hi;
        default: panic("Access out of bound.");
    }
}

void write_timer(uint32_t rel_addr, AccessMode mode, uint32_t data) {
    Assert(mode == ACCESS_WORD, "Timer access must be a word access");
    switch (rel_addr) {
        case 0:  break;                 // mtime 只读, 写被忽略(与 RTL 一致)
        case 4:  break;
        case 8:  mtimecmp_lo = data; break;
        case 12: mtimecmp_hi = data; break;
        default: panic("Access out of bound.");
    }
}
