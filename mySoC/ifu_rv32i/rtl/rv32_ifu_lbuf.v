// SPDX-License-Identifier: Apache-2.0
// RV32I full-instruction adaptation of ct_ifu_lbuf.v (T-Head, 2019-2021).
// See doc/RV32I_C910_IFU_microarchitecture_spec_zh.md section 7.3 and 15.7.
//
// Structure kept from C910: the seven loop states and their duties, the two-entry
// loop record FIFO with its filled/ban/valid lifecycle, the front-branch and
// back-branch buffers, the front-branch body refill, the 16-entry create pointer,
// the 16-entry retire pointer, the self-maintained BHT select-array counters and
// the one-cycle change-flow pulse generators.
//
// C910 half-word machinery that collapses for RV32I:
//   - an entry is one complete 32 bit instruction, so there is no 32_start, no
//     six-half-word reassembly casez, no half_num, and no offset_less_15/16 pair
//     (all RV32I control transfers span whole words, so only "offset >= -16
//     instructions" is reachable and the two C910 tests are identical there);
//   - every pipedown lane is an instruction start, so C910's h0_vld shift of the
//     hn_* vectors disappears;
//   - all PC arithmetic is byte based: one instruction step is 4 bytes, where
//     C910's lbuf PC was in half-word units and stepped by 1/2.
// Signal names are C910's wherever the meaning is unchanged so that this file can
// be audited against ct_ifu_lbuf.v line by line. Unpacked arrays replace C910's
// per-instance wire banks where a generate block elaborates the same expression.
// Bit j of the hn_* vectors is pipedown lane j, lane 0 being the oldest.
//
// C910 gates every register bank with a gated_clk_cell. This core's
// rv32_ifu_clk_cell is a pass-through, so no clock cell is instantiated; a clock
// enable is folded into its always block as an extra guard only where it is a
// real functional gate (lbuf_sm_clk_en), and otherwise the C910 reset/clear/
// update priority chain already reproduces the enabled behaviour.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_lbuf (

  // Clock, reset and configuration
  input  wire         forever_cpuclk,
  input  wire         cpurst_b,
  input  wire         cp0_ifu_lbuf_en,

  // BHT interface
  input  wire [31:0]  bht_lbuf_pre_ntaken_result,
  input  wire [31:0]  bht_lbuf_pre_taken_result,
  input  wire [21:0]  bht_lbuf_vghr,
  output wire         lbuf_bht_active_state,
  output wire         lbuf_bht_con_br_taken,
  output wire         lbuf_bht_con_br_vld,

  // IBCTRL interface
  input  wire         ibctrl_lbuf_bju_mispred,
  input  wire         ibctrl_lbuf_create_vld,
  input  wire         ibctrl_lbuf_flush,
  input  wire         ibctrl_lbuf_retire_vld,
  output wire         lbuf_ibctrl_active_idle_flush,
  output reg  [31:0]  lbuf_ibctrl_chgflw_pc,
  output wire [ 1:0]  lbuf_ibctrl_chgflw_pred,
  output wire         lbuf_ibctrl_chgflw_vld,
  output wire         lbuf_ibctrl_lbuf_active,
  output wire         lbuf_ibctrl_stall,

  // IBDP fill interface
  input  wire [ 3:0]  ibdp_lbuf_inst_vld_num,
  input  wire [ 1:0]  ibdp_lbuf_bht_sel_array_result,
  input  wire [31:0]  ibdp_lbuf_con_br_cur_pc,
  input  wire [31:0]  ibdp_lbuf_con_br_offset,
  input  wire         ibdp_lbuf_con_br_taken,
  input  wire         ibdp_lbuf_inst0_vld,
  input  wire [31:0]  ibdp_lbuf_inst0_data,
  input  wire         ibdp_lbuf_inst0_con_br,
  input  wire         ibdp_lbuf_inst0_chgflw,
  input  wire         ibdp_lbuf_inst0_auipc,
  input  wire         ibdp_lbuf_inst0_fence,
  input  wire         ibdp_lbuf_inst0_bkpta,
  input  wire         ibdp_lbuf_inst0_bkptb,
  input  wire         ibdp_lbuf_inst1_vld,
  input  wire [31:0]  ibdp_lbuf_inst1_data,
  input  wire         ibdp_lbuf_inst1_con_br,
  input  wire         ibdp_lbuf_inst1_chgflw,
  input  wire         ibdp_lbuf_inst1_auipc,
  input  wire         ibdp_lbuf_inst1_fence,
  input  wire         ibdp_lbuf_inst1_bkpta,
  input  wire         ibdp_lbuf_inst1_bkptb,
  input  wire         ibdp_lbuf_inst2_vld,
  input  wire [31:0]  ibdp_lbuf_inst2_data,
  input  wire         ibdp_lbuf_inst2_con_br,
  input  wire         ibdp_lbuf_inst2_chgflw,
  input  wire         ibdp_lbuf_inst2_auipc,
  input  wire         ibdp_lbuf_inst2_fence,
  input  wire         ibdp_lbuf_inst2_bkpta,
  input  wire         ibdp_lbuf_inst2_bkptb,
  input  wire         ibdp_lbuf_inst3_vld,
  input  wire [31:0]  ibdp_lbuf_inst3_data,
  input  wire         ibdp_lbuf_inst3_con_br,
  input  wire         ibdp_lbuf_inst3_chgflw,
  input  wire         ibdp_lbuf_inst3_auipc,
  input  wire         ibdp_lbuf_inst3_fence,
  input  wire         ibdp_lbuf_inst3_bkpta,
  input  wire         ibdp_lbuf_inst3_bkptb,

  // IBDP replay interface
  output wire         lbuf_ibdp_inst0_valid,
  output wire [31:0]  lbuf_ibdp_inst0_data,
  output wire [31:0]  lbuf_ibdp_inst0_pc,
  output wire [31:0]  lbuf_ibdp_inst0_npc,
  output wire         lbuf_ibdp_inst0_front_br,
  output wire         lbuf_ibdp_inst0_back_br,
  output wire         lbuf_ibdp_inst0_fence,
  output wire         lbuf_ibdp_inst0_bkpta,
  output wire         lbuf_ibdp_inst0_bkptb,
  output wire         lbuf_ibdp_inst1_valid,
  output wire [31:0]  lbuf_ibdp_inst1_data,
  output wire [31:0]  lbuf_ibdp_inst1_pc,
  output wire [31:0]  lbuf_ibdp_inst1_npc,
  output wire         lbuf_ibdp_inst1_front_br,
  output wire         lbuf_ibdp_inst1_back_br,
  output wire         lbuf_ibdp_inst1_fence,
  output wire         lbuf_ibdp_inst1_bkpta,
  output wire         lbuf_ibdp_inst1_bkptb,
  output wire         lbuf_ibdp_inst2_valid,
  output wire [31:0]  lbuf_ibdp_inst2_data,
  output wire [31:0]  lbuf_ibdp_inst2_pc,
  output wire [31:0]  lbuf_ibdp_inst2_npc,
  output wire         lbuf_ibdp_inst2_front_br,
  output wire         lbuf_ibdp_inst2_back_br,
  output wire         lbuf_ibdp_inst2_fence,
  output wire         lbuf_ibdp_inst2_bkpta,
  output wire         lbuf_ibdp_inst2_bkptb,

  // IBUF / IFCTRL / IU interface
  input  wire         ibuf_lbuf_empty,
  input  wire         ifctrl_lbuf_ins_inv_on,
  input  wire         ifctrl_lbuf_inv_req,
  input  wire         iu_ifu_bht_check_vld,
  input  wire         iu_ifu_bht_condbr_taken,
  input  wire [31:0]  iu_ifu_cur_pc,

  // PCGEN interface
  output wire         lbuf_pcgen_active,
  output wire         lbuf_pcgen_vld_mask,

  // ADDRGEN interface
  output wire         lbuf_addrgen_active_state,
  output wire         lbuf_addrgen_cache_state,
  output wire         lbuf_addrgen_chgflw_mask,

  // PCFIFO interface
  output wire         lbuf_pcfifo_if_create_select,
  output wire [ 1:0]  lbuf_pcfifo_if_inst_bht_pre_result,
  output wire [ 1:0]  lbuf_pcfifo_if_inst_bht_sel_result,
  output wire [31:0]  lbuf_pcfifo_if_inst_cur_pc,
  output wire         lbuf_pcfifo_if_inst_pc_oper,
  output wire [31:0]  lbuf_pcfifo_if_inst_target_pc,
  output wire [21:0]  lbuf_pcfifo_if_inst_vghr,

  // IPDP interface
  output wire         lbuf_ipdp_lbuf_active,

  // Debug
  output wire [ 5:0]  lbuf_debug_st
);

  //------------------------------------------------------------------------------
  // Local parameters
  //------------------------------------------------------------------------------
  localparam ENTRY_NUM = 16;
  // C910's one-hot state encoding.
  localparam [5:0] IDLE         = 6'b000000;
  localparam [5:0] FILL         = 6'b000001;
  localparam [5:0] FRONT_BRANCH = 6'b000010;
  localparam [5:0] CACHE        = 6'b000100;
  localparam [5:0] ACTIVE       = 6'b001000;
  localparam [5:0] FRONT_FILL   = 6'b010000;
  localparam [5:0] FRONT_CACHE  = 6'b100000;

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  // Loop buffer state and running loop-body instruction count
  reg  [ 5:0] lbuf_cur_state;
  wire [ 5:0] lbuf_next_state;
  reg  [ 3:0] lbuf_cur_entry_num;
  wire        lbuf_sm_clk_en;

  // IB create handshake and con_br description of the pipedown group
  wire [ 3:0] hn_inst_vld;
  wire [ 3:0] hn_create_vld;
  wire [ 3:0] hn_con_br;
  wire [ 3:0] hn_front_br;
  wire [ 3:0] hn_back_br;
  wire [ 3:0] hn_chgflw;
  wire [ 3:0] hn_auipc;
  wire [ 3:0] hn_fence;
  wire [ 3:0] hn_bkpta;
  wire [ 3:0] hn_bkptb;
  wire [31:0] hn_data [0:3];
  wire [31:0] con_br_cur_pc;
  wire [31:0] con_br_offset;
  wire        con_br_taken;
  wire [ 1:0] con_br_inst_num;
  wire        back_br_taken;
  wire        back_br_check;
  wire [31:0] back_br_pc;
  wire [31:0] back_br_tar_pc;
  wire [ 3:0] back_br_offset;
  wire        back_br_offset_less_16;
  wire        front_br_taken;
  wire        front_br_check;
  wire [31:0] front_br_pc;
  wire [ 3:0] front_br_offset;
  wire        front_br_offset_less_16;
  wire        front_br_oversize;
  wire [ 3:0] front_cur_num;
  wire [ 3:0] front_target_num;
  wire [ 3:0] lbuf_target_entry_num;
  wire        loop_buffer_full;
  wire        inst_other_chgflw;
  wire        inst_auipc;
  wire        back_br_not_loop_end;
  wire        loop_end_br_not_taken;
  wire        front_br_more_than_one;
  wire        lbuf_create_vld;
  wire        fill_not_under_rule;
  wire        front_fill_not_under_rule;
  wire        front_fill_con_br_check;
  wire        front_br_under_rule;
  wire [ 3:0] front_vld_mask;
  wire [ 3:0] lbuf_cur_entry_num_pre;
  wire        back_br_hit_record_fifo_fill;
  wire        back_br_hit_filled_old_entry;
  wire        back_br_hit_filled_new_entry;
  wire        back_br_hit_record_fifo_unfill;
  wire        back_br_hit_unfill_old_entry;
  wire        back_br_hit_unfill_new_entry;
  wire        back_br_hit_lbuf_end;
  wire        back_br_hit_not_jump_lbuf_end;

  // Loop record FIFO
  reg         record_fifo_bit;
  reg         record_fifo_update_flop;
  reg  [31:0] new_record_cur_pc;
  reg  [31:0] new_record_target_pc;
  wire        record_fifo_update;
  wire        record_fifo_bit_update;
  wire        record_fifo_entry_ban_update;
  wire        record_fifo_entry_filled_update;
  wire        new_record_entry_out_loop;
  wire        old_entry_filled;
  wire        old_entry_ban;
  wire        old_entry_valid;
  wire [31:0] old_entry_pc;
  wire        new_entry_filled;
  wire        new_entry_ban;
  wire        new_entry_valid;
  wire [31:0] new_entry_pc;
  wire [ 3:0] new_entry_start_num;
  reg         record_fifo_entry0_valid;
  reg  [31:0] record_fifo_entry0_pc;
  reg  [ 3:0] record_fifo_entry0_offset;
  reg         record_fifo_entry0_ban;
  reg         record_fifo_entry0_filled;
  reg         record_fifo_entry1_valid;
  reg  [31:0] record_fifo_entry1_pc;
  reg  [ 3:0] record_fifo_entry1_offset;
  reg         record_fifo_entry1_ban;
  reg         record_fifo_entry1_filled;

  // Front branch buffer
  reg         front_entry_vld;
  reg  [31:0] front_entry_cur_pc;
  reg  [31:0] front_entry_target_pc;
  reg  [15:0] front_entry_update_pointer;
  reg  [15:0] front_entry_next_pointer;
  reg         front_entry_body_filled;
  reg         front_update_pre_br_taken;
  reg  [ 3:0] front_update_pre_offset;
  reg  [31:0] front_update_pre_cur_pc;
  reg  [15:0] front_update_pre_pointer;
  reg  [ 3:0] front_br_body_num;
  reg  [ 3:0] front_br_body_num_record;
  wire        front_entry_update;
  wire        front_update_pre_vld;
  wire        front_entry_body_filled_update;
  wire        front_update_br_taken;
  wire [ 3:0] front_update_offset;
  wire [31:0] front_update_cur_pc;
  wire [31:0] front_update_target_pc;
  wire [15:0] front_update_pointer;
  wire [15:0] front_update_next_pointer;
  wire [15:0] front_update_rot1;
  wire [15:0] front_update_rot2;
  wire [15:0] front_update_rot4;
  wire [15:0] front_update_rot8;
  wire [15:0] lbuf_front_br_pointer_pre;
  wire [ 3:0] front_br_body_num_pre;
  wire        front_br_body_num_update;
  wire        front_br_body_fill_finish;

  // Back branch buffer
  reg         back_entry_vld;
  reg  [ 3:0] back_entry_start_num;
  reg  [31:0] back_entry_cur_pc;
  reg  [31:0] back_entry_target_pc;
  reg         back_update_pre_vld_flop;
  reg  [31:0] back_update_pre_cur_pc;
  reg  [31:0] back_update_pre_tar_pc;
  wire        back_entry_update;
  wire        back_update_pre_vld;
  wire [31:0] back_update_cur_pc;
  wire [31:0] back_update_target_pc;
  wire [15:0] back_entry_update_pointer;

  // State entry strobes
  wire        fill_state_enter;
  wire        idle_cache_state_enter;
  wire        front_cache_active_state_enter;
  wire        active_state_enter;
  wire        front_fill_enter;
  wire        taken_front_branch_enter;
  wire        lbuf_fill_state;
  wire        front_branch_state;
  wire        front_fill_state;
  wire        lbuf_flush;
  wire        bju_mispred;
  wire        ins_inv_on;
  wire        ibuf_empty;
  wire        lbuf_retire_vld;

  // Create pointer
  reg  [15:0] lbuf_create_pointer;
  wire [15:0] create_pointer_pre;
  wire [15:0] lbuf_create_pointer_rot [0:3];

  // Entry array
  wire [15:0] entry_vld;
  wire [15:0] entry_front_br;
  wire [15:0] entry_back_br;
  wire [15:0] entry_fence;
  wire [15:0] entry_bkpta;
  wire [15:0] entry_bkptb;
  wire [ENTRY_NUM*32-1:0] entry_inst_data;
  wire [15:0] entry_create;
  wire [15:0] entry_create_front_br;
  wire [15:0] entry_create_back_br;
  wire [15:0] entry_create_fence;
  wire [15:0] entry_create_bkpta;
  wire [15:0] entry_create_bkptb;
  wire [ENTRY_NUM*32-1:0] entry_create_inst_data;

  // Retire pointer
  reg  [15:0] lbuf_retire_pointer;
  wire [15:0] lbuf_retire_pointer_rot [0:3];
  wire [15:0] lbuf_retire_pointer_pre;
  wire [15:0] lbuf_retire_pointer_branch_pre;
  wire [15:0] lbuf_retire_pointer_pop1_pre;
  wire [15:0] lbuf_retire_pointer_pop2_pre;
  wire [15:0] lbuf_retire_pointer_pop3_pre;

  // Replay slots
  wire [ 2:0] lbuf_pop_inst_valid;
  wire [ 2:0] lbuf_pop_inst_front_br;
  wire [ 2:0] lbuf_pop_inst_back_br;
  wire [ 2:0] lbuf_pop_inst_br;
  wire [ 2:0] lbuf_pop_inst_fence;
  wire [ 2:0] lbuf_pop_inst_bkpta;
  wire [ 2:0] lbuf_pop_inst_bkptb;
  wire [95:0] lbuf_pop_inst_data;
  wire [95:0] lbuf_pop_inst_pc;
  // C910's lbuf_pop_inst0/1/2_br_mask_vld, packed by replay slot.
  wire [ 2:0] lbuf_pop_inst_br_mask_vld;
  wire [15:0] lbuf_pop_inst0_retire_pointer_br_pre;
  wire [15:0] lbuf_pop_inst1_retire_pointer_br_pre;
  wire [15:0] lbuf_pop_inst2_retire_pointer_br_pre;
  wire [31:0] lbuf_pop_inst0_pc_br_pre;
  wire [31:0] lbuf_pop_inst1_pc_br_pre;
  wire [31:0] lbuf_pop_inst2_pc_br_pre;
  wire        lbuf_pop_branch_vld;
  wire        lbuf_pop_not_taken_back_br;
  wire        lbuf_pop_not_taken_front_br;
  wire        front_br_body_not_filled;
  wire        lbuf_pop_front_br;
  wire        lbuf_pop_con_br_inst;
  wire        lbuf_pop_con_br_taken;
  wire [31:0] lbuf_pop_con_br_cur_pc;
  wire [ 1:0] lbuf_pop_pre_result;
  wire [ 1:0] lbuf_pop_sel_result;
  wire [ 2:0] lbuf_pop_inst_con_br;

  // Replay PC
  reg  [31:0] lbuf_cur_pc;
  wire [31:0] loop_start_pc;
  wire [31:0] lbuf_pc_add_1;
  wire [31:0] lbuf_pc_add_2;
  wire [31:0] lbuf_pc_add_3;
  wire [31:0] lbuf_pc_pop1_pre;
  wire [31:0] lbuf_pc_pop2_pre;
  wire [31:0] lbuf_pc_pop3_pre;
  wire [31:0] lbuf_cur_pc_pre;
  wire [31:0] lbuf_cur_pc_branch_pre;

  // BHT interaction
  wire [13:0] vghr;
  wire [31:0] pre_taken_result;
  wire [31:0] pre_ntaken_result;
  wire [ 1:0] sel_array_result;
  reg  [ 1:0] front_br_sel_array_result;
  reg  [ 1:0] back_br_sel_array_result;
  wire [ 1:0] front_br_sel_array_result_pre;
  wire [ 1:0] back_br_sel_array_result_pre;
  wire        front_br_sel_array_record;
  wire        back_br_sel_array_record;
  wire        front_br_sel_array_update;
  wire        back_br_sel_array_update;
  wire [31:0] front_pre_array_result;
  wire [31:0] back_pre_array_result;
  reg  [ 1:0] front_br_bht_pre_result;
  reg  [ 1:0] back_br_bht_pre_result;
  wire        front_br_bht_result;
  wire        back_br_bht_result;
  wire        inst0_bht_result;
  wire        inst1_bht_result;
  wire        inst2_bht_result;

  // Change flow
  reg         active_ctc_record;
  reg         lbuf_stop_fetch_chgflw_vld;
  reg         active_idle_chgflw_vld;
  reg         active_front_fill_chgflw_vld;
  wire        lbuf_stop_fetch_chgflw_vld_pre;
  wire        active_idle_chgflw_vld_pre;
  wire        active_front_fill_chgflw_vld_pre;
  wire [31:0] active_idle_chgflw_pc_pre;
  wire [31:0] active_front_fill_chgflw_pc_pre;
  wire        lbuf_vld_mask;
  wire        chgflw_vld;

  genvar entry;
  genvar slot;

  //------------------------------------------------------------------------------
  // Aliases to the C910 names of the stage boundary signals
  //------------------------------------------------------------------------------
  assign lbuf_flush      = ibctrl_lbuf_flush;
  assign bju_mispred     = ibctrl_lbuf_bju_mispred;
  assign ins_inv_on      = ifctrl_lbuf_ins_inv_on;
  assign ibuf_empty      = ibuf_lbuf_empty;
  assign lbuf_retire_vld = ibctrl_lbuf_retire_vld;
  assign con_br_taken    = ibdp_lbuf_con_br_taken;
  assign con_br_cur_pc   = ibdp_lbuf_con_br_cur_pc;
  // IBDP hands over a signed byte offset; C910 handed over a half-word offset.
  assign con_br_offset   = ibdp_lbuf_con_br_offset;
  assign sel_array_result = ibdp_lbuf_bht_sel_array_result;
  assign pre_taken_result = bht_lbuf_pre_taken_result;
  assign pre_ntaken_result = bht_lbuf_pre_ntaken_result;
  assign vghr[13:0]      = bht_lbuf_vghr[13:0];

  assign lbuf_fill_state   = lbuf_cur_state[5:0] == FILL;
  assign front_branch_state = lbuf_cur_state[5:0] == FRONT_BRANCH;
  assign front_fill_state  = lbuf_cur_state[5:0] == FRONT_FILL;
  assign back_entry_update_pointer[15:0] = 16'b1;

  //------------------------------------------------------------------------------
  // State machine
  //------------------------------------------------------------------------------
  // IDLE         : wait for the loop-end back branch
  // FILL         : duplicate the loop body into the entry array
  // FRONT_BRANCH : record front branch information
  // CACHE        : wait for the record to settle and for IBUF to drain
  // ACTIVE       : replay instructions out of the loop buffer
  // FRONT_FILL   : fill the front branch body that was skipped
  // FRONT_CACHE  : wait for IBUF to drain before the front-fill replay
  // C910 gates this register with lbuf_sm_clk_en; the condition is reproduced
  // here because rv32_ifu_clk_cell does not gate.
  assign lbuf_sm_clk_en = (lbuf_cur_state[5:0] != IDLE) || back_br_taken;

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_lbuf_cur_state
    if (!cpurst_b) begin
      lbuf_cur_state[5:0] <= IDLE;
    end else if (lbuf_flush || bju_mispred) begin
      lbuf_cur_state[5:0] <= IDLE;
    end else if (!cp0_ifu_lbuf_en) begin
      lbuf_cur_state[5:0] <= IDLE;
    end else if (lbuf_sm_clk_en) begin
      lbuf_cur_state[5:0] <= lbuf_next_state[5:0];
    end
  end

  // C910 priority order of the state transfer.
  assign lbuf_next_state[5:0] =
    (lbuf_cur_state[5:0] == IDLE) ?
      (back_br_hit_record_fifo_fill && !ins_inv_on) ? CACHE :
      (back_br_hit_record_fifo_unfill && !ins_inv_on) ? FILL : IDLE :
    (lbuf_cur_state[5:0] == FILL) ?
      fill_not_under_rule ? IDLE :
      back_br_hit_lbuf_end ? CACHE :
      front_br_under_rule ? FRONT_BRANCH : FILL :
    (lbuf_cur_state[5:0] == CACHE) ?
      (ibuf_empty && !ins_inv_on) ? ACTIVE : CACHE :
    (lbuf_cur_state[5:0] == FRONT_BRANCH) ? FILL :
    (lbuf_cur_state[5:0] == ACTIVE) ?
      front_br_body_not_filled ? FRONT_FILL :
      lbuf_pop_not_taken_back_br ? IDLE : ACTIVE :
    (lbuf_cur_state[5:0] == FRONT_FILL) ?
      front_fill_not_under_rule ? IDLE :
      back_br_hit_lbuf_end ? FRONT_CACHE : FRONT_FILL :
    (lbuf_cur_state[5:0] == FRONT_CACHE) ?
      (ibuf_empty && !ins_inv_on) ? ACTIVE : FRONT_CACHE : IDLE;

  //------------------------------------------------------------------------------
  // Fill control signal
  //------------------------------------------------------------------------------
  // IDLE: the currently seen back branch already has a filled and unbanned entry.
  assign back_br_hit_record_fifo_fill = ibctrl_lbuf_create_vld &&
    (back_br_hit_filled_old_entry || back_br_hit_filled_new_entry);
  assign back_br_hit_filled_old_entry = back_br_taken &&
    (back_br_pc[31:0] == old_entry_pc[31:0]) && old_entry_filled && !old_entry_ban &&
    old_entry_valid;
  assign back_br_hit_filled_new_entry = back_br_taken &&
    (back_br_pc[31:0] == new_entry_pc[31:0]) && new_entry_filled && !new_entry_ban &&
    new_entry_valid;

  // IDLE: the currently seen back branch has an entry that is still unfilled.
  assign back_br_hit_record_fifo_unfill = ibctrl_lbuf_create_vld &&
    (back_br_hit_unfill_old_entry || back_br_hit_unfill_new_entry);
  assign back_br_hit_unfill_old_entry = back_br_taken &&
    (back_br_pc[31:0] == old_entry_pc[31:0]) && !old_entry_filled && !old_entry_ban &&
    old_entry_valid;
  assign back_br_hit_unfill_new_entry = back_br_taken &&
    (back_br_pc[31:0] == new_entry_pc[31:0]) && !new_entry_filled && !new_entry_ban &&
    new_entry_valid;

  // FILL: the running back branch reached the recorded loop-end PC, fill done.
  assign back_br_hit_lbuf_end = back_br_taken &&
    (back_br_pc[31:0] == new_entry_pc[31:0]) && lbuf_create_vld;
  assign back_br_hit_not_jump_lbuf_end = !back_br_taken &&
    (back_br_pc[31:0] == new_entry_pc[31:0]) && lbuf_create_vld;

  // ACTIVE: the replayed loop-end back branch was not taken, leave the loop.
  assign lbuf_pop_not_taken_back_br = lbuf_retire_vld && !back_br_bht_result &&
    (lbuf_pop_inst_br_mask_vld[0] && lbuf_pop_inst_back_br[0] ||
     lbuf_pop_inst_br_mask_vld[1] && lbuf_pop_inst_back_br[1] ||
     lbuf_pop_inst_br_mask_vld[2] && lbuf_pop_inst_back_br[2]);

  // ACTIVE: the replayed front branch was not taken and its body is missing.
  assign front_br_body_not_filled = !front_entry_body_filled && front_entry_vld &&
    lbuf_pop_not_taken_front_br;
  assign lbuf_pop_not_taken_front_br = lbuf_retire_vld && !front_br_bht_result &&
    (lbuf_pop_inst_br_mask_vld[0] && lbuf_pop_inst_front_br[0] ||
     lbuf_pop_inst_br_mask_vld[1] && lbuf_pop_inst_front_br[1] ||
     lbuf_pop_inst_br_mask_vld[2] && lbuf_pop_inst_front_br[2]);
  assign front_br_body_fill_finish = front_br_body_num[3:0] == 4'b0000;

  //------------------------------------------------------------------------------
  // IB stage sends data to LBUF
  //------------------------------------------------------------------------------
  // The create handshake is only meaningful while duplicating the body.
  assign lbuf_create_vld = ibctrl_lbuf_create_vld &&
    (lbuf_cur_state[5:0] == FILL || lbuf_cur_state[5:0] == FRONT_FILL);

  // Bit j of every hn_ vector is pipedown lane j, lane 0 being the oldest. C910
  // kept an extra h0_vld shift here because a 32 bit instruction could start on
  // the second half word; RV32I has no such case.
  assign hn_inst_vld[3:0] = {ibdp_lbuf_inst3_vld, ibdp_lbuf_inst2_vld,
    ibdp_lbuf_inst1_vld, ibdp_lbuf_inst0_vld};
  assign hn_con_br[3:0] = {ibdp_lbuf_inst3_con_br, ibdp_lbuf_inst2_con_br,
    ibdp_lbuf_inst1_con_br, ibdp_lbuf_inst0_con_br};
  // The offset sign decides which con_br is the loop-end candidate.
  assign hn_front_br[3:0] = hn_con_br[3:0] & {4{~con_br_offset[31]}};
  assign hn_back_br[3:0] = hn_con_br[3:0] & {4{con_br_offset[31]}};
  assign hn_chgflw[3:0] = {ibdp_lbuf_inst3_chgflw, ibdp_lbuf_inst2_chgflw,
    ibdp_lbuf_inst1_chgflw, ibdp_lbuf_inst0_chgflw};
  assign hn_auipc[3:0] = {ibdp_lbuf_inst3_auipc, ibdp_lbuf_inst2_auipc,
    ibdp_lbuf_inst1_auipc, ibdp_lbuf_inst0_auipc};
  assign hn_fence[3:0] = {ibdp_lbuf_inst3_fence, ibdp_lbuf_inst2_fence,
    ibdp_lbuf_inst1_fence, ibdp_lbuf_inst0_fence};
  assign hn_bkpta[3:0] = {ibdp_lbuf_inst3_bkpta, ibdp_lbuf_inst2_bkpta,
    ibdp_lbuf_inst1_bkpta, ibdp_lbuf_inst0_bkpta};
  assign hn_bkptb[3:0] = {ibdp_lbuf_inst3_bkptb, ibdp_lbuf_inst2_bkptb,
    ibdp_lbuf_inst1_bkptb, ibdp_lbuf_inst0_bkptb};
  assign hn_data[0] = ibdp_lbuf_inst0_data;
  assign hn_data[1] = ibdp_lbuf_inst1_data;
  assign hn_data[2] = ibdp_lbuf_inst2_data;
  assign hn_data[3] = ibdp_lbuf_inst3_data;

  // Lanes that may be written this cycle. FRONT_FILL only takes the first
  // front_br_body_num lanes.
  assign hn_create_vld[3:0] = front_fill_state ?
    (hn_inst_vld[3:0] & front_vld_mask[3:0]) : hn_inst_vld[3:0];

  // Lane index of the pipedown con_br. C910 received this from IBDP as
  // con_br_half_num; the specified port list has no such input, so it is derived
  // from the per-lane con_br flags, lowest lane first.
  assign con_br_inst_num[1:0] = hn_con_br[0] ? 2'd0 :
    hn_con_br[1] ? 2'd1 : hn_con_br[2] ? 2'd2 : 2'd3;

  //------------------------------------------------------------------------------
  // Pipedown con_br classification
  //------------------------------------------------------------------------------
  // A negative offset conditional branch is the loop-end candidate; a positive
  // one is the front branch that leaves the loop body.
  assign back_br_taken  = (|hn_con_br[3:0]) && con_br_offset[31] && con_br_taken;
  assign back_br_check  = (|hn_con_br[3:0]) && con_br_offset[31];
  assign back_br_pc[31:0] = con_br_cur_pc[31:0];
  assign back_br_tar_pc[31:0] = con_br_cur_pc[31:0] + con_br_offset[31:0];

  assign front_br_taken = (|hn_con_br[3:0]) && !con_br_offset[31] && con_br_taken;
  assign front_br_check = (|hn_con_br[3:0]) && !con_br_offset[31];
  assign front_br_pc[31:0] = con_br_cur_pc[31:0];

  // C910 carried the distance in half words, so the low nibble was bits [3:0].
  // Here the distance is in instructions, i.e. byte offset bits [5:2]. C910's
  // offset_less_15 and offset_less_16 tests are identical for whole-word control
  // transfers, so only the less_16 form survives.
  assign back_br_offset[3:0] = (~con_br_offset[5:2]) + 4'b1;
  assign back_br_offset_less_16 = (&con_br_offset[31:6]) && (back_br_offset[3:0] != 4'b0000);
  assign front_br_offset[3:0] = con_br_offset[5:2];
  assign front_br_offset_less_16 = !(|con_br_offset[31:6]);

  assign front_cur_num[3:0] = lbuf_cur_entry_num[3:0] + {2'b0, con_br_inst_num[1:0]};
  assign front_target_num[3:0] = front_cur_num[3:0] + front_br_offset[3:0];
  assign front_br_oversize = !front_br_offset_less_16 ||
    (front_target_num[3:0] < front_cur_num[3:0]) ||
    (front_target_num[3:0] > back_entry_start_num[3:0]);

  assign inst_other_chgflw = front_fill_state ?
    |(hn_chgflw[3:0] & front_vld_mask[3:0]) : |hn_chgflw[3:0];
  assign inst_auipc = front_fill_state ?
    |(hn_auipc[3:0] & front_vld_mask[3:0]) : |hn_auipc[3:0];
  assign front_fill_con_br_check = front_fill_state ?
    |(hn_con_br[3:0] & front_vld_mask[3:0]) : |hn_con_br[3:0];
  assign back_br_not_loop_end = back_br_check &&
    (back_br_pc[31:0] != new_entry_pc[31:0]);
  assign loop_end_br_not_taken = back_br_check &&
    (back_br_pc[31:0] == new_entry_pc[31:0]) && !back_br_taken;
  assign front_br_more_than_one = front_br_check && front_entry_vld;
  assign lbuf_target_entry_num[3:0] =
    lbuf_cur_entry_num[3:0] + ibdp_lbuf_inst_vld_num[3:0];
  assign loop_buffer_full = lbuf_target_entry_num[3:0] < lbuf_cur_entry_num[3:0];

  assign fill_not_under_rule = lbuf_create_vld &&
    (inst_other_chgflw || inst_auipc || back_br_not_loop_end || front_br_more_than_one ||
     loop_buffer_full || loop_end_br_not_taken ||
     (front_br_check && front_br_oversize));
  assign front_fill_not_under_rule = lbuf_create_vld &&
    (inst_other_chgflw || inst_auipc || front_fill_con_br_check) ||
    back_br_hit_not_jump_lbuf_end;

  assign front_br_under_rule = front_br_check && !front_br_oversize && lbuf_create_vld;

  //------------------------------------------------------------------------------
  // Loop buffer current entry number
  //------------------------------------------------------------------------------
  // Running count of the instructions duplicated in this fill attempt, used only
  // for the fill rules. Values are positions modulo the 16 entries.
  assign lbuf_cur_entry_num_pre = front_br_taken ?
    front_target_num[3:0] : lbuf_target_entry_num[3:0];

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_lbuf_cur_entry_num
    if (!cpurst_b) begin
      lbuf_cur_entry_num[3:0] <= 4'b0;
    end else if (lbuf_flush) begin
      lbuf_cur_entry_num[3:0] <= 4'b0;
    end else if (fill_state_enter) begin
      lbuf_cur_entry_num[3:0] <= 4'b0;
    end else if (lbuf_fill_state && lbuf_create_vld) begin
      lbuf_cur_entry_num[3:0] <= lbuf_cur_entry_num_pre[3:0];
    end
  end

  //------------------------------------------------------------------------------
  // Loop record FIFO
  //------------------------------------------------------------------------------
  // Entry0 / Entry1: cur_pc[31:0] | offset[3:0] | ban | filled | valid.
  assign old_entry_filled = record_fifo_bit ? record_fifo_entry1_filled :
    record_fifo_entry0_filled;
  assign old_entry_ban = record_fifo_bit ? record_fifo_entry1_ban : record_fifo_entry0_ban;
  assign old_entry_valid = record_fifo_bit ? record_fifo_entry1_valid :
    record_fifo_entry0_valid;
  assign old_entry_pc[31:0] = record_fifo_bit ? record_fifo_entry1_pc[31:0] :
    record_fifo_entry0_pc[31:0];

  assign new_entry_filled = !record_fifo_bit ? record_fifo_entry1_filled :
    record_fifo_entry0_filled;
  assign new_entry_ban = !record_fifo_bit ? record_fifo_entry1_ban : record_fifo_entry0_ban;
  assign new_entry_valid = !record_fifo_bit ? record_fifo_entry1_valid :
    record_fifo_entry0_valid;
  assign new_entry_pc[31:0] = !record_fifo_bit ? record_fifo_entry1_pc[31:0] :
    record_fifo_entry0_pc[31:0];

  assign new_entry_start_num[3:0] = back_br_hit_unfill_new_entry ?
    (!record_fifo_bit ? record_fifo_entry1_offset[3:0] : record_fifo_entry0_offset[3:0]) :
    (record_fifo_bit ? record_fifo_entry1_offset[3:0] : record_fifo_entry0_offset[3:0]);

  // A new back branch is only recorded on a negated distance that still wraps
  // inside the 16 entries and does not hit either live entry.
  assign record_fifo_update = ibctrl_lbuf_create_vld && cp0_ifu_lbuf_en && back_br_taken &&
    back_br_offset_less_16 && (lbuf_cur_state[5:0] == IDLE) &&
    (!(back_br_pc[31:0] == record_fifo_entry0_pc[31:0]) || !record_fifo_entry0_valid) &&
    (!(back_br_pc[31:0] == record_fifo_entry1_pc[31:0]) || !record_fifo_entry1_valid);

  // The pointer is toggled when a new entry is allocated, or when the current
  // back branch re-hits the live entry that is not banned.
  assign record_fifo_bit_update = ibctrl_lbuf_create_vld && cp0_ifu_lbuf_en && back_br_taken &&
    back_br_offset_less_16 && (lbuf_cur_state[5:0] == IDLE) &&
    (((!(back_br_pc[31:0] == record_fifo_entry0_pc[31:0]) || !record_fifo_entry0_valid) &&
      (!(back_br_pc[31:0] == record_fifo_entry1_pc[31:0]) || !record_fifo_entry1_valid)) ||
     ((back_br_pc[31:0] == record_fifo_entry0_pc[31:0]) && record_fifo_entry0_valid &&
      !record_fifo_entry0_ban && !record_fifo_bit) ||
     ((back_br_pc[31:0] == record_fifo_entry1_pc[31:0]) && record_fifo_entry1_valid &&
      !record_fifo_entry1_ban && record_fifo_bit));

  // A failed fill bans the entry being built so that the same loop is not
  // recognised again from the same record.
  assign record_fifo_entry_ban_update = (lbuf_cur_state[5:0] == FILL) && fill_not_under_rule ||
    (lbuf_cur_state[5:0] == FRONT_FILL) && front_fill_not_under_rule ||
    new_record_entry_out_loop;
  assign record_fifo_entry_filled_update = (lbuf_cur_state[5:0] == FILL) &&
    back_br_hit_lbuf_end;

  // The new back branch and the old record overlap in the wrong direction: the
  // old loop end lies inside the new loop, so the old record must be banned.
  assign new_record_entry_out_loop = record_fifo_update_flop && old_entry_valid &&
    (old_entry_pc[31:0] < new_record_cur_pc[31:0]) &&
    (old_entry_pc[31:0] > new_record_target_pc[31:0]);

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_record_fifo_update_flop
    if (!cpurst_b) begin
      record_fifo_update_flop <= 1'b0;
    end else if (lbuf_flush) begin
      record_fifo_update_flop <= 1'b0;
    end else begin
      record_fifo_update_flop <= record_fifo_update;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_new_record_pc
    if (!cpurst_b) begin
      new_record_cur_pc[31:0] <= 32'b0;
      new_record_target_pc[31:0] <= 32'b0;
    end else if (lbuf_flush) begin
      new_record_cur_pc[31:0] <= 32'b0;
      new_record_target_pc[31:0] <= 32'b0;
    end else if (record_fifo_update) begin
      new_record_cur_pc[31:0] <= con_br_cur_pc[31:0];
      new_record_target_pc[31:0] <= con_br_cur_pc[31:0] -
        {26'b0, back_br_offset[3:0], 2'b00};
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_record_fifo_bit
    if (!cpurst_b) begin
      record_fifo_bit <= 1'b0;
    end else if (lbuf_flush) begin
      record_fifo_bit <= 1'b0;
    end else if (record_fifo_bit_update) begin
      record_fifo_bit <= ~record_fifo_bit;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_record_fifo_entry0
    if (!cpurst_b) begin
      record_fifo_entry0_valid <= 1'b0;
      record_fifo_entry0_pc[31:0] <= 32'b0;
      record_fifo_entry0_offset[3:0] <= 4'b0;
    end else if (lbuf_flush) begin
      record_fifo_entry0_valid <= 1'b0;
      record_fifo_entry0_pc[31:0] <= 32'b0;
      record_fifo_entry0_offset[3:0] <= 4'b0;
    end else if (record_fifo_update && !record_fifo_bit) begin
      record_fifo_entry0_valid <= 1'b1;
      record_fifo_entry0_pc[31:0] <= con_br_cur_pc[31:0];
      record_fifo_entry0_offset[3:0] <= back_br_offset[3:0];
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_record_fifo_entry0_ban
    if (!cpurst_b) begin
      record_fifo_entry0_ban <= 1'b0;
    end else if (lbuf_flush) begin
      record_fifo_entry0_ban <= 1'b0;
    end else if (record_fifo_update && !record_fifo_bit) begin
      record_fifo_entry0_ban <= 1'b0;
    end else if (record_fifo_entry_ban_update && record_fifo_bit) begin
      record_fifo_entry0_ban <= 1'b1;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_record_fifo_entry0_filled
    if (!cpurst_b) begin
      record_fifo_entry0_filled <= 1'b0;
    end else if (lbuf_flush) begin
      record_fifo_entry0_filled <= 1'b0;
    end else if (fill_state_enter || record_fifo_update) begin
      record_fifo_entry0_filled <= 1'b0;
    end else if (record_fifo_entry_filled_update && record_fifo_bit) begin
      record_fifo_entry0_filled <= 1'b1;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_record_fifo_entry1
    if (!cpurst_b) begin
      record_fifo_entry1_valid <= 1'b0;
      record_fifo_entry1_pc[31:0] <= 32'b0;
      record_fifo_entry1_offset[3:0] <= 4'b0;
    end else if (lbuf_flush) begin
      record_fifo_entry1_valid <= 1'b0;
      record_fifo_entry1_pc[31:0] <= 32'b0;
      record_fifo_entry1_offset[3:0] <= 4'b0;
    end else if (record_fifo_update && record_fifo_bit) begin
      record_fifo_entry1_valid <= 1'b1;
      record_fifo_entry1_pc[31:0] <= con_br_cur_pc[31:0];
      record_fifo_entry1_offset[3:0] <= back_br_offset[3:0];
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_record_fifo_entry1_ban
    if (!cpurst_b) begin
      record_fifo_entry1_ban <= 1'b0;
    end else if (lbuf_flush) begin
      record_fifo_entry1_ban <= 1'b0;
    end else if (record_fifo_update && record_fifo_bit) begin
      record_fifo_entry1_ban <= 1'b0;
    end else if (record_fifo_entry_ban_update && !record_fifo_bit) begin
      record_fifo_entry1_ban <= 1'b1;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_record_fifo_entry1_filled
    if (!cpurst_b) begin
      record_fifo_entry1_filled <= 1'b0;
    end else if (lbuf_flush) begin
      record_fifo_entry1_filled <= 1'b0;
    end else if (fill_state_enter || record_fifo_update) begin
      record_fifo_entry1_filled <= 1'b0;
    end else if (record_fifo_entry_filled_update && !record_fifo_bit) begin
      record_fifo_entry1_filled <= 1'b1;
    end
  end

  //------------------------------------------------------------------------------
  // State entry strobes
  //------------------------------------------------------------------------------
  assign fill_state_enter = (lbuf_cur_state[5:0] == IDLE) &&
    back_br_hit_record_fifo_unfill;
  assign idle_cache_state_enter = (lbuf_cur_state[5:0] == IDLE) &&
    back_br_hit_record_fifo_fill;
  assign front_cache_active_state_enter = (lbuf_cur_state[5:0] == FRONT_CACHE) &&
    ibuf_empty;
  assign active_state_enter = ((lbuf_cur_state[5:0] == CACHE) ||
    (lbuf_cur_state[5:0] == FRONT_CACHE)) && ibuf_empty;
  assign front_fill_enter = (lbuf_cur_state[5:0] == ACTIVE) && front_br_body_not_filled;
  assign taken_front_branch_enter = (lbuf_cur_state[5:0] == FRONT_BRANCH) &&
    front_update_br_taken;

  //------------------------------------------------------------------------------
  // Front branch buffer
  //------------------------------------------------------------------------------
  assign front_entry_update = front_branch_state;
  assign front_entry_body_filled_update = (lbuf_cur_state[5:0] == FILL) &&
    front_br_check && !front_br_taken && lbuf_create_vld ||
    (lbuf_cur_state[5:0] == FRONT_FILL) && front_br_body_fill_finish ||
    (lbuf_cur_state[5:0] == FRONT_CACHE) && front_br_body_fill_finish;

  assign front_update_br_taken = front_update_pre_br_taken;
  assign front_update_offset[3:0] = front_update_pre_offset[3:0];
  assign front_update_cur_pc[31:0] = front_update_pre_cur_pc[31:0];
  assign front_update_target_pc[31:0] = front_update_pre_cur_pc[31:0] +
    {26'b0, front_update_pre_offset[3:0], 2'b00};

  // C910 rotated the one-hot create pointer by the front branch distance; the
  // 16 entry case is written here as an equivalent 4 stage barrel rotate.
  assign front_update_rot1[15:0] = front_update_pre_offset[0] ?
    {front_update_pre_pointer[14:0], front_update_pre_pointer[15]} :
    front_update_pre_pointer[15:0];
  assign front_update_rot2[15:0] = front_update_pre_offset[1] ?
    {front_update_rot1[13:0], front_update_rot1[15:14]} : front_update_rot1[15:0];
  assign front_update_rot4[15:0] = front_update_pre_offset[2] ?
    {front_update_rot2[11:0], front_update_rot2[15:12]} : front_update_rot2[15:0];
  assign front_update_rot8[15:0] = front_update_pre_offset[3] ?
    {front_update_rot4[7:0], front_update_rot4[15:8]} : front_update_rot4[15:0];
  assign front_update_pointer[15:0] = front_update_rot8[15:0];

  // One instruction past the front branch: every RV32I instruction is one word,
  // where C910 rotated by two half words for a 32 bit instruction.
  assign front_update_next_pointer[15:0] =
    {front_update_pre_pointer[14:0], front_update_pre_pointer[15]};

  assign front_update_pre_vld = (lbuf_cur_state[5:0] == FILL) && front_br_check &&
    !front_br_oversize && ibctrl_lbuf_create_vld;

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_front_update_pre
    if (!cpurst_b) begin
      front_update_pre_br_taken <= 1'b0;
      front_update_pre_offset[3:0] <= 4'b0;
      front_update_pre_cur_pc[31:0] <= 32'b0;
      front_update_pre_pointer[15:0] <= 16'b0;
    end else if (lbuf_flush) begin
      front_update_pre_br_taken <= 1'b0;
      front_update_pre_offset[3:0] <= 4'b0;
      front_update_pre_cur_pc[31:0] <= 32'b0;
      front_update_pre_pointer[15:0] <= 16'b0;
    end else if (front_update_pre_vld) begin
      front_update_pre_br_taken <= front_br_taken;
      front_update_pre_offset[3:0] <= front_br_offset[3:0];
      front_update_pre_cur_pc[31:0] <= front_br_pc[31:0];
      front_update_pre_pointer[15:0] <= lbuf_front_br_pointer_pre[15:0];
    end
  end

  // Entry the front branch itself lands on. C910 rotated by con_br_half_num.
  assign lbuf_front_br_pointer_pre[15:0] =
    (con_br_inst_num[1:0] == 2'd0) ? lbuf_create_pointer_rot[0][15:0] :
    (con_br_inst_num[1:0] == 2'd1) ? lbuf_create_pointer_rot[1][15:0] :
    (con_br_inst_num[1:0] == 2'd2) ? lbuf_create_pointer_rot[2][15:0] :
    lbuf_create_pointer_rot[3][15:0];

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_front_entry
    if (!cpurst_b) begin
      front_entry_vld <= 1'b0;
      front_entry_cur_pc[31:0] <= 32'b0;
      front_entry_target_pc[31:0] <= 32'b0;
      front_entry_update_pointer[15:0] <= 16'b1;
      front_entry_next_pointer[15:0] <= 16'b1;
    end else if (lbuf_flush) begin
      front_entry_vld <= 1'b0;
      front_entry_cur_pc[31:0] <= 32'b0;
      front_entry_target_pc[31:0] <= 32'b0;
      front_entry_update_pointer[15:0] <= 16'b1;
      front_entry_next_pointer[15:0] <= 16'b1;
    end else if (fill_state_enter) begin
      front_entry_vld <= 1'b0;
      front_entry_cur_pc[31:0] <= 32'b0;
      front_entry_target_pc[31:0] <= 32'b0;
      front_entry_update_pointer[15:0] <= 16'b1;
      front_entry_next_pointer[15:0] <= 16'b1;
    end else if (front_entry_update) begin
      front_entry_vld <= 1'b1;
      front_entry_cur_pc[31:0] <= front_update_cur_pc[31:0];
      front_entry_target_pc[31:0] <= front_update_target_pc[31:0];
      front_entry_update_pointer[15:0] <= front_update_pointer[15:0];
      front_entry_next_pointer[15:0] <= front_update_next_pointer[15:0];
    end
  end

  // Entering FILL clears the bit; the normal sequential fill sets it when the
  // front branch falls through, and the body refill sets it when it completes.
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_front_entry_body_filled
    if (!cpurst_b) begin
      front_entry_body_filled <= 1'b0;
    end else if (lbuf_flush) begin
      front_entry_body_filled <= 1'b0;
    end else if (fill_state_enter) begin
      front_entry_body_filled <= 1'b0;
    end else if (front_entry_body_filled_update) begin
      front_entry_body_filled <= 1'b1;
    end
  end

  //------------------------------------------------------------------------------
  // Front branch body number
  //------------------------------------------------------------------------------
  // Number of instructions between the front branch and its target that still
  // have to be duplicated. C910 counted half words and subtracted 2 for a 32 bit
  // branch; here the count is in instructions and one is subtracted.
  assign front_br_body_num_pre[3:0] = (front_branch_state && front_update_br_taken) ?
    (front_update_offset[3:0] - 4'b0001) :
    (front_fill_state && lbuf_create_vld) ?
    ((ibdp_lbuf_inst_vld_num[3:0] < front_br_body_num[3:0]) ?
     (front_br_body_num[3:0] - ibdp_lbuf_inst_vld_num[3:0]) : 4'b0000) :
    front_fill_enter ? front_br_body_num_record[3:0] : front_br_body_num[3:0];

  assign front_br_body_num_update = (front_branch_state && front_update_br_taken) ||
    (front_fill_state && lbuf_create_vld) || front_fill_enter;

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_front_br_body_num_record
    if (!cpurst_b) begin
      front_br_body_num_record[3:0] <= 4'b0;
    end else if (front_branch_state && front_update_br_taken) begin
      front_br_body_num_record[3:0] <= front_br_body_num_pre[3:0];
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_front_br_body_num
    if (!cpurst_b) begin
      front_br_body_num[3:0] <= 4'b0;
    end else if (lbuf_flush) begin
      front_br_body_num[3:0] <= 4'b0;
    end else if (fill_state_enter) begin
      front_br_body_num[3:0] <= 4'b0;
    end else if (front_br_body_num_update) begin
      front_br_body_num[3:0] <= front_br_body_num_pre[3:0];
    end
  end

  // Prefix mask of the first front_br_body_num lanes. C910 had the same mask as
  // a 9 bit half-word vector.
  assign front_vld_mask[3:0] = (front_br_body_num[3:0] == 4'b0000) ? 4'b0000 :
    (front_br_body_num[3:0] == 4'b0001) ? 4'b0001 :
    (front_br_body_num[3:0] == 4'b0010) ? 4'b0011 :
    (front_br_body_num[3:0] == 4'b0011) ? 4'b0111 : 4'b1111;

  //------------------------------------------------------------------------------
  // Back branch buffer
  //------------------------------------------------------------------------------
  assign back_entry_update = (lbuf_cur_state[5:0] == CACHE) && back_update_pre_vld_flop;
  assign back_update_cur_pc[31:0] = back_update_pre_cur_pc[31:0];
  assign back_update_target_pc[31:0] = back_update_pre_tar_pc[31:0];
  assign back_update_pre_vld = (lbuf_cur_state[5:0] == FILL) && back_br_hit_lbuf_end;

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_back_update_pre_vld_flop
    if (!cpurst_b) begin
      back_update_pre_vld_flop <= 1'b0;
    end else if (lbuf_flush) begin
      back_update_pre_vld_flop <= 1'b0;
    end else begin
      back_update_pre_vld_flop <= back_update_pre_vld;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_back_entry
    if (!cpurst_b) begin
      back_entry_vld <= 1'b0;
      back_entry_start_num[3:0] <= 4'b0;
      back_entry_cur_pc[31:0] <= 32'b0;
      back_entry_target_pc[31:0] <= 32'b0;
    end else if (lbuf_flush) begin
      back_entry_vld <= 1'b0;
      back_entry_start_num[3:0] <= 4'b0;
      back_entry_cur_pc[31:0] <= 32'b0;
      back_entry_target_pc[31:0] <= 32'b0;
    end else if (fill_state_enter) begin
      back_entry_vld <= 1'b0;
      back_entry_start_num[3:0] <= new_entry_start_num[3:0];
      back_entry_cur_pc[31:0] <= 32'b0;
      back_entry_target_pc[31:0] <= 32'b0;
    end else if (back_entry_update) begin
      back_entry_vld <= 1'b1;
      back_entry_cur_pc[31:0] <= back_update_cur_pc[31:0];
      back_entry_target_pc[31:0] <= back_update_target_pc[31:0];
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_back_update_pre
    if (!cpurst_b) begin
      back_update_pre_tar_pc[31:0] <= 32'b0;
      back_update_pre_cur_pc[31:0] <= 32'b0;
    end else if (lbuf_flush) begin
      back_update_pre_tar_pc[31:0] <= 32'b0;
      back_update_pre_cur_pc[31:0] <= 32'b0;
    end else if (back_update_pre_vld) begin
      back_update_pre_tar_pc[31:0] <= back_br_tar_pc[31:0];
      back_update_pre_cur_pc[31:0] <= back_br_pc[31:0];
    end
  end

  //------------------------------------------------------------------------------
  // Loop buffer entry array
  //------------------------------------------------------------------------------
  // C910 writes entry (create_pointer + lane) with the create pointer expressed
  // as one-hot pointers rotated by the lane index. Bit j of every hn_ vector is
  // lane j, so pointer_rot[j][entry] selects entry (create + j).
  assign lbuf_create_pointer_rot[0][15:0] = lbuf_create_pointer[15:0];
  assign lbuf_create_pointer_rot[1][15:0] = {lbuf_create_pointer[14:0],
    lbuf_create_pointer[15]};
  assign lbuf_create_pointer_rot[2][15:0] = {lbuf_create_pointer[13:0],
    lbuf_create_pointer[15:14]};
  assign lbuf_create_pointer_rot[3][15:0] = {lbuf_create_pointer[12:0],
    lbuf_create_pointer[15:13]};

  generate
    for (entry = 0; entry < ENTRY_NUM; entry = entry + 1) begin : g_entry
      // C910 qualifies the entry write enable with the FILL / FRONT_FILL state as
      // well; lbuf_create_vld already carries that qualification.
      assign entry_create[entry] = lbuf_create_vld &&
        ((lbuf_create_pointer_rot[0][entry] & hn_create_vld[0]) |
         (lbuf_create_pointer_rot[1][entry] & hn_create_vld[1]) |
         (lbuf_create_pointer_rot[2][entry] & hn_create_vld[2]) |
         (lbuf_create_pointer_rot[3][entry] & hn_create_vld[3]));
      assign entry_create_front_br[entry] =
        (lbuf_create_pointer_rot[0][entry] & hn_front_br[0]) |
        (lbuf_create_pointer_rot[1][entry] & hn_front_br[1]) |
        (lbuf_create_pointer_rot[2][entry] & hn_front_br[2]) |
        (lbuf_create_pointer_rot[3][entry] & hn_front_br[3]);
      assign entry_create_back_br[entry] =
        (lbuf_create_pointer_rot[0][entry] & hn_back_br[0]) |
        (lbuf_create_pointer_rot[1][entry] & hn_back_br[1]) |
        (lbuf_create_pointer_rot[2][entry] & hn_back_br[2]) |
        (lbuf_create_pointer_rot[3][entry] & hn_back_br[3]);
      assign entry_create_fence[entry] =
        (lbuf_create_pointer_rot[0][entry] & hn_fence[0]) |
        (lbuf_create_pointer_rot[1][entry] & hn_fence[1]) |
        (lbuf_create_pointer_rot[2][entry] & hn_fence[2]) |
        (lbuf_create_pointer_rot[3][entry] & hn_fence[3]);
      assign entry_create_bkpta[entry] =
        (lbuf_create_pointer_rot[0][entry] & hn_bkpta[0]) |
        (lbuf_create_pointer_rot[1][entry] & hn_bkpta[1]) |
        (lbuf_create_pointer_rot[2][entry] & hn_bkpta[2]) |
        (lbuf_create_pointer_rot[3][entry] & hn_bkpta[3]);
      assign entry_create_bkptb[entry] =
        (lbuf_create_pointer_rot[0][entry] & hn_bkptb[0]) |
        (lbuf_create_pointer_rot[1][entry] & hn_bkptb[1]) |
        (lbuf_create_pointer_rot[2][entry] & hn_bkptb[2]) |
        (lbuf_create_pointer_rot[3][entry] & hn_bkptb[3]);
      assign entry_create_inst_data[entry*32+:32] =
        ({32{lbuf_create_pointer_rot[0][entry]}} & hn_data[0]) |
        ({32{lbuf_create_pointer_rot[1][entry]}} & hn_data[1]) |
        ({32{lbuf_create_pointer_rot[2][entry]}} & hn_data[2]) |
        ({32{lbuf_create_pointer_rot[3][entry]}} & hn_data[3]);

      rv32_ifu_lbuf_entry u_entry (
        .forever_cpuclk         (forever_cpuclk                  ),
        .cpurst_b               (cpurst_b                        ),
        .lbuf_flush             (lbuf_flush                      ),
        .fill_state_enter       (fill_state_enter                 ),
        .entry_create_x         (entry_create[entry]             ),
        .entry_create_inst_data_v(entry_create_inst_data[entry*32+:32]),
        .entry_create_front_br_x(entry_create_front_br[entry]    ),
        .entry_create_back_br_x (entry_create_back_br[entry]     ),
        .entry_create_fence_x   (entry_create_fence[entry]       ),
        .entry_create_bkpta_x   (entry_create_bkpta[entry]       ),
        .entry_create_bkptb_x   (entry_create_bkptb[entry]       ),
        .entry_inst_data_v      (entry_inst_data[entry*32+:32]   ),
        .entry_front_br_x       (entry_front_br[entry]           ),
        .entry_back_br_x        (entry_back_br[entry]            ),
        .entry_fence_x          (entry_fence[entry]              ),
        .entry_bkpta_x          (entry_bkpta[entry]              ),
        .entry_bkptb_x          (entry_bkptb[entry]              ),
        .entry_vld_x            (entry_vld[entry]                )
      );
    end
  endgenerate

  //------------------------------------------------------------------------------
  // Create pointer logic
  //------------------------------------------------------------------------------
  // C910 pre-rotated the create pointer by the number of pipedown instructions.
  // Here the count is 0..4 whole instructions.
  assign create_pointer_pre[15:0] =
    (ibdp_lbuf_inst_vld_num[3:0] == 4'b0001) ?
      {lbuf_create_pointer[14:0], lbuf_create_pointer[15]} :
    (ibdp_lbuf_inst_vld_num[3:0] == 4'b0010) ?
      {lbuf_create_pointer[13:0], lbuf_create_pointer[15:14]} :
    (ibdp_lbuf_inst_vld_num[3:0] == 4'b0011) ?
      {lbuf_create_pointer[12:0], lbuf_create_pointer[15:13]} :
    (ibdp_lbuf_inst_vld_num[3:0] == 4'b0100) ?
      {lbuf_create_pointer[11:0], lbuf_create_pointer[15:12]} :
      lbuf_create_pointer[15:0];

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_lbuf_create_pointer
    if (!cpurst_b) begin
      lbuf_create_pointer[15:0] <= {{(ENTRY_NUM-1){1'b0}}, 1'b1};
    end else if (lbuf_flush) begin
      lbuf_create_pointer[15:0] <= {{(ENTRY_NUM-1){1'b0}}, 1'b1};
    end else if (fill_state_enter) begin
      lbuf_create_pointer[15:0] <= {{(ENTRY_NUM-1){1'b0}}, 1'b1};
    end else if (taken_front_branch_enter) begin
      lbuf_create_pointer[15:0] <= front_update_pointer[15:0];
    end else if (front_fill_enter) begin
      lbuf_create_pointer[15:0] <= front_update_next_pointer[15:0];
    end else if (lbuf_create_vld) begin
      lbuf_create_pointer[15:0] <= create_pointer_pre[15:0];
    end
  end

  //------------------------------------------------------------------------------
  // Retire pointer logic
  //------------------------------------------------------------------------------
  assign lbuf_retire_pointer_rot[0][15:0] = lbuf_retire_pointer[15:0];
  assign lbuf_retire_pointer_rot[1][15:0] = {lbuf_retire_pointer[14:0],
    lbuf_retire_pointer[15]};
  assign lbuf_retire_pointer_rot[2][15:0] = {lbuf_retire_pointer[13:0],
    lbuf_retire_pointer[15:14]};
  assign lbuf_retire_pointer_rot[3][15:0] = {lbuf_retire_pointer[12:0],
    lbuf_retire_pointer[15:13]};

  // The branch way advances the pointer to the entry holding the front branch
  // when the front branch is predicted taken, otherwise to the loop start.
  assign lbuf_pop_inst0_retire_pointer_br_pre[15:0] = lbuf_pop_inst_front_br[0] ?
    front_entry_update_pointer[15:0] : back_entry_update_pointer[15:0];
  assign lbuf_pop_inst1_retire_pointer_br_pre[15:0] = lbuf_pop_inst_front_br[1] ?
    front_entry_update_pointer[15:0] : back_entry_update_pointer[15:0];
  assign lbuf_pop_inst2_retire_pointer_br_pre[15:0] = lbuf_pop_inst_front_br[2] ?
    front_entry_update_pointer[15:0] : back_entry_update_pointer[15:0];

  assign lbuf_retire_pointer_branch_pre[15:0] =
    (lbuf_pop_inst_br[0] && lbuf_pop_inst_valid[0] && inst0_bht_result) ?
      lbuf_pop_inst0_retire_pointer_br_pre[15:0] :
    (lbuf_pop_inst_br[1] && lbuf_pop_inst_valid[1] && inst1_bht_result) ?
      lbuf_pop_inst1_retire_pointer_br_pre[15:0] :
      lbuf_pop_inst2_retire_pointer_br_pre[15:0];

  assign lbuf_pop_branch_vld = (lbuf_pop_inst_br[0] && inst0_bht_result &&
    lbuf_pop_inst_valid[0]) ||
    (lbuf_pop_inst_br[1] && inst1_bht_result && lbuf_pop_inst_valid[1] &&
     !lbuf_pop_inst_br[0]) ||
    (lbuf_pop_inst_br[2] && inst2_bht_result && lbuf_pop_inst_valid[2] &&
     !lbuf_pop_inst_br[0] && !lbuf_pop_inst_br[1]);

  // No-branch way: advance by the number of slots that were actually consumed.
  assign lbuf_retire_pointer_pop3_pre[15:0] = lbuf_retire_pointer_rot[3][15:0];
  assign lbuf_retire_pointer_pop2_pre[15:0] = lbuf_retire_pointer_rot[2][15:0];
  assign lbuf_retire_pointer_pop1_pre[15:0] = lbuf_retire_pointer_rot[1][15:0];

  assign lbuf_pop_inst_br_mask_vld[2] = lbuf_pop_inst_valid[2] &&
    !lbuf_pop_inst_br[1] && !lbuf_pop_inst_br[0];
  assign lbuf_pop_inst_br_mask_vld[1] = lbuf_pop_inst_valid[1] && !lbuf_pop_inst_br[0];
  assign lbuf_pop_inst_br_mask_vld[0] = lbuf_pop_inst_valid[0];

  assign lbuf_retire_pointer_pre[15:0] =
    lbuf_pop_inst_br_mask_vld[2] ? lbuf_retire_pointer_pop3_pre[15:0] :
    lbuf_pop_inst_br_mask_vld[1] ? lbuf_retire_pointer_pop2_pre[15:0] :
    lbuf_pop_inst_br_mask_vld[0] ? lbuf_retire_pointer_pop1_pre[15:0] :
      lbuf_retire_pointer[15:0];

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_lbuf_retire_pointer
    if (!cpurst_b) begin
      lbuf_retire_pointer[15:0] <= {{(ENTRY_NUM-1){1'b0}}, 1'b1};
    end else if (lbuf_flush) begin
      lbuf_retire_pointer[15:0] <= {{(ENTRY_NUM-1){1'b0}}, 1'b1};
    end else if (fill_state_enter || idle_cache_state_enter ||
      front_cache_active_state_enter) begin
      lbuf_retire_pointer[15:0] <= {{(ENTRY_NUM-1){1'b0}}, 1'b1};
    end else if (lbuf_retire_vld && lbuf_pop_branch_vld) begin
      lbuf_retire_pointer[15:0] <= lbuf_retire_pointer_branch_pre[15:0];
    end else if (lbuf_retire_vld && !lbuf_pop_branch_vld) begin
      lbuf_retire_pointer[15:0] <= lbuf_retire_pointer_pre[15:0];
    end
  end

  //------------------------------------------------------------------------------
  // Replay slot read out of the entry array
  //------------------------------------------------------------------------------
  // One slot is one complete instruction, so no C910 half-word reassembly is
  // needed: slot k is simply the entry under retire pointer k.
  generate
    for (slot = 0; slot < 3; slot = slot + 1) begin : g_pop
      assign lbuf_pop_inst_valid[slot] =
        |(lbuf_retire_pointer_rot[slot][15:0] & entry_vld[15:0]);
      assign lbuf_pop_inst_front_br[slot] =
        |(lbuf_retire_pointer_rot[slot][15:0] & entry_front_br[15:0] & entry_vld[15:0]);
      assign lbuf_pop_inst_back_br[slot] =
        |(lbuf_retire_pointer_rot[slot][15:0] & entry_back_br[15:0] & entry_vld[15:0]);
      assign lbuf_pop_inst_fence[slot] =
        |(lbuf_retire_pointer_rot[slot][15:0] & entry_fence[15:0] & entry_vld[15:0]);
      assign lbuf_pop_inst_bkpta[slot] =
        |(lbuf_retire_pointer_rot[slot][15:0] & entry_bkpta[15:0] & entry_vld[15:0]);
      assign lbuf_pop_inst_bkptb[slot] =
        |(lbuf_retire_pointer_rot[slot][15:0] & entry_bkptb[15:0] & entry_vld[15:0]);
      assign lbuf_pop_inst_data[slot*32+:32] =
        ({32{lbuf_retire_pointer_rot[slot][ 0]}} & entry_inst_data[ 0*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 1]}} & entry_inst_data[ 1*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 2]}} & entry_inst_data[ 2*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 3]}} & entry_inst_data[ 3*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 4]}} & entry_inst_data[ 4*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 5]}} & entry_inst_data[ 5*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 6]}} & entry_inst_data[ 6*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 7]}} & entry_inst_data[ 7*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 8]}} & entry_inst_data[ 8*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][ 9]}} & entry_inst_data[ 9*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][10]}} & entry_inst_data[10*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][11]}} & entry_inst_data[11*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][12]}} & entry_inst_data[12*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][13]}} & entry_inst_data[13*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][14]}} & entry_inst_data[14*32+:32]) |
        ({32{lbuf_retire_pointer_rot[slot][15]}} & entry_inst_data[15*32+:32]);
    end
  endgenerate

  assign lbuf_pop_inst_br[2:0] = lbuf_pop_inst_front_br[2:0] | lbuf_pop_inst_back_br[2:0];

  //------------------------------------------------------------------------------
  // PC related information
  //------------------------------------------------------------------------------
  // The branch way targets the front branch target or the loop start. C910 added
  // 2 half words for a 32 bit branch; here it is always one instruction.
  assign lbuf_pop_inst0_pc_br_pre[31:0] = lbuf_pop_inst_front_br[0] ?
    front_entry_target_pc[31:0] : back_entry_target_pc[31:0];
  assign lbuf_pop_inst1_pc_br_pre[31:0] = lbuf_pop_inst_front_br[1] ?
    front_entry_target_pc[31:0] : back_entry_target_pc[31:0];
  assign lbuf_pop_inst2_pc_br_pre[31:0] = lbuf_pop_inst_front_br[2] ?
    front_entry_target_pc[31:0] : back_entry_target_pc[31:0];

  assign lbuf_cur_pc_branch_pre[31:0] =
    (lbuf_pop_inst_br[0] && lbuf_pop_inst_valid[0] && inst0_bht_result) ?
      lbuf_pop_inst0_pc_br_pre[31:0] :
    (lbuf_pop_inst_br[1] && lbuf_pop_inst_valid[1] && inst1_bht_result) ?
      lbuf_pop_inst1_pc_br_pre[31:0] :
      lbuf_pop_inst2_pc_br_pre[31:0];

  // No-branch way: advance by the number of consumed whole instructions.
  assign lbuf_pc_pop3_pre[31:0] = lbuf_pc_add_3[31:0];
  assign lbuf_pc_pop2_pre[31:0] = lbuf_pc_add_2[31:0];
  assign lbuf_pc_pop1_pre[31:0] = lbuf_pc_add_1[31:0];

  assign lbuf_cur_pc_pre[31:0] =
    lbuf_pop_inst_br_mask_vld[2] ? lbuf_pc_pop3_pre[31:0] :
    lbuf_pop_inst_br_mask_vld[1] ? lbuf_pc_pop2_pre[31:0] :
    lbuf_pop_inst_br_mask_vld[0] ? lbuf_pc_pop1_pre[31:0] :
      lbuf_cur_pc[31:0];

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_lbuf_cur_pc
    if (!cpurst_b) begin
      lbuf_cur_pc[31:0] <= 32'b0;
    end else if (lbuf_flush) begin
      lbuf_cur_pc[31:0] <= 32'b0;
    end else if (fill_state_enter) begin
      lbuf_cur_pc[31:0] <= 32'b0;
    end else if (active_state_enter) begin
      lbuf_cur_pc[31:0] <= loop_start_pc[31:0];
    end else if (lbuf_retire_vld && lbuf_pop_branch_vld) begin
      lbuf_cur_pc[31:0] <= lbuf_cur_pc_branch_pre[31:0];
    end else if (lbuf_retire_vld && !lbuf_pop_branch_vld) begin
      lbuf_cur_pc[31:0] <= lbuf_cur_pc_pre[31:0];
    end
  end

  // The loop start is the target recorded for the loop-end back branch.
  assign loop_start_pc[31:0] = back_update_target_pc[31:0];

  // One step is one whole instruction. C910 stepped by half words.
  assign lbuf_pc_add_1[31:0] = lbuf_cur_pc[31:0] + 32'd4;
  assign lbuf_pc_add_2[31:0] = lbuf_cur_pc[31:0] + 32'd8;
  assign lbuf_pc_add_3[31:0] = lbuf_cur_pc[31:0] + 32'd12;

  assign lbuf_pop_inst_pc[31:0] = lbuf_cur_pc[31:0];
  assign lbuf_pop_inst_pc[63:32] = lbuf_pc_add_1[31:0];
  assign lbuf_pop_inst_pc[95:64] = lbuf_pc_add_2[31:0];

  //------------------------------------------------------------------------------
  // Loop buffer BHT interaction
  //------------------------------------------------------------------------------
  // Two sources: the select array recorded while filling and maintained by this
  // module, and the pre array read out of the BHT for the current prediction.
  assign front_pre_array_result[31:0] = front_br_sel_array_result[1] ?
    pre_taken_result[31:0] : pre_ntaken_result[31:0];
  assign back_pre_array_result[31:0] = back_br_sel_array_result[1] ?
    pre_taken_result[31:0] : pre_ntaken_result[31:0];

  assign front_br_sel_array_record = (lbuf_cur_state[5:0] == FILL) && front_br_check &&
    lbuf_create_vld;
  assign back_br_sel_array_record = (lbuf_cur_state[5:0] == FILL) && back_br_check &&
    lbuf_create_vld;
  assign front_br_sel_array_result_pre[1:0] = iu_ifu_bht_condbr_taken ?
    front_br_sel_array_result[1:0] + 2'b01 : front_br_sel_array_result[1:0] - 2'b01;
  assign back_br_sel_array_result_pre[1:0] = iu_ifu_bht_condbr_taken ?
    back_br_sel_array_result[1:0] + 2'b01 : back_br_sel_array_result[1:0] - 2'b01;

  // C910 also suppressed the update on a bi-mode crossing qualified by
  // iu_ifu_chgflw_vld. That input is not in the specified port list; the IU
  // change-of-flow event available here is ibctrl_lbuf_bju_mispred, which drives
  // C910's bju_mispred, and is used for both qualifications.
  assign front_br_sel_array_update = iu_ifu_bht_check_vld &&
    (iu_ifu_cur_pc[31:0] == front_entry_cur_pc[31:0]) &&
    !((front_br_sel_array_result[1:0] == 2'b00) && !iu_ifu_bht_condbr_taken ||
      (front_br_sel_array_result[1:0] == 2'b11) && iu_ifu_bht_condbr_taken ||
      (front_br_sel_array_result[1] == 1'b0) && iu_ifu_bht_condbr_taken &&
      !bju_mispred ||
      (front_br_sel_array_result[1] == 1'b1) && !iu_ifu_bht_condbr_taken &&
      !bju_mispred);

  assign back_br_sel_array_update = iu_ifu_bht_check_vld &&
    (iu_ifu_cur_pc[31:0] == back_entry_cur_pc[31:0]) &&
    !((back_br_sel_array_result[1:0] == 2'b00) && !iu_ifu_bht_condbr_taken ||
      (back_br_sel_array_result[1:0] == 2'b11) && iu_ifu_bht_condbr_taken ||
      (back_br_sel_array_result[1] == 1'b0) && iu_ifu_bht_condbr_taken &&
      !bju_mispred ||
      (back_br_sel_array_result[1] == 1'b1) && !iu_ifu_bht_condbr_taken &&
      !bju_mispred);

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_front_br_sel_array_result
    if (!cpurst_b) begin
      front_br_sel_array_result[1:0] <= 2'b00;
    end else if (lbuf_flush) begin
      front_br_sel_array_result[1:0] <= 2'b00;
    end else if (fill_state_enter) begin
      front_br_sel_array_result[1:0] <= 2'b00;
    end else if (front_br_sel_array_record) begin
      front_br_sel_array_result[1:0] <= sel_array_result[1:0];
    end else if (front_br_sel_array_update) begin
      front_br_sel_array_result[1:0] <= front_br_sel_array_result_pre[1:0];
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_back_br_sel_array_result
    if (!cpurst_b) begin
      back_br_sel_array_result[1:0] <= 2'b00;
    end else if (lbuf_flush) begin
      back_br_sel_array_result[1:0] <= 2'b00;
    end else if (fill_state_enter) begin
      back_br_sel_array_result[1:0] <= 2'b00;
    end else if (back_br_sel_array_record) begin
      back_br_sel_array_result[1:0] <= sel_array_result[1:0];
    end else if (back_br_sel_array_update) begin
      back_br_sel_array_result[1:0] <= back_br_sel_array_result_pre[1:0];
    end
  end

  // The pre array is indexed by the branch PC low bits XOR the live VGHR, so
  // every iteration forms a new prediction from the BHT instead of replaying the
  // one recorded while the loop was filled.
  always @(*) begin : p_front_br_bht_pre_result_comb
    case (front_entry_cur_pc[6:3] ^ vghr[3:0])
      4'b0000: front_br_bht_pre_result[1:0] = front_pre_array_result[ 1: 0];
      4'b0001: front_br_bht_pre_result[1:0] = front_pre_array_result[ 3: 2];
      4'b0010: front_br_bht_pre_result[1:0] = front_pre_array_result[ 5: 4];
      4'b0011: front_br_bht_pre_result[1:0] = front_pre_array_result[ 7: 6];
      4'b0100: front_br_bht_pre_result[1:0] = front_pre_array_result[ 9: 8];
      4'b0101: front_br_bht_pre_result[1:0] = front_pre_array_result[11:10];
      4'b0110: front_br_bht_pre_result[1:0] = front_pre_array_result[13:12];
      4'b0111: front_br_bht_pre_result[1:0] = front_pre_array_result[15:14];
      4'b1000: front_br_bht_pre_result[1:0] = front_pre_array_result[17:16];
      4'b1001: front_br_bht_pre_result[1:0] = front_pre_array_result[19:18];
      4'b1010: front_br_bht_pre_result[1:0] = front_pre_array_result[21:20];
      4'b1011: front_br_bht_pre_result[1:0] = front_pre_array_result[23:22];
      4'b1100: front_br_bht_pre_result[1:0] = front_pre_array_result[25:24];
      4'b1101: front_br_bht_pre_result[1:0] = front_pre_array_result[27:26];
      4'b1110: front_br_bht_pre_result[1:0] = front_pre_array_result[29:28];
      4'b1111: front_br_bht_pre_result[1:0] = front_pre_array_result[31:30];
      default: front_br_bht_pre_result[1:0] = 2'b0;
    endcase
  end

  always @(*) begin : p_back_br_bht_pre_result_comb
    case (back_entry_cur_pc[6:3] ^ vghr[3:0])
      4'b0000: back_br_bht_pre_result[1:0] = back_pre_array_result[ 1: 0] &
        {2{!ins_inv_on}};
      4'b0001: back_br_bht_pre_result[1:0] = back_pre_array_result[ 3: 2] &
        {2{!ins_inv_on}};
      4'b0010: back_br_bht_pre_result[1:0] = back_pre_array_result[ 5: 4] &
        {2{!ins_inv_on}};
      4'b0011: back_br_bht_pre_result[1:0] = back_pre_array_result[ 7: 6] &
        {2{!ins_inv_on}};
      4'b0100: back_br_bht_pre_result[1:0] = back_pre_array_result[ 9: 8] &
        {2{!ins_inv_on}};
      4'b0101: back_br_bht_pre_result[1:0] = back_pre_array_result[11:10] &
        {2{!ins_inv_on}};
      4'b0110: back_br_bht_pre_result[1:0] = back_pre_array_result[13:12] &
        {2{!ins_inv_on}};
      4'b0111: back_br_bht_pre_result[1:0] = back_pre_array_result[15:14] &
        {2{!ins_inv_on}};
      4'b1000: back_br_bht_pre_result[1:0] = back_pre_array_result[17:16] &
        {2{!ins_inv_on}};
      4'b1001: back_br_bht_pre_result[1:0] = back_pre_array_result[19:18] &
        {2{!ins_inv_on}};
      4'b1010: back_br_bht_pre_result[1:0] = back_pre_array_result[21:20] &
        {2{!ins_inv_on}};
      4'b1011: back_br_bht_pre_result[1:0] = back_pre_array_result[23:22] &
        {2{!ins_inv_on}};
      4'b1100: back_br_bht_pre_result[1:0] = back_pre_array_result[25:24] &
        {2{!ins_inv_on}};
      4'b1101: back_br_bht_pre_result[1:0] = back_pre_array_result[27:26] &
        {2{!ins_inv_on}};
      4'b1110: back_br_bht_pre_result[1:0] = back_pre_array_result[29:28] &
        {2{!ins_inv_on}};
      4'b1111: back_br_bht_pre_result[1:0] = back_pre_array_result[31:30] &
        {2{!ins_inv_on}};
      default: back_br_bht_pre_result[1:0] = 2'b0;
    endcase
  end

  assign front_br_bht_result = front_br_bht_pre_result[1];
  assign back_br_bht_result = back_br_bht_pre_result[1];

  // Each replay slot takes the prediction of the branch it actually holds.
  assign inst0_bht_result = lbuf_pop_inst_front_br[0] ? front_br_bht_result :
    back_br_bht_result;
  assign inst1_bht_result = lbuf_pop_inst_front_br[1] ? front_br_bht_result :
    back_br_bht_result;
  assign inst2_bht_result = lbuf_pop_inst_front_br[2] ? front_br_bht_result :
    back_br_bht_result;

  // front_br and back_br entry bits are only ever set for a conditional branch,
  // so a valid popped slot carrying either bit is a replayed conditional branch.
  assign lbuf_pop_inst_con_br[2:0] = lbuf_pop_inst_br[2:0] & lbuf_pop_inst_valid[2:0];
  assign lbuf_pop_con_br_inst = |lbuf_pop_inst_con_br[2:0];
  assign lbuf_pop_con_br_taken = lbuf_pop_inst_con_br[0] ? inst0_bht_result :
    lbuf_pop_inst_con_br[1] ? inst1_bht_result : inst2_bht_result;

  //------------------------------------------------------------------------------
  // Loop buffer change flow
  //------------------------------------------------------------------------------
  // Sources: FILL reaches the loop end, FRONT_FILL reaches the loop end, IDLE
  // recognises an already filled record, ACTIVE sees the loop-end back branch
  // not taken, ACTIVE sees the front branch not taken with an unfilled body. The
  // C910 delay is one cycle, hence the registered copies below.
  assign active_idle_chgflw_vld_pre = (lbuf_cur_state[5:0] == ACTIVE) &&
    lbuf_pop_not_taken_back_br;
  assign active_front_fill_chgflw_vld_pre = (lbuf_cur_state[5:0] == ACTIVE) &&
    front_br_body_not_filled;
  assign lbuf_stop_fetch_chgflw_vld_pre = (lbuf_cur_state[5:0] == FILL) &&
    back_br_hit_lbuf_end && !fill_not_under_rule ||
    (lbuf_cur_state[5:0] == FRONT_FILL) && back_br_hit_lbuf_end &&
    !front_fill_not_under_rule ||
    (lbuf_cur_state[5:0] == IDLE) && cp0_ifu_lbuf_en &&
    back_br_hit_record_fifo_fill && !ins_inv_on;

  // ACTIVE and the loop-end back branch not taken: resume fetch after it.
  assign active_idle_chgflw_pc_pre[31:0] = back_entry_cur_pc[31:0] + 32'd4;
  // ACTIVE and the front branch not taken: resume fetch after it.
  assign active_front_fill_chgflw_pc_pre[31:0] = front_entry_cur_pc[31:0] + 32'd4;

  // C910 clears the three pulse registers with lbuf_flush or iu_ifu_chgflw_vld.
  // iu_ifu_chgflw_vld is not in the specified port list; the IU change-of-flow
  // event available here is ibctrl_lbuf_bju_mispred (C910's bju_mispred).
  assign chgflw_vld = lbuf_flush || bju_mispred;

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_lbuf_stop_fetch_chgflw_vld
    if (!cpurst_b) begin
      lbuf_stop_fetch_chgflw_vld <= 1'b0;
    end else if (chgflw_vld) begin
      lbuf_stop_fetch_chgflw_vld <= 1'b0;
    end else begin
      lbuf_stop_fetch_chgflw_vld <= lbuf_stop_fetch_chgflw_vld_pre;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_active_idle_chgflw_vld
    if (!cpurst_b) begin
      active_idle_chgflw_vld <= 1'b0;
    end else if (chgflw_vld) begin
      active_idle_chgflw_vld <= 1'b0;
    end else begin
      active_idle_chgflw_vld <= active_idle_chgflw_vld_pre;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_active_front_fill_chgflw_vld
    if (!cpurst_b) begin
      active_front_fill_chgflw_vld <= 1'b0;
    end else if (chgflw_vld) begin
      active_front_fill_chgflw_vld <= 1'b0;
    end else begin
      active_front_fill_chgflw_vld <= active_front_fill_chgflw_vld_pre;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_active_ctc_record
    if (!cpurst_b) begin
      active_ctc_record <= 1'b0;
    end else if (lbuf_flush) begin
      active_ctc_record <= 1'b0;
    end else if (lbuf_cur_state[5:0] == ACTIVE && ifctrl_lbuf_inv_req) begin
      active_ctc_record <= 1'b1;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_lbuf_ibctrl_chgflw_pc
    if (!cpurst_b) begin
      lbuf_ibctrl_chgflw_pc[31:0] <= 32'b0;
    end else if (lbuf_stop_fetch_chgflw_vld_pre) begin
      lbuf_ibctrl_chgflw_pc[31:0] <= back_br_tar_pc[31:0];
    end else if (active_idle_chgflw_vld_pre) begin
      lbuf_ibctrl_chgflw_pc[31:0] <= active_idle_chgflw_pc_pre[31:0];
    end else if (active_front_fill_chgflw_vld_pre) begin
      lbuf_ibctrl_chgflw_pc[31:0] <= active_front_fill_chgflw_pc_pre[31:0];
    end
  end

  //------------------------------------------------------------------------------
  // Information sent to IBCTRL
  //------------------------------------------------------------------------------
  assign lbuf_ibctrl_lbuf_active = lbuf_cur_state[5:0] == ACTIVE;
  assign lbuf_ibctrl_stall = lbuf_cur_state[5:0] == CACHE ||
    lbuf_cur_state[5:0] == FRONT_BRANCH || lbuf_cur_state[5:0] == FRONT_CACHE;
  assign lbuf_ibctrl_active_idle_flush = active_idle_chgflw_vld && active_ctc_record;
  assign lbuf_ibctrl_chgflw_pred[1:0] = lbuf_stop_fetch_chgflw_vld ? 2'b00 : 2'b11;
  assign lbuf_ibctrl_chgflw_vld = cp0_ifu_lbuf_en &&
    (lbuf_stop_fetch_chgflw_vld || active_idle_chgflw_vld || active_front_fill_chgflw_vld);

  //------------------------------------------------------------------------------
  // Information sent to PCFIFO_IF
  //------------------------------------------------------------------------------
  assign lbuf_pcfifo_if_create_select = lbuf_cur_state[5:0] == ACTIVE;
  assign lbuf_pcfifo_if_inst_pc_oper = lbuf_pop_con_br_inst && cp0_ifu_lbuf_en &&
    lbuf_retire_vld;
  assign lbuf_pcfifo_if_inst_cur_pc[31:0] = lbuf_pop_con_br_cur_pc[31:0];
  // C910 leaves the target for the IU to recompute.
  assign lbuf_pcfifo_if_inst_target_pc[31:0] = 32'b0;
  assign lbuf_pcfifo_if_inst_vghr[21:0] = bht_lbuf_vghr[21:0];
  assign lbuf_pcfifo_if_inst_bht_pre_result[1:0] = lbuf_pop_pre_result[1:0];
  assign lbuf_pcfifo_if_inst_bht_sel_result[1:0] = lbuf_pop_sel_result[1:0];

  assign lbuf_pop_front_br = (lbuf_pop_inst_front_br[0] && lbuf_pop_inst_valid[0]) ||
    (lbuf_pop_inst_front_br[1] && lbuf_pop_inst_valid[1] && !lbuf_pop_inst_br[0]) ||
    (lbuf_pop_inst_front_br[2] && lbuf_pop_inst_valid[2] && !lbuf_pop_inst_br[0] &&
     !lbuf_pop_inst_br[1]);
  assign lbuf_pop_con_br_cur_pc[31:0] = lbuf_pop_front_br ?
    front_entry_cur_pc[31:0] : back_entry_cur_pc[31:0];
  assign lbuf_pop_pre_result[1:0] = lbuf_pop_front_br ?
    front_br_bht_pre_result[1:0] : back_br_bht_pre_result[1:0];
  assign lbuf_pop_sel_result[1:0] = lbuf_pop_front_br ?
    front_br_sel_array_result[1:0] : back_br_sel_array_result[1:0];

  //------------------------------------------------------------------------------
  // Information sent to ADDRGEN
  //------------------------------------------------------------------------------
  assign lbuf_addrgen_cache_state = lbuf_cur_state[5:0] == CACHE;
  assign lbuf_addrgen_active_state = lbuf_cur_state[5:0] == ACTIVE;
  assign lbuf_addrgen_chgflw_mask = cp0_ifu_lbuf_en && !lbuf_flush &&
    ((lbuf_cur_state[5:0] == IDLE) && back_br_hit_record_fifo_fill && !ins_inv_on ||
     (lbuf_cur_state[5:0] == FILL) && back_br_hit_lbuf_end && !fill_not_under_rule ||
     (lbuf_cur_state[5:0] == FRONT_FILL) && back_br_hit_lbuf_end &&
     !front_fill_not_under_rule);

  //------------------------------------------------------------------------------
  // Instructions sent to IBDP
  //------------------------------------------------------------------------------
  assign lbuf_ibdp_inst0_valid = lbuf_pop_inst_br_mask_vld[0] && cp0_ifu_lbuf_en &&
    lbuf_retire_vld;
  assign lbuf_ibdp_inst1_valid = lbuf_pop_inst_br_mask_vld[1] && cp0_ifu_lbuf_en &&
    lbuf_retire_vld;
  assign lbuf_ibdp_inst2_valid = lbuf_pop_inst_br_mask_vld[2] && cp0_ifu_lbuf_en &&
    lbuf_retire_vld;

  assign lbuf_ibdp_inst0_data[31:0] = lbuf_pop_inst_data[31:0];
  assign lbuf_ibdp_inst1_data[31:0] = lbuf_pop_inst_data[63:32];
  assign lbuf_ibdp_inst2_data[31:0] = lbuf_pop_inst_data[95:64];
  assign lbuf_ibdp_inst0_pc[31:0] = lbuf_pop_inst_pc[31:0];
  assign lbuf_ibdp_inst1_pc[31:0] = lbuf_pop_inst_pc[63:32];
  assign lbuf_ibdp_inst2_pc[31:0] = lbuf_pop_inst_pc[95:64];

  // The local ADDRGEN has no access to the recorded branch offsets, so the adder
  // result is delivered per slot: the branch target for the slot that is
  // predicted taken, the fall-through link otherwise.
  assign lbuf_ibdp_inst0_npc[31:0] = (lbuf_pop_inst_br[0] && lbuf_pop_inst_valid[0] &&
    inst0_bht_result) ? lbuf_pop_inst0_pc_br_pre[31:0] :
      (lbuf_pop_inst_pc[31:0] + 32'd4);
  assign lbuf_ibdp_inst1_npc[31:0] = (lbuf_pop_inst_br[1] && lbuf_pop_inst_valid[1] &&
    inst1_bht_result) ? lbuf_pop_inst1_pc_br_pre[31:0] :
      (lbuf_pop_inst_pc[63:32] + 32'd4);
  assign lbuf_ibdp_inst2_npc[31:0] = (lbuf_pop_inst_br[2] && lbuf_pop_inst_valid[2] &&
    inst2_bht_result) ? lbuf_pop_inst2_pc_br_pre[31:0] :
      (lbuf_pop_inst_pc[95:64] + 32'd4);

  assign lbuf_ibdp_inst0_front_br = lbuf_pop_inst_front_br[0];
  assign lbuf_ibdp_inst0_back_br  = lbuf_pop_inst_back_br[0];
  assign lbuf_ibdp_inst0_fence    = lbuf_pop_inst_fence[0];
  assign lbuf_ibdp_inst0_bkpta    = lbuf_pop_inst_bkpta[0];
  assign lbuf_ibdp_inst0_bkptb    = lbuf_pop_inst_bkptb[0];
  assign lbuf_ibdp_inst1_front_br = lbuf_pop_inst_front_br[1];
  assign lbuf_ibdp_inst1_back_br  = lbuf_pop_inst_back_br[1];
  assign lbuf_ibdp_inst1_fence    = lbuf_pop_inst_fence[1];
  assign lbuf_ibdp_inst1_bkpta    = lbuf_pop_inst_bkpta[1];
  assign lbuf_ibdp_inst1_bkptb    = lbuf_pop_inst_bkptb[1];
  assign lbuf_ibdp_inst2_front_br = lbuf_pop_inst_front_br[2];
  assign lbuf_ibdp_inst2_back_br  = lbuf_pop_inst_back_br[2];
  assign lbuf_ibdp_inst2_fence    = lbuf_pop_inst_fence[2];
  assign lbuf_ibdp_inst2_bkpta    = lbuf_pop_inst_bkpta[2];
  assign lbuf_ibdp_inst2_bkptb    = lbuf_pop_inst_bkptb[2];

  //------------------------------------------------------------------------------
  // Information sent to IPDP and PCGEN
  //------------------------------------------------------------------------------
  assign lbuf_ipdp_lbuf_active = lbuf_cur_state[5:0] == ACTIVE;

  assign lbuf_vld_mask = cp0_ifu_lbuf_en &&
    ((lbuf_cur_state[5:0] == ACTIVE) &&
     (active_idle_chgflw_vld_pre || active_front_fill_chgflw_vld_pre) ||
     lbuf_stop_fetch_chgflw_vld_pre);
  assign lbuf_pcgen_vld_mask = lbuf_vld_mask;
  assign lbuf_pcgen_active = lbuf_cur_state[5:0] == ACTIVE;

  //------------------------------------------------------------------------------
  // Information sent to BHT
  //------------------------------------------------------------------------------
  assign lbuf_bht_con_br_vld = cp0_ifu_lbuf_en && lbuf_pop_con_br_inst && lbuf_retire_vld;
  assign lbuf_bht_con_br_taken = lbuf_pop_con_br_taken;
  assign lbuf_bht_active_state = lbuf_cur_state[5:0] == ACTIVE;

  //------------------------------------------------------------------------------
  // Debug information
  //------------------------------------------------------------------------------
  assign lbuf_debug_st[5:0] = lbuf_cur_state[5:0];

endmodule
