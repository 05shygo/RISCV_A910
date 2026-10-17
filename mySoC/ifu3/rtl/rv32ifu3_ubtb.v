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

function [1:0] pick_pos;
    input [ENTRIES-1:0] hv;
    integer i;
    begin
        pick_pos = 2'd0;
        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (hv[i]) pick_pos = pos_q[i];
        end
    end
endfunction

function [31:0] pick_tgt;
    input [ENTRIES-1:0] hv;
    integer i;
    begin
        pick_tgt = 32'd0;
        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (hv[i]) pick_tgt = tgt_q[i];
        end
    end
endfunction

function pick_cond;
    input [ENTRIES-1:0] hv;
    integer i;
    begin
        pick_cond = 1'b0;
        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (hv[i]) pick_cond = cond_q[i];
        end
    end
endfunction

function [IDX_W-1:0] pick_idx;
    input [ENTRIES-1:0] hv;
    integer i;
    begin
        pick_idx = {IDX_W{1'b0}};
        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (hv[i]) pick_idx = i[IDX_W-1:0];
        end
    end
endfunction

function [IDX_W-1:0] pick_alloc_idx;
    input [ENTRIES-1:0] vld;
    input [IDX_W-1:0]   rr;
    integer i;
    reg found;
    begin
        pick_alloc_idx = rr;
        found = 1'b0;
        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (!found && !vld[i]) begin
                pick_alloc_idx = i[IDX_W-1:0];
                found = 1'b1;
            end
        end
    end
endfunction

assign hit     = |hit_vec;
assign pos     = pick_pos(hit_vec);
assign is_cond = pick_cond(hit_vec);
assign target  = pick_tgt(hit_vec);

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
wire [IDX_W-1:0] u_idx = u_hit ? pick_idx(u_hit_vec) : pick_alloc_idx(vld_q, rr_q);

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
