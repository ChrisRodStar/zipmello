import Foundation

extension ArchiveWriter {
    /// Recursively packages a directory without its parent. Hidden files are retained by
    /// default because installation/download trees may contain required metadata.
    public func create(at destination: URL, directory: URL, skipHiddenFiles: Bool = false,
                       compression: ArchiveCompression = .stored, limits: ArchiveLimits = .exporting,
                       tuning: ArchiveTuning = .init(), progress: ArchiveProgressHandler? = nil) throws {
        try limits.validate()
        try Task.checkCancellation()
        guard directory.isFileURL else { throw ArchiveFailure.invalidSource(directory.absoluteString) }
        let root = directory.standardizedFileURL
        let output = destination.standardizedFileURL
        // Prevent enumeration of our own output/staging within the input tree.
        guard !output.path.hasPrefix(root.path + "/") else { throw ArchiveFailure.invalidSource("Output is inside source directory") }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ArchiveFailure.invalidSource(root.path) }
        var assets: [ArchiveAsset] = []
        func visit(_ url: URL, prefix: String) throws {
            try Task.checkCancellation()
            let children = try FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: skipHiddenFiles ? [.skipsHiddenFiles] : []).sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
            for child in children {
                try Task.checkCancellation()
                guard assets.count < limits.maximumEntries else { throw ArchiveFailure.tooManyEntries }
                let path = prefix + child.lastPathComponent
                let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ArchiveFailure.unsupportedEntry(path) }
                if values.isDirectory == true {
                    assets.append(.init(path: path + "/", content: .directory))
                    try visit(child, prefix: path + "/")
                } else if values.isRegularFile == true {
                    assets.append(.init(path: path, content: .file(child), compression: compression))
                } else { throw ArchiveFailure.unsupportedEntry(path) }
            }
        }
        try visit(root, prefix: "")
        try create(at: destination, assets: assets, limits: limits, tuning: tuning, progress: progress)
    }
}
