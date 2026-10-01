import Foundation
import Darwin

/// Snapshot of filesystem inode, device, size, and modification timestamps for an archive file.
/// Used to guard against time-of-check-to-time-of-use (TOCTOU) file replacement during reading or session pooling.
struct ArchiveFileIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    /// Captures the filesystem identity of a regular file at the given URL using `lstat`.
    init(_ url: URL) throws {
        guard url.isFileURL else {
            throw ArchiveFailure.invalidSource(url.absoluteString)
        }
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            throw ArchiveFailure.invalidSource(url.path)
        }
        self.init(stat: value)
    }

    /// Captures the filesystem identity of an open file descriptor using `fstat`.
    init(fileDescriptor: Int32) throws {
        var value = stat()
        guard fstat(fileDescriptor, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            throw ArchiveFailure.invalidSource("Invalid file descriptor \(fileDescriptor)")
        }
        self.init(stat: value)
    }

    /// Initializes from a resolved Darwin `stat` buffer.
    init(stat: stat) {
        self.device = stat.st_dev
        self.inode = stat.st_ino
        self.bytes = stat.st_size
        self.modifiedSeconds = stat.st_mtimespec.tv_sec
        self.modifiedNanoseconds = stat.st_mtimespec.tv_nsec
        self.changedSeconds = stat.st_ctimespec.tv_sec
        self.changedNanoseconds = stat.st_ctimespec.tv_nsec
    }

    /// Verifies that the file at the specified URL matches this recorded identity.
    func matches(url: URL) -> Bool {
        guard let current = try? ArchiveFileIdentity(url) else {
            return false
        }
        return self == current
    }

    /// Verifies that the open file descriptor matches this recorded identity.
    func matches(fileDescriptor: Int32) -> Bool {
        guard let current = try? ArchiveFileIdentity(fileDescriptor: fileDescriptor) else {
            return false
        }
        return self == current
    }
}
