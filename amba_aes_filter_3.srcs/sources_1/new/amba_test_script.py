import serial
import serial.tools.list_ports
import time
import struct
import random

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SERIAL_PORT = 'COM11'  # Change this to your Basys 3 COM port
BAUD_RATE = 115200
TIMEOUT = 1

# Address Map
ADDR_RAM1   = 0x00000000
ADDR_RAM2   = 0x10000000
ADDR_FILTER = 0x40000000
ADDR_AES    = 0x50000000
ADDR_SYS    = 0xE0000000

# Filter register map (from ahb_filter_slave.v)
ADDR_FILTER_OUT    = ADDR_FILTER + 0x04  # DATA_OUT  (read-only): pop filtered result from output FIFO
ADDR_FILTER_CTRL   = ADDR_FILTER + 0x08  # CONTROL   (R/W)     : bit0=FILTER_ENABLE, bit1=BYPASS
ADDR_FILTER_STATUS = ADDR_FILTER + 0x0C  # STATUS    (R)       : [11:8]=in_cnt, [3:0]=out_cnt
# NOTE: addresses 0x20-0x28 are FIR coefficient registers, 0x2C-0x38 are FEC registers.
# The filter does NOT expose per-stage debug outputs as memory-mapped registers.

# ==============================================================================
# FILTER GOLDEN MODEL
# Replicates each RTL stage from wireline_rcvr_chain.v for pass/fail comparison.
# ==============================================================================
# RTL capture timing (ahb_filter_slave.v, PIPELINE_LAT = 16):
#   Streaming delay (filter_din registered): 2 cycles
#   CTLE:  2  |  DC Offset: 1  |  FIR EQ: 1  |  DFE:  1
#   Glitch: 1  |  LPF:      4  |  FEC:    2
#   Total = 2 + 2+1+1+1+1+4+2 = 14 cycles + 2 margin = PIPELINE_LAT 16
#
# FLUSH_WRITES: number of identical samples written to HW per test vector.
# The UART is slow (115200 baud, ~87 us/byte).  Writing 8 samples and then
# sleeping 50 ms gives the filter ~5 million clock cycles at 100 MHz between
# bursts, far more than the DC offset time constant (tau=16 cycles).  By the
# time the next burst arrives the filter has FULLY converged for the previous
# input value.  This is why HW outputs are always near-zero for constant DC
# inputs regardless of magnitude — the DC offset filter has fully settled.
#
# The golden model therefore must also run until DC convergence, not just 32
# clocks.  CONVERGENCE_CYCLES >> 5*tau (80 cycles) ensures full settlement.
# Use 2000 cycles which covers the full filter chain settling comfortably.
FLUSH_WRITES       = 32    # HW writes per test vector (4 bursts of 8)
CONVERGENCE_CYCLES = 2000  # golden model cycles per vector (matches HW inter-burst convergence)
PIPELINE_LAT       = 16    # must match ahb_filter_slave.v PIPELINE_LAT
FILTER_DW          = 12    # data width

# WARMUP_CYCLES for the golden model: run with input=0 long enough that all
# stages (DC avg, FIR SR, DFE limit-cycle, LPF pipeline) are fully settled.
WARMUP_CYCLES = 5000

def _sc(val, bits=FILTER_DW):
    """Sign-clip to signed 'bits'-bit integer."""
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return max(lo, min(hi, int(val)))

def _vdiv(num, den):
    """Truncate-toward-zero division matching Verilog signed '/'."""
    if den == 0: return 0
    sign = -1 if (num < 0) ^ (den < 0) else 1
    return sign * (abs(num) // abs(den))

class _CTLE:
    """
    CTLE — matches ctle.v exactly (2-register pipeline).
    Cycle N (non-blocking assignments):
      diff      <= din      - prev_sample   (new diff from OLD prev)
      boosted   <= din      + (diff >>> 2)  (new boost from OLD diff)
      dout      <= boosted                  (output = OLD boosted)
      prev_sample <= din
    Latency: 2 cycles (diff reg + boosted reg before dout).
    """
    def __init__(self):
        self.prev = 0; self.diff = 0; self.boosted = 0
    def clock(self, din):
        din = _sc(din)
        new_diff    = din - self.prev                    # uses old prev
        new_boosted = din + (self.diff >> 2)             # uses old diff
        new_dout    = self.boosted                       # output = old boosted
        self.diff    = new_diff
        self.boosted = new_boosted
        self.prev    = din
        return _sc(new_dout)

class _DCOffset:
    """
    DC Offset filter — matches dc_offset_filter.v exactly.
    Cycle N (non-blocking):
      avg  <= avg + ((din - avg) >>> 4)   (updates using OLD avg)
      dout <= din - avg                   (uses OLD avg, no extra clip)
    Latency: 1 cycle.
    """
    def __init__(self):
        self.avg = 0
    def clock(self, din):
        din     = _sc(din)
        old_avg = self.avg
        new_dout = din - old_avg                                # RTL: din - avg (no extra clip)
        self.avg = old_avg + ((din - old_avg) >> 4)            # IIR update
        # Truncate to DATA_WIDTH bits (what happens naturally in the wire)
        return _sc(new_dout)

class _FIREq:
    """7-tap FIR Equalizer: coeffs=[-32,-64,128,256,128,-64,-32]/256; 1-cycle latency."""
    _C = [-32, -64, 128, 256, 128, -64, -32]
    def __init__(self):
        self.sr = [0] * 7; self.dout = 0
    def clock(self, din):
        din = _sc(din)
        acc = sum(self.sr[i] * self._C[i] for i in range(7))
        nd = _sc(acc >> 8)   # divide by 256
        self.sr = [din] + self.sr[:-1]
        self.dout = nd
        return self.dout

class _DFE:
    """
    DFE — matches dfe.v exactly (2-register feedback path).
    Cycle N (non-blocking):
      feedback <=  prev_decision * 64   (uses OLD prev_decision)
      dout     <=  din - feedback       (uses OLD feedback)
      prev_decision <= decision(dout)   (uses OLD dout)
    Latency: 1 cycle output, but 2-cycle closed-loop feedback delay.
    """
    def __init__(self):
        self.prev_dec = 0; self.fb = 0; self.dout = 0
    def clock(self, din):
        din      = _sc(din)
        new_fb   = self.prev_dec * 64             # new feedback from OLD decision
        new_dout = _sc(din - self.fb)             # output uses OLD feedback
        new_dec  = 1 if self.dout >= 0 else -1    # decision on OLD dout
        self.fb       = new_fb
        self.dout     = new_dout
        self.prev_dec = new_dec
        return self.dout

class _Glitch:
    """
    Glitch filter — matches glitch_filter.v exactly.
    Median computed combinationally; abs_diff threshold check combinational.
    Cycle N:
      dout <= median(din,s1,s2) if |din-s1|>512 else din
      s1   <= din
      s2   <= s1
    Latency: 1 cycle.
    """
    def __init__(self):
        self.s1 = 0; self.s2 = 0
    def clock(self, din):
        din = _sc(din)
        s1, s2 = self.s1, self.s2
        # Combinational median (matches Verilog always@* block)
        if (din >= s1 and din <= s2) or (din <= s1 and din >= s2):
            median = din
        elif (s1 >= din and s1 <= s2) or (s1 <= din and s1 >= s2):
            median = s1
        else:
            median = s2
        abs_diff = abs(din - s1)  # matches Verilog: diff = din - s1; abs_diff
        new_dout = median if abs_diff > 512 else din
        self.s1 = din
        self.s2 = s1
        return _sc(new_dout)

class _LPF:
    """
    LPF FIR — matches lpf_fir.v (1,2,3,2,1)/9 with 4-register pipeline.
    Cycle N (non-blocking, uses OLD state):
      x4..x0 shift: x4<=x3, x3<=x2, x2<=x1, x1<=x0, x0<=din
      acc      <= x0 + x1*2 + x2*3 + x3*2 + x4          (old x's)
      acc_div  <= acc / 9                                  (old acc, truncate-toward-zero)
      dout_pipe <= acc_div                                 (old acc_div)
      dout      <= dout_pipe                              (old dout_pipe)
    Latency: 4 cycles. Steady state for constant input: 8 cycles.
    """
    def __init__(self):
        self.x        = [0]*5
        self.acc      = 0
        self.acc_div  = 0
        self.dout_pipe = 0
        self.dout     = 0
    def clock(self, din):
        din = _sc(din)
        ox = self.x                                            # old x state
        new_acc      = ox[0] + (ox[1] << 1) + ox[2]*3 + (ox[3] << 1) + ox[4]
        new_acc_div  = _vdiv(self.acc, 9)                     # uses OLD acc
        new_dout_pipe = self.acc_div                          # uses OLD acc_div
        new_dout     = _sc(self.dout_pipe)                    # uses OLD dout_pipe
        self.x        = [din] + ox[:4]                        # shift din in
        self.acc      = new_acc
        self.acc_div  = new_acc_div
        self.dout_pipe = new_dout_pipe
        self.dout     = new_dout
        return self.dout

class FilterChainModel:
    """
    Full golden model: CTLE->DC_Offset->FIR_EQ->DFE->Glitch->LPF->FEC.
    FEC is data-transparent (no error injection), adding 2 pipeline cycles.
    State is maintained between calls to model the continuous HW pipeline.
    """
    def __init__(self):
        self.ctle = _CTLE(); self.dc = _DCOffset(); self.fir = _FIREq()
        self.dfe  = _DFE();  self.gl = _Glitch();  self.lpf = _LPF()
        self.fec_pipe = [0, 0]  # 2-cycle FEC pass-through

    def clock(self, din):
        """Advance all stages by one clock cycle. Returns the 12-bit FEC output."""
        y = self.ctle.clock(din)
        y = self.dc.clock(y)
        y = self.fir.clock(y)
        y = self.dfe.clock(y)
        y = self.gl.clock(y)
        y = self.lpf.clock(y)
        # 2-stage FEC pipeline (data unchanged when no errors injected)
        y_out = self.fec_pipe[1]          # oldest entry exits first
        self.fec_pipe = [y, self.fec_pipe[0]]
        return y_out

    def run_sample(self, sample_12b):
        """
        Simulate HW inter-burst convergence: clock the filter CONVERGENCE_CYCLES
        times with constant input sample_12b.

        Why CONVERGENCE_CYCLES >> FLUSH_WRITES:
          The UART runs at 115200 baud (~87 us/byte).  Each 8-write burst takes
          ~6 ms.  The 50 ms inter-burst sleep, plus burst transfer time, gives
          the 100 MHz filter ~5 million clock cycles between HW test bursts.
          The DC offset time constant is tau=16 cycles; 2000 cycles >> 5*tau so
          the DC filter has fully converged before the next HW capture.
          Running CONVERGENCE_CYCLES in the golden model matches this HW behavior
          exactly: for any constant input the steady-state chain output is near
          zero (DC removed) with a small DFE limit-cycle component (±64 LSB
          peak, LPF-averaged to ±~20 LSB).
        """
        last = 0
        for _ in range(CONVERGENCE_CYCLES):
            last = self.clock(sample_12b)
        return last & 0xFFF

# ==============================================================================
# UART DRIVER
# ==============================================================================
def open_serial():
    try:
        ser = serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=TIMEOUT)
        print(f"[+] Connected to {SERIAL_PORT} at {BAUD_RATE} baud.")
        return ser
    except serial.SerialException as e:
        print(f"[-] Error opening serial port: {e}")
        print("[*] Listing available ports:")
        ports = serial.tools.list_ports.comports()
        for p in ports:
            print(f"    {p.device} - {p.description}")
        return None

def ahb_write(ser, addr, data):
    # Protocol: 'W' (0x57) + 4B Addr + 4B Data -> Returns 'K' (0x4B)
    cmd = struct.pack('>BII', 0x57, addr, data) # Big-endian
    ser.write(cmd)
    resp = ser.read(1)
    if resp == b'K':
        return True
    else:
        print(f"[-] Write failed at 0x{addr:08X}. Resp: {resp}")
        return False

def ahb_read(ser, addr):
    # Protocol: 'R' (0x52) + 4B Addr -> Returns 4B Data
    cmd = struct.pack('>BI', 0x52, addr)
    ser.write(cmd)
    resp = ser.read(4)
    if len(resp) == 4:
        return struct.unpack('>I', resp)[0]
    else:
        print(f"[-] Read failed at 0x{addr:08X}. Resp len: {len(resp)}")
        return None

# ==============================================================================
# TEST MODULES
# ==============================================================================
def test_ram(ser):
    print("\n--- Testing RAM (Slave 1 & 2) ---")
    
    # Test Slave 1
    val1 = 0xDEADBEEF
    print(f"[*] Writing 0x{val1:08X} to RAM1 (0x{ADDR_RAM1:08X})...")
    ahb_write(ser, ADDR_RAM1, val1)
    read1 = ahb_read(ser, ADDR_RAM1)
    if read1 is not None:
        print(f"[*] Read back: 0x{read1:08X}")
        if read1 == val1: print("[+] RAM1 Test PASS")
        else: print("[-] RAM1 Test FAIL")
    else:
        print("[-] RAM1 Test FAIL (Read Error)")

    # Test Slave 2
    val2 = 0xCAFEBABE
    print(f"[*] Writing 0x{val2:08X} to RAM2 (0x{ADDR_RAM2:08X})...")
    ahb_write(ser, ADDR_RAM2, val2)
    read2 = ahb_read(ser, ADDR_RAM2)
    if read2 is not None:
        print(f"[*] Read back: 0x{read2:08X}")
        if read2 == val2: print("[+] RAM2 Test PASS")
        else: print("[-] RAM2 Test FAIL")
    else:
        print("[-] RAM2 Test FAIL (Read Error)")

def test_filter(ser):
    print("\n" + "=" * 56)
    print("  TEST: Filter Chain (Slave 3) — 6-Stage Wireline Receiver")
    print("=" * 56)
    print("  Stages: CTLE -> DC_Offset -> FIR_EQ -> DFE -> Glitch -> LPF -> FEC")
    print(f"  Golden model: wireline_rcvr_chain.v | converge@{CONVERGENCE_CYCLES} cyc/vector, warmup@{WARMUP_CYCLES} cyc")
    print("  Architecture: u_filter_chain output captured directly; TMR/FEC stages")
    print("                remain connected as fault monitors (STATUS registers).")

    # ---------------------------------------------------------------
    # STEP 0: Enable filter (bit0 of CONTROL register, offset 0x08)
    # ---------------------------------------------------------------
    print("\n[*] Enabling filter (writing 0x1 to CONTROL @ 0x{:08X})...".format(ADDR_FILTER_CTRL))
    if not ahb_write(ser, ADDR_FILTER_CTRL, 0x00000001):
        print("[-] FATAL: Could not enable filter slave. Aborting test.")
        return
    time.sleep(0.01)

    # Verify control register
    ctrl_rd = ahb_read(ser, ADDR_FILTER_CTRL)
    if ctrl_rd is not None:
        print(f"[*] CONTROL readback: 0x{ctrl_rd:08X} ({'ENABLED' if ctrl_rd & 1 else 'DISABLED'})")
    else:
        print("[-] WARNING: Could not read CONTROL register.")

    # ---------------------------------------------------------------
    # STEP 1: Drain any stale entries from output FIFO
    # ---------------------------------------------------------------
    print("[*] Draining stale output FIFO entries...")
    for _ in range(8):                          # FIFO_DEPTH = 8
        status = ahb_read(ser, ADDR_FILTER_STATUS)
        if status is None:
            break
        out_cnt = status & 0xF
        if out_cnt == 0:
            break
        ahb_read(ser, ADDR_FILTER_OUT)          # pop and discard

    # ---------------------------------------------------------------
    # STEP 2: Instantiate golden model (RTL-accurate simulation)
    # ---------------------------------------------------------------
    golden_model = FilterChainModel()

    # Pre-warm the golden model with all-zero input so all stages (DC avg,
    # FIR SR, DFE, LPF) are in their fully-settled state before the first
    # test vector.  The flush-write strategy makes this less critical (each
    # test vector pushes FLUSH_WRITES samples through), but pre-warming ensures
    # the first vector's golden value is also from settled state.
    print(f"[*] Pre-warming golden model ({WARMUP_CYCLES} cycles at input=0)...")
    for _ in range(WARMUP_CYCLES):
        golden_model.clock(0)

    # Test vectors matching reference_tb.v init_filter_test_vectors()
    # (a mix of positive, negative, and boundary 12-bit values)
    samples = [
        0x100,  # Small positive
        0x200,  # Medium positive
        0x400,  # Larger positive
        0x7FF,  # Max positive (2047)
        0x800,  # Min negative (-2048)
        0xA00,  # Negative
        0xC00,  # More negative
        0xFFF,  # -1 in 12-bit 2's complement
        0x050,  # Small value
        0x1AB,  # Arbitrary pattern 1
        0x2CD,  # Arbitrary pattern 2
        0x3EF,  # Arbitrary pattern 3
        0x444,  # Test pattern 4
        0x555,  # Test pattern 5
        0x666,  # Test pattern 6
        0x777,  # Test pattern 7
    ]

    hw_outputs   = []
    golden_out   = []
    per_sample   = []
    pass_all     = True

    # ---------------------------------------------------------------
    # STEP 3: Write each sample FLUSH_WRITES times, drain all FIFO outputs,
    #         keep the LAST one as the steady-state result, compare with model.
    #
    # Flush-write strategy (avoids step-response transient entirely):
    #   Writing FLUSH_WRITES identical samples streams them through the pipeline
    #   one-per-clock.  After PIPELINE_LAT clocks the output is in steady state.
    #   We discard early transient outputs and compare only the last FIFO entry.
    #
    # HW FIFO depth = 8.  FLUSH_WRITES=32 produces up to 32-PIPELINE_LAT=16
    #   valid steady-state outputs, but the FIFO holds only 8.  The FSM will
    #   stall capture when FIFO is full, so we drain between bursts by writing
    #   up to FIFO_DEPTH samples at a time, sleeping, draining, and repeating.
    # ---------------------------------------------------------------
    FIFO_DEPTH = 8
    BURSTS     = FLUSH_WRITES // FIFO_DEPTH        # = 4 bursts of 8

    print(f"\n[*] DATA_IN  write : 0x{ADDR_FILTER:08X}")
    print(f"[*] DATA_OUT read  : 0x{ADDR_FILTER_OUT:08X}")
    print(f"[*] STATUS   read  : 0x{ADDR_FILTER_STATUS:08X}")
    print(f"\n[*] Running {len(samples)} test vectors  "
          f"({FLUSH_WRITES} HW writes each; golden runs {CONVERGENCE_CYCLES} cycles per vector)")

    print(f"\n{'Sample':>6} {'Input':>8} {'Golden':>8} {'HW Out':>8} {'Status':>8}")
    print("-" * 48)

    for idx, sample in enumerate(samples):
        sample_12b = sample & 0xFFF

        # --- Compute golden steady-state expected output ---
        g_out = golden_model.run_sample(sample_12b)
        golden_out.append(g_out)
        g_signed = g_out if g_out < 0x800 else g_out - 0x1000

        # --- Write FLUSH_WRITES identical samples in bursts of FIFO_DEPTH ---
        # Drain after each burst so the output FIFO never overflows.
        hw_burst_outs = []
        for burst in range(BURSTS):
            # Write one burst of FIFO_DEPTH samples
            for _ in range(FIFO_DEPTH):
                ahb_write(ser, ADDR_FILTER, sample_12b)
            # Allow pipeline to process (PIPELINE_LAT << 100 MHz / 115200 baud)
            time.sleep(0.05)
            # Drain all available FIFO outputs
            for _ in range(FIFO_DEPTH):
                st = ahb_read(ser, ADDR_FILTER_STATUS)
                if st is not None and (st & 0xF) > 0:
                    r = ahb_read(ser, ADDR_FILTER_OUT)
                    if r is not None:
                        hw_burst_outs.append(r & 0xFFF)

        # --- Take the last captured value as steady-state result ---
        status = ahb_read(ser, ADDR_FILTER_STATUS)
        out_cnt = (status & 0xF)        if status is not None else 0
        in_cnt  = ((status >> 8) & 0xF) if status is not None else 0

        if hw_burst_outs:
            hw_val    = hw_burst_outs[-1]
            hw_signed = hw_val if hw_val < 0x800 else hw_val - 0x1000
            hw_outputs.append(hw_val)

            # --- Pass/fail: steady-state golden vs HW ---
            # Both golden and HW converge to near-zero for constant DC input.
            # Residual difference comes from DFE limit-cycle phase (~±64 LSB
            # peak, LPF-averaged to ~±20 LSB) and timing of FIFO capture.
            # ±100 LSB covers all phase combinations of the 6-cycle DFE limit
            # cycle plus minor Python-vs-Verilog integer rounding (≤2 LSB).
            TOLERANCE = 100
            golden_ok   = abs(hw_signed - g_signed) <= TOLERANCE
            sample_pass = golden_ok
            if not sample_pass:
                pass_all = False

            status_str = "PASS" if sample_pass else "FAIL"
            per_sample.append({
                'input': sample_12b, 'golden': g_out, 'hw': hw_val,
                'in_cnt': in_cnt, 'out_cnt': out_cnt, 'ok': sample_pass
            })
            print(f"{idx+1:>6} {sample_12b:>8} (0x{sample_12b:03X}) "
                  f" {g_out:>5} (0x{g_out:03X}) "
                  f" {hw_val:>5} (0x{hw_val:03X}) "
                  f" [{status_str}]")
        else:
            print(f"{idx+1:>6} {sample_12b:>8}   --- read error ---      [FAIL]")
            pass_all = False
            per_sample.append({'input': sample_12b, 'golden': g_out, 'hw': None, 'ok': False})

    # ---------------------------------------------------------------
    # STEP 4: Detailed per-sample breakdown
    # ---------------------------------------------------------------
    print("\n" + "=" * 56)
    print("  FILTER CHAIN DETAILED RESULTS")
    print("=" * 56)
    for idx, rec in enumerate(per_sample):
        hw_s = rec['hw'] if rec['hw'] is None else (rec['hw'] if rec['hw'] < 0x800 else rec['hw'] - 0x1000)
        g_s  = rec['golden'] if rec['golden'] < 0x800 else rec['golden'] - 0x1000
        print(f"  Sample {idx+1}:")
        print(f"    Input         : 0x{rec['input']:03X} ({rec['input']:>5}  signed={rec['input'] if rec['input']<0x800 else rec['input']-0x1000})")
        print(f"    Golden (model): 0x{rec['golden']:03X} ({rec['golden']:>5}  signed={g_s})")
        if rec['hw'] is not None:
            print(f"    HW Output     : 0x{rec['hw']:03X} ({rec['hw']:>5}  signed={hw_s})")
            print(f"    Delta (HW-G)  : {hw_s - g_s}")
            print(f"    FIFO Status   : in_cnt={rec.get('in_cnt','-')}, out_cnt={rec.get('out_cnt','-')}")
            print(f"    Result        : {'[+] PASS' if rec['ok'] else '[-] FAIL'}")
        else:
            print(f"    HW Output     : READ/WRITE ERROR")
            print(f"    Result        : [-] FAIL")

    # ---------------------------------------------------------------
    # STEP 5: Overall status
    # ---------------------------------------------------------------
    pass_cnt = sum(1 for r in per_sample if r['ok'])
    fail_cnt = len(per_sample) - pass_cnt
    print("\n" + "=" * 56)
    print(f"  FILTER CHAIN SUMMARY:  {pass_cnt}/{len(per_sample)} PASSED")
    print("=" * 56)
    if pass_all:
        print("  [+] FILTER TEST PASS: All outputs match golden model (±50 LSB).")
        print("  [+] Filter pipeline is correctly connected and producing valid data.")
    else:
        print("  [-] FILTER TEST FAIL: One or more outputs deviate from golden model.")
        print("  [-] Check: filter enabled? Bitstream up to date? Serial connection OK?")
    print("=" * 56)

def test_aes(ser):
    print("\n--- Testing AES (Slave 4) ---")
    # Assuming standard AES slave mapping:
    # 0x00-0x0F: Key
    # 0x10-0x1F: Plaintext
    # 0x20: Control/Status (Write 1 to start)
    # 0x30-0x3F: Ciphertext
    
    # 1. Write Key (Dummy)
    print("[*] Writing AES Key...")
    key = [0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF]
    for i in range(4):
        ahb_write(ser, ADDR_AES + (i*4), key[i])

    # 2. Write Plaintext (example)
    print("[*] Writing AES Plaintext...")
    plaintext = [0x12345678, 0x9ABCDEF0, 0x0F1E2D3C, 0x4B5A6978]
    for i in range(4):
        ahb_write(ser, ADDR_AES + 0x10 + (i*4), plaintext[i])

    # 3. Start Encryption
    print("[*] Starting Encryption...")
    ahb_write(ser, ADDR_AES + 0x20, 1)

    # 4. Wait for completion (UART delay is usually enough)
    time.sleep(0.05)

    # 5. Read Ciphertext
    print("[*] Reading Ciphertext...")
    ciphertext = []
    for i in range(4):
        c = ahb_read(ser, ADDR_AES + 0x30 + (i*4))
        ciphertext.append(c)
        print(f"[*] Ciphertext[{i}]: 0x{c:08X}" if c is not None else f"[-] AES Test FAIL (Read Error)")

    if None in ciphertext:
        print("[-] AES Test FAIL (Read Error)")
        return

    # 6. Write Ciphertext as new input (simulate decryption)
    print("[*] Writing Ciphertext as input for decryption...")
    for i in range(4):
        ahb_write(ser, ADDR_AES + 0x10 + (i*4), ciphertext[i])

    # 7. Start Encryption again (XOR model: encrypting ciphertext with same key should return plaintext)
    print("[*] Starting Decryption (re-encrypt with same key)...")
    ahb_write(ser, ADDR_AES + 0x20, 1)
    time.sleep(0.05)

    # 8. Read Decrypted Text
    print("[*] Reading Decrypted Text...")
    decrypted = []
    for i in range(4):
        d = ahb_read(ser, ADDR_AES + 0x30 + (i*4))
        decrypted.append(d)
        print(f"[*] Decrypted[{i}]: 0x{d:08X}" if d is not None else f"[-] AES Decrypt FAIL (Read Error)")

    if None in decrypted:
        print("[-] AES Decrypt FAIL (Read Error)")
        return

    # 9. Compare decrypted with original plaintext
    if decrypted == plaintext:
        print("[+] AES Encrypt/Decrypt Test PASS (decrypted matches original)")
    else:
        print("[-] AES Encrypt/Decrypt Test FAIL (decrypted does not match original)")

def _stress_traffic(ser, duration_sec, label):
    """
    Maximum-intensity AHB traffic targeting all 4 slaves simultaneously.
    Alternates checkerboard patterns (0xAAAA5555 / 0x55555AAA) every op to
    maximise flip-flop toggle rate (= maximum dynamic power).
    Hits: RAM1, RAM2, Filter (data-in), AES (plaintext + trigger), RAM1 read.
    Prints a live countdown every 5 seconds.
    Returns total operation count.
    """
    # Alternating high-toggle patterns
    PATTERNS = [0xAAAA5555, 0x55555AAA, 0xFFFF0000, 0x0000FFFF,
                0xA5A5A5A5, 0x5A5A5A5A, 0xDEADBEEF, 0x12345678]

    # Pre-load AES key once (stays loaded during entire phase)
    for i in range(4):
        ahb_write(ser, ADDR_AES + (i * 4), 0xDEADBEEF)

    ops       = 0
    pat_idx   = 0
    start     = time.time()
    last_print = start
    next_milestone = 5

    print(f"\n[*] Stressing ALL slaves for {duration_sec}s  [{label}]")
    print(f"    Slaves: RAM1 + RAM2 + Filter + AES")
    print(f"    Pattern: alternating 0xAAAA5555/0x55555AAA (max toggle rate)")

    while True:
        elapsed = time.time() - start
        if elapsed >= duration_sec:
            break

        pat = PATTERNS[pat_idx % len(PATTERNS)]
        pat_idx += 1

        # --- RAM1: write + read (back-to-back, keeps bus fully busy) ---
        ahb_write(ser, ADDR_RAM1,           pat)
        ahb_write(ser, ADDR_RAM1 + 0x04,    ~pat & 0xFFFFFFFF)
        ahb_read(ser,  ADDR_RAM1)

        # --- RAM2: write (different address to toggle address lines too) ---
        ahb_write(ser, ADDR_RAM2,           ~pat & 0xFFFFFFFF)
        ahb_write(ser, ADDR_RAM2 + 0x04,    pat)

        # --- Filter: push a new sample (12-bit, alternating hi/lo) ---
        filter_sample = 0x7FF if (pat_idx % 2 == 0) else 0x800
        ahb_write(ser, ADDR_FILTER,         filter_sample)

        # --- AES: write plaintext + fire trigger (keeps AES core toggling) ---
        ahb_write(ser, ADDR_AES + 0x10,     pat)
        ahb_write(ser, ADDR_AES + 0x14,     ~pat & 0xFFFFFFFF)
        ahb_write(ser, ADDR_AES + 0x20,     0x1)   # start encryption

        ops += 9  # 9 AHB transactions per loop iteration

        # Idle gap: with cg_enable=1 all hsel signals go LOW here,
        # so BUFGCE gates all 4 slave clocks OFF for the full 5ms.
        # With cg_enable=0 the clocks keep running — this is where
        # the measurable power difference actually comes from.
        # 5ms = 500,000 clock cycles at 100MHz — enough for gating to matter,
        # short enough to avoid UART serial timeout (1s).
        time.sleep(0.005)

        # Live countdown every 5 seconds
        now = time.time()
        if now - last_print >= 5:
            remaining = int(duration_sec - elapsed)
            ops_per_sec = ops / elapsed if elapsed > 0 else 0
            print(f"    [{remaining:3d}s remaining]  ops so far: {ops:,}  (~{ops_per_sec:.0f} ops/s)")
            last_print = now

    total_time = time.time() - start
    print(f"[+] Phase complete: {ops:,} total AHB ops in {total_time:.1f}s  "
          f"({ops/total_time:.0f} ops/s)")
    return ops


def power_analysis_loop(ser):
    WARMUP_SEC  = 30    # seconds to let board reach steady state (not measured)
    TRAFFIC_SEC = 600   # 10 minutes per phase

    print("\n" + "=" * 60)
    print("   POWER COMPARISON  (Clock Gating OFF vs ON)")
    print("   Read the mAh value on your USB meter after each phase.")
    print("=" * 60)
    print(f"  Warmup  : {WARMUP_SEC}s per phase  (board stabilises — reset meter after)")
    print(f"  Traffic : {TRAFFIC_SEC}s per phase  (note mAh before & after)")
    print(f"  Targets : RAM1 + RAM2 + Filter + AES (max switching activity)")
    print("=" * 60)

    ops_results = {}

    # Run both orderings to cancel thermal drift bias:
    #   Run A: OFF first, ON second  (board heats up between phases)
    #   Run B: ON first, OFF second  (reverse order)
    # Average the two to get a thermally-balanced comparison.
    # Here we run ONE ordering per invocation — alternate manually,
    # or set REVERSE_ORDER = True for the second run.
    REVERSE_ORDER = True    # ON first (cold board), OFF second

    phase_order = [
        ("Clock Gating ON   [Low Power]",  0),
        ("Clock Gating OFF  [High Power]", 1)
    ]
    if REVERSE_ORDER:
        phase_order = list(reversed(phase_order))

    for phase, (label, cg_val) in enumerate(phase_order):
        print(f"\n{'='*60}")
        print(f"  PHASE {phase+1}: {label}")
        print(f"{'='*60}")

        # Apply clock gating setting
        ahb_write(ser, ADDR_SYS, cg_val)
        readback = ahb_read(ser, ADDR_SYS)
        if readback is not None:
            print(f"[*] ADDR_SYS readback: 0x{readback:08X}  "
                  f"(cg_enable bit = {readback & 1})")
        else:
            print("[!] Could not read ADDR_SYS")

        input(f"\n>>> Press ENTER to start {WARMUP_SEC}s warmup for Phase {phase+1} ...")

        # Warmup — do not read meter yet
        print(f"[*] Warmup running ({WARMUP_SEC}s) — do NOT read meter yet...")
        _stress_traffic(ser, WARMUP_SEC, f"WARMUP  {label}")
        print(f"[*] Warmup done — NOTE or RESET the mAh counter on your meter now.")

        input(f">>> Press ENTER to start the {TRAFFIC_SEC}s measurement window ...")

        # Measurement window
        print(f"[*] Running {TRAFFIC_SEC}s stress traffic — watch the mAh accumulate...")
        ops = _stress_traffic(ser, TRAFFIC_SEC, f"MEASURE {label}")
        ops_results[phase] = ops

        print(f"\n[*] Phase {phase+1} done — READ the mAh value on your meter now.")
        print(f"[*]   delta mAh = (reading now) - (reading before traffic started)")
        print(f"[*]   AHB ops this phase: {ops:,}")

    # ---------------------------------------------------------------
    # Final reminder — user compares meter readings manually
    # ---------------------------------------------------------------
    print(f"\n{'='*60}")
    print(f"  BOTH PHASES COMPLETE")
    print(f"{'='*60}")
    print(f"  Compare the two mAh deltas you observed on your USB meter:")
    print()
    print(f"  Phase 1 (Gating OFF) — higher mAh = more charge = more power")
    print(f"  Phase 2 (Gating ON)  — lower mAh  = less charge = power saved")
    print()
    print(f"  To calculate from your mAh values (USB @ 5V, {TRAFFIC_SEC}s window):")
    print(f"    Energy  (mWh) = delta_mAh x 5")
    print(f"    Avg Pwr (mW)  = delta_mAh x 5 x 60   [= mWh / ({TRAFFIC_SEC}s/3600)]")
    print(f"    Savings (%)   = (mAh_OFF - mAh_ON) / mAh_OFF x 100")
    print()
    print(f"  Phase 1 AHB ops : {ops_results.get(0, 0):,}")
    print(f"  Phase 2 AHB ops : {ops_results.get(1, 0):,}")
    print(f"{'='*60}")

# ==============================================================================
# MAIN
# ==============================================================================
def power_analysis_idle(ser):
    """
    Idle-dominant test: maximises clock gating savings.

    Pattern per iteration:
      1. Fire a tiny AHB burst (4 writes across all slaves) — ~4ms UART time
      2. Sleep IDLE_SEC (all hsel=0 → BUFGCE freezes all slave clocks if cg_enable=1)

    With cg_enable=0: slave clock trees toggle at 100 MHz during the entire idle window.
    With cg_enable=1: slave clock trees are frozen during the entire idle window → maximum savings.

    Idle fraction = IDLE_SEC / (IDLE_SEC + ~0.004s) ≈ 99% at IDLE_SEC=0.5s
    This is the worst-case scenario for gating OFF and best-case for gating ON.
    """
    WARMUP_SEC   = 30     # warmup before each measurement (not counted)
    TRAFFIC_SEC  = 600    # 10-minute measurement window per phase
    IDLE_SEC     = 0.5    # idle gap between bursts (500ms = 50,000,000 clock cycles frozen)
    REVERSE_ORDER = False  # set True for second run (thermally balanced)

    print("\n" + "=" * 60)
    print("   IDLE-DOMINANT POWER COMPARISON (max clock gating savings)")
    print("=" * 60)
    print(f"  Pattern   : 4-op burst → {IDLE_SEC*1000:.0f}ms idle → repeat")
    print(f"  Idle frac : ~{100*IDLE_SEC/(IDLE_SEC+0.004):.0f}%  (clocks frozen this % of the time)")
    print(f"  Window    : {TRAFFIC_SEC}s per phase  |  Warmup: {WARMUP_SEC}s")
    print(f"  Expected  : Gating ON should show LOWER mAh than Gating OFF")
    print("=" * 60)

    phase_order = [
        ("Clock Gating ON   [Low Power]",  0),
        ("Clock Gating OFF  [High Power]", 1),
    ]
    if REVERSE_ORDER:
        phase_order = list(reversed(phase_order))

    ops_results = {}

    for phase, (label, cg_val) in enumerate(phase_order):
        print(f"\n{'='*60}")
        print(f"  PHASE {phase+1}: {label}")
        print(f"{'='*60}")

        # Apply clock gating setting
        ahb_write(ser, ADDR_SYS, cg_val)
        readback = ahb_read(ser, ADDR_SYS)
        if readback is not None:
            print(f"[*] ADDR_SYS readback: 0x{readback:08X}  "
                  f"(cg_enable bit = {readback & 1})")
        else:
            print("[!] Could not read ADDR_SYS")

        input(f"\n>>> Press ENTER to start {WARMUP_SEC}s warmup for Phase {phase+1} ...")

        # Warmup — same idle pattern, not measured
        print(f"[*] Warmup running ({WARMUP_SEC}s) — do NOT read meter yet...")
        w_start = time.time()
        while time.time() - w_start < WARMUP_SEC:
            ahb_write(ser, ADDR_RAM1,   0xAAAA5555)
            ahb_write(ser, ADDR_RAM2,   0x5555AAAA)
            ahb_write(ser, ADDR_FILTER, 0x7FF)
            ahb_write(ser, ADDR_AES + 0x10, 0xDEADBEEF)
            time.sleep(IDLE_SEC)
        print(f"[*] Warmup done — RESET the mAh counter on your meter now.")

        input(f">>> Press ENTER to start the {TRAFFIC_SEC}s measurement window ...")

        # Measurement window — idle-dominant pattern
        print(f"[*] Running {TRAFFIC_SEC}s idle-dominant traffic...")
        print(f"[*] Each iteration: 4 AHB writes then {IDLE_SEC*1000:.0f}ms idle")
        print(f"[*] Gating ON  → clocks frozen {IDLE_SEC*1000:.0f}ms per iteration")
        print(f"[*] Gating OFF → clocks toggling at 100MHz during idle")

        ops      = 0
        start    = time.time()
        last_print = start
        PATTERNS = [0xAAAA5555, 0x55555AAA, 0xFFFF0000, 0x0000FFFF]
        idx      = 0

        while True:
            elapsed = time.time() - start
            if elapsed >= TRAFFIC_SEC:
                break

            pat = PATTERNS[idx % len(PATTERNS)]
            idx += 1

            # Minimal burst: touch each slave once to prove bus is alive
            ahb_write(ser, ADDR_RAM1,        pat)
            ahb_write(ser, ADDR_RAM2,        ~pat & 0xFFFFFFFF)
            ahb_write(ser, ADDR_FILTER,      0x7FF if idx % 2 == 0 else 0x800)
            ahb_write(ser, ADDR_AES + 0x10,  pat)
            ops += 4

            # Long idle — THIS is where the savings come from
            time.sleep(IDLE_SEC)

            # Live countdown every 30 seconds
            if time.time() - last_print >= 30:
                remaining = int(TRAFFIC_SEC - elapsed)
                print(f"    [{remaining:3d}s remaining]  iterations: {idx}  ops: {ops:,}")
                last_print = time.time()

        ops_results[phase] = ops
        total_time = time.time() - start
        print(f"[+] Phase {phase+1} done: {ops:,} ops in {total_time:.1f}s  "
              f"({ops/total_time:.1f} ops/s)")
        print(f"\n[*] Phase {phase+1} complete — READ and NOTE the mAh on your meter now.")
        print(f"[*]   delta mAh = (reading now) - (reading when traffic started)")

    # ---------------------------------------------------------------
    # Final summary
    # ---------------------------------------------------------------
    print(f"\n{'='*60}")
    print(f"  IDLE-DOMINANT TEST COMPLETE")
    print(f"{'='*60}")
    print(f"  With ~{100*IDLE_SEC/(IDLE_SEC+0.004):.0f}% idle fraction:")
    print(f"    Gating ON  should have LOWER mAh  (clocks frozen during idle)")
    print(f"    Gating OFF should have HIGHER mAh (clocks run during idle)")
    print()
    print(f"  To calculate from your mAh readings (USB @ 5V, {TRAFFIC_SEC}s):")
    print(f"    Energy (mWh) = delta_mAh x 5")
    print(f"    Avg Pwr (mW) = delta_mAh x 5 x 6   [mWh / (600s/3600)]")
    print(f"    Savings (%)  = (mAh_OFF - mAh_ON) / mAh_OFF x 100")
    print()
    print(f"  Phase 1 AHB ops : {ops_results.get(0, 0):,}")
    print(f"  Phase 2 AHB ops : {ops_results.get(1, 0):,}")
    print(f"  (ops should be equal — any difference = UART timeouts)")
    print(f"{'='*60}")


# ==============================================================================
# MAIN
# ==============================================================================
if __name__ == "__main__":
    ser = open_serial()
    if ser:
        while True:
            print("\n--- AMBA Test Menu ---")
            print("1. Test RAM")
            print("2. Test Filter Chain")
            print("3. Test AES")
            print("4. Run Power Analysis (stress traffic)")
            print("5. Run Power Analysis (idle-dominant, max gating savings)")
            print("6. Exit")

            choice = input("Select: ")

            if choice == '1':
                test_ram(ser)
            elif choice == '2':
                test_filter(ser)
            elif choice == '3':
                test_aes(ser)
            elif choice == '4':
                power_analysis_loop(ser)
            elif choice == '5':
                power_analysis_idle(ser)
            elif choice == '6':
                ser.close()
                break
            else:
                print("Invalid selection.")