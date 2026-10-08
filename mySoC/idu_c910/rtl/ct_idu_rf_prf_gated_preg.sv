module ct_idu_rf_prf_gated_preg (
  input  logic         forever_cpuclk,
  input  logic [31:0]  iu_idu_ex2_pipe0_wb_preg_data,
  input  logic [31:0]  iu_idu_ex2_pipe1_wb_preg_data,
  input  logic [31:0]  lsu_idu_wb_pipe3_wb_preg_data,
  // 2026-10-08 新增: **第 4 个写口 —— RTU 在退休拍写 CSR 指令的 rd 结果**。
  // 为什么必须加口: CSR 的 rd 值(旧值)要到**退休**那拍才算得出来(见 RTU §6.3 ⑩),
  // 而交付的 PRF 只有 3 个写口、全被 IU/LSU 的写回占着 ⇒ 没有空位。
  // 见 doc/DELIVERY_FIXES_2026-10-08.md 与接口表 RTU↔IDU 的 A1/A5 说明。
  input  logic [31:0]  rtu_csr_rd_wdata,
  input  logic [3:0]   x_wb_vld,          // 位宽 3 → 4
  output logic [31:0]  x_reg_dout
);

  //==========================================================
  //                     Write Port
  //==========================================================
  logic        write_en;
  logic [31:0] write_data;

  assign write_en = |x_wb_vld;

  // ⚠️ 四个写口**互斥**（一个 preg 在任一拍只可能有一个写者：改名保证）。
  //    所以 `unique case` 在这里是安全的断言 —— 真出现两位同置会报 violation。
  always_comb begin
    unique case (x_wb_vld)
      4'b0001 : write_data = iu_idu_ex2_pipe0_wb_preg_data;
      4'b0010 : write_data = iu_idu_ex2_pipe1_wb_preg_data;
      4'b0100 : write_data = lsu_idu_wb_pipe3_wb_preg_data;
      4'b1000 : write_data = rtu_csr_rd_wdata;
      default: write_data = 'x;
    endcase
  end

  //==========================================================
  //                     Preg Register
  //==========================================================
  logic [31:0] reg_dout;

  always_ff @(posedge forever_cpuclk) begin
    if (write_en) begin
      reg_dout <= write_data;
    end
  end

  assign x_reg_dout = reg_dout;

// &ModuleEnd; @91
endmodule