module lsu_ld_ag #(
  parameter int IID_WIDTH  = 6,
  parameter int LSIQ_ENTRY = 8,
  parameter int DCACHE_SIZE = 2048,  // 1024, 2048, or 4096 bytes
  // Derived parameters for dcache indexing
  parameter int CACHELINE_SIZE = 32,
  parameter int NUM_WAYS = 2,
  parameter int OFFSET_WIDTH = 5,
  parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
  parameter int INDEX_WIDTH = $clog2(NUM_SETS),
  parameter int INDEX_LSB = OFFSET_WIDTH,
  parameter int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1,
  parameter int DATA_INDEX_WIDTH = INDEX_WIDTH + 1,
  parameter int DC_IDX = INDEX_WIDTH
)(
  //==========================================================
  // Clock / Reset
  //==========================================================
  input  logic                         forever_cpuclk,
  input  logic                         cpurst_b,

  //==========================================================
  // IDU -> LSU_LD_AG
  //==========================================================
  input  logic                         idu_lsu_ld_sel,
  input  logic [1:0]                   idu_lsu_ld_inst_size,
  // 2026-10-15 停用: 非对齐拆分通路的"第二条"标记, 见文件下方 "非对齐硬件已停用" 一节
  //input  logic                         idu_lsu_ld_unalign_2nd,
  input  logic                         idu_lsu_ld_sign_extend,
  input  logic [6:0]                   idu_lsu_ld_iid,
  input  logic [LSIQ_ENTRY-1:0]        idu_lsu_ld_lch_entry,
  input  logic                         idu_lsu_ld_oldest,
  input  logic [5:0]                   idu_lsu_ld_preg,
  // 2026-10-17 S7: 向量 beat
  input  logic                         idu_lsu_ld_vec,
  input  logic [4:0]                   idu_lsu_ld_uop_idx,
  input  logic                         idu_lsu_ld_last,
  input  logic [11:0]                  idu_lsu_ld_offset,
  // 2026-10-15 停用: LSU 不再接收 IDU 的 offset_plus (只有非对齐拆分才用它)
  //input  logic [12:0]                  idu_lsu_ld_offset_plus,
  input  logic [31:0]                  idu_lsu_ld_src,

  //==========================================================
  // RTU -> LSU
  //==========================================================
  input  logic                         rtu_yy_xx_flush,

  // 2026-10-15 停用: 只喂下面的 ld_ag_cmit 块, 而那块已被注释 ⇒ 这 6 个口无消费者
  //input  logic                         rtu_yy_xx_commit0,
  //input  logic [6:0]                   rtu_yy_xx_commit0_iid,

  //input  logic                         rtu_yy_xx_commit1,
  //input  logic [6:0]                   rtu_yy_xx_commit1_iid,

  //input  logic                         rtu_yy_xx_commit2,
  //input  logic [6:0]                   rtu_yy_xx_commit2_iid,

  //==========================================================
  // DCache Arb -> LSU
  //==========================================================
  input  logic                         dcache_arb_ag_ld_sel,
  input  logic                         dcache_arb_ld_ag_borrow_addr_vld,
  input  logic [31:0]                  dcache_arb_ld_ag_addr,

  //==========================================================
  // Store AG -> Load AG
  //==========================================================
  input  logic [6:0]                   st_ag_iid,

  //==========================================================
  // DCache related input
  //==========================================================

  //==========================================================
  // LSU_LD_AG -> DC
  //==========================================================
  output logic                         ld_ag_dc_inst_vld,
  output logic [1:0]                   ld_ag_inst_size,
  // 2026-10-15 停用: 非对齐拆分通路整条摘掉 (boundary/secd/acclr_en), 见下方说明块
  //output logic                         ld_ag_secd,
  output logic                         ld_ag_sign_extend,
  output logic [6:0]                   ld_ag_iid,
  output logic [LSIQ_ENTRY-1:0]        ld_ag_lsid,
  output logic                         ld_ag_old,
  output logic [5:0]                   ld_ag_preg,
  output logic                         ld_ag_vec,
  output logic [4:0]                   ld_ag_uop_idx,
  output logic                         ld_ag_last,
  //output logic                         ld_ag_boundary,
  //output logic                         ld_ag_acclr_en,
  // 2026-10-15 停用: bypass 通路在本仓没实现 (ld_dc_chk_ld_bypass_vld 无人使用), 整条摘掉: output logic                         ld_ag_dc_fwd_bypass_en,
  output logic                         ld_ag_expt,
  //==========================================================
  // LSU_LD_AG -> DCACHE
  //==========================================================
  output logic                          ag_dcache_arb_ld_tag_gateclk_en,
  output logic                          ag_dcache_arb_ld_tag_req,
  output logic [INDEX_WIDTH-1:0]        ag_dcache_arb_ld_tag_idx,
  output logic [7:0]                    ag_dcache_arb_ld_data_gateclk_en,
  output logic [7:0]                    ag_dcache_arb_ld_data_req,
  output logic [DATA_INDEX_WIDTH-1:0]   ag_dcache_arb_ld_data_low_idx,
  output logic [DATA_INDEX_WIDTH-1:0]   ag_dcache_arb_ld_data_high_idx,

  // 2026-10-15 停用: 只服务非对齐拆分, 不再往下传
  //output logic [15:0]                   ld_ag_bytes_vld1,
  output logic [15:0]                   ld_ag_bytes_vld,
 // output logic [27:0]                   ld_ag_addr1_to4,
  output logic [31:0]                   ld_ag_dc_addr0,
  output logic                          ld_ag_raw_new,
  // 2026-10-15 恢复: AG 级"发射落空"要把 LSIQ 表项的 frz 打掉 (见下面的 assign)
  output logic [LSIQ_ENTRY-1:0]         ld_ag_stall_restart_entry
);

//==========================================================
// Internal registers
//==========================================================
logic                         ld_ag_inst_vld;
//logic                         ld_rf_inst_vld;
//logic                         ld_ag_ld_inst;
logic                         ld_ag_clk;
//logic                         ld_ag_addr_plus_sel;   // 2026-10-15 停用: 非对齐地址选择

// ---------------------------------------------------------------------------
// 本地时钟驱动（2026-10-08 补）
// ⚠️ C910 工厂版在这里例化门控时钟单元 (forever_cpuclk + ag_dcache_arb_*_gateclk_en
//    → ct_clk_cell), **交付时那批单元被整体剥掉** ⇒ `ld_ag_clk` 全仓无驱动。
//    后果: 地址生成级的流水寄存器 (offset / offset_plus / inst_size / iid / preg…)
//    全部冻结 —— 整个 load 通路从第一级就是死的。
// 本模块的 forever_cpuclk 端口一直存在 (见端口表, 且 lsu_top 已连)。
// 各 always 块内部自带使能条件 (!ld_ag_stall_vld / idu_lsu_ld_sel / 冲刷),
// 所以直接接 forever_cpuclk 功能等价, 只是少了时钟门控的省电效果。
// 注意: 本文件里还留着一处 `always @(posedge forever_cpuclk)` 直连 —— 两处同源,
//      不存在相位差。
// ---------------------------------------------------------------------------
assign ld_ag_clk = forever_cpuclk;

logic [31:0]                  ld_ag_offset;
logic [31:0]                  ld_ag_base;


//==========================================================
// Address generation
//==========================================================
logic [31:0]                  ld_ag_addr_ori;
//logic [63:0]                  ld_ag_va_ori;
logic [31:0]                  ld_ag_addr;
//logic [31:0]                  ld_ag_addr_plus;      // 2026-10-15 停用: 非对齐 +16 地址
//logic [31:0]                  ld_ag_offset_plus;    // 2026-10-15 停用: 非对齐 +16 偏移

//logic [4:0]                   ld_ag_va_add_access_size;
logic [3:0]                   ld_ag_va_add_access_size;
logic [3:0]                   ld_ag_access_size_ori;
logic [3:0]                   ld_ag_access_size;


//==========================================================
// Boundary / Unalign
//==========================================================
//logic                         ld_ag_boundary_unmask;   // 2026-10-15 停用: 非对齐跨行判定
//logic                         ld_ag_ld_inst;

//logic                         ld_ag_va_plus_sel;       // 2026-10-15 停用: 非对齐地址选择

logic                         ld_ag_dcache_stall_unmask;
logic                         ld_ag_stall_ori;
logic                         ld_ag_stall_vld;
logic                         rf_iid_older_than_ld_ag;
logic                         ld_ag_stall_mask;


//==========================================================
// Byte valid
//==========================================================
logic [15:0]                  ld_ag_le_bytes_vld_high_bits_full;
logic [15:0]                  ld_ag_le_bytes_vld_low_bits_full;

logic [15:0]                  ld_ag_le_bytes_vld_cross;
logic [15:0]                  ld_ag_le_bytes_vld_low_cross_bits;

//logic [15:0]                  ld_ag_le_bytes_vld_high_bits;   // 2026-10-15 停用: 只喂 bytes_vld1

logic [15:0]                  ld_ag_bytes_vld_low_cross_bits;
//logic [15:0]                  ld_ag_bytes_vld_high_bits;      // 2026-10-15 停用: 只喂 bytes_vld1


//==========================================================
// DCache bank select
//==========================================================
logic [3:0]                   bank_en_low_ori;
logic [3:0]                   bank_en_low;
logic [3:0]                   bank_en_low_gateclk;


//==========================================================
// DCache request
//==========================================================
logic                         ag_dcache_arb_ld_req;


//==========================================================
// Commit
//==========================================================
// 2026-10-15 停用: 这套 commit 比较的 assign 已注释, 声明一并摘掉
//logic                         ld_ag_cmit_hit0;
//logic                         ld_ag_cmit_hit1;
//logic                         ld_ag_cmit_hit2;
//logic                         ld_ag_cmit;


//==========================================================
// IID compare
//==========================================================
logic                         rf_iid_older_than_ld_ag;

//+----------+
//| inst_vld |
//+----------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_ag_inst_vld  <=  1'b0;
  else if(rtu_yy_xx_flush)
    ld_ag_inst_vld  <=  1'b0;
  else if(ld_ag_stall_vld ||  idu_lsu_ld_sel)
    ld_ag_inst_vld  <=  1'b1;
  else
    ld_ag_inst_vld  <=  1'b0;
end

//------------------data part-------------------------------

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    ld_ag_inst_size[1:0]        <=  2'b0;
   // ld_ag_secd                  <=  1'b0;
    ld_ag_sign_extend           <=  1'b0;
    ld_ag_iid[6:0]              <=  7'b0;
    ld_ag_lsid[LSIQ_ENTRY-1:0]  <=  {LSIQ_ENTRY{1'b0}};
    ld_ag_old                   <=  1'b0;
    ld_ag_preg[5:0]             <=  7'b0;
    ld_ag_vec                   <=  1'b0;
    ld_ag_uop_idx[4:0]          <=  5'b0;
    ld_ag_last                  <=  1'b0;
  end
  else if(!ld_ag_stall_vld  &&  idu_lsu_ld_sel)
  begin
    ld_ag_inst_size[1:0]        <=  idu_lsu_ld_inst_size[1:0];
   // ld_ag_secd                  <=  idu_lsu_ld_unalign_2nd;
    ld_ag_sign_extend           <=  idu_lsu_ld_sign_extend;
    ld_ag_iid[6:0]              <=  idu_lsu_ld_iid[6:0];
    ld_ag_lsid[LSIQ_ENTRY-1:0]  <=  idu_lsu_ld_lch_entry[LSIQ_ENTRY-1:0];
    ld_ag_old                   <=  idu_lsu_ld_oldest;
    ld_ag_preg[5:0]             <=  idu_lsu_ld_preg[5:0];
    ld_ag_vec                   <=  idu_lsu_ld_vec;
    ld_ag_uop_idx[4:0]          <=  idu_lsu_ld_uop_idx[4:0];
    ld_ag_last                  <=  idu_lsu_ld_last;
  end
end

//+--------+
//| offset |
//+--------+
always @(posedge forever_cpuclk)
begin
  if (!ld_ag_stall_vld &&  idu_lsu_ld_sel)
    ld_ag_offset[31:0]  <= {{20{idu_lsu_ld_offset[11]}},idu_lsu_ld_offset[11:0]};
end
//+-------------+
//| offset_plus |
//+-------------+
//use this imm as offset when the ld/st inst need split and !secd
/*
always @(posedge ld_ag_clk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_ag_offset_plus[12:0]  <=  13'h0;
  else if (!ld_ag_stall_vld &&  idu_lsu_ld_sel)
    ld_ag_offset_plus[12:0]  <=  idu_lsu_ld_offset_plus[12:0];
end
*/
//+------+
//| base |
//+------+
//the base addr, if stall, the base is set the result from the adder
always @(posedge forever_cpuclk)
begin
  if (!ld_ag_stall_vld &&  idu_lsu_ld_sel)
    ld_ag_base[31:0]  <=  idu_lsu_ld_src[31:0];
end

//==========================================================
//               Generate  address
//==========================================================
assign ld_ag_addr_ori[31:0] = ld_ag_base[31:0] + ld_ag_offset[31:0];
/*
assign ld_ag_addr_plus[31:0]          = ld_ag_base[31:0]
                                      + {{19{ld_ag_offset_plus[12]}},ld_ag_offset_plus[12:0]};
*/
// 2026-10-15 停用: addr1 (非对齐拆分里"低地址那半"的地址)。对齐访问下它与 addr0 同值,
//   而它的消费者 (lq_entry 的 create1 分支 / ld_dc 的 raw_addr1 比较 / cache_buffer)
//   全部由 ld_dc_acclr_en 或 cb_ld_dc_addr_hit 门控 ⇒ acclr_en 恒 0 时这条通路已死。
//   恒 0 顶住, 避免输出悬空 (Z) 静默传播成 X。
//assign ld_ag_addr1_to4[27:0] = ld_ag_addr_ori[31:4];
//assign ld_ag_addr1_to4[27:0] = 28'b0;
//assign ld_ag_offset_plus[31:0]     = ld_ag_offset[31:0] + 32'h10;
//if misalign without page, then select ori va
/*
assign ld_ag_addr_plus_sel            = ld_ag_boundary_unmask
                                      &&  !ld_ag_secd;
*/
assign ld_ag_addr[31:0]               =// ld_ag_addr_plus_sel
                                     // ? ld_ag_addr_plus[31:0]
                                        ld_ag_addr_ori[31:0]; 

//---------------boundary---------------
assign ld_ag_va_add_access_size[3:0]  = ld_ag_addr_ori[3:0] + ld_ag_access_size[3:0];
//assign ld_ag_boundary_unmask  = ld_ag_va_add_access_size[4];

//assign ld_ag_boundary = (ld_ag_boundary_unmask
//                            ||  ld_ag_secd);

// ═══════════════════════════════════════════════════════════════════════════
// 2026-10-15 停用: 非对齐 (boundary / unalign) 硬件处理逻辑 —— **整条从流水线摘掉**
//   前提: 现在跑的测试里**不会再出现非对齐访问** —— 非对齐一律由 ld_ag_expt
//         (见下方 `assign ld_ag_expt = !ld_ag_align;`) 当异常上报, 不进数据通路。
//   已摘掉的输出 (端口 + 驱动一并注释, 不再往下传给 ld_dc):
//     ld_ag_boundary      —— 原 = ld_ag_boundary_unmask || ld_ag_secd
//     ld_ag_secd          —— 原 = reg(idu_lsu_ld_unalign_2nd)   ("第二条"标记)
//     ld_ag_acclr_en      —— 原 = ld_ag_boundary & !ld_ag_secd
//     ld_ag_bytes_vld1    —— 原 = le_bytes_vld_high_bits       (只服务拆分)
//     ld_ag_addr1_to4     —— 原 = ld_ag_addr_ori[31:4]         (只服务拆分)
//   对齐情形下这五根本来就分别是 0/0/0/(死)/(死), 摘掉后功能等价。
//   ⚠️ 原逻辑全部按"只注释、不删除"原地保留, 便于回退。
// ═══════════════════════════════════════════════════════════════════════════
//assign ld_ag_boundary = 1'b0;
//assign ld_ag_secd     = 1'b0;

//----------------generate unalign--------------------------
//-----------unalign--------------------
// 2026-10-08 修: 下面这个 casez 用了 BYTE/HALF/WORD, 而这三个 parameter 原本声明在
// 文件靠下 (~:319) ⇒ **先用后声明**, VCS 报 "Identifier 'BYTE' has not been declared",
// 整个 LSU elaborate 失败。把声明提到使用点之前 (下面那段 `Generate unalign, bytes_vld`
// 里的同名声明已随之删除, 只留这一处, 避免重复定义)。
parameter BYTE = 2'b00,
          HALF = 2'b01,
          WORD = 2'b10;

// &CombBeg; @400
logic ld_ag_align;
always @(*)
begin
casez({ld_ag_inst_size[1:0],ld_ag_addr_ori[2:0]})
  {BYTE,3'b???}:ld_ag_align = 1'b1;
  {HALF,3'b??0}:ld_ag_align = 1'b1;
  {WORD,3'b?00}:ld_ag_align = 1'b1;
  default:ld_ag_align  = 1'b0;
endcase
// &CombEnd; @411
end
assign ld_ag_expt = !ld_ag_align;
                 

//==========================================================
//            Generate unalign, bytes_vld
//==========================================================
//---------------inst access size---------------
// access size is used to select bytes_vld and boundary judge
// (BYTE/HALF/WORD 的声明已上移到上面的 unalign 块之前 —— 那里先用到了它们, 见 2026-10-08 注)


always @( ld_ag_inst_size[1:0])
begin
case(ld_ag_inst_size[1:0])
  BYTE: ld_ag_access_size_ori[3:0] = 4'b0000;
  HALF: ld_ag_access_size_ori[3:0] = 4'b0001;
  WORD: ld_ag_access_size_ori[3:0] = 4'b0011;
  default:ld_ag_access_size_ori[3:0] = 4'b0;
endcase
// &CombEnd; @379
end
assign ld_ag_access_size[3:0] = ld_ag_access_size_ori[3:0]; 


//assign ld_ag_acclr_en         = ld_ag_boundary & !ld_ag_secd;
// 2026-10-15 停用: 非对齐才需要"加速"清 dcache 行 (acclr), 整根摘掉 (见上方说明块)
//assign ld_ag_acclr_en         = 1'b0;

//----------------generate bytes_vld------------------------
//-----------in le/bev2-----------------
//the 2nd half boundary inst will +128, so va[3:0] of 2nd inst will not change
// &CombBeg; @439
always @( ld_ag_addr_ori[3:0])
begin
case(ld_ag_addr_ori[3:0])
  4'b0000:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffff;
  4'b0001:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfffe;
  4'b0010:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfffc;
  4'b0011:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfff8;
  4'b0100:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfff0;
  4'b0101:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffe0;
  4'b0110:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffc0;
  4'b0111:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hff80;
  4'b1000:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hff00;
  4'b1001:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfe00;
  4'b1010:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfc00;
  4'b1011:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hf800;
  4'b1100:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hf000;
  4'b1101:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'he000;
  4'b1110:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'hc000;
  4'b1111:ld_ag_le_bytes_vld_high_bits_full[15:0] = 16'h8000;
  default:ld_ag_le_bytes_vld_high_bits_full[15:0] = {16{1'bx}};
endcase
// &CombEnd; @459
end

// &CombBeg; @461
always @( ld_ag_va_add_access_size[3:0])
begin
case(ld_ag_va_add_access_size[3:0])
  4'b0000:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0001;
  4'b0001:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0003;
  4'b0010:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0007;
  4'b0011:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h000f;
  4'b0100:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h001f;
  4'b0101:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h003f;
  4'b0110:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h007f;
  4'b0111:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h00ff;
  4'b1000:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h01ff;
  4'b1001:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h03ff;
  4'b1010:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h07ff;
  4'b1011:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0fff;
  4'b1100:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h1fff;
  4'b1101:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h3fff;
  4'b1110:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'h7fff;
  4'b1111:ld_ag_le_bytes_vld_low_bits_full[15:0] = 16'hffff;
  default:ld_ag_le_bytes_vld_low_bits_full[15:0] = {16{1'bx}};
endcase
// &CombEnd; @481
end

assign ld_ag_le_bytes_vld_cross[15:0]       = ld_ag_le_bytes_vld_high_bits_full[15:0]
                                                & ld_ag_le_bytes_vld_low_bits_full[15:0];

assign ld_ag_le_bytes_vld_low_cross_bits[15:0]  = //ld_ag_boundary_unmask
                                                  //? ld_ag_le_bytes_vld_low_bits_full[15:0]
                                                   ld_ag_le_bytes_vld_cross[15:0]; 

// 2026-10-15 停用: 下面两根只喂 bytes_vld1 (已摘), 一并注释
//assign ld_ag_le_bytes_vld_high_bits[15:0]   = ld_ag_le_bytes_vld_high_bits_full[15:0];
//-----------select bytes_vld-----------
assign ld_ag_bytes_vld_low_cross_bits[15:0] = ld_ag_le_bytes_vld_low_cross_bits[15:0];

//assign ld_ag_bytes_vld_high_bits[15:0]  = ld_ag_le_bytes_vld_high_bits[15:0];

//used for
//1.lq create
//2.da data_merge when acclr_en
//bytes_vld1 is the bytes_vld of lower addr when there is a first(bigger) boundary ld inst
// 2026-10-15 停用: bytes_vld1 只服务非对齐拆分。消费者 (lq_entry create1 / sq_entry
//   depd_hit4 / ld_da 的 cb_bypass) 全部被 acclr_en 或 cb_* 门控 ⇒ 已死。恒 0 顶住。
//assign ld_ag_bytes_vld1[15:0] =  ld_ag_bytes_vld_high_bits[15:0];
//assign ld_ag_bytes_vld1[15:0] =  16'b0;

assign ld_ag_bytes_vld[15:0]  =  //ld_ag_secd
                                 //? ld_ag_bytes_vld_high_bits[15:0]
                                  ld_ag_bytes_vld_low_cross_bits[15:0];

//assign ld_ag_dc_fwd_bypass_en = !ld_ag_boundary;
// 2026-10-15 停用: bypass 通路在本仓没实现 (ld_dc_chk_ld_bypass_vld 无人使用), 整条摘掉: assign ld_ag_dc_fwd_bypass_en = 1'b1;

//==========================================================
//        Generage commit signal
//==========================================================
/*
assign ld_ag_cmit_hit0  = {rtu_yy_xx_commit0,rtu_yy_xx_commit0_iid[6:0]}
                          ==  {1'b1,ld_ag_iid[6:0]};
assign ld_ag_cmit_hit1  = {rtu_yy_xx_commit1,rtu_yy_xx_commit1_iid[6:0]}
                          ==  {1'b1,ld_ag_iid[6:0]};
assign ld_ag_cmit_hit2  = {rtu_yy_xx_commit2,rtu_yy_xx_commit2_iid[6:0]}
                          ==  {1'b1,ld_ag_iid[6:0]};

// //&Force("output","ld_ag_cmit"); @1036
assign ld_ag_cmit       = ld_ag_cmit_hit0
                          ||  ld_ag_cmit_hit1
                          ||  ld_ag_cmit_hit2;
                          */
//==========================================================
//        Generage dcache request information
//==========================================================
assign ag_dcache_arb_ld_req = ld_ag_inst_vld;


//-----------tag array-------------------------------------
assign ag_dcache_arb_ld_tag_gateclk_en  = ag_dcache_arb_ld_req;
assign ag_dcache_arb_ld_tag_req         = ag_dcache_arb_ld_req;
assign ag_dcache_arb_ld_tag_idx         = ld_ag_addr[INDEX_MSB:INDEX_LSB];

//-----------data array------------------------------------
//------------data req signal-----------
// &CombBeg; @1064
always @(*)
begin
// 2026-10-15 停用非对齐: 原来 casez 的键多两位 `{boundary, secd}`; 对齐访问恒为 {0,?},
//   留下的就是下面这 10 条 (addr_ori[3:2] 是起始 bank, va_add_access_size[3:2] 是结束 bank),
//   后半 8 条 (boundary=1) 只服务拆分, 一并摘掉。
casez({ld_ag_addr_ori[3:2],ld_ag_va_add_access_size[3:2]})
  {2'b00,2'b00}:bank_en_low_ori[3:0] = 4'b0001;
  {2'b00,2'b01}:bank_en_low_ori[3:0] = 4'b0011;
  {2'b00,2'b10}:bank_en_low_ori[3:0] = 4'b0111;
  {2'b00,2'b11}:bank_en_low_ori[3:0] = 4'b1111;
  {2'b01,2'b01}:bank_en_low_ori[3:0] = 4'b0010;
  {2'b01,2'b10}:bank_en_low_ori[3:0] = 4'b0110;
  {2'b01,2'b11}:bank_en_low_ori[3:0] = 4'b1110;
  {2'b10,2'b10}:bank_en_low_ori[3:0] = 4'b0100;
  {2'b10,2'b11}:bank_en_low_ori[3:0] = 4'b1100;
  {2'b11,2'b11}:bank_en_low_ori[3:0] = 4'b1000;
  // 原 (boundary, secd): {1'b1,1'b0,...} / {1'b1,1'b1,...} 共 8 条, 只服务非对齐拆分
  //  {1'b1,1'b0,2'b??,2'b00}:bank_en_low_ori[3:0] = 4'b0001;
  //  {1'b1,1'b0,2'b??,2'b01}:bank_en_low_ori[3:0] = 4'b0011;
  //  {1'b1,1'b0,2'b??,2'b10}:bank_en_low_ori[3:0] = 4'b0111;
  //  {1'b1,1'b0,2'b??,2'b11}:bank_en_low_ori[3:0] = 4'b1111;
  //  {1'b1,1'b1,2'b00,2'b??}:bank_en_low_ori[3:0] = 4'b1111;
  //  {1'b1,1'b1,2'b01,2'b??}:bank_en_low_ori[3:0] = 4'b1110;
  //  {1'b1,1'b1,2'b10,2'b??}:bank_en_low_ori[3:0] = 4'b1100;
  //  {1'b1,1'b1,2'b11,2'b??}:bank_en_low_ori[3:0] = 4'b1000;
  default:bank_en_low_ori[3:0]  = 4'b0;
endcase
// &CombEnd; @1086
end

//if accelate, it must access all banks for 128 bits
assign bank_en_low[3:0] = bank_en_low_ori[3:0];
//-------------for gateclk--------------
assign ag_dcache_arb_ld_gateclk_en = ld_ag_inst_vld;
assign bank_en_low_gateclk[3:0]   = bank_en_low[3:0];

assign ag_dcache_arb_ld_data_gateclk_en[7:0]  = {bank_en_low_gateclk[3:0],bank_en_low_gateclk[3:0]}
                                                & {8{ag_dcache_arb_ld_gateclk_en}};

//--------------for req-----------------
assign ag_dcache_arb_ld_data_req[7:0] = {bank_en_low[3:0],bank_en_low[3:0]}
                                        & {8{ag_dcache_arb_ld_req}};

//-----------data idx-------------------
assign ag_dcache_arb_ld_data_low_idx  = ld_ag_addr[INDEX_MSB+1:4];
assign ag_dcache_arb_ld_data_high_idx = {ld_ag_addr[INDEX_MSB+1:INDEX_LSB], ~ld_ag_addr[4]};


//==========================================================
//            stall
//==========================================================
//if misalign without page, then select ori va

assign ld_ag_dcache_stall_unmask    = !dcache_arb_ag_ld_sel;

assign ld_ag_stall_ori            = ld_ag_dcache_stall_unmask;

// ⚠️⚠️ 2026-10-15 补 (coremark_i1 T71237 整机死锁的真凶): **漏了 `&& !ld_ag_stall_mask`**。
//   原版 (ct_lsu_ld_ag.v:1318-1321):
//      ld_ag_stall_ori = (cross_page || dcache_stall || mmu_stall) && !atomic;
//      ld_ag_stall_vld = ld_ag_stall_ori && !ld_ag_stall_mask;
//   而 `ld_ag_stall_vld` 又是 **AG 级"这拍收不下新指令"的判据** —— 三处寄存器装载都是
//      if (!ld_ag_stall_vld && idu_lsu_rf_pipe3_sel) <= RF 来的新指令;
//   所以 mask=1 (RF 那条比 AG 里那条**更老**) 时必须把它拉低, AG 才肯把更老的那条收进来、
//   把手里更年轻的那条挤出去 (原版注释: "for performance, when ag stall, let oldest inst go")。
//   本仓原来掩掉了这个取反项 ⇒ mask=1 时 AG 仍自称 stall ⇒ **拒收那条更老的 load**,
//   而 RF 级那拍过后就换下一条 ⇒ 这条更老的 load **既没进 AG、LSIQ 表项也没被 pop**。
//   更糟的是那拍 `ld_ag_stall_restart_entry` 选的是 `ld_ag_lsid` (AG 里那条更年轻的),
//   LSIQ 里那条更老的表项**没有任何 wakeup 去解它的 `frz`** ⇒ 永远不再发射。
//   实测 (coremark_i1): T71215 LSIQ 发 entry2 (iid=40, pc=0x0cd8 `lh a4,0(a6)`, 正是 ROB
//   队头); T71216 它到了 RF 级 (`ld_lch=00000100`), 而 AG 里是更年轻的 iid=41
//   (`ld_ag_iid=41`) ⇒ `rf_iid_older_than_ld_ag=1` ⇒ mask=1: 该拍 `ld_ag_stall_vld=1`
//   ⇒ AG 拒收 ⇒ 下拍 RF 换成 iid=48, entry2 永久 `vld=1 frz=1 x_raw_rdy=0`
//   (`src0_rdy` 明明是 1) ⇒ ROB 队头永不完成 ⇒ T71237 起一条指令都不退休。
assign ld_ag_stall_vld            = ld_ag_inst_vld & ld_ag_stall_ori & !ld_ag_stall_mask;

// ⚠️⚠️ 2026-10-15 恢复 (coremark_i1 T68485 整机死锁的真凶): 下面这一整段原来被注释掉了,
//   连端口一起删了 (lsu_top 的 `lsu_idu_imme_wakeup` 那行也把这一项注释掉了)。
//   原版 ct_lsu_ld_ag.v:1331-1334 + ct_lsu_ctrl.v:901-903 的机制是:
//      ld_rf_restart_vld = idu_lsu_rf_pipe3_sel && ld_ag_stall_ori;   // "这拍发射落空"
//      ld_rf_imme_wakeup = ld_ag_stall_restart_entry & {LSIQ_ENTRY{ld_rf_restart_vld}};
//   即 **LSIQ 把一个表项发给 RF 级、但 AG 级这拍收不下 (等 dcache 仲裁) 时, 要把那个
//   LSIQ 表项的 `frz` 打掉**, 让它能在下一拍重新发射。
//   LSIQ 表项的 `frz` 是"发过一次"就置死、只在收到这个 wakeup 时才清的
//   (`ct_idu_is_lsiq_entry.sv` 的 frz 块)。这条 wakeup 没了 ⇒ **发射落空一次, 这个
//   表项就永远不再发射**, 而 ROB 队头正是它 ⇒ 队头永不完成 ⇒ 它后面那条已误预测的
//   分支永远提交不了 ⇒ 没有冲刷脉冲 ⇒ `A910_cpu.sv` 的 mispred 闸门永不开 ⇒ 整机冻结。
//   实测 (coremark_i1): T68461 LSIQ 发 entry7 (iid=118, pc=0x0eec, 正是 ROB 队头),
//   那两拍 AG 级正被 iid=113 占着等 dcache 仲裁 (`ld_ag_stall_ori=1`) ⇒ 没接住,
//   而 entry7 的 frz 已经在 T68462 置死、再没人清 ⇒ T68485 起一条指令都不退休。
//   恢复后 entry7 每拍都能重发, AG 级一空就读进来。
ct_rtu_compare_iid  x_lsu_rf_compare_ld_ag_iid (
  .x_iid0                    (idu_lsu_ld_iid[6:0]),
  .x_iid0_older              (rf_iid_older_than_ld_ag  ),
  .x_iid1                    (ld_ag_iid[6:0]           )
);

assign ld_ag_stall_mask = idu_lsu_ld_sel
                          && rf_iid_older_than_ld_ag;

// 把原版在 ct_lsu_ctrl.v 里做的那层 `& {LSIQ_ENTRY{ld_rf_restart_vld}}` 并进来
// (少一根跨模块的 stall_ori 端口): 只有"这拍真的在发射且真的落空"才发 wakeup。
// ⚠️ 原版 `ld_ag_stall_ori` 里**含 `ld_ag_inst_vld`** (它 = ... || `ld_ag_dcache_stall_req`,
//   而后者 = `!dcache_arb_ag_ld_sel && ld_ag_inst_vld`)；本仓把 inst_vld 挪到了
//   `ld_ag_stall_vld` 里 ⇒ 这里必须用 `ld_ag_stall_vld` 当原版的 stall_ori。
//   若误用 `ld_ag_stall_ori` (无 inst_vld): AG 级空着、新 load 刚发进来的那拍
//   `dcache_arb_ag_ld_sel` 还没拉 (req = ld_ag_inst_vld = 0) ⇒ 会发一次**多余的** wakeup
//   ⇒ LSIQ 表项被解锁后**重复发射**同一笔 load。
// ⚠️ 使能用的是**加 mask 之前**的 `ld_ag_inst_vld & ld_ag_stall_ori`, 不是 `ld_ag_stall_vld`
//   —— 否则 mask=1 那拍 (正是"AG 把更年轻那条挤出去"的场合) stall_vld 已被上面取反项拉低,
//   `ld_ag_lsid` 这一支永远选不中, 被挤出去的那条就再也发不回来了。
//   对齐原版: 使能 `ld_rf_restart_vld = idu_lsu_rf_pipe3_sel && ld_ag_stall_ori` 用的也是
//   **未取反**的 stall_ori。这里额外带上 `ld_ag_inst_vld`, 是为了避免 AG 空着那拍
//   (`dcache_arb_ag_ld_sel` 还没拉) 发一次多余的 wakeup ⇒ 表项解锁后重复发射。
assign ld_ag_stall_restart_entry[LSIQ_ENTRY-1:0] =
        (idu_lsu_ld_sel && ld_ag_inst_vld && ld_ag_stall_ori)
          ? (ld_ag_stall_mask ? ld_ag_lsid[LSIQ_ENTRY-1:0]
                              : idu_lsu_ld_lch_entry[LSIQ_ENTRY-1:0])
          : {LSIQ_ENTRY{1'b0}};
//-----------for timing--------------------------
//compare iid ahead for dc restart timing
//compare the instruction in the entry is newer or older
// &Instance("ct_rtu_compare_iid","x_lsu_ld_ag_compare_st_ag_iid"); @1295
ct_rtu_compare_iid  x_lsu_ld_ag_compare_st_ag_iid (
  .x_iid0         (st_ag_iid[6:0]),
  .x_iid0_older   (ld_ag_raw_new ),
  .x_iid1         (ld_ag_iid[6:0])
);

//==========================================================
//        Generage to DC stage signal
//==========================================================
// &Force("output", "ld_ag_dc_inst_vld"); @1249
assign ld_ag_dc_inst_vld          = ld_ag_inst_vld && !ld_ag_stall_ori;

 assign ld_ag_dc_addr0[31:0] = dcache_arb_ld_ag_borrow_addr_vld
                                      ? dcache_arb_ld_ag_addr[31:0]
                                      : ld_ag_addr[31:0];

endmodule