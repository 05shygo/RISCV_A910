// SPDX-License-Identifier: Apache-2.0
// IB target arbitration after RV32 decode. Bad actual targets are source
// instruction exceptions reported by BJU, not frontend target-fetch faults.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_bp_target (

  // Predictor and pipeline interface
  input  wire [31:0] pc,
  input  wire [ 2:0] cf_type,
  input  wire [31:0] direct_target,
  input  wire        bht_pred,
  input  wire        ras_usable,
  input  wire        ras_valid,
  input  wire [31:0] ras_target,
  input  wire        ind_valid,
  input  wire [31:0] ind_target,
  input  wire        btb_valid,
  input  wire [31:0] btb_target,
  output wire [31:0] pred_npc,
  output wire [31:0] recorded_target,
  output wire        pred_taken,
  output wire        target_unknown,
  output wire        bad_target
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  reg [31:0] chosen;
  reg        available;
  reg [31:0] pred_npc_int;
  reg [31:0] recorded_target_int;
  reg        pred_taken_int;
  reg        target_unknown_int;
  reg        bad_target_int;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  always @(*) begin : p_pred_npc_comb
    pred_npc_int        = pc + 32'd4;
    recorded_target_int = pc + 32'd4;
    pred_taken_int      = 0;
    target_unknown_int  = 0;
    bad_target_int      = 0;
    chosen              = 0;
    available           = 0;
    case (cf_type)
      3'd1, 3'd2: begin
        recorded_target_int = direct_target;
        bad_target_int      = |direct_target[1:0];
        pred_taken_int      = cf_type == 3'd2 || bht_pred;
        if (pred_taken_int && !bad_target_int) begin
          pred_npc_int = direct_target;
        end
      end
      3'd3: begin
        if (ras_usable && ras_valid) begin
          chosen    = ras_target;
          available = 1;
        end else if (ind_valid) begin
          chosen    = ind_target;
          available = 1;
        end else if (btb_valid) begin
          chosen    = btb_target;
          available = 1;
        end
        bad_target_int     = available && (|chosen[1:0]);
        target_unknown_int = !available || bad_target_int;
        if (available && !bad_target_int) begin
          pred_taken_int      = 1;
          pred_npc_int        = chosen;
          recorded_target_int = chosen;
        end
      end
      default: begin
      end
    endcase
  end

  //------------------------------------------------------------------------------
  // Output assignments
  //------------------------------------------------------------------------------
  assign pred_npc        = pred_npc_int;
  assign recorded_target = recorded_target_int;
  assign pred_taken      = pred_taken_int;
  assign target_unknown  = target_unknown_int;
  assign bad_target      = bad_target_int;
endmodule
