import Foundation
import os

/// Fixed-size sample ring shared with a real-time audio thread: no allocation and a very short
/// critical section under an unfair lock on that thread.
final class SampleRing: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private let buf: UnsafeMutablePointer<Float>
    private let cap: Int
    private var r = 0, w = 0, count = 0

    init(capacity: Int) {
        cap = capacity
        buf = .allocate(capacity: capacity)
        buf.initialize(repeating: 0, count: capacity)
    }
    deinit { buf.deallocate() }

    var available: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return count }

    /// Overwrites the oldest samples when full.
    func write(_ src: UnsafePointer<Float>, _ n: Int, stride: Int = 1) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<n {
            buf[w] = src[i * stride]
            w = (w + 1) % cap
            if count == cap { r = (r + 1) % cap } else { count += 1 }
        }
    }

    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let k = min(n, count)
        for i in 0..<k { dst[i] = buf[r]; r = (r + 1) % cap }
        count -= k
        return k
    }

    func skip(_ n: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let k = min(n, count); r = (r + k) % cap; count -= k
    }

    func clear() { os_unfair_lock_lock(&lock); r = 0; w = 0; count = 0; os_unfair_lock_unlock(&lock) }
}

/// Playout buffer for decoded far-end audio.
/// - A short shortfall is concealed (the last 10 ms faded out over ~60 ms) instead of dropping to silence and
///   re-buffering; only ~100 ms without audio un-primes it.
/// - Clock drift and bursts are drained in quiet frames (a quiet frame is written short: inaudible) back to `target`, so the
///   delay never creeps up and is never cut in the middle of speech; a hard trim only catches a huge burst.
/// - `target` grows by 5 ms with every concealed gap (more after a real underrun) and shrinks after ~3 s clean.
final class PlayoutBuffer: @unchecked Sendable {
    private let ring: SampleRing
    private var lock = os_unfair_lock()
    private(set) var target: Int
    let minTarget: Int, maxTarget: Int
    private let rate: Int
    private var primed = false
    private(set) var underruns = 0
    private(set) var trimmed = 0
    private(set) var concealedSamples = 0
    private var cleanPulls = 0
    // Concealment state, render thread only.
    private let last: UnsafeMutablePointer<Float>
    private let lastLen: Int
    private var concealRun = 0

    init(rate: Double) {
        self.rate = Int(rate)
        minTarget = Int(rate * 0.03)   // 30 ms
        maxTarget = Int(rate * 0.12)   // 120 ms
        target = Int(rate * 0.04)      // start at 40 ms
        ring = SampleRing(capacity: Int(rate))
        lastLen = Int(rate * 0.01)     // 10 ms
        last = .allocate(capacity: lastLen)
        last.initialize(repeating: 0, count: lastLen)
    }
    deinit { last.deallocate() }

    /// Audio queue (not real-time): converts outside any lock the render thread uses.
    func push(_ pcm: [Int16]) {
        let f = pcm.map { Float($0) / 32768 }
        let energy = f.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, f.count))
        os_unfair_lock_lock(&lock)
        let tgt = target
        os_unfair_lock_unlock(&lock)
        // Drift: a quiet frame is written short (only its own silence is dropped, never queued speech).
        var n = f.count
        let before = ring.available
        if energy < 1e-5 && before + n > tgt + minTarget / 3 { n -= min(before + n - tgt, n) }
        if n > 0 { f.withUnsafeBufferPointer { ring.write($0.baseAddress!, n) } }
        var live = before + n
        var skip = f.count - n
        if live > tgt + maxTarget { ring.skip(live - tgt); skip += live - tgt; live = tgt }   // a huge burst: cut now
        os_unfair_lock_lock(&lock)
        if !primed && live >= tgt { primed = true }
        trimmed += skip
        os_unfair_lock_unlock(&lock)
    }

    /// Real-time thread: fills `out`, returns how many samples were real audio.
    @discardableResult
    func pull(into out: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let isPrimed = primed, tgt = target
        os_unfair_lock_unlock(&lock)
        guard isPrimed else { for i in 0..<count { out[i] = 0 }; return 0 }
        // After a gap keep concealing until half the target is back: frames lost (not late) would otherwise leave
        // the buffer running on empty, and every small jitter spike would be another gap.
        let n = concealRun > 0 && ring.available < tgt / 2 ? 0 : ring.read(into: out, count)
        if n == count {
            if concealRun > 0 && n > 0 {
                // Fade back in over the first 2 ms after concealment (no click).
                let ramp = min(n, rate / 500)
                for i in 0..<ramp { out[i] *= Float(i) / Float(ramp) }
            }
            concealRun = 0
            remember(out, count)
            os_unfair_lock_lock(&lock)
            cleanPulls += 1
            if cleanPulls > 300 && target > minTarget { target -= minTarget / 6; cleanPulls = 0 }   // ~3 s clean: shrink
            os_unfair_lock_unlock(&lock)
            return n
        }
        // Shortfall: continue the last 10 ms, fading out over ~60 ms, instead of a hard gap.
        // A new gap also deepens the buffer a little: frames over Bluetooth arrive in bursts (gaps of 60-77 ms
        // against a 40 ms target were concealed every few seconds on a real iPhone, 2026-11-22), and only a full
        // 100 ms dropout used to grow the target. It shrinks again after ~3 s without a gap.
        if concealRun == 0 {
            os_unfair_lock_lock(&lock)
            target = min(maxTarget, target + rate / 200)
            os_unfair_lock_unlock(&lock)
        }
        let fadeLen = Float(rate) * 0.06
        for i in n..<count {
            let g = max(0, 1 - Float(concealRun) / fadeLen)
            out[i] = last[(concealRun) % lastLen] * g
            concealRun += 1
        }
        os_unfair_lock_lock(&lock)
        concealedSamples += count - n
        cleanPulls = 0
        if concealRun > rate / 10 {
            // ~100 ms with nothing: really out of audio. Re-buffer a little deeper.
            primed = false
            underruns += 1
            target = min(maxTarget, target + minTarget / 3)
            concealRun = 0
        }
        os_unfair_lock_unlock(&lock)
        return n
    }

    private func remember(_ out: UnsafeMutablePointer<Float>, _ count: Int) {
        let k = min(count, lastLen)
        // Keep the newest 10 ms, in order, so concealment continues the waveform.
        if k == lastLen { last.update(from: out + (count - k), count: k) }
        else { last.update(from: last + k, count: lastLen - k); (last + (lastLen - k)).update(from: out + (count - k), count: k) }
    }

    func reset() { ring.clear(); os_unfair_lock_lock(&lock); primed = false; concealRun = 0; os_unfair_lock_unlock(&lock) }
}

