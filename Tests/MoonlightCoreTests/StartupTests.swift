import Foundation
import MoonlightCore

extension CoreTests {
    static func startupCaches() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("moonlight-startup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let javaHome = root.appendingPathComponent("runtime/java-17-\(Platform.architecture)/test-jre/Contents/Home")
        let executable = javaHome.appendingPathComponent("bin/java")
        let probes = javaHome.appendingPathComponent("bin/probes")
        for file in ["bin/java", "lib/libjli.dylib", "lib/server/libjvm.dylib", "lib/modules", "release"] {
            let url = javaHome.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let arch = Platform.architecture == "arm64" ? "aarch64" : "x86_64"
        let script = """
        #!/bin/sh
        echo probe >> "$(dirname "$0")/probes"
        echo "java.specification.version = 17"
        echo "os.arch = \(arch)"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let installer = Installer(root: root)
        func count() throws -> Int { try String(contentsOf: probes, encoding: .utf8).split(separator: "\n").count }
        for _ in 0..<2 {
            _ = try await installer.java(major: 17, custom: "") { _ in }
        }
        let unchanged = try count()
        try check(unchanged == 1, "second launch reuses managed runtime validation")
        try Data("updated VM".utf8).write(to: javaHome.appendingPathComponent("lib/server/libjvm.dylib"), options: .atomic)
        _ = try await installer.java(major: 17, custom: "") { _ in }
        let modified = try count()
        try check(modified == 2, "changed VM invalidates cached validation")
        _ = try await installer.java(major: 17, custom: executable.path) { _ in }
        let custom = try count()
        try check(custom == 3, "custom Java always probed")

        let catalog = root.appendingPathComponent("manifest-cache.json")
        let payload = #"{"latest":{"release":"1.20.1","snapshot":"test"},"versions":[{"id":"1.20.1","type":"release","url":"https://example.org/manifest","releaseTime":"2023-06-12"}]}"#
        try Data(payload.utf8).write(to: catalog)
        let current = await installer.cachedManifest(maximumAge: 3600)
        try check(current?.latest.release == "1.20.1", "recent catalog can satisfy startup locally")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: catalog.path)
        let expired = await installer.cachedManifest(maximumAge: 3600)
        let offline = await installer.cachedManifest()
        try check(expired == nil && offline?.versions.first?.id == "1.20.1", "stale catalog needs refresh but stays available offline")
        try Data("invalid".utf8).write(to: catalog)
        let corrupt = await installer.cachedManifest(maximumAge: 3600)
        try check(corrupt == nil, "malformed catalog never short-circuits refresh")
    }
}
