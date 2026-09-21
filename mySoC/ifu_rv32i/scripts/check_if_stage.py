"""IF control/datapath structure, interface, and real SRAM/PCGEN/BTB/BHT tests."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import sys
import openpyxl
from pyslang import ast, syntax, DiagnosticEngine
from rtl_style import public_ports, layout

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT/'work/if_stage'
WORK.mkdir(parents=True, exist_ok=True)
files = (ROOT/'rtl/if_stage_files.f').read_text().splitlines()
assert not any('icache_top' in f or 'icache_biu' in f for f in files)
comp = ast.Compilation()
for f in files:
    comp.addSyntaxTree(syntax.SyntaxTree.fromFile(str(ROOT/f)))
ds = comp.getAllDiagnostics()
report = DiagnosticEngine.reportAll(comp.sourceManager, ds)
(WORK/'lint.log').write_text(report, encoding='utf-8')
assert not ds, report
new_modules = ['rv32_ifu_ifctrl', 'rv32_ifu_ifdp', 'rv32_ifu_if_array']
for mod in new_modules:
    text = (ROOT/'rtl'/f'{mod}.v').read_text()
    assert layout(text) == text, mod
    loops, blocks = [], []
    def inspect(node):
        if type(node).__name__ == 'ForLoopStatementSyntax': loops.append(str(node))
        if type(node).__name__ == 'ProceduralBlockSyntax': blocks.append(str(node))
    syntax.SyntaxTree.fromText(text).root.visit(inspect)
    assert not loops
    assert len(blocks) == {'rv32_ifu_ifctrl':1, 'rv32_ifu_ifdp':2, 'rv32_ifu_if_array':0}[mod]
    for b in blocks:
        assert 'always @(posedge forever_cpuclk or negedge cpurst_b)' in b
        assert len(re.findall(r'\bif\s*\(', b)) == 2
        assert re.search(r'else if\s*\(\w+_en(?:\[\w+\])?\)', b)
        assert len(re.findall('<=',b)) == 2
        assert re.search(r'<=\s*\w+_nxt(?:\[\w+\])?;',b)
    assert not re.search(r'\b(?:mmu|itlb)_\w+|\bh0_\w+', text)

book = openpyxl.load_workbook(ROOT.parent/'ifu/doc/RV32I_C910_IFU_interface_v1.1_noMMU.xlsx',
                             read_only=True, data_only=True)
excel={}
for n,d,_ in book['IFU_Interface'].values:
    m=re.fullmatch(r'(\w+)(\[\d+:\d+\])?',str(n))
    if m and d in ['Input','Output']: excel[m[1]]=(d.lower(),m[2] or '')
checked=[]
for mod in new_modules[:2]:
    for d,w,n in public_ports((ROOT/'rtl'/f'{mod}.v').read_text()):
        if n in excel:
            assert (d,re.sub(r'\s','',w))==excel[n],(mod,n)
            checked.append(mod+'.'+n)
book.close()

# Generate only wiring; expectations and directed/random scenarios are in the
# reviewed testbench body, with an independent instruction/tag memory model.
mods = {}
for mod in ['rv32_ifu_pcgen', *new_modules, 'rv32_ifu_btb', 'rv32_ifu_bht']:
    mods[mod] = public_ports((ROOT/'rtl'/f'{mod}.v').read_text())
btb_map = {'forever_cpuclk':'forever_cpuclk', 'cpurst_b':'cpurst_b',
           'enable':'cp0_ifu_btb_en', 'cancel':'frontend_redirect', 'invalidate':'tb_btb_invalidate',
           'init_done':'tb_btb_init_done', 'lookup_vld':'ifctrl_btb_lookup_vld',
           'lookup_ready':'btb_ifctrl_ready', 'lookup_pc':'ifctrl_btb_lookup_pc',
           'if_vld':'btb_ifdp_vld', 'if_pc':'btb_ifdp_pc', 'if_hit':'btb_ifdp_hit',
           'if_target':'btb_ifdp_target', 'if_way_hint':'btb_ifdp_way'}
bht_map = {n:n for n in ['forever_cpuclk','cpurst_b','cp0_yy_clk_en',
                        'ifctrl_bht_pipedown','ifctrl_bht_stall']}
bht_map.update({'pcgen_bht_seq_read':'ifctrl_bht_read',
                'pcgen_bht_pcindex':'ifctrl_bht_pcindex',
                'pcgen_bht_ifpc':'tb_bht_ifpc'})
signals={}
connections={}
for mod,ports in mods.items():
    con=[]
    for d,w,n in ports:
        mapped=btb_map.get(n,'tb_btb_'+n) if mod=='rv32_ifu_btb' else n
        if mod=='rv32_ifu_bht': mapped=bht_map.get(n,'tb_bht_'+n)
        con.append((n,mapped))
        if mapped not in signals or d=='output': signals[mapped]=(d,w)
    connections[mod]=con
for n in ['frontend_redirect','region_ifctrl_attr','region_ifdp_attr','tb_bht_ifpc']:
    signals[n]=('output',signals[n][1])
s='`timescale 1ns/1ps\nmodule tb_if_stage;\n'
for n,(d,w) in signals.items(): s+=f'{"reg" if d=="input" else "wire"} {w} {n};\n'
for mod,cons in connections.items():
    s+=mod+' u_'+mod.removeprefix('rv32_ifu_')+'(\n'+',\n'.join(f'.{n}({v})' for n,v in cons)+'\n);\n'
s+='''
assign tb_bht_ifpc = ifdp_bht_pc[7:1];
assign frontend_redirect = (debug_pcgen_pcload && rtu_ifu_dbgon) || vector_pcgen_pcload ||
 rtu_ifu_chgflw_vld || iu_ifu_chgflw_vld || addrgen_pcgen_pcload || ibctrl_pcgen_pcload ||
 ipctrl_pcgen_reissue_pcload || ipctrl_pcgen_chgflw_pcload;
'''
for inst,pc,attr in [('fast','pcgen_icache_if_index','region_ifctrl_attr'),
                     ('issue','ifctrl_ifdp_issue_pc','region_ifdp_attr')]:
    s+=f'''rv32_ifu_region #(.REGION_COUNT(2),
 .REGION_BASE({{32'h10000000,32'h00000000}}),
 .REGION_LIMIT({{33'h010010000,33'h000100000}}),
 .REGION_ATTR({{5'b10101,5'b11101}})) u_region_{inst}(.pa({pc}),.attr({attr}));\n'''
s+='task defaults; begin\n'
s+='\n'.join(n+'=0;' for n,(d,_) in signals.items() if d=='input')
s+='''
cp0_yy_clk_en=1; cp0_ifu_icache_en=1; cp0_ifu_iwpe=1; cp0_ifu_btb_en=1;
cp0_yy_priv_mode=3; hpcp_ifu_cnt_en=1;
tb_bht_cp0_ifu_bht_en=1; tb_bht_cp0_ifu_icg_en=1;
end endtask
'''
ip_fields=[n for _,_,n in mods['rv32_ifu_ifdp'] if n.startswith('ifdp_ipdp_')]
def bits(w):
    return int(re.search(r'\d+',w)[0])+1 if w else 1
pw=sum(bits(signals[n][1]) for n in ip_fields)
s+=f'wire [{pw-1}:0] ip_packet_observed={{'+','.join(ip_fields)+'};\n'
s+='`include "tb_if_stage_body.svh"\nendmodule\n'
(WORK/'tb_if_stage.sv').write_text(s)
iverilog=shutil.which('iverilog') or str(next((ROOT/'work/tools/iverilog').rglob('iverilog.exe')))
vvp=str(Path(iverilog).with_name('vvp.exe' if iverilog.endswith('.exe') else 'vvp'))


def run(command,log,timeout=60):
    p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=timeout)
    (WORK/log).write_text(p.stdout+p.stderr,encoding='utf-8')
    assert p.returncode==0,p.stdout+p.stderr
    return p.stdout


for mod in new_modules:
    run([iverilog,'-g2001','-s',mod,'-f','rtl/if_stage_files.f','-o',str(WORK/f'{mod}.vvp')],mod+'_compile.log')
bht_sources=['rtl/rv32_ifu_'+n+'.v' for n in ['bht','bht_sel_array','bht_pre_array']]
run([iverilog,'-g2012','-Wall','-s','tb_if_stage','-I',str(ROOT/'tb'),'-f','rtl/if_stage_files.f',
     '-o',str(WORK/'tb.vvp'),str(WORK/'tb_if_stage.sv'),*bht_sources],'compile.log')
out=run([vvp,str(WORK/'tb.vvp')],'simulation.log')
assert 'PASS IF stage' in out
# Generated datapath and grant wrapper must reproduce exactly.
generated=[ROOT/'rtl/rv32_ifu_ifdp.v', ROOT/'rtl/rv32_ifu_if_array.v', ROOT/'rtl/if_stage_files.f']
before={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in generated}
for script in ['build_ifdp.py','build_if_array.py']:
    run([sys.executable,str(ROOT/'scripts'/script)],script+'.log')
assert all(hashlib.sha256(p.read_bytes()).hexdigest()==v for p,v in before.items())
result={'lint_errors':0,'lint_warnings':0,'verilog2001':True,'assign_generate_style':True,
        'xlsx_ports_checked':checked,'generator_reproducibility':True,'simulation':out.strip(),
        'rtl_sha256':{m:hashlib.sha256((ROOT/'rtl'/f'{m}.v').read_bytes()).hexdigest() for m in new_modules}}
(WORK/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(out,end='')
print('IF stage checks passed;',len(checked),'Excel mappings; no lint diagnostics.')
