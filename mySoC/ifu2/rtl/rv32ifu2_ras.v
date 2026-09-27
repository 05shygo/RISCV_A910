`timescale 1ns / 1ps

// ===========================================================================
// rv32ifu2_ras — 返回地址栈
//
// 为什么需要它: 块 BTB 对 `ret` 只能记住**最近一次**看到的目标, 而 ret 的目标
// 随调用深度变化 —— 同一个 ret 指令在不同深度下目标不同, BTB 必然只对一个。
// 实测 branch_bench 类 4 (4 个调用点 + 2 个 ret) 的 jal/jalr 误预测 2,056/4,611,
// 明显偏高, 而这一类本来就该由 RAS 覆盖。
// (原设计的教训同样指向这里: "L1 BTB 真正干的活是 jal/jalr 目标" ——
//  memory cpu-btb-index-conflict §"L1 BTB 真正干的活".)
//
// 推测与修复:
//   压栈/弹栈在 F1 发生 (那里才知道这条指令是什么), 是**推测**的。
//   误预测时用随指令走的 chk 快照把栈指针拨回去。
//
//   ⚠️ 只恢复指针、不恢复内容会**用到错误路径留下的垃圾**: 环境切回来之后
//   栈顶那一格的内容是错误路径压进去的, 而它看起来"有效"。实测这个副作用
//   足以把 RAS 在 CoreMark 上的收益吃成负数 (792,369 → 802,266, +1.25%),
//   尽管它在 branch_bench 上把 jal/jalr 误预测从 2,056 打到 12。
//   所以每一项带一个 valid 位: 压栈时置位, 恢复时把"高于恢复点"的那些格子
//   作废 —— 无法确定内容的格子一律回落到 BTB 的目标, 而不是拿垃圾当真。
//
// ⚠️ 同一个取指包内"先 pop 后 push"的顺序: 这里把本拍所有 pop 做完再统一 push。
//   对真实代码足够 (一拍里既有 ret 又有 call 且顺序敏感的情况极少), 但不声称
//   与逐条严格等价。
// ===========================================================================
module rv32ifu2_ras #(
    parameter DEPTH = 8,
    parameter AW    = 3          // DEPTH = 1<<AW
)(
    input  wire         clk,
    input  wire         rst,           // 高有效

    // ---- F1: 本拍推进 IBUF 的 lane 里的 call / ret ----
    input  wire [ 3:0]  push_num,      // 本拍压入几条 (0..4)
    input  wire [31:0]  push_pc0,      // 返回地址 (= 该 call 的 pc + 4)
    input  wire [31:0]  push_pc1,
    input  wire [31:0]  push_pc2,
    input  wire [31:0]  push_pc3,
    input  wire [ 3:0]  pop_num,       // 本拍弹出几条 (0..4)

    // ---- 栈顶 (组合读, F1 算 next_pc 用) ----
    output wire [31:0]  top,
    output wire         top_vld,

    // ---- 快照 (随指令走, 用于误预测恢复) ----
    output wire [AW:0]  ptr_out,
    input  wire         restore_vld,
    input  wire [AW:0]  restore_ptr
);

reg [31:0] stk [0:DEPTH-1];
reg        evld [0:DEPTH-1];           // 该格内容是否可信
reg [AW:0] sp_q;                       // 0..DEPTH (DEPTH = 满)

// 先弹后压
//
// ⚠️ sp 的位宽 [AW:0] **不能动**: 它经 ptr_out 进 chk 的 RAS 位段 (top.v 的
//    RAS_CHK_MSB/LSB), 改宽会平移下游所有位切片 —— 本工程反复踩过的坑。
//    这里够用: push/pop 最多 4, DEPTH+4 = 12 < 2^(AW+1) = 16。
//    切片 [AW-1:0] 取的是计数值本身 (0..4 装得下), 不是丢高位。
wire [AW:0] sp_after_pop = (sp_q >= {1'b0, pop_num[AW-1:0]}) ? (sp_q - {1'b0, pop_num[AW-1:0]})
                                                             : {(AW+1){1'b0}};
wire [AW:0] sp_sum       = sp_after_pop + {1'b0, push_num[AW-1:0]};
wire [AW:0] sp_nxt       = (sp_sum > DEPTH[AW:0]) ? DEPTH[AW:0] : sp_sum;

// 压入位置: 栈底 = 0, 栈顶 = sp-1
wire [AW:0] pw0 = sp_after_pop;
wire [AW:0] pw1 = sp_after_pop + 1'b1;
wire [AW:0] pw2 = sp_after_pop + 2'd2;
wire [AW:0] pw3 = sp_after_pop + 2'd3;

// 栈顶: 空栈 或 该格内容不可信 时无效 (顶层会回落到 BTB 目标)
assign top_vld = (sp_q != {(AW+1){1'b0}}) & evld[sp_q - 1'b1];
assign top     = stk[sp_q - 1'b1];

assign ptr_out = sp_q;

integer i;
always @(posedge clk) begin
    if (rst) begin
        sp_q <= {(AW+1){1'b0}};
        for (i = 0; i < DEPTH; i = i + 1) begin
            stk[i]  <= 32'd0;
            evld[i] <= 1'b0;
        end
    end else if (restore_vld) begin
        // 拨回快照点, 并把**高于恢复点**的格子作废 —— 那些是错误路径留下的,
        // 内容无法回滚, 但至少不能再被当成可信的栈顶。
        sp_q <= restore_ptr;
        for (i = 0; i < DEPTH; i = i + 1)
            if (i >= restore_ptr[AW-1:0]) evld[i] <= 1'b0;
    end else begin
        if (push_num >= 4'd1) begin stk[pw0[AW-1:0]] <= push_pc0; evld[pw0[AW-1:0]] <= 1'b1; end
        if (push_num >= 4'd2) begin stk[pw1[AW-1:0]] <= push_pc1; evld[pw1[AW-1:0]] <= 1'b1; end
        if (push_num >= 4'd3) begin stk[pw2[AW-1:0]] <= push_pc2; evld[pw2[AW-1:0]] <= 1'b1; end
        if (push_num >= 4'd4) begin stk[pw3[AW-1:0]] <= push_pc3; evld[pw3[AW-1:0]] <= 1'b1; end
        sp_q <= sp_nxt;
    end
end

endmodule
