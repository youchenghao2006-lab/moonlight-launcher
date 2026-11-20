import Foundation

public struct PackProject: Decodable, Identifiable {
    public let project_id: String
    public let slug: String
    public let title: String
    public let description: String
    public let downloads: Int
    public let icon_url: String?
    public var id: String { project_id }
}
public struct PackRelease: Decodable, Identifiable {
    public struct File: Decodable {
        public let filename: String
        public let url: String
        public let primary: Bool
        public let hashes: [String: String]
    }
    public let id: String
    public let name: String
    public let version_number: String
    public let game_versions: [String]
    public let loaders: [String]
    public let files: [File]
    public var supported: Bool { game_versions.contains(where: GameVersion.supports) && loaders.allSatisfy { ["fabric", "forge", "minecraft"].contains($0) } && files.contains { $0.filename.hasSuffix(".mrpack") } }
}
public enum PackCatalog {
    static func endpoint(_ path: String, _ params: [URLQueryItem] = []) throws -> String {
        var url = URLComponents(string: "https://api.modrinth.com/v2/" + path)!
        url.queryItems = params.isEmpty ? nil : params
        guard let address = url.url?.absoluteString else { throw LauncherError("目录地址无效。") }
        return address
    }
    public static func search(_ query: String, game: String = "", loader: String = "") async throws -> [PackProject] {
        var facets = [["project_type:modpack"]]
        if !game.isEmpty { facets.append(["versions:" + game]) }
        if !loader.isEmpty { facets.append(["categories:" + loader]) }
        let facet = String(decoding: try JSONSerialization.data(withJSONObject: facets), as: UTF8.self)
        let address = try endpoint("search", [.init(name: "query", value: query), .init(name: "facets", value: facet), .init(name: "limit", value: "20"), .init(name: "index", value: "downloads")])
        struct Response: Decodable { let hits: [PackProject] }
        return try JSONDecoder().decode(Response.self, from: await Network.data(address)).hits
    }
    public static func releases(_ project: String) async throws -> [PackRelease] {
        guard project.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw LauncherError("项目编号无效。") }
        return try JSONDecoder().decode([PackRelease].self, from: await Network.data(endpoint("project/\(project)/version")))
    }
}
