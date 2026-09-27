# RV32M 扩展实现文档

## 概述

成功为miniRV CPU添加了RISC-V RV32M标准扩展（乘法和除法指令），包括8条新指令：
- 4条乘法指令：MUL, MULH, MULHSU, MULHU
- 4条除法指令：DIV, DIVU, REM, REMU

## 实现架构

> **2026-09-27 重构**：本节原先写的"3 级流水、吞吐 1 条/周期、延迟 33 周期"与 RTL
> 不符（实测：MUL 延迟 3 拍、**背靠背间隔 4 拍**、DIV 恒 34 拍）。整个单元已按
> `doc/muldiv_pipeline_zh.md` 重写成**两条独立真流水 + 带 tag 的请求/写回接口**，
> 下面是与 RTL 一致的数字。

### 1. 乘法器 `mySoC/mul_pipe.v` —— 真流水, II=1

- **设计**：radix-4 Booth 编码（17 组）+ 进位保留压缩树（6 级 3:2 CSA）
- **切分**：M1 = 预扩展 + 编码 + 部分积 + **树的前 4 级**；M2 = 树的后 2 级 +
  (MAC 预留 CSA) + 64 位 CPA + 结果选择
- **延迟**：2 拍（请求拍 T 打 M1、T+1 打 M2、T+2 响应有效）
- **吞吐量**：**1 条/拍**（每拍都能收一条，写回脉冲间隔 1 拍）
- **四种 MUL 共用一条通路**：操作数按符号性预扩展到 33 位（MUL/MULH 两者有符号、
  MULHSU 的 src1 补 0、MULHU 两者补 0），于是 33×33 有符号乘法的低 64 位对四种
  指令都成立，op 只影响扩展位和最后取高/低 32 位。
- **不阻塞发射**：结果 2 拍后从自己的写回口出来；核在 WB 级用随流水下传的
  `is_mul` 标志把它换进写回数据（`mycpu.v` 的 `wb_wD_eff`）。消费者由
  `Hazard_Detection` 的 `mul_stall` 顶住（距离 0 停 2 拍，更远不停）。

### 2. 除法器 `mySoC/div_pipe.v` —— radix-4 SRT, 提前结束

- **设计**：对齐式 radix-4 恢复余数（每拍 2 位），与 C906 `aq_iu_div_shift2_kernel`
  同路线：用 r−d / r−2d / r−3d 三个减法器的借位当比较，选 0~3 的商位
- **延迟**：**数据相关**, `n+4` 拍，其中 `n = (pos_a - pos_d)/2 + 1` 最多 16
  （全量程 20 拍、常见小操作数 4~8 拍）
- **吞吐量**：不做流水（doc §5.5）—— 单条占住 EX 等结果，用 `div_stall` 反压
- **不阻塞别人**：乘法是另一条流水，除法迭代期间乘法照常发射/写回

### 3. 顶层接口 `mySoC/MUL_DIV.v`（OoO-ready）

带 tag 的请求/写回口：`req_valid/req_op/req_src0/1/req_tag/req_src2/req_acc_mode`
进，`mul_ready/div_busy/resp_valid/resp_data/resp_tag/resp_is_div` 出，
`wb_grant/flush_valid/flush_tag` 控制。顺序核里 `req_tag` 接 rd 序号、
`wb_grant` 接 1、MAC 口接 0；换乱序核时只改这些接线, **单元本身不用动**。

### 4. 实测（CoreMark, IFU=1 默认配置）

| 计数 | 重构前 | 重构后 |
|---|---|---|
| `muldiv_stall` / `div_stall` | 850,150 拍 (6.15%) | 见 `make run-all` 报表的 `div` 一列 |
| 乘法背靠背间隔 | 4 拍 | 1 拍 |
| 除法延迟 | 恒 34 拍 | 4~20 拍 |
| 单元面积（nangate45, 1.0ns 目标） | 15,066 cells / 19,295 µm² | 9,140 cells / 12,887 µm² |
| 单元 Fmax | ~620 MHz（乘法在端口→寄存器的一拍里） | **917 MHz**（M1: 801 ps 逻辑） |

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

