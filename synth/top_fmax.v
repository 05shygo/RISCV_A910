`timescale 1ns / 1ps

// ===========================================================================
// 综合/Fmax 测量专用顶层 (不参与仿真)
//
// 只做一件事: 把 miniRV_SoC 包一层显式 BUFG, 让 create_clock 的约束口径干净。
// 全部输入来自片内触发器/时钟, 不接物理管脚 (I/O 约束见 build_fmax.tcl)。
//
// 调试口 (RUN_TRACE) 直接引到输出端口 —— 它们本来就是把流水线里已有的寄存器
// 引出来, 不新增逻辑; 引出来只是为了让这些 tap 不被优化掉。
// ===========================================================================
module top_fmax (
    input  wire        clk,
    input  wire        rst,

    output wire [31:0] o_dbg_pc,
    output wire [31:0] o_dbg_value,
    output wire [ 4:0] o_dbg_reg,
    output wire        o_dbg_ena,
    output wire        o_dbg_have
);

    wire clk_buf;

    BUFG u_bufg (
        .I (clk),
        .O (clk_buf)
    );

    miniRV_SoC u_soc (
        .fpga_rst           (rst),
        .fpga_clk           (clk_buf),

        .debug_wb_have_inst (o_dbg_have),
        .debug_wb_pc        (o_dbg_pc),
        .debug_wb_ena       (o_dbg_ena),
        .debug_wb_reg       (o_dbg_reg),
        .debug_wb_value     (o_dbg_value)
    );

endmodule
