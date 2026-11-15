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
}
