// SPDX-License-Identifier: Apache-2.0
// RV32 slot adaptation of ct_ifu_l0_btb/entry: 16-entry CAM, circular replacement,
// counter/return/way information, earliest eligible word and directed invalidation.
// Full tags and targets replace C910's partial tag/high-PC target reconstruction.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
// Structure follows cci500_tt.v: generated entry circuits, assign-only
// combinational logic, and enable-only / reset-and-enable register storage.
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_l0_btb (

  // Clock, reset and configuration
  input wire forever_cpuclk,
  input wire cpurst_b,

  // Predictor and pipeline interface
  input  wire        enable,
  input  wire        invalidate,
  input  wire        lookup_vld,
  input  wire [31:0] lookup_pc,
  input  wire        cancel,
  input  wire        ras_valid,
  input  wire [31:0] ras_target,
  output wire        hit,
  output wire [ 3:0] hit_index,
  output wire [ 1:0] hit_slot,
  output wire [ 2:0] hit_type,
  output wire [31:0] target,
  output wire [ 1:0] way_hint,
  input  wire        update_vld,
  input  wire [31:0] update_pc,
  input  wire [31:0] update_target,
  input  wire [ 2:0] update_type,
  input  wire        update_taken,
  input  wire        update_ras,
  input  wire [ 1:0] update_way,
  input  wire        directed_inv_vld,
  input  wire [15:0] directed_inv_mask
);

  //------------------------------------------------------------------------------
  // Local parameters
  //------------------------------------------------------------------------------
  localparam ENTRY_COUNT = 16;
  localparam SLOT_COUNT  = 4;
  localparam INDEX_WIDTH = 4;
  localparam HIT_WIDTH   = 43;  // {index[3:0], slot[1:0], type[2:0], target[31:0], way[1:0]}

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  genvar entry;
  genvar slot;
  genvar bit_index;
  reg  [ENTRY_COUNT-1:0] valid_q;
  reg  [ENTRY_COUNT-1:0] taken_q;
  reg  [ENTRY_COUNT-1:0] use_ras_q;
  reg  [           31:0] src_q             [0:ENTRY_COUNT-1];
  reg  [           31:0] dst_q             [0:ENTRY_COUNT-1];
  reg  [            2:0] kind_q            [0:ENTRY_COUNT-1];
  reg  [            1:0] ways_q            [0:ENTRY_COUNT-1];
  reg  [INDEX_WIDTH-1:0] replace_ptr_q;
  wire [INDEX_WIDTH-1:0] replace_ptr_nxt;
  wire                   replace_ptr_en;
  wire                   lookup_en;
  wire                   update_en;
  wire                   update_match;
  wire [INDEX_WIDTH-1:0] update_index;
  wire [INDEX_WIDTH-1:0] wr_index;
  wire [ENTRY_COUNT-1:0] update_match_vec;
  wire [ENTRY_COUNT-1:0] update_select;
  wire [ENTRY_COUNT-1:0] update_index_terms[0:INDEX_WIDTH-1];
  wire [ENTRY_COUNT-1:0] entry_write;
  wire [ENTRY_COUNT-1:0] entry_invalidate;
  wire [ENTRY_COUNT-1:0] payload_en;
  wire [           31:0] src_nxt;
  wire [           31:0] dst_nxt;
  wire [            2:0] kind_nxt;
  wire [            1:0] ways_nxt;
  wire [ENTRY_COUNT-1:0] valid_en;
  wire [ENTRY_COUNT-1:0] valid_nxt;
  wire [ENTRY_COUNT-1:0] flags_en;
  wire                   taken_nxt;
  wire                   use_ras_nxt;
  wire [ENTRY_COUNT-1:0] eligible;
  wire [ENTRY_COUNT-1:0] slot_match        [ 0:SLOT_COUNT-1];
  wire [ SLOT_COUNT-1:0] slot_valid;
  wire [ SLOT_COUNT-1:0] slot_select;
  wire [ENTRY_COUNT-1:0] hit_candidates;
  wire [ENTRY_COUNT-1:0] hit_select;
  wire [           31:0] entry_target      [0:ENTRY_COUNT-1];
  wire [  HIT_WIDTH-1:0] entry_hit_payload [0:ENTRY_COUNT-1];
  wire [ENTRY_COUNT-1:0] hit_terms         [  0:HIT_WIDTH-1];
  wire [  HIT_WIDTH-1:0] hit_payload;

  //------------------------------------------------------------------------------
  // Common controls and register next values
  //------------------------------------------------------------------------------
  assign lookup_en = lookup_vld && enable && !cancel && !invalidate && (lookup_pc[1:0] == 2'b00);
  assign update_en = update_vld && enable && !cancel && !invalidate && (update_pc[1:0] == 2'b00) &&
    (update_target[1:0] == 2'b00) && (update_type >= 3'd1) && (update_type <= 3'd3);
  assign update_match = |update_match_vec;
  assign wr_index = update_match ? update_index : replace_ptr_q;
  assign src_nxt = update_pc;
  assign dst_nxt = update_target;
  assign kind_nxt = update_type;
  assign ways_nxt = update_way;
  assign taken_nxt = !invalidate && update_taken;
  assign use_ras_nxt = !invalidate && update_ras;
  assign replace_ptr_en = invalidate || (update_en && !update_match);
  assign replace_ptr_nxt = invalidate ? 4'b0000 : replace_ptr_q + 4'd1;

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_replace_ptr
    if (!cpurst_b) begin
      replace_ptr_q <= 4'b0000;
    end else if (replace_ptr_en) begin
      replace_ptr_q <= replace_ptr_nxt;
    end
  end

  //------------------------------------------------------------------------------
  // Identical CAM entries: compare, write decode and enabled storage
  //------------------------------------------------------------------------------
  generate
    for (entry = 0; entry < ENTRY_COUNT; entry = entry + 1) begin : g_entry
      localparam [INDEX_WIDTH-1:0] ENTRY_INDEX = entry;
      localparam [ENTRY_COUNT-1:0] LOWER_ENTRIES = (16'h0001 << entry) - 16'h0001;
      localparam [ENTRY_COUNT-1:0] HIGHER_ENTRIES = 16'hfffe << entry;

      // The original ascending update loop chose the highest matching index.
      // Match against old valid state, even if directed invalidation also fires.
      assign update_match_vec[entry] = valid_q[entry] && (src_q[entry] == update_pc);
      assign
        update_select[entry] = update_match_vec[entry] && !(|(update_match_vec & HIGHER_ENTRIES));
      assign entry_write[entry] = update_en && (wr_index == ENTRY_INDEX);
      assign entry_invalidate[entry] = directed_inv_vld && directed_inv_mask[entry];
      assign valid_en[entry] = invalidate || entry_write[entry] || entry_invalidate[entry];
      // Directed invalidation wins over an update to the same entry.
      assign valid_nxt[entry] = !invalidate && !entry_invalidate[entry];
      assign flags_en[entry] = invalidate || entry_write[entry];
      // Payload registers intentionally retain the original no-reset behavior.
      // Valid masks them until written; reset must suppress a simultaneous write.
      assign payload_en[entry] = cpurst_b && entry_write[entry];

      always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_valid
        if (!cpurst_b) begin
          valid_q[entry] <= 1'b0;
        end else if (valid_en[entry]) begin
          valid_q[entry] <= valid_nxt[entry];
        end
      end

      always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_flags
        if (!cpurst_b) begin
          taken_q[entry]   <= 1'b0;
          use_ras_q[entry] <= 1'b0;
        end else if (flags_en[entry]) begin
          taken_q[entry]   <= taken_nxt;
          use_ras_q[entry] <= use_ras_nxt;
        end
      end

      always @(posedge forever_cpuclk) begin : p_payload
        if (payload_en[entry]) begin
          src_q[entry]  <= src_nxt;
          dst_q[entry]  <= dst_nxt;
          kind_q[entry] <= kind_nxt;
          ways_q[entry] <= ways_nxt;
        end
      end

      assign entry_target[entry] = use_ras_q[entry] ? ras_target : dst_q[entry];
      assign eligible[entry] = lookup_en && valid_q[entry] && !entry_invalidate[entry] &&
        (src_q[entry][31:4] == lookup_pc[31:4]) && (src_q[entry][3:2] >= lookup_pc[3:2]) &&
        taken_q[entry] && (!use_ras_q[entry] || ras_valid) && !(|entry_target[entry][1:0]);
      assign hit_candidates[entry] = eligible[entry] && slot_select[src_q[entry][3:2]];
      // At the earliest word, the lowest entry number wins equal-slot ties.
      assign hit_select[entry] = hit_candidates[entry] && !(|(hit_candidates & LOWER_ENTRIES));
      assign entry_hit_payload[entry] = {
        ENTRY_INDEX, src_q[entry][3:2], kind_q[entry], entry_target[entry], ways_q[entry]
      };

      for (bit_index = 0; bit_index < INDEX_WIDTH; bit_index = bit_index + 1) begin : g_update_bit
        assign
          update_index_terms[bit_index][entry] = update_select[entry] && ENTRY_INDEX[bit_index];
      end
      for (bit_index = 0; bit_index < HIT_WIDTH; bit_index = bit_index + 1) begin : g_hit_bit
        assign
          hit_terms[bit_index][entry] = hit_select[entry] & entry_hit_payload[entry][bit_index];
      end
    end

    // Four replicated word-slot comparators and earliest-slot priority masks.
    for (slot = 0; slot < SLOT_COUNT; slot = slot + 1) begin : g_slot
      localparam [1:0] SLOT_INDEX = slot;
      localparam [SLOT_COUNT-1:0] LOWER_SLOTS = (4'b0001 << slot) - 4'b0001;
      for (entry = 0; entry < ENTRY_COUNT; entry = entry + 1) begin : g_entry_match
        assign slot_match[slot][entry] = eligible[entry] && (src_q[entry][3:2] == SLOT_INDEX);
      end
      assign slot_valid[slot]  = |slot_match[slot];
      assign slot_select[slot] = slot_valid[slot] && !(|(slot_valid & LOWER_SLOTS));
    end

    for (bit_index = 0; bit_index < INDEX_WIDTH; bit_index = bit_index + 1) begin : g_update_reduce
      assign update_index[bit_index] = |update_index_terms[bit_index];
    end
    for (bit_index = 0; bit_index < HIT_WIDTH; bit_index = bit_index + 1) begin : g_hit_reduce
      assign hit_payload[bit_index] = |hit_terms[bit_index];
    end
  endgenerate

  //------------------------------------------------------------------------------
  // Output assignments
  //------------------------------------------------------------------------------
  assign hit                                               = |hit_select;
  assign {hit_index, hit_slot, hit_type, target, way_hint} = hit_payload;
endmodule
