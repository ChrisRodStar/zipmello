import Foundation
import ZIPFoundation

struct ValidatedArchiveIndex: Sendable {
    var index: [String: ArchiveReadDescriptor] = [:]
    var members: [ArchiveMember] = []
    init(_ opened: Archive, bytes: UInt64, limits: ArchiveLimits) throws {
        var expanded: UInt64 = 0
        var seen = Set<String>()
        let count = opened.declaredEntryCount
        guard count <= UInt64(limits.maximumEntries) else { throw ArchiveFailure.tooManyEntries }
        // Every central record needs at least 46 physical bytes. Reject forged counts
        // before reserving index storage, even when a caller chooses a very high limit.
        guard count <= bytes / 46 else { throw ArchiveFailure.invalidSource("Incomplete directory") }
        index.reserveCapacity(Int(count)); members.reserveCapacity(Int(count)); seen.reserveCapacity(Int(count))
        for entry in opened {
            try Task.checkCancellation()
            guard members.count < limits.maximumEntries else { throw ArchiveFailure.tooManyEntries }
            guard entry.type != .symlink else { throw ArchiveFailure.unsupportedEntry(entry.path) }
            let path = entry.path
            _ = try ArchivePath.canonical(path, directory: entry.type == .directory)
            guard seen.insert(path).inserted else { throw ArchiveFailure.duplicatePath(path) }
            guard entry.uncompressedSize <= limits.maximumEntryBytes else { throw ArchiveFailure.memberTooLarge(path) }
            let sum = expanded.addingReportingOverflow(entry.uncompressedSize)
            guard !sum.overflow, sum.partialValue <= limits.maximumExpandedBytes else { throw ArchiveFailure.expandedArchiveTooLarge }
            expanded = sum.partialValue
            if entry.type == .file {
                let descriptor = try opened.descriptor(for: entry)
                guard descriptor.offset <= bytes, descriptor.compressedBytes <= bytes - descriptor.offset else {
                    throw ArchiveFailure.invalidSource(path)
                }
                index[path] = descriptor
            }
            members.append(.init(path: path, uncompressedBytes: entry.uncompressedSize,
                                 compressedBytes: entry.compressedSize, isDirectory: entry.type == .directory))
        }
        guard UInt64(members.count) == count else { throw ArchiveFailure.invalidSource("Incomplete directory") }
    }
}
