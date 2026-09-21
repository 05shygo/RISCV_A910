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

// RV32I port, 2026-09-20: C910 Bi-Mode retained; H0 removed, P31, P15 flush, local GHR repair, drop counter.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_bht (

  // Predictor and pipeline interface
  input  wire        local_recover_vld,
  input  wire [21:0] local_recover_ghr,
  output wire        bht_train_drop,
  output wire [31:0] bht_train_drop_count,

  // Clock, reset and configuration
  input wire cp0_ifu_bht_en,
  input wire cp0_ifu_icg_en,
  input wire cp0_yy_clk_en,
  input wire cpurst_b,
  input wire forever_cpuclk,

  // Predictor and pipeline interface
  input wire        ifctrl_bht_inv,
  input wire        ifctrl_bht_pipedown,
  input wire        ifctrl_bht_stall,
  input wire        ipctrl_bht_con_br_gateclk_en,
  input wire        ipctrl_bht_con_br_taken,
  input wire        ipctrl_bht_con_br_vld,
  input wire        ipctrl_bht_more_br,
  input wire        ipctrl_bht_vld,
  input wire [30:0] ipdp_bht_vpc,

  // Execution check and recovery
  input wire        iu_ifu_bht_check_vld,
  input wire        iu_ifu_bht_condbr_taken,
  input wire        iu_ifu_bht_pred,
  input wire        iu_ifu_chgflw_vld,
  input wire [24:0] iu_ifu_chk_idx,
  input wire [30:0] iu_ifu_cur_pc,

  // Predictor and pipeline interface
  input wire lbuf_bht_active_state,
  input wire lbuf_bht_con_br_taken,
  input wire lbuf_bht_con_br_vld,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Predictor and pipeline interface
  input wire       pcgen_bht_chgflw,
  input wire       pcgen_bht_chgflw_short,
  input wire [6:0] pcgen_bht_ifpc,
  input wire [9:0] pcgen_bht_pcindex,
  input wire       pcgen_bht_seq_read,

  // Retirement interface
  input wire rtu_ifu_flush,
  input wire rtu_ifu_retire0_condbr,
  input wire rtu_ifu_retire0_condbr_taken,
  input wire rtu_ifu_retire1_condbr,
  input wire rtu_ifu_retire1_condbr_taken,
  input wire rtu_ifu_retire2_condbr,
  input wire rtu_ifu_retire2_condbr_taken,

  // Predictor and pipeline interface
  output wire        bht_ifctrl_inv_done,
  output wire        bht_ifctrl_inv_on,
  output wire [ 7:0] bht_ind_btb_rtu_ghr,
  output wire [ 7:0] bht_ind_btb_vghr,
  output wire [31:0] bht_ipdp_pre_array_data_ntake,
  output wire [31:0] bht_ipdp_pre_array_data_taken,
  output wire [15:0] bht_ipdp_pre_offset_onehot,
  output wire [ 1:0] bht_ipdp_sel_array_result,
  output wire [21:0] bht_ipdp_vghr,
  output wire [31:0] bht_lbuf_pre_ntaken_result,
  output wire [31:0] bht_lbuf_pre_taken_result,
  output wire [21:0] bht_lbuf_vghr
);

  //------------------------------------------------------------------------------
  // Localparams
  //------------------------------------------------------------------------------

  localparam PC_WIDTH = 32;

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire [ 21:0] committed_recover_ghr;
  reg          after_bju_mispred_q;
  reg          after_rtu_ifu_flush_q;
  reg          bht_inv_on_q;
  reg          bht_inv_on_reg_ff_q;
  reg  [  9:0] bht_inval_cnt_pre_q;
  reg  [  9:0] bht_pred_array_index;
  reg  [  9:0] bht_pred_array_index_q;
  reg  [  9:0] bht_pred_array_rd_index;
  reg  [  6:0] bht_sel_array_index;
  reg  [  9:0] bht_sel_array_index_q;
  reg  [ 15:0] bht_sel_data_q;
  reg  [ 31:0] bht_wr_buf_pred_updt_sel_b;
  reg  [  7:0] bht_wr_buf_sel_updt_sel_b;
  reg          buf_full;
  reg  [  3:0] create_ptr_q;
  reg          cur_condbr_taken;
  reg  [  9:0] cur_cur_pc;
  reg  [ 21:0] cur_ghr;
  reg  [  1:0] cur_pred_rst;
  reg  [  1:0] cur_sel_rst;
  reg  [ 36:0] entry0_data_q;
  reg  [  1:0] entry0_sel_updt_data;
  reg          entry0_vld_q;
  reg  [ 36:0] entry1_data_q;
  reg  [  1:0] entry1_sel_updt_data;
  reg          entry1_vld_q;
  reg  [ 36:0] entry2_data_q;
  reg  [  1:0] entry2_sel_updt_data;
  reg          entry2_vld_q;
  reg  [ 36:0] entry3_data_q;
  reg  [  1:0] entry3_sel_updt_data;
  reg          entry3_vld_q;
  reg  [ 36:0] entry_data;
  reg          entry_vld;
  reg  [  7:0] if_pc_onehot;
  reg  [ 31:0] lbuf_pre_ntaken_q;
  reg  [ 31:0] lbuf_pre_taken_q;
  reg  [ 31:0] pre_array_pipe_ntaken_data;
  reg  [ 31:0] pre_array_pipe_taken_data;
  reg  [ 31:0] pre_ntaken_q;
  reg  [ 15:0] pre_offset_onehot_if_0;
  reg  [ 15:0] pre_offset_onehot_if_1;
  reg  [ 15:0] pre_offset_onehot_ip_0;
  reg  [ 15:0] pre_offset_onehot_ip_1;
  reg          pre_rd_q;
  reg  [ 31:0] pre_taken_q;
  reg  [  3:0] pre_vghr_offset_0;
  reg  [  3:0] pre_vghr_offset_1;
  reg  [  1:0] pred_array_updt_data;
  reg  [  3:0] retire_ptr_q;
  reg  [ 21:0] rtughr_nxt;
  reg  [ 21:0] rtughr_q;
  reg  [  1:0] sel_array_updt_data;
  reg  [  1:0] sel_array_val_q;
  reg          sel_rd_q;
  reg  [ 21:0] vghr_q;
  reg  [ 21:0] vghr_value;
  reg  [  1:0] wr_buf_sel_array_result;
  wire         after_inv_reg;
  wire         bht_flop_clk;
  wire         bht_flop_clk_en;
  wire         bht_ghr_updt_clk;
  wire         bht_ghr_updt_clk_en;
  wire         bht_inv_cnt_clk;
  wire         bht_inv_cnt_clk_en;
  wire [  9:0] bht_inval_cnt;
  wire         bht_pipe_clk;
  wire         bht_pipe_clk_en;
  wire         bht_pre_array_clk_en;
  wire [ 63:0] bht_pre_data_out;
  wire [ 31:0] bht_pre_ntaken_data;
  wire [ 31:0] bht_pre_taken_data;
  wire         bht_pred_array_cen_b;
  wire [ 63:0] bht_pred_array_din;
  wire         bht_pred_array_gwen;
  wire         bht_pred_array_rd;
  wire [ 31:0] bht_pred_array_wen_b;
  wire         bht_pred_array_wr;
  wire [ 63:0] bht_pred_bwen;
  wire         bht_sel_array_cen_b;
  wire         bht_sel_array_clk_en;
  wire [ 15:0] bht_sel_array_din;
  wire         bht_sel_array_gwen;
  wire         bht_sel_array_rd;
  wire [  7:0] bht_sel_array_wen_b;
  wire         bht_sel_array_wr;
  wire [ 15:0] bht_sel_bwen;
  wire [ 15:0] bht_sel_data;
  wire [ 15:0] bht_sel_data_out;
  wire         bht_wr_buf_create_vld;
  wire         bht_wr_buf_not_empty;
  wire [  9:0] bht_wr_buf_pred_updt_index;
  wire [ 63:0] bht_wr_buf_pred_updt_val;
  wire         bht_wr_buf_retire_vld;
  wire [  6:0] bht_wr_buf_sel_updt_index;
  wire [ 15:0] bht_wr_buf_sel_updt_val;
  wire         bht_wr_buf_updt_vld;
  wire         bht_wr_buf_updt_vld_for_gateclk;
  wire         bju_check_updt_vld;
  wire [ 21:0] bju_ghr;
  wire         bju_mispred;
  wire [  1:0] bju_pred_rst;
  wire [  1:0] bju_sel_rst;
  wire         buf_condbr_taken;
  wire [  9:0] buf_cur_pc;
  wire [ 21:0] buf_ghr;
  wire [  1:0] buf_pred_rst;
  wire [  1:0] buf_sel_rst;
  wire [  3:0] entry_create;
  wire [  3:0] entry_retire;
  wire [ 36:0] entry_updt_data;
  wire         ghr_updt_vld;
  wire         ip_vld;
  wire [  1:0] memory_sel_array_result;
  wire [  3:0] pre_offset_if_0;
  wire [  3:0] pre_offset_if_1;
  wire [  3:0] pre_offset_ip_0;
  wire [  3:0] pre_offset_ip_1;
  wire [ 15:0] pre_offset_onehot;
  wire [ 15:0] pre_offset_onehot_if;
  wire [ 15:0] pre_offset_onehot_ip;
  wire         pre_reg_clk;
  wire         pre_reg_clk_en;
  wire         pred_array_check_updt_vld;
  wire         rtu_con_br_vld;
  wire         rtughr_updt_vld;
  wire         sel_array_check_updt_vld;
  wire [  1:0] sel_array_val;
  wire [  1:0] sel_array_val_cur;
  wire         sel_reg_clk;
  wire         sel_reg_clk_en;
  wire         vghr_ip_updt_vld;
  wire         vghr_lbuf_updt_vld;
  wire         wr_buf_clk;
  wire         wr_buf_clk_en;
  wire         wr_buf_hit;
  wire         wr_buf_hit_0;
  wire         wr_buf_hit_1;
  wire         wr_buf_hit_2;
  wire         wr_buf_hit_3;
  wire         wr_buf_pre_hit_0;
  wire         wr_buf_pre_hit_1;
  wire         wr_buf_pre_hit_2;
  wire         wr_buf_pre_hit_3;
  wire         wr_buf_rd;
  wire         wr_buf_sel_hit_0;
  wire         wr_buf_sel_hit_1;
  wire         wr_buf_sel_hit_2;
  wire         wr_buf_sel_hit_3;
  reg  [ 31:0] bht_train_drop_count_q;
  reg  [ 31:0] bht_ipdp_pre_array_data_ntake_q;
  reg  [ 31:0] bht_ipdp_pre_array_data_taken_q;
  reg  [ 15:0] bht_ipdp_pre_offset_onehot_q;
  reg  [1 : 0] bht_ipdp_sel_array_result_q;
  reg  [ 21:0] bht_ipdp_vghr_q;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  //CK860 Use Bi-Mode BHT
  //Total Size is 64K Bits
  //2*Pre_Array + 1*Sel_Array
  //2*Pre_Array = Taken_pre_array + Not_Taken_pre_array
  //  1KEntry * 32Bits * 2Array  ----  Use one Memory
  //1*Sel_Array
  //  128Entry * 16Bits
  //==========================================================
  //          Signal Input to BHT Predict Array
  //==========================================================
  //--------------------Chip Enable---------------------------
  //the BHT Predict Array is enable when:
  //1.Write Enable
  //  a.BHT INV
  //  b.BHT can be updated
  //2.Read Enable
  //  (When Update VGHR, BHT need read)
  //  a.after invalidated
  //  b.conditional branch happen in ip stage
  //  c.the cycle BJU mispredict
  //  d.the cycle after BJU mispredict
  //  e.the cycle RTU flush
  //  f.the cycle after RTU flush
  assign bht_pred_array_wr = bht_inv_on_q || bht_wr_buf_updt_vld;

  assign bht_pred_array_rd = after_inv_reg || ipctrl_bht_con_br_vld && !lbuf_bht_active_state ||
    lbuf_bht_con_br_vld && lbuf_bht_active_state || bju_mispred || after_bju_mispred_q ||
    rtu_ifu_flush || local_recover_vld || after_rtu_ifu_flush_q;

  assign bht_pred_array_cen_b =
    !(bht_inv_on_q || after_inv_reg ||
      (bht_wr_buf_updt_vld || ipctrl_bht_con_br_vld && !lbuf_bht_active_state ||
       lbuf_bht_con_br_vld && lbuf_bht_active_state || bju_mispred || after_bju_mispred_q ||
       rtu_ifu_flush || local_recover_vld || after_rtu_ifu_flush_q) && cp0_ifu_bht_en);

  //Memory Gate Clock Enable
  assign
    bht_pre_array_clk_en = bht_inv_on_q || bht_wr_buf_updt_vld_for_gateclk || bht_pred_array_rd;

  //-------------------Write Enable---------------------------
  assign bht_pred_array_gwen = !bht_pred_array_wr;

  //-------------------Write Bit Enable-----------------------
  assign bht_pred_array_wen_b[31:0] = bht_inv_on_q ?
    32'b0 : (bht_wr_buf_pred_updt_sel_b[31:0] | {32{!bht_wr_buf_updt_vld}});

  assign bht_pred_bwen[63:0] = {
    {2{bht_pred_array_wen_b[31]}},
    {2{bht_pred_array_wen_b[30]}},
    {2{bht_pred_array_wen_b[29]}},
    {2{bht_pred_array_wen_b[28]}},
    {2{bht_pred_array_wen_b[27]}},
    {2{bht_pred_array_wen_b[26]}},
    {2{bht_pred_array_wen_b[25]}},
    {2{bht_pred_array_wen_b[24]}},
    {2{bht_pred_array_wen_b[23]}},
    {2{bht_pred_array_wen_b[22]}},
    {2{bht_pred_array_wen_b[21]}},
    {2{bht_pred_array_wen_b[20]}},
    {2{bht_pred_array_wen_b[19]}},
    {2{bht_pred_array_wen_b[18]}},
    {2{bht_pred_array_wen_b[17]}},
    {2{bht_pred_array_wen_b[16]}},
    {2{bht_pred_array_wen_b[15]}},
    {2{bht_pred_array_wen_b[14]}},
    {2{bht_pred_array_wen_b[13]}},
    {2{bht_pred_array_wen_b[12]}},
    {2{bht_pred_array_wen_b[11]}},
    {2{bht_pred_array_wen_b[10]}},
    {2{bht_pred_array_wen_b[9]}},
    {2{bht_pred_array_wen_b[8]}},
    {2{bht_pred_array_wen_b[7]}},
    {2{bht_pred_array_wen_b[6]}},
    {2{bht_pred_array_wen_b[5]}},
    {2{bht_pred_array_wen_b[4]}},
    {2{bht_pred_array_wen_b[3]}},
    {2{bht_pred_array_wen_b[2]}},
    {2{bht_pred_array_wen_b[1]}},
    {2{bht_pred_array_wen_b[0]}}
  };

  //==========================================================
  //              Predict Array Data Input
  //==========================================================
  assign bht_pred_array_din[63:0] = bht_inv_on_q ? 64'h3333_3333_3333_3333 :
    bht_wr_buf_pred_updt_val[63:0];

  //==========================================================
  //                 Predict Array Index
  //==========================================================
  //Predict Array Priority:
  //1.bht_inv_index
  //2.bht_pred_array_read_index
  //3.bht_pred_array_write_index
  always @(*) begin : p_bht_pred_array_index_comb
    if (bht_inv_on_q || after_inv_reg) begin
      bht_pred_array_index[9:0] = bht_inval_cnt[9:0];
    end else if (bht_pred_array_rd) begin
      bht_pred_array_index[9:0] = bht_pred_array_rd_index[9:0];
    end else  //bht_pred_array_wr
    begin
      bht_pred_array_index[9:0] = bht_wr_buf_pred_updt_index[9:0];
    end
  end

  //{vghr[12:9], {vghr_reg[8:3]^vghr_reg[20:15]}} is the basic index of read
  //pc[6:3] ^ vghr[3:0] to select result out from sel array
  //vghr[3:0] in ip stage is {if_vghr[2:0], ip_con_br_taken}
  always @(*) begin : p_bht_pred_array_rd_index_comb
    if (rtu_ifu_flush) begin
      bht_pred_array_rd_index[9:0] = {
        committed_recover_ghr[13:10], {committed_recover_ghr[9:4] ^ committed_recover_ghr[21:16]}
      };
    end else if (bju_mispred && !iu_ifu_bht_check_vld) begin
      bht_pred_array_rd_index[9:0] = {bju_ghr[13:10], {bju_ghr[9:4] ^ bju_ghr[21:16]}};
    end else if (bju_mispred && iu_ifu_bht_check_vld) begin
      bht_pred_array_rd_index[9:0] = {bju_ghr[12:9], {bju_ghr[8:3] ^ bju_ghr[20:15]}};
    end else if (local_recover_vld) begin
      bht_pred_array_rd_index[9:0] = {
        local_recover_ghr[13:10], local_recover_ghr[9:4] ^ local_recover_ghr[21:16]
      };
    end else if (after_bju_mispred_q || after_rtu_ifu_flush_q) begin
      bht_pred_array_rd_index[9:0] = {vghr_q[12:9], {vghr_q[8:3] ^ vghr_q[20:15]}};
    end else  //ipctrl_bht_con_br_vld
    begin
      bht_pred_array_rd_index[9:0] = {vghr_q[11:8], {vghr_q[7:2] ^ vghr_q[19:14]}};
    end
  end

  //==========================================================
  //          Signal Input to BHT Select Array
  //==========================================================
  //--------------------Chip Enable---------------------------
  //the BHT Select Array is enable when:
  //1.Write Enable
  //  a.BHT INV
  //  b.BHT can be updated
  //2.Read Enable
  //  a.after invalidated
  //  b.change flow read
  //  c.sequence read
  assign bht_sel_array_wr = bht_inv_on_q || bht_wr_buf_updt_vld;

  assign bht_sel_array_rd = after_inv_reg || pcgen_bht_chgflw || pcgen_bht_seq_read;

  assign bht_sel_array_cen_b =
    !(bht_inv_on_q || after_inv_reg ||
      (bht_wr_buf_updt_vld || pcgen_bht_chgflw || pcgen_bht_seq_read) && cp0_ifu_bht_en);

  //Memory Gate Clock Enable
  assign bht_sel_array_clk_en = bht_inv_on_q || bht_wr_buf_updt_vld_for_gateclk || after_inv_reg ||
    pcgen_bht_seq_read || pcgen_bht_chgflw_short;

  //-------------------Write Enable---------------------------
  assign bht_sel_array_gwen = !bht_sel_array_wr;

  //-------------------Write Bit Enable-----------------------
  assign bht_sel_array_wen_b[7:0] = bht_inv_on_q ?
    8'b0 : (bht_wr_buf_sel_updt_sel_b[7:0] | {8{!bht_wr_buf_updt_vld}});

  assign bht_sel_bwen[15:0] = {
    {2{bht_sel_array_wen_b[7]}},
    {2{bht_sel_array_wen_b[6]}},
    {2{bht_sel_array_wen_b[5]}},
    {2{bht_sel_array_wen_b[4]}},
    {2{bht_sel_array_wen_b[3]}},
    {2{bht_sel_array_wen_b[2]}},
    {2{bht_sel_array_wen_b[1]}},
    {2{bht_sel_array_wen_b[0]}}
  };

  //==========================================================
  //              Select Array Data Input
  //==========================================================
  assign bht_sel_array_din[15:0] = bht_inv_on_q ? 16'b0 : bht_wr_buf_sel_updt_val[15:0];

  //==========================================================
  //                 Select Array Index
  //==========================================================
  //Select Array Priority:
  //1.bht_inv_index
  //2.bht_select_array_read_index
  //3.bht_select_array_write_index
  always @(*) begin : p_bht_sel_array_index_comb
    if (bht_inv_on_q || after_inv_reg) begin
      bht_sel_array_index[6:0] = bht_inval_cnt[6:0];
    end else if (bht_sel_array_rd) begin
      bht_sel_array_index[6:0] = pcgen_bht_pcindex[9:3];
    end else  //bht_sel_array_wr
    begin
      bht_sel_array_index[6:0] = bht_wr_buf_sel_updt_index[6:0];
    end
  end

  //==========================================================
  //                GHR Update Gate Clock
  //==========================================================
  rv32_ifu_clk_cell u_bht_ghr_updt_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (bht_ghr_updt_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (bht_ghr_updt_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign bht_ghr_updt_clk_en = bht_inv_on_q ||
    cp0_ifu_bht_en && (rtu_ifu_flush || local_recover_vld || rtu_con_br_vld || iu_ifu_chgflw_vld ||
                       ipctrl_bht_con_br_gateclk_en || lbuf_bht_con_br_vld);

  //==========================================================
  //                   Update RTU GHR
  //==========================================================
  //rtu_ghr is used to record con_br happen in rtu
  //1.BHT INV
  //2.RTU Update
  assign rtughr_updt_vld = cp0_ifu_bht_en && rtu_con_br_vld;

  assign
    rtu_con_br_vld = rtu_ifu_retire0_condbr || rtu_ifu_retire1_condbr || rtu_ifu_retire2_condbr;

  always @(posedge bht_ghr_updt_clk or negedge cpurst_b) begin : p_rtughr
    if (!cpurst_b) begin
      rtughr_q[21:0] <= 22'b0;
    end else if (bht_inv_on_q) begin
      rtughr_q[21:0] <= 22'b0;
    end else if (rtughr_updt_vld) begin
      rtughr_q[21:0] <= rtughr_nxt[21:0];
    end else begin
      rtughr_q[21:0] <= committed_recover_ghr[21:0];
    end
  end

  always @(*) begin : p_rtughr_comb
    case ({
      rtu_ifu_retire0_condbr, rtu_ifu_retire1_condbr, rtu_ifu_retire2_condbr
    })
      3'b000: rtughr_nxt[21:0] = rtughr_q[21:0];
      3'b001: rtughr_nxt[21:0] = {rtughr_q[20:0], rtu_ifu_retire2_condbr_taken};
      3'b010: rtughr_nxt[21:0] = {rtughr_q[20:0], rtu_ifu_retire1_condbr_taken};
      3'b100: rtughr_nxt[21:0] = {rtughr_q[20:0], rtu_ifu_retire0_condbr_taken};
      3'b101:
      rtughr_nxt[21:0] = {
        rtughr_q[19:0], rtu_ifu_retire0_condbr_taken, rtu_ifu_retire2_condbr_taken
      };
      3'b110:
      rtughr_nxt[21:0] = {
        rtughr_q[19:0], rtu_ifu_retire0_condbr_taken, rtu_ifu_retire1_condbr_taken
      };
      3'b011:
      rtughr_nxt[21:0] = {
        rtughr_q[19:0], rtu_ifu_retire1_condbr_taken, rtu_ifu_retire2_condbr_taken
      };
      3'b111:
      rtughr_nxt[21:0] = {
        rtughr_q[18:0],
        rtu_ifu_retire0_condbr_taken,
        rtu_ifu_retire1_condbr_taken,
        rtu_ifu_retire2_condbr_taken
      };
      default: rtughr_nxt[21:0] = rtughr_q[21:0];
    endcase
  end

  //==========================================================
  //                   Update VGHR
  //==========================================================
  //vghr is used to record con_br happen in ifu
  //1.BHT INV
  //2.RTU Flush Update
  //3.BJU Mispredict
  //4.IFU Update
  assign ghr_updt_vld       = cp0_ifu_bht_en && iu_ifu_chgflw_vld;

  assign vghr_lbuf_updt_vld = cp0_ifu_bht_en && lbuf_bht_con_br_vld;

  assign vghr_ip_updt_vld   = cp0_ifu_bht_en && ipctrl_bht_con_br_vld;

  always @(posedge bht_ghr_updt_clk or negedge cpurst_b) begin : p_vghr
    if (!cpurst_b) begin
      vghr_q[21:0] <= 22'b0;
    end else if (bht_inv_on_q) begin
      vghr_q[21:0] <= 22'b0;
    end else if (rtu_ifu_flush && cp0_ifu_bht_en) begin
      vghr_q[21:0] <= committed_recover_ghr[21:0];
    end else if (local_recover_vld && !ghr_updt_vld) begin
      vghr_q[21:0] <= local_recover_ghr;
    end else if (ghr_updt_vld && iu_ifu_bht_check_vld) begin
      vghr_q[21:0] <= {bju_ghr[20:0], iu_ifu_bht_condbr_taken};
    end else if (ghr_updt_vld && !iu_ifu_bht_check_vld) begin
      vghr_q[21:0] <= bju_ghr[21:0];
    end else if (vghr_lbuf_updt_vld) begin
      vghr_q[21:0] <= {vghr_q[20:0], lbuf_bht_con_br_taken};
    end else if (vghr_ip_updt_vld && !lbuf_bht_active_state) begin
      vghr_q[21:0] <= {vghr_q[20:0], ipctrl_bht_con_br_taken};
    end else begin
      vghr_q[21:0] <= vghr_q[21:0];
    end
  end

  //==========================================================
  //              Select Array Final Result
  //==========================================================
  //----------------Memory Data Out Reg-----------------------
  //store memory dout value to reg 
  //in case of memory writing changes the value of dout
  rv32_ifu_clk_cell u_sel_reg_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (sel_reg_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (sel_reg_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign sel_reg_clk_en = sel_rd_q || bht_inv_on_q;

  always @(posedge sel_reg_clk or negedge cpurst_b) begin : p_bht_sel_data
    if (!cpurst_b) begin
      bht_sel_data_q[15:0] <= 16'b0;
    end else if (bht_inv_on_q) begin
      bht_sel_data_q[15:0] <= 16'b0;
    end else if (sel_rd_q) begin
      bht_sel_data_q[15:0] <= bht_sel_data_out[15:0];
    end  //Memory Dout
    else begin
      bht_sel_data_q[15:0] <= bht_sel_data_q[15:0];
    end
  end

  //flop bht_sel_array_rd
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sel_rd
    if (!cpurst_b) begin
      sel_rd_q <= 1'b0;
    end else if (bht_inv_on_q) begin
      sel_rd_q <= 1'b0;
    end else if (bht_sel_array_rd && !ifctrl_bht_stall) begin
      sel_rd_q <= 1'b1;
    end else begin
      sel_rd_q <= 1'b0;
    end
  end

  //select sel data from memory dout or memory flop reg
  assign bht_sel_data[15:0] = (sel_rd_q) ? bht_sel_data_out[15:0] : bht_sel_data_q[15:0];

  always @(*) begin : p_if_pc_onehot_comb
    case (pcgen_bht_ifpc[5:3])
      3'b000:  if_pc_onehot[7:0] = 8'b0000_0001;
      3'b001:  if_pc_onehot[7:0] = 8'b0000_0010;
      3'b010:  if_pc_onehot[7:0] = 8'b0000_0100;
      3'b011:  if_pc_onehot[7:0] = 8'b0000_1000;
      3'b100:  if_pc_onehot[7:0] = 8'b0001_0000;
      3'b101:  if_pc_onehot[7:0] = 8'b0010_0000;
      3'b110:  if_pc_onehot[7:0] = 8'b0100_0000;
      3'b111:  if_pc_onehot[7:0] = 8'b1000_0000;
      default: if_pc_onehot[7:0] = 8'b0000_0001;
    endcase
  end

  assign sel_array_val_cur[1:0] = ({2{if_pc_onehot[0]}} & bht_sel_data[1:0]) |
    ({2{if_pc_onehot[1]}} & bht_sel_data[3:2]) | ({2{if_pc_onehot[2]}} & bht_sel_data[5:4]) |
    ({2{if_pc_onehot[3]}} & bht_sel_data[7:6]) | ({2{if_pc_onehot[4]}} & bht_sel_data[9:8]) |
    ({2{if_pc_onehot[5]}} & bht_sel_data[11:10]) | ({2{if_pc_onehot[6]}} & bht_sel_data[13:12]) |
    ({2{if_pc_onehot[7]}} & bht_sel_data[15:14]);

  //When 32 Bit con_br locate at H8
  //BHT Predict infor flop to IP stage should use the value of last cycle
  assign memory_sel_array_result[1:0] = (ipctrl_bht_more_br) ? sel_array_val_q[1:0] :
    sel_array_val_cur[1:0];

  //wr_buf bypass select
  assign
    sel_array_val[1:0] = (wr_buf_hit) ? wr_buf_sel_array_result[1:0] : memory_sel_array_result[1:0];

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_sel_array_val
    if (!cpurst_b) begin
      sel_array_val_q[1:0] <= 2'b00;
    end else begin
      sel_array_val_q[1:0] <= sel_array_val[1:0];
    end
  end

  //==========================================================
  //              Predict Array Flop Result
  //==========================================================
  //-----------------Memory Data Out--------------------------
  //Data read out from pre_array memory dout
  assign bht_pre_taken_data[31:0] = {
    bht_pre_data_out[61:60],
    bht_pre_data_out[57:56],
    bht_pre_data_out[53:52],
    bht_pre_data_out[49:48],
    bht_pre_data_out[45:44],
    bht_pre_data_out[41:40],
    bht_pre_data_out[37:36],
    bht_pre_data_out[33:32],
    bht_pre_data_out[29:28],
    bht_pre_data_out[25:24],
    bht_pre_data_out[21:20],
    bht_pre_data_out[17:16],
    bht_pre_data_out[13:12],
    bht_pre_data_out[9:8],
    bht_pre_data_out[5:4],
    bht_pre_data_out[1:0]
  };

  assign bht_pre_ntaken_data[31:0] = {
    bht_pre_data_out[63:62],
    bht_pre_data_out[59:58],
    bht_pre_data_out[55:54],
    bht_pre_data_out[51:50],
    bht_pre_data_out[47:46],
    bht_pre_data_out[43:42],
    bht_pre_data_out[39:38],
    bht_pre_data_out[35:34],
    bht_pre_data_out[31:30],
    bht_pre_data_out[27:26],
    bht_pre_data_out[23:22],
    bht_pre_data_out[19:18],
    bht_pre_data_out[15:14],
    bht_pre_data_out[11:10],
    bht_pre_data_out[7:6],
    bht_pre_data_out[3:2]
  };

  //----------------Memory Data Out Reg-----------------------
  //store memory dout value to reg 
  //in case of memory writing changes the value of dout
  rv32_ifu_clk_cell u_pre_reg_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (pre_reg_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (pre_reg_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign pre_reg_clk_en = pre_rd_q || bht_inv_on_q;

  //Memory data output reg updata rule:
  //  a.if pre_rd_flop == 1, memory data output reg write data in
  //  b.if pre_rd_flop != 1, memory data output reg hold origin value
  always @(posedge pre_reg_clk or negedge cpurst_b) begin : p_pre_taken
    if (!cpurst_b) begin
      pre_taken_q[31:0] <= 32'b0;
    end else if (bht_inv_on_q) begin
      pre_taken_q[31:0] <= 32'b0;
    end else if (pre_rd_q) begin
      pre_taken_q[31:0] <= bht_pre_taken_data[31:0];
    end else begin
      pre_taken_q[31:0] <= pre_taken_q[31:0];
    end
  end

  always @(posedge pre_reg_clk or negedge cpurst_b) begin : p_pre_ntaken
    if (!cpurst_b) begin
      pre_ntaken_q[31:0] <= 32'b0;
    end else if (bht_inv_on_q) begin
      pre_ntaken_q[31:0] <= 32'b0;
    end else if (pre_rd_q) begin
      pre_ntaken_q[31:0] <= bht_pre_ntaken_data[31:0];
    end else begin
      pre_ntaken_q[31:0] <= pre_ntaken_q[31:0];
    end
  end

  //flop bht_pred_array_rd
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_pre_rd
    if (!cpurst_b) begin
      pre_rd_q <= 1'b0;
    end else if (bht_inv_on_q) begin
      pre_rd_q <= 1'b0;
    end else if (bht_pred_array_rd) begin
      pre_rd_q <= 1'b1;
    end else begin
      pre_rd_q <= 1'b0;
    end
  end

  //pipe taken & ntaken data to be selected in IP stage
  always @(*) begin : p_pre_array_pipe_taken_data_comb
    if (pre_rd_q && ip_vld && !lbuf_bht_active_state) begin
      pre_array_pipe_taken_data[31:0] = bht_pre_taken_data[31:0];
    end else if (pre_rd_q && lbuf_bht_con_br_vld && lbuf_bht_active_state) begin
      pre_array_pipe_taken_data[31:0] = bht_pre_taken_data[31:0];
    end else begin
      pre_array_pipe_taken_data[31:0] = pre_taken_q[31:0];
    end
  end

  always @(*) begin : p_pre_array_pipe_ntaken_data_comb
    if (pre_rd_q && ip_vld && !lbuf_bht_active_state) begin
      pre_array_pipe_ntaken_data[31:0] = bht_pre_ntaken_data[31:0];
    end else if (pre_rd_q && lbuf_bht_con_br_vld && lbuf_bht_active_state) begin
      pre_array_pipe_ntaken_data[31:0] = bht_pre_ntaken_data[31:0];
    end else begin
      pre_array_pipe_ntaken_data[31:0] = pre_ntaken_q[31:0];
    end
  end

  //==========================================================
  //                  BHT Wirte Buffer
  //==========================================================
  //wr_buf update BHT should under following condition:
  //1.one conditional branch instruction checked in bju || 
  //2.any valid entry in write buffer &&
  //3.no read request(include select array and predictarra y)
  assign bht_wr_buf_updt_vld_for_gateclk = (bju_check_updt_vld || bht_wr_buf_not_empty);

  assign bht_wr_buf_updt_vld = (bju_check_updt_vld || bht_wr_buf_not_empty) &&
    !(after_inv_reg || ipctrl_bht_con_br_vld || after_bju_mispred_q || rtu_ifu_flush ||
      local_recover_vld || after_rtu_ifu_flush_q || local_recover_vld ||
      pcgen_bht_chgflw && !lbuf_bht_active_state || pcgen_bht_seq_read);

  assign bju_check_updt_vld = (pred_array_check_updt_vld || sel_array_check_updt_vld) &&
    iu_ifu_bht_check_vld;

  assign pred_array_check_updt_vld = !(((bju_pred_rst[1:0] == 2'b00) &&  //saturated
    !iu_ifu_bht_condbr_taken) || ((bju_pred_rst[1:0] == 2'b11) &&  //saturated
    iu_ifu_bht_condbr_taken));

  assign sel_array_check_updt_vld = !(((bju_sel_rst[1:0] == 2'b00) &&  //saturated
    !iu_ifu_bht_condbr_taken) || ((bju_sel_rst[1:0] == 2'b11) &&  //saturated
    iu_ifu_bht_condbr_taken) || ((bju_sel_rst[1] == 1'b0) &&  //bi-mode logic
    iu_ifu_bht_condbr_taken && !iu_ifu_chgflw_vld) || ((bju_sel_rst[1] == 1'b1) &&  //bi-mode logic
    !iu_ifu_bht_condbr_taken && !iu_ifu_chgflw_vld));

  assign bht_wr_buf_create_vld = bju_check_updt_vld &&
    (bht_pred_array_rd || bht_sel_array_rd || bht_wr_buf_not_empty) && cp0_ifu_bht_en;

  assign bht_wr_buf_retire_vld = bht_wr_buf_not_empty && !(bht_pred_array_rd || bht_sel_array_rd) &&
    cp0_ifu_bht_en;

  assign bht_wr_buf_not_empty = entry_vld;

  //==========================================================
  //               BHT Write Buffer Pointer
  //==========================================================
  rv32_ifu_clk_cell u_wr_buf_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (wr_buf_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (wr_buf_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign
    wr_buf_clk_en = bju_check_updt_vld || bht_wr_buf_not_empty || bht_inv_on_q || ifctrl_bht_inv;

  //Write Buffer has 4 Entry
  //Use one-hot pointer
  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_create_ptr
    if (!cpurst_b) begin
      create_ptr_q[3:0] <= 4'b0001;
    end else if (bht_inv_on_q) begin
      create_ptr_q[3:0] <= 4'b0001;
    end else if (bht_wr_buf_create_vld && !buf_full) begin
      create_ptr_q[3:0] <= {create_ptr_q[2:0], create_ptr_q[3]};
    end else begin
      create_ptr_q[3:0] <= create_ptr_q[3:0];
    end
  end

  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_retire_ptr
    if (!cpurst_b) begin
      retire_ptr_q[3:0] <= 4'b0001;
    end else if (bht_inv_on_q) begin
      retire_ptr_q[3:0] <= 4'b0001;
    end else if (bht_wr_buf_retire_vld) begin
      retire_ptr_q[3:0] <= {retire_ptr_q[2:0], retire_ptr_q[3]};
    end else begin
      retire_ptr_q[3:0] <= retire_ptr_q[3:0];
    end
  end

  assign entry_create[3:0] = {4{bht_wr_buf_create_vld && !buf_full}} & create_ptr_q[3:0];

  assign entry_retire[3:0] = {4{bht_wr_buf_retire_vld}} & retire_ptr_q[3:0];

  //==========================================================
  //             Four Write Buffer Entry
  //==========================================================
  assign entry_updt_data[36:0] = {
    //iu_ifu_bht_check_vld,
    iu_ifu_bht_condbr_taken,
    bju_sel_rst[1:0],
    bju_pred_rst[1:0],
    bju_ghr[21:0],
    iu_ifu_cur_pc[12:3]
  };

  //Entry 0
  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_entry0_vld
    if (!cpurst_b) begin
      entry0_vld_q <= 1'b0;
    end else if (bht_inv_on_q) begin
      entry0_vld_q <= 1'b0;
    end else if (entry_create[0]) begin
      entry0_vld_q <= 1'b1;
    end else if (entry_retire[0]) begin
      entry0_vld_q <= 1'b0;
    end else begin
      entry0_vld_q <= entry0_vld_q;
    end
  end

  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_entry0_data
    if (!cpurst_b) begin
      entry0_data_q[36:0] <= 37'b0;
    end else if (entry_create[0]) begin
      entry0_data_q[36:0] <= entry_updt_data[36:0];
    end else begin
      entry0_data_q[36:0] <= entry0_data_q[36:0];
    end
  end

  //Entry 1
  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_entry1_vld
    if (!cpurst_b) begin
      entry1_vld_q <= 1'b0;
    end else if (bht_inv_on_q) begin
      entry1_vld_q <= 1'b0;
    end else if (entry_create[1]) begin
      entry1_vld_q <= 1'b1;
    end else if (entry_retire[1]) begin
      entry1_vld_q <= 1'b0;
    end else begin
      entry1_vld_q <= entry1_vld_q;
    end
  end

  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_entry1_data
    if (!cpurst_b) begin
      entry1_data_q[36:0] <= 37'b0;
    end else if (entry_create[1]) begin
      entry1_data_q[36:0] <= entry_updt_data[36:0];
    end else begin
      entry1_data_q[36:0] <= entry1_data_q[36:0];
    end
  end

  //Entry 2
  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_entry2_vld
    if (!cpurst_b) begin
      entry2_vld_q <= 1'b0;
    end else if (bht_inv_on_q) begin
      entry2_vld_q <= 1'b0;
    end else if (entry_create[2]) begin
      entry2_vld_q <= 1'b1;
    end else if (entry_retire[2]) begin
      entry2_vld_q <= 1'b0;
    end else begin
      entry2_vld_q <= entry2_vld_q;
    end
  end

  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_entry2_data
    if (!cpurst_b) begin
      entry2_data_q[36:0] <= 37'b0;
    end else if (entry_create[2]) begin
      entry2_data_q[36:0] <= entry_updt_data[36:0];
    end else begin
      entry2_data_q[36:0] <= entry2_data_q[36:0];
    end
  end

  //Entry 3
  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_entry3_vld
    if (!cpurst_b) begin
      entry3_vld_q <= 1'b0;
    end else if (bht_inv_on_q) begin
      entry3_vld_q <= 1'b0;
    end else if (entry_create[3]) begin
      entry3_vld_q <= 1'b1;
    end else if (entry_retire[3]) begin
      entry3_vld_q <= 1'b0;
    end else begin
      entry3_vld_q <= entry3_vld_q;
    end
  end

  always @(posedge wr_buf_clk or negedge cpurst_b) begin : p_entry3_data
    if (!cpurst_b) begin
      entry3_data_q[36:0] <= 37'b0;
    end else if (entry_create[3]) begin
      entry3_data_q[36:0] <= entry_updt_data[36:0];
    end else begin
      entry3_data_q[36:0] <= entry3_data_q[36:0];
    end
  end

  //==========================================================
  //               Update Data Prepare
  //==========================================================
  //Entry data selected out
  always @(*) begin : p_entry_vld_comb
    case (retire_ptr_q[3:0])
      4'b0001: begin
        entry_vld        = entry0_vld_q;
        entry_data[36:0] = entry0_data_q[36:0];
      end
      4'b0010: begin
        entry_vld        = entry1_vld_q;
        entry_data[36:0] = entry1_data_q[36:0];
      end
      4'b0100: begin
        entry_vld        = entry2_vld_q;
        entry_data[36:0] = entry2_data_q[36:0];
      end
      4'b1000: begin
        entry_vld        = entry3_vld_q;
        entry_data[36:0] = entry3_data_q[36:0];
      end
      default: begin
        entry_vld        = 1'b0;
        entry_data[36:0] = 37'b0;
      end
    endcase
  end

  //Split Entry Data
  assign buf_condbr_taken  = entry_data[36];

  assign buf_sel_rst[1:0]  = entry_data[35:34];

  assign buf_pred_rst[1:0] = entry_data[33:32];

  assign buf_ghr[21:0]     = entry_data[31:10];

  assign buf_cur_pc[9:0]   = entry_data[9:0];

  //Buffer Full
  always @(*) begin : p_buf_full_comb
    case (create_ptr_q[3:0])
      4'b0001: buf_full = entry0_vld_q;
      4'b0010: buf_full = entry1_vld_q;
      4'b0100: buf_full = entry2_vld_q;
      4'b1000: buf_full = entry3_vld_q;
      default: buf_full = 1'b0;
    endcase
  end

  //Cur info to update BHT
  //May come from entry data or BJU data
  always @(*) begin : p_cur_condbr_taken_comb
    if (entry_vld) begin
      cur_condbr_taken  = buf_condbr_taken;
      cur_sel_rst[1:0]  = buf_sel_rst[1:0];
      cur_pred_rst[1:0] = buf_pred_rst[1:0];
      cur_ghr[21:0]     = buf_ghr[21:0];
      cur_cur_pc[9:0]   = buf_cur_pc[9:0];
    end else begin
      cur_condbr_taken  = iu_ifu_bht_condbr_taken;
      cur_sel_rst[1:0]  = bju_sel_rst[1:0];
      cur_pred_rst[1:0] = bju_pred_rst[1:0];
      cur_ghr[21:0]     = bju_ghr[21:0];
      cur_cur_pc[9:0]   = iu_ifu_cur_pc[12:3];
    end
  end

  //==========================================================
  //             predict array updt data
  //==========================================================
  always @(*) begin : p_pred_array_updt_data_comb
    case ({
      cur_pred_rst[1:0], cur_condbr_taken
    })
      3'b001:  pred_array_updt_data[1:0] = 2'b01;
      3'b011:  pred_array_updt_data[1:0] = 2'b10;
      3'b010:  pred_array_updt_data[1:0] = 2'b00;
      3'b110:  pred_array_updt_data[1:0] = 2'b10;
      3'b101:  pred_array_updt_data[1:0] = 2'b11;
      3'b100:  pred_array_updt_data[1:0] = 2'b01;
      3'b111:  pred_array_updt_data[1:0] = 2'b11;
      3'b000:  pred_array_updt_data[1:0] = 2'b00;
      default: pred_array_updt_data[1:0] = 2'b00;
    endcase
  end

  //Select 13:4 as pred array updt index
  assign bht_wr_buf_pred_updt_index[9:0] = {cur_ghr[13:10], {cur_ghr[9:4] ^ cur_ghr[21:16]}};

  //==========================================================
  //             select array updt data
  //==========================================================
  always @(*) begin : p_sel_array_updt_data_comb
    case ({
      cur_sel_rst[1:0], cur_condbr_taken
    })
      3'b001:  sel_array_updt_data[1:0] = 2'b01;
      3'b011:  sel_array_updt_data[1:0] = 2'b10;
      3'b010:  sel_array_updt_data[1:0] = 2'b00;
      3'b110:  sel_array_updt_data[1:0] = 2'b10;
      3'b101:  sel_array_updt_data[1:0] = 2'b11;
      3'b100:  sel_array_updt_data[1:0] = 2'b01;
      3'b000:  sel_array_updt_data[1:0] = 2'b00;
      3'b111:  sel_array_updt_data[1:0] = 2'b11;
      default: sel_array_updt_data[1:0] = 2'b00;
    endcase
  end

  assign bht_wr_buf_sel_updt_index[6:0] = cur_cur_pc[9:3];

  //==========================================================
  //                sel_array_updt_sel_b
  //==========================================================
  always @(*) begin : p_bht_wr_buf_sel_updt_sel_b_comb
    case (cur_cur_pc[2:0])
      3'b000:  bht_wr_buf_sel_updt_sel_b[7:0] = 8'b1111_1110;
      3'b001:  bht_wr_buf_sel_updt_sel_b[7:0] = 8'b1111_1101;
      3'b010:  bht_wr_buf_sel_updt_sel_b[7:0] = 8'b1111_1011;
      3'b011:  bht_wr_buf_sel_updt_sel_b[7:0] = 8'b1111_0111;
      3'b100:  bht_wr_buf_sel_updt_sel_b[7:0] = 8'b1110_1111;
      3'b101:  bht_wr_buf_sel_updt_sel_b[7:0] = 8'b1101_1111;
      3'b110:  bht_wr_buf_sel_updt_sel_b[7:0] = 8'b1011_1111;
      3'b111:  bht_wr_buf_sel_updt_sel_b[7:0] = 8'b0111_1111;
      default: bht_wr_buf_sel_updt_sel_b[7:0] = 8'b1111_1111;
    endcase
  end

  //==========================================================
  //                pred_array_updt_sel_b
  //==========================================================
  always @(*) begin : p_bht_wr_buf_pred_updt_sel_b_comb
    case ({
      (cur_cur_pc[3:0] ^ cur_ghr[3:0]), !cur_sel_rst[1]
    })
      5'b0000_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_1111_1110;
      5'b0000_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_1111_1101;
      5'b0001_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_1111_1011;
      5'b0001_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_1111_0111;
      5'b0010_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_1110_1111;
      5'b0010_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_1101_1111;
      5'b0011_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_1011_1111;
      5'b0011_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_0111_1111;
      5'b0100_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1110_1111_1111;
      5'b0100_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1101_1111_1111;
      5'b0101_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1011_1111_1111;
      5'b0101_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_0111_1111_1111;
      5'b0110_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1110_1111_1111_1111;
      5'b0110_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1101_1111_1111_1111;
      5'b0111_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1011_1111_1111_1111;
      5'b0111_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_0111_1111_1111_1111;

      5'b1000_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1110_1111_1111_1111_1111;
      5'b1000_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1101_1111_1111_1111_1111;
      5'b1001_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1011_1111_1111_1111_1111;
      5'b1001_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_0111_1111_1111_1111_1111;
      5'b1010_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1110_1111_1111_1111_1111_1111;
      5'b1010_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1101_1111_1111_1111_1111_1111;
      5'b1011_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1011_1111_1111_1111_1111_1111;
      5'b1011_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_0111_1111_1111_1111_1111_1111;
      5'b1100_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1110_1111_1111_1111_1111_1111_1111;
      5'b1100_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1101_1111_1111_1111_1111_1111_1111;
      5'b1101_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1011_1111_1111_1111_1111_1111_1111;
      5'b1101_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_0111_1111_1111_1111_1111_1111_1111;
      5'b1110_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1110_1111_1111_1111_1111_1111_1111_1111;
      5'b1110_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1101_1111_1111_1111_1111_1111_1111_1111;
      5'b1111_0: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1011_1111_1111_1111_1111_1111_1111_1111;
      5'b1111_1: bht_wr_buf_pred_updt_sel_b[31:0] = 32'b0111_1111_1111_1111_1111_1111_1111_1111;
      default:   bht_wr_buf_pred_updt_sel_b[31:0] = 32'b1111_1111_1111_1111_1111_1111_1111_1111;
    endcase
  end

  assign bht_wr_buf_pred_updt_val[63:0] = {32{pred_array_updt_data[1:0]}};

  assign bht_wr_buf_sel_updt_val[15:0]  = {8{sel_array_updt_data[1:0]}};

  //==========================================================
  //                Pipe Data to IP Stage
  //==========================================================
  //BHT to IP Pipe Clock
  rv32_ifu_clk_cell u_bht_pipe_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (bht_pipe_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (bht_pipe_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign bht_pipe_clk_en = bht_inv_on_q || ifctrl_bht_pipedown || lbuf_bht_con_br_vld;

  //-------------------Pre Array Result-----------------------
  //32-Bit Predict Array Result
  always @(posedge bht_pipe_clk or negedge cpurst_b) begin : p_bht_ipdp_pre_array_data_taken
    if (!cpurst_b) begin
      bht_ipdp_pre_array_data_taken_q[31:0] <= 32'b0;
    end else if (bht_inv_on_q) begin
      bht_ipdp_pre_array_data_taken_q[31:0] <= 32'b0;
    end else if (ifctrl_bht_pipedown && cp0_ifu_bht_en && bht_pred_array_rd) begin
      bht_ipdp_pre_array_data_taken_q[31:0] <= pre_array_pipe_taken_data[31:0];
    end else begin
      bht_ipdp_pre_array_data_taken_q[31:0] <= bht_ipdp_pre_array_data_taken_q[31:0];
    end
  end

  always @(posedge bht_pipe_clk or negedge cpurst_b) begin : p_bht_ipdp_pre_array_data_ntake
    if (!cpurst_b) begin
      bht_ipdp_pre_array_data_ntake_q[31:0] <= 32'b0;
    end else if (bht_inv_on_q) begin
      bht_ipdp_pre_array_data_ntake_q[31:0] <= 32'b0;
    end else if (ifctrl_bht_pipedown && cp0_ifu_bht_en && bht_pred_array_rd) begin
      bht_ipdp_pre_array_data_ntake_q[31:0] <= pre_array_pipe_ntaken_data[31:0];
    end else begin
      bht_ipdp_pre_array_data_ntake_q[31:0] <= bht_ipdp_pre_array_data_ntake_q[31:0];
    end
  end

  assign
    ip_vld = ipctrl_bht_vld || after_rtu_ifu_flush_q || local_recover_vld || after_bju_mispred_q;

  //-------------Pre Array offset One-hot---------------------
  //Predict Array offset = vghr[3:0] ^ pc[7:4]
  //And then trans it to one-hot
  assign pre_offset_ip_0[3:0] = ipdp_bht_vpc[6:3] ^ pre_vghr_offset_0[3:0];

  assign pre_offset_ip_1[3:0] = ipdp_bht_vpc[6:3] ^ pre_vghr_offset_1[3:0];

  assign pre_offset_if_0[3:0] = pcgen_bht_ifpc[6:3] ^ pre_vghr_offset_0[3:0];

  assign pre_offset_if_1[3:0] = pcgen_bht_ifpc[6:3] ^ pre_vghr_offset_1[3:0];

  //offset_0 means ip con_branch not valid
  always @(*) begin : p_pre_vghr_offset_0_comb
    if (rtu_ifu_flush) begin
      pre_vghr_offset_0[3:0] = committed_recover_ghr[3:0];
    end else if (bju_mispred && !iu_ifu_bht_check_vld) begin
      pre_vghr_offset_0[3:0] = bju_ghr[3:0];
    end else if (bju_mispred && iu_ifu_bht_check_vld) begin
      pre_vghr_offset_0[3:0] = {bju_ghr[2:0], iu_ifu_bht_condbr_taken};
    end else if (local_recover_vld) begin
      pre_vghr_offset_0[3:0] = local_recover_ghr[3:0];
    end else begin
      pre_vghr_offset_0[3:0] = vghr_q[3:0];
    end
  end

  //offset_1 means ip con_branch valid
  always @(*) begin : p_pre_vghr_offset_1_comb
    if (rtu_ifu_flush) begin
      pre_vghr_offset_1[3:0] = committed_recover_ghr[3:0];
    end else if (bju_mispred && !iu_ifu_bht_check_vld) begin
      pre_vghr_offset_1[3:0] = bju_ghr[3:0];
    end else if (bju_mispred && iu_ifu_bht_check_vld) begin
      pre_vghr_offset_1[3:0] = {bju_ghr[2:0], iu_ifu_bht_condbr_taken};
    end else if (local_recover_vld) begin
      pre_vghr_offset_1[3:0] = local_recover_ghr[3:0];
    end else if (after_bju_mispred_q || after_rtu_ifu_flush_q) begin
      pre_vghr_offset_1[3:0] = vghr_q[3:0];
    end else begin
      pre_vghr_offset_1[3:0] = {vghr_q[2:0], ipctrl_bht_con_br_taken};
    end
  end

  assign pre_offset_onehot[15:0] = (ipctrl_bht_more_br) ? pre_offset_onehot_ip[15:0] :
    pre_offset_onehot_if[15:0];

  assign pre_offset_onehot_ip[15:0] = (ipctrl_bht_con_br_vld) ? pre_offset_onehot_ip_1[15:0] :
    pre_offset_onehot_ip_0[15:0];

  assign pre_offset_onehot_if[15:0] = (ipctrl_bht_con_br_vld) ? pre_offset_onehot_if_1[15:0] :
    pre_offset_onehot_if_0[15:0];

  always @(*) begin : p_pre_offset_onehot_ip_0_comb
    case (pre_offset_ip_0[3:0])
      4'b0000: pre_offset_onehot_ip_0[15:0] = 16'b0000_0000_0000_0001;
      4'b0001: pre_offset_onehot_ip_0[15:0] = 16'b0000_0000_0000_0010;
      4'b0010: pre_offset_onehot_ip_0[15:0] = 16'b0000_0000_0000_0100;
      4'b0011: pre_offset_onehot_ip_0[15:0] = 16'b0000_0000_0000_1000;
      4'b0100: pre_offset_onehot_ip_0[15:0] = 16'b0000_0000_0001_0000;
      4'b0101: pre_offset_onehot_ip_0[15:0] = 16'b0000_0000_0010_0000;
      4'b0110: pre_offset_onehot_ip_0[15:0] = 16'b0000_0000_0100_0000;
      4'b0111: pre_offset_onehot_ip_0[15:0] = 16'b0000_0000_1000_0000;
      4'b1000: pre_offset_onehot_ip_0[15:0] = 16'b0000_0001_0000_0000;
      4'b1001: pre_offset_onehot_ip_0[15:0] = 16'b0000_0010_0000_0000;
      4'b1010: pre_offset_onehot_ip_0[15:0] = 16'b0000_0100_0000_0000;
      4'b1011: pre_offset_onehot_ip_0[15:0] = 16'b0000_1000_0000_0000;
      4'b1100: pre_offset_onehot_ip_0[15:0] = 16'b0001_0000_0000_0000;
      4'b1101: pre_offset_onehot_ip_0[15:0] = 16'b0010_0000_0000_0000;
      4'b1110: pre_offset_onehot_ip_0[15:0] = 16'b0100_0000_0000_0000;
      4'b1111: pre_offset_onehot_ip_0[15:0] = 16'b1000_0000_0000_0000;
      default: pre_offset_onehot_ip_0[15:0] = {16{1'bx}};
    endcase
  end

  always @(*) begin : p_pre_offset_onehot_ip_1_comb
    case (pre_offset_ip_1[3:0])
      4'b0000: pre_offset_onehot_ip_1[15:0] = 16'b0000_0000_0000_0001;
      4'b0001: pre_offset_onehot_ip_1[15:0] = 16'b0000_0000_0000_0010;
      4'b0010: pre_offset_onehot_ip_1[15:0] = 16'b0000_0000_0000_0100;
      4'b0011: pre_offset_onehot_ip_1[15:0] = 16'b0000_0000_0000_1000;
      4'b0100: pre_offset_onehot_ip_1[15:0] = 16'b0000_0000_0001_0000;
      4'b0101: pre_offset_onehot_ip_1[15:0] = 16'b0000_0000_0010_0000;
      4'b0110: pre_offset_onehot_ip_1[15:0] = 16'b0000_0000_0100_0000;
      4'b0111: pre_offset_onehot_ip_1[15:0] = 16'b0000_0000_1000_0000;
      4'b1000: pre_offset_onehot_ip_1[15:0] = 16'b0000_0001_0000_0000;
      4'b1001: pre_offset_onehot_ip_1[15:0] = 16'b0000_0010_0000_0000;
      4'b1010: pre_offset_onehot_ip_1[15:0] = 16'b0000_0100_0000_0000;
      4'b1011: pre_offset_onehot_ip_1[15:0] = 16'b0000_1000_0000_0000;
      4'b1100: pre_offset_onehot_ip_1[15:0] = 16'b0001_0000_0000_0000;
      4'b1101: pre_offset_onehot_ip_1[15:0] = 16'b0010_0000_0000_0000;
      4'b1110: pre_offset_onehot_ip_1[15:0] = 16'b0100_0000_0000_0000;
      4'b1111: pre_offset_onehot_ip_1[15:0] = 16'b1000_0000_0000_0000;
      default: pre_offset_onehot_ip_1[15:0] = {16{1'bx}};
    endcase
  end

  always @(*) begin : p_pre_offset_onehot_if_0_comb
    case (pre_offset_if_0[3:0])
      4'b0000: pre_offset_onehot_if_0[15:0] = 16'b0000_0000_0000_0001;
      4'b0001: pre_offset_onehot_if_0[15:0] = 16'b0000_0000_0000_0010;
      4'b0010: pre_offset_onehot_if_0[15:0] = 16'b0000_0000_0000_0100;
      4'b0011: pre_offset_onehot_if_0[15:0] = 16'b0000_0000_0000_1000;
      4'b0100: pre_offset_onehot_if_0[15:0] = 16'b0000_0000_0001_0000;
      4'b0101: pre_offset_onehot_if_0[15:0] = 16'b0000_0000_0010_0000;
      4'b0110: pre_offset_onehot_if_0[15:0] = 16'b0000_0000_0100_0000;
      4'b0111: pre_offset_onehot_if_0[15:0] = 16'b0000_0000_1000_0000;
      4'b1000: pre_offset_onehot_if_0[15:0] = 16'b0000_0001_0000_0000;
      4'b1001: pre_offset_onehot_if_0[15:0] = 16'b0000_0010_0000_0000;
      4'b1010: pre_offset_onehot_if_0[15:0] = 16'b0000_0100_0000_0000;
      4'b1011: pre_offset_onehot_if_0[15:0] = 16'b0000_1000_0000_0000;
      4'b1100: pre_offset_onehot_if_0[15:0] = 16'b0001_0000_0000_0000;
      4'b1101: pre_offset_onehot_if_0[15:0] = 16'b0010_0000_0000_0000;
      4'b1110: pre_offset_onehot_if_0[15:0] = 16'b0100_0000_0000_0000;
      4'b1111: pre_offset_onehot_if_0[15:0] = 16'b1000_0000_0000_0000;
      default: pre_offset_onehot_if_0[15:0] = {16{1'bx}};
    endcase
  end

  always @(*) begin : p_pre_offset_onehot_if_1_comb
    case (pre_offset_if_1[3:0])
      4'b0000: pre_offset_onehot_if_1[15:0] = 16'b0000_0000_0000_0001;
      4'b0001: pre_offset_onehot_if_1[15:0] = 16'b0000_0000_0000_0010;
      4'b0010: pre_offset_onehot_if_1[15:0] = 16'b0000_0000_0000_0100;
      4'b0011: pre_offset_onehot_if_1[15:0] = 16'b0000_0000_0000_1000;
      4'b0100: pre_offset_onehot_if_1[15:0] = 16'b0000_0000_0001_0000;
      4'b0101: pre_offset_onehot_if_1[15:0] = 16'b0000_0000_0010_0000;
      4'b0110: pre_offset_onehot_if_1[15:0] = 16'b0000_0000_0100_0000;
      4'b0111: pre_offset_onehot_if_1[15:0] = 16'b0000_0000_1000_0000;
      4'b1000: pre_offset_onehot_if_1[15:0] = 16'b0000_0001_0000_0000;
      4'b1001: pre_offset_onehot_if_1[15:0] = 16'b0000_0010_0000_0000;
      4'b1010: pre_offset_onehot_if_1[15:0] = 16'b0000_0100_0000_0000;
      4'b1011: pre_offset_onehot_if_1[15:0] = 16'b0000_1000_0000_0000;
      4'b1100: pre_offset_onehot_if_1[15:0] = 16'b0001_0000_0000_0000;
      4'b1101: pre_offset_onehot_if_1[15:0] = 16'b0010_0000_0000_0000;
      4'b1110: pre_offset_onehot_if_1[15:0] = 16'b0100_0000_0000_0000;
      4'b1111: pre_offset_onehot_if_1[15:0] = 16'b1000_0000_0000_0000;
      default: pre_offset_onehot_if_1[15:0] = {16{1'bx}};
    endcase
  end

  always @(posedge bht_pipe_clk or negedge cpurst_b) begin : p_bht_ipdp_pre_offset_onehot
    if (!cpurst_b) begin
      bht_ipdp_pre_offset_onehot_q[15:0] <= 16'b1;
    end else if (bht_inv_on_q) begin
      bht_ipdp_pre_offset_onehot_q[15:0] <= 16'b1;
    end else if (ifctrl_bht_pipedown && cp0_ifu_bht_en)  //BHT not on, hold old result
      begin
      bht_ipdp_pre_offset_onehot_q[15:0] <= pre_offset_onehot[15:0];
    end else begin
      bht_ipdp_pre_offset_onehot_q[15:0] <= bht_ipdp_pre_offset_onehot_q[15:0];
    end
  end

  //-------------------Vghr pipe tp IP------------------------
  always @(*) begin : p_vghr_value_comb
    if (rtu_ifu_flush && cp0_ifu_bht_en) begin
      vghr_value[21:0] = committed_recover_ghr[21:0];
    end else if (local_recover_vld && !ghr_updt_vld) begin
      vghr_value[21:0] = local_recover_ghr;
    end else if (ghr_updt_vld && iu_ifu_bht_check_vld) begin
      vghr_value[21:0] = {bju_ghr[20:0], iu_ifu_bht_condbr_taken};
    end else if (ghr_updt_vld && !iu_ifu_bht_check_vld) begin
      vghr_value[21:0] = bju_ghr[21:0];
    end else if (vghr_lbuf_updt_vld) begin
      vghr_value[21:0] = {vghr_q[20:0], lbuf_bht_con_br_taken};
    end else if (vghr_ip_updt_vld && !lbuf_bht_active_state) begin
      vghr_value[21:0] = {vghr_q[20:0], ipctrl_bht_con_br_taken};
    end else begin
      vghr_value[21:0] = vghr_q[21:0];
    end
  end

  always @(posedge bht_pipe_clk or negedge cpurst_b) begin : p_bht_ipdp_vghr
    if (!cpurst_b) begin
      bht_ipdp_vghr_q[21:0] <= 22'b0;
    end else if (bht_inv_on_q) begin
      bht_ipdp_vghr_q[21:0] <= 22'b0;
    end else if (ifctrl_bht_pipedown && cp0_ifu_bht_en) begin
      bht_ipdp_vghr_q[21:0] <= vghr_value[21:0];
    end else begin
      bht_ipdp_vghr_q[21:0] <= bht_ipdp_vghr_q[21:0];
    end
  end

  //-------------------Sel Array Result-----------------------
  always @(posedge bht_pipe_clk or negedge cpurst_b) begin : p_bht_ipdp_sel_array_result
    if (!cpurst_b) begin
      bht_ipdp_sel_array_result_q[1:0] <= 2'b0;
    end else if (bht_inv_on_q) begin
      bht_ipdp_sel_array_result_q[1:0] <= 2'b0;
    end else if (ifctrl_bht_pipedown && cp0_ifu_bht_en) begin
      bht_ipdp_sel_array_result_q[1:0] <= sel_array_val[1:0];
    end else begin
      bht_ipdp_sel_array_result_q[1:0] <= bht_ipdp_sel_array_result_q[1:0];
    end
  end

  //==========================================================
  //                 Some Control of BHT
  //==========================================================
  rv32_ifu_clk_cell u_bht_flop_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (bht_flop_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (bht_flop_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign bht_flop_clk_en = bht_inv_on_q || bht_inv_on_reg_ff_q || bju_mispred ||
    after_bju_mispred_q || rtu_ifu_flush || local_recover_vld || after_rtu_ifu_flush_q;

  //-----------------after_inv_reg----------------------------
  always @(posedge bht_flop_clk or negedge cpurst_b) begin : p_bht_inv_on_reg_ff
    if (!cpurst_b) begin
      bht_inv_on_reg_ff_q <= 1'b0;
    end else begin
      bht_inv_on_reg_ff_q <= bht_inv_on_q;
    end
  end

  assign after_inv_reg = !bht_inv_on_q && bht_inv_on_reg_ff_q;

  //-----------------after_bju_mispred------------------------
  always @(posedge bht_flop_clk or negedge cpurst_b) begin : p_after_bju_mispred
    if (!cpurst_b) begin
      after_bju_mispred_q <= 1'b0;
    end else if (bju_mispred) begin
      after_bju_mispred_q <= 1'b1;
    end else begin
      after_bju_mispred_q <= 1'b0;
    end
  end

  //-----------------after_rtu_ifu_flush----------------------
  always @(posedge bht_flop_clk or negedge cpurst_b) begin : p_after_rtu_ifu_flush
    if (!cpurst_b) begin
      after_rtu_ifu_flush_q <= 1'b0;
    end else if (rtu_ifu_flush || local_recover_vld) begin
      after_rtu_ifu_flush_q <= 1'b1;
    end else begin
      after_rtu_ifu_flush_q <= 1'b0;
    end
  end

  //==========================================================
  //               Invalidation of BHT
  //==========================================================
  rv32_ifu_clk_cell u_bht_inv_cnt_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (bht_inv_cnt_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (bht_inv_cnt_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign bht_inv_cnt_clk_en = bht_inv_on_q || ifctrl_bht_inv;

  always @(posedge bht_inv_cnt_clk or negedge cpurst_b) begin : p_bht_inval_cnt_pre
    if (!cpurst_b) begin
      bht_inval_cnt_pre_q[9:0] <= 10'b0;
    end else if (bht_inv_on_q) begin
      bht_inval_cnt_pre_q[9:0] <= bht_inval_cnt_pre_q[9:0] - 10'b1;
    end else if (ifctrl_bht_inv) begin
      bht_inval_cnt_pre_q[9:0] <= 10'b1111111111;
    end else begin
      bht_inval_cnt_pre_q[9:0] <= bht_inval_cnt_pre_q[9:0];
    end
  end

  assign bht_inval_cnt[9:0] = bht_inval_cnt_pre_q[9:0];

  always @(posedge bht_inv_cnt_clk or negedge cpurst_b) begin : p_bht_inv_on
    if (!cpurst_b) begin
      bht_inv_on_q <= 1'b0;
    end else if (!(|bht_inval_cnt[9:0]) && bht_inv_on_q) begin
      bht_inv_on_q <= 1'b0;
    end else if (ifctrl_bht_inv) begin
      bht_inv_on_q <= 1'b1;
    end
  end

  assign bht_ifctrl_inv_done = !bht_inv_on_q;

  assign bht_ifctrl_inv_on   = bht_inv_on_q;

  //==========================================================
  //                  BHT BYPASS WAY
  //==========================================================
  //IF BHT_INDEX Hit WR_BUF
  //TAKE BUF VALUE not TAKE Memory Value
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_bht_pred_array_index
    if (!cpurst_b) begin
      bht_pred_array_index_q[9:0] <= 10'b0;
    end else if (bht_pred_array_rd) begin
      bht_pred_array_index_q[9:0] <= bht_pred_array_index[9:0];
    end else begin
      bht_pred_array_index_q[9:0] <= bht_pred_array_index_q[9:0];
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_bht_sel_array_index
    if (!cpurst_b) begin
      bht_sel_array_index_q[9:0] <= 10'b0;
    end else if (bht_sel_array_rd && !ifctrl_bht_stall) begin
      bht_sel_array_index_q[9:0] <= pcgen_bht_pcindex[9:0];
    end else begin
      bht_sel_array_index_q[9:0] <= bht_sel_array_index_q[9:0];
    end
  end

  //Write Buffer Bypass Logic
  assign wr_buf_pre_hit_0 = (vghr_q[20:0] == entry0_data_q[30:10]);

  assign wr_buf_pre_hit_1 = (vghr_q[20:0] == entry1_data_q[30:10]);

  assign wr_buf_pre_hit_2 = (vghr_q[20:0] == entry2_data_q[30:10]);

  assign wr_buf_pre_hit_3 = (vghr_q[20:0] == entry3_data_q[30:10]);

  assign wr_buf_sel_hit_0 = (bht_sel_array_index_q[9:0] == entry0_data_q[9:0]);

  assign wr_buf_sel_hit_1 = (bht_sel_array_index_q[9:0] == entry1_data_q[9:0]);

  assign wr_buf_sel_hit_2 = (bht_sel_array_index_q[9:0] == entry2_data_q[9:0]);

  assign wr_buf_sel_hit_3 = (bht_sel_array_index_q[9:0] == entry3_data_q[9:0]);

  assign wr_buf_hit_0 = wr_buf_pre_hit_0 && wr_buf_sel_hit_0 && entry0_vld_q;

  assign wr_buf_hit_1 = wr_buf_pre_hit_1 && wr_buf_sel_hit_1 && entry1_vld_q;

  assign wr_buf_hit_2 = wr_buf_pre_hit_2 && wr_buf_sel_hit_2 && entry2_vld_q;

  assign wr_buf_hit_3 = wr_buf_pre_hit_3 && wr_buf_sel_hit_3 && entry3_vld_q;

  assign wr_buf_hit = (wr_buf_hit_0 || wr_buf_hit_1 || wr_buf_hit_2 || wr_buf_hit_3) && wr_buf_rd;

  assign wr_buf_rd = sel_rd_q && pre_rd_q;

  always @(*) begin : p_wr_buf_sel_array_result_comb
    if (wr_buf_hit_0) begin
      wr_buf_sel_array_result[1:0] = entry0_sel_updt_data[1:0];
    end else if (wr_buf_hit_1) begin
      wr_buf_sel_array_result[1:0] = entry1_sel_updt_data[1:0];
    end else if (wr_buf_hit_2) begin
      wr_buf_sel_array_result[1:0] = entry2_sel_updt_data[1:0];
    end else begin
      wr_buf_sel_array_result[1:0] = entry3_sel_updt_data[1:0];
    end
  end

  always @(*) begin : p_entry0_sel_updt_data_comb
    case ({
      entry0_data_q[34:33], entry0_data_q[35]
    })
      3'b001:  entry0_sel_updt_data[1:0] = 2'b01;
      3'b011:  entry0_sel_updt_data[1:0] = 2'b10;
      3'b010:  entry0_sel_updt_data[1:0] = 2'b00;
      3'b110:  entry0_sel_updt_data[1:0] = 2'b10;
      3'b101:  entry0_sel_updt_data[1:0] = 2'b11;
      3'b100:  entry0_sel_updt_data[1:0] = 2'b01;
      3'b111:  entry0_sel_updt_data[1:0] = 2'b11;
      3'b000:  entry0_sel_updt_data[1:0] = 2'b00;
      default: entry0_sel_updt_data[1:0] = 2'b00;
    endcase
  end

  always @(*) begin : p_entry1_sel_updt_data_comb
    case ({
      entry1_data_q[34:33], entry1_data_q[35]
    })
      3'b001:  entry1_sel_updt_data[1:0] = 2'b01;
      3'b011:  entry1_sel_updt_data[1:0] = 2'b10;
      3'b010:  entry1_sel_updt_data[1:0] = 2'b00;
      3'b110:  entry1_sel_updt_data[1:0] = 2'b10;
      3'b101:  entry1_sel_updt_data[1:0] = 2'b11;
      3'b100:  entry1_sel_updt_data[1:0] = 2'b01;
      3'b111:  entry1_sel_updt_data[1:0] = 2'b11;
      3'b000:  entry1_sel_updt_data[1:0] = 2'b00;
      default: entry1_sel_updt_data[1:0] = 2'b00;
    endcase
  end

  always @(*) begin : p_entry2_sel_updt_data_comb
    case ({
      entry2_data_q[34:33], entry2_data_q[35]
    })
      3'b001:  entry2_sel_updt_data[1:0] = 2'b01;
      3'b011:  entry2_sel_updt_data[1:0] = 2'b10;
      3'b010:  entry2_sel_updt_data[1:0] = 2'b00;
      3'b110:  entry2_sel_updt_data[1:0] = 2'b10;
      3'b101:  entry2_sel_updt_data[1:0] = 2'b11;
      3'b100:  entry2_sel_updt_data[1:0] = 2'b01;
      3'b111:  entry2_sel_updt_data[1:0] = 2'b11;
      3'b000:  entry2_sel_updt_data[1:0] = 2'b00;
      default: entry2_sel_updt_data[1:0] = 2'b00;
    endcase
  end

  always @(*) begin : p_entry3_sel_updt_data_comb
    case ({
      entry3_data_q[34:33], entry3_data_q[35]
    })
      3'b001:  entry3_sel_updt_data[1:0] = 2'b01;
      3'b011:  entry3_sel_updt_data[1:0] = 2'b10;
      3'b010:  entry3_sel_updt_data[1:0] = 2'b00;
      3'b110:  entry3_sel_updt_data[1:0] = 2'b10;
      3'b101:  entry3_sel_updt_data[1:0] = 2'b11;
      3'b100:  entry3_sel_updt_data[1:0] = 2'b01;
      3'b111:  entry3_sel_updt_data[1:0] = 2'b11;
      3'b000:  entry3_sel_updt_data[1:0] = 2'b00;
      default: entry3_sel_updt_data[1:0] = 2'b00;
    endcase
  end

  //==========================================================
  //                Interface to Ind BTB
  //==========================================================
  assign bht_ind_btb_rtu_ghr[7:0] = rtughr_q[7:0];

  assign bht_ind_btb_vghr[7:0]    = vghr_q[7:0];

  //==========================================================
  //                Interface to LBUF
  //==========================================================
  always @(posedge bht_pipe_clk or negedge cpurst_b) begin : p_lbuf_pre_taken
    if (!cpurst_b) begin
      lbuf_pre_taken_q[31:0] <= 32'b0;
    end else if (bht_inv_on_q) begin
      lbuf_pre_taken_q[31:0] <= 32'b0;
    end else if (cp0_ifu_bht_en && lbuf_bht_con_br_vld && lbuf_bht_active_state) begin
      lbuf_pre_taken_q[31:0] <= pre_array_pipe_taken_data[31:0];
    end else begin
      lbuf_pre_taken_q[31:0] <= lbuf_pre_taken_q[31:0];
    end
  end

  always @(posedge bht_pipe_clk or negedge cpurst_b) begin : p_lbuf_pre_ntaken
    if (!cpurst_b) begin
      lbuf_pre_ntaken_q[31:0] <= 32'b0;
    end else if (bht_inv_on_q) begin
      lbuf_pre_ntaken_q[31:0] <= 32'b0;
    end else if (cp0_ifu_bht_en && lbuf_bht_con_br_vld && lbuf_bht_active_state) begin
      lbuf_pre_ntaken_q[31:0] <= pre_array_pipe_ntaken_data[31:0];
    end else begin
      lbuf_pre_ntaken_q[31:0] <= lbuf_pre_ntaken_q[31:0];
    end
  end

  assign bht_lbuf_pre_taken_result[31:0]  = lbuf_pre_taken_q[31:0];

  assign bht_lbuf_pre_ntaken_result[31:0] = lbuf_pre_ntaken_q[31:0];

  assign bht_lbuf_vghr[21:0]              = vghr_q[21:0];

  //==========================================================
  //                  Infor from IU
  //==========================================================
  assign bju_mispred                      = iu_ifu_chgflw_vld;

  assign bju_pred_rst[1:0]                = {iu_ifu_bht_pred, iu_ifu_chk_idx[24]};

  assign bju_sel_rst[1:0]                 = iu_ifu_chk_idx[23:22];

  assign bju_ghr[21:0]                    = iu_ifu_chk_idx[21:0];

  //==========================================================
  //                 Interface to Memory
  //==========================================================
  rv32_ifu_bht_pre_array u_bht_pre_array (
    .bht_pre_array_clk_en(bht_pre_array_clk_en),
    .bht_pre_data_out    (bht_pre_data_out),
    .bht_pred_array_cen_b(bht_pred_array_cen_b),
    .bht_pred_array_din  (bht_pred_array_din),
    .bht_pred_array_gwen (bht_pred_array_gwen),
    .bht_pred_array_index(bht_pred_array_index),
    .bht_pred_bwen       (bht_pred_bwen),
    .cp0_ifu_icg_en      (cp0_ifu_icg_en),
    .cp0_yy_clk_en       (cp0_yy_clk_en),
    .forever_cpuclk      (forever_cpuclk),
    .pad_yy_icg_scan_en  (pad_yy_icg_scan_en)
  );

  rv32_ifu_bht_sel_array u_bht_sel_array (
    .bht_sel_array_cen_b (bht_sel_array_cen_b),
    .bht_sel_array_clk_en(bht_sel_array_clk_en),
    .bht_sel_array_din   (bht_sel_array_din),
    .bht_sel_array_gwen  (bht_sel_array_gwen),
    .bht_sel_array_index (bht_sel_array_index),
    .bht_sel_bwen        (bht_sel_bwen),
    .bht_sel_data_out    (bht_sel_data_out),
    .cp0_ifu_icg_en      (cp0_ifu_icg_en),
    .cp0_yy_clk_en       (cp0_yy_clk_en),
    .forever_cpuclk      (forever_cpuclk),
    .pad_yy_icg_scan_en  (pad_yy_icg_scan_en)
  );

  // Dropped training is a performance event; recovery/retirement remain independent.
  assign committed_recover_ghr = rtughr_updt_vld ? rtughr_nxt : rtughr_q;

  assign bht_train_drop        = bht_wr_buf_create_vld && buf_full && !bht_inv_on_q;

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_bht_train_drop_count

    if (!cpurst_b) begin
      bht_train_drop_count_q <= 32'b0;
    end else if (bht_inv_on_q) begin
      bht_train_drop_count_q <= 32'b0;
    end else if (bht_train_drop && !(&bht_train_drop_count_q)) begin
      bht_train_drop_count_q <= bht_train_drop_count_q + 32'd1;
    end
  end

  //------------------------------------------------------------------------------
  // Output assignments
  //------------------------------------------------------------------------------
  assign bht_train_drop_count          = bht_train_drop_count_q;
  assign bht_ipdp_pre_array_data_ntake = bht_ipdp_pre_array_data_ntake_q;
  assign bht_ipdp_pre_array_data_taken = bht_ipdp_pre_array_data_taken_q;
  assign bht_ipdp_pre_offset_onehot    = bht_ipdp_pre_offset_onehot_q;
  assign bht_ipdp_sel_array_result     = bht_ipdp_sel_array_result_q;
  assign bht_ipdp_vghr                 = bht_ipdp_vghr_q;
endmodule
