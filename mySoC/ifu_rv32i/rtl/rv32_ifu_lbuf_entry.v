// SPDX-License-Identifier: Apache-2.0
// RV32I full-instruction adaptation of ct_ifu_lbuf_entry.v (T-Head, 2019-2021).
// One loop-buffer entry now holds a complete 32 bit instruction plus its
// control-transfer metadata. The C910 half-word fields (32_start, split0_type,
// split1_type, vl/vlmul/vsew/vsetvli, vsetvli) have no RV32I counterpart and are
// gone; the entry keeps exactly the C910 pair of registers: payload and valid.
// C910 gates both registers with gated_clk_cell instances. This core's
// rv32_ifu_clk_cell is a pass-through, so the C910 clock enables are reproduced
// here as the write conditions of the two always blocks instead.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_lbuf_entry (
  input  wire        forever_cpuclk,
  input  wire        cpurst_b,
  input  wire        lbuf_flush,
  input  wire        fill_state_enter,
  input  wire        entry_create_x,
  input  wire [31:0] entry_create_inst_data_v,
  input  wire        entry_create_front_br_x,
  input  wire        entry_create_back_br_x,
  input  wire        entry_create_fence_x,
  input  wire        entry_create_bkpta_x,
  input  wire        entry_create_bkptb_x,
  output reg  [31:0] entry_inst_data_v,
  output reg         entry_front_br_x,
  output reg         entry_back_br_x,
  output reg         entry_fence_x,
  output reg         entry_bkpta_x,
  output reg         entry_bkptb_x,
  output reg         entry_vld_x
);

  //------------------------------------------------------------------------------
  // Entry valid bit
  //------------------------------------------------------------------------------
  // C910 priority: reset, lbuf_flush, FILL kick-off, create.
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_entry_vld
    if (!cpurst_b) begin
      entry_vld_x <= 1'b0;
    end else if (lbuf_flush) begin
      entry_vld_x <= 1'b0;
    end else if (fill_state_enter) begin
      entry_vld_x <= 1'b0;
    end else if (entry_create_x) begin
      entry_vld_x <= 1'b1;
    end
  end

  //------------------------------------------------------------------------------
  // Entry payload
  //------------------------------------------------------------------------------
  // C910 writes the payload only on a create; lbuf_flush and fill_state_enter do
  // not clear it there either, because entry_vld_x gates every read.
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_entry_data
    if (!cpurst_b) begin
      entry_inst_data_v <= 32'b0;
      entry_front_br_x  <= 1'b0;
      entry_back_br_x   <= 1'b0;
      entry_fence_x     <= 1'b0;
      entry_bkpta_x     <= 1'b0;
      entry_bkptb_x     <= 1'b0;
    end else if (entry_create_x) begin
      entry_inst_data_v <= entry_create_inst_data_v;
      entry_front_br_x  <= entry_create_front_br_x;
      entry_back_br_x   <= entry_create_back_br_x;
      entry_fence_x     <= entry_create_fence_x;
      entry_bkpta_x     <= entry_create_bkpta_x;
      entry_bkptb_x     <= entry_create_bkptb_x;
    end
  end
endmodule
