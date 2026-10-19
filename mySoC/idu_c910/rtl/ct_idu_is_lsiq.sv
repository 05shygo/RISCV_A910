//=============================================================================
// ct_idu_is_lsiq —— load/store 发射队列 (单一队列, 两个发射口: pipe3=load,
//   pipe4=store/bar)
//
// 2026-10-16 参数化: 新增 LSIQ_ENTRY (深度), 编译期可用 `+define+LSIQ_ENTRY=N`
//   覆盖, 默认 12。
//
// 【为什么参数化】移植时把发射队列砍小了 —— C910 原版 BIQ/SDIQ/LSIQ = 12/12/12,
//   本树被砍成 4/4/8 (commit 165dfd5 "位宽对齐 64 preg / 8 LSIQ" 把 LSIQ 从 12
//   收到 8, 去迁就当时 64 preg 的 LSU)。AIQ/BIQ 加宽之后 (doc/a910_aiq_width_zh.md
//   §10.7) LSIQ 满升到"有指令等着派"的 21.7%, 成了第一大挡路者 —— 而机制是
//   整机级的: `ctrl_is_dis_stall = rob_full || iq_full`, `iq_full` 是六个队列相或,
//   任意一个满就把整个派遣口堵死 (3 条车道全停, 哪怕等的是 ALU 指令)。
//   LSU 侧早就按 `LSIQ_ENTRY` 参数化了, 只有这里还是逐表项写死。
//
// 【结构】原版逐表项写死 (entry0..entry7 各写一遍, 连建表优先级编码都是手写的
//   casez), 这里换成 generate 循环, 任意 N 自动展开。语义逐条对齐原版, 三处
//   刻意的改动:
//
//   1) 年龄向量 (agevec) 用 **LSIQ_ENTRY 位自屏蔽**约定 (位 i ↔ 表项 i, 自己那
//      一位恒 0), 而不是原版的 N-1 位紧凑约定。原版 entry i 的 agevec 是"除自己
//      外按序号降序"的 N-1 位, 泛化要反复切片; 自屏蔽约定下
//          older_entry_rdy_mask = |(agevec & raw_rdy)   // 自己那一位是 0, 不自锁
//      一步到位。两种约定在 N=8 时逐位等价 (tb_lsiq_equiv 按语义映射逐位比)。
//
//   2) 两个建表优先级编码 (casez) 换成"掩码 + 与归约", 见 ct_idu_is_aiq.sv 的同款
//      写法与那两个坑的注释。N=12 时 casez 要写 4096 个模式, 不可行。
//
//   3) full / 1_left 判据改写成"下一拍占用 R = cnt + create - pop"再和
//      LSIQ_ENTRY / LSIQ_ENTRY-1 比较, 不再枚举组合。原版 N=8 的 3+6 个枚举项与
//      下面两式**等价**, 但有一个前提要说清楚:
//        ⚠️ 原版的 create 用的是**独热编码** `create_2 = create1_en` /
//           `create_1 = create0_en && !create1_en` / `create_0 = !create0_en`,
//           而它自己的计数器用的是**二进制** `create0_en + create1_en` —— 两者
//           只有在 `create1_en ⟹ create0_en` 时才一致。这个蕴含关系在本树是
//           **结构性成立**的 (ct_idu_ir_ctrl.sv:644 `pre_dis_lsiq_create1_en` 是
//           "三条车道里至少两条是 lsiq" 的与或, 蕴含 `create0_en` 的"至少一条"),
//           且两者同被 `ctrl_is_dis_stall` 闸住 (ct_idu_is_ctrl.sv:449-450)。
//           下面按**二进制**口径写 (与计数器同源); 真核输入空间下与原版逐位相同,
//           tb_lsiq_equiv 也按这条契约喂激励。
//        * full   三项全是 pop_0 起头 (本拍有项出去就腾出坑) ⇒
//                 `pop_0 & (R == LSIQ_ENTRY)`, 对全部输入组合逐位相同。
//        * 1_left 六项只覆盖 pop∈{0,1}; `R == LSIQ_ENTRY-1` 而不含 `pop=2`
//                 (两个 pop 同拍都有效) ⇒ 朴素的 `R == LSIQ_ENTRY-1` 会与 ref
//                 **分叉**, 必须带上 `& ~(pop0_vld & pop1_vld)`。
//
// 【时序提醒】发射数据通路选择器在 N=12 时是一条 12 级优先级链。这里保持原语义
//   (原版那串 casez 就是按序号选的); 若 N 再大导致 Fmax 掉下来, 因为
//   `lsiq_dp_pipe3/4_issue_entry` 结构上就是 one-hot, 可以直接改成或-归约。
//=============================================================================
module ct_idu_is_lsiq #(
`ifdef LSIQ_ENTRY
  parameter int LSIQ_ENTRY = `LSIQ_ENTRY
`else
  parameter int LSIQ_ENTRY = 12
`endif
) (
  input  logic         cpurst_b,
  input  logic         ctrl_lsiq_create0_en,
  input  logic         ctrl_lsiq_create1_en,
  input  logic [59:0]  dp_lsiq_create0_data,
  input  logic [59:0]  dp_lsiq_create1_data,
  input  logic         forever_cpuclk,
  input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
  input  logic [5:0]   iu_idu_ex2_pipe2_wb_preg_dupx,
  input  logic         iu_idu_ex2_pipe2_wb_preg_vld_dupx,
  input  logic [LSIQ_ENTRY-1:0] lsu_idu_lq_full,
  input  logic         lsu_idu_lq_not_full,
  input  logic         lsu_idu_lsiq_pop0_vld,
  input  logic         lsu_idu_lsiq_pop1_vld,
  input  logic [LSIQ_ENTRY-1:0] lsu_idu_lsiq_pop_entry,
  input  logic         lsu_idu_lsiq_pop_vld,
  input  logic [LSIQ_ENTRY-1:0] lsu_idu_rb_full,
  input  logic         lsu_idu_rb_not_full,
  // 2026-10-19 停用: 非对齐第二半链路整条摘除, IDU 不再接收 LSU 的 secd
  //input  logic [LSIQ_ENTRY-1:0] lsu_idu_secd,
  input  logic [LSIQ_ENTRY-1:0] lsu_idu_sq_full,
  input  logic         lsu_idu_sq_not_full,
  input  logic [LSIQ_ENTRY-1:0] lsu_idu_imme_wakeup,
  input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
  input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
  input  logic         rtu_yy_xx_flush,
  output logic         lsiq_ctrl_1_left_updt,
  output logic         lsiq_ctrl_full_updt,
  output logic         lsiq_rf_pipe3_issue_en,
  output logic         lsiq_rf_pipe4_issue_en,
  output logic [59:0]  lsiq_dp_pipe3_entry_read_data,
  // 2026-10-19 停用: 非对齐第二半标记 (随非对齐硬件一并摘除)
  //output logic         lsiq_pipe3_entry_unalign_2nd,
  output logic         lsiq_pipe3_entry_old,
  output logic [LSIQ_ENTRY-1:0] lsiq_dp_pipe3_issue_entry,
  output logic [59:0]  lsiq_dp_pipe4_entry_read_data,
  //output logic         lsiq_pipe4_entry_unalign_2nd,
  output logic         lsiq_pipe4_entry_old,
  output logic [LSIQ_ENTRY-1:0] lsiq_dp_pipe4_issue_entry
);

parameter LSIQ_WIDTH             = 60;
parameter LSIQ_IID               = 59;
parameter LSIQ_SDIQ_ENTRY        = 52;
parameter LSIQ_STORE             = 48;
parameter LSIQ_LOAD              = 47;
parameter LSIQ_SRC0_DATA         = 46;
parameter LSIQ_DST_PREG          = 39;
parameter LSIQ_DST_VLD           = 33;
parameter LSIQ_SRC0_VLD          = 32;
parameter LSIQ_OPCODE            = 31;

// 计数位宽: 12 项仍是 4 位 (与原版写死的 [3:0] 同宽), 扫 16 会自动加宽。
localparam int LSIQ_CNT_W = $clog2(LSIQ_ENTRY + 1);

// 落地自证: 这一行是判断"`+define+LSIQ_ENTRY` 到底进没进 RTL"的**唯一**可靠判据
// (照 rv32ifu2_icache.v 的 [IFU2-ICACHE] 那行的先例)。深度差 8/12 只值百分之几,
// 光看周期**分不出来**; 而 A910 那几条规则不挂 BP_DEFS, 忘了走 VCS_FLAGS_EXTRA
// 就会静默用默认档。跑之前先 grep 日志里这一行。
initial $display("[IDU-LSIQ] ENTRY=%0d CNT_W=%0d  (判据: 应与 +define+LSIQ_ENTRY 一致; 不给 = 默认 12)",
                 LSIQ_ENTRY, LSIQ_CNT_W);

  //------------------- 内部信号声明 -------------------
  // 计数器
  logic [LSIQ_CNT_W-1:0]   lsiq_entry_cnt;
  logic [LSIQ_CNT_W+1:0]   lsiq_entry_cnt_next;   // 多两位: cnt+create-pop 不溢出
  logic [1:0]  lsiq_entry_cnt_create;
  logic [1:0]  lsiq_entry_cnt_pop;
  logic        lsiq_entry_cnt_updt_vld;
  logic        lsiq_entry_cnt_pop_0;

  // entry 有效位
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_vld;

  // create 选择
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create0_in;
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create1_in;
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create_en;

  // agevec
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create0_agevec;
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create1_agevec;
  // agevec of ALL types (原版 lsiq_entry_createN_agevec_all) —— 给表项的 old 用
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create0_agevec_all;
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create1_agevec_all;

  // issue
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_issue_en;
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_ready;
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_load;
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_store;
  logic [LSIQ_ENTRY-1:0]  lsiq_pipe3_entry_ready;
  logic [LSIQ_ENTRY-1:0]  lsiq_pipe4_entry_ready;

  // unalign
  // 2026-10-19 停用: 非对齐第二半标记
  //logic [LSIQ_ENTRY-1:0]  unalign_2nd;

  // pop
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_pop_cur_entry;

  // raw ready
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_raw_rdy;

  // 【下述数组都是"每表项一份"】用 packed/unpacked 端口数组, 由 generate 展开
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create_agevec     [LSIQ_ENTRY-1:0];
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_create_agevec_all [LSIQ_ENTRY-1:0];
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_pop_other_entry   [LSIQ_ENTRY-1:0];
  logic [LSIQ_ENTRY-1:0]  lsiq_entry_other_raw_rdy     [LSIQ_ENTRY-1:0];

  logic [LSIQ_WIDTH-1:0]  lsiq_entry_create_data       [LSIQ_ENTRY-1:0];
  logic [LSIQ_WIDTH-1:0]  lsiq_entry_read_data         [LSIQ_ENTRY-1:0];

  logic                   lsiq_entry_lq_full_set       [LSIQ_ENTRY-1:0];
  logic                   lsiq_entry_sq_full_set       [LSIQ_ENTRY-1:0];
  logic                   lsiq_entry_rb_full_set       [LSIQ_ENTRY-1:0];
  // 2026-10-19 停用: 非对齐第二半置位 (来源 lsu_idu_secd 已摘)
  //logic                   lsiq_entry_unalign_2nd_set   [LSIQ_ENTRY-1:0];
  logic                   lsiq_entry_old               [LSIQ_ENTRY-1:0];

  // 【补齐】create load/store 信号
  logic        dp_lsiq_create0_load;
  logic        dp_lsiq_create0_store;
  logic        dp_lsiq_create1_load;
  logic        dp_lsiq_create1_store;

//--------------------lsiq entry counter--------------------
//if create, add entry counter
assign lsiq_entry_cnt_create[1:0]   = {1'b0,ctrl_lsiq_create0_en}
                                      + {1'b0,ctrl_lsiq_create1_en};
//if pop, sub entry counter
assign lsiq_entry_cnt_pop[1:0]      = {lsu_idu_lsiq_pop0_vld &  lsu_idu_lsiq_pop1_vld,
                                       lsu_idu_lsiq_pop0_vld ^  lsu_idu_lsiq_pop1_vld};

//update valid and value
assign lsiq_entry_cnt_updt_vld      = ctrl_lsiq_create0_en
                                      || lsu_idu_lsiq_pop_vld;
// 下一拍占用: cnt + create - pop。判满/判"只剩一个坑"都用它比 (见文件头第 3 条)。
assign lsiq_entry_cnt_next[LSIQ_CNT_W+1:0] = {2'b0, lsiq_entry_cnt[LSIQ_CNT_W-1:0]}
                                      + {{LSIQ_CNT_W{1'b0}}, lsiq_entry_cnt_create[1:0]}
                                      - {{LSIQ_CNT_W{1'b0}}, lsiq_entry_cnt_pop[1:0]};
//implement entry counter
always @(posedge forever_cpuclk or negedge cpurst_b)
begin
  if(!cpurst_b)
    lsiq_entry_cnt[LSIQ_CNT_W-1:0] <= {LSIQ_CNT_W{1'b0}};
  //after flush fe/is, the lsu may wrongly pop before rtu_yy_xx_flush
  //need flush also when rtu_yy_xx_flush
  else if(rtu_yy_xx_flush)
    lsiq_entry_cnt[LSIQ_CNT_W-1:0] <= {LSIQ_CNT_W{1'b0}};
  else if(lsiq_entry_cnt_updt_vld)
    lsiq_entry_cnt[LSIQ_CNT_W-1:0] <= lsiq_entry_cnt_next[LSIQ_CNT_W-1:0];
  else
    lsiq_entry_cnt[LSIQ_CNT_W-1:0] <= lsiq_entry_cnt[LSIQ_CNT_W-1:0];
end

//--------------------lsiq entry full----------------------
// ⚠️ 原版这里还有一根 `lsiq_entry_cnt_pop_1` (`pop0 ^ pop1`)。它当年只喂给下面那串
//    枚举式 full/1_left 当条件 —— 换成 `cnt_next` 的比较之后**全仓零引用**了,
//    故删除 (留着就是一根死线, 日后有人会以为它还在参与判据)。
assign lsiq_entry_cnt_pop_0    = !lsu_idu_lsiq_pop0_vld && !lsu_idu_lsiq_pop1_vld;

// 满: 下一拍占用顶到 LSIQ_ENTRY 且本拍**没有**项出去 (再派必溢出)。
// 只剩一个: 下一拍占用顶到 LSIQ_ENTRY-1, 且**不是**同拍两个 pop 都有效。
// ctrl 侧 (ct_idu_is_ctrl.sv) 用这两个信号:
//   派 create0 && full      ⇒ 堵
//   派 create1 && 1_left    ⇒ 堵
assign lsiq_ctrl_full_updt     = lsiq_entry_cnt_pop_0
                                 && (lsiq_entry_cnt_next[LSIQ_CNT_W+1:0]
                                     == LSIQ_ENTRY[LSIQ_CNT_W+1:0]);

assign lsiq_ctrl_1_left_updt   = !(lsu_idu_lsiq_pop0_vld && lsu_idu_lsiq_pop1_vld)
                                 && (lsiq_entry_cnt_next[LSIQ_CNT_W+1:0]
                                     == (LSIQ_ENTRY-1));

// create0 priority is from entry 0 to LSIQ_ENTRY-1
// create1 priority is from entry LSIQ_ENTRY-1 to 0
// lsiq_entry_vld 由各表项实例的 x_vld 驱动 (见下面的 generate)
assign lsiq_entry_create_en[LSIQ_ENTRY-1:0] =
       {LSIQ_ENTRY{ctrl_lsiq_create0_en}} & lsiq_entry_create0_in[LSIQ_ENTRY-1:0]
     | {LSIQ_ENTRY{ctrl_lsiq_create1_en}} & lsiq_entry_create1_in[LSIQ_ENTRY-1:0];

assign dp_lsiq_create0_load = dp_lsiq_create0_data[LSIQ_LOAD];
assign dp_lsiq_create0_store = dp_lsiq_create0_data[LSIQ_STORE];
assign dp_lsiq_create1_load = dp_lsiq_create1_data[LSIQ_LOAD];
assign dp_lsiq_create1_store = dp_lsiq_create1_data[LSIQ_STORE];
//-------------------agevec of same type--------------------
//create 0 age vectors:
//1.existed entries of same type (bar and store shares same type)
assign lsiq_entry_create0_agevec[LSIQ_ENTRY-1:0] =
          lsiq_entry_vld[LSIQ_ENTRY-1:0]
          & ( {LSIQ_ENTRY{dp_lsiq_create0_load}} & lsiq_entry_load[LSIQ_ENTRY-1:0]
            | {LSIQ_ENTRY{dp_lsiq_create0_store}} & lsiq_entry_store[LSIQ_ENTRY-1:0])
          & ~(lsu_idu_lsiq_pop_entry[LSIQ_ENTRY-1:0]);
//create 1 age vectors:
//1.existed entries of same type
//2.create 0 entry of same type
assign lsiq_entry_create1_agevec[LSIQ_ENTRY-1:0] =
          lsiq_entry_vld[LSIQ_ENTRY-1:0]
          & ( {LSIQ_ENTRY{dp_lsiq_create1_load}} & lsiq_entry_load[LSIQ_ENTRY-1:0]
            | {LSIQ_ENTRY{dp_lsiq_create1_store}} & lsiq_entry_store[LSIQ_ENTRY-1:0])
          & ~(lsu_idu_lsiq_pop_entry[LSIQ_ENTRY-1:0])
        | lsiq_entry_create0_in[LSIQ_ENTRY-1:0]
          & {LSIQ_ENTRY{dp_lsiq_create0_load && dp_lsiq_create1_load
            || dp_lsiq_create0_store && dp_lsiq_create1_store}};

//-------------------agevec of ALL types--------------------
//原版: create0_agevec_all = 所有还在的表项(不分 load/store)
//      create1_agevec_all = 所有还在的表项 | 同拍 create0 的那条
assign lsiq_entry_create0_agevec_all[LSIQ_ENTRY-1:0] =
          lsiq_entry_vld[LSIQ_ENTRY-1:0]
          & ~(lsu_idu_lsiq_pop_entry[LSIQ_ENTRY-1:0]);

assign lsiq_entry_create1_agevec_all[LSIQ_ENTRY-1:0] =
          (lsiq_entry_vld[LSIQ_ENTRY-1:0] & ~(lsu_idu_lsiq_pop_entry[LSIQ_ENTRY-1:0]))
        | lsiq_entry_create0_in[LSIQ_ENTRY-1:0];

// 建表时刻"队列里还有谁"的快照 (原版 lsiq_entry_createN_agevec) —— 见上面的 assign。
// 每表项那一份的"自己那一位"由 generate 里的 SELF_ONE 清掉 (自屏蔽约定)。

//==========================================================
//             LSU Issue Queue Issue Control
//==========================================================
//-----------entry issue enable signals for entries---------
//issue signals for entries ignore inst type
assign lsiq_entry_issue_en[LSIQ_ENTRY-1:0]  = lsiq_entry_ready[LSIQ_ENTRY-1:0];

//---------------entry issue signals for rf pipes-----------
//load entry ready
assign lsiq_pipe3_entry_ready[LSIQ_ENTRY-1:0]    = lsiq_entry_ready[LSIQ_ENTRY-1:0]
                                                   & lsiq_entry_load[LSIQ_ENTRY-1:0];
//store and bar entry ready
assign lsiq_pipe4_entry_ready[LSIQ_ENTRY-1:0]    = lsiq_entry_ready[LSIQ_ENTRY-1:0]
                                                   & lsiq_entry_store[LSIQ_ENTRY-1:0];
//issue enable for rf pipes:
//consider inst type
assign lsiq_dp_pipe3_issue_entry[LSIQ_ENTRY-1:0] = lsiq_pipe3_entry_ready[LSIQ_ENTRY-1:0];
assign lsiq_dp_pipe4_issue_entry[LSIQ_ENTRY-1:0] = lsiq_pipe4_entry_ready[LSIQ_ENTRY-1:0];

assign lsiq_rf_pipe3_issue_en = |lsiq_dp_pipe3_issue_entry[LSIQ_ENTRY-1:0];

assign lsiq_rf_pipe4_issue_en = |lsiq_dp_pipe4_issue_entry[LSIQ_ENTRY-1:0];

//-----------------issue data path selection----------------
// issue data path will select oldest ready entry in issue queue.
//
// ⚠️ 原版这里是一串 `case (lsiq_dp_pipeN_issue_entry)` 逐项列 8 个 one-hot 模式,
//    **只在恰好一位时命中**, 其余 (全 0 / 多位 / 含 x) 一律走 default 给 X。
//    换成循环以后"多位"这一支会变成"取序号最大的那位" —— 与原版**分叉**
//    (tb_lsiq_equiv 第 39 拍就抓到过一次: p3iss 同时置位两位)。
//    所以下面显式补一个 one-hot 判据, 不是 one-hot 就强制回 X, 与原版逐位一致。
//
// ⚠️ 默认值也必须是 X (原版"一个都没就绪"时走 default)。
// ⚠️ 残留差异 (不可达): 若 issue_entry 本身含 x, 原版 case 不匹配 ⇒ X, 而这里的
//    one-hot 判据在 4 值逻辑下是 x ⇒ `if(!x)` 不成立 ⇒ 保留循环选出的值。要出现
//    x 得先有 x 进 vld/ready 这些触发器 —— 全都有复位, 复位后不可达。
logic p3_sel_onehot, p4_sel_onehot;
assign p3_sel_onehot = (lsiq_dp_pipe3_issue_entry[LSIQ_ENTRY-1:0] != {LSIQ_ENTRY{1'b0}})
                    && ((lsiq_dp_pipe3_issue_entry[LSIQ_ENTRY-1:0]
                         & (lsiq_dp_pipe3_issue_entry[LSIQ_ENTRY-1:0] - 1'b1))
                        == {LSIQ_ENTRY{1'b0}});
assign p4_sel_onehot = (lsiq_dp_pipe4_issue_entry[LSIQ_ENTRY-1:0] != {LSIQ_ENTRY{1'b0}})
                    && ((lsiq_dp_pipe4_issue_entry[LSIQ_ENTRY-1:0]
                         & (lsiq_dp_pipe4_issue_entry[LSIQ_ENTRY-1:0] - 1'b1))
                        == {LSIQ_ENTRY{1'b0}});

always_comb
begin
  lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] = {LSIQ_WIDTH{1'bx}};
  // 2026-10-19 停用: lsiq_pipe3_entry_unalign_2nd = 1'bx;
  lsiq_pipe3_entry_old         = 1'bx;
  lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] = {LSIQ_WIDTH{1'bx}};
  // 2026-10-19 停用: lsiq_pipe4_entry_unalign_2nd = 1'bx;
  lsiq_pipe4_entry_old         = 1'bx;
  for (int k = 0; k < LSIQ_ENTRY; k++) begin
    if (lsiq_dp_pipe3_issue_entry[k]) begin
      lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] = lsiq_entry_read_data[k][LSIQ_WIDTH-1:0];
      // 2026-10-19 停用: lsiq_pipe3_entry_unalign_2nd = unalign_2nd[k];
      lsiq_pipe3_entry_old         = lsiq_entry_old[k];
    end
    if (lsiq_dp_pipe4_issue_entry[k]) begin
      lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] = lsiq_entry_read_data[k][LSIQ_WIDTH-1:0];
      // 2026-10-19 停用: lsiq_pipe4_entry_unalign_2nd = unalign_2nd[k];
      lsiq_pipe4_entry_old         = lsiq_entry_old[k];
    end
  end
  // 非 one-hot ⇒ 回 X (见上面第 2 条注释)
  if (!p3_sel_onehot) begin
    lsiq_dp_pipe3_entry_read_data[LSIQ_WIDTH-1:0] = {LSIQ_WIDTH{1'bx}};
    // 2026-10-19 停用: lsiq_pipe3_entry_unalign_2nd = 1'bx;
    lsiq_pipe3_entry_old         = 1'bx;
  end
  if (!p4_sel_onehot) begin
    lsiq_dp_pipe4_entry_read_data[LSIQ_WIDTH-1:0] = {LSIQ_WIDTH{1'bx}};
    // 2026-10-19 停用: lsiq_pipe4_entry_unalign_2nd = 1'bx;
    lsiq_pipe4_entry_old         = 1'bx;
  end
end

//==========================================================
//             LSU Issue Queue Entry Instances
//==========================================================
// 原版这里还有一节 "LSU Issue Queue Launch Control": 每个表项的 pop_cur/pop_other、
// lq/sq/rb_full_set、unalign_2nd_set、raw_rdy/other_raw_rdy 全是手写的 8 份切片。
// 那些切片在自屏蔽约定下都退化成 "取第 i 位" / "取整体再清第 i 位", 所以整节搬进
// 下面的 generate 里 (见 loop 内那几条 assign), 不再单独列。

genvar gi;
generate
for (gi = 0; gi < LSIQ_ENTRY; gi = gi + 1) begin : g_lsiq_entry

    // 只在本项作用域里可见的位掩码 (gi 是 genvar, 各自展开成常量)
    localparam int LSIQ_SELF_BIT = (1 << gi);                   // 位 [gi]
    localparam int LSIQ_MASK_LO  = LSIQ_SELF_BIT - 1;           // 位 [gi-1:0] —— 序号比自己低的
    localparam int LSIQ_MASK_HI  = ~((LSIQ_SELF_BIT << 1) - 1); // 位 [N-1:gi+1] —— 序号比自己高的
    localparam logic [LSIQ_ENTRY-1:0] LSIQ_SELF_ONE = LSIQ_SELF_BIT[LSIQ_ENTRY-1:0];

    //---- 建表优先级: create0 找序号最小的空项, create1 找序号最大的空项 ----
    // "序号最小" ⇒ 比自己小的那些项**全忙** (人家先占了, 才轮到我); 掩码外的不约束
    //   ⇒ 写成 &(vld | ~MASK)。原版 casez `8'b????_???0: 选0` 就是这个意思。
    //   ⚠️ 别写成 ~|(vld & MASK) —— 那是"比我小的全空", 会一次给好几项发 create
    //   (2026-10-16 在 AIQ 上踩过, 由 tb_aiq_equiv 第 4 拍抓到)。
    assign lsiq_entry_create0_in[gi] = ~lsiq_entry_vld[gi]
                                     & (&(lsiq_entry_vld[LSIQ_ENTRY-1:0]
                                           | ~LSIQ_MASK_LO[LSIQ_ENTRY-1:0]));
    assign lsiq_entry_create1_in[gi] = ~lsiq_entry_vld[gi]
                                     & (&(lsiq_entry_vld[LSIQ_ENTRY-1:0]
                                           | ~LSIQ_MASK_HI[LSIQ_ENTRY-1:0]));

    //---- 本项被建表时, 灌进去的年龄向量与指令数据 ----
    // 年龄向量按 create0_in 选 source (原版就这么选: create0_in[i] ? create0 : create1),
    // 再把自己那一位清 0 (自屏蔽约定; 原版的紧凑约定是显式把第 i 位切掉, 等价)。
    assign lsiq_entry_create_agevec[gi][LSIQ_ENTRY-1:0] =
             (lsiq_entry_create0_in[gi] ? lsiq_entry_create0_agevec[LSIQ_ENTRY-1:0]
                                        : lsiq_entry_create1_agevec[LSIQ_ENTRY-1:0])
           & ~LSIQ_SELF_ONE[LSIQ_ENTRY-1:0];
    assign lsiq_entry_create_agevec_all[gi][LSIQ_ENTRY-1:0] =
             (lsiq_entry_create0_in[gi] ? lsiq_entry_create0_agevec_all[LSIQ_ENTRY-1:0]
                                        : lsiq_entry_create1_agevec_all[LSIQ_ENTRY-1:0])
           & ~LSIQ_SELF_ONE[LSIQ_ENTRY-1:0];
    assign lsiq_entry_create_data[gi][LSIQ_WIDTH-1:0] =
             lsiq_entry_create0_in[gi] ? dp_lsiq_create0_data[LSIQ_WIDTH-1:0]
                                       : dp_lsiq_create1_data[LSIQ_WIDTH-1:0];

    //---- pop / full_set / other_raw_rdy: 原来写死的 8 份拼接, 换成掩码 ----
    // 原版 `{entry_i_pop_other[i-1:0], pop_cur, entry_i_pop_other[N-2:i]} = pop_entry`
    // 等价于 "pop_entry 去掉第 i 位" ⇒ 自屏蔽约定下就是 `& ~SELF_ONE`。
    assign lsiq_entry_pop_cur_entry[gi]            = lsu_idu_lsiq_pop_entry[gi];
    assign lsiq_entry_pop_other_entry[gi][LSIQ_ENTRY-1:0] =
             lsu_idu_lsiq_pop_entry[LSIQ_ENTRY-1:0] & ~LSIQ_SELF_ONE[LSIQ_ENTRY-1:0];
    assign lsiq_entry_other_raw_rdy[gi][LSIQ_ENTRY-1:0] =
             lsiq_entry_raw_rdy[LSIQ_ENTRY-1:0] & ~LSIQ_SELF_ONE[LSIQ_ENTRY-1:0];

    assign lsiq_entry_lq_full_set[gi]     = lsu_idu_lq_full[gi];
    assign lsiq_entry_sq_full_set[gi]     = lsu_idu_sq_full[gi];
    assign lsiq_entry_rb_full_set[gi]     = lsu_idu_rb_full[gi];
    // 2026-10-19 停用: 非对齐第二半置位 (lsu_idu_secd 不再接收)
    //assign lsiq_entry_unalign_2nd_set[gi] = lsu_idu_secd[gi];

    //==========================================================
    //             LSU Issue Queue Entry Instance
    //==========================================================
    ct_idu_is_lsiq_entry #(.LSIQ_ENTRY(LSIQ_ENTRY)) u_ct_idu_is_lsiq_entry (
      .cpurst_b                         (cpurst_b                         ),
      .forever_cpuclk                   (forever_cpuclk                   ),
      .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
      .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),
      .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
      .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),
      .iu_idu_ex2_pipe2_wb_preg_dupx    (iu_idu_ex2_pipe2_wb_preg_dupx    ),
      .iu_idu_ex2_pipe2_wb_preg_vld_dupx(iu_idu_ex2_pipe2_wb_preg_vld_dupx),
      .lsu_idu_lq_not_full              (lsu_idu_lq_not_full              ),
      .lsu_idu_lsiq_pop_vld             (lsu_idu_lsiq_pop_vld             ),
      .lsu_idu_rb_not_full              (lsu_idu_rb_not_full              ),
      .lsu_idu_sq_not_full              (lsu_idu_sq_not_full              ),
      .lsu_idu_imme_wakeup              (lsu_idu_imme_wakeup[gi]          ),
      .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
      .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),
      .rtu_yy_xx_flush                  (rtu_yy_xx_flush                  ),
      .x_create_agevec                  (lsiq_entry_create_agevec[gi]     ),
      .x_create_agevec_all              (lsiq_entry_create_agevec_all[gi] ),
      .x_create_data                    (lsiq_entry_create_data[gi]       ),
      .x_create_en                      (lsiq_entry_create_en[gi]         ),
      .x_issue_en                       (lsiq_entry_issue_en[gi]          ),
      .x_load                           (lsiq_entry_load[gi]              ),
      .x_lq_full_set                    (lsiq_entry_lq_full_set[gi]       ),
      .x_other_raw_rdy                  (lsiq_entry_other_raw_rdy[gi]     ),
      .x_pop_cur_entry                  (lsiq_entry_pop_cur_entry[gi]     ),
      .x_pop_other_entry                (lsiq_entry_pop_other_entry[gi]   ),
      .x_raw_rdy                        (lsiq_entry_raw_rdy[gi]           ),
      .x_rb_full_set                    (lsiq_entry_rb_full_set[gi]       ),
      .x_rdy                            (lsiq_entry_ready[gi]             ),
      .x_read_data                      (lsiq_entry_read_data[gi]         ),
      // 2026-10-19 停用: .unalign_2nd                    (unalign_2nd[gi]                  ),
      .x_sq_full_set                    (lsiq_entry_sq_full_set[gi]       ),
      .x_store                          (lsiq_entry_store[gi]             ),
      // 2026-10-19 停用: .x_unalign_2nd_set              (lsiq_entry_unalign_2nd_set[gi]   ),
      .x_vld                            (lsiq_entry_vld[gi]               ),
      .old                              (lsiq_entry_old[gi]               )
    );
end
endgenerate

endmodule
