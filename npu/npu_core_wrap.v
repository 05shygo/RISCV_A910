`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// CoralNPU 包装: 把生成的 RvvCoreMiniAxi 收敛成一个干净的小接口, 并给它的
// AXI **主口** 接一个"永远报错"的从机.
//
// 为什么要有这一层
// ----------------
// 1. RvvCoreMiniAxi 有 60+ 个端口, 其中一大半是常量 (prot/id/len/size/burst/
//    lock/cache/qos/region). 把它们灌注在 wrap 里, miniRV_SoC 那边就只看得到
//    真正有信息量的信号.
// 2. NPU 的 AXI 主口**不能悬空** —— 见下面 null slave 的说明.
//
// 端口名对应生成的 RvvCoreMiniAxi.sv. 该文件由
//   bazel build //hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_emit_verilog
// 产出; 参考上游自己的 tests/vcs_sim/top.sv 实例化 (同一套命名).
// ⚠️ 若生成文件的端口名与此处不符, VCS elaborate 会直接报 "port not found" ——
//    属于早期明确失败, 不会静默跑错.
//
// 配置 (IC2 版 hdl/chisel/src/coralnpu/BUILD):
//   rvv_core_mini_axi_cc_library =
//       --enableRvv=True --enableVector=False --enableFloat=True
//       --lsuDataBits=128 --fetchDataBits=128
//       --itcmSizeKBytes=8 --dtcmSizeKBytes=32
//   ⇒ AXI 数据 128 位, 地址 32 位, ID 6 位 (核内断言 rid/bid 恒 0)
//   ⇒ shouldExposeDebugPorts=False ⇒ **没有** io_debug_* 端口
// ---------------------------------------------------------------------------
module npu_core_wrap(
    input  wire         clk,
    input  wire         npu_aresetn,     // 低有效, 由 npu_bridge 的 CTL[0] 驱动

    // NPU 状态 (直连出来给 npu_bridge 的 STATUS 寄存器)
    output wire         npu_halted,
    output wire         npu_fault,
    output wire         npu_wfi,

    // ---------------- AXI 从口 (npu_bridge 当主) ----------------
    input  wire [31:0]  m_awaddr,
    input  wire         m_awvalid,
    output wire         m_awready,
    input  wire [127:0] m_wdata,
    input  wire [15:0]  m_wstrb,
    input  wire         m_wvalid,
    input  wire         m_wlast,
    output wire         m_wready,
    output wire         m_bvalid,
    output wire [1:0]   m_bresp,
    output wire [5:0]   m_bid,
    input  wire         m_bready,
    input  wire [31:0]  m_araddr,
    input  wire         m_arvalid,
    output wire         m_arready,
    output wire         m_rvalid,
    output wire [127:0] m_rdata,
    output wire [1:0]   m_rresp,
    output wire [5:0]   m_rid,
    output wire         m_rlast,
    input  wire         m_rready
);

    // NPU 主口的输出 (只取 valid 用于空从机; 地址/data 留给波形直接层级探针)
    wire         npu_m_awvalid, npu_m_wvalid,  npu_m_arvalid;
    wire         npu_m_bready,  npu_m_rready;
    wire [31:0]  npu_m_awaddr,  npu_m_araddr;
    wire [127:0] npu_m_wdata,   npu_m_rdata;
    wire [15:0]  npu_m_wstrb;
    wire         npu_m_wlast;
    wire [5:0]   npu_m_awid,    npu_m_arid;
    wire [7:0]   npu_m_awlen,   npu_m_arlen;
    wire [2:0]   npu_m_awsize,  npu_m_awprot, npu_m_arsize, npu_m_arprot;
    wire [1:0]   npu_m_awburst, npu_m_arburst;
    wire         npu_m_awlock,  npu_m_arlock;
    wire [3:0]   npu_m_awcache, npu_m_awqos, npu_m_awregion;
    wire [3:0]   npu_m_arcache, npu_m_arqos, npu_m_arregion;

    wire         npu_m_awready, npu_m_wready, npu_m_arready;
    wire         npu_m_bvalid,  npu_m_rvalid, npu_m_rlast;
    wire [1:0]   npu_m_bresp,   npu_m_rresp;
    wire [5:0]   npu_m_bid,     npu_m_rid;

    RvvCoreMiniAxi u_core (
        .io_aclk            (clk),
        .io_aresetn         (npu_aresetn),

        // ---- 控制/中断: 全部接常量 ----
        // io_te 是扫描测试使能, 置 1 会旁路内部的复位同步器 ⇒ 必须为 0
        .io_te              (1'b0),
        .io_irq             (1'b0),
        .io_timer_irq       (1'b0),
        .io_software_irq    (1'b0),
        // 启动地址 0 ⇒ 程序入口就是 ITCM 本地 0.
        // pcStartReg 复位后第一拍从这个端口载入; 我们随后还会显式写
        // CSR+0x004, 两者一致 ⇒ 无论走哪条路入口都是 0.
        .io_boot_addr       (32'h0),

        // ---- 状态 ----
        .io_halted          (npu_halted),
        .io_fault           (npu_fault),
        .io_wfi             (npu_wfi),

        // ---- AXI 从口 (主机侧加载程序 / 配 CSR) ----
        .io_axi_slave_write_addr_valid      (m_awvalid),
        .io_axi_slave_write_addr_ready      (m_awready),
        .io_axi_slave_write_addr_bits_addr  (m_awaddr),
        .io_axi_slave_write_addr_bits_prot  (3'b010),   // 非特权/安全/数据
        .io_axi_slave_write_addr_bits_id    (6'd0),
        .io_axi_slave_write_addr_bits_len   (8'd0),     // 单拍
        .io_axi_slave_write_addr_bits_size  (3'd2),     // 4 字节/拍
        .io_axi_slave_write_addr_bits_burst (2'b01),    // INCR
        .io_axi_slave_write_addr_bits_lock  (1'b0),
        .io_axi_slave_write_addr_bits_cache (4'b0),
        .io_axi_slave_write_addr_bits_qos   (4'b0),
        .io_axi_slave_write_addr_bits_region(4'b0),
        .io_axi_slave_write_data_valid      (m_wvalid),
        .io_axi_slave_write_data_ready      (m_wready),
        .io_axi_slave_write_data_bits_data  (m_wdata),
        .io_axi_slave_write_data_bits_strb  (m_wstrb),
        .io_axi_slave_write_data_bits_last  (m_wlast),
        .io_axi_slave_write_resp_valid      (m_bvalid),
        .io_axi_slave_write_resp_ready      (m_bready),
        .io_axi_slave_write_resp_bits_id    (m_bid),
        .io_axi_slave_write_resp_bits_resp  (m_bresp),
        .io_axi_slave_read_addr_valid       (m_arvalid),
        .io_axi_slave_read_addr_ready       (m_arready),
        .io_axi_slave_read_addr_bits_addr   (m_araddr),
        .io_axi_slave_read_addr_bits_prot   (3'b010),
        .io_axi_slave_read_addr_bits_id     (6'd0),
        .io_axi_slave_read_addr_bits_len    (8'd0),
        .io_axi_slave_read_addr_bits_size   (3'd2),
        .io_axi_slave_read_addr_bits_burst  (2'b01),
        .io_axi_slave_read_addr_bits_lock   (1'b0),
        .io_axi_slave_read_addr_bits_cache  (4'b0),
        .io_axi_slave_read_addr_bits_qos    (4'b0),
        .io_axi_slave_read_addr_bits_region (4'b0),
        .io_axi_slave_read_data_valid       (m_rvalid),
        .io_axi_slave_read_data_ready       (m_rready),
        .io_axi_slave_read_data_bits_data   (m_rdata),
        .io_axi_slave_read_data_bits_id     (m_rid),
        .io_axi_slave_read_data_bits_resp   (m_rresp),
        .io_axi_slave_read_data_bits_last   (m_rlast),

        // ---- AXI 主口 → 空从机 ----
        .io_axi_master_write_addr_valid     (npu_m_awvalid),
        .io_axi_master_write_addr_ready     (npu_m_awready),
        .io_axi_master_write_addr_bits_addr (npu_m_awaddr),
        .io_axi_master_write_addr_bits_prot (npu_m_awprot),
        .io_axi_master_write_addr_bits_id   (npu_m_awid),
        .io_axi_master_write_addr_bits_len  (npu_m_awlen),
        .io_axi_master_write_addr_bits_size (npu_m_awsize),
        .io_axi_master_write_addr_bits_burst(npu_m_awburst),
        .io_axi_master_write_addr_bits_lock (npu_m_awlock),
        .io_axi_master_write_addr_bits_cache(npu_m_awcache),
        .io_axi_master_write_addr_bits_qos  (npu_m_awqos),
        .io_axi_master_write_addr_bits_region(npu_m_awregion),
        .io_axi_master_write_data_valid     (npu_m_wvalid),
        .io_axi_master_write_data_ready     (npu_m_wready),
        .io_axi_master_write_data_bits_data (npu_m_wdata),
        .io_axi_master_write_data_bits_strb (npu_m_wstrb),
        .io_axi_master_write_data_bits_last (npu_m_wlast),
        .io_axi_master_write_resp_valid     (npu_m_bvalid),
        .io_axi_master_write_resp_ready     (npu_m_bready),
        .io_axi_master_write_resp_bits_id   (npu_m_bid),
        .io_axi_master_write_resp_bits_resp (npu_m_bresp),
        .io_axi_master_read_addr_valid      (npu_m_arvalid),
        .io_axi_master_read_addr_ready      (npu_m_arready),
        .io_axi_master_read_addr_bits_addr  (npu_m_araddr),
        .io_axi_master_read_addr_bits_prot  (npu_m_arprot),
        .io_axi_master_read_addr_bits_id    (npu_m_arid),
        .io_axi_master_read_addr_bits_len   (npu_m_arlen),
        .io_axi_master_read_addr_bits_size  (npu_m_arsize),
        .io_axi_master_read_addr_bits_burst (npu_m_arburst),
        .io_axi_master_read_addr_bits_lock  (npu_m_arlock),
        .io_axi_master_read_addr_bits_cache (npu_m_arcache),
        .io_axi_master_read_addr_bits_qos   (npu_m_arqos),
        .io_axi_master_read_addr_bits_region(npu_m_arregion),
        .io_axi_master_read_data_valid      (npu_m_rvalid),
        .io_axi_master_read_data_ready      (npu_m_rready),
        .io_axi_master_read_data_bits_data  (npu_m_rdata),
        .io_axi_master_read_data_bits_id    (npu_m_rid),
        .io_axi_master_read_data_bits_resp  (npu_m_rresp),
        .io_axi_master_read_data_bits_last  (npu_m_rlast),

        // ---- 调试模块: 主机侧永远不发请求 ----
        // io_dm.req 在 CoreAxi 里是 Flipped(Decoupled) ⇒ valid/bits 是输入,
        // ready 是输出; io_dm.rsp 反过来. req_valid 恒 0 就不会产生 rsp;
        // rsp_ready 给 1 是防御性的 (万一有响应也不至于反压住).
        .io_dm_req_valid        (1'b0),
        .io_dm_req_bits_address (32'h0),
        .io_dm_req_bits_data    (32'h0),
        .io_dm_req_bits_op      (2'h0),
        .io_dm_rsp_ready        (1'b1)
    );

    // -----------------------------------------------------------------------
    // 空从机 —— NPU 主口的唯一去处
    //
    // ⚠️ 这里**必须**给一个会应答的从机, 不能把 arready/rvalid/awready/bready
    //    悬空或恒 0. 理由: NPU 的 io.dbus.ready 依赖响应到达 (DBus2Axi 里 ready
    //    由 resp.fire/data.fire 驱动), 所以任何一次落到 TCM 之外的访存都会让
    //    LSU **永久卡死** —— 没有 fault, 没有 halted, CPU 侧只能看到轮询 BUSY
    //    到超时, 完全不知道发生了什么.
    //
    //    回 SLVERR 而不是 OKAY, 是为了让"程序跑飞出了 TCM"变成**可诊断的
    //    fault** (粘滞到 io_fault, 经 STATUS.fault 位被 CPU 读到), 而不是一个
    //    看起来正常的错误数据.
    //
    // 实现: 无条件接收 (三个 ready 恒 1), 收到 valid 后下一拍给响应, 响应被
    //       取走才允许刷新. 上游只发 id=0 (核内有断言), 所以 bid/rid 直接接 0,
    //       不需要 ID 路由; 写恒单拍 (wlast=1), 读恒单拍, 所以无需突发计数.
    // -----------------------------------------------------------------------
    reg bvalid_r, rvalid_r;

    always @(posedge clk or negedge npu_aresetn) begin
        if (!npu_aresetn) begin
            bvalid_r <= 1'b0;
            rvalid_r <= 1'b0;
        end else begin
            if (!bvalid_r || npu_m_bready)
                bvalid_r <= npu_m_awvalid && npu_m_wvalid;
            if (!rvalid_r || npu_m_rready)
                rvalid_r <= npu_m_arvalid;
        end
    end

    assign npu_m_awready = 1'b1;
    assign npu_m_wready  = 1'b1;
    assign npu_m_arready = 1'b1;

    assign npu_m_bvalid = bvalid_r;
    assign npu_m_bresp  = 2'b10;    // SLVERR
    assign npu_m_bid    = 6'd0;

    assign npu_m_rvalid = rvalid_r;
    assign npu_m_rdata  = 128'd0;
    assign npu_m_rresp  = 2'b10;    // SLVERR
    assign npu_m_rlast  = 1'b1;
    assign npu_m_rid    = 6'd0;

endmodule
