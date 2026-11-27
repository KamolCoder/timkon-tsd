package uz.timkon.tsd

import android.media.AudioManager
import android.media.ToneGenerator
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var tone: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Scan sounds (Dart: _Beep). Notification stream, full tone volume.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tsd/beep").setMethodCallHandler { call, result ->
            val (type, ms) = when (call.method) {
                "ok" -> ToneGenerator.TONE_PROP_BEEP to 120
                "done" -> ToneGenerator.TONE_PROP_BEEP2 to 250
                "excess" -> ToneGenerator.TONE_PROP_NACK to 400
                "error" -> ToneGenerator.TONE_SUP_ERROR to 700
                else -> {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
            }
            try {
                val t = tone ?: ToneGenerator(AudioManager.STREAM_NOTIFICATION, ToneGenerator.MAX_VOLUME).also { tone = it }
                t.startTone(type, ms)
            } catch (_: RuntimeException) {
                tone = null // audio unavailable: no sound, never a crash
            }
            result.success(null)
        }
    }

    override fun onDestroy() {
        tone?.release()
        tone = null
        super.onDestroy()
    }
}
