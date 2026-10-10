`timescale 1ns / 1ps

`include "defines.vh"
// ⚠️ 无条件 include: 下面 RTU 实例的几个 preg 常量按 `RTU_PREG_W 展开 (见 RTU_define.vh)。
//    文件里另有一处 `include 在 `ifdef RTU_DBG 里 (调试打印用), 那处**不能**顶替这一处。
`include "RTU_define.vh"

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
// id_sext_op / id_alua_sel / id_alub_sel / id_is_illegal / id_is_ecall / id_is_ebreak
// 已经从本模块删除 —— 它们只在 ID 级内部用 (Control -> SEXT / ALU_input_MUX /
// 异常检出), 现在都是 mySoC/idu/rtl/IDU.v 的内部线网。
wire ex_alu_f;
wire [31:0] ex_alu_c;
wire [31:0] mem_alu_c;
wire [31:0] wb_alu_c;
wire [`NPC_SEL_WIDTH-1:0] id_npc_op;
wire [`NPC_SEL_WIDTH-1:0] ex_npc_op;
wire [`ALU_OP_WIDTH-1:0] id_alu_op;
wire [`ALU_OP_WIDTH-1:0] ex_alu_op;
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
wire hz_flush_id_ex;   // Hazard_Detection 出的那份 (与 RTU 的合并成 flush_id_ex)

// ===================== 退休单元 (RTU) 接口 —— 阶段 1 (§7 读法 A) =====================
// 这一组全部**先声明再赋值**: 本仓有过"先用后声明 ⇒ 1 位隐式线网、语义静默错"
// 的前科 (见 rv32ifu2_top.v / cpu/sim/rtl_patch/README.md), 而这里全是窄位宽信号。
wire        hz_stall;                  // Hazard_Detection 的原始停顿
wire        rtu_disp_stall;            // RTU 的派遣停顿 (冲刷窗口 / ROB 满 / CSR 在途)
wire        rtu_disp_vld0;             // 派遣回执: 车道 0 本拍真的进了 ROB
wire [6:0]  rtu_disp_iid0;             // 回执里的编号 (随指令带进流水线)
wire [6:0]  id_iid;                    // = rtu_disp_iid0 (ID 那拍取)
wire [6:0]  ex_iid;                    // ID_EX 带下来的同一份
wire [6:0]  mem_iid;                   // EX_MEM 带下来的同一份 (完成/异常口用它)
wire        rtu_commit_vld0;           // 交付脉冲 (退休窗口槽 0)
wire        rtu_commit_ena0;           // 写寄存器的使能 (陷阱那条为 0)
wire [31:0] rtu_commit_pc0;
wire [31:0] rtu_commit_value0;
wire [4:0]  rtu_commit_reg0;
wire        rtu_trap_vld;              // 同步异常 或 中断 (两者都写 mepc/mcause/mtval)
wire        rtu_mret_vld;
wire [31:0] rtu_trap_epc, rtu_trap_tval;
wire [4:0]  rtu_trap_cause;
wire        rtu_beu_flush_chgflw_mask;
wire        rtu_cmplt_vld;             // 完成信号 (从 MEM 级报)
wire        rtu_expt_vld;              // 异常收集口 (从 MEM 级报)
wire        rtu_resolve_vld;           // 解析口 (BEU, EX 级)
wire        rtu_resolve_taken;
wire        rtu_resolve_mispred;
wire [31:0] rtu_resolve_target;
wire        rtu_int_pending;
wire        rtu_ifu_flush;             // ← RTU 实例驱动 (陷阱/中断/mret; D13 后误预测不发)
wire        rtu_core_redirect;         // ← RTU 实例驱动: 核内重定向事件 (四类源都算)
wire        beu_redirect_vld;          // → RTU: EX 级真的发出误预测重定向的那一拍
wire        rtu_ifu_chgflw_vld;
wire [31:0] rtu_ifu_chgflw_pc;
// 阶段 4b: 退休点重训练口 (RTU 实例驱动 → ifu2 的 rtu_train_*)。
// ⚠️ **必须在这里显式声明位宽** —— 8 根里只有 vld 是 1 位, 其余是 32/32/25 位。
//    漏声明它们会变成 **1 位隐式线网** (VCS 只报 IWNF 警告, 不报错), 训练数据被
//    静默截成最低位: 功能全对 (预测器只影响准确率)、difftest 全绿, 但方向表被
//    灌进垃圾。这就是 §9 的 R7 与 `cpu/sim/rtl_patch/README.md` 记的那个坑。
//    (2026-10-02 真踩到了: 加完接线后 compile.log 里 8 条 IWNF。)
wire        rtu_ifu_train_vld;
wire [31:0] rtu_ifu_train_pc;
wire [31:0] rtu_ifu_train_target;
wire [24:0] rtu_ifu_train_chk;
wire        rtu_ifu_train_taken;
wire        rtu_ifu_train_is_cond;
wire        rtu_ifu_train_is_jal;
wire        rtu_ifu_train_is_jalr;
wire        wb_irq_safe;               // 给 difftest: 这一拍是不是"取中断的沿"
wire        rtu_csr_we;                // 退休拍: CSR 写使能 (含"这条真要写"的口径)
wire [11:0] rtu_csr_addr;              // 退休拍: CSR 地址 (读口 2 与写口共用)
wire [31:0] rtu_csr_wdata;             // 退休拍: CSR 新值 (RTU 现算)
wire [31:0] rtu_csr_rdata;             // 2 号读口的输出 (在途 CSR 指令的旧值)
wire [1:0]  rtu_retire_cnt;            // 本拍退休条数 (0..3)
wire        irq_taken;                 // = RTU 的 int_take (rtu_trap_vld 且无交付脉冲)
                                       //   ⚠️ 必须在这里声明: 它在 U_CSR 的
                                       //   trap_cause_i 里就被用了, 晚声明会造出
                                       //   1 位隐式线网 (VCS 只报 IPDW 警告、不报错)。

wire id_rf1_used;
wire id_rf2_used;

wire branched;

// ===================== RV32M: 乘除法单元接口 =====================
// 单元是**真流水**的乘法 + radix-4 的除法, 两条独立流水共用一个带 tag 的
// 请求/写回口 (见 mySoC/iu/rtl/MUL_DIV.v)。核这边分四件事:
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
wire        id_is_mret;
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
wire        wb_exc_valid, wb_is_mret, wb_csr_we;
wire        wb_irq_safe_mm;   // MEM_WB 锁出来的那份 (只用于比对, 见下)
wire [31:0] mem_csr_src;       // CSR 指令的源操作数, 随流水到 WB (退休拍现算新值用)
wire [31:0] wb_csr_src;
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

// ---------------------------------------------------------------------------
// 提交点 = RTU 的退休窗口 (阶段 1: doc/rtu_plan_zh.md §7)
//
// 改动前这里是**组合的 WB 级裁决** (wb_exc / irq_taken / wb_mret)。现在三者
// 全部由 RTU 在退休拍给出, mycpu 只做转发:
//   * 同步异常: 在 **MEM 级**报到 RTU 的异常口 (expt_*), 退休那拍命中;
//   * 中断:     int_pending 送进 RTU, 由它按"退休窗口 + 无副作用"裁决;
//   * mret:     表项里的 flags 位, 退休那拍由 RTU 发重定向。
// 时序与改动前**同拍**: 指令在 MEM 那拍报异常/完成, 下一拍 (它的 WB 拍) 是
// 退休判决拍 —— 与旧的 `wb_exc` 落在同一拍, 所以周期数不变。
// ---------------------------------------------------------------------------
// 核内重定向事件: 同步异常 / 中断入口 / mret / **误预测退休**, 四者都要求
// "冲掉年轻指令"(冲 IF_ID/ID_EX/EX_MEM、按掉 store 写使能、CSR 静默、训练门控)。
// 由 RTU 的慢路状态机在退休拍发出, 单拍脉冲。
//
// ⚠️ **D13 (2026-10-02): 这一根与"重启前端"分开了。**
//    以前 `redirect = rtu_ifu_flush`, 一根干两件事。D13 之后两者对**误预测**取值不同:
//      * `rtu_core_redirect` (本根) —— 误预测**仍然要拉**: 后端与 IDU 里更年轻的指令
//        必须冲掉, 而且它按着 store 的写使能 (见下面的 mem_ram_we)。
//      * `rtu_ifu_flush` / `rtu_ifu_chgflw_vld` —— 误预测**不再拉**: 前端在 BEU 的
//        执行级重定向那拍就已经被送到真实目标, 再重启一次就是"重取两次"(阶段 1
//        实测 +4.66% 周期)。配套的是 `beu_redirect_vld` → RTU 把派遣从那一拍起冻住。
//    合成一根的症状: 错误路径的 store 会写进内存 (mem_ram_we 的 ~redirect 失效)。
wire redirect    = rtu_core_redirect;
wire [31:0] redirect_pc = rtu_ifu_chgflw_pc;

// 有效的寄存器写使能: 陷阱指令不写 rd(非对齐 load 的 rf_we=1 必须按掉),
// 被中断 squash 掉的指令也不写. 必须从源头掐掉 —— 只改 debug_wb_ena 是不够的,
// 因为 RegFile 和转发逻辑(Hazard_Detection 的 wb_rf_we)都在用它.
// rtu_trap_vld = trap_hit | int_take, 覆盖两者 (mret 的 rf_we 本来就是 0)。
wire wb_rf_we_eff = wb_rf_we & ~rtu_trap_vld;

// ---------------------------------------------------------------------------
// WB 级写回数据: 乘法的结果在这里接进来 (doc §7)
// ---------------------------------------------------------------------------
// doc §7 写的是"并进 mem_wD (MEM_WB 入口加 mux)", 但按 §3.3 的时序图, 乘法是
// T 拍发射、T+2 拍出响应 —— 那是乘法自己的 **WB 拍**, 而 wb_wD 早在 T+1 边沿就
// 从 mem_wD 锁好了, 赶不上 MEM_WB 入口。所以 mux 落在 WB 级的输出上。
// 正确性靠"响应属于哪条指令由指令自己说了算": is_mul 跟着指令走完流水, 而
// 乘法的发射拍与它的 WB 拍相差恒定 2 拍, 两者天然对齐 (见 MUL_DIV.v 的说明)。
wire [31:0] wb_wD_eff = wb_is_mul ? md_resp_data : wb_wD;
// instret 的口径: **RTU 的退休条数** (rtu_retire_cnt, §6.3 ⑥⑦ —— 是 [1:0] 的
// 计数不是 3 位宽)。被中断 squash 掉的那条不计 (那拍 pop_n=0), 同步异常那条
// **计** (它的交付脉冲照样发, 与 golden model 在 WB 级的 minstret++ 对齐)。
//
// `retire_now` 保留成"这一拍有没有退休"的脉冲 (tb_miniRV_dpi.sv 的指令计数
// 探针抓它): 就是退休条数的非零位 —— 取中断那拍 pop_n=0, 所以不计。

// CSR 文件是否"静止": 没有任何一级存在途的 CSR 写, 也没有重定向.
// DUT 在 EX 级写 CSR(比提交早 2 拍), golden model 在提交当拍才写 ——
// 只有在静止时才保证两边读到同一个状态, 在途窗口里比较会误报.
// (陷阱自己的 mepc/mcause/mstatus 写发生在重定向边沿, 所以也排除 redirect.)
// ⚠️ 口径随块 ③ 改过: CSR 写搬到退休拍之后就没有"EX 级早写两拍"的在途窗口了,
//    只剩"这一拍正在落盘"需要跳过 (那一刻 DUT 读到的是边沿前的值, 而 golden
//    model 已经在 gm_check_step 里应用完了)。下一拍两边都是新值。
wire csr_quiescent = ~redirect & ~rtu_csr_we;
wire retire_now    = |rtu_retire_cnt;

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
// ⚠️ rtu_ifu_* 三根**无条件声明** —— 它们现在由 RTU 实例驱动, 而 redirect /
//    redirect_pc (MUL_DIV 的 flush_valid / 各级流水寄存器的 flush 都在用)
//    在 IFU=0 时也要有值。放进 `ifdef USE_IFU_ANY 里会造出 1 位隐式线网。

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
    // ---- 训练口: 数据来自**退休窗口** (阶段 4b, 2026-10-02) ----
    // 原来那一组 EX 级训练信号 (iu_bht_check_vld / iu_cur_pc / iu_chk_idx /
    // iu_btb_update_vld / iu_btb_cur_pc / iu_btb_target / iu_btb_is_jal / is_jalr)
    // 在**本例化里已经全部不用** —— rv32ifu2_top 的端口已随之删掉。
    // ⚠️ 但它们的 `assign` 在上面**保留着**: 下面那个 `ifu_subsys` (IFU=1, 遗留
    //    的 C910 派生前端) 还在消费同一组网线, 仍是 EX 级训练。
    //    ⇒ 已知缺口: **IFU=1 下训练没搬** (它慢 10~15 倍, 不是乱序的目标配置)。
    .rtu_train_vld        (rtu_ifu_train_vld),
    .rtu_train_pc         (rtu_ifu_train_pc),
    .rtu_train_target     (rtu_ifu_train_target),
    .rtu_train_chk        (rtu_ifu_train_chk),
    .rtu_train_taken      (rtu_ifu_train_taken),
    .rtu_train_is_cond    (rtu_ifu_train_is_cond),
    .rtu_train_is_jal     (rtu_ifu_train_is_jal),
    .rtu_train_is_jalr    (rtu_ifu_train_is_jalr),
    // ---- 下面这三个**留在 EX**(不是训练口): 重定向当拍现算 ghr_restore 与
    //      RAS 指针要用当拍值, 换成退休点会把 GHR/RAS 修到别的指令的快照上 ----
    .iu_btb_chk           (iu_btb_chk),
    .iu_btb_taken         (iu_btb_taken),
    .iu_btb_is_cond       (iu_btb_is_cond),
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
// ⚠️ 这条**必须显式声明**在 U_IDU 例化之前 —— 只留例化口、把声明删掉的话它会
//    变成**隐式 1 位线网** (本工程反复踩过这个坑, 见 rv32ifu2_top.v 里 chk0_f 的
//    注释)。VCS 对这种情形只报 PCWM-W 警告、不报错, 而后果是
//    ID_EX.ex_csr_addr 与 U_CSR.raddr_i 都只剩 1 位 ⇒ **所有 CSR 访问都会读写到
//    错的寄存器**。译码本身已经搬进 mySoC/idu/rtl/IDU.v (idu_csr_addr_o)。
wire [11:0] id_csr_addr;
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
    
// ---------------------------------------------------------------------------
// ID 级数据通路 —— 整块封装在 mySoC/idu/rtl/IDU.v 里。
//
// 搬进去的: Control(主译码) / SEXT(立即数) / ID 级异常检出 / RegFile /
//           ALU_input_MUX(操作数选择)。
// 留在外面的理由:
//   * IF_ID / ID_EX 是 IF|ID 与 ID|EX 的**边界寄存器**, 不属于 ID 级本体;
//   * Hazard_Detection 要看 EX/MEM/WB 三级, 是跨级单元;
//   * CSR 读数据的 EX→ID 旁路 (下面的 id_csr_rdata) 选择子全在 EX 级, 而且
//     ex_csr_wdata 在本文件里声明得比这里晚 400 行, 搬进去会变成隐式线网。
//
// ⚠️ 右边这些 id_* 网名**一个都不能改**: tb/tb_miniRV_dpi.sv 用
//    dut.Core_cpu.<net> 一级层次探针直接抓它们
//    (id_inst/have_inst_ID, id_pc, id_pred_npc, stall/flush_if_id/flush_id_ex,
//     id_exc_valid/cause/tval)。带 idu_ 前缀的只有 IDU 自己的端口。
// ---------------------------------------------------------------------------
IDU U_IDU(
    .clk                (cpu_clk),
    .rst                (cpu_rst),
    // ---- 来自 IF_ID 的指令包 ----
    .idu_inst_data_i    (id_inst),
    .idu_have_inst_i    (have_inst_ID),
    .idu_pc_i           (id_pc),
    .idu_ifu_fault_i    (id_fault),
    .idu_ifu_cause_i    (id_cause),
    // ---- 来自 WB 的寄存器堆写口 ----
    .idu_wb_wR_i        (wb_wR),
    .idu_wb_we_i        (wb_rf_we_eff),
    .idu_wb_wD_i        (wb_wD_eff),
    // ---- 译码结果: 控制信号 ----
    .idu_npc_op_o       (id_npc_op),
    .idu_alu_op_o       (id_alu_op),
    .idu_rf_wsel_o      (id_rf_wsel),
    .idu_dram_sel_o     (id_dram_sel),
    .idu_rf_we_o        (id_rf_we),
    .idu_ram_we_o       (id_ram_we),
    .idu_is_muldiv_o    (id_is_muldiv),
    .idu_is_mret_o      (id_is_mret),
    // ---- 译码结果: CSR ----
    .idu_csr_op_o       (id_csr_op),
    .idu_csr_imm_o      (id_csr_imm),
    .idu_csr_we_o       (id_csr_we),
    .idu_csr_addr_o     (id_csr_addr),
    // ---- 译码结果: 源寄存器使用标志 (给 Hazard_Detection) ----
    .idu_rf1_used_o     (id_rf1_used),
    .idu_rf2_used_o     (id_rf2_used),
    // ---- ID 级数据通路 ----
    .idu_sext_o         (id_sext),
    .idu_rD1_o          (id_rD1),
    .idu_rD2_o          (id_rD2),
    .idu_A_o            (id_A),
    .idu_B_o            (id_B),
    // ---- ID 级异常 ----
    .idu_exc_vld_o      (id_exc_valid),
    .idu_exc_cause_o    (id_exc_cause),
    .idu_exc_tval_o     (id_exc_tval)
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
    .id_iid        (id_iid       ),
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
    .ex_iid        (ex_iid       ),

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

// RV32M Multiplier and Divider Unit (真流水 + tag 接口, 见 mySoC/iu/rtl/MUL_DIV.v)
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
wire ex_is_jump  = (ex_npc_op == `NPC_SEL_JAL);
wire ex_is_jalr  = (ex_npc_op == `NPC_SEL_ALU);

// ---------------------------------------------------------------------------
// 分支执行单元 (BEU, 见 BEU.v 头注释) —— 条件/目标/误预测判决全在这里
//
// ⚠️ actual_npc 必须先声明再用 (下面的例化端口): 隐式线网是 1 位 —— 本工程
//    已经在这类坑上栽过两次 (见 rv32ifu2_top.v 的 chk 位宽注释)。
//
// 改动前: ex_br_taken = (npc_op==BRANCH) && ex_alu_f, 而 ex_alu_f 来自共享 ALU,
// 它的 A 口前面还挂着 `ex_csr_op ? ex_csr_rdata : ex_A` 的 mux 和 32 位比较的
// 进位链 —— FPGA 报告里 EX 族 132/500 条路径的起点就是 ex_csr_op_reg。
// 现在条件直接从 ex_A/ex_B 判, 目标三个候选并行算, 每个候选的
// {失配, 非对齐} 也提前并行算好, 只留一层浅 select。
// ---------------------------------------------------------------------------
wire        ex_br_taken;
wire [31:0] ex_target;
wire [31:0] actual_npc;
wire        ex_npc_mismatch;
wire        ex_tgt_misalign;

BEU U_BEU(
    .A           (ex_A),
    .B           (ex_B),
    .pc          (pc_EX),
    .sext        (ex_sext),
    .pc4         (ex_pc4),
    .pred_npc    (ex_pred_npc),
    .alu_op      (ex_alu_op),
    .is_branch   (ex_npc_op == `NPC_SEL_BRANCH),
    .is_jal      (ex_npc_op == `NPC_SEL_JAL),
    .is_jalr     (ex_npc_op == `NPC_SEL_ALU),
    .br_taken    (ex_br_taken),
    .actual_npc  (actual_npc),
    .target      (ex_target),
    .mis_align   (ex_tgt_misalign),
    .npc_mismatch(ex_npc_mismatch)
);

// ---------------------------------------------------------------------------
// 误预测检测 (候选并行算, 见 BEU.v)
//
// 三个后继 PC 候选 (pc4 / pc+sext / A+B) 与**每个候选各自的**
// {与 pred_npc 的失配, 目标非对齐} 都在 BEU 里从寄存器直算, 这里只剩门控:
//   * 非对齐目标不重定向: IFU 对非对齐目标只会预测 pc+4, 必然判"误预测",
//     但把非对齐 PC 发给 IFU 只会让它报取指故障并停住 (fault_stop_q 要等
//     重定向才清) —— 交给 ex_inst_misaligned 异常在 WB 处理。
// ---------------------------------------------------------------------------
wire ex_inst_misaligned = have_inst_EX & (ex_br_taken | ex_is_jump | ex_is_jalr)
                        & ex_tgt_misalign;

`ifdef USE_IFU_ANY
// ===================== 误预测检测与前端重定向 =====================
wire mispredict = have_inst_EX & ~ex_inst_misaligned & ex_npc_mismatch;

// Hazard_Detection 的 branched 冲刷源换成 mispredict: 预测正确时零气泡,
// 预测错了才像旧设计那样冲 IF/ID。
assign branched = mispredict;

// EX 级重定向 (IFU 内部 RTU 优先于 IU; 与陷阱同拍时由 ~redirect 掐掉)。
// ~rtu_beu_flush_chgflw_mask: 慢路冲刷窗口 (T..T+2) 里屏蔽 BEU 再发重定向,
// 否则两次重定向会打架 (对应 C910 的 rtu_iu_flush_chgflw_mask, §6.2)。阶段 1
// 里 EX 那拍已经是气泡、本来发不出重定向, 但这条门控是"契约要求"的接线。
assign iu_ifu_chgflw_vld = mispredict & ~redirect & ~rtu_beu_flush_chgflw_mask;
assign iu_ifu_chgflw_pc  = actual_npc;

// D13: 把"EX 级**真的**发出了误预测重定向"告诉 RTU。它据此把一个锁存位置起,
// 与冲刷窗口一起把派遣一直冻到 F2 —— 否则前端会在"重定向到该分支退休"之间
// 派出若干条拿着**未恢复的 RAT** 改名出来的指令, 只能在退休时冲掉、再从同一个
// 目标重取一次 (阶段 1 实测 +4.66% 周期)。
// ⚠️ 冻结窗口的另一半 — "误预测退休时不再重启前端" — 在 RTU_flush 里 (D13 ②)。
//    只做这一半不做那一半, 就只是把重取推迟, 白花冻结。
assign beu_redirect_vld = iu_ifu_chgflw_vld;

// ===================== BHT 训练反馈 =====================
// ⚠️⚠️ **2026-10-02 阶段 4b: 这一整块对 `rv32ifu2_top` 已经不再生效。**
//    训练源已改由退休窗口驱动 (`rtu_ifu_train_*` → ifu2 的 `rtu_train_*`,
//    见上面 u_ifu_subsys 的例化), 理由见 doc/rtu_plan_zh.md §7-4b:
//    乱序下分支是乱序完成/解析的, EX 级训练会把 GHR 按乱序顺序推、方向表被
//    静默带偏; 而且下面这些门控**挡不住错误路径**的分支。
//    这里**保留**是因为 `ifu_subsys` (IFU=1, 遗留的 C910 派生前端) 还在消费
//    同一组网线 —— 它的训练口形状不同 (bht_check_vld/chk_idx), 没跟着搬。
//    ⇒ **已知缺口: IFU=1 下训练仍在 EX**。IFU=1 慢 10~15 倍, 不是乱序的目标
//      配置; 哪天真要用它跑乱序, 这块必须一起搬 (或直接退役 IFU=1)。
//    ⚠️ `iu_btb_chk / iu_btb_taken / iu_btb_is_cond` **三个仍属 EX**, 不是遗留:
//       ifu2 在**重定向当拍**用它们现算 ghr_restore / RAS 指针 (见
//       rv32ifu2_top.v 的 GHR 段), 换成退休点会修到别的指令的快照上。
//
// 下面这一组只服务 `ifu_subsys`:
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
assign iu_bht_condbr_taken = ex_br_taken;
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
assign iu_btb_taken  = (ex_npc_op == `NPC_SEL_BRANCH) ? ex_br_taken : 1'b1;
assign iu_btb_target = actual_npc;
assign iu_btb_is_cond = (ex_npc_op == `NPC_SEL_BRANCH);
assign iu_btb_is_jal  = ex_is_jump;
assign iu_btb_is_jalr = ex_is_jalr;
// GHR 快照随指令走完全程 (IFU 打包 → IF_ID → ID_EX → 这里), 与指令天然同序。
// 不能用"重定向时再读一次 GHR"那种做法 —— 那时 GHR 已经被错误路径上的块推过了。
assign iu_btb_chk = ex_bht_chk;
`endif
// 前端重定向的另一路 (rtu_ifu_flush / rtu_ifu_chgflw_vld / rtu_ifu_chgflw_pc)
// 现在**由 RTU 实例直接驱动** —— 见文件末尾的 u_rtu。这里原来那三条
// `assign rtu_ifu_* = redirect` 必须删掉: 留着就是双驱动 (X)。
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
// CSR 文件 —— 阶段 1: **读写都搬到了退休拍** (doc/rtu_plan_zh.md §7 / §6.3 ⑤⑩)
//
// 改动前: 读在 ID、写在 EX(比提交早两拍)。现在:
//   * **写**: `rtu_csr_we/rtu_csr_addr/rtu_csr_wdata` —— RTU 在退休那拍现算
//     (RW 直接写源, RS 置位, RC 清位), 源操作数来自两条路:
//       - 立即数形式 (csrrwi/si/ci): CSR 槽里的 `csr_imm` (inst[19:15]);
//       - 寄存器形式: `rtu_csr_src_rdata` ← 随流水走到 WB 的 rs1 (阶段 1 的等价物,
//         阶段 2 的 PRF 有读口之后换成按 `rtu_csr_src_raddr` 真读)。
//     "旧值"由 RTU 用 `csr_rdata` 现读 (下面那个地址 mux 保证它读的是**在途那条**
//     CSR 指令的地址)。
//   * **读**: 两个口 (CSR.v 里多了一个 16:1 读译码器):
//       - 1 号口按 `id_csr_addr` —— 本指令自己的旧值, 当 rd 用 (走 ALU 的 A 口,
//         与改动前完全一致, 所以 rd 的取值/转发路径一位没动);
//       - 2 号口按 `rtu_csr_addr` —— RTU 在退休拍读, 算 RS/RC 的新值 + difftest。
//     为什么不做成"一口 + 地址 mux": 那需要 mycpu 知道"有没有 CSR 在途",
//     而那是 RTU 的内部状态 (`csr_inflight`), 把它引出来是新的跨模块耦合。
//
// ⚠️ 两条旧注释随本次改动作废:
//   ① "EX→ID 旁路"删掉了 —— 写挪到退休拍之后, 后一条 CSR 指令被 `csr_inflight`
//      一直按在 ID 里, 等前一条退休(写落盘)才放行 ⇒ 它读到的一定是新值,
//      旁路本身也不再对应任何真实写 (`ex_csr_we` 已经不驱动写口了)。
//   ② "计数器类读早一拍"的已知偏移也一并消失。
//
// 注: CSR 指令的 **rd 值**仍由 WB 的写口送出, 与 §6.3 ⑤ 的"rd 值退休当拍产生"
//     是同一拍; `rtu_csr_rd_we/addr/wdata` 是阶段 2 物理寄存器堆写回用的, 阶段 1
//     与 WB 写口**同拍同值**, 因此不接。
// ---------------------------------------------------------------------------
// 1 号读口 = ID 级: 本指令自己的旧值 (当 rd 用, 走 ALU 的 A 口, 与改动前一致)。
// 2 号读口 = 退休拍: RTU 按 `rtu_csr_addr` 读, 算 RS/RC 的新值 + difftest 取值。
assign id_csr_rdata = csr_rdata;

// ---------------------------------------------------------------------------
// 阶段 1 的调试探针 (只在编译时加 `+define+RTU_DBG` 才存在; 默认不参与编译)
//
//   make run TEST=trap VCS_FLAGS_EXTRA="+define+RTU_DBG"
//
// 两条都在这次接 RTU 时立过功, 留着当现成的抓手:
//   * `[csrID]/[csrEX]` —— CSR 指令在 ID/EX 两侧看到的地址/旧值/写数据。
//     "csrr 读回 0"那个坑就是靠它定位的 (CSR 被钉在 EX, 旁路值被冲成 0)。
//   * `[cyc]` —— 每拍打印退休指针/占用计数与影子窗口 (含 vld/cmplt/pc/iid)。
//     "同一条指令退休两次"是靠它看出 win1 挂着一份上一代的表项。
// ⚠️ `[cyc]` 是**逐拍**打印, 只用在小用例上; 跑 coremark 会把日志撑爆。
// ---------------------------------------------------------------------------
`ifdef RTU_DBG
`include "RTU_define.vh"
always @(posedge cpu_clk) begin
    if (have_inst_ID && (id_csr_op != `CSR_OP_NONE))
        $display("[csrID t=%0t] pc=%h addr=%h op=%b csr_rdata=%h id_csr_rdata=%h | 退休侧: we=%b addr=%h wdata=%h rdata2=%h | redirect=%b stall=%b",
                 $time, id_pc, id_csr_addr, id_csr_op, csr_rdata, id_csr_rdata,
                 rtu_csr_we, rtu_csr_addr, rtu_csr_wdata, rtu_csr_rdata, redirect, stall);
    if (rtu_csr_we)
        $display("[csrRET t=%0t] we=%b addr=%h wdata=%h rdata2=%h | wb_csr_src=%h wb_csr_we=%b",
                 $time, rtu_csr_we, rtu_csr_addr, rtu_csr_wdata, rtu_csr_rdata,
                 wb_csr_src, wb_csr_we);
    if (!$test$plusargs("RTU_DBG_QUIET"))
        $display("[cyc t=%0t] rptr=%0d occ=%0d | win0 vld=%b cmp=%b pc=%h iid=%h | win1 vld=%b cmp=%b pc=%h | vld0=%b trap=%b flushing=%b fsm=%b",
          $time, u_rtu.u_rob.rptr, u_rtu.u_rob.occ_q,
          u_rtu.win0[`RTU_E_VLD], u_rtu.win0[`RTU_E_CMPLT], u_rtu.win0[`RTU_E_PC], u_rtu.win_iid0,
          u_rtu.win1[`RTU_E_VLD], u_rtu.win1[`RTU_E_CMPLT], u_rtu.win1[`RTU_E_PC],
          rtu_commit_vld0, rtu_trap_vld, u_rtu.flushing, u_rtu.u_flush.st_q);
end
`endif
CSR U_CSR(
    .clk            (cpu_clk),
    .rst            (cpu_rst),
    // 1 号读口: ID 级 (本指令自己的旧值 → rd)
    .raddr_i        (id_csr_addr),
    .rdata_o        (csr_rdata),
    // 2 号读口: RTU 退休拍 (在途那条 CSR 指令的地址)
    .raddr2_i       (rtu_csr_addr),
    .rdata2_o       (rtu_csr_rdata),
    // 软件写口: **退休拍**由 RTU 驱动 (rtu_csr_we 已经含了"这条真要写"的口径,
    // 也自动排除了被冲掉的那些 —— 不再需要 EX 时代那条 `& ~redirect`)。
    .we_i           (rtu_csr_we),
    .waddr_i        (rtu_csr_addr),
    .wdata_i        (rtu_csr_wdata),
    // 陷阱的 mepc/mcause/mtval/mstatus 写: 改由 **RTU 退休拍**驱动。
    // 与旧的 wb_exc/irq_taken **同拍** (指令在 MEM 报异常、WB 拍退休判退),
    // 所以 CSR 文件看到的时刻一位不变。trap_epc 取表项里的 PC, 与旧的 pc_WB 同值。
    .trap_i         (rtu_trap_vld),
    // ⚠️ mcause 的**中断位 (bit31) 要在这里补**: §6.2 的 rtu_trap_cause 只有 5 位
    //    (异常号), 中断/异常的区分由"这一拍有没有交付脉冲"给出 (§6.3 ⑥/⑫):
    //    取中断那拍 pop_n=0 ⇒ 没有交付脉冲。
    .trap_cause_i   ({irq_taken, 26'b0, rtu_trap_cause}),
    .trap_epc_i     (rtu_trap_epc),
    .trap_tval_i    (rtu_trap_tval),
    .mret_i         (rtu_mret_vld),
    .retire_i       (rtu_retire_cnt),
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
    .ex_iid         (ex_iid     ),
    .ex_csr_src     (ex_rD1     ),   // 转发后的 rs1 —— CSR 的源操作数
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
    .mem_iid        (mem_iid    ),
    .mem_csr_src    (mem_csr_src),

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
    .mem_csr_src     (mem_csr_src),
    .wb_csr_we       (wb_csr_we  ),
    .wb_csr_src      (wb_csr_src ),
    .mem_rf_we       (mem_rf_we),
    .mem_is_mul      (mem_is_mul),
    .mem_wR          (mem_wR),
    .mem_wD          (mem_wD),
    .wb_irq_safe     (wb_irq_safe_mm),
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
    // ⚠️ 老的名字 `stall` 让给下面那条"合并后"的网线 (TB 用 dut.Core_cpu.stall
    //    一级探针抓它, 名字不能变)。冒险本身的停顿在这里叫 hz_stall。
    .stall          (hz_stall    ),
    .flush_IF_ID    (flush_if_id ),
    .flush_ID_EX    (hz_flush_id_ex ),
    .A_forward      (A_forward   ),
    .B_forward      (B_forward   ),
    .Forward_A_en   (Forward_A_en),
    .Forward_B_en   (Forward_B_en)
);
// ---------------------------------------------------------------------------
// 退休单元 (RTU) —— 阶段 1 的接线现场 (doc/rtu_plan_zh.md §6/§7)
//
// 映射口径按 §7 的**读法 A**: 阶段 1 不重命名,
//     disp*_dst_preg = disp*_old_preg = p_<lreg>,  ren_preg_req = 0
// 于是四态表/自由池/AMT 全是惰性的 (§7 那张表), 真正激活在阶段 2。
//
// ============================ 本块搬进来的东西 ============================
// ① 派遣点 = **ID 级**: 指令在 ID 这拍进 ROB, 同一拍锁进 ID_EX; 回执的 iid
//    跟着指令走 ID_EX→EX_MEM, 完成/解析/异常口都按它寻址 (§6.3 ⑪)。
// ② 完成 (cmplt) 从 **MEM 级**报: 这样"完成位置进表项"与"退休判决"正好错开
//    一拍 ⇒ 退休判决落在该指令的 **WB 拍**, 与改动前的 `have_inst_WB` 同拍。
// ③ 异常 (expt) 也从 **MEM 级**报 (异常随流水锁存到 MEM), 于是陷阱裁决同样
//    落在 WB 拍 —— 与旧的 `wb_exc` 同拍。
// ④ 误预测的解析 (resolve) 从 **EX 级**报 (BEU 就在那儿), 早于 cmplt, 满足 A8。
// ⑤ 重定向/冲刷全部改由 RTU 的慢路状态机发 (§6.3 ⑨), 包括**误预测退休**那一路。
//
// 还没接 (后续块): store 退休时写 / CSR 退休时读写 / instret 计数 / 训练搬退休点。
// ---------------------------------------------------------------------------

// ---- 派遣车道的字段 (阶段 1 单发射, 只用车道 0) ----
wire        id_is_csr    = (id_csr_op != `CSR_OP_NONE);
// 控制转移: 条件分支 / JAL / JALR —— 三者都可能被 BTB 预测错, 都要走
// "解析写表项 → 退休时慢路冲刷"这条路 (§6.3 ⑨)。与 iu_btb_update_vld 同集合。
wire        id_is_cf     = (id_npc_op == `NPC_SEL_BRANCH) |
                           (id_npc_op == `NPC_SEL_JAL)    |
                           (id_npc_op == `NPC_SEL_ALU);
wire        id_irq_safe  = ~id_ram_we & ~id_csr_we;   // 只进 flags 的 intmask 位
// 控制转移的三分类 (阶段 4b): BTB 的 `upd_cond/upd_jal/upd_jalr` 要它。
// 原来这是 EX 当拍从 ex_npc_op/ex_is_jump/ex_is_jalr 现算的; 搬到退休点之后
// 必须随指令存进 ROB 表项 (RTU_FLG_JAL / RTU_FLG_JALR), 否则表项里只剩
// 一位 `is_branch`, 分不出"写哪一类"。本核 JALR 走 `NPC_SEL_ALU` (同 ex_is_jalr)。
wire        id_is_jal    = (id_npc_op == `NPC_SEL_JAL);
wire        id_is_jalr   = (id_npc_op == `NPC_SEL_ALU);
// A6d: **不写寄存器时必须给 0**。给非 0 的垃圾 rd (store 的那几位本来是立即数)
// 会让 RTU 按"要写 rd"去记账, 退休时 wr_eff 又不成立 ⇒ 编号静默泄漏。
wire [4:0]  id_dst_lreg  = id_rf_we ? id_inst[11:7] : 5'd0;
// 派遣条件: 真有一条指令, 而且它这一拍**真的会离开 ID**。
//   ~stall      —— 停顿时 IF_ID 保持, 不加就会被重复派遣 (建多条表项);
//   ~flush_if_id—— 它这一拍已被冲掉 (branched/trap), 不该再建表项。
wire        rtu_disp0_vld = have_inst_ID & ~stall & ~flush_if_id;
assign      id_iid        = rtu_disp_iid0;

RTU u_rtu (
    .cpu_clk (cpu_clk),
    .cpu_rst (cpu_rst),

    // ---- §6.0 preg 分配握手: 阶段 1 恒不请求 (读法 A) ----
    // ⚠️ 2026-10-08 新增: LSU 的 store 重放请求 (对应 lsu_rtu_wb_pipe4_flush/spec_fail)。
    //    顺序核里 LSU 还没接 ⇒ 恒 0; 接上之后由 LSU 侧按"这条 store 的投机写失败了"
    //    驱动 (带该指令的 iid)。恒 0 时下面那条重放路径永不触发, 行为与改动前逐位一致。
    .lsu_replay_vld     (1'b0),
    .lsu_replay_iid     (7'd0),
    .ren_preg_req       (2'd0),
    .ren_preg_req_lreg0 (5'd0),
    .ren_preg_req_lreg1 (5'd0),
    .ren_preg_req_lreg2 (5'd0),

    // ---- §6.1 派遣: 车道 0 = ID 级那条; 车道 1/2 恒空 (单发射) ----
    .disp0_vld      (rtu_disp0_vld),
    .disp0_pc       (id_pc),
    .disp0_chk      (id_bht_chk),
    .disp0_dst_lreg (id_dst_lreg),
    .disp0_rf_we    (id_rf_we),
    // 读法 A 的恒等映射: dst_preg = old_preg = p_<lreg>。
    // p0..p31 恒为 ARCH, 所以 ret_arch_vld 是幂等的、ret_free_vld 恒 0
    // (被 old_preg >= 32 那道门控挡住) —— 见 §7 的那张"惰性"表。
    .disp0_dst_preg ({{(7-`RTU_PREG_W){1'b0}}, id_dst_lreg}),   // 位宽随 PREG 档
    .disp0_old_preg ({{(7-`RTU_PREG_W){1'b0}}, id_dst_lreg}),
    .disp0_src1_preg({{(7-`RTU_PREG_W){1'b0}}, id_inst[19:15]}),  // CSR 的 rs1 (= uimm5 for csrr*i)
    .disp0_csr_addr (id_csr_addr),
    // ⚠️ A6c: disp*_csr_op 要的是 **funct3 原样** (001=RW 010=RS 011=RC
    //    101=RWI 110=RSI 111=RCI), 不是 Control.v 译出来的 CSR_OP_* 两位码 ——
    //    RTU 用 bit2 判"是不是立即数形式" (`csr_is_imm`), 喂两位码会让它恒判成
    //    寄存器形式, csrrwi 于是拿 rs1 的**垃圾值**当源 (症状: csrrwi 写进去
    //    0 而不是 uimm5, 且只在 CSR 文件比对那一步炸)。
    .disp0_csr_op   (id_inst[14:12]),
    .disp0_csr_imm  (id_inst[19:15]),
    // 7 位 (2026-10-02 加 JAL/JALR 两位, 见 RTU_define.vh 的 RTU_FLG_*)
    .disp0_flags    ({id_is_jalr, id_is_jal, id_is_mret, id_is_csr,
                      id_irq_safe, id_ram_we, id_is_cf}),
    .disp0_sq_id    (3'd0),

    .disp1_vld (1'b0), .disp1_pc (32'd0), .disp1_chk (25'd0),
    .disp1_dst_lreg (5'd0), .disp1_rf_we (1'b0),
    .disp1_dst_preg ({`RTU_PREG_W{1'b0}}), .disp1_old_preg ({`RTU_PREG_W{1'b0}}),
    .disp1_src1_preg({`RTU_PREG_W{1'b0}}),
    .disp1_csr_addr (12'd0), .disp1_csr_op (3'd0), .disp1_csr_imm (5'd0),
    .disp1_flags (7'd0), .disp1_sq_id (3'd0),

    .disp2_vld (1'b0), .disp2_pc (32'd0), .disp2_chk (25'd0),
    .disp2_dst_lreg (5'd0), .disp2_rf_we (1'b0),
    .disp2_dst_preg ({`RTU_PREG_W{1'b0}}), .disp2_old_preg ({`RTU_PREG_W{1'b0}}),
    .disp2_src1_preg({`RTU_PREG_W{1'b0}}),
    .disp2_csr_addr (12'd0), .disp2_csr_op (3'd0), .disp2_csr_imm (5'd0),
    .disp2_flags (7'd0), .disp2_sq_id (3'd0),

    // ---- §6.1 完成: 从 MEM 级报 (见文件头 ②) ----
    .cmplt_vld0 (rtu_cmplt_vld), .cmplt_iid0 (mem_iid),
    .cmplt_vld1 (1'b0), .cmplt_iid1 (7'd0),
    .cmplt_vld2 (1'b0), .cmplt_iid2 (7'd0),
    .cmplt_vld3 (1'b0), .cmplt_iid3 (7'd0),
    .cmplt_vld4 (1'b0), .cmplt_iid4 (7'd0),
    // D1.3: 口 5/6 = LSU 读/写。单发射核里 load/store 也走完成口 0 (MEM 级),
    // 这两路留给 IQ 接进来时按功能单元拆开用。
    .cmplt_vld5 (1'b0), .cmplt_iid5 (7'd0),
    .cmplt_vld6 (1'b0), .cmplt_iid6 (7'd0),
    // ---- §6.1 解析结果 (BEU, EX 级) ----
    .resolve_vld    (rtu_resolve_vld),
    .resolve_iid    (ex_iid),
    .resolve_taken  (rtu_resolve_taken),
    .resolve_mispred(rtu_resolve_mispred),
    .resolve_target (rtu_resolve_target),
    // ---- §6.1 异常 (MEM 级) ----
    // ⚠️ 2026-10-10: RTU 的异常口由 1 路扩成 3 路 (IU / load / store), 多源在
    //    `RTU_expt` 里做锦标赛 —— 因为乱序核里 load 与 store 是两条独立流水、
    //    可以同拍都报, 上游先合成一路会在同拍冲突时永久丢异常。
    //    **本核是顺序核**, 异常只有 MEM 级这一路、天然"老级优先", 没有多源冲突
    //    ⇒ 全部接到 **IU 那一路** (语义上它承载"非访存流水检出的异常"), 另两路恒 0。
    //    这里**不拆 load/store**: 顺序核在 MEM 级已经分不出这条指令是不是访存,
    //    而拆错的代价 (报错的 cause) 比不拆大。
    .expt_iu_vld (rtu_expt_vld),
    .expt_iu_iid (mem_iid),
    .expt_iu_cause({1'b0, mem_exc_cause}),
    .expt_iu_tval(mem_exc_tval),
    .expt_ld_vld (1'b0), .expt_ld_iid (7'd0),
    .expt_ld_cause(5'd0), .expt_ld_tval(32'd0),
    .expt_st_vld (1'b0), .expt_st_iid (7'd0),
    .expt_st_cause(5'd0), .expt_st_tval(32'd0),

    // ---- §6.1 存储队列 / CSR / 中断 ----
    // 阶段 1 还没有存储队列: 每个 store 的数据在 EX 级就算好了、直接随流水带下来,
    // 到 MEM 级就写出去 —— 对退休级而言"永远就绪", 所以 sq_rdy 恒 1、sq_stall 恒 0。
    // (⚠️ 这里**不能**接 0: 接 0 会让每一条 store 都永远退不了休 —— 死锁。)
    .sq_rdy0 (1'b1), .sq_rdy1 (1'b1), .sq_rdy2 (1'b1), .sq_stall (1'b0),
    // ---- §6.1 IDU 的释放否决掩码 (第 5 态, 2026-10-08) ----
    // TODO: 等 IDU 接进来, 改接 `idu_rtu_pst_preg_dealloc_mask`。阶段 1 恒 0 是**正确**
    // 取值, 不只是占位: 阶段 1 是恒等映射 (dst == old) ⇒ `ret_free_vld ≡ 0` ⇒ 一次释放
    // 都不会发生, 掩码没有作用对象; 反过来掩码本身现在也恒 0 (IDU 那侧 SDIQ 的
    // `ct_idu_is_sdiq.sv:38` 的 src_mask_clk 全仓无驱动, 见接口待办的"先决条件")。
    // ⚠️ **必须显式写这一行**: 漏了它是悬空 Z ⇒ `st==RELEASE` 那支变 X ⇒ else-if 视为假
    //    ⇒ 号**永久漏在 RELEASE** (不是 X 爆炸, 是静默漏号)。极性见 RTU.v 端口注释。
    .preg_dealloc_mask (64'd0),
    // 阶段 1 的 CSR 仍在 EX 级读写, 所以这里喂进去的 csr_rdata 其实是**该条指令
    // 自己的 CSR 旧值**(= wb_wD_eff: CSR 的 rf_wsel 是 ALUC 且 A 口取旧值, 见
    // Control.v 的 SYSTEM 分支)。RTU 在退休拍正好需要"这条 CSR 指令的旧值"——
    // 于是阶段的巧合正好对上。块 ④ 把 CSR 搬到退休时, 这里换成按 rtu_csr_addr
    // 组合读 CSR 文件。
    .csr_rdata  (rtu_csr_rdata),
    .int_pending(rtu_int_pending),

    // ---- §6.1 物理寄存器堆读口 (A1) ----
    // 阶段 1 的 PRF 就是核里的 RegFile, 而退休拍**恒等于 WB 拍**(见文件头 ②),
    // 所以值就在 wb_wD_eff 上 —— 直接喂, 不另开读口。
    // (rtu_preg_raddr* 的观察口在阶段 1 就是 lreg 自己, 仍接出来给以后的 PRF 用。)
    .preg_rdata0 (wb_wD_eff), .preg_rdata1 (32'd0), .preg_rdata2 (32'd0),
    // CSR 的源操作数 (转发后的 rs1) 随流水走到 WB —— 退休拍 RTU 现算新值要用。
    .rtu_csr_src_rdata (wb_csr_src),
    .csr_trap_vector (csr_trap_vector),
    .csr_mepc        (csr_mepc),

    // ===================== 输出 =====================
    // ---- 前端重定向 (陷阱/中断/mret; D13 后误预测不发) ----
    .rtu_ifu_flush      (rtu_ifu_flush),
    .rtu_ifu_chgflw_vld (rtu_ifu_chgflw_vld),
    .rtu_ifu_chgflw_pc  (rtu_ifu_chgflw_pc),
    // ---- 退休点重训练 (阶段 4b): 送到上面 ifu2 的 `rtu_train_*` ----
    // ⚠️ 这 8 根**必须两头都接**: 只接消费侧 (ifu2) 不接生产侧 (u_rtu), 线就是
    //    悬空的 Z, `Z & is_cond` = X ⇒ 训练一次都不会发生。症状**只体现在跑分上**
    //    (branch_bench 方向准确率 92% → 15%, CoreMark 15M 拍跑不完),
    //    difftest 全绿、单测台全绿、编译只报 IWNF/PCWM 警告。
    //    (2026-10-02 真踩了: 先漏声明变成 1 位隐式线网, 补了声明又漏了这半边。)
    .rtu_ifu_train_vld     (rtu_ifu_train_vld),
    .rtu_ifu_train_pc      (rtu_ifu_train_pc),
    .rtu_ifu_train_target  (rtu_ifu_train_target),
    .rtu_ifu_train_chk     (rtu_ifu_train_chk),
    .rtu_ifu_train_taken   (rtu_ifu_train_taken),
    .rtu_ifu_train_is_cond (rtu_ifu_train_is_cond),
    .rtu_ifu_train_is_jal  (rtu_ifu_train_is_jal),
    .rtu_ifu_train_is_jalr (rtu_ifu_train_is_jalr),
    // ---- 核内重定向事件 (四类源都算, 含误预测) —— 驱动上面的 `redirect` ----
    .rtu_core_redirect  (rtu_core_redirect),
    // ---- BEU: 冲刷窗口里屏蔽再发重定向 + D13 的"EX 真的发了重定向"回执 ----
    .rtu_beu_flush_chgflw_mask (rtu_beu_flush_chgflw_mask),
    .beu_redirect_vld   (beu_redirect_vld),
    // ---- 重命名级: 阶段 1 只消费派遣停顿与派遣回执 ----
    .rtu_disp_stall (rtu_disp_stall),
    .rtu_disp_vld0  (rtu_disp_vld0),
    .rtu_disp_iid0  (rtu_disp_iid0),
    // ---- 提交点副作用: CSR 读写 (阶段 1 块 ③ 接上) ----
    .rtu_csr_we     (rtu_csr_we),
    .rtu_csr_addr   (rtu_csr_addr),
    .rtu_csr_wdata  (rtu_csr_wdata),
    .rtu_retire_cnt (rtu_retire_cnt),
    // ---- 陷阱 / mret ----
    .rtu_trap_vld   (rtu_trap_vld),
    .rtu_mret_vld   (rtu_mret_vld),
    .rtu_trap_epc   (rtu_trap_epc),
    .rtu_trap_tval  (rtu_trap_tval),
    .rtu_trap_cause (rtu_trap_cause),
    // ---- difftest ----
    .dbg_commit_vld0  (rtu_commit_vld0),
    .dbg_commit_ena0  (rtu_commit_ena0),
    .dbg_commit_pc0   (rtu_commit_pc0),
    .dbg_commit_reg0  (rtu_commit_reg0),
    .dbg_commit_value0(rtu_commit_value0)

    // ⚠️ 其余输出 (preg 分配/释放观察口、CSR 写口、store 提交口、retire_cnt、
    //    训练口、backend_flush、beu_retire_iid、commit_vld1/2) 本块**刻意不接**,
    //    由后面的块逐个补上 —— 每接一组在这里加, 不要在别处另起一份例化。
);

// 派遣停顿并入流水线停顿: 冲刷窗口 (T..T+2) 里必须冻住 ID, 否则那条指令会
// 顺着流水走下去、而它的表项在 FLUSH_2 被清掉 ⇒ **静默丢一条指令**
// (D3.1 的前提③)。ROB 满 / CSR 在途同理由 RTU 一并给出 (§6.2 的 rtu_disp_stall)。
//
// ⚠️ **必须用"停前端 + 给 EX 灌气泡"这一对, 不能只拉 stall。**
//    本核的 stall 语义是"保持 ID_EX"(不是插气泡), 只拉 stall 会把 EX 里那条
//    指令**钉死在 EX**上。对冲刷无所谓 (反正要冲掉), 但对 `csr_inflight`
//    是致命的: CSR 指令被钉在 EX ⇒ 永远走不到退休 ⇒ `csr_inflight` 永远不清 ⇒
//    派遣永远停摆 (实测: CSR 卡在 EX 4 拍, 期间它的 ex_rD1 被无条件更新的
//    A/B 锁存块冲成 0, 还把后面那条 csrr 的旁路值一起带成 0 —— 现象是
//    "csrr 读回 0" 而不是卡死, 更难查)。
//    load-use / mul_stall 用的就是这一对 (见 Hazard_Detection 的 flush_ID_EX),
//    这里与它们对齐: 前端停, EX 那条照常往前走, 留下一个气泡。
assign stall = hz_stall | rtu_disp_stall;
assign flush_id_ex = hz_flush_id_ex | rtu_disp_stall;

// 中断的屏蔽条件 (与改动前 irq_taken 里的那三个与项同源)。RTU 还会补上
// "退休窗口 + 无副作用"那几条 (§6.3 ⑥ / D10 的单退休模式)。
assign rtu_int_pending = csr_mip_mtip & csr_mie_mtie & csr_mstatus_mie;

// ---------------------------------------------------------------------------
// 完成 / 异常 / 解析 三个上报口
//
// **为什么是 MEM 级而不是 WB 级**: RTU 把"完成"位置进表项之后, 判退用的是
// 寄存过的表项内容, 中间差一拍。从 MEM 报 ⟹ 判决落在该指令的 WB 拍 ——
// 与改动前的 `have_inst_WB` 同拍, 周期数一位不变 (见文件头 ②)。
// 同时 RegFile 的写口仍在 WB 拍, 所以"退休拍 = WB 拍"这条不变式保证
// dbg_commit_value (= wb_wD_eff) 就是这条指令的结果。
//
// 另一条**必须**同时满足的是契约 A8: 解析不能晚于完成。这里解析在 EX 报、
// 完成在 MEM 报, 天然满足。
// ---------------------------------------------------------------------------
// ~redirect: 重定向那拍流水线上全是比队头年轻的指令 (要被冲掉的), 不必也不能
// 给它们标完成 —— 虽然表项随后会被 FLUSH_2 清掉, 但少一分"错路径标完成"就
// 少一分将来被人依赖的机会。
assign rtu_cmplt_vld = have_inst_MEM & ~redirect;
// 异常: 随流水锁存到 MEM (ID 级的非法/取指故障 + EX 级的非对齐/越界都在里面),
// 所以这一个口就覆盖了 §6.3 ④ 说的"ID/EX/MEM 各级检出点"。
// 单发射顺序核里"最旧者胜"是自动的: 先进 MEM 的那条一定更老。
assign rtu_expt_vld  = have_inst_MEM & mem_exc_valid & ~redirect;

`ifdef USE_IFU_ANY
// 解析: BEU 在 EX 解出"这条控制转移跳没跳、去了哪、是不是预测错了"。
//
// ⚠️ 这里**不加 `~stall`**(邻近的 iu_bht_check_vld / iu_btb_update_vld 加了)。
//    原因: 解析结果决定了**误预测冲刷**, 漏报一次就是"错误路径照常执行"。
//    而"重复上报"在这条路上根本不可能发生 —— ID_EX 只在 `stall & ~flush` 时保持,
//    而 stall 的三个来源里 load_use / mul_stall 都同时拉 flush_ID_EX (EX 那条照常
//    前进), 唯一真正钉住 EX 的是 div_stall, 而被钉住的必然是**除法**、不可能是
//    控制转移 (`ex_is_cf` 当场为 0)。所以精确的写法就是不加 stall 门控。
//    (阶段 1 加过 `~stall`, 它会把 rt_ 的 disp_stall 也一起吃进来 —— 那时 EX 里的
//     分支明明要往前走, 解析却被吞掉。目前走不到, 但那是颗定时炸弹。)
wire ex_is_cf = (ex_npc_op == `NPC_SEL_BRANCH) |
                (ex_npc_op == `NPC_SEL_JAL)    |
                (ex_npc_op == `NPC_SEL_ALU);
assign rtu_resolve_vld     = have_inst_EX & ex_is_cf & ~redirect;
assign rtu_resolve_taken   = (ex_npc_op == `NPC_SEL_BRANCH) ? ex_br_taken : 1'b1;
assign rtu_resolve_mispred = mispredict;
assign rtu_resolve_target  = actual_npc;
`else
// IFU=0 的老通路没有"预测"这回事 (分支在 EX 直接算 NPC), 解析口没有意义。
assign rtu_resolve_vld     = 1'b0;
assign rtu_resolve_taken   = 1'b0;
assign rtu_resolve_mispred = 1'b0;
assign rtu_resolve_target  = 32'd0;
`endif

// 给 difftest 的"这个提交点能不能取中断": **就是 RTU 的 int_take 本身**
// (rtu_trap_vld=1 且这一拍没有交付脉冲)。
// 为什么不沿用旧的 `~ram_we & ~csr_we`: RTU 的口径是 `~store & ~csr & ~mret`,
// 两者对"不写 CSR 的 CSR 指令"结论不同 —— 只要有一次判断不同, 模型就会比 DUT
// 早/晚一条指令取中断, 之后每条都对不上。直接把 DUT 的判决推给模型, 两边
// **逐拍同沿**。
// 顺带修掉旧口径的一个隐患: 陷阱当拍旧口径会给出 irq_safe=1, 于是模型可能
// 把中断取在一条"将要陷入"的指令上 (trap.S 里只是侥幸没撞上)。
assign irq_taken   = rtu_trap_vld & ~rtu_commit_vld0;   // = RTU 的 int_take
assign wb_irq_safe = irq_taken;                          // 同口径推给 golden model
// (tb/tb_miniRV_dpi.sv:722 的陷阱诊断 $display 直接抓 dut.Core_cpu.irq_taken,
//  所以这个名字要留着 —— 它现在的含义是"这一拍退休窗口取走了中断"。)

`ifdef RUN_TRACE
//     Debug Interface —— 阶段 1 起**全部来自 RTU 的退休窗口** (§6.2 的 dbg_commit_*)
    // ⚠️ have_inst 必须**或上 rtu_trap_vld**: 被中断 squash 的那条不发交付脉冲
    //    (§6.3 ⑥), 但 golden model 是在"有指令提交"的那个沿里取中断的
    //    (dpi_shim.c:133-145 的 `if (!dut_wb_have_inst) return 0;`), 不给这个沿
    //    模型就永远取不到中断、差一条指令。见 §10.C 的 C3。
    //    同步异常那条本来就有脉冲 (rtu_trap_vld 与它重合), 所以这里只是把
    //    "中断"这一路的沿补上 —— 退休口径 (rtu_retire_cnt / 副作用) 一位没动。
    assign debug_wb_have_inst = rtu_commit_vld0 | rtu_trap_vld;
    assign debug_wb_pc        = rtu_commit_pc0;
    // ena 的口径对齐 golden model 的 `wb_en && !trapped`, 而 wb_en 是 `dst != 0`:
    // RTU 的 commit_ena 只到 "rf_we 且没陷阱", 少 `dst != 0` 这一条, 在这里补。
    // (addi x0, ... 的 rf_we=1、rd=0, DUT 与模型都必须报 ena=0 —— 两者必须能分开。)
    assign debug_wb_ena       = rtu_commit_ena0 & (rtu_commit_reg0 != 5'd0);
    assign debug_wb_reg       = rtu_commit_reg0;
    // 值 = 退休拍那条指令的结果。阶段 1 退休拍恒等于 WB 拍 ⇒ 就是 wb_wD_eff。
    assign debug_wb_value     = rtu_commit_value0;
`endif

endmodule

