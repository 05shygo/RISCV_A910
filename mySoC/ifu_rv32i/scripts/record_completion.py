"""Record incremental provenance without overwriting earlier delivery audits."""
from pathlib import Path
import difflib,hashlib,json
ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def key(path):return path.relative_to(ROOT).as_posix()
snapshot=ROOT/'work/completion_before'
before=json.loads((snapshot/'manifest.json').read_text())
for f,h in before.items():assert sha(snapshot/f)==h,('modified snapshot',f)
# The preceding IF delivery already recorded these original inputs.
historical=json.loads((ROOT/'doc/if_stage_source_manifest.json').read_text())
for item in historical['sources']:
    assert sha(ROOT/item['path'])==item['sha256'],('upstream input changed',item['path'])
sources={}
for p in sorted((ROOT.parent/'ifu/rtl').glob('ct_ifu_*.v')):
    sources['../ifu/rtl/'+p.name]=sha(p)
for n in ['RV32I_C910_IFU_microarchitecture_spec_zh.md','RV32I_C910_IFU_interface_v1.1_noMMU.xlsx']:
    sources['../ifu/doc/'+n]=sha(ROOT.parent/'ifu/doc'/n)
style=Path('D:/Project/bus/yh_xbar550-main/yh_xbar550-main/cci550/cci550_tablet/verilog/cci500_tt.v')
sources[style.as_posix()]=sha(style)
new=set()
for group in ['pipeline','memory','support']:
    new.update((ROOT/f'rtl/{group}_files.f').read_text().splitlines())
new-={'rtl/rv32_ifu_bp_decode.v','rtl/rv32_ifu_icache_precode.v'}
new.add('rtl/rv32_ifu_top.v')
new.update('rtl/'+n+'_files.f' for n in ['pipeline','memory','support','ifu'])
new.update('scripts/'+n+'.py' for n in ['build_pipeline','build_memory','build_support','build_top',
    'check_pipeline','check_memory','check_support','check_ifu','check_completion','record_completion'])
new.update('tb/tb_'+n+'_body.svh' for n in ['pipeline','memory','ifu','sfp'])
new.add('doc/pipeline_zh.md')
modified={f:{'before_sha256':h,'sha256':sha(ROOT/f),'snapshot':'work/completion_before/'+f}
          for f,h in before.items() if sha(ROOT/f)!=h}
patch=[]
for f in sorted(modified):
    patch.extend(difflib.unified_diff((snapshot/f).read_text().splitlines(True),
        (ROOT/f).read_text().splitlines(True),fromfile='before/'+f,tofile='after/'+f))
for f in sorted(new):
    patch.extend(difflib.unified_diff([], (ROOT/f).read_text(encoding='utf-8').splitlines(True),
        fromfile='/dev/null',tofile='after/'+f))
(ROOT/'doc/completion_delta.patch').write_text(''.join(patch),encoding='utf-8')
products=[]
for directory,pattern in [('rtl','*.v'),('rtl','*.f'),('scripts','*.py'),('tb','*.sv'),('tb','*.svh')]:
    products.extend((ROOT/directory).glob(pattern))
products.extend(ROOT/f for f in ['README_zh.md','doc/pipeline_zh.md','doc/if_stage_zh.md',
    'doc/integration_zh.md','doc/coding_style_zh.md','doc/verification_zh.md','doc/ports.json'])
results={}
for n in ['pipeline','memory','support','ifu','completion','if_stage']:
    p=ROOT/f'work/{n}/result.json';results[key(p)]={'sha256':sha(p),'result':json.loads(p.read_text())}
for n in ['check_result','test_result']:
    p=ROOT/f'work/{n}.json';results[key(p)]={'sha256':sha(p),'result':json.loads(p.read_text())}
manifest={'date':'2026-09-21','scope':'RV32I no-MMU IFU integration initial RTL',
    'method':'New word-stage adaptations follow C910 duties; not claimed cycle-equivalent deletion.',
    'sources':sources,'historical_inputs_verified':True,'new_products':sorted(new),
    'modified_snapshotted_products':modified,'before_manifest_sha256':sha(snapshot/'manifest.json'),
    'current_products':{key(p):sha(p) for p in sorted(set(products))},
    'delta_sha256':sha(ROOT/'doc/completion_delta.patch'),'validation':results,
    'limitations':['No ROB-driven CPU commit differential or signoff synthesis/STA',
       'Cross-line target Way uses conservative dual read',
       'SFP/LBUF are documented RV32 adaptations, not original cycle equivalence',
       'Older delivery manifests remain historical; this manifest records the current integration']}
(ROOT/'doc/completion_manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
print('Recorded',len(sources),'inputs,',len(products),'products,',len(new),'new files,',len(modified),'snapshot deltas')
