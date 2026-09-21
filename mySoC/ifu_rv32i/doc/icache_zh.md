# RV32I / 无 MMU ICache 初版 v0.1

**2026-09-21流水集成决定**：正式PCGEN→IF→IP路径使用 `rv32_ifu_ifctrl` 统一授权、`rv32_ifu_if_array` 连接本包原始阵列，IP负责命中汇总/miss/Way重发。本文 `icache_top` 的封装接口继续用于独立Cache验证，不与正式IF调度器共用同一份阵列。具体职责和接线见 [if_stage_zh.md](if_stage_zh.md)。

日期：2026-09-21。按用户确认，采用 `../../ifu/doc/RV32I_C910_IFU_microarchitecture_spec_zh.md` v3.1 和 `RV32I_C910_IFU_interface_v1.1_noMMU.xlsx`。未采用已废止的 OOO 16 KiB 方案。原 `ifu/rtl`、规格和 Excel 均未修改。

本次交付 **ICache 子系统**，不是完整 IFU。六个 `ct_ifu_icache_*` 文件采用定点裁剪；外围握手、维护和需求回填控制为适配新接口增加的代码。原 `ct_ifu_l1_refill`、`ct_ifu_ipb` 没有被机械复制后冒充可直接接入的新模块。

## 文件与裁剪来源

| 交付文件（均在 `../rtl/`） | 原始来源 / 职责 |
|---|---|
| `rv32_ifu_icache_if.v` | 裁剪 `ct_ifu_icache_if.v`；保留阵列仲裁输入、Way 读使能、first/last 写协议、FIFO 和各路输出 |
| `rv32_ifu_icache_tag_array.v` | 裁剪同名 `ct_` 文件；512×37，两个 18 bit Tag/Valid 和 1 bit FIFO |
| `rv32_ifu_icache_data_array0/1.v` | 裁剪两个同名文件；每 Way 四个 2048×32 bank，保持原高低字拼接关系 |
| `rv32_ifu_icache_predecd_array0/1.v` | 裁剪两个同名文件；每 Way 2048×32，同步 SRAM |
| `rv32_ifu_icache_precode.v` | 4 个完整 RV32I word 的组合预码；替代原半字/压缩格式 |
| `rv32_ifu_region.v` | 静态物理区域组合译码，无翻译握手；默认全部拒绝 |
| `rv32_ifu_icache_top.v` | 新适配控制层：流水请求、Tag 比较、Way 重读、响应保存、需求回填、软件读和 Cache 局部维护 |
| `rv32_ifu_icache_biu.v` | 独立验证用 ID0 demand BIU 适配；不是完整 IPB/双 ID 仲裁器或 AXI 适配器 |
| `icache_files.f` | 上述十个文件和已有 `rv32_ifu_spram.v` / `rv32_ifu_clk_cell.v`，共十二个文件 |

具体减法：固定 ICACHE_64K 分支；去掉其他容量、ECC 和 MEM_CFG_IN 选择；PA 改为 32 bit 字节地址；Tag 从 28 bit 缩为 17 bit，Tag 行从 59 bit 缩为 37 bit；移除失效的 vector 注释及冗余 Predecode 写端口。ECC 未在这份目标规格中定义，不把本版描述为支持 ECC 的 Cache。

保留每 Way 的四个数据 bank、两组预码 SRAM、同步读、独立读使能、门控连接、FIFO 替换、软件读、IPB 查 Tag 以及关键块优先写回。没有把 FIFO 改为 LRU，没有因 RV32I 删除 Way 预测。

必要修正：软件读选中 Data/Precode 时同时使能对应预码阵列；末拍另加 `install` 资格，错误行不能置 valid；阵列选择默认值改为确定零并由外围保证互斥；性能事件关闭时不残留高电平。完整源文件 SHA-256、私有命名变化及逐行差异分别见 `icache_source_manifest.json`、`icache_C910_delta.patch`。

## 存储组织与代码风格

64 KiB、2 Way、512 sets、64 B/line、4×16 B/line。地址拆分：

```text
PA[31:15]   = tag，17 bit
PA[14:6]    = set，9 bit
PA[5:4]     = block，2 bit
PA[3:2]     = word，2 bit
PA[1:0]     = byte，合法取指应为 00
Tag row    = {fifo, valid1, tag1[16:0], valid0, tag0[16:0]}
Data row   = PA[14:4]
```

Data[31:0] 是低地址 word0；Precode[7:0] 对应 word0。每 word 的 bit0..7 分别为 condbr、JAL、JALR、call、return、FENCE、load、store。x1/x5 的协程 JALR 可同时设置 call/return。非法编码仍由 IDU 判断，本模块不产生非法指令陷阱；FENCE.I 不当作基线 FENCE。

遵循 `coding_style_zh.md` 指定的 CCI500 风格：Verilog-2001、ANSI wire 端口、两空格缩进、对齐声明、`u_` 实例、`g_` generate、`p_` 过程块。控制层 39 组寄存器分别给出 `assign xxx_en`、`assign xxx_nxt` 和仅含复位/使能存储的时序块。`rv32_ifu_icache_if.v` 进一步按 `cci500_tt.v` 改写，Way/bank、地址选择、性能寄存器均用 generate，组合逻辑全部 assign；详见下面的结构改写验证。SRAM 延用已有单端口可综合行为模型；ASIC SRAM 和真实 ICG 映射不在本版完成范围。

## 取指接口及周期

内部接口不是 Excel 的 IDU 三路接口，不可直接连 IDU。

| 通道 | 协议 / 载荷 |
|---|---|
| `lookup_vld/lookup_ready` | 接受 `lookup_pc[31:0]`、`lookup_way_pred[1:0]`；01/10 选 Way，00/11 双读；`cp0_ifu_iwpe=0` 双读 |
| `result_vld/result_ready` | 一次接受对应一次完整块响应；PC、128 bit Data、32 bit Precode、物理 word mask、fault/cause、Way、refill 来源 |
| `cancel` | 单拍取消所有尚未交付请求/响应；压过当拍结果交付、Miss 授权及新 lookup；已授权事务继续排空 |
| `way_reissue` | 命中未读 Way 时实际重新访问 SRAM 的脉冲；由本模块完成重读，不启动 refill |
| `refill_reissue` | 事务末拍之后一个周期的通知；让父级后续 PC 重新执行正常 lookup，不能重新交付已接受响应 |

在 E0 接受 lookup 并同步读 SRAM；E1 边沿锁存比较/数据结果，E1 后 `result_vld=1`。连续命中且下游 ready 时，可在 E1 接受下一 lookup，稳定吞吐为每拍一个 16 B 块。预测错 Way 增加一次同步读取。阻塞时 PC、Data、Precode、异常等保持，不使用继续变化的当前 PC。

`result_slot_mask` 保持物理位置，例如 PC=0x1034 时正常为 1110。故障时只标记入口 word，Data/Precode 为 0；cause=0 为地址不对齐，cause=1 为取指访问故障，故障地址就是 result_pc。IP/IB 负责按程序顺序去头、分支截尾、压紧为连续指令、以及三路交付/部分消费；本 Cache 接口仅进行整块交接，不能用 `result_ready` 表示只消费部分 word。

## 区域配置

`REGION_COUNT` 个表项以 packed vector 传入：`REGION_BASE` 每项 32 bit，`REGION_LIMIT` 每项 33 bit **不含末地址**，`REGION_ATTR` 每项 5 bit `{exec_allow,cacheable,bufferable,sec,spec_safe}`；表项0放最低位。33 bit 上界可表示 0x1_0000_0000。

集成者根据 SoC 内存图填写不重叠且 64 B 边界对齐的表项。默认上界为零，不开放任意地址；重叠命中也拒绝。请求接受时锁存属性。不可执行/不可安全推测的地址，即使 SRAM 中存在 Tag 也不能取得正常指令或发起总线读。非缓存但可安全整块读取的区域走单 beat，不适用于有副作用的 MMIO 指令执行。

测试使用的低地址 RAM、高地址窗口等仅在 testbench 中定义，未写死到生产 RTL。

## Demand refill / BIU / IPB 边界

`miss_vld && miss_ready` 接受一笔需求，载荷为原始 word PC、allocate 和已采样区域属性。该握手意味着下游 BIU 或 IPB 承担返回责任；首个返回最早下一周期接受。未握手请求可以由 cancel/维护撤销。

`refill_vld && refill_ready` 每次传送一个 128 bit beat，附 `refill_error/refill_last`。可分配行必须按 WRAP 顺序返回四拍，非分配只返回一拍：PC=0x1034 → 0x1030、0x1000、0x1010、0x1020。返回没有地址字段，次序必须由来源保证。

第一次写 victim 同时清 valid；末拍仅当整行无错且没有维护取消安装，才写 Tag/valid 并令 FIFO 指向另一 Way。普通命中不更新 FIFO。关键首块通过独立响应寄存器提前交付，尾拍不能覆盖它。首块出错产生该块的故障；后续 beat 出错只让行无效，不给已成功交付的首块追加故障。未消费首块受阻时仍能收齐其余三拍。

普通改向撤销 live 关联，允许旧无错行完成安装；维护则同时撤销安装资格。维护期间仍接收已授权返回，直到事务完成再访问失效阵列。本版采用显式 busy/live/install-killed/beat 状态组织，没有声称与原 C910 WFD/INV_WFD 编码及所有事件逐周期等价。

`refill_protocol_error` 为复位清零的 sticky 标志，检查 last 位置。提早 last 不允许发布短行，控制器仍等待约定拍数；违反长度协议后不承诺活性，正常 BIU 必须满足 Excel P05/P06。每次只存在一笔需求事务，不支持 hit-under-miss；首块提前返回后，新的 Cache 访问等待当前行尾拍结束。

`rv32_ifu_icache_biu` 将 miss/refill 接到 Excel 同名 ID0 BIU 引脚，保持 size=16 B、WRAP/INCR、cache/prot/domain/snoop/user 编码；Cache 功能关闭不改变区域的 cacheable 属性。ID1 返回不会推进或交付给 demand。内部 req/grant **不是 AXI ARVALID/ARREADY**。

完整 IFU 中应以 IPB/BIU 仲裁模块取代该独立适配器：先比较 demand 是否匹配在途/完整 IPB 行；匹配时内部授权并按需求 offset WRAP 回放，否则发 ID0；ID1 预取独立接收。此版本没有实现 `ct_ifu_ipb` 的请求机、行缓冲和双 ID 仲裁，不能宣称完成规格第12节。

已保留 `ipb_lookup_vld/ready/pa` 同步查 Tag 和可保持的 `ipb_result_vld/ready/hit/allowed` 响应。`allowed` 检查目标区域执行/缓存/推测权限，不负责自动产生下一行或检查触发 PC 的 4 KiB 窗口；后者由 IPB 负责。`ipb_invalidate` 在接受维护时通知清空 IPB，父级以 `ipb_idle` 保证旧事务/回放已排空。不接 IPB 的独立验证中 tie `ipb_idle=1`、`ipb_lookup_vld=0`。

## 初始化、维护、软件读与停取

冷复位异步清控制状态，随后扫描 2048 个 block 行，清 Data/Precode 并清对应 Tag/FIFO；完成前 lookup 不 ready。BIU 必须与冷复位协同清旧事务。当前为确定性初始化，不能把 2048 周期描述为仅需 512 周期的 Tag 扫描。

`maint_vld/maint_ready` 为 **Cache 局部命令**，接受 `maint_all/maint_pa`。优先级为 cancel > 维护接受 > 回填写 > 软件读 > IPB Tag 查询 > 取指；已有读结果先保存，不能被另一阵列拥有者覆盖。行失效只读 PA[14:6] 一个 set，比较两 Way 的完整 Tag 并清匹配项；全失效扫描 512 个 set。维护不修改其他有效行，行失效不改变 FIFO。

`maint_done` 单拍，仅在需求、IPB 和已接受软件读响应完成后给出 Cache 局部完成。父 IFU 仍需仲裁 LSU/CP0、保存应答归属/resume_pc、取消 IF/IP/IB/IBUF/LBUF 旧流并等待相关模块，再生成 Excel 的 `ifu_cp0_maint_done/ifu_lsu_icache_inv_done`；不能直接把本地 done 当作整个前端维护完成。CP0 op11 等不失效 Cache 的前端命令，也需由父级协调 Cache 事务/IPB 取消边界。

软件读八个引脚（含请求/响应握手等）保持 Excel 名称/位宽；kind00 返回 Data，kind01 返回 `{109'b0,fifo,valid,tag[16:0]}`，kind10 返回低32位 Precode，其余位零；kind11确定返回零。响应一直保持到 ready，后续维护不能把已接受的响应静默丢弃。

`cp0_ifu_no_op_req` 阻止新 lookup/IPB 查表，但已接受请求可以完成其需求总线事务，以免停在 LOOK→MISS 之间导致不能排空。`cache_no_op` 为本模块的保守空闲指示，包含未交付块/软件读响应；不直接冒充全 IFU 的 `ifu_yy_xx_no_op`，也不等同 ROB 已退休。Cache 开关、priv、安全属性配置变化仍须遵守 Excel 的停止/维护窗口约束。

## 复现与验证

在 `ifu_rv32i` 目录执行：

```powershell
python scripts/derive_icache.py
python scripts/build_icache_control.py
python scripts/check_icache.py
```

前三个生成/检查入口仅处理本次 ICache，不覆盖预测器。生成器依赖已有 `pyslang` 和 Verible；检查另用 openpyxl、Icarus/vvp。脚本支持从任意当前目录调用；工具优先 PATH，其次仓库已存在的 `work/tools`，不自动下载。

综合/集成清单为 `rtl/icache_files.f`。与预测器 `rtl/files.f` 同时编译时，共享 SRAM/时钟两个文件只列一次。现有预测器清单未混入 Cache 顶层。

验证实际通过：

- 全部十二个文件的 Verilog-2001 编译、Slang 展开和格式一致性检查；核对40处 Excel 端口方向/位宽。
- 16 个连续周期每周期接受一块并正确顺序返回；随机0..7周期结果反压。
- 四种块位置、入口 word mask、Way 预测错重读、FIFO 不随命中更新、同 set 不同 Tag、最高17位 Tag / set511。
- 每个 beat 分别出错、首块故障与尾拍错误隔离、关键块先行、未授权取消、授权后取消、cancel与首返回同拍。
- 回填中维护、末拍与维护同拍、IPB排空等待、软件读响应等待、全失效/物理行失效及不匹配Tag不误清。
- 非缓存/关闭Cache旁路、区域执行/推测禁止、未映射/不对齐、ID1返回隔离、last错误检测和已接受Miss遇到停取。
- 独立组合测试覆盖33种指令编码×4槽，包括JAL/JALR x1/x5、合法/保留分支、FENCE、RV32I load/store及被删除的扩展编码；验证区域默认拒绝、重叠拒绝、排他上界。

主仿真执行9435次检查，接受18个需求事务，交付76个块/故障响应。检查次数包括每拍互斥/维护断言，不代表9435种独立测试场景。结果与日志位于 `../work/icache/result.json`、`simulation.log`、`precode_simulation.log`。

Slang 无错误；ICache IF 结构改写后已显式整理运算括号，原31条括号警告消除，剩余6个显式不连接的重复阵列输出警告。Icarus 提示生产RTL没有timescale；测试平台明确指定1ns/1ps，生产逻辑无延时语句。未做形式等价、目标SRAM综合/STA/功耗或CPU级提交差分；不能依据本次测试宣称完整C910性能或完整IFU验证通过。

## ICache IF 的 generate / assign 改写验证

2026-09-21，按用户指定 `cci500_tt.v` 将 `rv32_ifu_icache_if.v` 改为全部组合电路使用 assign、重复电路使用 generate、寄存器仅复位/使能更新。模块外部接口和子模块源文件保留；两路相同的 Data/Precode 包装统一以 array0 类型在 `g_way[0/1]` 分别实例化，存储数目、位宽及独立读写行为不变。私有层次和控制连线转为向量/数组，见编码风格说明。

运行 `python scripts/check_icache_if_generate.py`：

- 对修改前独立快照做SHA-256校验，确保参考未随新RTL更改；全端口名称、顺序、方向、位宽一致。
- 结构检查确认只有一类性能寄存器时序模板，没有组合always、过程式for循环或组合reg。
- 再运行 `derive_icache.py`，确认所有RTL、源清单、差异补丁的内容哈希不变，避免重新生成退回展开式代码。
- 同激励比较所有公开输出、Tag端口、Way/bank读写及门控控制、地址选择和两位性能寄存器；使用四态 `!==`，不屏蔽未知存储输出。
- 覆盖16种地址拥有者组合、64种Way/bank选择组合、6000个固定种子随机周期（每种操作750次），末尾读回所有2048个block地址的两路Data/Precode和Tag。

共 **2,016,905次四态信号比较**，无差异。控制输入使用确定的0/1，不表示任意未知控制输入下的形式等价。原ICache主仿真9435次检查、33种编码×4槽预码测试、Verilog-2001编译、40项Excel端口核对和格式检查也重新通过。

修改前快照在 `work/icache_if_generate_before/`，结果与日志在 `work/icache_if_generate/`。主体生成模板为 `scripts/templates/icache_if_body.vh`；在模板中维护改动，然后运行原生成命令。原 C910 源哈希和完整差异补丁已同步更新。
