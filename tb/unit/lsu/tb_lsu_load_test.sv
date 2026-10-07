`timescale 1ns/1ps

module tb_lsu_load_test;

// Parameters
localparam DCACHE_SIZE      = 2048;
localparam LSIQ_ENTRY       = 12;
localparam SQ_ENTRY         = 6;
localparam SDIQ_ENTRY       = 4;
localparam WMB_ENTRY        = 4;
localparam LFB_ADDR_ENTRY   = 3;
localparam LFB_DATA_ENTRY   = 1;

// Clock and reset
logic clk;
logic rst_n;

// IDU to LSU - Load interface
logic                 idu_lsu_ld_sel;
logic [1:0]           idu_lsu_ld_inst_size;
logic                 idu_lsu_ld_unalign_2nd;
logic                 idu_lsu_ld_sign_extend;
logic [6:0]           idu_lsu_ld_iid;
logic [LSIQ_ENTRY-1:0] idu_lsu_ld_lch_entry;
logic                 idu_lsu_ld_oldest;
logic [6:0]           idu_lsu_ld_preg;
logic [11:0]          idu_lsu_ld_offset;
logic [12:0]          idu_lsu_ld_offset_plus;
logic [31:0]          idu_lsu_ld_src;

// IDU to LSU - Store interface
logic                 idu_lsu_st_sel;
logic [1:0]           idu_lsu_st_inst_size;
logic                 idu_lsu_st_unalign_2nd;
logic [6:0]           idu_lsu_st_iid;
logic [LSIQ_ENTRY-1:0] idu_lsu_st_lch_entry;
logic [SDIQ_ENTRY-1:0] idu_lsu_st_sdiq_entry;
logic                 idu_lsu_st_oldest;
logic [11:0]          idu_lsu_st_offset;
logic [12:0]          idu_lsu_st_offset_plus;
logic [31:0]          idu_lsu_st_src0;

logic [31:0]          idu_lsu_rf_pipe5_src0;
logic                 idu_lsu_sdiq_sel;
logic [3:0]           idu_lsu_rf_pipe5_sdiq_entry;

// RTU interface
logic                 rtu_yy_xx_flush;
logic                 rtu_yy_xx_commit0;
logic [6:0]           rtu_yy_xx_commit0_iid;
logic                 rtu_yy_xx_commit1;
logic [6:0]           rtu_yy_xx_commit1_iid;
logic                 rtu_yy_xx_commit2;
logic [6:0]           rtu_yy_xx_commit2_iid;
logic                 rtu_lsu_async_flush;

// BIU read interface
logic                 bus_arb_rb_ar_grnt;
logic                 bus_arb_rb_ar_sel;
logic [127:0]         biu_lsu_r_data;
logic [3:0]           biu_lsu_r_id;
logic                 biu_lsu_r_last;
logic [1:0]           biu_lsu_r_resp;
logic                 biu_lsu_r_vld;

// BIU write response interface
logic [3:0]           biu_lsu_b_id;
logic [1:0]           biu_lsu_b_resp;
logic                 biu_lsu_b_vld;

// BIU write grant
logic                 bus_arb_wmb_aw_grnt;
logic                 bus_arb_wmb_w_grnt;
logic                 bus_arb_vb_aw_grnt;
logic                 bus_arb_vb_w_grnt;

// LSU to BIU - Read request outputs
logic [31:0]          rb_biu_ar_addr;
logic [1:0]           rb_biu_ar_bar;
logic [1:0]           rb_biu_ar_burst;
logic [3:0]           rb_biu_ar_cache;
logic [1:0]           rb_biu_ar_domain;
logic [3:0]           rb_biu_ar_id;
logic [1:0]           rb_biu_ar_len;
logic                 rb_biu_ar_lock;
logic [2:0]           rb_biu_ar_prot;
logic                 rb_biu_ar_req;
logic [2:0]           rb_biu_ar_size;
logic [3:0]           rb_biu_ar_snoop;
logic                 rb_biu_ar_user;

// LSU to BIU - Write request outputs (WMB)
logic [31:0]          wmb_biu_aw_addr;
logic [1:0]           wmb_biu_aw_bar;
logic [1:0]           wmb_biu_aw_burst;
logic [3:0]           wmb_biu_aw_cache;
logic [1:0]           wmb_biu_aw_domain;
logic [3:0]           wmb_biu_aw_id;
logic [1:0]           wmb_biu_aw_len;
logic                 wmb_biu_aw_lock;
logic [2:0]           wmb_biu_aw_prot;
logic                 wmb_biu_aw_req;
logic [2:0]           wmb_biu_aw_size;
logic [2:0]           wmb_biu_aw_snoop;
logic                 wmb_biu_aw_user;
logic [127:0]         wmb_biu_w_data;
logic [3:0]           wmb_biu_w_id;
logic                 wmb_biu_w_req;
logic [15:0]          wmb_biu_w_strb;
logic                 wmb_biu_w_vld;

// LSU to BIU - Write request outputs (VB)
logic [31:0]          vb_biu_aw_addr;
logic [1:0]           vb_biu_aw_burst;
logic [3:0]           vb_biu_aw_cache;
logic [3:0]           vb_biu_aw_id;
logic [1:0]           vb_biu_aw_len;
logic                 vb_biu_aw_lock;
logic [2:0]           vb_biu_aw_prot;
logic [2:0]           vb_biu_aw_size;
logic                 vb_biu_aw_req;
logic [127:0]         vb_biu_w_data;
logic [3:0]           vb_biu_w_id;
logic                 vb_biu_w_last;
logic                 vb_biu_w_req;
logic [15:0]          vb_biu_w_strb;
logic                 vb_biu_w_vld;

// LSU to IDU - Load queue status
logic [LSIQ_ENTRY-1:0] lsu_idu_imme_wakeup;
logic [LSIQ_ENTRY-1:0] lsu_idu_pop_entry;
logic [LSIQ_ENTRY-1:0] lsu_idu_secd;
logic [LSIQ_ENTRY-1:0] lsu_idu_lq_full;
logic                  lsu_idu_lq_not_full;
logic [LSIQ_ENTRY-1:0] lsu_idu_rb_full;
logic                  lsu_idu_rb_not_full;
logic [LSIQ_ENTRY-1:0] lsu_idu_sq_full;
logic                  lsu_idu_sq_not_full;
logic [SDIQ_ENTRY-1:0] lsu_idu_has_in_sq;

// LSU to RTU - Writeback pipe3
logic                  lsu_rtu_wb_pipe3_cmplt;
logic [6:0]            lsu_rtu_wb_pipe3_iid;
logic [95:0]           lsu_rtu_wb_pipe3_wb_preg_expand;
logic                  lsu_rtu_wb_pipe3_wb_preg_vld;

// LSU to IDU - Writeback pipe3
logic [6:0]            lsu_idu_wb_pipe3_wb_preg;
logic [31:0]           lsu_idu_wb_pipe3_wb_preg_data;
logic [95:0]           lsu_idu_wb_pipe3_wb_preg_expand;
logic                  lsu_idu_wb_pipe3_wb_preg_vld;

// LSU to RTU - Writeback pipe4
logic                  lsu_rtu_wb_pipe4_cmplt;
logic                  lsu_rtu_wb_pipe4_flush;
logic [6:0]            lsu_rtu_wb_pipe4_iid;
logic                  lsu_rtu_wb_pipe4_spec_fail;

// Store queue wakeup
logic [LSIQ_ENTRY-1:0] sq_data_depd_wakeup;
logic [LSIQ_ENTRY-1:0] sq_global_depd_wakeup;

// LFB dependency wakeup
logic [LSIQ_ENTRY-1:0] lfb_depd_wakeup;

// 辅助变量
logic [3:0] ar_id1, ar_id2;

// Instantiate DUT
lsu_top #(
  .DCACHE_SIZE     (DCACHE_SIZE),
  .LSIQ_ENTRY      (LSIQ_ENTRY),
  .SQ_ENTRY        (SQ_ENTRY),
  .SDIQ_ENTRY      (SDIQ_ENTRY),
  .WMB_ENTRY       (WMB_ENTRY),
  .LFB_ADDR_ENTRY  (LFB_ADDR_ENTRY),
  .LFB_DATA_ENTRY  (LFB_DATA_ENTRY)
) u_lsu_top (
  // IDU to LSU - Load interface
  .idu_lsu_ld_sel          (idu_lsu_ld_sel),
  .idu_lsu_ld_inst_size    (idu_lsu_ld_inst_size),
  .idu_lsu_ld_unalign_2nd  (idu_lsu_ld_unalign_2nd),
  .idu_lsu_ld_sign_extend  (idu_lsu_ld_sign_extend),
  .idu_lsu_ld_iid          (idu_lsu_ld_iid),
  .idu_lsu_ld_lch_entry    (idu_lsu_ld_lch_entry),
  .idu_lsu_ld_oldest       (idu_lsu_ld_oldest),
  .idu_lsu_ld_preg         (idu_lsu_ld_preg),
  .idu_lsu_ld_offset       (idu_lsu_ld_offset),
  .idu_lsu_ld_offset_plus  (idu_lsu_ld_offset_plus),
  .idu_lsu_ld_src          (idu_lsu_ld_src),

  // IDU to LSU - Store interface
  .idu_lsu_st_sel          (idu_lsu_st_sel),
  .idu_lsu_st_inst_size    (idu_lsu_st_inst_size),
  .idu_lsu_st_unalign_2nd  (idu_lsu_st_unalign_2nd),
  .idu_lsu_st_iid          (idu_lsu_st_iid),
  .idu_lsu_st_lch_entry    (idu_lsu_st_lch_entry),
  .idu_lsu_st_sdiq_entry   (idu_lsu_st_sdiq_entry),
  .idu_lsu_st_oldest       (idu_lsu_st_oldest),
  .idu_lsu_st_offset       (idu_lsu_st_offset),
  .idu_lsu_st_offset_plus  (idu_lsu_st_offset_plus),
  .idu_lsu_st_src0         (idu_lsu_st_src0),

  .idu_lsu_rf_pipe5_src0       (idu_lsu_rf_pipe5_src0),
  .idu_lsu_sdiq_sel            (idu_lsu_sdiq_sel),
  .idu_lsu_rf_pipe5_sdiq_entry (idu_lsu_rf_pipe5_sdiq_entry),

  // RTU interface
  .rtu_yy_xx_flush         (rtu_yy_xx_flush),
  .rtu_yy_xx_commit0       (rtu_yy_xx_commit0),
  .rtu_yy_xx_commit0_iid   (rtu_yy_xx_commit0_iid),
  .rtu_yy_xx_commit1       (rtu_yy_xx_commit1),
  .rtu_yy_xx_commit1_iid   (rtu_yy_xx_commit1_iid),
  .rtu_yy_xx_commit2       (rtu_yy_xx_commit2),
  .rtu_yy_xx_commit2_iid   (rtu_yy_xx_commit2_iid),
  .rtu_lsu_async_flush     (rtu_lsu_async_flush),

  // Clock and reset
  .forever_cpuclk             (clk),
  .cpurst_b                (rst_n),

  // BIU read interface
  .bus_arb_rb_ar_grnt      (bus_arb_rb_ar_grnt),
  .bus_arb_rb_ar_sel       (bus_arb_rb_ar_sel),
  .biu_lsu_r_data          (biu_lsu_r_data),
  .biu_lsu_r_id            (biu_lsu_r_id),
  .biu_lsu_r_last          (biu_lsu_r_last),
  .biu_lsu_r_resp          (biu_lsu_r_resp),
  .biu_lsu_r_vld           (biu_lsu_r_vld),

  // BIU write response interface
  .biu_lsu_b_id            (biu_lsu_b_id),
  .biu_lsu_b_resp          (biu_lsu_b_resp),
  .biu_lsu_b_vld           (biu_lsu_b_vld),

  // BIU write address grant
  .bus_arb_wmb_aw_grnt     (bus_arb_wmb_aw_grnt),
  .bus_arb_wmb_w_grnt      (bus_arb_wmb_w_grnt),
  .bus_arb_vb_aw_grnt      (bus_arb_vb_aw_grnt),
  .bus_arb_vb_w_grnt       (bus_arb_vb_w_grnt),

  // LSU to BIU - Read address request (RB)
  .rb_biu_ar_addr          (rb_biu_ar_addr),
  .rb_biu_ar_bar           (rb_biu_ar_bar),
  .rb_biu_ar_burst         (rb_biu_ar_burst),
  .rb_biu_ar_cache         (rb_biu_ar_cache),
  .rb_biu_ar_domain        (rb_biu_ar_domain),
  .rb_biu_ar_id            (rb_biu_ar_id),
  .rb_biu_ar_len           (rb_biu_ar_len),
  .rb_biu_ar_lock          (rb_biu_ar_lock),
  .rb_biu_ar_prot          (rb_biu_ar_prot),
  .rb_biu_ar_req           (rb_biu_ar_req),
  .rb_biu_ar_size          (rb_biu_ar_size),
  .rb_biu_ar_snoop         (rb_biu_ar_snoop),
  .rb_biu_ar_user          (rb_biu_ar_user),

  // LSU to BIU - Write address/data request (WMB)
  .wmb_biu_aw_addr         (wmb_biu_aw_addr),
  .wmb_biu_aw_bar          (wmb_biu_aw_bar),
  .wmb_biu_aw_burst        (wmb_biu_aw_burst),
  .wmb_biu_aw_cache        (wmb_biu_aw_cache),
  .wmb_biu_aw_domain       (wmb_biu_aw_domain),
  .wmb_biu_aw_id           (wmb_biu_aw_id),
  .wmb_biu_aw_len          (wmb_biu_aw_len),
  .wmb_biu_aw_lock         (wmb_biu_aw_lock),
  .wmb_biu_aw_prot         (wmb_biu_aw_prot),
  .wmb_biu_aw_req          (wmb_biu_aw_req),
  .wmb_biu_aw_size         (wmb_biu_aw_size),
  .wmb_biu_aw_snoop        (wmb_biu_aw_snoop),
  .wmb_biu_aw_user         (wmb_biu_aw_user),
  .wmb_biu_w_data          (wmb_biu_w_data),
  .wmb_biu_w_id            (wmb_biu_w_id),
  .wmb_biu_w_req           (wmb_biu_w_req),
  .wmb_biu_w_strb          (wmb_biu_w_strb),
  .wmb_biu_w_vld           (wmb_biu_w_vld),

  // LSU to BIU - Write address/data request (VB)
  .vb_biu_aw_addr          (vb_biu_aw_addr),
  .vb_biu_aw_burst         (vb_biu_aw_burst),
  .vb_biu_aw_cache         (vb_biu_aw_cache),
  .vb_biu_aw_id            (vb_biu_aw_id),
  .vb_biu_aw_len           (vb_biu_aw_len),
  .vb_biu_aw_lock          (vb_biu_aw_lock),
  .vb_biu_aw_prot          (vb_biu_aw_prot),
  .vb_biu_aw_size          (vb_biu_aw_size),
  .vb_biu_aw_req           (vb_biu_aw_req),
  .vb_biu_w_data           (vb_biu_w_data),
  .vb_biu_w_id             (vb_biu_w_id),
  .vb_biu_w_last           (vb_biu_w_last),
  .vb_biu_w_req            (vb_biu_w_req),
  .vb_biu_w_strb           (vb_biu_w_strb),
  .vb_biu_w_vld            (vb_biu_w_vld),

  // LSU to IDU - Load queue status
  .lsu_idu_imme_wakeup     (lsu_idu_imme_wakeup),
  .lsu_idu_pop_entry       (lsu_idu_pop_entry),
  .lsu_idu_secd            (lsu_idu_secd),
  .lsu_idu_lq_full         (lsu_idu_lq_full),
  .lsu_idu_lq_not_full     (lsu_idu_lq_not_full),
  .lsu_idu_rb_full         (lsu_idu_rb_full),
  .lsu_idu_rb_not_full     (lsu_idu_rb_not_full),
  .lsu_idu_sq_full         (lsu_idu_sq_full),
  .lsu_idu_sq_not_full     (lsu_idu_sq_not_full),
  .lsu_idu_has_in_sq       (lsu_idu_has_in_sq),

  // LSU to RTU - Writeback pipe3
  .lsu_rtu_wb_pipe3_cmplt          (lsu_rtu_wb_pipe3_cmplt),
  .lsu_rtu_wb_pipe3_iid            (lsu_rtu_wb_pipe3_iid),
  .lsu_rtu_wb_pipe3_wb_preg_expand (lsu_rtu_wb_pipe3_wb_preg_expand),
  .lsu_rtu_wb_pipe3_wb_preg_vld    (lsu_rtu_wb_pipe3_wb_preg_vld),

  // LSU to IDU - Writeback pipe3
  .lsu_idu_wb_pipe3_wb_preg         (lsu_idu_wb_pipe3_wb_preg),
  .lsu_idu_wb_pipe3_wb_preg_data    (lsu_idu_wb_pipe3_wb_preg_data),
  .lsu_idu_wb_pipe3_wb_preg_expand  (lsu_idu_wb_pipe3_wb_preg_expand),
  .lsu_idu_wb_pipe3_wb_preg_vld     (lsu_idu_wb_pipe3_wb_preg_vld),

  // LSU to RTU - Writeback pipe4
  .lsu_rtu_wb_pipe4_cmplt      (lsu_rtu_wb_pipe4_cmplt),
  .lsu_rtu_wb_pipe4_flush      (lsu_rtu_wb_pipe4_flush),
  .lsu_rtu_wb_pipe4_iid        (lsu_rtu_wb_pipe4_iid),
  .lsu_rtu_wb_pipe4_spec_fail  (lsu_rtu_wb_pipe4_spec_fail),

  // Store queue wakeup
  .sq_data_depd_wakeup         (sq_data_depd_wakeup),
  .sq_global_depd_wakeup       (sq_global_depd_wakeup),

  // LFB dependency wakeup
  .lfb_depd_wakeup             (lfb_depd_wakeup)
);

// Clock generation
initial begin
  clk = 0;
  forever #5 clk = ~clk;
end

// Test stimulus
initial begin
  // 初始化所有输入
  rst_n = 0;

  idu_lsu_ld_sel          = 0;
  idu_lsu_ld_inst_size    = 0;
  idu_lsu_ld_unalign_2nd  = 0;
  idu_lsu_ld_sign_extend  = 0;
  idu_lsu_ld_iid          = 0;
  idu_lsu_ld_lch_entry    = 0;
  idu_lsu_ld_oldest       = 0;
  idu_lsu_ld_preg         = 0;
  idu_lsu_ld_offset       = 0;
  idu_lsu_ld_offset_plus  = 0;
  idu_lsu_ld_src          = 0;

  idu_lsu_st_sel          = 0;
  idu_lsu_st_inst_size    = 0;
  idu_lsu_st_unalign_2nd  = 0;
  idu_lsu_st_iid          = 0;
  idu_lsu_st_lch_entry    = 0;
  idu_lsu_st_sdiq_entry   = 0;
  idu_lsu_st_oldest       = 0;
  idu_lsu_st_offset       = 0;
  idu_lsu_st_offset_plus  = 0;
  idu_lsu_st_src0         = 0;

  idu_lsu_rf_pipe5_src0       = 0;
  idu_lsu_sdiq_sel            = 0;
  idu_lsu_rf_pipe5_sdiq_entry = 0;

  rtu_yy_xx_flush         = 0;
  rtu_yy_xx_commit0       = 0;
  rtu_yy_xx_commit0_iid   = 0;
  rtu_yy_xx_commit1       = 0;
  rtu_yy_xx_commit1_iid   = 0;
  rtu_yy_xx_commit2       = 0;
  rtu_yy_xx_commit2_iid   = 0;
  rtu_lsu_async_flush     = 0;

  bus_arb_rb_ar_grnt      = 1;
  bus_arb_rb_ar_sel       = 1;
  biu_lsu_r_data          = 0;
  biu_lsu_r_id            = 0;
  biu_lsu_r_last          = 0;
  biu_lsu_r_resp          = 0;
  biu_lsu_r_vld           = 0;

  biu_lsu_b_id            = 0;
  biu_lsu_b_resp          = 0;
  biu_lsu_b_vld           = 0;

  bus_arb_wmb_aw_grnt     = 1;
  bus_arb_wmb_w_grnt      = 1;
  bus_arb_vb_aw_grnt      = 1;
  bus_arb_vb_w_grnt       = 1;

  // 复位
  repeat(10) @(posedge clk);
  rst_n = 1;
  repeat(5) @(posedge clk);

  $display("=== Test: Two Load Requests ===");

  // ------------------------------------------------------------
  // 第一个 Load 请求
  // ------------------------------------------------------------
  @(posedge clk);
  #1;  // 添加小延迟确保在时钟上升沿后设置信号
  idu_lsu_ld_sel          = 1;
  idu_lsu_ld_inst_size    = 2'b10;      // Word load
  idu_lsu_ld_unalign_2nd  = 0;
  idu_lsu_ld_sign_extend  = 0;
  idu_lsu_ld_iid          = 7'h01;
  idu_lsu_ld_lch_entry    = 12'h001;
  idu_lsu_ld_oldest       = 1;
  idu_lsu_ld_preg         = 7'd1;
  idu_lsu_ld_offset       = 12'h000;
  idu_lsu_ld_offset_plus  = 13'h000;
  idu_lsu_ld_src          = 32'h0000_1000;  // 地址 0x1000
  $display("[%0t] First load request asserted: idu_lsu_ld_sel=%b, addr=0x%h", $time, idu_lsu_ld_sel, idu_lsu_ld_src);

  // 发射后 50 个周期产生 commit0
  fork
    begin
      repeat(50) @(posedge clk);
      rtu_yy_xx_commit0       = 1;
      rtu_yy_xx_commit0_iid   = 7'h01;
      @(posedge clk);
      rtu_yy_xx_commit0       = 0;
      rtu_yy_xx_commit0_iid   = 0;
    end
  join_none

  @(posedge clk);
  #1;
  idu_lsu_ld_sel = 0;
  $display("[%0t] First load request deasserted: idu_lsu_ld_sel=%b", $time, idu_lsu_ld_sel);

  // 等待 AR 请求上升沿，增加超时检测
  fork
    begin
      @(posedge rb_biu_ar_req);
      ar_id1 = rb_biu_ar_id;
      $display("[%0t] First AR request: addr=0x%h, id=%d", $time, rb_biu_ar_addr, rb_biu_ar_id);
    end
    begin
      repeat(200) @(posedge clk);
      $display("[%0t] ERROR: Timeout waiting for first AR request!", $time);
      $display("  rb_biu_ar_req=%b", rb_biu_ar_req);
      $display("  lsu_idu_lq_not_full=%b", lsu_idu_lq_not_full);
      $display("  lsu_idu_rb_not_full=%b", lsu_idu_rb_not_full);
      $display("  NOTE: Load instruction did not generate bus read request.");
      $display("  Possible reasons: cache hit, instruction stalled, or pipeline issue.");
      $finish;
    end
  join_any
  disable fork;

  // 10 个时钟周期后返回全 1 数据
  repeat(10) @(posedge clk);
  biu_lsu_r_vld  = 1;
  biu_lsu_r_data = 128'hFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF;
  biu_lsu_r_id   = ar_id1;
  biu_lsu_r_resp = 2'b00;
  biu_lsu_r_last = 1;
  @(posedge clk);
  biu_lsu_r_vld  = 0;
  biu_lsu_r_last = 0;

  // 等待第一个 load 完成
  repeat(30) @(posedge clk);

  // ------------------------------------------------------------
  // 第二个 Load 请求
  // ------------------------------------------------------------
  @(posedge clk);
  #1;  // 添加小延迟确保在时钟上升沿后设置信号
  idu_lsu_ld_sel          = 1;
  idu_lsu_ld_inst_size    = 2'b10;      // Word load
  idu_lsu_ld_unalign_2nd  = 0;
  idu_lsu_ld_sign_extend  = 0;
  idu_lsu_ld_iid          = 7'h02;
  idu_lsu_ld_lch_entry    = 12'h002;
  idu_lsu_ld_oldest       = 1;
  idu_lsu_ld_preg         = 7'd2;
  idu_lsu_ld_offset       = 12'h000;
  idu_lsu_ld_offset_plus  = 13'h000;
  idu_lsu_ld_src          = 32'h0000_2000;  // 地址 0x2000
  $display("[%0t] Second load request asserted: idu_lsu_ld_sel=%b, addr=0x%h", $time, idu_lsu_ld_sel, idu_lsu_ld_src);

  // 发射后 50 个周期产生 commit1
  fork
    begin
      repeat(50) @(posedge clk);
      rtu_yy_xx_commit1       = 1;
      rtu_yy_xx_commit1_iid   = 7'h02;
      @(posedge clk);
      rtu_yy_xx_commit1       = 0;
      rtu_yy_xx_commit1_iid   = 0;
    end
  join_none

  @(posedge clk);
  #1;
  idu_lsu_ld_sel = 0;
  $display("[%0t] Second load request deasserted: idu_lsu_ld_sel=%b", $time, idu_lsu_ld_sel);

  // 等待第二个 AR 请求上升沿
  @(posedge rb_biu_ar_req);
  ar_id2 = rb_biu_ar_id;
  $display("[%0t] Second AR request: addr=0x%h, id=%d", $time, rb_biu_ar_addr, rb_biu_ar_id);

  // 10 个时钟周期后返回全 1 数据
  repeat(10) @(posedge clk);
  biu_lsu_r_vld  = 1;
  biu_lsu_r_data = 128'hFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF;
  biu_lsu_r_id   = ar_id2;
  biu_lsu_r_resp = 2'b00;
  biu_lsu_r_last = 1;
  @(posedge clk);
  biu_lsu_r_vld  = 0;
  biu_lsu_r_last = 0;

  // 等待足够时间，让第二个 load 及提交完成
  repeat(60) @(posedge clk);

  $display("=== Simulation Complete ===");
  $finish;
end

// Dump waveform
initial begin
  $dumpfile("load_test.vcd");
  $dumpvars(0, tb_lsu_load_test);
end

endmodule