module ct_idu_ir_rt (
  // 2026-10-08 补: 原来这个模块**没有时钟端口** —— C910 工厂版靠门控时钟单元
  // 在内部派生 dep_clk/write_clk, 交付时那批单元被剥掉 ⇒ 32 个改名表项
  // 全都挂在无驱动的时钟上（一个字都写不进去）。现在把时钟从顶层引进来,
  // 由 ct_idu_dep_reg_src2_entry 内部直连 forever_cpuclk。
  input  logic         forever_cpuclk,
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
logic         rt_reset_updt_vld;   // 2026-10-08 补: 复位映射的写窗口 (见下方注释)

// 数组声明
// ⚠️ 2026-10-08 修: 这两个数组原来声明成 **7 位**, 而表项的端口是
//     `x_read_data[12:0]` / `x_create_data[10:0]` (C910 的打包格式):
//        x_read_data   = {bypass[11], issue_rdy[10], mla_rdy[9], preg[8:2], wb[1], rdy[0]}
//        x_create_data = {                 preg[8:2], wb[1], rdy[0]}
//     7 位连 13/11 位 ⇒ 读侧**被截断**、写侧**被错位**, 于是表项存进去和读出来都不是
//     那个 preg。实测指纹: 给号 33 → 存进表项变成 8 → 读回来变成 16 (每一步都错位 2 位)。
//     ⇒ 这里按 C910 的真实宽度声明, 再派生一个 7 位的"wrapper 视图"给下面那 9 个
//        32 路 case 读口用 (视图 = {preg[5:0], wb}, 与原来那套 `[6:1]`/`[0]` 的取法一致),
//        这样几百行 case 一行都不用改。
logic [12:0]  reg_read_data_raw [0:31];   // 表项 x_read_data 原样
logic [10:0]  reg_create_data    [0:31];  // 表项 x_create_data 原样
logic [6:0]   reg_read_data      [0:31];  // wrapper 视图: {preg[5:0], wb}
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
  // ⚠️ 从 1 起, 不是 0 —— 0 号 (x0) 的读数据由上面那根 assign 硬接成常量,
  //    没有实体表项。原来从 0 起 ⇒ 例化出来的 0 号表项与那根 assign 抢
  //    reg_read_data[0] 的驱动权, elaborate 直接报 ICSD (多驱动器)。
  //    C910 原版的例化编号也确实是 _reg_1 .. _reg_31。
  //    (reg_create_data[0] / reg_write_en_arr[0] 仍由下面的写口逻辑驱动, 不受影响。)
  for (j = 1; j < 32; j = j + 1) begin : gen_ct_idu_ir_rt_entry
    ct_idu_dep_reg_src2_entry x_ct_idu_ir_rt_entry_reg (
      .forever_cpuclk                    (forever_cpuclk                    ),
      .cpurst_b                          (cpurst_b                          ),
      .rtu_yy_xx_flush                  (rtu_yy_xx_flush                  ),
      .iu_idu_ex2_pipe0_wb_preg_vld_dupx (iu_idu_ex2_pipe0_wb_preg_vld_dupx ),
      .iu_idu_ex2_pipe0_wb_preg_dupx     (iu_idu_ex2_pipe0_wb_preg_dupx     ),
      .iu_idu_ex2_pipe1_wb_preg_vld_dupx (iu_idu_ex2_pipe1_wb_preg_vld_dupx ),
      .iu_idu_ex2_pipe1_wb_preg_dupx     (iu_idu_ex2_pipe1_wb_preg_dupx     ),
      .lsu_idu_wb_pipe3_wb_preg_dupx     (lsu_idu_wb_pipe3_wb_preg_dupx     ),
      .lsu_idu_wb_pipe3_wb_preg_vld_dupx (lsu_idu_wb_pipe3_wb_preg_vld_dupx ),
      .x_create_data                     (reg_create_data[j]                ),  // 11 位 (2026-10-08 修宽度)
      .x_write_en                        (reg_write_en_arr[j]               ),
      .x_read_data                       (reg_read_data_raw[j]              )  // 13 位 (2026-10-08 修宽度)
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

// ---------------------------------------------------------------------------
// 2026-10-08 补: **复位映射的写窗口**。
//
// 原来 `rt_reset_updt_preg` (上面那张 x_l → p_l 的表) **算出来了却零消费** ——
// 而表项的复位值是 `preg <= 7'b0` ⇒ 上电后 32 个表项全是 0 ⇒ **所有逻辑寄存器
// 都指向 p0**。这在整核里是必错的 (x1/x2/... 互相踩)，只是冒烟台接常量看不出来。
//
// 这里给复位开一个**单拍写窗口**: 复位期间举起, 释放后的第一个时钟沿落下。
// 于是释放后第一拍, 32 个表项各按自己的索引把 `rt_reset_updt_preg[6*jj+5:6*jj]`
// 写进去 (数据本来就是按项索引的, 所以**一拍就能全灌完**, 不用走 32 拍)。
//
// 那一拍表项的 `always @(posedge write_clk...)` 里 `if(!cpurst_b)` 已经不成立、
// `else if(x_write_en)` 成立 ⇒ 写生效 (write_clk 已在 2026-10-08 接到 forever_cpuclk)。
//
// ⚠️ 它在写使能里的优先级**高于 recover**: 见下面 create-data 生成里的三元选择与
//    `reg_write_en` 的或项 —— 复位窗口与冲刷同拍时以复位为准。
// ---------------------------------------------------------------------------
reg rt_reset_updt_vld_q;
always @(posedge forever_cpuclk or negedge cpurst_b) begin
  if (!cpurst_b) rt_reset_updt_vld_q <= 1'b1;   // 复位期间举着
  else           rt_reset_updt_vld_q <= 1'b0;   // 释放后第一拍落下
end
assign rt_reset_updt_vld = rt_reset_updt_vld_q;

assign reg_write_en[31:0] = {32{rt_recover_updt_vld | rt_reset_updt_vld}}
                          | reg_write0_en[31:0]
                          | reg_write1_en[31:0]
                          | reg_write2_en[31:0];

// ---------------------------------------------------------------------------
// 2026-10-08 补: 把上面这根 32 位写使能总线接到**逐表项的**写使能数组上。
//
// 原来这里缺一段: `reg_write_en_arr[0:31]` 只在上面的 generate 里被当
// `x_write_en` 连进 32 个表项 (:153), 而**全文件没有任何地方给它赋值** ⇒
// 每个表项的写使能都是悬空的 Z ⇒ `always @(posedge write_clk) ... else if(x_write_en)`
// 里 x_write_en 为 Z ⇒ 表项**一个字都写不进去**。
// 症状: 改名表恒等于复位值 (x_l → p_l), 参考数永远读到初始映射 ——
// 配合"表项时钟没接"那个坑, 这两处一起让整个重命名级形同虚设。
// 单元台 tb_idu_c910.sv 的定向判据 ("第 N 次派遣读到 old_preg == 前面写进去的号")
// 就是为它加的: 修之前那条判据红。
// ---------------------------------------------------------------------------
genvar jw;
generate
  for (jw = 0; jw < 32; jw = jw + 1) begin : gen_reg_write_en_arr
    assign reg_write_en_arr[jw] = reg_write_en[jw];
  end
endgenerate

// ---------------------------------------------------------------------------
// 表项读出的 7 位"wrapper 视图" (2026-10-08 新增)
//   视图 = {preg[5:0], wb}  —— 与下面 9 个 case 读口 (read_wb = [0],
//   read_preg = [6:1]) 以及 rt_dp_inst*_rel_preg 的取法完全一致, 所以那些点一行不用改。
//   来源: 表项输出的 [8:2]=preg[6:0] (我们只用低 6 位) / [1]=wb。
// ---------------------------------------------------------------------------
// ⚠️ 从 1 起 —— 与上面表项例化同一个理由: 0 号 (x0) 的读数据由
//    `assign reg_read_data[0][6:0] = 7'b0000001;` 硬接成常量, 从 0 起会 ICSD (多驱动器)。
genvar jv;
generate
  for (jv = 1; jv < 32; jv = jv + 1) begin : gen_reg_read_view
    assign reg_read_data[jv][6:0] = {reg_read_data_raw[jv][7:2], reg_read_data_raw[jv][1]};
  end
endgenerate

// reg_create_preg 生成
// ⚠️ 2026-10-08 修: 原来只写 `[5:0]` 且把 r_vld 塞在 bit[6] —— 那是 7 位口径的残留。
//    表项要的是 11 位 `{preg[8:2], wb[1], rdy[0]}`:
//      * 指令改名写进去的新映射: 生产者还没写回 ⇒ wb=0, rdy=0;
//      * recover 写进去的是**架构映射**: 值就在 PRF 里、没有在途生产者 ⇒ wb=1, rdy=1。
//    (原来那个 bit[6]=r_vld 的写法在正确打包下会落进 preg 字段里, 属于同一个错位 bug。)
genvar jj;
generate
  for(jj=0; jj<32; jj=jj+1) begin : gen_reg_create_preg
    always @(*)
    begin
      if(reg_write2_en[jj]) begin
        reg_create_data[jj][8:2] = {1'b0, dp_rt_inst2_dst_preg[5:0]};
        reg_create_data[jj][1]   = 1'b0;
        reg_create_data[jj][0]   = 1'b0;
      end
      else if(reg_write1_en[jj]) begin
        reg_create_data[jj][8:2] = {1'b0, dp_rt_inst1_dst_preg[5:0]};
        reg_create_data[jj][1]   = 1'b0;
        reg_create_data[jj][0]   = 1'b0;
      end
      else if(reg_write0_en[jj]) begin
        reg_create_data[jj][8:2] = {1'b0, dp_rt_inst0_dst_preg[5:0]};
        reg_create_data[jj][1]   = 1'b0;
        reg_create_data[jj][0]   = 1'b0;
      end
      else begin
        // 复位窗口优先于 recover(冲刷): 两者同拍时灌复位映射
        reg_create_data[jj][8:2] = rt_reset_updt_vld
                                 ? {1'b0, rt_reset_updt_preg[6*jj+5 : 6*jj]}
                                 : {1'b0, rt_recover_updt_preg[6*jj+5 : 6*jj]};
        reg_create_data[jj][1]   = 1'b1;   // 架构映射: 值已在 PRF
        reg_create_data[jj][0]   = 1'b1;   // rdy
      end
    end
  end
endgenerate

assign r_vld = rt_recover_updt_vld;

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

