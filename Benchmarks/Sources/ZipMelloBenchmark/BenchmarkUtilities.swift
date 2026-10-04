import Foundation
import CryptoKit

/// Deterministic 64-bit PRNG (SplitMix64) for reproducible workload permutations independent of Swift's randomized hash seed.
public struct DeterministicPRNG: Sendable {
    private var state: UInt64

    public init(seed: UInt64 = 0x123456789ABCDEF) {
        self.state = seed
    }

    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(nextUInt64() % UInt64(upperBound))
    }

    public mutating func shuffled<T>(_ array: [T]) -> [T] {
        var copy = array
        guard copy.count > 1 else { return copy }
        for i in (1..<copy.count).reversed() {
            let j = nextInt(upperBound: i + 1)
            copy.swapAt(i, j)
        }
        return copy
    }
}

/// Deterministic natural sort comparator using explicit POSIX locale for cross-machine reproducibility.
public func deterministicNaturalSort(_ a: String, _ b: String) -> Bool {
    let result = a.compare(b, options: [.numeric, .widthInsensitive], range: nil, locale: Locale(identifier: "en_US_POSIX"))
    if result == .orderedSame {
        return a < b
    }
    return result == .orderedAscending
}

/// A synchronization barrier to release concurrent worker tasks simultaneously without scheduling jitter.
public actor ConcurrencyGate {
    private let targetCount: Int
    private var arrived: Int = 0
    private var isReleased: Bool = false
    private var workerContinuations: [CheckedContinuation<Void, Never>] = []
    private var readyContinuation: CheckedContinuation<Void, Never>?

    public init(count: Int) {
        self.targetCount = count
    }

    /// Called by each worker task to arrive and wait at the barrier.
    public func wait() async {
        if isReleased { return }
        arrived += 1
        if arrived == targetCount, let ready = readyContinuation {
            readyContinuation = nil
            ready.resume()
        }
        await withCheckedContinuation { continuation in
            workerContinuations.append(continuation)
        }
    }

    /// Waits until all `targetCount` tasks have arrived at the barrier, then releases them all simultaneously.
    public func releaseWhenReady() async {
        if arrived < targetCount {
            await withCheckedContinuation { continuation in
                readyContinuation = continuation
            }
        }
        isReleased = true
        let toResume = workerContinuations
        workerContinuations.removeAll()
        for c in toResume {
            c.resume()
        }
    }
}

/// Computes SHA-256 hash over an array of data chunks outside the timer for external verification.
public func computeSHA256Digest(dataChunks: [Data]) -> String {
    var hasher = SHA256()
    for chunk in dataChunks {
        hasher.update(data: chunk)
    }
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
}
