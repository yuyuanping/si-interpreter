package com.qoder.si

import android.content.Context
import android.media.AudioFormat
import android.util.Log
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.jvm.Throws

data class Utterance(
    val id: Int,
    val sourceText: String,
    val translated: String,
    val source: String,
    val target: String,
    val pending: Boolean = false,
    /** end-of-speech -> translation-ready, the number that tells you if this feels live */
    val latencyMs: Long = 0,
)

sealed interface EngineState {
    data object Idle : EngineState
    data object Loading : EngineState
    data object Running : EngineState
    data class Error(val message: String) : EngineState
}

/**
 * The pipeline: AudioRecord -> streaming ASR -> endpoint cut -> translate -> publish.
 *
 * Threading contract, this is what decides whether the UI stays smooth and the mic stays
 * continuous:
 *  - [captureLoop] touches only the mic and the ASR encoder. It must never await the
 *    translator, or a 400 ms model call blocks reads and the kernel drops audio.
 *  - finished utterances go into a Channel of capacity 1, newest wins. When translation
 *    is slower than speech we drop the OLD turn, which is what a human interpreter does:
 *    you let go of the previous sentence rather than fall behind forever. Buffering
 *    instead would grow unbounded latency and look like the app froze.
 */
class InterpreterEngine(
    private val context: Context,
    private val asr: AsrEngine,
    private val translator: Translator,
    private val config: PipelineConfig,
    private val vadPath: VadPath? = null,
    private val senseVoicePath: SenseVoicePaths? = null,
    private val onFinished: (Utterance) -> Unit = {},
) {

    /**
     * Speech gate. Built from the resolved [vadPath] at start(); null path -> the gate runs
     * in "always feed" mode so the app still works without the VAD model installed. This is
     * the field that makes ambient-noise hallucination go away: when null, the capture loop
     * behaves exactly as it did before VAD was added.
     */
    private var gate: VadGate? = null

    /**
     * System-TTS playback of finished translations, and tap-to-replay of history rows.
     * Always built at start() so replay works regardless of the toggle; [PipelineConfig]
     * speakTranslation only governs AUTO-speaking. While [TtsPlayer.muted] is true the
     * capture loop drops hops: the speaker output reaches the mic, and transcribing our
     * own voice is the exact failure mode the VAD exists to prevent.
     */
    private var tts: TtsPlayer? = null

    /**
     * Offline refinement engine (SenseVoice). Decodes each completed VAD segment whole —
     * this is what the user sees as the final transcript. Brought up LAZILY in its own
     * coroutine: session init for a 228 MB int8 model can take a while on flash+CPU, and
     * making the mic wait for it would reproduce the very freeze this architecture exists
     * to prevent. null -> streaming transcript published as-is. @Volatile: written by the
     * bring-up coroutine, read by capture/refine loops.
     */
    @Volatile private var offline: OfflineAsr? = null
    private val _state = MutableStateFlow<EngineState>(EngineState.Idle)
    val state: StateFlow<EngineState> = _state

    private val _live = MutableStateFlow("")
    val live: StateFlow<String> = _live

    private val _history = MutableStateFlow<List<Utterance>>(emptyList())
    val history: StateFlow<List<Utterance>> = _history

    private val _stats = MutableStateFlow(Stats())
    val stats: StateFlow<Stats> = _stats

    /** RMS of the most recent hop, linear 0..1; on screen only as dBFS */
    @Volatile var peakLevel: Float = 0f
        private set

    /**
     * Set from the UI to cut the current utterance on the next hop. This is how endpoint
     * latency gets measured instead of guessed: say one known sentence, tap, and the logged
     * timestamp gap is the real end-of-speech-to-cut time. A rule that only ever fires on
     * noise hallucinations looks identical on screen.
     */
    @Volatile var forceCut = false

    data class Stats(
        val secondsHeard: Float = 0f,
        val utterances: Int = 0,
        val asrMs: Long = 0,
        val translateMs: Long = 0,
        val dropped: Int = 0,
        /**
         * dBFS of the current hop and of the loudest hop so far. Without these, an ASR that
         * emits hallucinated fragments is undiagnosable: "mic is too quiet" and "endpoint
         * cuts too early" read identically in the text and need opposite fixes.
         */
        val levelDb: Float = -120f,
        val peakDb: Float = -120f,
    )

    /** one turn on the way to translation: the text plus the language it was detected in */
    data class Turn(val text: String, val detectedLang: String?)

    private var scope: CoroutineScope? = null
    private val queue = Channel<Turn>(capacity = 1)
    /** segments awaiting offline refinement; capacity 2 newest-wins so a slow SenseVoice
     *  decode of one long segment makes us drop stale audio, never stop reading the mic */
    private val refineQueue = Channel<FloatArray>(capacity = 2)
    private val buffer = ContextBuffer()
    private var nextId = 0

    suspend fun start() {
        try {
            _state.value = EngineState.Loading
            withContext(Dispatchers.Default) {
                asr.init()
                // build the gate on the same background dispatcher as ASR init: Silero VAD is
                // a tiny (~2 MB) ONNX model but its native ctor still touches disk+ONNXRuntime,
                // so keep it off the main thread for the same reason as the 175 MB encoder.
                gate = VadGate(vadPath, asr.sampleRate, config.cutSilenceSec)
                tts = TtsPlayer(context)
            }
            Log.i(TAG, "started gate.enabled=${gate?.enabled == true}")
            _state.value = EngineState.Running
        } catch (e: Throwable) {
            _state.value = EngineState.Error("模型加载失败: ${e.message}")
            return
        }

        val sc = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scope = sc
        sc.launch { translateLoop() }
        sc.launch { refineLoop() }
        sc.launch { captureLoop() }
        if (senseVoicePath != null) {
            // lazy bring-up: Running state reflects streaming readiness; refinement comes
            // online on its own a few seconds in. Until then cuts fall back to streaming text.
            sc.launch {
                try {
                    val off = OfflineAsr(senseVoicePath)
                    off.init()
                    offline = off
                    Log.i(TAG, "offline asr ready")
                } catch (e: Throwable) {
                    Log.e(TAG, "offline asr init failed, streaming-only: ${e.message}")
                }
            }
        }
        // translator bring-up (llama.cpp loads a 1.1 GB GGUF) runs in parallel too; the
        // translate loop awaits it on its first turn, so an early utterance waits rather
        // than ships untranslated
        sc.launch {
            try {
                translator.prepare()
                Log.i(TAG, "translator ready")
            } catch (e: Throwable) {
                Log.e(TAG, "translator prepare failed: ${e.message}")
            }
        }
    }

    fun stop() {
        scope?.cancel()
        scope = null
        tts?.shutdown()
        tts = null
        gate?.release()
        gate = null
        offline?.release()
        offline = null
        asr.release()
        _state.value = EngineState.Idle
        _live.value = ""
        peakLevel = 0f
    }

    private suspend fun captureLoop() {
        val hop = 16000 * config.hopMs / 1000            // 100 ms -> 1600 samples
        val pcm = ShortArray(hop)
        val f = FloatArray(hop)

        val minBuf = AudioRecord.getMinBufferSize(
            16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuf <= 0) {
            _state.value = EngineState.Error("此设备不支持 16kHz 单声道录音")
            return
        }

        val rec = try {
            @Suppress("MissingPermission")
            AudioRecord(
                // VOICE_RECOGNITION: unlike MIC it skips the aggressive gain control that
                // pumps up room noise between sentences and makes streaming ASR hallucinate
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                16000,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, hop * 4),
            )
        } catch (e: SecurityException) {
            _state.value = EngineState.Error("没有录音权限")
            return
        }

        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            _state.value = EngineState.Error("麦克风初始化失败")
            return
        }

        try {
            rec.startRecording()
            // per-segment accumulators; logged at every cut so a hallucinated fragment can be
            // told apart from real speech by ITS LOUDNESS, which is the only hard evidence
            // of whether VOICE_RECOGNITION is feeding the model a usable signal
            var segSamples = 0L
            var segPeakDb = -120f
            var lastDbLog = 0L
            var cutCount = 0

            while (currentCoroutineContext().isActive) {
                val n = rec.read(pcm, 0, hop)
                if (n <= 0) continue
                // TTS playback mutes the pipeline: the speaker output reaches the mic
                // and transcribing our own voice is the failure mode the VAD exists to
                // prevent. Dropped hops are gone — speech over the playback is lost,
                // same as a human interpreter talking over the translation.
                if (tts?.muted == true) continue
                val frame = if (n == hop) f else f.copyOf(n)
                for (i in 0 until n) f[i] = pcm[i] / 32768f
                val level = rms(f, n)
                peakLevel = level
                val db = toDb(level)
                segSamples += n
                if (db > segPeakDb) segPeakDb = db

                val now = System.currentTimeMillis()
                // one level line every 5 s whether or not anything was recognised: without it
                // a silent-looking screen cannot be read as "too quiet" versus "no speech"
                if (now - lastDbLog > 5_000) {
                    lastDbLog = now
                    Log.i(TAG, "level=%.1f dBFS peak=%.1f heard=%.1fs cuts=%d".format(db, segPeakDb, segSamples / 16000f, cutCount))
                }

                // VAD gate: feed the hop to the gate FIRST. Only when it reports speech do we
                // hand audio to the ASR. This is the hallucination fix — the transducer never
                // sees room tone, so it cannot invent "THINK"/"ER SINGER" out of nothing. The
                // gate also surfaces a segmentEnded signal (VAD's own silence timer) that is a
                // more trustworthy utterance boundary than the ASR endpoint on noisy input.
                val g = gate
                val speech = g?.feed(frame) ?: true
                val vadSegment: FloatArray? = g?.segmentEnded()

                val partial: String
                val t0 = System.currentTimeMillis()
                if (speech) {
                    // The vivo mic (VOICE_RECOGNITION source) hands us a weak signal: observed
                    // speech peaks at ~-23 dBFS where a near-mic voice should be -3..-12. The
                    // Zipformer was trained on normalised audio, so feeding it -25 dB frames
                    // yields empty hypotheses even on clear speech. Boost speech hops toward a
                    // -12 dBFS RMS target before decode. The VAD already ate the ORIGINAL frame,
                    // so this gain does not perturb VAD state — it only conditions what the ASR
                    // sees. Noise hops are not boosted (they are not decoded), so gain never
                    // amplifies the very room tone the VAD is there to suppress.
                    val boosted = boostForAsr(frame, n)
                    partial = asr.accept(boosted)
                } else {
                    // not feeding silence keeps the RNN-T context clean; the live hypothesis
                    // from the last speech hop stays on screen until a cut fires
                    partial = _live.value
                }
                _stats.update {
                    it.copy(
                        secondsHeard = it.secondsHeard + n / 16000f,
                        asrMs = System.currentTimeMillis() - t0,
                        levelDb = db,
                        peakDb = maxOf(it.peakDb, db),
                    )
                }
                if (partial != _live.value) _live.value = partial

                // three independent cut triggers, all valid:
                //  - vadSegment != null: the VAD's silence timer fired -> trustworthy sentence
                //    boundary, and it hands us the COMPLETE segment audio for offline refinement
                //  - endpoint: the ASR's own rule2 (trailing silence after speech) -> the
                //    fallback that works when no VAD is installed, and a second opinion when
                //    one is. Kept because the ASR sometimes endpoint-cuts a hair earlier than
                //    the VAD, and that lower latency is worth taking.
                //  - forced: the 切断 button, for measuring end-of-speech->cut latency by hand.
                val endpoint = partial.isNotBlank() && asr.isEndpoint()
                val forced = forceCut && partial.isNotBlank()
                if (vadSegment != null || endpoint || forced) {
                    val streamed = asr.flush().trim()
                    forceCut = false
                    _live.value = ""
                    val why = buildString {
                        if (forced) append("FORCED")
                        else if (vadSegment != null) append("vad")
                        else append("endpoint")
                    }
                    Log.i(TAG, "cut#${++cutCount} $why " +
                        "dur=%.1fs peak=%.1fdB stream=[%s]".format(
                            segSamples / 16000f, segPeakDb, streamed))
                    segSamples = 0L
                    segPeakDb = -120f

                    if (vadSegment != null && offline != null) {
                        // Hand the segment to the refinement worker and move on — awaiting
                        // SenseVoice here is what froze the mic reads (a long segment decodes
                        // for seconds-minutes and the kernel ring buffer overruns). If the
                        // refiner is already 2 segments behind, publish the streaming text so
                        // the turn ships rather than queues: same newest-wins contract as
                        // translation.
                        val r = refineQueue.trySend(vadSegment)
                        if (r.isSuccess) {
                            Log.i(TAG, "queued segment ${vadSegment.size / 16000.0}s for refinement")
                        } else {
                            runCatching { refineQueue.tryReceive().getOrNull() }
                            if (refineQueue.trySend(vadSegment).isFailure && streamed.isNotEmpty()) {
                                offer(Turn(streamed, null))
                            }
                        }
                    } else if (streamed.isNotEmpty()) {
                        // no refiner installed, or an endpoint/forced cut with no VAD segment
                        // audio: the streaming hypothesis is all we have
                        offer(Turn(streamed, null))
                    }
                }
            }
        } finally {
            runCatching { rec.stop() }
            rec.release()
        }
    }

    /** newest-wins handoff; a full queue means the speaker outran the model */
    private fun offer(turn: Turn) {
        val q = queue
        if (q.isClosedForSend) return
        val r = q.trySend(turn)
        if (r.isSuccess) return
        // drop the stale one and push the new turn
        runCatching { q.tryReceive().getOrNull() }
        if (q.trySend(turn).isFailure) {
            _stats.update { it.copy(dropped = it.dropped + 1) }
        }
    }

    /**
     * Offline refinement worker. Owns the SenseVoice decode so the capture thread never
     * awaits it. Takes the newest segment, caps it at 30 s (SenseVoice cost grows with
     * length; a TTS blaring in the background can otherwise hand us 60 s chunks that pin a
     * CPU for minutes), and routes the refined text into the translation queue — it becomes
     * the transcript the user actually sees. Empty refinement keeps the turn alive via the
     * already-published streaming text, so nothing is ever lost twice.
     */
    private suspend fun refineLoop() {
        val maxSamples = 30 * 16000
        for (seg in refineQueue) {
            val off = offline ?: continue
            val capped = if (seg.size > maxSamples) {
                Log.w(TAG, "segment %.1fs exceeds 30s cap, refining the tail".format(seg.size / 16000f))
                seg.copyOfRange(seg.size - maxSamples, seg.size)
            } else seg

            val t0 = System.currentTimeMillis()
            val ref = try {
                off.decode(capped)
            } catch (e: Throwable) {
                Log.e(TAG, "offline decode failed: ${e.message}")
                null
            }
            _stats.update { it.copy(asrMs = System.currentTimeMillis() - t0) }
            val txt = ref?.text?.trim().orEmpty()
            Log.i(TAG, "refined %.1fs in %dms lang=%s -> [%s]".format(
                capped.size / 16000f, System.currentTimeMillis() - t0, ref?.lang, txt))
            if (txt.isNotEmpty()) offer(Turn(txt, ref?.lang))
        }
    }

    private suspend fun translateLoop() {
        for (turn in queue) {
            // Direction per utterance, from the language SenseVoice actually detected —
            // speakers code-switch mid-session, and a fixed en->zh chip fed Chinese text to
            // a "translate into Chinese" instruction, which the model rightly echoed back.
            // SenseVoice reports the lang as the raw first token, e.g. "<|zh|>" (tokens.txt
            // keeps the decorator form), so match by substring, never equality. Cantonese
            // ("yue") writes as Chinese. The configured direction is only the fallback for
            // turns with no detection (streaming path).
            val detected = turn.detectedLang?.lowercase()?.let { raw ->
                when {
                    "zh" in raw || "yue" in raw -> "zh"
                    "en" in raw -> "en"
                    else -> null
                }
            }
            val src = detected ?: config.sourceLang
            val tgt = if (src == "zh") "en" else "zh"
            val text = turn.text
            val id = ++nextId

            _history.value = (_history.value + Utterance(id, text, "", src, tgt, pending = true))
                .takeLast(80)

            val t0 = System.currentTimeMillis()
            val out = try {
                translator.translate(text, src, tgt)
            } catch (e: Exception) {
                "〔翻译失败: ${e.message}〕"
            }
            val ms = System.currentTimeMillis() - t0
            Log.i(TAG, "translate#$id %s->%s %dms src=[%s] out=[%s]".format(src, tgt, ms, text, out))

            buffer.note(src, tgt)
            val done = Utterance(id, text, out, src, tgt, pending = false, latencyMs = ms)
            _history.value = _history.value.map { if (it.id == id) done else it }
            _stats.update { it.copy(translateMs = ms, utterances = id) }
            // auto-speak follows the toggle; tapping a history row replays regardless
            if (config.speakTranslation) tts?.speak(out, tgt)
            onFinished(done)
        }
    }

    /** speak one already-translated utterance again (tap on a history row) */
    fun replay(u: Utterance) {
        tts?.speak(u.translated, u.target)
    }

    fun clear() {
        forceCut = false
        _history.value = emptyList()
        buffer.clear()
        nextId = 0
        _stats.value = Stats()
    }

    companion object { private const val TAG = "Engine" }

    private fun rms(s: FloatArray, n: Int): Float {
        var acc = 0.0
        for (i in 0 until n) acc += (s[i] * s[i]).toDouble()
        return Math.sqrt(acc / n.coerceAtLeast(1)).toFloat()
    }

    /** linear RMS -> dBFS, floored so the HUD never shows -Inf */
    private fun toDb(linear: Float): Float =
        if (linear <= 1e-6f) -120f else (20 * Math.log10(linear.toDouble())).toFloat()

    /**
     * Boost a speech hop toward a -12 dBFS RMS target (linear ~0.25) so the ASR — trained on
     * normalised audio — actually decodes it on a weak mic. Caps the gain at 8x to avoid
     * exploding a quiet-but-noisy frame into clipping noise. Returns a fresh array when gain
     * applies, or the same array (no-op) when the signal is already loud enough — so the
     * zero-copy fast path for full reads is preserved in the common loud-speech case.
     */
    private fun boostForAsr(s: FloatArray, n: Int): FloatArray {
        val r = rms(s, n)
        if (r <= 1e-5f) return s                       // near-silent: leave it
        val target = 0.25f                             // ~-12 dBFS
        var gain = (target / r).coerceAtMost(8f)
        if (gain <= 1.05f) return s                    // already loud enough; no copy
        val out = FloatArray(n)
        for (i in 0 until n) {
            var v = s[i] * gain
            if (v > 1f) v = 1f else if (v < -1f) v = -1f   // hard clip; ASR tolerates it
            out[i] = v
            // don't keep boosting into clipping: once we saturate, pull gain back for the rest
            if (v >= 1f || v <= -1f) gain = (gain * 0.85f).coerceAtLeast(1f)
        }
        return out
    }
}
