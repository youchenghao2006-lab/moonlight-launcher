import Foundation

public enum Network {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 1200
        config.httpMaximumConnectionsPerHost = 8
        config.httpAdditionalHeaders = ["User-Agent": "Moonlight/0.5.0 (macOS)"]
        return URLSession(configuration: config)
    }()

    static func request(_ string: String) throws -> URLRequest {
        guard let url = URL(string: string), url.scheme == "https" else {
            throw LauncherError("下载地址无效，或不是 HTTPS 地址。")
        }
        return URLRequest(url: url)
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LauncherError("下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），请稍后重试。")
        }
    }

    public static func data(_ string: String) async throws -> Data {
        let (data, response) = try await session.data(for: request(string))
        try check(response)
        return data
    }

    public static func download(_ string: String, to destination: URL, hash: String, sha256: Bool = false, sha512: Bool = false) async throws {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path),
           try Metadata.digest(destination, sha256: sha256, sha512: sha512) == hash { return }
        var lastError: Error = LauncherError("下载失败。")
        for attempt in 0..<3 {
            do {
                let (temporary, response) = try await session.download(for: request(string))
                defer { try? FileManager.default.removeItem(at: temporary) }
                try check(response)
                try Task.checkCancellation()
                guard try Metadata.digest(temporary, sha256: sha256, sha512: sha512) == hash else {
                    throw LauncherError("文件校验失败：\(destination.lastPathComponent)")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
            }
        }
        throw lastError
    }
}
