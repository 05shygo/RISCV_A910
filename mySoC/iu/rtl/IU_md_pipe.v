`timescale 1ns / 1ps
`include "defines.vh"

// ---------------------------------------------------------------------------
// IU_md_pipe —— **IDU 的 MUL/DIV 发射口 ↔ 本仓 MUL_DIV 单元之间的适配级**。
//
// 【两套接口的差异】
//   IDU 给**两个独立发射口**: `idu_mult_{sel,iid,dst_preg,src0,src1,rslt_sel[3:0]}`
//                             `idu_div_{sel,iid,dst_vld,dst_preg,src0,src1,rslt_sel[3:0]}`
//   而 `MUL_DIV` 是**一个共用请求口 + 一个共用写回口**:
//     req_{valid,op,src0,src1,tag,src2,acc_mode} → resp_{valid,data,tag,is_div}
//     (内部仲裁写回口: mul > div)
//
//   ⚠️ 两个 `rslt_sel[3:0]` 是**独热且位序含义不同**:
//        mult: bit0=MUL bit1=MULH bit2=MULHSU bit3=MULHU   → MD_OP 0..3
//        div : bit0=DIV bit1=DIVU bit2=REM    bit3=REMU    → MD_OP 4..7
//      即同样的 bit 位置, 一个指乘法一个指除法 ⇒ 解码时必须先看是哪条口。
//
// ⚠️ 【两个口**可以同拍都发** —— 不要假设互斥】
//   交付的 IDU 里 `ct_idu_is_md` 被例化了**两次**: `x_ct_idu_is_mult` 与
//   `x_ct_idu_is_div` —— 乘、除是**两条独立的发射队列**, 各自的 `md_xx_issue_en`
//   独立 ⇒ 同拍可能既有 `idu_mult_sel` 又有 `idu_div_sel`。
//   而 `MUL_DIV` 只有**一个共用请求口** ⇒ 必须仲裁。这里的做法:
//     * 除法在飞时 (`div_hold_vld`) **乘法让路**, 由 `md_unit_stall` 压住乘法队列
//       (那一拍不发, 而不是发了被丢 —— 后者会静默销毁一条指令);
//     * 同时来且除法空闲时, 除法被收进保持寄存器, 乘法**当拍也让路** (下次再发)。
//
// ⚠️ **反压缺口 (交付侧的, 不是本模块的)**: `ct_idu_is_md` **没有单元忙的输入口**
//    —— 它只看自己表项 ready 就发 (`md_xx_issue_en = |md_entry_issue_en`)。
//    所以**本单元必须每拍都能收下请求**, 否则请求会被静默丢掉、那条指令永远不完成 ⇒
//    死等。当前 `MUL_DIV` 满足这一点 (乘法 II=1 恒可收; 除法口在 IDLE 那拍可收),
//    但**除法连发两条**时会撞上 `div_busy`。⇒ 见下面 `req_valid` 处的说明与
//    本模块做的**除法准入屏蔽**。
//
// 【tag = {iid, preg}】
//   `MUL_DIV` 的模块头写着"接口从第一天就带 tag, 换乱序核时只是把 tag 接到
//   rename/ROB, 单元本身一行不用改" —— 这里正是那个用法: 把 **iid 与 dst_preg
//   一起打包**进 tag (TAG_W 7 → 13)。这样写回时一次就拿回两样东西:
//     * `resp_tag[5:0]`  = dst_preg  → PRF 写地址
//     * `resp_tag[12:6]` = iid       → RTU 的完成口 (它按 iid 找 ROB 表项)
//   ⇒ 省掉一张"preg → iid"的 CAM。tag 在单元里只被寄存传递、从不参与运算
//     (见 mul_pipe/div_pipe 里 tag 只进 `_r` 寄存器), 所以加宽是安全的。
// ---------------------------------------------------------------------------
module IU_md_pipe (
    input  wire        cpu_clk,
    input  wire        cpu_rst,          // 高有效
    input  wire        idu_flush,        // = rtu_yy_xx_flush

    // ---------------- 来自 IDU 的 mult 发射口 ----------------
    input  wire        idu_mult_sel,
    input  wire [6:0]  idu_mult_iid,
    input  wire [5:0]  idu_mult_dst_preg,
    input  wire [31:0] idu_mult_src0,
    input  wire [31:0] idu_mult_src1,
    input  wire [3:0]  idu_mult_rslt_sel,   // 独热: MUL/MULH/MULHSU/MULHU

    // ---------------- 来自 IDU 的 div 发射口 ----------------
    input  wire        idu_div_sel,
    input  wire [6:0]  idu_div_iid,
    input  wire        idu_div_dst_vld,
    input  wire [5:0]  idu_div_dst_preg,
    input  wire [31:0] idu_div_src0,
    input  wire [31:0] idu_div_src1,
    input  wire [3:0]  idu_div_rslt_sel,    // 独热: DIV/DIVU/REM/REMU

    // ---------------- 写回 (由顶层仲裁到某个 PRF 写口) ----------------
    output wire        wb_preg_vld,
    output wire [5:0]  wb_preg_dupx,
    output wire        wb_preg_vld_dupx,
    output wire [31:0] wb_preg_data,
    output wire [63:0] wb_preg_expand,

    // ---------------- 完成回报给 RTU ----------------
    output wire        cmplt_vld,
    output wire [6:0]  cmplt_iid,

    // ---------------- 观察 / 给顶层做发射准入 ----------------
    output wire        mul_ready,        // 乘法口空 (II=1)
    output wire        div_busy,         // 除法忙 —— **这一拍别选它**
    output wire        resp_is_div,
    // 给 IDU 的**发射准入门控** —— 接到 `ct_idu_is_md` 新加的
    // `ctrl_md_unit_stall` 上。为什么必须接: 交付的 MD 队列**没有反压口**,
    // 而除法口只在 IDLE 那拍收请求 ⇒ 不设闸就会静默丢请求 (那条永远不完成 ⇒ 死等)。
    // 现在恒等于 `div_busy`; 粒度是"整个 MD 口", 也就是**除法在飞时乘法也让路**。
    // 代价是除法那 ~35 拍里乘法不发射 (M 扩展占比小, 先保正确)。
    // 想细粒度的话: 让顶层按 MD 队头 opcode 判断是不是除法再决定要不要挡。
    output wire        md_unit_stall
);

    localparam TAG_W = 13;               // {iid[6:0], dst_preg[5:0]}

    // ==========================================================
    //  1) 独热 → MD_OP 编码
    // ==========================================================
    // mult 口: bit0..3 → MD_OP 0..3
    reg [2:0] mul_idx;
    always @(*) begin
        if      (idu_mult_rslt_sel[1]) mul_idx = 3'd1;   // MULH
        else if (idu_mult_rslt_sel[2]) mul_idx = 3'd2;   // MULHSU
        else if (idu_mult_rslt_sel[3]) mul_idx = 3'd3;   // MULHU
        else                           mul_idx = 3'd0;   // MUL (含"没选中"的默认, sel 会挡住)
    end

    // div 口: bit0..3 → MD_OP 4..7
    reg [2:0] div_idx;
    always @(*) begin
        if      (idu_div_rslt_sel[1]) div_idx = 3'd1;    // DIVU
        else if (idu_div_rslt_sel[2]) div_idx = 3'd2;    // REM
        else if (idu_div_rslt_sel[3]) div_idx = 3'd3;    // REMU
        else                          div_idx = 3'd0;    // DIV
    end

    // ⚠️ MD_OP 是**三位**编码 (靠 `req_op[2]` 区分乘/除, 见 MUL_DIV.v:68-69), 不是四位!
    //    写成 `{1'b1, idx}` 会得到 8..11 —— `req_op[2]` 反而是 0, 于是**除法请求被
    //    当成乘法吞掉** (实测症状: 除法结果全是垃圾、div_busy 永不拉高)。
    //    所以下面的 `div_req_op` 用 `4'd4 + idx` 而不是 `{1'b1, idx}`。

    // ==========================================================
    //  2) **除法请求保持寄存器** (协议要求, 不是优化)
    // ==========================================================
    // ⚠️ `div_pipe` 的协议是"请求方**一直保持** req_vld 到 resp_vld":
    //      `abort = flush_vld | ((state != ST_IDLE) & ~req_vld);`  (div_pipe.v:160)
    //    ⇒ 请求中途撤销会被当成**被冲刷**, 除法立即中止、**不出结果**。
    //    而 IDU 的 MD 队列是"发一拍就弹表项"(`md_xx_issue_en` 单拍) ⇒ 直接把
    //    `idu_div_sel` 接到 `req_valid` 上, 除法**永远算不出结果**。
    //    (实测症状: 除法请求像被吞掉, `div_busy` 也不拉高, 200 拍等不到写回。)
    //
    //    这里用一个保持寄存器把它钉住: 收到就锁存, 保持到响应回来才放。
    //    乘法不需要 (II=1、单拍即可收)。
    // ⚠️ 这两根**必须在 always 块之前声明** —— 放在后面会变成"先用后声明",
    //    Verilog 会造一个隐式 1 位线网 (本仓栽过四次的坑)。
    wire             resp_valid;
    wire [31:0]      resp_data;
    wire [TAG_W-1:0] resp_tag;
    wire             div_resp_vld = resp_valid & resp_is_div;

    reg              div_hold_vld;
    reg  [2:0]       div_hold_idx;
    reg  [31:0]      div_hold_s0, div_hold_s1;
    reg  [6:0]       div_hold_iid;
    reg  [5:0]       div_hold_preg;

    // 只在**除法口真的空闲**时收新的 (div_busy 时上层应该已被 `md_unit_stall` 挡住;
    // 这里再挡一道, 保证"没被收下的不会挤掉在飞的那条")。
    wire div_accept = idu_div_sel & ~div_hold_vld & ~div_busy;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            div_hold_vld  <= 1'b0;
            div_hold_idx  <= 3'd0;
            div_hold_s0   <= 32'd0;
            div_hold_s1   <= 32'd0;
            div_hold_iid  <= 7'd0;
            div_hold_preg <= 6'd0;
        end
        else if (idu_flush) begin
            // 冲刷那拍放掉 —— 在飞的除法本来也会被 flush 中止。
            div_hold_vld  <= 1'b0;
        end
        else if (div_accept) begin
            div_hold_vld  <= 1'b1;
            div_hold_idx  <= div_idx;
            div_hold_s0   <= idu_div_src0;
            div_hold_s1   <= idu_div_src1;
            div_hold_iid  <= idu_div_iid;
            div_hold_preg <= idu_div_dst_preg;
        end
        else if (div_resp_vld) begin
            div_hold_vld  <= 1'b0;      // 收到响应才放 —— 这正是协议要的"保持到出结果"
        end
    end

    // 除法口的请求来自保持寄存器 (而不是当拍的 sel)
    wire        div_req_vld = div_hold_vld;
    wire [3:0]  div_req_op  = 4'd4 + {1'b0, div_hold_idx};
    wire [31:0] div_req_s0  = div_hold_s0;
    wire [31:0] div_req_s1  = div_hold_s1;
    wire [TAG_W-1:0] div_req_tag = {div_hold_iid, div_hold_preg};

    // 乘法口: 当拍收 (II=1)
    wire        mul_req_vld = idu_mult_sel & ~div_hold_vld;   // 除法在飞时不抢共用请求口
    wire [3:0]  mul_req_op  = {1'b0, mul_idx};

    // 请求口合并: 除法优先 (它必须连续保持), 乘法让路一拍
    wire        req_vld_mux = div_req_vld | mul_req_vld;
    wire [3:0]  req_op_mux  = div_req_vld ? div_req_op : mul_req_op;
    wire [31:0] req_s0_mux  = div_req_vld ? div_req_s0 : idu_mult_src0;
    wire [31:0] req_s1_mux  = div_req_vld ? div_req_s1 : idu_mult_src1;
    wire [TAG_W-1:0] req_tag_mux = div_req_vld ? div_req_tag
                                               : {idu_mult_iid, idu_mult_dst_preg};


    MUL_DIV #(.DATA_W(32), .TAG_W(TAG_W)) u_muldiv (
        .clk         (cpu_clk),
        .rst         (cpu_rst),
        .req_valid   (req_vld_mux),
        .req_op      (req_op_mux),
        .req_src0    (req_s0_mux),
        .req_src1    (req_s1_mux),
        .req_tag     (req_tag_mux),
        // MAC 累加口: 本核不用 (§4.6 的接口留着的), 恒 NONE
        .req_src2    (64'd0),
        .req_acc_mode(`MD_ACC_NONE),
        .mul_ready   (mul_ready),
        .div_busy    (div_busy),
        .resp_valid  (resp_valid),
        .resp_data   (resp_data),
        .resp_tag    (resp_tag),
        .resp_is_div (resp_is_div),
        // 写回口: 单元内部已经做了 mul > div 的仲裁 (MUL_DIV.v:126),
        // 所以这里**恒授权** —— 来了就收, 不让单元攒着。
        .wb_grant    (1'b1),
        // 冲刷: 全清。**为什么"全清"在这里是对的** —— 重定向那条指令能退休,
        // 就意味着所有比它老的都已经退了; 而还"在飞"的乘法/除法必然比它年轻
        // (老的若还在飞, 它就没退, 重定向那条也就退不了)。所以冲刷时刻在飞的
        // 都是错误路径上的, 全清不会误杀需要完成的那条。
        // (将来若要省, 把 flush_tag 接上重定向的 iid 做年龄比较即可 —— 单元结构不用改。)
        .flush_valid (idu_flush),
        .flush_tag   ({TAG_W{1'b0}})
    );

    // ==========================================================
    //  3) 写回 + 完成 (拆 tag)
    // ==========================================================
    // ⚠️ 写回**不打拍**: `resp_valid` 已经是单元寄存输出的; 再打一拍的话,
    //    `cmplt` 就比 PRF 写晚 —— 而 RTU 可能在写回落地前就让那条退休 ⇒
    //    difftest 读到旧值 (与 IU_alu_pipe 里"cmplt 与写回必须同拍"同一个理由)。
    wire [5:0] resp_preg = resp_tag[5:0];
    wire [6:0] resp_iid  = resp_tag[12:6];

    assign wb_preg_vld      = resp_valid;
    assign wb_preg_data     = resp_data;
    assign wb_preg_expand   = 64'd1 << resp_preg;
    assign wb_preg_dupx     = resp_preg;
    assign wb_preg_vld_dupx = resp_valid;

    assign cmplt_vld        = resp_valid;
    assign cmplt_iid        = resp_iid;

    assign md_unit_stall    = div_busy;

endmodule
