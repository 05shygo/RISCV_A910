module ct_lsu_ld_wb #(
    parameter int PA_WIDTH = 32,
    parameter BYTE  = 2'b00,
    parameter HALF  = 2'b01,
    parameter WORD  = 2'b10,
    parameter DWORD = 2'b11,
    parameter VMB_ENTRY = 8
)(
    // 输入
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [31:0]  ld_da_addr,
    input  logic [6:0]   ld_da_iid,
    input  logic [5:0]   ld_da_preg,
    input  logic [3:0]   ld_da_preg_sign_sel,
    input  logic         ld_da_wb_cmplt_req,
    input  logic [31:0]  ld_da_wb_data,
    input  logic         ld_da_wb_data_req,
    input  logic         rb_ld_wb_bus_err,
    input  logic [31:0]  rb_ld_wb_bus_err_addr,
    input  logic         rb_ld_wb_cmplt_req,
    input  logic [31:0]  rb_ld_wb_data,
    input  logic [6:0]   rb_ld_wb_data_iid,
    input  logic         rb_ld_wb_data_req,
    input  logic [6:0]   rb_ld_wb_iid,
    input  logic [5:0]   rb_ld_wb_preg,
    input  logic [3:0]   rb_ld_wb_preg_sign_sel,
    input  logic         rtu_yy_xx_flush,

    // 输出
    output logic         ld_wb_data_vld,
    output logic         ld_wb_inst_vld,
    output logic         ld_wb_rb_cmplt_grnt,
    output logic         ld_wb_rb_data_grnt,
    output logic [31:0]  lsu_rtu_async_expt_addr,
    output logic         lsu_rtu_async_expt_vld,
    output logic         lsu_rtu_wb_pipe3_cmplt,
    output logic [6:0]   lsu_rtu_wb_pipe3_iid,
    output logic [63:0]  lsu_rtu_wb_pipe3_wb_preg_expand,
    output logic         lsu_rtu_wb_pipe3_wb_preg_vld,
    output logic [5:0]   lsu_idu_wb_pipe3_wb_preg,
    output logic [31:0]  lsu_idu_wb_pipe3_wb_preg_data,
    output logic [63:0]  lsu_idu_wb_pipe3_wb_preg_expand,
    output logic         lsu_idu_wb_pipe3_wb_preg_vld
);

//------------------------------------------------------------------
// 内部信号声明
//------------------------------------------------------------------
logic         ld_wb_da_cmplt_grnt;
logic         ld_wb_da_data_grnt;
logic         ld_wb_pre_inst_vld;
logic [6:0]   ld_wb_pre_iid;
logic         ld_wb_pre_data_vld;
logic         ld_wb_pre_bus_err;
logic [39:0]  ld_wb_pre_data_addr;
logic [6:0]   ld_wb_pre_data_iid;
logic [5:0]   ld_wb_pre_preg;
logic [63:0]  ld_wb_pre_preg_expand;
logic [63:0]  ld_wb_pre_data;
logic         ld_wb_pre_preg_wb_vld;
logic [3:0]   ld_wb_pre_preg_sign_sel;

logic [6:0]   ld_wb_iid;
logic         ld_wb_bus_err;
logic [39:0]  ld_wb_data_addr;
logic [6:0]   ld_wb_data_iid;
logic [63:0]  ld_wb_data;
logic [5:0]   ld_wb_data_preg;
logic [63:0]  ld_wb_data_preg_expand;
logic [3:0]   ld_wb_preg_sign_sel;
logic [63:0]  ld_wb_data_sign0;
logic [63:0]  ld_wb_data_sign1;
logic [63:0]  ld_wb_data_sign2;
logic [63:0]  ld_wb_data_sign3;
logic [63:0]  ld_wb_preg_data_sign_extend;

logic [63:0]  ld_da_preg_expand;
logic [63:0]  rb_ld_wb_preg_expand;

//------------------------------------------------------------------
// 子模块实例化
//------------------------------------------------------------------
ct_rtu_expand_64 x_lsu_ld_da_preg_expand (
    .x_num        (ld_da_preg[5:0]),
    .x_num_expand (ld_da_preg_expand[63:0])
);

ct_rtu_expand_64 x_lsu_rb_ld_wb_preg_expand (
    .x_num        (rb_ld_wb_preg[5:0]),
    .x_num_expand (rb_ld_wb_preg_expand[63:0])
);

//==========================================================
//                 arbitrate WB stage request
//==========================================================
//------------------complete part---------------------------
//-----------grant signal---------------
assign ld_wb_da_cmplt_grnt      = ld_da_wb_cmplt_req;
assign ld_wb_rb_cmplt_grnt      = !ld_da_wb_cmplt_req
                                  &&  rb_ld_wb_cmplt_req;

//-----------signal select--------------
assign ld_wb_pre_inst_vld       = ld_da_wb_cmplt_req
                                  ||  rb_ld_wb_cmplt_req;


assign ld_wb_pre_iid[6:0]       = {7{ld_wb_da_cmplt_grnt}}  & ld_da_iid[6:0]
                                  | {7{ld_wb_rb_cmplt_grnt}}  & rb_ld_wb_iid[6:0];

//------------------data part-------------------------------
//-----------grant signal---------------
assign ld_wb_da_data_grnt       = ld_da_wb_data_req;
assign ld_wb_rb_data_grnt       = !ld_da_wb_data_req
                                  &&  rb_ld_wb_data_req;

//-----------signal select--------------
assign ld_wb_pre_data_vld       = ld_da_wb_data_req
                                  ||  rb_ld_wb_data_req;

assign ld_wb_pre_bus_err        = ld_wb_rb_data_grnt &&  rb_ld_wb_bus_err;

assign ld_wb_pre_data_addr[31:0] = {PA_WIDTH{ld_wb_da_data_grnt}} & ld_da_addr[31:0]
                                   | {PA_WIDTH{ld_wb_rb_data_grnt}} & rb_ld_wb_bus_err_addr[31:0];

assign ld_wb_pre_data_iid[6:0]  = {7{ld_wb_da_data_grnt}} & ld_da_iid[6:0]
                                  | {7{ld_wb_rb_data_grnt}} & rb_ld_wb_data_iid[6:0];

assign ld_wb_pre_preg[5:0]      = {7{ld_wb_da_data_grnt}} & ld_da_preg[5:0]
                                  | {7{ld_wb_rb_data_grnt}} & rb_ld_wb_preg[5:0];

assign ld_wb_pre_preg_expand[63:0] = {96{ld_wb_da_data_grnt}} & ld_da_preg_expand[63:0]
                                     | {96{ld_wb_rb_data_grnt}} & rb_ld_wb_preg_expand[63:0];

assign ld_wb_pre_data[31:0]     = ld_da_wb_data_req
                                  ? ld_da_wb_data[31:0]
                                  : rb_ld_wb_data[31:0];

assign ld_wb_pre_preg_wb_vld    = ld_wb_pre_data_vld;

assign ld_wb_pre_preg_sign_sel[3:0] = {4{ld_wb_da_data_grnt}} & ld_da_preg_sign_sel[3:0]
                                      | {4{ld_wb_rb_data_grnt}} & rb_ld_wb_preg_sign_sel[3:0];

//==========================================================
//                 Pipeline Register
//==========================================================
//------------------complete part---------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_wb_inst_vld      <=  1'b0;
  else if(rtu_yy_xx_flush)
    ld_wb_inst_vld      <=  1'b0;
  else if(ld_wb_pre_inst_vld)
    ld_wb_inst_vld      <=  1'b1;
  else
    ld_wb_inst_vld      <=  1'b0;
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_wb_iid[6:0]        <=  7'b0;
  else if(ld_wb_pre_inst_vld)
    ld_wb_iid[6:0]        <=  ld_wb_pre_iid[6:0];
end

//------------------data part-------------------------------
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_wb_data_vld          <=  1'b0;
  else if(rtu_yy_xx_flush)
    ld_wb_data_vld          <=  1'b0;
  else if(ld_wb_pre_data_vld)
    ld_wb_data_vld          <=  1'b1;
  else
    ld_wb_data_vld          <=  1'b0;
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_wb_bus_err       <=  1'b0;
  else if(rtu_yy_xx_flush)
    ld_wb_bus_err       <=  1'b0;
  else if(ld_wb_pre_data_vld)
    ld_wb_bus_err       <=  ld_wb_pre_bus_err;
  else
    ld_wb_bus_err       <=  1'b0;
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    ld_wb_data_addr[31:0] <=  {PA_WIDTH{1'b0}};
    ld_wb_data_iid[6:0]   <=  7'b0;
  end
  else if(ld_wb_pre_data_vld)
  begin
    ld_wb_data_addr[31:0] <=  ld_wb_pre_data_addr[31:0];
    ld_wb_data_iid[6:0]   <=  ld_wb_pre_data_iid[6:0];
  end
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_wb_data[31:0] <=  32'b0;
  else if(ld_wb_pre_data_vld)
    ld_wb_data[31:0] <=  ld_wb_pre_data[31:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    ld_wb_data_preg[5:0]          <=  7'b0;
    ld_wb_data_preg_expand[63:0]  <=  96'b0;
    ld_wb_preg_sign_sel[3:0]      <=  4'b0;
  end
  else if(ld_wb_pre_data_vld)
  begin
    ld_wb_data_preg[5:0]          <=  ld_wb_pre_preg[5:0];
    ld_wb_data_preg_expand[63:0]  <=  ld_wb_pre_preg_expand[63:0];
    ld_wb_preg_sign_sel[3:0]      <=  ld_wb_pre_preg_sign_sel[3:0];
  end
end

//==========================================================
//            Data settle and Sign extend
//==========================================================
assign ld_wb_data_sign0[31:0]       = ld_wb_data[31:0];
assign ld_wb_data_sign1[31:0]       = {{24{ld_wb_data[7]}},ld_wb_data[7:0]};
assign ld_wb_data_sign2[31:0]       = {{16{ld_wb_data[15]}},ld_wb_data[15:0]};
assign ld_wb_data_sign3[31:0]       = {{0{ld_wb_data[31]}},ld_wb_data[31:0]};

assign ld_wb_preg_data_sign_extend[31:0] = {32{ld_wb_preg_sign_sel[3]}} & ld_wb_data_sign3[31:0]
                                           | {32{ld_wb_preg_sign_sel[2]}} & ld_wb_data_sign2[31:0]
                                           | {32{ld_wb_preg_sign_sel[1]}} & ld_wb_data_sign1[31:0]
                                           | {32{ld_wb_preg_sign_sel[0]}} & ld_wb_data_sign0[31:0];

//==========================================================
//                 Generate interface to rtu
//==========================================================
assign lsu_rtu_wb_pipe3_cmplt         = ld_wb_inst_vld;
assign lsu_rtu_wb_pipe3_iid[6:0]      = ld_wb_iid[6:0];

assign lsu_rtu_wb_pipe3_wb_preg_vld   = ld_wb_pre_preg_wb_vld;
assign lsu_rtu_wb_pipe3_wb_preg_expand[63:0] = ld_wb_data_preg_expand[63:0];

assign lsu_rtu_async_expt_vld         = ld_wb_data_vld && ld_wb_bus_err;
assign lsu_rtu_async_expt_addr[31:0]  = (ld_wb_data_vld && ld_wb_bus_err)
                                        ? ld_wb_data_addr[31:0]
                                        : {PA_WIDTH{1'b0}};

assign lsu_idu_wb_pipe3_wb_preg_vld          = ld_wb_pre_preg_wb_vld;
assign lsu_idu_wb_pipe3_wb_preg[5:0]         = ld_wb_data_preg[5:0];
assign lsu_idu_wb_pipe3_wb_preg_expand[63:0] = ld_wb_data_preg_expand[63:0];
assign lsu_idu_wb_pipe3_wb_preg_data[31:0]   = ld_wb_preg_data_sign_extend[31:0];

// &ModuleEnd; @1056
endmodule