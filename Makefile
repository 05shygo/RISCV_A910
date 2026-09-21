# VCS + Verdi Makefile for miniRV testing - COMPLETE VERSION
# Usage: make vcs_fsdb TEST=addi

# Source files - INCLUDING VCS TOP MODULE
VSRC = $(wildcard vsrc/ram.v mySoC/*.v)
CSRC = $(wildcard golden_model/*.c) $(wildcard golden_model/stage/*.c) $(wildcard golden_model/peripheral/*.c) csrc/test_vcs.cpp

# Test configuration
TEST = addi
TESTFILE = meminit.bin
PWD = $(shell pwd)

# VCS compilation options - WITH -no_main AND INCLUDE PATH
VCS_OPTS = -full64 -timescale=1ns/1ps -sverilog +v2k +define+PATH=$(TESTFILE) +incdir+$(PWD)/mySoC 

# VCS runtime options
VCS_RUN_OPTS = +define+PATH=$(TESTFILE)

# Directories
WAVE_DIR = waveform
SIM_DIR = simv_work

# Default target
all: vcs_build

# Check VCS installation first
check_tools:
	@echo "=== Checking VCS installation ==="
	@which vcs > /dev/null 2>&1 || (echo "ERROR: vcs not found in PATH" && exit 1)
	@echo "VCS found: $$(which vcs)"
	@vcs -Version | head -1 || echo "WARNING: Cannot get VCS version"
	@echo "=== Checking Verdi installation ==="
	@which verdi > /dev/null 2>&1 || echo "WARNING: verdi not found (waveform viewing won't work)"
	@echo "================================="

# VCS compilation target - COMPLETE
vcs_build: check_tools $(VSRC) $(CSRC)
	@mkdir -p $(WAVE_DIR) $(SIM_DIR)
	@echo "=== Compiling with VCS ==="
	@echo "Source files:"
	@echo "  Verilog: $(VSRC)"
	@echo "  C/C++:   $(CSRC)"
	@echo "Options:   $(VCS_OPTS)"
	vcs $(VCS_OPTS) $(VSRC) -top vcs_top $(CSRC) \
		-CFLAGS -std=c99 -DPATH=$(TESTFILE) -CFLAGS -I$(PWD)/golden_model/include
	@echo "=== Compilation completed ==="

# VCS simulation without waveform
vcs_run: vcs_build
	@echo "=== Running simulation (no waveform) ==="
	@ln -sf bin/$(TEST).bin $(TESTFILE)
	@./simv $(TEST) $(VCS_RUN_OPTS)
	@result=$$?; rm -f $(TESTFILE); exit $$result

# VCS simulation with VCD waveform
vcs_vcd: vcs_build
	@echo "=== Running simulation with VCD waveform ==="
	@ln -sf bin/$(TEST).bin $(TESTFILE)
	@./simv $(TEST) $(VCS_RUN_OPTS) +vcd+$(WAVE_DIR)/$(TEST).vcd
	@result=$$?; rm -f $(TESTFILE); exit $$result

# VCS simulation with FSDB waveform (for Verdi)
vcs_fsdb: vcs_build
	@echo "=== Running simulation with FSDB waveform ==="
	@ln -sf bin/$(TEST).bin $(TESTFILE)
	@./simv $(TEST) $(VCS_RUN_OPTS) +fsdb+$(WAVE_DIR)/$(TEST).fsdb
	@result=$$?; rm -f $(TESTFILE); exit $$result

# Simple test to verify VCS works
test_vcs:
	@echo "Testing VCS with simple command..."
	vcs -help | head -3

# Open waveform with Verdi
verdi: $(WAVE_DIR)/$(TEST).fsdb
	@echo "Opening waveform with Verdi..."
	verdi -ssf $(WAVE_DIR)/$(TEST).fsdb &

# Open waveform with Verdi (specify test)
verdi_%: $(WAVE_DIR)/%.fsdb
	@echo "Opening waveform: $(WAVE_DIR)/$*.fsdb"
	verdi -ssf $(WAVE_DIR)/$*.fsdb &

# Batch run all tests with waveform
run_all_fsdb:
	@echo "=== Running all tests with FSDB wave generation ==="
	@success=0; fail=0; \
	for test in $$(ls bin/*.bin | sed 's|bin/||' | sed 's|\.bin||'); do \
		echo "Running test: $$test"; \
		if make vcs_fsdb TEST=$$test; then \
			success=$$((success + 1)); \
			echo "? $$test PASSED"; \
		else \
			fail=$$((fail + 1)); \
			echo "? $$test FAILED"; \
		fi; \
		echo "---"; \
	done; \
	echo "=== SUMMARY ==="; \
	echo "Total tests: $$(success + fail)"; \
	echo "Passed: $$success"; \
	echo "Failed: $$fail"; \
	echo "Waveforms saved in $(WAVE_DIR)/"

# Run all tests with VCD (faster, for debugging)
run_all_vcd:
	@echo "=== Running all tests with VCD wave generation ==="
	@for test in $$(ls bin/*.bin | sed 's|bin/||' | sed 's|\.bin||'); do \
		echo "Running test: $$test"; \
		make vcs_vcd TEST=$$test || echo "Test $$test failed"; \
	done
	@echo "All tests completed. Waveforms saved in $(WAVE_DIR)/"

# Clean generated files
clean:
	@echo "Cleaning generated files..."
	rm -rf simv* csrc/*.daidir $(WAVE_DIR) $(SIM_DIR) $(TESTFILE) \
	       ucli.key vc_hdrs.h DVEfiles inter.vpd .vlogansetup.env \
	       .vlogansetup.args .vlogansetup.env.out AN.DB
	@echo "Clean completed."

# Clean only waveforms
clean_wave:
	@echo "Cleaning waveform files..."
	rm -rf $(WAVE_DIR)/*.fsdb $(WAVE_DIR)/*.vcd
	@echo "Waveform files cleaned."

# Help target
help:
	@echo "Available targets:"
	@echo "  check_tools  - Check VCS/Verdi installation"
	@echo "  test_vcs     - Simple VCS test"
	@echo "  vcs_build    - Compile with VCS"
	@echo "  vcs_run      - Run simulation without waveform"
	@echo "  vcs_vcd      - Run simulation with VCD waveform"
	@echo "  vcs_fsdb     - Run simulation with FSDB waveform (Verdi)"
	@echo "  verdi        - Open waveform with Verdi (uses TEST variable)"
	@echo "  run_all_vcd  - Run all tests with VCD waves (faster)"
	@echo "  run_all_fsdb - Run all tests with FSDB wave generation"
	@echo "  clean        - Clean all generated files"
	@echo "  clean_wave   - Clean only waveform files"
	@echo ""
	@echo "Example usage:"
	@echo "  make check_tools          # Check installation"
	@echo "  make test_vcs             # Test VCS"
	@echo "  make vcs_vcd TEST=addi    # Run with VCD (try first)"
	@echo "  make vcs_fsdb TEST=addi   # Run with FSDB (for Verdi)"
	@echo "  make verdi TEST=addi      # Open waveform in Verdi"
	@echo "  make run_all_vcd          # Run all tests (faster)"

.PHONY: all check_tools test_vcs vcs_build vcs_run vcs_fsdb vcs_vcd verdi run_all_fsdb run_all_vcd clean clean_wave help
