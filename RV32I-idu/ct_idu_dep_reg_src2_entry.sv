module ct_idu_dep_reg_src2_entry (
    // 时钟与复位
    input  logic         forever_cpuclk,
    input  logic         cpurst_b,

    // 流水线控制与冲刷
    input  logic         rtu_yy_xx_flush,

    // 写回与旁路控制 (Pipe0 / Pipe1)
    input  logic         ctrl_xx_rf_pipe0_preg_lch_vld_dupx,
    input  logic         ctrl_xx_rf_pipe1_preg_lch_vld_dupx,
    input  logic [6:0]   dp_xx_rf_pipe0_dst_preg_dupx,
    input  logic [6:0]   dp_xx_rf_pipe1_dst_preg_dupx,
    input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
    input  logic [6:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
    input  logic         iu_idu_ex2_pipe1_mult_inst_vld_dupx,
    input  logic [6:0]   iu_idu_ex2_pipe1_preg_dupx,
    input  logic [6:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
    input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,

    // 除法器接口
    input  logic         iu_idu_div_inst_vld,
    input  logic [6:0]   iu_idu_div_preg_dupx,

    // LSU 接口 (Pipe3)
    input  logic         lsu_idu_ag_pipe3_load_inst_vld,
    input  logic [6:0]   lsu_idu_ag_pipe3_preg_dupx,
    input  logic         lsu_idu_dc_pipe3_load_fwd_inst_vld_dupx,
    input  logic         lsu_idu_dc_pipe3_load_inst_vld_dupx,
    input  logic [6:0]   lsu_idu_dc_pipe3_preg_dupx,
    input  logic [6:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
    input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,

    // 乘法器与 ALU 旁路
    input  logic         mla_reg_fwd_vld,
    input  logic         alu0_reg_fwd_vld,
    input  logic         alu1_reg_fwd_vld,

    // VFPU 接口 (Pipe6 / Pipe7)
    input  logic         vfpu_idu_ex1_pipe6_mfvr_inst_vld_dupx,
    input  logic [6:0]   vfpu_idu_ex1_pipe6_preg_dupx,
    input  logic         vfpu_idu_ex1_pipe7_mfvr_inst_vld_dupx,
    input  logic [6:0]   vfpu_idu_ex1_pipe7_preg_dupx,

    // 内部队列/表项控制接口
    input  logic [10:0]  x_create_data,
    input  logic         x_entry_mla,
    input  logic         x_gateclk_idx_write_en,
    input  logic         x_gateclk_write_en,
    input  logic         x_rdy_clr,
    input  logic         x_write_en,

    // 输出读数据
    output logic [12:0]  x_read_data
);

    // =========================================================
    // 内部信号声明 (Internal Signals)
    // =========================================================
    
    // 状态寄存器 (Regs)
    logic        lsu_match;
    logic        mla_rdy;
    logic [6:0]  preg;
    logic        rdy;
    logic        wb;

    // 组合逻辑与解码信号 (Wires)
    logic        alu0_data_ready;
    logic        alu0_issue_data_ready;
    logic        alu1_data_ready;
    logic        alu1_issue_data_ready;
    logic        data_ready;
    logic        dep_clk;
    logic        dep_clk_en;
    logic        div_data_ready;
    logic        gateclk_entry_vld;
    logic        load_data_ready;
    logic        load_issue_data_ready;
    logic        lsu_match_update;
    logic        mla_data_ready;
    logic        mla_issue_data_ready;
    logic        mla_rdy_update;
    logic        mult_data_ready;
    logic        pipe0_wb;
    logic        pipe1_wb;
    logic        pipe3_wb;
    logic        rdy_clear;
    logic        rdy_update;
    logic        vfpu0_data_ready;
    logic        vfpu1_data_ready;
    logic        wake_up;
    logic        wb_update;
    logic        write_back;
    logic        write_clk;
    logic        write_clk_en;

    // 解构 x_create_data 的内部信号
    logic        x_create_lsu_match;
    logic        x_create_mla_rdy;
    logic [6:0]  x_create_preg;
    logic        x_create_rdy;
    logic        x_create_wb;

    // 解构 x_read_data 的内部信号
    logic        x_read_lsu_match;
    logic        x_read_mla_rdy;
    logic [6:0]  x_read_preg;
    logic        x_read_rdy;
    logic        x_read_rdy_for_bypass;
    logic        x_read_rdy_for_issue;
    logic        x_read_wb;
//==========================================================
//                  Create and Read Bus
//==========================================================
assign x_create_preg[6:0]           = x_create_data[8:2];
assign x_create_wb                  = x_create_data[1];
assign x_create_rdy                 = x_create_data[0];


assign x_read_data[11]              = x_read_rdy_for_bypass;
assign x_read_data[10]              = x_read_rdy_for_issue;
assign x_read_data[9]               = x_read_mla_rdy;
assign x_read_data[8:2]             = x_read_preg[6:0];
assign x_read_data[1]               = x_read_wb;
assign x_read_data[0]               = x_read_rdy;

//==========================================================
//                       Ready Bit
//==========================================================
//ready bit shows the result of source is predicted to be ready:
//1 stands for the result may be forwarded

//-------------Update value of Ready Bit--------------------
//prepare data_ready signal
assign alu0_data_ready   = ctrl_xx_rf_pipe0_preg_lch_vld_dupx
                           && (dp_xx_rf_pipe0_dst_preg_dupx[6:0] == preg[6:0]);
//div data ready use wb to wake up / set ready
assign alu1_data_ready   = ctrl_xx_rf_pipe1_preg_lch_vld_dupx
                           && (dp_xx_rf_pipe1_dst_preg_dupx[6:0] == preg[6:0]);
assign mult_data_ready   = iu_idu_ex2_pipe1_mult_inst_vld_dupx
                           && (iu_idu_ex2_pipe1_preg_dupx[6:0] == preg[6:0]);
assign div_data_ready    = iu_idu_div_inst_vld
                           && (iu_idu_div_preg_dupx[6:0] == preg[6:0]);
assign load_data_ready   = lsu_idu_dc_pipe3_load_inst_vld_dupx
                           && (lsu_idu_dc_pipe3_preg_dupx[6:0] == preg[6:0]);
assign vfpu0_data_ready  = vfpu_idu_ex1_pipe6_mfvr_inst_vld_dupx
                           && (vfpu_idu_ex1_pipe6_preg_dupx[6:0] == preg[6:0]);
assign vfpu1_data_ready  = vfpu_idu_ex1_pipe7_mfvr_inst_vld_dupx
                           && (vfpu_idu_ex1_pipe7_preg_dupx[6:0] == preg[6:0]);
//bypass data ready for issue
assign alu0_issue_data_ready = alu0_reg_fwd_vld;
assign alu1_issue_data_ready = alu1_reg_fwd_vld;
assign load_issue_data_ready = lsu_idu_dc_pipe3_load_fwd_inst_vld_dupx && lsu_match;

assign data_ready        = alu0_data_ready
                           || alu1_data_ready
                           || mult_data_ready
                           || div_data_ready
                           || load_data_ready
                           || vfpu0_data_ready
                           || vfpu1_data_ready;
//prepare wake up signal
assign wake_up           = wb;
//prepare clear signal
assign rdy_clear         = x_rdy_clr;

//1.if ready is already be 1, just hold 1
//2.if producer are presumed to produce the result two cycles later,
//  set ready to 1 
//3.if producer wake up, set ready to 1
//4.clear ready to 0
assign rdy_update = (rdy || data_ready || wake_up) && !rdy_clear;
//ready read signal
assign x_read_rdy = rdy_update;
//the following signals are for Issue Queue bypass/issue logic
assign x_read_rdy_for_issue  = rdy || mla_rdy
                                   || alu0_issue_data_ready
                                   || alu1_issue_data_ready
                                   || load_issue_data_ready
                                   || mla_issue_data_ready;
assign x_read_rdy_for_bypass = rdy;

always @(posedge dep_clk or negedge cpurst_b)
begin
  if(!cpurst_b)
    rdy <= 1'b1;
  else if(rtu_yy_xx_flush)
    rdy <= 1'b1;
  else if(x_write_en)
    rdy <= x_create_rdy;
  else
    rdy <= rdy_update;
end



//==========================================================
//                     Write Back Valid  
//==========================================================
//write back valid shows whether the result is written back
//into PRF : 1 stands for the result is in PRF

//-------------Update value of Write Back Bit---------------
//prepare write back signal
assign pipe0_wb = iu_idu_ex2_pipe0_wb_preg_vld_dupx
                  && (iu_idu_ex2_pipe0_wb_preg_dupx[6:0] == preg[6:0]);
assign pipe1_wb = iu_idu_ex2_pipe1_wb_preg_vld_dupx
                  && (iu_idu_ex2_pipe1_wb_preg_dupx[6:0] == preg[6:0]);
assign pipe3_wb = lsu_idu_wb_pipe3_wb_preg_vld_dupx
                  && (lsu_idu_wb_pipe3_wb_preg_dupx[6:0] == preg[6:0]);
assign write_back = wb
                    || pipe0_wb
                    || pipe1_wb
                    || pipe3_wb;
//1.if wb_vld is already be 1, just hold 1
//2.if this result is writing back to PRF, set wb to 1
assign x_read_wb = wb_update;
assign wb_update = wb || write_back;

always @(posedge dep_clk or negedge cpurst_b)
begin
  if(!cpurst_b)
    wb <= 1'b1;
  else if(rtu_yy_xx_flush)
    wb <= 1'b1;
  else if(x_write_en)
    wb <= x_create_wb;
  else
    wb <= wb_update;
end


//==========================================================
//                         Preg 
//==========================================================
assign x_read_preg[6:0] = preg[6:0];
always @(posedge write_clk or negedge cpurst_b)
begin
  if(!cpurst_b)
    preg[6:0] <= 7'b0;
  else if(x_write_en)
    preg[6:0] <= x_create_preg[6:0];
  else
    preg[6:0] <= preg[6:0];
end

// &ModuleEnd; @239
endmodule


