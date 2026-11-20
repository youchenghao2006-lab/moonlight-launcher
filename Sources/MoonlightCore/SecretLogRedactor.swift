import Foundation

// Buffer complete lines so a credential split between pipe reads cannot escape redaction.
public struct SecretLogRedactor {
    private let secrets: [String]
    private var pending = Data()
    private var discarding = false
    public init(secrets: [String]) { self.secrets = Array(Set(secrets.filter { !$0.isEmpty })).sorted { $0.count > $1.count } }
    public mutating func consume(_ data: Data, finish: Bool = false) -> Data {
        var output = Data()
        for byte in data {
            if discarding {
                if byte == 10 { discarding = false }
                continue
            }
            pending.append(byte)
            if byte == 10 { output.append(redacted()); pending.removeAll(keepingCapacity: true) }
            else if pending.count > 1_048_576 {
                output.append(Data("[输出行过长，已省略]\n".utf8)); pending.removeAll(keepingCapacity: true); discarding = true
            }
        }
        if finish && !pending.isEmpty { output.append(redacted()); pending.removeAll() }
        return output
    }
    private func redacted() -> Data {
        var text = String(decoding: pending, as: UTF8.self)
        for secret in secrets { text = text.replacingOccurrences(of: secret, with: "[登录凭证已隐藏]") }
        return Data(text.utf8)
    }
}
