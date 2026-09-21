# RV32M 扩展实现文档

## 概述

成功为miniRV CPU添加了RISC-V RV32M标准扩展（乘法和除法指令），包括8条新指令：
- 4条乘法指令：MUL, MULH, MULHSU, MULHU
- 4条除法指令：DIV, DIVU, REM, REMU

## 实现架构

### 1. 硬件乘法器（3级流水线）
- **设计**：完全流水线乘法器
- **延迟**：3个周期
- **吞吐量**：1条指令/周期
- **实现**：使用Verilog的`*`运算符，综合工具会映射到FPGA的DSP模块

### 2. 硬件除法器（恢复余数算法）
- **设计**：逐位恢复余数除法
- **延迟**：33个周期（1个启动 + 32个计算）
- **吞吐量**：1条指令/33周期
- **实现**：状态机控制，面积最小

## 修改的文件列表

### 新建文件
1. **mySoC/MUL_DIV.v** - 乘除法单元核心模块

### 修改文件
2. **mySoC/defines.vh**
   - ALU_OP_WIDTH: 4→5位
   - 添加8个乘除法ALU操作码
   - 添加RV32M的funct3和funct7定义

3. **mySoC/Control.v**
   - 添加is_muldiv输出信号
   - 在R型指令中检测funct7=0x01
   - 解码8条乘除法指令

4. **mySoC/mycpu.v**
   - 实例化MUL_DIV模块
   - 添加乘除法结果选择逻辑
   - 集成muldiv_stall信号

5. **mySoC/ID_EX.v**
   - 添加is_muldiv流水线寄存器
   - 在ID/EX级传递乘除法标志

6. **mySoC/Hazard_Detection.v**
   - 添加muldiv_stall输入
   - 在流水线暂停逻辑中考虑乘除法

## 指令编码

| 指令 | 格式 | funct7 | funct3 | opcode | 说明 |
|------|------|--------|--------|--------|------|
| MUL rd, rs1, rs2 | R | 0000001 | 000 | 0110011 | rd ← (rs1 × rs2)[31:0] |
| MULH rd, rs1, rs2 | R | 0000001 | 001 | 0110011 | rd ← (rs1 × rs2)[63:32] 有符号 |
| MULHSU rd, rs1, rs2 | R | 0000001 | 010 | 0110011 | rd ← (rs1 × rs2)[63:32] rs1有符号 |
| MULHU rd, rs1, rs2 | R | 0000001 | 011 | 0110011 | rd ← (rs1 × rs2)[63:32] 无符号 |
| DIV rd, rs1, rs2 | R | 0000001 | 100 | 0110011 | rd ← rs1 ÷ rs2 有符号商 |
| DIVU rd, rs1, rs2 | R | 0000001 | 101 | 0110011 | rd ← rs1 ÷ rs2 无符号商 |
| REM rd, rs1, rs2 | R | 0000001 | 110 | 0110011 | rd ← rs1 % rs2 有符号余数 |
| REMU rd, rs1, rs2 | R | 0000001 | 111 | 0110011 | rd ← rs1 % rs2 无符号余数 |

## 性能分析

### 软件 vs 硬件对比

| 操作 | 软件周期数 | 硬件周期数 | 加速比 |
|------|-----------|-----------|--------|
| 32位乘法 | ~40-50 | 3 | **~15倍** |
| 32位除法 | ~60-80 | 33 | **~2倍** |

### CoreMark预期提升
- CoreMark包含大量乘除运算
- 预计总体性能提升：**10-15倍**
- 之前10亿周期超时 → 预计7000万-1亿周期完成

## 流水线行为

### 乘法指令
```
Cycle: 1    2    3    4    5    6
MUL:   IF   ID   EX1  EX2  EX3  MEM  WB
ADD:             IF   ID   EX   MEM  WB  (正常流水)
```
- 乘法占用EX阶段3个周期
- 后续指令正常流水（如无数据冒险）

### 除法指令
```
Cycle: 1    2    3    ...  34   35
DIV:   IF   ID   EX(STALL 33 cycles)  MEM  WB
ADD:             (STALLED)              IF   ID
```
- 除法占用EX阶段33个周期
- 流水线暂停，后续指令等待

## 测试方法

### 1. 功能测试
创建简单的测试程序：
```c
int main() {
    int a = 100, b = 7;
    int mul_result = a * b;        // 使用MUL
    int div_result = a / b;        // 使用DIV
    int rem_result = a % b;        // 使用REM
    return 0;
}
```

### 2. CoreMark性能测试
```bash
# CoreMark会自动检测并使用硬件乘除法
cd coremark
make -f Makefile.coremark clean
make -f Makefile.coremark

# 运行测试（预计时间大幅缩短）
cd ..
make run TEST=coremark MAX_CYCLES=200000000
```

## 编译说明

GCC编译器会自动检测RV32M扩展：
- 使用 `-march=rv32im` 编译参数启用硬件乘除法
- CoreMark的Makefile.coremark已配置为rv32im

## 已知限制

1. **除法性能**：33周期的延迟相对较长，但比软件实现快2倍
2. **流水线暂停**：除法执行期间整个流水线暂停
3. **面积开销**：增加一个64位乘法器和除法状态机

## 可能的优化方向

1. **除法优化**：
   - 使用SRT-4算法（每周期2位）减少到17周期
   - 添加除法流水线（允许重叠执行）

2. **乘法优化**：
   - 减少到2级流水线（1周期延迟）
   - 使用部分积乘法器节省面积

3. **指令调度**：
   - 编译器优化以减少除法暂停的影响

## 验证清单

- [x] 添加MUL_DIV硬件模块
- [x] 修改Control模块解码
- [x] 集成到流水线CPU
- [x] 添加流水线暂停逻辑
- [x] 更新指令定义
- [ ] 功能仿真测试
- [ ] CoreMark性能验证
- [ ] FPGA综合与实现

## 参考资料

- RISC-V指令集手册 Volume I: User-Level ISA
- RISC-V标准扩展"M"（整数乘除法）
- 参考实现：/x2025/GPrj1/IC1/riscv/RISCV_CPU/cpu/src/

