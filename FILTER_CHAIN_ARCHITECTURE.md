# WIRELINE RECEIVER FILTER CHAIN ARCHITECTURE

## Overview
The filter chain integrates a complete signal processing pipeline for wireline data recovery with the AMBA AHB protocol. The chain implements best practices for high-speed serial receiver design.

---

## Filter Chain Architecture

### System Block Diagram
```
Raw Data Input
     ↓
  ┌──────────────────────────────────────────────────────┐
  │  WIRELINE RECEIVER FILTER CHAIN (wireline_rcvr_chain)│
  │                                                       │
  │  Stage 1: CTLE (ALPHA_SHIFT=2)                       │
  │  ├─ High-frequency peaking/emphasis                  │
  │  ├─ Compensates channel loss at high frequencies     │
  │  └─ Output: ctle_out                                 │
  │          ↓                                            │
  │  Stage 2: DC Offset Removal (ALPHA_SHIFT=4)          │
  │  ├─ Exponential moving average HPF                   │
  │  ├─ Removes DC drift and low-freq components        │
  │  └─ Output: dc_offset_out                            │
  │          ↓                                            │
  │  Stage 3: FIR Equalizer (7-tap)                      │
  │  ├─ Linear channel equalization                       │
  │  ├─ Preset symmetric taps: [-32, -64, 128, 256, ...]│
  │  └─ Output: fir_eq_out                               │
  │          ↓                                            │
  │  Stage 4: DFE (4-tap feedback)                       │
  │  ├─ Non-linear equalization                          │
  │  ├─ Uses previous decisions for ISI cancellation     │
  │  └─ Output: dfe_out                                  │
  │          ↓                                            │
  │  Stage 5: Glitch Filter (Median, THRESHOLD=512)     │
  │  ├─ Spike/impulse noise removal                      │
  │  ├─ 3-point median filtering                         │
  │  └─ Output: glitch_out                               │
  │          ↓                                            │
  │  Stage 6: LPF (5-tap FIR, coeffs: 1,2,3,2,1/9)      │
  │  ├─ Final low-pass filtering                         │
  │  ├─ Removes residual HF noise and aliases            │
  │  └─ Output: data_out (filtered result)               │
  │                                                       │
  └──────────────────────────────────────────────────────┘
     ↓
Filtered Data Output
```

---

## Detailed Filter Descriptions

### 1. CTLE (Continuous Time Linear Equalizer)
**File:** `ctle.v`
**Purpose:** High-frequency peaking to compensate for channel loss
**Parameters:**
- `DATA_WIDTH`: 12 bits
- `ALPHA_SHIFT`: 2 (controls peaking strength)

**Algorithm:**
```
diff = din - prev_sample              (high-frequency content)
boosted = din + (diff >>> ALPHA_SHIFT) (add back boosted HF)
dout = boosted
```

**Use Case:** Initial signal conditioning for attenuated high-frequency components

---

### 2. DC Offset Removal Filter
**File:** `dc_offset_filter.v`
**Purpose:** Remove DC bias and low-frequency drift
**Parameters:**
- `DATA_WIDTH`: 12 bits
- `ALPHA_SHIFT`: 4 (HPF cutoff frequency)

**Algorithm:**
```
dc_avg = dc_avg + ((din - dc_avg) >>> ALPHA_SHIFT)
hpf_out = din - dc_avg
```

**Use Case:** Signal centering after CTLE, prevents integrator saturation in downstream stages

---

### 3. FIR Equalizer
**File:** `fir_equalizer.v`
**Purpose:** Linear channel equalization with preset taps
**Parameters:**
- `DATA_WIDTH`: 12 bits
- `NUM_TAPS`: 7 (symmetric around center tap)

**Tap Coefficients:**
```
[-32, -64, 128, 256, 128, -64, -32]  (normalized by 256)
Main tap at center: 256
```

**Algorithm:**
```
accum = Σ(samples[i] * taps[i]) / 256
```

**Use Case:** General channel equalization before decision feedback stage

---

### 4. DFE (Decision Feedback Equalizer)
**File:** `dfe.v`
**Purpose:** Non-linear equalization using previous hard decisions
**Parameters:**
- `DATA_WIDTH`: 12 bits
- `NUM_TAPS`: 4 (feedback taps)

**Tap Coefficients:**
```
fb_taps = [256, 128, 64, 32]  (normalized by 256)
```

**Algorithm:**
```
fb_sum = Σ(decisions[i] * fb_taps[i])
dfe_out = din - (fb_sum >>> 8)
decisions shift-register updates with current output
```

**Use Case:** Advanced ISI cancellation, particularly effective for severe channel distortion

---

### 5. Glitch Filter (Median Filter)
**File:** `glitch_filter.v`
**Purpose:** Impulse noise/spike removal while preserving edges
**Parameters:**
- `DATA_WIDTH`: 12 bits
- `THRESHOLD`: 512 (spike detection threshold)

**Algorithm:**
```
3-point median: sort(x0, x1, x2) → take middle value
Spike detection: if |difference| > THRESHOLD → use median
Otherwise → pass through
```

**Use Case:** Remove isolated noise spikes that DFE cannot handle

---

### 6. LPF (Low-Pass FIR Filter)
**File:** `lpf_fir.v`
**Purpose:** Final low-pass filtering and noise smoothing
**Parameters:**
- `DATA_WIDTH`: 12 bits

**Tap Coefficients:**
```
[1, 2, 3, 2, 1]  (normalized by 9)
Filter equation: (x0 + 2*x1 + 3*x2 + 2*x3 + x4) / 9
```

**Use Case:** Final smoothing, removes residual aliasing and HF noise

---

## AHB Integration (ahb_filter_slave.v)

### Module Hierarchy
```
ahb_top.v (Master system)
    ├─ ahb_mastern (generates AHB transactions)
    ├─ ahb_decoder (address decoding)
    ├─ ahb_mux (data multiplexing)
    └─ ahb_filter_slave (SLAVE with filter chain)  ← NEW
        └─ wireline_rcvr_chain
            ├─ ctle
            ├─ dc_offset_filter
            ├─ fir_equalizer
            ├─ dfe
            ├─ glitch_filter
            └─ lpf_fir
```

### AHB Slave Integration
The `ahb_filter_slave` replaces generic memory in slave slot 3 and provides:

**Input Processing:**
- Raw 32-bit AHB write data → Extract 12-bit sample (lower bits)
- Feed to wireline_rcvr_chain

**Output Processing:**
- Filtered 12-bit result stored in memory
- Combined with original data for analysis/comparison

**Memory Organization:**
```
mem[addr] = [filtered_data (12-bit) | original_data (20-bit)]
```

**Signal Flow:**
```
AHB Master → hwdata[31:0]
           ↓
hwdata[11:0] → wireline_rcvr_chain → filtered_data[11:0]
           ↓
    Memory Storage
```

---

## Configuration Parameters

### Filter Chain Settings
| Component | Parameter | Value | Purpose |
|-----------|-----------|-------|---------|
| CTLE | ALPHA_SHIFT | 2 | Strong HF peaking |
| DC Offset | ALPHA_SHIFT | 4 | Moderate HPF cutoff |
| FIR EQ | NUM_TAPS | 7 | Symmetric equalization |
| DFE | NUM_TAPS | 4 | ISI cancellation |
| Glitch | THRESHOLD | 512 | Spike detection level |
| LPF | - | Hardcoded | Final smoothing |

### Timing
- **Latency:** 6 cycles (one cycle per filter stage)
- **Clock:** hclk (AHB clock)
- **Reset:** hresetn (active low)

---

## Design Rationale

### Filter Ordering Justification

1. **CTLE First**: Equalizes channel before other operations
2. **DC Removal Second**: Centers signal for linear stages
3. **FIR Equalizer Third**: Linear equalization of known channel
4. **DFE Fourth**: Non-linear refinement of equalization
5. **Glitch Filter Fifth**: Removes isolated noise before final smooth
6. **LPF Last**: Final noise reduction and anti-aliasing

### Performance Characteristics
- **Data Width**: 12 bits (suitable for medium-resolution ADC data)
- **Tap Widths**: Optimized for resource efficiency
- **Accumulator Sizes**: Prevent overflow while maintaining precision

---

## Integration Instructions

### 1. Add to Project
```verilog
// In amba_aes_filter_3.srcs/sources_1/new/
wireline_rcvr_chain.v    // NEW - Filter chain wrapper
ctle.v                   // UPDATED - Full implementation
dc_offset_filter.v       // UPDATED - Full implementation  
dfe.v                    // UPDATED - Full implementation
glitch_filter.v          // UPDATED - Full implementation
fir_equalizer.v          // UPDATED - Full implementation
lpf_fir.v                // Already exists
ahb_filter_slave.v       // UPDATED - AHB integration
```

### 2. Update ahb_top.v (Already Done)
The ahb_top.v instantiates ahb_filter_slave as slave_3:
```verilog
ahb_filter_slave slave_3(...)  // Slot 3 in AHB address space
```

### 3. Testbench Usage
```verilog
// In ahb_top_tb.v - Write to filter slave (address 0x4000_0000)
slave_sel = 2'b11;  // Select slave 3 (filter slave)
addr = 32'h4000_0000;
data_in = 32'h0000_0ABC;  // Lower 12 bits: 0xABC (sample)
wr = 1'b1;
// Result appears in mem after filter chain latency
```

---

## Simulation Considerations

### Latency Impact
- Each filter stage adds 1 cycle latency
- Total filter chain latency: **6 cycles**
- Plan testbench wait times accordingly

### Reset Behavior
- All filter stages reset to zero on hresetn=0
- Memory also resets
- Warm-up cycles needed after reset

### Data Saturation
- All filters implement saturation at ±2047 (12-bit range)
- Prevents overflow corruption
- Check for saturation in testbench if unexpected results occur

---

## Future Enhancements

1. **Adaptive Tap Updating**: Implement LMS algorithm for FIR/DFE taps
2. **Clock Domain Crossing**: Add synchronizers for multi-clock domains
3. **Bypass Mode**: Add control signal to bypass filter chain
4. **Configurable Parameters**: AHB registers to tune filter settings
5. **Performance Monitoring**: Add counters for filter statistics

---

## References

- **CTLE**: Continuous-time linear equalization for high-speed links
- **DFE**: Decision feedback equalizer for ISI cancellation (Widrow & Hoff, 1960s)
- **FIR**: Finite impulse response filtering (Oppenheim & Schafer)
- **Median Filter**: Non-linear noise removal (Gallagher & Wise, 1981)

