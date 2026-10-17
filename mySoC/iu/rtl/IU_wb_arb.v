`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// IU_wb_arb —— 两个执行单元抢同一个写回口时的**严格 round-robin** 仲裁。
//
// 当前用法 (A910): A = ALU1, B = MUL/DIV。两者共用 IDU 的 pipe2 写回口。
//
// 【为什么不是"固定优先级"】
//   乘法结果在 MUL_DIV 里**没有输出缓冲**、定延迟 2 拍，ALU1 的结果则在
//   IU_alu_pipe 里可以保持。若写成"MD 优先"，只要 MD 连续有结果，ALU1 会被
//   无限期压住、AIQ1 反过来被 stall 堵满；若写成"ALU1 优先"，MD 的乘法结果
//   会被压到它的 skid 里、再反压 MUL_DIV。两种固定优先级都会把一侧的队列
//   顶死。RR 的硬保证是：**两边同时请求时交替授权**，所以任一侧最多等一拍，
//   两个 skid/保持寄存器都只需很浅的深度。
//
// 【协议】
//   * req_* 必须**一直保持到 grant 为止** (调用方负责: ALU1 用 EX2 保持,
//     MD 用 skid FIFO 的队头保持)。本模块不缓冲、不记忆请求。
//   * 只有一侧请求时，它每拍都能拿到口 (不会因为"上一拍是它"而空转)。
//   * 两侧同时请求时，上一拍拿过口的一侧让路。
//   * flush 把 RR 状态清回 A 侧；这只是为了复位/冲刷后的确定性，不影响正确性
//     (冲刷拍两侧的请求都会被各自的 valid 清掉)。
// ---------------------------------------------------------------------------
module IU_wb_arb (
    input  wire cpu_clk,
    input  wire cpu_rst,          // 高有效, 与 IU wrapper 同口径
    input  wire flush,            // = rtu_yy_xx_flush

    input  wire req_a,
    input  wire req_b,
    output wire gnt_a,
    output wire gnt_b,

    output wire last_b          // 观察口: 1 = 上一拍授权给了 B (调试用)
);

    // last_b = 0: 上一拍给 A; 1: 上一拍给 B
    reg last_b_q;

    // 两侧同时请求时给"上一拍没拿到"的那一侧; 只有一侧请求时直接给它。
    assign gnt_a = req_a & (~req_b | last_b_q);
    assign gnt_b = req_b & (~req_a | ~last_b_q);

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            last_b_q <= 1'b0;
        else if (flush)
            last_b_q <= 1'b0;
        else if (gnt_b)
            last_b_q <= 1'b1;      // 授权给 B ⇒ 下一次冲突让 A 先
        else if (gnt_a)
            last_b_q <= 1'b0;      // 授权给 A ⇒ 下一次冲突让 B 先
        // 无授权 ⇒ 状态保持
    end

    assign last_b = last_b_q;

endmodule
