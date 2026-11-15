import Foundation

struct Utterance: Identifiable, Equatable {
    let id: Int
    let sourceText: String
    let translated: String
    let source: String
    let target: String
    var pending: Bool
    /// end-of-speech -> translation-ready, the number that tells you if this feels live
    var latencyMs: Int64
}

enum EngineState: Equatable {
    case idle
    case loading
    case running
    case error(String)
}

struct Stats: Equatable {
    var secondsHeard: Float = 0
    var utterances = 0
    var asrMs: Int64 = 0
    var translateMs: Int64 = 0
    var dropped = 0
    /// dBFS of the current hop and of the loudest hop so far. Without these, an ASR
    /// that emits hallucinated fragments is undiagnosable: "mic is too quiet" and
    /// "endpoint cuts too early" read identically in the text and need opposite fixes.
    var levelDb: Float = -120
    var peakDb: Float = -120
}

enum Fmt {
    static func latency(_ ms: Int64) -> String {
        if ms <= 0 { return "—" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    static func db(_ db: Float) -> String {
        if db <= -119 { return "—" }
        return String(format: "%.0fdB", db)
    }

    static func mb(_ b: Int64) -> String { String(format: "%.1f", Double(b) / 1_048_576.0) }

    static func speed(_ bps: Double) -> String {
        if bps <= 0 { return "" }
        return String(format: "%.1f MB/s", bps / 1_048_576.0)
    }
}
