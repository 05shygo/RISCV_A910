`timescale 1ns / 1ps
`include "defines.vh"

// 机器模式 CSR 文件 + 陷阱入口 / 中断返回的硬件更新.
//
// 参照 cpu/src/csr_reg.v 的扁平结构, 但有意修正了参考实现里的几处问题:
//   1. 参考把 mstatus[6:4] 当作伪 MPP, 且硬件从不写它. 这里按规范用 [12:11]
//      做 MPP, 且因为本核只有 M 模式, 恒读 2'b11 (只读).
//   2. 参考的向量模式地址算成了 (base + cause) << 2 —— Verilog 里 '+' 的
//      优先级高于 '<<'. 这里显式写成 base + (cause << 2).
//   3. 参考对未实现的 CSR 读返回 0、写静默丢弃, 从不报非法指令. 这里由
//      Control.v 判定 is_illegal, 本模块只负责已实现地址的读写.
//
// 写操作的优先级(同一 always 块内, 靠后的赋值覆盖靠前的):
//     计数器 -> 软件写(来自 EX) -> 陷阱入口 -> mret
// CSR 指令本身不会陷入, 陷阱指令也不会写 CSR, 所以实际上互斥;
// 显式排序只是为了不出现"谁也不清楚谁赢"的歧义.
module CSR(
    input  wire        clk,
    input  wire        rst,

    // 读口: 组合读, 地址来自 **ID 级** (本条指令自己的 inst[31:20]),
    // 结果由 mycpu.v 随 ID_EX 锁一拍再进 EX —— 这条 mux 以前挂在 EX 的 ALU
    // 操作数上, 是 FPGA 关键路径的链头 (2026-09-28)。
    input  wire [11:0] raddr_i,
    output reg  [31:0] rdata_o,

    // 软件写口 (来自 EX, 已由 mycpu 用 ~redirect 门控)
    input  wire        we_i,
    input  wire [11:0] waddr_i,
    input  wire [31:0] wdata_i,

    // 陷阱入口 (来自 WB 的重定向逻辑)
    input  wire        trap_i,
    input  wire [31:0] trap_cause_i,
    input  wire [31:0] trap_epc_i,
    input  wire [31:0] trap_tval_i,

    // 中断返回
    input  wire        mret_i,

    // 提交脉冲: 用于 instret 计数 (被中断 squash 掉的那条不计)
    input  wire        retire_i,

    // 已寄存的定时器中断电平, 硬件驱动 mip[7]
    input  wire        timer_irq_i,

    // 中断仲裁需要的位
    output wire        mstatus_mie_o,
    output wire        mie_mtie_o,
    output wire        mip_mtip_o,

    // 陷阱向量 (已按 mtvec 模式解算好) 与中断返回地址
    output wire [31:0] trap_vector_o,
    output wire [31:0] mepc_o
);

    reg        mstatus_mie;
    reg        mstatus_mpie;
    reg        mie_mtie;
    reg [31:0] mtvec;       // [31:2] 基址, [0] 模式(0=直接 1=向量), [1] 恒 0
    reg [31:0] mscratch;
    reg [31:0] mepc;        // [1:0] 恒 0 (IALIGN=32)
    reg [31:0] mcause;
    reg [31:0] mtval;
    reg [63:0] mcycle;
    reg [63:0] minstret;

    // mip[7] 直接跟随已寄存的定时器中断电平: 源是高电平就一直挂着,
    // 软件只能靠抬高 mtimecmp 让源变低来清除 (与参考 clint.v 的语义一致).
    assign mstatus_mie_o = mstatus_mie;
    assign mie_mtie_o    = mie_mtie;
    assign mip_mtip_o    = timer_irq_i;

    assign mepc_o = mepc;

    // 陷阱向量: 直接模式一律走基址 (异常在向量模式下也走基址);
    // 只有"向量模式 + 中断"才加 4*cause.
    wire [31:0] tvec_base = {mtvec[31:2], 2'b00};
    assign trap_vector_o = (mtvec[0] && trap_cause_i[31])
                         ? (tvec_base + (trap_cause_i[3:0] << 2))
                         : tvec_base;

    // ---------------- 写 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst == `RstEnable) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_mtie     <= 1'b0;
            mtvec        <= 32'b0;
            mscratch     <= 32'b0;
            mepc         <= 32'b0;
            mcause       <= 32'b0;
            mtval        <= 32'b0;
            mcycle       <= 64'b0;
            minstret     <= 64'b0;
        end else begin
            // 1) 计数器
            mcycle <= mcycle + 1'b1;
            if (retire_i) minstret <= minstret + 1'b1;

            // 2) 软件写 (来自 EX 的 CSR 指令)
            //    只保存"已实现位", 未实现位读回恒 0 (WARL)
            if (we_i) begin
                case (waddr_i)
                    `CSR_MSTATUS: begin
                        mstatus_mie  <= wdata_i[`MSTATUS_MIE_BIT];
                        mstatus_mpie <= wdata_i[`MSTATUS_MPIE_BIT];
                    end
                    `CSR_MIE:      mie_mtie <= wdata_i[`MIE_MTIE_BIT];
                    `CSR_MTVEC:    mtvec    <= {wdata_i[31:2], wdata_i[0], 1'b0};
                    `CSR_MSCRATCH: mscratch <= wdata_i;
                    `CSR_MEPC:     mepc     <= {wdata_i[31:2], 2'b00};
                    `CSR_MCAUSE:   mcause   <= wdata_i;
                    `CSR_MTVAL:    mtval    <= wdata_i;
                    default:       ;
                endcase
            end

            // 3) 陷阱入口 (覆盖上面的软件写)
            if (trap_i) begin
                mepc         <= trap_epc_i;
                mcause       <= trap_cause_i;
                mtval        <= trap_tval_i;
                mstatus_mpie <= mstatus_mie;   // MPIE <- 旧的 MIE
                mstatus_mie  <= 1'b0;          // 关中断, 防止电平型 MTIP 反复触发
            end

            // 4) 中断返回
            if (mret_i) begin
                mstatus_mie  <= mstatus_mpie;  // MIE <- MPIE
                mstatus_mpie <= 1'b1;
            end
        end
    end

    // ---------------- 读 ----------------
    // mstatus 读回: MPP[12:11] 恒 2'b11 (只有 M 模式), 其余未实现位为 0
    wire [31:0] mstatus_rdata = {19'b0, 2'b11,
                                 3'b0, mstatus_mpie,
                                 3'b0, mstatus_mie,
                                 3'b0};

    always @(*) begin
        case (raddr_i)
            `CSR_MSTATUS:  rdata_o = mstatus_rdata;
            `CSR_MIE:      rdata_o = {31'b0, mie_mtie};
            `CSR_MTVEC:    rdata_o = {mtvec[31:2], mtvec[0], 1'b0};
            `CSR_MSCRATCH: rdata_o = mscratch;
            `CSR_MEPC:     rdata_o = mepc;
            `CSR_MCAUSE:   rdata_o = mcause;
            `CSR_MTVAL:    rdata_o = mtval;
            `CSR_MIP:      rdata_o = {31'b0, timer_irq_i};

            `CSR_MCYCLE:   rdata_o = mcycle[31:0];
            `CSR_MCYCLEH:  rdata_o = mcycle[63:32];
            `CSR_MINSTRET: rdata_o = minstret[31:0];
            `CSR_MINSTRETH:rdata_o = minstret[63:32];
            // 用户态计数器别名 (参考设计只暴露了 0xC00/0xC80 这两个)
            `CSR_CYCLE:    rdata_o = mcycle[31:0];
            `CSR_CYCLEH:   rdata_o = mcycle[63:32];
            `CSR_INSTRET:  rdata_o = minstret[31:0];
            `CSR_INSTRETH: rdata_o = minstret[63:32];

            // 未实现地址: Control.v 已经把它判成非法指令了, 这里的取值不重要,
            // 给 0 保证不会有 X 传播.
            default:       rdata_o = 32'b0;
        endcase
    end

endmodule
