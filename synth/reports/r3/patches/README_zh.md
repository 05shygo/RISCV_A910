# F1 前向链削级数: 4 处 bit-exact 改动 (待 VCS 判等)

对象: IFU=2 配置, **只碰 F1 前向链的逻辑级数**, 全部逐位等价 (下面逐条给等价性依据)。
补丁: `c1c2c3c4.patch` (对当前 miniRV 分支, +62/-32 行, 3 个文件)。

| # | 文件 | 改什么 | 为什么掉级数 | 等价性依据 |
|---|---|---|---|---|
| C1 | `rv32ifu2_tage.v` | 逐 slot 的 provider/altpred 选择: 去掉"3 位优先编码 `prov_sel/alt_sel` → `(ps-1)` 解码 → 4:1 mux"的往返, 改成逐级 one-hot 优先选择 | 编码+解码这一来回在综合后是 2 级 LUT; 直接优先选择只要 2 级 (LUT6 的 6 输入能吃下 4 个 hit + 4 个候选) | 优先级 h4>h3>h2>h1 不变; 无命中时 pp=t0_pred、pw=0、ap=t0_pred, 与原来 `ps==0` 分支逐位相同 |
| C2 | `rv32ifu2_ibuf.v` | lane 使能/`out_vld` 由 `acc_push >= k` 改成 `(push_num >= k) & (space >= k)` | `space` 只依赖寄存器 `cnt_q` ⇒ 这一半提前算好, 关键路径上只剩 push_num 侧 1 级比较 + AND | `acc_push = min(push_num, space)` ⇒ `min(p,n) ≥ k ⟺ p ≥ k ∧ n ≥ k` (整数恒等) |
| C3 | `rv32ifu2_top.v` | `want_cnt_raw = any_taken ? (taken_slot-pc_ofs+1) : (4-pc_ofs)` 改成 `(t0?1 : t1?2 : t2?3 : 4) - pc_ofs` | 去掉 `taken_slot` 的优先编码 (2 级) 与末尾的两路 mux (1 级) | 三个都没命中时 `taken_slot` 默认 3 ⇒ 原式的 `want_to_taken` 退化成 `4-pc_ofs` = `blk_left`, 两路本就同值; 且 `t0` 要求 `pc_ofs==0`、`t1≤1`、`t2≤2` ⇒ 结果天然落在 [1,4] |
| C4 | `rv32ifu2_tage.v` | `init_done` 门控从路径末尾 (`slot_pred = fpred_raw & init_done`) 提前到 `tb_hit` / `t0_pred` 两处 | 末尾那一级 AND 从关键路径上消失 (前两处都只剩 1 级且不在路径上) | 扫描期 hit 全 0 ⇒ anyhit=0 ⇒ fpred_raw 取 t0_pred, 而 t0_pred 也已门控 ⇒ slot_pred 逐位相同。仍是 AND 门控 (非三元), 保持原注释要求的 X 语义 |

## 实测 (影子 RTL 树, 与工程 run 同一流程)

| 配置 | 6.9ns | 6.5ns | 6.2ns | 最差路径级数 (6.9) | 500 条平均级数 |
|---|---|---|---|---|---|
| 基线 | +0.114 | −0.473 | — | 15 (6.755ns) | 14.1 |
| C1 | +0.242 | −0.151 | — | 13 (6.386ns) | 12.9 |
| C1+C2+C3 | — | −0.129 | −0.396 | — | 13.7~14.4 |
| C1+C2+C3+C4 | — | −0.233 | −0.149 | — | 13.5~13.8 |

注意: 单点 WNS 在 RTL 被扰动后有 ±0.2ns 量级的"布局运气" (pass 臂证明**同 RTL 同流程是逐位确定的**),
所以判据要看"最紧通过点"而不是单点差值 (bracket 扫描见 `logs/`)。

## 复现

```bash
# 影子 RTL 树 (仓库不动): /tmp/rtly = 拷贝 mySoC + vsrc + top_fmax.v, 打上本补丁
cd /tmp/rtly/synth && vivado -mode batch -source build_fmax.tcl -tclargs 6.5 impl
```

要落到仓库时: `git apply -p1 < c1c2c3c4.patch` (在仓库根目录), 然后跑 VCS 回归判逐位等价。
