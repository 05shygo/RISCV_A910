module ct_lsu_lq_entry (
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [31:0]  ld_dc_addr0,
    // 2026-10-15 停用: addr1/bytes_vld1/secd/create1 都只服务非对齐的"第二半"表项
    //input  logic [27:0]  ld_dc_addr1_to4,
    input  logic [15:0]  ld_dc_bytes_vld,
    //input  logic [15:0]  ld_dc_bytes_vld1,
    input  logic [6:0]   ld_dc_iid,
    // 2026-10-17 S7: 向量 load 的 beat
    input  logic         ld_dc_vec,
    input  logic         ld_dc_old,
    input  logic [4:0]   ld_dc_uop_idx,
    input  logic [4:0]   ld_dc_beat_idx,
    //input  logic         ld_dc_secd,
    input  logic         lq_entry_create0_vld_x,
    //input  logic         lq_entry_create1_vld_x,
    input  logic         rtu_yy_xx_commit0,
    input  logic [6:0]   rtu_yy_xx_commit0_iid,
    input  logic         rtu_yy_xx_commit1,
    input  logic [6:0]   rtu_yy_xx_commit1_iid,
    input  logic         rtu_yy_xx_commit2,
    input  logic [6:0]   rtu_yy_xx_commit2_iid,
    // 2026-10-18: 向量 beat 提前提交窗口 (电平)
    input  logic [2:0]   rtu_yy_xx_win_valid,
    input  logic [6:0]   rtu_yy_xx_win_iid0,
    input  logic [6:0]   rtu_yy_xx_win_iid1,
    input  logic [6:0]   rtu_yy_xx_win_iid2,
    input  logic         rtu_yy_xx_flush,
    input  logic [31:0]  st_dc_addr0,
    input  logic [15:0]  st_dc_bytes_vld,
    input  logic         st_dc_chk_st_inst_vld,
    input  logic [6:0]   st_dc_iid,
    input  logic         st_dc_vec,
    input  logic [4:0]   st_dc_uop_idx,
    output logic         lq_entry_inst_hit_x,
    output logic         lq_entry_raw_spec_fail_x,
    output logic         lq_entry_vld_x
);

// 内部寄存器
logic [27:0] lq_entry_addr0_tto4;
logic [15:0] lq_entry_bytes_vld;
logic [6:0]  lq_entry_iid;
// 2026-10-17 S7
logic        lq_entry_vec;
logic        lq_entry_old;
logic [4:0]  lq_entry_uop_idx;
logic [4:0]  lq_entry_beat_idx;
//logic        lq_entry_secd;     // 2026-10-15 停用: 只有非对齐第二半才是 1, 现在恒 0
logic        lq_entry_vld;

// 内部组合信号
logic        lq_entry_cmit_hit0;
logic        lq_entry_cmit_hit1;
logic        lq_entry_cmit_hit2;
logic        lq_entry_cmit_vld;
// 2026-10-15 停用: 死亡声明 (无驱动无负载, 与本次非对齐摘除无关的既有残留): logic        lq_entry_create0_dp_vld;
logic        lq_entry_create0_vld;
//logic        lq_entry_create1_dp_vld;   // 2026-10-15 停用
//logic        lq_entry_create1_vld;      // 2026-10-15 停用
logic [39:0] lq_entry_from_ld_dc_addr0;
//logic [39:0] lq_entry_from_ld_dc_addr1; // 2026-10-15 停用
logic [39:0] lq_entry_from_st_dc_addr0;
logic        lq_entry_iid_newer_than_st_dc;
logic        lq_entry_inst_hit;
logic        lq_entry_newer_than_st_dc;
logic        lq_entry_pop_vld;
logic        lq_entry_raw_addr_tto4_hit;
logic        lq_entry_raw_do_hit;
logic        lq_entry_raw_spec_fail;
logic        lq_entry_raw_spec_fail1;

//==========================================================
//                 Register
//==========================================================
//+-----------+
//| entry_vld |
//+-----------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lq_entry_vld  <=  1'b0;
  else if(lq_entry_pop_vld  ||  rtu_yy_xx_flush)
    lq_entry_vld  <=  1'b0;
  else if(lq_entry_create0_vld)   // 2026-10-15 停用: || lq_entry_create1_vld
    lq_entry_vld  <=  1'b1;
end

//+-----------+------------+-----+--------+------+
//| addr_tto2 | bytes_vld0 | iid | deform | secd |
//+-----------+------------+-----+--------+------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    lq_entry_addr0_tto4[27:0]  <=  {28{1'b0}};
    lq_entry_bytes_vld[15:0]  <=  16'b0;
    lq_entry_iid[6:0]         <=  7'b0;
    //lq_entry_secd             <=  1'b0;
  end
  else if(lq_entry_create0_vld)
  begin
    lq_entry_addr0_tto4[27:0] <=  lq_entry_from_ld_dc_addr0[31:4];
    lq_entry_bytes_vld[15:0]  <=  ld_dc_bytes_vld[15:0];
    lq_entry_iid[6:0]         <=  ld_dc_iid[6:0];
    lq_entry_vec              <=  ld_dc_vec;
    // 计划 §9.6.1: 向量 beat 的 lq_entry_old 直接取 1 —— fill 引擎已经保证
    // 向量 load 只在 anchor 是 LSIQ 最老项时才发 beat (RAW 双保险),
    // 而 ld_dc_old 对向量被 rf_dp 强制成 0 (保守建 LQ) ⇒ 不能直接用它,
    // 否则向量 LQ 表项永不提前 pop ⇒ 8 项 LQ 被一条向量 load 占满 ⇒ 卡死。
    lq_entry_old              <=  ld_dc_old;
    lq_entry_uop_idx[4:0]     <=  ld_dc_uop_idx[4:0];
    lq_entry_beat_idx[4:0]    <=  ld_dc_beat_idx[4:0];
    //lq_entry_secd             <=  ld_dc_secd;
  end
  // 2026-10-15 停用: 非对齐"第二半"的 lq 表项 (地址取 addr1 / 掩码取 bytes_vld1)
  //else if(lq_entry_create1_vld)
  //begin
  //  lq_entry_addr0_tto4[27:0] <=  lq_entry_from_ld_dc_addr1[31:4];
  //  lq_entry_bytes_vld[15:0]  <=  ld_dc_bytes_vld1[15:0];
  //  lq_entry_iid[6:0]         <=  ld_dc_iid[6:0];
  //  lq_entry_secd             <=  1'b1;
  //end
end

//==========================================================
//                 Generate pop signal
//==========================================================
assign lq_entry_cmit_hit0 = rtu_yy_xx_commit0
                            &&  lq_entry_vld
                            &&  (rtu_yy_xx_commit0_iid[6:0]  ==  lq_entry_iid[6:0]);
assign lq_entry_cmit_hit1 = rtu_yy_xx_commit1
                            &&  lq_entry_vld
                            &&  (rtu_yy_xx_commit1_iid[6:0]  ==  lq_entry_iid[6:0]);
assign lq_entry_cmit_hit2 = rtu_yy_xx_commit2
                            &&  lq_entry_vld
                            &&  (rtu_yy_xx_commit2_iid[6:0]  ==  lq_entry_iid[6:0]);

assign lq_entry_cmit_vld  = (lq_entry_cmit_hit0
                                ||  lq_entry_cmit_hit1
                                ||  lq_entry_cmit_hit2)
                            &&  lq_entry_vld;

// 2026-10-18: 所有 LQ 表项都只在提交时弹出。
// 向量 beat 使用 RTU 头部 3 条提交窗口的**电平**提前 pop, 以便在指令等待
// cmplt 期间释放 LQ 容量; 标量仍用真正的退休广播。
wire lq_entry_win_cmit_vld = lq_entry_vec &&
    ((rtu_yy_xx_win_valid[0] && (rtu_yy_xx_win_iid0[6:0] == lq_entry_iid[6:0])) ||
     (rtu_yy_xx_win_valid[1] && (rtu_yy_xx_win_iid1[6:0] == lq_entry_iid[6:0])) ||
     (rtu_yy_xx_win_valid[2] && (rtu_yy_xx_win_iid2[6:0] == lq_entry_iid[6:0])));

assign lq_entry_pop_vld   = lq_entry_cmit_vld | lq_entry_win_cmit_vld;

//==========================================================
//                 lq iid check
//==========================================================
//check iid to judge whether to create lq
// 2026-10-15 停用: 原式还有 `&& (lq_entry_secd == ld_dc_secd)`, 两侧恒 0 恒等
assign lq_entry_inst_hit  = lq_entry_vld
                            //&&  (lq_entry_secd  ==  ld_dc_secd)
                            &&  (lq_entry_iid[6:0] ==  ld_dc_iid[6:0])
                            &&  (!ld_dc_vec ||
                                 ((lq_entry_uop_idx[4:0]  == ld_dc_uop_idx[4:0]) &&
                                  (lq_entry_beat_idx[4:0] == ld_dc_beat_idx[4:0])));

//==========================================================
//                 RAR speculation check
//==========================================================


//==========================================================
//                 RAW speculation check
//==========================================================
// situat st pipe             lq        addr      bytes_vld
// 1      st/stex             ld        31:4      x

//------------------compare signal--------------------------
//compare the instruction in the entry is newer or older
// &Instance("ct_rtu_compare_iid","x_lsu_lq_entry_compare_st_dc_iid"); @169
ct_rtu_compare_iid  x_lsu_lq_entry_compare_st_dc_iid (
  .x_iid0                        (st_dc_iid[6:0]               ),
  .x_iid0_older                  (lq_entry_iid_newer_than_st_dc),
  .x_iid1                        (lq_entry_iid[6:0]            )
);

// &Connect( .x_iid0         (st_dc_iid[6:0]       ), @170
//           .x_iid1         (lq_entry_iid[6:0]    ), @171
//           .x_iid0_older   (lq_entry_iid_newer_than_st_dc)); @172

assign lq_entry_newer_than_st_dc  = lq_entry_vld
                                    &&  lq_entry_iid_newer_than_st_dc;
//addr0 compare
// ⚠️ 原版 ct_lsu_lq_entry.v:295-296 有这两根:
//      lq_entry_from_ld_dc_addr0 = ld_dc_addr0;
//      lq_entry_from_ld_dc_addr1 = ld_dc_addr1;
//    本仓只接了 from_st_dc_addr0 ⇒ from_ld_dc_addr0/addr1 悬空 ⇒ lq_entry_addr0_tto4
//    (从 from_ld_dc_addr0[31:4] 装) 全是 X ⇒ lq_entry_raw_spec_fail 比对出 X。
//    addr1 用 ld_dc_addr1_to4 (== addr1[31:4]) 顶上。
assign lq_entry_from_ld_dc_addr0[31:0] = ld_dc_addr0[31:0];
// 2026-10-15 停用: addr1 已摘 (只有 create1 那条路用它)
//assign lq_entry_from_ld_dc_addr1[31:4] = ld_dc_addr1_to4[27:0];
assign lq_entry_from_st_dc_addr0[31:0] = st_dc_addr0[31:0];
assign lq_entry_raw_addr_tto4_hit   = lq_entry_addr0_tto4[27:0]
                                      ==  lq_entry_from_st_dc_addr0[31:4];

//bytes_vld compare
assign lq_entry_raw_do_hit       = |(lq_entry_bytes_vld[15:0]  & st_dc_bytes_vld[15:0]);

//------------------situation 1-----------------------------
assign lq_entry_raw_spec_fail1    = lq_entry_newer_than_st_dc
                                    &&  st_dc_chk_st_inst_vld
                                    &&  lq_entry_raw_addr_tto4_hit
                                    &&  lq_entry_raw_do_hit;

//------------------combine---------------------------------
assign lq_entry_raw_spec_fail     = lq_entry_raw_spec_fail1;

//==========================================================
//                 Generate interface
//==========================================================
//------------------input-----------------------------------
assign lq_entry_create0_vld         = lq_entry_create0_vld_x;
// 2026-10-15 停用: create1 通路已摘
//assign lq_entry_create1_vld         = lq_entry_create1_vld_x;
//------------------output----------------------------------
assign lq_entry_vld_x               = lq_entry_vld;
assign lq_entry_inst_hit_x          = lq_entry_inst_hit;
assign lq_entry_raw_spec_fail_x     = lq_entry_raw_spec_fail;

// &ModuleEnd; @209
endmodule