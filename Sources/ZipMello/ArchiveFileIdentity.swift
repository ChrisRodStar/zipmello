import Foundation
import Darwin

struct ArchiveFileIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ url: URL) throws {
        guard url.isFileURL else { throw ArchiveFailure.invalidSource(url.absoluteString) }
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw ArchiveFailure.invalidSource(url.path) }
        device = value.st_dev; inode = value.st_ino; bytes = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}
