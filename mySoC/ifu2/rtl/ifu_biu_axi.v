`timescale 1ns / 1ps

//----------------------------------------------------------------------------
// ifu_biu_axi — IFU 的 BIU 主口到 ct_biu_top 的 AXI4 读通道之间的协议翻译
//
//---------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
//---------------------------------------------------------------------------
//
// Purpose : 把 rv32ifu2_top 的 BIU 主口 (req/grnt 协议) 翻译成 ct_biu_top 的
//           IFU 口 (标准 AXI4 AR/R 通道)。
//
//   rv32ifu2_top 的 BIU 主口沿用 C910 的形式: 一笔事务用 `req & grnt` 在同一拍
//   成交, 带 `rd_id` (0=demand / 1=prefetch) 与 `rd_len` (2'b11=64 B 行 4 拍 /
//   2'b00=16 B 单拍); 返回侧用 `data_vld`/`last`/`resp` 加 `r_ready` 反压。
//   它原本的对手方是 mySoC/ifu_biu_mem.v (一块指令 ROM)。
//
//   而 `ct_biu_top` (C906 移植) 露出来的 IFU 口是标准 AXI4 AR/R:
//   `arvalid`/`arready`/`arlen`/`arsize`/`arburst` 与 `rvalid`/`rready`/`rlast`/
//   `rresp`。两者不能直连, 本模块就是那层翻译。
//
//   C910 原版把这段翻译藏在 ct_biu_req_arbiter.v 里 (它的 IFU 侧本来就是
//   req/grnt)。我们的 BIU 是精简移植, IFU 口直接做成了 AXI 样式, 所以翻译得由
//   我们这一侧提供。
//
// Usage :
//   mySoC/A910_cpu.sv 里例化, 夹在 rv32ifu2_top 与 ct_biu_top 之间。
//   端口命名沿用两侧各自的原名 —— `biu_rd_*` / `biu_r_ready` 是 IFU 的,
//   `ifu_biu_*` / `biu_ifu_r*` 是 BIU 的 —— 于是顶层三段都是同名对接。
//
//   注意 `biu_r_ready` (IFU 侧, 输入) 与 `ifu_biu_rready` (BIU 侧, 输出) 只差
//   一个下划线, 是两根不同的线: 前者是 IFU 告诉本模块"我这一拍能收", 后者是
//   本模块告诉 BIU"我这一拍能收"。两边各自的名字就是这么定的, 不要合并。
//
// Timing :
//   AXI 侧只做单笔在途 (busy_q 锁住), 不做流水重叠。三条时序约定, 每条背后都有
//   踩过的坑:
//
//   1. **AR 不能裸接 req**。`biu_rd_req` 是电平 (IFU 的 refill FSM 里就是
//      `state_q == S_REQ`), 会一直拉到成交之后那一拍。裸接会让同一笔请求在
//      `arready` 持续为 1 时重复发出。这里用 busy_q 把"已发出、还没收完"锁住。
//
//   2. **grant 寄存一拍**。契约 (见 mySoC/ifu_biu_mem.v 头注释) 写明"grant 当拍
//      IFU 内部的 outstanding 寄存器还没置位, 那拍不能驱动 data_vld"; 而
//      rv32ifu2_refill 的 FSM 只在 S_WAIT 收数据 (`refill_en =
//      (state_q == S_WAIT) & fire`) —— **在 S_REQ 那拍回来的数据会被静默丢掉,
//      FSM 就此挂死**。AXI 允许从端在 AR 握手同一拍就返回 R (读数据先于地址
//      成交是合法的), 所以 `grnt = arready` 的裸接法有真实风险。
//
//   3. **R 通道也寄存一拍**, 与第 2 条配套。两条一起寄存不会比"组合 grant +
//      寄存 R"多付延迟: 两种写法数据都落在 AR 成交后的第 2 拍, 但寄存 grant
//      没有"从端同拍返回"的组合路径风险。
//
//   完成判据用**拍数**而不是 RLAST: 请求时 `rd_len` 就决定了这一笔有几拍
//   (2'b11 是 4 拍, 其余是 1 拍), 所以本模块自己数拍就能知道事务何时结束, 不
//   依赖从端把 RLAST 打对。`biu_rd_last` 仍然原样透传给 IFU —— 它目前不看,
//   但契约上有这根线。
//
//   当前只有单拍那支跑得到: rv32ifu2_refill.v 里 `rd_id` 恒 0、`rd_len` 恒
//   2'b00, prefetch 从未发起过。4 拍那支**跑不到、仿真测不出来**, 逻辑照写全,
//   将来上预取时先给它补用例。
//----------------------------------------------------------------------------

module ifu_biu_axi

  //---------------------------------------------------------------------------
  // Ports
  //---------------------------------------------------------------------------
  (
    // Global signals
    input  wire         clk,
    input  wire         rst,              // 高有效, 与 IFU/RTU 同极性

    // IFU 侧: req/grnt 主端 (rv32ifu2_top 的原端口名)
    input  wire         biu_rd_req,
    input  wire [ 31:0] biu_rd_addr,      // 字节地址, 已按行对齐, [3:0]==0
    input  wire         biu_rd_id,        // 0=demand 1=prefetch
    input  wire [  1:0] biu_rd_len,       // 2'b11=4 拍(64 B 行) 2'b00=单拍(16 B)
    output wire         biu_rd_grnt,
    output wire         biu_rd_data_vld,
    output wire [127:0] biu_rd_data,
    output wire         biu_rd_rid,
    output wire         biu_rd_last,
    output wire [  1:0] biu_rd_resp,
    input  wire         biu_r_ready,      // IFU 侧 ready (refill FSM 里恒 1)

    // BIU 侧: AXI4 读地址/读数据 (ct_biu_top 的原端口名)
    output wire [ 31:0] ifu_biu_araddr,
    output wire [  1:0] ifu_biu_arlen,    // AXI 语义: 拍数 - 1
    output wire [  2:0] ifu_biu_arsize,   // 3'b100 = 16 B/拍
    output wire [  1:0] ifu_biu_arburst,  // 4 拍 = WRAP (2'b10), 单拍 = INCR (2'b01)
    output wire [  3:0] ifu_biu_arcache,
    output wire [  2:0] ifu_biu_arprot,
    output wire         ifu_biu_arvalid,
    input  wire         ifu_biu_arready,
    output wire [  3:0] ifu_biu_rid,      // ct_biu_top 内部拼成 {3'b100, rid}
    input  wire [127:0] biu_ifu_rdata,
    input  wire         biu_ifu_rvalid,
    input  wire         biu_ifu_rlast,
    input  wire [  1:0] biu_ifu_rresp,
    input  wire         biu_ifu_rid,
    output wire         ifu_biu_rready
  );

  // ---------------------------------------------------------------------------
  //  Local parameters
  // ---------------------------------------------------------------------------
  // 取数与 LSU 同一套值 (见 lsu/rtl/lsu_mshr.sv 里 rb_biu_ar_* 那三行), 让整个
  // 系统对下游看到的 cache/prot 口径一致, 而不是各写一份。IFU 一律 16 B/拍。
  // ct_biu_top 目前把这三个原样透传给 pad —— 真正消费它们的是片外的 interconnect
  // 或存储, 所以这里给"系统中立"的常量即可。
  localparam [2:0] AR_SIZE  = 3'b100;   // 16 B/拍
  localparam [3:0] AR_CACHE = 4'b1111;  // cacheable + bufferable (同 LSU)
  localparam [2:0] AR_PROT  = 3'b000;   // 本核没有特权/安全域模型 (同 LSU)

  // ---------------------------------------------------------------------------
  //  Signal declarations
  // ---------------------------------------------------------------------------
  // R 通道寄存一拍。`rid_q` 存的是本笔请求的 rd_id, 在 AR 成交时捕获, 不是 R
  // 带上来的 —— 见下面 p_ar 里的说明。
  reg  [127:0] rdata_q;
  reg          rlast_q;
  reg  [  1:0] rresp_q;
  reg          rid_q;
  reg          data_vld_q;

  // 给 IFU 的 grant, 寄存一拍 (见头注释 §Timing 第 2 条)。
  reg          grnt_q;

  // 本笔还剩几拍没收完 (0..4)。
  //
  // 宽度是 3 位, 不是 2 位。一笔最多 4 拍, 而 2 位寄存器装不下 4 —— 写成
  // `2'd4` 会被静默截成 0, VCS 只报一条 `Warning-[DCTTSW] Decimal constant
  // truncated`, 不报错。截成 0 的后果是 busy_q 永远落不下来, 第一笔 4 拍请求
  // 之后整个取指通路卡死。make a910-elab 把 DCTTSW 做成硬判据就是为了这个。
  reg  [  2:0] beat_left_q;

  // 一笔事务"AR 已成交、R 还没收完"。它同时挡住两件事:
  //   1. `req` 是电平, 成交后还会拉着, 没有它就会重复发 AR;
  //   2. 事务没在途时把 R 通道关掉, 免得下游来的野拍被当成取指数据收进来。
  reg          busy_q;

  // ---------------------------------------------------------------------------
  //  Functional code
  // ---------------------------------------------------------------------------

  // ---- AR 通道 ----
  wire ar_fire = ifu_biu_arvalid & ifu_biu_arready;

  assign ifu_biu_arvalid = biu_rd_req & ~busy_q;
  assign ifu_biu_araddr  = biu_rd_addr;

  // ct_biu_top.sv 把 `ifu_biu_rid` 声明成 [ID_WIDTH-1:0] (4 位), 而真正消费它的
  // ct_biu_req_arbiter.sv 是 1 位 —— 只有 bit0 有效。这里按 1 位驱动、高位补 0,
  // 与下游实际用到的口径一致。那条宽度不一致是 BIU 侧的已知项。
  assign ifu_biu_rid     = {3'b000, biu_rd_id};

  // `rd_len` 是 "2'b11 = 4 拍" 这个 IFU 私有编码, 不是 AXI 的"拍数 - 1"。
  // 换算成 AXI: 4 拍 → arlen=2'b11, 1 拍 → arlen=2'b00; 两者数值上碰巧一样,
  // 但别把这条巧合当成恒等式 —— 将来若加 8 拍编码就分了。
  //
  // burst 必须是 WRAP: 64 B 行内的拍序是"以请求的那个 16 B 块为首、模 4 回绕"
  // (见 ifu_biu_mem.v 头注释), INCR 的拍序对不上, i-cache 填进去的行会错位。
  wire        four_beat = (biu_rd_len == 2'b11);
  assign ifu_biu_arlen   = four_beat ? 2'b11 : 2'b00;
  assign ifu_biu_arburst = four_beat ? 2'b10 : 2'b01;
  assign ifu_biu_arsize  = AR_SIZE;
  assign ifu_biu_arcache = AR_CACHE;
  assign ifu_biu_arprot  = AR_PROT;

  // ---- R 通道: 寄存一拍 + 反压 ----
  // 只有"事务在途、还有拍没收、手上那拍已被 IFU 取走 (或本来就空)"才从 BIU 收
  // 下一拍。`beat_left_q != 0` 这一项顺带保证了 AR 成交那一拍不收任何数据 ——
  // 它是头注释 §Timing 第 2 条的第二道保险。
  wire r_fire = biu_ifu_rvalid & ifu_biu_rready;

  assign ifu_biu_rready = busy_q & (beat_left_q != 3'd0)
                        & (~data_vld_q | biu_r_ready);

  // IFU 这一拍真的把手上那拍取走了 (`biu_r_ready` 在 refill FSM 里恒 1)。
  wire beat_taken = data_vld_q & biu_r_ready;

  assign biu_rd_grnt     = grnt_q;
  assign biu_rd_data_vld = data_vld_q;
  assign biu_rd_data     = rdata_q;
  assign biu_rd_last     = rlast_q;
  assign biu_rd_resp     = rresp_q;
  assign biu_rd_rid      = rid_q;

  // ---- AR 成交: 置 busy, 给 IFU 一个 grant 脉冲, 锁下本笔的拍数与 id ----
  always @(posedge clk or posedge rst)
  begin : p_ar
    if (rst)
    begin
      busy_q      <= 1'b0;
      grnt_q      <= 1'b0;
      beat_left_q <= 3'd0;
      rid_q       <= 1'b0;
    end
    else
    begin
      grnt_q <= ar_fire;

      if (ar_fire)
      begin
        // 拍数在**请求时**就定下来, 之后不再改 —— 完成判据不依赖 RLAST。
        beat_left_q <= four_beat ? 3'd4 : 3'd1;

        // rd_id 在 AR 成交时捕获。单笔在途时它与 R 带回来的 rid 同值, 但捕获
        // 不依赖下游把 RID 原样回显: 下游若改了 RID, 那一拍压根不会路由到 IFU
        // 口 —— ct_biu_read_channel 按 pad_biu_rid[3] 分流, 数据直接丢掉。
        rid_q       <= biu_rd_id;
      end
      else if (r_fire)
      begin
        beat_left_q <= beat_left_q - 3'd1;
      end

      // busy 在 AR 成交时置起, 最后一拍被取走时落下。
      if (ar_fire)
        busy_q <= 1'b1;
      else if (beat_taken & (beat_left_q == 3'd1))
        busy_q <= 1'b0;
    end
  end // p_ar

  // ---- R: 每一拍装进寄存器, 被 IFU 取走那一拍清掉 ----
  // 两个分支都不成立时保持 —— 那是"IFU 没 ready"的反压态, 数据必须钉住。
  always @(posedge clk or posedge rst)
  begin : p_r
    if (rst)
    begin
      data_vld_q <= 1'b0;
      rdata_q    <= 128'd0;
      rlast_q    <= 1'b0;
      rresp_q    <= 2'd0;
    end
    else if (r_fire)
    begin
      data_vld_q <= 1'b1;
      rdata_q    <= biu_ifu_rdata;
      rlast_q    <= biu_ifu_rlast;
      rresp_q    <= biu_ifu_rresp;
    end
    else if (beat_taken)
    begin
      data_vld_q <= 1'b0;
    end
  end // p_r

endmodule
