// Copyright 2019-2021 T-Head Semiconductor Co., Ltd.
// SPDX-License-Identifier: Apache-2.0
//
// Request arbiter for AXI BIU.
// - AR: LSU higher priority than IFU.
// - AW/W: pass LSU store and victim to write channel.

module ct_biu_req_arbiter #(
    parameter int PA_WIDTH   = 32,
    parameter int ID_WIDTH   = 4,
    parameter int LEN_WIDTH  = 2,
    parameter int DATA_WIDTH = 128,
    parameter int STRB_WIDTH = 16
) (
    //---------------------------------------------------------
    // IFU read request
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]   ifu_biu_araddr,
    input  logic [LEN_WIDTH-1:0]  ifu_biu_arlen,
    input  logic [2:0]            ifu_biu_arsize,
    input  logic [1:0]            ifu_biu_arburst,
    input  logic [3:0]            ifu_biu_arcache,
    input  logic [2:0]            ifu_biu_arprot,
    input  logic                  ifu_biu_arvalid,
    output logic                  ifu_biu_arready,
    input  logic                  ifu_biu_rid,

    //---------------------------------------------------------
    // LSU read request
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]   lsu_biu_araddr,
    input  logic [ID_WIDTH-1:0]   lsu_biu_arid,
    input  logic [LEN_WIDTH-1:0]  lsu_biu_arlen,
    input  logic [2:0]            lsu_biu_arsize,
    input  logic [1:0]            lsu_biu_arburst,
    input  logic [3:0]            lsu_biu_arcache,
    input  logic [2:0]            lsu_biu_arprot,
    input  logic                  lsu_biu_arvalid,
    output logic                  lsu_biu_arready,

    //---------------------------------------------------------
    // LSU write source 0: store
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]   lsu_biu_aw_st_addr,
    input  logic [ID_WIDTH-1:0]   lsu_biu_aw_st_id,
    input  logic [LEN_WIDTH-1:0]  lsu_biu_aw_st_len,
    input  logic [2:0]            lsu_biu_aw_st_size,
    input  logic [1:0]            lsu_biu_aw_st_burst,
    input  logic [3:0]            lsu_biu_aw_st_cache,
    input  logic [2:0]            lsu_biu_aw_st_prot,
    input  logic                  lsu_biu_aw_st_valid,
    output logic                  lsu_biu_aw_st_ready,

    input  logic [DATA_WIDTH-1:0] lsu_biu_w_st_data,
    input  logic [STRB_WIDTH-1:0] lsu_biu_w_st_strb,
    input  logic                  lsu_biu_w_st_last,
    input  logic                  lsu_biu_w_st_valid,
    output logic                  lsu_biu_w_st_ready,

    //---------------------------------------------------------
    // LSU write source 1: victim
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]   lsu_biu_aw_vict_addr,
    input  logic [ID_WIDTH-1:0]   lsu_biu_aw_vict_id,
    input  logic [LEN_WIDTH-1:0]  lsu_biu_aw_vict_len,
    input  logic [2:0]            lsu_biu_aw_vict_size,
    input  logic [1:0]            lsu_biu_aw_vict_burst,
    input  logic [3:0]            lsu_biu_aw_vict_cache,
    input  logic [2:0]            lsu_biu_aw_vict_prot,
    input  logic                  lsu_biu_aw_vict_valid,
    output logic                  lsu_biu_aw_vict_ready,

    input  logic [DATA_WIDTH-1:0] lsu_biu_w_vict_data,
    input  logic [STRB_WIDTH-1:0] lsu_biu_w_vict_strb,
    input  logic                  lsu_biu_w_vict_last,
    input  logic                  lsu_biu_w_vict_valid,
    output logic                  lsu_biu_w_vict_ready,

    //---------------------------------------------------------
    // To read channel: arbitrated AR
    //---------------------------------------------------------
    output logic [PA_WIDTH-1:0]   araddr,
    output logic [ID_WIDTH-1:0]   arid,
    output logic [LEN_WIDTH-1:0]  arlen,
    output logic [2:0]            arsize,
    output logic [1:0]            arburst,
    output logic [3:0]            arcache,
    output logic [2:0]            arprot,
    output logic                  arvalid,
    input  logic                  arready,

    //---------------------------------------------------------
    // To write channel: store
    //---------------------------------------------------------
    output logic [PA_WIDTH-1:0]   st_awaddr,
    output logic [ID_WIDTH-1:0]   st_awid,
    output logic [LEN_WIDTH-1:0]  st_awlen,
    output logic [2:0]            st_awsize,
    output logic [1:0]            st_awburst,
    output logic [3:0]            st_awcache,
    output logic [2:0]            st_awprot,
    output logic                  st_awvalid,
    input  logic                  st_awready,

    output logic [DATA_WIDTH-1:0] st_wdata,
    output logic [STRB_WIDTH-1:0] st_wstrb,
    output logic                  st_wlast,
    output logic                  st_wvalid,
    input  logic                  st_wready,

    //---------------------------------------------------------
    // To write channel: victim
    //---------------------------------------------------------
    output logic [PA_WIDTH-1:0]   vict_awaddr,
    output logic [ID_WIDTH-1:0]   vict_awid,
    output logic [LEN_WIDTH-1:0]  vict_awlen,
    output logic [2:0]            vict_awsize,
    output logic [1:0]            vict_awburst,
    output logic [3:0]            vict_awcache,
    output logic [2:0]            vict_awprot,
    output logic                  vict_awvalid,
    input  logic                  vict_awready,

    output logic [DATA_WIDTH-1:0] vict_wdata,
    output logic [STRB_WIDTH-1:0] vict_wstrb,
    output logic                  vict_wlast,
    output logic                  vict_wvalid,
    input  logic                  vict_wready
);

    //---------------------------------------------------------
    // Read AR arbitration: LSU priority
    //---------------------------------------------------------
    assign arvalid = lsu_biu_arvalid | ifu_biu_arvalid;

    always_comb begin
        if (lsu_biu_arvalid) begin
            araddr  = lsu_biu_araddr;
            arid    = lsu_biu_arid;
            arlen   = lsu_biu_arlen;
            arsize  = lsu_biu_arsize;
            arburst = lsu_biu_arburst;
            arcache = lsu_biu_arcache;
            arprot  = lsu_biu_arprot;
        end else begin
            araddr  = ifu_biu_araddr;
            // IFU 原始 1-bit ID 映射到 4-bit AXI ID
            arid    = {3'b100, ifu_biu_rid};
            arlen   = ifu_biu_arlen;
            arsize  = ifu_biu_arsize;
            arburst = ifu_biu_arburst;
            arcache = ifu_biu_arcache;
            arprot  = ifu_biu_arprot;
        end
    end

    assign lsu_biu_arready = lsu_biu_arvalid & arready;
    assign ifu_biu_arready = ~lsu_biu_arvalid & ifu_biu_arvalid & arready;

    //---------------------------------------------------------
    // Store channel direct pass-through
    //---------------------------------------------------------
    assign st_awaddr  = lsu_biu_aw_st_addr;
    assign st_awid    = lsu_biu_aw_st_id;
    assign st_awlen   = lsu_biu_aw_st_len;
    assign st_awsize  = lsu_biu_aw_st_size;
    assign st_awburst = lsu_biu_aw_st_burst;
    assign st_awcache = lsu_biu_aw_st_cache;
    assign st_awprot  = lsu_biu_aw_st_prot;
    assign st_awvalid = lsu_biu_aw_st_valid;
    assign lsu_biu_aw_st_ready = st_awready;

    assign st_wdata   = lsu_biu_w_st_data;
    assign st_wstrb   = lsu_biu_w_st_strb;
    assign st_wlast   = lsu_biu_w_st_last;
    assign st_wvalid  = lsu_biu_w_st_valid;
    assign lsu_biu_w_st_ready = st_wready;

    //---------------------------------------------------------
    // Victim channel direct pass-through
    //---------------------------------------------------------
    assign vict_awaddr  = lsu_biu_aw_vict_addr;
    assign vict_awid    = lsu_biu_aw_vict_id;
    assign vict_awlen   = lsu_biu_aw_vict_len;
    assign vict_awsize  = lsu_biu_aw_vict_size;
    assign vict_awburst = lsu_biu_aw_vict_burst;
    assign vict_awcache = lsu_biu_aw_vict_cache;
    assign vict_awprot  = lsu_biu_aw_vict_prot;
    assign vict_awvalid = lsu_biu_aw_vict_valid;
    assign lsu_biu_aw_vict_ready = vict_awready;

    assign vict_wdata   = lsu_biu_w_vict_data;
    assign vict_wstrb   = lsu_biu_w_vict_strb;
    assign vict_wlast   = lsu_biu_w_vict_last;
    assign vict_wvalid  = lsu_biu_w_vict_valid;
    assign lsu_biu_w_vict_ready = vict_wready;

endmodule