import Foundation

/// Constructs an unambiguous extraction plan by rejecting case and Unicode aliases.
///
/// Ensures that an archive created or verified on macOS produces a deterministic,
/// non-colliding directory tree on case-insensitive filesystems (such as standard APFS on iOS/macOS).
struct ArchiveTreePlan {
    struct File {
        let path: String
        let member: ArchiveMember
    }

    /// Sorted list of directory paths ordered from shallowest to deepest.
    let directories: [String]

    /// List of non-directory files to extract.
    let files: [File]

    init(members: [ArchiveMember]) throws {
        var names: [String: (path: String, directory: Bool)] = [:]
        var explicit = Set<String>()
        var files: [File] = []

        func insert(_ path: String, directory: Bool) throws {
            let key = ArchivePath.alias(path)
            if let previous = names[key] {
                guard previous.path == path && previous.directory && directory else {
                    throw ArchiveFailure.destinationCollision(path)
                }
            } else {
                names[key] = (path, directory)
            }
        }

        for member in members {
            let path = try ArchivePath.canonical(member.path, directory: member.isDirectory)
            if member.isDirectory && path.isEmpty {
                continue
            }
            guard explicit.insert(ArchivePath.alias(path)).inserted else {
                throw ArchiveFailure.destinationCollision(path)
            }

            let parts = path.split(separator: "/")
            if parts.count > 1 {
                for depth in 1..<parts.count {
                    let parent = parts.prefix(depth).joined(separator: "/")
                    try insert(parent, directory: true)
                }
            }
            try insert(path, directory: member.isDirectory)
            if !member.isDirectory {
                files.append(File(path: path, member: member))
            }
        }

        directories = names.values
            .filter(\.directory)
            .map(\.path)
            .sorted { a, b in
                let depthA = a.split(separator: "/").count
                let depthB = b.split(separator: "/").count
                return depthA == depthB ? a < b : depthA < depthB
            }
        self.files = files
    }
}
