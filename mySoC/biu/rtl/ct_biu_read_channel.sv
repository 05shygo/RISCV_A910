// Copyright 2019-2021 T-Head Semiconductor Co., Ltd.
// SPDX-License-Identifier: Apache-2.0
//
// 移植自原版 C910 ct_biu_read_channel.v。
//
// 保持与原版一致的:
//   * AR: cur_raddr_buf0/1 两项 ping-pong 寄存器 + crt1_sel/pop1_sel,
//         arready = cur_raddr_buf_ready = 至少一个 buffer 空;
//   * R : cur_rdata_buf0/1 两项 ping-pong 寄存器 + crt1_sel/pop1_sel,
//         biu_pad_rready = cur_rdata_buf_ready = 至少一个 buffer 空;
//         IFU/LSU 共用同一个 cur_rdata_buf_* 组合 bundle;
//         cur_rdata_is_ifu / is_lsu / is_linefill、rd_data_clr_en_raw、
//         rd_data_create_en 的口径与原版一致。
//
// 相对原版删掉的输入信号及相关逻辑 (本简化接口没有):
//   * AXI 属性: arlock / arsnoop / ardomain / arbar / aruser;
//   * rack: rack_valid / rack_pending / rack_full / biu_pad_rack
//     (因此 rd_data_clr_en / rvalid 上的 !rack_full 门控一并去掉);
//   * 低功耗/门控时钟: arcpuclk / rcpuclk / read_ar_clk_en / read_r_clk_en /
//     read_busy, 统一改用 forever_cpuclk;
//   * 请求侧 arvalid_gate (本接口只有 AXI 的 arvalid, 数据写入用 arvalid);
//   * ID 宽度 5 -> 4: 原版 IFU id 5'b10000/10001 在本接口里是 4'b100x,
//     linefill 判定原版 rid[4:3]==0 对应本接口 rid[3:2]==0。

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

    //==========================================================
    //           read addr channel
    // cur_raddr_buf:
    // | cur_raddr_buf_arvalid | cur_raddr_buf_arid | cur_raddr_buf_araddr |
    // |            ..._arlen  |        ..._arsize  |       ..._arburst    |
    // |           ..._arcache |        ..._arprot  |
    //==========================================================
    logic [PA_WIDTH-1:0]   cur_raddr_buf0_araddr;
    logic [ID_WIDTH-1:0]   cur_raddr_buf0_arid;
    logic [LEN_WIDTH-1:0]  cur_raddr_buf0_arlen;
    logic [2:0]            cur_raddr_buf0_arsize;
    logic [1:0]            cur_raddr_buf0_arburst;
    logic [3:0]            cur_raddr_buf0_arcache;
    logic [2:0]            cur_raddr_buf0_arprot;
    logic                  cur_raddr_buf0_arvalid;

    logic [PA_WIDTH-1:0]   cur_raddr_buf1_araddr;
    logic [ID_WIDTH-1:0]   cur_raddr_buf1_arid;
    logic [LEN_WIDTH-1:0]  cur_raddr_buf1_arlen;
    logic [2:0]            cur_raddr_buf1_arsize;
    logic [1:0]            cur_raddr_buf1_arburst;
    logic [3:0]            cur_raddr_buf1_arcache;
    logic [2:0]            cur_raddr_buf1_arprot;
    logic                  cur_raddr_buf1_arvalid;

    logic [PA_WIDTH-1:0]   cur_raddr_buf_araddr;
    logic [ID_WIDTH-1:0]   cur_raddr_buf_arid;
    logic [LEN_WIDTH-1:0]  cur_raddr_buf_arlen;
    logic [2:0]            cur_raddr_buf_arsize;
    logic [1:0]            cur_raddr_buf_arburst;
    logic [3:0]            cur_raddr_buf_arcache;
    logic [2:0]            cur_raddr_buf_arprot;
    logic                  cur_raddr_buf_crt1_sel;
    logic                  cur_raddr_buf_pop1_sel;

    wire                   cur_raddr_buf_arvalid;
    wire                   cur_raddr_buf_empty;
    wire                   cur_raddr_buf_ready;

    // buf ready stand for buf can accept req from lsu/ifu
    assign arready = cur_raddr_buf_ready;

    assign cur_raddr_buf_ready = cur_raddr_buf_empty;

    assign cur_raddr_buf_empty = !cur_raddr_buf0_arvalid
                                 || !cur_raddr_buf1_arvalid;

    assign biu_pad_arvalid = cur_raddr_buf_arvalid;
    assign biu_pad_arid    = cur_raddr_buf_arid;
    assign biu_pad_araddr  = cur_raddr_buf_araddr;
    assign biu_pad_arlen   = cur_raddr_buf_arlen;
    assign biu_pad_arsize  = cur_raddr_buf_arsize;
    assign biu_pad_arburst = cur_raddr_buf_arburst;
    assign biu_pad_arcache = cur_raddr_buf_arcache;
    assign biu_pad_arprot  = cur_raddr_buf_arprot;

    assign cur_raddr_buf_arvalid = cur_raddr_buf0_arvalid
                                   || cur_raddr_buf1_arvalid;

    always_comb begin
        if (cur_raddr_buf_pop1_sel) begin
            cur_raddr_buf_arid    = cur_raddr_buf1_arid;
            cur_raddr_buf_araddr  = cur_raddr_buf1_araddr;
            cur_raddr_buf_arlen   = cur_raddr_buf1_arlen;
            cur_raddr_buf_arsize  = cur_raddr_buf1_arsize;
            cur_raddr_buf_arburst = cur_raddr_buf1_arburst;
            cur_raddr_buf_arcache = cur_raddr_buf1_arcache;
            cur_raddr_buf_arprot  = cur_raddr_buf1_arprot;
        end else begin
            cur_raddr_buf_arid    = cur_raddr_buf0_arid;
            cur_raddr_buf_araddr  = cur_raddr_buf0_araddr;
            cur_raddr_buf_arlen   = cur_raddr_buf0_arlen;
            cur_raddr_buf_arsize  = cur_raddr_buf0_arsize;
            cur_raddr_buf_arburst = cur_raddr_buf0_arburst;
            cur_raddr_buf_arcache = cur_raddr_buf0_arcache;
            cur_raddr_buf_arprot  = cur_raddr_buf0_arprot;
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_raddr_buf_crt1_sel <= 1'b0;
        else if (arvalid && cur_raddr_buf_ready)
            cur_raddr_buf_crt1_sel <= !cur_raddr_buf_crt1_sel;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_raddr_buf_pop1_sel <= 1'b0;
        else if (cur_raddr_buf_arvalid && pad_biu_arready)
            cur_raddr_buf_pop1_sel <= !cur_raddr_buf_pop1_sel;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_raddr_buf0_arvalid <= 1'b0;
        else if (arvalid && !cur_raddr_buf_crt1_sel && !cur_raddr_buf0_arvalid)
            cur_raddr_buf0_arvalid <= 1'b1;
        else if (pad_biu_arready && !cur_raddr_buf_pop1_sel
                 && cur_raddr_buf0_arvalid)
            cur_raddr_buf0_arvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_raddr_buf0_arid    <= {ID_WIDTH{1'b0}};
            cur_raddr_buf0_araddr  <= {PA_WIDTH{1'b0}};
            cur_raddr_buf0_arlen   <= {LEN_WIDTH{1'b0}};
            cur_raddr_buf0_arsize  <= 3'b0;
            cur_raddr_buf0_arburst <= 2'b0;
            cur_raddr_buf0_arcache <= 4'b0;
            cur_raddr_buf0_arprot  <= 3'b0;
        end
        // 原版这里用 arvalid_gate; 本接口没有 gate 信号, 用 AXI 的 arvalid
        else if (arvalid && !cur_raddr_buf_crt1_sel && !cur_raddr_buf0_arvalid) begin
            cur_raddr_buf0_arid    <= arid;
            cur_raddr_buf0_araddr  <= araddr;
            cur_raddr_buf0_arlen   <= arlen;
            cur_raddr_buf0_arsize  <= arsize;
            cur_raddr_buf0_arburst <= arburst;
            cur_raddr_buf0_arcache <= arcache;
            cur_raddr_buf0_arprot  <= arprot;
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_raddr_buf1_arvalid <= 1'b0;
        else if (arvalid && cur_raddr_buf_crt1_sel && !cur_raddr_buf1_arvalid)
            cur_raddr_buf1_arvalid <= 1'b1;
        else if (pad_biu_arready && cur_raddr_buf_pop1_sel
                 && cur_raddr_buf1_arvalid)
            cur_raddr_buf1_arvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_raddr_buf1_arid    <= {ID_WIDTH{1'b0}};
            cur_raddr_buf1_araddr  <= {PA_WIDTH{1'b0}};
            cur_raddr_buf1_arlen   <= {LEN_WIDTH{1'b0}};
            cur_raddr_buf1_arsize  <= 3'b0;
            cur_raddr_buf1_arburst <= 2'b0;
            cur_raddr_buf1_arcache <= 4'b0;
            cur_raddr_buf1_arprot  <= 3'b0;
        end
        // 原版这里用 arvalid_gate; 本接口没有 gate 信号, 用 AXI 的 arvalid
        else if (arvalid && cur_raddr_buf_crt1_sel && !cur_raddr_buf1_arvalid) begin
            cur_raddr_buf1_arid    <= arid;
            cur_raddr_buf1_araddr  <= araddr;
            cur_raddr_buf1_arlen   <= arlen;
            cur_raddr_buf1_arsize  <= arsize;
            cur_raddr_buf1_arburst <= arburst;
            cur_raddr_buf1_arcache <= arcache;
            cur_raddr_buf1_arprot  <= arprot;
        end
    end

    //==========================================================
    //           read data channel
    //           bus handshake signal
    //==========================================================
    logic [DATA_WIDTH-1:0] cur_rdata_buf0_rdata;
    logic [ID_WIDTH-1:0]   cur_rdata_buf0_rid;
    logic                  cur_rdata_buf0_rlast;
    logic [1:0]            cur_rdata_buf0_rresp;
    logic                  cur_rdata_buf0_rvalid;

    logic [DATA_WIDTH-1:0] cur_rdata_buf1_rdata;
    logic [ID_WIDTH-1:0]   cur_rdata_buf1_rid;
    logic                  cur_rdata_buf1_rlast;
    logic [1:0]            cur_rdata_buf1_rresp;
    logic                  cur_rdata_buf1_rvalid;

    logic [DATA_WIDTH-1:0] cur_rdata_buf_rdata;
    logic [ID_WIDTH-1:0]   cur_rdata_buf_rid;
    logic                  cur_rdata_buf_rlast;
    logic [1:0]            cur_rdata_buf_rresp;
    logic                  cur_rdata_buf_crt1_sel;
    logic                  cur_rdata_buf_pop1_sel;

    wire                   cur_rdata_buf_empty;
    wire                   cur_rdata_buf_ready;
    wire                   cur_rdata_buf_rvalid;
    wire                   cur_rdata_is_ifu;
    wire                   cur_rdata_is_linefill;
    wire                   cur_rdata_is_lsu;
    wire                   rd_data_clr_en;
    wire                   rd_data_clr_en_raw;
    wire                   rd_data_create_en;

    assign biu_pad_rready      = cur_rdata_buf_ready;

    assign cur_rdata_buf_ready = cur_rdata_buf_empty;

    assign cur_rdata_buf_empty = !cur_rdata_buf0_rvalid
                                 || !cur_rdata_buf1_rvalid;

    // 原版: rd_data_clr_en_raw 里非 linefill 的 LSU 响应当拍自动消费;
    //       只有 linefill 等 lsu_biu_r_linefill_ready。
    // 本接口的 lsu_biu_rready 就是原版 lsu_biu_r_linefill_ready 的对应信号。
    assign rd_data_clr_en_raw  = (cur_rdata_is_ifu && ifu_biu_rready)
                              || (cur_rdata_is_lsu && lsu_biu_rready)
                              || (cur_rdata_is_lsu && !cur_rdata_is_linefill);

    // 原版这里是 rd_data_clr_en_raw && !rack_full; rack 不做, 直接等于 raw
    assign rd_data_clr_en      = rd_data_clr_en_raw;

    // 原版: IFU id = 5'b10000/10001; 本接口 4-bit IFU id = 4'b100x
    assign cur_rdata_is_ifu    = cur_rdata_buf_rvalid
                              && (cur_rdata_buf_rid[3:2] == 2'b10);
    assign cur_rdata_is_lsu    = cur_rdata_buf_rvalid
                              && !cur_rdata_is_ifu;

    // only linefill data care for lsu_biu_rready;
    // other read req don't care
    // 原版: cur_rdata_buf_rid[4:3] == 2'b00; 本接口对应 [3:2]
    assign cur_rdata_is_linefill = cur_rdata_buf_rvalid
                                && (cur_rdata_buf_rid[3:2] == 2'b00);

    assign rd_data_create_en   = cur_rdata_buf_ready && pad_biu_rvalid;

    //==========================================================
    //           read data channel : get data from bus
    // cur_rdata_buf:
    // | cur_rdata_buf_rvalid |
    // | cur_rdata_buf_rid    | cur_rdata_buf_rdata |
    // | cur_rdata_buf_rresp  | cur_rdata_buf_rlast |
    //==========================================================
    assign cur_rdata_buf_rvalid = cur_rdata_buf0_rvalid
                                  || cur_rdata_buf1_rvalid;

    always_comb begin
        if (cur_rdata_buf_pop1_sel) begin
            cur_rdata_buf_rid   = cur_rdata_buf1_rid;
            cur_rdata_buf_rdata = cur_rdata_buf1_rdata;
            cur_rdata_buf_rresp = cur_rdata_buf1_rresp;
            cur_rdata_buf_rlast = cur_rdata_buf1_rlast;
        end else begin
            cur_rdata_buf_rid   = cur_rdata_buf0_rid;
            cur_rdata_buf_rdata = cur_rdata_buf0_rdata;
            cur_rdata_buf_rresp = cur_rdata_buf0_rresp;
            cur_rdata_buf_rlast = cur_rdata_buf0_rlast;
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_rdata_buf_crt1_sel <= 1'b0;
        else if (rd_data_create_en)
            cur_rdata_buf_crt1_sel <= !cur_rdata_buf_crt1_sel;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_rdata_buf_pop1_sel <= 1'b0;
        else if (rd_data_clr_en)
            cur_rdata_buf_pop1_sel <= !cur_rdata_buf_pop1_sel;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_rdata_buf0_rvalid <= 1'b0;
        else if (rd_data_create_en && !cur_rdata_buf_crt1_sel)
            cur_rdata_buf0_rvalid <= 1'b1;
        else if (rd_data_clr_en && !cur_rdata_buf_pop1_sel)
            cur_rdata_buf0_rvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_rdata_buf0_rid   <= {ID_WIDTH{1'b0}};
            cur_rdata_buf0_rdata <= {DATA_WIDTH{1'b0}};
            cur_rdata_buf0_rresp <= 2'b0;
            cur_rdata_buf0_rlast <= 1'b0;
        end
        else if (rd_data_create_en && !cur_rdata_buf_crt1_sel) begin
            cur_rdata_buf0_rid   <= pad_biu_rid;
            cur_rdata_buf0_rdata <= pad_biu_rdata;
            cur_rdata_buf0_rresp <= pad_biu_rresp;
            cur_rdata_buf0_rlast <= pad_biu_rlast;
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_rdata_buf1_rvalid <= 1'b0;
        else if (rd_data_create_en && cur_rdata_buf_crt1_sel)
            cur_rdata_buf1_rvalid <= 1'b1;
        else if (rd_data_clr_en && cur_rdata_buf_pop1_sel)
            cur_rdata_buf1_rvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_rdata_buf1_rid   <= {ID_WIDTH{1'b0}};
            cur_rdata_buf1_rdata <= {DATA_WIDTH{1'b0}};
            cur_rdata_buf1_rresp <= 2'b0;
            cur_rdata_buf1_rlast <= 1'b0;
        end
        else if (rd_data_create_en && cur_rdata_buf_crt1_sel) begin
            cur_rdata_buf1_rid   <= pad_biu_rid;
            cur_rdata_buf1_rdata <= pad_biu_rdata;
            cur_rdata_buf1_rresp <= pad_biu_rresp;
            cur_rdata_buf1_rlast <= pad_biu_rlast;
        end
    end

    //==========================================================
    //           read data channel : return data to lsu/ifu
    //==========================================================
    // 原版: biu_lsu_r_vld = cur_rdata_is_lsu && !rack_full; rack 不做
    assign biu_lsu_rvalid = cur_rdata_is_lsu;
    assign biu_lsu_rid    = cur_rdata_buf_rid;
    assign biu_lsu_rdata  = cur_rdata_buf_rdata;
    assign biu_lsu_rresp  = cur_rdata_buf_rresp;
    assign biu_lsu_rlast  = cur_rdata_buf_rlast;

    // 原版: biu_ifu_rd_data_vld = cur_rdata_is_ifu && !rack_full; rack 不做
    assign biu_ifu_rvalid = cur_rdata_is_ifu;
    assign biu_ifu_rid    = cur_rdata_buf_rid[0];
    assign biu_ifu_rdata  = cur_rdata_buf_rdata;
    assign biu_ifu_rresp  = cur_rdata_buf_rresp;
    assign biu_ifu_rlast  = cur_rdata_buf_rlast;

    //==========================================================
    //                  deleted from original
    //==========================================================
    // rack_valid / rack_pending / rack_full / biu_pad_rack 已删除;
    // read_ar_clk_en / read_r_clk_en / read_busy 随低功耗逻辑删除。

endmodule
