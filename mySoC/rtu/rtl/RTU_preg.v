`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_preg — 物理寄存器四态表 + 两拍分配 + 架构映射表 AMT (D2 / D3)。
//
// 四态 (每 preg 2 bit, 共 192 bit):
//   FREE --(优先编码选中, T)--> WF_ALLOC --(派遣确认, T+1)--> ALLOC
//                                    \--(没派成/被冲刷)--------> FREE
//   ALLOC --(退休且写回)--> ARCH        ALLOC --(陷阱那条)--> FREE
//   ARCH  --(退休释放 old_preg && >=32)--> FREE
//   冲刷: 非 ARCH 全部回 FREE (一拍并行, 每个 preg 各看各的, 不用扫描)
//
// ⚠️ `WF_ALLOC` 不是多余的簿记: 96 位三端口优先编码器是 7 级左右的组合深度,
//    直接串在"派遣 → 分配 → 更新状态"这条链上会把派遣拍压垮 (§4.2 的 P3)。
//    C910 也是切成两拍 (`ct_rtu_pst_preg_entry.v:288-295`)。
// ⚠️ `p0..p31` 永不进自由池 —— 退休释放 old_preg 时必须判 `>= 32`,
//    否则第一次写 x1 就把初始映射 p1 放回池子 (D2 里标"最容易漏的一行",
//    本核把它放在**调用方** RTU.v 一处判, 免得观察口与池子两处判得不一致)。
//
// 空闲计数用**加减计数器**而不是 popcount: disp_stall 要喂给前端的捕获使能,
// 而 IF_ID 捕获本来就在 500 条最差路径里 (§4.2 的 P8)。计数器只被寄存器事件驱动。
// ---------------------------------------------------------------------------
module RTU_preg (
    input  wire        cpu_clk,
    input  wire        cpu_rst,

    // ---- §6.0 分配请求 (T 拍) ----
    input  wire [1:0]  ren_preg_req,
    input  wire [4:0]  ren_preg_req_lreg0,
    input  wire [4:0]  ren_preg_req_lreg1,
    input  wire [4:0]  ren_preg_req_lreg2,

    // ---- 派遣确认 (T+1 拍) ----
    input  wire [2:0]  disp_vld,
    input  wire [6:0]  disp_dst_preg0,
    input  wire [6:0]  disp_dst_preg1,
    input  wire [6:0]  disp_dst_preg2,

    // ---- 退休 ----
    input  wire [2:0]  ret_arch_vld,     // dst_preg -> ARCH (+ AMT 写)
    input  wire [2:0]  ret_kill_vld,     // 陷阱那条: 分配过但没写的 dst_preg -> FREE
    input  wire [2:0]  ret_free_vld,     // old_preg (已判 >=32) -> FREE
    input  wire [6:0]  ret_dst_preg0, ret_dst_preg1, ret_dst_preg2,
    input  wire [6:0]  ret_old_preg0, ret_old_preg1, ret_old_preg2,
    input  wire [4:0]  ret_dst_lreg0, ret_dst_lreg1, ret_dst_lreg2,

    // ---- 冲刷 (FLUSH_2) ----
    input  wire        flush_lvl,

    // ---- 输出 ----
    output wire [6:0]  rtu_preg_alloc0,
    output wire [6:0]  rtu_preg_alloc1,
    output wire [6:0]  rtu_preg_alloc2,
    output wire        rtu_preg_alloc_vld0,
    output wire        rtu_preg_alloc_vld1,
    output wire        rtu_preg_alloc_vld2,
    output wire [6:0]  free_cnt,               // 7 位真值 (给自检/TB)
    output wire [1:0]  rtu_preg_free_cnt,      // §6.0 的口径: 饱和到 3
    output wire [223:0] amt_flat               // 32 × 7bit, amt_flat[7*l +: 7] = AMT[l]
);

    reg  [1:0]  st [0:95];
    reg  [1:0]  nst[0:95];
    // WF_ALLOC 的"年龄": 刚发出去那一拍是 0, 再等一拍变 1。
    // ⚠️ 放回自由池**要等两拍**, 不能刚发出去没派成下一拍就收 —— §6.0 的握手本来
    //    只留了一拍窗口, 但那样对"发出者晚半拍/晚一拍"零容忍: 编号一旦被放回,
    //    优先编码器立刻可能把它发给别人, 而前一条指令还拿着它 (单测台就是这么撞上的)。
    //    多等一拍只让自由池少一个编号一拍, 没有任何正确性代价。
    reg  [95:0] wf_age;
    reg  [6:0]  amt[0:31];
    reg  [6:0]  free_cnt_q;

    integer     i;
    integer     k;

    // -----------------------------------------------------------------------
    // 优先编码 (C910 的 ct_rtu_encode_96 就是干这个的)
    //   enc_lo: p32 -> p95 低到高找第一个
    //   enc_hi: p95 -> p32 高到低找第一个
    //   p0..p31 永不参与
    // -----------------------------------------------------------------------
    function [6:0] enc_lo;
        input [95:0] v;
        integer      j;
        reg          found;
        begin
            enc_lo = 7'd0;
            found  = 1'b0;
            for (j = 95; j >= 32; j = j - 1) begin
                if (v[j] && !found) begin
                    enc_lo = j;
                    found  = 1'b1;
                end
            end
        end
    endfunction

    function [6:0] enc_hi;
        input [95:0] v;
        integer      j;
        reg          found;
        begin
            enc_hi = 7'd0;
            found  = 1'b0;
            for (j = 32; j < 96; j = j + 1) begin
                if (v[j] && !found) begin
                    enc_hi = j;
                    found  = 1'b1;
                end
            end
        end
    endfunction

    wire [95:0] free_vec;
    genvar      gv;
    generate
        for (gv = 0; gv < 96; gv = gv + 1) begin : g_free
            assign free_vec[gv] = (st[gv] == `RTU_P_FREE);
        end
    endgenerate

    // 车道是否要分配: 有请求 且 dst 不是 x0 (x0 不分配、不映射)
    wire [2:0] req_lane;
    assign req_lane[0] = (ren_preg_req > 2'd0) && (ren_preg_req_lreg0 != 5'd0);
    assign req_lane[1] = (ren_preg_req > 2'd1) && (ren_preg_req_lreg1 != 5'd0);
    assign req_lane[2] = (ren_preg_req > 2'd2) && (ren_preg_req_lreg2 != 5'd0);

    wire [6:0]  sel0 = enc_lo(free_vec);
    wire [95:0] v1   = free_vec & ~(96'd1 << sel0);
    wire [6:0]  sel1 = enc_hi(v1);
    wire [95:0] v2   = v1 & ~(96'd1 << sel1);
    wire [6:0]  sel2 = enc_lo(v2);

    // ⚠️ 先把每个候选池声明出来再用 —— 本仓有"先用后声明造 1 位隐式线网"的前科
    //    (cpu/sim/rtl_patch/README.md 与 §9 的 R7), 症状是**语义静默错**而不是报错。
    wire [95:0] cand0 = free_vec;
    wire [95:0] cand1 = v1;
    wire [95:0] cand2 = v2;

    wire [95:0] sel_oh = ((96'd1 << sel0) & {96{req_lane[0]}})
                       | ((96'd1 << sel1) & {96{req_lane[1]}})
                       | ((96'd1 << sel2) & {96{req_lane[2]}});

    assign rtu_preg_alloc0     = sel0;
    assign rtu_preg_alloc1     = sel1;
    assign rtu_preg_alloc2     = sel2;
    assign rtu_preg_alloc_vld0 = req_lane[0] & (|cand0);
    assign rtu_preg_alloc_vld1 = req_lane[1] & (|cand1);
    assign rtu_preg_alloc_vld2 = req_lane[2] & (|cand2);

    // -----------------------------------------------------------------------
    // 派遣确认 (T+1 拍)
    //
    // 口径: **按"这个编号当前是不是 WF_ALLOC 态"判**, 而不是去比"上一拍发出去的
    // 那个值"。两者在合法协议下等价 (WF_ALLOC 恰好就是上一拍发出去、还没落定的
    // 那一批), 但按状态判**与相位无关** —— 派遣晚半拍/晚一拍都不会把编号误放回
    // 自由池。踩过的坑: 早先按 pend 值比较, TB 侧相位对不齐时 DUT 会静默地把
    // 编号放回 FREE, 而指令还拿着它 —— 自由池立刻放水。
    // -----------------------------------------------------------------------
    wire [95:0] hit_disp;      // 本拍派遣真正用到的编号 (独热)
    genvar      gd;
    generate
        for (gd = 0; gd < 96; gd = gd + 1) begin : g_disp
            assign hit_disp[gd] = (disp_vld[0] && (disp_dst_preg0 == gd))
                               || (disp_vld[1] && (disp_dst_preg1 == gd))
                               || (disp_vld[2] && (disp_dst_preg2 == gd));
        end
    endgenerate

    wire [95:0] is_wf;
    genvar      gw;
    generate
        for (gw = 0; gw < 96; gw = gw + 1) begin : g_wf
            assign is_wf[gw] = (st[gw] == `RTU_P_WFALLOC);
        end
    endgenerate

    wire conf_alloc_any = |(is_wf &  hit_disp);
    wire conf_free_any  = |(is_wf & ~hit_disp);

    // -----------------------------------------------------------------------
    // 四态表更新 (优先级: 冲刷 > 退休 > 派遣确认 > 本拍选中 > 保持)
    // -----------------------------------------------------------------------
    always @(*) begin
        for (i = 0; i < 96; i = i + 1) begin
            if (flush_lvl) begin
                // 冲刷: 没退休的一律回 FREE, 架构态不动
                nst[i] = (st[i] == `RTU_P_ARCH) ? `RTU_P_ARCH : `RTU_P_FREE;
            end else if ((ret_arch_vld[0] && (ret_dst_preg0 == i)) ||
                         (ret_arch_vld[1] && (ret_dst_preg1 == i)) ||
                         (ret_arch_vld[2] && (ret_dst_preg2 == i))) begin
                nst[i] = `RTU_P_ARCH;
            end else if ((ret_kill_vld[0] && (ret_dst_preg0 == i)) ||
                         (ret_kill_vld[1] && (ret_dst_preg1 == i)) ||
                         (ret_kill_vld[2] && (ret_dst_preg2 == i))) begin
                nst[i] = `RTU_P_FREE;
            end else if ((ret_free_vld[0] && (ret_old_preg0 == i)) ||
                         (ret_free_vld[1] && (ret_old_preg1 == i)) ||
                         (ret_free_vld[2] && (ret_old_preg2 == i))) begin
                nst[i] = `RTU_P_FREE;
            end else if (is_wf[i] &&  hit_disp[i]) begin
                nst[i] = `RTU_P_ALLOC;          // 本拍被派出去了
            end else if (is_wf[i] && !hit_disp[i] && wf_age[i]) begin
                nst[i] = `RTU_P_FREE;           // 等满两拍都没派成 -> 回自由池
            end else if (sel_oh[i]) begin
                nst[i] = `RTU_P_WFALLOC;
            end else begin
                nst[i] = st[i];
            end
        end
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            // p0..p31 = x0..x31 的初始映射; p32..p95 = FREE
            for (i = 0; i < 32; i = i + 1) st[i] <= `RTU_P_ARCH;
            for (i = 32; i < 96; i = i + 1) st[i] <= `RTU_P_FREE;
        end else begin
            for (i = 0; i < 96; i = i + 1) st[i] <= nst[i];
        end
    end

    // -----------------------------------------------------------------------
    // 空闲计数 (加减计数器, 不让 popcount 上路径)
    // -----------------------------------------------------------------------
    wire [95:0] do_free_wf = is_wf & ~hit_disp & wf_age;
    wire [1:0] n_cf = $countones(do_free_wf);             // 本拍放回自由池的个数 (0..3)
    wire [2:0] n_freed = {2'b0, ret_free_vld[0]} + {2'b0, ret_free_vld[1]}
                       + {2'b0, ret_free_vld[2]} + {1'b0, n_cf};
    wire [2:0] n_alloc = {2'b0, rtu_preg_alloc_vld0} + {2'b0, rtu_preg_alloc_vld1}
                       + {2'b0, rtu_preg_alloc_vld2};

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)          free_cnt_q <= 7'd64;
        else if (flush_lvl)   free_cnt_q <= 7'd64;
        else                  free_cnt_q <= free_cnt_q + {4'b0, n_freed} - {4'b0, n_alloc};
    end

    assign free_cnt          = free_cnt_q;
    assign rtu_preg_free_cnt = (free_cnt_q >= 7'd3) ? 2'd3 : free_cnt_q[1:0];

    // -----------------------------------------------------------------------
    // AMT: 架构映射表 (32 × 7)。退休那拍的 3 个写口; 冲刷**不**动它 ——
    // 它只反映已退休的映射, 这正是"恢复靠整表覆盖"的底气 (D1/D2)。
    // -----------------------------------------------------------------------
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            for (i = 0; i < 32; i = i + 1) amt[i] <= i[6:0];
        end else begin
            for (i = 0; i < 32; i = i + 1) begin
                if      (ret_arch_vld[0] && (ret_dst_lreg0 == i)) amt[i] <= ret_dst_preg0;
                else if (ret_arch_vld[1] && (ret_dst_lreg1 == i)) amt[i] <= ret_dst_preg1;
                else if (ret_arch_vld[2] && (ret_dst_lreg2 == i)) amt[i] <= ret_dst_preg2;
            end
        end
    end

    generate
        for (gv = 0; gv < 32; gv = gv + 1) begin : g_amt
            assign amt_flat[7*gv +: 7] = amt[gv];
        end
    endgenerate

endmodule
