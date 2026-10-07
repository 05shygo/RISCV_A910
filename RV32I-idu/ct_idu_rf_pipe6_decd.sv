

module ct_idu_rf_pipe6_br_decd (
  input  logic [31:0]  pipe6_decd_opcode,
  output logic [7:0]   pipe6_decd_br_sel,   // 扩展为 8 位独热码以容纳 JAL/JALR
  output logic [31:0]  pipe6_decd_br_imm    // 32 位跳转/分支立即数输出
);

//==========================================================
//              独热码 分支/跳转 运算类型编码
//==========================================================
// 每一位代表一种操作，只有 1 位为 1
localparam logic [7:0] BR_BEQ  = 8'd1 << 0;   // BEQ  (相等跳转)
localparam logic [7:0] BR_BNE  = 8'd1 << 1;   // BNE  (不相等跳转)
localparam logic [7:0] BR_BLT  = 8'd1 << 2;   // BLT  (有符号小于跳转)
localparam logic [7:0] BR_BGE  = 8'd1 << 3;   // BGE  (有符号大于等于跳转)
localparam logic [7:0] BR_BLTU = 8'd1 << 4;   // BLTU (无符号小于跳转)
localparam logic [7:0] BR_BGEU = 8'd1 << 5;   // BGEU (无符号大于等于跳转)
localparam logic [7:0] BR_JAL  = 8'd1 << 6;   // JAL  (直接跳转并链接)
localparam logic [7:0] BR_JALR = 8'd1 << 7;   // JALR (寄存器间接跳转并链接)

//==========================================================
//                      字段提取
//==========================================================
logic [6:0] opcode;
logic [2:0] funct3;

assign opcode = pipe6_decd_opcode[6:0];
assign funct3 = pipe6_decd_opcode[14:12];

//==========================================================
//                      译码逻辑
//==========================================================
always_comb begin
  // 默认值初始化，防止生成 Latch
  pipe6_decd_br_sel = 8'b00000000;
  pipe6_decd_br_imm = 32'd0;

  case (opcode)
    // 1. B型指令：分支 (BRANCH)
    7'b1100011: begin
      case (funct3)
        3'b000: pipe6_decd_br_sel = BR_BEQ;     // BEQ
        3'b001: pipe6_decd_br_sel = BR_BNE;     // BNE
        3'b100: pipe6_decd_br_sel = BR_BLT;     // BLT
        3'b101: pipe6_decd_br_sel = BR_BGE;     // BGE
        3'b110: pipe6_decd_br_sel = BR_BLTU;    // BLTU
        3'b111: pipe6_decd_br_sel = BR_BGEU;    // BGEU
        default: pipe6_decd_br_sel = 8'b00000000; // 非法分支指令
      endcase

      // B 型指令立即数拼接与符号扩展
      // 格式：{{20{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0}
      pipe6_decd_br_imm = {{19{pipe6_decd_opcode[31]}}, // 注意这里改为 19 位，使总位宽保持 32
                           pipe6_decd_opcode[31],
                           pipe6_decd_opcode[7],
                           pipe6_decd_opcode[30:25],
                           pipe6_decd_opcode[11:8],
                           1'b0};
    end

    // 2. J型指令：JAL
    7'b1101111: begin
      pipe6_decd_br_sel = BR_JAL;
      
      // J 型指令立即数拼接与符号扩展
      // 格式：{{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}
      pipe6_decd_br_imm = {{11{pipe6_decd_opcode[31]}},
                           pipe6_decd_opcode[31],
                           pipe6_decd_opcode[19:12],
                           pipe6_decd_opcode[20],
                           pipe6_decd_opcode[30:21],
                           1'b0};
    end

    // 3. I型指令：JALR (要求 funct3 == 3'b000)
    7'b1100111: begin
      if (funct3 == 3'b000) begin
        pipe6_decd_br_sel = BR_JALR;
        
        // I 型指令立即数拼接与符号扩展
        // 格式：{{20{inst[31]}}, inst[31:20]}
        pipe6_decd_br_imm = {{20{pipe6_decd_opcode[31]}},
                             pipe6_decd_opcode[31:20]};
      end else begin
        pipe6_decd_br_sel = 8'b00000000; // 非法 JALR 指令 (funct3 非 000)
        pipe6_decd_br_imm = 32'd0;
      end
    end

    default: begin
      pipe6_decd_br_sel = 8'b00000000;
      pipe6_decd_br_imm = 32'd0;
    end
  endcase
end

endmodule