module ct_lsu_cache_buffer (
    input  logic         cpurst_b,
    input  logic [4:0]   dcache_idx,
    input  logic         forever_cpuclk,
    input  logic [127:0] ld_da_cb_data,
    input  logic         ld_da_cb_data_vld,
    input  logic         ld_da_cb_ld_inst_vld,
    input  logic [27:0]  ld_dc_addr1_to4,
    input  logic         ld_dc_cb_addr_create_vld,
    input  logic [27:0]  ld_dc_cb_addr_tto4,
    input  logic         lsu_dcache_ld_xx_gwen,
    output logic [127:0] cb_ld_da_data,
    output logic         cb_ld_da_data_vld,
    output logic         cb_ld_dc_addr_hit
);

    logic [27:0]  cb_addr_tto4;
    logic [127:0] cb_data;
    logic         cb_vld;

    logic         cb_addr_hit_idx;
    logic         cb_addr_create_vld;
    logic         cb_data_create_vld;
    logic         cb_create_vld;
    logic         cb_pop_vld;
    logic [27:0]  cb_cmp_ld_dc_addr1;

    //==========================================================
    //            control signal
    //==========================================================
    assign cb_addr_hit_idx    = (cb_addr_tto4[5:1]  ==  dcache_idx[4:0]);
    assign cb_addr_create_vld = ld_dc_cb_addr_create_vld;
    assign cb_data_create_vld = ld_da_cb_data_vld;
    assign cb_create_vld      = cb_data_create_vld;
    assign cb_pop_vld         = ld_da_cb_ld_inst_vld 
                                   && !ld_da_cb_data_vld
                                || lsu_dcache_ld_xx_gwen
                                   && cb_addr_hit_idx;  

    //==========================================================
    //                 Register
    //==========================================================
    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cb_vld <= 1'b0;
        else if (cb_pop_vld)
            cb_vld <= 1'b0;
        else if (cb_create_vld)
            cb_vld <= 1'b1;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cb_addr_tto4 <= 28'b0;
        else if (cb_addr_create_vld)
            cb_addr_tto4 <= ld_dc_cb_addr_tto4;
    end

    always_ff @(posedge forever_cpuclk or negedge cpurst_b) begin
        if (!cpurst_b)
            cb_data[127:0] <= 128'b0;
        else if (cb_data_create_vld)
            cb_data[127:0] <= ld_da_cb_data[127:0];
    end

    //==========================================================
    //            Generage to ld dc signal
    //==========================================================
    assign cb_cmp_ld_dc_addr1 = ld_dc_addr1_to4;
    assign cb_ld_dc_addr_hit = cb_addr_tto4[27:0] == cb_cmp_ld_dc_addr1[27:0];

    //==========================================================
    //            Generage to ld da signal
    //==========================================================
    assign cb_ld_da_data[127:0] = cb_data[127:0];
    assign cb_ld_da_data_vld    = cb_vld;

endmodule