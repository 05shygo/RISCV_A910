"""Structure, reproducibility and four-state differential checks for ICache IF.

Uses the immutable snapshot captured before the TT-style rewrite. This is
simulation comparison of known control inputs, not a formal equivalence proof.
"""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pyslang import syntax
from rtl_style import public_ports, layout

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT/'work/icache_if_generate'
WORK.mkdir(parents=True, exist_ok=True)
path = ROOT/'rtl/rv32_ifu_icache_if.v'
s = path.read_text()
assert layout(s) == s
tree = syntax.SyntaxTree.fromText(s)
blocks = []
loops = []
def inspect(node):
    if type(node).__name__ == 'ProceduralBlockSyntax':
        blocks.append(str(node))
    if type(node).__name__ == 'ForLoopStatementSyntax':
        loops.append(str(node))
tree.root.visit(inspect)
assert len(blocks) == 1 and not loops
assert not re.search(r'always\s*@\s*\(\s*\*', s)
assert 'always @(posedge hpcp_clk or negedge cpurst_b)' in blocks[0]
for rhs in re.findall(r'<=\s*([^;]+);', blocks[0]):
    assert re.fullmatch(r"(?:1'b0|event_nxt\[event_index\])", rhs.strip()), rhs
assert set(re.findall(r'\breg\s+(?:\[[^\]]+\]\s*)?(\w+)', s)) == {'event_q'}
for label in ['g_owner', 'g_index_reduce', 'g_way', 'g_bank', 'g_event']:
    assert 'begin : '+label in s

before_dir = ROOT/'work/icache_if_generate_before'
before = before_dir/path.name
manifest = json.loads((before_dir/'manifest.json').read_text())
assert hashlib.sha256(before.read_bytes()).hexdigest() == manifest['rtl/'+path.name]
assert public_ports(before.read_text()) == public_ports(s)
(WORK/'reference.v').write_text(before.read_text().replace(
    'module rv32_ifu_icache_if', 'module before_rv32_ifu_icache_if', 1))

# A regeneration must not undo the generated circuits, alter other modules, or
# change the source manifest/delta. Inspect every product touched by the command.
products = list((ROOT/'rtl').glob('*.v')) + [ROOT/'doc/icache_source_manifest.json',
                                          ROOT/'doc/icache_C910_delta.patch']
hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in products}
p = subprocess.run([sys.executable, str(ROOT/'scripts/derive_icache.py')],
                   capture_output=True, text=True, timeout=60)
assert p.returncode == 0, p.stdout+p.stderr
assert all(hashlib.sha256(p.read_bytes()).hexdigest() == h for p, h in hashes.items()), 'Regeneration drift'

ports = public_ports(s)
bench = '`timescale 1ns/1ps\nmodule tb_icache_if_generate;\n'
for d, w, n in ports:
    bench += f'{"reg" if d=="input" else "wire"} {w} {n};\n'
    if d == 'output':
        bench += f'wire {w} before_{n};\n'
for mod, inst, prefix in [('rv32_ifu_icache_if','dut',''),
                          ('before_rv32_ifu_icache_if','ref_dut','before_')]:
    bench += mod+' '+inst+'(\n'+',\n'.join(
        f'.{n}({prefix if d=="output" else ""}{n})' for d, _, n in ports)+'\n);\n'
bench += 'integer comparisons=0;\ntask compare; begin\n'
pairs = [(n, 'before_'+n) for d, _, n in ports if d == 'output']
for n in ['icache_index_higher','ifu_icache_index','icache_index_sel','icache_req_higher',
          'ifu_icache_tag_wen','ifu_icache_tag_cen_b','ifu_icache_tag_clk_en','ifu_icache_tag_din',
          'icache_way_pred','hpcp_clk_en']:
    pairs.append(('dut.'+n, 'ref_dut.'+n))
for i in range(2):
    for j in range(4):
        pairs += [(f'dut.data_cen_b[{i}][{j}]', f'ref_dut.ifu_icache_data_array{i}_bank{j}_cen_b'),
                  (f'dut.data_clk_en[{i}][{j}]', f'ref_dut.ifu_icache_data_array{i}_bank{j}_clk_en')]
    for left, right in [('way_wen_b', f'ifu_icache_data_array{i}_wen_b'),
                        ('way_wen_b', f'ifu_icache_predecd_array{i}_wen_b'),
                        ('way_clk_en', f'ifu_icache_predecd_array{i}_clk_en'),
                        ('precode_cen_b', f'ifu_icache_predecd_array{i}_cen_b')]:
        pairs.append((f'dut.{left}[{i}]', 'ref_dut.'+right))
    pairs += [('dut.data_din',f'ref_dut.ifu_icache_data_array{i}_din'),
              ('dut.precode_din',f'ref_dut.ifu_icache_predecd_array{i}_din')]
pairs += [('dut.event_q[0]','ref_dut.ifu_hpcp_icache_access_q'),
          ('dut.event_q[1]','ref_dut.ifu_hpcp_icache_miss_q')]
for a, b in pairs:
    bench += f'comparisons=comparisons+1; if({a} !== {b}) $fatal(1,"{a} mismatch t=%0t got=%h ref=%h",$time,{a},{b});\n'
bench += 'end endtask\ntask defaults; begin\n'
for d, w, n in ports:
    if d=='input' and n not in ['forever_cpuclk','cpurst_b']:
        bench += f'{n}=0;\n'
bench += "cp0_ifu_icache_en=1; cp0_yy_clk_en=1; hpcp_ifu_cnt_en=1;\nend endtask\n"
bench += '`include "tb_icache_if_generate_body.svh"\nendmodule\n'
(WORK/'tb.sv').write_text(bench)
iverilog = shutil.which('iverilog') or str(next((ROOT/'work/tools/iverilog').rglob('iverilog.exe')))
vvp = str(Path(iverilog).with_name('vvp.exe' if iverilog.endswith('.exe') else 'vvp'))
cmd = [iverilog,'-g2012','-s','tb_icache_if_generate','-I',str(ROOT/'tb'),
       '-f','rtl/icache_files.f','-o',str(WORK/'tb.vvp'),str(WORK/'reference.v'),str(WORK/'tb.sv')]
for label, command in [('compile',cmd),('simulation',[vvp,str(WORK/'tb.vvp')])]:
    p = subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=60)
    (WORK/f'{label}.log').write_text(p.stdout+p.stderr)
    if p.returncode:
        raise SystemExit(p.stdout+p.stderr)
    if label == 'simulation':
        assert 'PASS ICache IF generate' in p.stdout
        print(p.stdout,end='')
        report = {'reference_sha256':manifest['rtl/'+path.name],
                  'rtl_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                  'public_ports_unchanged':True, 'assign_only_combinational':True,
                  'procedural_loops':0, 'register_process_templates':1,
                  'regeneration_unchanged':True, 'signals_compared_per_sample':len(pairs),
                  'simulation':p.stdout.strip()}
        (WORK/'result.json').write_text(json.dumps(report,indent=2)+'\n')
