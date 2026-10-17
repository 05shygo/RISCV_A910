`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_top — FTQ + 3 级 IFU + (Phase 0) fall-through BPU
//
// 对外端口与 rv32ifu2_top 完全一致, 便于 A910_cpu.sv 用 ifdef 直接替换。
// 复用: rv32ifu2_icache / rv32ifu2_refill / rv32ifu2_spram / ifu_biu_axi /
//       rv32ifu2_ibuf。
// 新写: FTQ、3 级 IFU、BPU (Phase 0 只有 fall-through; Phase 1 起替换成
//       香山式 BTB/TAGE/PHR 的 3 级预测)。
//
// 数据流:
//   BPU --alloc--> FTQ --read--> IFU S0/S1/S2 --push--> IBUF --3 lane--> IDU
//   ICache 行读由 IFU S0 驱动; refill 由 S0 的 miss 触发。
// ===========================================================================
module rv32ifu3_top #(
    parameter ICACHE_EN = 1,
    parameter BP_EN     = 1,     // Phase 1: BTB + base direction; 0 = fall-through
`ifdef IFU3_BTB_ROW_AW
    parameter BTB_AW    = `IFU3_BTB_ROW_AW,   // 64/128/256 行 = 6/7/8
`else
    parameter BTB_AW    = 6,
`endif
`ifdef IFU3_TAGE_L0
    parameter [4:0] TAGE_L0 = `IFU3_TAGE_L0,
    parameter [4:0] TAGE_L1 = `IFU3_TAGE_L1,
    parameter [4:0] TAGE_L2 = `IFU3_TAGE_L2,
    parameter [4:0] TAGE_L3 = `IFU3_TAGE_L3,
`else
    parameter [4:0] TAGE_L0 = 5'd5,
    parameter [4:0] TAGE_L1 = 5'd10,
    parameter [4:0] TAGE_L2 = 5'd15,
    parameter [4:0] TAGE_L3 = 5'd16,
`endif
`ifdef ICACHE_BYTES
    parameter IC_BYTES  = `ICACHE_BYTES,
`else
    parameter IC_BYTES  = 1024,
`endif
`ifdef ICACHE_LINE_BYTES
    parameter IC_LINE   = `ICACHE_LINE_BYTES,
`else
    parameter IC_LINE   = 16,
`endif
    parameter IC_WAYS   = 2,
`ifdef ICACHE_REPL
    parameter IC_REPL   = `ICACHE_REPL,
`else
    parameter IC_REPL   = 0,
`endif
    parameter FTQ_DEPTH  = 16,
    parameter META_DEPTH = 64,
    parameter META_W     = 64,
    parameter _param_list_sentinel = 1'b0
)(
    input  wire         clk,
    input  wire         rst,              // 高有效

    // ---- IDU 交付 ----
    output wire         idu_inst0_vld,
    output wire [127:0] idu_inst0_data,
    output wire [ 24:0] idu_inst0_chk,
    output wire         idu_inst1_vld,
    output wire [127:0] idu_inst1_data,
    output wire [ 24:0] idu_inst1_chk,
    output wire         idu_inst2_vld,
    output wire [127:0] idu_inst2_data,
    output wire [ 24:0] idu_inst2_chk,
    output wire         idu_flush,        // 本模块内部冲刷, 当拍三槽 vld 全 0
    input  wire [  1:0] idu_accept_num,   // 同拍消费的前缀条数

    // ---- 后端重定向 (1 拍脉冲) ----
    input  wire         iu_chgflw_vld,
    input  wire [ 31:0] iu_chgflw_pc,
    input  wire         rtu_flush,
    input  wire         rtu_chgflw_vld,
    input  wire [ 31:0] rtu_chgflw_pc,

    // ---- 退休点训练 (Phase 1 起使用; Phase 0 忽略) ----
    input  wire         rtu_train_vld,
    input  wire [ 31:0] rtu_train_pc,
    input  wire [ 31:0] rtu_train_target,
    input  wire [ 24:0] rtu_train_chk,
    input  wire         rtu_train_taken,
    input  wire         rtu_train_is_cond,
    input  wire         rtu_train_is_jal,
    input  wire         rtu_train_is_jalr,
    // EX 重定向当拍的 PHR/RAS 修复信息 (Phase 1 起使用)
    input  wire [ 24:0] iu_btb_chk,
    input  wire [ 31:0] iu_btb_pc,       // 分支自己的 PC (PHR hash 精确重算)
    input  wire         iu_btb_taken,
    input  wire         iu_btb_is_cond,

    // ---- 状态 ----
    output wire         init_done,

    // ---- BIU 主端 ----
    output wire         biu_rd_req,
    output wire [ 31:0] biu_rd_addr,
    output wire         biu_rd_id,
    output wire [  1:0] biu_rd_len,
    input  wire         biu_rd_grnt,
    input  wire         biu_rd_data_vld,
    input  wire [127:0] biu_rd_data,
    input  wire         biu_rd_rid,
    input  wire         biu_rd_last,
    input  wire [  1:0] biu_rd_resp,
    output wire         biu_r_ready
);

// ---------------------------------------------------------------------------
// 重定向 (与 ifu2 同口径): RTU 优先, IU 可选打一拍
// ---------------------------------------------------------------------------
`ifdef REDIRECT_PIPE
reg         iu_red_vld_q;
reg [ 31:0] iu_red_pc_q;
// chk/taken/is_cond/分支 PC 必须和 redirect 一起打拍: 它们是 EX 当拍的信号,
// 晚一拍再采会拿到**下一条**指令的快照。
reg [ 24:0] iu_btb_chk_q;
reg [ 31:0] iu_btb_pc_q;
reg         iu_btb_taken_q;
reg         iu_btb_is_cond_q;
always @(posedge clk) begin
    if (rst) begin
        iu_red_vld_q      <= 1'b0;
        iu_red_pc_q       <= 32'd0;
        iu_btb_chk_q      <= 25'd0;
        iu_btb_pc_q       <= 32'd0;
        iu_btb_taken_q    <= 1'b0;
        iu_btb_is_cond_q  <= 1'b0;
    end else begin
        iu_red_vld_q      <= iu_chgflw_vld;
        iu_red_pc_q       <= iu_chgflw_pc;
        iu_btb_chk_q      <= iu_btb_chk;
        iu_btb_pc_q       <= iu_btb_pc;
        iu_btb_taken_q    <= iu_btb_taken;
        iu_btb_is_cond_q  <= iu_btb_is_cond;
    end
end
wire        iu_red_vld = iu_red_vld_q;
wire [31:0] iu_red_pc  = iu_red_pc_q;
wire [24:0] iu_btb_chk_r     = iu_btb_chk_q;
wire [31:0] iu_btb_pc_r      = iu_btb_pc_q;
wire        iu_btb_taken_r   = iu_btb_taken_q;
wire        iu_btb_is_cond_r = iu_btb_is_cond_q;
`else
wire        iu_red_vld = iu_chgflw_vld;
wire [31:0] iu_red_pc  = iu_chgflw_pc;
wire [24:0] iu_btb_chk_r     = iu_btb_chk;
wire [31:0] iu_btb_pc_r      = iu_btb_pc;
wire        iu_btb_taken_r   = iu_btb_taken;
wire        iu_btb_is_cond_r = iu_btb_is_cond;
`endif

// ICache 状态先声明: redirect 在初始化完成前一律屏蔽 —— A910 的 BEU/RTU
// 在复位后前几拍可能给出 X 的 iu_chgflw/rtu_chgflw, 若直接进 BPU 的 pc_q,
// 会把整个前端永久污染成 X。初始化期间核不可能有真实重定向, 屏蔽是安全的。
wire         ic_init_done;
wire         redirect_raw = rtu_chgflw_vld | rtu_flush | iu_red_vld;
wire [ 31:0] redirect_pc_raw = (rtu_chgflw_vld | rtu_flush) ? rtu_chgflw_pc : iu_red_pc;
// A910 的 BEU/RTU 在复位后前几拍可能给出 X 的目标; X 的重定向不能进前端,
// 否则 BPU/FTQ/ICache 的 PC 会被永久污染成 X。初始化期间核不可能有真实重定向。
wire         redirect_pc_ok = (^redirect_pc_raw !== 1'bx);
wire         redirect     = redirect_raw & ic_init_done & redirect_pc_ok;
wire [ 31:0] redirect_pc  = redirect_pc_ok ? redirect_pc_raw : 32'd0;
wire         redirect_rtu = rtu_chgflw_vld | rtu_flush;

assign idu_flush = redirect;

// ---------------------------------------------------------------------------
// ICache / refill
// ---------------------------------------------------------------------------
wire [ 31:0] ifu_ic_rd_addr;
wire         ifu_ic_req_active;
wire [ 31:0] ic_q_pc;
wire [127:0] ic_q_data;
wire         ic_q_hit;

wire         refill_en;
wire [ 31:0] refill_pc;
wire [127:0] refill_data;
wire         refill_busy;
wire         refill_req;

assign refill_req = ifu_ic_req_active & ~ic_q_hit & ~refill_busy &
                    ic_init_done & ~redirect;

rv32ifu2_icache #(
    .IC_BYTES  (IC_BYTES),
    .IC_LINE   (IC_LINE),
    .IC_WAYS   (IC_WAYS),
    .ICACHE_EN (ICACHE_EN),
    .IC_REPL   (IC_REPL)
) u_icache (
    .clk         (clk),
    .rst         (rst),
    .rd_addr     (ifu_ic_rd_addr),
    .q_pc        (ic_q_pc),
    .q_data      (ic_q_data),
    .q_hit       (ic_q_hit),
    .refill_en   (refill_en),
    .refill_pc   (refill_pc),
    .refill_data (refill_data),
    .init_done   (ic_init_done)
);

rv32ifu2_refill #(
    .IC_LINE (IC_LINE)
) u_refill (
    .clk             (clk),
    .rst             (rst),
    .req             (refill_req),
    .req_pc          (ic_q_pc),
    .busy            (refill_busy),
    .refill_en       (refill_en),
    .refill_pc       (refill_pc),
    .refill_data     (refill_data),
    .biu_rd_req      (biu_rd_req),
    .biu_rd_addr     (biu_rd_addr),
    .biu_rd_id       (biu_rd_id),
    .biu_rd_len      (biu_rd_len),
    .biu_rd_grnt     (biu_rd_grnt),
    .biu_rd_data_vld (biu_rd_data_vld),
    .biu_rd_data     (biu_rd_data),
    .biu_rd_rid      (biu_rd_rid),
    .biu_rd_last     (biu_rd_last),
    .biu_rd_resp     (biu_rd_resp),
    .biu_r_ready     (biu_r_ready)
);

// ---------------------------------------------------------------------------
// FTQ
// ---------------------------------------------------------------------------
wire         ftq_alloc_valid;
wire         ftq_alloc_ready;
wire [ 31:0] ftq_alloc_start_pc;
wire         ftq_alloc_taken;
wire [  1:0] ftq_alloc_taken_slot;
wire [ 31:0] ftq_alloc_target;
wire [  3:0] ftq_alloc_btb_cond;
wire [ 15:0] ftq_alloc_phr;
wire [  5:0] ftq_alloc_meta_id;
wire [META_W-1:0] ftq_alloc_meta_data;

wire         ftq_rd_valid;
wire [ 31:0] ftq_rd_start_pc;
wire         ftq_rd_taken;
wire [  1:0] ftq_rd_taken_slot;
wire [ 31:0] ftq_rd_target;
wire [  3:0] ftq_rd_btb_cond;
wire [ 15:0] ftq_rd_phr;
wire [  5:0] ftq_rd_meta_id;
wire [  2:0] ifu_inflight;
wire         ifu_ftq_finish;

// FTQ 索引 / S2 override
wire [  3:0] ftq_alloc_idx;
wire [  3:0] ftq_rd_ptr;
wire [  3:0] ftq_head_idx;
wire         bpu_ovr_valid;
wire [  3:0] bpu_ovr_idx;
wire         bpu_ovr_taken;
wire [  1:0] bpu_ovr_taken_slot;
wire [ 31:0] bpu_ovr_target;
wire [  3:0] bpu_ovr_btb_cond;
wire [ 15:0] bpu_ovr_phr;

// IFU (PredChecker) 自己发起的 override
wire         ifu_ovr_valid;
wire [  3:0] ifu_ovr_idx;
wire         ifu_ovr_taken;
wire [  1:0] ifu_ovr_taken_slot;
wire [ 31:0] ifu_ovr_target;
wire [  3:0] ifu_ovr_btb_cond;
wire [ 15:0] ifu_ovr_phr;

// 优先级: IFU (真实译码) > BPU (TAGE/BP2)
wire         ftq_ovr_valid = ifu_ovr_valid | bpu_ovr_valid;
wire [  3:0] ftq_ovr_idx   = ifu_ovr_valid ? ifu_ovr_idx : bpu_ovr_idx;
wire         ftq_ovr_taken = ifu_ovr_valid ? ifu_ovr_taken : bpu_ovr_taken;
wire [  1:0] ftq_ovr_taken_slot = ifu_ovr_valid ? ifu_ovr_taken_slot : bpu_ovr_taken_slot;
wire [ 31:0] ftq_ovr_target = ifu_ovr_valid ? ifu_ovr_target : bpu_ovr_target;
wire [  3:0] ftq_ovr_btb_cond = ifu_ovr_valid ? ifu_ovr_btb_cond : bpu_ovr_btb_cond;
wire [ 15:0] ftq_ovr_phr = ifu_ovr_valid ? ifu_ovr_phr : bpu_ovr_phr;

rv32ifu3_ftq #(
    .DEPTH      (FTQ_DEPTH),
    .META_DEPTH (META_DEPTH),
    .META_W     (META_W)
) u_ftq (
    .clk              (clk),
    .rst              (rst),
    .alloc_valid      (ftq_alloc_valid),
    .alloc_ready      (ftq_alloc_ready),
    .alloc_start_pc   (ftq_alloc_start_pc),
    .alloc_taken      (ftq_alloc_taken),
    .alloc_taken_slot (ftq_alloc_taken_slot),
    .alloc_target     (ftq_alloc_target),
    .alloc_btb_cond   (ftq_alloc_btb_cond),
    .alloc_phr        (ftq_alloc_phr),
    .alloc_meta_id    (ftq_alloc_meta_id),
    .alloc_meta_data  (ftq_alloc_meta_data),
    .inflight         (ifu_inflight),
    .rd_valid         (ftq_rd_valid),
    .rd_start_pc      (ftq_rd_start_pc),
    .rd_taken         (ftq_rd_taken),
    .rd_taken_slot    (ftq_rd_taken_slot),
    .rd_target        (ftq_rd_target),
    .rd_btb_cond      (ftq_rd_btb_cond),
    .rd_phr           (ftq_rd_phr),
    .rd_meta_id       (ftq_rd_meta_id),
    .finish           (ifu_ftq_finish),
    .flush            (redirect),
    .ovr_valid        (ftq_ovr_valid),
    .ovr_idx          (ftq_ovr_idx),
    .ovr_taken        (ftq_ovr_taken),
    .ovr_taken_slot   (ftq_ovr_taken_slot),
    .ovr_target       (ftq_ovr_target),
    .ovr_btb_cond     (ftq_ovr_btb_cond),
    .ovr_phr          (ftq_ovr_phr),
    .alloc_idx        (ftq_alloc_idx),
    .rd_ptr           (ftq_rd_ptr),
    .head_idx         (ftq_head_idx)
);

// ---------------------------------------------------------------------------
// BPU (Phase 0: fall-through)
// ---------------------------------------------------------------------------
rv32ifu3_bpu #(
    .BP_EN (BP_EN),
    .BTB_AW(BTB_AW),
    .TAGE_L0(TAGE_L0),
    .TAGE_L1(TAGE_L1),
    .TAGE_L2(TAGE_L2),
    .TAGE_L3(TAGE_L3)
) u_bpu (
    .clk              (clk),
    .rst              (rst),
    .redirect         (redirect),
    .redirect_rtu     (redirect_rtu),
    .redirect_pc      (redirect_pc),
    .iu_btb_chk       (iu_btb_chk_r),
    .iu_btb_pc        (iu_btb_pc_r),
    .iu_btb_taken     (iu_btb_taken_r),
    .iu_btb_is_cond   (iu_btb_is_cond_r),
    .ifu_ovr_valid    (ifu_ovr_valid),
    .ifu_ovr_target   (ifu_ovr_target),
    .ifu_ovr_phr      (ifu_ovr_phr),
    .upd_vld          (rtu_train_vld),
    .upd_pc           (rtu_train_pc),
    .upd_target       (rtu_train_target),
    .upd_taken        (rtu_train_taken),
    .upd_is_cond      (rtu_train_is_cond),
    .upd_is_jal       (rtu_train_is_jal),
    .upd_is_jalr      (rtu_train_is_jalr),
    .upd_chk          (rtu_train_chk),
    .alloc_valid      (ftq_alloc_valid),
    .alloc_ready      (ftq_alloc_ready),
    .alloc_start_pc   (ftq_alloc_start_pc),
    .alloc_taken      (ftq_alloc_taken),
    .alloc_taken_slot (ftq_alloc_taken_slot),
    .alloc_target     (ftq_alloc_target),
    .alloc_btb_cond   (ftq_alloc_btb_cond),
    .alloc_phr        (ftq_alloc_phr),
    .alloc_meta_id    (ftq_alloc_meta_id),
    .alloc_meta_data  (ftq_alloc_meta_data),
    .ftq_alloc_idx    (ftq_alloc_idx),
    .ovr_valid        (bpu_ovr_valid),
    .ovr_idx          (bpu_ovr_idx),
    .ovr_taken        (bpu_ovr_taken),
    .ovr_taken_slot   (bpu_ovr_taken_slot),
    .ovr_target       (bpu_ovr_target),
    .ovr_btb_cond     (bpu_ovr_btb_cond),
    .ovr_phr          (bpu_ovr_phr)
);

// ---------------------------------------------------------------------------
// IFU
// ---------------------------------------------------------------------------
wire [  3:0] ib_push_mask;
wire [152:0] ib_push_data0;
wire [152:0] ib_push_data1;
wire [152:0] ib_push_data2;
wire [152:0] ib_push_data3;
wire [  2:0] ib_push_accept;
wire [  3:0] ib_count;
wire         ib_full;

rv32ifu3_ifu u_ifu (
    .clk              (clk),
    .rst              (rst),
    .ftq_rd_valid     (ftq_rd_valid),
    .ftq_rd_start_pc  (ftq_rd_start_pc),
    .ftq_rd_taken     (ftq_rd_taken),
    .ftq_rd_taken_slot(ftq_rd_taken_slot),
    .ftq_rd_target    (ftq_rd_target),
    .ftq_rd_btb_cond  (ftq_rd_btb_cond),
    .ftq_rd_phr       (ftq_rd_phr),
    .ftq_rd_meta_id   (ftq_rd_meta_id),
    .ftq_rd_ptr       (ftq_rd_ptr),
    .ftq_head_idx     (ftq_head_idx),
    .ftq_inflight     (ifu_inflight),
    .ftq_finish       (ifu_ftq_finish),
    .ovr_valid        (bpu_ovr_valid),
    .ovr_idx          (bpu_ovr_idx),
    .iu_btb_chk       (iu_btb_chk_r),
    .iu_btb_pc        (iu_btb_pc_r),
    .iu_btb_taken     (iu_btb_taken_r),
    .redirect_rtu     (redirect_rtu),
    .rtu_train_vld    (rtu_train_vld),
    .rtu_train_chk    (rtu_train_chk),
    .ifu_ovr_valid    (ifu_ovr_valid),
    .ifu_ovr_idx      (ifu_ovr_idx),
    .ifu_ovr_taken    (ifu_ovr_taken),
    .ifu_ovr_taken_slot(ifu_ovr_taken_slot),
    .ifu_ovr_target   (ifu_ovr_target),
    .ifu_ovr_btb_cond (ifu_ovr_btb_cond),
    .ifu_ovr_phr      (ifu_ovr_phr),
    .ic_rd_addr       (ifu_ic_rd_addr),
    .ic_q_pc          (ic_q_pc),
    .ic_q_data        (ic_q_data),
    .ic_q_hit         (ic_q_hit),
    .ic_req_active    (ifu_ic_req_active),
    .ib_push_mask     (ib_push_mask),
    .ib_push_data0    (ib_push_data0),
    .ib_push_data1    (ib_push_data1),
    .ib_push_data2    (ib_push_data2),
    .ib_push_data3    (ib_push_data3),
    .ib_push_accept   (ib_push_accept),
    .ib_count         (ib_count),
    .redirect         (redirect),
    .redirect_pc      (redirect_pc),
    .init_done        (ic_init_done)
);

// ---------------------------------------------------------------------------
// IBUF (复用 ifu2)
// ---------------------------------------------------------------------------
wire [152:0] ib_out0;
wire [152:0] ib_out1;
wire [152:0] ib_out2;
wire [  2:0] ib_vld;

rv32ifu2_ibuf #(
    .DEPTH (8),
    .W     (153)
) u_ibuf (
    .clk        (clk),
    .rst        (rst),
    .flush      (redirect),
    .push_mask  (ib_push_mask),
    .push_data0 (ib_push_data0),
    .push_data1 (ib_push_data1),
    .push_data2 (ib_push_data2),
    .push_data3 (ib_push_data3),
    .push_accept(ib_push_accept),
    .out_data0  (ib_out0),
    .out_data1  (ib_out1),
    .out_data2  (ib_out2),
    .out_vld    (ib_vld),
    .pop_num    (idu_accept_num),
    .count      (ib_count),
    .full       (ib_full)
);

assign idu_inst0_vld  = ib_vld[0] & ~idu_flush;
assign idu_inst0_data = ib_out0[127:0];
assign idu_inst0_chk  = ib_out0[152:128];
assign idu_inst1_vld  = ib_vld[1] & ~idu_flush;
assign idu_inst1_data = ib_out1[127:0];
assign idu_inst1_chk  = ib_out1[152:128];
assign idu_inst2_vld  = ib_vld[2] & ~idu_flush;
assign idu_inst2_data = ib_out2[127:0];
assign idu_inst2_chk  = ib_out2[152:128];

assign init_done = ic_init_done;

// ---------------------------------------------------------------------------
// A910 TB 兼容别名 (ifu2 的层级探针用这些名字):
//   push_mask / init_all / q_hit / can_push
// 语义说明:
//   * push_mask 在 IFU3 里是"bundle 相对"的掩码 (不是物理 slot), TB 只用
//     `|push_mask` 看有没有推进, 够用。
//   * init_all = ic_init_done (Phase 0 没有 BTB/TAGE 初始化; Phase 1 再合并)。
//   * q_hit 就是 ICache 行命中信号。
//   * can_push = 本拍有推进 (IBUF 掩码非 0)。
// ---------------------------------------------------------------------------
wire [3:0] push_mask = ib_push_mask;
wire       init_all  = ic_init_done;
wire       q_hit     = ic_q_hit;
wire       can_push  = (ib_push_mask != 4'd0);

// Phase 1a 未使用: EX GHR/RAS 修复口 (Phase 1c 接入) + 训练 chk
// synopsys translate_off
wire unused_phase1 = rtu_train_chk[0] ^ iu_btb_chk[0] ^ iu_btb_taken ^
                     iu_btb_is_cond ^ ib_full;
// synopsys translate_on

// IC_LINE 固定 16 B (4 条 4 B 指令); 其他值不支持
// synopsys translate_off
initial begin
    if (IC_LINE != 16) begin
        $display("[IFU3-TOP] ERROR: IC_LINE=%0d, IFU3 只支持 16 B 行", IC_LINE);
        $fatal;
    end
    $display("[IFU3-TOP] FTQ=%0d BP_EN=%0d IC_BYTES=%0d IC_LINE=%0d IC_WAYS=%0d",
             FTQ_DEPTH, BP_EN, IC_BYTES, IC_LINE, IC_WAYS);
end
// synopsys translate_on

endmodule
