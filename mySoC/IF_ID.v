`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// Design Name: 
// Module Name: IF_ID
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


`include "defines.vh"

module IF_ID(
    input               clk,
    input               rst,
    input               stall,
    input               flush,
    // 取指气泡 (IFU 集成): 本拍没有可捕获的指令时灌一个气泡,
    // 让流水线照常前进而不是保持 (EX_MEM 的 stall 是"插气泡"语义,
    // 把取指停顿传到后面各级会让同一条指令被重复提交).
    input               if_bubble,
    input [31:0]        if_pc,
    input [31:0]        if_pc4,
    input [31:0]        if_inst,
    // 该指令的预测后继 PC, 带到 EX 级与真实后继比较 (误预测重定向用)
    input [31:0]        if_pred_npc,
    // 取指故障包 (IFU 集成): fault/cause 带到 ID 级当异常报
    input               if_fault,
    input [3:0]         if_cause,
    // BHT 检查快照 (IFU 集成): 预测当时的 {计数器低位, 选择器, 分支前 VGHR},
    // 以及当时给出的方向预测. 一起带到 EX 级, 分支解析时回送给 BHT 训练.
    input [24:0]        if_bht_chk,
    input               if_bht_pred,
    output reg [31:0]   id_pc,
    output reg [31:0]   id_pc4,
    output reg [31:0]   id_inst,
    output reg [31:0]   id_pred_npc,
    output reg          id_fault,
    output reg [3:0]    id_cause,
    output reg [24:0]   id_bht_chk,
    output reg          id_bht_pred,
    output reg          id_have_inst
    );

// id_have_inst: 这个槽位里到底有没有一条真实取到的指令.
//
// 以前这个信息由 Control.v 的 opcode 白名单"猜"出来, 但那个办法有两个洞:
//   1. 白名单不含 0x73, 于是 ecall/ebreak/csr/mret 永远不提交;
//   2. 未知 opcode 一律记 0, 于是【非法指令也不会提交】, trap 根本发不出去,
//      golden model 等不到提交脉冲会一直卡住.
// 而靠 "id_inst != 0" 来判也不行: 气泡正好就是全零, 而 .word 0x00000000
// 恰恰是一条合法的"非法指令"用例, 两者必须区分开.
// 所以只能真的带一位: 正常捕获置 1, flush/rst 清 0, 停顿保持.
always @(posedge clk or posedge rst) begin
    if(rst == `RstEnable || flush) begin
        id_pc <= 0;
        id_pc4 <= 0;
        id_inst <= 0;
        id_pred_npc <= 0;
        id_fault <= 1'b0;
        id_cause <= 4'd0;
        id_bht_chk <= 25'd0;
        id_bht_pred <= 1'b0;
        id_have_inst <= 1'b0;
    end else if(stall) begin
        // stall 必须排在 if_bubble 前面: load-use 停顿时 if_accept=0,
        // 若先判 if_bubble 会把 ID 级这条刚被停住的指令悄悄清掉.
        id_pc <= id_pc;
        id_pc4 <= id_pc4;
        id_inst <= id_inst;
        id_pred_npc <= id_pred_npc;
        id_fault <= id_fault;
        id_cause <= id_cause;
        id_bht_chk <= id_bht_chk;
        id_bht_pred <= id_bht_pred;
        id_have_inst <= id_have_inst;
    end else if(if_bubble) begin
        id_pc <= 0;
        id_pc4 <= 0;
        id_inst <= 0;
        id_pred_npc <= 0;
        id_fault <= 1'b0;
        id_cause <= 4'd0;
        id_bht_chk <= 25'd0;
        id_bht_pred <= 1'b0;
        id_have_inst <= 1'b0;
    end else begin
        id_pc <= if_pc;
        id_pc4 <= if_pc4;
        id_inst <= if_inst;
        id_pred_npc <= if_pred_npc;
        id_fault <= if_fault;
        id_cause <= if_cause;
        id_bht_chk <= if_bht_chk;
        id_bht_pred <= if_bht_pred;
        id_have_inst <= 1'b1;
    end
end


endmodule

