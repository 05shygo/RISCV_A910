`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_flush — 冲刷状态机 + 重定向分发 (D11 / §6.3 ①)。
//
//   IDLE --(退休窗口出现 flush 源)--> F1 --(无条件)--> F2 --(无条件)--> IDLE
//
//   T   : IDLE & flush_trig —— 退休窗口照常出信号; **本拍就** 拉高 disp_stall 与
//         beu_mask, 并向前端发一次重定向 (目标见 §6.3 ⑨)。
//   T+1 : F1 —— backend_flush (冲发射队列/执行级/存储队列) + 清 expt_entry。
//   T+2 : F2 —— ren_flush + AMT 整表覆盖 + ALLOC/WF_ALLOC -> FREE + ROB 指针复位。
//   T+3 : IDLE —— disp_stall 放开, 派遣恢复。
//
// ⚠️ `disp_stall` 从 **T 拍** 就要起来 (不是 T+1): 从这一刻到 FLUSH_2 之间派出去的
//    指令, 都是拿"还没恢复的 RAT"改名出来的, 只能在 F2 被冲掉 —— 而冲掉之后
//    前端必须从重定向目标重取 (所以本模块在 T 拍就重定向前端, 而不是等到 F2)。
//    这条漏了, 症状是"偶发算错、极难复现" (D3.1 的前提③)。
// ⚠️ `beu_mask` (rtu_beu_flush_chgflw_mask) 同样从 T 拍起 —— 漏了会让两次重定向打架。
// ---------------------------------------------------------------------------
module RTU_flush (
    input  wire         cpu_clk,
    input  wire         cpu_rst,

    input  wire         flush_trig,
    input  wire [1:0]   flush_src,
    input  wire [31:0]  flush_pc,
    input  wire [223:0] amt_flat,        // 架构映射表 (RTU_preg 出)

    output wire         fsm_busy,        // 非 IDLE: 判退要停
    output wire         flushing,        // 含 T 拍: 冻派遣 + 屏蔽 BEU
    output wire         backend_flush,   // T+1
    output wire         expt_clr,        // T+1
    output wire         flush_lvl,       // T+2: ALLOC->FREE / RAT 覆盖 / 指针复位
    output wire         ren_flush,
    output wire         ren_recover_vld,
    output wire [223:0] ren_recover_map,
    output wire         beu_mask,
    output wire         ifu_flush,
    output wire         ifu_chgflw_vld,
    output wire [31:0]  ifu_chgflw_pc
);

    reg [1:0] st_q;
    reg [31:0] pc_q;

    wire idle = (st_q == `RTU_FSM_IDLE);
    wire f1   = (st_q == `RTU_FSM_F1);
    wire f2   = (st_q == `RTU_FSM_F2);

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            st_q <= `RTU_FSM_IDLE;
            pc_q <= 32'd0;
        end else begin
            case (st_q)
                `RTU_FSM_IDLE: st_q <= flush_trig ? `RTU_FSM_F1 : `RTU_FSM_IDLE;
                `RTU_FSM_F1  : st_q <= `RTU_FSM_F2;
                default      : st_q <= `RTU_FSM_IDLE;
            endcase
            if (flush_trig) pc_q <= flush_pc;   // 目标留下来, 供 F1/F2 期间读
        end
    end

    assign fsm_busy = ~idle;
    assign flushing = flush_trig | ~idle;

    assign backend_flush = f1;
    assign expt_clr      = f1;

    assign flush_lvl       = f2;
    assign ren_flush       = f2;
    assign ren_recover_vld = f2;
    assign ren_recover_map = amt_flat;

    assign beu_mask = flushing;

    // 重定向在 T 拍发出 (与"哪些指令会被冲掉"必须同拍, 见文件头)
    assign ifu_flush       = flush_trig;
    assign ifu_chgflw_vld  = flush_trig;
    assign ifu_chgflw_pc   = flush_trig ? flush_pc : pc_q;

endmodule
