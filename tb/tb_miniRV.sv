module tb_miniRV;
  logic clk = 0;
  logic rst = 1;

  always #5 clk = ~clk; // 100MHz

  initial begin
    #100 rst = 0;
  end

  // DUT
  miniRV_SoC dut (
    .fpga_rst(rst),
    .fpga_clk(clk),
    .debug_wb_have_inst(),
    .debug_wb_pc(),
    .debug_wb_ena(),
    .debug_wb_reg(),
    .debug_wb_value()
  );

`ifdef FSDB
  initial begin
    $fsdbDumpfile("waveform/waves.fsdb");
    $fsdbDumpvars(0, tb_miniRV);
  end
`endif

  initial begin
    // stop after some time if no finish triggered
    #1000000 $finish;
  end
endmodule

