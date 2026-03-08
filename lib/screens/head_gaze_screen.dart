/// ===========================================================================
/// GazeNav v6.1 - HEAD TRACKING + SYSTEM NAVIGATION (Fixed coordinates)
/// ===========================================================================
///
/// FIX: Cursor coordinates sent to native overlay are now in DEVICE PIXELS
///      (multiplied by devicePixelRatio) instead of Flutter logical pixels.
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
  static const _channel = MethodChannel('com.gaze_nav/native');

  CameraController? _camCtrl;
  bool _camReady = false;
  bool _processing = false;

  late final FaceDetector _faceDetector;
  final _headTracker = HeadTrackingEngine();
  final _blinkDetector = BlinkDetector();

  Offset _cursorPos = Offset.zero;
  bool _faceDetected = false;
  String _statusText = 'Initializing camera...';
  Color _statusColor = Colors.orange;
  int _fps = 0;
  int _frameCount = 0;
  DateTime _fpsTime = DateTime.now();

  bool _overlayRunning = false;
  bool _accessibilityEnabled = false;
  bool _showDebug = false;
  bool _showBlinkFlash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableLandmarks: true,
        enableContours: false,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );

    _blinkDetector.onDoubleBlink = _onDoubleBlink;
    _blinkDetector.onSingleBlink = () {};

    _initCamera();
    _checkAccessibility();
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
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (!_overlayRunning) _camCtrl?.stopImageStream();
    } else if (state == AppLifecycleState.resumed) {
      _startImageStream();
      _checkAccessibility();
    }
  }

  Future<void> _checkAccessibility() async {
    try {
      final enabled = await _channel.invokeMethod('checkAccessibility');
      setState(() => _accessibilityEnabled = enabled == true);
    } catch (e) {
      debugPrint('Accessibility check: $e');
    }
  }

  Future<void> _openAccessibilitySettings() async {
    try { await _channel.invokeMethod('openAccessibility'); } catch (_) {}
  }

  Future<void> _startNavigation() async {
    if (!_accessibilityEnabled) { _showAccessibilityDialog(); return; }
    if (!_headTracker.isCalibrated) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please complete calibration first')));
      return;
    }
    try {
      await _channel.invokeMethod('startOverlay');
      setState(() => _overlayRunning = true);
      HapticFeedback.heavyImpact();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _stopNavigation() async {
    try {
      await _channel.invokeMethod('stopOverlay');
      setState(() => _overlayRunning = false);
    } catch (_) {}
  }

  void _showAccessibilityDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F38),
        title: const Text('Accessibility Service Required',
            style: TextStyle(color: Colors.white)),
        content: const Text(
            'GazeNav needs the Accessibility Service to perform gestures '
                'on your home screen.\n\n'
                'Go to: Settings → Accessibility → Installed Services → Gaze Nav',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () { Navigator.pop(ctx); _openAccessibilitySettings(); },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan),
              child: const Text('Open Settings')),
        ],
      ),
    );
  }

  // ── Camera ──
  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first);
    _camCtrl = CameraController(front, ResolutionPreset.medium,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
    try {
      await _camCtrl!.initialize();
      if (!mounted) return;
      setState(() { _camReady = true; _statusText = 'Look straight...'; });
      _startImageStream();
    } catch (e) {
      setState(() { _statusText = 'Camera error: $e'; _statusColor = Colors.red; });
    }
  }

  void _startImageStream() {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;
    if (_camCtrl!.value.isStreamingImages) return;
    _camCtrl!.startImageStream(_onCameraFrame);
  }

  void _onCameraFrame(CameraImage image) {
    if (_processing) return;
    _processing = true;
    _processFrame(image).then((_) => _processing = false);
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) return;
      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted) return;

      if (faces.isEmpty) {
        if (!_overlayRunning) {
          setState(() { _faceDetected = false; _statusText = 'No face detected';
          _statusColor = Colors.orange; });
        }
        return;
      }

      final face = faces.first;
      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final tracked = _headTracker.processFace(face, imageSize);

      _blinkDetector.update(
          face.leftEyeOpenProbability, face.rightEyeOpenProbability);

      if (tracked) {
        final screenSize = MediaQuery.of(context).size;
        _cursorPos = _headTracker.toScreenPosition(screenSize);

        // ══════════════════════════════════════════
        // FIX: Send DEVICE PIXELS to native overlay
        // Flutter logical pixels * devicePixelRatio = device pixels
        // ══════════════════════════════════════════
        if (_overlayRunning) {
          final dpr = MediaQuery.of(context).devicePixelRatio;
          _sendCursorToNative(_cursorPos.dx * dpr, _cursorPos.dy * dpr);
        }
      }

      if (!_overlayRunning) {
        setState(() {
          _faceDetected = true;
          if (!_headTracker.isCalibrated) {
            _statusText = _headTracker.calibrationInstruction;
            _statusColor = Colors.amber;
          } else {
            _statusText = 'Calibrated — Ready!';
            _statusColor = Colors.green;
          }
          _frameCount++;
          final now = DateTime.now();
          if (now.difference(_fpsTime).inMilliseconds >= 1000) {
            _fps = _frameCount; _frameCount = 0; _fpsTime = now;
          }
        });
      }
    } catch (e) { debugPrint('Frame error: $e'); }
  }

  void _sendCursorToNative(double x, double y) {
    try { _channel.invokeMethod('updateCursor', {'x': x, 'y': y}); } catch (_) {}
  }

  void _sendBlinkToNative() {
    try { _channel.invokeMethod('doubleBlink'); } catch (_) {}
  }

  InputImage? _buildInputImage(CameraImage image) {
    final planes = image.planes;
    if (planes.isEmpty) return null;
    final bytes = Uint8List.fromList(
        planes.map((p) => p.bytes).expand((b) => b).toList());
    return InputImage.fromBytes(bytes: bytes, metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation270deg,
        format: InputImageFormat.nv21,
        bytesPerRow: planes[0].bytesPerRow));
  }

  void _onDoubleBlink() {
    HapticFeedback.heavyImpact();
    if (_overlayRunning) { _sendBlinkToNative(); return; }
    setState(() => _showBlinkFlash = true);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _showBlinkFlash = false);
    });
  }

  // ── UI ──
  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      body: Stack(
        children: [
          SafeArea(child: Column(children: [
            const SizedBox(height: 20),
            Row(children: [
              const SizedBox(width: 16),
              Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: _statusColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _statusColor.withOpacity(0.4))),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 8, height: 8,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: _statusColor)),
                    const SizedBox(width: 6),
                    Text(_statusText, style: TextStyle(color: _statusColor, fontSize: 12)),
                  ])),
              const Spacer(),
              if (_camReady) ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(width: 70, height: 95,
                      decoration: BoxDecoration(
                          border: Border.all(color: _faceDetected ? Colors.green : Colors.red, width: 2),
                          borderRadius: BorderRadius.circular(12)),
                      child: FittedBox(fit: BoxFit.cover,
                          child: SizedBox(
                              width: _camCtrl!.value.previewSize?.height ?? 480,
                              height: _camCtrl!.value.previewSize?.width ?? 640,
                              child: CameraPreview(_camCtrl!))))),
              const SizedBox(width: 16),
            ]),
            const SizedBox(height: 30),
            const Text('GazeNav', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('Head tracking navigation', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14)),
            const SizedBox(height: 30),
            // Accessibility status
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Colors.white.withOpacity(0.05),
                        border: Border.all(color: _accessibilityEnabled
                            ? Colors.green.withOpacity(0.3) : Colors.orange.withOpacity(0.3))),
                    child: Row(children: [
                      Icon(_accessibilityEnabled ? Icons.check_circle : Icons.warning_amber_rounded,
                          color: _accessibilityEnabled ? Colors.green : Colors.orange, size: 24),
                      const SizedBox(width: 12),
                      Expanded(child: Text(
                          _accessibilityEnabled ? 'Accessibility service active' : 'Accessibility service needed',
                          style: TextStyle(color: _accessibilityEnabled ? Colors.green : Colors.orange, fontSize: 14))),
                      if (!_accessibilityEnabled)
                        GestureDetector(onTap: _openAccessibilitySettings,
                            child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                                    color: Colors.orange.withOpacity(0.2)),
                                child: const Text('Enable', style: TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold)))),
                    ]))),
            const Spacer(),
            // RUN APP button
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: GestureDetector(
                    onTap: _overlayRunning ? _stopNavigation : _startNavigation,
                    child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200), height: 64,
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            gradient: LinearGradient(colors: _overlayRunning
                                ? [Colors.redAccent.shade200, Colors.red.shade400]
                                : _headTracker.isCalibrated && _accessibilityEnabled
                                ? [Colors.cyan.shade300, Colors.teal.shade400]
                                : [Colors.grey.shade600, Colors.grey.shade700]),
                            boxShadow: _headTracker.isCalibrated ? [BoxShadow(
                                color: (_overlayRunning ? Colors.redAccent : Colors.cyan).withOpacity(0.3),
                                blurRadius: 20, spreadRadius: 2)] : []),
                        child: Center(child: Text(
                            _overlayRunning ? 'STOP & RETURN' : 'RUN APP',
                            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2)))))),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _controlButton(icon: Icons.center_focus_strong, label: 'Recalibrate',
                  onTap: () { HapticFeedback.mediumImpact(); _headTracker.recalibrate(); _blinkDetector.reset(); },
                  color: Colors.amber),
              _controlButton(icon: _showDebug ? Icons.bug_report : Icons.bug_report_outlined,
                  label: 'Debug', onTap: () => setState(() => _showDebug = !_showDebug),
                  color: _showDebug ? Colors.cyan : Colors.white54),
            ]),
            const SizedBox(height: 20),
          ])),

          // Calibration targets
          if (_headTracker.calibrationPhase == CalibrationPhase.center && _faceDetected)
            _buildCalTarget(screenSize.width / 2, screenSize.height / 2, 'Look here'),
          if (_headTracker.calibrationPhase == CalibrationPhase.rangeLeft && _faceDetected)
            _buildCalTarget(40, screenSize.height / 2, 'Look LEFT'),
          if (_headTracker.calibrationPhase == CalibrationPhase.rangeRight && _faceDetected)
            _buildCalTarget(screenSize.width - 40, screenSize.height / 2, 'Look RIGHT'),
          if (_headTracker.calibrationPhase == CalibrationPhase.rangeUp && _faceDetected)
            _buildCalTarget(screenSize.width / 2, 80, 'Look UP'),
          if (_headTracker.calibrationPhase == CalibrationPhase.rangeDown && _faceDetected)
            _buildCalTarget(screenSize.width / 2, screenSize.height - 120, 'Look DOWN'),

          if (!_headTracker.isCalibrated && _faceDetected)
            Positioned(bottom: 200, left: 40, right: 40,
                child: Column(children: [
                  LinearProgressIndicator(value: _headTracker.calibrationProgress / 100.0,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber)),
                  const SizedBox(height: 8),
                  Text('${_headTracker.calibrationProgress}%',
                      style: TextStyle(color: Colors.amber.withOpacity(0.8), fontSize: 12)),
                  if (_headTracker.isRangeCalibrating)
                    Padding(padding: const EdgeInsets.only(top: 8),
                        child: GestureDetector(
                            onTap: () { _headTracker.skipRangeCalibration(); HapticFeedback.mediumImpact(); },
                            child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.white24)),
                                child: const Text('Skip (use auto-range)',
                                    style: TextStyle(color: Colors.white54, fontSize: 12))))),
                ])),

          // In-app cursor
          if (_headTracker.isCalibrated && _faceDetected && !_overlayRunning)
            Positioned(left: _cursorPos.dx - 22, top: _cursorPos.dy - 22,
                child: IgnorePointer(child: Container(width: 44, height: 44,
                    decoration: BoxDecoration(shape: BoxShape.circle,
                        color: Colors.cyan.withOpacity(0.3),
                        border: Border.all(color: Colors.cyan, width: 2.5),
                        boxShadow: [BoxShadow(color: Colors.cyan.withOpacity(0.3), blurRadius: 15, spreadRadius: 5)]),
                    child: Center(child: Container(width: 8, height: 8,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white)))))),

          if (_showBlinkFlash) Positioned.fill(child: IgnorePointer(
              child: Container(color: Colors.greenAccent.withOpacity(0.08)))),

          if (_showDebug && _headTracker.isCalibrated)
            Positioned(bottom: 120, left: 16,
                child: Container(padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Pos: (${_cursorPos.dx.toInt()}, ${_cursorPos.dy.toInt()})  dpr: ${MediaQuery.of(context).devicePixelRatio.toStringAsFixed(1)}', style: _debugStyle),
                          Text('FPS: $_fps  Overlay: $_overlayRunning', style: _debugStyle),
                          Text('Eyes: ${_blinkDetector.rawProbability.toStringAsFixed(2)} [${_blinkDetector.stateLabel}]', style: _debugStyle),
                          Text('Blinks: ${_blinkDetector.totalBlinks} Dbl: ${_blinkDetector.totalDoubleBlinks} Long: ${_blinkDetector.totalLongBlinks}',
                              style: TextStyle(color: (_blinkDetector.totalDoubleBlinks + _blinkDetector.totalLongBlinks) > 0
                                  ? Colors.greenAccent : Colors.white70, fontSize: 11, fontFamily: 'monospace', height: 1.5)),
                          if (_blinkDetector.lastTrigger.isNotEmpty)
                            Text('Last: ${_blinkDetector.lastTrigger}',
                                style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace')),
                        ]))),
        ],
      ),
    );
  }

  Widget _buildCalTarget(double x, double y, String label) {
    return Positioned(left: x - 35, top: y - 50,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 70, height: 70,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  border: Border.all(color: Colors.amber, width: 3),
                  color: Colors.amber.withOpacity(0.1),
                  boxShadow: [BoxShadow(color: Colors.amber.withOpacity(0.3), blurRadius: 20, spreadRadius: 5)]),
              child: const Center(child: Icon(Icons.remove_red_eye, color: Colors.amber, size: 32))),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.bold)),
        ]));
  }

  TextStyle get _debugStyle => const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace', height: 1.5);

  Widget _controlButton({required IconData icon, required String label,
    required VoidCallback onTap, Color color = Colors.white}) {
    return GestureDetector(onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 50, height: 50,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: color.withOpacity(0.15), border: Border.all(color: color.withOpacity(0.5))),
              child: Icon(icon, color: color, size: 24)),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color.withOpacity(0.8), fontSize: 11)),
        ]));
  }
}