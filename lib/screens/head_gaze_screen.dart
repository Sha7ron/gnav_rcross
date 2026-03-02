/// ===========================================================================
/// GazeNav v5.2 - HEAD TRACKING + DOUBLE-BLINK ACTIONS + DWELL CANCEL
/// ===========================================================================
///
/// Flow:
///   1. Cursor hovers over a target (app card)
///   2. Double-blink → confirmation dialog appears
///   3. Dialog shows "Opening [App]" + progress bar (2.5s timeout)
///   4. Cancel: hold gaze on (X) button for 2.5s → cancel action
///   5. If timeout elapses without cancel → confirm and execute
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

class GazeTarget {
  final String id;
  final String label;
  final IconData icon;
  final Rect bounds;
  final VoidCallback? onActivate;

  GazeTarget({
    required this.id,
    required this.label,
    required this.icon,
    required this.bounds,
    this.onActivate,
  });

  bool containsPoint(Offset point) => bounds.contains(point);
}

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

  // ── Blink feedback ──
  bool _showBlinkFlash = false;

  // ── Debug ──
  bool _showDebug = true; // Default ON so we can see blink values

  // ══════════════════════════════════════════
  // ACTION SYSTEM
  // ══════════════════════════════════════════
  List<GazeTarget> _targets = [];
  GazeTarget? _hoveredTarget;
  bool _dialogVisible = false;
  GazeTarget? _pendingTarget;
  Timer? _confirmTimer;
  double _confirmProgress = 0;
  Timer? _progressTimer;
  Rect? _cancelButtonBounds;
  bool _hoveringCancel = false;

  // ── Dwell-to-cancel ──
  DateTime? _cancelDwellStart;
  double _cancelDwellProgress = 0;
  static const int _cancelDwellMs = 2500; // 2.5 seconds to cancel

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _buildTargets();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camCtrl?.stopImageStream();
    _camCtrl?.dispose();
    _faceDetector.close();
    _confirmTimer?.cancel();
    _progressTimer?.cancel();
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
  // TARGETS
  // ══════════════════════════════════════════════════

  void _buildTargets() {
    final size = MediaQuery.of(context).size;
    final cardW = size.width - 48;
    const cardH = 100.0;
    const startY = 180.0;

    _targets = [
      GazeTarget(
        id: 'road_crossing',
        label: 'Road Crossing',
        icon: Icons.directions_walk,
        bounds: Rect.fromLTWH(24, startY, cardW, cardH),
        onActivate: () {
          debugPrint('ACTION: Opening Road Crossing');
        },
      ),
      GazeTarget(
        id: 'settings',
        label: 'Settings',
        icon: Icons.settings,
        bounds: Rect.fromLTWH(24, startY + cardH + 16, cardW, cardH),
        onActivate: () => debugPrint('ACTION: Opening Settings'),
      ),
      GazeTarget(
        id: 'contacts',
        label: 'Contacts',
        icon: Icons.contacts,
        bounds: Rect.fromLTWH(24, startY + (cardH + 16) * 2, cardW, cardH),
        onActivate: () => debugPrint('ACTION: Opening Contacts'),
      ),
      GazeTarget(
        id: 'messages',
        label: 'Messages',
        icon: Icons.message,
        bounds: Rect.fromLTWH(24, startY + (cardH + 16) * 3, cardW, cardH),
        onActivate: () => debugPrint('ACTION: Opening Messages'),
      ),
    ];
  }

  // ══════════════════════════════════════════════════
  // CAMERA
  // ══════════════════════════════════════════════════

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _camCtrl = CameraController(
      front,
      ResolutionPreset.medium,
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
  // FRAME PIPELINE
  // ══════════════════════════════════════════════════

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
        setState(() {
          _faceDetected = false;
          _statusText = 'No face detected';
          _statusColor = Colors.orange;
        });
        return;
      }

      final face = faces.first;
      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final tracked = _headTracker.processFace(face, imageSize);

      _blinkDetector.update(
        face.leftEyeOpenProbability,
        face.rightEyeOpenProbability,
      );

      setState(() {
        _faceDetected = true;

        if (!_headTracker.isCalibrated) {
          _statusText = _headTracker.calibrationInstruction;
          _statusColor = Colors.amber;
        } else if (tracked) {
          final screenSize = MediaQuery.of(context).size;
          _cursorPos = _headTracker.toScreenPosition(screenSize);
          _statusText = 'Tracking';
          _statusColor = Colors.green;
          _updateHoverState();
          _updateCancelDwell();
        }

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
    final planes = image.planes;
    if (planes.isEmpty) return null;

    final bytes = Uint8List.fromList(
      planes.map((p) => p.bytes).expand((b) => b).toList(),
    );

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation270deg,
      format: InputImageFormat.nv21,
      bytesPerRow: planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  // ══════════════════════════════════════════════════
  // HOVER + DWELL DETECTION
  // ══════════════════════════════════════════════════

  void _updateHoverState() {
    if (_dialogVisible && _cancelButtonBounds != null) {
      final expanded = _cancelButtonBounds!.inflate(30);
      _hoveringCancel = expanded.contains(_cursorPos);
    } else {
      _hoveringCancel = false;
    }

    if (!_dialogVisible) {
      GazeTarget? found;
      for (final t in _targets) {
        if (t.containsPoint(_cursorPos)) {
          found = t;
          break;
        }
      }
      _hoveredTarget = found;
    }
  }

  void _updateCancelDwell() {
    if (!_dialogVisible || !_hoveringCancel) {
      // Not on cancel button - reset dwell
      _cancelDwellStart = null;
      _cancelDwellProgress = 0;
      return;
    }

    // Hovering cancel button - accumulate dwell time
    if (_cancelDwellStart == null) {
      _cancelDwellStart = DateTime.now();
      _cancelDwellProgress = 0;
    } else {
      final elapsed = DateTime.now().difference(_cancelDwellStart!).inMilliseconds;
      _cancelDwellProgress = (elapsed / _cancelDwellMs).clamp(0.0, 1.0);

      if (_cancelDwellProgress >= 1.0) {
        // Dwell complete - CANCEL!
        _cancelAction();
      }
    }
  }

  // ══════════════════════════════════════════════════
  // DOUBLE BLINK → OPEN ACTION
  // ══════════════════════════════════════════════════

  void _onDoubleBlink() {
    HapticFeedback.heavyImpact();

    // If dialog is visible, double-blink does nothing
    // (cancel is done by dwelling on X)
    if (_dialogVisible) return;

    // Hovering a target → show confirmation
    if (_hoveredTarget != null) {
      _showConfirmation(_hoveredTarget!);
      return;
    }

    // Not on target → just flash
    setState(() => _showBlinkFlash = true);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _showBlinkFlash = false);
    });
  }

  // ══════════════════════════════════════════════════
  // CONFIRMATION DIALOG
  // ══════════════════════════════════════════════════

  void _showConfirmation(GazeTarget target) {
    setState(() {
      _dialogVisible = true;
      _pendingTarget = target;
      _confirmProgress = 0;
      _showBlinkFlash = true;
      _cancelDwellStart = null;
      _cancelDwellProgress = 0;
    });

    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _showBlinkFlash = false);
    });

    HapticFeedback.mediumImpact();

    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() {
        _confirmProgress += 50.0 / 2500.0;
        if (_confirmProgress >= 1.0) {
          _confirmProgress = 1.0;
          timer.cancel();
        }
      });
    });

    _confirmTimer?.cancel();
    _confirmTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _dialogVisible) {
        _executeAction();
      }
    });
  }

  void _cancelAction() {
    HapticFeedback.lightImpact();
    _confirmTimer?.cancel();
    _progressTimer?.cancel();
    setState(() {
      _dialogVisible = false;
      _pendingTarget = null;
      _confirmProgress = 0;
      _hoveringCancel = false;
      _cancelDwellStart = null;
      _cancelDwellProgress = 0;
    });
    debugPrint('ACTION: Cancelled by dwell');
  }

  void _executeAction() {
    _confirmTimer?.cancel();
    _progressTimer?.cancel();
    final target = _pendingTarget;
    setState(() {
      _dialogVisible = false;
      _pendingTarget = null;
      _confirmProgress = 0;
      _cancelDwellStart = null;
      _cancelDwellProgress = 0;
    });

    HapticFeedback.heavyImpact();
    debugPrint('ACTION: Executing ${target?.label}');

    setState(() => _showBlinkFlash = true);
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _showBlinkFlash = false);
      target?.onActivate?.call();
    });
  }

  // ══════════════════════════════════════════════════
  // BUILD UI
  // ══════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      body: Stack(
        children: [
          // ── APP CONTENT ──
          Column(
            children: [
              const SizedBox(height: 100),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Icon(Icons.apps, color: Colors.white38, size: 20),
                    SizedBox(width: 8),
                    Text('Apps', style: TextStyle(color: Colors.white54, fontSize: 16)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: _targets.map((t) {
                    final isHovered = _hoveredTarget?.id == t.id && !_dialogVisible;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _buildAppCard(t, isHovered),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),

          // ── CAMERA PREVIEW ──
          if (_camReady)
            Positioned(
              right: 12,
              top: 50,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 80,
                  height: 110,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _faceDetected ? Colors.green : Colors.red,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _camCtrl!.value.previewSize?.height ?? 480,
                      height: _camCtrl!.value.previewSize?.width ?? 640,
                      child: CameraPreview(_camCtrl!),
                    ),
                  ),
                ),
              ),
            ),

          // ── STATUS ──
          Positioned(
            top: 50,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _statusColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _statusColor.withOpacity(0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _statusColor),
                  ),
                  const SizedBox(width: 6),
                  Text(_statusText, style: TextStyle(color: _statusColor, fontSize: 12)),
                ],
              ),
            ),
          ),

          // ── CALIBRATION ──
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
            Positioned(
              bottom: 160, left: 40, right: 40,
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: _headTracker.calibrationProgress / 100.0,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
                  ),
                  const SizedBox(height: 8),
                  Text('${_headTracker.calibrationProgress}%',
                      style: TextStyle(color: Colors.amber.withOpacity(0.8), fontSize: 12)),
                  if (_headTracker.isRangeCalibrating)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: GestureDetector(
                        onTap: () {
                          _headTracker.skipRangeCalibration();
                          HapticFeedback.mediumImpact();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text('Skip (use auto-range)',
                              style: TextStyle(color: Colors.white54, fontSize: 12)),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // ── CONFIRMATION DIALOG ──
          if (_dialogVisible && _pendingTarget != null)
            _buildConfirmationDialog(),

          // ── BLINK FLASH ──
          if (_showBlinkFlash)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(color: Colors.greenAccent.withOpacity(0.08)),
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
                    color: (_hoveringCancel
                        ? Colors.redAccent
                        : _hoveredTarget != null && !_dialogVisible
                        ? Colors.greenAccent
                        : Colors.cyan)
                        .withOpacity(0.4),
                    border: Border.all(
                      color: _hoveringCancel
                          ? Colors.redAccent
                          : _hoveredTarget != null && !_dialogVisible
                          ? Colors.greenAccent
                          : Colors.cyan,
                      width: 2.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (_hoveringCancel ? Colors.redAccent : Colors.cyan)
                            .withOpacity(0.3),
                        blurRadius: 15, spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 8, height: 8,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ── DEBUG ──
          if (_showDebug && _headTracker.isCalibrated)
            Positioned(
              bottom: 100,
              left: 16,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Pos: (${_cursorPos.dx.toInt()}, ${_cursorPos.dy.toInt()})',
                        style: _debugStyle),
                    Text('FPS: $_fps', style: _debugStyle),
                    Text('Hover: ${_hoveredTarget?.label ?? "none"}',
                        style: _debugStyle),
                    Text(
                      'Eyes raw: ${_blinkDetector.rawProbability.toStringAsFixed(2)} '
                          'smooth: ${_blinkDetector.eyeOpenProbability.toStringAsFixed(2)} '
                          '[${_blinkDetector.stateLabel}]',
                      style: _debugStyle,
                    ),
                    Text(
                      'Blinks: ${_blinkDetector.totalBlinks} '
                          'Double: ${_blinkDetector.totalDoubleBlinks}',
                      style: TextStyle(
                        color: _blinkDetector.totalDoubleBlinks > 0
                            ? Colors.greenAccent
                            : Colors.white70,
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── CONTROLS ──
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _controlButton(
                  icon: Icons.arrow_back, label: 'Back',
                  onTap: () => Navigator.pop(context),
                ),
                _controlButton(
                  icon: Icons.center_focus_strong, label: 'Recalibrate',
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _headTracker.recalibrate();
                    _blinkDetector.reset();
                    _cancelAction();
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

  // ── APP CARD ──
  Widget _buildAppCard(GazeTarget target, bool isHovered) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 100,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isHovered ? Colors.cyan.withOpacity(0.15) : Colors.white.withOpacity(0.05),
        border: Border.all(
          color: isHovered ? Colors.cyan.withOpacity(0.6) : Colors.white12,
          width: isHovered ? 2 : 1,
        ),
        boxShadow: isHovered
            ? [BoxShadow(color: Colors.cyan.withOpacity(0.2), blurRadius: 15, spreadRadius: 2)]
            : [],
      ),
      child: Row(
        children: [
          const SizedBox(width: 20),
          Container(
            width: 50, height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isHovered ? Colors.cyan.withOpacity(0.2) : Colors.white.withOpacity(0.08),
            ),
            child: Icon(target.icon,
                color: isHovered ? Colors.cyan : Colors.white54, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(target.label,
                style: TextStyle(
                  color: isHovered ? Colors.white : Colors.white70,
                  fontSize: 18,
                  fontWeight: isHovered ? FontWeight.w600 : FontWeight.normal,
                )),
          ),
          if (isHovered)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text('BLINK ×2',
                  style: TextStyle(
                    color: Colors.cyan.withOpacity(0.7),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  )),
            ),
          if (!isHovered) const SizedBox(width: 16),
        ],
      ),
    );
  }

  // ── CONFIRMATION DIALOG ──
  Widget _buildConfirmationDialog() {
    final screenSize = MediaQuery.of(context).size;
    const dialogW = 280.0;
    const dialogH = 160.0;
    final dialogX = (screenSize.width - dialogW) / 2;
    final dialogY = (screenSize.height - dialogH) / 2 - 40;

    final cancelX = dialogX + dialogW - 20;
    final cancelY = dialogY - 20;
    const cancelSize = 56.0; // Bigger for easier targeting

    _cancelButtonBounds = Rect.fromCenter(
      center: Offset(cancelX, cancelY),
      width: cancelSize,
      height: cancelSize,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: Container(color: Colors.black.withOpacity(0.5)),
        ),

        // Dialog box
        Positioned(
          left: dialogX,
          top: dialogY,
          child: Container(
            width: dialogW,
            height: dialogH,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1F38),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
              boxShadow: [
                BoxShadow(
                  color: Colors.greenAccent.withOpacity(0.15),
                  blurRadius: 30, spreadRadius: 5,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_pendingTarget!.icon, color: Colors.greenAccent, size: 36),
                const SizedBox(height: 12),
                Text('Opening ${_pendingTarget!.label}',
                    style: const TextStyle(
                      color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _confirmProgress,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                      minHeight: 6,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${((1 - _confirmProgress) * 2.5).toStringAsFixed(1)}s',
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
                ),
              ],
            ),
          ),
        ),

        // Cancel (X) button with DWELL progress ring
        Positioned(
          left: cancelX - cancelSize / 2,
          top: cancelY - cancelSize / 2,
          child: SizedBox(
            width: cancelSize,
            height: cancelSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Dwell progress ring
                if (_hoveringCancel && _cancelDwellProgress > 0)
                  SizedBox(
                    width: cancelSize,
                    height: cancelSize,
                    child: CircularProgressIndicator(
                      value: _cancelDwellProgress,
                      strokeWidth: 3,
                      color: Colors.redAccent,
                      backgroundColor: Colors.redAccent.withOpacity(0.15),
                    ),
                  ),
                // Button
                Container(
                  width: cancelSize - 10,
                  height: cancelSize - 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _hoveringCancel
                        ? Colors.redAccent.withOpacity(0.3)
                        : const Color(0xFF2A2F48),
                    border: Border.all(
                      color: _hoveringCancel ? Colors.redAccent : Colors.white24,
                      width: _hoveringCancel ? 2.5 : 1.5,
                    ),
                    boxShadow: _hoveringCancel
                        ? [BoxShadow(color: Colors.redAccent.withOpacity(0.3),
                        blurRadius: 12, spreadRadius: 3)]
                        : [],
                  ),
                  child: Icon(Icons.close,
                      color: _hoveringCancel ? Colors.redAccent : Colors.white54,
                      size: _hoveringCancel ? 26 : 22),
                ),
              ],
            ),
          ),
        ),

        // Dwell hint when hovering cancel
        if (_hoveringCancel)
          Positioned(
            left: cancelX + cancelSize / 2 + 4,
            top: cancelY - 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'HOLD TO CANCEL ${(_cancelDwellProgress * 100).toInt()}%',
                style: const TextStyle(
                  color: Colors.redAccent, fontSize: 9,
                  fontWeight: FontWeight.bold, letterSpacing: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── HELPERS ──
  Widget _buildCalTarget(double x, double y, String label) {
    return Positioned(
      left: x - 35, top: y - 50,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 70, height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.amber, width: 3),
              color: Colors.amber.withOpacity(0.1),
              boxShadow: [BoxShadow(color: Colors.amber.withOpacity(0.3), blurRadius: 20, spreadRadius: 5)],
            ),
            child: const Center(child: Icon(Icons.remove_red_eye, color: Colors.amber, size: 32)),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  TextStyle get _debugStyle => const TextStyle(
      color: Colors.white70, fontSize: 11, fontFamily: 'monospace', height: 1.5);

  Widget _controlButton({
    required IconData icon, required String label,
    required VoidCallback onTap, Color color = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50, height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.15),
              border: Border.all(color: color.withOpacity(0.5)),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color.withOpacity(0.8), fontSize: 11)),
        ],
      ),
    );
  }
}