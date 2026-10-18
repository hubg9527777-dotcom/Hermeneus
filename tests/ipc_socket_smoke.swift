import Foundation
import Darwin

@main
struct IPCSocketSmoke {
    static func main() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        child.arguments = [CommandLine.arguments[2]]
        child.standardInput = LocalServiceAccess.asrHTTPListener.handle
        child.standardOutput = LocalServiceAccess.asrWSListener.handle
        child.standardError = FileHandle.standardError
        var env = ProcessInfo.processInfo.environment
        env["ASR_HTTP_PORT"] = String(LocalServiceAccess.asrHTTPPort)
        env["ASR_WS_PORT"] = String(LocalServiceAccess.asrWSPort)
        env["HERMENEUS_ASR_TOKEN"] = LocalServiceAccess.token
        child.environment = env
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        var request = URLRequest(url: LocalServiceAccess.asrHTTPURL)
        LocalServiceAccess.authorize(&request)
        request.timeoutInterval = 5
        let (body, response) = try await LocalServiceAccess.session.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        precondition(String(data: body, encoding: .utf8) == "inherited-http")
        var redirect = URLRequest(url: LocalServiceAccess.asrHTTPURL.deletingLastPathComponent().appendingPathComponent("redirect"))
        LocalServiceAccess.authorize(&redirect)
        let (_, redirectResponse) = try await LocalServiceAccess.session.data(for: redirect)
        precondition((redirectResponse as? HTTPURLResponse)?.statusCode == 302, "Local redirect must never be followed")
        var wsRequest = URLRequest(url: LocalServiceAccess.asrWSURL)
        LocalServiceAccess.authorize(&wsRequest)
        let ws = LocalServiceAccess.session.webSocketTask(with: wsRequest)
        ws.resume()
        let message = try await ws.receive()
        guard case .string("inherited-ws") = message else { fatalError("Wrong inherited WebSocket response") }
        ws.cancel(with: .normalClosure, reason: nil)
        var remote = URLRequest(url: URL(string: "https://example.invalid/")!)
        LocalServiceAccess.authorize(&remote)
        precondition(remote.value(forHTTPHeaderField: "Authorization") == nil)
        child.terminate(); child.waitUntilExit()
        for listener in [LocalServiceAccess.asrHTTPListener, LocalServiceAccess.asrWSListener, LocalServiceAccess.ollamaListener] {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = UInt16(listener.port).bigEndian
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(fd)
            precondition(result == -1, "Child exit must not release the parent's port")
        }
        print("PASS: inherited HTTP/WS sockets, no redirects/remote credential, parent port ownership survives child exit")
    }
}
