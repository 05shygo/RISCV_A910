module ct_idu_is_aiq (
  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic         aiq_ctrl_1_left_updt,
  output logic         aiq_ctrl_full_updt,
  output logic         aiq_xx_issue_en,
  output logic [63:0]  aiq_dp_issue_read_data,

  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         cpurst_b,
  input  logic         ctrl_aiq_create0_en,
  input  logic         ctrl_aiq_create1_en,
  input  logic [63:0]  dp_aiq_create0_data,
  input  logic [63:0]  dp_aiq_create1_data,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush
);
parameter AIQ_WIDTH             = 64;
parameter AIQ_ILLEGAL           = 63;
parameter AIQ_IID               = 62;
parameter AIQ_SRC2_DATA         = 55;
parameter AIQ_SRC1_DATA         = 48;
parameter AIQ_SRC0_DATA         = 41;
parameter AIQ_DST_VLD           = 34;
parameter AIQ_SRC1_VLD          = 33;
parameter AIQ_SRC0_VLD          = 32;
parameter AIQ_OPCODE            = 31;

    //----------------------------------------------------------------------------
    // Internal signals
    //----------------------------------------------------------------------------
    logic [2:0]  aiq_entry_cnt;
    logic [2:0]  aiq_entry_cnt_create;
    logic        aiq_entry_cnt_updt_vld;
    logic [2:0]  aiq_entry_cnt_updt_val;
    logic        aiq_entry_cnt_create_2;
    logic        aiq_entry_cnt_create_1;
    logic        aiq_entry_cnt_create_0;
    logic        aiq_entry_cnt_pop_1;
    logic        aiq_entry_cnt_pop_0;

    logic [3:0]  aiq_entry_vld;
    logic        aiq_entry0_vld;
    logic        aiq_entry1_vld;
    logic        aiq_entry2_vld;
    logic        aiq_entry3_vld;

    logic [3:0]  aiq_entry_create0_in;
    logic [7:0]  aiq_entry_create1_in;
    logic [3:0]  aiq_entry_create_en;
    logic        aiq_entry0_create_en;
    logic        aiq_entry1_create_en;
    logic        aiq_entry2_create_en;
    logic        aiq_entry3_create_en;

    logic [3:0]  aiq_entry_create0_agevec;
    logic [3:0]  aiq_entry_create1_agevec;
    logic [7:0]  aiq_entry_create_sel;

    logic [2:0]  aiq_entry0_create_agevec;
    logic [2:0]  aiq_entry1_create_agevec;
    logic [2:0]  aiq_entry2_create_agevec;
    logic [2:0]  aiq_entry3_create_agevec;

    logic [AIQ_WIDTH-1:0] aiq_entry0_create_data;
    logic [AIQ_WIDTH-1:0] aiq_entry1_create_data;
    logic [AIQ_WIDTH-1:0] aiq_entry2_create_data;
    logic [AIQ_WIDTH-1:0] aiq_entry3_create_data;

    logic [2:0]  aiq_entry0_pop_other_entry;
    logic [2:0]  aiq_entry1_pop_other_entry;
    logic [2:0]  aiq_entry2_pop_other_entry;
    logic [2:0]  aiq_entry3_pop_other_entry;
    logic        aiq_entry0_pop_cur_entry;
    logic        aiq_entry1_pop_cur_entry;
    logic        aiq_entry2_pop_cur_entry;
    logic        aiq_entry3_pop_cur_entry;

    logic [3:0]  aiq_older_entry_ready;
    logic [3:0]  aiq_entry_issue_en;
    logic [AIQ_WIDTH-1:0] aiq_entry_read_data;

    logic [3:0]  aiq_entry_ready;
    logic [2:0]  aiq_entry0_agevec;
    logic [2:0]  aiq_entry1_agevec;
    logic [2:0]  aiq_entry2_agevec;
    logic [2:0]  aiq_entry3_agevec;
    logic [AIQ_WIDTH-1:0] aiq_entry0_read_data;
    logic [AIQ_WIDTH-1:0] aiq_entry1_read_data;
    logic [AIQ_WIDTH-1:0] aiq_entry2_read_data;
    logic [AIQ_WIDTH-1:0] aiq_entry3_read_data;

//--------------------aiq entry counter--------------------
//if create, add entry counter
assign aiq_entry_cnt_create[2:0]   = {2'b0,ctrl_aiq_create0_en}
                                      + {2'b0,ctrl_aiq_create1_en};
//update valid and value
assign aiq_entry_cnt_updt_vld      = ctrl_aiq_create0_en
                                      || aiq_xx_issue_en;
assign aiq_entry_cnt_updt_val[2:0] = aiq_entry_cnt[2:0]
                                      + aiq_entry_cnt_create[2:0]
                                      - {2'b0,aiq_xx_issue_en};
//implement entry counter
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    aiq_entry_cnt[2:0] <= 3'b0;
  //after flush fe/is, the rf may wrongly pop before rtu_yy_xx_flush
  //need flush also when rtu_yy_xx_flush
  else if(rtu_yy_xx_flush)
    aiq_entry_cnt[2:0] <= 3'b0;
  else if(aiq_entry_cnt_updt_vld)
    aiq_entry_cnt[2:0] <= aiq_entry_cnt_updt_val[2:0];
  else
    aiq_entry_cnt[2:0] <= aiq_entry_cnt[2:0];
end

//--------------------aiq entry full-----------------------
assign aiq_entry_cnt_create_2 =  ctrl_aiq_create1_en;
assign aiq_entry_cnt_create_1 =  ctrl_aiq_create0_en && !ctrl_aiq_create1_en;
assign aiq_entry_cnt_create_0 = !ctrl_aiq_create0_en;

assign aiq_entry_cnt_pop_1    =  aiq_xx_issue_en;
assign aiq_entry_cnt_pop_0    = !aiq_xx_issue_en;

assign aiq_ctrl_full_updt     = (aiq_entry_cnt[2:0] == 3'd2)
                                 && aiq_entry_cnt_create_2
                                 && aiq_entry_cnt_pop_0
                              || (aiq_entry_cnt[2:0] == 3'd3)
                                 && aiq_entry_cnt_create_1
                                 && aiq_entry_cnt_pop_0
                              || (aiq_entry_cnt[2:0] == 3'd4)
                                 && aiq_entry_cnt_create_0
                                 && aiq_entry_cnt_pop_0;

assign aiq_ctrl_1_left_updt   = (aiq_entry_cnt[2:0] == 3'd1)
                                 && aiq_entry_cnt_create_2
                                 && aiq_entry_cnt_pop_0
                              || (aiq_entry_cnt[2:0] == 3'd2)
                                 && aiq_entry_cnt_create_1
                                 && aiq_entry_cnt_pop_0
                              || (aiq_entry_cnt[2:0] == 3'd2)
                                 && aiq_entry_cnt_create_2
                                 && aiq_entry_cnt_pop_1
                              || (aiq_entry_cnt[2:0] == 3'd3)
                                 && aiq_entry_cnt_create_0
                                 && aiq_entry_cnt_pop_0
                              || (aiq_entry_cnt[2:0] == 3'd3)
                                 && aiq_entry_cnt_create_1
                                 && aiq_entry_cnt_pop_1
                              || (aiq_entry_cnt[2:0] == 3'd4)
                                 && aiq_entry_cnt_create_0
                                 && aiq_entry_cnt_pop_1;

//issue queue entry create control
assign aiq_entry_vld[0]         = aiq_entry0_vld;
assign aiq_entry_vld[1]         = aiq_entry1_vld;
assign aiq_entry_vld[2]         = aiq_entry2_vld;
assign aiq_entry_vld[3]         = aiq_entry3_vld;


//create0 priority is from entry 0 to 7
// &CombBeg; @178
always @(*)
begin
  casez ({aiq_entry0_vld, aiq_entry1_vld, aiq_entry2_vld, aiq_entry3_vld})
    4'b0???: aiq_entry_create0_in = 4'b0001; // entry0 空闲，选 0
    4'b10??: aiq_entry_create0_in = 4'b0010; // 0 忙，1 空闲，选 1
    4'b110?: aiq_entry_create0_in = 4'b0100; // 0/1 忙，2 空闲，选 2
    4'b1110: aiq_entry_create0_in = 4'b1000; // 0/1/2 忙，3 空闲，选 3
    default: aiq_entry_create0_in = 4'b0000; // 全忙
  endcase
// &CombEnd; @197
end
always @(*)
begin
  casez ({aiq_entry3_vld, aiq_entry2_vld, aiq_entry1_vld, aiq_entry0_vld})
    4'b0???: aiq_entry_create1_in = 4'b1000; // entry3 空闲，选 3
    4'b10??: aiq_entry_create1_in = 4'b0100; // 3 忙，2 空闲，选 2
    4'b110?: aiq_entry_create1_in = 4'b0010; // 3/2 忙，1 空闲，选 1
    4'b1110: aiq_entry_create1_in = 4'b0001; // 3/2/1 忙，0 空闲，选 0
    default: aiq_entry_create1_in = 4'b0000; // 全忙
  endcase
// &CombEnd; @219
end

assign aiq_entry_create_en[3:0] =
       {4{ctrl_aiq_create0_en}} & aiq_entry_create0_in[3:0]
     | {4{ctrl_aiq_create1_en}} & aiq_entry_create1_in[3:0];

assign aiq_entry0_create_en     = aiq_entry_create_en[0];
assign aiq_entry1_create_en     = aiq_entry_create_en[1];
assign aiq_entry2_create_en     = aiq_entry_create_en[2];
assign aiq_entry3_create_en     = aiq_entry_create_en[3];

//aiq create entry should consider pop signal and create0
assign aiq_entry_create0_agevec[3:0] = aiq_entry_vld[3:0]
                                        & ~({4{aiq_xx_issue_en}}
                                           & aiq_entry_issue_en[3:0]);

assign aiq_entry_create1_agevec[3:0] = aiq_entry_vld[3:0]
                                        & ~({4{aiq_xx_issue_en}}
                                           & aiq_entry_issue_en[3:0])
                                        | aiq_entry_create0_in[3:0];

//create 0/1 select:
//entry 0~3 use ~aiq_entry_create0_in for better timing
//entry 4~7 use aiq_entry_create1_in for better timing
//aiq_entry_create0/1_in cannot be both 1,
//if both 0, do not create
assign aiq_entry_create_sel[7:4] = {4{ctrl_aiq_create1_en}}
                                     & aiq_entry_create1_in[7:4];
assign aiq_entry_create_sel[3:0] = ~({4{ctrl_aiq_create0_en}}
                                      & aiq_entry_create0_in[3:0]);

//----------------entry0 flop create signals----------------
// &CombBeg; @297
always @(*)
begin
  if(aiq_entry_create0_in[0]) begin
    aiq_entry0_create_agevec[2:0] = aiq_entry_create0_agevec[3:1];
    aiq_entry0_create_data[AIQ_WIDTH-1:0] = 
       dp_aiq_create0_data[AIQ_WIDTH-1:0];
  end
  else begin
    aiq_entry0_create_agevec[2:0] = aiq_entry_create1_agevec[3:1];
    aiq_entry0_create_data[AIQ_WIDTH-1:0] = 
       dp_aiq_create1_data[AIQ_WIDTH-1:0];
  end
// &CombEnd; @310
end

//----------------entry1 flop create signals----------------
// &CombBeg; @313
always @(*)
begin
  if(aiq_entry_create0_in[1]) begin
    aiq_entry1_create_agevec[2:0] = {aiq_entry_create0_agevec[3:2],
                                      aiq_entry_create0_agevec[0]};
    aiq_entry1_create_data[AIQ_WIDTH-1:0] =
       dp_aiq_create0_data[AIQ_WIDTH-1:0];
  end
  else begin
    aiq_entry1_create_agevec[2:0] = {aiq_entry_create1_agevec[3:2],
                                      aiq_entry_create1_agevec[0]};
    aiq_entry1_create_data[AIQ_WIDTH-1:0] =
       dp_aiq_create1_data[AIQ_WIDTH-1:0];
  end
// &CombEnd; @328
end

//----------------entry2 flop create signals----------------
// &CombBeg; @331
always @(*)
begin
  if(aiq_entry_create0_in[2]) begin
    aiq_entry2_create_agevec[2:0] = {aiq_entry_create0_agevec[3],
                                      aiq_entry_create0_agevec[1:0]};
    aiq_entry2_create_data[AIQ_WIDTH-1:0] =
       dp_aiq_create0_data[AIQ_WIDTH-1:0];
  end
  else begin
    aiq_entry2_create_agevec[2:0] = {aiq_entry_create1_agevec[3],
                                      aiq_entry_create1_agevec[1:0]};
    aiq_entry2_create_data[AIQ_WIDTH-1:0] =
       dp_aiq_create1_data[AIQ_WIDTH-1:0];
  end
// &CombEnd; @346
end

//----------------entry3 flop create signals----------------
// &CombBeg; @349
always @(*)
begin
  if(aiq_entry_create0_in[3]) begin
    aiq_entry3_create_agevec[2:0] = aiq_entry_create0_agevec[2:0];
    aiq_entry3_create_data[AIQ_WIDTH-1:0] =
       dp_aiq_create0_data[AIQ_WIDTH-1:0];
  end
  else begin
    aiq_entry3_create_agevec[2:0] = aiq_entry_create1_agevec[2:0];
    aiq_entry3_create_data[AIQ_WIDTH-1:0] =
       dp_aiq_create1_data[AIQ_WIDTH-1:0];
  end
// &CombEnd; @364
end

//-------------------entry pop enable signals---------------
//pop when rf launch pass
assign {aiq_entry0_pop_other_entry[2:0],
        aiq_entry0_pop_cur_entry}        = aiq_entry_issue_en[3:0];
assign {aiq_entry1_pop_other_entry[2:1],
        aiq_entry1_pop_cur_entry,
        aiq_entry1_pop_other_entry[0]}   = aiq_entry_issue_en[3:0];
assign {aiq_entry2_pop_other_entry[2],
        aiq_entry2_pop_cur_entry,
        aiq_entry2_pop_other_entry[1:0]} = aiq_entry_issue_en[3:0];
assign {aiq_entry3_pop_cur_entry,
        aiq_entry3_pop_other_entry[2:0]} = aiq_entry_issue_en[3:0];

//------------------entry issue enable signals--------------
//first find older ready entry
assign aiq_older_entry_ready[0] = |(aiq_entry0_agevec[2:0]
                                     & aiq_entry_ready[3:1]);
assign aiq_older_entry_ready[1] = |(aiq_entry1_agevec[2:0]
                                     & {aiq_entry_ready[3:2],
                                        aiq_entry_ready[0]});
assign aiq_older_entry_ready[2] = |(aiq_entry2_agevec[2:0]
                                     & {aiq_entry_ready[3],
                                        aiq_entry_ready[1:0]});
assign aiq_older_entry_ready[3] = |(aiq_entry3_agevec[2:0]
                                     & aiq_entry_ready[2:0]);
//not ready if older ready exists
assign aiq_entry_issue_en[3:0]  = aiq_entry_ready[3:0]
                                   & ~aiq_older_entry_ready[3:0];
//rename for entries
assign aiq_xx_issue_en = |aiq_entry_issue_en[3:0];
//-----------------issue data path selection----------------
//issue data path will select oldest ready entry in issue queue
//if no instruction valid, the data path will always select bypass 
//data path
// &CombBeg; @527
always @(*)
begin
  case (aiq_entry_issue_en[3:0])
    4'h01  : aiq_entry_read_data[AIQ_WIDTH-1:0] =
               aiq_entry0_read_data[AIQ_WIDTH-1:0];
    4'h02  : aiq_entry_read_data[AIQ_WIDTH-1:0] =
               aiq_entry1_read_data[AIQ_WIDTH-1:0];
    4'h04  : aiq_entry_read_data[AIQ_WIDTH-1:0] =
               aiq_entry2_read_data[AIQ_WIDTH-1:0];
    4'h08  : aiq_entry_read_data[AIQ_WIDTH-1:0] =
               aiq_entry3_read_data[AIQ_WIDTH-1:0];
    default: aiq_entry_read_data[AIQ_WIDTH-1:0] =
                                    {AIQ_WIDTH{1'bx}};
  endcase
// &CombEnd; @548
end
assign aiq_dp_issue_read_data[AIQ_WIDTH-1:0] = aiq_entry_read_data[AIQ_WIDTH-1:0];

//==========================================================
//             ALU Issue Queue 0 Entry Instance
//==========================================================
ct_idu_is_aiq_entry x_ct_idu_is_aiq_entry0 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_aiq0_rf_pop_vld              (aiq_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (aiq_entry0_create_agevec         ),
    .x_create_data                    (aiq_entry0_create_data           ),
    .x_create_en                      (aiq_entry0_create_en             ),
    .x_pop_cur_entry                  (aiq_entry0_pop_cur_entry         ),
    .x_pop_other_entry                (aiq_entry0_pop_other_entry       ),

    .x_rdy                            (aiq_entry_ready[0]               ),
    .x_agevec                         (aiq_entry0_agevec                ),
    .x_read_data                      (aiq_entry0_read_data             ),
    .x_vld                            (aiq_entry0_vld                   )
);

ct_idu_is_aiq_entry x_ct_idu_is_aiq_entry1 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_aiq0_rf_pop_vld              (aiq_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (aiq_entry1_create_agevec         ),
    .x_create_data                    (aiq_entry1_create_data           ),
    .x_create_en                      (aiq_entry1_create_en             ),
    .x_pop_cur_entry                  (aiq_entry1_pop_cur_entry         ),
    .x_pop_other_entry                (aiq_entry1_pop_other_entry       ),

    .x_rdy                            (aiq_entry_ready[1]               ),
    .x_agevec                         (aiq_entry1_agevec                ),
    .x_read_data                      (aiq_entry1_read_data             ),
    .x_vld                            (aiq_entry1_vld                   )
);

ct_idu_is_aiq_entry x_ct_idu_is_aiq_entry2 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_aiq0_rf_pop_vld              (aiq_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (aiq_entry2_create_agevec         ),
    .x_create_data                    (aiq_entry2_create_data           ),
    .x_create_en                      (aiq_entry2_create_en             ),
    .x_pop_cur_entry                  (aiq_entry2_pop_cur_entry         ),
    .x_pop_other_entry                (aiq_entry2_pop_other_entry       ),

    .x_rdy                            (aiq_entry_ready[2]               ),
    .x_agevec                         (aiq_entry2_agevec                ),
    .x_read_data                      (aiq_entry2_read_data             ),
    .x_vld                            (aiq_entry2_vld                   )
);

ct_idu_is_aiq_entry x_ct_idu_is_aiq_entry3 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_aiq0_rf_pop_vld              (aiq_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (aiq_entry3_create_agevec         ),
    .x_create_data                    (aiq_entry3_create_data           ),
    .x_create_en                      (aiq_entry3_create_en             ),
    .x_pop_cur_entry                  (aiq_entry3_pop_cur_entry         ),
    .x_pop_other_entry                (aiq_entry3_pop_other_entry       ),

    .x_rdy                            (aiq_entry_ready[3]               ),
    .x_agevec                         (aiq_entry3_agevec                ),
    .x_read_data                      (aiq_entry3_read_data             ),
    .x_vld                            (aiq_entry3_vld                   )
);
// &ModuleEnd; @630
endmodule