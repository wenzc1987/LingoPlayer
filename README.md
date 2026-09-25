# LingoPlayer

个人使用的 macOS 英语学习播放器技术原型。SwiftUI / AppKit 界面、libmpv 播放、本地 MFA 逐词对齐、ECDICT 词典和 SQLite 缓存。

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

## 在线字幕配置

在设置中填写 OpenSubtitles API Key；如下载需要登录，在同一页输入该服务的用户名和密码。API Key 和登录 token 存入 macOS 钥匙串，密码不持久化。

搜索使用文件哈希、片名、年份和季集信息。唯一文件哈希匹配可自动采用；不确定的匹配展示候选供选择。找不到或服务不可用时仍可播放，并可导入本地字幕。所选字幕及各语言偏移随片源保存。没有配置 API Key 不影响本地功能。

在线服务会收到搜索所需的文件哈希与片名信息；视频、音频不上传。字幕文件和词典在准备后可离线使用。首次安装模型和词库需要联网；播放期间不会自动下载模型。

## 数据与实现

默认数据目录：`~/Library/Application Support/LingoPlayer/`。

| 文件或目录 | 用途 |
|---|---|
| `library.sqlite` | 观看位置、音轨、字幕路径、偏移、逐句对齐缓存 |
| `settings.json` | 本地依赖路径与自动搜索设置；不含密钥 |
| `MFA/pretrained_models` | 本地声学模型及发音词典 |
| `Subtitles` | 抽取的内嵌字幕和下载字幕 |
| `AlignmentJobs` | 对齐临时文件，任务结束后清理 |
| `alignment-metrics.jsonl` | 每批处理耗时、子进程峰值内存、词数与失败数 |

`LINGOPLAYER_DATA_DIR` 可覆盖数据目录；`LINGOPLAYER_RUNTIME` 可指定依赖根目录。自定义运行环境也可在设置页配置。更换 libmpv 路径后需重启。

`PlayerCore` 提供字幕解析、独立时间轴、学习状态、词典、字幕服务和存储。`CMpv` 仅适配 libmpv 的稳定 C API，播放器控制运行在串行队列，渲染在主线程。`LingoPlayer` 管理界面、双窗口和后台调度。学习内容通过 `LearningContentProvider` 接口接入，后续扩展不需要改动播放内核。

对齐使用独立可取消进程，一次优先准备当前播放位置附近约 30 秒的字幕。缓存按片源标识、字幕内容、音轨、英文偏移、模型版本和处理脚本版本隔离，逐句保存。跳转到尚未准备的新片段会调整队列。故障片段保持整句；基础设施故障会停止自动重试并显示状态。

## 开发与验证

```bash
bash scripts/test.sh
bash scripts/build-app.sh debug
python3 scripts/prepare-validation.py
python3 Sources/LingoPlayer/Resources/alignment_worker.py \
  --request verification/local/clear-request.json \
  --output verification/local/clear-result.json
bash scripts/run-smoke.sh \
  "$PWD/verification/local/clear.mp4" "$PWD/verification/local/ui-mp4"
```

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
