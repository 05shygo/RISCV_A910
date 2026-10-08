`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_idu_lsu_adapter —— 自研 RTU ↔ 同事交付的 C910 IDU / LSU 之间的**适配层**。
//
// 【为什么需要单独一层】
// RTU 的 §6 契约与同事交付的 IP 之间有四类系统性差异。这些差异**不该**散落在
// 顶层接线里（那样每次看波形都要重新推一遍），统一收在这一层：
//
//   1. **preg 位宽**: RTU 端口一律 7 位（= log2(96)，不随档变），IDU 是 6 位。
//      PREG=64 档下 RTU 侧最高位恒 0 ⇒ 出方向切 `[5:0]`，入方向补 0。
//   2. **恢复表布局**: `rtu_ren_recover_map` 是 32×7（`[7*l +: 7]`），
//      IDU 的 `rtu_idu_rt_recover_preg` 是 32×6（`[6*l +: 6]`）。
//      **不是切低位就完事** —— 是逐槽重排，见下面 genvar 那段。
//   3. **复位极性**: RTU 是 `cpu_rst` 高有效，IDU/LSU 是 `cpurst_b` 低有效。
//   4. **语义编解码**: 三路独立请求 → 程序序前缀计数；两个访存异常源 → 单路
//      "最旧者胜"；store 重放两根 → 一根。
//
// 【本层刻意不做的事】
//   * 不碰 §6.1 的派遣记录字段 —— 那些在 IDU 侧已经按 RTU 的契约打包好了
//     （见 ct_idu_top 末尾的打包块），这里只改名不做变换。
//   * 不做 CSR / PRF / BEU 的接线 —— 那些是"和第三方的接口"，直接拿 RTU 的
//     端口名接在顶层，绕开本层不用翻译。
//
// 端口命名约定：**本模块两侧分别沿用对方的名字**
//   * `idu_*` / `lsu_*` 前缀 = 同事那边的原端口名，顶层 1:1 接过去即可；
//   * 其余 = RTU 的原端口名，同样 1:1。
//   所以这一层"不像适配器、更像一面镜子"—— 所有真正的变换都集中在下面那几个
//   标了 ⚠️ 的 assign 上，一眼能找到。
// ---------------------------------------------------------------------------
module RTU_idu_lsu_adapter (
    // ===================== 时钟 / 复位 =====================
    input  wire        cpu_clk,          // RTU 口径时钟（= forever_cpuclk，同一根）
    input  wire        cpu_rst,          // RTU 口径复位，**高有效**
    output wire        cpurst_b,         // IDU/LSU 口径复位，**低有效**（本层就地反相）

    // ============================================================
    //  IDU 侧 —— 下面这些名字就是 ct_idu_top 的原端口名
    // ============================================================
    // ---- §6.0 分配握手 (IDU → 本层 → RTU) ----
    input  wire        idu_rtu_ir_preg0_alloc_vld,
    input  wire        idu_rtu_ir_preg1_alloc_vld,
    input  wire        idu_rtu_ir_preg2_alloc_vld,
    output wire [5:0]  rtu_idu_alloc_preg0,
    output wire [5:0]  rtu_idu_alloc_preg1,
    output wire [5:0]  rtu_idu_alloc_preg2,
    output wire        rtu_idu_alloc_preg0_vld,
    output wire        rtu_idu_alloc_preg1_vld,
    output wire        rtu_idu_alloc_preg2_vld,

    // ---- iid 回执 / 停派遣 ----
    output wire [6:0]  rtu_idu_rob_inst0_iid,
    output wire [6:0]  rtu_idu_rob_inst1_iid,
    output wire [6:0]  rtu_idu_rob_inst2_iid,
    output wire        rtu_idu_rob_full,

    // ---- 冲刷 / 映射恢复 ----
    output wire        rtu_yy_xx_flush,
    output wire [191:0] rtu_idu_rt_recover_preg,

    // ---- 释放否决掩码（第 5 态 RELEASE）----
    input  wire [63:0] idu_rtu_pst_preg_dealloc_mask,

    // ---- §6.1 派遣记录（3 路 × 12 字段，IDU 侧已按 RTU 契约打包好）----
    input  wire        idu_rtu_disp0_vld,
    input  wire [31:0] idu_rtu_disp0_pc,
    input  wire [24:0] idu_rtu_disp0_chk,
    input  wire [4:0]  idu_rtu_disp0_dst_lreg,
    input  wire        idu_rtu_disp0_rf_we,
    input  wire [6:0]  idu_rtu_disp0_dst_preg,
    input  wire [6:0]  idu_rtu_disp0_old_preg,
    input  wire [6:0]  idu_rtu_disp0_src1_preg,
    input  wire [11:0] idu_rtu_disp0_csr_addr,
    input  wire [2:0]  idu_rtu_disp0_csr_op,
    input  wire [4:0]  idu_rtu_disp0_csr_imm,
    input  wire [6:0]  idu_rtu_disp0_flags,

    input  wire        idu_rtu_disp1_vld,
    input  wire [31:0] idu_rtu_disp1_pc,
    input  wire [24:0] idu_rtu_disp1_chk,
    input  wire [4:0]  idu_rtu_disp1_dst_lreg,
    input  wire        idu_rtu_disp1_rf_we,
    input  wire [6:0]  idu_rtu_disp1_dst_preg,
    input  wire [6:0]  idu_rtu_disp1_old_preg,
    input  wire [6:0]  idu_rtu_disp1_src1_preg,
    input  wire [11:0] idu_rtu_disp1_csr_addr,
    input  wire [2:0]  idu_rtu_disp1_csr_op,
    input  wire [4:0]  idu_rtu_disp1_csr_imm,
    input  wire [6:0]  idu_rtu_disp1_flags,

    input  wire        idu_rtu_disp2_vld,
    input  wire [31:0] idu_rtu_disp2_pc,
    input  wire [24:0] idu_rtu_disp2_chk,
    input  wire [4:0]  idu_rtu_disp2_dst_lreg,
    input  wire        idu_rtu_disp2_rf_we,
    input  wire [6:0]  idu_rtu_disp2_dst_preg,
    input  wire [6:0]  idu_rtu_disp2_old_preg,
    input  wire [6:0]  idu_rtu_disp2_src1_preg,
    input  wire [11:0] idu_rtu_disp2_csr_addr,
    input  wire [2:0]  idu_rtu_disp2_csr_op,
    input  wire [4:0]  idu_rtu_disp2_csr_imm,
    input  wire [6:0]  idu_rtu_disp2_flags,

    // ============================================================
    //  LSU 侧 —— 下面是 lsu_top 面向 RTU 的原端口名
    // ============================================================
    input  wire        lsu_rtu_wb_pipe3_cmplt,      // load 完成
    input  wire [6:0]  lsu_rtu_wb_pipe3_iid,
    input  wire        lsu_rtu_wb_pipe3_expt_vld,   // load 非对齐
    input  wire [31:0] lsu_rtu_wb_pipe3_expt_addr,
    input  wire        lsu_rtu_wb_pipe4_cmplt,      // store 完成
    input  wire [6:0]  lsu_rtu_wb_pipe4_iid,
    input  wire        lsu_rtu_wb_pipe4_expt_vld,   // store 非对齐
    input  wire [31:0] lsu_rtu_wb_pipe4_expt_addr,
    input  wire        lsu_rtu_wb_pipe4_flush,      // store 投机写失败
    input  wire        lsu_rtu_wb_pipe4_spec_fail,

    // ============================================================
    //  其它异常源（非法指令 / 取指故障 …）—— 由顶层喂进来，
    //  本层把它和 LSU 那两个源一起做**单路"最旧者胜"**仲裁
    // ============================================================
    input  wire        other_expt_vld,
    input  wire [6:0]  other_expt_iid,
    input  wire [4:0]  other_expt_cause,
    input  wire [31:0] other_expt_tval,

    // ============================================================
    //  RTU 侧 —— 下面这些就是 RTU 的原端口名
    // ============================================================
    // ---- §6.0 ----
    output wire [1:0]  ren_preg_req,
    output wire [4:0]  ren_preg_req_lreg0,
    output wire [4:0]  ren_preg_req_lreg1,
    output wire [4:0]  ren_preg_req_lreg2,
    input  wire [6:0]  rtu_preg_alloc0,
    input  wire [6:0]  rtu_preg_alloc1,
    input  wire [6:0]  rtu_preg_alloc2,
    input  wire        rtu_preg_alloc_vld0,
    input  wire        rtu_preg_alloc_vld1,
    input  wire        rtu_preg_alloc_vld2,

    // ---- §6.1 派遣 ----
    output wire        disp0_vld,
    output wire [31:0] disp0_pc,
    output wire [24:0] disp0_chk,
    output wire [4:0]  disp0_dst_lreg,
    output wire        disp0_rf_we,
    output wire [6:0]  disp0_dst_preg,
    output wire [6:0]  disp0_old_preg,
    output wire [6:0]  disp0_src1_preg,
    output wire [11:0] disp0_csr_addr,
    output wire [2:0]  disp0_csr_op,
    output wire [4:0]  disp0_csr_imm,
    output wire [6:0]  disp0_flags,
    output wire [2:0]  disp0_sq_id,

    output wire        disp1_vld,
    output wire [31:0] disp1_pc,
    output wire [24:0] disp1_chk,
    output wire [4:0]  disp1_dst_lreg,
    output wire        disp1_rf_we,
    output wire [6:0]  disp1_dst_preg,
    output wire [6:0]  disp1_old_preg,
    output wire [6:0]  disp1_src1_preg,
    output wire [11:0] disp1_csr_addr,
    output wire [2:0]  disp1_csr_op,
    output wire [4:0]  disp1_csr_imm,
    output wire [6:0]  disp1_flags,
    output wire [2:0]  disp1_sq_id,

    output wire        disp2_vld,
    output wire [31:0] disp2_pc,
    output wire [24:0] disp2_chk,
    output wire [4:0]  disp2_dst_lreg,
    output wire        disp2_rf_we,
    output wire [6:0]  disp2_dst_preg,
    output wire [6:0]  disp2_old_preg,
    output wire [6:0]  disp2_src1_preg,
    output wire [11:0] disp2_csr_addr,
    output wire [2:0]  disp2_csr_op,
    output wire [4:0]  disp2_csr_imm,
    output wire [6:0]  disp2_flags,
    output wire [2:0]  disp2_sq_id,

    // ---- §6.1 完成口 5/6（LSU 读 / 写）----
    output wire        cmplt_vld5,
    output wire [6:0]  cmplt_iid5,
    output wire        cmplt_vld6,
    output wire [6:0]  cmplt_iid6,

    // ---- §6.1 store 重放 ----
    output wire        lsu_replay_vld,
    output wire [6:0]  lsu_replay_iid,

    // ---- §6.1 异常（单路收集口，最旧者胜）----
    output wire        expt_vld,
    output wire [6:0]  expt_iid,
    output wire [4:0]  expt_cause,
    output wire [31:0] expt_tval,

    // ---- §6.1 存储队列 / 释放否决 ----
    output wire        sq_rdy0,
    output wire        sq_rdy1,
    output wire        sq_rdy2,
    output wire        sq_stall,
    output wire [63:0] preg_dealloc_mask,

    // ---- 停派遣 / 映射恢复（回给 IDU）----
    input  wire        rtu_disp_stall,
    input  wire        rtu_ren_flush,
    input  wire        rtu_backend_flush,
    input  wire [223:0] rtu_ren_recover_map,
    input  wire [6:0]  rtu_disp_iid0,
    input  wire [6:0]  rtu_disp_iid1,
    input  wire [6:0]  rtu_disp_iid2,

    // ---- 观察口（原样引出，接不接由顶层定）----
    input  wire [1:0]  rtu_preg_free_cnt
);

    // ============================================================
    //  1) 复位极性：RTU 高有效 ↔ IDU/LSU 低有效
    // ============================================================
    assign cpurst_b = ~cpu_rst;

    // ============================================================
    //  2) §6.0 分配握手
    // ============================================================
    // ⚠️ **三路独立请求 vld → "程序序前缀"计数**。
    //    §6.0 的车道语义写死为: `ren_preg_req = n` 表示**车道 0..n-1 是请求者**。
    //    IDU 给的是三根独立 vld（`idu_rtu_ir_preg{k}_alloc_vld`），而它那边的
    //    停顿链天然保证"请求是前缀"（同一根 `ctrl_ir_stall` 门控三路）⇒ 数个数
    //    就是前缀长度，不用再判合法性。
    //    ⚠️ 这条"请求 ⟺ 取走"是硬契约：请求了却不派遣也不冲刷，那个号会永久停在
    //       WF_ALLOC（年龄回收已删）。IDU 天然满足（请求、RAT 写、进 IS 由同一个
    //       `!ctrl_ir_stall` 门控）。
    assign ren_preg_req[1:0] = {1'b0, idu_rtu_ir_preg0_alloc_vld}
                             + {1'b0, idu_rtu_ir_preg1_alloc_vld}
                             + {1'b0, idu_rtu_ir_preg2_alloc_vld};

    // ⚠️ **填非零常量**。RTU 只拿这三根判"是不是 x0 那一路"（`lreg == 0` 的那路不给号），
    //    而 IDU 的请求本身在产生时就已经排除了 x0（条件里有 `!..._dst_x0`）⇒
    //    给非零常量即可，不需要真的把 dst lreg 引出来。
    assign ren_preg_req_lreg0 = 5'd1;
    assign ren_preg_req_lreg1 = 5'd1;
    assign ren_preg_req_lreg2 = 5'd1;

    // ⚠️ **preg 7 → 6 切位**：PREG=64 档下 RTU 侧最高位恒 0。
    //    （IDU 的端口是 6 位，给 7 位会隐式截断；这里显式切，免得将来读的人以为是漏接。）
    assign rtu_idu_alloc_preg0[5:0] = rtu_preg_alloc0[5:0];
    assign rtu_idu_alloc_preg1[5:0] = rtu_preg_alloc1[5:0];
    assign rtu_idu_alloc_preg2[5:0] = rtu_preg_alloc2[5:0];
    assign rtu_idu_alloc_preg0_vld   = rtu_preg_alloc_vld0;
    assign rtu_idu_alloc_preg1_vld   = rtu_preg_alloc_vld1;
    assign rtu_idu_alloc_preg2_vld   = rtu_preg_alloc_vld2;

    // ============================================================
    //  3) iid 回执 / 停派遣
    // ============================================================
    // 位宽/相位两边完全对齐（都是"create 指针寄存器 + 组合"）。
    assign rtu_idu_rob_inst0_iid[6:0] = rtu_disp_iid0[6:0];
    assign rtu_idu_rob_inst1_iid[6:0] = rtu_disp_iid1[6:0];
    assign rtu_idu_rob_inst2_iid[6:0] = rtu_disp_iid2[6:0];
    assign rtu_idu_rob_full           = rtu_disp_stall;

    // ============================================================
    //  4) 冲刷：两根或起来
    // ============================================================
    // ⚠️ **别接 `rtu_core_redirect`**！那根是 T 拍的"核内重定向事件"，
    //    而 IDU/LSU 要的是 T+1 拍的 backend flush（与它们自己的流水相位对齐）。
    //    `rtu_ren_flush` 与 `rtu_backend_flush` 是同一拍同值（§6.2），
    //    这里两根都或上只是为了不依赖"它们恒相等"这个实现细节。
    assign rtu_yy_xx_flush = rtu_ren_flush | rtu_backend_flush;

    // ============================================================
    //  5) ⚠️ 映射恢复表：32×7 → 32×6 **逐槽重排**
    // ============================================================
    // 两侧都是"32 个逻辑寄存器的架构映射"，但**每槽的位宽不同**：
    //     RTU 侧 `rtu_ren_recover_map[223:0]`：`[7*l +: 7]` = x_l 的映射（7 位）
    //     IDU 侧 `rtu_idu_rt_recover_preg[191:0]`：`[6*l +: 6]` = x_l 的映射（6 位）
    // ⇒ **不是切低位就完事**（那样会把 32 个槽整体错位），必须逐槽搬。
    //    PREG=64 档下每槽的高位恒 0，所以搬低 6 位即可。
    // 写法说明：不能写 `map[7*l +: 7][5:0]`（对内层的位选再切片，语法不允许）。
    // 每槽的低 6 位 = `map[7*l +: 6]` —— 直接这样取，等价且更短。
    genvar l;
    generate
        for (l = 0; l < 32; l = l + 1) begin : gen_recover_repack
            assign rtu_idu_rt_recover_preg[6*l +: 6] = rtu_ren_recover_map[7*l +: 6];
        end
    endgenerate

    // ============================================================
    //  6) §6.1 派遣记录 —— 原样透传（IDU 侧已按契约打包）
    // ============================================================
    // 这里**一个字段都不变换**：dst_preg/old_preg/src1_preg 在 IDU 侧已经从 6 位补成
    // 7 位，flags 已按 RTU_FLG_* 排好，csr_op 已是 funct3 原样，dst_lreg 已按 A6d 掩过。
    assign disp0_vld       = idu_rtu_disp0_vld;
    assign disp0_pc        = idu_rtu_disp0_pc;
    assign disp0_chk       = idu_rtu_disp0_chk;
    assign disp0_dst_lreg  = idu_rtu_disp0_dst_lreg;
    assign disp0_rf_we     = idu_rtu_disp0_rf_we;
    assign disp0_dst_preg  = idu_rtu_disp0_dst_preg;
    assign disp0_old_preg  = idu_rtu_disp0_old_preg;
    assign disp0_src1_preg = idu_rtu_disp0_src1_preg;
    assign disp0_csr_addr  = idu_rtu_disp0_csr_addr;
    assign disp0_csr_op    = idu_rtu_disp0_csr_op;
    assign disp0_csr_imm   = idu_rtu_disp0_csr_imm;
    assign disp0_flags     = idu_rtu_disp0_flags;
    // ⚠️ `sq_id` **恒 0**：IDU 那边有意没有引出来（它的 SDIQ 不是 LSU 的 SQ，
    //    且 LSU 按 iid 广播找表项）。见 doc/DELIVERY_FIXES_2026-10-08.md §6。
    assign disp0_sq_id     = 3'd0;

    assign disp1_vld       = idu_rtu_disp1_vld;
    assign disp1_pc        = idu_rtu_disp1_pc;
    assign disp1_chk       = idu_rtu_disp1_chk;
    assign disp1_dst_lreg  = idu_rtu_disp1_dst_lreg;
    assign disp1_rf_we     = idu_rtu_disp1_rf_we;
    assign disp1_dst_preg  = idu_rtu_disp1_dst_preg;
    assign disp1_old_preg  = idu_rtu_disp1_old_preg;
    assign disp1_src1_preg = idu_rtu_disp1_src1_preg;
    assign disp1_csr_addr  = idu_rtu_disp1_csr_addr;
    assign disp1_csr_op    = idu_rtu_disp1_csr_op;
    assign disp1_csr_imm   = idu_rtu_disp1_csr_imm;
    assign disp1_flags     = idu_rtu_disp1_flags;
    assign disp1_sq_id     = 3'd0;

    assign disp2_vld       = idu_rtu_disp2_vld;
    assign disp2_pc        = idu_rtu_disp2_pc;
    assign disp2_chk       = idu_rtu_disp2_chk;
    assign disp2_dst_lreg  = idu_rtu_disp2_dst_lreg;
    assign disp2_rf_we     = idu_rtu_disp2_rf_we;
    assign disp2_dst_preg  = idu_rtu_disp2_dst_preg;
    assign disp2_old_preg  = idu_rtu_disp2_old_preg;
    assign disp2_src1_preg = idu_rtu_disp2_src1_preg;
    assign disp2_csr_addr  = idu_rtu_disp2_csr_addr;
    assign disp2_csr_op    = idu_rtu_disp2_csr_op;
    assign disp2_csr_imm   = idu_rtu_disp2_csr_imm;
    assign disp2_flags     = idu_rtu_disp2_flags;
    assign disp2_sq_id     = 3'd0;

    // ============================================================
    //  7) §6.1 完成口 5/6 —— LSU 读 / 写
    // ============================================================
    assign cmplt_vld5 = lsu_rtu_wb_pipe3_cmplt;
    assign cmplt_iid5 = lsu_rtu_wb_pipe3_iid;
    assign cmplt_vld6 = lsu_rtu_wb_pipe4_cmplt;
    assign cmplt_iid6 = lsu_rtu_wb_pipe4_iid;

    // ============================================================
    //  8) §6.1 store 重放
    // ============================================================
    // LSU 的 `pipe4_flush` / `pipe4_spec_fail` 对 RTU 是**同一个动作**（这条 store
    // 的投机结果错了 ⇒ 要重放），所以或起来。（C910 里也是跟完成一起报的两根，
    // 见 ct_lsu_st_wb.v:334-335。）
    assign lsu_replay_vld = lsu_rtu_wb_pipe4_flush | lsu_rtu_wb_pipe4_spec_fail;
    assign lsu_replay_iid = lsu_rtu_wb_pipe4_iid;

    // ============================================================
    //  9) ⚠️ 异常：三源 → 单路，**先门控、再取最旧**
    // ============================================================
    // 【为什么必须门控】
    //   `lsu_rtu_wb_pipe3_expt_vld` 曾经与 `cmplt` 相位不一致（lsu_ld_wb 的 always
    //   缺 begin/end，2026-10-08 已修）。**这里仍然显式相与**，理由有两条：
    //     ① 修完之后相位一致是"实现保证"，而本层是**跨人契约的边界**，不该依赖它；
    //     ② RTU 的异常是"按 iid 命中表项"的 —— 若 expt_vld 在没有指令完成的那拍
    //        为 1，那拍的 `_iid` 是**残留值**，RTU 会按错误的 iid 报异常，静默错。
    // 【为什么必须比 iid】
    //   RTU 的异常口只有**一路**（D9 的"全局单表项、最旧者胜"），而 load 与 store
    //   是**两条独立流水**、可以同拍都报。RTU 手里的比较只能拿"已经收下的"比，
    //   所以**丢哪一条是适配层决定的**：丢错（丢了年长的那条）会让它按正常流程
    //   退休走掉、异常**永久丢失**（它不会被重取 —— 冲刷只冲比 trap 那条更年轻的）。
    //   ⇒ 这里用 RTU 同款的年龄比较器（`RTU_iid_cmp`）选最旧的那条送出去。
    //   ⚠️ `RTU_iid_cmp` 的模块头写明"只许给异常/中断用，不许进重定向链" ——
    //      这里正是异常路径，符合它的定位。
    wire ld_expt_gated = lsu_rtu_wb_pipe3_cmplt & lsu_rtu_wb_pipe3_expt_vld;
    wire st_expt_gated = lsu_rtu_wb_pipe4_cmplt & lsu_rtu_wb_pipe4_expt_vld;

    // 第一级：load vs store
    wire ld_older_than_st;
    RTU_iid_cmp u_expt_cmp_lsu (
        .x_iid0     (lsu_rtu_wb_pipe3_iid),
        .x_iid1     (lsu_rtu_wb_pipe4_iid),
        .x_iid0_older(ld_older_than_st)
    );
    wire pick_ld = ld_expt_gated & (~st_expt_gated | ld_older_than_st);
    wire pick_st = st_expt_gated & ~pick_ld;

    wire        lsu_expt_vld   = pick_ld | pick_st;
    wire [6:0]  lsu_expt_iid   = pick_ld ? lsu_rtu_wb_pipe3_iid : lsu_rtu_wb_pipe4_iid;
    // cause 由**是哪条流水**决定（LSU 只给地址，不给 cause）：
    //   load  非对齐 → 4 (EXC_LOAD_MISALIGNED)
    //   store 非对齐 → 6 (EXC_STORE_MISALIGNED)   见 defines.vh:301/303
    wire [4:0]  lsu_expt_cause = pick_ld ? 5'd4 : 5'd6;
    wire [31:0] lsu_expt_tval  = pick_ld ? lsu_rtu_wb_pipe3_expt_addr
                                         : lsu_rtu_wb_pipe4_expt_addr;

    // 第二级：LSU 汇总 vs "其它源"（非法指令 / 取信故障 …）
    wire other_older_than_lsu;
    RTU_iid_cmp u_expt_cmp_other (
        .x_iid0     (other_expt_iid),
        .x_iid1     (lsu_expt_iid),
        .x_iid0_older(other_older_than_lsu)
    );
    wire pick_other = other_expt_vld & (~lsu_expt_vld | other_older_than_lsu);
    wire pick_lsu   = lsu_expt_vld & ~pick_other;

    assign expt_vld   = pick_other | pick_lsu;
    assign expt_iid   = pick_other ? other_expt_iid   : lsu_expt_iid;
    assign expt_cause = pick_other ? other_expt_cause : lsu_expt_cause;
    assign expt_tval  = pick_other ? other_expt_tval  : lsu_expt_tval;

    // ============================================================
    // 10) §6.1 存储队列 / 释放否决掩码
    // ============================================================
    // ⚠️ `sq_rdy*` / `sq_stall` **LSU 侧还没有产生**（lsu_top 没有对应输出）。
    //    这里按"顺序提交、数据就绪"的当前假设恒接：`sq_rdy*=1`（store 数据永远就绪，
    //    因为发射当拍就进 SQ）、`sq_stall=0`。
    //    ⚠️ `sq_rdy*` **绝不能接 0** —— 那会让每一条 store 都永远退不了休（死锁）。
    //    详见 doc/rtu_接口对照表.csv 的 RTU↔LSU 表「需新增」两条。
    assign sq_rdy0   = 1'b1;
    assign sq_rdy1   = 1'b1;
    assign sq_rdy2   = 1'b1;
    assign sq_stall  = 1'b0;

    // 释放否决掩码：位 = 1 ⇒ 这个号还被 store 引用着，不许回池（第 5 态 RELEASE）。
    // ⚠️ 交付的 IDU 里 SDIQ 的 `src_mask_clk` 原来全仓无驱动 ⇒ 这根恒 0。
    //    2026-10-08 已把那个时钟接上，所以现在它是**活的**。
    assign preg_dealloc_mask[63:0] = idu_rtu_pst_preg_dealloc_mask[63:0];

    // ============================================================
    // 11) 配置守卫: 本层按 **PREG=64** 使用
    // ============================================================
    // 同事交付的 C910 IDU 的 PRF (`ct_idu_rf_prf_pregfile`) 是 **64 项 / 6 位寻址**,
    // 而 RTU 的端口位宽固定 7 位 (两档共用一份 §6 契约)。
    //
    // **64 档下两者直接相接就是对的**: RTU 侧最高位恒 0, Verilog 在端口连接处
    // 隐式截掉的那一位**正好是 0** —— 不需要显式切位、也不需要适配层插一脚。
    // (唯一要显式处理的是 alloc 那句, 因为它在 §6.0 的口径里; PRF 的读地址/写地址
    //  由顶层直连, 见上面 §5 的说明。)
    //
    // ⚠️ 这条守卫防的是**拿 96 档来编**: 那时最高位不再是 0, 隐式截断就变成
    //    "写到错的物理寄存器", 而且**完全静默**(不报 x、不报 z、difftest 也只在
    //    某些用例上炸)。真要用 96 档, 两件事必须同时做:
    //      ① `ct_idu_rf_prf_pregfile` 扩到 96 项 (地址 7 位);
    //      ② 把顶层那几根 RTU→IDU 的连线改成 7 位显式直通, 并删掉这条守卫。
    generate
        if (`RTU_NUM_PREG != 64) begin : g_preg_must_be_64
            RTU_MUST_BE_BUILT_WITH_PREG_64_TO_MATCH_THE_C910_IDU_PRF u_err();
        end
    endgenerate

endmodule
