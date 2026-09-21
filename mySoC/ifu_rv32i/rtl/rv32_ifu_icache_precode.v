// SPDX-License-Identifier: Apache-2.0
// RV32I replacement for the compressed/halfword ct_ifu_precode format.
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_icache_precode (
  input  wire [127:0] data,
  output wire [ 31:0] precode
);
  genvar slot;
  generate
    for (slot = 0; slot < 4; slot = slot + 1) begin : g_slot
      wire [31:0] inst;
      wire        condbr;
      wire        jal;
      wire        jalr;
      wire        rd_link;
      wire        rs_link;
      wire        call_hint;
      wire        return_hint;
      wire        fence;
      wire        load_inst;
      wire        store_inst;
      assign inst = data[32*slot+:32];
      assign condbr = (inst[6:0] == 7'h63) &&
        ((inst[14:12] == 3'd0) || (inst[14:12] == 3'd1) || inst[14]);
      assign jal = inst[6:0] == 7'h6f;
      assign jalr = (inst[6:0] == 7'h67) && (inst[14:12] == 3'd0);
      assign rd_link = (inst[11:7] == 5'd1) || (inst[11:7] == 5'd5);
      assign rs_link = (inst[19:15] == 5'd1) || (inst[19:15] == 5'd5);
      assign call_hint = (jal || jalr) && rd_link;
      assign return_hint = jalr && rs_link && (!rd_link || (inst[11:7] != inst[19:15]));
      assign fence = (inst[6:0] == 7'h0f) && (inst[14:12] == 3'd0);
      assign load_inst = (inst[6:0] == 7'h03) &&
        ((inst[14:12] <= 3'd2) || (inst[14:12] == 3'd4) || (inst[14:12] == 3'd5));
      assign store_inst = (inst[6:0] == 7'h23) && (inst[14:12] <= 3'd2);
      assign precode[8*slot+:8] = {
        store_inst, load_inst, fence, return_hint, call_hint, jalr, jal, condbr
      };
    end
  endgenerate
endmodule
