//=============================================================================
// ct_idu_is_aiq —— ALU 发射队列 (Issue Queue for ALU, 单发射口)
//
// 2026-10-16 参数化: 新增 AIQ_ENTRY (深度), 编译期可用 `+define+AIQ_ENTRY=N`
//   覆盖, 默认 8。
//
// 【为什么参数化】移植时把发射队列砍小了 —— C910 原版 AIQ 是"两 bank × 8 项",
//   本树只剩一份 4 项 (注释里还留着 entry 0~7 的痕迹, 只有 aiq_entry_vld 被砍成
//   [3:0])。2026-10-16 的诊断: AIQ 满占了"有指令等着派"的 39.8%, 而满的那些拍里
//   68.2% **队里确实有就绪项发不出去** ⇒ 深度是瓶颈, 不是 ALU 端口排空到顶。
//   做成参数才能在同一份 RTL 下扫 4/8/16 三档, 而不是维护三份源码。
//
// 【结构】原版逐表项写死 (entry0..entry3 各写一遍, 连 create 优先级编码都是手写的
//   casez), 这里换成 generate 循环, 任意 N 自动展开。语义逐条对齐原版, 两处刻意
//   的改动:
//
//   1) 年龄向量 (agevec) 用 **AIQ_ENTRY 位自屏蔽**约定 (位 i ↔ 表项 i, 自己那一位
//      恒 0), 而不是原版的 N-1 位紧凑约定。原版 entry i 的 agevec 是"除自己外按
//      序号降序"的 N-1 位, 泛化要反复切片; 自屏蔽约定下
//          older_ready[i] = |(agevec[i] & ready)   // 自己那一位是 0, 不会自锁
//      一步到位。两种约定在 N=4 时逐位等价。
//
//   2) full / 1_left 判据改写成"下一拍占用 R = cnt + create - pop"再和
//      AIQ_ENTRY / AIQ_ENTRY-1 比较, 不再枚举项。原版 N=4 的六个枚举项与
//      R==4 / R==3 **逐项等价** (可达输入空间下; 见下一条)。
//      注意 create1_en ⟹ create0_en 恒成立 (ct_idu_ir_ctrl.sv:456
//      `al_2_aiq_inst` 蕴含 `al_1_aiq_inst`), 且两者同被 ctrl_is_dis_stall 闸住
//      ⇒ "create1 独占"这一支不可达, 原版那组枚举项里唯一的歧义分支也就不可达。
//
// 另外 `aiq_entry_create_sel` 在原版是**死代码** (赋值了但没有任何读者), 已删。
//
// 【时序提醒】issue 数据通路选择器在 N=16 时是 16 级优先级链 (原版注释说明要选
//   "最老的就绪项")。这里保持原语义不变; 若 16 档 Fmax 掉下来, 因为 issue_en
//   结构上就是 one-hot, 可以直接改成 one-hot 或-归约 (扁平成 1 级 LUT + OR 树)。
//=============================================================================
module ct_idu_is_aiq (
  //----------------------------------------------------------------------------
  // Outputs
  //----------------------------------------------------------------------------
  output logic         aiq_ctrl_1_left_updt,
  output logic         aiq_ctrl_full_updt,
  output logic         aiq_xx_issue_en,
  output logic [94:0]  aiq_dp_issue_read_data,   // 64 → 96 (2026-10-08 加 PC)

  //----------------------------------------------------------------------------
  // Inputs
  //----------------------------------------------------------------------------
  input  logic         cpurst_b,
  input  logic         ctrl_aiq_create0_en,
  input  logic         ctrl_aiq_create1_en,
  input  logic [94:0]  dp_aiq_create0_data,     // 64 → 96
  input  logic [94:0]  dp_aiq_create1_data,     // 64 → 96
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe2_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe2_wb_preg_vld_dupx,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush,

  // 2026-10-18 新增: 下游执行端口占住时的**发射保持**。
  //   stall=1 ⇒ 本拍既不发射、也不弹表项、也不改年龄向量; 队头留在原地,
  //   stall 撤销后同一条照常发。AIQ0 恒接 0 (与参数化之前逐拍等价);
  //   AIQ1 接 IU_alu_pipe 的 issue_stall (EX2 有结果但没拿到写回授权)。
  input  logic         aiq_ctrl_stall
);
parameter AIQ_WIDTH             = 95;   // 2026-10-08: 64 → 96 (高 32 位给 PC)
parameter AIQ_PC                = 94;   // 2026-10-08 新增: AUIPC 的 PC (高 32 位, 其余字段不动)
parameter AIQ_ILLEGAL           = 62; // 修正：补上分号
parameter AIQ_IID               = 61;
parameter AIQ_PREG              = 54;
parameter AIQ_SRC1_DATA         = 48;
parameter AIQ_SRC0_DATA         = 41;
parameter AIQ_DST_VLD           = 34;
parameter AIQ_SRC1_VLD          = 33;
parameter AIQ_SRC0_VLD          = 32;
parameter AIQ_OPCODE            = 31;

//----------------------------------------------------------------------------
// 队列深度: 编译期可用 `+define+AIQ_ENTRY=N` 覆盖, 默认 8 (C910 原版每 bank 8 项)。
//   N=4 时与参数化之前的树逐拍等价 (回归口径 `make a910-difftest-all` 46 PASS)。
//   注意: ctrl 侧 ctrl_aiq_create0_sel/create1_sel 是 2 位 (最多 3 条派遣车道),
//   与本参数无关 —— 那是"派哪条车道去 AIQ", 不是"进哪个表项"。
//----------------------------------------------------------------------------
`ifdef AIQ_ENTRY
  parameter int AIQ_ENTRY = `AIQ_ENTRY;
`else
  parameter int AIQ_ENTRY = 8;
`endif

localparam int AIQ_CNT_W = $clog2(AIQ_ENTRY + 1);   // 计数位宽: 4→3, 8→4, 16→5

    //----------------------------------------------------------------------------
    // Internal signals
    //----------------------------------------------------------------------------
    logic [AIQ_CNT_W-1:0] aiq_entry_cnt;
    logic [AIQ_CNT_W+1:0] aiq_entry_cnt_next;      // 多两位: 下一拍占用 (cnt+2-pop 不溢出)
    logic [1:0]           aiq_entry_cnt_create;
    logic                 aiq_entry_cnt_updt_vld;

    logic [AIQ_ENTRY-1:0] aiq_entry_vld;
    logic [AIQ_ENTRY-1:0] aiq_entry_create0_in;
    logic [AIQ_ENTRY-1:0] aiq_entry_create1_in;
    logic [AIQ_ENTRY-1:0] aiq_entry_create_en;

    // 建表时"其他表项"的快照 (N 位, 含自己那一位, create 时按自屏蔽约定清零)
    logic [AIQ_ENTRY-1:0] aiq_entry_create0_agevec;
    logic [AIQ_ENTRY-1:0] aiq_entry_create1_agevec;

    logic [AIQ_ENTRY-1:0] aiq_entry_ready;
    logic [AIQ_ENTRY-1:0] aiq_older_entry_ready;
    logic [AIQ_ENTRY-1:0] aiq_entry_issue_en;   // 原始仲裁结果 (最老的就绪项)
    logic [AIQ_ENTRY-1:0] aiq_entry_issue_go;   // 再过一道 aiq_ctrl_stall
    logic [AIQ_WIDTH-1:0] aiq_entry_read_data [AIQ_ENTRY];
    logic [AIQ_WIDTH-1:0] aiq_entry_read_data_sel;

//--------------------aiq entry counter--------------------
//if create, add entry counter
assign aiq_entry_cnt_create[1:0]   = {1'b0,ctrl_aiq_create0_en}
                                      + {1'b0,ctrl_aiq_create1_en};
//update valid and value (与原版一致: create1 必然伴随 create0, 故只判 create0)
assign aiq_entry_cnt_updt_vld      = ctrl_aiq_create0_en
                                      || aiq_xx_issue_en;
// 下一拍占用: cnt + create - pop。判满/判"只剩一个坑"都用它比 (见文件头第 2 条)。
assign aiq_entry_cnt_next[AIQ_CNT_W+1:0] = {2'b0,aiq_entry_cnt}
                                      + {{AIQ_CNT_W{1'b0}},aiq_entry_cnt_create}
                                      - {{(AIQ_CNT_W+1){1'b0}},aiq_xx_issue_en};
//implement entry counter
always_ff @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    aiq_entry_cnt[AIQ_CNT_W-1:0] <= {AIQ_CNT_W{1'b0}};
  //after flush fe/is, the rf may wrongly pop before rtu_yy_xx_flush
  //need flush also when rtu_yy_xx_flush
  else if(rtu_yy_xx_flush)
    aiq_entry_cnt[AIQ_CNT_W-1:0] <= {AIQ_CNT_W{1'b0}};
  else if(aiq_entry_cnt_updt_vld)
    aiq_entry_cnt[AIQ_CNT_W-1:0] <= aiq_entry_cnt_next[AIQ_CNT_W-1:0];
  else
    aiq_entry_cnt[AIQ_CNT_W-1:0] <= aiq_entry_cnt[AIQ_CNT_W-1:0];
end

//--------------------aiq entry full-----------------------
// 满: 下一拍占用就顶到 AIQ_ENTRY 且本拍**没有**项出去 (再派必溢出);
// 只剩一个: 下一拍占用顶到 AIQ_ENTRY-1 (两条派遣车道塞不下第二个)。
// ctrl 侧 (ct_idu_is_ctrl.sv:524) 用这两个信号:
//   派 create0 && full      ⇒ 堵
//   派 create1 && 1_left    ⇒ 堵
//
// ⚠️ full 上那个 `&& !issue` 不能省: 原版三个枚举项全是 pop_0 起头的
//   (本拍有项发走就腾出坑来, 下一拍照样能派)。少了它会在
//   cnt=3&create=2&issue=1 这类拍上多堵一下 —— tb_aiq_equiv 第 13 拍抓到过。
//   而 1_left 的六个枚举项里 pop_0/pop_1 都有, 就是纯粹的 R==AIQ_ENTRY-1。
assign aiq_ctrl_full_updt   = (aiq_entry_cnt_next == AIQ_ENTRY) && !aiq_xx_issue_en;
assign aiq_ctrl_1_left_updt = (aiq_entry_cnt_next == (AIQ_ENTRY-1));

//issue queue entry create control
//create0 priority is from entry 0 to AIQ_ENTRY-1 (低位优先)
//create1 priority is from entry AIQ_ENTRY-1 to 0 (高位优先)
//aiq_entry_vld is driven by each entry instance's x_vld

//aiq create entry should consider pop signal and create0
// 建表时刻"队列里还有谁"的快照: 先扣掉本拍发射走的项, 再算 create1 时要多算上
// 同拍 create0 刚放进去的那一项 (它相对 create1 的项更老)。
assign aiq_entry_create0_agevec[AIQ_ENTRY-1:0] = aiq_entry_vld[AIQ_ENTRY-1:0]
                                        & ~({AIQ_ENTRY{aiq_xx_issue_en}}
                                           & aiq_entry_issue_go[AIQ_ENTRY-1:0]);

assign aiq_entry_create1_agevec[AIQ_ENTRY-1:0] = aiq_entry_vld[AIQ_ENTRY-1:0]
                                        & ~({AIQ_ENTRY{aiq_xx_issue_en}}
                                           & aiq_entry_issue_go[AIQ_ENTRY-1:0])
                                        | aiq_entry_create0_in[AIQ_ENTRY-1:0];

//------------------entry issue enable signals--------------
//first find older ready entry, then not ready if older ready exists
// ⚠️ 发射/弹表项/年龄向量一律用 `aiq_entry_issue_go` (已过 stall);
//    读数据选择仍用原始的 `aiq_entry_issue_en` —— stall 时虽然不会发射,
//    但保持"最老就绪项"的选择, 避免组合输出变成 X 污染波形。
assign aiq_xx_issue_en = |aiq_entry_issue_go[AIQ_ENTRY-1:0];

//-----------------issue data path selection----------------
//issue data path will select oldest ready entry in issue queue
//if no instruction valid, the data path will always select bypass
//data path
always_comb
begin
  aiq_entry_read_data_sel[AIQ_WIDTH-1:0] = {AIQ_WIDTH{1'bx}};
  for (int k = 0; k < AIQ_ENTRY; k++)
    if (aiq_entry_issue_en[k])
      aiq_entry_read_data_sel[AIQ_WIDTH-1:0] = aiq_entry_read_data[k][AIQ_WIDTH-1:0];
end
assign aiq_dp_issue_read_data[AIQ_WIDTH-1:0] = aiq_entry_read_data_sel[AIQ_WIDTH-1:0];

//==========================================================
//             ALU Issue Queue Entry Instances
//==========================================================
genvar gi;
generate
for (gi = 0; gi < AIQ_ENTRY; gi = gi + 1) begin : g_aiq_entry

    // 只在本项作用域里可见的位掩码 (gi 是 genvar, 各自展开成常量)
    localparam int AIQ_SELF_BIT = (1 << gi);            // 位 [gi]
    localparam int AIQ_MASK_LO  = AIQ_SELF_BIT - 1;     // 位 [gi-1:0]  —— 比自己年轻的
    localparam int AIQ_MASK_HI  = ~((AIQ_SELF_BIT << 1) - 1);  // 位 [N-1:gi+1] —— 比自己年长的
    localparam logic [AIQ_ENTRY-1:0] AIQ_SELF_ONE = AIQ_SELF_BIT[AIQ_ENTRY-1:0];  // 只有位 [gi] 是 1

    logic [AIQ_ENTRY-1:0] entry_agevec;         // 本项存着的年龄向量
    logic [AIQ_ENTRY-1:0] entry_create_agevec;  // 建表时灌进去的年龄向量
    logic [AIQ_WIDTH-1:0] entry_create_data;
    logic [AIQ_WIDTH-1:0] entry_read_data;

    //---- 建表优先级: create0 找序号最小的空项, create1 找序号最大的空项 ----
    // "序号最小" ⇒ 比自己小的那些项**全忙** (人家先占了, 才轮到我); 掩码外的不约束
    //   ⇒ 写成 &(vld | ~MASK)。原版 casez `4'b10??: 选1` 就是这个意思。
    //   ⚠️ 别写成 ~|(vld & MASK) —— 那是"比我小的全空", 会一次给好几项发 create
    //   (2026-10-16 踩过, 由 tb_aiq_equiv 第 4 拍抓到)。
    assign aiq_entry_create0_in[gi] = ~aiq_entry_vld[gi]
                                    & (&(aiq_entry_vld[AIQ_ENTRY-1:0]
                                          | ~AIQ_MASK_LO[AIQ_ENTRY-1:0]));
    assign aiq_entry_create1_in[gi] = ~aiq_entry_vld[gi]
                                    & (&(aiq_entry_vld[AIQ_ENTRY-1:0]
                                          | ~AIQ_MASK_HI[AIQ_ENTRY-1:0]));

    //aiq_entry_create0/1_in cannot be both 1 (除"只剩一个空项"那一拍, 而 ctrl 的
    //1_left 判据已经把那一拍的 create1 闸掉了 —— 见文件头第 2 条)
    assign aiq_entry_create_en[gi] = ({1{ctrl_aiq_create0_en}} & aiq_entry_create0_in[gi])
                                   | ({1{ctrl_aiq_create1_en}} & aiq_entry_create1_in[gi]);

    //---- 本项被建表时, 灌进去的年龄向量与指令数据 ----
    // 年龄向量按 create0_in 选 source, 再把自己那一位清 0 (自屏蔽约定)
    assign entry_create_agevec[AIQ_ENTRY-1:0] =
             (aiq_entry_create0_in[gi] ? aiq_entry_create0_agevec[AIQ_ENTRY-1:0]
                                       : aiq_entry_create1_agevec[AIQ_ENTRY-1:0])
           & ~AIQ_SELF_ONE[AIQ_ENTRY-1:0];
    assign entry_create_data[AIQ_WIDTH-1:0] =
             aiq_entry_create0_in[gi] ? dp_aiq_create0_data[AIQ_WIDTH-1:0]
                                      : dp_aiq_create1_data[AIQ_WIDTH-1:0];

    //---- 发射仲裁: 就绪 且 没有更老的项就绪 ⇒ 本项发 ----
    assign aiq_older_entry_ready[gi] = |(entry_agevec[AIQ_ENTRY-1:0]
                                         & aiq_entry_ready[AIQ_ENTRY-1:0]);
    assign aiq_entry_issue_en[gi]    = aiq_entry_ready[gi] & ~aiq_older_entry_ready[gi];
    // 下游端口占住时保持: 不弹表项、不更新年龄向量、不计 pop
    assign aiq_entry_issue_go[gi]    = aiq_entry_issue_en[gi] & ~aiq_ctrl_stall;

    //==========================================================
    //             ALU Issue Queue Entry Instance
    //==========================================================
    ct_idu_is_aiq_entry #(.AIQ_ENTRY(AIQ_ENTRY)) x_ct_idu_is_aiq_entry (
        .cpurst_b                         (cpurst_b                         ),
        .ctrl_aiq0_rf_pop_vld              (aiq_xx_issue_en             ),
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

        .x_create_agevec                  (entry_create_agevec[AIQ_ENTRY-1:0]),
        .x_create_data                    (entry_create_data[AIQ_WIDTH-1:0] ),
        .x_create_en                      (aiq_entry_create_en[gi]          ),
        .x_pop_cur_entry                  (aiq_entry_issue_go[gi]           ),
        // 把自己那一位也连进去是无害的: 本项 agevec 的自屏蔽位恒 0, 清不动它
        .x_pop_other_entry                (aiq_entry_issue_go[AIQ_ENTRY-1:0]),

        .x_rdy                            (aiq_entry_ready[gi]              ),
        .x_agevec                         (entry_agevec[AIQ_ENTRY-1:0]       ),
        .x_read_data                      (entry_read_data[AIQ_WIDTH-1:0]    ),
        .x_vld                            (aiq_entry_vld[gi]                )
    );

    assign aiq_entry_read_data[gi] = entry_read_data;

end
endgenerate
// &ModuleEnd;
endmodule
