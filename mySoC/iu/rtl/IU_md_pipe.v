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
    // 取值见文件末尾 `assign md_unit_stall` 处的长注 —— **不是** `div_busy`。
    // 粒度是"整个 MD 口", 也就是**除法在飞时乘法也让路**。
    // 代价是除法那 ~35 拍里乘法不发射 (M 扩展占比小, 先保正确)。
    // 想细粒度的话: 让顶层按 MD 队头 opcode 判断是不是除法再决定要不要挡 ——
    // ⚠️ 但做之前**必须先把 `MUL_DIV` 的写回保持补上**, 理由见那里。
    output wire        md_unit_stall,

    // ---------------- 写回授权 (2026-10-18: 与 ALU1 共用 pipe2 时的仲裁接口) ----
    // ALU1 与 MD 抢 IDU 的 pipe2 写回口。MD 侧在 MUL_DIV 输出后加了一个 **2 项
    // skid FIFO**: 空时旁路 (resp_valid 当拍直接输出, 不增加常规延迟), 非空时
    // 先入队、等授权再写出。写回/完成都由 `md_out_* & md_wb_grant` 产生, 保持
    // "完成与真正落 PRF 的写回同拍" 这条硬契约。
    //
    // ⚠️ 本模块的 `wb_grant` 不再恒 1: 回送 MUL_DIV 的授权是 `(skid 为空)`。
    //   它同时门住 `mul_ready` (FIFO 非空时不再收新乘法) 和 `div_resp_gnt`
    //   (除法在 ST_RESP 举着等)。深度 2 的溢出安全性见下面 FIFO 段的长注。
    input  wire        md_wb_grant,
    output wire        md_wb_req,
    output wire [2:0]  md_skid_occ       // 观察口: 0..2
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

    // ==========================================================
    //  输出 skid FIFO (深度 2) —— 见端口处与下面 FIFO 段的说明
    // ==========================================================
    // ⚠️ 这些声明必须在 MUL_DIV 例化之前: `.wb_grant(mdiv_wb_grant)` 要用它。
    //    (本仓栽过多次"先用后声明 ⇒ 隐式 1 位线网"的坑, 见 eda-env-csh-vcs)
    reg              sk_vld   [0:1];
    reg  [31:0]      sk_data  [0:1];
    reg  [TAG_W-1:0] sk_tag   [0:1];
    reg              sk_is_div[0:1];
    reg  [2:0]       sk_cnt;            // 0..2

    wire             sk_empty = (sk_cnt == 3'd0);
    wire             mdiv_wb_grant = sk_empty;

    wire             md_out_vld  = sk_empty ? resp_valid  : sk_vld[0];
    wire [31:0]      md_out_data = sk_empty ? resp_data   : sk_data[0];
    wire [TAG_W-1:0] md_out_tag  = sk_empty ? resp_tag    : sk_tag[0];
    wire             md_out_is_div = sk_empty ? resp_is_div : sk_is_div[0];

    wire             md_out_take = md_out_vld & md_wb_grant;
    // 空时若本拍授权, 响应直接旁路 (不写 FIFO); 否则有响应就入队。
    wire             sk_push = resp_valid & ~(sk_empty & md_wb_grant);
    wire             sk_pop  = md_wb_grant & ~sk_empty;
    wire [2:0]       sk_cnt_nxt = sk_cnt + {2'd0, sk_push} - {2'd0, sk_pop};

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
        // 写回口: 单元内部已经做了 mul > div 的仲裁 (MUL_DIV.v:126)。
        // 授权 = skid 为空: 非空时 MUL_DIV 不再收新乘法 (mul_ready=0),
        // 除法则在 ST_RESP 举着结果等 (div_resp_gnt=0) —— 这正是防溢出的闸门。
        .wb_grant    (mdiv_wb_grant),
        // 冲刷: 全清。**为什么"全清"在这里是对的** —— 重定向那条指令能退休,
        // 就意味着所有比它老的都已经退了; 而还"在飞"的乘法/除法必然比它年轻
        // (老的若还在飞, 它就没退, 重定向那条也就退不了)。所以冲刷时刻在飞的
        // 都是错误路径上的, 全清不会误杀需要完成的那条。
        // (将来若要省, 把 flush_tag 接上重定向的 iid 做年龄比较即可 —— 单元结构不用改。)
        .flush_valid (idu_flush),
        .flush_tag   ({TAG_W{1'b0}})
    );

    // ==========================================================
    //  3) 输出 skid FIFO + 写回/完成
    // ==========================================================
    // 【为什么必须缓冲】原来 resp_valid 直接就是写回; 现在 pipe2 要与 ALU1
    // 共用, 乘法结果没有输出缓冲 (定延迟 2 拍), 抢不到口就会丢。skid 空时
    // 仍然是**组合旁路** (resp_valid 当拍写回, 零额外延迟), 只有抢输时才入队。
    //
    // 【深度 2 为什么够】乘/除请求口严格时分复用; FIFO 一旦非空, 回送
    // MUL_DIV 的 wb_grant=0 ⇒ 不再收新乘法、除法在 ST_RESP 举着。在飞的乘法
    // 最多 2 条 (M1/M2, 包括 div_accept 同拍收下的那条)。纯 RR 又保证: 只要
    // MD 有请求 (FIFO 非空就一定有), 它至少每两拍拿到一次授权 ⇒ 两次 push
    // 之间必有一次 pop。所以占用只会是 0→1→2→(pop/push 维持)→…, 不会到 3。
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            sk_cnt    <= 3'd0;
            sk_vld[0] <= 1'b0;
            sk_vld[1] <= 1'b0;
        end
        else if (idu_flush) begin
            // 在飞的乘/除会被 MUL_DIV 的 flush 清掉; FIFO 里存的是更老的结果,
            // 但它们同样属于被冲刷的错误路径 (顺序核重定向即全清)。
            sk_cnt    <= 3'd0;
            sk_vld[0] <= 1'b0;
            sk_vld[1] <= 1'b0;
        end
        else begin
            case ({sk_pop, sk_push})
                2'b10: begin // 只出
                    if (sk_cnt == 3'd2) begin
                        sk_vld[0]    <= sk_vld[1];
                        sk_data[0]   <= sk_data[1];
                        sk_tag[0]    <= sk_tag[1];
                        sk_is_div[0] <= sk_is_div[1];
                        sk_vld[1]    <= 1'b0;
                    end
                    else begin
                        sk_vld[0] <= 1'b0;
                    end
                    sk_cnt <= sk_cnt - 3'd1;
                end
                2'b01: begin // 只进
                    if (sk_cnt == 3'd0) begin
                        sk_vld[0]    <= 1'b1;
                        sk_data[0]   <= resp_data;
                        sk_tag[0]    <= resp_tag;
                        sk_is_div[0] <= resp_is_div;
                    end
                    else begin
                        sk_vld[1]    <= 1'b1;
                        sk_data[1]   <= resp_data;
                        sk_tag[1]    <= resp_tag;
                        sk_is_div[1] <= resp_is_div;
                    end
                    sk_cnt <= sk_cnt + 3'd1;
                end
                2'b11: begin // 同拍进出
                    if (sk_cnt == 3'd1) begin
                        // 队头被取走, 新响应直接占队头
                        sk_vld[0]    <= 1'b1;
                        sk_data[0]   <= resp_data;
                        sk_tag[0]    <= resp_tag;
                        sk_is_div[0] <= resp_is_div;
                    end
                    else begin // sk_cnt == 2
                        sk_vld[0]    <= sk_vld[1];
                        sk_data[0]   <= sk_data[1];
                        sk_tag[0]    <= sk_tag[1];
                        sk_is_div[0] <= sk_is_div[1];
                        sk_vld[1]    <= 1'b1;
                        sk_data[1]   <= resp_data;
                        sk_tag[1]    <= resp_tag;
                        sk_is_div[1] <= resp_is_div;
                    end
                    // sk_cnt 不变
                end
                default: ;
            endcase
        end
    end

    // 写回 + 完成: 都只在真正拿到授权的那一拍有效, 而且同拍。
    // ⚠️ 改成寄存/入队后依然保持 "cmplt 与 PRF 写同拍" —— 未授权时完成不提前。
    wire [5:0] md_out_preg = md_out_tag[5:0];
    wire [6:0] md_out_iid  = md_out_tag[12:6];

    assign md_wb_req        = md_out_vld;
    assign md_skid_occ      = sk_cnt;

    assign wb_preg_vld      = md_out_take;
    assign wb_preg_data     = md_out_data;
    assign wb_preg_expand   = {64{md_out_take}} & (64'd1 << md_out_preg);
    assign wb_preg_dupx     = md_out_preg;
    assign wb_preg_vld_dupx = md_out_take;

    assign cmplt_vld        = md_out_take;
    assign cmplt_iid        = md_out_iid;

    // ==========================================================
    //  4) 发射准入门控 —— **必须把 div_hold_vld 一起算进去**
    // ==========================================================
    // ⚠️ 2026-10-11 修: 原先是 `= div_busy`, **晚了一拍**, 会静默丢指令。
    //
    // 洞在除法被收下、但 div_pipe 还没开始跑的那一拍。设 A = IDU 发 `idu_div_sel`:
    //
    //   拍   | div_hold_vld | div_pipe state | div_busy | 单元实际收不收
    //   -----+--------------+----------------+----------+------------------
    //    A   |      0       |    ST_IDLE     |    0     | 收 (进保持寄存器)
    //   A+1  |      1       |  **ST_IDLE**   |  **0**   | **两个口都不收**
    //   A+2  |      1       |    ST_PREP     |    1     | (已被挡住)
    //
    // A+1 拍 `div_busy` 为什么还是 0: 保持寄存器刚置起, 请求这一拍才**第一次**
    // 出现在 `div_req_vld` 上, 状态要到 A+1 边沿才跳 ST_PREP。
    //
    // 于是若只接 `div_busy`, A+1 拍 IDU 看到 stall=0 就照发 (`md_xx_issue_en`
    // 是单拍脉冲, 发射队列**当拍已把表项 pop 掉**), 而这边
    //     `div_accept   = idu_div_sel & ~div_hold_vld & ~div_busy` = 0
    //     `mul_req_vld  = idu_mult_sel & ~div_hold_vld`          = 0
    // 两边都不接 ⇒ **那条指令凭空蒸发**, RTU 的表项永远不完成 ⇒ 死等。
    // 触发条件很普通: 背靠背两条除, 或除在 A 拍发、任一条乘紧跟着在 A+1 拍发。
    //
    // 修法就是把"保持寄存器已占住"也算进忙: div_busy 覆盖 [A+2, R], div_hold_vld
    // 覆盖 [A+1, R], 或起来正好把 A+1 这个窗口补上。不影响 A 拍 (两者皆 0,
    // 第一条正常进), 也不影响"同拍发一乘一除" (A 拍两个队列都能发: 除进保持
    // 寄存器、乘上共用请求口, 互不冲突)。
    //
    // 回归: `make iu-md-unit` —— 新增的"反压闭环"一段按 IDU 语义驱动 (只看
    //       md_unit_stall), 判据是"发出条数 == 写回条数"。改回 `div_busy` 会
    //       立刻在"背靠背两条除"上报丢指令。
    // ⚠️ 别用 `div_accept` 那种兜底代替这里: 它是**静默丢弃**, 不是反压 ——
    //    丢弃发生在 IDU 已经 pop 表项之后, 补救不回来。
    //
    // ⚠️⚠️ 2026-10-15 修: **还要把 `div_accept` 本身并进来**, 上面那张表少盖了一拍。
    //
    // 【为什么】`idu_div_sel` **不是**发射队列的 `md_xx_issue_en`, 而是它**打了一拍**
    //   的结果 —— `ct_idu_rf_ctrl.sv:117` 的 `rf_pipe2_inst_vld <= div_xx_issue_en`
    //   (RF pipedown 寄存器)。所以"队列发"和"单元看到请求"差一拍:
    //
    //     拍     | 队列 (issue_en)      | 单元看到的 idu_div_sel | 单元收不收
    //     -------+----------------------+------------------------+-----------
    //      A     | 发第 1 条 (ie=1)     | 0                      | —
    //      A+1   | 发第 2 条 ← **要挡这** | 第 1 条                | 收 (hold←1)
    //      A+2   | (已被挡住)            | 第 2 条                | **丢掉**
    //
    //   旧式 `div_busy | div_hold_vld` 在第 A+1 拍两个都是 0 (hold 要到 A+1 末尾才置起)
    //   ⇒ 队列以为空闲、照发第 2 条 ⇒ 第 2 条发出后 `div_accept = sel & ~hold & ~busy = 0`、
    //     `mul_req_vld = 0`, **两个口都不接, 静默蒸发** —— 而队列那一拍已经把表项 pop 掉了。
    //
    // 【症状】coremark_i1 `core_print_int` 的 0x1e2c..0x1e50 循环里 `remu`/`divu` 背靠背
    //   (队列里同时挂着两条除), 第二条 DIVU 被丢 ⇒ 那条 ROB 表项的 cmplt 永远不置
    //   ⇒ **顺序退休卡死**(累计退休 328731 停住, 队头 pc=0x1e48, 3M 拍不再动)。
    //   单元级的 `make iu-md-unit` 原来测不出来: 那个 TB 把 IDU 建模成"当拍发"
    //   (same-cycle), 正好绕开了这一拍的延迟。**该 TB 已同步修** (补了一级发射流水线
    //   寄存器 + 摆完端口要 `#1` 再读 stall), 现在三种背靠背/混发场景都能抓到这类洞。
    //
    // 【取值】`div_accept` = 这一拍**正在被收下**的除法请求 ⇒ 下一拍单元必然不空,
    //   所以"收下那一拍"就必须把队列挡住。三项并起来覆盖 [A, R] 整段。
    //   不影响"同拍一乘一除": 那一拍 div_accept=1 ⇒ stall=1 ⇒ **两条队列都不发**,
    //   下一个空闲拍才发 (除法先被收进保持寄存器、乘法上共用口), 顺序不变、只晚一拍。
    // ⚠️ 2026-10-18 补: skid 占用也要算进来, 而且要用**下一拍的占用**
    //   `sk_cnt_nxt = sk_cnt + push - pop`。理由与上面的 `div_accept` 完全同型:
    //   队列在第 T 拍看到 stall、第 T+1 拍才把请求摆到 `idu_*_sel` 上。若只看
    //   `sk_cnt` (本拍), FIFO 会在 T+1 拍变非空 ⇒ MUL_DIV 的 `mul_ready=0`,
    //   而请求已经摆出来了 ⇒ **静默丢一条乘法**。用 occ_nxt 才是 IDU 视角。
    //   对除法口这个项偏保守 (div_accept 本身不受 skid 影响), 但 M 扩展占比小,
    //   统一挡住更简单、也不会丢指令。
    assign md_unit_stall    = div_busy | div_hold_vld | div_accept
                            | (sk_cnt_nxt != 3'd0);

endmodule
