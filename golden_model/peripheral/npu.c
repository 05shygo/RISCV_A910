#include "npu.h"

// 必须与 mySoC/npu_bridge.v 的寄存器偏移一致
#define NPU_CTL      0x00
#define NPU_WADDR    0x04
#define NPU_WDATA    0x08
#define NPU_STATUS   0x0C
#define NPU_RADDR    0x10
#define NPU_RCMD     0x14
#define NPU_RDATA    0x18
#define NPU_ERRADDR  0x1C
#define NPU_ERRCLR   0x20

// STATUS 位 (与 npu_bridge.v 一致)
#define ST_BUSY      0x01
#define ST_ERR       0x02
#define ST_OVF       0x04
#define ST_HALT      0x08
#define ST_FAULT     0x10
#define ST_RVALID    0x40

// NPU 本地地址 (IC2 版 Parameters.scala:44-48 的 MemoryRegions.default)
#define NPU_ITCM_BASE   0x00000000u
#define NPU_ITCM_SIZE   0x00002000u     // 8 KB
#define NPU_DTCM_BASE   0x00010000u
#define NPU_DTCM_SIZE   0x00008000u     // 32 KB
#define NPU_CSR_BASE    0x00030000u

// 期望值 —— 必须与 npu/npu_prog.S 里写的两个魔数一致
#define EXP_W0          0xCAFEBABEu
#define EXP_W1          0x12345678u

// ---- 桥的寄存器堆影子 ----
static uint32_t npu_ctl;
static uint32_t npu_waddr;
static uint32_t npu_raddr;
static uint32_t npu_rdat;
static uint32_t npu_csr_reset;      // CSR+0x00 最后被写入的值
static uint32_t npu_csr_pcstart;    // CSR+0x04
// STATUS.RVALID 必须跟着走 —— difftest 比的是**读出来的寄存器值**,
// 所以模型给的 STATUS 每一位都要和 DUT 逐位相同. 漏掉这一位就会在
// "读 STATUS" 那条指令上报失配.
static int      npu_rvalid;
static int      npu_initialized;

// ---- ITCM 影子 (CPU 只往 ITCM 写; DTCM 由 NPU 程序写, 模型无从得知) ----
#define ITCM_WORDS (NPU_ITCM_SIZE / 4)
static uint32_t itcm_shadow[ITCM_WORDS];

// NPU 侧一次读会返回什么.
// 模型不执行 NPU 的程序, 所以 DTCM/CSR 按"NPN 正确执行后应当是什么"作答.
static uint32_t npu_side_read(uint32_t addr) {
    if (addr >= NPU_ITCM_BASE && addr < NPU_ITCM_BASE + NPU_ITCM_SIZE) {
        // ITCM 是可回读的影子 —— CPU 写进去什么就读出什么.
        return itcm_shadow[(addr >> 2) % ITCM_WORDS];
    }
    if (addr >= NPU_DTCM_BASE && addr < NPU_DTCM_BASE + NPU_DTCM_SIZE) {
        // DTCM: npu_prog.S 往里写的两个魔数. 写别的地址说明 CPU 读错了地方.
        if (addr == NPU_DTCM_BASE + 0) return EXP_W0;
        if (addr == NPU_DTCM_BASE + 4) return EXP_W1;
        return 0;
    }
    if (addr == NPU_CSR_BASE + 0x0) return npu_csr_reset;
    if (addr == NPU_CSR_BASE + 0x4) return npu_csr_pcstart;
    if (addr == NPU_CSR_BASE + 0x8) {
        // statusReg := Cat(io.fault, io.halted) ⇒ bit0 = halted.
        // 走到这里说明 CPU 认为 NPU 已经跑完 (npu_smoke 在读之前有固定延时),
        // 所以模型答"已 halted, 无 fault".
        return 0x1u;
    }
    return 0;
}

static void npu_reset_if_needed(void) {
    unsigned i;   // 不在 for 里声明 —— VCS 内置 C 编译器的标准不确定, 别赌 C99
    if (!npu_initialized) {
        npu_initialized = 1;
        for (i = 0; i < ITCM_WORDS; i++) itcm_shadow[i] = 0;
    }
}

uint32_t read_npu(uint32_t rel_addr, AccessMode mode) {
    npu_reset_if_needed();
    Assert(mode == ACCESS_WORD && !(rel_addr & 0x3), "NPU: 非字访问或未对齐");

    switch (rel_addr) {
    case NPU_CTL:     return npu_ctl;
    case NPU_WADDR:   return npu_waddr;
    case NPU_WDATA:   return 0;              // 只写
    case NPU_STATUS:
        // 模型里访问引擎永远"已完成" (BUSY=0), 且 NPU 已经 halted.
        // ⚠️ 所以 npu_smoke.S **不能轮询 BUSY** —— DUT 的 BUSY 是几个周期的
        //    真实电平, 模型恒 0, 轮询循环两边圈数不同 ⇒ pc 序列发散.
        //    用固定延时循环代替轮询 (见 asm/npu_smoke.S).
        return ST_HALT | (npu_rvalid ? ST_RVALID : 0);
    case NPU_RADDR:   return npu_raddr;
    case NPU_RCMD:    return 0;              // 只写
    case NPU_RDATA:   return npu_rdat;
    case NPU_ERRADDR: return 0;
    case NPU_ERRCLR:  return 0;              // 只写
    default:          return 0;
    }
}

void write_npu(uint32_t rel_addr, AccessMode mode, uint32_t data) {
    npu_reset_if_needed();
    Assert(mode == ACCESS_WORD && !(rel_addr & 0x3), "NPU: 非字访问或未对齐");

    switch (rel_addr) {
    case NPU_CTL:
        npu_ctl = data & 0x3u;
        break;

    case NPU_WADDR:
        npu_waddr = data & 0x3FFFFu;
        break;

    case NPU_WDATA:
        // 写 ITCM 影子, 然后自增 —— 与 npu_bridge.v:W_RESP 的行为一致
        if (npu_waddr >= NPU_ITCM_BASE && npu_waddr < NPU_ITCM_BASE + NPU_ITCM_SIZE) {
            itcm_shadow[(npu_waddr >> 2) % ITCM_WORDS] = data;
        }
        // 写到 ITCM 之外只记 WADDR, 不 panic —— DUT 侧也一样照单全收
        // (落到 DTCM/CSR 的写是合法的, 只是本程序不用)
        npu_waddr = (npu_waddr + 4) & 0x3FFFFu;
        npu_rvalid = 0;         // 有新的写 ⇒ 旧读数据作废 (npu_bridge.v 同)
        break;

    case NPU_RADDR:
        npu_raddr = data & 0x3FFFFu;
        break;

    case NPU_RCMD:
        npu_rdat   = npu_side_read(npu_raddr);
        npu_raddr  = (npu_raddr + 4) & 0x3FFFFu;
        npu_rvalid = 1;
        break;

    case NPU_ERRCLR:
        // 清粘滞错误 + RVALID —— 模型里本来就没有错误
        npu_rvalid = 0;
        break;

    default:
        // 未实现的偏移: DUT 那边读回 0、写被忽略. 不 panic, 保持两边一致.
        break;
    }
}
