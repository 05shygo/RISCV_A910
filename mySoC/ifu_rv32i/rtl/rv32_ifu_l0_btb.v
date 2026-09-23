// SPDX-License-Identifier: Apache-2.0
// RV32 slot adaptation of ct_ifu_l0_btb: 16-entry CAM, per-field entry writes,
// rotating allocation FIFO, ADDRGEN/IBDP write arbitration with ADDRGEN priority,
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

  // Training interface: ADDRGEN kill is mapped onto directed_inv_vld/mask,
  // IBDP fill onto the update_* group (see the arbitration section below).
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
  localparam FIFO_WIDTH  = 16;
  localparam DATA_WIDTH  = 69;  // {kind[2:0], src[31:0], way_pred[1:0], dst[31:0]}
  localparam HIT_WIDTH   = 43;  // {index[3:0], slot[1:0], type[2:0], target[31:0], way[1:0]}

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  genvar entry;
  genvar slot;
  genvar bit_index;
  reg  [FIFO_WIDTH-1:0]  entry_fifo_q;
  wire [FIFO_WIDTH-1:0]  entry_fifo_nxt;
  wire                   entry_fifo_en;
  wire                   lookup_en;
  wire                   update_en;
  wire                   update_match;
  wire                   alloc_vld;
  wire                   update_kill;
  wire                   update_hold;
  wire                   update_fire;
  wire                   update_cnt_armed;
  wire [ENTRY_COUNT-1:0] update_match_vec;
  wire [ENTRY_COUNT-1:0] update_select;
  wire [ENTRY_COUNT-1:0] ibdp_update_entry;
  wire [ENTRY_COUNT-1:0] l0_btb_update_entry;
  wire [ENTRY_COUNT-1:0] entry_invalidate;
  wire [          3:0]   l0_btb_wen;
  wire                   l0_btb_update_vld_bit;
  wire                   l0_btb_update_cnt_bit;
  wire                   l0_btb_update_ras_bit;
  wire [DATA_WIDTH-1:0]  l0_btb_update_data;

  // Per-entry contents, driven by the rv32_ifu_l0_btb_entry instances.
  wire [ENTRY_COUNT-1:0] entry_vld;
  wire [ENTRY_COUNT-1:0] entry_cnt;
  wire [ENTRY_COUNT-1:0] entry_ras;
  wire [          2:0]   entry_kind     [0:ENTRY_COUNT-1];
  wire [          1:0]   entry_way_pred [0:ENTRY_COUNT-1];
  wire [         31:0]   entry_src      [0:ENTRY_COUNT-1];
  wire [         31:0]   entry_dst      [0:ENTRY_COUNT-1];

  wire [ENTRY_COUNT-1:0] entry_rd_hit;
  wire [ENTRY_COUNT-1:0] eligible;
  wire [ENTRY_COUNT-1:0] slot_match        [ 0:SLOT_COUNT-1];
  wire [ SLOT_COUNT-1:0] slot_valid;
  wire [ SLOT_COUNT-1:0] slot_select;
  wire [ENTRY_COUNT-1:0] hit_candidates;
  wire [ENTRY_COUNT-1:0] hit_select;
  wire [         31:0]   entry_target      [0:ENTRY_COUNT-1];
  wire [  HIT_WIDTH-1:0] entry_hit_payload [0:ENTRY_COUNT-1];
  wire [ENTRY_COUNT-1:0] hit_terms         [  0:HIT_WIDTH-1];
  wire [  HIT_WIDTH-1:0] hit_payload;

  //------------------------------------------------------------------------------
  // Common controls
  //------------------------------------------------------------------------------
  assign lookup_en = lookup_vld && enable && !cancel && !invalidate && (lookup_pc[1:0] == 2'b00);
  assign update_en = update_vld && enable && !cancel && !invalidate && (update_pc[1:0] == 2'b00) &&
    (update_target[1:0] == 2'b00) && (update_type >= 3'd1) && (update_type <= 3'd3);
  assign update_match = |update_match_vec;
  assign alloc_vld = update_en && !update_match;

  //------------------------------------------------------------------------------
  // Update intent, following C910's per-entry write semantics
  //------------------------------------------------------------------------------
  // C910 never lowers the counter of an entry that is still present: a hit whose
  // branch is no longer predicted taken either deletes the entry (l0_btb_not_saturate,
  // ct_ifu_ipdp.v:5850-5855: "bht predict as weak taken,it may cause next branch not
  // taken") or leaves it untouched. Only a reallocation or an invalidation clears it.
  // Note update_taken here is the front-end's direction prediction, not the executed
  // result (rv32_ifu_ipdp.v:79 prediction_taken), so the kill is gated on the entry
  // having been armed == counter set; otherwise every not-taken prediction would
  // churn the whole table.
  assign update_cnt_armed = |(update_select & entry_cnt);
  assign update_kill      = update_en && update_match && !update_taken && update_cnt_armed;
  assign update_hold      = update_en && update_match && !update_taken && !update_cnt_armed;
  assign update_fire      = update_en && !update_hold;

  // The allocation FIFO advances only on a real allocation, never on a hit update
  // and never on a kill. A global invalidate restarts it at entry 0.
  assign entry_fifo_en  = invalidate || alloc_vld;
  assign entry_fifo_nxt = invalidate ? 16'h0001 : {entry_fifo_q[FIFO_WIDTH-2:0], entry_fifo_q[FIFO_WIDTH-1]};

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_entry_fifo
    if (!cpurst_b) begin
      entry_fifo_q <= 16'h0001;
    end else if (entry_fifo_en) begin
      entry_fifo_q <= entry_fifo_nxt;
    end
  end

  //------------------------------------------------------------------------------
  // Write arbitration: the directed invalidation (C910's ADDRGEN operand) wins over
  // the training fill (C910's IBDP operand, ct_ifu_l0_btb.v casez 2'b1?). A kill only
  // enables wen[3] with a zero written into the valid bit, so the entry is deleted
  // with its tag/counter/return/way fields left alone; a fill touches all four fields.
  //------------------------------------------------------------------------------
  // Whether any write happens at all is decided solely by the per-entry select
  // below; wen/vld_bit/data only describe the intent of a write that does fire.
  assign
    l0_btb_wen[3:0] = (directed_inv_vld || update_kill) ? 4'b1000
                                                        : 4'b1111;
  assign l0_btb_update_vld_bit = !(directed_inv_vld || update_kill);
  assign l0_btb_update_cnt_bit = update_taken;
  assign l0_btb_update_ras_bit = update_ras;
  assign l0_btb_update_data    = {update_type, update_pc, update_way, update_target};

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
      assign update_match_vec[entry] = entry_vld[entry] && (entry_src[entry] == update_pc);
      assign
        update_select[entry] = update_match_vec[entry] && !(|(update_match_vec & HIGHER_ENTRIES));
      // A hit update lands on the entry that matched; a miss allocates at the
      // FIFO head. C910 carries this select down the pipe instead of re-comparing.
      assign ibdp_update_entry[entry] = update_match ? update_select[entry] : entry_fifo_q[entry];
      assign entry_invalidate[entry] = directed_inv_vld && directed_inv_mask[entry];
      assign l0_btb_update_entry[entry] = entry_invalidate[entry] ||
        (update_fire && ibdp_update_entry[entry]);

      assign entry_rd_hit[entry] = entry_vld[entry] && (entry_src[entry][31:4] == lookup_pc[31:4]);
      assign eligible[entry] = lookup_en && entry_rd_hit[entry] && !entry_invalidate[entry] &&
        (entry_src[entry][3:2] >= lookup_pc[3:2]) && entry_cnt[entry] &&
        (!entry_ras[entry] || ras_valid) && !(|entry_target[entry][1:0]);
      assign hit_candidates[entry] = eligible[entry] && slot_select[entry_src[entry][3:2]];
      // At the earliest word, the lowest entry number wins equal-slot ties.
      assign hit_select[entry] = hit_candidates[entry] && !(|(hit_candidates & LOWER_ENTRIES));
      assign entry_target[entry] = entry_ras[entry] ? ras_target : entry_dst[entry];
      assign entry_hit_payload[entry] = {
        ENTRY_INDEX, entry_src[entry][3:2], entry_kind[entry], entry_target[entry],
        entry_way_pred[entry]
      };

      for (bit_index = 0; bit_index < HIT_WIDTH; bit_index = bit_index + 1) begin : g_hit_bit
        assign
          hit_terms[bit_index][entry] = hit_select[entry] & entry_hit_payload[entry][bit_index];
      end

      rv32_ifu_l0_btb_entry x_entry (
        .forever_cpuclk     (forever_cpuclk    ),
        .cpurst_b           (cpurst_b          ),
        .cp0_ifu_btb_en     (enable            ),
        .cp0_ifu_icg_en     (1'b0              ),
        .cp0_ifu_l0btb_en   (enable            ),
        .cp0_yy_clk_en      (1'b1              ),
        .pad_yy_icg_scan_en (1'b0              ),
        .entry_update       (l0_btb_update_entry[entry]),
        .entry_inv          (invalidate        ),
        .entry_wen          (l0_btb_wen        ),
        .entry_update_vld   (l0_btb_update_vld_bit),
        .entry_update_cnt   (l0_btb_update_cnt_bit),
        .entry_update_ras   (l0_btb_update_ras_bit),
        .entry_update_data  (l0_btb_update_data),
        .entry_vld          (entry_vld[entry]  ),
        .entry_cnt          (entry_cnt[entry]  ),
        .entry_ras          (entry_ras[entry]  ),
        .entry_kind         (entry_kind[entry] ),
        .entry_way_pred     (entry_way_pred[entry]),
        .entry_src          (entry_src[entry]  ),
        .entry_dst          (entry_dst[entry]  )
      );
    end

    // Four replicated word-slot comparators and earliest-slot priority masks.
    for (slot = 0; slot < SLOT_COUNT; slot = slot + 1) begin : g_slot
      localparam [1:0] SLOT_INDEX = slot;
      localparam [SLOT_COUNT-1:0] LOWER_SLOTS = (4'b0001 << slot) - 4'b0001;
      for (entry = 0; entry < ENTRY_COUNT; entry = entry + 1) begin : g_entry_match
        assign slot_match[slot][entry] = eligible[entry] && (entry_src[entry][3:2] == SLOT_INDEX);
      end
      assign slot_valid[slot]  = |slot_match[slot];
      assign slot_select[slot] = slot_valid[slot] && !(|(slot_valid & LOWER_SLOTS));
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
