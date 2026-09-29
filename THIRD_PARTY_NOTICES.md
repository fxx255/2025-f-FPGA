# Third-party notices

## Pipelined FFT

The files below are derived from the Pipelined FFT project by Dan Gisselquist / Gisselquist Technology, LLC:

- `src/rtl/bimpy.v`
- `src/rtl/bitreverse.v`
- `src/rtl/butterfly.v`
- `src/rtl/convround.v`
- `src/rtl/fftmain.v`
- `src/rtl/fftstage.v`
- `src/rtl/hwbfly.v`
- `src/rtl/laststage.v`
- `src/rtl/longbimpy.v`
- `src/rtl/qtrstage.v`
- `src/rtl/shiftaddmpy.v`

These files retain their original copyright and LGPL-3.0-or-later notice. A copy of the LGPL license is included at `licenses/LGPL-3.0.pdf`; consult the copyright headers in each file for the upstream project and license terms.

The FFT coefficient ROM files in src/rtl/cmem_*.hex are distributed with the same FFT implementation.

The remaining project-specific RTL, testbench, scripts, constraints, and documentation are covered by the repository license unless a file states otherwise.
