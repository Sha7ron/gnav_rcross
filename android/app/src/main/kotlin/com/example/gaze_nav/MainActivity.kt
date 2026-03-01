package com.example.gaze_nav_app

import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.gazenav/unity"

    // ═══════════════════════════════════════════════════════════════
    // Change this to match your Unity game's package name.
    // To find it: open Unity → Edit → Project Settings → Player
    //   → Other Settings → Package Name
    // It's usually something like "com.DefaultCompany.YourGameName"
    // ═══════════════════════════════════════════════════════════════
    private val UNITY_PACKAGE = "com.gazenav.roadcrossing"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchUnity" -> {
                        val launched = launchUnityApp()
                        result.success(launched)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun launchUnityApp(): Boolean {
        val pm: PackageManager = packageManager

        // Try to get the launch intent for the Unity app
        val intent: Intent? = pm.getLaunchIntentForPackage(UNITY_PACKAGE)

        return if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } else {
            false // App not installed
        }
    }
}