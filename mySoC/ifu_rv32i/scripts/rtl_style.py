"""Apply the project's cci500_sf.v-inspired Verilog-2001 source conventions.

Syntax-aware declaration conversion and private-name changes precede Verible
layout. Public port names and expressions are preserved. No ARM code is copied.
"""
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess
from pyslang import syntax

ROOT = Path(__file__).resolve().parents[1]
MARKER = '// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)'
SEPARATOR = '//------------------------------------------------------------------------------'


def clean(s):
    return re.sub(r'//[^\n]*|/\*.*?\*/', '', str(s), flags=re.S).strip()


def module(tree):
    if type(tree.root).__name__ == 'ModuleDeclarationSyntax':
        return tree.root
    return next(x for x in tree.root.members if type(x).__name__ == 'ModuleDeclarationSyntax')


def public_ports(s):
    tree = syntax.SyntaxTree.fromText(s)
    m = module(tree)
    if type(m.header.ports).__name__ == 'NonAnsiPortListSyntax':
        parts = [str(x) for x in m.members if type(x).__name__ == 'PortDeclarationSyntax']
    else:
        parts = [str(m.header.ports)]
    return [(d, w or '', n) for d, _, w, n in re.findall(
        r'\b(input|output|inout)\s+(?:(wire|reg)\s+)?(\[[^\]]+\])?\s*(\w+)', clean('\n'.join(parts)))]


def formatter_path():
    exe = os.environ.get('VERIBLE_FORMAT') or shutil.which('verible-verilog-format')
    if not exe:
        candidates = list((ROOT/'work/tools/verible').rglob('verible-verilog-format.exe'))
        exe = str(candidates[0]) if candidates else None
    if not exe:
        raise RuntimeError('Set VERIBLE_FORMAT to verible-verilog-format (see doc/coding_style_zh.md)')
    return exe


def layout(s):
    cmd = [formatter_path(), '--indentation_spaces=2', '--wrap_spaces=2',
           '--column_limit=100', '--port_declarations_alignment=align',
           '--module_net_variable_alignment=align', '--named_parameter_alignment=align',
           '--named_port_alignment=align', '--assignment_statement_alignment=align',
           '--try_wrap_long_lines=true', '-']
    s = re.sub(r'\n(?:[ \t]*\n)+(?=[ \t]*end\b)', '\n', s)
    s = re.sub(r'\n(?:[ \t]*\n){2,}', '\n\n', s)
    r = subprocess.run(cmd, input=s, text=True, capture_output=True, timeout=45)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout


def substitute(s, names):
    # Never alter comments, string literals, or named formal port connections.
    return re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\b[A-Za-z_]\w*\b',
                  lambda m: names.get(m[0], m[0]) if not m[0].startswith(('/', '"'))
                  and (m.start()==0 or s[m.start()-1]!='.') else m[0], s, flags=re.S)


def section(title):
    return '\n' + SEPARATOR + '\n// ' + title + '\n' + SEPARATOR + '\n'


def explicit_blocks(s):
    """Use begin/end for conditional and loop bodies, preserving else-if chains."""
    tree = syntax.SyntaxTree.fromText(s)
    inserts = {}
    def wrap(stmt):
        if type(stmt).__name__ == 'BlockStatementSyntax':
            return
        start, end = stmt.sourceRange.start.offset, stmt.sourceRange.end.offset
        inserts[start] = inserts.get(start, '') + 'begin\n'
        inserts[end] = '\nend\n' + inserts.get(end, '')
    def visit(node):
        if type(node).__name__ == 'ConditionalStatementSyntax':
            wrap(node.statement)
            if node.elseClause is not None:
                clause = node.elseClause.clause
                if type(clause).__name__ != 'ConditionalStatementSyntax':
                    wrap(clause)
        elif type(node).__name__ in ('ForLoopStatementSyntax', 'WhileLoopStatementSyntax',
                                    'RepeatLoopStatementSyntax'):
            wrap(node.statement)
    tree.root.visit(visit)
    for offset, text in sorted(inserts.items(), reverse=True):
        s = s[:offset] + text + s[offset:]
    return s


def rewrite(s):
    if MARKER in s:
        return layout(s), {}
    # Remove leftover Connect/Force generator scaffolding, retain real comments.
    s = re.sub(r'^\s*//[^\n]*@\d+[^\n]*\n', '\n', s, flags=re.M)
    s = re.sub(r'^\s*//[^\n]*&(?:Force|Module|Ports|Regs|Wires|Depend)[^\n]*\n', '\n', s, flags=re.M)
    tree = syntax.SyntaxTree.fromText(s)
    m = module(tree)
    ports = public_ports(s)
    port_names = {n for _, _, n in ports}
    raw = clean(s)
    sequential = set()
    def collect_state(node):
        if node.kind == syntax.SyntaxKind.NonblockingAssignmentExpression:
            sequential.update(re.findall(r'\b[A-Za-z_]\w*\b',
                              re.sub(r'\[[^\]]*\]', '', clean(node.left))))
    m.visit(collect_state)
    assert not sequential & {n for d, _, n in ports if d == 'input'}
    combinational = set()
    declarations = {}
    params, functions, behavior, genvars = [], [], [], []
    initialized = []
    for member in m.members:
        typ = type(member).__name__
        if typ == 'PortDeclarationSyntax':
            continue
        if typ in ('DataDeclarationSyntax', 'NetDeclarationSyntax'):
            data_type = re.sub(r'\s*:\s*', ':', clean(member.type))
            if typ=='NetDeclarationSyntax': data_type = clean(member.netType)+' '+data_type
            for decl in member.declarators:
                if not hasattr(decl, 'name'): continue
                name = clean(decl.name)
                dimensions = ''.join(clean(x) for x in decl.dimensions)
                if name in port_names:
                    if data_type.startswith('reg') and name not in sequential:
                        combinational.add(name)
                    continue
                declarations[name] = (data_type, dimensions)
                if decl.initializer is not None:
                    assert data_type.startswith('wire'), ('unexpected register initialization', name)
                    initialized.append('assign '+name+' '+clean(decl.initializer)+';')
        elif typ == 'ParameterDeclarationStatementSyntax':
            params.append(str(member))
        elif typ == 'GenvarDeclarationSyntax':
            genvars.append(str(member))
        elif typ == 'FunctionDeclarationSyntax':
            functions.append(str(member))
        else:
            behavior.append(str(member))
    # ANSI output reg declarations are not module members.
    for name in port_names:
        if name not in sequential and re.search(r'\b'+re.escape(name)+r'\s*(?:\[[^\]]+\]\s*)*=(?!=)',raw):
            if re.search(r'\boutput\s+reg\s+(?:\[[^\]]+\]\s*)?'+name+r'\b',raw):
                combinational.add(name)
    names = {}
    for name in sorted(sequential):
        if name not in declarations and name not in port_names:
            continue
        base = re.sub(r'_(?:reg|flop|q)$', '', name)
        names[name] = base.lower()+'_q'
    for name in declarations:
        if name not in names and name.endswith('_pre'):
            names[name] = name[:-4]+'_nxt'
    for name in sorted(combinational):
        names[name] = name+'_int'
    assert len(set(names.values())) == len(names), ('name collision', names)
    assert not (set(names.values())-set(names)) & set(declarations), 'new name collides with original'
    # Uniform instance and generate block names. These are private hierarchy.
    for member_type, instance in re.findall(r'\b(rv32_ifu_\w+)\s+(?:#\s*\([^;]+?\)\s*)?(\w+)\s*\(',raw):
        if instance.startswith('u_'): continue
        stem = re.sub(r'^x_(?:rv32_ifu_)?','',instance)
        names[instance] = 'u_'+stem
    names.update({name:'g_'+name for name in re.findall(r'\bbegin\s*:\s*(\w+)',raw)
                  if name not in names and not name.startswith(('g_', 'p_'))})
    for direction, width, name in ports:
        if name in sequential or name in combinational:
            declarations[name] = ('reg '+width, '')
    newdecl = []
    for name, (dt, dim) in declarations.items():
        newdecl.append(substitute(dt+' '+name+dim+';',names))
    header = s[:s.index('module ')].strip()+'\n\n'
    header += SEPARATOR+'\n// Verilog-2001 (IEEE Std 1364-2001)\n'+MARKER+'\n'+SEPARATOR+'\n'
    header += section('Module Declaration')
    header += 'module '+clean(m.header.name)
    if m.header.parameters is not None: header += ' '+clean(m.header.parameters)
    header += ' (\n'
    # Keep public names/ordering so the existing spreadsheet contract survives.
    group = None
    for index, (direction, width, name) in enumerate(ports):
        current = ('Clock, reset and configuration' if name.startswith(('cp0_', 'cpurst', 'forever_', 'pad_'))
                   else 'Retirement interface' if name.startswith('rtu_')
                   else 'Execution check and recovery' if name.startswith('iu_')
                   else 'Predictor and pipeline interface')
        if current != group:
            header+='\n  // '+current+'\n'
            group=current
        width=re.sub(r'\s+','',width)
        header += f'  {direction} wire {width} {name}'+(',' if index+1<len(ports) else '')+'\n'
    header += ');\n'
    out = header
    if params: out += section('Localparams')+'\n'.join(params)+'\n'
    out += section('Net declarations')+'\n'.join(genvars+newdecl)+'\n'
    if functions: out += section('Functions')+'\n'.join(substitute(x,names) for x in functions)+'\n'
    out += section('Combinational logic and register updates')
    out += '\n'.join(substitute(x,names) for x in initialized)+'\n'
    out += '\n'.join(substitute(x,names) for x in behavior)+'\n'
    if sequential & port_names or combinational:
        out += section('Output assignments')
        out += '\n'.join('assign '+n+' = '+names[n]+';' for _,_,n in ports if n in names)+'\n'
    out += 'endmodule\n'
    # Give every process an explicit p_ name, including in generate regions.
    t2=syntax.SyntaxTree.fromText(out)
    blocks=[]
    def collect(node):
        if type(node).__name__=='ProceduralBlockSyntax': blocks.append(node)
    t2.root.visit(collect)
    edits=[]
    used=set()
    for block in blocks:
        timing=block.statement
        assert type(timing).__name__=='TimingControlStatementSyntax'
        stmt=timing.statement
        if hasattr(stmt,'blockName') and stmt.blockName is not None: continue
        text=clean(stmt)
        found=re.search(r'\b(\w+)\s*(?:\[[^\]]+\]\s*)*(?:<=|=(?!=))',text)
        stem=found[1] if found else 'logic'
        stem=re.sub(r'_(q|nxt|int)$','',stem)
        label='p_'+stem+('_comb' if '*' in clean(timing.timingControl) else '')
        if label in used: label+='_'+str(len(used))
        used.add(label)
        if hasattr(stmt,'items'):
            body='\n'.join(str(x).strip() for x in stmt.items)
        else: body=str(stmt)
        replacement='always '+clean(timing.timingControl)+' begin : '+label+'\n'+body+'\nend'
        edits.append((block.sourceRange.start.offset,block.sourceRange.end.offset,replacement))
    for start,end,text in sorted(edits,reverse=True): out=out[:start]+text+out[end:]
    return layout(explicit_blocks(out)), names


def remember(module_name, names):
    file=ROOT/'doc/style_names.json'
    data=json.loads(file.read_text()) if file.exists() else {}
    if names: data[module_name]=names
    file.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    for path in sorted((ROOT/'rtl').glob('*.v')):
        original=path.read_text()
        text,names=rewrite(original)
        if args.check:
            if MARKER not in original: raise SystemExit('Style not applied: '+str(path))
            if layout(original)!=original: raise SystemExit('Layout drift: '+str(path))
        else:
            path.write_text(text)
            remember(path.stem,names)
    print('CCI500-style RTL '+('check passed' if args.check else 'applied'))
