# RVV 逐指令跑通测试（`doc/v-instruction.md` 全集）

## 1. 范围

只测 `doc/v-instruction.md` 里实际列出的 **82 个助记符**（文档有笔误：LSU 段标题写 12、
实际列 18；mask 段标题写 3、实际列 8）：

| 组 | 助记符 |
|---|---|
| MULMAC (15) | vwmaccu/vwmacc/vwmaccsu/vwmaccus、vwmulu/vwmul/vwmulsu、vmul/vmulhu/vmulh/vmulhsu、vmacc/vmadd/vnmsac/vnmsub |
| ALU (35) | vadd/vsub/vrsub/vadc；vmax/vmaxu/vmin/vminu；vmseq/vmsne/vmslt/vmsltu/vmsle/vmsleu；vand/vor/vxor；vsll/vsrl/vsra/vssrl/vssra/vnsrl；vsaddu/vsadd/vssubu/vssub；vmv/vmerge；vsext.vf2/vf4、vzext.vf2/vf4、vnclip/vnclipu |
| PMTRDT (6) | vredsum、vwredsum、vredmax/vredmaxu/vredmin/vredminu |
| LSU (18) | vle8/16/32.v、vse8/16/32.v；vlse8/16/32.v、vsse8/16/32.v；vluxei8/16/32.v、vsuxei8/16/32.v |
| mask (8) | vmandn/vmand/vmor/vmxor/vmorn/vmnand/vmnor/vmxnor（`.mm`） |

`vsetvli/vsetivli/vsetvl` 只作为每条用例的前缀，不作为被测项。RTL 里其它指令
（VDIV/VREM/VAADD/VSLIDE/VIOTA/VID/浮点/Zvt …）**不测**。

## 2. 文件

| 文件 | 作用 |
|---|---|
| `catalog.py` | 用例目录（组 / 助记符 / 形态 / SEW / 寄存器 / 是否 store） |
| `gen_sweep.py` | 生成 `asm/rvv_sweep_*.S`；`--oracle` 时用 Spike 生成黄金值 |
| `run_sweep.py` | 跑 A910 整核，解析 `RVV_STATUS/RVV_PROGRESS/RVV_PHASE`，出逐指令表 |
| `manifest_*.json` | 每组：用例名、progress/phase/status 的绝对地址 |
| `asm/rvv_sweep_*.S` | 生成的自检汇编（黄金值已嵌在 `.data` 里） |

## 3. 命令

```bash
# 用 Spike 重算黄金值（只有改目录/需要重算时跑；运行期不需要 Spike）
make rvv-sweep-gen

# 全量：5 组，真实 vle 源数据
make rvv-sweep

# 计算类统一操作数变体（向量 load 未通时的 bring-up 手段）
make rvv-sweep-gen-unif
make rvv-sweep-unif

# 只跑一组 / 看逐条结果（只有组名时匹配该组所有批次: --only alu 匹配 alu_*）
make rvv-sweep RVV_SWEEP_ARGS="--variant unif --only alu --verbose"

# 生成时指定每批用例数 (默认 20, 避开已知 idu_accept_num/IBUF 长程序 bug)
python3 tests/rvv/gen_sweep.py --oracle --batch 20
python3 tests/rvv/gen_sweep.py --oracle --setup unif --batch 20
```

输出形如：

```
[alu] 100 cases -> FAIL  (PASS=0 FAIL=0 HANG=1 ENTERED=1 NOTRUN=98)
    HANG    [  1] vadd.vx e32
  ⚠️ progress 停在第 1 条, phase=被测指令; 之后 98 条没跑到
```

判定：

* `PASS`：该用例的 16B/64B 结果与 Spike 黄金逐字节一致；
* `FAIL`：跑完但结果不一致；
* `HANG`：progress 停在它上面（phase 0=setup/源装载，1=被测指令，2=结果落内存）；
* `ENTERED`：超时前已经进入过（它的比对在所有用例之后的 check pass 里，没跑到）；
* `NOTRUN`：没进入。

## 4. 生成/判定机制

每条用例的汇编：

1. **phase 0**：`vsetivli` + `vmv.v.i` 预置 vd 的整个 16B（tu/mu，尾部/被屏蔽元素确定），
   再装载 vs1/vs2（`vle` 或 `vmv.v.i` 常量）/ v0；
2. **phase 1**：被测指令；
3. **phase 2**：`vse32.v` 把 vd 组落到 `rvv_res[cid]`（store 类直接写 `rvv_mem[cid]`）；
4. **全部用例跑完后**统一做 **phase 4**：标量 `lw` 读回结果，与 `rvv_exp[cid]` 逐字
   `xor/or`，写 `rvv_status[cid]`，失败累加进 `a0`；
5. 末尾 `x17=93; ecall`（冒烟台的退出判据）。

为什么比对放在所有 store 之后：实测 `vse32` 之后**立刻** `lw` 会读到旧值（0），
隔约 8 条指令才稳定；两阶段写法让所有向量 store 都远早于标量读，避开这个
排序/转发窗口。

**黄金值**：`gen_sweep.py --oracle` 把同一份程序汇到 `0x80000000`、开头置
`mstatus.VS`、装一个 trap handler（跳过本 build 不支持的编码并记录），用
`spike --isa=rv32gcv --misaligned -d` 跑，`rs N -> pc 0 -> mem` 逐字读回
`rvv_res/rvv_mem`，再写回最终 `.S` 的 `rvv_exp`。最后用带黄金的版本再跑一遍
Spike，要求 `a0==0`（校验生成器自己的比较代码）。

Spike 踩过的坑（已固化在脚本里）：

* RV32 Spike 必须先置 `mstatus.VS=3`，否则所有向量指令 illegal；
* 向量访存要加 `--misaligned`（未对齐用例）；
* 这个 build 对 **SEW=8 的 vsext/vzext** 一律 illegal（e16/e32 正常）⇒ 这 4 条黄金
  用 Python 直接算（`manual_expected`）；
* `vwmaccus.vv` 在 binutils 2.43 里没有助记符 ⇒ 只测 `.vx`；
* 窄化（vnsrl/vnclip）的源 EMUL=2*LMUL ⇒ vs2/vs1 必须偶数寄存器；
* MAC 的 `.vx` 汇编语法是 `vd, rs1, vs2`（标量在前），与 `vadd.vx` 相反；
* 裸机程序必须 `-mno-relax`（没有 crt0 设 gp，`la` 会被松弛成 gp-relative）。

## 5. 2026-10-18 的 RTL 修复与当前结果

### 5.1 顶层编不过（已修）

提交里删了桥的 `idu_vec_src0_preg/wb`、`idu_vec_src1_preg/wb` 端口，但 `A910_cpu.sv`
仍在连 ⇒ `a910-elab` 四条 UPIMI。已删掉这 4 根连接和 4 个无用声明。

### 5.2 向量 load 的 miss 数据回不来（已修，两处）

1. `lsu_mshr.sv`：no-fill 向量读的 BIU AR ID 用了 `{2'b10, idx}`。但
   `ct_biu_read_channel` 按 **`rid[3]`** 分流（1→IFU，0→LSU）⇒ R 数据全被送到 IFU，
   MSHR 的 `rb_entry_r_id_hit` 永不命中。改成 `{2'b01, idx}`（LFB 是 `2'b00`，读侧
   `2'b01` 空闲）。
2. `lsu_mshr_entry.sv`：状态机的组合 always 敏感表漏了 `rb_entry_vec_rsp_grnt_x`，
   VEC_RSP 的出口条件永远不重新求值 ⇒ MSHR 表项收到数据后 `rb_entry_vec_rsp` 不撤，
   fill 只消费第一笔。已加进敏感表。

load 的 beat done（`ld_da_vec_done`）本来就是每拍非 restart 都发；hit 走
`ld_da_vec_rsp_vld`，miss 建 MSHR 后走 `rb_vec_rsp_vld`，fill 在
`ctx_pending==0 && ctx_outs==0` 时才回 RVV —— 与需求一致。

### 5.3 向量 store 死锁（已修：DC 入口仲裁）

根因不是 anchor pop 本身：标量 store（iid=44）在 **st AG→DC** 那一拍和向量 store
beat 撞在同一个 DC 槽，`st_dc` 的输入 mux 向量优先 ⇒ 标量请求被静默挤掉，LSIQ 表项
停在 `frz=1` ⇒ 年龄图不前进 ⇒ 后续向量 store 被 `lsiq_vec_old` 永久门住。

修法：`ct_lsu_vec_ls_fe.sv` 增加 `dc_deny`，授权后不再发固定单拍脉冲，而是
**pending 到标量 AG 不用 DC 的空拍**；`lsu_top.sv` 用
`dc_deny = dc_store ? st_ag_dc_inst_vld : ld_ag_dc_inst_vld` 驱动。标量流水线优先级
不变，向量请求只等待、不丢，也不会重复注入。

### 5.3b 向量 L/S 的 discard / 唤醒语义（2026-10-18 第二轮）

- **向量 load 被 SQ other/data discard**：不再 `ld_restart_imme`。DA 这拍既不
  done 也不 restart，fill 的 outstanding 保持；fill_id 记进被命中的 **SQ 表项**
  (`sq_entry_vec_wk_*`)，该表项 `data_set` 时用 fill_id 唤醒 fill。
- **`ld_da_sq_global_discard_vld`**：fill_id 记在 **SQ 顶层**
  (`sq_vec_global_wk_*`)，`sq_pop_depd_ff` 时唤醒。
- **rb/flb 地址冲突 discard (`ld_da_hit_idx_discard_req`)**：向量 load 现在也走
  LFB 冲突通路（不再强制另建 no-fill MSHR）；fill_id 记进 **LFB**
  (`lfb_vec_wk_*`)，linefill 数据回来 (`lfb_pop_depd_ff`) 时唤醒。
- 唤醒统一走 `lsu_top` 的 `ld_restart_any`（带 fill_id），FE 收到后清 outstanding、
  下一拍重发；没有 resource 类 stall 时不会误睡。
- **向量 store spec-fail**：`st_da_spec_fail` 时发 wb-cmplt + spec_fail
  (`st_da_wb_cmplt_req` 对向量只在 spec-fail 时为 1)，并通过
  `vec_st_spec_fail_vld/fill_id` 通知 `ct_idu_vec_ls_fill` **立刻释放对应 entry**；
  非 spec-fail 的向量 store 仍然**不发** wb-cmplt。
- 新增定向用例：`vle32.v dcache-hit`、`vle32.v sq-data-discard`、
  `vle32.v lfb-conflict`（都在 LS 组）。

### 5.3c 第二轮 RTL/用例修复（全部 181 条通过）

跑全量时暴露的 8 个问题与修法：

1. **标量 load 的写回被误标成向量**（`lsu_ld_wb.sv`）：`ld_wb_data_vec` 原来
   无条件取当拍 `ld_da_vec`。RB（miss 回填）写回那一拍若 DA 恰好在处理向量 beat，
   标量 load 会被标成 vec ⇒ `lsu_idu_wb_pipe3_wb_preg_vld` 被清 0 ⇒ 等它的标量
   指令永不唤醒（alu_0/1/2 卡在 check pass）。改成
   `ld_wb_da_data_grnt ? ld_da_vec : 1'b0`（RB 通路恒标量）。
2. **mask 指令的尾段没有 tail-undisturbed**：`ignore_vta` 在 VMAND 组被置 1 ⇒
   byte_type 把整条 VLEN 标成 BODY_ACTIVE，vl（按 bit 计）之后的位被写；同时
   `opr_byte_type` 的 EEW1 元素号按字节号算（应 `i*8`）。两处一起改后
   vmand/vmor/... 与 Spike 一致。
3. **标量 store 抢占 SQ 导致队头向量 store 死锁**（alu_4）：向量 store 的每个
   beat 要一格 SQ，年轻标量 store 先占满 8 格 ⇒ 队头 beat 永远 `sq_full`。
   在 `ct_idu_is_lsiq_entry` 的 `older_entry_rdy_mask` 里增加
   “更老的向量 store（`x_other_vec`）未 pop 时 store 表项不发射”。
4. **fill 的 context 序号回绕**（alu_4 第二轮）：`ctx_seq` 只有 5 位，
   29/30/31/0 回绕后“最老 store context”判反 ⇒ 最老 context 饿死。加宽到 16 位。
5. **vsext/vzext 非法**：DEC1 把 vtype.SEW 当成目的宽度，vf2 只认 SEW16/32、
   vf4 只认 SEW32 ⇒ 合法的 `vsetivli e8; vsext.vf2/vf4` 被判 illegal（bridge F1
   报异常、整核反复重启）。按规范改成“SEW=源宽度，EEW_vd=2/4*SEW”，EMUL 也按
   `EMUL_vd=2/4*EMUL_vs2`，uop 数同步。
6. **用例本身不合法**：`vnclip.vv e32->e16` 用的是 `vsetivli e32` —— 窄化指令的
   vtype.SEW 是**目的**宽度，这条实际要求 EEW64（后端不支持）。改成合法的
   `vnclip.vv e8`（源 e16→目的 e8）。e32→e16 已由 `vnclip.* e16` 覆盖。
7. **TB 直读 AXI 内存读不到 write-back dcache**（red 的 status[5]）：status 行被
   向量访存带进 dcache 后只更新脏行，内存仍是镜像初值 ⇒ 误判 HANG。生成器在
   收尾前顺序读 4KB 无关的 `rvv_sweep_area`，强制脏行写回；TB 退出后的等待
   从 500 拍加长到 5000 拍。
8. **索引向量访存地址算错**（ls_1 的 6 条）：
   * `vec_byte_addr` 对索引元素一律读 32 位（e8 时把 4 个索引字节拼成一个数），
     且 `elem` 公式在多 uop 时错、k≥12 会越界读成 X ⇒ fill 活锁（AXI 读握手 10 万次）；
   * **索引是字节偏移、不按元素大小缩放**（ei8/ei16/ei32 是索引宽度，数据宽度看
     vtype.SEW）——原式多乘了 `1<<sh`，e16/e32 读成“32 位连续 load”。
   * `idx_bit` 只有 6 位，k=8..15 被截断，元素 8..15 又读回 0..7 的地址。

### 5.4 当前 sweep 结果

`make rvv-sweep`（11 批，20 条/批）与 `make rvv-sweep-unif`（9 批）最终结果：

```
full: PASS=181 FAIL=0 HANG=0 ENTERED=0 NOTRUN=0
unif: PASS=146 FAIL=0 HANG=0 ENTERED=0 NOTRUN=0
```

标量回归：`a910-difftest-all` 里 44 项基础用例全 PASS（唯一 FAIL 是 coremark
默认 20 万拍上限、以及 RVV 用例——difftest 黄金模型本来就不支持 RVV）；
`coremark_i1` 用 `A910_DT_MAX_CYCLES=15000000` 复跑 PASS。

> 长直线程序仍按 20 条/批拆分（`batches.json`），避免踩已知的
> `idu_accept_num`/IBUF 长度问题。

## 6. 复现/定位

```bash
# 跑单组并打开 RVV 探针（VIQ issue / LSU RS / fill ctx / LSIQ old）
make a910-run TEST=rvv_sweep_red_unif MAX_CYCLES=50000 \
  A910_SIM_ARGS="+RVV_SWEEP +RVV_PROGRESS_ADDR=<m> +RVV_PHASE_ADDR=<m> \
                 +RVV_STATUS_ADDR=<m> +RVV_STATUS_N=6 +RVV_DBG"
# 地址从 tests/rvv/manifest_red_unif.json 取
```

探针是 `tb/a910/tb_a910_smoke.sv` 里 `+RVV_DBG` 门控的一段，平时不影响原有用例。

## 7. 逐条 difftest（2026-10-18 新增）

除上面的"程序自检 + 冒烟台"外，RVV 现在也能跑**提交驱动 difftest**：
`golden_model/` 里加了 RVV 架构模型，`tb/a910/tb_a910_difftest.sv` 逐条比对
每条向量指令的 vd 写回（寄存器 / 字节掩码 / 数据），标量比对不变。

```bash
# 主机侧先验证 C 语义（不需要 VCS/DUT）：20 个 bin 全部 a0==0
make gm-host

# 单个批次
make a910-difftest TEST=rvv_sweep_alu_0 A910_DT_MAX_CYCLES=600000

# 11 个 full 批次全量
make a910-difftest-rvv
```

当前结果（2026-10-18）：`gm-host` 20/20；`a910-difftest-rvv` 11/11 PASS。

注意：

- `a910-difftest-all` / `_wave` 现在用 pattern 跳过 `rvv_sweep_*`（它们属于
  `a910-difftest-rvv`，默认 20 万拍也不够）；
- `A910_cpu.sv` 的 `DBG_HOLD` 从 16 加到 32（只影响观察口），
  否则 mask 组一条 dcache miss 的 load 写回会落在窗口外；
- 生成器的 dcache write-back 扫描已从 `lw` 改成 `sw`（读数据本来就被丢弃）。

详见 `doc/rvv_difftest_zh.md`。
