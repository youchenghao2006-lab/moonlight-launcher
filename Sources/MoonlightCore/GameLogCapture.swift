import Foundation

public final class GameLogCapture: @unchecked Sendable {
    public let pipe = Pipe()
    private let lock = NSLock()
    private let handle: FileHandle
    private var redactor: SecretLogRedactor
    private var closed = false
    public init(file: URL, secrets: [String]) throws {
        handle = try FileHandle(forWritingTo: file)
        redactor = SecretLogRedactor(secrets: secrets)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] reader in
            guard let self else { return }
            self.receive(reader)
        }
    }
    private func receive(_ reader: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let data = reader.availableData
        try? handle.write(contentsOf: redactor.consume(data, finish: data.isEmpty))
        if data.isEmpty { closed = true; reader.readabilityHandler = nil; try? handle.close() }
    }
    // Call after the child exits (or fails to start), so draining cannot wait on it.
    public func finish() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let remaining = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        try? handle.write(contentsOf: redactor.consume(remaining, finish: true))
        closed = true
        try? handle.close()
        try? pipe.fileHandleForReading.close()
    }
    deinit { finish() }
}
