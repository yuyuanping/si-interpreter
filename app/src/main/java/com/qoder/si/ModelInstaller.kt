package com.qoder.si

import android.content.Context
import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

data class DownloadState(
    val active: Boolean = false,
    val label: String = "",
    val fileIndex: Int = 0,
    val fileCount: Int = 0,
    val fileName: String = "",
    val done: Long = 0,
    val total: Long = 0,
    val bytesPerSec: Double = 0.0,
    val message: String = "",
)

/**
 * Model installer. Network use is confined to exactly this file — the interpretation path
 * never touches a socket.
 *
 * Resume matters because these are 200 MB files on flaky mobile connections: we write to
 * <name>.part, ask the server for Range, and only rename into place when the byte count
 * matches. A partial .part is never mistaken for an installed model.
 */
class ModelInstaller(private val context: Context) {

    private val store = ModelStore(context)
    private val _state = MutableStateFlow(DownloadState())
    val state: StateFlow<DownloadState> = _state

    @Volatile private var cancelled = false

    fun cancel() { cancelled = true }

    suspend fun install(bundle: Bundle): Boolean = withContext(Dispatchers.IO) {
        cancelled = false
        // always download into the internal root; the external root is reserved for
        // adb-pushed files so we never mix two writers in one directory
        val dir = store.installDir(bundle.id)
        var lastError: String? = null

        for (base in Bundles.bases) {
            var ok = true
            bundle.files.forEachIndexed { i, fs ->
                if (cancelled) return@withContext false
                _state.value = _state.value.copy(
                    active = true, label = bundle.label,
                    fileIndex = i + 1, fileCount = bundle.files.size, fileName = fs.local,
                )
                val final = File(dir, fs.local)
                if (final.isFile && final.length() >= fs.minBytes) return@forEachIndexed
                if (!fetch(bundle.urlFor(base), fs, final, dir)) {
                    ok = false
                    lastError = "下载失败: ${fs.local}"
                    return@forEachIndexed
                }
            }
            if (ok) {
                _state.value = DownloadState(message = "${bundle.label} 已就绪")
                return@withContext true
            }
            _state.value = _state.value.copy(message = "$lastError，换镜像重试")
        }

        _state.value = DownloadState(message = lastError ?: "全部镜像均失败")
        false
    }

    private suspend fun fetch(url: String, fs: FileSpec, final: File, dir: File): Boolean {
        val part = File(dir, fs.local + ".part")
        var start = if (part.isFile) part.length() else 0L

        // if the server (or a captive network) returned something tiny, do not trust resume
        if (start > 0 && start >= fs.minBytes) { part.delete(); start = 0 }

        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = true
            connectTimeout = 15_000
            readTimeout = 30_000
            if (start > 0) setRequestProperty("Range", "bytes=$start-")
        }

        val code = conn.responseCode
        if (code !in 200..299) { conn.disconnect(); return false }

        // 200 means the server ignored Range: restart from zero rather than append onto
        // an existing partial file, which would silently corrupt the model
        val append = code == 206 && start > 0
        if (!append) start = 0

        val contentLen = conn.contentLengthLong.coerceAtLeast(0)
        val total = if (append) start + contentLen else contentLen

        conn.inputStream.use { input ->
            RandomAccessFile(part, "rw").use { raf ->
                raf.setLength(start)
                raf.seek(start)
                val buf = ByteArray(64 * 1024)
                var written = start
                var lastTick = System.currentTimeMillis()
                var lastBytes = start

                while (true) {
                    coroutineContext.ensureActive()
                    if (cancelled) { conn.disconnect(); return false }
                    val n = input.read(buf)
                    if (n <= 0) break
                    raf.write(buf, 0, n)
                    written += n

                    val now = System.currentTimeMillis()
                    if (now - lastTick > 250) {
                        val dt = (now - lastTick) / 1000.0
                        _state.value = _state.value.copy(
                            done = written, total = total,
                            bytesPerSec = (written - lastBytes) / dt,
                        )
                        lastTick = now; lastBytes = written
                    }
                }
            }
        }
        conn.disconnect()

        if (writtenOk(part, fs)) {
            part.renameTo(final)
            return true
        }
        return false
    }

    private fun writtenOk(part: File, fs: FileSpec): Boolean =
        part.isFile && part.length() >= fs.minBytes

    suspend fun delete(bundle: Bundle) = withContext(Dispatchers.IO) {
        // only the internal copy: the adb-pushed external copy belongs to the user's PC
        store.installDir(bundle.id).deleteRecursively()
    }

    fun freeBytes(): Long = context.filesDir.usableSpace

    /** path the user should `adb push` to, shown verbatim so it can be copy-pasted */
    fun adbPath(bundle: Bundle): String = store.adbTargetFor(bundle.id)
}
