package com.qoder.si

/**
 * Catalogue of the model bundles this app knows how to fetch and load.
 *
 * Min-size values are the real file sizes from the upstream repo with ~10% slack: they
 * exist purely to catch a truncated download, not to validate a model.
 */
data class FileSpec(val remote: String, val local: String, val minBytes: Long)

data class Bundle(
    val id: String,
    val label: String,
    val kind: Kind,
    /** {repo} is substituted, so a bundle works from either mirror */
    val path: String,
    val files: List<FileSpec>,
    val note: String = "",
) {
    enum class Kind { ASR, VAD, MT, TTS }
    val totalMb: Long get() = files.sumOf { it.minBytes } / 1_000_000

    fun urlFor(base: String) = "${base.trimEnd('/')}/${path.trimStart('/')}"
}

object Bundles {

    // hf-mirror.com is the reachable copy of the HF CDN from mainland networks; both are
    // tried in order so the installer works anywhere.
    const val HF = "https://huggingface.co"
    const val HF_MIRROR = "https://hf-mirror.com"
    val bases = listOf(HF_MIRROR, HF)

    /** streaming zh+en Zipformer, int8: one model transcribes BOTH languages, which is
     *  what an interpreter session needs (speakers code-switch mid-sentence). */
    val asrZipformerBilingual = Bundle(
        id = "asr-zipformer-bilingual-int8",
        label = "流式中英识别 (Zipformer, int8)",
        kind = Bundle.Kind.ASR,
        path = "csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main",
        files = listOf(
            FileSpec("encoder-epoch-99-avg-1.int8.onnx", "encoder.onnx", 175_000_000),
            FileSpec("decoder-epoch-99-avg-1.int8.onnx", "decoder.onnx", 12_500_000),
            FileSpec("joiner-epoch-99-avg-1.int8.onnx", "joiner.onnx", 3_100_000),
            FileSpec("tokens.txt", "tokens.txt", 50_000),
        ),
        note = "约 196 MB · 中英混说自动识别，内置端点检测",
    )

    /**
     * Silero VAD v5 (~2.2 MB). Tiny, MIT-licensed, and the single fix for the ambient-noise
     * hallucination problem: gating the ASR on "is there speech" stops the Zipformer from
     * being fed room tone and inventing fragments like "THINK"/"ER SINGER" out of nothing.
     * Without it, dBFS alone cannot tell noise from speech, so endpoint tuning is a gamble.
     */
    val vadSilero = Bundle(
        id = "vad-silero-v5",
        label = "语音活动检测 (Silero v5)",
        kind = Bundle.Kind.VAD,
        // snakers4/silero-vad GitHub release is a stable CDN copy that does not need HF auth
        path = "snakers4/silero-vad/raw/refs/tags/v5.0/files/silero_vad.onnx",
        files = listOf(
            FileSpec("silero_vad.onnx", "silero_vad.onnx", 2_000_000),
        ),
        note = "约 2.2 MB · MIT 协议 · 拦截环境噪音，只把人声喂给识别",
    )

    /**
     * SenseVoice-Small offline (~228 MB int8). The accuracy path: decodes each VAD-delimited
     * speech segment whole, with punctuation and zh/en auto code-switching — a generation
     * ahead of the 2023 streaming Zipformer, whose garbled mixed-language fragments are the
     * "识别不准" complaint. Optional: without it the streaming transcript goes straight out.
     */
    val asrSenseVoice = Bundle(
        id = "asr-sensevoice-zh-en-int8",
        label = "离线精识别 (SenseVoice, int8)",
        kind = Bundle.Kind.ASR,
        path = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main",
        files = listOf(
            FileSpec("model.int8.onnx", "model.int8.onnx", 230_000_000),
            FileSpec("tokens.txt", "tokens.txt", 300_000),
        ),
        note = "约 228 MB · VAD 分段后整段精解码，带标点，中英混说大幅更准",
    )

    /**
     * Tencent Hunyuan Hy-MT2-1.8B, Q4_K_M GGUF (1.1 GB, Apache-2.0) — the offline translator.
     * Runs through the vendored llama.cpp (libsi_mt.so). Translation-specialised: published
     * evals put the 1.8B above mainstream commercial MT APIs. Q4_K_M is the right quant for
     * this phone — the smaller 2bit/1.25bit quants use AngelSlim's STQ format that upstream
     * llama.cpp cannot decode yet.
     */
    val mtHymt2 = Bundle(
        id = "mt-hymt2-1.8b-q4km",
        label = "离线翻译 (腾讯混元 Hy-MT2 1.8B)",
        kind = Bundle.Kind.MT,
        path = "tencent/Hy-MT2-1.8B-GGUF/resolve/main",
        files = listOf(
            FileSpec("Hy-MT2-1.8B-Q4_K_M.gguf", "model.gguf", 1_100_000_000),
        ),
        note = "约 1.1 GB · 中英互译专用模型，llama.cpp 推理，纯本地",
    )

    /**
     * Google Gemma 4 E2B-it, Q4_K_M GGUF (~3.1 GB, Apache-2.0) — the A/B alternative
     * translator. General-purpose LLM (2.3B effective of 5.1B total via PLE), pre-trained
     * on 140+ languages. Runs on the same vendored llama.cpp: the build already carries the
     * gemma4 arch (incl. PLE prefetch), and the GGUF's embedded chat template drives the
     * prompt path unchanged. No official Google GGUF — unsloth's community build is the
     * standard copy. Thinking mode only activates via a system-prompt <|think|> token this
     * app never sends. Installed when present takes priority over Hy-MT2 (ModelStore).
     */
    val mtGemma4E2B = Bundle(
        id = "mt-gemma4-e2b-q4km",
        label = "离线翻译 (谷歌 Gemma 4 E2B)",
        kind = Bundle.Kind.MT,
        path = "unsloth/gemma-4-E2B-it-GGUF/resolve/main",
        files = listOf(
            FileSpec("gemma-4-E2B-it-Q4_K_M.gguf", "model.gguf", 2_900_000_000),
        ),
        note = "约 3.1 GB · 通用多语言模型（有效 2.3B），llama.cpp 推理，纯本地",
    )

    val all: List<Bundle> = listOf(
        asrZipformerBilingual, asrSenseVoice, vadSilero, mtHymt2, mtGemma4E2B,
    )

    fun byId(id: String): Bundle? = all.find { it.id == id }

    /** bundles that must be present before the pipeline can start well */
    val required: List<Bundle> get() = listOf(asrZipformerBilingual, vadSilero)
}
