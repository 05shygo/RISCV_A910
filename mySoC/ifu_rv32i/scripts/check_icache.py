"""Elaborate RTL, check Excel ports and run self-checking ICache simulations."""
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import openpyxl
from pyslang import ast, syntax, DiagnosticEngine
from rtl_style import public_ports, layout

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT/'work/icache'
WORK.mkdir(parents=True, exist_ok=True)
files = (ROOT/'rtl/icache_files.f').read_text().splitlines()
c = ast.Compilation()
for f in files:
    c.addSyntaxTree(syntax.SyntaxTree.fromFile(str(ROOT/f)))
ds = c.getAllDiagnostics()
(WORK/'lint.log').write_text(DiagnosticEngine.reportAll(c.sourceManager, ds), encoding='utf-8')
allowed = {'DiagCode(LogicalOpParentheses)', 'DiagCode(EmptyOutputPortConn)'}
unexpected = [d for d in ds if str(d.code) not in allowed]
if unexpected:
    print(DiagnosticEngine.reportAll(c.sourceManager, unexpected))
    raise SystemExit(1)
modules = ['rv32_ifu_icache_top', 'rv32_ifu_icache_biu']
ports = {m: {n: (d, re.sub(r'\s+', '', w)) for d, w, n in
              public_ports((ROOT/'rtl'/f'{m}.v').read_text())} for m in modules}
book = openpyxl.load_workbook(ROOT/'doc/RV32I_C910_IFU_interface_v1.1_noMMU.xlsx',
                             read_only=True, data_only=True)
excel_ports = {}
for name, direction, desc in book['IFU_Interface'].values:
    m = re.fullmatch(r'(\w+)(\[\d+:\d+\])?', str(name))
    if m and direction in ('Input', 'Output'):
        excel_ports[m[1]] = (direction.lower(), m[2] or '')
checked = []
for module, pp in ports.items():
    for name, spec in pp.items():
        if name in excel_ports:
            assert spec == excel_ports[name], (module, name, spec, excel_ports[name])
            checked.append(module+'.'+name)
assert len(checked) >= 35
for f in files:
    s = (ROOT/f).read_text()
    assert layout(s) == s, 'Formatting drift: '+f
    assert not re.search(r'\b(?:mmu|itlb)_\w+', s), f

# Generate wiring only; tests and the independent data model live in a reviewed .svh.
signals = {}
for module in modules:
    for n, (d, w) in ports[module].items():
        if n in signals:
            assert signals[n][1] == w
            if d == 'output':
                signals[n] = (d, w)
        else:
            signals[n] = (d, w)
s = '`timescale 1ns/1ps\nmodule tb_icache;\n'
s += '\n'.join(f'{"reg" if d=="input" else "wire"} {w} {n};' for n, (d, w) in signals.items())
s += '''
rv32_ifu_icache_top #(
  .REGION_COUNT(5),
  .REGION_BASE({32'hfffff000,32'h30000000,32'h20000000,32'h10000000,32'h00000000}),
  .REGION_LIMIT({33'h100000000,33'h030010000,33'h020010000,33'h010010000,33'h000200000}),
  .REGION_ATTR({5'b11101,5'b11110,5'b01001,5'b10101,5'b11101})
) dut (\n'''
s += ',\n'.join(f'.{n}({n})' for n in ports[modules[0]])+'\n);\n'
s += 'rv32_ifu_icache_biu u_biu (\n'
s += ',\n'.join(f'.{n}({n})' for n in ports[modules[1]])+'\n);\n'
s += 'task defaults; begin\n'
s += '\n'.join(f'{n}=0;' for n, (d, w) in signals.items()
               if d == 'input' and n not in ['forever_cpuclk', 'cpurst_b'])
s += '''
cp0_yy_clk_en=1; cp0_ifu_icache_en=1; cp0_ifu_iwpe=1;
hpcp_ifu_cnt_en=1; cp0_ifu_insde=1; cp0_yy_priv_mode=3; ipb_idle=1;
end endtask
`include "tb_icache_body.svh"
endmodule
'''
(WORK/'tb_icache.sv').write_text(s)
iverilog = shutil.which('iverilog')
if not iverilog:
    hits = list((ROOT/'work/tools/iverilog').rglob('iverilog.exe'))
    if not hits:
        raise SystemExit('Icarus Verilog is required on PATH or under work/tools/iverilog')
    iverilog = str(hits[0].resolve())
vvp = str(Path(iverilog).with_name('vvp.exe' if iverilog.endswith('.exe') else 'vvp'))


def run(cmd, name, timeout=60):
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    (WORK/name).write_text(p.stdout+p.stderr, encoding='utf-8')
    if p.returncode:
        print(p.stdout+p.stderr)
        raise SystemExit(p.returncode)
    return p.stdout


run([iverilog, '-g2001', '-s', 'rv32_ifu_icache_top', '-f', 'rtl/icache_files.f',
     '-o', str(WORK/'compile.vvp')], 'verilog2001.log')
run([iverilog, '-g2012', '-Wall', '-s', 'tb_icache', '-I', str(ROOT/'tb'),
     '-f', 'rtl/icache_files.f', '-o', str(WORK/'tb_icache.vvp'),
     str(WORK/'tb_icache.sv')], 'compile.log')
out = run([vvp, str(WORK/'tb_icache.vvp')], 'simulation.log', 120)
print(out, end='')
assert 'PASS' in out
run([iverilog, '-g2012', '-s', 'tb_icache_precode', '-f', 'rtl/icache_files.f',
     '-o', str(WORK/'tb_icache_precode.vvp'), str(ROOT/'tb/tb_icache_precode.sv')],
    'precode_compile.log')
precode_out = run([vvp, str(WORK/'tb_icache_precode.vvp')], 'precode_simulation.log')
print(precode_out, end='')
assert 'PASS' in precode_out
report = {'rtl_files': len(files), 'errors': 0, 'warnings': len(ds),
          'warning_codes': sorted({str(d.code) for d in ds}),
          'xlsx_ports_checked': checked, 'verilog2001_compile': True,
          'style_check': True, 'simulation': out.strip(), 'precode_simulation': precode_out.strip()}
(WORK/'result.json').write_text(json.dumps(report, indent=2)+'\n')
print('ICache checks passed;', len(checked), 'Excel port mappings checked.')
