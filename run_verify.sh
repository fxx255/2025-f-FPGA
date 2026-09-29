#!/usr/bin/env bash
# Run from Git Bash with Vivado's xvlog, xelab and xsim on PATH, or set VIVADO_BIN.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/build/verify"
mkdir -p "$WORK"
XVLOG="${VIVADO_BIN:+$VIVADO_BIN/}xvlog"
XELAB="${VIVADO_BIN:+$VIVADO_BIN/}xelab"
XSIM="${VIVADO_BIN:+$VIVADO_BIN/}xsim"
for tool in "$XVLOG" "$XELAB" "$XSIM"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing Vivado tool: $tool (set VIVADO_BIN or add Vivado/bin to PATH)" >&2
        exit 127
    fi
done
python "$ROOT/gen_fm_signal.py"
cp "$ROOT/src/sim/fm_signal_hex.txt" "$ROOT/src/sim/mod_signal_hex.txt" "$WORK/"
cp "$ROOT"/src/rtl/cmem_*.hex "$WORK/"
cd "$WORK"
rtl=(bimpy longbimpy shiftaddmpy convround butterfly hwbfly bitreverse laststage qtrstage fftstage fftmain fft_scanner_wrapper cordic_limiter fm_demodulator_improved am_demodulator fm_am_demod_top)
sources=()
for name in "${rtl[@]}"; do sources+=("$ROOT/src/rtl/$name.v"); done
sources+=("$ROOT/src/sim/fm_signal_rom.v" "$ROOT/src/sim/tb_fm_demod_fft.v")
echo '[1/3] Compiling RTL and testbench'
"$XVLOG" -sv -work xil_defaultlib "${sources[@]}"
echo '[2/3] Elaborating testbench'
"$XELAB" -debug typical --timescale 1ns/1ps --override_timeunit --relax -L xil_defaultlib -s tb_fm_demod_fft_snap xil_defaultlib.tb_fm_demod_fft
echo '[3/3] Simulating and checking output'
"$XSIM" tb_fm_demod_fft_snap --tclbatch "$ROOT/scripts/verify.tcl" | tee xsim-run.log
python "$ROOT/scripts/check_verify.py" xsim-run.log
