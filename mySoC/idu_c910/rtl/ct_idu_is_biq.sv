//=============================================================================
// ct_idu_is_biq —— 分支发射队列 (Issue Queue for Branch/Jump, 单发射口)
//
// 2026-10-16 参数化: 新增 BIQ_ENTRY (深度), 编译期可用 `+define+BIQ_ENTRY=N`
//   覆盖, 默认 8。
//
// 【为什么参数化】和 AIQ 同一刀砍下来的 —— C910 原版 BIQ 是 12 项 (注释里还留着
//   `biq_entry_create1_in[7:4]` / `create_sel[7:4]` 的痕迹), 本树只有 4 项。
//   2026-10-16 的参照测量把这件事钉死了:
//     整场 30 迭代 CoreMark 里, **C910 的 BIQ 满只占 0.0%** (它 12 项),
//     而我们 AIQ 加宽之后 **BIQ 满反而升到 17.0%, 成了最大单项**。
//   ⇒ 这是唯一一项我们比参照设计差一个数量级的地方。
//
// 【结构】与 ct_idu_is_aiq 逐行同源 (计数器 / 优先级编码 / agevec / pop /
//   older-ready / issue mux 完全一致), 所以直接套用 AIQ 那份参数化模板;
//   两处刻意改动与等价性论证见 ct_idu_is_aiq.sv 文件头 (agevec 改 N 位自屏蔽
//   约定; full/1_left 改写成"下一拍占用 R = cnt + create − pop"比较, 并保留
//   full 上的 `&& !issue`)。
//   另: `biq_entry_create_sel` 与原版一样是**死代码** (赋值了没有读者), 已删。
//=============================================================================
module ct_idu_is_biq (
  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic         biq_ctrl_1_left_updt,
  output logic         biq_ctrl_full_updt,
  output logic         biq_xx_issue_en,
  output logic [151:0] biq_dp_issue_read_data,

  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         cpurst_b,
  input  logic         ctrl_biq_create0_en,
  input  logic         ctrl_biq_create1_en,
  input  logic [151:0] dp_biq_create0_data,
  input  logic [151:0] dp_biq_create1_data,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe2_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe2_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush
);
parameter BIQ_WIDTH             = 152;
parameter BIQ_CHK               = 151;   // 2026-10-08 修: 原来漏了分号 ⇒ 本文件语法错 ⇒ 整个 IDU 编不过
parameter BIQ_PC                = 126;
parameter BIQ_IID               = 61;
parameter BIQ_DST_PREG          = 54;
parameter BIQ_SRC1_DATA         = 48;
parameter BIQ_SRC0_DATA         = 41;
parameter BIQ_DST_VLD           = 34;
parameter BIQ_SRC1_VLD          = 33;
parameter BIQ_SRC0_VLD          = 32;
parameter BIQ_OPCODE            = 31;

//----------------------------------------------------------------------------
// 队列深度: 编译期可用 `+define+BIQ_ENTRY=N` 覆盖, 默认 8 (C910 原版 12 项)。
//----------------------------------------------------------------------------
`ifdef BIQ_ENTRY
  parameter int BIQ_ENTRY = `BIQ_ENTRY;
`else
  parameter int BIQ_ENTRY = 8;
`endif

localparam int BIQ_CNT_W = $clog2(BIQ_ENTRY + 1);   // 计数位宽: 4→3, 8→4, 16→5

    //----------------------------------------------------------------------------
    // Internal signals
    //----------------------------------------------------------------------------
    logic [BIQ_CNT_W-1:0] biq_entry_cnt;
    logic [BIQ_CNT_W+1:0] biq_entry_cnt_next;      // 多两位: 下一拍占用 (cnt+2-pop 不溢出)
    logic [1:0]           biq_entry_cnt_create;
    logic                 biq_entry_cnt_updt_vld;

    logic [BIQ_ENTRY-1:0] biq_entry_vld;
    logic [BIQ_ENTRY-1:0] biq_entry_create0_in;
    logic [BIQ_ENTRY-1:0] biq_entry_create1_in;
    logic [BIQ_ENTRY-1:0] biq_entry_create_en;

    // 建表时"其他表项"的快照 (N 位, 含自己那一位, create 时按自屏蔽约定清零)
    logic [BIQ_ENTRY-1:0] biq_entry_create0_agevec;
    logic [BIQ_ENTRY-1:0] biq_entry_create1_agevec;

    logic [BIQ_ENTRY-1:0] biq_entry_ready;
    logic [BIQ_ENTRY-1:0] biq_older_entry_ready;
    logic [BIQ_ENTRY-1:0] biq_entry_issue_en;
    logic [BIQ_WIDTH-1:0] biq_entry_read_data [BIQ_ENTRY];
    logic [BIQ_WIDTH-1:0] biq_entry_read_data_sel;

//--------------------biq entry counter--------------------
//if create, add entry counter
assign biq_entry_cnt_create[1:0]   = {1'b0,ctrl_biq_create0_en}
                                      + {1'b0,ctrl_biq_create1_en};
//update valid and value (与原版一致: create1 必然伴随 create0, 故只判 create0)
assign biq_entry_cnt_updt_vld      = ctrl_biq_create0_en
                                      || biq_xx_issue_en;
// 下一拍占用: cnt + create - pop。判满/判"只剩一个坑"都用它比。
assign biq_entry_cnt_next[BIQ_CNT_W+1:0] = {2'b0,biq_entry_cnt}
                                      + {{BIQ_CNT_W{1'b0}},biq_entry_cnt_create}
                                      - {{(BIQ_CNT_W+1){1'b0}},biq_xx_issue_en};
//implement entry counter
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    biq_entry_cnt[BIQ_CNT_W-1:0] <= {BIQ_CNT_W{1'b0}};
  //after flush fe/is, the rf may wrongly pop before rtu_yy_xx_flush
  //need flush also when rtu_yy_xx_flush
  else if(rtu_yy_xx_flush)
    biq_entry_cnt[BIQ_CNT_W-1:0] <= {BIQ_CNT_W{1'b0}};
  else if(biq_entry_cnt_updt_vld)
    biq_entry_cnt[BIQ_CNT_W-1:0] <= biq_entry_cnt_next[BIQ_CNT_W-1:0];
  else
    biq_entry_cnt[BIQ_CNT_W-1:0] <= biq_entry_cnt[BIQ_CNT_W-1:0];
end

//--------------------biq entry full-----------------------
// ⚠️ full 上那个 `&& !issue` 不能省 (原版三个枚举项全是 pop_0 起头的);
//    少了它会在 cnt=N-2 & create=2 & issue=1 这类拍上多堵一下。
//    1_left 的六个枚举项 pop_0/pop_1 都有 ⇒ 就是纯粹的 R==BIQ_ENTRY-1。
assign biq_ctrl_full_updt   = (biq_entry_cnt_next == BIQ_ENTRY) && !biq_xx_issue_en;
assign biq_ctrl_1_left_updt = (biq_entry_cnt_next == (BIQ_ENTRY-1));

//issue queue entry create control
//create0 priority is from entry 0 to BIQ_ENTRY-1 (低位优先)
//create1 priority is from entry BIQ_ENTRY-1 to 0 (高位优先)

//biq create entry should consider pop signal and create0
assign biq_entry_create0_agevec[BIQ_ENTRY-1:0] = biq_entry_vld[BIQ_ENTRY-1:0]
                                        & ~({BIQ_ENTRY{biq_xx_issue_en}}
                                           & biq_entry_issue_en[BIQ_ENTRY-1:0]);

assign biq_entry_create1_agevec[BIQ_ENTRY-1:0] = biq_entry_vld[BIQ_ENTRY-1:0]
                                        & ~({BIQ_ENTRY{biq_xx_issue_en}}
                                           & biq_entry_issue_en[BIQ_ENTRY-1:0])
                                        | biq_entry_create0_in[BIQ_ENTRY-1:0];

//------------------entry issue enable signals--------------
//first find older ready entry, then not ready if older ready exists
assign biq_xx_issue_en = |biq_entry_issue_en[BIQ_ENTRY-1:0];

//-----------------issue data path selection----------------
//issue data path will select oldest ready entry in issue queue
//if no instruction valid, the data path will always select bypass
//data path
always_comb
begin
  biq_entry_read_data_sel[BIQ_WIDTH-1:0] = {BIQ_WIDTH{1'bx}};
  for (int k = 0; k < BIQ_ENTRY; k++)
    if (biq_entry_issue_en[k])
      biq_entry_read_data_sel[BIQ_WIDTH-1:0] = biq_entry_read_data[k][BIQ_WIDTH-1:0];
end
assign biq_dp_issue_read_data[BIQ_WIDTH-1:0] = biq_entry_read_data_sel[BIQ_WIDTH-1:0];

//==========================================================
//             BIQ Entry Instances
//==========================================================
genvar gi;
generate
for (gi = 0; gi < BIQ_ENTRY; gi = gi + 1) begin : g_biq_entry

    // 只在本项作用域里可见的位掩码 (gi 是 genvar, 各自展开成常量)
    localparam int BIQ_SELF_BIT = (1 << gi);            // 位 [gi]
    localparam int BIQ_MASK_LO  = BIQ_SELF_BIT - 1;     // 位 [gi-1:0]  —— 比自己年轻的
    localparam int BIQ_MASK_HI  = ~((BIQ_SELF_BIT << 1) - 1);  // 位 [N-1:gi+1] —— 比自己年长的
    localparam logic [BIQ_ENTRY-1:0] BIQ_SELF_ONE = BIQ_SELF_BIT[BIQ_ENTRY-1:0];

    logic [BIQ_ENTRY-1:0] entry_agevec;
    logic [BIQ_ENTRY-1:0] entry_create_agevec;
    logic [BIQ_WIDTH-1:0] entry_create_data;
    logic [BIQ_WIDTH-1:0] entry_read_data;

    //---- 建表优先级: create0 找序号最小的空项, create1 找序号最大的空项 ----
    // "序号最小" ⇒ 比自己小的那些项**全忙** ⇒ 写成 &(vld | ~MASK)。
    // ⚠️ 别写成 ~|(vld & MASK) —— 那是"比我小的全空", 会一次给好几项发 create
    // (AIQ 那边踩过, 由对拍台第 4 拍抓到)。
    assign biq_entry_create0_in[gi] = ~biq_entry_vld[gi]
                                    & (&(biq_entry_vld[BIQ_ENTRY-1:0]
                                          | ~BIQ_MASK_LO[BIQ_ENTRY-1:0]));
    assign biq_entry_create1_in[gi] = ~biq_entry_vld[gi]
                                    & (&(biq_entry_vld[BIQ_ENTRY-1:0]
                                          | ~BIQ_MASK_HI[BIQ_ENTRY-1:0]));

    assign biq_entry_create_en[gi] = ({1{ctrl_biq_create0_en}} & biq_entry_create0_in[gi])
                                   | ({1{ctrl_biq_create1_en}} & biq_entry_create1_in[gi]);

    //---- 本项被建表时, 灌进去的年龄向量与指令数据 ----
    assign entry_create_agevec[BIQ_ENTRY-1:0] =
             (biq_entry_create0_in[gi] ? biq_entry_create0_agevec[BIQ_ENTRY-1:0]
                                       : biq_entry_create1_agevec[BIQ_ENTRY-1:0])
           & ~BIQ_SELF_ONE[BIQ_ENTRY-1:0];
    assign entry_create_data[BIQ_WIDTH-1:0] =
             biq_entry_create0_in[gi] ? dp_biq_create0_data[BIQ_WIDTH-1:0]
                                      : dp_biq_create1_data[BIQ_WIDTH-1:0];

    //---- 发射仲裁: 就绪 且 没有更老的项就绪 ⇒ 本项发 ----
    assign biq_older_entry_ready[gi] = |(entry_agevec[BIQ_ENTRY-1:0]
                                         & biq_entry_ready[BIQ_ENTRY-1:0]);
    assign biq_entry_issue_en[gi]    = biq_entry_ready[gi] & ~biq_older_entry_ready[gi];

    //==========================================================
    //             BIQ Entry Instance
    //==========================================================
    ct_idu_is_biq_entry #(.BIQ_ENTRY(BIQ_ENTRY)) x_ct_idu_is_biq_entry (
        .cpurst_b                         (cpurst_b                         ),
        .ctrl_biq_rf_pop_vld              (biq_xx_issue_en             ),
        .forever_cpuclk                   (forever_cpuclk                   ),

        .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
        .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

        .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
        .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

        .iu_idu_ex2_pipe2_wb_preg_dupx    (iu_idu_ex2_pipe2_wb_preg_dupx    ),
        .iu_idu_ex2_pipe2_wb_preg_vld_dupx(iu_idu_ex2_pipe2_wb_preg_vld_dupx),

        .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
        .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

        .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

        .x_create_agevec                  (entry_create_agevec[BIQ_ENTRY-1:0]),
        .x_create_data                    (entry_create_data[BIQ_WIDTH-1:0] ),
        .x_create_en                      (biq_entry_create_en[gi]          ),
        .x_pop_cur_entry                  (biq_entry_issue_en[gi]           ),
        .x_pop_other_entry                (biq_entry_issue_en[BIQ_ENTRY-1:0]),

        .x_rdy                            (biq_entry_ready[gi]              ),
        .x_agevec                         (entry_agevec[BIQ_ENTRY-1:0]       ),
        .x_read_data                      (entry_read_data[BIQ_WIDTH-1:0]    ),
        .x_vld                            (biq_entry_vld[gi]                )
    );

    assign biq_entry_read_data[gi] = entry_read_data;

end
endgenerate
// &ModuleEnd;
endmodule
