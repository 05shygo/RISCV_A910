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
    initial forever_cpuclk = 0;
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
    initial cpu_clk = 0;
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
        .cmplt_vld5                   (lsu_rtu_wb_pipe3_cmplt),
        .cmplt_iid5                   (lsu_rtu_wb_pipe3_iid),
        .cmplt_vld6                   (lsu_rtu_wb_pipe4_cmplt),
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

    // ============ 本台接线 (复位桥接 / 总线 grant / 重放或门) ============
    // 复位: RTU 高有效、LSU 低有效 => 取反 (照 mySoC/ifu_subsys.v:111 的先例)
    assign cpu_rst  = rst;
    assign cpurst_b = ~rst;
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
    logic [6:0] ld_iid;
    integer     i;

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
        disp0_vld = 1'b1; disp0_pc = 32'h0000_0100; disp0_dst_lreg = 5'd1; disp0_rf_we = 1'b1;
        disp0_dst_preg = 7'd9; disp0_old_preg = 7'd1; disp0_flags = 7'b0; disp0_chk = 25'h0;
        @(negedge clk);
        disp0_vld = 1'b0;
        @(posedge clk); ld_iid = rtu_disp_iid0;          // 派遣回执 = 这条的 iid
        $display("[%0t] RTU 派了一条, iid=%0d (disp_vld0=%b)", $time, ld_iid, rtu_disp_vld0);

        // ---- 2) 拿同一个 iid 把这条 load 发给 LSU ----
        // ⚠️ 激励要**举住**直到 ld_ag_inst_vld (空闲时它自振荡, 相位 50/50, 举一拍可能刚好
        //    落在 stall 相位上, 载荷寄存器一个都不锁)。
        // ⚠️ oldest=0: 为 1 时 ld_dc_lq_create_vld 恒 0 (LQ 不建表项)。
        idu_lsu_ld_sel         <= 1'b1;
        idu_lsu_ld_inst_size   <= 2'b10;      // word
        idu_lsu_ld_sign_extend <= 1'b1;
        idu_lsu_ld_unalign_2nd <= 1'b0;
        idu_lsu_ld_iid         <= ld_iid;
        idu_lsu_ld_oldest      <= 1'b0;
        idu_lsu_ld_preg        <= 6'd1;
        idu_lsu_ld_lch_entry   <= 8'h01;      // LSIQ 表项 one-hot (现在 8 项)
        idu_lsu_ld_offset      <= 12'h0;
        idu_lsu_ld_offset_plus <= 13'h10;
        idu_lsu_ld_src         <= 32'h0000_1000;   // 基址 -> 实际地址 0x1000
        // 举 3 拍 (AG 的 vld 空闲时每 2 拍翻一次, 3 拍必覆盖到可接收的那一拍;
        // 再长会重复注入, 这里只要命中最少一次)
        repeat (3) @(negedge clk);
        idu_lsu_ld_sel <= 1'b0;
        $display("[%0t] load 激励撤掉 (举了 3 拍)", $time);

        // ---- 3) 等 AR -> 数据回 -> 完成回报 ----
        fork
            begin : w_ar
                wait (rb_biu_ar_req);
                $display("[%0t] *** AR! addr=%08x", $time, rb_biu_ar_addr);
            end
            begin : w_cmplt
                wait (lsu_rtu_wb_pipe3_cmplt);
                $display("[%0t] *** load 完成回报: iid=%0d", $time, lsu_rtu_wb_pipe3_iid);
            end
        join_any
        disable fork;

        // ---- 4) 观察 RTU 的提交广播 ----
        repeat (40) @(negedge clk);
        $display("[%0t] 观察结束 (commit0=%b iid=%0d | retire_cnt=%0d)",
                 $time, rtu_yy_xx_commit0, rtu_yy_xx_commit0_iid, rtu_retire_cnt);
        $finish;
    end

endmodule
