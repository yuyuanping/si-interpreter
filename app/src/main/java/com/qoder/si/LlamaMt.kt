package com.qoder.si

/**
 * JNI bridge to libsi_mt.so — see app/src/main/cpp/si-mt.cpp. One model, one context, one
 * blocking translate call; all heavy work happens on the caller's (Default) dispatcher.
 */
object LlamaMt {
    init { System.loadLibrary("si_mt") }

    external fun nativeInit(modelPath: String, nThreads: Int): Boolean
    external fun nativeTranslate(prompt: String, maxTokens: Int): String
    external fun nativeFree()
}
