`timescale 1ns / 1ps
`include "RTU_define.vh"

// ---------------------------------------------------------------------------
// RTU — 退休单元顶层 (doc/rtu_plan_zh.md §5 / §6)
//
// 对外端口 = §6 契约的**逐字实现**, 一条不多一条不少。任何改动都要先改 §6。
//   §6.0 物理寄存器分配握手 (门房语义: 提前备号 / 当拍取走 / 取走即补)
//   §6.1 输入   §6.2 输出
//   §6.3 时序与边角约定 (冲刷时间线 / disp_stall 只依赖寄存器 / CSR 完成时机)
//   ⚠️ 2026-10-07: §6.0 由"两拍语义"改成 C910 的门房语义, 目的是断开与 IDU
//      停顿链之间的组合环 —— 见 doc/rtu_preg_alloc_plan_zh.md。
//
// 📌 **每个端口都有注释, 而且注释里顺带标了它属于哪条契约条目**
//    (A1 读口 / A6b 的 ena 口径 / A6c 的 funct3 原样 / A6d 的 dst_lreg 给 0 /
//     A7 一拍一条 CSR / A8 完成不早于解析 / D13 的重定向分家) ——
//    接线的人**只看这个文件就能接对**, 不必先读完 doc/rtu_plan_zh.md 的 2000 行。
//    所以改端口时注释要跟着改, 别让它变成假的。
//
// 端口风格: 扁平编号 (xxx0/xxx1/xxx2 = 程序序, 0 最老), 与前端 idu_inst0/1/2_*
// 同风格 —— 本仓与蓝本 C910 都没有 SV unpacked array 端口的先例, 而 Fmax 验收
// 要在 Vivado 上过, 不该拿新语法当第一次综合实验 (§6 的 A4)。
//
// 内部结构:
//   RTU_ROB       表项阵列 + 独热创造指针 + read_entry 影子窗口 (D5) + 完成/解析匹配
//   RTU_commit    判退级联 + 中断掩码 + 提交点副作用 (P1 链的后半段)
//   RTU_preg      四态表 + 门房(tap)保持寄存器 + 96 位三端口优先编码 + AMT
//   RTU_csr_slot  CSR 单槽 + 在途门控 (§4.3 的省资源项)
//   RTU_expt      异常收集, 最旧者胜 (D9)
//   RTU_flush     冲刷状态机 + 重定向分发 (D11)
//   RTU_iid_cmp   iid 年龄比较 (**只给异常收集用**, 不许接进重定向链, D12)
// ---------------------------------------------------------------------------
module RTU (
    input  wire        cpu_clk,             // 时钟
    input  wire        cpu_rst,             // 复位, 高有效

    // ===================== §6.0 物理寄存器分配握手 (门房语义, 2026-10-07) =========
    // 自由池与 96 位优先编码器都在 RTU 侧, 所以是"你要、我给"。车道语义**写死**:
    // `ren_preg_req = n` 表示**车道 0..n-1 是本次的请求者**, 车道 n..2 是 don't-care。
    //
    // 时序 = **C910 的"门房备号"** (`ct_rtu_pst_preg.v:7376-7393`):
    //   * `rtu_preg_alloc*` / `_vld*` 都是**寄存器** —— 池子提前把一个号备在门口;
    //   * 你**当拍取走**: 请求那一拍就把号用进 RAT / 随指令下发, RTU 在同一个边沿
    //     给这一路补下一个号;
    //   * `_vld* == 0` 表示这一路**这拍没有号可给** —— 你应当停住, 别用那个编号;
    //   * 号在"备进门口"那一刻就出了自由池(WF_ALLOC), 派遣回来认领时才转 ALLOC,
    //     **认领与取走相隔几拍不限**。
    // ⇒ 与旧版(两拍: T 要 / T+1 用)的差别就是"号提前备好"。
    //   旧写法让 `_vld*` 成了本拍请求的组合函数, 而消费者(IDU)拿它当同拍许可并
    //   反馈进自己的停顿链 ⇒ 组合环。改成寄存器后环消失。
    //   ⚠️ 消费者必须守一条契约: **请求 ⟺ 取走**。请求了却不派遣也不冲刷,
    //      那个号会永久停在 WF_ALLOC (年龄回收已删)。C910 IDU 天然满足
    //      (请求、RAT 写、进 IS 由同一个 `!ctrl_ir_stall` 门控)。
    input  wire [1:0]  ren_preg_req,        // 本拍要几个新 preg (0..3)
    input  wire [4:0]  ren_preg_req_lreg0,  // 请求 0 的 dst 逻辑寄存器 (判 x0 用)
    input  wire [4:0]  ren_preg_req_lreg1,  // 请求 1 的 —— lreg==0 的那一路不给编号
    input  wire [4:0]  ren_preg_req_lreg2,  // 请求 2 的
    output wire [6:0]  rtu_preg_alloc0,     // 车道 0 门口备着的号 (寄存器)
    output wire [6:0]  rtu_preg_alloc1,     // 车道 1 门口备着的
    output wire [6:0]  rtu_preg_alloc2,     // 车道 2 门口备着的
    output wire        rtu_preg_alloc_vld0, // 车道 0 门口**备到了** (池子空 -> 0, 此时别用那个号)
    output wire        rtu_preg_alloc_vld1, // 车道 1 同上
    output wire        rtu_preg_alloc_vld2, // 车道 2 同上
    output wire [1:0]  rtu_preg_free_cnt,   // 剩余可用数, 饱和到 3 (3 == ">= 3")
    //   ⚠️ 比"还能发出去多少"少 ≤3 —— 门口备着的那几个不在 FREE 里 (见 RTU_preg 末尾长注)

    // ===================== §6.1 派遣 (k = 0/1/2 = 程序序, 0 最老) =====================
    //
    // 硬约定 (完整版见 doc/rtu_plan_zh.md §6.1):
    //   * 一拍最多 3 条, 且必须是**程序序的前缀** —— 允许少于 3 条, 不允许跳号;
    //   * 派遣必须等 `rtu_disp_stall == 0`;
    //   * **A6d**: `rf_we == 0` 时 `_dst_lreg` **必须给 0**。给非 0 的垃圾 rd
    //     (store 的那几位本来是立即数), RTU 会按"要写 rd"去分配编号, 而退休时
    //     `wr_eff` 又不成立 ⇒ 那个编号既不转 ARCH 也不释放, **静默泄漏**;
    //   * **A6b**: `_rf_we` 必须与写回级的 `wb_rf_we` 同源 —— difftest 连 `ena`
    //     本身都比, `addi x0,...` 的 `rf_we=1` 与 `rd=x0` 是两件事;
    //   * **A6c**: `_csr_op` 要 **funct3 原样** (001/010/011 = RW/RS/RC,
    //     101/110/111 = RWI/RSI/RCI)。喂 `Control.v` 译出来的两位码会让
    //     `csrrwi` 被当成寄存器形式, 拿 rs1 的垃圾值当源;
    //   * **A7**: **一拍最多一条 CSR**。CSR 的 addr/op/imm/src1 抽成了**单槽**,
    //     装不下第二条 —— 这条**只能由重命名级/IDU 保证** (组内出现第二条时
    //     把它连同后面的指令截到下一拍), RTU 这侧挡不住;
    //   * `_flags` 的位序见 RTU_define.vh 的 `RTU_FLG_*`。
    //
    // 下面三组 (0/1/2) 的 12 个字段**逐字同义**, 只是车道号不同。
    input  wire        disp0_vld,           // 车道 0 (最老) 有一条真指令且这一拍离开 ID
    input  wire [31:0] disp0_pc,            // 它的 PC
    input  wire [24:0] disp0_chk,           // 前端预测快照 (取指时打包, 随指令走 → 进表项)
    input  wire [4:0]  disp0_dst_lreg,      // 目标逻辑寄存器 (不写寄存器时给 0, 见 A6d)
    input  wire        disp0_rf_we,         // 真的要写 rd (= difftest 的 ena)
    input  wire [6:0]  disp0_dst_preg,      // 分到的新物理号 ← §6.0 的 rtu_preg_alloc0
    input  wire [6:0]  disp0_old_preg,      // 被它替换掉的映射 ← 重命名级的 RAT
    input  wire [6:0]  disp0_src1_preg,     // rs1 的物理号 (**只有 CSR 指令有意义**)
    input  wire [11:0] disp0_csr_addr,      // CSR 地址 (**只有 CSR 指令有意义**)
    input  wire [2:0]  disp0_csr_op,        // CSR funct3 原样 (A6c)
    input  wire [4:0]  disp0_csr_imm,       // csrrwi 系列的 uimm5 (csr_op[2]=1 时有效)
    input  wire [6:0]  disp0_flags,         // {is_jalr, is_jal, is_mret, is_csr, intmask, is_store, is_branch}
    input  wire [2:0]  disp0_sq_id,         // 存储队列槽号 (LSU 在派遣时分配, RTU 只存不解释)

    input  wire        disp1_vld,           // 车道 1 (居中) 有一条真指令
    input  wire [31:0] disp1_pc,            // 车道 1 的 PC
    input  wire [24:0] disp1_chk,           // 车道 1 的前端快照
    input  wire [4:0]  disp1_dst_lreg,      // 车道 1 的目标逻辑寄存器 (不写时给 0)
    input  wire        disp1_rf_we,         // 车道 1 真的要写 rd
    input  wire [6:0]  disp1_dst_preg,      // 车道 1 的新物理号 ← rtu_preg_alloc1
    input  wire [6:0]  disp1_old_preg,      // 车道 1 替换掉的映射
    input  wire [6:0]  disp1_src1_preg,     // 车道 1 的 rs1 物理号 (只有 CSR 有意义)
    input  wire [11:0] disp1_csr_addr,      // 车道 1 的 CSR 地址
    input  wire [2:0]  disp1_csr_op,        // 车道 1 的 CSR funct3 原样
    input  wire [4:0]  disp1_csr_imm,       // 车道 1 的 uimm5
    input  wire [6:0]  disp1_flags,         // 车道 1 的 flags (位序同车道 0)
    input  wire [2:0]  disp1_sq_id,         // 车道 1 的存储队列槽号

    input  wire        disp2_vld,           // 车道 2 (最年轻) 有一条真指令
    input  wire [31:0] disp2_pc,            // 车道 2 的 PC
    input  wire [24:0] disp2_chk,           // 车道 2 的前端快照
    input  wire [4:0]  disp2_dst_lreg,      // 车道 2 的目标逻辑寄存器 (不写时给 0)
    input  wire        disp2_rf_we,         // 车道 2 真的要写 rd
    input  wire [6:0]  disp2_dst_preg,      // 车道 2 的新物理号 ← rtu_preg_alloc2
    input  wire [6:0]  disp2_old_preg,      // 车道 2 替换掉的映射
    input  wire [6:0]  disp2_src1_preg,     // 车道 2 的 rs1 物理号 (只有 CSR 有意义)
    input  wire [11:0] disp2_csr_addr,      // 车道 2 的 CSR 地址
    input  wire [2:0]  disp2_csr_op,        // 车道 2 的 CSR funct3 原样
    input  wire [4:0]  disp2_csr_imm,       // 车道 2 的 uimm5
    input  wire [6:0]  disp2_flags,         // 车道 2 的 flags (位序同车道 0)
    input  wire [2:0]  disp2_sq_id,         // 车道 2 的存储队列槽号

    // ===================== §6.1 完成 (p = 0..6, 来自各执行单元) =====================
    // D1.3 (2026-10-02): 5 -> 7 路。口 5/6 分给 LSU 读/写 —— 顺序核里 load 与 store
    // 不会同拍完成, 但乱序下两者各有独立通道, 挤一个口会把完成速率钉在 1/拍。
    // **按 iid 寻址**: 表项里只存回绕位, iid 由派遣回执 (`rtu_disp_iid*`) 发给
    // 重命名级、随指令走到完成级再报回来 (§6.3 ⑪)。不要试图"从退休指针现推"。
    input  wire        cmplt_vld0,          // 完成口 0 有结果
    input  wire [6:0]  cmplt_iid0,          // 口 0 完成的是哪条 ({wrap, 6 位索引})
    input  wire        cmplt_vld1,          // 完成口 1 有结果
    input  wire [6:0]  cmplt_iid1,          // 口 1 的 iid
    input  wire        cmplt_vld2,          // 完成口 2 有结果
    input  wire [6:0]  cmplt_iid2,          // 口 2 的 iid
    input  wire        cmplt_vld3,          // 完成口 3 有结果
    input  wire [6:0]  cmplt_iid3,          // 口 3 的 iid
    input  wire        cmplt_vld4,          // 完成口 4 有结果
    input  wire [6:0]  cmplt_iid4,          // 口 4 的 iid
    // ---- D1.3 (2026-10-02): 5 路 -> 7 路, LSU 读/写分开 ----
    input  wire        cmplt_vld5,          // 完成口 5: LSU 读 (load)
    input  wire [6:0]  cmplt_iid5,
    input  wire        cmplt_vld6,          // 完成口 6: LSU 写 (store)
    input  wire [6:0]  cmplt_iid6,

    // ===================== §6.1 解析结果 (BEU) =====================
    // 控制转移在 EX 解析出结果时写回表项。**A8**: 分支的"完成"不能早于它的
    // "解析" (同拍或 resolve 更早) —— 否则它会在两拍之间走到队头、按"没误预测"
    // 正常退休, 这次重定向就**永久丢掉**了。
    // ⚠️ **解析口 = 分支执行单元数, 不是发射宽度** (2026-10-02: D1.4 曾按发射宽度
    //    做成 3 路, 同一天收回 1 路 —— 本核 1 个 BEU, 一拍最多一条进 EX)。
    //    要加路数时按"将来有几个分支单元"定, 并同步 `RTU_RESOLVE_PORTS`。
    input  wire        resolve_vld,         // 本拍有一条控制转移解析出结果
    input  wire [6:0]  resolve_iid,         // 是哪条 (按 iid 寻址)
    input  wire        resolve_taken,       // 实际方向; JAL/JALR 恒 1
    input  wire        resolve_mispred,     // 预测错了 (退休时触发冲刷)
    input  wire [31:0] resolve_target,      // 真实后继 PC (退休点重训练要用)

    // ===================== §6.1 异常 (ID/EX/MEM 的检出点, 老级优先) =====================
    // 只有一路收集口 (D9): 级间天然是"老级优先" (MEM > EX > ID), 被丢掉的年轻异常
    // 不会丢信息 —— 它随流水逐级锁存, 下一拍还会从下一级报到。RTU 侧只留最旧的一条。
    // `mtval` 由**检出级**装好送进来 (非法指令给指令字 / 访存故障给地址 / 取指故障给 PC),
    // RTU 不再重算。
    // ===================== §6.1 LSU store 重放请求 — 2026-10-08 新增 =============
    // 对应 LSU 的 `lsu_rtu_wb_pipe4_flush` / `lsu_rtu_wb_pipe4_spec_fail`
    // (C910 里是**跟完成一起**报的两根, 见 `ct_lsu_st_wb.v:334-335`:
    //  `spec_fail` = store 的投机写失败 —— 后来的 load 读到了旧数据之类)。
    // 语义: "iid 这条 store 的投机结果是错的 ⇒ 它**要重放**"。
    // RTU 的处理: 在它的表项上置 `RTU_E_REPLAY` ⇒ 它**不能退休**(store 不许落内存),
    // 等它走到退休窗口最前面时触发一次 `RTU_FS_REPLAY` 冲刷: 冲掉它和更年轻的,
    // **从它自己的 PC 重取** (与误预测的区别: 这条要重启前端)。
    // ⚠️ 两根 LSU 信号在适配层**或**起来再送进来 (对我们这条简化路径是同一个动作);
    //    将来若要区分(比如 flush 带异常向量), 再拆成两个口。
    // ⚠️ 与完成口一样**按 iid 寻址**, 必须带着回绕位。
    input  wire        lsu_replay_vld,
    input  wire [6:0]  lsu_replay_iid,

    input  wire        expt_vld,            // 本拍有一级检出异常
    input  wire [6:0]  expt_iid,            // 是哪条 (按 iid 寻址, 用来判最旧)
    input  wire [4:0]  expt_cause,          // 异常号 (**不含** mcause 的中断位, 见 §6.3 ⑫)
    input  wire [31:0] expt_tval,           // mtval, 由检出级装好

    // ===================== §6.1 存储队列 / CSR / 中断 =====================
    input  wire        sq_rdy0,             // 退休槽 0 的 store **数据已就绪** ⇒ 才允许它退休
    input  wire        sq_rdy1,             // 退休槽 1 的 store 数据就绪
    input  wire        sq_rdy2,             // 退休槽 2 的 store 数据就绪
    input  wire        sq_stall,            // 队列满/下游忙 -> **压退休宽度** (与中断共用 commit_mask)
    input  wire [31:0] csr_rdata,           // CSR 组合读出的旧值 (地址见 rtu_csr_addr)
    input  wire        int_pending,         // 有中断待取 (**已按 mstatus/mie/mip 屏蔽过**)

    // ===================== BEU -> RTU (D13) =====================
    // EX 级**真的发出**误预测重定向的那一拍 (mycpu.v 里就是 iu_ifu_chgflw_vld)。
    // 只用于置"未决快路重定向"锁存位 —— 把派遣冻结的窗口从"执行级重定向那拍"
    // 拉起来, 直到 F2; 并且它是"误预测不再重启前端"(D13 ②)的依据。
    // ⚠️ 必须**锁存** (不能直接组合进 disp_stall): P8 要求 disp_stall 只依赖寄存器。
    input  wire        beu_redirect_vld,    // 本拍 EX 发出了误预测重定向

    // ===================== §6.1 物理寄存器堆读口 (A1) =====================
    // 退休级要按**物理号**取数: difftest 要比对提交值, CSR 指令要读 rs1 的源操作数。
    // 地址由本模块的 `rtu_preg_raddr*` / `rtu_csr_src_raddr` 给出。
    input  wire [31:0] preg_rdata0,         // ← PRF[rtu_preg_raddr0] (退休槽 0 的结果)
    input  wire [31:0] preg_rdata1,         // ← PRF[rtu_preg_raddr1]
    input  wire [31:0] preg_rdata2,         // ← PRF[rtu_preg_raddr2]
    input  wire [31:0] rtu_csr_src_rdata,   // ← PRF[rtu_csr_src_raddr] (在途 CSR 的 rs1)

    // ===================== §6.1 重定向目标的来源 (A6) =====================
    input  wire [31:0] csr_trap_vector,     // 陷阱/中断的目标 (mtvec + cause<<2, 已解算)
    input  wire [31:0] csr_mepc,            // mret 的目标

    // ===================== §6.2 前端: 陷阱/中断/mret 的重定向 =====================
    // ⚠️ **误预测不走这三根** (D13): 前端在 EX 那拍就被 BEU 直接送到真实目标了,
    // 退休时再重启一次就是"重取两次"。误预测的"核内冲刷"由 rtu_core_redirect 出。
    output wire        rtu_ifu_flush,       // 重启前端 (与下面那根同拍同值)
    output wire        rtu_ifu_chgflw_vld,  // 前端重定向有效
    output wire [31:0] rtu_ifu_chgflw_pc,   // 目标二选一: 陷阱/中断→trap_vector, mret→mepc
    // ---- 退休点重训练 (阶段 4b, 2026-10-02 接上) ----
    // 数据源 = ROB 表项里的 `pc / target / chk / actual_taken`, **不是** EX 当拍那份。
    // 为什么搬: 乱序下分支是乱序完成/解析的, EX 级训练会把 GHR 按乱序顺序推。
    //   * `_taken` 对条件分支是实际方向, 对 JAL/JALR 恒 1;
    //   * `_is_cond/_is_jal/_is_jalr` 三分类**互斥** (条件分支 = is_branch & ~jal & ~jalr),
    //     BTB 靠它决定写哪一类 —— 原来由 EX 的 npc_op 现算。
    // ⚠️ 只有**一路**训练口 (取退休窗口里最老的那条控制转移)。1 发射下窗口里最多
    //    一条分支, 恒等价; 3 发射落地时同一窗口可能有 2 条以上 —— 见 RTU_commit
    //    末尾的说明。
    output wire        rtu_ifu_train_vld,   // 本拍有一条控制转移退休, 值得训练
    output wire [31:0] rtu_ifu_train_pc,    // 它的 PC
    output wire [31:0] rtu_ifu_train_target,// 真实后继 PC (= 表项 TARGET, BTB 的 upd_target)
    output wire [24:0] rtu_ifu_train_chk,   // 表项里那份 chk (BHT 取 GHR / TAGE 取 fpred)
    output wire        rtu_ifu_train_taken, // 实际方向 (条件分支才看它)
    output wire        rtu_ifu_train_is_cond,// 是条件分支 (方向表**只**认这一类)
    output wire        rtu_ifu_train_is_jal, // 是 JAL
    output wire        rtu_ifu_train_is_jalr,// 是 JALR

    // ===================== §6.2 后端冲刷 (D11 的 FLUSH_1) =====================
    // 单拍脉冲 (T+1): 冲发射队列/执行级/存储队列。**误预测也要拉** ——
    // 后端 (ID_EX 往后) 与 IDU 里那些更年轻的指令必须冲掉, 别因为"D13 不重启前端"
    // 就把它一起删了。
    output wire        rtu_backend_flush,   // 单拍脉冲 (T+1), 四类冲刷都拉

    // ===================== §6.2 核内重定向事件 (D13 新增) =====================
    // "本拍 RTU 在重定向", 四类源**都算**(含误预测)。mycpu.v 用它驱动 `redirect`
    // (冲 IF_ID/ID_EX/EX_MEM、按掉 store 写使能、CSR 静默、训练门控)。
    // ⚠️ 与 rtu_ifu_flush **必须在顶层分开接**: D13 之后两者对误预测取值不同。
    //    合成一根的症状是"错误路径的 store 写进内存", 不是慢。
    output wire        rtu_core_redirect,   // = 退休拍的 flush_trig (T 拍, 单拍)

    // ===================== §6.2 提交窗口广播 (给 LSU) — 2026-10-08 新增 ==========
    // **照 C910 `ct_rtu_rob_rt.v:2723-2731` 逐字对齐**: 那里的 LSU 拿这组信号跟自己的
    // LQ/SQ/MSHR 表项里的 iid 比对, 决定"这条访存现在可以真正生效了"(lsu_lq_entry.sv:104)。
    //   * `commit{k}` = **真的提交了** (trap 那条不算: 它没写回、它的 store 不能落内存);
    //   * `commit{k}_iid` = 同一次提交的 iid;
    //   * 两者都是**寄存器** (C910 就是), 且是**同一次窗口**的一对 —— 所以消费方
    //     必须在同一个边沿成对采样 (iid 寄存器是无条件锁存的, 单独看它没有意义)。
    //   ⚠️ 与 `rtu_retire_cnt` 的区别: 后者给 difftest 数条数 (trap 那条**要**计),
    //      这里给 LSU 判"能不能落内存" (trap 那条**不能**发)。
    output wire        rtu_yy_xx_commit0,   // 槽 0 本拍真的提交了
    output wire        rtu_yy_xx_commit1,   // 槽 1 (0 和 1 都提交了才有它)
    output wire        rtu_yy_xx_commit2,
    output wire [6:0]  rtu_yy_xx_commit0_iid,  // 槽 0 的 iid (与上面那根成对)
    output wire [6:0]  rtu_yy_xx_commit1_iid,
    output wire [6:0]  rtu_yy_xx_commit2_iid,

    // ===================== §6.2 异步冲刷 (给 LSU) — 2026-10-08 新增 ==============
    // C910 里这根是**调试请求**的异步冲刷 (`ct_rtu_retire.v:2005/2016`:
    // `async_flush = dbgreq_ack_jdbreq` ⇒ 打一拍给 LSU/WMB), 与指令流的冲刷无关。
    // 本核**没有 debug 模块** ⇒ 恒 0; 将来接 debug 时把它的请求接到这里即可
    // (LSU 侧拿它清 WMB/SQ: `lsu_sq.sv:527`、`lsu_wmb_ce.sv:62`)。
    output wire        rtu_lsu_async_flush, // 恒 0 (占位, 见上)

    // ===================== §6.2 BEU: D1 的最旧门控 + 冲刷屏蔽 =====================
    output wire [6:0]  rtu_beu_retire_iid,  // ROB 的 pop iid —— ⚠️ **不再是门控用的**
                                            //   (D12 改口径后比的是"上一次已发出的重定向的
                                            //    iid", 那是 BEU 侧自己的寄存器)。
                                            //   留着只当 debug 观察口, 别为它设计逻辑。
    output wire        rtu_beu_flush_chgflw_mask, // 慢路冲刷期间屏蔽 BEU 再发重定向
                                            //   (从 T 拍起、T+1 结束; 漏了会让两次
                                            //    重定向打架)

    // ===================== §6.2 重命名级 =====================
    // 分工: 重命名级维护**投机 RAT**; RTU 维护**架构映射表 AMT**。RTU 不碰你的 RAT,
    // 只在该覆盖时给你一份完整映射。
    output wire        rtu_disp_stall,      // 停派遣: ROB 满 / preg 不足 / CSR 在途 /
                                            //   冲刷窗口 / 未决快路重定向
                                            //   ⚠️ 只依赖寄存器 (P8); 消费时必须
                                            //   "停前端 + 给 EX 灌气泡"成对拉
    output wire        rtu_ren_recover_vld, // 恢复映射有效 (与 _map 同拍)
    output wire [223:0] rtu_ren_recover_map,// 32 × 7bit AMT, `[7*l +: 7]` = x_l 的映射
                                            //   只反映**已退休**的映射 (D1/D2)
    output wire        rtu_ren_flush,       // 重命名级自身清空 (T+1 拍, 与下面 recover 同拍)
    output wire [6:0]  rtu_ren_free_preg0,  // 退休槽 0 释放掉的物理号 (**观察口**:
    output wire [6:0]  rtu_ren_free_preg1,  //   自由池在 RTU 侧, 不需要重命名级回收)
    output wire [6:0]  rtu_ren_free_preg2,  // 退休槽 2 释放掉的物理号
    output wire        rtu_ren_free_vld0,   // 槽 0 真的释放了一个 (>= 32 才放)
    output wire        rtu_ren_free_vld1,   // 槽 1 同上
    output wire        rtu_ren_free_vld2,   // 槽 2 同上
    // ---- 派遣回执: 本拍**真进了 ROB** 的车道拿到的 iid ----
    // 你**必须**把它随指令带进流水线: `cmplt_iid` / `resolve_iid` 是按 iid 寻址的,
    // 而 RTU 表项里只存回绕位 —— 编号只有分配者知道 (§6.3 ⑪)。
    output wire        rtu_disp_vld0,       // 车道 0 真的进了 ROB (已扣掉冲刷窗口)
    output wire        rtu_disp_vld1,       // 车道 1 同上
    output wire        rtu_disp_vld2,       // 车道 2 同上
    output wire [6:0]  rtu_disp_iid0,       // 车道 0 的 iid = {wrap, 6 位索引}
    output wire [6:0]  rtu_disp_iid1,       // 车道 1 的 iid
    output wire [6:0]  rtu_disp_iid2,       // 车道 2 的 iid

    // ===================== §6.2 物理寄存器堆访问 (A1) =====================
    output wire [6:0]  rtu_preg_raddr0,     // 退休槽 0 的 dst_preg (difftest 按它取值)
    output wire [6:0]  rtu_preg_raddr1,     // 退休槽 1 的 dst_preg
    output wire [6:0]  rtu_preg_raddr2,     // 退休槽 2 的 dst_preg
    output wire [6:0]  rtu_csr_src_raddr,   // 在途 CSR 指令的 src1_preg (读 rs1 用)
    output wire        rtu_csr_rd_we,       // CSR 的 rd 结果**退休当拍**才产生, 这时才写
    output wire [6:0]  rtu_csr_rd_addr,     // 写哪个物理号 (= 该 CSR 指令的 dst_preg)
    output wire [31:0] rtu_csr_rd_wdata,    // 写什么 (= CSR 旧值, 三种 op 都一样)

    // ===================== §6.2 提交点副作用 =====================
    output wire        rtu_store_vld0,      // 退休槽 0 是一条**要提交**的 store
    output wire        rtu_store_vld1,      // 退休槽 1 是要提交的 store
    output wire        rtu_store_vld2,      // 退休槽 2 是要提交的 store
    output wire [2:0]  rtu_store_sq_id0,    // 槽 0 的队列号 (取自表项里的 disp0_sq_id)
    output wire [2:0]  rtu_store_sq_id1,    // 槽 1 的队列号
    output wire [2:0]  rtu_store_sq_id2,    // 槽 2 的队列号
    output wire        rtu_csr_we,          // CSR 写使能 (已按 op 与 rs1!=x0 判过)
    output wire [11:0] rtu_csr_addr,        // 一个口两种用: 组合读地址 + 写地址
    output wire [31:0] rtu_csr_wdata,       // CSR 新值 (退休级现算, 见 §6.3 ⑩)
    output wire        rtu_trap_vld,        // 同步异常或中断 (两者都写 mepc/mcause/mtval)
    output wire        rtu_mret_vld,        // 本拍退休的是一条 mret
    output wire [31:0] rtu_trap_epc,        // 写入 mepc 的值 (= 队头那条的 PC)
    output wire [31:0] rtu_trap_tval,       // 写入 mtval 的值 (中断时为 0)
    output wire [4:0]  rtu_trap_cause,      // 写入 mcause 的异常号 (**5 位, 中断位由消费方补**)
    output wire [1:0]  rtu_retire_cnt,      // 本拍退休条数 0..3 (被中断 squash 的那条不计)

    // ===================== §6.2 difftest / debug =====================
    // 交付脉冲口径 (§6.3 ⑥, **不许改**, 改了 difftest 立刻失步):
    //   同步异常那条**发**脉冲 (ena 强 0); 被中断 squash 的那条**不发** (也不计 cnt);
    //   mret 正常发。消费方还要把 `have_inst` 或上 `rtu_trap_vld` (见 §7 的 C3)。
    output wire        dbg_commit_vld0,     // 退休槽 0 要交付给 difftest
    output wire        dbg_commit_vld1,     // 退休槽 1 要交付
    output wire        dbg_commit_vld2,     // 退休槽 2 要交付
    output wire [31:0] dbg_commit_pc0,      // 槽 0 的 PC (逐条比对, 错一位就炸)
    output wire [31:0] dbg_commit_pc1,      // 槽 1 的 PC
    output wire [31:0] dbg_commit_pc2,      // 槽 2 的 PC
    output wire        dbg_commit_ena0,      // 槽 0 是否真的写 rd (陷阱那条: vld=1 但 ena=0)
    output wire        dbg_commit_ena1,      // 槽 1 同上
    output wire        dbg_commit_ena2,      // 槽 2 同上
    output wire [4:0]  dbg_commit_reg0,      // 槽 0 写的逻辑寄存器号
    output wire [4:0]  dbg_commit_reg1,      // 槽 1 的
    output wire [4:0]  dbg_commit_reg2,      // 槽 2 的
    output wire [31:0] dbg_commit_value0,    // 槽 0 的结果 (摘自 preg_rdata0; CSR 那条换成旧值)
    output wire [31:0] dbg_commit_value1,    // 槽 1 的结果
    output wire [31:0] dbg_commit_value2     // 槽 2 的结果
);

    // =======================================================================
    // 路数自检 (D1.3/D1.4): 宏与端口表必须同改。
    // ⚠️ 扁平端口表没法由宏生成 (A4), 而"改了宏没生效"正是 §9 R7 那类**静默错** ——
    //    这里的 generate 分支只在路数对不上时被 elaborate, 里面故意例化一个
    //    不存在的模块 ⇒ 编译期直接失败, 而不是"改了宏、跑起来没变化"。
    // =======================================================================
    generate
        if (`RTU_CMPLT_PORTS != 7) begin : g_cmplt_ports_mismatch
            RTU_CMPLT_PORTS_MUST_MATCH_RTU_define_vh u_err();
        end
        if (`RTU_RESOLVE_PORTS != 1) begin : g_resolve_ports_mismatch
            RTU_RESOLVE_PORTS_MUST_MATCH_RTU_define_vh u_err();
        end
    endgenerate

    // =======================================================================
    // 内部连线 —— **全部前置声明**。
    // ⚠️ 本仓有"先用后声明造 1 位隐式线网"的前科 (cpu/sim/rtl_patch/README.md,
    //    以及 §9 的 R7): 症状是语义静默错、只报 PCWM-W 警告, 不报错。
    //    所以这里一次性把跨模块的网线全列出来, 后面只赋值/连接, 不再插声明。
    // =======================================================================
    wire        flushing;                    // 冲刷窗口 (含 T 拍)
    wire        mispred_pend;                // D13: 有未决快路重定向 (T_ex+1 .. F2)
    wire        fsm_busy;
    wire        flush_lvl;                   // FLUSH_2 脉冲
    wire        expt_clr;                    // FLUSH_1: 清 expt_entry
    wire        flush_trig;
    wire [2:0]  flush_src;
    wire [31:0] flush_pc;
    wire        backend_flush;
    wire        ren_flush;
    wire        ren_recover_vld;
    wire [223:0] ren_recover_map;
    wire        beu_mask;
    wire [1:0]  pop_n;
    wire [2:0]  disp_acc;
    wire [2:0]  disp_wrap;
    wire [5:0]  cptr_idx;                    // 创造指针的二进制下标 (派遣回执)
    wire [2:0]  disp_vld_raw;
    wire [`RTU_E_W-1:0] disp_data0;
    wire [`RTU_E_W-1:0] disp_data1;
    wire [`RTU_E_W-1:0] disp_data2;
    wire [`RTU_E_W-1:0] win0, win1, win2;
    wire [6:0]  win_iid0, win_iid1, win_iid2;
    wire [6:0]  rob_occ;
    wire        rob_full;
    wire        expt_entry_vld;
    wire [6:0]  expt_entry_iid;
    wire [4:0]  expt_entry_cause;
    wire [31:0] expt_entry_tval;
    wire        csr_inflight;
    wire [6:0]  slot_src1_preg;
    wire [11:0] slot_csr_addr;
    wire [2:0]  slot_csr_op;
    wire [4:0]  slot_csr_imm;
    wire [2:0]  csr_slot_retire;
    wire [2:0]  commit_vld, write_vld;
    wire        trap_hit, int_take, mret_hit, mispred_hit, trap_or_int;
    wire [31:0] mispred_target;
    wire [31:0] trap_epc_d, trap_tval_d;
    wire [4:0]  trap_cause_d;
    wire [2:0]  ret_arch_vld, ret_kill_vld, ret_free_vld;
    wire [6:0]  ret_dst_preg0, ret_dst_preg1, ret_dst_preg2;
    wire [6:0]  ret_old_preg0, ret_old_preg1, ret_old_preg2;
    wire [4:0]  ret_dst_lreg0, ret_dst_lreg1, ret_dst_lreg2;
    wire [6:0]  free_cnt;
    wire [223:0] amt_flat;

    // =======================================================================
    // 派遣车道: 收口成程序序前缀 (§6 的硬约定 1; 允许少于 3 条, 不许跳号)
    // =======================================================================
    assign disp_acc[0] = disp0_vld & ~flushing;
    assign disp_acc[1] = disp_acc[0] & disp1_vld;
    assign disp_acc[2] = disp_acc[1] & disp2_vld;

    assign disp_vld_raw = {disp2_vld, disp1_vld, disp0_vld};

    // 表项拼装 (位序 = RTU_define.vh 里那张图, 一个字都不能错)
    // ⚠️⚠️ 字段顺序必须与 `RTU_define.vh` 的位域表**逐行对齐**, 而且必须**写满
    //    `RTU_E_W` 位**。少写一位不会报错 —— 会被静默零扩展, 于是每个字段整体错位
    //    一格: 2026-10-08 加 `replay` 位时就踩过 (sq_id 的最低位落进 bit0 = 新加的
    //    replay 位, 窗口里的"要重放"标志被随机置位, 一开跑就是误冲刷乱拉)。
    assign disp_data0 = { 1'b0,             // [124] replay (派遣时恒 0)
                          1'b1,             // vld
                          1'b0,             // cmplt
                          disp_wrap[0],     // wrap
                          disp0_pc,
                          32'd0,            // target (BEU 解析时写回)
                          disp0_chk,
                          disp0_dst_lreg,
                          disp0_dst_preg,
                          disp0_old_preg,
                          disp0_flags,
                          disp0_rf_we,
                          1'b0,             // actual_taken
                          1'b0,             // mispred
                          disp0_sq_id };
    assign disp_data1 = { 1'b0,          // [124] replay (派遣时恒 0)
                         1'b1, 1'b0, disp_wrap[1], disp1_pc, 32'd0, disp1_chk,
                          disp1_dst_lreg, disp1_dst_preg, disp1_old_preg, disp1_flags,
                          disp1_rf_we, 1'b0, 1'b0, disp1_sq_id };
    assign disp_data2 = { 1'b0,          // [124] replay (派遣时恒 0)
                         1'b1, 1'b0, disp_wrap[2], disp2_pc, 32'd0, disp2_chk,
                          disp2_dst_lreg, disp2_dst_preg, disp2_old_preg, disp2_flags,
                          disp2_rf_we, 1'b0, 1'b0, disp2_sq_id };

    // =======================================================================
    // ROB
    // =======================================================================
    RTU_ROB u_rob (
        .cpu_clk            (cpu_clk),
        .cpu_rst            (cpu_rst),
        .flushing           (flushing),
        .disp_vld           (disp_vld_raw),
        .disp_data0         (disp_data0),
        .disp_data1         (disp_data1),
        .disp_data2         (disp_data2),
        .cmplt_vld          ({cmplt_vld6, cmplt_vld5, cmplt_vld4, cmplt_vld3,
                              cmplt_vld2, cmplt_vld1, cmplt_vld0}),
        .cmplt_iid0         (cmplt_iid0),
        .cmplt_iid1         (cmplt_iid1),
        .cmplt_iid2         (cmplt_iid2),
        .cmplt_iid3         (cmplt_iid3),
        .cmplt_iid4         (cmplt_iid4),
        .cmplt_iid5         (cmplt_iid5),
        .cmplt_iid6         (cmplt_iid6),
        .lsu_replay_vld     (lsu_replay_vld),
        .lsu_replay_iid     (lsu_replay_iid),
        .resolve_vld        (resolve_vld),
        .resolve_iid        (resolve_iid),
        .resolve_taken      (resolve_taken),
        .resolve_mispred    (resolve_mispred),
        .resolve_target     (resolve_target),
        .pop_n              (pop_n),
        .flush_lvl          (flush_lvl),
        .rtu_beu_retire_iid (rtu_beu_retire_iid),
        .win_iid0           (win_iid0),
        .win_iid1           (win_iid1),
        .win_iid2           (win_iid2),
        .win_q0             (win0),
        .win_q1             (win1),
        .win_q2             (win2),
        .occ                (rob_occ),
        .rob_full           (rob_full),
        .disp_wrap          (disp_wrap),
        .cptr_idx           (cptr_idx)
    );

    // =======================================================================
    // 派遣回执: 本拍被接受的车道在 ROB 里的 iid (§6.2 / §6.3 ⑪)
    //   车道 k 的 iid = {wrap_k, cptr_idx + k} —— 与表项里存的 (wrap, 固定下标)
    //   是同一套算法 (disp_wrap 就是表项 WRAP 位的来源, 见上面的 disp_data*)。
    //   ⚠️ 编号是给**下一拍**随指令走的, 与 §6.0 的两拍语义无关 (那条是 preg)。
    // =======================================================================
    assign rtu_disp_vld0 = disp_acc[0];
    assign rtu_disp_vld1 = disp_acc[1];
    assign rtu_disp_vld2 = disp_acc[2];
    assign rtu_disp_iid0 = {disp_wrap[0], cptr_idx};
    assign rtu_disp_iid1 = {disp_wrap[1], cptr_idx + 6'd1};
    assign rtu_disp_iid2 = {disp_wrap[2], cptr_idx + 6'd2};

    // =======================================================================
    // 异常收集 (最旧者胜)
    // =======================================================================
    RTU_expt u_expt (
        .cpu_clk   (cpu_clk),
        .cpu_rst   (cpu_rst),
        .expt_vld  (expt_vld),
        .expt_iid  (expt_iid),
        .expt_cause(expt_cause),
        .expt_tval (expt_tval),
        .flush_clr (expt_clr),
        .entry_vld (expt_entry_vld),
        .entry_iid (expt_entry_iid),
        .entry_cause(expt_entry_cause),
        .entry_tval(expt_entry_tval)
    );

    // =======================================================================
    // CSR 单槽
    // =======================================================================
    RTU_csr_slot u_csr_slot (
        .cpu_clk        (cpu_clk),
        .cpu_rst        (cpu_rst),
        .disp_csr_vld   ({ disp_acc[2] & disp2_flags[`RTU_FLG_CSR],
                           disp_acc[1] & disp1_flags[`RTU_FLG_CSR],
                           disp_acc[0] & disp0_flags[`RTU_FLG_CSR] }),
        .disp_src1_preg0(disp0_src1_preg),
        .disp_src1_preg1(disp1_src1_preg),
        .disp_src1_preg2(disp2_src1_preg),
        .disp_csr_addr0 (disp0_csr_addr),
        .disp_csr_addr1 (disp1_csr_addr),
        .disp_csr_addr2 (disp2_csr_addr),
        .disp_csr_op0   (disp0_csr_op),
        .disp_csr_op1   (disp1_csr_op),
        .disp_csr_op2   (disp2_csr_op),
        .disp_csr_imm0  (disp0_csr_imm),
        .disp_csr_imm1  (disp1_csr_imm),
        .disp_csr_imm2  (disp2_csr_imm),
        .retire_clr     (|csr_slot_retire),
        .flush_clr      (flush_lvl),
        .csr_inflight   (csr_inflight),
        .slot_src1_preg (slot_src1_preg),
        .slot_csr_addr  (slot_csr_addr),
        .slot_csr_op    (slot_csr_op),
        .slot_csr_imm   (slot_csr_imm)
    );

    // =======================================================================
    // 判退 + 提交点副作用
    // =======================================================================
    RTU_commit u_commit (
        .cpu_clk        (cpu_clk),
        .cpu_rst        (cpu_rst),
        .win0           (win0),
        .win1           (win1),
        .win2           (win2),
        .lsu_replay_vld (lsu_replay_vld),
        .lsu_replay_iid (lsu_replay_iid),
        .win_iid0       (win_iid0),
        .win_iid1       (win_iid1),
        .win_iid2       (win_iid2),
        .fsm_busy       (fsm_busy),
        .expt_vld       (expt_entry_vld),
        .expt_iid       (expt_entry_iid),
        .expt_cause     (expt_entry_cause),
        .expt_tval      (expt_entry_tval),
        .sq_rdy0        (sq_rdy0),
        .sq_rdy1        (sq_rdy1),
        .sq_rdy2        (sq_rdy2),
        .sq_stall       (sq_stall),
        .int_pending    (int_pending),
        .slot_src1_preg (slot_src1_preg),
        .slot_csr_addr  (slot_csr_addr),
        .slot_csr_op    (slot_csr_op),
        .slot_csr_imm   (slot_csr_imm),
        .csr_rdata      (csr_rdata),
        .csr_src_rdata  (rtu_csr_src_rdata),
        .csr_trap_vector(csr_trap_vector),
        .csr_mepc       (csr_mepc),
        .preg_rdata0    (preg_rdata0),
        .preg_rdata1    (preg_rdata1),
        .preg_rdata2    (preg_rdata2),
        .pop_n          (pop_n),
        .commit_vld     (commit_vld),
        .write_vld      (write_vld),
        .trap_hit       (trap_hit),
        .int_take       (int_take),
        .mret_hit       (mret_hit),
        .mispred_hit    (mispred_hit),
        .mispred_target (mispred_target),
        .flush_trig     (flush_trig),
        .flush_src      (flush_src),
        .flush_pc       (flush_pc),
        .trap_epc       (trap_epc_d),
        .trap_cause     (trap_cause_d),
        .trap_tval      (trap_tval_d),
        .trap_or_int    (trap_or_int),
        .ret_arch_vld   (ret_arch_vld),
        .ret_kill_vld   (ret_kill_vld),
        .ret_free_vld   (ret_free_vld),
        .ret_dst_preg0  (ret_dst_preg0),
        .ret_dst_preg1  (ret_dst_preg1),
        .ret_dst_preg2  (ret_dst_preg2),
        .ret_old_preg0  (ret_old_preg0),
        .ret_old_preg1  (ret_old_preg1),
        .ret_old_preg2  (ret_old_preg2),
        .ret_dst_lreg0  (ret_dst_lreg0),
        .ret_dst_lreg1  (ret_dst_lreg1),
        .ret_dst_lreg2  (ret_dst_lreg2),
        .store_vld      ({rtu_store_vld2, rtu_store_vld1, rtu_store_vld0}),
        .store_sq_id0   (rtu_store_sq_id0),
        .store_sq_id1   (rtu_store_sq_id1),
        .store_sq_id2   (rtu_store_sq_id2),
        .csr_we         (rtu_csr_we),
        .csr_addr       (rtu_csr_addr),
        .csr_wdata      (rtu_csr_wdata),
        .csr_rd_we      (rtu_csr_rd_we),
        .csr_rd_addr    (rtu_csr_rd_addr),
        .csr_rd_wdata   (rtu_csr_rd_wdata),
        .csr_slot_retire(csr_slot_retire),
        .preg_raddr0    (rtu_preg_raddr0),
        .preg_raddr1    (rtu_preg_raddr1),
        .preg_raddr2    (rtu_preg_raddr2),
        .csr_src_raddr  (rtu_csr_src_raddr),
        .commit_ena     ({dbg_commit_ena2, dbg_commit_ena1, dbg_commit_ena0}),
        .commit_pc0     (dbg_commit_pc0),
        .commit_pc1     (dbg_commit_pc1),
        .commit_pc2     (dbg_commit_pc2),
        .commit_reg0    (dbg_commit_reg0),
        .commit_reg1    (dbg_commit_reg1),
        .commit_reg2    (dbg_commit_reg2),
        .commit_value0  (dbg_commit_value0),
        .commit_value1  (dbg_commit_value1),
        .commit_value2  (dbg_commit_value2),
        .train_vld      (rtu_ifu_train_vld),
        .train_pc       (rtu_ifu_train_pc),
        .train_target   (rtu_ifu_train_target),
        .train_chk      (rtu_ifu_train_chk),
        .train_taken    (rtu_ifu_train_taken),
        .train_is_cond  (rtu_ifu_train_is_cond),
        .train_is_jal   (rtu_ifu_train_is_jal),
        .train_is_jalr  (rtu_ifu_train_is_jalr)
    );

    assign dbg_commit_vld0 = commit_vld[0];
    assign dbg_commit_vld1 = commit_vld[1];
    assign dbg_commit_vld2 = commit_vld[2];

    // =======================================================================
    // 物理寄存器状态 (四态表 + AMT)
    // =======================================================================
    RTU_preg u_preg (
        .cpu_clk            (cpu_clk),
        .cpu_rst            (cpu_rst),
        .ren_preg_req       (ren_preg_req),
        .ren_preg_req_lreg0 (ren_preg_req_lreg0),
        .ren_preg_req_lreg1 (ren_preg_req_lreg1),
        .ren_preg_req_lreg2 (ren_preg_req_lreg2),
        .disp_vld           (disp_acc),
        .disp_dst_preg0     (disp0_dst_preg),
        .disp_dst_preg1     (disp1_dst_preg),
        .disp_dst_preg2     (disp2_dst_preg),
        .ret_arch_vld       (ret_arch_vld),
        .ret_kill_vld       (ret_kill_vld),
        .ret_free_vld       (ret_free_vld),
        .ret_dst_preg0      (ret_dst_preg0),
        .ret_dst_preg1      (ret_dst_preg1),
        .ret_dst_preg2      (ret_dst_preg2),
        .ret_old_preg0      (ret_old_preg0),
        .ret_old_preg1      (ret_old_preg1),
        .ret_old_preg2      (ret_old_preg2),
        .ret_dst_lreg0      (ret_dst_lreg0),
        .ret_dst_lreg1      (ret_dst_lreg1),
        .ret_dst_lreg2      (ret_dst_lreg2),
        .flush_lvl          (flush_lvl),
        .rtu_preg_alloc0    (rtu_preg_alloc0),
        .rtu_preg_alloc1    (rtu_preg_alloc1),
        .rtu_preg_alloc2    (rtu_preg_alloc2),
        .rtu_preg_alloc_vld0(rtu_preg_alloc_vld0),
        .rtu_preg_alloc_vld1(rtu_preg_alloc_vld1),
        .rtu_preg_alloc_vld2(rtu_preg_alloc_vld2),
        .free_cnt           (free_cnt),
        .rtu_preg_free_cnt  (rtu_preg_free_cnt),
        .amt_flat           (amt_flat)
    );

    // 释放的观察口 (§6.2): 自由池在 RTU 侧, 这三个口是给 debug/difftest 看的
    assign rtu_ren_free_vld0 = ret_free_vld[0];
    assign rtu_ren_free_vld1 = ret_free_vld[1];
    assign rtu_ren_free_vld2 = ret_free_vld[2];
    assign rtu_ren_free_preg0 = ret_old_preg0;
    assign rtu_ren_free_preg1 = ret_old_preg1;
    assign rtu_ren_free_preg2 = ret_old_preg2;

    // =======================================================================
    // 冲刷状态机
    // =======================================================================
    RTU_flush u_flush (
        .cpu_clk        (cpu_clk),
        .cpu_rst        (cpu_rst),
        .flush_trig     (flush_trig),
        .flush_src      (flush_src),
        .flush_pc       (flush_pc),
        .amt_flat       (amt_flat),
        .beu_redirect_vld(beu_redirect_vld),
        .fsm_busy       (fsm_busy),
        .flushing       (flushing),
        .mispred_pend   (mispred_pend),
        .core_redirect  (rtu_core_redirect),
        .backend_flush  (backend_flush),
        .expt_clr       (expt_clr),
        .flush_lvl      (flush_lvl),
        .ren_flush      (ren_flush),
        .ren_recover_vld(ren_recover_vld),
        .ren_recover_map(ren_recover_map),
        .beu_mask       (beu_mask),
        .ifu_flush      (rtu_ifu_flush),
        .ifu_chgflw_vld (rtu_ifu_chgflw_vld),
        .ifu_chgflw_pc  (rtu_ifu_chgflw_pc)
    );

    assign rtu_backend_flush         = backend_flush;
    assign rtu_beu_flush_chgflw_mask = beu_mask;
    assign rtu_ren_flush             = ren_flush;
    assign rtu_ren_recover_vld       = ren_recover_vld;
    assign rtu_ren_recover_map       = ren_recover_map;

    // =======================================================================
    // 派遣停顿 —— 只依赖寄存器 (P8): ROB 占用计数、CSR 在途、
    // 冲刷窗口、未决快路重定向 (D13)
    //
    // ⚠️ 2026-10-07 删掉了 `preg_short = (free_cnt < ren_preg_req)` 这一项。
    //    它看着无害, 但配 C910 IDU 会绕出**第二条组合环**:
    //        ren_preg_req ← IDU 的请求 ← ctrl_ir_stall ← ctrl_is_stall
    //                     ← rtu_idu_rob_full ← rtu_disp_stall ← preg_short ← ren_preg_req
    //    池子快见底时它还会**振荡** (preg_short=1 → 停 → 请求=0 → preg_short=0 → 放行 → …)。
    //    C910 那侧不成立, 因为它的 `rtu_idu_rob_full` 是**寄存器** (`ct_rtu_rob.v:4479`)。
    //    职责本来就重复: 该告诉消费者"这一路拿不到号"的是**每路的 alloc vld**
    //    (RTU_preg 的 tap, 寄存器), 比"剩余总数"精确, 也不在环上。
    //    ⚠️ 阶段 1 整核里 `ren_preg_req` 恒 0 ⇒ 这一项恒假 ⇒ 删它**行为一位不变**。
    // =======================================================================

    // ⚠️ mispred_pend 是**寄存器** (见 RTU_flush) —— P8 要求这一项不许把
    //    beu_redirect_vld 组合进来 (那会造出"EX 控制锥 -> 前端捕获使能"的新长链,
    //    而 r3 的绑定路径正是 ex_csr_op -> U_ID_EX/*_reg/CE 那一族)。
    assign rtu_disp_stall = rob_full | csr_inflight | flushing | mispred_pend;

    // =======================================================================
    // 其余提交点副作用与 retire 计数
    // =======================================================================
    assign rtu_trap_vld   = trap_or_int;
    assign rtu_mret_vld   = mret_hit;
    assign rtu_trap_epc   = trap_epc_d;
    assign rtu_trap_tval  = trap_tval_d;
    assign rtu_trap_cause = trap_cause_d;
    assign rtu_retire_cnt = pop_n;

    // -----------------------------------------------------------------------
    // 提交窗口广播 (给 LSU) —— 寄存器输出, 与 C910 `ct_rtu_rob_rt.v:2686-2713` 同构
    //
    // 一次边沿上成对锁存: 决策 (`retire_cnt > k`, 且槽 0 要排掉 trap) 与**当拍**的
    // 窗口 iid。消费方必须在同一个边沿成对采样 —— iid 是无条件锁存的, 单独看它会
    // 拿到"下一个窗口"的号。
    // ⚠️ trap 那条: 它走了 `rtu_retire_cnt` 与 difftest 脉冲 (§6.3 ⑥ 的口径), 但
    //    **没有真正提交** (没写 rd、store 不落内存) ⇒ 这里必须排掉, 否则 LSU 会把
    //    一条陷入的 store 写进内存。中断那条 `pop_n = 0` ⇒ 三路自然全 0。
    // -----------------------------------------------------------------------
    reg  [2:0] cmt_q;
    reg  [6:0] cmt_iid_q0, cmt_iid_q1, cmt_iid_q2;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            cmt_q <= 3'd0;
            cmt_iid_q0 <= 7'd0; cmt_iid_q1 <= 7'd0; cmt_iid_q2 <= 7'd0;
        end else begin
            cmt_q[0] <= (pop_n > 2'd0) && !trap_hit;
            cmt_q[1] <= (pop_n > 2'd1);
            cmt_q[2] <= (pop_n > 2'd2);
            cmt_iid_q0 <= win_iid0;
            cmt_iid_q1 <= win_iid1;
            cmt_iid_q2 <= win_iid2;
        end
    end

    assign rtu_yy_xx_commit0     = cmt_q[0];
    assign rtu_yy_xx_commit1     = cmt_q[1];
    assign rtu_yy_xx_commit2     = cmt_q[2];
    assign rtu_yy_xx_commit0_iid = cmt_iid_q0;
    assign rtu_yy_xx_commit1_iid = cmt_iid_q1;
    assign rtu_yy_xx_commit2_iid = cmt_iid_q2;

    assign rtu_lsu_async_flush = 1'b0;   // 无 debug 模块 ⇒ 见端口注释

endmodule
