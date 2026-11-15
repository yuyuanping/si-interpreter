package com.qoder.si

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.util.Locale

/**
 * Speaks finished translations through the system TTS engine. Zero download: the engine
 * is whatever the ROM ships (vivo's built-in synthesiser covers zh and en offline).
 *
 * The speaker output reaches the mic, and an interpreter that transcribes its own voice
 * is exactly the hallucination the VAD exists to prevent — so [muted] is part of the
 * contract with the capture loop: while it is true, hops are dropped. It clears only
 * [GRACE_MS] after the synthesis callback, covering the reverb tail still reaching the
 * mic after onDone fires.
 *
 * QUEUE_FLUSH gives a new translation the newest-wins treatment, same as the turn queue.
 */
class TtsPlayer(context: Context) {

    @Volatile var muted = false
        private set

    private val tts = TextToSpeech(context.applicationContext, ::onInit)
    private val handler = Handler(Looper.getMainLooper())
    private var unmute: Runnable? = null

    @Volatile private var ready = false

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) = finishPlayback()
            override fun onError(utteranceId: String?) = finishPlayback()
        })
    }

    private fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        Log.i(TAG, "tts init ok=$ready engine=${tts.defaultEngine}")
    }

    fun speak(text: String, lang: String) {
        if (!ready || text.isBlank()) return
        cancelUnmute()
        muted = true
        // fallback chain: a plain setLanguage(Locale.US) on a ROM carrying only the
        // generic zh voice must not fail silently into the wrong-language default voice
        val candidates = if (lang == "zh")
            listOf(Locale.SIMPLIFIED_CHINESE, Locale.CHINESE, Locale.TAIWAN, Locale("zh"))
        else
            listOf(Locale.US, Locale.ENGLISH, Locale.UK, Locale("en"))
        var res = TextToSpeech.LANG_NOT_SUPPORTED
        for (loc in candidates) {
            res = tts.setLanguage(loc)
            if (res >= TextToSpeech.LANG_AVAILABLE) break
        }
        Log.i(TAG, "speak lang=$lang setLang=$res text=[${text.take(24)}]")
        val r = tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "utt")
        // an enqueue failure fires NO callback — without this the mute would stick and
        // the capture loop would drop hops forever
        if (r != TextToSpeech.SUCCESS) {
            Log.w(TAG, "speak enqueue failed r=$r")
            finishPlayback()
        }
    }

    /** cancel playback and unmute immediately — teardown path */
    fun shutdown() {
        cancelUnmute()
        muted = false
        runCatching { tts.stop(); tts.shutdown() }
    }

    private fun finishPlayback() {
        // a queued second utterance may still be speaking: its own callback re-arms the
        // unmute, so bail out instead of unmuting underneath it
        if (tts.isSpeaking) return
        unmute = Runnable { muted = false }.also { handler.postDelayed(it, GRACE_MS) }
    }

    private fun cancelUnmute() {
        unmute?.let { handler.removeCallbacks(it) }
        unmute = null
    }

    companion object {
        private const val TAG = "TtsPlayer"
        private const val GRACE_MS = 500L
    }
}
