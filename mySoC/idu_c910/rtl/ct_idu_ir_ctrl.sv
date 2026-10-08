module ct_idu_ir_ctrl (
  // 2026-10-08 补: 原来这个模块**没有时钟端口** —— C910 工厂版靠门控时钟单元在内部
  // 派生 ir_inst_clk, 交付时那批单元被剥掉 ⇒ IR 级的流水线寄存器
  // (ir_inst0/1/2_vld) 挂在无驱动的时钟上, 永不翻转。
  input  logic         forever_cpuclk,
  input  logic         cpurst_b,
  input  logic         ctrl_id_pipedown_inst0_vld,
  input  logic         ctrl_id_pipedown_inst1_vld,
  input  logic         ctrl_id_pipedown_inst2_vld,
  input  logic         ctrl_is_inst2_vld,
  input  logic         ctrl_is_stall,
  input  logic [1:0]   ctrl_xx_is_inst0_sel,
  input  logic [6:0]   dp_ctrl_ir_inst0_ctrl_info,
  input  logic         dp_ctrl_ir_inst0_dst_vld,
  input  logic         dp_ctrl_ir_inst0_dst_x0,
  input  logic [6:0]   dp_ctrl_ir_inst1_ctrl_info,
  input  logic         dp_ctrl_ir_inst1_dst_vld,
  input  logic         dp_ctrl_ir_inst1_dst_x0,
  input  logic [6:0]   dp_ctrl_ir_inst2_ctrl_info,
  input  logic         dp_ctrl_ir_inst2_dst_vld,
  input  logic         dp_ctrl_ir_inst2_dst_x0,
  input  logic [6:0]   dp_ctrl_is_dis_inst2_ctrl_info,
  input  logic         rtu_idu_alloc_preg0_vld,
  input  logic         rtu_idu_alloc_preg1_vld,
  input  logic         rtu_idu_alloc_preg2_vld,
  // 原名 rtu_idu_flush_fe; 归一成 rtu_yy_xx_flush, 与 is_*_entry 一致
  // (本设计只有一个冲刷信号, 见 ct_idu_is_pipe_entry.sv 里的同款说明)
  input  logic         rtu_yy_xx_flush,
  output logic         ctrl_ir_pipedown,
  output logic         ctrl_ir_pipedown_inst0_vld,
  output logic         ctrl_ir_pipedown_inst1_vld,
  output logic         ctrl_ir_pipedown_inst2_vld,
  output logic         ctrl_ir_pre_dis_aiq_create0_en,
  output logic [1:0]   ctrl_ir_pre_dis_aiq_create0_sel,
  output logic         ctrl_ir_pre_dis_aiq_create1_en,
  output logic [1:0]   ctrl_ir_pre_dis_aiq_create1_sel,
  output logic         ctrl_ir_pre_dis_biq_create0_en,
  output logic [1:0]   ctrl_ir_pre_dis_biq_create0_sel,
  output logic         ctrl_ir_pre_dis_biq_create1_en,
  output logic [1:0]   ctrl_ir_pre_dis_biq_create1_sel,
  output logic         ctrl_ir_pre_dis_inst0_vld,
  output logic         ctrl_ir_pre_dis_inst1_vld,
  output logic         ctrl_ir_pre_dis_inst2_vld,
  output logic         ctrl_ir_pre_dis_lsiq_create0_en,
  output logic [1:0]   ctrl_ir_pre_dis_lsiq_create0_sel,
  output logic         ctrl_ir_pre_dis_lsiq_create1_en,
  output logic [1:0]   ctrl_ir_pre_dis_lsiq_create1_sel,
  // ⚠️ 2026-10-09 补: 下面这三根在模块**内部算了却没引出来** (只在 :140/:147/:162
  //    声明成内部 logic 并赋值), 于是顶层同名的那几根线**没有驱动** ⇒ 悬空 Z
  //    ⇒ SDIQ / MULT / DIV 三条队列的**第二 create 口整个是死的**
  //    (create1_en = Z ⇒ 队列把它当 X, 那一口永远建不进去)。
  //    症状是"这些队列的吞吐只有一半", 而功能测试基本看不出来 (还有 create0 在跑)。
  //    这一类的检验: VCS 的 `Warning-[IWNF] Implicit wire has no fanin` ——
  //    1 位信号不会被截断, 所以"未声明且多位"那个扫描器**抓不到它**。
  output logic         ctrl_ir_pre_dis_sdiq_create1_en,
  output logic         ctrl_ir_pre_dis_mult_create1_en,
  output logic         ctrl_ir_pre_dis_div_create1_en,
  output logic         ctrl_ir_pre_dis_pipedown2,
  output logic         ctrl_ir_pre_dis_sdiq_create0_en,
  output logic [1:0]   ctrl_ir_pre_dis_sdiq_create0_sel,
  output logic [1:0]   ctrl_ir_pre_dis_sdiq_create1_sel,
  output logic         ctrl_ir_stage_stall,
  output logic         ctrl_ir_stall,
  output logic         ctrl_rt_inst0_vld,
  output logic         ctrl_rt_inst1_vld,
  output logic         ctrl_rt_inst2_vld,
  output logic         idu_rtu_ir_preg0_alloc_vld,
  output logic         idu_rtu_ir_preg1_alloc_vld,
  output logic         idu_rtu_ir_preg2_alloc_vld
);

// &Regs; @29
logic             ir_inst0_vld;
logic             ir_inst1_vld;
logic             ir_inst2_vld;

// &Wires; @30
logic             ctrl_ir_inst0_biq;
logic             ctrl_ir_inst0_biq_vld;
logic             ctrl_ir_inst0_lsiq;
logic             ctrl_ir_inst0_lsiq_vld;
logic             ctrl_ir_inst0_sdiq;
logic             ctrl_ir_inst1_biq;
logic             ctrl_ir_inst1_biq_vld;
logic             ctrl_ir_inst1_lsiq;
logic             ctrl_ir_inst1_lsiq_vld;
logic             ctrl_ir_inst1_sdiq;
logic             ctrl_ir_inst2_biq;
logic             ctrl_ir_inst2_biq_vld;
logic             ctrl_ir_inst2_lsiq;
logic             ctrl_ir_inst2_lsiq_vld;
logic             ctrl_ir_inst2_sdiq;
logic             ctrl_ir_inst3_biq;
logic             ctrl_ir_inst3_lsiq;
logic             ctrl_ir_inst3_sdiq;
logic             ctrl_ir_pipedown_stall;
logic             ctrl_ir_pre_dis_3_biq_inst;
logic             ctrl_ir_pre_dis_3_lsiq_inst;
logic             ctrl_ir_pre_dis_aiq_create0_sel_inst0;
logic             ctrl_ir_pre_dis_aiq_create0_sel_inst1;
logic             ctrl_ir_pre_dis_aiq_create1_sel_inst1;
logic             ctrl_ir_pre_dis_biq_create1_sel_inst1;
logic             ctrl_ir_pre_dis_inst0_biq;
logic             ctrl_ir_pre_dis_inst0_lsiq;
logic             ctrl_ir_pre_dis_inst0_sdiq;
logic             ctrl_ir_pre_dis_inst1_biq;
logic             ctrl_ir_pre_dis_inst1_lsiq;
logic             ctrl_ir_pre_dis_inst1_sdiq;
logic             ctrl_ir_pre_dis_inst2_biq;
logic             ctrl_ir_pre_dis_inst2_lsiq;
logic             ctrl_ir_pre_dis_inst2_sdiq;
logic             ctrl_ir_pre_dis_lsiq_create1_sel_inst1;
logic             ctrl_ir_pre_dis_sdiq_create1_sel_inst1;
logic             ctrl_ir_pre_dis_type_stall_pipedown2;
logic             ctrl_ir_preg_stall;
logic             ir_inst_clk;
logic [12:0]      ir_pipedown_inst0_ctrl_info;
logic             ir_pipedown_inst0_vld;
logic [12:0]      ir_pipedown_inst1_ctrl_info;
logic             ir_pipedown_inst1_vld;
logic [12:0]      ir_pipedown_inst2_ctrl_info;
logic             ir_pipedown_inst2_vld;
logic [12:0]      ir_pipedown_inst3_ctrl_info;

// 新增缺失的内部信号声明
logic             ctrl_ir_inst0_aiq;
logic             ctrl_ir_inst1_aiq;
logic             ctrl_ir_inst2_aiq;
logic             ctrl_ir_inst0_mult;
logic             ctrl_ir_inst1_mult;
logic             ctrl_ir_inst2_mult;
logic             ctrl_ir_inst0_div;
logic             ctrl_ir_inst1_div;
logic             ctrl_ir_inst2_div;
logic             ctrl_ir_inst0_aiq_vld;
logic             ctrl_ir_inst1_aiq_vld;
logic             ctrl_ir_inst2_aiq_vld;
logic             ctrl_ir_pre_dis_3_aiq_inst;
logic             ctrl_ir_pre_dis_3_mult_inst;
logic             ctrl_ir_pre_dis_3_div_inst;
logic             ctrl_ir_pre_dis_al_1_aiq_inst;
logic             ctrl_ir_pre_dis_al_2_aiq_inst;
logic             ctrl_ir_pre_dis_al_1_mult_inst;
logic             ctrl_ir_pre_dis_al_2_mult_inst;
logic             ctrl_ir_pre_dis_al_1_div_inst;
logic             ctrl_ir_pre_dis_al_2_div_inst;

logic [1:0]       ctrl_ir_pre_dis_aiq0_create1_sel;
logic             ctrl_ir_pre_dis_mult_create0_en;
logic [1:0]       ctrl_ir_pre_dis_mult_create0_sel;
logic [1:0]       ctrl_ir_pre_dis_mult_create1_sel;
logic             ctrl_ir_pre_dis_mult_create0_sel_inst0;
logic             ctrl_ir_pre_dis_mult_create0_sel_inst1;
logic             ctrl_ir_pre_dis_mult_create1_sel_inst1;
logic             ctrl_ir_pre_dis_div_create0_en;
logic [1:0]       ctrl_ir_pre_dis_div_create0_sel;
logic [1:0]       ctrl_ir_pre_dis_div_create1_sel;
logic             ctrl_ir_pre_dis_div_create0_sel_inst0;
logic             ctrl_ir_pre_dis_div_create0_sel_inst1;
logic             ctrl_ir_pre_dis_div_create1_sel_inst1;
logic             ctrl_ir_pre_dis_inst0_aiq;
logic             ctrl_ir_pre_dis_inst1_aiq;
logic             ctrl_ir_pre_dis_inst2_aiq;
logic             ctrl_ir_pre_dis_inst0_mult;
logic             ctrl_ir_pre_dis_inst1_mult;
logic             ctrl_ir_pre_dis_inst2_mult;
logic             ctrl_ir_pre_dis_inst0_div;
logic             ctrl_ir_pre_dis_inst1_div;
logic             ctrl_ir_pre_dis_inst2_div;
//==========================================================
//                       Parameters
//==========================================================
//----------------------------------------------------------
//                 IS ctrl path parameters
//----------------------------------------------------------
parameter IS_CTRL_WIDTH       = 7;
parameter IS_CTRL_ILLEGAL     = 6;
parameter IS_CTRL_ALU         = 5;
parameter IS_CTRL_STADDR      = 4;
parameter IS_CTRL_LSU         = 3;
parameter IS_CTRL_BJU         = 2;
parameter IS_CTRL_DIV         = 1;
parameter IS_CTRL_MULT        = 0;

//==========================================================
//                 IR pipeline registers
//==========================================================
// 本地时钟驱动（2026-10-08 补）: 见模块头的说明。
// IR 级寄存器的 always 块内部自带使能条件（!cpurst_b / rtu_yy_xx_flush /
// !ctrl_ir_stall / else 保持），所以直接接 forever_cpuclk 功能等价，
// 只是少了时钟门控的省电效果。
assign ir_inst_clk = forever_cpuclk;

//----------------------------------------------------------
//               Pipeline register implement
//----------------------------------------------------------
always @(posedge ir_inst_clk or negedge cpurst_b)
begin
  if(!cpurst_b) begin
    ir_inst0_vld <= 1'b0;
    ir_inst1_vld <= 1'b0;
    ir_inst2_vld <= 1'b0;
  end
  else if(rtu_yy_xx_flush) begin
    ir_inst0_vld <= 1'b0;
    ir_inst1_vld <= 1'b0;
    ir_inst2_vld <= 1'b0;
  end
  else if(!ctrl_ir_stall) begin
    ir_inst0_vld <= ctrl_id_pipedown_inst0_vld;
    ir_inst1_vld <= ctrl_id_pipedown_inst1_vld;
    ir_inst2_vld <= ctrl_id_pipedown_inst2_vld;
  end
  else begin
    ir_inst0_vld <= ir_inst0_vld;
    ir_inst1_vld <= ir_inst1_vld;
    ir_inst2_vld <= ir_inst2_vld;
  end
end

//----------------------------------------------------------
//             IR pipedown inst valid signals
//----------------------------------------------------------
//assign ctrl_ir_pipedown_stall = ctrl_ir_stage_stall || ctrl_is_dis_type_stall;
assign ctrl_ir_pipedown_stall = ctrl_ir_stage_stall;

assign ir_pipedown_inst0_vld =
            ctrl_xx_is_inst0_sel[0] && ctrl_is_inst2_vld
         || ctrl_xx_is_inst0_sel[1] && ir_inst0_vld && !ctrl_ir_pipedown_stall;

assign ir_pipedown_inst1_vld =
            ctrl_xx_is_inst0_sel[0] && ir_inst0_vld && !ctrl_ir_pipedown_stall
         || ctrl_xx_is_inst0_sel[1] && ir_inst1_vld && !ctrl_ir_pipedown_stall;
assign ir_pipedown_inst2_vld =
            ctrl_xx_is_inst0_sel[0] && ir_inst1_vld && !ctrl_ir_pipedown_stall
         || ctrl_xx_is_inst0_sel[1] && ir_inst2_vld && !ctrl_ir_pipedown_stall;

//----------------------------------------------------------
//            Rename Table inst valid signals
//----------------------------------------------------------
assign ctrl_rt_inst0_vld = ir_inst0_vld;
assign ctrl_rt_inst1_vld = ir_inst1_vld;
assign ctrl_rt_inst2_vld = ir_inst2_vld;

//----------------------------------------------------------
//            Rename pipedown inst valid signals
//----------------------------------------------------------
assign ctrl_ir_pipedown_inst0_vld = ir_pipedown_inst0_vld;
assign ctrl_ir_pipedown_inst1_vld = ir_pipedown_inst1_vld;
assign ctrl_ir_pipedown_inst2_vld = ir_pipedown_inst2_vld;

//==========================================================
//                IR stage pipedown signals
//==========================================================
assign ctrl_ir_pipedown         = (ir_pipedown_inst0_vld
                                || ir_pipedown_inst1_vld
                                || ir_pipedown_inst2_vld);

//==========================================================
//                  IR stage stall signals
//==========================================================
assign ctrl_ir_preg_stall =
     ir_inst0_vld && dp_ctrl_ir_inst0_dst_vld && !rtu_idu_alloc_preg0_vld
  || ir_inst1_vld && dp_ctrl_ir_inst1_dst_vld && !rtu_idu_alloc_preg1_vld
  || ir_inst2_vld && dp_ctrl_ir_inst2_dst_vld && !rtu_idu_alloc_preg2_vld;


assign ctrl_ir_stage_stall  = ctrl_ir_preg_stall;

assign ctrl_ir_stall = ir_inst0_vld && (ctrl_is_stall || ctrl_ir_stage_stall);

//==========================================================
//  Allocate signal for Ptag pool / PST preg / LSU pcfifo
//==========================================================
assign idu_rtu_ir_preg0_alloc_vld = ir_inst0_vld
                                    && !ctrl_ir_stall
                                    && dp_ctrl_ir_inst0_dst_vld
                                    && !dp_ctrl_ir_inst0_dst_x0;
assign idu_rtu_ir_preg1_alloc_vld = ir_inst1_vld
                                    && !ctrl_ir_stall
                                    && dp_ctrl_ir_inst1_dst_vld
                                    && !dp_ctrl_ir_inst1_dst_x0;
assign idu_rtu_ir_preg2_alloc_vld = ir_inst2_vld
                                    && !ctrl_ir_stall
                                    && dp_ctrl_ir_inst2_dst_vld
                                    && !dp_ctrl_ir_inst2_dst_x0;


//==========================================================
//                 Prepare Dispatch Signals
//==========================================================
//----------------------------------------------------------
//            MUX between IR inst and IS shift inst
//----------------------------------------------------------
assign ir_pipedown_inst0_ctrl_info[IS_CTRL_WIDTH-1:0] = 
    {IS_CTRL_WIDTH{ctrl_xx_is_inst0_sel[0]}} & dp_ctrl_is_dis_inst2_ctrl_info[IS_CTRL_WIDTH-1:0]
  | {IS_CTRL_WIDTH{ctrl_xx_is_inst0_sel[1]}} & dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_WIDTH-1:0];
assign ir_pipedown_inst1_ctrl_info[IS_CTRL_WIDTH-1:0] = 
    {IS_CTRL_WIDTH{ctrl_xx_is_inst0_sel[0]}} & dp_ctrl_ir_inst0_ctrl_info[IS_CTRL_WIDTH-1:0]
  | {IS_CTRL_WIDTH{ctrl_xx_is_inst0_sel[1]}} & dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_WIDTH-1:0];
assign ir_pipedown_inst2_ctrl_info[IS_CTRL_WIDTH-1:0] = 
    {IS_CTRL_WIDTH{ctrl_xx_is_inst0_sel[0]}} & dp_ctrl_ir_inst1_ctrl_info[IS_CTRL_WIDTH-1:0]
  | {IS_CTRL_WIDTH{ctrl_xx_is_inst0_sel[1]}} & dp_ctrl_ir_inst2_ctrl_info[IS_CTRL_WIDTH-1:0];

//rename for pre dispatch
assign ctrl_ir_inst0_aiq          = ir_pipedown_inst0_ctrl_info[IS_CTRL_ALU] | ir_pipedown_inst0_ctrl_info[IS_CTRL_ILLEGAL];
assign ctrl_ir_inst1_aiq          = ir_pipedown_inst1_ctrl_info[IS_CTRL_ALU] | ir_pipedown_inst1_ctrl_info[IS_CTRL_ILLEGAL];;
assign ctrl_ir_inst2_aiq          = ir_pipedown_inst2_ctrl_info[IS_CTRL_ALU] | ir_pipedown_inst2_ctrl_info[IS_CTRL_ILLEGAL];;

assign ctrl_ir_inst0_mult  = ir_pipedown_inst0_ctrl_info[IS_CTRL_MULT];
assign ctrl_ir_inst1_mult  = ir_pipedown_inst1_ctrl_info[IS_CTRL_MULT];
assign ctrl_ir_inst2_mult  = ir_pipedown_inst2_ctrl_info[IS_CTRL_MULT];

assign ctrl_ir_inst0_div  = ir_pipedown_inst0_ctrl_info[IS_CTRL_DIV];
assign ctrl_ir_inst1_div  = ir_pipedown_inst1_ctrl_info[IS_CTRL_DIV];
assign ctrl_ir_inst2_div  = ir_pipedown_inst2_ctrl_info[IS_CTRL_DIV];

assign ctrl_ir_inst0_biq           = ir_pipedown_inst0_ctrl_info[IS_CTRL_BJU];
assign ctrl_ir_inst1_biq           = ir_pipedown_inst1_ctrl_info[IS_CTRL_BJU];
assign ctrl_ir_inst2_biq           = ir_pipedown_inst2_ctrl_info[IS_CTRL_BJU];

assign ctrl_ir_inst0_lsiq          = ir_pipedown_inst0_ctrl_info[IS_CTRL_LSU];
assign ctrl_ir_inst1_lsiq          = ir_pipedown_inst1_ctrl_info[IS_CTRL_LSU];
assign ctrl_ir_inst2_lsiq          = ir_pipedown_inst2_ctrl_info[IS_CTRL_LSU];

assign ctrl_ir_inst0_sdiq          = ir_pipedown_inst0_ctrl_info[IS_CTRL_STADDR];
assign ctrl_ir_inst1_sdiq          = ir_pipedown_inst1_ctrl_info[IS_CTRL_STADDR];
assign ctrl_ir_inst2_sdiq          = ir_pipedown_inst2_ctrl_info[IS_CTRL_STADDR];

//----------------------------------------------------------
//                  prepare IS inst valid
//----------------------------------------------------------
assign ctrl_ir_pre_dis_inst0_vld = ir_pipedown_inst0_vld;
assign ctrl_ir_pre_dis_inst1_vld = ir_pipedown_inst1_vld;
assign ctrl_ir_pre_dis_inst2_vld = ir_pipedown_inst2_vld
                                   && !ctrl_ir_pre_dis_type_stall_pipedown2;

//----------------------------------------------------------
//             prepare IS dispatch type stall
//----------------------------------------------------------
assign ctrl_ir_inst0_aiq_vld = ir_pipedown_inst0_vld && ctrl_ir_inst0_aiq;
assign ctrl_ir_inst1_aiq_vld = ir_pipedown_inst1_vld && ctrl_ir_inst1_aiq;
assign ctrl_ir_inst2_aiq_vld = ir_pipedown_inst2_vld && ctrl_ir_inst2_aiq;

assign ctrl_ir_inst0_biq_vld = ir_pipedown_inst0_vld && ctrl_ir_inst0_biq;
assign ctrl_ir_inst1_biq_vld = ir_pipedown_inst1_vld && ctrl_ir_inst1_biq;
assign ctrl_ir_inst2_biq_vld = ir_pipedown_inst2_vld && ctrl_ir_inst2_biq;

assign ctrl_ir_inst0_lsiq_vld = ir_pipedown_inst0_vld && ctrl_ir_inst0_lsiq;
assign ctrl_ir_inst1_lsiq_vld = ir_pipedown_inst1_vld && ctrl_ir_inst1_lsiq;
assign ctrl_ir_inst2_lsiq_vld = ir_pipedown_inst2_vld && ctrl_ir_inst2_lsiq;

assign ctrl_ir_pre_dis_3_biq_inst =
            ctrl_ir_inst0_biq_vld && ctrl_ir_inst1_biq_vld && ctrl_ir_inst2_biq_vld;
assign ctrl_ir_pre_dis_3_aiq_inst =
            ctrl_ir_inst0_aiq_vld && ctrl_ir_inst1_aiq_vld && ctrl_ir_inst2_aiq_vld;
assign ctrl_ir_pre_dis_3_mult_inst =
             ctrl_ir_inst0_mult && ctrl_ir_inst1_mult && ctrl_ir_inst2_mult;
assign ctrl_ir_pre_dis_3_div_inst =
             ctrl_ir_inst0_div && ctrl_ir_inst1_div && ctrl_ir_inst2_div;             
assign ctrl_ir_pre_dis_3_lsiq_inst =
            ctrl_ir_inst0_lsiq_vld && ctrl_ir_inst1_lsiq_vld && ctrl_ir_inst2_lsiq_vld;

assign ctrl_ir_pre_dis_type_stall_pipedown2 = ctrl_ir_pre_dis_3_biq_inst
                                           || ctrl_ir_pre_dis_3_aiq_inst
                                           || ctrl_ir_pre_dis_3_lsiq_inst
                                           || ctrl_ir_pre_dis_3_mult_inst
                                           || ctrl_ir_pre_dis_3_div_inst;

assign ctrl_ir_pre_dis_pipedown2  = ir_pipedown_inst2_vld
                                    && ctrl_ir_pre_dis_type_stall_pipedown2;

//----------------------------------------------------------
//           prepare dispatch IQ create signals
//----------------------------------------------------------
assign ctrl_ir_pre_dis_inst0_aiq       = ctrl_ir_pre_dis_inst0_vld
                                          && ctrl_ir_inst0_aiq;
assign ctrl_ir_pre_dis_inst1_aiq       = ctrl_ir_pre_dis_inst1_vld
                                          && ctrl_ir_inst1_aiq;
assign ctrl_ir_pre_dis_inst2_aiq       = ctrl_ir_pre_dis_inst2_vld
                                          && ctrl_ir_inst2_aiq;

assign ctrl_ir_pre_dis_inst0_mult       = ctrl_ir_pre_dis_inst0_vld
                                          && ctrl_ir_inst0_mult;
assign ctrl_ir_pre_dis_inst1_mult       = ctrl_ir_pre_dis_inst1_vld
                                          && ctrl_ir_inst1_mult;
assign ctrl_ir_pre_dis_inst2_mult       = ctrl_ir_pre_dis_inst2_vld
                                          && ctrl_ir_inst2_mult;

assign ctrl_ir_pre_dis_inst0_div       = ctrl_ir_pre_dis_inst0_vld
                                          && ctrl_ir_inst0_div;
assign ctrl_ir_pre_dis_inst1_div       = ctrl_ir_pre_dis_inst1_vld
                                          && ctrl_ir_inst1_div;
assign ctrl_ir_pre_dis_inst2_div       = ctrl_ir_pre_dis_inst2_vld
                                          && ctrl_ir_inst2_div;                                          

assign ctrl_ir_pre_dis_inst0_biq        = ctrl_ir_pre_dis_inst0_vld
                                          && ctrl_ir_inst0_biq;
assign ctrl_ir_pre_dis_inst1_biq        = ctrl_ir_pre_dis_inst1_vld
                                          && ctrl_ir_inst1_biq;
assign ctrl_ir_pre_dis_inst2_biq        = ctrl_ir_pre_dis_inst2_vld
                                          && ctrl_ir_inst2_biq;

assign ctrl_ir_pre_dis_inst0_lsiq       = ctrl_ir_pre_dis_inst0_vld
                                          && ctrl_ir_inst0_lsiq;
assign ctrl_ir_pre_dis_inst1_lsiq       = ctrl_ir_pre_dis_inst1_vld
                                          && ctrl_ir_inst1_lsiq;
assign ctrl_ir_pre_dis_inst2_lsiq       = ctrl_ir_pre_dis_inst2_vld
                                          && ctrl_ir_inst2_lsiq;

assign ctrl_ir_pre_dis_inst0_sdiq       = ctrl_ir_pre_dis_inst0_vld
                                          && ctrl_ir_inst0_sdiq;
assign ctrl_ir_pre_dis_inst1_sdiq       = ctrl_ir_pre_dis_inst1_vld
                                          && ctrl_ir_inst1_sdiq;
assign ctrl_ir_pre_dis_inst2_sdiq       = ctrl_ir_pre_dis_inst2_vld
                                          && ctrl_ir_inst2_sdiq;

//----------------------------------------------------------
//           AIQ0 and AIQ1 create enable prepare
//----------------------------------------------------------
assign ctrl_ir_pre_dis_al_1_aiq_inst = ctrl_ir_pre_dis_inst0_aiq
                                     || ctrl_ir_pre_dis_inst1_aiq
                                     || ctrl_ir_pre_dis_inst2_aiq;

assign ctrl_ir_pre_dis_al_2_aiq_inst = 
            ctrl_ir_pre_dis_inst0_aiq && ctrl_ir_pre_dis_inst1_aiq
         || ctrl_ir_pre_dis_inst0_aiq && ctrl_ir_pre_dis_inst2_aiq
         || ctrl_ir_pre_dis_inst1_aiq && ctrl_ir_pre_dis_inst2_aiq;

//----------------------------------------------------------
//               AIQ0 and AIQ1 create enable
//----------------------------------------------------------
assign ctrl_ir_pre_dis_aiq_create0_en = ctrl_ir_pre_dis_al_1_aiq_inst;
assign ctrl_ir_pre_dis_aiq_create1_en = ctrl_ir_pre_dis_al_2_aiq_inst;

//----------------------------------------------------------
//                  AIQ create 0 select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_aiq_create0_sel_inst0 =
              ctrl_ir_pre_dis_inst0_aiq;
assign ctrl_ir_pre_dis_aiq_create0_sel_inst1 =
              ctrl_ir_pre_dis_inst1_aiq & !ctrl_ir_pre_dis_inst0_aiq;

always @(*)
begin
  if(ctrl_ir_pre_dis_aiq_create0_sel_inst0)
    ctrl_ir_pre_dis_aiq_create0_sel[1:0] = 2'd0;
  else if(ctrl_ir_pre_dis_aiq_create0_sel_inst1)
    ctrl_ir_pre_dis_aiq_create0_sel[1:0] = 2'd1;
  else 
    ctrl_ir_pre_dis_aiq_create0_sel[1:0] = 2'd2;
end

//----------------------------------------------------------
//                  AIQ create 1 select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_aiq_create1_sel_inst1 = 
              ctrl_ir_pre_dis_inst1_aiq & ctrl_ir_pre_dis_inst0_aiq;

always @(*)
begin
  if(ctrl_ir_pre_dis_aiq_create1_sel_inst1)
    ctrl_ir_pre_dis_aiq_create1_sel[1:0] = 2'd1;
  else
    ctrl_ir_pre_dis_aiq_create1_sel[1:0] = 2'd2;
end

//----------------------------------------------------------
//          MULT create enable prepare
//----------------------------------------------------------
assign ctrl_ir_pre_dis_al_1_mult_inst = ctrl_ir_pre_dis_inst0_mult
                                     || ctrl_ir_pre_dis_inst1_mult
                                     || ctrl_ir_pre_dis_inst2_mult;

assign ctrl_ir_pre_dis_al_2_mult_inst = 
            ctrl_ir_pre_dis_inst0_mult && ctrl_ir_pre_dis_inst1_mult
         || ctrl_ir_pre_dis_inst0_mult && ctrl_ir_pre_dis_inst2_mult
         || ctrl_ir_pre_dis_inst1_mult && ctrl_ir_pre_dis_inst2_mult;

//----------------------------------------------------------
//               MULT create enable
//----------------------------------------------------------
assign ctrl_ir_pre_dis_mult_create0_en = ctrl_ir_pre_dis_al_1_mult_inst;
assign ctrl_ir_pre_dis_mult_create1_en = ctrl_ir_pre_dis_al_2_mult_inst;

//----------------------------------------------------------
//                  MULT create 0 select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_mult_create0_sel_inst0 =
              ctrl_ir_pre_dis_inst0_mult;
assign ctrl_ir_pre_dis_mult_create0_sel_inst1 =
              ctrl_ir_pre_dis_inst1_mult & !ctrl_ir_pre_dis_inst0_mult;

always @(*)
begin
  if(ctrl_ir_pre_dis_mult_create0_sel_inst0)
    ctrl_ir_pre_dis_mult_create0_sel[1:0] = 2'd0;
  else if(ctrl_ir_pre_dis_mult_create0_sel_inst1)
    ctrl_ir_pre_dis_mult_create0_sel[1:0] = 2'd1;
  else 
    ctrl_ir_pre_dis_mult_create0_sel[1:0] = 2'd2;
end

//----------------------------------------------------------
//                  MULT create 1 select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_mult_create1_sel_inst1 = 
              ctrl_ir_pre_dis_inst1_mult & ctrl_ir_pre_dis_inst0_mult;

always @(*)
begin
  if(ctrl_ir_pre_dis_mult_create1_sel_inst1)
    ctrl_ir_pre_dis_mult_create1_sel[1:0] = 2'd1;
  else
    ctrl_ir_pre_dis_mult_create1_sel[1:0] = 2'd2;
end

//----------------------------------------------------------
//           DIV create enable prepare
//----------------------------------------------------------
assign ctrl_ir_pre_dis_al_1_div_inst = ctrl_ir_pre_dis_inst0_div
                                     || ctrl_ir_pre_dis_inst1_div
                                     || ctrl_ir_pre_dis_inst2_div;

assign ctrl_ir_pre_dis_al_2_div_inst = 
            ctrl_ir_pre_dis_inst0_div && ctrl_ir_pre_dis_inst1_div
         || ctrl_ir_pre_dis_inst0_div && ctrl_ir_pre_dis_inst2_div
         || ctrl_ir_pre_dis_inst1_div && ctrl_ir_pre_dis_inst2_div;

//----------------------------------------------------------
//               DIV create enable
//----------------------------------------------------------
assign ctrl_ir_pre_dis_div_create0_en = ctrl_ir_pre_dis_al_1_div_inst;
assign ctrl_ir_pre_dis_div_create1_en = ctrl_ir_pre_dis_al_2_div_inst;

//----------------------------------------------------------
//                  DIV create 0 select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_div_create0_sel_inst0 =
              ctrl_ir_pre_dis_inst0_div;
assign ctrl_ir_pre_dis_div_create0_sel_inst1 =
              ctrl_ir_pre_dis_inst1_div & !ctrl_ir_pre_dis_inst0_div;

always @(*)
begin
  if(ctrl_ir_pre_dis_div_create0_sel_inst0)
    ctrl_ir_pre_dis_div_create0_sel[1:0] = 2'd0;
  else if(ctrl_ir_pre_dis_div_create0_sel_inst1)
    ctrl_ir_pre_dis_div_create0_sel[1:0] = 2'd1;
  else 
    ctrl_ir_pre_dis_div_create0_sel[1:0] = 2'd2;
end

//----------------------------------------------------------
//                  DIV create 1 select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_div_create1_sel_inst1 = 
              ctrl_ir_pre_dis_inst1_div & ctrl_ir_pre_dis_inst0_div;

always @(*)
begin
  if(ctrl_ir_pre_dis_div_create1_sel_inst1)
    ctrl_ir_pre_dis_div_create1_sel[1:0] = 2'd1;
  else
    ctrl_ir_pre_dis_div_create1_sel[1:0] = 2'd2;
end

//----------------------------------------------------------
//               BIQ create enable and Select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_biq_create0_en = ctrl_ir_pre_dis_inst0_biq
                                         || ctrl_ir_pre_dis_inst1_biq
                                         || ctrl_ir_pre_dis_inst2_biq;

always @(*)
begin
  if(ctrl_ir_pre_dis_inst0_biq)
    ctrl_ir_pre_dis_biq_create0_sel[1:0] = 2'd0;
  else if(ctrl_ir_pre_dis_inst1_biq)
    ctrl_ir_pre_dis_biq_create0_sel[1:0] = 2'd1;
  else
    ctrl_ir_pre_dis_biq_create0_sel[1:0] = 2'd2;
end

assign ctrl_ir_pre_dis_biq_create1_en =
            ctrl_ir_pre_dis_inst0_biq && ctrl_ir_pre_dis_inst1_biq
         || ctrl_ir_pre_dis_inst0_biq && ctrl_ir_pre_dis_inst2_biq
         || ctrl_ir_pre_dis_inst1_biq && ctrl_ir_pre_dis_inst2_biq;

assign ctrl_ir_pre_dis_biq_create1_sel_inst1 =
            ctrl_ir_pre_dis_inst0_biq && ctrl_ir_pre_dis_inst1_biq;

always @(*)
begin
  if(ctrl_ir_pre_dis_biq_create1_sel_inst1)
    ctrl_ir_pre_dis_biq_create1_sel[1:0] = 2'd1;
  else
    ctrl_ir_pre_dis_biq_create1_sel[1:0] = 2'd2;
end

//----------------------------------------------------------
//              LSIQ create enable and Select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_lsiq_create0_en = ctrl_ir_pre_dis_inst0_lsiq
                                         || ctrl_ir_pre_dis_inst1_lsiq
                                         || ctrl_ir_pre_dis_inst2_lsiq;

always @(*)
begin
  if(ctrl_ir_pre_dis_inst0_lsiq) begin
    ctrl_ir_pre_dis_lsiq_create0_sel[1:0] = 2'd0;
  end
  else if(ctrl_ir_pre_dis_inst1_lsiq) begin
    ctrl_ir_pre_dis_lsiq_create0_sel[1:0] = 2'd1;
  end
  else begin
    ctrl_ir_pre_dis_lsiq_create0_sel[1:0] = 2'd2;
  end
end

assign ctrl_ir_pre_dis_lsiq_create1_en =
            ctrl_ir_pre_dis_inst0_lsiq && ctrl_ir_pre_dis_inst1_lsiq
         || ctrl_ir_pre_dis_inst0_lsiq && ctrl_ir_pre_dis_inst2_lsiq
         || ctrl_ir_pre_dis_inst1_lsiq && ctrl_ir_pre_dis_inst2_lsiq;

assign ctrl_ir_pre_dis_lsiq_create1_sel_inst1 = 
               ctrl_ir_pre_dis_inst1_lsiq
            && ctrl_ir_pre_dis_inst0_lsiq;

always @(*)
begin
  if(ctrl_ir_pre_dis_lsiq_create1_sel_inst1) begin
    ctrl_ir_pre_dis_lsiq_create1_sel[1:0] = 2'd1;
  end
  else begin
    ctrl_ir_pre_dis_lsiq_create1_sel[1:0] = 2'd2;
  end
end

//----------------------------------------------------------
//              SDIQ create enable and Select
//----------------------------------------------------------
assign ctrl_ir_pre_dis_sdiq_create0_en = ctrl_ir_pre_dis_inst0_sdiq
                                         || ctrl_ir_pre_dis_inst1_sdiq
                                         || ctrl_ir_pre_dis_inst2_sdiq;

always @(*)
begin
  if(ctrl_ir_pre_dis_inst0_sdiq)
    ctrl_ir_pre_dis_sdiq_create0_sel[1:0] = 2'd0;
  else if(ctrl_ir_pre_dis_inst1_sdiq)
    ctrl_ir_pre_dis_sdiq_create0_sel[1:0] = 2'd1;
  else
    ctrl_ir_pre_dis_sdiq_create0_sel[1:0] = 2'd2;
end

assign ctrl_ir_pre_dis_sdiq_create1_en =
            ctrl_ir_pre_dis_inst0_sdiq && ctrl_ir_pre_dis_inst1_sdiq
         || ctrl_ir_pre_dis_inst0_sdiq && ctrl_ir_pre_dis_inst2_sdiq
         || ctrl_ir_pre_dis_inst1_sdiq && ctrl_ir_pre_dis_inst2_sdiq;

assign ctrl_ir_pre_dis_sdiq_create1_sel_inst1 = 
               ctrl_ir_pre_dis_inst1_sdiq
            && ctrl_ir_pre_dis_inst0_sdiq;

always @(*)
begin
  if(ctrl_ir_pre_dis_sdiq_create1_sel_inst1)
    ctrl_ir_pre_dis_sdiq_create1_sel[1:0] = 2'd1;
  else
    ctrl_ir_pre_dis_sdiq_create1_sel[1:0] = 2'd2;
end

// &ModuleEnd; @1732
endmodule