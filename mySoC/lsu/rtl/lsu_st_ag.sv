module ct_lsu_st_ag #(
    parameter int DCACHE_SIZE = 2048, 
    parameter int LSIQ_ENTRY = 8, // 1024, 2048, or 4096 bytes
    parameter int SDIQ_ENTRY = 4,
    parameter int CACHELINE_SIZE = 32,
    parameter int NUM_WAYS = 2,
    parameter int OFFSET_WIDTH = 5,
    parameter int NUM_SETS = DCACHE_SIZE / CACHELINE_SIZE / NUM_WAYS,
    parameter int INDEX_WIDTH = $clog2(NUM_SETS)
)(
    input  logic         cpurst_b,
    input  logic         forever_cpuclk,
    input  logic [31:0]  dcache_arb_st_ag_addr,
    input  logic         dcache_arb_st_ag_borrow_addr_vld,
    input  logic         idu_lsu_st_sel,
    input  logic [1:0]   idu_lsu_st_inst_size,
    // 2026-10-15 停用: 非对齐拆分通路的"第二条"标记, 见下方 "非对齐硬件已停用" 一节
    //input  logic         idu_lsu_st_unalign_2nd,
    input  logic [6:0]   idu_lsu_st_iid,
    input  logic [LSIQ_ENTRY-1:0]  idu_lsu_st_lch_entry,
    input  logic [SDIQ_ENTRY-1:0]  idu_lsu_st_sdiq_entry,
    input  logic         idu_lsu_st_oldest,
    input  logic [11:0]  idu_lsu_st_offset,
    // 2026-10-15 停用: LSU 不再接收 IDU 的 offset_plus (只有非对齐拆分才用它)
    //input  logic [12:0]  idu_lsu_st_offset_plus,
    input  logic [31:0]  idu_lsu_st_src0,
    input  logic         rtu_yy_xx_flush,
    input  logic         dcache_arb_ag_st_sel,

    output logic         ag_dcache_arb_st_dirty_gateclk_en,
    output logic [INDEX_WIDTH-1:0]   ag_dcache_arb_st_dirty_idx,
    output logic         ag_dcache_arb_st_dirty_req,
    output logic         ag_dcache_arb_st_tag_gateclk_en,
    output logic [INDEX_WIDTH-1:0]   ag_dcache_arb_st_tag_idx,
    output logic         ag_dcache_arb_st_tag_req,
    // 2026-10-15 停用: 非对齐拆分通路整条摘掉 (boundary/secd), 见下方说明块
    //output logic         st_ag_boundary,
    output logic [31:0]  st_ag_dc_addr0,
    output logic [15:0]  st_ag_dc_bytes_vld,
    output logic         st_ag_dc_inst_vld,
    output logic [3:0]   st_ag_dc_rot_sel,
    output logic [6:0]   st_ag_iid,
    (* max_fanout = 32 *) output logic st_ag_inst_vld,
    output logic [LSIQ_ENTRY-1:0]   st_ag_lsid,
    output logic         st_ag_old,
    output logic         st_ag_expt,
    output logic [SDIQ_ENTRY-1:0]   st_ag_sdid_oh,
    //output logic         st_ag_secd,
    output logic [LSIQ_ENTRY-1:0]   st_ag_stall_restart_entry
);
    localparam int INDEX_LSB = OFFSET_WIDTH;
    localparam int INDEX_MSB = INDEX_LSB + INDEX_WIDTH - 1;

    localparam BYTE  = 2'b00,
               HALF  = 2'b01,
               WORD  = 2'b10,
               DWORD = 2'b11;

    localparam PC_LEN     = 15;

    //==========================================================
    //                 Pipeline Register
    //==========================================================
    logic st_ag_stall_vld;
    logic st_ag_stall_mask;
    //logic st_ag_stall_restart;
    logic st_ag_dcache_stall_req;
    logic st_ag_dcache_stall_unmask;

    assign st_ag_dcache_stall_unmask = !dcache_arb_ag_st_sel;
    assign st_ag_dcache_stall_req = st_ag_dcache_stall_unmask && st_ag_inst_vld;
    // ⚠️⚠️ 2026-10-15 补: 与 lsu_ld_ag.sv 同款 —— **必须带 `&& !st_ag_stall_mask`**。
    //   原版 ct_lsu_st_ag.v:1331-1332
    //      st_ag_stall_vld = st_ag_stall_ori && !st_ag_stall_mask;
    //   (原版注释同 ld_ag: "for performance, when ag stall, let oldest inst go")
    //   本仓原来把它注掉了 ⇒ mask=1 (RF 那条 store 比 AG 里那条**更老**) 时 AG 仍自称
    //   stall ⇒ 拒收更老的那条 store, 而 RF 级下拍就换下一条 ⇒ 这条 store 既没进 AG、
    //   LSIQ 表项也没被 pop; 那拍 `st_ag_stall_restart_entry` 又选的是 `st_ag_lsid`
    //   (AG 里更年轻那条) ⇒ 更老的表项没有任何 wakeup 去解 `frz` ⇒ 永远不再发射。
    //   ⚠️ 原来是**整段注释掉**的 (连输出口一起悬空 → Z → `lsu_idu_imme_wakeup` 全 X),
    //   2026-10-15 先补了 restart_entry 那一段, 这一项 (取反) 是第二步。
    assign st_ag_stall_vld = st_ag_dcache_stall_req && !st_ag_stall_mask;

    // ⚠️⚠️ 2026-10-16 补: **不能用 `st_ag_stall_vld`**, 原版是"mask 之前"的 restart 请求。
    //   原版 ct_lsu_st_ag.v:1331-1346
    //      st_ag_stall_restart = cross_page_str_imme_stall_req || st_ag_dcache_stall_req
    //                            || st_ag_mmu_stall_req || st_ag_atomic_no_cmit_restart_req;
    //      st_ag_dc_inst_vld   = st_ag_inst_vld && !st_ag_stall_restart;
    //   本仓把 cross_page / mmu / atomic 三项连端口一起砍了 (本模块没有那几条通路),
    //   所以这里只剩 dcache 一项 —— 但**同样不能取反 mask**。
    //   为什么: mask=1 (RF 那条 store 比 AG 里那条**更老**) 时 AG 要"让更老的走", 具体是
    //   两个动作**必须成对**: ①`st_ag_stall_vld=0` 把 AG 寄存器让给那条更老的 (手里更年轻
    //   的那条就此**被挤掉、永远到不了 DC**); ②`st_ag_stall_restart_entry` 选 `st_ag_lsid`
    //   (被挤掉那条) 发 wakeup, 让它回 LSIQ 重新发射。
    //   本仓原来 ② 对了、① 的 DC 口却写成 `!st_ag_stall_vld` ⇒ mask=1 那拍**被挤掉的那条
    //   照样往 DC 走**, 于是同一条 store **既在 DC 建了一张 SQ 表项、又被 wakeup 重新发射
    //   再建一张** —— 双派发。SDIQ 表项只服务一份数据, 抢不上就成孤儿 (挂死)。
    //   实测 (-O3 flags 版 iid=109@0xf75c): T260175 mask=1 ⇒ T260176 建 SQ#1 且同日
    //   entry6 被 wakeup ⇒ T260179 又建 SQ#2, SDIQ entry3 已弹 ⇒ `notdvld` 恒 1 ⇒
    //   RTU_flush 的 WAIT 出不去。改回"mask 之前"后两份 -O3 镜像都能跑到 ecall。
    //   注: mask=0 那拍 `stall_vld == stall_restart`, 两种写法**逐拍等价** ⇒ 只动 mask=1 那条路。
    assign st_ag_stall_restart = st_ag_dcache_stall_req;
   // assign st_ag_stall_restart = st_ag_dcache_stall_req && st_ag_stall_mask;

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            st_ag_inst_vld <= 1'b0;
        else if (rtu_yy_xx_flush)
            st_ag_inst_vld <= 1'b0;
        else if (st_ag_stall_vld || idu_lsu_st_sel)
            st_ag_inst_vld <= 1'b1;
        else
            st_ag_inst_vld <= 1'b0;
    end

    (* max_fanout = 8 *) logic [31:0] st_ag_base;
    logic [31:0] st_ag_offset;
    //logic [12:0] st_ag_offset_plus;   // 2026-10-15 停用: 非对齐 +16 偏移
    logic [1:0]  st_ag_inst_size;

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            st_ag_inst_size[1:0]          <= 2'b0;
            // 2026-10-15 停用: st_ag_secd 改由下方常量驱动
            //st_ag_secd                    <= 1'b0;
            st_ag_iid[6:0]                <= 7'b0;
            st_ag_lsid[LSIQ_ENTRY-1:0]    <= {LSIQ_ENTRY{1'b0}};
            st_ag_sdid_oh[SDIQ_ENTRY-1:0] <= {SDIQ_ENTRY{1'b0}};
            st_ag_old                     <= 1'b0;
        end
        else if (!st_ag_stall_vld && idu_lsu_st_sel) begin
            st_ag_inst_size[1:0]          <= idu_lsu_st_inst_size[1:0];
            // 2026-10-15 停用: 非对齐第二条标记
            //st_ag_secd                    <= idu_lsu_st_unalign_2nd;
            st_ag_iid[6:0]                <= idu_lsu_st_iid[6:0];
            st_ag_lsid[LSIQ_ENTRY-1:0]    <= idu_lsu_st_lch_entry[LSIQ_ENTRY-1:0];
            st_ag_sdid_oh[SDIQ_ENTRY-1:0] <= idu_lsu_st_sdiq_entry[SDIQ_ENTRY-1:0];
            st_ag_old                     <= idu_lsu_st_oldest;
        end
    end

    always_ff @(posedge forever_cpuclk) begin
        if (!st_ag_stall_vld && idu_lsu_st_sel)
            st_ag_offset[31:0] <= {{20{idu_lsu_st_offset[11]}}, idu_lsu_st_offset[11:0]};
    end

    // 2026-10-15 停用: offset_plus (非对齐拆分用的 +16 偏移) 连同它的输入口一起停用
    /*
    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            st_ag_offset_plus[12:0] <= 13'h0;
        else if (!st_ag_stall_vld && idu_lsu_st_sel)
            st_ag_offset_plus[12:0] <= idu_lsu_st_offset_plus[12:0];
    end
    */

    always_ff @(posedge forever_cpuclk) begin
        if (!st_ag_stall_vld && idu_lsu_st_sel)
            st_ag_base[31:0] <= idu_lsu_st_src0[31:0];
    end

    //==========================================================
    //               Generate virtual address
    //==========================================================
    logic [31:0] st_ag_addr_ori;
    //logic [31:0] st_ag_addr_plus;      // 2026-10-15 停用: 非对齐 +16 地址
    //logic        st_ag_addr_plus_sel;  // 2026-10-15 停用
    logic [31:0] st_ag_addr;

    assign st_ag_addr_ori[31:0] = st_ag_base[31:0] + st_ag_offset[31:0];

    // 2026-10-15 停用: 非对齐拆分时第二条要用 +16 的地址, 对齐访问恒用 ori
    /*
    assign st_ag_addr_plus[31:0] = st_ag_base[31:0] +
        {{19{st_ag_offset_plus[12]}}, st_ag_offset_plus[12:0]};

    assign st_ag_addr_plus_sel = st_ag_secd;
    */
    assign st_ag_addr[31:0] = st_ag_addr_ori[31:0];

logic st_ag_align;
always @(*)
begin
casez({st_ag_inst_size[1:0],st_ag_addr_ori[2:0]})
  {BYTE,3'b???}:st_ag_align = 1'b1;
  {HALF,3'b??0}:st_ag_align = 1'b1;
  {WORD,3'b?00}:st_ag_align = 1'b1;
  default:st_ag_align  = 1'b0;
endcase
// &CombEnd; @420
end
assign st_ag_expt = !st_ag_align;
    //==========================================================
    //            Generate unalign, bytes_vld
    //==========================================================
    logic [3:0]  st_ag_access_size_ori;
    logic [3:0]  st_ag_access_size;
    logic [15:0] st_ag_le_bytes_vld_high_bits_full;
    logic [15:0] st_ag_le_bytes_vld_low_bits_full;
    logic [15:0] st_ag_le_bytes_vld_cross;
    logic [15:0] st_ag_le_bytes_vld_high_cross_bits;
    //logic [15:0] st_ag_bytes_vld_low_bits;   // 2026-10-15 停用: 只服务非对齐第二半
    logic [15:0] st_ag_bytes_vld_high_cross_bits;
    logic [15:0] st_ag_bytes_vld;
    logic [4:0]  st_ag_va_add_access_size;
    //logic        st_ag_boundary_unmask;   // 2026-10-15 停用: 非对齐跨行判定

    always_comb begin
        case (st_ag_inst_size[1:0])
            BYTE:    st_ag_access_size_ori[3:0] = 4'b0000;
            HALF:    st_ag_access_size_ori[3:0] = 4'b0001;
            WORD:    st_ag_access_size_ori[3:0] = 4'b0011;
            DWORD:   st_ag_access_size_ori[3:0] = 4'b0111;
            default: st_ag_access_size_ori[3:0] = 4'b0;
        endcase
    end

    assign st_ag_access_size[3:0] = st_ag_access_size_ori[3:0];

    // st_ag_va_add_access_size 的 [3:0] 还要给下面 bytes_vld 查表用 ⇒ 保留;
    // [4] (越过 32B 行的进位) 只服务 boundary, 见下方说明块。
    assign st_ag_va_add_access_size[4:0] = {1'b0, st_ag_addr_ori[3:0]} +
                                           {1'b0, st_ag_access_size[3:0]};
    //assign st_ag_boundary_unmask = st_ag_va_add_access_size[4];

    //assign st_ag_boundary = st_ag_boundary_unmask || st_ag_secd;

    // ═══════════════════════════════════════════════════════════════════════
    // 2026-10-15 停用: 非对齐 (boundary / unalign) 硬件处理逻辑 —— 整条从流水线摘掉
    //   前提: 现在跑的测试里**不会再出现非对齐访问** —— 非对齐一律由 st_ag_expt
    //         (见上方 `assign st_ag_expt = !st_ag_align;`) 当异常上报。
    //   已摘掉的输出 (端口 + 驱动一并注释, 不再往下传给 st_dc):
    //     st_ag_boundary  —— 原 = st_ag_boundary_unmask || st_ag_secd   (上方已注释)
    //     st_ag_secd      —— 原 = reg(idu_lsu_st_unalign_2nd)           (见上面的 always)
    //   对齐情形下这两根本来就恒 0, 摘掉后功能等价。
    //   ⚠️ 原逻辑按"只注释、不删除"原地保留, 便于回退。
    // ═══════════════════════════════════════════════════════════════════════
    //assign st_ag_boundary = 1'b0;
    //assign st_ag_secd     = 1'b0;

    always_comb begin
        case (st_ag_addr_ori[3:0])
            4'b0000: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffff;
            4'b0001: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfffe;
            4'b0010: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfffc;
            4'b0011: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfff8;
            4'b0100: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfff0;
            4'b0101: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffe0;
            4'b0110: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hffc0;
            4'b0111: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hff80;
            4'b1000: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hff00;
            4'b1001: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfe00;
            4'b1010: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hfc00;
            4'b1011: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hf800;
            4'b1100: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hf000;
            4'b1101: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'he000;
            4'b1110: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'hc000;
            4'b1111: st_ag_le_bytes_vld_high_bits_full[15:0] = 16'h8000;
            default: st_ag_le_bytes_vld_high_bits_full[15:0] = {16{1'bx}};
        endcase
    end

    always_comb begin
        case (st_ag_va_add_access_size[3:0])
            4'b0000: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0001;
            4'b0001: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0003;
            4'b0010: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0007;
            4'b0011: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h000f;
            4'b0100: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h001f;
            4'b0101: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h003f;
            4'b0110: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h007f;
            4'b0111: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h00ff;
            4'b1000: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h01ff;
            4'b1001: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h03ff;
            4'b1010: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h07ff;
            4'b1011: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h0fff;
            4'b1100: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h1fff;
            4'b1101: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h3fff;
            4'b1110: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'h7fff;
            4'b1111: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'hffff;
            default: st_ag_le_bytes_vld_low_bits_full[15:0] = 16'b0;
        endcase
    end

    assign st_ag_le_bytes_vld_cross[15:0] =
        st_ag_le_bytes_vld_high_bits_full[15:0] & st_ag_le_bytes_vld_low_bits_full[15:0];

    // 2026-10-15 停用: 非对齐下这里的两个 mux (按 boundary_unmask / secd 选那一半掩码)
    //   全部塌成对齐那一支 —— 取 high_full & low_full 的交集, 即本次访问真正覆盖的字节。
    assign st_ag_le_bytes_vld_high_cross_bits[15:0] =
        //st_ag_boundary_unmask ? st_ag_le_bytes_vld_high_bits_full[15:0]
        //                      :
                                  st_ag_le_bytes_vld_cross[15:0];

    //assign st_ag_bytes_vld_low_bits[15:0] = st_ag_le_bytes_vld_low_bits_full[15:0];
    assign st_ag_bytes_vld_high_cross_bits[15:0] = st_ag_le_bytes_vld_high_cross_bits[15:0];

    assign st_ag_bytes_vld[15:0] =
        //st_ag_secd ? st_ag_bytes_vld_low_bits[15:0]
        //           :
                     st_ag_bytes_vld_high_cross_bits[15:0];

    //==========================================================
    //        vector mask
    //==========================================================
    assign st_ag_dc_bytes_vld[15:0] = st_ag_bytes_vld[15:0];
    assign st_ag_dc_rot_sel[3:0] = st_ag_addr_ori[3:0];

    //==========================================================
    //        Generate dcache request information
    //==========================================================
    logic ag_dcache_arb_st_gateclk_en;
    logic ag_dcache_arb_st_req;

    assign ag_dcache_arb_st_gateclk_en = st_ag_inst_vld;
    assign ag_dcache_arb_st_req = st_ag_inst_vld;

    assign ag_dcache_arb_st_tag_gateclk_en = ag_dcache_arb_st_gateclk_en;
    assign ag_dcache_arb_st_tag_req        = ag_dcache_arb_st_req;
    assign ag_dcache_arb_st_tag_idx        = st_ag_addr[INDEX_MSB:INDEX_LSB];

    assign ag_dcache_arb_st_dirty_gateclk_en = ag_dcache_arb_st_gateclk_en;
    assign ag_dcache_arb_st_dirty_req        = ag_dcache_arb_st_req;
    assign ag_dcache_arb_st_dirty_idx        = st_ag_addr[INDEX_MSB:INDEX_LSB];

    //==========================================================
    //        Generate stall/restart signal
    //==========================================================
    // ⚠️⚠️ 2026-10-15 恢复 (coremark_i1 T71237 整机死锁的真凶, 与 lsu_ld_ag.sv 同款):
    //   下面这一整段原来被注释掉了 ⇒ 输出口 `st_ag_stall_restart_entry` **没有任何
    //   驱动** (Z)。它经 lsu_top:
    //       lsu_idu_imme_wakeup = ld_dc_imme_wakeup | st_ag_stall_restart_entry
    //                             | ld_ag_stall_restart_entry | sq_data/global/lfb_depd_wakeup
    //   并进 LSIQ 表项的 `frz` 清条件 (`ct_idu_is_lsiq_entry.sv:121`):
    //       else if(lsu_frz_clr | x_unalign_2nd_set | lsu_idu_imme_wakeup) frz <= 1'b0;
    //   ① Z 让整根 `lsu_idu_imme_wakeup` 变 **X** ⇒ `if(X)` 取假分支 ⇒ 所有靠这条
    //      wakeup 解锁的表项都**永远解不开**;
    //   ② 就算把它接成 0 也一样死 —— 这段逻辑本来就是"LSIQ 把表项发给 RF、AG 这拍收不下
    //      (等 dcache 仲裁) 时把该表项的 frz 打掉"的**唯一**通道, 缺了它, 发射落空一次
    //      的表项就再也不发射。
    //   实测 (coremark_i1): T71248 起 ROB 队头 iid=40 (pc=00000cd8 `lh a4,0(a6)`) 停在
    //   LSIQ entry2 上 `vld=1 frz=1 x_raw_rdy=0` 且 `iss_en=0`, 而
    //   `ld_ag_re=0 / ld_dc_imme_wakeup=0 / st_ag_re=X` ⇒ 没有任何一条能把 frz 清掉;
    //   T71237 之后一条指令都不退休, 队头完不成 ⇒ 它后面那条已误预测的分支永远提交不了
    //   ⇒ 没有冲刷脉冲 ⇒ `A910_cpu.sv` 的 mispred 闸门永不开 ⇒ 整机冻结。
    //   接法与判据**照抄 lsu_ld_ag.sv:507-546** (那份是 2026-10-15 修好并验证过的):
    //   使能必须用 `st_ag_stall_vld` (= `!dcache_arb_ag_st_sel && st_ag_inst_vld`), 与
    //   原版在 ct_lsu_ctrl.v 里那层 `& {LSIQ_ENTRY{st_rf_restart_vld}}` 等价 —— 只有
    //   "这拍真在发射且真落空"才发 wakeup。若误用 `st_ag_stall_restart` 而无 inst_vld,
    //   AG 级空着、新 store 刚发进来那拍会发一次多余的 wakeup ⇒ 表项解锁后重复发射。
    logic rf_iid_older_than_st_ag;

    ct_rtu_compare_iid x_lsu_rf_compare_st_ag_iid (
        .x_iid0       (idu_lsu_st_iid[6:0]),
        .x_iid0_older (rf_iid_older_than_st_ag),
        .x_iid1       (st_ag_iid[6:0])
    );

    assign st_ag_stall_mask = idu_lsu_st_sel && rf_iid_older_than_st_ag;

    // ⚠️ 使能用的是**加 mask 之前**的 `st_ag_dcache_stall_req` (它已含 st_ag_inst_vld),
    //   不是 `st_ag_stall_vld` —— 否则 mask=1 那拍 (正是"AG 把更年轻那条挤出去"的场合)
    //   stall_vld 已被上面的取反项拉低, `st_ag_lsid` 这一支永远选不中, 被挤出去的那条
    //   store 就再也发不回来了。对齐原版: 使能用的也是**未取反**的 stall_ori。
    assign st_ag_stall_restart_entry[LSIQ_ENTRY-1:0] =
        (idu_lsu_st_sel && st_ag_dcache_stall_req)
          ? (st_ag_stall_mask ? st_ag_lsid[LSIQ_ENTRY-1:0]
                              : idu_lsu_st_lch_entry[LSIQ_ENTRY-1:0])
          : {LSIQ_ENTRY{1'b0}};
    //==========================================================
    //        Generate to DC stage signal
    //==========================================================
    // ⚠️ 用 `!st_ag_stall_restart` (mask 之前), 不是 `!st_ag_stall_vld` —— 见上面那段注释。
    assign st_ag_dc_inst_vld = st_ag_inst_vld && !st_ag_stall_restart;

    assign st_ag_dc_addr0[31:0] = dcache_arb_st_ag_borrow_addr_vld
        ? dcache_arb_st_ag_addr[31:0]
        : st_ag_addr[31:0];

endmodule