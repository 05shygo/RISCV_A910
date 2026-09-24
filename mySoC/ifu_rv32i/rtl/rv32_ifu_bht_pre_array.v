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

// RV32I port, 2026-09-20: portable synchronous SRAM; original control polarity/read latency retained.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_bht_pre_array #(
  // [BP_SHRINK] 方向预测阵列的行数可配, 默认 = 原样 1024 行 (ADDR_WIDTH=10)。
  // `+define+BP_PRE_AW=n` 覆盖成 2^n 行。
  // 实现方式是**只保留索引的低 n 位, 高位截掉** —— 等效于"同一套哈希、更小的表",
  // 多出来的就是别名。上游 (rv32_ifu_bht.v) 不用改: 宽表达式接窄端口按低位截断。
`ifdef BP_PRE_AW
  parameter PRE_AW = `BP_PRE_AW
`else
  parameter PRE_AW = 10
`endif
) (

  // Predictor and pipeline interface
  input wire        bht_pre_array_clk_en,
  input wire        bht_pred_array_cen_b,
  input wire [63:0] bht_pred_array_din,
  input wire        bht_pred_array_gwen,
  input wire [9:0] bht_pred_array_index,
  input wire [63:0] bht_pred_bwen,

  // Clock, reset and configuration
  input wire cp0_ifu_icg_en,
  input wire cp0_yy_clk_en,
  input wire forever_cpuclk,
  input wire pad_yy_icg_scan_en,

  // Predictor and pipeline interface
  output wire [63:0] bht_pre_data_out
);

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  wire bht_pre_clk;
  wire bht_pre_en;
  wire [PRE_AW-1:0] bht_pre_folded_index;

  //------------------------------------------------------------------------------
  // Combinational logic and register updates
  //------------------------------------------------------------------------------

  //Gate Clk
  rv32_ifu_clk_cell u_bht_pre_clk (
    .clk_in            (forever_cpuclk),
    .clk_out           (bht_pre_clk),
    .external_en       (1'b0),
    .global_en         (cp0_yy_clk_en),
    .local_en          (bht_pre_en),
    .module_en         (cp0_ifu_icg_en),
    .pad_yy_icg_scan_en(pad_yy_icg_scan_en)
  );

  assign bht_pre_en = bht_pre_array_clk_en;

  //Instance Logic
  // [BP_PRE_FOLD] 把完整 10 位行索引 XOR 折到 PRE_AW 位, 而不是截掉高位。
  //   bht.v 里 7 个索引来源(写缓冲/失效/普通预测/各类恢复读)汇成同一根
  //   bht_pred_array_index[9:0], 所以在这一处折叠对读/写/失效/恢复读一律一致。
  //   截断只留低 PRE_AW 位 ⇒ 行索引高位的那些历史位被整块丢弃;
  //   折叠加回后, 同样行数的小表仍能区分一部分历史上下文。
  //   未定义 BP_PRE_FOLD 时保持原样的截断行为 ⇒ 基线逐位可复现。
`ifdef BP_PRE_FOLD
  generate
    genvar fold_bit;
    for (fold_bit = 0; fold_bit < PRE_AW; fold_bit = fold_bit + 1) begin : g_pre_index_fold
      if (fold_bit + PRE_AW < 10) begin : g_xor
        assign bht_pre_folded_index[fold_bit] =
          bht_pred_array_index[fold_bit] ^ bht_pred_array_index[fold_bit + PRE_AW];
      end else begin : g_pass
        assign bht_pre_folded_index[fold_bit] = bht_pred_array_index[fold_bit];
      end
    end
  endgenerate
`else
  assign bht_pre_folded_index = bht_pred_array_index[PRE_AW-1:0];
`endif

  rv32_ifu_spram #(
    .ADDR_WIDTH(PRE_AW),
    .DATA_WIDTH(64)
  ) u_ct_spsram_pre (
    .A   (bht_pre_folded_index),
    .CEN (bht_pred_array_cen_b),
    .CLK (bht_pre_clk),
    .D   (bht_pred_array_din),
    .GWEN(bht_pred_array_gwen),
    .Q   (bht_pre_data_out),
    .WEN (bht_pred_bwen)
  );
endmodule
