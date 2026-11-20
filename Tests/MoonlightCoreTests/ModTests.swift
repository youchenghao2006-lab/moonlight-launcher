import Foundation
import MoonlightCore

extension CoreTests {
    static func mods() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moonlight-mod-tests-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = InstalledVersion(id: "test-forge", javaMajor: 17, architecture: Platform.architecture, baseID: "1.20.1", loader: "forge", loaderVersion: "47.4.12")
        let profile = root.appendingPathComponent("versions/\(target.id)")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONEncoder().encode(target).write(to: profile.appendingPathComponent("moonlight.json"))
        let mods = root.appendingPathComponent("instances/\(target.id)/mods")
        try fm.createDirectory(at: mods, withIntermediateDirectories: true)
        let saves = root.appendingPathComponent("instances/\(target.id)/saves/world.dat")
        try fm.createDirectory(at: saves.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Keep this world".utf8).write(to: saves)

        func jar(_ id: String, _ version: String, filename: String, fabric: Bool = false, title: String? = nil) async throws -> URL {
            let folder = root.appendingPathComponent("fixtures/\(UUID().uuidString)")
            try fm.createDirectory(at: folder.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            let entry: String
            if fabric {
                entry = "fabric.mod.json"
                try JSONSerialization.data(withJSONObject: ["id": id, "name": "Title \(id)", "version": version]).write(to: folder.appendingPathComponent(entry))
            } else {
                entry = "META-INF/mods.toml"
                let name = String(decoding: try JSONEncoder().encode(title ?? "Title \(id)"), as: UTF8.self)
                let text = "[[mods]]\nmodId = \"\(id)\"\nversion = \"\(version)\"\ndisplayName = \(name)\n[[dependencies.\(id)]]\nmodId = \"not_a_mod\"\nmandatory = false\n"
                try Data(text.utf8).write(to: folder.appendingPathComponent(entry))
            }
            let file = folder.appendingPathComponent(filename)
            _ = try await Installer.tool("/usr/bin/zip", ["-q", file.path, entry], directory: folder)
            return file
        }
        func release(_ project: String, _ id: String, file: URL, deps: [[String: Any]] = [], loader: String = "forge", games: [String] = ["1.20.1"]) throws -> ModRelease {
            let value: [String: Any] = ["id": id, "project_id": project, "name": project, "version_number": id, "version_type": "release", "game_versions": games, "loaders": [loader], "dependencies": deps, "files": [["filename": file.lastPathComponent, "url": "https://cdn.modrinth.com/test/\(file.lastPathComponent)", "primary": true, "hashes": ["sha512": try Metadata.digest(file, sha512: true)], "size": try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!]]]
            return try JSONDecoder().decode(ModRelease.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func rejected(_ name: String, _ body: () async throws -> Void) async throws {
            var failed = false
            do { try await body() } catch { failed = true }
            try check(failed, name)
        }

        let library = try await jar("library", "2", filename: "library-2.jar")
        let main = try await jar("example", "2", filename: "example-2.jar")
        let old = try await jar("example", "1", filename: "example-1.jar")
        let fabric = try await jar("fabric_example", "1", filename: "fabric-1.jar", fabric: true)
        let info = try ModJar.inspect(main), fabricInfo = try ModJar.inspect(fabric)
        try check(info.ids == ["example"] && !info.ids.contains("not_a_mod"), "dependency TOML blocks are not installed mod IDs")
        try check(fabricInfo.ids == ["fabric_example"] && fabricInfo.version == "1", "Fabric jar metadata")
        let quotedTitle = "[Let's Do] \"Vinery\""
        let quoted = try await jar("vinery", "1", filename: "vinery.jar", title: quotedTitle)
        let quotedInfo = try ModJar.inspect(quoted)
        try check(quotedInfo.title == quotedTitle, "TOML quoted names preserve apostrophes and escaped quotes")
        // A dual-loader JAR can list Forge first. Keep the same preference on a single pass.
        let dualFolder = main.deletingLastPathComponent()
        try Data(#"{"id":"dual_fabric","name":"Dual","version":"2"}"#.utf8).write(to: dualFolder.appendingPathComponent("fabric.mod.json"))
        let dual = dualFolder.appendingPathComponent("dual.jar")
        _ = try await Installer.tool("/usr/bin/zip", ["-q", dual.path, "META-INF/mods.toml", "fabric.mod.json"], directory: dualFolder)
        let dualID = try ModJar.inspect(dual).ids
        try check(dualID == ["dual_fabric"], "descriptor order preserves dual-loader identity")
        let oversized = dualFolder.appendingPathComponent("oversized.jar")
        try Data(repeating: 65, count: 1_048_577).write(to: dualFolder.appendingPathComponent("META-INF/mods.toml"))
        _ = try await Installer.tool("/usr/bin/zip", ["-q", oversized.path, "META-INF/mods.toml"], directory: dualFolder)
        try mustThrow("over-budget decompressed descriptors are rejected") { _ = try ModJar.inspect(oversized) }
        let dependency = try release("lib", "lib2", file: library)
        let required: [String: Any] = ["dependency_type": "required", "project_id": "lib", "version_id": "lib2"]
        let mainRelease = try release("main", "main2", file: main, deps: [required, ["dependency_type": "optional", "project_id": "optional"]])
        let plan = try await ModResolver.plan(mainRelease, target: target, version: { id in
            guard id == "lib2" else { throw LauncherError("Unexpected version lookup") }; return dependency
        }, projects: { _, _ in throw LauncherError("Optional dependencies must not be resolved") })
        try check(plan.releases.map(\.id) == ["lib2", "main2"], "exact required dependencies installed before root; optional skipped")
        let wrong = try release("wrong", "wrong", file: main, loader: "fabric")
        try await rejected("wrong loader rejected") { _ = try await ModResolver.plan(wrong, target: target) }
        let wrongGame = try release("wrong", "wrongGame", file: main, games: ["1.21.1"])
        try await rejected("wrong game version rejected") { _ = try await ModResolver.plan(wrongGame, target: target) }
        let missing = try release("missing", "missing", file: main, deps: [["dependency_type":"required", "project_id":"absent"]])
        try await rejected("missing required dependency rejected") { _ = try await ModResolver.plan(missing, target: target, projects: { _, _ in [] }) }
        let cycle = try release("cycle", "cycle1", file: main, deps: [["dependency_type":"required", "project_id":"cycle"]])
        try await rejected("dependency cycle rejected") { _ = try await ModResolver.plan(cycle, target: target) }
        let malformed = try release("malformed", "malformed", file: main, deps: [["dependency_type":"required", "file_name":"manual.jar"]])
        try await rejected("manual-only dependency is not silently skipped") { _ = try await ModResolver.plan(malformed, target: target) }
        let conflicting = try release("main", "conflicting", file: main, deps: [required, ["dependency_type":"incompatible", "project_id":"lib"]])
        try await rejected("incompatible planned dependency rejected") { _ = try await ModResolver.plan(conflicting, target: target, version: { _ in dependency }) }

        try fm.copyItem(at: old, to: mods.appendingPathComponent(old.lastPathComponent))
        let manager = ModManager(root: root)
        let original = try await manager.localMods(target)
        try check(original.count == 1 && original[0].version == "1", "existing unmanaged jar recognized")
        let sources = [main.lastPathComponent: main, library.lastPathComponent: library]
        let download: @Sendable (ModRelease.File, URL) async throws -> Void = { file, destination in
            guard let source = sources[file.filename] else { throw LauncherError("Missing fixture") }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        // Corrupt downloads must leave the previous working installation unchanged.
        try await rejected("checksum failure rejects installation") {
            try await manager.install(plan, download: { _, destination in try Data("corrupt".utf8).write(to: destination) }, progress: { _ in })
        }
        try check(fm.fileExists(atPath: mods.appendingPathComponent(old.lastPathComponent).path) && !fm.fileExists(atPath: mods.appendingPathComponent(library.lastPathComponent).path), "checksum failure makes no partial changes")
        // Force a collision only after staging to exercise commit rollback.
        try await rejected("commit failure rolls back installation") {
            try await manager.install(plan, download: download, progress: { progress in
                if progress.fraction == 0.9 { try? FileManager.default.createDirectory(at: mods.appendingPathComponent(main.lastPathComponent), withIntermediateDirectories: true) }
            })
        }
        try check(fm.fileExists(atPath: mods.appendingPathComponent(old.lastPathComponent).path) && !fm.fileExists(atPath: mods.appendingPathComponent(library.lastPathComponent).path), "rollback restores old jar and removes newly added dependency")
        try fm.removeItem(at: mods.appendingPathComponent(main.lastPathComponent))
        try await manager.install(plan, download: download, progress: { _ in })
        let installed = try await manager.localMods(target)
        try check(installed.count == 2 && installed.contains { $0.version == "2" && $0.modIDs == ["example"] }, "install root and dependency without duplicate old mod")
        let backupRoot = root.appendingPathComponent("backups/mods/\(target.id)")
        let backups = (fm.enumerator(at: backupRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        try check(backups.contains { $0.lastPathComponent == old.lastPathComponent }, "replaced unmanaged jar backed up")
        let active = installed.first { $0.modIDs == ["example"] }!
        try await manager.setEnabled(active, target: target, enabled: false)
        let paused = try await manager.localMods(target).first { $0.modIDs == ["example"] }!
        try check(!paused.enabled && paused.filename.hasSuffix(".jar.disabled"), "disable retains jar")
        try await manager.setEnabled(paused, target: target, enabled: true)
        let restored = try await manager.localMods(target).first { $0.modIDs == ["example"] }!
        try check(restored.enabled, "re-enable restores original name")
        let removed = try await manager.remove(restored, target: target)
        try check(fm.fileExists(atPath: removed.appendingPathComponent(restored.filename).path) && !fm.fileExists(atPath: mods.appendingPathComponent(restored.filename).path), "remove is recoverable from backup")
        let saved = try Data(contentsOf: saves)
        try check(saved == Data("Keep this world".utf8), "mod operations preserve saves")
        try fm.removeItem(at: mods)
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: mods, withDestinationURL: outside)
        try await rejected("symlink mod directory rejected") { _ = try await manager.localMods(target) }
    }
}
