# Dazi Low（打字 Low）

一个只给自己用的 macOS 语音输入工具：按住右侧 Option 键说话，松开后，整理好的文字直接出现在光标处。全部在本机运行，不花钱，不联网。

对标 Typeless，只做一件事：中英混说的语音转文字，并且像 Typeless 一样把口语整理成通顺的文字（去口头禅、合并改口、长段落分段或整理成编号列表）。

## 用法

| 操作 | 效果 |
|---|---|
| 按住右侧 ⌥ 说话，松开 | 识别、整理，然后粘贴到光标处 |
| 轻点一下右侧 ⌥ | 免提模式，说完再轻点一下 |
| 录音时按 Esc | 取消 |
| 按住 ⌥ 后 1 秒内按了别的键 | 当成普通的 Option 快捷键，不录音 |

菜单栏的麦克风图标里可以复制上一条、打开历史记录、编辑词汇表、重启引擎。

## 安装

需要 Apple Silicon Mac、Xcode 命令行工具和 [uv](https://github.com/astral-sh/uv)。不需要管理员权限。

```bash
./scripts/install.sh
```

脚本会编译 App 并装到 `~/Applications/DaziLow.app`，在 `~/Library/Application Support/DaziLow/venv` 建好推理环境，并下载两个模型（约 8 GB）。

第一次启动时，要在「系统设置 → 隐私与安全性」里给 Dazi 打开两项权限：

- **麦克风**：用来听你说话。
- **辅助功能**：用来监听右侧 ⌥，以及把文字粘贴到其他 App。

## 怎么做到又准又快

- **识别**用 Qwen3-ASR 1.7B（8 位量化），把你最常用的约 300 个专有名词作为提示词交给它。
- **整理**用本地的 Qwen 模型，提示词里带完整词汇表和你自己的写作风格示例。
- **边说边识别**：你一停顿，前面那段就开始在后台识别，松手后只剩最后几秒要处理。
- **提示词缓存和抄写加速**：固定不变的提示词只计算一次；整理结果大多是照抄原话，所以一次猜一串字，让模型一次性验证。
- **保险**：如果整理结果里出现大量原话里没有的内容（比如模型开始回答你的问题），就退回原始识别结果。

模型选型和测试数据见 [docs/DESIGN.md](docs/DESIGN.md)。

## 个人数据

词汇表、示例、历史录音都放在 `~/Library/Application Support/DaziLow/`，不进这个仓库。

- `lexicon.json`：词汇表和纠错规则，改完下一次说话时自动生效。
- `config.json`（可选）：覆盖默认设置，比如换模型。
- `history/`：每次说话的录音、原始识别和最终文字，方便以后调优。

## 开发

```bash
swift test --package-path app                                   # App 单元测试
~/Library/Application\ Support/DaziLow/venv/bin/python -m unittest discover engine/tests   # 引擎测试
./scripts/build_app.sh                                          # 只编译 App
```

引擎日志在 `~/Library/Logs/DaziLow/engine.log`。
