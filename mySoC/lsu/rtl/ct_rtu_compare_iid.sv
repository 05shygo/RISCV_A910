module ct_rtu_compare_iid (
    input  logic [6:0] x_iid0,
    input  logic [6:0] x_iid1,
    output logic       x_iid0_older
);

    logic        iid0_5_0_larger;
    logic [5:0]  iid0_larger;
    logic        iid1_5_0_larger;
    logic [5:0]  iid1_larger;
    logic        iid_msb_mismatch;

    assign iid_msb_mismatch = x_iid0[6] ^ x_iid1[6];

    assign iid0_larger[5] = x_iid0[5] && !x_iid1[5];
    assign iid0_larger[4] = x_iid0[4] && !x_iid1[4];
    assign iid0_larger[3] = x_iid0[3] && !x_iid1[3];
    assign iid0_larger[2] = x_iid0[2] && !x_iid1[2];
    assign iid0_larger[1] = x_iid0[1] && !x_iid1[1];
    assign iid0_larger[0] = x_iid0[0] && !x_iid1[0];

    assign iid1_larger[5] = !x_iid0[5] && x_iid1[5];
    assign iid1_larger[4] = !x_iid0[4] && x_iid1[4];
    assign iid1_larger[3] = !x_iid0[3] && x_iid1[3];
    assign iid1_larger[2] = !x_iid0[2] && x_iid1[2];
    assign iid1_larger[1] = !x_iid0[1] && x_iid1[1];
    assign iid1_larger[0] = !x_iid0[0] && x_iid1[0];

    assign iid0_5_0_larger =
         iid0_larger[5]
      || iid0_larger[4] && !iid1_larger[5]
      || iid0_larger[3] && !(|iid1_larger[5:4])
      || iid0_larger[2] && !(|iid1_larger[5:3])
      || iid0_larger[1] && !(|iid1_larger[5:2])
      || iid0_larger[0] && !(|iid1_larger[5:1]);

    assign iid1_5_0_larger =
         iid1_larger[5]
      || iid1_larger[4] && !iid0_larger[5]
      || iid1_larger[3] && !(|iid0_larger[5:4])
      || iid1_larger[2] && !(|iid0_larger[5:3])
      || iid1_larger[1] && !(|iid0_larger[5:2])
      || iid1_larger[0] && !(|iid0_larger[5:1]);

    assign x_iid0_older = !iid_msb_mismatch && iid1_5_0_larger
                       || iid_msb_mismatch && iid0_5_0_larger;

endmodule