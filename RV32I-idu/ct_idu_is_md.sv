module ct_idu_is_md (
  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic         md_ctrl_1_left_updt,
  output logic         md_ctrl_full_updt,
  output logic         md_xx_issue_en,
  output logic [62:0]  md_dp_issue_read_data,

  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         cpurst_b,
  input  logic         ctrl_md_create0_en,
  input  logic         ctrl_md_create1_en,
  input  logic [62:0]  dp_md_create0_data,
  input  logic [62:0]  dp_md_create1_data,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush
);
    parameter int AIQ_WIDTH       = 63;
    parameter int AIQ_IID         = 62;
    parameter int AIQ_SRC2_DATA   = 55;
    parameter int AIQ_SRC1_DATA   = 48;
    parameter int AIQ_SRC0_DATA   = 41;
    parameter int AIQ_DST_VLD     = 34;
    parameter int AIQ_SRC1_VLD    = 33;
    parameter int AIQ_SRC0_VLD    = 32;
    parameter int AIQ_OPCODE      = 31;

    //----------------------------------------------------------------------------
    // Internal signals
    //----------------------------------------------------------------------------
    logic [2:0]  md_entry_cnt;
    logic [2:0]  md_entry_cnt_create;
    logic        md_entry_cnt_updt_vld;
    logic [2:0]  md_entry_cnt_updt_val;
    logic        md_entry_cnt_create_2;
    logic        md_entry_cnt_create_1;
    logic        md_entry_cnt_create_0;
    logic        md_entry_cnt_pop_1;
    logic        md_entry_cnt_pop_0;

    logic [3:0]  md_entry_vld;
    logic        md_entry0_vld;
    logic        md_entry1_vld;
    logic        md_entry2_vld;
    logic        md_entry3_vld;

    logic [3:0]  md_entry_create0_in;
    logic [7:0]  md_entry_create1_in;
    logic [3:0]  md_entry_create_en;
    logic        md_entry0_create_en;
    logic        md_entry1_create_en;
    logic        md_entry2_create_en;
    logic        md_entry3_create_en;

    logic [3:0]  md_entry_create0_agevec;
    logic [3:0]  md_entry_create1_agevec;
    logic [7:0]  md_entry_create_sel;

    logic [2:0]  md_entry0_create_agevec;
    logic [2:0]  md_entry1_create_agevec;
    logic [2:0]  md_entry2_create_agevec;
    logic [2:0]  md_entry3_create_agevec;

    logic [AIQ_WIDTH-1:0] md_entry0_create_data;
    logic [AIQ_WIDTH-1:0] md_entry1_create_data;
    logic [AIQ_WIDTH-1:0] md_entry2_create_data;
    logic [AIQ_WIDTH-1:0] md_entry3_create_data;

    logic [2:0]  md_entry0_pop_other_entry;
    logic [2:0]  md_entry1_pop_other_entry;
    logic [2:0]  md_entry2_pop_other_entry;
    logic [2:0]  md_entry3_pop_other_entry;
    logic        md_entry0_pop_cur_entry;
    logic        md_entry1_pop_cur_entry;
    logic        md_entry2_pop_cur_entry;
    logic        md_entry3_pop_cur_entry;

    logic [3:0]  md_older_entry_ready;
    logic [3:0]  md_entry_issue_en;
    logic [AIQ_WIDTH-1:0] md_entry_read_data;

    logic [3:0]  md_entry_ready;
    logic [2:0]  md_entry0_agevec;
    logic [2:0]  md_entry1_agevec;
    logic [2:0]  md_entry2_agevec;
    logic [2:0]  md_entry3_agevec;
    logic [AIQ_WIDTH-1:0] md_entry0_read_data;
    logic [AIQ_WIDTH-1:0] md_entry1_read_data;
    logic [AIQ_WIDTH-1:0] md_entry2_read_data;
    logic [AIQ_WIDTH-1:0] md_entry3_read_data;

//--------------------md entry counter--------------------
//if create, add entry counter
assign md_entry_cnt_create[2:0]   = {2'b0,ctrl_md_create0_en}
                                      + {2'b0,ctrl_md_create1_en};
//update valid and value
assign md_entry_cnt_updt_vld      = ctrl_md_create0_en
                                      || md_xx_issue_en;
assign md_entry_cnt_updt_val[2:0] = md_entry_cnt[2:0]
                                      + md_entry_cnt_create[2:0]
                                      - {2'b0,md_xx_issue_en};
//implement entry counter
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    md_entry_cnt[2:0] <= 3'b0;
  //after flush fe/is, the rf may wrongly pop before rtu_yy_xx_flush
  //need flush also when rtu_yy_xx_flush
  else if(rtu_yy_xx_flush)
    md_entry_cnt[2:0] <= 3'b0;
  else if(md_entry_cnt_updt_vld)
    md_entry_cnt[2:0] <= md_entry_cnt_updt_val[2:0];
  else
    md_entry_cnt[2:0] <= md_entry_cnt[2:0];
end

//--------------------md entry full-----------------------
assign md_entry_cnt_create_2 =  ctrl_md_create1_en;
assign md_entry_cnt_create_1 =  ctrl_md_create0_en && !ctrl_md_create1_en;
assign md_entry_cnt_create_0 = !ctrl_md_create0_en;

assign md_entry_cnt_pop_1    =  md_xx_issue_en;
assign md_entry_cnt_pop_0    = !md_xx_issue_en;

assign md_ctrl_full_updt     = (md_entry_cnt[2:0] == 3'd2)
                                 && md_entry_cnt_create_2
                                 && md_entry_cnt_pop_0
                              || (md_entry_cnt[2:0] == 3'd3)
                                 && md_entry_cnt_create_1
                                 && md_entry_cnt_pop_0
                              || (md_entry_cnt[2:0] == 3'd4)
                                 && md_entry_cnt_create_0
                                 && md_entry_cnt_pop_0;

assign md_ctrl_1_left_updt   = (md_entry_cnt[2:0] == 3'd1)
                                 && md_entry_cnt_create_2
                                 && md_entry_cnt_pop_0
                              || (md_entry_cnt[2:0] == 3'd2)
                                 && md_entry_cnt_create_1
                                 && md_entry_cnt_pop_0
                              || (md_entry_cnt[2:0] == 3'd2)
                                 && md_entry_cnt_create_2
                                 && md_entry_cnt_pop_1
                              || (md_entry_cnt[2:0] == 3'd3)
                                 && md_entry_cnt_create_0
                                 && md_entry_cnt_pop_0
                              || (md_entry_cnt[2:0] == 3'd3)
                                 && md_entry_cnt_create_1
                                 && md_entry_cnt_pop_1
                              || (md_entry_cnt[2:0] == 3'd4)
                                 && md_entry_cnt_create_0
                                 && md_entry_cnt_pop_1;

//issue queue entry create control
assign md_entry_vld[0]         = md_entry0_vld;
assign md_entry_vld[1]         = md_entry1_vld;
assign md_entry_vld[2]         = md_entry2_vld;
assign md_entry_vld[3]         = md_entry3_vld;


//create0 priority is from entry 0 to 7
// &CombBeg; @178
always @(*)
begin
  casez ({md_entry0_vld, md_entry1_vld, md_entry2_vld, md_entry3_vld})
    4'b0???: md_entry_create0_in = 4'b0001; // entry0 空闲，选 0
    4'b10??: md_entry_create0_in = 4'b0010; // 0 忙，1 空闲，选 1
    4'b110?: md_entry_create0_in = 4'b0100; // 0/1 忙，2 空闲，选 2
    4'b1110: md_entry_create0_in = 4'b1000; // 0/1/2 忙，3 空闲，选 3
    default: md_entry_create0_in = 4'b0000; // 全忙
  endcase
// &CombEnd; @197
end
always @(*)
begin
  casez ({md_entry3_vld, md_entry2_vld, md_entry1_vld, md_entry0_vld})
    4'b0???: md_entry_create1_in = 4'b1000; // entry3 空闲，选 3
    4'b10??: md_entry_create1_in = 4'b0100; // 3 忙，2 空闲，选 2
    4'b110?: md_entry_create1_in = 4'b0010; // 3/2 忙，1 空闲，选 1
    4'b1110: md_entry_create1_in = 4'b0001; // 3/2/1 忙，0 空闲，选 0
    default: md_entry_create1_in = 4'b0000; // 全忙
  endcase
// &CombEnd; @219
end

assign md_entry_create_en[3:0] =
       {4{ctrl_md_create0_en}} & md_entry_create0_in[3:0]
     | {4{ctrl_md_create1_en}} & md_entry_create1_in[3:0];

assign md_entry0_create_en     = md_entry_create_en[0];
assign md_entry1_create_en     = md_entry_create_en[1];
assign md_entry2_create_en     = md_entry_create_en[2];
assign md_entry3_create_en     = md_entry_create_en[3];

//md create entry should consider pop signal and create0
assign md_entry_create0_agevec[3:0] = md_entry_vld[3:0]
                                        & ~({4{md_xx_issue_en}}
                                           & md_entry_issue_en[3:0]);

assign md_entry_create1_agevec[3:0] = md_entry_vld[3:0]
                                        & ~({4{md_xx_issue_en}}
                                           & md_entry_issue_en[3:0])
                                        | md_entry_create0_in[3:0];

//create 0/1 select:
//entry 0~3 use ~md_entry_create0_in for better timing
//entry 4~7 use md_entry_create1_in for better timing
//md_entry_create0/1_in cannot be both 1,
//if both 0, do not create
assign md_entry_create_sel[7:4] = {4{ctrl_md_create1_en}}
                                     & md_entry_create1_in[7:4];
assign md_entry_create_sel[3:0] = ~({4{ctrl_md_create0_en}}
                                      & md_entry_create0_in[3:0]);

//----------------entry0 flop create signals----------------
// &CombBeg; @297
always @(*)
begin
  if(md_entry_create0_in[0]) begin
    md_entry0_create_agevec[2:0] = md_entry_create0_agevec[3:1];
    md_entry0_create_data[AIQ_WIDTH-1:0] = 
       dp_md_create0_data[AIQ_WIDTH-1:0];
  end
  else begin
    md_entry0_create_agevec[2:0] = md_entry_create1_agevec[3:1];
    md_entry0_create_data[AIQ_WIDTH-1:0] = 
       dp_md_create1_data[AIQ_WIDTH-1:0];
  end
// &CombEnd; @310
end

//----------------entry1 flop create signals----------------
// &CombBeg; @313
always @(*)
begin
  if(md_entry_create0_in[1]) begin
    md_entry1_create_agevec[2:0] = {md_entry_create0_agevec[3:2],
                                      md_entry_create0_agevec[0]};
    md_entry1_create_data[AIQ_WIDTH-1:0] =
       dp_md_create0_data[AIQ_WIDTH-1:0];
  end
  else begin
    md_entry1_create_agevec[2:0] = {md_entry_create1_agevec[3:2],
                                      md_entry_create1_agevec[0]};
    md_entry1_create_data[AIQ_WIDTH-1:0] =
       dp_md_create1_data[AIQ_WIDTH-1:0];
  end
// &CombEnd; @328
end

//----------------entry2 flop create signals----------------
// &CombBeg; @331
always @(*)
begin
  if(md_entry_create0_in[2]) begin
    md_entry2_create_agevec[2:0] = {md_entry_create0_agevec[3],
                                      md_entry_create0_agevec[1:0]};
    md_entry2_create_data[AIQ_WIDTH-1:0] =
       dp_md_create0_data[AIQ_WIDTH-1:0];
  end
  else begin
    md_entry2_create_agevec[2:0] = {md_entry_create1_agevec[3],
                                      md_entry_create1_agevec[1:0]};
    md_entry2_create_data[AIQ_WIDTH-1:0] =
       dp_md_create1_data[AIQ_WIDTH-1:0];
  end
// &CombEnd; @346
end

//----------------entry3 flop create signals----------------
// &CombBeg; @349
always @(*)
begin
  if(md_entry_create0_in[3]) begin
    md_entry3_create_agevec[2:0] = md_entry_create0_agevec[2:0];
    md_entry3_create_data[AIQ_WIDTH-1:0] =
       dp_md_create0_data[AIQ_WIDTH-1:0];
  end
  else begin
    md_entry3_create_agevec[2:0] = md_entry_create1_agevec[2:0];
    md_entry3_create_data[AIQ_WIDTH-1:0] =
       dp_md_create1_data[AIQ_WIDTH-1:0];
  end
// &CombEnd; @364
end

//-------------------entry pop enable signals---------------
//pop when rf launch pass
assign {md_entry0_pop_other_entry[2:0],
        md_entry0_pop_cur_entry}        = md_entry_issue_en[3:0];
assign {md_entry1_pop_other_entry[2:1],
        md_entry1_pop_cur_entry,
        md_entry1_pop_other_entry[0]}   = md_entry_issue_en[3:0];
assign {md_entry2_pop_other_entry[2],
        md_entry2_pop_cur_entry,
        md_entry2_pop_other_entry[1:0]} = md_entry_issue_en[3:0];
assign {md_entry3_pop_cur_entry,
        md_entry3_pop_other_entry[2:0]} = md_entry_issue_en[3:0];

//------------------entry issue enable signals--------------
//first find older ready entry
assign md_older_entry_ready[0] = |(md_entry0_agevec[2:0]
                                     & md_entry_ready[3:1]);
assign md_older_entry_ready[1] = |(md_entry1_agevec[2:0]
                                     & {md_entry_ready[3:2],
                                        md_entry_ready[0]});
assign md_older_entry_ready[2] = |(md_entry2_agevec[2:0]
                                     & {md_entry_ready[3],
                                        md_entry_ready[1:0]});
assign md_older_entry_ready[3] = |(md_entry3_agevec[2:0]
                                     & md_entry_ready[2:0]);
//not ready if older ready exists
assign md_entry_issue_en[3:0]  = md_entry_ready[3:0]
                                   & ~md_older_entry_ready[3:0];
//rename for entries
assign md_xx_issue_en = |md_entry_issue_en[3:0];
//-----------------issue data path selection----------------
//issue data path will select oldest ready entry in issue queue
//if no instruction valid, the data path will always select bypass 
//data path
// &CombBeg; @527
always @(*)
begin
  case (md_entry_issue_en[3:0])
    4'h01  : md_entry_read_data[AIQ_WIDTH-1:0] =
               md_entry0_read_data[AIQ_WIDTH-1:0];
    4'h02  : md_entry_read_data[AIQ_WIDTH-1:0] =
               md_entry1_read_data[AIQ_WIDTH-1:0];
    4'h04  : md_entry_read_data[AIQ_WIDTH-1:0] =
               md_entry2_read_data[AIQ_WIDTH-1:0];
    4'h08  : md_entry_read_data[AIQ_WIDTH-1:0] =
               md_entry3_read_data[AIQ_WIDTH-1:0];
    default: md_entry_read_data[AIQ_WIDTH-1:0] =
                                    {AIQ_WIDTH{1'bx}};
  endcase
// &CombEnd; @548
end
assign md_dp_issue_read_data[AIQ_WIDTH-1:0] = md_entry_read_data[AIQ_WIDTH-1:0];

//==========================================================
//             ALU Issue Queue 0 Entry Instance
//==========================================================
ct_idu_is_md_entry x_ct_idu_is_md_entry0 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_md_rf_pop_vld              (md_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (md_entry0_create_agevec         ),
    .x_create_data                    (md_entry0_create_data           ),
    .x_create_en                      (md_entry0_create_en             ),
    .x_pop_cur_entry                  (md_entry0_pop_cur_entry         ),
    .x_pop_other_entry                (md_entry0_pop_other_entry       ),

    .x_rdy                            (md_entry_ready[0]               ),
    .x_agevec                         (md_entry0_agevec                ),
    .x_read_data                      (md_entry0_read_data             ),
    .x_vld                            (md_entry0_vld                   )
);

ct_idu_is_md_entry x_ct_idu_is_md_entry1 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_md_rf_pop_vld              (md_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (md_entry1_create_agevec         ),
    .x_create_data                    (md_entry1_create_data           ),
    .x_create_en                      (md_entry1_create_en             ),
    .x_pop_cur_entry                  (md_entry1_pop_cur_entry         ),
    .x_pop_other_entry                (md_entry1_pop_other_entry       ),

    .x_rdy                            (md_entry_ready[1]               ),
    .x_agevec                         (md_entry1_agevec                ),
    .x_read_data                      (md_entry1_read_data             ),
    .x_vld                            (md_entry1_vld                   )
);

ct_idu_is_md_entry x_ct_idu_is_md_entry2 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_md_rf_pop_vld              (md_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (md_entry2_create_agevec         ),
    .x_create_data                    (md_entry2_create_data           ),
    .x_create_en                      (md_entry2_create_en             ),
    .x_pop_cur_entry                  (md_entry2_pop_cur_entry         ),
    .x_pop_other_entry                (md_entry2_pop_other_entry       ),

    .x_rdy                            (md_entry_ready[2]               ),
    .x_agevec                         (md_entry2_agevec                ),
    .x_read_data                      (md_entry2_read_data             ),
    .x_vld                            (md_entry2_vld                   )
);

ct_idu_is_md_entry x_ct_idu_is_md_entry3 (
    .cpurst_b                         (cpurst_b                         ),
    .ctrl_md_rf_pop_vld              (md_xx_issue_en             ),
    .forever_cpuclk                   (forever_cpuclk                   ),

    .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
    .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

    .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
    .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

    .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
    .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

    .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

    .x_create_agevec                  (md_entry3_create_agevec         ),
    .x_create_data                    (md_entry3_create_data           ),
    .x_create_en                      (md_entry3_create_en             ),
    .x_pop_cur_entry                  (md_entry3_pop_cur_entry         ),
    .x_pop_other_entry                (md_entry3_pop_other_entry       ),

    .x_rdy                            (md_entry_ready[3]               ),
    .x_agevec                         (md_entry3_agevec                ),
    .x_read_data                      (md_entry3_read_data             ),
    .x_vld                            (md_entry3_vld                   )
);
// &ModuleEnd; @630
endmodule