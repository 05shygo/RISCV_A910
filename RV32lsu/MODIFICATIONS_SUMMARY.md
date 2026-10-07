# DCache 可配置容量实现总结

## 完成的修改

### 1. 参数化系统建立
- **DCACHE_SIZE参数**: 支持1024、2048、4096字节三种容量配置
- **派生参数**: 所有模块统一使用以下localparam计算方式:
  ```systemverilog
  localparam int CACHELINE_SIZE = 32;
  localparam int NUM_WAYS = 2;
  localparam int OFFSET_WIDTH = 5;
  localparam int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS;
  localparam int INDEX_WIDTH = $clog2(NUM_SETS);  // 4/5/6 for 1KB/2KB/4KB
  localparam int INDEX_LSB = OFFSET_WIDTH;
  localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;
  localparam int TAG_LSB = INDEX_MSB + 1;
  localparam int TAG_WIDTH = 32 - TAG_LSB;
  localparam int LD_TAG_WIDTH = TAG_WIDTH * 2 + 2;
  ```

### 2. 修改的模块列表

#### DCache核心模块
1. **ct_lsu_dcache_top.sv** - 添加DCACHE_SIZE参数，参数化所有接口
2. **ct_lsu_dcache_tag_array.sv** - 参数化tag数组索引
3. **ct_lsu_dcache_ld_tag_array.sv** - 参数化load tag数组索引
4. **ct_lsu_dcache_dirty_array.sv** - 参数化dirty数组索引
5. **ct_lsu_dcache_data_array.sv** - 参数化data数组索引

#### DCache仲裁器
6. **ct_lsu_dcache_arb.sv** - 完全重写，简化为4个请求源
   - **删除**: SNQ/ICC/MCIC模块接口
   - **删除**: Serial request功能（连续两周期请求）
   - **保留**: AG/WMB/LFB/VB请求源
   - **优先级**: Load (LFB>VB>WMB>AG), Store (LFB>VB>AG)
   - 原1357行简化为~450行

#### LSU访问模块
7. **lsu_ld_ag.sv** - 参数化load地址生成阶段的dcache索引
8. **lsu_st_ag.sv** - 参数化store地址生成阶段的dcache索引
9. **lsu_ld_dc.sv** - 参数化load数据缓存阶段的索引比较
10. **lsu_wmb.sv** - 参数化写合并缓冲的dcache索引
11. **lsu_wmb_entry.sv** - 参数化WMB entry的地址比较
12. **lsu_lfb.sv** - 参数化linefill buffer的索引和tag
13. **lsu_lfb_addr_entry.sv** - 参数化LFB地址entry的索引比较
14. **lsu_vb.sv** - 参数化victim buffer的索引

### 3. 索引映射关系

| 容量 | INDEX_WIDTH | Tag索引位 | Data索引位 | Tag位 |
|------|-------------|-----------|------------|-------|
| 1KB  | 4           | pa[8:5]   | pa[8:4]    | pa[31:9] |
| 2KB  | 5           | pa[9:5]   | pa[9:4]    | pa[31:10] |
| 4KB  | 6           | pa[10:5]  | pa[10:4]   | pa[31:11] |

### 4. 保持不变的特性
- 2-way set-associative结构
- 32字节cacheline大小
- High/low bank访问结构（bank0-3用low_idx，bank4-7用high_idx）
- Store属性简化（仅保留fifo/dirty/valid）
- 32位物理地址空间

### 5. 备份文件
- **ct_lsu_dcache_arb_old.sv** - 原始仲裁器备份
- **lsu_wmb_old.sv** - 原始WMB备份
- **lsu_wmb_entry_old.sv** - 原始WMB entry备份
- **lsu_wmb_ce_old.sv** - 原始WMB CE备份

## 验证要点

### 编译验证
1. 使用DCACHE_SIZE=1024编译，检查INDEX_WIDTH=4的正确性
2. 使用DCACHE_SIZE=2048编译，检查INDEX_WIDTH=5的正确性
3. 使用DCACHE_SIZE=4096编译，检查INDEX_WIDTH=6的正确性
4. 检查所有模块间接口位宽是否匹配

### 功能验证（如果有testbench）
1. Load/Store基本操作
2. Cache hit/miss路径
3. WMB写回流程
4. LFB refill流程
5. VB替换流程
6. 地址别名处理

## 使用方法

在顶层模块实例化时设置DCACHE_SIZE参数:

```systemverilog
ct_lsu_dcache_top #(
  .DCACHE_SIZE(2048)  // 1024, 2048, or 4096
) u_dcache_top (
  // ports...
);
```

## 注意事项

1. 所有访问dcache的模块必须添加DCACHE_SIZE参数并传递
2. 不要使用硬编码的地址位（如[11:5]），必须使用参数表达式（如[INDEX_MSB:INDEX_LSB]）
3. Data数组索引需要包含way位：INDEX_WIDTH+1
4. Load tag数组包含valid位：TAG_WIDTH*2+2
5. VB的5位dirty数组需要扩展为7位以匹配dcache接口

## 完成日期
2026-10-01
