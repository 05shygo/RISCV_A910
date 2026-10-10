`timescale 1ns/1ps
//==========================================================
// tb_rtu_expt —— RTU_expt 的单元台 (2026-10-10)
//==========================================================
// 【这个台子守什么】
// `RTU_expt` 是异常收集: **三个平行源 (IU / load / store) 锦标赛取最旧, 保持一项**。
// 这是 2026-10-10 从 `RTU_idu_lsu_adapter` 搬进来的 —— 搬的理由就是这里最容易错的
// 那件事: **同拍冲突必须取最旧的, 取错(取了年轻的)会让年长那条的异常永久丢失**
// (它比 trap 那条老 ⇒ 不在冲刷范围内 ⇒ 带着"无异常"的表项正常退休)。
//
// 判据分四组:
//   A. 单源: 三路各自单独有效时都能收下, 且 cause/tval 跟着走对;
//   B. **同拍锦标赛**: 三路任意组合同拍有效 ⇒ 收下的一定是 iid 最旧的那条,
//      且它的 cause/tval 也一起选对 (不是"iid 选对了、载荷选错了");
//   C. **跨拍覆盖**: 已持有 iid=0x20 时来 0x30 (更年轻) ⇒ 不动; 来 0x08 (更老) ⇒ 顶掉。
//      这是保持项那一级, 与 B 是**两级不同的逻辑**, 必须分开钉。
//   D. 冲刷清空 (少 `flush_clr` 那一支, 冲刷后会凭空陷入)。
//
// ⚠️ 保持项是**跨用例活着**的, 只有 `flush_clr` 清得掉 —— §A/§B 的每个用例前都要
//    用 `prep` 把它清干净, 否则会拿上一个用例的残留去比年龄, 得到假 FAIL
//    (第一版就栽在这, 而且看起来像 RTL 错)。
//
// ⚠️⚠️ **本台的 iid 全部落在同一个回绕圈内 (bit6=0, 即 0x00..0x3F)**。
//     RTU 的 iid 是 `{回绕位[6], 6 位索引[5:0]}`, 年龄比较**不是**简单的 7 位数大小:
//     回绕位不同时, "索引大"的那个属于**上一圈**、反而更老 (`RTU_iid_cmp`)。
//     ⇒ 0x50 与 0x10 的回绕位不同, 拿它们比年龄会得到"0x50 更老"这个**反直觉但正确**
//       的结果。第一版就是这么写的, 表现成 2 条假 FAIL。
//     真实运行时两两比较的对象一定在同一圈内 (ROB 深 64 < 128), 所以本台也这样构造;
//     跨回绕的行为由 tb_rtu_rob 的随机流覆盖。
//==========================================================
module tb_rtu_expt;

  logic        clk = 0;
  logic        rst = 1;
  always #5 clk = ~clk;

  logic        iu_vld, ld_vld, st_vld;
  logic [6:0]  iu_iid, ld_iid, st_iid;
  logic [4:0]  iu_cause, ld_cause, st_cause;
  logic [31:0] iu_tval, ld_tval, st_tval;
  logic        flush_clr;
  logic        entry_vld;
  logic [6:0]  entry_iid;
  logic [4:0]  entry_cause;
  logic [31:0] entry_tval;

  RTU_expt dut (
    .cpu_clk      (clk),
    .cpu_rst      (rst),
    .expt_iu_vld  (iu_vld),  .expt_iu_iid(iu_iid),
    .expt_iu_cause(iu_cause),.expt_iu_tval(iu_tval),
    .expt_ld_vld  (ld_vld),  .expt_ld_iid(ld_iid),
    .expt_ld_cause(ld_cause),.expt_ld_tval(ld_tval),
    .expt_st_vld  (st_vld),  .expt_st_iid(st_iid),
    .expt_st_cause(st_cause),.expt_st_tval(st_tval),
    .flush_clr    (flush_clr),
    .entry_vld    (entry_vld),
    .entry_iid    (entry_iid),
    .entry_cause  (entry_cause),
    .entry_tval   (entry_tval)
  );

  integer errs = 0;

  // 每个**独立**用例开始前调它: 清三源 + 用 flush_clr 把保持项也清掉。
  //
  // ⚠️ 为什么要动 flush_clr —— 保持项是**跨用例活着**的 (只有冲刷才清它)。
  //    第一版没清, 于是用例 2 拿 iid=0x12 去比用例 1 留下的 0x11: 0x12 更年轻
  //    ⇒ 正确地没被收下, 而台子把它当成了 FAIL。**台子的错, 不是 RTL 的错。**
  //    跨拍覆盖是 §C 组专门考的, 别让它在 §A/§B 里意外发生。
  task automatic prep;
    begin
      iu_vld=0; ld_vld=0; st_vld=0;
      iu_iid=0; ld_iid=0; st_iid=0;
      iu_cause=0; ld_cause=0; st_cause=0;
      iu_tval=0; ld_tval=0; st_tval=0;
      flush_clr=1; @(posedge clk); #1;
      flush_clr=0; @(posedge clk); #1;
    end
  endtask

  // 只清三源 (不动保持项) —— §C 组的跨拍用例要它。
  task automatic clr_src;
    begin
      iu_vld=0; ld_vld=0; st_vld=0;
      iu_iid=0; ld_iid=0; st_iid=0;
      iu_cause=0; ld_cause=0; st_cause=0;
      iu_tval=0; ld_tval=0; st_tval=0;
      @(posedge clk); #1;
    end
  endtask

  task automatic chk(string what, logic exp_vld, logic [6:0] exp_iid,
                     logic [4:0] exp_cause, logic [31:0] exp_tval);
    begin
      if (entry_vld !== exp_vld) begin
        errs=errs+1;
        $display("FAIL[%s]: entry_vld=%b 期望 %b", what, entry_vld, exp_vld);
      end
      if (exp_vld && (entry_iid !== exp_iid || entry_cause !== exp_cause
                      || entry_tval !== exp_tval)) begin
        errs=errs+1;
        $display("FAIL[%s]: 收下的是 iid=%h cause=%0d tval=%h, 期望 iid=%h cause=%0d tval=%h",
                 what, entry_iid, entry_cause, entry_tval, exp_iid, exp_cause, exp_tval);
      end
    end
  endtask

  initial begin
    iu_vld=0; ld_vld=0; st_vld=0; flush_clr=0;
    iu_iid=0; ld_iid=0; st_iid=0; iu_cause=0; ld_cause=0; st_cause=0;
    iu_tval=0; ld_tval=0; st_tval=0;

    rst=1; repeat(3) @(posedge clk); rst=0; @(posedge clk); #1;
    chk("复位后", 1'b0, 7'd0, 5'd0, 32'd0);

    // ---------------- A. 单源: 三路各自都能收下, 载荷跟着走 ----------------
    iu_vld=1; iu_iid=7'h11; iu_cause=5'd2; iu_tval=32'haaaa; @(posedge clk); #1;
    chk("只有 IU", 1'b1, 7'h11, 5'd2, 32'haaaa);

    prep;
    ld_vld=1; ld_iid=7'h12; ld_cause=5'd4; ld_tval=32'hbbbb; @(posedge clk); #1;
    chk("只有 load", 1'b1, 7'h12, 5'd4, 32'hbbbb);

    prep;
    st_vld=1; st_iid=7'h13; st_cause=5'd6; st_tval=32'hcccc; @(posedge clk); #1;
    chk("只有 store", 1'b1, 7'h13, 5'd6, 32'hcccc);

    // ---------------- B. 同拍锦标赛: 每一对组合的正反两个方向 ----------------
    // iid 用 0x10 / 0x20 / 0x30, 索引小的更老 (同圈口径见文件头)。
    prep;
    iu_vld=1; iu_iid=7'h30; iu_cause=5'd2; iu_tval=32'h0001;
    ld_vld=1; ld_iid=7'h10; ld_cause=5'd4; ld_tval=32'h0002;   // ld 更老
    @(posedge clk); #1;
    chk("IU vs load (load 更老)", 1'b1, 7'h10, 5'd4, 32'h0002);

    prep;
    iu_vld=1; iu_iid=7'h10; iu_cause=5'd2; iu_tval=32'h0003;   // IU 更老
    ld_vld=1; ld_iid=7'h30; ld_cause=5'd4; ld_tval=32'h0004;
    @(posedge clk); #1;
    chk("IU vs load (IU 更老)", 1'b1, 7'h10, 5'd2, 32'h0003);

    prep;
    ld_vld=1; ld_iid=7'h30; ld_cause=5'd4; ld_tval=32'h0005;
    st_vld=1; st_iid=7'h10; st_cause=5'd6; st_tval=32'h0006;   // store 更老
    @(posedge clk); #1;
    chk("load vs store (store 更老)", 1'b1, 7'h10, 5'd6, 32'h0006);

    prep;
    ld_vld=1; ld_iid=7'h10; ld_cause=5'd4; ld_tval=32'h0007;   // load 更老
    st_vld=1; st_iid=7'h30; st_cause=5'd6; st_tval=32'h0008;
    @(posedge clk); #1;
    chk("load vs store (load 更老)", 1'b1, 7'h10, 5'd4, 32'h0007);

    // ⚠️ 三路同拍 —— 这条是这次改动的靶心。最老的是**第二级**才进来的那路
    //    (store), 所以它同时考了"第一级胜者不能直接获胜"这一点。
    prep;
    iu_vld=1; iu_iid=7'h20; iu_cause=5'd2; iu_tval=32'h0010;
    ld_vld=1; ld_iid=7'h30; ld_cause=5'd4; ld_tval=32'h0011;
    st_vld=1; st_iid=7'h10; st_cause=5'd6; st_tval=32'h0012;   // 三路里最老
    @(posedge clk); #1;
    chk("三路同拍 (store 最老)", 1'b1, 7'h10, 5'd6, 32'h0012);

    // 再来一组: 最老的是**第一级**里较年轻的那路 (load), 逼出第一级的方向选择
    prep;
    iu_vld=1; iu_iid=7'h30; iu_cause=5'd2; iu_tval=32'h0020;
    ld_vld=1; ld_iid=7'h10; ld_cause=5'd4; ld_tval=32'h0021;   // 三路里最老
    st_vld=1; st_iid=7'h20; st_cause=5'd6; st_tval=32'h0022;
    @(posedge clk); #1;
    chk("三路同拍 (load 最老)", 1'b1, 7'h10, 5'd4, 32'h0021);

    // ---------------- C. 跨拍覆盖: 保持项那一级 ----------------
    // 先 prep 起到"空", 之后本组**不再清保持项** —— 跨拍就是它要考的东西。
    prep;
    iu_vld=1; iu_iid=7'h20; iu_cause=5'd2; iu_tval=32'h0030; @(posedge clk); #1;
    chk("持有 0x20", 1'b1, 7'h20, 5'd2, 32'h0030);
    // 更年轻的 -> 不许动
    clr_src;
    st_vld=1; st_iid=7'h30; st_cause=5'd6; st_tval=32'h0031; @(posedge clk); #1;
    chk("更年轻的来了不许覆盖", 1'b1, 7'h20, 5'd2, 32'h0030);
    // 更老的 -> 顶掉
    clr_src;
    ld_vld=1; ld_iid=7'h08; ld_cause=5'd4; ld_tval=32'h0032; @(posedge clk); #1;
    chk("更老的来了要顶掉", 1'b1, 7'h08, 5'd4, 32'h0032);
    // 同拍两路但都更年轻 -> 仍然不许动
    clr_src;
    iu_vld=1; iu_iid=7'h18; iu_cause=5'd2; iu_tval=32'h0033;
    st_vld=1; st_iid=7'h28; st_cause=5'd6; st_tval=32'h0034; @(posedge clk); #1;
    chk("同拍两路都更年轻", 1'b1, 7'h08, 5'd4, 32'h0032);

    // ---------------- D. 冲刷清空 ----------------
    // ⚠️ 这条守的是 "错误路径上的异常必须丢掉" —— 少了 flush_clr 那一支,
    //    冲刷后会凭空陷入 (§8.4 的变异清单里专门有一条守它)。
    clr_src;
    flush_clr=1; @(posedge clk); #1;
    chk("冲刷后清空", 1'b0, 7'd0, 5'd0, 32'd0);
    flush_clr=0; @(posedge clk); #1;
    chk("清空后不复现", 1'b0, 7'd0, 5'd0, 32'd0);

    if (errs==0)
      $display("=== RTU-EXPT UNIT: ALL PASS ===");
    else begin
      $display("=== RTU-EXPT UNIT: FAIL — %0d 条判据不过 ===", errs);
      $fatal(1, "checks failed");
    end
    $finish;
  end
endmodule
