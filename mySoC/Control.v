`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/06/30 15:50:54
// Design Name: 
// Module Name: Control
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`include "defines.vh"

module Control(
    input wire [6:0]                    opcode       ,
    input wire [2:0]                    funct3       ,
    input wire [6:0]                    funct7       ,
    // 系统指令译码需要 rs1 域(csrrwi 的 uimm5 / ecall-ebreak-mret 的区分)
    // 和 csr 域
    input wire [4:0]                    rs1_addr     ,   // id_inst[19:15]
    input wire [11:0]                   csr_addr     ,   // id_inst[31:20]
    output reg [`Sext_OP_WDITH-1:0]     sext_op      ,
    output reg [`NPC_SEL_WIDTH-1:0]     npc_op       ,
    output reg [`ALU_OP_WIDTH-1:0]      alu_op       ,
    output reg [`ALUA_SEL_WIDTH-1:0]    alua_sel     ,
    output reg [`ALUB_SEL_WIDTH-1:0]    alub_sel     ,
    output reg [`RF_WSEL_WIDTH-1:0]     rf_wsel      ,
    output reg [`DRAM_SEL_WIDTH-1:0]    dram_sel     ,
    output reg                          rf_we        ,
    output reg                          ram_we       ,
    output reg                          is_muldiv    , // 标识乘除法指令
    output wire                         id_rf1_used  ,
    output wire                         id_rf2_used  ,

    // ---- 系统指令 / 陷阱 ----
    output reg                          is_illegal   ,
    output reg                          is_ecall     ,
    output reg                          is_ebreak    ,
    output reg                          is_mret      ,
    output reg  [2:0]                   csr_op       ,
    output reg                          csr_imm      ,
    output reg                          csr_we
    );

    // 已实现的 CSR 地址 (未实现地址 -> 非法指令)
    wire csr_addr_known = (csr_addr == `CSR_MSTATUS)  || (csr_addr == `CSR_MIE)
                       || (csr_addr == `CSR_MTVEC)    || (csr_addr == `CSR_MSCRATCH)
                       || (csr_addr == `CSR_MEPC)     || (csr_addr == `CSR_MCAUSE)
                       || (csr_addr == `CSR_MTVAL)    || (csr_addr == `CSR_MIP)
                       || (csr_addr == `CSR_MCYCLE)   || (csr_addr == `CSR_MCYCLEH)
                       || (csr_addr == `CSR_MINSTRET) || (csr_addr == `CSR_MINSTRETH)
                       || (csr_addr == `CSR_CYCLE)    || (csr_addr == `CSR_CYCLEH)
                       || (csr_addr == `CSR_INSTRET)  || (csr_addr == `CSR_INSTRETH);

    // 只读 CSR: mip 的 MTIP 由硬件驱动, 所有计数器都由硬件驱动.
    // 对它们"尝试写"(csrrw 总是写; csrrs/csrrc 只要 rs1 != x0 就写) -> 非法指令.
    // 注意 csrrs rd, csr, x0 是纯读, 对只读 CSR 也必须合法.
    wire csr_addr_ro = (csr_addr == `CSR_MIP)
                    || (csr_addr == `CSR_MCYCLE)   || (csr_addr == `CSR_MCYCLEH)
                    || (csr_addr == `CSR_MINSTRET) || (csr_addr == `CSR_MINSTRETH)
                    || (csr_addr == `CSR_CYCLE)    || (csr_addr == `CSR_CYCLEH)
                    || (csr_addr == `CSR_INSTRET)  || (csr_addr == `CSR_INSTRETH);

    // -----------------------------------------------------------------------
    // 系统指令 / 非法指令译码.
    // 单独放一个 always 块, 不去动上面原有的 opcode 分支结构: 那些分支里
    // 有些信号是【故意不赋值、靠 latch 保留】的(LUI 就是这样), 混进去容易
    // 引入新的锁存问题.
    // -----------------------------------------------------------------------
    always @(*) begin
        is_illegal = 1'b0;
        is_ecall   = 1'b0;
        is_ebreak  = 1'b0;
        is_mret    = 1'b0;
        csr_op     = `CSR_OP_NONE;
        csr_imm    = 1'b0;
        csr_we     = 1'b0;

        case (opcode)
            `OPCODE_SYSTEM: begin
                case (funct3)
                    `FUNCT3_PRIV: begin
                        // ecall/ebreak/mret 用整条指令匹配.
                        // 用 csr 域(inst[31:20]) 而不是 funct7+rs2 区分:
                        //   ecall  = 0x000  ebreak = 0x001  mret = 0x302
                        // 注意 mret 的 rs1 域是 0, 那个 "010" 在 rs2 域([24:20])里
                        // —— 按 rs1==2 判会把 mret 误判成非法指令.
                        // 三种合法形式都要求 rs1 == x0.
                        if      (csr_addr == 12'h000 && rs1_addr == 5'd0) is_ecall  = 1'b1;
                        else if (csr_addr == 12'h001 && rs1_addr == 5'd0) is_ebreak = 1'b1;
                        else if (csr_addr == 12'h302 && rs1_addr == 5'd0) is_mret   = 1'b1;
                        else                                              is_illegal = 1'b1;
                    end
                    `FUNCT3_CSRRW, `FUNCT3_CSRRS, `FUNCT3_CSRRC,
                    `FUNCT3_CSRRWI,`FUNCT3_CSRRSI,`FUNCT3_CSRRCI: begin
                        case (funct3)
                            `FUNCT3_CSRRW,
                            `FUNCT3_CSRRWI: csr_op = `CSR_OP_RW;
                            `FUNCT3_CSRRS,
                            `FUNCT3_CSRRSI: csr_op = `CSR_OP_RS;
                            // CSRRCI 以及其余 (CSRRC) 都是清位
                            default:        csr_op = `CSR_OP_RC;
                        endcase
                        csr_imm = (funct3 == `FUNCT3_CSRRWI)
                               || (funct3 == `FUNCT3_CSRRSI)
                               || (funct3 == `FUNCT3_CSRRCI);
                        // csrrwi/rs i/ci 的 uimm5 就在 rs1 域里, 所以判据是同一个
                        csr_we  = (csr_op == `CSR_OP_RW) || (rs1_addr != 5'b0);
                        is_illegal = ~csr_addr_known || (csr_we && csr_addr_ro);
                    end
                    default: is_illegal = 1'b1;   // 其余 funct3 (含 WFI) 一律非法
                endcase
            end
            // 已实现的基本指令: 不在这里判非法
            `OPCODE_R, `OPCODE_I_REG, `OPCODE_I_LOAD, `OPCODE_JALR, `OPCODE_S,
            `OPCODE_B, `OPCODE_LUI, `OPCODE_AUIPC, `OPCODE_JAL: ;
            // 未实现的 opcode: 以前只是静默当成 nop 且 have_inst=0,
            // 现在要报非法指令并真正陷入
            default: is_illegal = 1'b1;
        endcase
    end
    // 原来的 have_inst opcode 白名单已删除: "这个槽位里有没有真指令"改由
    // IF_ID.id_have_inst 提供. 白名单方案会漏掉 0x73(SYSTEM) 和未知 opcode,
    // 于是 ecall / 非法指令根本不会提交, 陷阱机制无法工作.

assign id_rf1_used = ~((opcode == `OPCODE_LUI) || (opcode == `OPCODE_JAL));
// CSR 指令的源是 rs1(不是 rs2), 而 id_rf1_used 对 SYSTEM 本来就是 1,
// 转发的 A 通路(Forward_A_en / A_forward, 按 id_rR1 判定)正好覆盖它.
assign id_rf2_used = ((opcode == `OPCODE_R) || (opcode == `OPCODE_S) || (opcode == `OPCODE_B));

always @(*) begin
    // -----------------------------------------------------------------------
    // 无条件默认值 —— **必须留在 case 之前** (2026-09-28)
    //
    // 这段 case 有几条分支不给某些信号赋值 (R 不给 sext_op; LUI/JAL 不给
    // alu_op/alua_sel/alub_sel; S/B 不给 rf_wsel; 7 条不给 dram_sel)。
    // 缺赋值 ⇒ Vivado 推断电平敏感 latch (实测 Control 出 6 处、16 个 LDCE),
    // 而 latch 的门是数据信号 ⇒ 被报成 `TIMING-20 Non-clocked latch`,
    // 那些路径**根本不进时序分析**, 工具也不会去优化它们。
    //
    // 逐条核过每个"洞"的下游都走不到: 洞所在的分支里, 那个信号要么不被消费
    // (例如 S/B 的 rf_wsel —— rf_we=0, 写回被门控), 要么被同分支给的别的信号
    // 排除 (例如 LUI/JAL 的 alu_op —— rf_wsel 是 SEXT/PC4, ALU 结果不进写回)。
    // 合法指令语义不变。
    //
    // dram_sel 缺省取 LB 而不是 LW: LB 让 ex_wsize_word/ex_wsize_half 都为 0,
    // 于是 ex_addr_bad 连 ex_alu_c 都不看 —— 那些分支本来就不访存, 少一份
    // "非访存指令的地址"进异常判据。**不要**改成 SW/SH。
    // -----------------------------------------------------------------------
    sext_op  = `Sext_I;
    npc_op   = `NPC_SEL_NEXT;
    alu_op   = `ALU_ADD;
    alua_sel = `ALUA_SEL_RD1;
    alub_sel = `ALUB_SEL_RD2;
    rf_wsel  = `RF_WSEL_ALUC;
    dram_sel = `DRAM_SEL_LB;
    rf_we    = 1'b0;
    ram_we   = 1'b0;
    is_muldiv = 1'b0;
    case (opcode)
        `OPCODE_R: begin
            npc_op = `NPC_SEL_NEXT;
            alua_sel = `ALUA_SEL_RD1;
            alub_sel = `ALUB_SEL_RD2;
            rf_wsel = `RF_WSEL_ALUC;
            rf_we = 1;
            ram_we = 0;
            is_muldiv = 0;

            // 检查是否是RV32M指令
            if (funct7 == `FUNCT7_MULDIV) begin
                is_muldiv = 1;
                case (funct3)
                    `FUNCT3_MUL: alu_op = `ALU_MUL;
                    `FUNCT3_MULH: alu_op = `ALU_MULH;
                    `FUNCT3_MULHSU: alu_op = `ALU_MULHSU;
                    `FUNCT3_MULHU: alu_op = `ALU_MULHU;
                    `FUNCT3_DIV: alu_op = `ALU_DIV;
                    `FUNCT3_DIVU: alu_op = `ALU_DIVU;
                    `FUNCT3_REM: alu_op = `ALU_REM;
                    `FUNCT3_REMU: alu_op = `ALU_REMU;
                    default: begin
                        alu_op = `ALU_ADD;
                        is_muldiv = 0;
                    end
                endcase
            end else begin
                // 原有RV32I指令
                case (funct3)
                    `FUNCT3_ADD_SUB: begin
                        case (funct7[5])
                            1'b0: alu_op = `ALU_ADD;
                            1'b1: alu_op = `ALU_SUB;
                        endcase
                    end
                    `FUNCT3_AND: begin
                        alu_op = `ALU_AND;
                    end
                    `FUNCT3_OR: begin
                        alu_op = `ALU_OR;
                    end
                    `FUNCT3_XOR: begin
                        alu_op = `ALU_XOR;
                    end
                    `FUNCT3_SLL: begin
                        alu_op = `ALU_SLL;
                    end
                    `FUNCT3_SHIFT_RIGHT: begin
                         case (funct7[5])
                            1'b0: alu_op = `ALU_SRL;
                            1'b1: alu_op = `ALU_SRA;
                        endcase
                    end
                    `FUNCT3_SLT: begin
                        alu_op = `ALU_SLT;
                    end
                    `FUNCT3_SLTU: begin
                        alu_op = `ALU_SLTU;
                    end
                    // 不可达 (8 个 funct3 在上面全枚举了), 但空 default 在
                    // "这个块已经全赋值"之后是个坑 —— 补上, 别留给下一个读者。
                    default begin
                        alu_op = `ALU_ADD;
                    end
                endcase
            end
        end
        `OPCODE_I_REG: begin
            sext_op = `Sext_I;
            npc_op = `NPC_SEL_NEXT;
            alua_sel = `ALUA_SEL_RD1;
            alub_sel = `ALUB_SEL_SEXT;
            rf_wsel = `RF_WSEL_ALUC;
            rf_we = 1;
            ram_we = 0;
            is_muldiv = 0;
            case (funct3)
                `FUNCT3_ADDI: begin
                    alu_op = `ALU_ADD;
                end
                `FUNCT3_ANDI: begin
                    alu_op = `ALU_AND;
                end
                `FUNCT3_ORI: begin
                    alu_op = `ALU_OR;
                end
                `FUNCT3_XORI: begin
                    alu_op = `ALU_XOR;
                end
                `FUNCT3_SLLI: begin
                    alu_op = `ALU_SLL;
                end
                `FUNCT3_SHIFT_RIGHT: begin
                    case (funct7[5]) 
                        1'b0: alu_op = `ALU_SRL;
                        1'b1: alu_op = `ALU_SRA;
                    endcase
                end
                `FUNCT3_SLTI: begin
                    alu_op = `ALU_SLT;
                end
                `FUNCT3_SLTIU: begin
                    alu_op = `ALU_SLTU;
                end
            endcase
        end
        `OPCODE_I_LOAD: begin
            sext_op = `Sext_I;
            npc_op = `NPC_SEL_NEXT;
            alua_sel = `ALUA_SEL_RD1;
            alub_sel = `ALUB_SEL_SEXT;
            rf_wsel = `RF_WSEL_DRAM;
            rf_we = 1;
            ram_we = 0;
            is_muldiv = 0;
            alu_op = `ALU_ADD;
            case (funct3)
                `FUNCT3_LB: dram_sel = `DRAM_SEL_LB;
                `FUNCT3_LBU: dram_sel = `DRAM_SEL_LBU;
                `FUNCT3_LH: dram_sel = `DRAM_SEL_LH;
                `FUNCT3_LHU: dram_sel = `DRAM_SEL_LHU;
                `FUNCT3_LW: dram_sel = `DRAM_SEL_LW;
                default: dram_sel = 0;
            endcase
        end
        `OPCODE_JALR: begin
            sext_op = `Sext_I;
            npc_op = `NPC_SEL_ALU;
            alua_sel = `ALUA_SEL_RD1;
            alub_sel = `ALUB_SEL_SEXT;
            rf_wsel = `RF_WSEL_PC4;
            rf_we = 1;
            ram_we = 0;
            is_muldiv = 0;
            alu_op = `ALU_ADD;
        end
        `OPCODE_S: begin
            sext_op = `Sext_S;
            npc_op = `NPC_SEL_NEXT;
            alua_sel = `ALUA_SEL_RD1;
            alub_sel = `ALUB_SEL_SEXT;
            rf_we = 0;
            ram_we = 1;
            is_muldiv = 0;
            alu_op = `ALU_ADD;
            case (funct3)
                `FUNCT3_SB: dram_sel = `DRAM_SEL_SB;
                `FUNCT3_SH: dram_sel = `DRAM_SEL_SH;
                `FUNCT3_SW: dram_sel = `DRAM_SEL_SW;
                // ⚠️ 这里是 `0` (= DRAM_SEL_LW, 一个**读**选择子) 而 ram_we=1。
                //    配合 MEM.v 的 `wdata_out` 原先也是 latch, 非法 store funct3 时
                //    实际写进内存的是**上一笔 store 的残留数据** —— 历史相关的垃圾。
                //    改成 SW 后这个角落 = "按 SW 写 wdin", 确定且与 MEM.v 的
                //    default 臂一致。合法 funct3 走不到这里。
                default: dram_sel = `DRAM_SEL_SW;
            endcase
        end
        `OPCODE_B: begin
            sext_op = `Sext_B;
            alua_sel = `ALUA_SEL_RD1;
            alub_sel = `ALUB_SEL_RD2;
            npc_op = `NPC_SEL_BRANCH;
            rf_we = 0;
            ram_we = 0;
            is_muldiv = 0;
            case (funct3)
                `FUNCT3_BEQ: begin
                    alu_op = `ALU_BEQ;
                end
                `FUNCT3_BNE: begin
                    alu_op = `ALU_BNE;
                end
                `FUNCT3_BLT: begin
                    alu_op = `ALU_BLT;
                end
                `FUNCT3_BLTU: begin
                    alu_op = `ALU_BLTU;
                end
                `FUNCT3_BGE: begin
                    alu_op = `ALU_BGE;
                end
                `FUNCT3_BGEU: begin
                    alu_op = `ALU_BGEU;
                end
                default: begin
                    alu_op = 0;
                end
            endcase
        end
        `OPCODE_LUI: begin
            //?????ALU?DRAM
            sext_op = `Sext_U;
            npc_op = `NPC_SEL_NEXT;
            rf_wsel = `RF_WSEL_SEXT;
            rf_we = 1;
            ram_we = 0;
            is_muldiv = 0;
        end
        `OPCODE_AUIPC: begin
            sext_op = `Sext_U;
            npc_op = `NPC_SEL_NEXT;
            alua_sel = `ALUA_SEL_PC;
            alub_sel = `ALUB_SEL_SEXT;
            alu_op = `ALU_ADD;
            rf_wsel = `RF_WSEL_ALUC;
            rf_we = 1;
            ram_we = 0;
            is_muldiv = 0;
        end
        `OPCODE_JAL: begin
            //?????ALU
            sext_op = `Sext_J;
            npc_op = `NPC_SEL_JAL;
            rf_wsel = `RF_WSEL_PC4;
            rf_we = 1;
            ram_we = 0;
            is_muldiv = 0;
        end
        `OPCODE_SYSTEM: begin
            // CSR 指令: 把旧的 CSR 值经 ALU(A 口选 CSR 读数据, B 口给 0)
            // 原样送到 rd; ecall/ebreak/mret 不写寄存器.
            // csrrwi 系列的 uimm5 走 B 口的 sext 通路(Sext_Z, 取 inst[19:15]).
            sext_op   = `Sext_Z;
            npc_op    = `NPC_SEL_NEXT;
            alu_op    = `ALU_ADD;
            // A 口在 EX 级被 mycpu.v 换成 CSR 旧值(见 ex_A_final), B 口给 0,
            // 于是 ALU 结果就是 CSR 旧值, 原样写回 rd.
            //
            // 历史 (2026-09-28 更正): 这里原先写着"【不能】把 CSR 读数据走 ID 级
            // 的 A 通路, 因为在 ID 级读会拿到上一拍那条指令的地址对应的值"。
            // 那句话说的是**用 EX 锁存的地址去 ID 级读**, 确实不行; 而现在
            // mycpu.v 是用**本条指令自己的** id_csr_addr 在 ID 级读, 再随 ID_EX
            // 锁一拍 —— 地址是对的, 只是读的时机提前了一拍 (FPGA 关键路径的链头
            // 就是那条 16:1 读 mux, 见 mycpu.v 的 ex_A_final 注释)。
            // 真正**不能**做的是把 CSR 值塞进 ID 级的 A 通路: A 口是转发通路,
            // Forward_A_en 会把 ex_A/ex_rD1 一起覆盖掉。所以走独立的
            // ex_csr_rdata 字段。
            //
            // CSR 的源操作数也不是 rs2: 对 csrrw/rs/rc 它是 rs1(inst[19:15]),
            // 而 inst[24:20] 属于 csr 域 —— 源统一在 mycpu.v 用
            // ex_rD1(已转发)/ex_sext(uimm5) 选取.
            alua_sel  = `ALUA_SEL_RD1;
            alub_sel  = `ALUB_SEL_ZERO;
            rf_wsel   = `RF_WSEL_ALUC;
            rf_we     = (csr_op != `CSR_OP_NONE);
            ram_we    = 0;
            is_muldiv = 0;
            dram_sel  = 0;
        end
        default: begin
            sext_op      = 0;
            npc_op       = 0;
            alu_op       = 0;
            alua_sel     = 0;
            alub_sel     = 0;
            rf_wsel      = 0;
            dram_sel     = 0;
            rf_we        = 0;
            ram_we       = 0;
            is_muldiv    = 0;
        end
    endcase
end

endmodule

