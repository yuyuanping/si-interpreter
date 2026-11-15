package com.qoder.si

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The real offline translator: Tencent Hunyuan Hy-MT2-1.8B (Q4_K_M GGUF, 1.1 GB, Apache-2.0)
 * through llama.cpp. Chosen over the alternatives researched on GitHub — ONNX NLLB (RTranslator's
 * route, ~2 s/75 tokens) and Firefox Bergamot models (European languages, no zh) — because it is
 * translation-specialised, officially ships llama.cpp GGUF, and outperforms commercial MT APIs
 * in its published evals while being small enough for a 16 GB phone.
 *
 * Prompt per the model card: zh output gets the Chinese instruction wording, en output the
 * English one (mixing confuses the model). Sampling params are the card's recommendations,
 * implemented natively in si-mt.cpp (top_k 20 / top_p 0.6 / temp 0.7 / repeat 1.05).
 *
 * Latency: a spoken sentence generates ~60-120 tokens at roughly 20-40 tok/s on the MT6991's
 * big cores — 2-4 s per turn. That is real interpreter-class latency for on-device MT and it
 * sits entirely downstream of the capture loop, so it can never stall the mic.
 */
class LlamaTranslator(
    private val paths: MtPaths,
    private val nThreads: Int = 4,
) : Translator {

    /** completes with true once the native model/context are live (or false on failure) */
    private val ready = CompletableDeferred<Boolean>()

    override suspend fun prepare() {
        withContext(Dispatchers.Default) {
            ready.complete(LlamaMt.nativeInit(paths.model, nThreads))
        }
    }

    override suspend fun translate(text: String, source: String, target: String): String {
        if (!ready.await()) return "〔翻译模型加载失败〕"
        val out = withContext(Dispatchers.Default) {
            LlamaMt.nativeTranslate(buildPrompt(text, target), MAX_TOKENS)
        }
        // the model sometimes wraps the answer in quotes or echoes the instruction header
        return out.trim().trim('"', '“', '”', '『', '』').trim()
    }

    private fun buildPrompt(text: String, target: String): String = when (target) {
        "zh" -> "将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：\n\n$text"
        else -> "Translate the following text into English. Note that you should only output the translated result without any additional explanation:\n\n$text"
    }

    override fun release() {
        runCatching { LlamaMt.nativeFree() }
    }

    companion object { private const val MAX_TOKENS = 512 }
}
