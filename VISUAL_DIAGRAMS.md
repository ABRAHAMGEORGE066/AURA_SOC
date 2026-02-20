# VISUAL FILTER CHAIN DIAGRAMS

## 1. Complete System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         AHB TOP MODULE                          │
│                      (ahb_top.v)                                │
└─────────────────────────────────────────────────────────────────┘
         │
         │  AHB Interconnect
         │
    ┌────┴────┬──────────┬──────────┬──────────┐
    │          │          │          │          │
    ▼          ▼          ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│Decoder │ │Master  │ │Slave 1 │ │Slave 2 │ │Slave 3 │ Slave 4
│ (addr  │ │(Master)│ │(Mem)   │ │(Mem)   │ │(FILTER)│ (AES)
│ decode)│ │        │ │        │ │        │ │        │
└────────┘ └────────┘ └────────┘ └────────┘ └────────┘ └────────┘
                                      │
                                      │ AHB Signals
                                      │ (hclk, haddr, hwdata, etc)
                                      ▼
                          ┌──────────────────────┐
                          │ ahb_filter_slave.v   │
                          │                      │
                          │ ┌──────────────────┐ │
                          │ │ Memory Array     │ │
                          │ │ (256×32-bit)     │ │
                          │ └──────────────────┘ │
                          │          ▲           │
                          │          │ Write     │
                          │    ┌─────┴────────┐  │
                          │    │ Filter Chain │  │
                          │    │ wireline_rcvr│  │
                          │    │_chain.v      │  │
                          │    └─────┬────────┘  │
                          │          │           │
                          │    Sample Stream     │
                          │   (12-bit data)      │
                          └──────────────────────┘
                                      ▲
                                      │
                               Raw Input Data
```

---

## 2. Filter Chain Pipeline

```
STAGE-BY-STAGE SIGNAL FLOW (6 CYCLES TOTAL)

Cycle 0:  din ────────────────────────────────────────
           │
           ▼ [CTLE Stage - High Frequency Boost]
           
Cycle 1:  ctle_out ──────────────────────────────────
           │
           ▼ [DC Offset Removal - HPF]
           
Cycle 2:  dc_offset_out ─────────────────────────────
           │
           ▼ [FIR Equalizer - 7-tap]
           
Cycle 3:  fir_eq_out ────────────────────────────────
           │
           ▼ [DFE - 4-tap Feedback]
           
Cycle 4:  dfe_out ───────────────────────────────────
           │
           ▼ [Glitch Filter - Median]
           
Cycle 5:  glitch_out ─────────────────────────────────
           │
           ▼ [LPF - 5-tap Smoothing]
           
Cycle 6:  data_out ◄─── FINAL FILTERED RESULT
```

---

## 3. Detailed Filter Chain (wireline_rcvr_chain.v)

```
                    WIRELINE_RCVR_CHAIN MODULE
                         (6 Stages)

    ┌─────────────────────────────────────────────────┐
    │  Input: 12-bit signed raw sample                │
    │  Clock: clk                                     │
    │  Enable: enable                                 │
    └──────────────────┬────────────────────────────┘
                       │
         ┌─────────────┼──────────────┐
         │             │              │
         ▼             ▼              ▼
    ┌────────────┐ ┌────────┐ ┌──────────┐
    │  CTLE      │ │Enable? │ │Clock Gen?│
    │(High Freq) │ └────────┘ └──────────┘
    ├────────────┤
    │ •din       │ (Current sample)
    │ •prev_smpl │ (Previous sample - register)
    │ •diff      │ (High-freq content: din-prev)
    │ •boosted   │ (Added back: din + diff>>2)
    │ •dout      │ → ALPHA_SHIFT = 2
    └──────────┬─┘
               │
         ┌─────▼──────────────┐
         │  DC_OFFSET_FILTER  │
         │  (High-Pass HPF)   │
         ├────────────────────┤
         │ •din               │ (From CTLE)
         │ •dc_avg            │ (Moving avg, register)
         │ •hpf_out           │ (High-pass: din-dc_avg)
         │ •Saturate at       │
         │  ±2047             │ → ALPHA_SHIFT = 4
         │ •dout              │
         └────────┬───────────┘
                  │
         ┌────────▼──────────────┐
         │ FIR_EQUALIZER        │
         │ (7-tap, symmetric)   │
         ├───────────────────────┤
         │ •Taps: [-32,-64,128, │
         │        256,128,-64,  │
         │        -32]          │ → NUM_TAPS = 7
         │ •Samples: x0-x6      │ (Shift register)
         │ •accum = Σ(tap×smpl) │
         │ •dout = accum/256    │
         │ •Saturate ±2047      │
         └────────┬──────────────┘
                  │
         ┌────────▼──────────────┐
         │ DFE (Decision Feedback)
         │ (4-tap feedback taps)│
         ├───────────────────────┤
         │ •fb_taps: [256,128,  │
         │           64,32]     │ → NUM_TAPS = 4
         │ •decisions: prev out │
         │           (shift reg)│
         │ •fb_sum = Σ(tap×dec)│
         │ •output = din - fb   │
         │ •Saturate ±2047      │
         └────────┬──────────────┘
                  │
         ┌────────▼──────────────┐
         │ GLITCH_FILTER        │
         │ (Median 3-point)     │
         ├───────────────────────┤
         │ •x0,x1,x2            │ (Shift register)
         │ •Spike detect:       │ → THRESHOLD
         │  |diff| > THRESHOLD  │   = 512
         │ •If spike: use       │
         │  median(x0,x1,x2)    │
         │ •Else: pass through  │
         │ •dout                │
         └────────┬──────────────┘
                  │
         ┌────────▼──────────────┐
         │ LPF_FIR (Low-Pass)   │
         │ (5-tap smoothing)    │
         ├───────────────────────┤
         │ •Taps: [1,2,3,2,1]   │ (Symmetric)
         │ •Samples: x0-x4      │
         │ •output = Σ(tap×smpl)│
         │ •dout = result/9     │
         │ •Saturate ±2047      │
         └────────┬──────────────┘
                  │
                  ▼
            ┌──────────────┐
            │Output: 12-bit│
            │Filtered Data │
            │ (FINAL)      │
            └──────────────┘
```

---

## 4. AHB Slave Integration

```
              AHB Write Transaction Flow
              
┌──────────────────────────────────────────┐
│ Address Phase (Cycle 1)                  │
├──────────────────────────────────────────┤
│ hsel = 1           (Slave selected)      │
│ haddr = 0x4000_0000 (Slave 3 address)   │
│ htrans = NONSEQ    (Non-sequential)      │
│ hwrite = 1         (Write)               │
│ hwdata = xxxx_xxxx  (Not used in addr)   │
│ hready = 1         (Master ready)        │
│ hreadyout = 1      (Slave ready)         │
└──────────┬──────────────────────────────┘
           │
           │ @(posedge hclk)
           │
┌──────────▼──────────────────────────────┐
│ Data Phase (Cycle 2)                    │
├──────────────────────────────────────────┤
│ haddr_captured = 0x4000_0000            │
│ hwdata = 32'h0000_0ABC                  │
│   ├─ [31:12] = Original upper bits      │
│   └─ [11:0]  = 0xABC (filter input)    │
│ hwriten = 1        (Write confirmed)    │
│ hreadyout = 1      (Always ready)       │
└──────────┬──────────────────────────────┘
           │
           │ Extract hwdata[11:0]
           │ = 12'h0ABC (12-bit sample)
           │
      ┌────▼────────────────────┐
      │ PIPELINE STAGES         │
      │ (6 Cycles)              │
      │                         │
      │ Cycle 2: CTLE           │
      │ Cycle 3: DC-Offset      │
      │ Cycle 4: FIR-EQ         │
      │ Cycle 5: DFE            │
      │ Cycle 6: Glitch         │
      │ Cycle 7: LPF            │
      │                         │
      │ filtered_data[11:0]     │
      │ = 12'hXXX (result)      │
      └────┬────────────────────┘
           │
           │ Store to memory
           │
      ┌────▼────────────────────┐
      │ mem[addr] = {filtered   │
      │            | original}  │
      └─────────────────────────┘
           │
           │ @(Cycle 8+)
           │ Can read via:
           │ wr = 0, haddr = same
           │ hrdata = mem[addr]
           │
      ┌────▼────────────────────┐
      │ Read Output:            │
      │ hrdata[11:0] = filtered │
      │ hrdata[31:12]= original │
      └────────────────────────┘
```

---

## 5. Signal Flow Example

```
EXAMPLE: Input Sample 0x0ABC → Filtered Output

Time:  T0        T1        T2        T3        T4        T5        T6

       din[11:0]
       0x0ABC
         │
         ▼
       CTLE
       Boost HF
       │
       ├─ prev = 0x000
       ├─ diff = 0x0ABC
       ├─ boost = 0x0ABC + (0x0ABC>>2)
       ├─ boost = 0x0ABC + 0x002B = 0x0AE7
       │
       ├─ dout[T0→T1] ───────────────────────→ 0x0AE7
                         │
                         ▼
                       DC-Offset
                       Center signal
                         │
                         ├─ dc_avg(init) = 0
                         ├─ new_avg = 0 + (0x0AE7 >> 4)
                         ├─ new_avg = 0x0AE7 >> 4 = 0x00AE
                         ├─ hpf_out = 0x0AE7 - 0x00AE = 0x0A39
                         │
                         ├─ dout[T1→T2] ──────────────→ 0x0A39
                                           │
                                           ▼
                                         FIR-EQ
                                         Equalize
                                           │
                                           ├─ Conv with 7 taps
                                           ├─ Center tap = 256
                                           ├─ result ∝ input boost
                                           │
                                           ├─ dout[T2→T3] ────→ 0x0B2x
                                                        │
                                                        ▼
                                                      DFE
                                                      ISI Cancel
                                                        │
                                                        ├─ Subtract
                                                        │  feedback
                                                        │
                                                        ├─ dout[T3→T4]→ 0x0A8x
                                                                   │
                                                                   ▼
                                                                Glitch
                                                                Spike Remove
                                                                   │
                                                                   ├─ Check if spike
                                                                   │
                                                                   ├─ dout[T4→T5]→ 0x0A8x
                                                                              │
                                                                              ▼
                                                                            LPF
                                                                            Smooth
                                                                              │
                                                                              ├─ 5-tap average
                                                                              │
                                                                              ├─ dout[T5→T6]
                                                                              │
                                                                              ▼
                                                                          FINAL: 0x0A72
                                                                          (Example)
```

---

## 6. Memory Organization

```
FILTER SLAVE MEMORY (ahb_filter_slave.v)

Base Address: 0x4000_0000
Size: 256 × 32-bit = 1 KB

Address         Data Field
0x4000_0000  ┌──────────────────────────┐
             │ [31:12] Original data    │
             │ [11:0] Filtered result   │
             └──────────────────────────┘
               ▲                    ▲
               │                    └─ Output of filter chain
               └────────────────────── Input hwdata upper bits

0x4000_0004  ┌──────────────────────────┐
             │ [31:12] Original data    │
             │ [11:0] Filtered result   │
             └──────────────────────────┘

...

0x4000_03FC  ┌──────────────────────────┐
             │ [31:12] Original data    │
             │ [11:0] Filtered result   │
             └──────────────────────────┘
             (Last entry: address offset 255)


EXAMPLE MEMORY CONTENTS AFTER FILTER OPERATIONS:

mem[0x00] = 0x0000_0ABC  (Original=0x0000, Filtered=0x0ABC)
mem[0x01] = 0x0000_0A72  (Original=0x0000, Filtered=0x0A72)
mem[0x02] = 0x0000_0B1F  (Original=0x0000, Filtered=0x0B1F)
...
```

---

## 7. Clock and Reset Timing

```
Clock Timing (Pipeline Synchronization)

hclk:     ─┐   ┌─   ┌─   ┌─   ┌─   ┐   ┐   ┐
           └─ ─ └─ ─ └─ ─ └─ ─ └─ ─┘   └─ ─
             T0  T1  T2  T3  T4  T5  T6  T7

hresetn:  ─ ─ ─ ─ ─ ─ ─ ┐
          ─────────────┐ └─────────────────── (Active Low)
          (Async reset)


Data Pipeline Timing (Write followed by Read)

hsel:     ─ ─ ─ ─ ─ ┐
          ──────────┘ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

hwrite:   ─ ─ ─ ─ ─ ┐                    ┐
          ──────────┘ ─ ─ ─ ─ ─ ─ ─ ─ ┌─┘
                                       └─ (Read)

hwdata:   ─ ─ ─ ─ ─ ┬──────────────────┬─ ─
          ──────────┘ 0xABC (sample)    └────


Filter Latency (6 Cycles)

Input Valid:     T0
                 │
                 ├─ T1: Through CTLE
                 ├─ T2: Through DC-Offset
                 ├─ T3: Through FIR-EQ
                 ├─ T4: Through DFE
                 ├─ T5: Through Glitch
                 ├─ T6: Through LPF
                 │
Output Valid:    T6 (6 cycles later)

Reading result requires:
  - Write at T0
  - Wait until T6+
  - Read at T7+
```

---

## 8. Control Signal Dependencies

```
Control Signals Flow:

hresetn ──┬─────┬─────┬────┬────┬────┬─────┐
          │     │     │    │    │    │     │
          ▼     ▼     ▼    ▼    ▼    ▼     ▼
        CTLE  DC-OFF FIR-EQ DFE GLITCH LPF  Memory
          │     │     │    │    │    │     │
          └─────┴─────┴────┴────┴────┴─────┴─→ All reset to 0
                                              on hresetn=0


enable ───┬─────┬─────┬────┬────┬────┬─────┐
          │     │     │    │    │    │     │
          ▼     ▼     ▼    ▼    ▼    ▼     ▼
        CTLE  DC-OFF FIR-EQ DFE GLITCH LPF  Filter
          │     │     │    │    │    │     │
          │ (All gated by enable signal)   │
          │ When enable=0, filters pass   │
          └───────────────────────────────┘
              input directly (bypass)
```

---

This visual guide complements the technical documentation. Use these diagrams alongside the implementation guides for complete understanding of the filter chain architecture and integration.

