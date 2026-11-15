import Foundation

/// Translation is deliberately behind a protocol: the offline MT choice is the hardest
/// part of this app and the only realistic answer changes with the model you can fit on
/// the device. Everything upstream of this (capture / VAD / streaming ASR) is settled
/// and must not have to change when the engine does.
///
/// Completion-style (not async): the engine's translate worker runs a blocking
/// newest-wins receive loop on a background queue, and a callback re-arms it — the
/// exact shape of the Kotlin `for (turn in queue)` coroutine without mixing async
/// isolation into the pipeline.
protocol Translator {
    /// One-time heavy bring-up (native model load). The engine launches it in parallel
    /// with everything else; `translate` must not be called concurrently with it.
    func prepare(_ done: @escaping () -> Void)

    /// "auto" | "zh" | "en" ... ; target is the language we want to speak/see.
    /// `done` fires exactly once, on an arbitrary background thread.
    func translate(text: String, source: String, target: String,
                   done: @escaping (String) -> Void)

    func release()
}

/// Interpretation needs context, not sentence isolation: a translator that sees one
/// sentence at a time will mis-resolve pronouns and drop terms the speaker only defined
/// two sentences ago. Keep a short rolling window and hand it to the model.
final class ContextBuffer {
    private let maxTurns = 6
    private var turns: [String] = []
    private let lock = NSLock()

    func note(src: String, dst: String) {
        lock.lock(); defer { lock.unlock() }
        turns.append("[\(src) -> \(dst)]")
        while turns.count > maxTurns { turns.removeFirst() }
    }

    func promptContext() -> String {
        lock.lock(); defer { lock.unlock() }
        return turns.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        turns.removeAll()
    }
}

/// NOT A REAL TRANSLATOR. This exists only so the ASR/latency/UI path can be exercised
/// before the offline MT engine is installed. It passes text through with a marker.
///
/// Do not ship this and do not mistake its output for translation.
struct PlaceholderTranslator: Translator {
    func prepare(_ done: @escaping () -> Void) { done() }

    func translate(text: String, source: String, target: String,
                   done: @escaping (String) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) {
            done("⟨MT未安装⟩ \(text)")  // pretend cost, so latency HUD is non-zero
        }
    }

    func release() {}
}

/// capacity-1 newest-wins slot, the direct port of the Kotlin Channel(capacity=1)
/// plus trySend/drop-oldest handoff: when the consumer is slower than the producer,
/// the STALE item is overwritten, never queued behind — a human interpreter lets go
/// of the previous sentence rather than fall behind forever.
final class NewestWins<T> {
    private let cond = NSCondition()
    private var value: T?
    private var closed = false

    /// block until an item is available (or the channel is closed); consumes it
    func receive() -> T? {
        cond.lock(); defer { cond.unlock() }
        while value == nil && !closed { cond.wait() }
        let v = value
        value = nil
        return v
    }

    /// overwrites any unconsumed item; never blocks
    func offer(_ v: T) {
        cond.lock()
        value = v
        cond.signal()
        cond.unlock()
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }
}
