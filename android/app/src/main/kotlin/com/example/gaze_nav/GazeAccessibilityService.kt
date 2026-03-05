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

/**
 * GazeNav Accessibility Service
 *
 * Responsibilities:
 * 1. Receives cursor position + blink events from Flutter via broadcasts
 * 2. Draws an overlay with cursor, navigator pad, and mode-specific controls
 * 3. Performs system gestures (swipes, taps) via AccessibilityService API
 *
 * Modes:
 *   HOME_SCREEN   → Navigator pad (5 buttons) + cursor
 *   APPS_DRAWER   → Scroll up/down + home button + cursor
 *   QUICK_SETTINGS → Home button + cursor
 */
class GazeAccessibilityService : AccessibilityService() {

    companion object {
        const val TAG = "GazeNavService"

        // Broadcast actions (from Flutter)
        const val ACTION_UPDATE_CURSOR = "com.gaze_nav.UPDATE_CURSOR"
        const val ACTION_DOUBLE_BLINK = "com.gaze_nav.DOUBLE_BLINK"
        const val ACTION_OVERLAY_START = "com.gaze_nav.OVERLAY_START"
        const val ACTION_OVERLAY_STOP = "com.gaze_nav.OVERLAY_STOP"

        // Broadcast extras
        const val EXTRA_CURSOR_X = "cursor_x"
        const val EXTRA_CURSOR_Y = "cursor_y"

        // Singleton reference for Flutter communication
        var instance: GazeAccessibilityService? = null
            private set

        fun isRunning(): Boolean = instance != null
    }

    private lateinit var windowManager: WindowManager
    private var overlayManager: GazeOverlayManager? = null
    private val handler = Handler(Looper.getMainLooper())

    private var screenWidth = 0
    private var screenHeight = 0

    // State
    private var overlayActive = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
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

        // Register broadcast receiver
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

        Log.d(TAG, "Service connected and receiver registered")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Not used - we only need gesture dispatch
    }

    override fun onInterrupt() {
        Log.d(TAG, "Service interrupted")
    }

    override fun onDestroy() {
        stopOverlay()
        try { unregisterReceiver(receiver) } catch (_: Exception) {}
        instance = null
        super.onDestroy()
    }

    // ══════════════════════════════════════════
    // OVERLAY MANAGEMENT
    // ══════════════════════════════════════════

    private fun startOverlay() {
        if (overlayActive) return
        overlayActive = true

        handler.post {
            overlayManager = GazeOverlayManager(
                service = this,
                windowManager = windowManager,
                screenWidth = screenWidth,
                screenHeight = screenHeight,
                onGestureRequest = { gestureType -> performGazeGesture(gestureType) }
            )
            overlayManager?.showOverlay()
            Log.d(TAG, "Overlay started")
        }
    }

    private fun stopOverlay() {
        overlayActive = false
        handler.post {
            overlayManager?.hideOverlay()
            overlayManager = null
            Log.d(TAG, "Overlay stopped")
        }
    }

    // ══════════════════════════════════════════
    // GESTURE DISPATCH
    // ══════════════════════════════════════════

    fun performGazeGesture(type: GestureType) {
        Log.d(TAG, "Performing gesture: $type")

        val path = Path()
        val duration = 300L // ms for swipe

        when (type) {
            // Swipe UP from bottom → Open apps drawer
            GestureType.SWIPE_UP -> {
                path.moveTo(screenWidth / 2f, screenHeight - 50f)
                path.lineTo(screenWidth / 2f, screenHeight / 3f)
            }
            // Swipe DOWN from top → Open quick settings
            GestureType.SWIPE_DOWN -> {
                path.moveTo(screenWidth / 2f, 10f)
                path.lineTo(screenWidth / 2f, screenHeight * 2f / 3f)
            }
            // Swipe LEFT → Next page
            GestureType.SWIPE_LEFT -> {
                path.moveTo(screenWidth - 50f, screenHeight / 2f)
                path.lineTo(50f, screenHeight / 2f)
            }
            // Swipe RIGHT → Previous page
            GestureType.SWIPE_RIGHT -> {
                path.moveTo(50f, screenHeight / 2f)
                path.lineTo(screenWidth - 50f, screenHeight / 2f)
            }
            // Go HOME
            GestureType.GO_HOME -> {
                performGlobalAction(GLOBAL_ACTION_HOME)
                overlayManager?.setMode(NavigationMode.HOME_SCREEN)
                return
            }
            // BACK action
            GestureType.GO_BACK -> {
                performGlobalAction(GLOBAL_ACTION_BACK)
                return
            }
            // Scroll UP (in apps drawer)
            GestureType.SCROLL_UP -> {
                path.moveTo(screenWidth / 2f, screenHeight * 2f / 3f)
                path.lineTo(screenWidth / 2f, screenHeight / 3f)
            }
            // Scroll DOWN (in apps drawer)
            GestureType.SCROLL_DOWN -> {
                path.moveTo(screenWidth / 2f, screenHeight / 3f)
                path.lineTo(screenWidth / 2f, screenHeight * 2f / 3f)
            }
            // TAP at cursor position
            GestureType.TAP -> {
                val pos = overlayManager?.getCursorPosition()
                if (pos != null) {
                    path.moveTo(pos.first, pos.second)
                    path.lineTo(pos.first, pos.second)
                    dispatchSwipe(path, 50L) // Short duration = tap
                    return
                }
                return
            }
        }

        dispatchSwipe(path, duration)

        // Auto-switch mode after certain gestures
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
        val stroke = GestureDescription.StrokeDescription(path, 0, duration)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()

        dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                Log.d(TAG, "Gesture completed")
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                Log.d(TAG, "Gesture cancelled")
            }
        }, null)
    }
}

enum class GestureType {
    SWIPE_UP, SWIPE_DOWN, SWIPE_LEFT, SWIPE_RIGHT,
    GO_HOME, GO_BACK,
    SCROLL_UP, SCROLL_DOWN,
    TAP
}

enum class NavigationMode {
    HOME_SCREEN, APPS_DRAWER, QUICK_SETTINGS
}