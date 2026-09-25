// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LingoPlayer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LingoPlayer", targets: ["LingoPlayer"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CMpv", linkerSettings: [.linkedFramework("OpenGL")]),
        .target(name: "PlayerCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "LingoPlayer", dependencies: ["PlayerCore", "CMpv"],
                          resources: [.copy("Resources/alignment_worker.py")],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("OpenGL"), .linkedFramework("Security")]),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"])
    ]
)
