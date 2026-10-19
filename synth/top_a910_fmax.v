`timescale 1ns / 1ps

// ===========================================================================
// A910 + ifu3 综合/Fmax 测量专用顶层 (不参与仿真)
//
// 与 top_fmax.v 同口径: 只包一层显式 BUFG, 让 create_clock 的约束口径干净。
// A910_cpu 直接以 AXI 主端作为顶层边界 (片内没有存储器), 不另加存储模型。
// ===========================================================================
module top_a910_fmax (
    input  wire         clk,
    input  wire         rst,

    // AXI read address
    output wire [ 31:0] biu_pad_araddr,
    output wire [  3:0] biu_pad_arid,
    output wire [  1:0] biu_pad_arlen,
    output wire [  2:0] biu_pad_arsize,
    output wire [  1:0] biu_pad_arburst,
    output wire [  3:0] biu_pad_arcache,
    output wire [  2:0] biu_pad_arprot,
    output wire         biu_pad_arvalid,
    input  wire         pad_biu_arready,

    // AXI read data
    input  wire [127:0] pad_biu_rdata,
    input  wire [  3:0] pad_biu_rid,
    input  wire         pad_biu_rlast,
    input  wire [  1:0] pad_biu_rresp,
    input  wire         pad_biu_rvalid,
    output wire         biu_pad_rready,

    // AXI write address
    output wire [ 31:0] biu_pad_awaddr,
    output wire [  3:0] biu_pad_awid,
    output wire [  1:0] biu_pad_awlen,
    output wire [  2:0] biu_pad_awsize,
    output wire [  1:0] biu_pad_awburst,
    output wire [  3:0] biu_pad_awcache,
    output wire [  2:0] biu_pad_awprot,
    output wire         biu_pad_awvalid,
    input  wire         pad_biu_awready,

    // AXI write data
    output wire [127:0] biu_pad_wdata,
    output wire [ 15:0] biu_pad_wstrb,
    output wire         biu_pad_wlast,
    output wire         biu_pad_wvalid,
    input  wire         pad_biu_wready,

    // AXI write response
    input  wire [  3:0] pad_biu_bid,
    input  wire [  1:0] pad_biu_bresp,
    input  wire         pad_biu_bvalid,
    output wire         biu_pad_bready
);

    wire clk_buf;

    BUFG u_bufg (
        .I (clk),
        .O (clk_buf)
    );

    A910_cpu u_cpu (
        .clk                (clk_buf),
        .rst                (rst),

        .biu_pad_araddr     (biu_pad_araddr),
        .biu_pad_arid       (biu_pad_arid),
        .biu_pad_arlen      (biu_pad_arlen),
        .biu_pad_arsize     (biu_pad_arsize),
        .biu_pad_arburst    (biu_pad_arburst),
        .biu_pad_arcache    (biu_pad_arcache),
        .biu_pad_arprot     (biu_pad_arprot),
        .biu_pad_arvalid    (biu_pad_arvalid),
        .pad_biu_arready    (pad_biu_arready),

        .pad_biu_rdata      (pad_biu_rdata),
        .pad_biu_rid        (pad_biu_rid),
        .pad_biu_rlast      (pad_biu_rlast),
        .pad_biu_rresp      (pad_biu_rresp),
        .pad_biu_rvalid     (pad_biu_rvalid),
        .biu_pad_rready     (biu_pad_rready),

        .biu_pad_awaddr     (biu_pad_awaddr),
        .biu_pad_awid       (biu_pad_awid),
        .biu_pad_awlen      (biu_pad_awlen),
        .biu_pad_awsize     (biu_pad_awsize),
        .biu_pad_awburst    (biu_pad_awburst),
        .biu_pad_awcache    (biu_pad_awcache),
        .biu_pad_awprot     (biu_pad_awprot),
        .biu_pad_awvalid    (biu_pad_awvalid),
        .pad_biu_awready    (pad_biu_awready),

        .biu_pad_wdata      (biu_pad_wdata),
        .biu_pad_wstrb      (biu_pad_wstrb),
        .biu_pad_wlast      (biu_pad_wlast),
        .biu_pad_wvalid     (biu_pad_wvalid),
        .pad_biu_wready     (pad_biu_wready),

        .pad_biu_bid        (pad_biu_bid),
        .pad_biu_bresp      (pad_biu_bresp),
        .pad_biu_bvalid     (pad_biu_bvalid),
        .biu_pad_bready     (biu_pad_bready)
    );

endmodule
