module ct_lsu_rot_data (
    input  logic [127:0] data_in,
    input  logic [7:0]   rot_sel,
    output logic [127:0] data_settle_out
);

    logic [63:0] data_settle;
    logic [63:0] data;
    logic [63:0] data_rot0;
    logic [63:0] data_rot1;
    logic [63:0] data_rot2;
    logic [63:0] data_rot3;
    logic [63:0] data_rot4;
    logic [63:0] data_rot5;
    logic [63:0] data_rot6;
    logic [63:0] data_rot7;

    assign data[63:0] = data_in[63:0] | data_in[127:64];

    assign data_rot0[63:0] = data[63:0];
    assign data_rot1[63:0] = {data[7:0],  data[63:8]};
    assign data_rot2[63:0] = {data[15:0], data[63:16]};
    assign data_rot3[63:0] = {data[23:0], data[63:24]};
    assign data_rot4[63:0] = {data[31:0], data[63:32]};
    assign data_rot5[63:0] = {data[39:0], data[63:40]};
    assign data_rot6[63:0] = {data[47:0], data[63:48]};
    assign data_rot7[63:0] = {data[55:0], data[63:56]};

    always_comb begin
        case (rot_sel[7:0])
            8'h01:   data_settle[63:0] = data_rot0[63:0];
            8'h02:   data_settle[63:0] = data_rot1[63:0];
            8'h04:   data_settle[63:0] = data_rot2[63:0];
            8'h08:   data_settle[63:0] = data_rot3[63:0];
            8'h10:   data_settle[63:0] = data_rot4[63:0];
            8'h20:   data_settle[63:0] = data_rot5[63:0];
            8'h40:   data_settle[63:0] = data_rot6[63:0];
            8'h80:   data_settle[63:0] = data_rot7[63:0];
            default: data_settle[63:0] = {64{1'bx}};
        endcase
    end

    assign data_settle_out[127:0] = {64'b0, data_settle[63:0]};

endmodule