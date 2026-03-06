package com.example.gaze_nav

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Path
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

enum class GestureType {
    SWIPE_UP, SWIPE_DOWN, SWIPE_LEFT, SWIPE_RIGHT,
    GO_HOME, GO_BACK,
    SCROLL_UP, SCROLL_DOWN,
    TAP
}

enum class NavigationMode {
    HOME_SCREEN, APPS_DRAWER, QUICK_SETTINGS
}

class GazeAccessibilityService : AccessibilityService() {

    companion object {
        const val TAG = "GazeNavService"
        const val ACTION_UPDATE_CURSOR = "com.gaze_nav.UPDATE_CURSOR"
        const val ACTION_DOUBLE_BLINK = "com.gaze_nav.DOUBLE_BLINK"
        const val ACTION_OVERLAY_START = "com.gaze_nav.OVERLAY_START"
        const val ACTION_OVERLAY_STOP = "com.gaze_nav.OVERLAY_STOP"
        const val EXTRA_CURSOR_X = "cursor_x"
        const val EXTRA_CURSOR_Y = "cursor_y"

        var instance: GazeAccessibilityService? = null
            private set

        fun isRunning(): Boolean = instance != null
    }

    private lateinit var windowManager: WindowManager
    private var overlayManager: GazeOverlayManager? = null
    private val handler = Handler(Looper.getMainLooper())
    private var screenWidth = 0
    private var screenHeight = 0
    private var overlayActive = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            try {
                when (intent?.action) {
                    ACTION_UPDATE_CURSOR -> {
                        val x = intent.getFloatExtra(EXTRA_CURSOR_X, 0f)
                        val y = intent.getFloatExtra(EXTRA_CURSOR_Y, 0f)
                        overlayManager?.updateCursorPosition(x, y)
                    }
                    ACTION_DOUBLE_BLINK -> {
                        overlayManager?.onDoubleBlink()
                    }
                    ACTION_OVERLAY_START -> {
                        startOverlay()
                    }
                    ACTION_OVERLAY_STOP -> {
                        stopOverlay()
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Receiver error: ${e.message}", e)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getMetrics(metrics)
        screenWidth = metrics.widthPixels
        screenHeight = metrics.heightPixels
        Log.d(TAG, "Service created. Screen: ${screenWidth}x${screenHeight}")
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        val filter = IntentFilter().apply {
            addAction(ACTION_UPDATE_CURSOR)
            addAction(ACTION_DOUBLE_BLINK)
            addAction(ACTION_OVERLAY_START)
            addAction(ACTION_OVERLAY_STOP)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        Log.d(TAG, "Service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    override fun onDestroy() {
        stopOverlay()
        try { unregisterReceiver(receiver) } catch (_: Exception) {}
        instance = null
        super.onDestroy()
    }

    private fun startOverlay() {
        if (overlayActive) return
        overlayActive = true
        handler.post {
            try {
                overlayManager = GazeOverlayManager(
                    service = this,
                    windowManager = windowManager,
                    screenWidth = screenWidth,
                    screenHeight = screenHeight,
                    onGestureRequest = { gestureType -> performGazeGesture(gestureType) }
                )
                overlayManager?.showOverlay()
                Log.d(TAG, "Overlay started")
            } catch (e: Exception) {
                Log.e(TAG, "Overlay start error: ${e.message}", e)
            }
        }
    }

    private fun stopOverlay() {
        overlayActive = false
        handler.post {
            overlayManager?.hideOverlay()
            overlayManager = null
        }
    }

    fun performGazeGesture(type: GestureType) {
        Log.d(TAG, "Gesture: $type")
        val path = Path()
        val duration = 300L

        when (type) {
            GestureType.SWIPE_UP -> {
                path.moveTo(screenWidth / 2f, screenHeight - 50f)
                path.lineTo(screenWidth / 2f, screenHeight / 3f)
            }
            GestureType.SWIPE_DOWN -> {
                path.moveTo(screenWidth / 2f, 10f)
                path.lineTo(screenWidth / 2f, screenHeight * 2f / 3f)
            }
            GestureType.SWIPE_LEFT -> {
                path.moveTo(screenWidth - 50f, screenHeight / 2f)
                path.lineTo(50f, screenHeight / 2f)
            }
            GestureType.SWIPE_RIGHT -> {
                path.moveTo(50f, screenHeight / 2f)
                path.lineTo(screenWidth - 50f, screenHeight / 2f)
            }
            GestureType.GO_HOME -> {
                performGlobalAction(GLOBAL_ACTION_HOME)
                overlayManager?.setMode(NavigationMode.HOME_SCREEN)
                return
            }
            GestureType.GO_BACK -> {
                performGlobalAction(GLOBAL_ACTION_BACK)
                return
            }
            GestureType.SCROLL_UP -> {
                path.moveTo(screenWidth / 2f, screenHeight * 2f / 3f)
                path.lineTo(screenWidth / 2f, screenHeight / 3f)
            }
            GestureType.SCROLL_DOWN -> {
                path.moveTo(screenWidth / 2f, screenHeight / 3f)
                path.lineTo(screenWidth / 2f, screenHeight * 2f / 3f)
            }
            GestureType.TAP -> {
                val pos = overlayManager?.getCursorPosition()
                if (pos != null) {
                    path.moveTo(pos.first, pos.second)
                    path.lineTo(pos.first, pos.second)
                    dispatchSwipe(path, 50L)
                }
                return
            }
        }

        dispatchSwipe(path, duration)

        when (type) {
            GestureType.SWIPE_UP -> {
                handler.postDelayed({
                    overlayManager?.setMode(NavigationMode.APPS_DRAWER)
                }, 500)
            }
            GestureType.SWIPE_DOWN -> {
                handler.postDelayed({
                    overlayManager?.setMode(NavigationMode.QUICK_SETTINGS)
                }, 500)
            }
            else -> {}
        }
    }

    private fun dispatchSwipe(path: Path, duration: Long) {
        try {
            val stroke = GestureDescription.StrokeDescription(path, 0, duration)
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            dispatchGesture(gesture, object : GestureResultCallback() {
                override fun onCompleted(g: GestureDescription?) {
                    Log.d(TAG, "Gesture completed")
                }
                override fun onCancelled(g: GestureDescription?) {
                    Log.d(TAG, "Gesture cancelled")
                }
            }, null)
        } catch (e: Exception) {
            Log.e(TAG, "Gesture dispatch error: ${e.message}", e)
        }
    }
}