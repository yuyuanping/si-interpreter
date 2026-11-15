package com.qoder.si

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Finds and validates model bundles.
 *
 * Two search roots, which is the whole reason an offline install can be done over USB:
 *
 *  - internal: filesDir/models            — written by the in-app downloader
 *  - external: /sdcard/Android/data/<pkg>/files/models
 *      the one location that BOTH `adb push` can write from a PC AND the app can read on
 *      Android 11+ scoped storage, with no runtime permission and no root. That is what
 *      makes a genuinely zero-network setup possible.
 *
 * There is deliberately no ".ready" sentinel file: a bundle pushed by adb would never get
 * one, so it would read as "incomplete" forever. Integrity is judged by per-file minimum
 * size alone — a truncated .onnx is exactly the case that otherwise dies inside sherpa-onnx
 * with an opaque native crash, and the downloader only renames .part -> final when the byte
 * count already passed, so a partial file can never masquerade as installed.
 */
class ModelStore(context: Context) {

    /** where the in-app installer writes */
    val root = File(context.filesDir, "models").apply { mkdirs() }

    /** where `adb push` can put files; read in place, never copied (200 MB of copy is waste) */
    val externalRoot: File =
        context.getExternalFilesDir("models")?.apply { mkdirs() } ?: File(root, "_external")

    fun installDir(bundle: String) = File(root, bundle).apply { mkdirs() }

    /** the directory this bundle actually lives in, external preferred */
    fun resolveDir(bundle: String): File? =
        listOf(File(externalRoot, bundle), File(root, bundle))
            .firstOrNull { presentIn(it, bundle) }

    private fun presentIn(dir: File, bundle: String): Boolean {
        val spec = Bundles.byId(bundle) ?: return false
        if (!dir.isDirectory) return false
        return spec.files.all { fs ->
            val f = File(dir, fs.local)
            f.isFile && f.length() >= fs.minBytes
        }
    }

    fun complete(bundle: String): Boolean = resolveDir(bundle) != null

    fun paths(bundle: String): ModelPaths? {
        val d = resolveDir(bundle) ?: return null
        return ModelPaths(
            encoder = File(d, "encoder.onnx").absolutePath,
            decoder = File(d, "decoder.onnx").absolutePath,
            joiner = File(d, "joiner.onnx").absolutePath,
            tokens = File(d, "tokens.txt").absolutePath,
        )
    }

    /** VAD model path, or null if the VAD bundle is not installed. The pipeline treats a
     *  missing VAD as "run ungated" rather than fail, so this returns null, not throws. */
    fun vadPath(): VadPath? {
        val d = resolveDir(Bundles.vadSilero.id) ?: return null
        val f = File(d, "silero_vad.onnx")
        return if (f.isFile) VadPath(f.absolutePath) else null
    }

    /** SenseVoice refinement paths, or null when not installed — the pipeline then publishes
     *  the streaming transcript directly instead of failing. */
    fun pathsSenseVoice(): SenseVoicePaths? {
        val d = resolveDir(Bundles.asrSenseVoice.id) ?: return null
        val p = SenseVoicePaths(
            model = File(d, "model.int8.onnx").absolutePath,
            tokens = File(d, "tokens.txt").absolutePath,
        )
        return if (p.exists()) p else null
    }

    /** Offline translation GGUF, or null when not installed (placeholder marks turns).
     *  [preferred] is the user's pick from the idle panel; it is honoured only when that
     *  bundle is actually installed — otherwise the A/B default order applies (Gemma 4
     *  first), so a deleted pick never bricks translation. null preferred = auto. */
    fun pathsMt(preferred: String? = null): MtPaths? {
        val mtIds = listOf(Bundles.mtGemma4E2B.id, Bundles.mtHymt2.id)
        val order = if (preferred != null && mtIds.contains(preferred))
            listOf(preferred) + mtIds.filter { it != preferred }
        else mtIds
        for (id in order) {
            val d = resolveDir(id) ?: continue
            val p = MtPaths(File(d, "model.gguf").absolutePath)
            if (p.exists()) return p
        }
        return null
    }

    /** catalogue bundles that are present and complete, in either root */
    fun installed(): List<String> {
        val ids = Bundles.all.map { it.id }
        val found = ids.filter { complete(it) }
        Log.i(TAG, "installed=$found of $ids")
        Log.i(TAG, "externalRoot=${externalRoot.absolutePath} isDir=${externalRoot.isDirectory} " +
            "listFiles=${externalRoot.list()?.toList()}")
        for (id in ids) diagnose(id).forEach { Log.i(TAG, "  $id: $it") }
        return found
    }

    /** what is missing or too small, for the "why won't it load" screen */
    fun diagnose(bundle: String): List<String> {
        val spec = Bundles.byId(bundle) ?: return listOf("<unknown bundle>")
        val lines = ArrayList<String>()
        for ((label, base) in listOf("内部" to root, "外部(adb)" to externalRoot)) {
            val d = File(base, bundle)
            if (!d.isDirectory) { lines += "$label: 目录不存在"; continue }
            val bad = spec.files.mapNotNull { fs ->
                val f = File(d, fs.local)
                when {
                    !f.isFile -> fs.local
                    f.length() < fs.minBytes -> "${fs.local} ${f.length()}/${fs.minBytes}"
                    else -> null
                }
            }
            lines += if (bad.isEmpty()) "$label: 完整 ✓" else "$label: 缺 $bad"
        }
        return lines
    }

    fun bytesUsed(): Long = listOf(root, externalRoot)
        .filter { it.isDirectory }
        .flatMap { it.walkBottomUp().filter { f -> f.isFile }.toList() }
        .sumOf { it.length() }

    /** where to put files so `adb push` is picked up, shown verbatim in the UI */
    fun adbTargetFor(bundle: String): String = File(externalRoot, bundle).absolutePath

    companion object { private const val TAG = "ModelStore" }
}
