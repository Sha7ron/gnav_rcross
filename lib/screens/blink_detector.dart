/// ===========================================================================
/// GazeNav v5 - BLINK DETECTOR
/// ===========================================================================
///
/// Detects single and double blinks using ML Kit's eyeOpenProbability.
///
/// Blink detection state machine:
///   OPEN → CLOSING (probability drops below threshold)
///   CLOSING → CLOSED (stays below threshold for min duration)
///   CLOSED → OPENING (probability rises above threshold)
///   OPENING → OPEN (confirmed blink)
///
/// Double blink: two confirmed blinks within 600ms window.
///
/// ===========================================================================

import 'package:flutter/foundation.dart';

enum BlinkState { open, closing, closed, opening }

class BlinkDetector {
  // ── Thresholds ──
  static const double _closeThreshold = 0.3;  // Below this = eyes closed
  static const double _openThreshold = 0.6;   // Above this = eyes open
  static const int _minClosedMs = 50;          // Min blink duration (ms)
  static const int _maxClosedMs = 400;         // Max blink duration (rejects long closes)
  static const int _doubleBinkWindowMs = 600;  // Window for second blink

  // ── State ──
  BlinkState _state = BlinkState.open;
  DateTime? _closeStartTime;
  DateTime? _lastBlinkTime;
  int _blinkCount = 0;

  // ── Callbacks ──
  void Function()? onSingleBlink;
  void Function()? onDoubleBlink;

  // ── Smoothed probability ──
  double _smoothProb = 1.0;
  static const double _probAlpha = 0.4;

  /// Process eye open probabilities from ML Kit face detection.
  /// Call this every frame with both eye probabilities.
  void update(double? leftEyeOpen, double? rightEyeOpen) {
    // Average both eyes (if one is null, use the other)
    double prob;
    if (leftEyeOpen != null && rightEyeOpen != null) {
      prob = (leftEyeOpen + rightEyeOpen) / 2.0;
    } else {
      prob = leftEyeOpen ?? rightEyeOpen ?? 1.0;
    }

    // Smooth the probability to avoid noise-triggered blinks
    _smoothProb += (prob - _smoothProb) * _probAlpha;

    final now = DateTime.now();

    switch (_state) {
      case BlinkState.open:
        if (_smoothProb < _closeThreshold) {
          _state = BlinkState.closing;
          _closeStartTime = now;
        }
        break;

      case BlinkState.closing:
        if (_smoothProb > _openThreshold) {
          // Eyes opened too quickly - probably noise
          _state = BlinkState.open;
          _closeStartTime = null;
        } else {
          final elapsed = now.difference(_closeStartTime!).inMilliseconds;
          if (elapsed >= _minClosedMs) {
            _state = BlinkState.closed;
          }
        }
        break;

      case BlinkState.closed:
        if (_smoothProb > _openThreshold) {
          _state = BlinkState.opening;
        } else {
          // Check if eyes have been closed too long (not a blink)
          final elapsed = now.difference(_closeStartTime!).inMilliseconds;
          if (elapsed > _maxClosedMs) {
            // Long close - reset, not a blink
            _state = BlinkState.open;
            _closeStartTime = null;
          }
        }
        break;

      case BlinkState.opening:
      // Confirmed blink!
        _state = BlinkState.open;
        _closeStartTime = null;
        _onBlinkDetected(now);
        break;
    }

    // Check for expired double-blink window
    if (_blinkCount == 1 && _lastBlinkTime != null) {
      final sinceFirst = now.difference(_lastBlinkTime!).inMilliseconds;
      if (sinceFirst > _doubleBinkWindowMs) {
        // Window expired - it was just a single blink
        _blinkCount = 0;
        onSingleBlink?.call();
      }
    }
  }

  void _onBlinkDetected(DateTime now) {
    if (_blinkCount == 0) {
      // First blink - start double-blink window
      _blinkCount = 1;
      _lastBlinkTime = now;
      debugPrint('BlinkDetector: First blink detected');
    } else if (_blinkCount == 1) {
      final sinceFirst = now.difference(_lastBlinkTime!).inMilliseconds;
      if (sinceFirst <= _doubleBinkWindowMs) {
        // Second blink within window = DOUBLE BLINK!
        _blinkCount = 0;
        _lastBlinkTime = null;
        debugPrint('BlinkDetector: DOUBLE BLINK!');
        onDoubleBlink?.call();
      } else {
        // Too slow - treat as new first blink
        _blinkCount = 1;
        _lastBlinkTime = now;
        onSingleBlink?.call();
      }
    }
  }

  /// Current smoothed eye open probability (for debug display)
  double get eyeOpenProbability => _smoothProb;

  /// Current state name (for debug display)
  String get stateLabel => _state.name.toUpperCase();

  /// Reset detector
  void reset() {
    _state = BlinkState.open;
    _closeStartTime = null;
    _lastBlinkTime = null;
    _blinkCount = 0;
    _smoothProb = 1.0;
  }
}