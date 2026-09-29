# FM 解调项目调试日志

日期:2026-07-14
调试对象:`FM_DEMOD_V`(FFT 自动扫描 + FM/AM 双模解调)

---

## 一、故障现象(用户报告)

12 ms 仿真时观察到:

| 调试信号 | 现象 |
|---|---|
| `dbg_i_norm` / `dbg_q_norm` | 在 ±16384 附近摆动 |
| `dbg_i_abs` | \|i_norm\|,随之摆动 |
| `dbg_fm_out` | 无波形,恒定 ~8000 |
| `dbg_discr` | 幅度巨大,fff70d39 ↔ 0033cee 剧烈跳变 |
| `dbg_raw_out` | 在 1600~1950 间摆动 |
| `dbg_demod_lpf` | 18ed~1650 |
| `dbg_demod_cln` | febc~0135 |
| `dbg_agc_out` | fffffd7a~0000027c |
| `dbg_dev_gain` | 到 12 ms 仍为 0 |
| `dbg_agc_sh` | 已跑到 3 |
| `dbg_is_fm` | 0(判成了 AM) |

---

## 二、根因分析

### 根本原因:本振(LO)锁到了错误载波

出问题那次运行的日志(`vivado.log`):

```
SCAN DONE: freq_word=0x3fc00000, peak_bin=255, peak_mag=10
CALIB DONE: fm_energy=128682, am_energy=10393295
is_fm=0, dev_gain=0
```

- `peak_mag=10` 是纯噪声量级。满幅 ±32767 单音经过本设计 1024 点 FFT,峰值应在 ~2.7×10^8 量级。
- 说明 FFT 当时看到的是**空 / 全 X 的 ROM**,"峰值"落在随机 bin 255 → LO = 12.45 MHz,与 10 MHz 载波**偏差约 2.45 MHz**。

### 为什么 2.45 MHz 偏频会导致上述全部现象

混频后残留 2.45 MHz 差频。16 抽头 LPF 的第一个零点在 50/16 = 3.125 MHz,**2.45 MHz 几乎无衰减通过**,于是 I/Q 是一个快速旋转的相量,而不是基带:

- `i_norm/q_norm` ±16384 —— CORDIC 限幅器本身工作正常。
- `discr` 剧烈跳变 —— 每样点相位推进 ~0.3 rad,`sin(dφ)` 越过线性区并回卷。
- `fm_out` 卡死 / 撞限幅 —— 对垃圾信号做后置滤波后饱和。
- `is_fm=0` —— 鉴频器输出垃圾 → fm_energy 很低(128k);AM 路径把 2.45 MHz 差频当成包络起伏 → am_energy 巨大(10.4M) → **误判为 AM**。
- 因此 `raw_out`(1600~1950)是 **AM 路径**输出,`demod_lpf/cln/agc_out` 都是 AM 残差。
- `dev_gain=0` —— fm_peak 撞满 ≥8192 → 增益档 0;且该值只在 calib_cnt=131071(~2.62 ms)时锁存,12 ms 前保持初值属正常。

### 关键结论:RTL 没有 bug

在 hex 数据就位的干净重编译中,扫描器**完全正确**:

```
SCAN DONE: freq_word=0x33400000, peak_bin=205, peak_mag=268173602   (正确 10 MHz)
CALIB DONE: fm_energy=292195391, am_energy=70700749
is_fm=1
```

逐拍探针也确认 S_SCAN→S_DONE→S_IDLE 的锁存**无竞争**:cnt=219 时就找到 best_bin=205 / best_mag=2.68×10^8 并保持到 cnt=1019,S_DONE 干净锁存后 S_IDLE 才清零。

### 真正的问题(2026-07-14 GUI 复现后确认)

`simulate.log` 顶部有 8 条 WARNING:

```
WARNING: File cmem_1024.hex referenced on hwbfly.v line 217 cannot be opened for reading
... cmem_512/256/128/64/32/16/8.hex 全部打不开
```

`cmem_*.hex` 是 **FFT 蝶形运算的旋转因子(twiddle)系数表**,由 `hwbfly.v` 用 `$readmemh` 在仿真时加载。GUI 运行目录 `FM_DEMOD_V.sim/sim_1/behav/xsim/` 里**只有 fm/mod 信号 hex,缺 cmem_*.hex** → FFT 系数全 X → FFT 输出垃圾 → 扫描器扫到噪声(bin 255 / mag 10)→ LO 锁错 → is_fm=0、输出幅度小。

**为什么 Reset 后仍错**:"Reset Behavioral Simulation" 会清空运行目录;而 `gen_fm_signal.py` 原来只拷 fm/mod 信号,从不拷 cmem,所以每次 reset 后 cmem 依旧缺失。

**命令行能跑通**是因为 `xsim_work/` 里一直有全套 cmem_*.hex。

### 修复
1. 手动:`cp src/rtl/cmem_*.hex FM_DEMOD_V.sim/sim_1/behav/xsim/`
2. 永久:已修改 `gen_fm_signal.py`,自动把 8 个 cmem_*.hex 连同 fm/mod hex 一起拷到 sim_work / xsim_work / GUI 运行目录。
3. 一劳永逸:把 cmem_*.hex 和信号 hex 加入项目 Simulation Sources(sim_1 fileset),由 Vivado 自动管理。

### (历史记录)最初的假设
最早怀疑是 fm_signal_hex.txt 未加载。实际信号 hex 是在的,缺的是 FFT 系数表 cmem_*.hex——两者是不同的文件。

---

## 三、验证过程与结果

两种方式均已跑通(Vivado 2025.2 xsim,50 MHz / 20 ns):

1. `FORCE_FREQ=0x33333333`(旁路扫描器):`is_fm=1`,`agc_out/dac_signed` 输出干净 ~3.4 kHz 正弦(约 295 µs 一周期)。
2. `FORCE_FREQ=0`(真实扫描):扫描器自行找到 bin 205,`is_fm=1`,同样干净正弦。

`fm_energy(292M) > am_energy(70M)` → 正确判为 FM,DAC 还原出 3.4 kHz 基带音。

### GUI 验证通过(2026-07-14)

补齐 `cmem_*.hex` 后,用户在 Vivado GUI(CARRIER_FW=0x33333333)重跑,`dac_data` 幅度约 **0x45ea ↔ 0xb6be**(offset-binary 中心 0x8000,即峰值 ±14000 左右的大幅跨零正弦)。相比修复前"幅度很小 / is_fm=0"的坏状态,确认扫描器已锁对 10 MHz 载波、整条解调链正常工作。所有最初报告的异常现象(discr 乱跳、fm_out 恒定、is_fm=0、幅度小)全部闭环解决。

注:CARRIER_FW=0x33333333 仅为 testbench 日志对照用的理论频率字;实际 LO 用扫描器锁到的 0x33400000(bin 205),差一个 bin 的量化属正常。

---

## 四、代码修改(调试脚手架,已保留)

### 1. `src/rtl/fm_am_demod_top.v`

新增 `FORCE_FREQ` 参数(默认 `0` = 正常自动扫描)。非零时用它覆盖扫描器得到的 LO,用于隔离"扫描器问题"与"解调链问题"。综合时若为 0 会被优化掉,不影响上板。

```verilog
// 新增参数
parameter [31:0] FORCE_FREQ = 32'd0

// FSM 中:有效载波字 = 强制覆盖(调试) 或 扫描结果
wire [31:0] eff_freq_word = (FORCE_FREQ != 32'd0) ? FORCE_FREQ : scan_freq_word;
// S_SCAN 分支改用 eff_freq_word 锁存 freq_hold / lo_freq_word
```

### 2. `src/sim/tb_fm_demod_fft.v`

DUT 例化增加 `.FORCE_FREQ(32'h00000000)`(当前为正常扫描模式)。
隔离测试时改为 `.FORCE_FREQ(32'h33333333)`。

### 3. `xsim_work/`(仅调试用脚本,可留可删)

- `xsim_cmds_verify.tcl`:跑到稳态后每 5 µs 采样一次输出,验证正弦波形。
- `xsim_probe_fft.tcl` / `xsim_probe_done.tcl`:扫描器内部逐拍探针。
- 注意:xsim 用 `get_value`,不是 GUI 的 `current_value`。

---

## 五、正确的仿真流程(避免复现此故障)

1. `python gen_fm_signal.py` —— 生成并自动拷贝 hex 到 `sim_work/` 与 `FM_DEMOD_V.sim/sim_1/behav/xsim/`。
2. Vivado:**Reset Behavioral Simulation** → **Run**(必须先 Reset,否则复用旧的空 ROM)。
3. 正确性判据:
   - `SCAN DONE: peak_bin=205, peak_mag≈2.68×10^8`(不是 255 / 10)
   - `is_fm=1`,`fm_energy > am_energy`
   - `dbg_agc_out` / `dac_signed` 呈 ~3.4 kHz 正弦

命令行批处理编译顺序需包含 `hwbfly.v` 和 `shiftaddmpy.v`(原 `run_xsim.sh` 漏了,会报 `hwbfly not found`)。
