import Foundation

public enum PackArchive {
    // Check the central directory and local names before handing the ZIP to ditto.
    // Reject links, ambiguous paths and ZIP64 rather than allowing extraction outside staging.
    public static func validate(_ file: URL) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        func fail() -> LauncherError { LauncherError("整合包压缩文件无效、不安全，或使用了暂不支持的 ZIP 格式。") }
        func number(_ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, offset + count <= data.count else { throw fail() }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        func checkExtras(_ start: Int, _ length: Int) throws {
            var offset = start
            while offset < start + length {
                guard offset + 4 <= start + length else { throw fail() }
                let kind = try number(offset, 2), size = Int(try number(offset + 2, 2))
                // Alternate filenames, ZIP64 and legacy Unix link records are unsupported.
                guard ![UInt64(0x7075), 0x0001, 0x000d, 0x756e].contains(kind), offset + 4 + size <= start + length else { throw fail() }
                offset += 4 + size
            }
        }
        guard data.count >= 22 else { throw fail() }
        var end: Int?
        for pos in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try number(pos, 4) == 0x06054b50, pos + 22 + Int(try number(pos + 20, 2)) == data.count { end = pos; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw fail() }
        let count = Int(try number(end + 10, 2))
        guard count > 0, count < 50_000, try number(end + 8, 2) == count else { throw fail() }
        let size = Int(try number(end + 12, 4)), start = Int(try number(end + 16, 4))
        guard start + size == end else { throw fail() }
        var pos = start, total: UInt64 = 0, paths = Set<String>(), files = Set<String>()
        for _ in 0..<count {
            guard try number(pos, 4) == 0x02014b50 else { throw fail() }
            let flags = try number(pos + 8, 2), method = try number(pos + 10, 2)
            let length = Int(try number(pos + 28, 2)), extra = Int(try number(pos + 30, 2)), comment = Int(try number(pos + 32, 2))
            let mode = try number(pos + 38, 4) >> 16, local = Int(try number(pos + 42, 4))
            guard flags & 1 == 0, [UInt64(0), 8].contains(method), [UInt64(0), 0x4000, 0x8000].contains(mode & 0xf000),
                  pos + 46 + length + extra + comment <= end, local < start else { throw fail() }
            let bytes = data.subdata(in: pos + 46..<pos + 46 + length)
            guard let name = String(data: bytes, encoding: .utf8), !name.isEmpty,
                  !name.split(separator: "/", omittingEmptySubsequences: false).dropLast().contains(""),
                  !name.split(separator: "/").contains(".") else { throw fail() }
            _ = try Metadata.safePath(name, under: URL(fileURLWithPath: "/private/tmp/pack-check"))
            let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(normalized).inserted else { throw fail() }
            if !name.hasSuffix("/") { files.insert(normalized) }
            guard try number(local, 4) == 0x04034b50, try number(local + 26, 2) == length,
                  local + 30 + length <= start,
                  data.subdata(in: local + 30..<local + 30 + length) == bytes,
                  try number(local + 6, 2) == flags, try number(local + 8, 2) == method else { throw fail() }
            let localExtra = Int(try number(local + 28, 2))
            try checkExtras(pos + 46 + length, extra)
            try checkExtras(local + 30 + length, localExtra)
            let payload = local + 30 + length + localExtra
            guard payload + Int(try number(pos + 20, 4)) <= start else { throw fail() }
            total += try number(pos + 24, 4)
            guard total <= 8_000_000_000 else { throw LauncherError("整合包解压后超过 8 GB，暂不支持导入。") }
            pos += 46 + length + extra + comment
        }
        guard pos == end else { throw fail() }
        for path in paths {
            var parts = path.split(separator: "/").map(String.init)
            while parts.count > 1 { parts.removeLast(); if files.contains(parts.joined(separator: "/")) { throw fail() } }
        }
    }

    static func extract(_ file: URL, to destination: URL) async throws {
        try validate(file)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try await Installer.tool("/usr/bin/ditto", ["-x", "-k", "--noqtn", file.path, destination.path])
        try checkExtracted(destination)
    }

    private static func checkExtracted(_ destination: URL) throws {
        if let entries = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in entries {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw LauncherError("整合包包含符号链接，已停止导入。") }
            }
        }
    }
}
