"""Check L0 structure and compare pre-refactor/current RTL under identical inputs.

The immutable work/l0_generate_before snapshot was saved before editing RTL.
Four-state simulation comparison is not a formal equivalence proof.
"""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
from pyslang import syntax
from rtl_style import public_ports, layout

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT/'work/l0_generate'
WORK.mkdir(parents=True, exist_ok=True)
path = ROOT/'rtl/rv32_ifu_l0_btb.v'
s = path.read_text()
assert layout(s) == s
assert not re.search(r'always\s*@\s*\(\s*\*', s)
tree = syntax.SyntaxTree.fromText(s)
blocks = []
loops = []
def inspect(node):
    if type(node).__name__ == 'ProceduralBlockSyntax':
        blocks.append(str(node))
    if type(node).__name__ == 'ForLoopStatementSyntax':
        loops.append(str(node))
tree.root.visit(inspect)
assert len(blocks) == 4 and not loops, 'Repeated hardware must use generate loops'
for block in blocks:
    assert '@(posedge forever_cpuclk' in block
    # Every stored value is a reset constant or an independently assigned _nxt.
    for rhs in re.findall(r'<=\s*([^;]+);', block):
        assert re.fullmatch(r"(?:\d+'b[01]+|\w+_nxt(?:\[\w+\])?)", rhs.strip()), rhs

before_dir = ROOT/'work/l0_generate_before'
before = before_dir/path.name
manifest = json.loads((before_dir/'manifest.json').read_text())
assert hashlib.sha256(before.read_bytes()).hexdigest() == manifest['sha256']
assert public_ports(before.read_text()) == public_ports(s), 'Public interface changed'
reference = before.read_text().replace('module rv32_ifu_l0_btb', 'module before_rv32_ifu_l0_btb', 1)
(WORK/'reference.v').write_text(reference)
ports = public_ports(s)
bench = '`timescale 1ns/1ps\nmodule tb_l0_generate;\n'
for d, w, n in ports:
    bench += f'{"reg" if d=="input" else "wire"} {w} {n};\n'
    if d == 'output':
        bench += f'wire {w} before_{n};\n'
bench += 'rv32_ifu_l0_btb dut(\n'+',\n'.join(f'.{n}({n})' for _, _, n in ports)+'\n);\n'
bench += 'before_rv32_ifu_l0_btb ref_dut(\n'
bench += ',\n'.join(f'.{n}({"before_" if d=="output" else ""}{n})' for d, _, n in ports)+'\n);\n'
bench += 'integer comparisons=0;\ntask compare; integer i; begin\n'
for d, w, n in ports:
    if d == 'output':
        bench += f'comparisons=comparisons+1; if ({n} !== before_{n}) $fatal(1,"output {n} mismatch at %0t",$time);\n'
for n in ['valid_q', 'taken_q', 'use_ras_q', 'replace_ptr_q']:
    bench += f'comparisons=comparisons+1; if(dut.{n} !== ref_dut.{n}) $fatal(1,"state {n} mismatch at %0t got=%h ref=%h update_pc=%h wr=%h ref_wr=%h",$time,dut.{n},ref_dut.{n},update_pc,dut.wr_index,ref_dut.wr_index);\n'
bench += 'for(i=0;i<16;i=i+1) begin\n'
for n in ['src_q', 'dst_q', 'kind_q', 'ways_q']:
    bench += f'comparisons=comparisons+1; if(dut.{n}[i] !== ref_dut.{n}[i]) $fatal(1,"payload {n}[%0d] mismatch at %0t",i,$time);\n'
bench += 'end\nend endtask\n'
bench += 'task defaults; begin\n'
for d, w, n in ports:
    if d == 'input' and n not in ['forever_cpuclk', 'cpurst_b']:
        bench += f'{n}=0;\n'
bench += 'enable=1;\nend endtask\n'
bench += '`include "tb_l0_generate_body.svh"\nendmodule\n'
(WORK/'tb_l0_generate.sv').write_text(bench)
iverilog = shutil.which('iverilog') or str(next((ROOT/'work/tools/iverilog').rglob('iverilog.exe')))
vvp = str(Path(iverilog).with_name('vvp.exe' if iverilog.endswith('.exe') else 'vvp'))
commands = [
    ([iverilog, '-g2001', '-s', 'rv32_ifu_l0_btb', '-o', str(WORK/'rtl.vvp'), str(path)], 'verilog2001'),
    ([iverilog, '-g2012', '-s', 'tb_l0_generate', '-I', str(ROOT/'tb'), '-o', str(WORK/'tb.vvp'),
      str(path), str(WORK/'reference.v'), str(WORK/'tb_l0_generate.sv')], 'compile'),
    ([vvp, str(WORK/'tb.vvp')], 'simulation')]
for command, label in commands:
    p = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (WORK/f'{label}.log').write_text(p.stdout+p.stderr)
    if p.returncode:
        raise SystemExit(p.stdout+p.stderr)
    if label == 'simulation':
        print(p.stdout, end='')
        assert 'PASS L0 generate' in p.stdout
        report = {'reference_sha256': manifest['sha256'], 'rtl_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                  'public_ports_unchanged': True, 'assign_only_combinational': True,
                  'procedural_loops': len(loops), 'register_process_templates': len(blocks),
                  'verilog2001_compile': True, 'simulation': p.stdout.strip()}
        (WORK/'result.json').write_text(json.dumps(report, indent=2)+'\n')
