#include "onboard.h"

uint32_t digit_value;

uint32_t read_seven_seg(uint32_t rel_addr, AccessMode mode)  {
    // RTL 侧 (perip_bridge.v 的 dig_reg) 是可回读的, 这里保持一致
    Assert(mode == ACCESS_WORD && rel_addr == 0, "Access violation");
    return digit_value;
}

void write_seven_seg(uint32_t rel_addr, AccessMode mode, uint32_t data)  {
    Assert(mode == ACCESS_WORD && rel_addr == 0, "Access violation");
    digit_value = data;
}

uint32_t read_keyboard(uint32_t rel_addr, AccessMode mode)  {
    panic("TODO");
}

void write_keyboard(uint32_t rel_addr, AccessMode mode, uint32_t data)  {
    panic("TODO");
}

uint32_t read_led(uint32_t rel_addr, AccessMode mode)   {
    panic("TODO");
}

void write_led(uint32_t rel_addr, AccessMode mode, uint32_t data)  {
    panic("TODO");
}

uint32_t read_switch(uint32_t rel_addr, AccessMode mode)  {
    panic("TODO");
}

void write_switch(uint32_t rel_addr, AccessMode mode, uint32_t data)  {
    panic("TODO");
}

uint32_t read_button(uint32_t rel_addr, AccessMode mode)  {
    panic("TODO");
}

void write_button(uint32_t rel_addr, AccessMode mode, uint32_t data)  {
    panic("TODO");
}