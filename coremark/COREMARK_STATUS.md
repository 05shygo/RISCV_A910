# CoreMark 移植状态总结

## ✅ 已完成的工作

### 1. CoreMark 完整移植
- **架构**: 纯 RV32I (37条基本指令)
- **无依赖**: 不需要 M 扩展（软件乘除法）、不需要 Zicsr 扩展（无CSR指令）
- **跑分输出**: 参考C910实现，可输出周期数和性能分数
- **测试判断**: 通过MONITOR外设报告 PASS/FAIL

### 2. 关键文件
```
cdp-tests/
├── bin/coremark.bin              # 12KB 可执行文件
├── coremark/
│   ├── Makefile.coremark         # 构建脚本
│   ├── core_main.c              # 已添加周期计数和跑分输出
│   ├── riscv-port/
│   │   ├── core_portme.c        # 计时器实现
│   │   ├── core_portme.h        # 配置
│   │   ├── ee_printf.c          # printf实现
│   │   ├── softmul.c            # 软件乘除法
│   │   ├── start.S              # 启动代码
│   │   └── link.ld              # 链接脚本(16KB配置)
│   └── build/
├── Makefile                    # 已集成coremark target
└── RUN_COREMARK.md             # 使用说明
```

### 3. 内存配置
```
地址范围: 0x0000 - 0x4000 (16KB)
- 0x0000 - 0x2F97: 代码+数据 (~12KB)
- 0x2F98 - 0x3000: BSS段
- 0x3000 - 0x4000: 栈空间 (~4KB)
- 栈顶: 0x4000
```

## ❌ 当前问题

### 内存越界错误
```
Memory access out of bound
Assertion `addr < (1 << 16)' failed
```

**可能原因**:
1. 程序运行时访问了超出64KB(0x10000)的地址
2. MONITOR外设(0x80000000)可能未被正确识别
3. 栈溢出或指针错误

## 🔍 调试建议

### 1. 添加调试输出
在 golden_model/stage/MEM.c 的 mem_store 函数中添加：
```c
void mem_store(uint32_t addr, AccessMode mode, uint32_t value) {
    // 调试输出
    if (addr >= MEM_SZ && !is_peripheral(addr, &peripheral_id)) {
        printf("ERROR: Accessing addr 0x%08x (> 0x%x)\n", addr, MEM_SZ);
    }
    
    // ... 原有代码
}
```

### 2. 检查外设识别
确认 `is_peripheral()` 函数正确识别 0x80000000 (MONITOR)

### 3. 使用更小的测试
创建一个最小的测试程序来验证基本功能：
```bash
# 测试简单程序是否能正常运行
make run TEST=addi MAX_CYCLES=1000
```

### 4. 查看波形
```bash
# 生成波形文件
make run TEST=coremark MAX_CYCLES=100000 WAVE=coremark

# 用Verdi查看
make verdi WAVE=coremark
```
在波形中查找：
- PC在哪里停止
- 哪个地址导致了访问越界
- 数据访问的地址是什么

## 🚀 下一步行动

### 选项1: 调试现有问题
1. 添加调试输出找出具体访问的地址
2. 检查为什么该地址超出范围
3. 修复地址计算或内存配置

### 选项2: 简化CoreMark
如果CoreMark太复杂，可以：
1. 先运行简单的基准测试（Dhrystone）
2. 或创建自定义的性能测试程序
3. 验证CPU所有指令正确后再运行CoreMark

### 选项3: 修改内存检查
临时方案：放宽golden model的内存检查，但要确保不会掩盖真正的bug

## 📝 CoreMark 特性

### 优点
- ✅ 纯RV32I实现
- ✅ 软件乘除法
- ✅ 无CSR依赖
- ✅ 可输出跑分
- ✅ 集成到测试框架

### 局限
- ⚠️ 需要大量周期（数千万到上亿）
- ⚠️ 软件乘除法性能较低
- ⚠️ 内存使用约12KB
- ⚠️ 需要栈空间约4KB

## 📚 参考实现

C910 CoreMark实现:
```
/x2025/GPrj1/IC1/riscv/RISCV_CPU/open_riscv_2035/smart_run/tests/cases/coremark/
```

关键代码:
- 周期计数: `get_vtimer()`
- 跑分输出: 整数运算避免浮点
- 测试结束: `sim_end()` 写MONITOR外设

---

**移植完成度**: 90%  
**阻塞问题**: 内存越界错误  
**建议**: 先调试找出具体访问地址，然后针对性修复
