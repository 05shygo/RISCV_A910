# 向量 Load/Store 直连 LSU 设计需求

## 0. 文档说明

- 汇总日期：2026-10-18
- 本文汇总两轮需求。第二轮（修订版）与第一轮冲突时，以第二轮为准。
- 涉及模块：
  - IDU：`ct_idu_vecq`、`ct_idu_is_lsiq`、`ct_idu_is_lsiq_entry`、`ct_idu_is_dp`、`ct_idu_vec_ls_fill`
  - RVV：`RvvFrontEnd`、`rvv_backend`、`rvv_a910_bridge`
  - LSU：`ct_lsu_vec_ls_fe`、`ct_lsu_dcache_arb`、`lsu_ld_dc`、`lsu_ld_da`、
    `lsu_st_dc`、`lsu_st_da`、`lsu_lq`、`lsu_sq`、`lsu_mshr`

---

## 1. IDU / VIQ / LSIQ anchor

### R1.1 创建 VIQ 与 LSIQ anchor
IDU 的 IS 流水线在创建向量指令的 VIQ 表项时，如果该指令是向量 load/store，
还必须同时在 LSIQ 中创建一个对应的 anchor 表项。

### R1.2 anchor 永久冻结
该向量 LSIQ anchor 始终冻结，不允许通过 LSIQ 正常发射路径向 LSU 发出请求。

### R1.3 VIQ 记录 lsid
VIQ 表项必须记录该向量 load/store 所创建的 LSIQ anchor 槽号（`lsid`）。

### R1.4 lsid 全链路携带
`lsid` 必须随以下路径一路携带：

1. VIQ → RVV 发射；
2. LSU RS → `ct_idu_vec_ls_fill.sv`；
3. `ct_idu_vec_ls_fill.sv` → LSU 请求；
4. 用于 LSIQ anchor 的 pop/唤醒配对。

### R1.5 anchor pop 时间
该向量指令的**最后一个 uop 的最后一笔 beat** 走完 ld/st DA 流水线时，
向 LSIQ 发出 pop 信号。实现上复用：

```systemverilog
ld_da_idu_pop_entry[LSIQ_ENTRY-1:0]
```

---

## 2. `ct_idu_vec_ls_fill.sv` 的职责

### R2.1 自己计算访存地址
向量 load/store 的每一笔请求地址必须由 `ct_idu_vec_ls_fill.sv` 计算完成。

### R2.2 直连 dcache_arb，绕过 AG
地址请求直接发往 `ct_lsu_dcache_arb.sv`，**不经过** ld AG / st AG 流水线。

### R2.3 不再合成标量 beat
不再把向量请求拆成 LBU/LHU/LW、SB/SH/SW 等标量 beat 走标量 LSU 发射路径。

### R2.4 请求配对字段
每一笔请求必须携带：

- `lsid`：LSIQ anchor 槽号；
- `fill_id`：`ct_idu_vec_ls_fill.sv` 内部请求表项编号；
- `uop_idx`：该向量指令在 RVV 后端拆出的 uop 索引；
- `beat_idx`：该 uop 内不同 beat 的标签（由 fill 生成）。

### R2.5 `fill_id` 的语义
`fill_id` 只作为 `ct_idu_vec_ls_fill.sv` 与 LSU 之间请求/响应的配对编号，
不再充当 LQ/SQ 的 uop 标识。

### R2.6 `uop_idx` 的语义
`uop_idx` 必须是该条向量指令的 uop 索引（来自 RVV 后端 `uop_index`），
不是 fill 的请求编号。

### R2.7 `beat_idx` 的语义
`beat_idx` 是同一 uop 内不同 beat 的标签，由 `ct_idu_vec_ls_fill.sv` 生成。

### R2.8 同一 uop 的 beat 串行
同一 uop 的不同 beat 请求按顺序处理。
上一笔 beat 被 LSU 接收/完成之前，不得发下一笔；
返回结果按 `fill_id` 配对。

### R2.9 没有下一 beat 就不发
如果该 uop 已经没有下一 beat，则不得再发请求。

### R2.10 每个 beat 都建表项
创建 LQ entry 和 SQ entry 时，不判断是否为最后一条 beat；
**每一笔 beat 都必须创建对应表项**（零掩码 nop 请求除外）。

---

## 3. 向量 Load 路径

### R3.1 16B 对齐取数
向量 load 的请求地址按 16B 对齐块计算，一次取 16B 数据。

### R3.2 byte_vld
必须生成对应的 `byte_vld` 信号，随地址请求一起送到
`ct_lsu_dcache_arb.sv`。

### R3.3 不考虑标量访存宽度
向量 load 按 16B 块组织数据，不受 ld 流水线标量访存宽度限制。

### R3.4 多块 gather
一个向量 uop 需要多个 16B 块时，由 fill 逐块发请求，最后拼成该 uop 的
完整数据。

### R3.5 LD DC 创建 LQ entry
向量 load 请求进入 ld DC 流水线时，必须创建 LQ entry。

### R3.6 LQ beat 只在提交时 pop
向量 load 的 LQ beat 表项必须在**指令提交时**弹出。
不得使用 ld DA 完成信号或 RB/MSHR 完成信号提前 pop。

### R3.7 dcache miss 建 MSHR
在 ld DA 判断 dcache miss 时，创建 MSHR entry，通过 BIU 读取数据。

### R3.8 不得创建 LFB / 不得回填 dcache
向量 load 请求**不允许**创建 LFB，也不允许把读回的数据回填进 dcache；
只能读取内存数据。

### R3.9 数据直接返回 fill
MSHR 读回的数据直接通过接口返回给 `ct_idu_vec_ls_fill.sv`，
然后弹出对应的 MSHR entry。

### R3.10 下一 beat 的触发源
load 下一 beat 的触发源是**上一笔 beat 走完 ld DA 流水线**，
不是上一笔数据响应返回。

### R3.11 LQ 命中判据
向量请求检查 LQ 是否命中时，必须同时满足：

- `iid` 匹配；
- `uop_idx` 匹配；
- `beat_idx` 匹配。

---

## 4. 向量 Store 路径

### R4.1 访存宽度选择
向量 store 每一笔请求必须在 4B 对齐字内按最大连续宽度选择：

1. 同一个 32-bit 全部有效 → 32-bit store；
2. 否则有连续 16-bit → 16-bit store；
3. 否则 → 8-bit store。

最大访存宽度为 32-bit。

### R4.2 直连 dcache_arb
与 load 一样，store 请求也进入 `ct_lsu_dcache_arb.sv`，不经过 st AG。

### R4.3 ST DC 创建 SQ entry
向量 store 请求进入 st DC 流水线时，必须创建 SQ entry。

### R4.4 dcache miss 不得建 MSHR
向量 store 如果 dcache miss，**不允许**创建 MSHR entry。

### R4.5 提交后经 WMB 写回
dcache miss 的向量 store 表项在指令提交后，从 SQ 弹出到 WMB：

- 由 WMB 直接写入内存；
- 如果 dcache 命中，则写入 dcache。

### R4.6 store 数据进 SQ 要旋转
向量 store 的数据进入 SQ 时必须按地址完成旋转，保证字节落在正确的
内存字节道。

### R4.7 SQ beat 只在提交时 pop
与 LQ 一致，向量 store 的 SQ beat 表项只在提交时弹出。

### R4.8 store uop 完成条件
一个 store uop 必须在**所有 beat 都走完 st 流水线**后，
才能在 `ct_idu_vec_ls_fill.sv` 中完成并弹出。

### R4.9 SQ 命中判据
向量请求检查 SQ 是否命中时，必须同时满足：

- `iid` 匹配；
- `uop_idx` 匹配；
- `beat_idx` 匹配。

---

## 5. 中断、休眠与唤醒

### R5.1 按 `fill_id` 唤醒
向量请求在流水线中途被打断时，必须有针对
`ct_idu_vec_ls_fill.sv` 对应请求表项的唤醒信号。
参考标量 load/store 唤醒 LSIQ entry 的方式，但这里使用 `fill_id` 唤醒。

### R5.2 ld DC 时 LQ 满
ld DC 判断 LQ 满时：

- 该 uop 进入休眠；
- 等 LQ 有空闲位置后再唤醒。

### R5.3 st DC 冲突
与 st DC 发生冲突时：

- 立即唤醒/下一拍重试；
- 不进入长时间休眠。

### R5.4 ld DA 时 MSHR 满
ld DA 判断 MSHR 满时：

- 等到 MSHR 有空闲位置后再唤醒。

### R5.5 discard
请求被 discard 时，必须有对应的唤醒信号，使该请求可以重新尝试。

### R5.6 store 同理
store 侧的中断、休眠、唤醒遵循与 load 相同的原则。

---

## 6. 完成信号与写回

### R6.1 向量请求不发 wb cmplt
向量 load/store 的请求不得向 A910 RTU 发送 wb cmplt 信号。

### R6.2 cmplt 在 RVV 内完成
向量 load/store 的完成（cmplt）在 RVV 内产生：

- 指令提交时，将向量数据写入向量寄存器；
- 同时向 RTU 发出 cmplt。

RTU 收到该指令的 cmplt 后才退休。
LQ/SQ 的“提交窗口指示”（R7.3）只用于提前释放队列表项，不代表退休；
不得用它驱动 RTU 的退休/释放逻辑。

### R6.3 LSU 侧只负责数据与表项
LSU 侧只负责：

- 数据读写；
- LQ/SQ/MSHR 表项维护；
- 向 fill 返回数据/完成；
- 不再负责向量指令的最终完成。

---

## 7. 队列容量与配置

### R7.1 LQ 可配置
LQ entry 数量必须可配置，默认 **16**。

### R7.2 SQ 可配置
SQ entry 数量必须可配置，默认 **12**。

### R7.3 提交 pop（使用 RTU 提交窗口电平）
LQ 和 SQ 的向量 beat 表项在“提交”时 pop，但这里的提交信号不是等到真正退休：

- RTU 只要该向量指令进入头部 **3 条提交窗口**，就持续发出提交指示
  （电平，不是单拍退休脉冲）；
- 向量 LQ/SQ 表项用该窗口 iid 匹配后提前 pop；
- RTU 本身仍然只在收到该指令的 **cmplt** 后退休，不会因为窗口提交指示提前退休。

对应信号：

```systemverilog
rtu_yy_xx_win_valid[2:0]
rtu_yy_xx_win_iid0/1/2
```

### R7.4 死锁问题
通过上面的“窗口提交指示 + cmplt 退休”把 LQ/SQ 的容量释放与真正退休解耦，
用于解决 LQ=16 / SQ=12 且提交 pop 的容量死锁。
其余边界问题如果仍存在，后续单独处理。

---

## 8. 检查/验收清单

- [ ] 向量 L/S 创建 VIQ 时同时创建 LSIQ anchor。
- [ ] LSIQ anchor 永久冻结，不通过 LSIQ 发射。
- [ ] VIQ/RVV/LSU RS/fill 全链路携带 lsid。
- [ ] fill 自己算地址并直连 dcache_arb，绕过 AG。
- [ ] load 按 16B 对齐取数并生成 byte_vld。
- [ ] 每个 load beat 建 LQ entry，且只在提交时 pop。
- [ ] load miss 建 MSHR，不建 LFB，不回填 dcache，数据直接返回 fill。
- [ ] load 下一 beat 由上一 beat 走完 ld DA 触发。
- [ ] store 严格按 32/16/8 最大连续宽度选择。
- [ ] 每个 store beat 建 SQ entry，且只在提交时 pop。
- [ ] store miss 不建 MSHR，提交后经 WMB 写内存；命中写 dcache。
- [ ] store 数据进 SQ 时完成旋转。
- [ ] store uop 在所有 beat 走完 st 流水线后才完成。
- [ ] LQ/SQ 命中判据包含 iid + uop_idx + beat_idx。
- [ ] uop_idx 为 RVV uop 索引，fill_id 为 fill 请求编号，beat_idx 为 uop 内 beat 标签。
- [ ] LQ 满 / MSHR 满 / SQ 满时按 fill_id 休眠并唤醒。
- [ ] st DC 冲突和 discard 立即唤醒/重试。
- [ ] 向量 load/store 不发 wb cmplt。
- [ ] RVV 在提交时写向量寄存器并产生 cmplt；RTU 收到 cmplt 后才退休。
- [ ] RTU 输出头部 3 条提交窗口电平，向量 LQ/SQ 用它提前 pop。
- [ ] 提交窗口电平不参与 RTU 的 commit/pop_n，不导致提前退休。
- [ ] 最后一个 uop 的最后一 beat 过 ld/st DA 时 pop LSIQ anchor。
- [ ] LQ/SQ 容量可配置，默认 16/12。

---

## 9. 术语

| 术语 | 含义 |
|---|---|
| `lsid` | IS 为向量 L/S 创建的 LSIQ anchor 槽号 |
| `fill_id` | `ct_idu_vec_ls_fill.sv` 内部请求表项编号，用于请求/响应配对 |
| `uop_idx` | 向量指令在 RVV 后端拆出的 uop 索引 |
| `beat_idx` | 同一 uop 内不同 beat 的标签，由 fill 生成 |
| anchor | LSIQ 中对应向量 L/S 的冻结表项 |
| no-fill MSHR | 只读数据、不回填 dcache、不建 LFB 的 MSHR 表项 |
