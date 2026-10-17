`timescale 1ns / 1ps

// ===========================================================================
// tb_ifu3_predcheck — PredChecker 定向用例
//
// 覆盖: JAL 漏预测/target 错、ret 的 RAS 修正、假 taken、非 CFI 假 taken、
//       更早的 always-taken JAL、cond/非 ret JALR 不修、pc_ofs、pop_push、
//       dec_action/dec_link。
// ===========================================================================
module tb_ifu3_predcheck;

reg  [127:0] line;
reg  [ 31:0] line_pc;
reg  [  1:0] pc_ofs;
reg          pred_taken;
reg  [  1:0] pred_slot;
reg  [ 31:0] pred_target;
reg  [  3:0] ras_top_vld;
reg  [127:0] ras_top;

wire [  7:0] dec_action;
wire [127:0] dec_link;
wire         corr_valid;
wire         corr_taken;
wire [  1:0] corr_slot;
wire [ 31:0] corr_target;
wire [  1:0] corr_end_slot;

rv32ifu3_predcheck dut (
    .line         (line),
    .line_pc      (line_pc),
    .pc_ofs       (pc_ofs),
    .pred_taken   (pred_taken),
    .pred_slot    (pred_slot),
    .pred_target  (pred_target),
    .ras_top_vld  (ras_top_vld),
    .ras_top      (ras_top),
    .dec_action   (dec_action),
    .dec_link     (dec_link),
    .corr_valid   (corr_valid),
    .corr_taken   (corr_taken),
    .corr_slot    (corr_slot),
    .corr_target  (corr_target),
    .corr_end_slot(corr_end_slot)
);

localparam [31:0] NOP   = 32'h00000013;   // addi x0,x0,0
localparam [31:0] ADDI1 = 32'h00100093;   // addi x1,x0,1
localparam [31:0] JAL1_8  = 32'h008000ef; // jal x1, +8
localparam [31:0] JAL5_8  = 32'h008002ef; // jal x5, +8
localparam [31:0] JAL0_8  = 32'h0080006f; // jal x0, +8
localparam [31:0] RET     = 32'h00008067; // jalr x0,0(x1)
localparam [31:0] RET5    = 32'h00028067; // jalr x0,0(x5)
localparam [31:0] PP      = 32'h000082e7; // jalr x5,0(x1)  pop_push
localparam [31:0] CALL    = 32'h000100e7; // jalr x1,0(x2)  call
localparam [31:0] JALR6   = 32'h00030067; // jalr x0,0(x6)  non-ret
localparam [31:0] BEQ8    = 32'h00208463; // beq x1,x2,+8
localparam [31:0] BNE8    = 32'h00209463; // bne x1,x2,+8

integer errs = 0;

task automatic chk(input string name,
                   input [1:0] exp_act0, exp_act1, exp_act2, exp_act3,
                   input       exp_valid, exp_taken,
                   input [1:0] exp_slot,
                   input [31:0] exp_target,
                   input [1:0] exp_end);
    integer i;
    reg [1:0] ea;
    begin
        #1;
        if (corr_valid !== exp_valid) begin
            errs = errs + 1;
            $display("[PRED-TB] FAIL %s: corr_valid=%b exp=%b", name, corr_valid, exp_valid);
        end
        if (exp_valid) begin
            if (corr_taken !== exp_taken) begin
                errs = errs + 1;
                $display("[PRED-TB] FAIL %s: corr_taken=%b exp=%b", name, corr_taken, exp_taken);
            end
            if (corr_slot !== exp_slot) begin
                errs = errs + 1;
                $display("[PRED-TB] FAIL %s: corr_slot=%0d exp=%0d", name, corr_slot, exp_slot);
            end
            if (corr_target !== exp_target) begin
                errs = errs + 1;
                $display("[PRED-TB] FAIL %s: corr_target=%h exp=%h", name, corr_target, exp_target);
            end
            if (corr_end_slot !== exp_end) begin
                errs = errs + 1;
                $display("[PRED-TB] FAIL %s: corr_end=%0d exp=%0d", name, corr_end_slot, exp_end);
            end
        end
        // dec_action / dec_link
        for (i = 0; i < 4; i = i + 1) begin
            ea = (i == 0) ? exp_act0 : (i == 1) ? exp_act1 : (i == 2) ? exp_act2 : exp_act3;
            if (dec_action[i*2 +: 2] !== ea) begin
                errs = errs + 1;
                $display("[PRED-TB] FAIL %s: action[%0d]=%0d exp=%0d", name, i,
                         dec_action[i*2 +: 2], ea);
            end
            if (dec_link[i*32 +: 32] !== (line_pc + i*4 + 4)) begin
                errs = errs + 1;
                $display("[PRED-TB] FAIL %s: link[%0d]=%h exp=%h", name, i,
                         dec_link[i*32 +: 32], line_pc + i*4 + 4);
            end
        end
    end
endtask

task automatic set_line(input [31:0] w0, w1, w2, w3);
    begin
        line = {w3, w2, w1, w0};
    end
endtask

localparam [31:0] PC = 32'h0000_1000;

initial begin
    line_pc = PC;
    pc_ofs = 0;
    pred_taken = 0; pred_slot = 0; pred_target = 0;
    ras_top_vld = 0; ras_top = 0;

    // 1) JAL 在 slot1, 未预测 taken -> 修到 slot1 target
    set_line(NOP, JAL1_8, NOP, NOP);
    pred_taken = 0;
    chk("jal-not-taken", 0, 1, 0, 0, 1, 1, 1, PC+4+8, 1);

    // 2) 假 taken 在 slot2 (非 CFI) -> 整块 fall-through
    set_line(NOP, ADDI1, NOP, NOP);
    pred_taken = 1; pred_slot = 2; pred_target = 32'hDEAD_0000;
    chk("false-taken", 0, 0, 0, 0, 1, 0, 3, PC+16, 3);

    // 3) ret 未预测 taken, RAS 有效 -> 修到 RAS top
    set_line(RET, NOP, NOP, NOP);
    pred_taken = 0;
    ras_top_vld = 4'b0001;
    ras_top[31:0] = 32'hA000_0000;
    chk("ret-ras", 2, 0, 0, 0, 1, 1, 0, 32'hA000_0000, 0);

    // 4) ret 未预测 taken, RAS 无效 -> 不修
    ras_top_vld = 4'b0000;
    chk("ret-no-ras", 2, 0, 0, 0, 0, 0, 0, 0, 0);

    // 5) ret 预测 taken, target 错, RAS 有效 -> 修 target
    pred_taken = 1; pred_slot = 0; pred_target = 32'hB000_0000;
    ras_top_vld = 4'b0001;
    ras_top[31:0] = 32'hC000_0000;
    chk("ret-wrong-target", 2, 0, 0, 0, 1, 1, 0, 32'hC000_0000, 0);

    // 6) 更早的 JAL 在 slot1, 预测 taken 在 slot2 -> 修到 slot1
    set_line(NOP, JAL1_8, NOP, NOP);
    pred_taken = 1; pred_slot = 2; pred_target = 32'hD000_0000;
    ras_top_vld = 0;
    chk("early-jal", 0, 1, 0, 0, 1, 1, 1, PC+4+8, 1);

    // 7) cond 在前, JAL 在后, 未预测 taken -> 不修
    set_line(BEQ8, JAL1_8, NOP, NOP);
    pred_taken = 0;
    chk("cond-first", 0, 1, 0, 0, 0, 0, 0, 0, 0);

    // 8) cond 预测 taken -> 不修
    pred_taken = 1; pred_slot = 0; pred_target = 32'hE000_0000;
    chk("cond-taken", 0, 1, 0, 0, 0, 1, 0, 32'hE000_0000, 0);

    // 9) 非 ret JALR 在前, 未预测 taken -> 不修
    set_line(NOP, JALR6, NOP, NOP);
    pred_taken = 0;
    chk("jalr-nonret", 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // 10) pc_ofs=2, slot2 的 JAL 未预测 -> 修到 slot2
    set_line(JAL1_8, RET, JAL5_8, NOP);
    pc_ofs = 2; pred_taken = 0;
    ras_top_vld = 0;
    chk("pcofs2-jal", 1, 2, 1, 0, 1, 1, 2, PC+8+8, 2);
    pc_ofs = 0;

    // 11) JAL 预测 taken 且 target 对 -> 不修
    set_line(NOP, JAL1_8, NOP, NOP);
    pred_taken = 1; pred_slot = 1; pred_target = PC+4+8;
    chk("jal-correct", 0, 1, 0, 0, 0, 1, 1, PC+4+8, 1);

    // 12) pop_push -> action=3, ret target 用 RAS top
    set_line(PP, NOP, NOP, NOP);
    pred_taken = 0;
    ras_top_vld = 4'b0001;
    ras_top[31:0] = 32'hF000_0000;
    chk("pop-push", 3, 0, 0, 0, 1, 1, 0, 32'hF000_0000, 0);

    // 13) 假 taken 在非 CFI, 但更早有 JAL -> 规则 1 优先
    set_line(JAL1_8, ADDI1, NOP, NOP);
    pred_taken = 1; pred_slot = 1; pred_target = 32'hDEAD_0000;
    ras_top_vld = 0;
    chk("false-after-jal", 1, 0, 0, 0, 1, 1, 0, PC+8, 0);

    // 14) 假 taken 在非 CFI, 更早是 cond -> fall-through
    set_line(BEQ8, ADDI1, NOP, NOP);
    pred_taken = 1; pred_slot = 1; pred_target = 32'hDEAD_0000;
    chk("false-after-cond", 0, 0, 0, 0, 1, 0, 3, PC+16, 3);

    // 15) call (非 pop_push) action=1
    set_line(NOP, CALL, NOP, NOP);
    pred_taken = 0;
    chk("call-action", 0, 1, 0, 0, 0, 0, 0, 0, 0);

    // 16) BNE 不修
    set_line(BNE8, NOP, NOP, NOP);
    pred_taken = 0;
    chk("bne", 0, 0, 0, 0, 0, 0, 0, 0, 0);

    $display("");
    if (errs == 0) begin
        $display("[tb_ifu3_predcheck] PASS");
    end else begin
        $display("[tb_ifu3_predcheck] FAIL %0d errors", errs);
        $fatal(1);
    end
    $finish;
end

initial begin
    #1_000_000;
    $display("[tb_ifu3_predcheck] 致命: 超时");
    $fatal(1);
end

endmodule
