`timescale 1ns / 1ps
`include "defines.vh"

// ===========================================================================
// mul_pipe — 2 级真流水乘法器 (radix-4 Booth + 进位保留压缩树)
//
// 结构 (doc §4.1/§4.3 方案 A, 切分点按综合实测前移了两级):
//
//   M1 级: 操作数预扩展(33 位) → Booth 编码(17 组) → 部分积(17 行) + 常量行
//          → CSA 压缩树前 4 级 → 打拍 **4 个 64 位冗余行**
//   M2 级: 压缩树后 2 级 → 3:2 CSA (MAC 预留, §4.6) → 最终 CPA(64 位)
//          → 结果选择 → 响应寄存器
//
// 关键点是 **在冗余形式上切流水** (doc §4.4): 压缩树的输出永远是"若干行没有进位
// 传播的部分积", 可以随便跨寄存器, 最后用一个 CPA 收尾。如果先把它们加成一个
// 64 位数再寄存, 第二级就只剩布线了 —— 等于把延迟全堆在 M1, 白切一级。
// (切分点为什么落在树上而不是树的末尾: 见下面"压缩树"那一段的实测说明。)
//
// 四种 MUL 共用同一条通路 (doc §4.2): 操作数按符号性预扩展到 33 位
//   MUL/MULH     : src0 有符号, src1 有符号
//   MULHSU       : src0 有符号, src1 无符号 (高位补 0)
//   MULHU        : 两者都补 0
// 于是 signed×signed / signed×unsigned / unsigned×unsigned 都变成**同一个
// 33×33 有符号乘法**, op 只影响扩展位的取值和最后取高 32 还是低 32 位。
//
// 时序: 请求拍 T 打 M1, T+1 打 M2, T+2 响应有效 —— 与 doc §3.3 的图一致,
// 也正好是本核 EX→WB 的 2 拍 (所以 P1 里乘法结果由 WB 级直接并进写回数据)。
//
// MAC 口 (§4.6): `req_src2/req_acc_mode` 的插入点**定死在 M2 的 3:2 CSA**。
// acc_mode=00 时那一级是纯透传 (核里把 acc_mode 接成常量 0 之后综合会整级优化
// 掉), 对不带 MAC 的负载零成本。注意将来若改成"单元内部累加器", M2 会变成
// acc_reg→CSA→CPA→acc_reg 的**自环**, 那时 M2 的周期就直接等于 CSA+CPA ——
// 这是 §4.6 里提醒过的、加 MAC 之后 M2 会变慢的唯一原因。
// ===========================================================================
module mul_pipe #(
    parameter TAG_W = 7
)(
    input  wire              clk,
    input  wire              rst,

    // ---- 发射请求 (EX 级, II=1: 每拍可来一条) ----
    input  wire              req_vld,
    input  wire [3:0]        req_op,      // `MD_OP_MUL / MULH / MULHSU / MULHU
    input  wire [31:0]       req_src0,
    input  wire [31:0]       req_src1,
    input  wire [TAG_W-1:0]  req_tag,
    input  wire [63:0]       req_src2,    // MAC 累加操作数 (P1 接 0)
    input  wire [1:0]        req_acc_mode,// `MD_ACC_NONE / ADD / SUB

    // ---- 写回 (固定 T+2 拍, 每拍最多一个脉冲) ----
    output wire              resp_vld,
    output wire [31:0]       resp_data,
    output wire [TAG_W-1:0]  resp_tag,

    // ---- 冲刷: 清掉在飞的乘法 (doc §6.3) ----
    // 顺序核里重定向来自 WB(最老的那条), 在飞的乘法一定比它年轻, 全清即可;
    // 乱序核要按 tag 比较 flush_tag, 那时只需把这里的 flush_vld 换成比较结果,
    // 单元结构不变。
    input  wire              flush_vld
);

localparam W = 64;                     // 只需要积的低 64 位 (MUL 取 [31:0], MULH* 取 [63:32])

// ---------------------------------------------------------------------------
// 操作数预扩展: 33 位 (doc §4.2)
// ---------------------------------------------------------------------------
// 无符号侧补 0、有符号侧补符号位 —— 补完之后四种 MUL 就是同一个有符号乘法。
wire s0_signed = (req_op == `MD_OP_MUL) | (req_op == `MD_OP_MULH) | (req_op == `MD_OP_MULHSU);
wire s1_signed = (req_op == `MD_OP_MUL) | (req_op == `MD_OP_MULH);
wire [32:0] a33 = {req_src0[31] & s0_signed, req_src0};
wire [32:0] b33 = {req_src1[31] & s1_signed, req_src1};

// ---------------------------------------------------------------------------
// M1 级: radix-4 Booth 编码 + 部分积 + 压缩树
// ---------------------------------------------------------------------------
// 编码用的是**乘数** b33 (33 位), 所以 17 组: 第 i 组吃 {b[2i+1], b[2i], b[2i-1]}。
// b[-1] 当 0 (i=0 单独处理); b[33] 取 b33 的符号位 —— 33 位有符号数做 radix-4
// 编码时必须多补这一位, 否则最高组的正负判错。
wire [33:0] b_booth = {b33[32], b33};

// 被乘数 A 是**有符号**的 33 位值, 所以部分积的符号是"编码符号 ⊕ A 的符号"。
// ⚠️ 两条都要写对, 而且**不要**绕道去算 |A|:
//   * 绕道算 |A| (一级 34 位条件取反) 会把 M1 的路径拖长 ~8 级 —— 综合实测
//     `req_op[2] → car_m2[39]` 1180 ps 里有 350 ps 是这一级, 而 M1 只剩一个周期;
//   * 但也不能像最初那样"把 a33 当无符号幅度、用编码符号当扩展位": A 为负时
//     (a33[32]=1) 行的高位会被当成 0 扩展, 结果**只在高 32 位错** —— MUL 看不
//     出来 (它只取低 32 位), MULH/MULHSU/MULHU 全错。
// 正解是直接用 A 的**符号扩展形式** (补码域天然带符号):
//   正部分积: 行 = A_ext, 高位补 A 自己的符号      ⇒ 任意符号都自动对
//   负部分积: 行 = ~A_ext, 高位补 ~A 的符号, 再靠 k_row 补那个 +1
// 于是 mag 这一级只剩 "2A 左移一位" (纯布线) + 一个取反 XOR, 没有加法器。
wire [33:0] a_ext = {a33[32], a33};                            // 符号扩展到 34 位

wire [W-1:0] pp_row [0:16];
wire [16:0]  pp_neg;

genvar i;
for (i = 0; i < 17; i = i + 1) begin : g_pp
    wire [2:0] code = {b_booth[2*i+1], b_booth[2*i], (i == 0) ? 1'b0 : b_booth[2*i-1]};
    wire       nz   = (code != 3'b000) && (code != 3'b111);   // 该组要不要出部分积
    wire       two  = (code == 3'b011) || (code == 3'b100);   // 2A / -2A
    wire       cneg = (code == 3'b100) || (code == 3'b101) || (code == 3'b110);
    // 行的符号 = 编码符号 ⊕ A 的符号; 整行为 0 时 (nz=0) 恒 0, 免得
    // "0 的部分积"被符号位撑成一个非零的数。
    wire       ext  = nz & (cneg ^ a33[32]);
    wire [33:0] mag = nz ? (two ? {a33, 1'b0} : a_ext) : 34'b0;
    wire [33:0] sel = cneg ? ~mag : mag;

    // 一行 = (34-2i) 个符号位做符号扩展 + 34 位尾数/补码, 整体左移 2i。
    // 负行那一份 "+1" 不在这里做 —— 17 个 +1 的落点 (第 2i 位) 互不重叠,
    // 合并成常量行 k_row 更省, 也少一级加法。
    // 中间用 68 位接住再截低 64 位: 加法没有借位传播, 丢掉 ≥64 的位不影响
    // 低 64 位的结果, 而这样写不会踩到"移位把有用位挤出去"的坑。
    wire [67:0] row68 = {{(34 - 2*i){ext}}, sel} << (2*i);
    assign pp_row[i] = row68[W-1:0];
    assign pp_neg[i] = cneg;
end

// 17 个负号 "+1" 的合并常量行 (第 i 行的 +1 落在第 2i 位)
wire [W-1:0] k_row;
genvar gk;
for (gk = 0; gk < 17; gk = gk + 1) begin : g_krow
    assign k_row[2*gk]     = pp_neg[gk];
    assign k_row[2*gk + 1] = 1'b0;
end
assign k_row[W-1:34] = 30'b0;

// ---- 进位保留压缩树: 18 → 12 → 8 → 6 → 4 ‖ 4 → 3 → 2 (6 级 3:2) ----
// 每级把 3 行压成 2 行; 进位输出**已经左移一位**, 所以各行始终对齐在同一列上。
//
// ⚠️ **切分点不在树的末尾, 而是在第 4 级之后** (‖ 处)。这不是随手切的:
// 综合实测按 doc §4.3 方案 A 那样"整棵树都放 M1"跑出来
// `req_op[0] → sum_m2[60]` = 1056 ps 逻辑 + 250 ps 输入延时 ≈ 1306 ps ⇒ 只有
// 766 MHz, 达不到 §9.4 定的 870 MHz。树的每一级在 nangate45 上约 110 ps,
// 把最后两级挪到 M2 之后 M1 降到 ~820 ps (≈930 MHz), 而 M2 那边
// (2 级 CSA + CPA) 仍然宽裕。代价只是中间那两行也各要 64 个 FF ——
// M1→M2 寄存器从 2×64 变成 4×64, 比多切一整级(§4.3 方案 B)便宜得多。
function [W-1:0] csa_s;
    input [W-1:0] a, b, c;
    begin csa_s = a ^ b ^ c; end
endfunction

function [W-1:0] csa_c;
    input [W-1:0] a, b, c;
    reg [W-1:0] m;
    begin
        m = (a & b) | (a & c) | (b & c);
        csa_c = {m[W-2:0], 1'b0};
    end
endfunction

wire [W-1:0] lv0 [0:17];
genvar gj;
for (gj = 0; gj < 17; gj = gj + 1) begin : g_lv0
    assign lv0[gj] = pp_row[gj];
end
assign lv0[17] = k_row;

wire [W-1:0] lv1 [0:11];
genvar g1;
for (g1 = 0; g1 < 6; g1 = g1 + 1) begin : g_lv1
    assign lv1[2*g1]     = csa_s(lv0[3*g1], lv0[3*g1+1], lv0[3*g1+2]);
    assign lv1[2*g1 + 1] = csa_c(lv0[3*g1], lv0[3*g1+1], lv0[3*g1+2]);
end

wire [W-1:0] lv2 [0:7];
genvar g2;
for (g2 = 0; g2 < 4; g2 = g2 + 1) begin : g_lv2
    assign lv2[2*g2]     = csa_s(lv1[3*g2], lv1[3*g2+1], lv1[3*g2+2]);
    assign lv2[2*g2 + 1] = csa_c(lv1[3*g2], lv1[3*g2+1], lv1[3*g2+2]);
end

wire [W-1:0] lv3 [0:5];
genvar g3;
for (g3 = 0; g3 < 2; g3 = g3 + 1) begin : g_lv3
    assign lv3[2*g3]     = csa_s(lv2[3*g3], lv2[3*g3+1], lv2[3*g3+2]);
    assign lv3[2*g3 + 1] = csa_c(lv2[3*g3], lv2[3*g3+1], lv2[3*g3+2]);
end
assign lv3[4] = lv2[6];
assign lv3[5] = lv2[7];

wire [W-1:0] lv4 [0:3];
genvar g4;
for (g4 = 0; g4 < 2; g4 = g4 + 1) begin : g_lv4
    assign lv4[2*g4]     = csa_s(lv3[3*g4], lv3[3*g4+1], lv3[3*g4+2]);
    assign lv4[2*g4 + 1] = csa_c(lv3[3*g4], lv3[3*g4+1], lv3[3*g4+2]);
end

// ---- M1 → M2 流水寄存器 (4 个冗余行 = 4×64 FF, 见上面切分点的说明) ----
reg [W-1:0]       row_m2 [0:3];
reg [3:0]         op_m2;
reg [TAG_W-1:0]   tag_m2;
reg [63:0]        src2_m2;
reg [1:0]         acc_m2;
reg               vld_m2;

// ---------------------------------------------------------------------------
// M2 级: MAC 预留 CSA → 最终 CPA → 结果选择
// ---------------------------------------------------------------------------
// 压缩树的最后两级 + MAC 的 3:2 CSA 都落在这一级 (切分点见上面)。
wire [W-1:0] lv5 [0:2];
genvar g5;
for (g5 = 0; g5 < 1; g5 = g5 + 1) begin : g_lv5
    assign lv5[0] = csa_s(row_m2[0], row_m2[1], row_m2[2]);
    assign lv5[1] = csa_c(row_m2[0], row_m2[1], row_m2[2]);
end
assign lv5[2] = row_m2[3];

wire [W-1:0] sum_m2 = csa_s(lv5[0], lv5[1], lv5[2]);
wire [W-1:0] car_m2 = csa_c(lv5[0], lv5[1], lv5[2]);

// MAC 的 3:2 CSA。acc_mode=00 时把 (sum,carry) 原样透传: 输入到 CPA 只多一级
// mux (不引入额外延迟), 综合在 acc_mode 被接成常量 0 之后还会把整级删掉。
// 减 = src2 取反, "+1" 走 CPA 的进位输入 (doc §4.6 的 mul_ex1_sub 同款做法)。
wire         acc_add = (acc_m2 == `MD_ACC_ADD);
wire         acc_sub = (acc_m2 == `MD_ACC_SUB);
wire [W-1:0] mac_c   = acc_sub ? ~src2_m2 : (acc_add ? src2_m2 : {W{1'b0}});
wire [W-1:0] mac_sum = csa_s(sum_m2, car_m2, mac_c);
wire [W-1:0] mac_car = csa_c(sum_m2, car_m2, mac_c);
wire [W-1:0] cpa_a = (acc_m2 == `MD_ACC_NONE) ? sum_m2 : mac_sum;
wire [W-1:0] cpa_b = (acc_m2 == `MD_ACC_NONE) ? car_m2 : mac_car;
wire         cpa_ci = acc_sub;

wire [W-1:0] product = cpa_a + cpa_b + {{(W-1){1'b0}}, cpa_ci};

// MUL 取低 32 位, MULH/MULHSU/MULHU 取高 32 位
wire [31:0] result = (op_m2 == `MD_OP_MUL) ? product[31:0] : product[63:32];

// ---------------------------------------------------------------------------
// 流水寄存器
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        row_m2[0] <= {W{1'b0}};
        row_m2[1] <= {W{1'b0}};
        row_m2[2] <= {W{1'b0}};
        row_m2[3] <= {W{1'b0}};
        op_m2   <= 4'b0;
        tag_m2  <= {TAG_W{1'b0}};
        src2_m2 <= 64'b0;
        acc_m2  <= `MD_ACC_NONE;
        vld_m2  <= 1'b0;
    end else if (flush_vld) begin
        // 被冲刷的乘法绝不能再产生响应 (doc §8.3): 它在核里已经被 EX / EX_MEM
        // 的 flush 丢掉, 结果一旦照常脉冲, 就会撞上"另一条正好走到 WB 的指令"。
        vld_m2 <= 1'b0;
    end else begin
        row_m2[0] <= lv4[0];
        row_m2[1] <= lv4[1];
        row_m2[2] <= lv4[2];
        row_m2[3] <= lv4[3];
        op_m2   <= req_op;
        tag_m2  <= req_tag;
        src2_m2 <= req_src2;
        acc_m2  <= req_acc_mode;
        vld_m2  <= req_vld;
    end
end

// 响应寄存器: 与"乘法指令自己的 WB 拍"对齐的那一拍 (T+2)
reg             resp_vld_r;
reg [31:0]      resp_data_r;
reg [TAG_W-1:0] resp_tag_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        resp_vld_r  <= 1'b0;
        resp_data_r <= 32'b0;
        resp_tag_r  <= {TAG_W{1'b0}};
    end else begin
        // 被冲刷的乘法**绝不出现 resp_valid** (doc §8.3): 冲刷当拍把这一位按掉。
        // 唯一"响应已经算好、同时又有冲刷"的情形是乘法正好在 WB 那拍被中断
        // squash —— 那一拍的写回由核的 wb_rf_we_eff 掐掉, 与这一位无关;
        // 这里只是保证不留下一个"没人认领的脉冲"去撞后面某条走到 WB 的指令。
        resp_vld_r  <= vld_m2 & ~flush_vld;
        resp_data_r <= result;
        resp_tag_r  <= tag_m2;
    end
end

assign resp_vld  = resp_vld_r;
assign resp_data = resp_data_r;
assign resp_tag  = resp_tag_r;

endmodule
