# 测试运行指南

## 前提条件

**重要**：在运行测试前，必须先修复DUT的bug！

在 `mySoC/mycpu.v` 第385行，修改：
```verilog
// 原来：
assign debug_wb_ena = wb_rf_we;

// 改为：
assign debug_wb_ena = wb_rf_we && (wb_wR != 5'b0);
```

然后重新编译：
```bash
rm obj_vcs/simv
make build
```

## 运行测试

### 1. 乘法指令测试
```bash
make run TEST=mul MAX_CYCLES=1000
```

**预期结果**：
- 如果修复了bug：显示 "Test Point Pass!" 并正常退出
- 如果未修复：显示 difftest error 并停止

### 2. 除法指令测试
```bash
make run TEST=div MAX_CYCLES=50000
```

**说明**：除法需要更多周期（每个DIV指令33周期）

### 3. CoreMark基准测试
```bash
make run TEST=coremark MAX_CYCLES=100000000
```

**说明**：
- CoreMark是一个综合性能测试
- 需要很多周期（1亿周期）
- 测试时间较长（可能几分钟到几十分钟）

### 4. 运行所有测试
```bash
make run-all MAX_CYCLES=50000
```

## 查看波形

如果需要调试，可以生成波形：

```bash
# 运行测试并保存波形
make run TEST=mul MAX_CYCLES=1000 WAVE=mul_debug

# 用Verdi查看波形（需要Verdi环境）
make verdi WAVE=mul_debug FMT=fsdb
```

## 输出说明

### 成功输出示例：
```
[mycpu] Reset done.
[difftest] Golden model running, difftest will start after pipeline fill...
[difftest] Test Start!
ECALL at PC = 0x00000028, Stop now.
Test Point Pass!
```

### 失败输出示例：
```
[difftest] Test Start!
=========== Diffrence ===========
SIGNAL NAME	REFERENCE	MYCPU
debug_wb_pc	0x00000000	0x00000000
debug_wb_ena	         0	         1
[difftest] ERROR: Mismatch detected at cycle 23
```

## 常见问题

### Q: 显示 "command not found: vcs"
A: VCS环境变量未设置，但只要 `obj_vcs/simv` 存在就可以直接运行测试

### Q: 所有测试都在第一条指令失败
A: 你还没有修复DUT的bug，见上面"前提条件"

### Q: CoreMark运行很慢
A: 正常现象，CoreMark是完整程序，需要执行很长时间

### Q: 想快速验证是否修复
A: 先运行简单的mul测试，只需1-2秒

## 测试文件位置

- 测试二进制：`bin/*.bin`
- 测试源码：`asm/*.S`
- 波形文件：`waveform/*.fsdb` 或 `waveform/*.vcd`
- 日志文件：`obj_vcs/sim.log`
