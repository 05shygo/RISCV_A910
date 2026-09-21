"""Compile and exercise IP/IB, two-record allocation and real bypass/merge."""
from pathlib import Path
import json,re,shutil,subprocess,sys
from pyslang import ast,syntax,DiagnosticEngine
from rtl_style import public_ports,layout

ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'work/pipeline'
WORK.mkdir(parents=True,exist_ok=True)
files=(ROOT/'rtl/pipeline_files.f').read_text().splitlines()
c=ast.Compilation()
for f in files:
    p=ROOT/f
    c.addSyntaxTree(syntax.SyntaxTree.fromFile(str(p)))
    if p.stem=='rv32_ifu_bp_decode':continue
    s=p.read_text()
    assert layout(s)==s
    assert not re.search(r'always\s*@\s*\(\s*\*',s)
    blocks=[]
    syntax.SyntaxTree.fromText(s).root.visit(lambda n: blocks.append(str(n))
        if type(n).__name__=='ProceduralBlockSyntax' else None)
    for b in blocks:
        assert 'posedge forever_cpuclk or negedge cpurst_b' in b
        assert len(re.findall(r'\bif\s*\(',b))==2
        assert len(re.findall('<=',b))==2
        assert re.search(r'<=\s*\w+_nxt(?:\[\w+\])?;',b)
diags=c.getAllDiagnostics()
report=DiagnosticEngine.reportAll(c.sourceManager,diags)
(WORK/'lint.log').write_text(report,encoding='utf-8')
assert not any(d.isError() for d in diags),report
ps=public_ports((ROOT/'rtl/rv32_ifu_pipeline.v').read_text())
s='`timescale 1ns/1ps\nmodule tb_pipeline;\n'
for d,w,n in ps:s+=('reg' if d=='input' else 'wire')+' '+w+' '+n+';\n'
s+='rv32_ifu_pipeline u_pipe('+','.join(f'.{n}({n})' for _,_,n in ps)+');\n'
s+='task defaults; begin\n'+'\n'.join(n+'=0;' for d,_,n in ps if d=='input')+'\nend endtask\n'
s+='`include "tb_pipeline_body.svh"\nendmodule\n'
(WORK/'tb.sv').write_text(s)
iv=shutil.which('iverilog') or str(next((ROOT/'work/tools/iverilog').rglob('iverilog.exe')))
vvp=str(Path(iv).with_name('vvp.exe' if iv.endswith('.exe') else 'vvp'))
def run(cmd,log):
    p=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=90)
    (WORK/log).write_text(p.stdout+p.stderr,encoding='utf-8')
    assert p.returncode==0,p.stdout+p.stderr
    return p.stdout
run([iv,'-g2001','-s','rv32_ifu_pipeline','-f','rtl/pipeline_files.f','-o',str(WORK/'rtl.vvp')],'compile2001.log')
run([iv,'-g2012','-s','tb_pipeline','-I',str(ROOT/'tb'),'-f','rtl/pipeline_files.f',
     '-o',str(WORK/'tb.vvp'),str(WORK/'tb.sv')],'compile.log')
out=run([vvp,str(WORK/'tb.vvp')],'simulation.log')
assert 'PASS pipeline' in out
(WORK/'result.json').write_text(json.dumps({'simulation':out,'lint_errors':0,
    'lint_diagnostics':len(diags),'style':True,'verilog2001':True},indent=2))
print(out)
