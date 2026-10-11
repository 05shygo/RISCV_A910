`timescale 1ns / 1ps

// `sync_mem.v` 里也有同名宏; 单独编本文件时要有, 重复定义会告警 ⇒ 加守卫。
`ifndef STRINGIFY
  `define STRINGIFY(x) `"x`"
`endif

// ===========================================================================
// tb/a910/axi_slave_128.v —— A910_cpu 整核冒烟台的 AXI4 从机 + 128 位内存
// ===========================================================================
// A910_cpu 对外只有 clk/rst + 一组 AXI4 主机口 (IFU 与 LSU 共用 `ct_biu_top`
// 那一个口)。仓库里所有 AXI RTL 都是**主机侧**, 没有从机内存模型 ⇒ 这个文件补上。
//
// 规格不是猜的, 是从 `ct_biu_top` / `ifu_biu_axi` / `lsu_*` 的实际代码里读出来的。
// 下面五条**写错就跑不起来**, 每条都附了证据:
//
//  1) **`rid`/`bid` 必须原样回显 `arid`/`awid`** —— 最容易漏的一条。
//     `ct_biu_read_channel.sv:66-82` 按 `rid[3]` 分流: rid[3]=1 → IFU, 否则 LSU。
//     恒回 0 会把 IFU 的返回数据全判给 LSU ⇒ **取指通路直接挂死**。
//     B 通道同理: `lsu_wmb_entry.sv:489-493` 要求 bid 与该表项发出的 awid **逐位相等**。
//
//  2) **`rvalid` 拉起来后必须保持到 `rready`** (标准 AXI 握手, 不要写成"固定一拍")。
//     `ifu_biu_axi.v:177-178` 在 AR 成交那一拍**不收 R** —— 它的 rready 要等 busy_q
//     置起, 晚一拍。写成"固定 1 拍不看 rready"会丢掉 IFU 的第一拍返回。
//
//  3) **读侧必须支持 2 拍 WRAP** (LSU linefill 用: `lsu_mshr.sv:481-485`)。
//     拍序是"先回起始那 16B, 再回卷":
//         addr[4]=0 → {+0x00, +0x10}        addr[4]=1 → {+0x10, +0x00}
//     ⚠️ `lsu_lfb.sv:403` 那句 "first beat is always the low half" 与代码行为**矛盾**,
//        照行为做 —— 也和 openc906 的 `axi_slave128.v:362-383` 一致 (它在 addr[4]=1
//        且 step==0 时把地址 -0x10)。别照那句注释。
//     (`arlen=2'b11` 的 4 拍 WRAP 只在 IFU 预取的死代码里, 本模型不实现。)
//
//  4) **`wlast` 必须收对**, 否则 `ct_biu_write_channel.sv:148-157` 回不到 IDLE
//     ⇒ 写通道死锁。(store 是 1 拍, victim 回写是 2 拍, wlast 在第 2 拍。)
//
//  5) `arsize/awsize` 恒 `3'b100`(16B), 地址恒 16B 对齐 ⇒ **一拍就是一个 128 位块**。
//     块内字节 j = `rdata[8j+7:8j]` = 地址 `{addr[31:4], j}`。
//     写侧字节位置**只看 `wstrb`**(store 的 `awaddr[3:0]` 恒 0), 逐字节写, **不需要 RMW**。
//
// 内存镜像: `$readmemh(meminit128.hex)`, 每行 32 个 hex 字符 = 一拍 rdata,
// 所以 `mem[i][31:0]` 就是地址 `16*i` 处的字 (生成规则见 Makefile 的 HEX_PAD128)。
// ===========================================================================
module axi_slave_128 #(
    parameter MEM_BLOCKS = 4096          // 4096 × 16B = 64 KB
)(
    input  wire         clk,
    input  wire         rst,             // 高有效, 与 A910_cpu 同极性

    // ---- 读地址通道 ----
    input  wire [31:0]  araddr,
    input  wire [3:0]   arid,
    input  wire [1:0]   arlen,
    input  wire [2:0]   arsize,
    input  wire [1:0]   arburst,
    input  wire         arvalid,
    output wire         arready,

    // ---- 读数据通道 ----
    output wire [127:0] rdata,
    output wire [3:0]   rid,
    output wire         rlast,
    output wire [1:0]   rresp,
    output wire         rvalid,
    input  wire         rready,

    // ---- 写地址通道 ----
    input  wire [31:0]  awaddr,
    input  wire [3:0]   awid,
    input  wire [1:0]   awlen,
    input  wire [2:0]   awsize,
    input  wire [1:0]   awburst,
    input  wire         awvalid,
    output wire         awready,

    // ---- 写数据通道 ----
    input  wire [127:0] wdata,
    input  wire [15:0]  wstrb,
    input  wire         wlast,
    input  wire         wvalid,
    output wire         wready,

    // ---- 写响应通道 ----
    output wire [3:0]   bid,
    output wire [1:0]   bresp,
    output wire         bvalid,
    input  wire         bready
);

  // -------------------------------------------------------------------------
  // 内存: 128 位 × MEM_BLOCKS。先清零再 $readmemh —— 镜像没覆盖到的位置
  // $readmemh 会留 X, X 扩散进核里会变成极难定位的失配 (Makefile 的补零注释同源)。
  // -------------------------------------------------------------------------
  reg [127:0] mem [0:MEM_BLOCKS-1];

  integer k;
  initial begin
    for (k = 0; k < MEM_BLOCKS; k = k + 1) mem[k] = 128'b0;
    $readmemh(`STRINGIFY(`PATH128), mem);
  end

  // 只取地址的 [15:4] 当索引 (12 位 = MEM_BLOCKS)。
  // 好处: 越界地址会**自然回卷**而不是索引成 X —— 冒烟台最怕 X 到处扩散。
  // 64 KB 对冒烟用例绰绰有余, 真越界了也是程序写错, 不是这里该管的。
  function [11:0] blk_idx(input [31:0] a); begin blk_idx = a[15:4]; end endfunction

  // =========================================================================
  // 读通道
  // =========================================================================
  reg          rd_busy;      // AR 已收下, 还有拍没回完
  reg  [31:0]  rd_addr;      // **当前这一拍**的地址 (每拍按 burst 推进)
  reg  [3:0]   rd_id;
  reg  [1:0]   rd_len;
  reg  [1:0]   rd_burst;
  reg  [1:0]   rd_cnt;
  reg          rvalid_r;
  reg  [3:0]   rid_r;
  reg          rlast_r;

  assign arready = ~rd_busy;
  assign rvalid  = rvalid_r;
  assign rid     = rid_r;
  assign rlast   = rlast_r;
  assign rresp   = 2'b00;                       // 恒 OKAY: SLVERR/DECERR 会被 LSU 当总线错误
  // 组合读出: 下面 rd_addr 每拍推进, rdata 跟着走 —— 配合"rvalid 保持到 rready"是对的
  assign rdata   = mem[blk_idx(rd_addr)];

  // 2 拍 WRAP 的回卷: **起始在块上半 (addr[4]=1) 时第二拍要 -0x10**, 不是 +0x10
  wire        rd_wrap = (rd_burst == 2'b10);
  wire [31:0] rd_next = (rd_wrap && (rd_cnt == 2'b0) && rd_addr[4]) ? (rd_addr - 32'h10)
                                                                   : (rd_addr + 32'h10);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      rd_busy  <= 1'b0;
      rd_addr  <= 32'b0;
      rd_id    <= 4'b0;
      rd_len   <= 2'b0;
      rd_burst <= 2'b0;
      rd_cnt   <= 2'b0;
      rvalid_r <= 1'b0;
      rid_r    <= 4'b0;
      rlast_r  <= 1'b0;
    end
    else if (~rd_busy) begin
      // ---- 收 AR。rvalid 同拍就拉起来, 但**不保证当拍被收** (见文件头第 2 条) ----
      if (arvalid) begin
        rd_busy  <= 1'b1;
        rd_addr  <= araddr;
        rd_id    <= arid;
        rd_len   <= arlen;
        rd_burst <= arburst;
        rd_cnt   <= 2'b0;
        rvalid_r <= 1'b1;
        rid_r    <= arid;                       // ← 原样回显, 见文件头第 1 条
        rlast_r  <= (arlen == 2'b0);
      end
    end
    else if (rvalid_r && rready) begin
      if (rd_cnt == rd_len) begin
        rd_busy  <= 1'b0;
        rvalid_r <= 1'b0;
        rlast_r  <= 1'b0;
      end
      else begin
        rd_cnt  <= rd_cnt + 2'b1;
        rd_addr <= rd_next;
        rlast_r <= ((rd_cnt + 2'b1) == rd_len);
      end
    end
  end

  // =========================================================================
  // 写通道 (AW / W / B)
  // =========================================================================
  // 时序: AW 先收下并寄存, 之后才放开 wready —— 这样每一拍写数据都能安全地用
  // 寄存后的 wr_addr (不用去猜"这拍的 awaddr 还算不算数")。代价是 AW 与 W 同拍
  // 到达时 W 要多等一拍, 对冒烟用例无所谓, 换来的是不会出错。
  reg          aw_done;      // AW 已收, 还没写满
  reg  [31:0]  wr_addr;
  reg  [3:0]   wr_id;
  reg  [1:0]   wr_len;
  reg  [1:0]   wr_burst;
  reg  [1:0]   wr_cnt;
  reg          bvalid_r;

  assign awready = ~aw_done & ~bvalid_r;
  assign wready  = aw_done & ~bvalid_r;
  assign bvalid  = bvalid_r;
  assign bid     = wr_id;                       // ← 原样回显 awid
  assign bresp   = 2'b00;

  wire        wr_wrap = (wr_burst == 2'b10);
  wire [31:0] wr_next = (wr_wrap && (wr_cnt == 2'b0) && wr_addr[4]) ? (wr_addr - 32'h10)
                                                                    : (wr_addr + 32'h10);

  integer b;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      aw_done  <= 1'b0;
      wr_addr  <= 32'b0;
      wr_id    <= 4'b0;
      wr_len   <= 2'b0;
      wr_burst <= 2'b0;
      wr_cnt   <= 2'b0;
      bvalid_r <= 1'b0;
    end
    else begin
      if (awvalid && awready) begin
        aw_done  <= 1'b1;
        wr_addr  <= awaddr;
        wr_id    <= awid;
        wr_len   <= awlen;
        wr_burst <= awburst;
        wr_cnt   <= 2'b0;
      end

      if (wvalid && wready) begin
        // 逐字节写: **只看 wstrb**, 不看地址低位 (store 的 awaddr[3:0] 恒 0)
        for (b = 0; b < 16; b = b + 1)
          if (wstrb[b]) mem[blk_idx(wr_addr)][8*b +: 8] <= wdata[8*b +: 8];

        if (wr_cnt == wr_len) begin
          aw_done  <= 1'b0;
          wr_cnt   <= 2'b0;
          bvalid_r <= 1'b1;                     // wlast 那一拍回 B
        end
        else begin
          wr_cnt  <= wr_cnt + 2'b1;
          wr_addr <= wr_next;
        end
      end

      if (bvalid_r && bready) bvalid_r <= 1'b0;
    end
  end

  // =========================================================================
  // 观察口 (TB 用来判 PASS/FAIL, 不参与协议)
  // =========================================================================
  // 写通道上解码 MONITOR 魔数 —— 与 `mySoC/perip_bridge.v:21` 和 `asm/trap.S:343-351`
  // 同口径 (0x8000_0000: 0x0000_BEEF 通过 / 0x0000_DEAD 失败)。
  // ⚠️ `perip_bridge.v` **不在** A910_cpu 里, 所以这个解码只能由从机自己做。
  reg        mon_pass_r;
  reg        mon_fail_r;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      mon_pass_r <= 1'b0;
      mon_fail_r <= 1'b0;
    end
    else if (wvalid && wready && (wr_addr == 32'h8000_0000)) begin
      if (wdata[15:0] == 16'hBEEF) mon_pass_r <= 1'b1;
      if (wdata[15:0] == 16'hDEAD) mon_fail_r <= 1'b1;
    end
  end

  // 读通道活动计数: TB 用它判"核到底有没有在取指"
  integer rd_hs_cnt;
  always @(posedge clk or posedge rst) begin
    if (rst) rd_hs_cnt <= 0;
    else if (rvalid_r && rready) rd_hs_cnt <= rd_hs_cnt + 1;
  end

endmodule
