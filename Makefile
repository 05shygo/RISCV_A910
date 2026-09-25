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
DEFINES := +define+PATH=$(TESTFILE)
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

.PHONY: all build run run-all verdi clean help coremark asm

asm: $(ASM_BINS)

$(PWD)/bin/%.bin: $(PWD)/asm/%.S
	@mkdir -p $(PWD)/bin
	@$(TOOLCHAIN)/$(CROSS)gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
	    -Wl,-Ttext=0 $< -o $(PWD)/asm/$*.elf
	@$(TOOLCHAIN)/$(CROSS)objdump -D $(PWD)/asm/$*.elf > $(PWD)/asm/$*.dump
	@$(TOOLCHAIN)/$(CROSS)objcopy -O binary $(PWD)/asm/$*.elf $@
	@echo "Built bin/$*.bin"

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
BP_GHR_W     ?= 8     # GHR 宽度: 索引只有 ROW_AW=9 位, 历史超过 8 位就开始互相干扰

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
           $(if $(BP_RAS),+define+BP_RAS=$(BP_RAS))

BP_CFG := $(BUILD_DIR)/.bp_cfg
BP_SIG := $(BP_PRE_FOLD)-$(BP_PRE_AW)-$(BP_SEL_AW)-$(BP_BTB_ROW_W)-$(BP_L0_ENTRIES)-$(BP_IND_AW)-$(ICACHE_BYTES)-$(ICACHE_LINE_BYTES)-$(BP_BTB_ROW_AW)-$(BP_BHT_ROW_AW)-$(BP_GHR_W)-$(BP_RAS)

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

run: build
	@ln -sf $(PWD)/bin/$(TEST).bin $(TESTFILE)
	@mkdir -p waveform
	$(SIMV) +vcs+lic+wait $(SIM_ARGS) -l $(BUILD_DIR)/sim.log

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

