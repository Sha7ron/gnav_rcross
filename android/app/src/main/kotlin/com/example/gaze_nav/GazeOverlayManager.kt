package com.example.gaze_nav

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.*
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.*
import android.widget.FrameLayout

class GazeOverlayManager(
    private val service: GazeAccessibilityService,
    private val windowManager: WindowManager,
    private val screenWidth: Int,
    private val screenHeight: Int,
    private val onGestureRequest: (GestureType) -> Unit
) {
    companion object {
        const val TAG = "GazeOverlay"
        const val DWELL_DURATION_MS = 1500L
        const val SCROLL_REPEAT_MS = 400L
        const val CURSOR_RADIUS = 22f
        const val BTN_RADIUS = 34f
        const val PAD_SPACING = 85f
    }

    private var overlayView: OverlayCanvasView? = null
    private var currentMode = NavigationMode.HOME_SCREEN
    private var cursorX = screenWidth / 2f
    private var cursorY = screenHeight / 2f

    private var dwellTarget: NavButton? = null
    private var dwellStartTime = 0L
    private var dwellProgress = 0f
    private val handler = Handler(Looper.getMainLooper())

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

    // ── Button definitions ──
    private val homeScreenButtons: List<NavButton> by lazy {
        val cx = screenWidth - PAD_SPACING - 40f
        val cy = screenHeight / 2f
        listOf(
            NavButton("up", "Apps", GestureType.SWIPE_UP,
                cx, cy - PAD_SPACING, BTN_RADIUS, "\u25B2",
                Color.argb(220, 0, 200, 180)),
            NavButton("down", "Quick", GestureType.SWIPE_DOWN,
                cx, cy + PAD_SPACING, BTN_RADIUS, "\u25BC",
                Color.argb(220, 0, 200, 180)),
            NavButton("right", "Next", GestureType.SWIPE_LEFT,
                cx + PAD_SPACING, cy, BTN_RADIUS, "\u25B6",
                Color.argb(220, 0, 200, 180)),
            NavButton("left", "Prev", GestureType.SWIPE_RIGHT,
                cx - PAD_SPACING, cy, BTN_RADIUS, "\u25C0",
                Color.argb(220, 0, 200, 180)),
            NavButton("center", "Home", GestureType.GO_HOME,
                cx, cy, (BTN_RADIUS * 0.85f), "\u2302",
                Color.argb(220, 100, 220, 100))
        )
    }

    private val appsDrawerButtons: List<NavButton> by lazy {
        val rightX = screenWidth - 55f
        listOf(
            NavButton("scroll_up", "Up", GestureType.SCROLL_UP,
                rightX, screenHeight / 3f, BTN_RADIUS, "\u25B2",
                Color.argb(220, 0, 200, 180)),
            NavButton("scroll_down", "Down", GestureType.SCROLL_DOWN,
                rightX, screenHeight * 2f / 3f, BTN_RADIUS, "\u25BC",
                Color.argb(220, 0, 200, 180)),
            NavButton("home", "Home", GestureType.GO_HOME,
                screenWidth / 2f, 55f, BTN_RADIUS, "\u2302",
                Color.argb(220, 100, 220, 100))
        )
    }

    private val quickSettingsButtons: List<NavButton> by lazy {
        listOf(
            NavButton("home", "Home", GestureType.GO_HOME,
                screenWidth / 2f, screenHeight - 110f, BTN_RADIUS, "\u2302",
                Color.argb(220, 100, 220, 100))
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
        Log.d(TAG, "Overlay shown: ${screenWidth}x${screenHeight}")
    }

    fun hideOverlay() {
        handler.removeCallbacksAndMessages(null)
        isScrolling = false
        overlayView?.let { try { windowManager.removeView(it) } catch (_: Exception) {} }
        overlayView = null
    }

    fun updateCursorPosition(x: Float, y: Float) {
        cursorX = x.coerceIn(0f, screenWidth.toFloat())
        cursorY = y.coerceIn(0f, screenHeight.toFloat())
        checkDwell()
    }

    fun onDoubleBlink() {
        if (currentMode == NavigationMode.QUICK_SETTINGS) {
            onGestureRequest(GestureType.TAP)
        }
    }

    fun setMode(mode: NavigationMode) {
        currentMode = mode
        dwellTarget = null
        dwellProgress = 0f
        isScrolling = false
    }

    fun getCursorPosition(): Pair<Float, Float> = Pair(cursorX, cursorY)

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
                        (cursorY - btn.y) * (cursorY - btn.y)).toDouble()).toFloat()
            if (dist < btn.radius * 2.5f) {
                hoveredButton = btn
                break
            }
        }

        if (hoveredButton == null) {
            dwellTarget = null
            dwellProgress = 0f
            isScrolling = false
            return
        }

        if (hoveredButton.id != dwellTarget?.id) {
            dwellTarget = hoveredButton
            dwellStartTime = System.currentTimeMillis()
            dwellProgress = 0f
            isScrolling = false
        } else {
            val elapsed = System.currentTimeMillis() - dwellStartTime
            dwellProgress = (elapsed.toFloat() / DWELL_DURATION_MS).coerceIn(0f, 1f)

            if (dwellProgress >= 1f && !isScrolling) {
                Log.d(TAG, "Dwell activated: ${hoveredButton.label}")
                onGestureRequest(hoveredButton.gesture)

                if (hoveredButton.gesture == GestureType.SCROLL_UP ||
                    hoveredButton.gesture == GestureType.SCROLL_DOWN) {
                    isScrolling = true
                    handler.postDelayed(scrollRunnable, SCROLL_REPEAT_MS)
                } else {
                    dwellTarget = null
                    dwellProgress = 0f
                }
            }
        }
    }

    private fun startRefresh() {
        handler.post(object : Runnable {
            override fun run() {
                overlayView?.invalidate()
                if (overlayView != null) handler.postDelayed(this, 33)
            }
        })
    }

    // ══════════════════════════════════════════
    // CANVAS DRAWING — Improved UI
    // ══════════════════════════════════════════

    @SuppressLint("ViewConstructor")
    inner class OverlayCanvasView(context: Context) : View(context) {

        private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 2.5f
        }
        private val hoverFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 30f; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
            color = Color.WHITE
        }
        private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 18f; textAlign = Paint.Align.CENTER
            color = Color.argb(200, 200, 200, 200)
        }
        private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 4f; strokeCap = Paint.Cap.ROUND
            color = Color.argb(230, 0, 255, 200)
        }
        private val cursorOuterPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 3f; color = Color.CYAN
        }
        private val cursorFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL; color = Color.argb(80, 0, 255, 255)
        }
        private val cursorDotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL; color = Color.WHITE
        }
        private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(40, 0, 0, 0); maskFilter = BlurMaskFilter(12f, BlurMaskFilter.Blur.NORMAL)
        }
        private val modePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 20f; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
            color = Color.argb(120, 0, 200, 150)
        }
        private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 1.5f
            color = Color.argb(50, 0, 200, 180)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)

            val buttons = when (currentMode) {
                NavigationMode.HOME_SCREEN -> homeScreenButtons
                NavigationMode.APPS_DRAWER -> appsDrawerButtons
                NavigationMode.QUICK_SETTINGS -> quickSettingsButtons
            }

            val modeLabel = when (currentMode) {
                NavigationMode.HOME_SCREEN -> "HOME"
                NavigationMode.APPS_DRAWER -> "APPS"
                NavigationMode.QUICK_SETTINGS -> "SETTINGS"
            }
            canvas.drawText(modeLabel, screenWidth / 2f, 38f, modePaint)

            // Connecting lines for home mode
            if (currentMode == NavigationMode.HOME_SCREEN && homeScreenButtons.size >= 5) {
                val center = homeScreenButtons[4] // center/home button
                for (i in 0 until 4) {
                    canvas.drawLine(center.x, center.y,
                        homeScreenButtons[i].x, homeScreenButtons[i].y, linePaint)
                }
            }

            // Draw buttons
            for (btn in buttons) {
                val isHovered = dwellTarget?.id == btn.id
                val isHome = btn.gesture == GestureType.GO_HOME

                // Shadow
                canvas.drawCircle(btn.x + 2, btn.y + 3, btn.radius + 2, shadowPaint)

                // Background
                bgPaint.color = if (isHome)
                    Color.argb(200, 25, 45, 25)
                else
                    Color.argb(200, 20, 30, 50)
                canvas.drawCircle(btn.x, btn.y, btn.radius, bgPaint)

                // Border
                borderPaint.color = btn.color
                canvas.drawCircle(btn.x, btn.y, btn.radius, borderPaint)

                // Hover glow
                if (isHovered) {
                    hoverFillPaint.color = Color.argb(50,
                        Color.red(btn.color), Color.green(btn.color), Color.blue(btn.color))
                    canvas.drawCircle(btn.x, btn.y, btn.radius + 6, hoverFillPaint)
                }

                // Icon
                canvas.drawText(btn.icon, btn.x, btn.y + 10f, iconPaint)

                // Label
                canvas.drawText(btn.label, btn.x, btn.y + btn.radius + 22f, labelPaint)

                // Dwell progress arc
                if (isHovered && dwellProgress > 0f) {
                    val r = btn.radius + 6
                    val rect = RectF(btn.x - r, btn.y - r, btn.x + r, btn.y + r)
                    canvas.drawArc(rect, -90f, dwellProgress * 360f, false, progressPaint)
                }

                // Scrolling pulse
                if (isScrolling && isHovered) {
                    val pulse = ((System.currentTimeMillis() % 800) / 800f)
                    val pulseR = btn.radius + 8 + pulse * 15
                    val alpha = ((1f - pulse) * 150).toInt().coerceIn(20, 150)
                    val pulsePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        color = Color.argb(alpha, 0, 255, 180)
                        style = Paint.Style.STROKE; strokeWidth = 2f
                    }
                    canvas.drawCircle(btn.x, btn.y, pulseR, pulsePaint)
                }
            }

            // Cursor
            val onBtn = dwellTarget != null
            if (onBtn) {
                cursorOuterPaint.color = Color.argb(255, 0, 255, 150)
                cursorFillPaint.color = Color.argb(60, 0, 255, 150)
            } else {
                cursorOuterPaint.color = Color.CYAN
                cursorFillPaint.color = Color.argb(80, 0, 255, 255)
            }
            canvas.drawCircle(cursorX, cursorY, CURSOR_RADIUS, cursorFillPaint)
            canvas.drawCircle(cursorX, cursorY, CURSOR_RADIUS, cursorOuterPaint)
            canvas.drawCircle(cursorX, cursorY, 5f, cursorDotPaint)
        }
    }
}

data class NavButton(
    val id: String,
    val label: String,
    val gesture: GestureType,
    val x: Float,
    val y: Float,
    val radius: Float,
    val icon: String,
    val color: Int
)