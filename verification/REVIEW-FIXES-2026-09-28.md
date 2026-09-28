# Code review 修复验证 · 2026-09-28

## 修复内容

- 单独导入英文时保留现有中文字幕、来源及文件路径；普通双语导入仍替换两组字幕。
- 重开影片时，显式保存的中文文件覆盖主字幕附带的默认译文，同时保留两组偏移。会话和字幕选择版本检查仍保护新的用户选择。
- 操作面板根据实际高度选择字幕上方或下方的可用空间；空间不足时保持在窗口内、片名下方。字幕、控件和提示的布局高度受到视频区域约束，避免撑高叠加层、移动视频和片名。字幕与导出截图仍共用原来的画面边界计算。

## 验证结果

- 100 项 Swift Testing 测试、15 个测试套件通过；新增几何测试覆盖上移字幕、最小窗口、竖屏／宽屏和超高字幕。
- 原生播放模式检查 72 项通过，应用重启恢复检查 4 项通过。
- 新增原生回归检查验证英文导入保留中文、普通双语导入替换中文、影片切换及应用重启后恢复自选中文。
- 在 680×360 视频区域、英文字号 36、中文字号 28、底部距离 160 下，普通／学习模式的进度条、全部按钮、片名均位于窗口内，视频区域与窗口内容边界一致。
- 原生学习开关检查等待实际状态变化，避免把固定 200 ms 等待期当作操作完成的依据。
- `git diff --check` 与 smoke 脚本语法检查通过。

完整结果：[review-fixes-2026-09-28.json](review-fixes-2026-09-28.json)。截图和测试影片保存在本机 `/tmp/lingoplayer-review-fix-smoke-3`，未纳入 Git。

## 复现

本机 Command Line Tools 的 `_Testing_Foundation` 缺少模块文件。测试使用临时编译缓存、显式测试框架路径，并关闭自动 cross-import overlay；未修改或安装系统工具链：

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lingoplayer-review-module-cache swift test \
  --disable-sandbox --cache-path /tmp/lingoplayer-review-spm-cache \
  -Xswiftc -module-cache-path -Xswiftc /tmp/lingoplayer-review-module-cache \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks

LINGOPLAYER_TEST_BINARY="$PWD/.build/debug/LingoPlayer" \
  bash scripts/run-playback-mode-smoke.sh /tmp/lingoplayer-review-fix-smoke-new
```

原生检查需要可用的 macOS 图形会话，并使用独立数据目录、合成测试影片和静音播放。
