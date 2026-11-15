package com.qoder.si

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private lateinit var store: ModelStore
    private lateinit var installer: ModelInstaller
    lateinit var config: PipelineConfig
        private set

    private var micGranted by mutableStateOf(false)

    // API 33+: a microphone foreground service with no notification consent is not merely
    // hidden -- on API 34 startForeground() throws outright. Ask for both at once.
    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
            micGranted = res[Manifest.permission.RECORD_AUDIO] == true
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = ModelStore(this)
        installer = ModelInstaller(this)
        config = PipelineConfig(this)
        micGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

        setContent { MaterialTheme { App(store, installer, config, micGranted, this) } }

        // `adb shell am start -n com.qoder.si/.MainActivity --es autostart 1`
        // Service is exported=false (correct), so shell cannot start it directly; going
        // through the Activity keeps on-device testing independent of flaky tap coordinates.
        if (intent?.hasExtra(EXTRA_AUTOSTART) == true) startInterpretation()
    }

    companion object { const val EXTRA_AUTOSTART = "autostart" }

    fun requestMic() = permissionLauncher.launch(
        buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }.toTypedArray()
    )

    /** the service owns the engine; the Activity only asks for start/stop and observes */
    fun startInterpretation() = InterpreterService.start(this)
    fun stopInterpretation() = InterpreterService.stop(this)

    override fun onDestroy() {
        super.onDestroy()
        // deliberately NOT stopping the engine: rotation or Activity recreation must not
        // cut short a live interpretation session
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun App(
    store: ModelStore,
    installer: ModelInstaller,
    config: PipelineConfig,
    micGranted: Boolean,
    activity: MainActivity,
) {
    // store.installed() hits the filesystem, which Compose cannot observe, so a rescan is
    // an explicit counter the UI bumps after an adb push or a finished download
    var rescanKey by remember { mutableStateOf(0) }
    val dl by installer.state.collectAsState()
    val engine by InterpreterService.engineFlow.collectAsState()
    val svcRunning by InterpreterService.runningFlow.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("同声传译 · 全离线", fontSize = 18.sp) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Bg, titleContentColor = Fg,
                ),
            )
        },
        containerColor = Bg,
    ) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(horizontal = 16.dp)) {
            if (!micGranted) {
                OutlinedButton(
                    onClick = { activity.requestMic() },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("授予麦克风权限") }
                Spacer(Modifier.height(12.dp))
            }

            val installed = remember(rescanKey, dl.active) { store.installed() }

            when {
                engine != null -> LivePanel(engine!!, activity)
                svcRunning -> LoadingPanel()
                installed.isEmpty() -> ModelSetup(installer, dl) { rescanKey++ }
                else -> IdlePanel(installed, store, config, activity)
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun ModelSetup(installer: ModelInstaller, dl: DownloadState, onRescan: () -> Unit) {
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val bundle = Bundles.asrZipformerBilingual

    Section("第一步 · 安装语音模型")
    Card {
        Text(bundle.label, color = Fg, fontWeight = FontWeight.Bold)
        Text(bundle.note, color = Dim, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
        Text("只有这一步需要网络。装完后飞行模式可正常使用。",
            color = Dim, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
        Spacer(Modifier.height(12.dp))

        if (dl.active) {
            Text("${dl.fileIndex}/${dl.fileCount}  ${dl.fileName}", color = Ok, fontSize = 12.sp)
            Progress(dl.done, dl.total)
            Text("${mb(dl.done)} / ${mb(dl.total)} MB    ${speed(dl.bytesPerSec)}",
                color = Dim, fontSize = 12.sp)
            OutlinedButton(
                onClick = { installer.cancel() },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            ) { Text("取消") }
        } else {
            Button(
                onClick = { scope.launch { installer.install(bundle) } },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("下载模型 ${bundle.totalMb} MB") }
            if (dl.message.isNotEmpty()) {
                Text(dl.message, color = Warn, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
            }
        }
    }

    Spacer(Modifier.height(12.dp))
    Section("完全不走网：用数据线推模型")
    Card {
        Text("电脑上下载好，adb push 进手机，App 直接识别。", color = Dim, fontSize = 12.sp)
        Spacer(Modifier.height(6.dp))
        Text("目标目录（点击复制）", color = Faint, fontSize = 11.sp)
        val path = installer.adbPath(bundle)
        Text(path, color = Live, fontSize = 11.sp,
            modifier = Modifier.padding(top = 2.dp, bottom = 6.dp).clickable {
                clipboard.setText(AnnotatedString(path))
            })
        Text("文件名必须改成", color = Faint, fontSize = 11.sp)
        bundle.files.forEach {
            Text("  ${it.remote}  →  ${it.local}", color = Dim, fontSize = 11.sp)
        }
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = onRescan, modifier = Modifier.fillMaxWidth()) {
            Text("推完后重新扫描")
        }
    }
}

@Composable
private fun IdlePanel(
    installed: List<String>,
    store: ModelStore,
    config: PipelineConfig,
    activity: MainActivity,
) {
    var src by remember { mutableStateOf(config.sourceLang) }
    var tgt by remember { mutableStateOf(config.targetLang) }
    var cut by remember { mutableStateOf(config.cutSilenceSec) }

    InstalledList(store)
    Spacer(Modifier.height(14.dp))

    Section("方向")
    Card {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            LangChip("英 → 中", src == "en" && tgt == "zh") { src = "en"; tgt = "zh" }
            LangChip("中 → 英", src == "zh" && tgt == "en") { src = "zh"; tgt = "en" }
        }
        Text("每句按实测语言自动定向：说中文译成英文，说英文译成中文。上方选择仅在无法判定时生效。",
            color = Dim, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
        val mtEngine = when {
            installed.contains(Bundles.mtGemma4E2B.id) -> "谷歌 Gemma 4 E2B"
            installed.contains(Bundles.mtHymt2.id) -> "腾讯混元 Hy-MT2"
            else -> null
        }
        Text(
            if (mtEngine != null) "翻译引擎已就绪：$mtEngine，纯本地推理。"
            else "安装下方翻译模型后即可离线翻译；未安装时译文处显示占位标记。",
            color = if (mtEngine != null) Ok else Warn,
            fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp),
        )
    }
    Spacer(Modifier.height(14.dp))

    Section("断句停顿")
    Card {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            listOf(0.5f, 1.0f, 1.5f, 2.5f).forEach { v ->
                LangChip("${v}s", cut == v) { cut = v; config.cutSilenceSec = v }
            }
        }
        Text("说话停顿超过该时长就按句尾切句并翻译。句子被切得太碎就调大，译文会相应出得稍慢。",
            color = Dim, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
    }
    Spacer(Modifier.height(14.dp))

    Button(
        onClick = {
            config.sourceLang = src
            config.targetLang = tgt
            activity.startInterpretation()
        },
        enabled = src != tgt && installed.isNotEmpty(),
        modifier = Modifier.fillMaxWidth().height(54.dp),
    ) { Text("开始", fontSize = 18.sp) }
}

@Composable
private fun LivePanel(engine: InterpreterEngine, activity: MainActivity) {
    val live by engine.live.collectAsState()
    val history by engine.history.collectAsState()
    val stats by engine.stats.collectAsState()
    val state by engine.state.collectAsState()
    val listState = rememberLazyListState()
    val density = LocalDensity.current

    // Tail-following is driven by user intent, not list position: a scroll animation that
    // is mid-flight leaves the list momentarily off the bottom, so a position check alone
    // would see "not at bottom" and stop following for good after two quick utterances.
    // A drag pauses following so history stays readable; dragging back to the tail resumes.
    var followTail by remember { mutableStateOf(true) }
    val nearTail by remember(listState, density) {
        derivedStateOf {
            val li = listState.layoutInfo
            val last = li.visibleItemsInfo.lastOrNull() ?: return@derivedStateOf true
            last.index == li.totalItemsCount - 1 &&
                last.offset + last.size <= li.viewportEndOffset + with(density) { 24.dp.toPx() }
        }
    }
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect { interaction ->
            if (interaction is DragInteraction.Start) followTail = false
        }
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling && !followTail && nearTail) followTail = true
        }
    }

    // Key on what the tail SHOWS, not on history.size: a turn is appended as pending and
    // its translation fills in later in place (size never moves), and once the engine's
    // takeLast(80) cap engages, size stops changing entirely -- only the last id does.
    LaunchedEffect(followTail, history.lastOrNull()?.id, history.lastOrNull()?.translated) {
        if (followTail && history.isNotEmpty()) listState.animateScrollToItem(history.lastIndex)
    }

    Column(Modifier.fillMaxWidth()) {
        // the number that decides whether this feels like interpretation at all
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Metric("译文延迟", fmtLatency(stats.translateMs))
            Metric("识别句数", "${stats.utterances}")
            Metric("丢弃", "${stats.dropped}")
            Metric("已听", String.format("%.0fs", stats.secondsHeard))
        }
        Spacer(Modifier.height(6.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            // mic level is the one number that separates "recogniser is bad" from
            // "microphone is handing it noise": speech should sit near -3..-12 dBFS
            Metric("当前电平", fmtDb(stats.levelDb))
            Metric("峰值电平", fmtDb(stats.peakDb))
            Metric("单帧耗时", "${stats.asrMs}ms")
            Metric("方向", "自动")
        }
        Spacer(Modifier.height(10.dp))

        val st = state
        if (st is EngineState.Error) {
            Card { Text(st.message, color = Bad) }
            Spacer(Modifier.height(10.dp))
        }

        Box(
            Modifier.fillMaxWidth().height(72.dp)
                .background(Cell2, RoundedCornerShape(12.dp)).padding(12.dp)
        ) {
            Text(
                live.ifBlank {
                    when (state) {
                        EngineState.Loading -> "模型加载中…"
                        else -> "聆听中… 说英语或中文"
                    }
                },
                color = if (live.isBlank()) Faint else Live,
                fontSize = 17.sp,
            )
        }
        Spacer(Modifier.height(10.dp))

        LazyColumn(state = listState, modifier = Modifier.fillMaxWidth().weight(1f)) {
            items(history, key = { it.id }) { UtteranceRow(it) }
        }

        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = { engine.forceCut = true }) { Text("切断") }
            OutlinedButton(onClick = { engine.clear() }) { Text("清空") }
            Button(
                onClick = { activity.stopInterpretation() },
                modifier = Modifier.weight(1f),
            ) { Text("停止") }
        }
    }
}

@Composable
private fun LoadingPanel() {
    // a 175 MB int8 encoder takes seconds to map; without this the UI just looks frozen
    Section("启动中")
    Card {
        Text("正在加载模型…", color = Fg, fontSize = 15.sp)
        Text("首次加载需几秒，之后常驻内存。", color = Dim, fontSize = 12.sp,
            modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun InstalledList(store: ModelStore) {
    Section("已安装")
    Card {
        val ids = store.installed()
        if (ids.isEmpty()) {
            Text("（无）", color = Faint, fontSize = 13.sp)
        } else ids.forEach { id ->
            val label = Bundles.byId(id)?.label ?: id
            val where = if (store.resolveDir(id)?.path?.contains("Android") == true) "adb" else "本机"
            Text("✓  $label   [$where]", color = Ok, fontSize = 13.sp)
        }
    }
}

@Composable
private fun UtteranceRow(u: Utterance) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 5.dp)
            .background(Cell, RoundedCornerShape(10.dp)).padding(12.dp)
    ) {
        Text(u.sourceText, color = Dim, fontSize = 14.sp)
        Spacer(Modifier.height(4.dp))
        if (u.pending) {
            Text("翻译中…", color = Warn, fontSize = 16.sp)
        } else {
            Text(u.translated, color = Fg, fontSize = 17.sp, fontWeight = FontWeight.Medium)
            Text("↳ ${fmtLatency(u.latencyMs)}", color = Faint, fontSize = 11.sp)
        }
    }
}

@Composable private fun Section(t: String) =
    Text(t, color = Fg, fontWeight = FontWeight.Bold, fontSize = 15.sp,
        modifier = Modifier.padding(top = 6.dp, bottom = 8.dp))

@Composable private fun Card(content: @Composable ColumnScope.() -> Unit) =
    Column(
        Modifier.fillMaxWidth().background(Cell, RoundedCornerShape(12.dp)).padding(14.dp),
        content = content,
    )

@Composable private fun Metric(label: String, value: String) =
    Column(horizontalAlignment = Alignment.Start) {
        Text(value, color = Ok, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Text(label, color = Faint, fontSize = 11.sp)
    }

@Composable private fun LangChip(text: String, selected: Boolean, onClick: () -> Unit) =
    Box(
        Modifier.background(if (selected) Accent else Cell2, RoundedCornerShape(20.dp))
            .clickable(onClick = onClick).padding(horizontal = 18.dp, vertical = 10.dp)
    ) { Text(text, color = Fg, fontSize = 14.sp) }

@Composable private fun Progress(done: Long, total: Long) {
    val f = if (total > 0) (done.toFloat() / total).coerceIn(0f, 1f) else 0f
    Box(Modifier.fillMaxWidth().height(6.dp).padding(vertical = 6.dp)
        .background(Cell2, RoundedCornerShape(3.dp))) {
        Box(Modifier.fillMaxWidth(f).height(6.dp).background(Accent, RoundedCornerShape(3.dp)))
    }
}

private val Bg = Color(0xFF101418)
private val Fg = Color(0xFFE6EAF0)
private val Dim = Color(0xFF8FA3C0)
private val Faint = Color(0xFF5C6B84)
private val Cell = Color(0xFF161C26)
private val Cell2 = Color(0xFF1B2230)
private val Accent = Color(0xFF2C6BED)
private val Ok = Color(0xFF7FE39B)
private val Warn = Color(0xFFFFC44D)
private val Bad = Color(0xFFFF9A8C)
private val Live = Color(0xFFCFE0FF)

private fun fmtLatency(ms: Long) = if (ms <= 0) "—"
else if (ms < 1000) "${ms}ms" else String.format("%.1fs", ms / 1000.0)

private fun fmtDb(db: Float) = if (db <= -119f) "—" else String.format("%.0fdB", db)

private fun mb(b: Long) = String.format("%.1f", b / 1_048_576.0)
private fun speed(bps: Double) = if (bps <= 0) "" else String.format("%.1f MB/s", bps / 1_048_576.0)
