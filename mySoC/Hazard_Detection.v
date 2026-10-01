`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/07/11 10:21:58
// Design Name: 
// Module Name: Hazard_Detection
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

module Hazard_Detection(
    input              id_rf1_used  ,
    input              id_rf2_used  ,
    input [`RF_WSEL_WIDTH-1:0] ex_rf_wsel   ,
    input [4:0]        ex_wR        ,
    input [4:0]        mem_wR       ,
    input [4:0]        wb_wR        ,
    input [31:0]       ex_wD        ,
    input [31:0]       mem_wD       ,
    input [31:0]       wb_wD        ,
    input [31:0]       id_rR1       ,
    input [31:0]       id_rR2       ,
    input              branched     ,
    input              ex_rf_we     ,
    input              mem_rf_we    ,
    input              wb_rf_we     ,
    // ---- RV32M 重构后新增 ----
    // ex_is_mul/mem_is_mul: 乘法在飞标志。乘法是**真流水**了 (II=1), 结果 2 拍后
    //   才从自己的写回口出来, 所以在它走到 WB 之前:
    //     * ex_wD/mem_wD 里是 ALU 对 MUL 算子的垃圾值 —— 绝不能前递 (见下面
    //       RAW_A/RAW_B 的 ~ex_is_mul / ~mem_is_mul 门控);
    //     * 消费者必须停 ID, 直到乘法进 WB 由现成的 RAW_C 通路喂给它。
    // div_stall: 除法忙 (占住 EX 等结果); 对 ID 级只表现为整体停顿。
    input              ex_is_mul    ,
    input              mem_is_mul   ,
    input              div_stall    ,
    input              trap         , // 陷阱/中断重定向 (来自 WB 提交点)
    output reg         stall        ,
    output reg         flush_IF_ID  ,
    output reg         flush_ID_EX  ,
    output wire        mul_stall    , // 只做停顿归因统计 (TB 分桶), 不参与时序
    output reg [31:0]  A_forward    ,
    output reg [31:0]  B_forward    ,
    output wire        Forward_A_en ,
    output wire        Forward_B_en
);


// 前递源要排除乘法: 乘法的 ex_wD/mem_wD 不是它的结果 (结果是 2 拍后从写回口
// 单独出来的), 转发了就是错的。被排除的那几条由 mul_stall 顶住, 不会漏。
wire RAW_A_rD1 = (ex_wR  == id_rR1) && ex_rf_we  && id_rf1_used && ~(ex_wR==0) && ~ex_is_mul;
wire RAW_A_rD2 = (ex_wR  == id_rR2) && ex_rf_we  && id_rf2_used && ~(ex_wR==0) && ~ex_is_mul;


wire RAW_B_rD1 = (mem_wR == id_rR1) && mem_rf_we && id_rf1_used && ~(mem_wR==0) && ~mem_is_mul;
wire RAW_B_rD2 = (mem_wR == id_rR2) && mem_rf_we && id_rf2_used && ~(mem_wR==0) && ~mem_is_mul;


wire RAW_C_rD1 = (wb_wR  == id_rR1) && wb_rf_we  && id_rf1_used && ~(wb_wR==0);
wire RAW_C_rD2 = (wb_wR  == id_rR2) && wb_rf_we  && id_rf2_used && ~(wb_wR==0);

assign Forward_A_en = RAW_A_rD1 || RAW_B_rD1 || RAW_C_rD1;
assign Forward_B_en = RAW_A_rD2 || RAW_B_rD2 || RAW_C_rD2;


always @ (*) begin
    if (RAW_A_rD1)      A_forward = ex_wD;
    else if (RAW_B_rD1) A_forward = mem_wD;
    else if (RAW_C_rD1) A_forward = wb_wD;
    else                A_forward = 32'b0;
end

always @ (*) begin
    if (RAW_A_rD2)      B_forward = ex_wD; 
    else if (RAW_B_rD2) B_forward = mem_wD;
    else if (RAW_C_rD2) B_forward = wb_wD; 
    else                B_forward = 32'b0; 
end

wire load_use_exist = (RAW_A_rD1 || RAW_A_rD2) & (ex_rf_wsel == `RF_WSEL_DRAM);

// ---------------------------------------------------------------------------
// 乘法互锁 (doc §7 的 N 项小队列表)
// ---------------------------------------------------------------------------
// 顺序核里不需要另建列表: `ex_is_mul/ex_wR` 与 `mem_is_mul/mem_wR` **就是**那份
// 在飞列表 —— 乘法在 EX 的那一拍一定是刚发射的那一条, 而 II=1 保证同一拍最多
// 一条。所以互锁退化成两个比较器。
//
// 停顿拍数与消费者的距离有关, 逻辑自动给出:
//   距离 0 (紧跟乘法的那条): 乘法在 EX 停 1 拍、在 MEM 再停 1 拍 ⇒ 停 2 拍;
//   再往后: 乘法已经进 WB, RAW_C 直接喂给它, **不用停**。
wire mul_raw1_e = ex_is_mul  & ex_rf_we  & ~(ex_wR ==0) & (ex_wR  == id_rR1) & id_rf1_used;
wire mul_raw2_e = ex_is_mul  & ex_rf_we  & ~(ex_wR ==0) & (ex_wR  == id_rR2) & id_rf2_used;
wire mul_raw1_m = mem_is_mul & mem_rf_we & ~(mem_wR==0) & (mem_wR == id_rR1) & id_rf1_used;
wire mul_raw2_m = mem_is_mul & mem_rf_we & ~(mem_wR==0) & (mem_wR == id_rR2) & id_rf2_used;

assign mul_stall = mul_raw1_e | mul_raw2_e | mul_raw1_m | mul_raw2_m;

always @ (*) begin
    if (load_use_exist || div_stall || mul_stall) stall = 1'b1;
    else                                          stall = 1'b0;
end

// 陷阱/中断重定向也是冲刷源, 且优先级最高(它来自 WB 提交点, 比 EX 级的分支
// 更"老"). 必须 OR 进这两条既有信号里, 而不是另起一个名字: 下游模块只认
// flush_IF_ID / flush_ID_EX, 另起名字会让 stall 在那两个模块里赢过陷阱.
always @ (*) begin
    if (branched || trap) flush_IF_ID = 1'b1;
    else                  flush_IF_ID = 1'b0;
end

// mul_stall 必须和 load_use_exist 走**同一个**分支: 两者的语义都是"把 ID 那条
// 指令留在 ID、同时把 EX 变成气泡"。
//   - 只拉 stall 不拉 flush_ID_EX 会把 ID_EX 保持住 ⇒ 乘法卡在 EX 不走 ⇒ 冒险
//     永远解不开 (而且 valid 一直为高, 会在同一个请求上重复写回);
//   - ID_EX 清成气泡之后乘法照常前进 (EX_MEM 是正常捕获), 两拍后进 WB。
// 这一条与 load-use 完全同构, 只是停 2 拍而不是 1 拍。
//
// ⚠️ `~div_stall` 不能省。清 ID_EX 的前提是"EX 里那条指令该往前走"; 除法是
// **占住 EX 等结果**的 (div_stall 期间 ID_EX 是在"保持", 整条前端都冻结)。
// 而 mul_stall 看的是 EX **和 MEM** 两级: 完全可能出现
//     mul x5,.. ; div x6,.. ; add x7,x5,x6      (div 与 mul 无依赖, 所以 div 走到 EX)
// 这一拍除法正在 EX 里迭代、乘法正好退到 MEM、而 ID 里那条要用乘法的 rd ——
// 不加这个门控就会把 ID_EX 清掉, 除法**从流水里凭空消失**, 结果永远不写回。
// (被冻结的 ID 指令本来也不会前进, 所以这里不清没有任何副作用; 乘法进 WB 时
//  ID 指令要么还被除法冻着, 要么已经从 RegFile 拿到值。)
always @ (*) begin
    if (load_use_exist || (mul_stall & ~div_stall) || branched || trap)
         flush_ID_EX = 1'b1;
    else flush_ID_EX = 1'b0;
end
endmodule
/*
module Hazard_Detection(
    input id_rf1_used,
    input id_rf2_used,
    input [31:0] ex_mem_wD,
    input [31:0] mem_wb_wD,
    input [4:0] if_id_RegisterRs1,
    input [4:0] if_id_RegisterRs2,
    input [4:0] id_ex_RegisterRs1,
    input [4:0] id_ex_RegisterRs2,
    input ex_mem_RegWrite,
    input [4:0] ex_mem_RegisterRd,
    input mem_wb_RegWrite,
    input [4:0] mem_wb_RegisterRd,
    input id_ex_MemRead,
    input branched,
    output reg Forward_A_en,
    output reg Forward_B_en,
    output reg [31:0] A_forward,
    output reg [31:0] B_forward,
    output reg stall,
    output reg flush_if_id,
    output reg flush_id_ex
    );

//reg [31:0] ex_mem_wD;
//reg [31:0] ex_mem_wD;
//always @(*) begin
    
//end



always @(*) begin
    if(id_rf1_used && ex_mem_RegWrite && ~(ex_mem_RegisterRd==0) && (ex_mem_RegisterRd==id_ex_RegisterRs1)) begin
        Forward_A_en = 1;
        A_forward = ex_mem_wD;
    end else begin
        Forward_A_en = 0;
        A_forward = 32'hFFFFFFFF;
    end
end

always @(*) begin
    if(id_rf2_used && ex_mem_RegWrite && ~(ex_mem_RegisterRd==0) && (ex_mem_RegisterRd==id_ex_RegisterRs2)) begin
        Forward_B_en = 1;
        B_forward = ex_mem_wD;
    end else begin
        Forward_B_en = 0;
        B_forward = 32'hFFFFFFFF;
    end
end


always @(*) begin
    if(id_rf1_used && mem_wb_RegWrite && ~(mem_wb_RegisterRd==0) && ~(ex_mem_RegWrite && ~(ex_mem_RegisterRd==0) && (ex_mem_RegisterRd==id_ex_RegisterRs1)) && (mem_wb_RegisterRd==id_ex_RegisterRs1)) begin
        Forward_A_en = 1;
        A_forward = mem_wb_wD;
    end else begin
        Forward_A_en = 0;
        A_forward = 32'hFFFFFFFF;
    end
end

always @(*) begin
    if(id_rf2_used && mem_wb_RegWrite && ~(mem_wb_RegisterRd==0) && ~(ex_mem_RegWrite && ~(ex_mem_RegisterRd==0) && (ex_mem_RegisterRd==id_ex_RegisterRs2)) && (mem_wb_RegisterRd==id_ex_RegisterRs1)) begin
        Forward_B_en = 1;
        B_forward = mem_wb_wD;
    end else begin
        Forward_B_en = 0;
        B_forward = 32'hFFFFFFFF;
    end
end


wire load_use_exist = id_ex_MemRead && ((id_ex_RegisterRs1==if_id_RegisterRs1) || (id_ex_RegisterRs2==if_id_RegisterRs2));

always @(*) begin
    if(load_use_exist) begin
        stall = 1;
    end else begin
        stall = 0;
    end
end

always @(*) begin
    if(branched) begin
        flush_if_id = 1;
    end else begin
        flush_if_id = 0;
    end
end

always @(*) begin
    if(load_use_exist || branched) begin
        flush_id_ex = 1;
    end else begin
        flush_id_ex = 0;
    end
end

endmodule*/

