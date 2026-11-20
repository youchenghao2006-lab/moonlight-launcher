import Foundation

public struct PackIndex: Decodable {
    public struct File: Decodable {
        public let path: String
        public let hashes: [String: String]
        public let downloads: [String]
        public let env: [String: String]?
    }
    public let formatVersion: Int
    public let game: String
    public let name: String
    public let versionId: String
    public let dependencies: [String: String]
    public let files: [File]

    public func validate() throws {
        guard formatVersion == 1, game == "minecraft", dependencies["minecraft"] != nil else { throw LauncherError("整合包格式或游戏类型暂不支持。") }
        let supported = Set(["minecraft", "forge", "fabric-loader"])
        guard Set(dependencies.keys).isSubset(of: supported), !(dependencies["forge"] != nil && dependencies["fabric-loader"] != nil) else { throw LauncherError("目前支持原版、Forge 和 Fabric 整合包；此包需要其他加载器。") }
        guard files.count < 50_000 else { throw LauncherError("整合包文件数量过多。") }
        var paths = Set<String>()
        for file in files {
            let path = try Metadata.safePath(file.path, under: URL(fileURLWithPath: "/private/tmp/pack-files")).path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(path).inserted, !file.path.hasSuffix("/"), let hash = file.hashes["sha512"], hash.count == 128, hash.allSatisfy(\.isHexDigit), !file.downloads.isEmpty else { throw LauncherError("整合包文件路径重复或缺少 SHA512 校验信息。") }
            if let env = file.env, !env.values.allSatisfy({ ["required", "optional", "unsupported"].contains($0) }) { throw LauncherError("整合包环境声明无效。") }
            for url in file.downloads { try Self.validateDownload(url) }
        }
    }
    public static func validateDownload(_ address: String) throws {
        let allowed = ["cdn.modrinth.com", "github.com", "raw.githubusercontent.com", "gitlab.com", "mediafilez.forgecdn.net", "edge.forgecdn.net", "media.forgecdn.net"]
        guard let url = URL(string: address), url.scheme == "https", let host = url.host?.lowercased(), allowed.contains(host), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw LauncherError("整合包包含不支持的下载来源：\(URL(string: address)?.host ?? "无效地址")") }
    }
}

extension Installer {
    public func installPack(_ release: PackRelease, optionalFiles: Bool = true, customJava: String = "", progress: @escaping @Sendable (InstallProgress) async -> Void) async throws -> InstalledVersion {
        guard release.supported, let file = release.files.first(where: { $0.primary && $0.filename.hasSuffix(".mrpack") }) ?? release.files.first(where: { $0.filename.hasSuffix(".mrpack") }), let hash = file.hashes["sha512"], hash.count == 128, hash.allSatisfy(\.isHexDigit) else { throw LauncherError("这个整合包版本暂不支持，或缺少校验信息。") }
        try PackIndex.validateDownload(file.url)
        let archive = root.appendingPathComponent("downloads/packs/\(hash.prefix(24)).mrpack")
        await progress(.init(0, "下载整合包：\(release.name)"))
        try await Network.download(file.url, to: archive, hash: hash, sha512: true)
        return try await importPack(archive, optionalFiles: optionalFiles, customJava: customJava, progress: progress)
    }

    public func importPack(_ archive: URL, optionalFiles: Bool = true, customJava: String = "", progress: @escaping @Sendable (InstallProgress) async -> Void) async throws -> InstalledVersion {
        await progress(.init(0.01, "检查并解压整合包"))
        try Task.checkCancellation()
        let hash = try Metadata.digest(archive, sha512: true)
        let id = "pack-\(hash.prefix(20))\(optionalFiles ? "" : "-required")"
        if let existing = installed().first(where: { $0.id == id }) { await progress(.init(1, "整合包已安装")); return existing }
        let staging = root.appendingPathComponent("staging/pack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let unpacked = staging.appendingPathComponent("archive"), client = staging.appendingPathComponent("client")
        try await PackArchive.extract(archive, to: unpacked)
        let index: PackIndex
        if FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("modrinth.index.json").path) {
            index = try JSONDecoder().decode(PackIndex.self, from: Data(contentsOf: unpacked.appendingPathComponent("modrinth.index.json")))
        } else {
            throw LauncherError("未找到 modrinth.index.json。请选择 .mrpack 或 Modrinth 格式 ZIP；暂不支持 CurseForge 清单包、EXE 安装器或普通备份 ZIP。")
        }
        try index.validate()
        await progress(.init(0.04, "准备 \(index.name) \(index.versionId) 的游戏环境"))
        let catalog: VersionManifest
        if let cache = cachedManifest() { catalog = cache } else { catalog = try await manifest() }
        guard let version = catalog.versions.first(where: { $0.id == index.dependencies["minecraft"] }), version.supported else { throw LauncherError("此整合包需要暂不支持的 Minecraft 版本。当前支持 1.19 及之后的正式版。") }
        let base: InstalledVersion
        let report: @Sendable (InstallProgress) async -> Void = { await progress(.init(0.04 + $0.fraction * 0.40, $0.message)) }
        if let forge = index.dependencies["forge"] { base = try await installLoader(version, loader: "forge", build: forge, customJava: customJava, progress: report) }
        else if let fabric = index.dependencies["fabric-loader"] { base = try await installLoader(version, loader: "fabric", build: fabric, customJava: customJava, progress: report) }
        else { base = try await install(version, customJava: customJava, progress: report) }
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        let files = index.files.filter { $0.env?["client"] != "unsupported" && (optionalFiles || $0.env?["client"] != "optional") }
        let cache = root.appendingPathComponent("downloads/pack-files")
        for offset in stride(from: 0, to: files.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(files[offset..<min(offset + 8, files.count)])
            try await withThrowingTaskGroup(of: Void.self) { group in
                for file in batch {
                    group.addTask {
                        let digest = file.hashes["sha512"]!.lowercased()
                        let saved = cache.appendingPathComponent(digest)
                        // Prefer Modrinth's CDN when the archive also provides CurseForge mirrors.
                        let urls = file.downloads.sorted { $0.contains("cdn.modrinth.com/") && !$1.contains("cdn.modrinth.com/") }
                        var failure: Error = LauncherError("无法下载 \(file.path)")
                        var success = false
                        for url in urls {
                            do { try await Network.download(url, to: saved, hash: digest, sha512: true); success = true; break }
                            catch { if Task.isCancelled { throw CancellationError() }; failure = error }
                        }
                        guard success else { throw LauncherError("无法下载 \(file.path)：\(failure.localizedDescription)") }
                        let destination = try Metadata.safePath(file.path, under: client)
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: saved, to: destination)
                    }
                }
                try await group.waitForAll()
            }
            let done = min(offset + 8, files.count)
            await progress(.init(0.44 + 0.50 * Double(done) / Double(max(1, files.count)), "下载并校验模组 \(done) / \(files.count)"))
        }
        await progress(.init(0.96, "整理模组和整合包配置"))
        try Self.overlay(unpacked.appendingPathComponent("overrides"), to: client)
        try Self.overlay(unpacked.appendingPathComponent("client-overrides"), to: client)
        try Task.checkCancellation()
        var metadata = try Metadata.object(Data(contentsOf: Metadata.safePath("versions/\(base.id)/\(base.id).json", under: root)))
        metadata["id"] = id
        let record = InstalledVersion(id: id, javaMajor: base.javaMajor, architecture: Platform.architecture, baseID: base.gameID, loader: base.loader, loaderVersion: base.loaderVersion, displayName: "\(index.name) \(index.versionId)")
        let destination = try Metadata.safePath("instances/\(id)", under: root)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LauncherError("此整合包目录已存在但安装未完成，请先将它移走再导入，以保护已有存档。") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: client, to: destination)
        do { try saveProfile(record, metadata: metadata) }
        catch { try? FileManager.default.moveItem(at: destination, to: client); throw error }
        await progress(.init(1, "\(record.title) 已安装，可在首页启动"))
        return record
    }

    static func overlay(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw LauncherError("无法读取整合包配置。") }
        for case let item as URL in entries {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LauncherError("整合包包含符号链接。") }
            let relative = String(item.path.dropFirst(source.path.count + 1))
            let target = try Metadata.safePath(relative, under: destination)
            if values.isDirectory == true { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }
}
