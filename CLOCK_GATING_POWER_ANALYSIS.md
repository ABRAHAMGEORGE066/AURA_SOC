# Clock Gating Power Analysis Guide

## Overview
Clock gating reduces dynamic power consumption by stopping clock signals to inactive components. Power savings depend on what percentage of time the clock is gated and the component's switching activity.

## Methods to Measure Power Reduction

### 1. **Simulation-Based Power Calculation (SystemVerilog)**
#### Formula:
```
Dynamic Power = 0.5 * Switching Frequency * Load Capacitance * Voltage^2
Simplified: Power ∝ Activity Factor × Frequency × Voltage^2
```

#### Gating Effectiveness:
```
Power Savings = (Ungated Power - Gated Power) / Ungated Power
              = Gating Ratio (%)
```

**Example:**
- Ungated operation: 100% clock activity
- With 70% clock gating: 30% clock activity (70% reduction)
- **Estimated power savings: ~70% for that component**

### 2. **Vivado Power Estimation Tool**
Steps in Vivado:
1. Generate bitstream from synthesized design
2. Open implementation design
3. Tools → Power → Estimate Power
4. Compare power reports with/without clock gating
5. Vivado will show:
   - Window Power
   - Clocking Power
   - Logic Power
   - I/O Power

### 3. **Activity-Based Calculation from Simulation**

#### Method A: Clock Toggle Counting
```
Total dynamic energy = Sum of all capacitances × Vdd^2 × transition_count

For each component:
Power_reduction = (ungated_transitions - gated_transitions) / ungated_transitions
```

#### Method B: Using Switching Activity Factor (SAF)
```
SAF = (Number of transitions per clock cycle) / 2
Power_with_gating = Base_Power × SAF × Activity_factor × (1 - gating_ratio)
```

### 4. **Hardware Measurement (Real FPGA/ASIC)**
- Use power supply monitors on the board
- Measure voltage/current with precision multimeter
- Calculate: Power = V × I
- Compare baseline vs. clock gated version

### 5. **Industry Standard: Estimate Based on Percentages**

#### Dynamic Power Contribution:
```
Total Power = Leakage Power (static) + Dynamic Power (switching)
Dynamic Power ≈ 60-80% of total in modern designs
```

#### Impact by Gating Ratio:
```
If 70% clock gating on component using 10mW:
- Ungated: 10mW (100% activity)
- Gated (70%): 10mW × (1 - 0.70) = 3mW (30% activity)
- Savings: 7mW = 70% reduction
```

## For Your AMBA AES Filter Design

### Typical Power Breakdown:

| Component | Usage | Est. Gating | Power Saving |
|-----------|-------|-------------|--------------|
| Master    | 40%   | 60%         | ~6% of total |
| Slave 1   | 10%   | 90%         | ~7% of total |
| Slave 2   | 10%   | 90%         | ~7% of total |
| Slave 3 (Filter) | 25% | 40%   | ~5% of total |
| Slave 4 (Crypto) | 15% | 60%   | ~6% of total |
| **TOTAL** | **100%** | **~68%** | **~31% savings** |

### Real Calculation:

If your design consumes **100mW** ungated:
- Leakage (static): ~20mW (always on)
- Dynamic (switching): ~80mW

With 68% average clock gating:
```
New Dynamic Power = 80mW × (1 - 0.68) = 25.6mW
New Total Power = 20mW (static) + 25.6mW (dynamic) = 45.6mW
Power Reduction = (100 - 45.6) / 100 = 54.4%
```

## Steps to Enable Proper Clock Gating in Your Design

### 1. Implement Idle Detection
```verilog
wire bus_idle = (htrans == 2'b00) && 
                ~hsel_1 && ~hsel_2 && ~hsel_3 && ~hsel_4 && 
                hreadyout && ~hresp;

reg idle_gate;
always @(bus_idle or hclk) begin
    if (!hclk) idle_gate <= bus_idle;
end
assign gated_clk = hclk & idle_gate;
```

### 2. Add Power Monitoring to Testbench
Track:
- Clock cycles (total)
- Active cycles (transactions enabled)
- Gated cycles (components idle)
- Calculate theoretical power savings

### 3. Generate Power Report
```
Clock Activity Report:
- Global Clock: 100% activity (ungated)
- Gated Clock: 32% activity (68% saved)
- Effective Power Reduction: ~31-54% depending on design
```

## Tools & Resources

### Synthesis Tools (Free)
- Vivado (Xilinx) - Built-in power estimator
- ISE (Legacy Xilinx) - Power estimator
- Quartus (Intel/Altera) - Power analyzer

### Third-Party Tools
- Mentor Questa/ModelSim - Toggle count analysis
- Cadence Xcelium - Power analysis
- Synopsys VCS - Activity-based power
- PrimeTime (ASIC) - Comprehensive power analysis

### Open Source
- Yosys + nextpnr - For open-source FPGA flow

## Practical Steps for Your Design

1. **Before Optimization** (Baseline)
   - Simulate ungated design
   - Note clock toggle counts
   - Calculate baseline power

2. **After Clock Gating** (Optimized)
   - Enable clock gating logic
   - Simulate with same test patterns
   - Compare toggle counts
   - Calculate power reduction

3. **Report Metrics**
   ```
   Base Power:         100mW (all clocks ungated)
   Optimized Power:    ~32-46mW (with clock gating)
   Power Reduction:    ~54-68%
   ```

## Summary Table

| Metric | Ungated | Gated | Reduction |
|--------|---------|-------|-----------|
| Clock Cycles | 100% | 100% | 0% |
| Active Cycles | 100% | 32% | 68% |
| Clock Toggles | 100% | 32% | 68% |
| Dynamic Power | 100% | 32% | 68% |
| **Total Power*** | 100% | 46% | 54% |

*Assuming 80% dynamic, 20% leakage

---

## Next Steps
1. Enable clock gating with proper idle detection
2. Re-run simulation with enhanced monitoring
3. Use Vivado's power estimator tool
4. Compare theoretical vs. measured results
