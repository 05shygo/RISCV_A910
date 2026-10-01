`timescale 1ns / 1ps
`include "defines.vh"

// ===========================================================================
// div_pipe — radix-4 (每拍 2 位) 除法器, 带前导位提前结束 (doc §5)
//
// 算法 = **对齐式 radix-4 恢复余数**, 与 C906 `aq_iu_div_shift2_kernel` 同路线:
// 它用三个减法器 r-d / r-2d / r-3d 的借位当比较 (div_remainder_lt_divisor_01/
// 10/11), 据此选 0~3 的商位并相减。本模块照抄这个思路 —— 非冗余余数、比较即
// 减法、没有 QDS 查表也没有 on-the-fly 商转换, 每一步都**可证明正确**:
//
//   不变式: 每步开始 r < 4*D_i  ⇒  q = floor(r/D_i) ∈ {0..3}
//           减完 r' = r - q*D_i < D_i = 4*D_{i-2}, 不变式保持
//   首步:   r = |a| < 4*D_i0 (i0 = s & ~1 的对齐步长, 见下), 归纳成立
//
// 迭代数的推导 (这是"提前结束"的核心, doc §5.2 的 div_ff1_res):
//   令 pos_a/pos_d = |a|/|d| 的最高位 1 的位置, s = pos_a - pos_d
//     s < 0  ⇒ |a| < |d| ⇒ 商 0、余数就是 |a|, **0 次迭代**
//     s >= 0 ⇒ 商 < 2^(s+1) ⇒ 只要 2n >= s+1 位就够 ⇒ n = (s>>1)+1, 最多 16
//   对齐步长取 i0 = s & ~1 (偶数), 于是 i0 = 2(n-1):
//     ⇒ 商寄存器移完正好是最终商、余数寄存器就是最终余数,
//       **不需要末尾重定标、也不需要 on-the-fly 转换**
//   (这是对齐式相对"每拍把被除数移进来"那套写法的关键好处: 后者的商是
//    左对齐的, 小操作数白跑满 16 拍还要做一次可变移位。)
//
// 位宽由算法本身定死 (不是随手取的): D_i0 = |d| << i0 < 2^(pos_d+1+i0)
//   ≤ 2^(pos_a+1) ≤ 2^32, 所以 D 只需 32 位、3D 34 位、r 32 位。
//
// ---------------------------------------------------------------------------
// PREP 拆成**两拍** (IDLE + PREP) —— 这是综合实测逼出来的, 不是随口多切一级
// ---------------------------------------------------------------------------
// doc §5.2 的预算写的是 "PREP 1 + ITER n + FIXUP 1 + RESP 1", 也就是请求那一拍
// 把绝对值/前导位/对齐/2D/3D 一次算完。照那个写法综合出来的关键路径是
// `req_src0[11] → d3_r[26]`, **1922 ps** (nangate45, 见 doc §9.1 的口径):
//
//   |取绝对值(8 级) → 前导位编码(8 级) → 求差(3) → 对齐量(1) → 桶形移位(7)
//    → 3D 加法(7)|                                  ≈ 34 级逻辑
//
// 比现状整个 MUL_DIV (1379 ps) 还慢, 会顶穿整核 Fmax, 所以拆成:
//   拍 1 (IDLE) : |a| / |d| + 控制位          —— 只有一级 32 位加/减, ~8 级
//   拍 2 (PREP) : 前导位 → s → 对齐量 → 摆除数 —— 编码+移位+3D,  ~19 级
// 两拍各留足余量, 代价是除法延迟 +1 拍 (n+4 而不是 n+3)。
// 注意 C906 也是这么干的: 它的 PREP 是 WFI1 → WFI2 → ALIGN 三个状态。
//
// 周期: IDLE(请求拍) → PREP → ITER×n → FIXUP → RESP ⇒ **n+4 拍**。
//   满量程 20 拍、小操作数 4~8 拍 (现状是恒 34 拍)。除法不做流水 (doc §5.5):
//   做流水每级都要带一整套 32 位余数+商寄存器和完整比较逻辑, 面积翻几倍, 而除法
//   在真实负载里占比 <1% —— 正解是"慢就慢, 但绝不阻塞别人"。
//
// 特殊值 (doc §5.4) 全在 FIXUP 一次做干净: 除零 DIV/DIVU→-1、REM/REMU→被除数
//   本身; INT_MIN/-1 **不需要特判** —— |a|=2^31、|d|=1 算出来商就是 0x8000_0000
//   (2^31), 符号异或为 0, 余数 0, 正好是规范要的 INT_MIN 与 0。
// ===========================================================================
module div_pipe #(
    parameter TAG_W = 7
)(
    input  wire              clk,
    input  wire              rst,

    // ---- 请求 (EX 级; 核会一直保持到 resp_vld, 见下面的"中止"说明) ----
    input  wire              req_vld,
    input  wire [3:0]        req_op,      // `MD_OP_DIV / DIVU / REM / REMU
    input  wire [31:0]       req_src0,
    input  wire [31:0]       req_src1,
    input  wire [TAG_W-1:0]  req_tag,

    output wire              busy,
    output wire              resp_vld,
    output wire [31:0]       resp_data,
    output wire [TAG_W-1:0]  resp_tag,

    input  wire              flush_vld
);

localparam ST_IDLE  = 3'd0;   // 请求拍: PREP 第一拍 (取绝对值)
localparam ST_PREP  = 3'd1;   // PREP 第二拍 (前导位 → 迭代数/对齐量 → 摆除数)
localparam ST_ITER  = 3'd2;
localparam ST_FIXUP = 3'd3;
localparam ST_RESP  = 3'd4;

reg [2:0] state;

// ---------------------------------------------------------------------------
// PREP 第一拍: 绝对值 + 控制位 (只经过一级加减, 深度 ~8)
// ---------------------------------------------------------------------------
wire is_signed = (req_op == `MD_OP_DIV) | (req_op == `MD_OP_REM);
wire is_rem    = (req_op == `MD_OP_REM) | (req_op == `MD_OP_REMU);
wire by_zero   = (req_src1 == 32'b0);

wire [31:0] a_abs = (is_signed & req_src0[31]) ? (~req_src0 + 32'd1) : req_src0;
wire [31:0] d_abs = (is_signed & req_src1[31]) ? (~req_src1 + 32'd1) : req_src1;

reg [31:0]     a_abs_r, d_abs_r;
reg [3:0]      op_r;
reg            sign_q_r, sign_r_r, by_zero_r;
reg [31:0]     dvd_orig_r;
reg [TAG_W-1:0] tag_r;

// ---------------------------------------------------------------------------
// PREP 第二拍: 前导位 → 迭代数 / 对齐量 → 除数与它的 2 倍 3 倍
// ---------------------------------------------------------------------------
// 组内最高位 (8 位, ~3 级)
function [2:0] hi3;
    input [7:0] y;
    begin
        hi3 = y[7] ? 3'd7 : y[6] ? 3'd6 : y[5] ? 3'd5 : y[4] ? 3'd4 :
              y[3] ? 3'd3 : y[2] ? 3'd2 : y[1] ? 3'd1 : 3'd0;
    end
endfunction

// 前导位优先编码器 (doc §5.6 估的 ~150 门)。做成"先 8 位一组、再组内"两级,
// 而不是 32 长的链。x==0 时返回 0 是**有意**的: 那样 s = -pos_d < 0 ⇒ 0 次
// 迭代 ⇒ 商 0、余数 = a = 0, 正好对。
function [4:0] hi_bit;
    input [31:0] x;
    reg   [1:0]  blk;
    reg   [2:0]  inner;
    begin
        if      (|x[31:24]) blk = 2'd3;
        else if (|x[23:16]) blk = 2'd2;
        else if (|x[15: 8]) blk = 2'd1;
        else                blk = 2'd0;
        inner = hi3(blk[1] ? (blk[0] ? x[31:24] : x[23:16])
                           : (blk[0] ? x[15: 8] : x[ 7: 0]));
        hi_bit = {blk, inner};
    end
endfunction

wire [5:0]        pos_a  = {1'b0, hi_bit(a_abs_r)};
wire [5:0]        pos_d  = {1'b0, hi_bit(d_abs_r)};
wire signed [6:0] s_diff = {1'b0, pos_a} - {1'b0, pos_d};     // -31..31

// n = (s<0) ? 0 : (s>>1)+1; 除零也直接 0 次迭代 (结果由 by_zero 决定)
wire [5:0] n_iter = (by_zero_r | s_diff[6]) ? 6'd0 : ({1'b0, s_diff[5:1]} + 6'd1);

// 除数对齐步长 i0 = s & ~1 (s<0 时用不上, 置 0 免得移位器拿到负数)
wire [4:0] align_sh = s_diff[6] ? 5'd0 : {s_diff[5:1], 1'b0};

// D = |d| << i0 / 3D = 3|d| << i0 = (2|d| + |d|) << i0:
// 两条桶形移位**并行**, 3 倍的加法放在移位前面 —— 若写成 (D + 2D) 就变成
// "编码 → 移位 → 加法" 串成一条, 白白多 7 级。
wire [31:0] d_sh   = d_abs_r << align_sh;
wire [32:0] d2_sh  = {d_sh, 1'b0};
wire [33:0] d3_abs = {1'b0, d_abs_r, 1'b0} + {2'b0, d_abs_r};
wire [33:0] d3_sh  = d3_abs << align_sh;

// ---------------------------------------------------------------------------
// 除法状态寄存器
// ---------------------------------------------------------------------------
reg [31:0]      d1_r;      // D_i      (32 位就够, 见文件头的位宽推导)
reg [32:0]      d2_r;      // 2*D_i
reg [33:0]      d3_r;      // 3*D_i
reg [31:0]      r_r;       // 余数 (非冗余, 恒 < D_i)
reg [31:0]      q_r;       // 商 (每拍移进 2 位)
reg [5:0]       cnt;

// 请求方消失 ⇒ 这条除法已经被核冲刷掉了, 立即中止, 别留一个陈旧结果在后面
// 冒充"下一个除法请求的响应"。核在等结果时会把 req_vld 保持住 (用 stall 顶住
// EX), 所以 req_vld 中途变 0 只可能是整条指令被 flush。
wire abort = flush_vld | ((state != ST_IDLE) & ~req_vld);

// ---------------------------------------------------------------------------
// ITER: 三个减法器并行比较 r 与 d/2d/3d, 借位就是"小于"
// ---------------------------------------------------------------------------
wire [33:0] r_x  = {2'b0, r_r};
wire [33:0] d3_x = d3_r;
wire [33:0] d2_x = {1'b0, d2_r};
wire [33:0] d1_x = {2'b0, d1_r};

wire [34:0] sub3 = {1'b0, r_x} - {1'b0, d3_x};
wire [34:0] sub2 = {1'b0, r_x} - {1'b0, d2_x};
wire [34:0] sub1 = {1'b0, r_x} - {1'b0, d1_x};

wire ge3 = ~sub3[34];
wire ge2 = ~sub2[34] & ~ge3;
wire ge1 = ~sub1[34] & ~ge2 & ~ge3;

wire [1:0]  q_dig = ge3 ? 2'd3 : ge2 ? 2'd2 : ge1 ? 2'd1 : 2'd0;
wire [33:0] r_sel = ge3 ? sub3[33:0] : ge2 ? sub2[33:0] : ge1 ? sub1[33:0] : r_x;

wire last_iter = (cnt == 6'd1);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= ST_IDLE;
    end else if (abort) begin
        state <= ST_IDLE;
    end else begin
        case (state)
            // ⚠️ 请求拍**不能**判 n_iter: 前导位是拿 a_abs_r/d_abs_r 算的, 而那两个
            // 寄存器要到这一拍末尾才装载 —— 在 IDLE 里用 n_iter 就永远在拿上一条
            // 除法的旧值 (症状: 小操作数白等满量程, INT_MIN/-1 还会算错)。
            // 所以 n_iter=0 的短路放在 PREP: 那一拍寄存值已经就位、n_iter 是真的。
            ST_IDLE : if (req_vld) state <= ST_PREP;
            ST_PREP : state <= (n_iter == 6'd0) ? ST_FIXUP : ST_ITER;
            ST_ITER : if (last_iter) state <= ST_FIXUP;
            ST_FIXUP: state <= ST_RESP;
            default : state <= ST_IDLE;      // ST_RESP
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        a_abs_r    <= 32'b0;
        d_abs_r    <= 32'b0;
        op_r       <= `MD_OP_DIV;
        sign_q_r   <= 1'b0;
        sign_r_r   <= 1'b0;
        by_zero_r  <= 1'b0;
        dvd_orig_r <= 32'b0;
        tag_r      <= {TAG_W{1'b0}};
        d1_r       <= 32'b0;
        d2_r       <= 33'b0;
        d3_r       <= 34'b0;
        r_r        <= 32'b0;
        q_r        <= 32'b0;
        cnt        <= 6'b0;
    end else if (state == ST_IDLE && req_vld && !abort) begin
        a_abs_r    <= a_abs;
        d_abs_r    <= d_abs;
        op_r       <= req_op;
        // 商 = 两符号异或, 余数 = 被除数的符号 (doc §5.4)
        sign_q_r   <= is_signed & (req_src0[31] ^ req_src1[31]);
        sign_r_r   <= is_signed & req_src0[31];
        by_zero_r  <= by_zero;
        dvd_orig_r <= req_src0;               // 除零时 REM/REMU 返回**原始**被除数
        tag_r      <= req_tag;
        // 余数/商在请求拍就摆好: n_iter=0 时直接跳 FIXUP, 那时也得有正确的 r/Q
        r_r        <= a_abs;
        q_r        <= 32'b0;
    end else if (state == ST_PREP) begin
        d1_r <= d_sh[31:0];
        d2_r <= d2_sh;
        d3_r <= d3_sh;
        cnt  <= n_iter;
    end else if (state == ST_ITER) begin
        d1_r <= d1_r >> 2;
        d2_r <= d2_r >> 2;
        d3_r <= d3_r >> 2;
        r_r  <= r_sel[31:0];                  // r' < D_i < 2^32, 高位恒 0
        q_r  <= {q_r[29:0], q_dig};
        cnt  <= cnt - 6'd1;
    end
end

// ---------------------------------------------------------------------------
// FIXUP → RESP: 符号 / 特殊值修正, 结果打一拍出去
// ---------------------------------------------------------------------------
wire [31:0] quo_s = sign_q_r ? (~q_r + 32'd1) : q_r;
wire [31:0] rem_s = sign_r_r ? (~r_r + 32'd1) : r_r;
wire [31:0] norm  = is_rem ? rem_s : quo_s;
wire [31:0] fixed = by_zero_r ? (is_rem ? dvd_orig_r : 32'hFFFF_FFFF) : norm;

reg [31:0]      resp_data_r;
reg [TAG_W-1:0] resp_tag_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        resp_data_r <= 32'b0;
        resp_tag_r  <= {TAG_W{1'b0}};
    end else if (state == ST_FIXUP && !abort) begin
        resp_data_r <= fixed;
        resp_tag_r  <= tag_r;
    end
end

assign busy      = (state != ST_IDLE);
assign resp_vld  = (state == ST_RESP);
assign resp_data = resp_data_r;
assign resp_tag  = resp_tag_r;

endmodule
