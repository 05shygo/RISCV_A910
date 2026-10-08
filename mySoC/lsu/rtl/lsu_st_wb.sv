module ct_lsu_st_wb (
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic         rtu_yy_xx_flush,

  // From ST_DA stage
  input  logic [6:0]   st_da_iid,
  input  logic         st_da_wb_cmplt_req,
  input  logic         st_da_wb_expt_vld,
  input  logic [31:0]  st_da_wb_expt_addr,
  input  logic         st_da_wb_spec_fail,

  // To RTU
  output logic         lsu_rtu_wb_pipe4_cmplt,
  output logic         lsu_rtu_wb_pipe4_flush,
  output logic         lsu_rtu_wb_pipe4_expt_vld,
  output logic [31:0]  lsu_rtu_wb_pipe4_expt_addr,
  output logic [6:0]   lsu_rtu_wb_pipe4_iid,
  output logic         lsu_rtu_wb_pipe4_spec_fail
);

//==========================================================
//                 Internal signals
//==========================================================
logic [6:0]   st_wb_iid;
logic         st_wb_spec_fail;
logic         st_wb_flush;
logic         st_wb_inst_vld;

//==========================================================
//                 Pipeline control signals
//==========================================================
logic         st_wb_pre_inst_vld;
logic         st_wb_pre_spec_fail;
logic         st_wb_pre_flush;
logic [6:0]   st_wb_pre_iid;

//==========================================================
//                 ST_WB stage logic
//==========================================================
assign st_wb_pre_inst_vld   = st_da_wb_cmplt_req;
assign st_wb_pre_spec_fail  = st_da_wb_spec_fail;
assign st_wb_pre_flush      = st_wb_pre_spec_fail;
assign st_wb_pre_iid[6:0]   = st_da_iid[6:0];
//==========================================================
//                 Pipeline Register
//==========================================================
always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b)
    st_wb_inst_vld <= 1'b0;
  else if(rtu_yy_xx_flush)
    st_wb_inst_vld <= 1'b0;
  else if(st_wb_pre_inst_vld)
    st_wb_inst_vld <= 1'b1;
  else
    st_wb_inst_vld <= 1'b0;
end
logic st_wb_expt_vld;
// 2026-10-08 修: 原来只声明了 st_wb_expt_vld, 下面 always_ff 里用到的
// st_wb_expt_addr **没有声明** ⇒ "Identifier not declared", LSU elaborate 失败。
// (对照 load 侧 lsu_ld_wb.sv 是有 `logic [31:0] ld_wb_expt_addr;` 的。)
logic [31:0] st_wb_expt_addr;
always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    st_wb_iid[6:0]        <= 7'b0;
    st_wb_spec_fail       <= 1'b0;
    st_wb_flush           <= 1'b0;
    st_wb_expt_vld        <= 1'b0;
    st_wb_expt_addr       <= 32'b0;
  end
  else if(st_wb_pre_inst_vld) begin
    st_wb_iid[6:0]        <= st_wb_pre_iid[6:0];
    st_wb_spec_fail       <= st_wb_pre_spec_fail;
    st_wb_flush           <= st_wb_pre_flush;
    st_wb_expt_vld        <= st_da_wb_expt_vld;
    st_wb_expt_addr       <= st_da_wb_expt_addr;
  end
end

//==========================================================
//                 Generate interface to RTU
//==========================================================
assign lsu_rtu_wb_pipe4_cmplt      = st_wb_inst_vld;
assign lsu_rtu_wb_pipe4_iid[6:0]   = st_wb_iid[6:0];
assign lsu_rtu_wb_pipe4_spec_fail  = st_wb_spec_fail;
assign lsu_rtu_wb_pipe4_flush      = st_wb_flush;
assign lsu_rtu_wb_pipe4_expt_vld   = st_wb_expt_vld;
assign lsu_rtu_wb_pipe4_expt_addr  = st_wb_expt_addr;

endmodule


