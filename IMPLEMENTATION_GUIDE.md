# IMPLEMENTATION GUIDE: Filter Chain in AMBA Protocol

## Quick Start

### 1. What Was Done
Your Verilog design now includes a **complete wireline receiver filter chain** integrated into the AMBA AHB protocol through `ahb_filter_slave`. This provides signal conditioning for incoming data.

### 2. Filter Chain at a Glance

**Order (Optimal Signal Processing Sequence):**
```
Raw Input → CTLE → DC Offset → FIR-EQ → DFE → Glitch → LPF → Filtered Output
```

**Each Stage Does:**
- **CTLE**: Boost high frequencies (compensate channel loss)
- **DC Offset**: Remove DC bias (center the signal)
- **FIR-EQ**: Linear equalization (known channel correction)
- **DFE**: Non-linear equalization (ISI cancellation with feedback)
- **Glitch**: Remove noise spikes (3-point median)
- **LPF**: Final smoothing (anti-aliasing)

---

## File Structure

### New Module Created
```
wireline_rcvr_chain.v
├─ Contains 6 instantiated filter stages
├─ Parameter: DATA_WIDTH = 12 bits
├─ Comprehensive comments for each stage
└─ Full documentation inline
```

### Modules Updated with Full Implementations
```
dc_offset_filter.v   ← Full high-pass filter (was empty)
dfe.v                ← 4-tap decision feedback equalizer (was empty)
glitch_filter.v      ← Median spike remover (was empty)
fir_equalizer.v      ← 7-tap symmetric equalizer (was empty)
ahb_filter_slave.v   ← AHB slave with filter chain (was empty)
```

### Existing Modules (Unchanged)
```
lpf_fir.v            ← Already complete
ctle.v               ← Already complete
AES_Encrypt.v        ← AES pipeline (separate)
ahb_top.v            ← Already uses ahb_filter_slave
```

---

## System Architecture

### Where It Fits
```
Your AMBA System (ahb_top.v)
│
├─ Master (ahb_mastern) → generates transactions
│
├─ Decoder → routes to slaves
│
└─ Slaves:
   ├─ Slave 1: Memory (generic)
   ├─ Slave 2: Memory (generic)
   ├─ Slave 3: ahb_filter_slave ← YOUR FILTER CHAIN HERE
   │           ├─ Memory array (256 × 32-bit)
   │           └─ wireline_rcvr_chain
   │               ├─ ctle
   │               ├─ dc_offset_filter
   │               ├─ fir_equalizer
   │               ├─ dfe
   │               ├─ glitch_filter
   │               └─ lpf_fir
   │
   └─ Slave 4: AES crypto
```

### Data Flow
```
Master writes 32-bit data
      ↓
hwdata[31:0] → Extract hwdata[11:0] (12-bit sample)
      ↓
wireline_rcvr_chain (6-stage pipeline)
      ↓
filtered_data[11:0] ← Final result
      ↓
Store in memory [addr] = {filtered, original}
```

---

## How to Use It

### In Your Testbench (ahb_top_tb.v)

**Write to Filter Slave:**
```verilog
// Select slave 3 and write sample data
slave_sel = 2'b11;           // Selects slave 3 (filter slave)
addr = 32'h4000_0000;        // Base address for slave 3
data_in = 32'h00000ABC;      // 12-bit sample in bits [11:0]
wr = 1'b1;                   // Write command
enable = 1'b1;
@(posedge hclk);            // Wait one clock

// Important: Add latency for filter pipeline (6 cycles)
repeat(7) @(posedge hclk);   // 6 filter stages + 1 margin

// Now read back the filtered result
wr = 1'b0;                   // Read command
@(posedge hclk);
// hrdata[11:0] contains filtered value
```

**Read Filtered Result:**
```verilog
slave_sel = 2'b11;
addr = 32'h4000_0000 + offset;
wr = 1'b0;
@(posedge hclk);
filtered_result = hrdata[11:0];
```

---

## Filter Stage Details

### Stage 1: CTLE (High-Frequency Emphasis)
```verilog
// Location: ctle.v
// Parameters:
//   DATA_WIDTH = 12
//   ALPHA_SHIFT = 2 (controls peaking strength)
//
// Operation:
// diff = current_sample - previous_sample
// output = current_sample + (diff >> ALPHA_SHIFT)
//
// Effect: Boosts high frequencies by ~25% (due to ALPHA_SHIFT=2)
```

### Stage 2: DC Offset Removal
```verilog
// Location: dc_offset_filter.v
// Parameters:
//   DATA_WIDTH = 12
//   ALPHA_SHIFT = 4
//
// Operation:
// dc_average_value = dc_avg + ((sample - dc_avg) >> 4)
// output = sample - dc_average
//
// Effect: High-pass filtering with ~4% integration rate
```

### Stage 3: FIR Equalizer (7-tap)
```verilog
// Location: fir_equalizer.v
// Parameters:
//   DATA_WIDTH = 12
//   NUM_TAPS = 7
//
// Tap Coefficients (symmetric):
//   [-32, -64, 128, 256, 128, -64, -32] (normalized by 256)
//
// Operation:
// output = (sum of (tap[i] × sample[i])) / 256
//
// Effect: Raises center frequency, suppresses edges
```

### Stage 4: DFE (Decision Feedback Equalizer)
```verilog
// Location: dfe.v
// Parameters:
//   DATA_WIDTH = 12
//   NUM_TAPS = 4
//
// Feedback Taps: [256, 128, 64, 32]
//
// Operation:
// feedback = sum(previous_decisions[i] × fb_tap[i])
// output = input - feedback / 256
//
// Effect: Cancels ISI from 4 previous symbols
```

### Stage 5: Glitch Filter (Median)
```verilog
// Location: glitch_filter.v
// Parameters:
//   DATA_WIDTH = 12
//   THRESHOLD = 512
//
// Operation:
// if |diff| > THRESHOLD then
//   output = median(prev, current, next)
// else
//   output = current
//
// Effect: Removes isolated spikes, preserves edges
```

### Stage 6: LPF (Low-Pass FIR)
```verilog
// Location: lpf_fir.v
//
// Tap Coefficients (normalized by 9):
//   [1, 2, 3, 2, 1]
//
// Operation:
// output = (1×x0 + 2×x1 + 3×x2 + 2×x3 + 1×x4) / 9
//
// Effect: Gaussian smoothing, removes high-frequency noise
```

---

## Performance Specifications

| Spec | Value |
|------|-------|
| **Data Width** | 12 bits (2's complement) |
| **Pipeline Depth** | 6 stages |
| **Latency** | 6 cycles |
| **Throughput** | 1 sample/cycle (after warm-up) |
| **Clock Domain** | hclk |
| **Reset** | hresetn (active low) |
| **Address Space** | 0x4000_0000 - 0x4000_03FF (1KB) |
| **Memory Entries** | 256 |

---

## Configuration Reference

### All Filter Parameters

| Filter | Parameter | Value | Effect |
|--------|-----------|-------|--------|
| CTLE | ALPHA_SHIFT | 2 | Stronger HF emphasis (larger = weaker) |
| DC Offset | ALPHA_SHIFT | 4 | Higher cutoff freq (larger = lower) |
| FIR-EQ | NUM_TAPS | 7 | More taps = sharper equalization |
| DFE | NUM_TAPS | 4 | More taps = more ISI cancellation |
| Glitch | THRESHOLD | 512 | Higher = less filtering |
| LPF | - | Fixed | Final smoothing (5-tap) |

**To Adjust Performance:**
- **More noise?** → Increase LPF taps or CTLE ALPHA_SHIFT
- **Less equalization?** → Increase ALPHA_SHIFT values
- **More ISI cancellation?** → Increase DFE NUM_TAPS
- **Fewer false spikes?** → Increase Glitch THRESHOLD

---

## Integration Checklist

- [x] Created `wireline_rcvr_chain.v` with 6 filter stages
- [x] Implemented `dc_offset_filter.v` (high-pass filter)
- [x] Implemented `dfe.v` (4-tap feedback equalizer)
- [x] Implemented `glitch_filter.v` (median spike filter)
- [x] Implemented `fir_equalizer.v` (7-tap equalizer)
- [x] Updated `ahb_filter_slave.v` with full AHB integration
- [x] Created filter chain documentation
- [x] Verified proper signal flow and ordering

**Ready to Simulate:** All files are complete and ready for synthesis/simulation.

---

## Troubleshooting

### Issue: Filtered data looks wrong
**Check:**
1. Is `hresetn` asserted properly during reset?
2. Are you waiting 6+ cycles after writing for filter latency?
3. Is `hclk` running stably?
4. Check filter `enable` signal is tied correctly

### Issue: Data gets saturated
**Check:**
1. Print intermediate filter outputs
2. Reduce input signal magnitude
3. Review tap coefficients are correct
4. Check ALPHA_SHIFT values

### Issue: No data appears
**Check:**
1. Is `slave_sel` = 2'b11 (select slave 3)?
2. Is address in range 0x4000_0000 - 0x4000_03FF?
3. Is `hready` = 1?
4. Is `hsel` being asserted?

---

## Example Testbench Snippet

```verilog
// Write-Read sequence for filter slave
integer sample_in, filtered_out;

// Initialize
slave_sel = 2'b11;
wr = 1'b1;

for (int i = 0; i < 10; i++) begin
    // Write sample
    sample_in = $random % 4096;  // Random 12-bit
    data_in = {20'b0, sample_in[11:0]};
    addr = 32'h4000_0000 + (i << 2);
    
    @(posedge hclk);
    
    // Wait for filter pipeline
    repeat(6) @(posedge hclk);
    
    // Read result
    wr = 1'b0;
    @(posedge hclk);
    filtered_out = hrdata[11:0];
    
    $display("Sample %d: In=%4h, Out=%4h", i, sample_in, filtered_out);
end
```

---

## Summary

✅ **Complete wireline receiver filter chain integrated into AMBA protocol**
✅ **6-stage pipeline with optimal signal processing order**
✅ **All filters fully implemented and parameterizable**
✅ **AHB slave port for easy integration**
✅ **Professional-grade signal conditioning**

Your system is ready to use!

