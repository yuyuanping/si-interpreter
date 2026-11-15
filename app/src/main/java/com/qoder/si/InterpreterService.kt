package com.qoder.si

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Owns the engine so the pipeline survives the screen going off.
 *
 * This is not optional polish: since Android 9, a process without a microphone-type
 * foreground service gets its capture stream SILENCED the moment it leaves the
 * foreground. An Activity-held engine therefore stops producing anything as soon as the
 * user turns the screen down to listen, which is precisely how an interpreter app gets
 * used. The notification also gives us the wake-lock-ish continuity we want during a
 * 40-minute talk.
 */
class InterpreterService : android.app.Service() {

    companion object {
        const val ACTION_START = "com.qoder.si.START"
        const val ACTION_STOP = "com.qoder.si.STOP"

        private const val CHANNEL = "interpretation"
        private const val NOTIF = 1
        private const val TAG = "InterpreterService"

        /**
         * The single source of truth the UI binds to. A plain nullable field would not
         * recompose Compose when the service later creates the engine, so the Activity would
         * sit on the idle screen forever -- this is a StateFlow the UI collects.
         */
        val engineFlow = MutableStateFlow<InterpreterEngine?>(null)
        val runningFlow = MutableStateFlow(false)
        var engine: InterpreterEngine? = null
            private set

        fun start(context: Context) =
            context.startService(Intent(context, InterpreterService::class.java).setAction(ACTION_START))

        fun stop(context: Context) =
            context.startService(Intent(context, InterpreterService::class.java).setAction(ACTION_STOP))
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate() {
        super.onCreate()
        channel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                teardown()
                stopSelf()
                return START_NOT_STICKY
            }
        }

        // startForeground() must precede any mic access or the system kills us. It also
        // THROWS SecurityException when RECORD_AUDIO is not granted, so guard it: an
        // unguarded call here crashes the app with no on-screen explanation at all.
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIF, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIF, notification())
            }
        } catch (e: SecurityException) {
            runningFlow.value = false
            stopSelf()
            return START_NOT_STICKY
        } catch (e: IllegalStateException) {
            runningFlow.value = false
            stopSelf()
            return START_NOT_STICKY
        }

        if (engine == null) {
            val store = ModelStore(this)
            val config = PipelineConfig(this)
            val bundle = store.installed().firstOrNull()
            val paths = bundle?.let { store.paths(it) }

            if (paths == null) {
                // refuse to start rather than run a service that hears nothing: a
                // foreground-service icon plus total silence is worse than an error
                (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .notify(NOTIF, notification("未找到模型，请先在 App 内安装"))
                stopSelf()
                return START_NOT_STICKY
            }
            val vadPath = store.vadPath()
            val svPath = store.pathsSenseVoice()
            val mtPath = store.pathsMt()
            // real on-device MT when the 1.1 GB GGUF is present; the placeholder only marks
            // turns otherwise — it is never a silent fallback that pretends to translate
            val translator: Translator = if (mtPath != null) LlamaTranslator(mtPath) else PlaceholderTranslator()
            engine = InterpreterEngine(this, AsrEngine(paths, config.cutSilenceSec), translator, config, vadPath, svPath)
            Log.i(TAG, "engine created bundle=$bundle paths=$paths vad=${vadPath?.model ?: "none"} " +
                "sv=${svPath?.model ?: "none"} mt=${mtPath?.model ?: "none"}")
        }

        val e = engine!!
        engineFlow.value = e
        scope.launch {
            runningFlow.value = true
            Log.i(TAG, "calling engine.start()")
            e.start()
            Log.i(TAG, "engine.start() returned, state=${e.state.value}")
            // if the engine fell over (permission, native load failure) reflect that in the
            // notification rather than leaving a "running" service that hears nothing
            e.state.collect { st ->
                if (st is EngineState.Error) {
                    Log.e(TAG, "engine error: ${st.message}")
                    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                        .notify(NOTIF, notification(st.message))
                }
            }
        }
        return START_STICKY
    }

    private fun teardown() {
        scope.cancel()
        engine?.stop()
        engine = null
        engineFlow.value = null
        runningFlow.value = false
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun channel() {
        if (Build.VERSION.SDK_INT < 26) return
        val m = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (m.getNotificationChannel(CHANNEL) == null) {
            m.createNotificationChannel(
                NotificationChannel(CHANNEL, "同声传译", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    private fun notification(text: String? = null): Notification {
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("同声传译运行中")
            .setContentText(text ?: "听风中 · 关闭屏幕不会中断")
            .setOngoing(true)
            .setContentIntent(pi)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}
