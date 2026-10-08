module lsu_ld_dc #(
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
    parameter int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1
)(
    //==========================================================
    // Clock / Reset
    //==========================================================
    input  logic                          forever_cpuclk,
    input  logic                          cpurst_b,

    //==========================================================
    // LSU_LD_AG -> DC  Input
    //==========================================================
    input  logic                          ld_ag_dc_inst_vld,
    input  logic [1:0]                    ld_ag_inst_size,
    input  logic                          ld_ag_secd,
    input  logic                          ld_ag_sign_extend,
    input  logic [6:0]                    ld_ag_iid,
    input  logic [LSIQ_ENTRY-1:0]         ld_ag_lsid,
    input  logic                          ld_ag_old,
    input  logic [5:0]                    ld_ag_preg,
    input  logic                          ld_ag_boundary,
    input  logic                          ld_ag_acclr_en,
    input  logic                          ld_ag_dc_fwd_bypass_en,
    input  logic [15:0]                   ld_ag_bytes_vld1,
    input  logic [15:0]                   ld_ag_bytes_vld,
    input  logic                          ld_ag_raw_new,
    input  logic [27:0]                   ld_ag_addr1_to4,
    input  logic [31:0]                   ld_ag_dc_addr0,

    //==========================================================
    // 来自其他模块 Input
    //==========================================================
    input  logic                          st_dc_chk_st_inst_vld,
    input  logic [15:0]                   st_dc_bytes_vld,
    input  logic [31:0]                   st_dc_addr0,
    input  logic                          lq_ld_dc_inst_hit,
    input  logic                          lq_ld_dc_full,
    input  logic                          lq_ld_dc_less2,
    input  logic [INDEX_WIDTH-1:0]        dcache_idx,
    input  logic                          dcache_arb_ld_dc_borrow_vld,
    input  logic                          dcache_arb_ld_dc_settle_way,
    input  logic [45:0]                   dcache_lsu_ld_tag_dout,
    input  logic                          cb_ld_dc_addr_hit,
    input  logic                          sq_ld_dc_cancel_acc_req,
    input  logic                          sq_ld_dc_fwd_req,
    input  logic                          wmb_ld_dc_cancel_acc_req,
    input  logic                          wmb_ld_dc_fwd_req,
    input  logic [15:0]                   wmb_fwd_bytes_vld,
    input  logic                          rtu_yy_xx_flush,
    input  logic                          sq_ld_dc_addr1_dep_discard,

    //==========================================================
    // LSU_LD_DC -> DA / 对外 Output
    //==========================================================
    output logic                          ld_dc_da_inst_vld,
    output logic                          ld_dc_borrow_vld,
    output logic                          ld_dc_settle_way,                 
    output logic [1:0]                    ld_dc_inst_size,
    output logic [27:0]                   ld_dc_addr1_to4,
    output logic                          ld_dc_boundary,
    output logic                          ld_dc_secd,
    output logic                          ld_dc_sign_extend,
    output logic [6:0]                    ld_dc_iid,
    output logic [LSIQ_ENTRY-1:0]         ld_dc_lsid,
    output logic                          ld_dc_old,
    output logic [5:0]                    ld_dc_preg,
    output logic [15:0]                   ld_dc_bytes_vld,
    output logic [15:0]                   ld_dc_bytes_vld1,
    output logic                          ld_dc_acclr_en,
    output logic                          ld_dc_da_cb_merge_en,
    output logic                          ld_dc_raw_new,
    output logic [31:0]                   ld_dc_addr0,
    output logic                          ld_dc_cb_addr_create_vld,
    output logic [27:0]                   ld_dc_cb_addr_tto4,
    output logic                          ld_dc_chk_ld_inst_vld,
    output logic                          ld_dc_chk_ld_addr1_vld,
    output logic                          ld_dc_chk_ld_bypass_vld,
    output logic [LSIQ_ENTRY-1:0]         ld_dc_idu_lq_full,
    output logic [LSIQ_ENTRY-1:0]         ld_dc_imme_wakeup,
    output logic                          ld_dc_hit_low_region,
    output logic                          ld_dc_hit_high_region,
    output logic                          ld_dc_dcache_hit,
    output logic [7:0]                    ld_dc_da_data_rot_sel,
    output logic [3:0]                    ld_dc_preg_sign_sel,

    output logic [15:0]                   ld_dc_fwd_bytes_vld,                   
    output logic                          ld_dc_fwd_sq_vld,                    
    output logic                          ld_dc_fwd_wmb_vld,

    output logic                          ld_dc_lq_create_vld,
    output logic                          ld_dc_lq_create1_vld


);

// Data size constants
localparam logic [1:0] BYTE  = 2'b00;
localparam logic [1:0] HALF  = 2'b01;
localparam logic [1:0] WORD  = 2'b10;

//====================================================================
// 内部信号声明（时序寄存器 + 组合逻辑信号）
//====================================================================
logic                          ld_dc_inst_vld;
logic                          ld_dc_inst_chk_vld;
logic                          ld_dc_restart_vld;
logic                          ld_dc_depd_imme_restart_req;
logic                          ld_dc_depd_st_dc;
logic                          ld_dc_depd_st_dc2;
logic                          ld_dc_depd_st_dc3;
logic                          ld_dc_fwd_bypass_en;
logic                          ld_dc_lq_full_req;

logic [31:0]                   ld_dc_cmp_st_dc_addr0;
logic                          ld_dc_raw_addr_tto4_hit;
logic                          ld_dc_raw_addr1_tto4_hit;
logic                          ld_dc_raw_do_hit;




logic [45:0]                   ld_dc_dcache_tag_array;
logic                          ld_dc_way0_tag_hit;
logic                          ld_dc_way1_tag_hit;
logic                          ld_dc_dcache_valid0;
logic                          ld_dc_dcache_valid1;
logic                          ld_dc_hit_way0;
logic                          ld_dc_hit_way1;



logic [3:0]                    ld_dc_rot_sel_final;


logic                          cb_create_hit_idx;


logic [LSIQ_ENTRY-1:0]         ld_dc_mask_lsid;

//====================================================================
// Load DC valid register
//====================================================================
// &Force("output","ld_dc_borrow_vld"); @167
always @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b) begin
        ld_dc_inst_vld <= 1'b0;
    end
    else if(rtu_yy_xx_flush) begin
        ld_dc_inst_vld <= 1'b0;
    end
    else if(ld_ag_dc_inst_vld) begin
        ld_dc_inst_vld <= 1'b1;
    end
    else begin
        ld_dc_inst_vld <= 1'b0;
    end
end

//====================================================================
// borrow vld register
//====================================================================
// &Force("output","ld_dc_borrow_vld"); @167
always @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b) begin
        ld_dc_borrow_vld <= 1'b0;
    end
    else if(dcache_arb_ld_dc_borrow_vld) begin
        ld_dc_borrow_vld <= 1'b1;
    end
    else begin
        ld_dc_borrow_vld <= 1'b0;
    end
end

always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if (!cpurst_b)
  begin
    ld_dc_settle_way                    <=  1'b0;
  end
  else if(dcache_arb_ld_dc_borrow_vld)
  begin
    ld_dc_settle_way                    <=  dcache_arb_ld_dc_settle_way;
  end
end

//====================================================================
// LD AG -> DC stage pipeline register (你之前补全复位的这一组)
//====================================================================
always @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b) begin
        ld_dc_inst_size[1:0]     <= 2'b0;
        ld_dc_addr1_to4[27:0]    <= 28'b0;
        ld_dc_boundary           <= 1'b0;
        ld_dc_secd               <= 1'b0;
        ld_dc_sign_extend        <= 1'b0;
        ld_dc_iid[6:0]           <= 7'b0;
        ld_dc_lsid[LSIQ_ENTRY-1:0] <= {LSIQ_ENTRY{1'b0}};
        ld_dc_old                <= 1'b0;
        ld_dc_preg[5:0]          <= 7'b0;
        ld_dc_bytes_vld[15:0]    <= 16'b0;
        ld_dc_bytes_vld1[15:0]   <= 16'b0;
        ld_dc_acclr_en           <= 1'b0;
        ld_dc_raw_new            <= 1'b0;
    end
    else if ( ld_ag_dc_inst_vld) begin
        ld_dc_inst_size[1:0]     <= ld_ag_inst_size[1:0];
        ld_dc_addr1_to4[27:0]    <= ld_ag_addr1_to4[27:0];
        ld_dc_boundary           <= ld_ag_boundary;
        ld_dc_secd               <= ld_ag_secd;
        ld_dc_sign_extend        <= ld_ag_sign_extend;
        ld_dc_iid[6:0]           <= ld_ag_iid[6:0];
        ld_dc_lsid[LSIQ_ENTRY-1:0] <= ld_ag_lsid[LSIQ_ENTRY-1:0];
        ld_dc_old                <= ld_ag_old; // 原代码写 ld_ag_oldest，输入端口只有 ld_ag_old，注意核对RTL
        ld_dc_preg[5:0]          <= ld_ag_preg[5:0];
        ld_dc_bytes_vld[15:0]    <= ld_ag_bytes_vld[15:0];
        ld_dc_bytes_vld1[15:0]   <= ld_ag_bytes_vld1[15:0];
        ld_dc_acclr_en           <= ld_ag_acclr_en;
        ld_dc_raw_new            <= ld_ag_raw_new;
        ld_dc_fwd_bypass_en   <= ld_ag_dc_fwd_bypass_en;
    end
end

//------------------inst/borrow share part------------------
//+-------+
//| addr0 |
//+-------+
// &Force("output","ld_dc_addr0"); @437
always @(posedge forever_cpuclk or negedge cpurst_b) begin
    if (!cpurst_b) begin
        ld_dc_addr0[31:0] <= {32{1'b0}};
    end
    // 注意：原代码 ld_ag_inst_vld 端口不存在，原设计意图应为 ld_ag_dc_inst_vld，请确认
    else if(ld_ag_dc_inst_vld || dcache_arb_ld_dc_borrow_vld) begin
        ld_dc_addr0[31:0] <= ld_ag_dc_addr0[31:0];
    end
end

//==========================================================
//          Generate  va
//==========================================================
//==========================================================
//               Generate check signal to lq/sq/wmb
//==========================================================
assign ld_dc_chk_ld_inst_vld    = ld_dc_inst_vld;
assign ld_dc_chk_ld_addr1_vld   = ld_dc_inst_vld && ld_dc_acclr_en;

//==========================================================
//                   RAW speculation check
//==========================================================
assign ld_dc_inst_chk_vld       = ld_dc_inst_vld;

assign ld_dc_chk_ld_bypass_vld    = ld_dc_chk_ld_inst_vld
                                    &&  ld_dc_fwd_bypass_en;
//-----------addr compare---------------
//addr0 compare
assign ld_dc_cmp_st_dc_addr0[31:0] = st_dc_addr0[31:0];
assign ld_dc_raw_addr_tto4_hit     = (ld_dc_addr0[31:4] == ld_dc_cmp_st_dc_addr0[31:4]);
// for cache buffer
assign ld_dc_raw_addr1_tto4_hit    = (ld_dc_addr1_to4[27:0] == ld_dc_cmp_st_dc_addr0[31:4]);

//-----------bytes_vld compare----------
assign ld_dc_raw_do_hit     = |(ld_dc_bytes_vld[15:0] & st_dc_bytes_vld[15:0]);

//------------------situation 2-----------------------------
assign ld_dc_depd_st_dc2    = ld_dc_inst_chk_vld
                            && ld_dc_raw_new
                            && st_dc_chk_st_inst_vld
                            && ld_dc_raw_addr_tto4_hit
                            && ld_dc_raw_do_hit;

//------------------situation 3-----------------------------
// when ld addr hit st, then do not get data from merge buffer
assign ld_dc_depd_st_dc3    = ld_dc_inst_chk_vld
                            && ld_dc_raw_new
                            && st_dc_chk_st_inst_vld
                            && ld_dc_raw_addr1_tto4_hit;

//------------------combine---------------------------------
assign ld_dc_depd_st_dc     = ld_dc_depd_st_dc2;

//==========================================================
//                   Create load queue
//==========================================================
assign ld_dc_lq_create_vld      = ld_dc_inst_vld
                                && !ld_dc_old
                                && !lq_ld_dc_inst_hit
                                && !ld_dc_depd_imme_restart_req
                                && !sq_ld_dc_addr1_dep_discard;

assign ld_dc_lq_create1_vld     = ld_dc_inst_vld
                                && !ld_dc_old
                                && !lq_ld_dc_inst_hit
                                && !ld_dc_depd_imme_restart_req
                                && cb_ld_dc_addr_hit
                                && !sq_ld_dc_addr1_dep_discard;

//==========================================================
//                   Restart signal
//==========================================================
assign ld_dc_lq_full_req      = ld_dc_lq_create_vld && lq_ld_dc_full
                                || ld_dc_lq_create1_vld && lq_ld_dc_less2;

assign ld_dc_depd_imme_restart_req = ld_dc_depd_st_dc;
assign ld_dc_restart_vld        = ld_dc_lq_full_req || ld_dc_depd_imme_restart_req;

//==========================================================
//                   Dependency check
//==========================================================
// dependency check is done in sq/wmb entry file
//------------------arbitrate-------------------------------
//-----------forward arbitrate----------
//bypass: pass data from ex1
//fwd: pass data from sq/wmb
//if ld_dc_fwd_sq_bypass_vld=1, and ld_dc_fwd_sq_vld=1,
//then see as multi depd in da
assign ld_dc_fwd_sq_vld         = sq_ld_dc_fwd_req;
// &Force("output","ld_dc_fwd_wmb_vld"); @669
assign ld_dc_fwd_wmb_vld        = !sq_ld_dc_fwd_req && wmb_ld_dc_fwd_req;

// &CombBeg; @673
always @( wmb_ld_dc_fwd_req
        or wmb_fwd_bytes_vld[15:0]
        or sq_ld_dc_fwd_req) begin
    case({sq_ld_dc_fwd_req,wmb_ld_dc_fwd_req})
        2'b11: ld_dc_fwd_bytes_vld[15:0] = 16'hffff;
        2'b10: ld_dc_fwd_bytes_vld[15:0] = 16'hffff;
        2'b01: ld_dc_fwd_bytes_vld[15:0]  = wmb_fwd_bytes_vld[15:0];
        2'b00: ld_dc_fwd_bytes_vld[15:0]  = 16'h0;
        default: ld_dc_fwd_bytes_vld[15:0] = {16{1'bx}};
    endcase
end
// &CombEnd; @681

//==========================================================
//            Generage to DA stage signal
//==========================================================
assign ld_dc_da_inst_vld        = ld_dc_inst_vld && !ld_dc_restart_vld;

//------------------dcache tag pre_compare----------------
assign ld_dc_dcache_tag_array[45:0] = dcache_lsu_ld_tag_dout[45:0];
assign ld_dc_way0_tag_hit     = (ld_dc_addr0[31:10] == ld_dc_dcache_tag_array[21:0]);
assign ld_dc_way1_tag_hit     = (ld_dc_addr0[31:10] == ld_dc_dcache_tag_array[44:23]);
assign ld_dc_dcache_valid0    = ld_dc_dcache_tag_array[22];
// &Force("output","ld_dc_hit_way0"); @922
assign ld_dc_dcache_valid1    = ld_dc_dcache_tag_array[45];
assign ld_dc_hit_way0         = ld_dc_dcache_valid0 && ld_dc_way0_tag_hit;
assign ld_dc_hit_way1         = ld_dc_dcache_valid1 && ld_dc_way1_tag_hit;
// &Force("output","ld_dc_dcache_hit"); @937
assign ld_dc_dcache_hit       = ld_dc_hit_way0 || ld_dc_hit_way1;
assign ld_dc_hit_low_region   = ld_dc_addr0[4] ? ld_dc_hit_way1 : ld_dc_hit_way0;
assign ld_dc_hit_high_region  = ld_dc_addr0[4] ? ld_dc_hit_way0 : ld_dc_hit_way1;

//------------------data pre_select----------------
assign ld_dc_rot_sel_final[3:0] = ld_dc_addr0[3:0];

// &CombBeg;   @969
// &CombEnd; @989
// &CombBeg;   @991
always @( ld_dc_rot_sel_final[2:0]) begin
    casez(ld_dc_rot_sel_final[2:0])
        3'h0: ld_dc_da_data_rot_sel[7:0] = 8'b00000001;
        3'h1: ld_dc_da_data_rot_sel[7:0] = 8'b00000010;
        3'h2: ld_dc_da_data_rot_sel[7:0] = 8'b00000100;
        3'h3: ld_dc_da_data_rot_sel[7:0] = 8'b00001000;
        3'h4: ld_dc_da_data_rot_sel[7:0] = 8'b00010000;
        3'h5: ld_dc_da_data_rot_sel[7:0] = 8'b00100000;
        3'h6: ld_dc_da_data_rot_sel[7:0] = 8'b01000000;
        3'h7: ld_dc_da_data_rot_sel[7:0] = 8'b10000000;
        default: ld_dc_da_data_rot_sel[7:0] = {8{1'bx}};
    endcase
end
// &CombEnd; @1003

//----------sign_sel--------------------
//3: word sign extend
//2: half sign extend
//1: byte sign extend
//0: not extend
// &CombBeg; @1011
always @( ld_dc_sign_extend
        or ld_dc_inst_size[1:0]) begin
    case({ld_dc_sign_extend,ld_dc_inst_size[1:0]})
        {1'b1,BYTE}:  ld_dc_preg_sign_sel[3:0] = 4'b0010;
        {1'b1,HALF}:  ld_dc_preg_sign_sel[3:0] = 4'b0100;
        {1'b1,WORD}:  ld_dc_preg_sign_sel[3:0] = 4'b1000;
        default:      ld_dc_preg_sign_sel[3:0] = 4'b0001;
    endcase
end
// &CombEnd; @1018

//==========================================================
//            Generage to cache buffer signal
//==========================================================
//------------------addr prepare----------------
assign ld_dc_cb_addr_tto4[27:0] = ld_dc_addr0[31:4];
assign cb_create_hit_idx   = (ld_dc_addr0[INDEX_MSB:INDEX_LSB] == dcache_idx[INDEX_WIDTH-1:0]);
// &Force("output","ld_dc_cb_addr_create_vld"); @1131
assign ld_dc_cb_addr_create_vld = ld_dc_inst_vld
                                && ld_dc_acclr_en
                                && !ld_dc_restart_vld
                                && cb_create_hit_idx
                                && !rtu_yy_xx_flush;

assign ld_dc_da_cb_merge_en     = ld_dc_acclr_en
                                && cb_ld_dc_addr_hit
                                && !ld_dc_depd_st_dc3
                                && !sq_ld_dc_cancel_acc_req
                                && !wmb_ld_dc_cancel_acc_req
                                && !lq_ld_dc_inst_hit;

//==========================================================
//      Generage lsiq signal (renamed in lsu_restart.vp)
//==========================================================
assign ld_dc_mask_lsid[LSIQ_ENTRY-1:0]    = {LSIQ_ENTRY{ld_dc_inst_vld}} & ld_dc_lsid[LSIQ_ENTRY-1:0];
assign ld_dc_idu_lq_full[LSIQ_ENTRY-1:0]  = {LSIQ_ENTRY{ld_dc_lq_full_req}} & ld_dc_mask_lsid[LSIQ_ENTRY-1:0];
assign ld_dc_imme_wakeup[LSIQ_ENTRY-1:0]  = {LSIQ_ENTRY{ld_dc_depd_imme_restart_req}} & ld_dc_mask_lsid[LSIQ_ENTRY-1:0];

endmodule
