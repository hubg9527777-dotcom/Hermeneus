import Foundation
import Darwin

/// Open only owner-controlled regular log files, including on upgraded installs.
public enum PrivateLogFile {
    public static func open(in directory: URL, name: String) throws -> FileHandle {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError() }
        defer { Darwin.close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0 else { throw posixError() }
        guard directoryInfo.st_uid == getuid() else { throw POSIXError(.EPERM) }
        guard fchmod(directoryFD, 0o700) == 0 else { throw posixError() }
        let descriptor = openat(directoryFD, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw posixError() }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                throw POSIXError(.EPERM)
            }
            guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
