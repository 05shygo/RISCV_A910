#include <cpu.h>
#include <bin.h>
#include <csr.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define pair(x, y) (((x) << 3) | (y))
#define PAIR_ENTRY(x, y, OP) case pair(x,y): ret.alu_op = OP; break
extern riscv32_CPU_state cpu;
ID2EX ID_R(IF2ID inst) {
    // 10 instructions
    //ADD/SLT/SLTU/AND/OR/XOR/SLL/SRL/SUB/SRA
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    ret.next_pc = inst.pc + 4;
    ret.pc = inst.pc;
    ret.inst = inst.inst;

    switch (pair(ret.inst_raw_split.r.funct7, ret.inst_raw_split.r.funct3)) {
        PAIR_ENTRY(0, 0, OP_ADD);
        PAIR_ENTRY(0, 1, OP_SLL);
        PAIR_ENTRY(0, 2, OP_SLT);
        PAIR_ENTRY(0, 3, OP_SLTU);
        PAIR_ENTRY(0, 4, OP_XOR);
        PAIR_ENTRY(0, 5, OP_SRL);
        PAIR_ENTRY(0, 6, OP_OR);
        PAIR_ENTRY(0, 7, OP_AND);
        PAIR_ENTRY(32, 0, OP_SUB);
        PAIR_ENTRY(32, 5, OP_SRA);
        // RV32M instructions (funct7 = 1)
        PAIR_ENTRY(1, 0, OP_MUL);
        PAIR_ENTRY(1, 1, OP_MULH);
        PAIR_ENTRY(1, 2, OP_MULHSU);
        PAIR_ENTRY(1, 3, OP_MULHU);
        PAIR_ENTRY(1, 4, OP_DIV);
        PAIR_ENTRY(1, 5, OP_DIVU);
        PAIR_ENTRY(1, 6, OP_REM);
        PAIR_ENTRY(1, 7, OP_REMU);
        default: ret.alu_op = OP_INVALID;
    }

    ret.is_jmp = 0;
    ret.is_branch = 0;
    ret.is_mem = 0;

    ret.src1.type = OP_TYPE_REG;
    ret.src1.value = cpu.gpr[ret.inst_raw_split.r.rs1];

    ret.src2.type = OP_TYPE_REG;
    ret.src2.value = cpu.gpr[ret.inst_raw_split.r.rs2];

    ret.dst = ret.inst_raw_split.r.rd;
    ret.wb_sel = WB_ALU;
    ret.wb_en = (ret.dst != 0);  // Don't write to x0

    return ret;
}

ID2EX ID_I_LOAD(IF2ID inst) {
    // LOAD
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    ret.alu_op = OP_ADD;
    ret.next_pc = inst.pc + 4;
    ret.pc = inst.pc;
    ret.inst = inst.inst;
    switch (ret.inst_raw_split.i.funct3) {
        case 0: ret.mem_op = MEM_LB; break;
        case 1: ret.mem_op = MEM_LH; break;
        case 2: ret.mem_op = MEM_LW; break;
        case 4: ret.mem_op = MEM_LBU; break;
        case 5: ret.mem_op = MEM_LHU; break;
        default: ret.mem_op = MEM_LW; break;
    }

    ret.is_jmp = 0;
    ret.is_branch = 0;
    ret.is_mem = 1;

    ret.src1.type = OP_TYPE_REG;
    ret.src1.value = cpu.gpr[ret.inst_raw_split.r.rs1];

    ret.src2.type = OP_TYPE_IMM;
    ret.src2.value = ret.inst_raw_split.i.simm11_0;
    
    ret.dst = ret.inst_raw_split.r.rd;
    ret.wb_sel = WB_LOAD;
    ret.wb_en = (ret.dst != 0);  // Don't write to x0

    return ret;
}

ID2EX ID_I(IF2ID inst) {
    // 9 instructions
    // ADDI/SLTI/SLTIU/ANDI/ORI/XORI
    // SLLI/SRLI/SRAI
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    ret.next_pc = inst.pc + 4;
    ret.pc = inst.pc;
    ret.inst = inst.inst;

    switch (ret.inst_raw_split.i.funct3) {
        case 0: ret.alu_op = OP_ADD; break;
        case 1: ret.alu_op = OP_SLL; break;
        case 2: ret.alu_op = OP_SLT; break;
        case 3: ret.alu_op = OP_SLTU; break;
        case 4: ret.alu_op = OP_XOR; break;
        case 5: if(ret.inst_raw_split.s.simm11_5 == 0) ret.alu_op = OP_SRL;
                else ret.alu_op = OP_SRA;
                break;
        case 6: ret.alu_op = OP_OR; break;
        case 7: ret.alu_op = OP_AND; break;
        default: ret.alu_op = OP_INVALID; break;
    }

    ret.is_jmp = 0;
    ret.is_branch = 0;
    ret.is_mem = 0;

    ret.src1.type = OP_TYPE_REG;
    ret.src1.value = cpu.gpr[ret.inst_raw_split.r.rs1];

    ret.src2.type = OP_TYPE_IMM;
    ret.src2.value = ret.inst_raw_split.i.simm11_0;

    ret.dst = ret.inst_raw_split.r.rd;
    ret.wb_sel = WB_ALU;
    ret.wb_en = (ret.dst != 0);  // Don't write to x0

    return ret;
}
ID2EX ID_S(IF2ID inst) {
    // 1 instruction
    // STORE
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    ret.next_pc = inst.pc + 4;
    ret.pc = inst.pc;
    ret.inst = inst.inst;

    ret.is_jmp = 0;
    ret.is_branch = 0;
    ret.is_mem = 1;

    ret.alu_op = OP_ADD;

    switch (ret.inst_raw_split.s.funct3) {
        case 0: ret.mem_op = MEM_SB; break;
        case 1: ret.mem_op = MEM_SH; break;
        case 2: ret.mem_op = MEM_SW; break;
        // 非法 funct3 (RISC-V 保留编码): 与 DUT 一致 —— 整条指令退化成纯 no-op,
        // 不写内存、不写寄存器、不报异常.
        //
        // 对齐参考实现 RISCV_CPU/cpu: 那个核对同一情形 `default:
        // inst_subtype_o = 4'b0` (= 它的 MEM_LB) 且 reg_wflag=0, 即"挑一个无害的
        // 默认值继续走", **不判非法指令** —— 它整个核都没有非法指令机制.
        //
        // is_mem=0 是关键: MEM.c 的访存块是 `if(ex_info.is_mem && !ret.exc_valid)`
        // 进入的, 置 0 之后既不真的写内存, 也不做越界/非对齐检查 —— 而
        // is_mem 仍为 1 的话, EX.c 会把 MEM_LB 当成一次 **load** 去查越界
        // (报 cause 5), 与 DUT 的"什么都不报"对不上. 同样, EX.c 的
        // is_store_op 只认 SB/SH/SW, mem_op=MEM_SW 会让它报 cause 6/7.
        default: ret.mem_op = MEM_LB; ret.is_mem = 0; break;
    }

    ret.src1.type = OP_TYPE_REG;
    ret.src1.value = cpu.gpr[ret.inst_raw_split.r.rs1];

    ret.src2.type = OP_TYPE_IMM;
    ret.src2.value = (ret.inst_raw_split.s.simm11_5 << 5 ) | (ret.inst_raw_split.s.imm4_0 );

    ret.store_val = cpu.gpr[ret.inst_raw_split.r.rs2];
    
    ret.wb_en = 0;

    return ret;
}

ID2EX ID_B(IF2ID inst) {
    // 6 instructions
    // BEQ/BNE/BLT/BLTU/BGE/BGEU
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    uint32_t imm = (ret.inst_raw_split.b.simm12 << 12) | (ret.inst_raw_split.b.imm11 << 11) | (ret.inst_raw_split.b.imm10_5 << 5) | (ret.inst_raw_split.b.imm4_1 << 1);
    ret.next_pc = inst.pc + imm;
    ret.pc = inst.pc;
    ret.inst = inst.inst;

    ret.is_jmp = 0;
    ret.is_branch = 1;
    ret.is_mem = 0;

    ret.alu_op = OP_ADD;

    switch(ret.inst_raw_split.b.funct3) {
        case 0: ret.br_op = BR_EQ; break;
        case 1: ret.br_op = BR_NEQ ; break;
        case 4: ret.br_op = BR_LT; break;
        case 5: ret.br_op = BR_GE; break;
        case 6: ret.br_op = BR_LTU; break;
        case 7: ret.br_op = BR_GEU; break;
    }

    ret.src1.type = OP_TYPE_REG;
    ret.src1.value = cpu.gpr[ret.inst_raw_split.r.rs1];

    ret.src2.type = OP_TYPE_REG;
    ret.src2.value = cpu.gpr[ret.inst_raw_split.r.rs2];

    ret.wb_en = 0;

    return ret;
}

ID2EX ID_U(IF2ID inst) {
    // 2 instructions
    // LUI/AUIPC
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    ret.next_pc = inst.pc + 4;
    ret.pc = inst.pc;
    ret.inst = inst.inst;

    ret.is_jmp = 0;
    ret.is_branch = 0;
    ret.is_mem = 0;

    ret.alu_op = OP_ADD;

    if(ret.inst_raw_split.u.opcode6_2 == 0xd) {
        ret.src1.value = 0;
    } else {
        ret.src1.value = inst.pc;
    }
    ret.src2.value = (ret.inst_raw_split.u.imm31_12 << 12);
    
    ret.dst = ret.inst_raw_split.u.rd;
    ret.wb_sel = WB_ALU;
    ret.wb_en = (ret.dst != 0);  // Don't write to x0

    return ret;
}

ID2EX ID_J(IF2ID inst) {
    // JAL/JALR
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    ret.next_pc = inst.pc + 4;
    ret.pc = inst.pc;
    ret.inst = inst.inst;

    ret.is_jmp = 1;
    ret.is_branch = 0;
    ret.is_mem = 0;

    ret.alu_op = OP_ADD;
    uint32_t jimm = (ret.inst_raw_split.j.simm20 << 20) | (ret.inst_raw_split.j.imm19_12 << 12) | (ret.inst_raw_split.j.imm11 << 11) | (ret.inst_raw_split.j.imm10_1  << 1);
    if(ret.inst_raw_split.j.opcode6_2 == 0x1b) {  // JAL 
        ret.next_pc = inst.pc + jimm;
    } else { // JALR
        ret.next_pc = (cpu.gpr[ret.inst_raw_split.r.rs1] + ret.inst_raw_split.i.simm11_0) & ~1u;
    }

    ret.dst = ret.inst_raw_split.j.rd;
    ret.wb_sel = WB_PC;
    ret.wb_en = (ret.dst != 0);  // Don't write to x0

    return ret;
}

// SYSTEM (opcode 1110011): CSR 五条 + ecall/ebreak/mret, 其余非法.
// 与 mySoC/idu/rtl/Control.v 的 `OPCODE_SYSTEM 分支逐条对应.
ID2EX ID_SYSTEM(IF2ID inst) {
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    ret.next_pc = inst.pc + 4;
    ret.pc = inst.pc;
    ret.inst = inst.inst;
    ret.csr_op = CSR_OP_NONE;

    uint32_t funct3 = ret.inst_raw_split.i.funct3;
    uint32_t rs1    = ret.inst_raw_split.r.rs1;
    uint32_t csr    = ret.inst_raw_split.csr.csr;   // inst[31:20]

    ret.src1.type  = OP_TYPE_REG;
    ret.src1.value = cpu.gpr[rs1];

    switch (funct3) {
        case 0: // PRIV: 用整条指令精确匹配
            if      (inst.inst == 0x00000073u) ret.alu_op = OP_ECALL;
            else if (inst.inst == 0x00100073u) ret.alu_op = OP_EBREAK;
            else if (inst.inst == 0x30200073u) { ret.alu_op = OP_MRET; ret.is_mret = 1; }
            else                               ret.alu_op = OP_INVALID;  // 含 WFI
            break;
        case 1: case 2: case 3: case 5: case 6: case 7: {
            uint32_t imm_form = (funct3 == 5) || (funct3 == 6) || (funct3 == 7);
            ret.csr_addr = csr;
            //    1=CSRRW 5=CSRRWI -> RW ;  2=CSRRS 6=CSRRSI -> RS ;  3/7 -> RC
            if      (funct3 == 1 || funct3 == 5) ret.csr_op = CSR_OP_RW;
            else if (funct3 == 2 || funct3 == 6) ret.csr_op = CSR_OP_RS;
            else                                 ret.csr_op = CSR_OP_RC;   // 3=CSRRC, 7=CSRRCI

            // csrrwi/csrrsi/csrrci 的源是 rs1 域里的 5 位零扩展立即数
            ret.src2.type  = imm_form ? OP_TYPE_IMM : OP_TYPE_REG;
            ret.src2.value = imm_form ? rs1 : cpu.gpr[rs1];

            // csrrw 总是写; csrrs/csrrc 只有 rs1 != x0 才写
            // (csrrs rd, csr, x0 是纯读, 对只读 CSR 也必须合法)
            ret.csr_we = (ret.csr_op == CSR_OP_RW) || (rs1 != 0);

            ret.alu_op = OP_CSR;
            ret.dst    = ret.inst_raw_split.r.rd;
            ret.wb_sel = WB_ALU;
            ret.wb_en  = (ret.dst != 0);

            // 未实现地址, 或对只读 CSR 尝试写 -> 非法指令
            if (!csr_is_known(csr) || (ret.csr_we && csr_is_readonly(csr)))
                ret.alu_op = OP_INVALID;
            break;
        }
        default:
            ret.alu_op = OP_INVALID;
            break;
    }
    return ret;
}

ID2EX ID(IF2ID inst) {
    ID2EX ret = {0};
    ret.inst_raw_split.inst_raw = inst.inst;
    ret.next_pc = inst.pc + 4;
    ret.pc = inst.pc;
    ret.inst = inst.inst;
    ret.wb_en = 0;

    // 取指越界 (instruction access fault, cause 1).
    // 与 DUT 的 id_inst_oob 对应: IROM 只有 64KB, PC 跑到更外面时取回来的
    // 是地址回绕后的别的指令, 不能按它译码, 直接报异常并返回.
    if (inst.pc >= MEM_SZ) {
        ret.exc_valid = 1;
        ret.exc_cause = EXC_INST_ACCESS;
        ret.exc_tval  = inst.pc;
        return ret;
    }

    Log("OpCode is %8.8x",  ((ret.inst_raw_split.i.opcode6_2) << 2) | (ret.inst_raw_split.i.opcode1_0) );
    switch( ((ret.inst_raw_split.i.opcode6_2) << 2) | (ret.inst_raw_split.i.opcode1_0) ) { // funct7
        // 必须是【8 位】二进制: B8(B0) 展开成 0x##B0, 参数在 ## 旁边不会被
        // 预展开, 所以写成 7 位的 B8(1110011) 会拼成字面量 0xB1110011 而不是
        // 0x73 —— 这个 case 一直是死代码(以前的 ecall 只靠 emu.c 的偷看生效).
        case B8(01110011):
            ret = ID_SYSTEM(inst);
            break;
        case B8(00110111):
        case B8(00010111):
            ret = ID_U(inst);
            break;
        case B8(01101111):
        case B8(01100111):
            ret = ID_J(inst);
            Log("Jump target = %8.8x", ret.next_pc);
            break;
        case B8(01100011):
            ret = ID_B(inst);
            Log("Branch target = %8.8x", ret.next_pc);
            break;
        case B8(00000011):
            ret = ID_I_LOAD(inst);
            break;
        case B8(00100011):
            ret = ID_S(inst);
            break;
        case B8(00010011):
            ret = ID_I(inst);
            break;
        case B8(00110011):
            ret = ID_R(inst);
            break;
        default:
            ret.alu_op = OP_INVALID;
            break;
    }

    // ID 级同步异常: 非法指令 / ecall / ebreak.
    // 与 DUT 一致 —— 非法指令的 mtval 记指令本身, ecall/ebreak 记 0.
    // 非对齐是在 EX 级检出的, 那里再补.
    if (ret.alu_op == OP_INVALID) {
        ret.exc_valid = 1;
        ret.exc_cause = EXC_ILLEGAL_INST;
        ret.exc_tval  = inst.inst;
    } else if (ret.alu_op == OP_ECALL) {
        ret.exc_valid = 1;
        ret.exc_cause = EXC_ECALL_M;
    } else if (ret.alu_op == OP_EBREAK) {
        ret.exc_valid = 1;
        ret.exc_cause = EXC_BREAKPOINT;
    }
    return ret;
}

