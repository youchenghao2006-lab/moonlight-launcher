import Foundation
import CryptoKit

public struct LauncherError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct GameVersion: Codable, Identifiable, Hashable {
    public let id: String
    public let type: String
    public let url: String
    public let sha1: String?
    public let releaseTime: String
    public var dateLabel: String { String(releaseTime.prefix(10)) }
    // Older versions require a separate legacy-native and Java compatibility layer.
    public var supported: Bool {
        type == "release" && Self.supports(id)
    }
    public static func supports(_ id: String) -> Bool {
        guard id.range(of: "^[0-9]+(?:\\.[0-9]+)+$", options: .regularExpression) != nil else { return false }
        let parts = id.split(separator: ".").compactMap { Int($0) }
        return parts.first == 1 ? (parts.count > 1 && parts[1] >= 19) : (parts.first ?? 0) >= 26
    }
}

public struct VersionManifest: Codable {
    public struct Latest: Codable { public let release: String; public let snapshot: String }
    public let latest: Latest
    public let versions: [GameVersion]
}

public struct InstalledVersion: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let javaMajor: Int
    public let architecture: String
    public let installedAt: Date
    public let baseID: String?
    public let loader: String?
    public let loaderVersion: String?
    public let displayName: String?
    public var gameID: String { baseID ?? id }
    public var title: String { displayName ?? "Minecraft \(gameID)" }
    public var loaderLabel: String { loader.map { "\($0.capitalized) \(loaderVersion ?? "")" } ?? "原版" }
    public init(id: String, javaMajor: Int, architecture: String, baseID: String? = nil, loader: String? = nil, loaderVersion: String? = nil, displayName: String? = nil) {
        self.id = id; self.javaMajor = javaMajor; self.architecture = architecture; installedAt = Date()
        self.baseID = baseID; self.loader = loader; self.loaderVersion = loaderVersion; self.displayName = displayName
    }
}

public enum Platform {
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    public static var label: String { architecture == "arm64" ? "Apple Silicon" : "Intel" }
}

public enum Metadata {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LauncherError("下载的版本信息格式不正确。")
        }
        return result
    }

    public static func safePath(_ relative: String, under root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              relative.range(of: "^[A-Za-z]:", options: .regularExpression) == nil,
              relative.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !relative.split(separator: "/").contains("..") else {
            throw LauncherError("版本信息包含不安全的文件路径。")
        }
        let result = root.appendingPathComponent(relative).standardizedFileURL
        guard result.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw LauncherError("文件路径超出了游戏目录。")
        }
        return result
    }

    public static func rulesAllow(_ rules: [[String: Any]]?, demo: Bool = false, arch: String = Platform.architecture) -> Bool {
        guard let rules else { return true }
        var allowed = false
        for rule in rules {
            var matches = true
            if let os = rule["os"] as? [String: Any] {
                if let name = os["name"] as? String, name != "osx" { matches = false }
                if let expected = os["arch"] as? String {
                    let actual = arch == "arm64" ? "aarch64" : "x86_64"
                    if actual.range(of: "^(?:\(expected))$", options: .regularExpression) == nil { matches = false }
                }
                if let pattern = os["version"] as? String, ProcessInfo.processInfo.operatingSystemVersionString.range(of: pattern, options: .regularExpression) == nil { matches = false }
            }
            if let features = rule["features"] as? [String: Bool] {
                for (key, expected) in features {
                    let actual = key == "is_demo_user" ? demo : key == "has_custom_resolution"
                    if actual != expected { matches = false }
                }
            }
            if matches { allowed = rule["action"] as? String == "allow" }
        }
        return allowed
    }

    public static func libraries(_ metadata: [String: Any], arch: String = Platform.architecture) -> [[String: Any]] {
        (metadata["libraries"] as? [[String: Any]] ?? []).filter { lib in
            guard rulesAllow(lib["rules"] as? [[String: Any]], arch: arch) else { return false }
            let name = lib["name"] as? String ?? ""
            if name.contains(":natives-macos") {
                return arch == "arm64" ? name.hasSuffix(":natives-macos-arm64") : !name.contains("arm64")
            }
            return true
        }
    }

    public static func arguments(_ items: [Any], values: [String: String], demo: Bool) throws -> [String] {
        var result: [String] = []
        for item in items {
            var strings: [String] = []
            if let string = item as? String { strings = [string] }
            else if let entry = item as? [String: Any], rulesAllow(entry["rules"] as? [[String: Any]], demo: demo) {
                if let string = entry["value"] as? String { strings = [string] }
                else { strings = entry["value"] as? [String] ?? [] }
            }
            for var string in strings {
                for (key, value) in values { string = string.replacingOccurrences(of: "${\(key)}", with: value) }
                guard !string.contains("${") else { throw LauncherError("暂不支持该版本的启动参数：\(string)") }
                result.append(string)
            }
        }
        return result
    }

    public static func digest(_ file: URL, sha256: Bool = false, sha512: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = Insecure.SHA1(); var sha2 = SHA256(); var sha5 = SHA512()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            if sha512 { sha5.update(data: data) } else if sha256 { sha2.update(data: data) } else { sha.update(data: data) }
        }
        if sha512 { return sha5.finalize().map { String(format: "%02x", $0) }.joined() }
        return sha256 ? sha2.finalize().map { String(format: "%02x", $0) }.joined()
            : sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func offlineUUID(_ name: String) -> String {
        var bytes = Array(Insecure.MD5.hash(data: Data("OfflinePlayer:\(name)".utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
