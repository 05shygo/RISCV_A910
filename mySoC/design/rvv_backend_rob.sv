/*
description: 
1. the ROB module receives uop information from Dispatch unit and uop result from Processor Unit (PU).
2. the ROB module provides all status for dispatch unit to foreward operand from ROB.
3. the ROB module send retire request to retire unit.
4. the ROB module receives trap information from LSU and flush buffer(s)

feature list:
1. the ROB can receive 2 uop information form Dispatch unit at most per cycle.
2. the ROB can receive 9 uop result from PU at most per cycle.
    a. However, U-arch of RVV limit the result number from 9 to 8.
3. the ROB can send 4 retire uops to writeback unit at most per cycle.
4. the ROB infomation for dispatch need to be sorted, which depends on program order.
*/

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_rob
(
    clk,
    rst_n,
    uop_valid_dp2rob,
    uop_dp2rob,
    uop_ready_rob2dp,
    rob_empty,
    rob_entry_rob2dp,
    wr_valid_pu2rob,
    wr_pu2rob,
    ff_tail_index,
    rd_valid_rob2rt,
    rd_rob2rt,
    rd_ready_rt2rob,
    rob_entry_rob2rt,
    uop_rob2dp,
    cmt_wmk_valid,
    cmt_wmk_iid,
    inst_cmplt_valid,
    inst_cmplt_rob_tag,
    rob_head_rob_tag,
    rob_head_valid,
`ifdef ZVT_ON
    vme_lsuflush_vld,
    vme_lsuflush_rdy,
`endif
    trap_valid_rmp2rob,
    trap_rob_entry_rmp2rob,
    trap_ready_rob2rmp,
`ifndef PRECISE_RVVTRAP
    trap_valid_rvs2rvv,
`endif
    trap_ready_rvv2rvs,
    trap_flush_rvv    
);  
// global signal
    input   logic                             clk;
    input   logic                             rst_n;

// push uop infomation to ROB
// Dispatch to ROB
    input   logic     [`NUM_DP_UOP-1:0]       uop_valid_dp2rob;
    input   DP2ROB_t  [`NUM_DP_UOP-1:0]       uop_dp2rob;
    output  logic     [`NUM_DP_UOP-1:0]       uop_ready_rob2dp;
    output  logic                             rob_empty;
    output  logic     [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2dp;

// push uop result to ROB
// PU to ROB
    input   logic     [`NUM_SMPORT-1:0]                   wr_valid_pu2rob;
    input   PU2ROB_t  [`NUM_SMPORT-1:0]                   wr_pu2rob;
    input   logic     [`NUM_SMPORT-1:0][$clog2(`VLENB):0] ff_tail_index;  

// retire uops
// pop vd_data from ROB and write to VRF
    output  logic     [`NUM_RT_UOP-1:0]       rd_valid_rob2rt;
    output  ROB2RT_t  [`NUM_RT_UOP-1:0]       rd_rob2rt;
    input   logic     [`NUM_RT_UOP-1:0]       rd_ready_rt2rob;
    output  logic     [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2rt;

// bypass all rob entries to Dispatch unit
// rob_entries must be in program order instead of entry_index
    output  ROB2DP_t  [`ROB_DEPTH-1:0]        uop_rob2dp;

// 2026-10-17 S4: 与 A910 的完成 / 提交接口
//   cmt_wmk_*   : bridge 寄存后的“提交水位”(电平, 不是脉冲)。水位覆盖
//                 (rob_tag 比它老或相等) 的表项才允许退休/写 VRF。
//   inst_cmplt_*: 一条指令的全部 uop 都 done 时发**一次**单拍脉冲,
//                 **早于**提交 —— 否则 A910 等 cmplt、core 等 commit 互锁。
    input   logic                             cmt_wmk_valid;
    input   logic   [`ROB_TAG_WIDTH-1:0]      cmt_wmk_iid;
    output  logic                             inst_cmplt_valid;
    output  logic   [`ROB_TAG_WIDTH-1:0]      inst_cmplt_rob_tag;
    output  logic   [`ROB_TAG_WIDTH-1:0]      rob_head_rob_tag;
    output  logic                             rob_head_valid;

// trap signal handshake
`ifdef ZVT_ON
    input   logic                             vme_lsuflush_vld;
    output  logic                             vme_lsuflush_rdy;
`endif
    input   logic                             trap_valid_rmp2rob;
    input   logic   [`ROB_DEPTH_WIDTH-1:0]    trap_rob_entry_rmp2rob;
    output  logic                             trap_ready_rob2rmp;
`ifndef PRECISE_RVVTRAP
    input   logic                             trap_valid_rvs2rvv;
`endif
    output  logic                             trap_ready_rvv2rvs;    
    output  logic                             trap_flush_rvv;        

// ---internal signal definition--------------------------------------
    logic                               trap_in;
    logic                               is_trapping;

  // Uop info
    DP2ROB_t  [`NUM_RT_UOP-1:0]         uop_rob2rt;
    logic     [`NUM_RT_UOP-1:0]         uop_valid_rob2rt;
    DP2ROB_t  [`ROB_DEPTH-1:0]          alluop_info;
    logic     [`ROB_DEPTH-1:0]          entry_valid;

    logic     [`ROB_DEPTH_WIDTH-1:0]    uop_wptr;
    logic     [`ROB_DEPTH_WIDTH-1:0]    uop_rptr;

  // Uop result
    RES_ROB_t [`ROB_DEPTH-1:0]          res_mem;
    logic     [`ROB_DEPTH-1:0]          uop_done;

  // trap
    logic     [`ROB_DEPTH-1:0]          trap_flag;

  // temp signal
    logic     [`ROB_DEPTH_WIDTH-1:0]    wind_uop_wptr [`ROB_DEPTH-1:0];
    logic     [`ROB_DEPTH_WIDTH-1:0]    wind_uop_rptr [`ROB_DEPTH-1:0];

  // 2026-10-17 S4: 完成链 / 提交门控
  //
  // ⚠️ 两套索引不能混:
  //    alluop_info / entry_valid / inst_done_chain / entry_committed 是
  //      **程序序**索引 (0 = ROB 头, multi_fifo 的 fifo_data 就是按 rptr 排的);
  //    uop_done / trap_flag / uop_cmplt_sent 是**物理槽位**索引
  //      (PU 写回带的是 rob_entry 物理号)。
  //    程序序 i 对应的物理槽恒为 wind_uop_rptr[i]。
    logic     [`ROB_DEPTH-1:0]          uop_cmplt_sent;  // 物理槽: 该表项的完成脉冲已发过
    logic     [`ROB_DEPTH-1:0]          inst_done_chain; // 程序序: 从断点起全 done
    logic     [`ROB_DEPTH-1:0]          entry_committed; // 程序序: 已被 A910 提交覆盖
    logic     [`ROB_DEPTH_WIDTH-1:0]    cmplt_sel;       // 程序序: 被选中发 cmplt 的位置

// ---code start------------------------------------------------------
  // 2026-10-17 S4: A910 iid 的年龄比较 (只用于退休门控慢路径)。
  // 规则与 mySoC/rtu/rtl/RTU_iid_cmp.v 完全一致:
  //   iid = {回绕位, 6 位索引}; 回绕位相同 ⇒ 索引小的更老;
  //   回绕位不同 ⇒ 索引**大**的属于上一圈, 更老。
  // ⚠️ 绝不接进重定向链 (那是 ~5 级 LUT)。
  function automatic logic iid_older (input logic [`ROB_TAG_WIDTH-1:0] a,
                                      input logic [`ROB_TAG_WIDTH-1:0] b);
    logic       msb_mismatch;
    logic [5:0] a_lo, b_lo;
    msb_mismatch = a[6] ^ b[6];
    a_lo = a[5:0];
    b_lo = b[5:0];
    iid_older = msb_mismatch ? (a_lo > b_lo) : (a_lo < b_lo);
  endfunction

  // Uop info FIFO
    multi_fifo #(
        .T            (DP2ROB_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_RT_UOP),
        .DEPTH        (`ROB_DEPTH),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1),
        .FULL_PUSH    (1'b1)
    ) u_uop_info_fifo (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // push side
        .push         (uop_valid_dp2rob),
        .pushRdy      (uop_ready_rob2dp),
        .datain       (uop_dp2rob),
      // pop side
        .pop          (rd_valid_rob2rt & rd_ready_rt2rob),
        .dataout      (uop_rob2rt),
        .full         (),
        .almost_full  (),
        .empty        (rob_empty),
        .almost_empty (),
      // fifo info
        .clear        (trap_flush_rvv),
        .fifo_data    (alluop_info),
        .wptr         (uop_wptr),
        .rptr         (uop_rptr),
        .entry_count  ()
    );

    assign rob_entry_rob2dp = uop_wptr;

  // entry valid
  // set if DP push uop into ROB
  // clear if RT pop uop from ROB
  // reset once flush ROB
    multi_fifo #(
        .T            (logic),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_RT_UOP),
        .DEPTH        (`ROB_DEPTH),
        .POP_CLEAR    (1'b1),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1),
        .FULL_PUSH    (1'b1)
    ) u_uop_valid_fifo (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // push side
        .push         (uop_valid_dp2rob),
        .pushRdy      (),
        .datain       (uop_valid_dp2rob),
      // pop side
        .pop          (rd_valid_rob2rt & rd_ready_rt2rob),
        .dataout      (uop_valid_rob2rt),
      // fifo info
        .full         (),
        .almost_full  (),
        .empty        (),
        .almost_empty (),
        .clear        (trap_flush_rvv),
        .fifo_data    (entry_valid),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

  // update PU result to result memory
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n)
            res_mem <= 'b0;
        else begin
            for (int k=0; k<`NUM_SMPORT; k++) begin
                if (wr_valid_pu2rob[k]) begin
                  `ifdef TB_SUPPORT
                    res_mem[wr_pu2rob[k].rob_entry].uop_pc        <= wr_pu2rob[k].uop_pc;
                  `endif                
                    res_mem[wr_pu2rob[k].rob_entry].w_valid       <= wr_pu2rob[k].w_valid;
                    res_mem[wr_pu2rob[k].rob_entry].w_data        <= wr_pu2rob[k].w_data;
                    res_mem[wr_pu2rob[k].rob_entry].ff_tail_index <= ff_tail_index[k];
                    res_mem[wr_pu2rob[k].rob_entry].vsaturate     <= wr_pu2rob[k].vsaturate;
                  `ifdef ZVE32F_ON
                    res_mem[wr_pu2rob[k].rob_entry].fpexp         <= wr_pu2rob[k].fpexp;
                  `endif
                end
            end
        end
    end

  // uop done
  // set if PU update uop result
  // clear if RT pop uop reuslt from ROB
  // reset once flush ROB.

  // wind back pointer
     for (genvar i=0; i<`ROB_DEPTH; i++) begin : gen_wind_uop_ptr
       assign wind_uop_rptr[i] = uop_rptr+i;
       assign wind_uop_wptr[i] = uop_wptr+i;
     end
    
     always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            uop_done <= '0;
        else if (trap_flush_rvv)
            uop_done <= '0;
        else begin
            for (int k=0; k<`NUM_RT_UOP; k++) begin
                if (rd_valid_rob2rt[k] && rd_ready_rt2rob[k])
                    uop_done[wind_uop_rptr[k]] <= 1'b0;
            end
            for (int k=0; k<`NUM_SMPORT; k++) begin
                if (wr_valid_pu2rob[k])
                    uop_done[wr_pu2rob[k].rob_entry] <= 1'b1;
            end
        end
    end

  // ---------------------------------------------------------------------------
  // 2026-10-17 S4: 指令完成链 / 完成脉冲
  //
  // 一条指令可能拆成多个 uop。最后一个 uop 带 last_uop_valid=1。
  // inst_done_chain[i] = “从指令起点到程序序 i 为止的 uop 全部 done”。
  // 链的起点是 ROB 头 (程序序 0): 已经弹出的前缀一定已经 done，所以
  // chain[0] = uop_done[head] 是成立的 —— 头有可能停在一条指令的中间。
  // ⚠️ 不要写成 `i_prev = (i==0)? DEPTH-1 : i-1` 的回绕形式: 程序序 0 就是
  //    头，链从 0 起头即可；回绕会把 ROB 尾部的残留项接到头上。
  // ---------------------------------------------------------------------------
  always_comb begin
    for (int i=0; i<`ROB_DEPTH; i++) begin
      if (i == 0) begin
        inst_done_chain[i] = uop_done[wind_uop_rptr[0]];
      end else begin
        inst_done_chain[i] = uop_done[wind_uop_rptr[i]] &&
                             (alluop_info[i-1].last_uop_valid ||
                              inst_done_chain[i-1]);
      end
    end
  end

  // 从 ROB 头方向挑一条已经完成的指令输出 (每拍最多一条)。
  // ⚠️ 必须带 entry_valid: rptr..wptr 之外的槽位是**上次的残留值**，
  //    不加掩码会从已弹出的槽里发出幽灵完成脉冲。
  // ⚠️ 必须排除 trap_flag: trap 表项由异常路径负责，再发 cmplt 会和
  //    A910 的退休/异常通路竞争。
  always_comb begin
    cmplt_sel        = '0;
    inst_cmplt_valid = 1'b0;
    for (int i=`ROB_DEPTH-1; i>=0; i--) begin
      if (!trap_flush_rvv &&
          entry_valid[i] &&
          inst_done_chain[i] &&
          alluop_info[i].last_uop_valid &&
          !trap_flag[wind_uop_rptr[i]] &&
          !uop_cmplt_sent[wind_uop_rptr[i]]) begin
        cmplt_sel        = `ROB_DEPTH_WIDTH'(i);
        inst_cmplt_valid = 1'b1;
      end
    end
  end
  assign inst_cmplt_rob_tag = alluop_info[cmplt_sel].rob_tag;

  // 每个表项只发一次完成脉冲:
  //   set   : 本拍被选中发 cmplt
  //   clear : 该 uop 被退休 (槽位即将重用) / trap 冲刷
  // ⚠️ clear 写在 set 之后: 同一拍既发 cmplt 又 pop 时以“清”为准,
  //    否则重用槽位会继承 sent=1，吞掉新指令的完成脉冲。
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      uop_cmplt_sent <= '0;
    else if (trap_flush_rvv)
      uop_cmplt_sent <= '0;
    else begin
      if (inst_cmplt_valid)
        uop_cmplt_sent[wind_uop_rptr[cmplt_sel]] <= 1'b1;
      for (int k=0; k<`NUM_RT_UOP; k++) begin
        if (rd_valid_rob2rt[k] && rd_ready_rt2rob[k])
          uop_cmplt_sent[wind_uop_rptr[k]] <= 1'b0;
      end
    end
  end

  // 提交水位: 表项的 rob_tag 不比水位年轻 ⇒ 已提交。
  // cmt_wmk_* 由 bridge 寄存成**电平** —— 没有提交脉冲的拍水位仍然有效。
  always_comb begin
    for (int i=0; i<`ROB_DEPTH; i++) begin
      entry_committed[i] = cmt_wmk_valid &&
                           (alluop_info[i].rob_tag == cmt_wmk_iid ||
                            iid_older(alluop_info[i].rob_tag, cmt_wmk_iid));
    end
  end

  assign rob_head_valid   = entry_valid[0];
  assign rob_head_rob_tag = alluop_info[0].rob_tag;

  `ifdef ASSERT_ON
    logic [`ROB_DEPTH-1:0][`NUM_SMPORT-1:0] res_sel; // one hot code for each entry
    for (genvar i=0; i<`ROB_DEPTH; i++) begin : gen_res_sel
        for (genvar j=0; j<`NUM_SMPORT; j++) begin : gen_smport    
            assign res_sel[i][j] = wr_valid_pu2rob[j] && (wr_pu2rob[j].rob_entry == i);
        end

        `rvv_expect($onehot0(res_sel[i])) 
        else $error("ROB: Multiple PU results write same entry: index %d, PU %d\n", i, $sampled(res_sel[i]));

    end
  `endif

  `ifdef ASSERT_ON
    for (genvar i=0; i<`ROB_DEPTH; i++) begin : gen_res_write_check
      `rvv_forbid( uop_done[wind_uop_rptr[i]] && !entry_valid[i] )
      else $error("ROB: Write back to ROB entry[%d] while entry is invalid", i);

    `ifdef TB_SUPPORT
      `rvv_forbid( uop_done[wind_uop_rptr[i]] && entry_valid[i] && (res_mem[wind_uop_rptr[i]].uop_pc !== alluop_info[i].uop_pc) )
      else $error("ROB: Result pc written back to ROB is mismacth: res_mem[%d].uop_pc(0x%08x) != alluop_info[%d].uop_pc(0x%08x)", i, res_mem[wind_uop_rptr[i]].uop_pc, i, alluop_info[i].uop_pc);
    `endif
    end
  `endif

  // trap flag
  // write trap to ROB when trap occurs
  // flush all fifo when the uop triggering trap is the oldest uop in ROB
  always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n)
          trap_flag <= '0;
      else if (trap_flush_rvv)
          trap_flag <= '0;
      else if (trap_valid_rmp2rob & trap_ready_rob2rmp)
          trap_flag[trap_rob_entry_rmp2rob] <= 1'b1;
  end

  // trap ready is always 1
  assign trap_ready_rob2rmp = 1'b1;

  // retire uop(s)
  logic [`ROB_DEPTH-1:0][$clog2(`VLENB):0] rt_ff_tail_index;
  logic [`ROB_DEPTH-1:0][`VLENB-1:0]       rt_ff_strobe;
  logic [`ROB_DEPTH-1:0]                   is_ff;

  for (genvar i=0; i<`ROB_DEPTH; i++) begin
    // write strobe
      assign rt_ff_tail_index[i] = res_mem[wind_uop_rptr[i]].ff_tail_index;
      assign is_ff[i]            = alluop_info[i].is_ff;
      assign rt_ff_strobe[i]     = ~((`VLENB)'('1)<<rt_ff_tail_index[i]);
  end

  for (genvar i=0; i<`NUM_RT_UOP; i++) begin : gen_rob2rt
    // retire_uop valid
    // 2026-10-17 S4: 送给 retire 级的 valid 必须带提交门控 ——
    // 不能只门控 ROB 内部 uop FIFO 的 pop：retire 级 (rvv_backend_retire.sv)
    // 是直接看 rd_valid_rob2rt / rd_ready_rt2rob 写 VRF 的，只门控 pop
    // 挡不住推测写。trap 表项放行：w_valid_chkTrap 已保证 trap 时不写 VRF，
    // 而且 core 自己的 trap 冲刷需要它流到 retire 级。
      if (i==0) begin : gen_0
        assign rd_valid_rob2rt[0] = uop_valid_rob2rt[0] &
                                    (uop_done[wind_uop_rptr[0]] | trap_flag[wind_uop_rptr[0]]) &
                                    (entry_committed[0] | trap_flag[wind_uop_rptr[0]]);
      end else begin : gen_i
        assign rd_valid_rob2rt[i] = uop_valid_rob2rt[i] &
                                    uop_done[wind_uop_rptr[i]] &
                                    rd_valid_rob2rt[i-1] &
                                    ~trap_flag[wind_uop_rptr[i]-1'b1] &
                                    (entry_committed[i] | trap_flag[wind_uop_rptr[i]]);
      end
    // retire_uop data
    `ifdef TB_SUPPORT          
      assign rd_rob2rt[i].uop_pc           = uop_rob2rt[i].uop_pc;
    `endif          
      assign rd_rob2rt[i].rob_tag          = uop_rob2rt[i].rob_tag;
      assign rd_rob2rt[i].res_updating_end = uop_rob2rt[i].res_updating_end;
      assign rd_rob2rt[i].last_uop_valid   = uop_rob2rt[i].last_uop_valid;
      assign rd_rob2rt[i].w_valid         = res_mem[wind_uop_rptr[i]].w_valid & uop_done[wind_uop_rptr[i]];
      assign rd_rob2rt[i].w_index         = uop_rob2rt[i].w_index;
      assign rd_rob2rt[i].w_data          = res_mem[wind_uop_rptr[i]].w_data;
      assign rd_rob2rt[i].w_type          = uop_rob2rt[i].w_type;
      assign rd_rob2rt[i].trap_flag       = trap_flag[wind_uop_rptr[i]];
      assign rd_rob2rt[i].vector_csr      = uop_rob2rt[i].vector_csr;
      assign rd_rob2rt[i].vxsaturate      = res_mem[wind_uop_rptr[i]].vsaturate;
    `ifdef ZVE32F_ON
      assign rd_rob2rt[i].fpexp           = res_mem[wind_uop_rptr[i]].fpexp;
    `endif

      always_comb begin
          for(int j=0;j<`VLENB;j++) begin
              rd_rob2rt[i].vd_type[j] = (is_ff[i] && !rt_ff_strobe[i][j]) ? TAIL : uop_rob2rt[i].byte_type[j];
          end
      end
  end

  assign rob_entry_rob2rt = uop_rptr;
  
  // trap handle ready and flush signal
  assign trap_in = uop_valid_rob2rt[0] & rd_rob2rt[0].trap_flag & rd_ready_rt2rob[0]
                  `ifdef ZVT_ON
                   || vme_lsuflush_vld
                  `endif
                  `ifndef PRECISE_RVVTRAP
                   || trap_valid_rvs2rvv
                  `endif
                   ;

  dff regTrapFlush (.q(is_trapping), .d(trap_in&(!is_trapping)), .clk(clk), .rst_n(rst_n));

  assign trap_flush_rvv = trap_in || is_trapping; // flush 2 cycles

  assign trap_ready_rvv2rvs = is_trapping;
`ifdef ZVT_ON
  assign vme_lsuflush_rdy = is_trapping;
`endif

  // bypass ROB info to Dispatch
  for (genvar i=0; i<`ROB_DEPTH; i++) begin : gen_rob2dp
    `ifdef TB_SUPPORT
      assign uop_rob2dp[i].uop_pc     = alluop_info[i].uop_pc;
    `endif
      assign uop_rob2dp[i].valid      = entry_valid[i];
      assign uop_rob2dp[i].w_valid    = res_mem[wind_uop_rptr[i]].w_valid & uop_done[wind_uop_rptr[i]];
      assign uop_rob2dp[i].w_index    = alluop_info[i].w_index;
      assign uop_rob2dp[i].w_type     = alluop_info[i].w_type;
      assign uop_rob2dp[i].w_data     = res_mem[wind_uop_rptr[i]].w_data;
      assign uop_rob2dp[i].vector_csr = alluop_info[i].vector_csr;

      always_comb begin
          for(int j=0;j<`VLENB;j++) begin
              uop_rob2dp[i].byte_type[j] = (is_ff[i] && !rt_ff_strobe[i][j]) ? TAIL : alluop_info[i].byte_type[j];
          end
      end
  end
  
endmodule
