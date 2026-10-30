package com.adeeteya.classipod

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Receives the Spotify OAuth redirect (classipod://spotify-callback). The
// activity is singleTask, so the redirect also closes the login Custom Tab.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        intent?.data?.takeIf { it.scheme == "classipod" }?.let {
            pending = it.toString()
        }
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "classipod/spotify_auth",
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeCallback") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = intent.data ?: return
        if (uri.scheme != "classipod" || uri.host != "spotify-callback") return
        pending = uri.toString()
        channel?.invokeMethod("callback", pending)
    }
}
