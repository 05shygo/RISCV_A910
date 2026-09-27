// Annotate this macro before synthesis
 `define RUN_TRACE

// TODO: ????????
//Regfile??????
`define RegAddrBus 4:0
//Regfile????????
`define RegBus 31:0
//?????
`define RegNum 32

`define RstEnable 1
`define RstDisable 0

`define Forward_OP_WIDTH 2
//?????????????????
`define Sext_OP_WDITH 3
`define Sext_I 0
`define Sext_S 1
`define Sext_B 2
`define Sext_U 3
`define Sext_J 4

`define NPC_SEL_WIDTH 2
`define NPC_SEL_NEXT 0
`define NPC_SEL_BRANCH 1
`define NPC_SEL_ALU 2
`define NPC_SEL_JAL 3

`define ALU_OP_WIDTH 5
`define ALUA_SEL_WIDTH 2
`define ALUA_SEL_RD1 0
`define ALUA_SEL_PC 1
`define ALUB_SEL_WIDTH 3
`define ALUB_SEL_RD2 0
`define ALUB_SEL_SEXT 1
`define ALU_ADD 0
`define ALU_SUB 1
`define ALU_AND 2
`define ALU_OR 3
`define ALU_XOR 4
`define ALU_SLL 5
`define ALU_SRL 6
`define ALU_SRA 7
`define ALU_SLT 8
`define ALU_SLTU 9
`define ALU_BEQ 10
`define ALU_BNE 11
`define ALU_BLT 12
`define ALU_BLTU 13
`define ALU_BGE 14
`define ALU_BGEU 15
// RV32M Extension
`define ALU_MUL 16
`define ALU_MULH 17
`define ALU_MULHSU 18
`define ALU_MULHU 19
`define ALU_DIV 20
`define ALU_DIVU 21
`define ALU_REM 22
`define ALU_REMU 23

// ---- 乘除法单元 (MUL_DIV) 的请求操作码 req_op[3:0] ----
// 单元内部只认这套编码, 不认 ALU_OP: 这样接口与核里 ALU 的算子编码解耦,
// P2 换乱序核时只要把 tag/仲裁接上, 单元一行不用改。
// 与 ALU_OP 的对应关系是**刻意**选的: ALU_MUL..ALU_REMU = 16..23, 二进制是
// 1_0000..1_0111, 低 3 位正好是 0..7 —— 所以 mycpu.v 直接给
// `{1'b0, ex_alu_op[2:0]}` 就是下面这张表 (见 mycpu.v 例化处的注释)。
`define MD_OP_MUL    4'd0
`define MD_OP_MULH   4'd1
`define MD_OP_MULHSU 4'd2
`define MD_OP_MULHU  4'd3
`define MD_OP_DIV    4'd4
`define MD_OP_DIVU   4'd5
`define MD_OP_REM    4'd6
`define MD_OP_REMU   4'd7

// MAC 累加口 (doc §4.6): 接口第一天就留, P1 接 0/`MD_ACC_NONE`
`define MD_ACC_NONE 2'b00
`define MD_ACC_ADD  2'b01
`define MD_ACC_SUB  2'b10

`define RF_WSEL_WIDTH 2
`define RF_WSEL_ALUC 0
`define RF_WSEL_DRAM 1
`define RF_WSEL_PC4 2
`define RF_WSEL_SEXT 3

`define DRAM_SEL_WIDTH 3
`define DRAM_SEL_LW 0
`define DRAM_SEL_LH 1
`define DRAM_SEL_LB 2
`define DRAM_SEL_LBU 3
`define DRAM_SEL_LHU 4
`define DRAM_SEL_SW 5
`define DRAM_SEL_SB 6
`define DRAM_SEL_SH 7

`define OPCODE_R 7'b0110011
`define OPCODE_ADD 7'b0110011
`define OPCODE_SUB 7'b0110011
`define OPCODE_AND 7'b0110011
`define OPCODE_OR 7'b0110011
`define OPCODE_XOR 7'b0110011
`define OPCODE_SLL 7'b0110011
`define OPCODE_SRL 7'b0110011
`define OPCODE_SRA 7'b0110011
`define OPCODE_SLT 7'b0110011
`define OPCODE_SLTU 7'b0110011

`define OPCODE_I_REG 7'b0010011
`define OPCODE_ADDI 7'b0010011
`define OPCODE_ANDI 7'b0010011
`define OPCODE_ORI 7'b0010011
`define OPCODE_XORI 7'b0010011
`define OPCODE_SLLI 7'b0010011
`define OPCODE_SRLI 7'b0010011
`define OPCODE_SRAI 7'b0010011
`define OPCODE_SLTI 7'b0010011
`define OPCODE_SLTIU 7'b0010011

`define OPCODE_I_LOAD 7'b0000011
`define OPCODE_LB 7'b0000011
`define OPCODE_LBU 7'b0000011
`define OPCODE_LH 7'b0000011
`define OPCODE_LHU 7'b0000011
`define OPCODE_LW 7'b0000011

`define OPCODE_JALR 7'b1100111

`define OPCODE_S 7'b0100011
`define OPCODE_SB 7'b0100011
`define OPCODE_SH 7'b0100011
`define OPCODE_SW 7'b0100011

`define OPCODE_B 7'b1100011
`define OPCODE_BEQ 7'b1100011
`define OPCODE_BNE 7'b1100011
`define OPCODE_BLT 7'b1100011
`define OPCODE_BLTU 7'b1100011
`define OPCODE_BGE 7'b1100011
`define OPCODE_BGEU 7'b1100011

`define OPCODE_LUI 7'b0110111
`define OPCODE_AUIPC 7'b0010111
`define OPCODE_JAL 7'b1101111

`define FUNCT3_ADD_SUB 3'b000
`define FUNCT3_AND 	3'b111
`define FUNCT3_OR 	    3'b110
`define FUNCT3_XOR 	3'b100
`define FUNCT3_SLL 	3'b001
`define FUNCT3_SHIFT_RIGHT 3'b101
`define FUNCT3_SLT 	3'b010
`define FUNCT3_SLTU	3'b011
`define FUNCT3_ADDI	3'b000
`define FUNCT3_ANDI	3'b111
`define FUNCT3_ORI 	3'b110
`define FUNCT3_XORI	3'b100
`define FUNCT3_SLLI	3'b001
`define FUNCT3_SLTI	3'b010
`define FUNCT3_SLTIU	3'b011
`define FUNCT3_LB 	    3'b000
`define FUNCT3_LBU  	3'b100
`define FUNCT3_LH	    3'b001
`define FUNCT3_LHU  	3'b101
`define FUNCT3_LW	    3'b010
`define FUNCT3_JALR	3'b000
`define FUNCT3_SB	    3'b000
`define FUNCT3_SH	    3'b001
`define FUNCT3_SW	    3'b010
`define FUNCT3_BEQ	    3'b000
`define FUNCT3_BNE	    3'b001
`define FUNCT3_BLT	    3'b100
`define FUNCT3_BLTU	3'b110
`define FUNCT3_BGE	    3'b101
`define FUNCT3_BGEU	3'b111
//`define FUNCT3_LUI	-
//`define FUNCT3_AUIPC	-
//`define FUNCT3_JAL	-

`define FUNCT7_ADD  	7'b0000000
`define FUNCT7_SUB 	7'b0100000
`define FUNCT7_AND 	7'b0000000
`define FUNCT7_OR 	    7'b0000000
`define FUNCT7_XOR 	7'b0000000
`define FUNCT7_SLL 	7'b0000000
`define FUNCT7_SRL 	7'b0000000
`define FUNCT7_SRA 	7'b0100000
`define FUNCT7_SLT 	7'b0000000
`define FUNCT7_SLTU	7'b0000000
// RV32M Extension
`define FUNCT7_MULDIV   7'b0000001
`define FUNCT3_MUL      3'b000
`define FUNCT3_MULH     3'b001
`define FUNCT3_MULHSU   3'b010
`define FUNCT3_MULHU    3'b011
`define FUNCT3_DIV      3'b100
`define FUNCT3_DIVU     3'b101
`define FUNCT3_REM      3'b110
`define FUNCT3_REMU     3'b111
//`define FUNCT7_ADDI	
//`define FUNCT7_ANDI	
//`define FUNCT7_ORI 	
//`define FUNCT7_XORI	
`define FUNCT7_SLLI	7'b0000000
`define FUNCT7_SRLI	7'b0000000
`define FUNCT7_SRAI	7'b0100000
//`define FUNCT7_SLTI	
//`define FUNCT7_SLTIU	
//`define FUNCT7_LB 	
//`define FUNCT7_LBU	
//`define FUNCT7_LH	
//`define FUNCT7_LHU	
//`define FUNCT7_LW	
//`define FUNCT7_JALR	
//`define FUNCT7_SB	
//`define FUNCT7_SH	
//`define FUNCT7_SW	
//`define FUNCT7_BEQ	
//`define FUNCT7_BNE	
//`define FUNCT7_BLT	
//`define FUNCT7_BLTU	
//`define FUNCT7_BGE	
//`define FUNCT7_BGEU	
//`define FUNCT7_LUI	
//`define FUNCT7_AUIPC	
//`define FUNCT7_JAL	

`define DIGIT 12'h000
`define TIMER 12'h040
`define LED 12'h060
`define SWITCH 12'h070
// ??I/O?????????
// ===================== 系统指令 / 陷阱 / CSR =====================

`define OPCODE_SYSTEM 7'b1110011
`define FUNCT3_PRIV   3'b000
`define FUNCT3_CSRRW  3'b001
`define FUNCT3_CSRRS  3'b010
`define FUNCT3_CSRRC  3'b011
`define FUNCT3_CSRRWI 3'b101
`define FUNCT3_CSRRSI 3'b110
`define FUNCT3_CSRRCI 3'b111

// funct3 == PRIV 时按整条指令精确匹配
`define INST_ECALL  32'h0000_0073
`define INST_EBREAK 32'h0010_0073
`define INST_MRET   32'h3020_0073

// CSR 子操作, 送到 EX 执行
`define CSR_OP_NONE 3'd0
`define CSR_OP_RW   3'd1   // csrrw / csrrwi : 直接写
`define CSR_OP_RS   3'd2   // csrrs / csrrsi : 新值 = 旧值 | 源
`define CSR_OP_RC   3'd3   // csrrc / csrrci : 新值 = 旧值 & ~源

`define CSR_MSTATUS   12'h300
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305
`define CSR_MSCRATCH  12'h340
`define CSR_MEPC      12'h341
`define CSR_MCAUSE    12'h342
`define CSR_MTVAL     12'h343
`define CSR_MIP       12'h344
`define CSR_MCYCLE    12'hB00
`define CSR_MINSTRET  12'hB02
`define CSR_MCYCLEH   12'hB80
`define CSR_MINSTRETH 12'hB82
`define CSR_CYCLE     12'hC00
`define CSR_INSTRET   12'hC02
`define CSR_CYCLEH    12'hC80
`define CSR_INSTRETH  12'hC82

// mstatus / mie / mip 用到的位号 (与规范一致: MIE=3, MPIE=7, MPP=[12:11], MTIE=MTIP=7)
`define MSTATUS_MIE_BIT   3
`define MSTATUS_MPIE_BIT  7
`define MIE_MTIE_BIT      7
`define MIP_MTIP_BIT      7

// ---------------------------------------------------------------------------
// 地址合法性判据 —— 必须只有这一处定义.
//
// perip_bridge.v 的 DRAM 写门控和 mycpu.v 的访问异常判据都用它.
// 以前两边各说各话: 桥把 >=64KB 的地址截断后照写 DRAM(静默别名到 DRAM[0]),
// 而 golden model 直接断言崩溃 —— 这正是"同一份地址映射被写了两遍"的后果.
//
// 数据侧: DRAM 只有低 64KB, 其余合法地址只有三个【已实现】的外设区间.
// 取指侧: IROM 也只有 64KB, 别的地址一律 instruction access fault.
// ---------------------------------------------------------------------------
`define ADDR_IN_MAP(a) ( ((a) <= 32'h0000_FFFF)                            \
                       || ((a) >= 32'h8000_0000 && (a) <= 32'h8000_0007) \
                       || ((a) >= 32'hFFFF_F000 && (a) <= 32'hFFFF_F003) \
                       || ((a) >= 32'hFFFF_F040 && (a) <= 32'hFFFF_F04F) )
`define INST_ADDR_OK(a)  ((a) <= 32'h0000_FFFF)

// 异常 cause (mcause[30:0]), 与规范编号一致
`define EXC_INST_MISALIGNED  4'd0
`define EXC_INST_ACCESS      4'd1
`define EXC_ILLEGAL_INST     4'd2
`define EXC_BREAKPOINT       4'd3
`define EXC_LOAD_MISALIGNED  4'd4
`define EXC_LOAD_ACCESS      4'd5
`define EXC_STORE_MISALIGNED 4'd6
`define EXC_STORE_ACCESS     4'd7
`define EXC_ECALL_M          4'd11
// 中断 mcause = {1'b1, 31'd7}
`define INTR_MTIP_CAUSE  32'h8000_0007

`define ALUB_SEL_ZERO 3'd2
`define Sext_Z        5     // csrrwi 系列的 5 位零扩展立即数

`define PERI_ADDR_DIG   32'hFFFF_F000
`define PERI_ADDR_TIMER 32'hFFFF_F040
`define PERI_ADDR_LED   32'hFFFF_F060
`define PERI_ADDR_SW    32'hFFFF_F070
`define PERI_ADDR_BTN   32'hFFFF_F078

