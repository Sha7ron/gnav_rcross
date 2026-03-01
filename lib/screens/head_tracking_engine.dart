/// ===========================================================================
/// GazeNav v5 - HEAD TRACKING ENGINE
/// ===========================================================================
///
/// Strategy: Track the MIDPOINT between both eye landmarks as a stable
/// facial anchor point. As the head moves, this point shifts in camera
/// space. Map that shift to screen cursor movement.
///
/// Also fuses nose tip position for enhanced sensitivity (nose protrudes
/// from the face, so it amplifies head tilt by ~40% more pixel movement).
///
/// This is fundamentally different from v1-v4 which tried to track
/// WHERE THE EYES ARE LOOKING (iris direction). Here we track
/// WHERE THE HEAD IS POINTING, which produces 20-50px camera shifts
/// vs the 2-5px we got from eye landmarks.
///
/// ===========================================================================

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class HeadTrackingEngine {
  // ── Calibration ──
  ui.Offset? _baselineMidEye;   // "Center" position in camera space
  ui.Offset? _baselineNose;
  int _baselineFrames = 0;
  double _baselineMidX = 0, _baselineMidY = 0;
  double _baselineNoseX = 0, _baselineNoseY = 0;
  bool _calibrated = false;
  static const int _calibrationFrameCount = 30;

  // ── Image dimensions (for normalization) ──
  double _imgW = 640;
  double _imgH = 480;

  // ── Smoothing (double EMA for extra stability) ──
  double _smoothX = 0, _smoothY = 0;
  double _smooth2X = 0, _smooth2Y = 0;
  bool _smoothInit = false;
  static const double _alpha1 = 0.25; // First pass EMA
  static const double _alpha2 = 0.35; // Second pass EMA

  // ── Sensitivity (how much head movement maps to screen movement) ──
  // These are tuned so ~15° head tilt = full screen edge
  double sensitivityX = 2.8;
  double sensitivityY = 2.5;

  // ── Fusion weights ──
  static const double _eyeMidWeight = 0.55; // Eye midpoint contribution
  static const double _noseWeight = 0.45;   // Nose tip contribution

  // ── Dead zone (ignore micro-movements) ──
  static const double _deadZone = 0.015;

  // ── Output: normalized position [-1, 1] ──
  double _outX = 0, _outY = 0;

  // Getters
  double get normalizedX => _outX;
  double get normalizedY => _outY;
  bool get isCalibrated => _calibrated;
  int get calibrationProgress =>
      _calibrated ? 100 : ((_baselineFrames / _calibrationFrameCount) * 100).round();

  /// ══════════════════════════════════════════════════════════════
  /// MAIN: Process a detected face → update cursor position
  /// ══════════════════════════════════════════════════════════════
  bool processFace(Face face, ui.Size imageSize) {
    _imgW = imageSize.width;
    _imgH = imageSize.height;

    // ── Get eye landmarks ──
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    final noseTip = face.landmarks[FaceLandmarkType.noseBase];

    if (leftEye == null || rightEye == null) return false;

    // ── Compute midpoint between eyes (the user's "red dot") ──
    final midEyeX = (leftEye.position.x + rightEye.position.x) / 2.0;
    final midEyeY = (leftEye.position.y + rightEye.position.y) / 2.0;
    final midEye = ui.Offset(midEyeX, midEyeY);

    // ── Nose tip (enhanced sensitivity point) ──
    ui.Offset nose;
    if (noseTip != null) {
      nose = ui.Offset(
        noseTip.position.x.toDouble(),
        noseTip.position.y.toDouble(),
      );
    } else {
      // Fallback: estimate nose as slightly below eye midpoint
      nose = ui.Offset(midEyeX, midEyeY + (_imgH * 0.05));
    }

    // ── Calibration phase: establish baseline ──
    if (!_calibrated) {
      _baselineMidX += midEyeX;
      _baselineMidY += midEyeY;
      _baselineNoseX += nose.dx;
      _baselineNoseY += nose.dy;
      _baselineFrames++;

      if (_baselineFrames >= _calibrationFrameCount) {
        _baselineMidEye = ui.Offset(
          _baselineMidX / _baselineFrames,
          _baselineMidY / _baselineFrames,
        );
        _baselineNose = ui.Offset(
          _baselineNoseX / _baselineFrames,
          _baselineNoseY / _baselineFrames,
        );
        _calibrated = true;
        debugPrint('HeadTracking: Calibrated! '
            'MidEye=(${_baselineMidEye!.dx.toInt()}, ${_baselineMidEye!.dy.toInt()}) '
            'Nose=(${_baselineNose!.dx.toInt()}, ${_baselineNose!.dy.toInt()})');
      }
      return false;
    }

    // ── Compute deltas from baseline ──
    // Normalize by image dimensions so it's device-independent
    final dMidX = (midEyeX - _baselineMidEye!.dx) / _imgW;
    final dMidY = (midEyeY - _baselineMidEye!.dy) / _imgH;
    final dNoseX = (nose.dx - _baselineNose!.dx) / _imgW;
    final dNoseY = (nose.dy - _baselineNose!.dy) / _imgH;

    // ── Fuse eye midpoint + nose tip ──
    double rawX = dMidX * _eyeMidWeight + dNoseX * _noseWeight;
    double rawY = dMidY * _eyeMidWeight + dNoseY * _noseWeight;

    // ── Apply sensitivity ──
    rawX *= sensitivityX;
    rawY *= sensitivityY;

    // ── Dead zone: ignore tiny movements ──
    if (rawX.abs() < _deadZone) rawX = 0;
    if (rawY.abs() < _deadZone) rawY = 0;

    // ── Front camera mirror: horizontal flip ──
    // Head moves LEFT → midpoint moves RIGHT in camera → cursor should go LEFT
    rawX = -rawX;
    // Vertical is natural: head tilts down → midpoint moves down → cursor goes down
    // (no flip needed)

    // ── Double EMA smoothing ──
    if (!_smoothInit) {
      _smoothX = rawX;
      _smoothY = rawY;
      _smooth2X = rawX;
      _smooth2Y = rawY;
      _smoothInit = true;
    } else {
      _smoothX += (rawX - _smoothX) * _alpha1;
      _smoothY += (rawY - _smoothY) * _alpha1;
      _smooth2X += (_smoothX - _smooth2X) * _alpha2;
      _smooth2Y += (_smoothY - _smooth2Y) * _alpha2;
    }

    // ── Clamp to [-1, 1] ──
    _outX = _smooth2X.clamp(-1.0, 1.0);
    _outY = _smooth2Y.clamp(-1.0, 1.0);

    return true;
  }

  /// Convert normalized [-1,1] to screen pixel coordinates
  ui.Offset toScreenPosition(ui.Size screenSize) {
    // Map [-1, 1] to [0, screenWidth/Height]
    final sx = ((1.0 + _outX) / 2.0) * screenSize.width;
    final sy = ((1.0 + _outY) / 2.0) * screenSize.height;
    return ui.Offset(
      sx.clamp(0, screenSize.width),
      sy.clamp(0, screenSize.height),
    );
  }

  /// Reset calibration (user can recalibrate)
  void recalibrate() {
    _baselineMidEye = null;
    _baselineNose = null;
    _baselineFrames = 0;
    _baselineMidX = 0;
    _baselineMidY = 0;
    _baselineNoseX = 0;
    _baselineNoseY = 0;
    _calibrated = false;
    _smoothInit = false;
    _smoothX = 0;
    _smoothY = 0;
    _smooth2X = 0;
    _smooth2Y = 0;
    _outX = 0;
    _outY = 0;
    debugPrint('HeadTracking: Recalibrating...');
  }
}