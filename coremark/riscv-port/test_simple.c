// Minimal test to check if CPU can execute basic code
volatile unsigned int *monitor = (volatile unsigned int *)0x80000000;

void _start() {
    // Write test pattern to monitor
    *monitor = 0x12345678;
    *monitor = 0xAAAAAAAA;
    *monitor = 0x55555555;
    *monitor = 0xDEADBEEF;
    
    // Infinite loop
    while(1) {
        *monitor = 0x11111111;
    }
}
