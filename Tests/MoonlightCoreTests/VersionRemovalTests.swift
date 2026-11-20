import Foundation
import MoonlightCore

extension CoreTests {
    static func versionRemoval() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("moonlight-remove-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func write(_ relative: String, _ content: Data = Data("keep".utf8)) throws {
            let file = root.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file)
        }
        func fixture(_ id: String, saves: Bool = true) throws -> InstalledVersion {
            let version = InstalledVersion(id: id, javaMajor: 17, architecture: Platform.architecture, baseID: id == "1.20.1" ? nil : "1.20.1", loader: id == "1.20.1" ? nil : "forge", loaderVersion: id == "1.20.1" ? nil : "47.4.12")
            try write("versions/\(id)/moonlight.json", JSONEncoder().encode(version))
            try write("versions/\(id)/\(id).json")
            try write("instances/\(id)/mods/mod.jar")
            try write("instances/\(id)/config/options.txt")
            if saves { try write("instances/\(id)/saves/World/level.dat", Data("precious world".utf8)) }
            return version
        }
        let installer = Installer(root: root)
        let base = try fixture("1.20.1"), child = try fixture("pack-example")
        try write("versions/1.20.1/1.20.1.jar")
        try write("libraries/shared.jar"); try write("assets/shared.asset"); try write("runtime/java-17/bin/java")
        let fakeTrash: (URL) throws -> URL? = { folder in
            let destination = root.appendingPathComponent("test-trash/\(folder.lastPathComponent)")
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: folder, to: destination); return destination
        }
        let kept = try await installer.removeVersion(base, keepSaves: true, trash: fakeTrash)
        let savedWorld = try Data(contentsOf: kept.savesBackup!.appendingPathComponent("saves/World/level.dat"))
        try check(savedWorld == Data("precious world".utf8), "saved world contents preserved outside Trash")
        try check(fm.fileExists(atPath: kept.savesBackup!.appendingPathComponent("version.json").path), "save backup retains original version identity")
        try check(!fm.fileExists(atPath: root.appendingPathComponent("instances/1.20.1").path), "private instance removed")
        let afterBase = await installer.installed()
        try check(afterBase.map(\.id) == [child.id], "deleted base record disappears; dependent instance remains listed")
        try check(fm.fileExists(atPath: root.appendingPathComponent("versions/1.20.1/1.20.1.jar").path) && fm.fileExists(atPath: root.appendingPathComponent("versions/1.20.1/1.20.1.json").path), "shared base jar and metadata remain for dependent instances")
        try check(["libraries/shared.jar", "assets/shared.asset", "runtime/java-17/bin/java", "instances/pack-example/saves/World/level.dat"].allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }, "shared dependencies and other worlds unchanged")
        try check(fm.fileExists(atPath: kept.trashLocation!.appendingPathComponent("instance/mods/mod.jar").path) && !fm.fileExists(atPath: kept.trashLocation!.appendingPathComponent("instance/saves").path), "non-save files trashed with recovery instructions")

        // A failed system Trash operation must restore both the record and all user data.
        var failed = false
        do { _ = try await installer.removeVersion(child, keepSaves: true, trash: { _ in throw LauncherError("Simulated Trash failure") }) }
        catch { failed = true }
        let rolledBack = await installer.installed()
        let restoredWorld = try Data(contentsOf: root.appendingPathComponent("instances/pack-example/saves/World/level.dat"))
        try check(failed && rolledBack.contains(child) && restoredWorld == Data("precious world".utf8), "Trash failure restores installation record and save contents")
        try check(fm.fileExists(atPath: root.appendingPathComponent("instances/pack-example/mods/mod.jar").path), "Trash failure restores mods too")
        let discarded = try await installer.removeVersion(child, keepSaves: false, trash: fakeTrash)
        try check(discarded.savesBackup == nil && !discarded.keptSaves && fm.fileExists(atPath: discarded.trashLocation!.appendingPathComponent("instance/saves/World/level.dat").path), "opt-out keeps worlds recoverable inside Trash")
        let empty = await installer.installed()
        try check(empty.isEmpty, "last deletion leaves empty version list")

        let noWorld = try fixture("no-world", saves: false)
        let noBackup = try await installer.removeVersion(noWorld, keepSaves: true, trash: fakeTrash)
        try check(noBackup.savesBackup == nil, "missing saves does not create a misleading empty backup")
        let missingInstance = try fixture("no-instance", saves: false)
        try fm.removeItem(at: root.appendingPathComponent("instances/no-instance"))
        _ = try await installer.removeVersion(missingInstance, keepSaves: true, trash: fakeTrash)
        let afterMissing = await installer.installed()
        try check(!afterMissing.contains(missingInstance), "missing game directory still allows record removal")

        let changed = try fixture("changed")
        try write("versions/changed/moonlight.json", Data("changed".utf8))
        failed = false
        do { _ = try await installer.removeVersion(changed, keepSaves: false, trash: fakeTrash) } catch { failed = true }
        try check(failed && fm.fileExists(atPath: root.appendingPathComponent("instances/changed/saves/World/level.dat").path), "stale record rejected without touching files")
        let linked = try fixture("linked", saves: false)
        let originalInstance = root.appendingPathComponent("instances/linked")
        let outside = root.appendingPathComponent("outside")
        try fm.moveItem(at: originalInstance, to: outside)
        try fm.createSymbolicLink(at: originalInstance, withDestinationURL: outside)
        failed = false
        do { _ = try await installer.removeVersion(linked, keepSaves: false, trash: fakeTrash) } catch { failed = true }
        try check(failed && fm.fileExists(atPath: outside.appendingPathComponent("mods/mod.jar").path), "linked instance rejected without touching destination")
        let unsafe = InstalledVersion(id: "../outside", javaMajor: 17, architecture: Platform.architecture)
        failed = false
        do { _ = try await installer.removeVersion(unsafe, keepSaves: false, trash: fakeTrash) } catch { failed = true }
        try check(failed, "unsafe instance ID rejected")
    }
}
