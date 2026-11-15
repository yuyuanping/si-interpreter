package com.qoder.si

import com.k2fsa.sherpa.onnx.EndpointConfig
import com.k2fsa.sherpa.onnx.EndpointRule
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.OfflineStream
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineRecognizer
import com.k2fsa.sherpa.onnx.OnlineRecognizerConfig
import com.k2fsa.sherpa.onnx.OnlineStream
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.TenVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import android.util.Log

/**
 * Paths of every model the app needs, all under filesDir so the APK stays small and the
 * user can install / swap / remove them without a rebuild.
 */
data class ModelPaths(
    val encoder: String,
    val decoder: String,
    val joiner: String,
    val tokens: String,
) {
    fun exists(): Boolean =
        listOf(encoder, decoder, joiner, tokens).all { java.io.File(it).isFile }
}

/** Path of the VAD model file. Separate from [ModelPaths] because the VAD is optional:
 *  the pipeline runs without it (the original ambient-noise behaviour), it just hallucinates.
 *  Presenting it as its own resolved path keeps ModelStore honest about what is mandatory. */
data class VadPath(val model: String) {
    fun exists(): Boolean = java.io.File(model).isFile
}

/** Paths of the optional SenseVoice offline refinement model. */
data class SenseVoicePaths(val model: String, val tokens: String) {
    fun exists(): Boolean = java.io.File(model).isFile && java.io.File(tokens).isFile
}

/** Path of the offline translation GGUF (Hy-MT2). Optional: without it the placeholder
 *  translator marks turns instead of translating. */
data class MtPaths(val model: String) {
    fun exists(): Boolean = java.io.File(model).isFile
}

/**
 * Wraps sherpa-onnx streaming recognition.
 *
 * Design notes that matter for latency:
 *  - the recognizer is created once and reused; createStream/reset are cheap
 *  - we feed it a fixed 100 ms hop and only call decode() when isReady() says there is
 *    enough context, so we never spin the encoder on partial frames
 *  - getResult() returns the FULL text of the current utterance every time, which is why
 *    the UI replaces rather than appends the live segment
 */
class AsrEngine(private val paths: ModelPaths, private val cutSilenceSec: Float = 1.0f) {

    private var recognizer: OnlineRecognizer? = null
    private var stream: OnlineStream? = null

    val sampleRate: Int = 16000

    fun init() {
        if (recognizer != null) return
        Log.i(TAG, "init paths enc=${paths.encoder.takeLast(40)} exists=${java.io.File(paths.encoder).isFile} " +
            "encBytes=${java.io.File(paths.encoder).length()} dec=${java.io.File(paths.decoder).isFile} " +
            "join=${java.io.File(paths.joiner).isFile} tok=${java.io.File(paths.tokens).isFile}")
        // Endpoint rules are what make this feel like simultaneous interpretation
        // rather than "transcribe after they stop talking". With the VAD gate active
        // the recognizer is never fed during silence, so its silence clock freezes and
        // these rules only bite in the degraded no-VAD mode; the +0.3 s margin keeps the
        // VAD (which hands complete segment audio to SenseVoice) winning whenever both
        // clocks run.
        val rule2Silence = cutSilenceSec + 0.3f
        val cfg = OnlineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = sampleRate, featureDim = 80, dither = 0f),
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(
                    encoder = paths.encoder,
                    decoder = paths.decoder,
                    joiner = paths.joiner,
                ),
                tokens = paths.tokens,
                numThreads = 2,
                debug = false,
                provider = "cpu",
            ),
            // rule1/rule2 share the trailing-silence threshold; rule3 caps a segment
            endpointConfig = EndpointConfig(
                rule1 = EndpointRule(false, rule2Silence, 0f),
                rule2 = EndpointRule(true, rule2Silence, 0f),
                rule3 = EndpointRule(false, 0f, 20f),   // never let a segment exceed 20 s
            ),
            enableEndpoint = true,
            decodingMethod = "greedy_search",
        )

        // AssetManager MUST be null here. Verified in the v2.0.0 bytecode: the constructor
        // branches `ifnull -> newFromFile` / `else -> newFromAsset`, so passing
        // context.assets makes sherpa look these absolute paths up inside the APK's asset
        // table and fail. null is the file-system route, which is what ModelStore uses.
        recognizer = OnlineRecognizer(null, cfg)
        Log.i(TAG, "recognizer built; creating stream")
        stream = recognizer!!.createStream(hotwords = "")
        Log.i(TAG, "stream created, init done")
    }

    companion object { private const val TAG = "AsrEngine" }

    /** @return partial text of the utterance currently being spoken. */
    fun accept(samples: FloatArray): String {
        val rec = recognizer ?: return ""
        val s = stream ?: return ""
        s.acceptWaveform(samples, sampleRate)
        while (rec.isReady(s)) rec.decode(s)
        return rec.getResult(s).text
    }

    /**
     * Endpoint fired: take the final text for the completed utterance and reset the stream
     * so the next words start a fresh hypothesis.
     */
    fun flush(): String {
        val rec = recognizer ?: return ""
        val s = stream ?: return ""
        val text = rec.getResult(s).text
        rec.reset(s)
        return text
    }

    fun isEndpoint(): Boolean = recognizer?.let { r -> stream?.let { r.isEndpoint(it) } } ?: false

    fun release() {
        stream?.release()
        recognizer?.release()
        stream = null
        recognizer = null
    }
}

/**
 * Speech/non-speech gate in front of the streaming ASR.
 *
 * Why this exists: the Zipformer transducer is a generative model — fed room tone, it emits
 * confident-sounding nonsense ("THINK", "ER SINGER", "有点冷你冷风里风景"). dBFS only proves a
 * signal exists, not that it is speech, so without a VAD "mic too quiet" and "endpoint cuts
 * too early" read identically. Silero VAD answers the actual question "is a person talking",
 * and the ASR is then fed ONLY during speech, which is the fix.
 *
 * Threading: owned by the capture loop's coroutine, touched from no other thread.
 *
 * Boundary semantics, which is the subtle part:
 *  - [feed] returns true while the VAD says speech is ongoing -> the engine decodes that hop.
 *    Silence hops return false and are NOT fed, so the RNN-T context never accrues noise.
 *  - [segmentEnded] fires on the speech->silence transition (the VAD's own silence timer
 *    expiring). That is a far more reliable utterance boundary than the ASR's endpoint
 *    rule, which on noisy input fires on phantom pauses. The engine treats it as a cut.
 *  - [maxSpeechReached] fires when one speech segment hits [SileroVadModelConfig.maxSpeechDuration]
 *    (5 s default): the VAD flushes a segment mid-speech, so we cut there too to keep
 *    streaming latency bounded on long monologues.
 *
 * A null instance (no VAD model installed) means "always feed": the pipeline degrades to the
 * original ungated behaviour rather than refusing to run.
 */
class VadGate(path: VadPath?, sampleRate: Int, cutSilenceSec: Float = 1.0f) {

    private val vad: Vad? = path?.let { p ->
        val cfg = VadModelConfig(
            sileroVadModelConfig = SileroVadModelConfig(
                model = p.model,
                // 0.6 (up from the 0.5 default): on the vivo's weak mic the 0.5 threshold
                // fired on -25 dB ambient rumble and produced empty cuts (peak=-24 text=[]).
                // 0.6 keeps VAD honest — it should fire on voiced frames, not room tone.
                threshold = 0.6f,
                // trailing silence -> segment end. The VAD is the primary cut signal, so
                // this carries the user's 断句停顿 knob verbatim: 0.5 s (the original
                // fixed value) chopped mid-sentence on any thinking pause.
                minSilenceDuration = cutSilenceSec,
                minSpeechDuration = 0.25f,
                windowSize = 512,
                // cap a segment at 8 s so a long run-on speaker still gets streamed out in
                // chunks rather than buffering until the ASR's 20 s hard limit
                maxSpeechDuration = 8f,
            ),
            tenVadModelConfig = TenVadModelConfig(),
            sampleRate = sampleRate,
            numThreads = 1,
            provider = "cpu",
            debug = false,
        )
        // null AssetManager -> newFromFile, same file-system route AsrEngine uses. Verified
        // in the v2.0.0 JNI: the Vad native constructor branches on AssetManager == null.
        Log.i(TAG, "Vad newFromFile model=${p.model.takeLast(40)} exists=${p.exists()}")
        Vad(null, cfg)
    }

    private var wasSpeech = false

    /** @return true if this hop should be decoded by the ASR (speech ongoing or just started). */
    fun feed(samples: FloatArray): Boolean {
        val v = vad ?: return true
        v.acceptWaveform(samples)
        val speech = v.isSpeechDetected()
        return speech
    }

    /**
     * Did a speech segment just end on this hop? Poll after [feed]; fires once per transition,
     * returning the COMPLETE segment audio the VAD assembled (front().samples) — exactly the
     * input the offline SenseVoice refinement wants. Multiple queued segments drain into one
     * concatenated buffer so no speech is dropped.
     */
    fun segmentEnded(): FloatArray? {
        val v = vad ?: return null
        var merged: FloatArray? = null
        while (!v.empty()) {
            val seg = v.front()
            v.pop()
            val s = seg.samples
            merged = if (merged == null) s else merged + s
        }
        return merged
    }

    /** force-flush any in-progress segment (e.g. on stop). */
    fun flush() { vad?.flush(); wasSpeech = false }

    fun release() { vad?.release() }

    val enabled: Boolean get() = vad != null

    companion object { private const val TAG = "VadGate" }
}

/**
 * Offline SenseVoice recogniser — the ACCURACY path.
 *
 * The streaming Zipformer (2023 demo-grade, int8) decodes weak-mic zh/en speech into garbled
 * fragments ("天天还爱丽LE ISNT SHOW WE GO OUT" for a sentence the user spoke cleanly). That is
 * a model-quality ceiling no amount of tuning fixes. SenseVoice-Small is a generation ahead on
 * zh+en code-switching and ships punctuation + inverse-text normalisation, but it is
 * non-streaming: it decodes a complete utterance at once. The VAD already hands us exactly
 * that — a complete, silence-delimited speech segment — so this engine refines each segment
 * AFTER the cut, while the streaming model keeps providing live partials during speech.
 *
 * Decode cost on the MT6991: a 5 s segment in a few hundred ms, well under the VAD's 0.5 s
 * trailing silence + the translation turn, so it does not move the perceived latency.
 */
class OfflineAsr(private val paths: SenseVoicePaths?) {

    private var recognizer: OfflineRecognizer? = null

    val sampleRate: Int = 16000

    fun init() {
        if (paths == null || recognizer != null) return
        Log.i(TAG, "init model=${paths.model.takeLast(44)} exists=${paths.exists()}")
        val cfg = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = sampleRate, featureDim = 80, dither = 0f),
            modelConfig = OfflineModelConfig(
                senseVoice = OfflineSenseVoiceModelConfig(
                    model = paths.model,
                    // empty => auto-detect among zh/en/ja/ko/yue per utterance: interpretation
                    // is code-switching, and locking one language is what garbled the old model
                    language = "",
                    useInverseTextNormalization = true,
                ),
                tokens = paths.tokens,
                numThreads = 2,
                debug = false,
                provider = "cpu",
            ),
        )
        // null AssetManager -> newFromFile, the same file-system route every other engine here uses
        recognizer = OfflineRecognizer(null, cfg)
        Log.i(TAG, "init done")
    }

    /** Refined text plus the language SenseVoice detected for the segment ("zh"/"en"/...). */
    data class Refined(val text: String, val lang: String?)

    /** Decode a complete speech segment; null when unavailable (not installed / init failed). */
    fun decode(samples: FloatArray): Refined? {
        val rec = recognizer ?: return null
        if (samples.isEmpty()) return null
        val stream: OfflineStream = rec.createStream()
        stream.acceptWaveform(samples, sampleRate)
        rec.decode(stream)
        val r = rec.getResult(stream)
        return Refined(r.text, r.lang)
    }

    fun release() {
        recognizer?.release()
        recognizer = null
    }

    companion object { private const val TAG = "OfflineAsr" }
}
