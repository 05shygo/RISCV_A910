`timescale 1ns/1ps
module tb_icache_precode;
  reg [127:0] data;
  wire [31:0] precode;
  reg [31:0] pa;
  wire [4:0] default_attr;
  wire [4:0] overlap_attr;
  integer count = 0;
  rv32_ifu_icache_precode dut (.data(data), .precode(precode));
  rv32_ifu_region u_default (.pa(pa), .attr(default_attr));
  rv32_ifu_region #(
    .REGION_COUNT(2), .REGION_BASE({32'h40,32'h0}),
    .REGION_LIMIT({33'hc0,33'h80}), .REGION_ATTR({5'b10001,5'b11101})
  ) u_overlap (.pa(pa), .attr(overlap_attr));

  task decode(input [31:0] inst, input [7:0] expected);
    begin
      data = {4{inst}};
      #1;
      if (precode !== {4{expected}}) begin
        $fatal(1,"precode inst=%h expected=%h actual=%h",inst,expected,precode);
      end
      count = count + 1;
    end
  endtask

  initial begin
    decode(32'h00000013,8'h00); // ADDI
    decode(32'h00000063,8'h01); // BEQ
    decode(32'h00001063,8'h01); // BNE
    decode(32'h00004063,8'h01); // BLT
    decode(32'h00005063,8'h01); // BGE
    decode(32'h00006063,8'h01); // BLTU
    decode(32'h00007063,8'h01); // BGEU
    decode(32'h00002063,8'h00); // reserved branch
    decode(32'h00003063,8'h00);
    decode(32'h0000006f,8'h02); // JAL x0
    decode(32'h000000ef,8'h0a); // JAL x1
    decode(32'h000002ef,8'h0a); // JAL x5
    decode(32'h00008067,8'h14); // JALR x0,x1: pop
    decode(32'h00028067,8'h14); // JALR x0,x5: pop
    decode(32'h000080e7,8'h0c); // JALR x1,x1: push only
    decode(32'h000082e7,8'h1c); // JALR x5,x1: pop+push
    decode(32'h00010067,8'h04); // JALR x0,x2: no RAS hint
    decode(32'h00001067,8'h00); // invalid JALR funct3
    decode(32'h0000000f,8'h20); // FENCE
    decode(32'h0000100f,8'h00); // FENCE.I is not RV32I FENCE
    decode(32'h00000003,8'h40); // LB
    decode(32'h00001003,8'h40); // LH
    decode(32'h00002003,8'h40); // LW
    decode(32'h00004003,8'h40); // LBU
    decode(32'h00005003,8'h40); // LHU
    decode(32'h00003003,8'h00); // LD excluded
    decode(32'h00006003,8'h00); // LWU excluded
    decode(32'h00000023,8'h80); // SB
    decode(32'h00001023,8'h80); // SH
    decode(32'h00002023,8'h80); // SW
    decode(32'h00003023,8'h00); // SD excluded
    decode(32'h00000001,8'h00); // C encoding excluded
    decode(32'h00000007,8'h00); // FP/vector load excluded
    pa=32'h0; #1;
    if (default_attr!==0 || overlap_attr!==5'b11101) $fatal(1,"default deny/first region");
    pa=32'h40; #1;
    if (default_attr!==0 || overlap_attr!==0) $fatal(1,"overlap must reject");
    pa=32'h80; #1;
    if (overlap_attr!==5'b10001) $fatal(1,"exclusive region end");
    pa=32'hc0; #1;
    if (overlap_attr!==0) $fatal(1,"unmapped must reject");
    $display("PASS ICache precode: %0d encodings x 4 lanes; default/overlap/boundary region checks",count);
    $finish;
  end
endmodule
