"""Directed SF/BAR feedback tests and strict style checks for support RTL."""
from pathlib import Path
import json,re,shutil,subprocess
from pyslang import ast,syntax,DiagnosticEngine
from rtl_style import public_ports,layout
ROOT=Path(__file__).resolve().parents[1];WORK=ROOT/'work/support'
WORK.mkdir(parents=True,exist_ok=True)
files=(ROOT/'rtl/support_files.f').read_text().splitlines()
c=ast.Compilation()
for f in files:
    s=(ROOT/f).read_text();assert layout(s)==s
    tree=syntax.SyntaxTree.fromText(s);c.addSyntaxTree(tree)
    blocks=[]
    tree.root.visit(lambda n:blocks.append(str(n)) if type(n).__name__=='ProceduralBlockSyntax' else None)
    for b in blocks:
        assert 'posedge forever_cpuclk or negedge cpurst_b' in b
        assert len(re.findall(r'\bif\s*\(',b))==2
        assert len(re.findall('<=',b))==2
        assert re.search(r'<=\s*\w+_nxt(?:\[\w+\])?;',b)
ds=c.getAllDiagnostics();report=DiagnosticEngine.reportAll(c.sourceManager,ds)
(WORK/'lint.log').write_text(report,encoding='utf-8');assert not ds,report
ps=public_ports((ROOT/'rtl/rv32_ifu_sfp.v').read_text())
s='`timescale 1ns/1ps\nmodule tb_sfp;\n'
for d,w,n in ps:s+=('reg' if d=='input' else 'wire')+' '+w+' '+n+';\n'
s+='rv32_ifu_sfp dut('+','.join(f'.{n}({n})' for _,_,n in ps)+');\n'
s+='task defaults;begin\n'+'\n'.join(n+'=0;' for d,_,n in ps if d=='input')+'\nend endtask\n'
s+='`include "tb_sfp_body.svh"\nendmodule\n';(WORK/'tb.sv').write_text(s)
iv=shutil.which('iverilog') or str(next((ROOT/'work/tools/iverilog').rglob('iverilog.exe')))
vvp=str(Path(iv).with_name('vvp.exe' if iv.endswith('.exe') else 'vvp'))
def run(cmd,log):
    p=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60)
    (WORK/log).write_text(p.stdout+p.stderr,encoding='utf-8');assert p.returncode==0,p.stdout+p.stderr
    return p.stdout
run([iv,'-g2001','-f','rtl/support_files.f','-o',str(WORK/'rtl.vvp')],'compile2001.log')
run([iv,'-g2012','-s','tb_sfp','-I',str(ROOT/'tb'),'-f','rtl/support_files.f',
     '-o',str(WORK/'tb.vvp'),str(WORK/'tb.sv')],'compile.log')
out=run([vvp,str(WORK/'tb.vvp')],'simulation.log');assert 'PASS SFP' in out
(WORK/'result.json').write_text(json.dumps({'simulation':out,'lint_errors':0,'diagnostics':0,
    'style':True,'verilog2001':True},indent=2))
print(out)
