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
    // 本项这一拍被退休弹出 —— 清成 0。
    // ⚠️ `vld` 的语义必须是"这一格**现在**装着一条在途指令": 阵列不随指针绕圈
    //    自动失效, 所以弹出时不清的话, 那些格子会一直挂着上一代 (甚至上上代) 的
    //    vld=1/cmplt=1。窗口的"补空"路径与 pop 后的重填都拿 vld 当"这格有没有
    //    东西", 于是 ROB 快排空时会把旧表项当成在途项补进窗口 —— 判退级联按它
    //    再发一次交付脉冲, 症状是"同一条指令退休两次"(实机: trap.S 的 wait_loop
    //    里 0x304 被重复提交, 而参考流早就往前走了)。
    input  wire                pop_en,
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
    // 优先级: flush > disp > pop > reload > 自更新。
    //   * flush 高于一切 (FLUSH_2 与指针复位同拍);
    //   * disp 与 pop 不会撞: 弹出的下标是 [rptr, rptr+pop_n), 派遣的是
    //     [rptr+occ, ...), 而 pop_n <= occ, 两个区间不相交;
    //   * pop 高于 reload: 影子窗口只 reload 不 pop, 顺序在这里只是防御。
    assign entry_d = flush_clr ? {`RTU_E_W{1'b0}} :
                     disp_en   ? disp_data           :
                     pop_en    ? {`RTU_E_W{1'b0}}    :
                     reload_en ? reload_data         : upd;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) q <= {`RTU_E_W{1'b0}};
        else         q <= entry_d;
    end

    assign entry_q = q;

endmodule
