/// ===========================================================================
/// GazeNav v5.1 - HEAD TRACKING ENGINE (Adaptive Range)
/// ===========================================================================
///
/// Strategy: Track the MIDPOINT between both eye landmarks as a stable
/// facial anchor point. As the head moves, this point shifts in camera
/// space. Map that shift to screen cursor movement.
///
/// v5.1 IMPROVEMENT: Adaptive range calibration
/// ─────────────────────────────────────────────
/// After center calibration, a RANGE CALIBRATION phase asks the user
/// to look at 4 screen edges. The engine measures the actual displacement
/// at each edge and calculates per-axis sensitivity so that the user's
/// comfortable head tilt range maps exactly to the full screen.
///
/// If range calibration is skipped, an AUTO-RANGING system gradually
/// learns the user's range over time and adjusts dynamically.
///
/// ===========================================================================

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

enum CalibrationPhase {
  center,       // Look at center (30 frames)
  rangeLeft,    // Look at left edge
  rangeRight,   // Look at right edge
  rangeUp,      // Look at top edge
  rangeDown,    // Look at bottom edge
  done,         // Calibration complete
}

class HeadTrackingEngine {
  // ── Calibration ──
  CalibrationPhase _calPhase = CalibrationPhase.center;
  int _calFrames = 0;
  static const int _centerCalFrames = 30;
  static const int _rangeCalFrames = 20;  // Frames per edge direction

  // Baseline (center position in camera space)
  double _baseMidX = 0, _baseMidY = 0;
  double _baseNoseX = 0, _baseNoseY = 0;

  // Range calibration: measured deltas at each edge
  double _rangeLeftX = 0, _rangeRightX = 0;
  double _rangeUpY = 0, _rangeDownY = 0;
  double _rangeTempSum = 0;
  int _rangeTempCount = 0;

  // ── Image dimensions ──
  double _imgW = 640;
  double _imgH = 480;

  // ── Adaptive sensitivity ──
  // These get set by range calibration OR auto-ranging
  double _sensX = 4.5;  // Default higher than v5 (was 2.8)
  double _sensY = 4.0;  // Default higher than v5 (was 2.5)

  // ── Auto-ranging (fallback if range calibration skipped) ──
  double _observedMinX = 0, _observedMaxX = 0;
  double _observedMinY = 0, _observedMaxY = 0;
  int _autoRangeFrames = 0;
  bool _autoRangeActive = false;
  static const int _autoRangeWarmup = 60;  // Frames before auto-range kicks in
  static const double _autoRangeDecay = 0.998; // Slowly shrink range (forgets old extremes)
  static const double _autoRangeMinRange = 0.05; // Minimum observed range before adjusting

  // ── Smoothing (double EMA) ──
  double _smoothX = 0, _smoothY = 0;
  double _smooth2X = 0, _smooth2Y = 0;
  bool _smoothInit = false;
  static const double _alpha1 = 0.22;
  static const double _alpha2 = 0.30;

  // ── Fusion weights ──
  static const double _eyeMidWeight = 0.55;
  static const double _noseWeight = 0.45;

  // ── Dead zone ──
  static const double _deadZone = 0.012;

  // ── Edge acceleration: boost when near edges for easier edge reach ──
  static const double _edgeBoostThreshold = 0.6;  // Start boosting past 60%
  static const double _edgeBoostFactor = 1.5;      // 50% extra push at edges

  // ── Output ──
  double _outX = 0, _outY = 0;

  // ── Public getters ──
  double get normalizedX => _outX;
  double get normalizedY => _outY;
  bool get isCalibrated => _calPhase == CalibrationPhase.done;
  bool get isRangeCalibrating =>
      _calPhase != CalibrationPhase.center && _calPhase != CalibrationPhase.done;
  CalibrationPhase get calibrationPhase => _calPhase;
  double get sensitivityX => _sensX;
  double get sensitivityY => _sensY;

  // Calibration data getters (for native tracker)
  double get baselineMidX => _baseMidX;
  double get baselineMidY => _baseMidY;
  double get baselineNoseX => _baseNoseX;
  double get baselineNoseY => _baseNoseY;
  double get imageWidth => _imgW;
  double get imageHeight => _imgH;

  int get calibrationProgress {
    switch (_calPhase) {
      case CalibrationPhase.center:
        return ((_calFrames / _centerCalFrames) * 20).round(); // 0-20%
      case CalibrationPhase.rangeLeft:
        return 20 + ((_calFrames / _rangeCalFrames) * 20).round(); // 20-40%
      case CalibrationPhase.rangeRight:
        return 40 + ((_calFrames / _rangeCalFrames) * 20).round(); // 40-60%
      case CalibrationPhase.rangeUp:
        return 60 + ((_calFrames / _rangeCalFrames) * 20).round(); // 60-80%
      case CalibrationPhase.rangeDown:
        return 80 + ((_calFrames / _rangeCalFrames) * 20).round(); // 80-100%
      case CalibrationPhase.done:
        return 100;
    }
  }

  String get calibrationInstruction {
    switch (_calPhase) {
      case CalibrationPhase.center:
        return 'Look at the CENTER of the screen';
      case CalibrationPhase.rangeLeft:
        return 'Now look at the LEFT edge';
      case CalibrationPhase.rangeRight:
        return 'Now look at the RIGHT edge';
      case CalibrationPhase.rangeUp:
        return 'Now look at the TOP edge';
      case CalibrationPhase.rangeDown:
        return 'Now look at the BOTTOM edge';
      case CalibrationPhase.done:
        return 'Calibration complete!';
    }
  }

  /// ══════════════════════════════════════════════════════════════
  /// Skip range calibration (use auto-ranging instead)
  /// ══════════════════════════════════════════════════════════════
  void skipRangeCalibration() {
    if (_calPhase != CalibrationPhase.center &&
        _calPhase != CalibrationPhase.done) {
      _calPhase = CalibrationPhase.done;
      _autoRangeActive = true;
      // Use boosted defaults
      _sensX = 5.5;
      _sensY = 5.0;
      debugPrint('HeadTracking: Range cal skipped, using auto-range with '
          'sensX=$_sensX sensY=$_sensY');
    }
  }

  /// ══════════════════════════════════════════════════════════════
  /// MAIN: Process a detected face → update cursor position
  /// ══════════════════════════════════════════════════════════════
  bool processFace(Face face, ui.Size imageSize) {
    _imgW = imageSize.width;
    _imgH = imageSize.height;

    // ── Get landmarks ──
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    final noseTip = face.landmarks[FaceLandmarkType.noseBase];

    if (leftEye == null || rightEye == null) return false;

    // ── Compute midpoint between eyes ──
    final midX = (leftEye.position.x + rightEye.position.x) / 2.0;
    final midY = (leftEye.position.y + rightEye.position.y) / 2.0;

    // ── Nose tip ──
    final noseX = noseTip?.position.x.toDouble() ?? midX;
    final noseY = noseTip?.position.y.toDouble() ?? (midY + _imgH * 0.05);

    // ═══════════════════════════════════════
    // CALIBRATION PHASES
    // ═══════════════════════════════════════

    if (_calPhase == CalibrationPhase.center) {
      _baseMidX += midX;
      _baseMidY += midY;
      _baseNoseX += noseX;
      _baseNoseY += noseY;
      _calFrames++;

      if (_calFrames >= _centerCalFrames) {
        _baseMidX /= _calFrames;
        _baseMidY /= _calFrames;
        _baseNoseX /= _calFrames;
        _baseNoseY /= _calFrames;
        debugPrint('HeadTracking: Center calibrated at '
            'mid=(${_baseMidX.toInt()}, ${_baseMidY.toInt()}) '
            'nose=(${_baseNoseX.toInt()}, ${_baseNoseY.toInt()})');

        // Move to range calibration
        _calPhase = CalibrationPhase.rangeLeft;
        _calFrames = 0;
        _rangeTempSum = 0;
        _rangeTempCount = 0;
      }
      return false;
    }

    // ── Compute current delta from baseline (always needed) ──
    final dMidX = (midX - _baseMidX) / _imgW;
    final dMidY = (midY - _baseMidY) / _imgH;
    final dNoseX = (noseX - _baseNoseX) / _imgW;
    final dNoseY = (noseY - _baseNoseY) / _imgH;

    final fusedX = dMidX * _eyeMidWeight + dNoseX * _noseWeight;
    final fusedY = dMidY * _eyeMidWeight + dNoseY * _noseWeight;

    // ── Range calibration phases ──
    if (_calPhase != CalibrationPhase.done) {
      _calFrames++;

      switch (_calPhase) {
        case CalibrationPhase.rangeLeft:
          _rangeTempSum += fusedX;
          _rangeTempCount++;
          if (_calFrames >= _rangeCalFrames) {
            _rangeLeftX = _rangeTempSum / _rangeTempCount;
            debugPrint('HeadTracking: Left range: $_rangeLeftX');
            _calPhase = CalibrationPhase.rangeRight;
            _calFrames = 0;
            _rangeTempSum = 0;
            _rangeTempCount = 0;
          }
          break;
        case CalibrationPhase.rangeRight:
          _rangeTempSum += fusedX;
          _rangeTempCount++;
          if (_calFrames >= _rangeCalFrames) {
            _rangeRightX = _rangeTempSum / _rangeTempCount;
            debugPrint('HeadTracking: Right range: $_rangeRightX');
            _calPhase = CalibrationPhase.rangeUp;
            _calFrames = 0;
            _rangeTempSum = 0;
            _rangeTempCount = 0;
          }
          break;
        case CalibrationPhase.rangeUp:
          _rangeTempSum += fusedY;
          _rangeTempCount++;
          if (_calFrames >= _rangeCalFrames) {
            _rangeUpY = _rangeTempSum / _rangeTempCount;
            debugPrint('HeadTracking: Up range: $_rangeUpY');
            _calPhase = CalibrationPhase.rangeDown;
            _calFrames = 0;
            _rangeTempSum = 0;
            _rangeTempCount = 0;
          }
          break;
        case CalibrationPhase.rangeDown:
          _rangeTempSum += fusedY;
          _rangeTempCount++;
          if (_calFrames >= _rangeCalFrames) {
            _rangeDownY = _rangeTempSum / _rangeTempCount;
            debugPrint('HeadTracking: Down range: $_rangeDownY');
            _calculateRangeSensitivity();
            _calPhase = CalibrationPhase.done;
          }
          break;
        default:
          break;
      }
      return false;
    }

    // ═══════════════════════════════════════
    // TRACKING (post-calibration)
    // ═══════════════════════════════════════

    // ── Apply sensitivity ──
    double rawX = fusedX * _sensX;
    double rawY = fusedY * _sensY;

    // ── Dead zone ──
    if (rawX.abs() < _deadZone) rawX = 0;
    if (rawY.abs() < _deadZone) rawY = 0;

    // ── Front camera mirror ──
    rawX = -rawX;

    // ── Edge acceleration: push harder near edges ──
    rawX = _applyEdgeBoost(rawX);
    rawY = _applyEdgeBoost(rawY);

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

    // ── Clamp ──
    _outX = _smooth2X.clamp(-1.0, 1.0);
    _outY = _smooth2Y.clamp(-1.0, 1.0);

    // ── Auto-ranging (if range calibration was skipped) ──
    if (_autoRangeActive) {
      _updateAutoRange(_outX, _outY);
    }

    return true;
  }

  /// ══════════════════════════════════════════════════════════════
  /// Calculate sensitivity from range calibration data
  /// ══════════════════════════════════════════════════════════════
  void _calculateRangeSensitivity() {
    // The range values are the raw fused deltas when looking at edges.
    // We want those deltas * sensitivity = ±0.9 (not ±1.0, leave a small margin)

    final xRange = (_rangeRightX - _rangeLeftX).abs();
    final yRange = (_rangeDownY - _rangeUpY).abs();

    if (xRange > 0.01) {
      // We want: halfRange * sensX = 0.9
      _sensX = (1.8 / xRange).clamp(3.0, 15.0);
    } else {
      _sensX = 5.5; // Fallback
    }

    if (yRange > 0.01) {
      _sensY = (1.8 / yRange).clamp(3.0, 15.0);
    } else {
      _sensY = 5.0; // Fallback
    }

    debugPrint('HeadTracking: Range calibration done! '
        'xRange=${xRange.toStringAsFixed(4)} yRange=${yRange.toStringAsFixed(4)} '
        'sensX=${_sensX.toStringAsFixed(1)} sensY=${_sensY.toStringAsFixed(1)}');
  }

  /// ══════════════════════════════════════════════════════════════
  /// Edge boost: accelerate cursor when near screen edges
  /// ══════════════════════════════════════════════════════════════
  double _applyEdgeBoost(double val) {
    final abs = val.abs();
    if (abs > _edgeBoostThreshold) {
      // Gradually increase push past threshold
      final extra = (abs - _edgeBoostThreshold) / (1.0 - _edgeBoostThreshold);
      final boosted = abs + extra * _edgeBoostFactor * (1.0 - _edgeBoostThreshold);
      return val.sign * boosted;
    }
    return val;
  }

  /// ══════════════════════════════════════════════════════════════
  /// Auto-ranging: dynamically adjust sensitivity based on
  /// observed movement range (when range calibration was skipped)
  /// ══════════════════════════════════════════════════════════════
  void _updateAutoRange(double x, double y) {
    _autoRangeFrames++;

    // Decay old extremes slowly (forget stale data)
    _observedMinX *= _autoRangeDecay;
    _observedMaxX *= _autoRangeDecay;
    _observedMinY *= _autoRangeDecay;
    _observedMaxY *= _autoRangeDecay;

    // Update with new observations
    if (x < _observedMinX) _observedMinX = x;
    if (x > _observedMaxX) _observedMaxX = x;
    if (y < _observedMinY) _observedMinY = y;
    if (y > _observedMaxY) _observedMaxY = y;

    if (_autoRangeFrames < _autoRangeWarmup) return;

    // Every 30 frames, recalculate sensitivity
    if (_autoRangeFrames % 30 == 0) {
      final xRange = _observedMaxX - _observedMinX;
      final yRange = _observedMaxY - _observedMinY;

      if (xRange > _autoRangeMinRange) {
        // Target: observed range should reach ±0.85 of screen
        final targetX = 1.7 / xRange;
        // Blend gradually toward target (don't jump)
        _sensX += (targetX.clamp(3.0, 15.0) - _sensX) * 0.1;
      }
      if (yRange > _autoRangeMinRange) {
        final targetY = 1.7 / yRange;
        _sensY += (targetY.clamp(3.0, 15.0) - _sensY) * 0.1;
      }
    }
  }

  /// Convert normalized [-1,1] to screen pixel coordinates
  ui.Offset toScreenPosition(ui.Size screenSize) {
    final sx = ((1.0 + _outX) / 2.0) * screenSize.width;
    final sy = ((1.0 + _outY) / 2.0) * screenSize.height;
    return ui.Offset(
      sx.clamp(0, screenSize.width),
      sy.clamp(0, screenSize.height),
    );
  }

  /// Reset and recalibrate
  void recalibrate() {
    _calPhase = CalibrationPhase.center;
    _calFrames = 0;
    _baseMidX = 0; _baseMidY = 0;
    _baseNoseX = 0; _baseNoseY = 0;
    _rangeLeftX = 0; _rangeRightX = 0;
    _rangeUpY = 0; _rangeDownY = 0;
    _rangeTempSum = 0; _rangeTempCount = 0;
    _smoothInit = false;
    _smoothX = 0; _smoothY = 0;
    _smooth2X = 0; _smooth2Y = 0;
    _outX = 0; _outY = 0;
    _autoRangeActive = false;
    _autoRangeFrames = 0;
    _observedMinX = 0; _observedMaxX = 0;
    _observedMinY = 0; _observedMaxY = 0;
    debugPrint('HeadTracking: Recalibrating...');
  }
}