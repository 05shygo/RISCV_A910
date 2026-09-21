#ifndef TEST_END_H
#define TEST_END_H

// MONITOR peripheral address for test result reporting
#define MONITOR_ADDR    ((volatile unsigned int*)0x80000000)

// Test result flags
#define TEST_PASS_FLAG  0x0000BEEF  // Test passed
#define TEST_FAIL_FLAG  0x0000DEAD  // Test failed

// Report test result via MONITOR peripheral
static inline void report_test_result(int pass) {
    if (pass) {
        *MONITOR_ADDR = TEST_PASS_FLAG;
    } else {
        *MONITOR_ADDR = TEST_FAIL_FLAG;
    }
}

// End simulation
static inline void sim_end(int pass) {
    report_test_result(pass);
    // Infinite loop to stop CPU
    while(1) {
        *MONITOR_ADDR = pass ? TEST_PASS_FLAG : TEST_FAIL_FLAG;
    }
}

#endif // TEST_END_H
