module ct_idu_is_lsiq_entry (
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe2_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe2_wb_preg_vld_dupx,
  input  logic         lsu_idu_lq_not_full,
  input  logic         lsu_idu_lsiq_pop_vld,
  input  logic         lsu_idu_rb_not_full,
  input  logic         lsu_idu_sq_not_full,
  input  logic         lsu_idu_imme_wakeup,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  // 第 5 路唤醒: RVV vset 写回 (S3)
  input  logic [5:0]   rvv_idu_vset_wb_preg_dupx,
  input  logic         rvv_idu_vset_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush,
  input  logic [6:0]   x_create_agevec,
  input  logic [6:0]   x_create_agevec_all,
  input  logic [60:0]  x_create_data,
  input  logic         x_create_en,
  input  logic         x_issue_en,
  output logic         x_load,
  input  logic         x_lq_full_set,
  input  logic [6:0]   x_other_raw_rdy,
  // 2026-10-18: 其它表项里"向量"标记 (与 x_other_raw_rdy 同序)。store 表项看到
  // 更老的向量 store 锚点时必须停下来 —— 锚点的一个 beat 就要占一格 SQ, 而
  // 标量 store 若抢先分配会把 SQ 占满, 队头向量 store 永远拿不到槽 ⇒ 死锁
  // (实测 alu_4: vse32 的队头在 st_dc 被 sq_full 永久 restart)。
  input  logic [6:0]   x_other_vec,
  input  logic         x_pop_cur_entry,
  input  logic [6:0]   x_pop_other_entry,
  output logic         x_raw_rdy,
  input  logic         x_rb_full_set,
  output logic         x_rdy,
  output logic [60:0]  x_read_data,
  // 2026-10-17 S7: LSIQ anchor (vector L/S)
  input  logic         x_vec_beat_rdy,     // fill 引擎: 当前 beat 可发射
  input  logic         x_vec_upd_en,       // fill 引擎: 写下一个 beat
  input  logic [105:0] x_vec_upd_data,     // VEC_BEAT_WIDTH
  input  logic         x_vec_beat_done,    // LSU DA: 本 beat 完成但非最后 beat
  output logic [105:0] x_read_vec_beat,    // 给 IDU 顶层发射 mux
  output logic         x_read_vec,
  // 2026-10-15 停用: 非对齐"第二半"标记 —— 喂它的 lsu_idu_secd 恒 0, 整条链摘掉
  //output logic         unalign_2nd,
  input  logic         x_sq_full_set,
  output logic         x_store,
  //input  logic         x_unalign_2nd_set,
  output logic         x_vld,
  output logic         old
);

//==========================================================
//                       Parameters
//==========================================================
//----------------------------------------------------------
//                    LSIQ Parameters
//----------------------------------------------------------
parameter LSIQ_WIDTH             = 61;      // S7: 60→61 (LSIQ_VEC)
parameter LSIQ_VEC               = 60;      // S7: anchor 标记 (最高位, 老位号不动)
parameter LSIQ_IID               = 59;
parameter LSIQ_SDIQ_ENTRY        = 52;
parameter LSIQ_STORE             = 48;
parameter LSIQ_LOAD              = 47;
parameter LSIQ_SRC0_DATA         = 46;
parameter LSIQ_DST_PREG          = 39;
parameter LSIQ_DST_VLD           = 33;
parameter LSIQ_SRC0_VLD          = 32;
parameter LSIQ_OPCODE            = 31;

// VEC beat 字段 (整包 106 bit)
parameter VEC_BEAT_WIDTH         = 106;
parameter VEC_BEAT_OPCODE        = 105;     // [105:74] 合成 opcode: LBU/LHU/LW / SB/SH/SW
parameter VEC_BEAT_ADDR          = 73;      // [73:42] 完整元素地址 (offset 恒 0)
parameter VEC_BEAT_SDIQ          = 41;      // [41:38] store 的 SDIQ 表项
parameter VEC_BEAT_UOPIDX        = 37;      // [37:33] uop_idx (load 同时作文档 preg)
parameter VEC_BEAT_LAST          = 32;      // 本 anchor 的最后一个 beat
parameter VEC_BEAT_SDATA         = 31;      // [31:0]  store beat 的 32 位数据

//==========================================================
//                  Internal Signal Declarations
//==========================================================
logic        vld;
logic        frz;
logic [6:0]  agevec;
logic [6:0]  agevec_all;
logic        lsu_frz_clr;
logic [5:0]  dst_preg;
logic [3:0]  sdiq_entry;
logic [31:0] opcode;
logic [6:0]  iid;
logic        src0_vld;
logic        src1_vld;
logic        dst_vld;
logic        load;
logic        store;
// S7: anchor beat
logic        vec;
logic [31:0] beat_opcode;
logic [31:0] beat_addr;
logic [3:0]  beat_sdiq;
logic [4:0]  beat_uop_idx;
logic        beat_last;
logic [31:0] beat_sdata;
logic        lq_full;
logic        lq_full_wakeup;
logic        sq_full;
logic        sq_full_wakeup;
logic        rb_full;
logic        rb_full_wakeup;

logic [6:0]  create_src0_data;
logic [6:0]  read_src0_data;
// 2026-10-15 停用: 既有死声明 (无驱动无负载, 与本仓非对齐摘除无关的移植残留): logic [6:0]  create_src1_data;
// 2026-10-15 停用: 既有死声明 (无驱动无负载, 与本仓非对齐摘除无关的移植残留): logic [6:0]  read_src1_data;
logic        src0_rdy_for_issue;
// 2026-10-15 停用: 既有死声明 (无驱动无负载, 与本仓非对齐摘除无关的移植残留): logic        src1_rdy_for_issue;
logic        older_entry_rdy_mask;


//==========================================================
//                      Entry Valid
//==========================================================
assign x_vld = vld;
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    vld <= 1'b0;
  else if(x_create_en)
    vld <= 1'b1;
  else if(lsu_idu_lsiq_pop_vld && x_pop_cur_entry)
    vld <= 1'b0;
  else
    vld <= vld;
end


//issue en has higher priority because bar check
//is still 1 when issue en, frz should be set
//when issue en and frz clr in this case
//bar check will be 0 after issue en
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    frz <= 1'b0;
  else if(x_create_en)
    frz <= 1'b0;
  else if(x_issue_en)
    frz <= 1'b1;
  // S7: anchor 的一个非最后 beat 完成 ⇒ 解冻, 等下一个 beat (fill 引擎会拉 ready)
  else if(x_vec_beat_done)
    frz <= 1'b0;
  // 2026-10-15 停用: 去掉 x_unalign_2nd_set (非对齐第二半的解锁, 恒 0)
  else if(lsu_frz_clr /*| x_unalign_2nd_set*/ | lsu_idu_imme_wakeup)
    frz <= 1'b0;
  else
    frz <= frz;
end

//==========================================================
//                       Age Vector
//==========================================================
//agevec of same type (store and bar share same type),
//used for issue
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    agevec[6:0] <= 7'b0;
  else if(x_create_en)
    agevec[6:0] <= x_create_agevec[6:0];
  else if(lsu_idu_lsiq_pop_vld)
    agevec[6:0] <= agevec[6:0] & ~x_pop_other_entry[6:0];
  else
    agevec[6:0] <= agevec[6:0];
end

// ⚠️ 原版还有一根"所有类型"的 agevec (ct_idu_is_lsiq_entry.v: agevec_all,
//    注释 "agevec of all types, used for old and bar frz clear")。本仓移植时漏了,
//    于是下面 old 只能拿"同类型"的 agevec 判 ⇒ **一条 load 只要前面没有更老的 load
//    (只有更老的 store) 就会被误判成 LSIQ 里最老** ⇒ `ld_dc_old`=1 ⇒ 不建 LQ 表项
//    ⇒ 更老的 store 走到 st_dc 时 LQ 是空的, `lq_st_dc_spec_fail` 不亮, 该 load
//    读到旧值也永远不会被重放。sb 侥幸过是因为它每条 load 前面都有更老的 load。
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    agevec_all[6:0] <= 7'b0;
  else if(x_create_en)
    agevec_all[6:0] <= x_create_agevec_all[6:0];
  else if(lsu_idu_lsiq_pop_vld)
    agevec_all[6:0] <= agevec_all[6:0] & ~x_pop_other_entry[6:0];
  else
    agevec_all[6:0] <= agevec_all[6:0];
end

//==========================================================
//                 Instruction Information
//==========================================================
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    dst_preg[5:0]      <= 6'b0;
  else if(x_create_en)
    dst_preg[5:0]      <= x_create_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5];
  // S7: anchor 的 load 写回目标 = beat 的 uop_idx (高位补 0)
  else if(x_vec_upd_en && vec)
    dst_preg[5:0]      <= {1'b0, beat_uop_idx[4:0]};
  else
    dst_preg[5:0]      <= dst_preg[5:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    sdiq_entry[3:0]   <= 4'b0;
  else if(x_create_en)
    sdiq_entry[3:0]   <= x_create_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3];
  // S7: store beat 的 SDIQ 表项
  else if(x_vec_upd_en && vec)
    sdiq_entry[3:0]   <= beat_sdiq[3:0];
  else
    sdiq_entry[3:0]   <= sdiq_entry[3:0];
end

// S7: anchor beat 寄存器 (opcode/addr/sdiq/uop_idx/last/sd_data)
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    beat_opcode[31:0]  <= 32'b0;
    beat_addr[31:0]    <= 32'b0;
    beat_sdiq[3:0]     <= 4'b0;
    beat_uop_idx[4:0]  <= 5'b0;
    beat_last          <= 1'b0;
    beat_sdata[31:0]   <= 32'b0;
  end
  else if(x_create_en) begin
    beat_opcode[31:0]  <= 32'b0;
    beat_addr[31:0]    <= 32'b0;
    beat_sdiq[3:0]     <= 4'b0;
    beat_uop_idx[4:0]  <= 5'b0;
    beat_last          <= 1'b0;
    beat_sdata[31:0]   <= 32'b0;
  end
  else if(x_vec_upd_en) begin
    beat_opcode[31:0]  <= x_vec_upd_data[VEC_BEAT_OPCODE -: 32];
    beat_addr[31:0]    <= x_vec_upd_data[VEC_BEAT_ADDR   -: 32];
    beat_sdiq[3:0]     <= x_vec_upd_data[VEC_BEAT_SDIQ   -: 4];
    beat_uop_idx[4:0]  <= x_vec_upd_data[VEC_BEAT_UOPIDX -: 5];
    beat_last          <= x_vec_upd_data[VEC_BEAT_LAST];
    beat_sdata[31:0]   <= x_vec_upd_data[VEC_BEAT_SDATA  -: 32];
  end
  else begin
    beat_opcode[31:0]  <= beat_opcode[31:0];
    beat_addr[31:0]    <= beat_addr[31:0];
    beat_sdiq[3:0]     <= beat_sdiq[3:0];
    beat_uop_idx[4:0]  <= beat_uop_idx[4:0];
    beat_last          <= beat_last;
    beat_sdata[31:0]   <= beat_sdata[31:0];
  end
end

// 合成 opcode 也要进 entry 的 opcode 寄存器 (pipe3/4 解码复用)
assign x_read_vec_beat[VEC_BEAT_OPCODE -: 32] = beat_opcode[31:0];
assign x_read_vec_beat[VEC_BEAT_ADDR   -: 32] = beat_addr[31:0];
assign x_read_vec_beat[VEC_BEAT_SDIQ   -: 4]  = beat_sdiq[3:0];
assign x_read_vec_beat[VEC_BEAT_UOPIDX -: 5]  = beat_uop_idx[4:0];
assign x_read_vec_beat[VEC_BEAT_LAST]         = beat_last;
assign x_read_vec_beat[VEC_BEAT_SDATA  -: 32] = beat_sdata[31:0];
assign x_read_vec = vec;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    opcode[31:0]       <= 32'b0;
    iid[6:0]           <= 7'b0;
    src0_vld           <= 1'b0;
    dst_vld            <= 1'b0;
    load               <= 1'b0;
    store              <= 1'b0;
    vec                <= 1'b0;
  end
  else if(x_create_en) begin
    opcode[31:0]       <= x_create_data[LSIQ_OPCODE:LSIQ_OPCODE-31];
    iid[6:0]           <= x_create_data[LSIQ_IID:LSIQ_IID-6];
    src0_vld           <= x_create_data[LSIQ_SRC0_VLD];
    dst_vld            <= x_create_data[LSIQ_DST_VLD];
    load               <= x_create_data[LSIQ_LOAD];
    store              <= x_create_data[LSIQ_STORE];
    vec                <= x_create_data[LSIQ_VEC];
  end
  else if(x_vec_upd_en && vec) begin
    // S7: beat update 只改"每个 beat 不同的字段"; iid/load/store/vec 不动
    opcode[31:0]       <= beat_opcode[31:0];
    iid[6:0]           <= iid[6:0];
    src0_vld           <= src0_vld;
    src1_vld           <= src1_vld;
    dst_vld            <= dst_vld;
    load               <= load;
    store              <= store;
    vec                <= vec;
  end
  else begin
    opcode[31:0]       <= opcode[31:0];
    iid[6:0]           <= iid[6:0];
    src0_vld           <= src0_vld;
    src1_vld           <= src1_vld;
    dst_vld            <= dst_vld;
    load               <= load;
    store              <= store;
    vec                <= vec;
  end
end

//rename for read output
assign x_read_data[LSIQ_OPCODE:LSIQ_OPCODE-31]         = opcode[31:0];
assign x_read_data[LSIQ_IID:LSIQ_IID-6]                = iid[6:0];
assign x_read_data[LSIQ_SRC0_VLD]                      = src0_vld;
assign x_read_data[LSIQ_DST_VLD]                       = dst_vld;
assign x_read_data[LSIQ_DST_PREG:LSIQ_DST_PREG-5]      = dst_preg[5:0];
assign x_read_data[LSIQ_LOAD]                          = load;
assign x_read_data[LSIQ_STORE]                         = store;
assign x_read_data[LSIQ_SDIQ_ENTRY:LSIQ_SDIQ_ENTRY-3] = sdiq_entry[3:0];
assign x_read_data[LSIQ_VEC]                           = vec;

assign x_load                                          = load;
assign x_store                                         = store;

//==========================================================
//                LSU Freeze Clear Signals
//==========================================================
//if all bits of age vec is 0, this entry is the oldest entry
//⚠️ 必须用**所有类型**的 agevec_all (原版如此): 同类型的 agevec 里不含更老的 store,
//   拿它判会把"前面只有更老 store"的 load 误判成 oldest。
assign old  = !(|agevec_all[6:0]);

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    lq_full             <=  1'b0;
  else if(rtu_yy_xx_flush)
    lq_full             <=  1'b0;
  else if(x_lq_full_set && vld)
    lq_full             <=  1'b1;
  else if(lq_full_wakeup)
    lq_full             <=  1'b0;
  else
    lq_full             <=  lq_full;
end

assign lq_full_wakeup = lsu_idu_lq_not_full ||  old;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    sq_full             <=  1'b0;
  else if(rtu_yy_xx_flush)
    sq_full             <=  1'b0;
  else if(x_sq_full_set && vld)
    sq_full             <=  1'b1;
  else if(sq_full_wakeup)
    sq_full             <=  1'b0;
  else
    sq_full             <=  sq_full;
end

assign sq_full_wakeup = lsu_idu_sq_not_full ||  old;

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rb_full             <=  1'b0;
  else if(rtu_yy_xx_flush)
    rb_full             <=  1'b0;
  else if(x_rb_full_set && vld)
    rb_full             <=  1'b1;
  else if(rb_full_wakeup)
    rb_full             <=  1'b0;
  else
    rb_full             <=  rb_full;
end

assign rb_full_wakeup = lsu_idu_rb_not_full ||  old;

assign lsu_frz_clr  =  (lq_full || sq_full || rb_full)
                      && (!lq_full       || lq_full       && lq_full_wakeup)
                      && (!sq_full       || sq_full       && sq_full_wakeup)
                      && (!rb_full       || rb_full       && rb_full_wakeup);

//==========================================================
//                    LSU Pass Signals
//==========================================================
// 2026-10-15 停用: 非对齐"第二半"标记寄存器 (整条链摘掉)
/*
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    unalign_2nd         <=  1'b0;
  else if(x_create_en)
    unalign_2nd         <=  1'b0;
  else if(x_unalign_2nd_set)
    unalign_2nd         <=  1'b1;
  else
    unalign_2nd         <=  unalign_2nd;
end
*/


//==========================================================
//              Source Dependency Information
//==========================================================
    //------------------------source 0--------------------------
    assign create_src0_data[6:0] = x_create_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-6];

    //----------------------------------------------------------------------
    // Instance : ct_idu_dep_reg_entry
    // Desc     : 依赖寄存器 entry（写端口来自 ex2/wb pipe0/1/pipe3，读端口给 x）
    //----------------------------------------------------------------------
    ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src0 (
        .cpurst_b                         (cpurst_b                         ),
        .forever_cpuclk                   (forever_cpuclk                   ),

        // 写端口：IU pipe0 ex2 wb
        .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
        .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

        // 写端口：IU pipe1 ex2 wb
        .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
        .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

        // 写端口：IU pipe2 ex2 wb
        .iu_idu_ex2_pipe2_wb_preg_dupx    (iu_idu_ex2_pipe2_wb_preg_dupx    ),
        .iu_idu_ex2_pipe2_wb_preg_vld_dupx(iu_idu_ex2_pipe2_wb_preg_vld_dupx),

        // 写端口：LSU pipe3 wb
        .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
        .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
        .rvv_idu_vset_wb_preg_dupx        (rvv_idu_vset_wb_preg_dupx        ),
        .rvv_idu_vset_wb_preg_vld_dupx    (rvv_idu_vset_wb_preg_vld_dupx    ),

        // flush
        .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

        // 写数据 / 写使能
        .x_create_data                    (create_src0_data[6:0]            ),
        .x_write_en                       (x_create_en                      ),

        // 读数据
        .x_read_data                      (read_src0_data[6:0]              )
    );

    assign x_read_data[LSIQ_SRC0_DATA:LSIQ_SRC0_DATA-6] = read_src0_data[6:0];

//==========================================================
//                  Entry Ready Signal
//==========================================================
//------------------------raw ready-------------------------
//without older entry ready mask
// &Force ("output", "x_raw_rdy"); @718

// 2026-10-18: anchor 永久冻结, 不再通过 LSIQ 发射 (直连路径由 fill 驱动)
assign src0_rdy_for_issue = vec ? 1'b0 : read_src0_data[0];


assign x_raw_rdy = vld && !frz
                       && src0_rdy_for_issue;

//----------------------older ready-------------------------
//if older entry of same type raw ready, mask cur entry ready
// 2026-10-18: store 还要等更老的**向量** store 真正做完 (锚点 pop)。
// 向量 store 的 beats 由 fill 异步注入, 不受 LSIQ 发射序约束; 若放行年轻标量
// store, 它们会先占满 SQ (8 格), 而队头向量 store 每 beat 还要一格 ⇒ 永久卡死。
assign older_entry_rdy_mask = |(agevec[6:0] &
                                (x_other_raw_rdy[6:0] |
                                 (x_other_vec[6:0] & {7{store}})));

//----------------------final ready-------------------------
//if older entry is ready, mask current entry ready
assign x_rdy = x_raw_rdy && !older_entry_rdy_mask;

// &ModuleEnd; @732
endmodule