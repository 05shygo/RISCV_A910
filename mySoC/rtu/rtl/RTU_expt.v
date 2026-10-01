`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_expt — 异常收集: **全局单表项, 最旧者胜** (D9)。
//
// 为什么不逐表项存异常字段: `{vld,iid,cause,tval}` 约 37 bit × 64 项 = 2.4 Kb,
// 而异常是极稀疏事件。全局一项只要 ~45 bit。
//
// 规律:
//   * 各级 (ID/EX/MEM) 检出异常时把 {iid, cause, tval} 打到收集口 (只有一路,
//     级间按"老级优先"仲裁, 见 §6.3 ④);
//   * 本模块用 RTU_iid_cmp 与已有表项比年龄, 只留最旧的一条;
//   * **冲刷时必须清 vld** —— 漏了这一行, 错误路径上的异常会"凭空陷入"
//     (§8.4 的变异清单里专门有一条守它)。
// ---------------------------------------------------------------------------
module RTU_expt (
    input  wire        cpu_clk,
    input  wire        cpu_rst,

    input  wire        expt_vld,
    input  wire [6:0]  expt_iid,
    input  wire [4:0]  expt_cause,
    input  wire [31:0] expt_tval,

    input  wire        flush_clr,      // FLUSH_1 那拍清掉

    output wire        entry_vld,
    output wire [6:0]  entry_iid,
    output wire [4:0]  entry_cause,
    output wire [31:0] entry_tval
);

    reg        vld_q;
    reg [6:0]  iid_q;
    reg [4:0]  cause_q;
    reg [31:0] tval_q;

    // 新来的比手里的更老才覆盖 (手里的无效时无条件收)
    wire new_older;
    RTU_iid_cmp u_cmp (
        .x_iid0      (expt_iid),
        .x_iid1      (iid_q),
        .x_iid0_older(new_older)
    );

    wire take = expt_vld & (~vld_q | new_older);

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
            iid_q   <= expt_iid;
            cause_q <= expt_cause;
            tval_q  <= expt_tval;
        end
    end

    assign entry_vld   = vld_q;
    assign entry_iid   = iid_q;
    assign entry_cause = cause_q;
    assign entry_tval  = tval_q;

endmodule
