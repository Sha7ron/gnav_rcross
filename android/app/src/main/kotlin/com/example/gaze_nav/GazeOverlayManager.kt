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
                val g = dwellTarget!!.gesture
                if (g == GestureType.SCROLL_UP || g == GestureType.SCROLL_DOWN) {
                    onGestureRequest(g)
                    handler.postDelayed(this, SCROLL_REPEAT_MS)
                }
            }
        }
    }

    // ── HOME SCREEN buttons ──
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

    // ── APPS DRAWER buttons ──
    private val appsDrawerButtons: List<NavButton> by lazy {
        val rx = screenWidth - 55f
        listOf(
            NavButton("scroll_up", "Up", GestureType.SCROLL_UP,
                rx, screenHeight / 3f, BTN_RADIUS, "\u25B2",
                Color.argb(220, 0, 200, 180)),
            NavButton("scroll_down", "Down", GestureType.SCROLL_DOWN,
                rx, screenHeight * 2f / 3f, BTN_RADIUS, "\u25BC",
                Color.argb(220, 0, 200, 180)),
            NavButton("home", "Home", GestureType.GO_HOME,
                screenWidth / 2f, 55f, BTN_RADIUS, "\u2302",
                Color.argb(220, 100, 220, 100))
        )
    }

    // ── QUICK SETTINGS buttons (with expand/collapse) ──
    private val quickSettingsButtons: List<NavButton> by lazy {
        val rx = screenWidth - 55f
        listOf(
            NavButton("expand", "More", GestureType.SWIPE_DOWN_SHORT,
                rx, screenHeight / 3f, BTN_RADIUS, "\u25BC",
                Color.argb(220, 255, 180, 0)),
            NavButton("collapse", "Less", GestureType.SWIPE_UP_SHORT,
                rx, screenHeight / 3f + PAD_SPACING, BTN_RADIUS, "\u25B2",
                Color.argb(220, 255, 180, 0)),
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
            PixelFormat.TRANSLUCENT)
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
        Log.d(TAG, "Mode: $mode")
    }

    fun getCursorPosition(): Pair<Float, Float> = Pair(cursorX, cursorY)

    private fun checkDwell() {
        val buttons = when (currentMode) {
            NavigationMode.HOME_SCREEN -> homeScreenButtons
            NavigationMode.APPS_DRAWER -> appsDrawerButtons
            NavigationMode.QUICK_SETTINGS -> quickSettingsButtons
        }

        var hovered: NavButton? = null
        for (btn in buttons) {
            val dx = cursorX - btn.x
            val dy = cursorY - btn.y
            val dist = Math.sqrt((dx * dx + dy * dy).toDouble()).toFloat()
            if (dist < btn.radius * 2.5f) { hovered = btn; break }
        }

        if (hovered == null) {
            dwellTarget = null; dwellProgress = 0f; isScrolling = false; return
        }

        if (hovered.id != dwellTarget?.id) {
            dwellTarget = hovered; dwellStartTime = System.currentTimeMillis()
            dwellProgress = 0f; isScrolling = false
        } else {
            val elapsed = System.currentTimeMillis() - dwellStartTime
            dwellProgress = (elapsed.toFloat() / DWELL_DURATION_MS).coerceIn(0f, 1f)
            if (dwellProgress >= 1f && !isScrolling) {
                Log.d(TAG, "Dwell: ${hovered.label}")
                onGestureRequest(hovered.gesture)
                if (hovered.gesture == GestureType.SCROLL_UP || hovered.gesture == GestureType.SCROLL_DOWN) {
                    isScrolling = true
                    handler.postDelayed(scrollRunnable, SCROLL_REPEAT_MS)
                } else { dwellTarget = null; dwellProgress = 0f }
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
    // DRAWING
    // ══════════════════════════════════════════
    @SuppressLint("ViewConstructor")
    inner class OverlayCanvasView(context: Context) : View(context) {

        private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 2.5f }
        private val hoverPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 28f; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
            color = Color.WHITE }
        private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 17f; textAlign = Paint.Align.CENTER
            color = Color.argb(200, 210, 210, 210) }
        private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 4f; strokeCap = Paint.Cap.ROUND
            color = Color.argb(230, 0, 255, 200) }
        private val cursorStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 3f; color = Color.CYAN }
        private val cursorFill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL; color = Color.argb(80, 0, 255, 255) }
        private val cursorDot = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL; color = Color.WHITE }
        private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(50, 0, 0, 0)
            maskFilter = BlurMaskFilter(10f, BlurMaskFilter.Blur.NORMAL) }
        private val modePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 20f; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
            color = Color.argb(120, 0, 200, 150) }
        private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 1.5f
            color = Color.argb(50, 0, 200, 180) }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)

            val buttons = when (currentMode) {
                NavigationMode.HOME_SCREEN -> homeScreenButtons
                NavigationMode.APPS_DRAWER -> appsDrawerButtons
                NavigationMode.QUICK_SETTINGS -> quickSettingsButtons
            }

            val label = when (currentMode) {
                NavigationMode.HOME_SCREEN -> "HOME"
                NavigationMode.APPS_DRAWER -> "APPS"
                NavigationMode.QUICK_SETTINGS -> "SETTINGS"
            }
            canvas.drawText(label, screenWidth / 2f, 38f, modePaint)

            // Connect lines for home d-pad
            if (currentMode == NavigationMode.HOME_SCREEN && homeScreenButtons.size >= 5) {
                val c = homeScreenButtons[4]
                for (i in 0 until 4) canvas.drawLine(c.x, c.y,
                    homeScreenButtons[i].x, homeScreenButtons[i].y, linePaint)
            }

            for (btn in buttons) {
                val isHov = dwellTarget?.id == btn.id

                // Shadow
                canvas.drawCircle(btn.x + 2, btn.y + 3, btn.radius + 2, shadowPaint)

                // Background
                bgPaint.color = when {
                    btn.gesture == GestureType.GO_HOME -> Color.argb(210, 25, 45, 25)
                    btn.gesture == GestureType.SWIPE_DOWN_SHORT ||
                            btn.gesture == GestureType.SWIPE_UP_SHORT -> Color.argb(210, 45, 35, 10)
                    else -> Color.argb(210, 20, 30, 50)
                }
                canvas.drawCircle(btn.x, btn.y, btn.radius, bgPaint)

                // Border
                borderPaint.color = btn.color
                canvas.drawCircle(btn.x, btn.y, btn.radius, borderPaint)

                // Hover glow
                if (isHov) {
                    hoverPaint.color = Color.argb(50,
                        Color.red(btn.color), Color.green(btn.color), Color.blue(btn.color))
                    canvas.drawCircle(btn.x, btn.y, btn.radius + 8, hoverPaint)
                }

                // Icon
                canvas.drawText(btn.icon, btn.x, btn.y + 10f, iconPaint)

                // Label
                canvas.drawText(btn.label, btn.x, btn.y + btn.radius + 22f, labelPaint)

                // Dwell arc
                if (isHov && dwellProgress > 0f) {
                    val r = btn.radius + 6
                    val rect = RectF(btn.x - r, btn.y - r, btn.x + r, btn.y + r)
                    canvas.drawArc(rect, -90f, dwellProgress * 360f, false, progressPaint)
                }

                // Scroll pulse
                if (isScrolling && isHov) {
                    val pulse = ((System.currentTimeMillis() % 800) / 800f)
                    val pr = btn.radius + 8 + pulse * 15
                    val a = ((1f - pulse) * 150).toInt().coerceIn(20, 150)
                    val pp = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        color = Color.argb(a, 0, 255, 180)
                        style = Paint.Style.STROKE; strokeWidth = 2f }
                    canvas.drawCircle(btn.x, btn.y, pr, pp)
                }
            }

            // Cursor
            val onBtn = dwellTarget != null
            cursorStroke.color = if (onBtn) Color.argb(255, 0, 255, 150) else Color.CYAN
            cursorFill.color = if (onBtn) Color.argb(60, 0, 255, 150)
            else Color.argb(80, 0, 255, 255)
            canvas.drawCircle(cursorX, cursorY, CURSOR_RADIUS, cursorFill)
            canvas.drawCircle(cursorX, cursorY, CURSOR_RADIUS, cursorStroke)
            canvas.drawCircle(cursorX, cursorY, 5f, cursorDot)
        }
    }
}

data class NavButton(
    val id: String, val label: String, val gesture: GestureType,
    val x: Float, val y: Float, val radius: Float,
    val icon: String, val color: Int
)