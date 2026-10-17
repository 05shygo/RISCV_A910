# CoralNPU 接入里程碑 1 —— CPU 启动 NPU 的最小闭环

## 目标

把 CoralNPU 作为 AXI 外设接进 `miniRV_SoC`,先跑通最小闭环:
**CPU 把程序写进 NPU 的 ITCM → 配 pcStart → 放时钟门控与复位 → NPU 自己跑完 →
CPU 读回结果**。不涉及向量指令、不涉及张量搬运、不涉及 YOLO。

## 为什么是这个形态

### 为什么不"把 NPU 的向量单元接进 CPU"

CoralNPU 的向量单元是**协处理器后端**,不是能挂在总线上的加速器:

- `rvv/RvvInterface.scala` 的 `RvvCoreIO` 要求外部提供**译码后的指令**(私有压缩格式,
  `RvvDecode.scala`)、8 个标量操作数读端口、以及向量 load/store 的 uop 协议
- 向量单元**没有任何内存端口** —— 所以 `hdl/verilog/rvv/design/RvvCore.sv` 里没有 AXI
- `SCore.scala` 显示它深度缝合进标量核的退休缓冲、异常通路和寄存器堆仲裁

而 miniRV 是教科书 5 级顺序流水,**没有 ROB**,一样都没有。硬接等于在 miniRV 里重写
CoralNPU 的半个前端。

CoralNPU 本来就是设计成外设的(`doc/integration_guide.md` 第一句),所以**整体挂载**。

### 为什么 CPU 侧是"寄存器窗口"而不是内存窗口

myCPU 的数据总线是**零握手**的(`mySoC/perip_bridge.v` 的接口约束):

- MMIO 读必须**当拍组合返回** —— MEM 级没有 ready/busy/stall
- DRAM load 是硬编码 1 周期(`Bus_raddr` 在 EX 级发出)
- `sb/sh` 在 MEM 级用同拍 `Bus_rdata` 做读-改-写

而 AXI 单拍往返是**多周期**的。两者不可能直接对接。

所以 `mySoC/npu_bridge.v` 把 AXI 藏在一个**寄存器堆**后面:CPU 侧读的全部是触发器,
零延迟契约原样保留,myCPU 一行都不用改;CPU 通过 WADDR/WDATA/RADDR/RCMD 显式驱动一个
访问引擎,自己轮询 BUSY。

## 结构

```
miniRV_SoC.v
 ├── myCPU                          (不动)
 ├── perip_bridge.v                 (加 NPU 窗口解码 + 读 mux)
 │    └── sel_npu → 0x4000_0000-0x4000_0FFF
 ├── mySoC/npu_bridge.v             寄存器堆 + 32→128 AXI 单拍引擎
 └── npu/npu_core_wrap.v
       ├── RvvCoreMiniAxi           (bazel 生成, 不在仓库里)
       └── null slave               给 NPU 主口一个永远 SLVERR 的从机
```

### 寄存器映射 (基址 0x4000_0000)

| 偏移 | 名称 | 方向 | 说明 |
|---|---|---|---|
| 0x00 | CTL | RW | bit0 resetn(0=NPU 保持复位;复位值 0) |
| 0x04 | WADDR | RW | [17:0] 本地写地址,每次 WDATA 被接收后自动 +4 |
| 0x08 | WDATA | WO | 写入即发起一次单拍 AXI 写 |
| 0x0C | STATUS | RO | [0]BUSY [1]ERR [2]OVERFLOW [3]halted [4]fault [5]wfi [6]RVALID |
| 0x10 | RADDR | RW | [17:0] 本地读地址,每次 RCMD 后自动 +4 |
| 0x14 | RCMD | WO | 写入即发起一次单拍 AXI 读 |
| 0x18 | RDATA | RO | 最近一次读回的字 |
| 0x1C | ERRADDR | RO | 最后一次失败事务的地址 |
| 0x20 | ERRCLR | WO | 写任意值清 ERR/OVERFLOW/RVALID |

地址是 **NPU 本地地址**,不做基址减法:ITCM `0x0`、DTCM `0x10000`、CSR `0x30000`。
与 IC2 版 `Parameters.scala` 的 `MemoryRegions.default` 一致。

**⚠️ 全程只用 `sw`/`lw`。** `perip_bridge.v` 写明"总线上看不出 sb/sh,外设只能按整字
sw 写" —— 半字写会走读-改-写,把高 lane 的垃圾一起写进去。

### 32→128 位宽适配

```
lane     = addr[3:2]
WDATA128 = {4{wdata32}} << (lane*32)
WSTRB16  = 16'h000F     << (lane*4)
RDATA32  = rdata128[lane*32 +: 32]
```

关键落位(已在 `CoreAxiCSR.scala` 核对):CSR+0x00 落 lane0、CSR+0x04(pcStart)落
lane1 即 `WDATA[63:32]`、CSR+0x08(status)读选 `RDATA[95:64]`。

这是最容易写错的地方 —— **pcStart 不是低 32 位**。Gate 4 有专门的变异对照。

### 时钟与复位

- `io_aclk = cpu_clk`(同域,零 CDC)
- `io_aresetn = CTL[0]`,软件控制,复位值 0
- 软件写 `CTL[0]=1` 后桥内加载 **16 拍保持计数器**,期间 BUSY=1。这确定性覆盖了
  `RstSync`(2 拍)+ `axiEnable`(1 拍),不依赖软件的延时循环
- 桥和 wrap 用 `fpga_rst`,**不用 `rst_cpu`**(后者是 CPU 专用)

### NPU 主口为什么必须接一个 null slave

不能悬空。NPU 的 `io.dbus.ready` 依赖响应到达(`DBus2Axi` 里 ready 由 resp.fire/data.fire
驱动),任何一次落到 TCM 之外的访存都会让 LSU **永久卡死** —— 没有 fault、没有 halted,
CPU 侧只能看到轮询 BUSY 到超时,完全不知道发生了什么。

回 **SLVERR** 而不是 OKAY,是为了让"程序跑飞出了 TCM"变成**可诊断的 fault**
(粘滞到 `io_fault`,经 STATUS 位被 CPU 读到),而不是看似正常的错误数据。

## 怎么跑

### 前置:生成 RvvCoreMiniAxi.sv

```bash
cd /x2025/GPrj1/IC1/riscv/coralnpu_v2
LD_LIBRARY_PATH=/home/IC1/g ~/tools/bazel/bazel-9.1.0-new build \
    //hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_emit_verilog
cp bazel-bin/hdl/chisel/src/coralnpu/RvvCoreMiniAxi.sv \
   /x2025/GPrj1/IC1/riscv/RISCV_CPU/cdp-tests/npu/core/
md5sum .../npu/core/RvvCoreMiniAxi.sv > .../npu/core/RvvCoreMiniAxi.sv.md5
```

生成文件**不入库**(几十万行,且随 Chisel 源码变)。缺它时 `make npu-run` 会报
"找不到模块 RvvCoreMiniAxi"。

#### 本机跑 bazel 的坑(详见 `~/tools/bazel/README-ic1.md`)

本机是 CentOS 7 / glibc 2.17,而官方 bazel 9.1.0 启动器要 GLIBC_2.25。三条死路
都试过并记录在 README 里,最后可行的办法是**绕过启动器 + 短路径解释器**:

1. 把 bazel 的 zip 载荷解出来(要先把中央目录里的 local header 偏移减去载荷起点)
2. 解释器统一改成 **短路径** `/home/IC1/g/ld.so`(glibc 2.34)。
   **关键**:路径必须比原来的 `/lib64/ld-linux-x86-64.so.2` 短,否则 patchelf
   会重排段布局(基址 0x400000→0x3fe000)导致 segfault
3. `~/g/` 汇总 glibc 2.34 + 新 libstdc++/libgcc_s/libz
4. 补丁要打进**自带的 zip 载荷**里 —— 直接改 install base 会被摘要校验判为
   "Corrupt installation" 并重新解压
5. `--server_javabase` 指向解出来的 JDK(bazel 惰性解压不到位,需手动补全
   `embedded_tools/`)

`.bazelrc.user` 里固化了:CC 覆盖(本机无 clang)、`--server_javabase`、
`--downloader_config`(GitHub 走 `ghfast.top` 代理,直连已不可用)。

**如果后续有人能在好网络上构建**,把 `bazel-bin/.../RvvCoreMiniAxi.sv` 直接
拷进来即可 —— 那一份是自包含单文件,不需要重建环境。

### Gate 2(主判据)

```bash
make npu-run TEST=npu_loop MAX_CYCLES=200000
```

判据四条:trace 里全 PASS 且 `simv` 返回 0。

### Gate 3(difftest 变体)

```bash
make NPU=1 TEST=npu_smoke run
```

### Gate 1(回归:证明没破坏原基线)

```bash
make build           # 不带 NPU
make IFU=1 run-all   # 48/48
```

## 为什么主判据不用 difftest

黄金模型不知道 NPU 的存在,而 NPU 的完成时刻不可能被"逐条指令比对"的模型跟踪:
轮询循环在模型里第 1 圈就退出、在 DUT 里要转 N 圈,pc 序列**必然**发散。

所以:
- **主判据**走专用 TB `tb/npu/tb_npu_loop.sv`,直接看信号
- **difftest 变体** `npu_smoke.S` 把轮询换成**固定延时**(循环内无 MMIO ⇒ 两边指令流
  逐位相同),模型按"NPU 正确执行后会是什么"应答 ⇒ 模型变成**独立检查器**

`npu_smoke` 验证的是"CPU 侧程序本身没写错",不验证 NPU 算得对不对(模型不跑 NPU 的
程序,DTCM 内容是写死的期望值)。

## 与同事方案的接口(已核实)

| 项 | 结论 |
|---|---|
| AXI 接口签名 | 相同 —— `aclk`/`aresetn`/`axi_slave`/`axi_master` |
| 默认地址映射 | 相同 —— ITCM `0x0`/8KB、DTCM `0x10000`/32KB、CSR `0x30000`/4KB |
| CSR 偏移 | 相同 —— `0x0` reset/cg、`0x4` pcStart、`0x8` status |
| status 语义 | 相同 —— `Cat(io.fault, io.halted)`,bit0 = halted |
| 程序收尾 | 相同 —— `mpause` = `0x08000073` |
| 目标模块 | `RvvCoreMiniAxi`(`--enableRvv=True --enableVector=False`) |

> ⚠️ `hdl/chisel/src/coralnpu/BUILD` 里**所有**目标都是 `--enableVector=False` ——
> Chisel 那套自定义 SIMD(`hdl/chisel/src/coralnpu/vector/`,含 `VDot.scala` 外积引擎)
> 没有任何可构建目标在用。对 ML 有用的是 **RVV 后端**,也就是同事在裁剪的那套。

## 本次集成的附加价值

同事的 RTL 裁剪(移除 DIV/FALU/ZVT + 部分掩码/位归约指令)此前只做过**代码审查**验证
(他的阶段 9 报告原文:"验证方式: 代码审查和信号连接分析"),**从未仿真过**。

本里程碑的 Gate 2/Gate 3 就是那套裁剪版 RTL 的**首次功能仿真证据**。
