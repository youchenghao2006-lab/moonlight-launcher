import Foundation
import CArchive

public struct ModRelease: Codable, Identifiable, Sendable {
    public struct File: Codable, Sendable {
        public let filename: String
        public let url: String
        public let primary: Bool
        public let hashes: [String: String]
        public let size: Int
    }
    public struct Dependency: Codable, Sendable {
        public let version_id: String?
        public let project_id: String?
        public let file_name: String?
        public let dependency_type: String
    }
    public let id: String
    public let project_id: String
    public let name: String
    public let version_number: String
    public let version_type: String
    public let game_versions: [String]
    public let loaders: [String]
    public let dependencies: [Dependency]
    public let files: [File]

    public func supports(_ target: InstalledVersion) -> Bool {
        ["forge", "fabric"].contains(target.loader ?? "") && game_versions.contains(target.gameID) && loaders.contains(target.loader ?? "")
    }
    public func artifact() throws -> File {
        guard let file = files.first(where: { $0.primary && $0.filename.lowercased().hasSuffix(".jar") }) ?? files.first(where: { $0.filename.lowercased().hasSuffix(".jar") }) else { throw LauncherError("这个版本没有可安装的 JAR 文件。") }
        guard file.filename == URL(fileURLWithPath: file.filename).lastPathComponent,
              !file.filename.contains("/"), !file.filename.contains("\\"), !file.filename.contains(":"),
              file.size > 0, file.size <= 200_000_000,
              let hash = file.hashes["sha512"], hash.count == 128, hash.allSatisfy(\.isHexDigit),
              let url = URL(string: file.url), url.scheme == "https", url.host == "cdn.modrinth.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw LauncherError("模组文件来源、文件名或校验信息无效。") }
        _ = try Metadata.safePath(file.filename, under: URL(fileURLWithPath: "/tmp/mod-files"))
        return file
    }
}

public enum ModCatalog {
    private static func validID(_ id: String) throws {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw LauncherError("模组项目编号无效。") }
    }
    public static func search(_ query: String, target: InstalledVersion) async throws -> [PackProject] {
        guard ["forge", "fabric"].contains(target.loader ?? "") else { throw LauncherError("请先选择已安装 Forge 或 Fabric 的游戏实例。") }
        let facets = [["project_type:mod"], ["versions:" + target.gameID], ["categories:" + (target.loader ?? "")]]
        let value = String(decoding: try JSONSerialization.data(withJSONObject: facets), as: UTF8.self)
        let address = try PackCatalog.endpoint("search", [.init(name: "query", value: query), .init(name: "facets", value: value), .init(name: "limit", value: "30"), .init(name: "index", value: query.isEmpty ? "downloads" : "relevance")])
        struct Response: Decodable { let hits: [PackProject] }
        return try JSONDecoder().decode(Response.self, from: await Network.data(address)).hits
    }
    public static func releases(_ project: String, target: InstalledVersion) async throws -> [ModRelease] {
        try validID(project)
        let games = String(decoding: try JSONEncoder().encode([target.gameID]), as: UTF8.self)
        let loaders = String(decoding: try JSONEncoder().encode([target.loader ?? ""]), as: UTF8.self)
        let address = try PackCatalog.endpoint("project/\(project)/version", [.init(name: "game_versions", value: games), .init(name: "loaders", value: loaders)])
        return try JSONDecoder().decode([ModRelease].self, from: await Network.data(address)).filter { $0.supports(target) }
    }
    public static func release(_ id: String) async throws -> ModRelease {
        try validID(id)
        return try JSONDecoder().decode(ModRelease.self, from: await Network.data(PackCatalog.endpoint("version/\(id)")))
    }
}

public struct ModInstallPlan: Sendable {
    public let target: InstalledVersion
    public let releases: [ModRelease]
    public var byteCount: Int { releases.reduce(0) { $0 + ((try? $1.artifact().size) ?? 0) } }
}

public enum ModResolver {
    public static func plan(_ release: ModRelease, target: InstalledVersion,
                            version: @escaping (String) async throws -> ModRelease = { try await ModCatalog.release($0) },
                            projects: @escaping (String, InstalledVersion) async throws -> [ModRelease] = { try await ModCatalog.releases($0, target: $1) }) async throws -> ModInstallPlan {
        var chosen: [String: ModRelease] = [:]
        var visiting = Set<String>(), finished = Set<String>()
        var ordered: [ModRelease] = []
        func visit(_ item: ModRelease) async throws {
            try Task.checkCancellation()
            guard item.supports(target) else { throw LauncherError("\(item.name) 不适用于 Minecraft \(target.gameID) / \(target.loaderLabel)。") }
            _ = try item.artifact()
            if let previous = chosen[item.project_id], previous.id != item.id { throw LauncherError("两个模组需要不同版本的同一依赖：\(item.name)。请改选版本。") }
            if finished.contains(item.project_id) { return }
            guard visiting.insert(item.project_id).inserted else { throw LauncherError("模组存在循环依赖，无法自动安装。") }
            guard chosen.count < 64 else { throw LauncherError("依赖数量过多，请分批安装。") }
            chosen[item.project_id] = item
            for dependency in item.dependencies where dependency.dependency_type == "required" {
                let child: ModRelease
                if let id = dependency.version_id { child = try await version(id) }
                else if let project = dependency.project_id {
                    if let existing = chosen[project] { child = existing }
                    else {
                        let candidates = try await projects(project, target).filter { $0.supports(target) }
                        guard let selected = candidates.first(where: { $0.version_type == "release" }) ?? candidates.first else { throw LauncherError("找不到适用于当前游戏的必需依赖：\(project)。") }
                        child = selected
                    }
                } else { throw LauncherError("依赖 \(dependency.file_name ?? "未知文件") 没有下载项目，需手动安装。") }
                if let project = dependency.project_id, child.project_id != project { throw LauncherError("依赖项目与指定版本不匹配。") }
                try await visit(child)
            }
            visiting.remove(item.project_id); finished.insert(item.project_id); ordered.append(item)
        }
        try await visit(release)
        for item in ordered {
            for dependency in item.dependencies where dependency.dependency_type == "incompatible" {
                if let id = dependency.version_id, ordered.contains(where: { $0.id == id }) { throw LauncherError("安装内容含不兼容的依赖版本。") }
                if dependency.version_id == nil, let project = dependency.project_id, chosen[project] != nil { throw LauncherError("安装内容含互不兼容的模组。") }
            }
        }
        return ModInstallPlan(target: target, releases: ordered)
    }
}

public struct LocalMod: Identifiable, Sendable {
    public let filename: String
    public let title: String
    public let version: String
    public let modIDs: Set<String>
    public let enabled: Bool
    public var id: String { filename }
}

public enum ModJar {
    // Read only the loader descriptors. No archive entries are extracted to disk.
    private static func descriptor(_ archive: OpaquePointer) throws -> Data {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
            if count == 0 { return bytes }
            guard count > 0, bytes.count + count <= 1_048_576 else {
                throw LauncherError("模组描述文件无效或过大。")
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    public static func inspect(_ file: URL) throws -> (title: String, version: String, ids: Set<String>) {
        guard let archive = archive_read_new() else { throw LauncherError("无法读取模组文件。") }
        defer { archive_read_free(archive) }
        guard archive_read_support_format_zip_seekable(archive) == ARCHIVE_OK,
              archive_read_open_filename(archive, file.path, 64 * 1024) == ARCHIVE_OK else {
            throw LauncherError("无法打开模组文件。")
        }
        var entry: OpaquePointer?
        var forge: Data?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK else { throw LauncherError("模组文件目录无效。") }
            guard let path = archive_entry_pathname(entry) else { continue }
            if strcmp(path, "fabric.mod.json") == 0 {
                if let data = try? descriptor(archive),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let id = object["id"] as? String {
                    return (object["name"] as? String ?? id, object["version"] as? String ?? "", [id])
                }
            } else if forge == nil, strcmp(path, "META-INF/mods.toml") == 0 {
                forge = try descriptor(archive)
            }
        }
        guard let forge else { throw LauncherError("没有找到模组描述。") }
        let metadata = String(decoding: forge, as: UTF8.self)
        func field(_ key: String, in block: String) -> String? {
            let regex = try! NSRegularExpression(pattern: #"(?m)^\s*"# + key + #"\s*=\s*(?:"((?:\\.|[^"\\\r\n])*)"|'([^'\r\n]*)')"#)
            guard let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)) else { return nil }
            if let range = Range(match.range(at: 1), in: block) {
                let value = String(block[range])
                return (try? JSONDecoder().decode(String.self, from: Data(("\"" + value + "\"").utf8))) ?? value
            }
            return Range(match.range(at: 2), in: block).map { String(block[$0]) }
        }
        let blocks = metadata.components(separatedBy: "[[mods]]").dropFirst().map { $0.components(separatedBy: "[[")[0] }
        let ids = Set(blocks.compactMap { field("modId", in: $0) })
        guard let first = blocks.first, !ids.isEmpty else { throw LauncherError("无法识别模组身份。") }
        let version = field("version", in: first) ?? ""
        let title = field("displayName", in: first) ?? ids.sorted().joined(separator: ", ")
        return (title.contains("\u{FFFD}") ? ids.sorted().joined(separator: ", ") : title, version.contains("${") ? "" : version, ids)
    }
}

public actor ModManager {
    public let root: URL
    private var mutating = false
    private var cache: [String: (stamp: String, mod: LocalMod)] = [:]
    public init(root: URL) { self.root = root }

    private func path(_ relative: String) throws -> URL {
        let url = try Metadata.safePath(relative, under: root)
        var current = root
        for part in relative.split(separator: "/") {
            current.appendPathComponent(String(part))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LauncherError("模组目录含符号链接，无法修改。") }
        }
        return url
    }
    private func directory(_ target: InstalledVersion) throws -> URL {
        guard let data = try? Data(contentsOf: path("versions/\(target.id)/moonlight.json")),
              let installed = try? JSONDecoder().decode(InstalledVersion.self, from: data),
              installed.id == target.id, installed.architecture == target.architecture,
              installed.gameID == target.gameID, installed.loader == target.loader,
              installed.loaderVersion == target.loaderVersion else { throw LauncherError("游戏实例已变化，请重新选择。") }
        return try path("instances/\(target.id)/mods")
    }
    public func localMods(_ target: InstalledVersion) throws -> [LocalMod] {
        let dir = try directory(target)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        var result: [LocalMod] = []
        for file in files where file.lastPathComponent.lowercased().hasSuffix(".jar") || file.lastPathComponent.lowercased().hasSuffix(".jar.disabled") {
            try Task.checkCancellation()
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            let stamp = "\(attributes.fileSize ?? 0):\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if let saved = cache[file.path], saved.stamp == stamp { result.append(saved.mod); continue }
            let info = try? ModJar.inspect(file)
            let item = LocalMod(filename: file.lastPathComponent, title: info?.title ?? file.lastPathComponent, version: info?.version ?? "", modIDs: info?.ids ?? [], enabled: !file.lastPathComponent.lowercased().hasSuffix(".disabled"))
            cache[file.path] = (stamp, item); result.append(item)
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func localFile(_ mod: LocalMod, target: InstalledVersion) throws -> URL {
        let dir = try directory(target)
        guard mod.filename == URL(fileURLWithPath: mod.filename).lastPathComponent, mod.filename.lowercased().hasSuffix(mod.enabled ? ".jar" : ".jar.disabled") else { throw LauncherError("模组文件名无效。") }
        let file = try path("instances/\(target.id)/mods/\(mod.filename)")
        guard file.standardizedFileURL == dir.appendingPathComponent(mod.filename).standardizedFileURL else { throw LauncherError("模组路径无效。") }
        return file
    }
    public func setEnabled(_ mod: LocalMod, target: InstalledVersion, enabled: Bool) throws {
        guard !mutating else { throw LauncherError("请等待当前模组操作完成。") }
        guard enabled != mod.enabled else { return }
        let source = try localFile(mod, target: target)
        let name = enabled ? String(mod.filename.dropLast(".disabled".count)) : mod.filename + ".disabled"
        let destination = try path("instances/\(target.id)/mods/\(name)")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LauncherError("已存在同名模组，未覆盖。") }
        try FileManager.default.moveItem(at: source, to: destination)
        cache.removeValue(forKey: source.path)
        cache.removeValue(forKey: destination.path)
    }
    public func remove(_ mod: LocalMod, target: InstalledVersion) throws -> URL {
        guard !mutating else { throw LauncherError("请等待当前模组操作完成。") }
        let source = try localFile(mod, target: target)
        let backup = try path("backups/mods/\(target.id)/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: backup.appendingPathComponent(mod.filename))
        cache.removeValue(forKey: source.path)
        return backup
    }
    public func install(_ plan: ModInstallPlan,
                        download: @escaping @Sendable (ModRelease.File, URL) async throws -> Void = { file, destination in try await Network.download(file.url, to: destination, hash: file.hashes["sha512"]!.lowercased(), sha512: true) },
                        progress: @escaping @Sendable (InstallProgress) async -> Void) async throws {
        guard !mutating else { throw LauncherError("请等待当前模组操作完成。") }
        mutating = true; defer { mutating = false; cache.removeAll() }
        let dir = try directory(plan.target)
        let staging = try path("staging/mods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var incoming: [(file: URL, ids: Set<String>)] = [], ids = Set<String>(), names = Set<String>()
        for (index, release) in plan.releases.enumerated() {
            try Task.checkCancellation()
            guard release.supports(plan.target) else { throw LauncherError("模组与游戏版本不匹配。") }
            let file = try release.artifact()
            guard names.insert(file.filename.lowercased()).inserted else { throw LauncherError("模组文件名冲突。") }
            let destination = try Metadata.safePath(file.filename, under: staging)
            await progress(.init(Double(index) / Double(max(1, plan.releases.count)) * 0.85, "下载并校验 \(release.name)"))
            try await download(file, destination)
            guard try Metadata.digest(destination, sha512: true) == file.hashes["sha512"]!.lowercased(),
                  (try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize == file.size else { throw LauncherError("模组文件校验失败。") }
            let info = try ModJar.inspect(destination)
            guard ids.isDisjoint(with: info.ids) else { throw LauncherError("安装内容包含重复的模组身份。") }
            ids.formUnion(info.ids); incoming.append((destination, info.ids))
        }
        guard !incoming.isEmpty else { throw LauncherError("没有可安装的模组。") }
        let locals = try localMods(plan.target)
        let replacing = locals.filter { !$0.modIDs.isDisjoint(with: ids) }
        let replacingNames = Set(replacing.map { $0.filename.lowercased() })
        for item in incoming where FileManager.default.fileExists(atPath: dir.appendingPathComponent(item.file.lastPathComponent).path) {
            guard replacingNames.contains(item.file.lastPathComponent.lowercased()) else { throw LauncherError("存在无法识别的同名文件，未覆盖。") }
        }
        let backup = try path("backups/mods/\(plan.target.id)/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var moved: [String] = [], added: [URL] = []
        do {
            try Task.checkCancellation()
            await progress(.init(0.9, "安装模组并备份原有版本"))
            for item in replacing {
                let source = try localFile(item, target: plan.target)
                try FileManager.default.moveItem(at: source, to: backup.appendingPathComponent(item.filename)); moved.append(item.filename)
            }
            for item in incoming {
                try Task.checkCancellation()
                let destination = try path("instances/\(plan.target.id)/mods/\(item.file.lastPathComponent)")
                try FileManager.default.moveItem(at: item.file, to: destination); added.append(destination)
            }
        } catch {
            var rollbackFailed = false
            for file in added { do { try FileManager.default.removeItem(at: file) } catch { rollbackFailed = true } }
            for name in moved { do { try FileManager.default.moveItem(at: backup.appendingPathComponent(name), to: dir.appendingPathComponent(name)) } catch { rollbackFailed = true } }
            if rollbackFailed { throw LauncherError("安装未完成，自动恢复失败；原模组备份保留在 \(backup.path)。") }
            throw error
        }
        await progress(.init(1, "已安装 \(incoming.count) 个模组，下次启动游戏时生效"))
    }
}
