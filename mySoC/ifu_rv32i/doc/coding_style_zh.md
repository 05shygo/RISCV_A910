# 分支预测与 ICache RTL 编码风格

完整 IFU 集成补充（2026-09-21）：本次新增 IP/IB/内存/支持/顶层共18个模块按用户最新指定 `D:\Project\bus\yh_xbar550-main\yh_xbar550-main\cci550\cci550_tablet\verilog\cci500_tt.v` 组织；重复电路使用 generate，所有组合逻辑 assign，59个时序模板只有复位与使能 `_q <= _nxt`。`scripts/check_completion.py` 对这些模块检查严格结构和生成可复现性。以下记录仍保留此前预测器移植的约定；原 BHT/RAS/IND 等内部组合过程未在本次全部改写。

日期：2026-09-21。适用于 `rtl/files.f` 中的全部 13 个模块。

同日新增的 `rtl/icache_files.f` 也采用本约定。ICache 控制层的39组寄存器全部分离 `_q/_nxt/_en`，派生阵列接口的性能事件寄存器也拆出下一值与使能；SRAM继续使用已有同步单端口存储模型。生成入口为 `scripts/derive_icache.py` / `scripts/build_icache_control.py`，验证入口为 `scripts/check_icache.py`，说明见 [icache_zh.md](icache_zh.md)。

按用户指定文件的代码组织与排版约定整理：

`D:\Project\bus\yh_xbar550-main\yh_xbar550-main\cci550\cci550_tablet\verilog\cci500_sf.v`

## 采用的约定

| 项目 | 本目录约定 |
|---|---|
| 语言 | Verilog-2001；ANSI 端口，显式 `input wire` / `output wire` |
| 文件结构 | 模块声明、局部参数、集中信号声明、函数、逻辑与寄存器更新、输出连接；用横线注释分隔 |
| 排版 | 两空格缩进；声明、赋值与具名端口连接对齐；默认行宽 100 |
| 寄存状态 | `_q` 后缀；原 `_pre` 下一值信号整理为 `_nxt`；保留已有 `_en` 使能命名 |
| 组合输出 | 过程块写内部组合变量，通过 `assign` 驱动输出 `wire` |
| 时序块 | `always @(posedge ... or negedge ...) begin : p_...`；保留各模块复位、清空、恢复、更新优先级 |
| 组合块 | `always @(*) begin : p_..._comb`；保留完整默认赋值及原组合算法 |
| 控制语句 | `if` / `else` 和循环体显式 `begin/end`；保留 `else if` 链 |
| 层次 | 模块实例 `u_*`，generate 块 `g_*`，过程块 `p_*`；使用具名端口连接 |

公共端口保留原名称，不统一增加参考文件的 `_i` / `_o`，以保持 Excel 接口和已有集成边界。内部信号只在含义明确时改名，例如 `vghr_reg → vghr_q`、`rtughr_pre → rtughr_nxt`、`x_bht → u_bht`。完整对应表见 `style_names.json`；波形脚本或使用私有层次路径的验证代码需相应更新。

这次只调整代码组织、命名和排版，不改变预测结构、表容量、读写时序或恢复算法。时钟、低有效复位等接口保留 C910 命名。C910 原有混合逻辑运算表达式保留，因此静态检查仍报告 39 项原优先级括号风格警告。

根据用户进一步明确的要求，`rv32_ifu_btb.v` 的 13 组寄存器全部拆出独立的 `assign xxx_nxt = ...` 和 `assign xxx_en = ...`。每个命名时序块只负责异步复位，以及在使能有效时执行 `xxx_q <= xxx_nxt`；计数、清空、有效位生成、命中及更新旁路选择全部由连续赋值实现。SRAM 端口的组合控制也独立赋值。此项进一步拆分目前覆盖主 BTB 模块，其他模块仍保持上一轮整理结果。

参考文件仅用于编码风格；没有移入其 snoop filter 逻辑或 ARM 文件头。C910 派生文件保留 T-Head/Apache-2.0 版权及许可声明。

## L0 BTB：CCI500 TT 结构风格

`rv32_ifu_l0_btb.v` 按用户新指定的 `D:\Project\bus\yh_xbar550-main\yh_xbar550-main\cci550\cci550_tablet\verilog\cci500_tt.v` 进一步改写。该要求在本模块优先于前面的通用风格约定：

- 16 个 CAM 项的比较、写入译码、有效位/标志/载荷存储，用 `g_entry` 统一生成。
- 4 个 word 槽的匹配和优先选择，以及各位编码/输出归约，用嵌套 `generate` 展开。
- 全部组合电路由 `assign` 驱动，没有组合 `always`、组合 `reg` 或过程式 `for` 循环。
- 寄存器使能和下一值在时序块外定义；时序块只进行复位与使能赋值。原来不复位的 src/dst/kind/ways 载荷仍只在使能时更新，`payload_en` 在复位期间为0；有效位保证未写入载荷不被消费，未额外增加载荷复位电路。

保留原优先级：查询先选最早 word，同 word 选最低项号；重复 PC 更新选最高项号；定向失效压过同拍写入的 valid，但不阻止原本允许的载荷更新。替换指针仍在更新未匹配时循环前进。公开端口和原状态数组名称保留；旧 `wr_index` 过程选择已改为连线网络。

复验命令：`python scripts/check_l0_generate.py`。脚本校验修改前快照哈希、公开端口、组合/时序结构，进行 Verilog-2001 编译及修改前后全输出/全状态差分测试。只参考 TT 的组织风格，未复制 ARM 功能电路或文件头。本文件为手工 RTL，现有生成器不会覆盖该结构。

## ICache IF：CCI500 TT 结构风格

`rv32_ifu_icache_if.v` 同样按用户指定的 `cci500_tt.v` 风格重构：Way 控制与阵列实例放在 `g_way`，每路四个 bank 控制放在 `g_bank`；高优先级地址选择的四个拥有者及每位归约由 `g_owner/g_index_reduce` 生成。性能 access/miss 的两份相同寄存结构合并为 `g_event`，只保留一份复位/使能更新模板。组合逻辑全部用 `assign`，没有组合过程块或组合 reg。

两个 Way 的 Data/Precode 包装模块经规范化名称后内容完全相同，因此在 generate 中各实例化两份 array0，存储仍完全独立。原 array1 文件保留，已有直接调用仍可使用。内部路径从 `u_icache_data_array0/1` 改为 `g_way[0/1].u_data_array`，预码对应 `g_way[0/1].u_precode_array`；性能状态改为 `event_q[1:0]={miss,access}`。外部端口不变，波形脚本若引用私有层次需调整。

地址选择保留 exact one-hot 的原行为：冲突选择仍输出零；没有把默认零的 case 改成有优先级的仲裁。Tag 的失效/first/last/install、独立 bank 读使能、软件读、门控提示和性能事件语义均保留。

生成器 `derive_icache.py` 从 `scripts/templates/icache_if_body.vh` 生成该模块的 TT 风格主体，并校验两个 Way 包装的一致性。后续修改主体应修改模板后重新生成；生成结果依然为可独立编译的 `.v`，不依赖运行时 include 模板。`python scripts/check_icache_if_generate.py` 检查结构、接口、生成幂等性及改写前后差分。

## PCGEN：CCI500 TT 结构风格

新增 `rv32_ifu_pcgen.v` 按用户指定的 `cci500_tt.v` 组织，优先采用全部组合 `assign`、重复结构 `generate`、时序块只复位/使能赋值的要求。两条来源选择网络使用 `g_mux/g_source/g_bit/g_term`；四个物理 bank 使用 `g_bank`，并显式对应已有阵列的逆序 word 映射；重复标志与 Way 寄存器使用 `g_flag/g_way_state`。PC 状态是独立的32位寄存器。所有 `_en`、`_nxt` 均在时序块外计算。

没有组合 always、组合 reg、过程式循环或时序块内的功能 mux；只保留三类寄存器更新模板。公开完整 PC 为32位字节地址，索引端口另有文档定义。该文件是手工 RTL，不由原生成器覆盖。`python scripts/check_pcgen.py` 检查风格结构、端口、行为模型及真实 ICache 阵列接线，详情见 [pcgen_zh.md](pcgen_zh.md)。

## IFCTRL / IFDP：CCI500 TT 结构风格

新增IFCTRL、IFDP和IF阵列连接层统一采用用户规定的全部组合assign、重复结构generate、寄存器仅复位/使能更新。IFCTRL以 `g_owner` / `g_flag` 生成仲裁及状态；IFDP以 `g_capture` 生成相同的stall快照/IP载荷寄存器，以 `g_way/g_tag_part/g_word/g_breakpoint/g_l0_entry` 生成比较和掩码；连接层以 `g_control` 门控全部阵列命令。IFCTRL手工维护，IFDP/连接层由 `build_ifdp.py` / `build_if_array.py` 维护。检查入口为 `check_if_stage.py`，详见 [if_stage_zh.md](if_stage_zh.md)。

## 生成与检查

在 `ifu_rv32i` 目录执行：

```powershell
python scripts/derive_c910.py
python scripts/build_cluster.py
python scripts/rtl_style.py --check
python scripts/check_rtl.py
python scripts/run_tests.py
```

生成器调用 `rtl_style.py`，使重新生成的六个 C910 派生模块及连接层自动遵守约定。手工模块可以用 `python scripts/rtl_style.py` 重新排版；已有风格标记的文件只执行排版，不重复重命名。

生成和风格检查依赖 `pyslang` 及 Verible。格式化器按 `VERIBLE_FORMAT` 环境变量、PATH、`work/tools/verible` 顺序查找；本次使用 `v0.0-4294-gc1d8f5e8`。固定该版本可复现排版。普通功能仿真不需要运行格式化器，BHT 参考测试端口提取需要 `pyslang`。

`work/style_before` 保留本次整理前的 13 个 RTL 快照。在运行功能测试后，可执行：

```powershell
python scripts/check_style_equivalence.py
```

它让修改前后模块接受同一组已有测试激励，比较所有预测子系统输出及译码/目标选择输出。检查采用四态比较，不屏蔽未知值差异；属于仿真采样一致性检查，不是形式等价证明。结果和基线 SHA-256 在 `work/style_equivalence/result.json`，详细范围见 `verification_zh.md`。
