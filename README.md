# LingoPlayer 0.2

个人使用的 macOS 英语学习播放器。SwiftUI / AppKit 界面、libmpv 播放、本地 MFA 逐词对齐、ECDICT 词典和 SQLite 缓存。

## 在当前 Mac 上使用

已构建的应用位于 `dist/LingoPlayer.app`，可在 Finder 中双击打开。拖入视频，或使用 `⌘O` 选择文件。

本机构建将播放库放入应用包，MFA 和词库仍使用本项目的 `.runtime`。请保留项目目录；移动目录后需重新构建。此包是本机签名的个人技术原型，尚不是可独立分发的安装包。

首次从源码准备：

```bash
bash scripts/setup-runtime.sh --all
bash scripts/build-app.sh
open dist/LingoPlayer.app
```

需要 macOS 14 或以上、Apple Command Line Tools、可用于首次下载依赖的网络和数 GB 空间。当前实测环境见 [验证记录](verification/REPORT.md)。安装脚本使用项目内 Miniforge，不修改 shell 配置。播放库来自 IINA 官方预编译依赖，MFA 和 FFmpeg 来自 conda-forge，ECDICT 来自原项目。

## 播放与学习

- 自动加载同目录同名字幕（例如 `film.en.srt`、`film.zh.srt`）与内嵌文字字幕；“字幕”菜单支持选择其他候选、手动导入及在线搜索。
- 支持 SRT、ASS/SSA、VTT。双语文件按中英文行拆分；中文和英文分别按自己的时间显示，可在滑杆图标中独立调整偏移，正值表示字幕推迟。
- 打开视频立即播放。MFA 在后台使用本地音频和已有英文字幕生成单词时间戳；未准备或失败的片段显示整句，仍能点词，不使用平均分配的假时间。
- 默认词卡随发音更新。点击英文单词暂停并锁定；普通播放按钮或 `⌘P` 继续播放时保留词卡。
- “继续学习”或 `⌘Return` 解除锁定并恢复播放；“回放本句”或 `⌘R` 播放选中台词后暂停，保留词卡。
- 学习区右上角可分离窗口；有第二屏时优先放到第二屏，关闭学习窗口后回到侧栏。
- 词卡显示词形、原形（词库提供时）、音标、词典释义、当前中英台词。词典释义不代表对当前语境的自动消歧。

图片字幕、烧录字幕暂不参与学习。不提供无字幕听写、自动翻译和流媒体站点接入。ASS 被转换为学习用纯文字，不复刻原文件的动画、位置或字体特效。一个文本行中混排的中英译文可能需要先整理为分行字幕。

## 播放列表与续播

右侧的“学习／播放列表”页签共用侧栏空间。学习区分离后主窗口自动显示播放列表；切回“学习”可以定位独立窗口或收回，关闭独立窗口后自动回到学习页签。

- `⌘O` 多选、拖入多个文件或 Finder 批量打开：追加并播放本次文件中按文件名自然排序的第一项（例如第 2 集排在第 10 集之前）。同一路径和符号链接去重。
- 播放列表中的“添加”只追加，不打断当前视频；当前没有视频时开始播放。
- 双击列表项播放，拖到另一项上方调整顺序，拖到列表底部移至末尾。可通过右键菜单在 Finder 中定位文件。
- 移除非当前项不影响播放；移除当前项播放原来的下一项，没有下一项则停止。清空列表停止播放。以上操作均不删除文件。
- “自动连播”默认开启，自然播完进入下一部；队尾停止、不循环。缺失或损坏文件标记后跳过，没有可用后续文件时停止并提示。
- 未看完的文件续播，已自然播完的文件再次打开从头开始。退出会保存列表顺序、当前文件和观看位置；重新启动恢复时保持暂停。
- “回放本句”到片尾也只暂停，保留词卡，不触发下一部。普通拖动到视频终点也不会当作自然播完。

## 快捷键

“设置 → 快捷键”支持按键录入、清除、单项恢复和全部恢复默认。按 `Esc` 取消录入；冲突会提示对应操作，必须先清除旧绑定。修改立即保存，菜单和按钮提示同步更新。

| 操作 | 默认按键 |
|---|---|
| 播放／暂停 | `⌘P` |
| 回放本句 / 继续学习 | `⌘R` / `⌘Return` |
| 后退 / 前进 5 秒 | `←` / `→` |
| 上一句 / 下一句 | `⌥←` / `⌥→` |
| 降低 / 提高音量 | `↓` / `↑`（每次 5%） |
| 降低 / 提高倍速 | `[` / `]`（0.5、0.75、1、1.25、1.5、2 倍） |
| 上一部 / 下一部 | `⌘⇧←` / `⌘⇧→` |
| 切换学习 / 播放列表 | `⌘L` |

这些是应用内快捷键，播放器和独立学习窗口均可用。文本编辑、中文输入组合态、设置、弹窗和字幕调节期间让位于原生键盘操作。打开文件 `⌘O`、导入字幕 `⌘I`、设置 `⌘,` 和系统编辑快捷键保留。

上／下一句使用播放位置与英文字幕偏移定位，保留播放或暂停以及词卡锁定状态。在对白间隙，上一句返回最近的前一句、下一句前往后一句；正在一句内时定位到相邻句。不跨影片，无可到达英文字幕时禁用。

## 应用图标

[矢量源稿](Design/LingoPlayer.svg) 是可编辑的 SVG，深色底、青柠绿播放三角和高亮字幕条。PNG 覆盖 16–1024 像素，[图标资源](Sources/LingoPlayer/Resources/Icon) 包含完整 macOS iconset 与 `.icns`；应用内品牌标识使用同源 PNG。构建脚本在签名前复制图标并设置 `CFBundleIconFile`，用于 Finder、Dock 和关于窗口。

修改源稿后重新生成：

```bash
swift scripts/render-icon.swift "$PWD"
iconutil -c icns Sources/LingoPlayer/Resources/Icon/AppIcon.iconset \
  -o Sources/LingoPlayer/Resources/Icon/AppIcon.icns
bash scripts/build-app.sh
```

渲染脚本读取源稿中的 `rect` / `polygon` 图形；增加其他 SVG 图形类型时需同步扩展渲染器。

## 在线字幕配置

在设置中填写 OpenSubtitles API Key；如下载需要登录，在同一页输入该服务的用户名和密码。API Key 和登录 token 存入 macOS 钥匙串，密码不持久化。

搜索使用文件哈希、片名、年份和季集信息。唯一文件哈希匹配可自动采用；不确定的匹配展示候选供选择。找不到或服务不可用时仍可播放，并可导入本地字幕。所选字幕及各语言偏移随片源保存。没有配置 API Key 不影响本地功能。

在线服务会收到搜索所需的文件哈希与片名信息；视频、音频不上传。字幕文件和词典在准备后可离线使用。首次安装模型和词库需要联网；播放期间不会自动下载模型。

## 数据与实现

默认数据目录：`~/Library/Application Support/LingoPlayer/`。

| 文件或目录 | 用途 |
|---|---|
| `library.sqlite` | 观看位置、时长、完成状态、单个队列顺序与当前项、音轨、字幕路径、偏移、逐句对齐缓存 |
| `interaction.json` | 快捷键和自动连播偏好；与运行环境设置独立 |
| `settings.json` | 本地依赖路径与自动搜索设置；不含密钥 |
| `MFA/pretrained_models` | 本地声学模型及发音词典 |
| `Subtitles` | 抽取的内嵌字幕和下载字幕 |
| `AlignmentJobs` | 对齐临时文件，任务结束后清理 |
| `alignment-metrics.jsonl` | 每批处理耗时、子进程峰值内存、词数与失败数 |

`LINGOPLAYER_DATA_DIR` 可覆盖数据目录；`LINGOPLAYER_RUNTIME` 可指定依赖根目录。自定义运行环境也可在设置页配置。更换 libmpv 路径后需重启。

SQLite 从 v1 增量升级至 v2，仅新增队列与进度表，不删除旧观看记录和对齐缓存。旧设置继续使用；缺失的交互偏好采用默认值。快捷键与连播设置不重启播放器或对齐任务。

`PlayerCore` 提供字幕解析、独立时间轴、学习状态、词典、字幕服务、队列、动作与快捷键规则、EOF 策略和存储。`CMpv` 仅适配 libmpv 的稳定 C API，播放器控制运行在串行队列，渲染在主线程。`LingoPlayer` 管理界面、双窗口和后台调度。学习内容通过 `LearningContentProvider` 接口接入，后续扩展不需要改动播放内核。

对齐使用独立可取消进程，一次优先准备当前播放位置附近约 30 秒的字幕。缓存按片源标识、字幕内容、音轨、英文偏移、模型版本和处理脚本版本隔离，逐句保存。跳转到尚未准备的新片段会调整队列。故障片段保持整句；基础设施故障会停止自动重试并显示状态。

## 开发与验证

```bash
bash scripts/test.sh
bash scripts/build-app.sh debug
bash scripts/run-interaction-smoke.sh
python3 scripts/prepare-validation.py
python3 Sources/LingoPlayer/Resources/alignment_worker.py \
  --request verification/local/clear-request.json \
  --output verification/local/clear-result.json
bash scripts/run-smoke.sh \
  "$PWD/verification/local/clear.mp4" "$PWD/verification/local/ui-mp4"
```

v0.2 的交互与兼容性结果见 [v0.2 验证记录](verification/V0.2.md)。交互自检生成短视频并连续启动两个应用进程，验证真实恢复；它使用独立数据目录。

GUI 自检会打开真实窗口、静音播放，在独立测试数据目录中保存检查结果、进度和截图。普通启动不运行自检。测试素材、依赖和构建结果不放入源码版本管理。界面快照会补入从真实 OpenGL framebuffer 读取的画面，因为 AppKit 普通视图快照不包含 OpenGL 表面。

逐词精度需要独立的人工标注，不能用模型输出给自己打分。标注 CSV 字段为 `cueID,tokenIndex,start,category`，category 为 `clear` / `fast` / `music`，start 为相对于视频的秒数。评估命令：

```bash
python3 scripts/create-annotation-template.py \
  --request verification/local/clear-request.json --category clear \
  --output verification/local/human-reference.csv
# 人工听音填写 start 后，再运行：
python3 scripts/evaluate-alignment.py --result result.json \
  --reference human-reference.csv --output accuracy.json
```

至少 100 个独立人工标注词、覆盖三类场景，清晰对白至少 90% 起点误差在 ±200 ms 内才通过。未产出的单词计入失败。当前达成情况和待验收项见 [验证记录](verification/REPORT.md)。

单独测量声学模型首次进程加载（不清空操作系统文件缓存）：

```bash
.runtime/aligner/bin/python scripts/measure-model-load.py \
  --model "$HOME/Library/Application Support/LingoPlayer/MFA/pretrained_models/acoustic/english_mfa.zip" \
  --output verification/local/model-load.json
```

依赖来源见 [第三方说明](THIRD_PARTY_NOTICES.md)。
