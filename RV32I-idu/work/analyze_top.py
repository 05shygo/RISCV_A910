#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Analyze ct_idu_top.sv: cross-check instance connections against sub-module port declarations."""
import re, io, os, json, sys

D = r'C:\Users\LIUCONG\Desktop\idu'
TOP = os.path.join(D, 'ct_idu_top.sv')

# --------------------------------------------------------------------------
# 1. Parse sub-module port declarations (robust to semicolons inside lists)
# --------------------------------------------------------------------------
def parse_module_ports(fpath):
    content = io.open(fpath, encoding='utf-8').read()
    m = re.search(r'module\s+(\w+)\s*(?:#\s*\([^)]*\))?\s*\(', content)
    if not m:
        return None, {}
    modname = m.group(1)
    # find matching close paren-semicolon
    start = m.end()
    depth = 0
    i = start
    while i < len(content):
        c = content[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth < 0:
                break
        i += 1
    header = content[start:i]
    # strip comments
    header = re.sub(r'//[^\n]*', '', header)
    header = re.sub(r'/\*.*?\*/', '', header, flags=re.S)
    # split entries on commas/semicolons
    entries = re.split(r'[,;]', header)
    ports = {}  # name -> (dir, width)
    for e in entries:
        e = e.strip()
        if not e:
            continue
        dm = re.match(r'^(input|output|inout)\s+', e)
        if not dm:
            continue
        d = dm.group(1)
        rest = e[dm.end():].strip()
        # optional signed / logic / wire / reg keywords
        rest = re.sub(r'^(signed\s+|logic\s+|wire\s+|reg\s+)', '', rest)
        wm = re.match(r'\[([^\]]*)\]\s*', rest)
        width = None
        if wm:
            width = wm.group(1).replace(' ', '')
            rest = rest[wm.end():].strip()
        else:
            # implicit 1-bit
            width = '1'
        nm = re.match(r'([A-Za-z_]\w*)', rest)
        if nm:
            name = nm.group(1)
            ports[name] = (d, width)
    return modname, ports

# --------------------------------------------------------------------------
# 2. Parse top module instances
# --------------------------------------------------------------------------
def parse_top_instances(fpath):
    content = io.open(fpath, encoding='utf-8').read()
    # find all instantiations: module_name inst_name ( ... );
    insts = []
    for m in re.finditer(r'(\bct_idu_\w+)\s+(x?_?\w*)\s*\(', content):
        mod = m.group(1)
        inst = m.group(2)
        start = m.end()
        # find matching close paren
        depth = 0
        i = start
        while i < len(content):
            c = content[i]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth < 0:
                    break
            i += 1
        body = content[start:i]
        # extract .port (net)  with optional //in //out comment
        conns = []
        for pm in re.finditer(r'\.(\w+)\s*\(\s*(\w*)\s*\)\s*,?\s*(//\s*(in|out))?', body):
            pname = pm.group(1)
            net = pm.group(2)
            cmt = pm.group(4)
            conns.append({'port': pname, 'net': net, 'comment': cmt})
        insts.append({'module': mod, 'instance': inst, 'conns': conns})
    return insts, content

insts, top_content = parse_top_instances(TOP)
print('=== Instances found in top ===')
for it in insts:
    print(f"  {it['module']} {it['instance']}  ({len(it['conns'])} conns)")

# --------------------------------------------------------------------------
# 3. Build module port database
# --------------------------------------------------------------------------
moddb = {}
for f in os.listdir(D):
    if f.endswith('.sv'):
        modname, ports = parse_module_ports(os.path.join(D, f))
        if modname and ports:
            moddb[modname] = ports

print('\n=== Module port DB (from files) ===')
for mn, ports in moddb.items():
    print(f"  {mn}: {len(ports)} ports")

# --------------------------------------------------------------------------
# 4. Cross-check each instance connection against module ports
# --------------------------------------------------------------------------
print('\n=== Connections to NON-EXISTENT module ports (compile errors) ===')
bogus = []
for it in insts:
    mod = it['module']
    ports = moddb.get(mod, {})
    if not ports:
        print(f"  !! module not found in files: {mod}")
        continue
    for c in it['conns']:
        if c['port'] not in ports:
            bogus.append((mod, it['instance'], c['port'], c['net']))
            print(f"  {mod} .{c['port']} ({c['net']})  <-- NOT A PORT of {mod}")

print('\n=== Module input ports LEFT UNCONNECTED in top ===')
for it in insts:
    mod = it['module']
    ports = moddb.get(mod, {})
    if not ports:
        continue
    connected = {c['port'] for c in it['conns']}
    for pname, (d, w) in ports.items():
        if d == 'input' and pname not in connected:
            print(f"  {it['instance']} ({mod}) input .{pname} unconnected")

# --------------------------------------------------------------------------
# 5. Build net database: driver / consumer / width candidates / comments
# --------------------------------------------------------------------------
nets = {}  # net -> {'drivers': [(mod,port,w)], 'consumers': [(mod,port,w)], 'comments': set}
for it in insts:
    mod = it['module']
    ports = moddb.get(mod, {})
    if not ports:
        continue
    for c in it['conns']:
        net = c['net']
        if not net:
            continue
        if net not in nets:
            nets[net] = {'drivers': [], 'consumers': [], 'comments': set()}
        pinfo = ports.get(c['port'])
        if pinfo is None:
            continue
        d, w = pinfo
        rec = (mod, c['port'], w)
        if d == 'output' or d == 'inout':
            nets[net]['drivers'].append(rec)
        else:
            nets[net]['consumers'].append(rec)
        if c['comment']:
            nets[net]['comments'].add(c['comment'])

# --------------------------------------------------------------------------
# 6. Classify nets
# --------------------------------------------------------------------------
print('\n=== NET CLASSIFICATION ===')
rows = []
for net, info in sorted(nets.items()):
    drivers = info['drivers']
    consumers = info['consumers']
    comments = info['comments']
    # width: prefer driver; if multiple widths -> max literal parse
    widths = [w for (_, _, w) in drivers]
    if not widths:
        widths = [w for (_, _, w) in consumers]
    def wnum(w):
        m = re.match(r'(\d+)\s*:\s*(\d+)', w)
        if m:
            return max(int(m.group(1)), int(m.group(2)))
        return 0
    maxw = max(wnum(x) for x in widths) if widths else None
    # classify
    if 'out' in comments:
        cls = 'TOP_OUTPUT'
    elif 'in' in comments and not drivers:
        cls = 'TOP_INPUT'
    elif 'in' in comments and drivers:
        cls = 'INTERNAL (commented //in but has internal driver!)'
    elif not drivers and consumers:
        cls = 'TOP_INPUT (unmarked, no internal driver)'
    elif drivers:
        cls = 'INTERNAL'
    else:
        cls = '??'
    rows.append((net, cls, maxw, len(drivers), len(consumers), sorted(comments), [x[:2] for x in drivers], [x[:2] for x in consumers]))

for net, cls, maxw, nd, nc, cmts, drv, csm in rows:
    print(f"  {net:45s} {cls:50s} w={maxw}  drv={nd} cons={nc} {drv} {csm}")

# --------------------------------------------------------------------------
# 7. Dump JSON for the generator step
# --------------------------------------------------------------------------
out = {
    'bogus': bogus,
    'nets': {net: {'class': cls, 'width': maxw, 'comments': cmts,
                   'drivers': [list(x) for x in drv], 'consumers': [list(x) for x in csm]}
             for net, cls, maxw, nd, nc, cmts, drv, csm in rows},
}
with io.open(os.path.join(D, 'work', 'top_analysis.json'), 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print('\nJSON written.')
