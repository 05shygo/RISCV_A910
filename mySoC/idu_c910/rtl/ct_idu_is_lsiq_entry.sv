module ct_idu_is_lsiq_entry (
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic         lsu_idu_lq_not_full,
  input  logic         lsu_idu_lsiq_pop_vld,
  input  logic         lsu_idu_rb_not_full,
  input  logic         lsu_idu_sq_not_full,
  input  logic         lsu_idu_imme_wakeup,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush,
  input  logic [6:0]   x_create_agevec,
  input  logic [59:0]  x_create_data,
  input  logic         x_create_en,
  input  logic         x_issue_en,
  output logic         x_load,
  input  logic         x_lq_full_set,
  input  logic [6:0]   x_other_raw_rdy,
  input  logic         x_pop_cur_entry,
  input  logic [6:0]   x_pop_other_entry,
  output logic         x_raw_rdy,
  input  logic         x_rb_full_set,
  output logic         x_rdy,
  output logic [59:0]  x_read_data,
  output logic         unalign_2nd,
  input  logic         x_sq_full_set,
  output logic         x_store,
  input  logic         x_unalign_2nd_set,
  output logic         x_vld,
  output logic         old
);

//==========================================================
//                       Parameters
//==========================================================
//----------------------------------------------------------
//                    LSIQ Parameters
//----------------------------------------------------------
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

//==========================================================
//                  Internal Signal Declarations
//==========================================================
logic        vld;
logic        frz;
logic [6:0]  agevec;
logic        lsu_frz_clr;
logic [5:0]  dst_preg;
logic [3:0]  sdiq_entry;
logic [31:0] opcode;
logic [6:0]  iid;
logic        src0_vld;
logic        src1_vld;
logic        dst_vld;
logic        load;
logic        store;
logic        lq_full;
logic        lq_full_wakeup;
logic        sq_full;
logic        sq_full_wakeup;
logic        rb_full;
logic        rb_full_wakeup;

logic [6:0]  create_src0_data;
logic [6:0]  read_src0_data;
logic [6:0]  create_src1_data;
logic [6:0]  read_src1_data;
logic        src0_rdy_for_issue;
logic        src1_rdy_for_issue;
logic        older_entry_rdy_mask;


//==========================================================
//                      Entry Valid
//==========================================================
assign x_vld = vld;
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    vld <= 1'b0;
  else if(x_create_en)
    vld <= 1'b1;
  else if(lsu_idu_lsiq_pop_vld && x_pop_cur_entry)
    vld <= 1'b0;
  else
    vld <= vld;
end


//issue en has higher priority because bar check
//is still 1 when issue en, frz should be set
//when issue en and frz clr in this case
//bar check will be 0 after issue en
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    frz <= 1'b0;
  else if(x_create_en)
    frz <= 1'b0;
  else if(x_issue_en)
    frz <= 1'b1;
  else if(lsu_frz_clr | x_unalign_2nd_set | lsu_idu_imme_wakeup)
    frz <= 1'b0;
  else
    frz <= frz;
end

//==========================================================
//                       Age Vector
//==========================================================
//agevec of same type (store and bar share same type),
//used for issue
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    agevec[6:0] <= 7'b0;
  else if(x_create_en)
    agevec[6:0] <= x_create_agevec[6:0];
  else if(lsu_idu_lsiq_pop_vld)
    agevec[6:0] <= agevec[6:0] & ~x_pop_other_entry[6:0];
  else
    agevec[6:0] <= agevec[6:0];
end

//==========================================================
//                 Instruction Information
//==========================================================
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    dst_preg[5:0]      <= 6'b0;
  else if(x_create_en)
    dst_preg[5:0]      <= x_create_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5];
  else
    dst_preg[5:0]      <= dst_preg[5:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    sdiq_entry[3:0]   <= 4'b0;
  else if(x_create_en)
    sdiq_entry[3:0]   <= x_create_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3];
  else
    sdiq_entry[3:0]   <= sdiq_entry[3:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    opcode[31:0]       <= 32'b0;
    iid[6:0]           <= 7'b0;
    src0_vld           <= 1'b0;
    dst_vld            <= 1'b0;
    load               <= 1'b0;
    store              <= 1'b0;
  end
  else if(x_create_en) begin
    opcode[31:0]       <= x_create_data[LSIQ_OPCODE:LSIQ_OPCODE-31];
    iid[6:0]           <= x_create_data[LSIQ_IID:LSIQ_IID-6];
    src0_vld           <= x_create_data[LSIQ_SRC0_VLD];
    dst_vld            <= x_create_data[LSIQ_DST_VLD];
    load               <= x_create_data[LSIQ_LOAD];
    store              <= x_create_data[LSIQ_STORE];
  end
  else begin
    opcode[31:0]       <= opcode[31:0];
    iid[6:0]           <= iid[6:0];
    src0_vld           <= src0_vld;
    src1_vld           <= src1_vld;
    dst_vld            <= dst_vld;
    load               <= load;
    store              <= store;
  end
end

//rename for read output
assign x_read_data[LSIQ_OPCODE:LSIQ_OPCODE-31]         = opcode[31:0];
assign x_read_data[LSIQ_IID:LSIQ_IID-6]                = iid[6:0];
assign x_read_data[LSIQ_SRC0_VLD]                      = src0_vld;
assign x_read_data[LSIQ_DST_VLD]                       = dst_vld;
assign x_read_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5]      = dst_preg[5:0];
assign x_read_data[LSIQ_LOAD]                          = load;
assign x_read_data[LSIQ_STORE]                         = store;
assign x_read_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3] = sdiq_entry[3:0];

assign x_load                                          = load;
assign x_store                                         = store;

//==========================================================
//                LSU Freeze Clear Signals
//==========================================================
//if all bits of age vec is 0, this entry is the oldest entry
assign old  = !(|agevec[6:0]);

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    lq_full             <=  1'b0;
  else if(rtu_yy_xx_flush)
    lq_full             <=  1'b0;
  else if(x_lq_full_set && vld)
    lq_full             <=  1'b1;
  else if(lq_full_wakeup)
    lq_full             <=  1'b0;
  else
    lq_full             <=  lq_full;
end

assign lq_full_wakeup = lsu_idu_lq_not_full ||  old;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    sq_full             <=  1'b0;
  else if(rtu_yy_xx_flush)
    sq_full             <=  1'b0;
  else if(x_sq_full_set && vld)
    sq_full             <=  1'b1;
  else if(sq_full_wakeup)
    sq_full             <=  1'b0;
  else
    sq_full             <=  sq_full;
end

assign sq_full_wakeup = lsu_idu_sq_not_full ||  old;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rb_full             <=  1'b0;
  else if(rtu_yy_xx_flush)
    rb_full             <=  1'b0;
  else if(x_rb_full_set && vld)
    rb_full             <=  1'b1;
  else if(rb_full_wakeup)
    rb_full             <=  1'b0;
  else
    rb_full             <=  rb_full;
end

assign rb_full_wakeup = lsu_idu_rb_not_full ||  old;

assign lsu_frz_clr  =  (lq_full || sq_full || rb_full)
                      && (!lq_full       || lq_full       && lq_full_wakeup)
                      && (!sq_full       || sq_full       && sq_full_wakeup)
                      && (!rb_full       || rb_full       && rb_full_wakeup);

//==========================================================
//                    LSU Pass Signals
//==========================================================
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    unalign_2nd         <=  1'b0;
  else if(x_create_en)
    unalign_2nd         <=  1'b0;
  else if(x_unalign_2nd_set)
    unalign_2nd         <=  1'b1;
  else
    unalign_2nd         <=  unalign_2nd;
end


//==========================================================
//              Source Dependency Information
//==========================================================
    //------------------------source 0--------------------------
    assign create_src0_data[6:0] = x_create_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-6];

    //----------------------------------------------------------------------
    // Instance : ct_idu_dep_reg_entry
    // Desc     : 依赖寄存器 entry（写端口来自 ex2/wb pipe0/1/pipe3，读端口给 x）
    //----------------------------------------------------------------------
    ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src0 (
        .cpurst_b                         (cpurst_b                         ),
        .forever_cpuclk                   (forever_cpuclk                   ),

        // 写端口：IU pipe0 ex2 wb
        .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
        .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

        // 写端口：IU pipe1 ex2 wb
        .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
        .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

        // 写端口：LSU pipe3 wb
        .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
        .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

        // flush
        .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

        // 写数据 / 写使能
        .x_create_data                    (create_src0_data[6:0]            ),
        .x_write_en                       (x_create_en                      ),

        // 读数据
        .x_read_data                      (read_src0_data[6:0]              )
    );

    assign x_read_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-6] = read_src0_data[6:0];

//==========================================================
//                  Entry Ready Signal
//==========================================================
//------------------------raw ready-------------------------
//without older entry ready mask
// &Force ("output", "x_raw_rdy"); @718

assign src0_rdy_for_issue = read_src0_data[0];


assign x_raw_rdy = vld && !frz
                       && src0_rdy_for_issue;

//----------------------older ready-------------------------
//if older entry of same type raw ready, mask cur entry ready
assign older_entry_rdy_mask = |(agevec[6:0] & x_other_raw_rdy[6:0]);

//----------------------final ready-------------------------
//if older entry is ready, mask current entry ready
assign x_rdy = x_raw_rdy && !older_entry_rdy_mask;

// &ModuleEnd; @732
endmodule