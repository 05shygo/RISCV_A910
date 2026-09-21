`timescale 1ns / 1ps
`include "defines.vh"

// ---------------------------------------------------------------------------
// 外设桥: 把 myCPU 的单条 Bus_* 拆成 DRAM + MMIO 外设.
//
// 之前 miniRV_SoC 把 Bus_addr 直接接 DRAM, 而 DRAM 只取 Bus_addr[15:2],
// 高 16 位被整个丢掉 —— 于是 0x80000000(测试结果) 和 0xFFFFF000(数码管)
// 这些 MMIO 地址会被静默截断成 DRAM 里某个字, 写坏了数据也无人知晓
// (difftest 发现不了: 存储指令不写寄存器, 比较不到).
//
// 接口约束 (来自 mySoC/MEM.v):
//   * 读必须【当拍组合返回】—— MEM 级没有 ready/busy/stall, Bus_rdata 到
//     regfile 是单周期组合链.
//   * 存储周期也必须保持 DRAM 读数据有效 —— MEM.v 用 Bus_rdata 给 sb/sh 做
//     读-改-写. 所以 dram_rdata 任何时候都在读, 不能按 Bus_wen 关掉.
//   * Bus_wdata 在 Bus_wen==0 时是垃圾(reg 保持旧值), 所有写一律用 Bus_wen 限定.
//   * 总线上看不出 sb/sh/sw —— 外设只能按整字 sw 写.
//
// 地址映射沿用 defines.vh / golden model 既有约定:
//   0x8000_0000 - 0x8000_0007  MONITOR  (0x00 pass 标志, 0x04 fail 标志)
//   0xFFFF_F000 - 0xFFFF_F003  DIG      (数码管)
//   0xFFFF_F040 - 0xFFFF_F04F  TIMER    (mtime / mtimecmp)
//   其余                        DRAM
// ---------------------------------------------------------------------------
module perip_bridge(
    input  wire        clk,
    input  wire        rst,

    // CPU 侧总线
    input  wire [31:0] Bus_addr,
    input  wire        Bus_wen,
    input  wire [31:0] Bus_wdata,
    output wire [31:0] Bus_rdata,

    // DRAM 侧
    output wire        dram_we,
    output wire [15:0] dram_word_addr,
    output wire [31:0] dram_wdata,
    input  wire [31:0] dram_rdata,

    // 板级 / 中断
    output wire [31:0] seg_value,
    output wire        timer_int_flag
);

    // ---------------- 地址解码 ----------------
    // 只解码【真正实现了的】外设区间, 不再"整页放行".
    // 放行整页会让"往未实现的外设写"变成静默丢弃 —— 那和越界地址被静默
    // 别名进 DRAM[0] 是同一类病. 现在未实现的地址一律走访问异常.
    // 这三个区间与 golden model 注册的外设(Digit/TIMER/MONITOR)一一对应.
    wire sel_monitor = (Bus_addr >= 32'h8000_0000) && (Bus_addr <= 32'h8000_0007);
    wire sel_dig     = (Bus_addr >= 32'hFFFF_F000) && (Bus_addr <= 32'hFFFF_F003);
    wire sel_timer   = (Bus_addr >= 32'hFFFF_F040) && (Bus_addr <= 32'hFFFF_F04F);

    // 只有低 64KB 落 DRAM. 越界地址在这里就被挡住 —— 【绝不截断后照写】.
    // 访问异常本身由 mycpu.v 在 EX 级报(cause 5/7), 判据用的是同一个
    // `ADDR_IN_MAP 宏, 保证两边不会各说各话.
    wire sel_dram = (Bus_addr <= 32'h0000_FFFF);

    assign dram_we        = Bus_wen & sel_dram;
    assign dram_wdata     = Bus_wdata;
    assign dram_word_addr = {2'b00, Bus_addr[15:2]};

    // ---------------- MONITOR ----------------
    // 两个独立寄存器, 与 golden model 的 monitor_value_passed/failed 对齐
    reg [31:0] monitor_passed;
    reg [31:0] monitor_failed;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            monitor_passed <= 32'b0;
            monitor_failed <= 32'b0;
        end else if (Bus_wen && sel_monitor) begin
            if (Bus_addr[2]) monitor_failed <= Bus_wdata;
            else             monitor_passed <= Bus_wdata;
        end
    end
    wire [31:0] monitor_rdata = Bus_addr[2] ? monitor_failed : monitor_passed;

    // ---------------- DIG (数码管) ----------------
    reg [31:0] dig_reg;
    always @(posedge clk or posedge rst) begin
        if (rst) dig_reg <= 32'b0;
        else if (Bus_wen && sel_dig) dig_reg <= Bus_wdata;
    end
    assign seg_value = dig_reg;

    // ---------------- TIMER ----------------
    // 照搬参考实现 cpu/src/timer.v 的寄存器约定:
    //   +0x00 mtime[31:0]     只读
    //   +0x04 mtime[63:32]    只读
    //   +0x08 mtimecmp[31:0]  读写
    //   +0x0C mtimecmp[63:32] 读写
    reg [63:0] mtime;
    reg [63:0] mtimecmp;

    always @(posedge clk or posedge rst) begin
        if (rst) mtime <= 64'b0;
        else     mtime <= mtime + 1'b1;      // 自由计数, 每拍 +1
    end

    always @(posedge clk or posedge rst) begin
        if (rst) mtimecmp <= 64'b0;
        else if (Bus_wen && sel_timer) begin
            case (Bus_addr[3:2])
                2'b10:   mtimecmp[31:0]  <= Bus_wdata;
                2'b11:   mtimecmp[63:32] <= Bus_wdata;
                default: ;                    // 00/01 是只读的 mtime
            endcase
        end
    end

    reg [31:0] timer_rdata;
    always @(*) begin
        case (Bus_addr[3:2])
            2'b00:   timer_rdata = mtime[31:0];
            2'b01:   timer_rdata = mtime[63:32];
            2'b10:   timer_rdata = mtimecmp[31:0];
            default: timer_rdata = mtimecmp[63:32];
        endcase
    end

    assign timer_int_flag = (mtime >= mtimecmp);

    // ---------------- 读选择 ----------------
    // one-hot 或, 任何情况都有确定值(未实现的外设页地址读回 0,
    // 而不是把 DRAM 的 X 灌进 regfile)
    assign Bus_rdata = {32{sel_monitor}} & monitor_rdata
                     | {32{sel_dig}}     & dig_reg
                     | {32{sel_timer}}   & timer_rdata
                     | {32{sel_dram}}    & dram_rdata;

endmodule
