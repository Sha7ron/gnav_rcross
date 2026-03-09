package com.example.gaze_nav

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.*
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Native Camera2 + ML Kit head tracker that runs in foreground service.
 * Independent of Flutter - camera keeps running when app is backgrounded.
 */
class NativeCameraTracker(
    private val context: Context,
    private val onCursorUpdate: (Float, Float) -> Unit
) {
    companion object {
        const val TAG = "NativeTracker"
        const val IMAGE_WIDTH = 640
        const val IMAGE_HEIGHT = 480
    }

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var bgThread: HandlerThread? = null
    private var bgHandler: Handler? = null
    private var faceDetector: FaceDetector? = null
    @Volatile private var processing = false
    @Volatile var isRunning = false
        private set

    // Calibration (set from Flutter before start)
    var baseMidX = 0.0; var baseMidY = 0.0
    var baseNoseX = 0.0; var baseNoseY = 0.0
    var sensX = 5.0; var sensY = 4.5
    var imgW = IMAGE_WIDTH.toDouble()
    var imgH = IMAGE_HEIGHT.toDouble()
    var screenWidth = 1080f; var screenHeight = 2400f

    // Double EMA
    private var sX = 0.0; private var sY = 0.0
    private var s2X = 0.0; private var s2Y = 0.0
    private var emaInit = false
    private val a1 = 0.22; private val a2 = 0.30
    private val deadZone = 0.012
    private val edgeThreshold = 0.6; private val edgeFactor = 1.5

    private var frameCount = 0
    private var lastLogTime = 0L

    fun start() {
        if (isRunning) return
        isRunning = true
        emaInit = false
        frameCount = 0
        lastLogTime = System.currentTimeMillis()

        Log.d(TAG, "Starting native tracker...")
        Log.d(TAG, "  baseMid=($baseMidX, $baseMidY)")
        Log.d(TAG, "  baseNose=($baseNoseX, $baseNoseY)")
        Log.d(TAG, "  sens=($sensX, $sensY) img=(${imgW}x${imgH})")
        Log.d(TAG, "  screen=(${screenWidth}x${screenHeight})")

        val opts = FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
            .build()
        faceDetector = FaceDetection.getClient(opts)

        bgThread = HandlerThread("NativeCamTracker").also { it.start() }
        bgHandler = Handler(bgThread!!.looper)

        openCamera()
    }

    fun stop() {
        isRunning = false
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        try { captureSession?.close() } catch (_: Exception) {}
        try { cameraDevice?.close() } catch (_: Exception) {}
        try { imageReader?.close() } catch (_: Exception) {}
        try { faceDetector?.close() } catch (_: Exception) {}
        try { bgThread?.quitSafely() } catch (_: Exception) {}
        captureSession = null; cameraDevice = null
        imageReader = null; faceDetector = null
        bgThread = null; bgHandler = null
        Log.d(TAG, "Stopped. Processed $frameCount frames total.")
    }

    @SuppressLint("MissingPermission")
    private fun openCamera() {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        var frontId: String? = null
        for (id in manager.cameraIdList) {
            val chars = manager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING)
                == CameraCharacteristics.LENS_FACING_FRONT) {
                frontId = id; break
            }
        }
        if (frontId == null) {
            Log.e(TAG, "ERROR: No front camera!"); return
        }

        imageReader = ImageReader.newInstance(
            IMAGE_WIDTH, IMAGE_HEIGHT, ImageFormat.YUV_420_888, 2)
        imageReader!!.setOnImageAvailableListener({ reader ->
            val img = try { reader.acquireLatestImage() } catch (_: Exception) { null }
            if (img == null) return@setOnImageAvailableListener
            if (!processing && isRunning) {
                processing = true
                processFrame(img)
            } else {
                img.close()
            }
        }, bgHandler)

        Log.d(TAG, "Opening camera $frontId...")
        manager.openCamera(frontId, object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) {
                Log.d(TAG, "Camera OPENED successfully")
                cameraDevice = cam
                startCapture()
            }
            override fun onDisconnected(cam: CameraDevice) {
                Log.w(TAG, "Camera disconnected"); cam.close(); cameraDevice = null
            }
            override fun onError(cam: CameraDevice, error: Int) {
                Log.e(TAG, "Camera ERROR: $error"); cam.close(); cameraDevice = null
            }
        }, bgHandler)
    }

    private fun startCapture() {
        val cam = cameraDevice ?: return
        val reader = imageReader ?: return
        try {
            val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            req.addTarget(reader.surface)
            req.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                android.util.Range(5, 15))

            cam.createCaptureSession(listOf(reader.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        try {
                            session.setRepeatingRequest(req.build(), null, bgHandler)
                            Log.d(TAG, "Capture session STARTED")
                        } catch (e: Exception) {
                            Log.e(TAG, "setRepeatingRequest failed: ${e.message}")
                        }
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Capture session config FAILED")
                    }
                }, bgHandler)
        } catch (e: Exception) {
            Log.e(TAG, "startCapture failed: ${e.message}")
        }
    }

    private fun processFrame(image: Image) {
        try {
            // Create InputImage from Camera2 Image
            val inputImage = InputImage.fromMediaImage(image, 270)

            faceDetector?.process(inputImage)
                ?.addOnSuccessListener { faces ->
                    if (faces.isNotEmpty() && isRunning) {
                        trackFace(faces[0])
                    }
                    image.close()
                    processing = false
                }
                ?.addOnFailureListener { e ->
                    Log.w(TAG, "ML Kit failed: ${e.message}")
                    image.close()
                    processing = false
                }
        } catch (e: Exception) {
            Log.e(TAG, "processFrame error: ${e.message}")
            try { image.close() } catch (_: Exception) {}
            processing = false
        }
    }

    private fun trackFace(face: Face) {
        val leftEye = face.getLandmark(FaceLandmark.LEFT_EYE)
        val rightEye = face.getLandmark(FaceLandmark.RIGHT_EYE)
        val nose = face.getLandmark(FaceLandmark.NOSE_BASE)
        if (leftEye == null || rightEye == null) return

        frameCount++

        // Log every 2 seconds
        val now = System.currentTimeMillis()
        if (now - lastLogTime > 2000) {
            Log.d(TAG, "Tracking: frame=$frameCount leftEye=(${leftEye.position.x}, ${leftEye.position.y})")
            lastLogTime = now
        }

        val midX = (leftEye.position.x + rightEye.position.x) / 2.0
        val midY = (leftEye.position.y + rightEye.position.y) / 2.0
        val nX = nose?.position?.x?.toDouble() ?: midX
        val nY = nose?.position?.y?.toDouble() ?: (midY + imgH * 0.05)

        val dMidX = (midX - baseMidX) / imgW
        val dMidY = (midY - baseMidY) / imgH
        val dNoseX = (nX - baseNoseX) / imgW
        val dNoseY = (nY - baseNoseY) / imgH

        val fusedX = dMidX * 0.55 + dNoseX * 0.45
        val fusedY = dMidY * 0.55 + dNoseY * 0.45

        var rawX = fusedX * sensX
        var rawY = fusedY * sensY

        if (abs(rawX) < deadZone) rawX = 0.0
        if (abs(rawY) < deadZone) rawY = 0.0
        rawX = -rawX  // mirror for front camera

        rawX = edgeBoost(rawX)
        rawY = edgeBoost(rawY)

        if (!emaInit) {
            sX = rawX; sY = rawY; s2X = rawX; s2Y = rawY; emaInit = true
        } else {
            sX += (rawX - sX) * a1; sY += (rawY - sY) * a1
            s2X += (sX - s2X) * a2; s2Y += (sY - s2Y) * a2
        }

        val outX = s2X.coerceIn(-1.0, 1.0)
        val outY = s2Y.coerceIn(-1.0, 1.0)

        val sx = ((1.0 + outX) / 2.0 * screenWidth).toFloat()
        val sy = ((1.0 + outY) / 2.0 * screenHeight).toFloat()

        onCursorUpdate(sx, sy)
    }

    private fun edgeBoost(v: Double): Double {
        val a = abs(v)
        if (a > edgeThreshold) {
            val extra = (a - edgeThreshold) / (1.0 - edgeThreshold)
            val boosted = a + extra * edgeFactor * (1.0 - edgeThreshold)
            return if (v > 0) boosted else -boosted
        }
        return v
    }
}