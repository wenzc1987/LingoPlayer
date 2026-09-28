import plistlib
from pathlib import Path
import sys

app, runtime = Path(sys.argv[1]), sys.argv[2]
info = {
    "CFBundleExecutable": "LingoPlayer", "CFBundleIdentifier": "local.lingoplayer.mac",
    "CFBundleName": "LingoPlayer", "CFBundleDisplayName": "LingoPlayer",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.3.1",
    "CFBundleIconFile": "AppIcon.icns", "CFBundleVersion": "18", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication", "LingoPlayerRuntime": runtime,
    "CFBundleDocumentTypes": [{"CFBundleTypeName": "Video and subtitle files", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate", "CFBundleTypeExtensions": ["mp4", "mkv", "mov", "avi", "webm", "m4v", "srt", "ass", "ssa", "vtt"]}]
}
with (app / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump(info, stream)
