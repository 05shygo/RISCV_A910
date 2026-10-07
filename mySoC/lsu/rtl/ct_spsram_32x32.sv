//==========================================================
// ct_spsram_32x32 —— C910 单口同步 SRAM 行为模型（32 字 x 32 位）
//==========================================================
// 端口语义照 C910 `gen_rtl/*/rtl/ct_spsram_*.v`：
//   CEN   片选，**低有效**
//   GWEN  全局写使能，**低有效**（CEN=0 且 GWEN=1 ⇒ 读）
//   WEN   逐位写掩码，**低有效**（WEN[i]=0 ⇒ 只写第 i 位）
//   Q     读数据，**寄存输出** —— CEN=0 且 GWEN=1 的那拍地址，下一拍出现在 Q
// 写的那拍不更新 Q；Q 在 CEN=1 时保持（见下方"与 C910 原始模型的差异"）。
//
// 【为什么有这个文件】
// C910 开源交付里没有这 12 种几何（它由内存编译器生成，交付的是结构化展开到
// 厂商原语 fpga_ram 的 ct_f_spsram_*，而 fpga_ram 本仓库没有）。
// RV32lsu 的 dcache 阵列全靠按名例化这些宏，缺一个整条 LSU 都 elaborate 不过。
//
// 【与 C910 原始模型的差异】（照抄仓库既有先例 mySoC/ifu_rv32i/rtl/rv32_ifu_spram.v）
//   C910 的 ct_f_spsram_* 会把地址寄存住，并且**每拍都更新 Q**（CEN=1 时用锁存的
//   地址重读）；本模型只在 CEN=0 且 GWEN=1 时才更新 Q，其余拍 Q 保持。
//   两者在"真读的那拍"逐位一致——LSU 也只在真正发起访问时才消费 Q，
//   差别只出现在未选中的拍上，且这样能避免无谓的 X 传播。
//   若将来 dcache 出现疑似读到陈旧数据的现象，这是第一个要看的地方。
//
// 用途：仿真/RTL 验证。不描述真实 SRAM 的时序库特性。
// 本文件由脚本按几何批量生成，几何与 C910 同名宏一一对应。
// 用在：ct_lsu_dcache_data_array (1KB)
//==========================================================

module ct_spsram_32x32 (
  input  wire [4:0]  A,
  input  wire            CEN,
  input  wire            GWEN,
  input  wire            CLK,
  input  wire [31:0]  D,
  input  wire [31:0]  WEN,
  output wire [31:0]  Q
);

  parameter ADDR_WIDTH = 32;
  parameter DATA_WIDTH = 32;

  reg [DATA_WIDTH-1:0] mem_q [0:(1<<ADDR_WIDTH)-1];
  reg [DATA_WIDTH-1:0] q_q;
  integer i;

  always @(posedge CLK) begin
    if (!CEN) begin
      if (!GWEN) begin
        for (i = 0; i < DATA_WIDTH; i = i + 1) begin
          if (!WEN[i]) begin
            mem_q[A][i] <= D[i];
          end
        end
      end else begin
        q_q <= mem_q[A];
      end
    end
  end

  assign Q = q_q;

endmodule
