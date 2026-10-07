module ct_idu_is_lsiq (
  input  logic         cpurst_b,
  input  logic         ctrl_lsiq_create0_en,
  input  logic         ctrl_lsiq_create1_en,
  input  logic [59:0]  dp_lsiq_create0_data,
  input  logic [59:0]  dp_lsiq_create1_data,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [7:0]   lsu_idu_lq_full,
  input  logic         lsu_idu_lq_not_full,
  input  logic         lsu_idu_lsiq_pop0_vld,
  input  logic         lsu_idu_lsiq_pop1_vld,
  input  logic [7:0]   lsu_idu_lsiq_pop_entry,
  input  logic         lsu_idu_lsiq_pop_vld,
  input  logic [7:0]   lsu_idu_rb_full,
  input  logic         lsu_idu_rb_not_full,
  input  logic [7:0]   lsu_idu_secd,
  input  logic [7:0]   lsu_idu_sq_full,
  input  logic         lsu_idu_sq_not_full,
  input  logic [7:0]   lsu_idu_imme_wakeup,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush,
  output logic         lsiq_ctrl_1_left_updt,
  output logic         lsiq_ctrl_full_updt,
  output logic         lsiq_rf_pipe3_issue_en,
  output logic         lsiq_rf_pipe4_issue_en,
  output logic [59:0]  lsiq_dp_pipe3_entry_read_data,
  output logic         lsiq_pipe3_entry_unalign_2nd,
  output logic         lsiq_pipe3_entry_old,
  output logic [7:0]   lsiq_dp_pipe3_issue_entry,
  output logic [59:0]  lsiq_dp_pipe4_entry_read_data,
  output logic         lsiq_pipe4_entry_unalign_2nd,
  output logic         lsiq_pipe4_entry_old,
  output logic [7:0]   lsiq_dp_pipe4_issue_entry
);

parameter LSIQ_WIDTH             = 60;
parameter LSIQ_IID               = 59;
parameter LSIQ_SDIQ_ENTRY        = 52;
parameter LSIQ_STORE             = 48;
parameter LSIQ_LOAD              = 47;
parameter LSIQ_SRC0_DATA         = 46;
parameter LSIQ_DST_PREG          = 39;
parameter LSIQ_DST_VLD           = 33;
parameter LSIQ_SRC0_VLD          = 32;
parameter LSIQ_OPCODE            = 31;

  //------------------- 内部信号声明 -------------------
  // 计数器
  logic [3:0]  lsiq_entry_cnt;
  logic [3:0]  lsiq_entry_cnt_create;
  logic [3:0]  lsiq_entry_cnt_pop;
  logic [3:0]  lsiq_entry_cnt_updt_val;
  logic        lsiq_entry_cnt_updt_vld;
  logic        lsiq_entry_cnt_create_2;
  logic        lsiq_entry_cnt_create_1;
  logic        lsiq_entry_cnt_create_0;
  logic        lsiq_entry_cnt_pop_1;
  logic        lsiq_entry_cnt_pop_0;

  // entry 有效位
  logic [7:0]  lsiq_entry_vld;

  // create 选择
  logic [7:0]  lsiq_entry_create0_in;
  logic [7:0]  lsiq_entry_create1_in;
  logic [7:0]  lsiq_entry_create_en;
  logic        lsiq_entry0_create_en;
  logic        lsiq_entry1_create_en;
  logic        lsiq_entry2_create_en;
  logic        lsiq_entry3_create_en;
  logic        lsiq_entry4_create_en;
  logic        lsiq_entry5_create_en;
  logic        lsiq_entry6_create_en;
  logic        lsiq_entry7_create_en;

  // agevec
  logic [7:0]  lsiq_entry_create0_agevec;
  logic [7:0]  lsiq_entry_create1_agevec;
  logic [6:0]  lsiq_entry0_create_agevec;
  logic [6:0]  lsiq_entry1_create_agevec;
  logic [6:0]  lsiq_entry2_create_agevec;
  logic [6:0]  lsiq_entry3_create_agevec;
  logic [6:0]  lsiq_entry4_create_agevec;
  logic [6:0]  lsiq_entry5_create_agevec;
  logic [6:0]  lsiq_entry6_create_agevec;
  logic [6:0]  lsiq_entry7_create_agevec;

  // create data
  logic [LSIQ_WIDTH-1:0] lsiq_entry0_create_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry1_create_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry2_create_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry3_create_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry4_create_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry5_create_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry6_create_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry7_create_data;

  // issue
  logic [7:0]  lsiq_entry_issue_en;
  logic [7:0]  lsiq_entry_ready;
  logic [7:0]  lsiq_entry_load;
  logic [7:0]  lsiq_entry_store;
  logic [7:0]  lsiq_pipe3_entry_ready;
  logic [7:0]  lsiq_pipe4_entry_ready;

  // unalign
  logic [7:0]  unalign_2nd;

  // pop
  logic [6:0]  lsiq_entry0_pop_other_entry;
  logic [6:0]  lsiq_entry1_pop_other_entry;
  logic [6:0]  lsiq_entry2_pop_other_entry;
  logic [6:0]  lsiq_entry3_pop_other_entry;
  logic [6:0]  lsiq_entry4_pop_other_entry;
  logic [6:0]  lsiq_entry5_pop_other_entry;
  logic [6:0]  lsiq_entry6_pop_other_entry;
  logic [6:0]  lsiq_entry7_pop_other_entry;
  logic        lsiq_entry0_pop_cur_entry;
  logic        lsiq_entry1_pop_cur_entry;
  logic        lsiq_entry2_pop_cur_entry;
  logic        lsiq_entry3_pop_cur_entry;
  logic        lsiq_entry4_pop_cur_entry;
  logic        lsiq_entry5_pop_cur_entry;
  logic        lsiq_entry6_pop_cur_entry;
  logic        lsiq_entry7_pop_cur_entry;

  // full set
  logic        lsiq_entry0_lq_full_set;
  logic        lsiq_entry1_lq_full_set;
  logic        lsiq_entry2_lq_full_set;
  logic        lsiq_entry3_lq_full_set;
  logic        lsiq_entry4_lq_full_set;
  logic        lsiq_entry5_lq_full_set;
  logic        lsiq_entry6_lq_full_set;
  logic        lsiq_entry7_lq_full_set;
  logic        lsiq_entry0_sq_full_set;
  logic        lsiq_entry1_sq_full_set;
  logic        lsiq_entry2_sq_full_set;
  logic        lsiq_entry3_sq_full_set;
  logic        lsiq_entry4_sq_full_set;
  logic        lsiq_entry5_sq_full_set;
  logic        lsiq_entry6_sq_full_set;
  logic        lsiq_entry7_sq_full_set;
  logic        lsiq_entry0_rb_full_set;
  logic        lsiq_entry1_rb_full_set;
  logic        lsiq_entry2_rb_full_set;
  logic        lsiq_entry3_rb_full_set;
  logic        lsiq_entry4_rb_full_set;
  logic        lsiq_entry5_rb_full_set;
  logic        lsiq_entry6_rb_full_set;
  logic        lsiq_entry7_rb_full_set;
  logic        lsiq_entry0_unalign_2nd_set;
  logic        lsiq_entry1_unalign_2nd_set;
  logic        lsiq_entry2_unalign_2nd_set;
  logic        lsiq_entry3_unalign_2nd_set;
  logic        lsiq_entry4_unalign_2nd_set;
  logic        lsiq_entry5_unalign_2nd_set;
  logic        lsiq_entry6_unalign_2nd_set;
  logic        lsiq_entry7_unalign_2nd_set;

  // raw ready
  logic [7:0]  lsiq_entry_raw_rdy;
  logic        lsiq_entry0_raw_rdy;
  logic        lsiq_entry1_raw_rdy;
  logic        lsiq_entry2_raw_rdy;
  logic        lsiq_entry3_raw_rdy;
  logic        lsiq_entry4_raw_rdy;
  logic        lsiq_entry5_raw_rdy;
  logic        lsiq_entry6_raw_rdy;
  logic        lsiq_entry7_raw_rdy;
  logic [6:0]  lsiq_entry0_other_raw_rdy;
  logic [6:0]  lsiq_entry1_other_raw_rdy;
  logic [6:0]  lsiq_entry2_other_raw_rdy;
  logic [6:0]  lsiq_entry3_other_raw_rdy;
  logic [6:0]  lsiq_entry4_other_raw_rdy;
  logic [6:0]  lsiq_entry5_other_raw_rdy;
  logic [6:0]  lsiq_entry6_other_raw_rdy;
  logic [6:0]  lsiq_entry7_other_raw_rdy;

  // read data
  logic [LSIQ_WIDTH-1:0] lsiq_entry0_read_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry1_read_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry2_read_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry3_read_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry4_read_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry5_read_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry6_read_data;
  logic [LSIQ_WIDTH-1:0] lsiq_entry7_read_data;

  // entry vld
  logic        lsiq_entry0_vld;
  logic        lsiq_entry1_vld;
  logic        lsiq_entry2_vld;
  logic        lsiq_entry3_vld;
  logic        lsiq_entry4_vld;
  logic        lsiq_entry5_vld;
  logic        lsiq_entry6_vld;
  logic        lsiq_entry7_vld;

  // 【补齐】create load/store 信号
  logic        dp_lsiq_create0_load;
  logic        dp_lsiq_create0_store;
  logic        dp_lsiq_create1_load;
  logic        dp_lsiq_create1_store;

  // 【补齐】entry old 信号
  logic        lsiq_entry0_old;
  logic        lsiq_entry1_old;
  logic        lsiq_entry2_old;
  logic        lsiq_entry3_old;
  logic        lsiq_entry4_old;
  logic        lsiq_entry5_old;
  logic        lsiq_entry6_old;
  logic        lsiq_entry7_old;

//--------------------lsiq entry counter--------------------
//if create, add entry counter
assign lsiq_entry_cnt_create[3:0]   = {3'b0,ctrl_lsiq_create0_en}
                                      + {3'b0,ctrl_lsiq_create1_en};
//if pop, sub entry counter
assign lsiq_entry_cnt_pop[3:0]      =
         {2'b0, lsu_idu_lsiq_pop0_vld &  lsu_idu_lsiq_pop1_vld,
                lsu_idu_lsiq_pop0_vld ^  lsu_idu_lsiq_pop1_vld};

//update valid and value
assign lsiq_entry_cnt_updt_vld      = ctrl_lsiq_create0_en
                                      || lsu_idu_lsiq_pop_vld;
assign lsiq_entry_cnt_updt_val[3:0] = lsiq_entry_cnt[3:0]
                                      + lsiq_entry_cnt_create[3:0]
                                      - lsiq_entry_cnt_pop[3:0];
//implement entry counter
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    lsiq_entry_cnt[3:0] <= 4'b0;
  //after flush fe/is, the lsu may wrongly pop before rtu_yy_xx_flush
  //need flush also when rtu_yy_xx_flush
  else if(rtu_yy_xx_flush)
    lsiq_entry_cnt[3:0] <= 4'b0;
  else if(lsiq_entry_cnt_updt_vld)
    lsiq_entry_cnt[3:0] <= lsiq_entry_cnt_updt_val[3:0];
  else
    lsiq_entry_cnt[3:0] <= lsiq_entry_cnt[3:0];
end

//--------------------lsiq entry full----------------------
assign lsiq_entry_cnt_create_2 =  ctrl_lsiq_create1_en;
assign lsiq_entry_cnt_create_1 =  ctrl_lsiq_create0_en && !ctrl_lsiq_create1_en;
assign lsiq_entry_cnt_create_0 = !ctrl_lsiq_create0_en;

assign lsiq_entry_cnt_pop_1    =  lsu_idu_lsiq_pop0_vld && !lsu_idu_lsiq_pop1_vld
                              || !lsu_idu_lsiq_pop0_vld &&  lsu_idu_lsiq_pop1_vld;
assign lsiq_entry_cnt_pop_0    = !lsu_idu_lsiq_pop0_vld && !lsu_idu_lsiq_pop1_vld;

assign lsiq_ctrl_full_updt     = (lsiq_entry_cnt[3:0] == 4'd6)
                                 && lsiq_entry_cnt_create_2
                                 && lsiq_entry_cnt_pop_0
                              || (lsiq_entry_cnt[3:0] == 4'd7)
                                 && lsiq_entry_cnt_create_1
                                 && lsiq_entry_cnt_pop_0
                              || (lsiq_entry_cnt[3:0] == 4'd8)
                                 && lsiq_entry_cnt_create_0
                                 && lsiq_entry_cnt_pop_0;

assign lsiq_ctrl_1_left_updt   = (lsiq_entry_cnt[3:0] == 4'd5)
                                 && lsiq_entry_cnt_create_2
                                 && lsiq_entry_cnt_pop_0
                              || (lsiq_entry_cnt[3:0] == 4'd6)
                                 && lsiq_entry_cnt_create_1
                                 && lsiq_entry_cnt_pop_0
                              || (lsiq_entry_cnt[3:0] == 4'd6)
                                 && lsiq_entry_cnt_create_2
                                 && lsiq_entry_cnt_pop_1
                              || (lsiq_entry_cnt[3:0] == 4'd7)
                                 && lsiq_entry_cnt_create_0
                                 && lsiq_entry_cnt_pop_0
                              || (lsiq_entry_cnt[3:0] == 4'd7)
                                 && lsiq_entry_cnt_create_1
                                 && lsiq_entry_cnt_pop_1
                              || (lsiq_entry_cnt[3:0] == 4'd8)
                                 && lsiq_entry_cnt_create_0
                                 && lsiq_entry_cnt_pop_1;

assign lsiq_entry_vld[7:0] =
        {lsiq_entry7_vld, lsiq_entry6_vld, lsiq_entry5_vld, lsiq_entry4_vld,
         lsiq_entry3_vld, lsiq_entry2_vld, lsiq_entry1_vld, lsiq_entry0_vld};

// create0 priority is from entry 0 to 7
// 找最低的无效位：低位优先
always @(*)
begin
  casez (lsiq_entry_vld[7:0])
    8'b????_???0: lsiq_entry_create0_in[7:0] = 8'b0000_0001;
    8'b????_??01: lsiq_entry_create0_in[7:0] = 8'b0000_0010;
    8'b????_?011: lsiq_entry_create0_in[7:0] = 8'b0000_0100;
    8'b????_0111: lsiq_entry_create0_in[7:0] = 8'b0000_1000;
    8'b???0_1111: lsiq_entry_create0_in[7:0] = 8'b0001_0000;
    8'b??01_1111: lsiq_entry_create0_in[7:0] = 8'b0010_0000;
    8'b?011_1111: lsiq_entry_create0_in[7:0] = 8'b0100_0000;
    8'b0111_1111: lsiq_entry_create0_in[7:0] = 8'b1000_0000;
    default:      lsiq_entry_create0_in[7:0] = 8'b0000_0000; // 8'b1111_1111
  endcase
end

// create1 priority is from entry 7 to 0
// 找最高的无效位：高位优先
always @(*)
begin
  casez (lsiq_entry_vld[7:0])
    8'b0???_????: lsiq_entry_create1_in[7:0] = 8'b1000_0000;
    8'b10??_????: lsiq_entry_create1_in[7:0] = 8'b0100_0000;
    8'b110?_????: lsiq_entry_create1_in[7:0] = 8'b0010_0000;
    8'b1110_????: lsiq_entry_create1_in[7:0] = 8'b0001_0000;
    8'b1111_0???: lsiq_entry_create1_in[7:0] = 8'b0000_1000;
    8'b1111_10??: lsiq_entry_create1_in[7:0] = 8'b0000_0100;
    8'b1111_110?: lsiq_entry_create1_in[7:0] = 8'b0000_0010;
    8'b1111_1110: lsiq_entry_create1_in[7:0] = 8'b0000_0001;
    default:      lsiq_entry_create1_in[7:0] = 8'b0000_0000; // 8'b1111_1111
  endcase
end


assign lsiq_entry_create_en[7:0] =
       {8{ctrl_lsiq_create0_en}} & lsiq_entry_create0_in[7:0]
     | {8{ctrl_lsiq_create1_en}} & lsiq_entry_create1_in[7:0];

assign lsiq_entry0_create_en  = lsiq_entry_create_en[0];
assign lsiq_entry1_create_en  = lsiq_entry_create_en[1];
assign lsiq_entry2_create_en  = lsiq_entry_create_en[2];
assign lsiq_entry3_create_en  = lsiq_entry_create_en[3];
assign lsiq_entry4_create_en  = lsiq_entry_create_en[4];
assign lsiq_entry5_create_en  = lsiq_entry_create_en[5];
assign lsiq_entry6_create_en  = lsiq_entry_create_en[6];
assign lsiq_entry7_create_en  = lsiq_entry_create_en[7];

assign dp_lsiq_create0_load = dp_lsiq_create0_data[LSIQ_LOAD];
assign dp_lsiq_create0_store = dp_lsiq_create0_data[LSIQ_STORE];
assign dp_lsiq_create1_load = dp_lsiq_create1_data[LSIQ_LOAD];
assign dp_lsiq_create1_store = dp_lsiq_create1_data[LSIQ_STORE];
//-------------------agevec of same type--------------------
//create 0 age vectors:
//1.existed entries of same type (bar and store shares same type)
assign lsiq_entry_create0_agevec[7:0] =
          lsiq_entry_vld[7:0]
          & ( {8{dp_lsiq_create0_load}} & lsiq_entry_load[7:0]
            | {8{dp_lsiq_create0_store}} & lsiq_entry_store[7:0])
          & ~(lsu_idu_lsiq_pop_entry[7:0]);
//create 1 age vectors:
//1.existed entries of same type
//2.create 0 entry of same type
assign lsiq_entry_create1_agevec[7:0] =
          lsiq_entry_vld[7:0]
          & ( {8{dp_lsiq_create1_load}} & lsiq_entry_load[7:0]
            | {8{dp_lsiq_create1_store}} & lsiq_entry_store[7:0])
          & ~(lsu_idu_lsiq_pop_entry[7:0])
        | lsiq_entry_create0_in[7:0]
          & {8{dp_lsiq_create0_load && dp_lsiq_create1_load
            || dp_lsiq_create0_store && dp_lsiq_create1_store}};

//----------------entry0 flop create signals----------------
always @(*)
begin
  if(lsiq_entry_create0_in[0]) begin
    lsiq_entry0_create_agevec[6:0]     = lsiq_entry_create0_agevec[7:1];
    lsiq_entry0_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create0_data[LSIQ_WIDTH-1:0];
  end
  else begin
    lsiq_entry0_create_agevec[6:0]     = lsiq_entry_create1_agevec[7:1];
    lsiq_entry0_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create1_data[LSIQ_WIDTH-1:0];
  end
end
always @(*)
begin
  if(lsiq_entry_create0_in[1]) begin
    lsiq_entry1_create_agevec[6:0]     = {lsiq_entry_create0_agevec[7:2],lsiq_entry_create0_agevec[0]};
    lsiq_entry1_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create0_data[LSIQ_WIDTH-1:0];
  end
  else begin
    lsiq_entry1_create_agevec[6:0]     = {lsiq_entry_create1_agevec[7:2],lsiq_entry_create1_agevec[0]};
    lsiq_entry1_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create1_data[LSIQ_WIDTH-1:0];
  end
end
always @(*)
begin
  if(lsiq_entry_create0_in[2]) begin
    lsiq_entry2_create_agevec[6:0]     = {lsiq_entry_create0_agevec[7:3], lsiq_entry_create0_agevec[1:0]};
    lsiq_entry2_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create0_data[LSIQ_WIDTH-1:0];
  end
  else begin
    lsiq_entry2_create_agevec[6:0]     = {lsiq_entry_create1_agevec[7:3], lsiq_entry_create1_agevec[1:0]};
    lsiq_entry2_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create1_data[LSIQ_WIDTH-1:0];
  end
end

always @(*)
begin
  if(lsiq_entry_create0_in[3]) begin
    lsiq_entry3_create_agevec[6:0]     = {lsiq_entry_create0_agevec[7:4], lsiq_entry_create0_agevec[2:0]};
    lsiq_entry3_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create0_data[LSIQ_WIDTH-1:0];
  end
  else begin
    lsiq_entry3_create_agevec[6:0]     = {lsiq_entry_create1_agevec[7:4], lsiq_entry_create1_agevec[2:0]};
    lsiq_entry3_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create1_data[LSIQ_WIDTH-1:0];
  end
end

always @(*)
begin
  if(lsiq_entry_create0_in[4]) begin
    lsiq_entry4_create_agevec[6:0]     = {lsiq_entry_create0_agevec[7:5], lsiq_entry_create0_agevec[3:0]};
    lsiq_entry4_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create0_data[LSIQ_WIDTH-1:0];
  end
  else begin
    lsiq_entry4_create_agevec[6:0]     = {lsiq_entry_create1_agevec[7:5], lsiq_entry_create1_agevec[3:0]};
    lsiq_entry4_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create1_data[LSIQ_WIDTH-1:0];
  end
end

always @(*)
begin
  if(lsiq_entry_create0_in[5]) begin
    lsiq_entry5_create_agevec[6:0]     = {lsiq_entry_create0_agevec[7:6], lsiq_entry_create0_agevec[4:0]};
    lsiq_entry5_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create0_data[LSIQ_WIDTH-1:0];
  end
  else begin
    lsiq_entry5_create_agevec[6:0]     = {lsiq_entry_create1_agevec[7:6], lsiq_entry_create1_agevec[4:0]};
    lsiq_entry5_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create1_data[LSIQ_WIDTH-1:0];
  end
end

always @(*)
begin
  if(lsiq_entry_create0_in[6]) begin
    lsiq_entry6_create_agevec[6:0]     = {lsiq_entry_create0_agevec[7], lsiq_entry_create0_agevec[5:0]};
    lsiq_entry6_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create0_data[LSIQ_WIDTH-1:0];
  end
  else begin
    lsiq_entry6_create_agevec[6:0]     = {lsiq_entry_create1_agevec[7], lsiq_entry_create1_agevec[5:0]};
    lsiq_entry6_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create1_data[LSIQ_WIDTH-1:0];
  end
end

always @(*)
begin
  if(lsiq_entry_create0_in[7]) begin
    lsiq_entry7_create_agevec[6:0]     = lsiq_entry_create0_agevec[6:0];
    lsiq_entry7_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create0_data[LSIQ_WIDTH-1:0];
  end
  else begin
    lsiq_entry7_create_agevec[6:0]     = lsiq_entry_create1_agevec[6:0];
    lsiq_entry7_create_data[LSIQ_WIDTH-1:0] =
       dp_lsiq_create1_data[LSIQ_WIDTH-1:0];
  end
end

//==========================================================
//             LSU Issue Queue Issue Control
//==========================================================
//-----------entry issue enable signals for entries---------
//issue signals for entries ignore inst type
assign lsiq_entry_issue_en[7:0]  = lsiq_entry_ready[7:0];

//---------------entry issue signals for rf pipes-----------
//load entry ready
assign lsiq_pipe3_entry_ready[7:0]    = lsiq_entry_ready[7:0]
                                         & lsiq_entry_load[7:0];
//store and bar entry ready
assign lsiq_pipe4_entry_ready[7:0]    = lsiq_entry_ready[7:0]
                                         & lsiq_entry_store[7:0];
//issue enable for rf pipes:
//consider inst type
assign lsiq_dp_pipe3_issue_entry[7:0] = lsiq_pipe3_entry_ready[7:0];
assign lsiq_dp_pipe4_issue_entry[7:0] = lsiq_pipe4_entry_ready[7:0];

assign lsiq_rf_pipe3_issue_en = |lsiq_dp_pipe3_issue_entry[7:0];

assign lsiq_rf_pipe4_issue_en = |lsiq_dp_pipe4_issue_entry[7:0];

//-----------------issue data path selection----------------
always @(*)
begin
  case (lsiq_dp_pipe3_issue_entry[7:0])
    8'h01: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry0_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe3_entry_unalign_2nd = unalign_2nd[0];
             lsiq_pipe3_entry_old         = lsiq_entry0_old;
           end
    8'h02: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry1_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe3_entry_unalign_2nd = unalign_2nd[1];
             lsiq_pipe3_entry_old         = lsiq_entry1_old;
           end
    8'h04: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry2_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe3_entry_unalign_2nd = unalign_2nd[2];
             lsiq_pipe3_entry_old         = lsiq_entry2_old;
           end
    8'h08: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry3_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe3_entry_unalign_2nd = unalign_2nd[3];
             lsiq_pipe3_entry_old         = lsiq_entry3_old;
           end
    8'h10: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry4_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe3_entry_unalign_2nd = unalign_2nd[4];
             lsiq_pipe3_entry_old         = lsiq_entry4_old;
           end
    8'h20: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry5_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe3_entry_unalign_2nd = unalign_2nd[5];
             lsiq_pipe3_entry_old         = lsiq_entry5_old;
           end
    8'h40: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry6_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe3_entry_unalign_2nd = unalign_2nd[6];
             lsiq_pipe3_entry_old         = lsiq_entry6_old;
           end
    8'h80: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry7_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe3_entry_unalign_2nd = unalign_2nd[7];
             lsiq_pipe3_entry_old         = lsiq_entry7_old;
           end
    default: begin
             lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] =
                                     {LSIQ_WIDTH{1'bx}};
             lsiq_pipe3_entry_unalign_2nd = 1'bx;
             lsiq_pipe3_entry_old         = 1'bx;
           end
  endcase
end

always @(*)
begin
  case (lsiq_dp_pipe4_issue_entry[7:0])
    8'h01: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry0_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe4_entry_unalign_2nd = unalign_2nd[0];
             lsiq_pipe4_entry_old         = lsiq_entry0_old;
           end
    8'h02: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry1_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe4_entry_unalign_2nd = unalign_2nd[1];
             lsiq_pipe4_entry_old         = lsiq_entry1_old;
           end
    8'h04: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry2_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe4_entry_unalign_2nd = unalign_2nd[2];
             lsiq_pipe4_entry_old         = lsiq_entry2_old;
           end
    8'h08: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry3_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe4_entry_unalign_2nd = unalign_2nd[3];
             lsiq_pipe4_entry_old         = lsiq_entry3_old;
           end
    8'h10: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry4_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe4_entry_unalign_2nd = unalign_2nd[4];
             lsiq_pipe4_entry_old         = lsiq_entry4_old;
           end
    8'h20: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry5_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe4_entry_unalign_2nd = unalign_2nd[5];
             lsiq_pipe4_entry_old         = lsiq_entry5_old;
           end
    8'h40: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry6_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe4_entry_unalign_2nd = unalign_2nd[6];
             lsiq_pipe4_entry_old         = lsiq_entry6_old;
           end
    8'h80: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
               lsiq_entry7_read_data[LSIQ_WIDTH-1:0];
             lsiq_pipe4_entry_unalign_2nd = unalign_2nd[7];
             lsiq_pipe4_entry_old         = lsiq_entry7_old;
           end
    default: begin
             lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] =
                                     {LSIQ_WIDTH{1'bx}};
             lsiq_pipe4_entry_unalign_2nd = 1'bx;
             lsiq_pipe4_entry_old         = 1'bx;
           end
  endcase
end

//==========================================================
//            LSU Issue Queue Launch Control
//==========================================================
//-------------------entry pop enable signals---------------
//pop when rf launch pass
assign {lsiq_entry0_pop_other_entry[6:0],
        lsiq_entry0_pop_cur_entry}          = lsu_idu_lsiq_pop_entry[7:0];
assign {lsiq_entry1_pop_other_entry[6:1],
        lsiq_entry1_pop_cur_entry,
        lsiq_entry1_pop_other_entry[0]}     = lsu_idu_lsiq_pop_entry[7:0];
assign {lsiq_entry2_pop_other_entry[6:2],
        lsiq_entry2_pop_cur_entry,
        lsiq_entry2_pop_other_entry[1:0]}   = lsu_idu_lsiq_pop_entry[7:0];
assign {lsiq_entry3_pop_other_entry[6:3],
        lsiq_entry3_pop_cur_entry,
        lsiq_entry3_pop_other_entry[2:0]}   = lsu_idu_lsiq_pop_entry[7:0];
assign {lsiq_entry4_pop_other_entry[6:4],
        lsiq_entry4_pop_cur_entry,
        lsiq_entry4_pop_other_entry[3:0]}   = lsu_idu_lsiq_pop_entry[7:0];
assign {lsiq_entry5_pop_other_entry[6:5],
        lsiq_entry5_pop_cur_entry,
        lsiq_entry5_pop_other_entry[4:0]}   = lsu_idu_lsiq_pop_entry[7:0];
assign {lsiq_entry6_pop_other_entry[6:6],
        lsiq_entry6_pop_cur_entry,
        lsiq_entry6_pop_other_entry[5:0]}   = lsu_idu_lsiq_pop_entry[7:0];
assign {lsiq_entry7_pop_cur_entry,
        lsiq_entry7_pop_other_entry[6:0]}   = lsu_idu_lsiq_pop_entry[7:0];


//------------------lsu bits set signals--------------------
assign lsiq_entry0_lq_full_set           = lsu_idu_lq_full[0];
assign lsiq_entry1_lq_full_set           = lsu_idu_lq_full[1];
assign lsiq_entry2_lq_full_set           = lsu_idu_lq_full[2];
assign lsiq_entry3_lq_full_set           = lsu_idu_lq_full[3];
assign lsiq_entry4_lq_full_set           = lsu_idu_lq_full[4];
assign lsiq_entry5_lq_full_set           = lsu_idu_lq_full[5];
assign lsiq_entry6_lq_full_set           = lsu_idu_lq_full[6];
assign lsiq_entry7_lq_full_set           = lsu_idu_lq_full[7];


assign lsiq_entry0_sq_full_set           = lsu_idu_sq_full[0];
assign lsiq_entry1_sq_full_set           = lsu_idu_sq_full[1];
assign lsiq_entry2_sq_full_set           = lsu_idu_sq_full[2];
assign lsiq_entry3_sq_full_set           = lsu_idu_sq_full[3];
assign lsiq_entry4_sq_full_set           = lsu_idu_sq_full[4];
assign lsiq_entry5_sq_full_set           = lsu_idu_sq_full[5];
assign lsiq_entry6_sq_full_set           = lsu_idu_sq_full[6];
assign lsiq_entry7_sq_full_set           = lsu_idu_sq_full[7];

assign lsiq_entry0_rb_full_set           = lsu_idu_rb_full[0];
assign lsiq_entry1_rb_full_set           = lsu_idu_rb_full[1];
assign lsiq_entry2_rb_full_set           = lsu_idu_rb_full[2];
assign lsiq_entry3_rb_full_set           = lsu_idu_rb_full[3];
assign lsiq_entry4_rb_full_set           = lsu_idu_rb_full[4];
assign lsiq_entry5_rb_full_set           = lsu_idu_rb_full[5];
assign lsiq_entry6_rb_full_set           = lsu_idu_rb_full[6];
assign lsiq_entry7_rb_full_set           = lsu_idu_rb_full[7];

assign lsiq_entry0_unalign_2nd_set       = lsu_idu_secd[0];
assign lsiq_entry1_unalign_2nd_set       = lsu_idu_secd[1];
assign lsiq_entry2_unalign_2nd_set       = lsu_idu_secd[2];
assign lsiq_entry3_unalign_2nd_set       = lsu_idu_secd[3];
assign lsiq_entry4_unalign_2nd_set       = lsu_idu_secd[4];
assign lsiq_entry5_unalign_2nd_set       = lsu_idu_secd[5];
assign lsiq_entry6_unalign_2nd_set       = lsu_idu_secd[6];
assign lsiq_entry7_unalign_2nd_set       = lsu_idu_secd[7];



assign lsiq_entry_raw_rdy[7:0] =
       {lsiq_entry7_raw_rdy,  lsiq_entry6_raw_rdy,
        lsiq_entry5_raw_rdy,  lsiq_entry4_raw_rdy,  lsiq_entry3_raw_rdy,
        lsiq_entry2_raw_rdy,  lsiq_entry1_raw_rdy,  lsiq_entry0_raw_rdy};

assign lsiq_entry0_other_raw_rdy[6:0]  =  lsiq_entry_raw_rdy[7:1];
assign lsiq_entry1_other_raw_rdy[6:0]  = {lsiq_entry_raw_rdy[7:2], lsiq_entry_raw_rdy[0]};
assign lsiq_entry2_other_raw_rdy[6:0]  = {lsiq_entry_raw_rdy[7:3], lsiq_entry_raw_rdy[1:0]};
assign lsiq_entry3_other_raw_rdy[6:0]  = {lsiq_entry_raw_rdy[7:4], lsiq_entry_raw_rdy[2:0]};
assign lsiq_entry4_other_raw_rdy[6:0]  = {lsiq_entry_raw_rdy[7:5], lsiq_entry_raw_rdy[3:0]};
assign lsiq_entry5_other_raw_rdy[6:0]  = {lsiq_entry_raw_rdy[7:6], lsiq_entry_raw_rdy[4:0]};
assign lsiq_entry6_other_raw_rdy[6:0]  = {lsiq_entry_raw_rdy[7],   lsiq_entry_raw_rdy[5:0]};
assign lsiq_entry7_other_raw_rdy[6:0]  =  lsiq_entry_raw_rdy[6:0];

//==========================================================
//             LSU Issue Queue Entry Instance
//==========================================================
ct_idu_is_lsiq_entry u_ct_idu_is_lsiq_entry0 (
  .cpurst_b                         (cpurst_b                         ),
  .forever_cpuclk                   (forever_cpuclk                   ),
  .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
  .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
  .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
  .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
  .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[0]),
  .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),
  .x_create_agevec                  (lsiq_entry0_create_agevec        ),
  .x_create_data                    (lsiq_entry0_create_data          ),
  .x_create_en                      (lsiq_entry0_create_en            ),
  .x_issue_en                       (lsiq_entry_issue_en[0]           ),
  .x_load                           (lsiq_entry_load[0]               ),
  .x_lq_full_set                    (lsiq_entry0_lq_full_set          ),
  .x_other_raw_rdy                  (lsiq_entry0_other_raw_rdy        ),
  .x_pop_cur_entry                  (lsiq_entry0_pop_cur_entry        ),
  .x_pop_other_entry                (lsiq_entry0_pop_other_entry      ),
  .x_raw_rdy                        (lsiq_entry0_raw_rdy              ),
  .x_rb_full_set                    (lsiq_entry0_rb_full_set          ),
  .x_rdy                            (lsiq_entry_ready[0]              ),
  .x_read_data                      (lsiq_entry0_read_data            ),
  .unalign_2nd                      (unalign_2nd[0]                   ),
  .x_sq_full_set                    (lsiq_entry0_sq_full_set          ),
  .x_store                          (lsiq_entry_store[0]              ),
  .x_unalign_2nd_set                (lsiq_entry0_unalign_2nd_set      ),
  .x_vld                            (lsiq_entry0_vld                  ),
  .old                              (lsiq_entry0_old                  )
);

ct_idu_is_lsiq_entry u_ct_idu_is_lsiq_entry1 (
  .cpurst_b                         (cpurst_b                         ),
  .forever_cpuclk                   (forever_cpuclk                   ),
  .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
  .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
  .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
  .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
  .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[1]),
  .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),
  .x_create_agevec                  (lsiq_entry1_create_agevec        ),
  .x_create_data                    (lsiq_entry1_create_data          ),
  .x_create_en                      (lsiq_entry1_create_en            ),
  .x_issue_en                       (lsiq_entry_issue_en[1]           ),
  .x_load                           (lsiq_entry_load[1]               ),
  .x_lq_full_set                    (lsiq_entry1_lq_full_set          ),
  .x_other_raw_rdy                  (lsiq_entry1_other_raw_rdy        ),
  .x_pop_cur_entry                  (lsiq_entry1_pop_cur_entry        ),
  .x_pop_other_entry                (lsiq_entry1_pop_other_entry      ),
  .x_raw_rdy                        (lsiq_entry1_raw_rdy              ),
  .x_rb_full_set                    (lsiq_entry1_rb_full_set          ),
  .x_rdy                            (lsiq_entry_ready[1]              ),
  .x_read_data                      (lsiq_entry1_read_data            ),
  .unalign_2nd                      (unalign_2nd[1]                   ),
  .x_sq_full_set                    (lsiq_entry1_sq_full_set          ),
  .x_store                          (lsiq_entry_store[1]              ),
  .x_unalign_2nd_set                (lsiq_entry1_unalign_2nd_set      ),
  .x_vld                            (lsiq_entry1_vld                  ),
  .old                              (lsiq_entry1_old                  )
);

ct_idu_is_lsiq_entry u_ct_idu_is_lsiq_entry2 (
  .cpurst_b                         (cpurst_b                         ),
  .forever_cpuclk                   (forever_cpuclk                   ),
  .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
  .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
  .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
  .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
  .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[2]),
  .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),
  .x_create_agevec                  (lsiq_entry2_create_agevec        ),
  .x_create_data                    (lsiq_entry2_create_data          ),
  .x_create_en                      (lsiq_entry2_create_en            ),
  .x_issue_en                       (lsiq_entry_issue_en[2]           ),
  .x_load                           (lsiq_entry_load[2]               ),
  .x_lq_full_set                    (lsiq_entry2_lq_full_set          ),
  .x_other_raw_rdy                  (lsiq_entry2_other_raw_rdy        ),
  .x_pop_cur_entry                  (lsiq_entry2_pop_cur_entry        ),
  .x_pop_other_entry                (lsiq_entry2_pop_other_entry      ),
  .x_raw_rdy                        (lsiq_entry2_raw_rdy              ),
  .x_rb_full_set                    (lsiq_entry2_rb_full_set          ),
  .x_rdy                            (lsiq_entry_ready[2]              ),
  .x_read_data                      (lsiq_entry2_read_data            ),
  .unalign_2nd                      (unalign_2nd[2]                   ),
  .x_sq_full_set                    (lsiq_entry2_sq_full_set          ),
  .x_store                          (lsiq_entry_store[2]              ),
  .x_unalign_2nd_set                (lsiq_entry2_unalign_2nd_set      ),
  .x_vld                            (lsiq_entry2_vld                  ),
  .old                              (lsiq_entry2_old                  )
);

ct_idu_is_lsiq_entry u_ct_idu_is_lsiq_entry3 (
  .cpurst_b                         (cpurst_b                         ),
  .forever_cpuclk                   (forever_cpuclk                   ),
  .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
  .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
  .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
  .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
  .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[3]),
  .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),
  .x_create_agevec                  (lsiq_entry3_create_agevec        ),
  .x_create_data                    (lsiq_entry3_create_data          ),
  .x_create_en                      (lsiq_entry3_create_en            ),
  .x_issue_en                       (lsiq_entry_issue_en[3]           ),
  .x_load                           (lsiq_entry_load[3]               ),
  .x_lq_full_set                    (lsiq_entry3_lq_full_set          ),
  .x_other_raw_rdy                  (lsiq_entry3_other_raw_rdy        ),
  .x_pop_cur_entry                  (lsiq_entry3_pop_cur_entry        ),
  .x_pop_other_entry                (lsiq_entry3_pop_other_entry      ),
  .x_raw_rdy                        (lsiq_entry3_raw_rdy              ),
  .x_rb_full_set                    (lsiq_entry3_rb_full_set          ),
  .x_rdy                            (lsiq_entry_ready[3]              ),
  .x_read_data                      (lsiq_entry3_read_data            ),
  .unalign_2nd                      (unalign_2nd[3]                   ),
  .x_sq_full_set                    (lsiq_entry3_sq_full_set          ),
  .x_store                          (lsiq_entry_store[3]              ),
  .x_unalign_2nd_set                (lsiq_entry3_unalign_2nd_set      ),
  .x_vld                            (lsiq_entry3_vld                  ),
  .old                              (lsiq_entry3_old                  )
);

ct_idu_is_lsiq_entry u_ct_idu_is_lsiq_entry4 (
  .cpurst_b                         (cpurst_b                         ),
  .forever_cpuclk                   (forever_cpuclk                   ),
  .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
  .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
  .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
  .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
  .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[4]),
  .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),
  .x_create_agevec                  (lsiq_entry4_create_agevec        ),
  .x_create_data                    (lsiq_entry4_create_data          ),
  .x_create_en                      (lsiq_entry4_create_en            ),
  .x_issue_en                       (lsiq_entry_issue_en[4]           ),
  .x_load                           (lsiq_entry_load[4]               ),
  .x_lq_full_set                    (lsiq_entry4_lq_full_set          ),
  .x_other_raw_rdy                  (lsiq_entry4_other_raw_rdy        ),
  .x_pop_cur_entry                  (lsiq_entry4_pop_cur_entry        ),
  .x_pop_other_entry                (lsiq_entry4_pop_other_entry      ),
  .x_raw_rdy                        (lsiq_entry4_raw_rdy              ),
  .x_rb_full_set                    (lsiq_entry4_rb_full_set          ),
  .x_rdy                            (lsiq_entry_ready[4]              ),
  .x_read_data                      (lsiq_entry4_read_data            ),
  .unalign_2nd                      (unalign_2nd[4]                   ),
  .x_sq_full_set                    (lsiq_entry4_sq_full_set          ),
  .x_store                          (lsiq_entry_store[4]              ),
  .x_unalign_2nd_set                (lsiq_entry4_unalign_2nd_set      ),
  .x_vld                            (lsiq_entry4_vld                  ),
  .old                              (lsiq_entry4_old                  )
);

ct_idu_is_lsiq_entry u_ct_idu_is_lsiq_entry5 (
  .cpurst_b                         (cpurst_b                         ),
  .forever_cpuclk                   (forever_cpuclk                   ),
  .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
  .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
  .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
  .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
  .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[5]),
  .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),
  .x_create_agevec                  (lsiq_entry5_create_agevec        ),
  .x_create_data                    (lsiq_entry5_create_data          ),
  .x_create_en                      (lsiq_entry5_create_en            ),
  .x_issue_en                       (lsiq_entry_issue_en[5]           ),
  .x_load                           (lsiq_entry_load[5]               ),
  .x_lq_full_set                    (lsiq_entry5_lq_full_set          ),
  .x_other_raw_rdy                  (lsiq_entry5_other_raw_rdy        ),
  .x_pop_cur_entry                  (lsiq_entry5_pop_cur_entry        ),
  .x_pop_other_entry                (lsiq_entry5_pop_other_entry      ),
  .x_raw_rdy                        (lsiq_entry5_raw_rdy              ),
  .x_rb_full_set                    (lsiq_entry5_rb_full_set          ),
  .x_rdy                            (lsiq_entry_ready[5]              ),
  .x_read_data                      (lsiq_entry5_read_data            ),
  .unalign_2nd                      (unalign_2nd[5]                   ),
  .x_sq_full_set                    (lsiq_entry5_sq_full_set          ),
  .x_store                          (lsiq_entry_store[5]              ),
  .x_unalign_2nd_set                (lsiq_entry5_unalign_2nd_set      ),
  .x_vld                            (lsiq_entry5_vld                  ),
  .old                              (lsiq_entry5_old                  )
);

ct_idu_is_lsiq_entry u_ct_idu_is_lsiq_entry6 (
  .cpurst_b                         (cpurst_b                         ),
  .forever_cpuclk                   (forever_cpuclk                   ),
  .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
  .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
  .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
  .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
  .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[6]),
  .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),
  .x_create_agevec                  (lsiq_entry6_create_agevec        ),
  .x_create_data                    (lsiq_entry6_create_data          ),
  .x_create_en                      (lsiq_entry6_create_en            ),
  .x_issue_en                       (lsiq_entry_issue_en[6]           ),
  .x_load                           (lsiq_entry_load[6]               ),
  .x_lq_full_set                    (lsiq_entry6_lq_full_set          ),
  .x_other_raw_rdy                  (lsiq_entry6_other_raw_rdy        ),
  .x_pop_cur_entry                  (lsiq_entry6_pop_cur_entry        ),
  .x_pop_other_entry                (lsiq_entry6_pop_other_entry      ),
  .x_raw_rdy                        (lsiq_entry6_raw_rdy              ),
  .x_rb_full_set                    (lsiq_entry6_rb_full_set          ),
  .x_rdy                            (lsiq_entry_ready[6]              ),
  .x_read_data                      (lsiq_entry6_read_data            ),
  .unalign_2nd                      (unalign_2nd[6]                   ),
  .x_sq_full_set                    (lsiq_entry6_sq_full_set          ),
  .x_store                          (lsiq_entry_store[6]              ),
  .x_unalign_2nd_set                (lsiq_entry6_unalign_2nd_set      ),
  .x_vld                            (lsiq_entry6_vld                  ),
  .old                              (lsiq_entry6_old                  )
);

ct_idu_is_lsiq_entry u_ct_idu_is_lsiq_entry7 (
  .cpurst_b                         (cpurst_b                         ),
  .forever_cpuclk                   (forever_cpuclk                   ),
  .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
  .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
  .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
  .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
  .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
  .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
  .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
  .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
  .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[7]),
  .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
  .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
  .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),
  .x_create_agevec                  (lsiq_entry7_create_agevec        ),
  .x_create_data                    (lsiq_entry7_create_data          ),
  .x_create_en                      (lsiq_entry7_create_en            ),
  .x_issue_en                       (lsiq_entry_issue_en[7]           ),
  .x_load                           (lsiq_entry_load[7]               ),
  .x_lq_full_set                    (lsiq_entry7_lq_full_set          ),
  .x_other_raw_rdy                  (lsiq_entry7_other_raw_rdy        ),
  .x_pop_cur_entry                  (lsiq_entry7_pop_cur_entry        ),
  .x_pop_other_entry                (lsiq_entry7_pop_other_entry      ),
  .x_raw_rdy                        (lsiq_entry7_raw_rdy              ),
  .x_rb_full_set                    (lsiq_entry7_rb_full_set          ),
  .x_rdy                            (lsiq_entry_ready[7]              ),
  .x_read_data                      (lsiq_entry7_read_data            ),
  .unalign_2nd                      (unalign_2nd[7]                   ),
  .x_sq_full_set                    (lsiq_entry7_sq_full_set          ),
  .x_store                          (lsiq_entry_store[7]              ),
  .x_unalign_2nd_set                (lsiq_entry7_unalign_2nd_set      ),
  .x_vld                            (lsiq_entry7_vld                  ),
  .old                              (lsiq_entry7_old                  )
);

endmodule