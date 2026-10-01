`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_ROB_entry — 一条 ROB 表项 (D4 的 122 bit), 例化 64 次 + 3 次 (影子窗口)。
//
// 三条写入路径, 优先级 **flush > reload > disp > 自更新**:
//   * disp    : 派遣建表项 (数据由 RTU_ROB 按车道拼好)
//   * reload  : 影子窗口专用 —— 从阵列的下一拍值重填 (D5 的"移位 / 补空")
//   * 自更新  : 完成信号置 cmplt; 解析信号写 target/taken/mispred
//   * flush   : 全清 (FLUSH_2 与指针复位同拍)
//
// ⚠️ 完成/解析的匹配信号 (cmplt_hit / resolve_hit) 由父模块算 —— 因为"本项的 iid"
//    是"位置"决定的: 阵列项是常量索引, 影子窗口项是 rptr+k 算出来的。父模块比谁都清楚。
// ⚠️ reload 优先于自更新是**有意**的: reload 的数据来自阵列的下一拍值, 里面已经含了
//    本拍的完成/解析更新, 先自更新再 reload 会丢一拍 (见 RTU_ROB.v 的窗口注释)。
// ---------------------------------------------------------------------------
module RTU_ROB_entry (
    input  wire                cpu_clk,
    input  wire                cpu_rst,

    input  wire                disp_en,
    input  wire [`RTU_E_W-1:0] disp_data,
    input  wire                reload_en,
    input  wire [`RTU_E_W-1:0] reload_data,

    input  wire                cmplt_hit,
    input  wire                resolve_hit,
    input  wire                resolve_taken,
    input  wire                resolve_mispred,
    input  wire [31:0]         resolve_target,

    input  wire                flush_clr,

    output wire [`RTU_E_W-1:0] entry_q,
    output wire [`RTU_E_W-1:0] entry_d
);

    reg [`RTU_E_W-1:0] q;
    reg [`RTU_E_W-1:0] upd;

    // ---- 自更新 (完成 / 解析) ----
    always @(*) begin
        upd = q;
        if (cmplt_hit) begin
            upd[`RTU_E_CMPLT] = 1'b1;
        end
        if (resolve_hit) begin
            upd[`RTU_E_TARGET]  = resolve_target;
            upd[`RTU_E_TAKEN]   = resolve_taken;
            upd[`RTU_E_MISPRED] = resolve_mispred;
        end
    end

    // ---- 写入优先级 ----
    assign entry_d = flush_clr ? {`RTU_E_W{1'b0}} :
                     reload_en ? reload_data         :
                     disp_en   ? disp_data           : upd;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) q <= {`RTU_E_W{1'b0}};
        else         q <= entry_d;
    end

    assign entry_q = q;

endmodule
