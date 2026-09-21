"""Generate explicit predictor-cluster wiring and a machine-readable port list.

The IF/IP/IB stage controls remain exposed: this is NOT a complete IFU top.
"""
from pathlib import Path
import re
import json
from rtl_style import public_ports, rewrite, remember

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'rtl'
ports = {}
wires = {}
instances = []


def port(name, direction='input', width=''):
    value = (direction, width)
    assert name not in ports or ports[name] == value, (name, ports.get(name), value)
    ports[name] = value
    return name


def wire(name, width=''):
    wires[name] = width
    return name


def original_ports(name):
    s = (RTL / (name+'.v')).read_text()
    return public_ports(s)


for name in ['forever_cpuclk','cpurst_b','iu_ifu_mispred_stall','frontend_cancel',
             'bp_maint_vld']:
    port(name)
port('bp_maint_mask', width='[4:0]')
for name in ['bp_init_done','bp_maint_ready','bp_maint_done','bp_recovery_stall']:
    port(name, 'output')
for i in range(3): port(f'rtu_ifu_retire{i}_vld')
port('if_pc', width='[31:0]')
port('if_query_pc', width='[31:0]')
port('ib_query_ghr', width='[7:0]')
port('ip_pc', width='[31:0]')
port('ib_pred_target', width='[31:0]')

for mod in ['bht','ras','ind_btb']:
    connections = []
    for direction, width, name in original_ports('rv32_ifu_'+mod):
        expr = name
        if name == 'cancel': expr = '!frontend_ok'
        elif name in ['ifctrl_bht_inv','ifctrl_ind_btb_inv']:
            expr = 'start_invalidate && active_mask['+('2' if mod=='bht' else '3')+']'
        elif name == 'ras_clear': expr = 'start_invalidate && active_mask[4]'
        elif name == 'ipdp_bht_vpc': expr = 'ip_pc[31:1]'
        elif name == 'pcgen_bht_ifpc': expr = 'if_pc[7:1]'
        elif name == 'pcgen_bht_pcindex': expr = '(STAGED_BHT ? if_query_pc[13:4] : if_pc[13:4])'
        elif name == 'iu_ifu_cur_pc':
            port(name, width='[31:0]'); expr = name+'[31:1]'
        elif name == 'ibctrl_ind_btb_path': expr = 'ib_pred_target[11:4]'
        elif name in ['bht_ind_btb_rtu_ghr','bht_ind_btb_vghr']:
            wire(name,width)
            if name=='bht_ind_btb_vghr' and mod=='ind_btb':
                expr='(STAGED_BHT ? ib_query_ghr : bht_ind_btb_vghr)'
        elif name == 'rtu_ifu_flush':
            port(name); expr = '(rtu_ifu_flush || maint_fire)'
        elif re.match(r'rtu_ifu_retire[012]_(condbr|jmp)$',name):
            port(name); expr = f'({name} && rtu_ifu_retire{name[14]}_vld)'
        elif name in ['rtu_ifu_retire0_pcall','rtu_ifu_retire0_preturn',
                      'rtu_ifu_retire0_mispred','rtu_ifu_retire0_jmp_mispred']:
            port(name); expr = f'({name} && rtu_ifu_retire0_vld)'
        elif name == 'iu_ifu_chgflw_vld':
            port(name); expr = '(iu_ifu_chgflw_vld && bp_init_done)'
        elif name == 'iu_ifu_bht_check_vld':
            port(name); expr = '(iu_ifu_bht_check_vld && bp_init_done && !maint_fire)'
        elif name in ['bht_ifctrl_inv_done','bht_ifctrl_inv_on',
                      'ind_btb_ifctrl_inv_done','ind_btb_ifctrl_inv_on']:
            wire(name,width)
        elif name in ['ras_top_valid','ras_ipdp_data_vld','ind_result_vld']:
            wire('raw_'+name,width); port(name,direction,width); expr='raw_'+name
        elif name == 'ibctrl_ind_btb_fifo_stall':
            port(name); expr = '(ibctrl_ind_btb_fifo_stall || bp_recovery_stall || !frontend_ok)'
        elif name.startswith('ibctrl_ras_') or name in ['ibctrl_ind_btb_check_vld','ipdp_ind_btb_jmp_detect']:
            port(name,direction,width); expr = f'({name} && frontend_ok && !bp_recovery_stall)'
        elif name in ['ipctrl_bht_con_br_vld','ipctrl_bht_con_br_gateclk_en',
                      'ipctrl_ind_btb_con_br_vld','lbuf_bht_con_br_vld',
                      'ifctrl_bht_pipedown','pcgen_bht_seq_read','pcgen_bht_chgflw',
                      'pcgen_bht_chgflw_short']:
            port(name,direction,width); expr = f'({name} && frontend_ok)'
        elif name == 'local_recover_vld':
            port(name); expr = '(local_recover_vld && bp_init_done && !maint_fire)'
        else: port(name,direction,width)
        connections.append(f'    .{name}({expr})')
    instances.append('  rv32_ifu_'+mod+' x_'+mod+' (\n'+',\n'.join(connections)+'\n  );')

# BTB and L0 have target-specific word-slot interfaces.
configs = {
 'btb': [('input','enable',''),('input','lookup_vld',''),('output','lookup_ready',''),
 ('input','lookup_pc','[31:0]'),('output','result_vld',''),('output','hit','[3:0]'),
 ('output','target','[127:0]'),('output','way_hint','[7:0]'),('input','update_vld',''),
 ('output','update_ready',''),('input','update_pc','[31:0]'),('input','update_target','[31:0]'),
 ('input','update_way','[1:0]'), ('output','if_vld',''), ('output','if_pc','[31:0]'),
 ('output','if_hit','[3:0]'), ('output','if_target','[127:0]'), ('output','if_way_hint','[7:0]')],
 'l0_btb': [('input','enable',''),('input','lookup_vld',''),('input','lookup_pc','[31:0]'),
 ('output','hit',''),('output','hit_index','[3:0]'),('output','hit_slot','[1:0]'),
 ('output','hit_type','[2:0]'),('output','target','[31:0]'),('output','way_hint','[1:0]'),
 ('input','update_vld',''),('input','update_pc','[31:0]'),('input','update_target','[31:0]'),
 ('input','update_type','[2:0]'),('input','update_taken',''),('input','update_ras',''),
 ('input','update_way','[1:0]'),('input','directed_inv_vld',''),('input','directed_inv_mask','[15:0]')]
}
for mod, declarations in configs.items():
    short = 'l0' if mod=='l0_btb' else 'btb'
    conn = ['.forever_cpuclk(forever_cpuclk)', '.cpurst_b(cpurst_b)',
            f'.invalidate(start_invalidate && active_mask[{0 if short=="l0" else 1}])']
    for direction,name,width in declarations:
        outer = f'{short}_{name}'
        if name=='enable': outer = 'cp0_ifu_l0btb_en' if short=='l0' else 'cp0_ifu_btb_en'
        port(outer,direction,width)
        expr = outer
        if name in ['lookup_vld','update_vld']: expr=f'({outer} && frontend_ok)'
        conn.append(f'.{name}({expr})')
    if short=='l0':
        conn += ['.cancel(!frontend_ok)', '.ras_valid(ras_top_valid && !bp_recovery_stall)',
                 '.ras_target(ras_l0_btb_pc)']
    else:
        wire('btb_init_done'); conn += ['.init_done(btb_init_done)', '.cancel(!frontend_ok)']
    instances.append(f'  rv32_ifu_{mod} x_{short} (\n    '+',\n    '.join(conn)+'\n  );')

port('bht_pred','output');port('bht_chk_idx','output','[24:0]')
port('ind_target_valid','output');port('ind_target','output','[31:0]')
s='''// SPDX-License-Identifier: Apache-2.0
// Generated by scripts/build_cluster.py. Predictor-only integration boundary.
// All top-level PCs are 32-bit byte addresses; only BHT leaf ports use P=PC>>1.
// Stage controls are accepted events from the future IF/IP/IB controllers.
module rv32_ifu_bp_top #(parameter STAGED_BHT=0)(\n'''
s+=',\n'.join(f'  {d} wire {w} {n}' for n,(d,w) in ports.items())+'\n);\n'
s+='\n'.join(f'  wire {w} {n};' for n,w in wires.items())+'\n'
s+='''
  // A pulse is launched in state 0/3; state 1/4 observes busy then completion.
  reg [2:0] state;
  reg [4:0] saved_mask;
  reg done_pulse;
  wire maint_fire = bp_maint_vld && bp_maint_ready;
  wire start_invalidate = (state==0 || state==3);
  wire [4:0] active_mask = (state==0 || state==1) ? 5'b11111 : saved_mask;
  wire arrays_done = bht_ifctrl_inv_done && ind_btb_ifctrl_inv_done && btb_init_done;
  assign bp_init_done = state==2;
  assign bp_maint_ready = state==2 && !rtu_ifu_flush && !iu_ifu_chgflw_vld;
  assign bp_maint_done = done_pulse;
  assign bp_recovery_stall = iu_ifu_mispred_stall;
  wire frontend_ok = bp_init_done && !frontend_cancel && !maint_fire
                     && !rtu_ifu_flush && !iu_ifu_chgflw_vld && (STAGED_BHT || !local_recover_vld);
  always @(posedge forever_cpuclk or negedge cpurst_b)
    if (!cpurst_b) begin state<=0; saved_mask<=0; done_pulse<=0; end
    else begin
      done_pulse<=0;
      case(state)
        0: state<=1;
        1: if (arrays_done) state<=2;
        2: if (maint_fire) begin saved_mask<=bp_maint_mask; state<=3; end
        3: state<=4;
        4: if (arrays_done) begin state<=2; done_pulse<=1; end
        default: state<=0;
      endcase
    end
  assign ras_top_valid = raw_ras_top_valid && frontend_ok && !bp_recovery_stall;
  assign ras_ipdp_data_vld = raw_ras_ipdp_data_vld && frontend_ok && !bp_recovery_stall;
  assign ind_result_vld = raw_ind_result_vld && frontend_ok && !bp_recovery_stall;
  assign ind_target_valid = ind_result_vld && ind_btb_ibctrl_dout[34]
                            && ind_btb_ibctrl_dout[33:32]==cp0_yy_priv_mode
                            && ind_btb_ibctrl_priv_mode==cp0_yy_priv_mode
                            && ind_btb_ibctrl_dout[1:0]==0;
  assign ind_target = ind_btb_ibctrl_dout[31:0];
  wire [31:0] bht_selected = bht_ipdp_sel_array_result[1]
                            ? bht_ipdp_pre_array_data_taken : bht_ipdp_pre_array_data_ntake;
  reg [1:0] bht_counter;
  integer k;
  always @(*) begin
    bht_counter=0;
    for(k=0;k<16;k=k+1)
      bht_counter=bht_counter | ({2{bht_ipdp_pre_offset_onehot[k]}} & bht_selected[k*2+:2]);
  end
  assign bht_pred = cp0_ifu_bht_en && bht_counter[1];
  assign bht_chk_idx = {bht_counter[0],bht_ipdp_sel_array_result,bht_ipdp_vghr};
'''
s+='\n\n'.join(instances)+'\nendmodule\n'
s, names = rewrite(s)
remember('rv32_ifu_bp_top', names)
(RTL/'rv32_ifu_bp_top.v').write_text(s)
(ROOT/'doc'/'ports.json').write_text(json.dumps(ports,indent=2))
files=['rv32_ifu_spram','rv32_ifu_clk_cell','rv32_ifu_bht_pre_array','rv32_ifu_bht_sel_array',
       'rv32_ifu_ind_btb_array','rv32_ifu_bht','rv32_ifu_ras','rv32_ifu_ind_btb',
       'rv32_ifu_btb','rv32_ifu_l0_btb','rv32_ifu_bp_decode','rv32_ifu_bp_target','rv32_ifu_bp_top']
(ROOT/'rtl'/'files.f').write_text('\n'.join('rtl/'+x+'.v' for x in files)+'\n')
