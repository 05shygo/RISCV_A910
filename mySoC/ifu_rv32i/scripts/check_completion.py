"""Strict new-RTL register grammar and deterministic regeneration audit."""
from pathlib import Path
import hashlib,json,re,subprocess,sys
from pyslang import syntax
from rtl_style import layout
ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'work/completion';WORK.mkdir(parents=True,exist_ok=True)
files=set()
for name in ['pipeline','memory','support']:
    files.update((ROOT/f'rtl/{name}_files.f').read_text().splitlines())
files-={'rtl/rv32_ifu_bp_decode.v','rtl/rv32_ifu_icache_precode.v'}
files.add('rtl/rv32_ifu_top.v')
register_blocks=0
for f in sorted(files):
    s=(ROOT/f).read_text();assert layout(s)==s,f
    blocks=[]
    syntax.SyntaxTree.fromText(s).root.visit(lambda n:blocks.append(str(n))
        if type(n).__name__=='ProceduralBlockSyntax' else None)
    for b in blocks:
        assert 'posedge forever_cpuclk or negedge cpurst_b' in b,(f,b)
        assert len(re.findall(r'\bif\s*\(',b))==2,(f,b)
        assert len(re.findall('<=',b))==2,(f,b)
        assert re.search(r'<=\s*\w+_nxt(?:\[\w+\])?;',b),(f,b)
    register_blocks+=len(blocks)
tracked=sorted((ROOT/'rtl').glob('*.v'))+sorted((ROOT/'rtl').glob('*.f'))+[ROOT/'doc/ports.json']
def hashes():return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
before=hashes()
generators=['build_cluster','build_ifdp','build_pipeline','build_support','build_top']
logs=[]
for g in generators:
    p=subprocess.run([sys.executable,str(ROOT/f'scripts/{g}.py')],cwd=ROOT,
        capture_output=True,text=True,timeout=90)
    logs.append(g+'\n'+p.stdout+p.stderr);assert p.returncode==0,logs[-1]
after=hashes();assert before==after,{p:(before[p],after[p]) for p in before if before[p]!=after[p]}
(WORK/'regeneration.log').write_text('\n'.join(logs),encoding='utf-8')
result={'new_modules_strict_style':len(files),'register_templates_checked':register_blocks,
        'generators':generators,'reproducible':True,'tracked_products':len(tracked)}
(WORK/'result.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result))
