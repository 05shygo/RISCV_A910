`timescale 1ns / 1ps
`define STRINGIFY(x) `"x`"

module IROM # (
    ADDR_BITS = 16
)(
    input [ADDR_BITS - 1:0] a,
    output [31:0] spo
);

    integer i, j, mem_file;
    // (* RAM_STYLE="BLOCK" *)
    reg [32-1:0] mem[(2**20)-1:0];
    reg [32-1:0] mem_rd[(2**20)-1:0];
    initial begin
        // two nested loops for smaller number of iterations per loop
        // workaround for synthesizer complaints about large loop counts
        for (i = 0; i < 2**20; i = i + 2**(20/2)) begin
            for (j = i; j < i + 2**(20/2); j = j + 1) begin
                mem[j] = 0;
            end
        end
        mem_file = $fopen(`STRINGIFY(`PATH), "r");
        if(mem_file == 0) begin
            $display("[ERROR] Open file %s failed, please check whether file exists!\n", `STRINGIFY(`PATH));
            $fatal;
        end
        $display("[INFO] Instruction ROM initialized with %s", `STRINGIFY(`PATH));
        // mem_rd 必须先清零: $fread 只填镜像覆盖到的部分, 其余保持 X, 而下面
        // 会把 mem_rd 的【每个字】都赋给 mem[]. 不清零的话, 凡是读到镜像之外的
        // 地址都会得到 X, 与 golden model(零初始化)不一致 —— X 一旦进了寄存器就会
        // 让分支误判并一路传播, 表现为难以定位的 difftest 不匹配.
        for (i = 0; i < 2**20; i = i + 2**(20/2)) begin
            for (j = i; j < i + 2**(20/2); j = j + 1) begin
                mem_rd[j] = 0;
            end
        end
        $fread(mem_rd, mem_file);
        for (i = 0; i < 2**20; i = i + 2**(20/2)) begin
            for (j = i; j < i + 2**(20/2); j = j + 1) begin
                mem[j] = {{mem_rd[j][07:00]}, {mem_rd[j][15:08]}, {mem_rd[j][23:16]}, {mem_rd[j][31:24]}};
            end
        end
    end

    assign spo = mem[a];

endmodule

module DRAM # (
    ADDR_BITS = 16
)(
    input clk,
    input [ADDR_BITS - 1: 0] a,
    input we,
    input [31:0] d,
    output [31:0] spo
);

    integer i, j, mem_file;
    // (* RAM_STYLE="BLOCK" *)
    reg [32-1:0] mem[(2**20)-1:0];
    reg [32-1:0] mem_rd[(2**20)-1:0];
    initial begin
        // two nested loops for smaller number of iterations per loop
        // workaround for synthesizer complaints about large loop counts
        for (i = 0; i < 2**20; i = i + 2**(20/2)) begin
            for (j = i; j < i + 2**(20/2); j = j + 1) begin
                mem[j] = 0;
            end
        end
        mem_file = $fopen(`STRINGIFY(`PATH), "r");
        if(mem_file == 0) begin
            $display("[ERROR] Open file %s failed, please check whether file exists!\n", `STRINGIFY(`PATH));
            $fatal;
        end
        $display("[INFO] Data RAM initialized with %s", `STRINGIFY(`PATH));
        // 同 IROM: 先清零, 否则镜像之外的读会返回 X
        for (i = 0; i < 2**20; i = i + 2**(20/2)) begin
            for (j = i; j < i + 2**(20/2); j = j + 1) begin
                mem_rd[j] = 0;
            end
        end
        $fread(mem_rd, mem_file);
        for (i = 0; i < 2**20; i = i + 2**(20/2)) begin
            for (j = i; j < i + 2**(20/2); j = j + 1) begin
                mem[j] = {{mem_rd[j][07:00]}, {mem_rd[j][15:08]}, {mem_rd[j][23:16]}, {mem_rd[j][31:24]}};
            end
        end
    end

    assign spo = mem[a];

    always @(posedge clk) begin
        if (we) mem[a] <= d;
    end

endmodule
