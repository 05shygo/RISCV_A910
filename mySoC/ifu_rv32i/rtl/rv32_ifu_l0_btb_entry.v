// SPDX-License-Identifier: Apache-2.0
// RV32 slot adaptation of ct_ifu_l0_btb_entry: one L0 BTB entry carrying four
// independently write-enabled fields (valid / counter / return / tag-kind-way-target),
// so that a counter bump or a directed invalidation need not disturb the rest.
// Compared with C910: full-width src/dst replace the partial tag and high-PC target
// reconstruction, and an explicit kind[2:0] field is kept because this core's IP stage
// checks the predicted control-transfer type (rv32_ifu_ipctrl.v l0_correct).

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_l0_btb_entry (

  // Clock, reset and configuration
  input wire forever_cpuclk,
  input wire cpurst_b,
  input wire cp0_ifu_btb_en,
  input wire cp0_ifu_icg_en,
  input wire cp0_ifu_l0btb_en,
  input wire cp0_yy_clk_en,
  input wire pad_yy_icg_scan_en,

  // Entry update interface
  input  wire        entry_update,
  input  wire        entry_inv,
  input  wire [ 3:0] entry_wen,
  input  wire        entry_update_vld,
  input  wire        entry_update_cnt,
  input  wire        entry_update_ras,
  input  wire [68:0] entry_update_data,

  // Entry contents
  output reg         entry_vld,
  output reg         entry_cnt,
  output reg         entry_ras,
  output reg  [ 2:0] entry_kind,
  output reg  [ 1:0] entry_way_pred,
  output reg  [31:0] entry_src,
  output reg  [31:0] entry_dst
);

  //------------------------------------------------------------------------------
  // Local parameters
  //------------------------------------------------------------------------------
  localparam DATA_KIND = 66;  // entry_update_data[68:66]
  localparam DATA_SRC  = 34;  // entry_update_data[65:34]
  localparam DATA_WAY  = 32;  // entry_update_data[33:32]
  localparam DATA_DST  = 0;   // entry_update_data[31:0]

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire entry_clk;
  wire entry_clk_en;
  wire entry_update_en;

  //------------------------------------------------------------------------------
  // Gated clock and write qualification
  //------------------------------------------------------------------------------
  rv32_ifu_clk_cell x_entry_clk (
    .clk_in             (forever_cpuclk    ),
    .clk_out            (entry_clk         ),
    .external_en        (1'b0              ),
    .global_en          (cp0_yy_clk_en     ),
    .local_en           (entry_clk_en      ),
    .module_en          (cp0_ifu_icg_en    ),
    .pad_yy_icg_scan_en (pad_yy_icg_scan_en)
  );

  assign entry_clk_en    = entry_update_en;
  assign entry_update_en = entry_update && cp0_ifu_btb_en && cp0_ifu_l0btb_en;

  //------------------------------------------------------------------------------
  // Contents of one L0 BTB entry
  //------------------------------------------------------------------------------
  // A global invalidation clears the whole entry, payload included.
  always @(posedge entry_clk or negedge cpurst_b) begin : p_vld
    if (!cpurst_b) begin
      entry_vld <= 1'b0;
    end else if (entry_inv) begin
      entry_vld <= 1'b0;
    end else if (entry_wen[3] && entry_update_en) begin
      entry_vld <= entry_update_vld;
    end
  end

  always @(posedge entry_clk or negedge cpurst_b) begin : p_cnt
    if (!cpurst_b) begin
      entry_cnt <= 1'b0;
    end else if (entry_inv) begin
      entry_cnt <= 1'b0;
    end else if (entry_wen[2] && entry_update_en) begin
      entry_cnt <= entry_update_cnt;
    end
  end

  always @(posedge entry_clk or negedge cpurst_b) begin : p_ras
    if (!cpurst_b) begin
      entry_ras <= 1'b0;
    end else if (entry_inv) begin
      entry_ras <= 1'b0;
    end else if (entry_wen[1] && entry_update_en) begin
      entry_ras <= entry_update_ras;
    end
  end

  always @(posedge entry_clk or negedge cpurst_b) begin : p_data
    if (!cpurst_b) begin
      entry_src      <= 32'b0;
      entry_kind     <= 3'b0;
      entry_way_pred <= 2'b0;
      entry_dst      <= 32'b0;
    end else if (entry_inv) begin
      entry_src      <= 32'b0;
      entry_kind     <= 3'b0;
      entry_way_pred <= 2'b0;
      entry_dst      <= 32'b0;
    end else if (entry_wen[0] && entry_update_en) begin
      entry_src      <= entry_update_data[DATA_SRC+:32];
      entry_kind     <= entry_update_data[DATA_KIND+:3];
      entry_way_pred <= entry_update_data[DATA_WAY+:2];
      entry_dst      <= entry_update_data[DATA_DST+:32];
    end
  end
endmodule
