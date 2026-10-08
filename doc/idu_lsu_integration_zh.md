# 同事的乱序 IDU / D-cache LSU 集成现状

记录 `origin/miniRV` 上两个同事交付物的接入状态、修过什么、以及**哪些还没验证**。
配套的 RTU 侧契约在 `doc/rtu_plan_zh.md`（§6 是跨人接口契约）。

| 提交 | 交付物 | 落位 |
|---|---|---|
| `0695964` idu and lsu | `RV32I-idu/` —— C910 移植的乱序多发射 IDU（重命名 + 发射队列 + PRF） | `mySoC/idu_c910/rtl/`（34 模块 + 补 1） |
| `26f5b06` lsu | `RV32lsu/` —— 自研 D-cache LSU（2 路组相联 / 32B 行 / 1·2·4KB 可配 + LFB/MSHR/VB/WMB/LQ/SQ） | `mySoC/lsu/rtl/`（33 模块 + 补 12）+ TB 在 `tb/unit/lsu/` |

`0695964` 里那个空的 `RV32I-LSU` gitlink（无 `.gitmodules`、commit 列取不到）
已在 `26f5b06` 被换成真目录，本次合并时清掉。

---

## 1. 最重要的一条：主构建**查不出**这两个模块的错

主构建里没有任何模块例化 `ct_idu_top` / `lsu_top`，而 VCS 只 elaborate **从 `-top`
可达**的层次 —— 它们只会被 "Parsing"，内部的端口连接错误（不存在的端口名 / 位宽不符 /
多驱动器 / 未驱动网）**一个都查不出来**。

这不是推测：把 IDU 的第一批端口错误修完之后，`make build` 依然 **0 error**，
而把它们真的例化一次后立刻报出 **10 个** `UPIMI-E`。

为此新增两个单元冒烟台（都在独立 BUILD_DIR，与主流程互不干扰）：

```
make idu-unit    # tb/unit/tb_idu_c910.sv   —— 把 ct_idu_top 真的例化一次
make lsu-unit    # tb/unit/lsu/tb_lsu_load_test.sv（同事自带）
```

⚠️ `tb_idu_c910.sv` 的 116 个端口连接是**生成的**
（`scripts/gen_idu_smoke_tb.py` 从 `ct_idu_top.sv` 的端口表生成）。
改了 IDU 顶层端口就要重跑那个脚本，否则 elaborate 报 "port not found"。

⚠️ **这两个台子都不是功能验证**：输入接常量 / 假 BIU，无自检。
它们的价值是"把 elaborate 错误逼出来"。
LSU 那个尤其要注意，见 §4。

---

## 2. `DCACHE_2KB` 是硬需求，不是优化开关

`ct_lsu_dcache_{data,tag,ld_tag,dirty}_array.sv` 里的阵列例化**整个**包在
`` `ifdef DCACHE_1KB / DCACHE_2KB / DCACHE_4KB `` 里，而 `data_dout` 这类输出 wire
**只由那些例化的 Q 驱动**。一个宏都不定义 ⇒ 阵列一片不例化 ⇒ 输出悬空（Z）、
**整个 dcache 读出来是 X**。不会报错，只是功能全错。

因此主 `Makefile` 里加了带配置戳的 `DCACHE_SIZE`（默认 2048，派生 `+define+DCACHE_2KB`），
`Makefile.verilator` 与 `make lsu-unit` 各自带上对应宏。
两处口径必须一致：`lsu_top` 的 `DCACHE_SIZE` 参数默认 2048 ↔ `DCACHE_2KB`。

### 12 个 `ct_spsram_*` 是补出来的

C910 开源交付里**没有**这 12 种几何（它由内存编译器生成，交付的是结构化展开到厂商原语
`fpga_ram` 的 `ct_f_spsram_*`，而 `fpga_ram` 本仓库没有）。按行为级补在
`mySoC/lsu/rtl/ct_spsram_<W>x<D>.sv`，端口与时序照 C910 约定
（`A/CEN/CLK/D/GWEN/Q/WEN`，三个使能低有效，`WEN` 是全数据宽写掩码，`Q` 同步寄存一拍），
与仓库既有先例 `mySoC/ifu_rv32i/rtl/rv32_ifu_spram.v` 逐条一致。

**已知差异**（写在每个文件头上）：C910 原模型会把地址锁存并且**每拍都更新 Q**
（CEN=1 时用锁存地址重读）；本模型只在 CEN=0 且 GWEN=1 时更新 Q，其余拍保持。
两者在"真读的那拍"逐位一致，差别只在未选中的拍上，且能避免无谓的 X 传播。
**若将来 dcache 出现疑似读到陈旧数据的现象，这是第一个要看的地方。**

---

## 3. 修过的硬错（都是"什么都没改，因为压根没编译过"）

### IDU

* **两处 copy-paste**：`ct_idu_top.sv` 里 `ctrl_id_pipedown_inst1/2_vld` 全接了
  `id_inst0_vld`；`ct_idu_ir_dp` 例化里 `dp_id_pipedown_inst1/2_data` 全接了 0 号。
* **12 处 `.forever_clk`**：子模块声明的是 `forever_cpuclk`（只有
  `ct_idu_ir_dp` / `ct_idu_is_ctrl` / `ct_idu_is_dp` 三个用 `forever_clk`），
  而顶层 `forever_clk` 这根网**从未声明也无人驱动**。
* **4 处不存在的端口**：`aiq/biq/md_dp_issue_entry` 不是被例化模块的端口
  （它们的口叫 `*_dp_issue_read_data`），且这 4 根网全文件只被引用那一次。
* **6 处模块名对不上文件名/例化名**（`rv32im_decoder` / `ct_idu_is_aiq0_entry` /
  `ct_idu_is_md0_entry` / `ct_idu_rf_pipe2_div_decd` / `ct_idu_rf_pipe6_br_decd` /
  `ct_rtu_expand_64`）—— 统一按"文件名 == 模块名"（仓库既有约定）改名。
* **缺 `ct_rtu_expand_32`**：`ct_idu_ir_rt.sv` 例化了 3 次，同事没把文件带过来。
  从 C910 原版补（`mySoC/idu_c910/rtl/ct_rtu_expand_32.sv`）。
* **`ctrl_xx_is_inst0_sel` 声明成 1 位**，却要驱动 4 个 `[1:0]` 端口 ⇒ 零扩展 ⇒
  `ct_idu_id_dp` 的 case 落 default ⇒ **整条 ID 数据路灌 X**。加宽到 `[1:0]` 即可，
  它本来就是 `ct_idu_is_ctrl` 的输出，不需要额外驱动。
* **`reg_read_data[0]` 双驱动**：0 号（x0）的读数据被一根 `assign` 硬接成常量，
  而 `generate` 循环又从 `j=0` 起、也例化了一个 0 号表项。**C910 原版的例化编号是
  `_reg_1 .. _reg_31`** ⇒ 循环应从 1 起。
* **SDIQ 的 read_data 字段偏移**：`ct_idu_is_sdiq_entry` 里那根
  `x_read_data[AIQ_SRC1_DATA:AIQ_SRC1_DATA-6]`（= 位 `[7:1]`）与
  `x_read_data[SDIQ_SRC0_VLD]`（位 6）**重叠**。偏移是从 AIQ entry 抄来的
  （AIQ 的 read_data 有 64 位，同样的写法不冲突），而 SDIQ 只有 8 位。
  按本文件自己的参数（`SDIQ_SRC0_PREG=5`）改成位 `[5:0]`，
  消费者 `ct_idu_rf_dp` 同步改成读 `[5:0]`（它原来读 `[7:2]`，会把 vld 位当 preg 最高位）。
* **`idu_div_dst_vld` 端口缺失**：顶层一直在连它，`ct_idu_rf_dp` 却没有这个端口
  （同事自己的分析工具也把它标成了 bogus）。内部其实早就算好了
  （`dp_ctrl_is_div_issue_dst_vld`，一根**没有任何消费者**的悬空线），补端口接出去即可，
  逻辑一行没动。

### LSU

* `lsu_top.sv` 给 `lsu_wmb` 连了一根 `.wmb_ce_create_same_dcache_line(...)` ——
  **端口不存在**（它的口叫 `wmb_ce_same_dcache_line`，而且是**输入**不是 CE 输出），
  那根网全文件只出现这一行、从未声明。同名概念在上面已经正确连过了，删掉这行。

### ⚠️ 一处影响了语义的归一（Phase 3/4 要回来处理）

`rtu_idu_flush_fe` / `rtu_idu_flush_is` 两个冲刷口统一成单个 `rtu_yy_xx_flush`，
涉及 `ct_idu_is_ctrl`、`ct_idu_is_pipe_entry`、`ct_idu_is_sdiq_entry` 三处
（外加把 `ct_idu_top` 里 `ct_idu_ir_ctrl` 那根**根本没接**的 flush 接上）。

理由：顶层端口表里**根本没有** fe/is，两处例化点传的本来就是 `rtu_yy_xx_flush`，
子模块 `ct_idu_dep_reg_entry` 也只有 `rtu_yy_xx_flush` 一个口。
前端/发射级分开冲刷（C910 有）是**要连同顶层端口一起加回来**的事。

---

## 4. 还没验证到的部分（务必别当成"已经好了"）

* **LSU 只验证到 elaborate**。它自带的 `tb_lsu_load_test` 是**空壳驱动**
  （无自检、假 BIU、只打波形），实测跑起来报
  *"Timeout waiting for first AR request —— Load instruction did not generate bus read request"*。
  是 TB 激励不足还是 LSU 有真问题，要等它接上真实总线（Phase 5）才能判。
* **同事那 5 个 TB 里 3 个编不过**（`.forever_clk` 接错、以及 `tb_lsu_load.sv`
  用的是旧版 `lsu_top` 的端口表），剩下 2 个能 elaborate 的都不能当回归。
* **store 路径零覆盖**：两个能跑的 TB 里 `idu_lsu_st_sel` 恒 0，从来没有 store 进过
  ST_AG/ST_DA/ST_DC/SQ/WMB，`biu_lsu_b_vld` 恒 0。
* **IDU 只验证到 elaborate + 上电 210 拍不炸**，一行功能都没测。
* **tag 阵列的位宽警告**：LSU 把这些线声明成 `LD_TAG_ARRAY_WIDTH`（2KB 档 = 46 位），
  却例化了名为 `32x54` 的宏 —— **宏容量大于实际使用**，`D/Q/WEN` 高位会被零扩展
  （写 0、读回来不用，无害）。C910 里也是"宏名 = 内存容量"这个惯例，
  所以模型按宏名给宽度是对的。已知、无害、记录在此。
* **两个交付物彼此就没对上**：LSU 是 **96 preg / LSIQ 12 项**，而 IDU 是 **64 preg / LSIQ 8 项**。
  ~~用户已定案：以我们这一代为准，IDU 扩到 96 / 7 位 + LSIQ 12 项（Phase 2）~~
  ⚠️ **2026-10-08 改判**：**不动 IDU**，改由 RTU 提供 **64 档**
  （`make ... PREG=64`，见 `doc/rtu_preg_size_config_zh.md`）—— 池子与 IDU 的 6 位 preg
  同宽，IDU 一行不改；LSU 那侧仍是 96（它自己带 `ct_rtu_expand_96`，与 RTU 的 96 档同源）。
  ⇒ "两个交付物谁迁就谁"这件事从"IDU 扩 96"翻成"RTU 可切 64"，代价与理由见那份文档 §3。

---

## 5. 下一步

| 阶段 | 内容 |
|---|---|
| Phase 2 | ~~IDU 对齐到 96 preg / 7 位 + LSIQ 8→12 项~~ ⇒ **改判：不动 IDU，RTU 走 64 档**（`PREG=64`）。剩下的活只有"把 IDU 的 RAT 表项时钟接上"（见 `doc/rtu_preg_size_config_zh.md` 与 `doc/idu_rtu_接口待办.txt` §4） |
| Phase 3 | 按 `rtu_plan_zh.md` §6.1 补三路派遣记录（pc/chk/flags/csr/dst_lreg/rf_we…）+ CSR 译码 + `chk` 随指令贯通重命名 |
| Phase 4 | RTU↔IDU 适配层（C910 词汇 ↔ §6 词汇）+ RTU↔LSU 完成口 5/6 接线；`mycpu.v` 用开关让新旧 IDU 可切 |
| Phase 5 | 多发射执行后端 + BIU/总线子系统（LSU 要 128 位 AXI 风格、三个主设备、外部仲裁）+ store 队列退休提交 |

Phase 1 的验收门（回归必须**逐位不变**，因为完全没碰现有数据通路）：

```
make build / make run-all                         48/48
CoreMark                                          11,438,398 拍 / 9,440,679 条（与改动前逐位一致）
make rtu-unit                                     ALL PASS
make idu-unit / make lsu-unit                     elaborate 通过
```
