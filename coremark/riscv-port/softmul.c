// Software implementation of multiply and divide for RV32I
// These functions are needed when using -march=rv32i without M extension

typedef unsigned int uint32_t;
typedef int int32_t;

// Software multiply
int32_t __mulsi3(int32_t a, int32_t b) {
    int32_t result = 0;
    int negative = 0;
    
    if (a < 0) { a = -a; negative = !negative; }
    if (b < 0) { b = -b; negative = !negative; }
    
    while (b > 0) {
        if (b & 1) result += a;
        a <<= 1;
        b >>= 1;
    }
    
    return negative ? -result : result;
}

// Software unsigned divide
uint32_t __udivsi3(uint32_t n, uint32_t d) {
    if (d == 0) return 0xFFFFFFFF; // Division by zero
    
    uint32_t q = 0;
    uint32_t r = 0;
    
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
            q |= (1U << i);
        }
    }
    return q;
}

// Software unsigned modulo
uint32_t __umodsi3(uint32_t n, uint32_t d) {
    if (d == 0) return n;
    
    uint32_t r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) r -= d;
    }
    return r;
}

// Software signed divide
int32_t __divsi3(int32_t n, int32_t d) {
    if (d == 0) return n >= 0 ? 0x7FFFFFFF : 0x80000000;
    
    int negative = 0;
    if (n < 0) { n = -n; negative = !negative; }
    if (d < 0) { d = -d; negative = !negative; }
    
    uint32_t q = __udivsi3((uint32_t)n, (uint32_t)d);
    return negative ? -(int32_t)q : (int32_t)q;
}

// Software signed modulo
int32_t __modsi3(int32_t n, int32_t d) {
    if (d == 0) return n;
    
    int negative = n < 0;
    if (n < 0) n = -n;
    if (d < 0) d = -d;
    
    uint32_t r = __umodsi3((uint32_t)n, (uint32_t)d);
    return negative ? -(int32_t)r : (int32_t)r;
}
