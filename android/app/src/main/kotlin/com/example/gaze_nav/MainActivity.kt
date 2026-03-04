package com.example.gazenav

import android.content.Intent
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity - Flutter <-> Native bridge
 *
 * Platform channel methods:
 *   - checkAccessibility  → returns bool
 *   - openAccessibility   → opens Android settings
 *   - startOverlay        → tells service to show overlay, sends user to home
 *   - stopOverlay         → hides overlay
 *   - updateCursor(x, y)  → sends cursor position to service
 *   - doubleBlink         → sends blink event to service
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "com.gazenav/native"
        const val TAG = "GazeNavMain"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkAccessibility" -> {
                        result.success(GazeAccessibilityService.isRunning())
                    }

                    "openAccessibility" -> {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        startActivity(intent)
                        result.success(true)
                    }

                    "startOverlay" -> {
                        if (!GazeAccessibilityService.isRunning()) {
                            result.error("NO_SERVICE",
                                "Accessibility service not enabled", null)
                            return@setMethodCallHandler
                        }
                        // Tell service to show overlay
                        val intent = Intent(GazeAccessibilityService.ACTION_OVERLAY_START)
                        sendBroadcast(intent)

                        // Send user to home screen after short delay
                        android.os.Handler(mainLooper).postDelayed({
                            val homeIntent = Intent(Intent.ACTION_MAIN)
                            homeIntent.addCategory(Intent.CATEGORY_HOME)
                            homeIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(homeIntent)
                        }, 300)

                        result.success(true)
                    }

                    "stopOverlay" -> {
                        val intent = Intent(GazeAccessibilityService.ACTION_OVERLAY_STOP)
                        sendBroadcast(intent)
                        result.success(true)
                    }

                    "updateCursor" -> {
                        val x = call.argument<Double>("x")?.toFloat() ?: 0f
                        val y = call.argument<Double>("y")?.toFloat() ?: 0f
                        val intent = Intent(GazeAccessibilityService.ACTION_UPDATE_CURSOR)
                        intent.putExtra(GazeAccessibilityService.EXTRA_CURSOR_X, x)
                        intent.putExtra(GazeAccessibilityService.EXTRA_CURSOR_Y, y)
                        sendBroadcast(intent)
                        result.success(true)
                    }

                    "doubleBlink" -> {
                        val intent = Intent(GazeAccessibilityService.ACTION_DOUBLE_BLINK)
                        sendBroadcast(intent)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }

        Log.d(TAG, "Flutter engine configured with method channel")
    }
}