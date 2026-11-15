package com.qoder.si

/**
 * Translation is deliberately behind an interface: the offline MT choice is the hardest
 * part of this app and the only realistic answer changes with the model you can fit on the
 * device. Everything upstream of this (capture / VAD / streaming ASR) is settled and must
 * not have to change when the engine does.
 */
interface Translator {

    /**
     * One-time heavy bring-up (native model load). The engine launches it in parallel with
     * everything else; [translate] implementations must suspend until it completes, never
     * run concurrent with it. Default no-op for engines with no setup phase.
     */
    suspend fun prepare() {}

    /** "auto" | "zh" | "en" ... ; target is the language we want to speak/see. */
    suspend fun translate(text: String, source: String, target: String): String

    fun release()
}

/**
 * Interpretation needs context, not sentence isolation: a translator that sees one
 * sentence at a time will mis-resolve pronouns and drop terms the speaker only defined
 * two sentences ago. Keep a short rolling window and hand it to the model.
 */
class ContextBuffer(private val maxTurns: Int = 6) {
    private val turns = ArrayDeque<String>()

    fun note(src: String, dst: String) {
        turns.addLast("[$src -> $dst]")
        while (turns.size > maxTurns) turns.removeFirst()
    }

    fun promptContext(): String = turns.joinToString("\n")

    fun clear() = turns.clear()
}
