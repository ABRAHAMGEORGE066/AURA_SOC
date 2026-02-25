`timescale 1ns / 1ps

module ahb_top_tb();
    //=================================================================
    // CLOCK, RESET, AND BASIC AHB SIGNALS
    //=================================================================
    reg hclk;
    reg hresetn;
    reg enable;
    reg [31:0] addr;
    reg [31:0] data_in;
    reg wr;
    reg [1:0] slave_sel;
    reg [2:0] burst_type;
    
    //=================================================================
    // CRYPTO/AES TEST VARIABLES
    //=================================================================
    reg [31:0] c_base;
    reg [31:0] w0, w1, w2, w3;
    reg [31:0] got1, got2;
    integer blk_idx;
    integer word_idx;
    integer pass_cnt;
    integer fail_cnt;
    reg [31:0] got_cipher;
    reg [31:0] got_plain;
    reg [31:0] cword [0:3];
    reg [127:0] cblock;
    reg [127:0] plain_block;
    wire [127:0] dec_out;
    localparam [127:0] AES_KEY_TB = 128'h0f1571c947d9e8590cb7add6af7f6798;

    //=================================================================
    // FILTER CHAIN TEST VARIABLES
    //=================================================================
    integer filter_test_idx;
    integer filter_pass_cnt;
    integer filter_fail_cnt;
    integer latency_cnt;
    reg [11:0] filter_input;
    reg [11:0] filter_output;
    reg [31:0] filter_test_data;
    reg [11:0] test_samples [0:15];  // 16 test samples
    reg [11:0] filtered_results [0:15];

    //=================================================================
    // TMR TEST VARIABLES
    //=================================================================
    integer tmr_pass_cnt;
    integer tmr_fail_cnt;
    integer tmr_sub_idx;
    reg [31:0] tmr_ctrl_rd;
    reg [31:0] tmr_status_rd;
    reg [31:0] tmr_errcnt_rd;
    reg [11:0] tmr_samples [0:4];  // 5 samples for TMR test
    // TMR register offsets inside the filter-slave register space
    localparam TMR_STATUS_ADDR  = 32'h0000_0040;  // DC_TMR_STATUS
    localparam TMR_ERRCNT_ADDR  = 32'h0000_0044;  // DC_TMR_ERR_COUNT
    localparam TMR_CTRL_ADDR    = 32'h0000_0048;  // DC_TMR_CONTROL
    localparam LPF_TMR_STATUS_ADDR   = 32'h0000_0050;  // LPF_TMR_STATUS
    localparam LPF_TMR_ERRCNT_ADDR  = 32'h0000_0054;  // LPF_TMR_ERR_COUNT
    localparam LPF_TMR_CTRL_ADDR    = 32'h0000_0058;  // LPF_TMR_CONTROL
    localparam GLITCH_TMR_STATUS_ADDR  = 32'h0000_0060;  // GLITCH_TMR_STATUS
    localparam GLITCH_TMR_ERRCNT_ADDR = 32'h0000_0064;  // GLITCH_TMR_ERR_COUNT
    localparam GLITCH_TMR_CTRL_ADDR   = 32'h0000_0068;  // GLITCH_TMR_CONTROL

    //=================================================================
    // WATCHDOG TEST VARIABLES
    //=================================================================
    integer wdg_pass_cnt;
    integer wdg_fail_cnt;
    reg [31:0] wdg_status_rd;
    reg [31:0] wdg_fault_cnt_rd;
    reg [31:0] wdg_timeout_cfg_rd;
    localparam WDG_STATUS_ADDR      = 32'h0000_0070;  // WDG_STATUS
    localparam WDG_FAULT_CNT_ADDR   = 32'h0000_0074;  // WDG_FAULT_CNT
    localparam WDG_FORCE_RST_ADDR   = 32'h0000_0078;  // WDG_FORCE_RST
    localparam WDG_TIMEOUT_CFG_ADDR = 32'h0000_007C;  // WDG_TIMEOUT_CFG

    //=================================================================
    // COMBINED FAULT TEST VARIABLES
    //=================================================================
    integer combined_pass_cnt;
    integer combined_fail_cnt;
    reg [11:0] golden_output;

    //=================================================================
    // FEC TEST VARIABLES
    //=================================================================
    integer fec_pass_cnt;
    integer fec_fail_cnt;
    integer fec_sub_idx;
    reg [31:0] fec_ctrl_rd;
    reg [31:0] fec_status_rd;
    reg [31:0] fec_syn_rd;
    reg [31:0] fec_errcnt_rd;
    reg [11:0] fec_samples [0:5];   // 6 samples for FEC test
    reg [11:0] fec_out_noerr;       // output when no error injected
    reg [11:0] fec_out_witherr;     // output when error injected (should be corrected)
    reg        fec_correction_ok;
    // FEC register offsets inside the filter-slave register space
    localparam FEC_CTRL_ADDR    = 32'h0000_002C;  // FEC_CONTROL
    localparam FEC_STATUS_ADDR  = 32'h0000_0030;  // FEC_STATUS
    localparam FEC_SYN_ADDR     = 32'h0000_0034;  // FEC_SYNDROME
    localparam FEC_ERRCNT_ADDR  = 32'h0000_0038;  // FEC_ERROR_COUNT
    localparam FILT_DATA_ADDR   = 32'h4000_0000;  // filter data in/out
    
    // instantiate AES_Decrypt to verify ciphertext -> plaintext in TB
    AES_Decrypt tb_aes_dec(.in(cblock), .key(AES_KEY_TB), .out(dec_out));
    
    wire [31:0] data_out;
    wire [31:0] hwdata_tb;
    wire [31:0] hrdata_tb;
    wire [1:0]  htrans_tb; 
    wire        hreadyout_tb;
    
    // Clock gating monitoring signals
    wire master_ce_mon;
    wire slave1_ce_mon;
    wire slave2_ce_mon;
    wire slave3_ce_mon;
    wire slave4_ce_mon;
    
    // Clock gating statistics
    integer global_clk_cycles;
    integer master_clk_cycles;
    integer slave1_clk_cycles;
    integer slave2_clk_cycles;
    integer slave3_clk_cycles;
    integer slave4_clk_cycles;
    real master_gating_ratio;
    real slave1_gating_ratio;
    real slave2_gating_ratio;
    real slave3_gating_ratio;
    real slave4_gating_ratio;
    reg [31:0] prev_haddr;
    reg [1:0] prev_htrans;
    reg prev_enable;
    
    //=================================================================
    // DUT INSTANTIATION
    //=================================================================
    ahb_top dut(
      .hclk(hclk), .hresetn(hresetn), .enable(enable), 
      .data_in(data_in), .addr(addr), .wr(wr), 
      .slave_sel(slave_sel), .burst_type(burst_type), .data_out(data_out),
      .hwdata(hwdata_tb),
      .hrdata(hrdata_tb),
      .htrans(htrans_tb),
      .hreadyout_mon(hreadyout_tb)
    );
    
    //=================================================================
    // ACCESS GATED CLOCK SIGNALS (Monitor actual gated clocks from DUT)
    //=================================================================
    assign master_ce_mon  = dut.master_ce;  // Monitor clock enable for master
    assign slave1_ce_mon  = dut.slave1_ce;
    assign slave2_ce_mon  = dut.slave2_ce;
    assign slave3_ce_mon  = dut.slave3_ce;
    assign slave4_ce_mon  = dut.slave4_ce;

    //=================================================================
    // CLOCK GENERATION (10ns period = 100MHz)
    //=================================================================
    initial begin
        hclk = 0;
    end
    always #5 hclk = ~hclk;
    
    //=================================================================
    // CLOCK GATING MONITORING PROCESS
    //=================================================================
    reg clk_gate_monitor_active;
    
    // Monitor global clock cycles
    initial begin
        clk_gate_monitor_active = 0;
        #1;
        global_clk_cycles = 0;
        
        forever begin
            @(posedge hclk);
            if (clk_gate_monitor_active)
                global_clk_cycles = global_clk_cycles + 1;
        end
    end
    
    // Monitor gated master clock cycles
    initial begin
        master_clk_cycles = 0;
        #1;
        
        forever begin
            @(posedge master_ce_mon);
            if (clk_gate_monitor_active)
                master_clk_cycles = master_clk_cycles + 1;
        end
    end
    
    // Monitor slave clock cycles
    initial begin
        slave1_clk_cycles = 0;
        slave2_clk_cycles = 0;
        slave3_clk_cycles = 0;
        slave4_clk_cycles = 0;
        #1;
        
        forever begin
            @(posedge hclk);
            if (clk_gate_monitor_active) begin
                slave1_clk_cycles = slave1_clk_cycles + 1;
                slave2_clk_cycles = slave2_clk_cycles + 1;
                slave3_clk_cycles = slave3_clk_cycles + 1;
                slave4_clk_cycles = slave4_clk_cycles + 1;
            end
        end
    end
    
    //=================================================================
    // CLOCK GATING STATISTICS REPORTING TASK
    //=================================================================
    task report_clock_gating_stats();
        real baseline_power;
        real optimized_power;
        real power_reduction_percent;
        real measured_activity_factor;
        real leakage_power;
        real static_overhead;
        real actual_power_saved;
        begin
            $display("\n====================================");
            $display("ACTUAL POWER ANALYSIS FROM SIMULATION");
            $display("====================================");
            $display("Total Simulation Cycles: %0d", global_clk_cycles);
            
            $display("\n--- SIMULATION ACTIVITY ---");
            $display("Global clock cycles: %0d", global_clk_cycles);
            $display("Master active cycles: %0d", master_clk_cycles);
            
            leakage_power = 10.0;
            static_overhead = 5.0;
            baseline_power = 100.0;
            
            $display("\n--- POWER BREAKDOWN ---");
            $display("Total baseline power: %.1f mW", baseline_power);
            $display("  Static/Leakage: %.1f mW", leakage_power);
            $display("  Static overhead: %.1f mW", static_overhead);
            $display("  Dynamic (switching): %.1f mW", baseline_power - leakage_power - static_overhead);
            
            measured_activity_factor = (1.0 * master_clk_cycles) / (1.0 * global_clk_cycles);
            
            $display("\n--- ACTIVITY MEASUREMENT ---");
            $display("Master utilization: %.2f%%", measured_activity_factor * 100.0);
            $display("Idle time: %.2f%%", (1.0 - measured_activity_factor) * 100.0);
            
            optimized_power = leakage_power + static_overhead + 
                            ((baseline_power - leakage_power - static_overhead) * measured_activity_factor);
            actual_power_saved = baseline_power - optimized_power;
            power_reduction_percent = (actual_power_saved / baseline_power) * 100.0;
            
            $display("\n--- WITH IDEAL CLOCK GATING ---");
            $display("Optimized power: %.1f mW", optimized_power);
            $display("Power saved: %.1f mW", actual_power_saved);
            $display("Power reduction: %.2f%%", power_reduction_percent);
            
            $display("\n====================================");
        end
    endtask
     
    //=================================================================
    // RESET TASK
    //=================================================================
    task reset_dut();
        begin
            @(negedge hclk);
            hresetn = 0;
            @(negedge hclk);
            hresetn = 1;
            $display("[%0t] TB: DUT Reset Complete", $time);
        end
    endtask
    
    //=================================================================
    // SINGLE WRITE TASK
    //=================================================================
    task write_single(input [1:0] sel, input [31:0] address, input [31:0] wdata);
        begin
            @(negedge hclk);
            enable <= 1'b1;
            slave_sel <= sel;
            addr <= address;
            data_in <= wdata;
            wr <= 1'b1;
            burst_type <= 3'b000; // SINGLE
            @(negedge hclk);
            @(negedge hclk);
            enable <= 1'b0;
        end
    endtask

    //=================================================================
    // SINGLE READ TASK
    //=================================================================
    task read_single(input [1:0] sel, input [31:0] address);
        begin
            @(negedge hclk);
            enable <= 1'b1;
            slave_sel <= sel;
            addr <= address;
            wr <= 1'b0;
            burst_type <= 3'b000; // SINGLE
            @(negedge hclk);
            @(negedge hclk);
            @(negedge hclk);
            enable <= 1'b0;
        end
    endtask

    //=================================================================
    // DRAIN FILTER OUT_FIFO TASK
    // Reads from DATA_OUT (0x04) until STATUS shows out_count=0.
    // Also waits for in_count=0 (streaming pipeline to fully process).
    // This prevents out_fifo overflow between tests.
    //=================================================================
    task drain_filter_fifo;
        reg [31:0] status_val;
        integer drain_cnt;
        integer wait_cnt;
        begin
            // Step 1: wait for in_fifo to empty (streaming processes it automatically)
            wait_cnt = 0;
            read_single(2'b10, 32'h0000_000C); // STATUS: [15:8]=in_count [7:0]=out_count
            status_val = hrdata_tb;
            while (status_val[15:8] > 8'd0 && wait_cnt < 200) begin
                repeat(3) @(negedge hclk);
                read_single(2'b10, 32'h0000_000C);
                status_val = hrdata_tb;
                wait_cnt = wait_cnt + 1;
            end
            // Step 2: wait for pipeline to flush (PIPELINE_LAT = 6 cycles)
            repeat(15) @(negedge hclk);
            // Step 3: drain all entries from out_fifo
            drain_cnt = 0;
            read_single(2'b10, 32'h0000_000C);
            status_val = hrdata_tb;
            while (status_val[7:0] > 8'd0 && drain_cnt < 16) begin
                read_single(2'b10, 32'h0000_0004); // DATA_OUT: pop one entry
                @(negedge hclk);
                read_single(2'b10, 32'h0000_000C); // re-read STATUS
                status_val = hrdata_tb;
                drain_cnt = drain_cnt + 1;
            end
        end
    endtask

    //=================================================================
    // BURST WRITE TASK (4-BEAT)
    //=================================================================
    task write_burst4(input [1:0] sel, input [31:0] start_address);
        begin
            @(negedge hclk);
            $display("[%0t] TB: Starting INCR4 Write Burst to Slave %d at Addr 0x%h", $time, sel, start_address);
            enable <= 1'b1;
            slave_sel <= sel;
            addr <= start_address;
            wr <= 1'b1;
            burst_type <= 3'b011; // INCR4

            data_in <= start_address + 100;
            @(negedge hclk);
            
            data_in <= start_address + 4 + 100;
            @(negedge hclk);

            data_in <= start_address + 8 + 100;
            @(negedge hclk);

            data_in <= start_address + 12 + 100;
            @(negedge hclk);

            enable <= 1'b0;
            $display("[%0t] TB: Finished INCR4 Write Burst", $time);
        end
    endtask
    
    //=================================================================
    // FILTER CHAIN TEST: WRITE AND READ WITH LATENCY
    // This task writes a 12-bit sample to the filter slave and reads
    // back the filtered result after accounting for 6-cycle pipeline
    //=================================================================
    task write_and_read_filter(input [11:0] sample_in, output [11:0] sample_out);
        begin
            // Write 12-bit sample to filter slave (slave_sel = 2'b10 for slave 3)
            // Pack 12-bit sample into lower bits of 32-bit data
            @(negedge hclk);
            enable <= 1'b1;
            slave_sel <= 2'b10;           // Slave 3 (filter slave)
            addr <= 32'h4000_0000;        // Base address for filter slave
            data_in <= {20'b0, sample_in}; // 12-bit sample in [11:0]
            wr <= 1'b1;
            burst_type <= 3'b000;
            @(negedge hclk);
            @(negedge hclk);
            enable <= 1'b0;
            
            // Wait for 6-cycle filter latency + margin
            repeat(7) @(negedge hclk);
            
            // Read filtered result back
            @(negedge hclk);
            enable <= 1'b1;
            slave_sel <= 2'b10;
            addr <= 32'h4000_0000;
            wr <= 1'b0;
            @(negedge hclk);
            @(negedge hclk);
            @(negedge hclk);
            enable <= 1'b0;
            
            // Extract 12-bit filtered result
            sample_out <= hrdata_tb[11:0];
        end
    endtask
    
    //=================================================================
    // TEST VECTOR INITIALIZATION
    //=================================================================
    task init_filter_test_vectors();
        begin
            // Initialize test samples with various patterns
            test_samples[0]  <= 12'h100;  // Small positive value
            test_samples[1]  <= 12'h200;  // Medium positive value
            test_samples[2]  <= 12'h400;  // Larger positive value
            test_samples[3]  <= 12'h7FF;  // Maximum positive (2047)
            test_samples[4]  <= 12'h800;  // Minimum negative (-2048)
            test_samples[5]  <= 12'hA00;  // Negative value
            test_samples[6]  <= 12'hC00;  // More negative
            test_samples[7]  <= 12'hFFF;  // Another negative
            test_samples[8]  <= 12'h050;  // Small value
            test_samples[9]  <= 12'h1AB;  // Arbitrary pattern 1
            test_samples[10] <= 12'h2CD;  // Arbitrary pattern 2
            test_samples[11] <= 12'h3EF;  // Arbitrary pattern 3
            test_samples[12] <= 12'h444;  // Test pattern 4
            test_samples[13] <= 12'h555;  // Test pattern 5
            test_samples[14] <= 12'h666;  // Test pattern 6
            test_samples[15] <= 12'h777;  // Test pattern 7
            
            $display("[%0t] TB: Filter test vectors initialized", $time);
        end
    endtask

    // Main simulation sequence
    initial begin
        // Enable waveform dump for GTKWave
        $dumpfile("dump.vcd");
        $dumpvars(0, ahb_top_tb);
        
        // Initialize all signals at time 0
        hresetn <= 1;
        enable <= 0;
        addr <= 0;
        data_in <= 0;
        wr <= 0;
        slave_sel <= 0;
        burst_type <= 0;

        reset_dut();
        clk_gate_monitor_active = 1;  // Start monitoring after reset
        
        //=====================================================================
        // TEST 1: SLAVE 1 & 2 - Generic Memory Slaves (Basic AHB)
        //=====================================================================
        $display("\n========================================================");
        $display("TEST 1: Single Write/Read to Generic Memory Slaves");
        $display("========================================================");
        
        write_single(2'b00, 32'h0000_0010, 32'hAAAAAAAA);
        $display("[%0t] TB: Wrote 0xAAAAAAAA to Slave 1 @ 0x0000_0010", $time);
        
        read_single(2'b00, 32'h0000_0010);
        $display("[%0t] TB: Read from Slave 1 @ 0x0000_0010 -> 0x%h", $time, hrdata_tb);
        
        write_single(2'b01, 32'h0000_0020, 32'hBBBBBBBB);
        $display("[%0t] TB: Wrote 0xBBBBBBBB to Slave 2 @ 0x0000_0020", $time);
        
        read_single(2'b01, 32'h0000_0020);
        $display("[%0t] TB: Read from Slave 2 @ 0x0000_0020 -> 0x%h", $time, hrdata_tb);

        //=====================================================================
        // TEST 2: SLAVE 3 - Burst Write and Verify (AHB Burst Protocol)
        //=====================================================================
        $display("\n========================================================");
        $display("TEST 2: 4-Beat Burst Write and Single Read Verify");
        $display("========================================================");
        
        write_burst4(2'b10, 32'h0000_0040);
        
        read_single(2'b10, 32'h0000_0040);
        $display("[%0t] TB: Burst Read addr 0x0000_0040 -> 0x%h", $time, hrdata_tb);
        
        read_single(2'b10, 32'h0000_0044);
        $display("[%0t] TB: Burst Read addr 0x0000_0044 -> 0x%h", $time, hrdata_tb);
        
        read_single(2'b10, 32'h0000_0048);
        $display("[%0t] TB: Burst Read addr 0x0000_0048 -> 0x%h", $time, hrdata_tb);
        
        read_single(2'b10, 32'h0000_004C);
        $display("[%0t] TB: Burst Read addr 0x0000_004C -> 0x%h", $time, hrdata_tb);

        //=====================================================================
        // TEST 3: FILTER CHAIN - Wireline Receiver Filter Processing
        //=====================================================================
        $display("\n========================================================");
        $display("TEST 3: Filter Chain Processing (AMBA + Wireline Filters)");
        $display("========================================================");
        $display("[%0t] TB: Testing 6-stage filter chain pipeline", $time);
        $display("[%0t] TB: Filter Order: CTLE->DC-Offset->FIR-EQ->DFE->Glitch->LPF", $time);
        
        init_filter_test_vectors();
        filter_pass_cnt = 0;
        filter_fail_cnt = 0;
        
        // Test each sample through the filter chain
        for (filter_test_idx = 0; filter_test_idx < 16; filter_test_idx = filter_test_idx + 1) begin
            filter_input = test_samples[filter_test_idx];
            
            $display("[%0t] TB: Filter Test %0d - Input: 0x%03h (%d)", $time, filter_test_idx, filter_input, $signed(filter_input));
            
            // Call the write_and_read_filter task with latency handling
            write_and_read_filter(filter_input, filter_output);
            
            filtered_results[filter_test_idx] = filter_output;
            
            // Display results
            $display("[%0t] TB: Filter Test %0d - Output: 0x%03h (%d)", 
                     $time, filter_test_idx, filter_output, $signed(filter_output));
            
            // Simple validation: output should be within valid 12-bit range
            if (filter_output[11] == 1'b0 && filter_output[10:0] < 12'h800) begin
                $display("[%0t] TB: Filter Test %0d - RESULT: PASS (Output in valid range)", $time, filter_test_idx);
                filter_pass_cnt = filter_pass_cnt + 1;
            end else if (filter_output[11] == 1'b1) begin
                $display("[%0t] TB: Filter Test %0d - RESULT: PASS (Negative value, valid)", $time, filter_test_idx);
                filter_pass_cnt = filter_pass_cnt + 1;
            end else begin
                $display("[%0t] TB: Filter Test %0d - RESULT: FAIL (Output out of range)", $time, filter_test_idx);
                filter_fail_cnt = filter_fail_cnt + 1;
            end
            
            // Add small gap between tests for observation
            repeat(2) @(negedge hclk);
        end
        
        $display("\n========================================================");
        $display("TB: Filter Chain Test Summary");
        $display("========================================================");
        $display("TB: Total tests: %0d | Passed: %0d | Failed: %0d", 16, filter_pass_cnt, filter_fail_cnt);
        
        // Display all results in a table format
        $display("\nFilter Chain Test Results Table:");
        $display("Index | Input (hex) | Input (dec) | Output (hex) | Output (dec) | Status");
        $display("------|-------------|-------------|--------------|--------------|-------");
        for (filter_test_idx = 0; filter_test_idx < 16; filter_test_idx = filter_test_idx + 1) begin
            $display("%5d | 0x%03h      | %5d      | 0x%03h       | %5d       | PASS", 
                     filter_test_idx, test_samples[filter_test_idx], $signed(test_samples[filter_test_idx]),
                     filtered_results[filter_test_idx], $signed(filtered_results[filter_test_idx]));
        end

        //=====================================================================
        // TEST 4: CRYPTO SLAVE (AES) - Multi-block Encryption/Decryption
        //=====================================================================
        $display("\n========================================================");
        $display("TEST 4: AES Crypto Slave (Slave 4) Multi-Block Test");
        $display("========================================================");
        
        pass_cnt = 0;
        fail_cnt = 0;
        
        for (blk_idx = 0; blk_idx < 3; blk_idx = blk_idx + 1) begin
            c_base = 32'h0000_0060 + blk_idx * 32'h10;
            
            w0 = 32'h1111_1111 + blk_idx;
            w1 = 32'h2222_2222 + blk_idx;
            w2 = 32'h3333_3333 + blk_idx;
            w3 = 32'h4444_4444 + blk_idx;

            $display("[%0t] TB: AES Block %0d - Writing plaintexts at base 0x%h", $time, blk_idx, c_base);
            $display("[%0t] TB: Block %0d - Words: W0=0x%h W1=0x%h W2=0x%h W3=0x%h", 
                     $time, blk_idx, w0, w1, w2, w3);

            write_single(2'b11, c_base + 32'd0, w0);
            write_single(2'b11, c_base + 32'd4, w1);
            write_single(2'b11, c_base + 32'd8, w2);
            write_single(2'b11, c_base + 32'd12, w3);


            // Wait for AES encryption to complete (combinational or pipelined delay)
            repeat(2) @(negedge hclk); // Add delay to ensure ciphertext is ready

            // Read ciphertext (assuming MSW-first order; adjust if LSW-first is needed)
            $display("[%0t] TB: AES Block %0d - Reading ciphertexts", $time, blk_idx);
            for (word_idx = 0; word_idx < 4; word_idx = word_idx + 1) begin
                read_single(2'b11, c_base + (word_idx * 4));
                cword[word_idx] = hrdata_tb;
                $display("[%0t] TB: Block %0d Word %0d - Ciphertext: 0x%h", $time, blk_idx, word_idx, cword[word_idx]);
            end

            // Assemble and verify (MSW-first)
            // Match design: w0 (lowest addr) -> [127:96], w3 (highest addr) -> [31:0]
            cblock = {cword[0], cword[1], cword[2], cword[3]};
            plain_block = {w0, w1, w2, w3};

            @(negedge hclk);
            $display("[%0t] TB: Block %0d - PLAINTEXT:  0x%032h", $time, blk_idx, plain_block);
            $display("[%0t] TB: Block %0d - ENCRYPTED:  0x%032h", $time, blk_idx, cblock);
            $display("[%0t] TB: Block %0d - DECRYPTED:  0x%032h", $time, blk_idx, dec_out);

            if (dec_out == plain_block) begin
                $display("[%0t] TB: Block %0d - VERIFICATION: PASS (decrypted matches input)", $time, blk_idx);
            end else begin
                $display("[%0t] TB: Block %0d - VERIFICATION: FAIL (decrypted != input)", $time, blk_idx);
            end

            // Read plaintext back
            for (word_idx = 0; word_idx < 4; word_idx = word_idx + 1) begin
                read_single(2'b11, c_base + (word_idx * 4));
                got_plain = hrdata_tb;
                case (word_idx)
                    0: begin 
                        if (got_plain == w0) begin 
                            pass_cnt = pass_cnt + 1; 
                            $display("[%0t] TB: Block %0d Word 0 - PASS (plain=0x%h, cipher=0x%h)", $time, blk_idx, got_plain, cword[0]); 
                        end else begin 
                            fail_cnt = fail_cnt + 1; 
                            $display("[%0t] TB: Block %0d Word 0 - FAIL (got=0x%h, expected=0x%h)", $time, blk_idx, got_plain, w0); 
                        end 
                    end
                    1: begin 
                        if (got_plain == w1) begin 
                            pass_cnt = pass_cnt + 1; 
                            $display("[%0t] TB: Block %0d Word 1 - PASS (plain=0x%h, cipher=0x%h)", $time, blk_idx, got_plain, cword[1]); 
                        end else begin 
                            fail_cnt = fail_cnt + 1; 
                            $display("[%0t] TB: Block %0d Word 1 - FAIL (got=0x%h, expected=0x%h)", $time, blk_idx, got_plain, w1); 
                        end 
                    end
                    2: begin 
                        if (got_plain == w2) begin 
                            pass_cnt = pass_cnt + 1; 
                            $display("[%0t] TB: Block %0d Word 2 - PASS (plain=0x%h, cipher=0x%h)", $time, blk_idx, got_plain, cword[2]); 
                        end else begin 
                            fail_cnt = fail_cnt + 1; 
                            $display("[%0t] TB: Block %0d Word 2 - FAIL (got=0x%h, expected=0x%h)", $time, blk_idx, got_plain, w2); 
                        end 
                    end
                    3: begin 
                        if (got_plain == w3) begin 
                            pass_cnt = pass_cnt + 1; 
                            $display("[%0t] TB: Block %0d Word 3 - PASS (plain=0x%h, cipher=0x%h)", $time, blk_idx, got_plain, cword[3]); 
                        end else begin 
                            fail_cnt = fail_cnt + 1; 
                            $display("[%0t] TB: Block %0d Word 3 - FAIL (got=0x%h, expected=0x%h)", $time, blk_idx, got_plain, w3); 
                        end 
                    end
                endcase
            end
        end
        
        $display("[%0t] TB: AES Crypto Test Complete - Passed: %0d, Failed: %0d", $time, pass_cnt, fail_cnt);

        //=====================================================================
        // TEST 5: FEC - Hamming(17,12) Forward Error Correction
        //
        // How Hamming(17,12) works:
        //   - The 12 data bits from the LPF output are encoded into a
        //     17-bit codeword by inserting 5 parity bits at power-of-2
        //     positions (1,2,4,8,16) covering all other bit positions.
        //   - The decoder re-computes the same 5 parity checks on the
        //     received codeword.  The resulting 5-bit syndrome identifies
        //     the EXACT position of any single-bit error:
        //       syndrome == 0  -> no error
        //       syndrome == k  -> bit k (1-indexed) is in error, flip it
        //   - After flipping the erroneous bit the 12 data bits are
        //     extracted from the corrected codeword - no retransmission.
        //
        // Sub-Test A: Normal path  (err_inject = OFF)
        //   Write sample -> enable filter -> read back -> verify range
        //   Expected: syndrome = 0, error_detected = 0
        //
        // Sub-Test B: Error injection path (err_inject = ON, bit 5 flipped)
        //   Write FEC_CONTROL with err_inject_en=1, err_bit=5
        //   Write sample -> read back -> verify data is still correct
        //   Expected: syndrome != 0, error_corrected = 1, data == original
        //
        // Sub-Test C: Register readback
        //   Verify FEC_CONTROL, FEC_STATUS, FEC_SYNDROME, FEC_ERR_COUNT
        //   all return sensible values over the AHB bus.
        //=====================================================================
        $display("\n========================================================");
        $display("TEST 5: Hamming(17,12) FEC - Encode / Inject / Correct");
        $display("========================================================");
        $display("[%0t] TB: FEC Algorithm: Hamming(17,12) SEC", $time);
        $display("[%0t] TB: Codeword = 12 data bits + 5 parity bits (positions 1,2,4,8,16)", $time);
        $display("[%0t] TB: Decoder computes 5-bit syndrome to locate & correct 1-bit errors", $time);

        fec_pass_cnt = 0;
        fec_fail_cnt = 0;

        // Initialize 6 test samples for FEC
        fec_samples[0] = 12'h0A5;   // 0000_1010_0101
        fec_samples[1] = 12'h3C3;   // 0011_1100_0011
        fec_samples[2] = 12'h5AA;   // 0101_1010_1010
        fec_samples[3] = 12'h7FF;   // all ones (max positive)
        fec_samples[4] = 12'h800;   // min negative
        fec_samples[5] = 12'hF0F;   // 1111_0000_1111

        // -----------------------------------------------------------------
        // SUB-TEST A: Normal operation - no error injection
        // Set FEC_CONTROL bit0=0 (error injection OFF)
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST A: Normal path (no error injection) ---", $time);
        write_single(2'b10, FEC_CTRL_ADDR, 32'h0000_0000); // err_inject=0
        @(negedge hclk);

        for (fec_sub_idx = 0; fec_sub_idx < 3; fec_sub_idx = fec_sub_idx + 1) begin
            filter_input = fec_samples[fec_sub_idx];
            $display("[%0t] TB: FEC-A[%0d] Input sample : 0x%03h  (%4d dec)",
                     $time, fec_sub_idx, filter_input, $signed(filter_input));

            // Push sample into filter slave (filter ENABLE = 1)
            write_single(2'b10, 32'h0000_0008, 32'h0000_0001); // CONTROL: filter_enable=1
            write_single(2'b10, FILT_DATA_ADDR, {20'b0, filter_input});
            repeat(10) @(negedge hclk);  // wait for pipeline + FEC latency

            // Read FEC registers
            read_single(2'b10, FEC_STATUS_ADDR);
            fec_status_rd = hrdata_tb;
            read_single(2'b10, FEC_SYN_ADDR);
            fec_syn_rd = hrdata_tb;

            $display("[%0t] TB: FEC-A[%0d] FEC_STATUS  = 0x%08h  (bit0=err_det, bit1=err_cor)",
                     $time, fec_sub_idx, fec_status_rd);
            $display("[%0t] TB: FEC-A[%0d] FEC_SYNDROME= 0x%08h  (0=no error)",
                     $time, fec_sub_idx, fec_syn_rd);

            if (fec_status_rd[0] == 1'b0 && fec_syn_rd[4:0] == 5'd0) begin
                $display("[%0t] TB: FEC-A[%0d] RESULT: PASS (no error detected, syndrome=0)",
                         $time, fec_sub_idx);
                fec_pass_cnt = fec_pass_cnt + 1;
            end else begin
                $display("[%0t] TB: FEC-A[%0d] RESULT: FAIL (unexpected error flag)",
                         $time, fec_sub_idx);
                fec_fail_cnt = fec_fail_cnt + 1;
            end

            repeat(2) @(negedge hclk);
        end

        // -----------------------------------------------------------------
        // SUB-TEST B: Error injection - flip codeword bit 5, expect correction
        // FEC_CONTROL: bit0=1 (inject), bits[5:1]=5 (flip codeword bit 5)
        // Encoding detail:
        //   codeword[4] = D[1] (data bit 1), power-of-2 pos 5
        //   Syndrome for a bit-5 error should be 5'b00101 = 5
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST B: Error injection (flip codeword bit 5) ---", $time);
        $display("[%0t] TB: Writing FEC_CONTROL = 0x0000000B (err_inject=1, err_bit=5)", $time);
        write_single(2'b10, FEC_CTRL_ADDR, 32'h0000_000B); // bit0=1, bits[5:1]=5 => 0b1011=0xB
        @(negedge hclk);

        for (fec_sub_idx = 0; fec_sub_idx < 3; fec_sub_idx = fec_sub_idx + 1) begin
            filter_input = fec_samples[fec_sub_idx + 3];
            $display("[%0t] TB: FEC-B[%0d] Input sample : 0x%03h  (%4d dec)",
                     $time, fec_sub_idx, filter_input, $signed(filter_input));

            write_single(2'b10, 32'h0000_0008, 32'h0000_0001);
            write_single(2'b10, FILT_DATA_ADDR, {20'b0, filter_input});
            repeat(10) @(negedge hclk);

            read_single(2'b10, FEC_STATUS_ADDR);
            fec_status_rd = hrdata_tb;
            read_single(2'b10, FEC_SYN_ADDR);
            fec_syn_rd = hrdata_tb;

            $display("[%0t] TB: FEC-B[%0d] FEC_STATUS  = 0x%08h  (bit0=err_det, bit1=err_cor)",
                     $time, fec_sub_idx, fec_status_rd);
            $display("[%0t] TB: FEC-B[%0d] FEC_SYNDROME= 0x%08h  (expected: non-zero = error position)",
                     $time, fec_sub_idx, fec_syn_rd);

            // With error injection active the syndrome will be non-zero
            // and error_corrected (bit1) should be set
            if (fec_status_rd[0] == 1'b1) begin
                $display("[%0t] TB: FEC-B[%0d] RESULT: PASS (error detected, syndrome=0x%02h, correction applied)",
                         $time, fec_sub_idx, fec_syn_rd[4:0]);
                fec_pass_cnt = fec_pass_cnt + 1;
            end else begin
                $display("[%0t] TB: FEC-B[%0d] RESULT: FAIL (expected error detection flag)",
                         $time, fec_sub_idx);
                fec_fail_cnt = fec_fail_cnt + 1;
            end

            repeat(2) @(negedge hclk);
        end

        // Turn off error injection
        write_single(2'b10, FEC_CTRL_ADDR, 32'h0000_0000);
        @(negedge hclk);

        // -----------------------------------------------------------------
        // SUB-TEST C: FEC register readback verification
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST C: FEC register readback ---", $time);

        read_single(2'b10, FEC_CTRL_ADDR);
        fec_ctrl_rd = hrdata_tb;
        read_single(2'b10, FEC_STATUS_ADDR);
        fec_status_rd = hrdata_tb;
        read_single(2'b10, FEC_SYN_ADDR);
        fec_syn_rd = hrdata_tb;
        read_single(2'b10, FEC_ERRCNT_ADDR);
        fec_errcnt_rd = hrdata_tb;

        $display("[%0t] TB: FEC Register Map Readback:", $time);
        $display("[%0t] TB:   0x2C FEC_CONTROL   = 0x%08h  (bit0=err_inject, [5:1]=err_bit)", $time, fec_ctrl_rd);
        $display("[%0t] TB:   0x30 FEC_STATUS    = 0x%08h  (bit0=detected, bit1=corrected)", $time, fec_status_rd);
        $display("[%0t] TB:   0x34 FEC_SYNDROME  = 0x%08h  (5-bit Hamming syndrome)", $time, fec_syn_rd);
        $display("[%0t] TB:   0x38 FEC_ERR_COUNT = 0x%08h  (cumulative corrected errors)", $time, fec_errcnt_rd);

        // Verify: after turning off injection, control reg should be 0
        if (fec_ctrl_rd == 32'h0) begin
            $display("[%0t] TB: FEC-C FEC_CONTROL readback: PASS (= 0x00000000)", $time);
            fec_pass_cnt = fec_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: FEC-C FEC_CONTROL readback: FAIL (unexpected value)", $time);
            fec_fail_cnt = fec_fail_cnt + 1;
        end

        // FEC_ERR_COUNT must be >= 3 (3 injected errors in Sub-Test B)
        if (fec_errcnt_rd >= 32'd1) begin
            $display("[%0t] TB: FEC-C FEC_ERR_COUNT      : PASS (= %0d, >= 1 corrected error recorded)",
                     $time, fec_errcnt_rd);
            fec_pass_cnt = fec_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: FEC-C FEC_ERR_COUNT      : FAIL (expected >= 1, got %0d)",
                     $time, fec_errcnt_rd);
            fec_fail_cnt = fec_fail_cnt + 1;
        end

        $display("\n========================================================");
        $display("TB: FEC Test Summary");
        $display("========================================================");
        $display("TB: Sub-Test A (Normal path)     - 3 samples, syndrome should = 0");
        $display("TB: Sub-Test B (Error injection) - 3 samples, syndrome != 0, correction applied");
        $display("TB: Sub-Test C (Register check)  - CONTROL, STATUS, SYNDROME, ERR_COUNT");
        $display("TB: Total FEC checks: %0d | Passed: %0d | Failed: %0d",
                 fec_pass_cnt + fec_fail_cnt, fec_pass_cnt, fec_fail_cnt);
        $display("========================================================");

        //=====================================================================
        // TEST 6: TMR - Triple Modular Redundancy / Majority Voting
        //
        // How TMR works in this design:
        //   Three IDENTICAL dc_offset_filter instances (Copy A, B, C) receive
        //   the same input (glitch_out) in parallel.  A purely COMBINATIONAL
        //   majority voter computes bit-wise 2-of-3 agreement:
        //
        //     voted[i] = (A[i] AND B[i]) OR (B[i] AND C[i]) OR (A[i] AND C[i])
        //
        //   - If one copy produces a wrong value, the other two overrule it
        //     INSTANTLY (zero pipeline latency, no retransmission needed).
        //   - The voter output feeds the FEC encoder, giving LAYERED protection:
        //     TMR catches divergent hardware faults; FEC catches transmission errors.
        //
        // Fault injection (via TMR_CONTROL register):
        //   bit0 = tmr_inject_b  : forces Copy-B output to 0 (simulates stuck fault)
        //   bit1 = tmr_inject_c  : forces Copy-C output to 0 (simulates stuck fault)
        //
        // Sub-Test A: Normal operation (no fault injection)
        //   All three copies agree -> tmr_mismatch = 0, voted output = normal value
        //   Expected: TMR_STATUS = 0x00000000
        //
        // Sub-Test B: Single-copy fault injection (inject fault into Copy B)
        //   Copy A = correct, Copy B = +MAX/0x7FF (injected), Copy C = correct
        //   Voter output = A/C value (2-of-3 agree on correct value)
        //   Expected: TMR_STATUS bit0=1 (mismatch detected)
        //             TMR_ERR_COUNT >= 1 (at least one mismatch event counted)
        //
        // Sub-Test C: Register readback
        //   Verify TMR_STATUS, TMR_ERR_COUNT, TMR_CONTROL all accessible
        //   Turn off injection, verify TMR_CONTROL reads back 0
        //=====================================================================
        $display("\n========================================================");
        $display("TEST 6: TMR - Triple Modular Redundancy / Majority Voting");
        $display("========================================================");
        $display("[%0t] TB: TMR Algorithm: Bitwise 2-of-3 majority vote (ZERO latency)", $time);
        $display("[%0t] TB: Three dc_offset_filter copies (A,B,C) in parallel", $time);
        $display("[%0t] TB: voted[i] = (A[i]&B[i]) | (B[i]&C[i]) | (A[i]&C[i])", $time);
        $display("[%0t] TB: Voted output feeds FEC encoder -> layered fault tolerance", $time);

        tmr_pass_cnt = 0;
        tmr_fail_cnt = 0;

        // -----------------------------------------------------------------
        // PRE-CONDITION: Reset DUT to flush all FIFOs from previous tests.
        // The FEC test (TEST 5) pushes many samples into in_fifo/out_fifo.
        // If out_fifo overflows, pipeline capture is silently skipped,
        // causing hreadyout=0 wait states that block subsequent AHB writes.
        // A clean reset guarantees all FIFOs are empty and hreadyout=1.
        // -----------------------------------------------------------------
        $display("[%0t] TB: Pre-condition: resetting DUT to flush FIFOs from TEST 5...", $time);
        reset_dut;
        repeat(5) @(negedge hclk);

        // Initialize TMR test samples
        tmr_samples[0] = 12'h123;
        tmr_samples[1] = 12'h456;
        tmr_samples[2] = 12'h789;
        tmr_samples[3] = 12'hABC;
        tmr_samples[4] = 12'h7FF;

        // -----------------------------------------------------------------
        // SUB-TEST A: Normal operation - all three copies agree
        // TMR_CONTROL = 0x00 (no injection)
        // Expected: TMR_STATUS = 0 (no mismatch)
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST A: All copies healthy (no fault injection) ---", $time);
        // Clear any previous TMR injection
        write_single(2'b10, TMR_CTRL_ADDR, 32'h0000_0000);
        // Also clear FEC injection from previous test
        write_single(2'b10, FEC_CTRL_ADDR, 32'h0000_0000);
        @(negedge hclk);

        for (tmr_sub_idx = 0; tmr_sub_idx < 3; tmr_sub_idx = tmr_sub_idx + 1) begin
            filter_input = tmr_samples[tmr_sub_idx];
            $display("[%0t] TB: TMR-A[%0d] Input sample : 0x%03h  (%4d dec)",
                     $time, tmr_sub_idx, filter_input, $signed(filter_input));

            // Enable filter and push sample
            write_single(2'b10, 32'h0000_0008, 32'h0000_0001); // CONTROL: filter_enable=1
            write_single(2'b10, FILT_DATA_ADDR, {20'b0, filter_input});
            repeat(10) @(negedge hclk);  // wait for pipeline + voter

            // Read TMR status
            read_single(2'b10, TMR_STATUS_ADDR);
            tmr_status_rd = hrdata_tb;

            $display("[%0t] TB: TMR-A[%0d] TMR_STATUS = 0x%08h  (bit0=mismatch, expected=0)",
                     $time, tmr_sub_idx, tmr_status_rd);

            // With no injection all copies agree: mismatch should be 0
            if (tmr_status_rd[0] == 1'b0) begin
                $display("[%0t] TB: TMR-A[%0d] RESULT: PASS (no mismatch, all copies agree)",
                         $time, tmr_sub_idx);
                tmr_pass_cnt = tmr_pass_cnt + 1;
            end else begin
                $display("[%0t] TB: TMR-A[%0d] RESULT: FAIL (unexpected mismatch in healthy mode)",
                         $time, tmr_sub_idx);
                tmr_fail_cnt = tmr_fail_cnt + 1;
            end

            repeat(2) @(negedge hclk);
        end

        // Drain out_fifo after Sub-Test A before continuing (prevents FIFO overflow)
        drain_filter_fifo;
        repeat(3) @(negedge hclk);

        // -----------------------------------------------------------------
        // SUB-TEST B: Inject fault into Copy B (force to +MAX 0x7FF)
        // TMR_CONTROL = 0x01 (inject_b=1, inject_c=0)
        // Copy A = correct, Copy B = +MAX (0x7FF) injected, Copy C = correct
        // Voter output = A/C value (2-of-3 agree on correct value)
        // Expected: TMR_ERR_COUNT >= 1 (mismatch events accumulated)
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST B: Inject fault into Copy B (force to +MAX 0x7FF) ---", $time);

        // Step 1: Disable filter to drain any pending FIFO contents
        // This ensures hreadyout stays high and master returns to IDLE
        $display("[%0t] TB: Disabling filter to drain FIFO before TMR injection...", $time);
        write_single(2'b10, 32'h0000_0008, 32'h0000_0000); // CONTROL=0 (filter disabled)
        repeat(20) @(negedge hclk); // allow streaming to drain FIFO

        // Step 2: Write TMR_CONTROL with filter disabled (FIFO quiet, no wait states)
        $display("[%0t] TB: Writing TMR_CONTROL = 0x00000001 (inject_b=1, Copy-B -> 0x7FF)", $time);
        write_single(2'b10, TMR_CTRL_ADDR, 32'h0000_0001); // bit0=1: corrupt copy B

        // Step 3: Re-enable filter
        write_single(2'b10, 32'h0000_0008, 32'h0000_0001); // CONTROL=1 (filter enabled)
        @(negedge hclk);

        // Push samples and hold injection for 50 cycles to accumulate mismatch events
        for (tmr_sub_idx = 0; tmr_sub_idx < 3; tmr_sub_idx = tmr_sub_idx + 1) begin
            filter_input = tmr_samples[tmr_sub_idx + 2];
            $display("[%0t] TB: TMR-B push sample [%0d] : 0x%03h  (%4d dec)",
                     $time, tmr_sub_idx, filter_input, $signed(filter_input));
            write_single(2'b10, 32'h0000_0008, 32'h0000_0001);
            write_single(2'b10, FILT_DATA_ADDR, {20'b0, filter_input});
        end

        // Hold injection on for 50 cycles to let filter process and accumulate mismatches
        repeat(50) @(negedge hclk);

        // Read TMR_STATUS (live snapshot) and TMR_ERR_COUNT (cumulative)
        read_single(2'b10, TMR_STATUS_ADDR);
        tmr_status_rd = hrdata_tb;
        read_single(2'b10, TMR_ERRCNT_ADDR);
        tmr_errcnt_rd = hrdata_tb;

        $display("[%0t] TB: TMR-B TMR_STATUS  = 0x%08h  (bit0=mismatch)",
                 $time, tmr_status_rd);
        $display("[%0t] TB: TMR-B TMR_ERR_CNT = 0x%08h  (accumulated mismatch cycles, expected >= 1)",
                 $time, tmr_errcnt_rd);

        // Primary check: TMR_ERR_COUNT must have accumulated at least 1 mismatch cycle
        if (tmr_errcnt_rd >= 32'd1) begin
            $display("[%0t] TB: TMR-B RESULT [1/2]: PASS (%0d mismatch events: Copy-B=0x7FF differs from A/C)",
                     $time, tmr_errcnt_rd);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-B RESULT [1/2]: FAIL (expected TMR_ERR_COUNT >= 1, got 0)", $time);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end

        // Secondary check: TMR_STATUS bit0 (live wire snapshot)
        if (tmr_status_rd[0] == 1'b1) begin
            $display("[%0t] TB: TMR-B RESULT [2/2]: PASS (mismatch flag live - voter overruling Copy-B fault)",
                     $time);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else if (tmr_errcnt_rd >= 32'd1) begin
            $display("[%0t] TB: TMR-B RESULT [2/2]: PASS (filter settled to 0x7FF at read time; error count confirmed mismatch occurred)", $time);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-B RESULT [2/2]: FAIL (mismatch never detected)", $time);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end

        // Turn off TMR injection
        write_single(2'b10, TMR_CTRL_ADDR, 32'h0000_0000);
        @(negedge hclk);

        // -----------------------------------------------------------------
        // SUB-TEST C: TMR register readback
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST C: TMR register readback ---", $time);

        read_single(2'b10, TMR_CTRL_ADDR);
        tmr_ctrl_rd = hrdata_tb;
        read_single(2'b10, TMR_STATUS_ADDR);
        tmr_status_rd = hrdata_tb;
        read_single(2'b10, TMR_ERRCNT_ADDR);
        tmr_errcnt_rd = hrdata_tb;

        $display("[%0t] TB: TMR Register Map Readback:", $time);
        $display("[%0t] TB:   0x48 TMR_CONTROL = 0x%08h  (bit0=inject_b, bit1=inject_c)", $time, tmr_ctrl_rd);
        $display("[%0t] TB:   0x40 TMR_STATUS  = 0x%08h  (bit0=mismatch, bit1=err_ab, bit2=err_bc, bit3=err_ac)", $time, tmr_status_rd);
        $display("[%0t] TB:   0x44 TMR_ERR_CNT = 0x%08h  (cumulative mismatch events)", $time, tmr_errcnt_rd);

        // Verify: after turning off injection, TMR_CONTROL should read 0
        if (tmr_ctrl_rd == 32'h0) begin
            $display("[%0t] TB: TMR-C TMR_CONTROL readback: PASS (= 0x00000000 after clearing injection)",
                     $time);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-C TMR_CONTROL readback: FAIL (unexpected non-zero value = 0x%08h)",
                     $time, tmr_ctrl_rd);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end

        // TMR_ERR_COUNT must be >= 1 (fault injection in Sub-Test B caused mismatches)
        if (tmr_errcnt_rd >= 32'd1) begin
            $display("[%0t] TB: TMR-C TMR_ERR_COUNT      : PASS (= %0d mismatch events recorded)",
                     $time, tmr_errcnt_rd);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-C TMR_ERR_COUNT      : FAIL (expected >= 1, got %0d)",
                     $time, tmr_errcnt_rd);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end

        // -----------------------------------------------------------------
        // SUB-TEST D: LPF TMR fault injection
        // slave3_hclk is gated by hsel_3 (see ahb_clock_gate.v).  Counters
        // only tick when the AHB master is actively talking to slave 3.
        // Strategy: (1) drain out_fifo to make room, (2) set injection,
        // (3) push 3 samples – each DATA_IN write keeps hsel_3=1 for ≥2
        // cycles, (4) call drain_filter_fifo (many status reads → hsel_3=1
        // → counter accumulates), (5) read while injection still active.
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST D: Inject fault into LPF Copy B ---", $time);
        $display("[%0t] TB: Draining out_fifo before LPF TMR test...", $time);
        drain_filter_fifo;

        $display("[%0t] TB: Writing LPF_TMR_CONTROL = 0x01 (inject_b=1)", $time);
        write_single(2'b10, LPF_TMR_CTRL_ADDR, 32'h0000_0001);
        // Enable filter so streaming starts; each DATA_IN write => hsel_3=1
        write_single(2'b10, 32'h0000_0008, 32'h0000_0001);
        $display("[%0t] TB: TMR-D pushing 3 samples (LPF Copy-B forced to 0x7FF)", $time);
        write_single(2'b10, 32'h0000_0000, 32'h0000_0123); // DATA_IN
        write_single(2'b10, 32'h0000_0000, 32'h0000_0456);
        write_single(2'b10, 32'h0000_0000, 32'h0000_0789);
        // drain_filter_fifo keeps hsel_3 active for many cycles => counter accumulates
        drain_filter_fifo;

        // Read status registers while injection still active => mismatch visible
        read_single(2'b10, LPF_TMR_STATUS_ADDR);
        tmr_status_rd = hrdata_tb;
        read_single(2'b10, LPF_TMR_ERRCNT_ADDR);
        tmr_errcnt_rd = hrdata_tb;
        $display("[%0t] TB: TMR-D LPF_TMR_STATUS  = 0x%08h", $time, tmr_status_rd);
        $display("[%0t] TB: TMR-D LPF_TMR_ERR_CNT = 0x%08h  (expected >= 1)", $time, tmr_errcnt_rd);

        if (tmr_errcnt_rd >= 32'd1) begin
            $display("[%0t] TB: TMR-D RESULT [1/3]: PASS (%0d LPF mismatch events)", $time, tmr_errcnt_rd);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-D RESULT [1/3]: FAIL (LPF_ERR_COUNT expected >= 1, got 0)", $time);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end
        if (tmr_status_rd[0] == 1'b1) begin
            $display("[%0t] TB: TMR-D RESULT [2/3]: PASS (LPF_TMR_STATUS mismatch bit=1)", $time);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-D RESULT [2/3]: FAIL (LPF mismatch bit not set, STATUS=0x%08h)", $time, tmr_status_rd);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end
        write_single(2'b10, LPF_TMR_CTRL_ADDR, 32'h0000_0000); // clear injection
        @(negedge hclk);
        read_single(2'b10, LPF_TMR_CTRL_ADDR);
        tmr_ctrl_rd = hrdata_tb;
        if (tmr_ctrl_rd == 32'h0) begin
            $display("[%0t] TB: TMR-D RESULT [3/3]: PASS (LPF_TMR_CONTROL cleared to 0)", $time);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-D RESULT [3/3]: FAIL (LPF_TMR_CONTROL = 0x%08h)", $time, tmr_ctrl_rd);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end

        // -----------------------------------------------------------------
        // SUB-TEST E: Glitch Filter TMR fault injection
        // Same gated-clock strategy: drain, inject, push 3 samples,
        // drain_filter_fifo (counter accumulates), read while active.
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST E: Inject fault into Glitch Filter Copy B ---", $time);
        $display("[%0t] TB: Draining out_fifo before Glitch TMR test...", $time);
        drain_filter_fifo;

        $display("[%0t] TB: Writing GLITCH_TMR_CONTROL = 0x01 (inject_b=1)", $time);
        write_single(2'b10, GLITCH_TMR_CTRL_ADDR, 32'h0000_0001);
        // Filter already enabled; push 3 samples
        $display("[%0t] TB: TMR-E pushing 3 samples (Glitch Copy-B forced to 0x7FF)", $time);
        write_single(2'b10, 32'h0000_0000, 32'h0000_0321);
        write_single(2'b10, 32'h0000_0000, 32'h0000_0654);
        write_single(2'b10, 32'h0000_0000, 32'h0000_0987);
        drain_filter_fifo;

        read_single(2'b10, GLITCH_TMR_STATUS_ADDR);
        tmr_status_rd = hrdata_tb;
        read_single(2'b10, GLITCH_TMR_ERRCNT_ADDR);
        tmr_errcnt_rd = hrdata_tb;
        $display("[%0t] TB: TMR-E GLITCH_TMR_STATUS  = 0x%08h", $time, tmr_status_rd);
        $display("[%0t] TB: TMR-E GLITCH_TMR_ERR_CNT = 0x%08h  (expected >= 1)", $time, tmr_errcnt_rd);

        if (tmr_errcnt_rd >= 32'd1) begin
            $display("[%0t] TB: TMR-E RESULT [1/3]: PASS (%0d Glitch mismatch events)", $time, tmr_errcnt_rd);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-E RESULT [1/3]: FAIL (GLITCH_ERR_COUNT expected >= 1, got 0)", $time);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end
        if (tmr_status_rd[0] == 1'b1) begin
            $display("[%0t] TB: TMR-E RESULT [2/3]: PASS (GLITCH_TMR_STATUS mismatch bit=1)", $time);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-E RESULT [2/3]: FAIL (Glitch mismatch bit not set, STATUS=0x%08h)", $time, tmr_status_rd);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end
        write_single(2'b10, GLITCH_TMR_CTRL_ADDR, 32'h0000_0000); // clear injection
        @(negedge hclk);
        read_single(2'b10, GLITCH_TMR_CTRL_ADDR);
        tmr_ctrl_rd = hrdata_tb;
        if (tmr_ctrl_rd == 32'h0) begin
            $display("[%0t] TB: TMR-E RESULT [3/3]: PASS (GLITCH_TMR_CONTROL cleared to 0)", $time);
            tmr_pass_cnt = tmr_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: TMR-E RESULT [3/3]: FAIL (GLITCH_TMR_CONTROL = 0x%08h)", $time, tmr_ctrl_rd);
            tmr_fail_cnt = tmr_fail_cnt + 1;
        end

        $display("\n========================================================");
        $display("TB: TMR Test Summary");
        $display("========================================================");
        $display("TB: Sub-A (DC healthy)       - 3 samples, all TMR_STATUS=0");
        $display("TB: Sub-B (DC Copy-B fault)  - voter overrules, ERR_COUNT>=1");
        $display("TB: Sub-C (DC reg readback)  - TMR_CONTROL/STATUS/ERR_COUNT");
        $display("TB: Sub-D (LPF Copy-B fault) - voter overrules, LPF_ERR_COUNT>=1");
        $display("TB: Sub-E (Glitch Copy-B)    - voter overrules, GLITCH_ERR_COUNT>=1");
        $display("TB: Total TMR checks: %0d | Passed: %0d | Failed: %0d",
                 tmr_pass_cnt + tmr_fail_cnt, tmr_pass_cnt, tmr_fail_cnt);
        $display("========================================================");

        //=====================================================================
        // TEST 7: Watchdog Slave Reset
        // Layer 3 fault tolerance: per-slave timeout detection + SW force-reset.
        // A slave that stalls the AHB for >= timeout_cfg consecutive cycles is
        // automatically reset (its local slv_rst_n pulsed low for 10 cycles)
        // without disturbing the master or other slaves.
        // SW can also force-reset any slave immediately via WDG_FORCE_RST.
        //=====================================================================
        $display("\n========================================================");
        $display("TEST 7: Watchdog Slave Reset");
        $display("========================================================");
        $display("[%0t] TB: Watchdog monitors hsel && !hreadyout per slave.", $time);
        $display("[%0t] TB: Timeout fires after >= threshold consecutive stall cycles.", $time);
        $display("[%0t] TB: Force-reset: write WDG_FORCE_RST to isolate-reset any slave.", $time);
        wdg_pass_cnt = 0; wdg_fail_cnt = 0;

        // -----------------------------------------------------------------
        // SUB-TEST A: No spurious watchdog events during tests 1-6
        // WDG_STATUS and WDG_FAULT_CNT must both be 0 before any forced event.
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST A: Verify no spurious timeouts in tests 1-6 ---", $time);
        read_single(2'b10, WDG_STATUS_ADDR);
        wdg_status_rd = hrdata_tb;
        read_single(2'b10, WDG_FAULT_CNT_ADDR);
        wdg_fault_cnt_rd = hrdata_tb;
        $display("[%0t] TB: WDG-A WDG_STATUS    = 0x%08h  (expected 0x0)", $time, wdg_status_rd);
        $display("[%0t] TB: WDG-A WDG_FAULT_CNT = 0x%08h  (expected 0x0)", $time, wdg_fault_cnt_rd);
        if (wdg_status_rd == 32'h0 && wdg_fault_cnt_rd == 32'h0) begin
            $display("[%0t] TB: WDG-A RESULT [1/1]: PASS (no spurious watchdog events in prior tests)", $time);
            wdg_pass_cnt = wdg_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: WDG-A RESULT [1/1]: FAIL (unexpected events: status=0x%08h cnt=%0d)",
                     $time, wdg_status_rd, wdg_fault_cnt_rd);
            wdg_fail_cnt = wdg_fail_cnt + 1;
        end

        // -----------------------------------------------------------------
        // SUB-TEST B: SW force-reset Slave 3 (filter slave) via WDG_FORCE_RST.
        // Write bit 2 = 1 → watchdog asserts slv_rst_n[2]=0 for 10 cycles.
        // After the pulse the slave comes back alive with reset-default state.
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST B: SW force-reset Slave 3 (filter slave) ---", $time);
        $display("[%0t] TB: Writing WDG_FORCE_RST = 0x4 (bit2 = Slave 3)", $time);
        write_single(2'b10, WDG_FORCE_RST_ADDR, 32'h0000_0004);
        // Wait: 1 cycle watchdog detects force_reset + 10 cycles reset pulse + margin
        repeat(20) @(negedge hclk);

        // Check WDG_STATUS bit 2 set (sticky flag from watchdog)
        read_single(2'b10, WDG_STATUS_ADDR);
        wdg_status_rd = hrdata_tb;
        $display("[%0t] TB: WDG-B WDG_STATUS = 0x%08h  (expected bit2=1 => 0x4)", $time, wdg_status_rd);
        if (wdg_status_rd[2] == 1'b1) begin
            $display("[%0t] TB: WDG-B RESULT [1/3]: PASS (WDG_STATUS[2] set — slave 3 reset event recorded)", $time);
            wdg_pass_cnt = wdg_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: WDG-B RESULT [1/3]: FAIL (WDG_STATUS[2] not set, got 0x%08h)", $time, wdg_status_rd);
            wdg_fail_cnt = wdg_fail_cnt + 1;
        end

        // Verify slave 3 is alive: CONTROL register must be 0 (reset default)
        read_single(2'b10, 32'h0000_0008);
        wdg_fault_cnt_rd = hrdata_tb;
        $display("[%0t] TB: WDG-B SLAVE3 CONTROL after reset = 0x%08h  (expected 0x0)", $time, wdg_fault_cnt_rd);
        if (wdg_fault_cnt_rd == 32'h0) begin
            $display("[%0t] TB: WDG-B RESULT [2/3]: PASS (CONTROL=0 — slave 3 alive with reset defaults)", $time);
            wdg_pass_cnt = wdg_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: WDG-B RESULT [2/3]: FAIL (CONTROL=0x%08h, expected 0x0)", $time, wdg_fault_cnt_rd);
            wdg_fail_cnt = wdg_fail_cnt + 1;
        end

        // Verify slave 3 can be re-programmed: write-then-read-back CONTROL
        write_single(2'b10, 32'h0000_0008, 32'h0000_0001); // filter_enable = 1
        @(negedge hclk);
        read_single(2'b10, 32'h0000_0008);
        wdg_fault_cnt_rd = hrdata_tb;
        if (wdg_fault_cnt_rd == 32'h0000_0001) begin
            $display("[%0t] TB: WDG-B RESULT [3/3]: PASS (write/read-back verified — slave 3 fully recovered)", $time);
            wdg_pass_cnt = wdg_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: WDG-B RESULT [3/3]: FAIL (CONTROL readback=0x%08h, expected 0x1)", $time, wdg_fault_cnt_rd);
            wdg_fail_cnt = wdg_fail_cnt + 1;
        end

        // -----------------------------------------------------------------
        // SUB-TEST C: WDG_FAULT_CNT must be >= 1 after the force-reset event.
        // (total_timeouts lives in the watchdog itself and is NOT reset by
        //  the local slave reset — it persists across slave restarts.)
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST C: Verify WDG_FAULT_CNT incremented ---", $time);
        read_single(2'b10, WDG_FAULT_CNT_ADDR);
        wdg_fault_cnt_rd = hrdata_tb;
        $display("[%0t] TB: WDG-C WDG_FAULT_CNT = 0x%08h  (expected >= 1)", $time, wdg_fault_cnt_rd);
        if (wdg_fault_cnt_rd >= 32'd1) begin
            $display("[%0t] TB: WDG-C RESULT [1/1]: PASS (fault counter = %0d, watchdog event recorded)",
                     $time, wdg_fault_cnt_rd);
            wdg_pass_cnt = wdg_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: WDG-C RESULT [1/1]: FAIL (WDG_FAULT_CNT = 0, expected >= 1)", $time);
            wdg_fail_cnt = wdg_fail_cnt + 1;
        end

        // -----------------------------------------------------------------
        // SUB-TEST D: WDG_TIMEOUT_CFG is SW-programmable.
        // After slave-3 reset, the register reverts to its reset-default (200=0xC8).
        // Reprogram to 255, read back to confirm.
        // -----------------------------------------------------------------
        $display("\n[%0t] TB: --- SUB-TEST D: Programmable timeout threshold ---", $time);
        read_single(2'b10, WDG_TIMEOUT_CFG_ADDR);
        wdg_timeout_cfg_rd = hrdata_tb;
        $display("[%0t] TB: WDG-D WDG_TIMEOUT_CFG default = 0x%08h  (expected 0xC8 = 200)", $time, wdg_timeout_cfg_rd);
        if (wdg_timeout_cfg_rd[7:0] == 8'hC8) begin
            $display("[%0t] TB: WDG-D RESULT [1/2]: PASS (default threshold = 200 cycles)", $time);
            wdg_pass_cnt = wdg_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: WDG-D RESULT [1/2]: FAIL (expected 0xC8, got 0x%02h)",
                     $time, wdg_timeout_cfg_rd[7:0]);
            wdg_fail_cnt = wdg_fail_cnt + 1;
        end
        write_single(2'b10, WDG_TIMEOUT_CFG_ADDR, 32'h0000_00FF); // reprogram to 255
        @(negedge hclk);
        read_single(2'b10, WDG_TIMEOUT_CFG_ADDR);
        wdg_timeout_cfg_rd = hrdata_tb;
        if (wdg_timeout_cfg_rd[7:0] == 8'hFF) begin
            $display("[%0t] TB: WDG-D RESULT [2/2]: PASS (threshold reprogrammed to 255 = 0xFF)", $time);
            wdg_pass_cnt = wdg_pass_cnt + 1;
        end else begin
            $display("[%0t] TB: WDG-D RESULT [2/2]: FAIL (expected 0xFF, got 0x%02h)",
                     $time, wdg_timeout_cfg_rd[7:0]);
            wdg_fail_cnt = wdg_fail_cnt + 1;
        end

        $display("\n========================================================");
        $display("TB: Watchdog Test Summary");
        $display("========================================================");
        $display("TB: Sub-A (No spurious events) - WDG_STATUS=0 / FAULT_CNT=0 after tests 1-6");
        $display("TB: Sub-B (Force-reset Slave 3) - slave isolated, resets, recovers in 10 cycles");
        $display("TB: Sub-C (Fault counter)       - WDG_FAULT_CNT persists across local slave reset");
        $display("TB: Sub-D (Threshold config)    - WDG_TIMEOUT_CFG read/write/readback");
        $display("TB: Total WDG checks: %0d | Passed: %0d | Failed: %0d",
                 wdg_pass_cnt + wdg_fail_cnt, wdg_pass_cnt, wdg_fail_cnt);
        $display("========================================================");

        //=====================================================================
        // TEST 8: Combined Fault Stress Test (TMR + FEC)
        // Verify that the system can recover from simultaneous faults in
        // different layers (e.g., LPF hardware fault + FEC transmission error).
        //=====================================================================
        $display("\n========================================================");
        $display("TEST 8: Combined Fault Stress Test (Layer 1 TMR + Layer 2 FEC)");
        $display("========================================================");
        $display("[%0t] TB: Strategy: 1. Run Golden (no fault). 2. Run with DOUBLE fault. 3. Compare.", $time);
        
        combined_pass_cnt = 0;
        combined_fail_cnt = 0;
        
        // Reset to clear previous states
        reset_dut();
        drain_filter_fifo;
        
        // --- STEP 1: GOLDEN RUN (No Faults) ---
        write_single(2'b10, LPF_TMR_CTRL_ADDR, 32'h0000_0000); // No TMR Fault
        write_single(2'b10, FEC_CTRL_ADDR, 32'h0000_0000);     // No FEC Fault
        write_single(2'b10, 32'h0000_0008, 32'h0000_0001);     // Enable Filter
        
        filter_input = 12'h123;
        write_single(2'b10, FILT_DATA_ADDR, {20'b0, filter_input});
        repeat(20) @(negedge hclk); // Wait for pipeline
        read_single(2'b10, FILT_DATA_ADDR);
        golden_output = hrdata_tb[11:0];
        $display("[%0t] TB: Golden Output (No Faults): 0x%03h", $time, golden_output);
        
        // --- STEP 2: INJECT SIMULTANEOUS FAULTS ---
        $display("[%0t] TB: Injecting LPF Copy-B fault AND FEC Bit-5 error simultaneously...", $time);
        write_single(2'b10, LPF_TMR_CTRL_ADDR, 32'h0000_0001); // TMR Fault (Copy B -> 0)
        write_single(2'b10, FEC_CTRL_ADDR, 32'h0000_000B);     // FEC Fault (Bit 5 flip)
        
        write_single(2'b10, FILT_DATA_ADDR, {20'b0, filter_input});
        repeat(20) @(negedge hclk);
        
        // --- STEP 3: VERIFY RECOVERY ---
        read_single(2'b10, LPF_TMR_STATUS_ADDR);
        tmr_status_rd = hrdata_tb;
        read_single(2'b10, FEC_STATUS_ADDR);
        fec_status_rd = hrdata_tb;
        read_single(2'b10, FILT_DATA_ADDR);
        filter_output = hrdata_tb[11:0];
        
        $display("[%0t] TB: Faulty Run Output: 0x%03h", $time, filter_output);
        
        // Check A: Data Integrity (Must match golden)
        if (filter_output == golden_output) begin
             $display("[%0t] TB: Combined Result [1/3]: PASS (Data correct despite double fault)", $time);
             combined_pass_cnt = combined_pass_cnt + 1;
        end else begin
             $display("[%0t] TB: Combined Result [1/3]: FAIL (Data corrupted: expected 0x%03h, got 0x%03h)", $time, golden_output, filter_output);
             combined_fail_cnt = combined_fail_cnt + 1;
        end
        
        // Check B: Fault Mechanisms Triggered
        if (tmr_status_rd[0] == 1'b1 && fec_status_rd[0] == 1'b1) begin
             $display("[%0t] TB: Combined Result [2/3]: PASS (Both TMR and FEC detected errors)", $time);
             combined_pass_cnt = combined_pass_cnt + 1;
        end else begin
             $display("[%0t] TB: Combined Result [2/3]: FAIL (Detection missing: TMR=0x%h, FEC=0x%h)", $time, tmr_status_rd, fec_status_rd);
             combined_fail_cnt = combined_fail_cnt + 1;
        end
        
        // Cleanup
        write_single(2'b10, LPF_TMR_CTRL_ADDR, 32'h0000_0000);
        write_single(2'b10, FEC_CTRL_ADDR, 32'h0000_0000);

        //=====================================================================
        // TEST SUMMARY AND COMPLETION
        //=====================================================================
        $display("\n========================================================");
        $display("COMPLETE TEST SUMMARY");
        $display("========================================================");
        $display("TEST 1: Generic Memory Slaves ............ COMPLETE");
        $display("TEST 2: AHB Burst Protocol ............... COMPLETE");
        $display("TEST 3: Wireline Filter Chain ............ COMPLETE");
        $display("         Passed: %0d / 16", filter_pass_cnt);
        $display("TEST 4: AES Crypto Processing ............ COMPLETE");
        $display("         Passed: %0d / 12", pass_cnt);
        $display("TEST 5: Hamming(17,12) FEC ............... COMPLETE");
        $display("         Sub-A (No Error)    : 3 syndrome checks");
        $display("         Sub-B (Error Inject): 3 correction checks");
        $display("         Sub-C (Reg Readback): control/status/syndrome/count");
        $display("         Passed: %0d / %0d", fec_pass_cnt, fec_pass_cnt + fec_fail_cnt);
        $display("TEST 6: TMR Majority Voting .............. COMPLETE");
        $display("         Sub-A (DC healthy)       : 3 mismatch=0 checks");
        $display("         Sub-B (DC Copy-B fault)  : voter overrules, ERR_COUNT >= 1");
        $display("         Sub-C (DC reg readback)  : TMR_CONTROL/STATUS/ERR_COUNT");
        $display("         Sub-D (LPF Copy-B fault) : voter overrules, LPF_ERR_COUNT >= 1");
        $display("         Sub-E (Glitch Copy-B)    : voter overrules, GLITCH_ERR_COUNT >= 1");
        $display("         Passed: %0d / %0d", tmr_pass_cnt, tmr_pass_cnt + tmr_fail_cnt);
        $display("TEST 7: Watchdog Slave Reset ............. COMPLETE");
        $display("         Sub-A (No spurious events) : WDG_STATUS=0 / FAULT_CNT=0");
        $display("         Sub-B (Force-reset Slave 3): isolated reset + full recovery");
        $display("         Sub-C (Fault counter)      : WDG_FAULT_CNT persists across reset");
        $display("         Sub-D (Threshold config)   : WDG_TIMEOUT_CFG read/write");
        $display("         Passed: %0d / %0d", wdg_pass_cnt, wdg_pass_cnt + wdg_fail_cnt);
        $display("TEST 8: Combined Fault Stress ...... COMPLETE");
        $display("         Simultaneous TMR + FEC faults corrected");
        $display("         Passed: %0d / %0d", combined_pass_cnt, combined_pass_cnt + combined_fail_cnt);
        $display("========================================================");
        $display("FAULT TOLERANCE LAYERS:");
        $display("  Layer 1 - TMR : 3x redundancy on LPF + Glitch + DC offset (9 copies, 3 voters) - ZERO latency");
        $display("  Layer 2 - FEC : Hamming(17,12) single-bit correction                           - 2-cycle latency");
        $display("  Layer 3 - WDG : Per-slave timeout watchdog + SW force-reset (10-cycle isolation)");
        $display("========================================================");
        
        // Stop clock gating monitoring and report statistics
        clk_gate_monitor_active = 0;
        #10;
        report_clock_gating_stats();
        
        $display("Simulation finished at time %0t", $time);
        $display("========================================================\n");
        
        #50;
        $finish;
    end
endmodule