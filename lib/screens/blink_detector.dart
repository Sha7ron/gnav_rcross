/// ===========================================================================
/// GazeNav v5.2 - BLINK DETECTOR (Fixed Sensitivity)
/// ===========================================================================
///
/// v5.2 FIXES:
/// - Raised close threshold: 0.3 → 0.5 (ML Kit often doesn't go below 0.4
///   during quick blinks at low FPS)
/// - Reduced smoothing alpha: 0.4 → 0.65 (faster response to blink events)
/// - Reduced min closed duration: 50ms → 20ms (catches quick blinks)
/// - Added raw threshold check alongside smoothed (belt + suspenders)
/// - Increased max closed: 400ms → 600ms (more forgiving)
///
/// Double blink: two confirmed blinks within 700ms window.
///
/// ===========================================================================

import 'package:flutter/foundation.dart';

enum BlinkState { open, closing, closed, opening }

class BlinkDetector {
  // ── Thresholds (TUNED for real-world ML Kit at 3-5 FPS) ──
  static const double _closeThreshold = 0.5;   // Was 0.3 - too strict!
  static const double _openThreshold = 0.6;    // Eyes reopened
  static const int _minClosedMs = 20;           // Was 50 - catch fast blinks
  static const int _maxClosedMs = 600;          // Was 400 - more forgiving
  static const int _doubleBlinkWindowMs = 700;  // Was 600 - slightly more time

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
  static const double _probAlpha = 0.65; // Was 0.4 - faster response now

  // ── Raw probability (unsmoothed, for instant threshold checks) ──
  double _rawProb = 1.0;

  // ── Debug counters ──
  int _totalBlinks = 0;
  int _totalDoubleBlinks = 0;

  /// Process eye open probabilities from ML Kit.
  void update(double? leftEyeOpen, double? rightEyeOpen) {
    // Average both eyes
    double prob;
    if (leftEyeOpen != null && rightEyeOpen != null) {
      prob = (leftEyeOpen + rightEyeOpen) / 2.0;
    } else {
      prob = leftEyeOpen ?? rightEyeOpen ?? 1.0;
    }

    _rawProb = prob;

    // Smooth the probability
    _smoothProb += (prob - _smoothProb) * _probAlpha;

    final now = DateTime.now();

    // Use the LOWER of raw and smoothed for close detection (more sensitive)
    // Use the HIGHER for open detection (more robust)
    final closeProb = _rawProb < _smoothProb ? _rawProb : _smoothProb;
    final openProb = _rawProb > _smoothProb ? _rawProb : _smoothProb;

    switch (_state) {
      case BlinkState.open:
        if (closeProb < _closeThreshold) {
          _state = BlinkState.closing;
          _closeStartTime = now;
          debugPrint('BLINK: Eyes closing (prob=${closeProb.toStringAsFixed(2)})');
        }
        break;

      case BlinkState.closing:
        if (openProb > _openThreshold) {
          // Check if it was long enough to count
          final elapsed = now.difference(_closeStartTime!).inMilliseconds;
          if (elapsed >= _minClosedMs) {
            // Quick valid blink!
            _state = BlinkState.open;
            _closeStartTime = null;
            _onBlinkDetected(now);
          } else {
            // Too fast - noise
            _state = BlinkState.open;
            _closeStartTime = null;
          }
        } else {
          final elapsed = now.difference(_closeStartTime!).inMilliseconds;
          if (elapsed >= _minClosedMs) {
            _state = BlinkState.closed;
          }
        }
        break;

      case BlinkState.closed:
        if (openProb > _openThreshold) {
          _state = BlinkState.open;
          _closeStartTime = null;
          _onBlinkDetected(now);
        } else {
          // Check if closed too long
          final elapsed = now.difference(_closeStartTime!).inMilliseconds;
          if (elapsed > _maxClosedMs) {
            _state = BlinkState.open;
            _closeStartTime = null;
            debugPrint('BLINK: Long close ignored (${elapsed}ms)');
          }
        }
        break;

      case BlinkState.opening:
      // This state is no longer used in the simplified flow
        _state = BlinkState.open;
        break;
    }

    // Check for expired double-blink window
    if (_blinkCount == 1 && _lastBlinkTime != null) {
      final sinceFirst = now.difference(_lastBlinkTime!).inMilliseconds;
      if (sinceFirst > _doubleBlinkWindowMs) {
        _blinkCount = 0;
        onSingleBlink?.call();
        debugPrint('BLINK: Single blink confirmed (window expired)');
      }
    }
  }

  void _onBlinkDetected(DateTime now) {
    _totalBlinks++;
    debugPrint('BLINK: Blink #$_totalBlinks detected!');

    if (_blinkCount == 0) {
      _blinkCount = 1;
      _lastBlinkTime = now;
    } else if (_blinkCount == 1) {
      final sinceFirst = now.difference(_lastBlinkTime!).inMilliseconds;
      if (sinceFirst <= _doubleBlinkWindowMs) {
        _blinkCount = 0;
        _lastBlinkTime = null;
        _totalDoubleBlinks++;
        debugPrint('BLINK: ★ DOUBLE BLINK #$_totalDoubleBlinks ★');
        onDoubleBlink?.call();
      } else {
        onSingleBlink?.call();
        _blinkCount = 1;
        _lastBlinkTime = now;
      }
    }
  }

  /// Current smoothed eye open probability
  double get eyeOpenProbability => _smoothProb;

  /// Raw (unsmoothed) probability
  double get rawProbability => _rawProb;

  /// Current state name
  String get stateLabel => _state.name.toUpperCase();

  /// Debug stats
  int get totalBlinks => _totalBlinks;
  int get totalDoubleBlinks => _totalDoubleBlinks;

  /// Reset
  void reset() {
    _state = BlinkState.open;
    _closeStartTime = null;
    _lastBlinkTime = null;
    _blinkCount = 0;
    _smoothProb = 1.0;
    _rawProb = 1.0;
    _totalBlinks = 0;
    _totalDoubleBlinks = 0;
  }
}