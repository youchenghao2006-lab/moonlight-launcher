import Foundation
import Darwin

private struct RuntimeFileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let changeSeconds: Int
    let changeNanoseconds: Int

    init?(_ file: URL) {
        var info = stat()
        guard stat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        changeSeconds = info.st_ctimespec.tv_sec
        changeNanoseconds = info.st_ctimespec.tv_nsec
    }
}

public struct InstallProgress: Sendable {
    public let fraction: Double
    public let message: String
    public init(_ fraction: Double, _ message: String) { self.fraction = fraction; self.message = message }
}

public struct LaunchPlan {
    public let executable: URL
    public let arguments: [String]
    public let directory: URL
}

public actor Installer {
    public let root: URL
    private var validatedRuntimes: [Int: (file: URL, stamps: [RuntimeFileStamp])] = [:]
    public init(root: URL) { self.root = root }
    public static let manifestURL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"

    public func manifest() async throws -> VersionManifest {
        let data = try await Network.data(Self.manifestURL)
        let manifest = try JSONDecoder().decode(VersionManifest.self, from: data)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("manifest-cache.json"), options: .atomic)
        return manifest
    }

    public func cachedManifest(maximumAge: TimeInterval? = nil) -> VersionManifest? {
        let file = root.appendingPathComponent("manifest-cache.json")
        if let maximumAge {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            let age = -modified.timeIntervalSinceNow
            guard age >= 0, age <= maximumAge else { return nil }
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(VersionManifest.self, from: data)
    }

    public func installed() -> [InstalledVersion] {
        let directory = root.appendingPathComponent("versions")
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> InstalledVersion? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("moonlight.json")),
                  let version = try? JSONDecoder().decode(InstalledVersion.self, from: data),
                  version.architecture == Platform.architecture else { return nil }
            return version
        }.sorted { $0.installedAt > $1.installedAt }
    }

    public func install(_ version: GameVersion, customJava: String = "", progress: @escaping @Sendable (InstallProgress) async -> Void) async throws -> InstalledVersion {
        guard version.supported else { throw LauncherError("目前支持 Minecraft 1.19 及之后的正式版。") }
        await progress(.init(0.01, "读取 \(version.id) 版本信息"))
        let dir = try Metadata.safePath("versions/\(version.id)", under: root)
        let jsonFile = dir.appendingPathComponent("\(version.id).json")
        guard let hash = version.sha1, hash.count == 40 else { throw LauncherError("官方版本信息缺少校验值。") }
        try await Network.download(version.url, to: jsonFile, hash: hash)
        let metadata = try Metadata.object(Data(contentsOf: jsonFile))
        let javaMajor = (metadata["javaVersion"] as? [String: Any])?["majorVersion"] as? Int ?? 17
        _ = try await java(major: javaMajor, custom: customJava, progress: progress)
        try Task.checkCancellation()
        guard let downloads = metadata["downloads"] as? [String: Any], let client = downloads["client"] as? [String: Any] else {
            throw LauncherError("该版本没有可下载的游戏客户端。")
        }
        await progress(.init(0.15, "下载游戏客户端"))
        try await artifact(client, to: dir.appendingPathComponent("\(version.id).jar"))
        let libs = Metadata.libraries(metadata)
        for (index, lib) in libs.enumerated() {
            try Task.checkCancellation()
            await progress(.init(0.25 + 0.20 * Double(index) / Double(max(1, libs.count)), "准备依赖 \(index + 1)/\(libs.count)"))
            if let downloads = lib["downloads"] as? [String: Any] {
                if let artifact = downloads["artifact"] as? [String: Any], let path = artifact["path"] as? String {
                    try await self.artifact(artifact, to: Metadata.safePath(path, under: root.appendingPathComponent("libraries")))
                }
                if let classifier = (lib["natives"] as? [String: String])?["osx"],
                   let native = (downloads["classifiers"] as? [String: [String: Any]])?[classifier],
                   let path = native["path"] as? String {
                    let file = try Metadata.safePath(path, under: root.appendingPathComponent("libraries"))
                    try await artifact(native, to: file)
                    let natives = dir.appendingPathComponent("natives")
                    try FileManager.default.createDirectory(at: natives, withIntermediateDirectories: true)
                    _ = try await Self.tool("/usr/bin/ditto", ["-x", "-k", file.path, natives.path])
                }
            }
        }
        if let logging = (metadata["logging"] as? [String: [String: Any]])?["client"],
           let file = logging["file"] as? [String: Any], let id = file["id"] as? String {
            try await artifact(file, to: Metadata.safePath(id, under: root.appendingPathComponent("assets/log_configs")))
        }
        guard let assetIndex = metadata["assetIndex"] as? [String: Any], let assetID = assetIndex["id"] as? String else {
            throw LauncherError("该版本缺少资源索引。")
        }
        let indexFile = try Metadata.safePath("assets/indexes/\(assetID).json", under: root)
        await progress(.init(0.46, "读取游戏资源索引"))
        try await artifact(assetIndex, to: indexFile)
        let assetData = try Metadata.object(Data(contentsOf: indexFile))
        let objects = assetData["objects"] as? [String: [String: Any]] ?? [:]
        let hashes = Array(Set(objects.values.compactMap { $0["hash"] as? String })).sorted()
        guard !hashes.isEmpty, hashes.allSatisfy({ $0.count == 40 && $0.allSatisfy(\.isHexDigit) }) else {
            throw LauncherError("资源索引无效。")
        }
        // Bounded groups keep resource downloads and memory use predictable.
        for start in stride(from: 0, to: hashes.count, by: 12) {
            try Task.checkCancellation()
            let batch = Array(hashes[start..<min(start + 12, hashes.count)])
            let assetsRoot = root.appendingPathComponent("assets/objects")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for hash in batch {
                    group.addTask {
                        let relative = "\(hash.prefix(2))/\(hash)"
                        try await Network.download("https://resources.download.minecraft.net/\(relative)", to: Metadata.safePath(relative, under: assetsRoot), hash: hash)
                    }
                }
                try await group.waitForAll()
            }
            await progress(.init(0.47 + 0.52 * Double(min(start + 12, hashes.count)) / Double(hashes.count), "下载并校验资源 \(min(start + 12, hashes.count))/\(hashes.count)"))
        }
        try Task.checkCancellation()
        let installed = InstalledVersion(id: version.id, javaMajor: javaMajor, architecture: Platform.architecture)
        // Only complete installs are listed; canceled files can be reused on retry.
        try JSONEncoder().encode(installed).write(to: dir.appendingPathComponent("moonlight.json"), options: .atomic)
        await progress(.init(1, "\(version.id) 已准备就绪"))
        return installed
    }

    func artifact(_ entry: [String: Any], to file: URL) async throws {
        guard let url = entry["url"] as? String, let sha = entry["sha1"] as? String, sha.count == 40 else {
            throw LauncherError("依赖文件缺少下载地址或校验信息。")
        }
        try await Network.download(url, to: file, hash: sha)
    }

    public func java(major: Int, custom: String, progress: @escaping @Sendable (InstallProgress) async -> Void) async throws -> URL {
        if !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let file = URL(fileURLWithPath: custom)
            try await validateJava(file, major: major)
            return file
        }
        let destination = root.appendingPathComponent("runtime/java-\(major)-\(Platform.architecture)")
        if let saved = validatedRuntimes[major],
           FileManager.default.isExecutableFile(atPath: saved.file.path),
           runtimeStamps(saved.file) == saved.stamps {
            return saved.file
        }
        validatedRuntimes.removeValue(forKey: major)
        if let file = findJava(destination), (try? await validateJava(file, major: major)) != nil {
            rememberRuntime(file, major: major)
            return file
        }
        try Task.checkCancellation()
        await progress(.init(0.04, "获取 Java \(major) · \(Platform.label)"))
        let arch = Platform.architecture == "arm64" ? "aarch64" : "x64"
        var package: [String: Any]?
        for kind in ["jre", "jdk"] {
            let data = try await Network.data("https://api.adoptium.net/v3/assets/latest/\(major)/hotspot?architecture=\(arch)&image_type=\(kind)&os=mac&vendor=eclipse")
            let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            package = ((list?.first?["binary"] as? [String: Any])?["package"] as? [String: Any])
            if package != nil { break }
        }
        guard let package, let link = package["link"] as? String, let checksum = package["checksum"] as? String, checksum.count == 64 else {
            throw LauncherError("暂时找不到 Java \(major)，请在设置中选择已安装的对应版本 Java。")
        }
        let archive = root.appendingPathComponent("runtime/java-\(major)-\(arch).tar.gz")
        await progress(.init(0.07, "下载 Java \(major)，首次准备可能需要几分钟"))
        try await Network.download(link, to: archive, hash: checksum, sha256: true)
        let staging = root.appendingPathComponent("runtime/staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        await progress(.init(0.12, "解压并检查 Java \(major)"))
        _ = try await Self.tool("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        guard let stagedJava = findJava(staging) else { throw LauncherError("下载的 Java 包中没有可执行文件。") }
        try await validateJava(stagedJava, major: major)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        try? FileManager.default.removeItem(at: archive)
        guard let file = findJava(destination) else { throw LauncherError("Java 安装失败。") }
        rememberRuntime(file, major: major)
        return file
    }

    func findJava(_ directory: URL) -> URL? {
        // Adoptium macOS archives normally contain one bundle with a standard Java home.
        // Check that layout first; old or unusual extractions still use the recursive lookup.
        let fm = FileManager.default
        let bundles = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for bundle in [directory] + bundles {
            let file = bundle.appendingPathComponent("Contents/Home/bin/java")
            if fm.isExecutableFile(atPath: file.path) { return file }
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in enumerator where file.lastPathComponent == "java" && file.deletingLastPathComponent().lastPathComponent == "bin" {
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }

    private func rememberRuntime(_ file: URL, major: Int) {
        if let stamps = runtimeStamps(file) { validatedRuntimes[major] = (file, stamps) }
    }

    // Only managed, already-probed runtimes are cached, for the life of the launcher.
    // Changes to the executable, VM, boot modules or runtime metadata require a new probe.
    private func runtimeStamps(_ executable: URL) -> [RuntimeFileStamp]? {
        let home = executable.deletingLastPathComponent().deletingLastPathComponent()
        var stamps = [RuntimeFileStamp]()
        for name in ["bin/java", "lib/libjli.dylib", "lib/server/libjvm.dylib", "lib/modules", "release"] {
            guard let stamp = RuntimeFileStamp(home.appendingPathComponent(name)) else { return nil }
            stamps.append(stamp)
        }
        return stamps
    }

    func validateJava(_ file: URL, major: Int) async throws {
        guard FileManager.default.isExecutableFile(atPath: file.path) else { throw LauncherError("所选路径不是可执行的 Java 文件，请选择 bin/java。") }
        let output = try await Self.tool(file.path, ["-XshowSettings:properties", "-version"])
        let lines = output.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.contains("java.specification.version = \(major)") }) else {
            throw LauncherError("这个游戏版本需要 Java \(major)。请清空自定义 Java 路径以自动安装。")
        }
        let expected = Platform.architecture == "arm64" ? "aarch64" : "x86_64"
        guard lines.contains(where: { $0.contains("os.arch = \(expected)") || (expected == "x86_64" && $0.contains("os.arch = amd64")) }) else {
            throw LauncherError("Java 架构不匹配，请使用 \(Platform.label) 对应的 Java。")
        }
    }

    public func launchPlan(_ installed: InstalledVersion, username: String, memoryMB: Int, demo: Bool, customJava: String = "", identity: OnlineIdentity? = nil, progress: @escaping @Sendable (InstallProgress) async -> Void) async throws -> LaunchPlan {
        let username = identity?.name ?? username
        let demo = identity == nil && demo
        guard username.range(of: identity == nil ? "^[A-Za-z0-9_]{3,16}$" : "^[A-Za-z0-9_]{1,16}$", options: .regularExpression) != nil else {
            throw LauncherError("游戏名称需要 3–16 位英文字母、数字或下划线。")
        }
        let dir = try Metadata.safePath("versions/\(installed.id)", under: root)
        let metadata = try Metadata.object(Data(contentsOf: dir.appendingPathComponent("\(installed.id).json")))
        var classpath: [String] = []
        for lib in Metadata.libraries(metadata) {
            if let artifact = (lib["downloads"] as? [String: Any])?["artifact"] as? [String: Any], let path = artifact["path"] as? String {
                let file = try Metadata.safePath(path, under: root.appendingPathComponent("libraries"))
                guard FileManager.default.fileExists(atPath: file.path) else { throw LauncherError("游戏依赖缺失，请在版本管理中点击「修复」。") }
                classpath.append(file.path)
            }
        }
        let jar = try Metadata.safePath("versions/\(installed.gameID)/\(installed.gameID).jar", under: root)
        guard FileManager.default.fileExists(atPath: jar.path) else { throw LauncherError("游戏文件缺失，请先修复版本。") }
        classpath.append(jar.path)
        let gameDirectory = try Metadata.safePath("instances/\(installed.id)", under: root)
        let natives = try Metadata.safePath("versions/\(installed.gameID)/natives", under: root)
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: natives, withIntermediateDirectories: true)
        let values = [
            "auth_player_name": username, "version_name": installed.id, "game_directory": gameDirectory.path,
            "assets_root": root.appendingPathComponent("assets").path,
            "assets_index_name": (metadata["assetIndex"] as? [String: Any])?["id"] as? String ?? "",
            "auth_uuid": identity?.uuid ?? Metadata.offlineUUID(username), "auth_access_token": identity?.accessToken ?? "0", "clientid": identity?.clientID ?? "", "auth_xuid": identity?.xuid ?? "",
            "user_type": identity == nil ? "legacy" : "msa", "version_type": "release", "natives_directory": natives.path,
            "launcher_name": "Moonlight", "launcher_version": "0.5.0", "classpath": classpath.joined(separator: ":"),
            "resolution_width": "1100", "resolution_height": "700", "user_properties": "{}",
            "library_directory": root.appendingPathComponent("libraries").path, "classpath_separator": ":"
        ]
        guard let arguments = metadata["arguments"] as? [String: [Any]], let jvm = arguments["jvm"], let game = arguments["game"], let mainClass = metadata["mainClass"] as? String else {
            throw LauncherError("暂不支持此版本的启动格式。")
        }
        var launchArgs = ["-Xms512M", "-Xmx\(max(1024, min(memoryMB, 32768)))M", "-Xdock:name=Minecraft · Moonlight"]
        // Forge's ignoreList must name the actual vanilla JAR, not the instance ID.
        var jvmValues = values
        jvmValues["version_name"] = installed.gameID
        launchArgs += try Metadata.arguments(jvm, values: jvmValues, demo: demo)
        if let logging = (metadata["logging"] as? [String: [String: Any]])?["client"], let arg = logging["argument"] as? String,
           let id = (logging["file"] as? [String: Any])?["id"] as? String {
            let path = try Metadata.safePath(id, under: root.appendingPathComponent("assets/log_configs"))
            launchArgs.append(arg.replacingOccurrences(of: "${path}", with: path.path))
        }
        launchArgs.append(mainClass)
        launchArgs += try Metadata.arguments(game, values: values, demo: demo)
        return try await LaunchPlan(executable: java(major: installed.javaMajor, custom: customJava, progress: progress), arguments: launchArgs, directory: gameDirectory)
    }

    public static func tool(_ path: String, _ arguments: [String], directory: URL? = nil) async throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("moonlight-tool-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = handle; process.standardError = handle
        let status: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try Task.checkCancellation(); try process.run() }
                catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { if process.isRunning { process.terminate() } })
        try Task.checkCancellation()
        let output = (try? String(contentsOf: temporary, encoding: .utf8)) ?? ""
        guard status == 0 else { throw LauncherError("执行失败（\(status)）：\(output.suffix(1800))") }
        return output
    }
}
