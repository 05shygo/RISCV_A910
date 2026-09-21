"""Derive the six C910 ICache files. Does not regenerate predictor RTL."""
from pathlib import Path
import difflib
import hashlib
import json
import re
from rtl_style import rewrite, layout

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT.parent / 'ifu/rtl'
manifest = []
patches = []


def fixed_config(text):
    active = [True]
    conditions = []
    result = []
    for line in text.splitlines(keepends=True):
        m = re.match(r'\s*`(ifdef|ifndef)\s+(\w+)', line)
        if m:
            condition = m[2] == 'ICACHE_64K'
            if m[1] == 'ifndef':
                condition = not condition
            conditions.append(condition)
            active.append(active[-1] and condition)
        elif re.match(r'\s*`else\b', line):
            active[-1] = active[-2] and not conditions[-1]
        elif re.match(r'\s*`endif\b', line):
            active.pop()
            conditions.pop()
        elif active[-1]:
            result.append(line)
    assert len(active) == 1
    return ''.join(result)


for suffix in ['tag_array', 'data_array0', 'data_array1',
               'predecd_array0', 'predecd_array1', 'if']:
    source = SRC / f'ct_ifu_icache_{suffix}.v'
    original = source.read_text(encoding='utf-8')
    s = fixed_config(original)
    s = re.sub(r'^\s*//[^\n]*@\d+[^\n]*\n', '\n', s, flags=re.M)
    s = re.sub(r'^\s*//\s*(?:&|csky)[^\n]*\n', '\n', s, flags=re.M)
    s = s.replace('ct_ifu_', 'rv32_ifu_').replace('gated_clk_cell', 'rv32_ifu_clk_cell')
    s = s.replace('parameter PC_WIDTH = 40;', '')
    s = re.sub(r'always\s*@\(\s*(?!posedge|negedge)[^)]*\)', 'always @(*)', s)
    s = re.sub(r'\[\s*(\d+)\s*:\s*(\d+)\s*\]', r'[\1:\2]', s)
    s = s.replace('parameter WIDTH = 13;', '')
    if suffix != 'if':
        s = s.replace('[15:0]', '[14:0]')
        s = s.replace('[WIDTH:5]', '[14:6]').replace('[WIDTH:3]', '[14:4]')
        if suffix == 'tag_array':
            s = s.replace('[58:0]', '[36:0]').replace('{29{', '{18{')
            s = s.replace('ct_spsram_512x59',
                          'rv32_ifu_spram #(.ADDR_WIDTH(9), .DATA_WIDTH(37))', 1)
        else:
            s = re.sub(r'\bct_spsram_2048x32_split(?=\s)',
                       'rv32_ifu_spram #(.ADDR_WIDTH(11), .DATA_WIDTH(32))', s)
        if suffix.startswith('predecd'):
            # Precode owns its write strobe; remove the redundant data-array input.
            way = suffix[-1]
            obsolete = f'ifu_icache_data_array{way}_wen_b'
            s = re.sub(r'^.*(?:input|wire)\s+'+obsolete+r';[^\n]*\n', '', s, flags=re.M)
            s = re.sub(r'^\s*'+obsolete+r',\s*\n', '', s, flags=re.M)
            s = s.replace(obsolete, f'ifu_icache_predecd_array{way}_wen_b')
    else:
        # External indices are all complete physical BYTE addresses.
        for name in ['ifctrl_icache_if_index', 'ifctrl_icache_if_read_req_index',
                     'l1_refill_icache_if_index', 'ipb_icache_if_index',
                     'pcgen_icache_if_index']:
            s = re.sub(r'\[\d+:0\](\s+'+name+r'\s*;)', r'[31:0]\1', s)
        s = s.replace('[15:0]', '[14:0]')
        s = s.replace('{ipb_icache_if_index[10:0],5\'b0}', 'ipb_icache_if_index[14:0]')
        for old, new in [('[58:0]', '[36:0]'), ('[57:29]', '[35:18]'),
                         ('[57:29]', '[35:18]'), ('[28:0]', '[17:0]'),
                         ('[27:0]', '[16:0]'), ('[58]', '[36]'), ("28'b0", "17'b0")]:
            s = s.replace(old, new)
        s = s.replace("{16{1'bx}}", "15'b0")
        # Explicit successful whole-line publication qualifier, not BIU RLAST.
        s = s.replace('module rv32_ifu_icache_if(',
                      'module rv32_ifu_icache_if(\n  l1_refill_icache_if_install,')
        pos = s.index('input ')
        s = s[:pos] + 'input l1_refill_icache_if_install;\n' + s[pos:]
        s = s.replace('else if(l1_refill_icache_if_wr && l1_refill_icache_if_last)',
                      'else if(l1_refill_icache_if_wr && l1_refill_icache_if_last && l1_refill_icache_if_install)')
        s = s.replace('assign tag_valid_din    = l1_refill_icache_if_last;',
                      'assign tag_valid_din = !ifctrl_icache_if_inv_on && l1_refill_icache_if_last && l1_refill_icache_if_install;')
        # A software Data/Precode read acquires both arrays of its selected way.
        for way in (0, 1):
            marker = f'assign ifu_icache_predecd_array{way}_cen_b'
            start = s.index(marker)
            end = s.index(';', start)
            s = s[:end] + f' && !ifctrl_icache_if_read_req_data{way}' + s[end:]
            start = s.index(f'assign ifu_icache_predecd_array{way}_clk_en')
            end = s.index(';', start)
            s = s[:end] + f' || ifctrl_icache_if_read_req_data{way}' + s[end:]
        # Remove predecode instances' obsolete formal ports only.
        s = re.sub(r'(rv32_ifu_icache_predecd_array[01]\s+\w+\s*\([^;]*?)'
                   r'^\s*\.ifu_icache_data_array[01]_wen_b[^\n]*\n', r'\1', s, flags=re.M)
        start = s.index('always @(posedge hpcp_clk')
        end = s.index('assign ifu_hpcp_icache_access =', start)
        s = s[:start] + '''wire access_en;
wire access_nxt;
wire miss_en;
wire miss_nxt;
assign access_en = 1'b1;
assign miss_en = 1'b1;
assign access_nxt = hpcp_ifu_cnt_en && ifu_hpcp_icache_access_pre;
assign miss_nxt = hpcp_ifu_cnt_en && cp0_ifu_icache_en && ifu_hpcp_icache_miss_pre;
always @(posedge hpcp_clk or negedge cpurst_b) begin : p_access
  if (!cpurst_b) begin
    ifu_hpcp_icache_access_reg <= 1'b0;
  end else if (access_en) begin
    ifu_hpcp_icache_access_reg <= access_nxt;
  end
end
always @(posedge hpcp_clk or negedge cpurst_b) begin : p_miss
  if (!cpurst_b) begin
    ifu_hpcp_icache_miss_reg <= 1'b0;
  end else if (miss_en) begin
    ifu_hpcp_icache_miss_reg <= miss_nxt;
  end
end
''' + s[end:]
        s = s.replace('assign hpcp_clk_en =  cp0_ifu_icache_en && hpcp_ifu_cnt_en;',
                      'assign hpcp_clk_en = (cp0_ifu_icache_en && hpcp_ifu_cnt_en) || ifu_hpcp_icache_access_reg || ifu_hpcp_icache_miss_reg;')
        s = s.replace('= ifu_hpcp_icache_access_reg;', '= hpcp_ifu_cnt_en && ifu_hpcp_icache_access_reg;')
        s = s.replace('= ifu_hpcp_icache_miss_reg;', '= hpcp_ifu_cnt_en && ifu_hpcp_icache_miss_reg;')
    # No vestigial vector/VA or inaccurate tag-width comments in the derived files.
    s = re.sub(r'^\s*//[^\n]*(?:[Vv]ector|20bit Tag|inv va/pa)[^\n]*\n', '', s, flags=re.M)
    pos = s.index('*/') + 2
    s = s[:pos] + '''

// RV32I/no-MMU derivative: 64 KiB, two ways, 64 B lines, 512 sets.
// All address inputs use byte addressing: set PA[14:6], block PA[5:4].
// Tag row = {FIFO, valid1, tag1[16:0], valid0, tag0[16:0]}.
// Core request strobes MUST be mutually exclusive; use rv32_ifu_icache_top.
''' + s[pos:]
    s, names = rewrite(s)
    # Style helper defaults to predictor prose; these are cache interfaces.
    s = s.replace('Predictor and pipeline interface', 'Cache array and pipeline interface')
    if suffix == 'if':
        # Keep the derived license/public interface; generate repeated circuits
        # from the reviewed TT-style body instead of restoring unrolled logic.
        for kind in ('data_array', 'predecd_array'):
            way0 = (ROOT/'rtl'/f'rv32_ifu_icache_{kind}0.v').read_text()
            way1 = (ROOT/'rtl'/f'rv32_ifu_icache_{kind}1.v').read_text()
            assert way0 == way1.replace(kind+'1', kind+'0'), 'Way wrappers have diverged'
        header = s[:s.index(');', s.index('module rv32_ifu_icache_if'))+2]
        body = (ROOT/'scripts/templates/icache_if_body.vh').read_text()
        s = layout(header+'\n\n'+body)
        names = {'icache_index_higher': 'icache_index_higher',
                 'ifu_hpcp_icache_access_reg': 'event_q[0]',
                 'ifu_hpcp_icache_miss_reg': 'event_q[1]',
                 'x_rv32_ifu_icache_data_array0': 'g_way[0].u_data_array',
                 'x_rv32_ifu_icache_data_array1': 'g_way[1].u_data_array',
                 'x_rv32_ifu_icache_predecd_array0': 'g_way[0].u_precode_array',
                 'x_rv32_ifu_icache_predecd_array1': 'g_way[1].u_precode_array'}
    name = f'rv32_ifu_icache_{suffix}.v'
    (ROOT/'rtl'/name).write_text(s, encoding='utf-8')
    manifest.append({'source': str(source.relative_to(ROOT.parent)),
                     'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                     'output': 'rtl/'+name, 'private_names': names})
    patches.extend(difflib.unified_diff(original.splitlines(True), s.splitlines(True),
                   fromfile='ifu/rtl/'+source.name, tofile='ifu_rv32i/rtl/'+name))

(ROOT/'doc/icache_source_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
(ROOT/'doc/icache_C910_delta.patch').write_text(''.join(patches), encoding='utf-8')
print('Derived 6 ICache modules; predictor sources unchanged.')
