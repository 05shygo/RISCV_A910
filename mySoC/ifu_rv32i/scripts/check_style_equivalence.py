"""Replay the existing tests against the pre-style snapshot and current RTL.

Run run_tests.py first. This is sampled four-state simulation equivalence, not
a formal proof. The reference files in work/style_before are never overwritten.
"""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
from rtl_style import public_ports

root = Path(__file__).resolve().parents[1]
work = root / 'work'
reference = work / 'style_before'
build = work / 'style_equivalence'
build.mkdir(exist_ok=True)
originals = sorted(reference.glob('*.v'))
assert len(originals) == 13, 'Expected all 13 pre-style RTL snapshots'
iverilog = shutil.which('iverilog')
if not iverilog:
    iverilog = str(next((work / 'tools/iverilog').rglob('iverilog.exe')))
vvp = str(Path(iverilog).with_name('vvp.exe' if iverilog.endswith('.exe') else 'vvp'))
manifest = []
for path in originals:
    s = path.read_text()
    # Prefix module types only; retain original ports and private state.
    s = re.sub(r'\brv32_ifu_\w+\b', lambda m: 'before_' + m[0], s)
    (build / path.name).write_text(s)
    manifest.append({'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})

results = []
for test, source in [('tb_bp', work / 'tb_bp.sv'), ('tb_decode', root / 'tb/tb_decode.sv')]:
    s = source.read_text()
    if test == 'tb_bp':
        s = s.replace('`include "tb_bp_body.svh"', (root / 'tb/tb_bp_body.svh').read_text())
    declarations, compares = [], []
    instances = list(re.finditer(r'\b(rv32_ifu_\w+)\s+(\w+)\s*\((.*?)\);', s, re.S))
    for instance in instances:
        mod, name, bindings = instance.groups()
        ports = public_ports((root / 'rtl' / (mod + '.v')).read_text())
        connections = dict(re.findall(r'\.(\w+)\s*\(\s*(\w+)\s*\)', bindings))
        assert len(connections) == len(ports), 'Only simple signal bindings are supported'
        old_connections = []
        for direction, width, port in ports:
            signal = connections[port]
            if direction == 'output':
                refsignal = 'before_' + name + '_' + port
                declarations.append(f'wire {width} {refsignal};')
                compares.append(f'style_checks = style_checks + 1; '
                                f'if ({signal} !== {refsignal}) '
                                f'$fatal(1, "style mismatch: {mod}.{port} time=%0t", $time);')
                signal = refsignal
            old_connections.append(f'.{port}({signal})')
        declarations.append(f'before_{mod} before_{name}(' + ','.join(old_connections) + ');')
    declarations += ['integer style_checks = 0;', 'task compare_style; begin',
                     *compares, 'end endtask']
    if test == 'tb_bp':
        # Sample once before and once after active clock edges, after settling.
        declarations += ['always @(negedge forever_cpuclk) begin #1; compare_style(); end']
        s = s.replace('@(posedge forever_cpuclk); #1;',
                      '@(posedge forever_cpuclk); #1; compare_style();')
    else:
        s = s.replace('begin checks=checks+1;', 'begin compare_style(); checks=checks+1;')
    s = s.replace('$finish;', '$display("PASS style equivalence: %0d output comparisons", '
                             'style_checks); $finish;')
    s = s.replace('endmodule', '\n'.join(declarations) + '\nendmodule')
    bench = build / (test + '.sv')
    bench.write_text(s)
    binary = build / (test + '.vvp')
    cmd = [iverilog, '-g2012', '-s', test, '-f', 'rtl/files.f', '-o', str(binary), str(bench)]
    cmd += [str(build / p.name) for p in originals]
    compile_result = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=60)
    (build / (test + '_compile.log')).write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        raise SystemExit(compile_result.stdout + compile_result.stderr)
    sim = subprocess.run([vvp, str(binary)], capture_output=True, text=True, timeout=90)
    (build / (test + '.log')).write_text(sim.stdout + sim.stderr)
    if sim.returncode:
        raise SystemExit(sim.stdout + sim.stderr)
    match = re.search(r'PASS style equivalence: (\d+) output comparisons', sim.stdout)
    assert match, sim.stdout
    print(test + ': ' + match[0])
    results.append({'test': test, 'output_comparisons': int(match[1]), 'passed': True})
(build / 'result.json').write_text(json.dumps({'reference': manifest, 'results': results}, indent=2))
