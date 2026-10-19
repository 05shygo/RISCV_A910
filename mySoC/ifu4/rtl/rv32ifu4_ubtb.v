`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu4_ubtb — 香山式 uBTB (快速 always-taken 路径)
//
// 32 项全相联; 每项 {valid, tag=块 PC[15:4], pos=块内 slot, target[15:0]}。
// 目标只存低 16 位 (SoC 代码在 64 KB 内), 高位由取指 PC 的 [31:16] 还原。
// 只存一个 CFI/块, 命中即 always-taken; 方向/多分支的修正交给 BP2 的 TAGE
// override (与香山 uBTB + S2 的关系一致)。
//
// 读是组合 CAM (BP1 用当前块 PC 比较), 写在退休点; 命中时 target/pos 直接
// 进早预测环。训练只收 taken/JAL/JALR: 条件分支 not-taken 时退休口给的是
// pc+4, 不是目标, 不能拿来分配。
// ===========================================================================
module rv32ifu4_ubtb #(
    parameter ENTRIES = 32,
    parameter TAG_W   = 12,
    parameter IDX_W   = 5
)(
    input  wire         clk,
    input  wire         rst,

    // ---- BP1: 组合读 (当前预测块 PC) ----
    input  wire [ 31:0] rd_pc,
    output wire         hit,
    output wire [  1:0] pos,
    output wire         is_cond,
    output wire [ 15:0] target,

    // ---- 退休点训练 ----
    input  wire         upd_vld,
    input  wire [ 31:0] upd_pc,
    input  wire [ 31:0] upd_target,
    input  wire         upd_taken,
    input  wire         upd_is_cond,
    input  wire         upd_is_jal,
    input  wire         upd_is_jalr
);

reg [ENTRIES-1:0]   vld_q;
reg [TAG_W-1:0]     tag_q [0:ENTRIES-1];
reg [1:0]           pos_q [0:ENTRIES-1];
reg                 cond_q[0:ENTRIES-1];
reg [15:0]          tgt_q [0:ENTRIES-1];
reg [IDX_W-1:0]     rr_q;

wire [TAG_W-1:0] rd_tag = rd_pc[15:4];

wire [ENTRIES-1:0] hit_vec;
genvar gi;
generate
for (gi = 0; gi < ENTRIES; gi = gi + 1) begin : g_cmp
    assign hit_vec[gi] = vld_q[gi] && (tag_q[gi] == rd_tag);
end
endgenerate

// 命中向量是 one-hot。下面不再用 `for + if (hv[i]) x = data[i]` —— 那种写法
// 带优先级语义, 综合出来是 32 级串行 mux, 训练口 u_idx 的 CE 也挂在同一锥上
// (Vivado 的 u_ubtb/tgt_q CE 44 条违例就来自这里)。
//
// 注意: 也不能写成 `reg acc; for (...) acc = acc | ...;` —— Yosys/Vivado 会
// 保留成一条串行 OR 链 (结构分析里仍是 33 级)。这里每个输出 bit 单独做
// unary reduction, 综合工具才能生成平衡树。
genvar gb, gg;
generate
    for (gb = 0; gb < 16; gb = gb + 1) begin : g_tgt
        wire [ENTRIES-1:0] term;
        for (gg = 0; gg < ENTRIES; gg = gg + 1) begin : g_t
            assign term[gg] = tgt_q[gg][gb] & hit_vec[gg];
        end
        assign target[gb] = |term;
    end

    for (gb = 0; gb < 2; gb = gb + 1) begin : g_pos
        wire [ENTRIES-1:0] term;
        for (gg = 0; gg < ENTRIES; gg = gg + 1) begin : g_p
            assign term[gg] = pos_q[gg][gb] & hit_vec[gg];
        end
        assign pos[gb] = |term;
    end
endgenerate

wire [ENTRIES-1:0] cond_term;
generate
    for (gg = 0; gg < ENTRIES; gg = gg + 1) begin : g_cond
        assign cond_term[gg] = cond_q[gg] & hit_vec[gg];
    end
endgenerate

assign hit     = |hit_vec;
assign is_cond = |cond_term;

wire [TAG_W-1:0] u_tag = upd_pc[15:4];
wire [1:0]       u_pos = upd_pc[3:2];
wire             u_is_jump = upd_is_jal | upd_is_jalr;
// 训练口在复位后可能短暂给 X; 不要用 X 的 pc/target 去写 tag 阵列
wire             upd_ok = (^upd_pc !== 1'bx) && (^upd_target !== 1'bx);
wire             u_take = upd_vld && upd_ok && (upd_taken | u_is_jump);

// ---------------------------------------------------------------------------
// [2026-10-19] 训练两级 + one-hot 写 (与 TAGE/IBUF 同一套路)
//   A 拍: 更新字段打拍 (upd_pc/target 不再组合穿到 32 项比较和写口)
//   B 拍: 用寄存器 tag 做命中/替换选择, one-hot 写各表项
// 相邻两笔更新同 tag 时, B 拍读 vld_q/tag_q 时上一笔已在同一个沿写回,
// 无 RAW 丢失 (与 TAGE 两级流水同理).
// ---------------------------------------------------------------------------
reg [TAG_W-1:0] u_tag_q;
reg [1:0]       u_pos_q;
reg             u_cond_q;
reg [15:0]      u_tgt_q;
reg             u_take_q;

always @(posedge clk) begin
    if (rst) begin
        u_tag_q  <= {TAG_W{1'b0}};
        u_pos_q  <= 2'd0;
        u_cond_q <= 1'b0;
        u_tgt_q  <= 16'd0;
        u_take_q <= 1'b0;
    end else begin
        u_tag_q  <= u_tag;
        u_pos_q  <= u_pos;
        u_cond_q <= upd_is_cond;
        u_tgt_q  <= upd_target[15:0];
        u_take_q <= u_take;
    end
end

wire [ENTRIES-1:0] u_hit_vec;
genvar gj;
generate
for (gj = 0; gj < ENTRIES; gj = gj + 1) begin : g_ucmp
    assign u_hit_vec[gj] = vld_q[gj] && (tag_q[gj] == u_tag_q);
end
endgenerate

wire u_hit = |u_hit_vec;
wire [ENTRIES-1:0] free_vec   = ~vld_q;
wire [ENTRIES-1:0] first_free = free_vec & (~free_vec + 1'b1);
wire               has_free   = |free_vec;
wire [ENTRIES-1:0] rr_oh      = {{(ENTRIES-1){1'b0}}, 1'b1} << rr_q;
wire [ENTRIES-1:0] u_wr_oh    = u_hit ? u_hit_vec : (has_free ? first_free : rr_oh);

genvar ge;
generate
for (ge = 0; ge < ENTRIES; ge = ge + 1) begin : g_wr
    always @(posedge clk) begin
        if (rst) begin
            vld_q[ge]  <= 1'b0;
            tag_q[ge]  <= {TAG_W{1'b0}};
            pos_q[ge]  <= 2'd0;
            cond_q[ge] <= 1'b0;
            tgt_q[ge]  <= 16'd0;
        end else if (u_take_q && u_wr_oh[ge]) begin
            vld_q[ge]  <= 1'b1;
            tag_q[ge]  <= u_tag_q;
            pos_q[ge]  <= u_pos_q;
            cond_q[ge] <= u_cond_q;
            tgt_q[ge]  <= u_tgt_q;
        end
    end
end
endgenerate

always @(posedge clk) begin
    if (rst)         rr_q <= {IDX_W{1'b0}};
    else if (u_take_q) rr_q <= rr_q + 1'b1;
end

// synopsys translate_off
integer i;
always @(posedge clk) begin
    if (!rst && (^hit_vec === 1'bx)) begin
        $display("[IFU3-UBTB] ERROR: hit_vec has X rd_pc=%h rd_tag=%h vld=%b",
                 rd_pc, rd_tag, vld_q);
        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (vld_q[i]) begin
                $display("  entry[%0d] tag=%h pos=%h tgt=%h",
                         i, tag_q[i], pos_q[i], tgt_q[i]);
            end
        end
        $fatal;
    end
end
// synopsys translate_on

endmodule
