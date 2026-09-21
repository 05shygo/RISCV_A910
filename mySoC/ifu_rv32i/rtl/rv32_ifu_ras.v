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

// RV32I port, 2026-09-20: all PCs are byte addresses; +4 link supplied by caller; synchronous clear and old-top valid added.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_ras (

  // Predictor and pipeline interface
  output wire ras_top_valid,
  input  wire ras_clear,

  // Clock, reset and configuration
  input wire       cp0_ifu_icg_en,
  input wire       cp0_ifu_ras_en,
  input wire       cp0_yy_clk_en,
  input wire [1:0] cp0_yy_priv_mode,
  input wire       cpurst_b,
  input wire       forever_cpuclk,

  // Predictor and pipeline interface
  input wire        ibctrl_ras_inst_pcall,
  input wire        ibctrl_ras_pcall_vld,
  input wire        ibctrl_ras_pcall_vld_for_gateclk,
  input wire        ibctrl_ras_preturn_vld,
  input wire        ibctrl_ras_preturn_vld_for_gateclk,
  input wire [31:0] ibdp_ras_push_pc,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Retirement interface
  input wire        rtu_ifu_flush,
  input wire [31:0] rtu_ifu_retire0_inc_pc,
  input wire        rtu_ifu_retire0_mispred,
  input wire        rtu_ifu_retire0_pcall,
  input wire        rtu_ifu_retire0_preturn,

  // Predictor and pipeline interface
  output wire        ras_ipdp_data_vld,
  output wire [31:0] ras_ipdp_pc,
  output wire [31:0] ras_l0_btb_pc,
  output wire [31:0] ras_l0_btb_push_pc,
  output wire        ras_l0_btb_ras_push
);

  //------------------------------------------------------------------------------
  // Localparams
  //------------------------------------------------------------------------------

  //CK 860 RAS has 12 + 6 Entry
  //12 Top Entry maintained by IFU
  //6  RTU Entry maintained by RTU
  localparam PC_WIDTH = 32;

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  reg         ras_entry0_filled_q;
  reg  [31:0] ras_entry0_pc_q;
  reg  [ 1:0] ras_entry0_priv_mode_q;
  reg         ras_entry10_filled_q;
  reg  [31:0] ras_entry10_pc_q;
  reg  [ 1:0] ras_entry10_priv_mode_q;
  reg         ras_entry11_filled_q;
  reg  [31:0] ras_entry11_pc_q;
  reg  [ 1:0] ras_entry11_priv_mode_q;
  reg         ras_entry1_filled_q;
  reg  [31:0] ras_entry1_pc_q;
  reg  [ 1:0] ras_entry1_priv_mode_q;
  reg         ras_entry2_filled_q;
  reg  [31:0] ras_entry2_pc_q;
  reg  [ 1:0] ras_entry2_priv_mode_q;
  reg         ras_entry3_filled_q;
  reg  [31:0] ras_entry3_pc_q;
  reg  [ 1:0] ras_entry3_priv_mode_q;
  reg         ras_entry4_filled_q;
  reg  [31:0] ras_entry4_pc_q;
  reg  [ 1:0] ras_entry4_priv_mode_q;
  reg         ras_entry5_filled_q;
  reg  [31:0] ras_entry5_pc_q;
  reg  [ 1:0] ras_entry5_priv_mode_q;
  reg         ras_entry6_filled_q;
  reg  [31:0] ras_entry6_pc_q;
  reg  [ 1:0] ras_entry6_priv_mode_q;
  reg         ras_entry7_filled_q;
  reg  [31:0] ras_entry7_pc_q;
  reg  [ 1:0] ras_entry7_priv_mode_q;
  reg         ras_entry8_filled_q;
  reg  [31:0] ras_entry8_pc_q;
  reg  [ 1:0] ras_entry8_priv_mode_q;
  reg         ras_entry9_filled_q;
  reg  [31:0] ras_entry9_pc_q;
  reg  [ 1:0] ras_entry9_priv_mode_q;
  reg         ras_filled;
  reg  [31:0] ras_pc_out;
  reg  [ 1:0] ras_priv_mode;
  reg         rtu_entry0_filled_q;
  reg  [31:0] rtu_entry0_pc_q;
  reg  [ 1:0] rtu_entry0_priv_mode_q;
  reg         rtu_entry1_filled_q;
  reg  [31:0] rtu_entry1_pc_q;
  reg  [ 1:0] rtu_entry1_priv_mode_q;
  reg         rtu_entry2_filled_q;
  reg  [31:0] rtu_entry2_pc_q;
  reg  [ 1:0] rtu_entry2_priv_mode_q;
  reg         rtu_entry3_filled_q;
  reg  [31:0] rtu_entry3_pc_q;
  reg  [ 1:0] rtu_entry3_priv_mode_q;
  reg         rtu_entry4_filled_q;
  reg  [31:0] rtu_entry4_pc_q;
  reg  [ 1:0] rtu_entry4_priv_mode_q;
  reg         rtu_entry5_filled_q;
  reg  [31:0] rtu_entry5_pc_q;
  reg  [ 1:0] rtu_entry5_priv_mode_q;
  reg  [ 3:0] rtu_fifo_ptr_q;
  reg  [ 4:0] rtu_ptr_q;
  reg  [ 4:0] rtu_ptr_nxt;
  reg  [ 4:0] status_ptr_q;
  reg  [ 4:0] top_ptr_q;
  reg  [ 4:0] top_ptr_nxt;
  wire        entry0_push;
  wire        entry10_push;
  wire        entry11_push;
  wire        entry1_push;
  wire        entry2_push;
  wire        entry3_push;
  wire        entry4_push;
  wire        entry5_push;
  wire        entry6_push;
  wire        entry7_push;
  wire        entry8_push;
  wire        entry9_push;
  wire        ras_empty;
  wire        ras_entry0_upd_clk;
  wire        ras_entry0_upd_clk_en;
  wire        ras_entry10_upd_clk;
  wire        ras_entry10_upd_clk_en;
  wire        ras_entry11_upd_clk;
  wire        ras_entry11_upd_clk_en;
  wire        ras_entry1_upd_clk;
  wire        ras_entry1_upd_clk_en;
  wire        ras_entry2_upd_clk;
  wire        ras_entry2_upd_clk_en;
  wire        ras_entry3_upd_clk;
  wire        ras_entry3_upd_clk_en;
  wire        ras_entry4_upd_clk;
  wire        ras_entry4_upd_clk_en;
  wire        ras_entry5_upd_clk;
  wire        ras_entry5_upd_clk_en;
  wire        ras_entry6_upd_clk;
  wire        ras_entry6_upd_clk_en;
  wire        ras_entry7_upd_clk;
  wire        ras_entry7_upd_clk_en;
  wire        ras_entry8_upd_clk;
  wire        ras_entry8_upd_clk_en;
  wire        ras_entry9_upd_clk;
  wire        ras_entry9_upd_clk_en;
  wire        ras_full;
  wire        ras_pop;
  wire        ras_push;
  wire [31:0] ras_push_pc;
  wire        rtu_entry0_copy;
  wire [31:0] rtu_entry0_nxt;
  wire        rtu_entry0_push;
  wire        rtu_entry0_upd_clk;
  wire        rtu_entry0_upd_clk_en;
  wire        rtu_entry10_copy;
  wire        rtu_entry11_copy;
  wire        rtu_entry1_copy;
  wire [31:0] rtu_entry1_nxt;
  wire        rtu_entry1_push;
  wire        rtu_entry1_upd_clk;
  wire        rtu_entry1_upd_clk_en;
  wire        rtu_entry2_copy;
  wire [31:0] rtu_entry2_nxt;
  wire        rtu_entry2_push;
  wire        rtu_entry2_upd_clk;
  wire        rtu_entry2_upd_clk_en;
  wire        rtu_entry3_copy;
  wire [31:0] rtu_entry3_nxt;
  wire        rtu_entry3_push;
  wire        rtu_entry3_upd_clk;
  wire        rtu_entry3_upd_clk_en;
  wire        rtu_entry4_copy;
  wire [31:0] rtu_entry4_nxt;
  wire        rtu_entry4_push;
  wire        rtu_entry4_upd_clk;
  wire        rtu_entry4_upd_clk_en;
  wire        rtu_entry5_copy;
  wire [31:0] rtu_entry5_nxt;
  wire        rtu_entry5_push;
  wire        rtu_entry5_upd_clk;
  wire        rtu_entry5_upd_clk_en;
  wire        rtu_entry6_copy;
  wire        rtu_entry7_copy;
  wire        rtu_entry8_copy;
  wire        rtu_entry9_copy;
  wire [ 3:0] rtu_fifo_ptr_nxt;
  wire        rtu_fifo_ptr_upd_clk;
  wire        rtu_fifo_ptr_upd_clk_en;
  wire        rtu_ptr_upd_clk;
  wire        rtu_ptr_upd_clk_en;
  wire        rtu_ras_empty;
  wire [ 4:0] status_ptr_nxt;
  wire        status_ptr_upd_clk;
  wire        status_ptr_upd_clk_en;
  wire        top_entry_rtu_updt;
  wire        top_ptr_upd_clk;
  wire        top_ptr_upd_clk_en;
  wire [ 3:0] top_write_ptr;
  wire [ 3:0] rtu_write_ptr;
  reg  [ 2:0] rtu_available_q;
  reg  [ 2:0] rtu_available_nxt;

  //------------------------------------------------------------------------------
  // Functions
  //------------------------------------------------------------------------------

  function [4:0] ptr_back;
    input [4:0] ptr;
    input [2:0] count;
    integer       n;
    reg     [4:0] p;
    begin
      p = ptr;
      for (n = 0; n < 6; n = n + 1) begin
        if (n[2:0] < count) begin
          p = (p[3:0] == 0) ? {~p[4], 4'd11} : p - 5'd1;
        end
      end

      ptr_back = p;
    end
  endfunction

  function entry_in_backup;
    input [3:0] slot;
    input [4:0] ptr;
    input [2:0] count;
    integer       n;
    reg     [4:0] p;
    begin
      p               = ptr;
      entry_in_backup = 0;
      for (n = 0; n < 6; n = n + 1) begin
        p = (p[3:0] == 0) ? {~p[4], 4'd11} : p - 5'd1;
        if (n[2:0] < count && slot == p[3:0]) begin
          entry_in_backup = 1;
        end
      end
    end
  endfunction

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------
  assign top_write_ptr = ras_push && ras_pop && !ras_empty ?
    (top_ptr_q[3:0] == 0 ? 4'd11 : top_ptr_q[3:0] - 4'd1) : top_ptr_q[3:0];
  assign rtu_write_ptr = rtu_ifu_retire0_pcall && rtu_ifu_retire0_preturn && !rtu_ras_empty ?
    (rtu_ptr_q[3:0] == 0 ? 4'd11 : rtu_ptr_q[3:0] - 4'd1) : rtu_ptr_q[3:0];

  always @(*) begin : p_rtu_available_comb
    rtu_available_nxt = rtu_available_q;
    if (rtu_ifu_retire0_pcall && rtu_ifu_retire0_preturn && !rtu_ras_empty) begin
      if (rtu_available_q == 0) begin
        rtu_available_nxt = 1;
      end
    end else if (rtu_ifu_retire0_pcall) begin
      if (rtu_available_q < 6) begin
        rtu_available_nxt = rtu_available_q + 3'd1;
      end
    end else if (rtu_ifu_retire0_preturn && rtu_available_q != 0) begin
      rtu_available_nxt = rtu_available_q - 3'd1;
    end
  end

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_rtu_available

    if (!cpurst_b || ras_clear) begin
      rtu_available_q <= 0;
    end else if (cp0_ifu_ras_en) begin
      rtu_available_q <= rtu_available_nxt;
    end
  end

  //==========================================================
  //                    RTU RAS Pointer 
  //==========================================================
  //rtu ras pointer is maintained by rtu signal
  //1.when inst pcall retires, this pointer add by one
  //2.when inst preturn retires, this pointer sub by one
  //pointer MSB is used to judge RAS empty logic
  always @(*) begin : p_rtu_ptr_comb
    if (rtu_ifu_retire0_pcall && rtu_ifu_retire0_preturn && !rtu_ras_empty) begin
      rtu_ptr_nxt[4:0] = rtu_ptr_q[4:0];
    end else if (rtu_ifu_retire0_pcall) begin
      if (rtu_ptr_q[3:0] == 4'b1011) begin
        rtu_ptr_nxt[4:0] = {{~rtu_ptr_q[4]}, 4'b0000};
      end else begin
        rtu_ptr_nxt[4:0] = rtu_ptr_q[4:0] + 5'b1;
      end
    end else if (rtu_ifu_retire0_preturn && !rtu_ras_empty) begin
      if (rtu_ptr_q[3:0] == 4'b0000) begin
        rtu_ptr_nxt[4:0] = {{~rtu_ptr_q[4]}, 4'b1011};
      end else begin
        rtu_ptr_nxt[4:0] = rtu_ptr_q[4:0] - 5'b1;
      end
    end else begin
      rtu_ptr_nxt[4:0] = rtu_ptr_q[4:0];
    end
  end

  assign rtu_ras_empty = (rtu_available_q == 3'd0);

  always @(posedge rtu_ptr_upd_clk or negedge cpurst_b) begin : p_rtu_ptr
    if (!cpurst_b || ras_clear) begin
      rtu_ptr_q[4:0] <= 5'b0;
    end else if (cp0_ifu_ras_en) begin
      rtu_ptr_q[4:0] <= rtu_ptr_nxt[4:0];
    end else begin
      rtu_ptr_q[4:0] <= rtu_ptr_q[4:0];
    end
  end

  //Gate Clk
  rv32_ifu_clk_cell u_rtu_ptr_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_ptr_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_ptr_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_ptr_upd_clk_en = cp0_ifu_ras_en && (rtu_ifu_retire0_pcall || rtu_ifu_retire0_preturn);

  //==========================================================
  //                    TOP RAS Pointer 
  //==========================================================
  //top ras pointer is maintained by IFU
  //1.when rtu_ifu ras update, load the value of rtu_ptr
  //2.when inst jsr/bsr pre_decode, this pointer add by one
  //3.when inst jmp r15/rts/pop pre_decode, this pointer sub by one
  //pointer MSB is used to judge RAS empty logic
  always @(*) begin : p_top_ptr_comb
    if (top_entry_rtu_updt) begin
      top_ptr_nxt[4:0] = rtu_ptr_nxt[4:0];
    end else if (ras_push && ras_pop && !ras_empty) begin
      top_ptr_nxt[4:0] = top_ptr_q[4:0];
    end else if (ras_push) begin
      if (top_ptr_q[3:0] == 4'b1011) begin
        top_ptr_nxt[4:0] = {{~top_ptr_q[4]}, 4'b0000};
      end else begin
        top_ptr_nxt[4:0] = top_ptr_q[4:0] + 5'b1;
      end
    end else if (ras_pop && !ras_empty) begin
      if (top_ptr_q[3:0] == 4'b0000) begin
        top_ptr_nxt[4:0] = {{~top_ptr_q[4]}, 4'b1011};
      end else begin
        top_ptr_nxt[4:0] = top_ptr_q[4:0] - 5'b1;
      end
    end else begin
      top_ptr_nxt[4:0] = top_ptr_q[4:0];
    end
  end

  always @(posedge top_ptr_upd_clk or negedge cpurst_b) begin : p_top_ptr
    if (!cpurst_b || ras_clear) begin
      top_ptr_q[4:0] <= 5'b0;
    end else if (cp0_ifu_ras_en) begin
      top_ptr_q[4:0] <= top_ptr_nxt[4:0];
    end else begin
      top_ptr_q[4:0] <= top_ptr_q[4:0];
    end
  end

  //Gate Clk
  rv32_ifu_clk_cell u_top_ptr_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (top_ptr_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (top_ptr_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign top_ptr_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt || ibctrl_ras_pcall_vld_for_gateclk || ibctrl_ras_preturn_vld_for_gateclk);

  assign top_entry_rtu_updt = rtu_ifu_retire0_mispred || rtu_ifu_flush;

  //==========================================================
  //                   Status Pointer
  //==========================================================
  //the extra bit of pointer can be used to decide the full or empty state easily
  //here,a 5-bit status counter is used to solve return stack overflow problem
  //when return stack is full and pc is overwritten, this counter adds by one for
  //example, when 13 consecutive procedual call will lead a result that the latest
  //12 will return correctly, and return stack will be empty so the oldest one will
  //get pc from x1 value from iu
  assign status_ptr_nxt[4:0] = (status_ptr_q[3:0] == 4'b1011) ?
    {{~status_ptr_q[4]}, 4'b0000} : (status_ptr_q[4:0] + 1'b1);

  always @(posedge status_ptr_upd_clk or negedge cpurst_b) begin : p_status_ptr
    if (!cpurst_b || ras_clear) begin
      status_ptr_q[4:0] <= 5'b0;
    end else if (cp0_ifu_ras_en && top_entry_rtu_updt) begin
      status_ptr_q[4:0] <= ptr_back(rtu_ptr_nxt, rtu_available_nxt);
    end else if (cp0_ifu_ras_en && ras_full && ras_push && ras_pop) begin
      status_ptr_q[4:0] <= status_ptr_q[4:0];
    end else if (cp0_ifu_ras_en && ras_full && ras_push) begin
      status_ptr_q[4:0] <= status_ptr_nxt[4:0];
    end else if (cp0_ifu_ras_en && ras_full && ras_pop) begin
      status_ptr_q[4:0] <= status_ptr_q[4:0];
    end else begin
      status_ptr_q[4:0] <= status_ptr_q[4:0];
    end
  end

  assign ras_empty = (top_ptr_q[4:0] == status_ptr_q[4:0]);

  assign ras_full  = (top_ptr_q[4:0] == {~status_ptr_q[4], status_ptr_q[3:0]});

  //Gate Clk
  rv32_ifu_clk_cell u_status_ptr_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (status_ptr_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (status_ptr_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign status_ptr_upd_clk_en = cp0_ifu_ras_en && ras_full && ibctrl_ras_pcall_vld_for_gateclk ||
    cp0_ifu_ras_en && ras_full && ibctrl_ras_preturn_vld_for_gateclk ||
    cp0_ifu_ras_en && top_entry_rtu_updt;

  //==========================================================
  //                    RTU RAS FIFO
  //==========================================================
  //rtu ras fifo entry write in logic
  //rtu ras entry0
  always @(posedge rtu_entry0_upd_clk or negedge cpurst_b) begin : p_rtu_entry0_pc
    if (!cpurst_b || ras_clear) begin
      rtu_entry0_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry0_push) begin
      rtu_entry0_pc_q[PC_WIDTH-1:0] <= rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0];
    end else begin
      rtu_entry0_pc_q[PC_WIDTH-1:0] <= rtu_entry0_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge rtu_entry0_upd_clk or negedge cpurst_b) begin : p_rtu_entry0_filled
    if (!cpurst_b || ras_clear) begin
      rtu_entry0_filled_q <= 1'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry0_push) begin
      rtu_entry0_filled_q <= 1'b1;
    end else begin
      rtu_entry0_filled_q <= rtu_entry0_filled_q;
    end
  end

  always @(posedge rtu_entry0_upd_clk or negedge cpurst_b) begin : p_rtu_entry0_priv_mode
    if (!cpurst_b || ras_clear) begin
      rtu_entry0_priv_mode_q[1:0] <= 2'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry0_push) begin
      rtu_entry0_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      rtu_entry0_priv_mode_q[1:0] <= rtu_entry0_priv_mode_q[1:0];
    end
  end

  assign rtu_entry0_push = (rtu_write_ptr == 4'b0000) || (rtu_write_ptr == 4'b0110);

  //Gate Clk
  rv32_ifu_clk_cell u_rtu_entry0_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_entry0_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_entry0_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_entry0_upd_clk_en = cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry0_push;

  //rtu ras entry1
  always @(posedge rtu_entry1_upd_clk or negedge cpurst_b) begin : p_rtu_entry1_pc
    if (!cpurst_b || ras_clear) begin
      rtu_entry1_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry1_push) begin
      rtu_entry1_pc_q[PC_WIDTH-1:0] <= rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0];
    end else begin
      rtu_entry1_pc_q[PC_WIDTH-1:0] <= rtu_entry1_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge rtu_entry1_upd_clk or negedge cpurst_b) begin : p_rtu_entry1_filled
    if (!cpurst_b || ras_clear) begin
      rtu_entry1_filled_q <= 1'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry1_push) begin
      rtu_entry1_filled_q <= 1'b1;
    end else begin
      rtu_entry1_filled_q <= rtu_entry1_filled_q;
    end
  end

  always @(posedge rtu_entry1_upd_clk or negedge cpurst_b) begin : p_rtu_entry1_priv_mode
    if (!cpurst_b || ras_clear) begin
      rtu_entry1_priv_mode_q[1:0] <= 2'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry1_push) begin
      rtu_entry1_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      rtu_entry1_priv_mode_q[1:0] <= rtu_entry1_priv_mode_q[1:0];
    end
  end

  assign rtu_entry1_push = (rtu_write_ptr == 4'b0001) || (rtu_write_ptr == 4'b0111);

  //Gate Clk
  rv32_ifu_clk_cell u_rtu_entry1_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_entry1_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_entry1_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_entry1_upd_clk_en = cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry1_push;

  //rtu ras entry2
  always @(posedge rtu_entry2_upd_clk or negedge cpurst_b) begin : p_rtu_entry2_pc
    if (!cpurst_b || ras_clear) begin
      rtu_entry2_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry2_push) begin
      rtu_entry2_pc_q[PC_WIDTH-1:0] <= rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0];
    end else begin
      rtu_entry2_pc_q[PC_WIDTH-1:0] <= rtu_entry2_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge rtu_entry2_upd_clk or negedge cpurst_b) begin : p_rtu_entry2_filled
    if (!cpurst_b || ras_clear) begin
      rtu_entry2_filled_q <= 1'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry2_push) begin
      rtu_entry2_filled_q <= 1'b1;
    end else begin
      rtu_entry2_filled_q <= rtu_entry2_filled_q;
    end
  end

  always @(posedge rtu_entry2_upd_clk or negedge cpurst_b) begin : p_rtu_entry2_priv_mode
    if (!cpurst_b || ras_clear) begin
      rtu_entry2_priv_mode_q[1:0] <= 2'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry2_push) begin
      rtu_entry2_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      rtu_entry2_priv_mode_q[1:0] <= rtu_entry2_priv_mode_q[1:0];
    end
  end

  assign rtu_entry2_push = (rtu_write_ptr == 4'b0010) || (rtu_write_ptr == 4'b1000);

  //Gate Clk
  rv32_ifu_clk_cell u_rtu_entry2_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_entry2_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_entry2_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_entry2_upd_clk_en = cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry2_push;

  //rtu ras entry3
  always @(posedge rtu_entry3_upd_clk or negedge cpurst_b) begin : p_rtu_entry3_pc
    if (!cpurst_b || ras_clear) begin
      rtu_entry3_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry3_push) begin
      rtu_entry3_pc_q[PC_WIDTH-1:0] <= rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0];
    end else begin
      rtu_entry3_pc_q[PC_WIDTH-1:0] <= rtu_entry3_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge rtu_entry3_upd_clk or negedge cpurst_b) begin : p_rtu_entry3_filled
    if (!cpurst_b || ras_clear) begin
      rtu_entry3_filled_q <= 1'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry3_push) begin
      rtu_entry3_filled_q <= 1'b1;
    end else begin
      rtu_entry3_filled_q <= rtu_entry3_filled_q;
    end
  end

  always @(posedge rtu_entry3_upd_clk or negedge cpurst_b) begin : p_rtu_entry3_priv_mode
    if (!cpurst_b || ras_clear) begin
      rtu_entry3_priv_mode_q[1:0] <= 2'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry3_push) begin
      rtu_entry3_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      rtu_entry3_priv_mode_q[1:0] <= rtu_entry3_priv_mode_q[1:0];
    end
  end

  assign rtu_entry3_push = (rtu_write_ptr == 4'b0011) || (rtu_write_ptr == 4'b1001);

  //Gate Clk
  rv32_ifu_clk_cell u_rtu_entry3_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_entry3_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_entry3_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_entry3_upd_clk_en = cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry3_push;

  //rtu ras entry4
  always @(posedge rtu_entry4_upd_clk or negedge cpurst_b) begin : p_rtu_entry4_pc
    if (!cpurst_b || ras_clear) begin
      rtu_entry4_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry4_push) begin
      rtu_entry4_pc_q[PC_WIDTH-1:0] <= rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0];
    end else begin
      rtu_entry4_pc_q[PC_WIDTH-1:0] <= rtu_entry4_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge rtu_entry4_upd_clk or negedge cpurst_b) begin : p_rtu_entry4_filled
    if (!cpurst_b || ras_clear) begin
      rtu_entry4_filled_q <= 1'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry4_push) begin
      rtu_entry4_filled_q <= 1'b1;
    end else begin
      rtu_entry4_filled_q <= rtu_entry4_filled_q;
    end
  end

  always @(posedge rtu_entry4_upd_clk or negedge cpurst_b) begin : p_rtu_entry4_priv_mode
    if (!cpurst_b || ras_clear) begin
      rtu_entry4_priv_mode_q[1:0] <= 2'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry4_push) begin
      rtu_entry4_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      rtu_entry4_priv_mode_q[1:0] <= rtu_entry4_priv_mode_q[1:0];
    end
  end

  assign rtu_entry4_push = (rtu_write_ptr == 4'b0100) || (rtu_write_ptr == 4'b1010);

  //Gate Clk
  rv32_ifu_clk_cell u_rtu_entry4_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_entry4_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_entry4_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_entry4_upd_clk_en = cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry4_push;

  //rtu ras entry5
  always @(posedge rtu_entry5_upd_clk or negedge cpurst_b) begin : p_rtu_entry5_pc
    if (!cpurst_b || ras_clear) begin
      rtu_entry5_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry5_push) begin
      rtu_entry5_pc_q[PC_WIDTH-1:0] <= rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0];
    end else begin
      rtu_entry5_pc_q[PC_WIDTH-1:0] <= rtu_entry5_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge rtu_entry5_upd_clk or negedge cpurst_b) begin : p_rtu_entry5_filled
    if (!cpurst_b || ras_clear) begin
      rtu_entry5_filled_q <= 1'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry5_push) begin
      rtu_entry5_filled_q <= 1'b1;
    end else begin
      rtu_entry5_filled_q <= rtu_entry5_filled_q;
    end
  end

  always @(posedge rtu_entry5_upd_clk or negedge cpurst_b) begin : p_rtu_entry5_priv_mode
    if (!cpurst_b || ras_clear) begin
      rtu_entry5_priv_mode_q[1:0] <= 2'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry5_push) begin
      rtu_entry5_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      rtu_entry5_priv_mode_q[1:0] <= rtu_entry5_priv_mode_q[1:0];
    end
  end

  assign rtu_entry5_push = (rtu_write_ptr == 4'b0101) || (rtu_write_ptr == 4'b1011);

  //Gate Clk
  rv32_ifu_clk_cell u_rtu_entry5_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_entry5_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_entry5_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_entry5_upd_clk_en     = cp0_ifu_ras_en && rtu_ifu_retire0_pcall && rtu_entry5_push;

  //==========================================================
  //                    TOP RAS FIFO
  //==========================================================
  assign ras_push                  = ibctrl_ras_pcall_vld;

  assign ras_push_pc[PC_WIDTH-1:0] = ibdp_ras_push_pc[PC_WIDTH-1:0];

  //rtu_fifo_ptr[3:0]
  always @(posedge rtu_fifo_ptr_upd_clk or negedge cpurst_b) begin : p_rtu_fifo_ptr
    if (!cpurst_b || ras_clear) begin
      rtu_fifo_ptr_q[3:0] <= 4'b0;
    end else if (cp0_ifu_ras_en && rtu_ifu_retire0_pcall) begin
      rtu_fifo_ptr_q[3:0] <= rtu_fifo_ptr_nxt[3:0];
    end
  end

  assign rtu_fifo_ptr_nxt[3:0] = (rtu_ifu_retire0_pcall) ? rtu_write_ptr : rtu_fifo_ptr_q[3:0];

  //Gate Clk
  rv32_ifu_clk_cell u_rtu_fifo_ptr_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (rtu_fifo_ptr_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (rtu_fifo_ptr_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign rtu_fifo_ptr_upd_clk_en = cp0_ifu_ras_en && rtu_ifu_retire0_pcall;

  //top ras fifo entry write in logic
  //top ras entry0
  always @(posedge ras_entry0_upd_clk or negedge cpurst_b) begin : p_ras_entry0_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry0_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry0_copy) begin
        ras_entry0_pc_q[PC_WIDTH-1:0] <= rtu_entry0_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry0_pc_q[PC_WIDTH-1:0] <= ras_entry0_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry0_push) begin
        ras_entry0_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry0_pc_q[PC_WIDTH-1:0] <= ras_entry0_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry0_pc_q[PC_WIDTH-1:0] <= ras_entry0_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry0_upd_clk or negedge cpurst_b) begin : p_ras_entry0_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry0_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry0_filled_q <= rtu_entry0_copy;
    end else if (ras_push && entry0_push) begin
      ras_entry0_filled_q <= 1'b1;
    end else begin
      ras_entry0_filled_q <= ras_entry0_filled_q;
    end
  end

  always @(posedge ras_entry0_upd_clk or negedge cpurst_b) begin : p_ras_entry0_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry0_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry0_copy) begin
      ras_entry0_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry0_push) ? cp0_yy_priv_mode :
        rtu_entry0_priv_mode_q;
    end else if (ras_push && entry0_push) begin
      ras_entry0_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry0_priv_mode_q[1:0] <= ras_entry0_priv_mode_q[1:0];
    end
  end

  assign rtu_entry0_nxt[PC_WIDTH-1:0] = (rtu_ifu_retire0_pcall && rtu_entry0_push) ?
    rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0] : rtu_entry0_pc_q[PC_WIDTH-1:0];

  //only when entry0 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry0_copy = entry_in_backup(4'd0, rtu_ptr_nxt, rtu_available_nxt);

  assign entry0_push = (top_write_ptr == 4'b0000);

  //top ras entry1
  always @(posedge ras_entry1_upd_clk or negedge cpurst_b) begin : p_ras_entry1_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry1_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry1_copy) begin
        ras_entry1_pc_q[PC_WIDTH-1:0] <= rtu_entry1_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry1_pc_q[PC_WIDTH-1:0] <= ras_entry1_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry1_push) begin
        ras_entry1_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry1_pc_q[PC_WIDTH-1:0] <= ras_entry1_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry1_pc_q[PC_WIDTH-1:0] <= ras_entry1_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry1_upd_clk or negedge cpurst_b) begin : p_ras_entry1_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry1_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry1_filled_q <= rtu_entry1_copy;
    end else if (ras_push && entry1_push) begin
      ras_entry1_filled_q <= 1'b1;
    end else begin
      ras_entry1_filled_q <= ras_entry1_filled_q;
    end
  end

  always @(posedge ras_entry1_upd_clk or negedge cpurst_b) begin : p_ras_entry1_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry1_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry1_copy) begin
      ras_entry1_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry1_push) ? cp0_yy_priv_mode :
        rtu_entry1_priv_mode_q;
    end else if (ras_push && entry1_push) begin
      ras_entry1_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry1_priv_mode_q[1:0] <= ras_entry1_priv_mode_q[1:0];
    end
  end

  assign rtu_entry1_nxt[PC_WIDTH-1:0] = (rtu_ifu_retire0_pcall && rtu_entry1_push) ?
    rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0] : rtu_entry1_pc_q[PC_WIDTH-1:0];

  //only when entry1 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry1_copy = entry_in_backup(4'd1, rtu_ptr_nxt, rtu_available_nxt);

  assign entry1_push = (top_write_ptr == 4'b0001);

  //top ras entry2
  always @(posedge ras_entry2_upd_clk or negedge cpurst_b) begin : p_ras_entry2_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry2_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry2_copy) begin
        ras_entry2_pc_q[PC_WIDTH-1:0] <= rtu_entry2_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry2_pc_q[PC_WIDTH-1:0] <= ras_entry2_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry2_push) begin
        ras_entry2_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry2_pc_q[PC_WIDTH-1:0] <= ras_entry2_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry2_pc_q[PC_WIDTH-1:0] <= ras_entry2_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry2_upd_clk or negedge cpurst_b) begin : p_ras_entry2_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry2_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry2_filled_q <= rtu_entry2_copy;
    end else if (ras_push && entry2_push) begin
      ras_entry2_filled_q <= 1'b1;
    end else begin
      ras_entry2_filled_q <= ras_entry2_filled_q;
    end
  end

  always @(posedge ras_entry2_upd_clk or negedge cpurst_b) begin : p_ras_entry2_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry2_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry2_copy) begin
      ras_entry2_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry2_push) ? cp0_yy_priv_mode :
        rtu_entry2_priv_mode_q;
    end else if (ras_push && entry2_push) begin
      ras_entry2_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry2_priv_mode_q[1:0] <= ras_entry2_priv_mode_q[1:0];
    end
  end

  assign rtu_entry2_nxt[PC_WIDTH-1:0] = (rtu_ifu_retire0_pcall && rtu_entry2_push) ?
    rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0] : rtu_entry2_pc_q[PC_WIDTH-1:0];

  //only when entry2 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry2_copy = entry_in_backup(4'd2, rtu_ptr_nxt, rtu_available_nxt);

  assign entry2_push = (top_write_ptr == 4'b0010);

  //top ras entry3
  always @(posedge ras_entry3_upd_clk or negedge cpurst_b) begin : p_ras_entry3_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry3_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry3_copy) begin
        ras_entry3_pc_q[PC_WIDTH-1:0] <= rtu_entry3_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry3_pc_q[PC_WIDTH-1:0] <= ras_entry3_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry3_push) begin
        ras_entry3_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry3_pc_q[PC_WIDTH-1:0] <= ras_entry3_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry3_pc_q[PC_WIDTH-1:0] <= ras_entry3_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry3_upd_clk or negedge cpurst_b) begin : p_ras_entry3_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry3_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry3_filled_q <= rtu_entry3_copy;
    end else if (ras_push && entry3_push) begin
      ras_entry3_filled_q <= 1'b1;
    end else begin
      ras_entry3_filled_q <= ras_entry3_filled_q;
    end
  end

  always @(posedge ras_entry3_upd_clk or negedge cpurst_b) begin : p_ras_entry3_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry3_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry3_copy) begin
      ras_entry3_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry3_push) ? cp0_yy_priv_mode :
        rtu_entry3_priv_mode_q;
    end else if (ras_push && entry3_push) begin
      ras_entry3_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry3_priv_mode_q[1:0] <= ras_entry3_priv_mode_q[1:0];
    end
  end

  assign rtu_entry3_nxt[PC_WIDTH-1:0] = (rtu_ifu_retire0_pcall && rtu_entry3_push) ?
    rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0] : rtu_entry3_pc_q[PC_WIDTH-1:0];

  //only when entry3 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry3_copy = entry_in_backup(4'd3, rtu_ptr_nxt, rtu_available_nxt);

  assign entry3_push = (top_write_ptr == 4'b0011);

  //top ras entry4
  always @(posedge ras_entry4_upd_clk or negedge cpurst_b) begin : p_ras_entry4_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry4_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry4_copy) begin
        ras_entry4_pc_q[PC_WIDTH-1:0] <= rtu_entry4_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry4_pc_q[PC_WIDTH-1:0] <= ras_entry4_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry4_push) begin
        ras_entry4_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry4_pc_q[PC_WIDTH-1:0] <= ras_entry4_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry4_pc_q[PC_WIDTH-1:0] <= ras_entry4_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry4_upd_clk or negedge cpurst_b) begin : p_ras_entry4_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry4_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry4_filled_q <= rtu_entry4_copy;
    end else if (ras_push && entry4_push) begin
      ras_entry4_filled_q <= 1'b1;
    end else begin
      ras_entry4_filled_q <= ras_entry4_filled_q;
    end
  end

  always @(posedge ras_entry4_upd_clk or negedge cpurst_b) begin : p_ras_entry4_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry4_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry4_copy) begin
      ras_entry4_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry4_push) ? cp0_yy_priv_mode :
        rtu_entry4_priv_mode_q;
    end else if (ras_push && entry4_push) begin
      ras_entry4_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry4_priv_mode_q[1:0] <= ras_entry4_priv_mode_q[1:0];
    end
  end

  assign rtu_entry4_nxt[PC_WIDTH-1:0] = (rtu_ifu_retire0_pcall && rtu_entry4_push) ?
    rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0] : rtu_entry4_pc_q[PC_WIDTH-1:0];

  //only when entry4 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry4_copy = entry_in_backup(4'd4, rtu_ptr_nxt, rtu_available_nxt);

  assign entry4_push = (top_write_ptr == 4'b0100);

  //top ras entry5
  always @(posedge ras_entry5_upd_clk or negedge cpurst_b) begin : p_ras_entry5_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry5_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry5_copy) begin
        ras_entry5_pc_q[PC_WIDTH-1:0] <= rtu_entry5_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry5_pc_q[PC_WIDTH-1:0] <= ras_entry5_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry5_push) begin
        ras_entry5_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry5_pc_q[PC_WIDTH-1:0] <= ras_entry5_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry5_pc_q[PC_WIDTH-1:0] <= ras_entry5_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry5_upd_clk or negedge cpurst_b) begin : p_ras_entry5_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry5_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry5_filled_q <= rtu_entry5_copy;
    end else if (ras_push && entry5_push) begin
      ras_entry5_filled_q <= 1'b1;
    end else begin
      ras_entry5_filled_q <= ras_entry5_filled_q;
    end
  end

  always @(posedge ras_entry5_upd_clk or negedge cpurst_b) begin : p_ras_entry5_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry5_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry5_copy) begin
      ras_entry5_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry5_push) ? cp0_yy_priv_mode :
        rtu_entry5_priv_mode_q;
    end else if (ras_push && entry5_push) begin
      ras_entry5_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry5_priv_mode_q[1:0] <= ras_entry5_priv_mode_q[1:0];
    end
  end

  assign rtu_entry5_nxt[PC_WIDTH-1:0] = (rtu_ifu_retire0_pcall && rtu_entry5_push) ?
    rtu_ifu_retire0_inc_pc[PC_WIDTH-1:0] : rtu_entry5_pc_q[PC_WIDTH-1:0];

  //only when entry5 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry5_copy = entry_in_backup(4'd5, rtu_ptr_nxt, rtu_available_nxt);

  assign entry5_push = (top_write_ptr == 4'b0101);

  //top ras entry6
  always @(posedge ras_entry6_upd_clk or negedge cpurst_b) begin : p_ras_entry6_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry6_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry6_copy) begin
        ras_entry6_pc_q[PC_WIDTH-1:0] <= rtu_entry0_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry6_pc_q[PC_WIDTH-1:0] <= ras_entry6_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry6_push) begin
        ras_entry6_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry6_pc_q[PC_WIDTH-1:0] <= ras_entry6_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry6_pc_q[PC_WIDTH-1:0] <= ras_entry6_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry6_upd_clk or negedge cpurst_b) begin : p_ras_entry6_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry6_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry6_filled_q <= rtu_entry6_copy;
    end else if (ras_push && entry6_push) begin
      ras_entry6_filled_q <= 1'b1;
    end else begin
      ras_entry6_filled_q <= ras_entry6_filled_q;
    end
  end

  always @(posedge ras_entry6_upd_clk or negedge cpurst_b) begin : p_ras_entry6_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry6_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry6_copy) begin
      ras_entry6_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry0_push) ? cp0_yy_priv_mode :
        rtu_entry0_priv_mode_q;
    end else if (ras_push && entry6_push) begin
      ras_entry6_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry6_priv_mode_q[1:0] <= ras_entry6_priv_mode_q[1:0];
    end
  end

  //only when entry6 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry6_copy = entry_in_backup(4'd6, rtu_ptr_nxt, rtu_available_nxt);

  assign entry6_push     = (top_write_ptr == 4'b0110);

  //top ras entry7
  always @(posedge ras_entry7_upd_clk or negedge cpurst_b) begin : p_ras_entry7_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry7_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry7_copy) begin
        ras_entry7_pc_q[PC_WIDTH-1:0] <= rtu_entry1_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry7_pc_q[PC_WIDTH-1:0] <= ras_entry7_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry7_push) begin
        ras_entry7_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry7_pc_q[PC_WIDTH-1:0] <= ras_entry7_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry7_pc_q[PC_WIDTH-1:0] <= ras_entry7_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry7_upd_clk or negedge cpurst_b) begin : p_ras_entry7_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry7_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry7_filled_q <= rtu_entry7_copy;
    end else if (ras_push && entry7_push) begin
      ras_entry7_filled_q <= 1'b1;
    end else begin
      ras_entry7_filled_q <= ras_entry7_filled_q;
    end
  end

  always @(posedge ras_entry7_upd_clk or negedge cpurst_b) begin : p_ras_entry7_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry7_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry7_copy) begin
      ras_entry7_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry1_push) ? cp0_yy_priv_mode :
        rtu_entry1_priv_mode_q;
    end else if (ras_push && entry7_push) begin
      ras_entry7_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry7_priv_mode_q[1:0] <= ras_entry7_priv_mode_q[1:0];
    end
  end

  //only when entry7 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry7_copy = entry_in_backup(4'd7, rtu_ptr_nxt, rtu_available_nxt);

  assign entry7_push     = (top_write_ptr == 4'b0111);

  //top ras entry8
  always @(posedge ras_entry8_upd_clk or negedge cpurst_b) begin : p_ras_entry8_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry8_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry8_copy) begin
        ras_entry8_pc_q[PC_WIDTH-1:0] <= rtu_entry2_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry8_pc_q[PC_WIDTH-1:0] <= ras_entry8_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry8_push) begin
        ras_entry8_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry8_pc_q[PC_WIDTH-1:0] <= ras_entry8_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry8_pc_q[PC_WIDTH-1:0] <= ras_entry8_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry8_upd_clk or negedge cpurst_b) begin : p_ras_entry8_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry8_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry8_filled_q <= rtu_entry8_copy;
    end else if (ras_push && entry8_push) begin
      ras_entry8_filled_q <= 1'b1;
    end else begin
      ras_entry8_filled_q <= ras_entry8_filled_q;
    end
  end

  always @(posedge ras_entry8_upd_clk or negedge cpurst_b) begin : p_ras_entry8_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry8_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry8_copy) begin
      ras_entry8_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry2_push) ? cp0_yy_priv_mode :
        rtu_entry2_priv_mode_q;
    end else if (ras_push && entry8_push) begin
      ras_entry8_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry8_priv_mode_q[1:0] <= ras_entry8_priv_mode_q[1:0];
    end
  end

  //only when entry8 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry8_copy = entry_in_backup(4'd8, rtu_ptr_nxt, rtu_available_nxt);

  assign entry8_push     = (top_write_ptr == 4'b1000);

  //top ras entry9
  always @(posedge ras_entry9_upd_clk or negedge cpurst_b) begin : p_ras_entry9_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry9_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry9_copy) begin
        ras_entry9_pc_q[PC_WIDTH-1:0] <= rtu_entry3_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry9_pc_q[PC_WIDTH-1:0] <= ras_entry9_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry9_push) begin
        ras_entry9_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry9_pc_q[PC_WIDTH-1:0] <= ras_entry9_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry9_pc_q[PC_WIDTH-1:0] <= ras_entry9_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry9_upd_clk or negedge cpurst_b) begin : p_ras_entry9_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry9_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry9_filled_q <= rtu_entry9_copy;
    end else if (ras_push && entry9_push) begin
      ras_entry9_filled_q <= 1'b1;
    end else begin
      ras_entry9_filled_q <= ras_entry9_filled_q;
    end
  end

  always @(posedge ras_entry9_upd_clk or negedge cpurst_b) begin : p_ras_entry9_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry9_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry9_copy) begin
      ras_entry9_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry3_push) ? cp0_yy_priv_mode :
        rtu_entry3_priv_mode_q;
    end else if (ras_push && entry9_push) begin
      ras_entry9_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry9_priv_mode_q[1:0] <= ras_entry9_priv_mode_q[1:0];
    end
  end

  //only when entry9 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry9_copy = entry_in_backup(4'd9, rtu_ptr_nxt, rtu_available_nxt);

  assign entry9_push     = (top_write_ptr == 4'b1001);

  //top ras entry10
  always @(posedge ras_entry10_upd_clk or negedge cpurst_b) begin : p_ras_entry10_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry10_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry10_copy) begin
        ras_entry10_pc_q[PC_WIDTH-1:0] <= rtu_entry4_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry10_pc_q[PC_WIDTH-1:0] <= ras_entry10_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry10_push) begin
        ras_entry10_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry10_pc_q[PC_WIDTH-1:0] <= ras_entry10_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry10_pc_q[PC_WIDTH-1:0] <= ras_entry10_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry10_upd_clk or negedge cpurst_b) begin : p_ras_entry10_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry10_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry10_filled_q <= rtu_entry10_copy;
    end else if (ras_push && entry10_push) begin
      ras_entry10_filled_q <= 1'b1;
    end else begin
      ras_entry10_filled_q <= ras_entry10_filled_q;
    end
  end

  always @(posedge ras_entry10_upd_clk or negedge cpurst_b) begin : p_ras_entry10_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry10_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry10_copy) begin
      ras_entry10_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry4_push) ?
        cp0_yy_priv_mode : rtu_entry4_priv_mode_q;
    end else if (ras_push && entry10_push) begin
      ras_entry10_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry10_priv_mode_q[1:0] <= ras_entry10_priv_mode_q[1:0];
    end
  end

  //only when entry10 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry10_copy = entry_in_backup(4'd10, rtu_ptr_nxt, rtu_available_nxt);

  assign entry10_push     = (top_write_ptr == 4'b1010);

  //top ras entry11
  always @(posedge ras_entry11_upd_clk or negedge cpurst_b) begin : p_ras_entry11_pc
    if (!cpurst_b || ras_clear) begin
      ras_entry11_pc_q[PC_WIDTH-1:0] <= {PC_WIDTH{1'b0}};
    end else if (top_entry_rtu_updt) begin
      if (rtu_entry11_copy) begin
        ras_entry11_pc_q[PC_WIDTH-1:0] <= rtu_entry5_nxt[PC_WIDTH-1:0];
      end else begin
        ras_entry11_pc_q[PC_WIDTH-1:0] <= ras_entry11_pc_q[PC_WIDTH-1:0];
      end
    end else if (ras_push) begin
      if (entry11_push) begin
        ras_entry11_pc_q[PC_WIDTH-1:0] <= ras_push_pc[PC_WIDTH-1:0];
      end else begin
        ras_entry11_pc_q[PC_WIDTH-1:0] <= ras_entry11_pc_q[PC_WIDTH-1:0];
      end
    end else begin
      ras_entry11_pc_q[PC_WIDTH-1:0] <= ras_entry11_pc_q[PC_WIDTH-1:0];
    end
  end

  always @(posedge ras_entry11_upd_clk or negedge cpurst_b) begin : p_ras_entry11_filled
    if (!cpurst_b || ras_clear) begin
      ras_entry11_filled_q <= 1'b0;
    end else if (top_entry_rtu_updt) begin
      ras_entry11_filled_q <= rtu_entry11_copy;
    end else if (ras_push && entry11_push) begin
      ras_entry11_filled_q <= 1'b1;
    end else begin
      ras_entry11_filled_q <= ras_entry11_filled_q;
    end
  end

  always @(posedge ras_entry11_upd_clk or negedge cpurst_b) begin : p_ras_entry11_priv_mode
    if (!cpurst_b || ras_clear) begin
      ras_entry11_priv_mode_q[1:0] <= 2'b0;
    end else if (top_entry_rtu_updt && rtu_entry11_copy) begin
      ras_entry11_priv_mode_q[1:0] <= (rtu_ifu_retire0_pcall && rtu_entry5_push) ?
        cp0_yy_priv_mode : rtu_entry5_priv_mode_q;
    end else if (ras_push && entry11_push) begin
      ras_entry11_priv_mode_q[1:0] <= cp0_yy_priv_mode[1:0];
    end else begin
      ras_entry11_priv_mode_q[1:0] <= ras_entry11_priv_mode_q[1:0];
    end
  end

  //only when entry11 is the last 6 entry used
  //will it be updated by rtu entry copy value                             
  assign rtu_entry11_copy = entry_in_backup(4'd11, rtu_ptr_nxt, rtu_available_nxt);

  assign entry11_push     = (top_write_ptr == 4'b1011);

  //----------------ras entry update gate clk-----------------
  //Gate Clk - ras_entry0_upd_clk
  rv32_ifu_clk_cell u_ras_entry0_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry0_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry0_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry0_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry0_copy || ibctrl_ras_pcall_vld_for_gateclk && entry0_push);

  //Gate Clk - ras_entry1_upd_clk
  rv32_ifu_clk_cell u_ras_entry1_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry1_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry1_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry1_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry1_copy || ibctrl_ras_pcall_vld_for_gateclk && entry1_push);

  //Gate Clk - ras_entry2_upd_clk
  rv32_ifu_clk_cell u_ras_entry2_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry2_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry2_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry2_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry2_copy || ibctrl_ras_pcall_vld_for_gateclk && entry2_push);

  //Gate Clk - ras_entry3_upd_clk
  rv32_ifu_clk_cell u_ras_entry3_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry3_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry3_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry3_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry3_copy || ibctrl_ras_pcall_vld_for_gateclk && entry3_push);

  //Gate Clk - ras_entry4_upd_clk
  rv32_ifu_clk_cell u_ras_entry4_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry4_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry4_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry4_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry4_copy || ibctrl_ras_pcall_vld_for_gateclk && entry4_push);

  //Gate Clk - ras_entry5_upd_clk
  rv32_ifu_clk_cell u_ras_entry5_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry5_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry5_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry5_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry5_copy || ibctrl_ras_pcall_vld_for_gateclk && entry5_push);

  //Gate Clk - ras_entry6_upd_clk
  rv32_ifu_clk_cell u_ras_entry6_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry6_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry6_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry6_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry6_copy || ibctrl_ras_pcall_vld_for_gateclk && entry6_push);

  //Gate Clk - ras_entry7_upd_clk
  rv32_ifu_clk_cell u_ras_entry7_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry7_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry7_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry7_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry7_copy || ibctrl_ras_pcall_vld_for_gateclk && entry7_push);

  //Gate Clk - ras_entry8_upd_clk
  rv32_ifu_clk_cell u_ras_entry8_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry8_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry8_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry8_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry8_copy || ibctrl_ras_pcall_vld_for_gateclk && entry8_push);

  //Gate Clk - ras_entry9_upd_clk
  rv32_ifu_clk_cell u_ras_entry9_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry9_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry9_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry9_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry9_copy || ibctrl_ras_pcall_vld_for_gateclk && entry9_push);

  //Gate Clk - ras_entry10_upd_clk
  rv32_ifu_clk_cell u_ras_entry10_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry10_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry10_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry10_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry10_copy || ibctrl_ras_pcall_vld_for_gateclk && entry10_push);

  //Gate Clk - ras_entry11_upd_clk
  rv32_ifu_clk_cell u_ras_entry11_upd_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (ras_entry11_upd_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (ras_entry11_upd_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign ras_entry11_upd_clk_en = cp0_ifu_ras_en &&
    (top_entry_rtu_updt && rtu_entry11_copy || ibctrl_ras_pcall_vld_for_gateclk && entry11_push);

  //==========================================================
  //                    POP PC from RAS
  //==========================================================
  assign ras_pop = ibctrl_ras_preturn_vld;

  always @(*) begin : p_ras_pc_out_comb
    case (top_ptr_q[3:0])
      4'b0001: ras_pc_out[PC_WIDTH-1:0] = ras_entry0_pc_q[PC_WIDTH-1:0];
      4'b0010: ras_pc_out[PC_WIDTH-1:0] = ras_entry1_pc_q[PC_WIDTH-1:0];
      4'b0011: ras_pc_out[PC_WIDTH-1:0] = ras_entry2_pc_q[PC_WIDTH-1:0];
      4'b0100: ras_pc_out[PC_WIDTH-1:0] = ras_entry3_pc_q[PC_WIDTH-1:0];
      4'b0101: ras_pc_out[PC_WIDTH-1:0] = ras_entry4_pc_q[PC_WIDTH-1:0];
      4'b0110: ras_pc_out[PC_WIDTH-1:0] = ras_entry5_pc_q[PC_WIDTH-1:0];
      4'b0111: ras_pc_out[PC_WIDTH-1:0] = ras_entry6_pc_q[PC_WIDTH-1:0];
      4'b1000: ras_pc_out[PC_WIDTH-1:0] = ras_entry7_pc_q[PC_WIDTH-1:0];
      4'b1001: ras_pc_out[PC_WIDTH-1:0] = ras_entry8_pc_q[PC_WIDTH-1:0];
      4'b1010: ras_pc_out[PC_WIDTH-1:0] = ras_entry9_pc_q[PC_WIDTH-1:0];
      4'b1011: ras_pc_out[PC_WIDTH-1:0] = ras_entry10_pc_q[PC_WIDTH-1:0];
      4'b0000: ras_pc_out[PC_WIDTH-1:0] = ras_entry11_pc_q[PC_WIDTH-1:0];
      default: ras_pc_out[PC_WIDTH-1:0] = ras_entry0_pc_q[PC_WIDTH-1:0];
    endcase
  end

  always @(*) begin : p_ras_filled_comb
    case (top_ptr_q[3:0])
      4'b0001: ras_filled = ras_entry0_filled_q;
      4'b0010: ras_filled = ras_entry1_filled_q;
      4'b0011: ras_filled = ras_entry2_filled_q;
      4'b0100: ras_filled = ras_entry3_filled_q;
      4'b0101: ras_filled = ras_entry4_filled_q;
      4'b0110: ras_filled = ras_entry5_filled_q;
      4'b0111: ras_filled = ras_entry6_filled_q;
      4'b1000: ras_filled = ras_entry7_filled_q;
      4'b1001: ras_filled = ras_entry8_filled_q;
      4'b1010: ras_filled = ras_entry9_filled_q;
      4'b1011: ras_filled = ras_entry10_filled_q;
      4'b0000: ras_filled = ras_entry11_filled_q;
      default: ras_filled = ras_entry0_filled_q;
    endcase
  end

  always @(*) begin : p_ras_priv_mode_comb
    case (top_ptr_q[3:0])
      4'b0001: ras_priv_mode[1:0] = ras_entry0_priv_mode_q[1:0];
      4'b0010: ras_priv_mode[1:0] = ras_entry1_priv_mode_q[1:0];
      4'b0011: ras_priv_mode[1:0] = ras_entry2_priv_mode_q[1:0];
      4'b0100: ras_priv_mode[1:0] = ras_entry3_priv_mode_q[1:0];
      4'b0101: ras_priv_mode[1:0] = ras_entry4_priv_mode_q[1:0];
      4'b0110: ras_priv_mode[1:0] = ras_entry5_priv_mode_q[1:0];
      4'b0111: ras_priv_mode[1:0] = ras_entry6_priv_mode_q[1:0];
      4'b1000: ras_priv_mode[1:0] = ras_entry7_priv_mode_q[1:0];
      4'b1001: ras_priv_mode[1:0] = ras_entry8_priv_mode_q[1:0];
      4'b1010: ras_priv_mode[1:0] = ras_entry9_priv_mode_q[1:0];
      4'b1011: ras_priv_mode[1:0] = ras_entry10_priv_mode_q[1:0];
      4'b0000: ras_priv_mode[1:0] = ras_entry11_priv_mode_q[1:0];
      default: ras_priv_mode[1:0] = ras_entry0_priv_mode_q[1:0];
    endcase
  end

  //ibctrl_ras_pc[PC_WIDTH-1:0] used for created into pcfifo
  assign ras_ipdp_data_vld =
    (!ras_empty && ras_filled && (cp0_yy_priv_mode[1:0] == ras_priv_mode[1:0]) || ras_push) &&
    cp0_ifu_ras_en;

  assign ras_ipdp_pc[PC_WIDTH-1:0] = (ibctrl_ras_inst_pcall) ? ibdp_ras_push_pc[PC_WIDTH-1:0] :
    ras_pc_out[PC_WIDTH-1:0];

  assign ras_l0_btb_ras_push = ras_push && cp0_ifu_ras_en;

  assign ras_l0_btb_push_pc[PC_WIDTH-1:0] = ibdp_ras_push_pc[PC_WIDTH-1:0];

  assign ras_l0_btb_pc[PC_WIDTH-1:0] = ras_pc_out[PC_WIDTH-1:0];

  assign ras_top_valid = !ras_empty && ras_filled && cp0_ifu_ras_en &&
    (cp0_yy_priv_mode == ras_priv_mode);
endmodule
