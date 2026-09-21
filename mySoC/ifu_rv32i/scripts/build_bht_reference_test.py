"""C910 effective algorithm equivalence outside intentionally changed contracts."""
from pathlib import Path
import re
from rtl_style import public_ports

root=Path(__file__).resolve().parents[1]
work=root/'work'
source=(root.parent/'ifu/rtl/ct_ifu_bht.v').read_text()
# Reference logic is otherwise byte-for-byte original, including sensitivity lists.
reference=source.replace('ct_ifu_bht_pre_array','rv32_ifu_bht_pre_array')
reference=reference.replace('ct_ifu_bht_sel_array','rv32_ifu_bht_sel_array')
reference=reference.replace('module ct_ifu_bht(', 'module ref_ct_ifu_bht(')
reference=reference.replace('gated_clk_cell','rv32_ifu_clk_cell')
reference=reference.replace('x_rv32_ifu_bht_pre_array','u_bht_pre_array')
reference=reference.replace('x_rv32_ifu_bht_sel_array','u_bht_sel_array')
(work/'ref_ct_ifu_bht.v').write_text(reference)
ported=(root/'rtl/rv32_ifu_bht.v').read_text()
ports=public_ports(ported)
refports=re.findall(r'^(input|output)\s+(\[[^\]]+\])?\s*(\w+)\s*;',source,re.M)
s='`timescale 1ns/1ps\nmodule tb_bht_reference;\n'
for direction,width,name in ports:
    s+=f'{"reg" if direction=="input" else "wire"} {width} {name};\n'
for direction,width,name in refports:
    if direction=='output': s+=f'wire {width} ref_{name};\n'
s+='rv32_ifu_bht dut(\n'+',\n'.join(f'.{n}({n})' for _,_,n in ports)+'\n);\n'
conn=[]
for d,w,n in refports:
    expr='ref_'+n if d=='output' else n
    if n=='ipdp_bht_h0_con_br': expr="1'b0"
    if d=='input' and w=='[38:0]': expr="{8'b0,"+n+'}'
    conn.append(f'.{n}({expr})')
s+='ref_ct_ifu_bht ref_dut(\n'+',\n'.join(conn)+'\n);\n'
s+='task clear_inputs; begin\n'
s+='\n'.join(n+'=0;' for d,_,n in ports if d=='input' and n not in ['forever_cpuclk','cpurst_b'])
s+='\ncp0_ifu_bht_en=1; cp0_yy_clk_en=1;\nend endtask\n'
s+='''integer i,j,checks=0;
reg [31:0] rng=32'h965317ab;
always #5 forever_cpuclk=~forever_cpuclk;
task tick; begin @(posedge forever_cpuclk); #1; end endtask
task compare; begin
'''
for d,w,n in refports:
    if d=='output':
        s+=f'checks=checks+1; if({n} !== ref_{n}) $fatal(1,"C910 differential: {n} cycle %0d port=%h ref=%h",i,{n},ref_{n});\n'
s+='''end endtask
initial begin
forever_cpuclk=0;cpurst_b=0;clear_inputs();tick();tick();cpurst_b=1;
ifctrl_bht_inv=1;tick();ifctrl_bht_inv=0;repeat(1028)tick();
for(i=0;i<3000;i=i+1)begin
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
  rtu_ifu_retire0_condbr=rng[0]; rtu_ifu_retire1_condbr=rng[1]; rtu_ifu_retire2_condbr=rng[2];
  rtu_ifu_retire0_condbr_taken=rng[3]; rtu_ifu_retire1_condbr_taken=rng[4]; rtu_ifu_retire2_condbr_taken=rng[5];
  lbuf_bht_active_state=rng[6];lbuf_bht_con_br_vld=rng[6]&&rng[7];lbuf_bht_con_br_taken=rng[8];
  ipctrl_bht_con_br_vld=!rng[6]&&rng[9];ipctrl_bht_con_br_taken=rng[10];
  ipctrl_bht_con_br_gateclk_en=ipctrl_bht_con_br_vld;
  iu_ifu_chgflw_vld=(rng[14:11]==0);iu_ifu_bht_check_vld=rng[15];
  iu_ifu_bht_condbr_taken=rng[16];iu_ifu_bht_pred=rng[17];iu_ifu_chk_idx=rng[24:0];
  iu_ifu_cur_pc={rng[31:2],1'b0};ipdp_bht_vpc={rng[31:2],1'b0};
  rtu_ifu_flush=(rng[21:18]==0);
  // The new P15 same-cycle flush+retirement rule is checked in tb_bp, not against
  // the legacy C910 old-RTUGHR behavior.
  if(rtu_ifu_flush)begin rtu_ifu_retire0_condbr=0;rtu_ifu_retire1_condbr=0;rtu_ifu_retire2_condbr=0;end
  ifctrl_bht_pipedown=rng[22];ifctrl_bht_stall=!rng[22];
  ipctrl_bht_more_br=rng[23];ipctrl_bht_vld=rng[24];
  pcgen_bht_chgflw=rng[25];pcgen_bht_chgflw_short=rng[25];pcgen_bht_seq_read=rng[26];
  pcgen_bht_ifpc={rng[7:2],1'b0};pcgen_bht_pcindex=rng[13:4];
  tick();compare();
end
clear_inputs();repeat(12)tick();compare();
for(j=0;j<1024;j=j+1)begin
  checks=checks+1;
  if(dut.u_bht_pre_array.u_ct_spsram_1024x64.mem_q[j] !==
     ref_dut.u_bht_pre_array.u_ct_spsram_1024x64.mem_q[j])
    $fatal(1,"prediction array differs at %0d",j);
end
for(j=0;j<128;j=j+1)begin
  checks=checks+1;
  if(dut.u_bht_sel_array.u_ct_spsram_128x16.mem_q[j] !==
     ref_dut.u_bht_sel_array.u_ct_spsram_128x16.mem_q[j])
    $fatal(1,"selection array differs at %0d",j);
end
$display("PASS original C910 BHT differential: %0d checks / 3000 random cycles and full arrays",checks);
$finish;
end
endmodule
'''
(work/'tb_bht_reference.sv').write_text(s)
