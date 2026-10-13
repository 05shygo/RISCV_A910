//==========================================================
// ct_spsram_32x44 —— C910 单口同步 SRAM 行为模型（32 字 x 44 位）
//==========================================================
// 端口语义照 C910 `gen_rtl/*/rtl/ct_spsram_*.v`：
//   CEN   片选，**低有效**
//   GWEN  全局写使能，**低有效**（CEN=0 且 GWEN=0 ⇒ 写；GWEN=1 ⇒ 读）
//   WEN   逐位写掩码，**低有效**（WEN[i]=0 ⇒ 只写第 i 位）
//   Q     读数据，**寄存输出**，每拍更新：Q(k+1) = mem[A(k)]
//
// ---------------------------------------------------------------------------
// 【2026-10-13 重写为 ifu 口径】照 `mySoC/ifu2/rtl/rv32ifu2_spram.v` 的
// "裸 reg 阵列 + 无条件同步读"写法。两处改动：
//
// 1) **深度参数填错了 —— 这是真 bug, 不是风格问题。**
//      原: `parameter ADDR_WIDTH = 32;`   ← 填的是**字数**(32), 不是 log2(字数)
//          阵列     mem_q [0:(1<<ADDR_WIDTH)-1]  → [0:2^32-1]; 而 A 只有 5 位,
//                                                实际只用到 0..31
//          清零循环 for (i=0; i < (1 << ADDR_WIDTH); i=i+1) mem_q[i] = '0;
//      而 32 位算术里 **`1<<32 == 0`** ⇒ 循环条件 `i < 0` 立刻为假
//      ⇒ **清零一次都没跑** ⇒ `mem_q` 全是 X ⇒ tag 读回 X ⇒ `dcache_hit` = X
//      ⇒ `ld_da_rb_create_vld` = X ⇒ 总线读请求永远发不出去 ⇒ **dcache 读出来全是 X**。
//      (16 字那档 `1<<16`=65536 碰巧还能跑, 所以旧注释里"LSU 自带 TB 卡住根因
//       就是这里"只在 DCACHE_1KB 档成立; 2KB / 4KB 档一直是 X。)
//      ⇒ 现在 `ADDR_WIDTH = 5`（= log2 深度）。**几何仍是 32 字 × 44 位, 没变。**
//
// 2) 读改成**每拍无条件** `q_q <= mem_q[A]`。原来是"只在 !CEN&&GWEN 那拍才更新,
//    其余拍 Q 保持" —— 而 Q 是寄存器, "保持"会把 X 一直往下传。无条件读之后
//    Q 每拍都有确定来源（mem_q 已被上面那个清零循环初始化, 不再是 X）。
//
// 写保持 C910 的 read-first、**不加写穿透**（dcache 现在依赖这个语义, 别加旁路）。
//
// 【为什么有这个文件】
// C910 开源交付里没有这些几何（它由内存编译器生成，交付的是结构化展开到
// 厂商原语 fpga_ram 的 ct_f_spsram_*，而 fpga_ram 本仓库没有）。
// RV32lsu 的 dcache 阵列全靠按名例化这些宏，缺一个整条 LSU 都 elaborate 不过。
//
// 用途：仿真/RTL 验证。不描述真实 SRAM 的时序库特性。
// 用在：ct_lsu_dcache_tag_array (2KB)
//==========================================================

module ct_spsram_32x44 (
  input  wire [4:0]  A,
  input  wire            CEN,
  input  wire            GWEN,
  input  wire            CLK,
  input  wire [43:0]  D,
  input  wire [43:0]  WEN,
  output wire [43:0]  Q
);

  // ⚠️ ADDR_WIDTH 是**深度的 log2**（32 字 ⇒ 5），不是字数。
  parameter ADDR_WIDTH = 5;
  parameter DATA_WIDTH = 44;

  reg [DATA_WIDTH-1:0] mem_q [0:(1<<ADDR_WIDTH)-1];
  reg [DATA_WIDTH-1:0] q_q;
  integer i;

  // 仿真用的确定性初值：清成全 0 = "所有行都无效", 与真机复位后的期望状态一致。
  // 真 SRAM 上电内容随机, 真机靠软件/硬件把 tag 的 valid 位清掉。
  initial begin : SIM_INIT
    for (i = 0; i < (1 << ADDR_WIDTH); i = i + 1) mem_q[i] = '0;
  end

  always @(posedge CLK) begin
    // 无条件同步读（ifu 口径）: Q 恒 = 上一拍的 mem[A], 不再"不选中就保持"。
    q_q <= mem_q[A];

    // 写: 片选 + 全局写使能 + 逐位掩码。read-first —— 同址同拍读拿到旧值。
    if (!CEN && !GWEN) begin
      for (i = 0; i < DATA_WIDTH; i = i + 1) begin
        if (!WEN[i]) begin
          mem_q[A][i] <= D[i];
        end
      end
    end
  end

  assign Q = q_q;

endmodule
