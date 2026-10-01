import Foundation

extension ArchiveWriter {
    /// Recursively packages a local directory without prepending its parent directory name.
    ///
    /// Hidden files and dot-files are retained by default because installation trees, application bundles,
    /// and download directories may contain essential metadata.
    ///
    /// - Parameters:
    ///   - destination: Target archive file URL. Must not already exist.
    ///   - directory: Source directory to recursively traverse and package.
    ///   - skipHiddenFiles: When `true`, dotfiles and hidden entries are excluded. Defaults to `false`.
    ///   - compression: Compression algorithm applied to regular files (.stored or .deflate).
    ///   - limits: Security constraints restricting entry counts, sizes, and expansion ratios.
    ///   - tuning: I/O buffer sizing and compression level configuration.
    ///   - progress: Optional callback receiving processing milestones.
    public func create(
        at destination: URL,
        directory: URL,
        skipHiddenFiles: Bool = false,
        compression: ArchiveCompression = .stored,
        limits: ArchiveLimits = .exporting,
        tuning: ArchiveTuning = .init(),
        progress: ArchiveProgressHandler? = nil
    ) throws {
        try limits.validate()
        try Task.checkCancellation()

        guard directory.isFileURL else {
            throw ArchiveFailure.invalidSource(directory.absoluteString)
        }

        let rootURL = directory.standardizedFileURL
        let outputURL = destination.standardizedFileURL

        // Prevent recursive archiving of the destination/staging directory within the input tree.
        guard !outputURL.path.hasPrefix(rootURL.path + "/") else {
            throw ArchiveFailure.invalidSource("Output is inside source directory")
        }

        let rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ArchiveFailure.invalidSource(rootURL.path)
        }

        var assets: [ArchiveAsset] = []

        func visit(_ currentURL: URL, prefix: String) throws {
            try Task.checkCancellation()

            let children = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: skipHiddenFiles ? [.skipsHiddenFiles] : []
            ).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            for child in children {
                try Task.checkCancellation()
                guard assets.count < limits.maximumEntries else {
                    throw ArchiveFailure.tooManyEntries
                }

                let entryPath = prefix + child.lastPathComponent
                let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])

                // Symbolic links are strictly rejected to prevent out-of-tree leaks or zip-slip attacks.
                guard values.isSymbolicLink != true else {
                    throw ArchiveFailure.unsupportedEntry(entryPath)
                }

                if values.isDirectory == true {
                    assets.append(.init(path: entryPath + "/", content: .directory))
                    try visit(child, prefix: entryPath + "/")
                } else if values.isRegularFile == true {
                    assets.append(.init(path: entryPath, content: .file(child), compression: compression))
                } else {
                    throw ArchiveFailure.unsupportedEntry(entryPath)
                }
            }
        }

        try visit(rootURL, prefix: "")
        try create(at: destination, assets: assets, limits: limits, tuning: tuning, progress: progress)
    }
}
