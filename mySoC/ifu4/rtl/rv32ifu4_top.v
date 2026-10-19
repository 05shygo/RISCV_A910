`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu4_top — FTQ + 3 级 IFU + (Phase 0) fall-through BPU
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
module rv32ifu4_top #(
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
`ifdef IFU4_UBTB_ENT
    parameter UBTB_ENT = `IFU4_UBTB_ENT,
`else
    parameter UBTB_ENT = 32,
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

    // ---- 后端重定向 (RTU trap/mret; 1 拍脉冲) ----
    input  wire         rtu_flush,
    input  wire         rtu_chgflw_vld,
    input  wire [ 31:0] rtu_chgflw_pc,
    input  wire         rtu_yy_xx_flush,   // RTU 大扫帚 (BVU/IDU 同源)

    // ---- BVU: IDU BIQ 发射口 (在 IFU 边界寄存一拍) ----
    input  wire         biq_sel,
    input  wire [ 6:0]  biq_iid,
    input  wire [ 31:0] biq_src0,
    input  wire [ 31:0] biq_src1,
    input  wire [ 31:0] biq_pc,
    input  wire [ 31:0] biq_npc,
    input  wire         biq_taken,
    input  wire [  7:0] biq_rslt_sel,
    input  wire [ 31:0] biq_br_imme,
    input  wire [ 24:0] biq_chk,
    input  wire         bvu_redirect_in_progress, // RTU 本拍在发 trap/mret
    input  wire         bvu_chgflw_mask,          // RTU 慢路冲刷屏蔽

    // ---- BVU → IFU 本地重定向 / RTU 完成口 / IDU 写回 ----
    output wire         bvu_redirect_vld,
    output wire [ 31:0] bvu_redirect_pc,
    output wire [ 24:0] bvu_btb_chk,
    output wire [ 31:0] bvu_btb_pc,
    output wire         bvu_btb_taken,
    output wire         bvu_btb_is_cond,

    // ---- 退休点训练: {vld, iid} 窄口; 现场从 BPiQ 读 ----
    input  wire         rtu_train_vld,
    input  wire [ 31:0] rtu_train_pc,      // 保留端口 (宽口已不用)
    input  wire [ 31:0] rtu_train_target,
    input  wire [ 24:0] rtu_train_chk,
    input  wire         rtu_train_taken,
    input  wire         rtu_train_is_cond,
    input  wire         rtu_train_is_jal,
    input  wire         rtu_train_is_jalr,
    input  wire [  6:0] rtu_train_iid,

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
// BVU: IDU BIQ 发射口 → 前端本地解析/重定向
//
// ⚠️ BPiQ 的互连必须在**例化之前**声明: 先说后用会让 VCS 生成 1 位隐式线网,
//    宽数据被静默截成 bit0 (这边 iid=1/pc=0 的现场就是它)。
// ---------------------------------------------------------------------------
wire        bvu_bpiq_wr;
wire [ 6:0] bvu_bpiq_iid;
wire [31:0] bvu_bpiq_pc;
wire [15:0] bvu_bpiq_target;
wire        bvu_bpiq_taken;
wire        bvu_bpiq_is_cond;
wire        bvu_bpiq_is_jal;
wire        bvu_bpiq_is_jalr;
wire [24:0] bvu_bpiq_chk;

rv32ifu4_bvu u_bvu (
    .clk                    (clk),
    .rst                    (rst),
    .idu_flush              (rtu_yy_xx_flush),

    .biq_sel                (biq_sel),
    .biq_iid                (biq_iid),
    .biq_src0               (biq_src0),
    .biq_src1               (biq_src1),
    .biq_pc                 (biq_pc),
    .biq_npc                (biq_npc),
    .biq_taken              (biq_taken),
    .biq_rslt_sel           (biq_rslt_sel),
    .biq_br_imme            (biq_br_imme),
    .biq_chk                (biq_chk),

    .redirect_in_progress   (bvu_redirect_in_progress),
    .chgflw_mask            (bvu_chgflw_mask),

    .bvu_redirect_vld       (bvu_redirect_vld),
    .bvu_redirect_pc        (bvu_redirect_pc),
    .bvu_btb_chk            (bvu_btb_chk),
    .bvu_btb_pc             (bvu_btb_pc),
    .bvu_btb_taken          (bvu_btb_taken),
    .bvu_btb_is_cond        (bvu_btb_is_cond),

    .bvu_bpiq_wr            (bvu_bpiq_wr),
    .bvu_bpiq_iid           (bvu_bpiq_iid),
    .bvu_bpiq_pc            (bvu_bpiq_pc),
    .bvu_bpiq_target        (bvu_bpiq_target),
    .bvu_bpiq_taken         (bvu_bpiq_taken),
    .bvu_bpiq_is_cond       (bvu_bpiq_is_cond),
    .bvu_bpiq_is_jal        (bvu_bpiq_is_jal),
    .bvu_bpiq_is_jalr       (bvu_bpiq_is_jalr),
    .bvu_bpiq_chk           (bvu_bpiq_chk)
);

// ---------------------------------------------------------------------------
// BPiQ: BVU 解析点写, RTU 退休点按 iid 读; 训练现场不出 IFU
// ---------------------------------------------------------------------------
wire [31:0] bpiq_rd_pc;
wire [31:0] bpiq_rd_target;
wire        bpiq_rd_taken;
wire        bpiq_rd_is_cond;
wire        bpiq_rd_is_jal;
wire        bpiq_rd_is_jalr;
wire [24:0] bpiq_rd_chk;

rv32ifu4_bpiq u_bpiq (
    .clk        (clk),
    .rst        (rst),
    .wr_en      (bvu_bpiq_wr),
    .wr_iid     (bvu_bpiq_iid),
    .wr_pc      (bvu_bpiq_pc),
    .wr_target  (bvu_bpiq_target),
    .wr_taken   (bvu_bpiq_taken),
    .wr_is_cond (bvu_bpiq_is_cond),
    .wr_is_jal  (bvu_bpiq_is_jal),
    .wr_is_jalr (bvu_bpiq_is_jalr),
    .wr_chk     (bvu_bpiq_chk),
    .rd_iid     (rtu_train_iid),
    .rd_pc      (bpiq_rd_pc),
    .rd_target  (bpiq_rd_target),
    .rd_taken   (bpiq_rd_taken),
    .rd_is_cond (bpiq_rd_is_cond),
    .rd_is_jal  (bpiq_rd_is_jal),
    .rd_is_jalr (bpiq_rd_is_jalr),
    .rd_chk     (bpiq_rd_chk)
);

// ICache 状态先声明: redirect 在初始化完成前一律屏蔽 —— RTU/BVU
// 在复位后前几拍可能给出 X 的目标, 若直接进 BPU 的 pc_q,
// 会把整个前端永久污染成 X。初始化期间核不可能有真实重定向, 屏蔽是安全的。
wire         ic_init_done;
wire         redirect_raw = rtu_chgflw_vld | rtu_flush | bvu_redirect_vld;
wire [ 31:0] redirect_pc_raw = (rtu_chgflw_vld | rtu_flush) ? rtu_chgflw_pc : bvu_redirect_pc;
wire         redirect_pc_ok = (^redirect_pc_raw !== 1'bx);
wire         redirect     = redirect_raw & ic_init_done & redirect_pc_ok;
wire [ 31:0] redirect_pc  = redirect_pc_ok ? redirect_pc_raw : 32'd0;
wire         redirect_rtu = rtu_chgflw_vld | rtu_flush;

assign idu_flush = redirect;

// synopsys translate_off
always @(posedge clk) begin
    if (!rst && $test$plusargs("BPIQ_DBG") && rtu_train_vld)
        $display("[BPIQR] iid=%0d pc=%h tgt=%h tkn=%b chk=%h cond=%b jal=%b jlr=%b",
                 rtu_train_iid, bpiq_rd_pc, bpiq_rd_target, bpiq_rd_taken, bpiq_rd_chk,
                 bpiq_rd_is_cond, bpiq_rd_is_jal, bpiq_rd_is_jalr);
end
// synopsys translate_on

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

// ⚠️ 不用 redirect 门控: 回填是路径无关的 (填一行以后可能用到), 而 redirect
// 来自 BEU, 横跨大半个芯片, 组合进 refill 请求会变成跨模块长路径。
// redirect 当拍的 IFU 状态由各状态机的 redirect 分支清掉, 回填事务本身无害。
assign refill_req = ifu_ic_req_active & ~ic_q_hit & ~refill_busy &
                    ic_init_done;

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
wire [ 15:0] ftq_alloc_target;
wire [ 24:0] ftq_alloc_phr;

wire         ftq_rd_valid;
wire [ 31:0] ftq_rd_start_pc;
wire         ftq_rd_taken;
wire [  1:0] ftq_rd_taken_slot;
wire [ 15:0] ftq_rd_target;
wire [ 24:0] ftq_rd_phr;
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
wire [ 15:0] bpu_ovr_target;
wire [ 24:0] bpu_ovr_phr;

// IFU (PredChecker) 自己发起的 override
wire         ifu_ovr_valid;
wire [  3:0] ifu_ovr_idx;
wire         ifu_ovr_taken;
wire [  1:0] ifu_ovr_taken_slot;
wire [ 31:0] ifu_ovr_target;
wire [ 24:0] ifu_ovr_phr;

// IFU 的 PredChecker 结果已经在 IFU 内部打拍 (S0 计算 -> S1 寄存)。
// 这里直接用 IFU 的寄存器输出, 不再加一级: FTQ override 必须和 IFU 的
// S1/S2 停拍同拍, 否则 S2 finish 被 FTQ 忽略而 IFU 的 inflight 照减,
// 同一个 entry 会被取两次。BPU 重启也同一拍。
// 优先级: IFU (真实译码) > BPU (TAGE/BP2)。
wire         ftq_ovr_valid = ifu_ovr_valid | bpu_ovr_valid;
wire [  3:0] ftq_ovr_idx   = ifu_ovr_valid ? ifu_ovr_idx : bpu_ovr_idx;
wire         ftq_ovr_taken = ifu_ovr_valid ? ifu_ovr_taken : bpu_ovr_taken;
wire [  1:0] ftq_ovr_taken_slot = ifu_ovr_valid ? ifu_ovr_taken_slot : bpu_ovr_taken_slot;
wire [ 15:0] ftq_ovr_target = ifu_ovr_valid ? ifu_ovr_target[15:0] : bpu_ovr_target;
wire [ 24:0] ftq_ovr_phr = ifu_ovr_valid ? ifu_ovr_phr : bpu_ovr_phr;

rv32ifu4_ftq #(
    .DEPTH      (FTQ_DEPTH)
) u_ftq (
    .clk              (clk),
    .rst              (rst),
    .alloc_valid      (ftq_alloc_valid),
    .alloc_ready      (ftq_alloc_ready),
    .alloc_start_pc   (ftq_alloc_start_pc),
    .alloc_taken      (ftq_alloc_taken),
    .alloc_taken_slot (ftq_alloc_taken_slot),
    .alloc_target     (ftq_alloc_target),
    .alloc_phr        (ftq_alloc_phr),
    .inflight         (ifu_inflight),
    .rd_valid         (ftq_rd_valid),
    .rd_start_pc      (ftq_rd_start_pc),
    .rd_taken         (ftq_rd_taken),
    .rd_taken_slot    (ftq_rd_taken_slot),
    .rd_target        (ftq_rd_target),
    .rd_phr           (ftq_rd_phr),
    .finish           (ifu_ftq_finish),
    .flush            (redirect),
    .ovr_valid        (ftq_ovr_valid),
    .ovr_idx          (ftq_ovr_idx),
    .ovr_taken        (ftq_ovr_taken),
    .ovr_taken_slot   (ftq_ovr_taken_slot),
    .ovr_target       (ftq_ovr_target),
    .ovr_phr          (ftq_ovr_phr),
    .alloc_idx        (ftq_alloc_idx),
    .rd_ptr           (ftq_rd_ptr),
    .head_idx         (ftq_head_idx)
);

// ---------------------------------------------------------------------------
// BPU (Phase 0: fall-through)
// ---------------------------------------------------------------------------
rv32ifu4_bpu #(
    .BP_EN (BP_EN),
    .BTB_AW(BTB_AW),
    .TAGE_L0(TAGE_L0),
    .TAGE_L1(TAGE_L1),
    .TAGE_L2(TAGE_L2),
    .TAGE_L3(TAGE_L3),
    .UBTB_ENT(UBTB_ENT)
) u_bpu (
    .clk              (clk),
    .rst              (rst),
    .redirect         (redirect),
    .redirect_rtu     (redirect_rtu),
    .redirect_pc      (redirect_pc),
    .iu_btb_chk       (bvu_btb_chk),
    .iu_btb_pc        (bvu_btb_pc),
    .iu_btb_taken     (bvu_btb_taken),
    .iu_btb_is_cond   (bvu_btb_is_cond),
    .ifu_ovr_valid    (ifu_ovr_valid),
    .ifu_ovr_target   (ifu_ovr_target),
    .ifu_ovr_phr      (ifu_ovr_phr),
    .upd_vld          (rtu_train_vld),
    .upd_pc           (bpiq_rd_pc),
    .upd_target       (bpiq_rd_target),
    .upd_taken        (bpiq_rd_taken),
    .upd_is_cond      (bpiq_rd_is_cond),
    .upd_is_jal       (bpiq_rd_is_jal),
    .upd_is_jalr      (bpiq_rd_is_jalr),
    .upd_chk          (bpiq_rd_chk),
    .alloc_valid      (ftq_alloc_valid),
    .alloc_ready      (ftq_alloc_ready),
    .alloc_start_pc   (ftq_alloc_start_pc),
    .alloc_taken      (ftq_alloc_taken),
    .alloc_taken_slot (ftq_alloc_taken_slot),
    .alloc_target     (ftq_alloc_target),
    .alloc_phr        (ftq_alloc_phr),
    .ftq_alloc_idx    (ftq_alloc_idx),
    .ovr_valid        (bpu_ovr_valid),
    .ovr_idx          (bpu_ovr_idx),
    .ovr_taken        (bpu_ovr_taken),
    .ovr_taken_slot   (bpu_ovr_taken_slot),
    .ovr_target       (bpu_ovr_target),
    .ovr_phr          (bpu_ovr_phr)
);

// ---------------------------------------------------------------------------
// IFU
// ---------------------------------------------------------------------------
wire [  3:0] ib_push_mask;
wire [121:0] ib_push_data0;
wire [121:0] ib_push_data1;
wire [121:0] ib_push_data2;
wire [121:0] ib_push_data3;
wire [  2:0] ib_push_accept;
wire [  3:0] ib_count;
wire         ib_full;

rv32ifu4_ifu u_ifu (
    .clk              (clk),
    .rst              (rst),
    .ftq_rd_valid     (ftq_rd_valid),
    .ftq_rd_start_pc  (ftq_rd_start_pc),
    .ftq_rd_taken     (ftq_rd_taken),
    .ftq_rd_taken_slot(ftq_rd_taken_slot),
    .ftq_rd_target    (ftq_rd_target),
    .ftq_rd_phr       (ftq_rd_phr),
    .ftq_rd_ptr       (ftq_rd_ptr),
    .ftq_head_idx     (ftq_head_idx),
    .ftq_inflight     (ifu_inflight),
    .ftq_finish       (ifu_ftq_finish),
    .ovr_valid        (bpu_ovr_valid),
    .ovr_idx          (bpu_ovr_idx),
    .iu_btb_chk       (bvu_btb_chk),
    .iu_btb_pc        (bvu_btb_pc),
    .iu_btb_taken     (bvu_btb_taken),
    .redirect_rtu     (redirect_rtu),
    .rtu_train_vld    (rtu_train_vld),
    .rtu_train_chk    (25'd0),
    .ifu_ovr_valid    (ifu_ovr_valid),
    .ifu_ovr_idx      (ifu_ovr_idx),
    .ifu_ovr_taken    (ifu_ovr_taken),
    .ifu_ovr_taken_slot(ifu_ovr_taken_slot),
    .ifu_ovr_target   (ifu_ovr_target),
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
wire [121:0] ib_out0;
wire [121:0] ib_out1;
wire [121:0] ib_out2;
wire [  2:0] ib_vld;

rv32ifu2_ibuf #(
    .DEPTH (8),
    .W     (122)
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

// IBUF 内部是 {chk[24:0], pkt[96:0]}; 展开成 A910_cpu 期望的 128 位布局:
//   [122]=pred_taken, [95:0]={npc,pc,inst}; 其余位为 0。
assign idu_inst0_vld  = ib_vld[0] & ~idu_flush;
assign idu_inst0_data = {5'd0, ib_out0[96], 26'd0, ib_out0[95:0]};
assign idu_inst0_chk  = ib_out0[121:97];
assign idu_inst1_vld  = ib_vld[1] & ~idu_flush;
assign idu_inst1_data = {5'd0, ib_out1[96], 26'd0, ib_out1[95:0]};
assign idu_inst1_chk  = ib_out1[121:97];
assign idu_inst2_vld  = ib_vld[2] & ~idu_flush;
assign idu_inst2_data = {5'd0, ib_out2[96], 26'd0, ib_out2[95:0]};
assign idu_inst2_chk  = ib_out2[121:97];

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
wire unused_phase1 = bvu_btb_chk[0] ^ bvu_btb_taken ^
                     bvu_btb_is_cond ^ ib_full;

// 临时: +IFU3_DBG 时打印 FTQ/IFU/override 指针, 用于定位重复交付
always @(posedge clk) begin
    if ($test$plusargs("IFU3_DBG") && !rst) begin
        $display("[IFU3-TOP] t=%0t rdpc=%h rdptr=%0d head=%0d cnt=%0d inf=%0d fin=%b iovr=%b bovr=%b fovr=%b oidx=%0d otgt=%h alloc=%b apc=%h atgt=%h",
                 $time, ftq_rd_start_pc, ftq_rd_ptr, ftq_head_idx, u_ftq.count_q,
                 ifu_inflight, ifu_ftq_finish, ifu_ovr_valid,
                 bpu_ovr_valid, ftq_ovr_valid, ftq_ovr_idx, ftq_ovr_target,
                 ftq_alloc_valid, ftq_alloc_start_pc, ftq_alloc_target);
    end
end
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
