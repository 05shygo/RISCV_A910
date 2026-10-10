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
  logic         idu_inst0_vld;
  logic [127:0] idu_inst0_data;
  logic [ 24:0] idu_inst0_chk;
  logic         idu_inst1_vld;
  logic [127:0] idu_inst1_data;
  logic [ 24:0] idu_inst1_chk;
  logic         idu_inst2_vld;
  logic [127:0] idu_inst2_data;
  logic [ 24:0] idu_inst2_chk;
  logic [  1:0] idu_accept_num;   // IDU 输出 → IFU 消费: 同拍收走的前缀条数
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
  logic [ 12:0] idu_lsu_ld_offset_plus;
  logic         idu_lsu_ld_sign_extend;
  logic [  1:0] idu_lsu_ld_inst_size;
  logic         idu_lsu_ld_unalign_2nd;
  logic [  7:0] idu_lsu_ld_lch_entry;
  logic         idu_lsu_ld_oldest;

  logic         idu_lsu_st_sel;
  logic [  6:0] idu_lsu_st_iid;
  logic [ 31:0] idu_lsu_st_src0;
  logic [ 11:0] idu_lsu_st_offset;
  logic [ 12:0] idu_lsu_st_offset_plus;
  logic [  1:0] idu_lsu_st_inst_size;
  logic         idu_lsu_st_unalign_2nd;
  logic [  7:0] idu_lsu_st_lch_entry;
  logic         idu_lsu_st_oldest;
  logic [  3:0] idu_lsu_st_sdiq_entry;

  logic         idu_lsu_sdiq_sel;
  logic [  3:0] idu_lsu_rf_pipe5_sdiq_entry;
  logic [ 31:0] idu_lsu_rf_pipe5_src0;

  logic [  7:0] lsu_idu_lq_full;
  logic         lsu_idu_lq_not_full;
  logic [  7:0] lsu_idu_rb_full;
  logic         lsu_idu_rb_not_full;
  logic [  7:0] lsu_idu_sq_full;
  logic         lsu_idu_sq_not_full;
  logic [  7:0] lsu_idu_secd;
  logic [  7:0] lsu_idu_imme_wakeup;
  logic         lsu_idu_lsiq_pop_vld;
  logic         lsu_idu_lsiq_pop0_vld;
  logic         lsu_idu_lsiq_pop1_vld;
  // ⚠️ 交付侧两侧名字不一致: IDU 叫 `lsu_idu_lsiq_pop_entry`, LSU 叫 `lsu_idu_pop_entry`
  //    (少个 `lsiq_`), 位宽与语义一致。顶层用 IDU 那一侧的名字。
  logic [  7:0] lsu_idu_lsiq_pop_entry;
  logic [  3:0] lsu_idu_has_in_sq;
  logic [  5:0] lsu_idu_wb_pipe3_wb_preg;
  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx;
  logic [ 31:0] lsu_idu_wb_pipe3_wb_preg_data;
  logic [ 63:0] lsu_idu_wb_pipe3_wb_preg_expand;
  logic         lsu_idu_wb_pipe3_wb_preg_vld;

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
  logic [ 31:0] rtu_preg_rdata0;
  logic [ 31:0] rtu_preg_rdata1;
  logic [ 31:0] rtu_preg_rdata2;
  logic [ 31:0] rtu_csr_src_rdata;

  // ---------------------------------------------------------------------------
  // RTU ↔ LSU: 经适配层 (完成口 5/6 / store 重放 / 访存异常)
  // ---------------------------------------------------------------------------
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
  logic [  1:0] ren_preg_req;
  logic [  4:0] ren_preg_req_lreg0;
  logic [  4:0] ren_preg_req_lreg1;
  logic [  4:0] ren_preg_req_lreg2;
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
  logic         dbg_commit_ena0;
  logic         dbg_commit_ena1;
  logic         dbg_commit_ena2;
  logic [  4:0] dbg_commit_reg0;
  logic [  4:0] dbg_commit_reg1;
  logic [  4:0] dbg_commit_reg2;
  logic [ 31:0] dbg_commit_value0;
  logic [ 31:0] dbg_commit_value1;
  logic [ 31:0] dbg_commit_value2;

  // ---- 待接 IDU 的执行单元侧 (这些线在 IDU 上是输入, 归执行单元驱动) ----
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
  rv32ifu2_top u_rv32ifu2_top (
    .clk                (clk),
    .rst                (rst),

    // ---- IDU 交付 ----
    .idu_inst0_vld      (idu_inst0_vld),
    .idu_inst0_data     (idu_inst0_data),
    .idu_inst0_chk      (idu_inst0_chk),
    .idu_inst1_vld      (idu_inst1_vld),
    .idu_inst1_data     (idu_inst1_data),
    .idu_inst1_chk      (idu_inst1_chk),
    .idu_inst2_vld      (idu_inst2_vld),
    .idu_inst2_data     (idu_inst2_data),
    .idu_inst2_chk      (idu_inst2_chk),
    .idu_flush          (ifu_idu_flush),      // 观察口, 见末尾待接清单
    .idu_accept_num     (idu_accept_num),

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
  .lsu_idu_secd                   (lsu_idu_secd),
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
  // Output to AIQ
  // ⚠️ 待接: 消费侧是 3 个 ALU (mySoC/iu/rtl/IU_alu_pipe.v), 本文件还没例化。
  //==========================================================
  .idu_aiq_sel                    (idu_aiq_sel),
  .idu_aiq_iid                    (idu_aiq_iid),
  .idu_aiq_dst_preg               (idu_aiq_dst_preg),
  .idu_aiq_src0                   (idu_aiq_src0),
  .idu_aiq_src1                   (idu_aiq_src1),
  .idu_aiq_pc                     (idu_aiq_pc),
  .idu_aiq_rslt_sel               (idu_aiq_rslt_sel),
  .idu_aiq_illegal                (idu_aiq_illegal),

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
  .idu_lsu_ld_offset_plus         (idu_lsu_ld_offset_plus),
  .idu_lsu_ld_sign_extend         (idu_lsu_ld_sign_extend),
  .idu_lsu_ld_inst_size           (idu_lsu_ld_inst_size),
  .idu_lsu_ld_unalign_2nd         (idu_lsu_ld_unalign_2nd),
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
  .idu_lsu_st_offset_plus         (idu_lsu_st_offset_plus),
  .idu_lsu_st_inst_size           (idu_lsu_st_inst_size),
  .idu_lsu_st_unalign_2nd         (idu_lsu_st_unalign_2nd),
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
  .rtu_preg_rdata0                (rtu_preg_rdata0),
  .rtu_preg_rdata1                (rtu_preg_rdata1),
  .rtu_preg_rdata2                (rtu_preg_rdata2),
  .rtu_csr_src_rdata              (rtu_csr_src_rdata),

  //==========================================================
  // 执行单元的发射准入
  // ⚠️ 待接: 源是 MUL/DIV wrapper 的 busy, 本文件还没例化。
  //==========================================================
  .md_unit_stall                  (md_unit_stall)
  );

  // ============================================================
  // LSU
  // ============================================================
  lsu_top #(
    .DCACHE_SIZE     (2048),
    .LSIQ_ENTRY      (8),
    .SQ_ENTRY        (6),
    .SDIQ_ENTRY      (4),
    .WMB_ENTRY       (4),
    .LFB_ADDR_ENTRY  (3),
    .LFB_DATA_ENTRY  (1)
  ) u_lsu_top (
    // IDU to LSU - Load interface
    .idu_lsu_ld_sel                 (idu_lsu_ld_sel),
    .idu_lsu_ld_inst_size           (idu_lsu_ld_inst_size),
    .idu_lsu_ld_unalign_2nd         (idu_lsu_ld_unalign_2nd),
    .idu_lsu_ld_sign_extend         (idu_lsu_ld_sign_extend),
    .idu_lsu_ld_iid                 (idu_lsu_ld_iid),
    .idu_lsu_ld_lch_entry           (idu_lsu_ld_lch_entry),
    .idu_lsu_ld_oldest              (idu_lsu_ld_oldest),
    .idu_lsu_ld_preg                (idu_lsu_ld_preg),
    .idu_lsu_ld_offset              (idu_lsu_ld_offset),
    .idu_lsu_ld_offset_plus         (idu_lsu_ld_offset_plus),
    .idu_lsu_ld_src                 (idu_lsu_ld_src),

    // IDU to LSU - Store interface
    .idu_lsu_st_sel                 (idu_lsu_st_sel),
    .idu_lsu_st_inst_size           (idu_lsu_st_inst_size),
    .idu_lsu_st_unalign_2nd         (idu_lsu_st_unalign_2nd),
    .idu_lsu_st_iid                 (idu_lsu_st_iid),
    .idu_lsu_st_lch_entry           (idu_lsu_st_lch_entry),
    .idu_lsu_st_sdiq_entry          (idu_lsu_st_sdiq_entry),
    .idu_lsu_st_oldest              (idu_lsu_st_oldest),
    .idu_lsu_st_offset              (idu_lsu_st_offset),
    .idu_lsu_st_offset_plus         (idu_lsu_st_offset_plus),
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
    .lsu_idu_secd                   (lsu_idu_secd),

    .lsu_idu_lq_full                (lsu_idu_lq_full),
    .lsu_idu_lq_not_full            (lsu_idu_lq_not_full),

    .lsu_idu_rb_full                (lsu_idu_rb_full),
    .lsu_idu_rb_not_full            (lsu_idu_rb_not_full),

    .lsu_idu_sq_full                (lsu_idu_sq_full),
    .lsu_idu_sq_not_full            (lsu_idu_sq_not_full),

    .lsu_idu_has_in_sq              (lsu_idu_has_in_sq),

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
    .ren_preg_req_lreg0                 (ren_preg_req_lreg0),
    .ren_preg_req_lreg1                 (ren_preg_req_lreg1),
    .ren_preg_req_lreg2                 (ren_preg_req_lreg2),
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
  RTU u_rtu (
    .cpu_clk                    (clk),
    .cpu_rst                    (rst),

    // ===================== §6.0 物理寄存器分配握手 =====================
    // 门房语义: 号提前备在门口(寄存器), 请求那拍当拍取走。接法在适配层里,
    // 这里 1:1。
    .ren_preg_req               (ren_preg_req),
    .ren_preg_req_lreg0         (ren_preg_req_lreg0),
    .ren_preg_req_lreg1         (ren_preg_req_lreg1),
    .ren_preg_req_lreg2         (ren_preg_req_lreg2),
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
    // 口 5/6 = LSU 读/写, 来自适配层; 口 0..4 待接 (3×ALU + BEU + MUL/DIV)。
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
    .dbg_commit_vld0            (dbg_commit_vld0),
    .dbg_commit_vld1            (dbg_commit_vld1),
    .dbg_commit_vld2            (dbg_commit_vld2),
    .dbg_commit_pc0             (dbg_commit_pc0),
    .dbg_commit_pc1             (dbg_commit_pc1),
    .dbg_commit_pc2             (dbg_commit_pc2),
    .dbg_commit_ena0            (dbg_commit_ena0),
    .dbg_commit_ena1            (dbg_commit_ena1),
    .dbg_commit_ena2            (dbg_commit_ena2),
    .dbg_commit_reg0            (dbg_commit_reg0),
    .dbg_commit_reg1            (dbg_commit_reg1),
    .dbg_commit_reg2            (dbg_commit_reg2),
    .dbg_commit_value0          (dbg_commit_value0),
    .dbg_commit_value1          (dbg_commit_value1),
    .dbg_commit_value2          (dbg_commit_value2)
  );

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
    .lsu_biu_bready         (lsu_biu_bready),

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
  // ⚠️ 这一版不要拿去跑整核仿真: 完成口 0..4 没驱动, ROB 里的表项永远不会标完成,
  //    一条都不会退休。跑到第一条指令就停, 得到的结论全是误导。
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
  //  LSU: lsu_rtu_wb_pipe3_wb_preg_expand / _wb_preg_vld
  //       (按 doc/rtu_接口对照表.csv 归"暂无对应": RTU 按 iid 找表项, 不需要
  //        按 preg 广播; 寿命信息走 idu_rtu_pst_preg_dealloc_mask)
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