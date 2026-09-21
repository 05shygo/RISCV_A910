"""Behavioral PCGEN scoreboard; uses ordered events rather than RTL mux structure."""


class PcgenModel:
    def __init__(self):
        self.reset()

    def reset(self):
        self.pc = 0
        self.stalled = 0
        self.redirected = 0
        self.way = 0
        self.redirect_way = 0
        self.way_stalled = 0
        self.debug = 0

    def evaluate(self, p):
        debug_load = p['debug_pcgen_pcload'] and p['rtu_ifu_dbgon']
        events = [
            (debug_load, p['debug_pcgen_pc'], 3),
            (p['vector_pcgen_pcload'], p['vector_pcgen_pc'], 3),
            (p['rtu_ifu_chgflw_vld'], p['rtu_ifu_chgflw_pc'], 3),
            (p['iu_ifu_chgflw_vld'], p['iu_ifu_chgflw_pc'], 3),
            (p['addrgen_pcgen_pcload'], p['addrgen_pcgen_pc'], 3),
            (p['ibctrl_pcgen_pcload'], p['ibctrl_pcgen_pc'], p['ibctrl_pcgen_way_pred']),
            (p['ipctrl_pcgen_reissue_pcload'], p['ipctrl_pcgen_reissue_pc'],
             p['ipctrl_pcgen_reissue_way_pred']),
            (p['ipctrl_pcgen_chgflw_pcload'], p['ipctrl_pcgen_chgflw_pc'],
             p['ipctrl_pcgen_chgflw_way_pred']),
            (p['ifctrl_pcgen_chgflw_vld'], p['ifctrl_pcgen_pcload_pc'], p['ifctrl_pcgen_way_pred']),
            (p['ifctrl_pcgen_reissue_pcload'], self.pc, p['ifctrl_pcgen_way_pred']),
        ]
        winner = next((i for i, event in enumerate(events) if event[0]), None)
        changing = winner is not None
        non_l0 = any(event[0] for i, event in enumerate(events) if i != 8)
        short = non_l0 or p['ifctrl_pcgen_chgflw_no_stall_mask']
        increment = self.pc if p['ifctrl_pcgen_reissue_pcload'] else ((self.pc // 16 + 1) * 16) & 0xffffffff
        fast_events = events[3:8] + [(p['ifctrl_pcgen_chgflw_no_stall_mask'],
                                    p['ifctrl_pcgen_pcload_pc'], 0)]
        bus = next((event[1] for event in fast_events if event[0]), increment)
        enabled = p['cpurst_b'] and p['cp0_yy_clk_en'] and not p['vector_pcgen_reset_on']
        advance = enabled and not p['ifctrl_pcgen_stall']
        if not p['cp0_ifu_iwpe']:
            prediction = 3
        elif changing:
            prediction = events[winner][2]
        elif p['ifctrl_pcgen_stall'] or self.stalled:
            prediction = self.way
        elif self.redirected and (increment // 16) % 4:
            prediction = self.redirect_way
        elif (increment // 16) % 4 >= 2:
            prediction = p['ipctrl_pcgen_inner_way_pred']
        else:
            prediction = (p['ipctrl_pcgen_inner_way1'] * 2 + p['ipctrl_pcgen_inner_way0']) or 3
        debug_enter = p['rtu_ifu_dbgon'] and not self.debug
        high = any(event[0] for event in events[:4])
        above_ib = any(event[0] for event in events[:5])
        above_ip = any(event[0] for event in events[:6])
        global_cancel = high or p['rtu_ifu_flush'] or debug_enter
        ip_cancel = above_ip or p['rtu_ifu_flush'] or debug_enter
        o = {}

        def outputs(value, *names):
            for name in names:
                o[name] = int(value)

        outputs(self.pc, 'pcgen_ifctrl_pc', 'pcgen_ifdp_pc', 'pcgen_l0_btb_if_pc', 'ifu_had_fetch_pc')
        outputs(increment, 'pcgen_ifdp_inc_pc')
        outputs(self.way, 'pcgen_ifctrl_way_pred', 'pcgen_ifdp_way_pred')
        outputs(self.way_stalled, 'pcgen_ifctrl_way_pred_stall')
        outputs(any(event[0] for event in events[:3]), 'pcgen_ifctrl_reissue')
        outputs(non_l0 or p['rtu_ifu_flush'] or debug_enter, 'pcgen_ifctrl_cancel')
        outputs(ip_cancel, 'pcgen_ipctrl_cancel')
        outputs(ip_cancel or p['lbuf_pcgen_vld_mask'] or p['ipctrl_pcgen_chk_err_reissue'] or
                (p['ipctrl_pcgen_chgflw_pcload'] and not p['ipctrl_pcgen_if_stall']),
                'pcgen_ifctrl_pipe_cancel')
        outputs(above_ib or p['rtu_ifu_flush'] or debug_enter or p['lbuf_pcgen_vld_mask'] or
                (p['ibctrl_pcgen_pcload'] and not p['ibctrl_pcgen_ip_stall']), 'pcgen_ipctrl_pipe_cancel')
        outputs(global_cancel, 'pcgen_ibctrl_cancel', 'pcgen_ibctrl_ibuf_flush')
        outputs(global_cancel or (p['ifctrl_pcgen_ins_icache_inv_done'] and not p['lbuf_pcgen_active']),
                'pcgen_ibctrl_lbuf_flush')
        outputs(p['iu_ifu_chgflw_vld'], 'pcgen_ibctrl_bju_chgflw')
        outputs(above_ib, 'pcgen_addrgen_cancel')
        outputs(changing, 'pcgen_l1_refill_chgflw', 'pcgen_ipb_chgflw', 'pcgen_bht_chgflw',
                'pcgen_btb_chgflw', 'pcgen_debug_chgflw')
        outputs(short, 'pcgen_bht_chgflw_short', 'pcgen_btb_chgflw_short')
        outputs(bus, 'pcgen_icache_if_index', 'pcgen_debug_pcbus')
        outputs(prediction, 'pcgen_icache_if_way_pred')
        outputs(enabled and changing, 'pcgen_icache_if_chgflw')
        outputs(enabled and short, 'pcgen_icache_if_chgflw_short')
        outputs(advance, 'pcgen_icache_if_seq_data_req')
        outputs(enabled and not p['ifctrl_pcgen_stall_short'], 'pcgen_icache_if_seq_data_req_short')
        outputs(advance and (bus // 16) % 4 == 0, 'pcgen_icache_if_seq_tag_req')
        outputs(enabled and (short or not p['ifctrl_pcgen_stall_short']), 'pcgen_icache_if_gateclk_en')
        first_bank = 0
        if winner == 7 and p['ipctrl_pcgen_branch_taken'] and p['ipctrl_pcgen_taken_pc'] == events[7][1]:
            first_bank = (events[7][1] // 4) % 4
        for bank in range(4):
            outputs(enabled and changing and (3-bank) >= first_bank, f'pcgen_icache_if_chgflw_bank{bank}')
        outputs((self.pc // 2) % 128, 'pcgen_bht_ifpc')
        outputs((bus // 16) % 1024, 'pcgen_bht_pcindex', 'pcgen_btb_index')
        outputs((self.pc // 128) % 2 != (increment // 128) % 2, 'pcgen_bht_seq_read')
        outputs(p['ifctrl_pcgen_stall'] or not enabled, 'pcgen_btb_stall')
        outputs(p['ifctrl_pcgen_stall_short'] or not enabled, 'pcgen_btb_stall_short')
        outputs(high, 'pcgen_btb_chgflw_higher_than_addrgen')
        outputs(above_ip, 'pcgen_btb_chgflw_higher_than_ip')
        outputs(non_l0, 'pcgen_btb_chgflw_higher_than_if')
        outputs(above_ib or p['ipctrl_pcgen_branch_mistaken'] or p['ipctrl_pcgen_reissue_pcload'] or
                p['ifctrl_pcgen_reissue_pcload'], 'pcgen_l0_btb_chgflw_mask')
        outputs(p['ifctrl_pcgen_chgflw_vld'] or p['ipctrl_pcgen_branch_taken'] or
                p['ibctrl_pcgen_pcload_vld'] or p['iu_ifu_chgflw_vld'], 'pcgen_l0_btb_chgflw_vld')
        if p['ibctrl_pcgen_pcload']:
            l0_pc = p['ibctrl_pcgen_pc']
        elif p['ipctrl_pcgen_branch_taken']:
            l0_pc = p['ipctrl_pcgen_taken_pc']
        elif p['ifctrl_pcgen_chgflw_no_stall_mask']:
            l0_pc = p['ifctrl_pcgen_pcload_pc']
        else:
            l0_pc = increment
        outputs(l0_pc, 'pcgen_l0_btb_chgflw_pc')
        outputs((self.pc // 16) % (2**17), 'pcgen_sfp_pc')
        return o, (events, winner, advance, increment, prediction)

    def tick(self, p):
        if not p['cpurst_b']:
            self.reset()
            return
        _, (events, winner, advance, increment, prediction) = self.evaluate(p)
        if winner is not None:
            self.pc = events[winner][1]
            self.redirect_way = events[winner][2]
            self.redirected = 1
        elif advance:
            self.pc = increment
            self.redirect_way = 3
            self.redirected = 0
        self.stalled = p['ifctrl_pcgen_stall']
        self.debug = p['rtu_ifu_dbgon']
        self.way = prediction
        self.way_stalled = int(prediction == 0)
