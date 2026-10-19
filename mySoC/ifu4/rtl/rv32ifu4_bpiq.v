`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu4_bpiq — A76 式分支预测信息队列 (按 iid 索引的精简版)
//
// 目的: 把分支的训练现场 (pc/target/actual-taken/类型/chk) 留在 IFU,
// ROB 只保留 {cmplt, mispred, iid}; 退休训练口缩成 {train_vld, iid}。
//
// 写: BVU 在解析点写入 (iid 唯一: ROB 深度 <= 64, iid 低 6 位在一批在途
//     指令里唯一; 这里用 7 位 iid 的低 6 位做表地址)。
// 读: RTU 在**退休点**发 train_vld + iid, 本模块异步读出记录, 由 BPU 训练口
//     按退休程序序写 BTB/TAGE/uBTB。错误路径上的记录不会被读 (不会退休),
//     之后被新分支覆盖。
// ===========================================================================
module rv32ifu4_bpiq (
    input  wire         clk,
    input  wire         rst,

    // ---- 写: BVU 解析点 ----
    input  wire         wr_en,
    input  wire [ 6:0]  wr_iid,
    input  wire [31:0]  wr_pc,
    input  wire [15:0]  wr_target,
    input  wire         wr_taken,
    input  wire         wr_is_cond,
    input  wire         wr_is_jal,
    input  wire         wr_is_jalr,
    input  wire [24:0]  wr_chk,

    // ---- 读: RTU 退休训练 ----
    input  wire [ 6:0]  rd_iid,
    output wire [31:0]  rd_pc,
    output wire [31:0]  rd_target,
    output wire         rd_taken,
    output wire         rd_is_cond,
    output wire         rd_is_jal,
    output wire         rd_is_jalr,
    output wire [24:0]  rd_chk
);

localparam W = 25 + 32 + 16 + 1 + 3 + 1; // chk, pc, target16, taken, types, rsvd

reg [W-1:0] mem [0:63];

wire [5:0] wa = wr_iid[5:0];
wire [5:0] ra = rd_iid[5:0];

wire [W-1:0] rd_ent = mem[ra];

assign rd_chk     = rd_ent[77:53];
assign rd_pc      = rd_ent[52:21];
assign rd_target  = {rd_pc[31:16], rd_ent[20:5]};
assign rd_taken   = rd_ent[4];
assign rd_is_cond = rd_ent[3];
assign rd_is_jal  = rd_ent[2];
assign rd_is_jalr = rd_ent[1];
// bit0 保留

always @(posedge clk) begin
    if (wr_en)
        mem[wa] <= {wr_chk, wr_pc, wr_target, wr_taken,
                    wr_is_cond, wr_is_jal, wr_is_jalr, 1'b0};
end

// 仿真初值: 只有被写过的表项会被读 (退休分支必先解析), 这里只是避免 X 扩散。
// synopsys translate_off
integer i;
initial begin
    for (i = 0; i < 64; i = i + 1)
        mem[i] = {W{1'b0}};
end
// synopsys translate_on

// synopsys translate_off
always @(posedge clk) begin
    if (!rst && $test$plusargs("BPIQ_DBG") && wr_en)
        $display("[BPIQW] iid=%0d pc=%h tgt=%h tkn=%b chk=%h cond=%b jal=%b jlr=%b",
                 wr_iid, wr_pc, wr_target, wr_taken, wr_chk,
                 wr_is_cond, wr_is_jal, wr_is_jalr);
end
// synopsys translate_on

endmodule
