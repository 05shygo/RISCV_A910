// SPDX-License-Identifier: Apache-2.0
// RV32 slot adaptation of ct_ifu_l0_btb: 16-entry CAM, per-field entry writes,
// rotating allocation FIFO, ADDRGEN/IBDP write arbitration with ADDRGEN priority,
// counter/return/way information, earliest eligible word and directed invalidation.
// Full tags and targets replace C910's partial tag/high-PC target reconstruction.

//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
// Coding style : CCI500-style Verilog-2001 (see doc/coding_style_zh.md)
// Structure follows cci500_tt.v: generated entry circuits, assign-only
// combinational logic, and enable-only / reset-and-enable register storage.
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Module Declaration
//------------------------------------------------------------------------------
module rv32_ifu_l0_btb (

  // Clock, reset and configuration
  input wire forever_cpuclk,
  input wire cpurst_b,

  // Predictor and pipeline interface
  input  wire        enable,
  input  wire        invalidate,
  input  wire        lookup_vld,
  input  wire [31:0] lookup_pc,
  input  wire        cancel,
  input  wire        ras_valid,
  input  wire [31:0] ras_target,
  output wire        hit,
  output wire [ 3:0] hit_index,
  output wire [ 1:0] hit_slot,
  output wire [ 2:0] hit_type,
  output wire [31:0] target,
  output wire [ 1:0] way_hint,

  // Training interface: ADDRGEN kill is mapped onto directed_inv_vld/mask,
  // IBDP fill onto the update_* group (see the arbitration section below).
  input  wire        update_vld,
  input  wire [31:0] update_pc,
  input  wire [31:0] update_target,
  input  wire [ 2:0] update_type,
  input  wire        update_taken,
  input  wire        update_cnt_lo,
  input  wire        update_ras,
  input  wire [ 1:0] update_way,
  input  wire        directed_inv_vld,
  input  wire [15:0] directed_inv_mask
);

  //------------------------------------------------------------------------------
  // Local parameters
  //------------------------------------------------------------------------------
  // [BP_SHRINK] L0 BTB 项数, 默认 = 原样 16 项。`+define+BP_L0_ENTRIES=n` 覆盖。
`ifdef BP_L0_ENTRIES
  localparam ENTRY_COUNT = `BP_L0_ENTRIES;
`else
  localparam ENTRY_COUNT = 16;
`endif
  localparam SLOT_COUNT  = 4;
  localparam INDEX_WIDTH = 4;
  localparam FIFO_WIDTH  = 16;
  localparam DATA_WIDTH  = 69;  // {kind[2:0], src[31:0], way_pred[1:0], dst[31:0]}
  localparam HIT_WIDTH   = 43;  // {index[3:0], slot[1:0], type[2:0], target[31:0], way[1:0]}

  //------------------------------------------------------------------------------
  // Net declarations
  //------------------------------------------------------------------------------
  genvar entry;
  genvar slot;
  genvar bit_index;
  reg  [FIFO_WIDTH-1:0]  entry_fifo_q;
  wire [FIFO_WIDTH-1:0]  entry_fifo_nxt;
  wire                   entry_fifo_en;
  wire                   lookup_en;
  wire                   update_en;
  wire                   update_match;
  wire                   alloc_vld;
  wire                   update_kill;
  wire                   update_hold;
  wire                   update_fire;
  wire [ENTRY_COUNT-1:0] update_match_vec;
  wire [ENTRY_COUNT-1:0] update_select;
  wire [ENTRY_COUNT-1:0] ibdp_update_entry;
  wire [ENTRY_COUNT-1:0] l0_btb_update_entry;
  wire [ENTRY_COUNT-1:0] entry_invalidate;
  wire [          3:0]   l0_btb_wen;
  wire                   l0_btb_update_vld_bit;
  wire                   update_cnt_bit;
  wire                   l0_btb_update_cnt_bit;
  wire                   l0_btb_update_ras_bit;
  wire [DATA_WIDTH-1:0]  l0_btb_update_data;

  // Per-entry contents, driven by the rv32_ifu_l0_btb_entry instances.
  wire [ENTRY_COUNT-1:0] entry_vld;
  wire [ENTRY_COUNT-1:0] entry_cnt;
  wire [ENTRY_COUNT-1:0] entry_ras;
  wire [          2:0]   entry_kind     [0:ENTRY_COUNT-1];
  wire [          1:0]   entry_way_pred [0:ENTRY_COUNT-1];
  wire [         31:0]   entry_src      [0:ENTRY_COUNT-1];
  wire [         31:0]   entry_dst      [0:ENTRY_COUNT-1];

  wire [ENTRY_COUNT-1:0] entry_rd_hit;
  wire [ENTRY_COUNT-1:0] eligible;
  wire [ENTRY_COUNT-1:0] slot_match        [ 0:SLOT_COUNT-1];
  wire [ SLOT_COUNT-1:0] slot_valid;
  wire [ SLOT_COUNT-1:0] slot_select;
  wire [ENTRY_COUNT-1:0] hit_candidates;
  wire [ENTRY_COUNT-1:0] hit_select;
  wire [         31:0]   entry_target      [0:ENTRY_COUNT-1];
  wire [  HIT_WIDTH-1:0] entry_hit_payload [0:ENTRY_COUNT-1];
  wire [ENTRY_COUNT-1:0] hit_terms         [  0:HIT_WIDTH-1];
  wire [  HIT_WIDTH-1:0] hit_payload;

  //------------------------------------------------------------------------------
  // Common controls
  //------------------------------------------------------------------------------
  assign lookup_en = lookup_vld && enable && !cancel && !invalidate && (lookup_pc[1:0] == 2'b00);
  assign update_en = update_vld && enable && !cancel && !invalidate && (update_pc[1:0] == 2'b00) &&
    (update_target[1:0] == 2'b00) && (update_type >= 3'd1) && (update_type <= 3'd3);
  assign update_match = |update_match_vec;
  // P0-3: 分配加资格 —— 只在方向预测为 taken 时才进表。
  // 未命中且预测 not-taken 的分支 (C910 里对应"没被 l0_btb_br_miss 报上来"的那些)
  // 天然不可能命中: eligible 要求 entry_cnt, 而 cnt 只在 (强 taken | jal/jalr) 时置位。
  // C910 的分配本来也是被 IP 级 miss/mispred 事件驱动的, 不是每条控制转移。
  //
  // 实测 (见 doc/bp_change_log_zh.md §2.3): 废项确实从 16,434 次降到 0,
  // 而且**确实在伤害别的类别** —— branch_bench 类 4 (调用/返回) 的 L0 命中
  // 从 5,372 涨到 7,564 (+41%), 因为它的条目不再被废项冲掉。
  // 但注意: 查询命中率**没有**因此上升 (34.8% → 33.4%)。33% 那个数字的成因是
  // 16 项表的容量, 不是废项搅动 —— 别再把这两件事绑在一起。
  assign alloc_vld = update_en && !update_match && update_taken;

  //------------------------------------------------------------------------------
  // Update intent, following C910's per-entry write semantics
  //------------------------------------------------------------------------------
  // C910 never lowers the counter of an entry that is still present: a hit whose
  // branch is no longer predicted *strongly* taken deletes the entry
  // (l0_btb_not_saturate, ct_ifu_ipdp.v:5850-5855: "bht predict as weak taken,it may
  // cause next branch not taken"), and a hit whose branch is not predicted taken at
  // all is left untouched. Only a reallocation or an invalidation clears it.
  //
  // P0-2: 撤销条件从"预测不跳"改成"弱 taken"。旧写法 (update_kill = ... && !update_taken
  // && update_cnt_armed) 把 C910 的 l0_btb_not_saturate 错认成"预测位为 0", 而
  // not_saturate 的真身是 bht_pre_result == 2'b10, 即【预测 taken 但计数器只有弱】。
  // 后果是整场 kill 只有 135 次 (hold 却有 463,012), 一旦武装几乎不降级 —— taken 位粘滞。
  // A3 决定严格对齐 C910: 去掉 update_cnt_armed 门控, 命中项直接按弱 taken 删。
  //
  // 同 P0-1, C910 的 not_saturate 也带 con_br 限定: 无条件转移没有 BHT 方向,
  // 不该被"弱 taken"删掉 (它的 update_cnt_lo 是个与该 PC 无关的计数器位)。
  assign update_kill = update_en && update_match && update_taken && !update_cnt_lo &&
    (update_type == 3'd1);
  assign update_hold = update_en && update_match && !update_taken;
  // update_fire = "本拍真的要写表"。未命中时只有在分配资格成立时才写 —— 这一条
  // 必须和 alloc_vld 一起改: 写入的目标是 entry_fifo_q 的头项 (见下面的
  // ibdp_update_entry), 而 FIFO 只在 alloc_vld 时推进; 若 update_fire 仍按
  // "未命中就写" 成立, 就会反复覆写同一个头项而不转格 —— 表里会出现重复 PC,
  // 正是 P-4 那颗地雷的触发器 (TB 的"同 PC 重复项"计数器会立刻抓到)。
  assign update_fire = update_en && ((update_match && !update_hold) || alloc_vld);

  // The allocation FIFO advances only on a real allocation, never on a hit update
  // and never on a kill. A global invalidate restarts it at entry 0.
  assign entry_fifo_en  = invalidate || alloc_vld;
  assign entry_fifo_nxt = invalidate ? 16'h0001 : {entry_fifo_q[FIFO_WIDTH-2:0], entry_fifo_q[FIFO_WIDTH-1]};

  always @(posedge forever_cpuclk or negedge cpurst_b) begin : p_entry_fifo
    if (!cpurst_b) begin
      entry_fifo_q <= 16'h0001;
    end else if (entry_fifo_en) begin
      entry_fifo_q <= entry_fifo_nxt;
    end
  end

  //------------------------------------------------------------------------------
  // Write arbitration: the directed invalidation (C910's ADDRGEN operand) wins over
  // the training fill (C910's IBDP operand, ct_ifu_l0_btb.v casez 2'b1?). A kill only
  // enables wen[3] with a zero written into the valid bit, so the entry is deleted
  // with its tag/counter/return/way fields left alone; a fill touches all four fields.
  //------------------------------------------------------------------------------
  // Whether any write happens at all is decided solely by the per-entry select
  // below; wen/vld_bit/data only describe the intent of a write that does fire.
  assign
    l0_btb_wen[3:0] = (directed_inv_vld || update_kill) ? 4'b1000
                                                        : 4'b1111;
  assign l0_btb_update_vld_bit = !(directed_inv_vld || update_kill);
  // P0-1: 条件分支只有【强 taken】(BHT 计数器 2'b11) 才武装。update_taken 是包内的
  // 方向预测位 (bht_pred = counter[1]), 分不出强/弱; update_cnt_lo 是预测当时计数器
  // 的低位 (chk_idx[24]), 两者相与即 counter==2'b11。
  //
  // 对齐 C910: 那条规则带 `con_br` 限定 (ct_ifu_ipdp.v:5856-5862) ——
  //   l0_btb_counter_zero = ... && ipctrl_ipdp_con_br && (bht_pre_result == 2'b11);
  // 它只对【条件分支】生效。无条件转移没有 BHT 方向可言 (C910 分配时用的是另一条
  // 依据: ct_ifu_ibdp.v:2287 `l0_btb_update_cnt_bit = |ibdp_hn_jal[7:0]`), 若也套上
  // BHT 低位, 就等于拿一个与该 PC 无关的计数器位去决定 jal/jalr 要不要武装 ——
  // 实测 (branch_bench class4 调用/返回) 会让 L0 命中从 5372 掉到 0。
  // 所以这里按 type 分开: 条件分支看强 taken, jal/jalr 维持原语义。
  assign update_cnt_bit = update_taken && ((update_type != 3'd1) || update_cnt_lo);
  assign l0_btb_update_cnt_bit = update_cnt_bit;
  assign l0_btb_update_ras_bit = update_ras;
  assign l0_btb_update_data    = {update_type, update_pc, update_way, update_target};

  //------------------------------------------------------------------------------
  // Identical CAM entries: compare, write decode and enabled storage
  //------------------------------------------------------------------------------
  generate
    for (entry = 0; entry < ENTRY_COUNT; entry = entry + 1) begin : g_entry
      localparam [INDEX_WIDTH-1:0] ENTRY_INDEX = entry;
      localparam [ENTRY_COUNT-1:0] LOWER_ENTRIES = (16'h0001 << entry) - 16'h0001;

      // Match against old valid state, even if directed invalidation also fires.
      assign update_match_vec[entry] = entry_vld[entry] && (entry_src[entry] == update_pc);
      // P0-4: 同 PC 多路匹配时取【最低】编号, 与查找 hit_select 一致。
      // 原来取最高编号, 于是"填充/杀项打最高那条、查找与 directed invalidation 打
      // 最低那条" —— 只要表里出现同 PC 重复项, 查找可见的那条就会永远留着旧 target
      // 与陈旧武装位。C910 根本不存在这个仲裁 (命中 one-hot 随包带到 addrgen 再原样
      // 送回来, ct_ifu_addrgen.v:302), P1 会把这条通路换成 one-hot; 在那之前先保证
      // 两条规则同向, 不让它变成正反馈。
      assign
        update_select[entry] = update_match_vec[entry] && !(|(update_match_vec & LOWER_ENTRIES));
      // A hit update lands on the entry that matched; a miss allocates at the
      // FIFO head. C910 carries this select down the pipe instead of re-comparing.
      assign ibdp_update_entry[entry] = update_match ? update_select[entry] : entry_fifo_q[entry];
      assign entry_invalidate[entry] = directed_inv_vld && directed_inv_mask[entry];
      assign l0_btb_update_entry[entry] = entry_invalidate[entry] ||
        (update_fire && ibdp_update_entry[entry]);

      assign entry_rd_hit[entry] = entry_vld[entry] && (entry_src[entry][31:4] == lookup_pc[31:4]);
      assign eligible[entry] = lookup_en && entry_rd_hit[entry] && !entry_invalidate[entry] &&
        (entry_src[entry][3:2] >= lookup_pc[3:2]) && entry_cnt[entry] &&
        (!entry_ras[entry] || ras_valid) && !(|entry_target[entry][1:0]);
      assign hit_candidates[entry] = eligible[entry] && slot_select[entry_src[entry][3:2]];
      // At the earliest word, the lowest entry number wins equal-slot ties.
      assign hit_select[entry] = hit_candidates[entry] && !(|(hit_candidates & LOWER_ENTRIES));
      assign entry_target[entry] = entry_ras[entry] ? ras_target : entry_dst[entry];
      assign entry_hit_payload[entry] = {
        ENTRY_INDEX, entry_src[entry][3:2], entry_kind[entry], entry_target[entry],
        entry_way_pred[entry]
      };

      for (bit_index = 0; bit_index < HIT_WIDTH; bit_index = bit_index + 1) begin : g_hit_bit
        assign
          hit_terms[bit_index][entry] = hit_select[entry] & entry_hit_payload[entry][bit_index];
      end

      rv32_ifu_l0_btb_entry x_entry (
        .forever_cpuclk     (forever_cpuclk    ),
        .cpurst_b           (cpurst_b          ),
        .cp0_ifu_btb_en     (enable            ),
        .cp0_ifu_icg_en     (1'b0              ),
        .cp0_ifu_l0btb_en   (enable            ),
        .cp0_yy_clk_en      (1'b1              ),
        .pad_yy_icg_scan_en (1'b0              ),
        .entry_update       (l0_btb_update_entry[entry]),
        .entry_inv          (invalidate        ),
        .entry_wen          (l0_btb_wen        ),
        .entry_update_vld   (l0_btb_update_vld_bit),
        .entry_update_cnt   (l0_btb_update_cnt_bit),
        .entry_update_ras   (l0_btb_update_ras_bit),
        .entry_update_data  (l0_btb_update_data),
        .entry_vld          (entry_vld[entry]  ),
        .entry_cnt          (entry_cnt[entry]  ),
        .entry_ras          (entry_ras[entry]  ),
        .entry_kind         (entry_kind[entry] ),
        .entry_way_pred     (entry_way_pred[entry]),
        .entry_src          (entry_src[entry]  ),
        .entry_dst          (entry_dst[entry]  )
      );
    end

    // Four replicated word-slot comparators and earliest-slot priority masks.
    for (slot = 0; slot < SLOT_COUNT; slot = slot + 1) begin : g_slot
      localparam [1:0] SLOT_INDEX = slot;
      localparam [SLOT_COUNT-1:0] LOWER_SLOTS = (4'b0001 << slot) - 4'b0001;
      for (entry = 0; entry < ENTRY_COUNT; entry = entry + 1) begin : g_entry_match
        assign slot_match[slot][entry] = eligible[entry] && (entry_src[entry][3:2] == SLOT_INDEX);
      end
      assign slot_valid[slot]  = |slot_match[slot];
      assign slot_select[slot] = slot_valid[slot] && !(|(slot_valid & LOWER_SLOTS));
    end

    for (bit_index = 0; bit_index < HIT_WIDTH; bit_index = bit_index + 1) begin : g_hit_reduce
      assign hit_payload[bit_index] = |hit_terms[bit_index];
    end
  endgenerate

  //------------------------------------------------------------------------------
  // Output assignments
  //------------------------------------------------------------------------------
  assign hit                                               = |hit_select;
  assign {hit_index, hit_slot, hit_type, target, way_hint} = hit_payload;
endmodule
