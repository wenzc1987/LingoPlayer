import AppKit
import CoreServices

// Register this exact bundle after packaging; do not reset global Finder caches
// or overwrite the user's preferred applications for video files.
let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let status = LSRegisterURL(url as CFURL, true)
if status != noErr { fputs("Application registration failed: \(status)\n", stderr); exit(1) }
NSWorkspace.shared.noteFileSystemChanged(url.path)
