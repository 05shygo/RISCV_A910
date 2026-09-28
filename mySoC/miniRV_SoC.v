/*module miniRV_SoC (
    input  logic         fpga_rst,   // High active
    input  logic         fpga_clk,

    output logic         debug_wb_have_inst, // 
    output logic [31:0]  debug_wb_pc,        // 
    output               debug_wb_ena,       // 
    output logic [ 4:0]  debug_wb_reg,       // 
    output logic [31:0]  debug_wb_value      // 

);
    logic        cpu_clk = fpga_clk;
    logic        inst_addr	   ;
    logic        inst		   ;
    logic	Bus_addr	   ;
    logic	Bus_rdata	   ;
    logic	Bus_wen		   ;
    logic	Bus_wdata	   ;
    logic	debug_wb_have_i	   ;
    logic	debug_wb_pc	   ;
    logic	 debug_wb_ena	   ;
    logic	debug_wb_reg	   ;
    logic	debug_wb_value     ;   
 
    myCPU Core_cpu (
        .cpu_rst            (fpga_rst),
        .cpu_clk            (cpu_clk),
        
	inst_addr	     (inst_addr),	    
	inst        	     (inst), 
	               
	Bus_addr	     (Bus_addr), 	
	Bus_rdata	     (Bus_rdata),
        Bus_wen		     (Bus_wen),
	Bus_wdata	     (Bus_wdata),
                                                 
        debug_wb_have_i	     (debug_wb_have_i),   
        debug_wb_pc	     (debug_wb_pc),   
         debug_wb_ena	     (debug_wb_ena),   
        debug_wb_reg	     (debug_wb_reg),   
        debug_wb_value       (debug_wb_value)  
    );
    
   //just instantiate model and connect signals,don't creat IP core  
    IROM Mem_IROM (
        .a          (inst_addr),
        .spo        (inst)
    );

    DRAM Mem_DRAM (
        .clk        (cpu_clk),
        .a          (Bus_addr),
        .spo        (Bus_rdata),
        .we         (Bus_wen),
        .d          (Bus_wdata)
    );

endmodule
*/
module miniRV_SoC (
      input  logic         fpga_rst,   // High active
      input  logic         fpga_clk,

      output logic         debug_wb_have_inst, //
      output logic [31:0]  debug_wb_pc,        //
      output logic         debug_wb_ena,       //
      output logic [ 4:0]  debug_wb_reg,       //
      output logic [31:0]  debug_wb_value      //
  );
      logic        cpu_clk = fpga_clk;

      // -----------------------------------------------------------------------
      // 复位同步器 (异步置位 / 同步释放)
      //
      // 综合报告 (fmax 12.2ns) 里第二组违例就是复位: rst 一根网扇出 **3342 个
      // CLR 端**, 那条 recovery 路径 12.37 ns 里 94% 是布线, 逻辑只有一级 IBUF ——
      // 病根不是逻辑多, 而是**一个输入端口直接扇出到两千多个触发器**: IBUF 不
      // 能被复制, 工具没法给它做高扇出拆分 (它只会复制寄存器)。
      //
      // 过一级寄存器就有两个作用:
      //   1. 输出是**寄存器** ⇒ 工具可以按区域自由复制, 布线长度塌下来;
      //   2. 释放沿由 clk 同步 ⇒ 它相对时钟的恢复/去除窗口天然满足, recovery 检查
      //      不再是"输入延迟 2ns + 未知到达时刻"那种碰运气的东西。
      // **断言仍然是异步的** (posedge fpga_rst 直接置位), 所以复位行为不变;
      // 只有**释放**晚一拍 ⇒ 核晚一拍开始干活。
      //
      // ⚠️ 这一拍是**常数**: CoreMark 的 Total ticks 是程序自己按 mtime 量的, 会
      //    自己抵消; 而 tb 的周期计数器会整体 +1, 与历史基线比较时要记得减掉。
      // ⚠️ 只给 CPU 用, **不要**给 perip_bridge —— 那边的 mtime 是 tb 直接采样去
      //    与黄金模型对齐的 (tb 里那句 mtime_d1), 动它会平移 mmio 时间戳。
      // -----------------------------------------------------------------------
      (* max_fanout = 200 *) logic rst_cpu;
      always @(posedge cpu_clk or posedge fpga_rst) begin
          if (fpga_rst) rst_cpu <= 1'b1;
          else          rst_cpu <= 1'b0;
      end

`ifndef USE_IFU_ANY
      logic [31:0] inst_addr;       // ????
      logic [31:0] inst;           // ????
`endif
      logic [31:0] Bus_addr;       // ????
      logic [31:0] Bus_rdata;      // ????
      logic        Bus_wen;
      logic [31:0] Bus_wdata;      // ????

      // ????????????????????????
      // logic        debug_wb_have_i;
      // logic [31:0] debug_wb_pc;
      // logic        debug_wb_ena;
      // logic [ 4:0] debug_wb_reg;
      // logic [31:0] debug_wb_value;

      myCPU Core_cpu (
          .cpu_rst            (rst_cpu),      // 见上面复位同步器 (不是 fpga_rst)
          .cpu_clk            (cpu_clk),
`ifndef USE_IFU_ANY
          .inst_addr          (inst_addr),        // ???????????
          .inst               (inst),
`endif
          .Bus_addr           (Bus_addr),
          .Bus_rdata          (Bus_rdata),
          .Bus_wen            (Bus_wen),
          .Bus_wdata          (Bus_wdata),
          // 定时器中断请求: 由 perip_bridge 的 timer_int_flag 驱动(mtime>=mtimecmp).
          // CPU 内部会再打一拍后使用, 与 TB 推给 golden model 的信号同源同级.
          // (timer_int_flag 在本文件后面才声明, Verilog 里先后顺序无所谓)
          .timer_irq_in       (timer_int_flag),
          .debug_wb_have_inst   (debug_wb_have_inst),   // ?????????
          .debug_wb_pc        (debug_wb_pc),
          .debug_wb_ena       (debug_wb_ena),
          .debug_wb_reg       (debug_wb_reg),
          .debug_wb_value     (debug_wb_value)
      );

`ifndef USE_IFU_ANY
     //just instantiate model and connect signals,don't creat IP core
      IROM Mem_IROM (
          .a          (inst_addr),
          .spo        (inst)
      );
`endif

      // 数据总线经外设桥: MMIO 地址(MONITOR/DIG/TIMER)不再被截断进 DRAM
      logic        dram_we;
      logic [15:0] dram_word_addr;
      logic [31:0] dram_wdata;
      logic [31:0] dram_rdata;
      logic [31:0] seg_value;        // 数码管, 留给板级顶层
      logic        timer_int_flag;   // 已接入 myCPU.timer_irq_in (MTIP 中断源)

      perip_bridge u_bridge (
          .clk            (cpu_clk),
          .rst            (fpga_rst),
          .Bus_addr       (Bus_addr),
          .Bus_wen        (Bus_wen),
          .Bus_wdata      (Bus_wdata),
          .Bus_rdata      (Bus_rdata),
          .dram_we        (dram_we),
          .dram_word_addr (dram_word_addr),
          .dram_wdata     (dram_wdata),
          .dram_rdata     (dram_rdata),
          .seg_value      (seg_value),
          .timer_int_flag (timer_int_flag)
      );

      DRAM Mem_DRAM (
          .clk        (cpu_clk),
          .a          (dram_word_addr),
          .spo        (dram_rdata),
          .we         (dram_we),
          .d         (dram_wdata)
      );

  endmodule
