/*Copyright 2019-2021 T-Head Semiconductor Co., Ltd.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// SPDX-License-Identifier: Apache-2.0
// RV32I adaptation of the stage control in T-Head ct_ifu_ifctrl.v (2019-2021).
// Cache arrays have no independent fetch/miss scheduler in this pipeline.
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_ifctrl (
  input  wire        forever_cpuclk,
  input  wire        cpurst_b,
  input  wire        cp0_yy_clk_en,
  input  wire        cp0_ifu_no_op_req,
  input  wire        cp0_ifu_icache_en,
  input  wire        cp0_ifu_btb_en,
  input  wire        hpcp_ifu_cnt_en,
  input  wire        rtu_ifu_dbgon,
  input  wire        frontend_init_done,
  input  wire        maintenance_busy,
  input  wire        lbuf_ifctrl_active,
  // Accepted redirect ABOVE IF L0/reissue; never connect pcgen_ifctrl_cancel here.
  input  wire        frontend_redirect,
  input  wire        pcgen_ifctrl_pipe_cancel,
  input  wire        pcgen_ifctrl_reissue,
  input  wire        control_ifctrl_reissue,
  input  wire [31:0] pcgen_ifctrl_pc,
  input  wire [31:0] pcgen_icache_if_index,
  input  wire [ 1:0] pcgen_icache_if_way_pred,
  input  wire [ 4:0] region_ifctrl_attr,
  input  wire        ipctrl_ifctrl_stall,
  input  wire        ipctrl_ifctrl_bht_stall,
  input  wire        btb_ifctrl_ready,
  // Persistent owner requests. Only grant permits an array access.
  input  wire        maintenance_array_req,
  input  wire        refill_array_req,
  input  wire        ipb_array_req,
  output wire [ 3:0] ifctrl_array_grant,
  output wire        ifctrl_maintenance_grant,
  output wire        ifctrl_refill_grant,
  output wire        ifctrl_ipb_grant,
  output wire        ifctrl_array_fetch,
  output wire [31:0] ifctrl_array_pc,
  output wire [ 1:0] ifctrl_array_way,
  // A live critical-block response is held by refill until ready, independent
  // of refill writes. An old transaction with the same PC is NOT live.
  input  wire        l1_refill_ifctrl_active,
  input  wire        l1_refill_ifctrl_live,
  input  wire        l1_refill_ifctrl_vld,
  input  wire [31:0] l1_refill_ifctrl_pc,
  output wire        ifctrl_l1_refill_ready,
  output wire        ifctrl_l1_refill_cancel,
  // IFDP presents either the current SRAM response or its saved copy.
  input  wire        ifdp_ifctrl_fault,
  input  wire        ifdp_ifctrl_l0_vld,
  input  wire [31:0] ifdp_ifctrl_l0_target,
  input  wire [ 1:0] ifdp_ifctrl_l0_way,
  output wire        ifctrl_ifdp_issue,
  output wire [31:0] ifctrl_ifdp_issue_pc,
  output wire [ 1:0] ifctrl_ifdp_issue_way,
  output wire [ 1:0] ifctrl_ifdp_issue_kind,
  output wire        ifctrl_ifdp_hold,
  output wire        ifctrl_ifdp_held,
  output wire        ifctrl_ifdp_pipedown,
  output wire        ifctrl_ifdp_l0_accept,
  output wire        ifctrl_ipctrl_vld,
  output wire        ifctrl_ipctrl_if_pcload,
  output wire        ifctrl_pcgen_stall,
  output wire        ifctrl_pcgen_stall_short,
  output wire        ifctrl_pcgen_reissue_pcload,
  output wire        ifctrl_pcgen_chgflw_vld,
  output wire        ifctrl_pcgen_chgflw_no_stall_mask,
  output wire [31:0] ifctrl_pcgen_pcload_pc,
  output wire [ 1:0] ifctrl_pcgen_way_pred,
  output wire        ifctrl_btb_lookup_vld,
  output wire [31:0] ifctrl_btb_lookup_pc,
  output wire        ifctrl_bht_read,
  output wire [ 9:0] ifctrl_bht_pcindex,
  output wire        ifctrl_bht_pipedown,
  output wire        ifctrl_bht_stall,
  output wire        ifctrl_l0_btb_lookup_vld,
  output wire        ifctrl_l0_btb_accept,
  output wire        ifctrl_debug_if_vld,
  output wire        ifctrl_debug_if_stall,
  output wire        ifctrl_idle,
  output wire        ifu_hpcp_frontend_stall
);
  //----------------------------------------------------------------------------
  // Central declarations. q bits: IF valid, IP valid, response saved,
  // replay pending, IP's accepted L0 flag, performance event.
  //----------------------------------------------------------------------------
  localparam FLAG_COUNT = 6;
  localparam OWNER_COUNT = 4;
  localparam [FLAG_COUNT-1:0] RESET_FLAGS = 6'b001000;
  localparam [1:0] CACHE = 2'd0, FAULT = 2'd1, BYPASS = 2'd2, REFILL = 2'd3;
  genvar flag_index;
  genvar owner;
  reg  [ FLAG_COUNT-1:0] flag_q;
  wire [ FLAG_COUNT-1:0] flag_nxt;
  wire [ FLAG_COUNT-1:0] flag_en;
  wire [OWNER_COUNT-1:0] owner_req;
  wire                   delivery_enable;
  wire                   fetch_enable;
  wire                   kill_if;
  wire                   ip_ready;
  wire                   if_space;
  wire                   issue_fault;
  wire                   use_cache;
  wire                   predictor_ready;
  wire                   fetch_candidate;
  wire                   fetch_fire;
  wire                   forward_fire;
  wire                   issue_fire;
  wire                   l0_accept;
  wire                   replay_set;

  //----------------------------------------------------------------------------
  // Stage transfer and PC cursor. IP decides hit/miss/Way replay, never IF.
  //----------------------------------------------------------------------------
  assign delivery_enable = cpurst_b && cp0_yy_clk_en && frontend_init_done && !maintenance_busy &&
    !rtu_ifu_dbgon;
  assign fetch_enable = delivery_enable && !cp0_ifu_no_op_req && !lbuf_ifctrl_active;
  assign kill_if = frontend_redirect || pcgen_ifctrl_pipe_cancel || control_ifctrl_reissue;
  assign ip_ready = !ipctrl_ifctrl_stall && !ipctrl_ifctrl_bht_stall;
  assign ifctrl_ifdp_pipedown = flag_q[0] && delivery_enable && ip_ready && !kill_if;
  assign if_space = !flag_q[0] || ifctrl_ifdp_pipedown || kill_if;
  assign ifctrl_ifdp_hold = flag_q[0] && !flag_q[2] && !ifctrl_ifdp_pipedown && !kill_if;
  assign ifctrl_ifdp_held = flag_q[2];

  assign
    issue_fault = (|pcgen_icache_if_index[1:0]) || !region_ifctrl_attr[4] || !region_ifctrl_attr[0];
  assign use_cache = !issue_fault && region_ifctrl_attr[3] && cp0_ifu_icache_en;
  assign predictor_ready = !cp0_ifu_btb_en || btb_ifctrl_ready;
  assign fetch_candidate = fetch_enable && if_space && !pcgen_ifctrl_reissue &&
    !control_ifctrl_reissue && !l1_refill_ifctrl_active && (!use_cache || predictor_ready);
  assign owner_req = {
    fetch_candidate && use_cache, ipb_array_req, refill_array_req, maintenance_array_req
  };
  generate
    for (owner = 0; owner < OWNER_COUNT; owner = owner + 1) begin : g_owner
      if (owner == 0) begin : g_first
        assign ifctrl_array_grant[owner] = cpurst_b && cp0_yy_clk_en && owner_req[owner];
      end else begin : g_later
        assign ifctrl_array_grant[owner] = cpurst_b && cp0_yy_clk_en && owner_req[owner] &&
          !(|owner_req[owner-1:0]);
      end
    end
  endgenerate
  assign ifctrl_maintenance_grant = ifctrl_array_grant[0];
  assign ifctrl_refill_grant = ifctrl_array_grant[1];
  assign ifctrl_ipb_grant = ifctrl_array_grant[2];
  assign ifctrl_array_fetch = ifctrl_array_grant[3];
  assign ifctrl_array_pc = pcgen_icache_if_index;
  // Zero is a wait hint in C910. Retry reads both ways to avoid deadlock.
  assign ifctrl_array_way = (|pcgen_icache_if_way_pred) ? pcgen_icache_if_way_pred : 2'b11;
  assign fetch_fire = fetch_candidate && (!use_cache || ifctrl_array_fetch);

  assign ifctrl_l1_refill_ready = delivery_enable && if_space && flag_q[3] &&
    l1_refill_ifctrl_active && l1_refill_ifctrl_live && predictor_ready && !kill_if &&
    (l1_refill_ifctrl_pc[31:4] == pcgen_ifctrl_pc[31:4]);
  assign forward_fire = ifctrl_l1_refill_ready && l1_refill_ifctrl_vld;
  assign ifctrl_l1_refill_cancel = kill_if;
  assign issue_fire = fetch_fire || forward_fire;
  assign ifctrl_ifdp_issue = issue_fire;
  assign ifctrl_ifdp_issue_pc = forward_fire ? pcgen_ifctrl_pc : pcgen_icache_if_index;
  assign ifctrl_ifdp_issue_way = forward_fire ? 2'b01 : use_cache ? ifctrl_array_way : 2'b00;
  assign ifctrl_ifdp_issue_kind = forward_fire ? REFILL :
    issue_fault ? FAULT : use_cache ? CACHE : BYPASS;

  // L0 changes the next PC only when its source packet actually enters IP.
  // Short hints never create prediction consumption or historical state.
  assign l0_accept = ifctrl_ifdp_pipedown && !ifdp_ifctrl_fault && ifdp_ifctrl_l0_vld;
  assign ifctrl_pcgen_chgflw_vld = l0_accept;
  assign ifctrl_pcgen_chgflw_no_stall_mask = flag_q[0] && delivery_enable && !kill_if &&
    !flag_q[3] && !ifdp_ifctrl_fault && ifdp_ifctrl_l0_vld;
  assign ifctrl_pcgen_pcload_pc = ifdp_ifctrl_l0_target;
  assign ifctrl_pcgen_way_pred = l0_accept ? ifdp_ifctrl_l0_way : 2'b11;
  assign ifctrl_ifdp_l0_accept = l0_accept;
  assign ifctrl_l0_btb_accept = l0_accept;
  // A saved target has already entered PCGEN even if no array port was granted.
  assign ifctrl_pcgen_reissue_pcload = flag_q[3] && fetch_enable && !frontend_redirect &&
    !l1_refill_ifctrl_active;
  assign ifctrl_pcgen_stall = !fetch_fire;
  assign ifctrl_pcgen_stall_short = !fetch_fire;
  assign
    replay_set = frontend_redirect || pcgen_ifctrl_reissue || control_ifctrl_reissue || l0_accept;

  assign ifctrl_btb_lookup_vld = issue_fire && cp0_ifu_btb_en &&
    ((ifctrl_ifdp_issue_kind == CACHE) || forward_fire);
  assign ifctrl_btb_lookup_pc = ifctrl_ifdp_issue_pc;
  assign ifctrl_bht_read = issue_fire && ((ifctrl_ifdp_issue_kind == CACHE) || forward_fire);
  assign ifctrl_bht_pcindex = ifctrl_ifdp_issue_pc[13:4];
  assign ifctrl_bht_pipedown = ifctrl_ifdp_pipedown;
  // C910's stall qualifies query index/read-response tracking, not IP transfer.
  assign ifctrl_bht_stall = !ifctrl_bht_read;
  assign ifctrl_l0_btb_lookup_vld = flag_q[0] && !kill_if;

  //----------------------------------------------------------------------------
  // Next values and generated reset/enable storage
  //----------------------------------------------------------------------------
  assign flag_en = {
    1'b1,
    pcgen_ifctrl_pipe_cancel || ip_ready,
    1'b1,
    1'b1,
    pcgen_ifctrl_pipe_cancel || ip_ready,
    1'b1
  };
  assign flag_nxt[0] = issue_fire || (flag_q[0] && !kill_if && !ifctrl_ifdp_pipedown);
  assign flag_nxt[1] = !pcgen_ifctrl_pipe_cancel && ifctrl_ifdp_pipedown;
  assign flag_nxt[2] = !issue_fire && !kill_if && !ifctrl_ifdp_pipedown &&
    (flag_q[2] || ifctrl_ifdp_hold);
  assign flag_nxt[3] = !issue_fire && (replay_set || flag_q[3]);
  assign flag_nxt[4] = !pcgen_ifctrl_pipe_cancel && l0_accept;
  assign flag_nxt[5] = hpcp_ifu_cnt_en && delivery_enable && !cp0_ifu_no_op_req &&
    !lbuf_ifctrl_active && !ifctrl_ifdp_pipedown;
  generate
    for (flag_index = 0; flag_index < FLAG_COUNT; flag_index = flag_index + 1) begin : g_flag
      always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_flag
        if (!cpurst_b) begin
          flag_q[flag_index] <= RESET_FLAGS[flag_index];
        end else if (flag_en[flag_index]) begin
          flag_q[flag_index] <= flag_nxt[flag_index];
        end
      end
    end
  endgenerate
  assign ifctrl_ipctrl_vld       = flag_q[1];
  assign ifctrl_ipctrl_if_pcload = flag_q[4];
  assign ifctrl_debug_if_vld     = flag_q[0];
  assign ifctrl_debug_if_stall   = flag_q[0] && !ifctrl_ifdp_pipedown;
  assign ifctrl_idle             = !flag_q[0] && !flag_q[1];
  assign ifu_hpcp_frontend_stall = flag_q[5];
endmodule
