package com.qoder.si

/**
 * NOT A REAL TRANSLATOR. This exists only so the ASR/latency/UI path can be exercised on a
 * phone before the offline MT engine lands. It passes text through with a marker.
 *
 * Do not ship this and do not mistake its output for translation.
 */
class PlaceholderTranslator : Translator {
    override suspend fun translate(text: String, source: String, target: String): String {
        kotlinx.coroutines.delay(120)   // pretend cost, so latency HUD is non-zero
        return "⟨MT未安装⟩ $text"
    }

    override fun release() {}
}
