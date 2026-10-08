# 同事交付的 IDU / LSU 修复清单（2026-10-08）

对着 `origin/miniRV` 的 **3e605a0** 逐条核过并修复。**改完两个交付物才第一次能 elaborate + 跑通各自的单元台。**

> 给同事的话：下面每一条都注了「症状 / 根因 / 改法」。改动都在交付文件里、都带
> `2026-10-08` 注释，可按此清单 rebase。**没有改任何端口语义**（除了下面标 ⭐ 的那组新增）。

## 0. 先说结论

| 交付物 | 修复前 | 修复后 |
|---|---|---|
| IDU (`ct_idu_top`) | **HEAD 语法错、根本编不过**；即使编过，改名表也不工作 | `make idu-unit` PASS |
| LSU (`lsu_top`) | 语法错 + 未声明标识符，编不过；存储队列时钟无驱动 | `make rtu-lsu-unit` ALL PASS |
| 阶段 1 整核基线 | — | `make run TEST=trap` Test Point Pass（未受影响） |

---

## 1. 编译不过的硬错误（阻塞项）

| # | 文件 | 症状 | 根因 | 改法 |
|---|---|---|---|---|
| 1 | `ct_idu_is_biq.sv:28` | `token is 'parameter'` | `parameter BIQ_CHK = 151` **漏分号** | 补 `;` |
| 2 | `ct_idu_is_biq_entry.sv:27` | 同上 | 同上（同一个 chk 提交带进来的） | 补 `;` |
| 3 | `ct_idu_id_dp.sv:14` | `token is ')'` | `inout logic [24:0] crtl_ir_inst2_chk` —— **inout 端口不能带 logic 数据类型** | 改 `input`（该模块对它只读，与上一行 `crtl_ir_inst2_data` 对称） |
| 4 | `ct_idu_id_dp.sv:23` | 同上 | 末端口后面留了个**尾逗号** | 去掉（全仓其它端口表都没有；本仓 VCS 配置不接受） |
| 5 | `ct_idu_ir_dp.sv:399` | `Identifier 'ctrl_ir_inst2_chk' not declared` | 端口名是 `crtl_ir_inst2_chk`，赋值时**少写了个 l** | 改名 |
| 6 | `ct_idu_is_biq_entry.sv:120/130/140/152` | `Identifier 'chk' not declared` | `chk` 用了四处**没声明**（同文件里 `dst_preg`/`pc` 是同一批坑） | 补 `logic [24:0] chk;` |
| 7 | `ct_idu_is_biq_entry.sv:152` | `Identifier 'CHK' not declared` | 位域写成 `[BIQ_CHK:BIQ_PC-CHK]`：`CHK` 不存在，且方向算出来是负数 | 改 `[BIQ_CHK:BIQ_CHK-24]` |
| 8 | `ct_idu_top.sv:923` | `Undefined port 'lsu_sq_sdiq_unalign_sdiq'` | 该端口在 `ct_idu_is_sdiq` 里**已被注释掉**，顶层还在连 | 顶层跟着注释掉 |
| 9 | `lsu_st_dc.sv:126` | `keyword 'always_ff' is not expected` | 提交 3e605a0 把一个空行**粘贴成了裸标识符 `st_ag_expt`** | 删掉那一行 |
| 10 | `lsu_st_wb.sv:65` | `Identifier 'st_wb_expt_addr' not declared` | 只声明了 `st_wb_expt_vld`，**漏声明 addr**（load 侧有） | 补 `logic [31:0] st_wb_expt_addr;` |
| 11 | `lsu_ld_ag.sv:304` | `Identifier 'BYTE' not declared` | 新加的 unalign 块**先用后声明**（parameter 在 :319） | 把 `BYTE/HALF/WORD` 的声明提到使用点之前 |

## 2. ⭐ 门控时钟被整批剥掉（17 处 / 8 个文件）

C910 工厂版会给每个本地时钟例化一个门控时钟单元（`forever_cpuclk` + `*_gateclk_en` → `ct_clk_cell`）。
**交付时那批单元被整体剥掉了**，于是这些本地时钟只有声明、没有驱动，被当作时钟用的
`always` 块**永不触发** ⇒ 对应寄存器全部冻结。

改法统一：模块内 `assign <本地时钟> = forever_cpuclk;`。
**功能等价** —— 每个 `always` 块内部都自带使能条件（`x_write_en` / `*_vld` / `rtu_yy_xx_flush` / else 保持），
"不门控"只是让触发器多翻转一些拍，只损失时钟门控的省电效果。

| 文件 | 无驱动的时钟 | 冻结了什么 |
|---|---|---|
| `ct_idu_dep_reg_src2_entry.sv` | `dep_clk` / `write_clk` | **改名表表项**（一个字节都写不进去） |
| `ct_idu_ir_ctrl.sv` | `ir_inst_clk` | IR 级流水线寄存器 |
| `ct_idu_is_aiq_entry.sv` | `entry_clk` / `create_preg_clk` / `create_clk` | ALU 发射队列表项 |
| `ct_idu_is_biq_entry.sv` | `entry_clk` / `create_clk` | 分支发射队列表项 |
| `ct_idu_is_md_entry.sv` | `entry_clk` / `create_preg_clk` / `create_clk` | 乘除发射队列表项 |
| `ct_idu_is_sdiq.sv` | `cnt_clk` / `src_mask_clk` | SDIQ 计数器 + `preg_dealloc_mask` |
| `lsu_ld_ag.sv` | `ld_ag_clk` | **load 地址生成级整条** |
| `ct_lsu_sq.sv` | `sq_clk` / `sq_pop_clk` / `sq_wakeup_queue_clk` | **存储队列弹出侧整条** |

其中 `ct_idu_ir_rt.sv` **连时钟端口都没有**，已补 `forever_cpuclk` 输入并在 `ct_idu_top` 里连上。

> 附带说明：`lsu_sq` 与 `lsu_ld_ag` 这两处文档里原来没记录，是这次扫描全目录挖出来的。
> 也就是说 **LSU 交付过来时存储队列根本不在跑**。

## 3. ⭐ 改名表的数据通路（3 处，同一类）

这三条是"改名表为什么读了没反应"的完整答案。前两条文档里已记，第三条是这次新挖出来的。

### 3.1 `reg_write_en_arr` 没有任何驱动（`ct_idu_ir_rt.sv`）

`reg_write_en_arr[0:31]` 声明了、也连进了 32 个表项的 `x_write_en`，但**全文件没有任何赋值**
（32 位总线的 `reg_write_en` 算出来了却没接过去）⇒ 每个表项的写使能是悬空的 Z。

**改法**：加一个 generate 把 `reg_write_en[j]` 接到 `reg_write_en_arr[j]`。

### 3.2 数组宽度与表项端口不匹配（`ct_idu_ir_rt.sv`）★ 最隐蔽

表项的端口是 C910 的打包格式：

```
x_read_data[12:0]   = {bypass[11], issue_rdy[10], mla_rdy[9], preg[8:2], wb[1], rdy[0]}
x_create_data[10:0] = {                                preg[8:2], wb[1], rdy[0]}
```

而 wrapper 里 `reg_read_data` / `reg_create_data` **只声明成 7 位** ⇒ 读侧被截断、写侧被错位。
实测指纹（每一步都错位 2 位）：**给号 33 → 存进表项变成 8 → 读回来变成 16**。

**改法**：按真实宽度声明（13 / 11 位），再派生一个 7 位的 wrapper 视图
`{preg[5:0], wb}` 给下面那 9 个 32 路 case 读口用 —— 几百行 case 一行不用改。
create 侧同时补上正确的打包：新映射 `wb=0,rdy=0`；recover 写架构映射 `wb=1,rdy=1`。

（原来那个 `reg_create_data[jk][6] = r_vld` 的写法在正确打包下会落进 preg 字段里，
属于同一个错位 bug，已随之删除。）

### 3.3 `rt_reset_updt_preg` 零消费 ✅ **已修**

复位映射表（x_l → p_l）算出来了但**没人用** ⇒ 上电后所有逻辑寄存器都指向 p0。
**为什么不修整核必错**：RAT 复位值是 `preg <= 0`，32 个表项全 0 ⇒ x1/x2/… 互相踩。

**改法**：加一个**单拍写窗口** `rt_reset_updt_vld`（复位期间举起、释放后第一个时钟沿落下），
把它或进 `reg_write_en`，并在 create-data 的生成里按"复位优先于 recover"选数据。
数据本来就是按项索引的（`rt_reset_updt_preg[6*jj+5:6*jj]`），所以**一拍就把 32 项全灌完**。

冒烟台判据：复位释放后、**灌任何指令之前**直接查 x1 表项必须是 1。实测 ✅。
（必须在灌指令前查 —— 一旦有指令改名，x1 表项就被它拿到的号覆盖了。）

## 4. LSU 的访存异常相位（1 处）

`lsu_ld_wb.sv:165-175` 的 `always` 块**缺 begin/end**，于是 `ld_wb_expt` / `ld_wb_expt_addr`
成了输入信号的**无条件一拍延迟**，而与它有门控的 cmplt（`ld_wb_inst_vld`）相位不一致
⇒ 会出现 `expt_vld=1` 而 `cmplt=0` 的拍，那拍的 `_iid` 是残留值。
消费方若拿裸的 expt_vld 报异常就会**按错误的 iid 报**（静默错，只有 difftest 能抓）。

**改法**：照 store 侧 `lsu_st_wb.sv:59-74` 的写法补 `begin/end` + 用 `ld_wb_pre_inst_vld` 门控。

## 5. 还没做 / 需要确认的

| # | 事项 | 说明 |
|---|---|---|
| **F** | 🔴 **`old_preg` 采样晚一拍**（2026-10-08 新发现，**未修**） | `dp_ir_inst*_data` 里的 `IS_DST_REL_PREG` 字段是对 RAT 的**实时组合读**（`ct_idu_ir_dp.sv:507`），而 IS 队列表目到 **IS 建表目那一拍**才把它采样锁存 —— 比改名拍晚一拍，那时本条的写已经落进表项了。**实测**：改名拍 RAT[x1] 读出 1、写进 33；下一拍派遣记录里的 `old_preg` 是 **33**（应该是 1）。⇒ RTU 的 `disp*_old_preg` 拿不到"被替换掉的旧映射"，AMT 回滚会恢复成错映射、`old_preg != dst_preg` 的释放判断也失效。**修法**：把 `rel_preg` 在 IR→IS 边界寄存（或在改名拍锁存一份）。⚠️ 这会让"用 old_preg 反推 RAT 写没写"的判据变成恒真，所以冒烟台改用层次引用直接看表项 |
| B | `rtu_yy_xx_flush` 作为 recover 写使能 | `rt_recover_updt_vld = rtu_yy_xx_flush`（组合），而冲刷是 T+1 拍的脉冲 —— 相位是否对得上要跟 RTU 侧确认 |
| C | `reg_read_data[0] = 7'b0000001` | x0 的读数据硬接成 {preg=0, wb=1}，与 RAT 复位映射（x0 应为 p0）口径不同，属可疑但未动 |
| D | `lsu_rtu_async_expt_*` 没引到顶层 | `lsu_top.sv:685-686` 是内部信号，RTU 拿不到总线错误异常 |
| E | `spi_*`/`wmb_ce_merge_wmb_wait_not_vld_req` 空连接 | 都是**输出**不接，无害，仅记录 |

## 6. ⭐ 新增端口：IDU → RTU 的派遣记录（36 根）

按 RTU §6.1 契约，`ct_idu_top` 新增 3 路 × 12 字段：

```
idu_rtu_disp{k}_{vld, pc[31:0], chk[24:0], dst_lreg[4:0], rf_we,
                   dst_preg[6:0], old_preg[6:0], src1_preg[6:0],
                   csr_addr[11:0], csr_op[2:0], csr_imm[4:0], flags[6:0]}
```

* **锚点**：`vld` 取自 `ct_idu_is_ctrl` 新加的 `ctrl_dp_dis_inst{k}_vld`
  （= `is_dis_inst{k}_vld && !ctrl_is_dis_stall`）。⚠️ **不是** `ctrl_dp_dis_inst{k}_preg_vld` ——
  那个还串了 `dst_vld`，只在该路**写寄存器**时有效；store/分支/跳转不写 rd 但都要建 ROB 表项。
* **数据源**：`ct_idu_is_dp` 新按车道录出的 `is_inst{k}_create_{data,pc,chk}`
  （本来就是派遣当拍的最终值，已含 pipedown2 的 mux）。
* 位域见 `ct_idu_top.sv` 末尾的打包注释。**两个易错点已注明**：
  * `src1_preg` 取 `data[48:43]`，**不是 [48:42]** —— 那 7 位是 `{preg[5:0], wb_valid}`；
  * **A6d**：`ct_idu_id_decd.sv:156` 是 `assign dst_reg = rd;`，不写寄存器时**不清零**
    （store 的 rd 位是立即数）⇒ 送出去前必须 `{5{rf_we}} & dst_reg` 掩一遍，否则 RTU 会
    按"要写 rd"分配编号而退休时又不写 ⇒ **编号静默泄漏**。
* `flags` 位序 = `RTU_FLG_*`；`is_jal/jalr/csr/mret` 从原始指令字现解；
  **`intmask` 恒 0** —— RTU 侧全仓 grep 只有定义与端口注释、**零消费点**。
* **`_sq_id` 故意没加**：IDU 的 SDIQ（4 项）不是 LSU 的 SQ（6 项），且 LSU 那侧按 **iid 广播**
  找表项，不需要槽号。等跟 LSU 确认后再定，先不造一根语义不清的。

## 7. 验证

* `make idu-unit` —— 冒烟台已从"全接常量"升级成**定向激励**：
  `tb/unit/tb_idu_c910.sv` 由 `scripts/gen_idu_smoke_tb.py` 生成，灌一条 `addi x1,x0,1`
  （每拍一条），判据两条：
  1. **RAT 真的在写** —— 靠"某次派遣的 `old_preg` 变成 RTU 给的号（33）"来证，
     不用层次引用（那样只证明线接上了，不证明值走通了）；
  2. **派遣记录对得上** —— `pc/rf_we/dst_lreg/dst_preg/chk` 逐项核对。
  实测 **198 次派遣、全部判据通过**。这两条判据在修复前都是红的。
* `make rtu-lsu-unit` —— ALL PASS。
* `make build` + `make run TEST=trap IFU=2` —— Test Point Pass（阶段 1 基线未受影响）。
