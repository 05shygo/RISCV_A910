`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/07/11 09:11:34
// Design Name: 
// Module Name: ID_EX
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

module ID_EX(
    input                               clk          ,
    input                               rst          ,
    input                               stall        ,  // 流水线暂停信号
    input                               flush        ,
    input [`ALU_OP_WIDTH-1:0]           id_alu_op    ,
    input                               id_rf_we     ,
    input                               id_ram_we    ,
    input [`RF_WSEL_WIDTH-1:0]          id_rf_wsel   ,
    input [`DRAM_SEL_WIDTH-1:0]         id_dram_sel  ,
    input [31:0]                        id_rD2       ,
    input [31:0]                        id_pc4       ,
    // 预测后继 PC (IFU 集成): 带到 EX 级与真实后继比较
    input [31:0]                        id_pred_npc  ,
    input [`NPC_SEL_WIDTH-1:0]          id_npc_op    ,
    input [31:0]                        id_sext      ,
    input [31:0]                        id_A         ,
    input [31:0]                        id_B         ,
    // CSR 的源操作数是 rs1, 走 A 通路的转发; ALU 的 A 口已经被 CSR 旧值占了,
    // 所以这里单独再锁存一份"已转发的 rs1"
    input [31:0]                        id_rD1       ,
    input                               id_csr_imm   ,
    input [4:0]                         id_wR        ,
    input                               id_is_muldiv , // RV32M signal
    // ---- 系统指令 / CSR / 陷阱 ----
    input [2:0]                         id_csr_op    ,
    input [11:0]                        id_csr_addr  ,
    // CSR 读数据在 **ID 级**读出来 (地址用 id_csr_addr, 带 EX→ID 旁路),
    // 随流水锁进来。以前它是在 EX 级用锁存的 ex_csr_addr 组合读的 ——
    // 那条 16:1 mux 挂在 ALU 的 A 口上, 是 FPGA 关键路径的链头。见 mycpu.v。
    input [31:0]                        id_csr_rdata ,
    input                               id_csr_we    ,
    input                               id_is_mret   ,
    input                               id_exc_valid ,
    input [3:0]                         id_exc_cause ,
    input [31:0]                        id_exc_tval  ,
    // BHT 检查快照 (IFU 集成): 预测当时的 {计数器低位, 选择器, 分支前 VGHR}
    // 与当时的方向预测. EX 级解析条件分支时回送给 BHT 做训练/VGHR 修复.
    input [24:0]                        id_bht_chk   ,
    input                               id_bht_pred  ,
    input                               Forward_A_en ,
    input                               Forward_B_en ,
    input [31:0]                        A_forward    ,
    input [31:0]                        B_forward    ,
    output reg [`ALU_OP_WIDTH-1:0]      ex_alu_op    ,
    output reg                          ex_rf_we     ,
    output reg                          ex_ram_we    ,
    output reg [`RF_WSEL_WIDTH-1:0]     ex_rf_wsel   ,
    output reg [`DRAM_SEL_WIDTH-1:0]    ex_dram_sel  ,
    output reg [`RegBus]                ex_rD2       ,
    output reg [31:0]                   ex_sext      ,
    output reg [31:0]                   ex_pc4       ,
    output reg [31:0]                   ex_pred_npc  ,
    output reg [31:0]                   ex_A         ,
    output reg [31:0]                   ex_B         ,
    output reg [31:0]                   ex_rD1       ,
    output reg                          ex_csr_imm   ,
    output reg [4:0]                    ex_wR        ,
    output reg [`NPC_SEL_WIDTH-1:0]     ex_npc_op    ,
    output reg                          ex_is_muldiv , // RV32M signal
    // ---- 系统指令 / CSR / 陷阱 ----
    output reg [2:0]                    ex_csr_op    ,
    output reg [11:0]                   ex_csr_addr  ,
    output reg [31:0]                   ex_csr_rdata ,
    output reg                          ex_csr_we    ,
    output reg                          ex_is_mret   ,
    output reg                          ex_exc_valid ,
    output reg [3:0]                    ex_exc_cause ,
    output reg [31:0]                   ex_exc_tval  ,
    output reg [24:0]                   ex_bht_chk   ,
    output reg                          ex_bht_pred

    //trace
    ,input  wire [31:0] pc_i       ,
    output reg  [31:0] pc_o       ,
    input  wire        have_inst_i,
    output reg         have_inst_o
    );

always @(posedge clk or posedge rst) begin
    if(rst) begin
        ex_A        <= 0;
        ex_rD1      <= 0;
    end else if(Forward_A_en) begin
        // 两条一起走 A 通路的转发: ex_A 是给 ALU 的 A 口(CSR 指令时是 CSR
        // 旧值), ex_rD1 始终是"转发后的 rs1", 给 CSR 的源用.
        ex_A        <= A_forward;
        ex_rD1      <= A_forward;
    end else begin
        ex_A        <= id_A;
        ex_rD1      <= id_rD1;
    end
end

always @(posedge clk or posedge rst) begin
    if(rst) begin
        ex_B        <= 0;
        ex_rD2      <= 0;
    end else if(Forward_B_en) begin
        if(id_ram_we) begin
            ex_B <= id_B;
        end else begin
            ex_B <= B_forward;
        end
        ex_rD2 <= B_forward;
    end else begin
        ex_B        <= id_B;
        ex_rD2      <= id_rD2     ;
    end
end

always @(posedge clk or posedge rst) begin
    if(rst) begin
        ex_alu_op   <= 0;
        ex_rf_we    <= 0;
        ex_ram_we   <= 0;
        ex_rf_wsel  <= 0;
        ex_dram_sel <= 0;
        ex_is_muldiv <= 0;
        ex_sext     <= 0;
        ex_pc4      <= 0;
        ex_pred_npc <= 0;
        ex_wR       <= 0;
        ex_npc_op   <= 0;
        ex_csr_op   <= `CSR_OP_NONE;
        ex_csr_addr <= 0;
        ex_csr_rdata<= 0;
        ex_csr_we   <= 0;
        ex_csr_imm  <= 0;
        ex_is_mret  <= 0;
        ex_exc_valid<= 0;
        ex_exc_cause<= 0;
        ex_exc_tval <= 0;
        ex_bht_chk  <= 0;
        ex_bht_pred <= 0;
    end else if(flush) begin
        ex_alu_op   <= 0;
        ex_rf_we    <= 0;
        ex_ram_we   <= 0;
        ex_rf_wsel  <= 0;
        ex_dram_sel <= 0;
        ex_is_muldiv <= 0;
        ex_sext     <= 0;
        ex_pc4      <= 0;
        ex_pred_npc <= 0;
        ex_wR       <= 0;
        ex_npc_op   <= 0;
        ex_csr_op   <= `CSR_OP_NONE;
        ex_csr_addr <= 0;
        ex_csr_rdata<= 0;
        ex_csr_we   <= 0;
        ex_csr_imm  <= 0;
        ex_is_mret  <= 0;
        ex_exc_valid<= 0;
        ex_exc_cause<= 0;
        ex_exc_tval <= 0;
        ex_bht_chk  <= 0;
        ex_bht_pred <= 0;
    end else if(!stall) begin
        // 注意: 这里不能再用 stall 分支去清零 payload.
        // stall = load_use_exist | muldiv_stall, 而 muldiv_stall 期间正需要把
        // 这条 MUL/DIV 保持在 EX 级等 ready: 清零会抹掉 ex_rf_we/ex_wR,
        // 使结果算出来也无处写回, 并且 ex_is_muldiv 归零会让 muldiv_stall
        // 下一拍就自我解除.
        // 停顿(两个分支都不命中) => 寄存器保持; 清零只由 flush 负责.
        ex_alu_op   <= id_alu_op  ;
        ex_rf_we    <= id_rf_we   ;
        ex_ram_we   <= id_ram_we  ;
        ex_rf_wsel  <= id_rf_wsel ;
        ex_dram_sel <= id_dram_sel;
        ex_is_muldiv <= id_is_muldiv;
        ex_sext     <= id_sext    ;
        ex_pc4      <= id_pc4     ;
        ex_pred_npc <= id_pred_npc;
        ex_wR       <= id_wR      ;
        ex_npc_op   <= id_npc_op  ;
        ex_csr_op   <= id_csr_op  ;
        ex_csr_addr <= id_csr_addr;
        ex_csr_rdata<= id_csr_rdata;
        ex_csr_we   <= id_csr_we  ;
        ex_csr_imm  <= id_csr_imm ;
        ex_is_mret  <= id_is_mret ;
        ex_exc_valid<= id_exc_valid;
        ex_exc_cause<= id_exc_cause;
        ex_exc_tval <= id_exc_tval;
        ex_bht_chk  <= id_bht_chk ;
        ex_bht_pred <= id_bht_pred;
    end
end

//trace
// 条件链必须与上面的 payload 块一致: 停顿时保持, 否则会向流水线注入一条
// have_inst=1 但 payload 已清零、且 pc 属于尚未执行的 ID 级指令的"幽灵指令".
always @ (posedge clk or posedge rst) begin
    if (rst) pc_o <= 32'b0;
    else if (flush) pc_o <= 32'b0;
    else if (!stall) pc_o <= pc_i;
end
always @ (posedge clk or posedge rst) begin
    if (rst) have_inst_o <= 1'b0;
    else if(flush)  have_inst_o <= 1'b0;
    else if(!stall) have_inst_o <= have_inst_i;
end

endmodule

