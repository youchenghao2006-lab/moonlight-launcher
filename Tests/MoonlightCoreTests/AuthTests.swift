import Foundation
import MoonlightCore

struct AuthEvent: Sendable {
    let path: String
    let status: Int
    let json: String
    var timeout = false
}
private actor ScriptedAuthentication: AuthTransport {
    private var events: [AuthEvent]
    private(set) var requests: [URLRequest] = []
    init(_ events: [AuthEvent]) { self.events = events }
    func send(_ request: URLRequest) async throws -> AuthReply {
        guard !events.isEmpty else { throw LauncherError("Unexpected auth request") }
        let event = events.removeFirst()
        guard request.url?.path == event.path else { throw LauncherError("Unexpected auth endpoint") }
        requests.append(request)
        if event.timeout { throw URLError(.timedOut) }
        return AuthReply(status: event.status, data: Data(event.json.utf8))
    }
}
private final class SimulatedAuthClock: AuthClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private(set) var intervals: [TimeInterval] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    private func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; intervals.append(seconds); current.addTimeInterval(seconds) }
    func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation(); advance(seconds) }
}
private actor RotatedCredential {
    private(set) var value: AccountCredential?
    func set(_ value: AccountCredential) { self.value = value }
}

extension CoreTests {
    static let testClientID = "11111111-2222-4333-8444-555555555555"
    static let testProfileID = "0123456789abcdef0123456789abcdef"
    static var challengeEvent: AuthEvent { .init(path: "/consumers/oauth2/v2.0/devicecode", status: 200, json: "{\"device_code\":\"DEVICE_TEST_ONLY\",\"user_code\":\"TEST-ONLY\",\"verification_uri\":\"https://microsoft.com/devicelogin\",\"expires_in\":900,\"interval\":5}") }
    static var tokenEvent: AuthEvent { .init(path: "/consumers/oauth2/v2.0/token", status: 200, json: "{\"access_token\":\"MS_TEST_ONLY\",\"refresh_token\":\"ROTATED_TEST_ONLY\"}") }
    static var xboxEvent: AuthEvent { .init(path: "/user/authenticate", status: 200, json: "{\"Token\":\"XBOX_TEST_ONLY\"}") }
    static var xstsEvent: AuthEvent { .init(path: "/xsts/authorize", status: 200, json: "{\"Token\":\"XSTS_TEST_ONLY\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"UHS_TEST_ONLY\",\"xid\":\"123456789\"}]}}") }
    static var minecraftEvent: AuthEvent { .init(path: "/authentication/login_with_xbox", status: 200, json: "{\"access_token\":\"MC_TEST_ONLY\",\"expires_in\":3600}") }
    static var entitlementEvent: AuthEvent { .init(path: "/entitlements/license", status: 200, json: "{\"items\":[{\"name\":\"game_minecraft\"}]}") }
    static var profileEvent: AuthEvent { .init(path: "/minecraft/profile", status: 200, json: "{\"id\":\"\(testProfileID)\",\"name\":\"RealPlayer\"}") }
    static var exchangeEvents: [AuthEvent] { [xboxEvent, xstsEvent, minecraftEvent, entitlementEvent, profileEvent] }
    static func sampleCredential(expired: Bool = false) -> AccountCredential {
        .init(clientID: testClientID, refreshToken: "REFRESH_TEST_ONLY", minecraftToken: "MC_TEST_ONLY", expiresAt: Date(timeIntervalSince1970: expired ? 1_600_000_000 : 1_800_000_000), profileID: testProfileID, profileName: "RealPlayer", xuid: "123456789")
    }
    static func asyncFailure(_ message: String, _ body: () async throws -> Void) async throws -> String {
        do { try await body(); throw LauncherError("Expected failure not raised: \(message)") }
        catch {
            if error.localizedDescription.hasPrefix("Expected failure not raised") { throw error }
            try check(true, message)
            return error.localizedDescription
        }
    }
    static func authentication() async throws {
        try mustThrow("client ID required") { _ = try MicrosoftConfiguration.validate("") }
        try mustThrow("zero client ID rejected") { _ = try MicrosoftConfiguration.validate("00000000-0000-0000-0000-000000000000") }
        let form = String(decoding: MicrosoftAuthentication.form(["refresh_token": "a+b&c=你好", "scope": "x y"]), as: UTF8.self)
        try check(form.contains("a%2Bb%26c%3D%E4%BD%A0%E5%A5%BD") && form.contains("x%20y"), "OAuth form encodes special characters")
        let empty = ScriptedAuthentication([])
        _ = try await asyncFailure("missing configuration never contacts server") { _ = try await MicrosoftAuthentication(transport: empty).login(clientID: "", challenge: { _ in }, status: { _ in }) }
        let noRequests = await empty.requests
        try check(noRequests.isEmpty, "no fabricated default application ID")

        let clock = SimulatedAuthClock()
        let pending = AuthEvent(path: "/consumers/oauth2/v2.0/token", status: 400, json: "{\"error\":\"authorization_pending\"}")
        let slow = AuthEvent(path: pending.path, status: 400, json: "{\"error\":\"slow_down\"}")
        let timeout = AuthEvent(path: pending.path, status: 0, json: "", timeout: true)
        let xstsWithoutID = AuthEvent(path: "/xsts/authorize", status: 200, json: "{\"Token\":\"XSTS_TEST_ONLY\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"UHS_TEST_ONLY\"}]}}")
        let script = ScriptedAuthentication([challengeEvent, pending, slow, timeout, tokenEvent, xboxEvent, xstsWithoutID, xstsEvent, minecraftEvent, entitlementEvent, profileEvent])
        let credential = try await MicrosoftAuthentication(transport: script, clock: clock).login(clientID: testClientID, challenge: { _ in }, status: { _ in })
        try check(clock.intervals == [5, 5, 10, 20], "pending, slow_down, timeout obey polling backoff")
        try check(credential.profileID == testProfileID && credential.profileName == "RealPlayer" && credential.xuid == "123456789", "verified identity comes from services")
        try check(credential.refreshToken == "ROTATED_TEST_ONLY" && credential.minecraftToken == "MC_TEST_ONLY", "Microsoft and Minecraft tokens stay distinct")
        let requests = await script.requests
        try check(requests.allSatisfy { $0.url?.scheme == "https" }, "authentication uses HTTPS")
        let xboxBody = try Metadata.object(requests.first { $0.url?.path == "/user/authenticate" }!.httpBody!)
        try check((xboxBody["Properties"] as? [String: String])?["RpsTicket"] == "d=MS_TEST_ONLY", "Xbox receives the Microsoft access token")
        let mcBody = try Metadata.object(requests.first { $0.url?.path == "/authentication/login_with_xbox" }!.httpBody!)
        try check(mcBody["identityToken"] as? String == "XBL3.0 x=UHS_TEST_ONLY;XSTS_TEST_ONLY", "Minecraft receives XSTS identity")
        try check(requests.filter { $0.url?.path == "/minecraft/profile" }.first?.value(forHTTPHeaderField: "Authorization") == "Bearer MC_TEST_ONLY", "profile request uses Minecraft bearer")
        let publicAccount = String(decoding: try JSONEncoder().encode(AccountSummary(credential)), as: UTF8.self)
        try check(!publicAccount.contains("TOKEN") && !publicAccount.contains("refreshToken") && !publicAccount.contains("minecraftToken"), "public account file excludes credentials")

        for code in ["authorization_declined", "expired_token"] {
            let script = ScriptedAuthentication([challengeEvent, .init(path: pending.path, status: 400, json: "{\"error\":\"\(code)\",\"error_description\":\"SECRET_MUST_NOT_LEAK\"}")])
            let text = try await asyncFailure("handle \(code)") { _ = try await MicrosoftAuthentication(transport: script, clock: SimulatedAuthClock()).login(clientID: testClientID, challenge: { _ in }, status: { _ in }) }
            try check(!text.contains("SECRET_MUST_NOT_LEAK"), "server descriptions never enter UI errors")
        }
        let badLink = AuthEvent(path: challengeEvent.path, status: 200, json: challengeEvent.json.replacingOccurrences(of: "https://microsoft.com", with: "https://example.com"))
        _ = try await asyncFailure("reject external authorization URL") { _ = try await MicrosoftAuthentication(transport: ScriptedAuthentication([badLink]), clock: clock).login(clientID: testClientID, challenge: { _ in }, status: { _ in }) }
        let cancelled = ScriptedAuthentication([challengeEvent])
        let task = Task {
            try await MicrosoftAuthentication(transport: cancelled, clock: SimulatedAuthClock()).login(clientID: testClientID, challenge: { _ in withUnsafeCurrentTask { $0?.cancel() } }, status: { _ in })
        }
        do { _ = try await task.value; throw LauncherError("Cancellation not raised") }
        catch is CancellationError { try check(true, "login cancellation stops polling") }
        let cancelledRequests = await cancelled.requests
        try check(cancelledRequests.count == 1, "cancelled login makes no token request")
        let expiry = AuthEvent(path: challengeEvent.path, status: 200, json: challengeEvent.json.replacingOccurrences(of: "900", with: "10"))
        _ = try await asyncFailure("local device code expiry") { _ = try await MicrosoftAuthentication(transport: ScriptedAuthentication([expiry, pending]), clock: SimulatedAuthClock()).login(clientID: testClientID, challenge: { _ in }, status: { _ in }) }

        let rotated = RotatedCredential()
        let denied = AuthEvent(path: minecraftEvent.path, status: 403, json: "{\"error\":\"ForbiddenOperationException\",\"errorMessage\":\"SECRET_MUST_NOT_LEAK\"}")
        let rotationScript = ScriptedAuthentication([tokenEvent, xboxEvent, xstsEvent, denied])
        let deniedMessage = try await asyncFailure("unapproved Minecraft application rejected") {
            _ = try await MicrosoftAuthentication(transport: rotationScript, clock: clock).refreshed(sampleCredential(expired: true), rotation: { await rotated.set($0) }, status: { _ in })
        }
        let rotatedValue = await rotated.value
        try check(rotatedValue?.refreshToken == "ROTATED_TEST_ONLY", "refresh rotation saved before downstream failure")
        try check(deniedMessage.contains("批准") && !deniedMessage.contains("SECRET_MUST_NOT_LEAK"), "403 gives setup guidance without response secrets")
        let refreshRequest = await rotationScript.requests.first!
        let refreshForm = String(decoding: refreshRequest.httpBody!, as: UTF8.self)
        try check(refreshForm.contains("REFRESH_TEST_ONLY") && refreshForm.contains(testClientID) && !refreshForm.contains("client_secret"), "refresh uses owning public client and no secret")

        let noEntitlement = AuthEvent(path: entitlementEvent.path, status: 200, json: "{\"items\":[]}")
        let noGame = ScriptedAuthentication([noEntitlement])
        _ = try await asyncFailure("no ownership prevents online launch") { _ = try await MicrosoftAuthentication(transport: noGame, clock: clock).refreshed(sampleCredential(), rotation: { _ in throw LauncherError("Unexpected refresh") }, status: { _ in }) }
        let noGameRequests = await noGame.requests
        try check(noGameRequests.count == 1, "ownership failure never falls back or refreshes")
        let unauthorized = AuthEvent(path: entitlementEvent.path, status: 401, json: "{}")
        let revoked = ScriptedAuthentication([unauthorized, tokenEvent] + exchangeEvents)
        let refreshed = try await MicrosoftAuthentication(transport: revoked, clock: clock).refreshed(sampleCredential(), rotation: { _ in }, status: { _ in })
        try check(refreshed.refreshToken == "ROTATED_TEST_ONLY", "401 refreshes a revoked access token once")
        let childError = AuthEvent(path: "/xsts/authorize", status: 401, json: "{\"XErr\":2148916238}")
        let childMessage = try await asyncFailure("child account Xbox restriction") { _ = try await MicrosoftAuthentication(transport: ScriptedAuthentication([tokenEvent, xboxEvent, childError]), clock: clock).refreshed(sampleCredential(expired: true), rotation: { _ in }, status: { _ in }) }
        try check(childMessage.contains("家长"), "Xbox restriction provides actionable message")
        let changed = AuthEvent(path: profileEvent.path, status: 200, json: profileEvent.json.replacingOccurrences(of: testProfileID, with: String(repeating: "f", count: 32)))
        _ = try await asyncFailure("refreshed profile must match selected account") { _ = try await MicrosoftAuthentication(transport: ScriptedAuthentication([tokenEvent, xboxEvent, xstsEvent, minecraftEvent, entitlementEvent, changed]), clock: clock).refreshed(sampleCredential(expired: true), rotation: { _ in }, status: { _ in }) }
        let fallback = ScriptedAuthentication([.init(path: "/entitlements/license", status: 404, json: "{}"), .init(path: "/entitlements/mcstore", status: 200, json: entitlementEvent.json), profileEvent])
        _ = try await MicrosoftAuthentication(transport: fallback, clock: clock).refreshed(sampleCredential(), rotation: { _ in throw LauncherError("Unexpected refresh") }, status: { _ in })
        try check(true, "legacy entitlement endpoint fallback only on 404")
        let noProfile = AuthEvent(path: profileEvent.path, status: 404, json: "{}")
        _ = try await asyncFailure("profile setup required") { _ = try await MicrosoftAuthentication(transport: ScriptedAuthentication([entitlementEvent, noProfile]), clock: clock).refreshed(sampleCredential(), rotation: { _ in }, status: { _ in }) }
        try logRedaction()
        try await onlineLaunchPlan()
    }
    static func logRedaction() throws {
        var redactor = SecretLogRedactor(secrets: ["MC_TEST_ONLY"])
        var output = redactor.consume(Data("中文 MC_TE".utf8))
        output.append(redactor.consume(Data("ST_ONLY hello\nlast MC_TEST_ON".utf8)))
        output.append(redactor.consume(Data("LY".utf8), finish: true))
        let text = String(decoding: output, as: UTF8.self)
        try check(!text.contains("MC_TEST_ONLY") && text.contains("中文") && text.components(separatedBy: "[登录凭证已隐藏]").count == 3, "chunked and unterminated log secrets redacted")
        var oversized = SecretLogRedactor(secrets: ["SECRET"])
        let large = oversized.consume(Data(repeating: 65, count: 1_048_600))
        let tail = oversized.consume(Data("SECRET\nnext\n".utf8))
        try check(!String(decoding: large + tail, as: UTF8.self).contains("SECRET"), "oversized log line discarded safely")
    }
    static func onlineLaunchPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moonlight-auth-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("versions/1.21.1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("1.21.1.jar"))
        let json: [String: Any] = ["mainClass": "TestMain", "libraries": [], "arguments": ["jvm": ["-cp", "${classpath}"], "game": ["--username", "${auth_player_name}", "--uuid", "${auth_uuid}", "--accessToken", "${auth_access_token}", "--userType", "${user_type}", "--clientId", "${clientid}", "--xuid", "${auth_xuid}", ["rules": [["action": "allow", "features": ["is_demo_user": true]]], "value": "--demo"]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("1.21.1.json"))
        let java = root.appendingPathComponent("java-test")
        let arch = Platform.architecture == "arm64" ? "aarch64" : "x86_64"
        try Data("#!/bin/sh\nprintf '%s\\n' 'java.specification.version = 21' 'os.arch = \(arch)'\n".utf8).write(to: java)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        let installer = Installer(root: root), record = InstalledVersion(id: "1.21.1", javaMajor: 21, architecture: Platform.architecture)
        let plan = try await installer.launchPlan(record, username: "OfflinePlayer", memoryMB: 2048, demo: true, customJava: java.path, identity: sampleCredential().identity()) { _ in }
        try check(plan.arguments.contains("RealPlayer") && plan.arguments.contains(testProfileID) && plan.arguments.contains("MC_TEST_ONLY") && plan.arguments.contains("msa"), "online launch receives actual identity and token")
        try check(!plan.arguments.contains("--demo") && !plan.arguments.contains(Metadata.offlineUUID("OfflinePlayer")), "online launch never uses demo or offline UUID")
        let offline = try await installer.launchPlan(record, username: "OfflinePlayer", memoryMB: 2048, demo: false, customJava: java.path) { _ in }
        try check(offline.arguments.contains(Metadata.offlineUUID("OfflinePlayer")) && offline.arguments.contains("legacy") && !offline.arguments.contains("MC_TEST_ONLY"), "offline mode remains independent")
        let outputFile = root.appendingPathComponent("captured.log")
        try Data().write(to: outputFile)
        let capture = try GameLogCapture(file: outputFile, secrets: ["MC_TEST_ONLY"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '中文 MC_TEST'; printf '_ONLY\\n'; printf 'last MC_TEST_ONLY' >&2"]
        process.standardOutput = capture.pipe; process.standardError = capture.pipe
        try process.run(); process.waitUntilExit(); capture.finish()
        let captured = try String(contentsOf: outputFile, encoding: .utf8)
        try check(captured.contains("中文") && captured.contains("last") && captured.hasSuffix("[登录凭证已隐藏]"), "process capture drains final output after exit")
        try check(!captured.contains("MC_TEST_ONLY"), "process stdout and stderr redact credentials before disk")
    }
    static func keychainRoundTrip() async throws {
        let vault = CredentialVault(service: "dev.moonlight.launcher.tests.\(UUID().uuidString)")
        do {
            try await vault.save(sampleCredential())
            let first = try await vault.load(testProfileID)
            try check(first.minecraftToken == "MC_TEST_ONLY", "Keychain stores credentials")
            try await vault.save(first.rotating("ROTATED_TEST_ONLY"))
            let changed = try await vault.load(testProfileID)
            try check(changed.refreshToken == "ROTATED_TEST_ONLY", "Keychain atomically updates refresh tokens")
            try await vault.remove(testProfileID)
            _ = try await asyncFailure("Keychain logout deletes saved credentials") { _ = try await vault.load(testProfileID) }
            print("KEYCHAIN_OK (temporary synthetic credential removed)")
        } catch { try? await vault.remove(testProfileID); throw error }
    }
}
