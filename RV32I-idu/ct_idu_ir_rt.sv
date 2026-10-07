module ct_idu_ir_rt (
  input  logic         cpurst_b,
  input  logic         ctrl_ir_stall,
  input  logic         ctrl_rt_inst0_vld,
  input  logic         ctrl_rt_inst1_vld,
  input  logic         ctrl_rt_inst2_vld,
  input  logic [5:0]   dp_rt_inst0_dst_preg,
  input  logic [4:0]   dp_rt_inst0_dst_reg,
  input  logic         dp_rt_inst0_dst_vld,
  input  logic [5:0]   dp_rt_inst0_src0_reg,
  input  logic         dp_rt_inst0_src0_vld,
  input  logic [5:0]   dp_rt_inst0_src1_reg,
  input  logic         dp_rt_inst0_src1_vld,
  input  logic [5:0]   dp_rt_inst1_dst_preg,
  input  logic [4:0]   dp_rt_inst1_dst_reg,
  input  logic         dp_rt_inst1_dst_vld,
  input  logic [5:0]   dp_rt_inst1_src0_reg,
  input  logic         dp_rt_inst1_src0_vld,
  input  logic [5:0]   dp_rt_inst1_src1_reg,
  input  logic         dp_rt_inst1_src1_vld,
  input  logic [5:0]   dp_rt_inst2_dst_preg,
  input  logic [4:0]   dp_rt_inst2_dst_reg,
  input  logic         dp_rt_inst2_dst_vld,
  input  logic [5:0]   dp_rt_inst2_src0_reg,
  input  logic         dp_rt_inst2_src0_vld,
  input  logic [5:0]   dp_rt_inst2_src1_reg,
  input  logic         dp_rt_inst2_src1_vld,
  input  logic [6:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [6:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [6:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic [191:0] rtu_idu_rt_recover_preg,
  input  logic         rtu_yy_xx_flush,
  output logic [5:0]   rt_dp_inst0_rel_preg,
  output logic [6:0]   rt_dp_inst0_src0_data,
  output logic [6:0]   rt_dp_inst0_src1_data,
  output logic [6:0]   rt_dp_inst0_src2_data,
  output logic [5:0]   rt_dp_inst1_rel_preg,
  output logic [6:0]   rt_dp_inst1_src0_data,
  output logic [6:0]   rt_dp_inst1_src1_data,
  output logic [6:0]   rt_dp_inst1_src2_data,
  output logic [5:0]   rt_dp_inst2_rel_preg,
  output logic [6:0]   rt_dp_inst2_src0_data,
  output logic [6:0]   rt_dp_inst2_src1_data,
  output logic [6:0]   rt_dp_inst2_src2_data
);

// &Regs; @27
logic [6:0]   inst0_dst_read_data;
logic [6:0]   inst0_src0_read_data;
logic [6:0]   inst0_src1_read_data;
logic [6:0]   inst1_dst_read_data;
logic [6:0]   inst1_src0_read_data;
logic [6:0]   inst1_src1_read_data;
logic [6:0]   inst2_dst_read_data;
logic [6:0]   inst2_src0_read_data;
logic [6:0]   inst2_src1_read_data;

// &Wires; @28
logic [4:0]   dp_rt_inst0_dst_reg_lsb;
logic [31:0]  dp_rt_inst0_dst_reg_lsb_expand;
logic [4:0]   dp_rt_inst1_dst_reg_lsb;
logic [31:0]  dp_rt_inst1_dst_reg_lsb_expand;
logic [4:0]   dp_rt_inst2_dst_reg_lsb;
logic [31:0]  dp_rt_inst2_dst_reg_lsb_expand;
logic         inst0_src0_read_wb;
logic [5:0]   inst0_src0_read_preg;
logic         inst0_src1_read_wb;
logic [5:0]   inst0_src1_read_preg;
logic         inst0_src2_read_wb;
logic [5:0]   inst0_src2_read_preg;
logic         inst0_write_en;
logic         inst1_src0_read_wb;
logic [5:0]   inst1_src0_read_preg;
logic         inst1_src1_read_wb;
logic [5:0]   inst1_src1_read_preg;
logic         inst1_src2_read_wb;
logic [5:0]   inst1_src2_read_preg;
logic         inst1_write_en;
logic         inst2_src0_read_wb;
logic [5:0]   inst2_src0_read_preg;
logic         inst2_src1_read_wb;
logic [5:0]   inst2_src1_read_preg;
logic         inst2_src2_read_wb;
logic [5:0]   inst2_src2_read_preg;
logic         inst2_write_en;
logic         r_vld;
logic [31:0]  reg_write0_en;
logic [31:0]  reg_write1_en;
logic [31:0]  reg_write2_en;
logic [31:0]  reg_write_en;
logic         rt_inst1_dst_match_inst0;
logic         rt_inst1_src0_match_inst0;
logic         rt_inst1_src1_match_inst0;
logic         rt_inst1_src2_match_inst0;
logic         rt_inst2_dst_match_inst0;
logic         rt_inst2_dst_match_inst1;
logic         rt_inst2_src0_match_inst0;
logic         rt_inst2_src0_match_inst1;
logic         rt_inst2_src1_match_inst0;
logic         rt_inst2_src1_match_inst1;
logic         rt_inst2_src2_match_inst0;
logic         rt_inst2_src2_match_inst1;
logic [191:0] rt_recover_updt_preg;
logic         rt_recover_updt_vld;
logic [191:0] rt_reset_updt_preg;

// 数组声明
logic [6:0]   reg_read_data [0:31];
logic [6:0]   reg_create_data [0:31];
logic         reg_write_en_arr [0:31];

//==========================================================
//                       Parameters
//==========================================================
parameter DEP_WIDTH = 17;

// &Force("bus","dp_rt_dep_info",DEP_WIDTH-1,0); @56

//==========================================================
//                   Instance Entries
//==========================================================
//------------------------x0 entry--------------------------
assign reg_read_data[0][6:0] = 7'b0000001;

//--------------------other register entry------------------
genvar j;
generate
  for (j = 0; j < 32; j = j + 1) begin : gen_ct_idu_ir_rt_entry
    ct_idu_dep_reg_src2_entry x_ct_idu_ir_rt_entry_reg (
      .cpurst_b                          (cpurst_b                          ),
      .rtu_yy_xx_flush                  (rtu_yy_xx_flush                  ),
      .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx ),
      .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx     ),
      .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx ),
      .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx     ),
      .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx     ),
      .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx ),
      .x_create_data                     (reg_create_data[j]                ),
      .x_write_en                        (reg_write_en_arr[j]               ),
      .x_read_data                       (reg_read_data[j]                  )
    );
  end
endgenerate

//==========================================================
//                      Write Port      
//==========================================================
assign dp_rt_inst0_dst_reg_lsb[4:0] = dp_rt_inst0_dst_reg[4:0];
assign dp_rt_inst1_dst_reg_lsb[4:0] = dp_rt_inst1_dst_reg[4:0];
assign dp_rt_inst2_dst_reg_lsb[4:0] = dp_rt_inst2_dst_reg[4:0];

ct_rtu_expand_32  x_ct_rtu_expand_32_dp_rt_inst0_dst_reg_lsb (
  .x_num                          (dp_rt_inst0_dst_reg_lsb       ),
  .x_num_expand                   (dp_rt_inst0_dst_reg_lsb_expand)
);

ct_rtu_expand_32  x_ct_rtu_expand_32_dp_rt_inst1_dst_reg_lsb (
  .x_num                          (dp_rt_inst1_dst_reg_lsb       ),
  .x_num_expand                   (dp_rt_inst1_dst_reg_lsb_expand)
);

ct_rtu_expand_32  x_ct_rtu_expand_32_dp_rt_inst2_dst_reg_lsb (
  .x_num                          (dp_rt_inst2_dst_reg_lsb       ),
  .x_num_expand                   (dp_rt_inst2_dst_reg_lsb_expand)
);

assign inst0_write_en              = ctrl_rt_inst0_vld
                                     && !ctrl_ir_stall
                                     && !rt_recover_updt_vld
                                     &&  dp_rt_inst0_dst_vld;
assign reg_write0_en[31:0]         = dp_rt_inst0_dst_reg_lsb_expand[31:0]
                                     & {32{inst0_write_en}};

assign inst1_write_en              = ctrl_rt_inst1_vld
                                     && !ctrl_ir_stall
                                     && !rt_recover_updt_vld
                                     &&  dp_rt_inst1_dst_vld;
assign reg_write1_en[31:0]         = dp_rt_inst1_dst_reg_lsb_expand[31:0]
                                     & {32{inst1_write_en}};

assign inst2_write_en              = ctrl_rt_inst2_vld
                                     && !ctrl_ir_stall
                                     && !rt_recover_updt_vld
                                     &&  dp_rt_inst2_dst_vld;
assign reg_write2_en[31:0]         = dp_rt_inst2_dst_reg_lsb_expand[31:0]
                                     & {32{inst2_write_en}};

assign rt_reset_updt_preg[191:0] =
         {6'd31, 6'd30, 6'd29, 6'd28, 6'd27, 6'd26, 6'd25, 6'd24,
          6'd23, 6'd22, 6'd21, 6'd20, 6'd19, 6'd18, 6'd17, 6'd16,
          6'd15, 6'd14, 6'd13, 6'd12, 6'd11, 6'd10, 6'd9,  6'd8,
          6'd7,  6'd6,  6'd5,  6'd4,  6'd3,  6'd2,  6'd1,  6'd0};

assign rt_recover_updt_vld         = rtu_yy_xx_flush;
assign rt_recover_updt_preg[191:0] = rtu_idu_rt_recover_preg[191:0];

assign reg_write_en[31:0] = {32{rt_recover_updt_vld}}
                          | reg_write0_en[31:0]
                          | reg_write1_en[31:0]
                          | reg_write2_en[31:0];

// reg_create_preg 生成
genvar jj;
generate
  for(jj=0; jj<32; jj=jj+1) begin : gen_reg_create_preg
    always @(*)
    begin
      if(reg_write2_en[jj])
        reg_create_data[jj][5:0] = dp_rt_inst2_dst_preg[5:0];
      else if(reg_write1_en[jj])
        reg_create_data[jj][5:0] = dp_rt_inst1_dst_preg[5:0];
      else if(reg_write0_en[jj])
        reg_create_data[jj][5:0] = dp_rt_inst0_dst_preg[5:0];
      else
        reg_create_data[jj][5:0] = rt_recover_updt_preg[6*jj+5 : 6*jj];
    end
  end
endgenerate

assign r_vld = rt_recover_updt_vld;

genvar jk;
generate
  for(jk=0; jk<32; jk=jk+1) begin : gen_reg_create_data
    assign reg_create_data[jk][6] = r_vld;
  end
endgenerate

//==========================================================
//                       Read Port
//==========================================================
//-----------------instruction 0 source 0-------------------
always @(*)
begin
  case (dp_rt_inst0_src0_reg[4:0])
    5'd0   : inst0_src0_read_data[6:0] = reg_read_data[0][6:0];
    5'd1   : inst0_src0_read_data[6:0] = reg_read_data[1][6:0];
    5'd2   : inst0_src0_read_data[6:0] = reg_read_data[2][6:0];
    5'd3   : inst0_src0_read_data[6:0] = reg_read_data[3][6:0];
    5'd4   : inst0_src0_read_data[6:0] = reg_read_data[4][6:0];
    5'd5   : inst0_src0_read_data[6:0] = reg_read_data[5][6:0];
    5'd6   : inst0_src0_read_data[6:0] = reg_read_data[6][6:0];
    5'd7   : inst0_src0_read_data[6:0] = reg_read_data[7][6:0];
    5'd8   : inst0_src0_read_data[6:0] = reg_read_data[8][6:0];
    5'd9   : inst0_src0_read_data[6:0] = reg_read_data[9][6:0];
    5'd10  : inst0_src0_read_data[6:0] = reg_read_data[10][6:0];
    5'd11  : inst0_src0_read_data[6:0] = reg_read_data[11][6:0];
    5'd12  : inst0_src0_read_data[6:0] = reg_read_data[12][6:0];
    5'd13  : inst0_src0_read_data[6:0] = reg_read_data[13][6:0];
    5'd14  : inst0_src0_read_data[6:0] = reg_read_data[14][6:0];
    5'd15  : inst0_src0_read_data[6:0] = reg_read_data[15][6:0];
    5'd16  : inst0_src0_read_data[6:0] = reg_read_data[16][6:0];
    5'd17  : inst0_src0_read_data[6:0] = reg_read_data[17][6:0];
    5'd18  : inst0_src0_read_data[6:0] = reg_read_data[18][6:0];
    5'd19  : inst0_src0_read_data[6:0] = reg_read_data[19][6:0];
    5'd20  : inst0_src0_read_data[6:0] = reg_read_data[20][6:0];
    5'd21  : inst0_src0_read_data[6:0] = reg_read_data[21][6:0];
    5'd22  : inst0_src0_read_data[6:0] = reg_read_data[22][6:0];
    5'd23  : inst0_src0_read_data[6:0] = reg_read_data[23][6:0];
    5'd24  : inst0_src0_read_data[6:0] = reg_read_data[24][6:0];
    5'd25  : inst0_src0_read_data[6:0] = reg_read_data[25][6:0];
    5'd26  : inst0_src0_read_data[6:0] = reg_read_data[26][6:0];
    5'd27  : inst0_src0_read_data[6:0] = reg_read_data[27][6:0];
    5'd28  : inst0_src0_read_data[6:0] = reg_read_data[28][6:0];
    5'd29  : inst0_src0_read_data[6:0] = reg_read_data[29][6:0];
    5'd30  : inst0_src0_read_data[6:0] = reg_read_data[30][6:0];
    5'd31  : inst0_src0_read_data[6:0] = reg_read_data[31][6:0];
    default: inst0_src0_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst0_src0_read_wb        = inst0_src0_read_data[0];
assign inst0_src0_read_preg[5:0] = inst0_src0_read_data[6:1];

assign rt_dp_inst0_src0_data[0]   = inst0_src0_read_wb
                                    || !dp_rt_inst0_src0_vld;
assign rt_dp_inst0_src0_data[6:1] = inst0_src0_read_preg[5:0];

//-----------------instruction 0 source 1-------------------
always @(*)
begin
  case (dp_rt_inst0_src1_reg[4:0])
    5'd0   : inst0_src1_read_data[6:0] = reg_read_data[0][6:0];
    5'd1   : inst0_src1_read_data[6:0] = reg_read_data[1][6:0];
    5'd2   : inst0_src1_read_data[6:0] = reg_read_data[2][6:0];
    5'd3   : inst0_src1_read_data[6:0] = reg_read_data[3][6:0];
    5'd4   : inst0_src1_read_data[6:0] = reg_read_data[4][6:0];
    5'd5   : inst0_src1_read_data[6:0] = reg_read_data[5][6:0];
    5'd6   : inst0_src1_read_data[6:0] = reg_read_data[6][6:0];
    5'd7   : inst0_src1_read_data[6:0] = reg_read_data[7][6:0];
    5'd8   : inst0_src1_read_data[6:0] = reg_read_data[8][6:0];
    5'd9   : inst0_src1_read_data[6:0] = reg_read_data[9][6:0];
    5'd10  : inst0_src1_read_data[6:0] = reg_read_data[10][6:0];
    5'd11  : inst0_src1_read_data[6:0] = reg_read_data[11][6:0];
    5'd12  : inst0_src1_read_data[6:0] = reg_read_data[12][6:0];
    5'd13  : inst0_src1_read_data[6:0] = reg_read_data[13][6:0];
    5'd14  : inst0_src1_read_data[6:0] = reg_read_data[14][6:0];
    5'd15  : inst0_src1_read_data[6:0] = reg_read_data[15][6:0];
    5'd16  : inst0_src1_read_data[6:0] = reg_read_data[16][6:0];
    5'd17  : inst0_src1_read_data[6:0] = reg_read_data[17][6:0];
    5'd18  : inst0_src1_read_data[6:0] = reg_read_data[18][6:0];
    5'd19  : inst0_src1_read_data[6:0] = reg_read_data[19][6:0];
    5'd20  : inst0_src1_read_data[6:0] = reg_read_data[20][6:0];
    5'd21  : inst0_src1_read_data[6:0] = reg_read_data[21][6:0];
    5'd22  : inst0_src1_read_data[6:0] = reg_read_data[22][6:0];
    5'd23  : inst0_src1_read_data[6:0] = reg_read_data[23][6:0];
    5'd24  : inst0_src1_read_data[6:0] = reg_read_data[24][6:0];
    5'd25  : inst0_src1_read_data[6:0] = reg_read_data[25][6:0];
    5'd26  : inst0_src1_read_data[6:0] = reg_read_data[26][6:0];
    5'd27  : inst0_src1_read_data[6:0] = reg_read_data[27][6:0];
    5'd28  : inst0_src1_read_data[6:0] = reg_read_data[28][6:0];
    5'd29  : inst0_src1_read_data[6:0] = reg_read_data[29][6:0];
    5'd30  : inst0_src1_read_data[6:0] = reg_read_data[30][6:0];
    5'd31  : inst0_src1_read_data[6:0] = reg_read_data[31][6:0];
    default: inst0_src1_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst0_src1_read_wb        = inst0_src1_read_data[0];
assign inst0_src1_read_preg[5:0] = inst0_src1_read_data[6:1];

assign rt_dp_inst0_src1_data[0]   = inst0_src1_read_wb
                                    || !dp_rt_inst0_src1_vld;
assign rt_dp_inst0_src1_data[6:1] = inst0_src1_read_preg[5:0];

//---------instruction 0 src2/dest reg (for release)--------
always @(*)
begin
  case (dp_rt_inst0_dst_reg[4:0])
    5'd0  : inst0_dst_read_data[6:0] = reg_read_data[0][6:0];
    5'd1  : inst0_dst_read_data[6:0] = reg_read_data[1][6:0];
    5'd2  : inst0_dst_read_data[6:0] = reg_read_data[2][6:0];
    5'd3  : inst0_dst_read_data[6:0] = reg_read_data[3][6:0];
    5'd4  : inst0_dst_read_data[6:0] = reg_read_data[4][6:0];
    5'd5  : inst0_dst_read_data[6:0] = reg_read_data[5][6:0];
    5'd6  : inst0_dst_read_data[6:0] = reg_read_data[6][6:0];
    5'd7  : inst0_dst_read_data[6:0] = reg_read_data[7][6:0];
    5'd8  : inst0_dst_read_data[6:0] = reg_read_data[8][6:0];
    5'd9  : inst0_dst_read_data[6:0] = reg_read_data[9][6:0];
    5'd10 : inst0_dst_read_data[6:0] = reg_read_data[10][6:0];
    5'd11 : inst0_dst_read_data[6:0] = reg_read_data[11][6:0];
    5'd12 : inst0_dst_read_data[6:0] = reg_read_data[12][6:0];
    5'd13 : inst0_dst_read_data[6:0] = reg_read_data[13][6:0];
    5'd14 : inst0_dst_read_data[6:0] = reg_read_data[14][6:0];
    5'd15 : inst0_dst_read_data[6:0] = reg_read_data[15][6:0];
    5'd16 : inst0_dst_read_data[6:0] = reg_read_data[16][6:0];
    5'd17 : inst0_dst_read_data[6:0] = reg_read_data[17][6:0];
    5'd18 : inst0_dst_read_data[6:0] = reg_read_data[18][6:0];
    5'd19 : inst0_dst_read_data[6:0] = reg_read_data[19][6:0];
    5'd20 : inst0_dst_read_data[6:0] = reg_read_data[20][6:0];
    5'd21 : inst0_dst_read_data[6:0] = reg_read_data[21][6:0];
    5'd22 : inst0_dst_read_data[6:0] = reg_read_data[22][6:0];
    5'd23 : inst0_dst_read_data[6:0] = reg_read_data[23][6:0];
    5'd24 : inst0_dst_read_data[6:0] = reg_read_data[24][6:0];
    5'd25 : inst0_dst_read_data[6:0] = reg_read_data[25][6:0];
    5'd26 : inst0_dst_read_data[6:0] = reg_read_data[26][6:0];
    5'd27 : inst0_dst_read_data[6:0] = reg_read_data[27][6:0];
    5'd28 : inst0_dst_read_data[6:0] = reg_read_data[28][6:0];
    5'd29 : inst0_dst_read_data[6:0] = reg_read_data[29][6:0];
    5'd30 : inst0_dst_read_data[6:0] = reg_read_data[30][6:0];
    5'd31 : inst0_dst_read_data[6:0] = reg_read_data[31][6:0];
    default: inst0_dst_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst0_src2_read_wb        = inst0_dst_read_data[0];
assign inst0_src2_read_preg[5:0] = inst0_dst_read_data[6:1];

assign rt_dp_inst0_src2_data[0]   = inst0_src2_read_wb
                                    || !dp_rt_inst0_dst_vld;
assign rt_dp_inst0_src2_data[6:1] = inst0_src2_read_preg[5:0];

assign rt_dp_inst0_rel_preg[5:0] = inst0_dst_read_data[6:1];

//-----------------instruction 1 source 0-------------------
always @(*)
begin
  case (dp_rt_inst1_src0_reg[4:0])
    5'd0  : inst1_src0_read_data[6:0] = reg_read_data[0][6:0];
    5'd1  : inst1_src0_read_data[6:0] = reg_read_data[1][6:0];
    5'd2  : inst1_src0_read_data[6:0] = reg_read_data[2][6:0];
    5'd3  : inst1_src0_read_data[6:0] = reg_read_data[3][6:0];
    5'd4  : inst1_src0_read_data[6:0] = reg_read_data[4][6:0];
    5'd5  : inst1_src0_read_data[6:0] = reg_read_data[5][6:0];
    5'd6  : inst1_src0_read_data[6:0] = reg_read_data[6][6:0];
    5'd7  : inst1_src0_read_data[6:0] = reg_read_data[7][6:0];
    5'd8  : inst1_src0_read_data[6:0] = reg_read_data[8][6:0];
    5'd9  : inst1_src0_read_data[6:0] = reg_read_data[9][6:0];
    5'd10 : inst1_src0_read_data[6:0] = reg_read_data[10][6:0];
    5'd11 : inst1_src0_read_data[6:0] = reg_read_data[11][6:0];
    5'd12 : inst1_src0_read_data[6:0] = reg_read_data[12][6:0];
    5'd13 : inst1_src0_read_data[6:0] = reg_read_data[13][6:0];
    5'd14 : inst1_src0_read_data[6:0] = reg_read_data[14][6:0];
    5'd15 : inst1_src0_read_data[6:0] = reg_read_data[15][6:0];
    5'd16 : inst1_src0_read_data[6:0] = reg_read_data[16][6:0];
    5'd17 : inst1_src0_read_data[6:0] = reg_read_data[17][6:0];
    5'd18 : inst1_src0_read_data[6:0] = reg_read_data[18][6:0];
    5'd19 : inst1_src0_read_data[6:0] = reg_read_data[19][6:0];
    5'd20 : inst1_src0_read_data[6:0] = reg_read_data[20][6:0];
    5'd21 : inst1_src0_read_data[6:0] = reg_read_data[21][6:0];
    5'd22 : inst1_src0_read_data[6:0] = reg_read_data[22][6:0];
    5'd23 : inst1_src0_read_data[6:0] = reg_read_data[23][6:0];
    5'd24 : inst1_src0_read_data[6:0] = reg_read_data[24][6:0];
    5'd25 : inst1_src0_read_data[6:0] = reg_read_data[25][6:0];
    5'd26 : inst1_src0_read_data[6:0] = reg_read_data[26][6:0];
    5'd27 : inst1_src0_read_data[6:0] = reg_read_data[27][6:0];
    5'd28 : inst1_src0_read_data[6:0] = reg_read_data[28][6:0];
    5'd29 : inst1_src0_read_data[6:0] = reg_read_data[29][6:0];
    5'd30 : inst1_src0_read_data[6:0] = reg_read_data[30][6:0];
    5'd31 : inst1_src0_read_data[6:0] = reg_read_data[31][6:0];
    default: inst1_src0_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst1_src0_read_wb        = inst1_src0_read_data[0];
assign inst1_src0_read_preg[5:0] = inst1_src0_read_data[6:1];

assign rt_inst1_src0_match_inst0 =
            ctrl_rt_inst1_vld && dp_rt_inst1_src0_vld
         && ctrl_rt_inst0_vld && dp_rt_inst0_dst_vld
         && (dp_rt_inst0_dst_reg[4:0] == dp_rt_inst1_src0_reg[4:0])
         && (dp_rt_inst0_dst_reg[4:0] != 5'd0);

always @(*)
  if(rt_inst1_src0_match_inst0) begin
    rt_dp_inst1_src0_data[0]     = 1'b0;
    rt_dp_inst1_src0_data[6:1]   = dp_rt_inst0_dst_preg[5:0];
  end
  else begin
    rt_dp_inst1_src0_data[0]     = inst1_src0_read_wb
                                   || !dp_rt_inst1_src0_vld;
    rt_dp_inst1_src0_data[6:1]   = inst1_src0_read_preg[5:0];
  end

//-----------------instruction 1 source 1-------------------
always @(*)
begin
  case (dp_rt_inst1_src1_reg[4:0])
    5'd0  : inst1_src1_read_data[6:0] = reg_read_data[0][6:0];
    5'd1  : inst1_src1_read_data[6:0] = reg_read_data[1][6:0];
    5'd2  : inst1_src1_read_data[6:0] = reg_read_data[2][6:0];
    5'd3  : inst1_src1_read_data[6:0] = reg_read_data[3][6:0];
    5'd4  : inst1_src1_read_data[6:0] = reg_read_data[4][6:0];
    5'd5  : inst1_src1_read_data[6:0] = reg_read_data[5][6:0];
    5'd6  : inst1_src1_read_data[6:0] = reg_read_data[6][6:0];
    5'd7  : inst1_src1_read_data[6:0] = reg_read_data[7][6:0];
    5'd8  : inst1_src1_read_data[6:0] = reg_read_data[8][6:0];
    5'd9  : inst1_src1_read_data[6:0] = reg_read_data[9][6:0];
    5'd10 : inst1_src1_read_data[6:0] = reg_read_data[10][6:0];
    5'd11 : inst1_src1_read_data[6:0] = reg_read_data[11][6:0];
    5'd12 : inst1_src1_read_data[6:0] = reg_read_data[12][6:0];
    5'd13 : inst1_src1_read_data[6:0] = reg_read_data[13][6:0];
    5'd14 : inst1_src1_read_data[6:0] = reg_read_data[14][6:0];
    5'd15 : inst1_src1_read_data[6:0] = reg_read_data[15][6:0];
    5'd16 : inst1_src1_read_data[6:0] = reg_read_data[16][6:0];
    5'd17 : inst1_src1_read_data[6:0] = reg_read_data[17][6:0];
    5'd18 : inst1_src1_read_data[6:0] = reg_read_data[18][6:0];
    5'd19 : inst1_src1_read_data[6:0] = reg_read_data[19][6:0];
    5'd20 : inst1_src1_read_data[6:0] = reg_read_data[20][6:0];
    5'd21 : inst1_src1_read_data[6:0] = reg_read_data[21][6:0];
    5'd22 : inst1_src1_read_data[6:0] = reg_read_data[22][6:0];
    5'd23 : inst1_src1_read_data[6:0] = reg_read_data[23][6:0];
    5'd24 : inst1_src1_read_data[6:0] = reg_read_data[24][6:0];
    5'd25 : inst1_src1_read_data[6:0] = reg_read_data[25][6:0];
    5'd26 : inst1_src1_read_data[6:0] = reg_read_data[26][6:0];
    5'd27 : inst1_src1_read_data[6:0] = reg_read_data[27][6:0];
    5'd28 : inst1_src1_read_data[6:0] = reg_read_data[28][6:0];
    5'd29 : inst1_src1_read_data[6:0] = reg_read_data[29][6:0];
    5'd30 : inst1_src1_read_data[6:0] = reg_read_data[30][6:0];
    5'd31 : inst1_src1_read_data[6:0] = reg_read_data[31][6:0];
    default: inst1_src1_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst1_src1_read_wb        = inst1_src1_read_data[0];
assign inst1_src1_read_preg[5:0] = inst1_src1_read_data[6:1];

assign rt_inst1_src1_match_inst0 =
            ctrl_rt_inst1_vld && dp_rt_inst1_src1_vld
         && ctrl_rt_inst0_vld && dp_rt_inst0_dst_vld
         && (dp_rt_inst0_dst_reg[4:0] == dp_rt_inst1_src1_reg[4:0])
         && (dp_rt_inst0_dst_reg[4:0] != 5'd0);

always @(*)
begin
  if(rt_inst1_src1_match_inst0) begin
    rt_dp_inst1_src1_data[0]     = 1'b0;
    rt_dp_inst1_src1_data[6:1]   = dp_rt_inst0_dst_preg[5:0];
  end
  else begin
    rt_dp_inst1_src1_data[0]     = inst1_src1_read_wb
                                   || !dp_rt_inst1_src1_vld;
    rt_dp_inst1_src1_data[6:1]   = inst1_src1_read_preg[5:0];
  end
end

//---------instruction 1 src2/dest reg (for release)--------
always @(*)
begin
  case (dp_rt_inst1_dst_reg[4:0])
    5'd0  : inst1_dst_read_data[6:0] = reg_read_data[0][6:0];
    5'd1  : inst1_dst_read_data[6:0] = reg_read_data[1][6:0];
    5'd2  : inst1_dst_read_data[6:0] = reg_read_data[2][6:0];
    5'd3  : inst1_dst_read_data[6:0] = reg_read_data[3][6:0];
    5'd4  : inst1_dst_read_data[6:0] = reg_read_data[4][6:0];
    5'd5  : inst1_dst_read_data[6:0] = reg_read_data[5][6:0];
    5'd6  : inst1_dst_read_data[6:0] = reg_read_data[6][6:0];
    5'd7  : inst1_dst_read_data[6:0] = reg_read_data[7][6:0];
    5'd8  : inst1_dst_read_data[6:0] = reg_read_data[8][6:0];
    5'd9  : inst1_dst_read_data[6:0] = reg_read_data[9][6:0];
    5'd10 : inst1_dst_read_data[6:0] = reg_read_data[10][6:0];
    5'd11 : inst1_dst_read_data[6:0] = reg_read_data[11][6:0];
    5'd12 : inst1_dst_read_data[6:0] = reg_read_data[12][6:0];
    5'd13 : inst1_dst_read_data[6:0] = reg_read_data[13][6:0];
    5'd14 : inst1_dst_read_data[6:0] = reg_read_data[14][6:0];
    5'd15 : inst1_dst_read_data[6:0] = reg_read_data[15][6:0];
    5'd16 : inst1_dst_read_data[6:0] = reg_read_data[16][6:0];
    5'd17 : inst1_dst_read_data[6:0] = reg_read_data[17][6:0];
    5'd18 : inst1_dst_read_data[6:0] = reg_read_data[18][6:0];
    5'd19 : inst1_dst_read_data[6:0] = reg_read_data[19][6:0];
    5'd20 : inst1_dst_read_data[6:0] = reg_read_data[20][6:0];
    5'd21 : inst1_dst_read_data[6:0] = reg_read_data[21][6:0];
    5'd22 : inst1_dst_read_data[6:0] = reg_read_data[22][6:0];
    5'd23 : inst1_dst_read_data[6:0] = reg_read_data[23][6:0];
    5'd24 : inst1_dst_read_data[6:0] = reg_read_data[24][6:0];
    5'd25 : inst1_dst_read_data[6:0] = reg_read_data[25][6:0];
    5'd26 : inst1_dst_read_data[6:0] = reg_read_data[26][6:0];
    5'd27 : inst1_dst_read_data[6:0] = reg_read_data[27][6:0];
    5'd28 : inst1_dst_read_data[6:0] = reg_read_data[28][6:0];
    5'd29 : inst1_dst_read_data[6:0] = reg_read_data[29][6:0];
    5'd30 : inst1_dst_read_data[6:0] = reg_read_data[30][6:0];
    5'd31 : inst1_dst_read_data[6:0] = reg_read_data[31][6:0];
    default: inst1_dst_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst1_src2_read_wb        = inst1_dst_read_data[0];
assign inst1_src2_read_preg[5:0] = inst1_dst_read_data[6:1];

assign rt_inst1_src2_match_inst0 =
            ctrl_rt_inst1_vld && dp_rt_inst1_dst_vld
         && ctrl_rt_inst0_vld && dp_rt_inst0_dst_vld
         && (dp_rt_inst0_dst_reg[4:0] == dp_rt_inst1_dst_reg[4:0])
         && (dp_rt_inst0_dst_reg[4:0] != 5'd0);

always @(*)
begin
  if(rt_inst1_src2_match_inst0) begin
    rt_dp_inst1_src2_data[0]     = 1'b0;
    rt_dp_inst1_src2_data[6:1]   = dp_rt_inst0_dst_preg[5:0];
  end
  else begin
    rt_dp_inst1_src2_data[0]     = inst1_src2_read_wb
                                   || !dp_rt_inst1_dst_vld;
    rt_dp_inst1_src2_data[6:1]   = inst1_src2_read_preg[5:0];
  end
end

assign rt_inst1_dst_match_inst0 =
            ctrl_rt_inst1_vld && dp_rt_inst1_dst_vld
         && ctrl_rt_inst0_vld && dp_rt_inst0_dst_vld
         && (dp_rt_inst0_dst_reg[4:0] == dp_rt_inst1_dst_reg[4:0])
         && (dp_rt_inst0_dst_reg[4:0] != 5'd0);

always @(*)
begin
  if(rt_inst1_dst_match_inst0)
    rt_dp_inst1_rel_preg[5:0] = dp_rt_inst0_dst_preg[5:0];
  else
    rt_dp_inst1_rel_preg[5:0] = inst1_dst_read_data[6:1];
end

//-----------------instruction 2 source 0-------------------
always @(*)
begin
  case (dp_rt_inst2_src0_reg[4:0])
    5'd0   : inst2_src0_read_data[6:0] = reg_read_data[0][6:0];
    5'd1   : inst2_src0_read_data[6:0] = reg_read_data[1][6:0];
    5'd2   : inst2_src0_read_data[6:0] = reg_read_data[2][6:0];
    5'd3   : inst2_src0_read_data[6:0] = reg_read_data[3][6:0];
    5'd4   : inst2_src0_read_data[6:0] = reg_read_data[4][6:0];
    5'd5   : inst2_src0_read_data[6:0] = reg_read_data[5][6:0];
    5'd6   : inst2_src0_read_data[6:0] = reg_read_data[6][6:0];
    5'd7   : inst2_src0_read_data[6:0] = reg_read_data[7][6:0];
    5'd8   : inst2_src0_read_data[6:0] = reg_read_data[8][6:0];
    5'd9   : inst2_src0_read_data[6:0] = reg_read_data[9][6:0];
    5'd10  : inst2_src0_read_data[6:0] = reg_read_data[10][6:0];
    5'd11  : inst2_src0_read_data[6:0] = reg_read_data[11][6:0];
    5'd12  : inst2_src0_read_data[6:0] = reg_read_data[12][6:0];
    5'd13  : inst2_src0_read_data[6:0] = reg_read_data[13][6:0];
    5'd14  : inst2_src0_read_data[6:0] = reg_read_data[14][6:0];
    5'd15  : inst2_src0_read_data[6:0] = reg_read_data[15][6:0];
    5'd16  : inst2_src0_read_data[6:0] = reg_read_data[16][6:0];
    5'd17  : inst2_src0_read_data[6:0] = reg_read_data[17][6:0];
    5'd18  : inst2_src0_read_data[6:0] = reg_read_data[18][6:0];
    5'd19  : inst2_src0_read_data[6:0] = reg_read_data[19][6:0];
    5'd20  : inst2_src0_read_data[6:0] = reg_read_data[20][6:0];
    5'd21  : inst2_src0_read_data[6:0] = reg_read_data[21][6:0];
    5'd22  : inst2_src0_read_data[6:0] = reg_read_data[22][6:0];
    5'd23  : inst2_src0_read_data[6:0] = reg_read_data[23][6:0];
    5'd24  : inst2_src0_read_data[6:0] = reg_read_data[24][6:0];
    5'd25  : inst2_src0_read_data[6:0] = reg_read_data[25][6:0];
    5'd26  : inst2_src0_read_data[6:0] = reg_read_data[26][6:0];
    5'd27  : inst2_src0_read_data[6:0] = reg_read_data[27][6:0];
    5'd28  : inst2_src0_read_data[6:0] = reg_read_data[28][6:0];
    5'd29  : inst2_src0_read_data[6:0] = reg_read_data[29][6:0];
    5'd30  : inst2_src0_read_data[6:0] = reg_read_data[30][6:0];
    5'd31  : inst2_src0_read_data[6:0] = reg_read_data[31][6:0];
    default: inst2_src0_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst2_src0_read_wb        = inst2_src0_read_data[0];
assign inst2_src0_read_preg[5:0] = inst2_src0_read_data[6:1];

assign rt_inst2_src0_match_inst0 =
            ctrl_rt_inst2_vld && dp_rt_inst2_src0_vld
         && ctrl_rt_inst0_vld && dp_rt_inst0_dst_vld
         && (dp_rt_inst0_dst_reg[4:0] == dp_rt_inst2_src0_reg[4:0])
         && (dp_rt_inst0_dst_reg[4:0] != 5'd0);

assign rt_inst2_src0_match_inst1 =
            ctrl_rt_inst2_vld && dp_rt_inst2_src0_vld
         && ctrl_rt_inst1_vld && dp_rt_inst1_dst_vld
         && (dp_rt_inst1_dst_reg[4:0] == dp_rt_inst2_src0_reg[4:0])
         && (dp_rt_inst1_dst_reg[4:0] != 5'd0);

always @(*)
begin
  if(rt_inst2_src0_match_inst1) begin
    rt_dp_inst2_src0_data[0]     = 1'b0;
    rt_dp_inst2_src0_data[6:1]   = dp_rt_inst1_dst_preg[5:0];
  end
  else if(rt_inst2_src0_match_inst0) begin
    rt_dp_inst2_src0_data[0]     = 1'b0;
    rt_dp_inst2_src0_data[6:1]   = dp_rt_inst0_dst_preg[5:0];
  end
  else begin
    rt_dp_inst2_src0_data[0]     = inst2_src0_read_wb
                                   || !dp_rt_inst2_src0_vld;
    rt_dp_inst2_src0_data[6:1]   = inst2_src0_read_preg[5:0];
  end
end

//-----------------instruction 2 source 1-------------------
always @(*)
begin
  case (dp_rt_inst2_src1_reg[4:0])
    5'd0   : inst2_src1_read_data[6:0] = reg_read_data[0][6:0];
    5'd1   : inst2_src1_read_data[6:0] = reg_read_data[1][6:0];
    5'd2   : inst2_src1_read_data[6:0] = reg_read_data[2][6:0];
    5'd3   : inst2_src1_read_data[6:0] = reg_read_data[3][6:0];
    5'd4   : inst2_src1_read_data[6:0] = reg_read_data[4][6:0];
    5'd5   : inst2_src1_read_data[6:0] = reg_read_data[5][6:0];
    5'd6   : inst2_src1_read_data[6:0] = reg_read_data[6][6:0];
    5'd7   : inst2_src1_read_data[6:0] = reg_read_data[7][6:0];
    5'd8   : inst2_src1_read_data[6:0] = reg_read_data[8][6:0];
    5'd9   : inst2_src1_read_data[6:0] = reg_read_data[9][6:0];
    5'd10  : inst2_src1_read_data[6:0] = reg_read_data[10][6:0];
    5'd11  : inst2_src1_read_data[6:0] = reg_read_data[11][6:0];
    5'd12  : inst2_src1_read_data[6:0] = reg_read_data[12][6:0];
    5'd13  : inst2_src1_read_data[6:0] = reg_read_data[13][6:0];
    5'd14  : inst2_src1_read_data[6:0] = reg_read_data[14][6:0];
    5'd15  : inst2_src1_read_data[6:0] = reg_read_data[15][6:0];
    5'd16  : inst2_src1_read_data[6:0] = reg_read_data[16][6:0];
    5'd17  : inst2_src1_read_data[6:0] = reg_read_data[17][6:0];
    5'd18  : inst2_src1_read_data[6:0] = reg_read_data[18][6:0];
    5'd19  : inst2_src1_read_data[6:0] = reg_read_data[19][6:0];
    5'd20  : inst2_src1_read_data[6:0] = reg_read_data[20][6:0];
    5'd21  : inst2_src1_read_data[6:0] = reg_read_data[21][6:0];
    5'd22  : inst2_src1_read_data[6:0] = reg_read_data[22][6:0];
    5'd23  : inst2_src1_read_data[6:0] = reg_read_data[23][6:0];
    5'd24  : inst2_src1_read_data[6:0] = reg_read_data[24][6:0];
    5'd25  : inst2_src1_read_data[6:0] = reg_read_data[25][6:0];
    5'd26  : inst2_src1_read_data[6:0] = reg_read_data[26][6:0];
    5'd27  : inst2_src1_read_data[6:0] = reg_read_data[27][6:0];
    5'd28  : inst2_src1_read_data[6:0] = reg_read_data[28][6:0];
    5'd29  : inst2_src1_read_data[6:0] = reg_read_data[29][6:0];
    5'd30  : inst2_src1_read_data[6:0] = reg_read_data[30][6:0];
    5'd31  : inst2_src1_read_data[6:0] = reg_read_data[31][6:0];
    default: inst2_src1_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst2_src1_read_wb        = inst2_src1_read_data[0];
assign inst2_src1_read_preg[5:0] = inst2_src1_read_data[6:1];

assign rt_inst2_src1_match_inst0 =
            ctrl_rt_inst2_vld && dp_rt_inst2_src1_vld
         && ctrl_rt_inst0_vld && dp_rt_inst0_dst_vld
         && (dp_rt_inst0_dst_reg[4:0] == dp_rt_inst2_src1_reg[4:0])
         && (dp_rt_inst0_dst_reg[4:0] != 5'd0);

assign rt_inst2_src1_match_inst1 =
            ctrl_rt_inst2_vld && dp_rt_inst2_src1_vld
         && ctrl_rt_inst1_vld && dp_rt_inst1_dst_vld
         && (dp_rt_inst1_dst_reg[4:0] == dp_rt_inst2_src1_reg[4:0])
         && (dp_rt_inst1_dst_reg[4:0] != 5'd0);

always @(*)
begin
  if(rt_inst2_src1_match_inst1) begin
    rt_dp_inst2_src1_data[0]     = 1'b0;
    rt_dp_inst2_src1_data[6:1]   = dp_rt_inst1_dst_preg[5:0];
  end
  else if(rt_inst2_src1_match_inst0) begin
    rt_dp_inst2_src1_data[0]     = 1'b0;
    rt_dp_inst2_src1_data[6:1]   = dp_rt_inst0_dst_preg[5:0];
  end
  else begin
    rt_dp_inst2_src1_data[0]     = inst2_src1_read_wb
                                   || !dp_rt_inst2_src1_vld;
    rt_dp_inst2_src1_data[6:1]   = inst2_src1_read_preg[5:0];
  end
end

//---------instruction 2 src2/dest reg (for release)--------
always @(*)
begin
  case (dp_rt_inst2_dst_reg[4:0])
    5'd0   : inst2_dst_read_data[6:0] = reg_read_data[0][6:0];
    5'd1   : inst2_dst_read_data[6:0] = reg_read_data[1][6:0];
    5'd2   : inst2_dst_read_data[6:0] = reg_read_data[2][6:0];
    5'd3   : inst2_dst_read_data[6:0] = reg_read_data[3][6:0];
    5'd4   : inst2_dst_read_data[6:0] = reg_read_data[4][6:0];
    5'd5   : inst2_dst_read_data[6:0] = reg_read_data[5][6:0];
    5'd6   : inst2_dst_read_data[6:0] = reg_read_data[6][6:0];
    5'd7   : inst2_dst_read_data[6:0] = reg_read_data[7][6:0];
    5'd8   : inst2_dst_read_data[6:0] = reg_read_data[8][6:0];
    5'd9   : inst2_dst_read_data[6:0] = reg_read_data[9][6:0];
    5'd10  : inst2_dst_read_data[6:0] = reg_read_data[10][6:0];
    5'd11  : inst2_dst_read_data[6:0] = reg_read_data[11][6:0];
    5'd12  : inst2_dst_read_data[6:0] = reg_read_data[12][6:0];
    5'd13  : inst2_dst_read_data[6:0] = reg_read_data[13][6:0];
    5'd14  : inst2_dst_read_data[6:0] = reg_read_data[14][6:0];
    5'd15  : inst2_dst_read_data[6:0] = reg_read_data[15][6:0];
    5'd16  : inst2_dst_read_data[6:0] = reg_read_data[16][6:0];
    5'd17  : inst2_dst_read_data[6:0] = reg_read_data[17][6:0];
    5'd18  : inst2_dst_read_data[6:0] = reg_read_data[18][6:0];
    5'd19  : inst2_dst_read_data[6:0] = reg_read_data[19][6:0];
    5'd20  : inst2_dst_read_data[6:0] = reg_read_data[20][6:0];
    5'd21  : inst2_dst_read_data[6:0] = reg_read_data[21][6:0];
    5'd22  : inst2_dst_read_data[6:0] = reg_read_data[22][6:0];
    5'd23  : inst2_dst_read_data[6:0] = reg_read_data[23][6:0];
    5'd24  : inst2_dst_read_data[6:0] = reg_read_data[24][6:0];
    5'd25  : inst2_dst_read_data[6:0] = reg_read_data[25][6:0];
    5'd26  : inst2_dst_read_data[6:0] = reg_read_data[26][6:0];
    5'd27  : inst2_dst_read_data[6:0] = reg_read_data[27][6:0];
    5'd28  : inst2_dst_read_data[6:0] = reg_read_data[28][6:0];
    5'd29  : inst2_dst_read_data[6:0] = reg_read_data[29][6:0];
    5'd30  : inst2_dst_read_data[6:0] = reg_read_data[30][6:0];
    5'd31  : inst2_dst_read_data[6:0] = reg_read_data[31][6:0];
    default: inst2_dst_read_data[6:0] = {7{1'bx}};
  endcase
end

assign inst2_src2_read_wb        = inst2_dst_read_data[0];
assign inst2_src2_read_preg[5:0] = inst2_dst_read_data[6:1];

assign rt_inst2_src2_match_inst0 =
            ctrl_rt_inst2_vld && dp_rt_inst2_dst_vld
         && ctrl_rt_inst0_vld && dp_rt_inst0_dst_vld
         && (dp_rt_inst0_dst_reg[4:0] == dp_rt_inst2_dst_reg[4:0])
         && (dp_rt_inst0_dst_reg[4:0] != 5'd0);

assign rt_inst2_src2_match_inst1 =
            ctrl_rt_inst2_vld && dp_rt_inst2_dst_vld
         && ctrl_rt_inst1_vld && dp_rt_inst1_dst_vld
         && (dp_rt_inst1_dst_reg[4:0] == dp_rt_inst2_dst_reg[4:0])
         && (dp_rt_inst1_dst_reg[4:0] != 5'd0);

always @(*)
begin
  if(rt_inst2_src2_match_inst1) begin
    rt_dp_inst2_src2_data[0]     = 1'b0;
    rt_dp_inst2_src2_data[6:1]   = dp_rt_inst1_dst_preg[5:0];
  end
  else if(rt_inst2_src2_match_inst0) begin
    rt_dp_inst2_src2_data[0]     = 1'b0;
    rt_dp_inst2_src2_data[6:1]   = dp_rt_inst0_dst_preg[5:0];
  end
  else begin
    rt_dp_inst2_src2_data[0]     = inst2_src2_read_wb
                                   || !dp_rt_inst2_dst_vld;
    rt_dp_inst2_src2_data[6:1]   = inst2_src2_read_preg[5:0];
  end
end

assign rt_inst2_dst_match_inst0 =
            ctrl_rt_inst2_vld && dp_rt_inst2_dst_vld
         && ctrl_rt_inst0_vld && dp_rt_inst0_dst_vld
         && (dp_rt_inst0_dst_reg[4:0] == dp_rt_inst2_dst_reg[4:0])
         && (dp_rt_inst0_dst_reg[4:0] != 5'd0);

assign rt_inst2_dst_match_inst1 =
            ctrl_rt_inst2_vld && dp_rt_inst2_dst_vld
         && ctrl_rt_inst1_vld && dp_rt_inst1_dst_vld
         && (dp_rt_inst1_dst_reg[4:0] == dp_rt_inst2_dst_reg[4:0])
         && (dp_rt_inst1_dst_reg[4:0] != 5'd0);

always @(*)
begin
  if(rt_inst2_dst_match_inst1)
    rt_dp_inst2_rel_preg[5:0] = dp_rt_inst1_dst_preg[5:0];
  else if(rt_inst2_dst_match_inst0)
    rt_dp_inst2_rel_preg[5:0] = dp_rt_inst0_dst_preg[5:0];
  else
    rt_dp_inst2_rel_preg[5:0] = inst2_dst_read_data[6:1];
end

// &ModuleEnd; @2160
endmodule

