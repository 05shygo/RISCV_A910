"""Workbook boundary, complete elaboration and executable IFU integration tests."""
from pathlib import Path
import re,json,shutil,subprocess,openpyxl
from pyslang import ast,syntax,DiagnosticEngine
from rtl_style import public_ports
ROOT=Path(__file__).resolve().parents[1];WORK=ROOT/'work/ifu'
WORK.mkdir(parents=True,exist_ok=True)
c=ast.Compilation()
for f in (ROOT/'rtl/ifu_files.f').read_text().splitlines():
 c.addSyntaxTree(syntax.SyntaxTree.fromFile(str(ROOT/f)))
ds=c.getAllDiagnostics();report=DiagnosticEngine.reportAll(c.sourceManager,ds)
(WORK/'lint.log').write_text(report,encoding='utf-8');assert not any(d.isError() for d in ds),report
ps=public_ports((ROOT/'rtl/rv32_ifu_top.v').read_text())
book=openpyxl.load_workbook(ROOT.parent/'ifu/doc/RV32I_C910_IFU_interface_v1.1_noMMU.xlsx',read_only=True,data_only=True)
expected={}
for name,d,_ in book['IFU_Interface'].values:
 m=re.fullmatch(r'(\w+)(\[\d+:\d+\])?',str(name))
 if m and d in ['Input','Output']:expected[m[1]]=(d.lower(),m[2] or '')
book.close()
assert {n:(d,re.sub(r'\s','',w)) for d,w,n in ps}==expected,'Workbook boundary mismatch'
s='`timescale 1ns/1ps\nmodule tb_ifu;\n'
for d,w,n in ps:s+=('reg' if d=='input' else 'wire')+' '+w+' '+n+';\n'
s+='''rv32_ifu_top #(.REGION_COUNT(1),.REGION_BASE(32'h1000),
 .REGION_LIMIT(33'h3000),.REGION_ATTR(5'b11101)) u_ifu(
'''+','.join(f'.{n}({n})' for _,_,n in ps)+');\n'
s+='task defaults;begin\n'+'\n'.join(n+'=0;' for d,_,n in ps if d=='input')+'\nend endtask\n'
s+='`include "tb_ifu_body.svh"\nendmodule\n';(WORK/'tb.sv').write_text(s)
iv=shutil.which('iverilog') or str(next((ROOT/'work/tools/iverilog').rglob('iverilog.exe')))
vvp=str(Path(iv).with_name('vvp.exe' if iv.endswith('.exe') else 'vvp'))
def run(cmd,log):
 p=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60)
 (WORK/log).write_text(p.stdout+p.stderr,encoding='utf-8');assert p.returncode==0,p.stdout+p.stderr
 return p.stdout
run([iv,'-g2001','-s','rv32_ifu_top','-f','rtl/ifu_files.f','-o',str(WORK/'rtl.vvp')],'compile2001.log')
run([iv,'-g2012','-s','tb_ifu','-I',str(ROOT/'tb'),'-f','rtl/ifu_files.f','-o',str(WORK/'tb.vvp'),str(WORK/'tb.sv')],'compile.log')
out=run([vvp,str(WORK/'tb.vvp')],'simulation.log');assert 'PASS IFU' in out
for label,args in [('short',['+SHORT_LOOP']),('forward',['+SHORT_LOOP','+FORWARD_LOOP']),
                   ('branches',['+BRANCHES']),('loop_branches',['+SHORT_LOOP','+BRANCHES']),
                   ('pred_off',['+PRED_OFF','+BRANCHES'])]:
 result=run([vvp,str(WORK/'tb.vvp'),*args],label+'.log');assert 'PASS IFU' in result
 out+='\n'+result
(WORK/'result.json').write_text(json.dumps({'simulation':out,'lint_errors':0,'diagnostics':len(ds),'verilog2001':True,'top_ports':len(ps)},indent=2))
print(out)
