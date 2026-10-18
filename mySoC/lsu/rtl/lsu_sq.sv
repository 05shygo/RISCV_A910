// Copyright 2019-2021 T-Head Semiconductor Co., Ltd.
// Licensed under the Apache License, Version 2.0
// http://www.apache.org/licenses/LICENSE-2.0

module ct_lsu_sq #(
    parameter SQ_ENTRY   = 12,
    parameter LSIQ_ENTRY = 8,
    parameter IID_WIDTH  = 7
)(
    input  logic         cpurst_b,
    input  logic [4:0]   dcache_dirty_din,
    input  logic         dcache_dirty_gwen,
    input  logic [4:0]   dcache_dirty_wen,
    input  logic [4:0]   dcache_idx,
    input  logic [43:0]  dcache_tag_din,
    input  logic         dcache_tag_gwen,
    input  logic [1:0]   dcache_tag_wen,
    input  logic         forever_cpuclk,
    input  logic [7:0]  ld_da_lsid,
    input  logic         ld_da_sq_data_discard_vld,
    // 2026-10-18: 向量 load 的 fill_id (SQ/LFB 唤醒队列用)
    input  logic         ld_da_vec,
    input  logic [4:0]   ld_da_fill_id,
    input  logic [SQ_ENTRY-1:0] ld_da_sq_fwd_id,
    input  logic         ld_da_sq_fwd_multi_vld,
    input  logic         ld_da_sq_global_discard_vld,
    input  logic [31:0]  ld_dc_addr0,
    // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): input  logic [7:0]   ld_dc_addr1_11to4,
    input  logic [15:0]  ld_dc_bytes_vld,
    // 2026-10-15 停用: 只服务非对齐第二半的 RAW 检查
    //input  logic [15:0]  ld_dc_bytes_vld1,
    //input  logic         ld_dc_chk_ld_addr1_vld,
    // 2026-10-15 停用: bypass 通路在本仓没实现 (ld_dc_chk_ld_bypass_vld 无人使用), 整条摘掉: input  logic         ld_dc_chk_ld_bypass_vld,
    input  logic         ld_dc_chk_ld_inst_vld,
    input  logic [IID_WIDTH-1:0] ld_dc_iid,
    input  logic         rb_sq_pop_hit_idx,
    input  logic         rtu_lsu_async_flush,
    input  logic         rtu_yy_xx_commit0,
    input  logic [6:0]   rtu_yy_xx_commit0_iid,
    input  logic         rtu_yy_xx_commit1,
    input  logic [6:0]   rtu_yy_xx_commit1_iid,
    input  logic         rtu_yy_xx_commit2,
    input  logic [6:0]   rtu_yy_xx_commit2_iid,
    input  logic         rtu_yy_xx_flush,
    // 2026-10-17 S7: 向量 store 的提交电平
    input  logic         vec_st_cmit_vld,
    input  logic [6:0]   vec_st_cmit_iid,
    input  logic [31:0]  idu_lsu_rf_pipe5_src0,
    input  logic         idu_lsu_sdiq_sel,
    input  logic [3:0]   idu_lsu_rf_pipe5_sdiq_entry,
    input  logic [IID_WIDTH-1:0] st_da_iid,
    input  logic         st_da_vec,
    input  logic [4:0]   st_da_uop_idx,
    input  logic [4:0]   st_da_beat_idx,
    input  logic         st_da_inst_vld,
    // 2026-10-15 停用: 非对齐拆分通路整条摘掉 (secd/boundary)
    //input  logic         st_da_secd,
    input  logic         st_da_sq_dcache_dirty,
    input  logic         st_da_sq_dcache_valid,
    input  logic         st_da_sq_dcache_way,
    input  logic         st_da_sq_no_restart,
    input  logic [31:0]  st_dc_addr0,
    //input  logic         st_dc_boundary,
    //input  logic         st_dc_boundary_first,
    input  logic [15:0]  st_dc_bytes_vld,
    input  logic [IID_WIDTH-1:0] st_dc_iid,
    input  logic         st_dc_vec,
    input  logic [4:0]   st_dc_uop_idx,
    input  logic [4:0]   st_dc_beat_idx,
    input  logic         st_dc_old,
    input  logic [7:0]   st_dc_rot_sel_rev,
    input  logic [3:0]   st_dc_sdid,
  //  input  logic         st_dc_sdid_hit,
    //input  logic         st_dc_secd,
    input  logic         st_dc_sq_create_vld,
    input  logic         st_dc_sq_data_vld,
    input  logic [31:0]  st_dc_sq_data,
    input  logic [31:0]  wmb_ce_addr,
    input  logic [SQ_ENTRY-1:0] wmb_ce_sq_ptr,
    input  logic         wmb_sq_pop_grnt,
    input  logic         wmb_sq_pop_to_ce_grnt,

    output logic [LSIQ_ENTRY-1:0] sq_data_depd_wakeup,
    output logic [LSIQ_ENTRY-1:0] sq_global_depd_wakeup,
    // 2026-10-18: 给 ct_idu_vec_ls_fill 的延迟唤醒 (替代"立刻 restart")
    output logic         sq_vec_wk_vld,
    output logic [4:0]   sq_vec_wk_fill_id,
    output logic [31:0]  sq_ld_da_fwd_data,
    // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): output logic         sq_ld_dc_addr1_dep_discard,
    // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): output logic         sq_ld_dc_cancel_acc_req,
    output logic         sq_ld_dc_data_discard_req,
    output logic [SQ_ENTRY-1:0] sq_ld_dc_fwd_id,
    output logic         sq_ld_dc_fwd_multi,
    output logic         sq_ld_dc_fwd_multi_mask,
    output logic         sq_ld_dc_fwd_req,
    output logic [15:0]  sq_ld_dc_fwd_bytes_vld,   // 2026-10-18 16B 向量 load 前递掩码
    output logic         sq_ld_dc_other_discard_req,
    output logic [31:0]  sq_pop_addr,
    output logic [15:0]  sq_pop_bytes_vld,
    output logic [SQ_ENTRY-1:0] sq_pop_ptr,
    output logic         sq_st_dc_full,
    output logic         sq_st_dc_inst_hit,
    output logic         sq_wmb_merge_stall_req,
    output logic         sq_wmb_pop_to_ce_req,
    output logic         sq_wmb_merge_req,
    output logic [127:0] wmb_ce_data128,
    output logic         wmb_ce_update_dcache_dirty,
    output logic         wmb_ce_update_dcache_valid,
    output logic         wmb_ce_update_dcache_way,
    output logic         lsu_idu_sq_not_full,
    // 2026-10-17 S7: SQ 表项弹出回送 uop_idx (给 S8 fill 引擎释放 request)
    output logic         lsu_idu_sq_pop_vld,
    output logic [4:0]   lsu_idu_sq_pop_uop_idx,
    // 给 RTU 的冲刷闸 (见 lsu_sq_entry.sv:436 的口径): "没有哪个**已退休**的表项
    // 还在等 store data"。C910 就是这根 (`ct_lsu_sq.v:3728`), 本仓移植时整条丢了。
    output logic         lsu_rtu_all_commit_st_data_vld
);

    localparam int PA_WIDTH = 32;
    localparam logic [1:0] BYTE  = 2'b00;
    localparam logic [1:0] HALF  = 2'b01;
    localparam logic [1:0] WORD  = 2'b10;
    localparam logic [1:0] DWORD = 2'b11;

    //==========================================================
    // Registers
    //==========================================================
    logic [SQ_ENTRY-1:0] sq_create_ptr;
    logic [SQ_ENTRY-1:0] sq_data_discard_id_sel;
    logic [31:0]         sq_pe_age_vec_surplus1_addr;
    logic [15:0]         sq_pe_age_vec_surplus1_bytes_vld;
    logic [31:0]         sq_pe_age_vec_zero_addr;
    logic [15:0]         sq_pe_age_vec_zero_bytes_vld;
    logic                sq_pop_depd_ff;
    logic [LSIQ_ENTRY-1:0] sq_wakeup_queue;
    logic [31:0]         wmb_ce_data32;

    //==========================================================
    // Wires
    //==========================================================
    logic                sq_age_vec_set;
    logic                sq_clk;
    logic [SQ_ENTRY-1:0] sq_create_age_vec;
    //logic                sq_create_pop_clk;
    logic                sq_create_same_addr_newest;
    logic                sq_create_success;
    logic [SQ_ENTRY-1:0] sq_create_vld;
    logic [127:0]         sq_data_after_rot;
    logic                sq_data_discard_has_newest;
    logic [SQ_ENTRY-1:0] sq_data_discard_newest_id;
    logic                sq_data_discard_req;
    // 2026-10-15 停用: 死亡声明 (无驱动无负载, 与本次非对齐摘除无关的既有残留): logic                sq_data_discard_req_short;
    logic [127:0]         sq_data_ori;
    logic [31:0]         sq_data_settle;
    logic                sq_empty_less2;
    // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): logic [SQ_ENTRY-1:0] sq_entry_addr1_dep_discard;
    logic [SQ_ENTRY-1:0] sq_entry_age_vec_surplus1_ptr;
    logic [SQ_ENTRY-1:0] sq_entry_age_vec_zero_ptr;
    // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): logic [SQ_ENTRY-1:0] sq_entry_cancel_acc_req;
    logic [SQ_ENTRY-1:0] sq_entry_cmit;
   // logic [SQ_ENTRY-1:0] sq_entry_cmit_data_vld;
    logic [SQ_ENTRY-1:0] sq_entry_create_vld;
    logic [SQ_ENTRY-1:0] sq_entry_data_discard_grnt;
    logic [SQ_ENTRY-1:0] sq_entry_data_discard_req;
    // 2026-10-15 停用: 死亡声明 (无驱动无负载, 与本次非对齐摘除无关的既有残留): logic [SQ_ENTRY-1:0] sq_entry_data_discard_req_short;
    logic [SQ_ENTRY-1:0] sq_entry_dcache_dirty;
    logic [SQ_ENTRY-1:0] sq_entry_dcache_info_vld;
    logic [SQ_ENTRY-1:0] sq_entry_dcache_valid;
    logic [SQ_ENTRY-1:0] sq_entry_dcache_way;
    logic [SQ_ENTRY-1:0] sq_entry_depd;
    logic [SQ_ENTRY-1:0] sq_entry_depd_set;
    logic [SQ_ENTRY-1:0] sq_entry_discard_req;
    // 2026-10-15 停用: 死亡声明 (无驱动无负载, 与本次非对齐摘除无关的既有残留): logic [SQ_ENTRY-1:0] sq_entry_fwd_bypass_req;
    logic [SQ_ENTRY-1:0] sq_entry_fwd_multi_depd_set;
    logic [SQ_ENTRY-1:0] sq_entry_fwd_req;
    logic [SQ_ENTRY-1:0] sq_entry_inst_hit;
    logic [SQ_ENTRY-1:0] sq_entry_pop_req;
    logic [SQ_ENTRY-1:0] sq_entry_pop_to_ce_grnt;
    logic [SQ_ENTRY-1:0] sq_entry_pop_to_ce_grnt_b;
    logic [SQ_ENTRY-1:0] sq_entry_same_addr_newest;
    logic [SQ_ENTRY-1:0] sq_entry_settle_data_hit;
    logic [SQ_ENTRY-1:0] sq_entry_st_dc_create_age_vec;
    logic [SQ_ENTRY-1:0] sq_entry_st_dc_same_addr_newer;
    logic [SQ_ENTRY-1:0] sq_entry_vld;
    logic [SQ_ENTRY-1:0] sq_entry_wakeup_queue_set_id;
    logic                sq_full;
    // 2026-10-15 停用: 死亡声明 (无驱动无负载, 与本次非对齐摘除无关的既有残留): logic                sq_fwd_bypass_req;
    logic                sq_fwd_multi;
    logic                sq_fwd_req;
    logic [SQ_ENTRY-1:0] sq_fwd_req_id;
    logic                sq_has_cmit;
    // 2026-10-15 停用: 死亡声明 (无驱动无负载, 与本次非对齐摘除无关的既有残留): logic                sq_newest_fwd_bypass_req;
    logic                sq_newest_fwd_req;
    // 2026-10-15 停用: 死亡声明 (无驱动无负载, 与本次非对齐摘除无关的既有残留): logic                sq_newest_fwd_req_data_vld_short;
    logic [SQ_ENTRY-1:0] sq_newest_fwd_req_id;
    logic                sq_pe_sel_age_vec_surplus1_entry_vld;
    logic                sq_pe_sel_age_vec_zero_entry_vld;
    logic                sq_pop_clk;
    logic                sq_pop_req_unmask;
    logic                sq_pop_to_ce_req;
    logic [7:0]          sq_settle_rot_sel;
    logic                sq_wakeup_queue_clk;
    logic [LSIQ_ENTRY-1:0] sq_wakeup_queue_grnt;
    logic [LSIQ_ENTRY-1:0] sq_wakeup_queue_next;
    logic                wmb_ce_dcache_hit_idx;
    logic                wmb_ce_dcache_update_vld;
    logic                wmb_ce_dcache_way;
    logic                wmb_ce_depd;
    logic                wmb_ce_depd_set;

    // -----------------------------------------------------------------------
    // 本地时钟驱动（2026-10-08 补, 三个一起放这里 —— 它们的声明分散在 116/172/176,
    // 连续赋值必须写在三处声明之后, 否则前面的引用算未声明)
    //
    // ⚠️ C910 工厂版在这里例化了门控时钟单元 (forever_cpuclk + 各 *_gateclk_en
    //    → ct_clk_cell), **交付时那批单元被整体剥掉** ⇒ 这三个时钟全仓无驱动。
    //    后果是**整个存储队列不在跑**:
    //      * `sq_clk`          —— sq_pop_depd_ff (弹出依赖标志);
    //      * `sq_pop_clk`      —— 弹出地址/掩码/指针 (没有复位, 纯"条件成立就装"型);
    //      * `sq_wakeup_queue_clk` —— 重启唤醒队列。
    //    即 SQ 的弹出侧全部冻结 ⇒ store 永远弹不出去。
    //
    // 本模块的 forever_cpuclk 端口一直存在 (端口表 :20, 且 lsu_top:1264 已连)。
    // 各 always_ff 内部自带使能条件 (cpurst_b / rtu_yy_xx_flush / *_vld),
    // 所以直接接 forever_cpuclk 功能等价, 只是少了时钟门控的省电效果。
    // -----------------------------------------------------------------------
    assign sq_clk              = forever_cpuclk;
    assign sq_pop_clk          = forever_cpuclk;
    assign sq_wakeup_queue_clk = forever_cpuclk;

    //==========================================================
    // Entry arrays
    //==========================================================
    logic [31:0] sq_entry_addr0 [0:SQ_ENTRY-1];
    logic [15:0] sq_entry_bytes_vld [0:SQ_ENTRY-1];
    logic [31:0] sq_entry_data [0:SQ_ENTRY-1];
    logic [IID_WIDTH-1:0] sq_entry_iid [0:SQ_ENTRY-1];
    logic [7:0]  sq_entry_rot_sel [0:SQ_ENTRY-1];
    logic [7:0]  sq_entry_data_depd_wakeup [0:SQ_ENTRY-1];
    logic [SQ_ENTRY-1:0] sq_entry_vec_wk_vld;
    logic [4:0]  sq_entry_vec_wk_fill_id [0:SQ_ENTRY-1];
logic [SQ_ENTRY-1:0]sq_entry_cmit_data_not_vld;
    //==========================================================
    // SQ entry instances
    //==========================================================
    // 2026-10-17 S7: 每个 SQ 表项的 uop_idx (给弹出回送)
    logic [SQ_ENTRY-1:0][4:0] sq_entry_uop_idx;

    genvar i ;
    generate
        for (i = 0; i < SQ_ENTRY; i++) begin : gen_sq_entry
            ct_lsu_sq_entry #(
                .SQ_ENTRY   (SQ_ENTRY),
                .LSIQ_ENTRY (LSIQ_ENTRY),
                .IID_WIDTH  (IID_WIDTH)
            ) x_ct_lsu_sq_entry (
                .cpurst_b                                  (cpurst_b),
                .forever_cpuclk                            (forever_cpuclk),
                .dcache_dirty_din                          (dcache_dirty_din),
                .dcache_dirty_gwen                         (dcache_dirty_gwen),
                .dcache_dirty_wen                          (dcache_dirty_wen),
                .dcache_idx                                (dcache_idx),
                .dcache_tag_din                            (dcache_tag_din),
                .dcache_tag_gwen                           (dcache_tag_gwen),
                .dcache_tag_wen                            (dcache_tag_wen),
                .ld_da_lsid                                (ld_da_lsid),
                .ld_da_vec                                 (ld_da_vec),
                .ld_da_fill_id                             (ld_da_fill_id),
                .ld_dc_addr0                               (ld_dc_addr0),
                // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): .ld_dc_addr1_11to4                         (ld_dc_addr1_11to4),
                .ld_dc_bytes_vld                           (ld_dc_bytes_vld),
                //.ld_dc_bytes_vld1                          (ld_dc_bytes_vld1),
                //.ld_dc_chk_ld_addr1_vld                    (ld_dc_chk_ld_addr1_vld),
                // 2026-10-15 停用: bypass 通路在本仓没实现 (ld_dc_chk_ld_bypass_vld 无人使用), 整条摘掉: .ld_dc_chk_ld_bypass_vld                   (ld_dc_chk_ld_bypass_vld),
                .ld_dc_chk_ld_inst_vld                     (ld_dc_chk_ld_inst_vld),
                .ld_dc_iid                                 (ld_dc_iid),
                .rtu_yy_xx_commit0                         (rtu_yy_xx_commit0),
                .rtu_yy_xx_commit0_iid                     (rtu_yy_xx_commit0_iid),
                .rtu_yy_xx_commit1                         (rtu_yy_xx_commit1),
                .rtu_yy_xx_commit1_iid                     (rtu_yy_xx_commit1_iid),
                .rtu_yy_xx_commit2                         (rtu_yy_xx_commit2),
                .rtu_yy_xx_commit2_iid                     (rtu_yy_xx_commit2_iid),
                .rtu_yy_xx_flush                           (rtu_yy_xx_flush),
                .vec_st_cmit_vld                           (vec_st_cmit_vld),
                .vec_st_cmit_iid                           (vec_st_cmit_iid),
                .sd_ex1_inst_vld                           (idu_lsu_sdiq_sel),
                .sd_rf_ex1_sdid                            (idu_lsu_rf_pipe5_sdiq_entry),
                .sq_age_vec_set                            (sq_age_vec_set),
                .sq_create_age_vec                         (sq_create_age_vec),
              //  .sq_create_pop_clk                         (sq_create_pop_clk),
                .sq_create_same_addr_newest                (sq_create_same_addr_newest),
                .sq_create_success                         (sq_create_success),
                .sq_create_vld                             (sq_create_vld),
                .sq_data_settle                            (sq_data_settle),
                .sq_entry_create_vld_x                     (sq_entry_create_vld[i]),
                .sq_entry_data_discard_grnt_x              (sq_entry_data_discard_grnt[i]),
                .sq_entry_fwd_multi_depd_set_x             (sq_entry_fwd_multi_depd_set[i]),
                .sq_entry_pop_to_ce_grnt_b                 (sq_entry_pop_to_ce_grnt_b),
                .sq_entry_pop_to_ce_grnt_x                 (sq_entry_pop_to_ce_grnt[i]),
                .sq_pop_ptr_x                              (sq_pop_ptr[i]),
                .st_da_iid                                 (st_da_iid),
                .st_da_inst_vld                            (st_da_inst_vld),
                .st_da_vec                                 (st_da_vec),
                .st_da_uop_idx                             (st_da_uop_idx),
                .st_da_beat_idx                            (st_da_beat_idx),
                //.st_da_secd                                (st_da_secd),
                .st_da_sq_dcache_dirty                     (st_da_sq_dcache_dirty),
                .st_da_sq_dcache_valid                     (st_da_sq_dcache_valid),
                .st_da_sq_dcache_way                       (st_da_sq_dcache_way),
                .st_da_sq_no_restart                       (st_da_sq_no_restart),
                .st_dc_addr0                               (st_dc_addr0),
                //.st_dc_boundary                            (st_dc_boundary),
                //.st_dc_boundary_first                      (st_dc_boundary_first),
                .st_dc_bytes_vld                           (st_dc_bytes_vld),
                .st_dc_iid                                 (st_dc_iid),
                .st_dc_vec                                 (st_dc_vec),
                .st_dc_uop_idx                             (st_dc_uop_idx),
                .st_dc_beat_idx                            (st_dc_beat_idx),
                .st_dc_rot_sel_rev                         (st_dc_rot_sel_rev),
                .st_dc_sdid                                (st_dc_sdid),
            //    .st_dc_sdid_hit                            (st_dc_sdid_hit),
                //.st_dc_secd                                (st_dc_secd),
                .st_dc_sq_data_vld                         (st_dc_sq_data_vld),
                .st_dc_sq_data                             (st_dc_sq_data),
                .wmb_sq_pop_grnt                           (wmb_sq_pop_grnt),
                .sq_entry_addr0_v                          (sq_entry_addr0[i]),
                // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): .sq_entry_addr1_dep_discard_x              (sq_entry_addr1_dep_discard[i]),
                .sq_entry_age_vec_surplus1_ptr_x           (sq_entry_age_vec_surplus1_ptr[i]),
                .sq_entry_age_vec_zero_ptr_x               (sq_entry_age_vec_zero_ptr[i]),
                .sq_entry_bytes_vld_v                      (sq_entry_bytes_vld[i]),
                // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): .sq_entry_cancel_acc_req_x                 (sq_entry_cancel_acc_req[i]),
               // .sq_entry_cmit_data_vld_x                  (sq_entry_cmit_data_vld[i]),
                .sq_entry_cmit_data_not_vld(sq_entry_cmit_data_not_vld[i]),
                .sq_entry_cmit_x                           (sq_entry_cmit[i]),
                .sq_entry_data_depd_wakeup_v               (sq_entry_data_depd_wakeup[i]),
                .sq_entry_vec_wk_vld_x                     (sq_entry_vec_wk_vld[i]),
                .sq_entry_vec_wk_fill_id_x                 (sq_entry_vec_wk_fill_id[i]),
                .sq_entry_data_discard_req_x               (sq_entry_data_discard_req[i]),
                .sq_entry_data_v                           (sq_entry_data[i]),
                .sq_entry_dcache_dirty_x                   (sq_entry_dcache_dirty[i]),
                .sq_entry_dcache_info_vld_x                (sq_entry_dcache_info_vld[i]),
                .sq_entry_dcache_valid_x                   (sq_entry_dcache_valid[i]),
                .sq_entry_dcache_way_x                     (sq_entry_dcache_way[i]),
                .sq_entry_depd_set_x                       (sq_entry_depd_set[i]),
                .sq_entry_depd_x                           (sq_entry_depd[i]),
                .sq_entry_discard_req_x                    (sq_entry_discard_req[i]),
                .sq_entry_fwd_req_x                        (sq_entry_fwd_req[i]),
                .sq_entry_iid_v                            (sq_entry_iid[i]),
                .sq_entry_inst_hit_x                       (sq_entry_inst_hit[i]),
                .sq_entry_uop_idx_x                        (sq_entry_uop_idx[i]),
                .sq_entry_pop_req_x                        (sq_entry_pop_req[i]),
                .sq_entry_rot_sel_v                        (sq_entry_rot_sel[i]),
                .sq_entry_same_addr_newest_x               (sq_entry_same_addr_newest[i]),
                .sq_entry_settle_data_hit_x                (sq_entry_settle_data_hit[i]),
                .sq_entry_st_dc_create_age_vec_x           (sq_entry_st_dc_create_age_vec[i]),
                .sq_entry_st_dc_same_addr_newer_x          (sq_entry_st_dc_same_addr_newer[i]),
                .sq_entry_vld_x                            (sq_entry_vld[i])
            );
        end
    endgenerate

    //==========================================================
    // Generate full/create signal
    //==========================================================
    always_comb begin
        sq_create_ptr = {SQ_ENTRY{1'b0}};
        for (int k=0; k<SQ_ENTRY; k++) begin
            if (!sq_entry_vld[k]) begin
                sq_create_ptr[k] = 1'b1;
                break;
            end
        end
    end

    assign sq_has_cmit = |(sq_entry_cmit[SQ_ENTRY-1:0] & sq_entry_vld[SQ_ENTRY-1:0]);
    assign sq_full = &sq_entry_vld[SQ_ENTRY-1:0];

    // -----------------------------------------------------------------------
    // 【2026-10-15 补漏, coremark_i1 T394913 死锁的真凶】
    // C910 `ct_lsu_sq.v:3728`: `assign lsu_rtu_all_commit_st_data_vld =
    //                            &sq_entry_cmit_data_vld[SQ_ENTRY-1:0];`
    // 本仓把 `sq_entry_cmit_data_vld` 从各表项收上来了 (见 :291), **但全仓再没人
    // 用它** —— 这根线连同 RTU 那侧的冲刷闸 (`retire_flush_pipeline_empty`) 一起
    // 在移植时丢了。后果:
    //   一条 store 退休了 (cmit=1) 但它的 store data 还没到 (data_vld=0), 此时来
    //   一次冲刷 ⇒ IDU 的 SDIQ 表项 (数据**唯一**来源) 被冲掉 ⇒ 这个 SQ 表项永远
    //   拿不到数据 ⇒ 永不 pop; 而更年轻的 load 若在 LD_DA 因它被 discard, 会把自己
    //   登记进它的 wakeup_queue 等 `data_set` ⇒ 永远不唤醒 ⇒ ROB 队头不完 ⇒ 死锁。
    // 口径: 表项内部 `sq_entry_cmit_data_vld = !(vld && (cmit|cmit_set) && !data_vld)`,
    // 无效表项恒 1 ⇒ 这里的 &-reduce 恰好是"没有任何已退休表项缺数据"。
    // -----------------------------------------------------------------------
    assign lsu_rtu_all_commit_st_data_vld = |sq_entry_cmit_data_not_vld[SQ_ENTRY-1:0];
    // 原 (错): assign lsu_rtu_all_commit_st_data_vld = |sq_entry_cmit_data_not_vld[SQ_ENTRY-1:0];
    assign sq_empty_less2 = &(sq_entry_vld[SQ_ENTRY-1:0] | sq_create_ptr[SQ_ENTRY-1:0]);
    assign sq_st_dc_inst_hit = |sq_entry_inst_hit[SQ_ENTRY-1:0];
    assign sq_st_dc_full = sq_full || (!st_dc_old && sq_empty_less2 && !sq_has_cmit);
    assign sq_create_success = st_dc_sq_create_vld && !sq_st_dc_full && !rtu_yy_xx_flush;

    assign lsu_idu_sq_not_full = !sq_empty_less2;

    // S7: 弹出表项的 uop_idx (sq_pop_ptr 是 one-hot)
    always_comb begin
      lsu_idu_sq_pop_uop_idx = 5'b0;
      lsu_idu_sq_pop_vld     = |sq_pop_ptr[SQ_ENTRY-1:0];
      for (int k=0; k<SQ_ENTRY; k++) begin
        if (sq_pop_ptr[k])
          lsu_idu_sq_pop_uop_idx = sq_entry_uop_idx[k];
      end
    end

    assign sq_entry_create_vld = {SQ_ENTRY{sq_create_success}} & sq_create_ptr;
    assign sq_create_same_addr_newest = &(~sq_entry_st_dc_same_addr_newer[SQ_ENTRY-1:0]);
    assign sq_create_vld = sq_entry_create_vld;
    assign sq_create_age_vec = sq_entry_st_dc_create_age_vec;
    assign sq_age_vec_set = sq_create_success || wmb_sq_pop_to_ce_grnt;

    //==========================================================
    // Settle data
    //==========================================================
    assign sq_data_ori = {idu_lsu_rf_pipe5_src0, idu_lsu_rf_pipe5_src0, idu_lsu_rf_pipe5_src0, idu_lsu_rf_pipe5_src0};
    // ⚠️ 2026-10-18: 这里原来只 OR 了表项 0~5 —— 是 SQ_ENTRY=6 时代的残留。
    //   SQ_ENTRY 扩到 12 后, store 落在表项 6~11 且它是唯一命中数据广播的表项时,
    //   rot_sel 为 0 ⇒ ct_lsu_rot_data 走 default 输出 X ⇒ 该 SQ 表项的 store data
    //   变成 X, 之后一路写进 WMB / dcache (coremark_i1 #97586:
    //   `lw s10,0(sp)` 读回 X, 因为 sp+0 那笔 sw 落在表项 E6)。
    //   改为遍历全部表项, 并保持原语义 (多表项同 sdid 命中时仍 OR rot_sel)。
    always_comb begin
        sq_settle_rot_sel = 8'b0;
        for (int k = 0; k < SQ_ENTRY; k++)
            if (sq_entry_settle_data_hit[k])
                sq_settle_rot_sel = sq_settle_rot_sel | sq_entry_rot_sel[k];
    end

    ct_lsu_rot_data x_lsu_sq_data_rot_to_mem_format (
        .data_in         (sq_data_ori),
        .data_settle_out (sq_data_after_rot),
        .rot_sel         (sq_settle_rot_sel)
    );
    assign sq_data_settle = sq_data_after_rot[31:0];

    //==========================================================
    // SQ to LD DC depd/discard
    //==========================================================
    assign sq_ld_dc_other_discard_req = |sq_entry_discard_req;
    // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): assign sq_ld_dc_addr1_dep_discard = |sq_entry_addr1_dep_discard;
    // 2026-10-15 停用: 非对齐通路摘除后的残留 (无消费者): assign sq_ld_dc_cancel_acc_req = |sq_entry_cancel_acc_req;

    assign sq_data_discard_req = |sq_entry_data_discard_req;
    assign sq_fwd_req = |sq_entry_fwd_req;
    assign sq_newest_fwd_req_id = sq_entry_fwd_req & sq_entry_same_addr_newest;
    assign sq_newest_fwd_req = |sq_newest_fwd_req_id;

    assign sq_ld_dc_fwd_req = sq_fwd_req;

    assign sq_ld_dc_data_discard_req = sq_data_discard_req &&  !sq_newest_fwd_req;
    assign sq_ld_dc_fwd_id = sq_data_discard_req & !sq_newest_fwd_req ? sq_entry_data_discard_req : sq_fwd_req_id;
    assign sq_fwd_req_id = sq_newest_fwd_req ? sq_newest_fwd_req_id : sq_entry_fwd_req;

    // 2026-10-18: 选中前递表项的字节掩码 (16B 向量 load 不能用 16'hffff)
    always_comb begin
        sq_ld_dc_fwd_bytes_vld = 16'h0;
        for (int k = 0; k < SQ_ENTRY; k++)
            if (sq_fwd_req_id[k]) sq_ld_dc_fwd_bytes_vld = sq_entry_bytes_vld[k];
    end

    always_comb begin
        logic [$clog2(SQ_ENTRY+1)-1:0] cnt;
        cnt = '0;
        for (int k=0; k<SQ_ENTRY; k++)
            if (sq_entry_fwd_req[k]) cnt = cnt + 1'b1;
        sq_fwd_multi = (cnt > 1);
    end
    assign sq_ld_dc_fwd_multi = sq_fwd_multi;
    assign sq_ld_dc_fwd_multi_mask = sq_newest_fwd_req;

    //==========================================================
    // Forward data to LD DA
    //==========================================================
    always_comb begin
        sq_ld_da_fwd_data = {32{1'bx}};
        for (int k=0; k<SQ_ENTRY; k++)
            if (ld_da_sq_fwd_id[k]) sq_ld_da_fwd_data = sq_entry_data[k];
    end

    //==========================================================
    // LD DA to SQ depd/discard
    //==========================================================
    assign sq_entry_fwd_multi_depd_set = {SQ_ENTRY{ld_da_sq_fwd_multi_vld}} &
                                         ld_da_sq_fwd_id & sq_entry_vld;

    always_comb begin
        sq_data_discard_id_sel = {SQ_ENTRY{1'b0}};
        for (int k=0; k<SQ_ENTRY; k++)
            if (ld_da_sq_fwd_id[k]) sq_data_discard_id_sel = {SQ_ENTRY{1'b0}} | (1 << k);
    end

    assign sq_data_discard_newest_id = sq_entry_same_addr_newest & ld_da_sq_fwd_id;
    assign sq_data_discard_has_newest = |sq_data_discard_newest_id;
    assign sq_entry_wakeup_queue_set_id = sq_data_discard_has_newest
                                          ? sq_data_discard_newest_id
                                          : sq_data_discard_id_sel;
    assign sq_entry_data_discard_grnt = {SQ_ENTRY{ld_da_sq_data_discard_vld}} &
                                        sq_entry_wakeup_queue_set_id;

    //==========================================================
    // Maintain restart wakeup queue
    //==========================================================
    always_ff @(posedge sq_wakeup_queue_clk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_wakeup_queue <= {LSIQ_ENTRY{1'b0}};
        else if (rtu_yy_xx_flush)
            sq_wakeup_queue <= {LSIQ_ENTRY{1'b0}};
        else if (ld_da_sq_global_discard_vld || sq_pop_depd_ff)
            sq_wakeup_queue <= sq_wakeup_queue_next;
    end

    always_ff @(posedge sq_clk or negedge cpurst_b) begin
        if (!cpurst_b)
            sq_pop_depd_ff <= 1'b0;
        else if (wmb_sq_pop_grnt && (wmb_ce_depd || wmb_ce_depd_set))
            sq_pop_depd_ff <= 1'b1;
        else
            sq_pop_depd_ff <= 1'b0;
    end

    assign sq_wakeup_queue_grnt = sq_wakeup_queue |
                                  ({LSIQ_ENTRY{ld_da_sq_global_discard_vld}} & ld_da_lsid);
    assign sq_wakeup_queue_next = sq_pop_depd_ff ? {LSIQ_ENTRY{1'b0}} : sq_wakeup_queue_grnt;
    assign sq_global_depd_wakeup = sq_pop_depd_ff ? sq_wakeup_queue_grnt : {LSIQ_ENTRY{1'b0}};

    //==========================================================
    // 2026-10-18: 向量 fill 的延迟唤醒
    //   data discard: fill_id 记在命中的 SQ entry, data_set 时唤醒;
    //   global discard: fill_id 记在 SQ 顶层, sq_pop_depd_ff 时唤醒。
    //   FE 同一时刻只有一笔 outstanding, 所以每类一个 pending 就够。
    //==========================================================
    logic        sq_vec_global_wk_pend;
    logic [4:0]  sq_vec_global_wk_fill_id;

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            sq_vec_global_wk_pend    <= 1'b0;
            sq_vec_global_wk_fill_id <= 5'd0;
        end
        else if (rtu_yy_xx_flush) begin
            sq_vec_global_wk_pend    <= 1'b0;
        end
        else if (ld_da_sq_global_discard_vld && ld_da_vec && !sq_vec_global_wk_pend) begin
            sq_vec_global_wk_pend    <= 1'b1;
            sq_vec_global_wk_fill_id <= ld_da_fill_id;
        end
        else if (sq_pop_depd_ff && sq_vec_global_wk_pend) begin
            sq_vec_global_wk_pend    <= 1'b0;
        end
    end

    logic        sq_vec_data_wk_vld;
    logic [4:0]  sq_vec_data_wk_fill_id;
    always_comb begin
        sq_vec_data_wk_vld     = 1'b0;
        sq_vec_data_wk_fill_id = 5'd0;
        for (int k=0; k<SQ_ENTRY; k++) begin
            if (sq_entry_vec_wk_vld[k]) begin
                sq_vec_data_wk_vld     = 1'b1;
                sq_vec_data_wk_fill_id = sq_entry_vec_wk_fill_id[k];
            end
        end
    end

    assign sq_vec_wk_vld = sq_vec_data_wk_vld ||
                           (sq_pop_depd_ff && sq_vec_global_wk_pend);
    assign sq_vec_wk_fill_id = sq_vec_data_wk_vld ? sq_vec_data_wk_fill_id
                                                  : sq_vec_global_wk_fill_id;

    // ⚠️ 2026-10-18: 同样只 OR 了表项 0~5 (SQ_ENTRY=6 时代的残留)。落在表项 6~11
    //   的 store 数据到达时, 等它数据的 load 收不到唤醒 ⇒ 只能等别的偶然唤醒/冲刷。
    always_comb begin
        sq_data_depd_wakeup = {LSIQ_ENTRY{1'b0}};
        for (int k = 0; k < SQ_ENTRY; k++)
            sq_data_depd_wakeup = sq_data_depd_wakeup | sq_entry_data_depd_wakeup[k];
    end

    //==========================================================
    // Pop entry
    //==========================================================
    always_ff @(posedge sq_pop_clk) begin
        if(!cpurst_b)begin
            sq_pop_addr        <= 32'b0;
            sq_pop_bytes_vld   <= 16'b0;
            sq_pop_ptr         <= {SQ_ENTRY{1'b0}};
        end 
        else if (sq_pe_sel_age_vec_zero_entry_vld) begin
            sq_pop_addr        <= sq_pe_age_vec_zero_addr[31:0];
            sq_pop_bytes_vld   <= sq_pe_age_vec_zero_bytes_vld;
            sq_pop_ptr         <= sq_entry_age_vec_zero_ptr;
        end
        else if (sq_pe_sel_age_vec_surplus1_entry_vld) begin
            sq_pop_addr        <= sq_pe_age_vec_surplus1_addr[31:0];
            sq_pop_bytes_vld   <= sq_pe_age_vec_surplus1_bytes_vld;
            sq_pop_ptr         <= sq_entry_age_vec_surplus1_ptr;
        end
    end

    assign sq_pe_sel_age_vec_zero_entry_vld = |sq_entry_age_vec_zero_ptr;//& (~sq_entry_dcache_info_vld));
    assign sq_pe_sel_age_vec_surplus1_entry_vld = wmb_sq_pop_to_ce_grnt;

    always_comb begin
        sq_pe_age_vec_zero_addr = {PA_WIDTH{1'bx}};
        for (int k=0; k<SQ_ENTRY; k++)
            if (sq_entry_age_vec_zero_ptr[k]) sq_pe_age_vec_zero_addr = sq_entry_addr0[k][31:0];
    end

    always_comb begin
        sq_pe_age_vec_zero_bytes_vld = {16{1'bx}};
        for (int k=0; k<SQ_ENTRY; k++)
            if (sq_entry_age_vec_zero_ptr[k]) sq_pe_age_vec_zero_bytes_vld = sq_entry_bytes_vld[k];
    end


    always_comb begin
        sq_pe_age_vec_surplus1_addr = {PA_WIDTH{1'bx}};
        for (int k=0; k<SQ_ENTRY; k++)
            if (sq_entry_age_vec_surplus1_ptr[k]) sq_pe_age_vec_surplus1_addr = sq_entry_addr0[k][31:0];
    end

    always_comb begin
        sq_pe_age_vec_surplus1_bytes_vld = {16{1'bx}};
        for (int k=0; k<SQ_ENTRY; k++)
            if (sq_entry_age_vec_surplus1_ptr[k]) sq_pe_age_vec_surplus1_bytes_vld = sq_entry_bytes_vld[k];
    end


    //==========================================================
    // Request WMB CE
    //==========================================================
    assign sq_pop_req_unmask = |sq_entry_pop_req;
    assign sq_pop_to_ce_req = sq_pop_req_unmask && !rtu_lsu_async_flush;
    assign sq_entry_pop_to_ce_grnt = {SQ_ENTRY{wmb_sq_pop_to_ce_grnt}} & sq_entry_pop_req;
    assign sq_entry_pop_to_ce_grnt_b = ~sq_entry_pop_to_ce_grnt;

    assign sq_wmb_pop_to_ce_req = sq_pop_to_ce_req;
    assign sq_wmb_merge_stall_req = rb_sq_pop_hit_idx;
    // C910: sq_wmb_merge_req = sq_pop_merge_data_req_unmask = sq_pop_req_unmask && sq_pop_wo_st
    // (wo_st = 普通 store, RV32I 恒为真) —— 移植时漏了这个输出, 导致 wmb_ce_create_merge 悬空,
    // 弹出的 store 在 WMB 里建表项与否变成 X ⇒ store 可能被丢掉。
    assign sq_wmb_merge_req = sq_pop_req_unmask;

    //==========================================================
    // WMB CE data path
    //==========================================================
    always_comb begin
        wmb_ce_data32 = {32{1'bx}};
        for (int k=0; k<SQ_ENTRY; k++)
            if (wmb_ce_sq_ptr[k]) wmb_ce_data32 = sq_entry_data[k];
    end
    assign wmb_ce_data128 = {wmb_ce_data32, wmb_ce_data32, wmb_ce_data32, wmb_ce_data32};

    assign wmb_ce_dcache_valid = |(wmb_ce_sq_ptr & sq_entry_dcache_valid);
    assign wmb_ce_dcache_dirty = |(wmb_ce_sq_ptr & sq_entry_dcache_dirty);
    assign wmb_ce_dcache_way = |(wmb_ce_sq_ptr & sq_entry_dcache_way);
    assign wmb_ce_depd = |(wmb_ce_sq_ptr & sq_entry_depd);
    assign wmb_ce_depd_set = |(wmb_ce_sq_ptr & sq_entry_depd_set);


    //==========================================================
    // Compare dcache write port
    //==========================================================
    lsu_dcache_info_update x_lsu_wmb_ce_dcache_info_update (
        .compare_dcwp_addr       (wmb_ce_addr[31:0]),
        .compare_dcwp_hit_idx    (wmb_ce_dcache_hit_idx),
        .compare_dcwp_update_vld (wmb_ce_dcache_update_vld),
        .dcache_dirty_din        (dcache_dirty_din),
        .dcache_dirty_gwen       (dcache_dirty_gwen),
        .dcache_dirty_wen        (dcache_dirty_wen),
        .dcache_idx              (dcache_idx),
        .dcache_tag_din          (dcache_tag_din),
        .dcache_tag_gwen         (dcache_tag_gwen),
        .dcache_tag_wen          (dcache_tag_wen),
        .origin_dcache_dirty     (wmb_ce_dcache_dirty),
        .origin_dcache_valid     (wmb_ce_dcache_valid),
        .origin_dcache_way       (wmb_ce_dcache_way),
        .update_dcache_dirty     (wmb_ce_update_dcache_dirty),
        .update_dcache_valid     (wmb_ce_update_dcache_valid),
        .update_dcache_way       (wmb_ce_update_dcache_way)
    );

endmodule