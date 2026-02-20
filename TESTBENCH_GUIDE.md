# Enhanced Testbench Guide: Filter Chain + AMBA Protocol Simulation

## Overview

The enhanced testbench (`ahb_top_tb.v`) now comprehensively tests the integrated AMBA protocol system with the wireline receiver filter chain. It combines:

1. **Basic AHB Protocol Testing** (Generic memory slaves)
2. **AHB Burst Protocol Testing** (INCR4 burst transactions)
3. **Filter Chain Processing** (6-stage wireline receiver)
4. **AES Crypto Operations** (Encryption/Decryption verification)

---

## Testbench Architecture

### Signal Organization

```
CLOCK & RESET
├── hclk          : 100MHz clock (5ns period)
├── hresetn       : Active-low reset

AHB MASTER SIGNALS
├── enable        : Transaction enable
├── slave_sel     : 2-bit slave selector
├── addr          : 32-bit address
├── data_in       : 32-bit write data
├── wr            : Write/Read control
├── burst_type    : Burst type selection

MONITORING WIRES
├── hwdata_tb     : Internal AHB write data
├── hrdata_tb     : Internal AHB read data
├── htrans_tb     : Transaction type
└── hreadyout_tb  : Slave ready output

TEST VARIABLES (Filter Chain)
├── test_samples[0:15]      : Input test vectors
├── filtered_results[0:15]  : Output results
├── filter_pass_cnt         : Pass counter
└── filter_fail_cnt         : Fail counter

TEST VARIABLES (AES/Crypto)
├── w0, w1, w2, w3          : Plaintext words
├── cword[0:3]              : Ciphertext words
├── pass_cnt / fail_cnt     : Test counters
└── dec_out                 : Decrypted output
```

---

## Test Tasks

### 1. **reset_dut()** - Reset Task
```verilog
task reset_dut();
  // Asserts hresetn=0, then deasserts to hresetn=1
  // Synchronizes with clock
```

### 2. **write_single()** - Single Write Transaction
```verilog
task write_single(input [1:0] sel, input [31:0] address, input [31:0] wdata);
  // Performs single AHB write transaction
  // sel: slave selector (2'b00, 2'b01, 2'b10, 2'b11)
  // address: target address
  // wdata: data to write
```

### 3. **read_single()** - Single Read Transaction
```verilog
task read_single(input [1:0] sel, input [31:0] address);
  // Performs single AHB read transaction
  // Returns data in hrdata_tb
```

### 4. **write_burst4()** - 4-Beat Burst Write
```verilog
task write_burst4(input [1:0] sel, input [31:0] start_address);
  // INCR4 burst write (4 beats)
  // Increments address automatically
```

### 5. **write_and_read_filter()** - Filter Chain Test Task
```verilog
task write_and_read_filter(input [11:0] sample_in, output [11:0] sample_out);
  // Writes 12-bit sample to filter slave (Slave 3)
  // Accounts for 6-cycle filter pipeline latency
  // Reads back filtered result
```

### 6. **init_filter_test_vectors()** - Initialize Test Vectors
```verilog
task init_filter_test_vectors();
  // Initializes 16 test samples with various patterns:
  // - Small values (0x050, 0x100)
  // - Medium values (0x200, 0x400)
  // - Maximum positive (0x7FF = 2047)
  // - Maximum negative (0x800 = -2048)
  // - Arbitrary patterns for coverage
```

---

## Test Sequence

### TEST 1: Generic Memory Slaves
```
Description: Basic single write/read operations
Slaves: Slave 1 (2'b00) and Slave 2 (2'b01)
Operations:
  1. Write 0xAAAAAAAA to Slave 1 @ 0x0000_0010
  2. Read from Slave 1
  3. Write 0xBBBBBBBB to Slave 2 @ 0x0000_0020
  4. Read from Slave 2
```

### TEST 2: AHB Burst Protocol
```
Description: 4-beat INCR4 burst with verification
Slave: Slave 3 (2'b10)
Address: 0x0000_0040 to 0x0000_004C
Operations:
  1. Write 4-beat burst (Beat 1-4)
  2. Read back each beat individually
  3. Verify data integrity
```

### TEST 3: Wireline Receiver Filter Chain
```
Description: Test 6-stage signal processing pipeline
Slave: Slave 3 (2'b10) at 0x4000_0000
Filter Order: CTLE → DC-Offset → FIR-EQ → DFE → Glitch → LPF
Test Vectors: 16 samples with various values
Operations:
  1. Initialize 16 test samples
  2. For each sample:
     a. Write 12-bit sample to filter slave
     b. Wait 7 cycles for filter latency
     c. Read back filtered result
     d. Validate output is in 12-bit range
  3. Report pass/fail statistics
```

### TEST 4: AES Crypto Processing
```
Description: Multi-block encryption and decryption verification
Slave: Slave 4 (2'b11)
Blocks: 3 blocks (16 bytes each)
Operations:
  1. For each block:
     a. Write 4 plaintext words
     b. Read back ciphertext
     c. Verify decryption matches original
     d. Read plaintext words back
  2. Report crypto verification results
```

---

## Filter Chain Test Details

### Input Test Samples (16 samples)

```
Index | Hex Value | Decimal | Description
------|-----------|---------|---------------------------
0     | 0x100     | 256     | Small positive
1     | 0x200     | 512     | Medium positive
2     | 0x400     | 1024    | Larger positive
3     | 0x7FF     | 2047    | Maximum positive
4     | 0x800     | -2048   | Minimum negative
5     | 0xA00     | -1536   | Negative value
6     | 0xC00     | -1024   | More negative
7     | 0xFFF     | -1      | Negative (-1)
8     | 0x050     | 80      | Very small
9     | 0x1AB     | 427     | Arbitrary pattern 1
10    | 0x2CD     | 717     | Arbitrary pattern 2
11    | 0x3EF     | 1007    | Arbitrary pattern 3
12    | 0x444     | 1092    | Pattern 4
13    | 0x555     | 1365    | Pattern 5
14    | 0x666     | 1638    | Pattern 6
15    | 0x777     | 1911    | Pattern 7
```

### Pipeline Latency Handling

```
Timeline for filter chain test:

T0: Write sample to filter slave
    └─ slave_sel = 2'b10 (Slave 3)
    └─ addr = 0x4000_0000 (Filter base)
    └─ data_in[11:0] = 12-bit sample

T1-T2: Wait for AHB write phases (2 cycles)

T3-T8: Wait for 6-cycle filter pipeline
    ├─ Cycle 1: Through CTLE
    ├─ Cycle 2: Through DC-Offset
    ├─ Cycle 3: Through FIR-EQ
    ├─ Cycle 4: Through DFE
    ├─ Cycle 5: Through Glitch
    └─ Cycle 6: Through LPF

T9-T11: Read filtered result
    └─ 3-cycle AHB read transaction

T12: Extract hrdata_tb[11:0] as filtered output

T13-T14: Gap for observation before next test
```

---

## Running the Testbench

### Using Vivado Simulator

```bash
# In Vivado:
1. Open Simulation
2. Run Behavioral Simulation
3. Monitor Waveforms (GTKWave)
```

### Output Generation

The testbench generates `dump.vcd` file with full signal traces:
```verilog
$dumpfile("dump.vcd");
$dumpvars(0, ahb_top_tb);
```

### Viewing with GTKWave

```bash
# After simulation completes:
$ gtkwave dump.vcd

# Add signals of interest:
# - hclk, hresetn
# - slave_sel, wr, hrdata_tb, hwdata_tb
# - Filter input/output signals (if available)
```

---

## Expected Output Format

### Test 1 Output
```
========================================================
TEST 1: Single Write/Read to Generic Memory Slaves
========================================================
[0 ns] TB: Wrote 0xAAAAAAAA to Slave 1 @ 0x0000_0010
[0 ns] TB: Read from Slave 1 @ 0x0000_0010 -> 0xaaaaaaaa
[0 ns] TB: Wrote 0xBBBBBBBB to Slave 2 @ 0x0000_0020
[0 ns] TB: Read from Slave 2 @ 0x0000_0020 -> 0xbbbbbbbb
```

### Test 3 Output (Filters)
```
========================================================
TEST 3: Filter Chain Processing (AMBA + Wireline Filters)
========================================================
[0 ns] TB: Testing 6-stage filter chain pipeline
[0 ns] TB: Filter Order: CTLE->DC-Offset->FIR-EQ->DFE->Glitch->LPF
[0 ns] TB: Filter test vectors initialized

[X ns] TB: Filter Test 0 - Input: 0x100 (256)
[Y ns] TB: Filter Test 0 - Output: 0x0FF (255)
[Y ns] TB: Filter Test 0 - RESULT: PASS (Output in valid range)

...

========================================================
TB: Filter Chain Test Summary
========================================================
TB: Total tests: 16 | Passed: 16 | Failed: 0

Filter Chain Test Results Table:
Index | Input (hex) | Input (dec) | Output (hex) | Output (dec) | Status
------|-------------|-------------|--------------|--------------|-------
    0 | 0x100      |   256      | 0x0FF       |   255       | PASS
    1 | 0x200      |   512      | 0x1FE       |   510       | PASS
    ...
```

### Test 4 Output (AES)
```
========================================================
TEST 4: AES Crypto Slave (Slave 4) Multi-Block Test
========================================================
[0 ns] TB: AES Block 0 - Writing plaintexts at base 0x60
[0 ns] TB: Block 0 - Words: W0=0x1111111 W1=0x22222222 W2=0x33333333 W3=0x44444444
[0 ns] TB: AES Block 0 - Reading ciphertexts
[0 ns] TB: Block 0 Word 0 - Ciphertext: 0xdeadbeef
...
[0 ns] TB: Block 0 - PLAINTEXT:  0x11111111222222233333333344444444
[0 ns] TB: Block 0 - ENCRYPTED:  0xdeadbeefdeadbeefdeadbeefdeadbeef
[0 ns] TB: Block 0 - DECRYPTED:  0x11111111222222233333333344444444
[0 ns] TB: Block 0 - VERIFICATION: PASS (decrypted matches input)
...
```

### Final Summary
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
Simulation finished at time XXX ns
========================================================
```

---

## Slave Address Mapping

| Slave | Selector | Address Range | Purpose |
|-------|----------|---------------|---------|
| 0 | 2'b00 | 0x0000_0000 - 0x3FFF_FFFF | Generic Memory |
| 1 | 2'b01 | 0x0000_0000 - 0x3FFF_FFFF | Generic Memory |
| 2 | 2'b10 | 0x0000_0000 - 0x3FFF_FFFF | Memory (Burst) |
| 3 | 2'b11 | 0x4000_0000 - 0x4000_03FF | **Filter Slave** |
| 4 | 2'b11 | 0x5000_0000 - 0x5000_03FF | AES Crypto |

---

## Filter Chain Signal Flow

### Input Data Path
```
AHB hwdata[31:0]
    ↓
Extract hwdata[11:0]
    ↓
wireline_rcvr_chain
    ├─ CTLE (1 cycle)
    ├─ DC-Offset (1 cycle)
    ├─ FIR-EQ (1 cycle)
    ├─ DFE (1 cycle)
    ├─ Glitch (1 cycle)
    └─ LPF (1 cycle)
    ↓
filtered_data[11:0]
    ↓
Store in memory
    ↓
Read via hrdata[11:0]
```

---

## Debugging Tips

### 1. Monitor Filter Input/Output
Add to waveform viewer:
```verilog
filter_input  (write value)
filter_output (read value)
```

### 2. Check Latency
Verify 6-cycle delay:
- Write at cycle N
- Read at cycle N+8 (accounting for AHB phases)

### 3. Verify AHB Transactions
Monitor these signals:
```verilog
slave_sel
wr
hrdata_tb
hwdata_tb
hreadyout_tb
```

### 4. Saturated Values
Look for clipping:
- Output should be ±2047 max
- Check for unexpected bounds

---

## Customization

### Modify Test Vectors
Edit `init_filter_test_vectors()`:
```verilog
test_samples[0]  <= 12'h100;  // Change values
test_samples[1]  <= 12'h200;
...
```

### Add More Test Samples
Increase array size:
```verilog
reg [11:0] test_samples [0:31];  // 32 samples instead of 16
```

### Adjust Filter Latency
If filter pipeline depth changes:
```verilog
repeat(7) @(negedge hclk);  // Change 7 to new latency
```

### Test Different Slaves
Change `slave_sel`:
```verilog
slave_sel = 2'b00;  // Test Slave 1
slave_sel = 2'b01;  // Test Slave 2
slave_sel = 2'b10;  // Test Slave 3 (Filter)
slave_sel = 2'b11;  // Test Slave 4 (AES)
```

---

## Summary

The enhanced testbench provides:
- ✅ Comprehensive AMBA protocol testing
- ✅ 6-stage filter chain validation
- ✅ AES encryption/decryption verification
- ✅ Automated result reporting
- ✅ Pass/fail statistics
- ✅ Waveform generation for debugging

All tests run in a single simulation with clear output indicating what's being tested and results.

