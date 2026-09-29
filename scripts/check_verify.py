#!/usr/bin/env python3
"""Check that xsim reached carrier scan, chose FM, and produced a varying DAC output."""
import re, sys
from pathlib import Path
log = Path(sys.argv[1]).read_text(errors="replace")
peak = re.search(r"SCAN DONE:.*peak_bin=(\d+)", log)
mode = re.search(r"VERIFY is_fm=([^\s]+)", log)
samples = [int(v) for v in re.findall(r"^SAMP\s+(-?\d+)\s*$", log, re.M)]
failures = []
if not peak or abs(int(peak.group(1)) - 205) > 1: failures.append("10 MHz carrier was not found near FFT bin 205")
if not mode or mode.group(1) not in {"1", "1'b1"}: failures.append("FM mode was not selected")
if len(samples) < 30 or (max(samples) - min(samples) if samples else 0) < 1000: failures.append("DAC output lacks at least 30 non-flat samples")
if failures:
    print("Verification FAILED: " + "; ".join(failures), file=sys.stderr); sys.exit(1)
print(f"Verification passed: bin={peak.group(1)}, FM mode, {len(samples)} DAC samples")
