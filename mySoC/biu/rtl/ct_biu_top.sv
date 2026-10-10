// Copyright 2019-2021 T-Head Semiconductor Co., Ltd.
// SPDX-License-Identifier: Apache-2.0
//
// AXI-style BIU top.
// - 32-bit address, 4-bit AXI ID, 2-bit AXI LEN, 128-bit data
// - No snoop, no CP0/HPCp/CSR/low-power
// - AR: IFU + LSU (LSU priority)
// - AW/W: LSU store + LSU victim
// - All clocks use forever_cpuclk

module ct_biu_top #(
    parameter int PA_WIDTH   = 32,
    parameter int ID_WIDTH   = 4,
    parameter int DATA_WIDTH = 128,
    parameter int STRB_WIDTH = 16,
    parameter int LEN_WIDTH  = 2
) (
    input  logic                     forever_cpuclk,
    input  logic                     cpurst_b,

    //---------------------------------------------------------
    // IFU read request
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]      ifu_biu_araddr,
    input  logic [LEN_WIDTH-1:0]     ifu_biu_arlen,
    input  logic [2:0]               ifu_biu_arsize,
    input  logic [1:0]               ifu_biu_arburst,
    input  logic [3:0]               ifu_biu_arcache,
    input  logic [2:0]               ifu_biu_arprot,
    input  logic                     ifu_biu_arvalid,
    output logic                     ifu_biu_arready,
    input  logic [ID_WIDTH-1:0]      ifu_biu_rid,

    //---------------------------------------------------------
    // IFU read response
    //---------------------------------------------------------
    output logic [DATA_WIDTH-1:0]    biu_ifu_rdata,
    output logic                     biu_ifu_rvalid,
    output logic                     biu_ifu_rlast,
    output logic [1:0]               biu_ifu_rresp,
    output logic                     biu_ifu_rid,
    input  logic                     ifu_biu_rready,

    //---------------------------------------------------------
    // LSU read request
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]      lsu_biu_araddr,
    input  logic [ID_WIDTH-1:0]      lsu_biu_arid,
    input  logic [LEN_WIDTH-1:0]     lsu_biu_arlen,
    input  logic [2:0]               lsu_biu_arsize,
    input  logic [1:0]               lsu_biu_arburst,
    input  logic [3:0]               lsu_biu_arcache,
    input  logic [2:0]               lsu_biu_arprot,
    input  logic                     lsu_biu_arvalid,
    output logic                     lsu_biu_arready,

    //---------------------------------------------------------
    // LSU read response
    //---------------------------------------------------------
    output logic [DATA_WIDTH-1:0]    biu_lsu_rdata,
    output logic [ID_WIDTH-1:0]      biu_lsu_rid,
    output logic                     biu_lsu_rvalid,
    output logic                     biu_lsu_rlast,
    output logic [1:0]               biu_lsu_rresp,
    input  logic                     lsu_biu_rready,

    //---------------------------------------------------------
    // LSU write source 0: store
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]      lsu_biu_aw_st_addr,
    input  logic [ID_WIDTH-1:0]      lsu_biu_aw_st_id,
    input  logic [LEN_WIDTH-1:0]     lsu_biu_aw_st_len,
    input  logic [2:0]               lsu_biu_aw_st_size,
    input  logic [1:0]               lsu_biu_aw_st_burst,
    input  logic [3:0]               lsu_biu_aw_st_cache,
    input  logic [2:0]               lsu_biu_aw_st_prot,
    input  logic                     lsu_biu_aw_st_valid,
    output logic                     lsu_biu_aw_st_ready,

    input  logic [DATA_WIDTH-1:0]    lsu_biu_w_st_data,
    input  logic [STRB_WIDTH-1:0]    lsu_biu_w_st_strb,
    input  logic                     lsu_biu_w_st_last,
    input  logic                     lsu_biu_w_st_valid,
    output logic                     lsu_biu_w_st_ready,

    //---------------------------------------------------------
    // LSU write source 1: victim
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]      lsu_biu_aw_vict_addr,
    input  logic [ID_WIDTH-1:0]      lsu_biu_aw_vict_id,
    input  logic [LEN_WIDTH-1:0]     lsu_biu_aw_vict_len,
    input  logic [2:0]               lsu_biu_aw_vict_size,
    input  logic [1:0]               lsu_biu_aw_vict_burst,
    input  logic [3:0]               lsu_biu_aw_vict_cache,
    input  logic [2:0]               lsu_biu_aw_vict_prot,
    input  logic                     lsu_biu_aw_vict_valid,
    output logic                     lsu_biu_aw_vict_ready,

    input  logic [DATA_WIDTH-1:0]    lsu_biu_w_vict_data,
    input  logic [STRB_WIDTH-1:0]    lsu_biu_w_vict_strb,
    input  logic                     lsu_biu_w_vict_last,
    input  logic                     lsu_biu_w_vict_valid,
    output logic                     lsu_biu_w_vict_ready,

    //---------------------------------------------------------
    // LSU write response
    //---------------------------------------------------------
    output logic [ID_WIDTH-1:0]      biu_lsu_bid,
    output logic [1:0]               biu_lsu_bresp,
    output logic                     biu_lsu_bvalid,
    input  logic                     lsu_biu_bready,

    //---------------------------------------------------------
    // AXI master read address
    //---------------------------------------------------------
    output logic [PA_WIDTH-1:0]      biu_pad_araddr,
    output logic [ID_WIDTH-1:0]      biu_pad_arid,
    output logic [LEN_WIDTH-1:0]     biu_pad_arlen,
    output logic [2:0]               biu_pad_arsize,
    output logic [1:0]               biu_pad_arburst,
    output logic [3:0]               biu_pad_arcache,
    output logic [2:0]               biu_pad_arprot,
    output logic                     biu_pad_arvalid,
    input  logic                     pad_biu_arready,

    //---------------------------------------------------------
    // AXI master read data
    //---------------------------------------------------------
    input  logic [DATA_WIDTH-1:0]    pad_biu_rdata,
    input  logic [ID_WIDTH-1:0]      pad_biu_rid,
    input  logic                     pad_biu_rlast,
    input  logic [1:0]               pad_biu_rresp,
    input  logic                     pad_biu_rvalid,
    output logic                     biu_pad_rready,

    //---------------------------------------------------------
    // AXI master write address
    //---------------------------------------------------------
    output logic [PA_WIDTH-1:0]      biu_pad_awaddr,
    output logic [ID_WIDTH-1:0]      biu_pad_awid,
    output logic [LEN_WIDTH-1:0]     biu_pad_awlen,
    output logic [2:0]               biu_pad_awsize,
    output logic [1:0]               biu_pad_awburst,
    output logic [3:0]               biu_pad_awcache,
    output logic [2:0]               biu_pad_awprot,
    output logic                     biu_pad_awvalid,
    input  logic                     pad_biu_awready,

    //---------------------------------------------------------
    // AXI master write data
    //---------------------------------------------------------
    output logic [DATA_WIDTH-1:0]    biu_pad_wdata,
    output logic [STRB_WIDTH-1:0]    biu_pad_wstrb,
    output logic                     biu_pad_wlast,
    output logic                     biu_pad_wvalid,
    input  logic                     pad_biu_wready,

    //---------------------------------------------------------
    // AXI master write response
    //---------------------------------------------------------
    input  logic [ID_WIDTH-1:0]      pad_biu_bid,
    input  logic [1:0]               pad_biu_bresp,
    input  logic                     pad_biu_bvalid,
    output logic                     biu_pad_bready
);

    //---------------------------------------------------------
    // Internal wires: req_arbiter -> read_channel
    //---------------------------------------------------------
    logic [PA_WIDTH-1:0]   araddr;
    logic [ID_WIDTH-1:0]   arid;
    logic [LEN_WIDTH-1:0]  arlen;
    logic [2:0]            arsize;
    logic [1:0]            arburst;
    logic [3:0]            arcache;
    logic [2:0]            arprot;
    logic                  arvalid;
    logic                  arready;

    //---------------------------------------------------------
    // Internal wires: req_arbiter -> write_channel (store)
    //---------------------------------------------------------
    logic [PA_WIDTH-1:0]   st_awaddr;
    logic [ID_WIDTH-1:0]   st_awid;
    logic [LEN_WIDTH-1:0]  st_awlen;
    logic [2:0]            st_awsize;
    logic [1:0]            st_awburst;
    logic [3:0]            st_awcache;
    logic [2:0]            st_awprot;
    logic                  st_awvalid;
    logic                  st_awready;

    logic [DATA_WIDTH-1:0] st_wdata;
    logic [STRB_WIDTH-1:0] st_wstrb;
    logic                  st_wlast;
    logic                  st_wvalid;
    logic                  st_wready;

    //---------------------------------------------------------
    // Internal wires: req_arbiter -> write_channel (victim)
    //---------------------------------------------------------
    logic [PA_WIDTH-1:0]   vict_awaddr;
    logic [ID_WIDTH-1:0]   vict_awid;
    logic [LEN_WIDTH-1:0]  vict_awlen;
    logic [2:0]            vict_awsize;
    logic [1:0]            vict_awburst;
    logic [3:0]            vict_awcache;
    logic [2:0]            vict_awprot;
    logic                  vict_awvalid;
    logic                  vict_awready;

    logic [DATA_WIDTH-1:0] vict_wdata;
    logic [STRB_WIDTH-1:0] vict_wstrb;
    logic                  vict_wlast;
    logic                  vict_wvalid;
    logic                  vict_wready;

    //=========================================================
    // Request arbiter
    //   - AR arbitration: LSU > IFU
    //   - AW/W pass-through: store + victim
    //=========================================================
    ct_biu_req_arbiter #(
        .PA_WIDTH   (PA_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .LEN_WIDTH  (LEN_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .STRB_WIDTH (STRB_WIDTH)
    ) u_ct_biu_req_arbiter (
        // IFU AR
        .ifu_biu_araddr       (ifu_biu_araddr),
        .ifu_biu_arlen        (ifu_biu_arlen),
        .ifu_biu_arsize       (ifu_biu_arsize),
        .ifu_biu_arburst      (ifu_biu_arburst),
        .ifu_biu_arcache      (ifu_biu_arcache),
        .ifu_biu_arprot       (ifu_biu_arprot),
        .ifu_biu_arvalid      (ifu_biu_arvalid),
        .ifu_biu_arready      (ifu_biu_arready),
        .ifu_biu_rid          (ifu_biu_rid),

        // LSU AR
        .lsu_biu_araddr       (lsu_biu_araddr),
        .lsu_biu_arid         (lsu_biu_arid),
        .lsu_biu_arlen        (lsu_biu_arlen),
        .lsu_biu_arsize       (lsu_biu_arsize),
        .lsu_biu_arburst      (lsu_biu_arburst),
        .lsu_biu_arcache      (lsu_biu_arcache),
        .lsu_biu_arprot       (lsu_biu_arprot),
        .lsu_biu_arvalid      (lsu_biu_arvalid),
        .lsu_biu_arready      (lsu_biu_arready),

        // LSU AW/W store
        .lsu_biu_aw_st_addr   (lsu_biu_aw_st_addr),
        .lsu_biu_aw_st_id     (lsu_biu_aw_st_id),
        .lsu_biu_aw_st_len    (lsu_biu_aw_st_len),
        .lsu_biu_aw_st_size   (lsu_biu_aw_st_size),
        .lsu_biu_aw_st_burst  (lsu_biu_aw_st_burst),
        .lsu_biu_aw_st_cache  (lsu_biu_aw_st_cache),
        .lsu_biu_aw_st_prot   (lsu_biu_aw_st_prot),
        .lsu_biu_aw_st_valid  (lsu_biu_aw_st_valid),
        .lsu_biu_aw_st_ready  (lsu_biu_aw_st_ready),

        .lsu_biu_w_st_data    (lsu_biu_w_st_data),
        .lsu_biu_w_st_strb    (lsu_biu_w_st_strb),
        .lsu_biu_w_st_last    (lsu_biu_w_st_last),
        .lsu_biu_w_st_valid   (lsu_biu_w_st_valid),
        .lsu_biu_w_st_ready   (lsu_biu_w_st_ready),

        // LSU AW/W victim
        .lsu_biu_aw_vict_addr  (lsu_biu_aw_vict_addr),
        .lsu_biu_aw_vict_id    (lsu_biu_aw_vict_id),
        .lsu_biu_aw_vict_len   (lsu_biu_aw_vict_len),
        .lsu_biu_aw_vict_size  (lsu_biu_aw_vict_size),
        .lsu_biu_aw_vict_burst (lsu_biu_aw_vict_burst),
        .lsu_biu_aw_vict_cache (lsu_biu_aw_vict_cache),
        .lsu_biu_aw_vict_prot  (lsu_biu_aw_vict_prot),
        .lsu_biu_aw_vict_valid (lsu_biu_aw_vict_valid),
        .lsu_biu_aw_vict_ready (lsu_biu_aw_vict_ready),

        .lsu_biu_w_vict_data   (lsu_biu_w_vict_data),
        .lsu_biu_w_vict_strb   (lsu_biu_w_vict_strb),
        .lsu_biu_w_vict_last   (lsu_biu_w_vict_last),
        .lsu_biu_w_vict_valid  (lsu_biu_w_vict_valid),
        .lsu_biu_w_vict_ready  (lsu_biu_w_vict_ready),

        // Arbitrated AR -> read_channel
        .araddr               (araddr),
        .arid                 (arid),
        .arlen                (arlen),
        .arsize               (arsize),
        .arburst              (arburst),
        .arcache              (arcache),
        .arprot               (arprot),
        .arvalid              (arvalid),
        .arready              (arready),

        // Store AW/W -> write_channel
        .st_awaddr            (st_awaddr),
        .st_awid              (st_awid),
        .st_awlen             (st_awlen),
        .st_awsize            (st_awsize),
        .st_awburst           (st_awburst),
        .st_awcache           (st_awcache),
        .st_awprot            (st_awprot),
        .st_awvalid           (st_awvalid),
        .st_awready           (st_awready),

        .st_wdata             (st_wdata),
        .st_wstrb             (st_wstrb),
        .st_wlast             (st_wlast),
        .st_wvalid            (st_wvalid),
        .st_wready            (st_wready),

        // Victim AW/W -> write_channel
        .vict_awaddr          (vict_awaddr),
        .vict_awid            (vict_awid),
        .vict_awlen           (vict_awlen),
        .vict_awsize          (vict_awsize),
        .vict_awburst         (vict_awburst),
        .vict_awcache         (vict_awcache),
        .vict_awprot          (vict_awprot),
        .vict_awvalid         (vict_awvalid),
        .vict_awready         (vict_awready),

        .vict_wdata           (vict_wdata),
        .vict_wstrb           (vict_wstrb),
        .vict_wlast           (vict_wlast),
        .vict_wvalid          (vict_wvalid),
        .vict_wready          (vict_wready)
    );

    //=========================================================
    // Read channel
    //=========================================================
    ct_biu_read_channel #(
        .PA_WIDTH   (PA_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .LEN_WIDTH  (LEN_WIDTH)
    ) u_ct_biu_read_channel (
        .forever_cpuclk     (forever_cpuclk),
        .cpurst_b           (cpurst_b),

        // Arbitrated AR
        .araddr             (araddr),
        .arid               (arid),
        .arlen              (arlen),
        .arsize             (arsize),
        .arburst            (arburst),
        .arcache            (arcache),
        .arprot             (arprot),
        .arvalid            (arvalid),
        .arready            (arready),

        // IFU R
        .biu_ifu_rdata      (biu_ifu_rdata),
        .biu_ifu_rvalid     (biu_ifu_rvalid),
        .biu_ifu_rlast      (biu_ifu_rlast),
        .biu_ifu_rresp      (biu_ifu_rresp),
        .biu_ifu_rid        (biu_ifu_rid),
        .ifu_biu_rready     (ifu_biu_rready),

        // LSU R
        .biu_lsu_rdata      (biu_lsu_rdata),
        .biu_lsu_rid        (biu_lsu_rid),
        .biu_lsu_rvalid     (biu_lsu_rvalid),
        .biu_lsu_rlast      (biu_lsu_rlast),
        .biu_lsu_rresp      (biu_lsu_rresp),
        .lsu_biu_rready     (lsu_biu_rready),

        // AXI AR
        .biu_pad_araddr     (biu_pad_araddr),
        .biu_pad_arid       (biu_pad_arid),
        .biu_pad_arlen      (biu_pad_arlen),
        .biu_pad_arsize     (biu_pad_arsize),
        .biu_pad_arburst    (biu_pad_arburst),
        .biu_pad_arcache    (biu_pad_arcache),
        .biu_pad_arprot     (biu_pad_arprot),
        .biu_pad_arvalid    (biu_pad_arvalid),
        .pad_biu_arready    (pad_biu_arready),

        // AXI R
        .pad_biu_rdata      (pad_biu_rdata),
        .pad_biu_rid        (pad_biu_rid),
        .pad_biu_rlast      (pad_biu_rlast),
        .pad_biu_rresp      (pad_biu_rresp),
        .pad_biu_rvalid     (pad_biu_rvalid),
        .biu_pad_rready     (biu_pad_rready)
    );

    //=========================================================
    // Write channel
    //=========================================================
    ct_biu_write_channel #(
        .PA_WIDTH   (PA_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .STRB_WIDTH (STRB_WIDTH),
        .LEN_WIDTH  (LEN_WIDTH)
    ) u_ct_biu_write_channel (
        .forever_cpuclk      (forever_cpuclk),
        .cpurst_b            (cpurst_b),

        // Store AW/W
        .lsu_biu_aw_st_addr  (st_awaddr),
        .lsu_biu_aw_st_id    (st_awid),
        .lsu_biu_aw_st_len   (st_awlen),
        .lsu_biu_aw_st_size  (st_awsize),
        .lsu_biu_aw_st_burst (st_awburst),
        .lsu_biu_aw_st_cache (st_awcache),
        .lsu_biu_aw_st_prot  (st_awprot),
        .lsu_biu_aw_st_valid (st_awvalid),
        .lsu_biu_aw_st_ready (st_awready),

        .lsu_biu_w_st_data   (st_wdata),
        .lsu_biu_w_st_strb   (st_wstrb),
        .lsu_biu_w_st_last   (st_wlast),
        .lsu_biu_w_st_valid  (st_wvalid),
        .lsu_biu_w_st_ready  (st_wready),

        // Victim AW/W
        .lsu_biu_aw_vict_addr  (vict_awaddr),
        .lsu_biu_aw_vict_id    (vict_awid),
        .lsu_biu_aw_vict_len   (vict_awlen),
        .lsu_biu_aw_vict_size  (vict_awsize),
        .lsu_biu_aw_vict_burst (vict_awburst),
        .lsu_biu_aw_vict_cache (vict_awcache),
        .lsu_biu_aw_vict_prot  (vict_awprot),
        .lsu_biu_aw_vict_valid (vict_awvalid),
        .lsu_biu_aw_vict_ready (vict_awready),

        .lsu_biu_w_vict_data   (vict_wdata),
        .lsu_biu_w_vict_strb   (vict_wstrb),
        .lsu_biu_w_vict_last   (vict_wlast),
        .lsu_biu_w_vict_valid  (vict_wvalid),
        .lsu_biu_w_vict_ready  (vict_wready),

        // Write response
        .biu_lsu_bid         (biu_lsu_bid),
        .biu_lsu_bresp       (biu_lsu_bresp),
        .biu_lsu_bvalid      (biu_lsu_bvalid),
        .lsu_biu_bready      (lsu_biu_bready),

        // AXI AW
        .biu_pad_awaddr      (biu_pad_awaddr),
        .biu_pad_awid        (biu_pad_awid),
        .biu_pad_awlen       (biu_pad_awlen),
        .biu_pad_awsize      (biu_pad_awsize),
        .biu_pad_awburst     (biu_pad_awburst),
        .biu_pad_awcache     (biu_pad_awcache),
        .biu_pad_awprot      (biu_pad_awprot),
        .biu_pad_awvalid     (biu_pad_awvalid),
        .pad_biu_awready     (pad_biu_awready),

        // AXI W
        .biu_pad_wdata       (biu_pad_wdata),
        .biu_pad_wstrb       (biu_pad_wstrb),
        .biu_pad_wlast       (biu_pad_wlast),
        .biu_pad_wvalid      (biu_pad_wvalid),
        .pad_biu_wready      (pad_biu_wready),

        // AXI B
        .pad_biu_bid         (pad_biu_bid),
        .pad_biu_bresp       (pad_biu_bresp),
        .pad_biu_bvalid      (pad_biu_bvalid),
        .biu_pad_bready      (biu_pad_bready)
    );

endmodule