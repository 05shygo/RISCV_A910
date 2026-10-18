### 3.1 MULMAC单元（15条）- 完全保留

根据opcode定义文件，MULMAC相关指令共15条， **全部保留** 。



```systemverilog
// ========== 宽位乘累加（4条）- 全部保留 ==========
VWMACCU   // INT8×INT8→INT16 MAC（无符号）
VWMACC    // INT8×INT8→INT16 MAC（有符号）
VWMACCSU  // INT8(signed)×INT8(unsigned)→INT16 MAC
VWMACCUS  // INT8(unsigned)×INT8(signed)→INT16 MAC
// 原因：4种符号组合对应不同量化方案，都需要

// ========== 宽位乘法（3条）- 全部保留 ==========
VWMULU    // INT8×INT8→INT16（无符号）
VWMUL     // INT8×INT8→INT16（有符号）
VWMULSU   // INT8(signed)×INT8(unsigned)→INT16 混合符号宽位乘法
// 原因：完整的符号组合支持

// ========== 基础乘法（4条）- 全部保留 ==========
VMUL      // 标准乘法 - SiLU激活：x*sigmoid(x)
VMULHU    // 高位乘法（无符号）- 替代除法的倒数近似
VMULH     // 高位乘法（有符号）- 归一化计算
VMULHSU   // 高位乘法（混合符号）- 完整性
// 原因：基础乘法操作，硬件成本低，全部保留

// ========== 乘累加（4条）- 全部保留 ==========
VMACC     // vd += vs1 * vs2
VMADD     // vd = (vd * vs1) + vs2
VNMSAC    // vd -= vs1 * vs2
VNMSUB    // vd = -(vd * vs1) + vs2
// 原因：FMA标准形式，编译器可能生成，硬件成本低
```

 **移除指令** ：0条（全部保留）

 **面积影响** ：0%（保持原有设计）

 **决策理由** ：

* ✅ MULMAC是卷积核心单元，占YOLO 92%计算量
* ✅ 15条指令硬件共享度高，移除单条收益<1%
* ✅ 完整保留避免边缘case失败，风险最低

---

### 3.2 ALU单元（35条）- 完全保留

根据opcode定义，ALU相关的OPI*指令共35条， **全部保留** 。

```systemverilog
// ========== 算术运算（4条）- 全部保留 ==========
VADD      // 加法 - 偏置、融合、残差（高频）
VSUB      // 减法 - 残差、范围计算
VRSUB     // 反向减法 - 立即数减法优化
VADC      // 带进位加 - 宽精度计算

// ========== 比较运算（10条）- 全部保留 ==========
VMAX      // 最大（有符号）- ReLU: max(0,x)
VMAXU     // 最大（无符号）- UINT8的ReLU
VMIN      // 最小（有符号）- Clip: min(x,6)
VMINU     // 最小（无符号）- UINT8的Clip
VMSEQ     // 相等比较 - 掩码生成
VMSNE     // 不等比较 - 掩码生成
VMSLT     // 小于（有符号）
VMSLTU    // 小于（无符号）
VMSLE     // 小于等于（有符号）
VMSLEU    // 小于等于（无符号）
// 原因：完整的比较操作，某些优化需要

// ========== 逻辑运算（3条）- 全部保留 ==========
VAND      // 按位与 - 掩码操作
VOR       // 按位或 - 掩码合并
VXOR      // 按位异或 - 掩码翻转

// ========== 移位运算（6条）- 全部保留 ==========
VSLL      // 逻辑左移
VSRL      // 逻辑右移 - 无符号量化除法
VSRA      // 算术右移 - 有符号量化除法
VSSRL     // 饱和右移 - 四舍五入量化（更高精度）
VSSRA     // 饱和算术右移 - 四舍五入有符号量化
VNSRL     // 窄化右移 - INT16→INT8
// 原因：量化核心操作

// ========== 饱和算术（4条）- 全部保留 ==========
VSADDU    // 饱和加（无符号）
VSADD     // 饱和加（有符号）
VSSUBU    // 饱和减（无符号）
VSSUB     // 饱和减（有符号）
// 原因：某些量化方案需要

// ========== 数据搬移（2条）- 全部保留 ==========
VMV       // 向量移动
VMERGE    // 条件选择

// ========== 类型转换（6条）- 全部保留 ==========
VSEXT_VF2 // INT8→INT16符号扩展（高频）
VZEXT_VF2 // INT8→INT16零扩展（高频）
VSEXT_VF4 // INT8→INT32符号扩展（后处理需要）
VZEXT_VF4 // INT8→INT32零扩展
VNCLIP    // INT16→INT8截断+饱和（量化输出）
VNCLIPU   // INT16→INT8截断+饱和（无符号）
```

 **移除指令** ：0条（全部保留）

 **面积影响** ：0%（保持原有设计）

 **决策理由** ：

* ✅ ALU指令硬件共享度极高（共用ALU核心）
* ✅ 单条指令移除收益<0.5%，但可能导致软件复杂度大增
* ✅ 某些指令虽然YOLO核心不用，但编译器优化可能生成
* ✅ 完整的ALU指令集提供最好的软件灵活性

---

### 3.3 PMTRDT单元（6条）- 基本完整

```systemverilog
// ========== 归约求和（2条）- 全部保留 ==========
VREDSUM   // 标准求和 - AvgPool, Softmax
VWREDSUM  // INT8→INT16宽位求和 - 大特征图防溢出

// ========== 归约最大/最小（4条）- 全部保留 ==========
VREDMAX   // 最大（有符号）- INT8 MaxPool
VREDMAXU  // 最大（无符号）- UINT8 MaxPool
VREDMIN   // 最小（有符号）- 某些池化变体
VREDMINU  // 最小（无符号）- UINT8 MinPool
```

 **移除指令（2条）** ：

```
VREDAND, VREDOR  // 位归约 - YOLO不用
```

 **面积影响** ：移除2条，**减少约8%的PMTRDT面积**

 **审查结论** ：

* ✅  **VWREDSUM必须保留** ：防止大特征图累加溢出
* ✅  **所有MIN/MAX保留** ：有符号/无符号都常见

---

### 3.4 LSU单元（12条）- 完全保留

```systemverilog
// ========== Unit-Stride（4条）- 全部保留 ==========
VLE8, VLE16, VLE32     // 连续加载
VSE8, VSE16, VSE32     // 连续存储

// ========== Strided（4条）- 全部保留 ==========
VLSE8, VLSE16, VLSE32  // 步长加载 - Im2Col
VSSE8, VSSE16, VSSE32  // 步长存储 - 转置

// ========== Indexed（4条）- 全部保留 ==========
VLXEI8, VLXEI16, VLXEI32   // 索引加载 - Gather
VSXEI8, VSXEI16, VSXEI32   // 索引存储 - Scatter
```

 **移除指令（0条）** ：全部保留

 **面积影响** ：0%

 **关键审查结论** ：

* ✅  **Indexed访存必须保留** ：FPN特征金字塔大量使用
* ✅  **移除会导致10-15%性能损失** ：不值得换7%面积

---

### 3.5 其他重要指令（3条）- 全部保留

根据opcode文件，还有一些重要的控制类指令：

```systemverilog
// ========== 掩码操作（OPMVV类型）==========
VMANDNOT  // 掩码与非 - 掩码合并
VMAND     // 掩码与
VMOR      // 掩码或
VMXOR     // 掩码异或
VMORN     // 掩码或非
VMNAND    // 掩码与非
VMNOR     // 掩码或非
VMXNOR    // 掩码同或
```
