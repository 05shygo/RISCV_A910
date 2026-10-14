VCS ?= vcs
VERDI ?= verdi

PWD := $(shell pwd)
TOP ?= tb_miniRV_dpi
TEST ?= addi
WAVE ?=
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
# PREG=64|96: **物理寄存器数量** (RTU_preg 的池子大小), 构建期可配。
#   64 档与同事交付的 C910 IDU 的 6 位 preg 直接对得上 (IDU 一行不用改);
#   默认 96 保持与 D-cache LSU 的 96 preg 一致。
#   ⚠️ 2026-10-10 改: **端口与内部信号的编号位宽也跟着档走** (`RTU_PREG_W`: 64→6 / 96→7),
#      ROB 表项位域仍固定 7 位 (`RTU_PREG_EW`, 位域是位置宏, 一缩就整体挪格)。
#      好处是 64 档下 RTU 与交付的 IDU 天然同宽 —— 位宽差全部显式收在适配层里,
#      不再靠端口处的隐式截断 (a910-elab 的 PCWM 判据因此从 5 收紧到 0)。
#   完整说明与代价见 doc/rtu_preg_size_config_zh.md。
#   ⚠️ 它只改 DEFINES ⇒ **必须有配置戳** (见下面的 PREG_CFG), 否则切档不会重编译。
PREG ?= 96
PREG_DEFS :=
ifeq ($(PREG),64)
PREG_DEFS += +define+RTU_PREG64
endif
ifeq ($(filter $(PREG),64 96),)
$(error PREG 只能是 64 或 96, 当前是 '$(PREG)')
endif
# IFU=2 时换成自研 2 级前端 ifu2 的 RTL。两棵树的模块名不重名, 但顶层只有一棵
# 能被例化 —— 旧树整个不参与编译, elaborate 更快, 也不会把死代码带进网表。
# ifu_subsys.v 必须一并排除: 它是 rv32_ifu_top 的 SoC 适配层, 而那棵树这时
# 不在文件列表里, 留着一个例化不存在模块的 wrapper 会让 elaborate 直接失败。
# ⚠️ `$(wildcard mySoC/*.v)` **不递归** —— 子目录必须逐个列出来。往
# mySoC/ 下新开目录时忘了加这一行, 症状是 elaborate 报"找不到模块 XXX",
# 而不是报文件缺失 (那个 .v 根本没进文件列表)。
#   * mySoC/        核本体 (顶层/流水寄存器/冒险单元/访存/SoC 适配)
#   * mySoC/idu/rtl ID 级 (译码+寄存器堆+立即数+异常检出)
#   * mySoC/iu/rtl  执行单元 (ALU / 分支执行 / 乘除法)
#   * mySoC/rtu/rtl 退休单元 (ROB/物理寄存器状态/异常/冲刷)
#   * mySoC/ifu2/rtl, mySoC/ifu_rv32i/rtl  两款前端 (二选一)
#   * mySoC/idu_c910/rtl  C910 移植的乱序多发射 IDU (重命名+发射队列+PRF)
#   * mySoC/lsu/rtl  D-cache LSU (含 dcache/LFB/MSHR/VB/WMB/LQ/SQ)
# ⚠️ 后两个目录是 **.sv**, 而上面的通配是 *.v —— 后缀不同, 不会被现有行捞到,
#    必须单独列出来 (这是 C910 移植过来的文件, 保持了原来的 SystemVerilog 写法)。
ifeq ($(IFU),2)
VSRC := $(filter-out $(PWD)/mySoC/ifu_subsys.v, $(wildcard $(PWD)/mySoC/*.v)) \
        $(wildcard $(PWD)/mySoC/idu/rtl/*.v) $(wildcard $(PWD)/mySoC/iu/rtl/*.v) \
        $(wildcard $(PWD)/mySoC/rtu/rtl/*.v) \
        $(wildcard $(PWD)/mySoC/idu_c910/rtl/*.sv) $(wildcard $(PWD)/mySoC/lsu/rtl/*.sv) \
        $(wildcard $(PWD)/mySoC/ifu2/rtl/*.v) $(PWD)/vsrc/$(RAM)
else
VSRC := $(wildcard $(PWD)/mySoC/*.v) \
        $(wildcard $(PWD)/mySoC/idu/rtl/*.v) $(wildcard $(PWD)/mySoC/iu/rtl/*.v) \
        $(wildcard $(PWD)/mySoC/rtu/rtl/*.v) \
        $(wildcard $(PWD)/mySoC/idu_c910/rtl/*.sv) $(wildcard $(PWD)/mySoC/lsu/rtl/*.sv) \
        $(wildcard $(PWD)/mySoC/ifu_rv32i/rtl/*.v) $(PWD)/vsrc/$(RAM)
endif
# ⚠️ 头文件也必须当先决条件。原来只有 .v 在列表里, 于是**改 defines.vh 不会重编** ——
# 症状是"改了宏但仿真器还是老的": 实测 `touch mySoC/defines.vh && make build` 耗时 0 秒、
# simv 时间戳纹丝不动。这条直接伤反向验证: scripts/rev_check.py 的 M04 注入的正是
# defines.vh, 单独跑 `rev_check.py M04` 会拿旧 simv 跑出"幸存"的假结论。
VHDR := $(wildcard $(PWD)/mySoC/*.vh) $(wildcard $(PWD)/mySoC/rtu/rtl/*.vh)
SVSRC := $(wildcard $(PWD)/tb/*.sv)
DPIC := $(wildcard $(PWD)/dpi/*.c)
CSRC_GM := $(wildcard $(PWD)/golden_model/*.c) $(wildcard $(PWD)/golden_model/stage/*.c) $(wildcard $(PWD)/golden_model/peripheral/*.c)
INC  := +incdir+$(PWD)/mySoC +incdir+$(PWD)/vsrc +incdir+$(PWD)/mySoC/rtu/rtl
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

# ---------------------------------------------------------------------------
# mySoC/lsu 的 dcache 容量. 三选一, 必须定义**恰好一个** —— 这不是优化开关,
# 是"定义了才有电路": ct_lsu_dcache_{data,tag,ld_tag,dirty}_array.sv 里的阵列
# 例化整个包在 `ifdef DCACHE_1KB/2KB/4KB 里, 而 data_dout 这类输出 wire 只由
# 那些例化的 Q 驱动。一个都不定义 ⇒ 阵列一片不例化 ⇒ 输出悬空 (Z), 整个 dcache
# 读出来是 X (不会报错, 只是功能全错)。lsu_top 的 DCACHE_SIZE 参数默认 2048,
# 与之配套的是 DCACHE_2KB, 两处必须一致。
# ---------------------------------------------------------------------------
ifndef DCACHE_SIZE
DCACHE_SIZE := 2048
endif
ifeq ($(DCACHE_SIZE),1024)
DEFINES += +define+DCACHE_1KB
else ifeq ($(DCACHE_SIZE),4096)
DEFINES += +define+DCACHE_4KB
else
DEFINES += +define+DCACHE_2KB
endif

# ---------------------------------------------------------------------------
# Verdi / FSDB 自动检测
#
# 【为什么不能只认环境变量】本机 Verdi 装在 /mnt/tools/synopsys/verdi/V-2023.12-SP2,
#   但登录 shell 里 **VERDI_HOME / NOVAS_HOME 都没设**, verdi/vcs 也都不在 PATH。
#   原来只认那两个环境变量 ⇒
#     (1) FSDB_VCS 为空 ⇒ VCS 编译时**不链接 novas PLI** ⇒ `$fsdbDumpvars` 变成
#         空操作 ⇒ FSDB 文件照生, 但**里面一条信号都没有** —— 症状正是"verdi 打开
#         波形后拉不出信号 / 层次树是空的";
#     (2) `verdi` 命令本身 "command not found"。
#   ⇒ 这里把安装路径**一次性探测出来**, 之后一律用绝对路径, 与 shell 环境解耦。
#
# 探测顺序:
#   1. 环境变量 VERDI_HOME / NOVAS_HOME        (若已设置, 以它为准)
#   2. 常见安装根目录, 每个根下按版本号排序取**最新**的含 bin/verdi 的版本目录
#   (verdi 的 bin/verdi 是个自设环境的 sh wrapper, 所以绝对路径调用无需再 source)
# ---------------------------------------------------------------------------
VERDI_HOME_ENV := $(if $(VERDI_HOME),$(VERDI_HOME),$(NOVAS_HOME))

# 常见安装根 (按冒号分隔, 便于加新机器)
VERDI_ROOTS := /mnt/tools/synopsys/verdi /mnt/tools/verdi \
               /eda/synopsys/verdi /eda/verdi /tools/synopsys/verdi /tools/verdi \
               /usr/synopsys/verdi /opt/synopsys/verdi

# ⚠️ 环境变量必须**校验后才信**: 本机 shell 里 VERDI_HOME 常被某模板设成占位符
#    `/path/to/verdi/installation`, 直接拿来用 ⇒ novas 照着假路径找库 ⇒ dumper 加载失败。
#    判据: 该目录下真有一份 novas.tab。
ifneq ($(strip $(VERDI_HOME_ENV)),)
  ifneq ($(wildcard $(VERDI_HOME_ENV)/share/PLI/VCS/LINUX64/novas.tab),)
    VERDI_HOME_AUTO := $(VERDI_HOME_ENV)
  endif
endif

# 环境变量没给或给了个假路径 ⇒ 按版本号取最新的一个真实安装。
ifeq ($(strip $(VERDI_HOME_AUTO)),)
  VERDI_HOME_AUTO := $(shell for root in $(VERDI_ROOTS); do \
      d=$$(ls -d $$root/*/ 2>/dev/null | sort -V | tail -1); \
      if [ -f "$${d}share/PLI/VCS/LINUX64/novas.tab" ]; then echo "$${d%/}"; break; fi; \
    done)
endif

ifneq ($(strip $(VERDI_HOME_AUTO)),)
  FSDB_HOME := $(VERDI_HOME_AUTO)
  FSDB_VCS  := -P $(FSDB_HOME)/share/PLI/VCS/LINUX64/novas.tab $(FSDB_HOME)/share/PLI/VCS/LINUX64/pli.a
  DEFINES   += +define+FSDB
  # verdi 可执行文件也换成绝对路径 (命令行 `make VERDI=xxx` 仍可覆盖)
  VERDI := $(FSDB_HOME)/bin/verdi
  # ⚠️ 【仿真运行时】也要这个变量: novas 在 simv **跑起来之后**才按 VERDI_HOME/NOVAS_HOME
  #    去 share/PLI/lib/LINUXAMD64/ 找 dumper 动态库 —— 与编译期 `-P ...novas.tab` 是
  #    两回事, 只链上 PLI 不够。实测 (2026-10-12): 本机 shell 里 VERDI_HOME 被某个模板
  #    设成占位符 `/path/to/verdi/installation`, 于是日志里出现
  #      "*Verdi* Cannot load libsscore_vcs202312.so ..." / "Failed to load FSDB dumper"
  #    之后 **FSDB 根本不写**: 旧的 waveform/<用例>.fsdb 原地留着, 看起来像"没生成波形"。
  #    所以这里**显式覆盖**成探测到的真路径, 不继承 shell 里那个可能错的变量。
  FSDB_ENV := VERDI_HOME=$(FSDB_HOME) NOVAS_HOME=$(FSDB_HOME)
  $(info ✅ Verdi/FSDB 已启用: $(FSDB_HOME))
else
  $(warning ⚠️  未找到 Verdi 安装 (已搜: $(VERDI_ROOTS))。)
  $(warning     波形生成将不可用 —— 请设置 VERDI_HOME 或 NOVAS_HOME 环境变量。)
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
# 工具链统一用 GCC 14.2.0 (riscv-collab 官方 release 包)。
# 为什么换: 同一份源码同一个核, 只换编译器 CoreMark 从 2.584 → 2.694 (+4.25%)。
# 收益全部来自分支行为 —— 控制转移少 8.1%、误预测砍 54% (366,940 → 167,188),
# IPC 0.795 → 0.847。是编译器做 if-conversion + 更好布局的结果, 与 RTL 无关,
# 零面积。详见 memory gcc14-on-our-core。
#
# 这个包原本在本机跑不起来(要 glibc >= 2.34, 而本机是 CentOS 7 / glibc 2.17);
# 现在靠 tools/glibc234 的移植 glibc + patchelf 打过的 RPATH 就地能跑,
# **不需要设置任何 PATH 或环境变量**。详见 memory riscv32-gcc14-toolchain。
# 想临时回退到旧的 Xuantie GCC 10.4:
#   make ... TOOLCHAIN=/x2025/GPrj1/IC1/riscv/RISCV_CPU/open_riscv_2035/tools/newlib/bin CROSS=riscv64-unknown-elf-
#
# -Wl,-Ttext=0 让镜像从地址 0 开始(CPU 复位后从 PC=0 取指),
# objcopy -O binary 生成扁平镜像给 IROM/DRAM 的 $fread 用.
# ---------------------------------------------------------------------------
TOOLCHAIN ?= /x2025/GPrj1/IC1/riscv/RISCV_CPU/tools/riscv/bin
CROSS     ?= riscv32-unknown-elf-
ASM_SRCS  := $(wildcard $(PWD)/asm/*.S)
ASM_BINS  := $(patsubst $(PWD)/asm/%.S,$(PWD)/bin/%.bin,$(ASM_SRCS))

.PHONY: all build run run-all verdi clean help coremark asm muldiv-unit rtu-unit rtu-lsu-unit rtu-adapter-unit rtu-expt-unit iu-alu-unit iu-beu-unit iu-md-unit rtu-subsys-elab biu-unit a910-elab a910-run a910-difftest a910-difftest-all a910-difftest-all_wave a910-difftest-wave verdi-difftest

asm: $(ASM_BINS)

$(PWD)/bin/%.bin: $(PWD)/asm/%.S
	@mkdir -p $(PWD)/bin
	# _zicsr 不能省: asm/trap.S 用了 csrw/csrr, 而 binutils 2.43 会正确拒绝
	# 没有 zicsr 的 CSR 指令(旧的 Xuantie binutils 2.35 放过了, 所以以前没暴露)。
	@$(TOOLCHAIN)/$(CROSS)gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
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

# Build CoreMark
#
# ITERATIONS=30 才是带完整校验、可以引用的跑分: CoreMark 规定必须跑满 10 秒,
# 而本 port 里 1 拍 = 1 µs(按 1 MHz 归一, 这样分数就是 CoreMark/MHz),
# 所以迭代数少于约 11 次会被 total_errors 判掉, 打印 "Errors detected"。
# bin/coremark.bin 入库的就是 30 次那版, 所以这里默认也取 30 ——
# 否则 `make coremark` 产出的二进制和入库的对不上。
# 只要冒烟不要分数时: make coremark COREMARK_ITERATIONS=1 (快 30 倍)
#
# 必须先 clean: coremark/build/ 是入库的, 里面的 .o 比源码新, 不清的话 make
# 判定无事可做 —— 换了工具链却静默沿用上一个编译器产出的 .o/.elf
# (实测踩过: 改完 TOOLCHAIN 后 bin/coremark.bin 的 md5 纹丝不动)。
COREMARK_ITERATIONS ?= 30
coremark:
	@echo "=== Building CoreMark (GCC 14.2, ITERATIONS=$(COREMARK_ITERATIONS)) ==="
	$(MAKE) -C coremark -f Makefile.coremark clean
	$(MAKE) -C coremark -f Makefile.coremark ITERATIONS=$(COREMARK_ITERATIONS)
	@echo "CoreMark binary ready at bin/coremark.bin"
	@echo "Run with: make run TEST=coremark MAX_CYCLES=30000000"

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

PREG_CFG := $(BUILD_DIR)/.preg_cfg

$(PREG_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(PREG)" | cmp -s - $@ || echo "$(PREG)" > $@

ICACHE_CFG := $(BUILD_DIR)/.icache_cfg
BP_EN_CFG  := $(BUILD_DIR)/.bp_en_cfg

$(ICACHE_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(ICACHE)" | cmp -s - $@ || echo "$(ICACHE)" > $@

$(BP_EN_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(BP)" | cmp -s - $@ || echo "$(BP)" > $@

# dcache 容量同理: 它只派生 DEFINES (DCACHE_1KB/2KB/4KB), 三选一写错或漏定义
# 都不会报错 —— 只会让 dcache 阵列一片不例化、输出悬空。给它自己的 stamp。
DCACHE_CFG := $(BUILD_DIR)/.dcache_cfg

$(DCACHE_CFG): FORCE
	@mkdir -p $(BUILD_DIR)
	@echo "$(DCACHE_SIZE)" | cmp -s - $@ || echo "$(DCACHE_SIZE)" > $@

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

$(SIMV): $(VSRC) $(VHDR) $(SVSRC) $(DPIC) $(CSRC_GM) $(IFU_CFG) $(LBUF_CFG) $(BP_CFG) $(ICACHE_CFG) $(BP_EN_CFG) $(DCACHE_CFG) $(PREG_CFG)
	@mkdir -p $(BUILD_DIR)
	$(VCS) $(VCS_FLAGS) $(VCS_FLAGS_EXTRA) $(INC) $(DEFINES) $(BP_DEFS) $(PREG_DEFS) $(FSDB_VCS) -CFLAGS -DVCS \
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
UNIT_SRC   := $(PWD)/mySoC/iu/rtl/MUL_DIV.v $(PWD)/mySoC/iu/rtl/mul_pipe.v $(PWD)/mySoC/iu/rtl/div_pipe.v
UNIT_TB    := $(PWD)/tb/unit/tb_muldiv_unit.sv

# ⚠️ `-exitstatus` 不能省: 没有它时 $fatal(1,...) 也让 simv 返回 0,
# 于是"单元测试失败"会被 make 当成通过 (与主流程 SIM_ARGS 里那条同源)。
muldiv-unit: $(UNIT_SIMV)
	@$(UNIT_SIMV) +vcs+lic+wait -exitstatus -l $(UNIT_BUILD)/sim.log

$(UNIT_SIMV): $(UNIT_SRC) $(UNIT_TB)
	@mkdir -p $(UNIT_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) -top tb_muldiv_unit -o $(UNIT_SIMV) \
	  -Mdir=$(UNIT_BUILD)/csrc -l $(UNIT_BUILD)/compile.log \
	  $(UNIT_SRC) $(UNIT_TB)

# ---------------------------------------------------------------------------
# RTU 单元 TB: 直接驱动 RTU 的 §6 端口 (tb/unit/tb_rtu_rob.sv), 不经整核。
# 为什么单开一套: 退休单元 90% 的 bug (退休窗口/异常最旧者胜/冲刷/preg 释放与
# 恢复/ROB 满停顿) 在整核 difftest 里只会表现成"某条指令结果不对", 定位不到是
# ROB 指针、影子表项还是 preg 状态机算错; 而这些时序性质在这里一个 task 就能构造。
#
# ⚠️ BUILD_DIR 必须是**另一个**目录: obj_unit 是 muldiv-unit 的, 两家共用一个
#    目录会让 simv 互相覆盖 (先跑的赢, 后跑的看起来"没问题")。
#   make rtu-unit                       # 默认种子
#   ./obj_unit_rtu/simv +SEED=12345     # 换种子重跑
# ---------------------------------------------------------------------------
RTU_UNIT_BUILD := $(PWD)/obj_unit_rtu
RTU_UNIT_SIMV  := $(RTU_UNIT_BUILD)/simv
# 只给单元 TB 用的仿真参数 (例如 RTU_UNIT_ARGS="+SEED=123 +NINSTR=400")。
# ⚠️ 不要用 SIM_ARGS —— 那是主流程的, 而且改了它会连 -exitstatus 一起吃掉。
RTU_UNIT_ARGS  ?=
RTU_UNIT_SRC   := $(wildcard $(PWD)/mySoC/rtu/rtl/*.v)
RTU_UNIT_HDR   := $(wildcard $(PWD)/mySoC/rtu/rtl/*.vh)
RTU_UNIT_TB    := $(PWD)/tb/unit/tb_rtu_rob.sv

rtu-unit: $(RTU_UNIT_SIMV)
	@$(RTU_UNIT_SIMV) +vcs+lic+wait -exitstatus $(RTU_UNIT_ARGS) -l $(RTU_UNIT_BUILD)/sim.log

# ⚠️ 池子大小 (PREG) 只改 DEFINES ⇒ 单元台也要自己的配置戳, 否则
#    `make rtu-unit PREG=64` 会拿 96 档的 simv 跑 (切档静默失效)。
RTU_UNIT_PREG_CFG := $(RTU_UNIT_BUILD)/.preg_cfg

$(RTU_UNIT_PREG_CFG): FORCE
	@mkdir -p $(RTU_UNIT_BUILD)
	@echo "$(PREG)" | cmp -s - $@ || echo "$(PREG)" > $@

$(RTU_UNIT_SIMV): $(RTU_UNIT_SRC) $(RTU_UNIT_HDR) $(RTU_UNIT_TB) $(RTU_UNIT_PREG_CFG)
	@mkdir -p $(RTU_UNIT_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) $(PREG_DEFS) -top tb_rtu_rob -o $(RTU_UNIT_SIMV) \
	  -Mdir=$(RTU_UNIT_BUILD)/csrc -l $(RTU_UNIT_BUILD)/compile.log \
	  $(RTU_UNIT_SRC) $(RTU_UNIT_TB)

# ---------------------------------------------------------------------------
# C910 移植过来的两个单元 (Phase 1: 只要 elaborate 得过 + 上电不炸)
#
# 为什么要单开: 主构建里**没有任何模块例化** ct_idu_top / lsu_top, 而 VCS 只
# elaborate 从 -top 可达的层次 —— 这两个顶层在主构建里只会被 "Parsing",
# 内部的端口连接错误 (不存在端口名 / 位宽不符 / 未驱动网) 一个都查不出来。
# 实测确认过: 修完 IDU 的一批端口错误, `make build` 依然 0 error。
#
#   make idu-unit                  # ct_idu_top 的 elaborate 冒烟
#   make lsu-unit                  # lsu_top 的 load 冒烟 (同事自带 TB)
#   make lsu-unit LSU_UNIT_ARGS=...
#
# ⚠️ 这两个台子**都不是功能验证**: 输入接常量/假 BIU, 无自检, store 路径零覆盖。
#    它们的价值是"把 elaborate 错误逼出来", 别拿它们当回归。
# ---------------------------------------------------------------------------
IDU_UNIT_BUILD := $(PWD)/obj_unit_idu
IDU_UNIT_SIMV  := $(IDU_UNIT_BUILD)/simv
IDU_UNIT_SRC   := $(wildcard $(PWD)/mySoC/idu_c910/rtl/*.sv)
IDU_UNIT_TB    := $(PWD)/tb/unit/tb_idu_c910.sv

idu-unit: $(IDU_UNIT_SIMV)
	@$(IDU_UNIT_SIMV) +vcs+lic+wait -exitstatus -l $(IDU_UNIT_BUILD)/sim.log

# ⚠️ tb_idu_c910.sv 的 116 个端口连接是**生成的** —— 改了 ct_idu_top 的端口表
#    就要重新生成, 否则 elaborate 报 "port not found" (这正是这个台子的用处)。
#    生成器: scripts/gen_idu_smoke_tb.py
$(IDU_UNIT_SIMV): $(IDU_UNIT_SRC) $(IDU_UNIT_TB)
	@mkdir -p $(IDU_UNIT_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) -top tb_idu_c910 -o $(IDU_UNIT_SIMV) \
	  -Mdir=$(IDU_UNIT_BUILD)/csrc -l $(IDU_UNIT_BUILD)/compile.log \
	  $(IDU_UNIT_SRC) $(IDU_UNIT_TB)

LSU_UNIT_BUILD := $(PWD)/obj_unit_lsu
LSU_UNIT_SIMV  := $(LSU_UNIT_BUILD)/simv
LSU_UNIT_SRC   := $(wildcard $(PWD)/mySoC/lsu/rtl/*.sv)
LSU_UNIT_TB    :=
LSU_UNIT_ARGS  ?=
LSU_UNIT_DEFS  := +define+DCACHE_$(if $(filter 1024,$(DCACHE_SIZE)),1KB,$(if $(filter 4096,$(DCACHE_SIZE)),4KB,2KB))

# ---------------------------------------------------------------------------
# IU MULDIV 流水级单元台 (2026-10-08 立): IDU 的 MUL/DIV 发射口 ↔ MUL_DIV 单元。
# 守: 两个 rslt_sel[3:0] **位序含义不同**(乘 vs 除) / **tag={iid,preg} 的打包拆包** /
#     写回与完成同拍 / div_busy 可见性 / 被冲刷的乘法不报写回。
#
#   make iu-md-unit
# ---------------------------------------------------------------------------
IU_MD_BUILD := $(PWD)/obj_unit_iu_md
IU_MD_SIMV  := $(IU_MD_BUILD)/simv
IU_MD_SRC   := $(PWD)/mySoC/iu/rtl/IU_md_pipe.v $(PWD)/mySoC/iu/rtl/MUL_DIV.v \
               $(PWD)/mySoC/iu/rtl/mul_pipe.v $(PWD)/mySoC/iu/rtl/div_pipe.v
IU_MD_TB    := $(PWD)/tb/unit/tb_iu_md_pipe.sv

iu-md-unit: $(IU_MD_SIMV)
	@$(IU_MD_SIMV) +vcs+lic+wait -exitstatus -l $(IU_MD_BUILD)/sim.log

$(IU_MD_SIMV): $(IU_MD_SRC) $(IU_MD_TB)
	@mkdir -p $(IU_MD_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) -top tb_iu_md_pipe -o $(IU_MD_SIMV) \
	  $(IU_MD_SRC) $(IU_MD_TB)

# IU BEU 流水级单元台 (2026-10-08 立): IDU 的 BIQ 发射口 ↔ 老 BEU 的适配级。
# 守: 操作数摆放 (BIQ 的 src1 是裸 PRF 读, JALR 要喂 br_imme) / 8 位独热编码 /
#     **JALR 目标 & ~1** (老 BEU 原缺) / 重定向的两个门 / 完成与解析两条都要报。
#
#   make iu-beu-unit
# ---------------------------------------------------------------------------
IU_BEU_BUILD := $(PWD)/obj_unit_iu_beu
IU_BEU_SIMV  := $(IU_BEU_BUILD)/simv
IU_BEU_SRC   := $(PWD)/mySoC/iu/rtl/IU_beu_pipe.v $(PWD)/mySoC/iu/rtl/BEU.v
IU_BEU_TB    := $(PWD)/tb/unit/tb_iu_beu_pipe.sv

iu-beu-unit: $(IU_BEU_SIMV)
	@$(IU_BEU_SIMV) +vcs+lic+wait -exitstatus -l $(IU_BEU_BUILD)/sim.log

$(IU_BEU_SIMV): $(IU_BEU_SRC) $(IU_BEU_TB)
	@mkdir -p $(IU_BEU_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) -top tb_iu_beu_pipe -o $(IU_BEU_SIMV) \
	  $(IU_BEU_SRC) $(IU_BEU_TB)

# IU ALU 流水级单元台 (2026-10-08 立): IDU 的 AIQ 发射口 ↔ 老 ALU 的适配级。
# 守三件事 (全在整核里只表现为"某条指令结果不对"、定位不到):
#   ① 13 位独热 → alu_op 的编码转换; ② LUI/AUIPC (老 ALU 没有这两条);
#   ③ 写回协议 (expand 独热 / 唤醒口 / 完成回报 / 非法指令报完成但不写 PRF)。
#
#   make iu-alu-unit
# ---------------------------------------------------------------------------
IU_ALU_BUILD := $(PWD)/obj_unit_iu_alu
IU_ALU_SIMV  := $(IU_ALU_BUILD)/simv
IU_ALU_SRC   := $(PWD)/mySoC/iu/rtl/IU_alu_pipe.v $(PWD)/mySoC/iu/rtl/ALU.v
IU_ALU_TB    := $(PWD)/tb/unit/tb_iu_alu_pipe.sv

iu-alu-unit: $(IU_ALU_SIMV)
	@$(IU_ALU_SIMV) +vcs+lic+wait -exitstatus -l $(IU_ALU_BUILD)/sim.log

$(IU_ALU_SIMV): $(IU_ALU_SRC) $(IU_ALU_TB)
	@mkdir -p $(IU_ALU_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) -top tb_iu_alu_pipe -o $(IU_ALU_SIMV) \
	  $(IU_ALU_SRC) $(IU_ALU_TB)

# RTU_subsys elaborate 体检 (2026-10-09 立): **RTU 与它所有对端的连线**。
# 这一层把 RTU + IDU + LSU + 适配层 真的连起来 (生成自 scripts/gen_rtu_top.py),
# 这个目标只做 elaborate + 查两类**静默错**的指纹:
#   * `Error-` —— 端口/名字对不上;
#   * `Warning-[IWNF]` (隐式线网没有驱动) —— **必须为 0**。
#     ⚠️ 这条判据是有来历的: 交付的 IDU 里有 3 根 create1_en 只在消费侧连了、
#        生产侧漏连 ⇒ 悬空 Z ⇒ 那三条队列的第二 create 口整个是死的,
#        而"未声明且多位"那个扫描器**抓不到 1 位信号**, 只有 elaborate 能看见。
#   * `PCWM-W` 预期 **0**（2026-10-12 起）。那条"允许 5 条有意截断"是 2026-10-10 之前
#     的口径 —— 那时 RTU 的 preg 端口恒 7 位；自 2026-10-10 端口位宽随 PREG 档走
#     （64→6），两侧天然同宽，截断没了。非 0 会在下面提示。
#
#   make rtu-subsys-elab
# ---------------------------------------------------------------------------
SUBSYS_BUILD := $(PWD)/obj_subsys
SUBSYS_LOG   := $(SUBSYS_BUILD)/elab.log

rtu-subsys-elab:
	@mkdir -p $(SUBSYS_BUILD)
	# ⚠️ 必须先删增量目录: VCS 看到"设计没变"会直接回一句
	#    "The design hasn't changed and need not be recompiled" 并**一条警告都不重发**,
	#    于是下面的计数全是 0, 这个目标就成了永远绿的假检查。
	#    (本机时钟偏移还会让 VCS 更爱走这条捷径, 见 memory `eda-env-csh-vcs`。)
	@rm -rf $(SUBSYS_BUILD)/simv.daidir $(SUBSYS_BUILD)/simv
	@$(VCS) $(VCS_FLAGS) $(INC) +define+RTU_PREG64 -top RTU_subsys \
	  -o $(SUBSYS_BUILD)/simv $(VSRC) > $(SUBSYS_LOG) 2>&1 || true
	@E=$$(grep -cE 'Error-\[' $(SUBSYS_LOG) || true); \
	 W=$$(grep -cE 'Warning-\[IWNF\]' $(SUBSYS_LOG) || true); \
	 P=$$(grep -A2 'Warning-\[PCWM-W\]' $(SUBSYS_LOG) | grep -c 'RTU_subsys.v' || true); \
	 echo "  Error=$$E  IWNF(悬空线)=$$W  PCWM-W(位宽)=$$P"; \
	 if [ "$$E" != "0" ]; then echo "  ❌ elaborate 失败, 见 $(SUBSYS_LOG)"; exit 1; fi; \
	 if [ "$$W" != "0" ]; then \
	   echo "  ❌ 有悬空线 —— 某个信号连了但没驱动 (症状是静默的, 见本目标的注释)"; \
	   grep -A3 'Warning-\[IWNF\]' $(SUBSYS_LOG) | grep 'Implicit wire' | sort -u; exit 1; fi; \
	 if [ "$$P" != "0" ]; then \
	   echo "  ⚠️ RTU_subsys.v 里 PCWM-W = $$P, 预期 0。\n     2026-10-12 起预期是 0: 生成器补了 `RTU_PREG_W` 的数值代换, RTU 的 preg 网\n     与 IDU 的 6 位口天然同宽 (PREG=64), 那 5 条'有意截断'不复存在。\n     ⚠️ 若又冒出来, 先怀疑生成器又把某根网的位宽落成了 1 位 (见 scripts/gen_rtu_top.py\n     的 GEO/resolve_width —— 那里栽过两次), 别急着改预期值。"; fi; \
	 echo "  ✅ RTU_subsys elaborate 通过 (RTU ↔ IDU/LSU 连线已接死)"

# ---------------------------------------------------------------------------
# A910_cpu 顶层 elaborate 检查 (2026-10-10 立)
# ---------------------------------------------------------------------------
# 守的是 mySoC/A910_cpu.sv 里 RTU 与 IFU 的对外连线 —— 那个文件先前是个空壳
# (RTU 的 130 个端口全空、IFU 只接了一半, 且第 1 行少了 m、端口表里没有时钟
# 复位)。这里把接线锁成可回归的判据。
#
# Criteria :
#   * Error-[ 必须为 0。
#
#   * Warning-[IWNF] (隐式线网没有驱动) 必须为 0。它有来历: 交付的 IDU 里 3 根
#     create1_en 只在消费侧连了、生产侧漏连, 悬空 Z 让那三条队列的第二 create 口
#     整个变成死的, 而"未声明且多位"那个扫描器抓不到 1 位信号。
#
#     ⚠️ 它抓的是"端口上写了一个没声明过的名字"(笔误或漏声明)。A910_cpu.sv 里
#        那批有意不接的待接口是显式声明过的, 所以不会在这里报出来 —— 它们登记在
#        A910_cpu.sv 末尾的"待接清单"里, 由人复核, 不靠这条判据。
#
#   * Warning-[DCTTSW] (常量被静默截断) 必须为 0。例如往 2 位寄存器里塞 2'd4 会
#     变成 0, 状态机于是永远走不到那一支, 既不报错也不变成 X。(2026-10-10 真
#     踩过: ifu_biu_axi 的 beat_left_q 少了 1 位, 4 拍请求走完之后 busy 落不下来,
#     取指通路就此卡死。)
#
#   * PCWM-W 必须为 0。
#     ⚠️ 2026-10-10 前这里写的是"恰好 5 条" —— 那 5 条是 RTU 端口固定 7 位、而交付的
#        IDU PRF 是 6 位, 靠端口处的隐式截位凑出来的。现在 RTU 的 preg 端口**随
#        `RTU_PREG_W 走** (64 档 = 6 位), 两侧天然同宽 ⇒ 那 5 条消失, 判据收紧到 0。
#        跨模块的位宽差现在**全部显式**落在适配层里 (切位/重排), 不再有隐式截断。
#
# Defines :
#   两个都必需, 少一个都会得到"看起来通过、实际错"的结果。
#
#   * +define+RTU_PREG64 —— 适配层里有配置守卫, RTU_NUM_PREG != 64 时 elaborate
#     直接失败; 而交付的 C910 IDU 的 PRF 是 64 项 / 6 位。
#
#   * +define+DCACHE_2KB —— lsu 的 dcache 阵列整个包在 `ifdef DCACHE_* 里, 一个
#     都不定义则阵列一片不例化, 输出悬空 (Z), 读出来全是 X 且不报错。与 lsu_top
#     的 DCACHE_SIZE 默认值 (2048) 配套。
#
#   make a910-elab
# ---------------------------------------------------------------------------
A910_BUILD := $(PWD)/obj_a910
A910_LOG   := $(A910_BUILD)/elab.log
A910_SRC   := $(PWD)/mySoC/A910_cpu.sv \
              $(wildcard $(PWD)/mySoC/ifu2/rtl/*.v) \
              $(wildcard $(PWD)/mySoC/rtu/rtl/*.v) \
              $(wildcard $(PWD)/mySoC/idu_c910/rtl/*.sv) \
              $(wildcard $(PWD)/mySoC/iu/rtl/*.v) \
              $(wildcard $(PWD)/mySoC/lsu/rtl/*.sv) \
              $(wildcard $(PWD)/mySoC/biu/rtl/*.sv)

a910-elab:
	@mkdir -p $(A910_BUILD)
	# ⚠️ 必须先删增量目录: VCS 看到"设计没变"会直接回一句
	#    "The design hasn't changed and need not be recompiled" 并**一条警告都不重发**,
	#    于是下面的计数全是 0, 这个目标就成了永远绿的假检查。
	#    (本机时钟偏移还会让 VCS 更爱走这条捷径, 见 memory `eda-env-csh-vcs`。)
	@rm -rf $(A910_BUILD)/simv.daidir $(A910_BUILD)/simv
	@$(VCS) $(VCS_FLAGS) $(INC) +define+RTU_PREG64 +define+DCACHE_2KB \
	  -top A910_cpu -o $(A910_BUILD)/simv $(A910_SRC) > $(A910_LOG) 2>&1 || true
	@E=$$(grep -cE 'Error-\[' $(A910_LOG) || true); \
	 W=$$(grep -cE 'Warning-\[IWNF\]' $(A910_LOG) || true); \
	 T=$$(grep -cE 'Warning-\[DCTTSW\]' $(A910_LOG) || true); \
	 P=$$(grep -A2 'Warning-\[PCWM-W\]' $(A910_LOG) | grep -c 'A910_cpu.sv' || true); \
	 echo "  Error=$$E  IWNF(悬空线)=$$W  DCTTSW(常量截断)=$$T  PCWM-W(A910_cpu.sv 里)=$$P"; \
	 if [ "$$E" != "0" ]; then echo "  ❌ elaborate 失败, 见 $(A910_LOG)"; exit 1; fi; \
	 if [ "$$W" != "0" ]; then \
	   echo "  ❌ 有悬空线 —— 某个信号连了但没驱动 (症状是静默的, 见本目标的注释)"; \
	   grep -A3 'Warning-\[IWNF\]' $(A910_LOG) | grep 'Implicit wire' | sort -u; exit 1; fi; \
	 if [ "$$T" != "0" ]; then \
	   echo "  ❌ 有常量被静默截断 (例如往 2 位寄存器里塞 2'd4 ⇒ 变成 0)。"; \
	   echo "     这类错**不报错、也不变成 X**, 只会让状态机永远走不到那一支。"; \
	   grep -A4 'Warning-\[DCTTSW\]' $(A910_LOG) | head -20; exit 1; fi; \
	 if [ "$$P" != "0" ]; then \
	   echo "  ❌ A910_cpu.sv 里 PCWM-W = $$P, 预期 0 (2026-10-10 起 RTU 的 preg 端口\n     随 PREG 档走, 与 IDU 天然同宽; 位宽差全部显式落在适配层)。\n     逐条查上面的日志 —— 每一条都可能是隐式截断。"; exit 1; fi; \
	 echo "  ✅ A910_cpu elaborate 通过 (RTU ↔ IDU/LSU/IFU/BIU 连线已接死)"

# ---------------------------------------------------------------------------
# A910_cpu 整核**冒烟台** (2026-10-11 立): 乱序多发射新顶层的第一个能跑的 TB。
#
# 为什么之前没有: 全仓没有任何 TB 例化 A910_cpu, `a910-elab` 只 elaborate 不仿真
#   ⇒ 这个核一次都没跑过。本目标补上"能跑起来 + 能自动判 PASS/FAIL"。
#
#   make a910-run TEST=a910_smoke        # 直线自检用例 (先跑这个)
#   make a910-run TEST=muldiv_edge       # 现成用例 (⚠️ 见下)
#
# 【怎么判对错】不接 difftest —— 顶层 `dbg_commit_*` 是架构寄存器视角的退休 trace,
#   TB 盯 `dbg_commit_reg==5'd10` 抓 a0 即可。用例把自检压进 a0 (无分支自检)。
#
# ⚠️ 现成用例**可能失败, 而且大概率不是 TB 的问题**: `ct_idu_top.sv:332` 的
#    `idu_accept_num` 只有 2'b00/2'b11 且不看 `ifu_idu_ib_inst*_vld` (见记忆
#    `idu-accept-num-contract`), IBUF 半满时会丢指令。现成用例开头就有 `jal` +
#    中间有 `beq`, 正好踩那个窗口 ⇒ 那是该 bug 在全核层面的**复现**, 不是回归。
#    `a910_smoke.S` 特意做成纯直线无跳转, 就是为了能把这个区分开。
#
# ⚠️ 独立 BUILD_DIR: 别和 `a910-elab` 的 obj_a910/ 共用 (会互相覆盖 simv)。
# ⚠️ TB 放在 tb/a910/ 子目录: `SVSRC := $(wildcard $(PWD)/tb/*.sv)` 会把 tb/ 平级的
#    所有 .sv 收进主构建, 放外面会污染 tb_miniRV_dpi 的编译。
# ---------------------------------------------------------------------------
A910_SIM_BUILD := $(PWD)/obj_a910_sim
A910_SIMV      := $(A910_SIM_BUILD)/simv
A910_TB_SRC    := $(PWD)/tb/a910/tb_a910_smoke.sv $(PWD)/tb/a910/axi_slave_128.v
# 只给本台用的仿真参数; 不要用 SIM_ARGS (那是主流程的, 改了会连 -exitstatus 一起吃掉)
A910_SIM_ARGS  ?=

a910-run: $(A910_SIMV) $(PWD)/bin/$(TEST).hex128 $(PWD)/bin/$(TEST).hex
	@ln -sf $(PWD)/bin/$(TEST).bin    $(TESTFILE)
	@ln -sf $(PWD)/bin/$(TEST).hex    $(TESTHEX)
	@ln -sf $(PWD)/bin/$(TEST).hex128 $(TESTHEX128)
	@$(A910_SIMV) +vcs+lic+wait -exitstatus $(A910_SIM_ARGS) \
	  +MAX_CYCLES=$(MAX_CYCLES) -l $(A910_SIM_BUILD)/sim.log

# 一键运行 a910_smoke 测试并自动打开波形
a910-run_smoke:
	@echo "===================================================="
	@echo "  运行 a910_smoke 测试并生成波形..."
	@echo "===================================================="
	@$(MAKE) a910-run TEST=a910_smoke || true
	@echo ""
	@echo "===================================================="
	@echo "  打开 Verdi 查看波形..."
	@echo "===================================================="
	@$(MAKE) verdi

$(A910_SIMV): $(A910_SRC) $(A910_TB_SRC)
	@mkdir -p $(A910_SIM_BUILD)
	$(VCS) $(VCS_FLAGS) $(VCS_FLAGS_EXTRA) $(INC) $(FSDB_VCS) \
	  +define+RTU_PREG64 +define+DCACHE_2KB +define+FSDB \
	  +define+PATH=$(TESTFILE) +define+PATHHEX=$(TESTHEX) +define+PATH128=$(TESTHEX128) \
	  -top tb_a910_smoke -o $(A910_SIMV) -Mdir=$(A910_SIM_BUILD)/csrc \
	  -l $(A910_SIM_BUILD)/compile.log \
	  $(A910_SRC) $(A910_TB_SRC)

# ---------------------------------------------------------------------------
# A910 的 **difftest 台** (2026-10-12 立): 用现成的黄金模型逐条比对退休流。
#
# 【为什么必须有它】冒烟台的判据 (看到 x17=93 且 a0==0) 会被 riscv-tests 的
#   布局骗过 —— `fail` 块紧挨在 `pass` 块前面, 而 `ecall` 在 A910 顶层不停机
#   ⇒ "走错路撞进 fail, 再落穿进 pass" 会报 PASS。实测 `beq` 用例就是这样:
#   分支根本没生效, 冒烟台照样绿。**顺序核那批用例不能用冒烟台判对错。**
#
# 【判据】`golden_model/` + `dpi/dpi_shim.c` (与 tb_miniRV_dpi 同一份)。
#   模型是**提交步进**: 每调一次 `gm_check_step()` 才走一条架构指令并逐位比对;
#   收尾由 `cpu_poll_halt()` 判 (停在第一个 ecall, 用当时的 a0 定 pass/fail)。
#
#   make a910-difftest TEST=addi
#   make a910-difftest TEST=addi A910_DT_ARGS=+TRACE     # 打全部退休流
#   make a910-difftest-all                               # 整套 bin/*.bin
#
# ⚠️ 独立 BUILD_DIR (别和 obj_a910/、obj_a910_sim/ 共用 —— 三者的 define 与
#    top 都不同, 共用会互相覆盖 simv)。
# ⚠️ 不开 FSDB: 这套台要跑几十个用例, 波形会让每个用例慢一个量级。
# ---------------------------------------------------------------------------
A910_DT_BUILD := $(PWD)/obj_a910_dt
A910_DT_SIMV  := $(A910_DT_BUILD)/simv
A910_DT_TB    := $(PWD)/tb/a910/tb_a910_difftest.sv $(PWD)/tb/a910/axi_slave_128.v
A910_DT_ARGS  ?=
# 顺序核的用例里跑得最久的也就几十万拍; 卡死的用例要快速暴露, 所以给个小上限。
A910_DT_MAX_CYCLES ?= 200000

a910-difftest: $(A910_DT_SIMV) $(PWD)/bin/$(TEST).bin $(PWD)/bin/$(TEST).hex $(PWD)/bin/$(TEST).hex128
	@ln -sf $(PWD)/bin/$(TEST).bin    $(TESTFILE)
	@ln -sf $(PWD)/bin/$(TEST).hex    $(TESTHEX)
	@ln -sf $(PWD)/bin/$(TEST).hex128 $(TESTHEX128)
	@$(A910_DT_SIMV) +vcs+lic+wait -exitstatus +TEST=$(TEST) $(A910_DT_ARGS) \
	  +MAX_CYCLES=$(A910_DT_MAX_CYCLES) -l $(A910_DT_BUILD)/sim.log

$(A910_DT_SIMV): $(A910_SRC) $(A910_DT_TB) $(DPIC) $(CSRC_GM)
	@mkdir -p $(A910_DT_BUILD)
	$(VCS) $(VCS_FLAGS) $(VCS_FLAGS_EXTRA) $(INC) \
	  -CFLAGS -DVCS -CFLAGS -I$(PWD)/golden_model/include \
	  +define+RTU_PREG64 +define+DCACHE_2KB \
	  +define+PATH=$(TESTFILE) +define+PATHHEX=$(TESTHEX) +define+PATH128=$(TESTHEX128) \
	  -top tb_a910_difftest -o $(A910_DT_SIMV) -Mdir=$(A910_DT_BUILD)/csrc \
	  -l $(A910_DT_BUILD)/compile.log \
	  $(A910_SRC) $(A910_DT_TB) $(DPIC) $(CSRC_GM)

# 整套顺序核用例 × A910 difftest, 末尾给一张 PASS/FAIL 总表。
# 每个用例一行; 失败的在 /tmp/a910_dt/<用例>.log 里有完整对照。
# ⚠️ coremark 不在默认列表里 (千万拍级, 且它靠外设 MONITOR 收尾, 本台没接外设)
# ⚠️ npu_loop / npu_smoke: NPU 还在做 (2026-10-14: npu_loop 第 6 条退休就失配),
#    先排除, 免得整套总表被两条在做中的用例染红。NPU 收尾后从这行删掉即可。
A910_DT_SKIP ?= coremark start peri trap npu_loop npu_smoke

a910-difftest-all: $(A910_DT_SIMV)
	@mkdir -p /tmp/a910_dt
	@pass=""; fail=""; \
	for f in $(PWD)/bin/*.bin; do \
	  t=$$(basename $$f .bin); \
	  case " $(A910_DT_SKIP) " in *" $$t "*) continue;; esac; \
	  $(MAKE) --no-print-directory a910-difftest TEST=$$t > /tmp/a910_dt/$$t.log 2>&1; \
	  if [ $$? -eq 0 ]; then pass="$$pass $$t"; st="PASS"; else fail="$$fail $$t"; st="FAIL"; fi; \
	  printf "  %-16s %s\n" "$$t" "$$st"; \
	done; \
	echo; echo "==================== A910 difftest 汇总 ===================="; \
	echo "PASS ($$(echo $$pass | wc -w)):"; \
	if [ -n "$$pass" ]; then echo "$$pass" | sed -e 's/^ //; s/ /, /g'; else echo "  (无)"; fi; \
	echo "FAIL ($$(echo $$fail | wc -w)):"; \
	if [ -n "$$fail" ]; then echo "$$fail" | sed -e 's/^ //; s/ /, /g'; else echo "  (无)"; fi; \
	echo "日志: /tmp/a910_dt/<用例>.log"

# ---------------------------------------------------------------------------
# A910 difftest 带波形版本
#
# 【目的】运行 a910-difftest-all 的**同一套用例**并生成波形，跑完自动用 verdi 打开
#         本次跑出来的波形（有失败用例就开第一个失败的，否则开最后一个跑过的）。
#
# 与 a910-difftest-all 的区别：
#   - 用另一个 simv (obj_a910_dt_wave/): 编译时加 +define+FSDB 并链接 Verdi 的
#     novas PLI —— **没有 PLI 则 $fsdbDumpvars 是空操作, FSDB 文件里一条信号都没有**
#   - 运行时加 +WAVE=<用例名>, 波形落到 waveform/<用例名>.fsdb
#   - 跑完自动开 verdi (见下面 verdi-difftest)
#
# 用法:
#   make a910-difftest-all_wave              # 跑整套并出波形, 自动开 verdi
#   make a910-difftest-wave TEST=<test>      # 只跑一个用例并出波形, 自动开 verdi
#   make verdi-difftest WAVE=<test>          # 只开已有波形, 不重跑
# ---------------------------------------------------------------------------
A910_DT_WAVE_BUILD := $(PWD)/obj_a910_dt_wave
# ⚠️ 日志目录**不能**用 /tmp/a910_dt (a910-difftest-all 用的那个): 那个目录在多用户
#    机器上常是别人(如 IC1)先建的、别人的属主 + 755, 本用户只在 others 位上有 r-x ⇒
#    写日志直接 "Permission denied", 连带整个用例判 FAIL。改成写在自己的构建目录下。
A910_DT_WAVE_LOG   := $(A910_DT_WAVE_BUILD)/logs
A910_DT_WAVE_SIMV  := $(A910_DT_WAVE_BUILD)/simv

# 带 FSDB 波形支持的 difftest simv
$(A910_DT_WAVE_SIMV): $(A910_SRC) $(A910_DT_TB) $(DPIC) $(CSRC_GM)
	@mkdir -p $(A910_DT_WAVE_BUILD)
	$(VCS) $(VCS_FLAGS) $(VCS_FLAGS_EXTRA) $(INC) $(FSDB_VCS) \
	  -CFLAGS -DVCS -CFLAGS -I$(PWD)/golden_model/include \
	  +define+RTU_PREG64 +define+DCACHE_2KB +define+FSDB \
	  +define+PATH=$(TESTFILE) +define+PATHHEX=$(TESTHEX) +define+PATH128=$(TESTHEX128) \
	  -top tb_a910_difftest -o $(A910_DT_WAVE_SIMV) -Mdir=$(A910_DT_WAVE_BUILD)/csrc \
	  -l $(A910_DT_WAVE_BUILD)/compile.log \
	  $(A910_SRC) $(A910_DT_TB) $(DPIC) $(CSRC_GM)

# 单个测试带波形
# ⚠️ 仿真那行必须 `|| true`: difftest 失配时 simv 返回非 0, 而**失配正是最想看波形
#    的时候** —— 不加的话 make 会当场中止, 下面开 verdi 的那步根本轮不到执行。
a910-difftest-wave: $(A910_DT_WAVE_SIMV) $(PWD)/bin/$(TEST).bin $(PWD)/bin/$(TEST).hex $(PWD)/bin/$(TEST).hex128
	@ln -sf $(PWD)/bin/$(TEST).bin    $(TESTFILE)
	@ln -sf $(PWD)/bin/$(TEST).hex    $(TESTHEX)
	@ln -sf $(PWD)/bin/$(TEST).hex128 $(TESTHEX128)
	@mkdir -p waveform
	@echo "===================================================="
	@echo "  运行 a910-difftest 测试: $(TEST) (生成波形)"
	@echo "===================================================="
	@$(FSDB_ENV) $(A910_DT_WAVE_SIMV) +vcs+lic+wait -exitstatus +TEST=$(TEST) $(A910_DT_ARGS) \
	  +WAVE=$(TEST) +MAX_CYCLES=$(A910_DT_MAX_CYCLES) -l $(A910_DT_WAVE_BUILD)/sim_$(TEST).log || true
	@echo ""
	@echo "===================================================="
	@echo "  打开 Verdi 查看波形: waveform/$(TEST).fsdb"
	@echo "===================================================="
	@$(MAKE) verdi-difftest WAVE=$(TEST)

# 所有测试带波形
a910-difftest-all_wave: $(A910_DT_WAVE_SIMV)
	@mkdir -p $(A910_DT_WAVE_LOG)
	@mkdir -p waveform
	@echo "===================================================="
	@echo "  运行所有 a910-difftest 测试并生成波形"
	@echo "===================================================="
	@pass=""; fail=""; fail_tests=""; last_run=""; \
	for f in $(PWD)/bin/*.bin; do \
	  t=$$(basename $$f .bin); \
	  case " $(A910_DT_SKIP) " in *" $$t "*) continue;; esac; \
	  echo "----------------------------------------"; \
	  echo "测试: $$t"; \
	  ln -sf $(PWD)/bin/$$t.bin $(TESTFILE); \
	  ln -sf $(PWD)/bin/$$t.hex $(TESTHEX); \
	  ln -sf $(PWD)/bin/$$t.hex128 $(TESTHEX128); \
	  $(FSDB_ENV) $(A910_DT_WAVE_SIMV) +vcs+lic+wait -exitstatus +TEST=$$t $(A910_DT_ARGS) \
	    +WAVE=$$t +MAX_CYCLES=$(A910_DT_MAX_CYCLES) \
	    -l $(A910_DT_WAVE_LOG)/$$t.log > $(A910_DT_WAVE_LOG)/$$t.out 2>&1; \
	  if [ $$? -eq 0 ]; then \
	    pass="$$pass $$t"; st="PASS"; \
	  else \
	    fail="$$fail $$t"; fail_tests="$$fail_tests $$t"; st="FAIL"; \
	  fi; \
	  last_run=$$t; \
	  printf "  %-16s %s\n" "$$t" "$$st"; \
	done; \
	echo; echo "==================== A910 difftest 汇总 ===================="; \
	echo "PASS ($$(echo $$pass | wc -w)):"; \
	if [ -n "$$pass" ]; then echo "$$pass" | sed -e 's/^ //; s/ /, /g'; else echo "  (无)"; fi; \
	echo "FAIL ($$(echo $$fail | wc -w)):"; \
	if [ -n "$$fail" ]; then echo "$$fail" | sed -e 's/^ //; s/ /, /g'; else echo "  (无)"; fi; \
	echo "日志: $(A910_DT_WAVE_LOG)/<用例>.log"; \
	echo "波形: waveform/<用例>.fsdb"; \
	echo ""; \
	open_wave=$$last_run; \
	if [ -n "$$fail_tests" ]; then \
	  open_wave=$$(echo $$fail_tests | awk '{print $$1}'); \
	  echo "===================================================="; \
	  echo "  有失败用例 —— 打开第一个失败用例 ($$open_wave) 的波形"; \
	  echo "===================================================="; \
	else \
	  echo "===================================================="; \
	  echo "  全部通过 —— 打开本次跑过的最后一个用例 ($$open_wave) 的波形"; \
	  echo "===================================================="; \
	fi; \
	if [ -z "$$open_wave" ]; then \
	  echo "⚠️  没有可打开的用例 (全部被 A910_DT_SKIP 跳过了?), 不开 verdi。"; \
	  exit 0; \
	fi; \
	echo "波形文件: waveform/$$open_wave.fsdb"; \
	$(MAKE) --no-print-directory verdi-difftest WAVE=$$open_wave

# RTU 适配层单元台 (2026-10-08 立): 直接驱动 RTU_idu_lsu_adapter 两侧端口, 不经整核。
# 它守的是适配层里**有真逻辑**的四类变换 (不是纯接线):
#   请求计数 / 映射恢复表逐槽重排 / 异常三路平行 + 门控 + cause 编码 / store 重放两根来源。
# 为什么单开: 这几条在整核 difftest 里只表现成"某条指令结果不对", 定位不到适配层;
#   其中"恢复表逐槽重排"写成切低位也能跑过功能测试 (恢复表只在冲刷时用)。
# ⚠️ 异常那条 2026-10-10 改过方向: 原来查"两源取最旧", 现在查"**同拍两路都送出去**"
#   (仲裁已搬进 RTU_expt) —— 有人把仲裁加回适配层的话, 这个台会报 FAIL。
#
#   make rtu-adapter-unit
# ---------------------------------------------------------------------------
# ⚠️ 这个台**固定按 PREG=64 编译**: 适配层是给同事交付的 C910 IDU 用的,
#    而那个 IDU 的 PRF 是 **64 项 / 6 位**; 适配层里有一条配置自检
#    (`RTU_NUM_PREG > (1 << IDU_PREG_W)` ⇒ elaborate 失败) —— 用默认的 96 档跑,
#    自检**会正确地报错**, 那不是在提示台子坏了, 是在提示"96 档得先扩 IDU 的 PRF"。
RTU_ADP_PREG_DEFS := +define+RTU_PREG64
RTU_ADP_BUILD := $(PWD)/obj_unit_rtu_adptr
RTU_ADP_SIMV  := $(RTU_ADP_BUILD)/simv
RTU_ADP_SRC   := $(wildcard $(PWD)/mySoC/rtu/rtl/*.v)
RTU_ADP_HDR   := $(wildcard $(PWD)/mySoC/rtu/rtl/*.vh)
RTU_ADP_TB    := $(PWD)/tb/unit/tb_rtu_adapter.sv

rtu-adapter-unit: $(RTU_ADP_SIMV)
	@$(RTU_ADP_SIMV) +vcs+lic+wait -exitstatus -l $(RTU_ADP_BUILD)/sim.log

$(RTU_ADP_SIMV): $(RTU_ADP_SRC) $(RTU_ADP_HDR) $(RTU_ADP_TB)
	@mkdir -p $(RTU_ADP_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) $(RTU_ADP_PREG_DEFS) -top tb_rtu_adapter -o $(RTU_ADP_SIMV) \
	  $(RTU_ADP_SRC) $(RTU_ADP_TB)

# ---------------------------------------------------------------------------
# RTU 异常收集单元台 (2026-10-10 立): 三源锦标赛取最旧
#
# 为什么单开: 2026-10-10 把异常的仲裁从 `RTU_idu_lsu_adapter` **搬进了 RTU_expt**
# (上游先合成一路会在**同拍冲突**时永久丢异常 —— 被丢的那条比 trap 那条老,
#  不在冲刷范围内, 会带着"无异常"的表项正常退休)。
# 搬进来之后适配层那个台**不再覆盖**这段逻辑, 所以这里补上。
#
# 判据分四组: 单源三路 / **同拍两两与三路组合** / 跨拍"更老才覆盖" / 冲刷清空。
# 中间那组是重点 —— 它查的是"**收下的是最老那条, 且 cause/tval 也一起选对**",
# 不是"选了哪一条"。
#
#   make rtu-expt-unit
# ---------------------------------------------------------------------------
RTU_EXPT_BUILD := $(PWD)/obj_unit_rtu_expt
RTU_EXPT_SIMV  := $(RTU_EXPT_BUILD)/simv
RTU_EXPT_SRC   := $(wildcard $(PWD)/mySoC/rtu/rtl/*.v)
RTU_EXPT_HDR   := $(wildcard $(PWD)/mySoC/rtu/rtl/*.vh)
RTU_EXPT_TB    := $(PWD)/tb/unit/tb_rtu_expt.sv

rtu-expt-unit: $(RTU_EXPT_SIMV)
	@$(RTU_EXPT_SIMV) +vcs+lic+wait -exitstatus -l $(RTU_EXPT_BUILD)/sim.log

$(RTU_EXPT_SIMV): $(RTU_EXPT_SRC) $(RTU_EXPT_HDR) $(RTU_EXPT_TB)
	@mkdir -p $(RTU_EXPT_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) -top tb_rtu_expt -o $(RTU_EXPT_SIMV) \
	  $(RTU_EXPT_SRC) $(RTU_EXPT_TB)

# RTU + LSU 联合单元台 (2026-10-08 立): 把两个交付物**真的连起来** elaborate
#
# 为什么要有它: 主构建里没有任何模块例化 ct_idu_top/lsu_top, 而两个冒烟台各连各的
# 常量 ⇒ RTU↔LSU 那 16 根线**从来没被检查过**。这个台子是第一次把两侧接起来。
#   make rtu-lsu-unit
#   make rtu-lsu-unit RTU_LSU_ARGS=+DUMP       # 存 FSDB
# ---------------------------------------------------------------------------
RTU_LSU_BUILD := $(PWD)/obj_unit_rtu_lsu
RTU_LSU_SIMV  := $(RTU_LSU_BUILD)/simv
RTU_LSU_ARGS  ?=
RTU_LSU_SRC   := $(wildcard $(PWD)/mySoC/rtu/rtl/*.v) $(wildcard $(PWD)/mySoC/lsu/rtl/*.sv)
RTU_LSU_HDR   := $(wildcard $(PWD)/mySoC/rtu/rtl/*.vh)
RTU_LSU_TB    := $(PWD)/tb/unit/tb_rtu_lsu.sv

rtu-lsu-unit: $(RTU_LSU_SIMV)
	@$(RTU_LSU_SIMV) +vcs+lic+wait -exitstatus $(RTU_LSU_ARGS) -l $(RTU_LSU_BUILD)/sim.log

$(RTU_LSU_SIMV): $(RTU_LSU_SRC) $(RTU_LSU_HDR) $(RTU_LSU_TB)
	@mkdir -p $(RTU_LSU_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) $(LSU_UNIT_DEFS) -top tb_rtu_lsu -o $(RTU_LSU_SIMV) \
	  -Mdir=$(RTU_LSU_BUILD)/csrc -l $(RTU_LSU_BUILD)/compile.log \
	  $(RTU_LSU_SRC) $(RTU_LSU_TB)

lsu-unit: $(LSU_UNIT_SIMV)
	@$(LSU_UNIT_SIMV) +vcs+lic+wait -exitstatus $(LSU_UNIT_ARGS) -l $(LSU_UNIT_BUILD)/sim.log

$(LSU_UNIT_SIMV): $(LSU_UNIT_SRC)
	@mkdir -p $(LSU_UNIT_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) $(LSU_UNIT_DEFS) -o $(LSU_UNIT_SIMV) \
	  -Mdir=$(LSU_UNIT_BUILD)/csrc -l $(LSU_UNIT_BUILD)/compile.log \
	  $(LSU_UNIT_SRC)

# ---------------------------------------------------------------------------
# BIU 单元 TB (2026-10-10 立): BIU (总线接口单元) 的 elaborate 检查。
# BIU 负责仲裁 IFU 和 LSU 的 AXI 读写请求。
# 这个目标进行 elaborate 检查，确保端口连接正确。
#
#   make biu-unit
# ---------------------------------------------------------------------------
BIU_UNIT_BUILD := $(PWD)/obj_unit_biu
BIU_UNIT_SIMV  := $(BIU_UNIT_BUILD)/simv
BIU_UNIT_SRC   := $(wildcard $(PWD)/mySoC/biu/rtl/*.sv)

biu-unit: $(BIU_UNIT_SIMV)
	@echo "✅ BIU 单元编译成功"

$(BIU_UNIT_SIMV): $(BIU_UNIT_SRC)
	@mkdir -p $(BIU_UNIT_BUILD)
	$(VCS) $(VCS_FLAGS) $(INC) -top ct_biu_top -o $(BIU_UNIT_SIMV) \
	  -Mdir=$(BIU_UNIT_BUILD)/csrc -l $(BIU_UNIT_BUILD)/compile.log \
	  $(BIU_UNIT_SRC)

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

# A910 专用的源文件列表
A910_VERDI_SRC := $(A910_SRC) $(A910_TB_SRC)
A910_VERDI_TOP := tb_a910_smoke
# ⚠️ 2026-10-11 修: Verdi 会**重新解析一遍 RTL**, 必须给它和编译时**同一套**
#    define/incdir, 否则解析出来的位宽与 FSDB 里记的对不上 —— 后果是波形里
#    信号的位宽显示错乱 (实测: `rtu_preg_alloc0` 在 FSDB 里是 6 位 `[5:0]`,
#    但 Verdi 不带 define 时走 RTU_define.vh 的 else 分支拿 `RTU_PREG_W=7`,
#    两边不一致)。
#    缺 +incdir 还会让 `` `include "defines.vh" `` 找不到文件。
A910_VERDI_DEFS := +define+RTU_PREG64 +define+DCACHE_2KB \
                   +incdir+$(PWD)/mySoC +incdir+$(PWD)/vsrc +incdir+$(PWD)/mySoC/rtu/rtl

# a910-difftest 专用的 Verdi 配置（与 smoke 测试分开）
A910_DT_VERDI_SRC := $(A910_SRC) $(A910_DT_TB)
A910_DT_VERDI_TOP := tb_a910_difftest
A910_DT_VERDI_DEFS := +define+RTU_PREG64 +define+DCACHE_2KB +define+FSDB \
                      +incdir+$(PWD)/mySoC +incdir+$(PWD)/vsrc +incdir+$(PWD)/mySoC/rtu/rtl

verdi:
	# 如果没有指定 WAVE，自动找最新的波形文件
	@if [ -z "$(WAVE)" ]; then \
	  LATEST=$$(ls -t waveform/*.fsdb 2>/dev/null | head -1); \
	  if [ -n "$$LATEST" ]; then \
	    echo "打开最新波形: $$LATEST"; \
	    $(VERDI) -sverilog -ssf $$LATEST $(A910_VERDI_DEFS) -top $(A910_VERDI_TOP) $(A910_VERDI_SRC) & \
	  else \
	    echo "No FSDB found under waveform/. Run simulation first." ; \
	  fi; \
	elif [ "$(FMT)" = "fsdb" ] && [ -f waveform/$(WAVE).fsdb ]; then \
	  $(VERDI) -sverilog -ssf waveform/$(WAVE).fsdb $(A910_VERDI_DEFS) -top $(A910_VERDI_TOP) $(A910_VERDI_SRC) & \
	elif [ "$(FMT)" = "vcd" ] && [ -f waveform/$(WAVE).vcd ]; then \
	  $(VERDI) -sverilog -vcd waveform/$(WAVE).vcd $(A910_VERDI_DEFS) -top $(A910_VERDI_TOP) $(A910_VERDI_SRC) & \
	elif [ -f waveform/$(WAVE).fsdb ]; then \
	  $(VERDI) -sverilog -ssf waveform/$(WAVE).fsdb $(A910_VERDI_DEFS) -top $(A910_VERDI_TOP) $(A910_VERDI_SRC) & \
	elif [ -f waveform/$(WAVE).vcd ]; then \
	  $(VERDI) -sverilog -vcd waveform/$(WAVE).vcd $(A910_VERDI_DEFS) -top $(A910_VERDI_TOP) $(A910_VERDI_SRC) & \
	elif [ -f waveform/waves.fsdb ]; then \
	  $(VERDI) -sverilog -ssf waveform/waves.fsdb $(A910_VERDI_DEFS) -top $(A910_VERDI_TOP) $(A910_VERDI_SRC) & \
	elif [ -f waveform/waves.vcd ]; then \
	  $(VERDI) -sverilog -vcd waveform/waves.vcd $(A910_VERDI_DEFS) -top $(A910_VERDI_TOP) $(A910_VERDI_SRC) & \
	else \
	  echo "No FSDB/VCD found: waveform/$(WAVE). Run simulation first." ; \
	fi

# 专门用于打开 a910-difftest 波形的 verdi 目标
verdi-difftest:
	# 如果没有指定 WAVE，自动找最新的波形文件
	@if [ -z "$(WAVE)" ]; then \
	  LATEST=$$(ls -t waveform/*.fsdb 2>/dev/null | head -1); \
	  if [ -n "$$LATEST" ]; then \
	    echo "打开最新 difftest 波形: $$LATEST"; \
	    $(VERDI) -sverilog -ssf $$LATEST $(A910_DT_VERDI_DEFS) -top $(A910_DT_VERDI_TOP) $(A910_DT_VERDI_SRC) & \
	  else \
	    echo "No FSDB found under waveform/. Run simulation first." ; \
	  fi; \
	elif [ -f waveform/$(WAVE).fsdb ]; then \
	  echo "打开 difftest 波形: waveform/$(WAVE).fsdb"; \
	  $(VERDI) -sverilog -ssf waveform/$(WAVE).fsdb $(A910_DT_VERDI_DEFS) -top $(A910_DT_VERDI_TOP) $(A910_DT_VERDI_SRC) & \
	else \
	  echo "波形文件不存在: waveform/$(WAVE).fsdb" ; \
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
	@echo "  PREG=$(PREG) (物理寄存器数量, 64|96; 只影响 RTU 池子)"
	@echo "  VCS=$(VCS)"
	@echo "  VERDI=$(VERDI)"
	@echo
	@echo "Examples:"
	@echo "  make coremark                    # Build CoreMark"
	@echo "  make run TEST=coremark MAX_CYCLES=10000000  # Run CoreMark (needs more cycles)"

