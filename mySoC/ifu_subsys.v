`timescale 1ns / 1ps

// ===========================================================================
// ifu_subsys: rv32_ifu_top 的 SoC 集成层
//
// 本 SoC 没有 PCFIFO/ROB/维护器/调试器/LSU 失效通路, 所以把 IFU 顶层里
// 属于后端基础设施的端口全部按"最小正确"接死:
//   - PCFIFO 桩: credit 恒 2'b10 (接 0 会死锁), token 接常量 (IFU 从不回读),
//     create/cancel 输出不接。
//   - iu_ifu_mispred_stall 接 0 (接 1 会死锁)。
//   - BHT 检查由 EX 级驱动, 但默认用 BHT_TRAIN_EN=0 关掉, 见下面的详细说明。
//   - 退休训练 (rtu_ifu_retire*) 仍全接 0: 只影响预测质量, 不影响取指正确性。
//   - 维护/调试/断点/HAD 全接空闲。
// 区域: 整个 64KB 指令空间 [0, 0x10000), {exec, cacheable, bufferable,
// sec, spec_safe} = 5'b11101, 与 golden model 的 MEM_SZ=64KB 一致。
// ===========================================================================
// BHT_TRAIN_EN: BHT 检查/训练总开关。
//
// 核心在 EX 级解析条件分支时回送 {iu_cur_pc, iu_bht_condbr_taken, iu_bht_pred,
// iu_chk_idx}; 快照由 IFU 随指令一起送来 (走 ifu_idu_ib_inst0_chk 旁路, 与指令
// 同序, 不受后端停顿影响 —— 不能用 create* 广播总线, 那条在 IBUF 输入侧对齐,
// 后端一停顿就会与交付的指令错位)。
//
// 打开后的实测收益: 44 个测试全过, 6 个纯分支测试各快 8 拍, start 快 28,
// trap 快 29; coremark 从 13465789 拍降到 10146229 拍 (快 24.7%)。
//
// 这个开关曾经默认关掉, 因为打开后 coremark 在 cycle 2494 difftest 不匹配。
// 根因不在 BHT 通路, 而是 rv32_ifu_ipctrl.v 里一个潜伏的恢复路径 bug:
// L0 的 taken 位是粘滞的, BHT 翻转成 not-taken 后 L0 项仍可能处于武装状态,
// 于是 IF 级按 L0 改向、IP 级译码却发现该分支没跳; 这时 redirect_pc 会落到
// {vpc[31:4]+1,4'b0} (下一个 16B 块), 把本块里还没取过的 slot 整个跳过 ——
// coremark 里 bltu 在 slot1, 0x858/0x85c 就此丢失。以前 BHT 未训练、条件分支
// 的 L0 项从不武装, 这条路径基本走不到, 是更好的预测把它暴露出来的。
// 修复见 rv32_ifu_ipctrl.v 的 l0_in_fragment (加在 redirect_pc 的 select 上)。
module ifu_subsys #(
    parameter ICACHE_EN = 1,       // I-Cache 开关 (关掉走 1 拍 bypass 读)
`ifdef USE_LBUF
    parameter LBUF_EN   = 1,       // 循环缓冲开关 (make LBUF=1)
`else
    parameter LBUF_EN   = 0,       // 循环缓冲开关 (make LBUF=1 打开)
`endif
    parameter BHT_TRAIN_EN = 1     // BHT 检查/训练 (关掉可回到无历史的旧行为)
)(
    input  wire         clk,
    input  wire         rst,              // 高有效

    // ---- IDU 交付 (与 core 取指级) ----
    output wire         idu_inst0_vld,
    output wire [127:0] idu_inst0_data,
    output wire [ 24:0] idu_inst0_chk,    // BHT 检查快照, 与 inst0 同拍同序
    output wire         idu_inst1_vld,
    output wire [127:0] idu_inst1_data,
    output wire [ 24:0] idu_inst1_chk,
    output wire         idu_inst2_vld,
    output wire [127:0] idu_inst2_data,
    output wire [ 24:0] idu_inst2_chk,
    output wire         idu_flush,        // IFU 内部冲刷, 当拍三槽 vld 全 0
    input  wire [  1:0] idu_accept_num,   // 同拍消费的前缀条数, 不得超有效槽数

    // ---- 后端重定向 (1 拍脉冲) ----
    input  wire         iu_chgflw_vld,    // EX 级分支/JAL/JALR 误预测
    input  wire [ 31:0] iu_chgflw_pc,
    input  wire         rtu_flush,        // WB 提交点陷阱/中断/mret
    input  wire         rtu_chgflw_vld,
    input  wire [ 31:0] rtu_chgflw_pc,

    // ---- BHT 检查/训练 (EX 级条件分支解析, 1 拍脉冲) ----
    // 只要有条件分支在 EX 解析就拉高 (不论是否误预测), 方向表靠它训练;
    // 与 iu_chgflw_vld 同拍时, 两者必须属于同一条指令 (VGHR 修复)。
    input  wire         iu_bht_check_vld,
    input  wire [ 31:0] iu_cur_pc,
    input  wire         iu_bht_condbr_taken,
    input  wire         iu_bht_pred,
    input  wire [ 24:0] iu_chk_idx,

    // ---- 调试 ----
    output wire         init_done,

    // ---- BIU 从端 (接 ifu_biu_mem) ----
    output wire         biu_rd_req,
    output wire [ 31:0] biu_rd_addr,
    output wire         biu_rd_id,
    output wire [  1:0] biu_rd_len,
    input  wire         biu_rd_grnt,
    input  wire         biu_rd_data_vld,
    input  wire [127:0] biu_rd_data,
    input  wire         biu_rd_rid,       // 从端回显的事务 ID
    input  wire         biu_rd_last,
    input  wire [  1:0] biu_rd_resp,
    output wire         biu_r_ready
);

rv32_ifu_top #(
    .REGION_COUNT (1),
    .REGION_BASE  (32'h0000_0000),
    .REGION_LIMIT (33'h0_0001_0000),
    .REGION_ATTR  (5'b11101)     // {exec, cacheable, bufferable, sec, spec_safe}
) u_ifu_top (
    .forever_cpuclk          (clk),
    .cpurst_b                (~rst),
    .cp0_yy_clk_en           (1'b1),
    .cp0_ifu_icg_en          (1'b1),
    .pad_yy_icg_scan_en      (1'b0),
    .cp0_ifu_rvbr            (32'h0),
    .ifu_cp0_init_done       (init_done),
    .ifu_yy_xx_no_op         (),
    .cp0_ifu_bht_en          (1'b1),
    .cp0_ifu_btb_en          (1'b1),
    .cp0_ifu_ind_btb_en      (1'b1),
    .cp0_ifu_l0btb_en        (1'b1),
    .cp0_ifu_ras_en          (1'b1),
    .cp0_ifu_lbuf_en         (LBUF_EN),
    .cp0_ifu_icache_en       (ICACHE_EN),
    .cp0_ifu_icache_pref_en  (ICACHE_EN),
    .cp0_ifu_iwpe            (1'b1),
    .cp0_ifu_nsfe            (1'b0),
    .cp0_ifu_insde           (1'b1),
    .cp0_ifu_no_op_req       (1'b0),
    .cp0_yy_priv_mode        (2'b11),
    // 维护: 不用
    .cp0_ifu_maint_vld       (1'b0),
    .ifu_cp0_maint_ready     (),
    .cp0_ifu_maint_op        (2'b00),
    .cp0_ifu_maint_pa        (32'h0),
    .cp0_ifu_maint_pred_mask (8'h0),
    .cp0_ifu_maint_resume_pc (32'h0),
    .ifu_cp0_maint_done      (),
    // 软件读 Cache: 不用
    .cp0_ifu_icache_read_req      (1'b0),
    .ifu_cp0_icache_read_ready    (),
    .cp0_ifu_icache_read_index    (11'h0),
    .cp0_ifu_icache_read_way      (1'b0),
    .cp0_ifu_icache_read_kind     (2'b00),
    .ifu_cp0_icache_read_data_vld (),
    .cp0_ifu_icache_read_data_ready (1'b1),
    .ifu_cp0_icache_read_data     (),
    // IDU 交付
    .ifu_idu_ib_inst0_vld         (idu_inst0_vld),
    .ifu_idu_ib_inst0_data        (idu_inst0_data),
    .ifu_idu_ib_inst0_chk         (idu_inst0_chk),
    .ifu_idu_ib_inst1_vld         (idu_inst1_vld),
    .ifu_idu_ib_inst1_data        (idu_inst1_data),
    .ifu_idu_ib_inst1_chk         (idu_inst1_chk),
    .ifu_idu_ib_inst2_vld         (idu_inst2_vld),
    .ifu_idu_ib_inst2_data        (idu_inst2_data),
    .ifu_idu_ib_inst2_chk         (idu_inst2_chk),
    .ifu_idu_ib_pipedown_gateclk  (),
    .ifu_idu_flush                (idu_flush),
    .idu_ifu_accept_num           (idu_accept_num),
    // PCFIFO 桩: credit 恒 2, token 恒 0, create/cancel 忽略
    .iu_ifu_pcfifo_credit         (2'b10),
    .iu_ifu_pcfifo_alloc0_token   (13'h0),
    .iu_ifu_pcfifo_alloc1_token   (13'h0),
    .ifu_iu_pcfifo_create0_en     (),
    .ifu_iu_pcfifo_create0_gateclk_en (),
    .ifu_iu_pcfifo_create0_cur_pc (),
    .ifu_iu_pcfifo_create0_tar_pc (),
    .ifu_iu_pcfifo_create0_pred_npc (),
    .ifu_iu_pcfifo_create0_cf_type  (),
    .ifu_iu_pcfifo_create0_dst_vld  (),
    .ifu_iu_pcfifo_create0_bht_pred (),
    .ifu_iu_pcfifo_create0_chk_idx  (),
    .ifu_iu_pcfifo_create0_jmp_mispred (),
    .ifu_iu_pcfifo_create1_en     (),
    .ifu_iu_pcfifo_create1_gateclk_en (),
    .ifu_iu_pcfifo_create1_cur_pc (),
    .ifu_iu_pcfifo_create1_tar_pc (),
    .ifu_iu_pcfifo_create1_pred_npc (),
    .ifu_iu_pcfifo_create1_cf_type  (),
    .ifu_iu_pcfifo_create1_dst_vld  (),
    .ifu_iu_pcfifo_create1_bht_pred (),
    .ifu_iu_pcfifo_create1_chk_idx  (),
    .ifu_iu_pcfifo_create1_jmp_mispred (),
    .ifu_iu_pcfifo_cancel_vld     (),
    .ifu_iu_pcfifo_cancel_first_token (),
    // BHT 检查/训练: 由 EX 级驱动, 受 BHT_TRAIN_EN 控制 (token 仍未用)
    .iu_ifu_bht_check_vld         (BHT_TRAIN_EN && iu_bht_check_vld),
    .iu_ifu_check_token           (13'h0),
    .iu_ifu_cur_pc                (iu_cur_pc),
    .iu_ifu_bht_condbr_taken      (iu_bht_condbr_taken),
    .iu_ifu_bht_pred              (iu_bht_pred),
    .iu_ifu_chk_idx               (iu_chk_idx),
    // 重定向
    .iu_ifu_chgflw_vld            (iu_chgflw_vld),
    .iu_ifu_chgflw_pc             (iu_chgflw_pc),
    .iu_ifu_mispred_stall         (1'b0),
    .rtu_ifu_flush                (rtu_flush),
    .rtu_ifu_chgflw_vld           (rtu_chgflw_vld),
    .rtu_ifu_chgflw_pc            (rtu_chgflw_pc),
    .rtu_ifu_dbgon                (1'b0),
    // 退休训练: 本轮全 0 (性能后补)
    .rtu_ifu_retire0_vld          (1'b0),
    .rtu_ifu_retire0_cur_pc       (32'h0),
    .rtu_ifu_retire0_condbr       (1'b0),
    .rtu_ifu_retire0_condbr_taken (1'b0),
    .rtu_ifu_retire0_jmp          (1'b0),
    .rtu_ifu_retire0_chk_idx      (8'h0),
    .rtu_ifu_retire0_load         (1'b0),
    .rtu_ifu_retire0_store        (1'b0),
    .rtu_ifu_retire0_no_spec_hit  (1'b0),
    .rtu_ifu_retire0_no_spec_miss (1'b0),
    .rtu_ifu_retire0_no_spec_mispred (1'b0),
    .rtu_ifu_retire1_vld          (1'b0),
    .rtu_ifu_retire1_cur_pc       (32'h0),
    .rtu_ifu_retire1_condbr       (1'b0),
    .rtu_ifu_retire1_condbr_taken (1'b0),
    .rtu_ifu_retire1_jmp          (1'b0),
    .rtu_ifu_retire1_chk_idx      (8'h0),
    .rtu_ifu_retire1_load         (1'b0),
    .rtu_ifu_retire1_store        (1'b0),
    .rtu_ifu_retire1_no_spec_hit  (1'b0),
    .rtu_ifu_retire1_no_spec_miss (1'b0),
    .rtu_ifu_retire1_no_spec_mispred (1'b0),
    .rtu_ifu_retire2_vld          (1'b0),
    .rtu_ifu_retire2_cur_pc       (32'h0),
    .rtu_ifu_retire2_condbr       (1'b0),
    .rtu_ifu_retire2_condbr_taken (1'b0),
    .rtu_ifu_retire2_jmp          (1'b0),
    .rtu_ifu_retire2_chk_idx      (8'h0),
    .rtu_ifu_retire2_load         (1'b0),
    .rtu_ifu_retire2_store        (1'b0),
    .rtu_ifu_retire2_no_spec_hit  (1'b0),
    .rtu_ifu_retire2_no_spec_miss (1'b0),
    .rtu_ifu_retire2_no_spec_mispred (1'b0),
    .rtu_ifu_retire0_pcall        (1'b0),
    .rtu_ifu_retire0_preturn      (1'b0),
    .rtu_ifu_retire0_inc_pc       (32'h0),
    .rtu_ifu_retire0_next_pc      (32'h0),
    .rtu_ifu_retire0_mispred      (1'b0),
    .rtu_ifu_retire0_jmp_mispred  (1'b0),
    // BIU 主端
    .ifu_biu_rd_req               (biu_rd_req),
    .ifu_biu_rd_req_gate          (),
    .ifu_biu_rd_addr              (biu_rd_addr),
    .ifu_biu_rd_id                (biu_rd_id),
    .ifu_biu_rd_len               (biu_rd_len),
    .ifu_biu_rd_size              (),
    .ifu_biu_rd_burst             (),
    .ifu_biu_rd_cache             (),
    .ifu_biu_rd_prot              (),
    .ifu_biu_rd_domain            (),
    .ifu_biu_rd_snoop             (),
    .ifu_biu_rd_user              (),
    .biu_ifu_rd_grnt              (biu_rd_grnt),
    .biu_ifu_rd_data_vld          (biu_rd_data_vld),
    .biu_ifu_rd_data              (biu_rd_data),
    .biu_ifu_rd_id                (biu_rd_rid),
    .biu_ifu_rd_last              (biu_rd_last),
    .biu_ifu_rd_resp              (biu_rd_resp),
    .ifu_biu_r_ready              (biu_r_ready),
    // LSU 失效: 没有 LSU 一致性问题 (IROM 只读), 接空闲
    .lsu_ifu_icache_inv_vld       (1'b0),
    .ifu_lsu_icache_inv_ready     (),
    .lsu_ifu_icache_inv_all       (1'b0),
    .lsu_ifu_icache_inv_pa        (32'h0),
    .lsu_ifu_icache_inv_resume_pc (32'h0),
    .ifu_lsu_icache_inv_done      (),
    // HAD 调试: 不用
    .had_rtu_xx_jdbreq            (1'b0),
    .had_ifu_pcload               (1'b0),
    .had_ifu_pc                   (32'h0),
    .had_ifu_ir_vld               (1'b0),
    .had_ifu_ir                   (32'h0),
    .ifu_had_cmd_ready            (),
    .had_yy_xx_bkpta_base         (32'h0),
    .had_yy_xx_bkpta_mask         (32'h0),
    .had_ifu_bkpta_en             (1'b0),
    .had_yy_xx_bkptb_base         (32'h0),
    .had_yy_xx_bkptb_mask         (32'h0),
    .had_ifu_bkptb_en             (1'b0),
    .ifu_had_fetch_pc             (),
    .ifu_had_no_inst              (),
    .ifu_had_reset_on             (),
    .ifu_had_quiescent            (),
    // 性能计数: 不用
    .hpcp_ifu_cnt_en              (1'b0),
    .ifu_hpcp_btb_inst            (),
    .ifu_hpcp_btb_mispred         (),
    .ifu_hpcp_frontend_stall      (),
    .ifu_hpcp_icache_access       (),
    .ifu_hpcp_icache_miss         (),
    .ifu_hpcp_way_reissue         (),
    .ifu_hpcp_ipb_launch          (),
    .ifu_hpcp_ipb_demand_hit      (),
    .ifu_hpcp_lbuf_active         (),
    .ifu_hpcp_pcfifo_stall        (),
    .ifu_hpcp_bht_update_drop     (),
    .ifu_hpcp_ras_miss            (),
    .ifu_hpcp_ind_btb_miss        (),
    .ifu_hpcp_bju_mispred         (),
    .ifu_hpcp_id_accept_num       ()
);

endmodule
