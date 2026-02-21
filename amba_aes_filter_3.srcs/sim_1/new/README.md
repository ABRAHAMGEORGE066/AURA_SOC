# New Testbench README

## Overview
This README provides information about the new testbench included in this project. The testbench is designed to verify and validate the functionality of the modules in the AURA_SOC project, specifically focusing on the new features and enhancements.

## Location
The new testbench files are located in:
- amba_aes_filter_3.srcs/sim_1/new/
  - ahb_top_tb.v
  - reference_tb.v

## Description
- **ahb_top_tb.v**: Main testbench for simulating the top-level AHB module. It instantiates the design under test and applies various test vectors to verify correct operation.
- **reference_tb.v**: Reference testbench for comparison and validation against the main testbench results.

## How to Run
1. Open your simulation tool (e.g., XSIM, ModelSim, etc.).
2. Add the testbench files and all required source files from `amba_aes_filter_3.srcs/sources_1/new/`.
3. Compile the design and testbench files.
4. Run the simulation and observe the output for verification.

## Expected Output
- The simulation should complete without errors.
- Output waveforms and logs can be used to verify the correct operation of the design.

## Notes
- Ensure all dependencies and source files are included in the simulation.
- Modify the testbench as needed to cover additional test cases or scenarios.

## Contact
For questions or support, please refer to the main project README or contact the project maintainer.
