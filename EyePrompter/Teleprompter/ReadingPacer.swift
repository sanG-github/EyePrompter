import Foundation

/// Turns the irregular word index coming from speech recognition into smooth,
/// continuous motion — like an auto-scrolling teleprompter whose speed is the
/// reader's own pace.
///
/// * The reader's pace (words/s) is estimated from how fast the recognised
///   position advances over the last few seconds.
/// * The text moves with a *velocity*; recognition results only nudge that
///   velocity (a small proportional correction), so bursts of words never
///   make it jump, and it keeps flowing between partial results.
/// * Recognition lags speech by ~0.4 s, so while the reader is talking the
///   display leads the last recognised word by `rate × latency` (capped).
/// * When the reader pauses, it eases to a stop; re-reading glides back.
struct ReadingPacer {
    private(set) var position: Double = 0      // fractional word index shown
    private(set) var velocity: Double = 0      // words / s
    private(set) var rate: Double = 2.6        // estimated reading pace, words / s
    private(set) var target = 0                // last recognised word index

    /// Recogniser delay behind the voice, seconds.
    var latency = 0.4
    /// How long without progress before we consider the reader paused.
    var pauseAfter = 1.3

    private var lastAdvance = -100.0
    private var samples: [(t: Double, w: Int)] = []

    var wordsPerMinute: Int { Int((rate * 60).rounded()) }

    mutating func reset(to index: Int) {
        position = Double(index)
        velocity = 0
        target = index
        samples = []
        lastAdvance = -100
    }

    mutating func update(target newTarget: Int, now: Double) {
        let delta = newTarget - target
        target = newTarget
        if delta > 0, delta <= 15 {
            if now - lastAdvance > pauseAfter + 0.3 { samples = [] } // new phrase after a pause
            samples.append((now, newTarget))
            samples.removeAll { now - $0.t > 6 }
            if let first = samples.first, now - first.t >= 1.2 {
                let instant = Double(newTarget - first.w) / (now - first.t)
                rate = min(8, max(1.2, rate * 0.6 + instant * 0.4))
            }
            lastAdvance = now
        } else if delta != 0 {
            // Re-read, manual jump or skip: restart the pace window.
            samples = []
            lastAdvance = delta > 0 ? now : -100
            if abs(Double(newTarget) - position) > 12 {
                position = Double(newTarget)
                velocity = 0
            }
        }
    }

    mutating func step(dt: Double, now: Double) {
        guard dt > 0 else { return }
        let active = now - lastAdvance < pauseAfter
        let lead = active ? min(1.5, rate * latency) : 0
        let error = Double(target) + lead - position
        var desired = active ? rate + 1.6 * error : 1.6 * error
        desired = min(max(desired, -6), max(10, rate * 3))
        // First-order response: smooth acceleration, no sudden speed changes.
        velocity += (desired - velocity) * (1 - exp(-dt / 0.25))
        position += velocity * dt
        // Never run far ahead of what was actually heard. Partial results can be
        // ~1 s apart, so allow about a second of reading beyond the last word,
        // slowing down smoothly as that limit approaches instead of stopping dead.
        let limit = Double(target) + 1 + rate * 0.9
        let room = limit - position
        if room < 1, velocity > 0 { velocity *= max(0, room) }
        if position > limit { position = limit }
        if position < Double(target) - 20 { position = Double(target) - 20 }
        if position < 0 { position = 0; velocity = max(0, velocity) }
    }
}
