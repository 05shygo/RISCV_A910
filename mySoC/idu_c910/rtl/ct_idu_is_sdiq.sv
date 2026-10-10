module ct_idu_is_sdiq(
    input  logic         cpurst_b,
  //  input  logic         lsu_sdiq_has_in_sq_vld,
 //   input  logic         lsu_sq_sdiq_unalign_vld,
    input  logic [3:0]   lsu_sdiq_has_in_sq_sdiq,
 //   input  logic [3:0]   lsu_sq_sdiq_unalign_sdiq,
    input  logic         ctrl_sdiq_create0_en,
    input  logic         ctrl_sdiq_create1_en,
    input  logic [7:0]   dp_sdiq_create0_data,
    input  logic [7:0]   dp_sdiq_create1_data,
    input  logic         forever_cpuclk,
    input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
    input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
    input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
    input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  //  input  logic [11:0]  lsu_idu_ex1_sdiq_entry,
 //   input  logic         lsu_idu_ex1_sdiq_pop_vld,
    input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
    input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
    input  logic         rtu_yy_xx_flush,
    output logic [63:0]  idu_rtu_pst_preg_dealloc_mask,
    output logic         sdiq_ctrl_1_left_updt,
    output logic         sdiq_ctrl_full_updt,
   // output logic [3:0]   sdiq_dp_create0_entry,
    //output logic [3:0]   sdiq_dp_create1_entry,
    output logic         sdiq_issue_en,
    output logic [3:0]   sdiq_dp_issue_entry,
    output logic [7:0]   sdiq_dp_issue_read_data,
    output logic [3:0]   sdiq_create0_entry,
    output logic [3:0]   sdiq_create1_entry
);

parameter int SDIQ_WIDTH = 8;

//----------------------------------------------------------------
// 内部信号声明
//----------------------------------------------------------------
logic            cnt_clk;
logic            src_mask_clk;

// ---------------------------------------------------------------------------
// 本地时钟驱动（2026-10-08 补）
//
// ⚠️ 这两个是 C910 工厂版门控时钟单元的产物, 交付时那批单元被整体剥掉 ⇒
//    全仓无驱动。后果有两个 (接口待办里记的是同一个坑):
//      ① `src_mask_clk` 上的 src_mask 寄存器永不翻转 ⇒ `sdiq_src_mask` 恒 0
//         ⇒ 送出去的 `idu_rtu_pst_preg_dealloc_mask` 恒 0 ⇒ RTU 那侧第 5 态
//         RELEASE 的释放否决口是**死的**(不会误挡, 但也永远覆盖不到);
//      ② `cnt_clk` 上的表项计数器 `sdiq_entry_cnt` 不动 ⇒ 满/空/创建指针的
//         判据全是死的。
//    SDIQ 自己的 always 块内部自带使能条件, 所以直接接 forever_cpuclk 功能等价,
//    只是少了时钟门控的省电效果。本模块的 forever_cpuclk 端口一直存在(见端口表)。
// ---------------------------------------------------------------------------
assign cnt_clk      = forever_cpuclk;
assign src_mask_clk = forever_cpuclk;

// 条目计数器相关
logic [2:0]      sdiq_entry_cnt_create;
logic [2:0]      sdiq_entry_cnt_pop;
logic            sdiq_entry_cnt_updt_vld;
logic [2:0]      sdiq_entry_cnt_updt_val;
logic [2:0]      sdiq_entry_cnt;

// 满/空控制
logic            sdiq_entry_cnt_create_2;
logic            sdiq_entry_cnt_create_1;
logic            sdiq_entry_cnt_create_0;
logic            sdiq_entry_cnt_pop_1;
logic            sdiq_entry_cnt_pop_0;

// 创建指针
logic [3:0]      sdiq_entry_vld;
logic [3:0]      sdiq_entry_create0_in;
logic [3:0]      sdiq_entry_create1_in;
logic [3:0]      sdiq_entry_create_en;
logic [3:0]      sdiq_entry_create0_agevec;
logic [3:0]      sdiq_entry_create1_agevec;

// 各条目创建信号
logic [2:0]      sdiq_entry0_create_agevec;
logic [SDIQ_WIDTH-1:0] sdiq_entry0_create_data;
logic [2:0]      sdiq_entry1_create_agevec;
logic [SDIQ_WIDTH-1:0] sdiq_entry1_create_data;
logic [2:0]      sdiq_entry2_create_agevec;
logic [SDIQ_WIDTH-1:0] sdiq_entry2_create_data;
logic [2:0]      sdiq_entry3_create_agevec;
logic [SDIQ_WIDTH-1:0] sdiq_entry3_create_data;

// 发射控制
logic [3:0]      sdiq_entry_ready;
logic [3:0]      sdiq_older_entry_ready;
logic [3:0]      sdiq_entry_issue_en;
logic [SDIQ_WIDTH-1:0] sdiq_entry_read_data;

// 弹出控制
logic            sdiq_entry0_pop_cur_entry;
logic [2:0]      sdiq_entry0_pop_other_entry;
logic            sdiq_entry1_pop_cur_entry;
logic [2:0]      sdiq_entry1_pop_other_entry;
logic            sdiq_entry2_pop_cur_entry;
logic [2:0]      sdiq_entry2_pop_other_entry;
logic            sdiq_entry3_pop_cur_entry;
logic [2:0]      sdiq_entry3_pop_other_entry;

// 源寄存器掩码
logic            sdiq_src_reg_mask_update_vld;
logic            sdiq_src_reg_mask_update_vld_ff;
logic [63:0]     sdiq_src0_preg_dealloc_mask_updt;
logic [63:0]     sdiq_src0_preg_dealloc_mask;

// 各条目输出
logic [2:0]      sdiq_entry0_agevec;
logic            sdiq_entry0_rdy;
logic [SDIQ_WIDTH-1:0] sdiq_entry0_read_data;
logic [63:0]     sdiq_entry0_src0_preg_expand;
logic            sdiq_entry0_vld;

logic [2:0]      sdiq_entry1_agevec;
logic            sdiq_entry1_rdy;
logic [SDIQ_WIDTH-1:0] sdiq_entry1_read_data;
logic [63:0]     sdiq_entry1_src0_preg_expand;
logic            sdiq_entry1_vld;

logic [2:0]      sdiq_entry2_agevec;
logic            sdiq_entry2_rdy;
logic [SDIQ_WIDTH-1:0] sdiq_entry2_read_data;
logic [63:0]     sdiq_entry2_src0_preg_expand;
logic            sdiq_entry2_vld;

logic [2:0]      sdiq_entry3_agevec;
logic            sdiq_entry3_rdy;
logic [SDIQ_WIDTH-1:0] sdiq_entry3_read_data;
logic [63:0]     sdiq_entry3_src0_preg_expand;
logic            sdiq_entry3_vld;

// 其他
logic [3:0]      lsu_sdiq_has_in_sq;
//logic [3:0]      lsu_sq_sdiq_unalign;

//----------------------------------------------------------------
// 条目计数器
//----------------------------------------------------------------
assign sdiq_entry_cnt_create[2:0]   = {2'b0, ctrl_sdiq_create0_en}
                                      + {2'b0, ctrl_sdiq_create1_en};

assign sdiq_entry_cnt_pop[2:0]      = {2'b0, sdiq_issue_en};

assign sdiq_entry_cnt_updt_vld      = ctrl_sdiq_create0_en
                                      || sdiq_issue_en;

assign sdiq_entry_cnt_updt_val[2:0] = sdiq_entry_cnt[2:0]
                                      + sdiq_entry_cnt_create[2:0]
                                      - sdiq_entry_cnt_pop[2:0];

always @(posedge cnt_clk or negedge cpurst_b)
begin
    if (!cpurst_b)
        sdiq_entry_cnt[2:0] <= 3'b0;
    else if (rtu_yy_xx_flush)
        sdiq_entry_cnt[2:0] <= 3'b0;
    else if (sdiq_entry_cnt_updt_vld)
        sdiq_entry_cnt[2:0] <= sdiq_entry_cnt_updt_val[2:0];
    else
        sdiq_entry_cnt[2:0] <= sdiq_entry_cnt[2:0];
end


//----------------------------------------------------------------
// 条目满信号
//----------------------------------------------------------------
assign sdiq_entry_cnt_create_2 =  ctrl_sdiq_create1_en;
assign sdiq_entry_cnt_create_1 =  ctrl_sdiq_create0_en && !ctrl_sdiq_create1_en;
assign sdiq_entry_cnt_create_0 = !ctrl_sdiq_create0_en;

assign sdiq_entry_cnt_pop_1    =  sdiq_issue_en;
assign sdiq_entry_cnt_pop_0    = !sdiq_issue_en;

assign sdiq_ctrl_full_updt     = (sdiq_entry_cnt[2:0] == 4'd2)
                                 && sdiq_entry_cnt_create_2
                                 && sdiq_entry_cnt_pop_0
                              || (sdiq_entry_cnt[2:0] == 4'd3)
                                 && sdiq_entry_cnt_create_1
                                 && sdiq_entry_cnt_pop_0
                              || (sdiq_entry_cnt[2:0] == 4'd4)
                                 && sdiq_entry_cnt_create_0
                                 && sdiq_entry_cnt_pop_0;

assign sdiq_ctrl_1_left_updt   = (sdiq_entry_cnt[2:0] == 4'd1)
                                 && sdiq_entry_cnt_create_2
                                 && sdiq_entry_cnt_pop_0
                              || (sdiq_entry_cnt[2:0] == 4'd2)
                                 && sdiq_entry_cnt_create_1
                                 && sdiq_entry_cnt_pop_0
                              || (sdiq_entry_cnt[2:0] == 4'd2)
                                 && sdiq_entry_cnt_create_2
                                 && sdiq_entry_cnt_pop_1
                              || (sdiq_entry_cnt[2:0] == 4'd3)
                                 && sdiq_entry_cnt_create_0
                                 && sdiq_entry_cnt_pop_0
                              || (sdiq_entry_cnt[2:0] == 4'd3)
                                 && sdiq_entry_cnt_create_1
                                 && sdiq_entry_cnt_pop_1
                              || (sdiq_entry_cnt[2:0] == 4'd4)
                                 && sdiq_entry_cnt_create_0
                                 && sdiq_entry_cnt_pop_1;

//----------------------------------------------------------------
// 创建指针
//----------------------------------------------------------------
assign sdiq_create0_entry[3:0] = sdiq_entry_create0_in[3:0];
assign sdiq_create1_entry[3:0] = sdiq_entry_create1_in[3:0];

assign sdiq_entry_vld[3:0] =
       {sdiq_entry3_vld, sdiq_entry2_vld, sdiq_entry1_vld, sdiq_entry0_vld};

// create0 优先级：entry0 -> entry1 -> entry2 -> entry3
always @(*)
begin
    casez (sdiq_entry_vld[3:0])
        4'b???0: sdiq_entry_create0_in[3:0] = 4'b0001;
        4'b??01: sdiq_entry_create0_in[3:0] = 4'b0010;
        4'b?011: sdiq_entry_create0_in[3:0] = 4'b0100;
        4'b0111: sdiq_entry_create0_in[3:0] = 4'b1000;
        default: sdiq_entry_create0_in[3:0] = 4'b0000;
    endcase
end

// create1 优先级：entry3 -> entry2 -> entry1 -> entry0
always @(*)
begin
    casez (sdiq_entry_vld[3:0])
        4'b0???: sdiq_entry_create1_in[3:0] = 4'b1000;
        4'b10??: sdiq_entry_create1_in[3:0] = 4'b0100;
        4'b110?: sdiq_entry_create1_in[3:0] = 4'b0010;
        4'b1110: sdiq_entry_create1_in[3:0] = 4'b0001;
        default: sdiq_entry_create1_in[3:0] = 4'b0000;
    endcase
end

assign sdiq_entry_create_en[3:0] =
       {4{ctrl_sdiq_create0_en}} & sdiq_entry_create0_in[3:0]
     | {4{ctrl_sdiq_create1_en}} & sdiq_entry_create1_in[3:0];

//----------------------------------------------------------------
// 准备创建信号
//----------------------------------------------------------------
assign sdiq_entry_create0_agevec[3:0] = sdiq_entry_vld[3:0]
                                         & ~({4{sdiq_issue_en}}
                                            & sdiq_dp_issue_entry[3:0]);

assign sdiq_entry_create1_agevec[3:0] = sdiq_entry_vld[3:0]
                                         & ~({4{sdiq_issue_en}}
                                            & sdiq_dp_issue_entry[3:0])
                                         | sdiq_entry_create0_in[3:0];

//----------------------------------------------------------------
// entry0 flop create signals
//----------------------------------------------------------------
always @(*)
begin
    if (sdiq_entry_create0_in[0]) begin
        sdiq_entry0_create_agevec[2:0] = sdiq_entry_create0_agevec[3:1];
        sdiq_entry0_create_data[SDIQ_WIDTH-1:0] =
            dp_sdiq_create0_data[SDIQ_WIDTH-1:0];
    end
    else begin
        sdiq_entry0_create_agevec[2:0] = sdiq_entry_create1_agevec[3:1];
        sdiq_entry0_create_data[SDIQ_WIDTH-1:0] =
            dp_sdiq_create1_data[SDIQ_WIDTH-1:0];
    end
end

//----------------------------------------------------------------
// entry1 flop create signals
//----------------------------------------------------------------
always @(*)
begin
    if (sdiq_entry_create0_in[1]) begin
        sdiq_entry1_create_agevec[2:0] = {sdiq_entry_create0_agevec[3:2],
                                           sdiq_entry_create0_agevec[0]};
        sdiq_entry1_create_data[SDIQ_WIDTH-1:0] =
            dp_sdiq_create0_data[SDIQ_WIDTH-1:0];
    end
    else begin
        sdiq_entry1_create_agevec[2:0] = {sdiq_entry_create1_agevec[3:2],
                                           sdiq_entry_create1_agevec[0]};
        sdiq_entry1_create_data[SDIQ_WIDTH-1:0] =
            dp_sdiq_create1_data[SDIQ_WIDTH-1:0];
    end
end

//----------------------------------------------------------------
// entry2 flop create signals
//----------------------------------------------------------------
always @(*)
begin
    if (sdiq_entry_create0_in[2]) begin
        sdiq_entry2_create_agevec[2:0] = {sdiq_entry_create0_agevec[3],
                                           sdiq_entry_create0_agevec[1:0]};
        sdiq_entry2_create_data[SDIQ_WIDTH-1:0] =
            dp_sdiq_create0_data[SDIQ_WIDTH-1:0];
    end
    else begin
        sdiq_entry2_create_agevec[2:0] = {sdiq_entry_create1_agevec[3],
                                           sdiq_entry_create1_agevec[1:0]};
        sdiq_entry2_create_data[SDIQ_WIDTH-1:0] =
            dp_sdiq_create1_data[SDIQ_WIDTH-1:0];
    end
end

//----------------------------------------------------------------
// entry3 flop create signals
//----------------------------------------------------------------
always @(*)
begin
    if (sdiq_entry_create0_in[3]) begin
        sdiq_entry3_create_agevec[2:0] = sdiq_entry_create0_agevec[2:0];
        sdiq_entry3_create_data[SDIQ_WIDTH-1:0] =
            dp_sdiq_create0_data[SDIQ_WIDTH-1:0];
    end
    else begin
        sdiq_entry3_create_agevec[2:0] = sdiq_entry_create1_agevec[2:0];
        sdiq_entry3_create_data[SDIQ_WIDTH-1:0] =
            dp_sdiq_create1_data[SDIQ_WIDTH-1:0];
    end
end

//==========================================================
//             LSU Issue Queue Issue Control
//==========================================================
assign sdiq_entry_ready[3:0] =
       {sdiq_entry3_rdy, sdiq_entry2_rdy, sdiq_entry1_rdy, sdiq_entry0_rdy};

assign sdiq_older_entry_ready[0] = |(sdiq_entry0_agevec[2:0]
                                     & sdiq_entry_ready[3:1]);
assign sdiq_older_entry_ready[1] = |(sdiq_entry1_agevec[2:0]
                                     & {sdiq_entry_ready[3:2],
                                        sdiq_entry_ready[0]});
assign sdiq_older_entry_ready[2] = |(sdiq_entry2_agevec[2:0]
                                     & {sdiq_entry_ready[3],
                                        sdiq_entry_ready[1:0]});
assign sdiq_older_entry_ready[3] = |(sdiq_entry3_agevec[2:0]
                                     & sdiq_entry_ready[2:0]);

assign sdiq_entry_issue_en[3:0] = sdiq_entry_ready[3:0]
                                  & ~sdiq_older_entry_ready[3:0];

assign sdiq_dp_issue_entry[3:0] = sdiq_entry_issue_en[3:0];
assign sdiq_issue_en = |sdiq_entry_issue_en[3:0];

always @(*)
begin
    case (sdiq_entry_issue_en[3:0])
        4'h1: sdiq_entry_read_data[SDIQ_WIDTH-1:0] =
                  sdiq_entry0_read_data[SDIQ_WIDTH-1:0];
        4'h2: sdiq_entry_read_data[SDIQ_WIDTH-1:0] =
                  sdiq_entry1_read_data[SDIQ_WIDTH-1:0];
        4'h4: sdiq_entry_read_data[SDIQ_WIDTH-1:0] =
                  sdiq_entry2_read_data[SDIQ_WIDTH-1:0];
        4'h8: sdiq_entry_read_data[SDIQ_WIDTH-1:0] =
                  sdiq_entry3_read_data[SDIQ_WIDTH-1:0];
        default: sdiq_entry_read_data[SDIQ_WIDTH-1:0] =
                     {SDIQ_WIDTH{1'bx}};
    endcase
end

assign sdiq_dp_issue_read_data[SDIQ_WIDTH-1:0] =
       sdiq_entry_read_data[SDIQ_WIDTH-1:0];

//==========================================================
//            LSU Issue Queue Launch Control
//==========================================================
assign {sdiq_entry0_pop_other_entry[2:0],
        sdiq_entry0_pop_cur_entry}          = sdiq_dp_issue_entry[3:0];
assign {sdiq_entry1_pop_other_entry[2:1],
        sdiq_entry1_pop_cur_entry,
        sdiq_entry1_pop_other_entry[0]}     = sdiq_dp_issue_entry[3:0];
assign {sdiq_entry2_pop_other_entry[2],
        sdiq_entry2_pop_cur_entry,
        sdiq_entry2_pop_other_entry[1:0]}   = sdiq_dp_issue_entry[3:0];
assign {sdiq_entry3_pop_cur_entry,
        sdiq_entry3_pop_other_entry[2:0]}   = sdiq_dp_issue_entry[3:0];

//==========================================================
//            LSU Issue Queue Create Control
//==========================================================
assign sdiq_src_reg_mask_update_vld = rtu_yy_xx_flush
                                      || ctrl_sdiq_create0_en
                                      || ctrl_sdiq_create1_en
                                      || sdiq_issue_en;

always @(posedge src_mask_clk or negedge cpurst_b)
begin
    if (!cpurst_b)
        sdiq_src_reg_mask_update_vld_ff <= 1'b0;
    else if (rtu_yy_xx_flush)
        sdiq_src_reg_mask_update_vld_ff <= 1'b0;
    else if (sdiq_src_reg_mask_update_vld)
        sdiq_src_reg_mask_update_vld_ff <= 1'b1;
    else
        sdiq_src_reg_mask_update_vld_ff <= 1'b0;
end

assign sdiq_src0_preg_dealloc_mask_updt[63:0] =
           sdiq_entry0_src0_preg_expand[63:0]
         | sdiq_entry1_src0_preg_expand[63:0]
         | sdiq_entry2_src0_preg_expand[63:0]
         | sdiq_entry3_src0_preg_expand[63:0];

always @(posedge src_mask_clk or negedge cpurst_b)
begin
    if (!cpurst_b)
        sdiq_src0_preg_dealloc_mask[63:0] <= 64'b0;
    else if (rtu_yy_xx_flush)
        sdiq_src0_preg_dealloc_mask[63:0] <= 64'b0;
    else if (sdiq_src_reg_mask_update_vld_ff)
        sdiq_src0_preg_dealloc_mask[63:0] <= sdiq_src0_preg_dealloc_mask_updt[63:0];
    else
        sdiq_src0_preg_dealloc_mask[63:0] <= sdiq_src0_preg_dealloc_mask[63:0];
end

assign idu_rtu_pst_preg_dealloc_mask[63:0] = sdiq_src0_preg_dealloc_mask[63:0];

//==========================================================
//             LSU Issue Queue Entry Instance
//==========================================================
assign lsu_sdiq_has_in_sq =lsu_sdiq_has_in_sq_sdiq[3:0];
//assign lsu_sq_sdiq_unalign = {4{lsu_sq_sdiq_unalign_vld}} & lsu_sq_sdiq_unalign_sdiq[3:0];

// entry 0
ct_idu_is_sdiq_entry u_ct_idu_is_sdiq_entry_0 (
    .cpurst_b                           (cpurst_b                           ),
    .lsu_sdiq_has_in_sq                 (lsu_sdiq_has_in_sq[0]              ),
  //  .lsu_sq_sdiq_unalign                (lsu_sq_sdiq_unalign[0]             ),
    .forever_cpuclk                     (forever_cpuclk                     ),
    .iu_idu_ex2_pipe0_wb_preg_dupx      (iu_idu_ex2_pipe0_wb_preg_dupx      ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx  (iu_idu_ex2_pipe0_wb_preg_vld_dupx  ),
    .iu_idu_ex2_pipe1_wb_preg_dupx      (iu_idu_ex2_pipe1_wb_preg_dupx      ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx  (iu_idu_ex2_pipe1_wb_preg_vld_dupx  ),
    .lsu_idu_ex1_sdiq_pop_vld           (sdiq_issue_en           ),
    .lsu_idu_wb_pipe3_wb_preg_dupx      (lsu_idu_wb_pipe3_wb_preg_dupx      ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx  (lsu_idu_wb_pipe3_wb_preg_vld_dupx  ),
    .rtu_yy_xx_flush                    (rtu_yy_xx_flush                    ),
    .x_create_agevec                    (sdiq_entry0_create_agevec          ),
    .x_create_data                      (sdiq_entry0_create_data            ),
    .x_create_en                        (sdiq_entry_create_en[0]            ),
    .x_issue_en                         (sdiq_entry_issue_en[0]             ),
    .x_pop_cur_entry                    (sdiq_entry0_pop_cur_entry          ),
    .x_pop_other_entry                  (sdiq_entry0_pop_other_entry        ),
    .x_agevec                           (sdiq_entry0_agevec                 ),
    .x_rdy                              (sdiq_entry0_rdy                    ),
    .x_read_data                        (sdiq_entry0_read_data              ),
    .x_src0_preg_expand                 (sdiq_entry0_src0_preg_expand       ),
    .x_vld                              (sdiq_entry0_vld                    )
);

// entry 1
ct_idu_is_sdiq_entry u_ct_idu_is_sdiq_entry_1 (
    .cpurst_b                           (cpurst_b                           ),
    .lsu_sdiq_has_in_sq                 (lsu_sdiq_has_in_sq[1]              ),
  //  .lsu_sq_sdiq_unalign                (lsu_sq_sdiq_unalign[1]             ),
    .forever_cpuclk                     (forever_cpuclk                     ),
    .iu_idu_ex2_pipe0_wb_preg_dupx      (iu_idu_ex2_pipe0_wb_preg_dupx      ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx  (iu_idu_ex2_pipe0_wb_preg_vld_dupx  ),
    .iu_idu_ex2_pipe1_wb_preg_dupx      (iu_idu_ex2_pipe1_wb_preg_dupx      ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx  (iu_idu_ex2_pipe1_wb_preg_vld_dupx  ),
    .lsu_idu_ex1_sdiq_pop_vld           (sdiq_issue_en           ),
    .lsu_idu_wb_pipe3_wb_preg_dupx      (lsu_idu_wb_pipe3_wb_preg_dupx      ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx  (lsu_idu_wb_pipe3_wb_preg_vld_dupx  ),
    .rtu_yy_xx_flush                    (rtu_yy_xx_flush                    ),
    .x_create_agevec                    (sdiq_entry1_create_agevec          ),
    .x_create_data                      (sdiq_entry1_create_data            ),
    .x_create_en                        (sdiq_entry_create_en[1]            ),
    .x_issue_en                         (sdiq_entry_issue_en[1]             ),
    .x_pop_cur_entry                    (sdiq_entry1_pop_cur_entry          ),
    .x_pop_other_entry                  (sdiq_entry1_pop_other_entry        ),
    .x_agevec                           (sdiq_entry1_agevec                 ),
    .x_rdy                              (sdiq_entry1_rdy                    ),
    .x_read_data                        (sdiq_entry1_read_data              ),
    .x_src0_preg_expand                 (sdiq_entry1_src0_preg_expand       ),
    .x_vld                              (sdiq_entry1_vld                    )
);

// entry 2
ct_idu_is_sdiq_entry u_ct_idu_is_sdiq_entry_2 (
    .cpurst_b                           (cpurst_b                           ),
    .lsu_sdiq_has_in_sq                 (lsu_sdiq_has_in_sq[2]              ),
  //  .lsu_sq_sdiq_unalign                (lsu_sq_sdiq_unalign[2]             ),
    .forever_cpuclk                     (forever_cpuclk                     ),
    .iu_idu_ex2_pipe0_wb_preg_dupx      (iu_idu_ex2_pipe0_wb_preg_dupx      ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx  (iu_idu_ex2_pipe0_wb_preg_vld_dupx  ),
    .iu_idu_ex2_pipe1_wb_preg_dupx      (iu_idu_ex2_pipe1_wb_preg_dupx      ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx  (iu_idu_ex2_pipe1_wb_preg_vld_dupx  ),
    .lsu_idu_ex1_sdiq_pop_vld           (sdiq_issue_en           ),
    .lsu_idu_wb_pipe3_wb_preg_dupx      (lsu_idu_wb_pipe3_wb_preg_dupx      ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx  (lsu_idu_wb_pipe3_wb_preg_vld_dupx  ),
    .rtu_yy_xx_flush                    (rtu_yy_xx_flush                    ),
    .x_create_agevec                    (sdiq_entry2_create_agevec          ),
    .x_create_data                      (sdiq_entry2_create_data            ),
    .x_create_en                        (sdiq_entry_create_en[2]            ),
    .x_issue_en                         (sdiq_entry_issue_en[2]             ),
    .x_pop_cur_entry                    (sdiq_entry2_pop_cur_entry          ),
    .x_pop_other_entry                  (sdiq_entry2_pop_other_entry        ),
    .x_agevec                           (sdiq_entry2_agevec                 ),
    .x_rdy                              (sdiq_entry2_rdy                    ),
    .x_read_data                        (sdiq_entry2_read_data              ),
    .x_src0_preg_expand                 (sdiq_entry2_src0_preg_expand       ),
    .x_vld                              (sdiq_entry2_vld                    )
);

// entry 3
ct_idu_is_sdiq_entry u_ct_idu_is_sdiq_entry_3 (
    .cpurst_b                           (cpurst_b                           ),
    .lsu_sdiq_has_in_sq                 (lsu_sdiq_has_in_sq[3]              ),
 //   .lsu_sq_sdiq_unalign                (lsu_sq_sdiq_unalign[3]             ),
    .forever_cpuclk                     (forever_cpuclk                     ),
    .iu_idu_ex2_pipe0_wb_preg_dupx      (iu_idu_ex2_pipe0_wb_preg_dupx      ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx  (iu_idu_ex2_pipe0_wb_preg_vld_dupx  ),
    .iu_idu_ex2_pipe1_wb_preg_dupx      (iu_idu_ex2_pipe1_wb_preg_dupx      ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx  (iu_idu_ex2_pipe1_wb_preg_vld_dupx  ),
    .lsu_idu_ex1_sdiq_pop_vld           (sdiq_issue_en           ),
    .lsu_idu_wb_pipe3_wb_preg_dupx      (lsu_idu_wb_pipe3_wb_preg_dupx      ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx  (lsu_idu_wb_pipe3_wb_preg_vld_dupx  ),
    .rtu_yy_xx_flush                    (rtu_yy_xx_flush                    ),
    .x_create_agevec                    (sdiq_entry3_create_agevec          ),
    .x_create_data                      (sdiq_entry3_create_data            ),
    .x_create_en                        (sdiq_entry_create_en[3]            ),
    .x_issue_en                         (sdiq_entry_issue_en[3]             ),
    .x_pop_cur_entry                    (sdiq_entry3_pop_cur_entry          ),
    .x_pop_other_entry                  (sdiq_entry3_pop_other_entry        ),
    .x_agevec                           (sdiq_entry3_agevec                 ),
    .x_rdy                              (sdiq_entry3_rdy                    ),
    .x_read_data                        (sdiq_entry3_read_data              ),
    .x_src0_preg_expand                 (sdiq_entry3_src0_preg_expand       ),
    .x_vld                              (sdiq_entry3_vld                    )
);

endmodule