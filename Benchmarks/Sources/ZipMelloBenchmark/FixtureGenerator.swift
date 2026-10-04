import Foundation
import ZipMello

public enum FixtureGenerator {
    public static func ensureFixture(
        at targetURL: URL,
        comicSourceDir: URL,
        compression: ArchiveCompression = .stored
    ) async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: targetURL.path) {
            return targetURL
        }

        try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Read available Pepper & Carrot page images
        let files = try fm.contentsOfDirectory(at: comicSourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { deterministicNaturalSort($0.lastPathComponent, $1.lastPathComponent) }

        guard !files.isEmpty else {
            throw NSError(domain: "FixtureGenerator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No comic pages found in \(comicSourceDir.path)"
            ])
        }

        var assets: [ArchiveAsset] = []

        // Cover page (page_000.jpg)
        let coverData = try Data(contentsOf: files[0])
        assets.append(ArchiveAsset(path: "page_000.jpg", content: .bytes(coverData), compression: compression))

        // Expand to 80 pages by cycling through the real pages
        for i in 1...79 {
            let sourceFile = files[i % files.count]
            let pageData = try Data(contentsOf: sourceFile)
            let pagePath = String(format: "page_%03d.jpg", i)
            assets.append(ArchiveAsset(path: pagePath, content: .bytes(pageData), compression: compression))

            // Add sidecar description files for every 5th page to simulate real reader sidecars
            if i % 5 == 0 {
                let descData = Data("Scene description for page \(i) of Pepper & Carrot Episode 1.\n".utf8)
                let descPath = String(format: "page_%03d.desc.txt", i)
                assets.append(ArchiveAsset(path: descPath, content: .bytes(descData), compression: compression))
            }
        }

        // Add standard ComicInfo.xml
        let comicInfoXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
          <Title>The Potion of Flight</Title>
          <Series>Pepper &amp; Carrot</Series>
          <Number>1</Number>
          <Count>1</Count>
          <Volume>1</Volume>
          <Summary>Pepper tries to brew a potion of flight for Carrot.</Summary>
          <Writer>David Revoy</Writer>
          <Penciller>David Revoy</Penciller>
          <Inker>David Revoy</Inker>
          <Colorist>David Revoy</Colorist>
          <PageCount>80</PageCount>
        </ComicInfo>
        """
        assets.append(ArchiveAsset(path: "ComicInfo.xml", content: .bytes(Data(comicInfoXML.utf8)), compression: compression))

        // Create the CBZ deterministically
        let writer = ArchiveWriter()
        try await writer.create(at: targetURL, assets: assets)

        return targetURL
    }
}
