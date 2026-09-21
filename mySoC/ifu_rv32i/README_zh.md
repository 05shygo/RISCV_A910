# RV32I / 无 MMU IFU：完整前端 RTL 集成初版 v0.2

2026-09-21 已补齐 IP/IB、ADDRGEN、PCFIFO_IF、IBUF/LBUF、独立 L1_REFILL/IPB/双 ID BIU、SFP、VECTOR/DEBUG 和维护序列器，并连接到 [rv32_ifu_top.v](rtl/rv32_ifu_top.v)。正式清单 [ifu_files.f](rtl/ifu_files.f) 包含 41 个 RTL 文件；顶层 179 个端口逐项匹配接口表。阶段职责、包格式、预测恢复、验证结果和接入限制见 [完整集成说明](doc/pipeline_zh.md)。

新增 RTL 遵守 `cci500_tt.v` 风格：重复结构 generate，组合逻辑 assign，时序仅复位与使能更新。六组完整顶层回归、流水/内存/SFP 定向测试及原预测器回归均已通过。这是可编译、可仿真的初版 IFU，不包含后端 PCFIFO/ROB/LSU，也尚未 CPU 提交差分、综合或 STA 签核。

2026-09-21 新增 **IFCTRL / IFDP**：[rv32_ifu_ifctrl.v](rtl/rv32_ifu_ifctrl.v)、[rv32_ifu_ifdp.v](rtl/rv32_ifu_ifdp.v)。按C910阶段分工，IF统一授权访问并保存载荷，IP负责汇总Tag命中、miss和Way重发；正式流水通过新增 `if_array` 使用原始阵列，独立 `icache_top` 不参与同一阵列调度。职责、预测恢复契约和验证见 [doc/if_stage_zh.md](doc/if_stage_zh.md)。清单为 `rtl/if_stage_files.f`，执行 `python scripts/check_if_stage.py` 验证。

2026-09-21 新增 **PCGEN 初版**：[rtl/rv32_ifu_pcgen.v](rtl/rv32_ifu_pcgen.v)，独立清单 [rtl/pcgen_files.f](rtl/pcgen_files.f)。按指定 `cci500_tt.v` 风格使用 generate/assign 和复位/使能寄存器更新。支持分级重定向、16 B 步进、Way 提示与分域取消；快慢地址、IF 重发、调试接受事件及接线边界见 [doc/pcgen_zh.md](doc/pcgen_zh.md)。执行 `python scripts/check_pcgen.py` 验证。

2026-09-21 新增 **ICache 初版**：入口 [rtl/rv32_ifu_icache_top.v](rtl/rv32_ifu_icache_top.v)，独立清单 [rtl/icache_files.f](rtl/icache_files.f)，裁剪、时序、IPB/维护接入边界及验证见 [doc/icache_zh.md](doc/icache_zh.md)。执行 `python scripts/check_icache.py` 验证。下面的预测器说明及其原文件清单仍单独有效。

此目录保留分支预测、Cache、PCGEN 和 IF 的独立回归入口，同时提供新的完整前端顶层。原 `../ifu/rtl` 和输入文档未修改；新顶层采用 RV32I/no-MMU 接口，不能作为同端口替换件直接替换 `ct_ifu_top`。

## 依据与版本选择

用户指定的 `RV32I_OOO_IFU_microarchitecture_spec_zh.md` 已在文件开头标为废止，并明确指向 `RV32I_C910_IFU_microarchitecture_spec_zh.md`。本版采用后者 v3.1 和 `RV32I_C910_IFU_interface_v1.1_noMMU.xlsx`；未采用旧稿的单级 BTB、bimodal、四路交付方案。

保留 C910 的 L0 BTB、主 BTB、Bi-Mode BHT、IND BTB、RAS 五部分。BHT/RAS/IND 基于原 RTL 定点修改；L0/主 BTB 因 word 槽、完整地址和 RAM 布局变化做了独立重排，**这两部分不是与原代码逐周期等价的机械裁剪**。

## 文件入口

| 文件 | 用途 |
|---|---|
| [rtl/rv32_ifu_bp_top.v](rtl/rv32_ifu_bp_top.v) | 预测子系统连接层；32 位字节地址、退休 valid 限定、初始化/预测器维护、恢复互锁 |
| [rtl/rv32_ifu_bht.v](rtl/rv32_ifu_bht.v) | C910 Bi-Mode 派生版：22 位 VGHR/RTUGHR、四项训练缓冲、原 hash/更新逻辑 |
| [rtl/rv32_ifu_ras.v](rtl/rv32_ifu_ras.v) | 12 TOP + 6 RTU 存储，字节 PC，协程提示、溢出及退休恢复修正 |
| [rtl/rv32_ifu_ind_btb.v](rtl/rv32_ifu_ind_btb.v) | 256 项，原路径 hash/退休路径/同步读，35 位完整目标项 |
| [rtl/rv32_ifu_btb.v](rtl/rv32_ifu_btb.v) | 512 行 × 4 word 槽，两组 Tag/Data bank、写缓冲和读出旁路 |
| [rtl/rv32_ifu_l0_btb.v](rtl/rv32_ifu_l0_btb.v) | 16 项 CAM，最早有效 word 槽、完整 Tag、目标/返回/Way 提示、定向失效 |
| [rtl/rv32_ifu_bp_decode.v](rtl/rv32_ifu_bp_decode.v) | RV32I 条件分支/JAL/JALR/AUIPC、x1/x5 调用返回提示 |
| [rtl/rv32_ifu_bp_target.v](rtl/rv32_ifu_bp_target.v) | 直接目标、RAS→IND→BTB 选择、NPC、未知/不对齐目标提示 |
| [rtl/files.f](rtl/files.f) | 13 个可综合 RTL 文件的清单；不依赖原工程宏、FPGA IP 或全 IFU |
| [doc/integration_zh.md](doc/integration_zh.md) | 内部接口、周期约定、维护/恢复与后端责任 |
| [doc/changes_zh.md](doc/changes_zh.md) | 逐模块减法、必要改造及与原版的差异 |
| [doc/verification_zh.md](doc/verification_zh.md) | 实际验证结果和未验证范围 |
| [doc/coding_style_zh.md](doc/coding_style_zh.md) | 按指定 `cci500_sf.v` 整理的编码风格、命名映射与复现方法 |

`bp_decode` 由正式 IP 数据通路四路实例化；IB 中的 ADDRGEN 对注册源包完成目标校正。每个预测快照随源包保存，在 IB 接受时与 IU 提供的 PCFIFO token 配对。`files.f` 仍只是预测子系统清单，整套 IFU 必须使用 `ifu_files.f`。

## 运行验证

在本目录执行（脚本亦支持从任意目录用完整路径执行）：

```powershell
python scripts/check_rtl.py
python scripts/run_tests.py
python scripts/check_pipeline.py
python scripts/check_memory.py
python scripts/check_support.py
python scripts/check_ifu.py
python scripts/check_completion.py
```

静态检查依赖 `pyslang`、`openpyxl`。仿真依赖 Icarus Verilog；脚本优先搜索 PATH，否则使用本次验证保留在 `work/tools/iverilog/app/bin` 的便携工具。可显式传入 `--iverilog PATH --vvp PATH`。脚本不自动安装工具。日志在 `work/`，该目录不是 RTL 交付内容。

重新生成 C910 派生文件及连接层：

```powershell
python scripts/derive_c910.py
python scripts/build_cluster.py
python scripts/rtl_style.py --check
```

生成器依赖 `pyslang` 和 Verible，自动应用指定的 CCI500 代码风格；工具查找与版本见 [风格说明](doc/coding_style_zh.md)。生成器会覆盖其负责的派生文件；修改这些模块时应同步修改生成器。L0、主 BTB、译码、目标选择、通用 RAM/时钟模型是手工文件，不会被覆盖。原文件 SHA-256 记录在 `doc/source_manifest.json`，派生差异记录在 `doc/C910_delta.patch`。

## 初版边界

- 正式顶层采用唯一 IFCTRL 阵列仲裁，IP 负责命中/Way/miss；独立 Cache 包不参与正式调度。已接入三路 IDU、两路 PCFIFO 和三路退休接口。
- LBUF 重放经正常 IP/BHT/IB 重新生成历史及 token；不复用上一轮动态记录，PCFIFO 限单路创建。跨行 Way 训练保守双读；LBUF/SFP 的适配边界见完整集成说明。
- **RAS 恢复采取保守策略**：正常推测 TOP 保存最近 12 项；恢复时只重新发布六项 RTU 备份能够证明有效的已提交后缀。更深返回回退 IND/BTB。这保留了 12+6 存储组织和延迟恢复协议，但不宣称已达到原设计全部恢复命中性能。
- L0 来源在 IFDP 保存；IP 真实译码定向失效、IB 注册目标校正和局部 GHR 修复均已接入。局部校正在 token 分配前完成，保留较老 IBUF；后端仍负责 token/ROB 生命周期及规定退休恢复协议。
- RAM 为同步单端口可综合行为模型，时钟单元沿用仓库的直通功能模型。尚未进行目标 SRAM 映射、综合、STA、功耗或 CPU 差分验证。

本目录遵循 Apache-2.0；派生文件保留原 T-Head 版权声明，许可证见 `LICENSE`。`work/tools` 的第三方验证工具遵循各自许可证，不属于本项目 RTL。
