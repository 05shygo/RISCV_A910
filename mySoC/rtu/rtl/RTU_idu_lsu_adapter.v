`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU_idu_lsu_adapter —— 自研 RTU ↔ 同事交付的 C910 IDU / LSU 之间的**适配层**。
//
// 【为什么需要单独一层】
// RTU 的 §6 契约与同事交付的 IP 之间有四类系统性差异。这些差异**不该**散落在
// 顶层接线里（那样每次看波形都要重新推一遍），统一收在这一层：
//
//   1. **preg 位宽**: RTU 端口**随档变**（`RTU_PREG_W`：64→6 / 96→7），
//      而交付的 IDU 是**硬编码 6 位**。
//      ⇒ 64 档下两侧天然同宽，本层那几处切位**退化成恒等**；
//        96 档下才真的要切（那时也会被下面 §11 的守卫拦住，见那一段）。
//   2. **恢复表布局**: `rtu_ren_recover_map` 是 32 × `RTU_PREG_W`（随档），
//      IDU 的 `rtu_idu_rt_recover_preg` 是 32×6（固定）。
//      **不是切低位就完事** —— 是逐槽重排，见下面 genvar 那段。
//      （64 档下两者都是 32×6 ⇒ 那个循环退化成恒等；真重排只在 96 档活。）
//   3. **复位极性**: RTU 是 `cpu_rst` 高有效，IDU/LSU 是 `cpurst_b` 低有效。
//   4. **语义编解码**: 三路独立请求 → 程序序前缀计数；store 重放两根 → 一根；
//      访存异常补 cause（LSU 只给地址，不给向量）。
//
// ⚠️ 2026-10-10: 原来第 4 类里还有一条"两个访存异常源 → 单路最旧者胜"，**已删**。
//    异常的三源锦标赛搬进了 `RTU_expt` —— 上游先合成一路会在**同拍冲突**时
//    永久丢异常（理由见下面 §9 的长注，以及 RTU.v §6.1 的端口注释）。
//    本层现在只做"完成门控 + cause 编码"这两件跨界必需的事。
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
    input  wire [`RTU_PREG_W-1:0]  rtu_preg_alloc0,
    input  wire [`RTU_PREG_W-1:0]  rtu_preg_alloc1,
    input  wire [`RTU_PREG_W-1:0]  rtu_preg_alloc2,
    input  wire        rtu_preg_alloc_vld0,
    input  wire        rtu_preg_alloc_vld1,
    input  wire        rtu_preg_alloc_vld2,

    // ---- §6.1 派遣 ----
    output wire        disp0_vld,
    output wire [31:0] disp0_pc,
    output wire [24:0] disp0_chk,
    output wire [4:0]  disp0_dst_lreg,
    output wire        disp0_rf_we,
    output wire [`RTU_PREG_W-1:0]  disp0_dst_preg,
    output wire [`RTU_PREG_W-1:0]  disp0_old_preg,
    output wire [`RTU_PREG_W-1:0]  disp0_src1_preg,
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
    output wire [`RTU_PREG_W-1:0]  disp1_dst_preg,
    output wire [`RTU_PREG_W-1:0]  disp1_old_preg,
    output wire [`RTU_PREG_W-1:0]  disp1_src1_preg,
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
    output wire [`RTU_PREG_W-1:0]  disp2_dst_preg,
    output wire [`RTU_PREG_W-1:0]  disp2_old_preg,
    output wire [`RTU_PREG_W-1:0]  disp2_src1_preg,
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

    // ---- §6.1 异常（三路平行送出，锦标赛在 RTU_expt 里做）----
    // 2026-10-10: 原来这里做"两源取最旧 + 再与其它源取最旧"的两级仲裁, 现在
    // **整个删掉** —— 同拍冲突在上游选一条送会永久丢异常 (见 RTU.v §6.1 的长注),
    // 所以三路原样送到 RTU, 由 RTU_expt 做锦标赛。
    // 本层只留下两件**必须**在跨界处做的事: 完成门控 + cause 编码。
    output wire        expt_iu_vld,
    output wire [6:0]  expt_iu_iid,
    output wire [4:0]  expt_iu_cause,
    output wire [31:0] expt_iu_tval,
    output wire        expt_ld_vld,
    output wire [6:0]  expt_ld_iid,
    output wire [4:0]  expt_ld_cause,
    output wire [31:0] expt_ld_tval,
    output wire        expt_st_vld,
    output wire [6:0]  expt_st_iid,
    output wire [4:0]  expt_st_cause,
    output wire [31:0] expt_st_tval,

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
    input  wire [32*`RTU_PREG_W-1:0] rtu_ren_recover_map,
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
    //     RTU 侧 `rtu_ren_recover_map`：`[`RTU_PREG_W*l +: `RTU_PREG_W]` = x_l 的映射
    //     IDU 侧 `rtu_idu_rt_recover_preg[191:0]`：`[6*l +: 6]` = x_l 的映射（6 位）
    // ⇒ **不是切低位就完事**（那样会把 32 个槽整体错位），必须逐槽搬。
    //    PREG=64 档下每槽的高位恒 0，所以搬低 6 位即可。
    // 写法说明：不能写 `map[`RTU_PREG_W*l +: `RTU_PREG_W][5:0]`（对内层的位选再
    // 切片，语法不允许）。每槽的低 6 位 = `map[`RTU_PREG_W*l +: 6]` —— 直接这样取。
    genvar l;
    generate
        for (l = 0; l < 32; l = l + 1) begin : gen_recover_repack
            assign rtu_idu_rt_recover_preg[6*l +: 6] = rtu_ren_recover_map[`RTU_PREG_W*l +: 6];
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
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp0_dst_preg  = idu_rtu_disp0_dst_preg[`RTU_PREG_W-1:0];
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp0_old_preg  = idu_rtu_disp0_old_preg[`RTU_PREG_W-1:0];
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp0_src1_preg = idu_rtu_disp0_src1_preg[`RTU_PREG_W-1:0];
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
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp1_dst_preg  = idu_rtu_disp1_dst_preg[`RTU_PREG_W-1:0];
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp1_old_preg  = idu_rtu_disp1_old_preg[`RTU_PREG_W-1:0];
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp1_src1_preg = idu_rtu_disp1_src1_preg[`RTU_PREG_W-1:0];
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
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp2_dst_preg  = idu_rtu_disp2_dst_preg[`RTU_PREG_W-1:0];
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp2_old_preg  = idu_rtu_disp2_old_preg[`RTU_PREG_W-1:0];
    // ⚠️ 显式切位: IDU 侧这三个字段**已经补到 7 位**（它按旧的 RTU 契约打包），
    //    而 RTU 侧现在随 `RTU_PREG_W 走 (64 档 6 位)。最高位是补出来的 0 ⇒ 切掉无损。
    //    写成显式切片是为了**不靠端口处的隐式截断** —— 那种截断不报错、也不报 x。
    assign disp2_src1_preg = idu_rtu_disp2_src1_preg[`RTU_PREG_W-1:0];
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
    //  9) 异常：三路平行送出（**这里不再仲裁**）
    // ============================================================
    // 2026-10-10：原来这里是"两源取最旧 + 再与其它源取最旧"的两级仲裁，两个
    // `RTU_iid_cmp` 都在这层。现在**整个搬进 `RTU_expt`**，本层只留下两件必须在
    // 跨界处做的事。
    //
    // 【为什么仲裁必须搬走 —— 这是这次改动的全部理由】
    //   load 与 store 是**两条独立流水，可以同拍都报**。上游先合成一路的话，
    //   同一拍只能送一条；而 RTU 那边的口也就只能收一条。若送的是**年轻**那条：
    //     * 年长那条的异常信息当场丢失，且**以后不会再报**（它已经离开流水）；
    //     * 它又比 trap 那条老 ⇒ **不在冲刷范围内** ⇒ 它会带着"无异常"的表项
    //       正常退休，异常**永久丢失**。
    //   RTU 内部那级（保持项"更老才覆盖"）只能救**跨拍**冲突 —— 跨拍时那条还在
    //   表项里，没走；同拍时它已经过去了，谁都救不回来。
    //   ⇒ 三路原样送下去，让 `RTU_expt` 在一个地方做锦标赛。
    //
    // 【留在本层的两件事 —— 它们都是"跨人契约的边界"才有的】
    //
    //   ① **完成门控**。`lsu_rtu_wb_pipe3_expt_vld` 曾经与 `cmplt` 相位不一致
    //      （lsu_ld_wb 的 always 缺 begin/end，2026-10-08 已修）。**这里仍然显式
    //      相与**，因为：修完之后相位一致只是"实现保证"，本层不该依赖它；更要紧的
    //      是 RTU 的异常是**按 iid 命中表项**的 —— 若 expt_vld 在没有指令完成的那拍
    //      为 1，那拍的 `_iid` 是**残留值**，RTU 会按错的 iid 报异常，静默错。
    //      （C910 也是显式门控：`ct_rtu_rob_expt.v` 里
    //        `pipe3_expt_cmplt = lsu_rtu_wb_pipe3_cmplt && lsu_rtu_wb_pipe3_abnormal`。）
    //
    //   ② **cause 编码**。交付的 LSU 只给 `expt_addr`，**不给异常向量**（C910 那边
    //      是给 `expt_vec[4:0]` 的），所以只能由"是哪条流水"反推：
    //        load  非对齐 → 4 (EXC_LOAD_MISALIGNED)
    //        store 非对齐 → 6 (EXC_STORE_MISALIGNED)   见 defines.vh:301/303
    //
    //   IU 那一路（非法指令 / 取指故障）在本层是**纯透传** —— 它的 cause 由检出级
    //   自己装好。
    wire ld_expt_gated = lsu_rtu_wb_pipe3_cmplt & lsu_rtu_wb_pipe3_expt_vld;
    wire st_expt_gated = lsu_rtu_wb_pipe4_cmplt & lsu_rtu_wb_pipe4_expt_vld;

    assign expt_ld_vld   = ld_expt_gated;
    assign expt_ld_iid   = lsu_rtu_wb_pipe3_iid;
    assign expt_ld_cause = 5'd4;                          // EXC_LOAD_MISALIGNED
    assign expt_ld_tval  = lsu_rtu_wb_pipe3_expt_addr;

    assign expt_st_vld   = st_expt_gated;
    assign expt_st_iid   = lsu_rtu_wb_pipe4_iid;
    assign expt_st_cause = 5'd6;                          // EXC_STORE_MISALIGNED
    assign expt_st_tval  = lsu_rtu_wb_pipe4_expt_addr;

    assign expt_iu_vld   = other_expt_vld;
    assign expt_iu_iid   = other_expt_iid;
    assign expt_iu_cause = other_expt_cause;
    assign expt_iu_tval  = other_expt_tval;

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
    // 同事交付的 C910 IDU 的 PRF (`ct_idu_rf_prf_pregfile`) 是**硬编码的 64 项 /
    // 6 位寻址**（`preg_reg_dout [0:63]`、两个 `for (i<64)`、读口是 64:1 的组合 mux）。
    //
    // ⚠️ **2026-10-10 起这条守卫的理由变了**: 原来是"RTU 端口固定 7 位、IDU 6 位,
    //    96 档下隐式截断会写到错的物理寄存器" —— 那是**位宽**问题。现在 RTU 的 preg
    //    端口随 `RTU_PREG_W 走 (64 档 = 6 位), 位宽在 64 档是**天然对上的**
    //    （这也是 `a910-elab` 的 PCWM 判据能从 5 条收到 0 条的原因）。
    //    剩下的只是**容量**: IDU 的 PRF 装不下 96 个号。
    //
    // ⇒ 拿 96 档来编仍然是错的, 但错法不同: 不是"截位写错寄存器", 而是
    //   "RTU 会发出 ≥64 的号, 而 IDU 的 PRF 根本没有那一项"。真要用 96 档,
    //   要做的是 ① `ct_idu_rf_prf_pregfile` 扩到 96 项 (地址 7 位、读 mux 变 128:1);
    //   ② 把 `rtu_idu_alloc_preg*` 那几个口也放宽到 7 位, 然后删掉这条守卫。
    //   (读 mux 从 64:1 到 128:1 要多一级 LUT, 而且在**每条 PRF 读路径**上 ——
    //    这是 96 档的真实代价, 不是"改个宏"。)
    generate
        if (`RTU_NUM_PREG != 64) begin : g_preg_must_be_64
            RTU_MUST_BE_BUILT_WITH_PREG_64_TO_MATCH_THE_C910_IDU_PRF u_err();
        end
    endgenerate

endmodule
