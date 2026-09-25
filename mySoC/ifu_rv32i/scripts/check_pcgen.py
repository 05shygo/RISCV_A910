"""Validate PCGEN style/interfaces and simulate against a behavioral scoreboard."""
from pathlib import Path
import hashlib
import json
import random
import re
import shutil
import subprocess
import sys

import openpyxl
from pyslang import ast, syntax, DiagnosticEngine
from rtl_style import public_ports, layout

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tb'))
from pcgen_model import PcgenModel

WORK = ROOT/'work/pcgen'
WORK.mkdir(parents=True, exist_ok=True)
rtl = ROOT/'rtl/rv32_ifu_pcgen.v'
text = rtl.read_text()
assert layout(text) == text, 'Formatting drift'
tree = syntax.SyntaxTree.fromText(text)
blocks, loops = [], []


def inspect(node):
    if type(node).__name__ == 'ProceduralBlockSyntax':
        blocks.append(str(node))
    if type(node).__name__ == 'ForLoopStatementSyntax':
        loops.append(str(node))


tree.root.visit(inspect)
assert len(blocks) == 3 and not loops
assert set(re.findall(r'\breg\s+(?:\[[^\]]+\]\s*)?(\w+)', text)) == {'if_pc_q', 'way_q', 'flag_q'}
for block in blocks:
    assert 'always @(posedge forever_cpuclk or negedge cpurst_b)' in block
    assert len(re.findall(r'\bif\s*\(', block)) == 2, block
    assert re.search(r'else if\s*\(\w+_en(?:\[\w+\])?\)', block), block
    rhs = re.findall(r'<=\s*([^;]+);', block)
    assert len(rhs) == 2 and re.fullmatch(r"\d+'b0+", rhs[0].strip()), block
    assert re.fullmatch(r'\w+_nxt(?:\[\w+\])?', rhs[1].strip()), block
for label in ['g_mux', 'g_source', 'g_bit', 'g_term', 'g_bank', 'g_flag', 'g_way_state']:
    assert 'begin : '+label in text
assert not re.search(r'\b(?:ifu_mmu_\w+|ipctrl_pcgen_h0_vld|ifu_rtu_cur_pc\w*)\b', text)

comp = ast.Compilation()
comp.addSyntaxTree(tree)
diags = comp.getAllDiagnostics()
report = DiagnosticEngine.reportAll(comp.sourceManager, diags)
(WORK/'lint.log').write_text(report, encoding='utf-8')
assert not diags, report

ports = public_ports(text)
width = lambda w: int(re.fullmatch(r'\[\s*(\d+)\s*:\s*0\s*\]', w)[1])+1 if w else 1
pp = {n: (d, width(w)) for d, w, n in ports}
book = openpyxl.load_workbook(ROOT/'doc/RV32I_C910_IFU_interface_v1.1_noMMU.xlsx',
                             read_only=True, data_only=True)
xlsx_checked = []
for name, direction, _ in book['IFU_Interface'].values:
    match = re.fullmatch(r'(\w+)(\[\d+:0\])?', str(name))
    if match and match[1] in pp:
        assert pp[match[1]] == (direction.lower(), width(match[2] or '')), name
        xlsx_checked.append(match[1])
book.close()
assert len(xlsx_checked) == 11, xlsx_checked
array_ports = public_ports((ROOT/'rtl/rv32_ifu_icache_if.v').read_text())
array_checked = []
for d, w, n in array_ports:
    if n.startswith('pcgen_'):
        assert pp[n] == ('output', width(w)) and d == 'input', n
        array_checked.append(n)
assert len(array_checked) == 12

inputs = [(n, width(w)) for d, w, n in ports if d == 'input' and n != 'forever_cpuclk']
outputs = [(n, width(w)) for d, w, n in ports if d == 'output']
in_width, out_width = sum(w for _, w in inputs), sum(w for _, w in outputs)
base = {n: 0 for n, _ in inputs}
base.update(cpurst_b=1, cp0_yy_clk_en=1, cp0_ifu_iwpe=1)
pc_names = ['debug_pcgen_pc', 'vector_pcgen_pc', 'rtu_ifu_chgflw_pc', 'iu_ifu_chgflw_pc',
            'addrgen_pcgen_pc', 'ibctrl_pcgen_pc', 'ipctrl_pcgen_reissue_pc',
            'ipctrl_pcgen_chgflw_pc', 'ifctrl_pcgen_pcload_pc']
requests = ['debug_pcgen_pcload', 'vector_pcgen_pcload', 'rtu_ifu_chgflw_vld',
            'iu_ifu_chgflw_vld', 'addrgen_pcgen_pcload', 'ibctrl_pcgen_pcload',
            'ipctrl_pcgen_reissue_pcload', 'ipctrl_pcgen_chgflw_pcload',
            'ifctrl_pcgen_chgflw_vld', 'ifctrl_pcgen_reissue_pcload']
base.update({n: 0x80001004 + 0x104*i for i, n in enumerate(pc_names)})
base.update(ibctrl_pcgen_way_pred=1, ipctrl_pcgen_reissue_way_pred=2,
            ipctrl_pcgen_chgflw_way_pred=1, ifctrl_pcgen_way_pred=2)
cases = []


def add(label, **changes):
    cases.append((label, dict(base, **changes)))


add('reset', cpurst_b=0)
add('initialization_hold', vector_pcgen_reset_on=1)
add('reset_vector_load_during_init', vector_pcgen_pcload=1, vector_pcgen_pc=0x1004,
    vector_pcgen_reset_on=1, ifctrl_pcgen_stall=1)
add('initialization_hold', vector_pcgen_reset_on=1)
add('vector_reissue', ifctrl_pcgen_reissue_pcload=1)
for _ in range(20):
    add('sequential_block_line_bht_boundary')
for source in range(9):
    for slot in range(4):
        for stall in range(2):
            add('single_source_slot_stall', **{requests[source]: 1, pc_names[source]: 0xfffffff0+4*slot,
                'rtu_ifu_dbgon': int(source == 0), 'ifctrl_pcgen_stall': stall,
                'ifctrl_pcgen_chgflw_no_stall_mask': int(source == 8)})
            add('redirect_followup_reissue', ifctrl_pcgen_reissue_pcload=int(source < 3))
            add('wrap_or_next_block')
for stall in range(2):
    for mask in range(1024):
        updates = {n: (mask >> i) & 1 for i, n in enumerate(requests)}
        updates.update(rtu_ifu_dbgon=1, ifctrl_pcgen_stall=stall,
                       ifctrl_pcgen_chgflw_no_stall_mask=(mask >> 8) & 1)
        add('all_source_combinations', **updates)
for higher in range(8):
    for slot in range(4):
        updates = {requests[higher]: 1, 'ipctrl_pcgen_chgflw_pcload': 1,
                   'ipctrl_pcgen_branch_taken': 1, 'ipctrl_pcgen_taken_pc': 0x1230+4*slot,
                   'ipctrl_pcgen_chgflw_pc': 0x1230+4*slot, 'rtu_ifu_dbgon': 1,
                   'ifctrl_pcgen_stall': 1}
        add('bank_mask_winner', **updates)
for _ in range(4):
    add('early_l0_hint_stalled', ifctrl_pcgen_stall=1, ifctrl_pcgen_chgflw_no_stall_mask=1)
add('early_l0_hint_advancing', ifctrl_pcgen_chgflw_no_stall_mask=1)
add('debug_entry', rtu_ifu_dbgon=1, ifctrl_pcgen_stall=1)
add('debug_level', rtu_ifu_dbgon=1, ifctrl_pcgen_stall=1)
add('debug_exit', ifctrl_pcgen_stall=1)
add('unaccepted_debug_command', debug_pcgen_pcload=1, ifctrl_pcgen_stall=1)
for disabled in ['cp0_yy_clk_en', 'cp0_ifu_iwpe', 'vector_pcgen_reset_on']:
    for i in range(12):
        add('clock_init_way_disable', **{disabled: int(disabled == 'vector_pcgen_reset_on'),
            'iu_ifu_chgflw_vld': int(i == 2), 'ifctrl_pcgen_stall': int(i % 3 == 0)})
for way in range(4):
    add('way_redirect', ibctrl_pcgen_pcload=1, ibctrl_pcgen_way_pred=way)
    for stall in [1, 1, 1, 0, 0, 0, 0]:
        add('way_hold_resume', ifctrl_pcgen_stall=stall)

rng = random.Random(0xC910_0032)
for cycle in range(10000):
    p = {n: rng.getrandbits(w) for n, w in inputs}
    for n in pc_names+['ipctrl_pcgen_taken_pc']:
        p[n] &= 0xfffffffc
    p['cpurst_b'] = int(cycle % 937 != 0)
    p['cp0_yy_clk_en'] = int(cycle % 13 != 0)
    p['vector_pcgen_reset_on'] = int(cycle % 127 < 3)
    # Exercise both quiet operation and dense conflicts.
    for n in requests:
        p[n] = int(rng.randrange(4 if cycle % 4 == 0 else 20) == 0)
    p['debug_pcgen_pcload'] &= p['rtu_ifu_dbgon']
    p['rtu_ifu_flush'] = p['rtu_ifu_chgflw_vld']
    p['ifctrl_pcgen_chgflw_no_stall_mask'] |= p['ifctrl_pcgen_chgflw_vld']
    if cycle % 2:
        p['ipctrl_pcgen_taken_pc'] = p['ipctrl_pcgen_chgflw_pc']
    cases.append(('random', p))


def pack(values, fields):
    result = 0
    for n, w in fields:
        assert 0 <= values[n] < 2**w, (n, values[n])
        result = (result << w) | values[n]
    return result


model = PcgenModel()
stimuli, before, after = [], [], []
coverage = {}
for label, p in cases:
    coverage[label] = coverage.get(label, 0)+1
    if not p['cpurst_b']:
        model.reset()
    expected, _ = model.evaluate(p)
    assert set(expected) == {n for n, _ in outputs}
    stimuli.append(pack(p, inputs))
    before.append(pack(expected, outputs))
    model.tick(p)
    after.append(pack(model.evaluate(p)[0], outputs))
for name, values, bits in [('inputs', stimuli, in_width), ('before', before, out_width),
                           ('after', after, out_width)]:
    (WORK/f'{name}.hex').write_text(''.join(f'{v:0{(bits+3)//4}x}\n' for v in values))

bench = '`timescale 1ns/1ps\nmodule tb_pcgen;\n'
for d, w, n in ports:
    bench += f'{"reg" if d == "input" else "wire"} {w} {n};\n'
bench += 'rv32_ifu_pcgen dut(\n'+',\n'.join(f'.{n}({n})' for _, _, n in ports)+'\n);\n'
bench += f'reg [{in_width-1}:0] stimulus [0:{len(cases)-1}];\n'
bench += f'reg [{out_width-1}:0] expected_before [0:{len(cases)-1}];\n'
bench += f'reg [{out_width-1}:0] expected_after [0:{len(cases)-1}];\n'
bench += f'reg [{out_width-1}:0] expected;\ninteger cycle; integer comparisons=0;\n'
bench += 'task compare; begin\n'
offset = out_width
for n, w in outputs:
    offset -= w
    expr = f'expected[{offset} +: {w}]'
    bench += f'comparisons=comparisons+1; if ({n} !== {expr}) $fatal(1, "cycle=%0d clk=%b {n}: got=%h expected=%h", cycle,forever_cpuclk,{n},{expr});\n'
bench += 'end endtask\ninitial begin\nforever_cpuclk=0; cpurst_b=1;\n'
for name, array in [('inputs', 'stimulus'), ('before', 'expected_before'), ('after', 'expected_after')]:
    bench += f'$readmemh("{name}.hex", {array});\n'
bench += f'for(cycle=0; cycle<{len(cases)}; cycle=cycle+1) begin\n'
bench += '{'+','.join(n for n, _ in inputs)+'}=stimulus[cycle];\n'
bench += '#1; expected=expected_before[cycle]; compare;\n'
bench += '#1; forever_cpuclk=1; #1; expected=expected_after[cycle]; compare;\n'
bench += '#1; forever_cpuclk=0; #1;\nend\n'
bench += '$display("PASS PCGEN cycles=%0d comparisons=%0d",cycle,comparisons); $finish; end\nendmodule\n'
(WORK/'tb_pcgen.sv').write_text(bench)
iverilog = shutil.which('iverilog') or str(next((ROOT/'work/tools/iverilog').rglob('iverilog.exe')))
vvp = str(Path(iverilog).with_name('vvp.exe' if iverilog.endswith('.exe') else 'vvp'))


def run(cmd, log):
    p = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True, timeout=60)
    (WORK/log).write_text(p.stdout+p.stderr, encoding='utf-8')
    assert p.returncode == 0, p.stdout+p.stderr
    return p.stdout


run([iverilog, '-g2001', '-Wall', '-s', 'rv32_ifu_pcgen', '-o', 'pcgen.vvp', str(rtl)], 'verilog2001.log')
run([iverilog, '-g2012', '-Wall', '-s', 'tb_pcgen', '-o', 'tb.vvp', str(rtl), str(WORK/'tb_pcgen.sv')],
    'compile.log')
simulation = run([vvp, 'tb.vvp'], 'simulation.log')
assert 'PASS PCGEN' in simulation

# Connect all twelve PCGEN array signals to the actual existing SRAM wrappers.
signals = {n: (d, w) for d, w, n in ports}
for d, w, n in array_ports:
    if n in signals:
        assert width(signals[n][1]) == width(w), n
    else:
        signals[n] = (d, w)
bench_array = '`timescale 1ns/1ps\nmodule tb_pcgen_array;\n'
for n, (d, w) in signals.items():
    bench_array += f'{"reg" if d == "input" else "wire"} {w} {n};\n'
for module, instance, module_ports in [('rv32_ifu_pcgen', 'dut', ports),
                                       ('rv32_ifu_icache_if', 'u_array', array_ports)]:
    bench_array += module+' '+instance+'(\n'+',\n'.join(
        f'.{n}({n})' for _, _, n in module_ports)+'\n);\n'
bench_array += 'task defaults; begin\n'
bench_array += '\n'.join(n+'=0;' for n, (d, _) in signals.items() if d == 'input')
bench_array += '\nend endtask\n`include "tb_pcgen_array_body.svh"\nendmodule\n'
(WORK/'tb_pcgen_array.sv').write_text(bench_array)
array_files = [str(ROOT/f) for f in (ROOT/'rtl/icache_files.f').read_text().splitlines()]
run([iverilog, '-g2012', '-Wall', '-s', 'tb_pcgen_array', '-I', str(ROOT/'tb'),
     '-o', 'array.vvp', str(rtl), *array_files, str(WORK/'tb_pcgen_array.sv')], 'array_compile.log')
array_simulation = run([vvp, 'array.vvp'], 'array_simulation.log')
assert 'PASS PCGEN + ICache array' in array_simulation
result = {'rtl_sha256': hashlib.sha256(rtl.read_bytes()).hexdigest(), 'lint_errors': 0,
          'lint_warnings': 0, 'assign_only_combinational': True, 'sequential_templates': len(blocks),
          'verilog2001_compile': True, 'xlsx_ports_checked': xlsx_checked,
          'icache_array_ports_checked': array_checked, 'cycles': len(cases),
          'outputs_per_sample': len(outputs), 'comparisons': len(cases)*2*len(outputs),
          'seed': '0xc9100032', 'coverage': coverage, 'simulation': simulation.strip(),
          'array_simulation': array_simulation.strip()}
(WORK/'result.json').write_text(json.dumps(result, indent=2)+'\n')
print(simulation, end='')
print(array_simulation, end='')
print(f'PCGEN checks passed; {len(xlsx_checked)} Excel ports; {len(array_checked)} ICache ports; no lint diagnostics.')
