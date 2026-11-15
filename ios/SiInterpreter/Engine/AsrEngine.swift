import Foundation
import SherpaOnnxC

/// Keeps strdup'd C strings alive from config construction until engine creation.
///
/// Importing a C struct field `const char *` and assigning a Swift String creates a
/// temporary whose storage dies at the end of the statement — the config would then
/// hand dangling pointers into the native constructor. Every string goes through here
/// and is freed only after the engine exists.
final class CStrings {
    private var ptrs: [UnsafeMutablePointer<CChar>] = []

    func add(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        ptrs.append(p)
        return UnsafePointer(p)
    }

    func freeAll() {
        ptrs.forEach { free($0) }
        ptrs = []
    }
}

/// Wraps sherpa-onnx streaming recognition.
///
/// Design notes that matter for latency:
///  - the recognizer is created once and reused; stream reset is cheap
///  - we feed it a fixed 100 ms hop and decode once per hop (the c-api has no
///    is-ready hook; sherpa internally buffers, so one decode call per accepted
///    chunk drains everything available)
///  - getResult returns the FULL text of the current utterance every time, which is
///    why the UI replaces rather than appends the live segment
final class AsrEngine {
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    let sampleRate = 16000

    /// Builds the recognizer; false when the model files are unusable.
    func initialize(_ paths: ModelPaths, cutSilenceSec: Float = 1.0) -> Bool {
        guard recognizer == nil else { return true }
        let cs = CStrings()
        defer { cs.freeAll() }

        var cfg = SherpaOnnxOnlineRecognizerConfig()
        cfg.feat_config.sample_rate = Int32(sampleRate)
        cfg.feat_config.feature_dim = 80
        cfg.model_config.transducer.encoder = cs.add(paths.encoder)
        cfg.model_config.transducer.decoder = cs.add(paths.decoder)
        cfg.model_config.transducer.joiner = cs.add(paths.joiner)
        cfg.model_config.tokens = cs.add(paths.tokens)
        cfg.model_config.num_threads = 2
        cfg.model_config.provider = cs.add("cpu")
        cfg.decoding_method = cs.add("greedy_search")
        // Endpoint rules are what make this feel like simultaneous interpretation
        // rather than "transcribe after they stop talking". rule2 (trailing silence)
        // is the one that fires during natural speech pauses.
        cfg.enable_endpoint = 1
        // With the VAD gate active the recognizer is never fed during silence, so its
        // silence clock freezes and these rules only bite in the degraded no-VAD mode;
        // the +0.3 s margin keeps the VAD (which hands complete segment audio to
        // SenseVoice) winning whenever both clocks run.
        let rule2Silence = cutSilenceSec + 0.3
        cfg.rule1_min_trailing_silence = rule2Silence
        cfg.rule2_min_trailing_silence = rule2Silence
        cfg.rule3_min_utterance_length = 20    // never let a segment exceed 20 s

        guard let rec = SherpaOnnxCreateOnlineRecognizer(&cfg) else { return false }
        recognizer = rec
        stream = SherpaOnnxCreateOnlineStream(rec)
        return stream != nil
    }

    /// Partial text of the utterance currently being spoken.
    func accept(_ samples: [Float]) -> String {
        guard let rec = recognizer, let s = stream else { return "" }
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineStreamAcceptWaveform(s, Int32(sampleRate), buf.baseAddress,
                                                 Int32(samples.count))
        }
        SherpaOnnxDecodeOnlineStream(rec, s)
        return resultText(rec, s)
    }

    /// Endpoint fired: take the final text for the completed utterance and reset the
    /// stream so the next words start a fresh hypothesis.
    func flush() -> String {
        guard let rec = recognizer, let s = stream else { return "" }
        let text = resultText(rec, s)
        SherpaOnnxOnlineStreamReset(rec, s)
        return text
    }

    func isEndpoint() -> Bool {
        guard let rec = recognizer, let s = stream else { return false }
        return SherpaOnnxOnlineStreamIsEndpoint(rec, s) != 0
    }

    private func resultText(_ rec: OpaquePointer, _ s: OpaquePointer) -> String {
        guard let r = SherpaOnnxGetOnlineStreamResult(rec, s) else { return "" }
        let text = r.pointee.text.map { String(cString: $0) } ?? ""
        SherpaOnnxDestroyOnlineRecognizerResult(r)
        return text
    }

    func release() {
        if let s = stream { SherpaOnnxDestroyOnlineStream(s) }
        if let r = recognizer { SherpaOnnxDestroyOnlineRecognizer(r) }
        stream = nil
        recognizer = nil
    }
}

/// Speech/non-speech gate in front of the streaming ASR.
///
/// Why this exists: the Zipformer transducer is a generative model — fed room tone, it
/// emits confident-sounding nonsense ("THINK", "ER SINGER", "有点冷你冷风里风景"). dBFS only
/// proves a signal exists, not that it is speech. Silero VAD answers the actual question
/// "is a person talking", and the ASR is then fed ONLY during speech, which is the fix.
///
/// Boundary semantics, which is the subtle part:
///  - feed() returns true while the VAD says speech is ongoing -> the engine decodes
///    that hop. Silence hops return false and are NOT fed, so the RNN-T context never
///    accrues noise.
///  - segmentEnded() fires on the speech->silence transition (the VAD's own silence
///    timer expiring) — a far more reliable utterance boundary than the ASR's endpoint
///    rule on noisy input. The engine treats it as a cut and hands the COMPLETE segment
///    audio to the offline SenseVoice refinement.
///  - max_speech_duration (8 s) flushes a segment mid-speech, keeping streaming latency
///    bounded on long monologues.
///
/// No VAD model installed means "always feed": the pipeline degrades to the original
/// ungated behaviour rather than refusing to run.
final class VadGate {
    private var vad: OpaquePointer?
    let enabled: Bool

    init(path: VadPath?, sampleRate: Int, cutSilenceSec: Float = 1.0) {
        guard let p = path, FileManager.default.fileExists(atPath: p.model) else {
            enabled = false
            return
        }
        let cs = CStrings()
        defer { cs.freeAll() }

        var cfg = SherpaOnnxVadModelConfig()
        cfg.silero_vad.model = cs.add(p.model)
        // 0.6 (up from the 0.5 default): on the vivo's weak mic the 0.5 threshold fired
        // on -25 dB ambient rumble and produced empty cuts (peak=-24 text=[]). 0.6 keeps
        // VAD honest — it should fire on voiced frames, not room tone.
        cfg.silero_vad.threshold = 0.6
        // trailing silence -> segment end. The VAD is the primary cut signal, so this
        // carries the user's cut-silence knob verbatim: 0.5 s (the original fixed value)
        // chopped mid-sentence on any thinking pause.
        cfg.silero_vad.min_silence_duration = cutSilenceSec
        cfg.silero_vad.min_speech_duration = 0.25
        cfg.silero_vad.window_size = 512
        cfg.silero_vad.max_speech_duration = 8
        cfg.sample_rate = Int32(sampleRate)
        cfg.num_threads = 1
        cfg.provider = cs.add("cpu")

        // 60 s ring: segments sit here only until the next 100 ms hop drains them
        vad = SherpaOnnxCreateVoiceActivityDetector(&cfg, 60)
        enabled = vad != nil
    }

    /// true if this hop should be decoded by the ASR (speech ongoing or just started)
    func feed(_ samples: [Float]) -> Bool {
        guard let v = vad else { return true }
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(v, buf.baseAddress,
                                                          Int32(samples.count))
        }
        return SherpaOnnxVoiceActivityDetectorDetected(v) != 0
    }

    /// Did a speech segment just end on this hop? Poll after feed(); fires once per
    /// transition, returning the COMPLETE segment audio the VAD assembled. Multiple
    /// queued segments drain into one concatenated buffer so no speech is dropped.
    func segmentEnded() -> [Float]? {
        guard let v = vad else { return nil }
        var merged: [Float] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(v) == 0 {
            guard let seg = SherpaOnnxVoiceActivityDetectorFront(v) else { break }
            let n = Int(seg.pointee.n)
            if n > 0, let s = seg.pointee.samples {
                merged.append(contentsOf: UnsafeBufferPointer(start: s, count: n))
            }
            SherpaOnnxDestroySpeechSegment(seg)
            SherpaOnnxVoiceActivityDetectorPop(v)
        }
        return merged.isEmpty ? nil : merged
    }

    /// force-flush any in-progress segment (e.g. on stop)
    func flush() {
        if let v = vad { SherpaOnnxVoiceActivityDetectorFlush(v) }
    }

    func release() {
        if let v = vad { SherpaOnnxDestroyVoiceActivityDetector(v) }
        vad = nil
    }
}

/// Offline SenseVoice recogniser — the ACCURACY path.
///
/// The streaming Zipformer (2023 demo-grade, int8) decodes weak-mic zh/en speech into
/// garbled fragments. SenseVoice-Small is a generation ahead on zh+en code-switching
/// and ships punctuation + inverse-text normalisation, but it is non-streaming: it
/// decodes a complete utterance at once. The VAD already hands us exactly that — a
/// complete, silence-delimited speech segment — so this engine refines each segment
/// AFTER the cut, while the streaming model keeps providing live partials during
/// speech.
final class OfflineAsr {
    struct Refined {
        let text: String
        /// language SenseVoice detected for the segment, e.g. "<|zh|>" (raw token form)
        let lang: String?
    }

    private var recognizer: OpaquePointer?

    func initialize(_ paths: SenseVoicePaths) -> Bool {
        guard recognizer == nil else { return true }
        let cs = CStrings()
        defer { cs.freeAll() }

        var cfg = SherpaOnnxOfflineRecognizerConfig()
        cfg.feat_config.sample_rate = 16000
        cfg.feat_config.feature_dim = 80
        cfg.model_config.sense_voice.model = cs.add(paths.model)
        // empty => auto-detect among zh/en/ja/ko/yue per utterance: interpretation is
        // code-switching, and locking one language is what garbled the old model
        cfg.model_config.sense_voice.language = cs.add("")
        cfg.model_config.sense_voice.use_itn = 1
        cfg.model_config.tokens = cs.add(paths.tokens)
        cfg.model_config.num_threads = 2
        cfg.model_config.provider = cs.add("cpu")

        recognizer = SherpaOnnxCreateOfflineRecognizer(&cfg)
        return recognizer != nil
    }

    /// Decode a complete speech segment; nil when unavailable (not installed / init failed).
    func decode(_ samples: [Float]) -> Refined? {
        guard let rec = recognizer, !samples.isEmpty else { return nil }
        guard let s = SherpaOnnxCreateOfflineStream(rec) else { return nil }
        defer { SherpaOnnxDestroyOfflineStream(s) }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(s, 16000, buf.baseAddress, Int32(samples.count))
        }
        SherpaOnnxDecodeOfflineStream(rec, s)

        guard let r = SherpaOnnxGetOfflineStreamResult(s) else { return nil }
        let text = r.pointee.text.map { String(cString: $0) } ?? ""
        let lang = r.pointee.lang.map { String(cString: $0) }
        SherpaOnnxDestroyOfflineRecognizerResult(r)
        return Refined(text: text, lang: lang)
    }

    func release() {
        if let r = recognizer { SherpaOnnxDestroyOfflineRecognizer(r) }
        recognizer = nil
    }
}
