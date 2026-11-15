import Foundation
import AVFoundation
import os.log

/// The pipeline: mic tap -> streaming ASR -> endpoint/VAD cut -> translate -> publish.
/// Port of the Android InterpreterEngine.kt; the threading contract is preserved:
///
///  - the hop worker touches only the mic pipe, VAD and ASR. It never awaits the
///    translator, or a 400 ms model call blocks the pipe and audio backlog grows.
///  - finished utterances go into a capacity-1 newest-wins slot. When translation is
///    slower than speech we drop the OLD turn — you let go of the previous sentence
///    rather than fall behind forever.
final class InterpreterEngine: ObservableObject {
    struct Turn {
        let text: String
        let detectedLang: String?
    }

    /// The single source of truth the UI binds to. All mutations hop to main.
    @Published var live = ""
    @Published var history: [Utterance] = []
    @Published var stats = Stats()
    @Published var state: EngineState = .idle

    /// Set from the UI to cut the current utterance on the next hop. This is how
    /// endpoint latency gets measured instead of guessed: say one known sentence,
    /// tap, and the logged timestamp gap is the real end-of-speech-to-cut time.
    private let flagLock = NSLock()
    private var _forceCut = false
    var forceCut: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return _forceCut }
        set { flagLock.lock(); _forceCut = newValue; flagLock.unlock() }
    }

    private let config: PipelineConfig
    private let asr = AsrEngine()
    private let capture = AudioCapture()
    private var translator: Translator
    private var asrPaths: ModelPaths?
    private var vadPath: VadPath?
    private var senseVoicePath: SenseVoicePaths?

    /// Offline refinement engine (SenseVoice). Brought up LAZILY on its own worker:
    /// session init for a 228 MB int8 model can take a while on flash+CPU, and making
    /// the mic wait for it would reproduce the very freeze this architecture exists
    /// to prevent. nil -> streaming transcript published as-is.
    private let offlineLock = NSLock()
    private var _offline: OfflineAsr?
    private var offline: OfflineAsr? {
        get { offlineLock.lock(); defer { offlineLock.unlock() }; return _offline }
        set { offlineLock.lock(); _offline = newValue; offlineLock.unlock() }
    }

    private var gate: VadGate?

    private let queue = NewestWins<Turn>()
    /// segments awaiting offline refinement; newest-wins so a slow SenseVoice decode of
    /// one long segment makes us drop stale audio, never stop reading the mic
    private let refineQueue = NewestWins<[Float]>()
    private var nextId = 0
    private let idLock = NSLock()
    private let buffer = ContextBuffer()

    private var hopTimer: DispatchSourceTimer?
    private let hopQueue = DispatchQueue(label: "com.qoder.si.hop", qos: .userInitiated)
    private let workerQueue = DispatchQueue(label: "com.qoder.si.worker", qos: .userInitiated)

    // per-segment accumulators, logged at every cut so a hallucinated fragment can be
    // told apart from real speech by ITS LOUDNESS
    private var segSamples: Int64 = 0
    private var segPeakDb: Float = -120
    private var lastDbLog = Date.distantPast
    private var currentLive = ""

    private let log = Logger(subsystem: "com.qoder.si", category: "Engine")

    init(config: PipelineConfig, asrPaths: ModelPaths, vadPath: VadPath?,
         senseVoicePath: SenseVoicePaths?, translator: Translator) {
        self.config = config
        self.asrPaths = asrPaths
        self.vadPath = vadPath
        self.senseVoicePath = senseVoicePath
        self.translator = translator
    }

    func publish(_ fn: @escaping () -> Void) {
        DispatchQueue.main.async(execute: fn)
    }

    // MARK: lifecycle

    func start() {
        publish { self.state = .loading }
        let micGranted = AVAudioSession.sharedInstance().recordPermission == .granted
        guard micGranted else {
            publish { self.state = .error("没有录音权限") }
            return
        }

        let asrPaths = self.asrPaths
        let vadPath = self.vadPath
        workerQueue.async { [weak self] in
            guard let self else { return }
            guard let asrPaths, self.asr.initialize(asrPaths,
                                                  cutSilenceSec: config.cutSilenceSec) else {
                self.publish { self.state = .error("识别模型加载失败") }
                return
            }
            // Silero VAD is a tiny (~2 MB) ONNX model but its native ctor still touches
            // disk+onnxruntime, so keep it off the main thread for the same reason as
            // the big encoders. A null gate runs "always feed" mode.
            self.gate = VadGate(path: vadPath, sampleRate: 16000,
                                cutSilenceSec: config.cutSilenceSec)
            self.log.info("started gate.enabled=\(self.gate?.enabled == true)")
            // open the mic BEFORE the workers: the hop timer pulls from the capture
            // pipe, so without this it would just find an empty pipe forever
            if let err = self.capture.start(sampleRate: 16000, hopMs: self.config.hopMs) {
                self.log.error("mic start failed: \(String(describing: err), privacy: .public)")
                self.publish { self.state = .error("麦克风启动失败: \(err.localizedDescription)") }
                return
            }
            self.publish { self.state = .running }
            self.startWorkers()
        }

        // translator bring-up (llama.cpp maps a 1-3 GB GGUF) runs in parallel; the
        // translate worker awaits it on its first turn, so an early utterance waits
        // rather than ships untranslated
        workerQueue.async { [weak self] in
            self?.translator.prepare {
                self?.log.info("translator ready")
            }
        }
        if senseVoicePath != nil {
            // lazy bring-up: Running state reflects streaming readiness; refinement
            // comes online on its own a few seconds in. Until then cuts fall back to
            // streaming text.
            workerQueue.async { [weak self] in
                guard let self, let sv = self.senseVoicePath else { return }
                let off = OfflineAsr()
                if off.initialize(sv) {
                    self.offline = off
                    self.log.info("offline asr ready")
                } else {
                    self.log.error("offline asr init failed, streaming-only")
                }
            }
        }
    }

    private func startWorkers() {
        // translate worker: re-armed from the translate completion so turns are
        // strictly serial (one blocking llama.cpp call at a time)
        translateLoop()

        // refine worker: same newest-wins contract
        refineLoop()

        // hop worker: fixed cadence, mirrors the Android AudioRecord read loop
        let timer = DispatchSource.makeTimerSource(queue: hopQueue)
        timer.schedule(deadline: .now() + Double(config.hopMs) / 1000.0,
                       repeating: Double(config.hopMs) / 1000.0)
        timer.setEventHandler { [weak self] in self?.hop() }
        timer.resume()
        hopTimer = timer
    }

    func stop() {
        // close the queues first so parked workers drain and exit
        queue.close()
        refineQueue.close()
        // the rest of the teardown runs ON the hop queue: any hop already executing
        // finishes before asr/gate are freed — releasing the recognizer while a decode
        // is in flight would be a use-after-free crash
        hopQueue.async { [weak self] in
            guard let self else { return }
            self.hopTimer?.cancel()
            self.hopTimer = nil
            self.capture.stop()
            self.gate?.release()
            self.gate = nil
            self.asr.release()
            self.offline?.release()
            self.offline = nil
            // deliberately NOT releasing the translator: the llama.cpp model stays
            // resident for the next session (same contract as the Android engine),
            // and freeing it while a translate call is in flight would crash
            self.forceCut = false
            self.currentLive = ""
            self.publish {
                self.state = .idle
                self.live = ""
            }
            self.log.info("stopped")
        }
    }

    func clear() {
        forceCut = false
        idLock.lock(); nextId = 0; idLock.unlock()
        buffer.clear()
        publish {
            self.history = []
            self.stats = Stats()
        }
    }

    // MARK: hop worker (the capture loop)

    private func hop() {
        let hopSamples = 16000 * config.hopMs / 1000        // 100 ms -> 1600 samples
        guard let frame = capture.pipe.take(hopSamples) else { return }

        let t0 = Date()
        let level = rms(frame)
        let db = toDb(level)
        segSamples += Int64(frame.count)
        if db > segPeakDb { segPeakDb = db }

        // one level line every 5 s whether or not anything was recognised: without it
        // a silent-looking screen cannot be read as "too quiet" versus "no speech"
        let now = Date()
        if now.timeIntervalSince(lastDbLog) > 5 {
            lastDbLog = now
            log.info("level=\(String(format: "%.1f", db), privacy: .public) dBFS peak=\(String(format: "%.1f", self.segPeakDb), privacy: .public) heard=\(String(format: "%.1f", Double(self.segSamples) / 16000), privacy: .public)s")
        }

        // VAD gate: feed the hop to the gate FIRST. Only when it reports speech do we
        // hand audio to the ASR — the transducer never sees room tone, so it cannot
        // invent "THINK"/"ER SINGER" out of nothing. The gate also surfaces a
        // segmentEnded signal (VAD's own silence timer) that is a more trustworthy
        // utterance boundary than the ASR endpoint on noisy input.
        let speech = gate?.feed(frame) ?? true
        let vadSegment = gate?.segmentEnded()

        var partial: String
        if speech {
            // The vivo-class mic hands a weak signal (observed speech peaks at ~-23 dBFS
            // where a near-mic voice should be -3..-12). Boost speech hops toward a
            // -12 dBFS RMS target before decode. The VAD already ate the ORIGINAL frame,
            // so this gain does not perturb VAD state — it only conditions what the ASR
            // sees. Noise hops are not boosted (they are not decoded), so gain never
            // amplifies the very room tone the VAD is there to suppress.
            let boosted = boostForAsr(frame)
            partial = asr.accept(boosted)
        } else {
            // not feeding silence keeps the transducer context clean; the live hypothesis
            // from the last speech hop stays on screen until a cut fires
            partial = currentLive
        }

        let asrMs = Int64(Date().timeIntervalSince(t0) * 1000)
        publish {
            self.stats.secondsHeard += Float(frame.count) / 16000.0
            self.stats.asrMs = asrMs
            self.stats.levelDb = db
            self.stats.peakDb = max(self.stats.peakDb, db)
        }
        if partial != currentLive {
            currentLive = partial
            publish { self.live = partial }
        }

        // three independent cut triggers, all valid:
        //  - vadSegment != nil: the VAD's silence timer fired -> trustworthy sentence
        //    boundary, hands the COMPLETE segment audio for offline refinement
        //  - endpoint: the ASR's own rule2 (trailing silence after speech) -> fallback
        //    without a VAD, second opinion with one; it sometimes fires a hair earlier,
        //    and that lower latency is worth taking
        //  - forced: the 切断 button, for measuring end-of-speech->cut latency by hand
        let endpoint = !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && asr.isEndpoint()
        let forced = forceCut
            && !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if vadSegment != nil || endpoint || forced {
            let streamed = asr.flush().trimmingCharacters(in: .whitespacesAndNewlines)
            forceCut = false
            currentLive = ""
            publish { self.live = "" }
            let why = forced ? "FORCED" : (vadSegment != nil ? "vad" : "endpoint")
            log.info("cut \(why, privacy: .public) dur=\(String(format: "%.1f", Double(self.segSamples) / 16000), privacy: .public)s peak=\(String(format: "%.1f", self.segPeakDb), privacy: .public)dB stream=[\(streamed, privacy: .public)]")
            segSamples = 0
            segPeakDb = -120

            if let seg = vadSegment, offline != nil {
                // Hand the segment to the refinement worker and move on — awaiting
                // SenseVoice here is what froze the mic reads. Newest-wins: a segment
                // already queued is dropped in favour of this one.
                var capped = seg
                let maxSamples = 30 * 16000
                if capped.count > maxSamples {
                    log.warning("segment \(String(format: "%.1f", Double(capped.count) / 16000), privacy: .public)s exceeds 30s cap, refining the tail")
                    capped = Array(capped.suffix(maxSamples))
                }
                refineQueue.offer(capped)
            } else if !streamed.isEmpty {
                // no refiner installed, or an endpoint/forced cut with no VAD segment
                // audio: the streaming hypothesis is all we have
                offerTurn(streamed, detectedLang: nil)
            }
        }
    }

    private func offerTurn(_ text: String, detectedLang: String?) {
        queue.offer(Turn(text: text, detectedLang: detectedLang))
    }

    // MARK: translate worker

    private func translateLoop() {
        workerQueue.async { [weak self] in
            guard let self else { return }
            // blocks this background thread until a turn arrives or stop() closes the slot
            guard let turn = self.queue.receive() else { return }
            self.beginTurn(turn)
        }
    }

    private func beginTurn(_ turn: Turn) {
        // Direction per utterance, from the language SenseVoice actually detected —
        // speakers code-switch mid-session, and a fixed en->zh chip fed Chinese text
        // to a "translate into Chinese" instruction, which the model rightly echoed
        // back. SenseVoice reports the lang as the raw first token, e.g. "<|zh|>", so
        // match by substring, never equality. Cantonese ("yue") writes as Chinese. The
        // configured direction is only the fallback for turns with no detection
        // (streaming path).
        let detected = normalizeLang(turn.detectedLang)
        let src = detected ?? config.sourceLang
        let tgt = src == "zh" ? "en" : "zh"
        idLock.lock(); nextId += 1; let id = nextId; idLock.unlock()
        let text = turn.text

        publish {
            self.history.append(Utterance(id: id, sourceText: text, translated: "",
                                          source: src, target: tgt, pending: true,
                                          latencyMs: 0))
            if self.history.count > 80 { self.history.removeFirst(self.history.count - 80) }
        }

        let t0 = Date()
        translator.translate(text: text, source: src, target: tgt) { [weak self] out in
            guard let self else { return }
            let ms = Int64(Date().timeIntervalSince(t0) * 1000)
            self.log.info("translate#\(id, privacy: .public) \(src, privacy: .public)->\(tgt, privacy: .public) \(ms, privacy: .public)ms src=[\(text, privacy: .public)] out=[\(out, privacy: .public)]")

            self.buffer.note(src: src, dst: tgt)
            self.publish {
                if let i = self.history.firstIndex(where: { $0.id == id }) {
                    self.history[i] = Utterance(id: id, sourceText: text, translated: out,
                                                source: src, target: tgt, pending: false,
                                                latencyMs: ms)
                }
                self.stats.translateMs = ms
                self.stats.utterances = id
            }
            self.translateLoop()
        }
    }

    /// SenseVoice reports the lang as the raw first token, e.g. "<|zh|>"; map to a code
    private func normalizeLang(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        if raw.contains("zh") || raw.contains("yue") { return "zh" }
        if raw.contains("en") { return "en" }
        return nil
    }

    // MARK: refine worker

    private func refineLoop() {
        workerQueue.async { [weak self] in
            guard let self else { return }
            guard let seg = self.refineQueue.receive() else { return }
            guard let off = self.offline else {
                self.refineLoop()
                return
            }
            let t0 = Date()
            let ref = off.decode(seg)
            let ms = Int64(Date().timeIntervalSince(t0) * 1000)
            // the refine decode time replaces the streaming asrMs — it is the number
            // that shows what the final transcript actually cost
            self.publish { self.stats.asrMs = ms }
            let txt = (ref?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.log.info("refined \(String(format: "%.1f", Double(seg.count) / 16000), privacy: .public)s in \(ms, privacy: .public)ms lang=\(ref?.lang ?? "nil", privacy: .public) -> [\(txt, privacy: .public)]")
            if !txt.isEmpty {
                self.offerTurn(txt, detectedLang: ref?.lang)
            }
            self.refineLoop()
        }
    }

    // MARK: audio math (ports of the Kotlin helpers)

    private func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc = 0.0
        for v in s { acc += Double(v) * Double(v) }
        return Float(sqrt(acc / Double(s.count)))
    }

    /// linear RMS -> dBFS, floored so the HUD never shows -Inf
    private func toDb(_ linear: Float) -> Float {
        if linear <= 1e-6 { return -120 }
        return Float(20 * log10(Double(linear)))
    }

    /// Boost a speech hop toward a -12 dBFS RMS target (linear ~0.25) so the ASR —
    /// trained on normalised audio — actually decodes it on a weak mic. Caps the gain
    /// at 8x to avoid exploding a quiet-but-noisy frame into clipping noise.
    private func boostForAsr(_ s: [Float]) -> [Float] {
        let r = rms(s)
        if r <= 1e-5 { return s }
        let target: Float = 0.25
        var gain = min(target / r, 8)
        if gain <= 1.05 { return s }
        var out = [Float](repeating: 0, count: s.count)
        for i in 0..<s.count {
            var v = s[i] * gain
            if v > 1 { v = 1 } else if v < -1 { v = -1 }
            out[i] = v
            // don't keep boosting into clipping: once we saturate, pull gain back
            if v >= 1 || v <= -1 { gain = max(gain * 0.85, 1) }
        }
        return out
    }
}
