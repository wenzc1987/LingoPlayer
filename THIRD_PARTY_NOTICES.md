# 第三方来源

本项目的安装脚本下载下列组件。它们各自的版权及许可仍适用；本机技术原型没有重新授予这些组件的许可。

| 组件 | 来源与许可说明 |
|---|---|
| mpv / libmpv | https://github.com/mpv-player/mpv ，GPL-2.0-or-later；部分构建配置可用 LGPL。当前使用 IINA 官方预编译库，不假定其为 LGPL 构建。 |
| IINA 预编译动态库 | https://iina.io/dylibs/ ，获取方式参照 https://github.com/iina/iina/blob/develop/other/download_libs.sh 。包括 FFmpeg、libass 等传递依赖，各库许可参见其上游。安装后来源与 SHA-256 记录在 `.runtime/lib/provenance.json`。 |
| Montreal Forced Aligner | https://github.com/MontrealCorpusTools/Montreal-Forced-Aligner ，MIT；当前固定 3.3.9。 |
| Kalpy / Kaldi | https://github.com/mmcauliffe/kalpy ，MIT；https://github.com/kaldi-asr/kaldi ，Apache-2.0。 |
| MFA 英语模型和发音词典 | https://mfa-models.readthedocs.io/ ，通过 MFA 官方模型下载器获取，具体版本和许可见下载模型内元数据及模型卡。 |
| ECDICT | https://github.com/skywind3000/ECDICT ，MIT；项目作者 skywind3000，词库来源记录随生成 SQLite 保存。 |
| Miniforge / conda-forge | https://github.com/conda-forge/miniforge ，BSD-3-Clause；具体环境的全部包版本及下载地址保存在 `.runtime/aligner-lock.txt`。包本身遵循各自许可。 |
| SQLite | https://sqlite.org/copyright.html ，公有领域。 |
| OpenSubtitles | https://www.opensubtitles.com/ ，通过其官方 API 查询，服务权限和配额由个人配置决定。 |
| 验证音频 LibriSpeech | https://www.openslr.org/12 ，CC BY 4.0。Vassil Panayotov、Guoguo Chen、Daniel Povey、Sanjeev Khudanpur。脚本截取、拼接 test-clean 音频并配合测试图案生成视频；具体条目和变更在 `verification/local/provenance.json`。 |

开发脚本和应用仅用于当前个人原型。公开分发尚不在此版本范围；完整的依赖许可归档、独立安装器和签名公证需在分发前完成。
