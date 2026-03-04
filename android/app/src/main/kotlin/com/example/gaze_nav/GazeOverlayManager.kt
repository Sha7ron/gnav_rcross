package com.example.gazenav

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.*
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.*
import android.widget.FrameLayout

/**
 * Manages the overlay drawn on top of the home screen.
 *
 * Components:
 *   - Cursor (follows head position)
 *   - Navigator pad (HOME_SCREEN mode: 5-button compass)
 *   - Scroll controls (APPS_DRAWER mode: up/down arrows + home)
 *   - Home button (QUICK_SETTINGS mode)
 *
 * Dwell activation: cursor hovers on a button for 1.2s → activate gesture.
 */
class GazeOverlayManager(
    private val service: GazeAccessibilityService,
    private val windowManager: WindowManager,
    private val screenWidth: Int,
    private val screenHeight: Int,
    private val onGestureRequest: (GestureType) -> Unit
) {
    companion object {
        const val TAG = "GazeOverlay"
        const val DWELL_DURATION_MS = 1200L       // 1.2s to activate
        const val SCROLL_REPEAT_MS = 400L          // Scroll repeat interval
        const val CURSOR_SIZE = 44
        const val NAV_BUTTON_SIZE = 56
        const val NAV_PAD_RADIUS = 80
    }

    private var overlayView: OverlayCanvasView? = null
    private var currentMode = NavigationMode.HOME_SCREEN
    private var cursorX = screenWidth / 2f
    private var cursorY = screenHeight / 2f

    // Dwell state
    private var dwellTarget: NavButton? = null
    private var dwellStartTime = 0L
    private var dwellProgress = 0f
    private val handler = Handler(Looper.getMainLooper())

    // Scroll repeat
    private var isScrolling = false
    private val scrollRunnable = object : Runnable {
        override fun run() {
            if (isScrolling && dwellTarget != null) {
                val gesture = dwellTarget!!.gesture
                if (gesture == GestureType.SCROLL_UP || gesture == GestureType.SCROLL_DOWN) {
                    onGestureRequest(gesture)
                    handler.postDelayed(this, SCROLL_REPEAT_MS)
                }
            }
        }
    }

    // ── Button definitions per mode ──
    private val homeScreenButtons: List<NavButton> by lazy {
        val cx = screenWidth - NAV_PAD_RADIUS - 30f
        val cy = screenHeight / 2f
        listOf(
            NavButton("up", "Apps", GestureType.SWIPE_UP,
                cx, cy - NAV_PAD_RADIUS, NAV_BUTTON_SIZE.toFloat(),
                "\u25B2"),  // ▲
            NavButton("down", "Quick\nSettings", GestureType.SWIPE_DOWN,
                cx, cy + NAV_PAD_RADIUS, NAV_BUTTON_SIZE.toFloat(),
                "\u25BC"),  // ▼
            NavButton("right", "Next", GestureType.SWIPE_LEFT,
                cx + NAV_PAD_RADIUS, cy, NAV_BUTTON_SIZE.toFloat(),
                "\u25B6"),  // ▶
            NavButton("left", "Prev", GestureType.SWIPE_RIGHT,
                cx - NAV_PAD_RADIUS, cy, NAV_BUTTON_SIZE.toFloat(),
                "\u25C0"),  // ◀
            NavButton("home", "Home", GestureType.GO_HOME,
                cx, cy + NAV_PAD_RADIUS + 70, (NAV_BUTTON_SIZE * 0.9f),
                "\u2302")   // ⌂
        )
    }

    private val appsDrawerButtons: List<NavButton> by lazy {
        val rightX = screenWidth - 50f
        listOf(
            NavButton("scroll_up", "Scroll\nUp", GestureType.SCROLL_UP,
                rightX, screenHeight / 3f, NAV_BUTTON_SIZE.toFloat(),
                "\u25B2"),
            NavButton("scroll_down", "Scroll\nDown", GestureType.SCROLL_DOWN,
                rightX, screenHeight * 2f / 3f, NAV_BUTTON_SIZE.toFloat(),
                "\u25BC"),
            NavButton("home", "Home", GestureType.GO_HOME,
                screenWidth / 2f, 50f, (NAV_BUTTON_SIZE * 0.9f),
                "\u2302")
        )
    }

    private val quickSettingsButtons: List<NavButton> by lazy {
        listOf(
            NavButton("home", "Home", GestureType.GO_HOME,
                screenWidth / 2f, screenHeight - 100f, (NAV_BUTTON_SIZE * 0.9f),
                "\u2302")
        )
    }

    fun showOverlay() {
        if (overlayView != null) return

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START

        overlayView = OverlayCanvasView(service)
        windowManager.addView(overlayView, params)
        startRefresh()

        Log.d(TAG, "Overlay shown")
    }

    fun hideOverlay() {
        handler.removeCallbacksAndMessages(null)
        isScrolling = false
        overlayView?.let {
            try { windowManager.removeView(it) } catch (_: Exception) {}
        }
        overlayView = null
        Log.d(TAG, "Overlay hidden")
    }

    fun updateCursorPosition(x: Float, y: Float) {
        cursorX = x
        cursorY = y
        checkDwell()
    }

    fun onDoubleBlink() {
        // In QUICK_SETTINGS mode, double-blink can toggle settings
        // For now, it acts as a tap at cursor position
        if (currentMode == NavigationMode.QUICK_SETTINGS) {
            onGestureRequest(GestureType.TAP)
        }
    }

    fun setMode(mode: NavigationMode) {
        currentMode = mode
        dwellTarget = null
        dwellProgress = 0f
        isScrolling = false
        Log.d(TAG, "Mode changed to: $mode")
    }

    fun getCursorPosition(): Pair<Float, Float> = Pair(cursorX, cursorY)

    // ── Dwell detection ──

    private fun checkDwell() {
        val buttons = when (currentMode) {
            NavigationMode.HOME_SCREEN -> homeScreenButtons
            NavigationMode.APPS_DRAWER -> appsDrawerButtons
            NavigationMode.QUICK_SETTINGS -> quickSettingsButtons
        }

        var hoveredButton: NavButton? = null
        for (btn in buttons) {
            val dist = Math.sqrt(
                ((cursorX - btn.x) * (cursorX - btn.x) +
                        (cursorY - btn.y) * (cursorY - btn.y)).toDouble()
            ).toFloat()
            if (dist < btn.size * 0.8f) {
                hoveredButton = btn
                break
            }
        }

        if (hoveredButton == null) {
            // Not hovering any button
            dwellTarget = null
            dwellProgress = 0f
            isScrolling = false
            return
        }

        if (hoveredButton.id != dwellTarget?.id) {
            // Started hovering a new button
            dwellTarget = hoveredButton
            dwellStartTime = System.currentTimeMillis()
            dwellProgress = 0f
            isScrolling = false
        } else {
            // Still hovering same button
            val elapsed = System.currentTimeMillis() - dwellStartTime
            dwellProgress = (elapsed.toFloat() / DWELL_DURATION_MS).coerceIn(0f, 1f)

            if (dwellProgress >= 1f && !isScrolling) {
                // DWELL COMPLETE → activate!
                Log.d(TAG, "Dwell activated: ${hoveredButton.label}")
                onGestureRequest(hoveredButton.gesture)

                // For scroll gestures, start repeating
                if (hoveredButton.gesture == GestureType.SCROLL_UP ||
                    hoveredButton.gesture == GestureType.SCROLL_DOWN) {
                    isScrolling = true
                    handler.postDelayed(scrollRunnable, SCROLL_REPEAT_MS)
                } else {
                    // Reset for non-scroll gestures
                    dwellTarget = null
                    dwellProgress = 0f
                }
            }
        }
    }

    // ── Refresh loop ──

    private fun startRefresh() {
        handler.post(object : Runnable {
            override fun run() {
                overlayView?.invalidate()
                if (overlayView != null) {
                    handler.postDelayed(this, 33) // ~30 FPS refresh
                }
            }
        })
    }

    // ══════════════════════════════════════════
    // CANVAS DRAWING
    // ══════════════════════════════════════════

    @SuppressLint("ViewConstructor")
    inner class OverlayCanvasView(context: Context) : View(context) {

        private val cursorPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.CYAN
            style = Paint.Style.STROKE
            strokeWidth = 4f
        }
        private val cursorFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(100, 0, 255, 255)
            style = Paint.Style.FILL
        }
        private val cursorDotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.FILL
        }
        private val btnPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(180, 30, 40, 60)
            style = Paint.Style.FILL
        }
        private val btnBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(150, 0, 220, 180)
            style = Paint.Style.STROKE
            strokeWidth = 3f
        }
        private val btnHoverPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(60, 0, 255, 200)
            style = Paint.Style.FILL
        }
        private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 28f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
        private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(180, 200, 200, 200)
            textSize = 18f
            textAlign = Paint.Align.CENTER
        }
        private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(200, 0, 255, 180)
            style = Paint.Style.STROKE
            strokeWidth = 4f
            strokeCap = Paint.Cap.ROUND
        }
        private val homeBtnPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(180, 40, 50, 30)
            style = Paint.Style.FILL
        }
        private val homeBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(150, 100, 220, 100)
            style = Paint.Style.STROKE
            strokeWidth = 3f
        }
        private val modeLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(150, 0, 200, 150)
            textSize = 22f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
        private val connectLinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(40, 0, 200, 180)
            style = Paint.Style.STROKE
            strokeWidth = 2f
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)

            val buttons = when (currentMode) {
                NavigationMode.HOME_SCREEN -> homeScreenButtons
                NavigationMode.APPS_DRAWER -> appsDrawerButtons
                NavigationMode.QUICK_SETTINGS -> quickSettingsButtons
            }

            // ── Draw mode label ──
            val modeLabel = when (currentMode) {
                NavigationMode.HOME_SCREEN -> "HOME"
                NavigationMode.APPS_DRAWER -> "APPS DRAWER"
                NavigationMode.QUICK_SETTINGS -> "QUICK SETTINGS"
            }
            canvas.drawText(modeLabel, screenWidth / 2f, 35f, modeLabelPaint)

            // ── Draw navigator pad connecting lines (HOME mode only) ──
            if (currentMode == NavigationMode.HOME_SCREEN && homeScreenButtons.size >= 4) {
                val cx = homeScreenButtons[0].x  // up button X = center X
                val cy = (homeScreenButtons[0].y + homeScreenButtons[1].y) / 2f
                for (i in 0 until 4) {
                    canvas.drawLine(cx, cy, homeScreenButtons[i].x, homeScreenButtons[i].y,
                        connectLinePaint)
                }
                // Center dot
                canvas.drawCircle(cx, cy, 8f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.argb(100, 0, 200, 180)
                    style = Paint.Style.FILL
                })
            }

            // ── Draw buttons ──
            for (btn in buttons) {
                val isHovered = dwellTarget?.id == btn.id
                val isHome = btn.gesture == GestureType.GO_HOME
                val bgPaint = if (isHome) homeBtnPaint else btnPaint
                val borderP = if (isHome) homeBorderPaint else btnBorderPaint

                // Button circle
                canvas.drawCircle(btn.x, btn.y, btn.size / 2f, bgPaint)
                canvas.drawCircle(btn.x, btn.y, btn.size / 2f, borderP)

                // Hover highlight
                if (isHovered) {
                    canvas.drawCircle(btn.x, btn.y, btn.size / 2f, btnHoverPaint)
                }

                // Icon text
                canvas.drawText(btn.icon, btn.x, btn.y + 10f, textPaint)

                // Label below
                canvas.drawText(btn.label.split("\n")[0], btn.x,
                    btn.y + btn.size / 2f + 22f, labelPaint)

                // Dwell progress arc
                if (isHovered && dwellProgress > 0f) {
                    val rect = RectF(
                        btn.x - btn.size / 2f - 4,
                        btn.y - btn.size / 2f - 4,
                        btn.x + btn.size / 2f + 4,
                        btn.y + btn.size / 2f + 4
                    )
                    canvas.drawArc(rect, -90f, dwellProgress * 360f, false, progressPaint)
                }

                // Scrolling indicator
                if (isScrolling && isHovered) {
                    val pulseAlpha = ((System.currentTimeMillis() % 600) / 600f * 255).toInt()
                    val pulsePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        color = Color.argb(pulseAlpha.coerceIn(50, 200), 0, 255, 180)
                        style = Paint.Style.STROKE
                        strokeWidth = 3f
                    }
                    canvas.drawCircle(btn.x, btn.y, btn.size / 2f + 10f, pulsePaint)
                }
            }

            // ── Draw cursor ──
            val cSize = CURSOR_SIZE / 2f

            // Hover color
            val isOnButton = dwellTarget != null
            if (isOnButton) {
                cursorPaint.color = Color.argb(255, 0, 255, 150)
                cursorFillPaint.color = Color.argb(80, 0, 255, 150)
            } else {
                cursorPaint.color = Color.CYAN
                cursorFillPaint.color = Color.argb(100, 0, 255, 255)
            }

            canvas.drawCircle(cursorX, cursorY, cSize, cursorFillPaint)
            canvas.drawCircle(cursorX, cursorY, cSize, cursorPaint)
            canvas.drawCircle(cursorX, cursorY, 5f, cursorDotPaint)
        }
    }
}

/** Data class for a navigator button */
data class NavButton(
    val id: String,
    val label: String,
    val gesture: GestureType,
    val x: Float,
    val y: Float,
    val size: Float,
    val icon: String
)