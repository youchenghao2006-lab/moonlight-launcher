import Foundation
import MoonlightCore

// A standalone harness also runs with Command Line Tools and no Xcode/XCTest.
@main
struct CoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw LauncherError("Assertion failed: \(message)") }
    }
    static func mustThrow(_ message: String, _ body: () throws -> Void) throws {
        var threw = false
        do { try body() } catch { threw = true }
        try check(threw, message)
    }
    static func main() async {
        do {
            try rules(); try arguments(); try paths(); try hashes(); try fixture(); try loaders(); try packs()
            try await incompleteInstall()
            try await startupCaches()
            try await mods()
            try await versionRemoval()
            try await authentication()
            if CommandLine.arguments.contains("--keychain") { try await keychainRoundTrip() }
            print("PASS: \(checks) assertions (rules, platform metadata, arguments, paths, checksums, UUIDs, loaders, pack archives, install state, authentication, launch identity, secret redaction, mod dependencies and transactions, version removal and save preservation)")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
    static func rules() throws {
        let rules: [[String: Any]] = [["action": "allow"], ["action": "disallow", "os": ["name": "osx"]]]
        try check(!Metadata.rulesAllow(rules), "ordered deny wins")
        try check(Metadata.rulesAllow(nil), "no rules allows")
        try check(!Metadata.rulesAllow([["action": "allow", "os": ["name": "windows"]]]), "exclude Windows")
        try check(!Metadata.rulesAllow([["action": "allow", "features": ["is_quick_play_realms": true]]]), "exclude unavailable features")
        try check(Metadata.rulesAllow([["action": "allow", "features": ["is_demo_user": true]]], demo: true), "include demo")
    }
    static func arguments() throws {
        let items: [Any] = ["--gameDir", "${game_directory}", ["rules": [["action": "allow", "features": ["is_demo_user": true]]], "value": "--demo"]]
        let regular = try Metadata.arguments(items, values: ["game_directory": "/a b/游戏"], demo: false)
        let demo = try Metadata.arguments(items, values: ["game_directory": "/a b/游戏"], demo: true)
        try check(regular == ["--gameDir", "/a b/游戏"], "preserve paths as one argument")
        try check(demo.last == "--demo", "demo mode")
        try mustThrow("unknown placeholder must fail") { _ = try Metadata.arguments(["${unknown}"], values: [:], demo: false) }
    }
    static func paths() throws {
        let root = URL(fileURLWithPath: "/tmp/moonlight")
        for path in ["../escape", "/etc/passwd", "a/../../escape", "a\\b", "C:/escape", "a/\u{0000}b", ""] {
            try mustThrow("reject \(path)") { _ = try Metadata.safePath(path, under: root) }
        }
        let file = try Metadata.safePath("a/b.jar", under: root)
        try check(file.path == "/tmp/moonlight/a/b.jar", "relative path")
    }
    static func hashes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let sha1 = try Metadata.digest(file), sha256 = try Metadata.digest(file, sha256: true)
        try check(sha1 == "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1")
        try check(sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256")
        let sha512 = try Metadata.digest(file, sha512: true)
        try check(sha512 == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "SHA-512")
        try check(Metadata.offlineUUID("Notch") == "b50ad385829d3141a2167e7d7539ba7f", "Java offline UUID")
    }
    static func fixture() throws {
        let file = Bundle.module.url(forResource: "1.21.1", withExtension: "json", subdirectory: "Fixtures")!
        let metadata = try Metadata.object(Data(contentsOf: file))
        for arch in ["arm64", "x86_64"] {
            let libs = Metadata.libraries(metadata, arch: arch)
            try check(!libs.isEmpty, "libraries are selected")
            try check(!libs.contains { ($0["name"] as? String ?? "").contains("natives-windows") }, "exclude Windows natives")
            try check(!libs.contains { ($0["name"] as? String ?? "").contains("natives-linux") }, "exclude Linux natives")
            let glfw = libs.filter { ($0["name"] as? String ?? "").contains("lwjgl-glfw:") && ($0["name"] as? String ?? "").contains("natives-macos") }
            try check(glfw.count == 1, "exactly one GLFW native architecture")
            try check((glfw.first?["name"] as? String)?.contains("arm64") == (arch == "arm64"), "correct native architecture")
        }
    }
    static func loaders() throws {
        try check(GameVersion.supports("1.19") && GameVersion.supports("1.20.1"), "modern game releases")
        try check(GameVersion.supports("26.3"), "new release numbering")
        try check(!GameVersion.supports("1.18.2") && !GameVersion.supports("26w01a"), "legacy and snapshots excluded")
        let path = try Metadata.mavenPath("org.test:module:2.0:natives-macos@zip")
        try check(path == "org/test/module/2.0/module-2.0-natives-macos.zip", "Maven classifier and extension")
        try mustThrow("invalid Maven coordinate") { _ = try Metadata.mavenPath("bad:name") }
        let parent: [String: Any] = ["mainClass": "vanilla", "libraries": [["name": "org.test:lib:1"], ["name": "org.test:lib:1:natives-macos"]], "arguments": ["game": ["--username", "Player"], "jvm": ["-cp", "${classpath}"]]]
        let child: [String: Any] = ["mainClass": "fabric", "inheritsFrom": "1.21.1", "libraries": [["name": "org.test:lib:2"]], "arguments": ["game": ["--loader"]]]
        let merged = Metadata.merge(parent: parent, child: child)
        try check(merged["mainClass"] as? String == "fabric" && merged["inheritsFrom"] == nil, "resolve inherited loader metadata")
        let libraries = merged["libraries"] as! [[String: String]]
        try check(libraries.map { $0["name"]! } == ["org.test:lib:1:natives-macos", "org.test:lib:2"], "override dependency version, preserve native classifier")
        let args = merged["arguments"] as! [String: [String]]
        try check(args["game"] == ["--username", "Player", "--loader"] && args["jvm"] == ["-cp", "${classpath}"], "inherit and append arguments")
    }
    static func packs() throws {
        for name in ["traversal", "drive", "collision", "parent-file", "symlink", "local-mismatch", "alternate-name"] {
            let file = Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures")!
            try mustThrow("reject unsafe ZIP \(name)") { try PackArchive.validate(file) }
        }
        try PackArchive.validate(Bundle.module.url(forResource: "valid", withExtension: "zip", subdirectory: "Fixtures")!)
        try check(true, "valid ZIP accepted")
        var json: [String: Any] = ["game": "minecraft", "formatVersion": 1, "name": "Test", "versionId": "1", "dependencies": ["minecraft": "1.20.1", "forge": "47.4.12"], "files": [["path": "mods/test.jar", "hashes": ["sha512": String(repeating: "a", count: 128)], "downloads": ["https://cdn.modrinth.com/test.jar"]]]]
        func index(_ value: [String: Any]) throws -> PackIndex { try JSONDecoder().decode(PackIndex.self, from: JSONSerialization.data(withJSONObject: value)) }
        try index(json).validate(); try check(true, "Forge MRPack accepted")
        json["dependencies"] = ["minecraft": "1.20.1", "quilt-loader": "1"]
        try mustThrow("unsupported loader rejected before downloads") { try index(json).validate() }
        json["dependencies"] = ["minecraft": "1.20.1"]
        var files = json["files"] as! [[String: Any]]
        files[0]["path"] = "../outside.jar"; json["files"] = files
        try mustThrow("MRPack traversal rejected") { try index(json).validate() }
        try mustThrow("unknown download origin rejected") { try PackIndex.validateDownload("https://example.com/file") }
        try mustThrow("HTTP rejected") { try PackIndex.validateDownload("http://cdn.modrinth.com/file") }
    }
    static func incompleteInstall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let versionDir = root.appendingPathComponent("versions/1.21.1")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: versionDir.appendingPathComponent("1.21.1.jar"))
        let installer = Installer(root: root)
        let incomplete = await installer.installed()
        try check(incomplete.isEmpty, "partial installs stay hidden")
        let version = InstalledVersion(id: "1.21.1", javaMajor: 21, architecture: Platform.architecture)
        try JSONEncoder().encode(version).write(to: versionDir.appendingPathComponent("moonlight.json"))
        // Old 0.1 markers have none of the new optional loader/pack fields.
        let old = "{\"id\":\"1.21.1\",\"javaMajor\":21,\"architecture\":\"\(Platform.architecture)\",\"installedAt\":0}"
        try Data(old.utf8).write(to: versionDir.appendingPathComponent("moonlight.json"))
        let complete = await installer.installed()
        try check(complete.map(\.id) == ["1.21.1"], "complete install listed")
    }
}
