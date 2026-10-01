`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU — 退休单元顶层 (doc/rtu_plan_zh.md §5 / §6)
//
// 对外端口 = §6 契约的**逐字实现**, 一条不多一条不少。任何改动都要先改 §6。
//   §6.0 物理寄存器分配握手 (两拍语义)   §6.1 输入   §6.2 输出
//   §6.3 时序与边角约定 (冲刷时间线 / disp_stall 只依赖寄存器 / CSR 完成时机)
//
// 端口风格: 扁平编号 (xxx0/xxx1/xxx2 = 程序序, 0 最老), 与前端 idu_inst0/1/2_*
// 同风格 —— 本仓与蓝本 C910 都没有 SV unpacked array 端口的先例, 而 Fmax 验收
// 要在 Vivado 上过, 不该拿新语法当第一次综合实验 (§6 A4)。
//
// 内部结构 (阶段 0-C):
//   RTU_ROB      表项阵列 + 独热三指针 + read_entry 影子窗口(D5)
//   RTU_commit   判退级联 (read_entry0/1/2 -> 退休宽度/中断掩码/AMT 写)
//   RTU_preg     四态表 + WF_ALLOC 打拍 + 96 位三端口优先编码 + AMT
//   RTU_csr_slot CSR 单槽 + 在途门控 (§4.3)
//   RTU_expt     异常收集, 最旧者胜 (D9)
//   RTU_flush    冲刷状态机 + 重定向分发 + 提交点副作用 (D11)
//   RTU_iid_cmp  iid 年龄比较 (只给异常收集/中断掩码用, **不许接进重定向链**, D12)
// ---------------------------------------------------------------------------
module RTU (
    input  wire        cpu_clk,
    input  wire        cpu_rst,

    // ===================== §6.0 物理寄存器分配握手 =====================
    input  wire [1:0]  ren_preg_req,        // 0..3, 车道 0..n-1 是本次的请求者
    input  wire [4:0]  ren_preg_req_lreg0,  // 判 x0 用: lreg==0 的那一路不给编号
    input  wire [4:0]  ren_preg_req_lreg1,
    input  wire [4:0]  ren_preg_req_lreg2,
    output wire [6:0]  rtu_preg_alloc0,     // 给下一拍用的编号 (T 拍给, T+1 拍仍有效)
    output wire [6:0]  rtu_preg_alloc1,
    output wire [6:0]  rtu_preg_alloc2,
    output wire        rtu_preg_alloc_vld0,
    output wire        rtu_preg_alloc_vld1,
    output wire        rtu_preg_alloc_vld2,
    output wire [1:0]  rtu_preg_free_cnt,   // 剩余可用数 (饱和: 3 == ">=3")

    // ===================== §6.1 派遣 (k = 0/1/2 = 程序序) =====================
    input  wire        disp0_vld,
    input  wire [31:0] disp0_pc,
    input  wire [24:0] disp0_chk,
    input  wire [4:0]  disp0_dst_lreg,
    input  wire [6:0]  disp0_dst_preg,
    input  wire [6:0]  disp0_old_preg,
    input  wire [6:0]  disp0_src1_preg,
    input  wire [11:0] disp0_csr_addr,
    input  wire [1:0]  disp0_csr_op,
    input  wire [4:0]  disp0_csr_imm,
    input  wire [4:0]  disp0_flags,         // {is_mret, is_csr, intmask, is_store, is_branch}
    input  wire [2:0]  disp0_sq_id,

    input  wire        disp1_vld,
    input  wire [31:0] disp1_pc,
    input  wire [24:0] disp1_chk,
    input  wire [4:0]  disp1_dst_lreg,
    input  wire [6:0]  disp1_dst_preg,
    input  wire [6:0]  disp1_old_preg,
    input  wire [6:0]  disp1_src1_preg,
    input  wire [11:0] disp1_csr_addr,
    input  wire [1:0]  disp1_csr_op,
    input  wire [4:0]  disp1_csr_imm,
    input  wire [4:0]  disp1_flags,
    input  wire [2:0]  disp1_sq_id,

    input  wire        disp2_vld,
    input  wire [31:0] disp2_pc,
    input  wire [24:0] disp2_chk,
    input  wire [4:0]  disp2_dst_lreg,
    input  wire [6:0]  disp2_dst_preg,
    input  wire [6:0]  disp2_old_preg,
    input  wire [6:0]  disp2_src1_preg,
    input  wire [11:0] disp2_csr_addr,
    input  wire [1:0]  disp2_csr_op,
    input  wire [4:0]  disp2_csr_imm,
    input  wire [4:0]  disp2_flags,
    input  wire [2:0]  disp2_sq_id,

    // ===================== §6.1 完成 (p = 0..4) =====================
    input  wire        cmplt_vld0, input wire [6:0] cmplt_iid0,
    input  wire        cmplt_vld1, input wire [6:0] cmplt_iid1,
    input  wire        cmplt_vld2, input wire [6:0] cmplt_iid2,
    input  wire        cmplt_vld3, input wire [6:0] cmplt_iid3,
    input  wire        cmplt_vld4, input wire [6:0] cmplt_iid4,

    // ===================== §6.1 解析结果 (BEU) =====================
    input  wire        resolve_vld,
    input  wire [6:0]  resolve_iid,
    input  wire        resolve_taken,
    input  wire        resolve_mispred,
    input  wire [31:0] resolve_target,

    // ===================== §6.1 异常 (ID/EX/MEM 的检出点, 老级优先) =====================
    input  wire        expt_vld,
    input  wire [6:0]  expt_iid,
    input  wire [4:0]  expt_cause,
    input  wire [31:0] expt_tval,

    // ===================== §6.1 存储队列 / CSR / 中断 =====================
    input  wire        sq_rdy0,             // 退休窗口第 k 槽的 store 数据就绪
    input  wire        sq_rdy1,
    input  wire        sq_rdy2,
    input  wire        sq_stall,            // 存储队列满/下游忙 -> 压退休宽度
    input  wire [31:0] csr_rdata,           // 组合读: 地址见 rtu_csr_addr
    input  wire        int_pending,         // 已按 mstatus/mie/mip 屏蔽过

    // ===================== §6.1 物理寄存器堆读口 (A1) =====================
    input  wire [31:0] preg_rdata0,         // <- PRF[rtu_preg_raddr0]
    input  wire [31:0] preg_rdata1,
    input  wire [31:0] preg_rdata2,
    input  wire [31:0] rtu_csr_src_rdata,   // <- PRF[rtu_csr_src_raddr]

    // ===================== §6.2 前端: 陷阱/中断/mret 的重定向 =====================
    output wire        rtu_ifu_flush,
    output wire        rtu_ifu_chgflw_vld,
    output wire [31:0] rtu_ifu_chgflw_pc,
    output wire        rtu_ifu_train_vld,   // 退休点重训练 (阶段 4b 接上)
    output wire [31:0] rtu_ifu_train_pc,
    output wire [24:0] rtu_ifu_train_chk,
    output wire        rtu_ifu_train_taken,

    // ===================== §6.2 后端冲刷 (D11 的 FLUSH_1) =====================
    output wire        rtu_backend_flush,

    // ===================== §6.2 BEU: D1 的最旧门控 + 冲刷屏蔽 =====================
    output wire [6:0]  rtu_beu_retire_iid,
    output wire        rtu_beu_flush_chgflw_mask,

    // ===================== §6.2 重命名级 =====================
    output wire        rtu_disp_stall,
    output wire        rtu_ren_recover_vld,
    output wire [223:0] rtu_ren_recover_map, // 32 x 7bit AMT
    output wire        rtu_ren_flush,
    output wire [6:0]  rtu_ren_free_preg0,   // 观察口 (自由池在 RTU 侧)
    output wire [6:0]  rtu_ren_free_preg1,
    output wire [6:0]  rtu_ren_free_preg2,
    output wire        rtu_ren_free_vld0,
    output wire        rtu_ren_free_vld1,
    output wire        rtu_ren_free_vld2,

    // ===================== §6.2 物理寄存器堆访问 (A1) =====================
    output wire [6:0]  rtu_preg_raddr0,      // = 退休槽 k 的 dst_preg
    output wire [6:0]  rtu_preg_raddr1,
    output wire [6:0]  rtu_preg_raddr2,
    output wire [6:0]  rtu_csr_src_raddr,    // = 在途 CSR 指令的 src1_preg
    output wire        rtu_csr_rd_we,        // CSR 的 rd 结果在退休当拍写回
    output wire [6:0]  rtu_csr_rd_addr,
    output wire [31:0] rtu_csr_rd_wdata,     // = CSR 旧值

    // ===================== §6.2 提交点副作用 =====================
    output wire        rtu_store_vld0,
    output wire        rtu_store_vld1,
    output wire        rtu_store_vld2,
    output wire [2:0]  rtu_store_sq_id0,
    output wire [2:0]  rtu_store_sq_id1,
    output wire [2:0]  rtu_store_sq_id2,
    output wire        rtu_csr_we,
    output wire [11:0] rtu_csr_addr,         // 一个口两种用: 组合读地址 + 写地址
    output wire [31:0] rtu_csr_wdata,
    output wire        rtu_trap_vld,
    output wire        rtu_mret_vld,
    output wire [31:0] rtu_trap_epc,
    output wire [31:0] rtu_trap_tval,
    output wire [4:0]  rtu_trap_cause,
    output wire [1:0]  rtu_retire_cnt,       // 0..3 (被中断 squash 的那条不计)

    // ===================== §6.2 difftest / debug =====================
    output wire        dbg_commit_vld0,
    output wire        dbg_commit_vld1,
    output wire        dbg_commit_vld2,
    output wire [31:0] dbg_commit_pc0,
    output wire [31:0] dbg_commit_pc1,
    output wire [31:0] dbg_commit_pc2,
    output wire        dbg_commit_ena0,      // 陷阱那条: vld=1 但 ena=0 (§4.5)
    output wire        dbg_commit_ena1,
    output wire        dbg_commit_ena2,
    output wire [4:0]  dbg_commit_reg0,
    output wire [4:0]  dbg_commit_reg1,
    output wire [4:0]  dbg_commit_reg2,
    output wire [31:0] dbg_commit_value0,    // 摘自 preg_rdata*, CSR 那条换成 CSR 旧值
    output wire [31:0] dbg_commit_value1,
    output wire [31:0] dbg_commit_value2
);

// ---------------------------------------------------------------------------
// 阶段 0-B: 端口骨架 (契约落码)。
// 0-C 把下面几个子模块填进来 —— 现在先把手里的输入吃掉、输出给常量, 让
// `vcs -top RTU` 能干净地 elaborate (输出恒 0 只是骨架态, 不进网表、不接核)。
// ---------------------------------------------------------------------------
wire _unused;
assign _unused = &{1'b0, ren_preg_req, ren_preg_req_lreg0, ren_preg_req_lreg1,
                   ren_preg_req_lreg2,
                   disp0_vld, disp0_pc, disp0_chk, disp0_dst_lreg, disp0_dst_preg,
                   disp0_old_preg, disp0_src1_preg, disp0_csr_addr, disp0_csr_op,
                   disp0_csr_imm, disp0_flags, disp0_sq_id,
                   disp1_vld, disp1_pc, disp1_chk, disp1_dst_lreg, disp1_dst_preg,
                   disp1_old_preg, disp1_src1_preg, disp1_csr_addr, disp1_csr_op,
                   disp1_csr_imm, disp1_flags, disp1_sq_id,
                   disp2_vld, disp2_pc, disp2_chk, disp2_dst_lreg, disp2_dst_preg,
                   disp2_old_preg, disp2_src1_preg, disp2_csr_addr, disp2_csr_op,
                   disp2_csr_imm, disp2_flags, disp2_sq_id,
                   cmplt_vld0, cmplt_iid0, cmplt_vld1, cmplt_iid1, cmplt_vld2, cmplt_iid2,
                   cmplt_vld3, cmplt_iid3, cmplt_vld4, cmplt_iid4,
                   resolve_vld, resolve_iid, resolve_taken, resolve_mispred, resolve_target,
                   expt_vld, expt_iid, expt_cause, expt_tval,
                   sq_rdy0, sq_rdy1, sq_rdy2, sq_stall, csr_rdata, int_pending,
                   preg_rdata0, preg_rdata1, preg_rdata2, rtu_csr_src_rdata};

assign rtu_preg_alloc0      = 7'd0;
assign rtu_preg_alloc1      = 7'd0;
assign rtu_preg_alloc2      = 7'd0;
assign rtu_preg_alloc_vld0  = 1'b0;
assign rtu_preg_alloc_vld1  = 1'b0;
assign rtu_preg_alloc_vld2  = 1'b0;
assign rtu_preg_free_cnt    = 2'd3;

assign rtu_ifu_flush        = 1'b0;
assign rtu_ifu_chgflw_vld   = 1'b0;
assign rtu_ifu_chgflw_pc    = 32'd0;
assign rtu_ifu_train_vld    = 1'b0;
assign rtu_ifu_train_pc     = 32'd0;
assign rtu_ifu_train_chk    = 25'd0;
assign rtu_ifu_train_taken  = 1'b0;

assign rtu_backend_flush         = 1'b0;
assign rtu_beu_retire_iid        = 7'd0;
assign rtu_beu_flush_chgflw_mask = 1'b0;

assign rtu_disp_stall      = 1'b0;
assign rtu_ren_recover_vld = 1'b0;
assign rtu_ren_recover_map = 224'd0;
assign rtu_ren_flush       = 1'b0;
assign rtu_ren_free_preg0  = 7'd0;
assign rtu_ren_free_preg1  = 7'd0;
assign rtu_ren_free_preg2  = 7'd0;
assign rtu_ren_free_vld0   = 1'b0;
assign rtu_ren_free_vld1   = 1'b0;
assign rtu_ren_free_vld2   = 1'b0;

assign rtu_preg_raddr0  = 7'd0;
assign rtu_preg_raddr1  = 7'd0;
assign rtu_preg_raddr2  = 7'd0;
assign rtu_csr_src_raddr = 7'd0;
assign rtu_csr_rd_we    = 1'b0;
assign rtu_csr_rd_addr  = 7'd0;
assign rtu_csr_rd_wdata = 32'd0;

assign rtu_store_vld0   = 1'b0;
assign rtu_store_vld1   = 1'b0;
assign rtu_store_vld2   = 1'b0;
assign rtu_store_sq_id0 = 3'd0;
assign rtu_store_sq_id1 = 3'd0;
assign rtu_store_sq_id2 = 3'd0;
assign rtu_csr_we       = 1'b0;
assign rtu_csr_addr     = 12'd0;
assign rtu_csr_wdata    = 32'd0;
assign rtu_trap_vld     = 1'b0;
assign rtu_mret_vld     = 1'b0;
assign rtu_trap_epc     = 32'd0;
assign rtu_trap_tval    = 32'd0;
assign rtu_trap_cause   = 5'd0;
assign rtu_retire_cnt   = 2'd0;

assign dbg_commit_vld0   = 1'b0;
assign dbg_commit_vld1   = 1'b0;
assign dbg_commit_vld2   = 1'b0;
assign dbg_commit_pc0    = 32'd0;
assign dbg_commit_pc1    = 32'd0;
assign dbg_commit_pc2    = 32'd0;
assign dbg_commit_ena0   = 1'b0;
assign dbg_commit_ena1   = 1'b0;
assign dbg_commit_ena2   = 1'b0;
assign dbg_commit_reg0   = 5'd0;
assign dbg_commit_reg1   = 5'd0;
assign dbg_commit_reg2   = 5'd0;
assign dbg_commit_value0 = 32'd0;
assign dbg_commit_value1 = 32'd0;
assign dbg_commit_value2 = 32'd0;

endmodule
