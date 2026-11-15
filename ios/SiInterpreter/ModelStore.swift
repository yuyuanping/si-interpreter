import Foundation

/// Finds and validates model bundles.
///
/// iOS has no adb; the sideload root is the app's Documents directory, which is exposed
/// through Finder / the Files app (UIFileSharingEnabled). The user drags a bundle folder
/// there and the app reads it in place — the same zero-network contract as the Android
/// external root, minus the USB tooling.
final class ModelStore {
    /// where the in-app installer writes AND where Finder drops land; one root keeps
    /// ownership unambiguous (the Android split existed because adb push cannot write
    /// into the app sandbox — Finder can).
    let root: URL

    init() {
        root = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func installDir(_ bundle: String) -> URL {
        let d = root.appendingPathComponent(bundle, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// the directory this bundle actually lives in and passes its minimum-size check
    func resolveDir(_ bundle: String) -> URL? {
        let dir = root.appendingPathComponent(bundle, isDirectory: true)
        return present(in: dir, bundle: bundle) ? dir : nil
    }

    private func present(in dir: URL, bundle: String) -> Bool {
        guard let spec = Bundles.byId(bundle),
              FileManager.default.fileExists(atPath: dir.path, isDirectory: nil) else { return false }
        return spec.files.allSatisfy { fs in
            let p = dir.appendingPathComponent(fs.local).path
            guard let attr = try? FileManager.default.attributesOfItem(atPath: p),
                  let size = attr[.size] as? Int64 else { return false }
            return size >= fs.minBytes
        }
    }

    func complete(_ bundle: String) -> Bool { resolveDir(bundle) != nil }

    /// catalogue bundles that are present and complete
    func installed() -> [String] { Bundles.all.map(\.id).filter { complete($0) } }

    /// paths of the streaming ASR bundle, or nil when not installed
    func pathsAsr() -> ModelPaths? {
        guard let d = resolveDir(Bundles.asrZipformerBilingual.id) else { return nil }
        let p = ModelPaths(
            encoder: d.appendingPathComponent("encoder.onnx").path,
            decoder: d.appendingPathComponent("decoder.onnx").path,
            joiner: d.appendingPathComponent("joiner.onnx").path,
            tokens: d.appendingPathComponent("tokens.txt").path)
        return p.exists ? p : nil
    }

    /// VAD model path, or nil if the VAD bundle is not installed. The pipeline treats a
    /// missing VAD as "run ungated" rather than fail.
    func vadPath() -> VadPath? {
        guard let d = resolveDir(Bundles.vadSilero.id) else { return nil }
        let f = d.appendingPathComponent("silero_vad.onnx")
        return FileManager.default.fileExists(atPath: f.path) ? VadPath(model: f.path) : nil
    }

    /// SenseVoice refinement paths, or nil when not installed — the pipeline then
    /// publishes the streaming transcript directly instead of failing.
    func pathsSenseVoice() -> SenseVoicePaths? {
        guard let d = resolveDir(Bundles.asrSenseVoice.id) else { return nil }
        let p = SenseVoicePaths(
            model: d.appendingPathComponent("model.int8.onnx").path,
            tokens: d.appendingPathComponent("tokens.txt").path)
        return p.exists ? p : nil
    }

    /// Offline translation GGUF, or nil when not installed (placeholder marks turns).
    /// A/B order: Gemma 4 when installed wins; remove its directory to fall back to
    /// Hy-MT2 without touching the other install.
    func pathsMt() -> MtPaths? {
        for id in [Bundles.mtGemma4E2B.id, Bundles.mtHymt2.id] {
            guard let d = resolveDir(id) else { continue }
            let p = MtPaths(model: d.appendingPathComponent("model.gguf").path)
            if p.exists { return p }
        }
        return nil
    }

    /// the folder the user should drop a bundle into via Finder/Files, shown verbatim
    /// in the UI so it can be copy-pasted
    func sideloadTargetFor(_ bundle: String) -> String { root.appendingPathComponent(bundle).path }

    var freeBytes: Int64 {
        let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

/// Paths of every model the streaming recognizer needs.
struct ModelPaths {
    let encoder: String
    let decoder: String
    let joiner: String
    let tokens: String

    var exists: Bool {
        [encoder, decoder, joiner, tokens].allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }
}

/// Path of the VAD model file. Optional: the pipeline runs without it, it just hallucinates.
struct VadPath {
    let model: String
    var exists: Bool { FileManager.default.fileExists(atPath: model) }
}

/// Paths of the optional SenseVoice offline refinement model.
struct SenseVoicePaths {
    let model: String
    let tokens: String
    var exists: Bool {
        FileManager.default.fileExists(atPath: model) && FileManager.default.fileExists(atPath: tokens)
    }
}

/// Path of the offline translation GGUF. Optional: without it the placeholder
/// translator marks turns instead of translating.
struct MtPaths {
    let model: String
    var exists: Bool { FileManager.default.fileExists(atPath: model) }
}
