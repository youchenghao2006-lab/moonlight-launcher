import Foundation

public struct LoaderBuild: Identifiable, Hashable {
    public var id: String { version }
    public let version: String
    public let recommended: Bool
    public init(_ version: String, recommended: Bool = false) { self.version = version; self.recommended = recommended }
}

extension Metadata {
    public static func mavenPath(_ name: String) throws -> String {
        let split = name.split(separator: "@", maxSplits: 1).map(String.init)
        let parts = split[0].split(separator: ":").map(String.init)
        guard (3...4).contains(parts.count) else { throw LauncherError("模组加载器的依赖名称无效。") }
        let ext = split.count == 2 ? split[1] : "jar"
        return "\(parts[0].replacingOccurrences(of: ".", with: "/"))/\(parts[1])/\(parts[2])/\(parts[1])-\(parts[2])\(parts.count == 4 ? "-" + parts[3] : "").\(ext)"
    }

    public static func merge(parent: [String: Any], child: [String: Any]) -> [String: Any] {
        var result = parent
        for (key, value) in child where key != "libraries" && key != "arguments" { result[key] = value }
        func key(_ lib: [String: Any]) -> String {
            let parts = (lib["name"] as? String ?? "").split(separator: ":").map(String.init)
            return parts.count >= 3 ? parts[0] + ":" + parts[1] + (parts.count > 3 ? ":" + parts[3] : "") : parts.joined(separator: ":")
        }
        let childLibs = child["libraries"] as? [[String: Any]] ?? []
        let replacements = Set(childLibs.map(key))
        result["libraries"] = (parent["libraries"] as? [[String: Any]] ?? []).filter { !replacements.contains(key($0)) } + childLibs
        var args = parent["arguments"] as? [String: [Any]] ?? [:]
        for (name, values) in child["arguments"] as? [String: [Any]] ?? [:] { args[name] = (args[name] ?? []) + values }
        result["arguments"] = args
        result.removeValue(forKey: "inheritsFrom")
        return result
    }
}

extension Installer {
    public func loaderBuilds(game: String, loader: String) async throws -> [LoaderBuild] {
        guard game.range(of: "^[0-9.]+$", options: .regularExpression) != nil else { throw LauncherError("游戏版本无效。") }
        if loader == "fabric" {
            let data = try await Network.data("https://meta.fabricmc.net/v2/versions/loader/\(game)")
            let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            return Array(list.compactMap { item -> LoaderBuild? in
                guard let info = item["loader"] as? [String: Any], let version = info["version"] as? String, info["stable"] as? Bool == true else { return nil }
                return LoaderBuild(version)
            }.prefix(30))
        }
        guard loader == "forge" else { throw LauncherError("暂不支持这个模组加载器。") }
        let json = try Metadata.object(await Network.data("https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"))
        let promos = json["promos"] as? [String: String] ?? [:]
        var builds: [LoaderBuild] = []
        if let recommended = promos[game + "-recommended"] { builds.append(LoaderBuild(recommended, recommended: true)) }
        if let latest = promos[game + "-latest"], !builds.contains(where: { $0.version == latest }) { builds.append(LoaderBuild(latest)) }
        return builds
    }

    public func installLoader(_ version: GameVersion, loader: String, build: String, customJava: String = "", repair: Bool = false, progress: @escaping @Sendable (InstallProgress) async -> Void) async throws -> InstalledVersion {
        guard ["fabric", "forge"].contains(loader), build.range(of: "^[A-Za-z0-9.+_-]+$", options: .regularExpression) != nil else { throw LauncherError("模组加载器版本无效。") }
        let base: InstalledVersion
        if !repair, let existing = installed().first(where: { $0.id == version.id }) { base = existing }
        else { base = try await install(version, customJava: customJava) { await progress(.init($0.fraction * 0.72, $0.message)) } }
        let id = "\(version.id)-\(loader)-\(build)"
        if !repair, let existing = installed().first(where: { $0.id == id }) { return existing }
        await progress(.init(0.74, "安装 \(loader.capitalized) \(build)"))
        let parentFile = try Metadata.safePath("versions/\(version.id)/\(version.id).json", under: root)
        let parent = try Metadata.object(Data(contentsOf: parentFile))
        let child: [String: Any]
        if loader == "fabric" {
            child = try Metadata.object(await Network.data("https://meta.fabricmc.net/v2/versions/loader/\(version.id)/\(build)/profile/json"))
        } else {
            let name = "forge-\(version.id)-\(build)-installer.jar"
            let address = "https://maven.minecraftforge.net/net/minecraftforge/forge/\(version.id)-\(build)/\(name)"
            let sha = String(decoding: try await Network.data(address + ".sha1"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count == 40 && sha.allSatisfy(\.isHexDigit) else { throw LauncherError("Forge 安装器的校验信息无效。") }
            let file = try Metadata.safePath("downloads/\(name)", under: root)
            try await Network.download(address, to: file, hash: sha)
            let javaFile = try await java(major: base.javaMajor, custom: customJava, progress: progress)
            let profiles = root.appendingPathComponent("launcher_profiles.json")
            if !FileManager.default.fileExists(atPath: profiles.path) { try Data("{\"profiles\":{}}".utf8).write(to: profiles, options: .atomic) }
            await progress(.init(0.80, "Forge 正在处理游戏依赖，可能需要几分钟"))
            let output: String
            do { output = try await Self.tool(javaFile.path, ["-Djava.awt.headless=true", "-jar", file.path, "--installClient", root.path], directory: root) }
            catch {
                if error is CancellationError { throw error }
                throw LauncherError("Forge 安装失败，可重试。\n\(error.localizedDescription)")
            }
            try output.write(to: root.appendingPathComponent("downloads/forge-install.log"), atomically: true, encoding: .utf8)
            let officialID = "\(version.id)-forge-\(build)"
            child = try Metadata.object(Data(contentsOf: Metadata.safePath("versions/\(officialID)/\(officialID).json", under: root)))
        }
        var merged = Metadata.merge(parent: parent, child: child)
        var all = merged["libraries"] as? [[String: Any]] ?? []
        for index in all.indices {
            if (all[index]["downloads"] as? [String: Any])?["artifact"] != nil { continue }
            guard let name = all[index]["name"] as? String else { throw LauncherError("加载器依赖缺少名称。") }
            let path = try Metadata.mavenPath(name)
            let file = try Metadata.safePath(path, under: root.appendingPathComponent("libraries"))
            let baseURL = all[index]["url"] as? String ?? "https://libraries.minecraft.net/"
            let address = (baseURL.hasSuffix("/") ? baseURL : baseURL + "/") + path
            let sha: String
            if FileManager.default.fileExists(atPath: file.path), loader == "forge" {
                // The official Forge installer has already verified its produced libraries.
                sha = try Metadata.digest(file)
            } else {
                sha = String(decoding: try await Network.data(address + ".sha1"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard sha.count == 40 && sha.allSatisfy(\.isHexDigit) else { throw LauncherError("加载器依赖缺少有效校验信息。") }
                try await Network.download(address, to: file, hash: sha)
            }
            all[index]["downloads"] = ["artifact": ["path": path, "url": address, "sha1": sha]]
        }
        merged["libraries"] = all; merged["id"] = id
        for lib in Metadata.libraries(merged) {
            guard let artifact = (lib["downloads"] as? [String: Any])?["artifact"] as? [String: Any], let path = artifact["path"] as? String else { continue }
            let file = try Metadata.safePath(path, under: root.appendingPathComponent("libraries"))
            if repair || !FileManager.default.fileExists(atPath: file.path) { try await self.artifact(artifact, to: file) }
        }
        try Task.checkCancellation()
        let record = InstalledVersion(id: id, javaMajor: base.javaMajor, architecture: Platform.architecture, baseID: version.id, loader: loader, loaderVersion: build)
        try saveProfile(record, metadata: merged)
        await progress(.init(1, "\(loader.capitalized) \(build) 已安装"))
        return record
    }

    public func repairEnvironment(_ record: InstalledVersion, customJava: String = "", progress: @escaping @Sendable (InstallProgress) async -> Void) async throws -> InstalledVersion {
        let catalog = try await manifest()
        guard let game = catalog.versions.first(where: { $0.id == record.gameID }) else { throw LauncherError("未找到该游戏的官方版本信息。") }
        let base: InstalledVersion
        if let loader = record.loader, let build = record.loaderVersion {
            base = try await installLoader(game, loader: loader, build: build, customJava: customJava, repair: true, progress: progress)
        } else { base = try await install(game, customJava: customJava, progress: progress) }
        if record.displayName != nil {
            var metadata = try Metadata.object(Data(contentsOf: Metadata.safePath("versions/\(base.id)/\(base.id).json", under: root)))
            metadata["id"] = record.id
            try saveProfile(record, metadata: metadata)
            return record
        }
        return base
    }

    func saveProfile(_ record: InstalledVersion, metadata: [String: Any]) throws {
        let dir = try Metadata.safePath("versions/\(record.id)", under: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: dir.appendingPathComponent("\(record.id).json"), options: .atomic)
        try JSONEncoder().encode(record).write(to: dir.appendingPathComponent("moonlight.json"), options: .atomic)
    }
}
