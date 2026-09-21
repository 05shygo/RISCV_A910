// SPDX-License-Identifier: Apache-2.0
// C910-derived ICache control boundary, spec v3.1 sections 10/11/13.
// Array datapath is derived; handshake/maintenance control is newly adapted.
// IPB and BIU remain adjacent modules. miss/refill is their demand boundary.
// A miss handshake commits one transaction; exactly 1 or 4 ordered beats follow.
// Cancellation kills delivery; maintenance also kills installation and drains.
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_icache_top #(
  parameter REGION_COUNT = 1,
  parameter [REGION_COUNT*32-1:0] REGION_BASE = 0,
  parameter [REGION_COUNT*33-1:0] REGION_LIMIT = 0,
  parameter [REGION_COUNT*5-1:0] REGION_ATTR = 0
) (
  input wire forever_cpuclk,
  input wire cpurst_b,
  input wire cp0_ifu_icg_en,
  input wire cp0_yy_clk_en,
  input wire pad_yy_icg_scan_en,
  input wire cp0_ifu_icache_en,
  input wire cp0_ifu_iwpe,
  input wire cp0_ifu_no_op_req,
  input wire hpcp_ifu_cnt_en,
  input wire cancel,
  output wire cache_init_done,
  output wire cache_no_op,
  input wire lookup_vld,
  output wire lookup_ready,
  input wire [31:0] lookup_pc,
  input wire [1:0] lookup_way_pred,
  output wire result_vld,
  input wire result_ready,
  output wire [31:0] result_pc,
  output wire [127:0] result_data,
  output wire [31:0] result_precode,
  output wire [3:0] result_slot_mask,
  output wire result_fault,
  output wire [3:0] result_cause,
  output wire result_way,
  output wire result_from_refill,
  output wire way_reissue,
  output wire refill_reissue,
  output wire ifu_hpcp_icache_access,
  output wire ifu_hpcp_icache_miss,
  // Demand request: IPB may satisfy this without issuing another BIU transaction.
  output wire miss_vld,
  input wire miss_ready,
  output wire [31:0] miss_pc,
  output wire miss_allocate,
  output wire [4:0] miss_attr,
  input wire refill_vld,
  output wire refill_ready,
  input wire [127:0] refill_data,
  input wire refill_error,
  input wire refill_last,
  output wire refill_busy,
  output wire refill_protocol_error,
  // IPB Tag-only lookup. Response must be consumed before a second lookup.
  input wire ipb_lookup_vld,
  output wire ipb_lookup_ready,
  input wire [31:0] ipb_lookup_pa,
  output wire ipb_result_vld,
  input wire ipb_result_ready,
  output wire [1:0] ipb_result_hit,
  output wire ipb_result_allowed,
  input wire ipb_idle,
  // Cache-local maintenance. Parent IFU arbitrates CP0/LSU and flushes IPB/LBUF.
  input wire maint_vld,
  output wire maint_ready,
  input wire maint_all,
  input wire [31:0] maint_pa,
  output wire maint_busy,
  output wire maint_done,
  output wire ipb_invalidate,
  // Excel v1.1 software-read ports, unchanged name/direction/width.
  input wire cp0_ifu_icache_read_req,
  output wire ifu_cp0_icache_read_ready,
  input wire [10:0] cp0_ifu_icache_read_index,
  input wire cp0_ifu_icache_read_way,
  input wire [1:0] cp0_ifu_icache_read_kind,
  output wire ifu_cp0_icache_read_data_vld,
  input wire cp0_ifu_icache_read_data_ready,
  output wire [127:0] ifu_cp0_icache_read_data
);
  //----------------------------------------------------------------------------
  // Local parameters and centralized declarations
  //----------------------------------------------------------------------------
  localparam [1:0] S_IDLE = 2'd0, S_LOOK = 2'd1, S_MISS = 2'd2, S_WAIT = 2'd3;
  localparam [2:0] M_INIT = 3'd0, M_IDLE = 3'd1, M_DRAIN = 3'd2,
                   M_ALL = 3'd3, M_READ = 3'd4, M_WRITE = 3'd5, M_DONE = 3'd6;
  reg [1:0] state_q;
  wire [1:0] state_nxt;
  wire state_en;
  reg [31:0] pc_q;
  wire [31:0] pc_nxt;
  wire pc_en;
  reg [4:0] attr_q;
  wire [4:0] attr_nxt;
  wire attr_en;
  reg allocate_q;
  wire allocate_nxt;
  wire allocate_en;
  reg [1:0] way_mask_q;
  wire [1:0] way_mask_nxt;
  wire way_mask_en;
  reg victim_q;
  wire victim_nxt;
  wire victim_en;
  reg rsp_vld_q;
  wire rsp_vld_nxt;
  wire rsp_vld_en;
  reg [31:0] rsp_pc_q;
  wire [31:0] rsp_pc_nxt;
  wire rsp_pc_en;
  reg [127:0] rsp_data_q;
  wire [127:0] rsp_data_nxt;
  wire rsp_data_en;
  reg [31:0] rsp_precode_q;
  wire [31:0] rsp_precode_nxt;
  wire rsp_precode_en;
  reg rsp_fault_q;
  wire rsp_fault_nxt;
  wire rsp_fault_en;
  reg [3:0] rsp_cause_q;
  wire [3:0] rsp_cause_nxt;
  wire rsp_cause_en;
  reg rsp_way_q;
  wire rsp_way_nxt;
  wire rsp_way_en;
  reg rsp_refill_q;
  wire rsp_refill_nxt;
  wire rsp_refill_en;
  reg trans_busy_q;
  wire trans_busy_nxt;
  wire trans_busy_en;
  reg [31:0] trans_pc_q;
  wire [31:0] trans_pc_nxt;
  wire trans_pc_en;
  reg trans_alloc_q;
  wire trans_alloc_nxt;
  wire trans_alloc_en;
  reg trans_way_q;
  wire trans_way_nxt;
  wire trans_way_en;
  reg trans_live_q;
  wire trans_live_nxt;
  wire trans_live_en;
  reg trans_killed_q;
  wire trans_killed_nxt;
  wire trans_killed_en;
  reg trans_error_q;
  wire trans_error_nxt;
  wire trans_error_en;
  reg [1:0] beat_q;
  wire [1:0] beat_nxt;
  wire beat_en;
  reg protocol_error_q;
  wire protocol_error_nxt;
  wire protocol_error_en;
  reg reissue_q;
  wire reissue_nxt;
  wire reissue_en;
  reg [2:0] maint_state_q;
  wire [2:0] maint_state_nxt;
  wire maint_state_en;
  reg [10:0] scan_q;
  wire [10:0] scan_nxt;
  wire scan_en;
  reg init_done_q;
  wire init_done_nxt;
  wire init_done_en;
  reg maint_all_q;
  wire maint_all_nxt;
  wire maint_all_en;
  reg [31:0] maint_pa_q;
  wire [31:0] maint_pa_nxt;
  wire maint_pa_en;
  reg sw_pending_q;
  wire sw_pending_nxt;
  wire sw_pending_en;
  reg sw_way_q;
  wire sw_way_nxt;
  wire sw_way_en;
  reg [1:0] sw_kind_q;
  wire [1:0] sw_kind_nxt;
  wire sw_kind_en;
  reg sw_vld_q;
  wire sw_vld_nxt;
  wire sw_vld_en;
  reg [127:0] sw_data_q;
  wire [127:0] sw_data_nxt;
  wire sw_data_en;
  reg ipb_pending_q;
  wire ipb_pending_nxt;
  wire ipb_pending_en;
  reg [31:0] ipb_pa_q;
  wire [31:0] ipb_pa_nxt;
  wire ipb_pa_en;
  reg ipb_allowed_q;
  wire ipb_allowed_nxt;
  wire ipb_allowed_en;
  reg ipb_vld_q;
  wire ipb_vld_nxt;
  wire ipb_vld_en;
  reg [1:0] ipb_hit_q;
  wire [1:0] ipb_hit_nxt;
  wire ipb_hit_en;

  wire [4:0] lookup_attr;
  wire [4:0] ipb_attr;
  wire active;
  wire kill;
  wire req_fire;
  wire lookup_array_read;
  wire [1:0] req_way_mask;
  wire slot_free;
  wire look_fault;
  wire look_hit;
  wire look_complete;
  wire replay_needed;
  wire replay_fire;
  wire miss_detect;
  wire miss_fire;
  wire [1:0] hit;
  wire selected_way;
  wire [127:0] selected_data;
  wire [31:0] selected_precode;
  wire beat_fire;
  wire beat_first;
  wire beat_end;
  wire beat_bad;
  wire forward_fire;
  wire [1:0] beat_block;
  wire array_write;
  wire install;
  wire [31:0] beat_pa;
  wire [31:0] beat_precode;
  wire maint_fire;
  wire init_last;
  wire all_last;
  wire maint_tag_req;
  wire maint_tag_write;
  wire [31:0] maint_index;
  wire [2:0] maint_wen;
  wire [1:0] maint_match;
  wire sw_fire;
  wire sw_capture;
  wire [17:0] sw_tag;
  wire [127:0] sw_data;
  wire [31:0] sw_precode;
  wire [127:0] sw_payload;
  wire ipb_fire;
  wire [1:0] ipb_hit;
  wire array_available;
  wire [31:0] array_pc;
  wire [1:0] array_way;
  wire array_read;
  wire [17:0] tag0;
  wire [17:0] tag1;
  wire fifo;
  wire [127:0] data0;
  wire [127:0] data1;
  wire [31:0] precode0;
  wire [31:0] precode1;
  wire unused_access;
  wire unused_miss;
  wire [4:0] owner_onehot;

  //----------------------------------------------------------------------------
  // Request ownership, comparison, replay and response storage
  //----------------------------------------------------------------------------
  assign active = init_done_q && (maint_state_q == M_IDLE);
  assign maint_ready = active && !cancel;
  assign maint_fire = maint_vld && maint_ready;
  assign kill = cancel || maint_fire;
  assign slot_free = !rsp_vld_q || result_ready;
  assign req_way_mask = (!cp0_ifu_iwpe || (lookup_way_pred == 2'b00)) ?
                         2'b11 : lookup_way_pred;
  assign look_fault = (state_q == S_LOOK) &&
                      ((|pc_q[1:0]) || !attr_q[4] || !attr_q[0]);
  assign hit = {tag1[17] && (tag1[16:0] == pc_q[31:15]),
                tag0[17] && (tag0[16:0] == pc_q[31:15])};
  assign selected_way = !hit[0] && hit[1];
  assign selected_data = selected_way ? data1 : data0;
  assign selected_precode = selected_way ? precode1 : precode0;
  assign look_hit = (state_q == S_LOOK) && allocate_q && (|hit) && !look_fault;
  assign replay_needed = look_hit && !(|(hit & way_mask_q));
  assign look_complete = !kill && (look_fault || (look_hit && !replay_needed));
  assign miss_detect = !kill && (state_q == S_LOOK) && !look_fault &&
                        (!allocate_q || !(|hit));
  // no_op_req stops new lookups. A lookup already accepted may finish its miss;
  // otherwise stopping between LOOK and MISS would prevent quiescence forever.
  assign miss_vld = active && !kill && (state_q == S_MISS);
  assign miss_fire = miss_vld && miss_ready;
  assign miss_pc = pc_q;
  assign miss_allocate = allocate_q;
  assign miss_attr = attr_q;
  // Hold SRAM outputs while a lookup is unresolved. Capturing a successful old
  // lookup and issuing a new SRAM read on the same edge sustains one block/cycle.
  assign array_available = active && !kill && !trans_busy_q &&
                           !sw_pending_q && !ipb_pending_q;
  assign ifu_cp0_icache_read_ready = array_available && (state_q == S_IDLE) &&
                                    !sw_vld_q;
  assign sw_fire = cp0_ifu_icache_read_req && ifu_cp0_icache_read_ready;
  assign ipb_lookup_ready = array_available && cp0_ifu_icache_en &&
                            !cp0_ifu_no_op_req && (state_q == S_IDLE) &&
                            !sw_fire && !ipb_vld_q;
  assign ipb_fire = ipb_lookup_vld && ipb_lookup_ready;
  assign replay_fire = array_available && replay_needed;
  assign lookup_ready = array_available && !cp0_ifu_no_op_req &&
                         !sw_fire && !ipb_fire && !replay_needed && slot_free &&
                         ((state_q == S_IDLE) || look_complete);
  assign req_fire = lookup_vld && lookup_ready;
  assign lookup_array_read = req_fire && cp0_ifu_icache_en && lookup_attr[3] &&
                             lookup_attr[4] && lookup_attr[0] && !(|lookup_pc[1:0]);
  assign array_read = lookup_array_read || replay_fire;
  assign array_pc = replay_fire ? pc_q : lookup_pc;
  assign array_way = replay_fire ? hit : req_way_mask;
  assign result_vld = rsp_vld_q && !kill;
  assign result_pc = rsp_pc_q;
  assign result_data = rsp_data_q;
  assign result_precode = rsp_precode_q;
  // A fault is one token at the starting instruction, not four faulty words.
  assign result_slot_mask = rsp_fault_q ? (4'b0001 << rsp_pc_q[3:2]) :
                                         (4'b1111 << rsp_pc_q[3:2]);
  assign result_fault = rsp_fault_q;
  assign result_cause = rsp_cause_q;
  assign result_way = rsp_way_q;
  assign result_from_refill = rsp_refill_q;
  assign way_reissue = replay_fire;
  assign refill_reissue = reissue_q;
  assign ifu_hpcp_icache_access = hpcp_ifu_cnt_en && lookup_array_read;
  assign ifu_hpcp_icache_miss = hpcp_ifu_cnt_en && miss_fire && allocate_q;

  //----------------------------------------------------------------------------
  // C910 first/last/FIFO write protocol, with independent live/install lifetimes
  //----------------------------------------------------------------------------
  assign refill_busy = trans_busy_q;
  assign refill_ready = trans_busy_q &&
                         (!trans_live_q || (beat_q != 2'b00) || slot_free || kill);
  assign beat_fire = refill_vld && refill_ready;
  assign beat_first = beat_q == 2'b00;
  // BIU last is checked, but never allowed to publish a short, partial line.
  assign beat_end = beat_fire && (!trans_alloc_q || (beat_q == 2'b11));
  assign beat_bad = refill_error || (refill_last != (!trans_alloc_q || (beat_q == 2'b11)));
  assign beat_block = trans_pc_q[5:4] + beat_q;
  assign beat_pa = {trans_pc_q[31:6], beat_block, 4'b0000};
  assign forward_fire = beat_fire && beat_first && trans_live_q && !kill;
  assign array_write = beat_fire && trans_alloc_q && !trans_killed_q && !maint_fire;
  assign install = beat_end && !trans_error_q && !beat_bad &&
                    !trans_killed_q && !maint_fire;
  assign refill_protocol_error = protocol_error_q;

  //----------------------------------------------------------------------------
  // Initialization, physical-line invalidation and cache-local completion
  //----------------------------------------------------------------------------
  assign init_last = (maint_state_q == M_INIT) && (&scan_q);
  assign all_last = (maint_state_q == M_ALL) && (&scan_q[8:0]);
  assign maint_busy = maint_state_q != M_IDLE;
  assign maint_done = maint_state_q == M_DONE;
  assign ipb_invalidate = maint_fire;
  assign cache_init_done = init_done_q;
  assign cache_no_op = active && (state_q == S_IDLE) && !rsp_vld_q &&
                       !trans_busy_q && !sw_pending_q && !sw_vld_q &&
                       !ipb_pending_q && !ipb_vld_q && ipb_idle;
  assign maint_match = {tag1[17] && (tag1[16:0] == maint_pa_q[31:15]),
                        tag0[17] && (tag0[16:0] == maint_pa_q[31:15])};
  assign maint_tag_req = (maint_state_q == M_INIT) || (maint_state_q == M_ALL) ||
                         (maint_state_q == M_READ) || (maint_state_q == M_WRITE);
  assign maint_tag_write = (maint_state_q == M_INIT) || (maint_state_q == M_ALL) ||
                           (maint_state_q == M_WRITE);
  assign maint_index = (maint_state_q == M_INIT) ? {17'b0, scan_q, 4'b0} :
                       (maint_state_q == M_ALL) ? {17'b0, scan_q[8:0], 6'b0} :
                       maint_pa_q;
  assign maint_wen = (maint_state_q == M_READ) ? 3'b111 :
                     (maint_state_q == M_WRITE) ? {1'b1, ~maint_match} : 3'b000;

  //----------------------------------------------------------------------------
  // Software read and IPB Tag query: synchronous capture, stable held responses
  //----------------------------------------------------------------------------
  assign sw_capture = sw_pending_q;
  assign sw_tag = sw_way_q ? tag1 : tag0;
  assign sw_data = sw_way_q ? data1 : data0;
  assign sw_precode = sw_way_q ? precode1 : precode0;
  assign sw_payload = (sw_kind_q == 2'b00) ? sw_data :
                       (sw_kind_q == 2'b01) ? {109'b0, fifo, sw_tag} :
                       (sw_kind_q == 2'b10) ? {96'b0, sw_precode} : 128'b0;
  assign ifu_cp0_icache_read_data_vld = sw_vld_q;
  assign ifu_cp0_icache_read_data = sw_data_q;
  assign ipb_hit = {tag1[17] && (tag1[16:0] == ipb_pa_q[31:15]),
                    tag0[17] && (tag0[16:0] == ipb_pa_q[31:15])};
  assign ipb_result_vld = ipb_vld_q && !kill;
  assign ipb_result_hit = ipb_hit_q;
  assign ipb_result_allowed = ipb_allowed_q;
  assign owner_onehot = {maint_tag_req, array_write, sw_fire, ipb_fire, array_read};

  rv32_ifu_region #(
    .REGION_COUNT(REGION_COUNT), .REGION_BASE(REGION_BASE),
    .REGION_LIMIT(REGION_LIMIT), .REGION_ATTR(REGION_ATTR)
  ) u_region (
    .pa(lookup_pc), .attr(lookup_attr)
  );
  rv32_ifu_region #(
    .REGION_COUNT(REGION_COUNT), .REGION_BASE(REGION_BASE),
    .REGION_LIMIT(REGION_LIMIT), .REGION_ATTR(REGION_ATTR)
  ) u_ipb_region (
    .pa(ipb_lookup_pa), .attr(ipb_attr)
  );
  rv32_ifu_icache_precode u_precode (
    .data(refill_data), .precode(beat_precode)
  );
  rv32_ifu_icache_if u_array_if (
    .forever_cpuclk(forever_cpuclk), .cpurst_b(cpurst_b),
    .cp0_ifu_icg_en(cp0_ifu_icg_en), .cp0_yy_clk_en(cp0_yy_clk_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en), .cp0_ifu_icache_en(cp0_ifu_icache_en),
    .hpcp_ifu_cnt_en(1'b0), .ifu_hpcp_icache_miss_pre(1'b0),
    .ifu_hpcp_icache_access(unused_access), .ifu_hpcp_icache_miss(unused_miss),
    .ifctrl_icache_if_index(maint_index), .ifctrl_icache_if_inv_fifo(1'b0),
    .ifctrl_icache_if_inv_on(maint_tag_write),
    .ifctrl_icache_if_tag_req(maint_tag_req), .ifctrl_icache_if_tag_wen(maint_wen),
    .ifctrl_icache_if_reset_req(maint_state_q == M_INIT),
    .ifctrl_icache_if_read_req_index({17'b0, cp0_ifu_icache_read_index, 4'b0}),
    .ifctrl_icache_if_read_req_data0(sw_fire && !cp0_ifu_icache_read_way &&
                                    (cp0_ifu_icache_read_kind != 2'b01)),
    .ifctrl_icache_if_read_req_data1(sw_fire && cp0_ifu_icache_read_way &&
                                    (cp0_ifu_icache_read_kind != 2'b01)),
    .ifctrl_icache_if_read_req_tag(sw_fire && (cp0_ifu_icache_read_kind == 2'b01)),
    .l1_refill_icache_if_fifo(trans_way_q), .l1_refill_icache_if_first(beat_first),
    .l1_refill_icache_if_index(beat_pa), .l1_refill_icache_if_inst_data(refill_data),
    .l1_refill_icache_if_last(beat_end), .l1_refill_icache_if_install(install),
    .l1_refill_icache_if_pre_code(beat_precode), .l1_refill_icache_if_ptag(trans_pc_q[31:15]),
    .l1_refill_icache_if_wr(array_write),
    .ipb_icache_if_index(ipb_lookup_pa), .ipb_icache_if_req(ipb_fire),
    .ipb_icache_if_req_for_gateclk(ipb_fire),
    .pcgen_icache_if_index(array_pc), .pcgen_icache_if_way_pred(array_way),
    .pcgen_icache_if_seq_data_req(array_read), .pcgen_icache_if_seq_tag_req(array_read),
    .pcgen_icache_if_seq_data_req_short(array_read), .pcgen_icache_if_gateclk_en(array_read),
    .pcgen_icache_if_chgflw(1'b0), .pcgen_icache_if_chgflw_short(1'b0),
    .pcgen_icache_if_chgflw_bank0(1'b0), .pcgen_icache_if_chgflw_bank1(1'b0),
    .pcgen_icache_if_chgflw_bank2(1'b0), .pcgen_icache_if_chgflw_bank3(1'b0),
    .icache_if_ifdp_fifo(fifo), .icache_if_ifdp_inst_data0(data0),
    .icache_if_ifdp_inst_data1(data1), .icache_if_ifdp_precode0(precode0),
    .icache_if_ifdp_precode1(precode1), .icache_if_ifdp_tag_data0(tag0),
    .icache_if_ifdp_tag_data1(tag1),
    .icache_if_ifctrl_inst_data0(), .icache_if_ifctrl_inst_data1(),
    .icache_if_ifctrl_tag_data0(), .icache_if_ifctrl_tag_data1(),
    .icache_if_ipb_tag_data0(), .icache_if_ipb_tag_data1()
  );

  //----------------------------------------------------------------------------
  // Register enables/next values and asynchronous-reset storage
  //----------------------------------------------------------------------------
  assign state_en = 1'b1;
  assign state_nxt = kill ? S_IDLE : req_fire ? S_LOOK :
    (state_q == S_LOOK) ? (look_complete && slot_free ? S_IDLE :
                           miss_detect ? S_MISS : S_LOOK) :
    miss_fire ? S_WAIT : forward_fire ? S_IDLE : state_q;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_state
    if (!cpurst_b) begin
      state_q <= S_IDLE;
    end else if (state_en) begin
      state_q <= state_nxt;
    end
  end
  assign pc_en = req_fire;
  assign pc_nxt = lookup_pc;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_pc
    if (!cpurst_b) begin
      pc_q <= 32'b0;
    end else if (pc_en) begin
      pc_q <= pc_nxt;
    end
  end
  assign attr_en = req_fire;
  assign attr_nxt = lookup_attr;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_attr
    if (!cpurst_b) begin
      attr_q <= 5'b0;
    end else if (attr_en) begin
      attr_q <= attr_nxt;
    end
  end
  assign allocate_en = req_fire;
  assign allocate_nxt = cp0_ifu_icache_en && lookup_attr[3];
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_allocate
    if (!cpurst_b) begin
      allocate_q <= 1'b0;
    end else if (allocate_en) begin
      allocate_q <= allocate_nxt;
    end
  end
  assign way_mask_en = req_fire || replay_fire;
  assign way_mask_nxt = req_fire ? req_way_mask : hit;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_way_mask
    if (!cpurst_b) begin
      way_mask_q <= 2'b0;
    end else if (way_mask_en) begin
      way_mask_q <= way_mask_nxt;
    end
  end
  assign victim_en = miss_detect;
  assign victim_nxt = allocate_q ? fifo : 1'b0;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_victim
    if (!cpurst_b) begin
      victim_q <= 1'b0;
    end else if (victim_en) begin
      victim_q <= victim_nxt;
    end
  end
  assign rsp_vld_en = 1'b1;
  assign rsp_vld_nxt = kill ? 1'b0 :
    (forward_fire || (look_complete && slot_free)) ? 1'b1 :
    result_ready ? 1'b0 : rsp_vld_q;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rsp_vld
    if (!cpurst_b) begin
      rsp_vld_q <= 1'b0;
    end else if (rsp_vld_en) begin
      rsp_vld_q <= rsp_vld_nxt;
    end
  end
  assign rsp_pc_en = !kill && (forward_fire || (look_complete && slot_free));
  assign rsp_pc_nxt = forward_fire ? trans_pc_q : pc_q;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rsp_pc
    if (!cpurst_b) begin
      rsp_pc_q <= 32'b0;
    end else if (rsp_pc_en) begin
      rsp_pc_q <= rsp_pc_nxt;
    end
  end
  assign rsp_data_en = !kill && (forward_fire || (look_complete && slot_free));
  assign rsp_data_nxt = forward_fire ? (beat_bad ? 128'b0 : refill_data) :
    look_fault ? 128'b0 : selected_data;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rsp_data
    if (!cpurst_b) begin
      rsp_data_q <= 128'b0;
    end else if (rsp_data_en) begin
      rsp_data_q <= rsp_data_nxt;
    end
  end
  assign rsp_precode_en = !kill && (forward_fire || (look_complete && slot_free));
  assign rsp_precode_nxt = forward_fire ? (beat_bad ? 32'b0 : beat_precode) :
    look_fault ? 32'b0 : selected_precode;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rsp_precode
    if (!cpurst_b) begin
      rsp_precode_q <= 32'b0;
    end else if (rsp_precode_en) begin
      rsp_precode_q <= rsp_precode_nxt;
    end
  end
  assign rsp_fault_en = !kill && (forward_fire || (look_complete && slot_free));
  assign rsp_fault_nxt = forward_fire ? beat_bad : look_fault;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rsp_fault
    if (!cpurst_b) begin
      rsp_fault_q <= 1'b0;
    end else if (rsp_fault_en) begin
      rsp_fault_q <= rsp_fault_nxt;
    end
  end
  assign rsp_cause_en = !kill && (forward_fire || (look_complete && slot_free));
  assign rsp_cause_nxt = forward_fire ? (beat_bad ? 4'd1 : 4'd0) :
    (|pc_q[1:0]) ? 4'd0 : look_fault ? 4'd1 : 4'd0;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rsp_cause
    if (!cpurst_b) begin
      rsp_cause_q <= 4'b0;
    end else if (rsp_cause_en) begin
      rsp_cause_q <= rsp_cause_nxt;
    end
  end
  assign rsp_way_en = !kill && (forward_fire || (look_complete && slot_free));
  assign rsp_way_nxt = forward_fire ? trans_way_q : look_fault ? 1'b0 : selected_way;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rsp_way
    if (!cpurst_b) begin
      rsp_way_q <= 1'b0;
    end else if (rsp_way_en) begin
      rsp_way_q <= rsp_way_nxt;
    end
  end
  assign rsp_refill_en = !kill && (forward_fire || (look_complete && slot_free));
  assign rsp_refill_nxt = forward_fire;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rsp_refill
    if (!cpurst_b) begin
      rsp_refill_q <= 1'b0;
    end else if (rsp_refill_en) begin
      rsp_refill_q <= rsp_refill_nxt;
    end
  end
  assign trans_busy_en = miss_fire || beat_end;
  assign trans_busy_nxt = miss_fire;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_trans_busy
    if (!cpurst_b) begin
      trans_busy_q <= 1'b0;
    end else if (trans_busy_en) begin
      trans_busy_q <= trans_busy_nxt;
    end
  end
  assign trans_pc_en = miss_fire;
  assign trans_pc_nxt = pc_q;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_trans_pc
    if (!cpurst_b) begin
      trans_pc_q <= 32'b0;
    end else if (trans_pc_en) begin
      trans_pc_q <= trans_pc_nxt;
    end
  end
  assign trans_alloc_en = miss_fire;
  assign trans_alloc_nxt = allocate_q;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_trans_alloc
    if (!cpurst_b) begin
      trans_alloc_q <= 1'b0;
    end else if (trans_alloc_en) begin
      trans_alloc_q <= trans_alloc_nxt;
    end
  end
  assign trans_way_en = miss_fire;
  assign trans_way_nxt = victim_q;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_trans_way
    if (!cpurst_b) begin
      trans_way_q <= 1'b0;
    end else if (trans_way_en) begin
      trans_way_q <= trans_way_nxt;
    end
  end
  assign trans_live_en = kill || miss_fire || forward_fire || beat_end;
  assign trans_live_nxt = !kill && miss_fire;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_trans_live
    if (!cpurst_b) begin
      trans_live_q <= 1'b0;
    end else if (trans_live_en) begin
      trans_live_q <= trans_live_nxt;
    end
  end
  assign trans_killed_en = maint_fire || miss_fire;
  assign trans_killed_nxt = maint_fire;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_trans_killed
    if (!cpurst_b) begin
      trans_killed_q <= 1'b0;
    end else if (trans_killed_en) begin
      trans_killed_q <= trans_killed_nxt;
    end
  end
  assign trans_error_en = miss_fire || beat_fire;
  assign trans_error_nxt = miss_fire ? 1'b0 : (trans_error_q || beat_bad);
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_trans_error
    if (!cpurst_b) begin
      trans_error_q <= 1'b0;
    end else if (trans_error_en) begin
      trans_error_q <= trans_error_nxt;
    end
  end
  assign beat_en = miss_fire || beat_fire;
  assign beat_nxt = miss_fire ? 2'b0 : beat_q + 2'd1;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_beat
    if (!cpurst_b) begin
      beat_q <= 2'b0;
    end else if (beat_en) begin
      beat_q <= beat_nxt;
    end
  end
  assign protocol_error_en = beat_fire;
  assign protocol_error_nxt = protocol_error_q || (refill_last != beat_end);
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_protocol_error
    if (!cpurst_b) begin
      protocol_error_q <= 1'b0;
    end else if (protocol_error_en) begin
      protocol_error_q <= protocol_error_nxt;
    end
  end
  assign reissue_en = 1'b1;
  assign reissue_nxt = beat_end;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_reissue
    if (!cpurst_b) begin
      reissue_q <= 1'b0;
    end else if (reissue_en) begin
      reissue_q <= reissue_nxt;
    end
  end
  assign maint_state_en = 1'b1;
  assign maint_state_nxt = (maint_state_q == M_INIT) ? (init_last ? M_IDLE : M_INIT) :
    (maint_state_q == M_IDLE) ? (maint_fire ? M_DRAIN : M_IDLE) :
    (maint_state_q == M_DRAIN) ?
      ((!trans_busy_q && ipb_idle && !sw_pending_q && !sw_vld_q &&
        !ipb_pending_q && !ipb_vld_q) ? (maint_all_q ? M_ALL : M_READ) : M_DRAIN) :
    (maint_state_q == M_ALL) ? (all_last ? M_DONE : M_ALL) :
    (maint_state_q == M_READ) ? M_WRITE :
    (maint_state_q == M_WRITE) ? M_DONE : M_IDLE;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_maint_state
    if (!cpurst_b) begin
      maint_state_q <= M_INIT;
    end else if (maint_state_en) begin
      maint_state_q <= maint_state_nxt;
    end
  end
  assign scan_en = (maint_state_q == M_INIT) || (maint_state_q == M_ALL) || maint_fire;
  assign scan_nxt = maint_fire ? 11'b0 : scan_q + 11'd1;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_scan
    if (!cpurst_b) begin
      scan_q <= 11'b0;
    end else if (scan_en) begin
      scan_q <= scan_nxt;
    end
  end
  assign init_done_en = init_last;
  assign init_done_nxt = 1'b1;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_init_done
    if (!cpurst_b) begin
      init_done_q <= 1'b0;
    end else if (init_done_en) begin
      init_done_q <= init_done_nxt;
    end
  end
  assign maint_all_en = maint_fire;
  assign maint_all_nxt = maint_all;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_maint_all
    if (!cpurst_b) begin
      maint_all_q <= 1'b0;
    end else if (maint_all_en) begin
      maint_all_q <= maint_all_nxt;
    end
  end
  assign maint_pa_en = maint_fire;
  assign maint_pa_nxt = maint_pa;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_maint_pa
    if (!cpurst_b) begin
      maint_pa_q <= 32'b0;
    end else if (maint_pa_en) begin
      maint_pa_q <= maint_pa_nxt;
    end
  end
  assign sw_pending_en = 1'b1;
  assign sw_pending_nxt = sw_fire;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sw_pending
    if (!cpurst_b) begin
      sw_pending_q <= 1'b0;
    end else if (sw_pending_en) begin
      sw_pending_q <= sw_pending_nxt;
    end
  end
  assign sw_way_en = sw_fire;
  assign sw_way_nxt = cp0_ifu_icache_read_way;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sw_way
    if (!cpurst_b) begin
      sw_way_q <= 1'b0;
    end else if (sw_way_en) begin
      sw_way_q <= sw_way_nxt;
    end
  end
  assign sw_kind_en = sw_fire;
  assign sw_kind_nxt = cp0_ifu_icache_read_kind;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sw_kind
    if (!cpurst_b) begin
      sw_kind_q <= 2'b0;
    end else if (sw_kind_en) begin
      sw_kind_q <= sw_kind_nxt;
    end
  end
  assign sw_vld_en = 1'b1;
  assign sw_vld_nxt = sw_capture ? 1'b1 : cp0_ifu_icache_read_data_ready ? 1'b0 : sw_vld_q;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sw_vld
    if (!cpurst_b) begin
      sw_vld_q <= 1'b0;
    end else if (sw_vld_en) begin
      sw_vld_q <= sw_vld_nxt;
    end
  end
  assign sw_data_en = sw_capture;
  assign sw_data_nxt = sw_payload;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sw_data
    if (!cpurst_b) begin
      sw_data_q <= 128'b0;
    end else if (sw_data_en) begin
      sw_data_q <= sw_data_nxt;
    end
  end
  assign ipb_pending_en = 1'b1;
  assign ipb_pending_nxt = kill ? 1'b0 : ipb_fire;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_ipb_pending
    if (!cpurst_b) begin
      ipb_pending_q <= 1'b0;
    end else if (ipb_pending_en) begin
      ipb_pending_q <= ipb_pending_nxt;
    end
  end
  assign ipb_pa_en = ipb_fire;
  assign ipb_pa_nxt = ipb_lookup_pa;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_ipb_pa
    if (!cpurst_b) begin
      ipb_pa_q <= 32'b0;
    end else if (ipb_pa_en) begin
      ipb_pa_q <= ipb_pa_nxt;
    end
  end
  assign ipb_allowed_en = ipb_fire;
  assign ipb_allowed_nxt = ipb_attr[4] && ipb_attr[3] && ipb_attr[0];
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_ipb_allowed
    if (!cpurst_b) begin
      ipb_allowed_q <= 1'b0;
    end else if (ipb_allowed_en) begin
      ipb_allowed_q <= ipb_allowed_nxt;
    end
  end
  assign ipb_vld_en = 1'b1;
  assign ipb_vld_nxt = kill ? 1'b0 : ipb_pending_q ? 1'b1 : ipb_result_ready ? 1'b0 : ipb_vld_q;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_ipb_vld
    if (!cpurst_b) begin
      ipb_vld_q <= 1'b0;
    end else if (ipb_vld_en) begin
      ipb_vld_q <= ipb_vld_nxt;
    end
  end
  assign ipb_hit_en = ipb_pending_q;
  assign ipb_hit_nxt = ipb_hit;
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_ipb_hit
    if (!cpurst_b) begin
      ipb_hit_q <= 2'b0;
    end else if (ipb_hit_en) begin
      ipb_hit_q <= ipb_hit_nxt;
    end
  end
endmodule
