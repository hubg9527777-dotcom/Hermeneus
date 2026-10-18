import Foundation
import Darwin

@main
struct PrivateLogSecurity {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let log = directory.appendingPathComponent("speech.log")
        try Data("existing\n".utf8).write(to: log)
        let handle = try PrivateLogFile.open(in: directory, name: "speech.log")
        try handle.write(contentsOf: Data("appended\n".utf8)); try handle.close()
        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        }
        let directoryMode = try mode(directory); precondition(directoryMode == 0o700)
        let logMode = try mode(log); precondition(logMode == 0o600)
        let logText = try String(contentsOf: log, encoding: .utf8); precondition(logText == "existing\nappended\n")
        let target = root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        let linked = directory.appendingPathComponent("linked.log")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        do { let file = try PrivateLogFile.open(in: directory, name: "linked.log"); try file.close(); fatalError("symlink accepted") }
        catch {}
        let hardlink = directory.appendingPathComponent("hard.log")
        precondition(link(target.path, hardlink.path) == 0)
        do { let file = try PrivateLogFile.open(in: directory, name: "hard.log"); try file.close(); fatalError("hard link accepted") }
        catch {}
        let targetText = try String(contentsOf: target, encoding: .utf8); precondition(targetText == "untouched")
        do { let file = try PrivateLogFile.open(in: directory, name: "../target"); try file.close(); fatalError("path traversal accepted") }
        catch {}
        let directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
        do { let file = try PrivateLogFile.open(in: directoryLink, name: "other.log"); try file.close(); fatalError("directory link accepted") }
        catch {}
        print("PASS: private log permissions, append, symlink/hard-link and traversal rejection")
    }
}
