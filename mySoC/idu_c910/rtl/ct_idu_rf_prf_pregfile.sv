module ct_idu_rf_prf_pregfile (
  //==========================================================
  // 全局信号
  //==========================================================
  input  logic         forever_cpuclk,

  //==========================================================
  // 来自 DP 的源寄存器索引（第一个模块的 output）
  //==========================================================
  input  logic [5:0]   dp_prf_rf_pipe0_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe0_src1_preg,
  input  logic [5:0]   dp_prf_rf_pipe1_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe1_src1_preg,
  input  logic [5:0]   dp_prf_rf_pipe2_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe2_src1_preg,
  input  logic [5:0]   dp_prf_rf_pipe3_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe4_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe5_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe6_src0_preg,
  input  logic [5:0]   dp_prf_rf_pipe6_src1_preg,

  //==========================================================
  // 写端口（来自 IU/LSU，位宽适配 32bit 寄存器）
  //==========================================================
  input  logic [31:0]  iu_idu_ex2_pipe0_wb_preg_data,
  input  logic [63:0]  iu_idu_ex2_pipe0_wb_preg_expand,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld,
  input  logic [31:0]  iu_idu_ex2_pipe1_wb_preg_data,
  input  logic [63:0]  iu_idu_ex2_pipe1_wb_preg_expand,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld,
  input  logic [31:0]  lsu_idu_wb_pipe3_wb_preg_data,
  input  logic [63:0]  lsu_idu_wb_pipe3_wb_preg_expand,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld,

  //==========================================================
  // 输出到 DP 的源数据（第一个模块的 input）
  //==========================================================
  output logic [31:0]  prf_dp_rf_pipe0_src0_data,
  output logic [31:0]  prf_dp_rf_pipe0_src1_data,
  output logic [31:0]  prf_dp_rf_pipe1_src0_data,
  output logic [31:0]  prf_dp_rf_pipe1_src1_data,
  output logic [31:0]  prf_dp_rf_pipe2_src0_data,
  output logic [31:0]  prf_dp_rf_pipe2_src1_data,
  output logic [31:0]  prf_dp_rf_pipe3_src0_data,
  output logic [31:0]  prf_dp_rf_pipe4_src0_data,
  output logic [31:0]  prf_dp_rf_pipe5_src0_data,
  output logic [31:0]  prf_dp_rf_pipe6_src0_data,
  output logic [31:0]  prf_dp_rf_pipe6_src1_data,

  //==========================================================
  // 【2026-10-08 新增】RTU 的访问口 —— 退休级要**按物理号**取数
  //==========================================================
  // 【为什么必须加】(RTU §6.1 的 A1/A5)
  //   * difftest 要比对**提交值** ⇒ 退休拍要按 dst_preg 真读 PRF 三个口;
  //   * CSR 指令要读 rs1 的源操作数 ⇒ 第 4 个读口;
  //   * CSR 的 rd 结果(= CSR 旧值)要到**退休**那拍才算得出 ⇒ 第 4 个写口。
  //   交付的 PRF 是 11 读 3 写、**全被 IDU 内部占满、一个空位都没有**,
  //   所以每个都得新加。这就是计划里 A5 那笔"10 读 4 写"预算的落点。
  //
  // ⚠️ 读口是纯组合的（`preg_reg_dout[addr]` 就是个 64 选 1 mux），
  //    代价在面积/时序上 —— 3 个 32 位 64:1 mux。
  // ⚠️ RTU 侧是 7 位 preg 而这里 64 档是 6 位 ⇒ 由适配层切位后送进来。
  input  logic [5:0]   rtu_preg_raddr0,
  input  logic [5:0]   rtu_preg_raddr1,
  input  logic [5:0]   rtu_preg_raddr2,
  input  logic [5:0]   rtu_csr_src_raddr,
  input  logic         rtu_csr_rd_we,
  input  logic [5:0]   rtu_csr_rd_addr,
  input  logic [31:0]  rtu_csr_rd_wdata,
  output logic [31:0]  rtu_preg_rdata0,
  output logic [31:0]  rtu_preg_rdata1,
  output logic [31:0]  rtu_preg_rdata2,
  output logic [31:0]  rtu_csr_src_rdata
);

//==========================================================
//              Instance GPR Physical Registers
//==========================================================
//----------------------------------------------------------
//                       Preg data / vld 数组
//----------------------------------------------------------
logic [31:0] preg_reg_dout [0:63];
// ⚠️ 2026-10-08: 3 → **4** 位。第 4 位是 RTU 的 CSR rd 写口 ——
//    忘了改这里的话，下面 `assign preg_wb_vld[j] = {csr, pipe3, pipe1, pipe0}`
//    会被**静默截断**成 3 位（丢掉最高位），于是 CSR 的 rd 永远写不进 PRF。
logic [3:0]  preg_wb_vld   [0:63];

//----------------------------------------------------------
//                         Preg 0
//----------------------------------------------------------
// treat preg0 as constant 0
assign preg_reg_dout[0] = 32'b0;

//----------------------------------------------------------
//                       实例化 preg1 ~ preg63
//----------------------------------------------------------
genvar i;
generate
  for (i = 1; i < 64; i = i + 1) begin : gen_preg
    ct_idu_rf_prf_gated_preg u_ct_idu_rf_prf_preg (
      .forever_cpuclk                (forever_cpuclk               ),
      .iu_idu_ex2_pipe0_wb_preg_data (iu_idu_ex2_pipe0_wb_preg_data),
      .iu_idu_ex2_pipe1_wb_preg_data (iu_idu_ex2_pipe1_wb_preg_data),
      .lsu_idu_wb_pipe3_wb_preg_data (lsu_idu_wb_pipe3_wb_preg_data),
      .rtu_csr_rd_wdata              (rtu_csr_rd_wdata             ), // 2026-10-08 第 4 写口
      .x_reg_dout                    (preg_reg_dout[i]             ),
      .x_wb_vld                      (preg_wb_vld[i]               )  // [3:0]
    );
  end
endgenerate

//==========================================================
//                       Write Port 
//==========================================================
// 3 write ports（+ 2026-10-08 的第 4 个: RTU 的 CSR rd）
logic [63:0] pipe0_wb_vld;
logic [63:0] pipe1_wb_vld;
logic [63:0] pipe3_wb_vld;
logic [63:0] csr_rd_wb_vld;   // 2026-10-08 新增

assign pipe0_wb_vld = {64{iu_idu_ex2_pipe0_wb_preg_vld}}
                      & iu_idu_ex2_pipe0_wb_preg_expand;
assign pipe1_wb_vld = {64{iu_idu_ex2_pipe1_wb_preg_vld}}
                      & iu_idu_ex2_pipe1_wb_preg_expand;
assign pipe3_wb_vld = {64{lsu_idu_wb_pipe3_wb_preg_vld}}
                      & lsu_idu_wb_pipe3_wb_preg_expand;

// 第 4 写口: RTU 在**退休拍**写 CSR 指令的 rd。地址是 6 位二进制 ⇒ 就地展成独热。
// （不用 ct_idu_expand_64 是因为那是个模块、这里只要一行移位。）
assign csr_rd_wb_vld = {64{rtu_csr_rd_we}} & (64'd1 << rtu_csr_rd_addr);

// preg0 恒为常量 0，不写入
assign preg_wb_vld[0] = 4'b0000;

genvar j;
generate
  for (j = 1; j < 64; j = j + 1) begin : gen_wb_vld
    assign preg_wb_vld[j] = {csr_rd_wb_vld[j], pipe3_wb_vld[j],
                             pipe1_wb_vld[j], pipe0_wb_vld[j]};
  end
endgenerate

//==========================================================
//                       Read Port 
//==========================================================
// 说明：
//   - 物理寄存器共有 64 个（preg0 ~ preg63），索引 [5:0]
//   - preg_reg_dout[0] 恒为 32'b0（preg0 作为常量 0）
//   - 数据位宽统一为 32bit
//   - 用数组索引替代 case，等价于 64 选 1 mux
//   - 仅保留 DP 实际用到的端口：pipe0/1/2/6 双 src，pipe3/4/5 单 src
//==========================================================

//----------------------------------------------------------
//                 Read Port 1: pipe0 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe0_src0_data = preg_reg_dout[dp_prf_rf_pipe0_src0_preg];

//----------------------------------------------------------
//                 Read Port 2: pipe0 src1
//----------------------------------------------------------
assign prf_dp_rf_pipe0_src1_data = preg_reg_dout[dp_prf_rf_pipe0_src1_preg];

//----------------------------------------------------------
//                 Read Port 3: pipe1 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe1_src0_data = preg_reg_dout[dp_prf_rf_pipe1_src0_preg];

//----------------------------------------------------------
//                 Read Port 4: pipe1 src1
//----------------------------------------------------------
assign prf_dp_rf_pipe1_src1_data = preg_reg_dout[dp_prf_rf_pipe1_src1_preg];

//----------------------------------------------------------
//                 Read Port 5: pipe2 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe2_src0_data = preg_reg_dout[dp_prf_rf_pipe2_src0_preg];

//----------------------------------------------------------
//                 Read Port 6: pipe2 src1
//----------------------------------------------------------
assign prf_dp_rf_pipe2_src1_data = preg_reg_dout[dp_prf_rf_pipe2_src1_preg];

//----------------------------------------------------------
//                 Read Port 7: pipe3 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe3_src0_data = preg_reg_dout[dp_prf_rf_pipe3_src0_preg];

//----------------------------------------------------------
//                 Read Port 8: pipe4 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe4_src0_data = preg_reg_dout[dp_prf_rf_pipe4_src0_preg];

//----------------------------------------------------------
//                 Read Port 9: pipe5 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe5_src0_data = preg_reg_dout[dp_prf_rf_pipe5_src0_preg];

//----------------------------------------------------------
//                 Read Port 10: pipe6 src0
//----------------------------------------------------------
assign prf_dp_rf_pipe6_src0_data = preg_reg_dout[dp_prf_rf_pipe6_src0_preg];

//----------------------------------------------------------
//                 Read Port 11: pipe6 src1
//----------------------------------------------------------
assign prf_dp_rf_pipe6_src1_data = preg_reg_dout[dp_prf_rf_pipe6_src1_preg];

//----------------------------------------------------------
//   Read Port 12~15 (2026-10-08 新增): RTU 的退休读口
//----------------------------------------------------------
// 三个 difftest 口按**退休槽**分（槽 0/1/2 各自的 dst_preg），加一个 CSR 源口。
// 地址由 RTU 给（`rtu_preg_raddr*` / `rtu_csr_src_raddr`），适配层已把 7 位切成 6 位。
// ⚠️ 这三个口是**组合**的：RTU 在退休拍用它取提交值，没有旁路、也没有 ready 位 ——
//    值必须在退休那拍已经写进 PRF 里（完成 → 写回 → 退休，顺序由 RTU 的
//    "只有完成的表项才准退休"保证）。
assign rtu_preg_rdata0    = preg_reg_dout[rtu_preg_raddr0];
assign rtu_preg_rdata1    = preg_reg_dout[rtu_preg_raddr1];
assign rtu_preg_rdata2    = preg_reg_dout[rtu_preg_raddr2];
assign rtu_csr_src_rdata  = preg_reg_dout[rtu_csr_src_raddr];

// &ModuleEnd; @1536
endmodule