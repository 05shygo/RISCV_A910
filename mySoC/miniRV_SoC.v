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
      logic [31:0] inst_addr;       // ????
      logic [31:0] inst;           // ????
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
          .inst_addr          (inst_addr),        // ???????????
          .inst               (inst),
          .Bus_addr           (Bus_addr),
          .Bus_rdata          (Bus_rdata),
          .Bus_wen            (Bus_wen),
          .Bus_wdata          (Bus_wdata),
          .debug_wb_have_inst   (debug_wb_have_inst),   // ?????????
          .debug_wb_pc        (debug_wb_pc),
          .debug_wb_ena       (debug_wb_ena),
          .debug_wb_reg       (debug_wb_reg),
          .debug_wb_value     (debug_wb_value)
      );

     //just instantiate model and connect signals,don't creat IP core
      IROM Mem_IROM (
          .a          (inst_addr),
          .spo        (inst)
      );

      DRAM Mem_DRAM (
          .clk        (cpu_clk),
          .a          (Bus_addr[15:2]),
          .spo        (Bus_rdata),
          .we         (Bus_wen),
          .d          (Bus_wdata)
      );

  endmodule
