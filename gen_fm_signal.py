#!/usr/bin/env python3
# =============================================================================
# gen_fm_signal.py - FM test signal generator
# Usage: python gen_fm_signal.py
# Just edit the parameters below, then run. Hex files are auto-generated.
# =============================================================================

import math, os

# =========================== SIGNAL PARAMETERS ===============================
FS       = 50_000_000   # Sample rate (Hz)
FC       = 10_000_000   # Carrier frequency (Hz)
FM       = 3_400        # Baseband / modulating frequency (Hz)
DEV      = 60_000       # Peak frequency deviation (Hz)
AMP      = 32_767       # 16-bit max amplitude
N        = 166_667      # Number of samples (matches ROM_DEPTH)
# =============================================================================

PROJ_DIR = os.path.dirname(os.path.abspath(__file__))
FM_HEX   = os.path.join(PROJ_DIR, "src", "sim", "fm_signal_hex.txt")
MOD_HEX  = os.path.join(PROJ_DIR, "src", "sim", "mod_signal_hex.txt")

beta    = DEV / FM
wc      = 2 * math.pi * FC / FS
wm      = 2 * math.pi * FM / FS
spc     = FS / FC                    # samples per carrier cycle
freq_w  = int(FC * 2**32 / FS)       # 32-bit DDS frequency word
fft_bin = FC / (FS / 1024)           # 1024-pt FFT bin
dur_ms  = N / FS * 1000              # duration in ms
n_cyc   = N / FS * FM                # baseband cycles

print(f"""
{'='*60}
  FM Test Signal Generator
{'='*60}
  Sample Rate : {FS/1e6:.0f} MHz
  Carrier     : {FC/1e6:.2f} MHz  ({spc:.1f} samples/period)
  Baseband    : {FM/1e3:.2f} kHz
  Deviation   : ±{DEV/1e3:.2f} kHz
  Mod Index β : {beta:.3f}
  Duration    : {dur_ms:.2f} ms ({n_cyc:.1f} baseband cycles)
  Samples     : {N}
{'='*60}
  freq_word   : 0x{freq_w:08X}
  FFT bin     : ~{fft_bin:.1f}
{'='*60}
""")

# Generate signals
fm_sig, mod_sig = [], []
for n in range(N):
    mv = math.sin(wm * n)
    fv = AMP * math.cos(wc * n + beta * mv)
    fi = round(fv)
    mi = round(mv * AMP)
    # Convert to unsigned hex (two's complement for negative)
    fu = fi + 65536 if fi < 0 else fi
    mu = mi + 65536 if mi < 0 else mi
    fm_sig.append(fu)
    mod_sig.append(mu)

# Write FM signal
with open(FM_HEX, "w") as f:
    for v in fm_sig:
        f.write(f"{v:04X}\n")
print(f"  Written: {FM_HEX}")

# Write mod signal
with open(MOD_HEX, "w") as f:
    for v in mod_sig:
        f.write(f"{v:04X}\n")
print(f"  Written: {MOD_HEX}")

# Quick verify
t = [(v - 65536) if v >= 0x8000 else v for v in fm_sig[:6]]
print(f"\n  First 6 signed values: {t}")
print(f"  Peak abs (first 500): {max(abs((v-65536) if v>=0x8000 else v) for v in fm_sig[:500])}")
print(f"\n  === Verilog updates required ===")
print(f"  fm_demod_top.v: localparam FREQ_XXMHZ = 32'd{freq_w};")
print(f"  tb_fm_demod_fft.v: localparam CARRIER_FW = 32'd{freq_w};")
print(f"  tb_fm_demod_fft.v: // {FC/1e6:.0f} MHz carrier, {FM/1e3:.1f} kHz baseband, {DEV/1e3:.0f} kHz deviation")
# Auto-copy to simulation directories
# NOTE: also copy the FFT twiddle-factor ROMs (cmem_*.hex). These are loaded by
# hwbfly.v via $readmemh at sim time; if missing, the FFT coefficients are X and
# the scanner locks onto noise (wrong carrier -> is_fm=0, tiny output).
import glob, shutil
RTL_DIR = os.path.join(PROJ_DIR, "src", "rtl")
cmem_files = glob.glob(os.path.join(RTL_DIR, "cmem_*.hex"))
for d in ["build/FM_DEMOD_V/FM_DEMOD_V.sim/sim_1/behav/xsim"]:
    dst = os.path.join(PROJ_DIR, d)
    if os.path.isdir(dst):
        shutil.copy(FM_HEX, dst)
        shutil.copy(MOD_HEX, dst)
        for c in cmem_files:
            shutil.copy(c, dst)
        print(f"  Copied to: {d}/  (fm/mod hex + {len(cmem_files)} cmem_*.hex)")

print(f"{'='*60}")
print("Done. Reset Behavioral Simulation in Vivado and re-run.")
