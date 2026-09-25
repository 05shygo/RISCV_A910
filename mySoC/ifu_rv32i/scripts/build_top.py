"""Explicit no-MMU workbook boundary and stage-owned IFU integration."""
from pathlib import Path
import re,json
import openpyxl
from rtl_style import public_ports,layout
ROOT=Path(__file__).resolve().parents[1]
w=openpyxl.load_workbook(ROOT/'doc/RV32I_C910_IFU_interface_v1.1_noMMU.xlsx',read_only=True,data_only=True)
external={}
for name,d,_ in w['IFU_Interface'].values:
    m=re.fullmatch(r'(\w+)(\[\d+:\d+\])?',str(name))
    if m and d in ['Input','Output']:external[m[1]]=(d.lower(),m[2] or '')
w.close()
signals={n:w for n,(_,w) in external.items()}
drivers={n:'external' for n,(d,_) in external.items() if d=='input'}
instances=[];used=set();module_files=[]

def drive(n,expr,width=''):
    assert n not in drivers,(n,drivers.get(n))
    drivers[n]='assign';signals[n]=width or signals.get(n,'')
    logic.append(f'  assign {n}={expr};')

def add(mod,mapping=None,params='',inst=None):
    mapping=mapping or {};cons=[]
    for d,width,n in public_ports((ROOT/'rtl'/f'rv32_ifu_{mod}.v').read_text()):
        v=mapping.get(n,n)
        if re.fullmatch(r'\w+',v):
            if v in signals:assert re.sub(r'\s','',signals[v])==re.sub(r'\s','',width),(mod,n,v,signals[v],width)
            signals[v]=width
            if d=='output':
                assert v not in drivers,(mod,n,v,drivers.get(v));drivers[v]=mod
            else:used.add(v)
        cons.append(f'.{n}({v})')
    instances.append('  rv32_ifu_'+mod+' '+params+' u_'+(inst or mod)+'('+',\n'.join(cons)+');')
    module_files.append('rtl/rv32_ifu_'+mod+'.v')

logic=[]
add('pcgen',{
 'addrgen_pcgen_pcload':"1'b0",'addrgen_pcgen_pc':"32'b0",
 'ibctrl_pcgen_pcload':'ib_redirect','ibctrl_pcgen_pcload_vld':'ib_redirect',
 'ibctrl_pcgen_pc':'ib_redirect_pc','ibctrl_pcgen_way_pred':"2'b11",'ibctrl_pcgen_ip_stall':"1'b0",
 'ipctrl_pcgen_reissue_pcload':'reissue','ipctrl_pcgen_reissue_pc':'demand_pc',
 'ipctrl_pcgen_reissue_way_pred':'reissue_way','ipctrl_pcgen_chgflw_pcload':'ip_redirect',
 'ipctrl_pcgen_chgflw_pc':'ip_redirect_pc','ipctrl_pcgen_chgflw_way_pred':"2'b11",
 'ipctrl_pcgen_branch_taken':'ip_redirect','ipctrl_pcgen_branch_mistaken':'l0_invalidate',
 'ipctrl_pcgen_taken_pc':'ip_redirect_pc','ipctrl_pcgen_chk_err_reissue':'reissue',
 'ipctrl_pcgen_if_stall':"1'b0",'ipctrl_pcgen_inner_way0':"1'b0",'ipctrl_pcgen_inner_way1':"1'b0",
 'ipctrl_pcgen_inner_way_pred':"2'b11",'ifctrl_pcgen_ins_icache_inv_done':'maint_resume',
 'lbuf_pcgen_active':"1'b0",'lbuf_pcgen_vld_mask':"1'b0",
 'vector_pcgen_pcload':'entry_load','vector_pcgen_pc':'entry_pc',
})
add('ifctrl',{'frontend_init_done':'fetch_initialized','maintenance_busy':'maint_busy',
 'frontend_redirect':'frontend_redirect',
 'control_ifctrl_reissue':'fault_accept','cp0_ifu_no_op_req':'stop_fetch',
 'ipctrl_ifctrl_bht_stall':"1'b0",'btb_ifctrl_ready':'btb_lookup_ready',
 'maintenance_array_req':'maintenance_array_req',
 'l1_refill_ifctrl_active':'refill_active_block',
 'ifu_hpcp_frontend_stall':'if_frontend_stall'})
# The ICache IF read data reach IFDP and maintenance directly; no mux remains.
cache_map={'icache_if_ifdp_'+f:'raw_cache_'+f
 for f in ['inst_data0','inst_data1','precode0','precode1','tag_data0','tag_data1','fifo']}
add('ifdp',{'btb_ifdp_vld':'btb_if_vld','btb_ifdp_pc':'btb_if_pc','btb_ifdp_hit':'btb_if_hit',
 'btb_ifdp_target':'btb_if_target','btb_ifdp_way':'btb_if_way_hint',
 'l0_btb_ifdp_hit':'l0_hit','l0_btb_ifdp_index':'l0_hit_index','l0_btb_ifdp_slot':'l0_hit_slot',
 'l0_btb_ifdp_way':'l0_way_hint','l0_btb_ifdp_type':'l0_hit_type','l0_btb_ifdp_target':'l0_target',
 'sfp_ifdp_vld':"1'b1",'sfp_ifdp_pc':'ifdp_l0_btb_pc','sfp_ifdp_no_spec':'sfp_no_spec',**cache_map})
array_map={'ifu_hpcp_icache_miss_pre':'miss_event',**cache_map}
add('if_array',array_map)

pipe_map={'cancel_ip':'cancel_ip','flush':'global_flush','recovery_stall':'bp_recovery_stall',
 'ind_enable':'cp0_ifu_ind_btb_en','ras_valid':'ras_top_valid','ras_target':'ras_l0_btb_pc',
 'ind_target_valid':'ind_target_valid','demand_ready':'pipe_demand_ready',
 'ifctrl_ipctrl_vld':'pipe_ip_valid','ifctrl_ifdp_pipedown':'pipe_ip_load',
 'bht_pred':'pipe_bht_pred','local_recover_ghr':'ib_recover_ghr','btb_update_ready':'training_ready'}
for _,width,n in public_ports((ROOT/'rtl/rv32_ifu_pipeline.v').read_text()):
    if n.startswith('ifdp_ipdp_'):pipe_map[n]='pipe_'+n
add('pipeline',pipe_map)
add('memory',{'cancel':'memory_cancel','invalidate':'maint_invalidate','enable':'cp0_ifu_icache_pref_en',
 'stop':'stop_fetch','demand_valid':'memory_demand_valid','demand_ready':'memory_demand_ready',
 'demand_attr':'ifdp_ipdp_attr','demand_priv':'ifdp_ipdp_priv_mode',
 'demand_allocate':'demand_allocate','region_pc':'prefetch_region_pc','region_attr':'prefetch_region_attr',
 'l1_refill_ifctrl_active':'refill_active_raw','launch':'ipb_launch','demand_hit':'ipb_demand_hit'})
add('maintenance',{'recovery':'backend_redirect','recovery_pc':'backend_pc',
 'memory_idle':'memory_idle','init_done':'cache_init_done','busy':'maint_busy',
 'invalidate':'maint_invalidate','flush':'maint_flush','resume':'maint_resume',
 'resume_pc':'maint_resume_pc',**cache_map})
add('vector',{'init_done':'ifu_cp0_init_done'})
add('debug',{'quiescent':'ifu_had_quiescent','global_cancel':'backend_redirect',
 'inject_accept':'debug_inject_accept'})
add('bp_top',{
 'rtu_ifu_flush':'predictor_commit_restore',
 'frontend_cancel':'global_flush','if_pc':'bp_if_pc','if_query_pc':'bp_query_pc',
 'ib_query_ghr':'ind_query_ghr','ip_pc':'pipe_ifdp_ipdp_vpc','ib_pred_target':'jump_target',
 'local_recover_vld':'ib_redirect','local_recover_ghr':'ib_recover_ghr','ifctrl_bht_pipedown':'bp_pipedown',
 'ipctrl_bht_con_br_gateclk_en':'bht_event','ipctrl_bht_con_br_taken':'bht_taken',
 'ipctrl_bht_con_br_vld':'bht_event','ipctrl_bht_more_br':'bht_more','ipctrl_bht_vld':'pipe_ip_valid',
 'lbuf_bht_active_state':"1'b0",'lbuf_bht_con_br_taken':"1'b0",'lbuf_bht_con_br_vld':"1'b0",
 'pcgen_bht_chgflw':"1'b0",'pcgen_bht_chgflw_short':"1'b0",'pcgen_bht_seq_read':'bp_read',
 'ifctrl_bht_stall':'bp_read_stall',
 'ibctrl_ras_inst_pcall':'ras_push','ibctrl_ras_pcall_vld':'ras_push',
 'ibctrl_ras_pcall_vld_for_gateclk':'ras_push','ibctrl_ras_preturn_vld':'ras_pop',
 'ibctrl_ras_preturn_vld_for_gateclk':'ras_pop','ibdp_ras_push_pc':'push_pc',
 'ibctrl_ind_btb_check_vld':'jump_accept','ibctrl_ind_btb_fifo_stall':"1'b0",
 'ipctrl_ind_btb_con_br_vld':"1'b0",'ipdp_ind_btb_jmp_detect':'ind_query',
 'btb_lookup_vld':'ifctrl_btb_lookup_vld','btb_lookup_pc':'ifctrl_btb_lookup_pc',
 'btb_update_vld':'train_valid','btb_update_pc':'train_pc','btb_update_target':'train_target',
 'btb_update_way':'train_way','l0_lookup_vld':'ifctrl_l0_btb_lookup_vld','l0_lookup_pc':'ifdp_l0_btb_pc',
 'l0_update_vld':'train_valid','l0_update_pc':'train_pc','l0_update_target':'train_target',
 'l0_update_type':'train_type','l0_update_taken':'train_taken','l0_update_ras':'train_ras',
 'l0_update_way':'train_way','l0_directed_inv_vld':'l0_invalidate','l0_directed_inv_mask':'l0_invalidate_mask',
},params='#(.STAGED_BHT(1))')
add('sfp',{'enable':'cp0_ifu_nsfe','invalidate':'clear_sfp','cancel':'global_flush',
 'lookup_accept':'ifctrl_ifdp_pipedown','lookup_pc':'ifdp_l0_btb_pc','lookup_mask':'sfp_mask',
 'no_spec':'sfp_no_spec',**{n:'sfp_'+n for n in ['retire_valid','retire_load','retire_store','retire_hit','retire_miss','retire_mispred','retire_pc']}})
region_params='#(.REGION_COUNT(REGION_COUNT),.REGION_BASE(REGION_BASE),.REGION_LIMIT(REGION_LIMIT),.REGION_ATTR(REGION_ATTR))'
for label,pc,attr in [('fast','pcgen_icache_if_index','region_ifctrl_attr'),
                      ('issue','ifctrl_ifdp_issue_pc','region_ifdp_attr'),
                      ('prefetch','prefetch_region_pc','prefetch_region_attr')]:
    add('region',{'pa':pc,'attr':attr},region_params,'region_'+label)

for n,expr in {
 'backend_redirect':'rtu_ifu_chgflw_vld || iu_ifu_chgflw_vld',
 'backend_pc':'rtu_ifu_chgflw_vld ? rtu_ifu_chgflw_pc : iu_ifu_chgflw_pc',
 'entry_load':'vector_pcgen_pcload || maint_resume',
 'entry_pc':'maint_resume ? maint_resume_pc : vector_pcgen_pc',
 'global_flush':'backend_redirect || maint_flush || pcgen_ibctrl_ibuf_flush',
 'predictor_commit_restore':'rtu_ifu_flush || debug_restore',
 'frontend_redirect':'global_flush || maint_resume || ib_redirect || ip_redirect || reissue',
 'cancel_ip':'global_flush || ib_redirect',
 'fetch_initialized':'ifu_cp0_init_done && !vector_pcgen_reset_on',
 'stop_fetch':'cp0_ifu_no_op_req || fault_stop_q',
 'refill_active_block':'refill_active_raw || miss_event',
 'memory_cancel':'global_flush || maint_resume || ib_redirect || ip_redirect || way_event',
 'memory_demand_valid':'demand_valid && !cp0_ifu_no_op_req',
 'pipe_demand_ready':'memory_demand_ready && !cp0_ifu_no_op_req',
 'demand_allocate':'cp0_ifu_icache_en && ifdp_ipdp_attr[3]',
 'memory_idle':'refill_idle && prefetch_idle && bus_idle',
 'ifu_cp0_init_done':'cache_init_done && bp_init_done',
 'ifu_idu_flush':'global_flush',
 'ifu_yy_xx_no_op':'ifu_cp0_init_done && memory_idle && !maint_busy && software_idle',
 'ifu_had_no_inst':'out_count==0',
 'ifu_had_reset_on':'vector_pcgen_reset_on',
 'ifu_had_quiescent':'ifu_yy_xx_no_op && ifctrl_idle && ib_empty && ibuf_empty && !debug_busy',
 'pipe_ip_valid':'inject_valid || ifctrl_ipctrl_vld',
 'pipe_ip_load':'ifctrl_ifdp_pipedown || inject_pipedown',
 'pipe_bht_pred':'bht_pred',
 'debug_inject_accept':'inject_valid && !ipctrl_ifctrl_stall',
 'bp_pipedown':'ifctrl_ifdp_pipedown || (bht_event && bht_more) || inject_pipedown',
 'bp_read':'ifctrl_bht_read || inject_query',
 'bp_read_stall':'!bp_read',
 'bp_if_pc':'rtu_ifu_dbgon ? inject_pc : ifdp_bht_pc',
 'bp_query_pc':'rtu_ifu_dbgon ? inject_pc : ifctrl_ifdp_issue_pc',
 'ifu_iu_pcfifo_cancel_vld':"1'b0",
 'ifu_iu_pcfifo_cancel_first_token':"13'b0",
 'ifu_idu_ib_pipedown_gateclk':'out_count!=0',
 'sfp_mask':"4'b1111 << ifdp_l0_btb_pc[3:2]",
 'fault_stop_nxt':'!global_flush && !ib_redirect && (fault_stop_q || fault_accept)',
 'fault_stop_en':"1'b1",
 'training_ready':'!cp0_ifu_btb_en || btb_update_ready',
}.items():drive(n,expr,'[31:0]' if n in ['backend_pc','entry_pc'] else '[3:0]' if n=='sfp_mask' else '')
logic.append('''
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_fault_stop
    if(!cpurst_b) fault_stop_q<=1'b0;
    else if(fault_stop_en) fault_stop_q<=fault_stop_nxt;
  end
''')

debug_values={'vpc':'inject_pc','inst_data0':'( {96\'b0,inject_inst} << ({inject_pc[3:2],5\'b0}))',
 'inst_data1':"128'b0",'tag_match0':"3'b111",'tag_match1':"3'b0",'way_pred':"2'b01",
 'word_mask':"4'b0001 << inject_pc[3:2]",'fault':'(|inject_pc[1:0])','cause':"4'b0"}
for _,width,n in public_ports((ROOT/'rtl/rv32_ifu_pipeline.v').read_text()):
    if n.startswith('ifdp_ipdp_'):
        field=n.removeprefix('ifdp_ipdp_')
        drive('pipe_'+n,f'inject_valid ? {debug_values.get(field, chr(39)+"0")} : {n}',width)
# Use sized zero literals for Verilog-2001.
logic=[x.replace("? '0 :", "? 0 :") for x in logic]
for field,source in [('valid','vld'),('load','load'),('store','store'),('hit','no_spec_hit'),
                     ('miss','no_spec_miss'),('mispred','no_spec_mispred'),('pc','cur_pc')]:
    drive('sfp_retire_'+field,'{'+','.join(f'rtu_ifu_retire{i}_{source}' for i in [2,1,0])+'}',
          '[95:0]' if field=='pc' else '[2:0]')
for lane in range(3):
    drive(f'ifu_idu_ib_inst{lane}_vld',f'out_count>{lane}')
    drive(f'ifu_idu_ib_inst{lane}_data',f'out_packet[{lane*128}+:128]')
for lane in range(2):
    for field,bus,width in [('en','create_en',1),('gateclk_en','create_en',1),('cur_pc','create_pc',32),
      ('tar_pc','create_target',32),('pred_npc','create_npc',32),('cf_type','create_type',3),
      ('dst_vld','create_dst',1),('bht_pred','create_pred',1),('chk_idx','create_chk',25),
      ('jmp_mispred','create_unknown',1)]:
        drive(f'ifu_iu_pcfifo_create{lane}_{field}',f'{bus}[{lane*width}'+(f'+:{width}]' if width>1 else ']'))
for event,expr in {'btb_inst':'btb_used','btb_mispred':'ib_redirect || l0_invalidate',
 'frontend_stall':'if_frontend_stall || pcfifo_wait || recovery_wait',
 'way_reissue':'way_event','ipb_launch':'ipb_launch','ipb_demand_hit':'ipb_demand_hit',
 'lbuf_active':"1'b0",'pcfifo_stall':'pcfifo_wait','bht_update_drop':'bht_train_drop',
 'ras_miss':'return_accept && !ras_top_valid','ind_btb_miss':'ind_miss_event',
 'bju_mispred':'iu_ifu_chgflw_vld && !rtu_ifu_chgflw_vld'}.items():
    drive('ifu_hpcp_'+event,'hpcp_ifu_cnt_en && ('+expr+')')
drive('ifu_hpcp_id_accept_num','(hpcp_ifu_cnt_en && !global_flush) ? idu_ifu_accept_num : 2\'b0')

missing={n:signals[n] for n in used if n not in drivers}
missing_outputs=[n for n,(d,_) in external.items() if d=='output' and n not in drivers]
assert not missing,("undriven inputs",missing)
assert not missing_outputs,("undriven outputs",missing_outputs)
header='''// SPDX-License-Identifier: Apache-2.0
// Generated by scripts/build_top.py. Workbook v1.1/no-MMU boundary.
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
module rv32_ifu_top #(
  parameter REGION_COUNT=1,
  parameter [REGION_COUNT*32-1:0] REGION_BASE=0,
  parameter [REGION_COUNT*33-1:0] REGION_LIMIT=0,
  parameter [REGION_COUNT*5-1:0] REGION_ATTR=0
) (
'''
s=header+',\n'.join('  '+d+' wire '+width+' '+n for n,(d,width) in external.items())+'\n);\n'
s+='  reg fault_stop_q;\n'
s+='\n'.join('  wire '+width+' '+n+';' for n,width in signals.items() if n not in external)+'\n'
s+='\n'.join(logic+instances)+'\nendmodule\n'
(ROOT/'rtl/rv32_ifu_top.v').write_text(layout(s))
files=[]
for f in ['files.f','if_stage_files.f','pipeline_files.f','memory_files.f','support_files.f','lbuf_files.f']:
    files+=(ROOT/'rtl'/f).read_text().splitlines()
files+=['rtl/rv32_ifu_top.v']
(ROOT/'rtl/ifu_files.f').write_text('\n'.join(dict.fromkeys(files))+'\n')
print('Generated IFU top:',len(external),'workbook ports')
