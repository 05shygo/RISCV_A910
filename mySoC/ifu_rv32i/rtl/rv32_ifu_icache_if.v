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

// RV32I/no-MMU derivative: 默认 64 KiB / two ways / 64 B lines / 512 sets,
// 由模块参数 IC_BYTES/IC_LINE 决定; 索引 = {set, beat, word} 左对齐,
// set = INDEX_WIDTH-1 : LINE_BITS, word 恒 4 bit。
// Tag row = {FIFO, valid1, tag1[TAG_BITS-1:0], valid0, tag0[TAG_BITS-1:0]}.
// Core request strobes MUST be mutually exclusive; use rv32_ifu_icache_top.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
// [ICACHE 参数化] 容量/行大小可配; 两个 define 都不给时 = 原 64 KiB/64 B 几何,
// 与参数默认值一致 ⇒ 不传参的基线逐位不变。
`ifdef ICACHE_BYTES
  `define IC_BYTES_VAL `ICACHE_BYTES
`else
  `define IC_BYTES_VAL 65536
`endif
`ifdef ICACHE_LINE_BYTES
  `define IC_LINE_VAL `ICACHE_LINE_BYTES
`else
  `define IC_LINE_VAL 64
`endif

module rv32_ifu_icache_if #(
  parameter IC_BYTES  = `IC_BYTES_VAL,        // 总容量(字节), 2 路
  parameter IC_LINE   = `IC_LINE_VAL,         // 行大小(字节)
  parameter IC_SETS   = IC_BYTES/(2*IC_LINE),
  parameter SET_BITS  = $clog2(IC_SETS),
  parameter LINE_BITS = $clog2(IC_LINE),
  parameter TAG_BITS  = 32 - SET_BITS - LINE_BITS,
  parameter TAG_WIDTH = 1 + TAG_BITS,
  parameter INDEX_WIDTH = SET_BITS + LINE_BITS,
  parameter BEATS     = IC_LINE/16
) (

  // Cache array and pipeline interface
  input wire l1_refill_icache_if_install,

  // Clock, reset and configuration
  input wire cp0_ifu_icache_en,
  input wire cp0_ifu_icg_en,
  input wire cp0_yy_clk_en,
  input wire cpurst_b,
  input wire forever_cpuclk,

  // Cache array and pipeline interface
  input wire         hpcp_ifu_cnt_en,
  input wire [ 31:0] ifctrl_icache_if_index,
  input wire         ifctrl_icache_if_inv_fifo,
  input wire         ifctrl_icache_if_inv_on,
  input wire         ifctrl_icache_if_read_req_data0,
  input wire         ifctrl_icache_if_read_req_data1,
  input wire [ 31:0] ifctrl_icache_if_read_req_index,
  input wire         ifctrl_icache_if_read_req_tag,
  input wire         ifctrl_icache_if_reset_req,
  input wire         ifctrl_icache_if_tag_req,
  input wire [  2:0] ifctrl_icache_if_tag_wen,
  input wire         ifu_hpcp_icache_miss_pre,
  input wire [ 31:0] ipb_icache_if_index,
  input wire         ipb_icache_if_req,
  input wire         ipb_icache_if_req_for_gateclk,
  input wire         l1_refill_icache_if_fifo,
  input wire         l1_refill_icache_if_first,
  input wire [ 31:0] l1_refill_icache_if_index,
  input wire [127:0] l1_refill_icache_if_inst_data,
  input wire         l1_refill_icache_if_last,
  input wire [ 31:0] l1_refill_icache_if_pre_code,
  input wire [TAG_BITS-1:0] l1_refill_icache_if_ptag,
  input wire         l1_refill_icache_if_wr,

  // Clock, reset and configuration
  input wire pad_yy_icg_scan_en,

  // Cache array and pipeline interface
  input  wire         pcgen_icache_if_chgflw,
  input  wire         pcgen_icache_if_chgflw_bank0,
  input  wire         pcgen_icache_if_chgflw_bank1,
  input  wire         pcgen_icache_if_chgflw_bank2,
  input  wire         pcgen_icache_if_chgflw_bank3,
  input  wire         pcgen_icache_if_chgflw_short,
  input  wire         pcgen_icache_if_gateclk_en,
  input  wire [ 31:0] pcgen_icache_if_index,
  input  wire         pcgen_icache_if_seq_data_req,
  input  wire         pcgen_icache_if_seq_data_req_short,
  input  wire         pcgen_icache_if_seq_tag_req,
  input  wire [  1:0] pcgen_icache_if_way_pred,
  output wire [127:0] icache_if_ifctrl_inst_data0,
  output wire [127:0] icache_if_ifctrl_inst_data1,
  // [ICACHE 参数化] tag 宽度必须随几何走; 写死 17 位会让 TAG_BITS!=17 的几何
  // 在父层被截断, 三片比较里的 part2 退化成恒假 ⇒ 永不命中。
  output wire [TAG_WIDTH-1:0] icache_if_ifctrl_tag_data0,
  output wire [TAG_WIDTH-1:0] icache_if_ifctrl_tag_data1,
  output wire         icache_if_ifdp_fifo,
  output wire [127:0] icache_if_ifdp_inst_data0,
  output wire [127:0] icache_if_ifdp_inst_data1,
  output wire [ 31:0] icache_if_ifdp_precode0,
  output wire [ 31:0] icache_if_ifdp_precode1,
  output wire [TAG_WIDTH-1:0] icache_if_ifdp_tag_data0,
  output wire [TAG_WIDTH-1:0] icache_if_ifdp_tag_data1,
  output wire [TAG_WIDTH-1:0] icache_if_ipb_tag_data0,
  output wire [TAG_WIDTH-1:0] icache_if_ipb_tag_data1,
  output wire         ifu_hpcp_icache_access,
  output wire         ifu_hpcp_icache_miss
);

  //------------------------------------------------------------------------------
  // Local parameters and net declarations
  //------------------------------------------------------------------------------
  localparam WAY_COUNT   = 2;
  localparam BANK_COUNT  = 4;
  localparam OWNER_COUNT = 4;
  localparam EVENT_COUNT = 2;

  genvar way;
  genvar bank;
  genvar owner;
  genvar bit_index;
  genvar event_index;
  wire [            INDEX_WIDTH-1:0] icache_index_higher;
  wire [            INDEX_WIDTH-1:0] ifu_icache_index;
  wire [            OWNER_COUNT-1:0] icache_index_sel;
  wire [            OWNER_COUNT-1:0] owner_select;
  wire [OWNER_COUNT*INDEX_WIDTH-1:0] owner_indices;
  wire [            OWNER_COUNT-1:0] index_terms           [0:INDEX_WIDTH-1];
  wire                               icache_read_req;
  wire                               icache_req_higher;
  wire                               icache_reset_inv;
  wire                               fifo_bit;
  wire [              WAY_COUNT-1:0] icache_way_pred;
  wire [              WAY_COUNT-1:0] software_data_read;
  wire [             BANK_COUNT-1:0] bank_chgflw;
  wire [              WAY_COUNT-1:0] way_refill;
  wire [              WAY_COUNT-1:0] way_enabled;
  wire [             BANK_COUNT-1:0] data_cen_b            [  0:WAY_COUNT-1];
  wire [             BANK_COUNT-1:0] data_clk_en           [  0:WAY_COUNT-1];
  wire [              WAY_COUNT-1:0] way_clk_en;
  wire [              WAY_COUNT-1:0] way_wen_b;
  wire [              WAY_COUNT-1:0] precode_cen_b;
  wire [                      127:0] data_din;
  wire [                       31:0] precode_din;
  wire [          WAY_COUNT*128-1:0] data_dout;
  wire [           WAY_COUNT*32-1:0] precode_dout;
  wire [              2*TAG_WIDTH:0] icache_ifu_tag_dout;
  wire [              2*TAG_WIDTH:0] ifu_icache_tag_din;
  wire [                        2:0] ifu_icache_tag_wen;
  wire                               ifu_icache_tag_cen_b;
  wire                               ifu_icache_tag_clk_en;
  wire                               refill_tag_write;
  wire                               refill_publish;
  wire                               tag_fifo_din;
  wire                               tag_valid_din;
  wire [                TAG_BITS-1:0] tag_pc_din;
  wire                               hpcp_clk;
  wire                               hpcp_clk_en;
  wire [            EVENT_COUNT-1:0] event_source;
  wire [            EVENT_COUNT-1:0] event_en;
  wire [            EVENT_COUNT-1:0] event_nxt;
  wire [            EVENT_COUNT-1:0] event_out;
  reg  [            EVENT_COUNT-1:0] event_q;

  //------------------------------------------------------------------------------
  // Address ownership: exact one-hot selection, not a priority arbiter
  //------------------------------------------------------------------------------
  assign fifo_bit = l1_refill_icache_if_fifo;
  assign icache_reset_inv = ifctrl_icache_if_reset_req;
  assign icache_read_req = ifctrl_icache_if_read_req_data0 || ifctrl_icache_if_read_req_data1 ||
    ifctrl_icache_if_read_req_tag;
  assign icache_index_sel = {
    ifctrl_icache_if_tag_req || icache_reset_inv,
    l1_refill_icache_if_wr,
    ipb_icache_if_req,
    icache_read_req
  };
// [临时诊断] 打印实际生效的几何参数; 定位完即删
  initial $display("[ICACHE] BYTES=%0d LINE=%0d SETS=%0d SET_BITS=%0d LINE_BITS=%0d TAG_BITS=%0d TAG_WIDTH=%0d BEATS=%0d",
                   IC_BYTES, IC_LINE, IC_SETS, SET_BITS, LINE_BITS, TAG_BITS, TAG_WIDTH, BEATS);

  assign icache_req_higher = |icache_index_sel;
  assign owner_indices = {
    ifctrl_icache_if_index[INDEX_WIDTH-1:0],
    l1_refill_icache_if_index[INDEX_WIDTH-1:0],
    ipb_icache_if_index[INDEX_WIDTH-1:0],
    ifctrl_icache_if_read_req_index[INDEX_WIDTH-1:0]
  };

  generate
    for (owner = 0; owner < OWNER_COUNT; owner = owner + 1) begin : g_owner
      localparam [OWNER_COUNT-1:0] OWNER_MASK = 4'b0001 << owner;
      // No/multiple owners produce zero, as in the original case/default mux.
      assign owner_select[owner] = icache_index_sel == OWNER_MASK;
      for (bit_index = 0; bit_index < INDEX_WIDTH; bit_index = bit_index + 1) begin : g_bit
        assign index_terms[bit_index][owner] = owner_select[owner] &
          owner_indices[owner*INDEX_WIDTH+bit_index];
      end
    end
    for (bit_index = 0; bit_index < INDEX_WIDTH; bit_index = bit_index + 1) begin : g_index_reduce
      assign icache_index_higher[bit_index] = |index_terms[bit_index];
    end
  endgenerate
  assign ifu_icache_index = icache_req_higher ? icache_index_higher : pcgen_icache_if_index[INDEX_WIDTH-1:0];

  //------------------------------------------------------------------------------
  // Shared Tag port: first beat clears valid; qualified last beat publishes
  //------------------------------------------------------------------------------
  assign refill_tag_write = l1_refill_icache_if_wr &&
    (l1_refill_icache_if_first || l1_refill_icache_if_last);
  assign refill_publish = l1_refill_icache_if_wr && l1_refill_icache_if_last &&
    l1_refill_icache_if_install;
  assign
    ifu_icache_tag_cen_b = !(refill_tag_write && cp0_ifu_icache_en) && !ifctrl_icache_if_tag_req &&
    !(pcgen_icache_if_chgflw && (pcgen_icache_if_way_pred != 2'b00) && cp0_ifu_icache_en) &&
    !(pcgen_icache_if_seq_tag_req && cp0_ifu_icache_en) &&
    !(ipb_icache_if_req && cp0_ifu_icache_en) && !ifctrl_icache_if_read_req_tag;
  assign ifu_icache_tag_clk_en = ifctrl_icache_if_tag_req || ifctrl_icache_if_read_req_tag ||
    (cp0_ifu_icache_en &&
     (l1_refill_icache_if_wr || pcgen_icache_if_gateclk_en || ipb_icache_if_req_for_gateclk));
  assign
    ifu_icache_tag_wen[2] = ifctrl_icache_if_inv_on ? ifctrl_icache_if_tag_wen[2] : !refill_publish;
  assign tag_fifo_din = ifctrl_icache_if_inv_on ? ifctrl_icache_if_inv_fifo : !fifo_bit;
  assign tag_valid_din = !ifctrl_icache_if_inv_on && l1_refill_icache_if_last &&
    l1_refill_icache_if_install;
  // [16 B 行] first 与 last 是同一拍, 不能按"首拍清 tag"处理, 否则 tag 恒为 0 ⇒ 永不命中
  assign tag_pc_din = (ifctrl_icache_if_inv_on ||
                       (l1_refill_icache_if_first && (BEATS > 1))) ? {TAG_BITS{1'b0}} :
    l1_refill_icache_if_ptag;
  assign ifu_icache_tag_din[2*TAG_WIDTH] = tag_fifo_din;

  rv32_ifu_icache_tag_array #(
    .INDEX_MSB (INDEX_WIDTH-1), .SET_LSB(LINE_BITS),
    .ADDR_WIDTH(SET_BITS), .DATA_WIDTH(2*TAG_WIDTH+1)
  ) u_icache_tag_array (
    .forever_cpuclk       (forever_cpuclk),
    .cp0_ifu_icg_en       (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en   (pad_yy_icg_scan_en),
    .ifu_icache_index     (ifu_icache_index),
    .ifu_icache_tag_cen_b (ifu_icache_tag_cen_b),
    .ifu_icache_tag_clk_en(ifu_icache_tag_clk_en),
    .ifu_icache_tag_din   (ifu_icache_tag_din),
    .ifu_icache_tag_wen   (ifu_icache_tag_wen),
    .icache_ifu_tag_dout  (icache_ifu_tag_dout)
  );

  //------------------------------------------------------------------------------
  // Generated Way/bank controls and identical SRAM wrappers
  //------------------------------------------------------------------------------
  assign icache_way_pred = l1_refill_icache_if_wr ? 2'b11 : pcgen_icache_if_way_pred;
  assign software_data_read = {ifctrl_icache_if_read_req_data1, ifctrl_icache_if_read_req_data0};
  assign bank_chgflw = {
    pcgen_icache_if_chgflw_bank3,
    pcgen_icache_if_chgflw_bank2,
    pcgen_icache_if_chgflw_bank1,
    pcgen_icache_if_chgflw_bank0
  };
  assign data_din = icache_reset_inv ? 128'b0 : l1_refill_icache_if_inst_data;
  assign precode_din = icache_reset_inv ? 32'b0 : l1_refill_icache_if_pre_code;

  generate
    for (way = 0; way < WAY_COUNT; way = way + 1) begin : g_way
      localparam WAY_ID = (way == 1);
      assign way_refill[way] = l1_refill_icache_if_wr && (fifo_bit == WAY_ID);
      assign way_enabled[way] = cp0_ifu_icache_en && icache_way_pred[way];
      assign way_wen_b[way] = !way_refill[way] && !icache_reset_inv;
      assign way_clk_en[way] = ((way_refill[way] || pcgen_icache_if_chgflw_short ||
                                 pcgen_icache_if_seq_data_req_short) && cp0_ifu_icache_en) ||
        software_data_read[way] || icache_reset_inv;
      assign precode_cen_b[way] = ((!way_refill[way] && !pcgen_icache_if_chgflw &&
                                    !pcgen_icache_if_seq_data_req) || !way_enabled[way]) &&
        !icache_reset_inv && !software_data_read[way];
      assign ifu_icache_tag_wen[way] = ifctrl_icache_if_inv_on ? ifctrl_icache_if_tag_wen[way] :
        !(refill_tag_write && (fifo_bit == WAY_ID));
      assign ifu_icache_tag_din[way*TAG_WIDTH+:TAG_WIDTH] = {tag_valid_din, tag_pc_din};

      for (bank = 0; bank < BANK_COUNT; bank = bank + 1) begin : g_bank
        assign data_cen_b[way][bank] = ((!way_refill[way] && !bank_chgflw[bank] &&
                                         !pcgen_icache_if_seq_data_req) || !way_enabled[way]) &&
          !software_data_read[way] && !icache_reset_inv;
        assign data_clk_en[way][bank] = way_clk_en[way];
      end

      // The original array0/array1 modules are identical after port renaming.
      // Instantiate array0 twice: each generated instance has independent SRAM.
      // Legacy array1 files remain available for existing direct instantiations.
      rv32_ifu_icache_data_array0 #(
        .INDEX_MSB(INDEX_WIDTH-1), .WORD_LSB(4),
        .ADDR_WIDTH(SET_BITS+(LINE_BITS-4)), .DATA_WIDTH(32)
      ) u_data_array (
        .forever_cpuclk                     (forever_cpuclk),
        .cp0_ifu_icg_en                     (cp0_ifu_icg_en),
        .cp0_yy_clk_en                      (cp0_yy_clk_en),
        .pad_yy_icg_scan_en                 (pad_yy_icg_scan_en),
        .ifu_icache_index                   (ifu_icache_index),
        .ifu_icache_data_array0_bank0_cen_b (data_cen_b[way][0]),
        .ifu_icache_data_array0_bank1_cen_b (data_cen_b[way][1]),
        .ifu_icache_data_array0_bank2_cen_b (data_cen_b[way][2]),
        .ifu_icache_data_array0_bank3_cen_b (data_cen_b[way][3]),
        .ifu_icache_data_array0_bank0_clk_en(data_clk_en[way][0]),
        .ifu_icache_data_array0_bank1_clk_en(data_clk_en[way][1]),
        .ifu_icache_data_array0_bank2_clk_en(data_clk_en[way][2]),
        .ifu_icache_data_array0_bank3_clk_en(data_clk_en[way][3]),
        .ifu_icache_data_array0_wen_b       (way_wen_b[way]),
        .ifu_icache_data_array0_din         (data_din),
        .icache_ifu_data_array0_dout        (data_dout[way*128+:128])
      );
      rv32_ifu_icache_predecd_array0 #(
        .INDEX_MSB(INDEX_WIDTH-1), .WORD_LSB(4),
        .ADDR_WIDTH(SET_BITS+(LINE_BITS-4)), .DATA_WIDTH(32)
      ) u_precode_array (
        .forever_cpuclk                  (forever_cpuclk),
        .cp0_ifu_icg_en                  (cp0_ifu_icg_en),
        .cp0_yy_clk_en                   (cp0_yy_clk_en),
        .pad_yy_icg_scan_en              (pad_yy_icg_scan_en),
        .ifu_icache_index                (ifu_icache_index),
        .ifu_icache_predecd_array0_cen_b (precode_cen_b[way]),
        .ifu_icache_predecd_array0_clk_en(way_clk_en[way]),
        .ifu_icache_predecd_array0_wen_b (way_wen_b[way]),
        .ifu_icache_predecd_array0_din   (precode_din),
        .icache_ifu_predecd_array0_dout  (precode_dout[way*32+:32])
      );
    end
  endgenerate

  //------------------------------------------------------------------------------
  // Generated performance event storage: reset and enabled update only
  //------------------------------------------------------------------------------
  assign event_source = {
    ifu_hpcp_icache_miss_pre, pcgen_icache_if_seq_data_req || pcgen_icache_if_chgflw
  };
  assign hpcp_clk_en = (cp0_ifu_icache_en && hpcp_ifu_cnt_en) || (|event_q);
  rv32_ifu_clk_cell u_hpcp_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (hpcp_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (hpcp_clk_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );
  generate
    for (event_index = 0; event_index < EVENT_COUNT; event_index = event_index + 1) begin : g_event
      assign event_en[event_index] = 1'b1;
      assign
        event_nxt[event_index] = hpcp_ifu_cnt_en && cp0_ifu_icache_en && event_source[event_index];
      always @(posedge hpcp_clk or negedge cpurst_b) begin : p_event
        if (!cpurst_b) begin
          event_q[event_index] <= 1'b0;
        end else if (event_en[event_index]) begin
          event_q[event_index] <= event_nxt[event_index];
        end
      end
      assign event_out[event_index] = hpcp_ifu_cnt_en && event_q[event_index];
    end
  endgenerate

  //------------------------------------------------------------------------------
  // Public output connections; the original interface is preserved
  //------------------------------------------------------------------------------
  assign {ifu_hpcp_icache_miss, ifu_hpcp_icache_access}             = event_out;
  assign icache_if_ifdp_fifo                                        = icache_ifu_tag_dout[2*TAG_WIDTH];
  assign {icache_if_ifdp_tag_data1, icache_if_ifdp_tag_data0}       = icache_ifu_tag_dout[2*TAG_WIDTH-1:0];
  assign {icache_if_ifctrl_tag_data1, icache_if_ifctrl_tag_data0}   = icache_ifu_tag_dout[2*TAG_WIDTH-1:0];
  assign {icache_if_ipb_tag_data1, icache_if_ipb_tag_data0}         = icache_ifu_tag_dout[2*TAG_WIDTH-1:0];
  assign {icache_if_ifdp_inst_data1, icache_if_ifdp_inst_data0}     = data_dout;
  assign {icache_if_ifctrl_inst_data1, icache_if_ifctrl_inst_data0} = data_dout;
  assign {icache_if_ifdp_precode1, icache_if_ifdp_precode0}         = precode_dout;
endmodule
