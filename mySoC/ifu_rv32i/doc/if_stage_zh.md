# IF阶段实现、阵列控制归属与预测恢复契约

日期：2026-09-21。依据 `../ifu/doc/RV32I_C910_IFU_microarchitecture_spec_zh.md` v3.1 和 `RV32I_C910_IFU_interface_v1.1_noMMU.xlsx`，参考 C910 的 IFCTRL/IFDP、IPCTRL、IBCTRL、PCGEN、ADDRGEN、BHT、RAS 和 IND BTB。原代码与输入文档未修改。

本次完成：

- [rv32_ifu_ifctrl.v](../rtl/rv32_ifu_ifctrl.v)：正式流水的 IF 控制、唯一阵列授权仲裁、IF/IP有效位、重发保持、L0接受事件和访问时序。
- [rv32_ifu_ifdp.v](../rtl/rv32_ifu_ifdp.v)：请求元数据、Cache/回填数据选择、Tag分段比较、首次受阻保存、IF→IP载荷寄存。
- [rv32_ifu_if_array.v](../rtl/rv32_ifu_if_array.v)：把仲裁授权落实到每个原始阵列控制端口；内部实例化已有 `icache_if`。仅有连线和授权门控，没有第二套调度状态机。
- 主 BTB 增加同步 SRAM 读后、旧结果寄存前的 IF 输出；原注册接口与行为保留。预测器连接层及生成器同步导出这些端口。

独立清单为 [if_stage_files.f](../rtl/if_stage_files.f)。它包含 PCGEN、实际阵列、区域译码、主 BTB 和 IF 模块，**不包含 `icache_top` 或独立 demand BIU 调度器**。完整顶层现已在 [ifu_files.f](../rtl/ifu_files.f) 中接入，见 [pipeline_zh.md](pipeline_zh.md)；本文件继续说明 IF 模块边界及其独立验证。

## 1. 唯一控制归属

采用规格 §4.2/4.3 和 C910 的阶段划分，不让已完成的独立 Cache 封装替代 IP 职责。

| 职责 | 唯一归属 | 本次实现/边界 |
|---|---|---|
| PC优先级、顺序块地址、分级取消范围 | PCGEN | 使用现有模块；普通 stall 不阻挡更高优先级改向 |
| 当前普通访问是否真的取得阵列 | IFCTRL | 与维护、回填写、IPB竞争；只依据 grant 记录访问和推进普通PC |
| SRAM端口、Tag/Data/Precode存储及写掩码 | ICache IF/arrays | 被动执行授权的访问；不自行发取指或重读 |
| 初始化/失效/软件读步骤 | maintenance | 序列器提出维护请求，IFCTRL统一授权；先排空后失效 |
| 回填写入时机、整行发布、错误及BIU排空 | L1_REFILL控制域 | 提出回填写请求并等待grant；只提交整行无错的install |
| IPB Tag查询、预取及回放 | IPB控制域 | 提出Tag请求并等待grant；不能另外直连一组取指控制 |
| 物理区域许可/属性、异常入口及请求元数据 | IF | 使用静态组合译码；属性和PC同拍保存 |
| SRAM/关键块转发选择及首次受阻保存 | IFDP | 把源PC、两路数据、预测信息作为同一载荷保持 |
| Tag分段比较 | IFDP | 每Way比较低8位、中8位、valid+最高位，随数据寄存 |
| 汇总完整Tag命中、选择正确Way | IP | 使用分段结果；IFCTRL没有命中状态机 |
| 区分真miss、Way预测错、已有回填等待 | IP | 分别发起需求/请求重发/等待，不能在Cache包装内再次处理 |
| 四word译码、分支截尾、多条件分支分段 | IP | IF只形成入口mask并携带L0来源，保留全部入口后槽供校验 |
| RAS/IND后期处理、PCFIFO及指令分发 | IB | 已由IBCTRL/IBDP和PCFIFO_IF实现，不提前到IF |

`rv32_ifu_icache_top.v` 仍可作为既有独立 Cache 回归封装使用。正式 IF→IP 路径选择 `if_array → icache_if → arrays`，不把 `icache_top.lookup/result` 接在其旁边，也不让它与IFCTRL同时控制一份阵列。独立封装中的命中判断/Way重读可作为后续IP移植的验证参考，不是正式流水的第二个控制源。

## 2. 阵列授权接口

`ifctrl_array_grant[3:0] = {fetch, ipb, refill, maintenance}`，优先级为 maintenance > refill > ipb > fetch。请求可保持，**只有grant当拍允许源完成一次阵列访问**。请求提交前，上层维护控制须与在途回填协调，不能用高优先级维护请求永久阻止必须排空的回填写。

`if_array` 将维护strobes、回填写/first/last/install、IPB请求和普通读分别按授权门控。对于合法源命令，原阵列的高优先级地址拥有者保持one-hot-or-zero。地址、Data、Tag等载荷可以直接连线，源在获得grant前必须保持载荷。

- 维护初始化访问应同时提供 reset_req、inv_on、tag_req 及相应低有效tag_wen；reset_req单独只控制数据清零，不等于Tag初始化。
- 维护Tag操作与软件Data读取属于同一维护控制域，但仍须遵守原阵列的互斥控制编码，不能任意把不同子命令相或。
- 回填写的被接受事件为 `refill_array_req && ifctrl_refill_grant`；first/last/install与该拍数据同步。
- IPB在grant拍采样其请求，下一拍取得对应同步Tag结果。
- 普通读为 `ifctrl_array_fetch`。读取选中Way的四个word及两路Tag，实际读取Way记录在请求元数据中。

本次每次普通访问都读取Tag；不继续依赖“只有跨行才读Tag”的隐含Q保持假设，因为维护/IPB可改写共享Tag输出。这保持每拍一块的访问带宽，增加Tag读活动；后续若优化行内Tag重用，必须另外保存Tag归属和有效位。

Way=`00`的重试保守使用双路读取，和现有独立Cache的00/11双读约定一致；01/10仍只读取指定数据Way。IP看到Tag命中未读Way时才发正确Way重发。

## 3. PCGEN连接与重发

IFCTRL输入的 `pcgen_icache_if_index/way_pred` 来自PCGEN快速路径。普通推进仅在真正接受访问或内部故障/旁路描述时解除stall。高优先级PCGEN改向仍可在没有阵列授权时保存目标，IFCTRL随后保持replay，直到访问实际完成。

必须区分以下取消线：

| IFCTRL输入 | 接线 |
|---|---|
| `frontend_redirect` | 已接受的debug/vector/RTU/IU/ADDRGEN/IB/IP改向或IP重发；**排除IF自己的L0和IF重发** |
| `pcgen_ifctrl_pipe_cancel` | 直接使用PCGEN同名输出；控制IF→IP valid取消，优先于IP stall |
| `pcgen_ifctrl_reissue` | 直接使用PCGEN同名输出；表示debug/vector/RTU最终PC不同于当拍快速地址 |
| `control_ifctrl_reissue` | 控制器明确要求重新采样当前PC的脉冲；取消当前IF样本并置持续重发状态 |

`frontend_redirect` 的具体逻辑为：

```verilog
(debug_pcgen_pcload && rtu_ifu_dbgon) || vector_pcgen_pcload ||
rtu_ifu_chgflw_vld || iu_ifu_chgflw_vld || addrgen_pcgen_pcload ||
ibctrl_pcgen_pcload || ipctrl_pcgen_reissue_pcload || ipctrl_pcgen_chgflw_pcload
```

**不能将 `pcgen_ifctrl_cancel` 直接接入 `frontend_redirect`。** 前者包含IF自身重发，直接回接会把合法重发当成新取消，甚至形成组合反馈。联合测试已使用上面的明确连接。

高优先级改向拍不采样错误快速地址；已保存目标通过 `ifctrl_pcgen_reissue_pcload` 重新访问。即使阵列连续七拍被维护占用，目标也不会只保存一拍后丢失。重发不改变块内word入口。

IF L0的 `chgflw_no_stall_mask` 是去掉下游stall资格的早期提示，可能在IP反压时为1；实际 `chgflw_vld` 只在源块IF→IP接受时产生。受阻时不会因此接受阵列访问或消费预测。

## 4. 流水与载荷保持

本版保留重叠流水，不用等待一个块全部分发的串行取指FSM。

| 边沿/阶段 | 行为 |
|---|---|
| E0 | 获得普通读授权；Cache和BTB同步读；IFDP保存请求PC、属性、priv、Way、来源和断点比较结果 |
| E0之后的IF | SRAM结果、Tag分段比较、L0查询及主BTB早期结果属于刚接受的请求 |
| E1 | 若IP可接收，完整载荷进入IP；同一边沿可接受下一个取指块 |
| IP受阻的首次边沿 | IFDP保存完整返回载荷；此后其他阵列拥有者或预测器更新不能改变该块 |
| 后续受阻周期 | IF/IP有效位和载荷按各自边界保持；取消优先于保持 |

IFDP现有218位请求元数据，以及两份相同的577位返回载荷寄存器：一份用于首次stall保存，一份为IP载荷。两份返回寄存器由同一个 `g_capture` 模板生成。新增 `lbuf_ifdp_source/word_mask` 保存循环来源和已记录槽；`ifdp_ipdp_lbuf_on` 随IP包输出，入口mask与LBUF槽mask相交。IF有效位/IP有效位由IFCTRL维护，数据无效时不要求清零整份载荷。

载荷包含完整PC、区域属性、priv、读取Way、回填/旁路类型、FIFO、异常/cause、入口mask、两组断点、两路Data/Precode、两路Tag分段结果、主BTB四槽目标/Way、L0索引/槽/类型/目标/Way和SFP no_spec。word0对应低32位。

`ifctrl_ipctrl_if_pcload` 是与IP载荷同拍保存的**L0实际接受标志**。`ifdp_ipdp_l0_hit`仅表示保存的候选，不能替代该标志。IP必须用实际接受标志判断早期路径是否已经改变。

BTB新增 `if_vld/if_pc/if_hit/if_target/if_way_hint`，连接层对应导出 `btb_if_*`。旧 `result_vld/hit/target/way_hint` 再晚一个寄存边沿，不接到本版IFDP。新口的值与下一拍旧口逐拍比较通过，未增加或修改表、训练缓冲及旧结果寄存状态。

BHT查询索引必须来自 **本次接受的PC `[13:4]`**，IF偏移坐标来自 `ifdp_bht_pc[7:1]`。本版给出 `ifctrl_bht_read/pcindex/pipedown/stall`；其中read连接叶模块的`pcgen_bht_seq_read`，pipedown为真实IF→IP接受。`stall = !read`，用于查询索引及SRAM返回有效位的推进，**不能取`!pipedown`**，否则空IF的首笔查询会丢失关联。此接法不再额外连接原PCGEN的BHT chgflw/short读脉冲（接0），避免无授权访问。现有 `bp_top` 中从单个 `if_pc` 同时推导索引的独立验证接线，不能直接照搬成正式PCGEN/IF双阶段接线；正式顶层应连接BHT叶模块的两个坐标，或据此拆分预测器连接层。没有用IF早期GHR值伪造IP分支快照。

## 5. 命中、异常、旁路与回填

完整顶层现已设置 `bp_top.STAGED_BHT=1`，通过 `if_query_pc` 和 `if_pc` 实现上节要求的双坐标；同块条件分支接受且有后缀时增加 BHT repipe。该接线与调试/LBUF重放的时序见完整集成说明。

IP使用每Way的 `tag_match[2:0]` 汇总命中，并与读取Way相交：

```text
hit[w]      = &tag_match[w]
data_hit[w] = hit[w] && way_pred[w]
```

异常优先处理；refill_on、cache_bypass必须单独处理。正常缓存源若命中未读Way，则IP保存/取消相应年轻边界并发Way重发；无Tag命中才是真miss。IF没有另一个命中选择或miss FSM，也不发BIU请求。

区域拒绝或地址不对齐产生内部异常描述，不访问阵列/预测器；异常载荷只保留入口槽，Data/Precode清零，cause为0（地址不对齐）或1（访问故障）。原始PC完整保存，不通过清低位修复地址。

非缓存区域/关闭Cache产生 `cache_bypass` 描述，数据和Tag命中均无效。它用于IP发起需求，不是可以直接译码并交付的零指令。只有合法命中、合法回填或异常令牌可按各自规则进入后续IB。

L1_REFILL的职责是保存已授权总线事务、live交付资格、首块及错误、尾拍安装与排空。关键块接口必须valid/ready保持：

- `active` 阻止普通阵列取指，但不阻挡维护/回填/IPB的已协调阵列请求。
- `live` 证明响应属于当前有效需求；**同PC相等不能代替live**。
- `pc[31:4]` 还须匹配待重发PC的块地址；指令入口低位来自保存的PC。
- 仅有待重发上下文且IF有空间、BTB能同步查询时接受关键块；接受后清待重发资格，避免把一个响应重复交付。
- 关键块Data/Precode/错误在接受时保存，后续BIU beat不能覆盖；转发占用逻辑Way0并提供合成命中，Way1无效。
- `ifctrl_l1_refill_cancel` 撤销旧交付资格，不是禁止BIU返回，也不是阻止安装的维护信号。
- 已接受需求的关键块可在no_op停取期间排出；no_op仅阻止新普通请求。

完整顶层已接入独立 `rv32_ifu_l1_refill`、`rv32_ifu_ipb` 和双ID BIU；其阵列请求仍由本IFCTRL授权。独立 `icache_top` 不与正式IF调度器并联。

## 6. 以C910为参考的预测恢复分工

采用规格 §6.6 的 **IU早期恢复、RAS/IND等待规定退休点** 协议，不改成“每次局部改向就复制提交栈”的增强变体。

| 状态/事件 | 产生阶段和恢复要求 |
|---|---|
| L0早期路径 | IF只查询、提出目标；实际接受一次后标记来源并传给IP；不追加GHR、不push/pop RAS、不推进IND路径 |
| 条件分支推测历史 | IP按照实际接受的有效前缀逐次更新；BHT快照、processed_mask须在IP/IB保存，stall/重发不能重复追加 |
| 局部GHR校正 | IP/IB/ADDRGEN根据被保留前缀给出 `local_recover_vld/ghr`；较老取消压过年轻IP更新，不能统一拉高RTU flush |
| L0错误项 | IP/ADDRGEN根据该块保存的entry index/one-hot mask产生定向失效；不能使用后来一次查询的索引 |
| RAS推测push/pop、IND推测路径 | IB实际接受call/return/JALR等源指令后才更新；IF查询和IF→IP移动不触发这些更新 |
| IU误预测 | PCGEN取消年轻前端，BHT按该动态源快照和实际方向恢复；后端维持 `mispred_stall`，不能在IU恢复拍无条件复制提交RAS/path |
| 延迟恢复窗口 | IB对依赖RAS/IND的指令互锁；较老提交继续更新提交副本；IF禁止使用不安全的间接L0候选 |
| 规定退休点/更老全恢复 | RAS/IND沿用 `retire0_mispred` 或 `rtu_ifu_flush` 恢复，并包含规定的同拍退休更新；后端解除或替代恢复等待 |

参考位置：原 `ct_ifu_bht.v` 的VGHR选择（约644行），`ct_ifu_ibctrl.v` 的RAS/IND接受事件（约909行），`ct_ifu_ras.v`/`ct_ifu_ind_btb.v` 的RTU恢复，以及 `ct_ifu_addrgen.v` 的注册目标校验、IB取消与L0定向失效。

**本次已实现的恢复部分**：正确的IF/IF→IP取消、L0接受一次性、L0来源及目标稳定保存、分域取消接线、同地址旧回填拒绝，以及 `bp_recovery_stall` 对间接L0候选的屏蔽。`cf_type=3`统一表示JALR，因此恢复期间保守屏蔽所有间接L0候选；直达JAL目标仍可查询，RAS更新留在IB。

**现已在完整流水接入**：IP/IB产生源关联的局部GHR恢复值、真实译码校验、L0定向失效、IB的RAS/IND接受互锁及token配对。目标校正在源分配之前完成，局部取消不会撤销已接受的较老RAS/path事件。PCFIFO本体、ROB动态身份和IU年龄过滤仍由后端提供，具体证明与接入约束见完整集成说明。

现有预测器连接层的 `frontend_cancel` 是组合验证边界，不是所有局部cancel的总和。将年轻IF/IP取消直接广播给较老IB的RAS/IND接受逻辑会丢失合法更新；正式顶层须按上述域连接，各事件与指令前缀原子接受。

## 7. 初始化、维护和范围

`frontend_init_done` 必须表示系统所需初始化已完成；顶层以Cache和预测器初始化完成及VECTOR状态驱动。VECTOR、维护序列器、DEBUG、IPB/L1_REFILL和IP/IB已通过IFCTRL的授权/暂停/取消边界接入，未复制独立Cache封装中的调度状态机。

`ifctrl_idle` 仅指本模块IF/IP两个上下文为空，不是整个IFU的no_op/quiescent。系统时钟许可不作为请求valid，物理ICG和目标SRAM宏映射未在此完成。

正式维护应先禁止新前端事件、按范围取消旧指令并排空事务，再向IF仲裁器提交数组操作。维护完成/软件读完成不能无条件让PC重复交付：需要重新读取当前PC时使用显式control_reissue；需要恢复到指定程序位置时由PCGEN接受resume_pc。

## 8. 风格、复现及验证

重复电路使用 `generate`：拥有者优先级、控制门控、状态位、两份载荷、两Way分段Tag比较、四槽与双断点比较、16项L0失效mask。所有新模块组合逻辑均为assign，寄存器时序块仅复位及使能更新，没有组合always或过程式循环。

```powershell
python scripts/build_ifdp.py
python scripts/build_if_array.py
python scripts/check_if_stage.py
python scripts/rtl_style.py --check
```

IFCTRL为手工RTL；IFDP及授权连接层分别由上述两个生成器维护。修改生成模块应先修改对应脚本。IF阶段首版审计保存在 [if_stage_source_manifest.json](if_stage_source_manifest.json) 和 [if_stage_C910_delta.patch](if_stage_C910_delta.patch)；后续IFDP/BP集成增量及当前产物哈希见 [completion_manifest.json](completion_manifest.json)。

验证已通过：

- 十二文件清单的Slang展开零错误、零告警；三个新模块Verilog-2001编译。
- AST检查assign/generate与复位/使能风格，19处Excel同名端口映射，生成结果可重复。
- 实例化真实PCGEN、IFCTRL/IFDP、Cache SRAM、两份静态区域译码、主BTB与BHT叶模块；测试端提供后续IP反压/改向和维护/回填/IPB源请求。BHT及其两份SRAM包装作为额外仿真源加入，不改变十二文件基础清单。
- 独立Data/Precode/Tag存储模型及事务记分板，6260周期、**84921次检查**，其中4000周期固定种子随机冲突/反压/改向；接受557次IF访问、386次IF→IP转移、107次L0接受。
- 连续16拍每拍一块，逐一核对PC顺序；覆盖初始word入口、首次stall保存、受阻期间阵列和预测信息变化、错Way与真miss、断点mask、区域拒绝、非缓存旁路、关键块转发、错误令牌、同PC旧响应、局部/全局取消、持续重发。
- 主BTB早期结果与下一拍旧注册结果逐拍一致。
- BHT selector表按行/槽预置不同计数器，以源PC独立计算期望值；检查首笔/连续查询、停顿和改向后结果关联，无传递时IP结果保持，以及没有IP更新事件时IF访问不修改VGHR。
- 原预测器回归（7124/15641/37164次检查）、PCGEN（1264596次比较及53次阵列检查）、ICache（9435次检查及33×4预码测试）亦通过。

结果位于 `work/if_stage/result.json` 与同目录日志。测试覆盖当前IF阶段和实际相邻阵列接口，不是完整IP/IB恢复、三路IDU交付、CPU提交差分、形式验证或综合/STA报告。
