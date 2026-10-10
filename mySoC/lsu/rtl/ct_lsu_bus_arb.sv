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

module ct_lsu_bus_arb (
  input  logic         biu_lsu_ar_ready,
  input  logic         biu_lsu_aw_vb_grnt,
  input  logic         biu_lsu_aw_wmb_grnt,
  input  logic         biu_lsu_w_vb_grnt,
  input  logic         biu_lsu_w_wmb_grnt,

  // RB AR request
  input  logic [31:0]  rb_biu_ar_addr,
//  input  logic [1:0]   rb_biu_ar_bar,
  input  logic [1:0]   rb_biu_ar_burst,
  input  logic [3:0]   rb_biu_ar_cache,
 // input  logic [1:0]   rb_biu_ar_domain,
  input  logic [3:0]   rb_biu_ar_id,
  input  logic [1:0]   rb_biu_ar_len,
  input  logic         rb_biu_ar_lock,
  input  logic [2:0]   rb_biu_ar_prot,
  input  logic         rb_biu_ar_req,
  input  logic [2:0]   rb_biu_ar_size,
 // input  logic [2:0]   rb_biu_ar_user,

  // VB AW request
  input  logic [31:0]  vb_biu_aw_addr,
 // input  logic [1:0]   vb_biu_aw_bar,
  input  logic [1:0]   vb_biu_aw_burst,
  input  logic [3:0]   vb_biu_aw_cache,
 // input  logic [1:0]   vb_biu_aw_domain,
  input  logic [3:0]   vb_biu_aw_id,
  input  logic [1:0]   vb_biu_aw_len,
  input  logic         vb_biu_aw_lock,
  input  logic [2:0]   vb_biu_aw_prot,
  input  logic         vb_biu_aw_req,
  input  logic [2:0]   vb_biu_aw_size,
 // input  logic         vb_biu_aw_user,

  // VB W request
  input  logic [127:0] vb_biu_w_data,
  input  logic         vb_biu_w_last,
  input  logic         vb_biu_w_req,
  input  logic [15:0]  vb_biu_w_strb,
  input  logic         vb_biu_w_vld,

  // WMB AW request
  input  logic [31:0]  wmb_biu_aw_addr,
//  input  logic [1:0]   wmb_biu_aw_bar,
  input  logic [1:0]   wmb_biu_aw_burst,
  input  logic [3:0]   wmb_biu_aw_cache,
 // input  logic [1:0]   wmb_biu_aw_domain,
  input  logic [3:0]   wmb_biu_aw_id,
  input  logic [1:0]   wmb_biu_aw_len,
  input  logic         wmb_biu_aw_lock,
  input  logic [2:0]   wmb_biu_aw_prot,
  input  logic         wmb_biu_aw_req,
  input  logic [2:0]   wmb_biu_aw_size,
 // input  logic         wmb_biu_aw_user,

  // WMB W request
  input  logic [127:0] wmb_biu_w_data,
  input  logic         wmb_biu_w_last,
  input  logic         wmb_biu_w_req,
  input  logic [15:0]  wmb_biu_w_strb,
  input  logic         wmb_biu_w_vld,

  // AR grant
  output logic         bus_arb_rb_ar_grnt,

  // AW grants
  output logic         bus_arb_vb_aw_grnt,
  output logic         bus_arb_wmb_aw_grnt,

  // W grants
  output logic         bus_arb_vb_w_grnt,
  output logic         bus_arb_wmb_w_grnt,

  // BIU AR outputs
  output logic [31:0]  lsu_biu_ar_addr,
  //output logic [1:0]   lsu_biu_ar_bar,
  output logic [1:0]   lsu_biu_ar_burst,
  output logic [3:0]   lsu_biu_ar_cache,
 // output logic [1:0]   lsu_biu_ar_domain,
  output logic [3:0]   lsu_biu_ar_id,
  output logic [1:0]   lsu_biu_ar_len,
  output logic         lsu_biu_ar_lock,
  output logic [2:0]   lsu_biu_ar_prot,
  output logic         lsu_biu_ar_req,
  output logic [2:0]   lsu_biu_ar_size,
 // output logic [2:0]   lsu_biu_ar_user,

  // BIU AW store outputs
  output logic [31:0]  lsu_biu_aw_st_addr,
//  output logic [1:0]   lsu_biu_aw_st_bar,
  output logic [1:0]   lsu_biu_aw_st_burst,
  output logic [3:0]   lsu_biu_aw_st_cache,
 // output logic [1:0]   lsu_biu_aw_st_domain,
  output logic [3:0]   lsu_biu_aw_st_id,
  output logic [1:0]   lsu_biu_aw_st_len,
  output logic         lsu_biu_aw_st_lock,
  output logic [2:0]   lsu_biu_aw_st_prot,
  output logic         lsu_biu_aw_st_req,
  output logic [2:0]   lsu_biu_aw_st_size,
 // output logic         lsu_biu_aw_st_user,

  // BIU AW victim outputs
  output logic [31:0]  lsu_biu_aw_vict_addr,
//  output logic [1:0]   lsu_biu_aw_vict_bar,
  output logic [1:0]   lsu_biu_aw_vict_burst,
  output logic [3:0]   lsu_biu_aw_vict_cache,
 // output logic [1:0]   lsu_biu_aw_vict_domain,
  output logic [3:0]   lsu_biu_aw_vict_id,
  output logic [1:0]   lsu_biu_aw_vict_len,
  output logic         lsu_biu_aw_vict_lock,
  output logic [2:0]   lsu_biu_aw_vict_prot,
  output logic         lsu_biu_aw_vict_req,
  output logic [2:0]   lsu_biu_aw_vict_size,
 // output logic         lsu_biu_aw_vict_user,

  // BIU W store outputs
  output logic [127:0] lsu_biu_w_st_data,
  output logic         lsu_biu_w_st_last,
  output logic [15:0]  lsu_biu_w_st_strb,
  output logic         lsu_biu_w_st_vld,

  // BIU W victim outputs
  output logic [127:0] lsu_biu_w_vict_data,
  output logic         lsu_biu_w_vict_last,
  output logic [15:0]  lsu_biu_w_vict_strb,
  output logic         lsu_biu_w_vict_vld
);

  //==========================================================
  //                      AR channel
  //==========================================================
  // 现在 BIU AR 只有 RB 请求，直接旁路，无需仲裁
  assign bus_arb_rb_ar_grnt = biu_lsu_ar_ready && rb_biu_ar_req;

  assign lsu_biu_ar_id        = rb_biu_ar_id;
  assign lsu_biu_ar_addr      = rb_biu_ar_addr;
  assign lsu_biu_ar_len       = rb_biu_ar_len;
  assign lsu_biu_ar_size      = rb_biu_ar_size;
  assign lsu_biu_ar_burst     = rb_biu_ar_burst;
  assign lsu_biu_ar_lock      = rb_biu_ar_lock;
  assign lsu_biu_ar_cache     = rb_biu_ar_cache;
  assign lsu_biu_ar_prot      = rb_biu_ar_prot;
  assign lsu_biu_ar_req       = rb_biu_ar_req;
 // assign lsu_biu_ar_user      = rb_biu_ar_user;
 // assign lsu_biu_ar_domain    = rb_biu_ar_domain;
 // assign lsu_biu_ar_bar       = rb_biu_ar_bar;

  //==========================================================
  //                      AW channel
  //==========================================================
  // priority: VB > WMB
  assign bus_arb_vb_aw_grnt  = biu_lsu_aw_vb_grnt  && vb_biu_aw_req;
  assign bus_arb_wmb_aw_grnt = biu_lsu_aw_wmb_grnt && wmb_biu_aw_req;

  // VB AW -> victim
  assign lsu_biu_aw_vict_req    = vb_biu_aw_req;
  assign lsu_biu_aw_vict_id     = vb_biu_aw_id;
  assign lsu_biu_aw_vict_addr   = vb_biu_aw_addr;
  assign lsu_biu_aw_vict_len    = vb_biu_aw_len;
  assign lsu_biu_aw_vict_size   = vb_biu_aw_size;
  assign lsu_biu_aw_vict_burst  = vb_biu_aw_burst;
  assign lsu_biu_aw_vict_lock   = vb_biu_aw_lock;
  assign lsu_biu_aw_vict_cache  = vb_biu_aw_cache;
  assign lsu_biu_aw_vict_prot   = vb_biu_aw_prot;
  //assign lsu_biu_aw_vict_user   = vb_biu_aw_user;
 // assign lsu_biu_aw_vict_domain = vb_biu_aw_domain;
 // assign lsu_biu_aw_vict_bar    = vb_biu_aw_bar;

  // WMB AW -> store
  assign lsu_biu_aw_st_req      = wmb_biu_aw_req;
  assign lsu_biu_aw_st_id       = wmb_biu_aw_id;
  assign lsu_biu_aw_st_addr     = wmb_biu_aw_addr;
  assign lsu_biu_aw_st_len      = wmb_biu_aw_len;
  assign lsu_biu_aw_st_size     = wmb_biu_aw_size;
  assign lsu_biu_aw_st_burst    = wmb_biu_aw_burst;
  assign lsu_biu_aw_st_lock     = wmb_biu_aw_lock;
  assign lsu_biu_aw_st_cache    = wmb_biu_aw_cache;
  assign lsu_biu_aw_st_prot     = wmb_biu_aw_prot;
//  assign lsu_biu_aw_st_user     = wmb_biu_aw_user;
 // assign lsu_biu_aw_st_domain   = wmb_biu_aw_domain;
//  assign lsu_biu_aw_st_bar      = wmb_biu_aw_bar;

  //==========================================================
  //                        W channel
  //==========================================================
  assign bus_arb_vb_w_grnt  = biu_lsu_w_vb_grnt  && vb_biu_w_req;
  assign bus_arb_wmb_w_grnt = biu_lsu_w_wmb_grnt && wmb_biu_w_req;

  assign lsu_biu_w_vict_vld   = vb_biu_w_vld;
  assign lsu_biu_w_vict_data  = vb_biu_w_data;
  assign lsu_biu_w_vict_strb  = vb_biu_w_strb;
  assign lsu_biu_w_vict_last  = vb_biu_w_last;

  assign lsu_biu_w_st_vld     = wmb_biu_w_vld;
  assign lsu_biu_w_st_data    = wmb_biu_w_data;
  assign lsu_biu_w_st_strb    = wmb_biu_w_strb;
  assign lsu_biu_w_st_last    = wmb_biu_w_last;

endmodule