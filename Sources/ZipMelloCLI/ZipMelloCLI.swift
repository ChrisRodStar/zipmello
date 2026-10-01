import Foundation
import ZipMello

@main
struct ZipMelloCLI {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "inspect" where args.count == 2:
            let reader = try await ArchiveReader.open(URL(filePath: args[1]))
            for member in try await reader.listing() {
                print("\(member.uncompressedBytes)\t\(member.path)")
            }
            await reader.close()
        case "read" where args.count == 4:
            let reader = try await ArchiveReader.open(URL(filePath: args[1]))
            try await reader.extract(args[2], to: URL(filePath: args[3]))
            await reader.close()
        case "cbz" where args.count == 3:
            let directory = URL(filePath: args[1], directoryHint: .isDirectory)
            try await ArchiveWriter().create(at: URL(filePath: args[2]), directory: directory, skipHiddenFiles: true)
        case "extract" where args.count == 3:
            let reader = try await ArchiveReader.open(URL(filePath: args[1]))
            try await reader.extractAll(to: URL(filePath: args[2]))
            await reader.close()
        case "validate" where args.count == 2:
            let reader = try await ArchiveReader.open(URL(filePath: args[1]))
            try await reader.validate()
            await reader.close()

        default:
            print("Usage: zipmello inspect ZIP | read ZIP ENTRY DESTINATION | cbz DIRECTORY DESTINATION | extract ZIP DIRECTORY | validate ZIP")
        }
    }
}
