    # 自动生成 by tests/rvv/gen_sweep.py —— 不要手改
.section .text.init
.globl _start
_start:
    add  a0, x0, x0
    la   s0, rvv_progress
    la   s1, rvv_phase
    # ---- case 0: vsse16.v 0 ----
    li   t0, 0
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 8, e16, m1, tu, mu
    la t1, rvv_ls_src
    vle16.v v5, (t1)
    la t1, rvv_mem+0
    li a1, 0
    li   t0, 1
    sw   t0, 0(s1)
    vsse16.v v5, (t1), a1
    li   t0, 2
    sw   t0, 0(s1)

    # ---- case 1: vlse32.v +4 ----
    li   t0, 1
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_ls_src
    vle32.v v5, (t1)
    la t1, rvv_ls_src
    li a1, 4
    li   t0, 1
    sw   t0, 0(s1)
    vlse32.v v5, (t1), a1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+64
    vse32.v v5, (t1)

    # ---- case 2: vlse32.v -4 ----
    li   t0, 2
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_ls_src+12
    li a1, -4
    li   t0, 1
    sw   t0, 0(s1)
    vlse32.v v5, (t1), a1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+128
    vse32.v v5, (t1)

    # ---- case 3: vsse32.v +4 ----
    li   t0, 3
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_ls_src
    vle32.v v5, (t1)
    la t1, rvv_mem+192
    li a1, 4
    li   t0, 1
    sw   t0, 0(s1)
    vsse32.v v5, (t1), a1
    li   t0, 2
    sw   t0, 0(s1)

    # ---- case 4: vsse32.v 0 ----
    li   t0, 4
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_ls_src
    vle32.v v5, (t1)
    la t1, rvv_mem+256
    li a1, 0
    li   t0, 1
    sw   t0, 0(s1)
    vsse32.v v5, (t1), a1
    li   t0, 2
    sw   t0, 0(s1)

    # ---- case 5: vluxei8.v ----
    li   t0, 5
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 16, e8, m1, tu, mu
    la t1, rvv_idx8
    vle8.v v1, (t1)
    la t1, rvv_ls_src
    li   t0, 1
    sw   t0, 0(s1)
    vluxei8.v v5, (t1), v1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+320
    vse32.v v5, (t1)

    # ---- case 6: vsuxei8.v ----
    li   t0, 6
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 16, e8, m1, tu, mu
    la t1, rvv_idx8
    vle8.v v1, (t1)
    vsetivli x0, 16, e8, m1, tu, mu
    la t1, rvv_ls_src
    vle8.v v5, (t1)
    la t1, rvv_mem+384
    li   t0, 1
    sw   t0, 0(s1)
    vsuxei8.v v5, (t1), v1
    li   t0, 2
    sw   t0, 0(s1)

    # ---- case 7: vluxei16.v ----
    li   t0, 7
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 8, e16, m1, tu, mu
    la t1, rvv_idx16
    vle16.v v1, (t1)
    la t1, rvv_ls_src
    li   t0, 1
    sw   t0, 0(s1)
    vluxei16.v v5, (t1), v1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+448
    vse32.v v5, (t1)

    # ---- case 8: vsuxei16.v ----
    li   t0, 8
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 8, e16, m1, tu, mu
    la t1, rvv_idx16
    vle16.v v1, (t1)
    vsetivli x0, 8, e16, m1, tu, mu
    la t1, rvv_ls_src
    vle16.v v5, (t1)
    la t1, rvv_mem+512
    li   t0, 1
    sw   t0, 0(s1)
    vsuxei16.v v5, (t1), v1
    li   t0, 2
    sw   t0, 0(s1)

    # ---- case 9: vluxei32.v ----
    li   t0, 9
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_idx32
    vle32.v v1, (t1)
    la t1, rvv_ls_src
    li   t0, 1
    sw   t0, 0(s1)
    vluxei32.v v5, (t1), v1
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+576
    vse32.v v5, (t1)

    # ---- case 10: vsuxei32.v ----
    li   t0, 10
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_idx32
    vle32.v v1, (t1)
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_ls_src
    vle32.v v5, (t1)
    la t1, rvv_mem+640
    li   t0, 1
    sw   t0, 0(s1)
    vsuxei32.v v5, (t1), v1
    li   t0, 2
    sw   t0, 0(s1)

    # ---- case 11: vle32.v masked ----
    li   t0, 11
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 16, e8, m1, tu, mu
    la   t1, rvv_mask_a
    vle8.v v0, (t1)
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_ls_src
    li   t0, 1
    sw   t0, 0(s1)
    vle32.v v5, (t1), v0.t
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+704
    vse32.v v5, (t1)

    # ---- case 12: vse32.v masked ----
    li   t0, 12
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v5, 5
    vsetivli x0, 16, e8, m1, tu, mu
    la   t1, rvv_mask_a
    vle8.v v0, (t1)
    vsetivli x0, 4, e32, m1, tu, mu
    la t1, rvv_ls_src
    vle32.v v5, (t1)
    la t1, rvv_mem+768
    li   t0, 1
    sw   t0, 0(s1)
    vse32.v v5, (t1), v0.t
    li   t0, 2
    sw   t0, 0(s1)

    # ---- case 13: vle32.v m2 lmul2 ----
    li   t0, 13
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v6, 5
    vmv.v.i v7, 5
    vsetivli x0, 8, e32, m2, tu, mu
    la t1, rvv_ls_src
    vle32.v v6, (t1)
    li   t0, 1
    sw   t0, 0(s1)
    vle32.v v6, (t1)
    li   t0, 2
    sw   t0, 0(s1)
    vsetivli x0, 4, e32, m1, tu, mu
    la   t1, rvv_res+832
    vse32.v v6, (t1)
    la   t1, rvv_res+848
    vse32.v v7, (t1)

    # ---- case 14: vse32.v m2 lmul2 ----
    li   t0, 14
    sw   t0, 0(s0)
    li   t0, 0
    sw   t0, 0(s1)
    vsetivli x0, 16, e8, m1, tu, mu
    vmv.v.i v6, 5
    vmv.v.i v7, 5
    vsetivli x0, 8, e32, m2, tu, mu
    la t1, rvv_ls_src
    vle32.v v6, (t1)
    la t1, rvv_mem+896
    li   t0, 1
    sw   t0, 0(s1)
    vse32.v v6, (t1)
    li   t0, 2
    sw   t0, 0(s1)

    # ---- check 0: vsse16.v 0 ----
    li   t0, 0
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_mem+0
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
    lw   t3, 32(t1)
    lw   t4, 32(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 36(t1)
    lw   t4, 36(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 40(t1)
    lw   t4, 40(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 44(t1)
    lw   t4, 44(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 48(t1)
    lw   t4, 48(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 52(t1)
    lw   t4, 52(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 56(t1)
    lw   t4, 56(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 60(t1)
    lw   t4, 60(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+0
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 1: vlse32.v +4 ----
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

    # ---- check 2: vlse32.v -4 ----
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

    # ---- check 3: vsse32.v +4 ----
    li   t0, 3
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_mem+192
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
    lw   t3, 32(t1)
    lw   t4, 32(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 36(t1)
    lw   t4, 36(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 40(t1)
    lw   t4, 40(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 44(t1)
    lw   t4, 44(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 48(t1)
    lw   t4, 48(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 52(t1)
    lw   t4, 52(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 56(t1)
    lw   t4, 56(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 60(t1)
    lw   t4, 60(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+12
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 4: vsse32.v 0 ----
    li   t0, 4
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_mem+256
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
    lw   t3, 32(t1)
    lw   t4, 32(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 36(t1)
    lw   t4, 36(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 40(t1)
    lw   t4, 40(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 44(t1)
    lw   t4, 44(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 48(t1)
    lw   t4, 48(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 52(t1)
    lw   t4, 52(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 56(t1)
    lw   t4, 56(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 60(t1)
    lw   t4, 60(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+16
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 5: vluxei8.v ----
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

    # ---- check 6: vsuxei8.v ----
    li   t0, 6
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_mem+384
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
    lw   t3, 32(t1)
    lw   t4, 32(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 36(t1)
    lw   t4, 36(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 40(t1)
    lw   t4, 40(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 44(t1)
    lw   t4, 44(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 48(t1)
    lw   t4, 48(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 52(t1)
    lw   t4, 52(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 56(t1)
    lw   t4, 56(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 60(t1)
    lw   t4, 60(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+24
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 7: vluxei16.v ----
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

    # ---- check 8: vsuxei16.v ----
    li   t0, 8
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_mem+512
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
    lw   t3, 32(t1)
    lw   t4, 32(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 36(t1)
    lw   t4, 36(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 40(t1)
    lw   t4, 40(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 44(t1)
    lw   t4, 44(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 48(t1)
    lw   t4, 48(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 52(t1)
    lw   t4, 52(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 56(t1)
    lw   t4, 56(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 60(t1)
    lw   t4, 60(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+32
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 9: vluxei32.v ----
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

    # ---- check 10: vsuxei32.v ----
    li   t0, 10
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_mem+640
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
    lw   t3, 32(t1)
    lw   t4, 32(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 36(t1)
    lw   t4, 36(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 40(t1)
    lw   t4, 40(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 44(t1)
    lw   t4, 44(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 48(t1)
    lw   t4, 48(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 52(t1)
    lw   t4, 52(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 56(t1)
    lw   t4, 56(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 60(t1)
    lw   t4, 60(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+40
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 11: vle32.v masked ----
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

    # ---- check 12: vse32.v masked ----
    li   t0, 12
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_mem+768
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
    lw   t3, 32(t1)
    lw   t4, 32(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 36(t1)
    lw   t4, 36(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 40(t1)
    lw   t4, 40(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 44(t1)
    lw   t4, 44(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 48(t1)
    lw   t4, 48(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 52(t1)
    lw   t4, 52(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 56(t1)
    lw   t4, 56(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 60(t1)
    lw   t4, 60(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+48
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 13: vle32.v m2 lmul2 ----
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
    la   t1, rvv_status+52
    sw   t5, 0(t1)
    add  a0, a0, t5

    # ---- check 14: vse32.v m2 lmul2 ----
    li   t0, 14
    sw   t0, 0(s0)
    li   t0, 4
    sw   t0, 0(s1)
    la   t1, rvv_mem+896
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
    lw   t3, 32(t1)
    lw   t4, 32(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 36(t1)
    lw   t4, 36(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 40(t1)
    lw   t4, 40(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 44(t1)
    lw   t4, 44(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 48(t1)
    lw   t4, 48(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 52(t1)
    lw   t4, 52(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 56(t1)
    lw   t4, 56(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    lw   t3, 60(t1)
    lw   t4, 60(t2)
    xor  t3, t3, t4
    or   t5, t5, t3
    sltu t5, x0, t5
    la   t1, rvv_status+56
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
    .word 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5, 0xa5a5a5a5
rvv_trapmask: .space 15
.align 4
rvv_res:      .space 960
.align 4
rvv_exp:
    .word 0x000004f3, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x7c6b5a49, 0xc0af9e8d, 0x04f3e2d1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x04f3e2d1, 0xc0af9e8d, 0x7c6b5a49, 0x38271605, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x7c6b5a49, 0xc0af9e8d, 0x04f3e2d1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x04f3e2d1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0xd18d4905, 0xe19d5915, 0xf1ad6925, 0x01bd7935, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x00000005, 0x00000016, 0x00000027, 0x00000038, 0x00000049, 0x0000005a, 0x0000006b, 0x0000007c, 0x0000008d, 0x0000009e, 0x000000af, 0x000000c0, 0x000000d1, 0x000000e2, 0x000000f3, 0x00000004
    .word 0x38271605, 0x7c6b5a49, 0xc0af9e8d, 0x04f3e2d1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x7c6b5a49, 0xc0af9e8d, 0x04f3e2d1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x7c6b5a49, 0xc0af9e8d, 0x04f3e2d1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x7c6b5a49, 0xc0af9e8d, 0x04f3e2d1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x05050505, 0xc0af9e8d, 0x05050505, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x00000000, 0xc0af9e8d, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x7c6b5a49, 0xc0af9e8d, 0x04f3e2d1, 0x48372615, 0x8c7b6a59, 0xd0bfae9d, 0x1403f2e1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    .word 0x38271605, 0x7c6b5a49, 0xc0af9e8d, 0x04f3e2d1, 0x48372615, 0x8c7b6a59, 0xd0bfae9d, 0x1403f2e1, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
.align 4
rvv_mem:      .space 960

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
