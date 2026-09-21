# CoreMark 跑分测试指南

## ✅ CoreMark 已完成移植并集成

### 新增功能（参考C910实现）

1. **自动周期计数** - 通过软件计数器跟踪执行周期
2. **跑分输出** - 显示 CoreMark 得分 (iterations/sec)/MHz
3. **测试结果判断** - 通过MONITOR外设报告 PASS/FAIL
4. **纯整数运算** - 无浮点依赖，完全RV32I兼容

### 输出格式

测试完成后会输出：
```
========================================
CoreMark Performance Results
========================================
Total iterations: 1
Total cycles: XXXXX
Average cycles/iteration: XXXXX
CoreMark Score: X.XXX (iterations/sec)/MHz
========================================
```

### 运行命令

```bash
# 基本测试（迭代1次，需要较多周期）
make -f Makefile.vcs run TEST=coremark MAX_CYCLES=100000000

# 保存日志
make -f Makefile.vcs run TEST=coremark MAX_CYCLES=100000000 | tee coremark_result.log

# 查看结果
tail -100 obj_vcs/sim.log | grep -A 10 "CoreMark"
```

### 判断测试成功的方法

1. **查看MONITOR输出**
   - `0x0000BEEF` = 测试通过
   - `0x0000DEAD` = 测试失败

2. **查看仿真日志**
   ```bash
   grep "CoreMark" obj_vcs/sim.log
   grep "BEEF" obj_vcs/sim.log  # 查找成功标志
   ```

3. **检查是否完整运行**
   - 日志中应有 "CoreMark Performance Results"
   - 应有具体的周期数和跑分
   - 最后应有 0xBEEF 输出

### 文件说明

- `bin/coremark.bin` - CoreMark 可执行文件（14KB，迭代1次）
- `obj_vcs/sim.log` - 仿真日志（包含跑分结果）
- `coremark/core_main.c` - 已添加跑分输出代码
- `coremark/riscv-port/core_portme.c` - 周期计数实现

### 预期性能

RV32I（无M扩展）性能参考：
- 软件乘法：~32周期/次
- 软件除法：~32周期/次
- CoreMark包含大量乘除法运算
- 预计需要数千万到上亿周期完成

### 故障排查

1. **超时**
   - 增加 MAX_CYCLES 参数
   - 或减少迭代次数（已设为1）

2. **没有输出**
   - 检查ee_printf是否工作
   - 查看MONITOR外设是否配置正确

3. **跑分为0**
   - 可能是周期计数器未正确递增
   - 检查 timer_counter 变量

---

**CoreMark移植完成** ✅  
**参考**: C910 CoreMark实现  
**状态**: 可以输出跑分结果
