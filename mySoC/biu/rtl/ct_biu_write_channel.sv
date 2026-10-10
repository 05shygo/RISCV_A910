// Copyright 2019-2021 T-Head Semiconductor Co., Ltd.
// SPDX-License-Identifier: Apache-2.0
//
// AXI write channel.
// Two AW/W sources: store (st) and victim (vict).
// Simple arbitration: store priority over victim.
// One AXI write transaction at a time.
// B response passthrough to LSU.

module ct_biu_write_channel #(
    parameter int PA_WIDTH   = 32,
    parameter int ID_WIDTH   = 4,
    parameter int DATA_WIDTH = 128,
    parameter int STRB_WIDTH = 16,
    parameter int LEN_WIDTH  = 2
) (
    input  logic                     forever_cpuclk,
    input  logic                     cpurst_b,

    //---------------------------------------------------------
    // Source 0: store AW
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

    //---------------------------------------------------------
    // Source 0: store W
    //---------------------------------------------------------
    input  logic [DATA_WIDTH-1:0]    lsu_biu_w_st_data,
    input  logic [STRB_WIDTH-1:0]    lsu_biu_w_st_strb,
    input  logic                     lsu_biu_w_st_last,
    input  logic                     lsu_biu_w_st_valid,
    output logic                     lsu_biu_w_st_ready,

    //---------------------------------------------------------
    // Source 1: victim AW
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

    //---------------------------------------------------------
    // Source 1: victim W
    //---------------------------------------------------------
    input  logic [DATA_WIDTH-1:0]    lsu_biu_w_vict_data,
    input  logic [STRB_WIDTH-1:0]    lsu_biu_w_vict_strb,
    input  logic                     lsu_biu_w_vict_last,
    input  logic                     lsu_biu_w_vict_valid,
    output logic                     lsu_biu_w_vict_ready,

    //---------------------------------------------------------
    // Write response to LSU
    //---------------------------------------------------------
    output logic [ID_WIDTH-1:0]      biu_lsu_bid,
    output logic [1:0]               biu_lsu_bresp,
    output logic                     biu_lsu_bvalid,
    input  logic                     lsu_biu_bready,

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
    // Write transaction state
    //---------------------------------------------------------
    typedef enum logic [1:0] {
        WR_IDLE,
        WR_ACTIVE
    } wr_state_e;

    wr_state_e wr_state;
    logic      wr_sel_st;   // 1: store, 0: victim
    logic      aw_done;
    logic      w_done;

    //---------------------------------------------------------
    // State machine
    //---------------------------------------------------------
    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            wr_state  <= WR_IDLE;
            wr_sel_st <= 1'b1;
            aw_done   <= 1'b0;
            w_done    <= 1'b0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    // store 优先，只要 AW 或 W 有效即可启动，避免因等待另一通道而死锁
                    if (lsu_biu_aw_st_valid || lsu_biu_w_st_valid) begin
                        wr_sel_st <= 1'b1;
                        wr_state  <= WR_ACTIVE;
                        aw_done   <= 1'b0;
                        w_done    <= 1'b0;
                    end else if (lsu_biu_aw_vict_valid || lsu_biu_w_vict_valid) begin
                        wr_sel_st <= 1'b0;
                        wr_state  <= WR_ACTIVE;
                        aw_done   <= 1'b0;
                        w_done    <= 1'b0;
                    end
                end

                WR_ACTIVE: begin
                    // AW 完成
                    if (!aw_done && biu_pad_awvalid && pad_biu_awready)
                        aw_done <= 1'b1;

                    // W 完成（最后一拍被接收）
                    if (!w_done && biu_pad_wvalid && pad_biu_wready && biu_pad_wlast)
                        w_done <= 1'b1;

                    // AW 和 W 都完成，回到 IDLE
                    if ((aw_done || (biu_pad_awvalid && pad_biu_awready)) &&
                        (w_done  || (biu_pad_wvalid && pad_biu_wready && biu_pad_wlast))) begin
                        wr_state <= WR_IDLE;
                        aw_done  <= 1'b0;
                        w_done   <= 1'b0;
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    //---------------------------------------------------------
    // AXI AW / W output mux
    //---------------------------------------------------------
    always_comb begin
        // 默认输出
        biu_pad_awvalid = 1'b0;
        biu_pad_awaddr  = '0;
        biu_pad_awid    = '0;
        biu_pad_awlen   = '0;
        biu_pad_awsize  = '0;
        biu_pad_awburst = '0;
        biu_pad_awcache = '0;
        biu_pad_awprot  = '0;

        biu_pad_wvalid  = 1'b0;
        biu_pad_wdata   = '0;
        biu_pad_wstrb   = '0;
        biu_pad_wlast   = 1'b0;

        lsu_biu_aw_st_ready   = 1'b0;
        lsu_biu_aw_vict_ready = 1'b0;
        lsu_biu_w_st_ready    = 1'b0;
        lsu_biu_w_vict_ready  = 1'b0;

        if (wr_state == WR_ACTIVE) begin
            if (wr_sel_st) begin
                if (!aw_done) begin
                    biu_pad_awvalid = lsu_biu_aw_st_valid;
                    biu_pad_awaddr  = lsu_biu_aw_st_addr;
                    biu_pad_awid    = lsu_biu_aw_st_id;
                    biu_pad_awlen   = lsu_biu_aw_st_len;
                    biu_pad_awsize  = lsu_biu_aw_st_size;
                    biu_pad_awburst = lsu_biu_aw_st_burst;
                    biu_pad_awcache = lsu_biu_aw_st_cache;
                    biu_pad_awprot  = lsu_biu_aw_st_prot;
                    lsu_biu_aw_st_ready = pad_biu_awready;
                end

                if (!w_done) begin
                    biu_pad_wvalid = lsu_biu_w_st_valid;
                    biu_pad_wdata  = lsu_biu_w_st_data;
                    biu_pad_wstrb  = lsu_biu_w_st_strb;
                    biu_pad_wlast  = lsu_biu_w_st_last;
                    lsu_biu_w_st_ready = pad_biu_wready;
                end
            end else begin
                if (!aw_done) begin
                    biu_pad_awvalid = lsu_biu_aw_vict_valid;
                    biu_pad_awaddr  = lsu_biu_aw_vict_addr;
                    biu_pad_awid    = lsu_biu_aw_vict_id;
                    biu_pad_awlen   = lsu_biu_aw_vict_len;
                    biu_pad_awsize  = lsu_biu_aw_vict_size;
                    biu_pad_awburst = lsu_biu_aw_vict_burst;
                    biu_pad_awcache = lsu_biu_aw_vict_cache;
                    biu_pad_awprot  = lsu_biu_aw_vict_prot;
                    lsu_biu_aw_vict_ready = pad_biu_awready;
                end

                if (!w_done) begin
                    biu_pad_wvalid = lsu_biu_w_vict_valid;
                    biu_pad_wdata  = lsu_biu_w_vict_data;
                    biu_pad_wstrb  = lsu_biu_w_vict_strb;
                    biu_pad_wlast  = lsu_biu_w_vict_last;
                    lsu_biu_w_vict_ready = pad_biu_wready;
                end
            end
        end
    end

    //---------------------------------------------------------
    // Write response passthrough: AXI B -> LSU
    //---------------------------------------------------------
    assign biu_pad_bready = lsu_biu_bready;
    assign biu_lsu_bvalid = pad_biu_bvalid;
    assign biu_lsu_bid    = pad_biu_bid;
    assign biu_lsu_bresp  = pad_biu_bresp;

endmodule