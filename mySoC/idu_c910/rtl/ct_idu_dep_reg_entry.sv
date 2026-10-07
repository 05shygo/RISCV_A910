module ct_idu_dep_reg_entry (
  input  logic         cpurst_b,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush,
  input  logic [6:0]   x_create_data,
  input  logic         x_write_en,
  output logic [6:0]   x_read_data
);

//==========================================================
//                   Internal Signals
//==========================================================
logic [5:0]  x_create_preg;
logic        x_create_wb;
logic [5:0]  x_read_preg;
logic        x_read_wb;
logic [5:0]  preg;
logic        wb;
logic        pipe0_wb;
logic        pipe1_wb;
logic        pipe3_wb;
logic        write_back;
logic        wb_update;

//==========================================================
//                  Create and Read Bus
//==========================================================
assign x_create_preg[5:0] = x_create_data[6:1];
assign x_create_wb        = x_create_data[0];

assign x_read_data[6:1]   = x_read_preg[5:0];
assign x_read_data[0]     = x_read_wb;

//==========================================================
//                     Write Back Valid
//==========================================================
//write back valid shows whether the result is written back
//into PRF : 1 stands for the result is in PRF

//-------------Update value of Write Back Bit---------------
//prepare write back signal
assign pipe0_wb = iu_idu_ex2_pipe0_wb_preg_vld_dupx
                  && (iu_idu_ex2_pipe0_wb_preg_dupx[5:0] == preg[5:0]);
assign pipe1_wb = iu_idu_ex2_pipe1_wb_preg_vld_dupx
                  && (iu_idu_ex2_pipe1_wb_preg_dupx[5:0] == preg[5:0]);
assign pipe3_wb = lsu_idu_wb_pipe3_wb_preg_vld_dupx
                  && (lsu_idu_wb_pipe3_wb_preg_dupx[5:0] == preg[5:0]);
assign write_back = wb
                    || pipe0_wb
                    || pipe1_wb
                    || pipe3_wb;
//1.if wb_vld is already be 1, just hold 1
//2.if this result is writing back to PRF, set wb to 1
assign x_read_wb  = wb_update;
assign wb_update  = wb || write_back;

always @(posedge forever_cpuclk or negedge cpurst_b)
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
assign x_read_preg[5:0] = preg[5:0];

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    preg[5:0] <= 6'b0;
  else if(x_write_en)
    preg[5:0] <= x_create_preg[5:0];
  else
    preg[5:0] <= preg[5:0];
end

// &ModuleEnd; @203
endmodule