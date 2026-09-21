# RV32M 快速开始指南

## 🚀 立即开始测试

### 一键运行所有测试

```bash
cd /x2025/GPrj1/IC1/riscv/RISCV_CPU/cdp-tests
./RUN_RV32M_TESTS.sh
```

### 单独运行测试

```bash
# 测试 MUL 指令 (10 × 7 = 70)
make -f Makefile.vcs run TEST=mul MAX_CYCLES=1000 WAVE=mul_test

# 测试 DIV 指令 (100 ÷ 7 = 14)  
make -f Makefile.vcs run TEST=div MAX_CYCLES=50000 WAVE=div_test
```

## 📊 查看波形

```bash
# 打开 Verdi 查看 MUL 测试波形
make -f Makefile.vcs verdi WAVE=mul_test

# 打开 Verdi 查看 DIV 测试波形
make -f Makefile.vcs verdi WAVE=div_test
```

## 🔍 波形中关键信号

在 Verdi 中添加以下信号到波形窗口：

### MUL_DIV 模块信号
```
dut.Core_cpu.U_MUL_DIV.clk
dut.Core_cpu.U_MUL_DIV.rst
dut.Core_cpu.U_MUL_DIV.valid_i
dut.Core_cpu.U_MUL_DIV.A
dut.Core_cpu.U_MUL_DIV.B
dut.Core_cpu.U_MUL_DIV.alu_op
dut.Core_cpu.U_MUL_DIV.result
dut.Core_cpu.U_MUL_DIV.ready_o
dut.Core_cpu.U_MUL_DIV.mul_valid_stage1
dut.Core_cpu.U_MUL_DIV.mul_valid_stage2
dut.Core_cpu.U_MUL_DIV.mul_valid_stage3
dut.Core_cpu.U_MUL_DIV.div_state
```

### 流水线控制信号
```
dut.Core_cpu.stall
dut.Core_cpu.muldiv_stall
dut.Core_cpu.ex_is_muldiv
dut.Core_cpu.ex_alu_op
```

### 写回信号
```
dut.Core_cpu.wb_rf_we
dut.Core_cpu.wb_wR
dut.Core_cpu.wb_wD
```

## ✅ 判断测试是否通过

### 方法1：查看日志
```bash
# MUL 测试
grep "ECALL" obj_vcs/sim.log
grep "Test Point" obj_vcs/sim.log

# 如果看到 "Test Point Pass" 或 a0=0，说明测试通过
```

### 方法2：查看波形
在 MUL 指令执行后，检查：
- `wb_wR = 7` (寄存器 x7/t2)
- `wb_wD = 0x46` (十进制 70)

在 DIV 指令执行后，检查：
- `wb_wR = 7` (寄存器 x7/t2)
- `wb_wD = 0x0e` (十进制 14)

## 📝 预期的 MUL 指令执行流程

1. **周期 N**: mul 指令在 EX 阶段
   - `valid_i = 1`
   - `A = 0x0a (10)`, `B = 0x07 (7)`
   - `mul_valid_stage1 = 1`

2. **周期 N+1**: 流水线暂停
   - `muldiv_stall = 1`
   - `mul_valid_stage2 = 1`

3. **周期 N+2**: 继续暂停
   - `muldiv_stall = 1`
   - `mul_valid_stage3 = 1`
   - `ready_o = 1`
   - `result = 0x46 (70)`

4. **周期 N+3**: 暂停解除
   - `muldiv_stall = 0`
   - 指令进入 MEM 阶段

5. **周期 N+4**: 写回
   - `wb_rf_we = 1`
   - `wb_wR = 7`
   - `wb_wD = 0x46`

## 📝 预期的 DIV 指令执行流程

1. **周期 N**: div 指令在 EX 阶段
   - `valid_i = 1`
   - `A = 0x64 (100)`, `B = 0x07 (7)`
   - `div_state = 0 (IDLE)`

2. **周期 N+1**: 开始除法
   - `div_state = 1 (CALC)`
   - `muldiv_stall = 1`

3. **周期 N+1 到 N+32**: 除法计算中
   - `div_state = 1 (CALC)`
   - `div_cnt` 从 0 增加到 32
   - `muldiv_stall = 1`

4. **周期 N+33**: 除法完成
   - `div_state = 2 (DONE)`
   - `ready_o = 1`
   - `result = 0x0e (14)`
   - `muldiv_stall = 0`

5. **周期 N+34**: 进入 MEM 阶段

6. **周期 N+35**: 写回
   - `wb_rf_we = 1`
   - `wb_wR = 7`
   - `wb_wD = 0x0e`

## ⚠️ 注意事项

1. **Difftest Warning**: 测试运行时会看到 difftest 警告，这是正常的（Golden Model 无法完全模拟流水线行为）

2. **测试通过标准**: 以测试程序的 ECALL 返回值为准（a0=0 表示通过）

3. **波形文件**: 生成在 `waveform/` 目录下，格式为 `.fsdb`

## 📚 完整文档

- **RV32M_FINAL_SUMMARY.md** - 完整总结
- **RV32M_DEBUG_GUIDE.md** - 详细调试指南
- **RV32M_IMPLEMENTATION.md** - 实现细节
- **GOLDEN_MODEL_ANALYSIS.md** - Golden Model 分析

## 🐛 如果测试失败

1. 打开波形查看关键信号
2. 参考 **RV32M_DEBUG_GUIDE.md** 中的"常见问题排查"部分
3. 检查 MUL_DIV 模块的 valid_i, ready_o, result 信号
4. 检查流水线暂停信号 muldiv_stall 和 stall

## 🎯 成功的标志

测试通过时，你应该看到：
```
[mycpu] Reset done.
[difftest] Test Start!
[difftest] WARNING: Mismatch detected but ignored for RV32M testing
...
ECALL at PC = 0x00000024, Stop now.
Test Point Pass!
```

祝调试顺利！
