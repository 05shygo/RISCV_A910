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

// RV32I port, 2026-09-20: 35-bit {valid,priv[1:0],byte_target[31:0]}; path remains target byte[11:4].

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_ind_btb (

  // Predictor and pipeline interface
  input  wire       cancel,
  output wire       ind_result_vld,
  input  wire [7:0] bht_ind_btb_rtu_ghr,
  input  wire [7:0] bht_ind_btb_vghr,

  // Clock, reset and configuration
  input wire       cp0_ifu_icg_en,
  input wire       cp0_ifu_ind_btb_en,
  input wire       cp0_yy_clk_en,
  input wire [1:0] cp0_yy_priv_mode,
  input wire       cpurst_b,
  input wire       forever_cpuclk,

  // Predictor and pipeline interface
  input wire       ibctrl_ind_btb_check_vld,
  input wire       ibctrl_ind_btb_fifo_stall,
  input wire [7:0] ibctrl_ind_btb_path,
  input wire       ifctrl_ind_btb_inv,
  input wire       ipctrl_ind_btb_con_br_vld,
  input wire       ipdp_ind_btb_jmp_detect,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Retirement interface
  input wire        rtu_ifu_flush,
  input wire [ 7:0] rtu_ifu_retire0_chk_idx,
  input wire        rtu_ifu_retire0_jmp,
  input wire        rtu_ifu_retire0_jmp_mispred,
  input wire        rtu_ifu_retire0_mispred,
  input wire [31:0] rtu_ifu_retire0_next_pc,
  input wire [ 7:0] rtu_ifu_retire1_chk_idx,
  input wire        rtu_ifu_retire1_jmp,
  input wire [ 7:0] rtu_ifu_retire2_chk_idx,
  input wire        rtu_ifu_retire2_jmp,

  // Predictor and pipeline interface
  output wire [34:0] ind_btb_ibctrl_dout,
  output wire [ 1:0] ind_btb_ibctrl_priv_mode,
  output wire        ind_btb_ifctrl_inv_done,
  output wire        ind_btb_ifctrl_inv_on
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  reg         after_path_reg_rtu_updt_q;
  reg  [34:0] ind_btb_dout_q;
  reg  [ 7:0] ind_btb_index;
  reg  [ 7:0] ind_btb_inv_cnt_q;
  reg         ind_btb_inv_on_q;
  reg         ind_btb_rd_q;
  reg  [ 7:0] path_reg_0_q;
  reg  [ 7:0] path_reg_1_q;
  reg  [ 7:0] path_reg_2_q;
  reg  [ 7:0] path_reg_3_q;
  reg  [ 1:0] priv_mode_q;
  reg  [ 7:0] rtu_path_reg_0_q;
  reg  [ 7:0] rtu_path_reg_0_nxt;
  reg  [ 7:0] rtu_path_reg_1_q;
  reg  [ 7:0] rtu_path_reg_1_nxt;
  reg  [ 7:0] rtu_path_reg_2_q;
  reg  [ 7:0] rtu_path_reg_2_nxt;
  reg  [ 7:0] rtu_path_reg_3_q;
  reg  [ 7:0] rtu_path_reg_3_nxt;
  wire        after_path_reg_rtu_updt_rd;
  wire        dout_update_clk;
  wire        dout_update_clk_en;
  wire        ib_stage_path_update_rd;
  wire        ind_btb_cen_b;
  wire        ind_btb_clk_en;
  wire [34:0] ind_btb_data_in;
  wire [34:0] ind_btb_dout;
  wire        ind_btb_inv_reg_upd_clk;
  wire        ind_btb_inv_reg_upd_clk_en;
  wire        ind_btb_invalidate;
  wire        ind_btb_rd;
  wire [ 7:0] ind_btb_rd_index;
  wire        ind_btb_wen_b;
  wire [ 7:0] ind_btb_wr_index;
  wire        ip_stage_vghr_update_rd;
  wire [ 7:0] path_reg_0_nxt;
  wire [ 7:0] path_reg_1_nxt;
  wire [ 7:0] path_reg_2_nxt;
  wire [ 7:0] path_reg_3_nxt;
  wire        path_reg_rtu_updt;
  wire        path_reg_rtu_updt_rd;
  wire        path_reg_updt_clk;
  wire        path_reg_updt_clk_en;
  wire [ 7:0] rtu_ghr;
  wire        rtu_ind_btb_update_vld;
  wire        rtu_jmp_check_vld;
  wire [31:0] rtu_jmp_target_pc;
  wire        rtu_path_reg_updt_clk;
  wire        rtu_path_reg_updt_clk_en;
  wire        updt_clk;
  wire        updt_clk_en;
  wire [ 7:0] vghr_reg;
  reg         ind_result_vld_q;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  //==========================================================
  //               Chip Enable to Ind_BTB
  //==========================================================
  //Ind_BTB is enabled when :
  //1.write enable
  //  a.Ind_BTB Invalid
  //  b.Ind_BTB Update by RTU
  //    When RTU ckeck any ind_btb inst, rtu_ind_btb_mispred
  //    It will update ind BTB memory data
  //2.read enable
  //  a.After RTU_Ind_BTB_recover --> Update PATH Infor
  //    1).RTU IFU Flush
  //    2).RTU retire any mispredict inst
  //  b.BJU Change Flow  --> Update VGHR
  //    BJU check any mispredict inst will update VGHR  
  //    Need not to read ind btb, beacuse from IU check Mispred
  //    inst, until RTU retire Mispred inst, if IFU fetch ind btb 
  //    inst, it will stall inst fetch 
  //  c.IB Stage check Ind_BTB Inst --> Update PATH Infor
  //  d.IP Stage check Con_br Inst --> Update VGHR 
  assign ind_btb_cen_b = !ind_btb_inv_on_q &&
    !(cp0_ifu_ind_btb_en &&
      (rtu_ind_btb_update_vld || path_reg_rtu_updt_rd || after_path_reg_rtu_updt_rd ||
       ib_stage_path_update_rd || ip_stage_vghr_update_rd));

  //Clk Enable Signal for Memory Gate Clk
  assign ind_btb_clk_en = ind_btb_inv_on_q ||
    cp0_ifu_ind_btb_en && (rtu_ind_btb_update_vld || ipdp_ind_btb_jmp_detect);

  //----------------------read signal-------------------------
  //Only When ip stage detect JMP inst will read ind_btb
  assign rtu_ind_btb_update_vld = rtu_ifu_retire0_jmp_mispred;

  assign ib_stage_path_update_rd = ipdp_ind_btb_jmp_detect || ibctrl_ind_btb_check_vld;

  assign ip_stage_vghr_update_rd = ipctrl_ind_btb_con_br_vld && ipdp_ind_btb_jmp_detect;

  assign path_reg_rtu_updt_rd = path_reg_rtu_updt && ipdp_ind_btb_jmp_detect;

  //-------------after_path_reg_rtu_updt_rd-------------------
  rv32_ifu_clk_cell u_updt_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (updt_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (updt_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign updt_clk_en = ind_btb_inv_on_q || path_reg_rtu_updt || after_path_reg_rtu_updt_q;

  //path_reg_rtu_updt means rtu retire one any mispredict inst
  //path_reg_rtu_updt will recover ind btb's PATH reg
  always @(posedge updt_clk or negedge cpurst_b) begin : p_after_path_reg_rtu_updt
    if (!cpurst_b) begin
      after_path_reg_rtu_updt_q <= 1'b0;
    end else if (ind_btb_inv_on_q) begin
      after_path_reg_rtu_updt_q <= 1'b0;
    end else if (path_reg_rtu_updt && rtu_ind_btb_update_vld)  //rtu_ind_br_mispred
      begin
      after_path_reg_rtu_updt_q <= 1'b1;
    end else begin
      after_path_reg_rtu_updt_q <= 1'b0;
    end
  end

  assign after_path_reg_rtu_updt_rd = after_path_reg_rtu_updt_q && ipdp_ind_btb_jmp_detect;

  assign path_reg_rtu_updt = rtu_ifu_retire0_mispred || rtu_ifu_flush;

  //==========================================================
  //               Write Enable to Ind_BTB
  //==========================================================
  //Ind_BTB write priority is higher than Ind_BTB read
  //1.Ind_BTB Invalid
  //2.Ind_BTB Update by RTU
  assign ind_btb_wen_b = !ind_btb_inv_on_q && !(cp0_ifu_ind_btb_en && rtu_ind_btb_update_vld);

  //==========================================================
  //               Read Enable to Ind_BTB
  //==========================================================
  assign ind_btb_rd = !cancel && cp0_ifu_ind_btb_en &&
    (path_reg_rtu_updt_rd || after_path_reg_rtu_updt_rd || ib_stage_path_update_rd ||
     ip_stage_vghr_update_rd) && !rtu_ind_btb_update_vld && !ibctrl_ind_btb_fifo_stall &&
    !ind_btb_inv_on_q;

  //==========================================================
  //                Write Data to Ind BTB
  //==========================================================
  //data_in[20:0] = {vld, target[31:0]}
  assign ind_btb_data_in[34:0] = (ind_btb_inv_on_q) ?
    35'b0 : {1'b1, cp0_yy_priv_mode[1:0], rtu_jmp_target_pc[31:0]};

  assign rtu_jmp_target_pc[31:0] = rtu_ifu_retire0_next_pc[31:0];

  //==========================================================
  //                   Index to Ind BTB
  //==========================================================
  always @(*) begin : p_ind_btb_index_comb
    if (ind_btb_inv_on_q) begin
      ind_btb_index[7:0] = ind_btb_inv_cnt_q[7:0];
    end else if (rtu_ind_btb_update_vld) begin
      ind_btb_index[7:0] = ind_btb_wr_index[7:0];
    end else  //if(ind_btb_read) 
    begin
      ind_btb_index[7:0] = ind_btb_rd_index[7:0];
    end
  end

  assign ind_btb_wr_index[7:0] = {
    {rtu_path_reg_3_q[7:6] ^ rtu_ghr[7:6]},
    {rtu_path_reg_2_q[5:4] ^ rtu_ghr[5:4]},
    {rtu_path_reg_1_q[3:2] ^ rtu_ghr[3:2]},
    {rtu_path_reg_0_q[1:0] ^ rtu_ghr[1:0]}
  };

  //For timing, use vghr_reg in stead of vghr_pre
  assign ind_btb_rd_index[7:0] = {
    {path_reg_3_nxt[7:6] ^ vghr_reg[7:6]},
    {path_reg_2_nxt[5:4] ^ vghr_reg[5:4]},
    {path_reg_1_nxt[3:2] ^ vghr_reg[3:2]},
    {path_reg_0_nxt[1:0] ^ vghr_reg[1:0]}
  };

  assign rtu_ghr[7:0] = bht_ind_btb_rtu_ghr[7:0];

  assign vghr_reg[7:0] = bht_ind_btb_vghr[7:0];

  //==========================================================
  //                   rtu_path_reg 
  //==========================================================
  //Gate Clk
  rv32_ifu_clk_cell u_rtu_path_reg_updt_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_path_reg_updt_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_path_reg_updt_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_path_reg_updt_clk_en = rtu_jmp_check_vld && cp0_ifu_ind_btb_en || ind_btb_inv_on_q;

  assign rtu_jmp_check_vld = rtu_ifu_retire0_jmp || rtu_ifu_retire1_jmp || rtu_ifu_retire2_jmp;

  //rtu_path_reg                             
  always @(posedge rtu_path_reg_updt_clk or negedge cpurst_b) begin : p_rtu_path_reg_3
    if (!cpurst_b) begin
      rtu_path_reg_3_q[7:0] <= 8'b0;
      rtu_path_reg_2_q[7:0] <= 8'b0;
      rtu_path_reg_1_q[7:0] <= 8'b0;
      rtu_path_reg_0_q[7:0] <= 8'b0;
    end else if (ind_btb_inv_on_q) begin
      rtu_path_reg_3_q[7:0] <= 8'b0;
      rtu_path_reg_2_q[7:0] <= 8'b0;
      rtu_path_reg_1_q[7:0] <= 8'b0;
      rtu_path_reg_0_q[7:0] <= 8'b0;
    end else if (rtu_jmp_check_vld && cp0_ifu_ind_btb_en) begin
      rtu_path_reg_3_q[7:0] <= rtu_path_reg_3_nxt[7:0];
      rtu_path_reg_2_q[7:0] <= rtu_path_reg_2_nxt[7:0];
      rtu_path_reg_1_q[7:0] <= rtu_path_reg_1_nxt[7:0];
      rtu_path_reg_0_q[7:0] <= rtu_path_reg_0_nxt[7:0];
    end else begin
      rtu_path_reg_3_q[7:0] <= rtu_path_reg_3_q[7:0];
      rtu_path_reg_2_q[7:0] <= rtu_path_reg_2_q[7:0];
      rtu_path_reg_1_q[7:0] <= rtu_path_reg_1_q[7:0];
      rtu_path_reg_0_q[7:0] <= rtu_path_reg_0_q[7:0];
    end
  end

  //rtu_path_reg_pre
  always @(*) begin : p_rtu_path_reg_3_comb
    case ({
      rtu_ifu_retire0_jmp, rtu_ifu_retire1_jmp, rtu_ifu_retire2_jmp
    })
      3'b000: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_3_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_path_reg_2_q[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_path_reg_1_q[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_path_reg_0_q[7:0];
      end
      3'b001: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_2_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_path_reg_1_q[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_path_reg_0_q[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_ifu_retire2_chk_idx[7:0];
      end
      3'b010: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_2_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_path_reg_1_q[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_path_reg_0_q[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_ifu_retire1_chk_idx[7:0];
      end
      3'b100: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_2_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_path_reg_1_q[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_path_reg_0_q[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_ifu_retire0_chk_idx[7:0];
      end
      3'b011: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_1_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_path_reg_0_q[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_ifu_retire1_chk_idx[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_ifu_retire2_chk_idx[7:0];
      end
      3'b101: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_1_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_path_reg_0_q[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_ifu_retire0_chk_idx[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_ifu_retire2_chk_idx[7:0];
      end
      3'b110: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_1_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_path_reg_0_q[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_ifu_retire0_chk_idx[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_ifu_retire1_chk_idx[7:0];
      end
      3'b111: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_0_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_ifu_retire0_chk_idx[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_ifu_retire1_chk_idx[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_ifu_retire2_chk_idx[7:0];
      end
      default: begin
        rtu_path_reg_3_nxt[7:0] = rtu_path_reg_3_q[7:0];
        rtu_path_reg_2_nxt[7:0] = rtu_path_reg_2_q[7:0];
        rtu_path_reg_1_nxt[7:0] = rtu_path_reg_1_q[7:0];
        rtu_path_reg_0_nxt[7:0] = rtu_path_reg_0_q[7:0];
      end
    endcase
  end

  //==========================================================
  //                       path_reg
  //==========================================================
  //Gate Clk
  rv32_ifu_clk_cell u_path_reg_updt_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (path_reg_updt_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (path_reg_updt_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign path_reg_updt_clk_en = (path_reg_rtu_updt || ibctrl_ind_btb_check_vld) &&
    cp0_ifu_ind_btb_en || ind_btb_inv_on_q;

  //path_reg
  always @(posedge path_reg_updt_clk or negedge cpurst_b) begin : p_path_reg_3
    if (!cpurst_b) begin
      path_reg_3_q[7:0] <= 8'b0;
      path_reg_2_q[7:0] <= 8'b0;
      path_reg_1_q[7:0] <= 8'b0;
      path_reg_0_q[7:0] <= 8'b0;
    end else if (ind_btb_inv_on_q) begin
      path_reg_3_q[7:0] <= 8'b0;
      path_reg_2_q[7:0] <= 8'b0;
      path_reg_1_q[7:0] <= 8'b0;
      path_reg_0_q[7:0] <= 8'b0;
    end else if ((path_reg_rtu_updt || ibctrl_ind_btb_check_vld) && cp0_ifu_ind_btb_en) begin
      path_reg_3_q[7:0] <= path_reg_3_nxt[7:0];
      path_reg_2_q[7:0] <= path_reg_2_nxt[7:0];
      path_reg_1_q[7:0] <= path_reg_1_nxt[7:0];
      path_reg_0_q[7:0] <= path_reg_0_nxt[7:0];
    end else begin
      path_reg_3_q[7:0] <= path_reg_3_q[7:0];
      path_reg_2_q[7:0] <= path_reg_2_q[7:0];
      path_reg_1_q[7:0] <= path_reg_1_q[7:0];
      path_reg_0_q[7:0] <= path_reg_0_q[7:0];
    end
  end

  //path_reg_pre
  assign path_reg_3_nxt[7:0] = (path_reg_rtu_updt) ?
    rtu_path_reg_3_nxt[7:0] : (ibctrl_ind_btb_check_vld) ? path_reg_2_q[7:0] : path_reg_3_q[7:0];

  assign path_reg_2_nxt[7:0] = (path_reg_rtu_updt) ?
    rtu_path_reg_2_nxt[7:0] : (ibctrl_ind_btb_check_vld) ? path_reg_1_q[7:0] : path_reg_2_q[7:0];

  assign path_reg_1_nxt[7:0] = (path_reg_rtu_updt) ?
    rtu_path_reg_1_nxt[7:0] : (ibctrl_ind_btb_check_vld) ? path_reg_0_q[7:0] : path_reg_1_q[7:0];

  assign path_reg_0_nxt[7:0] = (path_reg_rtu_updt) ? rtu_path_reg_0_nxt[7:0] :
    (ibctrl_ind_btb_check_vld) ? ibctrl_ind_btb_path[7:0] : path_reg_0_q[7:0];

  //==========================================================
  //                 Ind BTB Data out reg
  //==========================================================
  //In case of memory write affect the read data of Memory Dout
  //when read memory, flop one cycle, write data in dout into reg
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_ind_btb_rd
    if (!cpurst_b) begin
      ind_btb_rd_q <= 1'b0;
    end else if (ind_btb_inv_on_q || cancel) begin
      ind_btb_rd_q <= 1'b0;
    end else if (ind_btb_rd) begin
      ind_btb_rd_q <= 1'b1;
    end else begin
      ind_btb_rd_q <= 1'b0;
    end
  end

  //Gate clk
  rv32_ifu_clk_cell u_dout_update_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (dout_update_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (dout_update_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign dout_update_clk_en = ind_btb_rd_q;

  //Dout Reg Update
  always @(posedge dout_update_clk or negedge cpurst_b) begin : p_ind_btb_dout
    if (!cpurst_b) begin
      ind_btb_dout_q[34:0] <= 35'b0;
    end else if (ind_btb_rd_q) begin
      ind_btb_dout_q[34:0] <= ind_btb_dout[34:0];
    end  //Memory Dout
    else begin
      ind_btb_dout_q[34:0] <= ind_btb_dout_q[34:0];
    end
  end

  assign ind_btb_ibctrl_dout[34:0] = ind_btb_dout_q[34:0];

  //for timing consideration,when read ind btb,flop priv_mode
  always @(posedge dout_update_clk or negedge cpurst_b) begin : p_priv_mode
    if (!cpurst_b) begin
      priv_mode_q[1:0] <= 2'b11;
    end  //reset machine mode
    else if (ind_btb_rd_q) begin
      priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      priv_mode_q[1:0] <= priv_mode_q[1:0];
    end
  end

  assign ind_btb_ibctrl_priv_mode[1:0] = priv_mode_q[1:0];

  //==========================================================
  //              Invalidation of Ind BTB
  //==========================================================
  //Gate Clk
  rv32_ifu_clk_cell u_ind_btb_inv_reg_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ind_btb_inv_reg_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ind_btb_inv_reg_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ind_btb_inv_reg_upd_clk_en = ind_btb_inv_on_q || ind_btb_invalidate;

  //Invalidation Index
  always @(posedge ind_btb_inv_reg_upd_clk or negedge cpurst_b) begin : p_ind_btb_inv_cnt
    if (!cpurst_b) begin
      ind_btb_inv_cnt_q[7:0] <= 8'b0;
    end else if (ind_btb_inv_on_q) begin
      ind_btb_inv_cnt_q[7:0] <= ind_btb_inv_cnt_q[7:0] - 8'b1;
    end else if (ind_btb_invalidate) begin
      ind_btb_inv_cnt_q[7:0] <= 8'b11111111;
    end else begin
      ind_btb_inv_cnt_q[7:0] <= ind_btb_inv_cnt_q[7:0];
    end
  end

  assign ind_btb_invalidate = ifctrl_ind_btb_inv;

  //==========================================================
  //             Invalidating Status Register
  //==========================================================
  always @(posedge ind_btb_inv_reg_upd_clk or negedge cpurst_b) begin : p_ind_btb_inv_on
    if (!cpurst_b) begin
      ind_btb_inv_on_q <= 1'b0;
    end else if (!(|ind_btb_inv_cnt_q[7:0]) && ind_btb_inv_on_q) begin
      ind_btb_inv_on_q <= 1'b0;
    end else if (ind_btb_invalidate) begin
      ind_btb_inv_on_q <= 1'b1;
    end else begin
      ind_btb_inv_on_q <= ind_btb_inv_on_q;
    end
  end

  //==========================================================
  //              Invalidating Finish Signal
  //==========================================================
  assign ind_btb_ifctrl_inv_done = !ind_btb_inv_on_q;

  assign ind_btb_ifctrl_inv_on   = ind_btb_inv_on_q;

  //==========================================================
  //              Ind BTB Memory Instance
  //==========================================================
  rv32_ifu_ind_btb_array u_ind_btb_array (
    .cp0_ifu_icg_en    (cp0_ifu_icg_en),
    .cp0_yy_clk_en     (cp0_yy_clk_en),
    .forever_cpuclk    (forever_cpuclk),
    .ind_btb_cen_b     (ind_btb_cen_b),
    .ind_btb_clk_en    (ind_btb_clk_en),
    .ind_btb_data_in   (ind_btb_data_in),
    .ind_btb_dout      (ind_btb_dout),
    .ind_btb_index     (ind_btb_index),
    .ind_btb_wen_b     (ind_btb_wen_b),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  // Two edges: synchronous SRAM read, then held output register.
  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_ind_result_vld

    if (!cpurst_b) begin
      ind_result_vld_q <= 1'b0;
    end else if (cancel || ind_btb_inv_on_q || ifctrl_ind_btb_inv || path_reg_rtu_updt ||
                 rtu_ind_btb_update_vld) begin
      ind_result_vld_q <= 1'b0;
    end else begin
      ind_result_vld_q <= ind_btb_rd_q;
    end
  end

  //------------------------------------------------------------------------------
  // Output assignments
  //------------------------------------------------------------------------------
  assign ind_result_vld = ind_result_vld_q;
endmodule
