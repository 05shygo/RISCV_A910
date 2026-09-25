`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_refill — i-cache 需求回填 (BIU 主端小 FSM)
//
// 只做一件事: F1 报了一次 miss, 就去 BIU 取那一整行 16 B 回来, 写进阵列。
//
// 比 ifu_rv32i 的 l1_refill + ipb 少了什么, 以及为什么可以少:
//   * 没有"关键块优先转发"的分拍缓冲 —— 16 B 行就是**一整拍**, 没有块内拍序,
//     rv32ifu2_icache 里的一行旁路比较已经把这一拍省掉了。
//   * 没有 IPB(下一行预取) 的在途匹配/回放/取消状态机。预取在 Phase 1b 以
//     最简形式加入 (单个在途预取, 不做与需求的重叠匹配)。
//   * 没有错误/取消/维护/安装资格那一整套 —— 指令 ROM 只有一个 64 KB 区域,
//     没有 LSU 一致性 (代码只读), 也不做 CP0 维护。region 检查在顶层一次做完。
//
// 协议 (对手方 = mySoC/ifu_biu_mem.v): req && grnt 在边沿接受一笔事务;
// rd_len=2'b00 表示单拍; 返回拍 data_vld 与 r_ready 同时有效才算被消费。
// 本模块**不依赖** grant 恒 1 或"返回恰好晚一拍"这两个巧合, 换成真从端也能跑。
// ===========================================================================
module rv32ifu2_refill #(
    parameter IC_LINE = 16
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- 来自顶层 ----
    input  wire         req,           // 需要一个 16 B 行 (miss 且当前无事务)
    input  wire [ 31:0] req_pc,        // 触发这次回填的 PC

    output wire         busy,          // 有事务在途
    output wire         refill_en,     // 本拍把 refill_data 写进阵列
    output wire [ 31:0] refill_pc,
    output wire [127:0] refill_data,

    // ---- BIU 主端 ----
    output wire         biu_rd_req,
    output wire [ 31:0] biu_rd_addr,
    output wire         biu_rd_id,     // 0=demand
    output wire [  1:0] biu_rd_len,
    input  wire         biu_rd_grnt,
    input  wire         biu_rd_data_vld,
    input  wire [127:0] biu_rd_data,
    input  wire         biu_rd_rid,
    input  wire         biu_rd_last,
    input  wire [  1:0] biu_rd_resp,
    output wire         biu_r_ready
);

localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_REQ  = 2'd1;
localparam [1:0] S_WAIT = 2'd2;

localparam LINE_BITS = $clog2(IC_LINE);
localparam [1:0] RD_LEN_ONE = 2'b00;   // 单拍 = 16 B

reg [ 1:0] state_q;
reg [31:0] req_pc_q;

assign busy = (state_q != S_IDLE);

assign biu_rd_req  = (state_q == S_REQ);
assign biu_rd_addr = req_pc_q;         // 已按行对齐
assign biu_rd_id   = 1'b0;
assign biu_rd_len  = RD_LEN_ONE;
assign biu_r_ready = 1'b1;             // 返回拍一律立即消费, 不反压

wire launch = biu_rd_req & biu_rd_grnt;
wire fire   = biu_rd_data_vld & biu_r_ready;

assign refill_en   = (state_q == S_WAIT) & fire;
assign refill_pc   = req_pc_q;
assign refill_data = biu_rd_data;

// 返回拍必须认对事务: 只接受 demand (ID0) 的返回。
// 这里不额外比对 id —— 本模块同时在途只有一笔, 且 rd_id 恒 0; 将来加预取
// (ID1) 时, 这里要按 biu_rd_rid 分流, 别复用这一版。
always @(posedge clk) begin
    if (rst) begin
        state_q  <= S_IDLE;
        req_pc_q <= 32'd0;
    end else begin
        case (state_q)
            S_IDLE: if (req) begin
                        // 行对齐: 低 LINE_BITS 位清零
                        req_pc_q <= {req_pc[31:LINE_BITS], {LINE_BITS{1'b0}}};
                        state_q  <= S_REQ;
                    end
            S_REQ:  if (launch) state_q <= S_WAIT;
            S_WAIT: if (fire)   state_q <= S_IDLE;
            default:            state_q <= S_IDLE;
        endcase
    end
end

/* verilator lint_off UNUSED */
wire unused_rid  = biu_rd_rid;
wire unused_last = biu_rd_last;
wire unused_resp = biu_rd_resp[1];
/* verilator lint_on UNUSED */

endmodule
