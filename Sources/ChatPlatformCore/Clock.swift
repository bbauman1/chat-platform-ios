import Foundation

/// Time, injectable so tests don't wait.
public protocol ChatClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: ChatClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Jittered exponential backoff: 0.5 s doubling to 30 s.
struct Backoff: Sendable {
    var base: TimeInterval = 0.5
    var cap: TimeInterval = 30
    private(set) var attempt = 0

    init(base: TimeInterval = 0.5, cap: TimeInterval = 30) {
        self.base = base
        self.cap = cap
    }

    mutating func next(random: Double = Double.random(in: 0.5...1)) -> TimeInterval {
        let delay = min(cap, base * pow(2, Double(attempt)))
        attempt = min(attempt + 1, 16)
        return delay * random
    }

    mutating func reset() { attempt = 0 }
}
