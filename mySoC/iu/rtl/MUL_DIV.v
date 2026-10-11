`timescale 1ns / 1ps
`include "defines.vh"

// ===========================================================================
// MUL_DIV — RV32M 乘除法单元 (真流水乘法 + radix-4 除法, 带 tag 的请求/写回接口)
//
// 形态 (doc §0): **乘法、除法拆成两条独立流水, 共用一个带 tag 的请求/写回接口**。
//
//   | 形态      | 发射间隔 II | 延迟        | 阻塞发射?                  |
//   |-----------|-------------|-------------|----------------------------|
//   | mul_pipe  | 1 (真流水)  | 2 拍        | 否                         |
//   | div_pipe  | 忙则不发    | 3~19 拍     | 否 (顺序核用 busy 反压 ID) |
//
// 四条设计决策 (doc §0), 按重要性:
//  1. **接口从第一天就带 tag** (`req_tag/resp_tag`)。顺序核里 tag 先接 rd 的序号;
//     换乱序核时只是把 tag 接到 rename/ROB, **单元本身一行不用改**。
//  2. **乘除分家**: 乘法是吞吐部件、除法是延迟部件。合成一条流水的结果是
//     "除法在跑的时候乘法被卡住"。C906 也是两个文件、两个写回口。
//  3. **在冗余形式上切流水** (见 mul_pipe.v)。
//  4. **不阻塞发射**: 结果 2 拍后从写回口自己出来, 谁要用谁等唤醒。
//
// 本模块只做三件事: 按 op 把请求分到两条流水 / 把两条响应合并回一个写回口 /
// 把冲刷广播下去。仲裁优先级 **mul > div** (doc §6.1): div 慢, 多等一两拍无所谓;
// mul 被抢就会掉吞吐。
//
// 结构性约定 (doc §8.3, 单元级 TB 逐条断言):
//   * resp_valid 的条数 == 被接受的请求条数 − 被冲刷掉的条数;
//   * 同一 tag 在一次生命周期里最多写回一次;
//   * 被 flush 掉的乘法**绝不出现** resp_valid (mul_pipe 里清在飞项);
//   * div_busy 期间请求不会被 div 口吃掉 (= 请求只在 IDLE 那一拍被接受);
//   * **乘、除的响应永不同拍** —— 请求口严格时分复用 (除法在飞期间 `req_op` 必须
//     一直是除 op), 两条流水不可能同时在飞。TB 里有常驻监视器 + `probe_overlap`
//     定向探测; 写回口的让路机制见下面"写回口合并"那段。
//
// P1 (当前 5 级顺序核) 的接线方式见 mycpu.v: `wb_grant` 接 1、`req_src2` 接 0、
// `req_acc_mode` 接 `MD_ACC_NONE`、`flush_tag` 不参与比较 (顺序核重定向即全清)。
// ===========================================================================
module MUL_DIV #(
    parameter DATA_W = 32,
    parameter TAG_W  = 7              // 物理寄存器号: PRF = 128 项 → 7 位 (doc §3.1)
)(
    input  wire              clk,
    input  wire              rst,

    // ---- 发射请求 (EX 级; 乘法口每拍可来一条) ----
    input  wire              req_valid,
    input  wire [3:0]        req_op,        // `MD_OP_MUL / MULH / MULHSU / MULHU / DIV / DIVU / REM / REMU
    input  wire [DATA_W-1:0] req_src0,
    input  wire [DATA_W-1:0] req_src1,
    input  wire [TAG_W-1:0]  req_tag,       // 结果身份证 (乱序: preg; 顺序: rd 序号)
    input  wire [63:0]       req_src2,      // MAC 累加操作数 (§4.6; P1 接 0)
    input  wire [1:0]        req_acc_mode,  // `MD_ACC_NONE / ADD / SUB

    // ---- 流水状态 ----
    output wire              mul_ready,     // 乘法口空 (II=1 时=写回口被授权)
    output wire              div_busy,      // 除法忙, 这一拍别选它

    // ---- 写回口 (两条流水共用, 分时) ----
    output wire              resp_valid,
    output wire [DATA_W-1:0] resp_data,
    output wire [TAG_W-1:0]  resp_tag,
    output wire              resp_is_div,   // 1 = 这条响应来自除法 (调试/仲裁用)

    // ---- 控制 ----
    // 写回总线授权 (doc §3.2/§9.7: 要真做, 别接常量)。两处生效, 方向不同:
    //   * 乘法端 (输入侧): `mul_ready = wb_grant` —— 没授权就不收新的乘法;
    //   * 除法端 (输出侧): `div_resp_gnt = wb_grant & ~mul_resp_mld` ——
    //     没授权就把结果举在 `div_pipe` 的 ST_RESP 里等。
    // ⚠️ 乘法**没有输出缓冲**, 已经收下的那 ≤2 条照样会在 T+2 写回, 授权拦不住 ——
    //    这是本单元接口的固有语义, 外部仲裁要按"最多再放 2 拍"来设计。
    input  wire              wb_grant,
    input  wire              flush_valid,
    input  wire [TAG_W-1:0]  flush_tag      // 只冲刷比它年轻的在飞项 (乱序必需)
);

// op 的高位区分乘/除: MD_OP_MUL..MULHU = 0..3, DIV..REMU = 4..7
wire req_is_mul = ~req_op[2];
wire req_is_div =  req_op[2];

// 乘法口恒可收 (II=1), 但**写回口被授权**才算真的收下 —— 本核把 wb_grant 接 1,
// 乱序核里它由发射队列保证"同一拍只有一条要写这个口的指令", 否则乘法会把
// 同口的 ALU 饿死 (doc §9.7)。
assign mul_ready = wb_grant;

wire mul_req = req_valid & req_is_mul & mul_ready;
// 除法口**不要**用 ~div_busy 去掐请求: 除法是"请求保持到出结果"的协议, 掐了
// 就等于告诉它"请求方跑了" (div_pipe 靠 req_vld 中途变 0 来识别冲刷)。忙的
// 时候本来就不该被选, 这一点由 div_busy 反馈给发射侧 (顺序核里是 div_stall),
// div_pipe 自己也只在 IDLE 那一拍接受请求 —— 双重保险, 但**不能**在这里掐。
wire div_req = req_valid & req_is_div;

wire             mul_resp_vld;
wire [DATA_W-1:0] mul_resp_data;
wire [TAG_W-1:0] mul_resp_tag;

wire             div_resp_vld;
wire [DATA_W-1:0] div_resp_data;
wire [TAG_W-1:0] div_resp_tag;

// ⚠️ 这两根**必须在这里声明** —— 下面 `U_DIV_PIPE` 就要用 `div_resp_gnt`。
//    放到例化之后再 `wire x = ...` 会变成"先用后声明", Verilog 静默造一根 1 位
//    隐式线网, 端口接上去是 Z/X。本仓栽过四次 (见 `eda-env-csh-vcs`)。
//    含义与理由见文件下方"写回口合并"那段长注。
wire div_resp_gnt;                   // 写回口这一拍归除法 → 见下方 assign
wire div_resp_take;                  // 除法响应**真被取走** (= vld & gnt)

// ---------------------------------------------------------------------------
// 两条独立流水
// ---------------------------------------------------------------------------
mul_pipe #(.TAG_W(TAG_W)) U_MUL_PIPE (
    .clk          (clk),
    .rst          (rst),
    .req_vld      (mul_req),
    .req_op       (req_op),
    .req_src0     (req_src0[DATA_W-1:0]),
    .req_src1     (req_src1[DATA_W-1:0]),
    .req_tag      (req_tag),
    .req_src2     (req_src2),
    .req_acc_mode (req_acc_mode),
    .resp_vld     (mul_resp_vld),
    .resp_data    (mul_resp_data),
    .resp_tag     (mul_resp_tag),
    .flush_vld    (flush_valid)
);

div_pipe #(.TAG_W(TAG_W)) U_DIV_PIPE (
    .clk        (clk),
    .rst        (rst),
    .req_vld    (div_req),
    .req_op     (req_op),
    .req_src0   (req_src0[DATA_W-1:0]),
    .req_src1   (req_src1[DATA_W-1:0]),
    .req_tag    (req_tag),
    .busy       (div_busy),
    .resp_vld   (div_resp_vld),
    .resp_data  (div_resp_data),
    .resp_tag   (div_resp_tag),
    .resp_gnt   (div_resp_gnt),
    .flush_vld  (flush_valid)
);

// ---------------------------------------------------------------------------
// 写回口合并 (doc §6.1)
// ---------------------------------------------------------------------------
// 【仲裁规则: 不是"谁优先级高", 而是"谁等得起"】
//   写回口只有一个 (`resp_valid`)。两条流水同时在飞时谁让路, 判据是**物理能不能等**:
//     * `mul_pipe` 定延迟 2 拍、响应直接寄存、**没有输出缓冲** ⇒ 收下之后 T+2 那一拍
//       **必然**要口, 没有任何机制能让它推迟。它**等不起** ⇒ 乘法有响应时永远赢。
//     * `div_pipe` 慢、延迟不定 (n+4 拍), 但它的结果寄存器在 ST_RESP 里本来就是
//       静止的 ⇒ 给它一个 `resp_gnt` 就能等。所以除法让路, **举着结果等一拍**。
//   丢掉这条规则的后果是**静默的**: 老写法 `resp_is_div = ~mul_resp_mld & div_resp_mld`
//   在撞车时 `resp_valid` 照样拉高、但数据/tag 全是乘法的 ⇒ 除法的响应凭空消失,
//   而且消费侧 (`IU_md_pipe`) 的 `div_hold_vld` 靠 `resp_valid & resp_is_div` 清,
//   清不掉 ⇒ **整条 MD 通路永久卡死**。
//
// ⚠️ **当前配置下 `div_resp_gnt` 恒真、除法的等待一次也不会发生**, 因为:
//      `div_req = req_valid & req_is_div` (本文件 :76) —— 除法在飞期间 `req_op`
//      必须一直是除 op, 插一拍乘 op 就会让 `div_req` 掉 0、`abort` 拉高把除法打回
//      IDLE。**请求口是严格时分复用的 ⇒ 两条流水根本不可能同时在飞。**
//      所以 `mul_resp_mld & div_resp_mld` 恒假 (单元 TB 的 `probe_overlap` 在除法
//      飞行窗口的每一拍都插过一次乘 op, 实测 0 次同拍)。
//    ⇒ 这段保持是**防御性**的, 不是当前 bug 的修复。留着它的真正理由是让
//      `wb_grant` 这个端口**名副其实** —— 它的文档语义是"写回总线仲裁" (doc §3.2),
//      而在此之前它只门了乘法的**输入端** (`mul_ready`), **输出侧完全无视它**。
//    ⚠️ 换句话说: **别把这段当成"当前在修什么"来读**。它是把"静默丢结果 + 死锁"
//      换成"多举一拍", 代价是一个几乎走不到的状态。
assign div_resp_gnt  = wb_grant & ~mul_resp_vld;  // 口被乘法占着 / 外部未授权 ⇒ 除法等
assign div_resp_take = div_resp_vld & div_resp_gnt;

assign resp_valid  = mul_resp_vld | div_resp_take;
assign resp_is_div = div_resp_take;              // 只有**真被取走**的才算除法响应
assign resp_data   = mul_resp_vld ? mul_resp_data : div_resp_data;
assign resp_tag    = mul_resp_vld ? mul_resp_tag  : div_resp_tag;

// flush_tag 在顺序核 (P1) 里不参与比较: 重定向来自 WB 提交点, 在飞的乘法/除法
// 一定都比它年轻, 全清即可 (doc §6.3)。乱序核里把 flush_valid 换成
// "younger_than(stage_tag, flush_tag)" 的比较结果即可, 单元结构不变 ——
// 这个端口现在就留着, 免得 P2 再动接口 (doc §7 的 P1 收尾要求)。
wire unused_flush_tag = ^flush_tag;

endmodule
