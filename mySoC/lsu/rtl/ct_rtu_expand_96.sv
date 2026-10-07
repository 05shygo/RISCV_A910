// Simple one-hot decoder for register number
// Converts 7-bit register number to 96-bit one-hot encoding

module ct_rtu_expand_96 (
    input  logic [6:0]  x_num,
    output logic [95:0] x_num_expand
);

always_comb begin
    x_num_expand = 96'b0;
    if (x_num < 96) begin
        x_num_expand[x_num] = 1'b1;
    end
end

endmodule
