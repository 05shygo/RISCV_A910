// SPDX-License-Identifier: Apache-2.0
// Static physical-region decode. No MMU, translation, TLB or PMP semantics.
// REGION_LIMIT is an exclusive 33-bit end, allowing an end of 0x1_0000_0000.
// Integrator supplies non-overlapping regions with 64-byte-aligned boundaries.
// Attributes [4:0] = {exec_allow, cacheable, bufferable, sec, spec_safe}.
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_region #(
  parameter REGION_COUNT = 1,
  parameter [REGION_COUNT*32-1:0] REGION_BASE = 0,
  parameter [REGION_COUNT*33-1:0] REGION_LIMIT = 0,
  parameter [REGION_COUNT*5-1:0] REGION_ATTR = 0
) (
  input  wire [31:0] pa,
  output wire [ 4:0] attr
);
  integer       i;
  reg     [4:0] attr_int;
  reg           found;
  reg           overlap;
  // Reject an ambiguous table instead of OR-combining contradictory permissions.
  always @(*) begin : p_decode_comb
    attr_int = 5'b0;
    found    = 1'b0;
    overlap  = 1'b0;
    for (i = 0; i < REGION_COUNT; i = i + 1) begin
      if (({1'b0, pa} >= {1'b0, REGION_BASE[32*i+:32]}) &&
          ({1'b0, pa} < REGION_LIMIT[33*i+:33])) begin
        overlap  = overlap || found;
        found    = 1'b1;
        attr_int = REGION_ATTR[5*i+:5];
      end
    end
  end
  assign attr = overlap ? 5'b0 : attr_int;
endmodule
