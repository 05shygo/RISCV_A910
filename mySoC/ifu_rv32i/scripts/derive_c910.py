"""Reproduce the narrowly edited C910 predictor cores; run from any directory.

Only files listed in OUTPUTS are regenerated. Handwritten RV32 modules are separate.
"""
from pathlib import Path
import hashlib
import json
import re
import difflib
from rtl_style import rewrite, remember

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT.parent / 'ifu' / 'rtl'
RTL = ROOT / 'rtl'
RTL.mkdir(parents=True, exist_ok=True)
manifest = []
patches = []
(ROOT / 'doc').mkdir(exist_ok=True)


def read(name):
    p = SRC / (name + '.v')
    raw = p.read_text(encoding='utf-8')
    manifest.append({'source': str(p.relative_to(ROOT.parent)),
                     'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
    # Keep the original license and useful prose; remove generator directives.
    s = re.sub(r'^\s*//\s*&[^\n]*\n', '', raw, flags=re.M)
    s = re.sub(r'ct_ifu_', 'rv32_ifu_', s)
    s = s.replace('gated_clk_cell', 'rv32_ifu_clk_cell')
    # Auto sensitivity is important after adding recovery inputs.
    s = re.sub(r'always\s*@\(\s*(?!posedge|negedge)([^)]*)\)',
               'always @(*)', s)
    return s


def save(name, s, note):
    pos = s.index('*/') + 2
    s = s[:pos] + '\n\n// RV32I port, 2026-09-20: ' + note + '\n' + s[pos:]
    s, names = rewrite(s)
    remember(name, names)
    (RTL / (name + '.v')).write_text(s, encoding='utf-8')
    record = manifest[-1]
    record['output'] = 'rtl/' + name + '.v'
    record['modification'] = note
    original = (ROOT.parent / record['source']).read_text(encoding='utf-8')
    patches.extend(difflib.unified_diff(original.splitlines(keepends=True),
                    s.splitlines(keepends=True), fromfile=record['source'],
                    tofile='ifu_rv32i/'+record['output']))


# Bi-Mode tables, ahead-read pipeline, 4-entry queue and LBUF connections retained.
s = read('ct_ifu_bht')
s = s.replace('parameter PC_WIDTH = 40;', 'localparam PC_WIDTH = 32;')
s = s.replace('[38:0]', '[30:0]')
s = re.sub(r'^.*(?:input|wire)\s+ipdp_bht_h0_con_br;.*\n', '', s, flags=re.M)
s = re.sub(r'^\s*ipdp_bht_h0_con_br,\s*\n', '', s, flags=re.M)
s = s.replace('ipctrl_bht_more_br || ipdp_bht_h0_con_br', 'ipctrl_bht_more_br')
s = s.replace('module rv32_ifu_bht(', '''module rv32_ifu_bht(
  local_recover_vld,
  local_recover_ghr,
  bht_train_drop,
  bht_train_drop_count,''')
pos = s.index('// &Ports;') if '// &Ports;' in s else s.index('input ')
s = s[:pos] + '''// Internal PC inputs use P = byte_PC[31:1]; P[0] is zero for RV32I.
input local_recover_vld;
input [21:0] local_recover_ghr; // retained prefix AFTER the local correction
output bht_train_drop;
output reg [31:0] bht_train_drop_count;
wire [21:0] committed_recover_ghr;
''' + s[pos:]
# P15: all flush read offsets and history snapshots use the same retirement boundary.
s = s.replace('= rtughr_reg[21:0];', '= committed_recover_ghr[21:0];')
s = s.replace('= rtughr_reg[3:0];', '= committed_recover_ghr[3:0];')
s = s.replace('{rtughr_reg[13:10],{rtughr_reg[9:4]^rtughr_reg[21:16]}}',
              '{committed_recover_ghr[13:10],{committed_recover_ghr[9:4]^committed_recover_ghr[21:16]}}')
# Do not replace the committed-history combinational default with its own output.
s = s.replace('rtughr_pre[21:0] =  committed_recover_ghr[21:0];',
              'rtughr_pre[21:0] =  rtughr_reg[21:0];')
s = s.replace('else if(ghr_updt_vld && iu_ifu_bht_check_vld)',
              'else if(local_recover_vld && !ghr_updt_vld)\n    vghr_reg[21:0] <= local_recover_ghr;\n  else if(ghr_updt_vld && iu_ifu_bht_check_vld)', 1)
# Combinational snapshot and ahead-read indices must also be repaired, not just VGHR.
s = s.replace('else if(ghr_updt_vld && iu_ifu_bht_check_vld)\n  vghr_value',
              'else if(local_recover_vld && !ghr_updt_vld)\n  vghr_value[21:0] = local_recover_ghr;\nelse if(ghr_updt_vld && iu_ifu_bht_check_vld)\n  vghr_value')
s = s.replace('else if(after_bju_mispred || after_rtu_ifu_flush)\n  bht_pred_array_rd_index',
              'else if(local_recover_vld)\n  bht_pred_array_rd_index[9:0] = {local_recover_ghr[13:10], local_recover_ghr[9:4]^local_recover_ghr[21:16]};\nelse if(after_bju_mispred || after_rtu_ifu_flush)\n  bht_pred_array_rd_index')
for n in (0, 1):
    start = s.index(f'if(rtu_ifu_flush)\n  pre_vghr_offset_{n}')
    end = s.index('// &CombEnd', start) if '// &CombEnd' in s[start:] else -1
    # Insert before the normal/after-recovery path, after both IU cases.
    tail = f'pre_vghr_offset_{n}[3:0] = {{bju_ghr[2:0], iu_ifu_bht_condbr_taken}};'
    s = s.replace(tail, tail + f'\nelse if(local_recover_vld)\n  pre_vghr_offset_{n}[3:0] = local_recover_ghr[3:0];')
s = s.replace('rtu_ifu_flush ||', 'rtu_ifu_flush || local_recover_vld ||')
s = s.replace('else if(rtu_ifu_flush)\n    after_rtu_ifu_flush',
              'else if(rtu_ifu_flush || local_recover_vld)\n    after_rtu_ifu_flush')
s = s.replace('assign vghr_ip_updt_vld   = ipctrl_bht_con_br_vld;',
              'assign vghr_ip_updt_vld   = cp0_ifu_bht_en && ipctrl_bht_con_br_vld;')
s = s.replace('else if(vghr_ip_updt_vld)\n', 'else if(vghr_ip_updt_vld && !lbuf_bht_active_state)\n')
s = s.replace('endmodule', '''// Dropped training is a performance event; recovery/retirement remain independent.
assign committed_recover_ghr = rtughr_updt_vld ? rtughr_pre : rtughr_reg;
assign bht_train_drop = bht_wr_buf_create_vld && buf_full && !bht_inv_on_reg;
always @(posedge forever_cpuclk or negedge cpurst_b)
  if (!cpurst_b) bht_train_drop_count <= 32'b0;
  else if (bht_inv_on_reg) bht_train_drop_count <= 32'b0;
  else if (bht_train_drop && !(&bht_train_drop_count))
    bht_train_drop_count <= bht_train_drop_count + 32'd1;
endmodule''')
save('rv32_ifu_bht', s, 'C910 Bi-Mode retained; H0 removed, P31, P15 flush, local GHR repair, drop counter.')

# RAS has no opcode/MMU logic. Keep its 12 TOP + 6 RTU organization and context tags.
s = read('ct_ifu_ras')
s = s.replace('parameter PC_WIDTH = 40;', 'localparam PC_WIDTH = 32;')
s = s.replace('[38:0]', '[31:0]').replace('PC_WIDTH-2', 'PC_WIDTH-1')
s = s.replace('{PC_WIDTH-1{', '{PC_WIDTH{')
s = s.replace('module rv32_ifu_ras(', 'module rv32_ifu_ras(\n  ras_clear,')
s = s.replace('input ', 'input ras_clear; // synchronous stack invalidation, only at serialized maintenance\ninput ', 1)
s = s.replace('if(!cpurst_b)', 'if(!cpurst_b || ras_clear)')
# Six committed backups retain a bounded suffix. Do not infer committed empty
# from the speculative overflow pointer; those states diverge on wrong paths.
s = s.replace('assign rtu_ras_empty = (rtu_ptr[4:0] == status_ptr[4:0]);',
              "assign rtu_ras_empty = (rtu_available == 3'd0);")
s = s.replace('localparam PC_WIDTH = 32;', '''localparam PC_WIDTH = 32;
reg [2:0] rtu_available;
reg [2:0] rtu_available_pre;
function [4:0] ptr_back;
  input [4:0] ptr;
  input [2:0] count;
  integer n;
  reg [4:0] p;
  begin
    p=ptr;
    for(n=0;n<6;n=n+1)
      if(n[2:0]<count) p=(p[3:0]==0) ? {~p[4],4'd11} : p-5'd1;
    ptr_back=p;
  end
endfunction
function entry_in_backup;
  input [3:0] slot;
  input [4:0] ptr;
  input [2:0] count;
  integer n;
  reg [4:0] p;
  begin
    p=ptr; entry_in_backup=0;
    for(n=0;n<6;n=n+1) begin
      p=(p[3:0]==0) ? {~p[4],4'd11} : p-5'd1;
      if(n[2:0]<count && slot==p[3:0]) entry_in_backup=1;
    end
  end
endfunction
always @(*) begin
  rtu_available_pre=rtu_available;
  if(rtu_ifu_retire0_pcall && rtu_ifu_retire0_preturn) begin
    if(rtu_available==0) rtu_available_pre=1;
  end else if(rtu_ifu_retire0_pcall) begin
    if(rtu_available<6) rtu_available_pre=rtu_available+3'd1;
  end else if(rtu_ifu_retire0_preturn && rtu_available!=0)
    rtu_available_pre=rtu_available-3'd1;
end
always @(posedge forever_cpuclk or negedge cpurst_b)
  if(!cpurst_b || ras_clear) rtu_available<=0;
  else if(cp0_ifu_ras_en) rtu_available<=rtu_available_pre;
''')
s, n = re.subn(r'(else if\(cp0_ifu_ras_en && top_entry_rtu_updt\)\s*begin).*?\n  end',
               r'\1\n    status_ptr[4:0] <= ptr_back(rtu_ptr_pre, rtu_available_pre);\n  end', s, count=1, flags=re.S)
assert n == 1
# RV32I coroutine hint: pop old TOS then replace it with the new link. Original
# entry*_push selected the next free slot even when both hints were asserted.
s = s.replace('if(rtu_ifu_retire0_pcall && rtu_ifu_retire0_preturn)',
              'if(rtu_ifu_retire0_pcall && rtu_ifu_retire0_preturn && !rtu_ras_empty)')
s = s.replace('else if(ras_push && ras_pop)', 'else if(ras_push && ras_pop && !ras_empty)')
# Overflow floor tracks overwritten entries. Popping a full stack must not move
# that floor backwards and make the overwritten thirteenth entry valid again.
s, n = re.subn(r'(else if\(cp0_ifu_ras_en && ras_full && ras_pop\)\s*begin).*?\n  end',
               r'\1\n    status_ptr[4:0] <= status_ptr[4:0];\n  end', s, count=1, flags=re.S)
assert n == 1
s = s.replace('localparam PC_WIDTH = 32;', '''localparam PC_WIDTH = 32;
wire [3:0] top_write_ptr = ras_push && ras_pop && !ras_empty
                          ? (top_ptr[3:0]==0 ? 4'd11 : top_ptr[3:0]-4'd1) : top_ptr[3:0];
wire [3:0] rtu_write_ptr = rtu_ifu_retire0_pcall && rtu_ifu_retire0_preturn && !rtu_ras_empty
                          ? (rtu_ptr[3:0]==0 ? 4'd11 : rtu_ptr[3:0]-4'd1) : rtu_ptr[3:0];''')
s = re.sub(r'(assign entry\d+_push = )([^;]+);',
           lambda m: m[1]+m[2].replace('top_ptr[3:0]', 'top_write_ptr')+';', s)
s = re.sub(r'(assign rtu_entry\d+_push = )([^;]+);',
           lambda m: m[1]+m[2].replace('rtu_ptr[3:0]', 'rtu_write_ptr')+';', s)
s = re.sub(r'(assign rtu_entry\d+_pre\[PC_WIDTH-1:0\] = )([^;]+);',
           lambda m: m[1]+m[2].replace('rtu_ptr[3:0]', 'rtu_write_ptr')+';', s)
s = re.sub(r'(assign rtu_fifo_ptr_pre\[3:0\] = )([^;]+);',
           lambda m: m[1]+m[2].replace('rtu_ptr[3:0]', 'rtu_write_ptr')+';', s)
for i in range(12):
    k=i%6
    s=s.replace(f'ras_entry{i}_filled <= rtu_entry{k}_filled;',
                f'ras_entry{i}_filled <= (rtu_ifu_retire0_pcall && rtu_entry{k}_push) ? 1\'b1 : rtu_entry{k}_filled;')
    s=s.replace(f'ras_entry{i}_priv_mode[1:0] <= rtu_entry{k}_priv_mode[1:0];',
                f'ras_entry{i}_priv_mode[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry{k}_push) ? cp0_yy_priv_mode : rtu_entry{k}_priv_mode;')
    s=re.sub(rf'assign rtu_entry{i}_copy = .*?;',
             f"assign rtu_entry{i}_copy = entry_in_backup(4'd{i},rtu_ptr_pre,rtu_available_pre);", s, flags=re.S)
    s=re.sub(rf'else if\(top_entry_rtu_updt && rtu_entry{i}_copy\)\s*ras_entry{i}_filled <= [^;]+;',
             f"else if(top_entry_rtu_updt)\n    ras_entry{i}_filled <= rtu_entry{i}_copy;", s)
# Original IP bypass predicts the NEXT return after an older IB call. Expose old
# stack top separately so coroutine pop+push can use the pre-push target.
s = s.replace('module rv32_ifu_ras(', 'module rv32_ifu_ras(\n  ras_top_valid,')
s = s.replace('input ras_clear;', 'output ras_top_valid;\ninput ras_clear;')
s = s.replace('endmodule', '''assign ras_top_valid = !ras_empty && ras_filled && cp0_ifu_ras_en
                       && (cp0_yy_priv_mode == ras_priv_mode);
endmodule''')
save('rv32_ifu_ras', s, 'all PCs are byte addresses; +4 link supplied by caller; synchronous clear and old-top valid added.')

# Keep IND sequencing, path hash and delayed recovery. Widen stored target only.
s = read('ct_ifu_ind_btb')
s = s.replace('[38:0]', '[31:0]').replace('[22:0]', '[34:0]')
s = s.replace("23'b0", "35'b0").replace('[19:0]', '[31:0]')
s = s.replace('module rv32_ifu_ind_btb(', 'module rv32_ifu_ind_btb(\n  cancel,\n  ind_result_vld,')
s = s.replace('input ', 'input cancel;\noutput ind_result_vld;\nreg ind_result_vld;\ninput ', 1)
s = s.replace('assign ind_btb_rd = cp0_ifu_ind_btb_en &&',
              'assign ind_btb_rd = !cancel && cp0_ifu_ind_btb_en &&')
s = s.replace('else if(ind_btb_inv_on_reg)\n    ind_btb_rd_flop',
              'else if(ind_btb_inv_on_reg || cancel)\n    ind_btb_rd_flop')
s = s.replace('endmodule', '''// Two edges: synchronous SRAM read, then held output register.
always @(posedge forever_cpuclk or negedge cpurst_b)
  if (!cpurst_b) ind_result_vld <= 1'b0;
  else if (cancel || ind_btb_inv_on_reg || ifctrl_ind_btb_inv || path_reg_rtu_updt
           || rtu_ind_btb_update_vld) ind_result_vld <= 1'b0;
  else ind_result_vld <= ind_btb_rd_flop;
endmodule''')
save('rv32_ifu_ind_btb', s, '35-bit {valid,priv[1:0],byte_target[31:0]}; path remains target byte[11:4].')

# Technology-independent synchronous single-port RAMs (active-low bit masks).
for name, macro, aw, dw in [('bht_pre_array', 'ct_spsram_1024x64', 10, 64),
                           ('bht_sel_array', 'ct_spsram_128x16', 7, 16),
                           ('ind_btb_array', 'ct_spsram_256x23', 8, 35)]:
    s = read('ct_ifu_' + name)
    if name == 'ind_btb_array':
        s = s.replace('[22:0]', '[34:0]').replace("23'b", "35'b").replace('{23{', '{35{')
    s, n = re.subn(r'\b' + macro + r'\s+(\w+)\s*\(',
                   f'rv32_ifu_spram #(.ADDR_WIDTH({aw}), .DATA_WIDTH({dw})) \\1 (', s)
    assert n == 1, (name, macro)
    save('rv32_ifu_' + name, s, 'portable synchronous SRAM; original control polarity/read latency retained.')

(ROOT / 'doc').mkdir(exist_ok=True)
(ROOT / 'doc' / 'source_manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
(ROOT / 'doc' / 'C910_delta.patch').write_text(''.join(patches), encoding='utf-8')
