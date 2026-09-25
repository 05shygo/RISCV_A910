/*Copyright 2019-2021 T-Head Semiconductor Co., Ltd.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// RV32I/no-MMU adaptation of ct_ifu_pcgen.v. All PCs are physical byte addresses.
// See doc/pcgen_zh.md for accepted-event, fast-address and reissue contracts.
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
// [ICACHE 参数化] 只用行大小(判断"顺序取指何时换 set"); 默认 = 原 64 B 行。
`ifdef ICACHE_BYTES
  `define IC_BYTES_VAL `ICACHE_BYTES
`else
  `define IC_BYTES_VAL 65536
`endif
`ifdef ICACHE_LINE_BYTES
  `define IC_LINE_VAL `ICACHE_LINE_BYTES
`else
  `define IC_LINE_VAL 64
`endif

module rv32_ifu_pcgen (
  input wire forever_cpuclk,
  input wire cpurst_b,
  input wire cp0_yy_clk_en,
  input wire cp0_ifu_iwpe,

  // Debug controller supplies the accepted command, NOT raw HAD valid.
  input wire        debug_pcgen_pcload,
  input wire [31:0] debug_pcgen_pc,
  input wire        rtu_ifu_dbgon,
  input wire        vector_pcgen_pcload,
  input wire [31:0] vector_pcgen_pc,
  input wire        vector_pcgen_reset_on,
  input wire        rtu_ifu_chgflw_vld,
  input wire [31:0] rtu_ifu_chgflw_pc,
  input wire        rtu_ifu_flush,
  input wire        iu_ifu_chgflw_vld,
  input wire [31:0] iu_ifu_chgflw_pc,

  input wire        addrgen_pcgen_pcload,
  input wire [31:0] addrgen_pcgen_pc,
  input wire        ibctrl_pcgen_pcload,
  input wire        ibctrl_pcgen_pcload_vld,
  input wire [31:0] ibctrl_pcgen_pc,
  input wire [ 1:0] ibctrl_pcgen_way_pred,
  input wire        ibctrl_pcgen_ip_stall,
  input wire        ipctrl_pcgen_reissue_pcload,
  input wire [31:0] ipctrl_pcgen_reissue_pc,
  input wire [ 1:0] ipctrl_pcgen_reissue_way_pred,
  input wire        ipctrl_pcgen_chgflw_pcload,
  input wire [31:0] ipctrl_pcgen_chgflw_pc,
  input wire [ 1:0] ipctrl_pcgen_chgflw_way_pred,
  input wire        ipctrl_pcgen_branch_taken,
  input wire        ipctrl_pcgen_branch_mistaken,
  input wire [31:0] ipctrl_pcgen_taken_pc,
  input wire        ipctrl_pcgen_chk_err_reissue,
  input wire        ipctrl_pcgen_if_stall,
  input wire        ipctrl_pcgen_inner_way0,
  input wire        ipctrl_pcgen_inner_way1,
  input wire [ 1:0] ipctrl_pcgen_inner_way_pred,
  input wire        ifctrl_pcgen_chgflw_vld,
  input wire        ifctrl_pcgen_chgflw_no_stall_mask,
  input wire [31:0] ifctrl_pcgen_pcload_pc,
  input wire [ 1:0] ifctrl_pcgen_way_pred,
  input wire        ifctrl_pcgen_reissue_pcload,
  input wire        ifctrl_pcgen_stall,
  input wire        ifctrl_pcgen_stall_short,
  input wire        ifctrl_pcgen_ins_icache_inv_done,
  input wire        lbuf_pcgen_active,
  input wire        lbuf_pcgen_vld_mask,

  output wire [31:0] pcgen_ifctrl_pc,
  output wire [31:0] pcgen_ifdp_pc,
  output wire [31:0] pcgen_ifdp_inc_pc,
  output wire [ 1:0] pcgen_ifctrl_way_pred,
  output wire [ 1:0] pcgen_ifdp_way_pred,
  output wire        pcgen_ifctrl_way_pred_stall,
  output wire        pcgen_ifctrl_reissue,
  output wire        pcgen_ifctrl_cancel,
  output wire        pcgen_ifctrl_pipe_cancel,
  output wire        pcgen_ipctrl_cancel,
  output wire        pcgen_ipctrl_pipe_cancel,
  output wire        pcgen_ibctrl_cancel,
  output wire        pcgen_ibctrl_ibuf_flush,
  output wire        pcgen_ibctrl_lbuf_flush,
  output wire        pcgen_ibctrl_bju_chgflw,
  output wire        pcgen_addrgen_cancel,
  output wire        pcgen_l1_refill_chgflw,
  output wire        pcgen_ipb_chgflw,

  output wire [31:0] pcgen_icache_if_index,
  output wire [ 1:0] pcgen_icache_if_way_pred,
  output wire        pcgen_icache_if_chgflw,
  output wire        pcgen_icache_if_chgflw_short,
  output wire        pcgen_icache_if_chgflw_bank0,
  output wire        pcgen_icache_if_chgflw_bank1,
  output wire        pcgen_icache_if_chgflw_bank2,
  output wire        pcgen_icache_if_chgflw_bank3,
  output wire        pcgen_icache_if_seq_data_req,
  output wire        pcgen_icache_if_seq_data_req_short,
  output wire        pcgen_icache_if_seq_tag_req,
  output wire        pcgen_icache_if_gateclk_en,

  output wire        pcgen_bht_chgflw,
  output wire        pcgen_bht_chgflw_short,
  output wire [ 6:0] pcgen_bht_ifpc,
  output wire [ 9:0] pcgen_bht_pcindex,
  output wire        pcgen_bht_seq_read,
  output wire        pcgen_btb_chgflw,
  output wire        pcgen_btb_chgflw_short,
  output wire        pcgen_btb_chgflw_higher_than_addrgen,
  output wire        pcgen_btb_chgflw_higher_than_ip,
  output wire        pcgen_btb_chgflw_higher_than_if,
  output wire [ 9:0] pcgen_btb_index,
  output wire        pcgen_btb_stall,
  output wire        pcgen_btb_stall_short,
  output wire        pcgen_l0_btb_chgflw_mask,
  output wire        pcgen_l0_btb_chgflw_vld,
  output wire [31:0] pcgen_l0_btb_chgflw_pc,
  output wire [31:0] pcgen_l0_btb_if_pc,
  output wire [16:0] pcgen_sfp_pc,
  output wire        pcgen_debug_chgflw,
  output wire [31:0] pcgen_debug_pcbus,
  output wire [31:0] ifu_had_fetch_pc
);

  //----------------------------------------------------------------------------
  // Local parameters and net declarations
  //----------------------------------------------------------------------------
  localparam IC_BYTES  = `IC_BYTES_VAL;
  localparam IC_LINE   = `IC_LINE_VAL;
  localparam IC_SETS   = IC_BYTES/(2*IC_LINE);
  localparam LINE_BITS = $clog2(IC_LINE);
  localparam SOURCE_COUNT = 10;
  localparam MUX_COUNT = 2;
  localparam PAYLOAD_WIDTH = 34;
  localparam BANK_COUNT = 4;
  localparam FLAG_COUNT = 4;
  localparam WAY_STATE_COUNT = 2;

  genvar mux_index;
  genvar source_index;
  genvar bit_index;
  genvar bank;
  genvar flag_index;
  genvar way_index;

  wire [   SOURCE_COUNT-1:0] source_req          [      0:MUX_COUNT-1];
  wire [   SOURCE_COUNT-1:0] source_sel          [      0:MUX_COUNT-1];
  wire [  PAYLOAD_WIDTH-1:0] source_payload      [   0:SOURCE_COUNT-1];
  wire [  PAYLOAD_WIDTH-1:0] selected_payload    [      0:MUX_COUNT-1];
  wire [               31:0] pc_bus;
  wire [               31:0] inc_pc;
  reg  [               31:0] if_pc_q;
  wire [               31:0] if_pc_nxt;
  wire                       if_pc_en;
  reg  [     FLAG_COUNT-1:0] flag_q;
  wire [     FLAG_COUNT-1:0] flag_nxt;
  wire [     FLAG_COUNT-1:0] flag_en;
  reg  [                1:0] way_q               [0:WAY_STATE_COUNT-1];
  wire [                1:0] way_nxt             [0:WAY_STATE_COUNT-1];
  wire [WAY_STATE_COUNT-1:0] way_en;
  wire [                1:0] chgflw_way;
  wire [                1:0] way_predict;
  wire [                1:0] inner_way;
  wire [                1:0] inner_way_default;
  wire [     BANK_COUNT-1:0] bank_chgflw;
  wire                       fetch_enable;
  wire                       seq_advance;
  wire                       debug_load;
  wire                       debug_cancel;
  wire                       global_cancel;
  wire                       higher_than_addrgen;
  wire                       higher_than_ib;
  wire                       higher_than_ip;
  wire                       chgflw;
  wire                       chgflw_without_l0;
  wire                       chgflw_short;
  wire                       trim_bank;

  //----------------------------------------------------------------------------
  // PC arbitration. Source zero has highest priority; mux 1 is the fast path.
  //----------------------------------------------------------------------------
  assign debug_load = debug_pcgen_pcload && rtu_ifu_dbgon;
  assign source_req[0] = {
    ifctrl_pcgen_reissue_pcload,
    ifctrl_pcgen_chgflw_vld,
    ipctrl_pcgen_chgflw_pcload,
    ipctrl_pcgen_reissue_pcload,
    ibctrl_pcgen_pcload,
    addrgen_pcgen_pcload,
    iu_ifu_chgflw_vld,
    rtu_ifu_chgflw_vld,
    vector_pcgen_pcload,
    debug_load
  };
  // Debug/vector/RTU use the final PC register plus IF reissue. The early
  // L0 hint may steer SRAM addresses but is not a functional redirect event.
  assign source_req[1] = {1'b0, ifctrl_pcgen_chgflw_no_stall_mask, source_req[0][7:3], 3'b000};
  assign source_payload[0] = {2'b11, debug_pcgen_pc};
  assign source_payload[1] = {2'b11, vector_pcgen_pc};
  assign source_payload[2] = {2'b11, rtu_ifu_chgflw_pc};
  assign source_payload[3] = {2'b11, iu_ifu_chgflw_pc};
  assign source_payload[4] = {2'b11, addrgen_pcgen_pc};
  assign source_payload[5] = {ibctrl_pcgen_way_pred, ibctrl_pcgen_pc};
  assign source_payload[6] = {ipctrl_pcgen_reissue_way_pred, ipctrl_pcgen_reissue_pc};
  assign source_payload[7] = {ipctrl_pcgen_chgflw_way_pred, ipctrl_pcgen_chgflw_pc};
  assign source_payload[8] = {ifctrl_pcgen_way_pred, ifctrl_pcgen_pcload_pc};
  assign source_payload[9] = {ifctrl_pcgen_way_pred, if_pc_q};

  generate
    for (mux_index = 0; mux_index < MUX_COUNT; mux_index = mux_index + 1) begin : g_mux
      for (
        source_index = 0; source_index < SOURCE_COUNT; source_index = source_index + 1
      ) begin : g_source
        if (source_index == 0) begin : g_first
          assign source_sel[mux_index][source_index] = source_req[mux_index][source_index];
        end else begin : g_later
          assign source_sel[mux_index][source_index] = source_req[mux_index][source_index] &&
            !(|source_req[mux_index][source_index-1:0]);
        end
      end
      for (bit_index = 0; bit_index < PAYLOAD_WIDTH; bit_index = bit_index + 1) begin : g_bit
        wire [SOURCE_COUNT-1:0] terms;
        for (
          source_index = 0; source_index < SOURCE_COUNT; source_index = source_index + 1
        ) begin : g_term
          assign terms[source_index] = source_sel[mux_index][source_index] &
            source_payload[source_index][bit_index];
        end
        assign selected_payload[mux_index][bit_index] = |terms;
      end
    end
  endgenerate

  assign inc_pc            = ifctrl_pcgen_reissue_pcload ? if_pc_q : {if_pc_q[31:4] + 28'd1, 4'b0};
  assign pc_bus            = (|source_req[1]) ? selected_payload[1][31:0] : inc_pc;
  assign chgflw            = |source_req[0];
  assign chgflw_without_l0 = (|source_req[0][7:0]) || source_req[0][9];
  assign chgflw_short      = chgflw_without_l0 || ifctrl_pcgen_chgflw_no_stall_mask;
  assign fetch_enable      = cpurst_b && cp0_yy_clk_en && !vector_pcgen_reset_on;
  assign seq_advance       = fetch_enable && !ifctrl_pcgen_stall;
  assign if_pc_en          = chgflw || seq_advance;
  assign if_pc_nxt         = chgflw ? selected_payload[0][31:0] : inc_pc;

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_if_pc
    if (!cpurst_b) begin
      if_pc_q <= 32'b0;
    end else if (if_pc_en) begin
      if_pc_q <= if_pc_nxt;
    end
  end

  //----------------------------------------------------------------------------
  // Way prediction and enabled state updates
  // flag_q = {debug delayed, Way unavailable delayed, redirect delayed, stall delayed}.
  // way_q[0] = sampled Way; way_q[1] = saved redirect Way.
  //----------------------------------------------------------------------------
  assign chgflw_way = selected_payload[0][33:32];
  assign inner_way_default = (ipctrl_pcgen_inner_way0 || ipctrl_pcgen_inner_way1) ?
    {ipctrl_pcgen_inner_way1, ipctrl_pcgen_inner_way0} : 2'b11;
  assign inner_way = inc_pc[5] ? ipctrl_pcgen_inner_way_pred : inner_way_default;
  assign
    way_predict = !cp0_ifu_iwpe ? 2'b11 : chgflw ? chgflw_way : (ifctrl_pcgen_stall || flag_q[0]) ?
    way_q[0] : (flag_q[1] && (inc_pc[5:4] != 2'b00)) ? way_q[1] : inner_way;
  assign flag_en = {rtu_ifu_dbgon || flag_q[3], 1'b1, if_pc_en, 1'b1};
  assign flag_nxt = {rtu_ifu_dbgon, (way_predict == 2'b00), chgflw, ifctrl_pcgen_stall};
  assign way_en = {if_pc_en, 1'b1};
  assign way_nxt[0] = way_predict;
  assign way_nxt[1] = chgflw ? chgflw_way : 2'b11;

  generate
    for (flag_index = 0; flag_index < FLAG_COUNT; flag_index = flag_index + 1) begin : g_flag
      always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_flag
        if (!cpurst_b) begin
          flag_q[flag_index] <= 1'b0;
        end else if (flag_en[flag_index]) begin
          flag_q[flag_index] <= flag_nxt[flag_index];
        end
      end
    end
    for (way_index = 0; way_index < WAY_STATE_COUNT; way_index = way_index + 1) begin : g_way_state
      always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_way
        if (!cpurst_b) begin
          way_q[way_index] <= 2'b00;
        end else if (way_en[way_index]) begin
          way_q[way_index] <= way_nxt[way_index];
        end
      end
    end
  endgenerate

  //----------------------------------------------------------------------------
  // Graded cancellation; local correction must not flush older IBUF contents.
  //----------------------------------------------------------------------------
  assign debug_cancel = rtu_ifu_dbgon && !flag_q[3];
  assign higher_than_addrgen = |source_req[0][3:0];
  assign higher_than_ib = |source_req[0][4:0];
  assign higher_than_ip = |source_req[0][5:0];
  assign global_cancel = higher_than_addrgen || rtu_ifu_flush || debug_cancel;
  assign pcgen_ifctrl_reissue = |source_req[0][2:0];
  assign pcgen_ifctrl_cancel = chgflw_without_l0 || rtu_ifu_flush || debug_cancel;
  assign pcgen_ipctrl_cancel = higher_than_ip || rtu_ifu_flush || debug_cancel;
  assign pcgen_ifctrl_pipe_cancel = pcgen_ipctrl_cancel || lbuf_pcgen_vld_mask ||
    ipctrl_pcgen_chk_err_reissue || (ipctrl_pcgen_chgflw_pcload && !ipctrl_pcgen_if_stall);
  assign pcgen_ipctrl_pipe_cancel = higher_than_ib || rtu_ifu_flush || debug_cancel ||
    lbuf_pcgen_vld_mask || (ibctrl_pcgen_pcload && !ibctrl_pcgen_ip_stall);
  assign pcgen_ibctrl_cancel = global_cancel;
  assign pcgen_ibctrl_ibuf_flush = global_cancel;
  // IU recovery exits loop replay as required by the RV32I specification.
  assign pcgen_ibctrl_lbuf_flush = global_cancel ||
    (ifctrl_pcgen_ins_icache_inv_done && !lbuf_pcgen_active);
  assign pcgen_ibctrl_bju_chgflw = iu_ifu_chgflw_vld;
  assign pcgen_addrgen_cancel = higher_than_ib;
  assign pcgen_l1_refill_chgflw = chgflw;
  assign pcgen_ipb_chgflw = chgflw;

  //----------------------------------------------------------------------------
  // ICache fast-address path. Mask old data whenever IF reissue is asserted.
  //----------------------------------------------------------------------------
  assign pcgen_icache_if_index = pc_bus;
  assign pcgen_icache_if_way_pred = way_predict;
  assign pcgen_icache_if_chgflw = fetch_enable && chgflw;
  assign pcgen_icache_if_chgflw_short = fetch_enable && chgflw_short;
  assign pcgen_icache_if_seq_data_req = seq_advance;
  assign pcgen_icache_if_seq_data_req_short = fetch_enable && !ifctrl_pcgen_stall_short;
  // [ICACHE 参数化] 只在"顺序取指跨进新行 ⇒ set 变了"时才重读 tag。
  // 64 B 行: 行内 4 个 16 B 拍共用 1 个 set, 所以只有 pc[5:4]==0 需要重读 ✓
  // 16 B 行: 每个 16 B 拍就是一整行 ⇒ set 每拍都变, 必须每拍重读。
  // (原式恒按 64 B 行判, 16 B 行下 3/4 的顺序取指会拿上一行的 tag 去比。)
  generate
    if (LINE_BITS > 4) begin : g_seq_tag_on_line_boundary
      assign pcgen_icache_if_seq_tag_req = seq_advance && (pc_bus[LINE_BITS-1:4] == 2'b00);
    end else begin : g_seq_tag_every_fetch
      assign pcgen_icache_if_seq_tag_req = seq_advance;
    end
  endgenerate
  assign pcgen_icache_if_gateclk_en = fetch_enable && (chgflw_short || !ifctrl_pcgen_stall_short);
  // Only trim for the selected IP taken redirect. Reissue/higher redirects
  // must never inherit the bank mask of a losing branch source.
  assign trim_bank = source_sel[0][7] && ipctrl_pcgen_branch_taken &&
    (ipctrl_pcgen_taken_pc == ipctrl_pcgen_chgflw_pc);
  generate
    for (bank = 0; bank < BANK_COUNT; bank = bank + 1) begin : g_bank
      // The retained C910 array wires bank0 to data[127:96], bank3 to [31:0].
      localparam [1:0] SLOT = BANK_COUNT - 1 - bank;
      assign bank_chgflw[bank] = pcgen_icache_if_chgflw &&
        (!trim_bank || (SLOT >= ipctrl_pcgen_taken_pc[3:2]));
    end
  endgenerate
  assign {pcgen_icache_if_chgflw_bank3, pcgen_icache_if_chgflw_bank2, pcgen_icache_if_chgflw_bank1,
          pcgen_icache_if_chgflw_bank0} = bank_chgflw;

  //----------------------------------------------------------------------------
  // Predictor indices, observation and registered IF payload
  //----------------------------------------------------------------------------
  assign pcgen_ifctrl_pc = if_pc_q;
  assign pcgen_ifdp_pc = if_pc_q;
  assign pcgen_ifdp_inc_pc = inc_pc;
  assign pcgen_ifctrl_way_pred = way_q[0];
  assign pcgen_ifdp_way_pred = way_q[0];
  assign pcgen_ifctrl_way_pred_stall = flag_q[2];
  // BHT leaf retains its original halfword-based index encoding, NOT a PC bus.
  assign pcgen_bht_ifpc = if_pc_q[7:1];
  assign pcgen_bht_pcindex = pc_bus[13:4];
  assign pcgen_bht_seq_read = if_pc_q[7] ^ inc_pc[7];
  assign pcgen_bht_chgflw = chgflw;
  assign pcgen_bht_chgflw_short = chgflw_short;
  assign pcgen_btb_index = pc_bus[13:4];
  assign pcgen_btb_stall = ifctrl_pcgen_stall || !fetch_enable;
  assign pcgen_btb_stall_short = ifctrl_pcgen_stall_short || !fetch_enable;
  assign pcgen_btb_chgflw = chgflw;
  assign pcgen_btb_chgflw_short = chgflw_short;
  assign pcgen_btb_chgflw_higher_than_addrgen = higher_than_addrgen;
  assign pcgen_btb_chgflw_higher_than_ip = higher_than_ip;
  assign pcgen_btb_chgflw_higher_than_if = chgflw_without_l0;
  assign pcgen_l0_btb_chgflw_mask = higher_than_ib || ipctrl_pcgen_branch_mistaken ||
    ipctrl_pcgen_reissue_pcload || ifctrl_pcgen_reissue_pcload;
  assign pcgen_l0_btb_chgflw_vld = ifctrl_pcgen_chgflw_vld || ipctrl_pcgen_branch_taken ||
    ibctrl_pcgen_pcload_vld || iu_ifu_chgflw_vld;
  assign
    pcgen_l0_btb_chgflw_pc = ibctrl_pcgen_pcload ? ibctrl_pcgen_pc : ipctrl_pcgen_branch_taken ?
    ipctrl_pcgen_taken_pc : ifctrl_pcgen_chgflw_no_stall_mask ? ifctrl_pcgen_pcload_pc : inc_pc;
  assign pcgen_l0_btb_if_pc = if_pc_q;
  assign pcgen_sfp_pc = if_pc_q[20:4];
  assign pcgen_debug_chgflw = chgflw;
  assign pcgen_debug_pcbus = pc_bus;
  assign ifu_had_fetch_pc = if_pc_q;
endmodule
