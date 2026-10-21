# Dazi Low（打字 Low）

一个只给自己用的 macOS 语音输入工具：按一下左 Control + Shift 开始说话，说完再按一下，整理好的文字直接出现在光标处。全部在本机运行，不花钱，不联网。

对标 Typeless，只做一件事：中英混说的语音转文字，并且像 Typeless 一样把口语整理成通顺的文字（去口头禅、合并改口、长段落分段或整理成编号列表）。

## 用法

| 操作 | 效果 |
|---|---|
| 同时按下左 ⌃ 和 ⇧ 再松开 | 开始录音（不用一直按着） |
| 再按一次左 ⌃ + ⇧ | 结束，识别、整理，然后粘贴到光标处 |
| 录音时按 Esc | 取消 |
| 按住 ⌃⌥Space | 备用快捷键，不需要任何权限，结果放进剪贴板 |

⌃⇧ 中间按了别的键（比如 ⌃⇧Tab）或者按住超过 1 秒，都不会触发，所以不会和其他快捷键冲突。

录音时屏幕下方有一条跟着你声音跳动的波形；松手后变成蓝色的“整理中”。

打开面板：点菜单栏的麦克风图标 →“打开面板”；菜单栏图标被刘海挡住时，用 Spotlight 搜“Dazi”回车也会直接打开面板。面板里有：

- **概览**：今天和全部的次数、字数、省下的打字时间、松手后等待时间、最近 14 天的字数和一段分析总结。
- **词库**：你的词汇（可以搜索、添加、删除）、自动学会的纠错、所有纠错规则。
- **历史**：最近的听写，点一下复制。

## 越用越准

- **自我学习**：识别错了，直接在输入框里改掉就行。Dazi 会在粘贴后观察那段文字，发现你把某个词改掉了，就记下来：改过一次，下次作为提示交给整理模型，并把正确的词放到识别热词最前面；同样的修改出现两次，就变成自动替换。学到的内容在面板的“词库”里，学错了可以删掉。只能观察能读取文字的输入框（大部分原生 App、Slack 等），终端里读不到。
- **结合上下文**：开始录音时会读当前窗口的标题和光标前的一小段文字，帮助整理模型判断人名、仓库名怎么写（只参考，不写进结果）。

## 安装

需要 Apple Silicon Mac、Xcode 命令行工具和 [uv](https://github.com/astral-sh/uv)。不需要管理员权限。

```bash
./scripts/install.sh
```

脚本会编译 App 并装到 `~/Applications/DaziLow.app`，在 `~/Library/Application Support/DaziLow/venv` 建好推理环境，并下载两个模型（约 8 GB）。

第一次启动时，要在「系统设置 → 隐私与安全性」里给 Dazi 打开两项权限：

- **麦克风**：用来听你说话。
- **辅助功能**：用来监听 ⌃⇧，以及把文字粘贴到其他 App。

**公司管理的 Mac 上开辅助功能需要管理员**。这种情况下不用申请：只要从一个已经有辅助功能和麦克风权限的终端（比如 Orca）里启动 Dazi，它就沿用那个终端的权限。`scripts/dazi-ensure` 做的就是这件事：如果 Dazi 没在运行，或者在运行但没有权限，就从当前终端重新启动它。安装脚本会把它链接到 `~/.local/bin/dazi-ensure`，在 `~/.zshrc` 里加一行，让每次打开 Orca 终端时自动在后台运行一下：

```bash
[[ "$TERM_PROGRAM" == "Orca" && -x "$HOME/.local/bin/dazi-ensure" ]] && ( "$HOME/.local/bin/dazi-ensure" >/dev/null 2>&1 & )
```

完全没有辅助功能权限时也能用：按住 ⌃⌥Space 说话，松开后文字会放进剪贴板，自己按 ⌘V 粘贴。权限一打开，App 会自动切换到右侧 ⌥ 和自动粘贴，不用重启。

每次重新编译安装后，macOS 会把它当成新的 App，需要在设置里把这两项权限重新打开一次。

## 怎么做到又准又快

- **识别**用 Qwen3-ASR 1.7B（8 位量化），把你最常用的约 220 个专有名词作为提示词交给它。
- **整理**用本地的 Qwen3-8B，提示词里带完整词汇表和你自己的写作风格示例。
- **边说边识别、边说边整理**：你一停顿，前面那段就在后台识别并整理好，松手后只剩最后一小段要处理，所以说 10 秒还是说 2 分钟，等待时间都差不多（中位数约 1.2 秒）。
- **提示词缓存和抄写加速**：固定不变的提示词只计算一次；整理结果大多是照抄原话，所以一次猜一串字，让模型一次性验证。
- **保险**：整理结果如果加了原话没有的内容（比如开始回答你的问题）、丢了整句话、或者加了“请”“您”这类客套话，就改用只删口头禅、只修错字的保守模式再整理一次；还不行就输出原始识别结果。

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

引擎日志在 `~/Library/Logs/DaziLow/engine.log`，当前权限和引擎状态在 `~/Library/Application Support/DaziLow/status.json`。

不需要任何权限的自测：

```bash
~/Applications/DaziLow.app/Contents/MacOS/DaziLow --mic-test 3                        # 麦克风录 3 秒
~/Applications/DaziLow.app/Contents/MacOS/DaziLow --transcribe --realtime a.wav b.wav  # 按真实语速走完整链路
```

`./scripts/install.sh` 默认只更新引擎（放在 App 包外面），不会改动 App 的签名，所以权限不会丢；加 `--app` 才会重装 App。
