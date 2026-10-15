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

module lsu_dcache_info_update #(
    parameter int DCACHE_SIZE = 2048,
    parameter int INDEX_WIDTH = (DCACHE_SIZE == 1024) ? 4 : (DCACHE_SIZE == 2048) ? 5 : 6
)(
    input  logic [31:0] compare_dcwp_addr,
    input  logic [4:0]  dcache_dirty_din,
    input  logic        dcache_dirty_gwen,
    input  logic [4:0]  dcache_dirty_wen,
    input  logic [INDEX_WIDTH-1:0]  dcache_idx,
    input  logic [43:0] dcache_tag_din,
    input  logic        dcache_tag_gwen,
    input  logic [1:0]  dcache_tag_wen,
    input  logic        origin_dcache_dirty,
    input  logic        origin_dcache_valid,
    input  logic        origin_dcache_way,

    output logic        compare_dcwp_hit_idx,
    output logic        compare_dcwp_update_vld,
    output logic        update_dcache_dirty,
    output logic        update_dcache_valid,
    output logic        update_dcache_way
);

    //==========================================================
    //                 Internal signals
    //==========================================================
    logic        compare_dcwp_hit_dirty;
    logic [1:0]  compare_dcwp_hit_dirty_din;
    logic [1:0]  compare_dcwp_hit_dirty_wen;
    logic        compare_dcwp_hit_sel;
    logic        compare_dcwp_hit_up_vld;
    logic        compare_dcwp_hit_valid;
    logic        compare_dcwp_miss_dirty;
    logic [1:0]  compare_dcwp_miss_dirty_din;
    logic        compare_dcwp_miss_up_pre;
    logic        compare_dcwp_miss_up_vld;
    logic        compare_dcwp_miss_up_way0;
    logic        compare_dcwp_miss_up_way0_sel;
    logic        compare_dcwp_miss_up_way1;
    logic        compare_dcwp_miss_up_way1_sel;
    logic        compare_dcwp_miss_valid;
    logic [21:0] compare_dcwp_tag;
    logic        update_dcache_dirty_new;
    logic        update_dcache_valid_new;
    logic        update_dcache_way_new;

    //==========================================================
    //        Compare dcache write port index
    //==========================================================
    // ⚠️ 2026-10-15 修 (coremark_i1 #49777 真凶): 原版 (ct_lsu_dcache_info_update.v:113/117)
    //    两边**位宽相同** —— `compare_dcwp_addr[13:6] == dcache_idx[7:0]` (32K) /
    //    `[14:6] == [8:0]` (64K)。本仓移植时把左切片留在"8 位"上 ([12:5]), 而本仓
    //    dcache 是 2KB/32B 线/32 set ⇒ `dcache_idx` 只有 INDEX_WIDTH=5 位
    //    (= addr[9:5], 见 lsu_top `INDEX_LSB=OFFSET_WIDTH=5`)。
    //    8 位 vs 5 位的比较在 Verilog 里会把右操作数**零扩展**成 8 位 ⇒ 判据退化成
    //    `addr[12:10]==0 && addr[9:5]==idx` ⇒ **凡是 addr[12:10]!=0 (即地址 ≥0x2000,
    //    本用例的数据段 0xfxxx 全在里面) 的地址一律判"不是这个 set"**。
    //    后果: 本模块的 `compare_dcwp_miss_up_*` 永远不拉 ⇒ WMB 表项 (和 SQ 表项)
    //    在"store 判 miss、随后该行被 LFB 回填进 dcache"这件事上**永远不更新自己的
    //    `dcache_valid`** ⇒ `wmb_entry_write_biu_req` 一直是 1 ⇒ 这笔 store 被
    //    **直写 DRAM**, 而 dcache 里是回填时读到的**旧值**(且被后面命中的 load 读到)。
    //    实测 (coremark_i1): T67884 LFB 把 0xfa80 行回填进 dcache (数据是旧的 0x0003),
    //    T67878 判 miss 的那笔 store (pc=0xef8, 写 0xfa8c=0x0014) 没能恢复 valid,
    //    T67889 直写 DRAM (SLVW strb=3000 data byte12=0x14) ⇒ DRAM 里是 0x14,
    //    dcache 里还是 0x0003 ⇒ T68520 第二条循环的 load (pc=0xf2c) 命中 dcache 读回 3。
    localparam int INDEX_LSB = 5;                                  // = lsu_top OFFSET_WIDTH (32B 线)
    localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;         // 2KB ⇒ 9
    assign compare_dcwp_hit_idx = compare_dcwp_addr[INDEX_MSB:INDEX_LSB] == dcache_idx[INDEX_WIDTH-1:0];

    //==========================================================
    //        Update if dcache hit
    //==========================================================
    assign compare_dcwp_hit_dirty_din[1:0] = origin_dcache_way
        ? dcache_dirty_din[3:2]
        : dcache_dirty_din[1:0];

    assign compare_dcwp_hit_dirty_wen[1:0] = origin_dcache_way
        ? dcache_dirty_wen[3:2]
        : dcache_dirty_wen[1:0];

    assign compare_dcwp_hit_up_vld = dcache_dirty_gwen
        && origin_dcache_valid
        && compare_dcwp_hit_idx;

    assign compare_dcwp_hit_dirty = compare_dcwp_hit_dirty_wen[1]
        ? compare_dcwp_hit_dirty_din[1]
        : origin_dcache_dirty;

    assign compare_dcwp_hit_valid = compare_dcwp_hit_dirty_wen[0]
        ? compare_dcwp_hit_dirty_din[0]
        : origin_dcache_valid;

    //==========================================================
    //        Update if dcache miss
    //==========================================================
    assign compare_dcwp_miss_up_pre = dcache_tag_gwen
        && !origin_dcache_valid;

    assign compare_dcwp_tag[21:0] = compare_dcwp_addr[31:10];

    assign compare_dcwp_miss_up_way0_sel = dcache_dirty_wen[0]
        && dcache_dirty_din[0]
        && dcache_tag_wen[0]
        && (compare_dcwp_tag[21:0] == dcache_tag_din[21:0]);

    assign compare_dcwp_miss_up_way0 = compare_dcwp_miss_up_pre
        && compare_dcwp_miss_up_way0_sel
        && compare_dcwp_hit_idx;

    assign compare_dcwp_miss_up_way1_sel = dcache_dirty_wen[2]
        && dcache_dirty_din[2]
        && dcache_tag_wen[1]
        && (compare_dcwp_tag[21:0] == dcache_tag_din[43:22]);

    assign compare_dcwp_miss_up_way1 = compare_dcwp_miss_up_pre
        && compare_dcwp_miss_up_way1_sel
        && compare_dcwp_hit_idx;

    assign compare_dcwp_miss_dirty_din[1:0] = compare_dcwp_miss_up_way1_sel
        ? dcache_dirty_din[3:2]
        : dcache_dirty_din[1:0];

    assign compare_dcwp_miss_up_vld = compare_dcwp_miss_up_way0
        || compare_dcwp_miss_up_way1;

    assign compare_dcwp_miss_dirty = compare_dcwp_miss_dirty_din[1];
    assign compare_dcwp_miss_valid = compare_dcwp_miss_dirty_din[0];

    //==========================================================
    //        Select
    //==========================================================
    assign compare_dcwp_update_vld = compare_dcwp_hit_up_vld
        || compare_dcwp_miss_up_vld;

    assign compare_dcwp_hit_sel = origin_dcache_valid;

    assign update_dcache_dirty_new = compare_dcwp_hit_sel
        ? compare_dcwp_hit_dirty
        : compare_dcwp_miss_dirty;

    assign update_dcache_valid_new = compare_dcwp_hit_sel
        ? compare_dcwp_hit_valid
        : compare_dcwp_miss_valid;

    assign update_dcache_way_new = compare_dcwp_hit_sel
        ? origin_dcache_way
        : compare_dcwp_miss_up_way1;

    assign update_dcache_dirty = compare_dcwp_update_vld
        ? update_dcache_dirty_new
        : origin_dcache_dirty;

    assign update_dcache_valid = compare_dcwp_update_vld
        ? update_dcache_valid_new
        : origin_dcache_valid;

    assign update_dcache_way = compare_dcwp_update_vld
        ? update_dcache_way_new
        : origin_dcache_way;

endmodule