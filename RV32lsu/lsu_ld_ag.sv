module lsu_ld_ag #(
  parameter int IID_WIDTH  = 6,
  parameter int LSIQ_ENTRY = 16,
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
  input  logic                         idu_lsu_ld_unalign_2nd,
  input  logic                         idu_lsu_ld_sign_extend,
  input  logic [6:0]                   idu_lsu_ld_iid,
  input  logic [LSIQ_ENTRY-1:0]        idu_lsu_ld_lch_entry,
  input  logic                         idu_lsu_ld_oldest,
  input  logic [6:0]                   idu_lsu_ld_preg,
  input  logic [11:0]                  idu_lsu_ld_offset,
  input  logic [12:0]                  idu_lsu_ld_offset_plus,
  input  logic [31:0]                  idu_lsu_ld_src,

  //==========================================================
  // RTU -> LSU
  //==========================================================
  input  logic                         rtu_yy_xx_flush,

  input  logic                         rtu_yy_xx_commit0,
  input  logic [6:0]                   rtu_yy_xx_commit0_iid,

  input  logic                         rtu_yy_xx_commit1,
  input  logic [6:0]                   rtu_yy_xx_commit1_iid,

  input  logic                         rtu_yy_xx_commit2,
  input  logic [6:0]                   rtu_yy_xx_commit2_iid,

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
  output logic                         ld_ag_secd,
  output logic                         ld_ag_sign_extend,
  output logic [6:0]                   ld_ag_iid,
  output logic [LSIQ_ENTRY-1:0]        ld_ag_lsid,
  output logic                         ld_ag_old,
  output logic [6:0]                   ld_ag_preg,
  output logic                         ld_ag_boundary,
  output logic                         ld_ag_acclr_en,
  output logic                         ld_ag_dc_fwd_bypass_en,
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

  output logic [15:0]                   ld_ag_bytes_vld1,
  output logic [15:0]                   ld_ag_bytes_vld,
  output logic [27:0]                   ld_ag_addr1_to4,
  output logic [31:0]                   ld_ag_dc_addr0,
  output logic                          ld_ag_raw_new,
  output logic [LSIQ_ENTRY-1:0]         ld_ag_stall_restart_entry
);

//==========================================================
// Internal registers
//==========================================================
logic                         ld_ag_inst_vld;
logic                         ld_rf_inst_vld;
logic                         ld_ag_clk;
logic                         ld_ag_addr_plus_sel;

logic [31:0]                  ld_ag_offset;
logic [31:0]                  ld_ag_base;


//==========================================================
// Address generation
//==========================================================
logic [63:0]                  ld_ag_addr_ori;
logic [63:0]                  ld_ag_va_ori;
logic [31:0]                  ld_ag_addr;
logic [31:0]                  ld_ag_addr_plus;

logic [31:0]                  ld_ag_offset_plus;

logic [4:0]                   ld_ag_va_add_access_size;

logic [3:0]                   ld_ag_access_size_ori;
logic [3:0]                   ld_ag_access_size;


//==========================================================
// Boundary / Unalign
//==========================================================
logic                         ld_ag_boundary_unmask;
logic                         ld_ag_ld_inst;

logic                         ld_ag_va_plus_sel;

logic                         ld_ag_dcache_stall_unmask;
logic                         ld_ag_stall_ori;
logic                         ld_ag_stall_vld;
logic                         ld_ag_stall_mask;


//==========================================================
// Byte valid
//==========================================================
logic [15:0]                  ld_ag_le_bytes_vld_high_bits_full;
logic [15:0]                  ld_ag_le_bytes_vld_low_bits_full;

logic [15:0]                  ld_ag_le_bytes_vld_cross;
logic [15:0]                  ld_ag_le_bytes_vld_low_cross_bits;

logic [15:0]                  ld_ag_le_bytes_vld_high_bits;

logic [15:0]                  ld_ag_bytes_vld_low_cross_bits;
logic [15:0]                  ld_ag_bytes_vld_high_bits;


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
logic                         ld_ag_cmit_hit0;
logic                         ld_ag_cmit_hit1;
logic                         ld_ag_cmit_hit2;
logic                         ld_ag_cmit;


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
    ld_ag_secd                  <=  1'b0;
    ld_ag_sign_extend           <=  1'b0;
    ld_ag_iid[6:0]              <=  7'b0;
    ld_ag_lsid[LSIQ_ENTRY-1:0]  <=  {LSIQ_ENTRY{1'b0}};
    ld_ag_old                   <=  1'b0;
    ld_ag_preg[6:0]             <=  7'b0;
  end
  else if(!ld_ag_stall_vld  &&  idu_lsu_ld_sel)
  begin
    ld_ag_inst_size[1:0]        <=  idu_lsu_ld_inst_size[1:0];
    ld_ag_secd                  <=  idu_lsu_ld_unalign_2nd;
    ld_ag_sign_extend           <=  idu_lsu_ld_sign_extend;
    ld_ag_iid[6:0]              <=  idu_lsu_ld_iid[6:0];
    ld_ag_lsid[LSIQ_ENTRY-1:0]  <=  idu_lsu_ld_lch_entry[LSIQ_ENTRY-1:0];
    ld_ag_old                   <=  idu_lsu_ld_oldest;
    ld_ag_preg[6:0]             <=  idu_lsu_ld_preg[6:0];
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
always @(posedge ld_ag_clk or negedge cpurst_b)
begin
  if (!cpurst_b)
    ld_ag_offset_plus[12:0]  <=  13'h0;
  else if (!ld_ag_stall_vld &&  ld_rf_inst_vld)
    ld_ag_offset_plus[12:0]  <=  idu_lsu_ld_offset_plus[12:0];
end

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

assign ld_ag_addr_plus[31:0]          = ld_ag_base[31:0]
                                      + {{19{ld_ag_offset_plus[12]}},ld_ag_offset_plus[12:0]};

assign ld_ag_addr1_to4[27:0] = ld_ag_addr_ori[31:4];
//assign ld_ag_offset_plus[31:0]     = ld_ag_offset[31:0] + 32'h10;
//if misalign without page, then select ori va
assign ld_ag_addr_plus_sel            = ld_ag_boundary_unmask
                                      &&  ld_ag_ld_inst 
                                      &&  !ld_ag_secd;

assign ld_ag_addr[31:0]               = ld_ag_addr_plus_sel
                                      ? ld_ag_addr_plus[31:0]
                                      : ld_ag_addr_ori[31:0]; 

//---------------boundary---------------
assign ld_ag_va_add_access_size[4:0]  = {1'b0,ld_ag_addr_ori[3:0]} + {1'b0,ld_ag_access_size[3:0]};
assign ld_ag_boundary_unmask  = ld_ag_va_add_access_size[4];

assign ld_ag_boundary = (ld_ag_boundary_unmask
                            ||  ld_ag_secd)
                        &&  ld_ag_ld_inst;

//==========================================================
//            Generate unalign, bytes_vld
//==========================================================
//---------------inst access size---------------
// access size is used to select bytes_vld and boundary judge
parameter BYTE        = 2'b00,
          HALF        = 2'b01,
          WORD        = 2'b10;


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


assign ld_ag_acclr_en         = ld_ag_boundary & !ld_ag_secd;

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

assign ld_ag_le_bytes_vld_low_cross_bits[15:0]  = ld_ag_boundary_unmask
                                                  ? ld_ag_le_bytes_vld_low_bits_full[15:0]
                                                  : ld_ag_le_bytes_vld_cross[15:0]; 

assign ld_ag_le_bytes_vld_high_bits[15:0]   = ld_ag_le_bytes_vld_high_bits_full[15:0];
//-----------select bytes_vld-----------
assign ld_ag_bytes_vld_low_cross_bits[15:0] = ld_ag_le_bytes_vld_low_cross_bits[15:0];

assign ld_ag_bytes_vld_high_bits[15:0]  = ld_ag_le_bytes_vld_high_bits[15:0];

//used for 
//1.lq create
//2.da data_merge when acclr_en
//bytes_vld1 is the bytes_vld of lower addr when there is a first(bigger) boundary ld inst
assign ld_ag_bytes_vld1[15:0] =  ld_ag_bytes_vld_high_bits[15:0];

assign ld_ag_bytes_vld[15:0]  =  ld_ag_secd
                                 ? ld_ag_bytes_vld_high_bits[15:0]
                                 : ld_ag_bytes_vld_low_cross_bits[15:0];

assign ld_ag_dc_fwd_bypass_en = !ld_ag_boundary;


//==========================================================
//        Generage commit signal
//==========================================================
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
always @( ld_ag_va_add_access_size[3:2]
       or ld_ag_va_ori[3:2]
       or ld_ag_boundary
       or ld_ag_secd)
begin
casez({ld_ag_boundary,ld_ag_secd,ld_ag_va_ori[3:2],ld_ag_va_add_access_size[3:2]})
  {1'b0,1'b?,2'b00,2'b00}:bank_en_low_ori[3:0] = 4'b0001;
  {1'b0,1'b?,2'b00,2'b01}:bank_en_low_ori[3:0] = 4'b0011;
  {1'b0,1'b?,2'b00,2'b10}:bank_en_low_ori[3:0] = 4'b0111;
  {1'b0,1'b?,2'b00,2'b11}:bank_en_low_ori[3:0] = 4'b1111;
  {1'b0,1'b?,2'b01,2'b01}:bank_en_low_ori[3:0] = 4'b0010;
  {1'b0,1'b?,2'b01,2'b10}:bank_en_low_ori[3:0] = 4'b0110;
  {1'b0,1'b?,2'b01,2'b11}:bank_en_low_ori[3:0] = 4'b1110;
  {1'b0,1'b?,2'b10,2'b10}:bank_en_low_ori[3:0] = 4'b0100;
  {1'b0,1'b?,2'b10,2'b11}:bank_en_low_ori[3:0] = 4'b1100;
  {1'b0,1'b?,2'b11,2'b11}:bank_en_low_ori[3:0] = 4'b1000;
  {1'b1,1'b0,2'b??,2'b00}:bank_en_low_ori[3:0] = 4'b0001;
  {1'b1,1'b0,2'b??,2'b01}:bank_en_low_ori[3:0] = 4'b0011;
  {1'b1,1'b0,2'b??,2'b10}:bank_en_low_ori[3:0] = 4'b0111;
  {1'b1,1'b0,2'b??,2'b11}:bank_en_low_ori[3:0] = 4'b1111;
  {1'b1,1'b1,2'b00,2'b??}:bank_en_low_ori[3:0] = 4'b1111;
  {1'b1,1'b1,2'b01,2'b??}:bank_en_low_ori[3:0] = 4'b1110;
  {1'b1,1'b1,2'b10,2'b??}:bank_en_low_ori[3:0] = 4'b1100;
  {1'b1,1'b1,2'b11,2'b??}:bank_en_low_ori[3:0] = 4'b1000;
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

assign ld_ag_stall_vld            = ld_ag_stall_ori
                                    && !ld_ag_stall_mask;

ct_rtu_compare_iid  x_lsu_rf_compare_ld_ag_iid (
  .x_iid0                    (idu_lsu_ld_iid[6:0]),
  .x_iid0_older              (rf_iid_older_than_ld_ag  ),
  .x_iid1                    (ld_ag_iid[6:0]           )
);

assign ld_ag_stall_mask = idu_lsu_ld_sel
                          && rf_iid_older_than_ld_ag;


assign ld_ag_stall_restart_entry[LSIQ_ENTRY-1:0] =
        ld_ag_stall_mask ? ld_ag_lsid[LSIQ_ENTRY-1:0]
                         : idu_lsu_ld_lch_entry[LSIQ_ENTRY-1:0];

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