package com.qoder.si

import android.content.Context

/**
 * Runtime knobs. Mutable + persisted so tuning latency does not need a rebuild.
 */
class PipelineConfig(context: Context) {
    private val sp = context.getSharedPreferences("cfg", Context.MODE_PRIVATE)

    /** 100 ms is the sweet spot: smaller means more JNI churn, larger means more lag */
    var hopMs: Int = sp.getInt("hopMs", 100)
        set(v) { field = v; sp.edit().putInt("hopMs", v).apply() }

    var sourceLang: String = sp.getString("src", "en")!!
        set(v) { field = v; sp.edit().putString("src", v).apply() }

    var targetLang: String = sp.getString("tgt", "zh")!!
        set(v) { field = v; sp.edit().putString("tgt", v).apply() }

    var speakTranslation: Boolean = sp.getBoolean("speak", false)
        set(v) { field = v; sp.edit().putBoolean("speak", v).apply() }

    /** trailing silence (seconds) that ends a sentence. The old hard-coded 0.5 chopped
     *  speakers off mid-sentence on any thinking pause; the idle panel exposes presets. */
    var cutSilenceSec: Float = sp.getFloat("cutSilenceSec", 1.0f)
        set(v) { field = v; sp.edit().putFloat("cutSilenceSec", v).apply() }

    /** preferred MT bundle id, or null for the automatic A/B order (Gemma 4 first).
     *  Honoured only when that bundle is actually installed; otherwise the auto order
     *  applies, so a deleted pick never bricks translation. */
    var mtBundleId: String? = sp.getString("mtBundle", null)
        set(v) { field = v; sp.edit().putString("mtBundle", v).apply() }
}
