# 基于 FPGA 的 FM/AM 数字解调器

这是一个基于 FPGA 的宽带 FM/AM 自动识别与数字解调参考实现，面向 XI050CD（XC7A50TFGG484-1）开发板。工程使用 Verilog、Vivado 和 XSim，包含载波自动扫描、FM/AM 判决、解调、AGC 以及 DAC 输出链路。

> 据仓库所有者回忆，项目与 2025 年全国大学生电子设计竞赛 F 题相关；尚未核对赛题原文，也没有证据表明当前代码就是当年提交版本。源码在 2026 年仍有调试修改。上板前须按实际 PCB 和器件手册复核约束中的时序参数。

## 功能概览

- 1024 点流水线 FFT 自动搜索输入载波
- FM 解调：NCO 正交混频、CORDIC 限幅、鉴频、低通与 AGC
- AM 解调：包络检测、低通与自动判决
- FM/AM 自动识别，并通过板载 LED 指示状态
- 300–500 Hz 低频调制的输出增益补偿和异常输出看门狗
- AD9226 12 位 ADC、DAC904E 14 位 DAC 的 XI050CD 板级封装
- Python 生成可重复的 10 MHz 载波、3.4 kHz 调制、±60 kHz 频偏 FM 仿真激励

## 仓库结构

```text
src/rtl/       可综合 RTL、FFT 系数 ROM
src/sim/       XSim/ModelSim 测试平台和仿真激励
src/constrs/   XI050CD 引脚及时序约束
scripts/       仿真验证和结果检查脚本
gen_fm_signal.py
               生成 src/sim/*.txt，并同步 FFT ROM 到本地仿真目录
import_sources.tcl
               从源码创建干净的 Vivado 工程
build_bit.tcl  综合、实现并生成 bitstream
gen_mcs.tcl    将 bitstream 打包为 SPI Flash 的 MCS
run_verify.sh  Git Bash 下的一键仿真验证
```

Vivado 的 `.cache/`、`.runs/`、`.sim/`、`xsim_work/` 等本地生成物已加入 `.gitignore`，不会成为开源仓库内容。

## 环境

- Vivado 2025.2（推荐；其他版本可能需要调整 IP/仿真命令）
- Python 3.9+
- Git Bash（仅运行 `run_verify.sh` 时需要）
- FPGA：XC7A50TFGG484-1

## 从零创建 Vivado 工程

在仓库根目录执行：

```bash
vivado -mode batch -source import_sources.tcl
```

工程会生成到 `build/FM_DEMOD_V/`。也可以在 Vivado GUI 的 Tcl Console 中执行同一个脚本。

## 运行行为仿真

```bash
python gen_fm_signal.py
# Vivado/bin 加入 PATH 后：
bash run_verify.sh
```

仿真检查包括：

- 10 MHz 载波应落在 1024 点 FFT 的约 205 号 bin
- 自动判决结果 `is_fm=1`
- 校准后 DAC 输出应为非平坦的约 3.4 kHz 波形

如果 Vivado 不在 PATH：

```bash
VIVADO_BIN=/path/to/Vivado/bin bash run_verify.sh
```

## 生成 bitstream / MCS

```bash
vivado -mode batch -source build_bit.tcl
vivado -mode batch -source gen_mcs.tcl
```

`constraints.xdc` 中的 ADC/DAC 输入输出延时是代表性占位值，必须结合 AD9226、DAC904E 数据手册和实际 PCB 走线重新确认；引脚定义也应在烧录前核对板卡版本。

## 仿真参数

默认激励在 `gen_fm_signal.py` 中定义：50 MHz 采样率、10 MHz 载波、3.4 kHz 调制、±60 kHz 频偏、约 3.33 ms 采样长度。修改参数后重新运行脚本即可生成新的十六进制激励。

## 许可证和第三方代码

原创部分采用 MIT License，见 [LICENSE](LICENSE)。`src/rtl` 中的通用 FFT 模块来自 Gisselquist Technology 的 Pipelined FFT 项目，文件保留其 LGPL-3.0-or-later 版权头；详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。发布时请同时保留这些版权和许可证声明。

## 已知验证范围

- 当前自动化测试仅覆盖 FM 激励；原 Vivado 项目曾引用 AM 测试平台和激励文件，但这些文件目前不在源码目录中，不能声称 AM 已有独立回归测试。
- ADC/DAC 时序约束包含占位值；历史实现报告虽显示满足其约束，不能替代真实板卡时序核对。
- BUG_REPORT.md 的 v3.5 记录仍将噪声过零阈值、低频边界和一次复位锁定列为待上板验证项。
- 本次整理未成功启动本机 Vivado，新的项目生成、仿真及 bitstream 构建尚未重新验证。

## 贡献与复现实验

欢迎提交不同载波、调制频率、输入幅度和板卡版本的仿真结果。请在 issue 或 PR 中附上 Vivado 版本、器件型号、约束修改和关键仿真日志，便于复核。
