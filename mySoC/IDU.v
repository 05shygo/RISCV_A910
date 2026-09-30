`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// Module Name: IDU   (Instruction Decode Unit)
//
// miniRV 核的 ID 级数据通路。本文件是**纯层次重构**的产物: 里面的五个成分
//   Control / SEXT / ID 级异常检出 / RegFile / ALU_input_MUX
// 原先散在 mySoC/mycpu.v 的 488~607 行, 现在收进这里 —— 逻辑一位没改,
// 只把跨端口的那几个名字换成 idu_*_i / idu_*_o (与 IFU 侧 idu_inst0_* 同风格)。
//
// 边界为什么划在这里:
//   * IF_ID / ID_EX 是 IF|ID 与 ID|EX 的**边界寄存器**, 留在 mycpu.v;
//   * Hazard_Detection 要看 EX/MEM/WB 三级, 是跨级单元, 也留在 mycpu.v;
//   * U_CSR 的**读地址**由本模块给出 (idu_csr_addr_o), 但**读数据旁路不回这里** ——
//     那条 mux 的选择子 (ex_csr_we / ex_csr_addr / ex_csr_wdata / redirect) 全在
//     EX 级, 而且 ex_csr_wdata 在 mycpu.v 里声明得比 ID 段晚 400 行, 搬进来就是
//     下面第 3 条警告说的隐式线网坑。
//
// ⚠️ 三条不能破的约定:
//   1. **本文件里不允许出现 always 块**。所有输出都是 output wire, 由子模块实例
//      或 assign 驱动 —— 这样结构上就推不出 latch。将来若要加组合 always, 必须
//      带上 Control.v:140-168 那种"case 之前先无条件赋默认值"的块, 否则 Vivado
//      会推断出电平敏感 latch, 而 latch 的门是数据信号 ⇒ 被报成
//      `TIMING-20 Non-clocked latch`, **那些路径根本不进时序分析**, 工具也不会
//      去优化它们 (2026-09-28 实测 Control 出 6 处 / 16 个 LDCE)。
//   2. **mycpu.v 侧的网名保持 id_***。tb/tb_miniRV_dpi.sv 用 dut.Core_cpu.<net>
//      一级层次探针直接抓 id_inst / id_pc / have_inst_ID / id_exc_valid/cause/tval
//      / stall / flush_* 。带 idu_ 前缀的**只有本模块自己的端口**, 别顺手把顶层
//      网名也改了 —— 那会让 TB 在编译期就挂掉。
//   3. **先声明后使用**。内部线网集中在下面 "Signal declarations" 段。本工程反复
//      踩过"用在声明之前 ⇒ 隐式 1 位线网"那个坑 (见 rv32ifu2_top.v 里 chk0_f 的
//      注释): VCS 只报 PCWM-W 警告、不报错, 而位宽被悄悄截成 1 位。
// ---------------------------------------------------------------------------
`include "defines.vh"

module IDU(
    input  wire                        clk                 ,
    input  wire                        rst                 ,

    // ---- 来自 IF_ID 的指令包 ----
    input  wire [31:0]                 idu_inst_data_i     ,   // id_inst
    input  wire                        idu_have_inst_i     ,   // have_inst_ID
    input  wire [31:0]                 idu_pc_i            ,   // id_pc
    input  wire                        idu_ifu_fault_i     ,   // id_fault
    input  wire [3:0]                  idu_ifu_cause_i     ,   // id_cause

    // ---- 来自 WB 的寄存器堆写口 ----
    input  wire [4:0]                  idu_wb_wR_i         ,   // wb_wR
    input  wire                        idu_wb_we_i         ,   // wb_rf_we_eff
    input  wire [31:0]                 idu_wb_wD_i         ,   // wb_wD_eff

    // ---- 译码结果: 控制信号 ----
    output wire [`NPC_SEL_WIDTH-1:0]   idu_npc_op_o        ,   // id_npc_op
    output wire [`ALU_OP_WIDTH-1:0]    idu_alu_op_o        ,   // id_alu_op
    output wire [`RF_WSEL_WIDTH-1:0]   idu_rf_wsel_o       ,   // id_rf_wsel
    output wire [`DRAM_SEL_WIDTH-1:0]  idu_dram_sel_o      ,   // id_dram_sel
    output wire                        idu_rf_we_o         ,   // id_rf_we
    output wire                        idu_ram_we_o        ,   // id_ram_we
    output wire                        idu_is_muldiv_o     ,   // id_is_muldiv
    output wire                        idu_is_mret_o       ,   // id_is_mret

    // ---- 译码结果: CSR ----
    output wire [2:0]                  idu_csr_op_o        ,   // id_csr_op
    output wire                        idu_csr_imm_o       ,   // id_csr_imm
    output wire                        idu_csr_we_o        ,   // id_csr_we
    output wire [11:0]                 idu_csr_addr_o      ,   // id_csr_addr

    // ---- 译码结果: 源寄存器使用标志 (给 Hazard_Detection) ----
    output wire                        idu_rf1_used_o      ,   // id_rf1_used
    output wire                        idu_rf2_used_o      ,   // id_rf2_used

    // ---- ID 级数据通路: 立即数 / 寄存器堆读口 / ALU 操作数 ----
    output wire [31:0]                 idu_sext_o          ,   // id_sext
    output wire [31:0]                 idu_rD1_o           ,   // id_rD1
    output wire [31:0]                 idu_rD2_o           ,   // id_rD2
    output wire [31:0]                 idu_A_o             ,   // id_A
    output wire [31:0]                 idu_B_o             ,   // id_B

    // ---- ID 级异常 (取指故障 / 越界 / 非法 / ecall / ebreak) ----
    output wire                        idu_exc_vld_o       ,   // id_exc_valid
    output wire [3:0]                  idu_exc_cause_o     ,   // id_exc_cause
    output wire [31:0]                 idu_exc_tval_o          // id_exc_tval
    );

// ---------------------------------------------------------------------------
// Signal declarations
// 下面是**只活在本模块内部**的线网。名字沿用它们在 mycpu.v 里的原名 (id_ 前缀),
// 这样搬动前后的对照 diff 是逐行可读的; 跨出模块的那 22 个信号才是 idu_*_o 端口。
// ---------------------------------------------------------------------------
wire [`Sext_OP_WDITH-1:0] id_sext_op;    // Control -> SEXT
wire [`ALUA_SEL_WIDTH-1:0] id_alua_sel;   // Control -> ALU_input_MUX
wire [`ALUB_SEL_WIDTH-1:0] id_alub_sel;   // Control -> ALU_input_MUX

wire        id_is_illegal;               // 以下三条来自 Control, 只喂异常检出
wire        id_is_ecall;
wire        id_is_ebreak;

wire        id_inst_oob;                 // 取指越界
wire        id_ifu_fault;                // IFU 故障包

// ---------------------------------------------------------------------------
// Section: 立即数生成
//   din 是 **inst[31:7]** —— 移位过的, 不是整条指令。
//   Sext_Z 取 din[12:8], 正好是 inst[19:15] (csrr*i 的 uimm5 在 rs1 域)。
// ---------------------------------------------------------------------------
SEXT U_SEXT(
    .din(idu_inst_data_i[31:7]),
    .sext_op(id_sext_op),
    .sext(idu_sext_o)
);

// ---------------------------------------------------------------------------
// Section: 主译码 (case (opcode) 在 Control.v 里, 本模块只负责喂字段、收结果)
// ---------------------------------------------------------------------------
Control U_Control(
    .opcode(idu_inst_data_i[6:0]),
    .funct3(idu_inst_data_i[14:12]),
    .funct7(idu_inst_data_i[31:25]),
    .rs1_addr(idu_inst_data_i[19:15]),
    .csr_addr(idu_csr_addr_o),
    .sext_op(id_sext_op),
    .npc_op(idu_npc_op_o),
    .alu_op(idu_alu_op_o),
    .alua_sel(id_alua_sel),
    .alub_sel(id_alub_sel),
    .rf_wsel(idu_rf_wsel_o),
    .dram_sel(idu_dram_sel_o),
    .rf_we(idu_rf_we_o),
    .ram_we(idu_ram_we_o),
    .is_muldiv(idu_is_muldiv_o),
    .id_rf1_used(idu_rf1_used_o),
    .id_rf2_used(idu_rf2_used_o),

    .is_illegal(id_is_illegal),
    .is_ecall  (id_is_ecall  ),
    .is_ebreak (id_is_ebreak ),
    .is_mret   (idu_is_mret_o),
    .csr_op    (idu_csr_op_o ),
    .csr_imm   (idu_csr_imm_o),
    .csr_we    (idu_csr_we_o )
);

// CSR 读地址: 就是本条指令的 inst[31:20]。
//
// 历史 (从 mycpu.v 搬来): 这条以前是行内表达式写死在 U_Control 和 U_ID_EX 的连接
//   上, 后来提出来给 CSR 文件当读地址; 当时**必须**声明在 id_inst 之后, 否则就是
//   隐式 1 位线网 —— 而 U_CSR.raddr_i 只收到 1 位, 所有 CSR 访问都会读写到错的
//   寄存器, VCS 却只报 PCWM-W 警告。搬进本模块后 idu_inst_data_i 是端口, 永远在
//   作用域内, 那个坑天然消失; 但**声明顺序的纪律不要丢**。
assign idu_csr_addr_o = idu_inst_data_i[31:20];

// ---------------------------------------------------------------------------
// Section: ID 级异常
// 取指越界 / 非法指令 / ecall / ebreak。
// 必须用 have_inst 门控: 流水线气泡的 inst 是全零, 而全零正好是"非法指令",
// 不门控的话每个气泡都会当成陷阱。
//
// 取指越界(instruction access fault, cause 1)优先级最高: IROM 只有 64KB, PC 跑到
// 更外面时 inst_addr = if_pc[15:2] 会回绕, 取回来的是别的地址上的指令字 —— 那是
// 垃圾, 不能再按它译码, 只能报异常。
// ---------------------------------------------------------------------------
assign id_inst_oob = idu_have_inst_i & ~`INST_ADDR_OK(idu_pc_i);

// IFU 的取指故障包: 故障包被消费后 IFU 会停取指, 直到重定向才恢复, 所以这里必须
// 立刻生成异常。id_inst_oob 保留作兜底 (pc >= 64KB 时两条判据完全一致; 故障包是
// "非对齐取指" cause 0 的唯一来源)。
assign id_ifu_fault = idu_have_inst_i & idu_ifu_fault_i;

assign idu_exc_vld_o   = idu_have_inst_i & (id_ifu_fault | id_inst_oob | id_is_illegal | id_is_ecall | id_is_ebreak);
assign idu_exc_cause_o = id_ifu_fault  ? (idu_ifu_cause_i == 4'd0 ? `EXC_INST_MISALIGNED : `EXC_INST_ACCESS)
                       : id_inst_oob   ? `EXC_INST_ACCESS
                       : id_is_illegal ? `EXC_ILLEGAL_INST
                       : id_is_ecall   ? `EXC_ECALL_M
                       : id_is_ebreak  ? `EXC_BREAKPOINT
                       : 4'd0;
// 非法指令的 mtval 记指令本身, ecall/ebreak 记 0,
// 取指故障/越界记那个取不到的地址 (规范)
assign idu_exc_tval_o  = (id_ifu_fault | id_inst_oob) ? idu_pc_i
                       : id_is_illegal ? idu_inst_data_i : 32'b0;

// ---------------------------------------------------------------------------
// Section: 寄存器堆
// 组合读、时序写, **内部没有旁路** —— 旁路全在 Hazard_Detection。
// 写口来自 WB 提交点 (mycpu.v 的 wb_rf_we_eff / wb_wD_eff, 已把陷阱与中断掐掉)。
// ---------------------------------------------------------------------------
RegFile U_RegFile(
    .rst(rst),
    .clk(clk),
    .rR1(idu_inst_data_i[19:15]),
    .rR2(idu_inst_data_i[24:20]),
    .wR(idu_wb_wR_i),
    .we(idu_wb_we_i),
    .wD(idu_wb_wD_i),
    .rD1(idu_rD1_o),
    .rD2(idu_rD2_o)
);

// ---------------------------------------------------------------------------
// Section: ALU 操作数选择
// A 口: rd1 / pc(AUIPC) ; B 口: rd2 / sext / 0(csrr* 让 A 口原样穿过 ALU 写回)
// ---------------------------------------------------------------------------
ALU_input_MUX U_ALU_input_MUX(
    .rD1(idu_rD1_o),
    .rD2(idu_rD2_o),
    .pc(idu_pc_i),
    .sext(idu_sext_o),
    .alua_sel(id_alua_sel),
    .alub_sel(id_alub_sel),
    .A(idu_A_o),
    .B(idu_B_o)
);

endmodule
