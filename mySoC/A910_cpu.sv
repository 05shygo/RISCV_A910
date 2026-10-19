//----------------------------------------------------------------------------
// A910_cpu — 新顶层: 自研 IFU + C910 IDU/LSU/BIU + 自研 RTU
//
//---------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
//---------------------------------------------------------------------------
// Clocking :
//   顶层原来只有 AXI 那几个口, 没有任何时钟复位 —— 而五个子模块全都要。
//   这里补一对 clk/rst (高有效):
//
//     * IFU 的 clk/rst 与 RTU 的 cpu_clk/cpu_rst 都是高有效, 直接接;
//     * IDU/LSU/BIU 是 C910 口径的 forever_cpuclk/cpurst_b (低有效), 就地反相。
//
//   ⚠️ 反相只做一次: 由 RTU 的适配层产生 cpurst_b (它内部就是 ~cpu_rst),
//      顶层只声明不 assign。自己再反一次会变成双驱动, VCS 报 Error-[ICSD]。
//----------------------------------------------------------------------------

module A910_cpu

  //---------------------------------------------------------------------------
  // Ports
  //---------------------------------------------------------------------------
  (
    // Global signals
    input  wire         clk,        // 全核单时钟域
    input  wire         rst,        // 高有效 (与 IFU/RTU 同极性)

    //---------------------------------------------------------
    // AXI master read address
    //---------------------------------------------------------
    output wire [31:0]  biu_pad_araddr,
    output wire [3:0]   biu_pad_arid,
    output wire [1:0]   biu_pad_arlen,
    output wire [2:0]   biu_pad_arsize,
    output wire [1:0]   biu_pad_arburst,
    output wire [3:0]   biu_pad_arcache,
    output wire [2:0]   biu_pad_arprot,
    output wire         biu_pad_arvalid,
    input  wire         pad_biu_arready,

    //---------------------------------------------------------
    // AXI master read data
    //---------------------------------------------------------
    input  wire [127:0] pad_biu_rdata,
    input  wire [3:0]   pad_biu_rid,
    input  wire         pad_biu_rlast,
    input  wire [1:0]   pad_biu_rresp,
    input  wire         pad_biu_rvalid,
    output wire         biu_pad_rready,

    //---------------------------------------------------------
    // AXI master write address
    //---------------------------------------------------------
    output wire [31:0]  biu_pad_awaddr,
    output wire [3:0]   biu_pad_awid,
    output wire [1:0]   biu_pad_awlen,
    output wire [2:0]   biu_pad_awsize,
    output wire [1:0]   biu_pad_awburst,
    output wire [3:0]   biu_pad_awcache,
    output wire [2:0]   biu_pad_awprot,
    output wire         biu_pad_awvalid,
    input  wire         pad_biu_awready,

    //---------------------------------------------------------
    // AXI master write data
    //---------------------------------------------------------
    output wire [127:0] biu_pad_wdata,
    output wire [15:0]  biu_pad_wstrb,
    output wire         biu_pad_wlast,
    output wire         biu_pad_wvalid,
    input  wire         pad_biu_wready,

    //---------------------------------------------------------
    // AXI master write response
    //---------------------------------------------------------
    input  wire [3:0]   pad_biu_bid,
    input  wire [1:0]   pad_biu_bresp,
    input  wire         pad_biu_bvalid,
    output wire         biu_pad_bready
  );

  `include "RTU_define.vh"          // 端口位宽随 PREG 档变 (见下面 preg 那几条)
  `include "lsiq_defines.vh"        // LSIQ 那几根一位一项的向量随 LSIQ_ENTRY 变

  // ---------------------------------------------------------------------------
  //  Signal declarations
  // ---------------------------------------------------------------------------
  // 全量显式声明, 不留隐式线网。
  //
  // 本模块**不给 default_nettype 加开关**: 它是编译指令, 会跨文件生效 —— 在这里
  // 设了 none 而不在末尾还回去, 后面编到的文件全会受影响, 而"后面编到谁"取决于
  // Makefile 的文件顺序。所以改用全量显式声明 + elaborate 兜底 (见 Makefile 的
  // a910-elab: IWNF 必须为 0)。本仓在隐式线网上反复栽过 —— 多位信号被截成 1 位、
  // 悬空成 Z, 两者都是静默的, 扫描器抓不到 1 位信号。

  // IDU/LSU/BIU 口径的低复位, 由适配层产生。这里只声明不 assign —— 见文件头
  // §Clocking 里"反相只做一次"那条。
  logic rst_b;

  // ---- IFU ↔ IDU: 取指交付 ----
  // ⚠️ 2026-10-12: `ifu_inst*_vld` 是 IFU 的原始输出, `idu_inst*_vld` 是**过了
  //    "误预测冻结窗"之后**交给 IDU 的 (见下面 `mispred_hold_q` 那段)。别把两者
  //    又接成同一根 —— 那等于把冻结窗删掉。
  logic         ifu_inst0_vld;
  logic [127:0] idu_inst0_data;
  logic [ 24:0] idu_inst0_chk;
  logic         ifu_inst1_vld;
  logic [127:0] idu_inst1_data;
  logic [ 24:0] idu_inst1_chk;
  logic         ifu_inst2_vld;
  logic [127:0] idu_inst2_data;
  logic [ 24:0] idu_inst2_chk;
  logic         idu_inst0_vld;
  logic         idu_inst1_vld;
  logic         idu_inst2_vld;
  logic [  1:0] idu_accept_num;   // IDU 输出 → IFU 消费: 同拍收走的前缀条数
  logic [  1:0] ifu_accept_num;   // 过冻结窗之后才交给 IFU 的那一份 (冻结期夹成 0)
  logic         ifu_idu_flush;    // IFU 的内部冲刷, 只做观察口 (IDU 侧没有对应的口)
  // IFU 交出来的 128 位 → IDU 要的 97 位。布局见下面那三根 assign 的注释。
  logic [ 96:0] ifu_idu_ib_inst0_data;
  logic [ 96:0] ifu_idu_ib_inst1_data;
  logic [ 96:0] ifu_idu_ib_inst2_data;

  // ---------------------------------------------------------------------------
  // IDU ↔ LSU: 访存发射 + 队列状态 (IDU 与 LSU 之间的线, 不经过 RTU)
  // ---------------------------------------------------------------------------
  logic         idu_lsu_ld_sel;
  logic [  6:0] idu_lsu_ld_iid;
  logic [  5:0] idu_lsu_ld_preg;
  logic [ 31:0] idu_lsu_ld_src;
  logic [ 11:0] idu_lsu_ld_offset;
  // 2026-10-19 停用: 非对齐拆分 offset_plus
  //logic [ 12:0] idu_lsu_ld_offset_plus;
  logic         idu_lsu_ld_sign_extend;
  logic [  1:0] idu_lsu_ld_inst_size;
  //logic         idu_lsu_ld_unalign_2nd;
  logic [`LSIQ_NUM-1:0] idu_lsu_ld_lch_entry;
  logic         idu_lsu_ld_oldest;

  logic         idu_lsu_st_sel;
  logic [  6:0] idu_lsu_st_iid;
  logic [ 31:0] idu_lsu_st_src0;
  logic [ 11:0] idu_lsu_st_offset;
  //logic [ 12:0] idu_lsu_st_offset_plus;
  logic [  1:0] idu_lsu_st_inst_size;
  //logic         idu_lsu_st_unalign_2nd;
  logic [`LSIQ_NUM-1:0] idu_lsu_st_lch_entry;
  logic         idu_lsu_st_oldest;
  logic [  3:0] idu_lsu_st_sdiq_entry;

  logic         idu_lsu_sdiq_sel;
  logic [  3:0] idu_lsu_rf_pipe5_sdiq_entry;
  logic [ 31:0] idu_lsu_rf_pipe5_src0;

  logic [`LSIQ_NUM-1:0] lsu_idu_lq_full;
  logic         lsu_idu_lq_not_full;
  logic [`LSIQ_NUM-1:0] lsu_idu_rb_full;
  logic         lsu_idu_rb_not_full;
  logic [`LSIQ_NUM-1:0] lsu_idu_sq_full;
  logic         lsu_idu_sq_not_full;
  // 2026-10-19 停用: 非对齐第二半唤醒, IDU 不再接收
  //logic [`LSIQ_NUM-1:0] lsu_idu_secd;
  logic [`LSIQ_NUM-1:0] lsu_idu_imme_wakeup;
  logic         lsu_idu_lsiq_pop_vld;
  logic         lsu_idu_lsiq_pop0_vld;
  logic         lsu_idu_lsiq_pop1_vld;
  // ⚠️ 交付侧两侧名字不一致: IDU 叫 `lsu_idu_lsiq_pop_entry`, LSU 叫 `lsu_idu_pop_entry`
  //    (少个 `lsiq_`), 位宽与语义一致。顶层用 IDU 那一侧的名字。
  logic [`LSIQ_NUM-1:0] lsu_idu_lsiq_pop_entry;
  logic [  3:0] lsu_idu_has_in_sq;
  logic [  5:0] lsu_idu_wb_pipe3_wb_preg;
  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx;
  logic [ 31:0] lsu_idu_wb_pipe3_wb_preg_data;
  logic [ 63:0] lsu_idu_wb_pipe3_wb_preg_expand;
  logic         lsu_idu_wb_pipe3_wb_preg_vld;
  logic [  6:0] lsu_idu_wb_pipe3_wb_preg_iid;   // 数据写回那条的 iid (观察口按 iid 配对用)

  // ---------------------------------------------------------------------------
  // LSU ↔ BIU: 总线口 (读地址/读数据 + 两路写: store 走 WMB, victim 走 VB)
  //
  // ⚠️⚠️ 这一块**不是我们负责的接口**, 但原文件里这 40 多根线**一根都没声明**,
  //      全部落到隐式线网 —— 而 VCS 对隐式线网按 **1 位**处理, 于是:
  //          `biu_lsu_rdata` (128 位) 被截成 1 位, LSU 拿到的读数据只有最低位;
  //          `lsu_biu_araddr` (32 位) 被截成 1 位, 发出的地址只有 bit0。
  //      这**不会报错**、也不会变成 X, 只会静默地全错。elaborate 时表现为
  //      40 多条 `Warning-[PCWM-W] Port connection width mismatch`。
  //      这里按两侧端口表的真实位宽补齐声明 —— **只是补声明, 一个逻辑都不改**,
  //      但请 LSU/BIU 的负责人复核一遍(A910_cpu.sv 是他们建的文件)。
  // ---------------------------------------------------------------------------
  // LSU → BIU: 读地址通道
  logic [ 31:0] lsu_biu_araddr;
  logic [  3:0] lsu_biu_arid;
  logic [  1:0] lsu_biu_arlen;
  logic [  2:0] lsu_biu_arsize;
  logic [  1:0] lsu_biu_arburst;
  logic [  3:0] lsu_biu_arcache;
  logic [  2:0] lsu_biu_arprot;
  logic         lsu_biu_arvalid;
  logic         lsu_biu_arready;
  logic         lsu_biu_rready;
  // LSU → BIU: 写地址通道 — store 源
  logic [ 31:0] lsu_biu_aw_st_addr;
  logic [  3:0] lsu_biu_aw_st_id;
  logic [  1:0] lsu_biu_aw_st_len;
  logic [  2:0] lsu_biu_aw_st_size;
  logic [  1:0] lsu_biu_aw_st_burst;
  logic [  3:0] lsu_biu_aw_st_cache;
  logic [  2:0] lsu_biu_aw_st_prot;
  logic         lsu_biu_aw_st_valid;
  logic         lsu_biu_aw_st_ready;
  // LSU → BIU: 写地址通道 — victim(回写) 源
  logic [ 31:0] lsu_biu_aw_vict_addr;
  logic [  3:0] lsu_biu_aw_vict_id;
  logic [  1:0] lsu_biu_aw_vict_len;
  logic [  2:0] lsu_biu_aw_vict_size;
  logic [  1:0] lsu_biu_aw_vict_burst;
  logic [  3:0] lsu_biu_aw_vict_cache;
  logic [  2:0] lsu_biu_aw_vict_prot;
  logic         lsu_biu_aw_vict_valid;
  logic         lsu_biu_aw_vict_ready;
  // LSU → BIU: 写数据通道 — store 源
  logic [127:0] lsu_biu_w_st_data;
  logic [ 15:0] lsu_biu_w_st_strb;
  logic         lsu_biu_w_st_last;
  logic         lsu_biu_w_st_valid;
  logic         lsu_biu_w_st_ready;
  // LSU → BIU: 写数据通道 — victim 源
  logic [127:0] lsu_biu_w_vict_data;
  logic [ 15:0] lsu_biu_w_vict_strb;
  logic         lsu_biu_w_vict_last;
  logic         lsu_biu_w_vict_valid;
  logic         lsu_biu_w_vict_ready;
  // BIU → LSU: 读数据 + 写响应
  logic [127:0] biu_lsu_rdata;
  logic [  3:0] biu_lsu_rid;
  logic         biu_lsu_rvalid;
  logic         biu_lsu_rlast;
  logic [  1:0] biu_lsu_rresp;
  logic [  3:0] biu_lsu_bid;
  logic [  1:0] biu_lsu_bresp;
  logic         biu_lsu_bvalid;
  // ⚠️ `lsu_biu_bready` 是 `ct_biu_top` 的**输入**, 但 `lsu_top` 根本没有对应的
  //    输出口 —— 也就是说这根线现在**没有任何驱动**。留在这里不接常量, 见末尾
  //    待接清单的 E-3)。(接 0 会让写响应永远收不掉; 接 1 是"永远收", 但那是在
  //    替 LSU 做一个它还没表达的决定。)
  logic         lsu_biu_bready;

  // ⚠️ 下面这些线**跟着驱动它的一方**走, 不是一刀切:
  //    IDU 侧的 (`idu_rtu_disp*` / `rtu_idu_alloc_preg*`) 是同事的固定口径 ——
  //    派遣记录补到 7 位、分配号 6 位; RTU 侧的随 `RTU_PREG_W。
  //    两侧的差由适配层切, 切位写在适配层里 (显式), 不靠这里的端口隐式截断。
  // ---------------------------------------------------------------------------
  // RTU ↔ IDU: 经适配层 (RTU_idu_lsu_adapter)
  //
  // 两侧名字不同, 且适配层里有四类真变换(7→6 位 preg / 恢复表 32×7→32×6 逐槽
  // 重排 / 复位极性 / 三路请求→程序序前缀计数) —— **不要**在顶层直接对接这两组口,
  // 一定要过适配层。接法照抄 `rtu/rtl/RTU_subsys.v`(那份是脚本生成 + 过了 elaborate
  // 门禁的)。
  // ---------------------------------------------------------------------------
  logic         idu_rtu_ir_preg0_alloc_vld;
  logic         idu_rtu_ir_preg1_alloc_vld;
  logic         idu_rtu_ir_preg2_alloc_vld;
  logic [  5:0] rtu_idu_alloc_preg0;
  logic [  5:0] rtu_idu_alloc_preg1;
  logic [  5:0] rtu_idu_alloc_preg2;
  logic         rtu_idu_alloc_preg0_vld;
  logic         rtu_idu_alloc_preg1_vld;
  logic         rtu_idu_alloc_preg2_vld;
  logic [  6:0] rtu_idu_rob_inst0_iid;
  logic [  6:0] rtu_idu_rob_inst1_iid;
  logic [  6:0] rtu_idu_rob_inst2_iid;
  logic         rtu_idu_rob_full;
  logic [191:0] rtu_idu_rt_recover_preg;
  logic         rtu_yy_xx_flush;
  logic [ 63:0] idu_rtu_pst_preg_dealloc_mask;

  // ---- §6.1 派遣记录 (3 车道 × 12 字段) ----
  logic         idu_rtu_disp0_vld;
  logic [ 31:0] idu_rtu_disp0_pc;
  logic [ 24:0] idu_rtu_disp0_chk;
  logic [  4:0] idu_rtu_disp0_dst_lreg;
  logic         idu_rtu_disp0_rf_we;
  logic [  6:0] idu_rtu_disp0_dst_preg;
  logic [  6:0] idu_rtu_disp0_old_preg;
  logic [  6:0] idu_rtu_disp0_src1_preg;
  logic [ 11:0] idu_rtu_disp0_csr_addr;
  logic [  2:0] idu_rtu_disp0_csr_op;
  logic [  4:0] idu_rtu_disp0_csr_imm;
  logic [  6:0] idu_rtu_disp0_flags;

  logic         idu_rtu_disp1_vld;
  logic [ 31:0] idu_rtu_disp1_pc;
  logic [ 24:0] idu_rtu_disp1_chk;
  logic [  4:0] idu_rtu_disp1_dst_lreg;
  logic         idu_rtu_disp1_rf_we;
  logic [  6:0] idu_rtu_disp1_dst_preg;
  logic [  6:0] idu_rtu_disp1_old_preg;
  logic [  6:0] idu_rtu_disp1_src1_preg;
  logic [ 11:0] idu_rtu_disp1_csr_addr;
  logic [  2:0] idu_rtu_disp1_csr_op;
  logic [  4:0] idu_rtu_disp1_csr_imm;
  logic [  6:0] idu_rtu_disp1_flags;

  logic         idu_rtu_disp2_vld;
  logic [ 31:0] idu_rtu_disp2_pc;
  logic [ 24:0] idu_rtu_disp2_chk;
  logic [  4:0] idu_rtu_disp2_dst_lreg;
  logic         idu_rtu_disp2_rf_we;
  logic [  6:0] idu_rtu_disp2_dst_preg;
  logic [  6:0] idu_rtu_disp2_old_preg;
  logic [  6:0] idu_rtu_disp2_src1_preg;
  logic [ 11:0] idu_rtu_disp2_csr_addr;
  logic [  2:0] idu_rtu_disp2_csr_op;
  logic [  4:0] idu_rtu_disp2_csr_imm;
  logic [  6:0] idu_rtu_disp2_flags;

  // ---------------------------------------------------------------------------
  // RTU ↔ IDU: 物理寄存器堆 / CSR 结果写回 —— 不过适配层, 直连
  //
  // 适配层注释写明"不做 CSR / PRF / BEU 的接线", 所以这几根在顶层 1:1 接。
  // ⚠️ RTU 侧一律 7 位(两档共用一份 §6 契约), IDU 的 PRF 是 6 位。PREG=64 档下
  //    RTU 编号的最高位恒 0 ⇒ **端口处的隐式截位正好丢掉那个 0**, 这是有意的;
  //    `rtu-subsys-elab` 专门把"PCWM-W 恰好 5 条且都在这一路"当作通过判据。
  //    96 档下这个巧合不成立(会静默写到错的物理寄存器) —— 适配层里有 generate
  //    守卫拦住 96 档, 见 `RTU_idu_lsu_adapter.v` 末尾。
  // ---------------------------------------------------------------------------
  logic [`RTU_PREG_W-1:0] rtu_preg_raddr0;
  logic [`RTU_PREG_W-1:0] rtu_preg_raddr1;
  logic [`RTU_PREG_W-1:0] rtu_preg_raddr2;
  logic [`RTU_PREG_W-1:0] rtu_csr_src_raddr;
  logic         rtu_csr_rd_we;
  logic [`RTU_PREG_W-1:0] rtu_csr_rd_addr;
  logic [ 31:0] rtu_csr_rd_wdata;
  // ⚠️ RTU 侧的口叫 `preg_rdata*`, IDU 侧叫 `rtu_preg_rdata*` —— **两侧名字不一样**
  //    (CSR 源那根倒是同名)。这里用 IDU 的名字当网名, RTU 那边接时跨过去。
  //    2026-10-12 起这两组**不再是同一根网**: IDU 出来的是 `*_raw*`(PRF 组合读),
  //    经下面的写口旁路后才成为 RTU 看到的 `rtu_preg_rdata*`。
  logic [ 31:0] idu_rtu_preg_rdata_raw0;
  logic [ 31:0] idu_rtu_preg_rdata_raw1;
  logic [ 31:0] idu_rtu_preg_rdata_raw2;
  logic [ 31:0] idu_rtu_csr_src_rdata_raw;
  logic [ 31:0] rtu_preg_rdata0;
  logic [ 31:0] rtu_preg_rdata1;
  logic [ 31:0] rtu_preg_rdata2;
  logic [ 31:0] rtu_csr_src_rdata;



  // ---------------------------------------------------------------------------
  // RTU ↔ LSU: 经适配层 (完成口 5/6 / store 重放 / 访存异常)
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // 【2026-10-15】冲刷闸: "LSU 里已退休的访存都拿到数据了吗"。
  //   C910 `ct_lsu_top.v` 的同名口 = `&sq_entry_cmit_data_vld && &rb_entry_cmit_data_vld`。
  //   0 ⇒ RTU 的冲刷状态机先进 WAIT 态等它, **不发后端冲刷** —— 否则一笔"已退休、
  //   但 store data 还在路上"的 store, 它数据的唯一来源 (IDU 的 SDIQ 表项) 会被冲掉,
  //   而 SQ 表项因为已 cmit 不会被冲掉 ⇒ 永不 pop; 在 LD_DA 因它被 discard 的 load
  //   会登记进它的 wakeup_queue 等 `data_set` ⇒ 永不唤醒 ⇒ ROB 队头不完 ⇒ 死锁。
  //   来龙去脉见 mySoC/rtu/rtl/RTU_flush.v 的 FSM 长注。
  // ---------------------------------------------------------------------------
  logic         lsu_rtu_all_commit_data_vld;
  logic         lsu_rtu_wb_pipe3_cmplt;
  logic [  6:0] lsu_rtu_wb_pipe3_iid;
  logic         lsu_rtu_wb_pipe3_expt_vld;
  logic [ 31:0] lsu_rtu_wb_pipe3_expt_addr;
  logic         lsu_rtu_wb_pipe4_cmplt;
  logic [  6:0] lsu_rtu_wb_pipe4_iid;
  logic         lsu_rtu_wb_pipe4_expt_vld;
  logic [ 31:0] lsu_rtu_wb_pipe4_expt_addr;
  logic         lsu_rtu_wb_pipe4_flush;
  logic         lsu_rtu_wb_pipe4_spec_fail;
  // 这两根**不接 RTU**(按 doc/rtu_接口对照表.csv 归"暂无对应"), 只做观察口。
  // 声明它们是为了: 悬空成隐式线网时会被当成 1 位, 而它们是 64 位/1 位。
  logic [ 63:0] lsu_rtu_wb_pipe3_wb_preg_expand;
  logic         lsu_rtu_wb_pipe3_wb_preg_vld;

  // ---------------------------------------------------------------------------
  // RTU ↔ IDU/LSU: 适配层 RTU 侧的其余端口
  // ---------------------------------------------------------------------------
  logic [  2:0] ren_preg_req;
  logic [`RTU_PREG_W-1:0] rtu_preg_alloc0;
  logic [`RTU_PREG_W-1:0] rtu_preg_alloc1;
  logic [`RTU_PREG_W-1:0] rtu_preg_alloc2;
  logic         rtu_preg_alloc_vld0;
  logic         rtu_preg_alloc_vld1;
  logic         rtu_preg_alloc_vld2;
  logic [  1:0] rtu_preg_free_cnt;

  logic         disp0_vld;
  logic [ 31:0] disp0_pc;
  logic [ 24:0] disp0_chk;
  logic [  4:0] disp0_dst_lreg;
  logic         disp0_rf_we;
  logic [`RTU_PREG_W-1:0] disp0_dst_preg;
  logic [`RTU_PREG_W-1:0] disp0_old_preg;
  logic [`RTU_PREG_W-1:0] disp0_src1_preg;
  logic [ 11:0] disp0_csr_addr;
  logic [  2:0] disp0_csr_op;
  logic [  4:0] disp0_csr_imm;
  logic [  6:0] disp0_flags;
  logic [  2:0] disp0_sq_id;

  logic         disp1_vld;
  logic [ 31:0] disp1_pc;
  logic [ 24:0] disp1_chk;
  logic [  4:0] disp1_dst_lreg;
  logic         disp1_rf_we;
  logic [`RTU_PREG_W-1:0] disp1_dst_preg;
  logic [`RTU_PREG_W-1:0] disp1_old_preg;
  logic [`RTU_PREG_W-1:0] disp1_src1_preg;
  logic [ 11:0] disp1_csr_addr;
  logic [  2:0] disp1_csr_op;
  logic [  4:0] disp1_csr_imm;
  logic [  6:0] disp1_flags;
  logic [  2:0] disp1_sq_id;

  logic         disp2_vld;
  logic [ 31:0] disp2_pc;
  logic [ 24:0] disp2_chk;
  logic [  4:0] disp2_dst_lreg;
  logic         disp2_rf_we;
  logic [`RTU_PREG_W-1:0] disp2_dst_preg;
  logic [`RTU_PREG_W-1:0] disp2_old_preg;
  logic [`RTU_PREG_W-1:0] disp2_src1_preg;
  logic [ 11:0] disp2_csr_addr;
  logic [  2:0] disp2_csr_op;
  logic [  4:0] disp2_csr_imm;
  logic [  6:0] disp2_flags;
  logic [  2:0] disp2_sq_id;

  logic         cmplt_vld5;
  logic [  6:0] cmplt_iid5;
  logic         cmplt_vld6;
  logic [  6:0] cmplt_iid6;

  logic         lsu_replay_vld;
  logic [  6:0] lsu_replay_iid;

  // RTU 的异常口是**三路平行**的 (2026-10-10 由 1 路扩到 3 路, 与 C910 同构)。
  // 三源锦标赛在 RTU_expt 内部做, 不在这条线上 —— 上游先合成一路的话, 同拍
  // 冲突会永久丢异常 (理由见 RTU.v §6.1 的长注)。
  logic         expt_iu_vld;
  logic [  6:0] expt_iu_iid;
  logic [  4:0] expt_iu_cause;
  logic [ 31:0] expt_iu_tval;
  logic         expt_ld_vld;
  logic [  6:0] expt_ld_iid;
  logic [  4:0] expt_ld_cause;
  logic [ 31:0] expt_ld_tval;
  logic         expt_st_vld;
  logic [  6:0] expt_st_iid;
  logic [  4:0] expt_st_cause;
  logic [ 31:0] expt_st_tval;

  logic         sq_rdy0;
  logic         sq_rdy1;
  logic         sq_rdy2;
  logic         sq_stall;
  logic [ 63:0] preg_dealloc_mask;

  logic         rtu_disp_stall;
  logic         rtu_ren_flush;
  logic         rtu_backend_flush;
  logic [32*`RTU_PREG_W-1:0] rtu_ren_recover_map;   // 宽度随 PREG 档变, 见 RTU.v 端口注
  logic [  6:0] rtu_disp_iid0;
  logic [  6:0] rtu_disp_iid1;
  logic [  6:0] rtu_disp_iid2;

  // ---------------------------------------------------------------------------
  // RTU ↔ LSU: 直连 (提交窗口广播 + 异步冲刷)
  // `rtu_yy_xx_flush` 不在这一组 —— 它走适配层合并后的那根, 与 IDU 同源。
  // ---------------------------------------------------------------------------
  logic         rtu_yy_xx_commit0;
  logic [  6:0] rtu_yy_xx_commit0_iid;
  logic         rtu_yy_xx_commit1;
  logic [  6:0] rtu_yy_xx_commit1_iid;
  logic         rtu_yy_xx_commit2;
  logic [  6:0] rtu_yy_xx_commit2_iid;
  logic         rtu_lsu_async_flush;
  logic         rtu_flush_busy;   // RTU: 冲刷状态机非 IDLE

  // ---------------------------------------------------------------------------
  // RTU → IFU: 陷阱/mret 重定向 + 退休点重训练
  // ⚠️ 这两组必须**两头都接**: 只接消费侧(IFU)不接生产侧(RTU), 线就是悬空 Z,
  //    `Z & is_cond` = X ⇒ 训练一次都不会发生, 而症状只体现在跑分上(difftest 全绿、
  //    编译只报 IWNF/PCWM 警告)。本仓 2026-10-02 真踩过。
  // ---------------------------------------------------------------------------
  logic         rtu_ifu_flush;
  logic         rtu_ifu_chgflw_vld;
  logic [ 31:0] rtu_ifu_chgflw_pc;
  logic         rtu_ifu_train_vld;
  logic [ 31:0] rtu_ifu_train_pc;
  logic [ 31:0] rtu_ifu_train_target;
  logic [ 24:0] rtu_ifu_train_chk;
  logic         rtu_ifu_train_taken;
  logic         rtu_ifu_train_is_cond;
  logic         rtu_ifu_train_is_jal;
  logic         rtu_ifu_train_is_jalr;

  // ---------------------------------------------------------------------------
  // IFU ↔ BIU: 中间过 `ifu_biu_axi` 协议桥
  //
  // IFU 那侧是 req/grnt (`biu_rd_*`), `ct_biu_top` 那侧是 AXI4 (`ifu_biu_ar*` /
  // `biu_ifu_r*`), 两者不能直连 —— 桥的端口两侧分别沿用对方的名字, 所以顶层这三段
  // 全是同名对接。
  // ⚠️ `biu_r_ready`(IFU 侧) 与 `ifu_biu_rready`(BIU 侧) 只差一个下划线, 是**两根
  //    不同的线**: 前者是 IFU 告诉桥"我这一拍能收", 后者是桥告诉 BIU"我这一拍能收"。
  // ---------------------------------------------------------------------------
  logic         biu_rd_req;
  logic [ 31:0] biu_rd_addr;
  logic         biu_rd_id;
  logic [  1:0] biu_rd_len;
  logic         biu_rd_grnt;
  logic         biu_rd_data_vld;
  logic [127:0] biu_rd_data;
  logic         biu_rd_rid;
  logic         biu_rd_last;
  logic [  1:0] biu_rd_resp;
  logic         biu_r_ready;

  logic [ 31:0] ifu_biu_araddr;
  logic [  1:0] ifu_biu_arlen;
  logic [  2:0] ifu_biu_arsize;
  logic [  1:0] ifu_biu_arburst;
  logic [  3:0] ifu_biu_arcache;
  logic [  2:0] ifu_biu_arprot;
  logic         ifu_biu_arvalid;
  logic         ifu_biu_arready;
  logic [  3:0] ifu_biu_rid;
  logic [127:0] biu_ifu_rdata;
  logic         biu_ifu_rvalid;
  logic         biu_ifu_rlast;
  logic [  1:0] biu_ifu_rresp;
  logic         biu_ifu_rid;
  logic         ifu_biu_rready;

  // ---------------------------------------------------------------------------
  // RTU / IFU 的观察口
  //
  // 这些口**当前没有对端**: 要么是等执行单元/BEU/CSR 例化进来, 要么是只给波形与
  // difftest 看。逐条的去向见文件末尾的"待接清单"。
  // 这里显式声明而不是留空 `()`: 留空时 VCS 只给一条 PCWM 警告就过去了, 而**读
  // 代码的人看不出这是"有意"还是"漏了"** —— 两者的代价不对称。
  // ---------------------------------------------------------------------------
  logic         cmplt_vld0;        // 待接: ALU0
  logic [  6:0] cmplt_iid0;
  logic         cmplt_vld1;        // 待接: ALU1
  logic [  6:0] cmplt_iid1;
  logic         cmplt_vld2;        // 待接: ALU2
  logic [  6:0] cmplt_iid2;
  logic         cmplt_vld3;        // 待接: BEU
  logic [  6:0] cmplt_iid3;
  logic         cmplt_vld4;        // 待接: MUL/DIV
  logic [  6:0] cmplt_iid4;
  logic         resolve_vld;       // 待接: BEU (解析口只有 1 路 = 分支单元数)
  logic [  6:0] resolve_iid;
  logic         resolve_taken;
  logic         resolve_mispred;
  logic [ 31:0] resolve_target;
  logic         beu_redirect_vld;  // 待接: BEU
  // IU 侧的异常源 (BEU 取指非对齐 / IDU 非法指令) —— 待接, 见末尾清单 A,
  // 它对应 RTU 的 expt_iu_* 那一路。
  logic         other_expt_vld;
  logic [  6:0] other_expt_iid;
  logic [  4:0] other_expt_cause;
  logic [ 31:0] other_expt_tval;
  logic [ 31:0] csr_rdata;         // 待接: CSR 文件
  logic         int_pending;       // 待接: CSR 文件
  logic [ 31:0] csr_trap_vector;   // 待接: CSR 文件
  logic [ 31:0] csr_mepc;          // 待接: CSR 文件
  logic [ 31:0] iu_chgflw_pc;      // 待接: BEU → IFU
  logic         iu_chgflw_vld;     // 待接: BEU → IFU
  logic [ 24:0] iu_btb_chk;        // 待接: BEU → IFU
  logic [ 31:0] iu_btb_pc;         // 待接: BEU → IFU3 (PHR hash 精确重算)
  logic         iu_btb_taken;      // 待接: BEU → IFU
  logic         iu_btb_is_cond;    // 待接: BEU → IFU

  logic         rtu_core_redirect;      // 观察口 (核内重定向事件, T 拍)
  logic         rtu_ren_recover_vld;    // 观察口 (与 _map 同拍)
  logic [`RTU_PREG_W-1:0] rtu_ren_free_preg0;     // 观察口 (自由池在 RTU 侧, 不需要外部回收)
  logic [`RTU_PREG_W-1:0] rtu_ren_free_preg1;
  logic [`RTU_PREG_W-1:0] rtu_ren_free_preg2;
  logic         rtu_ren_free_vld0;
  logic         rtu_ren_free_vld1;
  logic         rtu_ren_free_vld2;
  logic [  6:0] rtu_beu_retire_iid;      // 待接: BEU (已经不再是门控用的)
  logic         rtu_beu_flush_chgflw_mask; // 待接: BEU
  logic         ifu_init_done;          // 观察口

  // ---- 提交点副作用: 待接 CSR 文件 ----
  logic         rtu_csr_we;
  logic [ 11:0] rtu_csr_addr;
  logic [ 31:0] rtu_csr_wdata;
  logic         rtu_trap_vld;
  logic         rtu_mret_vld;
  logic [ 31:0] rtu_trap_epc;
  logic [ 31:0] rtu_trap_tval;
  logic [  4:0] rtu_trap_cause;
  logic [  1:0] rtu_retire_cnt;
  // ---- store 提交口: 待接 LSU (LSU 现在按 iid 广播找表项, 不需要槽号) ----
  logic         rtu_store_vld0;
  logic         rtu_store_vld1;
  logic         rtu_store_vld2;
  logic [  2:0] rtu_store_sq_id0;
  logic [  2:0] rtu_store_sq_id1;
  logic [  2:0] rtu_store_sq_id2;
  // ---- difftest ----
  logic         dbg_commit_vld0;
  logic         dbg_commit_vld1;
  logic         dbg_commit_vld2;
  logic [ 31:0] dbg_commit_pc0;
  logic [ 31:0] dbg_commit_pc1;
  logic [ 31:0] dbg_commit_pc2;
  // (RTU 原始 ena 现走 `rtu_cmt_ena[2:0]`, 见下面延迟线一节; "写 x0" 在这里摘)
  logic         dbg_commit_ena0;
  logic         dbg_commit_ena1;
  logic         dbg_commit_ena2;
  logic [  4:0] dbg_commit_reg0;
  logic [  4:0] dbg_commit_reg1;
  logic [  4:0] dbg_commit_reg2;
  logic [ 31:0] dbg_commit_value0;
  logic [ 31:0] dbg_commit_value1;
  logic [ 31:0] dbg_commit_value2;

  // ===========================================================================
  //  【difftest 观察口】LSU load "退休早于写回" 的补偿 (2026-10-13)
  //  ---------------------------------------------------------------------------
  //  【现象】lb 用例: 第 4 条退休 (pc=0xc `lb x14,0(x1)`) 报 x14=0, 参考模型要
  //    0xffffffff (地址 0x2000 处的字节是 0xff)。
  //
  //  【为什么】`lsu_rtu_wb_pipe3_cmplt` 只表示 **LSU 流水线走完了**这条, 不表示
  //    数据已经进寄存器堆 —— dcache miss 的 load 在 ld_da 就报完成(cmplt), 真去
  //    取数是把它交给 RB(MSHR) 走 BIU, linefill 回来才写 RF。波形实测 (lb):
  //        T975  ld_da: wb_cmplt_req=1 但 wb_data_req=0 (miss, 没数据), rb_create=1
  //        T985  lsu_rtu_wb_pipe3_cmplt=1 ⇒ ROB 把这条标成完成
  //        T995  RTU 交付退休包 pc=0xc reg=14 value=00000000 ← 观察口就在这拍读 PRF
  //        T1005 RB 才写回 (rb_ld_wb_data=0x000000ff, _wb_preg_vld=1)
  //        T1015 RF 落 0xffffffff
  //    偏差拍数 = 内存延迟, **不是常数** ⇒ 没法"提前算出来", 只能把观察口推迟到
  //    数据落地之后再交付, 或在窗口内用 LSU 写回口的数据顶替。
  //
  //  【做法】只动观察口, IDU / RTU / LSU 一行不动:
  //    1) RTU 那 15 根 `dbg_commit_*` 不再直接对外, 先进一条 **DBG_HOLD 拍延迟线**;
  //    2) 同时把 LSU 写回口 (`lsu_idu_wb_pipe3_wb_preg_expand` 独热 + `_data`) 的
  //       **每拍事件**也移进同深度的窗口;
  //    3) 延迟线出口那一拍: 若窗口里有一拍 LSU 写回了这条退休包的**目的 preg**
  //       (取 `rtu_preg_raddr*`; preg 唯一 ⇒ 至多命中一条), 就用 LSU 的数据 ——
  //       那是终值; 否则用进线时抓到的 `preg_rdata*` (已含 `§PRF 读口旁路`的同拍写口旁路)。
  //
  //  ⚠️ 覆盖范围 = "内存延迟 ≤ DBG_HOLD 拍"。本台 (tb 的 AXI 从机) 只差 1~2 拍,
  //     16 拍余量足够; 哪天真跑慢内存对不上, 先看这里再加大 DBG_HOLD。
  //  ⚠️ 只改**观察**口径: 退休的时刻/顺序/条数一律不变, 整个流平移 DBG_HOLD 拍。
  //     difftest 与冒烟台都只听程序序, 平移无害。
  //  ⚠️ 复位用 `rst` (高有效) —— 与 RTU/LSU 同极性, 这里只是观察口, 不复核核内复位相位。
  // ===========================================================================
  localparam int DBG_HOLD = 16;

  // RTU 侧原始退休包 (改名, 不再直接对外)
  logic [2:0]       rtu_cmt_vld;
  logic [2:0]       rtu_cmt_ena;
  logic [2:0][31:0] rtu_cmt_pc;
  logic [2:0][4:0]  rtu_cmt_reg;
  logic [2:0][31:0] rtu_cmt_val;
  logic [2:0][5:0]  rtu_cmt_preg;
  logic [2:0][6:0]  rtu_cmt_iid;      // 退休包自己的 iid (与 LSU 写回按 iid 配对)

  // 延迟线 (每槽一条) + LSU 写回事件窗口
  logic [DBG_HOLD-1:0]       h_vld  [0:2];
  logic [DBG_HOLD-1:0]       h_ena  [0:2];
  logic [DBG_HOLD-1:0][31:0] h_pc   [0:2];
  logic [DBG_HOLD-1:0][4:0]  h_reg  [0:2];
  logic [DBG_HOLD-1:0][5:0]  h_preg [0:2];
  logic [DBG_HOLD-1:0][6:0]  h_iid  [0:2];
  logic [DBG_HOLD-1:0][31:0] h_val  [0:2];
  logic [DBG_HOLD-1:0]       w_vld;
  logic [DBG_HOLD-1:0][63:0] w_hot;
  logic [DBG_HOLD-1:0][31:0] w_dat;
  logic [DBG_HOLD-1:0][6:0]  w_iid;
  logic [31:0]               dbg_val_out [0:2];

  // ⚠️ LSU 写回口这三根**必须同拍**才能配对 (拿 vld 当闸门, 用同拍的 expand/data
  //    去找"这条退休包的 preg 被写过没有")。`lsu_ld_wb.sv` 现在把 `_vld` 做成
  //    **寄存**的 (`= ld_wb_data_vld`), 与 `ld_wb_data_preg_expand` /
  //    `ld_wb_preg_data_sign_extend` 同一拍出 ⇒ 直接取用即可。
  //    若哪天 `_vld` 被改回组合的 (`ld_wb_pre_preg_wb_vld`, 比另两根早一拍),
  //    这里要跟着补一拍对齐, 否则配对的 hot/data 会整体错一拍 (取到上一次写回的号)。
  wire        lsu_evt = lsu_idu_wb_pipe3_wb_preg_vld;
  wire [63:0] lsu_hot = lsu_idu_wb_pipe3_wb_preg_expand;
  wire [31:0] lsu_dat = lsu_idu_wb_pipe3_wb_preg_data;
  wire [ 6:0] lsu_iid = lsu_idu_wb_pipe3_wb_preg_iid;

  assign rtu_cmt_preg[0] = rtu_preg_raddr0[5:0];
  assign rtu_cmt_preg[1] = rtu_preg_raddr1[5:0];
  assign rtu_cmt_preg[2] = rtu_preg_raddr2[5:0];

  // 退休包自己的 iid (与上面三个槽一一对应) —— 旁路窗口现在按 **iid** 配对。
  // ⚠️ 用 RTU 的 `dbg_commit_iid*` (**与 dbg_commit_* 同拍**, 取自 ROB 影子窗口头部),
  //    **不能**用 `rtu_yy_xx_commit*_iid` —— 那个是寄存一拍的提交广播, 比 dbg_commit_*
  //    晚一拍, 会把上一包的 iid 存进延迟线 (实测 lh: pc=0x24 存到了 iid=6)。
  //    (连接在下面 RTU 实例的 `.dbg_commit_iid*` 上)

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      for (int i = 0; i < 3; i = i + 1) begin
        h_vld [i] <= '0;
        h_ena [i] <= '0;
        h_pc  [i] <= '0;
        h_reg [i] <= '0;
        h_preg[i] <= '0;
        h_iid [i] <= '0;
        h_val [i] <= '0;
      end
      w_vld <= '0;
      w_hot <= '0;
      w_dat <= '0;
      w_iid <= '0;
    end
    else begin
      for (int i = 0; i < 3; i = i + 1) begin
        h_vld [i] <= {h_vld [i][DBG_HOLD-2:0], rtu_cmt_vld [i]};
        h_ena [i] <= {h_ena [i][DBG_HOLD-2:0], rtu_cmt_ena [i]};
        h_pc  [i] <= {h_pc  [i][DBG_HOLD-2:0], rtu_cmt_pc  [i]};
        h_reg [i] <= {h_reg [i][DBG_HOLD-2:0], rtu_cmt_reg [i]};
        h_preg[i] <= {h_preg[i][DBG_HOLD-2:0], rtu_cmt_preg[i]};
        h_iid [i] <= {h_iid [i][DBG_HOLD-2:0], rtu_cmt_iid [i]};
        h_val [i] <= {h_val [i][DBG_HOLD-2:0], rtu_cmt_val [i]};
      end
      w_vld <= {w_vld[DBG_HOLD-2:0], lsu_evt};
      w_hot <= {w_hot[DBG_HOLD-2:0], lsu_hot};
      w_dat <= {w_dat[DBG_HOLD-2:0], lsu_dat};
      w_iid <= {w_iid[DBG_HOLD-2:0], lsu_iid};
    end
  end

  // 出口 = 延迟线里**最老**那一格。⚠️ 触发器是往高位挪的 (`{h[N-2:0],new}`),
  // 所以 index0 = 上一拍的输入 (只延 1 拍), index(DBG_HOLD-1) 才是延迟 DBG_HOLD 拍。
  localparam int DBG_OUT = DBG_HOLD - 1;

  // 出口: 窗口里有一拍 LSU 写回了**这条退休包自己的目的 preg** ⇒ 用 LSU 的终值顶替
  // (`j==0` 那支看**当拍**)
  //
  // ⚠️ 2026-10-13 修: 配对从"只比 preg"改成 **"比 preg + 比 iid"**。
  //    只比 preg 不安全 —— preg 会被**回收**: 16 拍窗口内同一 preg 完全可能被
  //    两条不同指令写 (前一条退休后释放, 后一条重新分配)。实测 (lb, cache 修好
  //    后): `lui x1` (retire #14, dst_preg=1) 的值被窗口里另一条 load (iid=33,
  //    也写 preg 1) 的数据顶成了 0 —— 核里 x1 明明是 0x2000。
  //    加上 iid 比较后, 只有"这条包自己的数据写回"才会顶替。
  always_comb begin
    for (int i = 0; i < 3; i = i + 1) begin
      dbg_val_out[i] = h_val[i][DBG_OUT];
      for (int j = 0; j < DBG_HOLD; j = j + 1) begin
        if ((j == 0) ? (lsu_evt && (lsu_iid == h_iid[i][DBG_OUT])
                                 && lsu_hot[h_preg[i][DBG_OUT]])
                     : (w_vld[j] && (w_iid[j] == h_iid[i][DBG_OUT])
                                 && w_hot[j][h_preg[i][DBG_OUT]]))
          dbg_val_out[i] = (j == 0) ? lsu_dat : w_dat[j];
      end
    end
  end

  assign dbg_commit_vld0    = h_vld[0][DBG_OUT];
  assign dbg_commit_vld1    = h_vld[1][DBG_OUT];
  assign dbg_commit_vld2    = h_vld[2][DBG_OUT];
  assign dbg_commit_pc0     = h_pc[0][DBG_OUT];
  assign dbg_commit_pc1     = h_pc[1][DBG_OUT];
  assign dbg_commit_pc2     = h_pc[2][DBG_OUT];
  assign dbg_commit_reg0    = h_reg[0][DBG_OUT];
  assign dbg_commit_reg1    = h_reg[1][DBG_OUT];
  assign dbg_commit_reg2    = h_reg[2][DBG_OUT];
  assign dbg_commit_value0  = dbg_val_out[0];
  assign dbg_commit_value1  = dbg_val_out[1];
  assign dbg_commit_value2  = dbg_val_out[2];

  // ---------------------------------------------------------------------------
  //  `ena` 要把"写 x0"摘掉 (2026-10-12)
  //
  //  RTU 的 `commit_ena = commit_vld & rf_we & ~trap_hit` —— 它只看"这条指令带不带
  //  写口", 不看写的是不是 x0。而 difftest 的黄金模型是按**架构是否改变**报 ena 的:
  //   `jal x0, 4` 在模型里 ena=0, 在 RTU 这里 ena=1 (reg=0) ⇒ 第一条指令就报失配。
  //
  //  顺序核早就这么处理了: `mycpu.v:1572`
  //      assign debug_wb_ena = rtu_commit_ena0 & (rtu_commit_reg0 != 5'd0);
  //  **摘在核顶层、不摘在 RTU 里** —— 这里照抄同一口径, 让两个核的 difftest 观察口
  //  逐位同义 (同一个 `dpi_shim.c` 才能同时喂两个核)。
  // ---------------------------------------------------------------------------
  // ⚠️ 2026-10-13: `ena`/`reg` 现在都取自上面那条延迟线的出口 (跟 pc/value 同步),
  //    否则"写 x0 摘掉"会拿错拍。
  assign dbg_commit_ena0 = h_ena[0][DBG_OUT] & (h_reg[0][DBG_OUT] != 5'd0);
  assign dbg_commit_ena1 = h_ena[1][DBG_OUT] & (h_reg[1][DBG_OUT] != 5'd0);
  assign dbg_commit_ena2 = h_ena[2][DBG_OUT] & (h_reg[2][DBG_OUT] != 5'd0);

  // ---- 待接 IDU 的执行单元侧 (这些线在 IDU 上是输入, 归执行单元驱动) ----
  // 执行单元写回 IDU 的端口分配 (2026-10-11):
  //   - pipe0 → ALU
  //   - pipe1 → BEU
  //   - pipe2 → MUL/DIV
  logic [  5:0] iu_idu_ex2_pipe0_wb_preg_dupx;
  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx;
  logic [ 31:0] iu_idu_ex2_pipe0_wb_preg_data;
  logic [ 63:0] iu_idu_ex2_pipe0_wb_preg_expand;
  logic         iu_idu_ex2_pipe0_wb_preg_vld;
  logic [  5:0] iu_idu_ex2_pipe1_wb_preg_dupx;
  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx;
  logic [ 31:0] iu_idu_ex2_pipe1_wb_preg_data;
  logic [ 63:0] iu_idu_ex2_pipe1_wb_preg_expand;
  logic         iu_idu_ex2_pipe1_wb_preg_vld;
  logic [  5:0] iu_idu_ex2_pipe2_wb_preg_dupx;
  logic         iu_idu_ex2_pipe2_wb_preg_vld_dupx;
  logic [ 31:0] iu_idu_ex2_pipe2_wb_preg_data;
  logic [ 63:0] iu_idu_ex2_pipe2_wb_preg_expand;
  logic         iu_idu_ex2_pipe2_wb_preg_vld;
  logic         md_unit_stall;

  // ---- 待接 IDU 的执行单元发射口 (IDU 输出) ----
  logic         idu_aiq_sel;
  logic [  6:0] idu_aiq_iid;
  logic         idu_aiq_illegal;
  logic [ 31:0] idu_aiq_pc;
  logic [  5:0] idu_aiq_dst_preg;
  logic [ 31:0] idu_aiq_src0;
  logic [ 31:0] idu_aiq_src1;
  logic [ 12:0] idu_aiq_rslt_sel;

  // ---- ALU1 发射口 (2026-10-18) ----
  logic         idu_aiq1_sel;
  logic [  6:0] idu_aiq1_iid;
  logic         idu_aiq1_illegal;
  logic [ 31:0] idu_aiq1_pc;
  logic [  5:0] idu_aiq1_dst_preg;
  logic [ 31:0] idu_aiq1_src0;
  logic [ 31:0] idu_aiq1_src1;
  logic [ 12:0] idu_aiq1_rslt_sel;
  logic         aiq1_issue_stall;      // ALU1 写回保持 -> IDU (AIQ1 发射门)

  // ---- ALU1 / MD 共用 pipe2 的中间线 (2026-10-18) ----
  logic         alu1_wb_req, md_wb_req;
  logic         alu1_wb_grant, md_wb_grant;
  logic         alu1_wb_vld, alu1_wb_vld_dupx;
  // ALU1 完成口先接独立网, 再显式赋给 RTU 的完成口 1 (排查端口连接用)
  logic         alu1_cmplt_vld;
  logic [  6:0] alu1_cmplt_iid;
  logic [ 31:0] alu1_wb_data;
  logic [ 63:0] alu1_wb_expand;
  logic [  5:0] alu1_wb_dupx;
  logic         md_wb_vld, md_wb_vld_dupx;
  logic [ 31:0] md_wb_data;
  logic [ 63:0] md_wb_expand;
  logic [  5:0] md_wb_dupx;

  logic         idu_mult_sel;
  logic [  6:0] idu_mult_iid;
  logic [  5:0] idu_mult_dst_preg;
  logic [ 31:0] idu_mult_src0;
  logic [ 31:0] idu_mult_src1;
  logic [  3:0] idu_mult_rslt_sel;
  logic         idu_div_sel;
  logic [  6:0] idu_div_iid;
  logic         idu_div_dst_vld;
  logic [  5:0] idu_div_dst_preg;
  logic [ 31:0] idu_div_src0;
  logic [ 31:0] idu_div_src1;
  logic [  3:0] idu_div_rslt_sel;
  logic         idu_biq_sel;
  logic [  6:0] idu_biq_iid;
  logic [ 31:0] idu_biq_src0;
  logic [ 31:0] idu_biq_src1;
  logic [  7:0] idu_biq_rslt_sel;
  logic [ 31:0] idu_biq_br_imme;
  logic         idu_biq_dst_vld;
  logic [  5:0] idu_biq_dst_preg;
  logic         idu_biq_taken;
  logic [ 31:0] idu_biq_npc;
  logic [ 31:0] idu_biq_pc;
  logic [ 24:0] idu_biq_chk;
  // ============================================================
  // IFU
  // ============================================================
`ifdef USE_IFU3
  // FTQ + 3 级 IFU + 香山式 BTB/TAGE；Phase 2 起带 RAS/PredChecker。
  // iu_btb_* 由 BEU 在 EX 重定向当拍驱动，用于 PHR/RAS 精确恢复。
  rv32ifu3_top u_rv32ifu2_top (
    .clk                (clk),
    .rst                (rst),

    .idu_inst0_vld      (ifu_inst0_vld),
    .idu_inst0_data     (idu_inst0_data),
    .idu_inst0_chk      (idu_inst0_chk),
    .idu_inst1_vld      (ifu_inst1_vld),
    .idu_inst1_data     (idu_inst1_data),
    .idu_inst1_chk      (idu_inst1_chk),
    .idu_inst2_vld      (ifu_inst2_vld),
    .idu_inst2_data     (idu_inst2_data),
    .idu_inst2_chk      (idu_inst2_chk),
    .idu_flush          (ifu_idu_flush),
    .idu_accept_num     (ifu_accept_num),

    .iu_chgflw_vld      (iu_chgflw_vld),
    .iu_chgflw_pc       (iu_chgflw_pc),
    .rtu_flush          (rtu_ifu_flush),
    .rtu_chgflw_vld     (rtu_ifu_chgflw_vld),
    .rtu_chgflw_pc      (rtu_ifu_chgflw_pc),

    .rtu_train_vld      (rtu_ifu_train_vld),
    .rtu_train_pc       (rtu_ifu_train_pc),
    .rtu_train_target   (rtu_ifu_train_target),
    .rtu_train_chk      (rtu_ifu_train_chk),
    .rtu_train_taken    (rtu_ifu_train_taken),
    .rtu_train_is_cond  (rtu_ifu_train_is_cond),
    .rtu_train_is_jal   (rtu_ifu_train_is_jal),
    .rtu_train_is_jalr  (rtu_ifu_train_is_jalr),
    .iu_btb_chk         (iu_btb_chk),
    .iu_btb_pc          (iu_btb_pc),
    .iu_btb_taken       (iu_btb_taken),
    .iu_btb_is_cond     (iu_btb_is_cond),

    .init_done          (ifu_init_done),

    .biu_rd_req         (biu_rd_req),
    .biu_rd_addr        (biu_rd_addr),
    .biu_rd_id          (biu_rd_id),
    .biu_rd_len         (biu_rd_len),
    .biu_rd_grnt        (biu_rd_grnt),
    .biu_rd_data_vld    (biu_rd_data_vld),
    .biu_rd_data        (biu_rd_data),
    .biu_rd_rid         (biu_rd_rid),
    .biu_rd_last        (biu_rd_last),
    .biu_rd_resp        (biu_rd_resp),
    .biu_r_ready        (biu_r_ready)
  );
`else
  rv32ifu2_top u_rv32ifu2_top (
    .clk                (clk),
    .rst                (rst),

    // ---- IDU 交付 ----
    .idu_inst0_vld      (ifu_inst0_vld),
    .idu_inst0_data     (idu_inst0_data),
    .idu_inst0_chk      (idu_inst0_chk),
    .idu_inst1_vld      (ifu_inst1_vld),
    .idu_inst1_data     (idu_inst1_data),
    .idu_inst1_chk      (idu_inst1_chk),
    .idu_inst2_vld      (ifu_inst2_vld),
    .idu_inst2_data     (idu_inst2_data),
    .idu_inst2_chk      (idu_inst2_chk),
    .idu_flush          (ifu_idu_flush),      // 观察口, 见末尾待接清单
    .idu_accept_num     (ifu_accept_num),

    // ---- 后端重定向 ----
    // `iu_*` 那两根来自 BEU (EX 级误预测) —— 本文件还没例化执行单元, 见待接清单;
    // `rtu_*` 那三根来自 RTU (退休点的陷阱/中断/mret), 接死。
    .iu_chgflw_vld      (iu_chgflw_vld),
    .iu_chgflw_pc       (iu_chgflw_pc),
    .rtu_flush          (rtu_ifu_flush),
    .rtu_chgflw_vld     (rtu_ifu_chgflw_vld),
    .rtu_chgflw_pc      (rtu_ifu_chgflw_pc),

    // ---- 分支预测器训练 (退休点回送) ----
    .rtu_train_vld      (rtu_ifu_train_vld),
    .rtu_train_pc       (rtu_ifu_train_pc),
    .rtu_train_target   (rtu_ifu_train_target),
    .rtu_train_chk      (rtu_ifu_train_chk),
    .rtu_train_taken    (rtu_ifu_train_taken),
    .rtu_train_is_cond  (rtu_ifu_train_is_cond),
    .rtu_train_is_jal   (rtu_ifu_train_is_jal),
    .rtu_train_is_jalr  (rtu_ifu_train_is_jalr),

    // ⚠️ 这三根与上面那 8 根**不是一回事**, 别合并: 它们是"双身份"的 —— 除了 BTB
    //    训练, 还要在**重定向当拍**现算 `ghr_restore` 并打拍存 RAS 指针。误预测
    //    重定向发生在 **EX**, 所以必须是**当拍 EX** 的值; 换成退休点那份, GHR/RAS
    //    会被修到**另一条**指令的快照上 (症状: 一切看起来正常, 只是准确率缓慢变差)。
    //    ⇒ 归 BEU 驱动, 见待接清单。
    .iu_btb_chk         (iu_btb_chk),
    .iu_btb_taken       (iu_btb_taken),
    .iu_btb_is_cond     (iu_btb_is_cond),

    // ---- 状态 ----
    .init_done          (ifu_init_done),

    // ---- BIU 主端 (req/grnt) → 经 ifu_biu_axi 翻成 AXI4 给 ct_biu_top ----
    .biu_rd_req         (biu_rd_req),
    .biu_rd_addr        (biu_rd_addr),
    .biu_rd_id          (biu_rd_id),
    .biu_rd_len         (biu_rd_len),
    .biu_rd_grnt        (biu_rd_grnt),
    .biu_rd_data_vld    (biu_rd_data_vld),
    .biu_rd_data        (biu_rd_data),
    .biu_rd_rid         (biu_rd_rid),
    .biu_rd_last        (biu_rd_last),
    .biu_rd_resp        (biu_rd_resp),
    .biu_r_ready        (biu_r_ready)
  );
`endif

  // ---------------------------------------------------------------------------
  // IFU 交出的 128 位 → IDU 要的 97 位
  //
  // IDU 侧的布局 (`ct_idu_id_dp.sv` 的 `ID_TAKEN=96 / ID_NPC=95 / ID_PC=63 /
  // `ID_OPCODE=31`):
  //     [96]    taken  —— 取指时那条指令的**方向预测**
  //     [95:64] npc    —— 预测的后继 PC (只有 BIQ/分支那条路用得到, 见 `idu_biq_npc`)
  //     [63:32] pc
  //     [31:0]  inst
  // IFU 侧的 128 位 (`rv32ifu2_top`):
  //     [31:0] inst  [63:32] pc  [95:64] pred_npc  [96] fault  [100:97] cause
  //     [122]  direction-predicted-taken
  // ⇒ 低 96 位**逐位同名同义**, 直接把 IFU 的 [122] 搬到 bit96 即可。
  // (fault/cause 那几位 IDU 侧没有对应字段, 取指故障走的是另一条通路。)
  // ---------------------------------------------------------------------------
  assign ifu_idu_ib_inst0_data[96:0] = {idu_inst0_data[122], idu_inst0_data[95:0]};

  // ===========================================================================
  //  【误预测冻结窗】EX 级重定向 → RTU 冲刷脉冲之间, 一条都不交给 IDU
  //  (2026-10-12 立; 对应 C910 的 `iu_idu_mispred_stall` + `rtu_idu_flush_stall`)
  // ===========================================================================
  //  【症状 (lui 用例, +PROBE_IFU 实测)】PC=0x60 的 `bne` 跳到 0x7c:
  //      T116  iu_chgflw_vld=1 (EX 级重定向) → IFU 立刻重取
  //      T117  IFU 把目标那条 0x7c **当拍**交给 IDU (I-Cache 命中 + IBUF 空时旁路),
  //            IDU 的 inst0_vld=1, 收下
  //      T119  RTU 的冲刷脉冲 (`rtu_yy_xx_flush`) 才到 IDU ⇒ 把它连 ID 级一起清掉
  //      ⇒ **0x7c 凭空消失**, 退休流从 0x60 直接跳到 0x80。
  //
  //  【根因是相位, 不是谁接错了】"执行级早重定向"让 IFU 比冲刷**早 3 拍**就取回了
  //  正确的目标, 而 IDU 的冲刷是**一把大扫帚**(整条 ID/IR/IS 全清, 分不清
  //  "错路"和"重定向后重新取回的正确指令")。C910 里靠两件事错开:
  //    * `iu_idu_mispred_stall`(ct_iu_bju.v:799-819) —— "stall ID stage until all
  //      frontend and backend pipeline empty", 由 EX1 重定向置起、`rtu_yy_xx_flush` 清掉;
  //    * `rtu_idu_flush_stall`(ct_rtu_retire.v:1985) —— 冲刷状态机离开 IDLE 期间冻 IDU。
  //  **交付的 IDU 把这两个输入整个删掉了** (ct_idu_ir_ctrl.sv:276 只剩
  //  `ctrl_ir_stage_stall = ctrl_ir_preg_stall`), 于是这层保护在 A910 上不存在。
  //  再者 C910 的 IFU 是 3 级、重定向后要好几拍才交得出指令, 冲刷窗口天然错开;
  //  我们的 IFU2 命中 I-Cache 时**下一拍**就交 —— 这个竞态就必然踩中, 不是偶发。
  //
  //  【为什么在本层做】IDU 没有可用的 stall 输入口 (要加口就得动同事的模块);
  //  而"重定向窗内不交付"这件事, 在 IFU 与 IDU 之间的**接线层**就能表达干净:
  //  IFU 照常抢跑取指 (抢跑的好处一点没丢, 指令就停在 IBUF 里), 只是**闸门**
  //  关到冲刷到来为止。代价: 每次误预测多几拍 (冲刷会把 IBUF 一起清掉 ⇒ 目标那条
  //  要再取一次), 换来的是**指令不再丢**。
  //
  //  ⚠️ 清条件必须用 `rtu_yy_xx_flush` —— 与 IDU 自己看到的**同一根**信号。
  //     用 RTU 别的重定向口 (相位不同) 会出现"闸门一直在关"的死锁。
  //  ⚠️ 只关 `vld`, 不关 IBUF 的推入: 推入是 IFU 内部的事, 且闸门期间 IFU 已经被
  //     `rtu_flush` 清过一次, 重新取回的目标那条正等在这里。
  // ===========================================================================
  // ⚠️ 2026-10-12 改: 开闸条件从"冲刷**脉冲**那拍"延到"冲刷**状态机回 IDLE**"。
  //    为什么: 脉冲发完, 冲刷机器还要跑几拍收尾 (恢复架构映射表 AMT / 回滚 preg /
  //    重训练)。这几拍里若放新指令进来, 它会跟"表还没恢复完"打架 —— 这正是 C910
  //    用 `rtu_idu_flush_stall = !flush_cur_state[0]` 单独再冻一道的原因。
  //    而冲刷脉冲已经把 IDU 流水线清空了 ⇒ 只要闸门不放新指令进来, 那几拍 IDU
  //    本来也没东西可推进 ⇒ **从外面就完整复刻了 `rtu_idu_flush_stall` 的效果**,
  //    不需要 IDU 加口。
  //    ⚠️ 不能简单地写成"清于 ~rtu_flush_busy": 重定向刚发出时冲刷机器还没起来
  //       (busy=0), 那样会当拍就开闸。必须**先见到脉冲**再等机器跑完。
  reg mispred_hold_q;
  reg hold_pulse_seen_q;                 // 这一轮里冲刷脉冲来过了
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      mispred_hold_q    <= 1'b0;
      hold_pulse_seen_q <= 1'b0;
    end
    else if (iu_chgflw_vld) begin        // EX 重定向 ⇒ 关闸 (重新等一轮脉冲)
      mispred_hold_q    <= 1'b1;
      hold_pulse_seen_q <= 1'b0;
    end
    else if (mispred_hold_q & hold_pulse_seen_q & ~rtu_flush_busy) begin
      mispred_hold_q    <= 1'b0;         // 冲刷机器跑完 ⇒ 开闸
      hold_pulse_seen_q <= 1'b0;
    end
    else if (rtu_yy_xx_flush) begin      // 见到脉冲 (与 IDU 同一根信号)
      hold_pulse_seen_q <= 1'b1;
    end
  end

  // ===========================================================================
  //  【2026-10-14 补漏】闸门必须**连冲刷脉冲那一拍一起夹** —— `rtu_yy_xx_flush`
  // ===========================================================================
  //  `mispred_hold_q` 是**寄存器**, 只在 `iu_chgflw_vld` (BEU 的 EX 级重定向) 时
  //  置位; 而 RTU 那条重定向走的是**另一条时序**, 它罩不住:
  //
  //      T   : `rtu_ifu_chgflw_vld` + `rtu_ifu_flush` 同拍同值拉高 (RTU_flush.v:156-161)
  //            ⇒ IFU 当拍转向 (零气泡), 目标行当拍进阵列
  //      T+1 : `rtu_yy_xx_flush` 才到 (RTU_flush.v 的 F1) —— **后端的大扫帚比前端晚一拍**
  //            ⇒ IFU2 命中 I-Cache 时 T+1 正好把目标那条交出来 (空队列旁路)
  //            ⇒ "交货"与"被清"撞在同一拍:
  //               * ID 级寄存器 `else if(rtu_yy_xx_flush)` 优先级高于 pipedown
  //                 (ct_idu_id_ctrl.sv:77 / ct_idu_id_dp.sv:178) ⇒ 当拍交来那条被丢;
  //               * 而 `idu_accept_num` **不看 vld** (ct_idu_id_ctrl.sv:53-65)
  //                 ⇒ IBUF 当"已收下"弹掉 ⇒ **永久丢** (不是晚一拍)。
  //
  //  【实测 (2026-10-14, `+PROBE_RACE`, 全套 45 用例扫过)】
  //      sw : T185 src=4(REPLAY) 重定向 0x158 → T+1 交出的 0x158/0x15c 被弹掉
  //           ⇒ 退休流 0x154 → 0x160, 黄金模型指着 `0x158 = sw`  ⇒ FAIL
  //      sh : 同型 (T184 src=4 → 0x148)                            ⇒ FAIL
  //      其余 41 条: RTU 前端重定向 0 次 (没触发过)                ⇒ PASS
  //      ⇒ 两条 FAIL 与两条"撞车即丢"**一一对应**。
  //
  //  为什么"并进脉冲那拍"就够 (而不是也要提前置位):
  //    脉冲那拍 IDU 的 ID/IR/IS 全在被清 ⇒ 当拍交进去什么都会被丢, 所以那拍
  //    "不交付、也不许弹"是**普适安全**的 (指令老实待在 IBUF, 下一拍照常交)。
  //    RTU 那条的前端转向(T)与脉冲(T+1)紧邻 ⇒ 夹这一拍正好够, 代价 1 拍/次。
  //    误预测那条 (转向在 EX, 离脉冲好几拍) 照旧靠上面的寄存器闸门。
  //  ⚠️ 别写成"清于 ~rtu_flush_busy"或只夹自己的口: 判据必须是**IDU 自己看到的
  //     那根** `rtu_yy_xx_flush` (同源同拍), 否则相位又对不上。
  // ===========================================================================
  wire idu_hold;
  assign idu_hold = mispred_hold_q | rtu_yy_xx_flush;

  assign idu_inst0_vld = ifu_inst0_vld & ~idu_hold;
  assign idu_inst1_vld = ifu_inst1_vld & ~idu_hold;
  assign idu_inst2_vld = ifu_inst2_vld & ~idu_hold;

  // ⚠️ **只关 vld 是不够的, 必须连 `accept_num` 一起夹 0。**
  //    实测 (第一版就只关了 vld): 闸门期间 IBUF 里的 0x7c 还是**没了** ——
  //    因为 `idu_accept_num` 是 IDU 按**自己的停顿状态**算的, 它**不看**
  //    `ifu_idu_ib_inst*_vld` (这是已知的契约违例, 见文件末尾待接清单第 1 条)。
  //    ⇒ IBUF 照 IDU 报的条数把它弹走, 而 IDU 那边因为 vld 被我夹掉没收 ⇒
  //      **指令被弹进了黑洞**。夹住 accept_num, 指令就老实待在 IBUF 里等开闸。
  assign ifu_accept_num = idu_hold ? 2'd0 : idu_accept_num;
  // ⚠️ 车道 1 原来写的是 `idu_inst2_data[122]` —— 复制粘贴时漏改车道号。后果是
  //    **车道 1 的方向预测被车道 2 的顶掉**: 一拍交两条时, 车道 1 的 taken 取自
  //    车道 2 ⇒ 分支预测器的方向快照随指令走错一条, BIQ 拿它算 NPC 也会错。
  //    这种错在只看"总数对不对"的回归里不显形, 只在精度/周期数上体现。
  assign ifu_idu_ib_inst1_data[96:0] = {idu_inst1_data[122], idu_inst1_data[95:0]};
  assign ifu_idu_ib_inst2_data[96:0] = {idu_inst2_data[122], idu_inst2_data[95:0]};

  // ---------------------------------------------------------------------------
  //  IFU → BIU 协议桥
  // ---------------------------------------------------------------------------
  // IFU 那侧是 req/grnt (biu_rd_*), ct_biu_top 那侧是 AXI4 (ifu_biu_ar* /
  // biu_ifu_r*)。桥的两侧分别沿用对方的名字, 所以上下三段都是同名对接。
  // 时序约定 (grant 寄存一拍 / R 寄存一拍 / 完成判据用拍数) 见桥自己的文件头。
  ifu_biu_axi u_ifu_biu_axi (
    .clk            (clk),
    .rst            (rst),

    // ---- IFU 侧 (req/grnt) ----
    .biu_rd_req     (biu_rd_req),
    .biu_rd_addr    (biu_rd_addr),
    .biu_rd_id      (biu_rd_id),
    .biu_rd_len     (biu_rd_len),
    .biu_rd_grnt    (biu_rd_grnt),
    .biu_rd_data_vld(biu_rd_data_vld),
    .biu_rd_data    (biu_rd_data),
    .biu_rd_rid     (biu_rd_rid),
    .biu_rd_last    (biu_rd_last),
    .biu_rd_resp    (biu_rd_resp),
    .biu_r_ready    (biu_r_ready),

    // ---- BIU 侧 (AXI4) ----
    .ifu_biu_araddr (ifu_biu_araddr),
    .ifu_biu_arlen  (ifu_biu_arlen),
    .ifu_biu_arsize (ifu_biu_arsize),
    .ifu_biu_arburst(ifu_biu_arburst),
    .ifu_biu_arcache(ifu_biu_arcache),
    .ifu_biu_arprot (ifu_biu_arprot),
    .ifu_biu_arvalid(ifu_biu_arvalid),
    .ifu_biu_arready(ifu_biu_arready),
    .ifu_biu_rid    (ifu_biu_rid),
    .biu_ifu_rdata  (biu_ifu_rdata),
    .biu_ifu_rvalid (biu_ifu_rvalid),
    .biu_ifu_rlast  (biu_ifu_rlast),
    .biu_ifu_rresp  (biu_ifu_rresp),
    .biu_ifu_rid    (biu_ifu_rid),
    .ifu_biu_rready (ifu_biu_rready)
  );

  // ============================================================
  // IDU
  // ============================================================
  ct_idu_top u_ct_idu_top (
  //==========================================================
  // Global signals
  //==========================================================
  .forever_cpuclk                 (clk),
  .cpurst_b                       (rst_b),

  //==========================================================
  // Interface with IFU
  //==========================================================
  .ifu_idu_ib_inst0_vld           (idu_inst0_vld),
  .ifu_idu_ib_inst1_vld           (idu_inst1_vld),
  .ifu_idu_ib_inst2_vld           (idu_inst2_vld),
  .ifu_idu_ib_inst0_data          (ifu_idu_ib_inst0_data),
  .ifu_idu_if_inst0_chk           (idu_inst0_chk),
  .ifu_idu_ib_inst1_data          (ifu_idu_ib_inst1_data),
  .ifu_idu_if_inst1_chk           (idu_inst1_chk),
  .ifu_idu_ib_inst2_data          (ifu_idu_ib_inst2_data),
  .ifu_idu_if_inst2_chk           (idu_inst2_chk),
  .idu_accept_num                 (idu_accept_num),

  //==========================================================
  // Interface with RTU
  //
  // ⚠️ 这一整段**必须经 `RTU_idu_lsu_adapter`**, 不能直连 RTU 的同义端口:
  //    两侧名字不同, 而且适配层里有四类真变换 (7→6 位 preg / 恢复表 32×7→32×6
  //    逐槽重排 / 复位极性 / 三路请求→程序序前缀计数)。
  //==========================================================
  .rtu_idu_alloc_preg0_vld        (rtu_idu_alloc_preg0_vld),
  .rtu_idu_alloc_preg1_vld        (rtu_idu_alloc_preg1_vld),
  .rtu_idu_alloc_preg2_vld        (rtu_idu_alloc_preg2_vld),
  .rtu_idu_alloc_preg0            (rtu_idu_alloc_preg0),
  .rtu_idu_alloc_preg1            (rtu_idu_alloc_preg1),
  .rtu_idu_alloc_preg2            (rtu_idu_alloc_preg2),
  .rtu_idu_rob_inst0_iid          (rtu_idu_rob_inst0_iid),
  .rtu_idu_rob_inst1_iid          (rtu_idu_rob_inst1_iid),
  .rtu_idu_rob_inst2_iid          (rtu_idu_rob_inst2_iid),
  .rtu_idu_rob_full               (rtu_idu_rob_full),
  .rtu_idu_rt_recover_preg        (rtu_idu_rt_recover_preg),
  .rtu_yy_xx_flush                (rtu_yy_xx_flush),
  .idu_rtu_ir_preg0_alloc_vld     (idu_rtu_ir_preg0_alloc_vld),
  .idu_rtu_ir_preg1_alloc_vld     (idu_rtu_ir_preg1_alloc_vld),
  .idu_rtu_ir_preg2_alloc_vld     (idu_rtu_ir_preg2_alloc_vld),
  .idu_rtu_pst_preg_dealloc_mask  (idu_rtu_pst_preg_dealloc_mask),

  //==========================================================
  // Interface with IU - Writeback
  // ⚠️ 待接: 源是执行单元 wrapper (mySoC/iu/rtl/IU_alu_pipe.v), 本文件还没例化。
  //==========================================================
  .iu_idu_ex2_pipe0_wb_preg_dupx      (iu_idu_ex2_pipe0_wb_preg_dupx),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx  (iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe0_wb_preg_data      (iu_idu_ex2_pipe0_wb_preg_data),
  .iu_idu_ex2_pipe0_wb_preg_expand    (iu_idu_ex2_pipe0_wb_preg_expand),
  .iu_idu_ex2_pipe0_wb_preg_vld       (iu_idu_ex2_pipe0_wb_preg_vld),
  .iu_idu_ex2_pipe1_wb_preg_dupx      (iu_idu_ex2_pipe1_wb_preg_dupx),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx  (iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_data      (iu_idu_ex2_pipe1_wb_preg_data),
  .iu_idu_ex2_pipe1_wb_preg_expand    (iu_idu_ex2_pipe1_wb_preg_expand),
  .iu_idu_ex2_pipe1_wb_preg_vld       (iu_idu_ex2_pipe1_wb_preg_vld),
  .iu_idu_ex2_pipe2_wb_preg_dupx      (iu_idu_ex2_pipe2_wb_preg_dupx),
  .iu_idu_ex2_pipe2_wb_preg_vld_dupx  (iu_idu_ex2_pipe2_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe2_wb_preg_data      (iu_idu_ex2_pipe2_wb_preg_data),
  .iu_idu_ex2_pipe2_wb_preg_expand    (iu_idu_ex2_pipe2_wb_preg_expand),
  .iu_idu_ex2_pipe2_wb_preg_vld       (iu_idu_ex2_pipe2_wb_preg_vld),

  //==========================================================
  // Interface with LSU - Writeback
  //==========================================================
  .lsu_idu_wb_pipe3_wb_preg_dupx      (lsu_idu_wb_pipe3_wb_preg),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx  (lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .lsu_idu_wb_pipe3_wb_preg_data      (lsu_idu_wb_pipe3_wb_preg_data),
  .lsu_idu_wb_pipe3_wb_preg_expand    (lsu_idu_wb_pipe3_wb_preg_expand),
  .lsu_idu_wb_pipe3_wb_preg_vld       (lsu_idu_wb_pipe3_wb_preg_vld),

  //==========================================================
  // Interface with LSU - LSIQ control
  //==========================================================
  .lsu_idu_lq_full                (lsu_idu_lq_full),
  .lsu_idu_lq_not_full            (lsu_idu_lq_not_full),
  .lsu_idu_rb_full                (lsu_idu_rb_full),
  .lsu_idu_rb_not_full            (lsu_idu_rb_not_full),
  .lsu_idu_sq_full                (lsu_idu_sq_full),
  .lsu_idu_sq_not_full            (lsu_idu_sq_not_full),
    // 2026-10-19 停用: .lsu_idu_secd                   (lsu_idu_secd),

  .lsu_idu_imme_wakeup            (lsu_idu_imme_wakeup),
  .lsu_idu_lsiq_pop_vld           (lsu_idu_lsiq_pop_vld),
  .lsu_idu_lsiq_pop0_vld          (lsu_idu_lsiq_pop0_vld),
  .lsu_idu_lsiq_pop1_vld          (lsu_idu_lsiq_pop1_vld),
  .lsu_idu_lsiq_pop_entry         (lsu_idu_lsiq_pop_entry),

  //==========================================================
  // Interface with LSU - SDIQ control
  //==========================================================
  //  .lsu_sdiq_has_in_sq_vld         (),
  .lsu_sdiq_has_in_sq_sdiq        (lsu_idu_has_in_sq),

  //==========================================================
  // Output to AIQ0 (ALU0) / AIQ1 (ALU1, 2026-10-18)
  //==========================================================
  .idu_aiq_sel                    (idu_aiq_sel),
  .idu_aiq_iid                    (idu_aiq_iid),
  .idu_aiq_dst_preg               (idu_aiq_dst_preg),
  .idu_aiq_src0                   (idu_aiq_src0),
  .idu_aiq_src1                   (idu_aiq_src1),
  .idu_aiq_pc                     (idu_aiq_pc),
  .idu_aiq_rslt_sel               (idu_aiq_rslt_sel),
  .idu_aiq_illegal                (idu_aiq_illegal),

  .idu_aiq1_sel                   (idu_aiq1_sel),
  .idu_aiq1_iid                   (idu_aiq1_iid),
  .idu_aiq1_dst_preg              (idu_aiq1_dst_preg),
  .idu_aiq1_src0                  (idu_aiq1_src0),
  .idu_aiq1_src1                  (idu_aiq1_src1),
  .idu_aiq1_pc                    (idu_aiq1_pc),
  .idu_aiq1_rslt_sel              (idu_aiq1_rslt_sel),
  .idu_aiq1_illegal               (idu_aiq1_illegal),

  //==========================================================
  // Output to MULT
  // ⚠️ 待接: 消费侧是 MUL (IU_md_pipe.v), 本文件还没例化。
  //==========================================================
  .idu_mult_sel                   (idu_mult_sel),
  .idu_mult_iid                   (idu_mult_iid),
  .idu_mult_dst_preg              (idu_mult_dst_preg),
  .idu_mult_src0                  (idu_mult_src0),
  .idu_mult_src1                  (idu_mult_src1),
  .idu_mult_rslt_sel              (idu_mult_rslt_sel),

  //==========================================================
  // Output to DIV
  // ⚠️ 待接: 同上。
  //==========================================================
  .idu_div_sel                    (idu_div_sel),
  .idu_div_iid                    (idu_div_iid),
  .idu_div_dst_vld                (idu_div_dst_vld),
  .idu_div_dst_preg               (idu_div_dst_preg),
  .idu_div_src0                   (idu_div_src0),
  .idu_div_src1                   (idu_div_src1),
  .idu_div_rslt_sel               (idu_div_rslt_sel),

  //==========================================================
  // Output to LSU - Load pipe
  //==========================================================
  .idu_lsu_ld_sel                 (idu_lsu_ld_sel),
  .idu_lsu_ld_iid                 (idu_lsu_ld_iid),
  .idu_lsu_ld_preg                (idu_lsu_ld_preg),
  .idu_lsu_ld_src0                (idu_lsu_ld_src),
  .idu_lsu_ld_offset              (idu_lsu_ld_offset),
    // 2026-10-19 停用: .idu_lsu_ld_offset_plus         (idu_lsu_ld_offset_plus),

  .idu_lsu_ld_sign_extend         (idu_lsu_ld_sign_extend),
  .idu_lsu_ld_inst_size           (idu_lsu_ld_inst_size),
    // 2026-10-19 停用: .idu_lsu_ld_unalign_2nd         (idu_lsu_ld_unalign_2nd),

  .idu_lsu_ld_lch_entry           (idu_lsu_ld_lch_entry),
  .idu_lsu_ld_oldest              (idu_lsu_ld_oldest),

  //==========================================================
  // Output to LSU - Store pipe
  //==========================================================
  .idu_lsu_st_sel                 (idu_lsu_st_sel),
  .idu_lsu_st_iid                 (idu_lsu_st_iid),
 // .idu_lsu_st_preg                (),
  .idu_lsu_st_src0                (idu_lsu_st_src0),
  .idu_lsu_st_offset              (idu_lsu_st_offset),
    // 2026-10-19 停用: .idu_lsu_st_offset_plus         (idu_lsu_st_offset_plus),

  .idu_lsu_st_inst_size           (idu_lsu_st_inst_size),
    // 2026-10-19 停用: .idu_lsu_st_unalign_2nd         (idu_lsu_st_unalign_2nd),

  .idu_lsu_st_lch_entry           (idu_lsu_st_lch_entry),
  .idu_lsu_st_oldest              (idu_lsu_st_oldest),
  .idu_lsu_st_sdiq_entry          (idu_lsu_st_sdiq_entry),

  //==========================================================
  // Output to LSU - SDIQ pipe
  //==========================================================
  .idu_lsu_sdiq_sel               (idu_lsu_sdiq_sel),
  .idu_lsu_rf_pipe5_sdiq_entry    (idu_lsu_rf_pipe5_sdiq_entry),
  .idu_lsu_rf_pipe5_src0          (idu_lsu_rf_pipe5_src0),

  //==========================================================
  // Output to BIQ
  // ⚠️ 待接: 消费侧是 BEU (IU_beu_pipe.v), 本文件还没例化。
  //==========================================================
  .idu_biq_sel                    (idu_biq_sel),
  .idu_biq_iid                    (idu_biq_iid),
  .idu_biq_src0                   (idu_biq_src0),
  .idu_biq_src1                   (idu_biq_src1),
  .idu_biq_rslt_sel               (idu_biq_rslt_sel),
  .idu_biq_br_imme                (idu_biq_br_imme),
  .idu_biq_dst_vld                (idu_biq_dst_vld),
  .idu_biq_dst_preg               (idu_biq_dst_preg),
  .idu_biq_taken                  (idu_biq_taken),
  .idu_biq_npc                    (idu_biq_npc),
  .idu_biq_pc                     (idu_biq_pc),
  .idu_biq_chk                    (idu_biq_chk),

  //==========================================================
  // Interface with RTU — 派遣记录 (3 车道 × 12 字段)
  //
  // IDU 侧已经按 RTU 的契约打包好了 (`ct_idu_top` 末尾的打包块): dst_preg/
  // old_preg/src1_preg 已从 6 位补成 7 位、flags 已按 `RTU_FLG_*` 排好、
  // csr_op 已是 funct3 原样、dst_lreg 已按 A6d 掩过。所以适配层一个字段都不变换,
  // 这里也只是改名 —— **不要在顶层再插任何变换**。
  // ==========================================================
  .idu_rtu_disp0_vld              (idu_rtu_disp0_vld),
  .idu_rtu_disp0_pc               (idu_rtu_disp0_pc),
  .idu_rtu_disp0_chk              (idu_rtu_disp0_chk),
  .idu_rtu_disp0_dst_lreg         (idu_rtu_disp0_dst_lreg),
  .idu_rtu_disp0_rf_we            (idu_rtu_disp0_rf_we),
  .idu_rtu_disp0_dst_preg         (idu_rtu_disp0_dst_preg),
  .idu_rtu_disp0_old_preg         (idu_rtu_disp0_old_preg),
  .idu_rtu_disp0_src1_preg        (idu_rtu_disp0_src1_preg),
  .idu_rtu_disp0_csr_addr         (idu_rtu_disp0_csr_addr),
  .idu_rtu_disp0_csr_op           (idu_rtu_disp0_csr_op),
  .idu_rtu_disp0_csr_imm          (idu_rtu_disp0_csr_imm),
  .idu_rtu_disp0_flags            (idu_rtu_disp0_flags),

  .idu_rtu_disp1_vld              (idu_rtu_disp1_vld),
  .idu_rtu_disp1_pc               (idu_rtu_disp1_pc),
  .idu_rtu_disp1_chk              (idu_rtu_disp1_chk),
  .idu_rtu_disp1_dst_lreg         (idu_rtu_disp1_dst_lreg),
  .idu_rtu_disp1_rf_we            (idu_rtu_disp1_rf_we),
  .idu_rtu_disp1_dst_preg         (idu_rtu_disp1_dst_preg),
  .idu_rtu_disp1_old_preg         (idu_rtu_disp1_old_preg),
  .idu_rtu_disp1_src1_preg        (idu_rtu_disp1_src1_preg),
  .idu_rtu_disp1_csr_addr         (idu_rtu_disp1_csr_addr),
  .idu_rtu_disp1_csr_op           (idu_rtu_disp1_csr_op),
  .idu_rtu_disp1_csr_imm          (idu_rtu_disp1_csr_imm),
  .idu_rtu_disp1_flags            (idu_rtu_disp1_flags),

  .idu_rtu_disp2_vld              (idu_rtu_disp2_vld),
  .idu_rtu_disp2_pc               (idu_rtu_disp2_pc),
  .idu_rtu_disp2_chk              (idu_rtu_disp2_chk),
  .idu_rtu_disp2_dst_lreg         (idu_rtu_disp2_dst_lreg),
  .idu_rtu_disp2_rf_we            (idu_rtu_disp2_rf_we),
  .idu_rtu_disp2_dst_preg         (idu_rtu_disp2_dst_preg),
  .idu_rtu_disp2_old_preg         (idu_rtu_disp2_old_preg),
  .idu_rtu_disp2_src1_preg        (idu_rtu_disp2_src1_preg),
  .idu_rtu_disp2_csr_addr         (idu_rtu_disp2_csr_addr),
  .idu_rtu_disp2_csr_op           (idu_rtu_disp2_csr_op),
  .idu_rtu_disp2_csr_imm          (idu_rtu_disp2_csr_imm),
  .idu_rtu_disp2_flags            (idu_rtu_disp2_flags),

  //==========================================================
  // Interface with RTU — 物理寄存器堆访问 (直连, 不过适配层)
  //
  // RTU 侧 7 位 / IDU 侧 6 位, 靠端口处的隐式截位 —— 见声明块里的长注。
  //==========================================================
  .rtu_preg_raddr0                (rtu_preg_raddr0),
  .rtu_preg_raddr1                (rtu_preg_raddr1),
  .rtu_preg_raddr2                (rtu_preg_raddr2),
  .rtu_csr_src_raddr              (rtu_csr_src_raddr),
  .rtu_csr_rd_we                  (rtu_csr_rd_we),
  .rtu_csr_rd_addr                (rtu_csr_rd_addr),
  .rtu_csr_rd_wdata               (rtu_csr_rd_wdata),
  .rtu_preg_rdata0                (idu_rtu_preg_rdata_raw0),
  .rtu_preg_rdata1                (idu_rtu_preg_rdata_raw1),
  .rtu_preg_rdata2                (idu_rtu_preg_rdata_raw2),
  .rtu_csr_src_rdata              (idu_rtu_csr_src_rdata_raw),

  //==========================================================
  // 执行单元的发射准入
  // 源 = IU_md_pipe.md_unit_stall (已例化; 含 div_busy/div_hold/div_accept/skid 占用)。
  //==========================================================
  .md_unit_stall                  (md_unit_stall),
  // ALU1 的 EX2 有结果但没拿到 pipe2 授权 ⇒ AIQ1 本拍保持、弹表项
  .iu_idu_aiq1_stall              (aiq1_issue_stall)
  );

  // ============================================================
  // LSU
  // ============================================================
  lsu_top #(
    // ⚠️ 必须与 `+define+DCACHE_{1,2,4}KB` **同步** (dcache 阵列整个包在那些 ifdef 里,
    //    两边不一致 ⇒ 阵列一片不例化 ⇒ 读出来是 X, 不报错但功能全错)。
    //    Makefile 的 `DCACHE_DEF` 与这里都由 `DCACHE_SIZE` 派生, 改一处即可。
    //    默认 (不传) = 2 KB, 与改动前的硬写值逐位一致。
`ifdef DCACHE_4KB
    .DCACHE_SIZE     (4096),
`elsif DCACHE_1KB
    .DCACHE_SIZE     (1024),
`else
    .DCACHE_SIZE     (2048),
`endif
    // ⚠️ 必须与 IDU 侧的 `ct_idu_is_lsiq` 项数**同步** —— 这两边靠同一个
    //    `+define+LSIQ_ENTRY` 驱动 (`LSIQ_NUM` 来自 lsiq_defines.vh, 那边读同一个
    //    define)。一边 12 一边 8 编得过、错得静默: lsid/lq_full/sq_full 这些
    //    一位一项的向量高位被丢, 8 号以上的表项永远 pop 不出去 ⇒ 挂死。
    .LSIQ_ENTRY      (`LSIQ_NUM),
    .SQ_ENTRY        (6),
    .SDIQ_ENTRY      (4),
    .WMB_ENTRY       (4),
    .LFB_ADDR_ENTRY  (3),
    .LFB_DATA_ENTRY  (1)
  ) u_lsu_top (
    // IDU to LSU - Load interface
    .idu_lsu_ld_sel                 (idu_lsu_ld_sel),
    .idu_lsu_ld_inst_size           (idu_lsu_ld_inst_size),
    // 2026-10-19 停用: .idu_lsu_ld_unalign_2nd         (idu_lsu_ld_unalign_2nd),

    .idu_lsu_ld_sign_extend         (idu_lsu_ld_sign_extend),
    .idu_lsu_ld_iid                 (idu_lsu_ld_iid),
    .idu_lsu_ld_lch_entry           (idu_lsu_ld_lch_entry),
    .idu_lsu_ld_oldest              (idu_lsu_ld_oldest),
    .idu_lsu_ld_preg                (idu_lsu_ld_preg),
    .idu_lsu_ld_offset              (idu_lsu_ld_offset),
    // 2026-10-19 停用: .idu_lsu_ld_offset_plus         (idu_lsu_ld_offset_plus),

    .idu_lsu_ld_src                 (idu_lsu_ld_src),

    // IDU to LSU - Store interface
    .idu_lsu_st_sel                 (idu_lsu_st_sel),
    .idu_lsu_st_inst_size           (idu_lsu_st_inst_size),
    // 2026-10-19 停用: .idu_lsu_st_unalign_2nd         (idu_lsu_st_unalign_2nd),

    .idu_lsu_st_iid                 (idu_lsu_st_iid),
    .idu_lsu_st_lch_entry           (idu_lsu_st_lch_entry),
    .idu_lsu_st_sdiq_entry          (idu_lsu_st_sdiq_entry),
    .idu_lsu_st_oldest              (idu_lsu_st_oldest),
    .idu_lsu_st_offset              (idu_lsu_st_offset),
    // 2026-10-19 停用: .idu_lsu_st_offset_plus         (idu_lsu_st_offset_plus),

    .idu_lsu_st_src0                (idu_lsu_st_src0),

    .idu_lsu_rf_pipe5_src0          (idu_lsu_rf_pipe5_src0),
    .idu_lsu_sdiq_sel               (idu_lsu_sdiq_sel),
    .idu_lsu_rf_pipe5_sdiq_entry    (idu_lsu_rf_pipe5_sdiq_entry),

    // RTU interface
    // ⚠️ `rtu_yy_xx_flush` 用**适配层合并后的那根** (`rtu_ren_flush |
    //    rtu_backend_flush`, T+1 拍), 与 IDU 同源 —— 不要接到 RTU 的
    //    `rtu_core_redirect` 上: 那根是 T 拍的"核内重定向事件", 相位与
    //    IDU/LSU 自己的流水对不齐。
    .rtu_yy_xx_flush                (rtu_yy_xx_flush),
    .rtu_yy_xx_commit0              (rtu_yy_xx_commit0),
    .rtu_yy_xx_commit0_iid          (rtu_yy_xx_commit0_iid),
    .rtu_yy_xx_commit1              (rtu_yy_xx_commit1),
    .rtu_yy_xx_commit1_iid          (rtu_yy_xx_commit1_iid),
    .rtu_yy_xx_commit2              (rtu_yy_xx_commit2),
    .rtu_yy_xx_commit2_iid          (rtu_yy_xx_commit2_iid),
    .rtu_lsu_async_flush            (rtu_lsu_async_flush),

    // Clock and reset
    .forever_cpuclk                 (clk),
    .cpurst_b                       (rst_b),

    // BIU read interface (from bus to LSU)
    .biu_lsu_r_data                 (biu_lsu_rdata),
    .biu_lsu_r_id                   (biu_lsu_rid),
    .biu_lsu_r_last                 (biu_lsu_rlast),
    .biu_lsu_r_resp                 (biu_lsu_rresp),
    .biu_lsu_r_vld                  (biu_lsu_rvalid),

    // BIU write response interface (from bus to LSU)
    .biu_lsu_b_id                   (biu_lsu_bid),
    .biu_lsu_b_resp                 (biu_lsu_bresp),
    .biu_lsu_b_vld                  (biu_lsu_bvalid),

    .biu_lsu_ar_ready               (lsu_biu_arready),
    // 4 个 grnt: store 走 WMB 通路, victim 走 VB 通路
    .biu_lsu_aw_wmb_grnt            (lsu_biu_aw_st_ready),
    .biu_lsu_w_wmb_grnt             (lsu_biu_w_st_ready),
    .biu_lsu_aw_vb_grnt             (lsu_biu_aw_vict_ready),
    .biu_lsu_w_vb_grnt              (lsu_biu_w_vict_ready),

    // BIU AR 输出
    .lsu_biu_ar_addr                (lsu_biu_araddr),
 // .lsu_biu_ar_bar                 (),   // ct_biu_top 无此口 (AXI4)
    .lsu_biu_ar_burst               (lsu_biu_arburst),
    .lsu_biu_ar_cache               (lsu_biu_arcache),
 // .lsu_biu_ar_domain              (),   // ct_biu_top 无此口
    .lsu_biu_ar_id                  (lsu_biu_arid),
    .lsu_biu_ar_len                 (lsu_biu_arlen),
 // .lsu_biu_ar_lock                (),   // ct_biu_top 无此口
    .lsu_biu_ar_prot                (lsu_biu_arprot),
    .lsu_biu_ar_req                 (lsu_biu_arvalid),
    .lsu_biu_ar_size                (lsu_biu_arsize),
 // .lsu_biu_ar_user                (),   // ct_biu_top 无此口
    .lsu_biu_r_ready                (lsu_biu_rready),

    // BIU AW store 输出
    .lsu_biu_aw_st_addr             (lsu_biu_aw_st_addr),
 // .lsu_biu_aw_st_bar              (),   // ct_biu_top 无此口
    .lsu_biu_aw_st_burst            (lsu_biu_aw_st_burst),
    .lsu_biu_aw_st_cache            (lsu_biu_aw_st_cache),
 // .lsu_biu_aw_st_domain           (),   // ct_biu_top 无此口
    .lsu_biu_aw_st_id               (lsu_biu_aw_st_id),
    .lsu_biu_aw_st_len              (lsu_biu_aw_st_len),
 // .lsu_biu_aw_st_lock             (),   // ct_biu_top 无此口
    .lsu_biu_aw_st_prot             (lsu_biu_aw_st_prot),
    .lsu_biu_aw_st_req              (lsu_biu_aw_st_valid),
    .lsu_biu_aw_st_size             (lsu_biu_aw_st_size),
 // .lsu_biu_aw_st_user             (),   // ct_biu_top 无此口

    // BIU AW victim 输出
    .lsu_biu_aw_vict_addr           (lsu_biu_aw_vict_addr),
 // .lsu_biu_aw_vict_bar            (),   // ct_biu_top 无此口
    .lsu_biu_aw_vict_burst          (lsu_biu_aw_vict_burst),
    .lsu_biu_aw_vict_cache          (lsu_biu_aw_vict_cache),
 // .lsu_biu_aw_vict_domain         (),   // ct_biu_top 无此口
    .lsu_biu_aw_vict_id             (lsu_biu_aw_vict_id),
    .lsu_biu_aw_vict_len            (lsu_biu_aw_vict_len),
 // .lsu_biu_aw_vict_lock           (),   // ct_biu_top 无此口
    .lsu_biu_aw_vict_prot           (lsu_biu_aw_vict_prot),
    .lsu_biu_aw_vict_req            (lsu_biu_aw_vict_valid),
    .lsu_biu_aw_vict_size           (lsu_biu_aw_vict_size),
 // .lsu_biu_aw_vict_user           (),   // ct_biu_top 无此口

    // BIU W store 输出
    .lsu_biu_w_st_data              (lsu_biu_w_st_data),
    .lsu_biu_w_st_last              (lsu_biu_w_st_last),
    .lsu_biu_w_st_strb              (lsu_biu_w_st_strb),
    .lsu_biu_w_st_vld               (lsu_biu_w_st_valid),

    // BIU W victim 输出
    .lsu_biu_w_vict_data            (lsu_biu_w_vict_data),
    .lsu_biu_w_vict_last            (lsu_biu_w_vict_last),
    .lsu_biu_w_vict_strb            (lsu_biu_w_vict_strb),
    .lsu_biu_w_vict_vld             (lsu_biu_w_vict_valid),

    // LSU to IDU - Load queue status
    .lsu_idu_imme_wakeup            (lsu_idu_imme_wakeup),
    .lsu_idu_lsiq_pop_vld           (lsu_idu_lsiq_pop_vld),
    .lsu_idu_lsiq_pop0_vld          (lsu_idu_lsiq_pop0_vld),
    .lsu_idu_lsiq_pop1_vld          (lsu_idu_lsiq_pop1_vld),
    .lsu_idu_pop_entry              (lsu_idu_lsiq_pop_entry),
    // 2026-10-19 停用: .lsu_idu_secd                   (lsu_idu_secd),


    .lsu_idu_lq_full                (lsu_idu_lq_full),
    .lsu_idu_lq_not_full            (lsu_idu_lq_not_full),

    .lsu_idu_rb_full                (lsu_idu_rb_full),
    .lsu_idu_rb_not_full            (lsu_idu_rb_not_full),

    .lsu_idu_sq_full                (lsu_idu_sq_full),
    .lsu_idu_sq_not_full            (lsu_idu_sq_not_full),

    .lsu_idu_has_in_sq              (lsu_idu_has_in_sq),

    // LSU to RTU - 冲刷闸 (见上面 logic 声明处的长注)
    .lsu_rtu_all_commit_data_vld    (lsu_rtu_all_commit_data_vld),

    // LSU to RTU - Writeback pipe3 (load 完成 / 非对齐异常)
    .lsu_rtu_wb_pipe3_cmplt         (lsu_rtu_wb_pipe3_cmplt),
    .lsu_rtu_wb_pipe3_iid           (lsu_rtu_wb_pipe3_iid),
    .lsu_rtu_wb_pipe3_expt_vld      (lsu_rtu_wb_pipe3_expt_vld),
    .lsu_rtu_wb_pipe3_expt_addr     (lsu_rtu_wb_pipe3_expt_addr),
    // ⚠️ 这两根按 `doc/rtu_接口对照表.csv` 归"暂无对应": RTU 按 **iid** 找表项,
    //    不需要按 preg 广播; 寿命信息走 `idu_rtu_pst_preg_dealloc_mask`。
    //    登记不接, 只做观察口。
    .lsu_rtu_wb_pipe3_wb_preg_expand(lsu_rtu_wb_pipe3_wb_preg_expand),
    .lsu_rtu_wb_pipe3_wb_preg_vld   (lsu_rtu_wb_pipe3_wb_preg_vld),

    // LSU to IDU - Writeback pipe3
    .lsu_idu_wb_pipe3_wb_preg       (lsu_idu_wb_pipe3_wb_preg),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
    .lsu_idu_wb_pipe3_wb_preg_data  (lsu_idu_wb_pipe3_wb_preg_data),
    .lsu_idu_wb_pipe3_wb_preg_expand(lsu_idu_wb_pipe3_wb_preg_expand),
    .lsu_idu_wb_pipe3_wb_preg_vld   (lsu_idu_wb_pipe3_wb_preg_vld),
    .lsu_idu_wb_pipe3_wb_preg_iid   (lsu_idu_wb_pipe3_wb_preg_iid),

    // LSU to RTU - Writeback pipe4 (store 完成 / 非对齐异常 / 投机写失败)
    // ⚠️ `_flush` / `_spec_fail` 对 RTU 是**同一个动作**(这条 store 的投机结果
    //    错了 ⇒ 要重放), 适配层把两根或起来送 `lsu_replay_vld`。
    .lsu_rtu_wb_pipe4_cmplt         (lsu_rtu_wb_pipe4_cmplt),
    .lsu_rtu_wb_pipe4_expt_vld      (lsu_rtu_wb_pipe4_expt_vld),
    .lsu_rtu_wb_pipe4_expt_addr     (lsu_rtu_wb_pipe4_expt_addr),
    .lsu_rtu_wb_pipe4_flush         (lsu_rtu_wb_pipe4_flush),
    .lsu_rtu_wb_pipe4_iid           (lsu_rtu_wb_pipe4_iid),
    .lsu_rtu_wb_pipe4_spec_fail     (lsu_rtu_wb_pipe4_spec_fail)

    // Store queue wakeup
 // .sq_data_depd_wakeup            (),
 // .sq_global_depd_wakeup          (),

    // LFB dependency wakeup
 // .lfb_depd_wakeup                ()
  );

  // ---------------------------------------------------------------------------
  //  RTU ↔ IDU/LSU 适配层
  // ---------------------------------------------------------------------------
  // 它属于 RTU 这一侧, 放这里是因为它夹在 RTU 与 IDU/LSU 之间。端口命名两侧分别
  // 沿用对方的名字 (idu_* / lsu_* 是lc的原端口名, 其余是 RTU 的), 所以下面三段
  // 全是同名对接。
  //
  // 四类真变换都在适配层内部, 顶层不插任何逻辑 —— 接法照抄 rtu/rtl/RTU_subsys.v。
  RTU_idu_lsu_adapter u_rtu_adapter (
    .cpu_clk                            (clk),
    .cpu_rst                            (rst),
    .cpurst_b                           (rst_b),

    // ---- IDU 侧 ----
    .idu_rtu_ir_preg0_alloc_vld         (idu_rtu_ir_preg0_alloc_vld),
    .idu_rtu_ir_preg1_alloc_vld         (idu_rtu_ir_preg1_alloc_vld),
    .idu_rtu_ir_preg2_alloc_vld         (idu_rtu_ir_preg2_alloc_vld),
    .rtu_idu_alloc_preg0                (rtu_idu_alloc_preg0),
    .rtu_idu_alloc_preg1                (rtu_idu_alloc_preg1),
    .rtu_idu_alloc_preg2                (rtu_idu_alloc_preg2),
    .rtu_idu_alloc_preg0_vld            (rtu_idu_alloc_preg0_vld),
    .rtu_idu_alloc_preg1_vld            (rtu_idu_alloc_preg1_vld),
    .rtu_idu_alloc_preg2_vld            (rtu_idu_alloc_preg2_vld),
    .rtu_idu_rob_inst0_iid              (rtu_idu_rob_inst0_iid),
    .rtu_idu_rob_inst1_iid              (rtu_idu_rob_inst1_iid),
    .rtu_idu_rob_inst2_iid              (rtu_idu_rob_inst2_iid),
    .rtu_idu_rob_full                   (rtu_idu_rob_full),
    .rtu_yy_xx_flush                    (rtu_yy_xx_flush),
    .rtu_idu_rt_recover_preg            (rtu_idu_rt_recover_preg),
    .idu_rtu_pst_preg_dealloc_mask      (idu_rtu_pst_preg_dealloc_mask),
    .idu_rtu_disp0_vld                  (idu_rtu_disp0_vld),
    .idu_rtu_disp0_pc                   (idu_rtu_disp0_pc),
    .idu_rtu_disp0_chk                  (idu_rtu_disp0_chk),
    .idu_rtu_disp0_dst_lreg             (idu_rtu_disp0_dst_lreg),
    .idu_rtu_disp0_rf_we                (idu_rtu_disp0_rf_we),
    .idu_rtu_disp0_dst_preg             (idu_rtu_disp0_dst_preg),
    .idu_rtu_disp0_old_preg             (idu_rtu_disp0_old_preg),
    .idu_rtu_disp0_src1_preg            (idu_rtu_disp0_src1_preg),
    .idu_rtu_disp0_csr_addr             (idu_rtu_disp0_csr_addr),
    .idu_rtu_disp0_csr_op               (idu_rtu_disp0_csr_op),
    .idu_rtu_disp0_csr_imm              (idu_rtu_disp0_csr_imm),
    .idu_rtu_disp0_flags                (idu_rtu_disp0_flags),
    .idu_rtu_disp1_vld                  (idu_rtu_disp1_vld),
    .idu_rtu_disp1_pc                   (idu_rtu_disp1_pc),
    .idu_rtu_disp1_chk                  (idu_rtu_disp1_chk),
    .idu_rtu_disp1_dst_lreg             (idu_rtu_disp1_dst_lreg),
    .idu_rtu_disp1_rf_we                (idu_rtu_disp1_rf_we),
    .idu_rtu_disp1_dst_preg             (idu_rtu_disp1_dst_preg),
    .idu_rtu_disp1_old_preg             (idu_rtu_disp1_old_preg),
    .idu_rtu_disp1_src1_preg            (idu_rtu_disp1_src1_preg),
    .idu_rtu_disp1_csr_addr             (idu_rtu_disp1_csr_addr),
    .idu_rtu_disp1_csr_op               (idu_rtu_disp1_csr_op),
    .idu_rtu_disp1_csr_imm              (idu_rtu_disp1_csr_imm),
    .idu_rtu_disp1_flags                (idu_rtu_disp1_flags),
    .idu_rtu_disp2_vld                  (idu_rtu_disp2_vld),
    .idu_rtu_disp2_pc                   (idu_rtu_disp2_pc),
    .idu_rtu_disp2_chk                  (idu_rtu_disp2_chk),
    .idu_rtu_disp2_dst_lreg             (idu_rtu_disp2_dst_lreg),
    .idu_rtu_disp2_rf_we                (idu_rtu_disp2_rf_we),
    .idu_rtu_disp2_dst_preg             (idu_rtu_disp2_dst_preg),
    .idu_rtu_disp2_old_preg             (idu_rtu_disp2_old_preg),
    .idu_rtu_disp2_src1_preg            (idu_rtu_disp2_src1_preg),
    .idu_rtu_disp2_csr_addr             (idu_rtu_disp2_csr_addr),
    .idu_rtu_disp2_csr_op               (idu_rtu_disp2_csr_op),
    .idu_rtu_disp2_csr_imm              (idu_rtu_disp2_csr_imm),
    .idu_rtu_disp2_flags                (idu_rtu_disp2_flags),

    // ---- LSU 侧 ----
    .lsu_rtu_wb_pipe3_cmplt             (lsu_rtu_wb_pipe3_cmplt),
    .lsu_rtu_wb_pipe3_iid               (lsu_rtu_wb_pipe3_iid),
    .lsu_rtu_wb_pipe3_expt_vld          (lsu_rtu_wb_pipe3_expt_vld),
    .lsu_rtu_wb_pipe3_expt_addr         (lsu_rtu_wb_pipe3_expt_addr),
    .lsu_rtu_wb_pipe4_cmplt             (lsu_rtu_wb_pipe4_cmplt),
    .lsu_rtu_wb_pipe4_iid               (lsu_rtu_wb_pipe4_iid),
    .lsu_rtu_wb_pipe4_expt_vld          (lsu_rtu_wb_pipe4_expt_vld),
    .lsu_rtu_wb_pipe4_expt_addr         (lsu_rtu_wb_pipe4_expt_addr),
    .lsu_rtu_wb_pipe4_flush             (lsu_rtu_wb_pipe4_flush),
    .lsu_rtu_wb_pipe4_spec_fail         (lsu_rtu_wb_pipe4_spec_fail),

    // ---- 其它异常源 (非法指令 / 取指故障 …): 待接, 见末尾清单 ----
    .other_expt_vld                     (other_expt_vld),
    .other_expt_iid                     (other_expt_iid),
    .other_expt_cause                   (other_expt_cause),
    .other_expt_tval                    (other_expt_tval),

    // ---- RTU 侧 ----
    .ren_preg_req                       (ren_preg_req),
    .rtu_preg_alloc0                    (rtu_preg_alloc0),
    .rtu_preg_alloc1                    (rtu_preg_alloc1),
    .rtu_preg_alloc2                    (rtu_preg_alloc2),
    .rtu_preg_alloc_vld0                (rtu_preg_alloc_vld0),
    .rtu_preg_alloc_vld1                (rtu_preg_alloc_vld1),
    .rtu_preg_alloc_vld2                (rtu_preg_alloc_vld2),
    .disp0_vld                          (disp0_vld),
    .disp0_pc                           (disp0_pc),
    .disp0_chk                          (disp0_chk),
    .disp0_dst_lreg                     (disp0_dst_lreg),
    .disp0_rf_we                        (disp0_rf_we),
    .disp0_dst_preg                     (disp0_dst_preg),
    .disp0_old_preg                     (disp0_old_preg),
    .disp0_src1_preg                    (disp0_src1_preg),
    .disp0_csr_addr                     (disp0_csr_addr),
    .disp0_csr_op                       (disp0_csr_op),
    .disp0_csr_imm                      (disp0_csr_imm),
    .disp0_flags                        (disp0_flags),
    .disp0_sq_id                        (disp0_sq_id),
    .disp1_vld                          (disp1_vld),
    .disp1_pc                           (disp1_pc),
    .disp1_chk                          (disp1_chk),
    .disp1_dst_lreg                     (disp1_dst_lreg),
    .disp1_rf_we                        (disp1_rf_we),
    .disp1_dst_preg                     (disp1_dst_preg),
    .disp1_old_preg                     (disp1_old_preg),
    .disp1_src1_preg                    (disp1_src1_preg),
    .disp1_csr_addr                     (disp1_csr_addr),
    .disp1_csr_op                       (disp1_csr_op),
    .disp1_csr_imm                      (disp1_csr_imm),
    .disp1_flags                        (disp1_flags),
    .disp1_sq_id                        (disp1_sq_id),
    .disp2_vld                          (disp2_vld),
    .disp2_pc                           (disp2_pc),
    .disp2_chk                          (disp2_chk),
    .disp2_dst_lreg                     (disp2_dst_lreg),
    .disp2_rf_we                        (disp2_rf_we),
    .disp2_dst_preg                     (disp2_dst_preg),
    .disp2_old_preg                     (disp2_old_preg),
    .disp2_src1_preg                    (disp2_src1_preg),
    .disp2_csr_addr                     (disp2_csr_addr),
    .disp2_csr_op                       (disp2_csr_op),
    .disp2_csr_imm                      (disp2_csr_imm),
    .disp2_flags                        (disp2_flags),
    .disp2_sq_id                        (disp2_sq_id),
    .cmplt_vld5                         (cmplt_vld5),
    .cmplt_iid5                         (cmplt_iid5),
    .cmplt_vld6                         (cmplt_vld6),
    .cmplt_iid6                         (cmplt_iid6),
    .lsu_replay_vld                     (lsu_replay_vld),
    .lsu_replay_iid                     (lsu_replay_iid),
    .expt_iu_vld                        (expt_iu_vld),
    .expt_iu_iid                        (expt_iu_iid),
    .expt_iu_cause                      (expt_iu_cause),
    .expt_iu_tval                       (expt_iu_tval),
    .expt_ld_vld                        (expt_ld_vld),
    .expt_ld_iid                        (expt_ld_iid),
    .expt_ld_cause                      (expt_ld_cause),
    .expt_ld_tval                       (expt_ld_tval),
    .expt_st_vld                        (expt_st_vld),
    .expt_st_iid                        (expt_st_iid),
    .expt_st_cause                      (expt_st_cause),
    .expt_st_tval                       (expt_st_tval),
    .sq_rdy0                            (sq_rdy0),
    .sq_rdy1                            (sq_rdy1),
    .sq_rdy2                            (sq_rdy2),
    .sq_stall                           (sq_stall),
    .preg_dealloc_mask                  (preg_dealloc_mask),
    .rtu_disp_stall                     (rtu_disp_stall),
    .rtu_ren_flush                      (rtu_ren_flush),
    .rtu_backend_flush                  (rtu_backend_flush),
    .rtu_ren_recover_map                (rtu_ren_recover_map),
    .rtu_disp_iid0                      (rtu_disp_iid0),
    .rtu_disp_iid1                      (rtu_disp_iid1),
    .rtu_disp_iid2                      (rtu_disp_iid2),
    .rtu_preg_free_cnt                  (rtu_preg_free_cnt)
  );

  // ============================================================
  // RTU
  // ============================================================
  // ---------------------------------------------------------------------------
  //  PRF 读口旁路 (2026-10-12, A910 集成层)
  //
  //  【为什么必需】`ct_idu_rf_prf_pregfile.sv` 的 12~15 号读口是**纯组合**读
  //  (`rtu_preg_rdata0 = preg_reg_dout[rtu_preg_raddr0]`), 而写口
  //  (`*_wb_preg_vld` + `*_wb_preg_expand`) 的写入落在**本拍时钟沿** —— 于是
  //  "写回与退休撞在同一拍"时, 读回来的是**写之前的旧值**; 那条指令的物理寄存器
  //  若从未被写过, 读到的就是未初始化值/X。
  //
  //  实测指纹 (mul 用例, +TRACE_EARLY):
  //      T93 写回 p0_vld=1 p0_dupx=63        ← addi x5 的写回
  //      T93 退休 ret pc=00000000 x5<=xxxxxxxx
  //  以及 `addi x17,x0,93` 执行了却报 `x17<=00000000` —— 冒烟台据此判超时。
  //
  //  对架构状态**无害**(写在边沿落地, 退休只是个状态位), 但**打死 difftest**:
  //  `dbg_commit_*` 那 15 根正是 difftest 的接入点, "边写边退休"这一拍必然读到旧值,
  //  于是每条这样的指令都会报一次假失配。
  //
  //  【为什么放在顶层】PRF 是 IDU 的文件, 改它属于动别人的模块; 而读口是给我们的
  //  RTU 用的 ⇒ 在**本集成层**加旁路, 只改接线, 两边模块一行不动。
  //  同一份旁路顺带覆盖 `rtu_csr_src_rdata`(RTU 读在途 CSR 指令的 rs1), 那里
  //  同样可能撞上同拍写 —— 是同一个洞。
  //
  //  ⚠️ 判命中用 `_wb_preg_expand`(独热) 而不是 `_dupx` 比索引: expand 才是 PRF
  //     内部真正用的写使能, 两者若哪天不同步, 这里跟着 PRF 走才对。
  //  ⚠️ **不旁路第 5 个写口**(RTU 自己的 `rtu_csr_rd_*`): 那根在退休拍写, 而同拍
  //     该 CSRC 条的值本来就取 `csr_rdata`; 把它卷进来会让
  //     `csr_rd_wdata →(旁路)→ rtu_csr_src_rdata → csr_rd_wdata` 出现组合环。
  // ---------------------------------------------------------------------------
  wire [63:0] prf_wb0_hot = iu_idu_ex2_pipe0_wb_preg_expand & {64{iu_idu_ex2_pipe0_wb_preg_vld}};
  wire [63:0] prf_wb1_hot = iu_idu_ex2_pipe1_wb_preg_expand & {64{iu_idu_ex2_pipe1_wb_preg_vld}};
  wire [63:0] prf_wb2_hot = iu_idu_ex2_pipe2_wb_preg_expand & {64{iu_idu_ex2_pipe2_wb_preg_vld}};
  wire [63:0] prf_wb3_hot = lsu_idu_wb_pipe3_wb_preg_expand & {64{lsu_idu_wb_pipe3_wb_preg_vld}};

  // 一个读口的旁路 = 4 个写口按优先级串起来 (同一拍不可能有两个写口写同一个号)。
  // 读口地址先切成 6 位 (PRF 是 64 项); RTU 侧的 `RTU_PREG_W` 是 6 或 7, 高位在
  // 64 档下恒 0, 与 PRF 的截位口径一致。
  wire [5:0] prf_raddr0 = rtu_preg_raddr0[5:0];
  wire [5:0] prf_raddr1 = rtu_preg_raddr1[5:0];
  wire [5:0] prf_raddr2 = rtu_preg_raddr2[5:0];
  wire [5:0] prf_raddrc = rtu_csr_src_raddr[5:0];

  assign rtu_preg_rdata0 = prf_wb0_hot[prf_raddr0] ? iu_idu_ex2_pipe0_wb_preg_data :
                           prf_wb1_hot[prf_raddr0] ? iu_idu_ex2_pipe1_wb_preg_data :
                           prf_wb2_hot[prf_raddr0] ? iu_idu_ex2_pipe2_wb_preg_data :
                           prf_wb3_hot[prf_raddr0] ? lsu_idu_wb_pipe3_wb_preg_data :
                                                     idu_rtu_preg_rdata_raw0;

  assign rtu_preg_rdata1 = prf_wb0_hot[prf_raddr1] ? iu_idu_ex2_pipe0_wb_preg_data :
                           prf_wb1_hot[prf_raddr1] ? iu_idu_ex2_pipe1_wb_preg_data :
                           prf_wb2_hot[prf_raddr1] ? iu_idu_ex2_pipe2_wb_preg_data :
                           prf_wb3_hot[prf_raddr1] ? lsu_idu_wb_pipe3_wb_preg_data :
                                                     idu_rtu_preg_rdata_raw1;

  assign rtu_preg_rdata2 = prf_wb0_hot[prf_raddr2] ? iu_idu_ex2_pipe0_wb_preg_data :
                           prf_wb1_hot[prf_raddr2] ? iu_idu_ex2_pipe1_wb_preg_data :
                           prf_wb2_hot[prf_raddr2] ? iu_idu_ex2_pipe2_wb_preg_data :
                           prf_wb3_hot[prf_raddr2] ? lsu_idu_wb_pipe3_wb_preg_data :
                                                     idu_rtu_preg_rdata_raw2;

  assign rtu_csr_src_rdata = prf_wb0_hot[prf_raddrc] ? iu_idu_ex2_pipe0_wb_preg_data :
                             prf_wb1_hot[prf_raddrc] ? iu_idu_ex2_pipe1_wb_preg_data :
                             prf_wb2_hot[prf_raddrc] ? iu_idu_ex2_pipe2_wb_preg_data :
                             prf_wb3_hot[prf_raddrc] ? lsu_idu_wb_pipe3_wb_preg_data :
                                                       idu_rtu_csr_src_rdata_raw;

  // ===========================================================================
  // 写回门的总线合成 (2026-10-13) —— 「这个号这一拍写回了」的独热或
  // ---------------------------------------------------------------------------
  // 给 RTU 的物理寄存器池当"写回过才准回池"那道闸门 (RELEASE → FREE 的第二个条件)。
  // 取的就是 PRF 的 4 个**外部**写口 (第 5 个是 CSR 的 rd, 由 RTU 自己产生, 在
  // RTU.v 内部并进掩码 —— 见那里的 `preg_wb_mask_i`)。
  //
  //   * IU pipe0/1/2: `iu_idu_ex2_pipe{k}_wb_preg_{vld,expand}`。判命中一律用
  //     `{64{vld}} & expand` —— **与 PRF 内部的写使能逐字同式**
  //     (`ct_idu_rf_prf_pregfile.sv:128-134`)。用 `_dupx` 比索引不行: expand 才是
  //     真正落到 PRF 写口上的独热 (本文件 PRF 旁路段 :1652-1654 记过同一句话)。
  //   * LSU pipe3: `lsu_rtu_wb_pipe3_wb_preg_{vld,expand}`。这两根**本来就是
  //     LSU 为 RTU 准备的** (C910 `ct_rtu_pst_preg.v:6134` 的 wb_vld 或项就是这么接的),
  //     在这之前一直挂在"观察口/有意留空"清单里 —— 现在它有对端了。
  //     ⚠️ 它与给 IDU 的 `lsu_idu_wb_pipe3_wb_preg_*` 是 lsu_top 的**同一对**输出
  //        (lsu_ld_wb.sv:279/287 同式), 接哪一组都行; 这里取名字对的那一组。
  //
  // ⚠️ 这三根必须**同拍配对** (vld 与其 expand): LSU 那侧 d769f0d 刚把 vld 从
  //    "组合的 pre" 改成"寄存的 data_vld"正是为了这件事 —— 配对错了会写错号。
  // ⚠️ 只做"或", 不做寄存/打拍: 门是电平保持的 (RTU_preg 里 `wb_ok` 自己锁存)。
  // ===========================================================================
  wire [63:0] preg_wb_mask =
        ({64{iu_idu_ex2_pipe0_wb_preg_vld}} & iu_idu_ex2_pipe0_wb_preg_expand)
      | ({64{iu_idu_ex2_pipe1_wb_preg_vld}} & iu_idu_ex2_pipe1_wb_preg_expand)
      | ({64{iu_idu_ex2_pipe2_wb_preg_vld}} & iu_idu_ex2_pipe2_wb_preg_expand)
      | ({64{lsu_rtu_wb_pipe3_wb_preg_vld}} & lsu_rtu_wb_pipe3_wb_preg_expand);

  RTU u_rtu (
    .cpu_clk                    (clk),
    .cpu_rst                    (rst),

    // ===================== §6.0 物理寄存器分配握手 =====================
    // 门房语义: 号提前备在门口(寄存器), 请求那拍当拍取走。接法在适配层里,
    // 这里 1:1。
    .ren_preg_req               (ren_preg_req),
    .rtu_preg_alloc0            (rtu_preg_alloc0),
    .rtu_preg_alloc1            (rtu_preg_alloc1),
    .rtu_preg_alloc2            (rtu_preg_alloc2),
    .rtu_preg_alloc_vld0        (rtu_preg_alloc_vld0),
    .rtu_preg_alloc_vld1        (rtu_preg_alloc_vld1),
    .rtu_preg_alloc_vld2        (rtu_preg_alloc_vld2),
    .rtu_preg_free_cnt          (rtu_preg_free_cnt),

    // ===================== §6.1 派遣 (车道 0) =====================
    .disp0_vld                  (disp0_vld),
    .disp0_pc                   (disp0_pc),
    .disp0_chk                  (disp0_chk),
    .disp0_dst_lreg             (disp0_dst_lreg),
    .disp0_rf_we                (disp0_rf_we),
    .disp0_dst_preg             (disp0_dst_preg),
    .disp0_old_preg             (disp0_old_preg),
    .disp0_src1_preg            (disp0_src1_preg),
    .disp0_csr_addr             (disp0_csr_addr),
    .disp0_csr_op               (disp0_csr_op),
    .disp0_csr_imm              (disp0_csr_imm),
    .disp0_flags                (disp0_flags),
    .disp0_sq_id                (disp0_sq_id),

    // ===================== §6.1 派遣 (车道 1) =====================
    .disp1_vld                  (disp1_vld),
    .disp1_pc                   (disp1_pc),
    .disp1_chk                  (disp1_chk),
    .disp1_dst_lreg             (disp1_dst_lreg),
    .disp1_rf_we                (disp1_rf_we),
    .disp1_dst_preg             (disp1_dst_preg),
    .disp1_old_preg             (disp1_old_preg),
    .disp1_src1_preg            (disp1_src1_preg),
    .disp1_csr_addr             (disp1_csr_addr),
    .disp1_csr_op               (disp1_csr_op),
    .disp1_csr_imm              (disp1_csr_imm),
    .disp1_flags                (disp1_flags),
    .disp1_sq_id                (disp1_sq_id),

    // ===================== §6.1 派遣 (车道 2) =====================
    .disp2_vld                  (disp2_vld),
    .disp2_pc                   (disp2_pc),
    .disp2_chk                  (disp2_chk),
    .disp2_dst_lreg             (disp2_dst_lreg),
    .disp2_rf_we                (disp2_rf_we),
    .disp2_dst_preg             (disp2_dst_preg),
    .disp2_old_preg             (disp2_old_preg),
    .disp2_src1_preg            (disp2_src1_preg),
    .disp2_csr_addr             (disp2_csr_addr),
    .disp2_csr_op               (disp2_csr_op),
    .disp2_csr_imm              (disp2_csr_imm),
    .disp2_flags                (disp2_flags),
    .disp2_sq_id                (disp2_sq_id),

    // ===================== §6.1 完成 (p = 0..6) =====================
    // 口 5/6 = LSU 读/写, 来自适配层;
    // 口 0 = ALU0, 口 1 = ALU1 (2026-10-18), 口 3 = BEU, 口 4 = MUL/DIV;
    // 口 2 无对应单元, RTL 里显式接 0。
    .cmplt_vld0                 (cmplt_vld0),
    .cmplt_iid0                 (cmplt_iid0),
    .cmplt_vld1                 (cmplt_vld1),
    .cmplt_iid1                 (cmplt_iid1),
    .cmplt_vld2                 (cmplt_vld2),
    .cmplt_iid2                 (cmplt_iid2),
    .cmplt_vld3                 (cmplt_vld3),
    .cmplt_iid3                 (cmplt_iid3),
    .cmplt_vld4                 (cmplt_vld4),
    .cmplt_iid4                 (cmplt_iid4),
    .cmplt_vld5                 (cmplt_vld5),
    .cmplt_iid5                 (cmplt_iid5),
    .cmplt_vld6                 (cmplt_vld6),
    .cmplt_iid6                 (cmplt_iid6),

    // ===================== §6.1 解析结果 (BEU) =====================
    // ⚠️ 待接: 源是 BEU (IU_beu_pipe.v)。解析口只有 1 路 = **分支单元数**,
    //    不是发射宽度 (2026-10-02 一度按发射宽度做成 3 路, 当天收回)。
    .resolve_vld                (resolve_vld),
    .resolve_iid                (resolve_iid),
    .resolve_taken              (resolve_taken),
    .resolve_mispred            (resolve_mispred),
    .resolve_target             (resolve_target),

    // ===================== §6.1 LSU store 重放请求 =====================
    .lsu_replay_vld             (lsu_replay_vld),
    .lsu_replay_iid             (lsu_replay_iid),

    // ===================== 冲刷闸: LSU 已退休访存的数据就绪 =====================
    .lsu_rtu_all_commit_data_vld(lsu_rtu_all_commit_data_vld),

    // ===================== §6.1 异常 (三个平行源) =====================
    // 三源 **平行** 进来, 锦标赛在 RTU_expt 内部做。适配层只做完成门控与
    // cause 编码, 不再合并 —— 上游先合成一路会在同拍冲突时永久丢异常。
    .expt_iu_vld                (expt_iu_vld),
    .expt_iu_iid                (expt_iu_iid),
    .expt_iu_cause              (expt_iu_cause),
    .expt_iu_tval               (expt_iu_tval),
    .expt_ld_vld                (expt_ld_vld),
    .expt_ld_iid                (expt_ld_iid),
    .expt_ld_cause              (expt_ld_cause),
    .expt_ld_tval               (expt_ld_tval),
    .expt_st_vld                (expt_st_vld),
    .expt_st_iid                (expt_st_iid),
    .expt_st_cause              (expt_st_cause),
    .expt_st_tval               (expt_st_tval),

    // ===================== §6.1 存储队列 / CSR / 中断 =====================
    // `sq_rdy*` / `sq_stall` 由适配层恒接 1/0 (LSU 还没产生这两根)。
    // ⚠️ `sq_rdy*` **绝不能接 0**: 那会让每一条 store 都永远退不了休 —— 死锁。
    .sq_rdy0                    (sq_rdy0),
    .sq_rdy1                    (sq_rdy1),
    .sq_rdy2                    (sq_rdy2),
    .sq_stall                   (sq_stall),
    // ⚠️ 待接: CSR 文件。`csr_rdata` 是"按 rtu_csr_addr 组合读出的**旧值**",
    //    不是本条指令自己的值 —— 接的时候别接错口。
    .csr_rdata                  (csr_rdata),
    .int_pending                (int_pending),

    // ============ §6.1 IDU 的释放否决掩码 ============
    // 位 = 1 ⇒ 这个号还被 store 引用着, 不许回池 (第 5 态 RELEASE)。
    .preg_dealloc_mask          (preg_dealloc_mask),

    // ============ §6.1 写回门 ============
    // 位 = 1 ⇒ 这个号的生产者已经写回, 准回池 (第 5 态 RELEASE 的第二道闸门)。
    // 合成见上面 `preg_wb_mask`; CSR 的 rd 那一路由 RTU 自己并进去。
    .preg_wb_mask               (preg_wb_mask),

    // ===================== BEU -> RTU (D13) =====================
    .beu_redirect_vld           (beu_redirect_vld),



    // ===================== §6.1 物理寄存器堆读口 (A1) =====================
    // 直连 IDU 内部的 PRF(不过适配层)。RTU 按"退休槽的 dst_preg"寻址。
    // ⚠️ RTU 侧叫 `preg_rdata*`, IDU 侧叫 `rtu_preg_rdata*` —— 两侧不同名。
    .preg_rdata0                (rtu_preg_rdata0),
    .preg_rdata1                (rtu_preg_rdata1),
    .preg_rdata2                (rtu_preg_rdata2),
    .rtu_csr_src_rdata          (rtu_csr_src_rdata),

    // ===================== §6.1 重定向目标的来源 (A6) =====================
    .csr_trap_vector            (csr_trap_vector),
    .csr_mepc                   (csr_mepc),

    // ===================== §6.2 前端: 陷阱/中断/mret 的重定向 =====================
    // ⚠️ D13 之后误预测**不走这条** (前端在 BEU 的重定向当拍就动了, 见 IFU 的
    //    `iu_chgflw_*`) —— 这里只发陷阱/中断/mret/store 重放。
    .rtu_ifu_flush              (rtu_ifu_flush),
    .rtu_ifu_chgflw_vld         (rtu_ifu_chgflw_vld),
    .rtu_ifu_chgflw_pc          (rtu_ifu_chgflw_pc),

    // ---- 退休点重训练 ----
    .rtu_ifu_train_vld          (rtu_ifu_train_vld),
    .rtu_ifu_train_pc           (rtu_ifu_train_pc),
    .rtu_ifu_train_target       (rtu_ifu_train_target),
    .rtu_ifu_train_chk          (rtu_ifu_train_chk),
    .rtu_ifu_train_taken        (rtu_ifu_train_taken),
    .rtu_ifu_train_is_cond      (rtu_ifu_train_is_cond),
    .rtu_ifu_train_is_jal       (rtu_ifu_train_is_jal),
    .rtu_ifu_train_is_jalr      (rtu_ifu_train_is_jalr),

    // ===================== §6.2 后端冲刷 (D11 的 FLUSH_1) =====================
    .rtu_backend_flush          (rtu_backend_flush),

    // ===================== §6.2 核内重定向事件 (D13) =====================
    // ⚠️ 只做观察口 —— **不要**拿它去驱动 IDU/LSU 的 flush: 它是 T 拍的事件,
    //    而那两个模块要的是 T+1 拍的 `rtu_yy_xx_flush`。
    .rtu_core_redirect          (rtu_core_redirect),

    // ===================== §6.2 提交窗口广播 (给 LSU) =====================
    .rtu_yy_xx_commit0          (rtu_yy_xx_commit0),
    .rtu_yy_xx_commit1          (rtu_yy_xx_commit1),
    .rtu_yy_xx_commit2          (rtu_yy_xx_commit2),
    .rtu_yy_xx_commit0_iid      (rtu_yy_xx_commit0_iid),
    .rtu_yy_xx_commit1_iid      (rtu_yy_xx_commit1_iid),
    .rtu_yy_xx_commit2_iid      (rtu_yy_xx_commit2_iid),

    // ===================== §6.2 异步冲刷 (给 LSU) =====================
    .rtu_lsu_async_flush        (rtu_lsu_async_flush),
    .rtu_flush_busy             (rtu_flush_busy),

    // ===================== §6.2 BEU: D1 的最旧门控 + 冲刷屏蔽 =====================
    .rtu_beu_retire_iid         (rtu_beu_retire_iid),
    .rtu_beu_flush_chgflw_mask  (rtu_beu_flush_chgflw_mask),

    // ===================== §6.2 重命名级 =====================
    .rtu_disp_stall             (rtu_disp_stall),
    .rtu_ren_recover_vld        (rtu_ren_recover_vld),
    .rtu_ren_recover_map        (rtu_ren_recover_map),
    .rtu_ren_flush              (rtu_ren_flush),
    .rtu_ren_free_preg0         (rtu_ren_free_preg0),
    .rtu_ren_free_preg1         (rtu_ren_free_preg1),
    .rtu_ren_free_preg2         (rtu_ren_free_preg2),
    .rtu_ren_free_vld0          (rtu_ren_free_vld0),
    .rtu_ren_free_vld1          (rtu_ren_free_vld1),
    .rtu_ren_free_vld2          (rtu_ren_free_vld2),

    // ---- 派遣回执 ----
    .rtu_disp_vld0              (rtu_disp_vld0),
    .rtu_disp_vld1              (rtu_disp_vld1),
    .rtu_disp_vld2              (rtu_disp_vld2),
    .rtu_disp_iid0              (rtu_disp_iid0),
    .rtu_disp_iid1              (rtu_disp_iid1),
    .rtu_disp_iid2              (rtu_disp_iid2),

    // ===================== §6.2 物理寄存器堆访问 (A1) =====================
    .rtu_preg_raddr0            (rtu_preg_raddr0),
    .rtu_preg_raddr1            (rtu_preg_raddr1),
    .rtu_preg_raddr2            (rtu_preg_raddr2),
    .rtu_csr_src_raddr          (rtu_csr_src_raddr),
    .rtu_csr_rd_we              (rtu_csr_rd_we),
    .rtu_csr_rd_addr            (rtu_csr_rd_addr),
    .rtu_csr_rd_wdata           (rtu_csr_rd_wdata),

    // ===================== §6.2 提交点副作用 =====================
    // ⚠️ `rtu_store_*` 待接: LSU 现在按 **iid 广播**找表项, 不需要槽号。
    .rtu_store_vld0             (rtu_store_vld0),
    .rtu_store_vld1             (rtu_store_vld1),
    .rtu_store_vld2             (rtu_store_vld2),
    .rtu_store_sq_id0           (rtu_store_sq_id0),
    .rtu_store_sq_id1           (rtu_store_sq_id1),
    .rtu_store_sq_id2           (rtu_store_sq_id2),
    // ⚠️ 待接: CSR 文件。见末尾清单里"中断位"那条。
    .rtu_csr_we                 (rtu_csr_we),
    .rtu_csr_addr               (rtu_csr_addr),
    .rtu_csr_wdata              (rtu_csr_wdata),
    .rtu_trap_vld               (rtu_trap_vld),
    .rtu_mret_vld               (rtu_mret_vld),
    .rtu_trap_epc               (rtu_trap_epc),
    .rtu_trap_tval              (rtu_trap_tval),
    .rtu_trap_cause             (rtu_trap_cause),
    .rtu_retire_cnt             (rtu_retire_cnt),

    // ===================== §6.2 difftest / debug =====================
    // ⚠️ 2026-10-13: 这 15 根先进 `DBG_HOLD` 拍延迟线, 再由延迟线出口驱动
    //    对外的 `dbg_commit_*` —— 理由见本文件上面那段长注 (LSU load 退休早于写回)。
    .dbg_commit_vld0            (rtu_cmt_vld[0]),
    .dbg_commit_vld1            (rtu_cmt_vld[1]),
    .dbg_commit_vld2            (rtu_cmt_vld[2]),
    .dbg_commit_pc0             (rtu_cmt_pc[0]),
    .dbg_commit_pc1             (rtu_cmt_pc[1]),
    .dbg_commit_pc2             (rtu_cmt_pc[2]),
    .dbg_commit_ena0            (rtu_cmt_ena[0]),
    .dbg_commit_ena1            (rtu_cmt_ena[1]),
    .dbg_commit_ena2            (rtu_cmt_ena[2]),
    .dbg_commit_reg0            (rtu_cmt_reg[0]),
    .dbg_commit_reg1            (rtu_cmt_reg[1]),
    .dbg_commit_reg2            (rtu_cmt_reg[2]),
    .dbg_commit_iid0            (rtu_cmt_iid[0]),
    .dbg_commit_iid1            (rtu_cmt_iid[1]),
    .dbg_commit_iid2            (rtu_cmt_iid[2]),
    .dbg_commit_value0          (rtu_cmt_val[0]),
    .dbg_commit_value1          (rtu_cmt_val[1]),
    .dbg_commit_value2          (rtu_cmt_val[2])
  );

  // ============================================================
  // 执行单元 (IU)
  // ============================================================
  // 当前配置 (2026-10-18 双 ALU):
  //   - 例化 2 个 ALU (完成口 0/1)、1 个 BEU (完成口 3)、1 个 MD (完成口 4)
  //   - 写回端口分配: ALU0 → pipe0, BEU → pipe1, **ALU1 与 MD 共用 pipe2**
  //   - pipe2 由 IU_wb_arb 做严格 round-robin; 两个 wrapper 各自保持结果直到授权
  //   - 完成口 2 没有对应单元, 明确接 0

  // ------------------------------------------------------------
  // ALU (完成口 0, 写回 pipe0)
  // ------------------------------------------------------------
  IU_alu_pipe u_iu_alu_pipe (
    .cpu_clk            (clk),
    .cpu_rst            (rst),
    .idu_flush          (rtu_yy_xx_flush),

    // IDU 发射口
    .idu_sel            (idu_aiq_sel),
    .idu_iid            (idu_aiq_iid),
    .idu_dst_preg       (idu_aiq_dst_preg),
    .idu_src0           (idu_aiq_src0),
    .idu_src1           (idu_aiq_src1),
    .idu_pc             (idu_aiq_pc),
    .idu_rslt_sel       (idu_aiq_rslt_sel),
    .idu_illegal        (idu_aiq_illegal),

    // 写回 IDU (pipe0)
    .wb_preg_vld        (iu_idu_ex2_pipe0_wb_preg_vld),
    .wb_preg_data       (iu_idu_ex2_pipe0_wb_preg_data),
    .wb_preg_expand     (iu_idu_ex2_pipe0_wb_preg_expand),
    .wb_preg_dupx       (iu_idu_ex2_pipe0_wb_preg_dupx),
    .wb_preg_vld_dupx   (iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    // 完成口 → RTU
    .cmplt_vld          (cmplt_vld0),
    .cmplt_iid          (cmplt_iid0),

    // 写回授权: ALU0 独占 pipe0 ⇒ 恒授权
    .wb_grant           (1'b1),
    .wb_req             (),
    .issue_stall        (),

    // 观察口
    .o_alu_result       ()
  );

  // ------------------------------------------------------------
  // ALU1 (完成口 1, 写回与 MD 共用 pipe2, 由 IU_wb_arb 做 RR)
  // ------------------------------------------------------------
  IU_alu_pipe u_iu_alu_pipe1 (
    .cpu_clk            (clk),
    .cpu_rst            (rst),
    .idu_flush          (rtu_yy_xx_flush),

    // IDU 发射口 (AIQ1)
    .idu_sel            (idu_aiq1_sel),
    .idu_iid            (idu_aiq1_iid),
    .idu_dst_preg       (idu_aiq1_dst_preg),
    .idu_src0           (idu_aiq1_src0),
    .idu_src1           (idu_aiq1_src1),
    .idu_pc             (idu_aiq1_pc),
    .idu_rslt_sel       (idu_aiq1_rslt_sel),
    .idu_illegal        (idu_aiq1_illegal),

    // 写回先接中间线, 由仲裁器选源后进 pipe2
    .wb_preg_vld        (alu1_wb_vld),
    .wb_preg_data       (alu1_wb_data),
    .wb_preg_expand     (alu1_wb_expand),
    .wb_preg_dupx       (alu1_wb_dupx),
    .wb_preg_vld_dupx   (alu1_wb_vld_dupx),

    // 完成口 → RTU 口 1
    .cmplt_vld          (alu1_cmplt_vld),
    .cmplt_iid          (alu1_cmplt_iid),

    // 写回授权 / 保持 / 反压 AIQ1
    .wb_grant           (alu1_wb_grant),
    .wb_req             (alu1_wb_req),
    .issue_stall        (aiq1_issue_stall),

    // 观察口
    .o_alu_result       ()
  );

  // ------------------------------------------------------------
  // BEU (完成口 3, 写回 pipe1)
  // ------------------------------------------------------------
  IU_beu_pipe u_iu_beu_pipe (
    .cpu_clk            (clk),
    .cpu_rst            (rst),
    .idu_flush          (rtu_yy_xx_flush),

    // IDU BIQ 发射口
    .idu_sel            (idu_biq_sel),
    .idu_iid            (idu_biq_iid),
    .idu_src0           (idu_biq_src0),
    .idu_src1           (idu_biq_src1),
    .idu_pc             (idu_biq_pc),
    .idu_npc            (idu_biq_npc),
    .idu_taken          (idu_biq_taken),
    .idu_rslt_sel       (idu_biq_rslt_sel),
    .idu_br_imme        (idu_biq_br_imme),
    .idu_dst_vld        (idu_biq_dst_vld),
    .idu_dst_preg       (idu_biq_dst_preg),
    .idu_chk            (idu_biq_chk),

    // 重定向握手
    .redirect_in_progress (rtu_ifu_chgflw_vld),  // RTU 本拍在发 trap/mret
    .chgflw_mask          (rtu_beu_flush_chgflw_mask),

    // 写回 IDU (pipe1)
    .wb_preg_vld        (iu_idu_ex2_pipe1_wb_preg_vld),
    .wb_preg_data       (iu_idu_ex2_pipe1_wb_preg_data),
    .wb_preg_expand     (iu_idu_ex2_pipe1_wb_preg_expand),
    .wb_preg_dupx       (iu_idu_ex2_pipe1_wb_preg_dupx),
    .wb_preg_vld_dupx   (iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    // 完成 / 解析 → RTU
    .cmplt_vld          (cmplt_vld3),
    .cmplt_iid          (cmplt_iid3),
    .resolve_vld        (resolve_vld),
    .resolve_iid        (resolve_iid),
    .resolve_taken      (resolve_taken),
    .resolve_mispred    (resolve_mispred),
    .resolve_target     (resolve_target),

    // 重定向 → RTU / IFU
    .beu_redirect_vld   (beu_redirect_vld),
    .iu_chgflw_vld      (iu_chgflw_vld),
    .iu_chgflw_pc       (iu_chgflw_pc),
    .iu_btb_chk         (iu_btb_chk),
    .iu_btb_pc          (iu_btb_pc),
    .iu_btb_taken       (iu_btb_taken),
    .iu_btb_is_cond     (iu_btb_is_cond),

    // 异常源: 取指地址非对齐
    .expt_vld           (other_expt_vld),
    .expt_iid           (other_expt_iid),
    .expt_cause         (other_expt_cause),
    .expt_tval          (other_expt_tval),

    // 观察口
    .o_actual_npc       (),
    .o_br_taken         ()
  );

  // ------------------------------------------------------------
  // MUL/DIV (完成口 4, 写回 pipe2)
  // ------------------------------------------------------------
  IU_md_pipe u_iu_md_pipe (
    .cpu_clk            (clk),
    .cpu_rst            (rst),
    .idu_flush          (rtu_yy_xx_flush),

    // IDU mult 发射口
    .idu_mult_sel       (idu_mult_sel),
    .idu_mult_iid       (idu_mult_iid),
    .idu_mult_dst_preg  (idu_mult_dst_preg),
    .idu_mult_src0      (idu_mult_src0),
    .idu_mult_src1      (idu_mult_src1),
    .idu_mult_rslt_sel  (idu_mult_rslt_sel),

    // IDU div 发射口
    .idu_div_sel        (idu_div_sel),
    .idu_div_iid        (idu_div_iid),
    .idu_div_dst_vld    (idu_div_dst_vld),
    .idu_div_dst_preg   (idu_div_dst_preg),
    .idu_div_src0       (idu_div_src0),
    .idu_div_src1       (idu_div_src1),
    .idu_div_rslt_sel   (idu_div_rslt_sel),

    // 写回先接中间线 (与 ALU1 一起进 RR 仲裁)
    .wb_preg_vld        (md_wb_vld),
    .wb_preg_dupx       (md_wb_dupx),
    .wb_preg_vld_dupx   (md_wb_vld_dupx),
    .wb_preg_data       (md_wb_data),
    .wb_preg_expand     (md_wb_expand),

    // 完成口 → RTU 口 4 (wrapper 内部已用授权门过, 与写回同拍)
    .cmplt_vld          (cmplt_vld4),
    .cmplt_iid          (cmplt_iid4),

    // 观察 / 发射准入
    .mul_ready          (),
    .div_busy           (),
    .resp_is_div        (),
    .md_unit_stall      (md_unit_stall),

    // 写回授权 / 请求 (2026-10-18: 与 ALU1 共用 pipe2)
    .md_wb_grant        (md_wb_grant),
    .md_wb_req          (md_wb_req),
    .md_skid_occ        ()
  );

  // ------------------------------------------------------------
  // ALU1 / MD 的 pipe2 写回仲裁 (严格 RR) + 共享写回 mux
  // ------------------------------------------------------------
  IU_wb_arb u_iu_wb_arb (
    .cpu_clk    (clk),
    .cpu_rst    (rst),
    .flush      (rtu_yy_xx_flush),
    .req_a      (alu1_wb_req),
    .req_b      (md_wb_req),
    .gnt_a      (alu1_wb_grant),
    .gnt_b      (md_wb_grant),
    .last_b     ()
  );

  // 两个 wrapper 已经各自把写回/完成用 grant 门过 ⇒ 这里按 md_wb_grant 选源。
  // ⚠️ 五个字段必须同源: 混着来会造成"写 A 的格子、唤醒 B 的 preg"。
  assign iu_idu_ex2_pipe2_wb_preg_vld      = md_wb_grant ? md_wb_vld      : alu1_wb_vld;
  assign iu_idu_ex2_pipe2_wb_preg_vld_dupx = md_wb_grant ? md_wb_vld_dupx : alu1_wb_vld_dupx;
  assign iu_idu_ex2_pipe2_wb_preg_dupx     = md_wb_grant ? md_wb_dupx     : alu1_wb_dupx;
  assign iu_idu_ex2_pipe2_wb_preg_data     = md_wb_grant ? md_wb_data     : alu1_wb_data;
  assign iu_idu_ex2_pipe2_wb_preg_expand   = md_wb_grant ? md_wb_expand   : alu1_wb_expand;

  // ALU1 → RTU 完成口 1 (显式连接)
  assign cmplt_vld1 = alu1_cmplt_vld;
  assign cmplt_iid1 = alu1_cmplt_iid;

  // 没有 ALU2: 完成口 2 明确接 0 (原来是悬空的 X 风险)
  assign cmplt_vld2 = 1'b0;
  assign cmplt_iid2 = 7'd0;

  // ============================================================
  // BIU
  // ============================================================
  ct_biu_top #(
    .PA_WIDTH       (32),
    .ID_WIDTH       (4),
    .DATA_WIDTH     (128),
    .STRB_WIDTH     (16),
    .LEN_WIDTH      (2)
  ) u_ct_biu_top (
    .forever_cpuclk         (clk),
    .cpurst_b               (rst_b),

    //---------------------------------------------------------
    // IFU read request (来自 ifu_biu_axi 协议桥)
    //---------------------------------------------------------
    .ifu_biu_araddr         (ifu_biu_araddr),
    .ifu_biu_arlen          (ifu_biu_arlen),
    .ifu_biu_arsize         (ifu_biu_arsize),
    .ifu_biu_arburst        (ifu_biu_arburst),
    .ifu_biu_arcache        (ifu_biu_arcache),
    .ifu_biu_arprot         (ifu_biu_arprot),
    .ifu_biu_arvalid        (ifu_biu_arvalid),
    .ifu_biu_arready        (ifu_biu_arready),
    .ifu_biu_rid            (ifu_biu_rid),

    //---------------------------------------------------------
    // IFU read response
    //---------------------------------------------------------
    .biu_ifu_rdata          (biu_ifu_rdata),
    .biu_ifu_rvalid         (biu_ifu_rvalid),
    .biu_ifu_rlast          (biu_ifu_rlast),
    .biu_ifu_rresp          (biu_ifu_rresp),
    .biu_ifu_rid            (biu_ifu_rid),
    .ifu_biu_rready         (ifu_biu_rready),

    //---------------------------------------------------------
    // LSU read request
    //---------------------------------------------------------
    .lsu_biu_araddr         (lsu_biu_araddr),
    .lsu_biu_arid           (lsu_biu_arid),
    .lsu_biu_arlen          (lsu_biu_arlen),
    .lsu_biu_arsize         (lsu_biu_arsize),
    .lsu_biu_arburst        (lsu_biu_arburst),
    .lsu_biu_arcache        (lsu_biu_arcache),
    .lsu_biu_arprot         (lsu_biu_arprot),
    .lsu_biu_arvalid        (lsu_biu_arvalid),
    .lsu_biu_arready        (lsu_biu_arready),

    //---------------------------------------------------------
    // LSU read response
    //---------------------------------------------------------
    .biu_lsu_rdata          (biu_lsu_rdata),
    .biu_lsu_rid            (biu_lsu_rid),
    .biu_lsu_rvalid         (biu_lsu_rvalid),
    .biu_lsu_rlast          (biu_lsu_rlast),
    .biu_lsu_rresp          (biu_lsu_rresp),
    .lsu_biu_rready         (lsu_biu_rready),

    //---------------------------------------------------------
    // LSU write source 0: store
    //---------------------------------------------------------
    .lsu_biu_aw_st_addr     (lsu_biu_aw_st_addr),
    .lsu_biu_aw_st_id       (lsu_biu_aw_st_id),
    .lsu_biu_aw_st_len      (lsu_biu_aw_st_len),
    .lsu_biu_aw_st_size     (lsu_biu_aw_st_size),
    .lsu_biu_aw_st_burst    (lsu_biu_aw_st_burst),
    .lsu_biu_aw_st_cache    (lsu_biu_aw_st_cache),
    .lsu_biu_aw_st_prot     (lsu_biu_aw_st_prot),
    .lsu_biu_aw_st_valid    (lsu_biu_aw_st_valid),
    .lsu_biu_aw_st_ready    (lsu_biu_aw_st_ready),

    .lsu_biu_w_st_data      (lsu_biu_w_st_data),
    .lsu_biu_w_st_strb      (lsu_biu_w_st_strb),
    .lsu_biu_w_st_last      (lsu_biu_w_st_last),
    .lsu_biu_w_st_valid     (lsu_biu_w_st_valid),
    .lsu_biu_w_st_ready     (lsu_biu_w_st_ready),

    //---------------------------------------------------------
    // LSU write source 1: victim
    //---------------------------------------------------------
    .lsu_biu_aw_vict_addr   (lsu_biu_aw_vict_addr),
    .lsu_biu_aw_vict_id     (lsu_biu_aw_vict_id),
    .lsu_biu_aw_vict_len    (lsu_biu_aw_vict_len),
    .lsu_biu_aw_vict_size   (lsu_biu_aw_vict_size),
    .lsu_biu_aw_vict_burst  (lsu_biu_aw_vict_burst),
    .lsu_biu_aw_vict_cache  (lsu_biu_aw_vict_cache),
    .lsu_biu_aw_vict_prot   (lsu_biu_aw_vict_prot),
    .lsu_biu_aw_vict_valid  (lsu_biu_aw_vict_valid),
    .lsu_biu_aw_vict_ready  (lsu_biu_aw_vict_ready),

    .lsu_biu_w_vict_data    (lsu_biu_w_vict_data),
    .lsu_biu_w_vict_strb    (lsu_biu_w_vict_strb),
    .lsu_biu_w_vict_last    (lsu_biu_w_vict_last),
    .lsu_biu_w_vict_valid   (lsu_biu_w_vict_valid),
    .lsu_biu_w_vict_ready   (lsu_biu_w_vict_ready),

    //---------------------------------------------------------
    // LSU write response
    //---------------------------------------------------------
    .biu_lsu_bid            (biu_lsu_bid),
    .biu_lsu_bresp          (biu_lsu_bresp),
    .biu_lsu_bvalid         (biu_lsu_bvalid),
    .lsu_biu_bready         (1'b1),

    //---------------------------------------------------------
    // AXI master read address
    //---------------------------------------------------------
    .biu_pad_araddr         (biu_pad_araddr),
    .biu_pad_arid           (biu_pad_arid),
    .biu_pad_arlen          (biu_pad_arlen),
    .biu_pad_arsize         (biu_pad_arsize),
    .biu_pad_arburst        (biu_pad_arburst),
    .biu_pad_arcache        (biu_pad_arcache),
    .biu_pad_arprot         (biu_pad_arprot),
    .biu_pad_arvalid        (biu_pad_arvalid),
    .pad_biu_arready        (pad_biu_arready),

    //---------------------------------------------------------
    // AXI master read data
    //---------------------------------------------------------
    .pad_biu_rdata          (pad_biu_rdata),
    .pad_biu_rid            (pad_biu_rid),
    .pad_biu_rlast          (pad_biu_rlast),
    .pad_biu_rresp          (pad_biu_rresp),
    .pad_biu_rvalid         (pad_biu_rvalid),
    .biu_pad_rready         (biu_pad_rready),

    //---------------------------------------------------------
    // AXI master write address
    //---------------------------------------------------------
    .biu_pad_awaddr         (biu_pad_awaddr),
    .biu_pad_awid           (biu_pad_awid),
    .biu_pad_awlen          (biu_pad_awlen),
    .biu_pad_awsize         (biu_pad_awsize),
    .biu_pad_awburst        (biu_pad_awburst),
    .biu_pad_awcache        (biu_pad_awcache),
    .biu_pad_awprot         (biu_pad_awprot),
    .biu_pad_awvalid        (biu_pad_awvalid),
    .pad_biu_awready        (pad_biu_awready),

    //---------------------------------------------------------
    // AXI master write data
    //---------------------------------------------------------
    .biu_pad_wdata          (biu_pad_wdata),
    .biu_pad_wstrb          (biu_pad_wstrb),
    .biu_pad_wlast          (biu_pad_wlast),
    .biu_pad_wvalid         (biu_pad_wvalid),
    .pad_biu_wready         (pad_biu_wready),

    //---------------------------------------------------------
    // AXI master write response
    //---------------------------------------------------------
    .pad_biu_bid            (pad_biu_bid),
    .pad_biu_bresp          (pad_biu_bresp),
    .pad_biu_bvalid         (pad_biu_bvalid),
    .biu_pad_bready         (biu_pad_bready)
  );

  // ---------------------------------------------------------------------------
  //  待接清单: RTU / IFU 上还没有对端模块的那些口
  // ---------------------------------------------------------------------------
  //
  // 这些网在声明段里都有名字有位宽, 端口上也连好了, 只是暂时没有驱动或消费者。
  // 之所以不接常量桩: 接了 0 就分不清"这个单元还没接"和"这个单元真的不会完成" ——
  // 前者等模块进来就好了, 后者是设计意图, 两者的调试路径完全不同。
  //
  // ⚠️ 2026-10-18 更新: 完成口 0/1/3/4 已分别由 ALU0/ALU1/BEU/MUL-DIV 驱动,
  //    口 2 显式接 0。**不要再在 TB 里 force 完成口 0/1/3/4** —— 双 ALU 集成时
  //    difftest/smoke 台里遗留的 `force dut.cmplt_vld1 = 0` 曾把 ALU1 的完成
  //    整个吞掉, 症状是 addi 只退休 2 条、ROB 填满后挂死。
  //
  // ---------------------------------------------------------------------------
  // A. 执行单元 → RTU / IDU   (源: mySoC/iu/rtl/IU_alu_pipe.v / IU_beu_pipe.v /
  //                                   IU_md_pipe.v —— 三个 wrapper 都已写好, 只是
  //                                   还没例化进本文件)
  // ---------------------------------------------------------------------------
  //  RTU 的 完成口 0/1/2  ←  3 × IU_alu_pipe.cmplt_vld / cmplt_iid
  //  RTU 的 完成口 3      ←  IU_beu_pipe.cmplt_vld / cmplt_iid
  //  RTU 的 完成口 4      ←  IU_md_pipe.cmplt_vld / cmplt_iid
  //  RTU 的 resolve_* 5 根 ←  IU_beu_pipe.resolve_vld / iid / taken / mispred / target
  //  RTU 的 beu_redirect_vld ← IU_beu_pipe.beu_redirect_vld (D13 的回执)
  //  RTU 的 expt_iu_* 4 根 ← IU_beu_pipe.expt_* (取指地址非对齐, cause 0)
  //                            与 IDU 的非法指令源 (即适配层的 other_expt_*)
  //                            ⚠️ 这条是**第三路异常**, 不是"和其它源合并的那一路" ——
  //                               三路在 RTU_expt 里做锦标赛, 见那里的长注
  //  RTU 的 rtu_beu_retire_iid / rtu_beu_flush_chgflw_mask  → IU_beu_pipe
  //  适配层的 rtu_beu_flush_chgflw_mask → IU_beu_pipe.chgflw_mask
  //  IDU 的 iu_idu_ex2_pipe0/1_* 10 根 ← ALU 与 BEU/MD 的 EX2 写回
  //  IDU 的 md_unit_stall ← MUL/DIV wrapper 的 busy
  //  IDU 的 idu_aiq_* / idu_mult_* / idu_div_* / idu_biq_*   → 上述三个 wrapper
  //
  // ---------------------------------------------------------------------------
  // B. IFU ← BEU   (源: IU_beu_pipe.v)
  // ---------------------------------------------------------------------------
  //  iu_chgflw_vld / iu_chgflw_pc  ← IU_beu_pipe 的同名输出 (EX 级误预测重定向)
  //  iu_btb_chk / iu_btb_taken / iu_btb_is_cond
  //      ⚠️ **IU_beu_pipe 现在没有这三个输出口, 要接得先给 wrapper 加口**
  //         (`chk` 从 BIQ 表项带过来)。
  //      ⚠️ 这三根不是"遗留": 重定向当拍要用**当拍 EX** 的值现算 `ghr_restore`
  //         并打拍存 RAS 指针。换成退休点那份, GHR/RAS 会被修到**另一条**指令的
  //         快照上 —— 症状是一切看起来正常, 只是准确率缓慢变差。
  //
  // ---------------------------------------------------------------------------
  // C. RTU ↔ CSR 文件   (源: mySoC/CSR.v —— mycpu.v 里有现成接法可抄)
  // ---------------------------------------------------------------------------
  //  RTU 的 csr_rdata        ← CSR.rdata2_o   (2 号读口, 地址 = rtu_csr_addr)
  //  RTU 的 int_pending      ← CSR.mstatus_mie_o & mie_mtie_o & mip_mtip_o
  //  RTU 的 csr_trap_vector  ← CSR.trap_vector_o
  //  RTU 的 csr_mepc         ← CSR.mepc_o
  //  RTU 的 rtu_csr_we/addr/wdata → CSR.we_i / waddr_i / wdata_i
  //  RTU 的 rtu_mret_vld          → CSR.mret_i
  //  RTU 的 rtu_retire_cnt        → CSR.retire_i
  //  RTU 的 rtu_trap_*            → CSR.trap_i / trap_epc_i / trap_tval_i / trap_cause_i
  //
  //  ⚠️ **接之前必须先解决"中断位"**: `rtu_trap_cause` 只有 5 位(异常号),
  //     mcause 的 bit31(中断位)要消费方补, 而 RTU 现在**没有一根"这次是中断还是
  //     异常"的输出**。mycpu.v 里那个位置接的是核自己算的 `irq_taken`, 本核没有
  //     对应信号 ⇒ 要么给 RTU 加一根输出, 要么在顶层按 flush 源重算。
  //     (只接异常、不接中断的话, 中断会以"异常"的面目写进 mcause。)
  //
  // ---------------------------------------------------------------------------
  // D. 观察口 / difftest   (没有对端, 有意留空)
  // ---------------------------------------------------------------------------
  //  RTU: rtu_core_redirect / rtu_ren_recover_vld / rtu_ren_free_preg0..2 +
  //       _vld0..2 / rtu_store_vld0..2 + rtu_store_sq_id0..2 / dbg_commit_* 15 根
  //  IFU: ifu_idu_flush (IDU 侧没有对应的口 —— IFU 内部冲刷时它自己把三槽 vld
  //       拉 0, IDU 看到的就是空 vld, 所以这根只是给波形看的) / ifu_init_done
  //  LSU: (2026-10-13 起**不再留空**) `lsu_rtu_wb_pipe3_wb_preg_expand` / `_wb_preg_vld`
  //       现在有对端了 —— 它们与 IU 的三组写回总线一起或成 `preg_wb_mask`, 喂给
  //       RTU 的物理寄存器池当"写回过才准回池"那道闸门 (见上面的合成段与
  //       rtu_plan_zh.md 的 D6 修正块)。原来按 doc/rtu_接口对照表.csv 归"暂无对应"
  //       的理由 ("RTU 按 iid 找表项, 不需要按 preg 广播") 只对**完成**口成立;
  //       写回门要的正是"按 preg"的寿命信息 —— 与掩码那条是同一类。
  //
  // ---------------------------------------------------------------------------
  // E. 已知的对接问题 (在 IDU/LSU/BIU 侧)
  // ---------------------------------------------------------------------------
  //  1) `idu_accept_num` (`ct_idu_top.sv:327`) 是
  //         {inst2_ready | inst0_ready, inst2_ready}
  //     而 `inst0_ready == inst1_ready` ⇒ **只有 2'b00 和 2'b11 可达**, 1 和 2 是
  //     不可达编码; 且它**不看 `ifu_idu_ib_inst*_vld`**, 所以可能报出比当拍有效
  //     lane 数更多的条数。IFU 的 IBUF 要求"必须是 out_vld 的连续前缀"
  //     (`rv32ifu2_ibuf.v`), 被打乱会丢/重复指令。
  //  2) `ct_biu_top.sv` 把 `ifu_biu_rid` 声明成 `[ID_WIDTH-1:0]`(4 位), 而真正
  //     消费它的 `ct_biu_req_arbiter.sv` 是 1 位 —— 位宽不匹配, 只有 bit0 有效。
  //     桥这边按 1 位驱动、高位补 0, 功能上没问题, 但那条声明该改成 1 位。
  //  3) **`lsu_biu_bready` 没有驱动源**: 它是 `ct_biu_top` 的输入(决定要不要收写
  //     响应 B), 而 `lsu_top` 没有对应的输出口 —— 我把 LSU 的端口表逐条核过,
  //     确实没有。不接的话 `biu_pad_bready` 是 Z ⇒ 写响应永远收不掉 ⇒ 写通道卡死。
  //     要修得在 LSU 侧加口(它会成为 `biu_lsu_bvalid` 的 ready)。
  //     ⚠️ 本文件里**没有**替它接常量: 接 0 是死锁, 接 1 是替 LSU 决定"永远收"。
  //
  //  另: A910_cpu.sv 原来的 LSU↔BIU 那 40 多根线**一根都没声明**, 全落到隐式线网
  //      ⇒ 被按 1 位截断 (`biu_lsu_rdata` 128→1、`lsu_biu_araddr` 32→1)。已在声明
  //      段里按两侧端口表的真实位宽补齐 —— **只补声明、没动逻辑**, 但这属于 LSU/BIU
  //      的地界, 请他们复核一遍。
  // ---------------------------------------------------------------------------

endmodule