package com.example.gaze_nav

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import androidx.core.app.NotificationCompat

/**
 * Foreground Service that runs native camera + ML Kit tracking
 * independently of Flutter's Activity lifecycle.
 *
 * When started, opens Camera2 → ML Kit → head tracking → overlay update.
 * Flutter is no longer needed for tracking while on home screen.
 */
class GazeForegroundService : Service() {

    companion object {
        const val TAG = "GazeFG"
        const val CHANNEL_ID = "gazenav_tracking"
        const val NOTIFICATION_ID = 1001

        // Extras for calibration data
        const val EXTRA_BASE_MID_X = "base_mid_x"
        const val EXTRA_BASE_MID_Y = "base_mid_y"
        const val EXTRA_BASE_NOSE_X = "base_nose_x"
        const val EXTRA_BASE_NOSE_Y = "base_nose_y"
        const val EXTRA_SENS_X = "sens_x"
        const val EXTRA_SENS_Y = "sens_y"
        const val EXTRA_IMG_W = "img_w"
        const val EXTRA_IMG_H = "img_h"
    }

    private var tracker: NativeCameraTracker? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Get screen size
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getMetrics(metrics)

        // Create native tracker with cursor -> overlay bridge
        tracker = NativeCameraTracker(this) { x, y ->
            // Send cursor update directly to accessibility service via broadcast
            val cursorIntent = Intent(GazeAccessibilityService.ACTION_UPDATE_CURSOR)
            cursorIntent.setPackage(packageName)
            cursorIntent.putExtra(GazeAccessibilityService.EXTRA_CURSOR_X, x)
            cursorIntent.putExtra(GazeAccessibilityService.EXTRA_CURSOR_Y, y)
            sendBroadcast(cursorIntent)
        }

        // Apply calibration data from Flutter
        tracker?.apply {
            baseMidX = intent?.getDoubleExtra(EXTRA_BASE_MID_X, 0.0) ?: 0.0
            baseMidY = intent?.getDoubleExtra(EXTRA_BASE_MID_Y, 0.0) ?: 0.0
            baseNoseX = intent?.getDoubleExtra(EXTRA_BASE_NOSE_X, 0.0) ?: 0.0
            baseNoseY = intent?.getDoubleExtra(EXTRA_BASE_NOSE_Y, 0.0) ?: 0.0
            sensX = intent?.getDoubleExtra(EXTRA_SENS_X, 5.0) ?: 5.0
            sensY = intent?.getDoubleExtra(EXTRA_SENS_Y, 4.5) ?: 4.5
            imgW = intent?.getDoubleExtra(EXTRA_IMG_W, 640.0) ?: 640.0
            imgH = intent?.getDoubleExtra(EXTRA_IMG_H, 480.0) ?: 480.0
            screenWidth = metrics.widthPixels.toFloat()
            screenHeight = metrics.heightPixels.toFloat()
        }

        tracker?.start()
        Log.d(TAG, "Foreground service + native tracker started")

        return START_STICKY
    }

    override fun onDestroy() {
        tracker?.stop()
        tracker = null
        Log.d(TAG, "Foreground service stopped")
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "GazeNav Tracking",
                NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows when GazeNav is actively tracking"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GazeNav Active")
            .setContentText("Head tracking is running. Tap to return.")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}