import AVFoundation
import os.log

/// Speaks finished translations via the system speech synthesiser. Port of the Android
/// TtsPlayer. The speaker output reaches the mic, and an interpreter that transcribes
/// its own voice is exactly the hallucination the VAD exists to prevent — so playback
/// raises `muted`, which the hop worker honours by dropping hops, and the flag clears
/// only GRACE seconds after didFinish/didCancel (the reverb tail still reaching the mic).
final class TtsSpeaker: NSObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private let log = Logger(subsystem: "com.qoder.si", category: "TtsSpeaker")

    private let lock = NSLock()
    private var _muted = false
    private var unmuteWork: DispatchWorkItem?

    /// true while synthesis plays (plus a reverb tail) — the hop worker must not feed
    var muted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _muted
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, lang: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lock.lock()
        _muted = true
        unmuteWork?.cancel()
        unmuteWork = nil
        lock.unlock()
        let u = AVSpeechUtterance(string: t)
        // explicit voice: without it zh text can come out of an en voice as pinyin soup
        u.voice = AVSpeechSynthesisVoice(language: lang == "zh" ? "zh-CN" : "en-US")
        log.info("speak lang=\(lang, privacy: .public) text=[\(t.prefix(24), privacy: .public)]")
        synthesizer.speak(u)
    }

    /// cancel playback and unmute immediately — teardown path
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        lock.lock()
        unmuteWork?.cancel()
        unmuteWork = nil
        _muted = false
        lock.unlock()
    }

    private func finishPlayback() {
        // a queued second utterance may still be speaking: its own callback re-arms the
        // unmute, so bail out instead of unmuting underneath it
        guard !synthesizer.isSpeaking else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); self._muted = false; self.lock.unlock()
        }
        lock.lock()
        unmuteWork?.cancel()
        unmuteWork = work
        lock.unlock()
        // GRACE: the speaker is still radiating the last phonemes when the callback fires
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        finishPlayback()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        finishPlayback()
    }
}
