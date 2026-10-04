import Foundation

/// Canonical and percent-decoded aliases, preserving exact-path precedence at the caller.
struct ArchiveAliasIndex: Sendable {
    private var paths: [String: String] = [:]
    private var ambiguous: Set<String> = []

    init(members: [ArchiveMember]) throws {
        paths.reserveCapacity(members.count)
        for member in members where !member.isDirectory {
            try Task.checkCancellation()
            let canonical = try ArchivePath.canonical(member.path)
            insert(ArchivePath.alias(canonical), path: member.path)
            if let decoded = canonical.removingPercentEncoding,
               (try? ArchivePath.validate(decoded)) != nil {
                insert(ArchivePath.alias(decoded), path: member.path)
            }
        }
    }

    private mutating func insert(_ key: String, path: String) {
        if let previous = paths[key], previous != path {
            ambiguous.insert(key)
        } else {
            paths[key] = path
        }
    }

    func resolve(_ path: String) throws -> String {
        let key = ArchivePath.alias(try ArchivePath.canonical(path))
        guard !ambiguous.contains(key) else {
            throw ArchiveFailure.ambiguousEntry(path)
        }
        return paths[key] ?? path
    }
}
