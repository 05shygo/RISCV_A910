# RISC-V bare-metal port configuration

# Toolchain
TOOLCHAIN_PREFIX = riscv64-unknown-elf-
CC = $(TOOLCHAIN_PREFIX)gcc
LD = $(TOOLCHAIN_PREFIX)gcc
OBJCOPY = $(TOOLCHAIN_PREFIX)objcopy
OBJDUMP = $(TOOLCHAIN_PREFIX)objdump

# Compiler flags
PORT_CFLAGS = -march=rv32i -mabi=ilp32 -O2 -g -nostdlib -nostartfiles -fno-builtin
FLAGS_STR = "$(PORT_CFLAGS) $(XCFLAGS)"
CFLAGS = $(PORT_CFLAGS) -I$(PORT_DIR) -I. -DFLAGS_STR=\"$(FLAGS_STR)\"

# Linker flags
LFLAGS = -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles
LFLAGS_END = -T $(PORT_DIR)/link.ld -lgcc

# Port specific sources
PORT_SRCS = $(PORT_DIR)/core_portme.c $(PORT_DIR)/ee_printf.c

# Startup assembly
PORT_ASM = $(PORT_DIR)/start.S
PORT_OBJS = core_portme$(OEXT) ee_printf$(OEXT) start$(OEXT)

# Build mode
SEPARATE_COMPILE = 1
OBJOUT = -o
OFLAG = -o
COUT = -c
LOUTCMD = $(OFLAG) $(OUTFILE) $(LFLAGS_END)
OUTFLAG = $(OFLAG)

OEXT = .o
EXE = .elf

# Load/Run placeholders
LOAD = echo "Built for bare-metal RISC-V"
RUN = echo "Please load to simulator/hardware"

# Compilation rules
$(OPATH)$(PORT_DIR)/%$(OEXT) : %.c
	$(CC) $(CFLAGS) $(XCFLAGS) $(COUT) $< $(OBJOUT) $@

$(OPATH)%$(OEXT) : %.c
	$(CC) $(CFLAGS) $(XCFLAGS) $(COUT) $< $(OBJOUT) $@

$(OPATH)$(PORT_DIR)/%$(OEXT) : %.S
	$(CC) $(CFLAGS) $(XCFLAGS) $(COUT) $< $(OBJOUT) $@

# Port build hooks
.PHONY : port_prebuild port_postbuild port_prerun port_postrun port_preload port_postload

port_prebuild:
	@echo "=== Building CoreMark for RISC-V RV32I ==="
	@mkdir -p $(OPATH)$(PORT_DIR)

port_postbuild:
	@echo "=== Creating binary and dump files ==="
	$(OBJCOPY) -O binary $(OUTFILE) $(OPATH)coremark.bin
	$(OBJDUMP) -D $(OUTFILE) > $(OPATH)coremark.dump
	@echo "=== Build complete ==="
	@ls -lh $(OPATH)coremark.bin $(OPATH)coremark.elf

port_prerun port_postrun port_preload port_postload:
	@true

# Output path
OPATH = ./build/
MKDIR = mkdir -p
