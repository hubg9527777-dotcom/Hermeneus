import Foundation
import Security
import Darwin

/// Per-process capability: memory-only, passed to our ASR child via its environment.
/// Old or unrelated port owners cannot authenticate as this app's speech service.
public enum LocalServiceAccess {
    /// Use our own loopback port, so an older external Ollama cannot silently
    /// bypass the bundled security revision. The port is stable for this process.
    public static let ollamaPort: Int = {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        precondition(descriptor >= 0, "Unable to allocate local translation port")
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0, "Unable to bind local translation port")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        precondition(read == 0, "Unable to read local translation port")
        return Int(UInt16(bigEndian: address.sin_port))
    }()
    public static let ollamaBaseURL = URL(string: "http://127.0.0.1:\(ollamaPort)")!
    public static let ollamaSecurityRevision = "0.40.6-hermeneus.3"

    public static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
                     "Unable to generate local IPC capability")
        return Data(bytes).base64EncodedString()
    }()
    public static func authorizeOllama(_ request: inout URLRequest) {
        if let url = request.url, url.scheme == "http", url.host == "127.0.0.1", url.port == ollamaPort {
            authorize(&request)
        }
    }
    public static func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }
}
