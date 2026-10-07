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
    assign compare_dcwp_hit_idx = compare_dcwp_addr[12:5] == dcache_idx[INDEX_WIDTH-1:0];

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