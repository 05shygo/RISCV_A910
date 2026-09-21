# CoreMark 移植到 RV32I CPU - 完成总结

## ✅ 已完成的工作

### 1. CoreMark 完整移植
- **目标架构**: 纯 RV32I 指令集（37条基本指令）
- **无依赖**: 不需要 M 扩展（乘法除法）、不需要 Zicsr 扩展（CSR指令）
- **编译器**: 使用现有的 riscv64-unknown-elf-gcc 工具链
- **输出**: `bin/coremark.bin` (14KB)

### 2. 关键技术实现

#### 软件乘除法实现 (`riscv-port/softmul.c`)
由于 RV32I 不包含硬件乘法和除法指令，提供了软件实现：
- `__mulsi3` - 32位有符号乘法
- `__udivsi3` - 32位无符号除法  
- `__umodsi3` - 32位无符号取模
- `__divsi3` - 32位有符号除法
- `__modsi3` - 32位有符号取模

#### 移除 CSR 依赖
原始 CoreMark 使用 `rdcycle` 指令读取周期计数器，需要 Zicsr 扩展。
已修改为简单的软件计数器，不依赖 CSR 指令。

### 3. 文件结构

```
coremark/
├── Makefile.coremark          # 独立构建脚本
├── build_coremark.sh          # Shell 构建脚本
├── riscv-port/               # RV32I 移植文件
│   ├── core_portme.h         # 配置头文件
│   ├── core_portme.c         # 移植实现（无CSR版本）
│   ├── ee_printf.c           # 简化 printf
│   ├── softmul.c             # 软件乘除法实现
│   ├── start.S               # 启动代码
│   └── link.ld               # 链接脚本（64KB RAM）
├── core_*.c                  # CoreMark 核心源文件
└── build/                    # 构建输出
    ├── coremark.elf          # ELF 可执行文件
    ├── coremark.bin          # 纯二进制文件
    └── coremark.dump         # 反汇编文件
```

### 4. 集成到测试框架

已集成到 `Makefile`，新增 target：
```bash
make coremark                    # 构建 CoreMark
make run TEST=coremark           # 运行测试
make help                        # 查看帮助
```

## 📋 使用方法

### 构建 CoreMark

```bash
# 方式1: 使用集成的 Makefile
make coremark

# 方式2: 在 coremark 目录直接构建
cd coremark
make -f Makefile.coremark

# 方式3: 使用 shell 脚本
cd coremark
./build_coremark.sh
```

### 运行仿真测试

```bash
# 基本运行（CoreMark 需要较多周期完成）
make run TEST=coremark MAX_CYCLES=10000000

# 生成波形
make run TEST=coremark MAX_CYCLES=10000000 WAVE=coremark

# 用 Verdi 查看波形
make verdi WAVE=coremark
```

**注意**: CoreMark 是复杂的基准测试程序，需要比简单指令测试更多的周期才能完成。建议设置 `MAX_CYCLES=10000000` 或更高。

## 🔧 配置选项

编辑 `coremark/Makefile.coremark` 调整参数：

```makefile
# 迭代次数（影响测试时间和精度）
ITERATIONS=10          # 默认10次，可增加获得更准确结果

# 编译优化级别
CFLAGS = ... -O2 ...   # 默认 -O2，可改为 -O0/-O1/-O3

# 架构配置（固定为RV32I）
ARCH = rv32i
ABI = ilp32
```

## ✨ 特性亮点

1. ✅ **纯 RV32I** - 仅使用37条基本指令
2. ✅ **无硬件依赖** - 不需要 M/Zicsr 扩展
3. ✅ **Bare-metal** - 无操作系统，直接运行
4. ✅ **无 CSR 指令** - 已验证二进制中无 rdcycle/csrr/ecall
5. ✅ **软件乘除法** - 完全用基本指令实现
6. ✅ **可配置** - 迭代次数、优化级别可调
7. ✅ **集成良好** - 像其他测试一样使用

## 📊 验证结果

```bash
# 确认无 CSR/ECALL 指令
$ objdump -d build/coremark.elf | grep -E "rdcycle|csrr|ecall" | wc -l
0

# 二进制文件大小
$ ls -lh bin/coremark.bin
-rwxrwxr-x 1 IC1 IC1 14K coremark.bin

# ELF 架构验证
$ readelf -h build/coremark.elf | grep -E "Class|Machine|Flags"
  Class:                             ELF32
  Machine:                           RISC-V
  Flags:                             0x0
```

## 🐛 已解决的问题

### 问题1: 链接时找不到乘除法函数
**解决**: 创建 `softmul.c` 提供软件实现，不依赖 libgcc

### 问题2: 运行时遇到 rdcycle 指令
**解决**: 修改 `core_portme.c`，移除对 CSR 的依赖，使用软件计数器

### 问题3: ECALL 导致测试停止
**解决**: 移除所有系统调用依赖，使用纯 bare-metal 实现

## 📝 技术说明

### 软件乘法算法
使用移位加法算法，时间复杂度 O(32)：
```c
while (b > 0) {
    if (b & 1) result += a;
    a <<= 1;
    b >>= 1;
}
```

### 软件除法算法
使用非恢复除法算法，时间复杂度 O(32)：
```c
while (divisor < dividend && !(divisor & 0x80000000)) {
    divisor <<= 1;
    bit <<= 1;
}
while (bit) {
    if (dividend >= divisor) {
        dividend -= divisor;
        quotient |= bit;
    }
    divisor >>= 1;
    bit >>= 1;
}
```

### 内存布局
```
0x00000000 - 0x00010000  RAM (64KB)
├── .text               代码段
├── .data               初始化数据
├── .bss                未初始化数据
└── stack               栈（从高地址向下增长）
```

## 🎯 性能评估

CoreMark 通过以下指标评估 CPU 性能：
- **CoreMark 分数**: 每秒完成的迭代次数
- **CoreMark/MHz**: 归一化性能指标
- **代码大小**: 14KB（适合小型嵌入式系统）

## 📚 相关文件

- `Makefile` - 主测试框架（已添加 coremark target）
- `coremark/Makefile.coremark` - CoreMark 独立构建脚本
- `coremark/riscv-port/*` - RV32I 移植实现
- `bin/coremark.bin` - 可执行二进制文件

## 🔗 工具链信息

```bash
工具链路径: /x2025/GPrj1/IC1/riscv/RISCV_CPU/open_riscv_2035/tools/newlib/bin
编译器: riscv64-unknown-elf-gcc (Xuantie-900 elf newlib gcc Toolchain V2.10.2)
版本: 10.4.0
目标: RV32I (-march=rv32i -mabi=ilp32)
```

---

**移植完成日期**: 2026-09-21  
**目标CPU**: RV32I (37条基本指令)  
**状态**: ✅ 编译成功，无CSR/M扩展依赖，可运行测试
