// ==============================================================================
// RV32IM Instruction Decoder
// Supports RV32I base ISA (except FENCE/SYSTEM) + M extension (multiply/divide)
// ==============================================================================

module ct_idu_id_decd (
    input  wire [31:0] inst,           // 32-bit instruction input

    // Source register 0
    output wire        src0_vld,       // Source 0 valid
    output wire [4:0]  src0_reg,       // Source 0 register number

    // Source register 1
    output wire        src1_vld,       // Source 1 valid
    output wire [4:0]  src1_reg,       // Source 1 register number

    // Destination register
    output wire        dst_vld,        // Destination valid
    output wire [4:0]  dst_reg,        // Destination register number
    output wire        dst_x0,         // Destination is x0

    // Instruction type (one-hot encoding)
    output wire [4:0]  inst_type,      // [4]:MUL [3]:DIV [2]:BR [1]:LSU [0]:ALU

    // Illegal instruction flag
    output wire        illegal         // Illegal instruction detected
);

// ==============================================================================
// Instruction field extraction
// ==============================================================================
wire [6:0] opcode = inst[6:0];
wire [2:0] funct3 = inst[14:12];
wire [6:0] funct7 = inst[31:25];

wire [4:0] rs1 = inst[19:15];
wire [4:0] rs2 = inst[24:20];
wire [4:0] rd  = inst[11:7];

// ==============================================================================
// Opcode decode
// ==============================================================================
wire op_lui    = (opcode == 7'b0110111);  // LUI
wire op_auipc  = (opcode == 7'b0010111);  // AUIPC
wire op_jal    = (opcode == 7'b1101111);  // JAL
wire op_jalr   = (opcode == 7'b1100111);  // JALR
wire op_branch = (opcode == 7'b1100011);  // BEQ, BNE, BLT, BGE, BLTU, BGEU
wire op_load   = (opcode == 7'b0000011);  // LB, LH, LW, LBU, LHU
wire op_store  = (opcode == 7'b0100011);  // SB, SH, SW
wire op_alui   = (opcode == 7'b0010011);  // ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
wire op_alur   = (opcode == 7'b0110011);  // ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
                                           // MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
wire op_fence  = (opcode == 7'b0001111);  // FENCE (excluded)
wire op_system = (opcode == 7'b1110011);  // ECALL, EBREAK, CSR* (excluded)

// ==============================================================================
// Detailed instruction validation
// ==============================================================================

// ALU R-type validation (funct7 check)
wire alur_valid = op_alur && (
    (funct3 == 3'b000 && (funct7 == 7'b0000000 || funct7 == 7'b0100000 || funct7 == 7'b0000001)) || // ADD/SUB/MUL
    (funct3 == 3'b001 && (funct7 == 7'b0000000 || funct7 == 7'b0000001)) || // SLL/MULH
    (funct3 == 3'b010 && (funct7 == 7'b0000000 || funct7 == 7'b0000001)) || // SLT/MULHSU
    (funct3 == 3'b011 && (funct7 == 7'b0000000 || funct7 == 7'b0000001)) || // SLTU/MULHU
    (funct3 == 3'b100 && (funct7 == 7'b0000000 || funct7 == 7'b0000001)) || // XOR/DIV
    (funct3 == 3'b101 && (funct7 == 7'b0000000 || funct7 == 7'b0100000 || funct7 == 7'b0000001)) || // SRL/SRA/DIVU
    (funct3 == 3'b110 && (funct7 == 7'b0000000 || funct7 == 7'b0000001)) || // OR/REM
    (funct3 == 3'b111 && (funct7 == 7'b0000000 || funct7 == 7'b0000001))    // AND/REMU
);

// ALU I-type shift validation (funct7 check for SLLI/SRLI/SRAI)
wire alui_shift_valid = op_alui && (
    (funct3 == 3'b001 && funct7 == 7'b0000000) || // SLLI
    (funct3 == 3'b101 && (funct7 == 7'b0000000 || funct7 == 7'b0100000)) // SRLI/SRAI
);

// ALU I-type non-shift (no funct7 constraint)
wire alui_non_shift = op_alui && (funct3 != 3'b001 && funct3 != 3'b101);

wire alui_valid = alui_non_shift || alui_shift_valid;

// JALR validation (funct3 must be 000)
wire jalr_valid = op_jalr && (funct3 == 3'b000);

// Branch validation (funct3 check)
wire branch_valid = op_branch && (
    funct3 == 3'b000 || // BEQ
    funct3 == 3'b001 || // BNE
    funct3 == 3'b100 || // BLT
    funct3 == 3'b101 || // BGE
    funct3 == 3'b110 || // BLTU
    funct3 == 3'b111    // BGEU
);

// Load validation (funct3 check)
wire load_valid = op_load && (
    funct3 == 3'b000 || // LB
    funct3 == 3'b001 || // LH
    funct3 == 3'b010 || // LW
    funct3 == 3'b100 || // LBU
    funct3 == 3'b101    // LHU
);

// Store validation (funct3 check)
wire store_valid = op_store && (
    funct3 == 3'b000 || // SB
    funct3 == 3'b001 || // SH
    funct3 == 3'b010    // SW
);

// M extension detection
wire m_ext = (funct7 == 7'b0000001);

// Multiply instructions (M extension)
wire is_mul  = op_alur && m_ext && (funct3 == 3'b000);  // MUL
wire is_mulh = op_alur && m_ext && (funct3 == 3'b001);  // MULH
wire is_mulhsu = op_alur && m_ext && (funct3 == 3'b010); // MULHSU
wire is_mulhu = op_alur && m_ext && (funct3 == 3'b011);  // MULHU
wire is_mul_any = is_mul || is_mulh || is_mulhsu || is_mulhu;

// Divide instructions (M extension)
wire is_div  = op_alur && m_ext && (funct3 == 3'b100);  // DIV
wire is_divu = op_alur && m_ext && (funct3 == 3'b101);  // DIVU
wire is_rem  = op_alur && m_ext && (funct3 == 3'b110);  // REM
wire is_remu = op_alur && m_ext && (funct3 == 3'b111);  // REMU
wire is_div_any = is_div || is_divu || is_rem || is_remu;

// Standard ALU operations (exclude M extension)
wire is_alu_r = op_alur && !m_ext;
wire is_alu = alui_valid || is_alu_r || op_lui || op_auipc;

// Valid instruction check
wire valid_inst = op_lui || op_auipc || op_jal || jalr_valid || branch_valid ||
                  load_valid || store_valid || alui_valid || alur_valid;

// Illegal instruction: not valid OR explicitly excluded (FENCE/SYSTEM)
assign illegal = !valid_inst || op_fence || op_system;

// ==============================================================================
// Source operand validity
// ==============================================================================
// rs1 is valid for: JALR, BRANCH, LOAD, STORE, ALU_I, ALU_R
assign src0_vld = (jalr_valid || branch_valid || load_valid || store_valid || alui_valid || alur_valid) && !illegal;
assign src0_reg = rs1;

// rs2 is valid for: BRANCH, STORE, ALU_R (including M extension)
assign src1_vld = (branch_valid || store_valid || alur_valid) && !illegal;
assign src1_reg = rs2;

// ==============================================================================
// Destination operand validity
// ==============================================================================
// rd is valid for: LUI, AUIPC, JAL, JALR, LOAD, ALU_I, ALU_R
assign dst_vld = (op_lui || op_auipc || op_jal || jalr_valid || load_valid || alui_valid || alur_valid) && !illegal;
assign dst_reg = rd;
assign dst_x0  = (rd == 5'b0);

// ==============================================================================
// Instruction type (one-hot encoding)
// ==============================================================================
// [0] ALU: basic ALU operations (not MUL/DIV)
assign inst_type[0] = is_alu && !illegal;

// [1] LSU: load/store unit operations
assign inst_type[1] = (load_valid || store_valid) && !illegal;

// [2] BRANCH: branch instructions (including JAL, JALR)
assign inst_type[2] = (branch_valid || op_jal || jalr_valid) && !illegal;

// [3] DIV: division/remainder operations
assign inst_type[3] = is_div_any && !illegal;

// [4] MUL: multiplication operations
assign inst_type[4] = is_mul_any && !illegal;

endmodule
