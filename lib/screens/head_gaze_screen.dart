/// ===========================================================================
/// GazeNav v5 - HEAD TRACKING SCREEN
/// ===========================================================================
///
/// Complete screen with:
/// - Camera preview (front camera)
/// - ML Kit face detection pipeline
/// - Head tracking cursor (midpoint-between-eyes method)
/// - Double-blink command detection
/// - Calibration flow
/// - Visual feedback
///
/// ===========================================================================

import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'head_tracking_engine.dart';
import 'blink_detector.dart';

class HeadGazeScreen extends StatefulWidget {
  const HeadGazeScreen({super.key});

  @override
  State<HeadGazeScreen> createState() => _HeadGazeScreenState();
}

class _HeadGazeScreenState extends State<HeadGazeScreen>
    with WidgetsBindingObserver {
  // ── Camera ──
  CameraController? _camCtrl;
  bool _camReady = false;
  bool _processing = false;

  // ── ML Kit ──
  late final FaceDetector _faceDetector;

  // ── Engines ──
  final _headTracker = HeadTrackingEngine();
  final _blinkDetector = BlinkDetector();

  // ── Screen state ──
  Offset _cursorPos = Offset.zero;
  bool _faceDetected = false;
  String _statusText = 'Initializing camera...';
  Color _statusColor = Colors.orange;
  int _fps = 0;
  int _frameCount = 0;
  DateTime _fpsTime = DateTime.now();

  // ── Blink visual feedback ──
  bool _showBlinkFlash = false;
  String _blinkLabel = '';

  // ── Debug mode ──
  bool _showDebug = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,  // For blink detection (eye open prob)
        enableLandmarks: true,       // For eye + nose landmarks
        enableContours: false,       // Not needed for head tracking
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );

    _blinkDetector.onDoubleBlink = _onDoubleBlink;
    _blinkDetector.onSingleBlink = _onSingleBlink;

    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camCtrl?.stopImageStream();
    _camCtrl?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _camCtrl?.stopImageStream();
    } else if (state == AppLifecycleState.resumed) {
      _startImageStream();
    }
  }

  // ══════════════════════════════════════════════════
  // CAMERA SETUP
  // ══════════════════════════════════════════════════

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _camCtrl = CameraController(
      front,
      ResolutionPreset.medium, // 480p - fast enough for real-time
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    try {
      await _camCtrl!.initialize();
      if (!mounted) return;
      setState(() {
        _camReady = true;
        _statusText = 'Look straight at the screen...';
      });
      _startImageStream();
    } catch (e) {
      setState(() {
        _statusText = 'Camera error: $e';
        _statusColor = Colors.red;
      });
    }
  }

  void _startImageStream() {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;
    if (_camCtrl!.value.isStreamingImages) return;

    _camCtrl!.startImageStream(_onCameraFrame);
  }

  // ══════════════════════════════════════════════════
  // FRAME PROCESSING PIPELINE
  // ══════════════════════════════════════════════════

  void _onCameraFrame(CameraImage image) {
    if (_processing) return;
    _processing = true;

    _processFrame(image).then((_) {
      _processing = false;
    });
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      // ── Build InputImage for ML Kit ──
      final inputImage = _buildInputImage(image);
      if (inputImage == null) return;

      // ── Run face detection ──
      final faces = await _faceDetector.processImage(inputImage);

      if (!mounted) return;

      if (faces.isEmpty) {
        setState(() {
          _faceDetected = false;
          _statusText = 'No face detected - look at camera';
          _statusColor = Colors.orange;
        });
        return;
      }

      final face = faces.first;

      // ── Run head tracking ──
      final imageSize = Size(
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final tracked = _headTracker.processFace(face, imageSize);

      // ── Run blink detection ──
      _blinkDetector.update(
        face.leftEyeOpenProbability,
        face.rightEyeOpenProbability,
      );

      // ── Update UI ──
      setState(() {
        _faceDetected = true;

        if (!_headTracker.isCalibrated) {
          _statusText =
          'Calibrating... ${_headTracker.calibrationProgress}%';
          _statusColor = Colors.amber;
        } else if (tracked) {
          final screenSize = MediaQuery.of(context).size;
          _cursorPos = _headTracker.toScreenPosition(screenSize);
          _statusText = 'Tracking';
          _statusColor = Colors.green;
        }

        // FPS counter
        _frameCount++;
        final now = DateTime.now();
        if (now.difference(_fpsTime).inMilliseconds >= 1000) {
          _fps = _frameCount;
          _frameCount = 0;
          _fpsTime = now;
        }
      });
    } catch (e) {
      debugPrint('Frame error: $e');
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    // NV21 format for Android
    final planes = image.planes;
    if (planes.isEmpty) return null;

    final bytes = Uint8List.fromList(
      planes.map((p) => p.bytes).expand((b) => b).toList(),
    );

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation270deg, // Front camera typical
      format: InputImageFormat.nv21,
      bytesPerRow: planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  // ══════════════════════════════════════════════════
  // BLINK HANDLERS
  // ══════════════════════════════════════════════════

  void _onDoubleBlink() {
    HapticFeedback.heavyImpact();
    setState(() {
      _showBlinkFlash = true;
      _blinkLabel = 'DOUBLE BLINK - SELECT';
    });

    // Visual flash feedback
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showBlinkFlash = false);
    });

    debugPrint('ACTION: Double blink at (${_cursorPos.dx.toInt()}, ${_cursorPos.dy.toInt()})');
  }

  void _onSingleBlink() {
    // Single blink - just visual feedback, no action
    debugPrint('Single blink detected (no action)');
  }

  // ══════════════════════════════════════════════════
  // BUILD UI
  // ══════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera preview (background) ──
          if (_camReady)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _camCtrl!.value.previewSize?.height ?? 480,
                  height: _camCtrl!.value.previewSize?.width ?? 640,
                  child: CameraPreview(_camCtrl!),
                ),
              ),
            ),

          // ── Semi-transparent overlay ──
          Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.4)),
          ),

          // ── Double blink flash ──
          if (_showBlinkFlash)
            Positioned.fill(
              child: Container(
                color: Colors.greenAccent.withOpacity(0.2),
              ),
            ),

          // ── Status bar ──
          Positioned(
            top: 50,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: _statusColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _statusColor.withOpacity(0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _faceDetected ? Icons.face : Icons.face_retouching_off,
                      color: _statusColor,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _statusText,
                      style: TextStyle(color: _statusColor, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Calibration overlay ──
          if (!_headTracker.isCalibrated && _faceDetected)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Crosshair target
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.amber, width: 2),
                    ),
                    child: const Icon(
                      Icons.center_focus_strong,
                      color: Colors.amber,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Look here and hold still',
                    style: TextStyle(
                      color: Colors.amber.withOpacity(0.9),
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 200,
                    child: LinearProgressIndicator(
                      value: _headTracker.calibrationProgress / 100.0,
                      backgroundColor: Colors.white12,
                      valueColor:
                      const AlwaysStoppedAnimation<Color>(Colors.amber),
                    ),
                  ),
                ],
              ),
            ),

          // ── GAZE CURSOR ──
          if (_headTracker.isCalibrated && _faceDetected)
            Positioned(
              left: _cursorPos.dx - 22,
              top: _cursorPos.dy - 22,
              child: IgnorePointer(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (_showBlinkFlash ? Colors.greenAccent : Colors.cyan)
                        .withOpacity(0.4),
                    border: Border.all(
                      color:
                      _showBlinkFlash ? Colors.greenAccent : Colors.cyan,
                      width: 2.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (_showBlinkFlash
                            ? Colors.greenAccent
                            : Colors.cyan)
                            .withOpacity(0.3),
                        blurRadius: 15,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  // Inner dot
                  child: Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _showBlinkFlash
                            ? Colors.greenAccent
                            : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ── Blink label flash ──
          if (_showBlinkFlash)
            Positioned(
              top: 110,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border:
                    Border.all(color: Colors.greenAccent.withOpacity(0.5)),
                  ),
                  child: Text(
                    _blinkLabel,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),

          // ── Debug overlay ──
          if (_showDebug && _headTracker.isCalibrated)
            Positioned(
              bottom: 100,
              left: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Cursor: (${_cursorPos.dx.toInt()}, ${_cursorPos.dy.toInt()})',
                      style: _debugStyle,
                    ),
                    Text(
                      'Norm: (${_headTracker.normalizedX.toStringAsFixed(3)}, '
                          '${_headTracker.normalizedY.toStringAsFixed(3)})',
                      style: _debugStyle,
                    ),
                    Text('FPS: $_fps', style: _debugStyle),
                    Text(
                      'Eyes: ${_blinkDetector.eyeOpenProbability.toStringAsFixed(2)} '
                          '[${_blinkDetector.stateLabel}]',
                      style: _debugStyle,
                    ),
                  ],
                ),
              ),
            ),

          // ── Bottom controls ──
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _controlButton(
                  icon: Icons.arrow_back,
                  label: 'Back',
                  onTap: () => Navigator.pop(context),
                ),
                _controlButton(
                  icon: Icons.center_focus_strong,
                  label: 'Recalibrate',
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _headTracker.recalibrate();
                    _blinkDetector.reset();
                  },
                  color: Colors.amber,
                ),
                _controlButton(
                  icon: _showDebug ? Icons.bug_report : Icons.bug_report_outlined,
                  label: 'Debug',
                  onTap: () => setState(() => _showDebug = !_showDebug),
                  color: _showDebug ? Colors.cyan : Colors.white54,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TextStyle get _debugStyle => const TextStyle(
    color: Colors.white70,
    fontSize: 11,
    fontFamily: 'monospace',
    height: 1.5,
  );

  Widget _controlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.15),
              border: Border.all(color: color.withOpacity(0.5)),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(color: color.withOpacity(0.8), fontSize: 11)),
        ],
      ),
    );
  }
}