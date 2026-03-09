package com.example.gaze_nav

import android.content.Intent
import android.os.Build
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
                                result.error("NO_SERVICE", "Accessibility not enabled", null)
                                return@setMethodCallHandler
                            }

                            // Start foreground service with calibration data
                            // Native camera takes over tracking from Flutter
                            val fgIntent = Intent(this, GazeForegroundService::class.java)
                            fgIntent.putExtra(GazeForegroundService.EXTRA_BASE_MID_X,
                                call.argument<Double>("baseMidX") ?: 0.0)
                            fgIntent.putExtra(GazeForegroundService.EXTRA_BASE_MID_Y,
                                call.argument<Double>("baseMidY") ?: 0.0)
                            fgIntent.putExtra(GazeForegroundService.EXTRA_BASE_NOSE_X,
                                call.argument<Double>("baseNoseX") ?: 0.0)
                            fgIntent.putExtra(GazeForegroundService.EXTRA_BASE_NOSE_Y,
                                call.argument<Double>("baseNoseY") ?: 0.0)
                            fgIntent.putExtra(GazeForegroundService.EXTRA_SENS_X,
                                call.argument<Double>("sensX") ?: 5.0)
                            fgIntent.putExtra(GazeForegroundService.EXTRA_SENS_Y,
                                call.argument<Double>("sensY") ?: 4.5)
                            fgIntent.putExtra(GazeForegroundService.EXTRA_IMG_W,
                                call.argument<Double>("imgW") ?: 640.0)
                            fgIntent.putExtra(GazeForegroundService.EXTRA_IMG_H,
                                call.argument<Double>("imgH") ?: 480.0)

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(fgIntent)
                            } else {
                                startService(fgIntent)
                            }

                            // Show overlay
                            val overlayIntent = Intent(GazeAccessibilityService.ACTION_OVERLAY_START)
                            overlayIntent.setPackage(packageName)
                            sendBroadcast(overlayIntent)

                            // Go home after delay
                            android.os.Handler(mainLooper).postDelayed({
                                val homeIntent = Intent(Intent.ACTION_MAIN)
                                homeIntent.addCategory(Intent.CATEGORY_HOME)
                                homeIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                startActivity(homeIntent)
                            }, 500)

                            result.success(true)
                        }
                        "stopOverlay" -> {
                            stopService(Intent(this, GazeForegroundService::class.java))
                            val intent = Intent(GazeAccessibilityService.ACTION_OVERLAY_STOP)
                            intent.setPackage(packageName)
                            sendBroadcast(intent)
                            result.success(true)
                        }
                        // These are no longer needed for home screen tracking
                        // but kept for in-app overlay testing
                        "updateCursor" -> result.success(true)
                        "doubleBlink" -> {
                            val intent = Intent(GazeAccessibilityService.ACTION_DOUBLE_BLINK)
                            intent.setPackage(packageName)
                            sendBroadcast(intent)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error: ${e.message}")
                    result.error("ERROR", e.message, null)
                }
            }
    }
}