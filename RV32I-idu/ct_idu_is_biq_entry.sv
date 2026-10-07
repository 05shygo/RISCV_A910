module ct_idu_is_biq_entry (
    input  logic         cpurst_b,
    input  logic         ctrl_biq_rf_pop_vld,
    input  logic         forever_cpuclk,
    input  logic [5:0]   iu_idu_ex2_pipe0_wb_preg_dupx,
    input  logic         iu_idu_ex2_pipe0_wb_preg_vld_dupx,
    input  logic [5:0]   iu_idu_ex2_pipe1_wb_preg_dupx,
    input  logic         iu_idu_ex2_pipe1_wb_preg_vld_dupx,
    input  logic [5:0]   lsu_idu_wb_pipe3_wb_preg_dupx,
    input  logic         lsu_idu_wb_pipe3_wb_preg_vld_dupx,
    input  logic         rtu_yy_xx_flush,
    input  logic [2:0]   x_create_agevec,
    input  logic [126:0] x_create_data,
    input  logic         x_create_en,
    input  logic         x_pop_cur_entry,
    input  logic [2:0]   x_pop_other_entry,
    output logic         x_rdy,
    output logic [2:0]   x_agevec,
    output logic [126:0] x_read_data,
    output logic         x_vld
);

    //==========================================================
    //                       Parameters
    //==========================================================
parameter BIQ_WIDTH             = 127;
parameter BIQ_PC                = 126;
parameter BIQ_IID               = 61;
parameter BIQ_DST_PREG          = 54;
parameter BIQ_SRC1_DATA         = 48;
parameter BIQ_SRC0_DATA         = 41;
parameter BIQ_DST_VLD           = 34;
parameter BIQ_SRC1_VLD          = 33;
parameter BIQ_SRC0_VLD          = 32;
parameter BIQ_OPCODE            = 31;

    //==========================================================
    //                    Internal Signals
    //==========================================================
    logic         vld;
    logic [2:0]   agevec;
    logic [31:0]  opcode;
    logic [6:0]   iid;
    logic         src0_vld;
    logic         src1_vld;
    logic         dst_vld;
    
    // 【补齐】以下两个信号在 always_ff 块中被赋值，但未声明
    logic [5:0]   dst_preg;  
    logic [64:0]  pc;        
    
    logic [6:0]   dst_data;        // 注：原代码中声明了但未使用，可能是 dst_preg 的笔误
    logic [6:0]   create_src0_data;
    logic [6:0]   create_src1_data;
    logic [6:0]   read_src0_data;
    logic [6:0]   read_src1_data;

    // 【补齐】底部 assign 中使用到的就绪信号
    logic         src0_rdy_for_issue;
    logic         src1_rdy_for_issue;

    // 内部时钟（原代码中未生成，保持声明以匹配原逻辑）
    logic         entry_clk;
    logic         create_preg_clk;
    logic         create_clk;

    //==========================================================
    //                      Entry Valid
    //==========================================================
    assign x_vld = vld;

    always_ff @(posedge entry_clk or negedge cpurst_b) begin
        if (!cpurst_b)
            vld <= 1'b0;
        else if (rtu_yy_xx_flush)
            vld <= 1'b0;
        else if (x_create_en)
            vld <= 1'b1;
        else if (ctrl_biq_rf_pop_vld && x_pop_cur_entry)
            vld <= 1'b0;
        else
            vld <= vld;
    end

    //==========================================================
    //                       Age Vector
    //==========================================================
    assign x_agevec[2:0] = agevec[2:0];

    always_ff @(posedge entry_clk or negedge cpurst_b) begin
        if (!cpurst_b)
            agevec[2:0] <= 3'b0;
        else if (x_create_en)
            agevec[2:0] <= x_create_agevec[2:0];
        else if (ctrl_biq_rf_pop_vld)
            agevec[2:0] <= agevec[2:0] & ~x_pop_other_entry[2:0];
        else
            agevec[2:0] <= agevec[2:0];
    end

    //==========================================================
    //                 Instruction Information
    //==========================================================
    always_ff @(posedge create_clk or negedge cpurst_b) begin
        if (!cpurst_b) begin
            opcode[31:0]  <= 32'b0;
            iid[6:0]      <= 7'b0;
            src0_vld      <= 1'b0;
            src1_vld      <= 1'b0;
            dst_vld       <= 1'b0;
            dst_preg[5:0] <= 6'b0;  // 补齐后此处不再报错
            pc[64:0]      <= 65'b0; // 补齐后此处不再报错
        end
        else if (x_create_en) begin
            opcode[31:0]  <= x_create_data[BIQ_OPCODE:BIQ_OPCODE-31];
            iid[6:0]      <= x_create_data[BIQ_IID:BIQ_IID-6];
            src0_vld      <= x_create_data[BIQ_SRC0_VLD];
            src1_vld      <= x_create_data[BIQ_SRC1_VLD];
            dst_vld       <= x_create_data[BIQ_DST_VLD];
            dst_preg[5:0] <= x_create_data[BIQ_DST_PREG:BIQ_DST_PREG-5];
            pc[64:0]      <= x_create_data[BIQ_PC:BIQ_PC-64];
        end
        else begin
            opcode[31:0]  <= opcode[31:0];
            iid[6:0]      <= iid[6:0];
            src0_vld      <= src0_vld;
            src1_vld      <= src1_vld;
            dst_vld       <= dst_vld;
            dst_preg[5:0] <= dst_preg[5:0];
            pc[64:0]      <= pc[64:0];
        end
    end

    // rename for read output
    assign x_read_data[BIQ_OPCODE:BIQ_OPCODE-31]     = opcode[31:0];
    assign x_read_data[BIQ_IID:BIQ_IID-6]            = iid[6:0];
    assign x_read_data[BIQ_SRC0_VLD]                 = src0_vld;
    assign x_read_data[BIQ_SRC1_VLD]                 = src1_vld;
    assign x_read_data[BIQ_DST_VLD]                  = dst_vld;
    assign x_read_data[BIQ_DST_PREG:BIQ_DST_PREG-5]  = dst_preg[5:0];
    assign x_read_data[BIQ_PC:BIQ_PC-64]             = pc[64:0];

    //==========================================================
    //              Source Dependency Information
    //==========================================================
    //------------------------source 0--------------------------
    assign create_src0_data[6:0] = x_create_data[BIQ_SRC0_DATA:BIQ_SRC0_DATA-6];

    //----------------------------------------------------------------------
    // Instance : ct_idu_dep_reg_entry
    // Desc     : 依赖寄存器 entry（写端口来自 ex2/wb pipe0/1/pipe3，读端口给 x）
    //----------------------------------------------------------------------
    ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src0 (
        .cpurst_b                         (cpurst_b                         ),
        .forever_cpuclk                   (forever_cpuclk                   ),

        // 写端口：IU pipe0 ex2 wb
        .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
        .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

        // 写端口：IU pipe1 ex2 wb
        .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
        .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

        // 写端口：LSU pipe3 wb
        .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
        .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

        // flush
        .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

        // 写数据 / 写使能
        .x_create_data                    (create_src0_data[6:0]            ),
        .x_write_en                       (x_create_en                      ),

        // 读数据
        .x_read_data                      (read_src0_data[6:0]              )
    );

    assign x_read_data[BIQ_SRC0_DATA:BIQ_SRC0_DATA-6] = read_src0_data[6:0];

    //------------------------source 1--------------------------
    assign create_src1_data[6:0] = x_create_data[BIQ_SRC1_DATA:BIQ_SRC1_DATA-6];

    //----------------------------------------------------------------------
    // Instance : ct_idu_dep_reg_entry
    // Desc     : 依赖寄存器 entry（写端口来自 ex2/wb pipe0/1/pipe3，读端口给 x）
    //----------------------------------------------------------------------
    ct_idu_dep_reg_entry u_ct_idu_dep_reg_entry_src1 (
        .cpurst_b                         (cpurst_b                         ),
        .forever_cpuclk                   (forever_cpuclk                   ),

        // 写端口：IU pipe0 ex2 wb
        .iu_idu_ex2_pipe0_wb_preg_dupx    (iu_idu_ex2_pipe0_wb_preg_dupx    ),
        .iu_idu_ex2_pipe0_wb_preg_vld_dupx(iu_idu_ex2_pipe0_wb_preg_vld_dupx),

        // 写端口：IU pipe1 ex2 wb
        .iu_idu_ex2_pipe1_wb_preg_dupx    (iu_idu_ex2_pipe1_wb_preg_dupx    ),
        .iu_idu_ex2_pipe1_wb_preg_vld_dupx(iu_idu_ex2_pipe1_wb_preg_vld_dupx),

        // 写端口：LSU pipe3 wb
        .lsu_idu_wb_pipe3_wb_preg_dupx    (lsu_idu_wb_pipe3_wb_preg_dupx    ),
        .lsu_idu_wb_pipe3_wb_preg_vld_dupx(lsu_idu_wb_pipe3_wb_preg_vld_dupx),

        // flush
        .rtu_yy_xx_flush                 (rtu_yy_xx_flush                 ),

        // 写数据 / 写使能
        .x_create_data                    (create_src1_data[6:0]            ),
        .x_write_en                       (x_create_en                      ),

        // 读数据
        .x_read_data                      (read_src1_data[6:0]              )
    );

    assign x_read_data[BIQ_SRC1_DATA:BIQ_SRC1_DATA-6] = read_src1_data[6:0];

    //==========================================================
    //                  Entry Ready Signal
    //==========================================================
    assign src0_rdy_for_issue = read_src0_data[0];
    assign src1_rdy_for_issue = read_src1_data[0];

    assign x_rdy = vld
                   && src0_rdy_for_issue
                   && src1_rdy_for_issue;

endmodule