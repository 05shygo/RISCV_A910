`timescale 1ns / 1ps

//==========================================================
// tb_iu_alu_pipe —— IU_alu_pipe (IDU 的 AIQ 口 ↔ 老 ALU 的适配流水级) 的单元台
//==========================================================
// 【守什么】
// 这一级里三件事都可能静默出错:
//   1. **13 位独热 → alu_op 的编码转换** —— 写错一位就是"某条算子算错", 而整核里
//      只表现为 difftest 某条指令结果不对, 定位不到是编码表写错;
//   2. **LUI / AUIPC** —— 老 ALU 里根本没有这两条 (老核在 EX 用 mux 现拼),
//      漏了或把 AUIPC 写成 src0+src1 都是静默错;
//   3. **写回协议** —— `wb_preg_expand` 必须是 dst_preg 的独热 (PRF 拿它当写使能),
//      写错就是"写错格子"; `cmplt_vld` 漏报非法指令会让那条永远退不了休。
//
// 全组合逻辑 + 一级寄存器, 所以"发一条 → 下一拍查"就够。
//==========================================================
module tb_iu_alu_pipe;

  reg         clk = 0;
  reg         rst = 1;
  always #5 clk = ~clk;

  reg         flush = 0;
  reg         sel = 0;
  reg  [6:0]  iid = 0;
  reg  [5:0]  dst_preg = 0;
  reg  [31:0] src0 = 0, src1 = 0, pc = 0;
  reg  [12:0] rslt_sel = 13'd1;   // 默认 ADD
  reg         illegal = 0;

  wire        wb_vld;
  wire [31:0] wb_data;
  wire [63:0] wb_expand;
  wire [5:0]  wb_dupx;
  wire        wb_vld_dupx;
  wire        cmplt_vld;
  wire [6:0]  cmplt_iid;
  wire [31:0] o_result;

  // 13 位独热的位序 (照 ct_idu_rf_pipe0_decd.sv)
  localparam [12:0] S_ADD=13'd1<<0,  S_SUB=13'd1<<1,  S_SLL=13'd1<<2,
                    S_SLT=13'd1<<3,  S_SLTU=13'd1<<4, S_XOR=13'd1<<5,
                    S_SRL=13'd1<<6,  S_SRA=13'd1<<7,  S_OR=13'd1<<8,
                    S_AND=13'd1<<9,  S_LUI=13'd1<<10, S_AUIPC=13'd1<<11,
                    S_ILL=13'd1<<12;

  IU_alu_pipe u_dut (
    .cpu_clk(clk), .cpu_rst(rst), .idu_flush(flush),
    .idu_sel(sel), .idu_iid(iid), .idu_dst_preg(dst_preg),
    .idu_src0(src0), .idu_src1(src1), .idu_pc(pc),
    .idu_rslt_sel(rslt_sel), .idu_illegal(illegal),
    .wb_preg_vld(wb_vld), .wb_preg_data(wb_data), .wb_preg_expand(wb_expand),
    .wb_preg_dupx(wb_dupx), .wb_preg_vld_dupx(wb_vld_dupx),
    .cmplt_vld(cmplt_vld), .cmplt_iid(cmplt_iid),
    .o_alu_result(o_result)
  );

  integer errs = 0;
  integer nchk = 0;

  // 发一条并查结果: 期望 a_sel 拍之后 (即下一拍) 出现写回
  task automatic issue_and_check(
      input [12:0] s, input [31:0] a, input [31:0] b, input [31:0] exp_val,
      input [8*40-1:0] name
  );
    begin
      @(negedge clk);
      sel = 1'b1; iid = 7'h2A; dst_preg = 6'd17;
      src0 = a; src1 = b; pc = 32'h1000; rslt_sel = s; illegal = 1'b0;
      @(negedge clk);
      sel = 1'b0;
      nchk = nchk + 1;
      if (wb_vld !== 1'b1) begin
        errs = errs + 1; $display("  ❌ %0s: wb_preg_vld 没拉起来", name);
      end
      else if (wb_data !== exp_val) begin
        errs = errs + 1;
        $display("  ❌ %0s: 结果 %h 期望 %h (a=%h b=%h)", name, wb_data, exp_val, a, b);
      end
      else if (wb_expand !== (64'd1 << 6'd17)) begin
        errs = errs + 1; $display("  ❌ %0s: expand 不是 p17 的独热 (%h)", name, wb_expand);
      end
      else if (wb_dupx !== 6'd17 || wb_vld_dupx !== 1'b1) begin
        errs = errs + 1; $display("  ❌ %0s: 唤醒口不对 (dupx=%0d vld=%b)", name, wb_dupx, wb_vld_dupx);
      end
      else if (cmplt_vld !== 1'b1 || cmplt_iid !== 7'h2A) begin
        errs = errs + 1; $display("  ❌ %0s: 完成回报不对 (vld=%b iid=%h)", name, cmplt_vld, cmplt_iid);
      end
      else
        $display("  ✅ %0s → %h", name, wb_data);
      @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // 复位后不该有任何写回
    if (wb_vld !== 1'b0 || cmplt_vld !== 1'b0) begin
      errs = errs + 1; $display("  ❌ 复位后 wb_vld=%b cmplt_vld=%b 应为 0", wb_vld, cmplt_vld);
    end

    $display("---- 10 个真算子 ----");
    issue_and_check(S_ADD,   32'h0000_0007, 32'h0000_0003, 32'h0000_000A, "ADD    7+3");
    issue_and_check(S_SUB,   32'h0000_0007, 32'h0000_0003, 32'h0000_0004, "SUB    7-3");
    issue_and_check(S_SUB,   32'h0000_0003, 32'h0000_0007, 32'hFFFF_FFFC, "SUB    3-7 (负数)");
    issue_and_check(S_SLL,   32'h0000_0001, 32'h0000_0013, 32'h0008_0000, "SLL    1<<19 (取低5位)");
    issue_and_check(S_SLT,   32'hFFFF_FFFF, 32'h0000_0001, 32'h0000_0001, "SLT    -1<1 (有符号)");
    issue_and_check(S_SLTU,  32'hFFFF_FFFF, 32'h0000_0001, 32'h0000_0000, "SLTU   0xFFFFFFFF<1 (无符号)");
    issue_and_check(S_XOR,   32'hF0F0_F0F0, 32'h00FF_00FF, 32'hF00F_F00F, "XOR");
    issue_and_check(S_SRL,   32'h8000_0000, 32'h0000_0004, 32'h0800_0000, "SRL    逻辑右移");
    issue_and_check(S_SRA,   32'h8000_0000, 32'h0000_0004, 32'hF800_0000, "SRA    算术右移");
    issue_and_check(S_OR,    32'hF0F0_0000, 32'h0000_0F0F, 32'hF0F0_0F0F, "OR");
    issue_and_check(S_AND,   32'hF0F0_F0F0, 32'h0FF0_0FF0, 32'h00F0_00F0, "AND");

    $display("---- LUI / AUIPC (老 ALU 里没有, 本模块补的) ----");
    // LUI: 立即数就在 src1 上 (AIQ_SRC1_VLD=0 时 rf_dp 把 src1 切成 imm)
    issue_and_check(S_LUI,   32'h0000_0000, 32'h1234_5000, 32'h1234_5000, "LUI    src1 直通");
    // AUIPC: pc + imm。⚠️ src0 是 PRF[x0]=0, **不能**参与运算
    issue_and_check(S_AUIPC, 32'h0000_0000, 32'h0000_0020, 32'h0000_1020, "AUIPC  0x1000+0x20");
    // 故意把 src0 给个非 0 值: 结果必须**不变** (防止误写成 src0+src1)
    issue_and_check(S_AUIPC, 32'hDEAD_BEEF, 32'h0000_0020, 32'h0000_1020, "AUIPC  忽略 src0");

    $display("---- 非法指令: 报完成但**不写 PRF** ----");
    @(negedge clk);
    sel = 1; iid = 7'h33; dst_preg = 6'd5; rslt_sel = S_ILL; illegal = 1;
    @(negedge clk);
    sel = 0; illegal = 0;
    nchk = nchk + 1;
    if (cmplt_vld !== 1'b1 || cmplt_iid !== 7'h33) begin
      errs = errs + 1; $display("  ❌ 非法指令没报完成 (vld=%b) —— 那条会永远退不了休", cmplt_vld);
    end
    else if (wb_vld !== 1'b0) begin
      errs = errs + 1; $display("  ❌ 非法指令不该写 PRF (wb_vld=1)");
    end
    else
      $display("  ✅ 非法指令: 报完成、不写 PRF");
    @(negedge clk);

    $display("---- 冲刷: EX2 里的在途结果必须被清掉 ----");
    @(negedge clk);
    sel = 1; iid = 7'h44; dst_preg = 6'd9; src0 = 1; src1 = 2; rslt_sel = S_ADD;
    @(negedge clk);          // 此刻结果已进 EX1, 下一拍该写回
    sel = 0;
    flush = 1;               // 在 EX1→EX2 的边沿上冲刷
    @(negedge clk);
    flush = 0;
    nchk = nchk + 1;
    if (wb_vld !== 1'b0 || cmplt_vld !== 1'b0) begin
      errs = errs + 1;
      $display("  ❌ 冲刷后在途结果还报出来了 (wb=%b cmplt=%b) —— 会按 iid 命中新表项",
               wb_vld, cmplt_vld);
    end
    else
      $display("  ✅ 冲刷清掉了在途结果");
    @(negedge clk);

    if (errs == 0)
      $display("=== IU-ALU-PIPE UNIT: ALL PASS (%0d 项判据) ===", nchk);
    else begin
      $display("=== IU-ALU-PIPE UNIT: FAIL — %0d 条判据不过 / 共 %0d ===", errs, nchk);
      $fatal(1, "checks failed");
    end
    $finish;
  end

  initial begin
    repeat (500) @(posedge clk);
    $display("=== IU-ALU-PIPE UNIT: FAIL — 超时 ===");
    $fatal(1, "timeout");
  end

endmodule
