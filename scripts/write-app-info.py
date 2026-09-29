import plistlib
from pathlib import Path
import sys
from versioning import read_version

app, runtime = Path(sys.argv[1]), sys.argv[2]
version = read_version(Path(__file__).resolve().parents[1])
info = {
    "CFBundleExecutable": "LingoPlayer", "CFBundleIdentifier": "local.lingoplayer.mac",
    "CFBundleName": "LingoPlayer", "CFBundleDisplayName": "LingoPlayer",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
    "CFBundleIconFile": "AppIcon.icns", "CFBundleVersion": version, "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication", "LingoPlayerRuntime": runtime,
    "CFBundleDocumentTypes": [{"CFBundleTypeName": "Video and subtitle files", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate", "CFBundleTypeExtensions": ["mp4", "mkv", "mov", "avi", "webm", "m4v", "srt", "ass", "ssa", "vtt"]}]
}
with (app / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump(info, stream)
