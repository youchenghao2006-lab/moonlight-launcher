import Foundation

public struct VersionRemovalResult: Sendable {
    public let version: InstalledVersion
    public let keptSaves: Bool
    public let savesBackup: URL?
    public let trashLocation: URL?
}

extension Installer {
    /// Remove the installation record and private instance; shared engine files stay cached.
    /// Stage all moves before asking macOS to trash a single recoverable folder.
    public func removeVersion(_ version: InstalledVersion, keepSaves: Bool,
                              trash: (URL) throws -> URL? = { folder in
                                  var result: NSURL?
                                  try FileManager.default.trashItem(at: folder, resultingItemURL: &result)
                                  return result.map { $0 as URL }
                              }) throws -> VersionRemovalResult {
        let fm = FileManager.default
        guard version.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*$", options: .regularExpression) != nil else {
            throw LauncherError("游戏实例编号无效，未删除文件。")
        }
        func path(_ relative: String) throws -> URL {
            let result = try Metadata.safePath(relative, under: root)
            var current = root
            for part in relative.split(separator: "/") {
                current.appendPathComponent(String(part))
                if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw LauncherError("游戏目录含符号链接，未删除文件。请先检查游戏目录。")
                }
            }
            return result
        }
        let record = try path("versions/\(version.id)/moonlight.json")
        guard (try? record.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: record),
              let current = try? JSONDecoder().decode(InstalledVersion.self, from: data), current == version else {
            throw LauncherError("游戏版本记录已变化，请重新打开版本管理。")
        }
        let instance = try path("instances/\(version.id)")
        let saves = keepSaves ? try path("instances/\(version.id)/saves") : nil
        if fm.fileExists(atPath: instance.path), (try instance.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true {
            throw LauncherError("游戏目录不是文件夹，未删除文件。")
        }
        let hasSaves = saves.map { fm.fileExists(atPath: $0.path) } ?? false
        if hasSaves, let saves, (try saves.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true {
            throw LauncherError("存档目录不是文件夹，未删除文件。")
        }
        let token = UUID().uuidString
        let staging = try path("staging/Moonlight-\(version.id)-\(token)")
        let backup = hasSaves ? try path("backups/saves/\(version.id)/\(token)") : nil
        try Task.checkCancellation()
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var moves: [(source: URL, destination: URL)] = []
        func move(_ source: URL, _ destination: URL) throws {
            try fm.moveItem(at: source, to: destination)
            moves.append((source, destination))
        }
        do {
            let info = """
            月光启动器：\(version.title)（\(version.id)）
            删除于：\(ISO8601DateFormatter().string(from: Date()))
            原游戏目录：\(instance.path)
            恢复版本：将本文件夹的 moonlight.json 放回 \(record.deletingLastPathComponent().path)，将 instance 放回原游戏目录。
            \(backup.map { "单独保留的存档位于：\($0.appendingPathComponent("saves").path)" } ?? "如果原游戏目录中有存档，它们随 instance 一起保存在此文件夹。")
            恢复前请退出游戏与启动器，避免覆盖后来创建的文件。
            """
            try info.write(to: staging.appendingPathComponent("恢复说明.txt"), atomically: true, encoding: .utf8)
            if let backup {
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                try JSONEncoder().encode(version).write(to: backup.appendingPathComponent("version.json"))
                try "将 saves 文件夹复制到重新安装的对应版本「游戏文件」目录内，再启动游戏。\n原实例：\(version.title)（\(version.id)）\n".write(to: backup.appendingPathComponent("恢复存档.txt"), atomically: true, encoding: .utf8)
            }
            if fm.fileExists(atPath: instance.path) { try move(instance, staging.appendingPathComponent("instance")) }
            if let backup { try move(staging.appendingPathComponent("instance/saves"), backup.appendingPathComponent("saves")) }
            // The record is removed last, and restored first if trashing fails.
            try move(record, staging.appendingPathComponent("moonlight.json"))
            try Task.checkCancellation()
            let trashed = try trash(staging)
            return VersionRemovalResult(version: version, keptSaves: keepSaves, savesBackup: backup, trashLocation: trashed)
        } catch {
            var failed = false
            for item in moves.reversed() {
                do { try fm.moveItem(at: item.destination, to: item.source) }
                catch { failed = true }
            }
            if failed {
                throw LauncherError("删除未完成，自动恢复失败。请保留并检查 \(staging.path)\(backup.map { " 与 " + $0.path } ?? "") 中的原文件。")
            }
            try? fm.removeItem(at: staging)
            if let backup { try? fm.removeItem(at: backup) }
            throw error
        }
    }
}
