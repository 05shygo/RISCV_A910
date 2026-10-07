module ct_idu_rf_prf_gated_preg (
  input  logic         forever_cpuclk,
  input  logic [31:0]  iu_idu_ex2_pipe0_wb_preg_data,
  input  logic [31:0]  iu_idu_ex2_pipe1_wb_preg_data,
  input  logic [31:0]  lsu_idu_wb_pipe3_wb_preg_data,
  input  logic [2:0]   x_wb_vld,
  output logic [31:0]  x_reg_dout
);

  //==========================================================
  //                     Write Port
  //==========================================================
  logic        write_en;
  logic [31:0] write_data;

  assign write_en = |x_wb_vld;

  always_comb begin
    unique case (x_wb_vld)
      3'b001 : write_data = iu_idu_ex2_pipe0_wb_preg_data;
      3'b010 : write_data = iu_idu_ex2_pipe1_wb_preg_data;
      3'b100 : write_data = lsu_idu_wb_pipe3_wb_preg_data;
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