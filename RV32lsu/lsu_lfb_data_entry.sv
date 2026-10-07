module ct_lsu_lfb_data_entry (
    input  logic [127:0] biu_lsu_r_data,
    input  logic         biu_lsu_r_last,
    input  logic         biu_lsu_r_vld,
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [2:0]   lfb_addr_entry_linefill_permit,
    input  logic [1:0]   lfb_biu_id_2to0,
    input  logic         lfb_biu_r_id_hit,
    input  logic         lfb_data_entry_create_vld_x,
    input  logic [1:0]   lfb_first_pass_ptr,
    input  logic         lfb_lf_sm_data_grnt_x,
    input  logic         lfb_lf_sm_data_pop_req_x,
    input  logic         lfb_r_resp_err,

    output logic [2:0]   lfb_data_entry_addr_id_v,
    output logic [2:0]   lfb_data_entry_addr_pop_req_v,
    output logic [255:0] lfb_data_entry_data_v,
    output logic         lfb_data_entry_last_x,
    output logic         lfb_data_entry_lf_sm_req_x,
    output logic         lfb_data_entry_vld_x
);

// 内部寄存器
logic [2:0]   lfb_data_entry_addr_id;
logic [1:0]   lfb_data_entry_biu_id;
logic         lfb_data_entry_bus_err;
logic         lfb_data_entry_cnt;
logic [255:0] lfb_data_entry_data;
logic         lfb_data_entry_last;
logic         lfb_data_entry_lf_sm_req_success;
logic [1:0]   lfb_data_entry_pass_ptr;
logic         lfb_data_entry_vld;

// 内部组合信号
logic         lfb_data_entry_abort;
logic [2:0]   lfb_data_entry_addr_pop_req;
logic         lfb_data_entry_create_vld;
logic         lfb_data_entry_finish_line;
logic         lfb_data_entry_lf_sm_req;
logic         lfb_data_entry_linefill_permit;
logic         lfb_data_entry_pass_data0_vld;
logic         lfb_data_entry_pass_data1_vld;
logic         lfb_data_entry_pass_data_last;
logic         lfb_data_entry_pass_data_vld;
logic         lfb_data_entry_pop_vld;
logic         lfb_data_entry_r_id_hit;
logic         lfb_lf_sm_data_grnt;
logic         lfb_lf_sm_data_pop_req;

//==========================================================
//                 Registers
//==========================================================
//+-----------+
//| entry_vld |
//+-----------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_data_entry_vld <= 1'b0;
  else if (lfb_data_entry_pop_vld)
    lfb_data_entry_vld <= 1'b0;
  else if (lfb_data_entry_create_vld)
    lfb_data_entry_vld <= 1'b1;
end

//+--------------------+
//| addr_entry_id/r_id |
//+--------------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_data_entry_biu_id[1:0] <= 2'b0;
  else if (lfb_data_entry_create_vld)
    lfb_data_entry_biu_id[1:0] <= lfb_biu_id_2to0[1:0];
end

//+------+-----+------------+
//| cnt  |     | bypass_ptr |
//+------+-----+------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    lfb_data_entry_cnt           <= 1'b0;
    lfb_data_entry_last          <= 1'b0;
    lfb_data_entry_pass_ptr[1:0] <= 2'b1;
  end
  else if (lfb_data_entry_create_vld)
  begin
    lfb_data_entry_cnt           <= 1'b0;
    lfb_data_entry_last          <= biu_lsu_r_last;
    lfb_data_entry_pass_ptr[1:0] <= {lfb_first_pass_ptr[0],
                                     lfb_first_pass_ptr[1]};
  end
  else if (lfb_data_entry_pass_data_vld)
  begin
    lfb_data_entry_cnt           <= !lfb_data_entry_cnt;
    lfb_data_entry_last          <= biu_lsu_r_last;
    lfb_data_entry_pass_ptr[1:0] <= {lfb_data_entry_pass_ptr[0],
                                     lfb_data_entry_pass_ptr[1]};
  end
end

//+-----------+
//| bus error |
//+-----------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_data_entry_bus_err <= 1'b0;
  else if (lfb_data_entry_create_vld)
    lfb_data_entry_bus_err <= lfb_r_resp_err;
  else if (lfb_data_entry_pass_data_vld && lfb_r_resp_err)
    lfb_data_entry_bus_err <= 1'b1;
end

//+------+
//| data |
//+------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_data_entry_data[127:0] <= 128'b0;
  else if (lfb_data_entry_pass_data0_vld)
    lfb_data_entry_data[127:0] <= biu_lsu_r_data[127:0];
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_data_entry_data[255:128] <= 128'b0;
  else if (lfb_data_entry_pass_data1_vld)
    lfb_data_entry_data[255:128] <= biu_lsu_r_data[127:0];
end

//+-------------------+
//| lf_sm_req_success |
//+-------------------+
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
    lfb_data_entry_lf_sm_req_success <= 1'b0;
  else if (lfb_data_entry_create_vld)
    lfb_data_entry_lf_sm_req_success <= 1'b0;
  else if (lfb_lf_sm_data_grnt)
    lfb_data_entry_lf_sm_req_success <= 1'b1;
end

//==========================================================
//                        Wires
//==========================================================
//------------------pass data signal------------------------
assign lfb_data_entry_r_id_hit = lfb_data_entry_vld
                                 && biu_lsu_r_vld
                                 && lfb_biu_r_id_hit
                                 && (lfb_data_entry_biu_id[1:0] == lfb_biu_id_2to0[1:0]);

assign lfb_data_entry_pass_data_vld = lfb_data_entry_create_vld
                                      || lfb_data_entry_r_id_hit;

assign lfb_data_entry_pass_data0_vld = (lfb_data_entry_create_vld && lfb_first_pass_ptr[0])
                                       || (lfb_data_entry_r_id_hit && lfb_data_entry_pass_ptr[0]);

assign lfb_data_entry_pass_data1_vld = (lfb_data_entry_create_vld && lfb_first_pass_ptr[1])
                                       || (lfb_data_entry_r_id_hit && lfb_data_entry_pass_ptr[1]);

//==========================================================
//                 Generate req/pop signal
//==========================================================
//------------------last signal---------------------------
assign lfb_data_entry_finish_line = lfb_data_entry_vld
                                    && (lfb_data_entry_cnt == 1'b1)
                                    && lfb_data_entry_last;

assign lfb_data_entry_pass_data_last = lfb_data_entry_vld
                                       && biu_lsu_r_last
                                       && lfb_data_entry_pass_data_vld;

//------------------addr entry signal-----------------------
always @( lfb_data_entry_biu_id[1:0])
begin
  lfb_data_entry_addr_id = 3'b0;
  case (lfb_data_entry_biu_id[1:0])
    2'd0: lfb_data_entry_addr_id[0] = 1'b1;
    2'd1: lfb_data_entry_addr_id[1] = 1'b1;
    2'd2: lfb_data_entry_addr_id[2] = 1'b1;
    default: lfb_data_entry_addr_id = 3'b0;
  endcase
end

assign lfb_data_entry_linefill_permit = |(lfb_data_entry_addr_id[2:0]
                                          & lfb_addr_entry_linefill_permit[2:0]);

assign lfb_data_entry_abort = lfb_data_entry_linefill_permit
                              && lfb_data_entry_bus_err;

assign lfb_data_entry_addr_pop_req[2:0] = lfb_data_entry_addr_id
                                         & {3{lfb_data_entry_abort}};

//------------------lf req signal---------------------------
assign lfb_data_entry_lf_sm_req = lfb_data_entry_vld
                                  && !lfb_data_entry_lf_sm_req_success
                                  && !lfb_data_entry_bus_err
                                  && lfb_data_entry_linefill_permit
                                  && (lfb_data_entry_finish_line
                                      || (lfb_data_entry_pass_data_last
                                          && !lfb_r_resp_err));

//------------------pop signal------------------------------
assign lfb_data_entry_pop_vld = lfb_data_entry_abort
                                || lfb_lf_sm_data_pop_req;

//==========================================================
//                 Generate interface
//==========================================================
//------------------input-----------------------------------
assign lfb_data_entry_create_vld        = lfb_data_entry_create_vld_x;
assign lfb_lf_sm_data_grnt              = lfb_lf_sm_data_grnt_x;
assign lfb_lf_sm_data_pop_req           = lfb_lf_sm_data_pop_req_x;

//------------------output----------------------------------
assign lfb_data_entry_vld_x             = lfb_data_entry_vld;
assign lfb_data_entry_addr_id_v         = lfb_data_entry_addr_id;
assign lfb_data_entry_data_v            = lfb_data_entry_data;
assign lfb_data_entry_last_x            = lfb_data_entry_last;
assign lfb_data_entry_addr_pop_req_v    = lfb_data_entry_addr_pop_req;
assign lfb_data_entry_lf_sm_req_x       = lfb_data_entry_lf_sm_req;

endmodule
