// SPDX-License-Identifier: Apache-2.0
// RV32 word-slot re-layout of ct_ifu_btb + tag/data arrays (spec v3.1 section 6.2).
// Retains 512 rows x 4 slots, two paired banks, registered read, update buffer,
// update bypass and way hints. Removes compressed target and halfword hash.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_btb #(
  // [BP_SHRINK] 行数可配, 默认 = 原样 512 行 (row = pc[12:4])。
  // `+define+BP_BTB_ROW_W=n` 覆盖成 2^n 行。
  // ⚠ 与 BHT 阵列不同, 这里**同时把标签加宽**: row 用 pc[n+3:4], 标签用
  //   pc[31:n+4]。否则被丢掉的高位不在标签里, 不同 PC 会"假命中" (指向错的
  //   目标), 比真实的小表更吃亏 —— 真实设计缩表时是把高位挪进标签的。
  //   n=9 → row=pc[12:4], tag={1'b1,pc[31:13]}, 与原实现逐位一致。
`ifdef BP_BTB_ROW_W
  parameter ROW_W = `BP_BTB_ROW_W,
`else
  parameter ROW_W = 9,
`endif
  parameter TAG_W = 29 - ROW_W   // = 1'b1(valid) + pc[31:ROW_W+4]
) (

  // Clock, reset and configuration
  input wire forever_cpuclk,
  input wire cpurst_b,

  // Predictor and pipeline interface
  input  wire         enable,
  input  wire         cancel,
  input  wire         invalidate,
  output wire         init_done,
  input  wire         lookup_vld,
  output wire         lookup_ready,
  input  wire [ 31:0] lookup_pc,
  output wire         result_vld,
  output wire [  3:0] hit,
  output wire [127:0] target,
  output wire [  7:0] way_hint,
  // Synchronous SRAM result in IF, before the legacy result register.
  output wire         if_vld,
  output wire [ 31:0] if_pc,
  output wire [  3:0] if_hit,
  output wire [127:0] if_target,
  output wire [  7:0] if_way_hint,
  input  wire         update_vld,
  output wire         update_ready,
  input  wire [ 31:0] update_pc,
  input  wire [ 31:0] update_target,
  input  wire [  1:0] update_way
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------

  genvar b;
  genvar s;
  reg          sweeping_q;
  wire         sweeping_nxt;
  wire         sweeping_en;
  reg  [ROW_W-1:0] sweep_row_q;
  wire [ROW_W-1:0] sweep_row_nxt;
  wire         sweep_row_en;
  reg          init_done_q;
  wire         init_done_nxt;
  wire         init_done_en;
  reg          buf_vld_q;
  wire         buf_vld_nxt;
  wire         buf_vld_en;
  reg  [ 31:0] buf_pc_q;
  wire [ 31:0] buf_pc_nxt;
  wire         buf_pc_en;
  reg  [ 31:0] buf_target_q;
  wire [ 31:0] buf_target_nxt;
  wire         buf_target_en;
  reg  [  1:0] buf_way_q;
  wire [  1:0] buf_way_nxt;
  wire         buf_way_en;
  reg          rd_pending_q;
  wire         rd_pending_nxt;
  wire         rd_pending_en;
  reg  [ 31:0] rd_pc_q;
  wire [ 31:0] rd_pc_nxt;
  wire         rd_pc_en;
  reg          result_vld_q;
  wire         result_vld_nxt;
  wire         result_vld_en;
  reg  [  3:0] hit_q;
  wire [  3:0] hit_nxt;
  wire         hit_en;
  reg  [127:0] target_q;
  wire [127:0] target_nxt;
  wire         target_en;
  reg  [  7:0] way_hint_q;
  wire [  7:0] way_hint_nxt;
  wire         way_hint_en;
  wire         write_buf;
  wire         rd;
  wire         upd;
  wire [ROW_W-1:0] row;
  wire [4*TAG_W-1:0] tag_q;
  wire [135:0] data_q;
  wire         sweep_last;
  wire         active;
  wire         response_en;
  wire [  3:0] slot_hit;
  wire [127:0] slot_target;
  wire [  7:0] slot_way_hint;
  wire [  3:0] slot_eligible;
  wire [  3:0] buffer_bypass;
  wire [  3:0] update_bypass;
  wire         tag_cen;
  wire         tag_gwen;
  wire         data_cen;
  wire         data_gwen;

  //------------------------------------------------------------------------------
  // Request control and SRAM interface
  //------------------------------------------------------------------------------
  assign write_buf    = buf_vld_q && !sweeping_q && !invalidate;
  assign rd           = lookup_vld && lookup_ready;
  assign upd          = update_vld && update_ready && !(|update_pc[1:0]) && !(|update_target[1:0]);
  assign row          = sweeping_q ? sweep_row_q : write_buf ? buf_pc_q[ROW_W+3:4] : lookup_pc[ROW_W+3:4];

  // A buffered write owns the single port; same row may be answered next cycle.
  assign lookup_ready = init_done_q && enable && !invalidate && !write_buf && !cancel;

  assign update_ready = init_done_q && enable && !invalidate && !cancel;

  assign sweep_last   = &sweep_row_q;
  assign active       = !invalidate && !sweeping_q;
  assign response_en  = active && rd_pending_q && !cancel;
  assign if_vld       = response_en && enable;
  assign if_pc        = rd_pc_q;
  assign if_hit       = slot_hit & {4{if_vld}};
  assign if_target    = slot_target;
  assign if_way_hint  = slot_way_hint;
  assign tag_cen      = !(sweeping_q || write_buf || rd);
  assign tag_gwen     = !(sweeping_q || write_buf);
  assign data_cen     = !(write_buf || rd);
  assign data_gwen    = !write_buf;

  generate
    for (b = 0; b < 2; b = b + 1) begin : g_bank
      wire [2*TAG_W-1:0] tag_d;
      wire [2*TAG_W-1:0] tag_write_data;
      wire [67:0] data_d;
      wire [ 1:0] selected;
      wire [2*TAG_W-1:0] tag_mask;
      wire [67:0] data_mask;

      assign tag_d          = {2{{1'b1, buf_pc_q[31:ROW_W+4]}}};
      assign tag_write_data = sweeping_q ? {2*TAG_W{1'b0}} : tag_d;
      assign data_d         = {2{{buf_way_q, buf_target_q}}};
      assign selected       = (buf_pc_q[3] == (b != 0)) ? (2'b01 << buf_pc_q[2]) : 2'b00;
      assign tag_mask       = sweeping_q ? {2*TAG_W{1'b0}} : {{TAG_W{!selected[1]}}, {TAG_W{!selected[0]}}};
      assign data_mask      = {{34{!selected[1]}}, {34{!selected[0]}}};

      rv32_ifu_spram #(
        .ADDR_WIDTH(ROW_W),
        .DATA_WIDTH(2*TAG_W)
      ) u_tags (
        .CLK (forever_cpuclk),
        .CEN (tag_cen),
        .GWEN(tag_gwen),
        .A   (row),
        .D   (tag_write_data),
        .WEN (tag_mask),
        .Q   (tag_q[b*2*TAG_W+:2*TAG_W])
      );
      rv32_ifu_spram #(
        .ADDR_WIDTH(ROW_W),
        .DATA_WIDTH(68)
      ) u_data (
        .CLK (forever_cpuclk),
        .CEN (data_cen),
        .GWEN(data_gwen),
        .A   (row),
        .D   (data_d),
        .WEN (data_mask),
        .Q   (data_q[b*68+:68])
      );
    end
  endgenerate

  //------------------------------------------------------------------------------
  // Read result selection
  //------------------------------------------------------------------------------
  // A newly accepted update wins over the buffered write and the SRAM result.
  generate
    for (s = 0; s < 4; s = s + 1) begin : g_slot
      assign slot_eligible[s] = enable && s[1:0] >= rd_pc_q[3:2] && rd_pc_q[1:0] == 0;
      assign
        buffer_bypass[s] = write_buf && buf_pc_q[31:4] == rd_pc_q[31:4] && buf_pc_q[3:2] == s[1:0];
      assign update_bypass[s] = upd && update_pc[31:4] == rd_pc_q[31:4] && update_pc[3:2] == s[1:0];
      assign
        slot_hit[s] = slot_eligible[s] && (update_bypass[s] || buffer_bypass[s] ||
                                           (tag_q[s*TAG_W+TAG_W-1] && tag_q[s*TAG_W+:TAG_W-1] == rd_pc_q[31:ROW_W+4]));
      assign slot_target[s*32+:32] = update_bypass[s] ? update_target :
        buffer_bypass[s] ? buf_target_q : data_q[s*34+:32];
      assign slot_way_hint[s*2+:2] = update_bypass[s] ? update_way :
        buffer_bypass[s] ? buf_way_q : data_q[s*34+32+:2];
    end
  endgenerate

  //------------------------------------------------------------------------------
  // Register next values and enables
  //------------------------------------------------------------------------------
  // Invalidate restarts the sweep. The last row is held at completion.
  // Buffer payload and read address hold during invalidate/sweep; buf_vld also
  // holds during sweep after being cleared by reset or invalidate.
  // Hit clears during sweep; target/way retain their old contents until a response.
  assign sweeping_nxt   = invalidate;
  assign sweeping_en    = invalidate || (sweeping_q && sweep_last);

  assign sweep_row_nxt  = invalidate ? {ROW_W{1'b0}} : sweep_row_q + 1'b1;
  assign sweep_row_en   = invalidate || (sweeping_q && !sweep_last);

  assign init_done_nxt  = !invalidate;
  assign init_done_en   = invalidate || (sweeping_q && sweep_last);

  assign buf_vld_nxt    = !invalidate && upd;
  assign buf_vld_en     = invalidate || !sweeping_q;

  assign buf_pc_nxt     = update_pc;
  assign buf_pc_en      = active && upd;

  assign buf_target_nxt = update_target;
  assign buf_target_en  = active && upd;

  assign buf_way_nxt    = update_way;
  assign buf_way_en     = active && upd;

  assign rd_pending_nxt = active && rd;
  assign rd_pending_en  = 1'b1;

  assign rd_pc_nxt      = lookup_pc;
  assign rd_pc_en       = active && rd;

  assign result_vld_nxt = response_en && enable;
  assign result_vld_en  = 1'b1;

  assign hit_nxt        = active ? slot_hit : 4'b0;
  assign hit_en         = invalidate || sweeping_q || response_en;

  assign target_nxt     = slot_target;
  assign target_en      = response_en;

  assign way_hint_nxt   = slot_way_hint;
  assign way_hint_en    = response_en;

  //------------------------------------------------------------------------------
  // Registers
  //------------------------------------------------------------------------------
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sweeping
    if (!cpurst_b) begin
      sweeping_q <= 1'b1;
    end else if (sweeping_en) begin
      sweeping_q <= sweeping_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sweep_row
    if (!cpurst_b) begin
      sweep_row_q <= {ROW_W{1'b0}};
    end else if (sweep_row_en) begin
      sweep_row_q <= sweep_row_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_init_done
    if (!cpurst_b) begin
      init_done_q <= 1'b0;
    end else if (init_done_en) begin
      init_done_q <= init_done_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_buf_vld
    if (!cpurst_b) begin
      buf_vld_q <= 1'b0;
    end else if (buf_vld_en) begin
      buf_vld_q <= buf_vld_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_buf_pc
    if (!cpurst_b) begin
      buf_pc_q <= 32'b0;
    end else if (buf_pc_en) begin
      buf_pc_q <= buf_pc_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_buf_target
    if (!cpurst_b) begin
      buf_target_q <= 32'b0;
    end else if (buf_target_en) begin
      buf_target_q <= buf_target_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_buf_way
    if (!cpurst_b) begin
      buf_way_q <= 2'b0;
    end else if (buf_way_en) begin
      buf_way_q <= buf_way_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rd_pending
    if (!cpurst_b) begin
      rd_pending_q <= 1'b0;
    end else if (rd_pending_en) begin
      rd_pending_q <= rd_pending_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rd_pc
    if (!cpurst_b) begin
      rd_pc_q <= 32'b0;
    end else if (rd_pc_en) begin
      rd_pc_q <= rd_pc_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_result_vld
    if (!cpurst_b) begin
      result_vld_q <= 1'b0;
    end else if (result_vld_en) begin
      result_vld_q <= result_vld_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_hit
    if (!cpurst_b) begin
      hit_q <= 4'b0;
    end else if (hit_en) begin
      hit_q <= hit_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_target
    if (!cpurst_b) begin
      target_q <= 128'b0;
    end else if (target_en) begin
      target_q <= target_nxt;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_way_hint
    if (!cpurst_b) begin
      way_hint_q <= 8'b0;
    end else if (way_hint_en) begin
      way_hint_q <= way_hint_nxt;
    end
  end

  //------------------------------------------------------------------------------
  // Output assignments
  //------------------------------------------------------------------------------
  assign init_done  = init_done_q;
  assign result_vld = result_vld_q;
  assign hit        = hit_q;
  assign target     = target_q;
  assign way_hint   = way_hint_q;
endmodule
