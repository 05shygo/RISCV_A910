`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu3_ubtb — 香山式 uBTB (快速 always-taken 路径)
//
// 32 项全相联; 每项 {valid, tag=块 PC[15:4], pos=块内 slot, target[31:0]}。
// 只存一个 CFI/块, 命中即 always-taken; 方向/多分支的修正交给 BP2 的 TAGE
// override (与香山 uBTB + S2 的关系一致)。
//
// 读是组合 CAM (BP1 用当前块 PC 比较), 写在退休点; 命中时 target/pos 直接
// 进早预测环。训练只收 taken/JAL/JALR: 条件分支 not-taken 时退休口给的是
// pc+4, 不是目标, 不能拿来分配。
// ===========================================================================
module rv32ifu3_ubtb #(
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
    output wire [ 31:0] target,

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
reg [31:0]          tgt_q [0:ENTRIES-1];
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
    for (gb = 0; gb < 32; gb = gb + 1) begin : g_tgt
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

// one-hot → index。每个 index bit = 一个常量掩码的 unary reduction,
// 没有优先级链; 调用点保证输入 one-hot。
function [IDX_W-1:0] oh_to_idx;
    input [ENTRIES-1:0] oh;
    integer i, b;
    reg [ENTRIES-1:0] mask;
    begin
        for (b = 0; b < IDX_W; b = b + 1) begin
            mask = {ENTRIES{1'b0}};
            for (i = 0; i < ENTRIES; i = i + 1)
                if (((i >> b) & 1) != 0)
                    mask[i] = 1'b1;
            oh_to_idx[b] = |(oh & mask);
        end
    end
endfunction

// 分配: 原来是从 0 开始串行找第一个空项, 找不到才回退 rr_q。
// `free_vec & -free_vec` 直接取出最低位的空闲项 (综合成 CARRY 链/优先级树),
// 语义与"从 0 扫第一个 0"完全一致。rr_q 仍只作为全满时的兜底。
wire [ENTRIES-1:0] free_vec   = ~vld_q;
wire [ENTRIES-1:0] first_free = free_vec & (~free_vec + 1'b1);
wire               has_free   = |free_vec;
wire [IDX_W-1:0]   free_idx   = oh_to_idx(first_free);
wire [IDX_W-1:0]   alloc_idx  = has_free ? free_idx : rr_q;

wire [TAG_W-1:0] u_tag = upd_pc[15:4];
wire [1:0]       u_pos = upd_pc[3:2];
wire             u_is_jump = upd_is_jal | upd_is_jalr;
// 训练口在复位后可能短暂给 X; 不要用 X 的 pc/target 去写 tag 阵列
wire             upd_ok = (^upd_pc !== 1'bx) && (^upd_target !== 1'bx);
wire             u_take = upd_vld && upd_ok && (upd_taken | u_is_jump);

wire [ENTRIES-1:0] u_hit_vec;
genvar gj;
generate
for (gj = 0; gj < ENTRIES; gj = gj + 1) begin : g_ucmp
    assign u_hit_vec[gj] = vld_q[gj] && (tag_q[gj] == u_tag);
end
endgenerate

wire u_hit = |u_hit_vec;
wire [IDX_W-1:0] u_hit_idx = oh_to_idx(u_hit_vec);
wire [IDX_W-1:0] u_idx = u_hit ? u_hit_idx : alloc_idx;

integer i;
always @(posedge clk) begin
    if (rst) begin
        vld_q <= {ENTRIES{1'b0}};
        rr_q  <= {IDX_W{1'b0}};
        for (i = 0; i < ENTRIES; i = i + 1) begin
            tag_q[i] <= {TAG_W{1'b0}};
            pos_q[i] <= 2'd0;
            cond_q[i] <= 1'b0;
            tgt_q[i] <= 32'd0;
        end
    end else if (u_take) begin
        vld_q[u_idx] <= 1'b1;
        tag_q[u_idx] <= u_tag;
        pos_q[u_idx] <= u_pos;
        cond_q[u_idx] <= upd_is_cond;
        tgt_q[u_idx] <= upd_target;
        rr_q <= rr_q + 1'b1;
    end
end

// synopsys translate_off
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
