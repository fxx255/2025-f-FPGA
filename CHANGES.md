# FM_DEMOD_V 修改记录

## 改动总结：FM/AM 自动判决 + AGC 重构

---

### 涉及文件

| 文件 | 改动类型 |
|---|
| `src/rtl/am_demodulator.v` | 新增输出端口 |
| `src/rtl/fm_am_demod_top.v` | 核心改动（判决逻辑 + AGC） |
| `src/rtl/fm_demod_board.v` | 板级端口/实例化 + LED 驱动 |
| `src/constrs/constraints.xdc` | 新增 LED 引脚约束 |

---

## 一、am_demodulator.v — 引出包络信号

**新增 3 个输出端口**，把内部包络信号引出给顶层做判决：

| 端口 | 来源 | 用途 |
|---|
| `o_env_dc` | `dc_est` | 包络均值（判决分母） |
| `o_env_ac` | `dc_removed` | 包络 AC 分量（备选判据，当前未用） |
| `o_env_raw` | `d_filtered` | 去直流前的完整包络（当前峰值法判据的输入） |

## 二、fm_am_demod_top.v — 核心改动

### 2.1 新增参数

```verilog
DEPTH_SHIFT     = 3   // 判决门限：调制深度 > 2^-3 = 12.5% 判 AM
AM_GAIN_SHIFT   = 4   // AM 输出粗增益 <<4 = ×16（FM 有 dev_gain，AM 之前没有）
ENV_LP_SHIFT    = 9   // 包络低通截止 ~15.5kHz（滤 FM 假起伏，留 AM 真包络）
FORCE_MODE      = 0   // 0=自动, 1=强制FM, 2=强制AM（调试用）
DIAG_NODE       = 0   // 0=正常, 1-6=各中间节点（诊断用）
```

### 2.2 AM/FM 判决 — 峰值法

**判据**：在校准窗口（约 2.62ms）内——

1. `env_lp_hi` 预加载首个包络值（消除从 0 爬升的瞬态）
2. 一阶 IIR 低通（~15.5kHz）用**放大域累加**平滑包络，消除截断死区
3. 跳过前 4096 拍（~82µs）等低通稳定
4. 剩余窗口内跟踪 `env_lp` 的 **max/min**
5. 判决：`(max−min) > (max+min) >> DEPTH_SHIFT` → AM，否则 FM

**关键设计点**：
- **低通滤波**：物理区分——真实 AM 包络起伏 ≤3.4kHz，FM 假包络是 MHz 量级，低通把 FM 假起伏压平
- **放大域 IIR**：`env_lp_hi += (am_env_raw − env_lp)`，全精度反馈，不截断
- **预加载**：首拍 `env_lp_hi = am_env_raw << 9`，不爬坡
- **自归一化**：(max−min)/(max+min) = 调制深度，与信号强弱无关

### 2.3 AGC 重构 — 细粒度三段收敛

**旧**：×2 移位步进 + [6000,18000] 的 3:1 接受窗口 → FM/AM 可差近 2 倍

**新**：
- Q8 定点线性增益 `agc_gain`：`agc_out = demod_clean × agc_gain / 256`
- 更新窗口：21ms（`AGC_WIN_SHIFT=20`）
- 三段式调节：
  1. 误差 > 6000 → 超粗调 ±256/次
  2. 误差 > 2000 → 粗调 ±48/次
  3. 误差在 ±400 死区内 → 不调（防抖）

FM 和 AM 都收敛到同一 `AGC_TARGET=12000`，输出幅度一致。

### 2.4 AM 输出增益

AM 支路加了粗增益 `<<AM_GAIN_SHIFT`(×16) + 饱和，与 FM 的 `dev_gain` 对称，补上之前小 20-30 倍的差距。

### 2.5 新增端口

```verilog
output wire o_is_fm       // 1=FM, 0=AM（判决完成后有效）
output wire o_mode_valid   // 判决完成标志 (= state==S_DEMOD)
```

## 三、fm_demod_board.v — 板级改动

- 新增 `o_led[3:0]` 端口
- 连接核心的 `o_is_fm / o_mode_valid`
- LED 驱动（**低电平点亮**）：LED0=FM，LED3=AM，判决完成前全灭

## 四、constraints.xdc — 新增 LED 引脚

| LED | 引脚 | IOSTANDARD |
|---|
| o_led[0] | P17 | LVCMOS33 |
| o_led[1] | V20 | LVCMOS33 |
| o_led[2] | V22 | LVCMOS33 |
| o_led[3] | U21 | LVCMOS33 |

## 五、判决链路回顾

```
AM_DEMOD.d_filtered (包络，带DC)
  → o_env_raw
    → IIR低通 (15.5kHz，放大域，不截断)
      → env_lp
        → 峰值检测 (max/min over 校准窗口)
          → depth = (max-min)/(max+min)
            → depth > 12.5% → LED3 亮 (AM)
            → depth ≤ 12.5% → LED0 亮 (FM)
```

## 六、可调参数速查

| 参数 | 默认值 | 含义 | 调大 | 调小 |
|---|
| `DEPTH_SHIFT` | 3 | 12.5% 门限 | 更易判 FM | 更易判 AM |
| `ENV_LP_SHIFT` | 9 | ~15.5kHz 低通截止 | 压低频更强 | 保留更多高频 |
| `AGC_TARGET` | 12000 | 目标输出幅度 | 整体更大 | 整体更小 |
| `AGC_WIN_SHIFT` | 20 | 21ms AGC 窗口 | 更平滑/慢 | 更快/可能抖 |
| `AM_GAIN_SHIFT` | 4 | AM ×16 粗增益 | AM 更大 | AM 更小 |

所有参数在 `fm_am_demod_top.v` 顶部或 AGC 段。

## 七、删掉的旧逻辑

- 旧能量法 `is_fm = (fm_energy > am_energy)` — 被峰值法取代，代码保留但不参与判决
- 旧 ×2 移位 AGC（`agc_sh`）— 被 Q8 线性增益取代

---

# 追加改动（2026-07-20）：AM 小信号增益 / 收敛速度 / 抗混叠

针对现象：**AM 在输入较小时增益不足（峰峰值只有 FM 一半）、AGC 收敛慢、载波接近 3MHz 时 AM 输出幅度小且略有失真**。全部改动在 `fm_am_demod_top.v`。

## 八、AM 自适应预增益（对称 FM 的 dev_gain）

**问题**：FM 路有 CORDIC 限幅器（恒包络）+ 自适应 `dev_gain`，小信号自动归一化；AM 路无限幅器、预增益固定 `AM_GAIN_SHIFT=4`（×16）。小信号时 AM 全靠后级 AGC 补，撞上 AGC 上限 → 达不到 target → 峰值只有 FM 一半（`<<5` vs `<<4` 差一位，正好 2 倍）。

**改动**：
- 新增 `reg [15:0] am_peak`：校准期（跳过前 4096 拍瞬态）跟踪 `am_demod_out` 峰值。
- 新增 `reg [2:0] am_gain_sh`：校准结束时按 `am_peak` 自适应选档，把 AM 归一化到 ~8k–16k，与 `dev_gain` 阈值表对称。
- AM 输出 `am_gained` 改用变量移位，取代固定 `<<AM_GAIN_SHIFT`。

## 九、AM 增幅上限翻倍（×32 → ×64；AGC ×320 → ×640）

**问题**：即使加了自适应预增益，极小信号（如近 3MHz）仍不够。

**改动**（预增益档 + AGC 闭环上限两处一起抬）：
- 预增益加一档 `am_peak<256 → <<6`（×64），`am_gained` case 扩到 `<<6`。
- `AGC_GAIN_MAX`：81920（×320）→ **163840（×640）**，`agc_gain` 位宽 17→18 bit。
- AM 总增益上限 ×10240 → **×40960**。
- 顺带修溢出：`agc_out` 中间乘积加宽到 48 位再饱和，杜绝高增益×大样本时的 32 位回卷。

## 十、AGC 加速收敛（固定步长 → 比例步进）

**问题**：旧 AGC 固定加减（±256/±48/±1），从初值 256 爬到两万级要 ~77 窗口 ≈ **1.6 秒**。

**改动**：改成比例（几何）步进，步长随当前增益缩放：
- 远（误差>VFAR）：`±agc_gain>>1`（×1.5 / ÷1.5）
- 中（误差>FAR）：`±agc_gain>>3`（×1.125）
- 死区内：`±AGC_COARSE(48)` 微调防抖
- 收敛时间变对数级，~**10 窗口 ≈ 0.2 秒**，与最终增益大小无关。
- 移除 `AGC_SUPER` 参数（被比例步进取代）。

## 十一、DDC 抗混叠：单级 boxcar → 二级 CIC（sinc²）

**问题**：DDC 的 16 抽头 boxcar 阻带差（旁瓣仅 −13dB），2·fc 和频镜像泄漏进包络检波器（非线性），是近 3MHz AM 幅度小 + 失真的片内主因。

**改动**：第一级 16 点 boxcar 不变，后面级联第二级 16 点滑动平均（递归 running-sum / CIC comb 实现），整体 sinc²：
- 旁瓣 −13dB → **−26dB**，零点加深 → 2·fc 泄漏多压 13–20dB。
- 仍严格线性相位 → 方波/三角波边沿不失真。
- DC 增益仍为 1 → 基带幅度不变，不扰动 AGC 阈值/预增益档。
- 基带 −3dB ~1.38MHz → ~1.0MHz，仍远高于音频需求。
- 新增寄存器：`i_lpf1/q_lpf1`（一级输出）、`i_d2/q_d2[0:15]`（二级延迟线）、`i_rsum/q_rsum`（二级 running-sum）。

**资源/功耗**：递归 running-sum 实现，每通道 ~1 加 + 1 减 + 16 深 SRL（~24 LUT），两通道合计 ~50 LUT + 4 加减器，**0 额外 DSP / BRAM**，功耗基本无感；代价仅多 2 拍延迟。

## 十二、可调参数速查（追加/变更）

| 参数 | 新值 | 含义 | 备注 |
|---|
| `am_gain_sh` 档位 | `am_peak<256→<<6` 起 | AM 自适应预增益 | 与 `dev_gain` 表对称 |
| `AGC_GAIN_MAX` | 163840（×640） | AGC 增益上限 | 原 81920（×320） |
| `agc_gain` 位宽 | 18 bit | — | 原 17 bit |
| AGC 步进 | 比例 `>>1 / >>3` | 收敛速度 | 原固定 ±256/±48/±1 |
| `AM_GAIN_SHIFT` | 4（仅复位初值/兜底） | — | 运行时被 `am_gain_sh` 覆盖 |
| DDC LPF | 二级 CIC（sinc²） | 抗混叠 | 原单级 16-tap boxcar |

## 十三、验证建议（需 Vivado 仿真/上板，本环境无仿真器）

1. `DIAG_NODE=4/5` 在 1/2/3MHz 载波下测 `am_demod_out`/`am_env_dc`，确认 3MHz 幅度和失真是否改善。
2. 小幅 AM 信号（`FORCE_MODE=2`）看 `dac_signed` 稳态峰值是否收敛到 ~12000（而非 ~6000），收敛时间是否 <0.3s。
3. 方波/三角波调制确认边沿无振铃、无不对称（验证线性相位保持）。
