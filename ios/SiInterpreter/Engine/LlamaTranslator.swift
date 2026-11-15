import Foundation

/// Swift wrapper over the si_mt C ABI (si_mt_ios.h -> vendored llama.cpp).
final class SiMtBridge {
    private let bufSize = 8192
    private var loaded = false

    var ready: Bool { loaded }

    /// Blocking native model load. Runs on the caller's background thread.
    func initialize(modelPath: String, nThreads: Int) -> Bool {
        guard !loaded else { return true }
        loaded = modelPath.withCString { p in si_mt_init(p, Int32(nThreads)) }
        return loaded
    }

    /// Blocking translate; returns "" on failure. Not thread-safe — the engine's
    /// translate worker is the only caller, same contract as the Android JNI surface.
    func translate(prompt: String, maxTokens: Int) -> String {
        guard loaded else { return "" }
        var out = [CChar](repeating: 0, count: bufSize)
        let n = prompt.withCString { p in
            si_mt_translate(p, Int32(maxTokens), &out, Int32(bufSize))
        }
        guard n > 0 else { return "" }
        return String(cString: out)
    }

    func release() {
        if loaded { si_mt_free() }
        loaded = false
    }
}

/// The real offline translator: Tencent Hunyuan Hy-MT2-1.8B (Q4_K_M GGUF, ~1.1 GB,
/// Apache-2.0) — or the installed Gemma 4 E2B A/B alternative — through the shared
/// vendored llama.cpp.
///
/// Prompt per the model card: zh output gets the Chinese instruction wording, en output
/// the English one (mixing confuses the model). Sampling params are the card's
/// recommendations, implemented natively in si_mt_ios.cpp (top_k 20 / top_p 0.6 /
/// temp 0.7 / repeat 1.05).
final class LlamaTranslator: Translator {
    private let paths: MtPaths
    private let nThreads: Int
    private let bridge = SiMtBridge()

    init(paths: MtPaths, nThreads: Int = 4) {
        self.paths = paths
        self.nThreads = nThreads
    }

    func prepare(_ done: @escaping () -> Void) {
        let p = paths.model
        let t = nThreads
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.bridge.initialize(modelPath: p, nThreads: t)
            done()
        }
    }

    func translate(text: String, source: String, target: String,
                   done: @escaping (String) -> Void) {
        guard bridge.ready else {
            done("〔翻译模型加载失败〕")
            return
        }
        let prompt = buildPrompt(text: text, target: target)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.bridge.translate(prompt: prompt, maxTokens: 512)
            // the model sometimes wraps the answer in quotes or echoes the instruction
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”『』"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            done(trimmed)
        }
    }

    private func buildPrompt(text: String, target: String) -> String {
        switch target {
        case "zh":
            return "将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
        default:
            return "Translate the following text into English. Note that you should only output the translated result without any additional explanation:\n\n\(text)"
        }
    }

    func release() {
        bridge.release()
    }
}
