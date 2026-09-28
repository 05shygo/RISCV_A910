`timescale 1ns / 1ps

`include "defines.vh"

// 取指级的三选一 (由 Makefile 的 IFU= 选择):
//   IFU=0       旧 PC/NPC/IROM 通路
//   IFU=1       ifu_rv32i (C910 派生, 3 级)
//   IFU=2       ifu2      (自研 2 级 3 发射, 见 mySoC/ifu2/)
// 三个宏都在 Makefile 的 DEFINES 里定义: USE_IFU / USE_IFU2 各自标识一款前端,
// USE_IFU_ANY = "任意一款 IFU 在用"。凡是"有 IFU 就成立"的门控 (IROM 端口、
// 误预测重定向) 一律用 USE_IFU_ANY; 只有确实只针对 C910 那款的才用 USE_IFU
// (例如 tb 里绑旧层次的探针)。

module myCPU (
    input  wire         cpu_rst,
    input  wire         cpu_clk,

`ifndef USE_IFU_ANY
    // Interface to IROM
    output wire [13:0]  inst_addr,
    input  wire [31:0]  inst,
`endif
    // Interface to Bridge
    output wire [31:0]  Bus_addr,
    input  wire [31:0]  Bus_rdata,
    output wire         Bus_wen,
    output wire [31:0]  Bus_wdata,
    // 数据存储的**读**地址 (字地址, 14 位 = 64 KB)。
    //
    // 与 Bus_addr 的关系是"早一拍": 访存地址在 **EX** 级就算出来了 (ex_alu_c_final),
    // 而同步 RAM 的读延迟正好一拍 ⇒ 数据在 **MEM** 级到齐, 与旧的异步读模型**同拍**,
    // 一拍都不多花。见 mySoC/sync_mem.v 的读口语义契约。
    //
    // ⚠️ 这一路只在 DRAM 是同步 RAM 时才有意义。它与写地址 (Bus_addr, MEM 级) 的
    //    关系是"同一个指令的同一个地址, 只是早一拍给出" —— EX_MEM 永不保持
    //    (只有 div_stall 会把它冲成气泡), 所以地址与数据天然对齐。
    output wire [13:0]  Bus_raddr,

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


`ifndef USE_IFU_ANY
wire [31:0] if_npc;
`endif
wire [31:0] if_pc;
wire [31:0] id_pc;
wire [31:0] wb_pc;
wire [31:0] if_pc4;
wire [31:0] id_pc4;
wire [31:0] ex_pc4;
// 预测后继 PC 与取指故障包 (IFU 集成), 沿 IF_ID / ID_EX 传递
wire [31:0] id_pred_npc;
wire [31:0] ex_pred_npc;
wire [24:0] ex_bht_chk;
wire        ex_bht_pred;
wire        id_fault;
wire [ 3:0] id_cause;

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
// 乘法标志随流水下传 (EX_MEM / MEM_WB 各一位), 到 WB 用来选写回数据
wire        mem_is_mul;
wire        wb_is_mul;

`ifndef USE_IFU_ANY
assign inst_addr = if_pc[15:2];
`endif
//assign Bus_wen = ram_we;
//assign Bus_wdata = rD2;
//assign Bus_addr = alu_c;

wire stall;
wire flush_if_id;
wire flush_id_ex;

wire id_rf1_used;
wire id_rf2_used;

wire branched;

// ===================== RV32M: 乘除法单元接口 =====================
// 单元是**真流水**的乘法 + radix-4 的除法, 两条独立流水共用一个带 tag 的
// 请求/写回口 (见 mySoC/MUL_DIV.v)。核这边分四件事:
//
//   1. 发射: ex_is_muldiv & ex_rf_we 那一拍把请求递进去 (req_valid);
//   2. 乘法**不阻塞流水**: 结果 2 拍后从写回口出来, 靠 `is_mul` 随流水下传,
//      在 WB 级换进 wb_wD (下面是 wb_wD_eff);
//   3. 除法仍占住 EX 等结果 (div_stall), 结果在 EX 级就地折进 alu_c;
//   4. 乘法在飞到 WB 之前不能前递、消费者要停 (Hazard_Detection 的 mul_stall)。
localparam MD_TAG_W = 7;              // PRF=128 → 7 位 (doc §3.1); P1 里接 rd 序号

wire id_is_muldiv;
wire ex_is_muldiv;
// ALU_MUL..ALU_MULHU = 16..19, ALU_DIV..ALU_REMU = 20..23 (defines.vh),
// 所以 alu_op[2] 正好就是"乘还是除"那一位, 低 3 位正好是 MD_OP_* 的编码。
wire ex_is_mul = ex_is_muldiv & ~ex_alu_op[2];
wire ex_is_div = ex_is_muldiv &  ex_alu_op[2];

wire [31:0]          md_resp_data;
wire                 md_resp_vld;
wire [MD_TAG_W-1:0]  md_resp_tag;
wire                 md_resp_is_div;
wire                 md_mul_ready;
wire                 md_div_busy;
wire        mul_stall;                // 乘法冒险停 ID (来自 Hazard_Detection)
wire        div_stall;                // 除法占住 EX

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
wire [31:0] ex_csr_rdata;              // ID 级读出、随 ID_EX 锁进来的 CSR 旧值
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

// ---------------------------------------------------------------------------
// WB 级写回数据: 乘法的结果在这里接进来 (doc §7)
// ---------------------------------------------------------------------------
// doc §7 写的是"并进 mem_wD (MEM_WB 入口加 mux)", 但按 §3.3 的时序图, 乘法是
// T 拍发射、T+2 拍出响应 —— 那是乘法自己的 **WB 拍**, 而 wb_wD 早在 T+1 边沿就
// 从 mem_wD 锁好了, 赶不上 MEM_WB 入口。所以 mux 落在 WB 级的输出上。
// 正确性靠"响应属于哪条指令由指令自己说了算": is_mul 跟着指令走完流水, 而
// 乘法的发射拍与它的 WB 拍相差恒定 2 拍, 两者天然对齐 (见 MUL_DIV.v 的说明)。
wire [31:0] wb_wD_eff = wb_is_mul ? md_resp_data : wb_wD;
// 提交脉冲 (被中断 squash 掉的那条不算退休, 否则 instret 会多计)
wire retire_now   = have_inst_WB & ~irq_taken;

// CSR 文件是否"静止": 没有任何一级存在途的 CSR 写, 也没有重定向.
// DUT 在 EX 级写 CSR(比提交早 2 拍), golden model 在提交当拍才写 ——
// 只有在静止时才保证两边读到同一个状态, 在途窗口里比较会误报.
// (陷阱自己的 mepc/mcause/mstatus 写发生在重定向边沿, 所以也排除 redirect.)
wire csr_quiescent = ~redirect & ~ex_csr_we & ~mem_csr_we & ~wb_csr_we;

`ifdef USE_IFU_ANY
// ===================== IFU 取指 =====================
// 每拍只消费 lane0 一条。无效槽的 data 是全 0 (会被译码成"非法指令"),
// 所以必须用 if_accept 门控; 取不到时给 IF_ID 灌气泡, 让流水线照常前进。
// 绝不能去停 ID_EX: EX_MEM 的 stall 是"插气泡"语义而非"保持", 停 ID_EX
// 会让同一条指令被 EX_MEM 重复锁存, 在 debug_wb_* 上重复出现, 被 difftest
// 当成多次提交 (EX_MEM.v 里的注释写的就是这个坑)。
wire        ifu_inst0_vld;
wire [127:0] ifu_inst0_data;
wire [ 24:0] ifu_inst0_chk;
wire        ifu_idu_flush;
wire        ifu_init_done;

// BHT 检查/训练 (IFU 集成): EX 级解析条件分支时回送预测当时的快照.
// 快照由 IFU 随指令一起送来 (chk 走独立旁路, 方向预测在包内 bit122),
// 因此与指令天然同序 —— 不能改用 create* 广播总线, 那条在 IBUF 输入侧
// 对齐, 后端一停顿就会与交付的指令错位.
wire        iu_bht_check_vld;
wire [31:0] iu_cur_pc;
wire        iu_bht_condbr_taken;
wire        iu_bht_pred;
wire [ 24:0] iu_chk_idx;

`ifdef USE_IFU2
// ifu2 的预测器训练回送: "EX 解析掉了一条控制转移, 它是什么、去了哪"。
// 与上面那组 C910 风格的 iu_bht_* 的区别是**覆盖 jal/jalr** —— 原设计只回送
// 条件分支, jalr 的目标学习完全缺失 (jalr 从不写 BTB, 见 memory
// cpu-btb-index-conflict 的微架构补记), 那是 L1 BTB 唯一真正在干的活。
wire        iu_btb_update_vld;
wire [31:0] iu_btb_cur_pc;
wire        iu_btb_taken;
wire [31:0] iu_btb_target;
wire        iu_btb_is_cond;
wire        iu_btb_is_jal;
wire        iu_btb_is_jalr;
wire [24:0] iu_btb_chk;
`endif

// BIU 总线 (rv32_ifu_top <-> ifu_biu_mem)
wire        ifu_biu_rd_req;
wire [31:0] ifu_biu_rd_addr;
wire        ifu_biu_rd_id;
wire [ 1:0] ifu_biu_rd_len;
wire        ifu_biu_rd_grnt;
wire        ifu_biu_rd_data_vld;
wire [127:0] ifu_biu_rd_data;
wire        ifu_biu_rd_rid;
wire        ifu_biu_rd_last;
wire [ 1:0] ifu_biu_rd_resp;
wire        ifu_biu_r_ready;

// 前端重定向 (组合, 由 EX/WB 段驱动, 声明在后)
wire        iu_ifu_chgflw_vld;
wire [31:0] iu_ifu_chgflw_pc;
wire        rtu_ifu_flush;
wire        rtu_ifu_chgflw_vld;
wire [31:0] rtu_ifu_chgflw_pc;

// 前端两个总开关从 Makefile 的 +define+ 派生后透传给 ifu_subsys。
// 不定义 ICACHE_OFF / BP_OFF 时两者都是 1, 与改动前逐位相同。
`ifdef ICACHE_OFF
localparam IFU_ICACHE_EN = 1'b0;
`else
localparam IFU_ICACHE_EN = 1'b1;
`endif
`ifdef BP_OFF
localparam IFU_BP_EN = 1'b0;
`else
localparam IFU_BP_EN = 1'b1;
`endif

`ifdef USE_IFU2
// 自研 2 级 3 发射前端。它不再需要 ifu_subsys 那层适配 —— 端口名本来就是
// 按本核的取指级语义定的, 不需要 PCFIFO/维护/断点/HAD 那套桩。
rv32ifu2_top #(
    .ICACHE_EN (IFU_ICACHE_EN),
    .BP_EN     (IFU_BP_EN)
) u_ifu_subsys (
    .clk           (cpu_clk),
    .rst           (cpu_rst),
    .idu_inst0_vld (ifu_inst0_vld),
    .idu_inst0_data(ifu_inst0_data),
    .idu_inst0_chk (ifu_inst0_chk),
    .idu_inst1_vld (),
    .idu_inst1_data(),
    .idu_inst1_chk (),
    .idu_inst2_vld (),
    .idu_inst2_data(),
    .idu_inst2_chk (),
    .idu_flush     (ifu_idu_flush),
    .idu_accept_num(if_accept ? 2'd1 : 2'd0),
    .iu_chgflw_vld (iu_ifu_chgflw_vld),
    .iu_chgflw_pc  (iu_ifu_chgflw_pc),
    .iu_bht_check_vld     (iu_bht_check_vld),
    .iu_cur_pc            (iu_cur_pc),
    .iu_bht_condbr_taken  (iu_bht_condbr_taken),
    .iu_bht_pred          (iu_bht_pred),
    .iu_chk_idx           (iu_chk_idx),
`ifdef USE_IFU2
    .iu_btb_update_vld    (iu_btb_update_vld),
    .iu_btb_cur_pc        (iu_btb_cur_pc),
    .iu_btb_taken         (iu_btb_taken),
    .iu_btb_target        (iu_btb_target),
    .iu_btb_is_cond       (iu_btb_is_cond),
    .iu_btb_is_jal        (iu_btb_is_jal),
    .iu_btb_is_jalr       (iu_btb_is_jalr),
    .iu_btb_chk           (iu_btb_chk),
`endif
    .rtu_flush     (rtu_ifu_flush),
    .rtu_chgflw_vld(rtu_ifu_chgflw_vld),
    .rtu_chgflw_pc (rtu_ifu_chgflw_pc),
    .init_done     (ifu_init_done),
    .biu_rd_req    (ifu_biu_rd_req),
    .biu_rd_addr   (ifu_biu_rd_addr),
    .biu_rd_id     (ifu_biu_rd_id),
    .biu_rd_len    (ifu_biu_rd_len),
    .biu_rd_grnt   (ifu_biu_rd_grnt),
    .biu_rd_data_vld(ifu_biu_rd_data_vld),
    .biu_rd_data   (ifu_biu_rd_data),
    .biu_rd_rid    (ifu_biu_rd_rid),
    .biu_rd_last   (ifu_biu_rd_last),
    .biu_rd_resp   (ifu_biu_rd_resp),
    .biu_r_ready   (ifu_biu_r_ready)
);
`else
ifu_subsys #(
    .ICACHE_EN (IFU_ICACHE_EN),
    .BP_EN     (IFU_BP_EN)
) u_ifu_subsys (
    .clk           (cpu_clk),
    .rst           (cpu_rst),
    .idu_inst0_vld (ifu_inst0_vld),
    .idu_inst0_data(ifu_inst0_data),
    .idu_inst0_chk (ifu_inst0_chk),
    .idu_inst1_vld (),
    .idu_inst1_data(),
    .idu_inst1_chk (),
    .idu_inst2_vld (),
    .idu_inst2_data(),
    .idu_inst2_chk (),
    .idu_flush     (ifu_idu_flush),
    .idu_accept_num(if_accept ? 2'd1 : 2'd0),
    .iu_chgflw_vld (iu_ifu_chgflw_vld),
    .iu_chgflw_pc  (iu_ifu_chgflw_pc),
    .iu_bht_check_vld     (iu_bht_check_vld),
    .iu_cur_pc            (iu_cur_pc),
    .iu_bht_condbr_taken  (iu_bht_condbr_taken),
    .iu_bht_pred          (iu_bht_pred),
    .iu_chk_idx           (iu_chk_idx),
    .rtu_flush     (rtu_ifu_flush),
    .rtu_chgflw_vld(rtu_ifu_chgflw_vld),
    .rtu_chgflw_pc (rtu_ifu_chgflw_pc),
    .init_done     (ifu_init_done),
    .biu_rd_req    (ifu_biu_rd_req),
    .biu_rd_addr   (ifu_biu_rd_addr),
    .biu_rd_id     (ifu_biu_rd_id),
    .biu_rd_len    (ifu_biu_rd_len),
    .biu_rd_grnt   (ifu_biu_rd_grnt),
    .biu_rd_data_vld(ifu_biu_rd_data_vld),
    .biu_rd_data   (ifu_biu_rd_data),
    .biu_rd_rid    (ifu_biu_rd_rid),
    .biu_rd_last   (ifu_biu_rd_last),
    .biu_rd_resp   (ifu_biu_rd_resp),
    .biu_r_ready   (ifu_biu_r_ready)
);
`endif

ifu_biu_mem u_ifu_biu_mem (
    .clk               (cpu_clk),
    .rst               (cpu_rst),
    .ifu_biu_rd_req    (ifu_biu_rd_req),
    .ifu_biu_rd_addr   (ifu_biu_rd_addr),
    .ifu_biu_rd_id     (ifu_biu_rd_id),
    .ifu_biu_rd_len    (ifu_biu_rd_len),
    .biu_ifu_rd_grnt   (ifu_biu_rd_grnt),
    .biu_ifu_rd_data_vld(ifu_biu_rd_data_vld),
    .biu_ifu_rd_data   (ifu_biu_rd_data),
    .biu_ifu_rd_id     (ifu_biu_rd_rid),
    .biu_ifu_rd_last   (ifu_biu_rd_last),
    .biu_ifu_rd_resp   (ifu_biu_rd_resp),
    .ifu_biu_r_ready   (ifu_biu_r_ready)
);

// 本拍能不能真正捕获一条指令。IFU 的 vld/data 不依赖 accept_num (无组合环),
// 且 accept_num 恒 <= 有效槽数, 满足 IBUF 前缀消费约束。
wire if_accept;
wire if_bubble;
assign if_accept = ifu_inst0_vld & ~stall & ~flush_if_id & ~ifu_idu_flush;
assign if_bubble = ~stall & ~if_accept;

wire [31:0] if_inst;
wire [31:0] if_pred_npc;
wire        if_fault;
wire [ 3:0] if_cause;
wire [24:0] if_bht_chk;
wire        if_bht_pred;
assign if_bht_chk  = ifu_inst0_chk;
assign if_pc       = ifu_inst0_data[63:32];
assign if_inst     = ifu_inst0_data[31:0];
assign if_pc4      = ifu_inst0_data[63:32] + 32'd4;
assign if_pred_npc = ifu_inst0_data[95:64];
assign if_fault    = ifu_inst0_data[96];
assign if_cause    = ifu_inst0_data[100:97];
// bit122 是 IFU 当时给出的方向预测 (pcfifo_if 原样透传), 与指令同序.
assign if_bht_pred = ifu_inst0_data[122];
`else
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
// 旧通路没有这些信号, 接常量即可 (IF_ID 行为不变)
wire        if_bubble   = 1'b0;
wire [31:0] if_pred_npc = 32'b0;
wire        if_fault    = 1'b0;
wire [ 3:0] if_cause    = 4'd0;
wire [24:0] if_bht_chk  = 25'd0;
wire        if_bht_pred = 1'b0;
`endif
wire [31:0] id_inst;
wire [24:0] id_bht_chk;
wire        id_bht_pred;

// CSR 读地址: 就是本条指令的 inst[31:20]。
// ⚠️ 必须声明在 id_inst **之后** —— 本工程反复踩过"用在声明之前 ⇒ 隐式 1 位线网"
//    那个坑 (见 rv32ifu2_top.v 里 chk0_f 的注释)。原来这条表达式是内联写在
//    U_Control 和 U_ID_EX 的连接上的, 现在提出来给 CSR 文件当读地址。
wire [11:0] id_csr_addr  = id_inst[31:20];
// ID 级读出的 CSR 值 (含 EX→ID 旁路)。这里只**声明**; 赋值放在 ex_csr_wdata
// 之后 —— 旁路要用到它。反过来会变成隐式线网。
wire [31:0] id_csr_rdata;

IF_ID U_IF_ID(
    .clk      (cpu_clk),
    .rst      (cpu_rst),
    .stall    (stall),
    .flush    (flush_if_id),
    .if_bubble(if_bubble),
    .if_pc    (if_pc),
    .if_pc4   (if_pc4),
    .if_inst  (if_inst),
    .if_pred_npc (if_pred_npc),
    .if_fault (if_fault),
    .if_cause (if_cause),
    .if_bht_chk  (if_bht_chk),
    .if_bht_pred (if_bht_pred),
    .id_pc    (id_pc),
    .id_pc4   (id_pc4),
    .id_inst  (id_inst),
    .id_pred_npc (id_pred_npc),
    .id_fault (id_fault),
    .id_cause (id_cause),
    .id_bht_chk  (id_bht_chk),
    .id_bht_pred (id_bht_pred),
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
    .csr_addr(id_csr_addr),
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

// IFU 的取指故障包: 故障包被消费后 IFU 会停取指, 直到重定向才恢复,
// 所以这里必须立刻生成异常。id_inst_oob 保留作兜底 (pc>=64KB 时两条
// 判据完全一致; 故障包是"非对齐取指"cause 0 的唯一来源)。
wire id_ifu_fault = have_inst_ID & id_fault;

assign id_exc_valid = have_inst_ID & (id_ifu_fault | id_inst_oob | id_is_illegal | id_is_ecall | id_is_ebreak);
assign id_exc_cause = id_ifu_fault  ? (id_cause == 4'd0 ? `EXC_INST_MISALIGNED : `EXC_INST_ACCESS)
                    : id_inst_oob   ? `EXC_INST_ACCESS
                    : id_is_illegal ? `EXC_ILLEGAL_INST
                    : id_is_ecall   ? `EXC_ECALL_M
                    : id_is_ebreak  ? `EXC_BREAKPOINT
                    : 4'd0;
// 非法指令的 mtval 记指令本身, ecall/ebreak 记 0,
// 取指故障/越界记那个取不到的地址 (规范)
assign id_exc_tval  = (id_ifu_fault | id_inst_oob) ? id_pc
                    : id_is_illegal ? id_inst : 32'b0;

RegFile U_RegFile(
    .rst(cpu_rst),
    .clk(cpu_clk),
    .rR1(id_inst[19:15]),
    .rR2(id_inst[24:20]),
    .wR(wb_wR),
    .we(wb_rf_we_eff),
    .wD(wb_wD_eff),
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
    .id_pred_npc   (id_pred_npc  ),
    .id_npc_op     (id_npc_op    ),
    .id_sext       (id_sext      ),
    .id_A          (id_A         ),
    .id_B          (id_B         ),
    .id_rD1        (id_rD1       ),
    .id_csr_imm    (id_csr_imm   ),
    .id_wR         (id_inst[11:7]),
    .id_is_muldiv  (id_is_muldiv ),
    .id_csr_op     (id_csr_op    ),
    .id_csr_addr   (id_csr_addr  ),
    .id_csr_rdata  (id_csr_rdata ),
    .id_csr_we     (id_csr_we    ),
    .id_is_mret    (id_is_mret   ),
    .id_exc_valid  (id_exc_valid ),
    .id_exc_cause  (id_exc_cause ),
    .id_exc_tval   (id_exc_tval  ),
    .id_bht_chk    (id_bht_chk   ),
    .id_bht_pred   (id_bht_pred  ),
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
    .ex_pred_npc   (ex_pred_npc  ),
    .ex_A          (ex_A         ),
    .ex_B          (ex_B         ),
    .ex_rD1        (ex_rD1       ),
    .ex_csr_imm    (ex_csr_imm   ),
    .ex_wR         (ex_wR        ),
    .ex_npc_op     (ex_npc_op    ),
    .ex_is_muldiv  (ex_is_muldiv ),
    .ex_csr_op     (ex_csr_op    ),
    .ex_csr_addr   (ex_csr_addr  ),
    .ex_csr_rdata  (ex_csr_rdata ),
    .ex_csr_we     (ex_csr_we    ),
    .ex_is_mret    (ex_is_mret   ),
    .ex_exc_valid  (ex_exc_valid ),
    .ex_exc_cause  (ex_exc_cause ),
    .ex_exc_tval   (ex_exc_tval  ),
    .ex_bht_chk    (ex_bht_chk   ),
    .ex_bht_pred   (ex_bht_pred  ),

//    ,//trace
    .pc_i        (id_pc         ),
    .pc_o        (pc_EX         ),
    .have_inst_i (have_inst_ID  ),
    .have_inst_o (have_inst_EX  )
);

// CSR 指令的 A 口取 CSR 旧值 —— 但取的是**随 ID_EX 锁进来的那一份**
// (ex_csr_rdata, 在 ID 级用本条指令自己的 id_csr_addr 读出来的)。
//
// ⚠️ 这里不能用 ID 级的 ALU_input_MUX 承载: A 口是**转发通路** (Forward_A_en 会把
//    ID_EX.v 里的 ex_A/ex_rD1 一起覆盖成 A_forward), CSR 值塞进去会被冲掉。
//    所以单独走一个 ex_csr_rdata 字段。
//
// 历史: 2026-09-28 之前这里是 `? csr_rdata : ex_A`, 即**在 EX 级组合读**。
// 那条 16:1 mux (4 级 LUT) 挂在 ALU 的 A 口上, 是 FPGA 关键路径的链头 ——
// 8 个综合 run 的最差 500 条路径全部从 ex_csr_addr_reg 出发。而且它还有一条
// 反向长链: csr_rdata → ex_A_final → ALU → EX_wD_MUX1 → A_forward → ID_EX.ex_A。
// 读搬到 ID 之后两条都断了。
wire [31:0] ex_A_final = (ex_csr_op != `CSR_OP_NONE) ? ex_csr_rdata : ex_A;

ALU U_ALU(
    .A(ex_A_final),
    .B(ex_B),
    .alu_op(ex_alu_op),
    .alu_c(ex_alu_c),
    .alu_f(ex_alu_f)
);

// RV32M Multiplier and Divider Unit (真流水 + tag 接口, 见 mySoC/MUL_DIV.v)
//   * req_op: MD_OP_* 与 ALU_OP 的 M 段低 3 位一一对应 (见 defines.vh 的注释);
//   * req_tag: P1 里就是 rd 的序号 —— 换乱序核时改成 rename 的 preg 即可,
//     单元和这里的其余接线都不用动 (doc §7);
//   * req_src2 / req_acc_mode: MAC 口, P1 接 0 (doc §4.6 已把插入点定死在 M2);
//   * wb_grant: 写回口仲裁。本核只有这一条乘除法流水在用它, 接 1;
//   * flush_valid: 顺序核重定向即全清 (乱序核换成 flush_tag 比较, 见 §6.3)。
MUL_DIV #(
    .DATA_W (32),
    .TAG_W  (MD_TAG_W)
) U_MUL_DIV (
    .clk          (cpu_clk),
    .rst          (cpu_rst),
    .req_valid    (ex_is_muldiv & ex_rf_we),
    .req_op       ({1'b0, ex_alu_op[2:0]}),
    .req_src0     (ex_A),
    .req_src1     (ex_B),
    .req_tag      ({{(MD_TAG_W-5){1'b0}}, ex_wR}),
    .req_src2     (64'b0),
    .req_acc_mode (`MD_ACC_NONE),
    .mul_ready    (md_mul_ready),
    .div_busy     (md_div_busy),
    .resp_valid   (md_resp_vld),
    .resp_data    (md_resp_data),
    .resp_tag     (md_resp_tag),
    .resp_is_div  (md_resp_is_div),
    .wb_grant     (1'b1),
    .flush_valid  (redirect),
    .flush_tag    ({MD_TAG_W{1'b0}})
);

// ---------------------------------------------------------------------------
// 除法: 占住 EX 等结果 (doc §5.5 "慢就慢, 但绝不阻塞别人")
// ---------------------------------------------------------------------------
// `& md_resp_is_div` 不能省: 乘法是真流水, 它完全可能在除法迭代期间从写回口
// 出来一条响应 —— 那条响应属于**另一条**指令 (它自己会走到 WB, 由 wb_wD_eff
// 取走)。不区分的话除法会拿着乘法的 resp 提前放行, 结果错得毫无痕迹。
assign div_stall = ex_is_div & ~(md_resp_vld & md_resp_is_div);

// ---------------------------------------------------------------------------
// 结果通路
// ---------------------------------------------------------------------------
// 除法结果在这一拍就折进流水 (被 div_stall 顶住的那几拍, 结果出来才放行),
// 于是它照常沿 EX→MEM→WB 退休, 提交点/精确异常全都不用改。
// 乘法的结果不在这一拍 —— 见下面的 wb_wD_eff。
wire [31:0] ex_alu_c_final = ex_is_div ? md_resp_data : ex_alu_c;

// 数据存储的读地址: 送给同步 DRAM 的读口, 下一拍数据正好在 MEM 级被用掉。
// 越界/非访存指令的地址无所谓 —— 读是**无副作用**的, 而 MEM 级那一路读 mux 由
// `ADDR_IN_MAP 与对外设的解码门控 (perip_bridge), 越界读出来的东西没人要。
// (地址高 16 位在上面的宏里本来就要求是 0, 这里截断到字地址即可。)
assign Bus_raddr = ex_alu_c_final[15:2];

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

// ---------------------------------------------------------------------------
// 三个后继 PC 候选值**从寄存器直算**, 不再串在 ALU 后面 (2026-09-28)
//
// 原来 actual_npc 取的是 ex_alu_c (分支/JAL 走 pc_EX+sext, jalr 走 ALU 的 A+B)。
// 那条路是 ex_A_final → ALU 32 位进位链 (5 级) → 目标 → mux, 而 FPGA 的关键路径
// 恰好就是 "EX 重定向 → 前端数组地址" —— ALU 进位链白占 5 级。
//
// jalr 的目标 = ALU 的 A+B, 而 jalr 的 alua_sel=ALUA_SEL_RD1 / alub_sel=ALUB_SEL_SEXT
// (Control.v 的 SYSTEM 臂), 且 jalr 的 ex_csr_op 恒为 NONE ⇒ ex_A_final == ex_A。
// 所以 npc_jalr = ex_A + ex_B 与原来的 ex_alu_c **逐位相同**, 只是把加法器搬到
// 并行位置、从寄存器直接起算。5% 利用率下多两个 32 位加法器是免费的。
// ---------------------------------------------------------------------------
wire [31:0] npc_pc4  = pc_EX + 32'd4;       // 顺序后继
wire [31:0] npc_imm  = pc_EX + ex_sext;     // 分支 / JAL 目标
wire [31:0] npc_jalr = ex_A + ex_B;         // jalr 目标 (= ALU 的 A+B)

wire [31:0] ex_target = ex_is_jalr ? npc_jalr : npc_imm;
wire ex_inst_misaligned = have_inst_EX & (ex_br_taken | ex_is_jump | ex_is_jalr)
                        & (ex_target[1:0] != 2'b00);

`ifdef USE_IFU_ANY
// ===================== 误预测检测与前端重定向 =====================
// 真实后继 PC。与旧 NPC.v 不同, 这里直接用 pc_EX 作基准, 不再依赖
// "if_pc == pc_EX + 8" 那个关系 (旧 NPC 里 PC + offset - 8 的 -8 就是
// 为这个关系打的补丁)。
// 三个候选值都已在上面并行算好, 这里只剩一层 3 路 mux。
wire [31:0] actual_npc = ex_is_jalr ? npc_jalr
                       : (ex_br_taken | ex_is_jump) ? npc_imm
                       : npc_pc4;
// 非对齐目标不重定向: IFU 对非对齐目标只会预测 pc+4, 必然判"误预测",
// 但把非对齐 PC 发给 IFU 只会让它报取指故障并停住 (fault_stop_q 要等
// 重定向才清) —— 交给 ex_inst_misaligned 异常在 WB 处理。
wire mispredict = have_inst_EX & ~ex_inst_misaligned & (actual_npc != ex_pred_npc);

// Hazard_Detection 的 branched 冲刷源换成 mispredict: 预测正确时零气泡,
// 预测错了才像旧设计那样冲 IF/ID。
assign branched = mispredict;

// EX 级重定向 (IFU 内部 RTU 优先于 IU; 与陷阱同拍时由 ~redirect 掐掉)
assign iu_ifu_chgflw_vld = mispredict & ~redirect;
assign iu_ifu_chgflw_pc  = actual_npc;

// ===================== BHT 训练反馈 =====================
// 一条条件分支在 EX 解析出结果就回送一次, 不论预测对错 —— 方向表靠这个训练,
// 只报误预测的话预测正确的分支永远学不到. 用 ex_npc_op==BRANCH 而不是
// ex_br_taken: 不跳的分支同样要训练.
// 预测错了的那一拍还会同时拉 iu_ifu_chgflw_vld, 两者指向同一条指令, IFU
// 借此用预测前的 GHR 修复 VGHR (rv32_ifu_bht.v 的 ghr_updt_vld 分支).
// ~stall 是必需的: ID_EX 在停顿时是"保持"而不是插气泡, 不加这个门控同一条
// 分支会在 EX 停多拍、把同一次解析重复上报.
assign iu_bht_check_vld    = have_inst_EX & (ex_npc_op == `NPC_SEL_BRANCH) &
                             ~stall & ~redirect;
assign iu_cur_pc           = pc_EX;
assign iu_bht_condbr_taken = ex_alu_f;
assign iu_bht_pred         = ex_bht_pred;
assign iu_chk_idx          = ex_bht_chk;

`ifdef USE_IFU2
// ifu2 的预测器训练: 条件分支 / JAL / JALR 一律回送。
//   * 用 actual_npc 而不是各自算一遍目标 —— 它已经是"真实后继 PC", 分支不跳时
//     就是 pc+4, 对 BTB 的"不跳"训练正好用不上目标, 由 upd_taken 决定写不写。
//   * ~stall 与上面 iu_bht_check_vld 同理: ID_EX 停顿时是保持, 不加门控同一条
//     指令会在 EX 停多拍、把同一次解析重复上报, 把方向计数器反复往同一方向推。
//   * ~redirect (陷阱) 同拍的那条已被冲刷, 不能训练。
//   * 注意**不能**加 ~mispredict: 误预测那一次恰恰是最该学的一次。
assign iu_btb_update_vld = have_inst_EX
                         & ((ex_npc_op == `NPC_SEL_BRANCH) ||
                            (ex_npc_op == `NPC_SEL_JAL)    ||
                            (ex_npc_op == `NPC_SEL_ALU))
                         & ~stall & ~redirect;
assign iu_btb_cur_pc = pc_EX;
assign iu_btb_taken  = (ex_npc_op == `NPC_SEL_BRANCH) ? ex_alu_f : 1'b1;
assign iu_btb_target = actual_npc;
assign iu_btb_is_cond = (ex_npc_op == `NPC_SEL_BRANCH);
assign iu_btb_is_jal  = ex_is_jump;
assign iu_btb_is_jalr = ex_is_jalr;
// GHR 快照随指令走完全程 (IFU 打包 → IF_ID → ID_EX → 这里), 与指令天然同序。
// 不能用"重定向时再读一次 GHR"那种做法 —— 那时 GHR 已经被错误路径上的块推过了。
assign iu_btb_chk = ex_bht_chk;
`endif
// WB 提交点陷阱/中断/mret 重定向
assign rtu_ifu_flush     = redirect;
assign rtu_ifu_chgflw_vld = redirect;
assign rtu_ifu_chgflw_pc  = redirect_pc;
`endif

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
// RS/RC 的"旧值"用的也是锁进来的那一份 (与 A 口同源, 保证 csrrw 后紧跟 csrrs 时
// 置位/清位是相对**新值**做的)。
wire [31:0] ex_csr_wdata = (ex_csr_op == `CSR_OP_RW) ? ex_csr_src
                         : (ex_csr_op == `CSR_OP_RS) ? (ex_csr_rdata |  ex_csr_src)
                         : (ex_csr_op == `CSR_OP_RC) ? (ex_csr_rdata & ~ex_csr_src)
                         : 32'b0;

// ---------------------------------------------------------------------------
// ID 级 CSR 读 + EX→ID 旁路 (2026-09-28)
//
// 读地址用 id_csr_addr (本条指令自己的 inst[31:20]), 结果随 ID_EX 锁一拍再进 EX。
// 于是 CSR 的 16:1 读 mux 整条离开 EX 的组合路径。
//
// ⚠️ 旁路是必需的, 而且必须带 `~redirect`:
//   * 不带旁路: 指令 N (csrrw) 在 EX 写 CSR 的同拍, N+1 正在 ID 读 —— 读到的是
//     **写之前**的旧值, 而架构要求 N+1 看到新值;
//   * 不带 ~redirect: CSR 实例的写使能就是 `ex_csr_we & ~redirect`。重定向那拍
//     这条更年轻的 CSR 指令会被 flush、写不进去, 旁路却把它的值转发出去 ——
//     下游会读到"其实从没被写过"的值。
//   * 只旁路 EX 一级就够: MEM/WB 级那些写是在它们自己的 EX 拍落的盘, 早已生效。
//
// 已知的行为偏移: 计数器类 (mcycle/minstret/cycle/instret) 与 mip 的读**早一拍**。
// difftest 不比较 mcycle/minstret (golden_model/include/cpu.h 明确排除); CoreMark
// 的 Total ticks 是首尾两次 rdcycle 相减, 两次同时早一拍 ⇒ 差值不变。
// ---------------------------------------------------------------------------
assign id_csr_rdata = (ex_csr_we & ~redirect & (ex_csr_addr == id_csr_addr))
                    ? ex_csr_wdata : csr_rdata;

CSR U_CSR(
    .clk            (cpu_clk),
    .rst            (cpu_rst),
    // 读地址来自 **ID** (见上); 读写口仍然在 EX, 语义不变。
    .raddr_i        (id_csr_addr),
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
    .stall          (div_stall),     // 只剩除法会占住 EX (乘法已真流水, 不再停顿)
    .flush          (redirect),      // 陷阱重定向: 与 stall 做同样的清空
    .ex_irq_safe    (ex_irq_safe),
    .ex_exc_valid   (ex_exc_valid_f),
    .ex_exc_cause   (ex_exc_cause_f),
    .ex_exc_tval    (ex_exc_tval_f),
    .ex_is_mret     (ex_is_mret),
    .ex_csr_we      (ex_csr_we  ),
    .ex_rf_we       (ex_rf_we    ),
    .ex_is_mul      (ex_is_mul   ),
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
    .mem_is_mul     (mem_is_mul  ),
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
    .mem_is_mul      (mem_is_mul),
    .mem_wR          (mem_wR),
    .mem_wD          (mem_wD),
    .wb_irq_safe     (wb_irq_safe),
    .wb_exc_valid    (wb_exc_valid),
    .wb_exc_cause    (wb_exc_cause),
    .wb_exc_tval     (wb_exc_tval),
    .wb_is_mret      (wb_is_mret),
    .wb_rf_we        (wb_rf_we),
    .wb_is_mul       (wb_is_mul),
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
    .wb_wD          (wb_wD_eff   ),
    .id_rR1         (id_inst[19:15]),
    .id_rR2         (id_inst[24:20]),
    .branched       (branched    ),
    .trap           (redirect    ),
    .ex_rf_we       (ex_rf_we    ),
    .mem_rf_we      (mem_rf_we   ),
    .ex_is_mul      (ex_is_mul   ),
    .mem_is_mul     (mem_is_mul  ),
    // 转发源也要用掐过的写使能: 陷阱指令(非对齐 load)的结果不能写回,
    // 也就不能被后面的指令转发走
    .wb_rf_we       (wb_rf_we_eff ),
    .div_stall      (div_stall   ), // 除法占住 EX
    .mul_stall      (mul_stall   ), // 乘法冒险停 ID (归因统计用)
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
    assign debug_wb_value     = wb_wD_eff;
`endif

endmodule

