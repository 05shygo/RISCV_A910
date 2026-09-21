integer n;
integer w;
integer bank_mask;
integer mode;
integer seed=32'h31415926;
reg [31:0] r;
integer coverage [0:7];

initial forever_cpuclk=0;
always #5 forever_cpuclk=~forever_cpuclk;
initial begin #3000000; $fatal(1,"ICache IF timeout"); end

task tick;
  begin
    #1; compare;
    @(posedge forever_cpuclk); #1; compare;
    @(negedge forever_cpuclk); #1; compare;
  end
endtask

task owners_off;
  begin
    ifctrl_icache_if_tag_req=0; ifctrl_icache_if_reset_req=0;
    ifctrl_icache_if_inv_on=0;
    ifctrl_icache_if_read_req_data0=0; ifctrl_icache_if_read_req_data1=0;
    ifctrl_icache_if_read_req_tag=0;
    l1_refill_icache_if_wr=0; ipb_icache_if_req=0;
    pcgen_icache_if_chgflw=0; pcgen_icache_if_seq_data_req=0;
    pcgen_icache_if_seq_tag_req=0;
    pcgen_icache_if_chgflw_bank0=0; pcgen_icache_if_chgflw_bank1=0;
    pcgen_icache_if_chgflw_bank2=0; pcgen_icache_if_chgflw_bank3=0;
  end
endtask

initial begin
  defaults; cpurst_b=0;
  for(n=0;n<8;n=n+1) coverage[n]=0;
  tick; cpurst_b=1;
  // Identical deterministic initialization of every block in BOTH ways.
  for(n=0;n<2048;n=n+1) begin
    ifctrl_icache_if_index=n*16;
    ifctrl_icache_if_reset_req=1; ifctrl_icache_if_tag_req=1;
    ifctrl_icache_if_inv_on=1; ifctrl_icache_if_tag_wen=0;
    tick;
  end
  owners_off;
  // Exercise all ownership patterns without a clocked write. Multi-owner
  // combinations are outside the caller contract but retain default=zero.
  ifctrl_icache_if_index=32'h1110; l1_refill_icache_if_index=32'h2220;
  ipb_icache_if_index=32'h3330; ifctrl_icache_if_read_req_index=32'h4440;
  for(n=0;n<16;n=n+1) begin
    ifctrl_icache_if_tag_req=n[3]; l1_refill_icache_if_wr=n[2];
    ipb_icache_if_req=n[1]; ifctrl_icache_if_read_req_tag=n[0];
    #1; compare;
  end
  owners_off;
  @(negedge forever_cpuclk); #1;
  // Independently exercise bank-select and Way prediction bits and gate hints.
  for(w=0;w<4;w=w+1) begin
    for(bank_mask=0;bank_mask<16;bank_mask=bank_mask+1) begin
      pcgen_icache_if_way_pred=w[1:0];
      pcgen_icache_if_chgflw=1;
      pcgen_icache_if_chgflw_bank0=bank_mask[0];
      pcgen_icache_if_chgflw_bank1=bank_mask[1];
      pcgen_icache_if_chgflw_bank2=bank_mask[2];
      pcgen_icache_if_chgflw_bank3=bank_mask[3];
      pcgen_icache_if_index=bank_mask*16;
      tick;
    end
  end
  owners_off;
  // Binary control inputs; memory outputs, including unknown retained data,
  // are compared with four-state case inequality at each sampling point.
  for(n=0;n<6000;n=n+1) begin
    owners_off;
    r=$random(seed);
    mode=n%8;
    coverage[mode]=coverage[mode]+1;
    cp0_ifu_icache_en=r[0]; cp0_ifu_icg_en=r[1]; cp0_yy_clk_en=r[2];
    pad_yy_icg_scan_en=r[3]; hpcp_ifu_cnt_en=r[4];
    ifu_hpcp_icache_miss_pre=r[5];
    pcgen_icache_if_way_pred=r[7:6];
    pcgen_icache_if_chgflw_short=r[8]; pcgen_icache_if_seq_data_req_short=r[9];
    pcgen_icache_if_gateclk_en=r[10]; ipb_icache_if_req_for_gateclk=r[11];
    ifctrl_icache_if_index={17'b0,r[14:4],4'b0};
    ifctrl_icache_if_read_req_index={17'b0,r[15:5],4'b0};
    ipb_icache_if_index={17'b0,r[16:6],4'b0};
    pcgen_icache_if_index={17'b0,r[17:7],4'b0};
    l1_refill_icache_if_index={17'b0,r[18:8],4'b0};
    l1_refill_icache_if_fifo=r[19]; l1_refill_icache_if_first=r[20];
    l1_refill_icache_if_last=r[21]; l1_refill_icache_if_install=r[22];
    l1_refill_icache_if_ptag=r[31:15];
    l1_refill_icache_if_inst_data={$random(seed),$random(seed),$random(seed),$random(seed)};
    l1_refill_icache_if_pre_code=$random(seed);
    ifctrl_icache_if_tag_wen=r[25:23]; ifctrl_icache_if_inv_fifo=r[26];
    case(mode)
      0: begin
        ifctrl_icache_if_tag_req=1; ifctrl_icache_if_inv_on=r[27];
        ifctrl_icache_if_reset_req=r[28];
      end
      1: l1_refill_icache_if_wr=1;
      2: ipb_icache_if_req=1;
      3: ifctrl_icache_if_read_req_data0=1;
      4: ifctrl_icache_if_read_req_data1=1;
      5: ifctrl_icache_if_read_req_tag=1;
      6: begin
        pcgen_icache_if_chgflw=r[27];
        pcgen_icache_if_chgflw_bank0=r[28]; pcgen_icache_if_chgflw_bank1=r[29];
        pcgen_icache_if_chgflw_bank2=r[30]; pcgen_icache_if_chgflw_bank3=r[31];
        pcgen_icache_if_seq_data_req=r[26]; pcgen_icache_if_seq_tag_req=r[25];
      end
      default: begin end // idle must retain array outputs and clear event pulses
    endcase
    if(n%997==0) begin
      #1; cpurst_b=0; #1; compare;
      tick; cpurst_b=1;
    end
    tick;
  end
  // Read every row/Way after random writes, so dormant mismatches cannot hide
  // simply because a later random read did not revisit a modified location.
  defaults;
  for(n=0;n<2048;n=n+1) begin
    owners_off;
    ifctrl_icache_if_read_req_index=n*16;
    ifctrl_icache_if_read_req_data0=1;
    ifctrl_icache_if_read_req_data1=1;
    tick;
    ifctrl_icache_if_read_req_data0=0;
    ifctrl_icache_if_read_req_data1=0;
    ifctrl_icache_if_read_req_tag=1;
    tick;
  end
  for(n=0;n<8;n=n+1) begin
    if(coverage[n]!=750) $fatal(1,"owner-mode coverage incomplete");
  end
  $display("PASS ICache IF generate: %0d four-state comparisons; 6000 random cycles; 16 owner masks; 64 bank/Way combinations; full final SRAM readback",comparisons);
  $finish;
end
