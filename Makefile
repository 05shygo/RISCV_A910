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
VSRC := $(wildcard $(PWD)/mySoC/*.v) $(PWD)/vsrc/$(RAM)
SVSRC := $(wildcard $(PWD)/tb/*.sv)
DPIC := $(wildcard $(PWD)/dpi/*.c)
CSRC_GM := $(wildcard $(PWD)/golden_model/*.c) $(wildcard $(PWD)/golden_model/stage/*.c) $(wildcard $(PWD)/golden_model/peripheral/*.c)
INC  := +incdir+$(PWD)/mySoC +incdir+$(PWD)/vsrc
DEFINES := +define+PATH=$(TESTFILE)

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

$(SIMV): $(VSRC) $(SVSRC) $(DPIC) $(CSRC_GM)
	@mkdir -p $(BUILD_DIR)
	$(VCS) $(VCS_FLAGS) $(VCS_FLAGS_EXTRA) $(INC) $(DEFINES) $(FSDB_VCS) -CFLAGS -DVCS \
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

