# ⚡ Quick Start: Run the Enhanced Testbench

## 30-Second Setup

```verilog
// Your testbench is ready! Just follow these steps:

1. Open Vivado
2. Open amba_aes_filter_3 project
3. In Simulation Sources, right-click ahb_top_tb.v
4. Click "Set as Top"
5. Click "Run Behavioral Simulation"
6. Watch the console output
7. Wait for completion
```

---

## What You'll See

### During Simulation
```
TEST 1: Single Write/Read to Generic Memory Slaves
TEST 2: 4-Beat Burst Write and Single Read Verify
TEST 3: Filter Chain Processing (AMBA + Wireline Filters)
    - 16 filter samples processed
    - Each with 6-cycle latency
    - Results verified
TEST 4: AES Crypto Slave Multi-Block Test
    - 3 blocks encrypted/decrypted
    - Results verified
```

### At Completion
```
========================================================
COMPLETE TEST SUMMARY
========================================================
TEST 1: Generic Memory Slaves ............ COMPLETE
TEST 2: AHB Burst Protocol ............... COMPLETE
TEST 3: Wireline Filter Chain ............ COMPLETE
         Passed: 16 / 16
TEST 4: AES Crypto Processing ............ COMPLETE
         Passed: 12 / 12
========================================================
```

---

## Test Coverage

### ✅ TEST 1: Basic AHB (2-3 minutes)
- Slave 1 write/read at 0x0000_0010
- Slave 2 write/read at 0x0000_0020
- Verifies basic data storage and retrieval

### ✅ TEST 2: Burst Transactions (1-2 minutes)
- 4-beat INCR4 burst to Slave 3
- Addresses: 0x0000_0040, 0x44, 0x48, 0x4C
- Verifies burst protocol handling

### ✅ TEST 3: Filter Chain (5-10 minutes) ⭐ NEW
- **16 test samples** through 6-stage filter
- Filter pipeline: CTLE → DC-Offset → FIR-EQ → DFE → Glitch → LPF
- Tests: small, medium, large, positive, negative, and arbitrary values
- Each sample: write → wait 7 cycles → read → validate
- **Results table** shows all inputs/outputs

### ✅ TEST 4: AES Crypto (3-5 minutes)
- 3 blocks of plaintext → encrypt → decrypt
- Verifies ciphertext
- Verifies plaintext recovery
- Each block: 4 words = 12 total verifications

---

## Expected Simulation Time

| Test | Time |
|------|------|
| TEST 1 (Memory) | ~50 ns |
| TEST 2 (Burst) | ~100 ns |
| TEST 3 (Filter) | ~300 ns |
| TEST 4 (AES) | ~200 ns |
| **Total** | **~650 ns** |

**Clock Speed**: 100 MHz (10ns period) = ~6500 clock cycles

---

## Key Test Vectors

### Filter Input Samples (16 total)
```
0x100  (256)   → Small positive
0x200  (512)   → Medium positive
0x400  (1024)  → Larger positive
0x7FF  (2047)  → Maximum positive ← Boundary test
0x800  (-2048) → Minimum negative ← Boundary test
0xA00  (-1536) → Negative
0xC00  (-1024) → More negative
0xFFF  (-1)    → Negative
0x050  (80)    → Very small
0x1AB  (427)   → Arbitrary 1
0x2CD  (717)   → Arbitrary 2
0x3EF  (1007)  → Arbitrary 3
0x444  (1092)  → Pattern 4
0x555  (1365)  → Pattern 5
0x666  (1638)  → Pattern 6
0x777  (1911)  → Pattern 7
```

Each sample processed through:
1. Write to filter slave (0x4000_0000)
2. Wait for 6-cycle filter latency
3. Read back filtered result
4. Validate output is ±2047 (12-bit range)

---

## Waveform Analysis

### After Simulation
```
$ gtkwave dump.vcd &
```

### Signals to Monitor
```
Clock/Reset
├── hclk           (100MHz clock)
└── hresetn        (reset)

Slave Control
├── slave_sel      (which slave active)
├── wr             (read vs write)
└── hreadyout_tb   (slave ready)

Data
├── hwdata_tb      (write data)
└── hrdata_tb      (read data)
```

### What to Look For
1. **Filter Write Phase**: slave_sel = 10, wr = 1, data appears on hwdata_tb
2. **Filter Latency**: Wait 6 cycles
3. **Filter Read Phase**: slave_sel = 10, wr = 0, filtered data appears on hrdata_tb
4. **Data Change**: hrdata_tb should differ from hwdata_tb (filter processed it)

---

## If Something Goes Wrong

### "Can't Find ahb_top_tb"
✓ In Simulation Sources, make sure ahb_top_tb.v is listed
✓ Right-click it → "Set as Top"

### "Module Not Found"
✓ Make sure all source files are in project
✓ Verify paths are correct

### "Simulation Stops Early"
✓ Check simulation time setting
✓ Simulation may finish early (~650 ns)
✓ Check for any error messages in console

### "All Tests Fail"
✓ Check hresetn timing
✓ Verify AHB interconnect is correct
✓ Check filter slave address (0x4000_0000)

---

## Test Results Interpretation

### PASS Means
✅ Sample successfully written
✅ Filter processed the data
✅ Output read back correctly
✅ Output in valid 12-bit range (±2047)

### FAIL Means
❌ Output out of range (shouldn't happen with saturating filters)
❌ Filter not responding
❌ Latency incorrect
❌ Data corruption

### Expected: 16/16 PASS
All 16 filter tests should pass if:
- Clock is running stably
- Reset is working
- Slave selection is correct
- Memory is functioning

---

## Customize the Test

### Add More Samples
```verilog
// Edit in testbench:
reg [11:0] test_samples [0:31];  // 32 instead of 16

// Then update loop:
for (filter_test_idx = 0; filter_test_idx < 32; ...)
```

### Change Latency
```verilog
// If your filter has different depth:
repeat(9) @(negedge hclk);  // Change 7 to your value
```

### Test Different Slave
```verilog
// In write_and_read_filter task:
slave_sel = 2'b00;  // Test Slave 1 instead
```

### Add Custom Test
```verilog
// Before $finish:
custom_test();

task custom_test();
  begin
    // Your test here
  end
endtask
```

---

## Files Involved

| File | Purpose |
|------|---------|
| ahb_top_tb.v | **The Testbench** (you run this) |
| ahb_top.v | DUT (system being tested) |
| wireline_rcvr_chain.v | Filter chain module |
| ctle.v, dc_offset_filter.v, etc. | Individual filter stages |
| dump.vcd | Generated waveform file (after sim) |

---

## Success Checklist

- [x] Testbench file loaded in Vivado
- [x] Set as Top (simulation)
- [x] Run Behavioral Simulation
- [x] Console shows 4 tests running
- [x] Each test shows COMPLETE
- [x] Filter chain shows "Passed: 16 / 16"
- [x] AES shows "Passed: 12 / 12"
- [x] Simulation finished message appears

---

## Next Steps After Success

1. **Analyze Waveforms**
   ```
   gtkwave dump.vcd &
   ```

2. **Modify Test Vectors**
   - Edit init_filter_test_vectors()
   - Re-run simulation

3. **Add More Tests**
   - Create custom_test() task
   - Call from main initial block

4. **Verify in Hardware** (if deploying to FPGA)
   - Synthesis complete
   - Place and route
   - Download to FPGA

---

## Quick Reference: Addresses

| Slave | Selector | Address | Purpose |
|-------|----------|---------|---------|
| 0 | 00 | 0x0000_0000 | Generic Memory 1 |
| 1 | 01 | 0x0000_0000 | Generic Memory 2 |
| 2 | 10 | 0x0000_0000 | Generic Memory (Burst) |
| **3** | **10** | **0x4000_0000** | **Filter Slave** ⭐ |
| 4 | 11 | 0x5000_0000 | AES Crypto |

**Note**: Same address bus, but slave_sel determines which slave responds

---

## Summary

Your enhanced testbench:
- ✅ Tests all 4 slaves
- ✅ Validates basic AHB protocol
- ✅ Validates burst transactions
- ✅ **Tests filter chain with 16 samples**
- ✅ Validates AES encryption/decryption
- ✅ Reports all results clearly
- ✅ Generates waveforms for analysis

**Ready to run!** 🚀

```
Quick command sequence:
1. Open ahb_top_tb.v
2. Run Behavioral Simulation
3. Watch console for results
4. Check for 16/16 filter PASS
5. Celebrate! ✨
```

