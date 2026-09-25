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
          .cpu_rst            (fpga_rst),
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
