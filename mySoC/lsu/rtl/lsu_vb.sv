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
    input  logic [31:0]  wmb_biu_aw_addr,
    output logic         vb_wmb_hit_idx,

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
    input  logic         st_da_dcache_replace_way,
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
   // output logic         vb_biu_aw_lock,
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
    // ⚠️ 2026-10-15 新增: 给 dcache 仲裁器的 **st 请求** (≠ borrow)。
    //   原版 ct_lsu_vb.v 里这是两根**不同**的信号:
    //     vb_dcache_arb_st_req        (寄存器, `vb_dcache_arb_st_req_set` 于
    //                                  RCL_R_TAG_DIRTY/READ_DATA1/RCL_INVALID 置起)
    //     vb_dcache_arb_st_borrow_req (组合, 只在 RCL_R_TAG_DIRTY)
    //   本仓把仲裁器那一根错接成了 borrow 那根 (见 lsu_top.sv) ⇒ RCL_INVALID 状态
    //   一个请求都不发, 却在那儿等 `dcache_arb_vb_st_grnt` ⇒ 死锁。详见下面的 assign。
    output logic         vb_dcache_arb_st_req,
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
assign vb_wmb_hit_idx  = vb_vld
                               && (vb_addr_tto5[INDEX_WIDTH-1:0] == wmb_biu_aw_addr[INDEX_WIDTH+4:5]);

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
// 本仓 VB 只有一个 create 源 (LFB linefill), 所以这里要取**被替换的那一路**
// (st_da_dcache_replace_way = dirty_array[4], miss 时报文路的 LRU 指针),
// 而不是 `st_da_dcache_way` (= st_da_hit_way1, miss 时恒 0)。
// 原版 ct_lsu_vb.v:1242 `vb_rcl_sm_reg_set_dcache_way = vb_rcl_sm_lfb_create
// ? st_da_dcache_replace_way : st_da_dcache_way;` —— 本仓把那个 mux 丢了。
// 取错的后果: LFB 回填永远写 way0, 而 VB 判定的牺牲者是 way1 (恒 invalid) ⇒
// VB 直接 RCL_IDLE "不用换出" ⇒ 回填把 way0 里 valid+dirty 的行**无声覆盖掉**
// (dirty 数据永不写回内存, vb_biu_aw_req 全程 0)。
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    vb_rcl_sm_dcache_way <= 1'b0;
  else if (vb_rcl_sm_state[2:0] == RCL_CMP_TAG)
    vb_rcl_sm_dcache_way <= st_da_dcache_replace_way;
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
// ⚠️ `vb_rcl_done` 在 RCL_CMP_TAG 那一拍就拉高 (hit/无需换出时直接结束), 而
//    `vb_rcl_sm_dcache_way` 要**下一拍**才寄存进去 ⇒ 直接用它, LFB 抓到的永远是
//    上一次 VB 残留的 way。原版 ct_lsu_vb.v:1200 是
//      vb_lfb_dcache_way = vb_rcl_sm_sel_dcache_reg_info ? vb_rcl_sm_dcache_way
//                                                        : vb_rcl_sm_reg_set_dcache_way;
//    (sel = state[2], 即 CMP_TAG 之后的那两个态)。CMP_TAG 当期必须给组合值。
assign vb_lfb_dcache_way[2:0]           = {3{ vb_rcl_sm_state[2] ? vb_rcl_sm_dcache_way
                                                                    : st_da_dcache_replace_way }}
                                          & vb_source_id_expand[2:0];
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
// ⚠️⚠️ 2026-10-15 修 (coremark_i1 卡死真凶): 仲裁器的 st 请求必须**连 RCL_INVALID
//   一起拉高**。原版 (ct_lsu_vb.v:1284-1288)
//      vb_dcache_arb_st_req_set = (next == RCL_R_TAG_DIRTY) || (next == RCL_READ_DATA1)
//                                 || (next == RCL_INVALID);
//   本仓只拉 RCL_R_TAG ⇒ **RCL_INVALID 状态下 `dcache_arb_st_req[2]`=0 ⇒ VB 永远
//   选不中 ⇒ `dcache_arb_vb_st_grnt` 恒 0**。而 RCL_INVALID 的出口条件恰恰就是它:
//      RCL_INVALID: if (dcache_arb_vb_st_grnt) -> RCL_IDLE; else 自环;
//   ⇒ VB 在 RCL_INVALID 里**永久自环**, 牺牲行的 valid/dirty 位永远清不掉 ⇒
//   `vb_rcl_done` 不拉 ⇒ LFB 表项永远等不到 "rcl done" ⇒ 该表项不回填 ⇒ 等它的
//   load 永远不 wakeup ⇒ ROB 队头永不完成 ⇒ 它后面那条**已误预测的分支永远提交不了**
//   ⇒ 没有冲刷脉冲 ⇒ A910_cpu.sv 的 `mispred_hold_q` 闸门永远不开 ⇒ IDU 永久冻结。
//   实测 (coremark_i1): 首次走到这条路的 T68341 起 VB 停在 state=4(RCL_INVALID),
//   dcache_arb_st_req 全 0, 整机在 T68357 之后一条指令都不退休 (卡死在 0xeec 循环)。
//   (borrow 那根保持只 RCL_R_TAG: 它给的是 borrow 地址, 只有读 tag 定牺牲路时才要。)
assign vb_dcache_arb_st_req             = (vb_rcl_sm_state[2:0] == RCL_R_TAG)
                                          || (vb_rcl_sm_state[2:0] == RCL_INVALID);
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
//assign vb_biu_aw_lock          = 1'b0;
assign vb_biu_aw_cache[3:0]    = 4'b0011;
assign vb_biu_aw_prot[2:0]     = 3'b000;

//==========================================================
//            write data state machine (W channel)
//==========================================================
// ⚠️⚠️ 2026-10-15 修 (coremark_i1 卡死真凶): start 必须门控"本 SM 还没在跑"。
//   原版 (ct_lsu_vb.v:1560-1561)
//      vb_wd_sm_permit    = !vb_wd_sm_vld || vb_wd_sm_vld_permit;
//      vb_wd_sm_start_vld = vb_data_wd_sm_req && vb_wd_sm_permit;
//   原版的 `vb_data_wd_sm_req` 是**表项来的脉冲** (表项被 vm_wd_sm_grnt 消费掉就自己撤),
//   所以它只在"新一笔要写"的那一拍为 1。本仓把它简化成
//      vb_data_wd_sm_req = (vb_data_state == DATA_REQ_W)
//   —— 这是**电平**, 整个 W burst 期间一直是 1。于是 `start_vld` 也整段为 1,
//   而两个 always 块里 `start_vld` 的优先级都高于"推进/撤销":
//      vld  : start_vld -> 1  (永远压过 vld_permit -> 0)
//      bias : start_vld -> 2'b01 (永远压过 {bias[0],1'b0} 左移)
//   ⇒ bias 卡在 2'b01 ⇒ `vb_biu_w_last = bias[1]` **恒 0** ⇒ W 通道只会发出一串
//   "最后一拍"标志永远不置位的 beat。
//   实测 (coremark_i1): T68345 牺牲行 0x3700 的 AW 成交后, T68347/T68348 两拍
//   W **last 都是 0**, 从机按 wr_cnt==wr_len 收满 2 拍就自己收尾 (aw_done=0/bvalid_r
//   过了), 而 BIU 写通道 `w_done` 靠 `wlast` 才置位 ⇒ 永远置不上 ⇒ FSM 永远停在
//   WR_ACTIVE/sel=0/aw_done=1/w_done=0, 且 VB 的 W SM 卡在 beat0 (bias=01) 一直重发
//   ⇒ AXI 写通道死锁, WMB 的 store AW 被这笔"占着通道"的 victim 事务挡死。
//   本仓只有一个 vb_data 寄存器 (不可能像原版那样背靠背串新表项), 所以正确门控就是
//   "SM 没在跑" —— 等价于 `vb_data_wd_sm_req && vb_wd_sm_permit` 在这个结构下的写法。
//   (末拍那拍 vld_permit=1 会让 permit=1, 但 `!vld` 已为 0 ⇒ start 仍为 0, 不会重启。)
assign vb_wd_sm_start_vld = vb_data_wd_sm_req && !vb_wd_sm_vld;

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