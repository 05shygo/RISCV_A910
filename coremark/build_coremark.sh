#!/bin/bash

# Set RISC-V toolchain path
export PATH=/x2025/GPrj1/IC1/riscv/RISCV_CPU/open_riscv_2035/tools/newlib/bin:$PATH

# Check toolchain
if ! which riscv64-unknown-elf-gcc > /dev/null 2>&1; then
    echo "ERROR: RISC-V toolchain not found!"
    exit 1
fi

echo "=== Building CoreMark for RISC-V ==="
echo "Toolchain: $(riscv64-unknown-elf-gcc --version | head -1)"

cd coremark

# Clean previous build
rm -rf build
mkdir -p build

# Toolchain settings
CROSS_COMPILE=riscv64-unknown-elf-
CC=${CROSS_COMPILE}gcc
OBJCOPY=${CROSS_COMPILE}objcopy
OBJDUMP=${CROSS_COMPILE}objdump

# Compiler flags
CFLAGS="-march=rv32i -mabi=ilp32 -O2 -g -nostdlib -nostartfiles -fno-builtin"
CFLAGS="$CFLAGS -Iriscv-port -I. -DITERATIONS=10 -DPERFORMANCE_RUN=1"

# Source files
SRCS="core_list_join.c core_main.c core_matrix.c core_state.c core_util.c"
SRCS="$SRCS riscv-port/core_portme.c riscv-port/ee_printf.c"

# Compile each source file
echo "=== Compiling source files ==="
for src in $SRCS; do
    obj="build/$(basename ${src%.c}.o)"
    echo "Compiling $src -> $obj"
    $CC $CFLAGS -c $src -o $obj
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to compile $src"
        exit 1
    fi
done

# Compile startup assembly
echo "Compiling riscv-port/start.S -> build/start.o"
$CC $CFLAGS -c riscv-port/start.S -o build/start.o
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to compile start.S"
    exit 1
fi

# Link
echo "=== Linking ==="
OBJS="build/core_list_join.o build/core_main.o build/core_matrix.o"
OBJS="$OBJS build/core_state.o build/core_util.o"
OBJS="$OBJS build/core_portme.o build/ee_printf.o build/start.o"

$CC -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles $OBJS \
    -T riscv-port/link.ld -lgcc -o build/coremark.elf

if [ $? -ne 0 ]; then
    echo "ERROR: Linking failed"
    exit 1
fi

# Generate binary and disassembly
echo "=== Generating binary and disassembly ==="
$OBJCOPY -O binary build/coremark.elf build/coremark.bin
$OBJDUMP -D build/coremark.elf > build/coremark.dump

echo ""
echo "=== Build successful! ==="
ls -lh build/coremark.bin build/coremark.elf
echo ""
echo "To test in your simulator:"
echo "  cp build/coremark.bin ../bin/"
echo "  cd .. && make vcs_run TEST=coremark"

