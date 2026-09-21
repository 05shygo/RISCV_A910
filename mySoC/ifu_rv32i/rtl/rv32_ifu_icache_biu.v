// SPDX-License-Identifier: Apache-2.0
// Demand-only BIU adapter for independent ICache bring-up, Excel v1.1 P05/P06.
// In a complete IFU the IPB/BIU arbiter replaces this adapter, intercepts matching
// demand lines and arbitrates ID0/ID1. This module NEVER consumes an ID1 return.
// Internal req/grant may be withdrawn before grant; these are NOT AXI AR pins.
// Configuration must be stable throughout a granted transaction (Protocol P20).
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_icache_biu (
  input  wire         miss_vld,
  output wire         miss_ready,
  input  wire [ 31:0] miss_pc,
  input  wire         miss_allocate,
  input  wire [  4:0] miss_attr,
  output wire         refill_vld,
  input  wire         refill_ready,
  output wire [127:0] refill_data,
  output wire         refill_error,
  output wire         refill_last,
  input  wire         cp0_ifu_insde,
  input  wire [  1:0] cp0_yy_priv_mode,
  output wire         ifu_biu_rd_req,
  output wire         ifu_biu_rd_req_gate,
  output wire [ 31:0] ifu_biu_rd_addr,
  output wire         ifu_biu_rd_id,
  output wire [  1:0] ifu_biu_rd_len,
  output wire [  2:0] ifu_biu_rd_size,
  output wire [  1:0] ifu_biu_rd_burst,
  output wire [  3:0] ifu_biu_rd_cache,
  output wire [  2:0] ifu_biu_rd_prot,
  output wire [  1:0] ifu_biu_rd_domain,
  output wire [  3:0] ifu_biu_rd_snoop,
  output wire [  1:0] ifu_biu_rd_user,
  input  wire         biu_ifu_rd_grnt,
  input  wire         biu_ifu_rd_data_vld,
  input  wire [127:0] biu_ifu_rd_data,
  input  wire         biu_ifu_rd_id,
  input  wire         biu_ifu_rd_last,
  input  wire [  1:0] biu_ifu_rd_resp,
  output wire         ifu_biu_r_ready
);
  assign ifu_biu_rd_req      = miss_vld;
  assign ifu_biu_rd_req_gate = miss_vld;
  assign miss_ready          = biu_ifu_rd_grnt;
  assign ifu_biu_rd_addr     = {miss_pc[31:4], 4'b0};
  assign ifu_biu_rd_id       = 1'b0;
  assign ifu_biu_rd_len      = miss_allocate ? 2'b11 : 2'b00;
  assign ifu_biu_rd_size     = 3'b100;
  assign ifu_biu_rd_burst    = miss_allocate ? 2'b10 : 2'b01;
  assign ifu_biu_rd_cache    = {miss_attr[3], miss_attr[3], 1'b1, miss_attr[2]};
  assign ifu_biu_rd_prot     = {1'b1, miss_attr[1], (cp0_yy_priv_mode != 2'b00)};
  assign ifu_biu_rd_domain   = miss_attr[3] ? {1'b0, !cp0_ifu_insde} : 2'b11;
  assign ifu_biu_rd_snoop    = (miss_allocate && !cp0_ifu_insde) ? 4'b0001 : 4'b0000;
  assign ifu_biu_rd_user     = {(cp0_yy_priv_mode == 2'b11), 1'b0};
  assign refill_vld          = biu_ifu_rd_data_vld && !biu_ifu_rd_id;
  assign refill_data         = biu_ifu_rd_data;
  assign refill_error        = biu_ifu_rd_resp[1];
  assign refill_last         = biu_ifu_rd_last;
  assign ifu_biu_r_ready     = refill_ready && !biu_ifu_rd_id;
endmodule
