`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_expt — 异常收集: **全局单表项, 最旧者胜** (D9)。
//
// 为什么不逐表项存异常字段: `{vld,iid,cause,tval}` 约 37 bit × 64 项 = 2.4 Kb,
// 而异常是极稀疏事件。全局一项只要 ~45 bit。
//
// 三个**平行的**异常源 (2026-10-10 由 1 路扩到 3 路, 与 C910 同构):
//
//   expt_iu_*   IU 侧 —— 非法指令 / 取指故障 / 取指地址非对齐
//                       (对应 C910 ct_rtu_top 的 `iu_rtu_pipe0_expt_*`)
//   expt_ld_*   LSU load 流水  (对应 `lsu_rtu_wb_pipe3_expt_*`)
//   expt_st_*   LSU store 流水 (对应 `lsu_rtu_wb_pipe4_expt_*`)
//
// 为什么不合成一路再送进来 —— **同拍冲突必须在进本模块之前就无法补救**:
//   如果上游把两个同拍到达的源先选一个, 而选中的是**年轻**那条, 那年长那条的
//   异常信息当场丢失, 且它**以后不会再报一次** (它已经离开流水了)。更糟的是
//   它还比 trap 那条老 ⇒ 不在冲刷范围内 ⇒ 它会带着"没有异常"的表项正常退休,
//   异常永久丢失。跨拍的冲突本模块能救 (保持项会被更老的顶掉), 同拍的救不了。
//   ⇒ 三路都引进来, 在这里做锦标赛。
//
// 规律:
//   * 三源做**锦标赛**取最旧: `cmp(iu,ld) → w1`, `cmp(w1,st) → w2` —— 全序上的
//     锦标赛树给出的就是最小值, 3 个比较器 (C910 那边是 4 源两两全比 = 10 个,
//     它用的是独热 write_sel 写法, 不是树);
//   * 再用 `RTU_iid_cmp` 与已有表项比年龄, 只留最旧的一条;
//   * **冲刷时必须清 vld** —— 漏了这一行, 错误路径上的异常会"凭空陷入"
//     (§8.4 的变异清单里专门有一条守它)。
//
// ⚠️ 三源里只有一路有效时, 另一路的 `_iid` 是**上一条**的残留值, 不是 X ——
//    所以锦标赛里每一级都必须**先看 vld 再比年龄**, 不能无条件比。
//    写成 `pick_a = a_vld & (~b_vld | a_older_b)` 就是这个意思。
// ---------------------------------------------------------------------------
module RTU_expt (
    input  wire        cpu_clk,
    input  wire        cpu_rst,

    // ---- 三个平行异常源 ----
    input  wire        expt_iu_vld,
    input  wire [6:0] expt_iu_iid,
    input  wire [4:0]  expt_iu_cause,
    input  wire [31:0] expt_iu_tval,

    input  wire        expt_ld_vld,
    input  wire [6:0] expt_ld_iid,
    input  wire [4:0]  expt_ld_cause,
    input  wire [31:0] expt_ld_tval,

    input  wire        expt_st_vld,
    input  wire [6:0] expt_st_iid,
    input  wire [4:0]  expt_st_cause,
    input  wire [31:0] expt_st_tval,

    input  wire        flush_clr,      // FLUSH_1 那拍清掉

    output wire        entry_vld,
    output wire [6:0] entry_iid,
    output wire [4:0]  entry_cause,
    output wire [31:0] entry_tval
);

    reg        vld_q;
    reg [6:0]  iid_q;
    reg [4:0]  cause_q;
    reg [31:0] tval_q;

    // -----------------------------------------------------------------------
    // 第一级: expt_iu vs expt_ld
    // -----------------------------------------------------------------------
    wire iu_older_ld;
    RTU_iid_cmp u_cmp_iu_ld (
        .x_iid0      (expt_iu_iid),
        .x_iid1      (expt_ld_iid),
        .x_iid0_older(iu_older_ld)
    );

    wire pick_iu = expt_iu_vld & (~expt_ld_vld | iu_older_ld);
    wire pick_ld = expt_ld_vld & ~pick_iu;

    wire        w1_vld   = pick_iu | pick_ld;
    wire [6:0] w1_iid   = pick_ld ? expt_ld_iid   : expt_iu_iid;
    wire [4:0]  w1_cause = pick_ld ? expt_ld_cause : expt_iu_cause;
    wire [31:0] w1_tval  = pick_ld ? expt_ld_tval  : expt_iu_tval;

    // -----------------------------------------------------------------------
    // 第二级: 第一级胜者 vs expt_st
    // -----------------------------------------------------------------------
    wire w1_older_st;
    RTU_iid_cmp u_cmp_w1_st (
        .x_iid0      (w1_iid),
        .x_iid1      (expt_st_iid),
        .x_iid0_older(w1_older_st)
    );

    wire pick_w1 = w1_vld & (~expt_st_vld | w1_older_st);
    wire pick_st = expt_st_vld & ~pick_w1;

    wire        new_vld   = pick_w1 | pick_st;
    wire [6:0] new_iid   = pick_st ? expt_st_iid   : w1_iid;
    wire [4:0]  new_cause = pick_st ? expt_st_cause : w1_cause;
    wire [31:0] new_tval  = pick_st ? expt_st_tval  : w1_tval;

    // -----------------------------------------------------------------------
    // 第三级: 本拍胜者 vs 已经持有的那条
    // -----------------------------------------------------------------------
    // 新来的比手里的更老才覆盖 (手里的无效时无条件收)。这一级是**跨拍**冲突的
    // 兜底: cycle T 收下 iid=5, cycle T+1 来了 iid=3, 3 更老就顶掉 5。
    wire new_older;
    RTU_iid_cmp u_cmp_held (
        .x_iid0      (new_iid),
        .x_iid1      (iid_q),
        .x_iid0_older(new_older)
    );

    wire take = new_vld & (~vld_q | new_older);

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            vld_q   <= 1'b0;
            iid_q   <= 7'd0;
            cause_q <= 5'd0;
            tval_q  <= 32'd0;
        end else if (flush_clr) begin
            vld_q   <= 1'b0;            // 错误路径的异常必须丢掉
            iid_q   <= 7'd0;
            cause_q <= 5'd0;
            tval_q  <= 32'd0;
        end else if (take) begin
            vld_q   <= 1'b1;
            iid_q   <= new_iid;
            cause_q <= new_cause;
            tval_q  <= new_tval;
        end
    end

    assign entry_vld   = vld_q;
    assign entry_iid   = iid_q;
    assign entry_cause = cause_q;
    assign entry_tval  = tval_q;

endmodule
