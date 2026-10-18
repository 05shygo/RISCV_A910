    # 自动生成 by tests/rvv/gen_sweep.py —— 不要手改
.section .text.init
.globl _start
_start:
    add  a0, x0, x0
    la   s0, rvv_progress
    la   s1, rvv_phase
    # ---- case 0: vmul.vv e32 ----
    li   t0, 0
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vmul.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+0
    vse32.v v5, (t1)

    # ---- case 1: vmul.vx e32 ----
    li   t0, 1
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vmul.vx v5, v1, a1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+64
    vse32.v v5, (t1)

    # ---- case 2: vmulhu.vv e32 ----
    li   t0, 2
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vmulhu.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+128
    vse32.v v5, (t1)

    # ---- case 3: vmulhu.vx e32 ----
    li   t0, 3
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vmulhu.vx v5, v1, a1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+192
    vse32.v v5, (t1)

    # ---- case 4: vmulh.vv e32 ----
    li   t0, 4
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vmulh.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+256
    vse32.v v5, (t1)

    # ---- case 5: vmulh.vx e32 ----
    li   t0, 5
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vmulh.vx v5, v1, a1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+320
    vse32.v v5, (t1)

    # ---- case 6: vmulhsu.vv e32 ----
    li   t0, 6
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vmulhsu.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+384
    vse32.v v5, (t1)

    # ---- case 7: vmulhsu.vx e32 ----
    li   t0, 7
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vmulhsu.vx v5, v1, a1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+448
    vse32.v v5, (t1)

    # ---- case 8: vmul.vv e8 ----
    li   t0, 8
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 16, e8, m1, tu, mu
    la t1, rvv_in_a8
    vle8.v v1, (t1)
    la t1, rvv_in_b8
    vle8.v v2, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vmul.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+512
    vse32.v v5, (t1)

    # ---- case 9: vmul.vv e16 ----
    li   t0, 9
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 8, e16, m1, tu, mu
    la t1, rvv_in_a16
    vle16.v v1, (t1)
    la t1, rvv_in_b16
    vle16.v v2, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vmul.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+576
    vse32.v v5, (t1)

    # ---- case 10: vmacc.vv e32 ----
    li   t0, 10
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    la t1, rvv_in_c32
    vle32.v v5, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vmacc.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+640
    vse32.v v5, (t1)

    # ---- case 11: vmacc.vx e32 ----
    li   t0, 11
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    la t1, rvv_in_c32
    vle32.v v5, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vmacc.vx v5, a1, v1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+704
    vse32.v v5, (t1)

    # ---- case 12: vmadd.vv e32 ----
    li   t0, 12
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    la t1, rvv_in_c32
    vle32.v v5, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vmadd.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+768
    vse32.v v5, (t1)

    # ---- case 13: vmadd.vx e32 ----
    li   t0, 13
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    la t1, rvv_in_c32
    vle32.v v5, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vmadd.vx v5, a1, v1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+832
    vse32.v v5, (t1)

    # ---- case 14: vnmsac.vv e32 ----
    li   t0, 14
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    la t1, rvv_in_c32
    vle32.v v5, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vnmsac.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+896
    vse32.v v5, (t1)

    # ---- case 15: vnmsac.vx e32 ----
    li   t0, 15
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    la t1, rvv_in_c32
    vle32.v v5, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vnmsac.vx v5, a1, v1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+960
    vse32.v v5, (t1)

    # ---- case 16: vnmsub.vv e32 ----
    li   t0, 16
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    la t1, rvv_in_c32
    vle32.v v5, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vnmsub.vv v5, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+1024
    vse32.v v5, (t1)

    # ---- case 17: vnmsub.vx e32 ----
    li   t0, 17
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_in_a32
    vle32.v v1, (t1)
    la t1, rvv_in_b32
    vle32.v v2, (t1)
    la t1, rvv_in_c32
    vle32.v v5, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vnmsub.vx v5, a1, v1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+1088
    vse32.v v5, (t1)

    # ---- case 18: vwmulu.vv e8 ----
    li   t0, 18
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v6, 5
    vmv.v.i v7, 5
    vsetivli x0, 16, e8, m1, tu, mu
    la t1, rvv_in_a8
    vle8.v v1, (t1)
    la t1, rvv_in_b8
    vle8.v v2, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vwmulu.vv v6, v1, v2
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+1152
    vse32.v v6, (t1)
    la   t1, rvv_res+1168
    vse32.v v7, (t1)

    # ---- case 19: vwmulu.vx e8 ----
    li   t0, 19
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v6, 5
    vmv.v.i v7, 5
    vsetivli x0, 16, e8, m1, tu, mu
    la t1, rvv_in_a8
    vle8.v v1, (t1)
    la t1, rvv_in_b8
    vle8.v v2, (t1)
    li a1, 3
    li   t0, 1
    sw   t0, 0(s1)
    vwmulu.vx v6, v1, a1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+1216
    vse32.v v6, (t1)
    la   t1, rvv_res+1232
    vse32.v v7, (t1)

    # ---- check 0: vmul.vv e32 ----
    li   t0, 0
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+0
    la   t2, rvv_exp+0
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+0
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 1: vmul.vx e32 ----
    li   t0, 1
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+64
    la   t2, rvv_exp+64
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+4
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 2: vmulhu.vv e32 ----
    li   t0, 2
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+128
    la   t2, rvv_exp+128
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+8
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 3: vmulhu.vx e32 ----
    li   t0, 3
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+192
    la   t2, rvv_exp+192
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+12
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 4: vmulh.vv e32 ----
    li   t0, 4
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+256
    la   t2, rvv_exp+256
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+16
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 5: vmulh.vx e32 ----
    li   t0, 5
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+320
    la   t2, rvv_exp+320
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+20
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 6: vmulhsu.vv e32 ----
    li   t0, 6
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+384
    la   t2, rvv_exp+384
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+24
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 7: vmulhsu.vx e32 ----
    li   t0, 7
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+448
    la   t2, rvv_exp+448
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+28
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 8: vmul.vv e8 ----
    li   t0, 8
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+512
    la   t2, rvv_exp+512
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+32
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 9: vmul.vv e16 ----
    li   t0, 9
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+576
    la   t2, rvv_exp+576
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+36
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 10: vmacc.vv e32 ----
    li   t0, 10
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+640
    la   t2, rvv_exp+640
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+40
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 11: vmacc.vx e32 ----
    li   t0, 11
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+704
    la   t2, rvv_exp+704
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+44
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 12: vmadd.vv e32 ----
    li   t0, 12
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+768
    la   t2, rvv_exp+768
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+48
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 13: vmadd.vx e32 ----
    li   t0, 13
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+832
    la   t2, rvv_exp+832
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+52
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 14: vnmsac.vv e32 ----
    li   t0, 14
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+896
    la   t2, rvv_exp+896
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+56
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 15: vnmsac.vx e32 ----
    li   t0, 15
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+960
    la   t2, rvv_exp+960
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+60
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 16: vnmsub.vv e32 ----
    li   t0, 16
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+1024
    la   t2, rvv_exp+1024
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+64
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 17: vnmsub.vx e32 ----
    li   t0, 17
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+1088
    la   t2, rvv_exp+1088
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+68
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 18: vwmulu.vv e8 ----
    li   t0, 18
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+1152
    la   t2, rvv_exp+1152
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 16(t1)
    lw   t4, 16(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 20(t1)
    lw   t4, 20(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 24(t1)
    lw   t4, 24(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 28(t1)
    lw   t4, 28(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+72
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 19: vwmulu.vx e8 ----
    li   t0, 19
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_res+1216
    la   t2, rvv_exp+1216
    lw   t3, 0(t1)
    lw   t4, 0(t2)
    xor  t3, t3, t4
    mv   t5, t3
    lw   t3, 4(t1)
    lw   t4, 4(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 8(t1)
    lw   t4, 8(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 12(t1)
    lw   t4, 12(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 16(t1)
    lw   t4, 16(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 20(t1)
    lw   t4, 20(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 24(t1)
    lw   t4, 24(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 28(t1)
    lw   t4, 28(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+76
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- dcache write-back sweep (写地址, 值会被丢弃) ----
    la   t1, rvv_sweep_area
    sw   t3, 0(t1)
    sw   t3, 32(t1)
    sw   t3, 64(t1)
    sw   t3, 96(t1)
    sw   t3, 128(t1)
    sw   t3, 160(t1)
    sw   t3, 192(t1)
    sw   t3, 224(t1)
    sw   t3, 256(t1)
    sw   t3, 288(t1)
    sw   t3, 320(t1)
    sw   t3, 352(t1)
    sw   t3, 384(t1)
    sw   t3, 416(t1)
    sw   t3, 448(t1)
    sw   t3, 480(t1)
    sw   t3, 512(t1)
    sw   t3, 544(t1)
    sw   t3, 576(t1)
    sw   t3, 608(t1)
    sw   t3, 640(t1)
    sw   t3, 672(t1)
    sw   t3, 704(t1)
    sw   t3, 736(t1)
    sw   t3, 768(t1)
    sw   t3, 800(t1)
    sw   t3, 832(t1)
    sw   t3, 864(t1)
    sw   t3, 896(t1)
    sw   t3, 928(t1)
    sw   t3, 960(t1)
    sw   t3, 992(t1)
    sw   t3, 1024(t1)
    sw   t3, 1056(t1)
    sw   t3, 1088(t1)
    sw   t3, 1120(t1)
    sw   t3, 1152(t1)
    sw   t3, 1184(t1)
    sw   t3, 1216(t1)
    sw   t3, 1248(t1)
    sw   t3, 1280(t1)
    sw   t3, 1312(t1)
    sw   t3, 1344(t1)
    sw   t3, 1376(t1)
    sw   t3, 1408(t1)
    sw   t3, 1440(t1)
    sw   t3, 1472(t1)
    sw   t3, 1504(t1)
    sw   t3, 1536(t1)
    sw   t3, 1568(t1)
    sw   t3, 1600(t1)
    sw   t3, 1632(t1)
    sw   t3, 1664(t1)
    sw   t3, 1696(t1)
    sw   t3, 1728(t1)
    sw   t3, 1760(t1)
    sw   t3, 1792(t1)
    sw   t3, 1824(t1)
    sw   t3, 1856(t1)
    sw   t3, 1888(t1)
    sw   t3, 1920(t1)
    sw   t3, 1952(t1)
    sw   t3, 1984(t1)
    sw   t3, 2016(t1)
    addi t1, t1, 2016
    sw   t3, 0(t1)
    sw   t3, 32(t1)
    sw   t3, 64(t1)
    sw   t3, 96(t1)
    sw   t3, 128(t1)
    sw   t3, 160(t1)
    sw   t3, 192(t1)
    sw   t3, 224(t1)
    sw   t3, 256(t1)
    sw   t3, 288(t1)
    sw   t3, 320(t1)
    sw   t3, 352(t1)
    sw   t3, 384(t1)
    sw   t3, 416(t1)
    sw   t3, 448(t1)
    sw   t3, 480(t1)
    sw   t3, 512(t1)
    sw   t3, 544(t1)
    sw   t3, 576(t1)
    sw   t3, 608(t1)
    sw   t3, 640(t1)
    sw   t3, 672(t1)
    sw   t3, 704(t1)
    sw   t3, 736(t1)
    sw   t3, 768(t1)
    sw   t3, 800(t1)
    sw   t3, 832(t1)
    sw   t3, 864(t1)
    sw   t3, 896(t1)
    sw   t3, 928(t1)
    sw   t3, 960(t1)
    sw   t3, 992(t1)
    sw   t3, 1024(t1)
    sw   t3, 1056(t1)
    sw   t3, 1088(t1)
    sw   t3, 1120(t1)
    sw   t3, 1152(t1)
    sw   t3, 1184(t1)
    sw   t3, 1216(t1)
    sw   t3, 1248(t1)
    sw   t3, 1280(t1)
    sw   t3, 1312(t1)
    sw   t3, 1344(t1)
    sw   t3, 1376(t1)
    sw   t3, 1408(t1)
    sw   t3, 1440(t1)
    sw   t3, 1472(t1)
    sw   t3, 1504(t1)
    sw   t3, 1536(t1)
    sw   t3, 1568(t1)
    sw   t3, 1600(t1)
    sw   t3, 1632(t1)
    sw   t3, 1664(t1)
    sw   t3, 1696(t1)
    sw   t3, 1728(t1)
    sw   t3, 1760(t1)
    sw   t3, 1792(t1)
    sw   t3, 1824(t1)
    sw   t3, 1856(t1)
    sw   t3, 1888(t1)
    sw   t3, 1920(t1)
    sw   t3, 1952(t1)
    sw   t3, 1984(t1)
    sw   t3, 2016(t1)
    la   t0, rvv_a0
    sw   a0, 0(t0)
    addi x17, x0, 93
    ecall
    unimp

.section .data
.align 4
rvv_progress: .word 0
rvv_phase:    .word 0
rvv_a0:       .word 0
rvv_status: .word 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5
    .word 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5
    .word 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5
rvv_trapmask: .space 20
.align 4
rvv_res:      .space 1280
.align 4
rvv_exp:
    .word 0x00000002, 0x7fffffff, 0x80000000, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000003, 0x7ffffffd, 0x80000000, 0xfffffffd, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000000, 0x00000001, 0x00000001, 0x00000002, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000000, 0x00000000, 0xffffffff, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000000, 0x00000001, 0xfffffffe, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000000, 0x00000000, 0xffffffff, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000000, 0x00000001, 0xfffffffe, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0xff807f02, 0x40feaa00, 0x817e7880, 0xc0c0fcfc, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x7fff0002, 0xffff8000, 0xaaaa0000, 0x4634fffe, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000005, 0x80000004, 0x80000007, 0x00000008, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000006, 0x80000002, 0x80000007, 0x00000006, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000005, 0x7ffffffc, 0x80000001, 0xfffffff8, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x0000000a, 0x8000000e, 0x80000015, 0x0000001a, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000001, 0x80000006, 0x80000007, 0x0000000a, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000000, 0x80000008, 0x80000007, 0x0000000c, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0xffffffff, 0x80000006, 0x80000001, 0x0000000a, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0xfffffff8, 0x7ffffff0, 0x7fffffeb, 0xffffffe4, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x007f0002, 0x00ff0080, 0x00aa0000, 0x004001fe, 0x00780780, 0x0081007e, 0x01fc01fc, 0x03c000c0, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x017d0003, 0x02fd0180, 0x00ff0000, 0x003001fe, 0x002d02d0, 0x0183017a, 0x02fa0006, 0x024000c0, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
.align 4
rvv_mem:      .space 1280

.align 4
rvv_in_a8:  .byte 1,127,128,255,0,85,170,16,240,15,126,129,2,254,64,192
rvv_in_b8:  .byte 2,1,1,1,1,2,3,4,8,8,1,1,254,2,3,5
rvv_in_a16: .half 1,0x7fff,0x8000,0xffff,0,0x5555,0xaaaa,0x1234
rvv_in_b16: .half 2,1,1,1,1,2,3,0x0101
rvv_in_a32: .word 1,0x7fffffff,0x80000000,0xffffffff
rvv_in_b32: .word 2,1,1,1
rvv_in_c32: .word 3,5,7,9
rvv_in_c16: .half 3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33
rvv_in_w16: .half 1,0x7fff,0x8000,0xffff,2,3,4,5,6,7,8,9,10,11,12,13
rvv_mask_a: .byte 0x55,0xaa,0x0f,0xf0,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0xff,0x00,0x5a,0xa5
rvv_mask_b: .byte 0x0f,0xf0,0x33,0xcc,0x80,0x40,0x20,0x10,0x08,0x04,0x02,0x01,0x0f,0xf0,0xa5,0x5a
rvv_idx8:   .byte 0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60
rvv_idx16:  .half 0,2,4,6,8,10,12,14
rvv_idx32:  .word 0,4,8,12
rvv_hitbuf: .space 64
rvv_ls_src: .byte 5, 22, 39, 56, 73, 90, 107, 124, 141, 158, 175, 192, 209, 226, 243, 4, 21, 38, 55, 72, 89, 106, 123, 140, 157, 174, 191, 208, 225, 242, 3, 20, 37, 54, 71, 88, 105, 122, 139, 156, 173, 190, 207, 224, 241, 2, 19, 36, 53, 70, 87, 104, 121, 138, 155, 172, 189, 206, 223, 240, 1, 18, 35, 52, 69, 86, 103, 120, 137, 154, 171, 188, 205, 222, 239, 0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255, 16, 33, 50, 67, 84, 101, 118, 135, 152, 169, 186, 203, 220, 237, 254, 15, 32, 49, 66, 83, 100, 117, 134, 151, 168, 185, 202, 219, 236, 253, 14, 31, 48, 65, 82, 99, 116, 133, 150, 167, 184, 201, 218, 235, 252, 13, 30, 47, 64, 81, 98, 115, 132, 149, 166, 183, 200, 217, 234, 251, 12, 29, 46, 63, 80, 97, 114, 131, 148, 165, 182, 199, 216, 233, 250, 11, 28, 45, 62, 79, 96, 113, 130, 147, 164, 181, 198, 215, 232, 249, 10, 27, 44, 61, 78, 95, 112, 129, 146, 163, 180, 197, 214, 231, 248, 9, 26, 43, 60, 77, 94, 111, 128, 145, 162, 179, 196, 213, 230, 247, 8, 25, 42, 59, 76, 93, 110, 127, 144, 161, 178, 195, 212, 229, 246, 7, 24, 41, 58, 75, 92, 109, 126, 143, 160, 177, 194, 211, 228, 245, 6, 23, 40, 57, 74, 91, 108, 125, 142, 159, 176, 193, 210, 227, 244
.align 5
rvv_sweep_area: .space 4096
