import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MoonlightCore

struct Preferences: Codable {
    var username = "Player"
    var memory = 4096
    var demo = false
    var customJava = ""
    var selected = ""
    var mode: String?
    var onlineAccount: String?
    var microsoftClientID: String?
    var authenticationMode: String { mode ?? (demo ? "demo" : "offline") }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var page = "启动"
    @Published var versions: [GameVersion] = []
    @Published var installed: [InstalledVersion] = []
    @Published var preferences = Preferences() { didSet { save() } }
    @Published var busy = false
    @Published var refreshing = false
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = "准备好，开启新的冒险。"
    @Published var catalogStatus = "正在连接官方版本目录…"
    @Published var errorMessage: String?
    @Published var search = ""
    @Published var logs = "Moonlight 0.5.0 · macOS · \(Platform.label)\n"
    @Published var latest = ""
    @Published var accounts: [AccountSummary] = []
    @Published var authenticating = false
    @Published var loginSheet = false
    @Published var configurationSheet = false
    @Published var modRevision = 0
    @Published var lastVersionRemoval: VersionRemovalResult?
    @Published var loginChallenge: DeviceAuthorization?
    @Published var loginStatus = ""
    @Published var loginError: String?
    let authentication = MicrosoftAuthentication()
    let vault = CredentialVault()
    private var authTask: Task<Void, Never>?
    private var loginGeneration: UUID?
    let root: URL
    let installer: Installer
    let modManager: ModManager
    var task: Task<Void, Never>?
    private var game: Process?
    private var logCapture: GameLogCapture?
    private var logReader: FileHandle?
    private var logTimer: Timer?

    var selected: InstalledVersion? { installed.first { $0.id == preferences.selected } ?? installed.first }
    var filteredVersions: [GameVersion] {
        search.isEmpty ? versions : versions.filter { $0.id.localizedCaseInsensitiveContains(search) }
    }
    var activeAccount: AccountSummary? { accounts.first { $0.id == preferences.onlineAccount } }
    var playerName: String { preferences.authenticationMode == "online" ? activeAccount?.name ?? "未登录" : preferences.username }
    var modeLabel: String {
        switch preferences.authenticationMode {
        case "online": return activeAccount.map { "微软正版 · \($0.name)" } ?? "微软正版 · 请先登录"
        case "demo": return "官方试玩 · 限时试玩世界"
        default: return "离线单人 · 不支持正版服务器验证"
        }
    }
    var clientID: String {
        preferences.microsoftClientID ?? ProcessInfo.processInfo.environment["MOONLIGHT_MICROSOFT_CLIENT_ID"] ?? Bundle.main.object(forInfoDictionaryKey: "MoonlightMicrosoftClientID") as? String ?? ""
    }
    var authenticationConfigured: Bool { (try? MicrosoftConfiguration.validate(clientID)) != nil }
    func setAuthenticationMode(_ mode: String) {
        guard ["offline", "demo", "online"].contains(mode), !busy, !running, !authenticating else { return }
        preferences.mode = mode; preferences.demo = mode == "demo"
    }

    var memoryLimit: Int { max(2048, min(32768, Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) - 2048)) }

    init() {
        if let override = ProcessInfo.processInfo.environment["MOONLIGHT_DATA_DIR"] { root = URL(fileURLWithPath: override) }
        else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Moonlight") }
        installer = Installer(root: root)
        modManager = ModManager(root: root)
        if let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")), let prefs = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = prefs }
        if let data = try? Data(contentsOf: root.appendingPathComponent("accounts.json")), let saved = try? JSONDecoder().decode([AccountSummary].self, from: data) { accounts = saved }
        if !["offline", "demo", "online"].contains(preferences.authenticationMode) { preferences.mode = "offline" }
        preferences.memory = min(preferences.memory, memoryLimit)
        Task {
            await refreshInstalled()
            await refresh(useRecentCache: true)
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
        } catch { append("设置保存失败：\(error.localizedDescription)") }
    }

    func refreshInstalled() async {
        installed = await installer.installed()
        if !installed.contains(where: { $0.id == preferences.selected }) { preferences.selected = installed.first?.id ?? "" }
    }

    func refresh(useRecentCache: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if useRecentCache, let recent = await installer.cachedManifest(maximumAge: 3600) {
            displayCatalog(recent)
            catalogStatus = "已加载最近更新的官方目录 · 可手动刷新"
            return
        }
        if versions.isEmpty, let cached = await installer.cachedManifest() {
            displayCatalog(cached)
            catalogStatus = "已加载本地目录 · 正在检查更新…"
        }
        do {
            let manifest = try await installer.manifest()
            displayCatalog(manifest)
            catalogStatus = "来自 Minecraft 官方 · \(versions.count) 个正式版"
        } catch {
            catalogStatus = versions.isEmpty ? "无法连接官方目录，请检查网络后刷新" : "当前显示缓存目录 · 联网后可刷新"
            append("获取目录失败：\(error.localizedDescription)")
        }
    }

    private func displayCatalog(_ manifest: VersionManifest) {
        versions = manifest.versions.filter(\.supported)
        latest = manifest.latest.release
    }

    private func saveAccounts(_ updated: [AccountSummary]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("accounts.json"), options: .atomic)
        accounts = updated
    }

    private func remember(_ credential: AccountCredential) async throws {
        let previous = try? await vault.load(credential.profileID)
        try await vault.save(credential)
        let summary = AccountSummary(credential)
        var updated = accounts.filter { $0.id != summary.id }; updated.append(summary)
        do { try saveAccounts(updated) }
        catch {
            if let previous { try? await vault.save(previous) } else { try? await vault.remove(credential.profileID) }
            throw LauncherError("账号信息保存失败，请检查数据目录权限后重试。")
        }
    }

    func login() {
        guard !busy, !running, !authenticating else { return }
        guard authenticationConfigured else { configurationSheet = true; return }
        let id = UUID(), application = clientID
        loginGeneration = id; authenticating = true; loginSheet = true; loginChallenge = nil; loginError = nil
        loginStatus = "正在准备微软登录…"
        authTask = Task {
            defer {
                if loginGeneration == id { authenticating = false; authTask = nil; loginGeneration = nil }
            }
            do {
                let credential = try await authentication.login(clientID: application, challenge: { [weak self] challenge in
                    await self?.showChallenge(challenge, generation: id)
                }, status: { [weak self] text in await self?.reportLogin(text, generation: id) })
                try Task.checkCancellation()
                guard loginGeneration == id else { return }
                try await remember(credential)
                try Task.checkCancellation()
                guard loginGeneration == id else { return }
                preferences.onlineAccount = credential.profileID; preferences.mode = "online"; preferences.demo = false
                loginSheet = false; loginChallenge = nil
                status = "\(credential.profileName) 已通过正版验证"; append(status)
            } catch {
                guard loginGeneration == id else { return }
                if error is CancellationError { loginSheet = false }
                else { loginError = error.localizedDescription; loginStatus = "登录未完成" }
            }
        }
    }
    private func showChallenge(_ challenge: DeviceAuthorization, generation: UUID) {
        guard loginGeneration == generation else { return }
        loginChallenge = challenge
        NSWorkspace.shared.open(challenge.verificationURL)
    }
    private func reportLogin(_ text: String, generation: UUID) { if loginGeneration == generation { loginStatus = text } }
    func cancelLogin() {
        authTask?.cancel(); authTask = nil; loginGeneration = nil; authenticating = false
        loginSheet = false; loginChallenge = nil; loginError = nil
    }
    func useAccount(_ account: AccountSummary) {
        guard !busy, !running, !authenticating else { return }
        preferences.onlineAccount = account.id; preferences.mode = "online"; preferences.demo = false
    }
    func removeAccount(_ account: AccountSummary) {
        guard !busy, !running, !authenticating else { return }
        authenticating = true
        Task {
            defer { authenticating = false }
            do {
                try await vault.remove(account.id)
                try saveAccounts(accounts.filter { $0.id != account.id })
                if preferences.onlineAccount == account.id { preferences.onlineAccount = nil }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func onlineIdentity(_ prefs: Preferences) async throws -> OnlineIdentity? {
        guard prefs.authenticationMode == "online" else { return nil }
        guard let id = prefs.onlineAccount, accounts.contains(where: { $0.id == id }) else {
            page = "设置"; throw LauncherError("请先在设置中登录并选择一个微软正版账号。")
        }
        let saved = try await vault.load(id), vault = vault
        let fresh = try await authentication.refreshed(saved, rotation: { try await vault.save($0) }, status: { [weak self] text in await self?.setStatus(text) })
        try Task.checkCancellation()
        try await remember(fresh)
        return try fresh.identity()
    }
    private func setStatus(_ text: String) { status = text }

    func report(_ info: InstallProgress) { progress = info.fraction; status = info.message }

    func install(_ version: GameVersion, launchAfter: Bool = false) {
        guard !busy, !running, !authenticating else { return }
        busy = true; progress = 0; status = "准备安装 \(version.id)"
        append("开始安装 / 校验 Minecraft \(version.id)")
        let prefs = preferences
        task = Task {
            defer { busy = false; task = nil }
            do {
                let result = try await installer.install(version, customJava: prefs.customJava) { [weak self] info in await self?.report(info) }
                try Task.checkCancellation()
                await refreshInstalled(); preferences.selected = result.id
                append("\(result.id) 安装完成。")
                if launchAfter { try await startGame(result, prefs: prefs) }
            } catch { handle(error) }
        }
    }

    func installLoader(_ version: GameVersion, loader: String, build: String) {
        operate("安装 \(loader.capitalized) \(build)") { installer, java, report in
            try await installer.installLoader(version, loader: loader, build: build, customJava: java, progress: report)
        }
    }

    func repair(_ version: InstalledVersion) {
        operate("修复 \(version.title) 的游戏环境") { installer, java, report in
            try await installer.repairEnvironment(version, customJava: java, progress: report)
        }
    }

    func choosePack(optionalFiles: Bool) {
        guard !busy, !running, !authenticating else { return }
        let panel = NSOpenPanel()
        panel.message = "导入 Modrinth 格式的 .mrpack 或 ZIP 整合包。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "mrpack") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            operate("导入 \(url.lastPathComponent)") { installer, java, report in
                try await installer.importPack(url, optionalFiles: optionalFiles, customJava: java, progress: report)
            }
        }
    }

    func installPack(_ release: PackRelease, optionalFiles: Bool) {
        operate("下载整合包 \(release.name)") { installer, java, report in
            try await installer.installPack(release, optionalFiles: optionalFiles, customJava: java, progress: report)
        }
    }

    func installMods(_ plan: ModInstallPlan) {
        guard !busy, !running, !authenticating else { return }
        busy = true; progress = 0; status = "准备安装模组"; append("安装模组到 \(plan.target.title)")
        task = Task {
            defer { busy = false; task = nil; modRevision += 1 }
            do {
                try await modManager.install(plan) { [weak self] info in await self?.report(info) }
                append(status)
            } catch { handle(error) }
        }
    }

    func deleteVersion(_ version: InstalledVersion, keepSaves: Bool) {
        guard !busy, !running, !authenticating else { return }
        busy = true; progress = 0; status = "正在删除 \(version.title)"; lastVersionRemoval = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let result = try await installer.removeVersion(version, keepSaves: keepSaves)
                await refreshInstalled()
                lastVersionRemoval = result
                status = "已删除 \(version.title)" + (result.savesBackup != nil ? "，存档已保留" : "，游戏目录已移至废纸篓")
                progress = 1; append(status)
                if let backup = result.savesBackup { append("存档备份：\(backup.path)") }
                if let trash = result.trashLocation { append("废纸篓：\(trash.path)") }
                modRevision += 1
            } catch { handle(error) }
        }
    }

    func changeMod(_ mod: LocalMod, target: InstalledVersion, remove: Bool = false) {
        guard !busy, !running, !authenticating else { return }
        busy = true; status = remove ? "正在移除模组" : "正在调整模组"; progress = 0
        task = Task {
            defer { busy = false; task = nil; modRevision += 1 }
            do {
                if remove {
                    let backup = try await modManager.remove(mod, target: target)
                    status = "\(mod.title) 已移至备份"; append("\(status)：\(backup.path)")
                } else {
                    try await modManager.setEnabled(mod, target: target, enabled: !mod.enabled)
                    status = "\(mod.title) 已\(mod.enabled ? "停用" : "启用")，下次启动游戏时生效"; append(status)
                }
                progress = 1
            } catch { handle(error) }
        }
    }

    private func operate(_ message: String, action: @escaping (Installer, String, @escaping @Sendable (InstallProgress) async -> Void) async throws -> InstalledVersion) {
        guard !busy, !running, !authenticating else { return }
        busy = true; progress = 0; status = message; append(message)
        let java = preferences.customJava
        task = Task {
            defer { busy = false; task = nil }
            do {
                let result = try await action(installer, java) { [weak self] info in await self?.report(info) }
                try Task.checkCancellation()
                await refreshInstalled(); preferences.selected = result.id
                status = "\(result.title) 安装完成"; append(status); page = "版本"
            } catch { handle(error) }
        }
    }

    func launch() {
        guard !busy, !running, !authenticating else { return }
        guard let selected else { page = "下载"; return }
        let prefs = preferences
        busy = true; progress = 0; status = "正在准备启动 \(selected.id)"
        task = Task {
            defer { busy = false; task = nil }
            do { try await startGame(selected, prefs: prefs) }
            catch { handle(error) }
        }
    }

    private func startGame(_ version: InstalledVersion, prefs: Preferences) async throws {
        let identity = try await onlineIdentity(prefs)
        let plan = try await installer.launchPlan(version, username: prefs.username, memoryMB: prefs.memory, demo: prefs.authenticationMode == "demo", customJava: prefs.customJava, identity: identity) { [weak self] info in await self?.report(info) }
        try Task.checkCancellation()
        let logDir = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let file = logDir.appendingPathComponent("game-\(Int(Date().timeIntervalSince1970)).log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let capture = try GameLogCapture(file: file, secrets: [identity?.accessToken ?? ""])
        let process = Process()
        process.executableURL = plan.executable; process.arguments = plan.arguments
        process.currentDirectoryURL = plan.directory
        process.standardOutput = capture.pipe; process.standardError = capture.pipe
        var env = ProcessInfo.processInfo.environment
        // Prevent inherited terminal options from injecting Java launch arguments.
        for key in ["JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH"] { env.removeValue(forKey: key) }
        process.environment = env
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in self?.gameEnded(process.terminationStatus) }
        }
        do { try process.run() }
        catch { capture.finish(); throw error }
        game = process; logCapture = capture; logReader = try? FileHandle(forReadingFrom: file)
        running = true; progress = 1; status = "\(version.title) 正在运行"
        append("启动 \(version.id) · Java \(version.javaMajor) · \(prefs.memory) MB · \(identity == nil ? (prefs.authenticationMode == "demo" ? "官方试玩" : "离线单人") : "微软正版")")
        append("日志：\(file.path)")
        logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readGameLog() }
        }
    }

    private func readGameLog() {
        if let data = try? logReader?.read(upToCount: 65_536), !data.isEmpty, let text = String(data: data, encoding: .utf8) {
            logs += text; trimLogs()
        }
    }

    private func gameEnded(_ code: Int32) {
        logCapture?.finish(); readGameLog(); logTimer?.invalidate(); logTimer = nil
        try? logReader?.close()
        logCapture = nil; logReader = nil; game = nil; running = false
        status = code == 0 || code == 143 || code == 15 ? "游戏已退出，可以开始下一次冒险。" : "游戏退出（\(code)），请查看启动日志。"
        append(status)
        if code != 0 && code != 143 && code != 15 { errorMessage = "游戏意外退出（\(code)）。请查看「日志」，也可以在版本管理中修复游戏文件。" }
    }

    func stop() { game?.terminate(); status = "正在结束游戏…" }
    func cancel() { task?.cancel(); status = "正在取消…" }
    func handle(_ error: Error) {
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
            status = "已取消，已下载的文件会在下次继续使用。"
        } else { status = "操作未完成"; errorMessage = error.localizedDescription; append(error.localizedDescription) }
    }
    func append(_ text: String) { logs += "[\(Date().formatted(date: .omitted, time: .standard))] \(text)\n"; trimLogs() }
    private func trimLogs() { if logs.count > 120_000 { logs = String(logs.suffix(100_000)) } }

    func openFolder(_ subpath: String = "") {
        let file = root.appendingPathComponent(subpath)
        do { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true); NSWorkspace.shared.open(file) }
        catch { errorMessage = error.localizedDescription }
    }
    func selectJava() {
        let panel = NSOpenPanel(); panel.message = "选择 Java 安装目录中的 bin/java 文件；留空则自动安装。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { preferences.customJava = url.path }
    }
    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Moonlight.log"
        if panel.runModal() == .OK, let file = panel.url {
            do { try logs.write(to: file, atomically: true, encoding: .utf8) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
