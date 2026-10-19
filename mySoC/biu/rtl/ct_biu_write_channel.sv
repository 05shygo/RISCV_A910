// Copyright 2019-2021 T-Head Semiconductor Co., Ltd.
// SPDX-License-Identifier: Apache-2.0
//
// 移植自原版 C910 ct_biu_write_channel.v。
//
// 保持与原版一致的:
//   * AW: store / victim 各一个 1 项寄存器 (cur_waddr_st/vict_awvalid),
//         组合 mux (victim 优先) 直接驱动 pad;
//   * W : store / victim / round 三个 1 项寄存器, 用 bus_arb_w_fifo
//         (12 项 shift FIFO) 记录 AW 的源顺序, 再按 FIFO 头选择 W 数据;
//   * B : cur_bresp_buf 一项寄存器。
//
// 相对原版删掉的输入信号及相关逻辑 (本简化接口没有):
//   * AW 属性: awlock / awsnoop / awdomain / awbar / awunique / awuser;
//   * W 属性: wns -> 原版 wns/ws 双通道退化为单 AXI W 通道,
//     pad_awready/pad_wready 直接就是 AXI 的 ready;
//   * evict_trans (依赖 awsnoop == EVICT);
//   * 请求侧 _req/_dp_req/_gate: 本接口只有 AXI valid, 数据写入用 valid;
//   * 低功耗/门控时钟: 各 *_awcpuclk / st_wcpuclk / bus_arb_w_fifo_clk /
//     bcpuclk 统一改用 forever_cpuclk;
//   * back 握手: 本接口是 AXI B 通道, 用 lsu_biu_bready 做标准
//     valid/ready skid (back_full = cur_bresp_buf_bvalid && !lsu_biu_bready)。

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
    // source 0: store AW
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]      st_awaddr,
    input  logic [ID_WIDTH-1:0]      st_awid,
    input  logic [LEN_WIDTH-1:0]     st_awlen,
    input  logic [2:0]               st_awsize,
    input  logic [1:0]               st_awburst,
    input  logic [3:0]               st_awcache,
    input  logic [2:0]               st_awprot,
    input  logic                     st_awvalid,
    output logic                     st_awready,

    input  logic [DATA_WIDTH-1:0]    st_wdata,
    input  logic [STRB_WIDTH-1:0]    st_wstrb,
    input  logic                     st_wlast,
    input  logic                     st_wvalid,
    output logic                     st_wready,

    //---------------------------------------------------------
    // source 1: victim (vb) AW
    //---------------------------------------------------------
    input  logic [PA_WIDTH-1:0]      vict_awaddr,
    input  logic [ID_WIDTH-1:0]      vict_awid,
    input  logic [LEN_WIDTH-1:0]     vict_awlen,
    input  logic [2:0]               vict_awsize,
    input  logic [1:0]               vict_awburst,
    input  logic [3:0]               vict_awcache,
    input  logic [2:0]               vict_awprot,
    input  logic                     vict_awvalid,
    output logic                     vict_awready,

    input  logic [DATA_WIDTH-1:0]    vict_wdata,
    input  logic [STRB_WIDTH-1:0]    vict_wstrb,
    input  logic                     vict_wlast,
    input  logic                     vict_wvalid,
    output logic                     vict_wready,

    //---------------------------------------------------------
    // write response to LSU
    //---------------------------------------------------------
    output logic [ID_WIDTH-1:0]      biu_lsu_bid,
    output logic [1:0]               biu_lsu_bresp,
    output logic                     biu_lsu_bvalid,
    input  logic                     lsu_biu_bready,

    //---------------------------------------------------------
    // AXI AW
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
    // AXI W
    //---------------------------------------------------------
    output logic [DATA_WIDTH-1:0]    biu_pad_wdata,
    output logic [STRB_WIDTH-1:0]    biu_pad_wstrb,
    output logic                     biu_pad_wlast,
    output logic                     biu_pad_wvalid,
    input  logic                     pad_biu_wready,

    //---------------------------------------------------------
    // AXI B
    //---------------------------------------------------------
    input  logic [ID_WIDTH-1:0]      pad_biu_bid,
    input  logic [1:0]               pad_biu_bresp,
    input  logic                     pad_biu_bvalid,
    output logic                     biu_pad_bready
);

    //==========================================================
    //           write addr channel
    // cur_waddr_buf:
    // | cur_waddr_buf_awvalid | cur_waddr_buf_awid | cur_waddr_buf_awaddr |
    // |          ..._awlen    |       ..._awsize   |      ..._awburst    |
    // |         ..._awcache   |       ..._awprot   |
    //==========================================================
    logic [PA_WIDTH-1:0]   cur_waddr_buf_awaddr;
    logic [ID_WIDTH-1:0]   cur_waddr_buf_awid;
    logic [LEN_WIDTH-1:0]  cur_waddr_buf_awlen;
    logic [2:0]            cur_waddr_buf_awsize;
    logic [1:0]            cur_waddr_buf_awburst;
    logic [3:0]            cur_waddr_buf_awcache;
    logic [2:0]            cur_waddr_buf_awprot;

    logic [PA_WIDTH-1:0]   cur_waddr_st_awaddr;
    logic [ID_WIDTH-1:0]   cur_waddr_st_awid;
    logic [LEN_WIDTH-1:0]  cur_waddr_st_awlen;
    logic [2:0]            cur_waddr_st_awsize;
    logic [1:0]            cur_waddr_st_awburst;
    logic [3:0]            cur_waddr_st_awcache;
    logic [2:0]            cur_waddr_st_awprot;
    logic                  cur_waddr_st_awvalid;

    logic [PA_WIDTH-1:0]   cur_waddr_vict_awaddr;
    logic [ID_WIDTH-1:0]   cur_waddr_vict_awid;
    logic [LEN_WIDTH-1:0]  cur_waddr_vict_awlen;
    logic [2:0]            cur_waddr_vict_awsize;
    logic [1:0]            cur_waddr_vict_awburst;
    logic [3:0]            cur_waddr_vict_awcache;
    logic [2:0]            cur_waddr_vict_awprot;
    logic                  cur_waddr_vict_awvalid;

    wire                   cur_waddr_buf_awvalid;

    // 原版: 单 AXI 通道, pad_awready 就是 pad 的 AXI AWREADY
    wire                   pad_awready;
    assign pad_awready = pad_biu_awready;

    assign vict_awready = !cur_waddr_vict_awvalid;
    assign st_awready   = !cur_waddr_st_awvalid;

    assign biu_pad_awvalid = cur_waddr_buf_awvalid;
    assign biu_pad_awid    = cur_waddr_buf_awid;
    assign biu_pad_awaddr  = cur_waddr_buf_awaddr;
    assign biu_pad_awlen   = cur_waddr_buf_awlen;
    assign biu_pad_awsize  = cur_waddr_buf_awsize;
    assign biu_pad_awburst = cur_waddr_buf_awburst;
    assign biu_pad_awcache = cur_waddr_buf_awcache;
    assign biu_pad_awprot  = cur_waddr_buf_awprot;

    assign cur_waddr_buf_awvalid = cur_waddr_vict_awvalid
                                 || cur_waddr_st_awvalid;

    always_comb begin
        if (cur_waddr_vict_awvalid) begin
            cur_waddr_buf_awid    = cur_waddr_vict_awid;
            cur_waddr_buf_awaddr  = cur_waddr_vict_awaddr;
            cur_waddr_buf_awlen   = cur_waddr_vict_awlen;
            cur_waddr_buf_awsize  = cur_waddr_vict_awsize;
            cur_waddr_buf_awburst = cur_waddr_vict_awburst;
            cur_waddr_buf_awcache = cur_waddr_vict_awcache;
            cur_waddr_buf_awprot  = cur_waddr_vict_awprot;
        end else begin
            cur_waddr_buf_awid    = cur_waddr_st_awid;
            cur_waddr_buf_awaddr  = cur_waddr_st_awaddr;
            cur_waddr_buf_awlen   = cur_waddr_st_awlen;
            cur_waddr_buf_awsize  = cur_waddr_st_awsize;
            cur_waddr_buf_awburst = cur_waddr_st_awburst;
            cur_waddr_buf_awcache = cur_waddr_st_awcache;
            cur_waddr_buf_awprot  = cur_waddr_st_awprot;
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_waddr_vict_awvalid <= 1'b0;
        else if (vict_awvalid && !cur_waddr_vict_awvalid)
            cur_waddr_vict_awvalid <= 1'b1;
        else if (pad_awready && cur_waddr_vict_awvalid)
            cur_waddr_vict_awvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_waddr_vict_awid    <= {ID_WIDTH{1'b0}};
            cur_waddr_vict_awaddr  <= {PA_WIDTH{1'b0}};
            cur_waddr_vict_awlen   <= {LEN_WIDTH{1'b0}};
            cur_waddr_vict_awsize  <= 3'b0;
            cur_waddr_vict_awburst <= 2'b0;
            cur_waddr_vict_awcache <= 4'b0;
            cur_waddr_vict_awprot  <= 3'b0;
        end
        // 原版这里用 vict_awvalid_gate; 本接口没有 gate, 用 AXI 的 valid
        else if (vict_awvalid && !cur_waddr_vict_awvalid) begin
            cur_waddr_vict_awid    <= vict_awid;
            cur_waddr_vict_awaddr  <= vict_awaddr;
            cur_waddr_vict_awlen   <= vict_awlen;
            cur_waddr_vict_awsize  <= vict_awsize;
            cur_waddr_vict_awburst <= vict_awburst;
            cur_waddr_vict_awcache <= vict_awcache;
            cur_waddr_vict_awprot  <= vict_awprot;
        end
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_waddr_st_awvalid <= 1'b0;
        else if (st_awvalid && !cur_waddr_st_awvalid)
            cur_waddr_st_awvalid <= 1'b1;
        else if (pad_awready && cur_waddr_st_awvalid && !cur_waddr_vict_awvalid)
            cur_waddr_st_awvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_waddr_st_awid    <= {ID_WIDTH{1'b0}};
            cur_waddr_st_awaddr  <= {PA_WIDTH{1'b0}};
            cur_waddr_st_awlen   <= {LEN_WIDTH{1'b0}};
            cur_waddr_st_awsize  <= 3'b0;
            cur_waddr_st_awburst <= 2'b0;
            cur_waddr_st_awcache <= 4'b0;
            cur_waddr_st_awprot  <= 3'b0;
        end
        // 原版这里用 st_awvalid_gate; 本接口没有 gate, 用 AXI 的 valid
        else if (st_awvalid && !cur_waddr_st_awvalid) begin
            cur_waddr_st_awid    <= st_awid;
            cur_waddr_st_awaddr  <= st_awaddr;
            cur_waddr_st_awlen   <= st_awlen;
            cur_waddr_st_awsize  <= st_awsize;
            cur_waddr_st_awburst <= st_awburst;
            cur_waddr_st_awcache <= st_awcache;
            cur_waddr_st_awprot  <= st_awprot;
        end
    end

    //==========================================================
    //                W FIFO
    // bus_arb_w_fifo: 0 : wmb (store)
    //                 1 : vb  (victim)
    //==========================================================
    localparam int W_FIFO_ENTRY = 12;

    logic [W_FIFO_ENTRY-1:0] bus_arb_w_fifo;
    logic [W_FIFO_ENTRY:0]   bus_arb_w_fifo_create_ptr;
    logic [W_FIFO_ENTRY-1:0] bus_arb_w_fifo_stage;
    logic [W_FIFO_ENTRY-1:0] bus_arb_w_fifo_next;
    logic                    bus_arb_w_fifo_create_vld;
    logic                    bus_arb_w_fifo_pop_vld;
    logic                    bus_arb_w_fifo_empty;
    logic                    bus_arb_w_fifo_less2;

    // 提前声明: FIFO pop 条件要用到当前 W 输出的 valid/last
    logic                    cur_wdata_buf_wvalid;
    logic                    cur_wdata_buf_wlast;

    wire                     pad_wready;
    assign pad_wready = pad_biu_wready;

    // 原版: bus_arb_w_fifo_create_vld = cur_waddr_buf_awvalid && !evict_trans && pad_awready
    assign bus_arb_w_fifo_create_vld = cur_waddr_buf_awvalid && pad_awready;
    assign bus_arb_w_fifo_pop_vld    = cur_wdata_buf_wvalid && cur_wdata_buf_wlast
                                     && pad_wready;

    assign bus_arb_w_fifo_stage =
        ({W_FIFO_ENTRY{cur_waddr_vict_awvalid && pad_awready}}
         & bus_arb_w_fifo_create_ptr[W_FIFO_ENTRY-1:0])
        | bus_arb_w_fifo;

    assign bus_arb_w_fifo_next = bus_arb_w_fifo_pop_vld
                                 ? {1'b0, bus_arb_w_fifo_stage[W_FIFO_ENTRY-1:1]}
                                 : bus_arb_w_fifo_stage;

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            bus_arb_w_fifo <= {W_FIFO_ENTRY{1'b0}};
        else if (bus_arb_w_fifo_create_vld || bus_arb_w_fifo_pop_vld)
            bus_arb_w_fifo <= bus_arb_w_fifo_next;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            bus_arb_w_fifo_create_ptr <= {{W_FIFO_ENTRY{1'b0}}, 1'b1};
        else if (bus_arb_w_fifo_create_vld && !bus_arb_w_fifo_pop_vld)
            bus_arb_w_fifo_create_ptr <= {bus_arb_w_fifo_create_ptr[W_FIFO_ENTRY-1:0], 1'b0};
        else if (!bus_arb_w_fifo_create_vld && bus_arb_w_fifo_pop_vld)
            bus_arb_w_fifo_create_ptr <= {1'b0, bus_arb_w_fifo_create_ptr[W_FIFO_ENTRY:1]};
    end

    assign bus_arb_w_fifo_empty = bus_arb_w_fifo_create_ptr[0];
    assign bus_arb_w_fifo_less2 = |bus_arb_w_fifo_create_ptr[1:0];

    //==========================================================
    //                write data channel
    // cur_wdata_buf:
    // | cur_wdata_buf_wvalid | cur_wdata_buf_wdata |
    // | cur_wdata_buf_wstrb  | cur_wdata_buf_wlast |
    //==========================================================
    logic [2:0]            cur_wdata_buf_pop_sel;
    logic [2:0]            cur_wdata_buf_create_pop_sel;
    logic [2:0]            cur_wdata_buf_pop_sel_next;
    logic                  cur_wdata_buf_wvalid_dp;
    logic [DATA_WIDTH-1:0] cur_wdata_buf_wdata;
    logic [STRB_WIDTH-1:0] cur_wdata_buf_wstrb;

    logic                  cur_wdata_vict_wvalid;
    logic [DATA_WIDTH-1:0] cur_wdata_vict_wdata;
    logic [STRB_WIDTH-1:0] cur_wdata_vict_wstrb;
    logic                  cur_wdata_vict_wlast;

    logic                  cur_wdata_st_wvalid;
    logic [DATA_WIDTH-1:0] cur_wdata_st_wdata;
    logic [STRB_WIDTH-1:0] cur_wdata_st_wstrb;
    logic                  cur_wdata_st_wlast;

    logic                  cur_wdata_round_wvalid;
    logic [DATA_WIDTH-1:0] cur_wdata_round_wdata;
    logic [STRB_WIDTH-1:0] cur_wdata_round_wstrb;
    logic                  cur_wdata_round_wlast;

    logic                  pop_next_w_fifo;
    logic                  wdata_vict_pop_sel_next;
    logic                  wdata_st_pop_sel_next;
    logic                  w_fifo_round_next_victim;
    logic                  w_fifo_round_next_st;
    logic                  round_wvalid;

    assign vict_wready = !cur_wdata_vict_wvalid
                      || (!cur_wdata_round_wvalid && w_fifo_round_next_victim);
    assign st_wready   = !cur_wdata_st_wvalid
                      || (!cur_wdata_round_wvalid && w_fifo_round_next_st);

    assign biu_pad_wvalid = cur_wdata_buf_wvalid;
    assign biu_pad_wdata  = cur_wdata_buf_wdata;
    assign biu_pad_wstrb  = cur_wdata_buf_wstrb;
    assign biu_pad_wlast  = cur_wdata_buf_wlast;

    // 只有 FIFO 非空时, 才把 W 数据送到 pad
    assign cur_wdata_buf_wvalid = !bus_arb_w_fifo_empty && cur_wdata_buf_wvalid_dp;

    always_comb begin
        case (cur_wdata_buf_pop_sel)
            3'b001: begin
                cur_wdata_buf_wvalid_dp = cur_wdata_vict_wvalid;
                cur_wdata_buf_wdata     = cur_wdata_vict_wdata;
                cur_wdata_buf_wstrb     = cur_wdata_vict_wstrb;
                cur_wdata_buf_wlast     = cur_wdata_vict_wlast;
            end
            3'b010: begin
                cur_wdata_buf_wvalid_dp = cur_wdata_st_wvalid;
                cur_wdata_buf_wdata     = cur_wdata_st_wdata;
                cur_wdata_buf_wstrb     = cur_wdata_st_wstrb;
                cur_wdata_buf_wlast     = cur_wdata_st_wlast;
            end
            3'b100: begin
                cur_wdata_buf_wvalid_dp = cur_wdata_round_wvalid;
                cur_wdata_buf_wdata     = cur_wdata_round_wdata;
                cur_wdata_buf_wstrb     = cur_wdata_round_wstrb;
                cur_wdata_buf_wlast     = cur_wdata_round_wlast;
            end
            default: begin
                cur_wdata_buf_wvalid_dp = 1'b0;
                cur_wdata_buf_wdata     = {DATA_WIDTH{1'b0}};
                cur_wdata_buf_wstrb     = {STRB_WIDTH{1'b0}};
                cur_wdata_buf_wlast     = 1'b0;
            end
        endcase
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_wdata_buf_pop_sel <= 3'b001;
        else if (bus_arb_w_fifo_empty && bus_arb_w_fifo_create_vld)
            cur_wdata_buf_pop_sel <= cur_wdata_buf_create_pop_sel;
        else if (cur_wdata_buf_wvalid && pad_wready)
            cur_wdata_buf_pop_sel <= cur_wdata_buf_pop_sel_next;
    end

    // for timing, select pop entry in advance
    assign cur_wdata_buf_create_pop_sel = {1'b0,
                                           !cur_waddr_vict_awvalid,
                                           cur_waddr_vict_awvalid};

    assign pop_next_w_fifo = cur_wdata_buf_wlast
                             ? (bus_arb_w_fifo_less2
                                ? cur_waddr_vict_awvalid
                                : bus_arb_w_fifo[1])
                             : bus_arb_w_fifo[0];

    assign wdata_vict_pop_sel_next = pop_next_w_fifo
                                     && !(cur_wdata_buf_pop_sel[0]
                                          && (cur_wdata_round_wvalid || round_wvalid));

    assign wdata_st_pop_sel_next = !pop_next_w_fifo
                                   && !(cur_wdata_buf_pop_sel[1]
                                        && (cur_wdata_round_wvalid || round_wvalid));

    assign cur_wdata_buf_pop_sel_next = {!wdata_st_pop_sel_next && !wdata_vict_pop_sel_next,
                                         wdata_st_pop_sel_next,
                                         wdata_vict_pop_sel_next};

    //---------------------------------------------------------
    // victim W buffer
    //---------------------------------------------------------
    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_wdata_vict_wvalid <= 1'b0;
        else if (vict_wvalid && !cur_wdata_vict_wvalid)
            cur_wdata_vict_wvalid <= 1'b1;
        else if (pad_wready && cur_wdata_buf_pop_sel[0] && cur_wdata_buf_wvalid)
            cur_wdata_vict_wvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_wdata_vict_wdata <= {DATA_WIDTH{1'b0}};
            cur_wdata_vict_wstrb <= {STRB_WIDTH{1'b0}};
            cur_wdata_vict_wlast <= 1'b0;
        end
        else if (vict_wvalid && !cur_wdata_vict_wvalid) begin
            cur_wdata_vict_wdata <= vict_wdata;
            cur_wdata_vict_wstrb <= vict_wstrb;
            cur_wdata_vict_wlast <= vict_wlast;
        end
    end

    //---------------------------------------------------------
    // store W buffer
    //---------------------------------------------------------
    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_wdata_st_wvalid <= 1'b0;
        else if (st_wvalid && !cur_wdata_st_wvalid)
            cur_wdata_st_wvalid <= 1'b1;
        else if (pad_wready && cur_wdata_buf_pop_sel[1] && cur_wdata_buf_wvalid)
            cur_wdata_st_wvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_wdata_st_wdata <= {DATA_WIDTH{1'b0}};
            cur_wdata_st_wstrb <= {STRB_WIDTH{1'b0}};
            cur_wdata_st_wlast <= 1'b0;
        end
        else if (st_wvalid && !cur_wdata_st_wvalid) begin
            cur_wdata_st_wdata <= st_wdata;
            cur_wdata_st_wstrb <= st_wstrb;
            cur_wdata_st_wlast <= st_wlast;
        end
    end

    //---------------------------------------------------------
    // round W buffer
    //---------------------------------------------------------
    assign w_fifo_round_next_victim = !bus_arb_w_fifo_empty
                                      && bus_arb_w_fifo[0]
                                      && (!cur_wdata_vict_wlast
                                          || (!bus_arb_w_fifo_less2
                                              && bus_arb_w_fifo[1]));

    assign w_fifo_round_next_st     = !bus_arb_w_fifo_empty
                                      && !bus_arb_w_fifo[0]
                                      && (!cur_wdata_st_wlast
                                          || (!bus_arb_w_fifo_less2
                                              && !bus_arb_w_fifo[1]));

    assign round_wvalid = vict_wvalid
                          && cur_wdata_vict_wvalid
                          && w_fifo_round_next_victim
                       || st_wvalid
                          && cur_wdata_st_wvalid
                          && w_fifo_round_next_st;

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_wdata_round_wvalid <= 1'b0;
        else if (round_wvalid && !cur_wdata_round_wvalid)
            cur_wdata_round_wvalid <= 1'b1;
        else if (pad_wready && cur_wdata_buf_pop_sel[2] && cur_wdata_buf_wvalid)
            cur_wdata_round_wvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_wdata_round_wdata <= {DATA_WIDTH{1'b0}};
            cur_wdata_round_wstrb <= {STRB_WIDTH{1'b0}};
            cur_wdata_round_wlast <= 1'b0;
        end
        else if (round_wvalid && !cur_wdata_round_wvalid
                 && w_fifo_round_next_victim) begin
            cur_wdata_round_wdata <= vict_wdata;
            cur_wdata_round_wstrb <= vict_wstrb;
            cur_wdata_round_wlast <= vict_wlast;
        end
        else if (round_wvalid && !cur_wdata_round_wvalid) begin
            cur_wdata_round_wdata <= st_wdata;
            cur_wdata_round_wstrb <= st_wstrb;
            cur_wdata_round_wlast <= st_wlast;
        end
    end

    //==========================================================
    //           write resp channel
    //           transmit resp from bus to req source (lsu)
    // cur_bresp_buf:
    // | cur_bresp_buf_bvalid |
    // | cur_bresp_buf_bresp  | cur_bresp_buf_bid |
    //==========================================================
    logic                  cur_bresp_buf_bvalid;
    logic [ID_WIDTH-1:0]   cur_bresp_buf_bid;
    logic [1:0]            cur_bresp_buf_bresp;
    wire                   back_full;

    // 原版 back_full = back_valid && back_pending (LSU 无条件接收, back 回 pad);
    // 本接口是 AXI B 通道: back_full 换成 "B 寄存器有数且 LSU 不 ready"
    assign back_full = cur_bresp_buf_bvalid && !lsu_biu_bready;

    assign biu_pad_bready = !back_full;

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cur_bresp_buf_bvalid <= 1'b0;
        else if (pad_biu_bvalid && !back_full)
            cur_bresp_buf_bvalid <= 1'b1;
        else if (!back_full)
            cur_bresp_buf_bvalid <= 1'b0;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            cur_bresp_buf_bresp <= 2'b0;
            cur_bresp_buf_bid   <= {ID_WIDTH{1'b0}};
        end
        else if (pad_biu_bvalid && !back_full) begin
            cur_bresp_buf_bresp <= pad_biu_bresp;
            cur_bresp_buf_bid   <= pad_biu_bid;
        end
    end

    // AXI: valid 不能因为 ready 撤销 (原版 LSU 永远能收, 所以直接与 !back_full)
    assign biu_lsu_bvalid = cur_bresp_buf_bvalid;
    assign biu_lsu_bresp  = cur_bresp_buf_bresp;
    assign biu_lsu_bid    = cur_bresp_buf_bid;

endmodule
