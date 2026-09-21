# RV32I / no-MMU IFU 初版集成说明

日期：2026-09-21。入口：[rv32_ifu_top.v](../rtl/rv32_ifu_top.v)，完整清单：[ifu_files.f](../rtl/ifu_files.f)，共 41 个 RTL 文件。顶层 179 个端口与 `RV32I_C910_IFU_interface_v1.1_noMMU.xlsx` 的 IFU_Interface 页逐个核对名称、方向和位宽。

依据为同目录原 IFU 文档中的 `RV32I_C910_IFU_microarchitecture_spec_zh.md` v3.1。原 C910 RTL、规格和 Excel 均未改动。本版完成可运行的前端 RTL 集成；不包含 IU 的 PCFIFO 本体、ROB、LSU 或提交模型，也不表示已完成 CPU 级验证、综合和时序收敛。

## 1. 新增模块与 C910 职责对应

| 本版模块 | 参考 C910 模块 | 实现与改造 |
|---|---|---|
| ipctrl / ipdp | ct_ifu_ipctrl / ipdp / ipdecode / decd_normal | 四个完整 word；真实 opcode 复核；Tag 命中汇总；错 Way 重发；真 miss；多条件分支分段 |
| ibctrl / ibdp | ct_ifu_ibctrl / ibdp | 注册源包、IND 同步等待与结果保存、RAS/IND 恢复互锁、前缀接受和训练事件 |
| addrgen | ct_ifu_addrgen | 对注册源包做 32 位直接目标/后继校验；在分配 token 前完成局部校正 |
| pcfifo_if | ct_ifu_pcfifo_if | 双路创建和 credit/token 接入；超过两项 pc_oper 的前缀切分；LBUF 限单路 |
| ibuf | ct_ifu_ibuf / ibuf_entry | 32 个完整 128 位包，4 入/3 出；环形存储、空队列旁路、不足三条时合并 |
| l1_refill | ct_ifu_l1_refill | 单需求事务、关键块优先、独立首块保存、错误/取消/安装资格、排空 |
| ipb | ct_ifu_ipb | 下一行 Tag 查询、独立请求/返回状态、四块缓冲、在途匹配及 WRAP 回放 |
| biu | ct_ifu_top 的总线分流及 refill/IPB 请求 | ID0 demand、ID1 prefetch 独立占用和响应分流；需求优先 |
| maintenance | ct_ifu_ifctrl 等维护控制 | 初始化、CP0/LSU 命令、总线排空、预测器维护、Tag 失效、软件读与恢复 PC |
| vector / debug | ct_ifu_vector / debug | 复位入口、初始化后 PCLOAD；调试入口、静止握手、单条注入和历史恢复 |
| sfp | ct_ifu_sfp / sfp_entry | 12 项完整 PC 的 SF/BAR 反馈对与饱和计数；删除 VL/VL_RAW |
| lbuf | ct_ifu_lbuf / lbuf_entry | 16 条完整指令，七类循环状态、观察路径记录、前向分支体、动态预测重放 |
| pipeline / memory / top | 新增连接包装 | 按现有阶段职责连接；不重复实现阵列调度或 IU PCFIFO |

这里的“参考”是保留阶段职责、容量和事件语义；新 word 数据通路、LBUF/SFP 和维护 FSM 是 RV32I 适配实现，**不是逐拍等价的机械删行版本**。已派生的 BHT/RAS/IND 算法继续使用已有实现，BHT 原算法差分回归继续通过。

## 2. 唯一调度与流水边界

```text
PCGEN → IFCTRL / IFDP → IPCTRL / IPDP → IBCTRL / IBDP / ADDRGEN
                                                  ↓
                                           PCFIFO_IF（IU分配）
                                                  ↓
                                      IBUF / bypass / merge → IDU

maintenance ─┐
l1_refill ───┼→ IFCTRL 授权 → if_array → icache_if → Tag/Data/Precode
ipb ─────────┤
普通取指 ────┘
```

- **IFCTRL** 是唯一阵列仲裁者，优先级 maintenance > refill > IPB > fetch。SRAM 只执行授权命令。维护先排空在途事务再执行失效，避免高优先级请求压死必要回填写。
- **IFDP** 保存请求元数据、同步阵列响应、预测来源、首拍受阻副本以及 IF→IP 原子载荷。请求元数据扩展为 218 位、返回包为 577 位；新增 LBUF 来源和四槽有效掩码。
- **IP** 汇总两个 Way 的完整 Tag 命中，区分命中但未读取正确 Way 与真 miss。前者只重发，不分配总线事务；后者仅在需求 ready 时分配一次。顶层把 `miss_event` 并入 IFCTRL 的 refill-active 阻塞，防止分配拍错误重读并破坏待转发上下文。
- **Cache/REFILL** 不重新判断取指路径、不另发普通 lookup。正式顶层不实例化独立 `icache_top`；该模块只留作既有 Cache 单元回归。
- **IB** 持有已注册前缀，等待 IND/恢复/训练写口/PCFIFO/IBUF 资源。实际接受事件一次性提交指令、token、RAS/path 和 BTB/L0 训练。

正常命中请求在 E0 查询同步 Cache/BTB/BHT，E1 进入 IP，后续边沿进入 IB 并可旁路交付。不同块可重叠；多分支、维护和单端口预测表写入会产生独立停顿。无每块必须完整交付后才发下一请求的全局串行 FSM。

## 3. IP 分段与 BHT 时序

四路 `bp_decode` 由 generate 实例化。真实 opcode 识别 RV32I branch/JAL/JALR/AUIPC、调用返回、load/store 和 FENCE；非法格式按原始 word 交付 IDU，不把压缩编码当成两条指令。

`processed_q` 标记已经接受的槽。每个 IP 前缀在第一个条件分支、JAL、JALR 或故障处结束。条件分支 not-taken 保留后缀，下拍重新获得依赖更新后 GHR 的预测；taken/JALR/故障丢弃年轻后缀。AUIPC 只受 PCFIFO 带宽约束，不追加分支历史。

顶层设置 `bp_top.STAGED_BHT=1`：

| 控制/坐标 | 绑定 |
|---|---|
| BHT 查询索引 | `if_query_pc = ifctrl_ifdp_issue_pc` |
| IF 槽偏移 | `if_pc = ifdp_bht_pc` |
| 查询推进 | `bp_read = ifctrl_bht_read || inject_query` |
| 查询 stall | `!bp_read`，不是 `!IF→IP` |
| IP 预测锁存 | `IF→IP || (bht_event && bht_more) || inject_pipedown` |
| VGHR 追加 | `bht_event`，仅在 IP 前缀实际接受时 |
| IND GHR | IB 注册源包的分支前 GHR[7:0] |

`bht_more` 是当前有效片段仍有未处理后缀的电平，不是接受脉冲。首次查询、同块多条件分支和 stall 后预测不可混用不同阶段的 PC。全顶层分支测试用非零 GHR 种子，逐次核对分支前快照和 VGHR；循环重放走同一检查。

## 4. 注册目标校正与恢复闭环

ADDRGEN 在 **IP→IB 注册边界之后、PCFIFO 分配之前** 校验直接目标与预测后继。JALR 按 RAS（合法 return 提示）→保存的 IND 结果→BTB→未知目标顺序选择。同步 IND 读完成后锁存 target-valid/target，后续反压不依赖实时 SRAM 输出；IND miss 计数也使用此保存结果。

| 事件 | 清除/保持 | 预测状态 |
|---|---|---|
| IF L0 接受 | 保留当前源块和较老 IP/IB/IBUF | 只提前选路，不追加 GHR/RAS/path |
| IP taken/Way 重发/miss 重发 | 取消年轻 IF，按事件保留源前缀或重发上下文 | 条件历史只在真正接受时追加 |
| IB/ADDRGEN 校正 | 保留源和较老 IBUF；清年轻 IP/IF | 以源包 GHR 和保留方向修复 VGHR |
| LBUF 记录闭合 | 接受闭合源；撤销年轻取指，等待旧 IB/IBUF 与内存排空 | 恢复到闭合源之后的前缀历史 |
| IU 执行恢复 | 前端 IF/IP/IB/IBUF/LBUF 清除 | 按 IU 源快照和真实方向恢复 GHR；RAS/path 延迟至规定退休点 |
| RTU flush/维护 | 清旧前端；总线已授权事务排空 | 按提交边界恢复；选中预测器再失效 |
| 调试进入/接受 HAD PCLOAD | 清旧前端并序列化 | 恢复已提交历史/RAS/path；注入前重新查询 BHT |

局部校正与较老 IB 接受可能同拍，因此 `STAGED_BHT=1` 下 `local_recover_vld` **不会整体关闭 frontend_ok**。顶层单独取消年轻 IP，保留合法 IB 训练、RAS 和 path 更新；否则会漏更新，且可能经 BTB ready/IB accept/LBUF close 形成组合反馈。

后端必须维护 `iu_ifu_mispred_stall`，直到仍有效的误预测源到达规定退休恢复点或被更老恢复替代。IB 对 call/return/JALR 互锁；本版没有新增任意局部 RAS/path 检查点。正常 TOP 12 项、提交备份 6 项的保守恢复策略沿用已有实现。

L0 来源索引/槽/类型/目标与源块同存，IP 真实译码发现陈旧项时定向失效。训练只来自验证后接受的源。Way 训练当前仅在源和目标同一物理行时使用已知源 Way；跨行目标或 LBUF 来源保守写 `11`，因此跨行 Way 预测性能尚未实现完整目标反馈学习。

## 5. 双流配对、包格式与取消证明

内部每槽 192 位，仅在流水内部使用：

| 位域 | 含义 |
|---|---|
| [127:0] | 初步 IDU 包；[124:123] 暂存源 Way，尚未成为外部包 |
| [159:128] | 静态/记录目标 |
| [184:160] | BHT chk_idx；其中 [181:160] 为源前 GHR |
| [185] / [186] | dst_vld / 目标未知 |
| [187] / [188] / [189] | RAS push / pop / 可用栈顶提示 |
| [190] / [191] | 使用 BTB / LBUF 来源 |

外部 IDU128 使用 Excel 定义：inst[31:0]、PC[63:32]、pred_npc[95:64]、fault[96]、cause[100:97]、属性[104:101]、pc_oper[105]、cf_type[108:106]、token[121:109]、pred_taken[122]。PCFIFO_IF 强制清零保留位 [127:123]，内部源 Way 不会泄漏到 IDU。

PCFIFO 本体仍在 IU。后端每拍提供 0..2 credit 和对应的 13 位 token，IFU 按程序顺序创建最多两项；LBUF 来源最多一项。`AUIPC,AUIPC,AUIPC,ADDI` 必须分两次接受，credit=0 不得产生孤立创建或丢失后缀。

创建时刻是 IB 获准进入 IBUF/旁路的同一拍，早于 IDU 最终接收是允许的。IBUF 保存完整已分配包；IDU 只能接受候选流的连续最老前缀 0..3 条。`pop/bypass/push` 分别记账，旁路消费不会再次入队。

本顶层的 `ifu_iu_pcfifo_cancel_vld` 固定 0，理由是：所有本地目标校正发生在分配之前；校正源仍被接受；被取消的年轻 IP/IF 尚未分配；已分配 IBUF 全是应保留的较老前缀。故不存在需本地回收的已分配年轻后缀。**该结论依赖当前边界**：以后若增加分配后的延迟校正，必须实现 token 后缀取消，不能继续固定 0。IU/RTU 全恢复及序列化维护/调试时，后端仍须依据自身恢复边界回收未完成 token；IFU 不能替后端管理 ROB 代际。

## 6. 需求回填、IPB 和总线

L1_REFILL 是一个在途需求描述符，Cacheable allocate 请求为四拍 128 位 WRAP，起始 offset 为源 PC[5:4]；未分配请求为单拍，不写 Cache。首块转发缓冲与回填写 beat 缓冲独立，即使首块被 IF 反压，整行仍能继续安装。

第一次回填写使替换行 valid 失效；只有最后一个无错 beat 接受且安装资格仍在时发布整行。普通改向清 live 交付资格，已授权事务仍返回/排空，可安装干净行；维护清安装资格，禁止失效过程中迟到安装。错误不会给已取消路径再交付故障。

IPB 仅由实际授权的需求触发下一行预取；查询独立静态区域属性，并拒绝地址溢出、跨 4 KiB 物理窗口、不可执行/不可缓存/不安全区域。先获 IFCTRL Tag 查询授权，已命中则取消预取。ID1 在途或已完成缓冲命中需求时，不再发重复 ID0；收到完整无错行后从需求 offset WRAP 回放。纯预取错误丢弃，随后需求允许重新请求 ID0。

BIU 保持 ID0/ID1 独立在途占用，支持交错返回和 `r_ready` 反压；每个 ID 内按 WRAP 顺序返回，last/错误遵循接口表。外部是 **req/grant 协议，不是 AXI ARVALID**；如接 AXI，需在 SoC 适配层增加地址保持、属性映射和 AXI ID/response 转换。未宣称此模块可以直接接 AXI。

## 7. LBUF、SFP、维护和调试

LBUF 保留 IDLE/FILL/FRONT_BRANCH/CACHE/ACTIVE/FRONT_FILL/FRONT_CACHE 状态职责。遇已接受的向后直接控制流后记录下一次观察到的遍历，最多 16 条 `{PC,inst}`；前向跳转保存实际观察体。故障、call/return/JALR、容量溢出或记录路径不连续时退出。ACTIVE 查不到新路径时回到 Cache，不假设所有循环形态都可重放。

重放只保存静态 PC/opcode，**不保存上轮 token/GHR/预测方向**。命中时 IFCTRL 仍产生一次逻辑取指接受，顶层抑制物理 Cache fetch grant 并按 SRAM 时序提供合成数据/Tag。源包标记 LBUF，有效槽取已记录的连续前缀；未记录块后缀由 IP 重定向继续取指。每轮重新经过 IP/BHT、IB 和单路 PCFIFO。CACHE 等待期间允许已经请求的正确较老包排空，ACTIVE 需 IB/IBUF 和内存为空。循环退出/维护/后端恢复都会撤销重放。

SFP 使用 12 项 SF PC/BAR PC、2 位饱和计数与循环替换。三路退休反馈按程序顺序选择最老一个事件，保留单更新口；store miss 分配 SF，后续 load 反馈绑定 BAR，load hit 饱和加一、mispred 减一，store mispred 清计数。SF 接受后使后续 BAR 可预测，取消清推测 BAR 读状态。该实现是非向量语义适配，不声称与 C910 混合 VL/SF/BAR 算法等价。no_spec 不能替代 LSU 内存依赖和 FENCE 正确性。

维护器扫描 512 个 Cache set 清 Tag，等预测器初始化后才发布 init_done。CP0 与 LSU 同拍请求时 LSU 优先；保存命令拥有者与 resume_pc，只向拥有者返回 done。命令接受先 flush/停取，等 ID0/ID1/回填排空后执行预测器维护、全失效或物理行双 Way 比较失效。等待期间的后端恢复更新保存的 resume_pc。软件 Data/Tag/Precode 读使用同一阵列仲裁，response 一直保存到 data_ready；不会覆盖等待中的返回。

VECTOR 在复位后锁存 RVBR，初始化完成才发一次入口 PCLOAD。DEBUG 只在 debug-on 且 quiescent 接受合法单个 HAD PCLOAD 或 IR 命令。IR 保存后经历 BHT query/pipedown 再送一个 IP word；准备期也计入 busy，不会重复注入。`ifu_yy_xx_no_op` 表示事务及维护排空，不要求 IBUF 为空；`ifu_had_quiescent` 还要求各级与注入/LBUF 停止。

## 8. 配置、风格与复现

顶层默认 REGION_MAP 全拒绝，接入前须设置 `REGION_COUNT/REGION_BASE/REGION_LIMIT/REGION_ATTR`。每项是完整 32 位 base、33 位 exclusive limit、5 位 `{exec_allow,cacheable,bufferable,sec,spec_safe}` 属性；集成方必须提供 64 字节对齐的区域边界，RTL 对重叠映射拒绝访问。测试只开放 0x1000..0x2fff。CP0 功能开关应在停取/维护窗口修改，不能用动态开关替代事务取消。

新增 18 个模块均采用用户指定 `cci500_tt.v` 的结构风格：重复存储/比较/槽处理用 generate；组合逻辑 assign；59 个时序模板仅异步复位与使能 `_q <= _nxt`。独立字段的 next-state 选择在 assign 中，时序块没有 case、组合 always 或重复手写的 entry 电路。顶层命名的 Excel 槽端口仅做固定连线拆包。原有 BHT/RAS/IND 内部保留派生代码风格，不把其既有组合过程冒称已全部改写。

在 `ifu_rv32i` 目录执行：

```powershell
python scripts/build_pipeline.py
python scripts/build_support.py  # 同时生成 memory 模块
python scripts/build_top.py
python scripts/check_pipeline.py
python scripts/check_memory.py
python scripts/check_support.py
python scripts/check_ifu.py
python scripts/check_completion.py
python scripts/rtl_style.py --check
```

改生成模块时同步改生成器；`check_completion.py` 会验证生成结果与当前 RTL 完全相同。已有 IF/PCGEN/Cache/预测器回归入口继续保留。正式编译使用 `-g2001 -s rv32_ifu_top -f rtl/ifu_files.f`。

## 9. 已执行验证与边界

| 测试 | 实际结果 |
|---|---|
| 顶层接口/展开 | 179 端口精确匹配；Verilog-2001 编译；零错误，39 条既有预测器混合逻辑括号提示，无新增告警 |
| IP/IB/IBUF/PCFIFO | 975 周期、15,252 次检查、1,007 条指令、522 次分配、252 次条件事件；零 lint 诊断 |
| 需求/IPB/BIU | 100 周期、163 次检查；交错 ID、首块反压、在途复用、错误隔离、取消/维护排空、非缓存 |
| SFP/辅助模块 | 35 周期、30 次断言；SF/BAR 关联、饱和/减计数、禁用、全 PC、最老反馈、12 项替换和失效；零 lint 诊断 |
| 原预测器 | 7,124 次集群检查；15,641 次译码/目标检查；原 C910 BHT 37,164 次差分检查 |
| IF 阶段 | 6,260 周期、84,921 次检查，真实相邻阵列和查询时序 |
| 可复现/结构检查 | 18 个新增模块、59 个寄存器模板；54 项 RTL/清单/端口产物无重生成差异 |

顶层六组都使用真实 Cache、预测器、流水、LBUF 和随机 IDU/credit/BIU 反压，并覆盖初始化、恢复、维护换代码、软件 Tag 读保持、LSU 行失效、调试单条注入、非零历史进入调试、区域拒绝和精确不对齐故障、故障后恢复：

| 模式 | 周期 | 检查 | IDU交付 | Cache访问 | LBUF active周期 |
|---|---:|---:|---:|---:|---:|
| 64条循环 | 3430 | 14739 | 1043 | 330 | 0 |
| 16条短循环 | 3429 | 14768 | 1041 | 70 | 594 |
| 短循环含前向跳转 | 3429 | 14829 | 1042 | 71 | 613 |
| 多条件分支 | 4461 | 19540 | 1029 | 288 | 0 |
| 短循环多条件分支 | 4409 | 19345 | 1032 | 55 | 1423 |
| 分支预测器全关闭 | 4355 | 18201 | 1030 | 293 | 0 |

结果在 `work/{pipeline,memory,support,ifu,completion}`。测试的条件分支真实结果采用固定程序/参考流，尚无 ROB 驱动的全 CPU 任意乱序提交差分；顶层间接跳转/复杂误预测交互仍需后端联调，已有模块回归不能代替该验证。SRAM 为同步行为模型，尚未目标工艺映射、综合、STA 或功耗检查。

当前可审查的性能边界还包括跨行 Way 的保守双读、RAS 六项提交备份恢复覆盖、LBUF 仅缓存观察到的有限路径、SFP 单端口反馈及上述适配算法。它们已在实现中明确，不将其宣称为完整复现 C910 性能。

本次增量来源、输入与产物 SHA-256 及旧文件 before/after 见 [completion_manifest.json](completion_manifest.json)、[completion_delta.patch](completion_delta.patch)。此前 `if_stage_source_manifest.json` 等清单是各次交付时点的历史记录；当前版本以本次清单为准。
