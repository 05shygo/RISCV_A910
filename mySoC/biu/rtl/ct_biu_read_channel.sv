module ct_biu_read_channel #(
    parameter int PA_WIDTH   = 32,
    parameter int ID_WIDTH   = 4,
    parameter int DATA_WIDTH = 128,
    parameter int LEN_WIDTH  = 2
) (
    input  logic                  forever_cpuclk,
    input  logic                  cpurst_b,

    input  logic [PA_WIDTH-1:0]   araddr,
    input  logic [ID_WIDTH-1:0]   arid,
    input  logic [LEN_WIDTH-1:0]  arlen,
    input  logic [2:0]            arsize,
    input  logic [1:0]            arburst,
    input  logic [3:0]            arcache,
    input  logic [2:0]            arprot,
    input  logic                  arvalid,
    output logic                  arready,

    // IFU R
    output logic [DATA_WIDTH-1:0] biu_ifu_rdata,
    output logic                  biu_ifu_rvalid,
    output logic                  biu_ifu_rlast,
    output logic [1:0]            biu_ifu_rresp,
    output logic                  biu_ifu_rid,
    input  logic                  ifu_biu_rready,

    // LSU R
    output logic [DATA_WIDTH-1:0] biu_lsu_rdata,
    output logic [ID_WIDTH-1:0]   biu_lsu_rid,
    output logic                  biu_lsu_rvalid,
    output logic                  biu_lsu_rlast,
    output logic [1:0]            biu_lsu_rresp,
    input  logic                  lsu_biu_rready,

    // AXI AR
    output logic [PA_WIDTH-1:0]   biu_pad_araddr,
    output logic [ID_WIDTH-1:0]   biu_pad_arid,
    output logic [LEN_WIDTH-1:0]  biu_pad_arlen,
    output logic [2:0]            biu_pad_arsize,
    output logic [1:0]            biu_pad_arburst,
    output logic [3:0]            biu_pad_arcache,
    output logic [2:0]            biu_pad_arprot,
    output logic                  biu_pad_arvalid,
    input  logic                  pad_biu_arready,

    // AXI R
    input  logic [DATA_WIDTH-1:0] pad_biu_rdata,
    input  logic [ID_WIDTH-1:0]   pad_biu_rid,
    input  logic                  pad_biu_rlast,
    input  logic [1:0]            pad_biu_rresp,
    input  logic                  pad_biu_rvalid,
    output logic                  biu_pad_rready
);
    // AR 直接旁路到 AXI
    assign biu_pad_araddr  = araddr;
    assign biu_pad_arid    = arid;
    assign biu_pad_arlen   = arlen;
    assign biu_pad_arsize  = arsize;
    assign biu_pad_arburst = arburst;
    assign biu_pad_arcache = arcache;
    assign biu_pad_arprot  = arprot;
    assign biu_pad_arvalid = arvalid;
    assign arready         = pad_biu_arready;

    // R 路由：RID[3] == 1 给 IFU，否则给 LSU
    assign biu_pad_rready = pad_biu_rvalid
                          ? (pad_biu_rid[3] ? ifu_biu_rready : lsu_biu_rready)
                          : 1'b1;

    assign biu_ifu_rdata  = pad_biu_rdata;
    assign biu_ifu_rvalid = pad_biu_rvalid &  pad_biu_rid[3];
    assign biu_ifu_rlast  = pad_biu_rlast;
    assign biu_ifu_rresp  = pad_biu_rresp;
    assign biu_ifu_rid    = pad_biu_rid[0];

    assign biu_lsu_rdata  = pad_biu_rdata;
    assign biu_lsu_rid    = pad_biu_rid;
    assign biu_lsu_rvalid = pad_biu_rvalid & ~pad_biu_rid[3];
    assign biu_lsu_rlast  = pad_biu_rlast;
    assign biu_lsu_rresp  = pad_biu_rresp;
endmodule