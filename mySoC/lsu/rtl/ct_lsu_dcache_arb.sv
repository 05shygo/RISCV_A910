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

// Simplified dcache arbiter for RV32I
// - Only AG/WMB/LFB/VB request sources (removed SNQ/ICC/MCIC)
// - No serial request (removed consecutive two-cycle request feature)
// - Configurable dcache capacity support

module ct_lsu_dcache_arb #(
  parameter int DCACHE_SIZE = 2048,  // 1024, 2048, or 4096 bytes
  // Derived parameters for dcache indexing
  parameter int CACHELINE_SIZE = 32,
  parameter int NUM_WAYS = 2,
  parameter int OFFSET_WIDTH = 5,
  parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
  parameter int INDEX_WIDTH = $clog2(NUM_SETS),
  parameter int INDEX_LSB = OFFSET_WIDTH,
  parameter int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1,
  parameter int DATA_INDEX_WIDTH = INDEX_WIDTH + 1,
  parameter int TAG_LSB = INDEX_MSB + 1,
  parameter int TAG_WIDTH = 32 - TAG_LSB,
  parameter int LD_TAG_WIDTH = TAG_WIDTH * 2 + 2,
  parameter int ST_TAG_WIDTH = TAG_WIDTH * 2
)(
  // Clock and reset
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,

  //==========================================================
  // AG stage requests
  //==========================================================
  input  logic         ag_dcache_arb_ld_tag_req,
  input  logic         ag_dcache_arb_ld_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  ag_dcache_arb_ld_tag_idx,
  input  logic [7:0]        ag_dcache_arb_ld_data_req,
  input  logic [7:0]   ag_dcache_arb_ld_data_gateclk_en,
  input  logic [DATA_INDEX_WIDTH-1:0]  ag_dcache_arb_ld_data_low_idx,
  input  logic [DATA_INDEX_WIDTH-1:0]  ag_dcache_arb_ld_data_high_idx,

  input  logic         ag_dcache_arb_st_tag_req,
  input  logic         ag_dcache_arb_st_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  ag_dcache_arb_st_tag_idx,
  input  logic         ag_dcache_arb_st_dirty_req,
  input  logic         ag_dcache_arb_st_dirty_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  ag_dcache_arb_st_dirty_idx,

  //==========================================================
  // VEC requests (2026-10-18 直连向量 L/S)
  //==========================================================
  input  logic         vec_dcache_arb_ld_req,
  input  logic [INDEX_WIDTH-1:0]  vec_dcache_arb_ld_tag_idx,
  input  logic [7:0]   vec_dcache_arb_ld_data_req,
  input  logic [DATA_INDEX_WIDTH-1:0]  vec_dcache_arb_ld_data_low_idx,
  input  logic [DATA_INDEX_WIDTH-1:0]  vec_dcache_arb_ld_data_high_idx,

  input  logic         vec_dcache_arb_st_tag_req,
  input  logic [INDEX_WIDTH-1:0]  vec_dcache_arb_st_tag_idx,
  input  logic         vec_dcache_arb_st_dirty_req,
  input  logic [INDEX_WIDTH-1:0]  vec_dcache_arb_st_dirty_idx,

  output logic         dcache_arb_vec_ld_sel,
  output logic         dcache_arb_vec_st_sel,

  output logic         dcache_arb_ag_ld_sel,
  output logic         dcache_arb_ag_st_sel,
  output logic [31:0]  dcache_arb_ld_ag_addr,
  output logic         dcache_arb_ld_ag_borrow_addr_vld,
  output logic [31:0]  dcache_arb_st_ag_addr,
  output logic         dcache_arb_st_ag_borrow_addr_vld,

  //==========================================================
  // WMB requests
  //==========================================================
  input  logic         wmb_dcache_arb_ld_req,
  input  logic [7:0]   wmb_dcache_arb_ld_data_gateclk_en,
  input  logic [DATA_INDEX_WIDTH-1:0]  wmb_dcache_arb_ld_data_low_idx,
  input  logic [DATA_INDEX_WIDTH-1:0]  wmb_dcache_arb_ld_data_high_idx,
  input  logic [127:0] wmb_dcache_arb_ld_data_low_din,
  input  logic [127:0] wmb_dcache_arb_ld_data_high_din,
  input  logic [31:0]  wmb_dcache_arb_ld_data_wen,

  input  logic         wmb_dcache_arb_st_req,
  input  logic [4:0]   wmb_dcache_arb_st_dirty_din,
  input  logic         wmb_dcache_arb_st_dirty_req,
  input  logic         wmb_dcache_arb_st_dirty_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  wmb_dcache_arb_st_dirty_idx,
  input  logic [4:0]   wmb_dcache_arb_st_dirty_wen,

  output logic         dcache_arb_wmb_ld_grnt,

  //==========================================================
  // LFB requests
  //==========================================================
  input  logic         lfb_dcache_arb_ld_req,
  input  logic [7:0]   lfb_dcache_arb_ld_data_gateclk_en,
  input  logic [DATA_INDEX_WIDTH-1:0]  lfb_dcache_arb_ld_data_idx,
  input  logic [127:0] lfb_dcache_arb_ld_data_low_din,
  input  logic [127:0] lfb_dcache_arb_ld_data_high_din,
  input  logic [LD_TAG_WIDTH-1:0]  lfb_dcache_arb_ld_tag_din,
  input  logic         lfb_dcache_arb_ld_tag_req,
  input  logic         lfb_dcache_arb_ld_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  lfb_dcache_arb_ld_tag_idx,
  input  logic [1:0]   lfb_dcache_arb_ld_tag_wen,

  input  logic         lfb_dcache_arb_st_req,
  input  logic [ST_TAG_WIDTH-1:0]  lfb_dcache_arb_st_tag_din,
  input  logic         lfb_dcache_arb_st_tag_req,
  input  logic         lfb_dcache_arb_st_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  lfb_dcache_arb_st_tag_idx,
  input  logic [1:0]   lfb_dcache_arb_st_tag_wen,
  input  logic [4:0]   lfb_dcache_arb_st_dirty_din,
  input  logic         lfb_dcache_arb_st_dirty_req,
  input  logic         lfb_dcache_arb_st_dirty_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  lfb_dcache_arb_st_dirty_idx,
  input  logic [4:0]   lfb_dcache_arb_st_dirty_wen,

  output logic         dcache_arb_lfb_ld_grnt,

  //==========================================================
  // VB requests
  //==========================================================
  input  logic         vb_dcache_arb_ld_req,
  input  logic         vb_dcache_arb_ld_borrow_req,
  input  logic         vb_dcache_arb_data_way,
  input  logic [7:0]   vb_dcache_arb_ld_data_gateclk_en,
  input  logic [INDEX_WIDTH:0]  vb_dcache_arb_ld_data_idx,
  input  logic [LD_TAG_WIDTH-1:0]  vb_dcache_arb_ld_tag_din,
  input  logic         vb_dcache_arb_ld_tag_req,
  input  logic         vb_dcache_arb_ld_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  vb_dcache_arb_ld_tag_idx,
  input  logic [1:0]   vb_dcache_arb_ld_tag_wen,

  input  logic         vb_dcache_arb_st_req,
  input  logic         vb_dcache_arb_st_borrow_req,
  input  logic         vb_dcache_arb_st_tag_req,
  input  logic         vb_dcache_arb_st_tag_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  vb_dcache_arb_st_tag_idx,
  input  logic [4:0]   vb_dcache_arb_st_dirty_din,
  input  logic         vb_dcache_arb_st_dirty_req,
  input  logic         vb_dcache_arb_st_dirty_gateclk_en,
  input  logic [INDEX_WIDTH-1:0]  vb_dcache_arb_st_dirty_idx,
  input  logic         vb_dcache_arb_st_dirty_gwen,
  input  logic [4:0]   vb_dcache_arb_st_dirty_wen,
  input  logic [31:0]  vb_dcache_arb_borrow_addr,

  output logic         dcache_arb_vb_ld_grnt,
  output logic         dcache_arb_vb_st_grnt,
  output logic         dcache_arb_ld_dc_borrow_vld,
  output logic         dcache_arb_ld_dc_settle_way,
  output logic         dcache_arb_st_dc_borrow_vld,

  //==========================================================
  // Dcache array interfaces
  //==========================================================
  output logic         lsu_dcache_ld_tag_sel_b,
  output logic         lsu_dcache_ld_tag_gwen_b,
  output logic [1:0]   lsu_dcache_ld_tag_wen_b,
  output logic         lsu_dcache_ld_tag_gateclk_en,
  output logic [INDEX_WIDTH-1:0]  lsu_dcache_ld_tag_idx,
  output logic [LD_TAG_WIDTH-1:0]  lsu_dcache_ld_tag_din,

  output logic         lsu_dcache_st_tag_sel_b,
  output logic         lsu_dcache_st_tag_gwen_b,
  output logic [1:0]   lsu_dcache_st_tag_wen_b,
  output logic         lsu_dcache_st_tag_gateclk_en,
  output logic [INDEX_WIDTH-1:0]  lsu_dcache_st_tag_idx,
  output logic [ST_TAG_WIDTH-1:0]  lsu_dcache_st_tag_din,

  output logic         lsu_dcache_st_dirty_sel_b,
  output logic         lsu_dcache_st_dirty_gwen_b,
  output logic [4:0]   lsu_dcache_st_dirty_wen_b,
  output logic         lsu_dcache_st_dirty_gateclk_en,
  output logic [INDEX_WIDTH-1:0]  lsu_dcache_st_dirty_idx,
  output logic [4:0]   lsu_dcache_st_dirty_din,

  output logic [7:0]   lsu_dcache_ld_data_sel_b,
  output logic [7:0]   lsu_dcache_ld_data_gwen_b,
  output logic [31:0]  lsu_dcache_ld_data_wen_b,
  output logic [7:0]   lsu_dcache_ld_data_gateclk_en,
  output logic [DATA_INDEX_WIDTH-1:0]  lsu_dcache_ld_data_low_idx,
  output logic [DATA_INDEX_WIDTH-1:0]  lsu_dcache_ld_data_high_idx,
  output logic [127:0] lsu_dcache_ld_data_low_din,
  output logic [127:0] lsu_dcache_ld_data_high_din,

  output logic [INDEX_WIDTH-1:0]  dcache_idx,
  output logic         lsu_dcache_ld_xx_gwen,
  output logic [ST_TAG_WIDTH-1:0]  dcache_tag_din,
  output logic         dcache_tag_gwen,
  output logic [1:0]   dcache_tag_wen,
  output logic [4:0]   dcache_dirty_din,
  output logic         dcache_dirty_gwen,
  output logic [4:0]   dcache_dirty_wen
);

//==========================================================
//            Load pipeline arbitration
//==========================================================
// Priority (high to low): LFB > VB > WMB > AG

logic [4:0] dcache_arb_ld_req;
logic [4:0] dcache_arb_ld_sel;
logic dcache_arb_lfb_ld_sel, dcache_arb_vb_ld_sel, dcache_arb_wmb_ld_sel;
logic dcache_arb_vec_ld_sel_unmask, dcache_arb_ag_ld_sel_unmask;
logic dcache_arb_lfb_ld_sel_unmask, dcache_arb_vb_ld_sel_unmask;
logic dcache_arb_wmb_ld_sel_unmask;

// Store pipeline signals (declared here because used in load masking)
logic [4:0] dcache_arb_st_req;
logic [4:0] dcache_arb_st_sel;
logic dcache_arb_lfb_st_sel, dcache_arb_vb_st_sel, dcache_arb_wmb_st_sel;
logic dcache_arb_vec_st_sel_unmask;
logic dcache_arb_lfb_st_sel_unmask, dcache_arb_vb_st_sel_unmask, dcache_arb_ag_st_sel_unmask;
logic dcache_arb_wmb_st_sel_unmask;

// Load priority: LFB > VB > WMB > VEC > AG
assign dcache_arb_ld_req[4:0] = {lfb_dcache_arb_ld_req,
                                 vb_dcache_arb_ld_req,
                                 wmb_dcache_arb_ld_req,
                                 vec_dcache_arb_ld_req,
                                 ag_dcache_arb_ld_tag_req};

always_comb begin
  dcache_arb_ld_sel[4:0] = 5'b0;
  casez(dcache_arb_ld_req[4:0])
    5'b1????:  dcache_arb_ld_sel[4] = 1'b1;  // LFB
    5'b01???:  dcache_arb_ld_sel[3] = 1'b1;  // VB
    5'b001??:  dcache_arb_ld_sel[2] = 1'b1;  // WMB
    5'b0001?:  dcache_arb_ld_sel[1] = 1'b1;  // VEC
    5'b00001:  dcache_arb_ld_sel[0] = 1'b1;  // AG
    default:   dcache_arb_ld_sel[4:0] = 5'b0;
  endcase
end

assign dcache_arb_lfb_ld_sel_unmask = dcache_arb_ld_sel[4];
assign dcache_arb_vb_ld_sel_unmask  = dcache_arb_ld_sel[3];
assign dcache_arb_wmb_ld_sel_unmask = dcache_arb_ld_sel[2];
assign dcache_arb_vec_ld_sel_unmask = dcache_arb_ld_sel[1];
assign dcache_arb_ag_ld_sel_unmask  = dcache_arb_ld_sel[0];
assign dcache_arb_vec_ld_sel        = dcache_arb_vec_ld_sel_unmask;

// Mask if requesting both ld and st but only got one
assign dcache_arb_lfb_ld_sel = dcache_arb_lfb_ld_sel_unmask
                               && (!lfb_dcache_arb_st_req || dcache_arb_lfb_st_sel_unmask);
assign dcache_arb_vb_ld_sel  = dcache_arb_vb_ld_sel_unmask
                               && (!vb_dcache_arb_st_req || dcache_arb_vb_st_sel_unmask);
// WMB 一次写同时要 ld(读行做 merge)+st(置 dirty)，两个 sel 都要给到 (照原版
// ct_lsu_dcache_arb.v:838 / 1142 `wmb_ld_sel = ld_unmask && st_unmask`)。
assign dcache_arb_wmb_ld_sel = dcache_arb_wmb_ld_sel_unmask && dcache_arb_wmb_st_sel_unmask;
assign dcache_arb_ag_ld_sel  = dcache_arb_ag_ld_sel_unmask;

assign dcache_arb_lfb_ld_grnt = dcache_arb_lfb_ld_sel;
assign dcache_arb_vb_ld_grnt  = dcache_arb_vb_ld_sel;
assign dcache_arb_wmb_ld_grnt = dcache_arb_wmb_ld_sel;

//==========================================================
//            Store pipeline arbitration
//==========================================================
// Priority (high to low): LFB > VB > AG > WMB > VEC
// ⚠️ 2026-10-15 修 (coremark_i1 #46462 真凶): 原版 (ct_lsu_dcache_arb.v:1123)
//    `dcache_arb_st_req[5:0] = {..., wmb_dcache_arb_st_req}` —— **WMB 也是 store
//    流水线的一个源**，走同一个优先编码器。本仓把它从编码器里删了 (注释还写成
//    "WMB doesn't use store pipeline")，却仍在下面 dirty 那条 mux 里用**未加选的**
//    `wmb_dcache_arb_st_req` 去 OR `idx`/`din`/`gwen_b`/`sel_b`。
//    后果: WMB 的 dcache 写和 LFB 回填**同拍**时 (回填要写 tag+dirty，WMB 也要写
//    dirty)，dirty 阵列的 idx 变成 `lfb_idx | wmb_idx`、din 变成两者 OR —— 于是
//    **回填那条线的 dirty-valid 位根本没被置起来**，而 tag 阵列 (不受 WMB 影响)
//    的 valid 位却置上了。store 的命中判据看的是 dirty 阵列 (`st_da_dcache_valid0/1
//    = dirty_array[0]/[2]`)，load 的命中判据看的是 tag 阵列 —— 两者不一致 ⇒
//    **该行之后所有 store 都判 miss、绕过 dcache 直写内存**，而后续 load 命中 dcache
//    读到旧值 (症状: load 读回上一笔 store 的值)。
//    实测 T63684: lfb_st=1/wmb_req=1 ⇒ tag idx=24 (对)，dirty idx=24|10=26 (错)。
assign dcache_arb_st_req[4:0] = {lfb_dcache_arb_st_req,
                                 vb_dcache_arb_st_req,
                                 ag_dcache_arb_st_tag_req,
                                 wmb_dcache_arb_st_req,
                                 vec_dcache_arb_st_tag_req};

always_comb begin
  dcache_arb_st_sel[4:0] = 5'b0;
  casez(dcache_arb_st_req[4:0])
    5'b1????:  dcache_arb_st_sel[4] = 1'b1;  // LFB
    5'b01???:  dcache_arb_st_sel[3] = 1'b1;  // VB
    5'b001??:  dcache_arb_st_sel[2] = 1'b1;  // AG
    5'b0001?:  dcache_arb_st_sel[1] = 1'b1;  // WMB
    5'b00001:  dcache_arb_st_sel[0] = 1'b1;  // VEC
    default:   dcache_arb_st_sel[4:0] = 5'b0;
  endcase
end

assign dcache_arb_lfb_st_sel_unmask = dcache_arb_st_sel[4];
assign dcache_arb_vb_st_sel_unmask  = dcache_arb_st_sel[3];
assign dcache_arb_ag_st_sel_unmask  = dcache_arb_st_sel[2];
assign dcache_arb_wmb_st_sel_unmask = dcache_arb_st_sel[1];
assign dcache_arb_vec_st_sel_unmask = dcache_arb_st_sel[0];

// Mask if requesting both ld and st but only got one
assign dcache_arb_lfb_st_sel = dcache_arb_lfb_st_sel_unmask
                               && (!lfb_dcache_arb_ld_req || dcache_arb_lfb_ld_sel_unmask);
assign dcache_arb_vb_st_sel  = dcache_arb_vb_st_sel_unmask
                               && (!vb_dcache_arb_ld_req || dcache_arb_vb_ld_sel_unmask);
assign dcache_arb_ag_st_sel  = dcache_arb_ag_st_sel_unmask;
assign dcache_arb_wmb_st_sel = dcache_arb_wmb_st_sel_unmask
                               && dcache_arb_wmb_ld_sel_unmask;
assign dcache_arb_vec_st_sel = dcache_arb_vec_st_sel_unmask;

assign dcache_arb_vb_st_grnt = dcache_arb_vb_st_sel;

//==========================================================
//            Borrow signals for DC stage
//==========================================================
// VB borrows ld/st pipeline when reading victim data
assign dcache_arb_ld_dc_borrow_vld      = vb_dcache_arb_ld_borrow_req && dcache_arb_vb_ld_sel;

assign dcache_arb_st_dc_borrow_vld      = vb_dcache_arb_st_borrow_req && dcache_arb_vb_st_sel;

assign dcache_arb_ld_ag_addr[31:0]      = vb_dcache_arb_borrow_addr[31:0];
assign dcache_arb_ld_ag_borrow_addr_vld = dcache_arb_ld_dc_borrow_vld;
// ⚠️ 原来无条件接了 `vb_dcache_arb_data_way`. 原版 (ct_lsu_dcache_arb.v:901) 是
//    各 borrow 源按自己的 sel 门控后再 OR。本仓只有 VB 一个 borrow 源。不门控的后果:
//    VB 空闲时这根信号仍是**上一次 VB 残留的 way** ⇒ 普通 AG load 会拿错 way 去
//    "解旋转" `ld_da_data256` (way1 排布 = way0 旋转 16B), 数据整体错位。
assign dcache_arb_ld_dc_settle_way      = dcache_arb_vb_ld_sel && vb_dcache_arb_data_way;
assign dcache_arb_st_ag_addr[31:0]      = vb_dcache_arb_borrow_addr[31:0];
assign dcache_arb_st_ag_borrow_addr_vld = dcache_arb_st_dc_borrow_vld;

//==========================================================
//            Load tag array mux
//==========================================================
assign lsu_dcache_ld_tag_sel_b = !(dcache_arb_lfb_ld_sel || dcache_arb_vb_ld_sel
                                    || dcache_arb_wmb_ld_sel || dcache_arb_vec_ld_sel
                                    || dcache_arb_ag_ld_sel);

assign lsu_dcache_ld_tag_gwen_b = !(dcache_arb_lfb_ld_sel || dcache_arb_vb_ld_sel
                                     || dcache_arb_wmb_ld_sel);

assign lsu_dcache_ld_tag_gateclk_en = lfb_dcache_arb_ld_tag_gateclk_en
                                       || vb_dcache_arb_ld_tag_gateclk_en
                                       || ag_dcache_arb_ld_tag_gateclk_en
                                       || dcache_arb_vec_ld_sel;

assign lsu_dcache_ld_tag_idx = ({INDEX_WIDTH{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_vb_ld_sel}} & vb_dcache_arb_ld_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_vec_ld_sel}} & vec_dcache_arb_ld_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_ag_ld_sel}} & ag_dcache_arb_ld_tag_idx);

assign lsu_dcache_ld_tag_din = ({LD_TAG_WIDTH{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_tag_din)
                                | ({LD_TAG_WIDTH{dcache_arb_vb_ld_sel}} & vb_dcache_arb_ld_tag_din);

// ⚠️ 原来把 `~` 推进了每一项 (逐路取反后 OR) ⇒ 两路都没被选中时结果是 `2'b00`,
//    而 tag 数组的 wen_b 是**按路低有效**(`tag_wen_b_all = {way1,way0}`) ⇒ `2'b00`
//    恰好 = **两路都写**。WMB 来查 dcache tag 时 (`dcache_arb_wmb_ld_sel=1`) 会把
//    `ld_tag_gwen_b` 拉成 0 (写允许), 于是 arb 拿残留的 wen_b=00 + din=0 **把整条
//    tag 条目(含 valid)写成 0** ⇒ 刚被 LFB 回填好的行立刻失效 ⇒ 后续 load 全 miss。
//    原版 (ct_lsu_dcache_arb.v:971/976) 是先 OR 出正 `wen` 再整体取反, 无源选中时
//    `wen=0 ⇒ wen_b=2'b11` (谁都不写)。同 bc29663 给 dirty 数组修的正是一类错。
assign lsu_dcache_ld_tag_wen_b = ~( ({2{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_tag_wen)
                                  | ({2{dcache_arb_vb_ld_sel}}  & vb_dcache_arb_ld_tag_wen) );

//==========================================================
//            Store tag array mux
//==========================================================
assign lsu_dcache_st_tag_sel_b = !(dcache_arb_lfb_st_sel || dcache_arb_vb_st_sel
                                    || dcache_arb_ag_st_sel || dcache_arb_wmb_st_sel
                                    || dcache_arb_vec_st_sel);

assign lsu_dcache_st_tag_gwen_b = !(dcache_arb_lfb_st_sel);

assign lsu_dcache_st_tag_gateclk_en = lfb_dcache_arb_st_tag_gateclk_en
                                       || vb_dcache_arb_st_tag_gateclk_en
                                       || ag_dcache_arb_st_tag_gateclk_en
                                       || dcache_arb_vec_st_sel;

assign lsu_dcache_st_tag_idx = ({INDEX_WIDTH{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_vb_st_sel}} & vb_dcache_arb_st_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_vec_st_sel}} & vec_dcache_arb_st_tag_idx)
                                | ({INDEX_WIDTH{dcache_arb_ag_st_sel}} & ag_dcache_arb_st_tag_idx);

assign lsu_dcache_st_tag_din = ({ST_TAG_WIDTH{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_tag_din);

// 同 ld_tag_wen_b: 逐项取反 OR ⇒ 无源选中时 2'b00 (=两队都写)。这里目前被
// `st_tag_gwen_b = !lfb_st_sel` 挡着(lfb 不选就不开写), 属潜伏同类错, 一并照原版改。
assign lsu_dcache_st_tag_wen_b = ~( ({2{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_tag_wen) );

assign dcache_tag_din  = lsu_dcache_st_tag_din;
assign dcache_tag_gwen = ~lsu_dcache_st_tag_gwen_b;
assign dcache_tag_wen  = ~lsu_dcache_st_tag_wen_b;

//==========================================================
//            Dirty array mux
//==========================================================
logic vb_dirty_gwen;
assign vb_dirty_gwen = vb_dcache_arb_st_dirty_gwen && dcache_arb_vb_st_sel;

// ⚠️ 2026-10-15: 这里原来用**未加选**的 `wmb_dcache_arb_st_req`。WMB 现在进了
//    上面的 store 优先编码器 ⇒ 必须改用加选后的 `dcache_arb_wmb_st_sel`，否则
//    WMB 只要"在请求"就会和 LFB/VB/AG 选中的那路抢 idx/din (见上面的长注释)。
assign lsu_dcache_st_dirty_sel_b = !(dcache_arb_lfb_st_sel || dcache_arb_vb_st_sel
                                      || dcache_arb_ag_st_sel || dcache_arb_wmb_st_sel
                                      || dcache_arb_vec_st_sel);

assign lsu_dcache_st_dirty_gwen_b = !(dcache_arb_lfb_st_sel || vb_dirty_gwen
                                       || dcache_arb_wmb_st_sel);

assign lsu_dcache_st_dirty_gateclk_en = lfb_dcache_arb_st_dirty_gateclk_en
                                         || vb_dcache_arb_st_dirty_gateclk_en
                                         || ag_dcache_arb_st_dirty_gateclk_en
                                         || wmb_dcache_arb_st_dirty_gateclk_en
                                         || dcache_arb_vec_st_sel;

assign lsu_dcache_st_dirty_idx = ({INDEX_WIDTH{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_dirty_idx)
                                  | ({INDEX_WIDTH{dcache_arb_vb_st_sel}} & vb_dcache_arb_st_dirty_idx)
                                  | ({INDEX_WIDTH{dcache_arb_ag_st_sel}} & ag_dcache_arb_st_dirty_idx)
                                  | ({INDEX_WIDTH{dcache_arb_wmb_st_sel}} & wmb_dcache_arb_st_dirty_idx)
                                  | ({INDEX_WIDTH{dcache_arb_vec_st_sel}} & vec_dcache_arb_st_dirty_idx);


assign lsu_dcache_st_dirty_din = ({5{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_dirty_din)
                                  | ({5{dcache_arb_vb_st_sel}} & vb_dcache_arb_st_dirty_din)
                                  | ({5{dcache_arb_wmb_st_sel}} & wmb_dcache_arb_st_dirty_din);


// ⚠️ 原来末尾硬写了 `| 5'h1F` ⇒ wen_b 恒 = 1 ⇒ `dcache_dirty_wen = ~wen_b` 恒 = 0
//    ⇒ **dcache 的 dirty 数组一次都没被写过** ⇒ 填线后 valid 位永远不置 1 ⇒
//    store 的 `st_da_dcache_valid` 恒判"线不在 dcache" ⇒ store 全走写内存、
//    dcache 永远不反映 store ⇒ 后续 load 命中老线读到旧值。
//    另外原来把 `~` 写进了每一项 (`{sel} & ~src_wen` 再 OR): 未获授权那路
//    (比如 WMB 在 req 但没被选中、wen=0) 会贡献一堆 1, 同样会把使能压成 0。
//    原版语义 (ct_lsu_dcache_arb.v): 各路**正 wen** 按选中屏蔽后 OR, 最后整体取反。
assign lsu_dcache_st_dirty_wen_b = ~( ({5{dcache_arb_lfb_st_sel}} & lfb_dcache_arb_st_dirty_wen)
                                    | ({5{dcache_arb_vb_st_sel}}  & vb_dcache_arb_st_dirty_wen)
                                    | ({5{dcache_arb_wmb_st_sel}} & wmb_dcache_arb_st_dirty_wen) );

assign dcache_dirty_din  = lsu_dcache_st_dirty_din;
assign dcache_dirty_gwen = ~lsu_dcache_st_dirty_gwen_b;
assign dcache_dirty_wen  = ~lsu_dcache_st_dirty_wen_b;

//==========================================================
//            Data array mux
//==========================================================
// ⚠️ 2026-10-14 修复 (coremark_i1 第 1689 条失配的真凶):
//    `sel_b` 接的是数据阵列 SRAM 的 **CEN** (片选, 低有效) —— CEN=1 那一拍的**写被整个丢掉**
//    (见 ct_spsram_32x32.sv: `if (!CEN && !GWEN) ... mem_q[A][i] <= D[i]`; 读是无条件同步读,
//     所以 CEN 只影响写 ⇒ 症状是"数据没写进去", 不是"读出来全错")。
//    原来写成 `{8{~(lfb||vb||wmb)}} || ag_dcache_arb_ld_data_req`: LFB (miss 回填) 选中时
//    上式塌成 `ag_dcache_arb_ld_data_req` —— 那是**当拍 AG 级那条 load** 要用的 bank。
//    于是"回填正在写 line X" 与 "某条 load 正好在读 bank i" 同拍时, bank i 的 CEN=1 ⇒
//    **回填把那个字整块漏掉**, 阵列里保持旧值(复位清 0) ⇒ 之后命中该行的 load 读到 0。
//    实测: coremark_i1 T2174 回填 0xf940 行 (low_din=...01082424 完全正确), 但
//    `sel_b=01` (AG 那条 load 要 bank0) ⇒ 0xf940 那个字没写进去, 保持 0;
//    T2669 `lh a5,0(a0)`@0xf940 命中该行读出 0 ⇒ 第 1689 条失配。
//    原版 (ct_lsu_dcache_arb.v:995-1003) 是**按选中源**取 req:
//      lsu_dcache_ld_data_sel_b = ~dcache_arb_ld_data_req, 其中
//      dcache_arb_ld_data_req = {8{lfb_sel}}&8'hff | {8{wmb_sel}}&wmb_req | {8{ag_sel}}&ag_req ...
//    这里照原版口径改回: LFB/VB/WMB 占口时**整行 8 个 bank 全使能**(逐字节掩码由 WEN 负责);
//    只有 AG 独占用口时才只使能它自己要的 bank。
assign lsu_dcache_ld_data_sel_b = ~( {8{dcache_arb_lfb_ld_sel || dcache_arb_vb_ld_sel
                                        || dcache_arb_wmb_ld_sel}}
                                   | ({8{dcache_arb_ag_ld_sel}} & ag_dcache_arb_ld_data_req)
                                   | ({8{dcache_arb_vec_ld_sel}} & vec_dcache_arb_ld_data_req) );

assign lsu_dcache_ld_data_gwen_b = {8{!(dcache_arb_lfb_ld_sel || dcache_arb_wmb_ld_sel)}};

assign lsu_dcache_ld_data_gateclk_en = lfb_dcache_arb_ld_data_gateclk_en
                                        | vb_dcache_arb_ld_data_gateclk_en
                                        | wmb_dcache_arb_ld_data_gateclk_en
                                        | ag_dcache_arb_ld_data_gateclk_en
                                        | dcache_arb_vec_ld_sel;

// LFB and VB use single index for all banks
assign lsu_dcache_ld_data_low_idx = ({DATA_INDEX_WIDTH{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_data_idx)
                                     | ({DATA_INDEX_WIDTH{dcache_arb_vb_ld_sel}} & vb_dcache_arb_ld_data_idx)
                                     | ({DATA_INDEX_WIDTH{dcache_arb_wmb_ld_sel}} & wmb_dcache_arb_ld_data_low_idx)
                                     | ({DATA_INDEX_WIDTH{dcache_arb_vec_ld_sel}} & vec_dcache_arb_ld_data_low_idx)
                                     | ({DATA_INDEX_WIDTH{dcache_arb_ag_ld_sel}} & ag_dcache_arb_ld_data_low_idx);

assign lsu_dcache_ld_data_high_idx = ({DATA_INDEX_WIDTH{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_data_idx)
                                      | ({DATA_INDEX_WIDTH{dcache_arb_vb_ld_sel}} & vb_dcache_arb_ld_data_idx)
                                      | ({DATA_INDEX_WIDTH{dcache_arb_wmb_ld_sel}} & wmb_dcache_arb_ld_data_high_idx)
                                      | ({DATA_INDEX_WIDTH{dcache_arb_vec_ld_sel}} & vec_dcache_arb_ld_data_high_idx)
                                      | ({DATA_INDEX_WIDTH{dcache_arb_ag_ld_sel}} & ag_dcache_arb_ld_data_high_idx);

assign lsu_dcache_ld_data_low_din = ({128{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_data_low_din)
                                     | ({128{dcache_arb_wmb_ld_sel}} & wmb_dcache_arb_ld_data_low_din);

assign lsu_dcache_ld_data_high_din = ({128{dcache_arb_lfb_ld_sel}} & lfb_dcache_arb_ld_data_high_din)
                                      | ({128{dcache_arb_wmb_ld_sel}} & wmb_dcache_arb_ld_data_high_din);

assign lsu_dcache_ld_data_wen_b = ({32{dcache_arb_lfb_ld_sel}} & 32'h0)
                                   | ({32{dcache_arb_wmb_ld_sel}} & ~wmb_dcache_arb_ld_data_wen)
                                   | {32{~(dcache_arb_lfb_ld_sel | dcache_arb_wmb_ld_sel)}};

assign lsu_dcache_ld_xx_gwen = ~lsu_dcache_ld_data_gwen_b[0];

// Index for compatibility
assign dcache_idx = lsu_dcache_st_dirty_idx;

endmodule