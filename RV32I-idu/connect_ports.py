#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
自动连接 ct_idu_top.sv 中同名端口的脚本
"""

# 定义需要连接的同名信号列表
common_signals = [
    'cpurst_b',
    'forever_cpuclk',
    'forever_clk',
    'rtu_idu_flush_fe',
    'rtu_idu_flush_is',
    'rtu_idu_flush_stall',
    'rtu_yy_xx_flush',
    'rtu_yy_xx_dbgon',
    'rtu_idu_rob_full',
    'rtu_idu_rt_recover_preg',
    'rtu_idu_rob_inst0_iid',
    'rtu_idu_rob_inst1_iid',
    'rtu_idu_rob_inst2_iid',
    'rtu_idu_alloc_preg0_vld',
    'rtu_idu_alloc_preg1_vld',
    'rtu_idu_alloc_preg2_vld',
    'rtu_idu_alloc_preg0',
    'rtu_idu_alloc_preg1',
    'rtu_idu_alloc_preg2',
    'iu_yy_xx_cancel',
    'iu_idu_mispred_stall',
    'iu_idu_ex2_pipe0_wb_preg_dupx',
    'iu_idu_ex2_pipe0_wb_preg_vld_dupx',
    'iu_idu_ex2_pipe1_wb_preg_dupx',
    'iu_idu_ex2_pipe1_wb_preg_vld_dupx',
    'iu_idu_ex2_pipe0_wb_preg_data',
    'iu_idu_ex2_pipe0_wb_preg_expand',
    'iu_idu_ex2_pipe0_wb_preg_vld',
    'iu_idu_ex2_pipe1_wb_preg_data',
    'iu_idu_ex2_pipe1_wb_preg_expand',
    'iu_idu_ex2_pipe1_wb_preg_vld',
    'lsu_idu_wb_pipe3_wb_preg_dupx',
    'lsu_idu_wb_pipe3_wb_preg_vld_dupx',
    'lsu_idu_wb_pipe3_wb_preg_data',
    'lsu_idu_wb_pipe3_wb_preg_expand',
    'lsu_idu_wb_pipe3_wb_preg_vld',
    'ifu_xx_sync_reset',
    'ctrl_ir_stall',
    'ctrl_ir_pipedown',
    'ctrl_ir_pipedown_inst0_vld',
    'ctrl_ir_pipedown_inst1_vld',
    'ctrl_ir_pipedown_inst2_vld',
    'ctrl_aiq_create0_en',
    'ctrl_aiq_create1_en',
    'ctrl_aiq_rf_pop_vld',
    'aiq_ctrl_1_left_updt',
    'aiq_ctrl_full_updt',
    'aiq_xx_issue_en',
    'dp_aiq_create0_data',
    'dp_aiq_create1_data',
    'ctrl_biq_create0_en',
    'ctrl_biq_create1_en',
    'ctrl_biq_rf_pop_vld',
    'biq_ctrl_1_left_updt',
    'biq_ctrl_full_updt',
    'biq_xx_issue_en',
    'ctrl_lsiq_create0_en',
    'ctrl_lsiq_create1_en',
    'lsiq_ctrl_1_left_updt',
    'lsiq_ctrl_full_updt',
    'lsiq_xx_pipe3_issue_en',
    'lsiq_xx_pipe4_issue_en',
    'dp_lsiq_create0_data',
    'dp_lsiq_create1_data',
    'ctrl_sdiq_create0_en',
    'ctrl_sdiq_create1_en',
    'sdiq_ctrl_1_left_updt',
    'sdiq_ctrl_full_updt',
    'sdiq_xx_issue_en',
    'dp_sdiq_create0_data',
    'dp_sdiq_create1_data',
    'sdiq_dp_issue_entry',
    'sdiq_dp_issue_read_data',
    'ctrl_mult_create0_en',
    'ctrl_mult_create1_en',
    'ctrl_mult_rf_pop_vld',
    'mult_ctrl_1_left_updt',
    'mult_ctrl_full_updt',
    'ctrl_div_create0_en',
    'ctrl_div_create1_en',
    'ctrl_div_rf_pop_vld',
    'div_ctrl_1_left_updt',
    'div_ctrl_full_updt',
    'dp_prf_rf_pipe0_src0_preg',
    'dp_prf_rf_pipe0_src1_preg',
    'dp_prf_rf_pipe1_src0_preg',
    'dp_prf_rf_pipe1_src1_preg',
    'dp_prf_rf_pipe2_src0_preg',
    'dp_prf_rf_pipe2_src1_preg',
    'dp_prf_rf_pipe3_src0_preg',
    'dp_prf_rf_pipe4_src0_preg',
    'dp_prf_rf_pipe5_src0_preg',
    'dp_prf_rf_pipe6_src0_preg',
    'dp_prf_rf_pipe6_src1_preg',
    'prf_dp_rf_pipe0_src0_data',
    'prf_dp_rf_pipe0_src1_data',
    'prf_dp_rf_pipe1_src0_data',
    'prf_dp_rf_pipe1_src1_data',
    'prf_dp_rf_pipe2_src0_data',
    'prf_dp_rf_pipe2_src1_data',
    'prf_dp_rf_pipe3_src0_data',
    'prf_dp_rf_pipe4_src0_data',
    'prf_dp_rf_pipe5_src0_data',
    'prf_dp_rf_pipe6_src0_data',
    'prf_dp_rf_pipe6_src1_data',
    'dp_ir_inst0_data',
    'dp_ir_inst1_data',
    'dp_ir_inst2_data',
    'ctrl_xx_is_inst0_sel',
    'dp_ctrl_is_inst0_dst_vld',
    'dp_ctrl_is_inst1_dst_vld',
    'dp_ctrl_is_inst2_dst_vld',
]

def process_file():
    input_file = r'C:\Users\LIUCONG\Desktop\idu\ct_idu_top.sv'

    with open(input_file, 'r', encoding='utf-8') as f:
        content = f.read()

    # 对每个信号进行替换
    for signal in common_signals:
        # 匹配模式：.signal_name  ()
        # 替换为：.signal_name  (signal_name)
        import re
        pattern = rf'(\.\s*{re.escape(signal)}\s*)\(\s*\)'
        replacement = rf'\1({signal})'
        content = re.sub(pattern, replacement, content)

    with open(input_file, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f"处理完成！已连接 {len(common_signals)} 个同名信号")

if __name__ == '__main__':
    process_file()
