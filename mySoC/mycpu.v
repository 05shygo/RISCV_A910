`timescale 1ns / 1ps

`include "defines.vh"

module myCPU (
    input  wire         cpu_rst,
    input  wire         cpu_clk,

    // Interface to IROM
    output wire [13:0]  inst_addr,
    input  wire [31:0]  inst,
    
    // Interface to Bridge
    output wire [31:0]  Bus_addr,
    input  wire [31:0]  Bus_rdata,
    output wire         Bus_wen,
    output wire [31:0]  Bus_wdata,

    // 定时器中断请求 (来自 perip_bridge 的 timer_int_flag, 电平有效).
    // 在本模块内过一级寄存器后使用, 与 TB 推给 golden model 的是同一级延迟.
    input  wire         timer_irq_in

`ifdef RUN_TRACE
    ,// Debug Interface
    output wire         debug_wb_have_inst,
    output wire [31:0]  debug_wb_pc,
    output               debug_wb_ena,
    output wire [ 4:0]  debug_wb_reg,
    output wire [31:0]  debug_wb_value
`endif
);
//trace
wire [31:0] pc_EX, pc_MEM, pc_WB;
wire        have_inst_ID, have_inst_EX, have_inst_MEM, have_inst_WB;


wire [31:0] if_npc;
wire [31:0] if_pc;
wire [31:0] id_pc;
wire [31:0] wb_pc;
wire [31:0] if_pc4;
wire [31:0] id_pc4;
wire [31:0] ex_pc4;

//wire [31:0] pc4;
wire [31:0] id_sext;
wire [31:0] ex_sext;
wire [31:0] mem_sext;
wire [31:0] wb_sext;
wire [`Sext_OP_WDITH-1:0] id_sext_op;
wire ex_alu_f;
wire [31:0] ex_alu_c;
wire [31:0] mem_alu_c;
wire [31:0] wb_alu_c;
wire [`NPC_SEL_WIDTH-1:0] id_npc_op;
wire [`NPC_SEL_WIDTH-1:0] ex_npc_op;
wire [`ALU_OP_WIDTH-1:0] id_alu_op;
wire [`ALU_OP_WIDTH-1:0] ex_alu_op;
wire [`ALUA_SEL_WIDTH-1:0] id_alua_sel;
wire [`ALUB_SEL_WIDTH-1:0] id_alub_sel;
wire [`RF_WSEL_WIDTH-1:0] id_rf_wsel;
wire [`RF_WSEL_WIDTH-1:0] ex_rf_wsel;
wire [`RF_WSEL_WIDTH-1:0] mem_rf_wsel;
wire [`RF_WSEL_WIDTH-1:0] wb_rf_wsel;
wire [`DRAM_SEL_WIDTH-1:0] id_dram_sel;
wire [`DRAM_SEL_WIDTH-1:0] ex_dram_sel;
wire [`DRAM_SEL_WIDTH-1:0] mem_dram_sel;
wire id_rf_we;
wire ex_rf_we;
wire mem_rf_we;
wire wb_rf_we;
wire id_ram_we;
wire ex_ram_we;
wire mem_ram_we;
wire [31:0] id_rD1;
wire [31:0] id_rD2;
wire [31:0] ex_rD2;
wire [31:0] mem_rD2;
wire [31:0] id_A;
wire [31:0] id_B;
wire [31:0] ex_A;
wire [31:0] ex_B;
wire [31:0] mem_DRAM_rdo;
wire [31:0] wb_DRAM_rdo;
wire [4:0] ex_wR;
wire [4:0] mem_wR;
wire [4:0] wb_wR;
wire [31:0] ex_wD;
wire [31:0] mem_wD;
wire [31:0] wb_wD;
wire [31:0] mem_wD_temp;

assign inst_addr = if_pc[15:2];
//assign Bus_wen = ram_we;
//assign Bus_wdata = rD2;
//assign Bus_addr = alu_c;

wire stall;
wire flush_if_id;
wire flush_id_ex;

wire id_rf1_used;
wire id_rf2_used;

wire branched;

// RV32M signals
wire id_is_muldiv;
wire ex_is_muldiv;
wire [31:0] muldiv_result;
wire muldiv_ready;
wire muldiv_busy;
wire muldiv_stall;

// ===================== 系统指令 / CSR / 陷阱 =====================
// ID 级 (Control 译码)
wire        id_is_illegal, id_is_ecall, id_is_ebreak, id_is_mret;
wire [2:0]  id_csr_op;
wire        id_csr_imm, id_csr_we;
wire [31:0] id_exc_tval;
wire [3:0]  id_exc_cause;
wire        id_exc_valid;

// ID_EX 锁存出来的 EX 级 CSR / 异常信号
wire [2:0]  ex_csr_op;
wire [11:0] ex_csr_addr;
wire        ex_csr_we, ex_is_mret, ex_csr_imm;
wire [31:0] ex_rD1;
wire        ex_exc_valid;
wire [3:0]  ex_exc_cause;
wire [31:0] ex_exc_tval;

// EX 级本地检出的异常 (非对齐)
wire        ex_local_exc_valid;
wire [3:0]  ex_local_exc_cause;
wire [31:0] ex_local_exc_tval;

// EX_MEM / MEM_WB 携带
wire        mem_irq_safe, mem_exc_valid, mem_is_mret, mem_csr_we;
wire [3:0]  mem_exc_cause;
wire [31:0] mem_exc_tval;
wire        wb_irq_safe, wb_exc_valid, wb_is_mret, wb_csr_we;
wire [3:0]  wb_exc_cause;
wire [31:0] wb_exc_tval;

// CSR 文件接口
wire [31:0] csr_rdata;
wire [31:0] csr_trap_vector;
wire [31:0] csr_mepc;
wire        csr_mstatus_mie, csr_mie_mtie, csr_mip_mtip;

// 定时器中断的寄存副本 (与 TB 推给 golden model 的信号同源同级)
reg timer_irq_d1;
always @(posedge cpu_clk or posedge cpu_rst) begin
    if (cpu_rst == `RstEnable) timer_irq_d1 <= 1'b0;
    else                       timer_irq_d1 <= timer_irq_in;
end

// WB(提交点)的陷阱裁决
wire wb_exc     = wb_exc_valid & have_inst_WB;
wire wb_mret    = wb_is_mret   & have_inst_WB;
// 中断只能落在【没有已发生副作用】的提交点: 被 squash 的指令若已经写过内存
// (MEM 级, 早一拍) 或写过 CSR(EX 级), squash 会造成 DUT 与 golden model 永久不一致.
wire irq_taken  = have_inst_WB & wb_irq_safe & ~wb_exc & ~wb_mret
                & csr_mip_mtip & csr_mie_mtie & csr_mstatus_mie;
// 重定向: 同步异常 / 中断入口 / mret, 三者都要求"跳到别处 + 冲掉年轻指令"
wire redirect   = wb_exc | irq_taken | wb_mret;
// 陷阱向量 / 返回地址: mret 走 mepc, 否则由 CSR 按 mtvec 模式解算
wire [31:0] redirect_pc = wb_mret ? csr_mepc : csr_trap_vector;
wire [31:0] trap_cause  = irq_taken ? `INTR_MTIP_CAUSE : {28'b0, wb_exc_cause};
wire [31:0] trap_tval   = irq_taken ? 32'b0 : wb_exc_tval;

// 有效的寄存器写使能: 陷阱指令不写 rd(非对齐 load 的 rf_we=1 必须按掉),
// 被中断 squash 掉的指令也不写. 必须从源头掐掉 —— 只改 debug_wb_ena 是不够的,
// 因为 RegFile 和转发逻辑(Hazard_Detection 的 wb_rf_we)都在用它.
wire wb_rf_we_eff = wb_rf_we & ~wb_exc & ~irq_taken;
// 提交脉冲 (被中断 squash 掉的那条不算退休, 否则 instret 会多计)
wire retire_now   = have_inst_WB & ~irq_taken;

// CSR 文件是否"静止": 没有任何一级存在途的 CSR 写, 也没有重定向.
// DUT 在 EX 级写 CSR(比提交早 2 拍), golden model 在提交当拍才写 ——
// 只有在静止时才保证两边读到同一个状态, 在途窗口里比较会误报.
// (陷阱自己的 mepc/mcause/mstatus 写发生在重定向边沿, 所以也排除 redirect.)
wire csr_quiescent = ~redirect & ~ex_csr_we & ~mem_csr_we & ~wb_csr_we;

// TODO: ?????????CPU??
NPC U_NPC(
    .rst(cpu_rst),
    .PC(if_pc),
    .offset(ex_sext),
    .br(ex_alu_f),
    .npc_op(ex_npc_op),
    .alu_c(ex_alu_c),
    .npc(if_npc),
    .pc4(if_pc4),
    .branched(branched)
);

PC U_PC(
    .clk(cpu_clk),
    .rst(cpu_rst),
    .stall(stall),
    .trap(redirect),
    .trap_pc(redirect_pc),
    .din(if_npc),
    .pc(if_pc)
);

wire [31:0] if_inst = inst;
wire [31:0] id_inst;

IF_ID U_IF_ID(
    .clk      (cpu_clk),
    .rst      (cpu_rst),
    .stall    (stall),
    .flush    (flush_if_id),
    .if_pc    (if_pc),
    .if_pc4   (if_pc4),
    .if_inst  (if_inst),
    .id_pc    (id_pc),
    .id_pc4   (id_pc4),
    .id_inst  (id_inst),
    .id_have_inst (have_inst_ID)
);
    
SEXT U_SEXT(
    .din(id_inst[31:7]),
    .sext_op(id_sext_op),
    .sext(id_sext)
);

Control U_Control(
    .opcode(id_inst[6:0]),
    .funct3(id_inst[14:12]),
    .funct7(id_inst[31:25]),
    .rs1_addr(id_inst[19:15]),
    .csr_addr(id_inst[31:20]),
    .sext_op(id_sext_op),
    .npc_op(id_npc_op),
    .alu_op(id_alu_op),
    .alua_sel(id_alua_sel),
    .alub_sel(id_alub_sel),
    .rf_wsel(id_rf_wsel),
    .dram_sel(id_dram_sel),
    .rf_we(id_rf_we),
    .ram_we(id_ram_we),
    .is_muldiv(id_is_muldiv),
    .id_rf1_used(id_rf1_used),
    .id_rf2_used(id_rf2_used),

    .is_illegal(id_is_illegal),
    .is_ecall  (id_is_ecall  ),
    .is_ebreak (id_is_ebreak ),
    .is_mret   (id_is_mret   ),
    .csr_op    (id_csr_op    ),
    .csr_imm   (id_csr_imm   ),
    .csr_we    (id_csr_we    )
);

// ID 级异常: 取指越界 / 非法指令 / ecall / ebreak.
// 必须用 have_inst_ID 门控: 流水线气泡的 id_inst 是全零, 而全零正好是
// "非法指令", 不门控的话每个气泡都会当成陷阱.
//
// 取指越界(instruction access fault, cause 1)优先级最高: IROM 只有 64KB,
// PC 跑到更外面时 inst_addr = if_pc[15:2] 会回绕, 取回来的是别的地址上的
// 指令字 —— 那是垃圾, 不能再按它译码, 只能报异常.
wire id_inst_oob = have_inst_ID & ~`INST_ADDR_OK(id_pc);

assign id_exc_valid = have_inst_ID & (id_inst_oob | id_is_illegal | id_is_ecall | id_is_ebreak);
assign id_exc_cause = id_inst_oob    ? `EXC_INST_ACCESS
                    : id_is_illegal ? `EXC_ILLEGAL_INST
                    : id_is_ecall   ? `EXC_ECALL_M
                    : id_is_ebreak  ? `EXC_BREAKPOINT
                    : 4'd0;
// 非法指令的 mtval 记指令本身, ecall/ebreak 记 0,
// 取指越界记那个取不到的地址 (规范)
assign id_exc_tval  = id_inst_oob    ? id_pc
                    : id_is_illegal ? id_inst : 32'b0;

RegFile U_RegFile(
    .rst(cpu_rst),
    .clk(cpu_clk),
    .rR1(id_inst[19:15]),
    .rR2(id_inst[24:20]),
    .wR(wb_wR),
    .we(wb_rf_we_eff),
    .wD(wb_wD),
    .rD1(id_rD1),
    .rD2(id_rD2)
);

ALU_input_MUX U_ALU_input_MUX(
    .rD1(id_rD1),
    .rD2(id_rD2),
    .pc(id_pc),
    .sext(id_sext),
    .alua_sel(id_alua_sel),
    .alub_sel(id_alub_sel),
    .A(id_A),
    .B(id_B)
);

wire [31:0] A_forward;
wire [31:0] B_forward;
wire Forward_A_en;
wire Forward_B_en;
ID_EX U_ID_EX(
    .clk           (cpu_clk),
    .rst           (cpu_rst),
    .stall         (stall),      // 添加stall信号
    .flush         (flush_id_ex),
    .id_alu_op     (id_alu_op    ),
    .id_rf_we      (id_rf_we     ),
    .id_ram_we     (id_ram_we    ),
    .id_rf_wsel    (id_rf_wsel   ),
    .id_dram_sel   (id_dram_sel  ),
    .id_rD2        (id_rD2       ),
    .id_pc4        (id_pc4       ),
    .id_npc_op     (id_npc_op    ),
    .id_sext       (id_sext      ),
    .id_A          (id_A         ),
    .id_B          (id_B         ),
    .id_rD1        (id_rD1       ),
    .id_csr_imm    (id_csr_imm   ),
    .id_wR         (id_inst[11:7]),
    .id_is_muldiv  (id_is_muldiv ),
    .id_csr_op     (id_csr_op    ),
    .id_csr_addr   (id_inst[31:20]),
    .id_csr_we     (id_csr_we    ),
    .id_is_mret    (id_is_mret   ),
    .id_exc_valid  (id_exc_valid ),
    .id_exc_cause  (id_exc_cause ),
    .id_exc_tval   (id_exc_tval  ),
    .Forward_A_en  (Forward_A_en ),
    .Forward_B_en  (Forward_B_en ),
    .A_forward     (A_forward    ),
    .B_forward     (B_forward    ),
    .ex_alu_op     (ex_alu_op    ),
    .ex_rf_we      (ex_rf_we     ),
    .ex_ram_we     (ex_ram_we    ),
    .ex_rf_wsel    (ex_rf_wsel   ),
    .ex_dram_sel   (ex_dram_sel  ),
    .ex_rD2        (ex_rD2       ),
    .ex_sext       (ex_sext      ),
    .ex_pc4        (ex_pc4       ),
    .ex_A          (ex_A         ),
    .ex_B          (ex_B         ),
    .ex_rD1        (ex_rD1       ),
    .ex_csr_imm    (ex_csr_imm   ),
    .ex_wR         (ex_wR        ),
    .ex_npc_op     (ex_npc_op    ),
    .ex_is_muldiv  (ex_is_muldiv ),
    .ex_csr_op     (ex_csr_op    ),
    .ex_csr_addr   (ex_csr_addr  ),
    .ex_csr_we     (ex_csr_we    ),
    .ex_is_mret    (ex_is_mret   ),
    .ex_exc_valid  (ex_exc_valid ),
    .ex_exc_cause  (ex_exc_cause ),
    .ex_exc_tval   (ex_exc_tval  ),

//    ,//trace
    .pc_i        (id_pc         ),
    .pc_o        (pc_EX         ),
    .have_inst_i (have_inst_ID  ),
    .have_inst_o (have_inst_EX  )
);

// CSR 指令的 A 口在【EX 级】直接取 CSR 旧值.
// 不能走 ID 级的 ALU_input_MUX: CSR 读地址 ex_csr_addr 是 EX 级的锁存值,
// 在 ID 级读会读到"当时 EX 里那条指令的地址"对应的值 —— 而 A 口是在
// ID→EX 边沿锁存的, 等真正到 EX 用的时候, 地址已经变成本条指令的了,
// 数据却是上一条的. (实测表现: csrw 后紧跟 csrr 读到的是旧值.)
wire [31:0] ex_A_final = (ex_csr_op != `CSR_OP_NONE) ? csr_rdata : ex_A;

ALU U_ALU(
    .A(ex_A_final),
    .B(ex_B),
    .alu_op(ex_alu_op),
    .alu_c(ex_alu_c),
    .alu_f(ex_alu_f)
);

// RV32M Multiplier and Divider Unit
MUL_DIV U_MUL_DIV(
    .clk(cpu_clk),
    .rst(cpu_rst),
    .A(ex_A),
    .B(ex_B),
    .alu_op(ex_alu_op),
    .valid_i(ex_is_muldiv & ex_rf_we),
    .result(muldiv_result),
    .ready_o(muldiv_ready),
    .busy_o(muldiv_busy)
);

// 乘除法单元导致的流水线暂停
assign muldiv_stall = ex_is_muldiv & ~muldiv_ready;

// 使用乘除法结果或ALU结果
wire [31:0] ex_alu_c_final = ex_is_muldiv ? muldiv_result : ex_alu_c;

EX_wD_MUX1 U_EX_wD_MUX1(
    .rf_wsel (ex_rf_wsel),
    .pc4     (ex_pc4),
    .sext    (ex_sext),
    .alu_c   (ex_alu_c_final),  // 使用最终结果
    .wD      (ex_wD)
);

// ---------------------------------------------------------------------------
// EX 级本地异常: 地址非对齐
// ---------------------------------------------------------------------------
// 访存地址 = rs1 + imm = ex_alu_c; 访问宽度由 ex_dram_sel 决定.
// 判据用 rf_wsel/ram_we 而不是 dram_sel 来确认"这确实是条访存指令":
// dram_sel 在 store 分支里是赋了值的, 但有些分支(如 LUI)故意不赋值靠 latch,
// 直接拿 dram_sel 判会把非访存指令误判成非对齐.
// 判据的可靠性说明(踩过一次坑): rf_wsel 在【分支/存储】分支里是不赋值的
// (它们不写寄存器), 会 latch 住上一条指令的值 —— 紧跟 lw 之后的 bne 会带着
// rf_wsel=RF_WSEL_DRAM, 只判 rf_wsel 就会把 bne 误当成 load 并报非对齐陷阱.
// 但 rf_we 和 ram_we 在【每一个】opcode 分支里都赋了值, 所以用它们来门控:
//   load  = rf_we=1 且 rf_wsel==DRAM
//   store = ram_we=1
wire ex_is_load  = ex_rf_we & (ex_rf_wsel == `RF_WSEL_DRAM);
wire ex_is_store = ex_ram_we;
wire ex_wsize_half = (ex_dram_sel == `DRAM_SEL_LH) || (ex_dram_sel == `DRAM_SEL_LHU)
                  || (ex_dram_sel == `DRAM_SEL_SH);
wire ex_wsize_word = (ex_dram_sel == `DRAM_SEL_LW) || (ex_dram_sel == `DRAM_SEL_SW);
wire ex_addr_bad   = ex_wsize_word ? (ex_alu_c[1:0] != 2'b00)
                                   : (ex_wsize_half & ex_alu_c[0]);
wire ex_load_misaligned  = have_inst_EX & ex_is_load  & ex_addr_bad;
wire ex_store_misaligned = have_inst_EX & ex_is_store & ex_addr_bad;

// 地址越界 -> 访问异常 (load=5 / store=7).
// 判据与 perip_bridge.v 的 DRAM 写门控共用 `ADDR_IN_MAP, 不会两边走样.
// 以前 DUT 会把 >=64KB 的地址截断后照写 DRAM[0], 静默别名; 现在报异常.
wire ex_load_oob  = have_inst_EX & ex_is_load  & ~`ADDR_IN_MAP(ex_alu_c);
wire ex_store_oob = have_inst_EX & ex_is_store & ~`ADDR_IN_MAP(ex_alu_c);

// 跳转/分支目标非对齐. 目标 = pc_EX + sext (JAL/分支), 或 jalr 的 ALU 结果.
// 分支只有【真的跳】才算 (不跳时目标无意义).
wire ex_br_taken = (ex_npc_op == `NPC_SEL_BRANCH) && ex_alu_f;
wire ex_is_jump  = (ex_npc_op == `NPC_SEL_JAL);
wire ex_is_jalr  = (ex_npc_op == `NPC_SEL_ALU);
wire [31:0] ex_target = ex_is_jalr ? ex_alu_c : (pc_EX + ex_sext);
wire ex_inst_misaligned = have_inst_EX & (ex_br_taken | ex_is_jump | ex_is_jalr)
                        & (ex_target[1:0] != 2'b00);

// 优先级: 指令目标非对齐 > 访问异常 > 访存非对齐.
// 地址根本不存在时再谈"对齐与否"没有意义, 所以访问异常压过非对齐
// (golden model 侧原本也是先查越界、再查对齐, 保持一致).
assign ex_local_exc_valid = ex_inst_misaligned | ex_load_oob | ex_store_oob
                          | ex_load_misaligned | ex_store_misaligned;
assign ex_local_exc_cause = ex_inst_misaligned  ? `EXC_INST_MISALIGNED
                          : ex_store_oob        ? `EXC_STORE_ACCESS
                          : ex_load_oob         ? `EXC_LOAD_ACCESS
                          : ex_load_misaligned  ? `EXC_LOAD_MISALIGNED
                          : ex_store_misaligned ? `EXC_STORE_MISALIGNED
                          : 4'd0;
// 指令地址非对齐时 mtval 记目标地址, 访存非对齐时记访存地址.
// 注意用【未掩码】的目标: RTL 的 jalr 目标没有清 bit0, 而 golden model 那边
// 也统一用未掩码值, 两边必须一致.
assign ex_local_exc_tval = ex_inst_misaligned ? ex_target : ex_alu_c;

// ID 级带来的异常优先 (两者本来互斥: 非法指令不会是跳转/访存)
wire        ex_exc_valid_f = ex_exc_valid | ex_local_exc_valid;
wire [3:0]  ex_exc_cause_f = ex_exc_valid ? ex_exc_cause : ex_local_exc_cause;
wire [31:0] ex_exc_tval_f  = ex_exc_valid ? ex_exc_tval  : ex_local_exc_tval;

// 这条指令是否"无已发生副作用": 中断只能落在这样的提交点上.
wire ex_irq_safe = ~ex_ram_we & ~ex_csr_we;

// ---------------------------------------------------------------------------
// CSR 文件
// ---------------------------------------------------------------------------
// 写数据在 EX 组合出来: RW 直接写源, RS 置位, RC 清位.
// 源: csrrwi 系列 = uimm5 (经 Sext_Z 得到, 锁在 ex_sext);
//     csrrw/rs/rc = rs1, 而且是【转发后】的 rs1 (ex_rD1).
// 注意不能用 rs2: 对 csrr* 来说 inst[24:20] 属于 csr 域, 不是寄存器号.
wire [31:0] ex_csr_src   = ex_csr_imm ? ex_sext : ex_rD1;
wire [31:0] ex_csr_wdata = (ex_csr_op == `CSR_OP_RW) ? ex_csr_src
                         : (ex_csr_op == `CSR_OP_RS) ? (csr_rdata |  ex_csr_src)
                         : (ex_csr_op == `CSR_OP_RC) ? (csr_rdata & ~ex_csr_src)
                         : 32'b0;

CSR U_CSR(
    .clk            (cpu_clk),
    .rst            (cpu_rst),
    .raddr_i        (ex_csr_addr),
    .rdata_o        (csr_rdata),
    // 重定向当拍必须掐掉 EX 级这条【更年轻的】CSR 指令的写: 它会被 flush,
    // 但它的写是在这个边沿生效的, 不掐就会漏进 CSR 文件.
    .we_i           (ex_csr_we & ~redirect),
    .waddr_i        (ex_csr_addr),
    .wdata_i        (ex_csr_wdata),
    .trap_i         (wb_exc | irq_taken),
    .trap_cause_i   (trap_cause),
    .trap_epc_i     (pc_WB),
    .trap_tval_i    (trap_tval),
    .mret_i         (wb_mret),
    .retire_i       (retire_now),
    .timer_irq_i    (timer_irq_d1),
    .mstatus_mie_o  (csr_mstatus_mie),
    .mie_mtie_o     (csr_mie_mtie),
    .mip_mtip_o     (csr_mip_mtip),
    .trap_vector_o  (csr_trap_vector),
    .mepc_o         (csr_mepc)
);

EX_MEM U_EX_MEM(
    .clk            (cpu_clk),
    .rst            (cpu_rst),
    .stall          (muldiv_stall),  // 传递乘除法暂停信号
    .flush          (redirect),      // 陷阱重定向: 与 stall 做同样的清空
    .ex_irq_safe    (ex_irq_safe),
    .ex_exc_valid   (ex_exc_valid_f),
    .ex_exc_cause   (ex_exc_cause_f),
    .ex_exc_tval    (ex_exc_tval_f),
    .ex_is_mret     (ex_is_mret),
    .ex_csr_we      (ex_csr_we  ),
    .ex_rf_we       (ex_rf_we    ),
    .ex_ram_we      (ex_ram_we   ),
    .ex_alu_c       (ex_alu_c_final),  // 使用包含乘除法结果的最终值
    .ex_dram_sel    (ex_dram_sel ),
    .ex_rf_wsel     (ex_rf_wsel  ),
    .ex_rD2         (ex_rD2      ),
    .ex_wR          (ex_wR       ),
    .ex_wD          (ex_wD       ),
    .mem_rf_we      (mem_rf_we   ),
    .mem_ram_we     (mem_ram_we  ),
    .mem_alu_c      (mem_alu_c   ),
    .mem_rD2        (mem_rD2     ),
    .mem_dram_sel   (mem_dram_sel),
    .mem_rf_wsel    (mem_rf_wsel ),
    .mem_wR         (mem_wR      ),
    .mem_wD_temp    (mem_wD_temp ),
    .mem_irq_safe   (mem_irq_safe),
    .mem_exc_valid  (mem_exc_valid),
    .mem_exc_cause  (mem_exc_cause),
    .mem_exc_tval   (mem_exc_tval),
    .mem_is_mret    (mem_is_mret),

    //trace
    .pc_i        (pc_EX        ),
    .pc_o        (pc_MEM       ),
    .have_inst_i (have_inst_EX ),
    .have_inst_o (have_inst_MEM)
);

MEM U_MEM(
    // store 的写是在 MEM 级(组合)就发出去的, 比 WB 提交点早一拍, 所以
    // 【~redirect 拦不住陷阱指令自己那次写】. 非对齐 store 必须靠 EX 级
    // 检出、随 EX_MEM 一起带过来的 mem_exc_valid 来掐; mem_exc_valid@T 与
    // wb_exc@T+1 是同一条指令(MEM_WB 无停顿, 恒锁存), 所以门控是精确的.
    // ~redirect 负责的是"同拍在 MEM 的、更年轻的那条 store".
    .we_in(mem_ram_we & ~mem_exc_valid & ~redirect),
    .addr_in(mem_alu_c),
    .wdin(mem_rD2),
    .dram_sel(mem_dram_sel),
    .DRAM_rdata_in(Bus_rdata),
    .addr_out(Bus_addr),
    .we_out(Bus_wen),
    .wdata_out(Bus_wdata),
    .rdo(mem_DRAM_rdo)
);

MEM_wD_MUX U_MEM_wD_MUX(
    .rf_wsel (mem_rf_wsel),
    .DRAM_rdo(mem_DRAM_rdo),
    .wD_temp (mem_wD_temp),
    .wD      (mem_wD)
);

MEM_WB U_MEM_WB(
    .clk             (cpu_clk),
    .rst             (cpu_rst),
    // 没有这个 flush 端口的话, 陷阱当拍"已经走到 MEM 的年轻指令"下一拍会
    // 照常提交(本模块原来既无 stall 也无 flush).
    .flush           (redirect),
    .mem_irq_safe    (mem_irq_safe),
    .mem_exc_valid   (mem_exc_valid),
    .mem_exc_cause   (mem_exc_cause),
    .mem_exc_tval    (mem_exc_tval),
    .mem_is_mret     (mem_is_mret),
    .mem_csr_we      (mem_csr_we ),
    .wb_csr_we       (wb_csr_we  ),
    .mem_rf_we       (mem_rf_we),
    .mem_wR          (mem_wR),
    .mem_wD          (mem_wD),
    .wb_irq_safe     (wb_irq_safe),
    .wb_exc_valid    (wb_exc_valid),
    .wb_exc_cause    (wb_exc_cause),
    .wb_exc_tval     (wb_exc_tval),
    .wb_is_mret      (wb_is_mret),
    .wb_rf_we        (wb_rf_we),
    .wb_wR           (wb_wR),
    .wb_wD           (wb_wD),

    //trace
    .pc_i        (pc_MEM       ),
    .pc_o        (pc_WB        ),
    .have_inst_i (have_inst_MEM),
    .have_inst_o (have_inst_WB )
);



//RegFile_wD_MUX U_RegFile_wD_MUX(
//    .rf_wsel(wb_rf_wsel),
//    .DRAM_rdo(wb_DRAM_rdo),
//    .alu_c(wb_alu_c),
//    .pc4(wb_pc4),
//    .sext(wb_sext),
//    .wD(wb_wD)
//);

Hazard_Detection U_Hazard_Detection(
    .id_rf1_used    (id_rf1_used ),
    .id_rf2_used    (id_rf2_used ),
    .ex_rf_wsel     (ex_rf_wsel  ),
    .ex_wR          (ex_wR       ),
    .mem_wR         (mem_wR      ),
    .wb_wR          (wb_wR       ),
    .ex_wD          (ex_wD       ),
    .mem_wD         (mem_wD      ),
    .wb_wD          (wb_wD       ),
    .id_rR1         (id_inst[19:15]),
    .id_rR2         (id_inst[24:20]),
    .branched       (branched    ),
    .trap           (redirect    ),
    .ex_rf_we       (ex_rf_we    ),
    .mem_rf_we      (mem_rf_we   ),
    // 转发源也要用掐过的写使能: 陷阱指令(非对齐 load)的结果不能写回,
    // 也就不能被后面的指令转发走
    .wb_rf_we       (wb_rf_we_eff ),
    .muldiv_stall   (muldiv_stall), // RV32M stall
    .stall          (stall       ),
    .flush_IF_ID    (flush_if_id ),
    .flush_ID_EX    (flush_id_ex ),
    .A_forward      (A_forward   ),
    .B_forward      (B_forward   ),
    .Forward_A_en   (Forward_A_en),
    .Forward_B_en   (Forward_B_en)
);
`ifdef RUN_TRACE
//     Debug Interface
    assign debug_wb_have_inst = have_inst_WB;
    assign debug_wb_pc        = pc_WB;
    // 用掐过的写使能: 陷阱指令(非对齐 load)不写 rd, 被中断 squash 的也不写
    assign debug_wb_ena       = wb_rf_we_eff & (wb_wR != 5'b0);
    assign debug_wb_reg       = wb_wR;
    assign debug_wb_value     = wb_wD;
`endif

endmodule

