#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_DEVELOPER="$(xcode-select -p)"
TASK_FRAMEWORKS="$TASK_DEVELOPER/Library/Developer/Frameworks"
if [ -d "$TASK_FRAMEWORKS/Testing.framework" ] && [ ! -d "$TASK_FRAMEWORKS/XCTest.framework" ]; then
  # Some Command Line Tools distributions omit the Foundation cross-import
  # overlay module. Core assertions work without that optional overlay.
  swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$TASK_FRAMEWORKS" \
    -Xswiftc -plugin-path -Xswiftc "$TASK_DEVELOPER/usr/lib/swift/host/plugins/testing" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker "$TASK_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$TASK_FRAMEWORKS"
else
  swift test
fi
python3 -m unittest discover -s tests -v
