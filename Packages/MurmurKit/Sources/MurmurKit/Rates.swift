import Foundation

/// A token bucket shared by every connection in a session. Zero means unlimited.
final class RateLimiter {
    var bytesPerSecond: Int = 0 {
        didSet { tokens = min(tokens, Double(max(bytesPerSecond, 1))) }
    }
    private var tokens: Double = 0
    private var last = DispatchTime.now().uptimeNanoseconds

    /// Takes `bytes` from the bucket and returns how long to wait before the next transfer.
    func consume(_ bytes: Int) -> TimeInterval {
        guard bytesPerSecond > 0 else { return 0 }
        refill()
        tokens -= Double(bytes)
        if tokens >= 0 { return 0 }
        return min(-tokens / Double(bytesPerSecond), 5)
    }

    /// How long until the bucket is no longer in debt.
    var delay: TimeInterval {
        guard bytesPerSecond > 0 else { return 0 }
        refill()
        return tokens >= 0 ? 0 : min(-tokens / Double(bytesPerSecond), 5)
    }

    private func refill() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - last) / 1_000_000_000
        last = now
        // Allow a burst of up to a quarter second so the limit isn't exceeded in spikes.
        tokens = min(tokens + elapsed * Double(bytesPerSecond), Double(bytesPerSecond) / 4)
    }
}

/// Bytes per second averaged over the last few seconds.
struct RateMeter {
    private var samples = [Int64](repeating: 0, count: 5)
    private var slot = 0
    private var current: Int64 = 0
    private(set) var total: Int64 = 0

    mutating func add(_ bytes: Int) {
        current += Int64(bytes)
        total += Int64(bytes)
    }

    /// Call once a second.
    mutating func tick() {
        samples[slot] = current
        slot = (slot + 1) % samples.count
        current = 0
    }

    var rate: Int64 { samples.reduce(0, +) / Int64(samples.count) }
}
