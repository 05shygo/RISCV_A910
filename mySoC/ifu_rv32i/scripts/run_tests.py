"""Run self-checking SV tests with Icarus. No automatic tool installation."""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
work=root/'work'
work.mkdir(exist_ok=True)
p=argparse.ArgumentParser()
p.add_argument('--iverilog')
p.add_argument('--vvp')
args=p.parse_args()
iverilog=args.iverilog or shutil.which('iverilog')
if not iverilog:
    hits=list((work/'tools/iverilog').rglob('iverilog.exe'))
    iverilog=str(hits[0]) if hits else None
if not iverilog: raise SystemExit('Icarus required: use --iverilog PATH --vvp PATH')
iverilog=str(Path(iverilog).resolve())
vvp=args.vvp or str(Path(iverilog).with_name('vvp.exe' if iverilog.endswith('.exe') else 'vvp'))
ports=json.loads((root/'doc/ports.json').read_text())
s='`timescale 1ns/1ps\nmodule tb_bp;\n'
s+='\n'.join(f'{"reg" if d=="input" else "wire"} {w} {n};' for n,(d,w) in ports.items())
s+='\nrv32_ifu_bp_top dut(\n'+',\n'.join(f'.{n}({n})' for n in ports)+'\n);\n'
s+='task defaults; begin\n'
s+='\n'.join(f'{n}=0;' for n,(d,w) in ports.items() if d=='input' and n not in ['forever_cpuclk','cpurst_b'])
s+='\ncp0_ifu_bht_en=1; cp0_ifu_ras_en=1; cp0_ifu_ind_btb_en=1;\n'
s+='cp0_ifu_btb_en=1; cp0_ifu_l0btb_en=1; cp0_yy_clk_en=1; cp0_yy_priv_mode=3;\nend endtask\n'
s+='`include "tb_bp_body.svh"\nendmodule\n'
(work/'tb_bp.sv').write_text(s)
results=[]
subprocess.run([sys.executable,str(root/'scripts/build_bht_reference_test.py')],check=True)
for name,source in [('tb_bp',work/'tb_bp.sv'),('tb_decode',root/'tb/tb_decode.sv'),
                    ('tb_bht_reference',work/'tb_bht_reference.sv')]:
    binary=work/(name+'.vvp')
    compile_cmd=[iverilog,'-g2012','-Wall','-s',name,'-I',str(root/'tb'),'-f','rtl/files.f','-o',str(binary),str(source)]
    if name=='tb_bht_reference': compile_cmd.append(str(work/'ref_ct_ifu_bht.v'))
    c=subprocess.run(compile_cmd,cwd=root,text=True,capture_output=True,timeout=60)
    (work/(name+'_compile.log')).write_text(c.stdout+c.stderr)
    if c.returncode: raise SystemExit(c.stdout+c.stderr)
    r=subprocess.run([vvp,str(binary)],cwd=root,text=True,capture_output=True,timeout=90)
    (work/(name+'.log')).write_text(r.stdout+r.stderr)
    print(r.stdout+r.stderr,end='')
    if r.returncode or 'PASS' not in r.stdout: raise SystemExit(f'{name} failed ({r.returncode})')
    results.append({'test':name,'passed':True,'output':r.stdout.strip()})
(work/'test_result.json').write_text(json.dumps(results,indent=2))
