`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu4_ftq — 取指目标队列 (16 个预测项)
//
// 设计参照香山 FTQ 的最小职责 (见 doc/xiangshan_ifu_bpu_zh.md):
//   * 每个 entry 是一个 16 B 预测块: {startPc, taken, takenSlot, target}
//   * BPU 从 alloc 口写, IFU 从 read 口读; IFU 用 inflight 表示"已取走但还没
//     交付完"的块数, read_idx = head + inflight, 所以 S0 可以领先当前 head
//     预取后面的块, 而 head 只有在 S2 把整块交付完 (finish) 后才前进。
//   * redirect 全清 (Phase 0/1 不做 redirect-entry 保留)。
//   * 目标只存低 16 位 (SoC 代码在 64 KB 内); IFU 用 start_pc[31:16] 还原。
//   * 原 64×64 meta RAM / meta_id / btb_cond 无消费者, Phase 1 删除。
// ===========================================================================
module rv32ifu4_ftq #(
    parameter DEPTH      = 16
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- BPU 分配 (写) ----
    input  wire         alloc_valid,
    output wire         alloc_ready,
    input  wire [ 31:0] alloc_start_pc,
    input  wire         alloc_taken,
    input  wire [  1:0] alloc_taken_slot, // 16 B 块内绝对 slot (0..3)
    input  wire [ 15:0] alloc_target,
    input  wire [ 24:0] alloc_phr,       // 块起始 PHR 快照 (训练用)

    // ---- IFU 读 (读 idx = head + inflight) ----
    input  wire [  2:0] inflight,       // 已取走、未交付完的块数 (0..3)
    output wire         rd_valid,
    output wire [ 31:0] rd_start_pc,
    output wire         rd_taken,
    output wire [  1:0] rd_taken_slot,
    output wire [ 15:0] rd_target,
    output wire [ 24:0] rd_phr,

    // IFU 把当前 head 块完整交付完 (pop)
    input  wire         finish,

    // 重定向: 全清
    input  wire         flush,

    // ---- BPU S2 override: 重写一项并丢弃它之后的所有年轻项 ----
    input  wire         ovr_valid,
    input  wire [  3:0] ovr_idx,          // FTQ=16 固定 4 位 (DEPTH 参数见下)
    input  wire         ovr_taken,
    input  wire [  1:0] ovr_taken_slot,
    input  wire [ 15:0] ovr_target,
    input  wire [ 24:0] ovr_phr,

    // ---- 给 BPU/IFU 的索引 ----
    output wire [  3:0] alloc_idx,
    output wire [  3:0] rd_ptr,
    output wire [  3:0] head_idx
);

localparam AW = $clog2(DEPTH);
localparam CW = AW + 1;

reg [31:0] ent_start_pc  [0:DEPTH-1];
reg        ent_taken     [0:DEPTH-1];
reg [ 1:0] ent_taken_slot[0:DEPTH-1];
reg [15:0] ent_target    [0:DEPTH-1];
reg [24:0] ent_phr       [0:DEPTH-1];

reg [AW-1:0] head_q;
reg [CW-1:0] count_q;

wire [AW-1:0] alloc_ptr = head_q + count_q[AW-1:0];
// inflight 只有 3 位; 不能写 inflight[AW-1:0] (AW=4 时 bit3 越界 => X)
wire [AW-1:0] rd_idx    = head_q + inflight;

wire alloc_fire = alloc_valid && alloc_ready;

assign alloc_ready = (count_q < DEPTH);
assign rd_valid    = (count_q > { {(CW-3){1'b0}}, inflight });

assign rd_start_pc   = ent_start_pc [rd_idx];
assign rd_taken      = ent_taken    [rd_idx];
assign rd_taken_slot = ent_taken_slot[rd_idx];
assign rd_target     = ent_target   [rd_idx];
assign rd_phr        = ent_phr      [rd_idx];

assign alloc_idx = alloc_ptr;
assign rd_ptr    = rd_idx;
assign head_idx  = head_q;

always @(posedge clk) begin
    if (rst) begin
        head_q  <= {AW{1'b0}};
        count_q <= {CW{1'b0}};
    end else if (flush) begin
        head_q  <= {AW{1'b0}};
        count_q <= {CW{1'b0}};
    end else if (ovr_valid) begin
        // 重写被 override 的项; 丢弃它之后的所有年轻项
        ent_taken     [ovr_idx] <= ovr_taken;
        ent_taken_slot[ovr_idx] <= ovr_taken_slot;
        ent_target    [ovr_idx] <= ovr_target;
        ent_phr       [ovr_idx] <= ovr_phr;
        count_q <= {1'b0, (ovr_idx - head_q)} + 1'b1;
    end else begin
        if (alloc_fire) begin
            ent_start_pc  [alloc_ptr] <= alloc_start_pc;
            ent_taken     [alloc_ptr] <= alloc_taken;
            ent_taken_slot[alloc_ptr] <= alloc_taken_slot;
            ent_target    [alloc_ptr] <= alloc_target;
            ent_phr       [alloc_ptr] <= alloc_phr;
        end
        if (finish) begin
            head_q <= head_q + 1'b1;
        end
        case ({alloc_fire, finish})
            2'b10:   count_q <= count_q + 1'b1;
            2'b01:   count_q <= count_q - 1'b1;
            default: count_q <= count_q;
        endcase
    end
end

// synopsys translate_off
always @(posedge clk) begin
    if (!rst && !flush) begin
        if (inflight > count_q) begin
            $display("[IFU3-FTQ] ERROR: inflight=%0d > count=%0d", inflight, count_q);
            $fatal;
        end
        if (finish && (count_q == 0)) begin
            $display("[IFU3-FTQ] ERROR: finish with empty FTQ");
            $fatal;
        end
        if (ovr_valid && ({1'b0, (ovr_idx - head_q)} >= count_q)) begin
            $display("[IFU3-FTQ] ERROR: override idx outside queue (idx=%0d head=%0d cnt=%0d)",
                     ovr_idx, head_q, count_q);
            $fatal;
        end
    end
end
// synopsys translate_on

endmodule
