// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Moonlight",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Moonlight", targets: ["Moonlight"])],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "MoonlightCore", dependencies: ["CArchive"]),
        .executableTarget(name: "Moonlight", dependencies: ["MoonlightCore"]),
        .executableTarget(name: "MoonlightCheck", dependencies: ["MoonlightCore"]),
        .executableTarget(name: "MoonlightCoreTests", dependencies: ["MoonlightCore"], path: "Tests/MoonlightCoreTests", resources: [.copy("Fixtures")])
    ]
)
