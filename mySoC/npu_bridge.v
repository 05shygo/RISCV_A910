`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// NPU 控制桥: myCPU 的 MMIO 寄存器窗口 ←→ CoralNPU 的 AXI 从口.
//
// 为什么需要这一层
// ----------------
// myCPU 的数据总线是**零握手**的 (见 perip_bridge.v:12-19 的接口约束):
//   * MMIO 读必须【当拍组合返回】—— MEM 级没有 ready/busy/stall
//   * 存储周期必须保持读数据有效 —— MEM.v 用 Bus_rdata 给 sb/sh 做读-改-写
// 而 AXI 单拍往返是**多周期**的. 这两件事不可能直接对接.
//
// 所以本模块把 AXI 藏在一个**寄存器堆**后面:
//   * CPU 侧读的全部是触发器 (STATUS 的 halted/fault/wfi 三位是直连线)
//     ⇒ 组合有效, 零延迟契约原样保留, myCPU 一行都不用改
//   * CPU 通过 WADDR/WDATA/RADDR/RCMD 显式驱动一个访问引擎, 自己轮询 BUSY
//
// ⚠️ 不能用 sb/sh 访问本窗口. perip_bridge.v:18 写明"总线上看不出 sb/sh,
//    外设只能按整字 sw 写" —— 半字写会让读-改-写链把高 lane 的垃圾写进去.
//    测试程序里一律用 sw/lw.
//
// 寄存器映射 (偏移自 PERI_ADDR_NPU = 0x4000_0000)
// ------------------------------------------------
//   0x00  CTL      RW   bit0 resetn (0 = NPU 保持在复位; 复位值 0)
//   0x04  WADDR    RW   [17:0] 本地写地址; 每次 WDATA 被接收后自动 +4
//   0x08  WDATA    WO   写入即发起一次到 WADDR 的单拍 AXI 写
//   0x0C  STATUS   RO   {RVALID, wfi, fault, halted, OVERFLOW, ERR, BUSY}
//   0x10  RADDR    RW   [17:0] 本地读地址; 每次 RCMD 被接收后自动 +4
//   0x14  RCMD     WO   写入即发起一次到 RADDR 的单拍 AXI 读
//   0x18  RDATA    RO   最近一次读回的 32 位字
//   0x1C  ERRADDR  RO   最后一次失败事务的地址 (调试用)
//   0x20  ERRCLR   WO   写任意值 ⇒ 清 ERR / OVERFLOW / RVALID
//
// STATUS 位 (0x0C):
//   [0] BUSY      访问引擎忙, 或 NPU 复位保持计数未走完
//   [1] ERR       粘滞: 事务被拒 / 收到非 OKAY 响应 / 超时
//   [2] OVERFLOW  粘滞: BUSY 期间往 WDATA/RCMD 写, 请求被丢弃
//   [3] halted    NPU 的 io_halted 直连
//   [4] fault     NPU 的 io_fault  直连
//   [5] wfi       NPU 的 io_wfi    直连
//   [6] RVALID    读数据已就绪 (RDATA 有效)
//
// 地址是 **NPU 本地地址**, 不做基址减法:
//   ITCM 0x0000_0000 / DTCM 0x0001_0000 / CSR 0x0003_0000
// 与 IC2 版 Parameters.scala:44-48 的 MemoryRegions.default 一致.
//
// 32→128 位宽适配 (单拍)
// ----------------------
//   lane     = addr[3:2]
//   WDATA128 = {4{wdata32}} << (lane*32)
//   WSTRB16  = 16'h000F     << (lane*4)
//   RDATA32  = rdata128[lane*32 +: 32]
// 关键落位(已在 CoreAxiCSR.scala 核对):
//   CSR+0x00 (0x30000) lane=0 ⇒ WDATA[31:0]  / WSTRB[3:0]
//   CSR+0x04 (0x30004) lane=1 ⇒ WDATA[63:32] / WSTRB[7:4]   ← pcStart
//   CSR+0x08 (0x30008) lane=2 ⇒ RDATA[95:64]                ← status
// ---------------------------------------------------------------------------
module npu_bridge(
    input  wire        clk,
    input  wire        rst,          // 高有效, 用 fpga_rst (不是 rst_cpu)

    // ---------------- CPU 侧 (来自 perip_bridge 的解码) ----------------
    // 只有 Bus_addr[5:2] 被用到 (寄存器索引) —— 完整的地址解码在 perip_bridge
    // 里做, 它把 0x4000_0000-0x4000_0FFF 整个窗口折成 npu_sel 一根线.
    /* verilator lint_off UNUSED */
    input  wire [31:0] Bus_addr,
    input  wire [31:0] Bus_wdata,
    input  wire        Bus_wen,
    input  wire        npu_sel,      // 地址落在 NPU 窗口内
    output wire [31:0] npu_rdata,

    // ---------------- NPU 状态 ----------------
    output wire        npu_aresetn,  // → npu_core_wrap → RvvCoreMiniAxi.io_aresetn
    input  wire        npu_halted,
    input  wire        npu_fault,
    input  wire        npu_wfi,

    // ---------------- AXI 主端 (→ npu_core_wrap → NPU 的 axi_slave) ----------------
    output reg  [31:0]  m_awaddr,
    output reg          m_awvalid,
    input  wire         m_awready,
    output reg  [127:0] m_wdata,
    output reg  [15:0]  m_wstrb,
    output reg          m_wvalid,
    output wire         m_wlast,
    input  wire         m_wready,
    input  wire         m_bvalid,
    input  wire [1:0]   m_bresp,
    input  wire [5:0]   m_bid,
    output reg          m_bready,
    output reg  [31:0]  m_araddr,
    output reg          m_arvalid,
    input  wire         m_arready,
    input  wire         m_rvalid,
    input  wire [127:0] m_rdata,
    input  wire [1:0]   m_rresp,
    input  wire [5:0]   m_rid,
    input  wire         m_rlast,
    output reg          m_rready
);

    // ---------------- 寄存器索引 ----------------
    localparam A_CTL     = 4'h0;   // 0x00 >> 2
    localparam A_WADDR   = 4'h1;   // 0x04
    localparam A_WDATA   = 4'h2;   // 0x08
    localparam A_STATUS  = 4'h3;   // 0x0C
    localparam A_RADDR   = 4'h4;   // 0x10
    localparam A_RCMD    = 4'h5;   // 0x14
    localparam A_RDATA   = 4'h6;   // 0x18
    localparam A_ERRADDR = 4'h7;   // 0x1C
    localparam A_ERRCLR  = 4'h8;   // 0x20

    // 写脉冲: Bus_wdata 在 Bus_wen==0 时是旧值垃圾, 所有写一律用 wen 限定
    // (perip_bridge.v:17).
    wire       we     = Bus_wen & npu_sel;
    wire [3:0] regidx = Bus_addr[5:2];

    // ---------------- 状态 ----------------
    reg [1:0]  ctl;          // bit0 = resetn
    reg [17:0] waddr;
    reg [17:0] raddr;
    reg [17:0] raddr_l;      // 读请求发出那一刻的地址快照 (lane 选择要用它)
    reg [31:0] rdat;
    reg [31:0] erraddr;
    reg        err;
    reg        ovf;
    reg        rvalid_reg;

    // 复位保持计数: 软件写 CTL[0]=1 之后等 16 拍再放事务过去.
    // 确定性覆盖 NPU 内部的 RstSync (2 拍) + axiEnable (1 拍), 不依赖
    // 软件的延时循环 (doc/integration_guide.md:167-168 要求"时钟必须在
    // 复位有效期间跑够拍数"之后才能放开门控).
    reg [4:0]  rel_cnt;

    // 超时计数器. 存在的意义是**保证 CPU 永远不会因为这个 AXI 口死锁** ——
    // 一个挂死的从端必须变成可读的 ERR, 而不是让 CPU 把 BUSY 轮询到天荒地老.
    reg [11:0] timeout_cnt;

    // 写通道 FSM
    localparam W_IDLE = 2'd0, W_ADDR = 2'd1, W_RESP = 2'd2;
    reg [1:0] wstate;
    reg       aw_done, w_done;

    // 读通道 FSM
    localparam R_IDLE = 2'd0, R_ADDR = 2'd1, R_DATA = 2'd2;
    reg [1:0] rstate;

    wire rel_busy = (rel_cnt != 5'd0);
    wire w_busy   = (wstate != W_IDLE);
    wire r_busy   = (rstate != R_IDLE);
    wire busy     = rel_busy | w_busy | r_busy;

    // CPU 请求脉冲
    wire w_req = we && (regidx == A_WDATA);
    wire r_req = we && (regidx == A_RCMD);
    wire clr   = we && (regidx == A_ERRCLR);

    // 请求被接受: 只在空闲 且 NPU 已放复位 时
    wire w_go = w_req && (wstate == W_IDLE) && !rel_busy && ctl[0];
    wire r_go = r_req && (rstate == R_IDLE) && !rel_busy && ctl[0];

    // 被拒: 总线来了请求但没被接走
    wire w_rej = w_req && !w_go;
    wire r_rej = r_req && !r_go;

    // ---------------- 32→128 lane 编码 ----------------
    wire [1:0]   wlane      = waddr[3:2];
    wire [127:0] wdata_lane = {4{Bus_wdata}} << {wlane, 5'b0};   // lane*32
    wire [15:0]  wstrb_lane = 16'h000F << {wlane, 2'b0};         // lane*4

    reg [31:0] rdata_mux;
    always @(*) begin
        case (raddr_l[3:2])
            2'd0:    rdata_mux = m_rdata[31:0];
            2'd1:    rdata_mux = m_rdata[63:32];
            2'd2:    rdata_mux = m_rdata[95:64];
            default: rdata_mux = m_rdata[127:96];
        endcase
    end

    // ---------------- 超时触发 ----------------
    wire timeout_fire = (w_busy || r_busy) && (timeout_cnt == 12'hFFF);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ctl         <= 2'd0;      // resetn=0 ⇒ NPU 上电处于复位
            waddr       <= 18'd0;
            raddr       <= 18'd0;
            raddr_l     <= 18'd0;
            rdat        <= 32'd0;
            erraddr     <= 32'd0;
            err         <= 1'b0;
            ovf         <= 1'b0;
            rvalid_reg  <= 1'b0;
            rel_cnt     <= 5'd0;
            timeout_cnt <= 12'd0;
            wstate      <= W_IDLE;
            rstate      <= R_IDLE;
            aw_done     <= 1'b0;
            w_done      <= 1'b0;
            m_awaddr    <= 32'd0;
            m_awvalid   <= 1'b0;
            m_wdata     <= 128'd0;
            m_wstrb     <= 16'd0;
            m_wvalid    <= 1'b0;
            m_bready    <= 1'b0;
            m_araddr    <= 32'd0;
            m_arvalid   <= 1'b0;
            m_rready    <= 1'b0;
        end else begin
            // ---------- 普通寄存器写 ----------
            if (we && regidx == A_CTL) begin
                // 只在 0→1 时启动保持计数 (重复写 1 不重装)
                if (Bus_wdata[0] && !ctl[0]) rel_cnt <= 5'd16;
                ctl <= Bus_wdata[1:0];
            end
            if (we && regidx == A_WADDR) waddr <= Bus_wdata[17:0];
            if (we && regidx == A_RADDR) raddr <= Bus_wdata[17:0];
            if (clr) begin
                err        <= 1'b0;
                ovf        <= 1'b0;
                rvalid_reg <= 1'b0;
            end

            if (rel_busy) rel_cnt <= rel_cnt - 5'd1;

            // ---------- 请求被拒的记账 ----------
            if (w_rej || r_rej) begin
                if (rel_busy) err <= 1'b1;          // 复位还没放, 直接拒绝
                else          ovf <= 1'b1;          // 忙, 丢弃
                erraddr <= {14'd0, (w_rej ? waddr : raddr)};
            end
            if (w_go) rvalid_reg <= 1'b0;           // 有新的写, 旧读数据作废

            // ---------- 超时计数 ----------
            if (w_go || r_go)               timeout_cnt <= 12'd0;
            else if (w_busy || r_busy) begin
                if (!timeout_fire)          timeout_cnt <= timeout_cnt + 12'd1;
            end else                        timeout_cnt <= 12'd0;

            if (timeout_fire) begin
                err     <= 1'b1;
                erraddr <= {14'd0, (w_busy ? waddr : raddr)};
            end

            // ---------- 通道 FSM ----------
            // 超时有最高优先级: 强制回空闲并释放总线. 这一支必须写在 case
            // **外面并包住它** —— 同一个 always 块里后面的赋值覆盖前面的,
            // 若把超时写在前面, 会被下面 case 里的赋值盖掉, 等于没做.
            if (timeout_fire) begin
                wstate    <= W_IDLE;
                rstate    <= R_IDLE;
                aw_done   <= 1'b0;
                w_done    <= 1'b0;
                m_awvalid <= 1'b0;
                m_wvalid  <= 1'b0;
                m_bready  <= 1'b0;
                m_arvalid <= 1'b0;
                m_rready  <= 1'b0;
            end else begin
                // ----- 写通道 -----
                // AW 与 W 同时拉起, 各自独立退休; 两个都退休后等 B.
                // 单拍: AWLEN=0 ⇒ WLAST 恒 1 (常量在 npu_core_wrap 里给).
                case (wstate)
                    W_IDLE: begin
                        m_awvalid <= 1'b0;
                        m_wvalid  <= 1'b0;
                        m_bready  <= 1'b0;
                        aw_done   <= 1'b0;
                        w_done    <= 1'b0;
                        if (w_go) begin
                            m_awaddr  <= {14'd0, waddr};
                            m_wdata   <= wdata_lane;
                            m_wstrb   <= wstrb_lane;
                            m_awvalid <= 1'b1;
                            m_wvalid  <= 1'b1;
                            wstate    <= W_ADDR;
                        end
                    end
                    W_ADDR: begin
                        if (m_awready) m_awvalid <= 1'b0;
                        if (m_wready)  m_wvalid  <= 1'b0;
                        if ((m_awready | aw_done) && (m_wready | w_done)) begin
                            m_bready <= 1'b1;
                            wstate   <= W_RESP;
                        end else begin
                            if (m_awready) aw_done <= 1'b1;
                            if (m_wready)  w_done  <= 1'b1;
                        end
                    end
                    W_RESP: begin
                        if (m_bvalid) begin
                            m_bready <= 1'b0;
                            wstate   <= W_IDLE;
                            if ((m_bresp != 2'b00) || (m_bid != 6'd0)) begin
                                err     <= 1'b1;
                                erraddr <= {14'd0, waddr};
                            end
                            // 无论成败都自增 —— 让软件的重试/跳过逻辑简单
                            waddr <= waddr + 18'd4;
                        end
                    end
                    default: wstate <= W_IDLE;
                endcase

                // ----- 读通道 -----
                case (rstate)
                    R_IDLE: begin
                        m_arvalid <= 1'b0;
                        m_rready  <= 1'b0;
                        if (r_go) begin
                            m_araddr  <= {14'd0, raddr};
                            raddr_l   <= raddr;      // 快照: lane 选择必须用它
                            m_arvalid <= 1'b1;
                            rstate    <= R_ADDR;
                        end
                    end
                    R_ADDR: begin
                        if (m_arready) begin
                            m_arvalid <= 1'b0;
                            m_rready  <= 1'b1;
                            rstate    <= R_DATA;
                        end
                    end
                    R_DATA: begin
                        if (m_rvalid) begin
                            m_rready <= 1'b0;
                            rstate   <= R_IDLE;
                            // rlast 必须为 1: 我们的 AR 恒为 len=0 (单拍),
                            // 多拍返回说明从端行为不符预期, 当错误处理.
                            if ((m_rresp != 2'b00) || (m_rid != 6'd0) || !m_rlast) begin
                                err     <= 1'b1;
                                erraddr <= {14'd0, raddr_l};
                            end else begin
                                rdat       <= rdata_mux;
                                rvalid_reg <= 1'b1;
                            end
                            raddr <= raddr + 18'd4;
                        end
                    end
                    default: rstate <= R_IDLE;
                endcase
            end
        end
    end

    assign m_wlast     = 1'b1;        // 单拍写, 恒为末拍
    assign npu_aresetn = ctl[0];

    // ---------------- 读选择 ----------------
    // 全部来自触发器 (或直连线) ⇒ 当拍组合返回, 满足 MEM 级的零延迟契约.
    // 每个分支都赋值, 未实现的偏移读回 0 而不是 X (照 perip_bridge.v:126-131).
    reg [31:0] rdata_reg;
    always @(*) begin
        case (regidx)
            A_CTL:     rdata_reg = {30'd0, ctl};
            A_WADDR:   rdata_reg = {14'd0, waddr};
            A_WDATA:   rdata_reg = 32'd0;               // WO, 读回 0
            A_STATUS:  rdata_reg = {25'd0, rvalid_reg, npu_wfi, npu_fault,
                                    npu_halted, ovf, err, busy};
            A_RADDR:   rdata_reg = {14'd0, raddr};
            A_RCMD:    rdata_reg = 32'd0;               // WO
            A_RDATA:   rdata_reg = rdat;
            A_ERRADDR: rdata_reg = erraddr;
            A_ERRCLR:  rdata_reg = 32'd0;               // WO
            default:   rdata_reg = 32'd0;
        endcase
    end

    assign npu_rdata = npu_sel ? rdata_reg : 32'd0;

endmodule
