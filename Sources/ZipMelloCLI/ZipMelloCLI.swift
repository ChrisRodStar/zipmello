import Foundation
import ZipMello

@main
struct ZipMelloCLI {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        switch command {
        case "list", "ls", "inspect":
            guard args.count >= 2 else { printUsage(); return }
            let zipPath = args[1]
            let reader = try await ArchiveReader.open(URL(filePath: zipPath))
            let members = try await reader.listing()
            
            print(String(repeating: "-", count: 70))
            print(String(format: "%-12@ %-12@ %-8@ %@", "SIZE", "COMPRESSED", "RATIO", "PATH"))
            print(String(repeating: "-", count: 70))

            var totalOriginal: UInt64 = 0
            var totalCompressed: UInt64 = 0

            for member in members {
                totalOriginal += member.uncompressedBytes
                totalCompressed += member.compressedBytes
                let ratio: String
                if member.uncompressedBytes > 0 {
                    let r = (1.0 - Double(member.compressedBytes) / Double(member.uncompressedBytes)) * 100.0
                    ratio = String(format: "%.0f%%", r)
                } else {
                    ratio = "0%"
                }
                
                let origStr = formatBytes(member.uncompressedBytes)
                let compStr = formatBytes(member.compressedBytes)
                print(String(format: "%-12@ %-12@ %-8@ %@", origStr, compStr, ratio, member.path))
            }

            print(String(repeating: "-", count: 70))
            let overallRatio = totalOriginal > 0 ? (1.0 - Double(totalCompressed) / Double(totalOriginal)) * 100.0 : 0.0
            print(String(format: "Total Entries: %d | Total Size: %@ | Compressed: %@ (Saved %.1f%%)",
                         members.count, formatBytes(totalOriginal), formatBytes(totalCompressed), overallRatio))
            await reader.close()

        case "info":
            guard args.count >= 2 else { printUsage(); return }
            let zipPath = args[1]
            let fileURL = URL(filePath: zipPath)
            let reader = try await ArchiveReader.open(fileURL)
            let members = try await reader.listing()

            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let totalUncompressed = members.reduce(UInt64(0)) { $0 + $1.uncompressedBytes }
            let files = members.filter { !$0.isDirectory }
            let dirs = members.filter { $0.isDirectory }

            print("=== ZipMello Archive Information ===")
            print("Archive Path:         \(zipPath)")
            print("Physical Size:        \(formatBytes(UInt64(fileSize)))")
            print("Total Entry Count:    \(members.count) (\(files.count) files, \(dirs.count) directories)")
            print("Total Uncompressed:   \(formatBytes(totalUncompressed))")
            if totalUncompressed > 0 {
                let ratio = (1.0 - Double(fileSize) / Double(totalUncompressed)) * 100.0
                print("Compression Ratio:    \(String(format: "%.1f%%", ratio)) saved")
            }
            await reader.close()

        case "extract":
            guard args.count >= 3 else { printUsage(); return }
            let zipPath = args[1]
            let destPath = args[2]
            print("Extracting \(zipPath) to \(destPath)...")
            let start = ContinuousClock.now
            try await ArchiveReader.extractAll(from: URL(filePath: zipPath), to: URL(filePath: destPath))
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1e15 * 1000
            print("Extraction complete in \(String(format: "%.2f", ms)) ms.")

        case "create", "zip", "cbz":
            guard args.count >= 3 else { printUsage(); return }
            let sourceDir = args[1]
            let destZip = args[2]
            print("Creating archive \(destZip) from \(sourceDir)...")
            let start = ContinuousClock.now
            try await ArchiveWriter.create(at: URL(filePath: destZip), from: URL(filePath: sourceDir), compression: .deflate)
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1e15 * 1000
            print("Archive created successfully in \(String(format: "%.2f", ms)) ms.")

        case "validate":
            guard args.count >= 2 else { printUsage(); return }
            let zipPath = args[1]
            print("Validating CRC32 checksums for \(zipPath)...")
            let reader = try await ArchiveReader.open(URL(filePath: zipPath))
            try await reader.validate()
            await reader.close()
            print("Validation PASSED. All entry checksums and bounds are valid.")

        default:
            printUsage()
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0)) }
        return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
    }

    private static func printUsage() {
        print("""
        ZipMello CLI - High-Speed Native Swift ZIP & CBZ Tool

        USAGE:
            zipmello <subcommand> [options]

        SUBCOMMANDS:
            list <archive.zip>             List archive entries with sizes and compression ratios
            info <archive.zip>             Show metadata summary for an archive
            extract <archive.zip> <dir>    Extract entire archive into target directory
            create <dir> <output.zip>      Create a DEFLATE compressed archive from a directory
            validate <archive.zip>         Perform streaming CRC32 validation on all entries
        """)
    }
}
