#!/bin/bash

echo "========================================"
echo "RV32M (Multiply/Divide) Test Suite"
echo "========================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cd /x2025/GPrj1/IC1/riscv/RISCV_CPU/cdp-tests

# Test 1: MUL instruction
echo "----------------------------------------"
echo "Test 1: MUL (10 × 7 = 70)"
echo "----------------------------------------"
make run TEST=mul MAX_CYCLES=1000 WAVE=mul_test 2>&1 | tee test_mul.log

if grep -q "Test Point Pass" test_mul.log || grep -q "ECALL.*0x00000024" test_mul.log; then
    echo -e "${GREEN}✓ MUL test completed${NC}"
    echo "Check: grep 'ECALL' test_mul.log"
else
    echo -e "${RED}✗ MUL test may have issues${NC}"
fi

echo ""
echo "Waveform saved to: waveform/mul_test.fsdb"
echo ""

# Test 2: DIV instruction
echo "----------------------------------------"
echo "Test 2: DIV (100 ÷ 7 = 14)"
echo "----------------------------------------"
make run TEST=div MAX_CYCLES=50000 WAVE=div_test 2>&1 | tee test_div.log

if grep -q "Test Point Pass" test_div.log || grep -q "ECALL.*0x00000024" test_div.log; then
    echo -e "${GREEN}✓ DIV test completed${NC}"
    echo "Check: grep 'ECALL' test_div.log"
else
    echo -e "${RED}✗ DIV test may have issues${NC}"
fi

echo ""
echo "Waveform saved to: waveform/div_test.fsdb"
echo ""

# Summary
echo "========================================"
echo "Test Summary"
echo "========================================"
echo ""
echo "Test logs:"
echo "  - test_mul.log (MUL test)"
echo "  - test_div.log (DIV test)"
echo ""
echo "Waveforms (open with Verdi):"
echo "  - waveform/mul_test.fsdb"
echo "  - waveform/div_test.fsdb"
echo ""
echo "To view waveforms:"
echo "  make verdi WAVE=mul_test"
echo "  make verdi WAVE=div_test"
echo ""
echo "Key signals to check in waveform:"
echo "  - dut.Core_cpu.U_MUL_DIV.valid_i"
echo "  - dut.Core_cpu.U_MUL_DIV.ready_o"
echo "  - dut.Core_cpu.U_MUL_DIV.result"
echo "  - dut.Core_cpu.muldiv_stall"
echo "  - dut.Core_cpu.stall"
echo ""
echo "Documentation:"
echo "  - RV32M_IMPLEMENTATION.md (implementation details)"
echo "  - RV32M_DEBUG_GUIDE.md (debugging guide)"
echo "  - GOLDEN_MODEL_ANALYSIS.md (golden model analysis)"
echo ""
