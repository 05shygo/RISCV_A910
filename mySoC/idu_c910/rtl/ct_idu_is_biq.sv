module ct_idu_is_biq (
  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic         biq_ctrl_1_left_updt,
  output logic         biq_ctrl_full_updt,
  output logic         biq_xx_issue_en,
  output logic [151:0] biq_dp_issue_read_data,

  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         cpurst_b,
  input  logic         ctrl_biq_create0_en,
  input  logic         ctrl_biq_create1_en,
  input  logic [151:0] dp_biq_create0_data,
  input  logic [151:0] dp_biq_create1_data,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush
);
parameter BIQ_WIDTH             = 152;
parameter BIQ_CHK               = 151;   // 2026-10-08 修: 原来漏了分号 ⇒ 本文件语法错 ⇒ 整个 IDU 编不过
parameter BIQ_PC                = 126;
parameter BIQ_IID               = 61;
parameter BIQ_DST_PREG          = 54;
parameter BIQ_SRC1_DATA         = 48;
parameter BIQ_SRC0_DATA         = 41;
parameter BIQ_DST_VLD           = 34;
parameter BIQ_SRC1_VLD          = 33;
parameter BIQ_SRC0_VLD          = 32;
parameter BIQ_OPCODE            = 31;

    //----------------------------------------------------------------------------
    // Internal signals
    //----------------------------------------------------------------------------
    logic [2:0]  biq_entry_cnt;
    logic [2:0]  biq_entry_cnt_create;
    logic        biq_entry_cnt_updt_vld;
    logic [2:0]  biq_entry_cnt_updt_val;
    logic        biq_entry_cnt_create_2;
    logic        biq_entry_cnt_create_1;
    logic        biq_entry_cnt_create_0;
    logic        biq_entry_cnt_pop_1;
    logic        biq_entry_cnt_pop_0;

    logic [3:0]  biq_entry_vld;
    logic        biq_entry0_vld;
    logic        biq_entry1_vld;
    logic        biq_entry2_vld;
    logic        biq_entry3_vld;

    logic [3:0]  biq_entry_create0_in;
    logic [7:0]  biq_entry_create1_in;
    logic [3:0]  biq_entry_create_en;
    logic        biq_entry0_create_en;
    logic        biq_entry1_create_en;
    logic        biq_entry2_create_en;
    logic        biq_entry3_create_en;

    logic [3:0]  biq_entry_create0_agevec;
    logic [3:0]  biq_entry_create1_agevec;
    logic [7:0]  biq_entry_create_sel;

    logic [2:0]  biq_entry0_create_agevec;
    logic [2:0]  biq_entry1_create_agevec;
    logic [2:0]  biq_entry2_create_agevec;
    logic [2:0]  biq_entry3_create_agevec;

    logic [BIQ_WIDTH-1:0] biq_entry0_create_data;
    logic [BIQ_WIDTH-1:0] biq_entry1_create_data;
    logic [BIQ_WIDTH-1:0] biq_entry2_create_data;
    logic [BIQ_WIDTH-1:0] biq_entry3_create_data;

    logic [2:0]  biq_entry0_pop_other_entry;
    logic [2:0]  biq_entry1_pop_other_entry;
    logic [2:0]  biq_entry2_pop_other_entry;
    logic [2:0]  biq_entry3_pop_other_entry;
    logic        biq_entry0_pop_cur_entry;
    logic        biq_entry1_pop_cur_entry;
    logic        biq_entry2_pop_cur_entry;
    logic        biq_entry3_pop_cur_entry;

    logic [3:0]  biq_older_entry_ready;
    logic [3:0]  biq_entry_issue_en;
    logic [BIQ_WIDTH-1:0] biq_entry_read_data;

    logic [3:0]  biq_entry_ready;
    logic [2:0]  biq_entry0_agevec;
    logic [2:0]  biq_entry1_agevec;
    logic [2:0]  biq_entry2_agevec;
    logic [2:0]  biq_entry3_agevec;
    logic [BIQ_WIDTH-1:0] biq_entry0_read_data;
    logic [BIQ_WIDTH-1:0] biq_entry1_read_data;
    logic [BIQ_WIDTH-1:0] biq_entry2_read_data;
    logic [BIQ_WIDTH-1:0] biq_entry3_read_data;

//--------------------biq entry counter--------------------
//if create, add entry counter
assign biq_entry_cnt_create[2:0]   = {2'b0,ctrl_biq_create0_en}
                                      + {2'b0,ctrl_biq_create1_en};
//update valid and value
assign biq_entry_cnt_updt_vld      = ctrl_biq_create0_en
                                      || biq_xx_issue_en;
assign biq_entry_cnt_updt_val[2:0] = biq_entry_cnt[2:0]
                                      + biq_entry_cnt_create[2:0]
                                      - {2'b0,biq_xx_issue_en};
//implement entry counter
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    biq_entry_cnt[2:0] <= 3'b0;
  //after flush fe/is, the rf may wrongly pop before rtu_yy_xx_flush
  //need flush also when rtu_yy_xx_flush
  else if(rtu_yy_xx_flush)
    biq_entry_cnt[2:0] <= 3'b0;
  else if(biq_entry_cnt_updt_vld)
    biq_entry_cnt[2:0] <= biq_entry_cnt_updt_val[2:0];
  else
    biq_entry_cnt[2:0] <= biq_entry_cnt[2:0];
end

//--------------------biq entry full-----------------------
assign biq_entry_cnt_create_2 =  ctrl_biq_create1_en;
assign biq_entry_cnt_create_1 =  ctrl_biq_create0_en && !ctrl_biq_create1_en;
assign biq_entry_cnt_create_0 = !ctrl_biq_create0_en;

assign biq_entry_cnt_pop_1    =  biq_xx_issue_en;
assign biq_entry_cnt_pop_0    = !biq_xx_issue_en;

assign biq_ctrl_full_updt     = (biq_entry_cnt[2:0] == 3'd2)
                                 && biq_entry_cnt_create_2
                                 && biq_entry_cnt_pop_0
                              || (biq_entry_cnt[2:0] == 3'd3)
                                 && biq_entry_cnt_create_1
                                 && biq_entry_cnt_pop_0
                              || (biq_entry_cnt[2:0] == 3'd4)
                                 && biq_entry_cnt_create_0
                                 && biq_entry_cnt_pop_0;

assign biq_ctrl_1_left_updt   = (biq_entry_cnt[2:0] == 3'd1)
                                 && biq_entry_cnt_create_2
                                 && biq_entry_cnt_pop_0
                              || (biq_entry_cnt[2:0] == 3'd2)
                                 && biq_entry_cnt_create_1
                                 && biq_entry_cnt_pop_0
                              || (biq_entry_cnt[2:0] == 3'd2)
                                 && biq_entry_cnt_create_2
                                 && biq_entry_cnt_pop_1
                              || (biq_entry_cnt[2:0] == 3'd3)
                                 && biq_entry_cnt_create_0
                                 && biq_entry_cnt_pop_0
                              || (biq_entry_cnt[2:0] == 3'd3)
                                 && biq_entry_cnt_create_1
                                 && biq_entry_cnt_pop_1
                              || (biq_entry_cnt[2:0] == 3'd4)
                                 && biq_entry_cnt_create_0
                                 && biq_entry_cnt_pop_1;

//issue queue entry create control
assign biq_entry_vld[0]         = biq_entry0_vld;
assign biq_entry_vld[1]         = biq_entry1_vld;
assign biq_entry_vld[2]         = biq_entry2_vld;
assign biq_entry_vld[3]         = biq_entry3_vld;


//create0 priority is from entry 0 to 7
// &CombBeg; @178
always @(*)
begin
  casez ({biq_entry0_vld, biq_entry1_vld, biq_entry2_vld, biq_entry3_vld})
    4'b0???: biq_entry_create0_in = 4'b0001; // entry0 空闲，选 0
    4'b10??: biq_entry_create0_in = 4'b0010; // 0 忙，1 空闲，选 1
    4'b110?: biq_entry_create0_in = 4'b0100; // 0/1 忙，2 空闲，选 2
    4'b1110: biq_entry_create0_in = 4'b1000; // 0/1/2 忙，3 空闲，选 3
    default: biq_entry_create0_in = 4'b0000; // 全忙
  endcase
// &CombEnd; @197
end
always @(*)
begin
  casez ({biq_entry3_vld, biq_entry2_vld, biq_entry1_vld, biq_entry0_vld})
    4'b0???: biq_entry_create1_in = 4'b1000; // entry3 空闲，选 3
    4'b10??: biq_entry_create1_in = 4'b0100; // 3 忙，2 空闲，选 2
    4'b110?: biq_entry_create1_in = 4'b0010; // 3/2 忙，1 空闲，选 1
    4'b1110: biq_entry_create1_in = 4'b0001; // 3/2/1 忙，0 空闲，选 0
    default: biq_entry_create1_in = 4'b0000; // 全忙
  endcase
// &CombEnd; @219
end

assign biq_entry_create_en[3:0] =
       {4{ctrl_biq_create0_en}} & biq_entry_create0_in[3:0]
     | {4{ctrl_biq_create1_en}} & biq_entry_create1_in[3:0];

assign biq_entry0_create_en     = biq_entry_create_en[0];
assign biq_entry1_create_en     = biq_entry_create_en[1];
assign biq_entry2_create_en     = biq_entry_create_en[2];
assign biq_entry3_create_en     = biq_entry_create_en[3];

//biq create entry should consider pop signal and create0
assign biq_entry_create0_agevec[3:0] = biq_entry_vld[3:0]
                                        & ~({4{biq_xx_issue_en}}
                                           & biq_entry_issue_en[3:0]);

assign biq_entry_create1_agevec[3:0] = biq_entry_vld[3:0]
                                        & ~({4{biq_xx_issue_en}}
                                           & biq_entry_issue_en[3:0])
                                        | biq_entry_create0_in[3:0];

//create 0/1 select:
//entry 0~3 use ~biq_entry_create0_in for better timing
//entry 4~7 use biq_entry_create1_in for better timing
//biq_entry_create0/1_in cannot be both 1,
//if both 0, do not create
assign biq_entry_create_sel[7:4] = {4{ctrl_biq_create1_en}}
                                     & biq_entry_create1_in[7:4];
assign biq_entry_create_sel[3:0] = ~({4{ctrl_biq_create0_en}}
                                      & biq_entry_create0_in[3:0]);

//----------------entry0 flop create signals----------------
// &CombBeg; @297
always @(*)
begin
  if(biq_entry_create0_in[0]) begin
    biq_entry0_create_agevec[2:0] = biq_entry_create0_agevec[3:1];
    biq_entry0_create_data[BIQ_WIDTH-1:0] = 
       dp_biq_create0_data[BIQ_WIDTH-1:0];
  end
  else begin
    biq_entry0_create_agevec[2:0] = biq_entry_create1_agevec[3:1];
    biq_entry0_create_data[BIQ_WIDTH-1:0] = 
       dp_biq_create1_data[BIQ_WIDTH-1:0];
  end
// &CombEnd; @310
end

//----------------entry1 flop create signals----------------
// &CombBeg; @313
always @(*)
begin
  if(biq_entry_create0_in[1]) begin
    biq_entry1_create_agevec[2:0] = {biq_entry_create0_agevec[3:2],
                                      biq_entry_create0_agevec[0]};
    biq_entry1_create_data[BIQ_WIDTH-1:0] =
       dp_biq_create0_data[BIQ_WIDTH-1:0];
  end
  else begin
    biq_entry1_create_agevec[2:0] = {biq_entry_create1_agevec[3:2],
                                      biq_entry_create1_agevec[0]};
    biq_entry1_create_data[BIQ_WIDTH-1:0] =
       dp_biq_create1_data[BIQ_WIDTH-1:0];
  end
// &CombEnd; @328
end

//----------------entry2 flop create signals----------------
// &CombBeg; @331
always @(*)
begin
  if(biq_entry_create0_in[2]) begin
    biq_entry2_create_agevec[2:0] = {biq_entry_create0_agevec[3],
                                      biq_entry_create0_agevec[1:0]};
    biq_entry2_create_data[BIQ_WIDTH-1:0] =
       dp_biq_create0_data[BIQ_WIDTH-1:0];
  end
  else begin
    biq_entry2_create_agevec[2:0] = {biq_entry_create1_agevec[3],
                                      biq_entry_create1_agevec[1:0]};
    biq_entry2_create_data[BIQ_WIDTH-1:0] =
       dp_biq_create1_data[BIQ_WIDTH-1:0];
  end
// &CombEnd; @346
end

//----------------entry3 flop create signals----------------
// &CombBeg; @349
always @(*)
begin
  if(biq_entry_create0_in[3]) begin
    biq_entry3_create_agevec[2:0] = biq_entry_create0_agevec[2:0];
    biq_entry3_create_data[BIQ_WIDTH-1:0] =
       dp_biq_create0_data[BIQ_WIDTH-1:0];
  end
  else begin
    biq_entry3_create_agevec[2:0] = biq_entry_create1_agevec[2:0];
    biq_entry3_create_data[BIQ_WIDTH-1:0] =
       dp_biq_create1_data[BIQ_WIDTH-1:0];
  end
// &CombEnd; @364
end

//-------------------entry pop enable signals---------------
//pop when rf launch pass
assign {biq_entry0_pop_other_entry[2:0],
        biq_entry0_pop_cur_entry}        = biq_entry_issue_en[3:0];
assign {biq_entry1_pop_other_entry[2:1],
        biq_entry1_pop_cur_entry,
        biq_entry1_pop_other_entry[0]}   = biq_entry_issue_en[3:0];
assign {biq_entry2_pop_other_entry[2],
        biq_entry2_pop_cur_entry,
        biq_entry2_pop_other_entry[1:0]} = biq_entry_issue_en[3:0];
assign {biq_entry3_pop_cur_entry,
        biq_entry3_pop_other_entry[2:0]} = biq_entry_issue_en[3:0];

//------------------entry issue enable signals--------------
//first find older ready entry
assign biq_older_entry_ready[0] = |(biq_entry0_agevec[2:0]
                                     & biq_entry_ready[3:1]);
assign biq_older_entry_ready[1] = |(biq_entry1_agevec[2:0]
                                     & {biq_entry_ready[3:2],
                                        biq_entry_ready[0]});
assign biq_older_entry_ready[2] = |(biq_entry2_agevec[2:0]
                                     & {biq_entry_ready[3],
                                        biq_entry_ready[1:0]});
assign biq_older_entry_ready[3] = |(biq_entry3_agevec[2:0]
                                     & biq_entry_ready[2:0]);
//not ready if older ready exists
assign biq_entry_issue_en[3:0]  = biq_entry_ready[3:0]
                                   & ~biq_older_entry_ready[3:0];
//rename for entries

assign biq_xx_issue_en = |biq_entry_issue_en[3:0];
//-----------------issue data path selection----------------
//issue data path will select oldest ready entry in issue queue
//if no instruction valid, the data path will always select bypass 
//data path
// &CombBeg; @527
always @(*)
begin
  case (biq_entry_issue_en[3:0])
    4'h01  : biq_entry_read_data[BIQ_WIDTH-1:0] =
               biq_entry0_read_data[BIQ_WIDTH-1:0];
    4'h02  : biq_entry_read_data[BIQ_WIDTH-1:0] =
               biq_entry1_read_data[BIQ_WIDTH-1:0];
    4'h04  : biq_entry_read_data[BIQ_WIDTH-1:0] =
               biq_entry2_read_data[BIQ_WIDTH-1:0];
    4'h08  : biq_entry_read_data[BIQ_WIDTH-1:0] =
               biq_entry3_read_data[BIQ_WIDTH-1:0];
    default: biq_entry_read_data[BIQ_WIDTH-1:0] =
                                    {BIQ_WIDTH{1'bx}};
  endcase
// &CombEnd; @548
end
assign biq_dp_issue_read_data[BIQ_WIDTH-1:0] = biq_entry_read_data[BIQ_WIDTH-1:0];

//==========================================================
//             ALU Issue Queue 0 Entry Instance
//==========================================================
ct_idu_is_biq_entry x_ct_idu_is_biq_entry0 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_biq_rf_pop_vld              (biq_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (biq_entry0_create_agevec         ),
    .x_create_data                    (biq_entry0_create_data           ),
    .x_create_en                      (biq_entry0_create_en             ),
    .x_pop_cur_entry                  (biq_entry0_pop_cur_entry         ),
    .x_pop_other_entry                (biq_entry0_pop_other_entry       ),

    .x_rdy                            (biq_entry_ready[0]               ),
    .x_agevec                         (biq_entry0_agevec                ),
    .x_read_data                      (biq_entry0_read_data             ),
    .x_vld                            (biq_entry0_vld                   )
);

ct_idu_is_biq_entry x_ct_idu_is_biq_entry1 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_biq_rf_pop_vld              (biq_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (biq_entry1_create_agevec         ),
    .x_create_data                    (biq_entry1_create_data           ),
    .x_create_en                      (biq_entry1_create_en             ),
    .x_pop_cur_entry                  (biq_entry1_pop_cur_entry         ),
    .x_pop_other_entry                (biq_entry1_pop_other_entry       ),

    .x_rdy                            (biq_entry_ready[1]               ),
    .x_agevec                         (biq_entry1_agevec                ),
    .x_read_data                      (biq_entry1_read_data             ),
    .x_vld                            (biq_entry1_vld                   )
);

ct_idu_is_biq_entry x_ct_idu_is_biq_entry2 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_biq_rf_pop_vld              (biq_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (biq_entry2_create_agevec         ),
    .x_create_data                    (biq_entry2_create_data           ),
    .x_create_en                      (biq_entry2_create_en             ),
    .x_pop_cur_entry                  (biq_entry2_pop_cur_entry         ),
    .x_pop_other_entry                (biq_entry2_pop_other_entry       ),

    .x_rdy                            (biq_entry_ready[2]               ),
    .x_agevec                         (biq_entry2_agevec                ),
    .x_read_data                      (biq_entry2_read_data             ),
    .x_vld                            (biq_entry2_vld                   )
);

ct_idu_is_biq_entry x_ct_idu_is_biq_entry3 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_biq_rf_pop_vld              (biq_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (biq_entry3_create_agevec         ),
    .x_create_data                    (biq_entry3_create_data           ),
    .x_create_en                      (biq_entry3_create_en             ),
    .x_pop_cur_entry                  (biq_entry3_pop_cur_entry         ),
    .x_pop_other_entry                (biq_entry3_pop_other_entry       ),

    .x_rdy                            (biq_entry_ready[3]               ),
    .x_agevec                         (biq_entry3_agevec                ),
    .x_read_data                      (biq_entry3_read_data             ),
    .x_vld                            (biq_entry3_vld                   )
);
// &ModuleEnd; @630
endmodule