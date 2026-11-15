import Foundation

/// Catalogue of the model bundles this app knows how to fetch or sideload.
/// Port of the Android Bundles.kt — same ids, same HF paths, same minimum sizes.
struct FileSpec {
    let remote: String
    let local: String
    let minBytes: Int64
}

struct Bundle {
    enum Kind { case asr, vad, mt, tts }

    let id: String
    let label: String
    let kind: Kind
    /// {repo} is substituted, so a bundle works from either mirror
    let path: String
    let files: [FileSpec]
    let note: String
    /// override of Bundles.bases for bundles the HF mirrors cannot serve: hf-mirror
    /// answers 401 for snakers4/silero-vad, so that one must come from GitHub raw
    var bases: [String]? = nil

    var totalMb: Int64 { files.map(\.minBytes).reduce(0, +) / 1_000_000 }

    func urlFor(_ base: String) -> String {
        base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" +
            path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// URL of one file in the bundle. The installer used to pass urlFor(base) alone —
    /// the filename never landed on the URL, so every multi-file bundle fetched the
    /// repo's directory page (HTML) and failed its size check. Silero only ever worked
    /// because its path happened to contain the name.
    func fileUrl(_ base: String, _ fs: FileSpec) -> String {
        urlFor(base).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + fs.remote
    }
}

enum Bundles {
    // hf-mirror.com is the reachable copy of the HF CDN from mainland networks; both are
    // tried in order so the installer works anywhere.
    static let hf = "https://huggingface.co"
    static let hfMirror = "https://hf-mirror.com"
    static let bases = [hfMirror, hf]

    /// streaming zh+en Zipformer, int8: one model transcribes BOTH languages, which is
    /// what an interpreter session needs (speakers code-switch mid-sentence).
    static let asrZipformerBilingual = Bundle(
        id: "asr-zipformer-bilingual-int8",
        label: "流式中英识别 (Zipformer, int8)",
        kind: .asr,
        path: "csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main",
        files: [
            FileSpec(remote: "encoder-epoch-99-avg-1.int8.onnx", local: "encoder.onnx", minBytes: 175_000_000),
            FileSpec(remote: "decoder-epoch-99-avg-1.int8.onnx", local: "decoder.onnx", minBytes: 12_500_000),
            FileSpec(remote: "joiner-epoch-99-avg-1.int8.onnx", local: "joiner.onnx", minBytes: 3_100_000),
            FileSpec(remote: "tokens.txt", local: "tokens.txt", minBytes: 50_000),
        ],
        note: "约 196 MB · 中英混说自动识别，内置端点检测"
    )

    /// Silero VAD v5 (~2.2 MB). Tiny, MIT-licensed, and the single fix for the
    /// ambient-noise hallucination problem.
    static let vadSilero = Bundle(
        id: "vad-silero-v5",
        label: "语音活动检测 (Silero v5)",
        kind: .vad,
        path: "snakers4/silero-vad/raw/refs/tags/v5.0/files",
        files: [FileSpec(remote: "silero_vad.onnx", local: "silero_vad.onnx", minBytes: 2_000_000)],
        note: "约 2.2 MB · MIT 协议 · 拦截环境噪音，只把人声喂给识别",
        bases: ["https://github.com"],
    )

    /// SenseVoice-Small offline (~228 MB int8). The accuracy path: decodes each
    /// VAD-delimited speech segment whole, with punctuation and zh/en auto code-switching.
    static let asrSenseVoice = Bundle(
        id: "asr-sensevoice-zh-en-int8",
        label: "离线精识别 (SenseVoice, int8)",
        kind: .asr,
        path: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main",
        files: [
            FileSpec(remote: "model.int8.onnx", local: "model.int8.onnx", minBytes: 230_000_000),
            FileSpec(remote: "tokens.txt", local: "tokens.txt", minBytes: 300_000),
        ],
        note: "约 228 MB · VAD 分段后整段精解码，带标点，中英混说大幅更准"
    )

    /// Tencent Hunyuan Hy-MT2-1.8B, Q4_K_M GGUF (~1.1 GB, Apache-2.0). The offline
    /// translator through the shared vendored llama.cpp. The smaller 2bit/1.25bit quants
    /// use AngelSlim's STQ format that upstream llama.cpp cannot decode yet.
    static let mtHymt2 = Bundle(
        id: "mt-hymt2-1.8b-q4km",
        label: "离线翻译 (腾讯混元 Hy-MT2 1.8B)",
        kind: .mt,
        path: "tencent/Hy-MT2-1.8B-GGUF/resolve/main",
        files: [FileSpec(remote: "Hy-MT2-1.8B-Q4_K_M.gguf", local: "model.gguf", minBytes: 1_100_000_000)],
        note: "约 1.1 GB · 中英互译专用模型，llama.cpp 推理，纯本地"
    )

    /// Google Gemma 4 E2B-it, Q4_K_M GGUF (~3.1 GB, Apache-2.0) — the A/B alternative
    /// translator. General-purpose LLM (2.3B effective of 5.1B total via PLE). The
    /// vendored llama.cpp carries the gemma4 arch; the GGUF's chat template drives the
    /// prompt path unchanged. Installed Gemma wins over Hy-MT2 in ModelStore.
    static let mtGemma4E2B = Bundle(
        id: "mt-gemma4-e2b-q4km",
        label: "离线翻译 (谷歌 Gemma 4 E2B)",
        kind: .mt,
        path: "unsloth/gemma-4-E2B-it-GGUF/resolve/main",
        files: [FileSpec(remote: "gemma-4-E2B-it-Q4_K_M.gguf", local: "model.gguf", minBytes: 2_900_000_000)],
        note: "约 3.1 GB · 通用多语言模型（有效 2.3B），llama.cpp 推理，纯本地"
    )

    static let all: [Bundle] = [asrZipformerBilingual, asrSenseVoice, vadSilero, mtHymt2, mtGemma4E2B]

    static func byId(_ id: String) -> Bundle? { all.first { $0.id == id } }

    /// bundles that must be present before the pipeline can start well
    static var required: [Bundle] { [asrZipformerBilingual, vadSilero] }
}
