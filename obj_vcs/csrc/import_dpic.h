
 extern void gm_init(/* INPUT */const char* path);

 extern int gm_check_step(/* INPUT */int dut_wb_have_inst, /* INPUT */int dut_wb_pc, /* INPUT */int dut_wb_ena, /* INPUT */int dut_wb_reg, /* INPUT */int dut_wb_value, /* INPUT */int dut_wb_irq_safe);

 extern int gm_halted();

 extern int gm_exit_code();

 extern void gm_set_cycle(/* INPUT */int c);

 extern void gm_set_timer(/* INPUT */int lo, /* INPUT */int hi);

 extern void gm_set_irq(/* INPUT */int pending);

 extern int gm_check_csr(/* INPUT */int dut_mstatus, /* INPUT */int dut_mie, /* INPUT */int dut_mtvec, /* INPUT */int dut_mscratch, /* INPUT */int dut_mepc, /* INPUT */int dut_mcause, /* INPUT */int dut_mtval, /* INPUT */int dut_mip);
