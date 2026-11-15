import Foundation

/// Runtime knobs. Mutable + persisted so tuning latency does not need a rebuild.
final class PipelineConfig {
    private let d = UserDefaults.standard

    /// 100 ms is the sweet spot: smaller means more per-hop overhead, larger means more lag
    var hopMs: Int {
        get { d.object(forKey: "hopMs") as? Int ?? 100 }
        set { d.set(newValue, forKey: "hopMs") }
    }

    var sourceLang: String {
        get { d.string(forKey: "src") ?? "en" }
        set { d.set(newValue, forKey: "src") }
    }

    var targetLang: String {
        get { d.string(forKey: "tgt") ?? "zh" }
        set { d.set(newValue, forKey: "tgt") }
    }

    var speakTranslation: Bool {
        get { d.bool(forKey: "speak") }
        set { d.set(newValue, forKey: "speak") }
    }
}
