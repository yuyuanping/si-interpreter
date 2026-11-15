import AVFoundation

/// Mic capture -> 16 kHz mono Float hops, the iOS counterpart of the Android
/// AudioRecord read loop. The engine's hop worker pulls from SamplePipe; the tap
/// callback only converts and appends, so the real-time audio thread never waits
/// on ASR/VAD/translation work.
final class AudioCapture {
    /// thread-safe accumulator between the audio tap (real-time thread) and the
    /// hop worker (background queue)
    final class SamplePipe {
        private let lock = NSLock()
        private var buf: [Float] = []

        func append(_ samples: [Float]) {
            lock.lock(); buf.append(contentsOf: samples); lock.unlock()
        }

        /// pull exactly n samples when available (mirrors AudioRecord.read blocking
        /// semantics, drained in order); nil when not enough has arrived yet
        func take(_ n: Int) -> [Float]? {
            lock.lock(); defer { lock.unlock() }
            guard buf.count >= n else { return nil }
            let out = Array(buf.prefix(n))
            buf.removeFirst(n)
            return out
        }

        /// drop stale audio (called on stop)
        func clear() {
            lock.lock(); buf.removeAll(); lock.unlock()
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return buf.count }
    }

    let pipe = SamplePipe()
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var running = false

    var isActive: Bool { running }

    /// Configure the audio session and start pulling mic frames. `sampleRate` is the
    /// pipeline rate (16000); the hardware rate is converted down automatically.
    func start(sampleRate: Double, hopMs: Int) -> Error? {
        let session = AVAudioSession.sharedInstance()
        do {
            // .measurement skips the aggressive voice-processing gain that pumps up
            // room noise between sentences — the iOS twin of the Android
            // VOICE_RECOGNITION source choice. playAndRecord + defaultToSpeaker so the
            // TTS player is heard over the speaker rather than the earpiece; the
            // speaker's own echo is handled by muting the hop worker during playback.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(sampleRate)
            try session.setPreferredIOBufferDuration(Double(hopMs) / 1000.0)
            try session.setActive(true)
        } catch {
            return error
        }

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        let outFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1)!

        let conv = AVAudioConverter(from: hwFormat, to: outFormat)
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let conv = self.converter else { return }
            self.consume(buffer: buffer, converter: conv)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return error
        }
        running = true
        return nil
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        pipe.clear()
    }

    /// Convert one hardware buffer to 16 kHz mono and append to the pipe. May emit
    /// nothing (priming) while the converter's internal resampler fills.
    private func consume(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        // capacity: how many output frames this input frame should yield, plus slack
        let ratio = converter.outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 128
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                         frameCapacity: max(cap, 1024)) else { return }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status == .haveData, conversionError == nil,
              out.frameLength > 0, let ch = out.floatChannelData else { return }

        let n = Int(out.frameLength)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n { samples[i] = ch[0][i] }
        pipe.append(samples)
    }
}
