# RV32I / 无 MMU PCGEN 初版

**2026-09-21接入更新**：IFCTRL/IFDP已实现，正式阵列路径及持续重发连接按 [if_stage_zh.md](if_stage_zh.md) 执行。本文原来的“未来IF控制器”职责现由新增IFCTRL承担；完整IP/IB、VECTOR/DEBUG和全前端维护仍未实现。

日期：2026-09-21。RTL 为 [rv32_ifu_pcgen.v](../rtl/rv32_ifu_pcgen.v)，模块名沿用 C910 的 `pcgen` 拼写。依据用户指定的 `../ifu/doc/RV32I_C910_IFU_microarchitecture_spec_zh.md` v3.1，特别是 §3.1、§4.1、§4.5，以及 `RV32I_C910_IFU_interface_v1.1_noMMU.xlsx`。源实现为 `../ifu/rtl/ct_ifu_pcgen.v`。

本次交付是 PC 选择、IF PC 状态、Way 提示和分级取消模块；不是完整 IFU 顶层，也没有增加 IF/IP/IB、VECTOR 或 DEBUG 控制器。原 C910 RTL、规格和 Excel 未修改。此文件是手工维护的 RTL，现有预测器和 ICache 生成器不会覆盖它。

## 1. 地址与来源优先级

所有完整 PC 端口均为 **32 位物理字节地址**。正常指令起点低两位为零；PCGEN 不会通过清零低位掩盖错误目标。执行端应按接口协议在源分支上报告不对齐异常，不得发送错误恢复目标。

正常步进为 `(PC & 32'hfffffff0) + 16`，加法按模 2^32 回绕。IF 重发保持完整 PC，包括 `[3:2]` 的块内入口位置。重定向不受普通 `ifctrl_pcgen_stall` 阻挡。

| 优先级 | 事件 | 地址 | Way 提示 |
|---|---|---|---|
| 0 | 已接受的调试 PC 装载且 `rtu_ifu_dbgon=1` | `debug_pcgen_pc` | `11` |
| 1 | `vector_pcgen_pcload` | `vector_pcgen_pc` | `11` |
| 2 | `rtu_ifu_chgflw_vld` | `rtu_ifu_chgflw_pc` | `11` |
| 3 | `iu_ifu_chgflw_vld` | `iu_ifu_chgflw_pc` | `11` |
| 4 | `addrgen_pcgen_pcload` | `addrgen_pcgen_pc` | `11` |
| 5 | `ibctrl_pcgen_pcload` | `ibctrl_pcgen_pc` | `ibctrl_pcgen_way_pred` |
| 6 | `ipctrl_pcgen_reissue_pcload` | `ipctrl_pcgen_reissue_pc` | `ipctrl_pcgen_reissue_way_pred` |
| 7 | `ipctrl_pcgen_chgflw_pcload` | `ipctrl_pcgen_chgflw_pc` | `ipctrl_pcgen_chgflw_way_pred` |
| 8 | `ifctrl_pcgen_chgflw_vld` | `ifctrl_pcgen_pcload_pc` | `ifctrl_pcgen_way_pred` |
| 9 | `ifctrl_pcgen_reissue_pcload` | 当前 IF PC | `ifctrl_pcgen_way_pred` |
| 无事件 | 无 stall 时顺序前进，否则保持 | 下一 16 B 块 | 行内 Way 规则 |

Way 编码为两位读使能：`01`/`10` 单路，`11` 双路，`00` 无可用 Way。关闭 `cp0_ifu_iwpe` 时强制双路。保留当前拍/延迟 stall、延迟重定向 Way、行内 Way 和 Way 不可用延迟标志。地址与重定向 Way 使用同一来源选择，IP 重发优先于 IP 改向。

该优先级是内部来源 mux。Excel P18 要求正常系统恢复为 RTU > IU；多个 IU 恢复还须在后端按 ROB 年龄选择。调试控制器只能在合法调试状态接受命令，VECTOR 的高优先级入口须由系统与普通恢复隔离，不能用本 mux 的位置替代这些约束。

## 2. 快速地址与最终 PC

`pcgen_icache_if_index` 和 `pcgen_debug_pcbus` 是 32 位快速地址；`pcgen_ifctrl_pc`、`pcgen_ifdp_pc`、`ifu_had_fetch_pc` 是寄存后的 IF PC。保留 C910 的时序分工：快速地址仅选择 IU、ADDRGEN、IB、IP 重发、IP 改向、L0 早期提示，默认使用顺序/IF 重发地址；调试、VECTOR、RTU 在最终 PC 路径覆盖它。

当 `pcgen_ifctrl_reissue=1` 时，**当拍快速阵列结果不能作为新目标的有效数据**。IF 控制器必须取消旧结果，随后用 `ifctrl_pcgen_reissue_pcload` 对已保存目标重新访问；请求被阵列仲裁阻挡时继续保持重发，不能无条件下一拍前进。PCGEN 不自行实现这些 IF 有效位或重发 FSM。

例：IF PC 为 `0x1000`，stall 有效，RTU 同拍恢复到 `0x100c`：

1. 快速地址仍可为 `0x1010`，`pcgen_ifctrl_reissue=1`，流水取消生效。
2. 时钟沿后 IF PC 为 `0x100c`，不能转发刚读到的 `0x1010` 数据。
3. IF 控制器发出重发，快速地址变成 `0x100c`，PC 保持，重新读取 `0x1000` 所在块。

`ifctrl_pcgen_chgflw_no_stall_mask` 只用于提前地址/时钟提示；实际接受事件是 `ifctrl_pcgen_chgflw_vld`。后者有效时控制器应同时给出前者，但仅早期提示有效绝不更新为 L0 目标，也不作为预测消费。

## 3. ICache 与预测器接入

十二个 `pcgen_icache_if_*` 端口与现有 `rv32_ifu_icache_if.v` 名称、方向和位宽匹配。该模块是底层同步阵列接口，仍需要 IF 控制器解决与 refill、维护、IPB 的端口仲裁及请求有效性；PCGEN 不取代阵列仲裁。

`rv32_ifu_icache_top.v` 则已经封装独立的 lookup/ready 控制器。若选用该顶层，未来 IF 适配层应将 IF PC/Way 转为 `lookup_*` 事务，并按接受结果产生 stall；**不能同时让它与 PCGEN 的原始阵列控制争用一份阵列**。本次没有把两套调度方式直接拼成 IFU。

ICache 位域为 set=`PA[14:6]`、block=`PA[5:4]`、Tag=`PA[31:15]`。顺序 tag 请求在快速地址进入 64 B 行首时产生；重定向另有 tag 请求路径。

现有阵列保留的 bank 编号与 RV32 word 顺序相反：

| 物理 bank | Data 位域 | 指令槽 |
|---|---|---|
| bank0 | `[127:96]` | word3 |
| bank1 | `[95:64]` | word2 |
| bank2 | `[63:32]` | word1 |
| bank3 | `[31:0]` | word0 |

只对**赢得仲裁的 IP taken 改向**且 taken PC 与改向 PC 一致时裁剪前缀 bank。例如入口 word2 时打开 bank0/1，关闭 bank2/3。更高优先级来源及 IP 重发读取全部 bank，不得继承被压过的分支掩码。顺序数据请求仍可打开全部 bank；bank 裁剪是优化，IP 仍必须生成指令槽有效掩码。双路真实 SRAM 联合测试覆盖全部四种入口和两路选择。

预测器索引接口有明确例外：

- `pcgen_bht_ifpc = IF_PC[7:1]`：既有 BHT leaf 的半字编码索引，不是完整 PC；删除 H0 后无需独立保存一份修正后的 BHT PC。
- `pcgen_bht_pcindex` / 兼容输出 `pcgen_btb_index` 为快速地址 `[13:4]`；BHT 顺序翻页提示检测 IF PC 与顺序地址的 bit7 翻转。
- `pcgen_sfp_pc = IF_PC[20:4]` 为索引。L0 的两个 PC 输出已扩为完整字节地址。
- 新 `rv32_ifu_btb` / `rv32_ifu_l0_btb` 接受完整字节地址，不能将兼容的 10 bit BTB 索引当成它们的 `lookup_pc`。
- `rv32_ifu_bp_top` 目前从其 `if_pc` 自行产生 BHT 索引；完整接入须统一该顶层与 PCGEN 的 SRAM 请求/响应拍，不能只连接 `chgflw` 就认为阶段已经对齐。
- short、gateclk、BHT 翻页及 L0 候选提示都不是握手。预测、历史追加和更新必须由有效推进事件记账。

## 4. 分级取消

保留 C910 的 IF cancel、IF→IP pipe cancel、IP cancel、IP→IB pipe cancel、IB cancel、ADDRGEN cancel、IBUF/LBUF flush 之间的区别。

| 来源 | 主要取消范围 |
|---|---|
| IF L0 | 更新下一路径，保留产生预测的当前块和较老流水 |
| IF 重发 / IP 重发 | 取消 IF 当前无效访问；IP 重发不自动清掉较老 IB/IBUF |
| IP 改向 | 取消 IF；IF→IP 边界结合 `ipctrl_pcgen_if_stall` 决定有效前缀保留 |
| IB 改向 | 取消 IF/IP；IP→IB 边界结合 `ibctrl_pcgen_ip_stall`，保留较老 IBUF |
| ADDRGEN 校正 | 取消年轻 IF/IP 边界，保持较老 IB/IBUF；ADDRGEN 自身收到 cancel |
| IU / RTU / VECTOR / 调试装载 | 全部年轻前端域，包括 IBUF 和 LBUF |
| `rtu_ifu_flush` / 调试状态上升沿 | 清对应前端域；单独 flush 不虚构恢复地址 |
| `lbuf_pcgen_vld_mask` | 提前取消 IF→IP、IP→IB 管线有效位 |

调试状态上升沿仅产生一拍取消，持续 `rtu_ifu_dbgon` 不会每拍重复 flush。RTU flush 与恢复地址按 Excel 由系统同拍提供。

`pcgen_l1_refill_chgflw` / `pcgen_ipb_chgflw` 保留原始改向通知，包含 L0、重发等事件，**不是全局清空许可**。不能直接把它们连到封装 Cache 的 `cancel` 并无差别丢掉较老需求。IF 控制器应按流水归属撤销交付；已授权 BIU 事务继续排空，普通取消与维护阻止安装的区别由 Cache/回填控制承担。

## 5. 复位、调试与时钟边界

- PC 及辅助状态异步低有效复位为零。复位释放同步由系统负责。
- VECTOR 控制器应在复位释放时采样 `cp0_ifu_rvbr`，完成其入口职责后通过 `vector_pcgen_pc/pcload` 装载。本模块未重复实现 VECTOR 的 RESET/PCLOAD FSM。
- `vector_pcgen_reset_on=1` 时抑制普通步进和阵列请求，仍接受优先入口装载；直到 Cache/预测器等初始化完成，控制器才可解除停取并安排重发。
- `debug_pcgen_pcload` 应为 `had_ifu_pcload && ifu_had_cmd_ready` 对应的已接受事件，`debug_pcgen_pc` 来自该命令的 `had_ifu_pc`。本模块进一步要求 `rtu_ifu_dbgon=1`。调试 ready、IR 注入、排空和与维护/恢复的互斥仍由 DEBUG/顶层控制器实现。
- `cp0_yy_clk_en=0` 停止普通步进/阵列请求，但重定向仍可保存到 PC。协议仍要求系统不要在未完成事务、恢复或维护时关闭系统时钟。
- `cp0_ifu_no_op_req`、IB 反压、Cache 仲裁、LBUF 等停取条件由 IF 控制器汇总为 stall，不将 `clk_en` 当请求 valid。
- 使用功能时钟和显式寄存器使能；没有添加物理 ICG 实例，也没有新增无用途的 scan/ICG 端口。ASIC 门控插入及扫描不属于本次验证。

## 6. 与 C910 的减法及必要修正

| 项目 | 本版处理 |
|---|---|
| RV64 / 半字地址 | 完整 PC 改为 32 bit 字节地址；块步进、行位域与索引逐项换算 |
| MMU | 删除全部 MMU 请求/VA/abort，以及 `if_pc_high_spe` 状态 |
| RVC / H0 | 删除 H0 输入和 BHT 前一半字块修正；合并重复 BHT PC 状态 |
| 旧 RTU PC 广播 | 按 Excel `C910_Port_Map` 删除 `ifu_rtu_cur_pc/load` 及对应寄存器 |
| 旧系统输入 | `rtu_ifu_xx_dbgon` 改为接口表 `rtu_ifu_dbgon`；异常恢复使用 RTU flush/目标协议 |
| 调试输入 | 接收内部已接受命令，不把原始 HAD valid 当单拍事件 |
| IP Way 选择 | 修正原地址选择优先重发、Way 选择却优先改向的不一致 |
| L0 short | 最终 PC 只接受实际 valid；short 仅用于提前路径 |
| bank 掩码 | 对应真实阵列的逆序 bank 映射；只裁剪赢得仲裁的 IP 分支 |
| IU 恢复 | 按 v3.1 §4.5 将 IU 恢复纳入 LBUF flush |
| 时钟/初始化 | 抑制未启动阶段的顺序访问，保留重定向覆盖 stall |

以上包含语义适配和明确修正，不能宣称与 RV64 原模块逐周期等价。源文件哈希与改动范围见 [pcgen_source_manifest.json](pcgen_source_manifest.json)，可审查差异见 [pcgen_C910_delta.patch](pcgen_C910_delta.patch)。仅借用 `cci500_tt.v` 的代码组织风格；没有移入 ARM 功能代码或文件头。

## 7. 风格与验证

`g_mux/g_source/g_bit/g_term` 生成两条来源优先级和载荷选择网络；`g_bank` 生成四个 bank 控制；`g_flag/g_way_state` 生成重复寄存结构。所有组合逻辑为 `assign`。三类时序模板只有复位及 `else if (xxx_en) xxx_q <= xxx_nxt`，没有组合 always、过程式 for 或组合 reg。

独立编译清单：[pcgen_files.f](../rtl/pcgen_files.f)。在 `ifu_rv32i` 目录运行：

```powershell
python scripts/check_pcgen.py
python scripts/rtl_style.py --check
```

检查包括：

- Verilog-2001 编译和 Slang 展开，PCGEN 零错误、零告警。
- AST 检查生成结构、寄存器更新模板、无组合过程；检查格式及被删除端口。
- 与 Excel 核对 11 个公开端口，与 ICache IF 核对 12 个阵列端口。
- Python 行为模型按事件优先级与状态规则生成期望值，RTL 仿真逐拍在时钟沿前后对全部 51 个输出作四态比较。
- 12,398 个周期，包括 10,000 个固定种子随机周期；共 **1,264,596 次输出比较**。全部 1,024 种来源组合在 stall=0/1 下覆盖，另有入口槽、地址回绕、Way 保持/恢复、short-only、复位、调试沿和时钟许可测试。
- PCGEN 与真实 ICache IF/SRAM 联合仿真 **53 次检查**：两路 × 四入口，屏蔽前缀保持旧数据、有效后缀读取新数据、预码对应目标、IP 重发优先、RTU 快慢地址分离和重发后读到正确块。

测试源码：[pcgen_model.py](../tb/pcgen_model.py)、[tb_pcgen_array_body.svh](../tb/tb_pcgen_array_body.svh)。结果和编译/仿真日志在 `work/pcgen/`。控制激励是确定的 0/1，四态比较用于发现 X/不匹配，不是未知控制输入的形式证明。

现有 ICache 回归（9435 次检查、33×4 预码）及预测器回归（7124 / 15641 / 37164 次检查）亦通过。未进行综合、STA、形式验证或完整 CPU/IFU 流水集成验证。
