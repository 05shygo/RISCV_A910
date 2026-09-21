// Real array integration: word0 is data[31:0], physical bank3.
integer checks = 0;
integer way;
integer slot;
integer word_index;
reg [127:0] row_a [0:1];
reg [127:0] row_b [0:1];
reg [127:0] expected_data;

task tick;
  begin
    #2; forever_cpuclk=1; #2; forever_cpuclk=0; #2;
  end
endtask

task check_data;
  input integer which_way;
  input [127:0] expected_value;
  reg [127:0] actual;
  begin
    actual = which_way ? icache_if_ifdp_inst_data1 : icache_if_ifdp_inst_data0;
    checks=checks+1;
    if (actual !== expected_value)
      $fatal(1,"array way=%0d slot=%0d got=%h expected=%h",which_way,slot,actual,expected_value);
  end
endtask

task read_baseline;
  begin
    iu_ifu_chgflw_vld=1; iu_ifu_chgflw_pc=32'h1000;
    tick;
    iu_ifu_chgflw_vld=0;
    check_data(0,row_a[0]); check_data(1,row_a[1]);
  end
endtask

initial begin
  defaults;
  forever_cpuclk=0; cpurst_b=1;
  #1; cpurst_b=0; tick; cpurst_b=1;
  cp0_yy_clk_en=1; cp0_ifu_icache_en=1; cp0_ifu_iwpe=1;
  ifctrl_pcgen_stall=1; ifctrl_pcgen_stall_short=1;
  row_a[0]=128'ha0000003_a0000002_a0000001_a0000000;
  row_a[1]=128'ha1110003_a1110002_a1110001_a1110000;
  row_b[0]=128'hb0000003_b0000002_b0000001_b0000000;
  row_b[1]=128'hb1110003_b1110002_b1110001_b1110000;
  for(way=0;way<2;way=way+1) begin
    l1_refill_icache_if_fifo=way;
    l1_refill_icache_if_wr=1;
    l1_refill_icache_if_index=32'h1000;
    l1_refill_icache_if_inst_data=row_a[way];
    l1_refill_icache_if_pre_code=32'h12345678;
    tick;
    l1_refill_icache_if_index=32'h1010;
    l1_refill_icache_if_inst_data=row_b[way];
    l1_refill_icache_if_pre_code=32'h87654321;
    tick;
  end
  l1_refill_icache_if_wr=0;
  for(way=0;way<2;way=way+1) begin
    for(slot=0;slot<4;slot=slot+1) begin
      read_baseline;
      ipctrl_pcgen_chgflw_pcload=1;
      ipctrl_pcgen_chgflw_pc=32'h1010+4*slot;
      ipctrl_pcgen_taken_pc=ipctrl_pcgen_chgflw_pc;
      ipctrl_pcgen_branch_taken=1;
      ipctrl_pcgen_chgflw_way_pred=1<<way;
      tick;
      expected_data=row_a[way];
      for(word_index=slot;word_index<4;word_index=word_index+1)
        expected_data[word_index*32+:32]=row_b[way][word_index*32+:32];
      check_data(way,expected_data);
      check_data(1-way,row_a[1-way]);
      checks=checks+1;
      if ((way ? icache_if_ifdp_precode1 : icache_if_ifdp_precode0) !== 32'h87654321)
        $fatal(1,"selected Way precode did not follow target");
      ipctrl_pcgen_chgflw_pcload=0; ipctrl_pcgen_branch_taken=0;
    end
  end
  // Reissue wins both PC and Way; a losing IP branch cannot trim the banks.
  read_baseline;
  ipctrl_pcgen_chgflw_pcload=1; ipctrl_pcgen_chgflw_pc=32'h100c;
  ipctrl_pcgen_taken_pc=32'h100c; ipctrl_pcgen_branch_taken=1;
  ipctrl_pcgen_chgflw_way_pred=1;
  ipctrl_pcgen_reissue_pcload=1; ipctrl_pcgen_reissue_pc=32'h1010;
  ipctrl_pcgen_reissue_way_pred=3;
  tick;
  check_data(0,row_b[0]); check_data(1,row_b[1]);
  ipctrl_pcgen_reissue_pcload=0;
  ipctrl_pcgen_chgflw_pcload=0; ipctrl_pcgen_branch_taken=0;

  // RTU address arrives on the final path; discard the early SRAM result,
  // then re-read the registered target before accepting data for the target.
  read_baseline;
  rtu_ifu_chgflw_vld=1; rtu_ifu_flush=1; rtu_ifu_chgflw_pc=32'h100c;
  #1;
  checks=checks+1;
  if (!pcgen_ifctrl_reissue || pcgen_icache_if_index !== 32'h1010)
    $fatal(1,"RTU final/fast address separation lost");
  tick;
  checks=checks+1;
  if (pcgen_ifctrl_pc !== 32'h100c) $fatal(1,"RTU target lost under stall");
  check_data(0,row_b[0]); check_data(1,row_b[1]);
  rtu_ifu_chgflw_vld=0; rtu_ifu_flush=0;
  ifctrl_pcgen_reissue_pcload=1; ifctrl_pcgen_way_pred=3;
  tick;
  check_data(0,row_a[0]); check_data(1,row_a[1]);
  checks=checks+1;
  if (pcgen_ifctrl_pc !== 32'h100c) $fatal(1,"IF reissue advanced PC");
  ifctrl_pcgen_reissue_pcload=0;
  $display("PASS PCGEN + ICache array: checks=%0d",checks);
  $finish;
end
