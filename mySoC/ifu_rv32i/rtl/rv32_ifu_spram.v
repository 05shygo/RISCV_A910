// SPDX-License-Identifier: Apache-2.0
// Portable C910-style synchronous 1RW array; active-low CEN/GWEN/bit WEN.
// Read output holds during a write. No reset of data: controller must sweep it.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_spram #(
  parameter ADDR_WIDTH = 10,
  parameter DATA_WIDTH = 64
) (

  // Predictor and pipeline interface
  input  wire                  CLK,
  input  wire                  CEN,
  input  wire                  GWEN,
  input  wire [ADDR_WIDTH-1:0] A,
  input  wire [DATA_WIDTH-1:0] D,
  input  wire [DATA_WIDTH-1:0] WEN,
  output wire [DATA_WIDTH-1:0] Q
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  reg     [DATA_WIDTH-1:0] mem_q[0:(1<<ADDR_WIDTH)-1];
  integer                  i;
  reg     [DATA_WIDTH-1:0] q_q;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  always @(posedge CLK) begin : p_i

    if (!CEN) begin
      if (!GWEN) begin
        for (i = 0; i < DATA_WIDTH; i = i + 1) begin
          if (!WEN[i]) begin
            mem_q[A][i] <= D[i];
          end
        end
      end else begin
        q_q <= mem_q[A];
      end
    end
  end

  //------------------------------------------------------------------------------
  // Output assignments
  //------------------------------------------------------------------------------
  assign Q = q_q;
endmodule
