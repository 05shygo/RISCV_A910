`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// Design Name: 
// Module Name: EX_MEM
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

module EX_MEM(
    input                           clk          ,
    input                           rst          ,
    input                           stall        ,  // muldiv 停顿时插气泡
    input                           flush        ,  // 陷阱重定向: 清空气泡
    // 这条指令会不会产生【已经发生、无法撤销】的副作用.
    // 中断只能落在 irq_safe 的提交点上: 被 squash 的指令若已经写过内存
    // (MEM 级) 或写过 CSR (EX 级), squash 会让 DUT 与 golden model 永久不一致.
    input                           ex_irq_safe  ,
    // 异常 (在 EX 级检出的非对齐; ID 级检出的非法/ecall/ebreak 也会带过来)
    input                           ex_exc_valid ,
    input [3:0]                     ex_exc_cause ,
    input [31:0]                    ex_exc_tval  ,
    input                           ex_is_mret   ,
    // 本条指令在 ROB 里的 iid (见 ID_EX.v): 完成/异常口要按它寻址 (§6.3 ⑪)
    input [6:0]                     ex_iid       ,
    // CSR 指令的**源操作数**(转发后的 rs1)。CSR 写搬到退休拍之后, RS/RC 的
    // "旧值 | 源"要在退休那拍由 RTU 现算, 而退休那拍 EX 早换人了 —— 所以这个
    // 操作数必须随指令走到 WB (阶段 1 的等价物: PRF 读口在阶段 2 才接)。
    input [31:0]                    ex_csr_src   ,
    // 这条指令是不是 CSR 写. 一路带到 WB, 供 difftest 判断"CSR 文件是否静止":
    // DUT 在 EX 级就写了 CSR(比提交早 2 拍), 而 golden model 是在提交当拍才写,
    // 所以只有在【没有 CSR 写在任何一级在途】时, 两边的 CSR 才一定一致.
    input                           ex_csr_we    ,
    input                           ex_rf_we     ,
    // 这条指令是乘法. 乘法的结果不在 ex_wD/mem_wD 里 —— 它 2 拍后才从乘除法单元
    // 自己的写回口出来, 由 mycpu.v 在 WB 级用这个标志把它换进 wb_wD。
    // 一路带到 WB 是为了让"响应属于哪条指令"由指令自己说了算, 而不是靠数拍数。
    input                           ex_is_mul    ,
    input                           ex_ram_we    ,
    input [31:0]                    ex_alu_c     ,
    input [`DRAM_SEL_WIDTH-1:0]     ex_dram_sel  ,
    input [`RF_WSEL_WIDTH-1:0]      ex_rf_wsel   ,
    input [31:0]                    ex_rD2       ,
    input [4:0]                     ex_wR        ,
    input [31:0]                    ex_wD        ,
    output reg                      mem_rf_we    ,
    output reg                      mem_ram_we   ,
    output reg [31:0]               mem_alu_c    ,
    output reg [31:0]               mem_rD2      ,
    output reg [`DRAM_SEL_WIDTH-1:0]mem_dram_sel ,
    output reg [`RF_WSEL_WIDTH-1:0] mem_rf_wsel  ,
    output reg [4:0]                mem_wR       ,
    output reg [31:0]               mem_wD_temp  ,
    output reg                      mem_is_mul   ,
    output reg                      mem_irq_safe ,
    output reg                      mem_exc_valid,
    output reg [3:0]                mem_exc_cause,
    output reg [31:0]               mem_exc_tval ,
    output reg                      mem_is_mret ,
    output reg                      mem_csr_we  ,
    output reg [6:0]                mem_iid     ,
    output reg [31:0]               mem_csr_src

    //trace
    ,input  wire [31:0] pc_i       ,
    output reg  [31:0] pc_o       ,
    input  wire        have_inst_i,
    output reg         have_inst_o
    );

always @(posedge clk or posedge rst) begin
    if(rst) begin
        mem_rf_we    <= 0;
        mem_ram_we   <= 0;
        mem_alu_c    <= 0;
        mem_rD2      <= 0;
        mem_dram_sel <= 0;
        mem_rf_wsel  <= 0;
        mem_wR       <= 0;
        mem_wD_temp  <= 0;
        mem_is_mul   <= 1'b0;
        mem_irq_safe <= 1'b1;
        mem_exc_valid<= 1'b0;
        mem_exc_cause<= 0;
        mem_exc_tval <= 0;
        mem_is_mret  <= 1'b0;
        mem_csr_we   <= 1'b0;
        mem_iid      <= 7'd0;
        mem_csr_src  <= 32'd0;
    end else if (stall || flush) begin
        // stall: muldiv 停顿 -> 向 MEM 级插入气泡, 让 MEM/WB 正常排空.
        //   这里不能"保持": MEM_WB 没有停顿端口, 会照常锁存, 于是被冻结的
        //   同一条指令会在 debug_wb_* 上连续多拍重复出现, 被 difftest 当成
        //   多次提交 (停顿越久重复越多).
        // flush: 陷阱重定向 -> 与 stall 做同样的事(清成气泡).
        //   两者必须落在同一个 always 分支里做同一件事: flush 不是"另一种
        //   保持", 否则年轻指令会漏进 MEM/WB.
        mem_rf_we    <= 0;
        mem_ram_we   <= 0;
        mem_alu_c    <= 0;
        mem_rD2      <= 0;
        mem_dram_sel <= 0;
        mem_rf_wsel  <= 0;
        mem_wR       <= 0;
        mem_wD_temp  <= 0;
        mem_is_mul   <= 1'b0;
        mem_irq_safe <= 1'b1;
        mem_exc_valid<= 1'b0;
        mem_exc_cause<= 0;
        mem_exc_tval <= 0;
        mem_is_mret  <= 1'b0;
        mem_csr_we   <= 1'b0;
        mem_iid      <= 7'd0;
        mem_csr_src  <= 32'd0;
    end else begin
        mem_rf_we    <= ex_rf_we   ;
        mem_ram_we   <= ex_ram_we  ;
        mem_alu_c    <= ex_alu_c   ;
        mem_rD2      <= ex_rD2     ;
        mem_dram_sel <= ex_dram_sel;
        mem_rf_wsel  <= ex_rf_wsel ;
        mem_wR       <= ex_wR      ;
        mem_wD_temp  <= ex_wD      ;
        mem_is_mul   <= ex_is_mul  ;
        mem_irq_safe <= ex_irq_safe;
        mem_exc_valid<= ex_exc_valid;
        mem_exc_cause<= ex_exc_cause;
        mem_exc_tval <= ex_exc_tval;
        mem_is_mret  <= ex_is_mret ;
        mem_csr_we   <= ex_csr_we  ;
        mem_iid      <= ex_iid     ;
        mem_csr_src  <= ex_csr_src ;
    end
end

//trace
// 与上面的 payload 块保持一致: 停顿/冲刷时该槽位是气泡, 不能继续携带原指令的
// pc/have_inst, 否则会重复提交.
always @ (posedge clk or posedge rst) begin
    if (rst) pc_o <= 32'b0;
    else if (stall || flush) pc_o <= 32'b0;
    else pc_o <= pc_i;
end
always @ (posedge clk or posedge rst) begin
    if (rst) have_inst_o <= 1'b0;
    else if (stall || flush) have_inst_o <= 1'b0;
    else have_inst_o <= have_inst_i;
end
endmodule

