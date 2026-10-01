import Foundation

/// Conservatively rejects case/Unicode aliases even on case-sensitive volumes, so a
/// package accepted on macOS also has one unambiguous tree on iOS.
struct ArchiveTreePlan {
    struct File { let path: String; let member: ArchiveMember }
    let directories: [String]
    let files: [File]
    init(members: [ArchiveMember]) throws {
        var names: [String: (path: String, directory: Bool)] = [:]
        var explicit = Set<String>()
        var files: [File] = []
        func insert(_ path: String, directory: Bool) throws {
            let key = ArchivePath.alias(path)
            if let previous = names[key] {
                guard previous.path == path, previous.directory && directory else {
                    throw ArchiveFailure.destinationCollision(path)
                }
            } else { names[key] = (path, directory) }
        }
        for member in members {
            let path = try ArchivePath.canonical(member.path, directory: member.isDirectory)
            if member.isDirectory && path.isEmpty { continue }
            guard explicit.insert(ArchivePath.alias(path)).inserted else {
                throw ArchiveFailure.destinationCollision(path)
            }
            let parts = path.split(separator: "/")
            if parts.count > 1 {
                for depth in 1..<parts.count { try insert(parts.prefix(depth).joined(separator: "/"), directory: true) }
            }
            try insert(path, directory: member.isDirectory)
            if !member.isDirectory { files.append(.init(path: path, member: member)) }
        }
        directories = names.values.filter(\.directory).map(\.path).sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a == b ? $0 < $1 : a < b
        }
        self.files = files
    }
}
