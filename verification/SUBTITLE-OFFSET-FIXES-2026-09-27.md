# 字幕偏移 P2 修复验证 · 2026-09-27

LingoPlayer 0.3.1 build 10，修复对 `e328f7c` 的两项审查发现。

- 退出前将待生效的英文、中文偏移纳入播放记录，再取消定时器并等待存储完成。退出不重新启动逐词对齐；未调整的旧版高精度偏移保持原值，重复退出准备不会覆盖已保存的新值。
- “重新准备逐词高亮”直接重启对齐，不再通过字幕偏移 setter 间接重启，因此不清除草稿，也不改变原定的 1 秒延迟。

## 验证结果

| 检查 | 结果 |
|---|---|
| Swift 核心测试 | 64/64 |
| Python 测试 | 10/10 |
| 原生窗口与交互检查 | 61/61 |
| 发行包构建、签名校验 | 通过 |

新增 6 项原生回归检查：实际点击高亮按钮后，草稿和等待期保留、偏移按时应用且保存；退出保存单语言草稿时保留另一语言的 0.25 秒精度；同时保存两语言草稿和播放进度、句尾余量；重复退出准备后仍保留新值。

应用实际退出后另行只读查询隔离的 SQLite 数据库，确认最终保存英文 `-0.3` 秒、中文 `0.4` 秒，没有被退出流程后续调用覆盖。所有验证使用合成视频与独立数据目录，不修改用户播放记录。

```bash
bash scripts/test.sh
bash scripts/build-app.sh
bash scripts/run-chrome-smoke.sh "$PWD/verification/local/subtitle-offset-fixes"
codesign --verify --deep --strict dist/LingoPlayer.app
```

[机器结果](subtitle-offset-fixes-2026-09-27.json)。本机日志及截图位于 `verification/local/subtitle-offset-fixes*`。

最终可执行文件 SHA-256：`c71a1949b271d1929ccd771e1034cc3a4caa94b45070ef4855670460e3eb9aac`。
