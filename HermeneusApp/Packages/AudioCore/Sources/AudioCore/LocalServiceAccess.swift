import Foundation
import Security
import Darwin

/// A parent-owned listening socket. It stays open for the app's lifetime, so a
/// crashed child cannot release the port for an unrelated process to impersonate.
public final class LocalServiceListener: @unchecked Sendable {
    public let handle: FileHandle
    public let port: Int

    fileprivate init() {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        precondition(descriptor >= 0, "Unable to allocate local service socket")
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0 && listen(descriptor, 16) == 0, "Unable to listen for local service")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        precondition(read == 0, "Unable to read local service port")
        // Foundation explicitly duplicates these handles onto the child's standard
        // descriptors. Do not let unrelated descendants inherit the original FD.
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        port = Int(UInt16(bigEndian: address.sin_port))
    }
}

private final class LocalRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum LocalServiceAccess {
    public static let ollamaListener = LocalServiceListener()
    public static let asrHTTPListener = LocalServiceListener()
    public static let asrWSListener = LocalServiceListener()
    public static var ollamaPort: Int { ollamaListener.port }
    public static var asrHTTPPort: Int { asrHTTPListener.port }
    public static var asrWSPort: Int { asrWSListener.port }
    public static var ollamaBaseURL: URL { URL(string: "http://127.0.0.1:\(ollamaPort)")! }
    public static var asrHTTPURL: URL { URL(string: "http://127.0.0.1:\(asrHTTPPort)/inference")! }
    public static var asrWSURL: URL { URL(string: "ws://127.0.0.1:\(asrWSPort)/ws/asr")! }
    public static let ollamaSecurityRevision = "0.40.6-hermeneus.6"
    private static let redirectBlocker = LocalRedirectBlocker()
    /// Local audio/text must not follow redirects or inherit proxy/cookie state.
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: redirectBlocker, delegateQueue: nil)
    }()
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
        guard let url = request.url, url.host == "127.0.0.1", url.user == nil, url.password == nil,
              (url.scheme == "http" && [ollamaPort, asrHTTPPort].contains(url.port ?? -1)) ||
              (url.scheme == "ws" && url.port == asrWSPort) else { return }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }
}
