"""Slang elaboration plus exact-width checks against the supplied interface XLSX."""
from pathlib import Path
import json
import re
import sys
import openpyxl
from pyslang import syntax, ast, DiagnosticEngine

root = Path(__file__).resolve().parents[1]
(root/'work').mkdir(exist_ok=True)
c = ast.Compilation()
for f in (root/'rtl/files.f').read_text().splitlines():
    c.addSyntaxTree(syntax.SyntaxTree.fromFile(str(root/f)))
diags = c.getAllDiagnostics()
report = DiagnosticEngine.reportAll(c.sourceManager, diags)
(root/'work/lint.log').write_text(report, encoding='utf-8')
errors = [d for d in diags if d.isError()]
# Preserve original mixed &&/|| expressions; all other diagnostics are failures.
unexpected = [d for d in diags if str(d.code) != 'DiagCode(LogicalOpParentheses)']
ports = json.loads((root/'doc/ports.json').read_text())
xlsx = root/'doc/RV32I_C910_IFU_interface_v1.1_noMMU.xlsx'
book = openpyxl.load_workbook(xlsx,read_only=True,data_only=True)
checked=[]
for row in book['IFU_Interface'].values:
    name=str(row[0] or '')
    m=re.fullmatch(r'(\w+)(\[\d+:\d+\])?',name)
    if m and m[1] in ports:
        direction,width=ports[m[1]]
        assert width.replace(' ','')==(m[2] or ''), (name,width)
        assert direction.lower()==str(row[1]).lower(), (name,direction,row[1])
        checked.append(name)
assert len(checked)>=25, checked
result={'rtl_files':len((root/'rtl/files.f').read_text().splitlines()),
        'errors':len(errors),'legacy_parentheses_warnings':len(diags)-len(unexpected),
        'unexpected_diagnostics':len(unexpected),'xlsx_ports_checked':checked}
(root/'work/check_result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps({k:(len(v) if isinstance(v,list) else v) for k,v in result.items()}))
if unexpected:
    print(DiagnosticEngine.reportAll(c.sourceManager,unexpected))
    sys.exit(1)
