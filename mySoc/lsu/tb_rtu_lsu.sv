`timescale 1ns / 1ps
`include "RTU_define.vh"

// ===========================================================================
// tb_rtu_lsu — RTU 与 LSU 的**联合**单元台 (2026-10-08 立)
//
// 为什么要有它: 这两个交付物在此之前**谁都没被例化过** —— 主构建里没有模块例化
// ct_idu_top/lsu_top (VCS 只 elaborate 从 -top 可达的层次, 它们只被 Parsing),
// 两个冒烟台也是各连各的常量。**这是第一次把 RTU 与 LSU 真的连起来 elaborate**,
// 所以第一价值就是"把两侧端口表对不对得上"逼出来 —— 那正是 `make build` 查不出来的
// 那一类错 (见 doc/idu_lsu_integration_zh.md §1)。
//
// 本台要验的那条链:
//   LSU 造出一条 load/store -> 完成回报 (lsu_rtu_wb_pipe{3,4}_{cmplt,iid})
//     -> RTU 置完成 -> 退休 -> **广播退休窗口的 iid** (rtu_yy_xx_commit*)
//     -> LSU 表项变 cmit (lsu_sq_entry.sv:418-427 拿 iid 比出来的)
//
// 接线口径 (doc/rtu_接口对照表.xlsx 的 RTU↔LSU 页):
//   * 完成口: LSU 读 -> RTU 完成口 5; LSU 写 -> 完成口 6 (D1.3 就是为它拆的)
//   * 提交:   rtu_backend_flush -> rtu_yy_xx_flush; commit0/1/2 + iid 直连
//   * 重放:   LSU 的 pipe4_flush / spec_fail **或**起来 -> lsu_replay_vld (iid 原样)
//   * sq_rdy0/1/2 恒 1、sq_stall 恒 0: LSU 的 store 数据**发射当拍就进 SQ**,
//     "退休时数据没到"不存在; 满/下游忙是**发射侧**的背压 (lsu_idu_sq_not_full),
//     与退休无关 —— 提交反而帮它排空。见接口表那一行。
//   * lsu_rtu_wb_pipe3_wb_preg_expand/_vld 不接: 我们按 iid 寻址, 不按 preg 广播。
//
// 复位: RTU 是 cpu_rst 高有效异步; LSU 是 cpurst_b 低有效异步 => 取反桥接
//       (照 mySoC/ifu_subsys.v:111 的既有先例 `.cpurst_b(~rst)`)。
//
// ⚠️⚠️ **2026-10-08: 这个台之前是"假绿"的, 修了四处才第一次真的验到东西。**
//   (之前的症状: `make rtu-lsu-unit` 在第 3 步 `fork ... join_any` 上**永久挂死**;
//    而它没有自检、没有超时 ⇒ "挂死"与"跑完没事"在日志上长得一样。)
//   ① **两个 DUT 的时钟都没接**: RTU 的 `cpu_clk`、LSU 的 `forever_cpuclk`
//      (= lsu_top.sv:50 唯一的时钟输入) 都被生成段 `initial = 0` 按住了, 接线块只桥了
//      复位 ⇒ 两边一个寄存器都不翻 (RTU 的 `occ_q` 全程 0、LSU 一条 AR 都不发)。
//      修在**生成器**里 (NO_INIT + 接线块), 见 scripts/gen_rtu_lsu_tb.py。
//   ② **派遣回执采错拍**: `rtu_disp_iid0` 是"当前创造指针", 只能在**举 vld 之前**读;
//      原来在撤掉 vld 之后再读 ⇒ 送给 LSU 的 iid 与 RTU 表项里的对不上 ⇒
//      完成信号标不中表项 ⇒ **永远不退** (实测: occ=1 但 w0cplt 起不来)。
//   ③ **完成口没过闸**: LSU 的 load AG 在"没人给它指令"时会自由跑一个 restart 环
//      (`lsu_ld_ag.sv:191-198`: `inst_vld <= (stall_ori && !ld_sel) || ld_sel`, 而
//      `stall_ori = !dcache_arb_ag_ld_sel`) ⇒ `pipe3_cmplt` 上**从复位起就周期性出现
//      iid 为垃圾的完成**。真 IDU 在场时完成只属于真指令, 本台没有 IDU, 就得自己过闸:
//      闸门 = `ld_inflight`(我们这条在途) & iid 相等, 见接线块。
//   ④ **没有自检、没有超时**: 现在有看门狗 (8000/200 拍) + 4 条链路判据 +
//      `ALL PASS` / `$fatal`。
//
// ⚠️⚠️ **本台验到了什么、没验到什么 (别读过头)**:
//   ✅ **RTU 侧那条链**: 派遣被接受 → 表项建起来 → 收到完成 → 退休 → **提交广播带对
//      iid** → 退休计数 +1。这是本台现在真正钉住的东西。
//   ❌ **没有证明 LSU 真的处理了这条 load**: 本环境里 LSU 全程 AR 0 次、LSIQ 表项弹出
//      0 次, 而那条"完成"是在我们举上去之后 1~2 拍就来的 —— 位置与形态都更像它空闲
//      restart 环吐的那一条 (恰好带着我们的 iid, 因为 AG 的数据寄存器里锁的就是这条)。
//      ⇒ 运行时会打印一行 ⚠️ 明确说这件事。
//   ❌ **store 那一半** (SDIQ 数据握手 → SQ 表项 cmit) 完全没有激励 —— 它要真 IDU 的
//      SDIQ 读口配合, 本台建不出来。
//   ⚠️ **LSU 自己的单测台 `tb/unit/lsu/tb_lsu_load_test.sv` 现在也是红的**:
//      `Timeout waiting for first AR request` —— 它只等 2000 拍, 而本环境里这条 load 的
//      天然延迟实测 ~4000 拍 (DC 级反复重试, 那期间 `ld_dc_dcache_hit`/`_valid*` 一直是 X)。
//      ⇒ **AR / 回填这条路径目前没有任何台覆盖到**, 要么把它的超时放宽并查明为什么这么慢,
//      要么查 DCache 为什么读不出确定值。这是 LSU 侧的活, 不是本台能修的。
// ===========================================================================
module tb_rtu_lsu;

    logic clk = 0;
    logic rst = 1;                       // 高有效 (RTU 侧)
    always #5 clk = ~clk;

    // RTU 侧的复位口叫 cpu_rst, LSU 侧那一堆 cpurst_b —— 都用这两根接

    // ---- **两边共用**的那 8 根 (LSU 的输入 = RTU 的输出, 同名) ----
    // 生成块在两侧都跳过它们, 由这里统一声明一次, 名字对上就自动连上了。
    wire         rtu_yy_xx_commit0, rtu_yy_xx_commit1, rtu_yy_xx_commit2;
    wire [6:0]   rtu_yy_xx_commit0_iid, rtu_yy_xx_commit1_iid, rtu_yy_xx_commit2_iid;
    wire         rtu_lsu_async_flush;    // RTU 输出 (恒 0) -> LSU 输入
    wire         rtu_yy_xx_flush;        // LSU 输入 <- RTU 的 rtu_backend_flush (接线块里 assign)

    // ============ lsu_top 端口 (生成, 勿手改) ============
    logic                  idu_lsu_ld_sel;
    logic [1:0]            idu_lsu_ld_inst_size;
    logic                  idu_lsu_ld_unalign_2nd;
    logic                  idu_lsu_ld_sign_extend;
    logic [6:0]            idu_lsu_ld_iid;
    logic [11:0]           idu_lsu_ld_lch_entry;
    logic                  idu_lsu_ld_oldest;
    logic [5:0]            idu_lsu_ld_preg;
    logic [11:0]           idu_lsu_ld_offset;
    logic [12:0]           idu_lsu_ld_offset_plus;
    logic [31:0]           idu_lsu_ld_src;
    logic                  idu_lsu_st_sel;
    logic [1:0]            idu_lsu_st_inst_size;
    logic                  idu_lsu_st_unalign_2nd;
    logic [6:0]            idu_lsu_st_iid;
    logic [11:0]           idu_lsu_st_lch_entry;
    logic [3:0]            idu_lsu_st_sdiq_entry;
    logic                  idu_lsu_st_oldest;
    logic [11:0]           idu_lsu_st_offset;
    logic [12:0]           idu_lsu_st_offset_plus;
    logic [31:0]           idu_lsu_st_src0;
    logic [31:0]           idu_lsu_rf_pipe5_src0;
    logic                  idu_lsu_sdiq_sel;
    logic [3:0]            idu_lsu_rf_pipe5_sdiq_entry;
    logic                  forever_cpuclk;
    logic                  cpurst_b;
    logic                  bus_arb_rb_ar_grnt;
    logic                  bus_arb_rb_ar_sel;
    logic [127:0]          biu_lsu_r_data;
    logic [3:0]            biu_lsu_r_id;
    logic                  biu_lsu_r_last;
    logic [1:0]            biu_lsu_r_resp;
    logic                  biu_lsu_r_vld;
    logic [3:0]            biu_lsu_b_id;
    logic [1:0]            biu_lsu_b_resp;
    logic                  biu_lsu_b_vld;
    logic                  bus_arb_wmb_aw_grnt;
    logic                  bus_arb_wmb_w_grnt;
    logic                  bus_arb_vb_aw_grnt;
    logic                  bus_arb_vb_w_grnt;
    wire  [31:0]           rb_biu_ar_addr;
    wire  [1:0]            rb_biu_ar_bar;
    wire  [1:0]            rb_biu_ar_burst;
    wire  [3:0]            rb_biu_ar_cache;
    wire  [1:0]            rb_biu_ar_domain;
    wire  [3:0]            rb_biu_ar_id;
    wire  [1:0]            rb_biu_ar_len;
    wire                   rb_biu_ar_lock;
    wire  [2:0]            rb_biu_ar_prot;
    wire                   rb_biu_ar_req;
    wire  [2:0]            rb_biu_ar_size;
    wire  [3:0]            rb_biu_ar_snoop;
    wire                   rb_biu_ar_user;
    wire  [31:0]           wmb_biu_aw_addr;
    wire  [1:0]            wmb_biu_aw_bar;
    wire  [1:0]            wmb_biu_aw_burst;
    wire  [3:0]            wmb_biu_aw_cache;
    wire  [1:0]            wmb_biu_aw_domain;
    wire  [3:0]            wmb_biu_aw_id;
    wire  [1:0]            wmb_biu_aw_len;
    wire                   wmb_biu_aw_lock;
    wire  [2:0]            wmb_biu_aw_prot;
    wire                   wmb_biu_aw_req;
    wire  [2:0]            wmb_biu_aw_size;
    wire  [2:0]            wmb_biu_aw_snoop;
    wire                   wmb_biu_aw_user;
    wire  [127:0]          wmb_biu_w_data;
    wire  [3:0]            wmb_biu_w_id;
    wire                   wmb_biu_w_req;
    wire  [15:0]           wmb_biu_w_strb;
    wire                   wmb_biu_w_vld;
    wire  [31:0]           vb_biu_aw_addr;
    wire  [1:0]            vb_biu_aw_burst;
    wire  [3:0]            vb_biu_aw_cache;
    wire  [3:0]            vb_biu_aw_id;
    wire  [1:0]            vb_biu_aw_len;
    wire                   vb_biu_aw_lock;
    wire  [2:0]            vb_biu_aw_prot;
    wire  [2:0]            vb_biu_aw_size;
    wire                   vb_biu_aw_req;
    wire  [127:0]          vb_biu_w_data;
    wire  [3:0]            vb_biu_w_id;
    wire                   vb_biu_w_last;
    wire                   vb_biu_w_req;
    wire  [15:0]           vb_biu_w_strb;
    wire                   vb_biu_w_vld;
    wire  [11:0]           lsu_idu_imme_wakeup;
    wire  [11:0]           lsu_idu_pop_entry;
    wire  [11:0]           lsu_idu_secd;
    wire  [11:0]           lsu_idu_lq_full;
    wire                   lsu_idu_lq_not_full;
    wire  [11:0]           lsu_idu_rb_full;
    wire                   lsu_idu_rb_not_full;
    wire  [11:0]           lsu_idu_sq_full;
    wire                   lsu_idu_sq_not_full;
    wire  [3:0]            lsu_idu_has_in_sq;
    wire                   lsu_rtu_wb_pipe3_cmplt;
    wire  [6:0]            lsu_rtu_wb_pipe3_iid;
    wire  [63:0]           lsu_rtu_wb_pipe3_wb_preg_expand;
    wire                   lsu_rtu_wb_pipe3_wb_preg_vld;
    wire  [5:0]            lsu_idu_wb_pipe3_wb_preg;
    wire  [31:0]           lsu_idu_wb_pipe3_wb_preg_data;
    wire  [63:0]           lsu_idu_wb_pipe3_wb_preg_expand;
    wire                   lsu_idu_wb_pipe3_wb_preg_vld;
    wire                   lsu_rtu_wb_pipe4_cmplt;
    wire                   lsu_rtu_wb_pipe4_flush;
    wire  [6:0]            lsu_rtu_wb_pipe4_iid;
    wire                   lsu_rtu_wb_pipe4_spec_fail;
    wire  [11:0]           sq_data_depd_wakeup;
    wire  [11:0]           sq_global_depd_wakeup;
    wire  [11:0]           lfb_depd_wakeup;
    initial idu_lsu_ld_sel = 0;
    initial idu_lsu_ld_inst_size = '0;
    initial idu_lsu_ld_unalign_2nd = 0;
    initial idu_lsu_ld_sign_extend = 0;
    initial idu_lsu_ld_iid = '0;
    initial idu_lsu_ld_lch_entry = '0;
    initial idu_lsu_ld_oldest = 0;
    initial idu_lsu_ld_preg = '0;
    initial idu_lsu_ld_offset = '0;
    initial idu_lsu_ld_offset_plus = '0;
    initial idu_lsu_ld_src = '0;
    initial idu_lsu_st_sel = 0;
    initial idu_lsu_st_inst_size = '0;
    initial idu_lsu_st_unalign_2nd = 0;
    initial idu_lsu_st_iid = '0;
    initial idu_lsu_st_lch_entry = '0;
    initial idu_lsu_st_sdiq_entry = '0;
    initial idu_lsu_st_oldest = 0;
    initial idu_lsu_st_offset = '0;
    initial idu_lsu_st_offset_plus = '0;
    initial idu_lsu_st_src0 = '0;
    initial idu_lsu_rf_pipe5_src0 = '0;
    initial idu_lsu_sdiq_sel = 0;
    initial idu_lsu_rf_pipe5_sdiq_entry = '0;
    initial biu_lsu_b_id = '0;
    initial biu_lsu_b_resp = '0;
    initial biu_lsu_b_vld = 0;

    lsu_top #(.SQ_ENTRY(6), .LSIQ_ENTRY(12), .SDIQ_ENTRY(4), .WMB_ENTRY(4), .LFB_ADDR_ENTRY(3), .LFB_DATA_ENTRY(1), .DCACHE_SIZE(2048), .IID_WIDTH(7)) u_lsu (
        .idu_lsu_ld_sel               (idu_lsu_ld_sel),
        .idu_lsu_ld_inst_size         (idu_lsu_ld_inst_size),
        .idu_lsu_ld_unalign_2nd       (idu_lsu_ld_unalign_2nd),
        .idu_lsu_ld_sign_extend       (idu_lsu_ld_sign_extend),
        .idu_lsu_ld_iid               (idu_lsu_ld_iid),
        .idu_lsu_ld_lch_entry         (idu_lsu_ld_lch_entry),
        .idu_lsu_ld_oldest            (idu_lsu_ld_oldest),
        .idu_lsu_ld_preg              (idu_lsu_ld_preg),
        .idu_lsu_ld_offset            (idu_lsu_ld_offset),
        .idu_lsu_ld_offset_plus       (idu_lsu_ld_offset_plus),
        .idu_lsu_ld_src               (idu_lsu_ld_src),
        .idu_lsu_st_sel               (idu_lsu_st_sel),
        .idu_lsu_st_inst_size         (idu_lsu_st_inst_size),
        .idu_lsu_st_unalign_2nd       (idu_lsu_st_unalign_2nd),
        .idu_lsu_st_iid               (idu_lsu_st_iid),
        .idu_lsu_st_lch_entry         (idu_lsu_st_lch_entry),
        .idu_lsu_st_sdiq_entry        (idu_lsu_st_sdiq_entry),
        .idu_lsu_st_oldest            (idu_lsu_st_oldest),
        .idu_lsu_st_offset            (idu_lsu_st_offset),
        .idu_lsu_st_offset_plus       (idu_lsu_st_offset_plus),
        .idu_lsu_st_src0              (idu_lsu_st_src0),
        .idu_lsu_rf_pipe5_src0        (idu_lsu_rf_pipe5_src0),
        .idu_lsu_sdiq_sel             (idu_lsu_sdiq_sel),
        .idu_lsu_rf_pipe5_sdiq_entry  (idu_lsu_rf_pipe5_sdiq_entry),
        .rtu_yy_xx_flush              (rtu_yy_xx_flush),
        .rtu_yy_xx_commit0            (rtu_yy_xx_commit0),
        .rtu_yy_xx_commit0_iid        (rtu_yy_xx_commit0_iid),
        .rtu_yy_xx_commit1            (rtu_yy_xx_commit1),
        .rtu_yy_xx_commit1_iid        (rtu_yy_xx_commit1_iid),
        .rtu_yy_xx_commit2            (rtu_yy_xx_commit2),
        .rtu_yy_xx_commit2_iid        (rtu_yy_xx_commit2_iid),
        .rtu_lsu_async_flush          (rtu_lsu_async_flush),
        .forever_cpuclk               (forever_cpuclk),
        .cpurst_b                     (cpurst_b),
        .bus_arb_rb_ar_grnt           (bus_arb_rb_ar_grnt),
        .bus_arb_rb_ar_sel            (bus_arb_rb_ar_sel),
        .biu_lsu_r_data               (biu_lsu_r_data),
        .biu_lsu_r_id                 (biu_lsu_r_id),
        .biu_lsu_r_last               (biu_lsu_r_last),
        .biu_lsu_r_resp               (biu_lsu_r_resp),
        .biu_lsu_r_vld                (biu_lsu_r_vld),
        .biu_lsu_b_id                 (biu_lsu_b_id),
        .biu_lsu_b_resp               (biu_lsu_b_resp),
        .biu_lsu_b_vld                (biu_lsu_b_vld),
        .bus_arb_wmb_aw_grnt          (bus_arb_wmb_aw_grnt),
        .bus_arb_wmb_w_grnt           (bus_arb_wmb_w_grnt),
        .bus_arb_vb_aw_grnt           (bus_arb_vb_aw_grnt),
        .bus_arb_vb_w_grnt            (bus_arb_vb_w_grnt),
        .rb_biu_ar_addr               (rb_biu_ar_addr),
        .rb_biu_ar_bar                (rb_biu_ar_bar),
        .rb_biu_ar_burst              (rb_biu_ar_burst),
        .rb_biu_ar_cache              (rb_biu_ar_cache),
        .rb_biu_ar_domain             (rb_biu_ar_domain),
        .rb_biu_ar_id                 (rb_biu_ar_id),
        .rb_biu_ar_len                (rb_biu_ar_len),
        .rb_biu_ar_lock               (rb_biu_ar_lock),
        .rb_biu_ar_prot               (rb_biu_ar_prot),
        .rb_biu_ar_req                (rb_biu_ar_req),
        .rb_biu_ar_size               (rb_biu_ar_size),
        .rb_biu_ar_snoop              (rb_biu_ar_snoop),
        .rb_biu_ar_user               (rb_biu_ar_user),
        .wmb_biu_aw_addr              (wmb_biu_aw_addr),
        .wmb_biu_aw_bar               (wmb_biu_aw_bar),
        .wmb_biu_aw_burst             (wmb_biu_aw_burst),
        .wmb_biu_aw_cache             (wmb_biu_aw_cache),
        .wmb_biu_aw_domain            (wmb_biu_aw_domain),
        .wmb_biu_aw_id                (wmb_biu_aw_id),
        .wmb_biu_aw_len               (wmb_biu_aw_len),
        .wmb_biu_aw_lock              (wmb_biu_aw_lock),
        .wmb_biu_aw_prot              (wmb_biu_aw_prot),
        .wmb_biu_aw_req               (wmb_biu_aw_req),
        .wmb_biu_aw_size              (wmb_biu_aw_size),
        .wmb_biu_aw_snoop             (wmb_biu_aw_snoop),
        .wmb_biu_aw_user              (wmb_biu_aw_user),
        .wmb_biu_w_data               (wmb_biu_w_data),
        .wmb_biu_w_id                 (wmb_biu_w_id),
        .wmb_biu_w_req                (wmb_biu_w_req),
        .wmb_biu_w_strb               (wmb_biu_w_strb),
        .wmb_biu_w_vld                (wmb_biu_w_vld),
        .vb_biu_aw_addr               (vb_biu_aw_addr),
        .vb_biu_aw_burst              (vb_biu_aw_burst),
        .vb_biu_aw_cache              (vb_biu_aw_cache),
        .vb_biu_aw_id                 (vb_biu_aw_id),
        .vb_biu_aw_len                (vb_biu_aw_len),
        .vb_biu_aw_lock               (vb_biu_aw_lock),
        .vb_biu_aw_prot               (vb_biu_aw_prot),
        .vb_biu_aw_size               (vb_biu_aw_size),
        .vb_biu_aw_req                (vb_biu_aw_req),
        .vb_biu_w_data                (vb_biu_w_data),
        .vb_biu_w_id                  (vb_biu_w_id),
        .vb_biu_w_last                (vb_biu_w_last),
        .vb_biu_w_req                 (vb_biu_w_req),
        .vb_biu_w_strb                (vb_biu_w_strb),
        .vb_biu_w_vld                 (vb_biu_w_vld),
        .lsu_idu_imme_wakeup          (lsu_idu_imme_wakeup),
        .lsu_idu_pop_entry            (lsu_idu_pop_entry),
        .lsu_idu_secd                 (lsu_idu_secd),
        .lsu_idu_lq_full              (lsu_idu_lq_full),
        .lsu_idu_lq_not_full          (lsu_idu_lq_not_full),
        .lsu_idu_rb_full              (lsu_idu_rb_full),
        .lsu_idu_rb_not_full          (lsu_idu_rb_not_full),
        .lsu_idu_sq_full              (lsu_idu_sq_full),
        .lsu_idu_sq_not_full          (lsu_idu_sq_not_full),
        .lsu_idu_has_in_sq            (lsu_idu_has_in_sq),
        .lsu_rtu_wb_pipe3_cmplt       (lsu_rtu_wb_pipe3_cmplt),
        .lsu_rtu_wb_pipe3_iid         (lsu_rtu_wb_pipe3_iid),
        .lsu_rtu_wb_pipe3_wb_preg_expand (lsu_rtu_wb_pipe3_wb_preg_expand),
        .lsu_rtu_wb_pipe3_wb_preg_vld (lsu_rtu_wb_pipe3_wb_preg_vld),
        .lsu_idu_wb_pipe3_wb_preg     (lsu_idu_wb_pipe3_wb_preg),
        .lsu_idu_wb_pipe3_wb_preg_data (lsu_idu_wb_pipe3_wb_preg_data),
        .lsu_idu_wb_pipe3_wb_preg_expand (lsu_idu_wb_pipe3_wb_preg_expand),
        .lsu_idu_wb_pipe3_wb_preg_vld (lsu_idu_wb_pipe3_wb_preg_vld),
        .lsu_rtu_wb_pipe4_cmplt       (lsu_rtu_wb_pipe4_cmplt),
        .lsu_rtu_wb_pipe4_flush       (lsu_rtu_wb_pipe4_flush),
        .lsu_rtu_wb_pipe4_iid         (lsu_rtu_wb_pipe4_iid),
        .lsu_rtu_wb_pipe4_spec_fail   (lsu_rtu_wb_pipe4_spec_fail),
        .sq_data_depd_wakeup          (sq_data_depd_wakeup),
        .sq_global_depd_wakeup        (sq_global_depd_wakeup),
        .lfb_depd_wakeup              (lfb_depd_wakeup)
    );

    // ============ RTU 端口 (生成, 勿手改) ============
    logic                  cpu_clk;
    logic                  cpu_rst;
    logic [1:0]            ren_preg_req;
    logic [4:0]            ren_preg_req_lreg0;
    logic [4:0]            ren_preg_req_lreg1;
    logic [4:0]            ren_preg_req_lreg2;
    wire  [6:0]            rtu_preg_alloc0;
    wire  [6:0]            rtu_preg_alloc1;
    wire  [6:0]            rtu_preg_alloc2;
    wire                   rtu_preg_alloc_vld0;
    wire                   rtu_preg_alloc_vld1;
    wire                   rtu_preg_alloc_vld2;
    wire  [1:0]            rtu_preg_free_cnt;
    logic                  disp0_vld;
    logic [31:0]           disp0_pc;
    logic [24:0]           disp0_chk;
    logic [4:0]            disp0_dst_lreg;
    logic                  disp0_rf_we;
    logic [6:0]            disp0_dst_preg;
    logic [6:0]            disp0_old_preg;
    logic [6:0]            disp0_src1_preg;
    logic [11:0]           disp0_csr_addr;
    logic [2:0]            disp0_csr_op;
    logic [4:0]            disp0_csr_imm;
    logic [6:0]            disp0_flags;
    logic [2:0]            disp0_sq_id;
    logic                  disp1_vld;
    logic [31:0]           disp1_pc;
    logic [24:0]           disp1_chk;
    logic [4:0]            disp1_dst_lreg;
    logic                  disp1_rf_we;
    logic [6:0]            disp1_dst_preg;
    logic [6:0]            disp1_old_preg;
    logic [6:0]            disp1_src1_preg;
    logic [11:0]           disp1_csr_addr;
    logic [2:0]            disp1_csr_op;
    logic [4:0]            disp1_csr_imm;
    logic [6:0]            disp1_flags;
    logic [2:0]            disp1_sq_id;
    logic                  disp2_vld;
    logic [31:0]           disp2_pc;
    logic [24:0]           disp2_chk;
    logic [4:0]            disp2_dst_lreg;
    logic                  disp2_rf_we;
    logic [6:0]            disp2_dst_preg;
    logic [6:0]            disp2_old_preg;
    logic [6:0]            disp2_src1_preg;
    logic [11:0]           disp2_csr_addr;
    logic [2:0]            disp2_csr_op;
    logic [4:0]            disp2_csr_imm;
    logic [6:0]            disp2_flags;
    logic [2:0]            disp2_sq_id;
    logic                  cmplt_vld0;
    logic [6:0]            cmplt_iid0;
    logic                  cmplt_vld1;
    logic [6:0]            cmplt_iid1;
    logic                  cmplt_vld2;
    logic [6:0]            cmplt_iid2;
    logic                  cmplt_vld3;
    logic [6:0]            cmplt_iid3;
    logic                  cmplt_vld4;
    logic [6:0]            cmplt_iid4;
    logic                  cmplt_vld5;
    logic [6:0]            cmplt_iid5;
    logic                  cmplt_vld6;
    logic [6:0]            cmplt_iid6;
    logic                  resolve_vld;
    logic [6:0]            resolve_iid;
    logic                  resolve_taken;
    logic                  resolve_mispred;
    logic [31:0]           resolve_target;
    logic                  lsu_replay_vld;
    logic [6:0]            lsu_replay_iid;
    logic                  expt_vld;
    logic [6:0]            expt_iid;
    logic [4:0]            expt_cause;
    logic [31:0]           expt_tval;
    logic                  sq_rdy0;
    logic                  sq_rdy1;
    logic                  sq_rdy2;
    logic                  sq_stall;
    logic [31:0]           csr_rdata;
    logic                  int_pending;
    logic [63:0]           preg_dealloc_mask;
    logic                  beu_redirect_vld;
    logic [31:0]           preg_rdata0;
    logic [31:0]           preg_rdata1;
    logic [31:0]           preg_rdata2;
    logic [31:0]           rtu_csr_src_rdata;
    logic [31:0]           csr_trap_vector;
    logic [31:0]           csr_mepc;
    wire                   rtu_ifu_flush;
    wire                   rtu_ifu_chgflw_vld;
    wire  [31:0]           rtu_ifu_chgflw_pc;
    wire                   rtu_ifu_train_vld;
    wire  [31:0]           rtu_ifu_train_pc;
    wire  [31:0]           rtu_ifu_train_target;
    wire  [24:0]           rtu_ifu_train_chk;
    wire                   rtu_ifu_train_taken;
    wire                   rtu_ifu_train_is_cond;
    wire                   rtu_ifu_train_is_jal;
    wire                   rtu_ifu_train_is_jalr;
    wire                   rtu_backend_flush;
    wire                   rtu_core_redirect;
    wire  [6:0]            rtu_beu_retire_iid;
    wire                   rtu_beu_flush_chgflw_mask;
    wire                   rtu_disp_stall;
    wire                   rtu_ren_recover_vld;
    wire  [223:0]          rtu_ren_recover_map;
    wire                   rtu_ren_flush;
    wire  [6:0]            rtu_ren_free_preg0;
    wire  [6:0]            rtu_ren_free_preg1;
    wire  [6:0]            rtu_ren_free_preg2;
    wire                   rtu_ren_free_vld0;
    wire                   rtu_ren_free_vld1;
    wire                   rtu_ren_free_vld2;
    wire                   rtu_disp_vld0;
    wire                   rtu_disp_vld1;
    wire                   rtu_disp_vld2;
    wire  [6:0]            rtu_disp_iid0;
    wire  [6:0]            rtu_disp_iid1;
    wire  [6:0]            rtu_disp_iid2;
    wire  [6:0]            rtu_preg_raddr0;
    wire  [6:0]            rtu_preg_raddr1;
    wire  [6:0]            rtu_preg_raddr2;
    wire  [6:0]            rtu_csr_src_raddr;
    wire                   rtu_csr_rd_we;
    wire  [6:0]            rtu_csr_rd_addr;
    wire  [31:0]           rtu_csr_rd_wdata;
    wire                   rtu_store_vld0;
    wire                   rtu_store_vld1;
    wire                   rtu_store_vld2;
    wire  [2:0]            rtu_store_sq_id0;
    wire  [2:0]            rtu_store_sq_id1;
    wire  [2:0]            rtu_store_sq_id2;
    wire                   rtu_csr_we;
    wire  [11:0]           rtu_csr_addr;
    wire  [31:0]           rtu_csr_wdata;
    wire                   rtu_trap_vld;
    wire                   rtu_mret_vld;
    wire  [31:0]           rtu_trap_epc;
    wire  [31:0]           rtu_trap_tval;
    wire  [4:0]            rtu_trap_cause;
    wire  [1:0]            rtu_retire_cnt;
    wire                   dbg_commit_vld0;
    wire                   dbg_commit_vld1;
    wire                   dbg_commit_vld2;
    wire  [31:0]           dbg_commit_pc0;
    wire  [31:0]           dbg_commit_pc1;
    wire  [31:0]           dbg_commit_pc2;
    wire                   dbg_commit_ena0;
    wire                   dbg_commit_ena1;
    wire                   dbg_commit_ena2;
    wire  [4:0]            dbg_commit_reg0;
    wire  [4:0]            dbg_commit_reg1;
    wire  [4:0]            dbg_commit_reg2;
    wire  [31:0]           dbg_commit_value0;
    wire  [31:0]           dbg_commit_value1;
    wire  [31:0]           dbg_commit_value2;
    initial ren_preg_req = '0;
    initial ren_preg_req_lreg0 = '0;
    initial ren_preg_req_lreg1 = '0;
    initial ren_preg_req_lreg2 = '0;
    initial disp0_vld = 0;
    initial disp0_pc = '0;
    initial disp0_chk = '0;
    initial disp0_dst_lreg = '0;
    initial disp0_rf_we = 0;
    initial disp0_dst_preg = '0;
    initial disp0_old_preg = '0;
    initial disp0_src1_preg = '0;
    initial disp0_csr_addr = '0;
    initial disp0_csr_op = '0;
    initial disp0_csr_imm = '0;
    initial disp0_flags = '0;
    initial disp0_sq_id = '0;
    initial disp1_vld = 0;
    initial disp1_pc = '0;
    initial disp1_chk = '0;
    initial disp1_dst_lreg = '0;
    initial disp1_rf_we = 0;
    initial disp1_dst_preg = '0;
    initial disp1_old_preg = '0;
    initial disp1_src1_preg = '0;
    initial disp1_csr_addr = '0;
    initial disp1_csr_op = '0;
    initial disp1_csr_imm = '0;
    initial disp1_flags = '0;
    initial disp1_sq_id = '0;
    initial disp2_vld = 0;
    initial disp2_pc = '0;
    initial disp2_chk = '0;
    initial disp2_dst_lreg = '0;
    initial disp2_rf_we = 0;
    initial disp2_dst_preg = '0;
    initial disp2_old_preg = '0;
    initial disp2_src1_preg = '0;
    initial disp2_csr_addr = '0;
    initial disp2_csr_op = '0;
    initial disp2_csr_imm = '0;
    initial disp2_flags = '0;
    initial disp2_sq_id = '0;
    initial cmplt_vld0 = 0;
    initial cmplt_iid0 = '0;
    initial cmplt_vld1 = 0;
    initial cmplt_iid1 = '0;
    initial cmplt_vld2 = 0;
    initial cmplt_iid2 = '0;
    initial cmplt_vld3 = 0;
    initial cmplt_iid3 = '0;
    initial cmplt_vld4 = 0;
    initial cmplt_iid4 = '0;
    initial cmplt_vld5 = 0;
    initial cmplt_iid5 = '0;
    initial cmplt_vld6 = 0;
    initial cmplt_iid6 = '0;
    initial resolve_vld = 0;
    initial resolve_iid = '0;
    initial resolve_taken = 0;
    initial resolve_mispred = 0;
    initial resolve_target = '0;
    initial lsu_replay_iid = '0;
    initial expt_vld = 0;
    initial expt_iid = '0;
    initial expt_cause = '0;
    initial expt_tval = '0;
    initial sq_rdy0 = 0;
    initial sq_rdy1 = 0;
    initial sq_rdy2 = 0;
    initial sq_stall = 0;
    initial csr_rdata = '0;
    initial int_pending = 0;
    initial preg_dealloc_mask = '0;
    initial beu_redirect_vld = 0;
    initial preg_rdata0 = '0;
    initial preg_rdata1 = '0;
    initial preg_rdata2 = '0;
    initial rtu_csr_src_rdata = '0;
    initial csr_trap_vector = '0;
    initial csr_mepc = '0;

    RTU u_rtu (
        .cpu_clk                      (cpu_clk),
        .cpu_rst                      (cpu_rst),
        .ren_preg_req                 (ren_preg_req),
        .ren_preg_req_lreg0           (ren_preg_req_lreg0),
        .ren_preg_req_lreg1           (ren_preg_req_lreg1),
        .ren_preg_req_lreg2           (ren_preg_req_lreg2),
        .rtu_preg_alloc0              (rtu_preg_alloc0),
        .rtu_preg_alloc1              (rtu_preg_alloc1),
        .rtu_preg_alloc2              (rtu_preg_alloc2),
        .rtu_preg_alloc_vld0          (rtu_preg_alloc_vld0),
        .rtu_preg_alloc_vld1          (rtu_preg_alloc_vld1),
        .rtu_preg_alloc_vld2          (rtu_preg_alloc_vld2),
        .rtu_preg_free_cnt            (rtu_preg_free_cnt),
        .disp0_vld                    (disp0_vld),
        .disp0_pc                     (disp0_pc),
        .disp0_chk                    (disp0_chk),
        .disp0_dst_lreg               (disp0_dst_lreg),
        .disp0_rf_we                  (disp0_rf_we),
        .disp0_dst_preg               (disp0_dst_preg),
        .disp0_old_preg               (disp0_old_preg),
        .disp0_src1_preg              (disp0_src1_preg),
        .disp0_csr_addr               (disp0_csr_addr),
        .disp0_csr_op                 (disp0_csr_op),
        .disp0_csr_imm                (disp0_csr_imm),
        .disp0_flags                  (disp0_flags),
        .disp0_sq_id                  (disp0_sq_id),
        .disp1_vld                    (disp1_vld),
        .disp1_pc                     (disp1_pc),
        .disp1_chk                    (disp1_chk),
        .disp1_dst_lreg               (disp1_dst_lreg),
        .disp1_rf_we                  (disp1_rf_we),
        .disp1_dst_preg               (disp1_dst_preg),
        .disp1_old_preg               (disp1_old_preg),
        .disp1_src1_preg              (disp1_src1_preg),
        .disp1_csr_addr               (disp1_csr_addr),
        .disp1_csr_op                 (disp1_csr_op),
        .disp1_csr_imm                (disp1_csr_imm),
        .disp1_flags                  (disp1_flags),
        .disp1_sq_id                  (disp1_sq_id),
        .disp2_vld                    (disp2_vld),
        .disp2_pc                     (disp2_pc),
        .disp2_chk                    (disp2_chk),
        .disp2_dst_lreg               (disp2_dst_lreg),
        .disp2_rf_we                  (disp2_rf_we),
        .disp2_dst_preg               (disp2_dst_preg),
        .disp2_old_preg               (disp2_old_preg),
        .disp2_src1_preg              (disp2_src1_preg),
        .disp2_csr_addr               (disp2_csr_addr),
        .disp2_csr_op                 (disp2_csr_op),
        .disp2_csr_imm                (disp2_csr_imm),
        .disp2_flags                  (disp2_flags),
        .disp2_sq_id                  (disp2_sq_id),
        .cmplt_vld0                   (cmplt_vld0),
        .cmplt_iid0                   (cmplt_iid0),
        .cmplt_vld1                   (cmplt_vld1),
        .cmplt_iid1                   (cmplt_iid1),
        .cmplt_vld2                   (cmplt_vld2),
        .cmplt_iid2                   (cmplt_iid2),
        .cmplt_vld3                   (cmplt_vld3),
        .cmplt_iid3                   (cmplt_iid3),
        .cmplt_vld4                   (cmplt_vld4),
        .cmplt_iid4                   (cmplt_iid4),
        .cmplt_vld5                   (rt_cmplt_vld5),
        .cmplt_iid5                   (lsu_rtu_wb_pipe3_iid),
        .cmplt_vld6                   (rt_cmplt_vld6),
        .cmplt_iid6                   (lsu_rtu_wb_pipe4_iid),
        .resolve_vld                  (resolve_vld),
        .resolve_iid                  (resolve_iid),
        .resolve_taken                (resolve_taken),
        .resolve_mispred              (resolve_mispred),
        .resolve_target               (resolve_target),
        .lsu_replay_vld               (lsu_replay_vld),
        .lsu_replay_iid               (lsu_rtu_wb_pipe4_iid),
        .expt_vld                     (expt_vld),
        .expt_iid                     (expt_iid),
        .expt_cause                   (expt_cause),
        .expt_tval                    (expt_tval),
        .sq_rdy0                      (sq_rdy0),
        .sq_rdy1                      (sq_rdy1),
        .sq_rdy2                      (sq_rdy2),
        .sq_stall                     (sq_stall),
        .csr_rdata                    (csr_rdata),
        .int_pending                  (int_pending),
        .preg_dealloc_mask            (preg_dealloc_mask),
        .beu_redirect_vld             (beu_redirect_vld),
        .preg_rdata0                  (preg_rdata0),
        .preg_rdata1                  (preg_rdata1),
        .preg_rdata2                  (preg_rdata2),
        .rtu_csr_src_rdata            (rtu_csr_src_rdata),
        .csr_trap_vector              (csr_trap_vector),
        .csr_mepc                     (csr_mepc),
        .rtu_ifu_flush                (rtu_ifu_flush),
        .rtu_ifu_chgflw_vld           (rtu_ifu_chgflw_vld),
        .rtu_ifu_chgflw_pc            (rtu_ifu_chgflw_pc),
        .rtu_ifu_train_vld            (rtu_ifu_train_vld),
        .rtu_ifu_train_pc             (rtu_ifu_train_pc),
        .rtu_ifu_train_target         (rtu_ifu_train_target),
        .rtu_ifu_train_chk            (rtu_ifu_train_chk),
        .rtu_ifu_train_taken          (rtu_ifu_train_taken),
        .rtu_ifu_train_is_cond        (rtu_ifu_train_is_cond),
        .rtu_ifu_train_is_jal         (rtu_ifu_train_is_jal),
        .rtu_ifu_train_is_jalr        (rtu_ifu_train_is_jalr),
        .rtu_backend_flush            (rtu_backend_flush),
        .rtu_core_redirect            (rtu_core_redirect),
        .rtu_yy_xx_commit0            (rtu_yy_xx_commit0),
        .rtu_yy_xx_commit1            (rtu_yy_xx_commit1),
        .rtu_yy_xx_commit2            (rtu_yy_xx_commit2),
        .rtu_yy_xx_commit0_iid        (rtu_yy_xx_commit0_iid),
        .rtu_yy_xx_commit1_iid        (rtu_yy_xx_commit1_iid),
        .rtu_yy_xx_commit2_iid        (rtu_yy_xx_commit2_iid),
        .rtu_lsu_async_flush          (rtu_lsu_async_flush),
        .rtu_beu_retire_iid           (rtu_beu_retire_iid),
        .rtu_beu_flush_chgflw_mask    (rtu_beu_flush_chgflw_mask),
        .rtu_disp_stall               (rtu_disp_stall),
        .rtu_ren_recover_vld          (rtu_ren_recover_vld),
        .rtu_ren_recover_map          (rtu_ren_recover_map),
        .rtu_ren_flush                (rtu_ren_flush),
        .rtu_ren_free_preg0           (rtu_ren_free_preg0),
        .rtu_ren_free_preg1           (rtu_ren_free_preg1),
        .rtu_ren_free_preg2           (rtu_ren_free_preg2),
        .rtu_ren_free_vld0            (rtu_ren_free_vld0),
        .rtu_ren_free_vld1            (rtu_ren_free_vld1),
        .rtu_ren_free_vld2            (rtu_ren_free_vld2),
        .rtu_disp_vld0                (rtu_disp_vld0),
        .rtu_disp_vld1                (rtu_disp_vld1),
        .rtu_disp_vld2                (rtu_disp_vld2),
        .rtu_disp_iid0                (rtu_disp_iid0),
        .rtu_disp_iid1                (rtu_disp_iid1),
        .rtu_disp_iid2                (rtu_disp_iid2),
        .rtu_preg_raddr0              (rtu_preg_raddr0),
        .rtu_preg_raddr1              (rtu_preg_raddr1),
        .rtu_preg_raddr2              (rtu_preg_raddr2),
        .rtu_csr_src_raddr            (rtu_csr_src_raddr),
        .rtu_csr_rd_we                (rtu_csr_rd_we),
        .rtu_csr_rd_addr              (rtu_csr_rd_addr),
        .rtu_csr_rd_wdata             (rtu_csr_rd_wdata),
        .rtu_store_vld0               (rtu_store_vld0),
        .rtu_store_vld1               (rtu_store_vld1),
        .rtu_store_vld2               (rtu_store_vld2),
        .rtu_store_sq_id0             (rtu_store_sq_id0),
        .rtu_store_sq_id1             (rtu_store_sq_id1),
        .rtu_store_sq_id2             (rtu_store_sq_id2),
        .rtu_csr_we                   (rtu_csr_we),
        .rtu_csr_addr                 (rtu_csr_addr),
        .rtu_csr_wdata                (rtu_csr_wdata),
        .rtu_trap_vld                 (rtu_trap_vld),
        .rtu_mret_vld                 (rtu_mret_vld),
        .rtu_trap_epc                 (rtu_trap_epc),
        .rtu_trap_tval                (rtu_trap_tval),
        .rtu_trap_cause               (rtu_trap_cause),
        .rtu_retire_cnt               (rtu_retire_cnt),
        .dbg_commit_vld0              (dbg_commit_vld0),
        .dbg_commit_vld1              (dbg_commit_vld1),
        .dbg_commit_vld2              (dbg_commit_vld2),
        .dbg_commit_pc0               (dbg_commit_pc0),
        .dbg_commit_pc1               (dbg_commit_pc1),
        .dbg_commit_pc2               (dbg_commit_pc2),
        .dbg_commit_ena0              (dbg_commit_ena0),
        .dbg_commit_ena1              (dbg_commit_ena1),
        .dbg_commit_ena2              (dbg_commit_ena2),
        .dbg_commit_reg0              (dbg_commit_reg0),
        .dbg_commit_reg1              (dbg_commit_reg1),
        .dbg_commit_reg2              (dbg_commit_reg2),
        .dbg_commit_value0            (dbg_commit_value0),
        .dbg_commit_value1            (dbg_commit_value1),
        .dbg_commit_value2            (dbg_commit_value2)
    );

    // ============ 本台接线 (时钟 / 复位桥接 / 总线 grant / 重放或门) ============
    // ⚠️ 本台的 TB 内部信号**先声明** (VCS 对"先用后声明"直接报
    //    `Identifier has not been declared yet`, 不是退化成隐式线网 —— 但两种都别踩)
    logic        ld_inflight = 1'b0;   // 我们那条 load 在途 (激励置, 完成回报后清)
    logic [6:0]  ld_iid      = 7'd0;   // 它的 iid (派遣那拍从 rtu_disp_iid0 采回)

    // ⚠️ **时钟必须先接上** (2026-10-08 修): RTU 的时钟口叫 `cpu_clk`、LSU 的叫
    // `forever_cpuclk` (= lsu_top.sv:50 唯一的时钟输入), 两边都接本台的 `clk`。
    // 不接的后果见 NO_INIT 上面那段注释 (挂死 + 整条链根本没跑)。
    assign cpu_clk        = clk;
    assign forever_cpuclk = clk;
    // 复位: RTU 高有效、LSU 低有效 => 取反 (照 mySoC/ifu_subsys.v:111 的先例)
    assign cpu_rst  = rst;
    assign cpurst_b = ~rst;

    // ---- 完成口过闸 (只放行"我们自己派出去的那条"的完成) ----
    // 为什么需要: 见 RTU_CONN_OVERRIDE 上面的长注 (LSU 空闲时 pipe3_cmplt 上会有
    // iid 为垃圾的完成)。三个条件缺一不可:
    //   ① `ld_inflight` 我们这条在途 (激励置/清, 保证完成不会在窗口外漏进来);
    //   ② iid 相等 —— 尾段把 `lch_entry` 一直举着, AG 的 restart 环带的就是**我们**
    //      这条 (数据寄存器里锁的就是它), 所以"我们 iid 的完成"不会是别人的。
    assign rt_cmplt_vld5 = lsu_rtu_wb_pipe3_cmplt & ld_inflight
                                                & (lsu_rtu_wb_pipe3_iid == ld_iid);
    // 本台不造 store ⇒ store 完成口恒 0 (别让 st_wb 的相位信号假报完成)
    assign rt_cmplt_vld6 = 1'b0;
    // 总线仲裁: **与对应 req 同拍给 grant/sel** (不是"永远预授权") ——
    // 侦察结论: `sel` 与 `grnt` 必须同拍为高, LFB 地址表项才会建 (lsu_lfb.sv:277);
    // 而 grnt 还兼作 rb 表项的推进 (lsu_mshr_entry.sv:443)。本台不建模仲裁器,
    // 直接"有请求就授权"。
    assign bus_arb_rb_ar_grnt  = rb_biu_ar_req;
    assign bus_arb_rb_ar_sel   = rb_biu_ar_req;
    assign bus_arb_wmb_aw_grnt = wmb_biu_aw_req;
    assign bus_arb_wmb_w_grnt  = wmb_biu_w_req;
    assign bus_arb_vb_aw_grnt  = 1'b0;      // 本台不测 VB (victim buffer)
    assign bus_arb_vb_w_grnt   = 1'b0;
    // store 重放: LSU 的两根**或**起来送进 RTU (语义见 RTU 的端口注释)
    assign lsu_replay_vld = lsu_rtu_wb_pipe4_flush | lsu_rtu_wb_pipe4_spec_fail;
    // LSU 的冲刷口名字与 RTU 的不同名, 需要显式接 (其余 7 根同名, 靠连线自动对上)
    assign rtu_yy_xx_flush = rtu_backend_flush;
    // 释放否决掩码 (2026-10-08, 第 5 态): 本台**不建模** IDU 的 SDIQ, 由生成器
    // 统一给 `initial preg_dealloc_mask = '0` (即"没有任何号被 store 引用"), 所以
    // 这个台上的释放都是"挂一拍 RELEASE 就回池"。要测押住请用 rtu-unit 的
    // `+MASKDIR` / `+MASKPCT=n` —— 那里才有参考模型与判据。

    // ===================== 假 BIU (读通道) =====================
    // 契约 (侦察结论): 一次 burst **两拍** (32B 线 = 2×128bit, ar_len=01/ar_size=100),
    // `r_id` 必须与 AR 的 id **完全对上** (MSHR 表项按 id 命中 lsu_mshr_entry.sv:505,
    // LFB 按 id 的高 2 位 + 逐表项低 2 位), `r_resp=00` 否则数据被屏蔽。
    logic        biu_busy = 1'b0;
    integer      biu_cnt  = 0;
    logic [3:0]  biu_id;
    logic [31:0] biu_addr;

    always @(posedge clk) begin
        if (!biu_busy && rb_biu_ar_req) begin
            biu_busy <= 1'b1; biu_cnt <= 0;
            biu_id   <= rb_biu_ar_id; biu_addr <= rb_biu_ar_addr;
            $display("[%0t] *** AR 发出: addr=%08x id=%0d", $time, rb_biu_ar_addr, rb_biu_ar_id);
        end else if (biu_busy) begin
            biu_cnt <= biu_cnt + 1;
            if (biu_cnt >= 3) biu_busy <= 1'b0;
        end
    end

    assign biu_lsu_r_vld  = biu_busy && (biu_cnt >= 1) && (biu_cnt <= 2);
    assign biu_lsu_r_id   = biu_id;
    assign biu_lsu_r_last = (biu_cnt == 2);
    assign biu_lsu_r_resp = 2'b00;
    // 数据图案按地址 + 半线号编, 便于在波形/打印里认出来
    assign biu_lsu_r_data = {biu_addr[31:4], 4'h0, biu_cnt[0] ? 32'h2222_2222 : 32'h1111_1111,
                             biu_addr, 32'h0000_0000};

    // ===================== 刺激 =====================
    // ⚠️ `ld_iid` / `ld_inflight` 声明在生成段 (接线块) 里 —— 完成口过闸要用它们
    integer     i;
    integer     errs    = 0;          // 判据失败数 (收尾决定 PASS/FAIL)
    integer     n_ar    = 0;          // 看到的 AR 次数 (回填路径到底跑没跑)
    integer     n_pop   = 0;          // LSU 报 LSIQ 表项弹出的次数 (观察用)
    integer     n_cmt   = 0;          // 提交广播脉冲的次数 (锁存, 见下)
    logic [6:0] cmt_iid = 7'd0;       // 提交广播带的 iid (锁存)
    logic [1:0] ret_max = 2'd0;       // 退休计数的最大值 (锁存)
    logic       got_cmp = 1'b0;

    task automatic chk(input logic cond, input string msg);
        begin
            if (!cond) begin
                errs = errs + 1;
                $display("  *** FAIL: %0s", msg);
            end
        end
    endtask

    // ⚠️ 提交广播是**一拍脉冲** (退休窗口那一拍), 而完成与退休可能只差一拍 ——
    //    在激励里"先等完成、再等提交"会**擦肩而过**(实测踩过: 探针看见 commit0=1,
    //    而激励的第一步等待错过了它)。⇒ 脉冲类判据一律**边沿锁存**, 激励只等"锁存到过"。
    always @(posedge clk) begin
        if (rtu_yy_xx_commit0) begin
            n_cmt   <= n_cmt + 1;
            cmt_iid <= rtu_yy_xx_commit0_iid;
        end
        if (rtu_retire_cnt > ret_max) ret_max <= rtu_retire_cnt;
    end

    initial begin
        `ifdef DUMP
            $fsdbDumpfile("tb_rtu_lsu.fsdb");
            $fsdbDumpvars(0, tb_rtu_lsu);
        `endif
        repeat (4) @(negedge clk);
        rst = 0;
        repeat (10) @(negedge clk);
        $display("[%0t] 上电完成 (disp_stall=%b)", $time, rtu_disp_stall);

        // ---- 1) 往 RTU 派一条普通指令, 取它的 iid ----
        // ⚠️ 回执 `rtu_disp_iid0` = **当前的创造指针** (`RTU_ROB.v:326` 由 `cptr_oh` 组合
        //    译出), 所以它只在"**还没被采走**"的时候等于"这条的 iid": DUT 在下一个
        //    posedge 采 `disp0_vld` 并把指针推走, 推走之后口上就是**下一条**的号了。
        //    两种错法都踩过: ① 在 posedge 读 (阻塞赋值与指针更新同拍 ⇒ 读到旧值 0);
        //    ② 撤掉 vld 之后再读 (读到下一条的号 1)。两次都让发给 LSU 的 iid 与 RTU
        //    表项里的 iid 对不上 ⇒ 完成信号标不中表项 ⇒ 永远不退 (实测: occ=1、
        //    w0vld=1、完成回报的 iid 也在, 只有 w0cplt 起不来)。
        //    ⇒ 正确时机 = **举 vld 之前**、在负沿读 (组合值已落定, 指针还没动)。
        @(negedge clk);
        ld_iid     = rtu_disp_iid0;            // ← 此刻指针指着的这一格就是我们的
        disp0_vld = 1'b1; disp0_pc = 32'h0000_0100; disp0_dst_lreg = 5'd1; disp0_rf_we = 1'b1;
        disp0_dst_preg = 7'd9; disp0_old_preg = 7'd1; disp0_flags = 7'b0; disp0_chk = 25'h0;
        @(negedge clk);                        // 中间那个 posedge 已经把这条采进 ROB 了
        chk(rtu_disp_vld0, "派遣没被接受 (rtu_disp_vld0=0)");
        disp0_vld  = 1'b0;
        $display("[%0t] RTU 派了一条, iid=%0d (disp_vld0=1, 未接受则上面已报)", $time, ld_iid);

        // ---- 2) 拿**同一个** iid 把这条 load 发给 LSU ----
        // 口径照 **LSU 自己的单测台** (`tb/unit/lsu/tb_lsu_load_test.sv:404-433`):
        //   `ld_sel` 只举**一拍**, 而 `lch_entry` (LSIQ 表项号) **一直举着** ——
        //   真 IDU 就是"表项有效直到 LSU 报弹出"这么维护的。实测: 把 `ld_sel` 举住不放
        //   会让 AG 每拍都重新锁存这条 (`lsu_ld_ag.sv:191-198` 的
        //   `inst_vld <= (stall_ori && !ld_sel) || ld_sel`), 反而更慢。
        // ⚠️ 完成口的闸门 (`rt_cmplt_vld5`) 要求"我们这条在途 + iid 相等": LSU 的 load AG
        //   在"没人给它指令"时会自由跑一个 restart 环, 于是 `pipe3_cmplt` 上**从复位起
        //   就周期性出现 iid 为垃圾的完成**。本台没有 IDU, 就只能自己过这道闸。
        // ⚠️ oldest=0: 为 1 时 ld_dc_lq_create_vld 恒 0 (LQ 不建表项)。
        ld_inflight = 1'b1;                    // 闸门 (见接线块)
        idu_lsu_ld_sel         <= 1'b1;
        idu_lsu_ld_inst_size   <= 2'b10;       // word
        idu_lsu_ld_sign_extend <= 1'b1;
        idu_lsu_ld_unalign_2nd <= 1'b0;
        idu_lsu_ld_iid         <= ld_iid;
        idu_lsu_ld_oldest      <= 1'b0;
        idu_lsu_ld_preg        <= 6'd1;
        idu_lsu_ld_lch_entry   <= 8'h01;       // LSIQ 表项 one-hot (现在 8 项)
        idu_lsu_ld_offset      <= 12'h0;
        idu_lsu_ld_offset_plus <= 13'h10;
        idu_lsu_ld_src         <= 32'h0000_1000;   // 基址 -> 实际地址 0x1000
        @(negedge clk);
        idu_lsu_ld_sel         <= 1'b0;        // 只举一拍 (表项号继续举着)

        // ---- 3) 等完成回报 (带看门狗), 顺路记回填 (AR) 与表项弹出 ----
        // 原来这里是 `fork ... join_any` 且**没有超时** ⇒ LSU 不动就永久挂死, 而日志上
        // 什么都看不出来。现在是有界等待 + 判据。
        // ⚠️ 8000 拍这个上界是**实测**来的: 本环境里这条 load 走完 LSU 要 ~4000 拍
        //    (DC 级反复重试; 那期间 `ld_dc_dcache_hit`/`_valid*` 一直是 X —— 本台不预置
        //    DCache 状态)。**LSU 自己的单测台只等 2000 拍**, 所以它现在也报
        //    "Timeout waiting for first AR request" —— 同一个现象, 不是本台特有的。
        for (i = 0; i < 8000; i = i + 1) begin
            @(negedge clk);
            if (rb_biu_ar_req)       n_ar  = n_ar  + 1;
            if (lsu_idu_pop_entry[0]) n_pop = n_pop + 1;
            if (lsu_rtu_wb_pipe3_cmplt && (lsu_rtu_wb_pipe3_iid === ld_iid)) begin
                got_cmp = 1'b1;
                break;
            end
        end
        chk(i < 8000, "8000 拍内没等到这条 load 的完成回报 (lsu_rtu_wb_pipe3_cmplt)");
        if (got_cmp)
            $display("[%0t] *** load 完成回报: iid=%0d (AR/回填 %0d 次, 表项弹出 %0d 次)",
                     $time, ld_iid, n_ar, n_pop);
        idu_lsu_ld_lch_entry <= 8'h00;

        // ⚠️ 提交广播可能**就在完成回报的下一拍** —— 所以这里只用边沿锁存下来的计数,
        //    不要在激励里"等脉冲" (会擦肩而过)。
        for (i = 0; i < 200; i = i + 1) begin
            @(negedge clk);
            if (n_cmt > 0) break;
        end
        chk(n_cmt > 0, "200 拍内没等到提交广播 (rtu_yy_xx_commit0)");
        chk(cmt_iid === ld_iid,
            $sformatf("提交广播的 iid=%0d, 期望 %0d", cmt_iid, ld_iid));
        chk(ret_max >= 2'd1, "退休计数没动 (rtu_retire_cnt=0)");
        ld_inflight = 1'b0;                    // 关闸

        // ---- 4) 结论 ----
        // ⚠️ 本台只造 **load**, 两处没覆盖, 别当成已经好了:
        //    * **store 那一半** (SDIQ 数据握手 → SQ 表项 cmit): 要真 IDU 的 SDIQ 读口配合;
        //    * **AR / 回填路径**: 本环境里没发过 AR (LSU 自己的台也一样, 见上)。
        $display("  链路: 派遣(iid=%0d) → load 完成 → 退休 %0d 条 → 提交广播 iid=%0d | AR %0d 次, 表项弹出 %0d 次",
                 ld_iid, ret_max, cmt_iid, n_ar, n_pop);
        if ((n_ar == 0) && (n_pop == 0)) begin
            $display("  ⚠️ LSU 全程 AR 0 次、LSIQ 表项弹出 0 次 ⇒ **本台没证明 LSU 处理了这条 load**:");
            $display("     上面那条完成是在举上激励后 1~2 拍就来的, 更像 LSU 空闲 restart 环吐出来的");
            $display("     那一条 (恰好带着我们的 iid)。本台钉住的是 **RTU 侧**那条链:");
            $display("     完成 → 退休 → 提交广播带对 iid。");
        end
        if (errs == 0) $display("  RTU-LSU UNIT: ALL PASS");
        else           $fatal(1, "rtu-lsu unit test failed: %0d 条判据不成立", errs);
        $finish;
    end

endmodule
