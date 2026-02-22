import serial
import serial.tools.list_ports
import time
import struct
import random

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SERIAL_PORT = 'COM5'  # Change this to your Basys 3 COM port
BAUD_RATE = 115200
TIMEOUT = 1

# Address Map
ADDR_RAM1   = 0x00000000
ADDR_RAM2   = 0x10000000
ADDR_FILTER = 0x40000000
ADDR_AES    = 0x50000000
ADDR_SYS    = 0xE0000000

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
    # Filter chain has 6 cycle latency.
    # We write a sample, wait slightly, then read.
    
    sample = 0x00000100 # 256
    print(f"[*] Writing Sample: {sample} to Filter...")
    ahb_write(ser, ADDR_FILTER, sample)
    
    # Simulate processing time (UART is slow enough, but good to be explicit)
    time.sleep(0.01) 
    
    result = ahb_read(ser, ADDR_FILTER)
    # Extract 12-bit result (assuming lower 12 bits)
    if result is not None:
        filtered_val = result & 0xFFF
        print(f"[*] Read Result: 0x{result:08X} (Filtered: {filtered_val})")
        
        # Simple check: Output should not be exactly input usually, but depends on filter state.
        # Just checking connectivity here.
        print("[+] Filter Test Connectivity PASS")
    else:
        print("[-] Filter Test FAIL (Read Error)")

def test_aes(ser):
    print("\n--- Testing AES (Slave 4) ---")
    # Assuming standard AES slave mapping:
    # 0x00-0x0F: Key
    # 0x10-0x1F: Plaintext
    # 0x20: Control/Status (Write 1 to start)
    # 0x30-0x3F: Ciphertext
    
    # 1. Write Key (Dummy)
    print("[*] Writing AES Key...")
    for i in range(4):
        ahb_write(ser, ADDR_AES + (i*4), 0xFFFFFFFF)
        
    # 2. Write Plaintext
    print("[*] Writing AES Plaintext...")
    for i in range(4):
        ahb_write(ser, ADDR_AES + 0x10 + (i*4), 0x00000000)
        
    # 3. Start Encryption
    print("[*] Starting Encryption...")
    ahb_write(ser, ADDR_AES + 0x20, 1)
    
    # 4. Wait for completion (UART delay is usually enough)
    time.sleep(0.05)
    
    # 5. Read Ciphertext
    print("[*] Reading Ciphertext...")
    c0 = ahb_read(ser, ADDR_AES + 0x30)
    
    if c0 is not None: 
        print(f"[*] Ciphertext[0]: 0x{c0:08X}")
        print("[+] AES Test Connectivity PASS")
    else:
        print("[-] AES Test FAIL (Read Error)")

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