import Foundation
import CryptoKit

public struct EnvironmentInfo: Sendable, Codable {
    public let hostModel: String
    public let cpuBrand: String
    public let memoryGB: Int
    public let osVersion: String
    public let swiftVersion: String
    public let machineLocale: String
    public let gitCommit: String
    public let fixtureHash: String
    public let fixturePath: String

    public static func capture(fixtureURL: URL) -> EnvironmentInfo {
        let hostModel = getSysctlString("hw.model") ?? "Mac"
        let cpuBrand = getSysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let memBytes = getSysctlInt64("hw.memsize") ?? 0
        let memoryGB = Int(memBytes / (1024 * 1024 * 1024))
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let machineLocale = Locale.current.identifier

        #if swift(>=6.0)
        let swiftVersion = "6.0 Strict"
        #elseif swift(>=5.10)
        let swiftVersion = "5.10"
        #else
        let swiftVersion = "5.x"
        #endif

        let gitCommit = getGitCommit() ?? "local checkout"

        var hashString = "unknown"
        if let data = try? Data(contentsOf: fixtureURL) {
            let digest = SHA256.hash(data: data)
            hashString = digest.map { String(format: "%02x", $0) }.joined()
        }

        return EnvironmentInfo(
            hostModel: hostModel,
            cpuBrand: cpuBrand,
            memoryGB: memoryGB,
            osVersion: osVersion,
            swiftVersion: swiftVersion,
            machineLocale: machineLocale,
            gitCommit: gitCommit,
            fixtureHash: hashString,
            fixturePath: fixtureURL.lastPathComponent
        )
    }

    private static func getSysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func getSysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func getGitCommit() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let commit = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return commit.isEmpty ? nil : commit
        } catch {
            return nil
        }
    }
}
