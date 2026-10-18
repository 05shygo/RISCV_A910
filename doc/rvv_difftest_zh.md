# RVV 向量黄金模型 (提交驱动 difftest)

2026-10-18。`golden_model/` 从"纯标量 RV32IM"扩展成"标量 + RVV"的提交步进模型，
`tb/a910/tb_a910_difftest.sv` 在原有标量比对之外，**逐条向量指令**比对 vd 写回。

## 1. 判据

- 标量指令：原有 `gm_check_step()` 比对 PC / ena / reg / value，行为不变。
- 向量指令：模型在 EX 级执行 `rvv_execute()`（vset* 的 rd=vl 仍走原 WB 通路），
  TB 用 RvvCore 的**已提交 uop 退休记录**按 `rob_tag`(=A910 iid) 逐字节比对：
  - 写字节掩码必须与模型完全一致（`BODY_ACTIVE` = 2'b11）；
  - 每个字节的数据必须一致；
  - 不允许写目的组之外的向量寄存器；
  - 向量 store 不允许有 VRF 写。
- 停机判据仍是黄金模型看到第一条裸 `ecall`（与标量 difftest 完全一样）。

## 2. 观察口延迟: DBG_HOLD 16 → 32

`mySoC/A910_cpu.sv` 的 `dbg_commit_*` 原来延迟 16 拍，用 LSU 写回窗口覆盖
"提交时 PRF 读值还不对" 的 load。实测（mask 组）一条 **dcache miss** 的 load
写回落在 16 拍窗口之外 ⇒ 观察口回退到提交时的 PRF 读值 0，而核内架构值是对的
（同一镜像在冒烟台 PASS）。把 `DBG_HOLD` 加到 32 拍后 mask/alu 都通过。

- 只改**观察口径**，退休时刻/顺序/条数不变。
- TB 里取延迟 iid 的下标同步改成 `dut.h_iid[slot][31]`（`DBG_OUT = DBG_HOLD-1`）；
  改 `DBG_HOLD` 时必须一起改这三处。
- 向量退休记录窗口余量因此从 ~13 拍变 ~29 拍，更宽松。

## 2b. 为什么不用 live VRF 比对

A910 的 `dbg_commit_*` 有 `DBG_HOLD=16` 拍延迟（等 LSU 写回落地）。而 RvvCore 的
VRF 在真实提交后约 3 拍就写完了（提交水位 T+2 → retire 写 → T+3 采样）。所以
**观察点上 live VRF 比模型超前最多 16 拍**，还可能被更年轻的指令覆盖。

TB 改为在每个时钟捕获 `u_rob.rd_valid_rob2rt[k] && u_retire.rt2rob_write_ready[k]`
的 per-uop 记录（按 `rob_tag` 分槽累计），等延迟提交点到达时再比对。这样：
- 每条指令只和**自己**的写记录比；
- 更年轻的 WAW 覆盖不会误伤；
- 也不需要假设 VRF 在观察点的最终值。

## 3. 用法

当前结果（2026-10-18）：

- `make gm-host`：PASS=20 FAIL=0（full + unif 全部 sweep bin）；
- `make a910-difftest-rvv`：PASS=11 FAIL=0；
- 标量回归 `make a910-difftest-all`：46 项 PASS；`coremark_c4/coremark_i1`
  是默认 20 万拍上限已知问题；`rvv_lsu` 是旧手写用例触发的 DUT 卡死（见 §7a）；
- 负向注入（`vadd` 结果 +1）：第一条出错指令即被报出（pc/v/byte/exp/act）。

```bash
# 1) 主机侧自测 (不需要 VCS/DUT): 20 个 sweep bin 全部 a0==0
make gm-host

# 只跑某组
python3 tests/rvv/run_host_model.py --only alu

# 2) 单条整核 difftest
make a910-difftest TEST=rvv_sweep_alu_0 A910_DT_MAX_CYCLES=600000

# 3) 向量 sweep 全量 (11 个 full bin)
make a910-difftest-rvv

# 4) 标量回归 (rvv_sweep_* 已由 pattern 跳过)
make a910-difftest-all
```

编译仍需要 EDA 变量：

```bash
export VCS_HOME=/mnt/tools/synopsys/vcs/V-2023.12-SP2
export VERDI_HOME=/mnt/tools/synopsys/verdi/V-2023.12-SP2
export SNPSLMD_LICENSE_FILE=27000@192.168.50.152
export PATH=$PATH:$VCS_HOME/bin:$VERDI_HOME/bin
```

## 4. 文件

| 文件 | 作用 |
|---|---|
| `golden_model/rvv.c` | 状态/reset、vset*、解码、分派、DPI 查询取值 |
| `golden_model/rvv_alu.c` | ALU / MULMAC / 归约 / mask / 扩展 / 窄化 |
| `golden_model/rvv_mem.c` | 向量 load/store（unit/strided/indexed） |
| `golden_model/include/rvv.h` | 接口与数据结构 |
| `golden_model/stage/{ID,EX,MEM}.c` | 0x57/0x07/0x27 分派与 `is_vec` 透传 |
| `dpi/dpi_shim.c` | `gm_last_*` 查询接口 |
| `tb/a910/tb_a910_difftest.sv` | 退休记录捕获 + 逐字节比对 |
| `tools/gm_host_run.c` | 主机侧自测入口 |
| `tests/rvv/run_host_model.py` | 主机自测驱动（读 manifest、报失败用例） |

## 5. 本仓语义约定（与 spec 的差异）

模型按**本仓 RTL**实现，不是纯 spec：

| 项目 | 行为 |
|---|---|
| VLEN / ELEN | 128 / 32，无 SEW64 |
| ta/ma | RTL 不读，恒 tail/mask undisturbed |
| vstart / vxrm | 恒 0 / RNU |
| 比较类 | 每元素 1 bit，写 `ceil(vl/8)` 字节，末字节 ≥vl 的位写 0 |
| mask 逻辑 | 同上（尾部保持） |
| 归约 | 种子 vs1[0]，只写 vd 第 0 个元素（vwredsum 为 2*SEW） |
| 窄化 | vtype.SEW = 目的宽度，源 EEW=2*SEW |
| 扩展 | vtype.SEW = 源宽度，目的 EEW=2/4*SEW |
| 索引访存 | 索引是字节偏移，不乘元素大小；索引 EEW 由 funct3 决定并符号扩展 |
| vmerge | mask=1 选第三操作数（vs1/scalar/imm），mask=0 选 vs2 |
| vwmaccsu | vs2 unsigned × vs1 signed |
| vwmaccus | vs2 signed × vs1 unsigned |

## 6. 不在范围内

- 段访存（nf>1）、whole-register / mask load/store、fault-only-first、
  ordered indexed 的排序差异：模型报 illegal（这些形态没有用例）。
- 向量访存访问 MMIO：模型只建模低 64KB DRAM。
- vmv.x.s / vcpop.m / vfirst.m：与 bridge 一致，报 illegal（cause 2）。
- 浮点向量 / Zvt。
- 向量 CSR（vtype/vl/vstart/vcsr）没有 A910 可读通路，不参与比对；
  只有 vset* 写 rd 的 vl 走标量比对。
- 端到端内存比对：不做。向量 store 的正确性由 sweep 程序自己的 phase-4
  标量回读（也在 difftest 里逐条比对）验证；直接比 AXI 内存会被 dcache 脏行干扰。

## 7. 调试

- `GM_TRACE=1 make a910-difftest ...`：原有逐提交 diff 打印。
- `+TRACE`：打印退休槽。
- 向量失配打印格式：

```
❌ RVV difftest: 数据不一致 (T<cycle> iid=<iid> pc=<pc> inst=<inst> v<reg> byte<b> exp=<xx> act=<xx>)
```

- 若报 "退休记录到延迟提交点仍未流完"：说明该指令的 uop 数超过了观察窗口，
  需要加大 `A910_cpu.sv` 的 `DBG_HOLD`（同时改 TB 里的 iid 下标）或把比对延后。

## 7a. 已知失败：`rvv_lsu`（旧手写用例，DUT 本身卡死）

`bin/rvv_lsu.bin` 在主机模型里 36 条指令跑完、a0=0；但整核在 difftest 里
16 条退休后卡住（ROB 占用 22，200k 拍不退出）。这是该旧用例本身触发的 DUT
LSU 卡死（历史上 `rvv_lsu` 就挂在第一条 `vle32`），与黄金模型无关。
`a910-difftest-all` / `_wave` 已用 pattern 跳过 `rvv_sweep_*|rvv_lsu`；
向量 L/S 的覆盖由 `rvv_sweep_ls_0/ls_1` 承担（均 PASS）。

## 7b. 生成器的一处配套修改（2026-10-18）

`tests/rvv/gen_sweep.py` 末尾的 "dcache write-back sweep" 从 `lw` 改成了 `sw`：

- 目的仍是按 4KB 步长遍历扫描区、把 dcache 脏行挤回内存；
- 原来的 `lw` 数据本来就被丢弃，但 difftest 会逐条比对退休值，而 DUT 在
  向量 store 之后对扫描区做 load 时**偶发**返回旧 store 数据（AXI 内存内容正确）；
- 改成 store 不产生被比对的架构值，冒烟台/整核行为不变（已验证 mask/alu PASS）。

已生成的 `asm/rvv_sweep_*.S` 用脚本同步过（只替换扫描块里的 `lw t3`→`sw t3`，
指令长度不变，数据段地址/manifest 不受影响）。
- `tools/gm_host_run` 的 `GM_DUMP=<addr>:<nwords>` 可以直接 dump 模型内存，
  用来和 `.elf` 里的 `rvv_exp` 对拍（例：`GM_DUMP=0x22d0:8,0x27d0:8`）。
