module ct_lsu_vb #(
    parameter BIU_VB_ID_T = 2'b00,
    parameter DCACHE_SIZE = 2048,  // 1024, 2048, or 4096 bytes
    parameter int CACHELINE_SIZE = 32,
    parameter int NUM_WAYS = 2,
    parameter int OFFSET_WIDTH = 5,
    parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
    parameter int INDEX_WIDTH = $clog2(NUM_SETS),
    parameter int INDEX_LSB = OFFSET_WIDTH,
    parameter int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1,
    parameter int TAG_LSB = INDEX_MSB + 1,
    parameter int TAG_WIDTH = 32 - TAG_LSB,
    parameter int LD_TAG_WIDTH = TAG_WIDTH * 2 + 2
)(
    //==========================================================
    // Clock / Reset
    //==========================================================
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,

    //==========================================================
    // LFB request (only source)
    //==========================================================
    input  logic [31:0]  rb_biu_req_addr,
    output logic         vb_rb_biu_req_hit_idx,
    input  logic [26:0]  lfb_vb_addr_tto5,
    input  logic         lfb_vb_create_vld,
    input  logic [1:0]   lfb_vb_id,

    //==========================================================
    // Bus arbiter (AXI AW/W) + B resp
    //==========================================================
    input  logic         bus_arb_vb_aw_grnt,
    input  logic         bus_arb_vb_w_grnt,
    input  logic [3:0]   biu_lsu_b_id,
    input  logic         biu_lsu_b_vld,

    //==========================================================
    // dcache arbiter
    //==========================================================
    input  logic         dcache_arb_vb_ld_grnt,
    input  logic         dcache_arb_vb_st_grnt,

    //==========================================================
    // dcache data / feedback
    //==========================================================
    input  logic [255:0] ld_da_data256,
    input  logic         ld_da_vb_borrow_vb,

    input  logic         st_da_dcache_hit,
    input  logic         st_da_dcache_way,
    input  logic         st_da_dcache_replace_valid,
    input  logic         st_da_dcache_replace_dirty,
    input  logic [21:0]  st_da_vb_feedback_addr_tto10,

    //==========================================================
    // LFB interface
    //==========================================================
    output logic         vb_lfb_create_grnt,
    output logic         vb_lfb_vb_req_hit_idx,
    output logic [2:0]   vb_lfb_addr_entry_rcl_done,
    output logic [2:0]   vb_lfb_dcache_hit,
    output logic [2:0]   vb_lfb_dcache_way,
    output logic         vb_lfb_rcl_done,

    //==========================================================
    // BIU AXI AW channel
    //==========================================================
    output logic [31:0]  vb_biu_aw_addr,
    output logic [1:0]   vb_biu_aw_burst,
    output logic [3:0]   vb_biu_aw_cache,
    output logic [3:0]   vb_biu_aw_id,
    output logic [1:0]   vb_biu_aw_len,
    output logic         vb_biu_aw_lock,
    output logic [2:0]   vb_biu_aw_prot,
    output logic         vb_biu_aw_req,
    output logic [2:0]   vb_biu_aw_size,

    //==========================================================
    // BIU AXI W channel
    //==========================================================
    output logic [127:0] vb_biu_w_data,
    output logic [3:0]   vb_biu_w_id,
    output logic         vb_biu_w_last,
    output logic         vb_biu_w_req,
    output logic [15:0]  vb_biu_w_strb,
    output logic         vb_biu_w_vld,

    //==========================================================
    // dcache interface
    //==========================================================
    output logic         vb_dcache_arb_ld_borrow_req,
    output logic         vb_dcache_arb_st_borrow_req,
    output logic         vb_dcache_arb_data_way,
    output logic [31:0]  vb_dcache_arb_borrow_addr,

    output logic [LD_TAG_WIDTH-1:0]  vb_dcache_arb_ld_tag_din,
    output logic [INDEX_WIDTH-1:0]   vb_dcache_arb_ld_tag_idx,
    output logic         vb_dcache_arb_ld_tag_req,
    output logic         vb_dcache_arb_ld_tag_gateclk_en,
    output logic [1:0]   vb_dcache_arb_ld_tag_wen,

    output logic [INDEX_WIDTH-1:0]   vb_dcache_arb_st_tag_idx,
    output logic         vb_dcache_arb_st_tag_req,
    output logic         vb_dcache_arb_st_tag_gateclk_en,

    output logic         vb_dcache_arb_st_dirty_req,
    output logic         vb_dcache_arb_st_dirty_gateclk_en,
    output logic [INDEX_WIDTH-1:0]   vb_dcache_arb_st_dirty_idx,
    output logic [4:0]   vb_dcache_arb_st_dirty_din,
    output logic         vb_dcache_arb_st_dirty_gwen,
    output logic [4:0]   vb_dcache_arb_st_dirty_wen,

    output logic [7:0]   vb_dcache_arb_ld_data_gateclk_en,
    output logic [INDEX_WIDTH:0]   vb_dcache_arb_ld_data_idx
);

//==========================================================
//                 Internal registers
//==========================================================
// addr entry (merged)
logic        vb_vld;
logic [26:0] vb_addr_tto5;
logic [1:0]  vb_source_id;
logic        vb_rcl_done_reg;

// data entry (merged)
logic [255:0] vb_data;
logic         vb_data_vld;

// rcl state machine
logic [2:0]  vb_rcl_sm_next_state;
logic [2:0]  vb_rcl_sm_state;
logic        vb_rcl_sm_dcache_way;

// data writeback state machine
logic [1:0]  vb_data_next_state;
logic [1:0]  vb_data_state;

// wd (W channel) state machine
logic        vb_wd_sm_vld;
logic [1:0]  vb_wd_sm_data_bias;

//==========================================================
//                 Internal wires
//==========================================================
logic        vb_addr_create_vld;
logic        vb_biu_b_id_hit;
logic        vb_data_biu_req;
logic        vb_data_entry_pass_data_vld;
logic        vb_data_wd_sm_req;
logic        vb_lfb_create_vld;
logic        vb_pop;
logic        vb_rcl_done;
logic        vb_wd_sm_start_vld;
logic        vb_wd_sm_vld_permit;
logic [127:0] vb_wd_sm_w_req_data;
logic [2:0]  vb_source_id_expand;

logic        vb_addr_feedback_vld;
logic        rcl_cmp_tag_vld;
logic        vb_dcache_arb_write;

//==========================================================
//                 rcl state machine
//==========================================================
localparam RCL_IDLE      = 3'b000,
           RCL_R_TAG     = 3'b001,
           RCL_NOP       = 3'b010,
           RCL_CMP_TAG   = 3'b011,
           RCL_INVALID   = 3'b100,
           RCL_READ_DATA = 3'b101;

// data writeback state machine
localparam DATA_IDLE   = 2'b00,
           DATA_GET    = 2'b01,
           DATA_REQ_AW = 2'b10,
           DATA_REQ_W  = 2'b11;

//==========================================================
//                 LFB create handshake
//==========================================================
// only LFB can create a VB entry
assign vb_lfb_create_grnt = lfb_vb_create_vld && !vb_vld;
assign vb_lfb_create_vld  = vb_lfb_create_grnt && lfb_vb_create_vld;
assign vb_addr_create_vld = vb_lfb_create_vld;

// hit check: LFB's requested line is already held in the VB
assign vb_lfb_vb_req_hit_idx = vb_vld
                               && (vb_addr_tto5[INDEX_WIDTH-1:0] == lfb_vb_addr_tto5[INDEX_WIDTH-1:0]);
assign vb_rb_biu_req_hit_idx    = vb_vld
                               && (vb_addr_tto5[INDEX_WIDTH-1:0] == rb_biu_req_addr[INDEX_WIDTH+4:5]);
//==========================================================
//                 addr entry register (merged)
//==========================================================
// vld: high on LFB create, low on pop
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    vb_vld <= 1'b0;
  else if (vb_addr_create_vld)
    vb_vld <= 1'b1;
  else if (vb_pop)
    vb_vld <= 1'b0;
end

// addr + source_id
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    vb_addr_tto5[26:0]  <= 27'b0;
    vb_source_id[1:0]   <= 2'b0;
    vb_rcl_done_reg     <= 1'b0;
  end
  else if (vb_addr_create_vld)
  begin
    vb_addr_tto5[26:0]  <= lfb_vb_addr_tto5[26:0];
    vb_source_id[1:0]   <= lfb_vb_id[1:0];
    vb_rcl_done_reg     <= 1'b0;
  end
  else if (vb_rcl_done)
  begin
    vb_addr_tto5[26:0]  <= vb_addr_tto5[26:0];
    vb_source_id[1:0]   <= vb_source_id[1:0];
    vb_rcl_done_reg     <= 1'b1;
  end
  else if (vb_addr_feedback_vld)
  begin
    vb_addr_tto5[26:0]  <= {st_da_vb_feedback_addr_tto10[21:0],
                            vb_addr_tto5[4:0]};
    vb_source_id[1:0]   <= vb_source_id[1:0];
    vb_rcl_done_reg     <= 1'b1;
  end
end

//==========================================================
//                 rcl state machine
//==========================================================
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    vb_rcl_sm_state[2:0] <= RCL_IDLE;
  else
    vb_rcl_sm_state[2:0] <= vb_rcl_sm_next_state[2:0];
end

// dcache way captured at CMP_TAG
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    vb_rcl_sm_dcache_way <= 1'b0;
  else if (vb_rcl_sm_state[2:0] == RCL_CMP_TAG)
    vb_rcl_sm_dcache_way <= st_da_dcache_way;
end

always @(*)
begin
  vb_rcl_sm_next_state[2:0] = RCL_IDLE;
  case (vb_rcl_sm_state[2:0])
    RCL_IDLE:
      if (vb_vld && !vb_rcl_done_reg)
        vb_rcl_sm_next_state[2:0] = RCL_R_TAG;
      else
        vb_rcl_sm_next_state[2:0] = RCL_IDLE;

    RCL_R_TAG:
      if (dcache_arb_vb_st_grnt)
        vb_rcl_sm_next_state[2:0] = RCL_NOP;
      else
        vb_rcl_sm_next_state[2:0] = RCL_R_TAG;

    RCL_NOP:
      vb_rcl_sm_next_state[2:0] = RCL_CMP_TAG;

    RCL_CMP_TAG:
      if (st_da_dcache_hit || !st_da_dcache_replace_valid)
        vb_rcl_sm_next_state[2:0] = RCL_IDLE; // directly pull vld low
      else if (!st_da_dcache_replace_dirty)
        vb_rcl_sm_next_state[2:0] = RCL_INVALID; // valid not dirty, invalidate
      else
        vb_rcl_sm_next_state[2:0] = RCL_READ_DATA; // dirty, read data

    RCL_INVALID:
      if (dcache_arb_vb_st_grnt)
        vb_rcl_sm_next_state[2:0] = RCL_IDLE;
      else
        vb_rcl_sm_next_state[2:0] = RCL_INVALID;

    RCL_READ_DATA:
      if (dcache_arb_vb_ld_grnt)
        vb_rcl_sm_next_state[2:0] = RCL_IDLE;
      else
        vb_rcl_sm_next_state[2:0] = RCL_READ_DATA;

    default:
      vb_rcl_sm_next_state[2:0] = RCL_IDLE;
  endcase
end

// rcl done: invalidate accepted, or data handed to data entry
assign vb_rcl_done = (vb_rcl_sm_state[2:0] == RCL_INVALID && dcache_arb_vb_st_grnt)
                     || (vb_rcl_sm_state[2:0] == RCL_READ_DATA && dcache_arb_vb_ld_grnt)
                     || (vb_rcl_sm_state[2:0] == RCL_CMP_TAG
                         && (st_da_dcache_hit || !st_da_dcache_replace_valid));

// data read (borrow) done for the dirty line
assign vb_data_entry_pass_data_vld = ld_da_vb_borrow_vb;

//==========================================================
//            source id expand (lfb entry id -> one-hot)
//==========================================================
always @(*)
begin
  vb_source_id_expand[2:0] = 3'b000;
  case (vb_source_id[1:0])
    2'd0: vb_source_id_expand[0] = 1'b1;
    2'd1: vb_source_id_expand[1] = 1'b1;
    2'd2: vb_source_id_expand[2] = 1'b1;
    default: vb_source_id_expand[2:0] = 3'b000;
  endcase
end

//--------------------CMP_TAG STATE-------------------------
//-------------------feed back signal-----------------------
assign rcl_cmp_tag_vld      = (vb_rcl_sm_state[2:0] == RCL_CMP_TAG);
assign vb_addr_feedback_vld = rcl_cmp_tag_vld;

//==========================================================
//            LFB rcl result interface
//==========================================================
assign vb_lfb_addr_entry_rcl_done[2:0] = {3{vb_rcl_done}} & vb_source_id_expand[2:0];
assign vb_lfb_dcache_hit[2:0]           = {3{vb_rcl_done && st_da_dcache_hit}} & vb_source_id_expand[2:0];
assign vb_lfb_dcache_way[2:0]           = {3{vb_rcl_sm_dcache_way}} & vb_source_id_expand[2:0];
assign vb_lfb_rcl_done                  = vb_rcl_done;

//==========================================================
//            dcache interface
//==========================================================
//---------------tag array--------------
assign vb_dcache_arb_write = (vb_rcl_sm_state[2:0] == RCL_READ_DATA)
                             || (vb_rcl_sm_state[2:0] == RCL_INVALID);

assign vb_dcache_arb_ld_tag_req         = vb_dcache_arb_write;
assign vb_dcache_arb_ld_tag_gateclk_en  = vb_dcache_arb_ld_tag_req;
assign vb_dcache_arb_ld_tag_idx[INDEX_WIDTH-1:0]    = vb_addr_tto5[INDEX_WIDTH-1:0];
assign vb_dcache_arb_ld_tag_wen[1:0]    = {vb_rcl_sm_dcache_way, !vb_rcl_sm_dcache_way};
assign vb_dcache_arb_ld_tag_din[LD_TAG_WIDTH-1:0]   = {LD_TAG_WIDTH{1'b0}}; // invalidate tags

assign vb_dcache_arb_st_tag_req         = (vb_rcl_sm_state[2:0] == RCL_R_TAG);
assign vb_dcache_arb_st_tag_gateclk_en  = vb_dcache_arb_st_tag_req;
assign vb_dcache_arb_st_tag_idx[INDEX_WIDTH-1:0]    = vb_addr_tto5[INDEX_WIDTH-1:0];

//---------------dirty array------------
assign vb_dcache_arb_st_dirty_req       = (vb_rcl_sm_state[2:0] == RCL_R_TAG)
                                          || (vb_rcl_sm_state[2:0] == RCL_INVALID);
assign vb_dcache_arb_st_dirty_gateclk_en = vb_dcache_arb_st_dirty_req;
assign vb_dcache_arb_st_dirty_idx[INDEX_WIDTH-1:0]  = vb_addr_tto5[INDEX_WIDTH-1:0];
assign vb_dcache_arb_st_dirty_din[4:0]  = {vb_rcl_sm_dcache_way, 2'b0, 2'b0};
assign vb_dcache_arb_st_dirty_gwen      = vb_dcache_arb_write;
assign vb_dcache_arb_st_dirty_wen[4:0]  = vb_dcache_arb_write
                                          ? {1'b1,
                                             {2{vb_rcl_sm_dcache_way}},
                                             {2{!vb_rcl_sm_dcache_way}}}
                                          : 5'b0;

//---------------data array-------------
assign vb_dcache_arb_ld_data_gateclk_en[7:0] = {8{vb_dcache_arb_write}};
assign vb_dcache_arb_ld_data_idx[INDEX_WIDTH:0]        = {vb_addr_tto5[INDEX_WIDTH-1:0],
                                                vb_rcl_sm_dcache_way};

//-------------------------borrow signal--------------------
assign vb_dcache_arb_ld_borrow_req       = (vb_rcl_sm_state[2:0] == RCL_READ_DATA);
assign vb_dcache_arb_data_way            = vb_rcl_sm_dcache_way;
assign vb_dcache_arb_st_borrow_req       = (vb_rcl_sm_state[2:0] == RCL_R_TAG);
assign vb_dcache_arb_borrow_addr[31:0]   = {vb_addr_tto5[26:0], 5'b0};

//==========================================================
//            data entry (merged)
//==========================================================
// data register: latch victim line data on borrow grant
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    vb_data[255:0] <= 256'b0;
  else if (vb_data_entry_pass_data_vld)
    vb_data[255:0] <= ld_da_data256[255:0];
end

assign vb_data_vld = (vb_rcl_sm_state[2:0] == RCL_READ_DATA) & dcache_arb_vb_ld_grnt;

//==========================================================
//            data writeback state machine
//==========================================================
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    vb_data_state[1:0] <= DATA_IDLE;
  else
    vb_data_state[1:0] <= vb_data_next_state[1:0];
end

always @(*)
begin
  vb_data_next_state[1:0] = DATA_IDLE;
  case (vb_data_state[1:0])
    DATA_IDLE:
      if (vb_data_vld)
        vb_data_next_state[1:0] = DATA_GET;
      else
        vb_data_next_state[1:0] = DATA_IDLE;

    DATA_GET:
      if (vb_data_entry_pass_data_vld)
        vb_data_next_state[1:0] = DATA_REQ_AW;
      else
        vb_data_next_state[1:0] = DATA_GET;

    DATA_REQ_AW:
      if (bus_arb_vb_aw_grnt)
        vb_data_next_state[1:0] = DATA_REQ_W;
      else
        vb_data_next_state[1:0] = DATA_REQ_AW;

    DATA_REQ_W:
      if (vb_wd_sm_vld_permit)
        vb_data_next_state[1:0] = DATA_IDLE;
      else
        vb_data_next_state[1:0] = DATA_REQ_W;

    default:
      vb_data_next_state[1:0] = DATA_IDLE;
  endcase
end

assign vb_data_biu_req    = (vb_data_state[1:0] == DATA_REQ_AW);
assign vb_data_wd_sm_req  = (vb_data_state[1:0] == DATA_REQ_W);

//==========================================================
//            BIU AXI AW channel
//==========================================================
assign vb_biu_aw_req           = vb_data_biu_req;
assign vb_biu_aw_id[3:0]       = {BIU_VB_ID_T, 2'b00};
assign vb_biu_aw_addr[31:0]    = {vb_addr_tto5[26:0], 5'b0};
assign vb_biu_aw_len[1:0]      = 2'b01;   // 2-beat burst (32B)
assign vb_biu_aw_size[2:0]     = 3'b100;  // 16B/beat
assign vb_biu_aw_burst[1:0]    = 2'b01;   // INCR
assign vb_biu_aw_lock          = 1'b0;
assign vb_biu_aw_cache[3:0]    = 4'b0011;
assign vb_biu_aw_prot[2:0]     = 3'b000;

//==========================================================
//            write data state machine (W channel)
//==========================================================
assign vb_wd_sm_start_vld = vb_data_wd_sm_req;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    vb_wd_sm_vld <= 1'b0;
  else if (vb_wd_sm_start_vld)
    vb_wd_sm_vld <= 1'b1;
  else if (vb_wd_sm_vld_permit)
    vb_wd_sm_vld <= 1'b0;
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    vb_wd_sm_data_bias[1:0] <= 2'b01;
  else if (vb_wd_sm_start_vld)
    vb_wd_sm_data_bias[1:0] <= 2'b01;
  else if (vb_wd_sm_vld && bus_arb_vb_w_grnt)
    vb_wd_sm_data_bias[1:0] <= {vb_wd_sm_data_bias[0], 1'b0};
end

// last beat when bias = 2'b10 (writing the upper 128-bit)
assign vb_wd_sm_vld_permit = vb_wd_sm_vld
                             && vb_wd_sm_data_bias[1]
                             && bus_arb_vb_w_grnt;

assign vb_wd_sm_w_req_data[127:0]
    = {128{vb_wd_sm_data_bias[0]}} & vb_data[127:0]
    | {128{vb_wd_sm_data_bias[1]}} & vb_data[255:128];

assign vb_biu_w_req         = vb_wd_sm_vld;
assign vb_biu_w_vld         = vb_wd_sm_vld;
assign vb_biu_w_id[3:0]     = {BIU_VB_ID_T, 2'b00};
assign vb_biu_w_data[127:0] = vb_wd_sm_w_req_data[127:0];
assign vb_biu_w_strb[15:0]  = 16'hffff;
assign vb_biu_w_last        = vb_wd_sm_data_bias[1];

//==========================================================
//            B response (writeback done)
//==========================================================
assign vb_biu_b_id_hit = biu_lsu_b_vld
                         && (biu_lsu_b_id[3:2] == BIU_VB_ID_T);

//==========================================================
//            pop vld
//==========================================================
// pop when: dcache hit / way invalid (directly), invalidate accepted,
//           or dirty writeback confirmed by B resp
assign vb_pop = (vb_rcl_sm_state[2:0] == RCL_CMP_TAG
                 && (st_da_dcache_hit || !st_da_dcache_replace_valid))
                || (vb_rcl_sm_state[2:0] == RCL_INVALID && dcache_arb_vb_st_grnt)
                || vb_biu_b_id_hit;


endmodule