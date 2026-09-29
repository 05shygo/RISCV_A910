VCS ?= vcs
VERDI ?= verdi

PWD := $(shell pwd)
TOP ?= tb_miniRV_dpi
TEST ?= addi
WAVE ?= waves
FMT ?= auto
MAX_CYCLES ?= 1000000
# CoreMark 是唯一需要跑上千万周期的用例 (ITERATIONS=25 时约 11.0M 周期, 实测 ~41s).
# 单测的 MAX_CYCLES 保持 1000000 不变, 这样真卡死的单测能快速暴露;
# 只有 coremark 用这个更大的上限.
COREMARK_MAX_CYCLES ?= 15000000

BUILD_DIR := $(PWD)/obj_vcs
SIMV := $(BUILD_DIR)/simv
TESTFILE := $(PWD)/meminit.bin
# 十六进制镜像: $readmemh 用 (可综合的存储原语 mySoC/sync_mem.v 读它)。
# 两种宽度, 都是每用例从 bin/%.bin 现生成:
#   meminit.hex     每行一个 32 位字      → 数据 RAM (16K 字)
#   meminit128.hex  每行一个 128 位取指块 → 取指 ROM (4096 块, 行内 w3..w0 降序)
TESTHEX    := $(PWD)/meminit.hex
TESTHEX128 := $(PWD)/meminit128.hex
# 镜像按 16K 字摊平。$readmemh **不会**把镜像没覆盖到的位置清零 (留 X), 而黄金
# 模型是零初始化的 —— 0 扩散进寄存器会让 difftest 出现莫名其妙的失配, 所以补零。
HEX_ROWS ?= 16384

RAM ?= ram.v
# 取指级三选一:
#   IFU=0  旧 PC/NPC/IROM 通路
#   IFU=1  ifu_rv32i (C910 派生前端, 3 级, 41 文件 14,967 行)
#   IFU=2  ifu2 (自研 2 级 3 发射前端, mySoC/ifu2/)
IFU ?= 1
# LBUF=1: 打开循环缓冲 (cp0_ifu_lbuf_en=1); LBUF=0: LBUF 状态机常驻 IDLE.
# 只在 IFU=1 下有意义 (LBUF 属于 ifu_rv32i).
LBUF ?= 0
# ICACHE=1: 打开 I-Cache (cp0_ifu_icache_en/pref_en=1); ICACHE=0: 走 bypass 读.
# BP=1: 打开分支预测 (BHT/L1-BTB/L0-BTB/间接/RAS); BP=0: 5 者全关.
# 两者都只在 IFU=1 下有意义, 由 mySoC/ifu_subsys.v 的 ICACHE_EN/BP_EN 参数接收.
ICACHE ?= 1
BP ?= 1
# IFU=2 时换成自研 2 级前端 ifu2 的 RTL。两棵树的模块名不重名, 但顶层只有一棵
# 能被例化 —— 旧树整个不参与编译, elaborate 更快, 也不会把死代码带进网表。
# ifu_subsys.v 必须一并排除: 它是 rv32_ifu_top 的 SoC 适配层, 而那棵树这时
# 不在文件列表里, 留着一个例化不存在模块的 wrapper 会让 elaborate 直接失败。
ifeq ($(IFU),2)
VSRC := $(filter-out $(PWD)/mySoC/ifu_subsys.v, $(wildcard $(PWD)/mySoC/*.v)) \
        $(wildcard $(PWD)/mySoC/ifu2/rtl/*.v) $(PWD)/vsrc/$(RAM)
else
VSRC := $(wildcard $(PWD)/mySoC/*.v) $(wildcard $(PWD)/mySoC/ifu_rv32i/rtl/*.v) $(PWD)/vsrc/$(RAM)
endif
SVSRC := $(wildcard $(PWD)/tb/*.sv)
DPIC := $(wildcard $(PWD)/dpi/*.c)
CSRC_GM := $(wildcard $(PWD)/golden_model/*.c) $(wildcard $(PWD)/golden_model/stage/*.c) $(wildcard $(PWD)/golden_model/peripheral/*.c)
INC  := +incdir+$(PWD)/mySoC +incdir+$(PWD)/vsrc
DEFINES := +define+PATH=$(TESTFILE) +define+PATHHEX=$(TESTHEX) +define+PATH128=$(TESTHEX128)
ifeq ($(IFU),1)
DEFINES += +define+USE_IFU
endif
# IFU=2 只定义 USE_IFU2, 不定义 USE_IFU: tb 里那一大段绑旧层次的探针
# (dut.Core_cpu.u_ifu_subsys.u_ifu_top.u_bp_top...) 因此不参与编译。
ifeq ($(IFU),2)
DEFINES += +define+USE_IFU2
endif
# "用了任何一款 IFU 就成立"的门控。必须由 Makefile 定义而不是 RTL 内部 `define ——
# 用到的文件不止 mycpu.v (miniRV_SoC.v 的 IROM 端口也是), 而 `define 的作用范围
# 取决于文件编译顺序, 靠 RTL 里定义会随时序变化。
ifneq ($(IFU),0)
DEFINES += +define+USE_IFU_ANY
endif
ifeq ($(LBUF),1)
DEFINES += +define+USE_LBUF
endif
ifeq ($(ICACHE),0)
DEFINES += +define+ICACHE_OFF
endif
ifeq ($(BP),0)
DEFINES += +define+BP_OFF
endif

# FSDB (Verdi) detection
# Enabled for debugging
FSDB_HOME := $(if $(VERDI_HOME),$(VERDI_HOME),$(NOVAS_HOME))
ifneq ($(strip $(FSDB_HOME)),)
  FSDB_VCS := -P $(FSDB_HOME)/share/PLI/VCS/LINUX64/novas.tab $(FSDB_HOME)/share/PLI/VCS/LINUX64/pli.a
  DEFINES += +define+FSDB
endif

VCS_FLAGS ?= -full64 -sverilog -timescale=1ns/1ps -debug_access+all +v2k
VCS_FLAGS_EXTRA ?=
SIM_ARGS ?= +WAVE=$(WAVE) +MAX_CYCLES=$(MAX_CYCLES)
# -exitstatus 是必需的: 没有它时 VCS 的 $fatal(1,...) 也会让 simv 返回 0,
# 于是 run-all 会把所有失败当成 PASS (difftest 不匹配同样如此 —— 实测确认过:
# 打印了 "Fatal:" 但 $? 仍是 0). 加上它之后 $fatal(n) 才真正返回 3/$n.
SIM_ARGS += -exitstatus

# ---------------------------------------------------------------------------
# 汇编用例的构建规则.
# 以前没有这条规则(asm/*.S 都是手敲命令建的), 加陷阱用例时补上.
# 工具链必须用 open_riscv_2035 里的这套: ../tools/riscv/bin 下那套在本机
# 因为 glibc 版本不匹配(缺 GLIBC_2.32/2.33/2.34)跑不起来.
# -Wl,-Ttext=0 让镜像从地址 0 开始(CPU 复位后从 PC=0 取指),
# objcopy -O binary 生成扁平镜像给 IROM/DRAM 的 $fread 用.
# ---------------------------------------------------------------------------
TOOLCHAIN ?= /x2025/GPrj1/IC1/riscv/RISCV_CPU/open_riscv_2035/tools/newlib/bin
CROSS     ?= riscv64-unknown-elf-
ASM_SRCS  := $(wildcard $(PWD)/asm/*.S)
ASM_BINS  := $(patsubst $(PWD)/asm/%.S,$(PWD)/bin/%.bin,$(ASM_SRCS))

.PHONY: all build run run-all verdi clean help coremark asm muldiv-unit

asm: $(ASM_BINS)

$(PWD)/bin/%.bin: $(PWD)/asm/%.S
	@mkdir -p $(PWD)/bin
	@$(TOOLCHAIN)/$(CROSS)gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
	    -Wl,-Ttext=0 $< -o $(PWD)/asm/$*.elf
	@$(TOOLCHAIN)/$(CROSS)objdump -D $(PWD)/asm/$*.elf > $(PWD)/asm/$*.dump
	@$(TOOLCHAIN)/$(CROSS)objcopy -O binary $(PWD)/asm/$*.elf $@
	@echo "Built bin/$*.bin"

# ---------------------------------------------------------------------------
# 十六进制镜像 (给可综合的存储原语 mySoC/sync_mem.v 的 $readmemh 用)
#
# od -An -tx4 在 x86 上按小端解释 4 字节组, 正好得到 RV32 的字值
# (已与 objdump 逐字核对)。128 位那一路把行内四字**降序**输出: $readmemh 把一行
# 当一个大端值、首 token 落在最高位, 降序之后正好等于取指侧要的 {w3,w2,w1,w0}。
#
# ⚠️ 补零那一段不能省: $readmemh 不会把镜像没覆盖到的位置清零 (留 X), 而黄金模型
#    是零初始化的 —— X 扩散进寄存器会让 difftest 出现难定位的失配。
# ---------------------------------------------------------------------------
HEX_PAD32 := awk -v n=$(HEX_ROWS) '{if (NR<=n) print} END{for(i=NR;i<n;i++) print "00000000"}'
HEX_PAD128 := awk -v n=$$(( $(HEX_ROWS) / 4 )) \
              '{if (NR<=n) print} END{for(i=NR;i<n;i++) print "00000000000000000000000000000000"}'

$(PWD)/bin/%.hex: $(PWD)/bin/%.bin
	@od -An -tx4 -v $< | awk '{for (i=1;i<=NF;i++) print $$i}' | $(HEX_PAD32) > $@

$(PWD)/bin/%.hex128: $(PWD)/bin/%.bin
	@od -An -tx4 -v -w16 $< \
	  | awk '{printf "%s%s%s%s\n", ($$4==""?"00000000":$$4), ($$3==""?"00000000":$$3), \
	                                    ($$2==""?"00000000":$$2), $$1}' \
	  | $(HEX_PAD128) > $@

all: run

# Build CoreMark for RV32I
coremark:
	@echo "=== Building CoreMark for RV32I ==="
	$(MAKE) -C coremark -f Makefile.coremark
	@echo "CoreMark binary ready at bin/coremark.bin"
	@echo "Run with: make run TEST=coremark MAX_CYCLES=10000000"

build: $(SIMV)

# IFU 开关只影响 DEFINES, 不是 $(SIMV) 的依赖 —— 不额外记一个 stamp 的话
# `make build IFU=0` 会因为"源文件没变"而跳过重编译, 静默沿用上一个 IFU=1
# 的 simv (实测踩过: 两次 coremark 周期数一模一样才发现)。
# LBUF 开关同理, 所以每个只改 DEFINES 的开关都要有自己的 stamp。
IFU_CFG  := $(BUILD_DIR)/.ifu_cfg
LBUF_CFG := $(BUILD_DIR)/.lbuf_cfg

$(IFU_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(IFU)" | cmp -s - $@ || echo "$(IFU)" > $@

$(LBUF_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(LBUF)" | cmp -s - $@ || echo "$(LBUF)" > $@

ICACHE_CFG := $(BUILD_DIR)/.icache_cfg
BP_EN_CFG  := $(BUILD_DIR)/.bp_en_cfg

$(ICACHE_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(ICACHE)" | cmp -s - $@ || echo "$(ICACHE)" > $@

$(BP_EN_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(BP)" | cmp -s - $@ || echo "$(BP)" > $@

# ---------------------------------------------------------------------------
# BP_* : 分支预测器表尺寸 (面积-准确率实验用)
#
# 只改 DEFINES, 所以同样需要自己的 stamp。默认全空 = RTL 里的原尺寸,
# 基线不受影响。举例 —— 缩到与 cpu 工程预测器(约 4.99 Kbit)相当的 ~5.08 Kbit:
#
#   make run TEST=branch_bench SIM_ARGS=+BENCH \
#        BP_PRE_AW=5 BP_SEL_AW=4 BP_BTB_ROW_W=3 BP_L0_ENTRIES=4 BP_IND_AW=3
#
#   BP_PRE_AW     BHT 预测阵列行数 log2  (默认 10 → 1024 行 × 64bit)
#   BP_SEL_AW     BHT 选择阵列行数 log2  (默认  7 →  128 行 × 16bit)
#   BP_BTB_ROW_W  L1 BTB 行数 log2       (默认  9 →  512 行 × 2bank × 4slot)
#   BP_L0_ENTRIES L0 BTB 项数            (默认 16)
#   BP_IND_AW     间接 BTB 行数 log2     (默认  8 →  256 行 × 35bit)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 默认值 = "对标 cpu 核面积"的选定配置 (5,372 bit, CoreMark 2.382 / +3.77% vs 189K 基线)
#   BHT 预测 32 行(XOR 折叠) 2,048 + 选择 16 行 256 + L1 BTB 4 行 976
#   + L0 16 项 1,792 + 间接 4 行 140 + RAS 160
# 想要回原样基线(189,088 bit, 2.471): make BP_PRE_FOLD= BP_PRE_AW= BP_SEL_AW= \
#   BP_BTB_ROW_W= BP_IND_AW= ...
# 面积/跑分全表见 doc/bp_three_way_zh.md §5 与 memory bp-area-frontier-2026-09-24。
# ---------------------------------------------------------------------------
ICACHE_BYTES      ?= 1024
ICACHE_LINE_BYTES ?= 16
BP_PRE_FOLD  ?= 1
BP_PRE_AW    ?= 5
BP_SEL_AW    ?= 4
BP_BTB_ROW_W ?= 2
BP_IND_AW    ?= 2
BP_L0_ENTRIES ?= 16
# ---------------------------------------------------------------------------
# BP_PRED : 方向预测器二选一 (只对 IFU=2 有意义)
#   0 = gshare (rv32ifu2_bht, **默认**, 2026-09-29 起 —— 为 FPGA Fmax)
#   1 = TAGE   (rv32ifu2_tage, 2026-09-26~09-29 曾是默认; 留下来做 A/B 与精度臂)
#
# 换回 gshare 的理由 = 时序: TAGE 的 F1 是「LUTRAM 读 → tag 比较 → hit →
# prov/alt 优先 → mux → use_sel/weak 选择」≈ 4~5 级组合, gshare 只有「寄存索引
# → LUTRAM 读 → 取计数器 MSB」≈ 0 级 —— 那 4~5 级整段落在 F1 取指环
# (q_idx → 表读 → 预测 → taken/目标 → next_pc → 哈希 → q_idx) 里。
# 实测 (w4 树 = BEU+前端减级数, 同镜像/同流程, 46 用例 difftest 全过):
#   Fmax          161.9 MHz (6.2ns)  ->  183.9 MHz (5.6ns)   +13.6%
#   CoreMark      11,270,384 -> 11,611,077 拍 (+3.02%), retired inst 逐位不变
#   branch_bench     163,764 ->    166,755 拍 (+1.83%)
# 净吞吐 = 1.136 / 1.030 ≈ +10.3%。代价的绝大部分来自 W2.4 的「索引 GHR 滞后
# 一块」——TAGE 长历史下只值 +0.28%, gshare 只有 8 位历史, 相对损失大得多。
# 面积顺带: 方向表 8,464 -> 4,104 bit (整机预测器 13,008 -> 8,920 bit)。
# 精度臂: TAGE 仍是同镜像下更强的预测器 (方向准确率 96.57% vs 95.02%,
# 条件分支误预测少 31%)。要用它: make ... BP_PRED=1
# ---------------------------------------------------------------------------
BP_PRED      ?= 0
# ---------------------------------------------------------------------------
# REDIRECT_PIPE : EX(IU) 那条重定向打一拍再进前端 (只对 IFU=2 有意义)
#   1 = 打拍 (**默认**, 2026-09-28 起) —— 为 FPGA 时序
#   0 = 不打拍, 逐位回到打拍前 (重定向 0 拍代价, 但 EX↔前端是一条单周期长链)
#
# 为什么: FPGA 综合报告里 8 个 run 的最差 500 条路径**全部**是
#   EX 段 (CSR 读 → ALU → 分支判决 → actual_npc) → next_pc mux → 前端数组地址
# 这一条 25~28 级、78% 走线的单周期链。打一拍把它从中间切断。
# 代价: 每次重定向 (误预测 + 陷阱/mret) 多 1 拍 —— 实测数字见 rv32ifu2_top.v
#       的 REDIRECT_PIPE 注释与提交信息。
# 回旧基线: make ... REDIRECT_PIPE=0
# ---------------------------------------------------------------------------
REDIRECT_PIPE ?= 1
# TAGE 几何。空 = 用 RTL 里的默认值 (T0_AW=6/ROW=6/N=4/TAG=6/L=2:5:9:14, 8,464 bit)。
# 这个默认点是 RTL 侧扫出来的: CoreMark 最快的配置是 128 行 × 4 表 (15,890 bit,
# -0.88%), 但多花 7,426 bit 只换 0.21% —— 按 doc §4 那张"每比特收益表"的口径
# 不到 0.028 %/Kbit, 在**自己的边际价值标尺上**就不划算, 所以停在 64 行。
#   make ... BP_TAGE_AW=7 BP_TAGE_TAG_W=5 BP_GHR_W=18 \
#        BP_TAGE_L1=2 BP_TAGE_L2=5 BP_TAGE_L3=10 BP_TAGE_L4=16   # -> 15,890 bit
# ⚠️ 两个硬约束, 越界都会在 time 0 报一句人能看懂的话然后 $fatal:
#   BP_GHR_W <= 18  (25 位 chk 的预算, CHK_FPRED = GHR_W + 6)
#   BP_TAGE_TAG_W >= 12 - min(BP_TAGE_RAi)  (标签要装下索引让出来的那几位;
#        ⚠️ 上了逐表行数之后这条是**下界**, 方向与以前相反 —— 以前是 <= 12-AW)
BP_T0_AW     ?=
BP_T0_HIST   ?=        # T0 索引里掺几位历史 (0 = 纯双模态)。⚠️ define 名是 BP_TAGE_T0H
BP_TAGE_AW   ?=
BP_TAGE_N    ?=
BP_TAGE_TAG_W ?=
BP_TAGE_L1   ?=
BP_TAGE_L2   ?=
BP_TAGE_L3   ?=
BP_TAGE_L4   ?=
# USE_SEL 的项数/位宽/门控。按构造与 T0 解耦 (见 top.v 那里的注释):
# 只有"命中 tagged 表"的分支才会查询/训练它, 所以它不必和 T0 同深。
# ⚠️ 抬过 BP_TAGE_AW 会加长初始化扫描 (INIT_ROWS 取三者最大)。
BP_TAGE_USEL_AW   ?=
BP_TAGE_USEL_W    ?=
BP_TAGE_USEL_GATE ?=
# 逐表逻辑行数 (回答"每一级的表 entry 数不同会怎样")。空 = 四张表同尺寸。
# ⚠️ 缩表要把 BP_TAGE_TAG_W 同步加宽到 >= 12 - min(RAi), 否则 tage.v 会 $fatal。
BP_TAGE_RA1  ?=
BP_TAGE_RA2  ?=
BP_TAGE_RA3  ?=
BP_TAGE_RA4  ?=

# GHR 宽度: gshare 只有 ROW_AW=9 位的索引, 历史超过 8 位就开始互相干扰 (doc §4 扫点);
# TAGE 每张表有自己的宽度, 没有那个自抵消, 长历史才有用 ⇒ 默认 16。
BP_GHR_W     ?= $(if $(filter-out 0,$(BP_PRED)),16,8)

BP_DEFS := $(if $(filter 16,$(ICACHE_LINE_BYTES)),+define+ICACHE_LINE_16B) \
           $(if $(ICACHE_BYTES),+define+ICACHE_BYTES=$(ICACHE_BYTES)) \
           $(if $(ICACHE_LINE_BYTES),+define+ICACHE_LINE_BYTES=$(ICACHE_LINE_BYTES)) \
           $(if $(BP_PRE_FOLD),+define+BP_PRE_FOLD) \
           $(if $(BP_PRE_AW),+define+BP_PRE_AW=$(BP_PRE_AW)) \
           $(if $(BP_SEL_AW),+define+BP_SEL_AW=$(BP_SEL_AW)) \
           $(if $(BP_BTB_ROW_W),+define+BP_BTB_ROW_W=$(BP_BTB_ROW_W)) \
           $(if $(BP_L0_ENTRIES),+define+BP_L0_ENTRIES=$(BP_L0_ENTRIES)) \
           $(if $(BP_IND_AW),+define+BP_IND_AW=$(BP_IND_AW)) \
           $(if $(BP_BTB_ROW_AW),+define+BP_BTB_ROW_AW=$(BP_BTB_ROW_AW)) \
           $(if $(BP_BHT_ROW_AW),+define+BP_BHT_ROW_AW=$(BP_BHT_ROW_AW)) \
           $(if $(BP_GHR_W),+define+BP_GHR_W=$(BP_GHR_W)) \
           $(if $(BP_RAS),+define+BP_RAS=$(BP_RAS)) \
           $(if $(filter-out 0,$(BP_PRED)),+define+BP_PRED=$(BP_PRED)) \
           $(if $(filter-out 0,$(REDIRECT_PIPE)),+define+REDIRECT_PIPE) \
           $(if $(BP_T0_AW),+define+BP_T0_AW=$(BP_T0_AW)) \
           $(if $(BP_T0_HIST),+define+BP_TAGE_T0H=$(BP_T0_HIST)) \
           $(if $(BP_TAGE_AW),+define+BP_TAGE_AW=$(BP_TAGE_AW)) \
           $(if $(BP_TAGE_N),+define+BP_TAGE_N=$(BP_TAGE_N)) \
           $(if $(BP_TAGE_TAG_W),+define+BP_TAGE_TAG_W=$(BP_TAGE_TAG_W)) \
           $(if $(BP_TAGE_L1),+define+BP_TAGE_L1=$(BP_TAGE_L1)) \
           $(if $(BP_TAGE_L2),+define+BP_TAGE_L2=$(BP_TAGE_L2)) \
           $(if $(BP_TAGE_L3),+define+BP_TAGE_L3=$(BP_TAGE_L3)) \
           $(if $(BP_TAGE_L4),+define+BP_TAGE_L4=$(BP_TAGE_L4)) \
           $(if $(BP_TAGE_USEL_AW),+define+BP_TAGE_USEL_AW=$(BP_TAGE_USEL_AW)) \
           $(if $(BP_TAGE_USEL_W),+define+BP_TAGE_USEL_W=$(BP_TAGE_USEL_W)) \
           $(if $(BP_TAGE_USEL_GATE),+define+BP_TAGE_USEL_GATE=$(BP_TAGE_USEL_GATE)) \
           $(if $(BP_TAGE_RA1),+define+BP_TAGE_RA1=$(BP_TAGE_RA1)) \
           $(if $(BP_TAGE_RA2),+define+BP_TAGE_RA2=$(BP_TAGE_RA2)) \
           $(if $(BP_TAGE_RA3),+define+BP_TAGE_RA3=$(BP_TAGE_RA3)) \
           $(if $(BP_TAGE_RA4),+define+BP_TAGE_RA4=$(BP_TAGE_RA4))

BP_CFG := $(BUILD_DIR)/.bp_cfg
BP_SIG := $(BP_PRE_FOLD)-$(BP_PRE_AW)-$(BP_SEL_AW)-$(BP_BTB_ROW_W)-$(BP_L0_ENTRIES)-$(BP_IND_AW)-$(ICACHE_BYTES)-$(ICACHE_LINE_BYTES)-$(BP_BTB_ROW_AW)-$(BP_BHT_ROW_AW)-$(BP_GHR_W)-$(BP_RAS)-$(REDIRECT_PIPE)\
          -$(BP_PRED)-$(BP_T0_AW)-$(BP_T0_HIST)-$(BP_TAGE_AW)-$(BP_TAGE_N)-$(BP_TAGE_TAG_W)-$(BP_TAGE_L1)-$(BP_TAGE_L2)-$(BP_TAGE_L3)-$(BP_TAGE_L4)\
          -$(BP_TAGE_USEL_AW)-$(BP_TAGE_USEL_W)-$(BP_TAGE_USEL_GATE)\
          -$(BP_TAGE_RA1)-$(BP_TAGE_RA2)-$(BP_TAGE_RA3)-$(BP_TAGE_RA4)

$(BP_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(BP_SIG)" | cmp -s - $@ || echo "$(BP_SIG)" > $@

FORCE:

$(SIMV): $(VSRC) $(SVSRC) $(DPIC) $(CSRC_GM) $(IFU_CFG) $(LBUF_CFG) $(BP_CFG) $(ICACHE_CFG) $(BP_EN_CFG)
	@mkdir -p $(BUILD_DIR)
	$(VCS) $(VCS_FLAGS) $(VCS_FLAGS_EXTRA) $(INC) $(DEFINES) $(BP_DEFS) $(FSDB_VCS) -CFLAGS -DVCS \
	  -CFLAGS -I$(PWD)/golden_model/include \
	  -LDFLAGS "-Wl,-rpath,$(FSDB_HOME)/share/PLI/VCS/LINUX64" \
	  -LDFLAGS "-Wl,-rpath,$(PWD)" \
	  -top $(TOP) -o $(SIMV) \
	  -Mdir=$(BUILD_DIR)/csrc -l $(BUILD_DIR)/compile.log \
	  $(VSRC) $(SVSRC) $(DPIC) $(CSRC_GM)

run: build $(PWD)/bin/$(TEST).hex $(PWD)/bin/$(TEST).hex128
	@ln -sf $(PWD)/bin/$(TEST).bin $(TESTFILE)
	@ln -sf $(PWD)/bin/$(TEST).hex $(TESTHEX)
	@ln -sf $(PWD)/bin/$(TEST).hex128 $(TESTHEX128)
	@mkdir -p waveform
	$(SIMV) +vcs+lic+wait $(SIM_ARGS) -l $(BUILD_DIR)/sim.log

# ---------------------------------------------------------------------------
# 单元级 TB: 直接驱动乘除法单元 (tb/unit/tb_muldiv_unit.sv), 不经整核。
#
# 为什么要单开一套: 整核 difftest 只说"某条指令结果不对", 定位不到是 Booth 阵列、
# 压缩树还是除法的迭代数算错; 而 II=1、"被冲刷的乘法绝不写回"这类时序性质在整核
# 里很难构造。这里用独立的 BUILD_DIR, 和主流程的 obj_vcs 互不干扰。
#
#   make muldiv-unit
# ---------------------------------------------------------------------------
UNIT_BUILD := $(PWD)/obj_unit
UNIT_SIMV  := $(UNIT_BUILD)/simv
UNIT_SRC   := $(PWD)/mySoC/MUL_DIV.v $(PWD)/mySoC/mul_pipe.v $(PWD)/mySoC/div_pipe.v
UNIT_TB    := $(PWD)/tb/unit/tb_muldiv_unit.sv

muldiv-unit: $(UNIT_SIMV)
	@$(UNIT_SIMV) -l $(UNIT_BUILD)/sim.log

$(UNIT_SIMV): $(UNIT_SRC) $(UNIT_TB)
	@mkdir -p $(UNIT_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) -top tb_muldiv_unit -o $(UNIT_SIMV) \
	  -Mdir=$(UNIT_BUILD)/csrc -l $(UNIT_BUILD)/compile.log \
	  $(UNIT_SRC) $(UNIT_TB)

run-all: build
	@mkdir -p waveform
	@tests=$$(ls -1 $(PWD)/bin/*.bin 2>/dev/null || true); \
	if [ -z "$$tests" ]; then echo "No tests found in $(PWD)/bin"; exit 0; fi; \
	pass=""; fail=""; \
	for f in $$tests; do \
	  t=$$(basename $$f .bin); \
	  mc=$(MAX_CYCLES); \
	  if [ "$$t" = "coremark" ]; then mc=$(COREMARK_MAX_CYCLES); fi; \
	  echo "==================== Running $$t (MAX_CYCLES=$$mc) ===================="; \
	  if $(MAKE) -f $(PWD)/Makefile run TOP=$(TOP) RAM=$(RAM) TEST=$$t WAVE=$$t MAX_CYCLES=$$mc; then \
	    pass="$$pass $$t"; \
	  else \
	    fail="$$fail $$t"; \
	  fi; \
	  echo "==================== $$t END ===================="; \
	done; \
	echo; echo "==================== SUMMARY ===================="; \
	echo "Passed Tests:"; \
	if [ -n "$$pass" ]; then echo "$$pass" | sed -e 's/^ //; s/ /, /g'; else echo "(none)"; fi; \
	echo "Failed Tests:"; \
	if [ -n "$$fail" ]; then echo "$$fail" | sed -e 's/^ //; s/ /, /g'; else echo "(none)"; fi

WAVE_SSF := $(if $(wildcard waveform/waves.fsdb),-ssf waveform/waves.fsdb,)

verdi: build
	# Open the specific waveform based on WAVE/FMT; prefer the newest name
	if [ "$(FMT)" = "fsdb" ] && [ -f waveform/$(WAVE).fsdb ]; then \
	  $(VERDI) -sverilog $(INC) $(VSRC) $(SVSRC) -top $(TOP) -ssf waveform/$(WAVE).fsdb ; \
	elif [ "$(FMT)" = "vcd" ] && [ -f waveform/$(WAVE).vcd ]; then \
	  $(VERDI) -sverilog $(INC) $(VSRC) $(SVSRC) -top $(TOP) -vcd waveform/$(WAVE).vcd ; \
	elif [ -f waveform/$(WAVE).fsdb ]; then \
	  $(VERDI) -sverilog $(INC) $(VSRC) $(SVSRC) -top $(TOP) -ssf waveform/$(WAVE).fsdb ; \
	elif [ -f waveform/$(WAVE).vcd ]; then \
	  $(VERDI) -sverilog $(INC) $(VSRC) $(SVSRC) -top $(TOP) -vcd waveform/$(WAVE).vcd ; \
	elif [ -f waveform/waves.fsdb ]; then \
	  $(VERDI) -sverilog $(INC) $(VSRC) $(SVSRC) -top $(TOP) -ssf waveform/waves.fsdb ; \
	elif [ -f waveform/waves.vcd ]; then \
	  $(VERDI) -sverilog $(INC) $(VSRC) $(SVSRC) -top $(TOP) -vcd waveform/waves.vcd ; \
	else \
	  echo "No FSDB/VCD found under waveform/. Run 'make run' first." ; \
	fi

clean:
	rm -rf $(BUILD_DIR) $(TESTFILE) ./simv.daidir ./csrc ./ucli.key ./verdiLog novas.*

help:
	@echo "Usage: make [target] [VAR=value]"
	@echo
	@echo "Targets:"
	@echo "  build            Compile $(TOP) to $(SIMV) (includes tb/*.sv, mySoC/*.v, vsrc/*.v)"
	@echo "  run              Run simulation (TEST=$(TEST)); link bin/$(TEST).bin -> meminit.bin; dumps waves to waveform/"
	@echo "  run-all          Run all tests under bin/*.bin (per-test WAVE); prints pass/fail summary"
	@echo "  asm              Build every asm/*.S into bin/*.bin"
	@echo "  coremark         Build CoreMark benchmark for RV32I (output: bin/coremark.bin)"
	@echo "  verdi            Open the project in Verdi (uses WAVE/FMT to select waveform)"
	@echo "  clean            Remove generated files"
	@echo
	@echo "Variables:"
	@echo "  TOP=$(TOP) (default tb_miniRV_dpi)"
	@echo "  TEST=$(TEST)"
	@echo "  RAM=$(RAM) (default ram.v; alternatives: ram0.v/ram1.v/ram2.v)"
	@echo "  WAVE=$(WAVE) (wave name prefix, default 'waves')"
	@echo "  FMT=$(FMT) (fsdb|vcd|auto)"
	@echo "  MAX_CYCLES=$(MAX_CYCLES)"
	@echo "  VCS=$(VCS)"
	@echo "  VERDI=$(VERDI)"
	@echo
	@echo "Examples:"
	@echo "  make coremark                    # Build CoreMark"
	@echo "  make run TEST=coremark MAX_CYCLES=10000000  # Run CoreMark (needs more cycles)"

