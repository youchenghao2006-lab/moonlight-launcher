import Foundation

public enum MicrosoftConfiguration {
    public static let scope = "XboxLive.SignIn XboxLive.offline_access"
    public static func validate(_ clientID: String) throws -> String {
        let value = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: value), uuid.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw LauncherError("请先配置月光自己的微软应用 Client ID，并确认它已获准访问 Minecraft 接口。")
        }
        return uuid.uuidString.lowercased()
    }
}

public struct OnlineIdentity: Sendable {
    public let name: String
    public let uuid: String
    public let accessToken: String
    public let clientID: String
    public let xuid: String
    public init(name: String, uuid: String, accessToken: String, clientID: String, xuid: String) throws {
        guard name.range(of: "^[A-Za-z0-9_]{1,16}$", options: .regularExpression) != nil,
              uuid.count == 32, uuid.allSatisfy(\.isHexDigit), !accessToken.isEmpty, xuid.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw LauncherError("正版账号档案不完整，请重新登录。") }
        self.name = name; self.uuid = uuid.lowercased(); self.accessToken = accessToken
        self.clientID = try MicrosoftConfiguration.validate(clientID); self.xuid = xuid
    }
}

public struct AccountSummary: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let clientID: String
    public init(_ credential: AccountCredential) {
        id = credential.profileID; name = credential.profileName; clientID = credential.clientID
    }
}

// The entire value belongs in Keychain; never encode this in preferences or logs.
public struct AccountCredential: Codable, Sendable {
    public let clientID: String
    public let refreshToken: String
    public let minecraftToken: String
    public let expiresAt: Date
    public let profileID: String
    public let profileName: String
    public let xuid: String
    public init(clientID: String, refreshToken: String, minecraftToken: String, expiresAt: Date, profileID: String, profileName: String, xuid: String) {
        self.clientID = clientID; self.refreshToken = refreshToken; self.minecraftToken = minecraftToken
        self.expiresAt = expiresAt; self.profileID = profileID; self.profileName = profileName; self.xuid = xuid
    }
    public func identity() throws -> OnlineIdentity { try OnlineIdentity(name: profileName, uuid: profileID, accessToken: minecraftToken, clientID: clientID, xuid: xuid) }
    public func rotating(_ token: String) -> Self {
        .init(clientID: clientID, refreshToken: token, minecraftToken: minecraftToken, expiresAt: expiresAt, profileID: profileID, profileName: profileName, xuid: xuid)
    }
}

public struct DeviceAuthorization: Sendable {
    let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    let interval: TimeInterval
}
public struct AuthReply: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public protocol AuthTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AuthReply
}
public protocol AuthClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}
public struct SystemAuthClock: AuthClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
}

private final class RejectAuthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct OfficialAuthTransport: AuthTransport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false; config.urlCache = nil
        return URLSession(configuration: config, delegate: RejectAuthRedirects(), delegateQueue: nil)
    }()
    public init() {}
    public func send(_ request: URLRequest) async throws -> AuthReply {
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LauncherError("登录服务返回了无效响应。") }
        return AuthReply(status: response.statusCode, data: data)
    }
}

private struct ExpiredMinecraftSession: LocalizedError {
    let stage: String
    var errorDescription: String? { "\(stage) 登录已失效，请重新登录。" }
}

public struct MicrosoftAuthentication: Sendable {
    private let transport: any AuthTransport
    private let clock: any AuthClock
    private static let microsoft = "https://login.microsoftonline.com/consumers/oauth2/v2.0/"
    public init(transport: any AuthTransport = OfficialAuthTransport(), clock: any AuthClock = SystemAuthClock()) {
        self.transport = transport; self.clock = clock
    }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    private func request(_ address: String, form: [String: String]? = nil, json: [String: Any]? = nil, bearer: String? = nil) async throws -> AuthReply {
        guard let url = URL(string: address), url.scheme == "https", ["login.microsoftonline.com", "user.auth.xboxlive.com", "xsts.auth.xboxlive.com", "api.minecraftservices.com"].contains(url.host ?? "") else { throw LauncherError("登录服务地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Moonlight/0.3 (macOS)", forHTTPHeaderField: "User-Agent")
        if url.host?.hasSuffix(".xboxlive.com") == true { request.setValue("1", forHTTPHeaderField: "x-xbl-contract-version") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let form { request.httpMethod = "POST"; request.httpBody = Self.form(form); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        if let json { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        try Task.checkCancellation()
        do { return try await transport.send(request) }
        catch {
            if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
            if (error as NSError).code == NSURLErrorTimedOut { throw URLError(.timedOut) }
            // Do not include response bodies, tokens, or URLRequest descriptions in errors.
            throw LauncherError("无法连接登录服务，请检查网络后重试。")
        }
    }
    private func object(_ reply: AuthReply) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any] else { throw LauncherError("登录服务的响应格式不正确，请稍后重试。") }
        return value
    }
    private func requireSuccess(_ reply: AuthReply, stage: String) throws -> [String: Any] {
        guard (200...299).contains(reply.status) else {
            let json = (try? object(reply)) ?? [:]
            if stage == "Minecraft", reply.status == 403 { throw LauncherError("Minecraft 拒绝了登录（403）。请确认月光的 Client ID 已获 Minecraft API 批准，并检查账号限制。") }
            if let code = (json["XErr"] as? NSNumber)?.uint64Value {
                switch code {
                case 2148916233: throw LauncherError("此微软账号尚未建立 Xbox 档案，请先在 xbox.com 完成设置后重新登录。")
                case 2148916238: throw LauncherError("此儿童账号需要由家长在微软家庭设置中完成 Xbox 授权。")
                case 2148916235: throw LauncherError("Xbox 在此账号所在地区不可用，请检查账号地区设置。")
                default: throw LauncherError("Xbox 拒绝了授权（\(code)），请检查账号与家庭限制。")
                }
            }
            let code = json["error"] as? String ?? ""
            if ["invalid_grant", "interaction_required", "login_required"].contains(code) { throw LauncherError("微软登录已失效，请重新添加此账号。") }
            if ["invalid_client", "unauthorized_client", "invalid_scope"].contains(code) { throw LauncherError("微软应用配置未通过验证，请检查 Client ID、个人账号支持和公共客户端流程。") }
            if reply.status == 401 { throw ExpiredMinecraftSession(stage: stage) }
            if reply.status == 429 { throw LauncherError("登录请求过于频繁，请稍后重试。") }
            throw LauncherError("\(stage) 服务暂时无法完成登录（HTTP \(reply.status)）。")
        }
        return try object(reply)
    }
    private func string(_ json: [String: Any], _ key: String) throws -> String {
        guard let value = json[key] as? String, !value.isEmpty else { throw LauncherError("登录服务缺少必要信息，请重新登录。") }
        return value
    }
    private func seconds(_ json: [String: Any], _ key: String) throws -> TimeInterval {
        guard let value = json[key] as? Double, value > 0, value.isFinite, value <= 604_800 else { throw LauncherError("登录服务返回的有效期无效。") }
        return value
    }

    public func login(clientID: String, challenge: @escaping @Sendable (DeviceAuthorization) async -> Void, status: @escaping @Sendable (String) async -> Void) async throws -> AccountCredential {
        let clientID = try MicrosoftConfiguration.validate(clientID)
        await status("正在向微软请求登录码…")
        let json = try requireSuccess(await request(Self.microsoft + "devicecode", form: ["client_id": clientID, "scope": MicrosoftConfiguration.scope]), stage: "微软")
        let deviceCode = try string(json, "device_code"), userCode = try string(json, "user_code")
        let expires = try seconds(json, "expires_in")
        guard expires <= 3600, let address = json["verification_uri"] as? String, let url = URL(string: address), url.scheme == "https", ["microsoft.com", "www.microsoft.com", "login.microsoftonline.com", "login.live.com"].contains(url.host ?? ""), url.user == nil, url.password == nil else { throw LauncherError("微软登录链接或有效期无效，已停止授权。") }
        var interval = json["interval"] as? Double ?? 5
        guard interval.isFinite, (1...300).contains(interval) else { throw LauncherError("微软登录轮询间隔无效。") }
        let deadline = clock.now().addingTimeInterval(expires)
        await challenge(.init(deviceCode: deviceCode, userCode: userCode, verificationURL: url, expiresAt: deadline, interval: interval))
        await status("请在微软网页输入登录码，完成后这里会自动继续。")
        while clock.now() < deadline {
            try await clock.sleep(seconds: min(interval, max(0, deadline.timeIntervalSince(clock.now()))))
            try Task.checkCancellation()
            guard clock.now() < deadline else { break }
            let reply: AuthReply
            do { reply = try await request(Self.microsoft + "token", form: ["client_id": clientID, "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": deviceCode]) }
            catch let error as URLError where error.code == .timedOut { interval = min(600, interval * 2); continue }
            let value = try object(reply)
            if !(200...299).contains(reply.status) {
                switch value["error"] as? String {
                case "authorization_pending": continue
                case "slow_down": interval += 5; continue
                case "authorization_declined", "access_denied": throw LauncherError("你取消了微软授权，可以重新登录。")
                case "expired_token", "bad_verification_code": throw LauncherError("登录码已失效，请重新获取。")
                default: _ = try requireSuccess(reply, stage: "微软")
                }
            }
            let access = try string(value, "access_token"), refresh = try string(value, "refresh_token")
            return try await exchange(access: access, refresh: refresh, clientID: clientID, status: status)
        }
        throw LauncherError("登录码已过期，请重新获取。")
    }

    private func xboxClaims(_ value: [String: Any]) throws -> [String: Any] {
        guard let claims = value["DisplayClaims"] as? [String: Any], let users = claims["xui"] as? [[String: Any]], let user = users.first else { throw LauncherError("Xbox 返回的身份信息不完整。") }
        return user
    }
    private func exchange(access: String, refresh: String, clientID: String, status: @escaping @Sendable (String) async -> Void) async throws -> AccountCredential {
        await status("正在验证 Xbox 身份…")
        let xbox = try requireSuccess(await request("https://user.auth.xboxlive.com/user/authenticate", json: ["Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": "d=" + access], "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT"]), stage: "Xbox")
        let token = try string(xbox, "Token")
        let properties: [String: Any] = ["SandboxId": "RETAIL", "UserTokens": [token]]
        let xsts = try requireSuccess(await request("https://xsts.auth.xboxlive.com/xsts/authorize", json: ["Properties": properties, "RelyingParty": "rp://api.minecraftservices.com/", "TokenType": "JWT"]), stage: "Xbox")
        let user = try xboxClaims(xsts), uhs = try string(user, "uhs"), xstsToken = try string(xsts, "Token")
        var xuid = user["xid"] as? String ?? ""
        if xuid.isEmpty {
            let profileToken = try requireSuccess(await request("https://xsts.auth.xboxlive.com/xsts/authorize", json: ["Properties": properties, "RelyingParty": "http://xboxlive.com", "TokenType": "JWT"]), stage: "Xbox 档案")
            xuid = try string(xboxClaims(profileToken), "xid")
        }
        guard xuid.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw LauncherError("Xbox 用户编号无效，请重新登录。") }
        await status("正在检查 Minecraft Java 版资格…")
        let minecraft = try requireSuccess(await request("https://api.minecraftservices.com/authentication/login_with_xbox", json: ["identityToken": "XBL3.0 x=" + uhs + ";" + xstsToken]), stage: "Minecraft")
        let gameToken = try string(minecraft, "access_token")
        let expiresAt = clock.now().addingTimeInterval(try seconds(minecraft, "expires_in"))
        let profile = try await verifiedProfile(gameToken)
        let credential = AccountCredential(clientID: clientID, refreshToken: refresh, minecraftToken: gameToken, expiresAt: expiresAt, profileID: profile.id, profileName: profile.name, xuid: xuid)
        _ = try credential.identity()
        await status("\(profile.name) 已通过正版身份验证。")
        return credential
    }

    private func verifiedProfile(_ token: String) async throws -> (id: String, name: String) {
        var reply = try await request("https://api.minecraftservices.com/entitlements/license?requestId=\(UUID().uuidString)", bearer: token)
        // Older service deployments use mcstore. Never fall back after authorization errors.
        if reply.status == 404 { reply = try await request("https://api.minecraftservices.com/entitlements/mcstore", bearer: token) }
        let entitlements = try requireSuccess(reply, stage: "Minecraft 资格")
        let items = entitlements["items"] as? [[String: Any]] ?? []
        guard items.contains(where: { ["game_minecraft", "product_minecraft"].contains($0["name"] as? String ?? "") }) else { throw LauncherError("这个微软账号没有有效的 Minecraft Java 版资格。请确认购买的是 Java 版，或订阅仍有效。") }
        let profileReply = try await request("https://api.minecraftservices.com/minecraft/profile", bearer: token)
        if profileReply.status == 404 { throw LauncherError("此账号尚未建立 Java 版角色，请先在 minecraft.net 设置游戏名称后重新登录。") }
        let profile = try requireSuccess(profileReply, stage: "Minecraft 档案")
        let id = try string(profile, "id").replacingOccurrences(of: "-", with: "").lowercased(), name = try string(profile, "name")
        guard id.count == 32, id.allSatisfy(\.isHexDigit), name.range(of: "^[A-Za-z0-9_]{1,16}$", options: .regularExpression) != nil else { throw LauncherError("Minecraft 角色档案无效，请重新登录。") }
        return (id, name)
    }

    public func refreshed(_ credential: AccountCredential, rotation: @escaping @Sendable (AccountCredential) async throws -> Void, status: @escaping @Sendable (String) async -> Void) async throws -> AccountCredential {
        _ = try credential.identity()
        if credential.expiresAt > clock.now().addingTimeInterval(120) {
            await status("正在确认正版账号资格…")
            do {
                let profile = try await verifiedProfile(credential.minecraftToken)
                guard profile.id == credential.profileID else { throw LauncherError("账号身份发生变化，请重新登录。") }
                return .init(clientID: credential.clientID, refreshToken: credential.refreshToken, minecraftToken: credential.minecraftToken, expiresAt: credential.expiresAt, profileID: profile.id, profileName: profile.name, xuid: credential.xuid)
            } catch {
                // Only invalid access tokens warrant refresh; network or ownership failures must stay visible.
                guard error is ExpiredMinecraftSession else { throw error }
            }
        }
        await status("正在刷新微软登录…")
        let reply = try await request(Self.microsoft + "token", form: ["client_id": credential.clientID, "grant_type": "refresh_token", "refresh_token": credential.refreshToken, "scope": MicrosoftConfiguration.scope])
        let microsoft = try requireSuccess(reply, stage: "微软")
        let access = try string(microsoft, "access_token"), refresh = microsoft["refresh_token"] as? String ?? credential.refreshToken
        guard !refresh.isEmpty else { throw LauncherError("微软登录凭证已失效，请重新登录。") }
        // Save rotated refresh tokens before later service calls can fail.
        try await rotation(credential.rotating(refresh))
        let result = try await exchange(access: access, refresh: refresh, clientID: credential.clientID, status: status)
        guard result.profileID == credential.profileID else { throw LauncherError("刷新后的账号与所选账号不一致，请重新登录。") }
        return result
    }
}
