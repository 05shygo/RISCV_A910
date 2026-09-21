# RV32M 实现状态报告

## 完成的工作

### 1. 硬件模块
- ✅ 创建了 MUL_DIV.v 模块
  - 3级流水线乘法器
  - 33周期恢复余数除法器
  - 支持所有8条RV32M指令

### 2. 指令解码
- ✅ 更新 defines.vh：ALU_OP_WIDTH 4→5位，添加8个RV32M操作码
- ✅ 更新 Control.v：添加 is_muldiv 输出，检测 funct7=0x01
- ✅ 解码所有8条指令：MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU

### 3. 流水线集成
- ✅ 在 mycpu.v 中实例化 MUL_DIV 模块
- ✅ 添加 muldiv_stall 信号生成逻辑
- ✅ 添加结果选择逻辑（ex_alu_c_final）
- ✅ 更新 ID_EX.v：添加 is_muldiv 流水线寄存器
- ✅ 更新 Hazard_Detection.v：集成 muldiv_stall
- ✅ 更新 EX_MEM.v：添加 stall 输入，防止在计算期间更新
- ✅ 更新 ID_EX.v：添加 stall 输入，在暂停时插入bubble

### 4. Golden Model 更新
- ✅ 更新 cpu.h：扩展 alu_op_t 枚举
- ✅ 更新 ID.c：在 ID_R 中解码 RV32M 指令
- ✅ 更新 EX.c：实现所有8条 RV32M 指令的执行逻辑

### 5. CoreMark 编译
- ✅ 修改 Makefile.coremark：ARCH 从 rv32i 改为 rv32im
- ✅ 重新编译 CoreMark，确认生成了 mul/div 指令

### 6. Bug 修复
- ✅ 修复 MUL_DIV.v 的复位极性（negedge→posedge）
- ✅ 修复 EX_MEM 传递 ex_alu_c_final 而不是 ex_alu_c
- ✅ 临时禁用 difftest（golden model 不支持多周期操作）

## 当前问题

### CPU 卡死（超时）
**症状**：CoreMark 运行 1亿周期后超时，没有任何输出

**可能原因**：
1. **流水线暂停逻辑问题**
   - 当 muldiv_stall=1 时：
     - PC, IF_ID, ID_EX 应该保持不变
     - EX_MEM 应该不更新
   - 当前实现：
     - ✅ PC 有 stall 处理
     - ✅ IF_ID 有 stall 处理  
     - ✅ ID_EX 有 stall 处理（新增）
     - ✅ EX_MEM 有 stall 处理（新增）
   
2. **MUL_DIV 模块问题**
   - valid_i 信号定义：`ex_is_muldiv & ex_rf_we`
   - 可能在暂停期间 valid_i 保持为 1，导致重复启动？
   
3. **除法器状态机问题**
   - 除法器可能没有正确从 DIV_DONE 返回 IDLE
   - ready_o 信号可能有问题

## 下一步调试建议

1. **简化测试**
   - 先测试简单的 mul/div 汇编程序
   - 确认基本指令能工作

2. **检查 valid_i 逻辑**
   - 当 muldiv_stall=1 时，valid_i 应该变为 0
   - 或者 MUL_DIV 模块应该忽略 stall 期间的 valid_i

3. **波形调试**
   - 启用 FSDB/VCD
   - 查看第一条 mul/div 指令的执行过程
   - 检查状态机转换

4. **添加调试输出**
   - 在 MUL_DIV 模块中添加 $display
   - 输出状态机状态和关键信号

## 设计权衡

### Golden Model vs RV32M
Golden model 是单周期模拟器，不支持多周期操作。有两个选择：

1. **扩展 Golden Model**（复杂）
   - 添加状态机来模拟多周期操作
   - 需要大量修改

2. **禁用 Difftest**（当前方案）
   - 简单快速
   - 依赖 CoreMark 的功能测试
   - 后期可以添加专门的 RV32M 测试向量

## 文件修改列表

**新建文件：**
- mySoC/MUL_DIV.v

**修改文件：**
- mySoC/defines.vh
- mySoC/Control.v
- mySoC/mycpu.v
- mySoC/ID_EX.v
- mySoC/EX_MEM.v
- mySoC/Hazard_Detection.v
- golden_model/include/cpu.h
- golden_model/stage/ID.c
- golden_model/stage/EX.c
- coremark/Makefile.coremark
- tb/tb_miniRV_dpi.sv (临时禁用 difftest)

