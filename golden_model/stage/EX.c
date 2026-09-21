#include <cpu.h>
#include <csr.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
extern riscv32_CPU_state cpu;
extern void print_reg_state();
// 定义在 MEM.c: 地址是否命中某个已注册的外设.
// 与 DUT 的 `ADDR_IN_MAP 判据一一对应(外设集合两边都是 MONITOR/DIG/TIMER).
extern bool is_peripheral(uint32_t addr, size_t* id);
#define ALU_CASE_ENTRY(op, calc) case op: alu_result = (calc); break
#define BR_CASE_ENTRY(op, calc) case op: br_result = (calc); break
EX2MEM EX(ID2EX decode_info) {
    EX2MEM ret;
    // Passthrough
    ret.inst = decode_info.inst;
    ret.pc = decode_info.pc;
    ret.wb_sel = decode_info.wb_sel;
    ret.wb_en = decode_info.wb_en;
    ret.dst = decode_info.dst;
    ret.target_pc = decode_info.next_pc; // evaluated in ID
    ret.store_val = decode_info.store_val;
    ret.is_mem = decode_info.is_mem;
    ret.mem_op = decode_info.mem_op;
    Log("PC=%8.8x", ret.pc);

    // 陷阱信息: 由 ID 级传来的(非法/ecall/ebreak), 下面 EX 级可能再补非对齐
    ret.exc_valid = decode_info.exc_valid;
    ret.exc_cause = decode_info.exc_cause;
    ret.exc_tval  = decode_info.exc_tval;
    ret.is_mret   = decode_info.is_mret;

    uint32_t alu_result;
    uint32_t src1 = decode_info.src1.value;
    uint32_t src2 = decode_info.src2.value;
    switch(decode_info.alu_op) {
        case OP_INVALID:
            // 非法指令: 不再 panic(那会把整个仿真进程 abort 掉).
            // ID 级已经置好 exc_valid/cause=2, 这里只需给个确定值.
            alu_result = 0;
            break;
        case OP_ECALL:
        case OP_EBREAK:
            // 异常由 WB 统一入口处理; 这里不产生任何架构副作用.
            // (注意: emu.c 的 cpu_poll_halt 仍会在 mtvec==0 时把裸 ecall
            //  当作"测试结束", 那是 gold model 侧的兼容层, 见 emu.c.)
            alu_result = 0;
            break;
        case OP_MRET:
            alu_result = 0;
            break;
        case OP_CSR: {
            // 读旧值 -> 算新值 -> 写. 与 CSR.v 的 EX 级行为一致:
            // RW 直接写源, RS 置位, RC 清位; 源在 imm 形式下是 uimm5.
            uint32_t old = csr_read(decode_info.csr_addr);
            uint32_t src = decode_info.src2.value;
            uint32_t wdata = (decode_info.csr_op == CSR_OP_RW) ? src
                           : (decode_info.csr_op == CSR_OP_RS) ? (old |  src)
                           :                                     (old & ~src);
            if (decode_info.csr_we)
                csr_write(decode_info.csr_addr, wdata);
            alu_result = old;   // rd 拿到的是【旧】值
            break;
        }
            ALU_CASE_ENTRY(OP_ADD, src1 + src2);
            ALU_CASE_ENTRY(OP_SLT, (int32_t)src1 < (int32_t)src2);
            ALU_CASE_ENTRY(OP_SLTU, src1 < src2);
            ALU_CASE_ENTRY(OP_AND, src1 & src2);
            ALU_CASE_ENTRY(OP_OR, src1 | src2);
            ALU_CASE_ENTRY(OP_XOR, src1 ^ src2);
            ALU_CASE_ENTRY(OP_SLL, src1 << src2);
            ALU_CASE_ENTRY(OP_SRL, src1 >> src2);
            ALU_CASE_ENTRY(OP_SUB, src1 - src2);
            ALU_CASE_ENTRY(OP_SRA, (int32_t)src1 >> src2);
            // RV32M: Multiply instructions
            ALU_CASE_ENTRY(OP_MUL, (uint32_t)((int64_t)(int32_t)src1 * (int64_t)(int32_t)src2));
            ALU_CASE_ENTRY(OP_MULH, (uint32_t)(((int64_t)(int32_t)src1 * (int64_t)(int32_t)src2) >> 32));
            ALU_CASE_ENTRY(OP_MULHSU, (uint32_t)(((int64_t)(int32_t)src1 * (uint64_t)src2) >> 32));
            ALU_CASE_ENTRY(OP_MULHU, (uint32_t)(((uint64_t)src1 * (uint64_t)src2) >> 32));
            // RV32M: Divide instructions
            case OP_DIV:
                if ((int32_t)src2 == 0) alu_result = 0xFFFFFFFF;
                else if ((int32_t)src1 == 0x80000000 && (int32_t)src2 == -1) alu_result = 0x80000000;
                else alu_result = (uint32_t)((int32_t)src1 / (int32_t)src2);
                break;
            case OP_DIVU:
                if (src2 == 0) alu_result = 0xFFFFFFFF;
                else alu_result = src1 / src2;
                break;
            case OP_REM:
                if ((int32_t)src2 == 0) alu_result = src1;
                else if ((int32_t)src1 == 0x80000000 && (int32_t)src2 == -1) alu_result = 0;
                else alu_result = (uint32_t)((int32_t)src1 % (int32_t)src2);
                break;
            case OP_REMU:
                if (src2 == 0) alu_result = src1;
                else alu_result = src1 % src2;
                break;
        default: alu_result = 0;
    }
    ret.alu_out = alu_result;
    Log("ALU Result = %8.8x", alu_result);

    uint32_t br_result = 0;
    if(decode_info.is_branch) {
        switch(decode_info.br_op) {
            BR_CASE_ENTRY(BR_EQ, src1 == src2);
            BR_CASE_ENTRY(BR_NEQ, src1 != src2);
            BR_CASE_ENTRY(BR_GE, (int32_t)src1 >= (int32_t)src2);
            BR_CASE_ENTRY(BR_GEU, src1 >= src2);
            BR_CASE_ENTRY(BR_LT, (int32_t)src1 < (int32_t)src2);
            BR_CASE_ENTRY(BR_LTU, src1 < src2);
            default: br_result = 0; break;
        }
    } else if (decode_info.is_jmp) {
        br_result = 1;
    }
    Log("BR Result = %8.8x", br_result);
    ret.branch_taken = br_result;

    // ---- EX 级异常: 地址非对齐 (与 mycpu.v 的 ex_local_exc_* 对应) ----
    // 只有"这条指令本身没有异常"时才检查, 且优先级: 指令地址 > 访存地址.
    if (!ret.exc_valid) {
        if (decode_info.is_mem) {
            uint32_t addr = src1 + src2;    // 访存地址 = rs1 + imm
            uint32_t bad = 0, store = 0;
            uint32_t is_store_op = (decode_info.mem_op == MEM_SB ||
                                    decode_info.mem_op == MEM_SH ||
                                    decode_info.mem_op == MEM_SW);
            size_t periph_id;
            // 地址越界 -> 访问异常 (load=5 / store=7).
            // 判据与 DUT 的 `ADDR_IN_MAP 一致: DRAM 窗口(低 64KB) 或已注册的
            // 外设才合法. 优先级高于非对齐(地址都不存在, 谈对齐没有意义).
            // 这里【不】abort 宿主进程 —— 那是原来 MEM.c 里 Assert 干的事.
            if (addr >= MEM_SZ && !is_peripheral(addr, &periph_id)) {
                ret.exc_valid = 1;
                ret.exc_cause = is_store_op ? EXC_STORE_ACCESS : EXC_LOAD_ACCESS;
                ret.exc_tval  = addr;
                return ret;
            }
            switch (decode_info.mem_op) {
                case MEM_LW: bad = (addr & 0x3u) != 0; break;
                case MEM_SW: bad = (addr & 0x3u) != 0; store = 1; break;
                case MEM_LH: case MEM_LHU: bad = (addr & 0x1u) != 0; break;
                case MEM_SH: bad = (addr & 0x1u) != 0; store = 1; break;
                default: break;             // 字节访问天然对齐
            }
            if (bad) {
                ret.exc_valid = 1;
                ret.exc_cause = store ? EXC_STORE_MISALIGNED : EXC_LOAD_MISALIGNED;
                ret.exc_tval  = addr;
            }
        }
        if (!ret.exc_valid && (decode_info.is_branch || decode_info.is_jmp)) {
            int taken = decode_info.is_jmp ? 1 : (int)br_result;
            uint32_t tgt = decode_info.next_pc;
            // JALR 的 next_pc 在 ID 里被 & ~1u 掩过码, 而 DUT 的 NPC 用的是
            // 未掩码的 ALU 结果. mtval 必须两侧一致, 所以这里按未掩码值算.
            if ((decode_info.inst & 0x7fu) == 0x67u)   // JALR
                tgt = cpu.gpr[decode_info.inst_raw_split.r.rs1]
                    + decode_info.inst_raw_split.i.simm11_0;
            if (taken && (tgt & 0x3u)) {
                ret.exc_valid = 1;
                ret.exc_cause = EXC_INST_MISALIGNED;
                ret.exc_tval  = tgt;
            }
        }
    }

    return ret;
}
