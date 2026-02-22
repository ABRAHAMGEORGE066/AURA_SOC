#!/bin/bash
# =============================================================================
# run_sim.sh - Simulate AURA_SOC with Icarus Verilog + view with GTKWave
# Usage:  ./run_sim.sh           (compile + simulate + open GTKWave)
#         ./run_sim.sh compile   (compile only)
#         ./run_sim.sh sim       (simulate only, assumes already compiled)
#         ./run_sim.sh wave      (open GTKWave with existing dump.vcd)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/amba_aes_filter_3.srcs/sources_1/new"
TB="$SCRIPT_DIR/amba_aes_filter_3.srcs/sim_1/new"
OUT_DIR="$SCRIPT_DIR/sim_out"
VCD="$OUT_DIR/dump.vcd"
SIM_BIN="$OUT_DIR/sim.out"

# Create output directory
mkdir -p "$OUT_DIR"

# --------------------------------------------------------------------------
do_compile() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  STEP 1: Compiling with Icarus Verilog   ║"
    echo "╚══════════════════════════════════════════╝"

    iverilog -g2001 -Wall \
        -o "$SIM_BIN" \
        "$SRC/AES_Encrypt.v" \
        "$SRC/ctle.v" \
        "$SRC/dc_offset_filter.v" \
        "$SRC/fir_equalizer.v" \
        "$SRC/dfe.v" \
        "$SRC/glitch_filter.v" \
        "$SRC/lpf_fir.v" \
        "$SRC/fec_encoder.v" \
        "$SRC/fec_decoder.v" \
        "$SRC/tmr_voter.v" \
        "$SRC/ahb_watchdog.v" \
        "$SRC/wireline_rcvr_chain.v" \
        "$SRC/ahb_filter_slave.v" \
        "$SRC/ahb_top.v" \
        "$TB/ahb_top_tb.v" \
        2>&1 | tee "$OUT_DIR/compile.log"

    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Compilation successful! Binary: $SIM_BIN"
    else
        echo ""
        echo "❌ Compilation failed. Check $OUT_DIR/compile.log"
        exit 1
    fi
}

# --------------------------------------------------------------------------
do_simulate() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  STEP 2: Running Simulation              ║"
    echo "╚══════════════════════════════════════════╝"

    # Run simulation from OUT_DIR so dump.vcd lands there
    cd "$OUT_DIR"
    vvp "$SIM_BIN" 2>&1 | tee "$OUT_DIR/simulate.log"

    if [ -f "$VCD" ]; then
        echo ""
        echo "✅ Simulation done! VCD waveform: $VCD"
    else
        echo ""
        echo "⚠️  Simulation ran but dump.vcd not found in $OUT_DIR"
    fi
}

# --------------------------------------------------------------------------
do_wave() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  STEP 3: Opening GTKWave                 ║"
    echo "╚══════════════════════════════════════════╝"

    if [ ! -f "$VCD" ]; then
        echo "❌ No VCD file found at $VCD"
        echo "   Run './run_sim.sh' first to generate it."
        exit 1
    fi

    echo "Opening $VCD in GTKWave..."
    gtkwave "$VCD" &
}

# --------------------------------------------------------------------------
# Parse argument
ACTION="${1:-all}"

case "$ACTION" in
    compile)
        do_compile
        ;;
    sim)
        do_simulate
        ;;
    wave)
        do_wave
        ;;
    all|*)
        do_compile
        do_simulate
        do_wave
        ;;
esac
