import serial
import serial.tools.list_ports
import time
import struct
import random

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SERIAL_PORT = 'COM10'  # Change this to your Basys 3 COM port
BAUD_RATE = 115200
TIMEOUT = 1

# Address Map
ADDR_RAM1   = 0x00000000
ADDR_RAM2   = 0x10000000
ADDR_FILTER = 0x40000000
ADDR_AES    = 0x50000000
ADDR_SYS    = 0xE0000000

# Filter debug output registers (must match Verilog mapping)
ADDR_CTLE_OUT      = ADDR_FILTER + 0x20
ADDR_DC_OFFSET_OUT = ADDR_FILTER + 0x24
ADDR_FIR_EQ_OUT    = ADDR_FILTER + 0x28
ADDR_DFE_OUT       = ADDR_FILTER + 0x2C
ADDR_GLITCH_OUT    = ADDR_FILTER + 0x30
ADDR_LPF_OUT       = ADDR_FILTER + 0x34

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
    print("\n--- Testing Filter Chain (Slave 3) ---")
    print("\n--- Comprehensive Filter Chain Test (Slave 3) ---")
    samples = [0x00000100, 0x00000200, 0x00000300, 0x00000400, 0x00000500]
    results = []
    pass_all = True
    for idx, sample in enumerate(samples):
        print(f"[*] Writing Sample {idx+1}: {sample} to Filter...")
        ahb_write(ser, ADDR_FILTER, sample)
        time.sleep(0.02)  # Slightly longer for chain latency
        # Read per-stage outputs
        ctle_out      = ahb_read(ser, ADDR_CTLE_OUT)
        dc_offset_out = ahb_read(ser, ADDR_DC_OFFSET_OUT)
        fir_eq_out    = ahb_read(ser, ADDR_FIR_EQ_OUT)
        dfe_out       = ahb_read(ser, ADDR_DFE_OUT)
        glitch_out    = ahb_read(ser, ADDR_GLITCH_OUT)
        lpf_out       = ahb_read(ser, ADDR_LPF_OUT)
        result        = ahb_read(ser, ADDR_FILTER)
        if result is not None:
            filtered_val = result & 0xFFF
            sample_12b = sample & 0xFFF
            results.append(filtered_val)
            print(f"[*] Stage Outputs:")
            print(f"    CTLE      : {ctle_out if ctle_out is not None else 'ERR'}")
            print(f"    DC Offset : {dc_offset_out if dc_offset_out is not None else 'ERR'}")
            print(f"    FIR EQ    : {fir_eq_out if fir_eq_out is not None else 'ERR'}")
            print(f"    DFE       : {dfe_out if dfe_out is not None else 'ERR'}")
            print(f"    Glitch    : {glitch_out if glitch_out is not None else 'ERR'}")
            print(f"    LPF       : {lpf_out if lpf_out is not None else 'ERR'}")
            print(f"    Final Out : 0x{result:08X} (Filtered: {filtered_val})")
            # Improved check: compare only lower 12 bits, and flag all-zero output
            if filtered_val == sample_12b:
                print(f"[-] Filter output matches input (0x{filtered_val:03X})! Possible filter bypass or error.")
                pass_all = False
            elif filtered_val == 0:
                print(f"[-] Filter output is zero! Possible malfunction or overly aggressive filtering.")
                pass_all = False
            else:
                print(f"[+] Filter output differs from input (0x{sample_12b:03X} -> 0x{filtered_val:03X}). Filter working.")
        else:
            print(f"[-] Filter Test FAIL (Read Error) for sample {sample}")
            pass_all = False
    print("\n--- Filter Chain Results ---")
    for idx, sample in enumerate(samples):
        print(f"Sample {idx+1}: Input={sample & 0xFFF}")
    print("(See above for per-stage outputs)")
    if pass_all:
        print("\n[+] Comprehensive Filter Test PASS: All outputs valid and filter working.")
    else:
        print("\n[-] Comprehensive Filter Test FAIL: One or more outputs invalid or zero.")

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

def power_analysis_loop(ser):
    print("\n==================================================")
    print("       POWER CONSUMPTION ANALYSIS MODE")
    print("==================================================")
    print("This mode runs a high-traffic loop to stress the bus.")
    print("You can measure the FPGA power (current) during the loops.")
    
    # 1. Disable Clock Gating
    print("\n[STEP 1] Disabling Clock Gating (High Power Mode)...")
    ahb_write(ser, ADDR_SYS, 0)
    
    input(">>> Press ENTER to start traffic loop (Gating OFF)...")
    print("[*] Running traffic for 10 seconds...")
    
    start_time = time.time()
    ops = 0
    while time.time() - start_time < 10:
        # Perform random R/W to all slaves to keep clock active
        ahb_write(ser, ADDR_RAM1, 0xAAAA5555)
        ahb_read(ser, ADDR_RAM1)
        ahb_write(ser, ADDR_FILTER, 0x123)
        ahb_read(ser, ADDR_FILTER)
        ops += 1
        
    print(f"[+] Done. Operations performed: {ops}")
    print(">>> Measure your baseline power now if holding peak.")
    
    # 2. Enable Clock Gating
    print("\n[STEP 2] Enabling Clock Gating (Low Power Mode)...")
    ahb_write(ser, ADDR_SYS, 1)
    
    input(">>> Press ENTER to start traffic loop (Gating ON)...")
    print("[*] Running traffic for 10 seconds...")
    
    start_time = time.time()
    ops = 0
    while time.time() - start_time < 10:
        # Same traffic pattern
        ahb_write(ser, ADDR_RAM1, 0xAAAA5555)
        ahb_read(ser, ADDR_RAM1)
        ahb_write(ser, ADDR_FILTER, 0x123)
        ahb_read(ser, ADDR_FILTER)
        ops += 1
        
    print(f"[+] Done. Operations performed: {ops}")
    print("[*] Compare the power measurements.")

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
            print("4. Run Power Analysis Comparison")
            print("5. Exit")
            
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
                ser.close()
                break
            else:
                print("Invalid selection.")