package com.example.gaze_nav

import android.content.Intent
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "com.gaze_nav/native"
        const val TAG = "GazeNavMain"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
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
                                result.error("NO_SERVICE", "Accessibility service not enabled", null)
                                return@setMethodCallHandler
                            }
                            val intent = Intent(GazeAccessibilityService.ACTION_OVERLAY_START)
                            intent.setPackage(packageName)
                            sendBroadcast(intent)

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
                            intent.setPackage(packageName)
                            sendBroadcast(intent)
                            result.success(true)
                        }
                        "updateCursor" -> {
                            val x = call.argument<Double>("x")?.toFloat() ?: 0f
                            val y = call.argument<Double>("y")?.toFloat() ?: 0f
                            val intent = Intent(GazeAccessibilityService.ACTION_UPDATE_CURSOR)
                            intent.setPackage(packageName)
                            intent.putExtra(GazeAccessibilityService.EXTRA_CURSOR_X, x)
                            intent.putExtra(GazeAccessibilityService.EXTRA_CURSOR_Y, y)
                            sendBroadcast(intent)
                            result.success(true)
                        }
                        "doubleBlink" -> {
                            val intent = Intent(GazeAccessibilityService.ACTION_DOUBLE_BLINK)
                            intent.setPackage(packageName)
                            sendBroadcast(intent)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Method channel error: ${e.message}")
                    result.error("ERROR", e.message, null)
                }
            }

        Log.d(TAG, "Flutter engine configured")
    }
}